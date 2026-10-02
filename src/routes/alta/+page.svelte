<script lang="ts">
	import { onMount, onDestroy, tick } from 'svelte';
	import { goto } from '$app/navigation';
	import { supabase } from '$lib/supabase';
	import { fetchMe, PROFILE_FIELDS } from '$lib/v2';

	interface Option {
		field: string;
		value: string;
		label: string;
	}

	let loading = $state(true);
	let options = $state<Record<string, Option[]>>({});
	let nick = $state('');
	let age = $state<number | null>(null);
	let traits = $state<Record<string, string>>({});
	let home = $state<{ lat: number; lng: number } | null>(null);
	let consent = $state(false);
	let submitting = $state(false);
	let errorMessage = $state<string | null>(null);
	let locating = $state(false);
	let registered = $state(false);

	let mapContainer = $state<HTMLDivElement>();
	let map: any = null;
	let marker: any = null;
	let L: any = null;

	const ageBand = $derived(
		age === null
			? null
			: age < 15 || age > 90
				? null
				: age <= 35
					? 'joven'
					: age <= 55
						? 'medio'
						: 'viejo'
	);
	const BAND_TEXT: Record<string, string> = {
		joven: 'Tramo joven: 100 de vida, 1,5 raciones al día.',
		medio: 'Tramo medio: 90 de vida, 1 ración al día.',
		viejo: 'Tramo mayor: 80 de vida, 0,75 raciones al día.'
	};

	const complete = $derived(
		nick.trim().length >= 3 &&
			ageBand !== null &&
			PROFILE_FIELDS.every((f) => !!traits[f.field]) &&
			home !== null &&
			consent
	);

	function placeHome(lat: number, lng: number) {
		home = { lat, lng };
		if (marker) {
			marker.setLatLng([lat, lng]);
		} else {
			marker = L.circleMarker([lat, lng], {
				radius: 9,
				color: '#1d2b3a',
				weight: 2,
				fillColor: '#a3242b',
				fillOpacity: 0.9
			}).addTo(map);
		}
	}

	function useMyLocation() {
		if (!('geolocation' in navigator)) {
			errorMessage = 'Este navegador no da la ubicación. Marca tu casa tocando el mapa.';
			return;
		}
		locating = true;
		navigator.geolocation.getCurrentPosition(
			(pos) => {
				locating = false;
				placeHome(pos.coords.latitude, pos.coords.longitude);
				map.setView([pos.coords.latitude, pos.coords.longitude], 18);
			},
			() => {
				locating = false;
				errorMessage = 'No se pudo obtener tu ubicación. Marca tu casa tocando el mapa.';
			},
			{ enableHighAccuracy: true, timeout: 15000 }
		);
	}

	async function submit(event: Event) {
		event.preventDefault();
		if (!complete || !home || age === null) return;
		submitting = true;
		errorMessage = null;
		const { error } = await supabase.rpc('create_character', {
			p_nick: nick.trim(),
			p_age: age,
			p_sex: traits.sex,
			p_eye_color: traits.eye_color,
			p_hair_color: traits.hair_color,
			p_height_band: traits.height_band,
			p_profession: traits.profession,
			p_hobby: traits.hobby,
			p_home_lat: home.lat,
			p_home_lng: home.lng
		});
		submitting = false;
		if (error) {
			errorMessage = error.message;
			return;
		}
		// El punto exacto ya no hace falta: el servidor solo ha guardado la zona.
		home = null;
		registered = true;
	}

	onMount(async () => {
		const me = await fetchMe();
		if (!me) {
			goto('/login');
			return;
		}
		if (me.age_band) {
			goto('/game');
			return;
		}

		const { data } = await supabase.from('profile_options').select('field, value, label');
		const grouped: Record<string, Option[]> = {};
		for (const o of (data ?? []) as Option[]) {
			(grouped[o.field] ??= []).push(o);
		}
		options = grouped;
		loading = false;

		L = (await import('leaflet')).default;
		await import('leaflet/dist/leaflet.css');
		// Esperar a que el contenedor del mapa exista tras quitar el estado de carga.
		await tick();
		map = L.map(mapContainer, { zoomControl: true }).setView([41.7811, 3.029], 15);
		L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
			attribution: '© OpenStreetMap',
			maxZoom: 19
		}).addTo(map);
		map.on('click', (e: any) => placeHome(e.latlng.lat, e.latlng.lng));
	});

	onDestroy(() => {
		map?.remove();
	});
</script>

<svelte:head>
	<title>Censo sanitario-militar · Prion</title>
	<link rel="preconnect" href="https://fonts.googleapis.com" />
	<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin="anonymous" />
	<link
		href="https://fonts.googleapis.com/css2?family=Archivo+Narrow:wght@400;600;700&family=Courier+Prime:wght@400;700&display=swap"
		rel="stylesheet"
	/>
</svelte:head>

<main class="sheet">
	<header class="sheet-head">
		<p class="issuer">Mando conjunto · Autoridad sanitaria</p>
		<h1>Censo de población no afectada</h1>
		<p class="form-id">Formulario C-1. Inscripción obligatoria.</p>
		<p class="lead">
			Rellena tu ficha. Una vez entregada no se puede modificar. Los datos de la ficha son de tu
			personaje, no tuyos.
		</p>
	</header>

	{#if loading}
		<p class="note">Cargando el formulario…</p>
	{:else if registered}
		<section class="done" aria-live="polite">
			<div class="stamp" aria-hidden="true">Inscrito</div>
			<p class="done-text">
				Ficha de <strong>{nick.trim()}</strong> registrada. Empiezas como civil, con
				{ageBand === 'joven' ? 100 : ageBand === 'medio' ? 90 : 80} de vida y 20 raciones.
			</p>
			<a class="primary" href="/game">Entrar en la zona</a>
		</section>
	{:else}
		<form onsubmit={submit} novalidate>
			<fieldset>
				<legend><span class="num">1</span>Identificación</legend>
				<label class="row">
					<span class="lbl">Nombre en el censo</span>
					<input
						class="typed"
						type="text"
						bind:value={nick}
						maxlength="20"
						autocomplete="off"
						spellcheck="false"
						placeholder="3 a 20 caracteres"
					/>
				</label>
				<label class="row">
					<span class="lbl">Edad</span>
					<input
						class="typed short"
						type="number"
						min="15"
						max="90"
						inputmode="numeric"
						bind:value={age}
						placeholder="15–90"
					/>
				</label>
				{#if ageBand}
					<p class="hint">{BAND_TEXT[ageBand]}</p>
				{:else if age !== null}
					<p class="hint warn">La edad tiene que estar entre 15 y 90.</p>
				{/if}
			</fieldset>

			<fieldset>
				<legend><span class="num">2</span>Rasgos</legend>
				<p class="hint">Los brotes de infección eligen a sus víctimas por estos rasgos.</p>
				{#each PROFILE_FIELDS as f (f.field)}
					<label class="row">
						<span class="lbl">{f.label}</span>
						<select class="typed" bind:value={traits[f.field]}>
							<option value={undefined} disabled selected>Elegir</option>
							{#each options[f.field] ?? [] as o (o.value)}
								<option value={o.value}>{o.label}</option>
							{/each}
						</select>
					</label>
				{/each}
			</fieldset>

			<fieldset>
				<legend><span class="num">3</span>Domicilio</legend>
				<p class="hint">
					Tu casa es tu refugio: dentro nadie te ve y puedes descansar. Toca el mapa donde vives o
					usa tu ubicación.
				</p>
				<button type="button" class="secondary" onclick={useMyLocation} disabled={locating}>
					{locating ? 'Buscando tu ubicación…' : 'Usar mi ubicación'}
				</button>
				<div class="map" bind:this={mapContainer}></div>
				<p class="hint" class:ok={home !== null}>
					{home ? 'Casa marcada.' : 'Sin marcar todavía.'}
				</p>
				<p class="privacy">
					El servidor no guarda el punto que marques. Guarda solo una zona irregular de 25 a 45 m a
					su alrededor, que nadie puede ver, ni siquiera tú.
				</p>
				<label class="check">
					<input type="checkbox" bind:checked={consent} />
					<span>
						Acepto que el juego use esa zona como mi casa y para saber en qué población juego.
					</span>
				</label>
			</fieldset>

			{#if errorMessage}
				<p class="error" role="alert">{errorMessage}</p>
			{/if}

			<button type="submit" class="primary" disabled={!complete || submitting}>
				{submitting ? 'Registrando…' : 'Entregar la ficha'}
			</button>
			{#if !complete}
				<p class="hint">Completa los tres apartados para entregar la ficha.</p>
			{/if}
		</form>
	{/if}
</main>

<style>
	:global(body) {
		margin: 0;
		background: #c9d0c4;
	}

	.sheet {
		--paper: #e4e8df;
		--field: #f3f5ef;
		--ink: #1d2b3a;
		--ink-soft: #4a5866;
		--rule: #9aa59a;
		--stamp: #a3242b;
		--focus: #2f5d8a;

		box-sizing: border-box;
		max-width: 38rem;
		min-height: 100vh;
		margin: 0 auto;
		padding: 1.5rem 1rem 3rem;
		background: var(--paper);
		color: var(--ink);
		font-family: 'Archivo Narrow', 'Arial Narrow', sans-serif;
		font-size: 1.0625rem;
		line-height: 1.45;
		border-left: 1px solid var(--rule);
		border-right: 1px solid var(--rule);
	}

	.sheet-head {
		border-bottom: 3px double var(--ink);
		padding-bottom: 1rem;
		margin-bottom: 1.25rem;
	}

	.issuer {
		margin: 0;
		color: var(--ink-soft);
		font-size: 0.95rem;
	}

	h1 {
		margin: 0.15rem 0 0.25rem;
		font-size: clamp(1.7rem, 6vw, 2.3rem);
		line-height: 1.05;
		font-weight: 700;
		letter-spacing: -0.01em;
	}

	.form-id {
		margin: 0;
		font-weight: 600;
	}

	.lead {
		margin: 0.75rem 0 0;
		max-width: 34em;
	}

	fieldset {
		border: 0;
		border-top: 1px solid var(--rule);
		margin: 0 0 1.5rem;
		padding: 0.9rem 0 0;
	}

	legend {
		display: flex;
		align-items: baseline;
		gap: 0.5rem;
		padding: 0 0.4rem 0 0;
		font-size: 1.3rem;
		font-weight: 700;
	}

	.num {
		display: inline-grid;
		place-items: center;
		width: 1.6rem;
		height: 1.6rem;
		border: 2px solid var(--ink);
		border-radius: 50%;
		font-size: 0.95rem;
	}

	.row {
		display: grid;
		grid-template-columns: 9.5rem 1fr;
		align-items: end;
		gap: 0.75rem;
		margin: 0.55rem 0;
	}

	.lbl {
		font-weight: 600;
		padding-bottom: 0.3rem;
	}

	/* Lo que escribe el jugador sale a máquina, sobre la línea del formulario. */
	.typed {
		font-family: 'Courier Prime', 'Courier New', monospace;
		font-size: 1.05rem;
		color: var(--ink);
		background: var(--field);
		border: 0;
		border-bottom: 2px solid var(--ink);
		border-radius: 0;
		padding: 0.35rem 0.4rem;
		width: 100%;
		box-sizing: border-box;
	}

	.typed.short {
		max-width: 7rem;
	}

	.typed:focus-visible,
	.check input:focus-visible,
	button:focus-visible,
	.primary:focus-visible {
		outline: 3px solid var(--focus);
		outline-offset: 2px;
	}

	.hint {
		margin: 0.35rem 0;
		color: var(--ink-soft);
		font-size: 0.95rem;
	}

	.hint.warn {
		color: var(--stamp);
	}

	.hint.ok {
		color: var(--ink);
		font-weight: 600;
	}

	.map {
		width: 100%;
		aspect-ratio: 4 / 3;
		margin-top: 0.6rem;
		border: 2px solid var(--ink);
	}

	.privacy {
		margin: 0.6rem 0;
		padding: 0.6rem 0.75rem;
		border-left: 4px solid var(--ink);
		background: var(--field);
		font-size: 0.95rem;
	}

	.check {
		display: flex;
		gap: 0.6rem;
		align-items: flex-start;
		margin-top: 0.75rem;
	}

	.check input {
		width: 1.2rem;
		height: 1.2rem;
		margin-top: 0.15rem;
		accent-color: var(--ink);
	}

	.secondary {
		font: inherit;
		font-weight: 600;
		color: var(--ink);
		background: transparent;
		border: 2px solid var(--ink);
		padding: 0.4rem 0.9rem;
		cursor: pointer;
	}

	.primary {
		display: inline-block;
		font: inherit;
		font-size: 1.15rem;
		font-weight: 700;
		color: var(--paper);
		background: var(--ink);
		border: 2px solid var(--ink);
		padding: 0.65rem 1.4rem;
		cursor: pointer;
		text-decoration: none;
	}

	.primary:disabled,
	.secondary:disabled {
		opacity: 0.45;
		cursor: not-allowed;
	}

	.error {
		color: var(--stamp);
		font-weight: 600;
		border: 2px solid var(--stamp);
		padding: 0.5rem 0.75rem;
	}

	.note {
		color: var(--ink-soft);
	}

	.done {
		position: relative;
		padding-top: 1rem;
	}

	.done-text {
		max-width: 30em;
		margin: 1.25rem 0 1.5rem;
	}

	/* El único momento con movimiento: el sello cae sobre la ficha. */
	.stamp {
		display: inline-block;
		font-family: 'Archivo Narrow', sans-serif;
		font-weight: 700;
		font-size: 2.6rem;
		color: var(--stamp);
		border: 5px solid var(--stamp);
		border-radius: 6px;
		padding: 0.1rem 1rem;
		transform: rotate(-8deg);
		opacity: 0.85;
		animation: stamp-down 0.35s cubic-bezier(0.2, 0.9, 0.3, 1.2) both;
	}

	@keyframes stamp-down {
		from {
			transform: rotate(-8deg) scale(2.2);
			opacity: 0;
		}
		to {
			transform: rotate(-8deg) scale(1);
			opacity: 0.85;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.stamp {
			animation: none;
		}
	}

	@media (max-width: 30rem) {
		.row {
			grid-template-columns: 1fr;
			gap: 0.2rem;
		}
		.lbl {
			padding-bottom: 0;
		}
	}
</style>
