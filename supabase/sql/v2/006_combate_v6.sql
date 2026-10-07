-- =====================================================================
-- Prion v2.3 — Migración 006: combate v6
-- Redactada 07/10/2026 sobre el esquema real de prion-mvp (001–005 aplicadas).
-- Se aplica en UNA sola transacción (BEGIN ... COMMIT al final del archivo).
--
-- Especificación: tools/equilibrio/combate_v6.py (tabla CELLS) y
-- combate_v6_carga.py (estados de carga), aprobados por Angel el 06/10.
-- Diseño: documento del proyecto, "Combate v6", "Combate v6 con estados de
-- carga", "Zombie eliminado" y "Recuperación del zombie".
--
-- Qué cambia:
--   * Los encuentros v2 dejan la tabla v1 ×10 y pasan a 3 asaltos con pulso:
--     P(gana el civil) = Fc^k / (Fc^k + Fz^k).
--   * La tabla de cruces es datos (combat_cells); todos los números, en
--     game_params. Nada de equilibrio escrito en el código.
--   * Decisión por SQL (combat_decide) y estado por SQL (combat_state). La edge
--     function submit_decision y la tabla v1 siguen solo para jugadores v1.
--   * Caída del zombie: 10 min, se levanta con 10 y recupera +1/min durante
--     50 min; pierde el 50 % del poder y el 25 % de la mutación. +4 por
--     mordisco que acierta, +10 cuando se convierte un civil al que mordió.
--
-- Criterios técnicos (Claude):
--   * Un asalto abierto = una fila de combat_rounds sin resolved_at. La
--     decisión del rival nunca sale del servidor antes de resolver el asalto
--     (combat_rounds no tiene política RLS; solo combat_state la lee).
--   * El asalto se resuelve en cuanto deciden los dos, o al vencer el plazo:
--     lo hace el cron apply_timeouts (5 s) o, antes, la primera llamada a
--     combat_state/combat_decide que lo encuentre vencido.
--   * Entre asaltos hay combat_pulse_s segundos para el pulso del cliente:
--     el siguiente asalto abre cuando acaba la animación.
--   * El azar sale de v2_combat_roll() (random()). Las pruebas la sustituyen
--     por una cola de tiradas; en producción no hay forma de forzarla.
--   * Equipamiento (combat_gear) y carga (cargo_food / cargo_serum) son
--     columnas nuevas de players. Hoy nadie las rellena salvo el editor SQL:
--     las armas llegan con los roles y la carga con el bloque 2 (sueros,
--     carga, caducidad). El combate ya las lee y ya hace perder la carga.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Parámetros (todos provisionales; se ajustan en pruebas)
-- ---------------------------------------------------------------------
INSERT INTO public.game_params (key, value, unit, description) VALUES
  ('combat_k',                   2,    'exponente', 'Regulador de azar del pulso: P = Fc^k / (Fc^k + Fz^k). Más alto, menos azar'),
  ('combat_force_hit_none',      0.75, 'fuerza',    'Golpe a mano (civil sin herramienta ni arma)'),
  ('combat_force_hit_tool',      1.38, 'fuerza',    'Golpe con herramienta'),
  ('combat_force_hit_weapon',    1.94, 'fuerza',    'Disparo'),
  ('combat_hit_damage',          8,    'vida',      'Daño del golpe que acierta, antes del multiplicador del equipamiento'),
  ('combat_hit_mult_none',       1,    'factor',    'Multiplicador de daño del golpe a mano'),
  ('combat_hit_mult_tool',       1.5,  'factor',    'Multiplicador de daño del golpe con herramienta'),
  ('combat_hit_mult_weapon',     2,    'factor',    'Multiplicador de daño del disparo'),
  ('combat_base_hit_chase',      1.7,  'fuerza',    'Golpear a quien te persigue (sorpresa)'),
  ('combat_base_block_bite',     3.8,  'fuerza',    'Bloquear el mordisco'),
  ('combat_base_flee_bite',      2.7,  'fuerza',    'Huir de quien muerde (se gira y escapa)'),
  ('combat_base_flee_chase',     0.55, 'fuerza',    'Huir de quien persigue (carrera)'),
  ('combat_base_flee_grab',      1.6,  'fuerza',    'Huir de quien intenta agarrar'),
  ('combat_base_grab1',          0.90, 'fuerza',    'Zafarse de un mordisco con un brazo agarrado'),
  ('combat_base_grab2',          0.35, 'fuerza',    'Zafarse de un mordisco con los dos brazos agarrados'),
  ('combat_age_strength_joven',  1.00, 'factor',    'Fuerza por tramo de edad: joven'),
  ('combat_age_strength_medio',  1.05, 'factor',    'Fuerza por tramo de edad: medio'),
  ('combat_age_strength_viejo',  0.95, 'factor',    'Fuerza por tramo de edad: viejo'),
  ('combat_age_agility_joven',   1.10, 'factor',    'Agilidad por tramo de edad: joven'),
  ('combat_age_agility_medio',   1.00, 'factor',    'Agilidad por tramo de edad: medio'),
  ('combat_age_agility_viejo',   0.90, 'factor',    'Agilidad por tramo de edad: viejo'),
  ('combat_health_floor',        0.6,  'factor',    'Factor de salud del civil = suelo + (1 - suelo) × vida / vida máx.'),
  ('combat_fatigue_round',       0.93, 'factor',    'Cansancio del civil por cada asalto ya disputado'),
  ('combat_fatigue_flee',        0.85, 'factor',    'Cansancio extra en agilidad por cada huida fallida'),
  ('combat_exp_max',             0.10, 'fracción',  'Bonus máximo de experiencia (los dos bandos)'),
  ('combat_exp_full_combats',    50,   'combates',  'Combates con los que la experiencia llega a su máximo (curva logarítmica)'),
  ('combat_noise_overexcite',    1.25, 'factor',    'Fuerza del zombie tras oír un disparo, el resto del combate'),
  ('combat_round1_s',            15,   's',         'Tiempo para decidir en el asalto 1'),
  ('combat_round2_s',            10,   's',         'Tiempo para decidir en el asalto 2'),
  ('combat_round3_s',            7,    's',         'Tiempo para decidir en el asalto 3'),
  ('combat_pulse_s',             5,    's',         'Pausa entre asaltos para el pulso del cliente'),
  ('combat_max_rounds',          3,    'asaltos',   'Asaltos máximos por combate'),
  ('combat_points_to_win',       2,    'puntos',    'Puntos que acaban el combate'),
  ('cargo_food_strength',        0.90, 'factor',    'Fuerza al golpear y bloquear mientras defiende comida'),
  ('cargo_serum_strength',       0.95, 'factor',    'Fuerza al golpear y bloquear mientras defiende la nevera de suero'),
  ('zombie_bite_heal',           4,    'resistencia', 'Resistencia que recupera el zombie por mordisco que acierta'),
  ('zombie_convert_heal',        10,   'resistencia', 'Resistencia que recupera cada zombie que mordió a un civil cuando este se convierte'),
  ('zombie_recover_per_min',     1,    'resistencia/min', 'Recuperación del zombie tras levantarse'),
  ('zombie_recover_minutes',     50,   'min',       'Duración de la recuperación tras levantarse'),
  ('zombie_down_power_loss',     0.5,  'fracción',  'Fracción del poder que pierde el zombie al caer'),
  ('zombie_down_mutation_loss',  0.25, 'fracción',  'Fracción de la mutación que pierde el zombie al caer')
ON CONFLICT (key) DO NOTHING;

UPDATE public.game_params SET value = 10,
  description = 'Minutos que el zombie eliminado pasa en el suelo (decidido 04/10)'
 WHERE key = 'zombie_down_minutes';
UPDATE public.game_params SET value = 10,
  description = 'Resistencia con la que se levanta un zombie caído (decidido 04/10)'
 WHERE key = 'zombie_up_resistance';
-- Sustituido por zombie_down_power_loss y zombie_down_mutation_loss.
DELETE FROM public.game_params WHERE key = 'zombie_down_index_loss';
UPDATE public.game_params SET
  description = 'OBSOLETO desde la 006: solo lo usaba el combate v1 ×10 entre jugadores v2'
 WHERE key = 'combat_damage_scale';

-- ---------------------------------------------------------------------
-- 2. Tabla de cruces (especificación: CELLS de combate_v6.py)
--    grab: brazos agarrados al empezar el asalto (0, 1, 2).
--    civil_action: G golpea, B bloquea, H huye, h huida automática (tiempo
--      agotado; se busca siempre con grab 0, vale para cualquier agarre).
--    zombie_action: M muerde, P persigue, A agarra.
--    variant: base, o gear (golpea–agarra con herramienta o arma: el reflejo
--      atrapa el arma).
--    kind: fixed (resultado único, en win) o pulse (win = gana el civil,
--      lose = gana el zombie).
--    stat: golpe (fuerza × equipamiento; daño del golpe × multiplicador),
--      fuerza, agil.
--    base_param: clave de game_params con la fuerza base; NULL en golpe =
--      la fuerza del equipamiento.
--    Resultado (jsonb): dc/dz daño civil/zombie, pc/pz punto, g agarre en el
--      asalto siguiente, exp boca expuesta, inf mordisco que infecta, end fin
--      del combate (huida), fail huida fallida.
-- ---------------------------------------------------------------------
CREATE TABLE public.combat_cells (
  variant       text     NOT NULL DEFAULT 'base' CHECK (variant IN ('base','gear')),
  grab          smallint NOT NULL CHECK (grab BETWEEN 0 AND 2),
  civil_action  text     NOT NULL CHECK (civil_action IN ('G','B','H','h')),
  zombie_action text     NOT NULL CHECK (zombie_action IN ('M','P','A')),
  kind          text     NOT NULL CHECK (kind IN ('fixed','pulse')),
  stat          text     CHECK (stat IN ('golpe','fuerza','agil')),
  base_param    text     REFERENCES public.game_params(key),
  win           jsonb    NOT NULL,
  lose          jsonb,
  note          text,
  PRIMARY KEY (variant, grab, civil_action, zombie_action),
  CHECK ((kind = 'fixed' AND stat IS NULL AND lose IS NULL)
      OR (kind = 'pulse' AND stat IS NOT NULL AND lose IS NOT NULL)),
  CHECK (kind = 'fixed' OR stat = 'golpe' OR base_param IS NOT NULL)
);
ALTER TABLE public.combat_cells ENABLE ROW LEVEL SECURITY;
-- Lectura para el cliente: la tabla es el reglamento, no un secreto.
CREATE POLICY combat_cells_select ON public.combat_cells FOR SELECT TO authenticated USING (true);

INSERT INTO public.combat_cells (variant, grab, civil_action, zombie_action, kind, stat, base_param, win, lose, note) VALUES
  -- sin agarre
  ('base',0,'G','M','pulse','golpe',NULL,
     '{"dc":2,"dz":8,"pc":1}', '{"dc":8,"dz":2,"pz":1,"inf":true}', 'Pulso de golpe. Con arma y boca expuesta: tiro a la silla turca'),
  ('base',0,'G','P','pulse','golpe','combat_base_hit_chase',
     '{"dc":2,"dz":8,"pc":1}', '{"dc":5,"dz":1,"pz":1}', 'Sorpresa; si falla, le arrolla'),
  ('base',0,'G','A','fixed',NULL,NULL,
     '{"dc":3,"dz":3}', NULL, 'Raso: el golpe aparta'),
  ('base',0,'B','M','pulse','fuerza','combat_base_block_bite',
     '{"dc":2,"dz":2,"pc":1,"exp":true}', '{"dc":4,"dz":1,"pz":1,"inf":true}', 'Boca expuesta; si falla, mordisco en el antebrazo'),
  ('base',0,'B','P','fixed',NULL,NULL,
     '{"dc":1,"dz":1}', NULL, 'Se tantean'),
  ('base',0,'B','A','fixed',NULL,NULL,
     '{"dc":3,"dz":1,"pz":1,"g":1}', NULL, 'Brazo agarrado'),
  ('base',0,'H','M','pulse','agil','combat_base_flee_bite',
     '{"dc":5,"dz":1,"end":true}', '{"dc":8,"dz":1,"pz":1,"inf":true,"fail":true}', 'Escapa con roce; si falla, le muerde al girarse'),
  ('base',0,'H','P','pulse','agil','combat_base_flee_chase',
     '{"dc":3,"dz":1,"end":true}', '{"dc":8,"dz":2,"pz":1,"g":1,"fail":true}', 'Escapa cansado; si falla, cazado = agarrado'),
  ('base',0,'H','A','pulse','agil','combat_base_flee_grab',
     '{"dc":3,"dz":1,"end":true}', '{"dc":3,"dz":1,"pz":1,"g":1,"fail":true}', 'Escapa; si falla, brazo agarrado'),
  ('gear',0,'G','A','fixed',NULL,NULL,
     '{"dc":3,"dz":1,"pz":1,"g":1}', NULL, 'Con herramienta o arma: el arma toca la palma y el reflejo la atrapa'),
  -- un brazo agarrado
  ('base',1,'G','M','pulse','fuerza','combat_base_grab1',
     '{"dc":2,"dz":6,"pc":1}', '{"dc":10,"dz":2,"pz":1,"g":1,"inf":true}', 'Brazo libre contra el mordisco'),
  ('base',1,'B','M','pulse','fuerza','combat_base_grab1',
     '{"dc":2,"dz":2,"pc":1,"exp":true,"g":1}', '{"dc":10,"dz":2,"pz":1,"g":1,"inf":true}', 'Forcejeo contra el mordisco'),
  ('base',1,'H','M','pulse','fuerza','combat_base_grab1',
     '{"dc":3,"dz":1,"end":true}', '{"dc":10,"dz":2,"pz":1,"g":1,"inf":true}', 'Tirón contra el mordisco'),
  ('base',1,'G','P','fixed',NULL,NULL,
     '{"dc":1,"dz":6,"pc":1}', NULL, 'Golpe con el brazo libre: se suelta'),
  ('base',1,'G','A','fixed',NULL,NULL,
     '{"dc":1,"dz":6,"pc":1}', NULL, 'Golpe con el brazo libre: se suelta'),
  ('base',1,'B','P','fixed',NULL,NULL,
     '{"dc":2,"dz":2,"g":1}', NULL, 'Forcejeo'),
  ('base',1,'B','A','fixed',NULL,NULL,
     '{"dc":3,"dz":1,"pz":1,"g":2}', NULL, 'Segundo brazo'),
  ('base',1,'H','P','fixed',NULL,NULL,
     '{"dc":3,"dz":1,"pz":1,"g":1,"fail":true}', NULL, 'Tirón fallido'),
  ('base',1,'H','A','fixed',NULL,NULL,
     '{"dc":3,"dz":1,"end":true}', NULL, 'Tirón: se suelta y escapa'),
  -- dos brazos agarrados (huir desactivado)
  ('base',2,'G','M','pulse','fuerza','combat_base_grab2',
     '{"dc":2,"dz":6,"pc":1,"g":1}', '{"dc":12,"dz":2,"pz":1,"g":2,"inf":true}', 'Patada contra el mordisco'),
  ('base',2,'B','M','pulse','fuerza','combat_base_grab2',
     '{"dc":2,"dz":2,"pc":1,"g":2,"exp":true}', '{"dc":12,"dz":2,"pz":1,"g":2,"inf":true}', 'Forcejeo contra el mordisco'),
  ('base',2,'G','P','fixed',NULL,NULL,
     '{"dc":1,"dz":6,"pc":1,"g":1}', NULL, 'Patada: libera un brazo'),
  ('base',2,'G','A','fixed',NULL,NULL,
     '{"dc":1,"dz":6,"pc":1,"g":1}', NULL, 'Patada: libera un brazo'),
  ('base',2,'B','P','fixed',NULL,NULL,
     '{"dc":2,"dz":2,"g":2}', NULL, 'Forcejeo'),
  ('base',2,'B','A','fixed',NULL,NULL,
     '{"dc":2,"dz":2,"g":2}', NULL, 'Forcejeo'),
  -- huida automática por tiempo agotado (sin pulso, nunca infecta)
  ('base',0,'h','M','fixed',NULL,NULL,
     '{"dc":5,"dz":1,"end":true}', NULL, 'Tiempo agotado: escapa'),
  ('base',0,'h','P','fixed',NULL,NULL,
     '{"dc":8,"dz":2,"pz":1}', NULL, 'Tiempo agotado: le caza (sin agarre); dos cazas = fin'),
  ('base',0,'h','A','fixed',NULL,NULL,
     '{"dc":3,"dz":1,"end":true}', NULL, 'Tiempo agotado: escapa');

-- ---------------------------------------------------------------------
-- 3. Jugador: equipamiento, carga, experiencia y recuperación del zombie
-- ---------------------------------------------------------------------
ALTER TABLE public.players
  ADD COLUMN combat_gear          text     NOT NULL DEFAULT 'none'
       CHECK (combat_gear IN ('none','tool','weapon')),
  ADD COLUMN cargo_food           smallint NOT NULL DEFAULT 0 CHECK (cargo_food >= 0),
  ADD COLUMN cargo_serum          smallint NOT NULL DEFAULT 0 CHECK (cargo_serum >= 0),
  ADD COLUMN combats_count        integer  NOT NULL DEFAULT 0 CHECK (combats_count >= 0),
  ADD COLUMN zombie_recover_until timestamptz;

-- ---------------------------------------------------------------------
-- 4. Encuentro v6 y asaltos
-- ---------------------------------------------------------------------
-- Ojo: los jugadores leen su fila de encounters (política encounters_select_own,
-- el cliente v1 hace select('*')). Aquí solo va lo que los dos pueden ver. La
-- boca expuesta, que nadie debe ver, vive en combat_rounds.outcome.
ALTER TABLE public.encounters
  ADD COLUMN combat_version smallint,        -- 6 = combate v6; NULL = v1 / v2 ×10
  ADD COLUMN round          smallint,
  ADD COLUMN grab           smallint,
  ADD COLUMN noise          boolean,
  ADD COLUMN civil_fails    smallint,
  ADD COLUMN civil_points   smallint,
  ADD COLUMN zombie_points  smallint,
  ADD COLUMN end_reason     text;

CREATE TABLE public.combat_rounds (
  encounter_id      uuid     NOT NULL REFERENCES public.encounters(id) ON DELETE CASCADE,
  round             smallint NOT NULL CHECK (round BETWEEN 1 AND 10),
  opens_at          timestamptz NOT NULL,
  deadline          timestamptz NOT NULL,
  grab              smallint NOT NULL,
  civil_action      text CHECK (civil_action IN ('G','B','H','h')),
  zombie_action     text CHECK (zombie_action IN ('M','P','A')),
  civil_decided_at  timestamptz,
  zombie_decided_at timestamptz,
  civil_timed_out   boolean NOT NULL DEFAULT false,
  zombie_timed_out  boolean NOT NULL DEFAULT false,
  cell_variant      text,
  p_civil           numeric,          -- NULL en cruces sin pulso
  civil_won         boolean,          -- NULL en cruces sin pulso
  outcome           jsonb,
  civil_damage      smallint,
  zombie_damage     smallint,
  bite              boolean NOT NULL DEFAULT false,
  noise             boolean NOT NULL DEFAULT false,
  eliminated        boolean NOT NULL DEFAULT false,
  cargo_lost        boolean NOT NULL DEFAULT false,
  resolved_at       timestamptz,
  PRIMARY KEY (encounter_id, round)
);
CREATE UNIQUE INDEX combat_rounds_one_open ON public.combat_rounds (encounter_id) WHERE resolved_at IS NULL;
CREATE INDEX combat_rounds_open_deadline ON public.combat_rounds (deadline) WHERE resolved_at IS NULL;
-- Sin políticas: la decisión del rival no sale del servidor. Se lee con combat_state().
ALTER TABLE public.combat_rounds ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.combat_rounds FROM anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Eventos nuevos
-- ---------------------------------------------------------------------
ALTER TABLE public.events DROP CONSTRAINT IF EXISTS events_type_check;
ALTER TABLE public.events ADD CONSTRAINT events_type_check CHECK (type = ANY (ARRAY[
  'encounter_start','encounter_result','life_regen','conversion','neutralization',
  'restoration','radar_restored','game_start','game_end',
  'character_created','outbreak','infected','incubation_tick','reconversion',
  'refuge_enter','refuge_exit','refuge_spent','rest_start','rest_stop',
  'food_eaten','hunger_damage','loot_started','loot_completed','loot_aborted',
  'overexcite_start','overexcite_end','zombie_down','zombie_up',
  -- 006
  'cargo_lost','zombie_eliminated','zombie_recovered'
]));

-- ---------------------------------------------------------------------
-- 6. Banco neutro de avisos "el rival ya ha elegido" (decisión de Angel
--    06/10). La frase no puede depender de la acción elegida (sería una
--    filtración): se saca al azar por rol. Textos de relleno: los escribe
--    Angel (encargo de escritura).
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
  ('combat_rival_ready', 'civil',  '¡Rápido, vuelve a por ti!'),
  ('combat_rival_ready', 'civil',  '¡Cuidado, se abalanza sobre ti!'),
  ('combat_rival_ready', 'civil',  'Ya se mueve. No te quedes quieto.'),
  ('combat_rival_ready', 'zombie', 'La presa se mueve.'),
  ('combat_rival_ready', 'zombie', 'El sabor del aire cambia. Ahora.'),
  ('combat_rival_ready', 'zombie', 'Algo tiembla delante de ti.');

-- ---------------------------------------------------------------------
-- 7. Azar (las pruebas sustituyen esta función; producción usa random())
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_combat_roll()
RETURNS double precision LANGUAGE sql VOLATILE
SET search_path = public, extensions, pg_temp AS $$ SELECT random() $$;

-- ---------------------------------------------------------------------
-- 8. Probabilidad del pulso (función pura; es outcomes() de combate_v6.py)
--    Devuelve P(gana el civil). Fc = base × salud × edad × cansancio ×
--    experiencia × carga; Fz = sobreexcitación × experiencia.
--    p_rounds_done: asaltos ya disputados en este combate.
--    p_cargo_f: penalización de carga (1 si no lleva o ya la perdió); solo
--    afecta cuando el civil golpea o bloquea.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_combat_pulse_prob(
  p_stat text, p_base_param text, p_civil_action text, p_gear text, p_band text,
  p_life numeric, p_life_max numeric, p_rounds_done integer, p_fails integer,
  p_exp_civil integer, p_exp_zombie integer, p_noise boolean, p_cargo_f numeric)
RETURNS numeric LANGUAGE plpgsql STABLE
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_k numeric := v2_param('combat_k');
  v_floor numeric := v2_param('combat_health_floor');
  v_base numeric;
  v_age numeric;
  v_fat numeric;
  v_fc numeric;
  v_fz numeric;
  v_full numeric := v2_param('combat_exp_full_combats');
  v_emax numeric := v2_param('combat_exp_max');
BEGIN
  IF p_stat = 'golpe' AND p_base_param IS NULL THEN
    v_base := v2_param('combat_force_hit_' || p_gear);
  ELSE
    v_base := v2_param(p_base_param);
  END IF;
  v_age := v2_param(CASE WHEN p_stat = 'agil' THEN 'combat_age_agility_' ELSE 'combat_age_strength_' END || p_band);
  v_fat := power(v2_param('combat_fatigue_round'), p_rounds_done);
  IF p_stat = 'agil' THEN
    v_fat := v_fat * power(v2_param('combat_fatigue_flee'), p_fails);
  END IF;
  v_fc := v_base
        * (v_floor + (1 - v_floor) * GREATEST(p_life, 0) / p_life_max)
        * v_age * v_fat
        * (1 + v_emax * LEAST(1.0, ln(1 + p_exp_civil) / ln(1 + v_full)))
        * CASE WHEN p_civil_action IN ('G','B') THEN p_cargo_f ELSE 1 END;
  v_fz := CASE WHEN p_noise THEN v2_param('combat_noise_overexcite') ELSE 1 END
        * (1 + v_emax * LEAST(1.0, ln(1 + p_exp_zombie) / ln(1 + v_full)));
  RETURN power(v_fc, v_k) / (power(v_fc, v_k) + power(v_fz, v_k));
END $$;

-- ---------------------------------------------------------------------
-- 9. Caída del zombie (eliminado = neutralizado, decidido 04/10)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_zombie_fall(p_player uuid, p_now timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_down_min numeric := v2_param('zombie_down_minutes');
BEGIN
  UPDATE players SET life = 0, life_pending = 0,
         down_until = p_now + (v_down_min::float8 * interval '1 minute'),
         status = 'neutralized', status_until = p_now + (v_down_min::float8 * interval '1 minute'),
         overexcited_until = NULL, zombie_recover_until = NULL,
         role_points = floor(role_points * (1 - v2_param('zombie_down_power_loss')))::int,
         mutation_points = floor(mutation_points * (1 - v2_param('zombie_down_mutation_loss')))::int
   WHERE id = p_player;
  UPDATE poi_visits SET aborted_at = now()
   WHERE player_id = p_player AND completed_at IS NULL AND aborted_at IS NULL;
  PERFORM v2_event(p_player, 'zombie_down',
    'Caes. Tu cuerpo no responde y parte de lo que habías ganado se desvanece.',
    jsonb_build_object('minutes', v_down_min));
END $$;

-- ---------------------------------------------------------------------
-- 10. Conversión: +10 a cada zombie que mordió a este civil desde que se
--     infectó; la carga se queda en el suelo; convertirse borra la
--     experiencia de combate (decidido 06/10: de civil a zombie se pierde todo).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_convert_to_zombie(p_player uuid, p_cause text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_res smallint := v2_param('zombie_resistance_start')::smallint;
  v_type text;
  v_infected timestamptz;
  v_heal integer := v2_param('zombie_convert_heal')::int;
  v_z record;
BEGIN
  SELECT infected_at INTO v_infected FROM players WHERE id = p_player;

  UPDATE players SET role = 'zombie', rank = 'raso', life_max = v_res, life = v_res,
         infected_at = NULL, resting = false, life_pending = 0,
         overexcited_until = NULL, down_until = NULL, status = 'active', status_until = NULL,
         cargo_food = 0, cargo_serum = 0, combats_count = 0, zombie_recover_until = NULL
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

  IF v_infected IS NOT NULL THEN
    FOR v_z IN
      SELECT DISTINCT e.zombie_id FROM combat_rounds cr JOIN encounters e ON e.id = cr.encounter_id
       WHERE e.civil_id = p_player AND cr.bite AND cr.resolved_at >= v_infected
         AND e.zombie_id <> p_player
    LOOP
      UPDATE players SET life = LEAST(life_max, life + v_heal)
       WHERE id = v_z.zombie_id AND role = 'zombie' AND down_until IS NULL;
      IF FOUND THEN
        PERFORM v2_event(v_z.zombie_id, 'zombie_recovered',
          'Uno de los que mordiste ya es de los vuestros. Te sientes más fuerte.',
          jsonb_build_object('resistance', v_heal));
      END IF;
    END LOOP;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 11. Efectos continuos: levantamiento y recuperación del zombie
--     (resto igual que en la 005)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_apply_effects(p_player uuid, p_now timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  p players%ROWTYPE;
  b age_bands%ROWTYPE;
  t refuge_types%ROWTYPE;
  v_active_until timestamptz;
  v_from timestamptz;
  dt_h numeric;
  v_delta numeric := 0;
  v_acc numeric;
  v_whole integer;
  v_life integer;
  v_drain_h numeric;
  v_rec_h numeric;
  v_up boolean := false;
BEGIN
  SELECT * INTO p FROM players WHERE id = p_player FOR UPDATE;
  IF NOT FOUND OR p.age_band IS NULL THEN RETURN; END IF;

  IF p.last_effects_at IS NULL OR p.last_effects_at >= p_now THEN
    UPDATE players SET last_effects_at = GREATEST(COALESCE(p.last_effects_at, p_now), p_now) WHERE id = p_player;
    RETURN;
  END IF;

  -- Zombie que se levanta: con zombie_up_resistance, y la recuperación cuenta
  -- desde el minuto exacto en que se levantó (no desde que alguien lo mira).
  v_from := p.last_effects_at;
  IF p.role = 'zombie' AND p.down_until IS NOT NULL AND p.down_until <= p_now THEN
    p.life := LEAST(p.life_max, v2_param('zombie_up_resistance')::int);
    p.life_pending := 0;
    p.zombie_recover_until := p.down_until + v2_param('zombie_recover_minutes')::float8 * interval '1 minute';
    v_from := GREATEST(v_from, p.down_until);
    UPDATE players SET life = p.life, life_pending = 0, status = 'active', status_until = NULL,
           down_until = NULL, zombie_recover_until = p.zombie_recover_until
     WHERE id = p_player;
    p.down_until := NULL;
    v_up := true;
    PERFORM v2_event(p_player, 'zombie_up', 'Te levantas. El hambre vuelve a mandar.', NULL);
  END IF;

  dt_h := LEAST(EXTRACT(epoch FROM p_now - v_from),
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

  -- Recuperación del zombie tras levantarse (+1/min durante 50 min).
  IF p.role = 'zombie' AND p.down_until IS NULL AND p.zombie_recover_until IS NOT NULL THEN
    v_rec_h := GREATEST(0, EXTRACT(epoch FROM LEAST(p_now, p.zombie_recover_until) - v_from)) / 3600.0;
    v_rec_h := LEAST(v_rec_h, dt_h);
    v_delta := v_delta + v2_param('zombie_recover_per_min') * 60 * v_rec_h;
  END IF;

  v_acc := p.life_pending + v_delta;
  v_whole := trunc(v_acc)::integer;
  v_acc := v_acc - v_whole;
  v_life := p.life + v_whole;
  IF v_life >= p.life_max THEN v_life := p.life_max; IF v_acc > 0 THEN v_acc := 0; END IF; END IF;
  IF v_life <= 0 THEN v_life := 0; v_acc := 0; END IF;

  UPDATE players SET life = v_life, life_pending = v_acc, last_effects_at = p_now,
         zombie_recover_until = CASE WHEN p.zombie_recover_until IS NOT NULL
                                      AND (p.zombie_recover_until <= p_now OR v_life >= p.life_max)
                                     THEN NULL ELSE p.zombie_recover_until END
   WHERE id = p_player;

  -- Caducidad de refugio temporal (zona mixta activada, escondite).
  IF p.inside_refuge_id IS NOT NULL AND v_active_until IS NOT NULL AND v_active_until <= p_now THEN
    PERFORM v2_exit_refuge(p_player, 'expired', NULL);
  END IF;

  -- Fin del enfriamiento tras combate.
  IF p.status = 'radar_disabled' AND p.status_until IS NOT NULL AND p.status_until <= p_now THEN
    UPDATE players SET status = 'active', status_until = NULL WHERE id = p_player;
  END IF;

  IF p.role = 'civil' AND v_life = 0 THEN
    PERFORM v2_convert_to_zombie(p_player, CASE WHEN p.infected_at IS NOT NULL THEN 'infection' ELSE 'exhaustion' END);
    RETURN;
  END IF;

  IF p.role = 'zombie' THEN
    IF p.down_until IS NULL AND v_life = 0 AND NOT v_up THEN
      PERFORM v2_zombie_fall(p_player, p_now);
    END IF;
    IF p.overexcited_until IS NOT NULL AND p.overexcited_until <= p_now THEN
      UPDATE players SET overexcited_until = NULL WHERE id = p_player;
      PERFORM v2_event(p_player, 'overexcite_end', 'La excitación se apaga. El olor de la sangre se pierde.', NULL);
    END IF;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 12. Abrir un asalto
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_combat_open_round(
  p_encounter uuid, p_round integer, p_grab integer, p_opens timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_secs numeric := v2_param('combat_round' || LEAST(p_round, 3) || '_s');
BEGIN
  INSERT INTO combat_rounds (encounter_id, round, opens_at, deadline, grab)
  VALUES (p_encounter, p_round, p_opens, p_opens + v_secs::float8 * interval '1 second', p_grab);
  UPDATE encounters SET round = p_round, grab = p_grab WHERE id = p_encounter;
END $$;

-- ---------------------------------------------------------------------
-- 13. Cerrar el combate
--     p_reason: fled, eliminated, zombie_down, converted, civil_points,
--     zombie_points, rounds, interrupted.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_combat_finish(
  p_encounter uuid, p_reason text, p_converted boolean, p_zombie_down boolean,
  p_eliminated boolean, p_now timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  e encounters%ROWTYPE;
  v_cd integer := v2_param('combat_cooldown_s')::int;
  v_flee_cd integer := v2_param('combat_flee_cooldown_s')::int;
  v_cmsg text;
  v_zmsg text;
  v_cdmg integer;
  v_zdmg integer;
BEGIN
  SELECT * INTO e FROM encounters WHERE id = p_encounter FOR UPDATE;
  SELECT COALESCE(sum(civil_damage), 0), COALESCE(sum(zombie_damage), 0) INTO v_cdmg, v_zdmg
    FROM combat_rounds WHERE encounter_id = p_encounter AND resolved_at IS NOT NULL;

  -- Por si quedara un asalto abierto (interrupción).
  DELETE FROM combat_rounds WHERE encounter_id = p_encounter AND resolved_at IS NULL;

  UPDATE encounters SET result = 'v6_' || p_reason, end_reason = p_reason, resolved_at = p_now,
         civil_damage = LEAST(v_cdmg, 32767), zombie_damage = LEAST(v_zdmg, 32767)
   WHERE id = p_encounter;

  -- Civil
  IF p_converted THEN
    UPDATE players SET life = 0, current_encounter_id = NULL WHERE id = e.civil_id;
    PERFORM v2_convert_to_zombie(e.civil_id, 'combat');
  ELSE
    UPDATE players SET current_encounter_id = NULL,
           combats_count = combats_count + CASE WHEN p_reason = 'interrupted' THEN 0 ELSE 1 END,
           status = CASE WHEN role = 'civil' THEN 'radar_disabled' ELSE status END,
           status_until = CASE WHEN role = 'civil'
             THEN p_now + (CASE WHEN p_reason = 'fled' THEN v_flee_cd ELSE v_cd END) * interval '1 second'
             ELSE status_until END
     WHERE id = e.civil_id;
  END IF;

  -- Zombie
  IF p_zombie_down THEN
    UPDATE players SET current_encounter_id = NULL,
           combats_count = combats_count + 1 WHERE id = e.zombie_id;
    PERFORM v2_zombie_fall(e.zombie_id, p_now);
    IF p_eliminated THEN
      PERFORM v2_event(e.zombie_id, 'zombie_eliminated',
        'Un estallido dentro de la cabeza. Todo se apaga de golpe.', NULL);
    END IF;
  ELSE
    UPDATE players SET current_encounter_id = NULL,
           combats_count = combats_count + CASE WHEN p_reason = 'interrupted' THEN 0 ELSE 1 END,
           status = CASE WHEN role = 'zombie' AND down_until IS NULL THEN 'radar_disabled' ELSE status END,
           status_until = CASE WHEN role = 'zombie' AND down_until IS NULL
             THEN p_now + v_cd * interval '1 second' ELSE status_until END
     WHERE id = e.zombie_id;
  END IF;

  v_cmsg := COALESCE(pick_narrative('combat_' || p_reason, 'civil'), CASE p_reason
    WHEN 'fled'          THEN 'Corres sin mirar atrás. Lo has dejado atrás.'
    WHEN 'eliminated'    THEN 'El disparo entra por la boca abierta. Cae y no se mueve.'
    WHEN 'zombie_down'   THEN 'Cae al suelo. Por ahora, no se levanta.'
    WHEN 'converted'     THEN 'Ya no hay nada que hacer.'
    WHEN 'civil_points'  THEN 'Lo has frenado. Aprovecha y aléjate.'
    WHEN 'zombie_points' THEN 'Te ha superado. Sales de ahí como puedes.'
    WHEN 'rounds'        THEN 'Os separáis, exhaustos.'
    ELSE 'El encuentro se interrumpe.' END);
  v_zmsg := COALESCE(pick_narrative('combat_' || p_reason, 'zombie'), CASE p_reason
    WHEN 'fled'          THEN 'La presa se escapa. El sabor se aleja.'
    WHEN 'eliminated'    THEN 'Un estruendo dentro de ti.'
    WHEN 'zombie_down'   THEN 'Tus piernas ceden.'
    WHEN 'converted'     THEN 'La presa deja de luchar. Ya es de los vuestros.'
    WHEN 'civil_points'  THEN 'La presa se resiste. Se aleja.'
    WHEN 'zombie_points' THEN 'La presa sangra. Se te escapa entre los dedos.'
    WHEN 'rounds'        THEN 'La presa se aleja, tambaleándose.'
    ELSE 'El rastro se pierde.' END);
  INSERT INTO events (player_id, type, message, related_encounter_id, metadata) VALUES
    (e.civil_id,  'encounter_result', v_cmsg, p_encounter, jsonb_build_object('end_reason', p_reason, 'damage', v_cdmg)),
    (e.zombie_id, 'encounter_result', v_zmsg, p_encounter, jsonb_build_object('end_reason', p_reason, 'damage', v_zdmg));
END $$;

-- ---------------------------------------------------------------------
-- 14. Resolver el asalto abierto
--     Lo resuelve si los dos han decidido o si ha vencido el plazo (tiempo
--     agotado: civil huida automática, o forcejeo si tiene los dos brazos
--     agarrados; zombie muerde). Devuelve true si ha resuelto algo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_combat_resolve_round(p_encounter uuid, p_now timestamptz DEFAULT now())
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  e encounters%ROWTYPE;
  r combat_rounds%ROWTYPE;
  c players%ROWTYPE;
  z players%ROWTYPE;
  cell combat_cells%ROWTYPE;
  v_a text;
  v_b text;
  v_c_to boolean := false;
  v_z_to boolean := false;
  v_variant text := 'base';
  v_grab integer;
  v_q numeric;
  v_won boolean;
  o jsonb;
  v_noise_now boolean := false;
  v_elim boolean := false;
  v_cargo_f numeric := 1;
  v_has_cargo boolean;
  v_drop boolean := false;
  v_dc integer; v_dz integer; v_inf boolean; v_end boolean;
  v_c_life integer; v_z_life integer;
  v_pc integer; v_pz integer;
  v_conv boolean; v_down boolean;
  v_reason text;
  v_exposed boolean;
BEGIN
  SELECT * INTO e FROM encounters WHERE id = p_encounter FOR UPDATE;
  IF NOT FOUND OR e.result IS NOT NULL OR e.combat_version IS DISTINCT FROM 6 THEN RETURN false; END IF;
  SELECT * INTO r FROM combat_rounds WHERE encounter_id = p_encounter AND resolved_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  IF (r.civil_action IS NULL OR r.zombie_action IS NULL) AND p_now < r.deadline THEN RETURN false; END IF;

  -- Bloqueo en orden fijo (civil, zombie) y efectos pendientes antes del daño.
  PERFORM 1 FROM players WHERE id = e.civil_id FOR UPDATE;
  PERFORM 1 FROM players WHERE id = e.zombie_id FOR UPDATE;
  PERFORM v2_apply_effects(e.civil_id, p_now);
  PERFORM v2_apply_effects(e.zombie_id, p_now);
  SELECT * INTO c FROM players WHERE id = e.civil_id;
  SELECT * INTO z FROM players WHERE id = e.zombie_id;

  -- Si los efectos continuos han cambiado a alguno de bando o tumbado al
  -- zombie a mitad de combate, el combate se interrumpe.
  IF c.role <> 'civil' OR z.role <> 'zombie' OR z.down_until IS NOT NULL THEN
    PERFORM v2_combat_finish(p_encounter, 'interrupted', false, false, false, p_now);
    RETURN true;
  END IF;

  v_grab := r.grab;
  -- Boca expuesta en el asalto anterior.
  SELECT COALESCE((outcome->>'exp')::boolean, false) INTO v_exposed
    FROM combat_rounds WHERE encounter_id = p_encounter AND round = r.round - 1;
  v_exposed := COALESCE(v_exposed, false);
  v_a := r.civil_action;
  v_b := r.zombie_action;
  IF v_a IS NULL THEN
    v_a := CASE WHEN v_grab = 2 THEN 'B' ELSE 'h' END;
    v_c_to := true;
  END IF;
  IF v_b IS NULL THEN v_b := 'M'; v_z_to := true; END IF;

  IF v_a = 'h' THEN
    SELECT * INTO cell FROM combat_cells WHERE variant = 'base' AND grab = 0 AND civil_action = 'h' AND zombie_action = v_b;
  ELSE
    IF v_grab = 0 AND v_a = 'G' AND v_b = 'A' AND c.combat_gear <> 'none' THEN v_variant := 'gear'; END IF;
    SELECT * INTO cell FROM combat_cells
     WHERE variant = v_variant AND grab = v_grab AND civil_action = v_a AND zombie_action = v_b;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cruce sin definir: agarre %, civil %, zombie %, variante %', v_grab, v_a, v_b, v_variant;
  END IF;

  -- El disparo suena siempre, acierte o no (con el brazo del arma libre).
  v_noise_now := v_grab = 0 AND v_a = 'G' AND v_variant = 'base' AND c.combat_gear = 'weapon';

  v_has_cargo := c.cargo_food > 0 OR c.cargo_serum > 0;
  IF v_has_cargo THEN
    v_cargo_f := CASE WHEN c.cargo_food  > 0 THEN v2_param('cargo_food_strength')  ELSE 1 END
               * CASE WHEN c.cargo_serum > 0 THEN v2_param('cargo_serum_strength') ELSE 1 END;
  END IF;

  IF cell.kind = 'fixed' THEN
    o := cell.win;
  ELSE
    v_q := v2_combat_pulse_prob(cell.stat, cell.base_param, v_a, c.combat_gear, c.age_band,
             c.life, c.life_max, r.round - 1, COALESCE(e.civil_fails, 0),
             c.combats_count, z.combats_count, COALESCE(e.noise, false), v_cargo_f);
    v_won := v2_combat_roll() < v_q;
    o := CASE WHEN v_won THEN cell.win ELSE cell.lose END;
    IF cell.stat = 'golpe' AND v_won THEN
      o := o || jsonb_build_object('dz',
        round(v2_param('combat_hit_damage') * v2_param('combat_hit_mult_' || c.combat_gear))::int);
      -- Tiro a la silla turca: militar con arma, boca expuesta en el asalto
      -- anterior y el zombie vuelve a morder (decidido 04/10).
      IF v_grab = 0 AND v_a = 'G' AND v_b = 'M' AND v_exposed
         AND c.combat_gear = 'weapon' AND c.rank IN ('militar', 'medico_militar') THEN
        o := o || '{"dz":0,"end":true}'::jsonb;
        v_elim := true;
      END IF;
    END IF;
  END IF;

  v_dc  := COALESCE((o->>'dc')::int, 0);
  v_dz  := COALESCE((o->>'dz')::int, 0);
  v_inf := COALESCE((o->>'inf')::boolean, false);
  v_end := COALESCE((o->>'end')::boolean, false);

  -- Carga: se pierde al huir (también la huida automática y el tirón), con
  -- los dos brazos agarrados o al forcejear con un brazo agarrado.
  v_drop := v_has_cargo AND (v_a IN ('H','h') OR COALESCE((o->>'g')::int, 0) = 2
                             OR (v_grab = 1 AND v_a = 'B'));

  v_c_life := GREATEST(0, c.life - v_dc);
  v_z_life := CASE WHEN v_elim THEN 0
              ELSE LEAST(z.life_max, z.life - v_dz + CASE WHEN v_inf THEN v2_param('zombie_bite_heal')::int ELSE 0 END) END;
  v_z_life := GREATEST(0, v_z_life);
  v_conv := v_c_life = 0;
  v_down := v_z_life = 0;
  IF v_conv AND v_has_cargo THEN v_drop := true; END IF;

  UPDATE players SET life = v_c_life,
         infected_at = CASE WHEN v_inf AND infected_at IS NULL THEN p_now ELSE infected_at END,
         cargo_food  = CASE WHEN v_drop THEN 0 ELSE cargo_food END,
         cargo_serum = CASE WHEN v_drop THEN 0 ELSE cargo_serum END
   WHERE id = c.id;
  UPDATE players SET life = v_z_life WHERE id = z.id;

  IF v_inf AND c.infected_at IS NULL AND NOT v_conv THEN
    PERFORM v2_event(c.id, 'infected',
      'Los dientes se cierran sobre ti. Sabes lo que significa.', jsonb_build_object('cause', 'bite'));
  END IF;
  IF v_drop AND NOT v_conv THEN
    PERFORM v2_event(c.id, 'cargo_lost', 'Lo que llevabas se queda en el suelo.',
      jsonb_build_object('food', c.cargo_food, 'serum', c.cargo_serum));
  END IF;

  UPDATE combat_rounds SET civil_action = v_a, zombie_action = v_b,
         civil_timed_out = v_c_to, zombie_timed_out = v_z_to,
         civil_decided_at = COALESCE(civil_decided_at, CASE WHEN v_c_to THEN p_now END),
         zombie_decided_at = COALESCE(zombie_decided_at, CASE WHEN v_z_to THEN p_now END),
         cell_variant = v_variant, p_civil = v_q, civil_won = v_won, outcome = o,
         civil_damage = c.life - v_c_life, zombie_damage = GREATEST(0, z.life - v_z_life),
         bite = v_inf, noise = v_noise_now, eliminated = v_elim, cargo_lost = v_drop,
         resolved_at = p_now
   WHERE encounter_id = p_encounter AND round = r.round;

  v_pc := COALESCE(e.civil_points, 0) + COALESCE((o->>'pc')::int, 0);
  v_pz := COALESCE(e.zombie_points, 0) + COALESCE((o->>'pz')::int, 0);
  UPDATE encounters SET civil_points = v_pc, zombie_points = v_pz,
         grab = COALESCE((o->>'g')::int, 0),
         noise = COALESCE(e.noise, false) OR v_noise_now,
         civil_fails = COALESCE(e.civil_fails, 0) + CASE WHEN COALESCE((o->>'fail')::boolean, false) THEN 1 ELSE 0 END,
         civil_timed_out = civil_timed_out OR v_c_to, zombie_timed_out = zombie_timed_out OR v_z_to
   WHERE id = p_encounter;

  v_reason := CASE
    WHEN v_elim THEN 'eliminated'
    WHEN v_conv THEN 'converted'
    WHEN v_down THEN 'zombie_down'
    WHEN v_end  THEN 'fled'
    WHEN v_pc >= v2_param('combat_points_to_win') THEN 'civil_points'
    WHEN v_pz >= v2_param('combat_points_to_win') THEN 'zombie_points'
    WHEN r.round >= v2_param('combat_max_rounds') THEN 'rounds'
  END;

  IF v_reason IS NOT NULL THEN
    PERFORM v2_combat_finish(p_encounter, v_reason, v_conv, v_down, v_elim, p_now);
  ELSE
    PERFORM v2_combat_open_round(p_encounter, r.round + 1, COALESCE((o->>'g')::int, 0),
      p_now + v2_param('combat_pulse_s')::float8 * interval '1 second');
  END IF;
  RETURN true;
END $$;

-- ---------------------------------------------------------------------
-- 15. Motor v1: igual que en la 003, con una guarda para que la edge
--     function submit_decision (v1) no pueda resolver un combate v6.
--     La rama v2 ×10 queda solo para encuentros v2 anteriores a la 006.
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
  -- 006: los encuentros del combate v6 se resuelven por asaltos
  -- (combat_decide / v2_combat_resolve_round), nunca con la tabla v1.
  IF v_enc.combat_version = 6 THEN
    RAISE EXCEPTION 'Encuentro de combate v6: usar combat_decide' USING ERRCODE = '22023';
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
-- 16. Detección v2: el encuentro nace como combate v6 con el asalto 1
--     abierto (resto igual que en la 005)
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

  -- El combate interrumpe lo que el civil estuviera haciendo en el supermercado
  -- (comer o cargar raciones); el saqueo sigue contando.
  IF EXISTS (SELECT 1 FROM poi_visits WHERE player_id = v_civil AND completed_at IS NULL
             AND aborted_at IS NULL AND action IS NOT NULL) THEN
    UPDATE poi_visits SET action = NULL, action_count = NULL, action_started_at = NULL
     WHERE player_id = v_civil AND completed_at IS NULL AND aborted_at IS NULL;
    PERFORM v2_event(v_civil, 'loot_aborted', 'Un ataque te interrumpe. Lo que tenías entre manos se pierde.', NULL);
  END IF;

  INSERT INTO encounters (civil_id, zombie_id, started_at, combat_version, round, grab,
                          noise, civil_fails, civil_points, zombie_points)
  VALUES (v_civil, v_zombie, now(), 6, 1, 0, false, 0, 0, 0)
  RETURNING id INTO v_id;
  PERFORM v2_combat_open_round(v_id, 1, 0, now());
  UPDATE players SET current_encounter_id = v_id WHERE id IN (v_civil, v_zombie);
  INSERT INTO events (player_id, type, message, related_encounter_id) VALUES
    (v_civil, 'encounter_start',
      COALESCE(pick_narrative('detection','civil'), 'Algo se mueve cerca. Enciende el radar.'), v_id),
    (v_zombie, 'encounter_start',
      COALESCE(pick_narrative('detection','zombie'), 'Carne fresca cerca. Acércate.'), v_id);
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- 17. Estado del combate para el jugador (RPC, authenticated)
--     Nunca devuelve la decisión del rival del asalto abierto: solo si ya
--     ha decidido, con una frase neutra. Entre asaltos, cada uno ve qué
--     eligió el otro (pistas). El zombie no ve el equipamiento del civil:
--     ve "golpear" y, si hubo disparo, el estruendo (noise). La boca expuesta
--     no se muestra (se descubre jugando; aún no hay sistema de descubrimientos).
--     p_encounter: un encuentro propio ya terminado (para la pantalla final);
--     por defecto, el actual.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.v2_combat_word(p_letter text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_letter WHEN 'G' THEN 'golpear' WHEN 'B' THEN 'bloquear' WHEN 'H' THEN 'huir'
    WHEN 'h' THEN 'huida_automatica' WHEN 'M' THEN 'morder' WHEN 'P' THEN 'perseguir'
    WHEN 'A' THEN 'agarrar' END
$$;

CREATE OR REPLACE FUNCTION public.combat_state(p_encounter uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_enc uuid;
  e encounters%ROWTYPE;
  r combat_rounds%ROWTYPE;
  me players%ROWTYPE;
  v_role text;
  v_now timestamptz := clock_timestamp();
  v_my_decided boolean;
  v_rival_decided boolean;
  v_rounds jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501'; END IF;
  SELECT * INTO me FROM players WHERE id = v_uid;
  v_enc := COALESCE(p_encounter, me.current_encounter_id);
  IF v_enc IS NULL THEN RETURN jsonb_build_object('in_combat', false); END IF;

  SELECT * INTO e FROM encounters WHERE id = v_enc;
  IF NOT FOUND OR v_uid NOT IN (e.civil_id, e.zombie_id) THEN
    RAISE EXCEPTION 'Encuentro ajeno o inexistente' USING ERRCODE = '42501';
  END IF;
  IF e.combat_version IS DISTINCT FROM 6 THEN
    RETURN jsonb_build_object('in_combat', e.result IS NULL, 'combat_version', e.combat_version);
  END IF;
  v_role := CASE WHEN v_uid = e.civil_id THEN 'civil' ELSE 'zombie' END;

  -- Resolver si el plazo ya venció (no esperar al cron de 5 s).
  IF e.result IS NULL AND v2_combat_resolve_round(v_enc, v_now) THEN
    SELECT * INTO e FROM encounters WHERE id = v_enc;
  END IF;
  SELECT * INTO me FROM players WHERE id = v_uid;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'round', cr.round,
      'my_action', v2_combat_word(CASE WHEN v_role = 'civil' THEN cr.civil_action ELSE cr.zombie_action END),
      'rival_action', v2_combat_word(CASE WHEN v_role = 'civil' THEN cr.zombie_action
                                          ELSE replace(cr.civil_action, 'h', 'H') END),
      'my_timed_out', CASE WHEN v_role = 'civil' THEN cr.civil_timed_out ELSE cr.zombie_timed_out END,
      'p_civil', round(cr.p_civil, 3),
      'civil_won', cr.civil_won,
      'civil_damage', cr.civil_damage,
      'zombie_damage', cr.zombie_damage,
      'bite', cr.bite,
      'noise', cr.noise,
      'eliminated', cr.eliminated,
      'cargo_lost', CASE WHEN v_role = 'civil' THEN cr.cargo_lost END,
      'grab_after', COALESCE((cr.outcome->>'g')::int, 0)
    ) ORDER BY cr.round), '[]'::jsonb)
    INTO v_rounds
    FROM combat_rounds cr WHERE cr.encounter_id = v_enc AND cr.resolved_at IS NOT NULL;

  SELECT * INTO r FROM combat_rounds WHERE encounter_id = v_enc AND resolved_at IS NULL;
  IF FOUND THEN
    v_my_decided := CASE WHEN v_role = 'civil' THEN r.civil_action IS NOT NULL ELSE r.zombie_action IS NOT NULL END;
    v_rival_decided := CASE WHEN v_role = 'civil' THEN r.zombie_action IS NOT NULL ELSE r.civil_action IS NOT NULL END;
  END IF;

  RETURN jsonb_build_object(
    'in_combat', e.result IS NULL,
    'encounter_id', v_enc,
    'role', v_role,
    'server_now', v_now,
    'end_reason', e.end_reason,
    'round', e.round,
    'round_open', r.round IS NOT NULL AND v_now >= r.opens_at,
    'opens_at', r.opens_at,
    'deadline', r.deadline,
    'seconds_left', CASE WHEN r.round IS NOT NULL
                      THEN GREATEST(0, ceil(EXTRACT(epoch FROM r.deadline - GREATEST(v_now, r.opens_at)))) END,
    'i_decided', v_my_decided,
    'rival_decided', v_rival_decided,
    'rival_ready_msg', CASE WHEN v_rival_decided AND NOT v_my_decided
                         THEN COALESCE(pick_narrative('combat_rival_ready', v_role), '¡Rápido!') END,
    'can_flee', v_role = 'civil' AND COALESCE(r.grab, e.grab, 0) < 2,
    'grab', COALESCE(r.grab, e.grab, 0),
    'tired', v_role = 'civil' AND COALESCE(e.civil_fails, 0) > 0,
    'my_points', CASE WHEN v_role = 'civil' THEN e.civil_points ELSE e.zombie_points END,
    'rival_points', CASE WHEN v_role = 'civil' THEN e.zombie_points ELSE e.civil_points END,
    'my_life', me.life, 'my_life_max', me.life_max,
    'rounds', v_rounds);
END $$;

-- ---------------------------------------------------------------------
-- 18. Decidir en el asalto abierto (RPC, authenticated)
--     Civil: golpear, bloquear, huir. Zombie: morder, perseguir, agarrar.
--     Con los dos brazos agarrados, huir no está disponible.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.combat_decide(p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_now timestamptz := clock_timestamp();
  me players%ROWTYPE;
  e encounters%ROWTYPE;
  r combat_rounds%ROWTYPE;
  v_role text;
  v_letter text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501'; END IF;
  SELECT * INTO me FROM players WHERE id = v_uid;
  IF me.current_encounter_id IS NULL THEN
    RAISE EXCEPTION 'No estás en combate' USING ERRCODE = '22023';
  END IF;

  -- Resolver antes cualquier asalto vencido.
  PERFORM v2_combat_resolve_round(me.current_encounter_id, v_now);

  SELECT * INTO e FROM encounters WHERE id = me.current_encounter_id FOR UPDATE;
  -- Los rechazos por tiempo no son errores: devuelven el estado con 'error'
  -- (un RAISE desharía también la resolución que se acaba de hacer).
  IF e.combat_version IS DISTINCT FROM 6 OR e.result IS NOT NULL THEN
    RETURN combat_state(e.id) || jsonb_build_object('error', 'combat_over');
  END IF;
  v_role := CASE WHEN v_uid = e.civil_id THEN 'civil' ELSE 'zombie' END;
  v_letter := CASE lower(trim(p_action))
    WHEN 'golpear' THEN 'G' WHEN 'bloquear' THEN 'B' WHEN 'huir' THEN 'H'
    WHEN 'morder' THEN 'M' WHEN 'perseguir' THEN 'P' WHEN 'agarrar' THEN 'A' END;
  IF v_letter IS NULL
     OR (v_role = 'civil' AND v_letter NOT IN ('G','B','H'))
     OR (v_role = 'zombie' AND v_letter NOT IN ('M','P','A')) THEN
    RAISE EXCEPTION 'Acción no válida para tu rol: %', p_action USING ERRCODE = '22023';
  END IF;

  SELECT * INTO r FROM combat_rounds WHERE encounter_id = e.id AND resolved_at IS NULL FOR UPDATE;
  IF NOT FOUND OR v_now < r.opens_at THEN
    RETURN combat_state(e.id) || jsonb_build_object('error', 'round_not_open');
  END IF;
  IF v_now >= r.deadline THEN
    RETURN combat_state(e.id) || jsonb_build_object('error', 'too_late');
  END IF;
  IF v_letter = 'H' AND r.grab >= 2 THEN
    RAISE EXCEPTION 'Con los dos brazos agarrados no puedes huir' USING ERRCODE = '22023';
  END IF;
  IF (v_role = 'civil' AND r.civil_action IS NOT NULL) OR (v_role = 'zombie' AND r.zombie_action IS NOT NULL) THEN
    RETURN combat_state(e.id) || jsonb_build_object('error', 'already_decided');
  END IF;

  IF v_role = 'civil' THEN
    UPDATE combat_rounds SET civil_action = v_letter, civil_decided_at = v_now
     WHERE encounter_id = e.id AND round = r.round;
  ELSE
    UPDATE combat_rounds SET zombie_action = v_letter, zombie_decided_at = v_now
     WHERE encounter_id = e.id AND round = r.round;
  END IF;

  PERFORM v2_combat_resolve_round(e.id, v_now);
  RETURN combat_state(e.id);
END $$;

-- ---------------------------------------------------------------------
-- 19. Timeouts: v1 como siempre; v6 por plazo de cada asalto
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_timeouts()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_enc RECORD; v_resolved_count INT := 0; v_active BOOLEAN := public.is_game_active();
BEGIN
  -- v1 (y v2 ×10 anteriores a la 006): tabla v1.
  FOR v_enc IN
    SELECT e.id, e.civil_decision, e.zombie_decision FROM encounters e
      JOIN players c ON c.id = e.civil_id JOIN players z ON z.id = e.zombie_id
    WHERE e.result IS NULL AND e.started_at < NOW() - INTERVAL '16 seconds'
      AND e.combat_version IS NULL
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

  -- v6: asaltos con el plazo vencido.
  FOR v_enc IN
    SELECT cr.encounter_id AS id FROM combat_rounds cr
     WHERE cr.resolved_at IS NULL AND cr.deadline <= now()
     ORDER BY cr.deadline
  LOOP
    BEGIN
      IF public.v2_combat_resolve_round(v_enc.id, now()) THEN
        v_resolved_count := v_resolved_count + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Combat v6 round resolution failed for encounter %: %', v_enc.id, SQLERRM;
    END;
  END LOOP;

  -- v6 huérfanos (sin asalto abierto ni resultado): no debería pasar nunca.
  FOR v_enc IN
    SELECT e.id FROM encounters e
     WHERE e.combat_version = 6 AND e.result IS NULL AND e.started_at < now() - interval '5 minutes'
       AND NOT EXISTS (SELECT 1 FROM combat_rounds cr WHERE cr.encounter_id = e.id AND cr.resolved_at IS NULL)
  LOOP
    PERFORM public.v2_combat_finish(v_enc.id, 'interrupted', false, false, false, now());
  END LOOP;

  RETURN v_resolved_count;
END;
$function$;

-- ---------------------------------------------------------------------
-- 20. Permisos
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  public.v2_combat_roll(),
  public.v2_combat_pulse_prob(text, text, text, text, text, numeric, numeric, integer, integer, integer, integer, boolean, numeric),
  public.v2_combat_open_round(uuid, integer, integer, timestamptz),
  public.v2_combat_finish(uuid, text, boolean, boolean, boolean, timestamptz),
  public.v2_combat_resolve_round(uuid, timestamptz),
  public.v2_combat_word(text),
  public.v2_zombie_fall(uuid, timestamptz), public.v2_convert_to_zombie(uuid, text),
  public.v2_apply_effects(uuid, timestamptz), public.v2_try_encounter(uuid)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.combat_state(uuid), public.combat_decide(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.combat_state(uuid), public.combat_decide(text) TO authenticated;

COMMIT;
