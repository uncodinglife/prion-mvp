-- =====================================================================
-- Prion v2.0 — Migración 004: poblaciones y supermercados (OpenStreetMap)
-- Datos: export de overpass-turbo del 02/10/2026 (Baix Empordà),
-- procesado con tools/osm/ (ver README). Geometrías en TWKB base64.
--
-- Decisiones de Angel: la población se deduce de la casa (02/10); los
-- supermercados son reales, empiezan inactivos y se descartan los que no
-- tienen espacio público adecuado al lado; la zona de saqueo está en la
-- calle peatonal o plaza junto al local, nunca en parques o jardines.
--
-- Criterios técnicos (Claude):
--   * Límites municipales simplificados a 15 m: solo sirven para saber en
--     qué población está una casa o un supermercado.
--   * Zona de saqueo = (calles peatonales, plazas y áreas viarias a <= 40 m
--     del local) - (parques, jardines, parques infantiles) - (el propio
--     local); se queda la parte mayor; mínimo 80 m². Las calles peatonales
--     que OSM tiene solo como línea se ensanchan 3 m a cada lado.
--   * Locales duplicados en OSM (nodo + edificio del mismo nombre a < 40 m)
--     se fusionan.
--   * Resultado: 115 supermercados en OSM, 26 con zona de saqueo válida.
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

