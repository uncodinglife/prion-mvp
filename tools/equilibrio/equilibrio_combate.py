import numpy as np
from scipy.optimize import linprog
C=['Golpea','Bloquea','Huye']; Z=['Muerde','Persigue','Agarra']
# Valor de un asalto desde el lado civil (provisional):
# +1 / -1 asalto ganado/perdido; agarre = -1 y -0.3 por la posición;
# mordisco perdido = -1 y -0.5 por la infección; huida: acaba sin perder el asalto,
# con daño (medio -0.4, leve -0.1); dados 50/50, o 2/3 con ventaja.
def base():
    return np.array([
     [0.5*1+0.5*(-1.5), 1.0, -1.3],          # golpea
     [2/3*1+1/3*(-1.5), 0.0, -1.3],          # bloquea (ventaja civil en dados)
     [-0.4,            -1.0, -0.1]])         # huye
def solve(M):
    n,m=M.shape
    # civil maximiza v: max v s.t. sum_i x_i M[i,j] >= v
    c=np.zeros(n+1); c[-1]=-1
    A=np.hstack([-M.T, np.ones((m,1))]); b=np.zeros(m)
    Aeq=np.hstack([np.ones((1,n)),[[0]]]); beq=[1]
    r=linprog(c,A_ub=A,b_ub=b,A_eq=Aeq,b_eq=beq,bounds=[(0,1)]*n+[(None,None)])
    x=r.x[:n]; v=r.x[-1]
    c2=np.zeros(m+1); c2[-1]=1
    A2=np.hstack([M, -np.ones((n,1))]); 
    Aeq2=np.hstack([np.ones((1,m)),[[0]]])
    r2=linprog(c2,A_ub=A2,b_ub=np.zeros(n),A_eq=Aeq2,b_eq=[1],bounds=[(0,1)]*m+[(None,None)])
    y=r2.x[:m]
    return v,x,y
def show(name,M):
    v,x,y=solve(M)
    print(f"\n== {name}: valor del asalto para el civil {v:+.2f}")
    print("  civil :", ", ".join(f"{c} {p:.0%}" for c,p in zip(C,x)))
    print("  zombie:", ", ".join(f"{z} {p:.0%}" for z,p in zip(Z,y)))
show("Base (rasos)", base())
M=base(); M[1,2]=+0.3          # bloquear con ruido: el agarre falla, zombie aturdido (-0.2 por el ruido)
M[2,1]=-0.2                     # huir con spray: el zombie pierde el rastro
show("Civil con ruido y spray", M)
G=base(); G[0]=[2/3*2+1/3*(-1.5), 1.5, -1.3]   # disparar: dados a favor y eliminación posible
show("Militar con arma (sin ruido ni spray)", G)
Zm=base(); Zm[0,2]=-2.0; Zm[1,2]=-2.0           # agarre doble
Zm[1,1]=-1.0                                     # salto: persigue caza aunque bloquee
show("Zombie mutado (agarre doble + salto) contra raso", Zm)
B=Zm.copy(); B[1,2]=+0.3; B[2,1]=-0.2
show("Zombie mutado contra civil con ruido y spray", B)

print("\n\n######## Ajustes para que se usen las tres opciones de cada bando ########")
def v2():
    # 1) Agarrar solo gana posición, no el asalto entero: -0.8 (en vez de -1.3).
    # 2) Morder al que huye: el roce puede infectar (1/3): huye-muerde -0.4 - 0.5/3.
    # 3) Huir sin contacto (vs agarra) cuesta algo más (cansancio, el zombie te sigue oliendo): -0.3.
    return np.array([
     [0.5*1+0.5*(-1.5), 1.0, -0.8],
     [2/3*1+1/3*(-1.5), 0.0, -0.8],
     [-0.4-0.5/3,      -1.0, -0.3]])
show("Base ajustada (rasos)", v2())
M=v2(); M[1,2]=+0.3; M[2,1]=-0.2
show("Ajustada: civil con ruido y spray", M)
G=v2(); G[0]=[2/3*2+1/3*(-1.5), 1.5, -0.8]
show("Ajustada: militar con arma", G)
Zm=v2(); Zm[0,2]=-1.5; Zm[1,2]=-1.5; Zm[1,1]=-1.0
show("Ajustada: zombie mutado (agarre doble + salto) contra raso", Zm)
B=Zm.copy(); B[1,2]=+0.3; B[2,1]=-0.2
show("Ajustada: zombie mutado contra civil con ruido y spray", B)
B2=B.copy(); B2[0]=[2/3*2+1/3*(-1.5), 1.5, -1.5]
show("Ajustada: zombie mutado contra militar con arma, ruido y spray", B2)

print("\n\n######## Cambio de estructura: el golpe no toca la palma; la embestida gana al golpe ########")
def v3():
    return np.array([
     [0.5*1+0.5*(-1.5), -1.0,  1.0],    # golpea: dados / embestida le gana / el reflejo no salta
     [2/3*1+1/3*(-1.5),  0.0, -1.3],    # bloquea: para el mordisco / pasa de largo / brazo en su mano
     [-0.4-0.5/3,       -1.0, -0.3]])   # huye
show("v3 base (rasos)", v3())
M=v3(); M[1,2]=+0.3; M[2,1]=-0.2
show("v3: civil con ruido y spray", M)
G=v3(); G[0]=[2/3*2+1/3*(-1.5), -1.0, 1.5]
show("v3: militar con arma", G)
Zm=v3(); Zm[1,2]=-2.0; Zm[0,1]=-1.5; Zm[0,0]=0.5*1+0.5*(-2.0)
show("v3: zombie mutado (agarre doble, embestida más dura, mordisco más profundo) contra raso", Zm)
B=Zm.copy(); B[1,2]=+0.3; B[2,1]=-0.2
show("v3: zombie mutado contra civil con ruido y spray", B)
B2=B.copy(); B2[0]=[2/3*2+1/3*(-2.0), -1.5, 1.5]
show("v3: zombie mutado contra militar con arma, ruido y spray", B2)

print("\n\n######## v4: cuadro latino (cada opción gana a una, empata con una y pierde con una) ########")
Z[:]=['Muerde','Embiste','Agarra']
def v4():
    return np.array([
     #  Muerde                 Embiste   Agarra
     [0.5*1+0.5*(-1.5),       -1.0,      1.0 ],   # Golpea: dados / la embestida le gana / el golpe no toca la palma
     [1.0,                     0.0,     -1.3 ],   # Bloquea: para el mordisco / choque / brazo en su mano
     [-1.5,                    0.6,     -0.2 ]])  # Huye: le muerde al darse la vuelta / esquiva la embestida y escapa / escapa cansado
show("v4 base (rasos)", v4())
M=v4(); M[1,2]=+0.3                 # bloquear con ruido: el sobresalto abre la mano
show("v4: civil con ruido", M)
M2=M.copy(); M2[2,0]=-0.6           # huir con spray: pierde el rastro, el mordisco suele fallar
show("v4: civil con ruido y spray", M2)
G=v4(); G[0]=[2/3*2+1/3*(-1.5), -1.0, 1.5]
show("v4: militar con arma", G)
Zm=v4(); Zm[1,2]=-2.0               # agarre doble
Zm[0,1]=-1.5                        # embestida más dura
show("v4: zombie mutado (agarre doble, embestida dura) contra raso", Zm)
B=Zm.copy(); B[1,2]=+0.3; B[2,0]=-0.6
show("v4: zombie mutado contra civil con ruido y spray", B)
B2=B.copy(); B2[0]=[2/3*2+1/3*(-1.5), -1.5, 1.5]
show("v4: zombie mutado contra militar con arma, ruido y spray", B2)

print("\n\n######## v4 con mejoras civiles moderadas (convierten una derrota en empate, no en victoria) ########")
M=v4(); M[1,2]=-0.2; M[2,0]=-0.6
show("v4: civil con ruido y spray (moderados)", M)
B=v4(); B[1,2]=-2.0; B[0,1]=-1.5; B[1,2]=-0.2; B[2,0]=-0.6
show("v4: zombie mutado contra civil con ruido y spray (moderados)", B)
B2=B.copy(); B2[0]=[2/3*2+1/3*(-1.5), -1.5, 1.5]
show("v4: zombie mutado contra militar con arma, ruido y spray (moderados)", B2)

print("\n\n######## v5: cuadro latino que respeta los pares de Angel (huye-persigue, bloquea-agarra) ########")
Z[:]=['Muerde','Persigue','Agarra']
def v5():
    return np.array([
     #  Muerde                    Persigue  Agarra
     [1/3*1+2/3*(-1.5),           1.0,      0.0 ],   # Golpea: dados con ventaja zombie / sorpresa (v1) / el golpe aparta, el reflejo agarra ropa: nadie gana
     [1.0,                        0.0,     -1.3 ],   # Bloquea: para el mordisco / se tantean / brazo en su mano
     [-0.2,                      -1.0,      0.6 ]])  # Huye: roce, escapa / cazado / escapa (cansado)
show("v5 base (rasos)", v5())
M=v5(); M[1,2]=-0.2; M[2,1]=-0.3
show("v5: civil con ruido y spray (convierten derrota en empate)", M)
G=v5(); G[0]=[2/3*2+1/3*(-1.5), 1.5, 0.0]
show("v5: militar con arma (el disparo convierte el mordisco en su oportunidad)", G)
Zm=v5(); Zm[1,2]=-2.0; Zm[2,1]=-1.5
show("v5: zombie mutado (agarre doble, caza más dura) contra raso", Zm)
B=Zm.copy(); B[1,2]=-0.2; B[2,1]=-0.3
show("v5: zombie mutado contra civil con ruido y spray", B)
B2=B.copy(); B2[0]=[2/3*2+1/3*(-1.5), 1.5, 0.0]
show("v5: zombie mutado contra militar con arma, ruido y spray", B2)
