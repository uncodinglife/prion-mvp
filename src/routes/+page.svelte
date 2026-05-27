<script lang="ts">
  import { supabase } from '$lib/supabase';
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';

  let user = $state<any>(null);
  let loading = $state(true);

  onMount(async () => {
    const { data: { user: currentUser } } = await supabase.auth.getUser();
    user = currentUser;
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
  <p><a href="/game">Entrar a Zona Prion</a></p>
  <p><button onclick={handleLogout}>Cerrar sesión</button></p>
{/if}