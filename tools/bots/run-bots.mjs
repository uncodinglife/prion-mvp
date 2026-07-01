/**
 * Proyecto Prion — Arnés de bots para prueba de carga y validación de backend.
 *
 * Replica EXACTAMENTE lo que hace el cliente real (src/routes/game/+page.svelte):
 *   1. Login email/password (supabase.auth.signInWithPassword).
 *   2. UPDATE de players.position (WKT POINT) + position_updated_at.
 *   3. Invoca la Edge Function detect_encounter (sin parámetros).
 *   4. Sondea su propia fila players.current_encounter_id.
 *   5. Si hay encuentro sin resolver, invoca submit_decision { encounter_id, decision }.
 *
 * NO es código de juego. Es herramienta de pruebas: se queda en el repo como
 * arnés de regresión y de carga. Sube BOT_COUNT para responder "¿aguanta N jugadores?".
 *
 * Ejecutar:  node tools/bots/run-bots.mjs
 * Requiere:  Node 18+, npm i @supabase/supabase-js, y tools/bots/testers.local.json
 */

import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ── Configuración (todo por variables de entorno, con valores por defecto) ──
const SUPABASE_URL = process.env.SUPABASE_URL || process.env.PUBLIC_SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || process.env.PUBLIC_SUPABASE_ANON_KEY;
const BOT_COUNT = parseInt(process.env.BOT_COUNT || '20', 10);
const TICK_MS = parseInt(process.env.TICK_MS || '10000', 10);   // igual que el cliente real
const WALK_SPEED_MPS = parseFloat(process.env.WALK_SPEED_MPS || '1.3'); // ritmo humano ~1,3 m/s
const TURN_JITTER_DEG = parseFloat(process.env.TURN_JITTER_DEG || '18'); // giro suave por tick
const BIG_TURN_PROB = parseFloat(process.env.BIG_TURN_PROB || '0.15');   // prob. de girar en "esquina"
const BIG_TURN_DEG = parseFloat(process.env.BIG_TURN_DEG || '80');       // magnitud del giro de esquina
const DECISION_DELAY_MS = parseInt(process.env.DECISION_DELAY_MS || '3000', 10); // "reacción humana"
const SILENT_PROB = parseFloat(process.env.SILENT_PROB || '0.10'); // % de bots que NO contestan (prueba el cron de timeout)
const RUN_SECONDS = parseInt(process.env.RUN_SECONDS || '0', 10); // 0 = infinito hasta Ctrl-C

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error('Falta SUPABASE_URL o SUPABASE_ANON_KEY en el entorno. Aborta.');
  process.exit(1);
}

// Credenciales locales (NUNCA en el repo). Plantilla: testers.example.json
let TESTERS;
try {
  TESTERS = JSON.parse(readFileSync(join(__dirname, 'testers.local.json'), 'utf8'));
} catch (e) {
  console.error('No encuentro tools/bots/testers.local.json. Copia testers.example.json y rellénalo.');
  process.exit(1);
}

const VALID = { civil: ['HUIR', 'LUCHAR'], zombie: ['MORDER', 'PERSEGUIR'] };
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Contadores globales para el resumen
const stats = { ticks: 0, positions: 0, detects: 0, decisions: 0, silences: 0, errors: 0, encountersSeen: new Set() };

// ── Geometría: parseo de zona y point-in-polygon (copiados del cliente) ──
function ringToLatLng(geojson) {
  // get_playable_zone devuelve GeoJSON; coordinates[0] es el anillo exterior [lng,lat]
  if (!geojson || !geojson.coordinates || !geojson.coordinates[0]) return [];
  return geojson.coordinates[0].map(([lng, lat]) => [lat, lng]);
}
function isInside(lat, lng, poly) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [yi, xi] = poly[i];
    const [yj, xj] = poly[j];
    const intersect = ((yi > lat) !== (yj > lat)) && (lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}
function bbox(poly) {
  let minLat = Infinity, maxLat = -Infinity, minLng = Infinity, maxLng = -Infinity;
  for (const [lat, lng] of poly) {
    if (lat < minLat) minLat = lat; if (lat > maxLat) maxLat = lat;
    if (lng < minLng) minLng = lng; if (lng > maxLng) maxLng = lng;
  }
  return { minLat, maxLat, minLng, maxLng };
}
function randomPointInZone(poly, box) {
  for (let i = 0; i < 200; i++) {
    const lat = box.minLat + Math.random() * (box.maxLat - box.minLat);
    const lng = box.minLng + Math.random() * (box.maxLng - box.minLng);
    if (isInside(lat, lng, poly)) return { lat, lng };
  }
  // fallback: centro del bbox
  return { lat: (box.minLat + box.maxLat) / 2, lng: (box.minLng + box.maxLng) / 2 };
}
// giro aleatorio suave (aprox. gaussiano) en grados
function jitterDeg(scale) {
  return (Math.random() + Math.random() + Math.random() - 1.5) * scale;
}
// Caminar correlacionado: mantiene el rumbo, gira poco, y "gira la esquina" a veces.
// Avanza la distancia de un humano por tick. Al chocar con el borde, gira y reintenta
// (rebota hacia dentro) en vez de teletransportarse.
function walk(lat, lng, heading, poly, box) {
  const dist = WALK_SPEED_MPS * (TICK_MS / 1000); // metros recorridos este tick
  let h = heading + jitterDeg(TURN_JITTER_DEG);
  if (Math.random() < BIG_TURN_PROB) {
    h += (Math.random() < 0.5 ? -1 : 1) * BIG_TURN_DEG * (0.5 + Math.random());
  }
  for (let i = 0; i < 8; i++) {
    const rad = (h * Math.PI) / 180;
    const dLat = (dist * Math.cos(rad)) / 111111;
    const dLng = (dist * Math.sin(rad)) / (111111 * Math.cos((lat * Math.PI) / 180));
    const nLat = lat + dLat, nLng = lng + dLng;
    if (isInside(nLat, nLng, poly)) return { lat: nLat, lng: nLng, heading: ((h % 360) + 360) % 360 };
    h += 120 + Math.random() * 120; // borde: gira bastante y reintenta
  }
  const p = randomPointInZone(poly, box); // atascado en una esquina: recoloca con rumbo nuevo
  return { lat: p.lat, lng: p.lng, heading: Math.random() * 360 };
}

// ── Un bot ──
async function runBot(cred, idx, poly, box, stopAt) {
  const tag = `[bot${String(idx).padStart(2, '0')} ${cred.email.split('@')[0]}]`;
  const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: true },
  });

  const { data: auth, error: authErr } = await sb.auth.signInWithPassword({
    email: cred.email, password: cred.password,
  });
  if (authErr || !auth?.user) {
    console.error(`${tag} login FALLÓ: ${authErr?.message}`);
    stats.errors++;
    return;
  }
  const uid = auth.user.id;
  let { lat, lng } = randomPointInZone(poly, box);
  let heading = Math.random() * 360; // rumbo inicial
  let decidedFor = null; // encounter_id ya respondido, para no decidir dos veces

  console.log(`${tag} dentro. uid=${uid.slice(0, 8)} en ${lat.toFixed(5)},${lng.toFixed(5)}`);

  while (!stopAt || Date.now() < stopAt) {
    try {
      // 1) mover (caminar humano: mantiene rumbo, gira en esquinas, rebota en el borde)
      ({ lat, lng, heading } = walk(lat, lng, heading, poly, box));
      // 2) enviar posición (idéntico al cliente: update directo a players)
      const { error: upErr } = await sb.from('players')
        .update({ position: `POINT(${lng} ${lat})`, position_updated_at: new Date().toISOString() })
        .eq('id', uid);
      if (upErr) { stats.errors++; console.error(`${tag} update pos: ${upErr.message}`); }
      else stats.positions++;

      // 3) detectar
      const { error: detErr } = await sb.functions.invoke('detect_encounter');
      if (detErr) { stats.errors++; console.error(`${tag} detect: ${detErr.message}`); }
      else stats.detects++;

      // 4) ¿estoy en un encuentro sin resolver?
      const { data: me, error: meErr } = await sb.from('players')
        .select('role, current_encounter_id').eq('id', uid).single();
      if (meErr || !me) { stats.errors++; }
      else if (me.current_encounter_id && me.current_encounter_id !== decidedFor) {
        const { data: enc } = await sb.from('encounters')
          .select('id, result').eq('id', me.current_encounter_id).single();
        if (enc && enc.result === null) {
          stats.encountersSeen.add(enc.id);
          // 5) decidir (o callar, para ejercitar el cron de timeout)
          if (Math.random() < SILENT_PROB) {
            stats.silences++;
            decidedFor = enc.id; // no vuelvo a tocar este encuentro
            console.log(`${tag} ENCUENTRO ${enc.id.slice(0,8)} → SILENCIO (prueba timeout)`);
          } else {
            await sleep(DECISION_DELAY_MS); // reacción humana dentro de los 15s
            const decision = pick(VALID[me.role] || VALID.civil);
            const { error: decErr } = await sb.functions.invoke('submit_decision', {
              body: { encounter_id: enc.id, decision },
            });
            decidedFor = enc.id;
            if (decErr) { stats.errors++; console.error(`${tag} decision: ${decErr.message}`); }
            else { stats.decisions++; console.log(`${tag} ENCUENTRO ${enc.id.slice(0,8)} → ${me.role}:${decision}`); }
          }
        }
      } else if (!me.current_encounter_id) {
        decidedFor = null; // libre de nuevo, listo para el próximo encuentro
      }
    } catch (e) {
      stats.errors++; console.error(`${tag} excepción: ${e.message}`);
    }
    stats.ticks++;
    await sleep(TICK_MS + Math.floor(Math.random() * 1500)); // jitter para no sincronizar a los bots
  }
  await sb.auth.signOut();
  console.log(`${tag} fin.`);
}

// ── Orquestación ──
async function main() {
  console.log(`Prion bots → ${SUPABASE_URL}`);
  console.log(`BOT_COUNT=${BOT_COUNT} TICK_MS=${TICK_MS} SPEED=${WALK_SPEED_MPS}m/s SILENT=${SILENT_PROB} RUN=${RUN_SECONDS || '∞'}s`);

  if (TESTERS.length < BOT_COUNT) {
    console.error(`Solo hay ${TESTERS.length} credenciales pero pides ${BOT_COUNT} bots.`);
    process.exit(1);
  }

  // Cargar la zona una vez con el primer tester (la zona es global)
  const probe = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  await probe.auth.signInWithPassword({ email: TESTERS[0].email, password: TESTERS[0].password });
  const { data: zone, error: zoneErr } = await probe.rpc('get_playable_zone');
  await probe.auth.signOut();
  if (zoneErr || !zone) { console.error(`No pude cargar la zona: ${zoneErr?.message}`); process.exit(1); }
  const poly = ringToLatLng(zone);
  if (poly.length < 3) { console.error('Polígono de zona vacío o inválido.'); process.exit(1); }
  const box = bbox(poly);
  console.log(`Zona cargada: ${poly.length} vértices. bbox lat[${box.minLat.toFixed(4)},${box.maxLat.toFixed(4)}] lng[${box.minLng.toFixed(4)},${box.maxLng.toFixed(4)}]`);

  const stopAt = RUN_SECONDS > 0 ? Date.now() + RUN_SECONDS * 1000 : null;

  // Resumen periódico
  const summary = setInterval(() => {
    console.log(`── resumen: ticks=${stats.ticks} pos=${stats.positions} detect=${stats.detects} decisiones=${stats.decisions} silencios=${stats.silences} encuentros=${stats.encountersSeen.size} errores=${stats.errors}`);
  }, 15000);

  const bots = TESTERS.slice(0, BOT_COUNT).map((c, i) => runBot(c, i + 1, poly, box, stopAt));
  await Promise.all(bots);

  clearInterval(summary);
  console.log(`\n==== FIN ====`);
  console.log(`ticks=${stats.ticks} posiciones=${stats.positions} detecciones=${stats.detects}`);
  console.log(`decisiones=${stats.decisions} silencios=${stats.silences} encuentros_únicos=${stats.encountersSeen.size} errores=${stats.errors}`);
}

process.on('SIGINT', () => { console.log('\nCtrl-C → cerrando bots…'); process.exit(0); });
main().catch((e) => { console.error('Fatal:', e); process.exit(1); });
