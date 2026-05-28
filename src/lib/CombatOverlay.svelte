<script lang="ts">
  interface Props {
    encounter: any;
    myRole: string;
    resolved: any;
    resultMessage: string;
    onDecision: (decision: string) => void;
    onClose: () => void;
  }

  let { encounter, myRole, resolved, resultMessage, onDecision, onClose }: Props = $props();

  // Tiempo restante calculado desde started_at + 15s
  let secondsLeft = $state(15);
  let decided = $state(false);
  let timerInterval: ReturnType<typeof setInterval> | null = null;

  // Acciones según rol
  const actions = myRole === 'civil'
    ? [
        { key: 'LUCHAR', label: 'LUCHAR', subtitle: 'Te enfrentas. Arriesgado pero puede sorprender.', kind: 'aggressive' },
        { key: 'HUIR', label: 'HUIR', subtitle: 'Escapas. Más seguro, pero no siempre gratis.', kind: 'evasive' }
      ]
    : [
        { key: 'PERSEGUIR', label: 'PERSEGUIR', subtitle: 'Te lanzas a por la presa. Letal si huye.', kind: 'aggressive' },
        { key: 'MORDER', label: 'MORDER', subtitle: 'Atacas de cerca. Mejor si plantan cara.', kind: 'evasive' }
      ];

  function computeSecondsLeft(): number {
    const start = new Date(encounter.started_at).getTime();
    const elapsed = (Date.now() - start) / 1000;
    return Math.max(0, Math.ceil(15 - elapsed));
  }

  function handleClick(decision: string) {
    if (decided || secondsLeft <= 0) return;
    decided = true;
    onDecision(decision);
  }

  $effect(() => {
    secondsLeft = computeSecondsLeft();
    timerInterval = setInterval(() => {
      secondsLeft = computeSecondsLeft();
      if (secondsLeft <= 0 && timerInterval) {
        clearInterval(timerInterval);
      }
    }, 250);

    return () => {
      if (timerInterval) clearInterval(timerInterval);
    };
  });
</script>

<div class="overlay">
  <div class="combat-box">
    <div class="alert">ENCUENTRO</div>

    <div class="timer" class:blinking={secondsLeft <= 5}>
      {secondsLeft}
    </div>

    {#if resolved}
      <div class="result">
        <p class="result-msg">{resultMessage}</p>
        <button class="close-btn" onclick={onClose}>Continuar</button>
      </div>
    {:else if decided}
      <p class="waiting">Decisión enviada. Esperando resolución...</p>
    {:else if secondsLeft <= 0}
      <p class="waiting">Tiempo agotado. Resolviendo...</p>
    {:else}
      <div class="buttons">
        {#each actions as action}
          <button
            class="action {action.kind}"
            onclick={() => handleClick(action.key)}
          >
            <span class="action-label">{action.label}</span>
            <span class="action-subtitle">{action.subtitle}</span>
          </button>
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.85);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
  }

  .combat-box {
    background: #1a1a1a;
    border: 2px solid #6b1414;
    border-radius: 12px;
    padding: 2rem;
    max-width: 420px;
    width: 90%;
    text-align: center;
    color: #eee;
  }

  .alert {
    font-size: 1.4rem;
    font-weight: bold;
    letter-spacing: 0.3em;
    color: #c0392b;
    margin-bottom: 1rem;
  }

  .timer {
    font-size: 3.5rem;
    font-weight: bold;
    font-variant-numeric: tabular-nums;
    margin-bottom: 1.5rem;
  }

  .timer.blinking {
    color: #e74c3c;
    animation: blink 1s steps(2, start) infinite;
  }

  @keyframes blink {
    50% { opacity: 0.2; }
  }

  .buttons {
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }

  .action {
    padding: 1rem;
    border: none;
    border-radius: 8px;
    cursor: pointer;
    color: white;
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
  }

  .action-label {
    font-size: 1.3rem;
    font-weight: bold;
    letter-spacing: 0.1em;
  }

  .action-subtitle {
    font-size: 0.8rem;
    opacity: 0.85;
    font-weight: normal;
  }

  .action.aggressive {
    background: #8b2222;
  }

  .action.aggressive:hover {
    background: #a52a2a;
  }

  .action.evasive {
    background: #1f4e6b;
  }

  .action.evasive:hover {
    background: #2a6489;
  }

  .waiting {
    font-size: 1.1rem;
    opacity: 0.9;
  }
  .result {
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
    align-items: center;
  }

  .result-msg {
    font-size: 1.2rem;
    line-height: 1.5;
    color: #eee;
  }

  .close-btn {
    padding: 0.8rem 2rem;
    border: 1px solid #888;
    border-radius: 8px;
    background: transparent;
    color: #eee;
    cursor: pointer;
    font-size: 1rem;
    letter-spacing: 0.05em;
  }

  .close-btn:hover {
    background: #333;
  }
</style>