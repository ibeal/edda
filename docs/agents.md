# edda — for agents

A Postgres database holding three things. You connect directly with `psql` as the shared `agent` role
(standard libpq env: `PGHOST`, `PGPORT`, `PGDATABASE=edda`, `PGUSER=agent`, `PGPASSWORD`). From a sandbox on
the `edda_agents` Docker network use `PGHOST=edda-db`; from the host use `PGHOST=localhost` and the published
port. `agent` is the only role that can log in over the network, and only to `edda`.
If it is unreachable, that is a hard failure — say so, don't work around it.

| Table | What | You can |
|---|---|---|
| `logs` | tagged, append-only record of what happened and what you learned | read, **insert** |
| `tasks` | work items (skald's fields; extras in `meta`) | read, insert, **update** the working fields |
| `docs` | curated library: standards, decisions. Promoted from logs by a human | **read only** |

Joins: `task_logs` (task ↔ log, you may insert) and `doc_logs` (doc ↔ log, read only).
You can never `DELETE` or `TRUNCATE`, never `UPDATE` a log, and never run DDL. Mistakes are fixed by
the admin, or by you with temporarily elevated credentials Ian provides. To change the schema, propose
it: open a PR against this repo with a migration, or write a log tagged `schema:proposal`.

## Say who you are
```sql
SET app.agent = 'pi';          -- once per session; becomes `author`. Or pass author explicitly.
```

## Logs
```sql
INSERT INTO logs (body, tags) VALUES ('jj colocated repos lose tmp/ files on jj new', ARRAY['kind:lesson','repo:dotfiles']);

SELECT id, created_at, author, body FROM logs WHERE tags @> ARRAY['kind:lesson'] ORDER BY id DESC LIMIT 20;
SELECT id, body FROM logs WHERE tsv @@ websearch_to_tsquery('english', 'colocated jj');   -- full-text
SELECT id, body FROM logs WHERE body ILIKE '%tmp/%';                                       -- substring
```
Tags are free-form strings, by convention `key:value` (`kind:`, `repo:`, `org:`). `meta` is free-form
jsonb. A correction is a new entry tagged `corrects:<id>`; there is no edit.
Flag something worth promoting to the library with the tag `promote:candidate`.

## Tasks
```sql
INSERT INTO tasks (id, title) VALUES ('ask-2026-10-08-thing', 'do the thing');      -- the claim: duplicate id fails
UPDATE tasks SET status = 'designing' WHERE id = 'ask-2026-10-08-thing';
UPDATE tasks SET meta = meta || '{"repos":["edda"],"branch":"main","complexity":2}' WHERE id = '...';  -- extras live in meta
UPDATE tasks SET paused = 'waiting on x' WHERE id = '...';   -- paused = NULL to resume
SELECT id, status, title FROM tasks WHERE status = 'building' ORDER BY updated_at DESC;
```
Status: `refining | designing | building | reviewing | done | cancelled`. The database enforces skald's rules:
- `ac` (acceptance criteria) can only change while `status = 'refining'`. If it is wrong, set status back
  to `refining` **first**, in its own statement, then edit it. Don't bend the criteria to fit the code.
- `done` and `cancelled` are terminal; follow-up work is a new task with `parent` set.

### The task journal
```sql
SELECT add_task_log('ask-2026-10-08-thing', 'chose X over Y because ...', ARRAY['kind:decision']);   -- returns the log id
SELECT l.id, l.created_at, l.body FROM task_logs k JOIN logs l ON l.id = k.log_id WHERE k.task_id = '...' ORDER BY l.id;
```
`add_task_log` writes the log and links it in one step. To link an existing log: `INSERT INTO task_logs (task_id, log_id) VALUES (...)`.

## Docs (read only)
```sql
SELECT slug, title FROM docs WHERE kind = 'standard' ORDER BY slug;
SELECT body FROM docs WHERE slug = 'naming';
SELECT slug FROM docs WHERE tsv @@ websearch_to_tsquery('english', 'error handling');
SELECT l.* FROM doc_logs k JOIN logs l ON l.id = k.log_id JOIN docs d ON d.id = k.doc_id WHERE d.slug = 'naming';  -- provenance
```
Archived docs are invisible to you by design.
