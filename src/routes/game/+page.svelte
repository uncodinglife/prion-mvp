<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { supabase } from '$lib/supabase';
  import { goto } from '$app/navigation';

  let mapContainer: HTMLDivElement;
  let map: any = null;
  let userMarker: any = null;
  let positionStatus = $state<string>('Solicitando permiso de geolocalización...');
  let userPosition = $state<{ lat: number; lng: number } | null>(null);
  let watchId: number | null = null;

 onMount(async () => {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) {
      goto('/login');
      return;
    }

    const L = (await import('leaflet')).default;
    await import('leaflet/dist/leaflet.css');

    map = L.map(mapContainer).setView([41.7811, 3.0306], 17);

    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '© OpenStreetMap',
      maxZoom: 19
    }).addTo(map);

    if (!('geolocation' in navigator)) {
      positionStatus = 'Tu navegador no soporta geolocalización.';
      return;
    }

    if ('permissions' in navigator) {
      const permission = await navigator.permissions.query({ name: 'geolocation' });

      if (permission.state === 'denied') {
        positionStatus = 'Geolocalización bloqueada. Activa el permiso en la configuración del navegador (icono del candado en la barra de direcciones) y recarga la página.';
        return;
      }
    }

    watchId = navigator.geolocation.watchPosition(
      (pos) => {
        const lat = pos.coords.latitude;
        const lng = pos.coords.longitude;
        userPosition = { lat, lng };
        positionStatus = `Posición: ${lat.toFixed(6)}, ${lng.toFixed(6)} (±${Math.round(pos.coords.accuracy)}m)`;

        if (userMarker) {
          userMarker.setLatLng([lat, lng]);
        } else {
          userMarker = L.marker([lat, lng]).addTo(map).bindPopup('Tu posición');
          map.setView([lat, lng], 17);
        }
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
  });

  onDestroy(() => {
    if (watchId !== null) {
      navigator.geolocation.clearWatch(watchId);
    }
    if (map) {
      map.remove();
    }
  });
</script>

<h1>Zona Prion</h1>

<p>{positionStatus}</p>

<div bind:this={mapContainer} style="width: 100%; height: 500px; border: 1px solid #ccc;"></div>

<p><a href="/">Volver</a></p>