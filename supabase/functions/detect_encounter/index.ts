import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // 1. Cliente Supabase con el JWT del usuario que invoca
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Missing authorization" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    });

    // 2. Obtener usuario autenticado
    const { data: { user }, error: userError } = await supabase.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Not authenticated" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 3. Cliente admin (bypass RLS para operaciones internas)
    const supabaseAdmin = createClient(
      supabaseUrl,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // 4. Comprobar sesión de juego activa
    const { data: gameSession, error: gameError } = await supabaseAdmin
      .from("game_session")
      .select("status, start_time, end_time, playable_zone")
      .eq("status", "active")
      .gte("end_time", new Date().toISOString())
      .lte("start_time", new Date().toISOString())
      .maybeSingle();

    console.log("Game session query result:", JSON.stringify({ gameSession, gameError }));

    if (gameError || !gameSession) {
      return new Response(
        JSON.stringify({ 
          encounter: null, 
          reason: "no_active_game",
          debug: { gameError: gameError?.message, gameSession }
        }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 5. Cargar el jugador actual
    const { data: player, error: playerError } = await supabaseAdmin
      .from("players")
      .select("id, role, status, life, current_encounter_id, position, position_updated_at")
      .eq("id", user.id)
      .single();

    if (playerError || !player) {
      return new Response(
        JSON.stringify({ encounter: null, reason: "player_not_found" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 6. Precondiciones del jugador
    if (player.status !== "active") {
      return new Response(
        JSON.stringify({ encounter: null, reason: "player_not_active" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    if (player.current_encounter_id) {
      return new Response(
        JSON.stringify({ encounter: null, reason: "already_in_encounter" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    if (player.life <= 0) {
      return new Response(
        JSON.stringify({ encounter: null, reason: "no_life" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const positionAge = Date.now() - new Date(player.position_updated_at).getTime();
    if (positionAge > 30000) {
      return new Response(
        JSON.stringify({ encounter: null, reason: "position_outdated" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 7. Comprobar que el jugador está dentro de la zona de juego
    const { data: insideZone } = await supabaseAdmin.rpc("is_inside_zone", {
      p_player_id: user.id
    });

    if (!insideZone) {
      return new Response(
        JSON.stringify({ encounter: null, reason: "outside_zone" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 8. Buscar rival cercano del rol contrario
    const oppositeRole = player.role === "civil" ? "zombie" : "civil";

    const { data: candidates, error: candError } = await supabaseAdmin.rpc(
      "find_nearby_opponent",
      {
        p_player_id: user.id,
        p_opposite_role: oppositeRole
      }
    );

    if (candError || !candidates || candidates.length === 0) {
      return new Response(
        JSON.stringify({ encounter: null, reason: "no_candidates" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const opponent = candidates[0];

    // 9. Crear encuentro vía transacción SQL
    const civilId = player.role === "civil" ? player.id : opponent.id;
    const zombieId = player.role === "zombie" ? player.id : opponent.id;

    const { data: encounterId, error: txError } = await supabaseAdmin.rpc(
      "create_encounter_transaction",
      {
        p_civil_id: civilId,
        p_zombie_id: zombieId
      }
    );

    if (txError) {
      return new Response(
        JSON.stringify({ encounter: null, reason: "transaction_failed", error: txError.message }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 10. Devolver el id del encuentro
    return new Response(
      JSON.stringify({ encounter: encounterId, opponent_nick: opponent.nick }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (err) {
    console.error("Error:", err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});