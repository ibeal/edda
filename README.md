# edda

Postgres for agent memory: tagged **logs**, **tasks**, and a curated **docs** library. Agents connect
directly as one shared `agent` role that can read and create (and, for tasks, update) but never delete.
The database is the guardrail: grants, column-level privileges, row-level security, and triggers do the
enforcing. Agent usage is in [`docs/agents.md`](docs/agents.md).

```sh
cp .env.example .env     # set ADMIN_PASSWORD and AGENT_PASSWORD
docker compose up -d     # db → bootstrap (roles) → migrate (dbmate); idempotent
```

## Layout
```
compose.yaml          postgres:18 on the `agents` network; bootstrap/migrate/backup/restore sidecars, no network
config/pg_hba.conf    admin: socket only. agent: TCP, edda database only. Everything else rejected
bootstrap/roles.sql   cluster-level role + password (not schema); re-run on every `up`
db/migrations/        plain SQL, forward-only, dbmate format. Grants are schema, so they live here
db/schema.sql         dbmate's dump after each run — commit it; PR diffs show what changed
backup/backup.sh      backup sidecar: pg_dump -Fc on an interval into $BACKUP_DIR, prunes to the newest N
backup/restore.sh     restore sidecar (profile `restore`): replaces the database from a dump
test/verify.sh        what `agent` can and cannot do. Run on every migration
test/scratch.sh       whole stack without Docker: scratch cluster + bootstrap + dbmate + verify
test/docker.sh        end to end on real containers, isolated project: up, verify, backup, disaster, restore
```

## Backup and restore
Host-side only (no cloud, no restic): the `backup` service writes `edda-<UTC>.dump` (pg_dump custom
format) into `BACKUP_DIR` (default `./backups`) every `BACKUP_INTERVAL_HOURS` (24), keeping the newest
`BACKUP_KEEP` (14). It dumps on start unless a recent one exists, and goes `unhealthy` in `docker ps` if
the newest dump is older than twice the interval. Point `BACKUP_DIR` wherever you like. On Docker
Desktop it must be a path Docker shares with the VM (your home directory is; `/tmp` and `/var/folders`
are not, and dumps would silently land inside the VM). Sync that directory off-box yourself if you want
a second copy.

```sh
docker compose run --rm backup once                                      # dump now
docker compose run --rm restore --list                                   # what is available
docker compose run --rm -e EDDA_RESTORE_CONFIRM=yes restore              # newest dump
docker compose run --rm -e EDDA_RESTORE_CONFIRM=yes restore edda-20261009T120000Z.dump
```

Restore refuses without `EDDA_RESTORE_CONFIRM=yes`, first saves the current state as
`pre-restore-<ts>.dump` (never pruned), disconnects other sessions (stop agents first if you can), and
restores in one transaction, so a failed restore changes nothing. It runs the bootstrap service first, so
the `agent` role exists; for total loss (a new empty volume) the same command works, then `up -d`.
Both sidecars hold admin credentials.

## Changing the schema
1. `dbmate new <name>` (or add `db/migrations/<timestamp>_<name>.sql` with `-- migrate:up` / `-- migrate:down`).
2. Prefer expand → backfill → contract. Anything agents may do must be granted in the migration.
3. Add checks to `test/verify.sh` for any new guarantee, then `test/scratch.sh`.
4. `docker compose up -d` applies it. Agents never run DDL; they propose via PR or a `schema:proposal` log.

Elevated cleanup (deleting rows, curating docs) uses an admin shell, which has no network path (see Access):
`docker compose exec db psql -U admin -d edda`.

## Access
- **Agents** log in over TCP as role `agent` only, to the `edda` database only, with a password:
  - from a sandbox: join the Docker network `edda_agents` (`docker run --network edda_agents ...`) and use `PGHOST=edda-db`;
  - from the host: the published port, `PGHOST=localhost PGPORT=$EDDA_PORT`.
- **Admin** exists only on the unix socket (`config/pg_hba.conf` rejects it over TCP from anywhere). The one-shot
  sidecars (bootstrap, migrate, backup, restore) share that socket by volume and run with `network_mode: none`;
  you get in with `docker compose exec db psql -U admin -d edda`. Whoever can mount the `pgsocket` volume is
  admin, which is the same trust as having docker access.
- The published port binds `127.0.0.1` by default; `EDDA_BIND=0.0.0.0` serves other machines (still only `agent`).
- Sandboxes on the same network can reach each other as well as the database; the database holds nothing else.

## Shape notes
- `meta jsonb` on every table is unconstrained on purpose. Promote a key to a column once it earns it.
- Not built yet, by design: ingestion of external sources, embeddings/semantic search, per-agent roles
  and an inbox (RLS), auto-logging of status changes, publishing to hivedb.
