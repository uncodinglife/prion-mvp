<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import { supabase } from '$lib/supabase';
	import { goto } from '$app/navigation';
	import CombatOverlay from '$lib/CombatOverlay.svelte';
	import RadioReceptora from '$lib/RadioReceptora.svelte';
	import FinalScreen from '$lib/FinalScreen.svelte';
	import { unlockAudio, playEncounter, playGameEnd, playZoneEnter } from '$lib/sounds';

	let mapContainer: HTMLDivElement;
	let map: any = null;
	let userMarker: any = null;
	let detectionCircle: any = null;
	let zonePolygon: any = null;
	let positionStatus = $state<string>('Solicitando permiso de geolocalización...');
	let zoneStatus = $state<string>('');
	let syncStatus = $state<string>('');
	let nearbyStatus = $state<string>('Buscando otros jugadores...');
	let userPosition = $state<{ lat: number; lng: number } | null>(null);
	let watchId: number | null = null;
	let L: any = null;
	let lastSentAt = 0;
	let wasInside: boolean | null = null;
	let radioEvents = $state<any[]>([]);
	const SYNC_INTERVAL_MS = 3000;

	let pollInterval: ReturnType<typeof setInterval> | null = null;
	let nearbyMarkers: Map<string, any> = new Map();

	let activeEncounter = $state<any>(null);
	let resolvedEncounter = $state<any>(null);
	let resultMessage = $state<string>('');
	let myRole = $state<string>('');
	let encounterPollInterval: ReturnType<typeof setInterval> | null = null;
	let radioPollInterval: ReturnType<typeof setInterval> | null = null;

	let gameEnded = $state<boolean>(false);
	let finalReport = $state<any>(null);

	// Estado de cabecera (rol + vida), solo para presentación visual.
	let headerRole = $state<string>('');
	let headerLife = $state<number>(10);
	let headerNick = $state<string>('');
	let headerStatus = $state<string>('active');
	let headerStatusUntil = $state<number | null>(null);
	let headerStatusRemainingMs = $state<number>(0);
	let headerPollInterval: ReturnType<typeof setInterval> | null = null;
	let statusTickInterval: ReturnType<typeof setInterval> | null = null;

	const STATUS_LABELS: Record<string, string> = {
		radar_disabled: 'Radar oculto',
		neutralized: 'Caído'
	};

	function formatRemaining(ms: number): string {
		const totalSeconds = Math.max(0, Math.ceil(ms / 1000));
		const minutes = Math.floor(totalSeconds / 60);
		const seconds = totalSeconds % 60;
		return `${minutes}m ${seconds}s`;
	}

	// Recalcula el tiempo restante del cooldown de radar / neutralización.
	function updateStatusRemaining() {
		headerStatusRemainingMs = headerStatusUntil === null ? 0 : Math.max(0, headerStatusUntil - Date.now());
	}

	// Desbloqueo de audio: varios tipos de gesto (touchstart es el que exige iOS Safari;
	// pointerdown/click cubren el resto) para no depender de uno solo. Se mantienen activos
	// toda la sesión (no se desregistran tras el primer disparo): Safari puede suspender el
	// AudioContext por su cuenta más adelante (pérdida de foco, bloqueo de pantalla), y solo
	// un gesto real del jugador puede reanudarlo, así que hace falta poder reintentarlo en
	// cada gesto posterior, no solo en el primero.
	const AUDIO_UNLOCK_EVENTS = ['touchstart', 'pointerdown', 'click'] as const;
	function unlockAudioOnGesture() {
		unlockAudio();
	}

	let zonePolygonCoords: [number, number][] = [];

	async function loadZonePolygon(): Promise<[number, number][]> {
		const { data, error } = await supabase.rpc('get_playable_zone');
		if (error) {
			console.error('Error cargando polígono de zona:', error);
			return [];
		}
		if (!data || !data.coordinates || !data.coordinates[0]) {
			return [];
		}
		return data.coordinates[0].map((coord: [number, number]) => [coord[1], coord[0]]);
	}

	function isInsidePolygon(lat: number, lng: number, polygon: [number, number][]): boolean {
		let inside = false;
		for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
			const [yi, xi] = polygon[i];
			const [yj, xj] = polygon[j];
			const intersect = yi > lat !== yj > lat && lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi;
			if (intersect) inside = !inside;
		}
		return inside;
	}

	async function sendPositionToSupabase(lat: number, lng: number) {
		const now = Date.now();
		if (now - lastSentAt < SYNC_INTERVAL_MS) {
			return;
		}
		lastSentAt = now;

		const {
			data: { user }
		} = await supabase.auth.getUser();
		if (!user) return;

		const wkt = `POINT(${lng} ${lat})`;

		const { error: updateError } = await supabase
			.from('players')
			.update({
				position: wkt,
				position_updated_at: new Date().toISOString()
			})
			.eq('id', user.id);

		if (updateError) {
			syncStatus = `Error sincronizando: ${updateError.message}`;
			console.error('Error update position:', updateError);
			return;
		}

		syncStatus = `Sincronizado a las ${new Date().toLocaleTimeString()}`;

		const { data: detectData, error: detectError } =
			await supabase.functions.invoke('detect_encounter');

		if (detectError) {
			console.error('Error detect_encounter:', detectError);
			return;
		}
	}

	async function pollNearbyPlayers() {
		const { data, error } = await supabase.from('nearby_players').select('*');

		if (error) {
			console.error('Error consultando nearby_players:', error);
			nearbyStatus = `Error: ${error.message}`;
			return;
		}

		if (!data || data.length === 0) {
			nearbyStatus = 'No hay jugadores cercanos';
			nearbyMarkers.forEach((marker) => map.removeLayer(marker));
			nearbyMarkers.clear();
			return;
		}

		nearbyStatus = `${data.length} jugador(es) cercano(s)`;

		const currentIds = new Set<string>();

		for (const player of data) {
			if (player.lat == null || player.lng == null) continue;
			currentIds.add(player.id);

			const color = player.role === 'civil' ? '#2d7a2d' : '#a02828';
			const label = `${player.nick} (${player.role}) - ${Math.round(player.distance_meters)}m`;

			const existingMarker = nearbyMarkers.get(player.id);
			if (existingMarker) {
				existingMarker.setLatLng([player.lat, player.lng]);
				existingMarker.setPopupContent(label);
			} else {
				const newMarker = L.circleMarker([player.lat, player.lng], {
					radius: 8,
					color: color,
					fillColor: color,
					fillOpacity: 0.7,
					weight: 2
				})
					.addTo(map)
					.bindPopup(label);
				nearbyMarkers.set(player.id, newMarker);
			}
		}

		nearbyMarkers.forEach((marker, id) => {
			if (!currentIds.has(id)) {
				map.removeLayer(marker);
				nearbyMarkers.delete(id);
			}
		});
	}

	async function pollActiveEncounter() {
		const {
			data: { user }
		} = await supabase.auth.getUser();
		if (!user) return;

		if (activeEncounter && !resolvedEncounter) {
			const { data: enc } = await supabase
				.from('encounters')
				.select('*')
				.eq('id', activeEncounter.id)
				.single();

			if (enc && enc.result !== null) {
				resolvedEncounter = enc;
				const { data: ev } = await supabase
					.from('events')
					.select('message')
					.eq('related_encounter_id', enc.id)
					.eq('player_id', user.id)
					.eq('type', 'encounter_result')
					.maybeSingle();
				resultMessage = ev?.message ?? 'Combate resuelto.';
				return;
			}
			return;
		}

		if (resolvedEncounter) return;

		const { data: player, error: playerError } = await supabase
			.from('players')
			.select('role, current_encounter_id')
			.eq('id', user.id)
			.single();

		if (playerError || !player) return;
		myRole = player.role;

		if (!player.current_encounter_id) return;

		const { data: encounter, error: encError } = await supabase
			.from('encounters')
			.select('*')
			.eq('id', player.current_encounter_id)
			.single();

		if (encError || !encounter) return;
		if (encounter.result !== null) return;

		activeEncounter = encounter;
		await playEncounter();
	}

	async function handleCombatDecision(decision: string) {
		if (!activeEncounter) return;

		const { data, error } = await supabase.functions.invoke('submit_decision', {
			body: {
				encounter_id: activeEncounter.id,
				decision: decision
			}
		});

		if (error) {
			console.error('Error submit_decision:', error);
			return;
		}
	}

	function closeCombat() {
		activeEncounter = null;
		resolvedEncounter = null;
		resultMessage = '';
	}

	async function handleGameEnd(userId: string) {
		gameEnded = true;
		await playGameEnd();

		// Congelar la pantalla: detener geolocalización y todos los polls.
		if (watchId !== null) {
			navigator.geolocation.clearWatch(watchId);
			watchId = null;
		}
		if (pollInterval !== null) {
			clearInterval(pollInterval);
			pollInterval = null;
		}
		if (encounterPollInterval !== null) {
			clearInterval(encounterPollInterval);
			encounterPollInterval = null;
		}
		if (radioPollInterval !== null) {
			clearInterval(radioPollInterval);
			radioPollInterval = null;
		}

		const { data, error } = await supabase.rpc('get_final_report', { p_player_id: userId });
		if (error) {
			console.error('Error get_final_report:', error);
			return;
		}
		finalReport = data;
	}
	async function pollRadioEvents() {
		const {
			data: { user }
		} = await supabase.auth.getUser();
		if (!user) return;

		const { data, error } = await supabase
			.from('events')
			.select('id, type, message, created_at')
			.eq('player_id', user.id)
			.order('created_at', { ascending: true })
			.limit(50);

		if (error) {
			console.error('Error consultando events:', error);
			return;
		}

		radioEvents = data ?? [];

		if (!gameEnded && radioEvents.some((e) => e.type === 'game_end')) {
			await handleGameEnd(user.id);
		}
	}

	// Lee el rol y la vida actuales para pintar la cabecera; solo lectura, no toca lógica de juego.
	async function pollHeaderStatus() {
		const {
			data: { user }
		} = await supabase.auth.getUser();
		if (!user) return;

		const { data: player, error } = await supabase
			.from('players')
			.select('role, life, nick, status, status_until')
			.eq('id', user.id)
			.single();

		if (error || !player) return;

		headerRole = player.role;
		if (typeof player.life === 'number') {
			headerLife = player.life;
		}
		if (typeof player.nick === 'string') {
			headerNick = player.nick;
		}

		headerStatus = typeof player.status === 'string' ? player.status : 'active';
		headerStatusUntil = player.status_until ? new Date(player.status_until).getTime() : null;
		updateStatusRemaining();

		const shouldTick =
			(headerStatus === 'radar_disabled' || headerStatus === 'neutralized') && headerStatusUntil !== null;
		if (shouldTick && statusTickInterval === null) {
			statusTickInterval = setInterval(updateStatusRemaining, 1000);
		} else if (!shouldTick && statusTickInterval !== null) {
			clearInterval(statusTickInterval);
			statusTickInterval = null;
		}
	}

	onMount(async () => {
		const {
			data: { user }
		} = await supabase.auth.getUser();
		if (!user) {
			goto('/login');
			return;
		}

		L = (await import('leaflet')).default;
		await import('leaflet/dist/leaflet.css');

		// Desbloquear el audio en el primer gesto del usuario (los navegadores lo exigen;
		// en iOS Safari concretamente hace falta un touchstart/click real, no basta pointerdown).
		AUDIO_UNLOCK_EVENTS.forEach((evt) =>
			window.addEventListener(evt, unlockAudioOnGesture, { passive: true })
		);

		delete (L.Icon.Default.prototype as any)._getIconUrl;
		L.Icon.Default.mergeOptions({
			iconUrl: 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png',
			iconRetinaUrl: 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png',
			shadowUrl: 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-shadow.png'
		});

		map = L.map(mapContainer).setView([41.7811, 3.029], 16);

		L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
			attribution: '© OpenStreetMap',
			maxZoom: 19
		}).addTo(map);

		zonePolygonCoords = await loadZonePolygon();

		if (zonePolygonCoords.length === 0) {
			positionStatus = 'No se pudo cargar la zona de juego.';
			return;
		}

		zonePolygon = L.polygon(zonePolygonCoords, {
			color: '#2d7a2d',
			fillColor: '#2d7a2d',
			fillOpacity: 0.15,
			weight: 2
		}).addTo(map);

		map.fitBounds(zonePolygon.getBounds());

		if (!('geolocation' in navigator)) {
			positionStatus = 'Tu navegador no soporta geolocalización.';
			return;
		}

		if ('permissions' in navigator) {
			const permission = await navigator.permissions.query({ name: 'geolocation' });
			if (permission.state === 'denied') {
				positionStatus =
					'Geolocalización bloqueada. Activa el permiso en la configuración del navegador y recarga.';
				return;
			}
		}

		watchId = navigator.geolocation.watchPosition(
			async (pos) => {
				const lat = pos.coords.latitude;
				const lng = pos.coords.longitude;
				userPosition = { lat, lng };
				positionStatus = `Posición: ${lat.toFixed(6)}, ${lng.toFixed(6)} (±${Math.round(pos.coords.accuracy)}m)`;

				const inside = isInsidePolygon(lat, lng, zonePolygonCoords);
				zoneStatus = inside ? 'En zona' : 'Fuera de zona';

				// Solo al cruzar de fuera a dentro (o al abrir ya estando dentro).
				if (inside && wasInside !== true) {
					await playZoneEnter();
				}
				wasInside = inside;

				if (userMarker) {
					userMarker.setLatLng([lat, lng]);
					detectionCircle.setLatLng([lat, lng]);
					map.panTo([lat, lng], { animate: true });
				} else {
					userMarker = L.marker([lat, lng]).addTo(map).bindPopup('Tu posición');
					detectionCircle = L.circle([lat, lng], {
						radius: 25,
						color: '#d24747',
						fillColor: '#d24747',
						fillOpacity: 0.1,
						weight: 1
					}).addTo(map);
					map.setView([lat, lng], 17);
				}

				sendPositionToSupabase(lat, lng);
			},
			(err) => {
				if (err.code === err.PERMISSION_DENIED) {
					positionStatus =
						'Permiso de geolocalización denegado. Actívalo en el navegador y recarga.';
				} else if (err.code === err.POSITION_UNAVAILABLE) {
					positionStatus = 'Posición no disponible. Comprueba tu GPS o conexión.';
				} else if (err.code === err.TIMEOUT) {
					positionStatus = 'Tiempo agotado intentando obtener posición. Reintenta.';
				} else {
					positionStatus = `Error: ${err.message}`;
				}
			},
			{
				enableHighAccuracy: true,
				maximumAge: 5000,
				timeout: 10000
			}
		);

		await pollNearbyPlayers();
		pollInterval = setInterval(pollNearbyPlayers, 5000);

		await pollActiveEncounter();
		encounterPollInterval = setInterval(pollActiveEncounter, 3000);

		await pollRadioEvents();
		radioPollInterval = setInterval(pollRadioEvents, 5000);

		await pollHeaderStatus();
		headerPollInterval = setInterval(pollHeaderStatus, 3000);

		// El contenedor del mapa es ahora cuadrado vía CSS (aspect-ratio); al rotar el móvil
		// o cambiar el tamaño de la ventana, Leaflet necesita que se lo digamos explícitamente.
		window.addEventListener('resize', handleMapResize);
	});

	function handleMapResize() {
		map?.invalidateSize();
	}

	onDestroy(() => {
		window.removeEventListener('resize', handleMapResize);
		if (watchId !== null) {
			navigator.geolocation.clearWatch(watchId);
		}
		if (pollInterval !== null) {
			clearInterval(pollInterval);
		}
		if (encounterPollInterval !== null) {
			clearInterval(encounterPollInterval);
		}
		if (radioPollInterval !== null) {
			clearInterval(radioPollInterval);
		}
		if (headerPollInterval !== null) {
			clearInterval(headerPollInterval);
		}
		if (statusTickInterval !== null) {
			clearInterval(statusTickInterval);
		}
		if (typeof window !== 'undefined') {
			AUDIO_UNLOCK_EVENTS.forEach((evt) => window.removeEventListener(evt, unlockAudioOnGesture));
		}
		if (map) {
			map.remove();
		}
	});
</script>

<div
	class="game-root"
	class:theme-civil={headerRole === 'civil'}
	class:theme-zombie={headerRole === 'zombie'}
>
	<header class="game-header">
		<h1>Zona Prion</h1>

		<div class="header-status">
			{#if headerRole === 'civil'}
				<div class="role-badge">
					<span class="role-icon" aria-hidden="true">🛡️</span>
					<span class="role-label">CIVIL</span>
				</div>
			{:else if headerRole === 'zombie'}
				<div class="role-badge">
					<span class="role-icon" aria-hidden="true">🧟</span>
					<span class="role-label">ZOMBIE</span>
				</div>
			{:else}
				<div class="role-badge role-badge-pending">
					<span class="role-label">CARGANDO ROL…</span>
				</div>
			{/if}

			{#if headerNick}
				<span class="nick-tag">{headerNick}</span>
			{/if}

			{#if (headerStatus === 'radar_disabled' || headerStatus === 'neutralized') && headerStatusRemainingMs > 0}
				<span class="status-indicator">
					{STATUS_LABELS[headerStatus]} · {formatRemaining(headerStatusRemainingMs)}
				</span>
			{/if}

			<div class="life-track" aria-label={`Vida: ${headerLife} de 10`}>
				<div class="life-segments" class:critical={headerLife <= 3}>
					{#each Array(10) as _, i (i)}
						<span class="segment" class:filled={i < headerLife}></span>
					{/each}
				</div>
				<span class="life-number" class:critical={headerLife <= 3}>{headerLife} / 10</span>
			</div>
		</div>
	</header>

	<p class="status-text">{positionStatus}</p>
	{#if zoneStatus}
		<p
			class="status-zone"
			class:zone-ok={zoneStatus === 'En zona'}
			class:zone-alert={zoneStatus !== 'En zona'}
		>
			{zoneStatus}
		</p>
	{/if}
	{#if syncStatus}
		<p class="status-text status-small">{syncStatus}</p>
	{/if}
	{#if nearbyStatus}
		<p class="status-text status-small">{nearbyStatus}</p>
	{/if}

	<div
		bind:this={mapContainer}
		style="width: 100%; max-width: 500px; aspect-ratio: 1 / 1; border: 1px solid #ccc; margin: 0 auto;"
	></div>
	<RadioReceptora events={radioEvents} />

	{#if activeEncounter}
		<CombatOverlay
			encounter={activeEncounter}
			{myRole}
			resolved={resolvedEncounter}
			{resultMessage}
			onDecision={handleCombatDecision}
			onClose={closeCombat}
		/>
	{/if}

	{#if gameEnded && finalReport}
		<FinalScreen report={finalReport} />
	{/if}

	<p><a class="back-link" href="/">Volver</a></p>
</div>

<style>
	/*
   * Tema por bando: variables CSS definidas aquí y consumidas también por
   * componentes hijos (p. ej. RadioReceptora) vía herencia de custom properties,
   * que atraviesa los límites de scoped-style de Svelte. Cambiar el bando solo
   * requiere tocar estos bloques .theme-*, nunca los colores en el resto del CSS.
   */
	.game-root {
		--theme-bg: #14171a;
		--theme-panel: #0d0f11;
		--theme-accent: #9ca3af;
		--theme-text-soft: #cbd5e1;
		--theme-alert: #facc15;

		background: var(--theme-bg);
		color: var(--theme-text-soft);
		min-height: 100vh;
		padding: 1rem;
		box-sizing: border-box;
		transition: background-color 0.4s ease;
	}

	.game-root.theme-civil {
		--theme-bg: #0f3d2e;
		--theme-panel: #0a1f16;
		--theme-accent: #4ade80;
		--theme-text-soft: #bdf5d1;
		--theme-alert: #fbbf24;
	}

	.game-root.theme-zombie {
		--theme-bg: #3d0f0f;
		--theme-panel: #1f0a0a;
		--theme-accent: #f87171;
		--theme-text-soft: #ffd0d0;
		--theme-alert: #fde047;
	}

	.game-header {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
		margin-bottom: 1rem;
	}

	.game-header h1 {
		color: var(--theme-text-soft);
		margin: 0;
	}

	.header-status {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 1rem;
		background: var(--theme-panel);
		border: 1px solid var(--theme-accent);
		border-radius: 8px;
		padding: 0.6rem 0.9rem;
	}

	.role-badge {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		font-family: monospace;
	}

	.role-icon {
		font-size: 1.5rem;
		line-height: 1;
	}

	.role-label {
		font-size: 1.1rem;
		font-weight: bold;
		letter-spacing: 0.1em;
		color: var(--theme-accent);
	}

	.role-badge-pending .role-label {
		font-size: 0.85rem;
		color: var(--theme-text-soft);
		font-weight: normal;
		letter-spacing: normal;
	}

	.nick-tag {
		font-family: monospace;
		font-size: 0.85rem;
		color: var(--theme-text-soft);
		opacity: 0.75;
		border: 1px solid var(--theme-accent);
		border-radius: 4px;
		padding: 0.15rem 0.5rem;
	}

	.status-indicator {
		font-size: 0.85rem;
		font-weight: bold;
		color: var(--theme-alert);
		border: 1px solid var(--theme-alert);
		border-radius: 4px;
		padding: 0.15rem 0.5rem;
	}

	.life-track {
		display: flex;
		align-items: center;
		gap: 0.6rem;
	}

	.life-segments {
		display: flex;
		gap: 3px;
	}

	.segment {
		width: 16px;
		height: 14px;
		border-radius: 2px;
		background: transparent;
		border: 1px solid var(--theme-accent);
		opacity: 0.4;
	}

	.segment.filled {
		background: var(--theme-accent);
		opacity: 1;
	}

	.life-segments.critical .segment.filled {
		animation: life-pulse 1s ease-in-out infinite;
	}

	.life-number {
		font-family: monospace;
		font-size: 0.9rem;
		color: var(--theme-text-soft);
	}

	.life-number.critical {
		animation: life-pulse 1s ease-in-out infinite;
		color: var(--theme-accent);
		font-weight: bold;
	}

	@keyframes life-pulse {
		0%,
		100% {
			opacity: 1;
		}
		50% {
			opacity: 0.35;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.life-segments.critical .segment.filled,
		.life-number.critical {
			animation: none;
		}
	}

	/* Textos de estado (posición, sync, jugadores cercanos): brillo bajo pero legibles. */
	.status-text {
		color: var(--theme-text-soft);
		opacity: 0.8;
	}

	.status-small {
		font-size: 0.9em;
	}

	.status-zone {
		font-weight: bold;
	}

	.status-zone.zone-ok {
		color: var(--theme-accent);
	}

	.status-zone.zone-alert {
		color: var(--theme-alert);
	}

	.back-link,
	.back-link:visited {
		color: var(--theme-accent);
	}

	.back-link:hover,
	.back-link:focus-visible {
		color: var(--theme-alert);
	}
</style>
