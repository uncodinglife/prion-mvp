<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { supabase } from '$lib/supabase';
  import { goto } from '$app/navigation';

  let mapContainer: HTMLDivElement;
  let map: any = null;
  let userMarker: any = null;
  let detectionCircle: any = null;
  let zonePolygon: any = null;
  let positionStatus = $state<string>('Solicitando permiso de geolocalización...');
  let zoneStatus = $state<string>('');
  let syncStatus = $state<string>('');
  let userPosition = $state<{ lat: number; lng: number } | null>(null);
  let watchId: number | null = null;
  let pollInterval: ReturnType<typeof setInterval> | null = null;
  let nearbyMarkers: Map<string, any> = new Map();
  let nearbyStatus = $state<string>('Buscando otros jugadores...');
  let L: any = null;
  let lastSentAt = 0;
  let encounterStatus = $state<string>('');
  const SYNC_INTERVAL_MS = 10000;

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

    // GeoJSON viene como [lng, lat], Leaflet quiere [lat, lng]
    return data.coordinates[0].map((coord: [number, number]) => [coord[1], coord[0]]);
  }

  function isInsidePolygon(lat: number, lng: number, polygon: [number, number][]): boolean {
    let inside = false;
    for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      const [yi, xi] = polygon[i];
      const [yj, xj] = polygon[j];
      const intersect = ((yi > lat) !== (yj > lat)) && (lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi);
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

    const { data: { user } } = await supabase.auth.getUser();
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

    // Invocar detección de encuentro
    const { data: detectData, error: detectError } = await supabase.functions.invoke('detect_encounter');

    if (detectError) {
      console.error('Error detect_encounter:', detectError);
      return;
    }

    if (detectData?.encounter) {
      encounterStatus = `Encuentro con ${detectData.opponent_nick}. ID: ${detectData.encounter}`;
      console.log('Encuentro detectado:', detectData);
    } else {
      console.log('Sin encuentro, respuesta completa:', detectData);
    }
  }
async function pollNearbyPlayers() {
    const { data, error } = await supabase
      .from('nearby_players')
      .select('*');

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
        }).addTo(map).bindPopup(label);
        nearbyMarkers.set(player.id, newMarker);
      }
    }

    // Borrar marcadores de jugadores que ya no están cerca
    nearbyMarkers.forEach((marker, id) => {
      if (!currentIds.has(id)) {
        map.removeLayer(marker);
        nearbyMarkers.delete(id);
      }
    });
  }

  onMount(async () => {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) {
      goto('/login');
      return;
    }

    L = (await import('leaflet')).default;
    await import('leaflet/dist/leaflet.css');

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
        positionStatus = 'Geolocalización bloqueada. Activa el permiso en la configuración del navegador y recarga.';
        return;
      }
    }

    watchId = navigator.geolocation.watchPosition(
      (pos) => {
        const lat = pos.coords.latitude;
        const lng = pos.coords.longitude;
        userPosition = { lat, lng };
        positionStatus = `Posición: ${lat.toFixed(6)}, ${lng.toFixed(6)} (±${Math.round(pos.coords.accuracy)}m)`;

        const inside = isInsidePolygon(lat, lng, zonePolygonCoords);
        zoneStatus = inside ? 'En zona' : 'Fuera de zona';

        if (userMarker) {
          userMarker.setLatLng([lat, lng]);
          detectionCircle.setLatLng([lat, lng]);
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
          positionStatus = 'Permiso de geolocalización denegado. Actívalo en el navegador y recarga.';
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
    // Polling de jugadores cercanos cada 5 segundos
    await pollNearbyPlayers();
    pollInterval = setInterval(pollNearbyPlayers, 5000);
  });

  onDestroy(() => {
    if (watchId !== null) {
      navigator.geolocation.clearWatch(watchId);
    }
    if (pollInterval !== null) {
      clearInterval(pollInterval);
    }
    if (map) {
      map.remove();
    }
  });
</script>

<h1>Zona Prion</h1>

<p>{positionStatus}</p>
{#if zoneStatus}
  <p style="color: {zoneStatus === 'En zona' ? 'green' : 'red'}; font-weight: bold;">{zoneStatus}</p>
{/if}
{#if syncStatus}
  <p style="color: blue; font-size: 0.9em;">{syncStatus}</p>
{/if}
{#if nearbyStatus}
  <p style="color: purple; font-size: 0.9em;">{nearbyStatus}</p>
{/if}
{#if encounterStatus}
  <p style="color: red; font-weight: bold; font-size: 1.1em;">{encounterStatus}</p>
{/if}

<div bind:this={mapContainer} style="width: 100%; height: 500px; border: 1px solid #ccc;"></div>

<p><a href="/">Volver</a></p>