-- =====================================================================
-- Prion v2.0 — Migración 001: modelo base del mundo continuo
-- APLICADA en prion-mvp el 02/10/2026 (editor SQL de Supabase).
-- Versión 2 (02/10/2026): incorpora límites diarios de refugios,
-- zombie con resistencia, aletargamiento, sobreexcitación, proteína,
-- índice de conversión y vuelta a civil al 50 %.
--
-- Alcance: solo tablas, parámetros y datos semilla. Las funciones
-- (alta, report_position con histéresis y refugios, tick de efectos,
-- saqueo, brotes, sobreexcitación) van en la migración 002.
--
-- Criterio: aditiva. El motor v1 sigue funcionando. Lo que v1 deja
-- obsoleto (game_session, close_game, assign_roles_balanced) se retira
-- cuando v2.0 esté probado.
--
-- Valores marcados PROVISIONAL: de relleno, se cambian en game_params
-- o en las tablas de catálogo sin tocar código.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Parámetros de juego
-- ---------------------------------------------------------------------
CREATE TABLE public.game_params (
  key         text PRIMARY KEY,
  value       numeric NOT NULL,
  unit        text,
  description text NOT NULL
);

INSERT INTO public.game_params (key, value, unit, description) VALUES
  -- Comida (civiles)
  ('food_start',                20,    'raciones', 'Existencias iniciales de comida al darse de alta'),
  ('hunger_damage_per_day',     3,     'vida/día', 'Vida perdida por día con existencias a cero'),
  ('extra_ration_heal',         3,     'vida',     'Vida recuperada por cada ración extra comida'),
  ('extra_rations_max_day',     2,     'raciones', 'Máximo de raciones extra por día'),
  ('loot_minutes',              10,    'min',      'Permanencia en supermercado para completar saqueo'),
  ('loot_rations',              3,     'raciones', 'Raciones obtenidas por saqueo completado (civil)'),
  ('loot_same_poi_cooldown_h',  24,    'h',        'Horas antes de volver a saquear el mismo supermercado'),
  -- Proteína (zombies) — PROVISIONAL
  ('loot_protein_resistance',   10,    'resistencia', 'PROVISIONAL. Resistencia ganada por saqueo de proteína completado (zombie)'),
  -- Regeneración y estados
  ('home_regen_per_hour',       1,     'vida/h',   'Regeneración en casa con descanso activado (civil)'),
  ('wounded_fraction',          0.6667,'fracción', 'Herido: life <= fracción * life_max'),
  ('critical_fraction',         0.3333,'fracción', 'Malherido/crítico: life <= fracción * life_max'),
  -- Infección y conversión
  ('incubation_damage_per_h',   2,     'vida/h',   'Daño de la infección durante incubación'),
  ('zombie_resistance_start',   60,    'resistencia', 'Resistencia inicial y máxima de todo zombie raso'),
  ('reconversion_life_fraction',0.5,   'fracción', 'Zombie que vuelve a civil: empieza con esta fracción del life_max de su tramo'),
  ('zombie_down_minutes',       60,    'min',      'PROVISIONAL. Tiempo que un zombie sin resistencia tarda en levantarse'),
  ('zombie_down_index_loss',    0.9,   'fracción', 'Fracción de poder y mutación que pierde el zombie al caer'),
  -- Sobreexcitación (zombies)
  ('overexcite_uses_day',       4,     'usos',     'Activaciones diarias de sobreexcitación, no acumulables'),
  ('overexcite_minutes',        15,    'min',      'Duración de cada sobreexcitación'),
  ('overexcite_radar_m',        60,    'm',        'PROVISIONAL. Radio de olfato de sangre: civiles heridos visibles hasta aquí durante la sobreexcitación (sanos siguen a 25 m)'),
  -- Escondite: reactivación tras salir
  ('hideout_reactivate_m',      100,   'm',        'Distancia para reactivar escondite tras salir'),
  ('hideout_reactivate_min',    60,    'min',      'Tiempo alternativo para reactivar escondite'),
  -- Histéresis y privacidad
  ('hysteresis_exit_buffer_m',  20,    'm',        'Margen fuera del polígono para considerar salida'),
  ('hysteresis_exit_readings',  3,     'lecturas', 'Lecturas consecutivas fuera para confirmar salida'),
  ('hysteresis_max_accuracy_m', 30,    'm',        'Precisión GPS mínima para que una lectura cuente como salida'),
  ('signal_loss_seconds',       8,     's',        'Duración del efecto de interferencias al entrar en un refugio'),
  ('position_stale_seconds',    300,   's',        'Antigüedad máxima de posición visible para otros (hoy 5 min en get_nearby_players)');

-- ---------------------------------------------------------------------
-- 1. Tramos de edad (ficticia)
--    Joven: más vida, más consumo. Viejo: menos vida, menos consumo.
-- ---------------------------------------------------------------------
CREATE TABLE public.age_bands (
  band                 text PRIMARY KEY CHECK (band IN ('joven','medio','viejo')),
  min_age              smallint NOT NULL,
  max_age              smallint NOT NULL,
  life_max             smallint NOT NULL,
  food_per_day         numeric(4,2) NOT NULL,
  conversion_threshold smallint NOT NULL,   -- puntos de conversión para que un zombie raso vuelva a civil
  CHECK (min_age <= max_age)
);

-- conversion_threshold: PROVISIONAL.
INSERT INTO public.age_bands VALUES
  ('joven', 15, 35, 100, 1.50, 100),
  ('medio', 36, 55,  90, 1.00,  90),
  ('viejo', 56, 90,  80, 0.75,  80);

-- ---------------------------------------------------------------------
-- 2. Ficha ficticia (censo sanitario-militar). Inmutable tras el alta.
-- ---------------------------------------------------------------------
CREATE TABLE public.profile_options (
  field  text NOT NULL,     -- 'sex','eye_color','hair_color','height_band','profession','hobby'
  value  text NOT NULL,
  label  text NOT NULL,     -- texto mostrado / usado en la noticia
  PRIMARY KEY (field, value)
);

CREATE TABLE public.character_profiles (
  player_id     uuid PRIMARY KEY REFERENCES public.players(id) ON DELETE CASCADE,
  fictional_age smallint NOT NULL CHECK (fictional_age BETWEEN 15 AND 90),
  sex           text NOT NULL,
  eye_color     text NOT NULL,
  hair_color    text NOT NULL,
  height_band   text NOT NULL,
  profession    text NOT NULL,
  hobby         text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.block_profile_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'La ficha del censo es inmutable';
END $$;
REVOKE ALL ON FUNCTION public.block_profile_update() FROM PUBLIC;

CREATE TRIGGER character_profiles_immutable
  BEFORE UPDATE ON public.character_profiles
  FOR EACH ROW EXECUTE FUNCTION public.block_profile_update();

ALTER TABLE public.character_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY character_profiles_select_own ON public.character_profiles
  FOR SELECT TO authenticated USING (player_id = auth.uid());

ALTER TABLE public.profile_options ENABLE ROW LEVEL SECURITY;
CREATE POLICY profile_options_select_all ON public.profile_options
  FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------
-- 3. Brotes de infección (inicial y mutaciones periódicas)
-- ---------------------------------------------------------------------
CREATE TABLE public.outbreaks (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at     timestamptz NOT NULL DEFAULT now(),
  criteria       jsonb NOT NULL,
  target_ratio   numeric(4,3) NOT NULL CHECK (target_ratio > 0 AND target_ratio < 1),
  affected_count integer NOT NULL DEFAULT 0,
  news_text      text NOT NULL
);

ALTER TABLE public.outbreaks ENABLE ROW LEVEL SECURITY;
CREATE POLICY outbreaks_select_all ON public.outbreaks
  FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------
-- 4. Jugador persistente
--    life / life_max: vida del civil o resistencia del zombie (mismo
--    campo; el nombre cambia en pantalla según el rol).
--    Índices (sin usar hasta v2.2, se crean ya para no migrar luego):
--      conversion_points: zombie raso, camino de vuelta a civil.
--      role_points: inteligencia (civil), poder (militar, zombie),
--                   investigación (médico). El significado lo da el rol.
--      evolution_points / evolution_level: evolución lenta.
-- ---------------------------------------------------------------------
ALTER TABLE public.players
  ADD COLUMN rank              text NOT NULL DEFAULT 'raso'
       CHECK (rank IN ('raso','militar','medico','medico_militar','lider')),
  ADD COLUMN evolution_level   smallint NOT NULL DEFAULT 0 CHECK (evolution_level >= 0),
  ADD COLUMN evolution_points  integer  NOT NULL DEFAULT 0 CHECK (evolution_points >= 0),
  ADD COLUMN role_points       integer  NOT NULL DEFAULT 0 CHECK (role_points >= 0),
  ADD COLUMN mutation_points   integer  NOT NULL DEFAULT 0 CHECK (mutation_points >= 0),
  ADD COLUMN life_max          smallint NOT NULL DEFAULT 10,   -- v1 sigue en 10; el alta v2 pone el del tramo
  ADD COLUMN age_band          text REFERENCES public.age_bands(band),
  ADD COLUMN food_stock        numeric(6,2),                   -- NULL en jugadores v1
  ADD COLUMN infected_at       timestamptz,
  ADD COLUMN outbreak_id       uuid REFERENCES public.outbreaks(id),
  -- Estado de refugio e histéresis
  ADD COLUMN inside_refuge_id  uuid,
  ADD COLUMN resting           boolean NOT NULL DEFAULT false, -- descanso activado a mano
  ADD COLUMN hidden_since      timestamptz,
  ADD COLUMN exit_streak       smallint NOT NULL DEFAULT 0,
  ADD COLUMN regen_pending     numeric(6,2) NOT NULL DEFAULT 0,
  ADD COLUMN overexcited_until timestamptz,
  ADD COLUMN down_until        timestamptz,
  ADD COLUMN last_effects_at   timestamptz;

ALTER TABLE public.players DROP CONSTRAINT IF EXISTS players_life_check;
ALTER TABLE public.players
  ADD CONSTRAINT players_life_check CHECK (life >= 0 AND life <= life_max),
  ADD CONSTRAINT players_life_max_check CHECK (life_max BETWEEN 1 AND 200);

-- ---------------------------------------------------------------------
-- 5. Contador de usos diarios no acumulables
--    Un solo mecanismo para escondites, activaciones de zona mixta,
--    sobreexcitación, raciones extra, etc. El día es el día local de
--    Europe/Madrid. Lo no gastado no pasa al día siguiente.
-- ---------------------------------------------------------------------
CREATE TABLE public.daily_usage (
  player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  day       date NOT NULL,
  kind      text NOT NULL,   -- 'hideout','mixed_activation','overexcite','extra_ration',...
  used      smallint NOT NULL DEFAULT 0 CHECK (used >= 0),
  PRIMARY KEY (player_id, day, kind)
);

ALTER TABLE public.daily_usage ENABLE ROW LEVEL SECURITY;
CREATE POLICY daily_usage_select_own ON public.daily_usage
  FOR SELECT TO authenticated USING (player_id = auth.uid());

-- ---------------------------------------------------------------------
-- 6. Lugares importados de OpenStreetMap
-- ---------------------------------------------------------------------
CREATE TABLE public.pois (
  id          bigserial PRIMARY KEY,
  osm_id      text UNIQUE NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('supermarket','church','sports_hall','hospital','police')),
  name        text,
  geom        geography(Point, 4326) NOT NULL,
  area        geography(Polygon, 4326) NOT NULL,
  active      boolean NOT NULL DEFAULT false, -- supermercados: el servidor los activa según jugadores cercanos
  source      text NOT NULL DEFAULT 'osm' CHECK (source IN ('osm','server')),  -- todos reales de OSM; 'server' reservado
  activated_at timestamptz,  -- cuándo el servidor lo puso en juego; una vez activo no se desactiva
  imported_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pois_area_gix ON public.pois USING gist (area);
CREATE INDEX pois_kind_idx ON public.pois (kind) WHERE active;

ALTER TABLE public.pois ENABLE ROW LEVEL SECURITY;
CREATE POLICY pois_select_all ON public.pois
  FOR SELECT TO authenticated USING (active);

CREATE TABLE public.poi_visits (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id    uuid NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  poi_id       bigint NOT NULL REFERENCES public.pois(id),
  started_at   timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  aborted_at   timestamptz,
  reward       jsonb
);
CREATE INDEX poi_visits_player_poi_idx ON public.poi_visits (player_id, poi_id, completed_at DESC);
CREATE UNIQUE INDEX poi_visits_one_open ON public.poi_visits (player_id)
  WHERE completed_at IS NULL AND aborted_at IS NULL;

ALTER TABLE public.poi_visits ENABLE ROW LEVEL SECURITY;
CREATE POLICY poi_visits_select_own ON public.poi_visits
  FOR SELECT TO authenticated USING (player_id = auth.uid());

-- ---------------------------------------------------------------------
-- 7. Refugios: un solo modelo parametrizado
-- ---------------------------------------------------------------------
CREATE TABLE public.refuge_types (
  code                 text PRIMARY KEY,
  anchor               text NOT NULL CHECK (anchor IN ('player','poi')),
  poi_kind             text,
  activation_minutes   integer,           -- NULL = sin límite de tiempo
  max_activations_day  smallint,          -- NULL = sin límite diario
  life_per_hour        numeric(6,3) NOT NULL DEFAULT 0,  -- regeneración (requiere descanso activado)
  regen_roles          text[] NOT NULL DEFAULT ARRAY[]::text[],
  drain_hours_healthy  numeric(6,2),      -- pierde 1 cada N horas (NULL = no pierde)
  drain_hours_wounded  numeric(6,2),
  drain_hours_critical numeric(6,2),
  hides_player         boolean NOT NULL DEFAULT true,
  radar_inside         boolean NOT NULL DEFAULT false,
  comms_inside         boolean NOT NULL DEFAULT false,
  allowed_roles        text[] NOT NULL DEFAULT ARRAY['civil'],
  allowed_ranks        text[]             -- NULL = todos los rangos
);

-- home:  casa. Sin tiempo, según GPS. Civil regenera con descanso
--        activado; zombie se aletarga (protegido, no regenera).
-- mixed: trabajo. 4 h por activación, máximo 2 activaciones al día.
--        Civil y zombie (aletargamiento).
-- hideout: escondite dinámico, 2 h. Solo civiles con cupo diario.
INSERT INTO public.refuge_types VALUES
  ('home',        'player', NULL,          NULL, NULL, 1.0, ARRAY['civil'], NULL, NULL, NULL, true, false, false, ARRAY['civil','zombie'], NULL),
  ('mixed',       'player', NULL,          240,  2,    0,   ARRAY[]::text[], 24, 12, 6, true, false, false, ARRAY['civil','zombie'], NULL),
  ('hideout',     'player', NULL,          120,  NULL, 0,   ARRAY[]::text[], 24, 12, 6, true, false, false, ARRAY['civil'], NULL),
  ('church',      'poi',    'church',      NULL, NULL, 0,   ARRAY[]::text[], 24, 12, 6, true, false, false, ARRAY['civil'], NULL),
  ('sports_hall', 'poi',    'sports_hall', NULL, NULL, 0,   ARRAY[]::text[], 24, 12, 6, true, false, false, ARRAY['civil'], NULL),
  ('hospital',    'poi',    'hospital',    NULL, NULL, 0,   ARRAY[]::text[], 24, 12, 6, true, false, false, ARRAY['civil'], ARRAY['medico','medico_militar']);

-- Cupos por rol, rango y nivel de evolución.
--   permanent_count: refugios fijos que posee (casa, zona mixta).
--   per_day:         usos diarios no acumulables (escondites).
-- Se aplica la fila con mayor min_level <= evolution_level del jugador.
CREATE TABLE public.refuge_limits (
  role            text NOT NULL CHECK (role IN ('civil','zombie')),
  rank            text NOT NULL,
  min_level       smallint NOT NULL DEFAULT 0,
  refuge_type     text NOT NULL REFERENCES public.refuge_types(code),
  permanent_count smallint NOT NULL DEFAULT 0,
  per_day         smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (role, rank, min_level, refuge_type)
);

-- min_level 1 = "evolucionado". PROVISIONAL: qué nivel cuenta como
-- evolucionado se decide con el sistema de evolución (v2.2).
INSERT INTO public.refuge_limits (role, rank, min_level, refuge_type, permanent_count, per_day) VALUES
  ('civil', 'raso',           0, 'home',    1, 0),
  ('civil', 'raso',           0, 'mixed',   1, 0),
  ('civil', 'raso',           0, 'hideout', 0, 1),
  ('civil', 'raso',           1, 'hideout', 0, 2),   -- civil avanzado
  ('civil', 'militar',        0, 'home',    1, 0),
  ('civil', 'militar',        0, 'mixed',   1, 0),
  ('civil', 'militar',        0, 'hideout', 0, 2),
  ('civil', 'militar',        1, 'hideout', 0, 3),
  ('civil', 'medico',         0, 'home',    1, 0),
  ('civil', 'medico',         0, 'mixed',   1, 0),   -- sin escondites
  ('civil', 'medico_militar', 0, 'home',    1, 0),
  ('civil', 'medico_militar', 0, 'mixed',   1, 0),
  ('civil', 'medico_militar', 0, 'hideout', 0, 2),   -- PROVISIONAL
  ('zombie','raso',           0, 'home',    1, 0),
  ('zombie','raso',           0, 'mixed',   1, 0),
  ('zombie','lider',          0, 'home',    1, 0),
  ('zombie','lider',          0, 'mixed',   1, 0);

-- Instancias. Para refugios de jugador solo se guarda el polígono
-- irregular; el punto original nunca se persiste.
CREATE TABLE public.refuges (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type_code    text NOT NULL REFERENCES public.refuge_types(code),
  owner_id     uuid REFERENCES public.players(id) ON DELETE CASCADE,
  poi_id       bigint REFERENCES public.pois(id),
  area         geography(Polygon, 4326) NOT NULL,
  state        text NOT NULL DEFAULT 'ready' CHECK (state IN ('ready','active','spent')),
  active_since timestamptz,
  active_until timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK ((owner_id IS NULL) <> (poi_id IS NULL))
);
CREATE INDEX refuges_area_gix ON public.refuges USING gist (area);
CREATE INDEX refuges_owner_idx ON public.refuges (owner_id);
CREATE UNIQUE INDEX refuges_one_home  ON public.refuges (owner_id) WHERE type_code = 'home';
CREATE UNIQUE INDEX refuges_one_mixed ON public.refuges (owner_id) WHERE type_code = 'mixed';

ALTER TABLE public.players
  ADD CONSTRAINT players_inside_refuge_fkey
  FOREIGN KEY (inside_refuge_id) REFERENCES public.refuges(id) ON DELETE SET NULL;

-- Sin políticas: ningún cliente lee polígonos de refugios, ni el propio.
ALTER TABLE public.refuges ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.game_params   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.age_bands     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.refuge_types  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.refuge_limits ENABLE ROW LEVEL SECURITY;
CREATE POLICY game_params_select   ON public.game_params   FOR SELECT TO authenticated USING (true);
CREATE POLICY age_bands_select     ON public.age_bands     FOR SELECT TO authenticated USING (true);
CREATE POLICY refuge_types_select  ON public.refuge_types  FOR SELECT TO authenticated USING (true);
CREATE POLICY refuge_limits_select ON public.refuge_limits FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------
-- 8. Nuevos tipos de evento
-- ---------------------------------------------------------------------
ALTER TABLE public.events DROP CONSTRAINT IF EXISTS events_type_check;
ALTER TABLE public.events ADD CONSTRAINT events_type_check CHECK (type = ANY (ARRAY[
  'encounter_start','encounter_result','life_regen','conversion','neutralization',
  'restoration','radar_restored','game_start','game_end',
  -- v2
  'character_created','outbreak','infected','incubation_tick','reconversion',
  'refuge_enter','refuge_exit','refuge_spent','rest_start','rest_stop',
  'food_eaten','hunger_damage','loot_started','loot_completed','loot_aborted',
  'overexcite_start','overexcite_end','zombie_down','zombie_up'
]));

-- ---------------------------------------------------------------------
-- 9. Minimización de datos (aprobado por Angel 02/10/2026)
--    Columnas de datos personales reales: vacías en los 21 jugadores y
--    sin referencias en funciones ni en el código del repo.
-- ---------------------------------------------------------------------
ALTER TABLE public.players DROP COLUMN real_name;
ALTER TABLE public.players DROP COLUMN birth_year;
ALTER TABLE public.players DROP COLUMN gender;
