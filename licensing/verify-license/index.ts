import { authenticateInstallation } from "../_shared/installation-auth.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { storeAndForwardEvent } from "../_shared/backend-logger.ts";

const headers = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
};
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers });
}

async function sha256(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return reply(405, { allowed: false, message: "Method not allowed." });
  const contentLength = Number.parseInt(request.headers.get("content-length") ?? "0", 10);
  if (Number.isFinite(contentLength) && contentLength > 4096) return reply(413, { allowed: false, message: "Request too large." });

  try {
    const body = await request.json();
    const licenseKey = String(body.license_key ?? "").trim();
    const productId = String(body.product_id ?? "").trim();
    const deviceId = String(body.device_id ?? "").trim().toLowerCase();
    const installationId = String(body.installation_id ?? "").trim().toLowerCase();
    if (licenseKey.length < 24 || licenseKey.length > 160 || !/^[a-f0-9]{64}$/.test(deviceId) || !/^[a-z0-9][a-z0-9_-]{2,63}$/.test(productId) || !uuidPattern.test(installationId)) {
      return reply(400, { allowed: false, code: "INVALID_REQUEST", message: "Érvénytelen licenckérés." });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false, autoRefreshToken: false } },
    );
    if (!await authenticateInstallation(supabase, installationId, String(body.installation_proof ?? ""))) return reply(403, {allowed:false, code:"INVALID_INSTALLATION_PROOF"});
    const { data: linkedUser, error: linkError } = await supabase.from("soundlift_installation_links").select("discord_user_id,discord_username,discord_global_name").eq("installation_id", installationId).is("revoked_at", null).maybeSingle();
    if (linkError) throw linkError;
    if (!linkedUser) {
      await storeAndForwardEvent(supabase, { category: "security", event_name: "license_without_discord_link", severity: "warning", installation_id: installationId, product_id: productId, source: "backend", trusted: true, metadata: { support_id: `SL-${installationId.replaceAll("-", "").slice(0, 8).toUpperCase()}` } });
      return reply(403, { allowed: false, code: "DISCORD_LINK_REQUIRED", message: "A licenc használatához előbb kapcsold össze a Discord-fiókodat." });
    }
    const keyHash = await sha256(licenseKey);
    const { data, error } = await supabase.rpc("activate_soundlift_license", {
      p_key_hash: keyHash,
      p_product_code: productId,
      p_device_id: deviceId,
    });
    if (error) throw error;
    const allowed = data?.allowed === true;
    const rejectedCode = String(data?.code ?? "UNKNOWN");
    const isSecurity = !allowed && ["INVALID_LICENSE", "LICENSE_BLOCKED", "LICENSE_EXPIRED", "DEVICE_LIMIT"].includes(rejectedCode);
    const eventName = allowed ? String(data.activation_event ?? "validated") : "license_rejected";
    await storeAndForwardEvent(supabase, {
      category: data?.license_type === "developer" && allowed ? "developer_access" : isSecurity ? "security" : "license",
      event_name: data?.license_type === "developer" && allowed ? "developer_license_authorized" : eventName,
      severity: allowed ? (data?.license_type === "developer" ? "warning" : "info") : "warning",
      product_id: productId,
      installation_id: installationId,
      source: "backend",
      trusted: true,
      metadata: {
        support_id: `SL-${installationId.replaceAll("-", "").slice(0, 8).toUpperCase()}`,
        discord_user: `<@${linkedUser.discord_user_id}>`,
        discord_name: String(linkedUser.discord_global_name || linkedUser.discord_username || "ismeretlen").slice(0, 80),
        code: rejectedCode,
        license_type: data?.license_type ?? "unknown",
        license_ref: data?.internal_license_id ?? `unknown-${keyHash.slice(0, 12)}`,
        device_ref: deviceId.slice(0, 12),
      },
    });
    const publicData = { ...data };
    delete publicData.internal_license_id;
    delete publicData.activation_event;
    return reply(allowed ? 200 : 403, publicData);
  } catch (error) {
    try {
      const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
      await storeAndForwardEvent(supabase, { category: "license", event_name: "license_backend_error", severity: "error", source: "backend", trusted: true, metadata: { error_type: error instanceof Error ? error.name : "unknown" } });
    } catch { /* A válasz akkor is titokmentes marad, ha a naplózás sem érhető el. */ }
    return reply(500, { allowed: false, code: "SERVER_ERROR", message: "A licencellenőrzés átmenetileg nem érhető el." });
  }
});
