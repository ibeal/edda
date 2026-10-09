#!/bin/sh
# Postgres backup sidecar. Writes custom-format dumps (pg_dump -Fc) to /backups, which compose
# bind-mounts from the host's $BACKUP_DIR. Host-side only: no cloud, no restic.
#
#   backup.sh loop     dump now (unless a recent one exists), then every BACKUP_INTERVAL_HOURS; the default
#   backup.sh once     one dump, then exit
#   backup.sh health   exit 0 iff the newest dump is younger than 2x the interval (the container healthcheck)
#
# Env: BACKUP_INTERVAL_HOURS (24), BACKUP_KEEP (14: newest N edda-*.dump are kept), plus libpq PG* vars.
set -eu

DIR=/backups
KEEP=${BACKUP_KEEP:-14}
INTERVAL_MIN=$(( ${BACKUP_INTERVAL_HOURS:-24} * 60 ))
mkdir -p "$DIR"

recent() { [ -n "$(find "$DIR" -maxdepth 1 -name 'edda-*.dump' -mmin "-$1" 2>/dev/null)" ]; }

dump() {
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  out="$DIR/edda-$ts.dump"
  # write aside, then rename: a half-written dump never looks like a backup
  if pg_dump -Fc -f "$out.tmp"; then
    mv "$out.tmp" "$out"
    echo "backup: wrote $out ($(wc -c < "$out") bytes)"
  else
    rm -f "$out.tmp"
    echo "backup: ERROR pg_dump failed" >&2
    return 1
  fi
}

prune() {
  # pre-restore-*.dump safety copies are never pruned here
  ls -1 "$DIR"/edda-*.dump 2>/dev/null | sort -r | tail -n +"$((KEEP + 1))" | while read -r f; do
    rm -f "$f" && echo "backup: pruned $f"
  done
}

case "${1:-loop}" in
  health) recent "$((INTERVAL_MIN * 2))" ;;
  once)   dump && prune ;;
  loop)
    echo "backup: every $((INTERVAL_MIN / 60))h, keeping $KEEP, into $DIR"
    while :; do
      if recent "$INTERVAL_MIN"; then
        echo "backup: a dump younger than the interval exists; skipping"
      elif dump; then
        prune
      else
        echo "backup: retrying in 5 minutes" >&2
        sleep 300
        continue
      fi
      sleep "$((INTERVAL_MIN * 60))"
    done
    ;;
  *) echo "usage: backup.sh [loop|once|health]" >&2; exit 2 ;;
esac
