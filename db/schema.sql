\restrict dbmate

-- Dumped from database version 18.6 (Debian 18.6-1.pgdg13+2)
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: add_task_log(text, text, text[], jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_task_log(p_task text, p_body text, p_tags text[] DEFAULT '{}'::text[], p_meta jsonb DEFAULT '{}'::jsonb) RETURNS bigint
    LANGUAGE sql
    AS $$
  WITH l AS (INSERT INTO logs (body, tags, meta) VALUES (p_body, p_tags, p_meta) RETURNING id),
       k AS (INSERT INTO task_logs (task_id, log_id) SELECT p_task, id FROM l)
  SELECT id FROM l
$$;


--
-- Name: current_author(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_author() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT coalesce(nullif(current_setting('app.agent', true), ''), current_user)
$$;


--
-- Name: tasks_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tasks_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: touch_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: doc_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.doc_logs (
    doc_id bigint NOT NULL,
    log_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: docs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.docs (
    id bigint NOT NULL,
    slug text NOT NULL,
    kind text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    archived boolean DEFAULT false NOT NULL,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    author text DEFAULT public.current_author() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((title || ' '::text) || body))) STORED,
    CONSTRAINT docs_body_check CHECK ((body <> ''::text)),
    CONSTRAINT docs_kind_check CHECK ((kind <> ''::text)),
    CONSTRAINT docs_slug_check CHECK ((slug ~ '^[a-z0-9][a-z0-9._-]*$'::text)),
    CONSTRAINT docs_title_check CHECK ((title <> ''::text))
);


--
-- Name: docs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.docs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.docs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.logs (
    id bigint NOT NULL,
    author text DEFAULT public.current_author() NOT NULL,
    body text NOT NULL,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, body)) STORED,
    CONSTRAINT logs_body_check CHECK ((body <> ''::text))
);


--
-- Name: logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.logs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: task_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_logs (
    task_id text NOT NULL,
    log_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tasks (
    id text NOT NULL,
    title text NOT NULL,
    status text DEFAULT 'refining'::text NOT NULL,
    paused text,
    parent text,
    ac text DEFAULT ''::text NOT NULL,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    author text DEFAULT public.current_author() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((title || ' '::text) || ac))) STORED,
    CONSTRAINT tasks_id_check CHECK ((id ~ '^[A-Za-z0-9][A-Za-z0-9._-]*$'::text)),
    CONSTRAINT tasks_status_check CHECK ((status = ANY (ARRAY['refining'::text, 'designing'::text, 'building'::text, 'reviewing'::text, 'done'::text, 'cancelled'::text]))),
    CONSTRAINT tasks_title_check CHECK (((title <> ''::text) AND (title !~ '[:\n]'::text)))
);


--
-- Name: doc_logs doc_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_logs
    ADD CONSTRAINT doc_logs_pkey PRIMARY KEY (doc_id, log_id);


--
-- Name: docs docs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.docs
    ADD CONSTRAINT docs_pkey PRIMARY KEY (id);


--
-- Name: docs docs_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.docs
    ADD CONSTRAINT docs_slug_key UNIQUE (slug);


--
-- Name: logs logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.logs
    ADD CONSTRAINT logs_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: task_logs task_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_logs
    ADD CONSTRAINT task_logs_pkey PRIMARY KEY (task_id, log_id);


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);


--
-- Name: doc_logs_log; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX doc_logs_log ON public.doc_logs USING btree (log_id);


--
-- Name: docs_tags; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX docs_tags ON public.docs USING gin (tags);


--
-- Name: docs_tsv; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX docs_tsv ON public.docs USING gin (tsv);


--
-- Name: logs_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX logs_created ON public.logs USING btree (created_at);


--
-- Name: logs_tags; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX logs_tags ON public.logs USING gin (tags);


--
-- Name: logs_tsv; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX logs_tsv ON public.logs USING gin (tsv);


--
-- Name: task_logs_log; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX task_logs_log ON public.task_logs USING btree (log_id);


--
-- Name: tasks_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tasks_parent ON public.tasks USING btree (parent);


--
-- Name: tasks_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tasks_status ON public.tasks USING btree (status);


--
-- Name: tasks_tags; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tasks_tags ON public.tasks USING gin (tags);


--
-- Name: tasks_tsv; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tasks_tsv ON public.tasks USING gin (tsv);


--
-- Name: docs docs_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER docs_touch BEFORE UPDATE ON public.docs FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


--
-- Name: tasks tasks_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tasks_guard BEFORE UPDATE ON public.tasks FOR EACH ROW EXECUTE FUNCTION public.tasks_guard();


--
-- Name: doc_logs doc_logs_doc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_logs
    ADD CONSTRAINT doc_logs_doc_id_fkey FOREIGN KEY (doc_id) REFERENCES public.docs(id) ON DELETE CASCADE;


--
-- Name: doc_logs doc_logs_log_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.doc_logs
    ADD CONSTRAINT doc_logs_log_id_fkey FOREIGN KEY (log_id) REFERENCES public.logs(id) ON DELETE CASCADE;


--
-- Name: task_logs task_logs_log_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_logs
    ADD CONSTRAINT task_logs_log_id_fkey FOREIGN KEY (log_id) REFERENCES public.logs(id) ON DELETE CASCADE;


--
-- Name: task_logs task_logs_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_logs
    ADD CONSTRAINT task_logs_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;


--
-- Name: tasks tasks_parent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_parent_fkey FOREIGN KEY (parent) REFERENCES public.tasks(id);


--
-- Name: docs agent_read_live; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY agent_read_live ON public.docs FOR SELECT TO agent USING ((NOT archived));


--
-- Name: docs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.docs ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20261008000000');
