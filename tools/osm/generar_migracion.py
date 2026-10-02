# Genera supabase/sql/v2/004_osm_poblaciones_supermercados.sql desde la base LOCAL "osm"
# (tras geojson_a_sql.py, zonas_saqueo.sql y dedup.sql). Ajustar la conexión de q().
import subprocess
def q(sql):
    return subprocess.run(["psql","-h","/var/tmp/pgt","-p","5499","-U","postgres","-d","osm","-At","-F","\t","-c",sql],capture_output=True,text=True,check=True).stdout.strip().split("\n")
B=lambda e: f"translate(encode({e},'base64'),E'\\n','')"
MG=B("ST_AsTWKB(ST_Multi(ST_Transform(ST_SimplifyPreserveTopology(ST_Transform(g,25831),15),4326)),5)")
munis=q(f"select osm, name, {MG} from raw where kind='muni' order by name")
pois=q(f"""select p.osm, p.name, {B("ST_AsTWKB(ST_Transform(p.pt,4326),6)")}, {B("ST_AsTWKB(ST_Transform(p.zone,4326),6)")},
 (select m.osm from raw m where m.kind='muni' and ST_Intersects(ST_Transform(m.g,25831), p.pt) limit 1) from final_pois p order by p.name, p.osm""")
src=open('supabase/sql/v2/002_funciones.sql').read()
i=src.index("CREATE OR REPLACE FUNCTION public.create_character(")
j=src.index("END $$;",i)+len("END $$;")
cc=src[i:j]
a="""  INSERT INTO refuges (type_code, owner_id, area) VALUES ('home', v_uid, v_home);
"""
assert a in cc
cc=cc.replace(a,a+"""
  -- Población: la del centro del polígono de casa (no se pide al jugador).
  SELECT id, name INTO v_muni_id, v_muni_name FROM municipalities
   WHERE ST_Intersects(area, ST_Centroid(v_home)) ORDER BY id LIMIT 1;
  UPDATE players SET municipality_id = v_muni_id WHERE id = v_uid;
""")
cc=cc.replace("  v_home geography;\nBEGIN","  v_home geography;\n  v_muni_id integer;\n  v_muni_name text;\nBEGIN")
old="""  RETURN jsonb_build_object('nick', v_nick, 'age_band', b.band, 'life', b.life_max,
    'life_max', b.life_max, 'food_stock', v2_param('food_start'));"""
assert old in cc
cc=cc.replace(old,"""  RETURN jsonb_build_object('nick', v_nick, 'age_band', b.band, 'life', b.life_max,
    'life_max', b.life_max, 'food_stock', v2_param('food_start'), 'municipality', v_muni_name);""")
def lit(s): return "'"+s.replace("'","''")+"'"
out=[open('tools/osm/cabecera_004.sql').read()]
out.append("INSERT INTO public.municipalities (osm_id, name, area) VALUES")
out.append(",\n".join(f"  ({lit(o)}, {lit(n)}, ST_SetSRID(ST_GeomFromTWKB(decode({lit(b)}, 'base64')), 4326)::geography)" for o,n,b in (l.split("\t") for l in munis))+";\n")
out.append("INSERT INTO public.pois (osm_id, kind, name, geom, area, municipality_id) VALUES")
rows=[]
for l in pois:
    o,n,pt,zn,mo=l.split("\t")
    rows.append(f"  ({lit(o)}, 'supermarket', {lit(n)}, ST_SetSRID(ST_GeomFromTWKB(decode({lit(pt)}, 'base64')), 4326)::geography, ST_SetSRID(ST_GeomFromTWKB(decode({lit(zn)}, 'base64')), 4326)::geography, (SELECT id FROM public.municipalities WHERE osm_id = {lit(mo)}))")
out.append(",\n".join(rows)+";\n")
out.append("-- Alta: asigna la población a partir del polígono de casa.\n"+cc+"\n")
out.append("""REVOKE ALL ON FUNCTION public.create_character(text, integer, text, text, text, text, text, text, double precision, double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_character(text, integer, text, text, text, text, text, text, double precision, double precision) TO authenticated;
""")
open('supabase/sql/v2/004_osm_poblaciones_supermercados.sql','w').write("\n".join(out))
print(len(munis), len(pois))
