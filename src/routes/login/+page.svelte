<script lang="ts">
  import { supabase } from '$lib/supabase';
  import { goto } from '$app/navigation';

  let email = $state('');
  let password = $state('');
  let errorMessage = $state<string | null>(null);
  let loading = $state(false);

  async function handleLogin(event: Event) {
    event.preventDefault();
    loading = true;
    errorMessage = null;

    const { data, error } = await supabase.auth.signInWithPassword({
      email,
      password
    });

    if (error) {
      errorMessage = error.message;
      loading = false;
    } else {
      goto('/');
    }
  }
</script>

<h1>Acceso al sistema</h1>

<p>Pandemia activa. Identifícate para acceder al protocolo de supervivencia.</p>

<form onsubmit={handleLogin}>
  <div>
    <label for="email">Email</label>
    <input
      type="email"
      id="email"
      bind:value={email}
      required
      autocomplete="email"
    />
  </div>

  <div>
    <label for="password">Contraseña</label>
    <input
      type="password"
      id="password"
      bind:value={password}
      required
      autocomplete="current-password"
    />
  </div>

  <button type="submit" disabled={loading}>
    {loading ? 'Conectando...' : 'Entrar'}
  </button>

  {#if errorMessage}
    <p style="color: red;">Error: {errorMessage}</p>
  {/if}
</form>