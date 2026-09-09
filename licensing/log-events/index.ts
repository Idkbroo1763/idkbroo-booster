import { authenticateInstallation } from "../_shared/installation-auth.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { storeAndForwardEvent, type BackendLogEvent } from "../_shared/backend-logger.ts";

const responseHeaders = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
const categories = new Set(["startup", "crash", "update", "license", "security", "developer_access"]);
const severities = new Set(["debug", "info", "warning", "error", "critical"]);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const clientEvents = new Set([
  "process_started", "initialization_succeeded", "initialization_failed", "startup_crash", "unhandled_runtime_error", "handled_runtime_error",
  "update_check_started", "update_check_succeeded", "update_check_failed", "update_available", "download_page_opened", "version_changed", "update_install_started", "update_install_failed",
  "activation_cancelled", "activation_succeeded", "validation_succeeded", "validation_failed", "validation_unavailable", "offline_grace_used",
  "license_rejected", "developer_license_used",
  "discord_link_required", "discord_link_succeeded", "discord_link_cancelled", "discord_link_check_failed", "discord_link_offline_grace_used",
]);

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}

function clean(value: unknown, max: number) {
  const text = String(value ?? "").replace(/[\u0000-\u001f]/g, " ").trim();
  return text.slice(0, max);
}

function cleanMetadata(input: unknown) {
  const allowed = new Set(["packaged", "stage", "component", "old_version", "new_version", "current_version", "result", "code", "license_type", "grace_hours", "authorization_id", "exception_type", "message", "script_stack"]);
  const output: Record<string, string> = {};
  if (!input || typeof input !== "object" || Array.isArray(input)) return output;
  for (const [key, value] of Object.entries(input as Record<string, unknown>)) {
    if (allowed.has(key)) output[key] = clean(value, key === "script_stack" ? 1600 : 900);
  }
  return output;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return reply(405, { error: "METHOD_NOT_ALLOWED" });
  const length = Number.parseInt(request.headers.get("content-length") ?? "0", 10);
  if (Number.isFinite(length) && length > 65536) return reply(413, { error: "REQUEST_TOO_LARGE" });

  try {
    const body = await request.json();
    if (!Array.isArray(body.events) || body.events.length < 1 || body.events.length > 50) return reply(400, { error: "INVALID_BATCH" });
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });

    const installationId = clean(body.events[0]?.installation_id, 36);
    if (!uuidPattern.test(installationId)) return reply(400, { error: "INVALID_INSTALLATION" });
    const supportId = `SL-${installationId.replaceAll("-", "").slice(0, 8).toUpperCase()}`;
    const ownsInstallation = await authenticateInstallation(supabase, installationId, request.headers.get("x-soundlift-installation-proof") ?? "");
    const { data: claimedUser } = await supabase.from("soundlift_installation_links").select("discord_user_id,discord_username,discord_global_name").eq("installation_id", installationId).is("revoked_at", null).maybeSingle();
    const linkedUser = ownsInstallation ? claimedUser : null;
    const since = new Date(Date.now() - 60_000).toISOString();
    const { count } = await supabase.from("app_log_events").select("id", { count: "exact", head: true }).eq("installation_id", installationId).gte("received_at", since);
    if ((count ?? 0) >= 100) return reply(429, { error: "RATE_LIMITED" });

    let accepted = 0;
    for (const raw of body.events) {
      const category = clean(raw.category, 40);
      const eventName = clean(raw.event_name, 80);
      const severity = clean(raw.severity, 20);
      const eventId = clean(raw.event_id, 36);
      const timestamp = clean(raw.timestamp_utc, 40);
      const occurred = Date.parse(timestamp);
      if (!categories.has(category) || !clientEvents.has(eventName) || !severities.has(severity) || !uuidPattern.test(eventId) || Number.isNaN(occurred) || Math.abs(Date.now() - occurred) > 7 * 86400_000) continue;
      const event: BackendLogEvent = {
        event_id: eventId,
        timestamp_utc: timestamp,
        category: category as BackendLogEvent["category"],
        event_name: eventName,
        severity: severity as BackendLogEvent["severity"],
        app_version: clean(raw.app_version, 24),
        installation_id: installationId,
        license_mode: clean(raw.license_mode, 16),
        product_id: clean(raw.product_id, 64),
        source: "client",
        trusted: false,
        metadata: {
          support_id: supportId,
          discord_user: linkedUser?.discord_user_id ? `<@${linkedUser.discord_user_id}>` : "nincs összekapcsolva",
          discord_name: clean(linkedUser?.discord_global_name || linkedUser?.discord_username || "ismeretlen", 80),
          ...cleanMetadata(raw.data),
        },
      };
      await storeAndForwardEvent(supabase, event);
      accepted++;
    }
    return reply(200, { accepted });
  } catch {
    return reply(500, { error: "SERVER_ERROR" });
  }
});
