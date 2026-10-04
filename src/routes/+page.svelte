<script lang="ts">
  import { supabase } from '$lib/supabase';
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';

  let user = $state<any>(null);
  let loading = $state(true);
  let inCensus = $state(false);

  onMount(async () => {
    const { data: { user: currentUser } } = await supabase.auth.getUser();
    user = currentUser;
    if (user) {
      const { data } = await supabase.from('players').select('age_band').eq('id', user.id).maybeSingle();
      inCensus = !!data?.age_band;
    }
    loading = false;
  });

  async function handleLogout() {
    await supabase.auth.signOut();
    user = null;
  }
</script>

<h1>Proyecto Prion</h1>

{#if loading}
  <p>Cargando...</p>
{:else if !user}
  <p>Pandemia activa. Identifícate para acceder al protocolo de supervivencia.</p>
  <a href="/login">Acceder al sistema</a>
{:else}
  <p>Identificado como <strong>{user.email}</strong></p>
  {#if !inCensus}
    <p><a href="/alta">Inscribirme en el censo</a></p>
  {/if}
  <p><a href="/game">Entrar a Zona Prion</a></p>
  <p><button onclick={handleLogout}>Cerrar sesión</button></p>
{/if}