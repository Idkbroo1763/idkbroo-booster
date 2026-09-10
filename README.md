# SoundLift V1.3.2

Modern Windows-hangvezérlő profilokkal, basszuskiemeléssel, tízsávos
equalizerrel és akár 300%-os hangerő-erősítéssel.

Az egyedi SoundLift ikon az ablakban, a tálcán és a Windowszal
induló parancsikonon is megjelenik.

Windows 10/11 rendszerhang-erősítő és basszusvezérlő az Equalizer APO-hoz.

## Funkciók

- 0–300% hangerőszabályzás, valódi 0%-os némítással
- 0–24 dB, többsávos Bass Boost
- 40–160 Hz között állítható középfrekvencia
- automatikus headroom-alapú torzításvédelem
- uj, 160%-os Zene profil kontrollalt basszussal es V-alaku zenei EQ-val
- FiveM-re hangolt Játék profil tisztább beszéddel és részletekkel
- Discord- és Film-profil
- 10 sávos, -12 és +12 dB között állítható equalizer
- FiveM, Spotify és Discord automatikus profilfelismerés
- opcionális azonnali alkalmazás
- torzításveszély-jelző és automatikus headroom-védelem
- hangosabb, használatra kész gyári presetek kiegyensúlyozott headroom-védelemmel
- opcionális automatikus indulás a Windowszal
- az eredeti Equalizer APO-konfiguráció egyszeri biztonsági mentése
- automatikus rendszergazdai indítás egyetlen Windows-engedélykéréssel
- leválasztott, rejtett PowerShell-folyamat: a parancssor bezárása nem állítja le az appot
- R6, FiveM RP és FiveM harc profil
- kiegyensúlyozott játékprofilok: testes hangzás, enyhén kiemelt lépések és részletek
- sajat profil mentese es betoltese
- JSON profil importalas es exportalas
- elozo alkalmazott hang visszavonasa
- teljes effekt-kikapcsolas egy gombbal
- beepitett 60 Hz-es basszusteszt
- Equalizer APO eszkozvalaszto gyorsgomb
- minden beallitas automatikus megjegyzese
- globális Ctrl+Alt+1..6 profil-gyorsbillentyűk, játék közben is
- tálcaikon profilváltó menüvel és automatikus értesítésekkel
- a Windows aktuális alapértelmezett hangkimenetének kijelzése
- tisztább Brutál basszus profil újrahangolt headroom-védelemmel
- külön sub-bass, fő basszus és ütős 115 Hz-es basszusszűrő
- 25 Hz-es high-pass szűrő a felesleges mélyrezgések csökkentésére
- elkülönített konfiguráció, amely nem törli a meglévő Equalizer APO-beállításokat
- központi indítási, összeomlási, frissítési, licenc- és biztonsági naplózás
- sikertelen hibajelentés automatikus újraküldése a következő indításkor
- kötelező, hitelesített Discord OAuth-összekapcsolás, amely frissítés után is megmarad
- a Discord-fiókhoz kapcsolt támogatási azonosító a gyorsabb hibakereséshez
- egyetlen univerzális telepítő ingyenes, vásárlói és fejlesztői módhoz
- alkalmazáson belüli licencaktiválás, amely a frissítések után is megmarad
- kizárólag developer licenccel elérhető, ellenőrzött verzió-visszaállítás

## Adatvédelem és naplók

A részletes helyi technikai naplók a `%LOCALAPPDATA%\SoundLift\logs\` mappában
találhatók, és 14 nap után automatikusan törlődnek. A beállított naplószervernek
csak a működéshez, hibakereséshez, licenchez és biztonsághoz szükséges technikai
események kerülnek elküldésre. A kötelező összekapcsolás a Discord felhasználói
azonosítót és a megjelenített nevet a Supabase backendben tárolja. A kliens nem
küld nyers licenckulcsot, Windows-felhasználónevet, teljes gépazonosítót,
Discord-üzeneteket, szerverlistát vagy kattintási előzményt.

## Indítás

Olvasd el a `TELEPÍTÉS.txt` fájlt, majd indítsd el a `SoundLift.Setup.exe` telepítőt.

## Megjegyzés

A 200% nem a Windows csúszkáját viszi 100 fölé: körülbelül +6 dB digitális
előerősítést alkalmaz. Nagy basszuskiemeléssel együtt ez torzítást okozhat, ezért
az app alapból kompenzáló headroomot állít be.
