-- =====================================================================
-- Prion v2.0 — Migración 004: poblaciones y supermercados (OpenStreetMap)
-- Datos: export de overpass-turbo del 02/10/2026 (Baix Empordà),
-- procesado con tools/osm/ (ver README). Geometrías en TWKB base64.
--
-- Decisiones de Angel: la población se deduce de la casa (02/10); los
-- supermercados son reales y empiezan inactivos; la zona de saqueo está en
-- el espacio público junto al local, nunca en parques o jardines; se acepta
-- la acera cuando no hay calle peatonal ni plaza; la zona debe quedar en la
-- puerta, compacta (04/10).
--
-- Criterios técnicos (Claude):
--   * Límites municipales simplificados a 15 m: solo sirven para saber en
--     qué población está una casa o un supermercado.
--   * Espacio candidato: peatonal (calles peatonales, plazas, áreas viarias;
--     las líneas ensanchadas 3 m) y acera (franja a 3-7 m del eje de calles
--     normales, 5-9 m de principales; calles de convivencia y aceras como
--     camino, enteras; sin vías de servicio). Menos parques, jardines y, en la
--     acera, edificios.
--   * Zona = círculo de 25 m alrededor de la puerta: entrada marcada en OSM
--     sobre el contorno del edificio (main/shop > yes > emergency); si el local
--     es un punto en OSM, ese punto; si no, el punto de la fachada más cercano
--     al espacio público. Peatonal antes que acera; mínimo 80 m². Si no hay
--     nada a 25 m, se repite a 40 m.
--   * Locales duplicados en OSM (nodo + edificio del mismo nombre a < 40 m)
--     se fusionan. Geometrías normalizadas (ST_ReducePrecision) para que el
--     redondeo no deje polígonos inválidos.
--   * Resultado: 115 supermercados en OSM; 100 con zona (17 peatonal, 83
--     acera), de 81 a 946 m² (media 318), en las 13 poblaciones con súper.
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

