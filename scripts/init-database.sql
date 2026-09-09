-- ============================================================================
-- Supabase Self-Hosted — Inicializacao do PostgreSQL externo
-- ============================================================================
-- Execute este script NO SERVIDOR PostgreSQL externo ANTES de subir os
-- containers. Conecte como superuser (ex.: postgres).
--
-- O que este script faz:
--   1. Cria os roles que os servicos Supabase esperam
--   2. Cria os schemas necessarios
--   3. Instala extensoes basicas
--   4. Configura grants e search_path
--   5. Cria a tabela de controle de migrations
--
-- IMPORTANTE: troque 'TROQUE_PELA_SUA_SENHA' pela mesma senha usada em
-- POSTGRES_PASSWORD no .env.
-- ============================================================================

-- ── 1. Roles ────────────────────────────────────────────────────────────────

DO $$
BEGIN
  -- Role de login principal (PostgREST usa para conectar e trocar de role)
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD 'TROQUE_PELA_SUA_SENHA';
  END IF;

  -- Roles de sessao (PostgREST faz SET ROLE para estes)
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;

  -- Admin geral (Studio, Meta, Edge Functions)
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    CREATE ROLE supabase_admin NOLOGIN NOINHERIT BYPASSRLS CREATEROLE CREATEDB;
  END IF;

  -- GoTrue (Auth)
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin NOLOGIN NOINHERIT CREATEROLE;
  END IF;

  -- Storage
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
    CREATE ROLE supabase_storage_admin NOLOGIN NOINHERIT;
  END IF;

  -- Realtime
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_realtime_admin') THEN
    CREATE ROLE supabase_realtime_admin NOLOGIN NOINHERIT;
  END IF;

  -- Functions
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_functions_admin') THEN
    CREATE ROLE supabase_functions_admin NOLOGIN NOINHERIT;
  END IF;

  -- Dashboard user
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dashboard_user') THEN
    CREATE ROLE dashboard_user NOLOGIN NOINHERIT;
  END IF;

  -- Read-only (opcional, para consultas externas)
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_read_only_user') THEN
    CREATE ROLE supabase_read_only_user NOLOGIN NOINHERIT;
  END IF;
END
$$;

-- Definir senhas para os roles que conectam diretamente
-- (mesma senha para simplificar; em producao, use senhas diferentes)
ALTER ROLE authenticator          PASSWORD 'TROQUE_PELA_SUA_SENHA';
ALTER ROLE supabase_auth_admin    PASSWORD 'TROQUE_PELA_SUA_SENHA' LOGIN;
ALTER ROLE supabase_storage_admin PASSWORD 'TROQUE_PELA_SUA_SENHA' LOGIN;
ALTER ROLE supabase_admin         PASSWORD 'TROQUE_PELA_SUA_SENHA' LOGIN;

-- authenticator precisa poder virar qualquer role de sessao
GRANT anon              TO authenticator;
GRANT authenticated     TO authenticator;
GRANT service_role      TO authenticator;
GRANT supabase_admin    TO authenticator;

-- supabase_auth_admin precisa criar/gerenciar users
GRANT supabase_auth_admin TO supabase_admin;
GRANT anon                TO supabase_auth_admin;
GRANT authenticated       TO supabase_auth_admin;

-- supabase_admin herda tudo
GRANT supabase_storage_admin   TO supabase_admin;
GRANT supabase_realtime_admin  TO supabase_admin;
GRANT supabase_functions_admin TO supabase_admin;
GRANT dashboard_user           TO supabase_admin;

-- ── 2. Schemas ──────────────────────────────────────────────────────────────

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS storage;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS _realtime;
CREATE SCHEMA IF NOT EXISTS graphql_public;
CREATE SCHEMA IF NOT EXISTS supabase_functions;
CREATE SCHEMA IF NOT EXISTS supabase_migrations;

ALTER SCHEMA auth       OWNER TO supabase_auth_admin;
ALTER SCHEMA storage    OWNER TO supabase_storage_admin;
ALTER SCHEMA _realtime  OWNER TO supabase_realtime_admin;
ALTER SCHEMA supabase_functions OWNER TO supabase_functions_admin;

-- ── 3. Extensoes ────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS "uuid-ossp"      SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto          SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgjwt             SCHEMA extensions;

-- ── 4. Grants ───────────────────────────────────────────────────────────────

-- Schema public
GRANT USAGE  ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL    ON SCHEMA public TO supabase_admin;

-- Default privileges para tabelas criadas no schema public
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT                ON TABLES    TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL                   ON TABLES    TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT         ON SEQUENCES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL                   ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE               ON FUNCTIONS TO anon, authenticated, service_role;

-- Schema extensions
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role, supabase_admin;

-- Schema auth (GoTrue gerencia internamente, mas precisa de acesso basico)
GRANT USAGE ON SCHEMA auth TO supabase_auth_admin;
GRANT ALL   ON SCHEMA auth TO supabase_auth_admin;

-- Schema storage
GRANT USAGE ON SCHEMA storage TO supabase_storage_admin, anon, authenticated, service_role;

-- Search path
ALTER ROLE authenticator       SET search_path TO public, extensions;
ALTER ROLE anon                SET search_path TO public, extensions;
ALTER ROLE authenticated       SET search_path TO public, extensions;
ALTER ROLE service_role        SET search_path TO public, extensions;
ALTER ROLE supabase_admin      SET search_path TO public, extensions;
ALTER ROLE supabase_auth_admin SET search_path TO auth, public, extensions;

-- ── 5. Tabela de controle de migrations ─────────────────────────────────────

CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
  version text NOT NULL PRIMARY KEY,
  name    text,
  statements text[],
  hash    text
);

GRANT USAGE ON SCHEMA supabase_migrations TO supabase_admin;
GRANT ALL   ON ALL TABLES IN SCHEMA supabase_migrations TO supabase_admin;

-- ── 6. Replication (necessario para Realtime) ───────────────────────────────

-- O role que o Realtime usa precisa de replication.
-- Em PostgreSQL gerenciado (RDS/Cloud SQL), isso pode exigir configuracao
-- separada no painel do provider.
DO $$
BEGIN
  EXECUTE format('ALTER ROLE supabase_admin REPLICATION');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Nao foi possivel conceder REPLICATION — configure manualmente se necessario para Realtime';
END
$$;

-- ============================================================================
-- Pronto! Agora suba os containers com: docker compose up -d
-- O GoTrue (auth) e o Storage criam suas tabelas automaticamente no primeiro boot.
-- ============================================================================
