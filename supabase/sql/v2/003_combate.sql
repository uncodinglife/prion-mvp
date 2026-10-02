-- =====================================================================
-- Prion v2.0 — Migración 003: combate en el mundo continuo
-- APLICADA en prion-mvp el 02/10/2026 (conector de Supabase).
-- Redactada 02/10/2026 sobre el esquema real de prion-mvp (002 aplicada).
--
-- Decisión de juego (Angel, 01/10): mientras no exista combate v2 (v2.3),
-- se usa la tabla de combate v1 con los daños ×10. Esta migración no toca
-- la tabla ni los dados: solo la escala, las consecuencias y el disparo.
--
-- Criterios técnicos (Claude):
--   * Generaciones separadas. Un jugador v2 solo se encuentra con otro v2
--     (con ×10, un v2 eliminaría a un v1 de un golpe). find_nearby_opponent
--     se filtra igual por si alguna vez coincide una partida v1.
--   * Sin partida ni zona para v2. La detección v2 vive en SQL, dentro de
--     report_position (una sola llamada, el servidor decide). La edge
--     function detect_encounter sigue igual para v1.
--   * Sin interbloqueos. El rival se bloquea con SKIP LOCKED: si dos
--     jugadores se detectan a la vez, uno crea el encuentro y el otro lo
--     encuentra hecho en su siguiente lectura.
--   * Consecuencias v2: civil a 0 → v2_convert_to_zombie (resistencia 60);
--     zombie a 0 → caída (v2_zombie_fall), no neutralización de 15 min.
--   * Enfriamiento tras combate: valores de v1 sin escalar por densidad
--     (el /20 de v1 cuenta cuentas tester%). PROVISIONAL en game_params.
--   * apply_timeouts deja de depender de la partida para encuentros v2.
-- =====================================================================

INSERT INTO public.game_params (key, value, unit, description) VALUES
  ('combat_damage_scale',        10,  'factor', 'Multiplicador de los daños de la tabla v1 para jugadores v2 (hasta el combate v2)'),
  ('combat_cooldown_s',          180, 's',      'PROVISIONAL. Radar apagado tras un combate v2'),
  ('combat_flee_cooldown_s',     300, 's',      'PROVISIONAL. Radar apagado del civil tras huida limpia (v2)'),
  ('encounter_position_max_age_s', 30, 's',     'Antigüedad máxima de la posición del rival para disparar un encuentro')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- 1. Caída del zombie (compartida por efectos y combate)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_zombie_fall(p_player uuid, p_now timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_down_min numeric := v2_param('zombie_down_minutes');
  v_loss numeric := v2_param('zombie_down_index_loss');
BEGIN
  UPDATE players SET life = 0, life_pending = 0,
         down_until = p_now + (v_down_min::float8 * interval '1 minute'),
         status = 'neutralized', status_until = p_now + (v_down_min::float8 * interval '1 minute'),
         overexcited_until = NULL,
         role_points = floor(role_points * (1 - v_loss))::int,
         mutation_points = floor(mutation_points * (1 - v_loss))::int
   WHERE id = p_player;
  UPDATE poi_visits SET aborted_at = now()
   WHERE player_id = p_player AND completed_at IS NULL AND aborted_at IS NULL;
  PERFORM v2_event(p_player, 'zombie_down',
    'Caes. Tu cuerpo no responde y lo que habías ganado se desvanece.',
    jsonb_build_object('minutes', v_down_min));
END $$;

-- ---------------------------------------------------------------------
-- 2. Efectos continuos: caída vía helper + fin del enfriamiento v2
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_apply_effects(p_player uuid, p_now timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  p players%ROWTYPE;
  b age_bands%ROWTYPE;
  t refuge_types%ROWTYPE;
  v_active_until timestamptz;
  dt_h numeric;
  v_delta numeric := 0;
  v_food numeric;
  v_rate numeric;
  v_starving_h numeric := 0;
  v_acc numeric;
  v_whole integer;
  v_life integer;
  v_drain_h numeric;
BEGIN
  SELECT * INTO p FROM players WHERE id = p_player FOR UPDATE;
  IF NOT FOUND OR p.age_band IS NULL THEN RETURN; END IF;

  IF p.last_effects_at IS NULL OR p.last_effects_at >= p_now THEN
    UPDATE players SET last_effects_at = GREATEST(COALESCE(p.last_effects_at, p_now), p_now) WHERE id = p_player;
    RETURN;
  END IF;

  dt_h := LEAST(EXTRACT(epoch FROM p_now - p.last_effects_at),
                v2_param('effects_max_gap_minutes') * 60) / 3600.0;

  IF p.inside_refuge_id IS NOT NULL THEN
    SELECT tt.* INTO t FROM refuges r JOIN refuge_types tt ON tt.code = r.type_code
     WHERE r.id = p.inside_refuge_id;
    SELECT active_until INTO v_active_until FROM refuges WHERE id = p.inside_refuge_id;
  END IF;

  -- Drenaje por estado de salud al inicio del intervalo.
  IF p.inside_refuge_id IS NOT NULL
     AND (p.role = 'civil' OR v2_param('zombie_refuge_drain') = 1) THEN
    v_drain_h := CASE
      WHEN p.life <= v2_param('critical_fraction') * p.life_max THEN t.drain_hours_critical
      WHEN p.life <= v2_param('wounded_fraction')  * p.life_max THEN t.drain_hours_wounded
      ELSE t.drain_hours_healthy END;
    IF v_drain_h IS NOT NULL AND v_drain_h > 0 THEN
      v_delta := v_delta - dt_h / v_drain_h;
    END IF;
  END IF;

  v_food := p.food_stock;
  IF p.role = 'civil' THEN
    SELECT * INTO b FROM age_bands WHERE band = p.age_band;
    v_rate := b.food_per_day / 24.0;                       -- raciones por hora
    v_food := COALESCE(v_food, 0);
    IF v_food >= v_rate * dt_h THEN
      v_food := v_food - v_rate * dt_h;
    ELSE
      v_starving_h := dt_h - CASE WHEN v_rate > 0 THEN v_food / v_rate ELSE dt_h END;
      v_food := 0;
    END IF;
    v_delta := v_delta - v2_param('hunger_damage_per_day') / 24.0 * v_starving_h;

    IF p.infected_at IS NOT NULL THEN
      v_delta := v_delta - v2_param('incubation_damage_per_h') * dt_h;
    END IF;

    IF p.inside_refuge_id IS NOT NULL AND p.resting
       AND t.life_per_hour > 0 AND 'civil' = ANY (t.regen_roles) THEN
      v_delta := v_delta + t.life_per_hour * dt_h;
    END IF;
  END IF;

  v_acc := p.life_pending + v_delta;
  v_whole := trunc(v_acc)::integer;
  v_acc := v_acc - v_whole;
  v_life := p.life + v_whole;
  IF v_life >= p.life_max THEN v_life := p.life_max; IF v_acc > 0 THEN v_acc := 0; END IF; END IF;
  IF v_life <= 0 THEN v_life := 0; v_acc := 0; END IF;

  UPDATE players SET life = v_life, life_pending = v_acc, food_stock = v_food, last_effects_at = p_now
   WHERE id = p_player;

  IF p.role = 'civil' AND COALESCE(p.food_stock, 0) > 0 AND v_food = 0 THEN
    PERFORM v2_event(p_player, 'hunger_damage',
      'Se han acabado tus existencias. Sin comida, cada día te debilita más.', NULL);
  END IF;

  -- Caducidad de refugio temporal (zona mixta activada, escondite).
  IF p.inside_refuge_id IS NOT NULL AND v_active_until IS NOT NULL AND v_active_until <= p_now THEN
    PERFORM v2_exit_refuge(p_player, 'expired', NULL);
  END IF;

  -- Fin del enfriamiento tras combate (en v1 lo hace restore_radar, que
  -- solo corre con partida activa).
  IF p.status = 'radar_disabled' AND p.status_until IS NOT NULL AND p.status_until <= p_now THEN
    UPDATE players SET status = 'active', status_until = NULL WHERE id = p_player;
  END IF;

  IF p.role = 'civil' AND v_life = 0 THEN
    PERFORM v2_convert_to_zombie(p_player, CASE WHEN p.infected_at IS NOT NULL THEN 'infection' ELSE 'exhaustion' END);
    RETURN;
  END IF;

  IF p.role = 'zombie' THEN
    IF p.down_until IS NOT NULL AND p.down_until <= p_now THEN
      UPDATE players SET life = LEAST(life_max, v2_param('zombie_up_resistance')::int),
             status = 'active', status_until = NULL, down_until = NULL
       WHERE id = p_player;
      PERFORM v2_event(p_player, 'zombie_up', 'Te levantas. El hambre vuelve a mandar.', NULL);
    ELSIF p.down_until IS NULL AND v_life = 0 THEN
      PERFORM v2_zombie_fall(p_player, p_now);
    END IF;
    IF p.overexcited_until IS NOT NULL AND p.overexcited_until <= p_now THEN
      UPDATE players SET overexcited_until = NULL WHERE id = p_player;
      PERFORM v2_event(p_player, 'overexcite_end', 'La excitación se apaga. El olor de la sangre se pierde.', NULL);
    END IF;
  END IF;
END $$;
-- ---------------------------------------------------------------------
-- 3. Detección de encuentros v2
--    Requisitos de ambos: v2, rol opuesto, status 'active', sin encuentro,
--    fuera de refugio (posición no NULL), en pie, vida > 0. Rival con
--    posición reciente a <= radar_radius_m.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_try_encounter(p_player uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  me players%ROWTYPE;
  v_opp uuid;
  v_id uuid;
  v_civil uuid;
  v_zombie uuid;
BEGIN
  SELECT * INTO me FROM players WHERE id = p_player FOR UPDATE;
  IF me.age_band IS NULL OR me.status <> 'active' OR me.current_encounter_id IS NOT NULL
     OR me.position IS NULL OR me.down_until IS NOT NULL OR me.life <= 0 THEN
    RETURN NULL;
  END IF;

  SELECT o.id INTO v_opp FROM players o
   WHERE o.id <> me.id AND o.age_band IS NOT NULL
     AND o.role <> me.role AND o.status = 'active' AND o.current_encounter_id IS NULL
     AND o.down_until IS NULL AND o.life > 0 AND o.position IS NOT NULL
     AND o.position_updated_at > now() - v2_param('encounter_position_max_age_s')::float8 * interval '1 second'
     AND ST_DWithin(o.position, me.position, v2_param('radar_radius_m')::float8)
   ORDER BY ST_Distance(o.position, me.position)
   LIMIT 1
   FOR UPDATE OF o SKIP LOCKED;
  IF v_opp IS NULL THEN RETURN NULL; END IF;

  v_civil  := CASE WHEN me.role = 'civil' THEN me.id ELSE v_opp END;
  v_zombie := CASE WHEN me.role = 'civil' THEN v_opp ELSE me.id END;

  -- Saqueos en curso se abortan: el combate interrumpe.
  UPDATE poi_visits SET aborted_at = now()
   WHERE player_id IN (v_civil, v_zombie) AND completed_at IS NULL AND aborted_at IS NULL;

  INSERT INTO encounters (civil_id, zombie_id, started_at) VALUES (v_civil, v_zombie, now())
  RETURNING id INTO v_id;
  UPDATE players SET current_encounter_id = v_id WHERE id IN (v_civil, v_zombie);
  INSERT INTO events (player_id, type, message, related_encounter_id) VALUES
    (v_civil, 'encounter_start',
      COALESCE(pick_narrative('detection','civil'), 'Algo se mueve cerca. Enciende el radar.'), v_id),
    (v_zombie, 'encounter_start',
      COALESCE(pick_narrative('detection','zombie'), 'Carne fresca cerca. Acércate.'), v_id);
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- 4. report_position: añade la detección y devuelve encounter_id/status
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_position(
  p_lat double precision, p_lng double precision, p_accuracy double precision DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_uid uuid := auth.uid();
  p players%ROWTYPE;
  v_point geography;
  v_good boolean;
  v_buffer numeric := v2_param('hysteresis_exit_buffer_m');
  v_refuge refuges%ROWTYPE;
  v_rt refuge_types%ROWTYPE;
  v_dist float8;
  v_entered boolean := false;
  v_exited boolean := false;
  v_home refuges%ROWTYPE;
  v_poi bigint;
  v_visit poi_visits%ROWTYPE;
  v_last timestamptz;
  v_loot jsonb := NULL;
  v_reward jsonb;
  v_amount numeric;
  v_type text;
  v_encounter uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501'; END IF;
  IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'Posición no válida' USING ERRCODE = '22023';
  END IF;
  v_point := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;

  SELECT * INTO p FROM players WHERE id = v_uid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jugador inexistente'; END IF;

  -- Jugador v1: mismo comportamiento que la escritura directa.
  IF p.age_band IS NULL THEN
    UPDATE players SET position = v_point, position_updated_at = now() WHERE id = v_uid;
    RETURN jsonb_build_object('v2', false);
  END IF;

  PERFORM v2_apply_effects(v_uid, now());
  SELECT * INTO p FROM players WHERE id = v_uid;

  v_good := p_accuracy IS NOT NULL AND p_accuracy > 0 AND p_accuracy <= v2_param('hysteresis_max_accuracy_m');

  IF p.inside_refuge_id IS NOT NULL THEN
    SELECT * INTO v_refuge FROM refuges WHERE id = p.inside_refuge_id;
    IF v_good THEN
      v_dist := ST_Distance(v_refuge.area, v_point);
      IF v_dist > v_buffer THEN
        IF p.exit_streak + 1 >= v2_param('hysteresis_exit_readings') THEN
          PERFORM v2_exit_refuge(v_uid, 'walked_out', v_point);
          v_exited := true;
        ELSE
          UPDATE players SET exit_streak = exit_streak + 1, position_updated_at = now() WHERE id = v_uid;
        END IF;
      ELSE
        UPDATE players SET exit_streak = 0, position_updated_at = now() WHERE id = v_uid;
      END IF;
    ELSE
      UPDATE players SET position_updated_at = now() WHERE id = v_uid;
    END IF;
  ELSE
    SELECT * INTO v_home FROM refuges WHERE owner_id = v_uid AND type_code = 'home';
    SELECT * INTO v_rt FROM refuge_types WHERE code = 'home';
    IF v_good AND v_home.id IS NOT NULL AND p.current_encounter_id IS NULL
       AND p.role = ANY (v_rt.allowed_roles) AND ST_Intersects(v_home.area, v_point) THEN
      PERFORM v2_enter_refuge(v_uid, v_home.id);
      v_entered := true;
    ELSE
      UPDATE players SET position = v_point, position_updated_at = now() WHERE id = v_uid;
    END IF;
  END IF;

  SELECT * INTO p FROM players WHERE id = v_uid;

  -- Saqueo (solo fuera de refugio, en pie y sin encuentro).
  IF p.inside_refuge_id IS NULL AND p.down_until IS NULL AND p.current_encounter_id IS NULL THEN
    SELECT * INTO v_visit FROM poi_visits
     WHERE player_id = v_uid AND completed_at IS NULL AND aborted_at IS NULL;
    IF v_good THEN
      SELECT id INTO v_poi FROM pois
       WHERE active AND kind = 'supermarket' AND ST_Intersects(area, v_point) ORDER BY id LIMIT 1;
    END IF;

    IF v_visit.id IS NOT NULL THEN
      IF v_poi IS NOT DISTINCT FROM v_visit.poi_id OR NOT v_good
         OR ST_Distance((SELECT area FROM pois WHERE id = v_visit.poi_id), v_point) <= v_buffer THEN
        IF now() - v_visit.started_at >= v2_param('loot_minutes')::float8 * interval '1 minute' THEN
          IF p.role = 'civil' THEN
            v_amount := v2_param('loot_rations');
            UPDATE players SET food_stock = COALESCE(food_stock, 0) + v_amount WHERE id = v_uid;
            v_reward := jsonb_build_object('rations', v_amount);
            PERFORM v2_event(v_uid, 'loot_completed',
              format('Saqueo completado: %s raciones más en tu mochila.', v_amount), v_reward);
          ELSE
            v_amount := v2_param('loot_protein_resistance');
            UPDATE players SET life = LEAST(life_max, life + v_amount::int) WHERE id = v_uid;
            v_reward := jsonb_build_object('resistance', v_amount);
            PERFORM v2_event(v_uid, 'loot_completed',
              'Has encontrado proteína. Tu cuerpo se endurece.', v_reward);
          END IF;
          UPDATE poi_visits SET completed_at = now(), reward = v_reward WHERE id = v_visit.id;
          v_loot := jsonb_build_object('state', 'completed', 'poi_id', v_visit.poi_id, 'reward', v_reward);
        ELSE
          v_loot := jsonb_build_object('state', 'looting', 'poi_id', v_visit.poi_id,
            'remaining_s', ceil(EXTRACT(epoch FROM v_visit.started_at
              + v2_param('loot_minutes')::float8 * interval '1 minute' - now())));
        END IF;
        v_poi := NULL;   -- ya gestionado
      ELSE
        UPDATE poi_visits SET aborted_at = now() WHERE id = v_visit.id;
        PERFORM v2_event(v_uid, 'loot_aborted', 'Te alejas del supermercado. El saqueo queda a medias.', NULL);
        v_loot := jsonb_build_object('state', 'aborted', 'poi_id', v_visit.poi_id);
      END IF;
    END IF;

    IF v_poi IS NOT NULL THEN
      SELECT max(completed_at) INTO v_last FROM poi_visits
       WHERE player_id = v_uid AND poi_id = v_poi AND completed_at IS NOT NULL;
      IF v_last IS NOT NULL AND v_last > now() - v2_param('loot_same_poi_cooldown_h')::float8 * interval '1 hour' THEN
        v_loot := jsonb_build_object('state', 'cooldown', 'poi_id', v_poi,
          'available_at', v_last + v2_param('loot_same_poi_cooldown_h')::float8 * interval '1 hour');
      ELSE
        INSERT INTO poi_visits (player_id, poi_id) VALUES (v_uid, v_poi);
        PERFORM v2_event(v_uid, 'loot_started',
          format('Empiezas a rebuscar. Necesitas %s minutos sin moverte de aquí.', v2_param('loot_minutes')), NULL);
        v_loot := jsonb_build_object('state', 'started', 'poi_id', v_poi,
          'remaining_s', v2_param('loot_minutes') * 60);
      END IF;
    END IF;
  END IF;

  -- Detección de encuentros v2 (sin partida ni zona: mundo continuo).
  IF v_good THEN
    v_encounter := v2_try_encounter(v_uid);
  END IF;

  SELECT * INTO p FROM players WHERE id = v_uid;
  SELECT r.type_code INTO v_type FROM refuges r WHERE r.id = p.inside_refuge_id;

  RETURN jsonb_build_object(
    'v2', true, 'role', p.role, 'life', p.life, 'life_max', p.life_max,
    'food_stock', round(COALESCE(p.food_stock, 0), 2),
    'inside_refuge', v_type,
    'entered', v_entered, 'exited', v_exited,
    'signal_loss_seconds', CASE WHEN v_entered THEN v2_param('signal_loss_seconds') END,
    'exit_streak', p.exit_streak, 'resting', p.resting, 'infected', p.infected_at IS NOT NULL,
    'overexcited_until', p.overexcited_until, 'down_until', p.down_until, 'loot', v_loot,
    'status', p.status, 'status_until', p.status_until,
    'encounter_id', COALESCE(v_encounter, p.current_encounter_id));
END $$;
-- ---------------------------------------------------------------------
-- 5. Motor de combate: rama v2 (×10, conversión v2, caída)
--    La tabla de decisiones y los dados son los de v1, sin cambios.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_and_resolve_encounter(p_encounter_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_enc encounters%ROWTYPE;
  v_civil players%ROWTYPE;
  v_zombie players%ROWTYPE;
  v_cd TEXT; v_zd TEXT; v_result TEXT;
  v_civil_damage INT := 0; v_zombie_damage INT := 0;
  v_dice JSONB := NULL; v_civil_msg TEXT; v_zombie_msg TEXT;
  v_civil_cooldown INT; v_zombie_cooldown INT;
  v_civil_roll INT; v_zombie_roll INT; v_rolls JSONB := '[]'::JSONB;
  v_civil_new_life INT; v_zombie_new_life INT;
  v_civil_converted BOOLEAN := false; v_zombie_neutralized BOOLEAN := false;
  v_situation TEXT;
  v_now TIMESTAMPTZ := NOW();
  v_player_count INT;
  v_density_scale NUMERIC;
  v_v2 BOOLEAN;
  v_scale INT;
BEGIN
  -- Los tiempos base (180s / 300s) se diseñaron para 20 jugadores en la zona.
  -- El test real del 07/08 se jugó con 10 y produjo hasta un 92% de tiempo en
  -- cooldown para algunos jugadores (ver análisis 29/09/2026: hasta 8/10 testers
  -- bloqueados a la vez). Se escala el cooldown a la densidad real de jugadores
  -- activos en vez de fijar un valor único que solo es correcto para 20.
  SELECT COUNT(*) INTO v_player_count FROM players WHERE nick LIKE 'tester%';
  v_density_scale := LEAST(1.0, v_player_count::NUMERIC / 20);
  v_civil_cooldown := GREATEST(45, ROUND(180 * v_density_scale));
  v_zombie_cooldown := GREATEST(45, ROUND(180 * v_density_scale));

  SELECT * INTO v_enc FROM encounters WHERE id = p_encounter_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Encounter not found'; END IF;
  IF v_enc.result IS NOT NULL THEN
    RETURN jsonb_build_object('already_resolved', true);
  END IF;
  v_cd := v_enc.civil_decision; v_zd := v_enc.zombie_decision;
  IF v_cd IS NULL OR v_zd IS NULL THEN
    RAISE EXCEPTION 'Both decisions required (civil=%, zombie=%)', v_cd, v_zd;
  END IF;
  SELECT * INTO v_civil FROM players WHERE id = v_enc.civil_id FOR UPDATE;
  SELECT * INTO v_zombie FROM players WHERE id = v_enc.zombie_id FOR UPDATE;

  -- v2: liquidar efectos pendientes antes de aplicar daño.
  v_v2 := v_civil.age_band IS NOT NULL AND v_zombie.age_band IS NOT NULL;
  IF v_v2 THEN
    PERFORM v2_apply_effects(v_civil.id, v_now);
    PERFORM v2_apply_effects(v_zombie.id, v_now);
    SELECT * INTO v_civil FROM players WHERE id = v_enc.civil_id;
    SELECT * INTO v_zombie FROM players WHERE id = v_enc.zombie_id;
  END IF;

  IF v_cd = 'HUIR' AND v_zd = 'MORDER' THEN
    v_result := 'civil_escaped'; v_civil_damage := 1;
    v_civil_cooldown := GREATEST(75, ROUND(300 * v_density_scale));
    v_situation := 'flee_escape';
  ELSIF v_cd = 'HUIR' AND v_zd = 'PERSEGUIR' THEN
    v_result := 'civil_caught'; v_civil_damage := 2;
    v_situation := 'flee_caught';
  ELSIF v_cd = 'LUCHAR' AND v_zd = 'PERSEGUIR' THEN
    v_result := 'civil_wins_fight'; v_zombie_damage := 3;
    v_situation := 'fight_surprise';
  ELSIF v_cd = 'LUCHAR' AND v_zd = 'MORDER' THEN
    LOOP
      v_civil_roll := floor(random() * 6 + 1)::INT;
      v_zombie_roll := floor(random() * 6 + 1)::INT;
      v_rolls := v_rolls || jsonb_build_object('civil', v_civil_roll, 'zombie', v_zombie_roll);
      EXIT WHEN v_civil_roll <> v_zombie_roll;
    END LOOP;
    IF v_civil_roll > v_zombie_roll THEN
      v_result := 'civil_wins_fight'; v_zombie_damage := 4;
      v_situation := 'fight_clash_civilwin';
    ELSE
      v_result := 'zombie_wins_fight'; v_civil_damage := 4;
      v_situation := 'fight_clash_zombiewin';
    END IF;
    v_dice := jsonb_build_object('rolls', v_rolls,
      'winner', CASE WHEN v_civil_roll > v_zombie_roll THEN 'civil' ELSE 'zombie' END);
  ELSE
    RAISE EXCEPTION 'Invalid decision combination: civil=%, zombie=%', v_cd, v_zd;
  END IF;

  IF v_v2 THEN
    v_scale := v2_param('combat_damage_scale')::int;
    v_civil_damage := v_civil_damage * v_scale;
    v_zombie_damage := v_zombie_damage * v_scale;
    v_zombie_cooldown := v2_param('combat_cooldown_s')::int;
    v_civil_cooldown := CASE WHEN v_result = 'civil_escaped'
      THEN v2_param('combat_flee_cooldown_s')::int ELSE v2_param('combat_cooldown_s')::int END;
  END IF;

  v_civil_msg  := COALESCE(public.pick_narrative(v_situation, 'civil'),  'El encuentro se resuelve.');
  v_zombie_msg := COALESCE(public.pick_narrative(v_situation, 'zombie'), 'El encuentro se resuelve.');

  IF v_dice IS NOT NULL AND jsonb_array_length(v_rolls) > 1 THEN
    v_civil_msg  := v_civil_msg  || ' (resuelto a suerte tras empate)';
    v_zombie_msg := v_zombie_msg || ' (resuelto a suerte tras empate)';
  END IF;

  v_civil_new_life := v_civil.life - v_civil_damage;
  v_zombie_new_life := v_zombie.life - v_zombie_damage;

  IF v_civil_new_life <= 0 THEN
    v_civil_converted := true;
    IF v_v2 THEN
      UPDATE players SET life = 0, current_encounter_id = NULL WHERE id = v_civil.id;
      PERFORM v2_convert_to_zombie(v_civil.id, 'combat');
    ELSE
      UPDATE players SET role='zombie', life=10, status='active',
        status_until=NULL, current_encounter_id=NULL WHERE id=v_civil.id;
    END IF;
  ELSE
    UPDATE players SET life=v_civil_new_life, status='radar_disabled',
      status_until=v_now + (v_civil_cooldown || ' seconds')::INTERVAL,
      current_encounter_id=NULL WHERE id=v_civil.id;
  END IF;

  IF v_zombie_new_life <= 0 THEN
    v_zombie_neutralized := true;
    IF v_v2 THEN
      UPDATE players SET current_encounter_id = NULL WHERE id = v_zombie.id;
      PERFORM v2_zombie_fall(v_zombie.id, v_now);
    ELSE
      UPDATE players SET life=0, status='neutralized',
        status_until=v_now + INTERVAL '15 minutes',
        current_encounter_id=NULL WHERE id=v_zombie.id;
    END IF;
  ELSE
    UPDATE players SET life=v_zombie_new_life, status='radar_disabled',
      status_until=v_now + (v_zombie_cooldown || ' seconds')::INTERVAL,
      current_encounter_id=NULL WHERE id=v_zombie.id;
  END IF;

  UPDATE encounters SET result=v_result, civil_damage=v_civil_damage,
    zombie_damage=v_zombie_damage, dice_roll=v_dice, resolved_at=v_now
  WHERE id=p_encounter_id;

  INSERT INTO events (player_id, type, message, related_encounter_id)
  VALUES (v_civil.id, 'encounter_result', v_civil_msg, p_encounter_id),
         (v_zombie.id, 'encounter_result', v_zombie_msg, p_encounter_id);

  -- En v2 los eventos de conversión y caída los emiten v2_convert_to_zombie
  -- y v2_zombie_fall.
  IF v_civil_converted AND NOT v_v2 THEN
    INSERT INTO events (player_id, type, message, related_encounter_id)
    VALUES (v_civil.id, 'conversion',
      COALESCE(public.pick_narrative('conversion','civil'), 'La fiebre te consume. Ahora formas parte de la horda.'),
      p_encounter_id);
  END IF;
  IF v_zombie_neutralized AND NOT v_v2 THEN
    INSERT INTO events (player_id, type, message, related_encounter_id)
    VALUES (v_zombie.id, 'neutralization',
      COALESCE(public.pick_narrative('neutralization','zombie'), 'Te han derribado. Quedas inerte durante 15 minutos.'),
      p_encounter_id);
  END IF;

  RETURN jsonb_build_object('result', v_result, 'civil_damage', v_civil_damage,
    'zombie_damage', v_zombie_damage, 'dice_roll', v_dice,
    'civil_converted', v_civil_converted, 'zombie_neutralized', v_zombie_neutralized,
    'civil_new_life', (SELECT life FROM players WHERE id = v_civil.id),
    'zombie_new_life', (SELECT life FROM players WHERE id = v_zombie.id));
END;
$function$;

-- ---------------------------------------------------------------------
-- 6. Timeouts: los encuentros v2 se resuelven sin partida activa
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_timeouts()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_enc RECORD; v_resolved_count INT := 0; v_active BOOLEAN := public.is_game_active();
BEGIN
  FOR v_enc IN
    SELECT e.id, e.civil_decision, e.zombie_decision FROM encounters e
      JOIN players c ON c.id = e.civil_id JOIN players z ON z.id = e.zombie_id
    WHERE e.result IS NULL AND e.started_at < NOW() - INTERVAL '16 seconds'
      -- v1: mundo congelado tras el cierre. v2: mundo continuo.
      AND (v_active OR (c.age_band IS NOT NULL AND z.age_band IS NOT NULL))
  LOOP
    IF v_enc.civil_decision IS NULL THEN
      UPDATE encounters SET civil_decision='HUIR', civil_decision_at=NOW(), civil_timed_out=true
      WHERE id=v_enc.id AND civil_decision IS NULL;
    END IF;
    IF v_enc.zombie_decision IS NULL THEN
      UPDATE encounters SET zombie_decision='MORDER', zombie_decision_at=NOW(), zombie_timed_out=true
      WHERE id=v_enc.id AND zombie_decision IS NULL;
    END IF;
    BEGIN
      PERFORM public.compute_and_resolve_encounter(v_enc.id);
      v_resolved_count := v_resolved_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Timeout resolution failed for encounter %: %', v_enc.id, SQLERRM;
    END;
  END LOOP;
  RETURN v_resolved_count;
END;
$function$;

-- ---------------------------------------------------------------------
-- 7. Detección v1: solo entre jugadores de la misma generación
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.find_nearby_opponent(p_player_id uuid, p_opposite_role text)
 RETURNS TABLE(id uuid, nick text, distance_meters double precision)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT
    p.id,
    p.nick,
    ST_Distance(
      p.position::geography,
      (SELECT position FROM players WHERE id = p_player_id)::geography
    ) AS distance_meters
  FROM players p
  WHERE
    p.id != p_player_id
    AND p.role = p_opposite_role
    AND p.status = 'active'
    AND p.current_encounter_id IS NULL
    AND p.life > 0
    AND p.position IS NOT NULL
    AND p.position_updated_at > NOW() - INTERVAL '30 seconds'
    AND (p.age_band IS NULL) = ((SELECT age_band FROM players WHERE id = p_player_id) IS NULL)
    AND ST_DWithin(
      p.position::geography,
      (SELECT position FROM players WHERE id = p_player_id)::geography,
      25
    )
  ORDER BY distance_meters ASC
  LIMIT 1;
$function$;

-- ---------------------------------------------------------------------
-- 8. Permisos (CREATE OR REPLACE conserva los de las funciones existentes)
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.v2_zombie_fall(uuid, timestamptz), public.v2_try_encounter(uuid)
FROM PUBLIC, anon, authenticated;
