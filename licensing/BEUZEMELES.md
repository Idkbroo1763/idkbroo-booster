# SoundLift vásárlói licencrendszer – előkészítés

A nyilvános SoundLift build továbbra is `free` módban működik. A licenc csak a
`build-custom-windows.ps1` használatával készített vásárlói EXE-ben kapcsol be.

## Egyszeri Supabase-beállítás

1. Készíts külön Supabase-projektet a SoundLifthez.
2. A SQL Editorban futtasd a `supabase-schema.sql` tartalmát.
3. Telepítsd a `verify-license` Edge Functiont. A service-role kulcs kizárólag a
   Supabase Function titkos környezetében maradhat; soha ne kerüljön az EXE-be.
4. A funkcióhoz használt publikus anon kulcs beépíthető a kliensbe. Ez nem ad
   közvetlen hozzáférést a licenctáblához, mert az RLS és a jogosultságok tiltják.

## Első termék létrehozása

```sql
insert into public.license_products(product_id, name)
values ('soundlift-custom', 'SoundLift Custom');
```

## Licenckulcs készítése

Készíts legalább 128 bit véletlen adatból kulcsot, például PowerShellben:

```powershell
$bytes = [byte[]]::new(16)
[Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$key = 'SL-' + ([Convert]::ToHexString($bytes))
$hash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-','').ToLowerInvariant()
"Kulcs a vásárlónak: $key"
"Adatbázisba kerülő hash: $hash"
```

Ezután a hash kerüljön az adatbázisba; a nyers kulcsot csak a vásárló kapja:

```sql
insert into public.licenses(product_id, key_hash, customer_name, customer_discord_id)
select id, 'A_GENERALT_64_KARAKTERES_HASH', 'Vásárló neve', 'Discord user ID'
from public.license_products where product_id = 'soundlift-custom';
```

## Vásárlói build

Állítsd be a három környezeti változót, majd futtasd a buildet:

```powershell
$env:SOUNDLIFT_LICENSE_API_URL='https://PROJECT.supabase.co/functions/v1/verify-license'
$env:SOUNDLIFT_LICENSE_PRODUCT_ID='soundlift-custom'
$env:SOUNDLIFT_LICENSE_ANON_KEY='A_SUPABASE_ANON_KULCS'
.\build-custom-windows.ps1
```

Az elkészült fájl: `dist-custom\SoundLift Custom.exe`.

## Áthelyezés új számítógépre

Ellenőrizd a vásárló Discord-azonosítóját, majd a Supabase SQL Editorban futtasd:

```sql
update public.licenses
set device_id = null, activated_at = null,
    transfer_count = transfer_count + 1, last_transfer_at = now()
where id = 'LICENSE_UUID' and status = 'active';
```

Ezután ugyanazt a kulcsot beírhatja az új gépen. Javasolt szabály: automatikus
áthelyezés legfeljebb 30 naponta, gyakoribb csere csak ellenőrzött hibajeggyel.

## Biztonsági korlát

Egy kliensoldali program védelme megnehezíti a jogosulatlan használatot, de nem
teszi matematikailag lehetetlenné a feltörést vagy az EXE továbbküldését. A
service-role kulcsot és a teljes licenclistát ezért mindig szerveroldalon kell tartani.
