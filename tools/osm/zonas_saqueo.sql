DROP TABLE IF EXISTS s, pub, parks, zones;
CREATE TABLE s AS SELECT osm, COALESCE(name, props->>'brand', 'Supermercado') AS name,
  ST_Transform(g,25831) AS g FROM raw WHERE kind='super';
ALTER TABLE s ADD fp geometry, ADD pt geometry;
UPDATE s SET fp = CASE WHEN GeometryType(g)='POINT' THEN ST_Buffer(g,8) ELSE g END, pt = ST_PointOnSurface(g);
CREATE TABLE pub AS SELECT ST_Union(CASE WHEN GeometryType(g)='LINESTRING' THEN ST_Buffer(ST_Transform(g,25831),3) ELSE ST_Transform(g,25831) END) g FROM raw WHERE kind='ped';
CREATE TABLE parks AS SELECT ST_Union(ST_Transform(g,25831)) g FROM raw WHERE kind='park' AND GeometryType(g) IN ('POLYGON','MULTIPOLYGON');
CREATE TABLE zones AS
SELECT s.osm, s.name, s.pt, z.geom AS zone, ST_Area(z.geom) area
FROM s, pub, parks,
LATERAL (SELECT (ST_Dump(ST_Difference(ST_Intersection(ST_Buffer(s.fp,40), pub.g), ST_Union(parks.g, s.fp)))).geom) z;
-- la parte mayor por supermercado
DELETE FROM zones a USING zones b WHERE a.osm=b.osm AND a.area < b.area;
SELECT count(*) total_supers FROM s;
SELECT count(*) FILTER (WHERE area>=80) lootable, count(*) FILTER (WHERE area<80) small FROM zones;
SELECT m.name muni, count(s.*) supers, count(z.*) FILTER (WHERE z.area>=80) lootable
FROM raw m JOIN s ON ST_Intersects(ST_Transform(m.g,25831), s.pt) LEFT JOIN zones z ON z.osm=s.osm
WHERE m.kind='muni' GROUP BY 1 ORDER BY 2 DESC;
SELECT s.name, round(z.area) area FROM s JOIN raw m ON m.kind='muni' AND m.name='Sant Feliu de Guíxols' AND ST_Intersects(ST_Transform(m.g,25831), s.pt) LEFT JOIN zones z ON z.osm=s.osm ORDER BY 2 DESC NULLS LAST;
