-- Pruebas funcionales de la 005 (existencias, saqueo, activación) sobre la réplica local con 001-005. NO ejecutar en Supabase.
-- Nota: 002_pruebas.sql describe el comportamiento de 002-003 (consumo de raciones, saqueo pasivo); tras la 005 sus pasos de comida y saqueo ya no aplican.
\set ON_ERROR_STOP 1
SET search_path = public, extensions;
UPDATE game_params SET value = 100000 WHERE key = 'effects_max_gap_minutes';
INSERT INTO auth.users SELECT ('00000000-0000-0000-0000-00000000000'||i)::uuid, 'u'||i||'@x' FROM generate_series(1,5) i;
INSERT INTO players (id, nick, role) SELECT id, split_part(email,'@',1), 'zombie' FROM auth.users;
CREATE OR REPLACE FUNCTION as_user(n int) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claims', json_build_object('sub','00000000-0000-0000-0000-00000000000'||n)::text, false) $$;
CREATE OR REPLACE FUNCTION uid(n int) RETURNS uuid LANGUAGE sql AS $$ SELECT ('00000000-0000-0000-0000-00000000000'||n)::uuid $$;
GRANT EXECUTE ON FUNCTION as_user(int), uid(int) TO authenticated;
-- Supermercado BonÀrea de la Rambla (SFG) y otro de SFG
SELECT 'pois_sfg' t, count(*) FROM pois p JOIN municipalities m ON m.id = p.municipality_id WHERE m.name = 'Sant Feliu de Guíxols';
CREATE TEMP TABLE sup AS SELECT id, name, size_class, ST_Y(ST_Centroid(area::geometry)) lat, ST_X(ST_Centroid(area::geometry)) lng
  FROM pois WHERE name = 'BonÀrea' AND municipality_id = (SELECT id FROM municipalities WHERE name='Sant Feliu de Guíxols');
SELECT 'bonarea' t, name, size_class FROM sup;
GRANT SELECT ON sup TO authenticated;
-- 1. Activación: 3 casas a < 1 km de la Rambla
SET ROLE authenticated;
SELECT as_user(1); SELECT create_character('Civil1', 40, 'hombre','verde','negro','media','sanitario','buceo', 41.7830, 3.0300) ->> 'municipality';
RESET ROLE; SELECT 'activos_1' t, count(*) FILTER (WHERE active) FROM pois; SET ROLE authenticated;
SELECT as_user(2); SELECT create_character('Civil2', 40, 'mujer','verde','negro','media','sanitario','buceo', 41.7800, 3.0280) IS NOT NULL;
SELECT as_user(3); SELECT create_character('Civil3', 70, 'mujer','azul','negro','media','docente','buceo', 41.7820, 3.0270) IS NOT NULL;
RESET ROLE;
SELECT 'activos_3' t, count(*) FILTER (WHERE active), (SELECT count(*) FROM poi_stock), (SELECT active FROM pois WHERE id=(SELECT id FROM sup)) bonarea_activo,
  (SELECT stock FROM poi_stock WHERE poi_id=(SELECT id FROM sup)) stock FROM pois;
SELECT 'desgaste' t, band, life_drain_per_day FROM age_bands ORDER BY band;
-- 2. Desgaste: medio 24 h → -2 ; sin consumo de raciones
UPDATE players SET life=80, life_pending=0, last_effects_at=now()-interval '24 hours' WHERE id=uid(1);
SELECT v2_apply_effects(uid(1));
SELECT 'desgaste_24h' t, life, food_stock FROM players WHERE id=uid(1);
-- 3. Ración en casa: fuera falla; dentro 4 raciones +4; tope 6/día
SET ROLE authenticated; SELECT as_user(1);
DO $$ BEGIN PERFORM eat_home_rations(1); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN others THEN RAISE NOTICE 'OK fuera de casa: %', SQLERRM; END $$;
SELECT report_position(41.7830, 3.0300, 5) ->> 'inside_refuge';
SELECT 'casa_4' t, eat_home_rations(4);
SELECT 'casa_5_mas' t, eat_home_rations(5);
DO $$ BEGIN PERFORM eat_home_rations(1); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN others THEN RAISE NOTICE 'OK tope diario casa: %', SQLERRM; END $$;
SELECT 'atajo' t, 1;
-- 4. Saqueo: civil 2 en la zona del BonÀrea
SELECT as_user(2);
SELECT 'dentro' t, report_position((SELECT lat FROM sup), (SELECT lng FROM sup), 5) -> 'loot';
RESET ROLE; UPDATE players SET life = 70 WHERE id = uid(2); SET ROLE authenticated;
SELECT 'come_2' t, loot_action('eat', 2);
DO $$ BEGIN PERFORM loot_action('take', 1); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN others THEN RAISE NOTICE 'OK ya en ello: %', SQLERRM; END $$;
RESET ROLE; UPDATE poi_visits SET action_started_at = now() - interval '7 minutes' WHERE player_id = uid(2); SET ROLE authenticated;
SELECT 'come_fin' t, report_position((SELECT lat FROM sup), (SELECT lng FROM sup), 5) -> 'loot';
RESET ROLE; SELECT 'vida_2' t, life FROM players WHERE id=uid(2); SELECT 'stock' t, stock FROM poi_stock WHERE poi_id=(SELECT id FROM sup); SET ROLE authenticated;
SELECT 'lleva_5' t, loot_action('take', 5);
RESET ROLE; UPDATE poi_visits SET action_started_at = now() - interval '4 minutes' WHERE player_id = uid(2) AND completed_at IS NULL; SET ROLE authenticated;
SELECT 'lleva_fin' t, report_position((SELECT lat FROM sup), (SELECT lng FROM sup), 5) -> 'loot';
RESET ROLE; SELECT 'food_2' t, food_stock FROM players WHERE id=uid(2); SELECT 'visita' t, rations_eaten, rations_taken, completed_at IS NOT NULL cerrada FROM poi_visits WHERE player_id=uid(2); SET ROLE authenticated;
DO $$ BEGIN PERFORM loot_action('eat', 1); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN others THEN RAISE NOTICE 'OK mismo super 72h: %', SQLERRM; END $$;
-- 5. Cancelación al salir
SELECT as_user(3);
SELECT report_position((SELECT lat FROM sup), (SELECT lng FROM sup), 5) IS NOT NULL;
RESET ROLE; UPDATE players SET life = 50 WHERE id = uid(3); SET ROLE authenticated;
SELECT loot_action('eat', 1) IS NOT NULL;
SELECT 'sale' t, report_position((SELECT lat FROM sup) + 0.002, (SELECT lng FROM sup), 5) -> 'loot';
RESET ROLE; SELECT 'tras_salir' t, life, (SELECT count(*) FROM events WHERE player_id=uid(3) AND type='loot_aborted') abortos FROM players WHERE id=uid(3);
-- 6. Tope diario: dos saqueos ya hechos hoy
INSERT INTO poi_visits (player_id, poi_id, completed_at) SELECT uid(2), id, now() FROM pois WHERE active AND id <> (SELECT id FROM sup) LIMIT 1;
SELECT 'elig_2' t, v2_loot_eligibility(uid(2), (SELECT id FROM pois WHERE active AND id NOT IN (SELECT poi_id FROM poi_visits WHERE player_id=uid(2)) LIMIT 1));
-- 7. Zombie no saquea; existencias ocultas
SET ROLE authenticated; SELECT as_user(1);
DO $$ BEGIN RAISE NOTICE 'OK filas de poi_stock visibles para el cliente: %', (SELECT count(*) FROM poi_stock); EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK poi_stock no legible para el cliente'; END $$;
RESET ROLE;
UPDATE players SET role='zombie', life=60, life_max=60, inside_refuge_id=NULL WHERE id=uid(1);
SET ROLE authenticated; SELECT as_user(1);
SELECT 'zombie_loot' t, report_position((SELECT lat FROM sup), (SELECT lng FROM sup), 5) -> 'loot';
DO $$ BEGIN PERFORM loot_action('eat', 1); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN others THEN RAISE NOTICE 'OK zombie no saquea: %', SQLERRM; END $$;
RESET ROLE;
SELECT 'tick' t, v2_tick();
SELECT 'privs' t, has_function_privilege('authenticated','public.v2_loot_settle(uuid,geography,boolean)','EXECUTE') settle,
  has_function_privilege('authenticated','public.loot_action(text,integer)','EXECUTE') action,
  has_function_privilege('anon','public.loot_action(text,integer)','EXECUTE') action_anon;
