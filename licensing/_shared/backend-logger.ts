type Severity = "debug" | "info" | "warning" | "error" | "critical";

export type BackendLogEvent = {
  event_id?: string;
  timestamp_utc?: string;
  category: "startup" | "crash" | "update" | "license" | "security" | "developer_access";
  event_name: string;
  severity: Severity;
  app_version?: string;
  installation_id?: string | null;
  license_mode?: string;
  product_id?: string | null;
  source: "client" | "backend" | "admin";
  trusted: boolean;
  metadata?: Record<string, unknown>;
};

const webhookNames: Record<BackendLogEvent["category"], string> = {
  startup: "DISCORD_LOG_WEBHOOK_STARTUP",
  crash: "DISCORD_LOG_WEBHOOK_CRASH",
  update: "DISCORD_LOG_WEBHOOK_UPDATE",
  license: "DISCORD_LOG_WEBHOOK_LICENSE",
  security: "DISCORD_LOG_WEBHOOK_SECURITY",
  developer_access: "DISCORD_LOG_WEBHOOK_DEVELOPER",
};

const colors: Record<Severity, number> = {
  debug: 0x64748b, info: 0x22c55e, warning: 0xf59e0b, error: 0xef4444, critical: 0x991b1b,
};

function clipped(value: unknown, limit = 900) {
  const text = String(value ?? "")
    .replace(/https?:\/\/[^\s]+/gi, "[URL]")
    .replace(/\b(?:SL-[A-Z0-9-]{12,}|[A-F0-9]{32,})\b/gi, "[REDACTED]");
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

export async function storeAndForwardEvent(supabase: any, event: BackendLogEvent): Promise<boolean> {
  const record = {
    event_id: event.event_id ?? crypto.randomUUID(),
    occurred_at: event.timestamp_utc ?? new Date().toISOString(),
    category: event.category,
    event_name: event.event_name,
    severity: event.severity,
    app_version: event.app_version ?? null,
    installation_id: event.installation_id || null,
    license_mode: event.license_mode ?? null,
    product_id: event.product_id || null,
    source: event.source,
    trusted: event.trusted,
    metadata: event.metadata ?? {},
    discord_forwarded: false,
  };

  const { error } = await supabase.from("app_log_events").insert(record);
  if (error && error.code !== "23505") throw error;
  if (error?.code === "23505") {
    const { data: existing } = await supabase.from("app_log_events").select("discord_forwarded").eq("event_id", record.event_id).maybeSingle();
    if (existing?.discord_forwarded === true) return true;
  }

  const webhook = Deno.env.get(webhookNames[event.category]) ?? Deno.env.get("DISCORD_LOG_WEBHOOK_DEFAULT");
  if (!webhook) return false;

  const fields = Object.entries(event.metadata ?? {}).slice(0, 8).map(([name, value]) => ({
    name: clipped(name, 80), value: clipped(value), inline: true,
  }));
  try {
    const response = await fetch(webhook, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        username: "SoundLift Logger",
        allowed_mentions: { parse: [] },
        embeds: [{
          title: `${event.category.toUpperCase()} · ${clipped(event.event_name, 100)}`,
          color: colors[event.severity],
          description: `Forrás: **${event.source}** · Megbízható: **${event.trusted ? "igen" : "nem"}**`,
          fields,
          footer: { text: `SoundLift ${clipped(event.app_version ?? "ismeretlen", 30)}` },
          timestamp: record.occurred_at,
        }],
      }),
    });
    if (response.ok) {
      await supabase.from("app_log_events").update({ discord_forwarded: true }).eq("event_id", record.event_id);
      return true;
    }
    return false;
  } catch {
    return false;
  }
}
