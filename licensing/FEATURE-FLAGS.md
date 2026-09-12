# SoundLift licencenkénti funkciók és Owner tesztmód

## Mit valósít meg

A V1.3.16-tól minden vásárló ugyanazt a hivatalos SoundLift buildet használja. A `verify-license` Edge Function a licenckulcs, a gépazonosító, a telepítési bizonyíték és a kapcsolt Discord-fiók ellenőrzése után adja vissza az adott licenchez rendelt funkciókat.

Az adatmodell:

- `soundlift_features`: a kiadható funkciók katalógusa;
- `soundlift_license_features`: több-a-többhöz kapcsolat a licencek és funkciók között, opcionális JSON-konfigurációval;
- `licenses.is_owner`: külön, alapértelmezetten kikapcsolt Owner jogosultság.

A korábbi licencek automatikusan nulla extra funkcióval és `is_owner=false` értékkel működnek tovább.

## Telepítés

1. Futtasd le a `licensing/supabase-schema.sql` teljes tartalmát a Supabase SQL Editorban.
2. Telepítsd újra a két módosított Edge Functiont:

```powershell
npx.cmd supabase functions deploy verify-license --project-ref SAJAT_PROJECT_REF --no-verify-jwt
npx.cmd supabase functions deploy admin-license-action --project-ref SAJAT_PROJECT_REF --no-verify-jwt
```

3. Az admin végpont titka maradjon kizárólag a Supabase secretben és a saját admin környezetedben: `SOUNDLIFT_ADMIN_API_KEY`. Soha ne kerüljön az alkalmazásba vagy a GitHub repositoryba.

## Új licenc funkciókkal

```powershell
.\licensing\New-SoundLiftLicense.ps1 -ProductId soundlift-custom -CustomerName Pisti -DiscordId 111111111111111111 -Features extra_bass_pro
.\licensing\New-SoundLiftLicense.ps1 -ProductId soundlift-custom -CustomerName Gabor -DiscordId 222222222222222222 -Features voice_boost,custom_preset_x
```

A parancs csak SQL-t és egyszer megjelenített nyers kulcsot készít. A nyers kulcsot kizárólag a vásárlónak add át.

## Funkció kezelése meglévő licencen

```powershell
.\licensing\Invoke-SoundLiftLicenseAdmin.ps1 -Action set_license_feature -LicenseId LICENC_UUID -FeatureKey extra_bass_pro -Enabled $true
.\licensing\Invoke-SoundLiftLicenseAdmin.ps1 -Action set_license_feature -LicenseId LICENC_UUID -FeatureKey extra_bass_pro -Enabled $false
```

Új feature-kulcs felvétele:

```powershell
.\licensing\Invoke-SoundLiftLicenseAdmin.ps1 -Action upsert_feature -FeatureKey studio_voice_x -DisplayName 'Studio Voice X' -Description 'Egyedi stúdióhang-profil.'
```

Az új kulcshoz kliensoldali megjelenítést és működést is implementálni kell egy későbbi közös buildben. Ismeretlen kulcs nem hoz létre önállóan végrehajtható kódot.

## Owner jogosultság

Először készíts egy `developer` típusú saját licencet, majd egyszer engedélyezd rajta az Ownert:

```powershell
.\licensing\Invoke-SoundLiftLicenseAdmin.ps1 -Action set_owner -LicenseId SAJAT_LICENC_UUID -Enabled $true
```

Ezután a kliensben megjelenik az **Owner tesztmód**. A listából választható a normál saját jogosultság vagy egy aktív licenc. A backend kizárólag annak feature-listáját adja vissza; nem adja át a céllicenc kulcsát, gépazonosítóját vagy Discord-adatait, és nem jelentkezik be a vásárló fiókjába.

## Biztonsági határok

- A normál kliens nem olvashatja közvetlenül a licenc- és feature-táblákat; az RLS aktív, az `anon` és `authenticated` szerepek jogai vissza vannak vonva.
- A Discord-azonosítóval rendelkező licenc csak a hozzá rendelt, hitelesítetten kapcsolt Discord-fiókkal aktiválható.
- Más licenc szimulációját és a céllistát a backend csak `is_owner=true` licencnek adja.
- Feature-t csak a titkos admin végpont rendelhet licenchez.
- A kliens a szervertől kapott kulcsokat csak ismert, beépített funkciók megjelenítésére használja.
- Egy asztali kliens binárisa elméletileg módosítható, ezért minden jövőbeli szerveroldali/prémium műveletnek a backendben is újra ellenőriznie kell a feature flaget. A helyi UI-elrejtés önmagában nem biztonsági határ.

## Pisti/Gábor ellenőrzés

A `licensing/tests/feature-flags.sql` tranzakción belül létrehoz két tesztlicencet, Pistihez csak `extra_bass_pro`, Gáborhoz csak `voice_boost` jogot rendel, ellenőrzi az elkülönítést, majd `rollback` segítségével mindent visszavon. A GitHub Actions emellett a `tests/feature-flags.ps1` statikus biztonsági és bekötési tesztet futtatja.
