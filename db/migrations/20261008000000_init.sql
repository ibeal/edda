-- migrate:up

-- Agents never run DDL. Only the migrate service (admin) does.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- ── helpers ───────────────────────────────────────────────────────────────────────────────────────
CREATE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Who wrote it. The shared `agent` login can't tell agents apart, so identity is self-asserted: set it
-- per session (`SET app.agent = 'pi'`) or pass `author` explicitly. Falls back to the login name.
CREATE FUNCTION current_author() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.agent', true), ''), current_user)
$$;

-- ── logs: the tagged, append-only record ──────────────────────────────────────────────────────────
-- Tags are free-form strings, by convention `key:value` (kind:lesson, repo:skald). A correction is a
-- new entry tagged `corrects:<id>`. Rows are never updated by agents.
CREATE TABLE logs (
  id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  author     text        NOT NULL DEFAULT current_author(),
  body       text        NOT NULL CHECK (body <> ''),
  tags       text[]      NOT NULL DEFAULT '{}',
  meta       jsonb       NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  tsv        tsvector GENERATED ALWAYS AS (to_tsvector('english', body)) STORED
);
CREATE INDEX logs_tags    ON logs USING gin (tags);
CREATE INDEX logs_tsv     ON logs USING gin (tsv);
CREATE INDEX logs_created ON logs (created_at);

-- ── tasks: mutable work items (skald's closed field set; the rest lives in meta) ──────────────────
-- meta holds repos, branch, link, pr, complexity, provider. Unconstrained on purpose; promote a key
-- to a column (with a migration) once it earns it.
CREATE TABLE tasks (
  id         text        PRIMARY KEY CHECK (id ~ '^[A-Za-z0-9][A-Za-z0-9._-]*$'),  -- permanent, no rename
  title      text        NOT NULL CHECK (title <> '' AND title !~ '[:\n]'),
  status     text        NOT NULL DEFAULT 'refining'
               CHECK (status IN ('refining', 'designing', 'building', 'reviewing', 'done', 'cancelled')),
  paused     text,                                           -- why it is parked; NULL = running
  parent     text        REFERENCES tasks (id),
  ac         text        NOT NULL DEFAULT '',                -- acceptance criteria
  tags       text[]      NOT NULL DEFAULT '{}',
  meta       jsonb       NOT NULL DEFAULT '{}',
  author     text        NOT NULL DEFAULT current_author(),  -- creator
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  tsv        tsvector GENERATED ALWAYS AS (to_tsvector('english', title || ' ' || ac)) STORED
);
CREATE INDEX tasks_status ON tasks (status);
CREATE INDEX tasks_parent ON tasks (parent);
CREATE INDEX tasks_tags   ON tasks USING gin (tags);
CREATE INDEX tasks_tsv    ON tasks USING gin (tsv);

-- skald's state rules, enforced for everyone except superusers (the admin / an elevated session):
--   * done and cancelled are terminal: nothing changes after
--   * acceptance criteria are frozen outside `refining`
CREATE FUNCTION tasks_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;
  IF OLD.status IN ('done', 'cancelled') THEN
    RAISE EXCEPTION 'task % is terminal (%); make a new task with parent = %', OLD.id, OLD.status, OLD.id
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.ac IS DISTINCT FROM OLD.ac AND OLD.status <> 'refining' THEN
    RAISE EXCEPTION 'acceptance criteria of % are frozen outside refining (status is %); set status = refining first',
      OLD.id, OLD.status USING ERRCODE = 'check_violation';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER tasks_guard BEFORE UPDATE ON tasks FOR EACH ROW EXECUTE FUNCTION tasks_guard();

-- ── docs: the curated library (standards, decisions, ...) ─────────────────────────────────────────
-- Written by the admin / an elevated session. Overwrites in place. `archived` is a soft delete.
CREATE TABLE docs (
  id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  slug       text        NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9._-]*$'),
  kind       text        NOT NULL CHECK (kind <> ''),        -- free text: standard, decision, ...
  title      text        NOT NULL CHECK (title <> ''),
  body       text        NOT NULL CHECK (body <> ''),
  archived   boolean     NOT NULL DEFAULT false,
  tags       text[]      NOT NULL DEFAULT '{}',
  meta       jsonb       NOT NULL DEFAULT '{}',
  author     text        NOT NULL DEFAULT current_author(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  tsv        tsvector GENERATED ALWAYS AS (to_tsvector('english', title || ' ' || body)) STORED
);
CREATE INDEX docs_tags ON docs USING gin (tags);
CREATE INDEX docs_tsv  ON docs USING gin (tsv);
CREATE TRIGGER docs_touch BEFORE UPDATE ON docs FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ── links ─────────────────────────────────────────────────────────────────────────────────────────
-- Many-to-many. Cascades so admin cleanup of a log/task/doc leaves no orphans.
CREATE TABLE task_logs (
  task_id    text        NOT NULL REFERENCES tasks (id) ON DELETE CASCADE,
  log_id     bigint      NOT NULL REFERENCES logs (id)  ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (task_id, log_id)
);
CREATE INDEX task_logs_log ON task_logs (log_id);

CREATE TABLE doc_logs (
  doc_id     bigint      NOT NULL REFERENCES docs (id) ON DELETE CASCADE,
  log_id     bigint      NOT NULL REFERENCES logs (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (doc_id, log_id)
);
CREATE INDEX doc_logs_log ON doc_logs (log_id);

-- One call to journal on a task: writes the log and links it, atomically. Returns the log id.
CREATE FUNCTION add_task_log(p_task text, p_body text, p_tags text[] DEFAULT '{}', p_meta jsonb DEFAULT '{}')
RETURNS bigint LANGUAGE sql AS $$
  WITH l AS (INSERT INTO logs (body, tags, meta) VALUES (p_body, p_tags, p_meta) RETURNING id),
       k AS (INSERT INTO task_logs (task_id, log_id) SELECT p_task, id FROM l)
  SELECT id FROM l
$$;

-- ── access: the shared `agent` login (created by bootstrap/roles.sql) ─────────────────────────────
GRANT SELECT ON logs, tasks, docs, task_logs, doc_logs TO agent;

-- logs: create + read. id, created_at, tsv are always server-stamped.
GRANT INSERT (author, body, tags, meta) ON logs TO agent;

-- tasks: create + read + update of the working fields. id, author, created_at, updated_at are fixed.
GRANT INSERT (id, title, status, paused, parent, ac, tags, meta, author) ON tasks TO agent;
GRANT UPDATE (title, status, paused, parent, ac, tags, meta)              ON tasks TO agent;

-- links to tasks are agent-written facts; links to docs are curated.
GRANT INSERT (task_id, log_id) ON task_logs TO agent;

-- docs: read-only, and archived docs are invisible to agents. (Owner and superusers bypass RLS.)
ALTER TABLE docs ENABLE ROW LEVEL SECURITY;
CREATE POLICY agent_read_live ON docs FOR SELECT TO agent USING (NOT archived);

-- migrate:down
DROP FUNCTION add_task_log(text, text, text[], jsonb);
DROP TABLE doc_logs, task_logs, docs, tasks, logs;
DROP FUNCTION tasks_guard();
DROP FUNCTION current_author();
DROP FUNCTION touch_updated_at();
