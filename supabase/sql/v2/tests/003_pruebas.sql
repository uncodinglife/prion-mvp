-- Pruebas funcionales de la 003 (combate v2) sobre la réplica local. NO ejecutar en Supabase.
\set ON_ERROR_STOP 1
SET search_path = public, extensions;
-- tablas que la réplica mínima no tenía completas
INSERT INTO auth.users SELECT ('00000000-0000-0000-0000-00000000000'||i)::uuid, 'u'||i||'@x' FROM generate_series(1,6) i;
INSERT INTO players (id, nick, role) SELECT id, split_part(email,'@',1), 'zombie' FROM auth.users;
CREATE OR REPLACE FUNCTION as_user(n int) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claims', json_build_object('sub','00000000-0000-0000-0000-00000000000'||n)::text, false) $$;
CREATE OR REPLACE FUNCTION uid(n int) RETURNS uuid LANGUAGE sql AS $$ SELECT ('00000000-0000-0000-0000-00000000000'||n)::uuid $$;
GRANT EXECUTE ON FUNCTION as_user(int), uid(int) TO authenticated;
SET ROLE authenticated;
SELECT as_user(1); SELECT create_character('Civil1', 25, 'hombre','verde','negro','media','sanitario','buceo', 41.80, 3.05) IS NOT NULL;
SELECT as_user(2); SELECT create_character('Civil2', 25, 'mujer','verde','negro','media','sanitario','buceo', 41.80, 3.05) IS NOT NULL;
SELECT as_user(3); SELECT create_character('Zombi3', 25, 'mujer','azul','negro','media','docente','buceo', 41.80, 3.05) IS NOT NULL;
RESET ROLE;
UPDATE players SET role='zombie', life=60, life_max=60 WHERE id=uid(3);
-- 4 = jugador v1 civil
UPDATE players SET role='civil' WHERE id=uid(4);

-- 1. Detección: civil 1 y zombie 3 a 10 m, lejos de casa
SET ROLE authenticated;
SELECT as_user(3); SELECT 'z_reporta' t, report_position(41.7700, 3.0300, 8)->>'encounter_id' enc;
SELECT as_user(1); SELECT 'c_reporta' t, (report_position(41.77009, 3.0300, 8)->>'encounter_id') IS NOT NULL enc;
RESET ROLE;
SELECT 'encuentro' t, count(*), bool_and(result IS NULL) FROM encounters;
-- v1 a 5 m no se cruza con v2 (find_nearby_opponent)
UPDATE players SET position=ST_SetSRID(ST_MakePoint(3.0300,41.77004),4326)::geography, position_updated_at=now() WHERE id=uid(4);
SELECT 'v1_no_ve_v2' t, count(*) FROM find_nearby_opponent(uid(4),'zombie');
-- 2. Resolver LUCHAR/PERSEGUIR → zombie −30
UPDATE encounters SET civil_decision='LUCHAR', zombie_decision='PERSEGUIR';
SELECT 'resuelve' t, compute_and_resolve_encounter((SELECT id FROM encounters LIMIT 1));
SELECT 'post' t, nick, life, status, status_until > now() + interval '170 s' cd FROM players WHERE id IN (uid(1),uid(3)) ORDER BY nick;
-- 3. Enfriamiento v2 termina sin partida
UPDATE players SET status_until = now() - interval '1 s', last_effects_at = now() - interval '1 min' WHERE id IN (uid(1),uid(3));
SELECT v2_apply_effects(uid(1)); SELECT v2_apply_effects(uid(3));
SELECT 'cd_fin' t, string_agg(status, ',') FROM players WHERE id IN (uid(1),uid(3));
-- 4. Timeout sin partida activa: zombie 30 vs civil 2 (vida 15). Sin decisiones → HUIR/MORDER → civil −10
UPDATE players SET life=30 WHERE id=uid(3);
UPDATE players SET life=15 WHERE id=uid(2);
UPDATE players SET position=NULL WHERE id=uid(1);
SET ROLE authenticated;
SELECT as_user(2); SELECT (report_position(41.77009, 3.0300, 8)->>'encounter_id') IS NOT NULL;
SELECT as_user(3); SELECT 'enc2' t, (report_position(41.7700, 3.0300, 8)->>'encounter_id') IS NOT NULL;
RESET ROLE;
UPDATE encounters SET started_at = now() - interval '20 s' WHERE result IS NULL;
SELECT 'timeouts' t, apply_timeouts();
SELECT 'post_timeout' t, nick, life, status FROM players WHERE id IN (uid(2),uid(3)) ORDER BY nick;
-- 5. Conversión en combate: civil 2 (5) cazado HUIR/PERSEGUIR (−20)
UPDATE players SET status='active', status_until=NULL, life=5 WHERE id IN (uid(2));
UPDATE players SET status='active', status_until=NULL WHERE id=uid(3);
SET ROLE authenticated; SELECT as_user(2); SELECT (report_position(41.77009, 3.0300, 8)->>'encounter_id') IS NOT NULL; RESET ROLE;
UPDATE encounters SET civil_decision='HUIR', zombie_decision='PERSEGUIR' WHERE result IS NULL;
SELECT 'conv' t, compute_and_resolve_encounter((SELECT id FROM encounters WHERE result IS NULL))->>'civil_new_life';
SELECT 'convertido' t, role, life, life_max, status FROM players WHERE id=uid(2);
-- 6. Caída en combate: civil 1 vs zombie 3 (vida 30) LUCHAR/PERSEGUIR → −30 → cae
UPDATE players SET status='active', status_until=NULL WHERE id IN (uid(1),uid(3));
UPDATE players SET position=ST_SetSRID(ST_MakePoint(3.0300,41.77009),4326)::geography, position_updated_at=now() WHERE id=uid(1);
UPDATE players SET position=ST_SetSRID(ST_MakePoint(3.0300,41.77),4326)::geography, position_updated_at=now() WHERE id=uid(2);
UPDATE players SET position=NULL WHERE id=uid(2);
SET ROLE authenticated; SELECT as_user(3); SELECT (report_position(41.7700, 3.0300, 8)->>'encounter_id') IS NOT NULL; RESET ROLE;
UPDATE encounters SET civil_decision='LUCHAR', zombie_decision='PERSEGUIR' WHERE result IS NULL;
SELECT compute_and_resolve_encounter((SELECT id FROM encounters WHERE result IS NULL))->>'zombie_neutralized';
SELECT 'caido' t, life, status, down_until > now() + interval '59 min' FROM players WHERE id=uid(3);
SELECT 'eventos' t, type, count(*) FROM events WHERE type IN ('conversion','zombie_down','neutralization','encounter_result') GROUP BY type ORDER BY type;
-- 7. Zombie caído no dispara encuentros
SET ROLE authenticated; SELECT as_user(3); SELECT 'caido_sin_enc' t, report_position(41.7700, 3.0300, 8)->>'encounter_id'; RESET ROLE;
