#!/bin/sh
# Postgres restore sidecar: REPLACES the contents of the database with a dump from /backups.
#
#   docker compose run --rm restore --list                              list dumps, newest first
#   docker compose run --rm -e EDDA_RESTORE_CONFIRM=yes restore         restore the newest dump
#   docker compose run --rm -e EDDA_RESTORE_CONFIRM=yes restore edda-20261008T120000Z.dump
#
# It first writes pre-restore-<ts>.dump (never pruned), then disconnects other sessions (agents
# included: stop them first if you can), then pg_restore --clean in one transaction, so a failed
# restore leaves the database as it was. The roles come from the bootstrap service, which compose runs
# before this. Env: libpq PG* vars.
set -eu

DIR=/backups

if [ "${1:-}" = "--list" ]; then
  ls -1 "$DIR"/*.dump 2>/dev/null | sort -r | sed "s#^$DIR/##" || true
  exit 0
fi

if [ -n "${1:-}" ]; then
  case "$1" in /*) file=$1 ;; *) file="$DIR/$1" ;; esac
else
  file=$(ls -1 "$DIR"/edda-*.dump 2>/dev/null | sort -r | head -n 1 || true)
fi
[ -n "$file" ] && [ -f "$file" ] || { echo "restore: no dump found in $DIR (try --list)" >&2; exit 1; }
pg_restore -l "$file" >/dev/null || { echo "restore: $file is not a readable dump" >&2; exit 1; }

echo "restore: would replace database '$PGDATABASE' on $PGHOST with $file"
if [ "${EDDA_RESTORE_CONFIRM:-}" != "yes" ]; then
  echo "restore: refusing. Re-run with -e EDDA_RESTORE_CONFIRM=yes to proceed." >&2
  exit 1
fi

safety="$DIR/pre-restore-$(date -u +%Y%m%dT%H%M%SZ).dump"
pg_dump -Fc -f "$safety"
echo "restore: current state saved to $safety"

psql -X -q -At -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()" >/dev/null

pg_restore --clean --if-exists --no-owner --single-transaction --exit-on-error -d "$PGDATABASE" "$file"
echo "restore: restored from $file"
psql -X -q -At -c "SELECT 'logs=' || (SELECT count(*) FROM logs) || ' tasks=' || (SELECT count(*) FROM tasks) || ' docs=' || (SELECT count(*) FROM docs)"
