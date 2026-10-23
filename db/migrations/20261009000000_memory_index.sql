-- migrate:up
-- One row per memory/archive log, with kind/scope parsed from their tags and a derived one-line
-- summary: meta.summary if set, else the first line of body (max 160 chars).
CREATE VIEW memory_index AS
SELECT id, author, tags, created_at,
       (SELECT substr(t, 6) FROM unnest(tags) t WHERE t LIKE 'kind:%'  LIMIT 1) AS kind,
       (SELECT substr(t, 7) FROM unnest(tags) t WHERE t LIKE 'scope:%' LIMIT 1) AS scope,
       meta ->> 'name' AS name,
       coalesce(meta ->> 'summary', left(split_part(body, E'\n', 1), 160)) AS summary
FROM logs
WHERE tags && ARRAY['kind:memory', 'kind:archive']
ORDER BY created_at DESC;

-- Body of one memory by name (newest wins), like `rata show memory:<name>`.
CREATE FUNCTION memory_get(p_name text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT body FROM logs
  WHERE tags && ARRAY['kind:memory', 'kind:archive'] AND meta ->> 'name' = p_name
  ORDER BY created_at DESC, id DESC LIMIT 1
$$;

GRANT SELECT ON memory_index TO agent;
GRANT EXECUTE ON FUNCTION memory_get(text) TO agent;

-- migrate:down
DROP FUNCTION memory_get(text);
DROP VIEW memory_index;
