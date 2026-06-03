-- =====================================================================
-- PROYECTO PRION - Backend completo (Supabase / PostgreSQL + PostGIS)
-- Archivo único y consolidado. Refleja TODO lo desplegado en Supabase
-- (project ref: uziyxukcasjmvcemtonp). Sustituye a los antiguos
-- prion_narrative.sql y prion_wire_narrative.sql, que quedan obsoletos.
--
-- NO se despliega solo: es la copia/documentación de lo que vive en la base.
-- Las tablas base (players, encounters, events, game_session) se crearon en
-- el setup inicial; aquí solo van las columnas AÑADIDAS después.
-- Orden: esquema -> funciones -> datos de narrativa -> grants -> crons.
-- =====================================================================

-- =====================================================================
-- ESQUEMA: columnas añadidas y tabla de narrativa
-- =====================================================================
ALTER TABLE game_session ADD COLUMN IF NOT EXISTS final_report jsonb;
ALTER TABLE encounters  ADD COLUMN IF NOT EXISTS civil_timed_out  boolean NOT NULL DEFAULT false;
ALTER TABLE encounters  ADD COLUMN IF NOT EXISTS zombie_timed_out boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.narrative (
  id        BIGSERIAL PRIMARY KEY,
  situation TEXT NOT NULL,
  role      TEXT,                 -- 'civil', 'zombie' o NULL (difusión)
  message   TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS narrative_lookup ON public.narrative (situation, role);

-- Solo lo leen las funciones de servidor (SECURITY DEFINER); el cliente no.
ALTER TABLE public.narrative ENABLE ROW LEVEL SECURITY;

-- =====================================================================
-- TRIGGER: alta automática de jugador al registrarse
-- =====================================================================
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
--   AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- =====================================================================
-- ZONA: polígono jugable y comprobación de pertenencia
-- =====================================================================
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

-- =====================================================================
-- ESTADO DE PARTIDA: freeze al expirar end_time
-- =====================================================================
CREATE OR REPLACE FUNCTION public.is_game_active()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM game_session
    WHERE status = 'active' AND NOW() < end_time
  );
$$;

-- =====================================================================
-- DETECCIÓN: rival cercano del rol opuesto (<25m)
-- =====================================================================
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

-- =====================================================================
-- RADAR: jugadores cercanos. La lógica va en una función SECURITY DEFINER
-- que SOLO devuelve columnas seguras (sin nombre real, edad ni género), y la
-- vista nearby_players la envuelve en SECURITY INVOKER (no expone la tabla
-- players ni filtra PII). El cliente sigue consultando la vista igual.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_nearby_players()
RETURNS TABLE (
  id uuid, nick text, role text,
  lat double precision, lng double precision,
  status text, distance_meters double precision
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT p.id, p.nick, p.role,
    ST_Y(p.position::geometry) AS lat,
    ST_X(p.position::geometry) AS lng,
    p.status,
    ST_Distance(p.position::geography,
      (SELECT position FROM players WHERE id = auth.uid())::geography) AS distance_meters
  FROM players p
  WHERE p.id <> auth.uid()
    AND p.status = ANY (ARRAY['active','radar_disabled','neutralized'])
    AND p.position IS NOT NULL
    AND p.position_updated_at > (now() - interval '5 minutes')
    AND ST_DWithin(p.position::geography,
      (SELECT position FROM players WHERE id = auth.uid())::geography, 25);
$$;

CREATE OR REPLACE VIEW public.nearby_players
WITH (security_invoker = true) AS
  SELECT * FROM public.get_nearby_players();

-- =====================================================================
-- NARRATIVA: selector de frase al azar
-- =====================================================================
CREATE OR REPLACE FUNCTION public.pick_narrative(p_situation TEXT, p_role TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT message FROM public.narrative
  WHERE situation = p_situation
    AND (role IS NOT DISTINCT FROM p_role)
  ORDER BY random()
  LIMIT 1;
$$;

-- =====================================================================
-- ENCUENTRO: creación transaccional (detección desde narrativa)
-- =====================================================================
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
  IF NOT public.is_game_active() THEN RETURN NULL; END IF;  -- no se crean encuentros tras el cierre
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
    (p_civil_id, 'encounter_start',
      COALESCE(public.pick_narrative('detection','civil'), 'Algo se mueve cerca. Enciende el radar.'),
      v_encounter_id),
    (p_zombie_id, 'encounter_start',
      COALESCE(public.pick_narrative('detection','zombie'), 'Carne fresca cerca. Acércate.'),
      v_encounter_id);
  RETURN v_encounter_id;
END;
$$;

-- =====================================================================
-- COMBATE: motor único (mensajes desde narrativa)
-- =====================================================================
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
  v_situation TEXT;
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

  v_civil_msg  := COALESCE(public.pick_narrative(v_situation, 'civil'),  'El encuentro se resuelve.');
  v_zombie_msg := COALESCE(public.pick_narrative(v_situation, 'zombie'), 'El encuentro se resuelve.');

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
    VALUES (v_civil.id, 'conversion',
      COALESCE(public.pick_narrative('conversion','civil'), 'La fiebre te consume. Ahora formas parte de la horda.'),
      p_encounter_id);
  END IF;
  IF v_zombie_neutralized THEN
    INSERT INTO events (player_id, type, message, related_encounter_id)
    VALUES (v_zombie.id, 'neutralization',
      COALESCE(public.pick_narrative('neutralization','zombie'), 'Te han derribado. Quedas inerte durante 15 minutos.'),
      p_encounter_id);
  END IF;

  RETURN jsonb_build_object('result', v_result, 'civil_damage', v_civil_damage,
    'zombie_damage', v_zombie_damage, 'dice_roll', v_dice,
    'civil_converted', v_civil_converted, 'zombie_neutralized', v_zombie_neutralized,
    'civil_new_life', CASE WHEN v_civil_converted THEN 10 ELSE v_civil_new_life END,
    'zombie_new_life', CASE WHEN v_zombie_neutralized THEN 0 ELSE v_zombie_new_life END);
END;
$$;

-- =====================================================================
-- TIMEOUT: rellena defaults y resuelve encuentros vencidos
-- =====================================================================
CREATE OR REPLACE FUNCTION public.apply_timeouts()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_enc RECORD; v_resolved_count INT := 0;
BEGIN
  IF NOT public.is_game_active() THEN RETURN 0; END IF;  -- mundo congelado tras el cierre
  FOR v_enc IN
    SELECT id, civil_decision, zombie_decision FROM encounters
    WHERE result IS NULL AND started_at < NOW() - INTERVAL '16 seconds'
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
$$;

-- =====================================================================
-- CRONS DE MANTENIMIENTO (con guard de freeze)
-- =====================================================================
CREATE OR REPLACE FUNCTION public.regenerate_civils()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE v_count INT;
BEGIN
  IF NOT public.is_game_active() THEN RETURN 0; END IF;
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
  IF NOT public.is_game_active() THEN RETURN 0; END IF;
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
  IF NOT public.is_game_active() THEN RETURN 0; END IF;
  UPDATE players SET status='active', status_until=NULL
  WHERE status='radar_disabled' AND status_until IS NOT NULL AND status_until <= NOW();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- =====================================================================
-- CIERRE: victoria, informe global y aviso final (narrativa)
-- =====================================================================
CREATE OR REPLACE FUNCTION public.close_game()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_session game_session%ROWTYPE;
  v_civil_count INT;
  v_winner TEXT;
  v_report jsonb;
  v_end_msg TEXT;
BEGIN
  SELECT * INTO v_session
  FROM game_session
  WHERE status = 'active' AND end_time <= NOW()
  ORDER BY start_time DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('closed', false);
  END IF;

  -- Civil vivo == role 'civil' (un civil nunca tiene vida <= 0; al caer se convierte).
  SELECT COUNT(*) INTO v_civil_count FROM players WHERE role = 'civil';
  v_winner := CASE WHEN v_civil_count >= 5 THEN 'civils' ELSE 'zombies' END;

  v_report := jsonb_build_object(
    'winning_side',          v_winner,
    'civils_alive',          v_civil_count,
    'zombies_count',         (SELECT COUNT(*) FROM players WHERE role = 'zombie'),
    'encounters_total',      (SELECT COUNT(*) FROM encounters WHERE result IS NOT NULL),
    'conversions_total',     (SELECT COUNT(*) FROM events WHERE type = 'conversion'),
    'neutralizations_total', (SELECT COUNT(*) FROM events WHERE type = 'neutralization'),
    'timeout_resolved',      (SELECT COUNT(*) FROM encounters
                              WHERE result IS NOT NULL AND (civil_timed_out OR zombie_timed_out)),
    'result_breakdown', (
      SELECT COALESCE(jsonb_object_agg(result, n), '{}'::jsonb)
      FROM (SELECT result, COUNT(*) n FROM encounters WHERE result IS NOT NULL GROUP BY result) s
    ),
    'civil_decisions', (
      SELECT COALESCE(jsonb_object_agg(civil_decision, n), '{}'::jsonb)
      FROM (SELECT civil_decision, COUNT(*) n FROM encounters
            WHERE civil_decision IS NOT NULL GROUP BY civil_decision) s
    ),
    'zombie_decisions', (
      SELECT COALESCE(jsonb_object_agg(zombie_decision, n), '{}'::jsonb)
      FROM (SELECT zombie_decision, COUNT(*) n FROM encounters
            WHERE zombie_decision IS NOT NULL GROUP BY zombie_decision) s
    ),
    'closed_at', NOW()
  );

  UPDATE game_session
  SET status = 'finished', winning_side = v_winner, final_report = v_report
  WHERE id = v_session.id;

  v_end_msg := COALESCE(
    public.pick_narrative('game_end_' || CASE WHEN v_winner = 'civils' THEN 'civils' ELSE 'zombies' END, NULL),
    CASE WHEN v_winner = 'civils'
      THEN 'Silencio en las calles. Los supervivientes han resistido. Fin de la partida.'
      ELSE 'La horda ha tomado la ciudad. No queda nadie a quien salvar. Fin de la partida.'
    END
  );

  INSERT INTO events (player_id, type, message)
  SELECT p.id, 'game_end', v_end_msg
  FROM players p;

  RETURN jsonb_build_object('closed', true, 'winning_side', v_winner, 'report', v_report);
END;
$$;

-- =====================================================================
-- INFORME FINAL por jugador (global congelado + individual)
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_final_report(p_player_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_global jsonb;
  v_individual jsonb;
BEGIN
  SELECT final_report INTO v_global
  FROM game_session
  WHERE status = 'finished'
  ORDER BY end_time DESC
  LIMIT 1;

  IF v_global IS NULL THEN
    RETURN jsonb_build_object('available', false);
  END IF;

  v_individual := jsonb_build_object(
    'encounters_total', (
      SELECT COUNT(*) FROM encounters
      WHERE result IS NOT NULL AND (civil_id = p_player_id OR zombie_id = p_player_id)
    ),
    'as_civil_decisions', (
      SELECT COALESCE(jsonb_object_agg(civil_decision, n), '{}'::jsonb)
      FROM (SELECT civil_decision, COUNT(*) n FROM encounters
            WHERE civil_id = p_player_id AND civil_decision IS NOT NULL
            GROUP BY civil_decision) s
    ),
    'as_zombie_decisions', (
      SELECT COALESCE(jsonb_object_agg(zombie_decision, n), '{}'::jsonb)
      FROM (SELECT zombie_decision, COUNT(*) n FROM encounters
            WHERE zombie_id = p_player_id AND zombie_decision IS NOT NULL
            GROUP BY zombie_decision) s
    ),
    -- Zombies que neutralicé (yo era el civil del encuentro y el rival cayó a 0).
    'neutralizations_caused', (
      SELECT COUNT(*) FROM events e
      JOIN encounters enc ON enc.id = e.related_encounter_id
      WHERE e.type = 'neutralization' AND enc.civil_id = p_player_id
    ),
    -- Civiles que convertí (yo era el zombie del encuentro y el rival cayó a 0).
    'conversions_caused', (
      SELECT COUNT(*) FROM events e
      JOIN encounters enc ON enc.id = e.related_encounter_id
      WHERE e.type = 'conversion' AND enc.zombie_id = p_player_id
    ),
    'times_converted',   (SELECT COUNT(*) FROM events WHERE type = 'conversion'     AND player_id = p_player_id),
    'times_neutralized', (SELECT COUNT(*) FROM events WHERE type = 'neutralization' AND player_id = p_player_id)
  );

  RETURN jsonb_build_object('available', true, 'global', v_global, 'individual', v_individual);
END;
$$;

-- =====================================================================
-- ASIGNACIÓN 10/10: reparto aleatorio con recuento garantizado
-- =====================================================================
CREATE OR REPLACE FUNCTION public.assign_roles_balanced(p_civil_count INT DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_total INT; v_civ INT; v_zom INT;
BEGIN
  -- Elegibles: los testers (excluye aparra112 y cualquier cuenta de pruebas).
  SELECT COUNT(*) INTO v_total FROM players WHERE nick LIKE 'tester%';
  IF v_total <> p_civil_count * 2 THEN
    RAISE EXCEPTION 'Esperaba % testers pero hay %. Reparto abortado.', p_civil_count*2, v_total;
  END IF;
  WITH barajados AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY random()) AS rn
    FROM players WHERE nick LIKE 'tester%'
  )
  UPDATE players p
  SET role = CASE WHEN b.rn <= p_civil_count THEN 'civil' ELSE 'zombie' END,
      life = 10, status = 'active', status_until = NULL, current_encounter_id = NULL
  FROM barajados b
  WHERE p.id = b.id;
  SELECT COUNT(*) FILTER (WHERE role='civil'), COUNT(*) FILTER (WHERE role='zombie')
  INTO v_civ, v_zom FROM players WHERE nick LIKE 'tester%';
  RETURN jsonb_build_object('civiles', v_civ, 'zombies', v_zom, 'total', v_total);
END;
$$;

-- Se ejecuta a mano UNA vez antes de abrir la partida: SELECT public.assign_roles_balanced();

-- =====================================================================
-- DATOS: banco narrativo (92 piezas)
-- =====================================================================
-- (Opcional) vaciar antes de recargar, para reejecutar sin duplicar:
-- TRUNCATE public.narrative RESTART IDENTITY;

-- ---------------------------------------------------------------------
-- DETECCIÓN — civil (central militar filtrada por el cuerpo)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('detection','civil','Interferencia en la onda. Algo se mueve a menos de veinticinco metros, y se mueve mal, a tirones. Enciende el radar. Reza por equivocarte.'),
('detection','civil','Señal de proximidad. El vello de la nuca se te eriza un segundo antes del aviso. Tu cuerpo ya lo sabe: te han olido.'),
('detection','civil','Captación cercana. Entre la estática se cuela un arrastre húmedo, una respiración que no es respiración. Está cerca.'),
('detection','civil','Contacto a corta distancia. El aire se ha vuelto denso, eléctrico, como antes de una tormenta. Algo te busca en la oscuridad.'),
('detection','civil','Lectura de movimiento. Lo que viene hacia ti no corre. No le hace falta. Tiene todo el tiempo del mundo, y tú no.'),
('detection','civil','Proximidad confirmada. Enciende el radar y mira bien. Lo que vas a ver no vas a poder olvidarlo.');

-- ---------------------------------------------------------------------
-- DETECCIÓN — zombie (instinto/hambre)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('detection','zombie','Carne viva en el radar. Tibia. A menos de veinticinco metros. El hambre te dobla en dos. Ve.'),
('detection','zombie','Late algo cerca. Un corazón asustado, rápido. Lo oyes a través del asfalto, a través de todo. Acércate.'),
('detection','zombie','Olfateas el sudor del vivo antes de verlo. Miedo. Sabe a miedo. El radar solo confirma lo que tu cuerpo ya persigue.'),
('detection','zombie','Señal de presa. Algo respira donde no debería. Cada bocanada suya es una invitación. Caza.'),
('detection','zombie','Proximidad de carne. La onda se llena de su pulso. Tan fuerte. Tan lleno. Tan tuyo.'),
('detection','zombie','Contacto. Hay vida a la vuelta de la sombra, y la vida es lo único que todavía te importa. Búscala.');

-- ---------------------------------------------------------------------
-- FLEE_ESCAPE (HUIR+MORDER) — civil escapa (-1)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('flee_escape','civil','La sangre seca del suelo te hace resbalar, pero te impulsas justo cuando esas manos podridas se cierran donde estaba tu cabeza. Vives. (-1)'),
('flee_escape','civil','Corres sin mirar atrás. Sientes su aliento frío en la nuca y luego, de golpe, nada. Solo tu propio jadeo y la oscuridad. (-1)'),
('flee_escape','civil','Un tirón en el brazo, tela que se rasga, piel que arde. Te zafas y la noche te traga antes que a él. Escapaste. (-1)'),
('flee_escape','civil','Tus piernas deciden por ti. Vuelas entre las sombras mientras detrás queda un gruñido de rabia que no te alcanzó. (-1)'),
('flee_escape','civil','Sientes los dedos rozarte la espalda, hambrientos, casi. Casi. Te hundes en lo oscuro y los pierdes. (-1)'),
('flee_escape','civil','El corazón te revienta en la garganta, pero los pies responden. Lo dejas atrás arañando el aire donde estabas. (-1)');

INSERT INTO public.narrative (situation, role, message) VALUES
('flee_escape','zombie','Cierras la mandíbula y solo muerdes aire frío. El calor de la presa se escurre entre tus dedos.'),
('flee_escape','zombie','Un palmo. Te ha faltado un palmo de carne viva. El vivo se hunde en la sombra y el hambre se queda, intacta, royéndote.'),
('flee_escape','zombie','Tus uñas rozan tela, piel, vida… y se llevan solo un jirón. El resto huye. Aúllas por dentro.'),
('flee_escape','zombie','La presa se escurre como agua. Te quedas con el eco de su pulso y nada que llevarte a la boca.'),
('flee_escape','zombie','Muerdes la noche. La carne ya no está, pero su miedo todavía flota en el aire. Lo seguirás.'),
('flee_escape','zombie','Tan cerca que sentías su pánico. Y se ha ido. La onda se vacía. El hambre no.');

-- ---------------------------------------------------------------------
-- FLEE_CAUGHT (HUIR+PERSEGUIR) — civil cazado al huir (-2)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('flee_caught','civil','Corres, pero él corre dentro de ti, en tus pesadillas, más rápido. Te alcanza antes de la esquina y algo se rompe. (-2)'),
('flee_caught','civil','Crees que escapas hasta que un peso frío se te echa encima y unos dientes encuentran carne. Te arrancas y sigues, sangrando. (-2)'),
('flee_caught','civil','La huida dura tres pasos. Al cuarto, sus manos. Al quinto, el dolor. Logras soltarte, pero te has dejado un trozo atrás. (-2)'),
('flee_caught','civil','No mira dónde pisa, no le importa caer: solo quiere tu carne. Te embiste y te marca antes de que te zafes. (-2)'),
('flee_caught','civil','Sientes cómo la distancia se cierra, metro a metro, como una trampa que se traga su propia cuerda. Cuando llega, llega entero. (-2)'),
('flee_caught','civil','Pensabas que eras rápido. Él no se cansa, no duda, no teme. Te cae encima y te muerde el avance. (-2)');

INSERT INTO public.narrative (situation, role, message) VALUES
('flee_caught','zombie','No corres: cazas. La distancia se rinde ante ti y tus manos encuentran por fin la carne tibia que late. (civil -2)'),
('flee_caught','zombie','El vivo cree que la velocidad lo salva. No sabe que tú ya no conoces el cansancio. Lo alcanzas. Lo marcas. (civil -2)'),
('flee_caught','zombie','Cada zancada suya es un latido más fuerte en tus oídos. Lo derribas, hincas, y arrancas un pedazo antes de que se zafe. (civil -2)'),
('flee_caught','zombie','Lo persigues hasta el lugar donde el miedo le falla a las piernas. Ahí lo tienes. Ahí lo muerdes. (civil -2)'),
('flee_caught','zombie','No hay rincón oscuro que te lo esconda. Lo hueles, lo alcanzas, lo abres. Se escapa, pero se deja algo entre tus dientes. (civil -2)'),
('flee_caught','zombie','El vivo era veloz. El hambre lo es más. Caes sobre él y le robas un trozo de vida. (civil -2)');

-- ---------------------------------------------------------------------
-- FIGHT_SURPRISE (LUCHAR+PERSEGUIR) — civil sorprende al zombie (zombie -3)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('fight_surprise','civil','Esperabas correr, pero algo dentro de ti dice basta. Cuando se lanza, ya no estás donde apunta: giras y golpeas con todo. Retrocede aullando. (zombie -3)'),
('fight_surprise','civil','Tu miedo se convierte en otra cosa, algo afilado. Aprovechas su embestida ciega y lo estrellas contra la oscuridad. (zombie -3)'),
('fight_surprise','civil','Viene a por ti sin pensar, todo hambre y nada de cabeza. Tú sí piensas. Esquivas, cargas y le abres una herida que no esperaba. (zombie -3)'),
('fight_surprise','civil','La adrenalina te vuelve animal a ti también. Lo recibes con un golpe seco que lo dobla. Por un instante, el cazador eres tú. (zombie -3)'),
('fight_surprise','civil','Su furia es su debilidad. Te apartas medio palmo, justo lo necesario, y descargas todo tu pánico convertido en fuerza. Cae herido. (zombie -3)'),
('fight_surprise','civil','No huyes. Te plantas. Y cuando esa cosa se abalanza, encuentra unas manos vivas que todavía saben pelear. Lo hieres y retrocede. (zombie -3)');

INSERT INTO public.narrative (situation, role, message) VALUES
('fight_surprise','zombie','Te lanzas seguro de la carne fácil y te recibe un golpe que no estaba en tus cálculos. El dolor te arranca el hambre por un segundo. (-3)'),
('fight_surprise','zombie','La presa no corre: se queda. Demasiado tarde entiendes por qué. Su golpe te dobla y retrocedes, herido. (-3)'),
('fight_surprise','zombie','Cargas a ciegas, sin miedo, sin pensar. Por eso no ves venir el impacto que te abre y te echa atrás. (-3)'),
('fight_surprise','zombie','Creías tener la cena servida. La cena te ha partido algo por dentro. Te repliegas a las sombras, goteando. (-3)'),
('fight_surprise','zombie','Vas entero a por él y él va entero a por ti. Pierdes. Algo cede dentro de ti con un crujido húmedo. (-3)'),
('fight_surprise','zombie','El vivo todavía tiene fuego. Lo descubres tarde, cuando su golpe te recuerda lo que es el dolor. (-3)');

-- ---------------------------------------------------------------------
-- FIGHT_CLASH_CIVILWIN (LUCHAR+MORDER, dado lo gana el civil) — zombie -4
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('fight_clash_civilwin','civil','Os encontráis de frente, dos voluntades y una sola sobrevive entera. Esta vez, la tuya. Lo derribas con un crujido que retumba en el silencio. (zombie -4)'),
('fight_clash_civilwin','civil','Cuerpo contra cuerpo, sin trucos, todo a una. Su fuerza muerta contra tu desesperación viva, y gana la vida. Lo abres y cae. (zombie -4)'),
('fight_clash_civilwin','civil','El mundo se reduce a sus dientes y a tus manos. Empujas cuando todo dice ríndete, y algo en él se quiebra. (zombie -4)'),
('fight_clash_civilwin','civil','Forcejeo brutal, manos en la garganta, su frío contra tu fiebre. Apuras la última gota de fuerza y lo vences. (zombie -4)'),
('fight_clash_civilwin','civil','No sabes de dónde sacas el impulso. Solo sabes que cuando todo termina, tú sigues de pie y él no. (zombie -4)'),
('fight_clash_civilwin','civil','Choque salvaje en la oscuridad. Por un instante eterno no hay ganador. Luego lo hay, y eres tú. (zombie -4)');

INSERT INTO public.narrative (situation, role, message) VALUES
('fight_clash_civilwin','zombie','Os trabáis cuerpo a cuerpo, frío contra fiebre, y por una vez la fiebre vence. Algo se parte dentro de ti y el suelo sube a recibirte. (-4)'),
('fight_clash_civilwin','zombie','Tenías la carne entre las manos. Tenías. El vivo pelea como solo pelea quien no quiere morir, y te destroza. (-4)'),
('fight_clash_civilwin','zombie','Forcejeo a vida o muerte, y descubres que todavía puedes perder. Su golpe final te apaga medio cuerpo. (-4)'),
('fight_clash_civilwin','zombie','La presa se defiende con una furia que no entiendes, que ya olvidaste. Te quiebra y caes hacia la sombra. (-4)'),
('fight_clash_civilwin','zombie','Ibas a devorar y te devuelven el hambre multiplicada en dolor. Algo crujió. Era tuyo. (-4)'),
('fight_clash_civilwin','zombie','El choque os funde un instante en una sola masa de violencia. Cuando se separa, tú eres el que sangra negro. (-4)');

-- ---------------------------------------------------------------------
-- FIGHT_CLASH_ZOMBIEWIN (LUCHAR+MORDER, dado lo gana el zombie) — civil -4
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('fight_clash_zombiewin','civil','Os trabáis en la oscuridad y descubres, demasiado tarde, que la fuerza muerta no se cansa. Sus dientes encuentran su sitio. Algo tuyo se apaga. (-4)'),
('fight_clash_zombiewin','civil','Peleas con todo lo que eres, y no basta. El frío te gana terreno, centímetro a centímetro, hasta morderte hondo. (-4)'),
('fight_clash_zombiewin','civil','Cuerpo a cuerpo, y por un momento crees que ganas. Luego sientes el desgarro y entiendes que no. (-4)'),
('fight_clash_zombiewin','civil','Su hambre es más antigua que tu miedo. Te vence en el forcejeo y te arranca un pedazo de vida. (-4)'),
('fight_clash_zombiewin','civil','Das todo lo que tienes contra algo que ya no siente nada. Pierdes. El dolor te dobla y la sangre te empapa. (-4)'),
('fight_clash_zombiewin','civil','El choque te enseña la peor lección: que querer vivir, a veces, no alcanza. Caes herido, muy herido. (-4)');

INSERT INTO public.narrative (situation, role, message) VALUES
('fight_clash_zombiewin','zombie','Os fundís en un solo nudo de violencia y, esta vez, el hambre puede más. Hincas los dientes donde late la vida y bebes. (civil -4)'),
('fight_clash_zombiewin','zombie','El vivo pelea, grita, suplica con el cuerpo. Da igual. Lo doblas y le arrancas un trozo de lo que le queda. (civil -4)'),
('fight_clash_zombiewin','zombie','Su calor se resiste, pero el frío siempre gana al final. Lo vences y la carne cede entre tus dientes. (civil -4)'),
('fight_clash_zombiewin','zombie','Forcejeo brutal, y descubres que todavía recuerdas cómo se mata. Lo dejas tirado, abierto, vaciándose. (civil -4)'),
('fight_clash_zombiewin','zombie','Toda su furia viva contra tu hambre muerta. Gana el hambre. Siempre el hambre. Te llevas tu pedazo. (civil -4)'),
('fight_clash_zombiewin','zombie','Lo aprietas hasta que algo en él se rinde. Entonces muerdes. El sabor de la vida ajena te recorre entero. (civil -4)');

-- ---------------------------------------------------------------------
-- CONVERSIÓN — civil que cae a 0 y se transforma (tu propia voz apagándose)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('conversion','civil','La fiebre sube como una marea. Las luces duelen, los sonidos se alargan. Tu último pensamiento con tu propia voz es que ya no la reconoces. Bienvenido a la horda.'),
('conversion','civil','Primero el frío. Luego un calor que no es tuyo. Luego un hambre sin fondo que se come tu nombre, tus recuerdos, tu miedo. Solo queda buscar carne.'),
('conversion','civil','Intentas recordar quién eras y la respuesta se disuelve, letra a letra, como una emisora que pierde la señal. Lo último que oyes es tu propio gruñido.'),
('conversion','civil','El dolor cesa, y eso es lo peor. En su lugar queda un vacío que solo se llena de una manera. Ahora lo sabes. Ahora eres uno de ellos.'),
('conversion','civil','Sientes cómo algo se apaga detrás de tus ojos, una luz tras otra. Cuando se apaga la última, ya no tienes miedo. Tienes hambre.'),
('conversion','civil','Tu corazón da un último golpe humano y luego encuentra otro ritmo, más lento, más antiguo, más hambriento. La ciudad acaba de ganar un cazador.');

-- ---------------------------------------------------------------------
-- NEUTRALIZACIÓN — zombie derribado 15 min (caer sin morir del todo)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('neutralization','zombie','Un golpe final y el mundo se inclina. Caes sin caer del todo, atrapado entre el hambre y la nada. Quince minutos de oscuridad inerte.'),
('neutralization','zombie','Tu cuerpo deja de obedecer. Lo ves todo desde muy lejos, como bajo el agua. Estás abajo. Tardarás en volver.'),
('neutralization','zombie','La horda no muere. Pero por un rato, tú tampoco te mueves. Te derriban y la quietud te sepulta. El hambre tendrá que esperar.'),
('neutralization','zombie','Se apagan tus sentidos uno a uno. No es el final, es una pausa, pero se siente como morir otra vez. Quince minutos a oscuras.'),
('neutralization','zombie','Caes inerte sobre el suelo frío. Los demás te ven, te rodean, te dejan atrás. Volverás. Siempre se vuelve.'),
('neutralization','zombie','Algo te tumba y el radar enmudece. Estás ahí, visible, indefenso, mientras la ciudad sigue cazando sin ti. Por ahora.');

-- ---------------------------------------------------------------------
-- FIN DE PARTIDA — ganan civiles (difusión, rol NULL)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('game_end_civils',NULL,'A todas las unidades: amanece. Los focos de infección quedan contenidos. Hay supervivientes en la zona. Repito: hay supervivientes. La ciudad respira. Corten transmisión.'),
('game_end_civils',NULL,'Última lectura de la onda: pulsos humanos confirmados, suficientes para resistir. Lo imposible ha ocurrido. Aguantasteis. Esto es el final de la emisión.'),
('game_end_civils',NULL,'Cierre de protocolo. La noche ha terminado y todavía late gente bajo estos tejados. Recordad lo que visteis. Nadie os creerá. Corto.'),
('game_end_civils',NULL,'La horda no ha vencido. Que conste en el registro: en Sant Feliu, esta vez, ganaron los vivos. Fin de la transmisión.');

-- ---------------------------------------------------------------------
-- FIN DE PARTIDA — ganan zombies (difusión, rol NULL)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('game_end_zombies',NULL,'A cualquier unidad que aún escuche… la onda está muda. No quedan pulsos humanos en la zona. No queda nadie que responda. La ciudad es suya. Corten—'),
('game_end_zombies',NULL,'Última lectura: silencio. Donde había miedo, ahora solo hay hambre que camina. La infección es total. Que Dios se apiade de quien venga después.'),
('game_end_zombies',NULL,'Cierre forzoso de protocolo. Hemos perdido la zona. Hemos perdido a todos. Si alguien oye esto, no vengáis. Huid. Corto y cier—'),
('game_end_zombies',NULL,'Que conste en el registro: la noche ganó. Sant Feliu ha caído. No queda voz viva en esta frecuencia. Fin de la trans—');

-- =====================================================================
-- GRANTS
-- =====================================================================
GRANT EXECUTE ON FUNCTION public.get_playable_zone()                      TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_inside_zone(UUID)                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.find_nearby_opponent(UUID, TEXT)         TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_game_active()                         TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_final_report(UUID)                   TO authenticated;
GRANT EXECUTE ON FUNCTION public.pick_narrative(TEXT, TEXT)               TO service_role;
GRANT EXECUTE ON FUNCTION public.create_encounter_transaction(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.compute_and_resolve_encounter(UUID)      TO service_role;
GRANT EXECUTE ON FUNCTION public.apply_timeouts()                         TO service_role;
GRANT EXECUTE ON FUNCTION public.regenerate_civils()                      TO service_role;
GRANT EXECUTE ON FUNCTION public.restore_zombies()                        TO service_role;
GRANT EXECUTE ON FUNCTION public.restore_radar()                          TO service_role;
GRANT EXECUTE ON FUNCTION public.close_game()                             TO service_role;
GRANT EXECUTE ON FUNCTION public.assign_roles_balanced(INT)               TO service_role;
GRANT EXECUTE ON FUNCTION public.get_nearby_players()                     TO authenticated;
GRANT SELECT   ON public.nearby_players                                   TO authenticated;

-- Endurecimiento: el cliente NO debe poder cerrar la partida ni rebarajar roles.
-- Estas funciones solo las usan los crons (service_role) y Angel desde el editor.
REVOKE EXECUTE ON FUNCTION public.assign_roles_balanced(INT) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.close_game()               FROM anon, authenticated;

-- =====================================================================
-- CRONS PROGRAMADOS (pg_cron) — referencia de lo activo
-- =====================================================================
--   apply-timeouts     '5 seconds'   -> SELECT public.apply_timeouts();
--   restore-zombies    '30 seconds'  -> SELECT public.restore_zombies();
--   restore-radar      '30 seconds'  -> SELECT public.restore_radar();
--   regenerate-civils  '0 * * * *'   -> SELECT public.regenerate_civils();
--   close-game         '30 seconds'  -> SELECT public.close_game();
-- (close-game se programó una vez con cron.schedule; no es CREATE OR REPLACE.)
-- assign_roles_balanced NO es cron: se lanza a mano antes de abrir la partida.