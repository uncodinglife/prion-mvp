<script lang="ts">
  import { supabase } from '$lib/supabase';
  import { onMount } from 'svelte';

  let sessionData = $state<any>(null);
  let errorMessage = $state<string | null>(null);
  let loading = $state(true);

  onMount(async () => {
    const { data, error } = await supabase
      .from('game_session')
      .select('*')
      .limit(1);

    if (error) {
      errorMessage = error.message;
    } else {
      sessionData = data;
    }
    loading = false;
  });
</script>

<h1>Proyecto Prion</h1>

<p>Comprobando conexión con Supabase...</p>

{#if loading}
  <p>Cargando...</p>
{:else if errorMessage}
  <p style="color: red;">Error: {errorMessage}</p>
{:else if sessionData && sessionData.length === 0}
  <p style="color: green;">Conexión OK. No hay sesión de juego activa todavía.</p>
{:else}
  <p style="color: green;">Conexión OK. Sesión encontrada:</p>
  <pre>{JSON.stringify(sessionData, null, 2)}</pre>
{/if}