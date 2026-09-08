# SoundLift központi naplózás – beüzemelés

## Mit csinál a rendszer?

- A kliens a `%LOCALAPPDATA%\SoundLift\logs\` mappába ír napi NDJSON-naplókat.
- A helyi naplók 14 nap után automatikusan törlődnek.
- A sikertelenül küldött események a `pending-events.ndjson` fájlban maradnak,
  és a következő sikeres indításkor újra elküldésre kerülnek.
- A kliens kizárólag a `log-events` Supabase Edge Functionnek küld. Discord
  webhook, bot token és service-role kulcs nincs az EXE-ben.
- A licencdöntések szerveroldali, `trusted=true` események. A kliensből érkező
  biztonsági események `trusted=false` jelölést kapnak.

Nem gyűjtünk Windows-felhasználónevet, e-mailt, Discord-nevet, nyers
licenckulcsot, teljes gépazonosítót vagy kattintási előzményt.

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
   `admin-license-action` és `_shared` mappát a `supabase/functions/` alá, majd
   telepítsd a három Edge Functiont:

```powershell
supabase functions deploy log-events --no-verify-jwt
supabase functions deploy verify-license
supabase functions deploy admin-license-action --no-verify-jwt
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
```

A webhook URL-eket kizárólag itt tárold. Ne küldd Discord-üzenetben, ne tedd a
GitHub-repóba és ne építsd az EXE-be.

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
2. Hibás log URL után állítsd vissza a helyeset, majd ellenőrizd, hogy a következő
   indítás elküldi-e a várakozó eseményeket.
3. Hibás és másik géphez kapcsolt licenc a `biztonsági-log` csatornába kerüljön.
4. Fejlesztői licenc a `fejlesztői-hozzáférés-log` csatornába kerüljön.
5. Kiadás előtt keresd át a forrást webhook/token maradványokra.
