# SoundLift egységes licencrendszer – előkészítés

A V1.3.0-tól egyetlen univerzális SoundLift telepítő készül. Az alkalmazás
alapból ingyenes módban indul, a vásárló pedig közvetlenül a felületen írhatja
be az `SL-...` kulcsát. Ugyanez az EXE kezeli a `customer` és `developer`
jogosultságot, ezért frissítésenként nem kell külön vásárlói buildet készíteni.

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

Készíts legalább 128 bit véletlen adatból kulcsot a mellékelt, Windows
PowerShell 5.1-kompatibilis segédprogrammal:

```powershell
.\New-SoundLiftLicense.ps1 -ProductId 'soundlift-custom' `
  -CustomerName 'Vásárló neve' -DiscordId 'DISCORD_USER_ID' -Type customer
```

Ezután a hash kerüljön az adatbázisba; a nyers kulcsot csak a vásárló kapja:

```sql
insert into public.licenses(product_id, key_hash, customer_name, customer_discord_id)
select id, 'A_GENERALT_64_KARAKTERES_HASH', 'Vásárló neve', 'Discord user ID'
from public.license_products where product_id = 'soundlift-custom';
```

## Külön fejlesztői tesztlicenc

Minden vásárlói termékhez külön `developer` licencet használj. Ez ugyanahhoz a
`product_id` értékhez tartozik, ezért ugyanaz az EXE a te gépeden is tesztelhető.
A fejlesztői licenc külön adatbázissor és külön gépkapcsolat, ezért a vásárló
`customer` licence nem válik le.

```powershell
.\New-SoundLiftLicense.ps1 -ProductId 'soundlift-custom' `
  -CustomerName 'ɪᴅᴋʙʀᴏᴏ' -DiscordId 'SAJAT_DISCORD_ID' `
  -Type developer -ExpiresInDays 7
```

Javasolt szabályok:

- a vásárlói kulcs típusa mindig `customer`;
- a saját tesztkulcsod típusa `developer`;
- egy fejlesztői kulcs csak egyetlen vásárlói termékhez tartozzon;
- alapból 7 nap után járjon le;
- tesztelés után állítsd `revoked` állapotba;
- soha ne kerüljön univerzális mesterkulcs az alkalmazásba.

## Univerzális build

A GitHub Actions ugyanabból a `SOUNDLIFT_LOG_API_URL` és publikus
`SOUNDLIFT_LOG_ANON_KEY` beállításból konfigurálja a naplózást és a
licencellenőrzést. Az elkészült `SoundLift Setup.exe` mindenkinek ugyanaz.

A vásárló kizárólag a telepítőt és a neki létrehozott nyers `SL-...` kulcsot
kapja meg. PowerShellt, Supabase-t vagy külön buildet nem kell használnia.

## Áthelyezés új számítógépre

Ellenőrizd a vásárló Discord-azonosítóját, majd használd a naplózott admin
segédprogramot:

```powershell
$env:SOUNDLIFT_ADMIN_API_URL='https://PROJECT.supabase.co/functions/v1/admin-license-action'
$env:SOUNDLIFT_ADMIN_API_KEY='A_SAJAT_ADMIN_KULCSOD'
.\Invoke-SoundLiftLicenseAdmin.ps1 -Action detach_device `
  -LicenseId 'LICENSE_UUID' -Reason 'Ellenőrzött gépcsere'
```

Ezután ugyanazt a kulcsot beírhatja az új gépen. Javasolt szabály: automatikus
áthelyezés legfeljebb 30 naponta, gyakoribb csere csak ellenőrzött hibajeggyel.

## Biztonsági korlát

Egy kliensoldali program védelme megnehezíti a jogosulatlan használatot, de nem
teszi matematikailag lehetetlenné a feltörést vagy az EXE továbbküldését. A
service-role kulcsot és a teljes licenclistát ezért mindig szerveroldalon kell tartani.

A központi naplózás és a Discord webhookok beüzemelése a
`LOGGING-BEUZEMELES.md` fájlban található.
