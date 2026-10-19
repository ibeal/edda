#!/bin/sh
# Guardrail regression: asserts what the shared `agent` role can and cannot do. Run on every migration.
#
#   agent connection: standard libpq env (PGHOST, PGPORT, PGPASSWORD, PGDATABASE), user = agent
#   ADMIN_URL | ADMIN_PSQL:  how to act as admin (docs are admin-written; cleanup). ADMIN_PSQL is an
#                     executable that runs `psql -At -U admin` (admin has no TCP path in the container stack)
#
# Everything it writes is prefixed `verify-` (tasks, docs) or tagged `verify` (logs), and is removed
# at the end by the admin. Exit 0 = all checks passed.
set -u
: "${ADMIN_PSQL:-${ADMIN_URL:?set ADMIN_URL (admin connection string) or ADMIN_PSQL (admin psql wrapper)}}"
fail=0
AGENT="${AGENT_USER:-agent}"

q()  { psql -X -q -v ON_ERROR_STOP=1 -At -U "$AGENT" -c "$1" 2>&1; }
# admin: an executable that runs psql as admin (ADMIN_PSQL, e.g. a `docker compose exec` wrapper), or a URL
qa() { if [ -n "${ADMIN_PSQL:-}" ]; then "$ADMIN_PSQL" -v ON_ERROR_STOP=1 -c "$1" 2>&1; else psql -X -q -v ON_ERROR_STOP=1 -At "$ADMIN_URL" -c "$1" 2>&1; fi; }

ok()    { out=$(q "$2");  rc=$?; if [ $rc -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1: $out"; fail=1; fi; }
deny()  { out=$(q "$2");  rc=$?; if [ $rc -ne 0 ] && printf %s "$out" | grep -q -i -E "$3"; then echo "ok   $1"; else echo "FAIL $1 (wanted /$3/): rc=$rc $out"; fail=1; fi; }
eq()    { out=$(q "$2");  if [ "$out" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$out' wanted '$3'"; fail=1; fi; }
adeny() { out=$(qa "$2"); rc=$?; if [ $rc -ne 0 ] && printf %s "$out" | grep -q -i -E "$3"; then echo "ok   $1"; else echo "FAIL $1 (wanted /$3/): rc=$rc $out"; fail=1; fi; }
aok()   { out=$(qa "$2"); rc=$?; if [ $rc -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1: $out"; fail=1; fi; }
aeq()   { out=$(qa "$2"); if [ "$out" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$out' wanted '$3'"; fail=1; fi; }

cleanup() {
  qa "DELETE FROM logs WHERE tags @> ARRAY['verify']; DELETE FROM tasks WHERE id LIKE 'verify-%'; DELETE FROM docs WHERE slug LIKE 'verify-%'" >/dev/null 2>&1 \
    || echo "WARN cleanup failed; remove verify rows by hand"
}
cleanup  # in case a previous run died

# ── logs ──────────────────────────────────────────────────────────────────────────────────────────
L="INSERT INTO logs (body, tags"
ok   "insert a log (minimal)" "$L) VALUES ('first verify entry', ARRAY['verify','kind:lesson','repo:skald'])"
eq   "author defaults to the login" "SELECT author FROM logs WHERE body='first verify entry'" "$AGENT"
ok   "author from session setting" "SET app.agent = 'pi'; $L) VALUES ('pi entry', ARRAY['verify'])"
eq   "session author recorded" "SELECT author FROM logs WHERE body='pi entry'" "pi"
ok   "explicit author" "INSERT INTO logs (author, body, tags) VALUES ('codex', 'codex entry', ARRAY['verify'])"
ok   "meta accepts anything" "INSERT INTO logs (body, tags, meta) VALUES ('meta entry', ARRAY['verify'], '{\"a\":[1,2],\"b\":{\"c\":null}}')"
deny "empty body rejected" "$L) VALUES ('', ARRAY['verify'])" "check constraint"
deny "agent cannot UPDATE logs" "UPDATE logs SET body='x'" "permission denied"
deny "agent cannot DELETE logs" "DELETE FROM logs" "permission denied"
deny "agent cannot TRUNCATE logs" "TRUNCATE logs" "permission denied"
deny "agent cannot set created_at" "INSERT INTO logs (body, tags, created_at) VALUES ('x', ARRAY['verify'], '2001-01-01')" "permission denied"
deny "agent cannot set id" "INSERT INTO logs (id, body, tags) VALUES (999999, 'x', ARRAY['verify'])" "permission denied|non-DEFAULT"
eq   "filter by tag" "SELECT count(*) FROM logs WHERE tags @> ARRAY['repo:skald'] AND tags @> ARRAY['verify']" "1"
eq   "full-text search" "SELECT count(*) FROM logs WHERE tsv @@ websearch_to_tsquery('english','codex') AND tags @> ARRAY['verify']" "1"
eq   "substring match" "SELECT count(*) FROM logs WHERE body ILIKE '%entry%' AND tags @> ARRAY['verify']" "4"

# ── tasks ─────────────────────────────────────────────────────────────────────────────────────────
T="INSERT INTO tasks (id, title"
ok   "create a task (minimal)" "$T) VALUES ('verify-t1', 'a task')"
eq   "task defaults" "SELECT status||'/'||(paused IS NULL)||'/'||ac||'/'||(created_at = updated_at) FROM tasks WHERE id='verify-t1'" "refining/true//true"
deny "duplicate id (claim twice)" "$T) VALUES ('verify-t1', 'again')" "duplicate key"
deny "bad id" "$T) VALUES ('bad id', 'x')" "check constraint"
deny "title with ':' rejected" "$T) VALUES ('verify-t2', 'a: b')" "check constraint"
deny "bad status" "$T, status) VALUES ('verify-t2', 'x', 'wat')" "check constraint"
deny "unknown parent" "$T, parent) VALUES ('verify-t2', 'x', 'verify-missing')" "foreign key"
ok   "meta holds repos/branch/pr/complexity" "UPDATE tasks SET meta = '{\"repos\":[\"skald\"],\"branch\":\"b\",\"pr\":\"u\",\"complexity\":2,\"provider\":\"openai\"}' WHERE id='verify-t1'"
eq   "meta filter" "SELECT id FROM tasks WHERE meta->>'provider' = 'openai' AND id LIKE 'verify-%'" "verify-t1"
ok   "AC editable while refining" "UPDATE tasks SET ac='criteria v1' WHERE id='verify-t1'"
ok   "refining -> designing" "UPDATE tasks SET status='designing' WHERE id='verify-t1'"
deny "AC frozen outside refining" "UPDATE tasks SET ac='bent to fit the code' WHERE id='verify-t1'" "frozen outside refining"
ok   "free movement between live states" "UPDATE tasks SET status='building' WHERE id='verify-t1'"
deny "AC and status can't move in one statement" "UPDATE tasks SET status='refining', ac='criteria v2' WHERE id='verify-t1'" "frozen outside refining"
ok   "back to refining, then re-edit AC" "UPDATE tasks SET status='refining' WHERE id='verify-t1'; UPDATE tasks SET ac='criteria v2' WHERE id='verify-t1'"
ok   "pause and resume" "UPDATE tasks SET paused='waiting on x' WHERE id='verify-t1'; UPDATE tasks SET paused=NULL WHERE id='verify-t1'"
eq   "updated_at moves" "SELECT updated_at > created_at FROM tasks WHERE id='verify-t1'" "t"
ok   "child task" "$T, parent) VALUES ('verify-t2', 'slice', 'verify-t1')"
deny "agent cannot change id" "UPDATE tasks SET id='verify-x' WHERE id='verify-t2'" "permission denied"
deny "agent cannot change author" "UPDATE tasks SET author='x' WHERE id='verify-t2'" "permission denied"
deny "agent cannot change created_at" "UPDATE tasks SET created_at=now() WHERE id='verify-t2'" "permission denied"
deny "agent cannot DELETE tasks" "DELETE FROM tasks WHERE id='verify-t2'" "permission denied"
ok   "finish a task" "UPDATE tasks SET status='done' WHERE id='verify-t2'"
deny "done is terminal" "UPDATE tasks SET title='renamed' WHERE id='verify-t2'" "terminal"
deny "cannot leave done" "UPDATE tasks SET status='building' WHERE id='verify-t2'" "terminal"
aok  "admin may still fix a terminal task" "UPDATE tasks SET title='admin fixed' WHERE id='verify-t2'"
eq   "full-text search tasks" "SELECT id FROM tasks WHERE tsv @@ websearch_to_tsquery('english','criteria') AND id LIKE 'verify-%'" "verify-t1"

# ── task_logs ─────────────────────────────────────────────────────────────────────────────────────
eq   "add_task_log returns an id" "SELECT add_task_log('verify-t1', 'journal one', ARRAY['verify']) > 0" "t"
ok   "add_task_log again" "SELECT add_task_log('verify-t1', 'journal two', ARRAY['verify'])"
eq   "journal reads in order" "SELECT string_agg(l.body, ',' ORDER BY l.id) FROM task_logs k JOIN logs l ON l.id = k.log_id WHERE k.task_id='verify-t1'" "journal one,journal two"
deny "add_task_log on an unknown task writes nothing" "SELECT add_task_log('verify-missing', 'x', ARRAY['verify'])" "foreign key"
eq   "…and left no orphan log" "SELECT count(*) FROM logs WHERE body='x' AND tags @> ARRAY['verify']" "0"
ok   "one log linked to two tasks" "WITH l AS (INSERT INTO logs (body, tags) VALUES ('shared', ARRAY['verify']) RETURNING id) INSERT INTO task_logs SELECT t, l.id FROM l, unnest(ARRAY['verify-t1','verify-t2']) t"
deny "agent cannot delete a link" "DELETE FROM task_logs" "permission denied"
deny "agent cannot edit a link" "UPDATE task_logs SET task_id='verify-t2'" "permission denied"

# ── docs ──────────────────────────────────────────────────────────────────────────────────────────
D="INSERT INTO docs (slug, kind, title, body"
deny "agent cannot insert a doc" "$D) VALUES ('verify-d1', 'standard', 't', 'b')" "permission denied"
aok  "admin inserts a live doc" "$D, tags) VALUES ('verify-d1', 'standard', 'Naming', 'name things well', ARRAY['verify'])"
aok  "admin inserts an archived doc" "$D, archived) VALUES ('verify-d2', 'decision', 'Maybe later', 'draft text', true)"
eq   "agent reads the live doc" "SELECT title FROM docs WHERE slug='verify-d1'" "Naming"
eq   "archived doc is invisible to the agent" "SELECT count(*) FROM docs WHERE slug='verify-d2'" "0"
aeq  "…but the admin still sees it" "SELECT count(*) FROM docs WHERE slug='verify-d2'" "1"
eq   "agent doc search" "SELECT count(*) FROM docs WHERE tsv @@ websearch_to_tsquery('english','naming')" "1"
deny "agent cannot UPDATE docs" "UPDATE docs SET body='x' WHERE slug='verify-d1'" "permission denied"
deny "agent cannot DELETE docs" "DELETE FROM docs WHERE slug='verify-d1'" "permission denied"
deny "agent cannot archive a doc" "UPDATE docs SET archived=true WHERE slug='verify-d1'" "permission denied"
adeny "bad slug" "$D) VALUES ('Bad Slug', 'k', 't', 'b')" "check constraint"
aok  "admin overwrites a doc" "UPDATE docs SET body='name things well, always' WHERE slug='verify-d1'"
aeq  "updated_at moves on overwrite" "SELECT updated_at > created_at FROM docs WHERE slug='verify-d1'" "t"
aok  "admin links a doc to logs" "INSERT INTO doc_logs SELECT d.id, l.id FROM docs d, logs l WHERE d.slug='verify-d1' AND l.body='shared'"
eq   "agent reads doc links" "SELECT count(*) FROM doc_logs" "1"
deny "agent cannot write doc links" "INSERT INTO doc_logs SELECT d.id, l.id FROM docs d, logs l WHERE d.slug='verify-d1' AND l.body='shared'" "permission denied"
aok  "deleting a log cascades its links" "DELETE FROM logs WHERE body='shared'"
aeq  "no orphan links" "SELECT count(*) FROM task_logs k LEFT JOIN logs l ON l.id = k.log_id WHERE l.id IS NULL" "0"

# ── schema ────────────────────────────────────────────────────────────────────────────────────────
deny "agent cannot create tables" "CREATE TABLE verify_nope (x int)" "permission denied"

cleanup
[ "$fail" -eq 0 ] && echo "all checks passed" || echo "FAILED"
exit "$fail"
