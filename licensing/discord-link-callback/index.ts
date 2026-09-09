import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { storeAndForwardEvent } from "../_shared/backend-logger.ts";

const htmlHeaders = { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer", "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'" };
const page = (ok: boolean, message: string, status = 200) => new Response(`<!doctype html><meta charset="utf-8"><title>SoundLift</title><style>body{font-family:Segoe UI,sans-serif;background:#09090b;color:#f8fafc;display:grid;place-items:center;height:100vh;margin:0}.box{max-width:560px;padding:36px;border:1px solid #27272a;border-radius:18px;background:#18181b;text-align:center}h1{color:${ok ? "#22c55e" : "#ef4444"}}</style><div class="box"><h1>${ok ? "Sikeres összekapcsolás" : "Az összekapcsolás sikertelen"}</h1><p>${message}</p><p>Most visszatérhetsz a SoundLift alkalmazásba.</p></div>`, { status, headers: htmlHeaders });

async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

const supportId = (id: string) => `SL-${id.replaceAll("-", "").slice(0, 8).toUpperCase()}`;

Deno.serve(async (request) => {
  if (request.method !== "GET") return page(false, "Érvénytelen kérés.", 405);
  try {
    const url = new URL(request.url);
    const code = url.searchParams.get("code") ?? "";
    const state = url.searchParams.get("state") ?? "";
    if (code.length < 8 || state.length < 32) return page(false, "Hiányzó vagy érvénytelen Discord-válasz.", 400);

    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: session, error: sessionError } = await supabase.from("soundlift_link_sessions").select("id,installation_id,expires_at,used_at").eq("state_hash", await sha256(state)).maybeSingle();
    if (sessionError || !session || session.used_at || Date.parse(session.expires_at) < Date.now()) return page(false, "A kapcsolókód lejárt vagy már fel lett használva.", 400);

    const clientId = Deno.env.get("DISCORD_CLIENT_ID") ?? "";
    const clientSecret = Deno.env.get("DISCORD_CLIENT_SECRET") ?? "";
    const redirectUri = Deno.env.get("DISCORD_REDIRECT_URI") ?? "";
    const form = new URLSearchParams({ client_id: clientId, client_secret: clientSecret, grant_type: "authorization_code", code, redirect_uri: redirectUri });
    const tokenResponse = await fetch("https://discord.com/api/oauth2/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: form });
    if (!tokenResponse.ok) return page(false, "A Discord nem fogadta el az engedélyezést.", 400);
    const token = await tokenResponse.json();
    const userResponse = await fetch("https://discord.com/api/users/@me", { headers: { authorization: `Bearer ${token.access_token}` } });
    if (!userResponse.ok) return page(false, "A Discord-fiók nem olvasható.", 400);
    const user = await userResponse.json();
    const discordId = String(user.id ?? "");
    if (!/^\d{15,25}$/.test(discordId)) return page(false, "Érvénytelen Discord-fiók.", 400);

    const { data: completed, error: linkError } = await supabase.rpc("complete_soundlift_discord_link", {
      p_session_id: session.id, p_discord_id: discordId,
      p_username: String(user.username ?? ""), p_global_name: String(user.global_name ?? "")
    });
    if (linkError) throw linkError;
    if (!completed) return page(false, "A kapcsolat már fel lett használva vagy másik fiókhoz tartozik.", 409);
    await storeAndForwardEvent(supabase, { category: "security", event_name: "discord_account_linked", severity: "info", installation_id: session.installation_id, source: "backend", trusted: true, metadata: { support_id: supportId(session.installation_id), discord_user: `<@${discordId}>`, discord_name: String(user.global_name || user.username || "ismeretlen").slice(0, 80) } });
    return page(true, "A Discord-fiókod sikeresen hozzá lett kapcsolva ehhez a SoundLift-telepítéshez.");
  } catch {
    return page(false, "Átmeneti szerverhiba történt. Próbáld újra később.", 500);
  }
});
