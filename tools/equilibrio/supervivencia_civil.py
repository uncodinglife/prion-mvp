"""Supervivencia del civil raso joven (Claude 06/10/2026, noche): cuantos siguen siendo civiles
a los dias 7, 14, 30, 60 y 90, segun perfil de juego y escasez de suero.

Modelo por horas (Monte Carlo). Valores de game_params y del combate v6:
  vida 100, desgaste 3/dia, raciones +1 (+0,5 con nauseas del retardante), descanso +1/h
  (infectado +0,25/h), infeccion -0,5/h (-0,2/h con retardante), combate: dano medio 8,7
  (dispersion), infecta en 1 de cada 3. Suero: primera entrega el dia 15-20 (director);
  desde entonces, cada dia que el infectado busca, lo encuentra con probabilidad p_suero.
Supuestos [SUP]: perfiles (descanso, raciones, combates/dia, prob. de conseguir un blister de
retardante tras el mordisco); combates de Poisson; el suero cura la infeccion, no la vida.
"""
import numpy as np

PERFILES = {  # descanso h/dia, raciones/dia, combates/dia, P(blister)
    'descuidado': (8, 3, 1.0, 0.2),
    'medio':      (12, 3, 0.5, 0.4),
    'prudente':   (16, 4, 1 / 3, 0.7),
}
DIAS = (7, 14, 30, 60, 90)


def sim(perfil, p_suero, n=20000, seed=1, dias=90):
    rest, rac, lam, p_ret = PERFILES[perfil]
    rng = np.random.default_rng(seed)
    vivo_hasta = np.full(n, dias + 1.0)
    for i in range(n):
        vida, inf, ret_h = 100.0, False, 0
        s0 = rng.uniform(15, 20)
        for d in range(dias):
            nk = rng.poisson(lam)
            for _ in range(nk):
                vida -= max(0, rng.normal(8.7, 4))
                if rng.random() < 1 / 3 and not inf:
                    inf = True
                    if rng.random() < p_ret:
                        ret_h = 14 * 24
            if vida <= 0:
                vivo_hasta[i] = d; break
            if inf and d >= s0 and rng.random() < p_suero:
                inf = False; ret_h = 0
            ration = 0.5 if ret_h > 0 else 1.0
            if inf:
                tasa = 0.2 if ret_h > 0 else 0.5
                vida += -24 * tasa + rest * 0.25 + rac * ration - 3
                ret_h = max(0, ret_h - 24)
            else:
                vida = min(100, vida + rest * 1.0 + rac - 3)
            if vida <= 0:
                vivo_hasta[i] = d + 1; break
    return {t: float((vivo_hasta > t).mean()) for t in DIAS}, float(np.median(vivo_hasta))


if __name__ == '__main__':
    print("Sin suero (calibracion: descuidado 7-12, prudente 17-23)")
    for pf in PERFILES:
        s, med = sim(pf, 0.0, n=5000)
        print(f"  {pf:10s} mediana dia {med:5.1f} | " + ' '.join(f"d{t} {s[t]:4.0%}" for t in DIAS))
    for ps in (0.1, 0.3, 0.6):
        print(f"Suero desde el dia 15-20, p diaria de encontrarlo {ps}")
        for pf in PERFILES:
            s, med = sim(pf, ps, n=5000)
            print(f"  {pf:10s} mediana dia {med:5.1f} | " + ' '.join(f"d{t} {s[t]:4.0%}" for t in DIAS))
