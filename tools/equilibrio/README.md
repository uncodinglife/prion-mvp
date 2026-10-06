# Cálculos de equilibrio del combate v2

Scripts de apoyo al diseño (no se ejecutan en producción). Requieren `numpy` y `scipy`.

- `equilibrio_combate.py`: equilibrio de Nash de un asalto (programación lineal) para la tabla v5, con mejoras civiles y zombie mutado.
- `sim_eliminacion.py`: Monte Carlo del combate al mejor de 3; frecuencia de eliminación del zombie según la regla de boca expuesta.
- `q3.py`: comparación bloquea–muerde a dados frente a victoria civil directa.
- `rps.py`: pruebas iniciales de cuadro latino. `q3.py` lo importa con una ruta temporal antigua (`/tmp/claude-0/rps.py`); no funciona tal cual.
- `combate_v2_secuencial.py` (06/10/2026): combate completo de 3 asaltos como juego de suma cero con información oculta (tipo de civil), resuelto en forma secuencial por programación lineal. Reglas del 06/10: fuerza continua con k, factor de salud por asalto, eliminación solo con boca expuesta y disparo, el zombie ve el botón de golpear (y deduce el tipo). Usa los daños de la tabla aceptada el 04/10, no valores abstractos. Supuestos propios marcados `[SUP]` (valoración y subjuego de agarre). Incluye espiral de muerte y coste de cada comportamiento por defecto al agotarse el tiempo. `python3 combate_v2_secuencial.py` (unos segundos).

Supuesto revisado en `combate_v2_secuencial.py` (06/10/2026): los scripts anteriores asumen un zombie ciego al rango del civil durante todo el combate. Con el "pulso", la posición inicial de la frontera revela la fuerza del civil tras el asalto 1.

- `combate_v6.py` (06/10/2026, propuesta de diseño de Claude): tabla de combate como datos (`CELLS`, especificación de la futura tabla en la base) con todas las variables: equipamiento, salud, edad (fuerza/agilidad), cansancio del civil (el zombie no se cansa), experiencia (tope +10 %), sobreexcitación del zombie por el disparo, agarre, boca expuesta y arma atrapada por el reflejo de prensión. Casi todos los cruces físicos van a pulso. Valores ajustados por búsqueda contra objetivos explícitos (ninguna opción muerta, infección, huida, duración, desgaste). `python3 combate_v6.py` imprime el informe completo (~1 min).
