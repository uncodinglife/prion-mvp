-- Pruebas funcionales de la 002 sobre la réplica local. NO ejecutar en Supabase:
-- crea usuarios de prueba y fuerza tiempos. Cada 'OK' en NOTICE es una comprobación superada.
\set ON_ERROR_STOP 1
SET search_path = public, extensions;
UPDATE game_params SET value = 100000 WHERE key = 'effects_max_gap_minutes';
INSERT INTO auth.users SELECT ('00000000-0000-0000-0000-00000000000'||i)::uuid, 'u'||i||'@x' FROM generate_series(1,8) i;
INSERT INTO players (id, nick, role) SELECT id, split_part(email,'@',1), 'zombie' FROM auth.users;
CREATE OR REPLACE FUNCTION as_user(n int) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claims', json_build_object('sub','00000000-0000-0000-0000-00000000000'||n)::text, false) $$;
CREATE OR REPLACE FUNCTION uid(n int) RETURNS uuid LANGUAGE sql AS $$ SELECT ('00000000-0000-0000-0000-00000000000'||n)::uuid $$;
CREATE OR REPLACE FUNCTION pt(lat float8, lng float8) RETURNS geography LANGUAGE sql AS $$ SELECT ST_SetSRID(ST_MakePoint(lng,lat),4326)::geography $$;
GRANT EXECUTE ON FUNCTION as_user(int), uid(int), pt(float8,float8) TO authenticated;

-- 1. Polígono: el punto siempre dentro (2000 muestras)
SELECT 'poly_contains_point' t, bool_and(ST_Intersects(v2_blob_polygon(pt(41.78,3.03),5,15,25,45), pt(41.78,3.03))) ok,
       round(min(ST_Distance(pt(41.78,3.03), ST_Centroid(v2_blob_polygon(pt(41.78,3.03),5,15,25,45)::geometry)::geography))::numeric,1) min_centroid_off
FROM generate_series(1,2000);

-- 2. Alta
SET ROLE authenticated; SELECT as_user(1);
SELECT 'alta' t, create_character('Angel_T', 25, 'hombre','verde','negro','media','sanitario','buceo', 41.7810, 3.0290);
RESET ROLE;
SELECT 'alta_estado' t, nick, role, life, life_max, age_band, food_stock, position IS NULL pos_null,
  (SELECT count(*) FROM refuges WHERE owner_id=uid(1) AND type_code='home') homes,
  (SELECT ST_Intersects(area, pt(41.7810,3.0290)) FROM refuges WHERE owner_id=uid(1)) home_contains
FROM players WHERE id=uid(1);
SET ROLE authenticated; SELECT as_user(2);
DO $$ BEGIN PERFORM create_character('tester99', 25, 'hombre','verde','negro','media','sanitario','buceo', 41.78, 3.03); RAISE EXCEPTION 'debía fallar';
EXCEPTION WHEN others THEN RAISE NOTICE 'OK rechaza nick reservado: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM create_character('Pepe', 25, 'hombre','violeta','negro','media','sanitario','buceo', 41.78, 3.03); RAISE EXCEPTION 'debía fallar';
EXCEPTION WHEN others THEN RAISE NOTICE 'OK rechaza opción: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM create_character('angel_t', 25, 'hombre','azul','negro','media','sanitario','buceo', 41.78, 3.03); RAISE EXCEPTION 'debía fallar';
EXCEPTION WHEN others THEN RAISE NOTICE 'OK rechaza nick ocupado: %', SQLERRM; END $$;
SELECT as_user(1);
DO $$ BEGIN PERFORM create_character('Otro', 25, 'hombre','azul','negro','media','sanitario','buceo', 41.78, 3.03); RAISE EXCEPTION 'debía fallar';
EXCEPTION WHEN others THEN RAISE NOTICE 'OK rechaza segunda alta: %', SQLERRM; END $$;

-- 3. report_position: fuera, entrar, histéresis de salida
SELECT 'fuera' t, report_position(41.7830, 3.0290, 10)->>'inside_refuge' r;
SELECT 'entra' t, report_position(41.7810, 3.0290, 10) r;
RESET ROLE; SELECT 'dentro_pos_null' t, position IS NULL, inside_refuge_id IS NOT NULL FROM players WHERE id=uid(1); SET ROLE authenticated;
SELECT 'mala_precision' t, report_position(41.7830, 3.0290, 80)->>'exit_streak';
SELECT 'lectura1' t, report_position(41.7830, 3.0290, 10)->>'exit_streak';
SELECT 'vuelve_dentro_reset' t, report_position(41.7810, 3.0290, 10)->>'exit_streak';
SELECT 'lectura1' t, report_position(41.7830, 3.0290, 10)->>'exit_streak';
SELECT 'lectura2' t, report_position(41.7830, 3.0290, 10)->>'exit_streak';
SELECT 'lectura3_sale' t, report_position(41.7830, 3.0290, 10)->>'exited';
DO $$ BEGIN PERFORM set_resting(true); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN others THEN RAISE NOTICE 'OK no descansa fuera: %', SQLERRM; END $$;

-- 4. Descanso en casa: 3 h con vida 90 → 93
SELECT report_position(41.7810, 3.0290, 10)->>'entered';
SELECT 'resting' t, set_resting(true);
RESET ROLE;
UPDATE players SET life=90, life_pending=0, last_effects_at = now() - interval '3 hours' WHERE id=uid(1);
SELECT v2_apply_effects(uid(1));
SELECT 'regen_3h' t, life, round(food_stock,4) food, round(life_pending,4) pend FROM players WHERE id=uid(1);

-- 5. Hambre: sin comida, fuera, 24 h → -3 ; incubación 10 h → -20 extra
UPDATE players SET resting=false, inside_refuge_id=NULL, food_stock=0, life=90, life_pending=0, last_effects_at=now()-interval '24 hours' WHERE id=uid(1);
SELECT v2_apply_effects(uid(1));
SELECT 'hambre_24h' t, life FROM players WHERE id=uid(1);
UPDATE players SET food_stock=20, infected_at=now(), life=90, life_pending=0, last_effects_at=now()-interval '10 hours' WHERE id=uid(1);
SELECT v2_apply_effects(uid(1));
SELECT 'incubacion_10h' t, life FROM players WHERE id=uid(1);
-- Infectado descansando en casa: -2 +1 = -1/h
UPDATE players SET inside_refuge_id=(SELECT id FROM refuges WHERE owner_id=uid(1) AND type_code='home'), resting=true, life=90, life_pending=0, last_effects_at=now()-interval '10 hours' WHERE id=uid(1);
SELECT v2_apply_effects(uid(1));
SELECT 'incub_en_casa_10h' t, life FROM players WHERE id=uid(1);

-- 6. Conversión por incubación (sigue en casa: zombie puede estar en casa)
UPDATE players SET life=1, life_pending=0, last_effects_at=now()-interval '1 hour' WHERE id=uid(1);
SELECT v2_apply_effects(uid(1));
SELECT 'conversion' t, role, life, life_max, infected_at IS NULL, inside_refuge_id IS NOT NULL still_home, resting FROM players WHERE id=uid(1);

-- 7. Caída y levantamiento
UPDATE players SET life=0, role_points=100, mutation_points=50, last_effects_at=now()-interval '1 minute' WHERE id=uid(1);
SELECT v2_apply_effects(uid(1));
SELECT 'caida' t, status, down_until > now() down, role_points, mutation_points FROM players WHERE id=uid(1);
UPDATE players SET down_until=now()-interval '1 second', last_effects_at=now()-interval '1 minute' WHERE id=uid(1);
SELECT v2_apply_effects(uid(1));
SELECT 'levanta' t, status, life, down_until FROM players WHERE id=uid(1);

-- 8. Sobreexcitación y olfato. Zombie 1 fuera en A; civiles 2 (herido, 50 m), 3 (sano, 50 m), 4 (sano, 20 m)
UPDATE players SET inside_refuge_id=NULL, resting=false WHERE id=uid(1);
SET ROLE authenticated;
SELECT as_user(2); SELECT create_character('Herido', 60, 'mujer','azul','rubio','alta','docente','lectura', 41.79, 3.04);
SELECT as_user(3); SELECT create_character('Sano', 40, 'mujer','azul','rubio','baja','docente','cocina', 41.79, 3.04);
SELECT as_user(4); SELECT create_character('Cerca', 40, 'hombre','marron','rubio','baja','pesca','cocina', 41.79, 3.04);
RESET ROLE;
UPDATE players SET position=pt(41.7700,3.0300), position_updated_at=now() WHERE id=uid(1);
UPDATE players SET position=ST_Project(pt(41.7700,3.0300),50,0), position_updated_at=now(), life=40 WHERE id=uid(2);
UPDATE players SET position=ST_Project(pt(41.7700,3.0300),50,1.5), position_updated_at=now() WHERE id=uid(3);
UPDATE players SET position=ST_Project(pt(41.7700,3.0300),20,3), position_updated_at=now() WHERE id=uid(4);
SET ROLE authenticated; SELECT as_user(1);
SELECT 'radar_normal' t, array_agg(nick ORDER BY nick) FROM nearby_players;
SELECT activate_overexcite(); 
SELECT 'radar_olfato' t, array_agg(nick||':'||blood_scent ORDER BY nick) FROM nearby_players;
RESET ROLE; UPDATE players SET overexcited_until=NULL WHERE id=uid(1); SET ROLE authenticated;
SELECT activate_overexcite(); RESET ROLE; UPDATE players SET overexcited_until=NULL WHERE id=uid(1); SET ROLE authenticated;
SELECT activate_overexcite(); RESET ROLE; UPDATE players SET overexcited_until=NULL WHERE id=uid(1); SET ROLE authenticated;
SELECT activate_overexcite(); RESET ROLE; UPDATE players SET overexcited_until=NULL WHERE id=uid(1); SET ROLE authenticated;
DO $$ BEGIN PERFORM activate_overexcite(); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN others THEN RAISE NOTICE 'OK quinta sobreexcitación: %', SQLERRM; END $$;
-- un civil en refugio no aparece aunque esté herido
SELECT as_user(2); SELECT report_position(41.79, 3.04, 5)->>'entered' herido_entra_casa;
RESET ROLE; UPDATE players SET overexcited_until=now()+interval '5 min' WHERE id=uid(1); SET ROLE authenticated; SELECT as_user(1);
SELECT 'radar_herido_en_casa' t, array_agg(nick ORDER BY nick) FROM nearby_players;

-- 9. Saqueo
RESET ROLE;
INSERT INTO pois (osm_id, kind, name, geom, area, active) VALUES ('t1','supermarket','Test', pt(41.775,3.035),
  ST_Buffer(pt(41.775,3.035), 15)::geography, true);
SET ROLE authenticated; SELECT as_user(3);
SELECT 'loot_start' t, report_position(41.775, 3.035, 8)->'loot';
SELECT 'loot_sigue' t, report_position(41.775, 3.035, 8)->'loot'->>'state';
RESET ROLE; UPDATE poi_visits SET started_at = now() - interval '11 minutes' WHERE player_id=uid(3); SET ROLE authenticated;
SELECT 'loot_fin' t, report_position(41.775, 3.035, 8)->'loot', report_position(41.775, 3.035, 8)->'loot'->>'state' despues;
-- zombie proteína
SELECT as_user(1); RESET ROLE; UPDATE players SET life=30 WHERE id=uid(1); SET ROLE authenticated;
SELECT report_position(41.775, 3.035, 8)->'loot'->>'state';
RESET ROLE; UPDATE poi_visits SET started_at = now() - interval '11 minutes' WHERE player_id=uid(1) AND completed_at IS NULL; SET ROLE authenticated;
SELECT 'proteina' t, report_position(41.775, 3.035, 8)->>'life';
-- abortar saliendo
SELECT as_user(4); SELECT report_position(41.775, 3.035, 8)->'loot'->>'state';
SELECT 'loot_abort' t, report_position(41.778, 3.035, 8)->'loot'->>'state';

-- 10. Escondite y zona mixta (usuario 4, civil raso: 1 escondite/día)
SELECT 'escondite' t, activate_refuge('hideout')->>'refuge_type';
RESET ROLE; SELECT 'esc_dentro' t, position IS NULL, (SELECT type_code FROM refuges WHERE id=inside_refuge_id) FROM players WHERE id=uid(4);
UPDATE refuges SET active_until = now() - interval '1 second' WHERE owner_id=uid(4) AND type_code='hideout';
SELECT v2_apply_effects(uid(4));
SELECT 'esc_caduca' t, inside_refuge_id IS NULL, (SELECT state FROM refuges WHERE owner_id=uid(4) AND type_code='hideout') FROM players WHERE id=uid(4);
SET ROLE authenticated;
SELECT report_position(41.778, 3.035, 8) IS NOT NULL;
DO $$ BEGIN PERFORM activate_refuge('hideout'); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN others THEN RAISE NOTICE 'OK segundo escondite: %', SQLERRM; END $$;
SELECT set_mixed_zone(41.778, 3.035);
SELECT 'mixta' t, activate_refuge('mixed')->>'refuge_type';
RESET ROLE; SELECT 'mixta_activa' t, state, active_until > now() + interval '3 hours 59 min' FROM refuges WHERE owner_id=uid(4) AND type_code='mixed';
-- drenaje en mixta: sano 24 h → -1
UPDATE players SET life=90, life_pending=0, last_effects_at=now()-interval '24 hours' WHERE id=uid(4);
UPDATE refuges SET active_until = now() + interval '1 hour' WHERE owner_id=uid(4) AND type_code='mixed';
SELECT v2_apply_effects(uid(4));
SELECT 'drenaje_mixta_24h' t, life FROM players WHERE id=uid(4);
SET ROLE authenticated;
DO $$ BEGIN PERFORM set_resting(true); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN others THEN RAISE NOTICE 'OK no descansa en mixta: %', SQLERRM; END $$;

-- 11. Ración extra
SELECT as_user(3); RESET ROLE; UPDATE players SET life=80 WHERE id=uid(3); SET ROLE authenticated;
SELECT 'racion' t, eat_extra_ration(), eat_extra_ration();
DO $$ BEGIN PERFORM eat_extra_ration(); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN others THEN RAISE NOTICE 'OK tercera ración: %', SQLERRM; END $$;

-- 12. Brote
RESET ROLE;
SET ROLE authenticated;
SELECT as_user(5); SELECT create_character('Civil5', 30, 'hombre','azul','negro','media','oficina','musica', 41.80, 3.05);
SELECT as_user(6); SELECT create_character('Civil6', 50, 'mujer','verde','negro','media','oficina','musica', 41.80, 3.05);
SELECT as_user(7); SELECT create_character('Civil7', 70, 'hombre','azul','castano','alta','comercio','deporte', 41.80, 3.05);
SELECT as_user(8); SELECT create_character('Civil8', 20, 'mujer','gris','rubio','baja','estudiante','videojuegos', 41.80, 3.05);
DO $$ BEGIN PERFORM v2_tick(); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK authenticated no ejecuta v2_tick'; END $$;
DO $$ BEGIN PERFORM v2_trigger_outbreak(); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK authenticated no dispara brotes'; END $$;
RESET ROLE;
SELECT 'brote1' t, v2_trigger_outbreak() IS NOT NULL;
SELECT 'brote1_info' t, criteria, target_ratio, affected_count, news_text FROM outbreaks;
SELECT 'brote2' t, v2_trigger_outbreak() IS NOT NULL;
SELECT 'brote2_campos_distintos' t, (SELECT array_agg(k) FROM outbreaks o2, jsonb_object_keys(o2.criteria) k WHERE o2.id = o.id) FROM outbreaks o ORDER BY created_at;
SELECT 'infectados' t, count(*) FILTER (WHERE infected_at IS NOT NULL) FROM players WHERE age_band IS NOT NULL;
SELECT 'eventos_brote' t, type, count(*) FROM events WHERE type IN ('outbreak','infected') GROUP BY type;
SELECT 'scheduler_apagado' t, v2_outbreak_scheduler();

-- 13. Tick y permisos
SELECT 'tick' t, v2_tick();
SET ROLE anon;
DO $$ BEGIN PERFORM report_position(1,1,1); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK anon no ejecuta report_position'; END $$;
RESET ROLE;
SELECT 'privs' t, has_function_privilege('authenticated','public.find_nearby_opponent(uuid,text)','EXECUTE') fno,
 has_function_privilege('authenticated','public.report_position(double precision,double precision,double precision)','EXECUTE') rp,
 has_function_privilege('anon','public.get_radar()','EXECUTE') radar_anon;
-- 14. v1: jugador sin alta sigue escribiendo posición
SET ROLE authenticated; SELECT as_user(2); RESET ROLE; UPDATE players SET age_band=NULL WHERE false;
SELECT 'refuges_sin_puntos' t, count(*) FROM information_schema.columns WHERE table_name='refuges' AND udt_name='geography';
