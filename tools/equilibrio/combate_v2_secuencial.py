"""Equilibrio del combate v2 completo (3 asaltos) con informacion oculta.

Reglas del 06/10/2026: tabla v5, fuerza continua P = (Fc*s)^k / ((Fc*s)^k + Fz^k),
factor de salud s = 0.6 + 0.4*vida/vida_max (se recalcula en cada asalto), eliminacion
solo con boca expuesta (bloquea-muerde ganado en el asalto anterior) y solo con disparo,
los dos ven la eleccion del otro al acabar cada asalto.

El tipo de civil (raso / herramienta / armado) lo elige el azar al principio y solo lo
conoce el civil. Modo "informado": el boton de golpear que ve el zombie lleva la variante
(golpe / herramienta / disparo), asi que golpear revela el tipo. Modo "ciego": el zombie
solo ve "golpea" (supuesto de los calculos del 04/10).

Se resuelve como juego de suma cero en forma secuencial (von Stengel 1996) con
programacion lineal: equilibrio exacto con actualizacion bayesiana de creencias del zombie.

Supuestos propios (NO decididos por Angel), marcados con [SUP]:
- Valor del combate para el civil = dano neto al zombie/60 - dano al civil/vida_max
  - infeccion*I - conversion*Cconv + caida_zombie*E.
- Subjuego de agarre (con uno o dos brazos agarrados), ver resolve().
"""
import itertools, sys
import numpy as np
from scipy.optimize import linprog
from scipy.sparse import coo_matrix

BASE = dict(
    k=2.0,
    F={'raso': 0.72, 'herr': 1.38, 'arma': 1.94},   # fuerza de golpear por tipo
    mult={'raso': 1.0, 'herr': 1.5, 'arma': 2.0},   # multiplicador de dano del golpe
    F_grab1=0.33, F_grab2=0.20,                     # fuerza del civil contra mordisco agarrado
    prior={'raso': 0.60, 'herr': 0.25, 'arma': 0.15},
    life0=100, life_max=100, res0=60, res_max=60,
    bite_heal=4, convert_heal=10,
    I=0.20,      # [SUP] coste de quedar infectado (fraccion de vida equivalente)
    Cconv=0.50,  # [SUP] coste extra de convertirse
    E=0.50,      # [SUP] coste extra de la caida del zombie (pierde 50 % poder, 25 % mutacion)
    health=True, informed=True,
    # Palancas de diseno para probar (los valores por defecto = tabla v5 aceptada 04/10)
    HP_dmg=8,        # huye-persigue: dano al civil cazado
    HP_grab=False,   # huye-persigue: el cazado empieza el siguiente asalto con un brazo agarrado
    HM_dmg=5, HA_dmg=3,
    GA_armed_grab=False,  # con herramienta o arma, golpea-agarra: el reflejo de prension atrapa el arma (brazo agarrado)
    W=0.0,           # valor de ganar el combate a puntos (2 asaltos), para quien gana
)
CA = ['G', 'B', 'H']   # golpea, bloquea, huye
ZA = ['M', 'P', 'A']   # muerde, persigue, agarra


def pwin(F, s, p):
    a = (F * s) ** p['k']
    return a / (a + 1.0)


def resolve(st, typ, a, b, p):
    """Devuelve lista de (prob, efectos). Efectos: dc, dz, pc, pz, g, exp, inf, bite, end, elim."""
    g = st['g']
    s = 0.6 + 0.4 * max(0, st['life']) / p['life_max'] if p['health'] else 1.0
    E = lambda **kw: dict(dict(dc=0, dz=0, pc=0, pz=0, g=g, exp=False, inf=False, bite=False,
                               end=False, elim=False), **kw)
    m = p['mult'][typ]
    if g == 0:
        if (a, b) == ('G', 'M'):
            q = pwin(p['F'][typ], s, p)
            civ = E(dc=2, dz=8 * m, pc=1)
            if st['exp'] and typ == 'arma':
                civ = E(dc=2, dz=0, elim=True, end=True)
            return [(q, civ), (1 - q, E(dc=8, dz=2, pz=1, inf=True, bite=True))]
        return [(1.0, {
            ('G', 'P'): E(dc=2, dz=8 * m, pc=1),
            ('G', 'A'): E(dc=3, dz=1, pz=1, g=1) if (p['GA_armed_grab'] and typ != 'raso')
                        else E(dc=3, dz=3),
            ('B', 'M'): E(dc=2, dz=2, pc=1, exp=True),
            ('B', 'P'): E(dc=1, dz=1),
            ('B', 'A'): E(dc=3, dz=1, pz=1, g=1),
            ('H', 'M'): E(dc=p['HM_dmg'], dz=1, end=True),
            ('H', 'P'): E(dc=p['HP_dmg'], dz=2, pz=1, g=1 if p['HP_grab'] else 0),
            ('H', 'A'): E(dc=p['HA_dmg'], dz=1, end=True),
        }[(a, b)])]
    # [SUP] Subjuego de agarre. Contra un mordisco la accion del civil no importa: pulso a F_grab.
    if b == 'M':
        Fg, dmg = (p['F_grab1'], 10) if g == 1 else (p['F_grab2'], 12)
        q = pwin(Fg, s, p)
        return [(q, E(dc=2, dz=6, pc=1, g=g - 1 if g == 2 else 0)),
                (1 - q, E(dc=dmg, dz=2, pz=1, inf=True, bite=True))]
    if g == 1:
        return [(1.0, {
            ('G', 'P'): E(dc=1, dz=6, pc=1, g=0),   # golpe con el brazo libre: se suelta
            ('G', 'A'): E(dc=1, dz=6, pc=1, g=0),
            ('B', 'P'): E(dc=2, dz=2),              # forcejeo
            ('B', 'A'): E(dc=3, dz=1, pz=1, g=2),   # segundo brazo
            ('H', 'P'): E(dc=3, dz=1, pz=1),        # tiron fallido
            ('H', 'A'): E(dc=3, dz=1, end=True),    # tiron: se suelta y escapa
        }[(a, b)])]
    return [(1.0, {                                  # g == 2, huir desactivado
        ('G', 'P'): E(dc=1, dz=6, pc=1, g=1), ('G', 'A'): E(dc=1, dz=6, pc=1, g=1),
        ('B', 'P'): E(dc=2, dz=2), ('B', 'A'): E(dc=2, dz=2),
    }[(a, b)])]


class Game:
    """Construye la forma secuencial. afk = (jugador, distribucion) fuerza a un jugador."""

    def __init__(self, p, afk=None):
        self.p, self.afk = p, afk
        self.cseq, self.zseq = {(): 0}, {(): 0}
        self.cinfo, self.zinfo = {}, {}
        self.A = {}
        self.leaves = []
        for typ, pr in p['prior'].items():
            if pr > 0:
                st = dict(r=0, pc=0, pz=0, g=0, exp=False, life=p['life0'], res=p['res0'],
                          inf=False, bites=0, hist=(), zobs=())
                self.rec(typ, st, pr, (), ())

    def seq(self, table, info, key, parent, actions, a):
        if key not in info:
            info[key] = (parent, actions)
        s = (key, a)
        if s not in table:
            table[s] = len(table)
        return s

    def rec(self, typ, st, pr, cs, zs):
        p = self.p
        cacts = ['G', 'B'] if st['g'] == 2 else CA
        for a in cacts:
            if self.afk and self.afk[0] == 'C':
                w = self.afk[1](st, cacts).get(a, 0)
                if w == 0: continue
                cs2, pa = cs, pr * w
            else:
                cs2, pa = self.seq(self.cseq, self.cinfo, ('C', typ, st['hist']), cs, cacts, a), pr
            for b in ZA:
                if self.afk and self.afk[0] == 'Z':
                    w = self.afk[1](st, ZA).get(b, 0)
                    if w == 0: continue
                    zs2, pb = zs, pa * w
                else:
                    zs2, pb = self.seq(self.zseq, self.zinfo, ('Z', st['zobs']), zs, ZA, b), pa
                for q, e in resolve(st, typ, a, b, p):
                    self.step(typ, st, pb * q, cs2, zs2, a, b, e)

    def step(self, typ, st, pr, cs, zs, a, b, e):
        p = self.p
        n = dict(st)
        n['life'] = st['life'] - e['dc']
        n['res'] = min(p['res_max'], st['res'] - e['dz'] + (p['bite_heal'] if e['bite'] else 0))
        n['pc'] += e['pc']; n['pz'] += e['pz']; n['g'] = e['g']; n['exp'] = e['exp']
        n['inf'] = st['inf'] or e['inf']; n['bites'] += e['bite']; n['r'] += 1
        outcome = (e['pc'], e['pz'], e['bite'], e['elim'])
        cl = a + (typ if (a == 'G' and st['g'] == 0 and p['informed']) else '')
        n['hist'] = st['hist'] + ((a, b, outcome),)
        n['zobs'] = st['zobs'] + ((cl, b, outcome),)
        conv = n['life'] <= 0
        fall = e['elim'] or n['res'] <= 0
        if e['end'] or fall or conv or n['pc'] >= 2 or n['pz'] >= 2 or n['r'] >= 3:
            self.leaf(typ, n, pr, cs, zs, conv, fall, e['elim'], e['end'] and not e['elim'])
        else:
            self.rec(typ, n, pr, cs, zs)

    def leaf(self, typ, n, pr, cs, zs, conv, fall, elim, fled=False):
        p = self.p
        closs = min(p['life0'], p['life0'] - n['life'])
        zloss = p['res0'] if fall else p['res0'] - n['res']
        if conv and n['inf']:
            zloss -= p['convert_heal']
        u = zloss / p['res_max'] - closs / p['life_max'] - p['I'] * n['inf'] \
            - p['Cconv'] * conv + p['E'] * fall \
            + p['W'] * (n['pc'] >= 2) - p['W'] * (n['pz'] >= 2)
        k = (self.cseq[cs] if cs else 0, self.zseq[zs] if zs else 0)
        self.A[k] = self.A.get(k, 0) + pr * u
        self.leaves.append(dict(typ=typ, pr=pr, cs=cs, zs=zs, n=n, conv=conv, fall=fall,
                                elim=elim, fled=fled, closs=closs, zloss=zloss, u=u))

    def constraints(self, table, info):
        rows, cols, vals = [0], [0], [1.0]
        for i, (key, (parent, acts)) in enumerate(info.items(), start=1):
            rows.append(i); cols.append(table[parent] if parent else 0); vals.append(-1.0)
            for a in acts:
                if (key, a) in table:
                    rows.append(i); cols.append(table[(key, a)]); vals.append(1.0)
        M = coo_matrix((vals, (rows, cols)), shape=(len(info) + 1, len(table))).tocsr()
        rhs = np.zeros(len(info) + 1); rhs[0] = 1
        return M, rhs

    def solve(self):
        nx, ny = len(self.cseq), len(self.zseq)
        r, c, v = zip(*[(i, j, val) for (i, j), val in self.A.items()])
        A = coo_matrix((v, (r, c)), shape=(nx, ny)).tocsr()
        E, e = self.constraints(self.cseq, self.cinfo)
        F, f = self.constraints(self.zseq, self.zinfo)
        from scipy.sparse import hstack
        # civil: max f.q  s.a. F^T q - A^T x <= 0, E x = e, x >= 0
        nq = F.shape[0]
        res = linprog(np.r_[np.zeros(nx), -f],
                      A_ub=hstack([-A.T, F.T]), b_ub=np.zeros(ny),
                      A_eq=hstack([E, coo_matrix((E.shape[0], nq))]), b_eq=e,
                      bounds=[(0, None)] * nx + [(None, None)] * nq, method='highs')
        x = res.x[:nx]
        # zombie: min e.p  s.a. E^T p - A y >= 0, F y = f, y >= 0
        npp = E.shape[0]
        res2 = linprog(np.r_[np.zeros(ny), e],
                       A_ub=hstack([A, -E.T]), b_ub=np.zeros(nx),
                       A_eq=hstack([F, coo_matrix((F.shape[0], npp))]), b_eq=f,
                       bounds=[(0, None)] * ny + [(None, None)] * npp, method='highs')
        y = res2.x[:ny]
        self.x, self.y, self.value = x, y, -res.fun
        return self.value

    def stats(self):
        """Recorre las hojas con las estrategias de equilibrio."""
        p = self.p
        xs = lambda s: self.x[self.cseq[s]] if s else 1.0
        ys = lambda s: self.y[self.zseq[s]] if s else 1.0
        out = dict(elim=0, fall=0, conv=0, inf=0, closs=0, zloss=0, flee=0, rounds=0,
                   elim_t={t: 0 for t in p['prior']}, zero_damage=0)
        for L in self.leaves:
            w = L['pr'] * (xs(L['cs']) if not (self.afk and self.afk[0] == 'C') else 1) \
                * (ys(L['zs']) if not (self.afk and self.afk[0] == 'Z') else 1)
            if w <= 1e-12: continue
            out['elim'] += w * L['elim']; out['fall'] += w * L['fall']
            out['elim_t'][L['typ']] += w * L['elim'] / p['prior'][L['typ']]
            out['conv'] += w * L['conv']; out['inf'] += w * L['n']['inf']
            out['closs'] += w * L['closs']; out['zloss'] += w * L['zloss']
            out['rounds'] += w * L['n']['r']
            out['flee'] += w * L['fled']
        return out

    def action_freq(self):
        """Frecuencia de cada accion (alcance del infoset x prob. de la accion), por tipo y asalto."""
        _reach(self)
        cf, zf = {}, {}
        for key, (parent, acts) in self.cinfo.items():
            typ, r, w = key[1], len(key[2]), self._rc.get(key, 0)
            for a in acts:
                pa = _beh(self.cseq, self.x, self.cinfo, key, a)
                for d in (cf.setdefault((typ, 'all'), {}), cf.setdefault((typ, r), {})):
                    d[a] = d.get(a, 0) + w * pa
        for key, (parent, acts) in self.zinfo.items():
            r, w = len(key[1]), self._rz.get(key, 0)
            for b in acts:
                pb = _beh(self.zseq, self.y, self.zinfo, key, b)
                for d in (zf.setdefault('all', {}), zf.setdefault(r, {})):
                    d[b] = d.get(b, 0) + w * pb
        norm = lambda d: {k: v / sum(d.values()) for k, v in d.items()} if sum(d.values()) else d
        return {k: norm(v) for k, v in cf.items()}, {k: norm(v) for k, v in zf.items()}


def _beh(table, vec, info, key, a):
    parent = info[key][0]
    den = vec[table[parent]] if parent else 1.0
    return vec[table[(key, a)]] / den if den > 1e-12 else 1.0 / len(info[key][1])


def _reach(game):
    """Probabilidad de alcanzar cada infoset (para pesar las frecuencias)."""
    if hasattr(game, '_rc'): return
    game._rc, game._rz = {}, {}
    p = game.p
    # Recorrido directo: rehacer el arbol con las estrategias y acumular alcance por infoset
    def rec(typ, st, pr):
        cacts = ['G', 'B'] if st['g'] == 2 else CA
        ck, zk = ('C', typ, st['hist']), ('Z', st['zobs'])
        game._rc[ck] = game._rc.get(ck, 0) + pr
        game._rz[zk] = game._rz.get(zk, 0) + pr
        for a in cacts:
            pa = _beh(game.cseq, game.x, game.cinfo, ck, a)
            for b in ZA:
                pb = _beh(game.zseq, game.y, game.zinfo, zk, b)
                if pa * pb <= 1e-12: continue
                for q, e in resolve(st, typ, a, b, p):
                    n = dict(st)
                    n['life'] = st['life'] - e['dc']
                    n['res'] = min(p['res_max'], st['res'] - e['dz'] + (p['bite_heal'] if e['bite'] else 0))
                    n['pc'] += e['pc']; n['pz'] += e['pz']; n['g'] = e['g']; n['exp'] = e['exp']
                    n['inf'] = st['inf'] or e['inf']; n['r'] += 1
                    o = (e['pc'], e['pz'], e['bite'], e['elim'])
                    cl = a + (typ if (a == 'G' and st['g'] == 0 and p['informed']) else '')
                    n['hist'] = st['hist'] + ((a, b, o),); n['zobs'] = st['zobs'] + ((cl, b, o),)
                    if not (e['end'] or e['elim'] or n['res'] <= 0 or n['life'] <= 0
                            or n['pc'] >= 2 or n['pz'] >= 2 or n['r'] >= 3):
                        rec(typ, n, pr * pa * pb * q)
    for typ, pr in p['prior'].items():
        if pr > 0:
            rec(typ, dict(r=0, pc=0, pz=0, g=0, exp=False, life=p['life0'], res=p['res0'],
                          inf=False, bites=0, hist=(), zobs=()), pr)


def run(**over):
    p = dict(BASE); p.update(over)
    g = Game(p); g.solve()
    return g


def fmt(d, keys):
    return ' '.join(f"{k} {d.get(k, 0):4.0%}" for k in keys)


def report(name, g):
    s = g.stats(); cf, zf = g.action_freq()
    print(f"\n== {name}   valor civil {g.value:+.3f}")
    print(f"   eliminacion {s['elim']:.1%} (armado {s['elim_t']['arma']:.1%})  caidas {s['fall']:.1%}"
          f"  infeccion {s['inf']:.0%}  huida {s['flee']:.0%}  asaltos {s['rounds']:.2f}"
          f"  dano civil {s['closs']:.1f}  dano zombie {s['zloss']:.1f}")
    for t in g.p['prior']:
        if g.p['prior'][t] > 0:
            print(f"   {t:5s} total: {fmt(cf[(t, 'all')], CA)} | asalto1: {fmt(cf[(t, 0)], CA)}")
    print(f"   zombie total: {fmt(zf['all'], ZA)} | asalto1: {fmt(zf[0], ZA)}"
          + (f" | asalto2: {fmt(zf[1], ZA)}" if 1 in zf else ''))


def afk_fixed(x):
    """Comportamiento por defecto al agotarse el tiempo: accion fija ('U' = al azar)."""
    def f(st, acts):
        if x == 'U':
            return {a: 1 / len(acts) for a in acts}
        return {x: 1.0} if x in acts else {'B': 1.0}
    return f


def timeout_table(**over):
    """Coste de no decidir con cada defecto, si el rival lo sabe y lo aprovecha."""
    p = dict(BASE); p.update(over)
    g = Game(p); v = g.solve()
    print(f"\n## Tiempo agotado ({over or 'base'}): valor de equilibrio para el civil {v:+.3f}")
    for who, opts in (('C', 'GBHU'), ('Z', 'MPAU')):
        for x in opts:
            ga = Game(p, afk=(who, afk_fixed(x))); va = ga.solve(); sa = ga.stats()
            print(f"   {'civil' if who == 'C' else 'zombie'} no decide -> {x}: valor civil {va:+.3f}"
                  f" ({va - v:+.3f})  dano civil {sa['closs']:4.1f}  dano zombie {sa['zloss']:4.1f}"
                  f"  infeccion {sa['inf']:3.0%}  eliminacion {sa['elim']:.1%}")


if __name__ == '__main__':
    R = {'raso': 1, 'herr': 0, 'arma': 0}
    report("Solo rasos, k=2 (v2.0: aun no hay mejoras)", run(prior=R))
    report("Solo rasos, k=1", run(prior=R, k=1.0))
    report("Mezcla 90/5/5, k=2, zombie informado", run(prior={'raso': .9, 'herr': .05, 'arma': .05}))
    report("Mezcla 60/25/15, k=2, zombie informado", run())
    report("Mezcla 60/25/15, k=2, zombie ciego", run(informed=False))
    report("Mezcla 60/25/15, k=1, zombie ciego (supuesto 04/10)", run(k=1.0, informed=False))
    report("Palanca A+B: arma atrapada en golpea-agarra + cazado = agarrado",
           run(GA_armed_grab=True, HP_grab=True))
    print("\n## Espiral de muerte (solo rasos): dano esperado por combate segun vida inicial")
    for lab, kw in (("k=2", {}), ("k=1", dict(k=1.0)), ("sin factor de salud", dict(health=False))):
        print(f"   {lab:22s}" + " | ".join(
            f"vida {L}: {run(prior=R, life0=L, **kw).stats()['closs']:.1f}" for L in (100, 60, 40, 20)))
    timeout_table(prior=R)
    timeout_table(prior={'raso': .9, 'herr': .05, 'arma': .05})
