# SoundLift központi naplózás – beüzemelés

## Mit csinál a rendszer?

- A kliens a `%LOCALAPPDATA%\SoundLift\logs\` mappába ír napi NDJSON-naplókat.
- A helyi naplók 14 nap után automatikusan törlődnek.
- A sikertelenül küldött események a `pending-events.ndjson` fájlban maradnak,
  és a következő sikeres indításkor újra elküldésre kerülnek.
- A kliens kizárólag a publikus `log-events`, `discord-link-create` és
  `discord-link-status` Supabase Edge Functionökkel kommunikál. Discord webhook,
  OAuth client secret, bot token és service-role kulcs nincs az EXE-ben.
- A licencdöntések szerveroldali, `trusted=true` események. A kliensből érkező
  biztonsági események `trusted=false` jelölést kapnak.

Nem gyűjtünk Windows-felhasználónevet, e-mailt, nyers licenckulcsot, teljes
gépazonosítót, Discord-üzeneteket, szerverlistát vagy kattintási előzményt. A
kötelező, felhasználó által jóváhagyott Discord OAuth-kapcsolat a Discord user
ID-t és a megjelenített nevet tárolja, hogy a logok tulajdonosa azonosítható
legyen és támogatást lehessen adni.

## Discord-csatornák és webhookok

A meglévő kilépés- és ellenőrző log mellé hozd létre ezeket a csak vezetőség
által látható csatornákat:

| Csatorna | Supabase secret |
|---|---|
| `🚀・indítás-log` | `DISCORD_LOG_WEBHOOK_STARTUP` |
| `💥・hiba-crash-log` | `DISCORD_LOG_WEBHOOK_CRASH` |
| `🔄・frissítés-log` | `DISCORD_LOG_WEBHOOK_UPDATE` |
| `🔑・licenc-log` | `DISCORD_LOG_WEBHOOK_LICENSE` |
| `🛡️・biztonsági-log` | `DISCORD_LOG_WEBHOOK_SECURITY` |
| `🧑‍💻・fejlesztői-hozzáférés-log` | `DISCORD_LOG_WEBHOOK_DEVELOPER` |

Mindegyik csatornában: **Csatorna szerkesztése → Integrációk → Webhookok → Új
webhook → Webhook URL másolása**. A csatorna-ID-kre nincs szükség.

## Supabase telepítés

1. Futtasd újra a `supabase-schema.sql` teljes tartalmát a SQL Editorban.
2. A Supabase-projektben másold a `verify-license`, `log-events`,
   `admin-license-action`, `discord-link-create`, `discord-link-status`,
   `discord-link-callback` és `_shared` mappát a `supabase/functions/` alá, majd
   telepítsd az Edge Functionöket:

```powershell
supabase functions deploy log-events --no-verify-jwt
supabase functions deploy verify-license
supabase functions deploy admin-license-action --no-verify-jwt
supabase functions deploy discord-link-create --no-verify-jwt
supabase functions deploy discord-link-status --no-verify-jwt
supabase functions deploy discord-link-callback --no-verify-jwt
```

3. Állítsd be a webhookokat és egy legalább 32 karakteres véletlen admin kulcsot:

```powershell
supabase secrets set DISCORD_LOG_WEBHOOK_STARTUP='WEBHOOK_URL'
supabase secrets set DISCORD_LOG_WEBHOOK_CRASH='WEBHOOK_URL'
supabase secrets set DISCORD_LOG_WEBHOOK_UPDATE='WEBHOOK_URL'
supabase secrets set DISCORD_LOG_WEBHOOK_LICENSE='WEBHOOK_URL'
supabase secrets set DISCORD_LOG_WEBHOOK_SECURITY='WEBHOOK_URL'
supabase secrets set DISCORD_LOG_WEBHOOK_DEVELOPER='WEBHOOK_URL'
supabase secrets set SOUNDLIFT_ADMIN_API_KEY='LEGALABB_32_KARAKTERES_VELETLEN_ERTEK'
supabase secrets set DISCORD_CLIENT_ID='DISCORD_APPLICATION_ID'
supabase secrets set DISCORD_CLIENT_SECRET='DISCORD_OAUTH_CLIENT_SECRET'
supabase secrets set DISCORD_REDIRECT_URI='https://PROJECT.supabase.co/functions/v1/discord-link-callback'
```

A webhook URL-eket kizárólag itt tárold. Ne küldd Discord-üzenetben, ne tedd a
GitHub-repóba és ne építsd az EXE-be.

## Discord OAuth alkalmazás

1. A Discord Developer Portalon hozz létre vagy válassz ki egy alkalmazást.
2. Az **OAuth2** oldalon add hozzá Redirect URL-ként pontosan ezt:
   `https://PROJECT.supabase.co/functions/v1/discord-link-callback`
3. Az Application ID kerüljön a `DISCORD_CLIENT_ID`, az OAuth2 Client Secret a
   `DISCORD_CLIENT_SECRET`, a teljes callback URL pedig a
   `DISCORD_REDIRECT_URI` Supabase secretbe.
4. A kliens csak az `identify` jogosultságot kéri. Nem olvas üzeneteket és nem
   kap hozzáférést a felhasználó szerverlistájához.

A kapcsolási state 32 bájt véletlen adat, csak SHA-256 hash formában tárolódik,
egyszer használható és 10 perc után lejár. A normál frissítés megőrzi az
`installation_id` értékét, ezért nem kell újra összekapcsolni. Igazolt korábbi
kapcsolatnál átmeneti backend-kiesésre legfeljebb 72 óra helyi türelmi idő van.

## GitHub Actions beállítása

A repó **Settings → Secrets and variables → Actions** oldalán:

- `SOUNDLIFT_LOG_API_URL` = `https://PROJECT.supabase.co/functions/v1/log-events`
- `SOUNDLIFT_LOG_ANON_KEY` = a Supabase publikus `anon` kulcsa

Az anon kulcs önmagában nem ad olvasási jogot a táblákhoz; az RLS ezt tiltja.

## Naplózott gépcsere

```powershell
$env:SOUNDLIFT_ADMIN_API_URL='https://PROJECT.supabase.co/functions/v1/admin-license-action'
$env:SOUNDLIFT_ADMIN_API_KEY='AZ_ADMIN_KULCS'
.\licensing\Invoke-SoundLiftLicenseAdmin.ps1 -Action detach_device `
  -LicenseId 'LICENSE_UUID' -Reason 'Ellenőrzött gépcsere hibajegy alapján'
```

Az admin kulcs csak a saját gépeden legyen. Vásárlói buildbe soha ne kerüljön.

## Ellenőrzés kiadás előtt

1. Indítsd el a buildet, majd nézd meg az `indítás-log` csatornát.
2. Új telepítésnél ellenőrizd, hogy Discord-összekapcsolás nélkül az alkalmazás
   bezárul, sikeres OAuth után pedig elindul.
3. Hibás log URL után állítsd vissza a helyeset, majd ellenőrizd, hogy a következő
   indítás elküldi-e a várakozó eseményeket.
4. Hibás és másik géphez kapcsolt licenc a `biztonsági-log` csatornába kerüljön.
5. Fejlesztői licenc a `fejlesztői-hozzáférés-log` csatornába kerüljön.
6. Kiadás előtt keresd át a forrást webhook/token maradványokra.


## V1.2.0 kiadási sorrend és korlátok

Először SQL, Discord OAuth secrets és az új Edge Functionök telepítése,
azután a kliens telepítése. A Discord OAuth csak fiókot igazol, szervertagságot nem.
A régi 1.1.0 kliensre ez a kapu nem vonatkozik. Módosított helyi program ellen
a klienskapu nem megkerülhetetlen védelem.

Az installation-proof.dat Windows DPAPI-val védett, telepítésenként generált
hitelesítő adat; nem fordításkor beépített közös titok. Ne oszd meg és ne töröld
frissítéskor. A logokban csak ellenőrzött bizonyítékhoz rendeljük a Discord-nevet.
Régi kliens logja név nélkül továbbra is fogadható.

## Automatikus alkalmazásfrissítés

A V1.2.2-től az alkalmazás induláskor a GitHub legfrissebb nyilvános kiadását
ellenőrzi. Új verziónál a felhasználó a **Frissítés telepítése** gombbal letöltheti
és elindíthatja a telepítőt. A kliens a kiadás `SHA256SUMS.txt` fájljával
ellenőrzi a `SoundLift Setup.exe` fájlt, majd bezárja a régi példányt.

Végleges kiadáshoz a GitHub Actions **Build Windows application** workflowban
állítsd a `publish_release` mezőt igazra. Ez létrehozza vagy frissíti a verzióhoz
tartozó GitHub Release-t, és feltölti a telepítőt az ellenőrzőösszeggel együtt.
Egy már kiadott régebbi EXE csak akkor kapja meg ezt a működést, ha tartalmazza
az automatikus frissítő kódját; a V1.2.2 előtti EXE-ket egyszer kézzel kell
frissíteni.

A jelenlegi felület OAuth gombbal működik, slash parancs és bot nem szükséges.
Önkiszolgáló leválasztási felület még nincs; adminisztrátor a link sor revoked_at
mezőjét beállítva visszavonhatja a hozzáférést. Visszavonás után online indítás
elutasítja a használatot; már futó példányt nem állít le. A 72 órás offline
türelmi idő csak korábban ellenőrzött kapcsolatra vonatkozik.

Élő elfogadási próba: új telepítés link nélkül bezárul; Discord engedélyezés
után elindul; frissítéskor a kapcsolat megmarad; más telepítés bizonyítéka 403;
azonos OAuth session másodszori felhasználása sikertelen; Discord logban saját
név és támogatási ID jelenik meg. Ezt csak beállított Discord alkalmazással
és telepített Supabase backenddel lehet teljesen ellenőrizni.
