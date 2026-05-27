<script lang="ts">
  import { supabase } from '$lib/supabase';

  let result = $state<string>('');
  let loading = $state(false);

  async function callFunction() {
    loading = true;
    const { data, error } = await supabase.functions.invoke('hello-prion', {
      body: {}
    });

    if (error) {
      result = `Error: ${error.message}`;
    } else {
      result = JSON.stringify(data, null, 2);
    }
    loading = false;
  }
</script>

<h1>Probar Edge Function</h1>

<button onclick={callFunction} disabled={loading}>
  {loading ? 'Llamando...' : 'Invocar hello-prion'}
</button>

{#if result}
  <pre>{result}</pre>
{/if}