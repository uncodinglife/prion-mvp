# Importación de OpenStreetMap (poblaciones y supermercados)

Herramienta de preparación de datos. Se ejecuta en un Postgres **local** con PostGIS, nunca en Supabase.
El resultado es una migración SQL autocontenida (geometrías en TWKB base64) que sí se aplica en Supabase.

1. En overpass-turbo.eu, ejecutar la consulta de `consulta_overpass.txt` y exportar como GeoJSON.
2. `python3 tools/osm/geojson_a_sql.py export.geojson > raw.sql` y cargarlo en una base local `osm`.
3. `psql -d osm -f tools/osm/zonas_saqueo.sql` calcula la zona de saqueo de cada supermercado
   (EPSG:25831): espacio peatonal a <= 40 m del local, menos parques y el propio local; parte mayor.
4. `psql -d osm -f tools/osm/dedup.sql` se queda con las zonas >= 80 m² y fusiona duplicados.
5. `python3 tools/osm/generar_migracion.py` escribe la migración 004.

Para otra comarca, cambiar el nombre del área en la consulta y numerar la migración nueva
(los `INSERT` de `municipalities` y `pois` chocarían por `osm_id` si se repiten).
