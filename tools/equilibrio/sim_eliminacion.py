import random
def combat(pM=0.42,pP=0.21,pA=0.37, p_win_shot=2/3, ammo=99, rounds=3):
    c=z=0
    for r in range(rounds):
        a=random.choices('MPA',[pM,pP,pA])[0]
        if a=='M':
            if random.random()<p_win_shot: return 'eliminado'
            z+=1
        elif a=='P': c+=1
        if c==2 or z==2: break
    return 'otro'
for pw in (2/3, 1/2, 1/3):
    N=200000
    e=sum(combat(p_win_shot=pw)=='eliminado' for _ in range(N))/N
    print(f"probabilidad de ganar el disparo {pw:.2f}: eliminación en {e:.0%} de los combates (militar que dispara siempre, zombie que no sabe que es militar)")

def combat2(pM=0.42,pP=0.21,pA=0.37, p_block_win=2/3, p_shot=2/3):
    # El militar bloquea hasta que la boca queda expuesta (para un mordisco), y entonces dispara.
    c=z=0; exposed=False
    for r in range(3):
        a=random.choices('MPA',[pM,pP,pA])[0]
        if exposed:
            if a=='M':
                if random.random()<p_shot: return 'eliminado'
                z+=1
            elif a=='P': c+=1
            exposed=False
        else:
            if a=='M':
                if random.random()<p_block_win: c+=1; exposed=True
                else: z+=1
            elif a=='A': z+=1; return 'otro'  # brazo agarrado: ya no hay disparo limpio (simplificación)
        if c==2 or z==2: break
    return 'otro'
N=200000
e=sum(combat2()=='eliminado' for _ in range(N))/N
print(f"exigiendo boca expuesta en el asalto anterior: eliminación en {e:.0%} de los combates")
