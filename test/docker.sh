#!/bin/sh
# End-to-end against real containers, in an isolated compose project (edda-test), so it never touches
# a running edda: compose up, guardrail checks, backup, simulated disaster, restore, and a restore into a
# brand-new empty volume. Needs docker + psql on the host. Leaves nothing behind.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
# under the repo, not /tmp: Docker Desktop only bind-mounts paths it shares with the VM (home yes, /var/folders no)
mkdir -p "$here/tmp"
tmp=$(mktemp -d "$here/tmp/docker.XXXXXX")
port=${PORT:-55432}
cat > "$tmp/env" <<ENV
ADMIN_PASSWORD=admin-test-pw
AGENT_PASSWORD=agent-test-pw
EDDA_PORT=$port
BACKUP_DIR=$tmp/backups
ENV
c() { docker compose -p edda-test --env-file "$tmp/env" -f "$here/compose.yaml" "$@"; }
trap 'c --profile restore down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

export PGHOST=localhost PGPORT=$port PGDATABASE=edda PGPASSWORD=agent-test-pw
ADMIN="postgresql://admin:admin-test-pw@localhost:$port/edda"
AGENT="postgresql://agent:agent-test-pw@localhost:$port/edda"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' wanted '$3'"; fail=1; fi; }
agent() { psql -X -q -At "$AGENT" -c "$1"; }
admin() { psql -X -q -At "$ADMIN" -c "$1"; }
markers() { admin "SELECT (SELECT count(*) FROM logs WHERE tags @> ARRAY['bk']) || '/' || (SELECT count(*) FROM tasks WHERE id='bk-t1') || '/' || (SELECT count(*) FROM task_logs WHERE task_id='bk-t1')"; }

echo "== up"
c up -d --wait
check "backup service healthy" "$(docker inspect --format '{{.State.Health.Status}}' edda-test-backup-1)" "healthy"
check "first dump written by the loop" "$(ls "$tmp/backups" | grep -c '^edda-.*\.dump$')" "1"

echo "== guardrails against the container"
ADMIN_URL=$ADMIN "$here/test/verify.sh" | grep -v '^ok' || true

echo "== backup, disaster, restore"
agent "INSERT INTO tasks (id, title) VALUES ('bk-t1', 'backup marker')" >/dev/null
agent "SELECT add_task_log('bk-t1', 'marker entry', ARRAY['bk'])" >/dev/null
check "markers present" "$(markers)" "1/1/1"
c run --rm backup once >/dev/null
check "manual dump written" "$(ls "$tmp/backups" | grep -c '^edda-.*\.dump$')" "2"

admin "DROP TABLE logs, tasks, docs, task_logs, doc_logs CASCADE" >/dev/null
check "disaster: tables gone" "$(admin "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename='logs'")" "0"

if c run --rm restore >/dev/null 2>&1; then echo "FAIL restore ran without confirmation"; fail=1; else echo "ok   restore refuses without confirmation"; fi
c run --rm -e EDDA_RESTORE_CONFIRM=yes restore
check "markers restored" "$(markers)" "1/1/1"
check "pre-restore safety dump kept" "$(ls "$tmp/backups" | grep -c '^pre-restore-')" "1"
ADMIN_URL=$ADMIN "$here/test/verify.sh" | grep -v '^ok' || true
check "agent grants survived the restore" "$(agent "SELECT count(*) FROM tasks WHERE id='bk-t1'")" "1"

echo "== total loss: brand-new empty volume"
c down -v --remove-orphans >/dev/null 2>&1
c run --rm -e EDDA_RESTORE_CONFIRM=yes restore
c up -d --wait
check "markers back after volume loss" "$(markers)" "1/1/1"
check "migrations still consistent" "$(admin "SELECT count(*) FROM schema_migrations")" "1"
ADMIN_URL=$ADMIN "$here/test/verify.sh" | grep -v '^ok' || true

[ "$fail" -eq 0 ] && echo "all docker checks passed" || echo "FAILED"
exit "$fail"
