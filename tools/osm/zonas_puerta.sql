-- Zona de saqueo en la puerta: círculo de R m alrededor de un punto de anclaje.
--   1. Entrada marcada en OSM sobre el contorno del edificio del supermercado
--      (a <= 2 m): main/shop > yes > emergency > otras. Las entradas de
--      portales vecinos no cuentan.
--   2. Supermercado mapeado como punto: el propio punto.
--   3. Edificio sin entrada marcada: el punto del contorno más cercano al
--      espacio público candidato (normalmente la fachada).
-- Dentro del círculo: peatonal si llega a 80 m²; si no, acera. Si con R no hay
-- ninguna de las dos, se repite con R2.
\set R 25
\set R2 40
DROP TABLE IF EXISTS anchors, zones_puerta, final_pois;
CREATE TABLE anchors AS
SELECT c.osm, c.name, c.pt, c.ped, c.ace,
  COALESCE(e.g, CASE WHEN GeometryType(s.g) = 'POINT' THEN s.g END,
           ST_ClosestPoint(ST_Boundary(s.g), ST_Union(COALESCE(c.ped, 'POLYGON EMPTY'::geometry), COALESCE(c.ace, 'POLYGON EMPTY'::geometry)))) AS anchor,
  CASE WHEN e.g IS NOT NULL THEN 'entrada_' || e.entrance
       WHEN GeometryType(s.g) = 'POINT' THEN 'punto_osm' ELSE 'fachada' END AS anchor_src
FROM cand c JOIN s USING (osm)
LEFT JOIN LATERAL (
  SELECT x.g, x.entrance FROM ent x
  WHERE GeometryType(s.g) <> 'POINT' AND ST_DWithin(ST_Boundary(s.g), x.g, 2)
  ORDER BY CASE x.entrance WHEN 'main' THEN 0 WHEN 'shop' THEN 0 WHEN 'yes' THEN 1 WHEN 'emergency' THEN 2 ELSE 3 END
  LIMIT 1) e ON true;
CREATE TABLE zones_puerta AS
SELECT DISTINCT ON (osm) osm, name, pt, anchor_src, zone, fuente, r
FROM (
  SELECT a.osm, a.name, a.pt, a.anchor_src, r.r, f.fuente, f.prio,
    mayor(ST_Intersection(CASE f.fuente WHEN 'peatonal' THEN a.ped ELSE a.ace END, ST_Buffer(a.anchor, r.r))) AS zone
  FROM anchors a
  CROSS JOIN (VALUES (:R), (:R2)) r(r)
  CROSS JOIN (VALUES ('peatonal', 0), ('acera', 1)) f(fuente, prio)
  WHERE a.anchor IS NOT NULL AND NOT ST_IsEmpty(a.anchor)
) x
WHERE ST_Area(zone) >= 80
-- primero el radio corto; dentro de cada radio, peatonal antes que acera
ORDER BY osm, r, prio;
CREATE TABLE final_pois AS
SELECT osm, name, pt, zone, ST_Area(zone) AS area, fuente, anchor_src, r FROM zones_puerta;
DELETE FROM final_pois a USING final_pois b
 WHERE a.osm <> b.osm AND a.name = b.name AND ST_DWithin(a.pt, b.pt, 40)
   AND (a.area < b.area OR (a.area = b.area AND a.osm > b.osm));
SELECT count(*) total, count(*) FILTER (WHERE fuente='peatonal') peatonal, count(*) FILTER (WHERE fuente='acera') acera,
  round(min(area)) min_m2, round(avg(area)) media_m2, round(max(area)) max_m2 FROM final_pois;
SELECT anchor_src, count(*) FROM final_pois GROUP BY 1 ORDER BY 2 DESC;
SELECT r, count(*) FROM final_pois GROUP BY 1;
SELECT m.name, count(p.*) FROM raw m JOIN final_pois p ON ST_Intersects(ST_Transform(m.g,25831), p.pt) WHERE m.kind='muni' GROUP BY 1 ORDER BY 2 DESC;
SELECT name, fuente, anchor_src, round(area) FROM final_pois p WHERE EXISTS (SELECT 1 FROM raw m WHERE m.kind='muni' AND m.name='Sant Feliu de Guíxols' AND ST_Intersects(ST_Transform(m.g,25831), p.pt)) ORDER BY 4 DESC;
