-- Réplica mínima del esquema v1 de prion-mvp para probar migraciones v2 en un
-- Postgres local con PostGIS (NO ejecutar en Supabase). Orden: este archivo,
-- 001_modelo_base.sql, 002_funciones.sql, 002_pruebas.sql. Base de datos vacía.
CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN;

CREATE SCHEMA extensions; CREATE EXTENSION postgis SCHEMA extensions; CREATE EXTENSION pgcrypto SCHEMA extensions;
ALTER DATABASE postgres SET search_path = "$user", public, extensions;
SET search_path = public, extensions;
CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid primary key, email text);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claims', true)::json->>'sub','')::uuid $$;
GRANT USAGE ON SCHEMA auth, extensions TO anon, authenticated; GRANT EXECUTE ON FUNCTION auth.uid() TO PUBLIC;
CREATE SCHEMA cron; CREATE TABLE cron.job(name text primary key, schedule text, command text);
CREATE FUNCTION cron.schedule(n text, s text, c text) RETURNS bigint LANGUAGE sql AS $$ INSERT INTO cron.job VALUES (n,s,c) ON CONFLICT (name) DO UPDATE SET schedule=excluded.schedule, command=excluded.command RETURNING 1::bigint $$;
CREATE TABLE public.players (id uuid PRIMARY KEY REFERENCES auth.users(id), nick text UNIQUE NOT NULL, role text NOT NULL CHECK (role IN ('civil','zombie')),
 life smallint NOT NULL DEFAULT 10, position geography, position_updated_at timestamptz, status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','radar_disabled','neutralized','eliminated')),
 status_until timestamptz, current_encounter_id uuid, joined_at timestamptz DEFAULT now(), consent_given_at timestamptz, consent_anonymize_at timestamptz,
 real_name text, birth_year int, gender text);
CREATE TABLE public.encounters(id uuid primary key default gen_random_uuid(), civil_id uuid references players(id), zombie_id uuid references players(id));
CREATE TABLE public.events (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), player_id uuid NOT NULL REFERENCES players(id), type text NOT NULL, message text NOT NULL,
 related_encounter_id uuid REFERENCES encounters(id), metadata jsonb, created_at timestamptz NOT NULL DEFAULT now());
CREATE FUNCTION public.is_game_active() RETURNS boolean LANGUAGE sql AS $$ SELECT false $$;
CREATE FUNCTION public.find_nearby_opponent(p_player_id uuid, p_opposite_role text) RETURNS TABLE(id uuid) LANGUAGE sql AS $$ SELECT null::uuid $$;
CREATE FUNCTION public.is_inside_zone(p_player_id uuid) RETURNS boolean LANGUAGE sql AS $$ SELECT true $$;
CREATE FUNCTION public.get_nearby_players() RETURNS TABLE(id uuid, nick text, role text, lat double precision, lng double precision, status text, distance_meters double precision) LANGUAGE sql AS $$ SELECT null::uuid,null,null,null::float8,null::float8,null,null::float8 WHERE false $$;
CREATE VIEW public.nearby_players WITH (security_invoker=true) AS SELECT id,nick,role,lat,lng,status,distance_meters FROM get_nearby_players();
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated; GRANT USAGE ON SCHEMA public TO anon, authenticated;
