#!/bin/sh
# Run the full stack check WITHOUT Docker: throwaway Postgres cluster + the real bootstrap + the real
# migrations (via dbmate) + verify.sh. Needs initdb/pg_ctl/psql on PATH, and dbmate (or `nix run
# nixpkgs#dbmate`). This is what CI should run on every migration PR.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/edda-test.XXXXXX")
port=${PORT:-5597}
trap 'pg_ctl -D "$tmp/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

initdb -D "$tmp/data" -U admin -A trust >/dev/null
pg_ctl -D "$tmp/data" -o "-p $port -k $tmp -c listen_addresses=" -l "$tmp/pg.log" -w start >/dev/null
export PGHOST="$tmp" PGPORT="$port" PGDATABASE=edda

psql -X -q -U admin -d postgres -c "CREATE DATABASE edda" 
PGUSER=admin psql -X -q -v ON_ERROR_STOP=1 -v agent_password=scratch -f "$here/bootstrap/roles.sql" >/dev/null

if command -v dbmate >/dev/null 2>&1; then dbmate=dbmate; else dbmate="nix run nixpkgs#dbmate --"; fi
$dbmate --url "postgres://admin@/edda?host=$tmp&port=$port&sslmode=disable" \
        --migrations-dir "$here/db/migrations" --no-dump-schema up
# round-trip: the last migration must roll back and re-apply cleanly
$dbmate --url "postgres://admin@/edda?host=$tmp&port=$port&sslmode=disable" \
        --migrations-dir "$here/db/migrations" --no-dump-schema rollback
$dbmate --url "postgres://admin@/edda?host=$tmp&port=$port&sslmode=disable" \
        --migrations-dir "$here/db/migrations" --no-dump-schema up

ADMIN_URL="postgresql://admin@/edda?host=$tmp&port=$port" PGPASSWORD=scratch "$here/test/verify.sh"
