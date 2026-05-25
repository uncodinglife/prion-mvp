<script lang="ts">
  import { supabase } from '$lib/supabase';
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';

  let user = $state<any>(null);
  let sessionData = $state<any>(null);
  let errorMessage = $state<string | null>(null);
  let loading = $state(true);

  onMount(async () => {
    const { data: { user: currentUser } } = await supabase.auth.getUser();
    user = currentUser;

    if (user) {
      const { data, error } = await supabase
        .from('game_session')
        .select('*')
        .limit(1);

      if (error) {
        errorMessage = error.message;
      } else {
        sessionData = data;
      }
    }

    loading = false;
  });

  async function handleLogout() {
    await supabase.auth.signOut();
    user = null;
    sessionData = null;
  }
</script>

<h1>Proyecto Prion</h1>

{#if loading}
  <p>Cargando...</p>
{:else if !user}
  <p>No has iniciado sesión.</p>
  <a href="/login">Ir al login</a>
{:else}
  <p>Autenticado como: <strong>{user.email}</strong></p>
  <button onclick={handleLogout}>Cerrar sesión</button>

  <hr />

  <h2>Estado del juego</h2>
  {#if errorMessage}
    <p style="color: red;">Error: {errorMessage}</p>
  {:else if sessionData && sessionData.length === 0}
    <p style="color: green;">Conexión OK. No hay sesión de juego activa todavía.</p>
  {:else if sessionData}
    <p style="color: green;">Sesión activa:</p>
    <pre>{JSON.stringify(sessionData, null, 2)}</pre>
  {/if}
{/if}