import numpy as np, random
exec(open('/tmp/claude-0/rps.py').read().split('show("Base (rasos)"')[0])
def v5(bm):
    return np.array([[1/3*1+2/3*(-1.5),1.0,0.0],[bm,0.0,-1.3],[-0.2,-1.0,0.6]])
for name,bm in [("Bloquea gana siempre al mordisco",1.0),("Bloquea contra mordisco a dados 2/3 civil (si gana el zombie, mordisco en el antebrazo que infecta)",2/3*1+1/3*(-1.5))]:
    v,x,y=solve(v5(bm))
    print(f"\n{name}\n  valor civil {v:+.2f} | civil: "+", ".join(f"{c} {p:.0%}" for c,p in zip(C,x))+" | zombie: "+", ".join(f"{z} {p:.0%}" for z,p in zip(Z,y)))
    pM,pP,pA=y
    def combat(pbw):
        c=z=0; exposed=False
        for r in range(3):
            a=random.choices('MPA',[pM,pP,pA])[0]
            if exposed:
                if a=='M':
                    if random.random()<2/3: return 1
                    z+=1
                elif a=='P': c+=1
                exposed=False
            else:
                if a=='M':
                    if random.random()<pbw: c+=1; exposed=True
                    else: z+=1
                elif a=='A': return 0
            if c==2 or z==2: break
        return 0
    pbw=1.0 if bm==1.0 else 2/3
    N=200000; e=sum(combat(pbw) for _ in range(N))/N
    print(f"  militar (bloquea y luego dispara) elimina en {e:.0%} de los combates")
