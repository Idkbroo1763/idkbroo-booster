import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { storeAndForwardEvent } from "../_shared/backend-logger.ts";

const headers = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
const reply = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });

Deno.serve(async (request) => {
  if (request.method !== "POST") return reply(405, { ok: false, code: "METHOD_NOT_ALLOWED" });
  const configuredKey = Deno.env.get("SOUNDLIFT_ADMIN_API_KEY") ?? "";
  const suppliedKey = request.headers.get("x-soundlift-admin-key") ?? "";
  if (configuredKey.length < 32 || suppliedKey !== configuredKey) return reply(401, { ok: false, code: "UNAUTHORIZED" });

  try {
    const body = await request.json();
    const action = String(body.action ?? "");
    const licenseId = String(body.license_id ?? "");
    const reason = String(body.reason ?? "").trim().slice(0, 200);
    if (action !== "detach_device" || !/^[a-f0-9-]{36}$/.test(licenseId) || reason.length < 3) return reply(400, { ok: false, code: "INVALID_REQUEST" });
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data, error } = await supabase.rpc("detach_soundlift_license", { p_license_id: licenseId, p_reason: reason });
    if (error) throw error;
    if (!data?.ok) return reply(404, { ok: false, code: data?.code ?? "NOT_FOUND" });
    await storeAndForwardEvent(supabase, {
      category: "license", event_name: "device_detached", severity: "warning", source: "admin", trusted: true,
      metadata: { license_ref: licenseId, license_type: data.license_type, device_ref: data.device_ref, reason },
    });
    return reply(200, { ok: true });
  } catch {
    return reply(500, { ok: false, code: "SERVER_ERROR" });
  }
});
