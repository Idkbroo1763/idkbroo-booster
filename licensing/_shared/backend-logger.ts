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
  const text = repairMojibake(String(value ?? ""))
    .replace(/https?:\/\/[^\s]+/gi, "[URL]")
    .replace(/\b(?:SL-[A-Z0-9-]{12,}|[A-F0-9]{32,})\b/gi, "[REDACTED]");
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

function repairMojibake(input: string) {
  if (!/[ÃÂâ€žœž™š]/.test(input)) return input;
  const windows1252: Record<number, number> = {
    0x20ac: 0x80, 0x201a: 0x82, 0x0192: 0x83, 0x201e: 0x84, 0x2026: 0x85,
    0x2020: 0x86, 0x2021: 0x87, 0x02c6: 0x88, 0x2030: 0x89, 0x0160: 0x8a,
    0x2039: 0x8b, 0x0152: 0x8c, 0x017d: 0x8e, 0x2018: 0x91, 0x2019: 0x92,
    0x201c: 0x93, 0x201d: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97,
    0x02dc: 0x98, 0x2122: 0x99, 0x0161: 0x9a, 0x203a: 0x9b, 0x0153: 0x9c,
    0x017e: 0x9e, 0x0178: 0x9f,
  };
  try {
    const bytes = Uint8Array.from([...input].map((character) => {
      const code = character.codePointAt(0)!;
      return windows1252[code] ?? (code <= 0xff ? code : 0x3f);
    }));
    const decoded = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return decoded.includes("�") ? input : decoded;
  } catch {
    return input;
  }
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
