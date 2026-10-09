-- Cluster-level roles, run by the `bootstrap` service on every `up` (idempotent). Roles and passwords
-- are not schema, so they live here and not in migrations; grants ARE schema and live in migrations.
-- Invoked as: psql -v agent_password=... -f roles.sql   (admin connection from the environment)

SELECT format('CREATE ROLE agent LOGIN PASSWORD %L', :'agent_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agent') \gexec

-- rotate the password on every run, so changing AGENT_PASSWORD in .env just works
SELECT format('ALTER ROLE agent LOGIN PASSWORD %L', :'agent_password') \gexec

-- belt and braces: the agent is never a superuser, and can't create anything
ALTER ROLE agent NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
