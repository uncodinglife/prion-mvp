// =====================================================================
// PROYECTO PRION - Sonidos sintetizados (Web Audio API, sin archivos)
// Dos efectos: alerta de encuentro y fin de partida.
// El navegador bloquea el audio hasta el primer gesto del usuario:
// llamar a unlockAudio() en el primer toque sobre la página.
// =====================================================================

let ctx: AudioContext | null = null;

function getCtx(): AudioContext | null {
  if (typeof window === 'undefined') return null;
  if (!ctx) {
    const AC = window.AudioContext || (window as any).webkitAudioContext;
    if (!AC) return null;
    ctx = new AC();
  }
  return ctx;
}

/** Despierta el contexto de audio. Llamar en el primer gesto del usuario. */
export function unlockAudio(): void {
  const c = getCtx();
  if (c && c.state === 'suspended') {
    c.resume();
  }
}

/** Un tono con envolvente suave para que no chasquee. */
function tone(
  freq: number,
  startOffset: number,
  duration: number,
  type: OscillatorType = 'sine',
  peak = 0.22
): void {
  const c = getCtx();
  if (!c) return;
  const osc = c.createOscillator();
  const gain = c.createGain();
  osc.type = type;
  osc.frequency.value = freq;
  osc.connect(gain);
  gain.connect(c.destination);
  const t = c.currentTime + startOffset;
  gain.gain.setValueAtTime(0.0001, t);
  gain.gain.exponentialRampToValueAtTime(peak, t + 0.02);
  gain.gain.exponentialRampToValueAtTime(0.0001, t + duration);
  osc.start(t);
  osc.stop(t + duration + 0.03);
}

/** Alerta de encuentro: dos pulsos agudos y secos. Tensión inmediata. */
/** Alerta de encuentro: bajo pulsante grave que aprieta. Tensión tipo Alien. */
export function playEncounter(): void {
  const c = getCtx();
  if (!c) return;
  if (c.state === 'suspended') c.resume();
  const pulses = 6;
  const step = 0.26; // separación entre latidos
  for (let i = 0; i < pulses; i++) {
    const freq = 110 + i * 4; // sube muy poco: la amenaza se acerca
    tone(freq, i * step, 0.16, 'sawtooth', 0.3);
  }
}

/** Fin de partida: descenso grave, una sirena que se apaga. */
export function playGameEnd(): void {
  const c = getCtx();
  if (!c) return;
  if (c.state === 'suspended') c.resume();
  tone(440, 0, 0.5, 'sawtooth', 0.2);
  tone(330, 0.45, 0.6, 'sawtooth', 0.2);
  tone(220, 0.95, 0.9, 'sawtooth', 0.22);
}

/** Entrada en zona: dos notas graves ascendentes. Territorio caliente. */
export function playZoneEnter(): void {
  const c = getCtx();
  if (!c) return;
  if (c.state === 'suspended') c.resume();
  tone(196, 0, 0.35, 'triangle', 0.2);
  tone(294, 0.3, 0.5, 'triangle', 0.2);
}