<script lang="ts">
  interface RadioEvent {
    id: string;
    type: string;
    message: string;
    created_at: string;
  }

  interface Props {
    events: RadioEvent[];
  }

  let { events }: Props = $props();

  let logContainer: HTMLDivElement;

  function formatTime(iso: string): string {
    return new Date(iso).toLocaleTimeString('es-ES');
  }

  // Autoscroll al fondo cuando cambian los eventos
  $effect(() => {
    // Referencia a events para que el efecto se dispare cuando cambian
    events.length;
    if (logContainer) {
      logContainer.scrollTop = logContainer.scrollHeight;
    }
  });
</script>

<div class="radio-log">
  <div class="radio-header">RADIORECEPTORA</div>
  <div class="radio-log">
    {#if events.length === 0}
      <p class="radio-empty">Sin transmisiones. Silencio en la frecuencia.</p>
    {:else}
      {#each events as ev (ev.id)}
        <div class="radio-line">
          <span class="radio-time">{formatTime(ev.created_at)}</span>
          <span class="radio-msg">{ev.message}</span>
        </div>
      {/each}
    {/if}
  </div>
</div>

<style>
  .radio {
    border: 1px solid #2d4a2d;
    border-radius: 8px;
    background: #0d140d;
    margin-top: 1rem;
    overflow: hidden;
  }

  .radio-header {
    background: #1a2e1a;
    color: #6fcf6f;
    font-family: monospace;
    font-size: 0.8rem;
    letter-spacing: 0.2em;
    padding: 0.5rem 0.8rem;
    border-bottom: 1px solid #2d4a2d;
  }

  .radio-log {
    max-height: 200px;
    overflow-y: auto;
    padding: 0.5rem 0.8rem;
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
    background: #0a1f12;
  }

  .radio-empty {
    color: #4a6a4a;
    font-family: monospace;
    font-size: 0.85rem;
    font-style: italic;
    margin: 0;
  }

  .radio-line {
    font-family: monospace;
    font-size: 0.85rem;
    line-height: 1.4;
    color: #a8d8a8;
    display: flex;
    gap: 0.6rem;
  }

  .radio-time {
    color: #5a8a5a;
    flex-shrink: 0;
  }

  .radio-msg {
    color: #c8e8c8;
  }
</style>