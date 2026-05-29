-- =====================================================================
-- PROYECTO PRION - Lógica de base de datos (Supabase / PostgreSQL + PostGIS)
-- Respaldo y documentación de funciones SQL y crons.
-- Este archivo refleja lo desplegado en Supabase (project ref: uziyxukcasjmvcemtonp).
-- =====================================================================

-- ---------------------------------------------------------------------
-- TRIGGER: creación automática de fila en players al registrarse usuario
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  random_role TEXT;
  base_nick TEXT;
  final_nick TEXT;
  counter INT := 0;
BEGIN
  random_role := CASE WHEN random() < 0.5 THEN 'civil' ELSE 'zombie' END;
  base_nick := split_part(NEW.email, '@', 1);
  final_nick := base_nick;
  WHILE EXISTS (SELECT 1 FROM public.players WHERE nick = final_nick) LOOP
    counter := counter + 1;
    final_nick := base_nick || counter;
  END LOOP;
  INSERT INTO public.players (id, nick, role, life, status)
  VALUES (NEW.id, final_nick, random_role, 10, 'active');
  RETURN NEW;
END;
$$;

-- Trigger asociado:
-- CREATE TRIGGER on_auth_user_created
--   AFTER INSERT ON auth.users
--   FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ---------------------------------------------------------------------
-- ZONA DE JUEGO: devolver polígono activo como GeoJSON
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_playable_zone()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT ST_AsGeoJSON(playable_zone::geometry)::jsonb
  FROM game_session
  WHERE status IN ('setup', 'active')
  ORDER BY start_time DESC
  LIMIT 1;
$$;

-- ---------------------------------------------------------------------
-- DETECCIÓN: ¿está el jugador dentro de la zona?
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_inside_zone(p_player_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT ST_Within(
    p.position::geometry,
    (SELECT playable_zone::geometry FROM game_session WHERE status = 'active' LIMIT 1)
  )
  FROM players p
  WHERE p.id = p_player_id;
$$;

-- ---------------------------------------------------------------------
-- DETECCIÓN: encontrar rival cercano del rol opuesto (<25m)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.find_nearby_opponent(
  p_player_id UUID,
  p_opposite_role TEXT
)
RETURNS TABLE (id UUID, nick TEXT, distance_meters DOUBLE PRECISION)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT p.id, p.nick,
    ST_Distance(p.position::geography,
      (SELECT position FROM players WHERE id = p_player_id)::geography) AS distance_meters
  FROM players p
  WHERE p.id != p_player_id
    AND p.role = p_opposite_role
    AND p.status = 'active'
    AND p.current_encounter_id IS NULL
    AND p.life > 0
    AND p.position IS NOT NULL
    AND p.position_updated_at > NOW() - INTERVAL '30 seconds'
    AND ST_DWithin(p.position::geography,
      (SELECT position FROM players WHERE id = p_player_id)::geography, 25)
  ORDER BY distance_meters ASC
  LIMIT 1;
$$;

-- ---------------------------------------------------------------------
-- ENCUENTRO: creación transaccional (evita race conditions)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_encounter_transaction(
  p_civil_id UUID,
  p_zombie_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_encounter_id UUID;
BEGIN
  PERFORM 1 FROM players WHERE id IN (p_civil_id, p_zombie_id) FOR UPDATE;
  IF EXISTS (SELECT 1 FROM players WHERE id IN (p_civil_id, p_zombie_id)
             AND current_encounter_id IS NOT NULL) THEN
    RAISE EXCEPTION 'One of the players is already in an encounter';
  END IF;
  INSERT INTO encounters (civil_id, zombie_id, started_at)
  VALUES (p_civil_id, p_zombie_id, NOW())
  RETURNING id INTO v_encounter_id;
  UPDATE players SET current_encounter_id = v_encounter_id
  WHERE id IN (p_civil_id, p_zombie_id);
  INSERT INTO events (player_id, type, message, related_encounter_id)
  VALUES
    (p_civil_id, 'encounter_start', 'Has oído algo cerca. Algo se mueve. Enciende el radar.', v_encounter_id),
    (p_zombie_id, 'encounter_start', 'Carne fresca cerca. Sientes el hambre. Acércate.', v_encounter_id);
  RETURN v_encounter_id;
END;
$$;

-- ---------------------------------------------------------------------
-- COMBATE: cálculo + resolución completa (motor único de combate)
-- Tabla de daños, dado con re-tirada en empate (guarda todas las tiradas),
-- conversión, neutralización, cooldowns y eventos. Todo atómico.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_and_resolve_encounter(p_encounter_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_enc encounters%ROWTYPE;
  v_civil players%ROWTYPE;
  v_zombie players%ROWTYPE;
  v_cd TEXT; v_zd TEXT; v_result TEXT;
  v_civil_damage INT := 0; v_zombie_damage INT := 0;
  v_dice JSONB := NULL; v_civil_msg TEXT; v_zombie_msg TEXT;
  v_civil_cooldown INT := 180; v_zombie_cooldown INT := 180;
  v_civil_roll INT; v_zombie_roll INT; v_rolls JSONB := '[]'::JSONB;
  v_civil_new_life INT; v_zombie_new_life INT;
  v_civil_converted BOOLEAN := false; v_zombie_neutralized BOOLEAN := false;
  v_now TIMESTAMPTZ := NOW();
BEGIN
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

  IF v_cd = 'HUIR' AND v_zd = 'MORDER' THEN
    v_result := 'civil_escaped'; v_civil_damage := 1; v_civil_cooldown := 300;
    v_civil_msg := 'Escapas entre callejones. Un rasguño, nada más. (-1)';
    v_zombie_msg := 'Dentellada al aire. La presa se escabulle.';
  ELSIF v_cd = 'HUIR' AND v_zd = 'PERSEGUIR' THEN
    v_result := 'civil_caught'; v_civil_damage := 2;
    v_civil_msg := 'Te dan caza antes de doblar la esquina. (-2)';
    v_zombie_msg := 'Lo alcanzas. Tus garras encuentran carne. (civil -2)';
  ELSIF v_cd = 'LUCHAR' AND v_zd = 'PERSEGUIR' THEN
    v_result := 'civil_wins_fight'; v_zombie_damage := 3;
    v_civil_msg := 'Aprovechas su impulso y golpeas. Retrocede herido. (zombie -3)';
    v_zombie_msg := 'Te lanzas y te recibe con un golpe seco. (-3)';
  ELSIF v_cd = 'LUCHAR' AND v_zd = 'MORDER' THEN
    LOOP
      v_civil_roll := floor(random() * 6 + 1)::INT;
      v_zombie_roll := floor(random() * 6 + 1)::INT;
      v_rolls := v_rolls || jsonb_build_object('civil', v_civil_roll, 'zombie', v_zombie_roll);
      EXIT WHEN v_civil_roll <> v_zombie_roll;
    END LOOP;
    IF v_civil_roll > v_zombie_roll THEN
      v_result := 'civil_wins_fight'; v_zombie_damage := 4;
      v_civil_msg := format('Choque brutal. Te impones (%s vs %s). (zombie -4)', v_civil_roll, v_zombie_roll);
      v_zombie_msg := format('Forcejeo cuerpo a cuerpo. Pierdes (%s vs %s). (-4)', v_zombie_roll, v_civil_roll);
    ELSE
      v_result := 'zombie_wins_fight'; v_civil_damage := 4;
      v_civil_msg := format('Forcejeo cuerpo a cuerpo. Pierdes (%s vs %s). (-4)', v_civil_roll, v_zombie_roll);
      v_zombie_msg := format('Choque brutal. Te impones (%s vs %s). (civil -4)', v_zombie_roll, v_civil_roll);
    END IF;
    v_dice := jsonb_build_object('rolls', v_rolls,
      'winner', CASE WHEN v_civil_roll > v_zombie_roll THEN 'civil' ELSE 'zombie' END);
  ELSE
    RAISE EXCEPTION 'Invalid decision combination: civil=%, zombie=%', v_cd, v_zd;
  END IF;

  v_civil_new_life := v_civil.life - v_civil_damage;
  v_zombie_new_life := v_zombie.life - v_zombie_damage;

  IF v_civil_new_life <= 0 THEN
    v_civil_converted := true;
    UPDATE players SET role='zombie', life=10, status='active',
      status_until=NULL, current_encounter_id=NULL WHERE id=v_civil.id;
  ELSE
    UPDATE players SET life=v_civil_new_life, status='radar_disabled',
      status_until=v_now + (v_civil_cooldown || ' seconds')::INTERVAL,
      current_encounter_id=NULL WHERE id=v_civil.id;
  END IF;

  IF v_zombie_new_life <= 0 THEN
    v_zombie_neutralized := true;
    UPDATE players SET life=0, status='neutralized',
      status_until=v_now + INTERVAL '15 minutes',
      current_encounter_id=NULL WHERE id=v_zombie.id;
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

  IF v_civil_converted THEN
    INSERT INTO events (player_id, type, message, related_encounter_id)
    VALUES (v_civil.id, 'conversion', 'La fiebre te consume. Ahora formas parte de la horda.', p_encounter_id);
  END IF;
  IF v_zombie_neutralized THEN
    INSERT INTO events (player_id, type, message, related_encounter_id)
    VALUES (v_zombie.id, 'neutralization', 'Te han derribado. Quedas inerte durante 15 minutos.', p_encounter_id);
  END IF;

  RETURN jsonb_build_object('result', v_result, 'civil_damage', v_civil_damage,
    'zombie_damage', v_zombie_damage, 'dice_roll', v_dice,
    'civil_converted', v_civil_converted, 'zombie_neutralized', v_zombie_neutralized,
    'civil_new_life', CASE WHEN v_civil_converted THEN 10 ELSE v_civil_new_life END,
    'zombie_new_life', CASE WHEN v_zombie_neutralized THEN 0 ELSE v_zombie_new_life END);
END;
$$;

-- ---------------------------------------------------------------------
-- TIMEOUT: rellena decisiones por defecto y resuelve encuentros vencidos
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_timeouts()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_enc RECORD; v_resolved_count INT := 0;
BEGIN
  FOR v_enc IN
    SELECT id, civil_decision, zombie_decision FROM encounters
    WHERE result IS NULL AND started_at < NOW() - INTERVAL '16 seconds'
  LOOP
    IF v_enc.civil_decision IS NULL THEN
      UPDATE encounters SET civil_decision='HUIR', civil_decision_at=NOW()
      WHERE id=v_enc.id AND civil_decision IS NULL;
    END IF;
    IF v_enc.zombie_decision IS NULL THEN
      UPDATE encounters SET zombie_decision='MORDER', zombie_decision_at=NOW()
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
$$;

-- ---------------------------------------------------------------------
-- CRONS DE MANTENIMIENTO
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.regenerate_civils()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE v_count INT;
BEGIN
  UPDATE players SET life = life + 1
  WHERE role='civil' AND status='active' AND life > 0 AND life < 10;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_zombies()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE v_count INT;
BEGIN
  UPDATE players SET life=10, status='active', status_until=NULL
  WHERE status='neutralized' AND status_until IS NOT NULL AND status_until <= NOW();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_radar()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE v_count INT;
BEGIN
  UPDATE players SET status='active', status_until=NULL
  WHERE status='radar_disabled' AND status_until IS NOT NULL AND status_until <= NOW();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------
-- CRONS PROGRAMADOS (pg_cron). Referencia de lo activo en Supabase:
--   apply-timeouts     : '5 seconds'   -> SELECT public.apply_timeouts();
--   restore-zombies    : '30 seconds'  -> SELECT public.restore_zombies();
--   restore-radar      : '30 seconds'  -> SELECT public.restore_radar();
--   regenerate-civils  : '0 * * * *'   -> SELECT public.regenerate_civils();
-- ---------------------------------------------------------------------

-- GRANTS (todas las funciones de servidor a service_role; las de lectura a authenticated)
-- get_playable_zone, is_inside_zone, find_nearby_opponent: GRANT EXECUTE ... TO authenticated;
-- create_encounter_transaction, compute_and_resolve_encounter, apply_timeouts,
-- regenerate_civils, restore_zombies, restore_radar: GRANT EXECUTE ... TO service_role;

-- PENDIENTE (próxima sesión): función close_game + cron, condición de victoria.