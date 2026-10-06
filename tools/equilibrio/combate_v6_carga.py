"""Combate v6 con estados de carga (Claude 06/10/2026, noche).

Reglas de carga decididas por Angel el 06/10 (noche), sobre el v6 aprobado:
  - Carga: comida (3 raciones), nevera de suero (pack de 3) o las dos, en un brazo.
  - Penalizacion mientras la defiende: fuerza al golpear y bloquear x0,90 (comida),
    x0,95 (suero), x0,855 (las dos). Huir no se penaliza.
  - Se pierde la carga con: huida (cualquier intento, tambien la automatica por tiempo
    agotado y el tiron con un brazo agarrado), agarre de los dos brazos, o forcejeo
    (bloquear con un brazo agarrado). No se pierde por perder a puntos.

Supuestos de calculo [SUP] (no son reglas del juego):
  - Valor de la carga en puntos de vida equivalentes: comida 3 (3 raciones x +1) y
    suero 30 (un pack de 3 dosis; una dosis evita una conversion lenta). Se barre.
  - El zombie NO ve la carga (ve mal) ni le importa (solo busca cerebros). Por eso el
    calculo principal fija la estrategia del zombie en la del equilibrio v6 sin carga y el
    civil con carga responde lo mejor posible. Se compara con el caso extremo de suma cero
    en el que el zombie si sabe y si le importa (cota pesimista para el civil).
"""
import numpy as np
import combate_v6 as v6
from combate_v6 import P, CA, ZA, MEZCLA, ctx as mkctx

CARGO_F = {'none': 1.0, 'food': 0.90, 'serum': 0.95, 'both': 0.90 * 0.95}
CARGO_V = {'none': 0, 'food': 3, 'serum': 30, 'both': 33}   # [SUP] vida equivalente


def outcomes_c(st, c, a, b, p):
    res = v6.outcomes(st, c, a, b, p)
    f = c['cargo_f']
    if f == 1.0 or a not in ('G', 'B') or st['lost']:
        return res
    # Rehacer la probabilidad de los pulsos de golpe/fuerza con la penalizacion
    if len(res) == 1:
        return res
    (q, win, noise), (_, lose, _) = res
    # q = X/(X+Fz^k) con X = Fc^k  ->  Fc' = f*Fc  ->  X' = f^k X
    ratio = q / (1 - q) * f ** p['k']   # q/(1-q) = (Fc/Fz)^k; Fc' = f*Fc
    q2 = ratio / (1 + ratio)
    return [(q2, win, noise), (1 - q2, lose, noise)]


class GameC(v6.Game):
    """prior: {(typ, cargo): prob}. El tipo de civil oculto incluye la carga."""

    def __init__(self, p, ctx, prior, mode='experto', afk=None):
        self.p, self.ctx, self.mode, self.afk = p, ctx, mode, afk
        self.cseq, self.zseq, self.cinfo, self.zinfo = {(): 0}, {(): 0}, {}, {}
        self.A, self.leaves = {}, []
        for (typ, cargo), pr in prior.items():
            if pr > 0:
                c = dict(ctx, typ=typ, cargo=cargo, cargo_f=CARGO_F[cargo], lab=f"{typ}+{cargo}")
                st = dict(r=0, pc=0, pz=0, g=0, exp=False,
                          life=ctx.get('life', p['vida_max'][ctx['edad']]), res=p['res0'],
                          inf=False, bites=0, over=False, fails=0, hist=(), zobs=(),
                          lost=(cargo == 'none'))
                self.rec(c, st, pr, (), ())

    def rec(self, c, st, pr, cs, zs):
        cacts = ['G', 'B'] if st['g'] == 2 else CA
        civ_afk = self.afk and self.afk[0] == 'C'
        loop = list(self.afk[1](st, cacts)) if civ_afk else cacts
        for a in loop:
            if civ_afk:
                w = self.afk[1](st, cacts).get(a, 0)
                if not w: continue
                cs2, pa = cs, pr * w
            else:
                cs2 = self.seq(self.cseq, self.cinfo, ('C', c['lab'], st['hist']), cs, cacts, a)
                pa = pr
            for b in ZA:
                if self.afk and self.afk[0] == 'Z':
                    w = self.afk[1](st, ZA).get(b, 0)
                    if not w: continue
                    zs2, pb = zs, pa * w
                else:
                    zs2, pb = self.seq(self.zseq, self.zinfo, ('Z', st['zobs']), zs, ZA, b), pa
                for q, o, noise in outcomes_c(st, c, a, b, self.p):
                    if q > 0:
                        self.step(c, st, pb * q, cs2, zs2, a, b, o, noise)



# Paso de asalto: el de v6 con perdida de carga y su coste al cerrar la hoja.
def _step(self, c, st, pr, cs, zs, a, b, o, noise):
    p = self.p
    drop = a in ('H', 'h') or o['g'] == 2 or (st['g'] == 1 and a == 'B')
    n = dict(st)
    n['lost'] = st['lost'] or drop
    bite = o['inf']
    n['life'] = st['life'] - o['dc']
    n['res'] = min(p['res_max'], st['res'] - o['dz'] + (p['bite_heal'] if bite else 0))
    n['pc'] += o['pc']; n['pz'] += o['pz']; n['g'] = o['g']; n['exp'] = o['exp']
    n['inf'] = st['inf'] or bite; n['bites'] += bite; n['r'] += 1
    n['over'] = st['over'] or noise; n['fails'] += o['fail']
    res = (o['pc'], o['pz'], bite, o.get('elim', False), o['end'])
    n['hist'] = st['hist'] + ((a, b, res),)
    seen = a if not (noise and self.mode == 'experto') else 'G!'
    n['zobs'] = st['zobs'] + ((seen, b, res),)
    conv, fall = n['life'] <= 0, o.get('elim', False) or n['res'] <= 0
    if conv:
        n['lost'] = True          # convertido: la carga queda en el suelo
    if o['end'] or fall or conv or n['pc'] >= 2 or n['pz'] >= 2 or n['r'] >= 3:
        vmax = p['vida_max'][c['edad']]
        closs = c.get('life', vmax) - max(0, n['life'])
        zloss = p['res0'] if fall else p['res0'] - n['res']
        if conv and n['inf']:
            zloss -= p['convert_heal']
        lostv = CARGO_V[c['cargo']] if (n['lost'] and c['cargo'] != 'none') else 0
        u = zloss / p['res_max'] - closs / 100 - p['I'] * n['inf'] - p['Cconv'] * conv \
            + p['E'] * fall + p['W'] * (n['pc'] >= 2) - p['W'] * (n['pz'] >= 2) - lostv / 100
        key = (self.cseq[cs] if cs else 0, self.zseq[zs] if zs else 0)
        self.A[key] = self.A.get(key, 0) + pr * u
        self.leaves.append(dict(typ=c['lab'], pr=pr, cs=cs, zs=zs, n=n, conv=conv, fall=fall,
                                elim=o.get('elim', False), fled=o['end'] and not o.get('elim'),
                                closs=closs, zloss=zloss,
                                kept=(c['cargo'] != 'none' and not n['lost'])))
    else:
        self.rec(c, n, pr, cs, zs)


GameC.step = _step


def zombie_behavior(g):
    """Estrategia de comportamiento del zombie (por observaciones) a partir de su plan."""
    beh = {}
    for key, (parent, acts) in g.zinfo.items():
        yp = g.y[g.zseq[parent]] if parent else 1.0
        if yp < 1e-12:
            beh[key[1]] = {b: 1 / 3 for b in acts}
        else:
            beh[key[1]] = {b: g.y[g.zseq[(key, b)]] / yp for b in acts}
    return beh


def per_type(g, lab):
    s = dict(w=0, kept=0, closs=0, inf=0, flee=0, conv=0, zloss=0)
    for L in g.leaves:
        if L['typ'] != lab: continue
        w = g._w(L)
        s['w'] += w; s['kept'] += w * L['kept']; s['closs'] += w * L['closs']
        s['inf'] += w * L['n']['inf']; s['flee'] += w * L['fled']; s['conv'] += w * L['conv']
        s['zloss'] += w * L['zloss']
    return {k: (v / s['w'] if k != 'w' else v) for k, v in s.items()}


def report(g, labs):
    cf, zf = g.freqs()
    for lab in labs:
        s = per_type(g, lab)
        f = cf.get(lab, {})
        kept = f"conserva {s['kept']:4.0%}" if not lab.endswith('none') else ' ' * 13
        print(f"    {lab:12s} G {f.get('G',0):4.0%} B {f.get('B',0):4.0%} H {f.get('H',0):4.0%} | "
              f"{kept} dano {s['closs']:4.1f} inf {s['inf']:4.0%} huida {s['flee']:4.0%} "
              f"dZ {s['zloss']:4.1f}")
    print(f"    zombie M {zf.get('M',0):4.0%} P {zf.get('P',0):4.0%} A {zf.get('A',0):4.0%}")


def base_mix(cargo_share, cargo='food'):
    pr = {}
    for t, w in MEZCLA.items():
        pr[(t, 'none')] = w * (1 - cargo_share)
        if cargo_share > 0:
            pr[(t, cargo)] = w * cargo_share
    return pr


if __name__ == '__main__':
    p = dict(P)
    base = v6.run(MEZCLA)
    beh = zombie_behavior(base)
    zfix = ('Z', lambda st, acts: beh.get(st['zobs'], {b: 1 / 3 for b in acts}))
    print("## A) Zombie que no ve la carga: juega el v6 sin carga; el civil responde")
    for cargo in ('none', 'food', 'serum', 'both'):
        print(f"  carga {cargo}")
        for typ in ('raso', 'herr', 'arma'):
            g = GameC(p, mkctx(), {(typ, cargo): 1.0}, afk=zfix).solve()
            report(g, [f"{typ}+{cargo}"])
    print("## A2) Sensibilidad al valor de la carga (raso, zombie fijo)")
    for vf in (0, 3, 9, 20, 30, 60):
        CARGO_V['food'] = vf
        g = GameC(p, mkctx(), {('raso', 'food'): 1.0}, afk=zfix).solve()
        print(f"  valor {vf:2d}:", end='')
        report(g, ['raso+food'])
    CARGO_V['food'] = 3
    print("## A3) Rasos heridos con nevera de suero (vida 40, zombie fijo)")
    for cargo in ('none', 'serum'):
        g = GameC(p, mkctx(life=40), {('raso', cargo): 1.0}, afk=zfix).solve()
        report(g, [f"raso+{cargo}"])
    print("## B) Suma cero, el zombie sabe que hay carga y le importa (cota pesimista)")
    for share, cargo in ((0.3, 'food'), (0.3, 'serum'), (1.0, 'food')):
        pr = base_mix(share, cargo)
        g = GameC(p, mkctx(), pr).solve()
        print(f"  {share:.0%} de civiles con {cargo}: valor {g.value:+.3f} (sin carga {base.value:+.3f})")
        report(g, [f"raso+none", f"raso+{cargo}", f"arma+{cargo}"] if share < 1 else [f"raso+{cargo}", f"arma+{cargo}"])
