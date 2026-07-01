# Arnés de bots — Proyecto Prion

Simula N jugadores reales contra el backend **de verdad** (la misma puerta que usa el
cliente: login, update de posición, `detect_encounter`, `submit_decision`). Sirve para
validar concurrencia, motor de combate, crons y rendimiento **sin gastar humanos**.

No es código de juego: es herramienta de pruebas. Se queda en el repo como arnés de
regresión y de carga. Para preguntar "¿aguanta 1.000 jugadores?", sube `BOT_COUNT`.

## Requisitos
- Node 18 o superior.
- `npm i @supabase/supabase-js` (en la raíz del repo ya lo tienes como dependencia).
- Las credenciales de las cuentas tester.

## Preparación
1. Copia la plantilla y rellena con las credenciales reales (este archivo NO se sube):
   ```
   cp tools/bots/testers.example.json tools/bots/testers.local.json
   ```
   Edita `testers.local.json` con los 20 email/contraseña.

2. Asegúrate de que `testers.local.json` está en `.gitignore` (ya añadido).

3. Exporta la URL y la anon key (las mismas PUBLIC_ que ya usas en el front):
   ```
   export SUPABASE_URL="https://TU-PROYECTO.supabase.co"
   export SUPABASE_ANON_KEY="TU_ANON_KEY"
   ```

4. Asegúrate de que hay una `game_session` en estado `setup` o `active` con la zona
   dibujada (si no, `get_playable_zone` devuelve vacío y los bots no arrancan).

## Ejecutar
```
node tools/bots/run-bots.mjs
```

## Parámetros (variables de entorno, opcionales)
| Variable            | Defecto | Qué hace                                                        |
|---------------------|---------|-----------------------------------------------------------------|
| `BOT_COUNT`         | 20      | Nº de bots (≤ nº de credenciales).                              |
| `TICK_MS`           | 10000   | Cadencia de cada bot (igual que el cliente real).              |
| `WALK_SPEED_MPS`    | 1.3     | Velocidad de caminata humana, en m/s.                           |
| `TURN_JITTER_DEG`   | 18      | Variación de rumbo (grados) en cada tick, para un andar natural.|
| `BIG_TURN_PROB`     | 0.15    | Probabilidad de "girar en una esquina" en vez de seguir recto.  |
| `BIG_TURN_DEG`      | 80      | Magnitud del giro de esquina, en grados.                        |
| `DECISION_DELAY_MS` | 3000    | Retardo de "reacción humana" antes de decidir (dentro de 15s). |
| `SILENT_PROB`       | 0.10    | Probabilidad de NO contestar → ejercita el cron de timeout.    |
| `RUN_SECONDS`       | 0       | Duración. 0 = infinito hasta Ctrl-C.                           |

Ejemplo de prueba de carga corta con 50 bots durante 3 minutos:
```
BOT_COUNT=50 RUN_SECONDS=180 node tools/bots/run-bots.mjs
```

## Qué mirar mientras corre
- El resumen cada 15s: `decisiones`, `encuentros`, `errores`.
- En Supabase: filas en `encounters` resolviéndose, `events` poblándose, vidas y
  conversiones cambiando, `apply_timeouts` rellenando los silencios.
- Cualquier `error` en consola es un fallo real del camino cliente→backend que un
  humano también habría sufrido. Eso es justo lo que buscamos cazar aquí.
