import { authenticateInstallation } from "../_shared/installation-auth.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const jsonHeaders = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const reply = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers: jsonHeaders });

async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

function randomState() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function supportId(installationId: string) {
  return `SL-${installationId.replaceAll("-", "").slice(0, 8).toUpperCase()}`;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return reply(405, { error: "METHOD_NOT_ALLOWED" });
  try {
    const body = await request.json();
    const installationId = String(body.installation_id ?? "").trim().toLowerCase();
    if (!uuidPattern.test(installationId)) return reply(400, { error: "INVALID_INSTALLATION" });
    const clientId = Deno.env.get("DISCORD_CLIENT_ID") ?? "";
    const redirectUri = Deno.env.get("DISCORD_REDIRECT_URI") ?? "";
    if (!/^\d{15,25}$/.test(clientId) || !redirectUri.startsWith("https://")) return reply(503, { error: "DISCORD_NOT_CONFIGURED" });

    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
    if (!await authenticateInstallation(supabase, installationId, String(body.installation_proof ?? ""), true)) return reply(403, { error: "INVALID_INSTALLATION_PROOF" });
    const { data: existing } = await supabase.from("soundlift_installation_links").select("installation_id").eq("installation_id", installationId).is("revoked_at", null).maybeSingle();
    if (existing) return reply(200, { linked: true, support_id: supportId(installationId) });

    const since = new Date(Date.now() - 60_000).toISOString();
    const { count } = await supabase.from("soundlift_link_sessions").select("id", { count: "exact", head: true }).eq("installation_id", installationId).gte("created_at", since);
    if ((count ?? 0) >= 5) return reply(429, { error: "RATE_LIMITED" });

    const state = randomState();
    const { error } = await supabase.from("soundlift_link_sessions").insert({ installation_id: installationId, state_hash: await sha256(state), expires_at: new Date(Date.now() + 10 * 60_000).toISOString() });
    if (error) throw error;
    const authorize = new URL("https://discord.com/oauth2/authorize");
    authorize.searchParams.set("client_id", clientId);
    authorize.searchParams.set("response_type", "code");
    authorize.searchParams.set("redirect_uri", redirectUri);
    authorize.searchParams.set("scope", "identify");
    authorize.searchParams.set("state", state);
    authorize.searchParams.set("prompt", "consent");
    return reply(200, { linked: false, authorization_url: authorize.toString(), expires_in: 600, support_id: supportId(installationId) });
  } catch {
    return reply(500, { error: "SERVER_ERROR" });
  }
});
