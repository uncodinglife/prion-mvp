-- =====================================================================
-- Prion v2.0 — Migración 002: funciones del servidor del mundo continuo
-- APLICADA en prion-mvp el 02/10/2026 (editor SQL). Crons 7 y 8 activos.
-- Redactada 02/10/2026 sobre el esquema real de prion-mvp (001 aplicada).
-- Probada entera sobre una réplica local (Postgres 16 + PostGIS) antes de
-- aplicarla: alta, histéresis, efectos, saqueo, olfato, brotes, permisos.
--
-- Alcance:
--   1. Alta de personaje (ficha del censo, tramo, life_max, comida, casa).
--   2. report_position: sustituye a la escritura directa de posición.
--      Refugios con histéresis, pérdida de señal, cupos diarios, descanso.
--   3. Efectos continuos (hambre, incubación, drenaje, regeneración,
--      caída y levantamiento del zombie) + tick por pg_cron.
--   4. Saqueo de supermercados y sobreexcitación con olfato de sangre.
--   5. Brotes de infección (manual y programado, apagado por defecto).
--
-- Criterios técnicos (Claude):
--   * Integración perezosa + barrido. Todo efecto continuo se calcula
--     sobre el intervalo [last_effects_at, ahora] en v2_apply_effects().
--     La llaman report_position, las acciones y el tick de 1 minuto. El
--     resultado no depende de cada cuánto corra el tick.
--   * Tope de intervalo (effects_max_gap_minutes). Si el servidor se para
--     (pausa del plan gratuito, caída), al volver no se aplica de golpe
--     una semana de hambre: se pierde ese tiempo, no a los jugadores.
--   * Dentro de un refugio la posición se pone a NULL. Nadie te ve, el
--     motor de encuentros v1 no te encuentra (exige posición) y la base
--     nunca guarda un punto tomado en casa. Solo queda el polígono.
--   * Jugadores v1 (age_band NULL) no se tocan: report_position les
--     escribe la posición igual que antes, y los crons v1 los siguen
--     tratando a ellos y solo a ellos.
--   * Aditiva: sin DROP. La vista nearby_players se amplía con una
--     columna al final (blood_scent); las columnas existentes no cambian.
--
-- Valores PROVISIONAL en game_params: se cambian sin tocar código.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Ajustes de esquema
-- ---------------------------------------------------------------------
-- Precisión: numeric(6,2) redondeaba a 0,00 el consumo por minuto.
ALTER TABLE public.players ALTER COLUMN food_stock TYPE numeric;
ALTER TABLE public.players ALTER COLUMN regen_pending TYPE numeric;
-- Acumulador de vida fraccionaria con signo (regeneración, hambre,
-- incubación, drenaje). El nombre anterior inducía a error.
ALTER TABLE public.players RENAME COLUMN regen_pending TO life_pending;

CREATE INDEX IF NOT EXISTS players_v2_idx ON public.players (id) WHERE age_band IS NOT NULL;
CREATE INDEX IF NOT EXISTS poi_visits_open_idx ON public.poi_visits (player_id)
  WHERE completed_at IS NULL AND aborted_at IS NULL;

INSERT INTO public.game_params (key, value, unit, description) VALUES
  ('radar_radius_m',             25,   'm',        'Radio de radar normal'),
  ('home_offset_min_m',          5,    'm',        'Desplazamiento mínimo del centro del polígono de casa respecto al punto'),
  ('home_offset_max_m',          15,   'm',        'Desplazamiento máximo del centro del polígono de casa'),
  ('home_radius_min_m',          25,   'm',        'Radio mínimo del polígono irregular de casa y zona mixta'),
  ('home_radius_max_m',          45,   'm',        'Radio máximo del polígono irregular de casa y zona mixta'),
  ('hideout_radius_min_m',       10,   'm',        'PROVISIONAL. Radio mínimo del escondite (centrado en el jugador)'),
  ('hideout_radius_max_m',       15,   'm',        'PROVISIONAL. Radio máximo del escondite'),
  ('blob_vertices',              12,   'vértices', 'Vértices del polígono irregular'),
  ('activation_max_position_age_s', 30, 's',       'Antigüedad máxima de la posición para activar un refugio'),
  ('zombie_up_resistance',       60,   'resistencia', 'PROVISIONAL. Resistencia con la que se levanta un zombie caído'),
  ('zombie_refuge_drain',        0,    '0/1',      'PROVISIONAL. 1 = el zombie aletargado en zona mixta pierde resistencia como el civil'),
  ('loot_abort_silence_s',       90,   's',        'Sin lecturas de posición durante este tiempo, el saqueo se aborta'),
  ('effects_max_gap_minutes',    15,   'min',      'Tope de intervalo de efectos continuos (protege de caídas del servidor)'),
  ('outbreak_auto',              0,    '0/1',      'Brotes automáticos. 0 hasta la prueba de v2.0'),
  ('outbreak_min_interval_h',    48,   'h',        'PROVISIONAL. Horas mínimas entre brotes automáticos'),
  ('outbreak_hourly_chance',     0.1,  'prob/h',   'PROVISIONAL. Probabilidad por hora de brote pasado el mínimo (impredecible)'),
  ('outbreak_traits',            2,    'rasgos',   'PROVISIONAL. Rasgos combinados en cada brote'),
  ('outbreak_ratio_min',         0.2,  'fracción', 'PROVISIONAL. Proporción mínima de infectados entre quienes cumplen los rasgos'),
  ('outbreak_ratio_max',         0.5,  'fracción', 'PROVISIONAL. Proporción máxima'),
  ('outbreak_min_civils',        5,    'jugadores','PROVISIONAL. Civiles v2 sanos mínimos para que haya brote')
ON CONFLICT (key) DO NOTHING;

-- Opciones de la ficha del censo. PROVISIONAL: contenido de juego, lo
-- decide Angel; sirven para poder probar el alta.
INSERT INTO public.profile_options (field, value, label) VALUES
  ('sex','hombre','hombre'), ('sex','mujer','mujer'), ('sex','no_consta','no consta'),
  ('eye_color','marron','marrones'), ('eye_color','azul','azules'), ('eye_color','verde','verdes'),
  ('eye_color','gris','grises'), ('eye_color','negro','negros'),
  ('hair_color','negro','negro'), ('hair_color','castano','castaño'), ('hair_color','rubio','rubio'),
  ('hair_color','pelirrojo','pelirrojo'), ('hair_color','canoso','canoso'), ('hair_color','sin_pelo','sin pelo'),
  ('height_band','baja','baja'), ('height_band','media','media'), ('height_band','alta','alta'),
  ('profession','sanitario','sanitaria'), ('profession','docente','docente'), ('profession','hosteleria','hostelería'),
  ('profession','construccion','construcción'), ('profession','comercio','comercio'), ('profession','oficina','oficina'),
  ('profession','pesca','pesca'), ('profession','estudiante','estudiante'), ('profession','jubilado','jubilación'),
  ('profession','seguridad','seguridad'),
  ('hobby','deporte','deporte'), ('hobby','lectura','lectura'), ('hobby','musica','música'),
  ('hobby','cocina','cocina'), ('hobby','videojuegos','videojuegos'), ('hobby','pesca','pesca'),
  ('hobby','montana','montaña'), ('hobby','buceo','buceo'), ('hobby','jardineria','jardinería')
ON CONFLICT (field, value) DO NOTHING;

-- ---------------------------------------------------------------------
-- 1. Utilidades internas (sin EXECUTE para clientes)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_param(p_key text)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE v numeric;
BEGIN
  SELECT value INTO v FROM game_params WHERE key = p_key;
  IF v IS NULL THEN RAISE EXCEPTION 'game_params sin clave %', p_key; END IF;
  RETURN v;
END $$;

-- Día de juego: día local de Europe/Madrid.
CREATE OR REPLACE FUNCTION public.v2_today()
RETURNS date LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT (now() AT TIME ZONE 'Europe/Madrid')::date;
$$;

CREATE OR REPLACE FUNCTION public.v2_event(p_player uuid, p_type text, p_msg text, p_meta jsonb DEFAULT NULL)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  INSERT INTO events (player_id, type, message, metadata) VALUES (p_player, p_type, p_msg, p_meta);
$$;

-- Gasta un uso diario si queda cupo. Atómico. NULL = sin límite.
CREATE OR REPLACE FUNCTION public.v2_use_quota(p_player uuid, p_kind text, p_max integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v smallint;
BEGIN
  IF p_max IS NULL THEN RETURN true; END IF;
  IF p_max <= 0 THEN RETURN false; END IF;
  INSERT INTO daily_usage (player_id, day, kind, used) VALUES (p_player, v2_today(), p_kind, 1)
  ON CONFLICT (player_id, day, kind) DO UPDATE SET used = daily_usage.used + 1
    WHERE daily_usage.used < p_max
  RETURNING used INTO v;
  RETURN v IS NOT NULL;
END $$;

-- Cupo diario de escondites según rol, rango y nivel de evolución.
CREATE OR REPLACE FUNCTION public.v2_hideout_quota(p_player uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
  SELECT COALESCE((
    SELECT l.per_day FROM refuge_limits l JOIN players p ON p.id = p_player
    WHERE l.role = p.role AND l.rank = p.rank AND l.refuge_type = 'hideout'
      AND l.min_level <= p.evolution_level
    ORDER BY l.min_level DESC LIMIT 1), 0);
$$;

-- Polígono irregular "charco de barro". Centro desplazado del punto,
-- radios aleatorios suavizados con los vecinos. Con desplazamiento máximo
-- 15 m, radio mínimo 25 m y 12 vértices, el punto queda siempre dentro
-- (distancia mínima del centro al borde: 25·cos 15º ≈ 24,1 m > 15 m).
-- El punto de entrada no se guarda en ningún sitio.
CREATE OR REPLACE FUNCTION public.v2_blob_polygon(
  p_point geography, p_off_min numeric, p_off_max numeric, p_r_min numeric, p_r_max numeric)
RETURNS geography LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  n int := v2_param('blob_vertices')::int;
  v_center geography;
  r float8[] := ARRAY[]::float8[];
  s float8;
  rot float8 := random() * 2 * pi();
  pts geometry[] := ARRAY[]::geometry[];
  i int;
BEGIN
  v_center := ST_Project(p_point,
    (p_off_min + random() * (p_off_max - p_off_min))::float8, random() * 2 * pi());
  FOR i IN 1..n LOOP
    r := r || (p_r_min + random() * (p_r_max - p_r_min))::float8;
  END LOOP;
  FOR i IN 1..n LOOP
    s := (r[CASE WHEN i = 1 THEN n ELSE i - 1 END] + 2 * r[i] + r[CASE WHEN i = n THEN 1 ELSE i + 1 END]) / 4;
    pts := pts || ST_Project(v_center, s, rot + 2 * pi() * (i - 1) / n)::geometry;
  END LOOP;
  pts := pts || pts[1];
  RETURN ST_MakePolygon(ST_MakeLine(pts))::geography;
END $$;

-- ---------------------------------------------------------------------
-- 2. Transiciones de refugio y de rol (internas)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_enter_refuge(p_player uuid, p_refuge uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE v_type text;
BEGIN
  SELECT type_code INTO v_type FROM refuges WHERE id = p_refuge;
  UPDATE players SET inside_refuge_id = p_refuge, hidden_since = now(), exit_streak = 0,
         position = NULL, position_updated_at = now()
   WHERE id = p_player;
  UPDATE poi_visits SET aborted_at = now()
   WHERE player_id = p_player AND completed_at IS NULL AND aborted_at IS NULL;
  PERFORM v2_event(p_player, 'refuge_enter',
    'Interferencias... la señal se pierde. Estás a cubierto.',
    jsonb_build_object('refuge_type', v_type, 'signal_loss_seconds', v2_param('signal_loss_seconds')));
END $$;

-- p_point: lectura actual al salir caminando; NULL si la salida es
-- forzada (caducidad, conversión). En ese caso la posición se rellena
-- con la siguiente lectura.
CREATE OR REPLACE FUNCTION public.v2_exit_refuge(p_player uuid, p_reason text, p_point geography)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE v_refuge uuid; v_type text; v_msg text;
BEGIN
  SELECT inside_refuge_id INTO v_refuge FROM players WHERE id = p_player;
  IF v_refuge IS NULL THEN RETURN; END IF;
  SELECT type_code INTO v_type FROM refuges WHERE id = v_refuge;
  IF v_type = 'hideout' THEN
    UPDATE refuges SET state = 'spent', active_until = LEAST(COALESCE(active_until, now()), now())
     WHERE id = v_refuge;
  ELSIF v_type = 'mixed' THEN
    UPDATE refuges SET state = 'ready', active_since = NULL, active_until = NULL WHERE id = v_refuge;
  END IF;
  UPDATE players SET inside_refuge_id = NULL, resting = false, hidden_since = NULL, exit_streak = 0,
         position = p_point,
         position_updated_at = CASE WHEN p_point IS NULL THEN position_updated_at ELSE now() END
   WHERE id = p_player;
  v_msg := CASE p_reason
    WHEN 'expired'    THEN 'Se acabó el tiempo a cubierto. Vuelves a estar expuesto.'
    WHEN 'conversion' THEN 'Ya no perteneces a ese refugio.'
    ELSE 'Sales del refugio. Vuelves a estar expuesto.' END;
  PERFORM v2_event(p_player, CASE WHEN p_reason = 'expired' THEN 'refuge_spent' ELSE 'refuge_exit' END,
    v_msg, jsonb_build_object('refuge_type', v_type, 'reason', p_reason));
END $$;

-- Civil v2 a 0 → zombie raso con resistencia completa.
-- La usará también el combate adaptado (migración 003).
CREATE OR REPLACE FUNCTION public.v2_convert_to_zombie(p_player uuid, p_cause text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE v_res smallint := v2_param('zombie_resistance_start')::smallint; v_type text;
BEGIN
  UPDATE players SET role = 'zombie', rank = 'raso', life_max = v_res, life = v_res,
         infected_at = NULL, resting = false, life_pending = 0,
         overexcited_until = NULL, down_until = NULL, status = 'active', status_until = NULL
   WHERE id = p_player;
  SELECT t.code INTO v_type FROM players p JOIN refuges r ON r.id = p.inside_refuge_id
    JOIN refuge_types t ON t.code = r.type_code
   WHERE p.id = p_player AND NOT ('zombie' = ANY (t.allowed_roles));
  IF v_type IS NOT NULL THEN PERFORM v2_exit_refuge(p_player, 'conversion', NULL); END IF;
  UPDATE poi_visits SET aborted_at = now()
   WHERE player_id = p_player AND completed_at IS NULL AND aborted_at IS NULL;
  PERFORM v2_event(p_player, 'conversion',
    'La fiebre te consume y algo distinto despierta en ti. Ahora eres uno de ellos.',
    jsonb_build_object('cause', p_cause));
END $$;

-- ---------------------------------------------------------------------
-- 3. Efectos continuos sobre un jugador v2
--    Civil: consumo de comida, hambre, incubación, drenaje en refugio,
--           regeneración con descanso activado en casa.
--    Zombie: drenaje opcional (zombie_refuge_drain), caída, levantamiento,
--            fin de sobreexcitación.
--    Todos: caducidad de refugios temporales.
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
  v_down_min numeric;
  v_loss numeric;
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
      v_down_min := v2_param('zombie_down_minutes');
      v_loss := v2_param('zombie_down_index_loss');
      UPDATE players SET down_until = p_now + (v_down_min::float8 * interval '1 minute'),
             status = 'neutralized', status_until = p_now + (v_down_min::float8 * interval '1 minute'),
             overexcited_until = NULL,
             role_points = floor(role_points * (1 - v_loss))::int,
             mutation_points = floor(mutation_points * (1 - v_loss))::int
       WHERE id = p_player;
      PERFORM v2_event(p_player, 'zombie_down',
        'Caes. Tu cuerpo no responde y lo que habías ganado se desvanece.',
        jsonb_build_object('minutes', v_down_min));
    END IF;
    IF p.overexcited_until IS NOT NULL AND p.overexcited_until <= p_now THEN
      UPDATE players SET overexcited_until = NULL WHERE id = p_player;
      PERFORM v2_event(p_player, 'overexcite_end', 'La excitación se apaga. El olor de la sangre se pierde.', NULL);
    END IF;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 4. Alta de personaje (authenticated)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_check_option(p_field text, p_value text)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_value IS NULL OR NOT EXISTS (SELECT 1 FROM profile_options WHERE field = p_field AND value = p_value) THEN
    RAISE EXCEPTION 'Valor no válido para %', p_field USING ERRCODE = '22023';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.create_character(
  p_nick text, p_age integer, p_sex text, p_eye_color text, p_hair_color text,
  p_height_band text, p_profession text, p_hobby text,
  p_home_lat double precision, p_home_lng double precision)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_uid uuid := auth.uid();
  p players%ROWTYPE;
  b age_bands%ROWTYPE;
  v_nick text := btrim(p_nick);
  v_home geography;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501'; END IF;
  SELECT * INTO p FROM players WHERE id = v_uid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jugador inexistente'; END IF;
  IF EXISTS (SELECT 1 FROM character_profiles WHERE player_id = v_uid) THEN
    RAISE EXCEPTION 'Ya estás en el censo' USING ERRCODE = '23505';
  END IF;
  IF p.current_encounter_id IS NOT NULL THEN RAISE EXCEPTION 'Estás en un encuentro'; END IF;

  IF v_nick !~ '^[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñÇç._-]{3,20}$' THEN
    RAISE EXCEPTION 'Nick no válido (3-20 caracteres: letras, números, . _ -)' USING ERRCODE = '22023';
  END IF;
  -- Prefijos reservados por el motor v1 (recuentos por tester%).
  IF lower(v_nick) LIKE 'tester%' OR v_nick LIKE '\_%' THEN
    RAISE EXCEPTION 'Nick reservado' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM players WHERE lower(nick) = lower(v_nick) AND id <> v_uid) THEN
    RAISE EXCEPTION 'Nick ocupado' USING ERRCODE = '23505';
  END IF;

  SELECT * INTO b FROM age_bands WHERE p_age BETWEEN min_age AND max_age;
  IF NOT FOUND THEN RAISE EXCEPTION 'Edad fuera de rango' USING ERRCODE = '22023'; END IF;

  PERFORM v2_check_option('sex', p_sex);
  PERFORM v2_check_option('eye_color', p_eye_color);
  PERFORM v2_check_option('hair_color', p_hair_color);
  PERFORM v2_check_option('height_band', p_height_band);
  PERFORM v2_check_option('profession', p_profession);
  PERFORM v2_check_option('hobby', p_hobby);

  IF p_home_lat IS NULL OR p_home_lng IS NULL OR p_home_lat NOT BETWEEN -90 AND 90
     OR p_home_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'Ubicación de casa no válida' USING ERRCODE = '22023';
  END IF;

  INSERT INTO character_profiles (player_id, fictional_age, sex, eye_color, hair_color, height_band, profession, hobby)
  VALUES (v_uid, p_age, p_sex, p_eye_color, p_hair_color, p_height_band, p_profession, p_hobby);

  UPDATE players SET nick = v_nick, role = 'civil', rank = 'raso', status = 'active', status_until = NULL,
         age_band = b.band, life_max = b.life_max, life = b.life_max,
         food_stock = v2_param('food_start'), infected_at = NULL, outbreak_id = NULL,
         evolution_level = 0, evolution_points = 0, role_points = 0, mutation_points = 0,
         inside_refuge_id = NULL, resting = false, hidden_since = NULL, exit_streak = 0,
         life_pending = 0, overexcited_until = NULL, down_until = NULL, last_effects_at = now()
   WHERE id = v_uid;

  -- El punto solo existe dentro de esta llamada.
  v_home := v2_blob_polygon(ST_SetSRID(ST_MakePoint(p_home_lng, p_home_lat), 4326)::geography,
    v2_param('home_offset_min_m'), v2_param('home_offset_max_m'),
    v2_param('home_radius_min_m'), v2_param('home_radius_max_m'));
  INSERT INTO refuges (type_code, owner_id, area) VALUES ('home', v_uid, v_home);

  PERFORM v2_event(v_uid, 'character_created',
    'Censo sanitario-militar completado. Tus datos quedan registrados.', NULL);

  RETURN jsonb_build_object('nick', v_nick, 'age_band', b.band, 'life', b.life_max,
    'life_max', b.life_max, 'food_stock', v2_param('food_start'));
END $$;

-- Zona mixta (trabajo). Se establece una vez; cambiarla queda pendiente
-- de decisión de juego.
CREATE OR REPLACE FUNCTION public.set_mixed_zone(p_lat double precision, p_lng double precision)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501'; END IF;
  PERFORM 1 FROM players WHERE id = v_uid AND age_band IS NOT NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Primero hay que completar el censo'; END IF;
  IF EXISTS (SELECT 1 FROM refuges WHERE owner_id = v_uid AND type_code = 'mixed') THEN
    RAISE EXCEPTION 'La zona mixta ya está establecida' USING ERRCODE = '23505';
  END IF;
  IF p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'Ubicación no válida' USING ERRCODE = '22023';
  END IF;
  INSERT INTO refuges (type_code, owner_id, area) VALUES ('mixed', v_uid,
    v2_blob_polygon(ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
      v2_param('home_offset_min_m'), v2_param('home_offset_max_m'),
      v2_param('home_radius_min_m'), v2_param('home_radius_max_m')));
  RETURN jsonb_build_object('ok', true);
END $$;

-- ---------------------------------------------------------------------
-- 5. report_position (authenticated)
--    Entrada en casa: lectura con precisión <= hysteresis_max_accuracy_m
--      dentro del polígono, sin encuentro en curso.
--    Salida: hysteresis_exit_readings lecturas seguidas con buena
--      precisión a más de hysteresis_exit_buffer_m del polígono. Las
--      lecturas imprecisas no cuentan ni a favor ni en contra.
--    Dentro: la posición queda a NULL; solo se actualiza la hora.
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

  SELECT * INTO p FROM players WHERE id = v_uid;
  SELECT r.type_code INTO v_type FROM refuges r WHERE r.id = p.inside_refuge_id;

  RETURN jsonb_build_object(
    'v2', true, 'role', p.role, 'life', p.life, 'life_max', p.life_max,
    'food_stock', round(COALESCE(p.food_stock, 0), 2),
    'inside_refuge', v_type,
    'entered', v_entered, 'exited', v_exited,
    'signal_loss_seconds', CASE WHEN v_entered THEN v2_param('signal_loss_seconds') END,
    'exit_streak', p.exit_streak, 'resting', p.resting, 'infected', p.infected_at IS NOT NULL,
    'overexcited_until', p.overexcited_until, 'down_until', p.down_until, 'loot', v_loot);
END $$;

-- ---------------------------------------------------------------------
-- 6. Acciones del jugador (authenticated)
-- ---------------------------------------------------------------------
-- Activa zona mixta (estando dentro) o escondite (donde estás).
CREATE OR REPLACE FUNCTION public.activate_refuge(p_type text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_uid uuid := auth.uid();
  p players%ROWTYPE;
  t refuge_types%ROWTYPE;
  v_ref refuges%ROWTYPE;
  v_quota integer;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501'; END IF;
  PERFORM v2_apply_effects(v_uid, now());
  SELECT * INTO p FROM players WHERE id = v_uid FOR UPDATE;
  IF p.age_band IS NULL THEN RAISE EXCEPTION 'Primero hay que completar el censo'; END IF;
  IF p.inside_refuge_id IS NOT NULL THEN RAISE EXCEPTION 'Ya estás a cubierto'; END IF;
  IF p.current_encounter_id IS NOT NULL THEN RAISE EXCEPTION 'No en mitad de un encuentro'; END IF;
  IF p.down_until IS NOT NULL THEN RAISE EXCEPTION 'No puedes moverte'; END IF;
  IF p.position IS NULL OR p.position_updated_at < now() - v2_param('activation_max_position_age_s')::float8 * interval '1 second' THEN
    RAISE EXCEPTION 'Sin posición reciente';
  END IF;

  SELECT * INTO t FROM refuge_types WHERE code = p_type;
  IF NOT FOUND OR p_type NOT IN ('mixed', 'hideout') THEN RAISE EXCEPTION 'Refugio no activable'; END IF;
  IF NOT (p.role = ANY (t.allowed_roles)) OR (t.allowed_ranks IS NOT NULL AND NOT (p.rank = ANY (t.allowed_ranks))) THEN
    RAISE EXCEPTION 'Este refugio no es para ti';
  END IF;

  IF p_type = 'mixed' THEN
    SELECT * INTO v_ref FROM refuges WHERE owner_id = v_uid AND type_code = 'mixed';
    IF NOT FOUND THEN RAISE EXCEPTION 'No tienes zona mixta'; END IF;
    IF NOT ST_Intersects(v_ref.area, p.position) THEN RAISE EXCEPTION 'No estás en tu zona mixta'; END IF;
    IF NOT v2_use_quota(v_uid, 'mixed_activation', t.max_activations_day) THEN
      RAISE EXCEPTION 'No te quedan activaciones hoy';
    END IF;
    UPDATE refuges SET state = 'active', active_since = now(),
           active_until = now() + t.activation_minutes * interval '1 minute'
     WHERE id = v_ref.id;
    v_id := v_ref.id;
  ELSE
    v_quota := v2_hideout_quota(v_uid);
    IF v_quota <= 0 THEN RAISE EXCEPTION 'No puedes esconderte'; END IF;
    SELECT * INTO v_ref FROM refuges WHERE owner_id = v_uid AND type_code = 'hideout'
     ORDER BY created_at DESC LIMIT 1;
    IF FOUND AND v_ref.active_until > now() - v2_param('hideout_reactivate_min')::float8 * interval '1 minute'
       AND ST_Distance(v_ref.area, p.position) < v2_param('hideout_reactivate_m') THEN
      RAISE EXCEPTION 'Demasiado pronto y demasiado cerca del último escondite';
    END IF;
    IF NOT v2_use_quota(v_uid, 'hideout', v_quota) THEN RAISE EXCEPTION 'No te quedan escondites hoy'; END IF;
    DELETE FROM refuges WHERE owner_id = v_uid AND type_code = 'hideout' AND state = 'spent';
    INSERT INTO refuges (type_code, owner_id, area, state, active_since, active_until)
    VALUES ('hideout', v_uid,
      v2_blob_polygon(p.position, 0, 0, v2_param('hideout_radius_min_m'), v2_param('hideout_radius_max_m')),
      'active', now(), now() + t.activation_minutes * interval '1 minute')
    RETURNING id INTO v_id;
  END IF;

  PERFORM v2_enter_refuge(v_uid, v_id);
  RETURN jsonb_build_object('refuge_type', p_type, 'active_until',
    (SELECT active_until FROM refuges WHERE id = v_id),
    'signal_loss_seconds', v2_param('signal_loss_seconds'));
END $$;

CREATE OR REPLACE FUNCTION public.set_resting(p_on boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE v_uid uuid := auth.uid(); p players%ROWTYPE; t refuge_types%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501'; END IF;
  -- Liquida lo acumulado con el estado anterior antes de cambiarlo.
  PERFORM v2_apply_effects(v_uid, now());
  SELECT * INTO p FROM players WHERE id = v_uid FOR UPDATE;
  IF p.age_band IS NULL THEN RAISE EXCEPTION 'Primero hay que completar el censo'; END IF;
  IF p_on = p.resting THEN RETURN jsonb_build_object('resting', p.resting); END IF;
  IF p_on THEN
    SELECT tt.* INTO t FROM refuges r JOIN refuge_types tt ON tt.code = r.type_code WHERE r.id = p.inside_refuge_id;
    IF p.inside_refuge_id IS NULL OR t.life_per_hour <= 0 OR NOT (p.role = ANY (t.regen_roles)) THEN
      RAISE EXCEPTION 'Aquí no puedes descansar';
    END IF;
  END IF;
  UPDATE players SET resting = p_on WHERE id = v_uid;
  PERFORM v2_event(v_uid, CASE WHEN p_on THEN 'rest_start' ELSE 'rest_stop' END,
    CASE WHEN p_on THEN 'Cierras los ojos. El cuerpo empieza a recuperarse.' ELSE 'Dejas de descansar.' END, NULL);
  RETURN jsonb_build_object('resting', p_on);
END $$;

-- Ración extra: +extra_ration_heal de vida, máximo extra_rations_max_day.
CREATE OR REPLACE FUNCTION public.eat_extra_ration()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE v_uid uuid := auth.uid(); p players%ROWTYPE; v_heal int := v2_param('extra_ration_heal')::int;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501'; END IF;
  PERFORM v2_apply_effects(v_uid, now());
  SELECT * INTO p FROM players WHERE id = v_uid FOR UPDATE;
  IF p.age_band IS NULL OR p.role <> 'civil' THEN RAISE EXCEPTION 'Solo civiles'; END IF;
  IF COALESCE(p.food_stock, 0) < 1 THEN RAISE EXCEPTION 'No tienes raciones'; END IF;
  IF p.life >= p.life_max THEN RAISE EXCEPTION 'No lo necesitas ahora'; END IF;
  IF NOT v2_use_quota(v_uid, 'extra_ration', v2_param('extra_rations_max_day')::int) THEN
    RAISE EXCEPTION 'Ya has comido de más hoy';
  END IF;
  UPDATE players SET food_stock = food_stock - 1, life = LEAST(life_max, life + v_heal) WHERE id = v_uid
  RETURNING * INTO p;
  PERFORM v2_event(v_uid, 'food_eaten', 'Comes algo más de la cuenta. Te sienta bien.',
    jsonb_build_object('heal', v_heal));
  RETURN jsonb_build_object('life', p.life, 'food_stock', round(p.food_stock, 2));
END $$;

CREATE OR REPLACE FUNCTION public.activate_overexcite()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE v_uid uuid := auth.uid(); p players%ROWTYPE; v_until timestamptz;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501'; END IF;
  PERFORM v2_apply_effects(v_uid, now());
  SELECT * INTO p FROM players WHERE id = v_uid FOR UPDATE;
  IF p.age_band IS NULL OR p.role <> 'zombie' THEN RAISE EXCEPTION 'Solo zombies'; END IF;
  IF p.down_until IS NOT NULL THEN RAISE EXCEPTION 'No puedes moverte'; END IF;
  IF p.overexcited_until IS NOT NULL AND p.overexcited_until > now() THEN
    RAISE EXCEPTION 'Ya estás sobreexcitado';
  END IF;
  IF NOT v2_use_quota(v_uid, 'overexcite', v2_param('overexcite_uses_day')::int) THEN
    RAISE EXCEPTION 'No te quedan sobreexcitaciones hoy';
  END IF;
  v_until := now() + v2_param('overexcite_minutes')::float8 * interval '1 minute';
  UPDATE players SET overexcited_until = v_until WHERE id = v_uid;
  PERFORM v2_event(v_uid, 'overexcite_start', 'Hueles la sangre. Los heridos no pueden esconderse de ti.',
    jsonb_build_object('until', v_until, 'scent_radius_m', v2_param('overexcite_radar_m')));
  RETURN jsonb_build_object('overexcited_until', v_until);
END $$;

-- ---------------------------------------------------------------------
-- 7. Radar con olfato de sangre
--    Sustituye a get_nearby_players detrás de la vista nearby_players.
--    Quien está en un refugio tiene posición NULL: ni ve ni es visto.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_radar()
RETURNS TABLE(id uuid, nick text, role text, lat double precision, lng double precision,
              status text, distance_meters double precision, blood_scent boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
  WITH me AS (
    SELECT p.id, p.position,
           (p.role = 'zombie' AND p.down_until IS NULL
            AND p.overexcited_until IS NOT NULL AND p.overexcited_until > now()) AS scent
    FROM players p WHERE p.id = auth.uid() AND p.position IS NOT NULL
  ), prm AS (
    SELECT v2_param('radar_radius_m')::float8 AS r, v2_param('overexcite_radar_m')::float8 AS rs,
           v2_param('wounded_fraction') AS wf, v2_param('position_stale_seconds')::float8 AS stale
  )
  SELECT o.id, o.nick, o.role, ST_Y(o.position::geometry), ST_X(o.position::geometry), o.status,
         ST_Distance(o.position, me.position),
         (me.scent AND o.role = 'civil' AND o.life <= prm.wf * o.life_max)
  FROM players o, me, prm
  WHERE o.id <> me.id
    AND o.status = ANY (ARRAY['active','radar_disabled','neutralized'])
    AND o.position IS NOT NULL
    AND o.position_updated_at > now() - prm.stale * interval '1 second'
    AND ST_DWithin(o.position, me.position, CASE WHEN me.scent THEN GREATEST(prm.r, prm.rs) ELSE prm.r END)
    AND (ST_DWithin(o.position, me.position, prm.r)
         OR (me.scent AND o.role = 'civil' AND o.life <= prm.wf * o.life_max));
$$;

CREATE OR REPLACE VIEW public.nearby_players WITH (security_invoker = true) AS
  SELECT id, nick, role, lat, lng, status, distance_meters, blood_scent FROM public.get_radar();

-- ---------------------------------------------------------------------
-- 8. Brotes de infección
--    Se elige un jugador semilla al azar entre los civiles v2 sanos y se
--    toman sus valores en outbreak_traits rasgos (distintos de los del
--    brote anterior: mutación del medicamento). Así la combinación nunca
--    sale vacía. Se infecta una proporción aleatoria de quienes cumplen.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_trigger_outbreak()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_fields text[] := ARRAY['sex','eye_color','hair_color','height_band','profession','hobby','age_band'];
  v_k int := v2_param('outbreak_traits')::int;
  v_last text[];
  v_pool text[];
  v_pick text[];
  v_seed jsonb;
  v_criteria jsonb;
  v_eligible int;
  v_matches int;
  v_ratio numeric;
  v_n int;
  v_id uuid;
  v_news text;
  v_parts text[] := ARRAY[]::text[];
  f text;
  r record;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _ob_pool (id uuid, traits jsonb) ON COMMIT DROP;
  TRUNCATE _ob_pool;
  INSERT INTO _ob_pool
  SELECT p.id, jsonb_build_object('sex', c.sex, 'eye_color', c.eye_color, 'hair_color', c.hair_color,
           'height_band', c.height_band, 'profession', c.profession, 'hobby', c.hobby, 'age_band', p.age_band)
  FROM players p JOIN character_profiles c ON c.player_id = p.id
  WHERE p.role = 'civil' AND p.age_band IS NOT NULL AND p.infected_at IS NULL;

  SELECT count(*) INTO v_eligible FROM _ob_pool;
  IF v_eligible < v2_param('outbreak_min_civils') THEN RETURN NULL; END IF;

  SELECT ARRAY(SELECT jsonb_object_keys(criteria)) INTO v_last FROM outbreaks ORDER BY created_at DESC LIMIT 1;
  SELECT array_agg(x) INTO v_pool FROM unnest(v_fields) x WHERE NOT (x = ANY (COALESCE(v_last, ARRAY[]::text[])));
  IF COALESCE(array_length(v_pool, 1), 0) < v_k THEN v_pool := v_fields; END IF;
  SELECT array_agg(x) INTO v_pick FROM (SELECT x FROM unnest(v_pool) x ORDER BY random() LIMIT v_k) s;

  SELECT traits INTO v_seed FROM _ob_pool ORDER BY random() LIMIT 1;
  SELECT jsonb_object_agg(x, v_seed -> x) INTO v_criteria FROM unnest(v_pick) x;
  SELECT count(*) INTO v_matches FROM _ob_pool WHERE traits @> v_criteria;

  v_ratio := round((v2_param('outbreak_ratio_min')
             + random()::numeric * (v2_param('outbreak_ratio_max') - v2_param('outbreak_ratio_min'))), 3);
  v_n := GREATEST(1, round(v_ratio * v_matches)::int);

  FOREACH f IN ARRAY v_pick LOOP
    v_parts := v_parts || (CASE f
        WHEN 'sex' THEN 'sexo' WHEN 'eye_color' THEN 'ojos' WHEN 'hair_color' THEN 'pelo'
        WHEN 'height_band' THEN 'estatura' WHEN 'profession' THEN 'profesión'
        WHEN 'hobby' THEN 'afición' ELSE 'franja de edad' END
      || ' ' || COALESCE((SELECT label FROM profile_options WHERE field = f AND value = v_criteria ->> f),
                         v_criteria ->> f));
  END LOOP;
  v_news := 'COMUNICADO SANITARIO. El tratamiento ha mutado. Se confirman nuevos casos de infección en la población con '
            || array_to_string(v_parts, ' y ') || '. Se ruega vigilar los síntomas.';

  INSERT INTO outbreaks (criteria, target_ratio, news_text) VALUES (v_criteria, v_ratio, v_news)
  RETURNING id INTO v_id;

  FOR r IN
    UPDATE players SET infected_at = now(), outbreak_id = v_id
     WHERE id IN (SELECT id FROM _ob_pool WHERE traits @> v_criteria ORDER BY random() LIMIT v_n)
    RETURNING id
  LOOP
    PERFORM v2_event(r.id, 'infected',
      'Los síntomas no dejan lugar a dudas: estás infectado. Puedes retrasarlo, pero no evitarlo.',
      jsonb_build_object('outbreak_id', v_id));
  END LOOP;
  UPDATE outbreaks SET affected_count = v_n WHERE id = v_id;

  INSERT INTO events (player_id, type, message, metadata)
  SELECT id, 'outbreak', v_news, jsonb_build_object('outbreak_id', v_id)
  FROM players WHERE age_band IS NOT NULL;

  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.v2_outbreak_scheduler()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE v_last timestamptz;
BEGIN
  IF v2_param('outbreak_auto') <> 1 THEN RETURN NULL; END IF;
  SELECT max(created_at) INTO v_last FROM outbreaks;
  IF v_last IS NOT NULL AND v_last > now() - v2_param('outbreak_min_interval_h')::float8 * interval '1 hour' THEN
    RETURN NULL;
  END IF;
  IF random() >= v2_param('outbreak_hourly_chance') THEN RETURN NULL; END IF;
  RETURN v2_trigger_outbreak();
END $$;

-- ---------------------------------------------------------------------
-- 9. Tick del mundo continuo (pg_cron, cada minuto)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_tick()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE r record; v_count int := 0;
BEGIN
  FOR r IN SELECT id FROM players WHERE age_band IS NOT NULL ORDER BY id LOOP
    PERFORM v2_apply_effects(r.id, now());
    v_count := v_count + 1;
  END LOOP;

  FOR r IN
    UPDATE poi_visits v SET aborted_at = now()
      FROM players p
     WHERE v.player_id = p.id AND v.completed_at IS NULL AND v.aborted_at IS NULL
       AND (p.position_updated_at IS NULL
            OR p.position_updated_at < now() - v2_param('loot_abort_silence_s')::float8 * interval '1 second')
    RETURNING v.player_id
  LOOP
    PERFORM v2_event(r.player_id, 'loot_aborted', 'Perdiste el contacto. El saqueo queda a medias.', NULL);
  END LOOP;

  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------
-- 10. Convivencia con v1: los crons v1 solo tocan jugadores v1.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.regenerate_civils()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions' AS $function$
DECLARE v_count INT;
BEGIN
  IF NOT public.is_game_active() THEN RETURN 0; END IF;
  UPDATE players SET life = life + 1
  WHERE role='civil' AND status='active' AND life > 0 AND life < 10 AND age_band IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.restore_zombies()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions' AS $function$
DECLARE v_count INT;
BEGIN
  IF NOT public.is_game_active() THEN RETURN 0; END IF;
  UPDATE players SET life=10, status='active', status_until=NULL
  WHERE status='neutralized' AND status_until IS NOT NULL AND status_until <= NOW() AND age_band IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

-- ---------------------------------------------------------------------
-- 11. Permisos
--     Internas: sin EXECUTE para nadie salvo el propietario (crons y
--     funciones DEFINER que las llaman).
--     De jugador: solo authenticated.
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  public.v2_param(text), public.v2_today(), public.v2_event(uuid, text, text, jsonb),
  public.v2_use_quota(uuid, text, integer), public.v2_hideout_quota(uuid),
  public.v2_blob_polygon(geography, numeric, numeric, numeric, numeric),
  public.v2_enter_refuge(uuid, uuid), public.v2_exit_refuge(uuid, text, geography),
  public.v2_convert_to_zombie(uuid, text), public.v2_apply_effects(uuid, timestamptz),
  public.v2_check_option(text, text), public.v2_trigger_outbreak(), public.v2_outbreak_scheduler(),
  public.v2_tick()
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  public.create_character(text, integer, text, text, text, text, text, text, double precision, double precision),
  public.set_mixed_zone(double precision, double precision),
  public.report_position(double precision, double precision, double precision),
  public.activate_refuge(text), public.set_resting(boolean), public.eat_extra_ration(),
  public.activate_overexcite(), public.get_radar()
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.create_character(text, integer, text, text, text, text, text, text, double precision, double precision),
  public.set_mixed_zone(double precision, double precision),
  public.report_position(double precision, double precision, double precision),
  public.activate_refuge(text), public.set_resting(boolean), public.eat_extra_ration(),
  public.activate_overexcite(), public.get_radar()
TO authenticated;

-- Fuga: aceptaban un id arbitrario y nearby_players expone ids. El
-- cliente no las usa; las edge functions van con service_role.
REVOKE EXECUTE ON FUNCTION public.find_nearby_opponent(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.is_inside_zone(uuid) FROM PUBLIC, anon, authenticated;
-- Sustituida por get_radar() detrás de la vista.
REVOKE EXECUTE ON FUNCTION public.get_nearby_players() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 12. Crons
-- ---------------------------------------------------------------------
SELECT cron.schedule('prion-v2-tick', '* * * * *', 'SELECT public.v2_tick();');
SELECT cron.schedule('prion-v2-outbreaks', '7 * * * *', 'SELECT public.v2_outbreak_scheduler();');

-- ---------------------------------------------------------------------
-- Aplicado después (02/10/2026), decisiones de juego de Angel:
--   UPDATE game_params SET value = 1 WHERE key = 'zombie_refuge_drain';
--   (zombie_up_resistance = 60 y escondite 10-15 m confirmados.)
-- ---------------------------------------------------------------------
