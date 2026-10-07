"""Genera supabase/sql/v2/tests/006_probabilidades.sql: P(gana el civil) esperada según
combate_v6.py / combate_v6_carga.py, para comparar con v2_combat_pulse_prob en la réplica.
Uso: python3 tools/equilibrio/generar_pruebas_006.py > supabase/sql/v2/tests/006_probabilidades.sql"""
import sys, itertools, random
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import combate_v6 as v6
from combate_v6 import P, CELLS
GEAR = {'raso': 'none', 'herr': 'tool', 'arma': 'weapon'}
BASEP = {'base_GP': 'combat_base_hit_chase', 'base_BM': 'combat_base_block_bite', 'base_HM': 'combat_base_flee_bite',
         'base_HP': 'combat_base_flee_chase', 'base_HA': 'combat_base_flee_grab', 'base_grab1': 'combat_base_grab1',
         'base_grab2': 'combat_base_grab2'}
random.seed(7)
rows = []
pulses = [(k, v) for k, v in CELLS.items() if v[0] == 'pulse']
for (g, a, b), cell in pulses:
    for typ in ('raso', 'herr', 'arma'):
        for _ in range(6):
            edad = random.choice(['joven', 'medio', 'viejo'])
            vmax = P['vida_max'][edad]
            life = random.randint(1, vmax)
            r = random.randint(0, 2); fails = random.randint(0, 2)
            ec = random.choice([0, 1, 5, 20, 50, 200]); ez = random.choice([0, 3, 50])
            over = random.random() < 0.5
            cf = random.choice([1.0, 0.90, 0.95, 0.90 * 0.95])
            st = dict(g=g, r=r, fails=fails, life=life, over=over, exp=False)
            ctx = dict(typ=typ, edad=edad, exp_c=ec, exp_z=ez, arma_atrapada=True)
            q = v6.outcomes(st, ctx, a, b, P)[0][0]
            if cf != 1.0 and a in ('G', 'B'):
                ratio = q / (1 - q) * cf ** P['k']; q = ratio / (1 + ratio)
            _, stat, basekey, _, _ = cell
            bp = 'NULL' if basekey is None else "'" + BASEP[basekey] + "'"
            rows.append(f"('{stat}',{bp},'{a}','{GEAR[typ]}','{edad}',{life},{vmax},{r},{fails},{ec},{ez},{str(over).lower()},{cf},{float(q)!r})")
print("CREATE TEMP TABLE expected_probs (stat text, base_param text, a text, gear text, band text, life numeric, life_max numeric, r int, fails int, ec int, ez int, over boolean, cf numeric, q float8);")
print("INSERT INTO expected_probs VALUES\n  " + ",\n  ".join(rows) + ";")
