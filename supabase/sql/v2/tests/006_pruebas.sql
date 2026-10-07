-- Pruebas funcionales de la 006 (combate v6) sobre la réplica local con 001-006. NO ejecutar en Supabase.
-- Base vacía: 00_replica_minima.sql, 001 ... 006, y este archivo. Cada comprobación lanza un error si falla.
\set ON_ERROR_STOP 1
SET search_path = public, extensions;
UPDATE game_params SET value = 100000 WHERE key = 'effects_max_gap_minutes';

-- ---------------------------------------------------------------- utilidades
CREATE OR REPLACE FUNCTION chk(p_label text, p_ok boolean) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FALLA: %', p_label; END IF;
  RETURN 'ok ' || p_label;
END $$;
INSERT INTO auth.users SELECT ('00000000-0000-0000-0000-00000000000'||i)::uuid, 'u'||i||'@x' FROM generate_series(1,6) i;
INSERT INTO players (id, nick, role) SELECT id, split_part(email,'@',1), 'zombie' FROM auth.users;
CREATE OR REPLACE FUNCTION as_user(n int) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claims', json_build_object('sub','00000000-0000-0000-0000-00000000000'||n)::text, false) $$;
CREATE OR REPLACE FUNCTION uid(n int) RETURNS uuid LANGUAGE sql AS $$ SELECT ('00000000-0000-0000-0000-00000000000'||n)::uuid $$;
GRANT EXECUTE ON FUNCTION as_user(int), uid(int) TO authenticated;

-- Tiradas controladas: cola FIFO. Vacía = error (ninguna tirada sin prever).
CREATE TABLE test_rolls (n serial PRIMARY KEY, v float8 NOT NULL);
CREATE OR REPLACE FUNCTION public.v2_combat_roll() RETURNS double precision LANGUAGE plpgsql AS $$
DECLARE v float8; k int;
BEGIN
  SELECT n, test_rolls.v INTO k, v FROM test_rolls ORDER BY n LIMIT 1;
  IF k IS NULL THEN RAISE EXCEPTION 'tirada no prevista'; END IF;
  DELETE FROM test_rolls WHERE n = k;
  RETURN v;
END $$;
CREATE OR REPLACE FUNCTION roll(p float8) RETURNS void LANGUAGE sql AS $$ INSERT INTO test_rolls(v) VALUES (p) $$;

-- Abre ya el asalto pendiente (salta la pausa del pulso).
CREATE OR REPLACE FUNCTION open_now(p_enc uuid) RETURNS void LANGUAGE sql AS $$
  UPDATE combat_rounds SET opens_at = clock_timestamp() - interval '1 s', deadline = clock_timestamp() + interval '30 s'
   WHERE encounter_id = p_enc AND resolved_at IS NULL $$;
-- Vence el plazo del asalto pendiente.
CREATE OR REPLACE FUNCTION expire(p_enc uuid) RETURNS void LANGUAGE sql AS $$
  UPDATE combat_rounds SET opens_at = now() - interval '20 s', deadline = now() - interval '1 s'
   WHERE encounter_id = p_enc AND resolved_at IS NULL $$;
-- Decidir como jugador n (pasa por el rol authenticated, como el cliente).
CREATE OR REPLACE FUNCTION decide_as(n int, a text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE j jsonb;
BEGIN
  PERFORM as_user(n);
  SET LOCAL ROLE authenticated;
  j := combat_decide(a);
  RESET ROLE;
  RETURN j;
END $$;
CREATE OR REPLACE FUNCTION st(n int, p_enc uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE j jsonb;
BEGIN
  PERFORM as_user(n);
  SET LOCAL ROLE authenticated;
  j := combat_state(p_enc);
  RESET ROLE;
  RETURN j;
END $$;
-- Pone a dos jugadores frente a frente y lanza la detección v2.
CREATE OR REPLACE FUNCTION fight(c int, z int) RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
  UPDATE players SET status='active', status_until=NULL, current_encounter_id=NULL, inside_refuge_id=NULL,
         position = ST_SetSRID(ST_MakePoint(3.0300, 41.7760 + CASE WHEN id = uid(c) THEN 0.00005 ELSE 0 END),4326)::geography,
         position_updated_at = now(), last_effects_at = now()
   WHERE id IN (uid(c), uid(z));
  RETURN v2_try_encounter(uid(z));
END $$;
CREATE OR REPLACE FUNCTION rnd(e uuid, r int) RETURNS combat_rounds LANGUAGE sql AS $$
  SELECT * FROM combat_rounds WHERE encounter_id = e AND round = r $$;

-- Personajes: 1 civil joven raso, 2 civil medio (militar), 3 y 5 zombies, 4 civil viejo
SET ROLE authenticated;
SELECT as_user(1); SELECT create_character('Civil1', 25, 'hombre','verde','negro','media','sanitario','buceo', 41.7830, 3.0300) IS NOT NULL;
SELECT as_user(2); SELECT create_character('Militar2', 40, 'mujer','verde','negro','media','seguridad','buceo', 41.7830, 3.0300) IS NOT NULL;
SELECT as_user(3); SELECT create_character('Zombi3', 25, 'mujer','azul','negro','media','docente','buceo', 41.7830, 3.0300) IS NOT NULL;
SELECT as_user(4); SELECT create_character('Civil4', 70, 'hombre','azul','negro','media','docente','buceo', 41.7830, 3.0300) IS NOT NULL;
SELECT as_user(5); SELECT create_character('Zombi5', 25, 'mujer','azul','negro','media','docente','buceo', 41.7830, 3.0300) IS NOT NULL;
RESET ROLE;
UPDATE players SET role='zombie', life=60, life_max=60 WHERE id IN (uid(3), uid(5));
UPDATE players SET rank='militar', combat_gear='weapon' WHERE id = uid(2);

-- ===================================================== 0. Tabla y parámetros
SELECT chk('28 cruces', (SELECT count(*) FROM combat_cells) = 28);
SELECT chk('todo cruce de pulso con fuerza resoluble',
  NOT EXISTS (SELECT 1 FROM combat_cells WHERE kind='pulse' AND base_param IS NOT NULL
               AND base_param NOT IN (SELECT key FROM game_params)));
SELECT chk('caída 10 / se levanta con 10', v2_param('zombie_down_minutes') = 10 AND v2_param('zombie_up_resistance') = 10);
SELECT chk('param viejo eliminado', NOT EXISTS (SELECT 1 FROM game_params WHERE key='zombie_down_index_loss'));

-- ===================================================== 1. Probabilidad = combate_v6.py
\ir 006_probabilidades.sql
SELECT chk('P(pulso) igual al modelo en ' || count(*) || ' casos (máx. dif. ' || max(abs(v2_combat_pulse_prob(stat, base_param, a, gear, band, life, life_max, r, fails, ec, ez, over, cf) - q)) || ')',
  max(abs(v2_combat_pulse_prob(stat, base_param, a, gear, band, life, life_max, r, fails, ec, ez, over, cf) - q)) < 1e-9)
  FROM expected_probs;
-- Referencias del documento: joven sano, asalto 1 -> mano 36 %, disparo 79 %, bloquear 93 %, huir de quien persigue 27 %
SELECT chk('mano 36 %',     round(v2_combat_pulse_prob('golpe', NULL, 'G', 'none',   'joven', 100, 100, 0, 0, 0, 0, false, 1), 2) = 0.36);
SELECT chk('disparo 79 %',  round(v2_combat_pulse_prob('golpe', NULL, 'G', 'weapon', 'joven', 100, 100, 0, 0, 0, 0, false, 1), 2) = 0.79);
SELECT chk('bloquear 93 %', round(v2_combat_pulse_prob('fuerza', 'combat_base_block_bite', 'B', 'none', 'joven', 100, 100, 0, 0, 0, 0, false, 1), 2) = 0.94
                         OR round(v2_combat_pulse_prob('fuerza', 'combat_base_block_bite', 'B', 'none', 'joven', 100, 100, 0, 0, 0, 0, false, 1), 2) = 0.93);
SELECT chk('carrera 27 %',  round(v2_combat_pulse_prob('agil', 'combat_base_flee_chase', 'H', 'none', 'joven', 100, 100, 0, 0, 0, 0, false, 1), 2) = 0.27);

-- ===================================================== 2. Combate completo: bloqueo, mordisco, tiempo agotado
SELECT fight(1, 3) AS e1 \gset
SELECT chk('encuentro v6 con asalto 1 abierto',
  (SELECT combat_version = 6 AND round = 1 FROM encounters WHERE id = :'e1')
  AND (SELECT deadline - opens_at = interval '15 s' FROM combat_rounds WHERE encounter_id = :'e1' AND round = 1));
SELECT chk('los dos quedan enlazados al encuentro', (SELECT count(*) = 2 FROM players WHERE current_encounter_id = :'e1'));
-- El zombie decide; el civil solo sabe que ya ha decidido.
SELECT chk('zombie muerde', (decide_as(3, 'morder')->>'i_decided')::boolean);
SELECT st(1) AS s1 \gset
SELECT chk('civil ve que el rival ya ha elegido, con frase', (:'s1'::jsonb->>'rival_decided')::boolean AND :'s1'::jsonb->>'rival_ready_msg' IS NOT NULL);
SELECT chk('y no ve qué ha elegido', :'s1'::jsonb->'rounds' = '[]'::jsonb AND position('morder' in :'s1') = 0);
SELECT chk('el rival no puede leer combat_rounds', NOT has_table_privilege('authenticated', 'combat_rounds', 'SELECT'));
-- B-M: gana el civil -> boca expuesta, 2/2, punto civil
SELECT roll(0.01);
SELECT decide_as(1, 'bloquear') IS NOT NULL;
SELECT chk('B-M resuelto', (SELECT civil_won AND civil_damage = 2 AND zombie_damage = 2 AND p_civil > 0.9 FROM rnd(:'e1', 1)));
SELECT chk('boca expuesta y punto civil', (SELECT (outcome->>'exp')::boolean FROM rnd(:'e1', 1)) AND (SELECT civil_points = 1 AND round = 2 FROM encounters WHERE id = :'e1'));
-- El cliente lee su fila de encounters con select('*'): ahí no puede haber nada oculto.
SELECT as_user(3); SET ROLE authenticated;
SELECT chk('la fila de encounters que lee el zombie no delata la boca expuesta', position('exp' in (SELECT to_jsonb(e)::text FROM encounters e WHERE id = :'e1')) = 0);
RESET ROLE;
SELECT chk('asalto 2 de 10 s tras 5 s de pulso',
  (SELECT deadline - opens_at = interval '10 s' AND c2.opens_at > r1.resolved_at FROM combat_rounds c2,
     (SELECT resolved_at FROM combat_rounds WHERE encounter_id = :'e1' AND round = 1) r1
   WHERE c2.encounter_id = :'e1' AND c2.round = 2));
SELECT chk('la boca expuesta no se le muestra a nadie', position('mouth' in st(1)::text) = 0 AND position('mouth' in st(3)::text) = 0);
-- Decidir durante el pulso: rechazado
DO $$ BEGIN PERFORM decide_as(1, 'golpear'); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN invalid_parameter_value THEN RAISE NOTICE 'ok decidir en el pulso rechazado'; END $$;
-- G-M (raso): gana el zombie -> 8, infecta, +4 al zombie
SELECT open_now(:'e1');
SELECT roll(0.99);
SELECT decide_as(1, 'golpear') IS NOT NULL;
SELECT decide_as(3, 'morder') IS NOT NULL;
SELECT chk('mordisco: civil 90, infectado', (SELECT life = 100 - 2 - 8 AND infected_at IS NOT NULL FROM players WHERE id = uid(1)));
SELECT chk('zombie 58 - 2 + 4 = 60', (SELECT life = 60 FROM players WHERE id = uid(3)));
SELECT chk('evento de infección', EXISTS (SELECT 1 FROM events WHERE player_id = uid(1) AND type = 'infected'));
SELECT chk('cansancio y experiencia en el pulso del asalto 2',
  (SELECT p_civil FROM rnd(:'e1', 2)) = v2_combat_pulse_prob('golpe', NULL, 'G', 'none', 'joven', 98, 100, 1, 0, 0, 0, false, 1));
-- Asalto 3 (7 s): nadie decide -> huida automática contra muerde: escapa, 5
SELECT chk('asalto 3 de 7 s', (SELECT deadline - opens_at = interval '7 s' FROM rnd(:'e1', 3)));
SELECT expire(:'e1');
SELECT chk('apply_timeouts resuelve el asalto vencido', apply_timeouts() >= 1);
SELECT chk('huida automática', (SELECT civil_action = 'h' AND zombie_action = 'M' AND civil_timed_out AND zombie_timed_out AND civil_damage = 5 FROM rnd(:'e1', 3)));
SELECT chk('combate cerrado por huida', (SELECT result = 'v6_fled' AND civil_damage = 15 AND zombie_damage = 3 FROM encounters WHERE id = :'e1'));
SELECT chk('enfriamientos y experiencia',
  (SELECT status = 'radar_disabled' AND status_until > now() + interval '290 s' AND combats_count = 1 AND current_encounter_id IS NULL FROM players WHERE id = uid(1))
  AND (SELECT status = 'radar_disabled' AND status_until < now() + interval '190 s' AND combats_count = 1 FROM players WHERE id = uid(3)));
SELECT st(1, :'e1') AS s1 \gset
SELECT chk('estado final: pistas de los 3 asaltos', jsonb_array_length(:'s1'::jsonb->'rounds') = 3 AND NOT (:'s1'::jsonb->>'in_combat')::boolean
  AND :'s1'::jsonb->'rounds'->0->>'rival_action' = 'morder');
SELECT chk('el motor v1 no resuelve un combate v6', (SELECT count(*) FROM encounters WHERE id = :'e1') = 1);
DO $$ BEGIN
  UPDATE encounters SET result = NULL, civil_decision='LUCHAR', zombie_decision='MORDER' WHERE combat_version = 6 AND result = 'v6_fled';
  PERFORM compute_and_resolve_encounter((SELECT id FROM encounters WHERE combat_version = 6 LIMIT 1));
  RAISE EXCEPTION 'debía fallar';
EXCEPTION WHEN invalid_parameter_value THEN RAISE NOTICE 'ok guarda del motor v1';
END $$;

-- ===================================================== 3. Militar: disparo, sobreexcitación y tiro a la silla turca
UPDATE players SET role_points = 40, mutation_points = 40 WHERE id = uid(3);
SELECT fight(2, 3) AS e2 \gset
-- Asalto 1: dispara contra quien persigue y falla (le arrolla): el disparo suena igual
SELECT roll(0.999);
SELECT decide_as(2, 'golpear') IS NOT NULL;
SELECT decide_as(3, 'perseguir') IS NOT NULL;
SELECT chk('disparo fallido: ruido, arrollado 5', (SELECT noise AND NOT civil_won AND civil_damage = 5 FROM rnd(:'e2', 1)));
SELECT st(3) AS z \gset
SELECT chk('el zombie ve "golpear" y el estruendo, nunca el arma',
  :'z'::jsonb->'rounds'->0->>'rival_action' = 'golpear' AND (:'z'::jsonb->'rounds'->0->>'noise')::boolean
  AND position('weapon' in :'z') = 0 AND position('gear' in :'z') = 0);
-- Asalto 2: bloquea el mordisco con el zombie sobreexcitado (Fz × 1,25)
SELECT open_now(:'e2');
SELECT roll(0.01);
SELECT decide_as(2, 'bloquear') IS NOT NULL;
SELECT decide_as(3, 'morder') IS NOT NULL;
SELECT chk('sobreexcitación en el pulso siguiente',
  (SELECT p_civil FROM rnd(:'e2', 2)) = v2_combat_pulse_prob('fuerza', 'combat_base_block_bite', 'B', 'weapon', 'medio', 85, 90, 1, 0, 0, 1, true, 1));
-- Asalto 3: dispara mientras vuelve a morder con la boca expuesta -> eliminado
SELECT open_now(:'e2');
SELECT roll(0.01);
SELECT decide_as(2, 'golpear') IS NOT NULL;
SELECT decide_as(3, 'morder') IS NOT NULL;
SELECT chk('tiro a la silla turca', (SELECT eliminated AND zombie_damage > 0 FROM rnd(:'e2', 3)));
SELECT chk('combate: eliminado', (SELECT result = 'v6_eliminated' FROM encounters WHERE id = :'e2'));
SELECT chk('zombie en el suelo 10 min, −50 % poder, −25 % mutación',
  (SELECT life = 0 AND down_until BETWEEN now() + interval '9 min' AND now() + interval '11 min'
          AND role_points = 20 AND mutation_points = 30 AND status = 'neutralized' FROM players WHERE id = uid(3)));
SELECT chk('evento de eliminación', EXISTS (SELECT 1 FROM events WHERE player_id = uid(3) AND type = 'zombie_eliminated'));
-- Un civil raso con arma no elimina (boca expuesta no aprovechable)
-- Un civil raso con arma no elimina: la boca expuesta no le sirve (decidido 04/10)
UPDATE players SET life = 60, down_until = NULL, status = 'active', zombie_recover_until = NULL WHERE id = uid(5);
UPDATE players SET combat_gear = 'weapon', infected_at = NULL WHERE id = uid(1);
SELECT fight(1, 5) AS e2b \gset
SELECT roll(0.01); SELECT decide_as(1, 'bloquear') IS NOT NULL; SELECT decide_as(5, 'morder') IS NOT NULL;
SELECT open_now(:'e2b');
SELECT roll(0.01); SELECT decide_as(1, 'golpear') IS NOT NULL; SELECT decide_as(5, 'morder') IS NOT NULL;
SELECT chk('raso armado con boca expuesta: disparo normal de 16, sin eliminar',
  (SELECT NOT eliminated AND civil_won AND (outcome->>'dz')::int = 16 FROM rnd(:'e2b', 2))
  AND (SELECT result = 'v6_civil_points' FROM encounters WHERE id = :'e2b'));
SELECT chk('regla: solo militar', (SELECT count(*) FROM combat_rounds WHERE eliminated) = 1);
UPDATE players SET combat_gear = 'none' WHERE id = uid(1);

-- ===================================================== 4. Levantarse y recuperarse
-- Cayó hace 20 min: se levantó hace 10 min con 10 -> 20
UPDATE players SET down_until = now() - interval '10 min', last_effects_at = now() - interval '20 min' WHERE id = uid(3);
SELECT v2_apply_effects(uid(3));
SELECT chk('se levanta con 10 y recupera +1/min', (SELECT life = 20 AND status = 'active' AND down_until IS NULL
  AND zombie_recover_until BETWEEN now() + interval '39 min' AND now() + interval '41 min' FROM players WHERE id = uid(3)));
SELECT chk('evento zombie_up', EXISTS (SELECT 1 FROM events WHERE player_id = uid(3) AND type = 'zombie_up'));
-- 30 min más: 50
UPDATE players SET last_effects_at = now() - interval '30 min', zombie_recover_until = now() + interval '10 min' WHERE id = uid(3);
SELECT v2_apply_effects(uid(3));
SELECT chk('recupera 30 en 30 min', (SELECT life = 50 FROM players WHERE id = uid(3)));
-- La ventana acaba: solo cuenta lo que queda dentro (5 min) -> 55, y se cierra
UPDATE players SET last_effects_at = now() - interval '30 min', zombie_recover_until = now() - interval '25 min' WHERE id = uid(3);
SELECT v2_apply_effects(uid(3));
SELECT chk('fin de la ventana: 55 y sin recuperación', (SELECT life = 55 AND zombie_recover_until IS NULL FROM players WHERE id = uid(3)));
-- Sin ventana no recupera (el zombie no regenera)
UPDATE players SET last_effects_at = now() - interval '30 min' WHERE id = uid(3);
SELECT v2_apply_effects(uid(3));
SELECT chk('sin ventana no recupera', (SELECT life = 55 FROM players WHERE id = uid(3)));

-- ===================================================== 5. Carga y agarre
UPDATE players SET life = 60 WHERE id = uid(5);
UPDATE players SET cargo_food = 3, cargo_serum = 3, life = 80, infected_at = NULL WHERE id = uid(4);
SELECT fight(4, 5) AS e3 \gset
-- Asalto 1: bloquea con carga (×0,90 × 0,95), viejo
SELECT roll(0.01);
SELECT decide_as(4, 'bloquear') IS NOT NULL;
SELECT decide_as(5, 'morder') IS NOT NULL;
SELECT chk('penalización de carga en el pulso',
  (SELECT p_civil FROM rnd(:'e3', 1)) = v2_combat_pulse_prob('fuerza', 'combat_base_block_bite', 'B', 'none', 'viejo', 80, 80, 0, 0, 0, (SELECT combats_count FROM players WHERE id = uid(5)), false, 0.855)
  AND (SELECT p_civil FROM rnd(:'e3', 1)) < v2_combat_pulse_prob('fuerza', 'combat_base_block_bite', 'B', 'none', 'viejo', 80, 80, 0, 0, 0, (SELECT combats_count FROM players WHERE id = uid(5)), false, 1));
SELECT chk('perder a puntos no pierde la carga', (SELECT cargo_food = 3 AND cargo_serum = 3 FROM players WHERE id = uid(4)));
-- Asalto 2: bloquea contra agarra -> brazo agarrado
SELECT open_now(:'e3');
SELECT decide_as(4, 'bloquear') IS NOT NULL;
SELECT decide_as(5, 'agarrar') IS NOT NULL;
SELECT chk('brazo agarrado', (SELECT grab = 1 FROM encounters WHERE id = :'e3'));
SELECT chk('el civil ve el agarre', (st(4)->>'grab')::int = 1);
-- Asalto 3: tiempo agotado con un brazo agarrado -> huida automática: escapa, suelta la carga
SELECT expire(:'e3');
SELECT apply_timeouts() >= 1;
SELECT chk('huida automática suelta la carga', (SELECT cargo_lost FROM rnd(:'e3', 3))
  AND (SELECT cargo_food = 0 AND cargo_serum = 0 FROM players WHERE id = uid(4))
  AND EXISTS (SELECT 1 FROM events WHERE player_id = uid(4) AND type = 'cargo_lost'));

-- Dos brazos: huir desactivado; tiempo agotado = forcejeo (provisional)
UPDATE players SET cargo_food = 3 WHERE id = uid(4);
SELECT fight(4, 5) AS e4 \gset
UPDATE combat_rounds SET grab = 2 WHERE encounter_id = :'e4' AND round = 1;
SELECT chk('estado: no puede huir', NOT (st(4)->>'can_flee')::boolean);
DO $$ BEGIN PERFORM decide_as(4, 'huir'); RAISE EXCEPTION 'debía fallar'; EXCEPTION WHEN invalid_parameter_value THEN RAISE NOTICE 'ok huir desactivado con dos brazos'; END $$;
SELECT expire(:'e4');
SELECT roll(0.99);
SELECT apply_timeouts() >= 1;
SELECT chk('dos brazos y tiempo agotado: forcejeo contra el mordisco (pulso grab2), sin huida',
  (SELECT civil_action = 'B' AND zombie_action = 'M' AND grab = 2 AND NOT civil_won AND civil_damage = 12 AND bite FROM rnd(:'e4', 1)));
SELECT chk('forcejeo con dos brazos: pierde la carga', (SELECT cargo_food = 0 FROM players WHERE id = uid(4)));
SELECT expire(:'e4'); SELECT roll(0.99); SELECT apply_timeouts();
SELECT expire(:'e4'); SELECT apply_timeouts();
SELECT chk('e4 cerrado', (SELECT result IS NOT NULL FROM encounters WHERE id = :'e4'));

-- Golpea–agarra con herramienta: el reflejo atrapa el arma
UPDATE players SET combat_gear = 'tool', life = 80 WHERE id = uid(4);
SELECT fight(4, 5) AS e5 \gset
SELECT decide_as(4, 'golpear') IS NOT NULL;
SELECT decide_as(5, 'agarrar') IS NOT NULL;
SELECT chk('arma atrapada', (SELECT cell_variant = 'gear' AND p_civil IS NULL FROM rnd(:'e5', 1))
  AND (SELECT grab = 1 AND zombie_points = 1 FROM encounters WHERE id = :'e5'));
UPDATE combat_rounds SET deadline = now() - interval '1 s' WHERE encounter_id = :'e5' AND resolved_at IS NULL;
SELECT v2_combat_finish(:'e5', 'interrupted', false, false, false, now());

-- ===================================================== 6. Conversión: +4 del mordisco y +10 a cada zombie que le mordió
-- Civil 4 mordido antes por el zombie 3 (registro sintético) y ahora por el 5
UPDATE players SET life = 5, infected_at = now() - interval '1 h', combat_gear = 'none', combats_count = 7, cargo_food = 2 WHERE id = uid(4);
INSERT INTO encounters (id, civil_id, zombie_id, started_at, resolved_at, result, combat_version)
VALUES ('11111111-1111-1111-1111-111111111111', uid(4), uid(3), now() - interval '30 min', now() - interval '30 min', 'v6_fled', 6);
INSERT INTO combat_rounds (encounter_id, round, opens_at, deadline, grab, bite, resolved_at)
VALUES ('11111111-1111-1111-1111-111111111111', 1, now() - interval '30 min', now() - interval '30 min', 0, true, now() - interval '30 min');
UPDATE players SET life = 30 WHERE id = uid(3);
UPDATE players SET life = 40 WHERE id = uid(5);
SELECT fight(4, 5) AS e6 \gset
SELECT roll(0.99);
SELECT decide_as(4, 'golpear') IS NOT NULL;
SELECT decide_as(5, 'morder') IS NOT NULL;
SELECT chk('convertido en combate', (SELECT result = 'v6_converted' FROM encounters WHERE id = :'e6'));
SELECT chk('el civil es zombie: sin carga ni experiencia', (SELECT role = 'zombie' AND life = 60 AND cargo_food = 0 AND combats_count = 0 AND current_encounter_id IS NULL FROM players WHERE id = uid(4)));
SELECT chk('zombie 5: 40 - 2 + 4 + 10 = 52', (SELECT life = 52 FROM players WHERE id = uid(5)));
SELECT chk('zombie 3 (mordió durante la infección): 30 + 10 = 40', (SELECT life = 40 FROM players WHERE id = uid(3)));
SELECT chk('evento de recuperación', (SELECT count(*) FROM events WHERE type = 'zombie_recovered') = 2);

-- ===================================================== 7. Zombie a 0 por golpes (sin arma) cae 10 min
UPDATE players SET role = 'civil', life = 100, life_max = 100, combat_gear = 'tool', infected_at = NULL WHERE id = uid(1);
UPDATE players SET life = 6 WHERE id = uid(5);
SELECT fight(1, 5) AS e7 \gset
SELECT roll(0.01);
SELECT decide_as(1, 'golpear') IS NOT NULL;
SELECT decide_as(5, 'perseguir') IS NOT NULL;
SELECT chk('sorpresa con herramienta: 12 de daño', (SELECT zombie_damage = 6 AND (outcome->>'dz')::int = 12 FROM rnd(:'e7', 1)));
SELECT chk('zombie caído', (SELECT result = 'v6_zombie_down' FROM encounters WHERE id = :'e7')
  AND (SELECT down_until IS NOT NULL AND life = 0 FROM players WHERE id = uid(5)));

-- ===================================================== 8. Permisos y fugas
SELECT chk('anon no decide ni consulta', NOT has_function_privilege('anon', 'combat_decide(text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'combat_state(uuid)', 'EXECUTE'));
SELECT chk('authenticated decide y consulta', has_function_privilege('authenticated', 'combat_decide(text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'combat_state(uuid)', 'EXECUTE'));
SELECT chk('internas cerradas', NOT has_function_privilege('authenticated', 'v2_combat_resolve_round(uuid, timestamptz)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'v2_combat_finish(uuid, text, boolean, boolean, boolean, timestamptz)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'v2_combat_open_round(uuid, integer, integer, timestamptz)', 'EXECUTE'));
DO $$ BEGIN PERFORM st(6, (SELECT id FROM encounters WHERE combat_version = 6 LIMIT 1)); RAISE EXCEPTION 'debía fallar';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'ok encuentro ajeno rechazado'; END $$;
SELECT chk('sin tiradas sobrantes', (SELECT count(*) FROM test_rolls) = 0);
SELECT 'TODAS LAS PRUEBAS DE LA 006 PASAN' AS fin;
