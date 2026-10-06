"""Combate v6: modelo de calculo con todas las variables (propuesta Claude 06/10/2026).

Principio: la LECTURA del rival decide quien tiene ventaja en cada cruce; el CUERPO
(edad, salud, cansancio, arma, experiencia, sobreexcitacion) decide cuanta.
Casi todos los cruces fisicos se resuelven con un pulso: incluso quien acierta la
lectura puede fallar (la gota de sudor). Solo son seguros los cruces sin contacto
(se tantean) y el reflejo de prension, que por la ficha del zombie nunca falla.

P(gana el civil) = Fc^k / (Fc^k + Fz^k)
  Fc = base_del_cruce * salud * edad[stat] * cansancio * experiencia
  Fz = 1 * sobreexcitacion * experiencia      (el estado del zombie no influye: no siente dolor)

La tabla CELLS es la especificacion de la futura tabla de combate en la base:
(agarre, accion civil, accion zombie) -> tipo, estadistica, fuerza base, resultado si gana
el civil, resultado si gana el zombie. Todos los numeros, en P (futuro game_params).

Se resuelve el combate completo (3 asaltos) como juego de suma cero con informacion
oculta (el zombie no sabe si el civil va armado), en forma secuencial (von Stengel 1996).
"""
import numpy as np
from scipy.optimize import linprog
from scipy.sparse import coo_matrix, hstack

# ---------------------------------------------------------------- parametros
P = dict(
    k=2.0,
    # Fuerza de golpear por equipamiento y multiplicador de dano del golpe
    F_golpe={'raso': 0.75, 'herr': 1.38, 'arma': 1.94},
    mult={'raso': 1.0, 'herr': 1.5, 'arma': 2.0},
    # Fuerzas base de los cruces (con k = 2: 0.6 -> 26 %, 1.0 -> 50 %, 2.0 -> 80 %, 3.0 -> 90 %)
    base_GP=1.7,      # golpe a quien te persigue (sorpresa)
    base_BM=3.8,      # bloquear el mordisco
    base_HM=2.7,      # huir de quien muerde (se gira y escapa)
    base_HP=0.55,     # huir de quien persigue (carrera)
    base_HA=1.6,      # huir de quien intenta agarrar
    base_grab1=0.90,  # zafarse de un mordisco con un brazo agarrado
    base_grab2=0.35,  # con los dos brazos agarrados
    # Edad ficticia: fuerza / agilidad
    edad={'joven': {'fuerza': 1.00, 'agil': 1.10},
          'medio': {'fuerza': 1.05, 'agil': 1.00},
          'viejo': {'fuerza': 0.95, 'agil': 0.90}},
    vida_max={'joven': 100, 'medio': 90, 'viejo': 80},
    # Cansancio del civil (el zombie no se cansa: no duerme ni siente fatiga)
    cansancio_asalto=0.93,   # por cada asalto ya disputado
    cansancio_huida=0.85,    # extra, en agilidad, por cada huida que no acaba el combate
    # Experiencia (0..1, curva logaritmica por combates; tope +10 %)
    exp_max=0.10,
    # Ruido del disparo: sobresalto en el momento, sobreexcitacion el resto del combate
    sobreexc=1.25,
    dz_golpe=8,      # dano del golpe que acierta (x multiplicador del equipamiento)
    # Dano / resistencia
    res0=60, res_max=60, bite_heal=4, convert_heal=10,
    # Valoracion [SUP] para el calculo (no son reglas del juego)
    I=0.20, Cconv=0.50, E=0.50, W=0.05,
)

# Resultado de un asalto: dc/dz dano civil/zombie, pc/pz punto, g agarre siguiente,
# exp boca expuesta, inf mordisco que infecta, end fin del combate, fail huida fallida.
def O(**kw):
    d = dict(dc=0, dz=0, pc=0, pz=0, g=0, exp=False, inf=False, end=False, fail=False)
    d.update(kw)
    return d

# kind 'fixed': resultado unico. kind 'pulse': stat + base + (gana civil, gana zombie).
# stat: 'golpe' (fuerza x equipamiento), 'fuerza' (sin arma), 'agil'.
CELLS = {
    # ------------------------------------------------------------ sin agarre
    (0, 'G', 'M'): ('pulse', 'golpe', None, O(dc=2, dz=8, pc=1), O(dc=8, dz=2, pz=1, inf=True)),
    (0, 'G', 'P'): ('pulse', 'golpe', 'base_GP', O(dc=2, dz=8, pc=1), O(dc=5, dz=1, pz=1)),
    (0, 'G', 'A'): ('fixed', O(dc=3, dz=3)),   # raso: el golpe aparta. Con arma: ver ARMA_ATRAPADA
    (0, 'B', 'M'): ('pulse', 'fuerza', 'base_BM', O(dc=2, dz=2, pc=1, exp=True), O(dc=4, dz=1, pz=1, inf=True)),
    (0, 'B', 'P'): ('fixed', O(dc=1, dz=1)),
    (0, 'B', 'A'): ('fixed', O(dc=3, dz=1, pz=1, g=1)),
    (0, 'H', 'M'): ('pulse', 'agil', 'base_HM', O(dc=5, dz=1, end=True), O(dc=8, dz=1, pz=1, inf=True, fail=True)),
    (0, 'H', 'P'): ('pulse', 'agil', 'base_HP', O(dc=3, dz=1, end=True), O(dc=8, dz=2, pz=1, g=1, fail=True)),
    (0, 'H', 'A'): ('pulse', 'agil', 'base_HA', O(dc=3, dz=1, end=True), O(dc=3, dz=1, pz=1, g=1, fail=True)),
    # ------------------------------------------------------------ un brazo agarrado
    (1, 'G', 'M'): ('pulse', 'fuerza', 'base_grab1', O(dc=2, dz=6, pc=1), O(dc=10, dz=2, pz=1, g=1, inf=True)),
    (1, 'B', 'M'): ('pulse', 'fuerza', 'base_grab1', O(dc=2, dz=2, pc=1, exp=True, g=1), O(dc=10, dz=2, pz=1, g=1, inf=True)),
    (1, 'H', 'M'): ('pulse', 'fuerza', 'base_grab1', O(dc=3, dz=1, end=True), O(dc=10, dz=2, pz=1, g=1, inf=True)),
    (1, 'G', 'P'): ('fixed', O(dc=1, dz=6, pc=1)),          # golpe con el brazo libre: se suelta
    (1, 'G', 'A'): ('fixed', O(dc=1, dz=6, pc=1)),
    (1, 'B', 'P'): ('fixed', O(dc=2, dz=2, g=1)),           # forcejeo
    (1, 'B', 'A'): ('fixed', O(dc=3, dz=1, pz=1, g=2)),     # segundo brazo
    (1, 'H', 'P'): ('fixed', O(dc=3, dz=1, pz=1, g=1, fail=True)),  # tiron fallido
    (1, 'H', 'A'): ('fixed', O(dc=3, dz=1, end=True)),      # tiron: se suelta y escapa
    # ------------------------------------------------------------ dos brazos (huir desactivado)
    (2, 'G', 'M'): ('pulse', 'fuerza', 'base_grab2', O(dc=2, dz=6, pc=1, g=1), O(dc=12, dz=2, pz=1, g=2, inf=True)),
    (2, 'B', 'M'): ('pulse', 'fuerza', 'base_grab2', O(dc=2, dz=2, pc=1, g=2, exp=True), O(dc=12, dz=2, pz=1, g=2, inf=True)),
    (2, 'G', 'P'): ('fixed', O(dc=1, dz=6, pc=1, g=1)),     # patada: libera un brazo
    (2, 'G', 'A'): ('fixed', O(dc=1, dz=6, pc=1, g=1)),
    (2, 'B', 'P'): ('fixed', O(dc=2, dz=2, g=2)),
    (2, 'B', 'A'): ('fixed', O(dc=2, dz=2, g=2)),
}
# Con herramienta o arma, golpea-agarra: el arma toca la palma y el reflejo la atrapa.
ARMA_ATRAPADA = O(dc=3, dz=1, pz=1, g=1)
# Tiempo agotado del civil: huida a ciegas con resultado fijo (sin pulso, nunca infecta).
# Si el zombie persigue, le caza (8) y el combate sigue; dos cazas = 16 y fin.
HUIDA_AUTO = {'M': O(dc=5, dz=1, end=True), 'P': O(dc=8, dz=2, pz=1), 'A': O(dc=3, dz=1, end=True)}

CA, ZA = ['G', 'B', 'H'], ['M', 'P', 'A']


def exp_factor(n_combates, p):
    return 1 + p['exp_max'] * min(1.0, np.log1p(n_combates) / np.log1p(50))


def outcomes(st, ctx, a, b, p):
    """Lista de (prob, resultado, ruido) para el cruce (a, b) en el estado st."""
    g, typ = st['g'], ctx['typ']
    if a == 'h':
        return [(1.0, HUIDA_AUTO[b], False)]
    if g == 0 and (a, b) == ('G', 'A') and typ != 'raso' and ctx['arma_atrapada']:
        return [(1.0, ARMA_ATRAPADA, False)]
    cell = CELLS[(g, a, b)]
    noise = (g == 0 and a == 'G' and typ == 'arma')          # el disparo suena siempre
    if cell[0] == 'fixed':
        return [(1.0, cell[1], noise)]
    _, stat, basekey, win, lose = cell
    vmax = p['vida_max'][ctx['edad']]
    salud = 0.6 + 0.4 * max(0, st['life']) / vmax
    cans = p['cansancio_asalto'] ** st['r']
    if stat == 'golpe':
        base = p['F_golpe'][typ] if basekey is None else p[basekey]
        edad = p['edad'][ctx['edad']]['fuerza']
    elif stat == 'fuerza':
        base, edad = p[basekey], p['edad'][ctx['edad']]['fuerza']
    else:
        base, edad = p[basekey], p['edad'][ctx['edad']]['agil']
        cans *= p['cansancio_huida'] ** st['fails']
    Fc = base * salud * edad * cans * exp_factor(ctx['exp_c'], p)
    Fz = (p['sobreexc'] if st['over'] else 1.0) * exp_factor(ctx['exp_z'], p)
    q = Fc ** p['k'] / (Fc ** p['k'] + Fz ** p['k'])
    if stat == 'golpe':
        m = p['mult'][typ]
        win = dict(win, dz=p['dz_golpe'] * m)
        if (a, b) == ('G', 'M') and st['exp'] and typ == 'arma':
            win = dict(win, dz=0, elim=True, end=True)            # tiro a la silla turca
    return [(q, win, noise), (1 - q, lose, noise)]


# ---------------------------------------------------------------- juego y solver
class Game:
    def __init__(self, p, ctx, prior, mode='experto', afk=None):
        """mode: 'experto' (el zombie oye el estruendo y deduce), 'novato' (no deduce nada)."""
        self.p, self.ctx, self.mode, self.afk = p, ctx, mode, afk
        self.cseq, self.zseq, self.cinfo, self.zinfo = {(): 0}, {(): 0}, {}, {}
        self.A, self.leaves = {}, []
        for typ, pr in prior.items():
            if pr > 0:
                c = dict(ctx, typ=typ)
                st = dict(r=0, pc=0, pz=0, g=0, exp=False, life=ctx.get('life', p['vida_max'][ctx['edad']]),
                          res=p['res0'], inf=False, bites=0, over=False, fails=0, hist=(), zobs=())
                self.rec(c, st, pr, (), ())

    def seq(self, table, info, key, parent, acts, a):
        info.setdefault(key, (parent, acts))
        s = (key, a)
        table.setdefault(s, len(table))
        return s

    def rec(self, c, st, pr, cs, zs):
        cacts = ['G', 'B'] if st['g'] == 2 else CA
        loop = list(self.afk[1](st, cacts)) if (self.afk and self.afk[0] == 'C') else cacts
        for a in loop:
            if self.afk and self.afk[0] == 'C':
                w = self.afk[1](st, cacts).get(a, 0)
                if not w: continue
                cs2, pa = cs, pr * w
            else:
                cs2, pa = self.seq(self.cseq, self.cinfo, ('C', c['typ'], st['hist']), cs, cacts, a), pr
            for b in ZA:
                if self.afk and self.afk[0] == 'Z':
                    w = self.afk[1](st, ZA).get(b, 0)
                    if not w: continue
                    zs2, pb = zs, pa * w
                else:
                    zs2, pb = self.seq(self.zseq, self.zinfo, ('Z', st['zobs']), zs, ZA, b), pa
                for q, o, noise in outcomes(st, c, a, b, self.p):
                    if q > 0:
                        self.step(c, st, pb * q, cs2, zs2, a, b, o, noise)

    def step(self, c, st, pr, cs, zs, a, b, o, noise):
        p = self.p
        n = dict(st)
        bite = o['inf']
        n['life'] = st['life'] - o['dc']
        n['res'] = min(p['res_max'], st['res'] - o['dz'] + (p['bite_heal'] if bite else 0))
        n['pc'] += o['pc']; n['pz'] += o['pz']; n['g'] = o['g']; n['exp'] = o['exp']
        n['inf'] = st['inf'] or bite; n['bites'] += bite; n['r'] += 1
        n['over'] = st['over'] or noise; n['fails'] += o['fail']
        res = (o['pc'], o['pz'], bite, o.get('elim', False), o['end'])
        n['hist'] = st['hist'] + ((a, b, res),)
        seen = a if not (noise and self.mode == 'experto') else 'G!'   # estruendo
        n['zobs'] = st['zobs'] + ((seen, b, res),)
        conv, fall = n['life'] <= 0, o.get('elim', False) or n['res'] <= 0
        if o['end'] or fall or conv or n['pc'] >= 2 or n['pz'] >= 2 or n['r'] >= 3:
            vmax = p['vida_max'][c['edad']]
            closs = c.get('life', vmax) - max(0, n['life'])
            zloss = p['res0'] if fall else p['res0'] - n['res']
            if conv and n['inf']:
                zloss -= p['convert_heal']
            u = zloss / p['res_max'] - closs / 100 - p['I'] * n['inf'] - p['Cconv'] * conv \
                + p['E'] * fall + p['W'] * (n['pc'] >= 2) - p['W'] * (n['pz'] >= 2)
            key = (self.cseq[cs] if cs else 0, self.zseq[zs] if zs else 0)
            self.A[key] = self.A.get(key, 0) + pr * u
            self.leaves.append(dict(typ=c['typ'], pr=pr, cs=cs, zs=zs, n=n, conv=conv, fall=fall,
                                    elim=o.get('elim', False), fled=o['end'] and not o.get('elim'),
                                    closs=closs, zloss=zloss))
        else:
            self.rec(c, n, pr, cs, zs)

    @staticmethod
    def _cons(table, info):
        r, c, v = [0], [0], [1.0]
        for i, (key, (parent, acts)) in enumerate(info.items(), start=1):
            r.append(i); c.append(table[parent] if parent else 0); v.append(-1.0)
            for a in acts:
                if (key, a) in table:
                    r.append(i); c.append(table[(key, a)]); v.append(1.0)
        rhs = np.zeros(len(info) + 1); rhs[0] = 1
        return coo_matrix((v, (r, c)), shape=(len(info) + 1, len(table))).tocsr(), rhs

    def solve(self):
        nx, ny = len(self.cseq), len(self.zseq)
        i, j, v = zip(*[(a, b, val) for (a, b), val in self.A.items()])
        A = coo_matrix((v, (i, j)), shape=(nx, ny)).tocsr()
        E, e = self._cons(self.cseq, self.cinfo)
        F, f = self._cons(self.zseq, self.zinfo)
        nq, npp = F.shape[0], E.shape[0]
        r1 = linprog(np.r_[np.zeros(nx), -f], A_ub=hstack([-A.T, F.T]), b_ub=np.zeros(ny),
                     A_eq=hstack([E, coo_matrix((npp, nq))]), b_eq=e,
                     bounds=[(0, None)] * nx + [(None, None)] * nq, method='highs')
        r2 = linprog(np.r_[np.zeros(ny), e], A_ub=hstack([A, -E.T]), b_ub=np.zeros(nx),
                     A_eq=hstack([F, coo_matrix((nq, npp))]), b_eq=f,
                     bounds=[(0, None)] * ny + [(None, None)] * npp, method='highs')
        self.x, self.y, self.value = r1.x[:nx], r2.x[:ny], -r1.fun
        return self

    def _w(self, L):
        x = 1.0 if (self.afk and self.afk[0] == 'C') or not L['cs'] else self.x[self.cseq[L['cs']]]
        y = 1.0 if (self.afk and self.afk[0] == 'Z') or not L['zs'] else self.y[self.zseq[L['zs']]]
        return L['pr'] * x * y

    def stats(self, prior):
        s = dict(elim=0, conv=0, inf=0, closs=0, zloss=0, flee=0, rounds=0, cwin=0, zwin=0)
        et = {t: 0.0 for t in prior}
        for L in self.leaves:
            w = self._w(L)
            if w < 1e-12: continue
            s['elim'] += w * L['elim']; s['conv'] += w * L['conv']; s['inf'] += w * L['n']['inf']
            s['closs'] += w * L['closs']; s['zloss'] += w * L['zloss']; s['flee'] += w * L['fled']
            s['rounds'] += w * L['n']['r']
            s['cwin'] += w * (L['n']['pc'] >= 2); s['zwin'] += w * (L['n']['pz'] >= 2)
            et[L['typ']] += w * L['elim'] / prior[L['typ']]
        s['elim_t'] = et
        return s

    def freqs(self):
        """Frecuencia de cada accion = sum(prob. de llegar al infoset x prob. de la accion)."""
        cf, zf = {}, {}
        for L in self.leaves:
            w = self._w(L)
            if w < 1e-12: continue
            for (a, b, _) in L['n']['hist']:
                d = cf.setdefault(L['typ'], {}); d[a] = d.get(a, 0) + w
                zf[b] = zf.get(b, 0) + w
        norm = lambda d: {k: v / sum(d.values()) for k, v in d.items()}
        return {t: norm(d) for t, d in cf.items()}, norm(zf)


def ctx(edad='joven', exp_c=0, exp_z=0, life=None, arma_atrapada=True):
    c = dict(edad=edad, exp_c=exp_c, exp_z=exp_z, arma_atrapada=arma_atrapada)
    if life is not None:
        c['life'] = life
    return c


def run(prior, c=None, mode='experto', **over):
    p = dict(P); p.update(over)
    return Game(p, c or ctx(), prior, mode).solve()


def fmt(d, keys):
    return ' '.join(f"{k}{d.get(k, 0):4.0%}" for k in keys)


def line(name, g, prior):
    s = g.stats(prior); cf, zf = g.freqs()
    civ = ' | '.join(f"{t} {fmt(cf.get(t, {}), CA)}" for t in prior if prior[t] > 0)
    print(f"{name:30s} elim {s['elim']:4.1%} inf {s['inf']:3.0%} huida {s['flee']:3.0%} "
          f"asl {s['rounds']:.2f} dC {s['closs']:4.1f} dZ {s['zloss']:4.1f} | {civ} | Z {fmt(zf, ZA)}")
    return s, cf, zf


RASOS = {'raso': 1.0}
MEZCLA = {'raso': .90, 'herr': .05, 'arma': .05}
GUERRA = {'raso': .60, 'herr': .25, 'arma': .15}

if __name__ == '__main__':
    print("## Escenarios")
    for name,pr in (('rasos',RASOS),('mezcla',MEZCLA),('guerra',GUERRA)):
        for mode in ('experto','novato'): line(f"{name} {mode}",run(pr,mode=mode),pr)
    print("## Sobreexcitacion (guerra, experto)")
    for so in (1.0,1.25,1.5): line(f"sobreexc {so}",run(GUERRA,sobreexc=so),GUERRA)
    print("## Edad (rasos)")
    for e in ('joven','medio','viejo'):
        g=run(RASOS,ctx(edad=e)); s=g.stats(RASOS); vm=P['vida_max'][e]
        print(f"  {e}: valor {g.value:+.3f} dano {s['closs']:.1f} inf {s['inf']:.0%} -> combates hasta caer ~{vm/s['closs']:.1f}")
    print("## Espiral (joven raso) y militar herido")
    for L in (100,60,40,20):
        g=run(RASOS,ctx(life=L)); s=g.stats(RASOS); ga=run({'arma':1.0},ctx(life=L)); sa=ga.stats({'arma':1.0})
        sal=0.6+0.4*L/100; q=lambda F:(F*sal)**2/((F*sal)**2+1)
        print(f"  vida {L}: raso dano {s['closs']:.1f} inf {s['inf']:.0%} | P(golpe mano) {q(.75):.0%}  P(disparo) {q(1.94):.0%} | militar solo: elim {sa['elim']:.1%} dano zombie {sa['zloss']:.1f}")
    print("## Experiencia (rasos)")
    for ec,ez in ((0,0),(50,0),(0,50),(50,50)):
        g=run(RASOS,ctx(exp_c=ec,exp_z=ez)); s=g.stats(RASOS)
        print(f"  civil {ec} combates, zombie {ez}: valor {g.value:+.3f} dano civil {s['closs']:.1f} dano zombie {s['zloss']:.1f} inf {s['inf']:.0%}")
    print("## Eliminacion contra zombie ingenuo (muerde/persigue/agarra con frecuencias medias, sin reaccionar)")
    g=run(MEZCLA); _,zf=g.freqs()
    for mix,lab in ((zf,'mezcla media'),({'M':1/3,'P':1/3,'A':1/3},'al azar')):
        ga=Game(dict(P),ctx(),{'arma':1.0},afk=('Z',lambda st,acts,m=mix:m)).solve(); sa=ga.stats({'arma':1.0})
        print(f"  militar vs zombie {lab}: eliminacion {sa['elim']:.1%}")
    print("## Tiempo agotado (mezcla): civil huida automatica / zombie muerde")
    g=run(MEZCLA); v=g.value
    for who,x in (('C','h'),('Z','M')):
        ga=Game(dict(P),ctx(),MEZCLA,afk=(who,lambda st,acts,x=x:{x:1.0})).solve(); sa=ga.stats(MEZCLA)
        print(f"  {who} no decide -> {x}: valor civil {ga.value:+.3f} ({ga.value-v:+.3f}) dano civil {sa['closs']:.1f} inf {sa['inf']:.0%} elim {sa['elim']:.1%}")
    print("## k")
    for k in (1.0,1.5,2.0,3.0): line(f"k={k} mezcla",run(MEZCLA,k=k),MEZCLA)
