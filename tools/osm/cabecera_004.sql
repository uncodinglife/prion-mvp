-- =====================================================================
-- Prion v2.0 — Migración 004: poblaciones y supermercados (OpenStreetMap)
-- Datos: export de overpass-turbo del 02/10/2026 (Baix Empordà),
-- procesado con tools/osm/ (ver README). Geometrías en TWKB base64.
--
-- Decisiones de Angel: la población se deduce de la casa (02/10); los
-- supermercados son reales y empiezan inactivos; la zona de saqueo está en
-- el espacio público junto al local, nunca en parques o jardines; se acepta
-- la acera cuando no hay calle peatonal ni plaza (04/10).
--
-- Criterios técnicos (Claude):
--   * Límites municipales simplificados a 15 m: solo sirven para saber en
--     qué población está una casa o un supermercado.
--   * Prioridad 1, peatonal: calles peatonales, plazas y áreas viarias a
--     <= 40 m del local (las que OSM tiene como línea, ensanchadas 3 m).
--   * Prioridad 2, acera: franja a 3-7 m del eje de calles normales y a
--     5-9 m de calles principales; calles de convivencia y aceras dibujadas
--     como camino, enteras. No cuentan las vías de servicio (aparcamientos,
--     accesos privados).
--   * A ambas se les restan parques, jardines, parques infantiles y, en la
--     acera, los edificios. Se queda la parte mayor; mínimo 80 m².
--   * Locales duplicados en OSM (nodo + edificio del mismo nombre a < 40 m)
--     se fusionan.
--   * Resultado: 115 supermercados en OSM; 106 con zona (26 peatonal, 80 acera).
-- =====================================================================

CREATE TABLE public.municipalities (
  id          serial PRIMARY KEY,
  osm_id      text UNIQUE NOT NULL,
  name        text NOT NULL,
  area        geography(MultiPolygon, 4326) NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX municipalities_area_gix ON public.municipalities USING gist (area);
ALTER TABLE public.municipalities ENABLE ROW LEVEL SECURITY;
-- Nombres y límites son datos públicos; el cliente puede leerlos.
CREATE POLICY municipalities_select ON public.municipalities FOR SELECT TO authenticated USING (true);

ALTER TABLE public.players ADD COLUMN municipality_id integer REFERENCES public.municipalities(id);
ALTER TABLE public.pois    ADD COLUMN municipality_id integer REFERENCES public.municipalities(id);
CREATE INDEX players_municipality_idx ON public.players (municipality_id) WHERE age_band IS NOT NULL;
CREATE INDEX pois_municipality_idx ON public.pois (municipality_id);

