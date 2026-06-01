<script lang="ts">
  let { report } = $props();

  // report = { available, global, individual }
  const global = report?.global ?? {};
  const individual = report?.individual ?? {};

  const civilsWin = global.winning_side === 'civils';

  const resultLabels: Record<string, string> = {
    civil_escaped: 'Civiles que escaparon',
    civil_caught: 'Civiles cazados',
    civil_wins_fight: 'Victorias del civil en lucha',
    zombie_wins_fight: 'Victorias del zombie en lucha'
  };

  const decisionLabels: Record<string, string> = {
    HUIR: 'Huir',
    LUCHAR: 'Luchar',
    MORDER: 'Morder',
    PERSEGUIR: 'Perseguir'
  };

  function entries(obj: Record<string, number> | undefined): [string, number][] {
    if (!obj) return [];
    return Object.entries(obj);
  }

  function label(map: Record<string, string>, key: string): string {
    return map[key] ?? key;
  }
</script>

<div class="final-overlay">
  <div class="final-panel">
    <header class="banner" class:civils={civilsWin} class:zombies={!civilsWin}>
      {#if !report?.available}
        <h1>Calculando el desenlace…</h1>
      {:else if civilsWin}
        <h1>LA CIUDAD RESISTE</h1>
        <p>Los supervivientes han aguantado hasta el amanecer.</p>
      {:else}
        <h1>LA CIUDAD HA CAÍDO</h1>
        <p>La horda lo ha consumido todo. No queda nadie a quien salvar.</p>
      {/if}
    </header>

    {#if report?.available}
      <section>
        <h2>Balance global</h2>
        <div class="grid">
          <div class="stat"><span class="num">{global.civils_alive ?? 0}</span><span class="lbl">Civiles vivos</span></div>
          <div class="stat"><span class="num">{global.zombies_count ?? 0}</span><span class="lbl">Zombies</span></div>
          <div class="stat"><span class="num">{global.encounters_total ?? 0}</span><span class="lbl">Encuentros</span></div>
          <div class="stat"><span class="num">{global.conversions_total ?? 0}</span><span class="lbl">Conversiones</span></div>
          <div class="stat"><span class="num">{global.neutralizations_total ?? 0}</span><span class="lbl">Neutralizaciones</span></div>
          <div class="stat"><span class="num">{global.timeout_resolved ?? 0}</span><span class="lbl">Por tiempo agotado</span></div>
        </div>

        <h3>Resultados de los encuentros</h3>
        <ul class="breakdown">
          {#each entries(global.result_breakdown) as [k, n]}
            <li><span>{label(resultLabels, k)}</span><span class="dot"></span><strong>{n}</strong></li>
          {/each}
        </ul>

        <div class="two-col">
          <div>
            <h3>Decisiones de los civiles</h3>
            <ul class="breakdown">
              {#each entries(global.civil_decisions) as [k, n]}
                <li><span>{label(decisionLabels, k)}</span><span class="dot"></span><strong>{n}</strong></li>
              {/each}
            </ul>
          </div>
          <div>
            <h3>Decisiones de los zombies</h3>
            <ul class="breakdown">
              {#each entries(global.zombie_decisions) as [k, n]}
                <li><span>{label(decisionLabels, k)}</span><span class="dot"></span><strong>{n}</strong></li>
              {/each}
            </ul>
          </div>
        </div>
      </section>

      <section>
        <h2>Tu partida</h2>
        <div class="grid">
          <div class="stat"><span class="num">{individual.encounters_total ?? 0}</span><span class="lbl">Tus encuentros</span></div>
          <div class="stat"><span class="num">{individual.neutralizations_caused ?? 0}</span><span class="lbl">Zombies que tumbaste</span></div>
          <div class="stat"><span class="num">{individual.conversions_caused ?? 0}</span><span class="lbl">Civiles que convertiste</span></div>
          <div class="stat"><span class="num">{individual.times_neutralized ?? 0}</span><span class="lbl">Veces neutralizado</span></div>
          <div class="stat"><span class="num">{individual.times_converted ?? 0}</span><span class="lbl">Veces convertido</span></div>
        </div>

        {#if entries(individual.as_civil_decisions).length > 0}
          <h3>Tus decisiones como civil</h3>
          <ul class="breakdown">
            {#each entries(individual.as_civil_decisions) as [k, n]}
              <li><span>{label(decisionLabels, k)}</span><span class="dot"></span><strong>{n}</strong></li>
            {/each}
          </ul>
        {/if}

        {#if entries(individual.as_zombie_decisions).length > 0}
          <h3>Tus decisiones como zombie</h3>
          <ul class="breakdown">
            {#each entries(individual.as_zombie_decisions) as [k, n]}
              <li><span>{label(decisionLabels, k)}</span><span class="dot"></span><strong>{n}</strong></li>
            {/each}
          </ul>
        {/if}
      </section>
    {/if}

    <footer>
      <p class="credit">Equipo cero — Sant Feliu, octubre 2026</p>
      <a href="/" class="back">Salir</a>
    </footer>
  </div>
</div>

<style>
  .final-overlay {
    position: fixed;
    inset: 0;
    z-index: 2000;
    background: rgba(6, 10, 8, 0.96);
    overflow-y: auto;
    display: flex;
    justify-content: center;
    align-items: flex-start;
    padding: 1.5rem 1rem 3rem;
    font-family: 'Courier New', ui-monospace, monospace;
    color: #c9f7d0;
  }

  .final-panel {
    width: 100%;
    max-width: 560px;
  }

  .banner {
    text-align: center;
    border: 1px solid;
    border-radius: 8px;
    padding: 1.6rem 1rem;
    margin-bottom: 1.4rem;
  }

  .banner.civils {
    border-color: #2f9e44;
    background: rgba(47, 158, 68, 0.12);
    box-shadow: 0 0 24px rgba(47, 158, 68, 0.25) inset;
  }

  .banner.zombies {
    border-color: #c0392b;
    background: rgba(192, 57, 43, 0.12);
    box-shadow: 0 0 24px rgba(192, 57, 43, 0.25) inset;
    color: #f3c6c0;
  }

  .banner h1 {
    margin: 0 0 0.4rem;
    font-size: 1.7rem;
    letter-spacing: 0.12em;
  }

  .banner p {
    margin: 0;
    opacity: 0.85;
    font-size: 0.95rem;
  }

  section {
    margin-bottom: 1.6rem;
  }

  h2 {
    font-size: 1.05rem;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    border-bottom: 1px solid rgba(47, 158, 68, 0.4);
    padding-bottom: 0.35rem;
    margin: 0 0 0.9rem;
    color: #7ee59a;
  }

  h3 {
    font-size: 0.85rem;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    opacity: 0.75;
    margin: 1.1rem 0 0.5rem;
  }

  .grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 0.6rem;
  }

  .stat {
    border: 1px solid rgba(47, 158, 68, 0.25);
    border-radius: 6px;
    padding: 0.7rem 0.4rem;
    text-align: center;
    background: rgba(20, 30, 24, 0.6);
  }

  .stat .num {
    display: block;
    font-size: 1.6rem;
    font-weight: bold;
    color: #8effa6;
    line-height: 1.1;
  }

  .stat .lbl {
    display: block;
    font-size: 0.7rem;
    opacity: 0.7;
    margin-top: 0.25rem;
  }

  .breakdown {
    list-style: none;
    padding: 0;
    margin: 0;
  }

  .breakdown li {
    display: flex;
    align-items: baseline;
    gap: 0.5rem;
    padding: 0.25rem 0;
    font-size: 0.9rem;
  }

  .breakdown .dot {
    flex: 1;
    border-bottom: 1px dotted rgba(201, 247, 208, 0.3);
    transform: translateY(-3px);
  }

  .breakdown strong {
    color: #8effa6;
  }

  .two-col {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1rem;
  }

  footer {
    text-align: center;
    margin-top: 2rem;
    border-top: 1px solid rgba(47, 158, 68, 0.3);
    padding-top: 1.2rem;
  }

  .credit {
    font-size: 0.78rem;
    opacity: 0.6;
    margin: 0 0 1rem;
  }

  .back {
    display: inline-block;
    color: #c9f7d0;
    text-decoration: none;
    border: 1px solid #2f9e44;
    border-radius: 6px;
    padding: 0.55rem 1.6rem;
    letter-spacing: 0.1em;
  }

  .back:hover {
    background: rgba(47, 158, 68, 0.2);
  }

  @media (max-width: 420px) {
    .grid { grid-template-columns: repeat(2, 1fr); }
    .two-col { grid-template-columns: 1fr; }
    .banner h1 { font-size: 1.35rem; }
  }
</style>