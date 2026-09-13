import { authenticateInstallation } from "../_shared/installation-auth.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const reply = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });
const supportId = (id: string) => `SL-${id.replaceAll("-", "").slice(0, 8).toUpperCase()}`;

Deno.serve(async (request) => {
  if (request.method !== "POST") return reply(405, { error: "METHOD_NOT_ALLOWED" });
  try {
    const body = await request.json();
    const installationId = String(body.installation_id ?? "").trim().toLowerCase();
    if (!uuidPattern.test(installationId)) return reply(400, { error: "INVALID_INSTALLATION" });
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
    if (!await authenticateInstallation(supabase, installationId, String(body.installation_proof ?? ""), true)) return reply(403, { error: "INVALID_INSTALLATION_PROOF" });
    const { data, error } = await supabase.from("soundlift_installation_links").select("installation_id").eq("installation_id", installationId).is("revoked_at", null).maybeSingle();
    if (error) throw error;
    if (data) await supabase.from("soundlift_installation_links").update({ last_verified_at: new Date().toISOString() }).eq("installation_id", installationId);
    return reply(200, { linked: Boolean(data), support_id: supportId(installationId) });
  } catch {
    return reply(500, { error: "SERVER_ERROR" });
  }
});
