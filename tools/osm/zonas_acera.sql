DROP TABLE IF EXISTS bld, walk, zones_acera;
CREATE TABLE bld AS SELECT ST_Union(ST_Transform(g,25831)) g FROM raw2 WHERE kind='building';
-- Franja de acera según el tipo de calle (distancia al eje): calles anchas 5-9 m,
-- normales 3-7 m; calles de convivencia y aceras dibujadas como camino, enteras.
CREATE TABLE walk AS SELECT ST_Union(geom) g FROM (
  SELECT ST_Difference(ST_Buffer(ST_Transform(g,25831), 9), ST_Buffer(ST_Transform(g,25831), 5)) geom
    FROM raw2 WHERE kind='street' AND hw IN ('primary','secondary') AND GeometryType(g)='LINESTRING'
  UNION ALL
  SELECT ST_Difference(ST_Buffer(ST_Transform(g,25831), 7), ST_Buffer(ST_Transform(g,25831), 3))
    FROM raw2 WHERE kind='street' AND hw IN ('tertiary','residential','unclassified') AND GeometryType(g)='LINESTRING'
  UNION ALL
  SELECT ST_Buffer(ST_Transform(g,25831), 4) FROM raw2 WHERE kind='street' AND hw='living_street'
  UNION ALL
  SELECT ST_Buffer(ST_Transform(g,25831), 2) FROM raw2 WHERE kind='street' AND hw='footway' AND GeometryType(g)='LINESTRING'
  UNION ALL
  SELECT ST_Transform(g,25831) FROM raw2 WHERE kind='street' AND GeometryType(g)='POLYGON' AND hw IN ('footway')
) x;
CREATE TABLE zones_acera AS
SELECT s.osm, s.name, s.pt, z.geom AS zone, ST_Area(z.geom) area
FROM s, walk, bld, parks,
LATERAL (SELECT (ST_Dump(ST_Difference(ST_Intersection(ST_Buffer(s.fp,40), walk.g),
                                       ST_Union(ARRAY[bld.g, parks.g, s.fp])))).geom) z
WHERE NOT EXISTS (SELECT 1 FROM zones p WHERE p.osm = s.osm AND p.area >= 80);
DELETE FROM zones_acera a USING zones_acera b WHERE a.osm=b.osm AND a.area < b.area;

-- Resultado combinado: peatonal/plaza si hay (>= 80 m²); si no, acera (>= 80 m²).
DROP TABLE IF EXISTS final_pois;
CREATE TABLE final_pois AS
SELECT osm, name, pt, zone, area, 'peatonal'::text AS fuente FROM zones WHERE area >= 80
UNION ALL
SELECT osm, name, pt, zone, area, 'acera' FROM zones_acera WHERE area >= 80;
DELETE FROM final_pois a USING final_pois b
 WHERE a.osm <> b.osm AND a.name = b.name AND ST_DWithin(a.pt, b.pt, 40)
   AND (a.area < b.area OR (a.area = b.area AND a.osm > b.osm));
SELECT fuente, count(*) FROM final_pois GROUP BY 1;
SELECT m.name, (SELECT count(*) FROM s WHERE ST_Intersects(ST_Transform(m.g,25831), s.pt)) en_osm,
  count(p.*) FILTER (WHERE fuente='peatonal') peatonal, count(p.*) FILTER (WHERE fuente='acera') acera
FROM raw m LEFT JOIN final_pois p ON ST_Intersects(ST_Transform(m.g,25831), p.pt)
WHERE m.kind='muni' GROUP BY m.name, m.g HAVING (SELECT count(*) FROM s WHERE ST_Intersects(ST_Transform(m.g,25831), s.pt)) > 0 ORDER BY 2 DESC;
SELECT name, fuente, round(area) FROM final_pois p WHERE EXISTS (SELECT 1 FROM raw m WHERE m.kind='muni' AND m.name IN ('Palamós','Sant Feliu de Guíxols') AND ST_Intersects(ST_Transform(m.g,25831), p.pt)) ORDER BY 2,3 DESC;
