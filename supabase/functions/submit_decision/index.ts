import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};

const VALID_DECISIONS: Record<string, string[]> = {
  civil: ["HUIR", "LUCHAR"],
  zombie: ["MORDER", "PERSEGUIR"]
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
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

    const { data: { user }, error: userError } = await supabase.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Not authenticated" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Leer body
    const body = await req.json().catch(() => ({}));
    const { encounter_id, decision } = body;

    if (!encounter_id || !decision) {
      return new Response(
        JSON.stringify({ error: "Missing encounter_id or decision" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseAdmin = createClient(
      supabaseUrl,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Cargar el encuentro
    const { data: encounter, error: encError } = await supabaseAdmin
      .from("encounters")
      .select("*")
      .eq("id", encounter_id)
      .single();

    if (encError || !encounter) {
      return new Response(
        JSON.stringify({ error: "Encounter not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ¿Ya está resuelto?
    if (encounter.result !== null) {
      return new Response(
        JSON.stringify({ error: "Encounter already resolved" }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ¿El usuario es participante? ¿Qué rol tiene en este encuentro?
    let myRole: string | null = null;
    if (encounter.civil_id === user.id) myRole = "civil";
    else if (encounter.zombie_id === user.id) myRole = "zombie";

    if (!myRole) {
      return new Response(
        JSON.stringify({ error: "You are not part of this encounter" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ¿La decisión es válida para su rol?
    if (!VALID_DECISIONS[myRole].includes(decision)) {
      return new Response(
        JSON.stringify({ error: `Invalid decision '${decision}' for role '${myRole}'` }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ¿Ya había decidido?
    const decisionColumn = myRole === "civil" ? "civil_decision" : "zombie_decision";
    const decisionAtColumn = myRole === "civil" ? "civil_decision_at" : "zombie_decision_at";

    if (encounter[decisionColumn] !== null) {
      return new Response(
        JSON.stringify({ error: "You already decided", current: encounter[decisionColumn] }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Guardar la decisión
    const { data: updated, error: updateError } = await supabaseAdmin
      .from("encounters")
      .update({
        [decisionColumn]: decision,
        [decisionAtColumn]: new Date().toISOString()
      })
      .eq("id", encounter_id)
      .select()
      .single();

    if (updateError) {
      return new Response(
        JSON.stringify({ error: "Failed to save decision", detail: updateError.message }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ¿Están ya las dos decisiones?
    const bothDecided = updated.civil_decision !== null && updated.zombie_decision !== null;

    if (bothDecided) {
      const { data: resolveData, error: resolveError } = await supabaseAdmin.rpc(
        "compute_and_resolve_encounter",
        { p_encounter_id: encounter_id }
      );

      if (resolveError) {
        return new Response(
          JSON.stringify({ ok: true, decision, both_decided: true, resolve_error: resolveError.message }),
          { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      return new Response(
        JSON.stringify({ ok: true, decision, both_decided: true, resolved: resolveData }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }


    return new Response(
      JSON.stringify({ ok: true, decision, both_decided: false }),
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