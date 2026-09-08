create extension if not exists pgcrypto;

create table if not exists public.license_products (
  id uuid primary key default gen_random_uuid(),
  product_id text not null unique check (product_id ~ '^[a-z0-9][a-z0-9_-]{2,63}$'),
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.licenses (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.license_products(id) on delete restrict,
  key_hash text not null unique check (length(key_hash) = 64),
  customer_name text,
  customer_discord_id text,
  license_type text not null default 'customer' check (license_type in ('customer','developer')),
  status text not null default 'active' check (status in ('active','revoked','suspended')),
  device_id text check (device_id is null or length(device_id) = 64),
  activated_at timestamptz,
  last_seen_at timestamptz,
  expires_at timestamptz,
  transfer_count integer not null default 0 check (transfer_count >= 0),
  last_transfer_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.licenses
  add column if not exists license_type text not null default 'customer';

do $$ begin
  alter table public.licenses add constraint licenses_license_type_check
    check (license_type in ('customer','developer'));
exception when duplicate_object then null;
end $$;

create table if not exists public.license_events (
  id bigint generated always as identity primary key,
  license_id uuid references public.licenses(id) on delete cascade,
  event_type text not null,
  device_id text,
  created_at timestamptz not null default now()
);

create table if not exists public.app_log_events (
  id bigint generated always as identity primary key,
  event_id uuid not null unique,
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  category text not null check (category in ('startup','crash','update','license','security','developer_access')),
  event_name text not null check (length(event_name) between 1 and 80),
  severity text not null check (severity in ('debug','info','warning','error','critical')),
  app_version text,
  installation_id uuid,
  license_mode text,
  product_id text,
  source text not null check (source in ('client','backend','admin')),
  trusted boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  discord_forwarded boolean not null default false
);

create index if not exists app_log_events_installation_received_idx
  on public.app_log_events(installation_id, received_at desc);
create index if not exists app_log_events_category_received_idx
  on public.app_log_events(category, received_at desc);

alter table public.license_products enable row level security;
alter table public.licenses enable row level security;
alter table public.license_events enable row level security;
alter table public.app_log_events enable row level security;

revoke all on public.license_products, public.licenses, public.license_events, public.app_log_events from anon, authenticated;

create or replace function public.activate_soundlift_license(p_key_hash text, p_product_code text, p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.licenses%rowtype;
begin
  if length(p_key_hash) <> 64 or length(p_device_id) <> 64 then
    return jsonb_build_object('allowed', false, 'code', 'INVALID_REQUEST', 'message', 'Érvénytelen licenckérés.');
  end if;

  select l.* into target
  from public.licenses l
  join public.license_products p on p.id = l.product_id
  where l.key_hash = p_key_hash and p.product_id = p_product_code and p.active = true
  for update of l;

  if not found then return jsonb_build_object('allowed', false, 'code', 'INVALID_LICENSE', 'message', 'A licenckulcs érvénytelen.'); end if;
  if target.status <> 'active' then return jsonb_build_object('allowed', false, 'code', 'LICENSE_BLOCKED', 'message', 'A licenc le van tiltva.'); end if;
  if target.expires_at is not null and target.expires_at <= now() then return jsonb_build_object('allowed', false, 'code', 'LICENSE_EXPIRED', 'message', 'A licenc lejárt.'); end if;
  if target.device_id is not null and target.device_id <> p_device_id then
    return jsonb_build_object('allowed', false, 'code', 'DEVICE_LIMIT', 'message', 'A licenc már egy másik számítógéphez tartozik. Áthelyezéshez nyiss hibajegyet.');
  end if;

  update public.licenses set
    device_id = coalesce(device_id, p_device_id),
    activated_at = coalesce(activated_at, now()),
    last_seen_at = now()
  where id = target.id;
  insert into public.license_events(license_id, event_type, device_id)
  values (target.id, case when target.device_id is null and target.transfer_count > 0 then 'device_attached_after_transfer' when target.device_id is null then 'activated' else 'validated' end, p_device_id);
  return jsonb_build_object(
    'allowed', true, 'code', 'OK', 'message', 'A licenc érvényes.',
    'license_type', target.license_type, 'internal_license_id', target.id,
    'activation_event', case when target.device_id is null and target.transfer_count > 0 then 'device_attached_after_transfer' when target.device_id is null then 'activated' else 'validated' end
  );
end;
$$;

revoke all on function public.activate_soundlift_license(text,text,text) from public, anon, authenticated;
grant execute on function public.activate_soundlift_license(text,text,text) to service_role;

create or replace function public.detach_soundlift_license(p_license_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare target public.licenses%rowtype;
begin
  select * into target from public.licenses where id = p_license_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'NOT_FOUND'); end if;
  update public.licenses set device_id = null, activated_at = null,
    transfer_count = transfer_count + 1, last_transfer_at = now()
  where id = target.id;
  insert into public.license_events(license_id, event_type, device_id)
  values (target.id, 'device_detached', target.device_id);
  return jsonb_build_object('ok', true, 'license_id', target.id, 'license_type', target.license_type,
    'device_ref', left(coalesce(target.device_id, ''), 12), 'reason', left(coalesce(p_reason, ''), 200));
end;
$$;

revoke all on function public.detach_soundlift_license(uuid,text) from public, anon, authenticated;
grant execute on function public.detach_soundlift_license(uuid,text) to service_role;

-- Gép leválasztásához az admin-license-action Edge Functiont használd, hogy a
-- művelet az adatbázisban és a Discordon is biztosan naplózva legyen.
