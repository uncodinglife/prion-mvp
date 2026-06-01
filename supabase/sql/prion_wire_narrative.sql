-- =====================================================================
-- PROYECTO PRION - Enchufado del banco narrativo
-- pick_narrative + reescritura de las funciones que emiten mensajes para
-- que saquen el texto al azar de la tabla narrative en vez de tenerlo fijo.
-- Requiere que la tabla narrative exista y esté poblada (prion_narrative.sql).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Selector de frase al azar para una situación/rol.
-- role IS NOT DISTINCT FROM p_role -> casa NULL con NULL (difusión).
-- ---------------------------------------------------------------------
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

GRANT EXECUTE ON FUNCTION public.pick_narrative(TEXT, TEXT) TO service_role;

-- ---------------------------------------------------------------------
-- ENCUENTRO: creación transaccional. Detección desde la tabla.
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

-- ---------------------------------------------------------------------
-- COMBATE: motor único. Mensajes de combate, conversión y neutralización
-- desde la tabla narrative. Los daños, dado y daño en (paréntesis) los
-- siguen marcando los textos de la tabla; las cifras del dado viven en
-- dice_roll para el overlay.
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

-- ---------------------------------------------------------------------
-- CIERRE: mensaje final de partida desde la tabla.
-- Una sola frase al azar, la misma para todos (transmisión de la central).
-- ---------------------------------------------------------------------
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