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

alter table public.licenses
  add column if not exists is_owner boolean not null default false;

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

-- Hitelesitett Discord-fiok hozzarendelese egy SoundLift-telepiteshez.
-- A teljes installation_id csak a backendben marad; Discordon rovid support ID jelenik meg.
create table if not exists public.soundlift_installation_links (
  installation_id uuid primary key,
  discord_user_id text not null check (discord_user_id ~ '^[0-9]{15,25}$'),
  discord_username text,
  discord_global_name text,
  linked_at timestamptz not null default now(),
  last_verified_at timestamptz not null default now(),
  revoked_at timestamptz
);

create index if not exists soundlift_installation_links_discord_idx
  on public.soundlift_installation_links(discord_user_id);

-- Egyszer hasznalhato, rovid eletu OAuth allapotok. Nyers state soha nem tarolodik.
create table if not exists public.soundlift_link_sessions (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  state_hash text not null unique check (length(state_hash) = 64),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);

create index if not exists soundlift_link_sessions_installation_idx
  on public.soundlift_link_sessions(installation_id, created_at desc);

create index if not exists app_log_events_installation_received_idx
  on public.app_log_events(installation_id, received_at desc);
create index if not exists app_log_events_category_received_idx
  on public.app_log_events(category, received_at desc);

alter table public.license_products enable row level security;
alter table public.licenses enable row level security;
alter table public.license_events enable row level security;
alter table public.app_log_events enable row level security;
alter table public.soundlift_installation_links enable row level security;
alter table public.soundlift_link_sessions enable row level security;

revoke all on public.license_products, public.licenses, public.license_events, public.app_log_events from anon, authenticated;
revoke all on public.soundlift_installation_links, public.soundlift_link_sessions from anon, authenticated;

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

-- V1.3.16: a Discord-azonossag ellenorzott licencaktivacioja. A regi harom
-- parameteres RPC megmarad a korabbi telepitesek kompatibilitasa miatt, az uj
-- kliens azonban kizarolag ezt a valtozatot hasznalja.
create or replace function public.activate_soundlift_license(
  p_key_hash text, p_product_code text, p_device_id text, p_discord_id text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.licenses%rowtype;
  activation_kind text;
begin
  if length(p_key_hash) <> 64 or length(p_device_id) <> 64 or p_discord_id !~ '^[0-9]{15,25}$' then
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
  if target.customer_discord_id is not null and target.customer_discord_id <> p_discord_id then
    return jsonb_build_object('allowed', false, 'code', 'DISCORD_ACCOUNT_MISMATCH', 'message', 'Ez a licenc egy másik Discord-fiókhoz tartozik.');
  end if;
  if target.device_id is not null and target.device_id <> p_device_id then
    return jsonb_build_object('allowed', false, 'code', 'DEVICE_LIMIT', 'message', 'A licenc már egy másik számítógéphez tartozik. Áthelyezéshez nyiss hibajegyet.');
  end if;

  activation_kind := case
    when target.device_id is null and target.transfer_count > 0 then 'device_attached_after_transfer'
    when target.device_id is null then 'activated'
    else 'validated'
  end;
  update public.licenses set device_id=coalesce(device_id,p_device_id), activated_at=coalesce(activated_at,now()), last_seen_at=now() where id=target.id;
  insert into public.license_events(license_id,event_type,device_id) values(target.id,activation_kind,p_device_id);
  return jsonb_build_object(
    'allowed',true,'code','OK','message','A licenc érvényes.',
    'license_type',target.license_type,'is_owner',target.is_owner,
    'internal_license_id',target.id,'activation_event',activation_kind
  );
end;
$$;
revoke all on function public.activate_soundlift_license(text,text,text,text) from public,anon,authenticated;
grant execute on function public.activate_soundlift_license(text,text,text,text) to service_role;

-- Egyetlen kozos kliensben hasznalhato, backend-altal kiosztott funkciok.
create table if not exists public.soundlift_features (
  id uuid primary key default gen_random_uuid(),
  feature_key text not null unique check (feature_key ~ '^[a-z][a-z0-9_]{2,63}$'),
  display_name text not null check (length(display_name) between 1 and 80),
  description text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.soundlift_license_features (
  license_id uuid not null references public.licenses(id) on delete cascade,
  feature_id uuid not null references public.soundlift_features(id) on delete restrict,
  enabled boolean not null default true,
  config jsonb not null default '{}'::jsonb,
  assigned_at timestamptz not null default now(),
  primary key (license_id,feature_id),
  check (jsonb_typeof(config) = 'object')
);

create index if not exists soundlift_license_features_license_idx on public.soundlift_license_features(license_id);
alter table public.soundlift_features enable row level security;
alter table public.soundlift_license_features enable row level security;
revoke all on public.soundlift_features,public.soundlift_license_features from public,anon,authenticated;

create or replace function public.get_soundlift_license_features(p_license_id uuid)
returns table(feature_key text,display_name text,config jsonb)
language sql stable security definer set search_path=public
as $$
  select f.feature_key,f.display_name,lf.config
  from public.soundlift_license_features lf
  join public.soundlift_features f on f.id=lf.feature_id
  join public.licenses l on l.id=lf.license_id
  where lf.license_id=p_license_id and lf.enabled=true and f.active=true and l.status='active'
  order by f.feature_key;
$$;
revoke all on function public.get_soundlift_license_features(uuid) from public,anon,authenticated;
grant execute on function public.get_soundlift_license_features(uuid) to service_role;

insert into public.soundlift_features(feature_key,display_name,description) values
  ('extra_bass_pro','Extra Bass Pro','Prémium, erőteljes mélyhangprofil.'),
  ('voice_boost','Voice Boost','Beszédhang-kiemelő profil.'),
  ('custom_preset_x','Custom Preset X','Egyedi, licenchez rendelt hangprofil.')
on conflict(feature_key) do update set display_name=excluded.display_name,description=excluded.description;

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

create table if not exists public.soundlift_installation_credentials (
 installation_id uuid primary key,
 proof_hash text not null check (proof_hash ~ '^[a-f0-9]{64}$'),
 created_at timestamptz not null default now()
);
alter table public.soundlift_installation_credentials enable row level security;
revoke all on public.soundlift_installation_credentials from public, anon, authenticated;
revoke all on public.soundlift_installation_links, public.soundlift_link_sessions from public;

create or replace function public.complete_soundlift_discord_link(
 p_session_id uuid, p_discord_id text, p_username text, p_global_name text
) returns boolean language plpgsql security definer set search_path=public as $$
declare s public.soundlift_link_sessions%rowtype;
begin
 select * into s from public.soundlift_link_sessions where id=p_session_id for update;
 if not found or s.used_at is not null or s.expires_at <= now() then return false; end if;
 if p_discord_id !~ '^[0-9]{15,25}$' then return false; end if;
 -- A second pending OAuth session cannot replace an established identity.
 insert into public.soundlift_installation_links(installation_id,discord_user_id,discord_username,discord_global_name)
 values(s.installation_id,p_discord_id,left(p_username,80),left(p_global_name,80))
 on conflict(installation_id) do nothing;
 update public.soundlift_link_sessions set used_at=now() where installation_id=s.installation_id and used_at is null;
 return exists(select 1 from public.soundlift_installation_links where installation_id=s.installation_id and discord_user_id=p_discord_id and revoked_at is null);
end;
$$;
revoke all on function public.complete_soundlift_discord_link(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.complete_soundlift_discord_link(uuid,text,text,text) to service_role;
