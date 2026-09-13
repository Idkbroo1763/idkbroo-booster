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
    const featureKey = String(body.feature_key ?? "").trim().toLowerCase();
    const featureName = String(body.display_name ?? "").trim().slice(0,80);
    const featurePattern = /^[a-z][a-z0-9_]{2,63}$/;
    const licensePattern = /^[a-f0-9-]{36}$/;
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
    if (action === "detach_device") {
      if (!licensePattern.test(licenseId) || reason.length < 3) return reply(400,{ok:false,code:"INVALID_REQUEST"});
      const { data, error } = await supabase.rpc("detach_soundlift_license", { p_license_id: licenseId, p_reason: reason });
      if (error) throw error;
      if (!data?.ok) return reply(404, { ok: false, code: data?.code ?? "NOT_FOUND" });
      await storeAndForwardEvent(supabase, { category:"license",event_name:"device_detached",severity:"warning",source:"admin",trusted:true,metadata:{license_ref:licenseId,license_type:data.license_type,device_ref:data.device_ref,reason} });
      return reply(200,{ok:true});
    }
    if (action === "upsert_feature") {
      if (!featurePattern.test(featureKey) || !featureName) return reply(400,{ok:false,code:"INVALID_REQUEST"});
      const { error } = await supabase.from("soundlift_features").upsert({feature_key:featureKey,display_name:featureName,description:String(body.description ?? "").slice(0,500),active:true},{onConflict:"feature_key"});
      if (error) throw error;
      return reply(200,{ok:true});
    }
    if (action === "set_license_feature") {
      if (!licensePattern.test(licenseId) || !featurePattern.test(featureKey)) return reply(400,{ok:false,code:"INVALID_REQUEST"});
      const { data:feature,error:featureError } = await supabase.from("soundlift_features").select("id").eq("feature_key",featureKey).eq("active",true).maybeSingle();
      if (featureError) throw featureError;
      if (!feature) return reply(404,{ok:false,code:"FEATURE_NOT_FOUND"});
      const enabled = body.enabled !== false;
      const config = body.config && typeof body.config === "object" && !Array.isArray(body.config) ? body.config : {};
      const { error } = await supabase.from("soundlift_license_features").upsert({license_id:licenseId,feature_id:feature.id,enabled,config},{onConflict:"license_id,feature_id"});
      if (error) throw error;
      await storeAndForwardEvent(supabase,{category:"license",event_name:"license_feature_changed",severity:"warning",source:"admin",trusted:true,metadata:{license_ref:licenseId,feature_key:featureKey,enabled}});
      return reply(200,{ok:true});
    }
    if (action === "set_owner") {
      if (!licensePattern.test(licenseId) || typeof body.enabled !== "boolean") return reply(400,{ok:false,code:"INVALID_REQUEST"});
      const { error } = await supabase.from("licenses").update({is_owner:body.enabled}).eq("id",licenseId);
      if (error) throw error;
      await storeAndForwardEvent(supabase,{category:"developer_access",event_name:"owner_permission_changed",severity:"critical",source:"admin",trusted:true,metadata:{license_ref:licenseId,enabled:body.enabled}});
      return reply(200,{ok:true});
    }
    return reply(400,{ok:false,code:"INVALID_ACTION"});
  } catch {
    return reply(500, { ok: false, code: "SERVER_ERROR" });
  }
});
