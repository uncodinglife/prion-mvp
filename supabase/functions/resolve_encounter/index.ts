import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};

function rollDie(): number {
  return Math.floor(Math.random() * 6) + 1;
}

// Calcula el resultado del combate según la tabla cerrada.
// Devuelve daños, result, dice_roll, mensajes y cooldowns.
function computeOutcome(civilDecision: string, zombieDecision: string) {
  let result = "";
  let civilDamage = 0;
  let zombieDamage = 0;
  let diceRoll: any = null;
  let civilMsg = "";
  let zombieMsg = "";
  let civilCooldown = 180; // 3 min por defecto
  let zombieCooldown = 180;

  if (civilDecision === "HUIR" && zombieDecision === "MORDER") {
    result = "civil_escaped";
    civilDamage = 1;
    civilCooldown = 300; // huida exitosa: 5 min
    civilMsg = "Escapas entre callejones. Un rasguño, nada más. (-1)";
    zombieMsg = "Dentellada al aire. La presa se escabulle.";
  }
  else if (civilDecision === "HUIR" && zombieDecision === "PERSEGUIR") {
    result = "civil_caught";
    civilDamage = 2;
    civilMsg = "Te dan caza antes de doblar la esquina. (-2)";
    zombieMsg = "Lo alcanzas. Tus garras encuentran carne. (civil -2)";
  }
  else if (civilDecision === "LUCHAR" && zombieDecision === "PERSEGUIR") {
    result = "civil_wins_fight";
    zombieDamage = 3;
    civilMsg = "Aprovechas su impulso y golpeas. Retrocede herido. (zombie -3)";
    zombieMsg = "Te lanzas y te recibe con un golpe seco. (-3)";
  }
  else if (civilDecision === "LUCHAR" && zombieDecision === "MORDER") {
    // Cuerpo a cuerpo: dado, perdedor -4, re-tirar en empate
    const rolls: any[] = [];
    let civilRoll = 0;
    let zombieRoll = 0;
    do {
      civilRoll = rollDie();
      zombieRoll = rollDie();
      rolls.push({ civil: civilRoll, zombie: zombieRoll });
    } while (civilRoll === zombieRoll);

    if (civilRoll > zombieRoll) {
      result = "civil_wins_fight";
      zombieDamage = 4;
      civilMsg = `Choque brutal. Te impones (${civilRoll} vs ${zombieRoll}). (zombie -4)`;
      zombieMsg = `Forcejeo cuerpo a cuerpo. Pierdes (${zombieRoll} vs ${civilRoll}). (-4)`;
    } else {
      result = "zombie_wins_fight";
      civilDamage = 4;
      civilMsg = `Forcejeo cuerpo a cuerpo. Pierdes (${civilRoll} vs ${zombieRoll}). (-4)`;
      zombieMsg = `Choque brutal. Te impones (${zombieRoll} vs ${civilRoll}). (civil -4)`;
    }

    diceRoll = { rolls, winner: civilRoll > zombieRoll ? "civil" : "zombie" };
  }

  return { result, civilDamage, zombieDamage, diceRoll, civilMsg, zombieMsg, civilCooldown, zombieCooldown };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const body = await req.json().catch(() => ({}));
    const { encounter_id } = body;

    if (!encounter_id) {
      return new Response(
        JSON.stringify({ error: "Missing encounter_id" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Cargar encuentro
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

    if (encounter.result !== null) {
      return new Response(
        JSON.stringify({ error: "Already resolved" }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Las dos decisiones deben estar
    if (!encounter.civil_decision || !encounter.zombie_decision) {
      return new Response(
        JSON.stringify({ error: "Both decisions required", civil: encounter.civil_decision, zombie: encounter.zombie_decision }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Calcular resultado
    const outcome = computeOutcome(encounter.civil_decision, encounter.zombie_decision);

    // Aplicar vía transacción SQL
    const { data: txResult, error: txError } = await supabaseAdmin.rpc(
      "resolve_encounter_transaction",
      {
        p_encounter_id: encounter_id,
        p_result: outcome.result,
        p_civil_damage: outcome.civilDamage,
        p_zombie_damage: outcome.zombieDamage,
        p_dice_roll: outcome.diceRoll,
        p_civil_msg: outcome.civilMsg,
        p_zombie_msg: outcome.zombieMsg,
        p_civil_cooldown_seconds: outcome.civilCooldown,
        p_zombie_cooldown_seconds: outcome.zombieCooldown
      }
    );

    if (txError) {
      return new Response(
        JSON.stringify({ error: "Transaction failed", detail: txError.message }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ ok: true, result: outcome.result, outcome, tx: txResult }),
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