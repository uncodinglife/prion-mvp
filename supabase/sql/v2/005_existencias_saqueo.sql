-- =====================================================================
-- Prion v2.0 — Migración 005: existencias, saqueo nuevo y activación
-- Redactada 04/10/2026 sobre el esquema real de prion-mvp (004 aplicada).
--
-- Decisiones de juego (Angel, 04/10):
--   * Todo en puntos de vida. Sobrevivir desgasta vida cada día según el
--     tramo: joven 3, medio 2, mayor 1. Las raciones ya no se consumen solas
--     ni hay daño por hambre: se comen a mano y cada ración da +1 de vida.
--   * En casa: hasta 6 raciones al día de las existencias propias, sin tiempo.
--   * Supermercado: existencias controladas por el servidor (solo
--     "alimentos"); llenas al activarse; agotado sigue activo y vacío. El
--     civil no sabe si hay comida hasta estar dentro.
--   * Saqueo: hasta 3 raciones por saqueo, combinando comer allí (3 min por
--     ración, +1 de vida) y llevárselas a casa (3 min la carga). Máximo 2
--     saqueos al día en supermercados distintos; el mismo supermercado, una
--     vez cada 72 h. Salir de la zona o un ataque cancelan lo que está en
--     curso (el ataque provoca el combate).
--   * La proteína desaparece: los zombies no saquean.
--   * Activación: un supermercado se activa cuando hay al menos 3 jugadores
--     con casa a menos de 1 km; no se desactiva.
--   * Existencias iniciales por cadena (tamaño S/M/L).
--
-- Criterios técnicos (Claude):
--   * Existencias en una tabla aparte sin políticas (poi_stock): la tabla
--     pois es legible por el cliente y delataría si queda comida.
--   * La activación cuenta casas (polígonos), no posiciones en vivo: no
--     depende de quién esté conectado ni guarda dónde está nadie. Se evalúa
--     en cada alta y cada 15 min.
--   * El avance de la acción en curso se asienta en report_position y en el
--     tick (con la última posición, si es reciente), así que termina aunque
--     el móvil deje de enviar unos segundos.
--   * La ración en casa pasa a eat_home_rations(n); eat_extra_ration() se
--     mantiene como atajo de 1 ración para no romper clientes ni usar DROP.
--   * Sin DROP. Parámetros obsoletos se marcan, no se borran.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Parámetros
-- ---------------------------------------------------------------------
UPDATE public.game_params SET value = 1,
  description = 'Vida por cada ración comida (en casa o en el supermercado) — decidido 04/10'
 WHERE key = 'extra_ration_heal';
UPDATE public.game_params SET value = 6,
  description = 'Raciones de casa que se pueden comer al día, dentro de casa y sin tiempo — decidido 04/10'
 WHERE key = 'extra_rations_max_day';
UPDATE public.game_params SET value = 72,
  description = 'Horas antes de volver a saquear el mismo supermercado — decidido 04/10'
 WHERE key = 'loot_same_poi_cooldown_h';
UPDATE public.game_params SET description = 'OBSOLETO (04/10): ya no hay daño por hambre; el desgaste diario va en age_bands.life_drain_per_day'
 WHERE key = 'hunger_damage_per_day';
UPDATE public.game_params SET description = 'OBSOLETO (04/10): sustituido por loot_eat_minutes y loot_take_minutes'
 WHERE key = 'loot_minutes';
UPDATE public.game_params SET description = 'OBSOLETO (04/10): sustituido por loot_rations_per_visit'
 WHERE key = 'loot_rations';
UPDATE public.game_params SET description = 'OBSOLETO (04/10): la proteína desaparece, los zombies no saquean'
 WHERE key = 'loot_protein_resistance';

INSERT INTO public.game_params (key, value, unit, description) VALUES
  ('loot_rations_per_visit',     3,   'raciones', 'Máximo de raciones por saqueo, sumando comidas allí y cargadas para casa'),
  ('loot_eat_minutes',           3,   'min',      'Tiempo para comer una ración en el supermercado'),
  ('loot_take_minutes',          3,   'min',      'Tiempo para cargar las raciones que se lleva a casa (la carga entera)'),
  ('loot_ration_heal',           1,   'vida',     'Vida por ración comida en el supermercado'),
  ('loot_visits_per_day',        2,   'saqueos',  'Saqueos al día (en supermercados distintos)'),
  ('loot_other_poi_cooldown_h',  0,   'h',        'PENDIENTE DE ACLARAR. Horas entre saqueos en supermercados distintos (0 = solo cuenta el máximo diario)'),
  ('loot_settle_max_age_s',      90,  's',        'Antigüedad máxima de la última posición para que el tick dé por buena una acción de saqueo'),
  ('poi_activation_min_players', 3,   'jugadores','Jugadores con casa cerca para activar un supermercado — decidido 04/10'),
  ('poi_activation_radius_m',    1000,'m',        'Radio desde el supermercado para contar casas — decidido 04/10'),
  ('poi_stock_L',                600, 'raciones', 'PROVISIONAL. Existencias iniciales de un supermercado grande'),
  ('poi_stock_M',                300, 'raciones', 'PROVISIONAL. Existencias iniciales de un supermercado mediano'),
  ('poi_stock_S',                150, 'raciones', 'PROVISIONAL. Existencias iniciales de un supermercado pequeño')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- 1. Desgaste diario por tramo (sustituye al consumo de raciones)
-- ---------------------------------------------------------------------
ALTER TABLE public.age_bands RENAME COLUMN food_per_day TO life_drain_per_day;
UPDATE public.age_bands SET life_drain_per_day = CASE band WHEN 'joven' THEN 3 WHEN 'medio' THEN 2 ELSE 1 END;

-- ---------------------------------------------------------------------
-- 2. Tamaño por cadena y existencias (ocultas al cliente)
-- ---------------------------------------------------------------------
ALTER TABLE public.pois ADD COLUMN size_class text NOT NULL DEFAULT 'S'
  CHECK (size_class IN ('S','M','L'));
-- PROVISIONAL: clasificación por cadena; se corrige a mano con un UPDATE.
UPDATE public.pois SET size_class = CASE
  WHEN lower(name) IN ('mercadona','lidl','aldi','esclat','hipermercat esclat','bonpreu',
                       'bonpreu supermercats','sorli') THEN 'L'
  WHEN lower(name) IN ('caprabo','cabrabo','bonàrea','bon area','carrefour market','consum',
                       'maxi dia','eurospar','valvi','gp supermercats','raül girona',
                       'raül girona supermercats') THEN 'M'
  ELSE 'S' END
 WHERE kind = 'supermarket';

CREATE TABLE public.poi_stock (
  poi_id     bigint PRIMARY KEY REFERENCES public.pois(id) ON DELETE CASCADE,
  stock      integer NOT NULL CHECK (stock >= 0),
  stock_max  integer NOT NULL CHECK (stock_max >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
-- Sin políticas: nadie fuera del servidor sabe cuánto queda.
ALTER TABLE public.poi_stock ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------
-- 3. Saqueo: raciones por saqueo y acción en curso
-- ---------------------------------------------------------------------
ALTER TABLE public.poi_visits
  ADD COLUMN rations_eaten     smallint NOT NULL DEFAULT 0,
  ADD COLUMN rations_taken     smallint NOT NULL DEFAULT 0,
  ADD COLUMN action            text CHECK (action IN ('eat','take')),
  ADD COLUMN action_count      smallint,
  ADD COLUMN action_started_at timestamptz;
CREATE INDEX poi_visits_player_started_idx ON public.poi_visits (player_id, started_at DESC);

-- Efectos continuos: desgaste diario en vida
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

  IF p.role = 'civil' THEN
    -- Desgaste por sobrevivir (decisión de Angel 04/10): vida por día según el
    -- tramo. Las raciones ya no se consumen solas; se comen a mano y dan vida.
    SELECT * INTO b FROM age_bands WHERE band = p.age_band;
    v_delta := v_delta - b.life_drain_per_day / 24.0 * dt_h;

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

  UPDATE players SET life = v_life, life_pending = v_acc, last_effects_at = p_now
   WHERE id = p_player;

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
-- Activación de supermercados por casas cercanas
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_activate_pois()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_n int := 0;
  v_radius float8 := v2_param('poi_activation_radius_m')::float8;
  v_min int := v2_param('poi_activation_min_players')::int;
  v_stock int;
  r record;
BEGIN
  FOR r IN
    UPDATE pois p SET active = true, activated_at = now()
     WHERE NOT p.active AND p.kind = 'supermarket'
       AND (SELECT count(DISTINCT rf.owner_id) FROM refuges rf JOIN players pl ON pl.id = rf.owner_id
             WHERE rf.type_code = 'home' AND pl.age_band IS NOT NULL
               AND ST_DWithin(rf.area, p.geom, v_radius)) >= v_min
    RETURNING p.id, p.size_class
  LOOP
    v_stock := v2_param('poi_stock_' || r.size_class)::int;
    INSERT INTO poi_stock (poi_id, stock, stock_max) VALUES (r.id, v_stock, v_stock)
    ON CONFLICT (poi_id) DO NOTHING;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

-- ---------------------------------------------------------------------
-- ¿Puede este civil empezar un saqueo en este supermercado?
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_loot_eligibility(p_player uuid, p_poi bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_today int;
  v_last_same timestamptz;
  v_last_other timestamptz;
  v_same_h numeric := v2_param('loot_same_poi_cooldown_h');
  v_other_h numeric := v2_param('loot_other_poi_cooldown_h');
BEGIN
  SELECT count(*) INTO v_today FROM poi_visits
   WHERE player_id = p_player AND (started_at AT TIME ZONE 'Europe/Madrid')::date = v2_today();
  IF v_today >= v2_param('loot_visits_per_day') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'Ya has saqueado dos veces hoy.');
  END IF;
  SELECT max(started_at) INTO v_last_same FROM poi_visits WHERE player_id = p_player AND poi_id = p_poi;
  IF v_last_same IS NOT NULL AND v_last_same > now() - v_same_h::float8 * interval '1 hour' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'Este supermercado ya lo saqueaste hace poco.',
      'available_at', v_last_same + v_same_h::float8 * interval '1 hour');
  END IF;
  IF v_other_h > 0 THEN
    SELECT max(started_at) INTO v_last_other FROM poi_visits WHERE player_id = p_player AND poi_id <> p_poi;
    IF v_last_other IS NOT NULL AND v_last_other > now() - v_other_h::float8 * interval '1 hour' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'Aún es pronto para otro saqueo.',
        'available_at', v_last_other + v_other_h::float8 * interval '1 hour');
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ---------------------------------------------------------------------
-- Asentar el saqueo de un jugador: completa o cancela la acción en curso
-- y describe el supermercado en el que está. p_point NULL = llamada del
-- tick (usa la última posición guardada si es reciente).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_loot_settle(p_player uuid, p_point geography, p_good boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  p players%ROWTYPE;
  v poi_visits%ROWTYPE;
  v_point geography := p_point;
  v_good boolean := COALESCE(p_good, false);
  v_buffer float8 := v2_param('hysteresis_exit_buffer_m')::float8;
  v_per int := v2_param('loot_rations_per_visit')::int;
  v_poi bigint;
  v_poi_name text;
  v_still boolean;
  v_need interval;
  v_n int;
  v_stock int;
  v_heal int;
  v_msg text;
  v_done jsonb := NULL;
  v_res jsonb;
  v_action text;
BEGIN
  SELECT * INTO p FROM players WHERE id = p_player FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;

  IF v_point IS NULL AND p.position IS NOT NULL
     AND p.position_updated_at > now() - v2_param('loot_settle_max_age_s')::float8 * interval '1 second' THEN
    v_point := p.position;
    v_good := true;
  END IF;

  SELECT * INTO v FROM poi_visits WHERE player_id = p_player AND completed_at IS NULL AND aborted_at IS NULL;

  -- Quien no puede estar saqueando cierra el saqueo abierto.
  IF p.age_band IS NULL OR p.role <> 'civil' OR p.inside_refuge_id IS NOT NULL OR p.down_until IS NOT NULL THEN
    IF v.id IS NOT NULL THEN
      UPDATE poi_visits SET completed_at = now(), action = NULL, action_count = NULL, action_started_at = NULL
       WHERE id = v.id;
    END IF;
    RETURN NULL;
  END IF;

  IF v_good AND v_point IS NOT NULL THEN
    SELECT id, name INTO v_poi, v_poi_name FROM pois
     WHERE active AND kind = 'supermarket' AND ST_Intersects(area, v_point) ORDER BY id LIMIT 1;
  END IF;

  IF v.id IS NOT NULL THEN
    IF v_point IS NULL THEN
      v_still := false;
    ELSE
      v_still := v_poi IS NOT DISTINCT FROM v.poi_id OR NOT v_good
                 OR ST_Distance((SELECT area FROM pois WHERE id = v.poi_id), v_point) <= v_buffer;
    END IF;

    IF NOT v_still THEN
      IF v.action IS NOT NULL THEN
        PERFORM v2_event(p_player, 'loot_aborted',
          CASE v.action WHEN 'eat' THEN 'Te vas sin terminar de comer.' ELSE 'Te vas sin cargar las raciones.' END, NULL);
      END IF;
      UPDATE poi_visits SET completed_at = now(), action = NULL, action_count = NULL, action_started_at = NULL
       WHERE id = v.id;
      v.id := NULL;
    ELSIF v.action IS NOT NULL AND p.current_encounter_id IS NULL THEN
      v_need := (CASE v.action WHEN 'eat' THEN v.action_count * v2_param('loot_eat_minutes')
                 ELSE v2_param('loot_take_minutes') END)::float8 * interval '1 minute';
      IF now() - v.action_started_at >= v_need THEN
        v_action := v.action;
        SELECT stock INTO v_stock FROM poi_stock WHERE poi_id = v.poi_id FOR UPDATE;
        v_n := LEAST(v.action_count, COALESCE(v_stock, 0));
        UPDATE poi_stock SET stock = stock - v_n, updated_at = now() WHERE poi_id = v.poi_id;
        IF v.action = 'eat' THEN
          v_heal := v2_param('loot_ration_heal')::int;
          UPDATE players SET life = LEAST(life_max, life + v_n * v_heal) WHERE id = p_player;
          UPDATE poi_visits SET rations_eaten = rations_eaten + v_n,
                 action = NULL, action_count = NULL, action_started_at = NULL
           WHERE id = v.id RETURNING * INTO v;
          v_msg := CASE WHEN v_n = 0 THEN 'No queda nada que comer.'
                   ELSE format('Comes %s %s. Recuperas %s de vida.', v_n,
                        CASE WHEN v_n = 1 THEN 'ración' ELSE 'raciones' END, v_n * v_heal) END;
        ELSE
          UPDATE players SET food_stock = COALESCE(food_stock, 0) + v_n WHERE id = p_player;
          UPDATE poi_visits SET rations_taken = rations_taken + v_n,
                 action = NULL, action_count = NULL, action_started_at = NULL
           WHERE id = v.id RETURNING * INTO v;
          v_msg := CASE WHEN v_n = 0 THEN 'Las estanterías están vacías.'
                   ELSE format('Cargas %s %s para casa.', v_n, CASE WHEN v_n = 1 THEN 'ración' ELSE 'raciones' END) END;
        END IF;
        PERFORM v2_event(p_player, 'loot_completed', v_msg,
          jsonb_build_object('action', v_action, 'rations', v_n));
        v_done := jsonb_build_object('action', v_action, 'message', v_msg, 'rations', v_n);
        IF v.rations_eaten + v.rations_taken >= v_per OR v_n = 0 THEN
          UPDATE poi_visits SET completed_at = now() WHERE id = v.id;
          v.id := NULL;
        END IF;
      END IF;
    END IF;
  END IF;

  IF v_poi IS NULL AND v.id IS NULL THEN
    RETURN CASE WHEN v_done IS NULL THEN NULL ELSE jsonb_build_object('done', v_done) END;
  END IF;

  v_res := jsonb_build_object('poi_id', COALESCE(v.poi_id, v_poi),
    'name', COALESCE(v_poi_name, (SELECT name FROM pois WHERE id = v.poi_id)), 'done', v_done);

  IF v.id IS NOT NULL THEN
    v_res := v_res || jsonb_build_object('visit', jsonb_build_object(
      'eaten', v.rations_eaten, 'taken', v.rations_taken,
      'left', v_per - v.rations_eaten - v.rations_taken,
      'action', v.action, 'action_count', v.action_count,
      'ends_at', CASE WHEN v.action IS NULL THEN NULL ELSE v.action_started_at +
         ((CASE v.action WHEN 'eat' THEN v.action_count * v2_param('loot_eat_minutes')
           ELSE v2_param('loot_take_minutes') END)::float8 * interval '1 minute') END));
  END IF;

  -- Solo dentro del supermercado se sabe si queda comida.
  IF v_poi IS NOT NULL THEN
    v_res := v_res || jsonb_build_object('inside', true,
      'has_food', COALESCE((SELECT stock > 0 FROM poi_stock WHERE poi_id = v_poi), false));
    IF v.id IS NULL THEN
      v_res := v_res || jsonb_build_object('eligibility', v2_loot_eligibility(p_player, v_poi));
    END IF;
  END IF;
  RETURN v_res;
END $$;

-- ---------------------------------------------------------------------
-- Acción de saqueo (authenticated): 'eat' n raciones (3 min cada una) o
-- 'take' n raciones a casa (3 min la carga). Máximo 3 por saqueo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.loot_action(p_action text, p_count integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_uid uuid := auth.uid();
  p players%ROWTYPE;
  v poi_visits%ROWTYPE;
  v_poi bigint;
  v_elig jsonb;
  v_stock int;
  v_per int := v2_param('loot_rations_per_visit')::int;
  v_left int;
  v_n int;
  v_ends timestamptz;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501'; END IF;
  IF p_action NOT IN ('eat', 'take') THEN RAISE EXCEPTION 'Acción no válida'; END IF;
  PERFORM v2_apply_effects(v_uid, now());
  SELECT * INTO p FROM players WHERE id = v_uid FOR UPDATE;
  IF p.age_band IS NULL OR p.role <> 'civil' THEN RAISE EXCEPTION 'Solo civiles'; END IF;
  IF p.inside_refuge_id IS NOT NULL THEN RAISE EXCEPTION 'Estás a cubierto'; END IF;
  IF p.current_encounter_id IS NOT NULL THEN RAISE EXCEPTION 'No en mitad de un encuentro'; END IF;
  IF p.position IS NULL OR p.position_updated_at < now() - v2_param('activation_max_position_age_s')::float8 * interval '1 second' THEN
    RAISE EXCEPTION 'Sin posición reciente';
  END IF;

  SELECT id INTO v_poi FROM pois
   WHERE active AND kind = 'supermarket' AND ST_Intersects(area, p.position) ORDER BY id LIMIT 1;
  IF v_poi IS NULL THEN RAISE EXCEPTION 'No estás en la zona de un supermercado'; END IF;

  SELECT * INTO v FROM poi_visits WHERE player_id = v_uid AND completed_at IS NULL AND aborted_at IS NULL;
  IF v.id IS NOT NULL AND v.poi_id <> v_poi THEN
    UPDATE poi_visits SET completed_at = now(), action = NULL, action_count = NULL, action_started_at = NULL
     WHERE id = v.id;
    v.id := NULL;
  END IF;
  IF v.id IS NOT NULL AND v.action IS NOT NULL THEN RAISE EXCEPTION 'Ya estás en ello'; END IF;

  SELECT stock INTO v_stock FROM poi_stock WHERE poi_id = v_poi;
  IF COALESCE(v_stock, 0) = 0 THEN RAISE EXCEPTION 'Las estanterías están vacías'; END IF;

  IF v.id IS NULL THEN
    v_elig := v2_loot_eligibility(v_uid, v_poi);
    IF NOT (v_elig ->> 'ok')::boolean THEN RAISE EXCEPTION '%', v_elig ->> 'reason'; END IF;
    INSERT INTO poi_visits (player_id, poi_id) VALUES (v_uid, v_poi) RETURNING * INTO v;
  END IF;

  v_left := v_per - v.rations_eaten - v.rations_taken;
  IF v_left <= 0 THEN RAISE EXCEPTION 'Ya has cogido todo lo que podías en este saqueo'; END IF;
  v_n := LEAST(GREATEST(COALESCE(p_count, 1), 1), v_left);
  IF p_action = 'eat' AND p.life >= p.life_max THEN RAISE EXCEPTION 'No lo necesitas ahora'; END IF;

  v_ends := now() + ((CASE p_action WHEN 'eat' THEN v_n * v2_param('loot_eat_minutes')
                      ELSE v2_param('loot_take_minutes') END)::float8 * interval '1 minute');
  UPDATE poi_visits SET action = p_action, action_count = v_n, action_started_at = now() WHERE id = v.id;
  PERFORM v2_event(v_uid, 'loot_started',
    CASE p_action WHEN 'eat' THEN format('Buscas algo que comer. Necesitas %s minutos sin salir de aquí.',
                                         round(EXTRACT(epoch FROM v_ends - now()) / 60))
         ELSE 'Cargas raciones para casa. No te alejes.' END,
    jsonb_build_object('action', p_action, 'rations', v_n, 'ends_at', v_ends));
  RETURN jsonb_build_object('action', p_action, 'count', v_n, 'ends_at', v_ends, 'left_after', v_left - v_n);
END $$;

-- Ración de casa: n raciones de una vez.


-- Ración en casa
CREATE OR REPLACE FUNCTION public.eat_home_rations(p_count integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_uid uuid := auth.uid();
  p players%ROWTYPE;
  v_type text;
  v_heal int := v2_param('extra_ration_heal')::int;
  v_max int := v2_param('extra_rations_max_day')::int;
  v_used int;
  v_n int;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501'; END IF;
  PERFORM v2_apply_effects(v_uid, now());
  SELECT * INTO p FROM players WHERE id = v_uid FOR UPDATE;
  IF p.age_band IS NULL OR p.role <> 'civil' THEN RAISE EXCEPTION 'Solo civiles'; END IF;
  SELECT type_code INTO v_type FROM refuges WHERE id = p.inside_refuge_id;
  IF v_type IS DISTINCT FROM 'home' THEN RAISE EXCEPTION 'Tus raciones están en casa'; END IF;
  IF p_count IS NULL OR p_count < 1 THEN RAISE EXCEPTION 'Número de raciones no válido'; END IF;
  IF COALESCE(p.food_stock, 0) < 1 THEN RAISE EXCEPTION 'No te quedan raciones en casa'; END IF;
  IF p.life >= p.life_max THEN RAISE EXCEPTION 'No lo necesitas ahora'; END IF;
  SELECT COALESCE(used, 0) INTO v_used FROM daily_usage
   WHERE player_id = v_uid AND day = v2_today() AND kind = 'extra_ration';
  v_n := LEAST(p_count, floor(p.food_stock)::int, v_max - COALESCE(v_used, 0));
  IF v_n <= 0 THEN RAISE EXCEPTION 'Ya has comido todo lo que podías hoy'; END IF;
  INSERT INTO daily_usage (player_id, day, kind, used) VALUES (v_uid, v2_today(), 'extra_ration', v_n)
  ON CONFLICT (player_id, day, kind) DO UPDATE SET used = daily_usage.used + v_n;
  UPDATE players SET food_stock = food_stock - v_n, life = LEAST(life_max, life + v_n * v_heal)
   WHERE id = v_uid RETURNING * INTO p;
  PERFORM v2_event(v_uid, 'food_eaten',
    format('Comes %s %s de tus existencias.', v_n, CASE WHEN v_n = 1 THEN 'ración' ELSE 'raciones' END),
    jsonb_build_object('rations', v_n, 'heal', v_n * v_heal, 'where', 'home'));
  RETURN jsonb_build_object('eaten', v_n, 'life', p.life, 'food_stock', round(p.food_stock, 2),
    'left_today', v_max - COALESCE(v_used, 0) - v_n);
END $$;

-- Alta (de 004) + activación de supermercados
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
  v_muni_id integer;
  v_muni_name text;
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

  -- Población: la del centro del polígono de casa (no se pide al jugador).
  SELECT id, name INTO v_muni_id, v_muni_name FROM municipalities
   WHERE ST_Intersects(area, ST_Centroid(v_home)) ORDER BY id LIMIT 1;
  UPDATE players SET municipality_id = v_muni_id WHERE id = v_uid;

  -- Una casa nueva puede hacer que un supermercado cercano llegue al mínimo.
  PERFORM v2_activate_pois();

  PERFORM v2_event(v_uid, 'character_created',
    'Censo sanitario-militar completado. Tus datos quedan registrados.', NULL);

  RETURN jsonb_build_object('nick', v_nick, 'age_band', b.band, 'life', b.life_max,
    'life_max', b.life_max, 'food_stock', v2_param('food_start'), 'municipality', v_muni_name);
END $$;

-- Posición (de 003) con el saqueo nuevo
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
  v_loot jsonb := NULL;
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
  -- Saqueo (civiles): avance y cancelación de la acción en curso, y qué ofrece
  -- el supermercado en el que está (sin revelar existencias desde fuera).
  v_loot := v2_loot_settle(v_uid, v_point, v_good);

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

-- Combate interrumpe la acción
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

  -- El combate interrumpe lo que el civil estuviera haciendo en el supermercado
  -- (comer o cargar raciones); el saqueo sigue contando.
  IF EXISTS (SELECT 1 FROM poi_visits WHERE player_id = v_civil AND completed_at IS NULL
             AND aborted_at IS NULL AND action IS NOT NULL) THEN
    UPDATE poi_visits SET action = NULL, action_count = NULL, action_started_at = NULL
     WHERE player_id = v_civil AND completed_at IS NULL AND aborted_at IS NULL;
    PERFORM v2_event(v_civil, 'loot_aborted', 'Un ataque te interrumpe. Lo que tenías entre manos se pierde.', NULL);
  END IF;

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

-- Tick
CREATE OR REPLACE FUNCTION public.v2_tick()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE r record; v_count int := 0;
BEGIN
  FOR r IN SELECT id FROM players WHERE age_band IS NOT NULL ORDER BY id LOOP
    PERFORM v2_apply_effects(r.id, now());
    v_count := v_count + 1;
  END LOOP;

  -- Saqueos abiertos: completar o cancelar acciones aunque el jugador no envíe
  -- posición (usa la última guardada; si es vieja, se cancela).
  FOR r IN SELECT DISTINCT player_id FROM poi_visits WHERE completed_at IS NULL AND aborted_at IS NULL LOOP
    PERFORM v2_loot_settle(r.player_id, NULL, false);
  END LOOP;

  RETURN v_count;
END $$;

-- Atajo de compatibilidad: 1 ración (el cliente anterior llama a esta).
CREATE OR REPLACE FUNCTION public.eat_extra_ration()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
  SELECT public.eat_home_rations(1);
$$;

-- ---------------------------------------------------------------------
-- Activar los que ya cumplan y programar la revisión
-- ---------------------------------------------------------------------
SELECT public.v2_activate_pois();
SELECT cron.schedule('prion-v2-pois', '*/15 * * * *', 'SELECT public.v2_activate_pois();');

-- ---------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.v2_activate_pois(), public.v2_loot_eligibility(uuid, bigint),
  public.v2_loot_settle(uuid, geography, boolean)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.loot_action(text, integer), public.eat_home_rations(integer),
  public.eat_extra_ration()
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.loot_action(text, integer), public.eat_home_rations(integer),
  public.eat_extra_ration()
TO authenticated;
