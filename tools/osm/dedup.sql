DROP TABLE IF EXISTS final_pois;
CREATE TABLE final_pois AS
SELECT z.osm, z.name, z.pt, z.zone, z.area FROM zones z WHERE z.area >= 80;
-- duplicados: mismo nombre a menos de 40 m (nodo + polígono del mismo local)
DELETE FROM final_pois a USING final_pois b
 WHERE a.osm <> b.osm AND a.name = b.name AND ST_DWithin(a.pt, b.pt, 40)
   AND (a.area < b.area OR (a.area = b.area AND a.osm > b.osm));
SELECT count(*) FROM final_pois;
