# Cálculos de equilibrio del combate v2

Scripts de apoyo al diseño (no se ejecutan en producción). Requieren `numpy` y `scipy`.

- `equilibrio_combate.py`: equilibrio de Nash de un asalto (programación lineal) para la tabla v5, con mejoras civiles y zombie mutado.
- `sim_eliminacion.py`: Monte Carlo del combate al mejor de 3; frecuencia de eliminación del zombie según la regla de boca expuesta.
- `q3.py`: comparación bloquea–muerde a dados frente a victoria civil directa.
- `rps.py` (si está): pruebas iniciales de cuadro latino.

Supuesto a revisar (06/10/2026): todos asumen un zombie ciego al rango del civil durante todo el combate. Con el "pulso", la posición inicial de la frontera revela la fuerza del civil tras el asalto 1.
