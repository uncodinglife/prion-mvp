<script lang="ts">
	import { onMount } from 'svelte';

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

	// Aviso sensorial al montar: solo dispara una vez, cuando aparece un encuentro nuevo
	// (el componente no se remonta al pasar a la pantalla de resultado, solo cambia `resolved`).
	onMount(() => {
		if (typeof navigator !== 'undefined' && 'vibrate' in navigator) {
			navigator.vibrate([200, 100, 200, 100, 400]);
		}
	});

	// Acciones según rol
	const actions =
		myRole === 'civil'
			? [
					{
						key: 'LUCHAR',
						label: 'LUCHAR',
						subtitle: 'Te enfrentas. Arriesgado pero puede sorprender.',
						kind: 'aggressive'
					},
					{
						key: 'HUIR',
						label: 'HUIR',
						subtitle: 'Escapas. Más seguro, pero no siempre gratis.',
						kind: 'evasive'
					}
				]
			: [
					{
						key: 'PERSEGUIR',
						label: 'PERSEGUIR',
						subtitle: 'Te lanzas a por la presa. Letal si huye.',
						kind: 'aggressive'
					},
					{
						key: 'MORDER',
						label: 'MORDER',
						subtitle: 'Atacas de cerca. Mejor si plantan cara.',
						kind: 'evasive'
					}
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
					<button class="action {action.kind}" onclick={() => handleClick(action.key)}>
						<span class="action-label">{action.label}</span>
						<span class="action-subtitle">{action.subtitle}</span>
					</button>
				{/each}
			</div>
		{/if}
	</div>
</div>

<style>
	/*
   * Colores por bando vía las custom properties --theme-* definidas en el
   * .game-root de game/+page.svelte (heredan por el DOM pese al scoping de
   * Svelte). Los valores tras la coma son el fallback si se renderiza fuera
   * de ese contenedor.
   */
	.overlay {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.92);
		display: flex;
		align-items: center;
		justify-content: center;
		z-index: 1000;
		animation: overlay-flash 550ms ease-out;
	}

	/* Fogonazo del color del bando al aparecer, que se desvanece hasta el scrim oscuro. */
	@keyframes overlay-flash {
		0% {
			background: var(--theme-accent, #c0392b);
		}
		12% {
			background: var(--theme-accent, #c0392b);
		}
		100% {
			background: rgba(0, 0, 0, 0.92);
		}
	}

	.combat-box {
		background: #1a1a1a;
		border: 2px solid var(--theme-accent, #6b1414);
		border-radius: 12px;
		padding: 2rem;
		max-width: 420px;
		width: 90%;
		text-align: center;
		color: #eee;
		animation: combat-box-in 320ms cubic-bezier(0.34, 1.56, 0.64, 1);
	}

	@keyframes combat-box-in {
		0% {
			transform: scale(0.8);
			opacity: 0;
		}
		100% {
			transform: scale(1);
			opacity: 1;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.overlay,
		.combat-box {
			animation: none;
		}
	}

	.alert {
		font-size: 1.4rem;
		font-weight: bold;
		letter-spacing: 0.3em;
		color: var(--theme-accent, #c0392b);
		margin-bottom: 1rem;
	}

	.timer {
		font-size: 5rem;
		font-weight: bold;
		font-variant-numeric: tabular-nums;
		margin-bottom: 1.5rem;
		line-height: 1;
		text-shadow: 0 0 18px var(--theme-accent, #c0392b);
		transition: color 0.2s ease;
	}

	.timer.blinking {
		color: var(--theme-alert, #ff3b30);
		text-shadow: 0 0 24px var(--theme-alert, #ff3b30);
		animation: blink 0.6s steps(2, start) infinite;
	}

	@keyframes blink {
		0% {
			opacity: 1;
			transform: scale(1);
		}
		50% {
			opacity: 0.3;
			transform: scale(1.12);
		}
		100% {
			opacity: 1;
			transform: scale(1);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.timer.blinking {
			animation: none;
			opacity: 1;
			transform: none;
		}
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
