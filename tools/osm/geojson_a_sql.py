"""Convierte el export GeoJSON de overpass-turbo en INSERTs a una tabla `raw`
de un Postgres LOCAL con PostGIS (no Supabase). Uso:
    python3 tools/osm/geojson_a_sql.py export.geojson > raw.sql
"""
import json, sys

if "--entradas" in sys.argv:
    # Tercera consulta: nodos de entrada.
    d = json.load(open(sys.argv[1]))
    print("DROP TABLE IF EXISTS ent; CREATE TABLE ent (osm text, entrance text, g geometry);")
    for f in d["features"]:
        p = f["properties"]
        x, y = f["geometry"]["coordinates"]
        print(f"INSERT INTO ent VALUES ('{p['@id']}','{p.get('entrance', 'yes')}', "
              f"ST_Transform(ST_SetSRID(ST_MakePoint({x},{y}),4326),25831));")
    sys.exit(0)

if "--raw2" in sys.argv:
    # Segunda consulta: calles y edificios.
    d = json.load(open(sys.argv[1]))
    print("DROP TABLE IF EXISTS raw2; CREATE TABLE raw2 (osm text, kind text, hw text, props jsonb, g geometry);")
    for f in d["features"]:
        p = f["properties"]
        kind = "building" if "building" in p else "street" if "highway" in p else "other"
        q = lambda x: "NULL" if x is None else "'" + str(x).replace("'", "''") + "'"
        print(f"INSERT INTO raw2 VALUES ({q(p.get('@id'))},{q(kind)},{q(p.get('highway'))},"
              f"{q(json.dumps(p))}::jsonb, ST_SetSRID(ST_GeomFromGeoJSON({q(json.dumps(f['geometry']))}),4326));")
    sys.exit(0)

d = json.load(open(sys.argv[1]))
print("DROP TABLE IF EXISTS raw; CREATE TABLE raw (osm text, kind text, name text, props jsonb, g geometry);")
for f in d["features"]:
    p = f["properties"]
    g = f["geometry"]
    if p.get("admin_level") == "8" and p.get("boundary") == "administrative":
        kind = "muni"
    elif p.get("shop") == "supermarket":
        kind = "super"
    elif p.get("highway") == "pedestrian" or p.get("place") == "square" or "area:highway" in p:
        kind = "ped"
    elif p.get("leisure") in ("park", "garden", "playground"):
        kind = "park"
    else:
        kind = "other"
    q = lambda x: "NULL" if x is None else "'" + str(x).replace("'", "''") + "'"
    print(f"INSERT INTO raw VALUES ({q(p.get('@id'))},{q(kind)},{q(p.get('name'))},"
          f"{q(json.dumps(p))}::jsonb, ST_SetSRID(ST_GeomFromGeoJSON({q(json.dumps(g))}),4326));")
