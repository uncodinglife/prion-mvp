-- Espacio candidato completo (peatonal + acera), para recortarlo por radio.
DROP TABLE IF EXISTS cand;
CREATE TABLE cand AS
SELECT s.osm, s.name, s.pt, s.fp,
  ST_Difference(ST_Intersection(ST_Buffer(s.fp,40), pub.g), ST_Union(parks.g, s.fp)) AS ped,
  ST_Difference(ST_Intersection(ST_Buffer(s.fp,40), walk.g), ST_Union(ARRAY[bld.g, parks.g, s.fp])) AS ace
FROM s, pub, parks, walk, bld;
CREATE OR REPLACE FUNCTION mayor(g geometry) RETURNS geometry LANGUAGE sql AS $$
  SELECT d.geom FROM ST_Dump(g) d WHERE GeometryType(d.geom)='POLYGON' ORDER BY ST_Area(d.geom) DESC LIMIT 1 $$;
