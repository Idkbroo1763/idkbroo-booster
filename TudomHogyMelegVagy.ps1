$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# Windows PowerShell / PS2EXE does not automatically load the DPAPI assembly.
Add-Type -AssemblyName System.Security

# PS2EXE alatt a $PSScriptRoot üres lehet. Ilyenkor az EXE saját mappáját
# használjuk minden alkalmazáshoz tartozó fájl és parancsikon alapjaként.
$script:isPackagedExe = [string]::IsNullOrWhiteSpace($PSScriptRoot)
$script:appDirectory = if ($script:isPackagedExe) {
    [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar)
} else {
    $PSScriptRoot
}
$script:appLaunchPath = if ($script:isPackagedExe) {
    [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
} else {
    Join-Path $script:appDirectory 'TudomHogyMelegVagy.bat'
}
$script:appVersion = '1.3.0'
$script:onboardingCompleted = $false
# A kiadott alkalmazás univerzális: ingyenes módban indul, és ugyanabban az
# EXE-ben aktiválható customer vagy developer licenc.
$script:licenseMode = 'free'
$script:currentLicenseType = 'free'
$script:licenseApiUrl = ''
$script:licenseProductId = ''
$script:licenseAnonKey = ''
# A build-szkriptek kizárólag a publikus naplófogadó végpontot és a Supabase
# anon kulcsot építhetik be. Discord webhook, bot token és service-role kulcs
# soha nem kerülhet a kliensbe.
$script:logApiUrl = ''
$script:logAnonKey = ''
$script:discordLinkRequired = $false
$script:discordLinkGraceHours = 72
$script:loggerInitialized = $false
$script:startupCompleted = $false

function ConvertTo-SoundLiftSafeText([object]$value, [int]$maxLength = 1000) {
    if ($null -eq $value) { return '' }
    $text = [string]$value
    foreach ($path in @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) { $text = $text.Replace($path, '%USERPROFILE%') }
    }
    $text = [Regex]::Replace($text, '(?i)\b(?:SL-[A-Z0-9-]{12,}|[A-F0-9]{32,})\b', '[REDACTED]')
    if ($text.Length -gt $maxLength) { return $text.Substring(0, $maxLength) }
    return $text
}

function Initialize-SoundLiftLogger {
    if ($script:loggerInitialized) { return }
    try {
        $script:logRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SoundLift\logs'
        if (-not (Test-Path $script:logRoot)) { [void][IO.Directory]::CreateDirectory($script:logRoot) }
        $script:logFile = Join-Path $script:logRoot ("soundlift-{0}.ndjson" -f (Get-Date -Format 'yyyy-MM-dd'))
        $script:logQueueFile = Join-Path $script:logRoot 'pending-events.ndjson'
        $script:logStateFile = Join-Path $script:logRoot 'logger-state.json'
        $installIdPath = Join-Path $script:logRoot 'installation-id.txt'
        if (Test-Path $installIdPath) { $script:installationId = ([IO.File]::ReadAllText($installIdPath)).Trim() }
        if ([string]::IsNullOrWhiteSpace($script:installationId) -or $script:installationId -notmatch '^[a-f0-9-]{36}$') {
            $script:installationId = [Guid]::NewGuid().ToString()
            [IO.File]::WriteAllText($installIdPath, $script:installationId, [Text.Encoding]::UTF8)
        }
        Get-ChildItem -LiteralPath $script:logRoot -Filter 'soundlift-*.ndjson' -File -ErrorAction SilentlyContinue |
            Where-Object LastWriteTimeUtc -lt ([DateTime]::UtcNow.AddDays(-14)) | Remove-Item -Force -ErrorAction SilentlyContinue
        $script:loggerInitialized = $true
    } catch { $script:loggerInitialized = $false }
}

function Get-SoundLiftSupportId {
    Initialize-SoundLiftLogger
    if ([string]::IsNullOrWhiteSpace($script:installationId)) { return 'SL-ISMERETLEN' }
    return 'SL-' + $script:installationId.Replace('-', '').Substring(0, 8).ToUpperInvariant()
}

function Add-SoundLiftPendingEvent([object]$event) {
    if (-not $script:loggerInitialized -or [string]::IsNullOrWhiteSpace($script:logApiUrl)) { return }
    try {
        $line = $event | ConvertTo-Json -Compress -Depth 6
        [IO.File]::AppendAllText($script:logQueueFile, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        if ((Get-Item -LiteralPath $script:logQueueFile).Length -gt 1048576) {
            $tail = @(Get-Content -LiteralPath $script:logQueueFile -Tail 500 -ErrorAction Stop)
            [IO.File]::WriteAllLines($script:logQueueFile, $tail, [Text.UTF8Encoding]::new($false))
        }
    } catch { }
}

function Write-SoundLiftLog {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('startup','crash','update','license','security','developer_access')][string]$Category,
        [Parameter(Mandatory=$true)][string]$EventName,
        [ValidateSet('debug','info','warning','error','critical')][string]$Severity = 'info',
        [hashtable]$Data = @{},
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    try {
        Initialize-SoundLiftLogger
        if (-not $script:loggerInitialized) { return }
        $safeData = [ordered]@{}
        foreach ($key in @($Data.Keys)) { $safeData[[string]$key] = ConvertTo-SoundLiftSafeText $Data[$key] }
        if ($ErrorRecord) {
            $safeData.exception_type = ConvertTo-SoundLiftSafeText $ErrorRecord.Exception.GetType().FullName 200
            $safeData.message = ConvertTo-SoundLiftSafeText $ErrorRecord.Exception.Message 1000
            $safeData.script_stack = ConvertTo-SoundLiftSafeText $ErrorRecord.ScriptStackTrace 1600
        }
        $event = [ordered]@{
            schema_version = 1; event_id = [Guid]::NewGuid().ToString(); timestamp_utc = [DateTime]::UtcNow.ToString('o')
            category = $Category; event_name = (ConvertTo-SoundLiftSafeText $EventName 80); severity = $Severity
            app_version = $script:appVersion; installation_id = $script:installationId
            license_mode = $script:licenseMode; product_id = (ConvertTo-SoundLiftSafeText $script:licenseProductId 64); data = $safeData
        }
        [IO.File]::AppendAllText($script:logFile, (($event | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Add-SoundLiftPendingEvent $event
    } catch { }
}

function Send-SoundLiftPendingLogs {
    Initialize-SoundLiftLogger
    if (-not $script:loggerInitialized -or [string]::IsNullOrWhiteSpace($script:logApiUrl) -or -not (Test-Path $script:logQueueFile)) { return }
    try {
        $allLines = @(Get-Content -LiteralPath $script:logQueueFile -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($allLines.Count -eq 0) { return }
        $take = [Math]::Min(50, $allLines.Count)
        $events = New-Object Collections.Generic.List[object]
        for ($i = 0; $i -lt $take; $i++) { try { $events.Add(($allLines[$i] | ConvertFrom-Json -ErrorAction Stop)) } catch { } }
        if ($events.Count -eq 0) { [IO.File]::Delete($script:logQueueFile); return }
        $headers = @{ 'Content-Type'='application/json'; 'User-Agent'="SoundLift/$($script:appVersion)" }
        if (-not [string]::IsNullOrWhiteSpace($script:logAnonKey)) { $headers.apikey=$script:logAnonKey; $headers.Authorization="Bearer $($script:logAnonKey)" }
        # Windows PowerShell 5.1 a Generic.List egyetlen elemes tartalmat
        # bizonyos esetekben objektumkent (nem JSON tombkent) szerializal.
        # A backend mindig {"events":[...]} formatumot var, ezert a tombot
        # explicit JSON-kent epitjuk fel egy- es tobbesemenyes kuldesnel is.
        $eventJson = @($events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 })
        $headers['x-soundlift-installation-proof'] = Get-InstallationProof
        $body = '{"events":[' + ($eventJson -join ',') + ']}'
        $response = Invoke-RestMethod -Uri $script:logApiUrl -Method Post -Headers $headers -Body $body -TimeoutSec 8
        if ($response.accepted -ge 0) {
            $remaining = if ($allLines.Count -gt $take) { @($allLines[$take..($allLines.Count - 1)]) } else { @() }
            [IO.File]::WriteAllLines($script:logQueueFile, $remaining, [Text.UTF8Encoding]::new($false))
        }
    } catch { }
}

function Complete-SoundLiftStartup {
    try {
        $previousVersion = ''
        if (Test-Path $script:logStateFile) {
            try { $previousVersion = [string]((Get-Content -LiteralPath $script:logStateFile -Raw | ConvertFrom-Json).lastSuccessfulVersion) } catch { }
        }
        if ($previousVersion -and $previousVersion -ne $script:appVersion) {
            Write-SoundLiftLog -Category update -EventName 'version_changed' -Data @{ old_version=$previousVersion; new_version=$script:appVersion }
        }
        [IO.File]::WriteAllText($script:logStateFile, (@{lastSuccessfulVersion=$script:appVersion; updatedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
        $script:startupCompleted = $true
        Write-SoundLiftLog -Category startup -EventName 'initialization_succeeded' -Data @{ packaged=$script:isPackagedExe }
        Send-SoundLiftPendingLogs
    } catch { }
}

Initialize-SoundLiftLogger
Write-SoundLiftLog -Category startup -EventName 'process_started' -Data @{ packaged=$script:isPackagedExe }
trap {
    $crashEvent = if ($script:startupCompleted) { 'unhandled_runtime_error' } else { 'startup_crash' }
    Write-SoundLiftLog -Category crash -EventName $crashEvent -Severity critical -ErrorRecord $_
    if (-not $script:startupCompleted) { Write-SoundLiftLog -Category startup -EventName 'initialization_failed' -Severity critical -ErrorRecord $_ }
    Send-SoundLiftPendingLogs
    break
}
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class AudioAppNative {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    enum EDataFlow { eRender, eCapture, eAll }
    enum ERole { eConsole, eMultimedia, eCommunications }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    interface IMMDevice {
        int Activate(ref Guid iid, uint context, IntPtr activationParams, out IntPtr instance);
        int OpenPropertyStore(uint access, out IPropertyStore properties);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    interface IPropertyStore {
        int GetCount(out uint count);
        int GetAt(uint index, out PROPERTYKEY key);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
    }

    [StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Explicit)] struct PROPVARIANT {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    public static string GetDefaultOutputName() {
        IMMDeviceEnumerator enumerator = null; IMMDevice device = null; IPropertyStore store = null;
        try {
            enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            if (enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device) != 0) return "Ismeretlen";
            if (device.OpenPropertyStore(0, out store) != 0) return "Ismeretlen";
            var key = new PROPERTYKEY { fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), pid = 14 };
            PROPVARIANT value;
            if (store.GetValue(ref key, out value) != 0 || value.pointerValue == IntPtr.Zero) return "Ismeretlen";
            return Marshal.PtrToStringUni(value.pointerValue) ?? "Ismeretlen";
        } catch { return "Ismeretlen"; }
        finally {
            if (store != null) Marshal.ReleaseComObject(store);
            if (device != null) Marshal.ReleaseComObject(device);
            if (enumerator != null) Marshal.ReleaseComObject(enumerator);
        }
    }
}
"@

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LicenseDeviceId {
    try {
        $machineGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
    } catch {
        $machineGuid = "fallback:$env:COMPUTERNAME:$env:PROCESSOR_IDENTIFIER"
    }
    $raw = "$machineGuid|$($script:licenseProductId)|SoundLift"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($raw)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Protect-LicenseState([object]$state) {
    $plain = [Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Compress))
    $protected = [Security.Cryptography.ProtectedData]::Protect($plain, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}

function Unprotect-LicenseState([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    $protected = [Convert]::FromBase64String($value)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return ([Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json)
}

function Get-InstallationProof {
    $path = Join-Path $script:logRoot 'installation-proof.dat'
    if (Test-Path $path) { return [string](Unprotect-LicenseState ([IO.File]::ReadAllText($path))).proof }
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $proof = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    [IO.File]::WriteAllText($path, (Protect-LicenseState @{proof=$proof}), [Text.Encoding]::UTF8)
    return $proof
}

function Get-SoundLiftFunctionUrl([string]$functionName) {
    if ([string]::IsNullOrWhiteSpace($script:logApiUrl)) { throw 'A SoundLift backend nincs beállítva.' }
    return [Regex]::Replace($script:logApiUrl.TrimEnd('/'), '/[^/]+$', "/$functionName")
}

function Invoke-DiscordLinkApi([string]$functionName) {
    $headers = @{ 'Content-Type'='application/json'; 'User-Agent'="SoundLift/$($script:appVersion)" }
    if (-not [string]::IsNullOrWhiteSpace($script:logAnonKey)) {
        $headers.apikey = $script:logAnonKey
        $headers.Authorization = "Bearer $($script:logAnonKey)"
    }
    $body = @{ installation_id=$script:installationId; installation_proof=(Get-InstallationProof) } | ConvertTo-Json -Compress
    return Invoke-RestMethod -Uri (Get-SoundLiftFunctionUrl $functionName) -Method Post -Headers $headers -Body $body -TimeoutSec 12
}

function Get-DiscordLinkCache {
    $path = Join-Path $script:logRoot 'discord-link.dat'
    if (-not (Test-Path $path)) { return $null }
    try { return Unprotect-LicenseState ([IO.File]::ReadAllText($path)) } catch { return $null }
}

function Save-DiscordLinkCache([string]$supportId) {
    try {
        $state = [PSCustomObject]@{ linked=$true; installationId=$script:installationId; supportId=$supportId; lastVerifiedUtc=[DateTime]::UtcNow.ToString('o') }
        [IO.File]::WriteAllText((Join-Path $script:logRoot 'discord-link.dat'), (Protect-LicenseState $state), [Text.Encoding]::UTF8)
    } catch { }
}

function Test-DiscordLinkOfflineGrace {
    $cached = Get-DiscordLinkCache
    if (-not $cached -or $cached.linked -ne $true -or $cached.installationId -ne $script:installationId -or -not $cached.lastVerifiedUtc) { return $false }
    try { $age = ([DateTime]::UtcNow - [DateTime]::Parse([string]$cached.lastVerifiedUtc).ToUniversalTime()).TotalHours; return ($age -ge 0 -and $age -le $script:discordLinkGraceHours) } catch { return $false }
}

function Confirm-DiscordAccountLink {
    if (-not $script:discordLinkRequired) { return $true }
    try {
        $status = Invoke-DiscordLinkApi 'discord-link-status'
        if ($status.linked -eq $true) { Save-DiscordLinkCache ([string]$status.support_id); return $true }
        $cachePath = Join-Path $script:logRoot 'discord-link.dat'
        if (Test-Path $cachePath) { [IO.File]::Delete($cachePath) }
    } catch {
        if ((-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ge 500) -and (Test-DiscordLinkOfflineGrace)) {
            Write-SoundLiftLog -Category security -EventName 'discord_link_offline_grace_used' -Severity warning -Data @{ grace_hours=$script:discordLinkGraceHours }
            return $true
        }
        Write-SoundLiftLog -Category security -EventName 'discord_link_check_failed' -Severity error -ErrorRecord $_
        [System.Windows.MessageBox]::Show('A Discord-összekapcsolás ellenőrzése sikertelen. Helyi alkalmazáshiba vagy szerverkapcsolati hiba is okozhatja. A részletek a SoundLift logs mappájában találhatók.', 'SoundLift – Discord ellenőrzés', 'OK', 'Error') | Out-Null
        return $false
    }

    Write-SoundLiftLog -Category security -EventName 'discord_link_required' -Severity warning
    $dialog = [Windows.Window]::new(); $dialog.Title='SoundLift – Discord összekapcsolás'; $dialog.Width=610; $dialog.Height=430
    $dialog.ResizeMode='NoResize'; $dialog.WindowStartupLocation='CenterScreen'; $dialog.Background='#09090B'; $dialog.Foreground='#F8FAFC'
    $root=[Windows.Controls.StackPanel]::new(); $root.Margin=[Windows.Thickness]::new(30)
    $title=[Windows.Controls.TextBlock]::new(); $title.Text='Discord-fiók összekapcsolása'; $title.FontSize=24; $title.FontWeight='Bold'
    $info=[Windows.Controls.TextBlock]::new(); $info.Text="A SoundLift használatához hitelesítened kell a Discord-fiókodat.`nA kapcsolat a frissítések után is megmarad."; $info.TextWrapping='Wrap'; $info.Margin=[Windows.Thickness]::new(0,14,0,12); $info.Foreground='#CBD5E1'
    $privacy=[Windows.Controls.TextBlock]::new(); $privacy.Text='A rendszer a Discord felhasználói azonosítódat és megjelenített nevedet tárolja a telepítés azonosításához, támogatáshoz és biztonsági naplózáshoz. Jelszót, üzeneteket és szerverlistát nem olvas.'; $privacy.TextWrapping='Wrap'; $privacy.Margin=[Windows.Thickness]::new(0,0,0,18); $privacy.Foreground='#94A3B8'
    $statusText=[Windows.Controls.TextBlock]::new(); $statusText.Text='Kattints az összekapcsolásra, engedélyezd a Discord-oldalon, majd térj vissza ide.'; $statusText.TextWrapping='Wrap'; $statusText.Margin=[Windows.Thickness]::new(0,0,0,18); $statusText.Foreground='#FBBF24'
    $connect=[Windows.Controls.Button]::new(); $connect.Content='Discord összekapcsolása'; $connect.Height=44; $connect.Margin=[Windows.Thickness]::new(0,0,0,10)
    $verify=[Windows.Controls.Button]::new(); $verify.Content='Összekapcsolás ellenőrzése'; $verify.Height=44; $verify.Margin=[Windows.Thickness]::new(0,0,0,10)
    $cancel=[Windows.Controls.Button]::new(); $cancel.Content='Kilépés'; $cancel.Height=38
    $result=@{ linked=$false }
    $connect.Add_Click({
        try {
            $created=Invoke-DiscordLinkApi 'discord-link-create'
            if ($created.linked -eq $true) { Save-DiscordLinkCache ([string]$created.support_id); $result.linked=$true; $dialog.Close(); return }
            if ([string]::IsNullOrWhiteSpace([string]$created.authorization_url)) { throw 'A backend nem adott engedélyezési linket.' }
            $authUri = [Uri]([string]$created.authorization_url)
            if ($authUri.Scheme -ne 'https' -or $authUri.Host -ne 'discord.com' -or $authUri.AbsolutePath -ne '/oauth2/authorize') { throw 'Érvénytelen Discord-link.' }
            Start-Process $authUri.AbsoluteUri
            $statusText.Text='A Discord-oldal megnyílt. Engedélyezés után kattints az ellenőrzés gombra.'
        } catch { $statusText.Text="Az összekapcsolás nem indítható: $($_.Exception.Message)" }
    }.GetNewClosure())
    $verify.Add_Click({
        try {
            $checked=Invoke-DiscordLinkApi 'discord-link-status'
            if ($checked.linked -eq $true) { Save-DiscordLinkCache ([string]$checked.support_id); $result.linked=$true; $dialog.Close() }
            else { $statusText.Text='Még nincs kész az összekapcsolás. Engedélyezd a Discord-oldalon, majd próbáld újra.' }
        } catch { $statusText.Text="Az ellenőrzés sikertelen: $($_.Exception.Message)" }
    }.GetNewClosure())
    $cancel.Add_Click({ $dialog.Close() }.GetNewClosure())
    foreach ($control in @($title,$info,$privacy,$statusText,$connect,$verify,$cancel)) { [void]$root.Children.Add($control) }
    $dialog.Content=$root; [void]$dialog.ShowDialog()
    if ($result.linked) { Write-SoundLiftLog -Category security -EventName 'discord_link_succeeded'; return $true }
    Write-SoundLiftLog -Category security -EventName 'discord_link_cancelled' -Severity warning
    return $false
}

function Get-SavedLicenseState {
    $path = Join-Path $env:APPDATA 'SoundLift\license.dat'
    if (-not (Test-Path $path)) { return $null }
    try { return Unprotect-LicenseState ([IO.File]::ReadAllText($path)) } catch { return $null }
}

function Save-LicenseState([string]$licenseKey, [string]$licenseType, [string]$authorizationId) {
    $directory = Join-Path $env:APPDATA 'SoundLift'
    if (-not (Test-Path $directory)) { [void][IO.Directory]::CreateDirectory($directory) }
    $state = [PSCustomObject]@{ key=$licenseKey.Trim(); licenseType=$licenseType; authorizationId=$authorizationId; lastSuccessUtc=[DateTime]::UtcNow.ToString('o') }
    [IO.File]::WriteAllText((Join-Path $directory 'license.dat'), (Protect-LicenseState $state), [Text.Encoding]::UTF8)
}

function Remove-LicenseState {
    $path = Join-Path $env:APPDATA 'SoundLift\license.dat'
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    $script:currentLicenseType = 'free'
}

function Invoke-LicenseApi([string]$licenseKey) {
    if ([string]::IsNullOrWhiteSpace($script:licenseApiUrl) -or [string]::IsNullOrWhiteSpace($script:licenseProductId)) {
        throw 'A SoundLift licenckiszolgálója nincs beállítva.'
    }
    $headers = @{ 'Content-Type' = 'application/json'; 'User-Agent' = "SoundLift/$($script:appVersion)" }
    if (-not [string]::IsNullOrWhiteSpace($script:licenseAnonKey)) {
        $headers['apikey'] = $script:licenseAnonKey
        $headers['Authorization'] = "Bearer $($script:licenseAnonKey)"
    }
    $body = @{ license_key = $licenseKey.Trim(); product_id = $script:licenseProductId; device_id = Get-LicenseDeviceId; installation_id = $script:installationId; installation_proof=(Get-InstallationProof) } | ConvertTo-Json -Compress
    try {
        return Invoke-RestMethod -Uri $script:licenseApiUrl -Method Post -Headers $headers -Body $body -TimeoutSec 12
    } catch {
        # Windows PowerShell 5.1 a szabályos 4xx licencválaszt is kivételként adja.
        # Ezt visszaalakítjuk válaszobjektummá, hogy egy letiltott kulcs soha ne
        # essen bele tévesen az offline türelmi időbe.
        $webResponse = $_.Exception.Response
        if ($webResponse) {
            try {
                $statusCode = [int]$webResponse.StatusCode
                if ($statusCode -ge 400 -and $statusCode -lt 500) {
                    $reader = New-Object IO.StreamReader($webResponse.GetResponseStream())
                    try { return ($reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop) } finally { $reader.Dispose() }
                }
            } catch { }
        }
        throw
    }
}

function Show-LicenseKeyDialog {
    $dialog = [Windows.Window]::new(); $dialog.Title = 'SoundLift – Licencaktiválás'; $dialog.Width = 560; $dialog.Height = 310
    $dialog.ResizeMode = 'NoResize'; $dialog.WindowStartupLocation = 'CenterScreen'; $dialog.Background = '#09090B'; $dialog.Foreground = '#F8FAFC'
    $root = [Windows.Controls.StackPanel]::new(); $root.Margin = [Windows.Thickness]::new(28)
    $title = [Windows.Controls.TextBlock]::new(); $title.Text = 'Vásárlói licenc aktiválása'; $title.FontSize = 23; $title.FontWeight = 'Bold'
    $info = [Windows.Controls.TextBlock]::new(); $info.Text = "Írd be a vásárláskor kapott licenckulcsot.`nA kulcs az első sikeres aktiváláskor ehhez a számítógéphez kapcsolódik."; $info.TextWrapping = 'Wrap'; $info.Margin = [Windows.Thickness]::new(0,12,0,16); $info.Foreground = '#CBD5E1'
    $input = [Windows.Controls.TextBox]::new(); $input.Height = 38; $input.Padding = [Windows.Thickness]::new(8); $input.FontSize = 14
    $buttons = [Windows.Controls.StackPanel]::new(); $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'; $buttons.Margin = [Windows.Thickness]::new(0,18,0,0)
    $cancel = [Windows.Controls.Button]::new(); $cancel.Content = 'Mégse'; $cancel.Width = 100; $cancel.Height = 38; $cancel.Margin = [Windows.Thickness]::new(0,0,10,0)
    $activate = [Windows.Controls.Button]::new(); $activate.Content = 'Aktiválás'; $activate.Width = 125; $activate.Height = 38
    $result = @{ key = $null }; $cancel.Add_Click({ $dialog.Close() }.GetNewClosure())
    $activate.Add_Click({ if (-not [string]::IsNullOrWhiteSpace($input.Text)) { $result.key = $input.Text.Trim(); $dialog.Close() } }.GetNewClosure())
    $buttons.Children.Add($cancel) | Out-Null; $buttons.Children.Add($activate) | Out-Null
    $root.Children.Add($title) | Out-Null; $root.Children.Add($info) | Out-Null; $root.Children.Add($input) | Out-Null; $root.Children.Add($buttons) | Out-Null
    $dialog.Content = $root; $dialog.ShowDialog() | Out-Null; return $result.key
}

function Confirm-SoundLiftLicense {
    param([switch]$PromptForKey)
    if ($script:licenseMode -notin @('universal','custom')) { return $true }
    $saved = Get-SavedLicenseState
    $key = if ($PromptForKey) { Show-LicenseKeyDialog } elseif ($saved -and $saved.key) { [string]$saved.key } else { $null }
    if ([string]::IsNullOrWhiteSpace($key)) {
        if ($PromptForKey) {
            Write-SoundLiftLog -Category license -EventName 'activation_cancelled' -Severity warning
            return $false
        }
        $script:currentLicenseType = 'free'
        return (-not $PromptForKey -and $script:licenseMode -eq 'universal')
    }
    try {
        $response = Invoke-LicenseApi $key
        if ($response.allowed -eq $true) {
            $script:currentLicenseType = [string]$response.license_type
            Save-LicenseState $key $script:currentLicenseType ([string]$response.authorization_id)
            $eventName = if (-not $PromptForKey -and $saved -and $saved.key) { 'validation_succeeded' } else { 'activation_succeeded' }
            Write-SoundLiftLog -Category license -EventName $eventName -Data @{ license_type=$response.license_type; code=$response.code }
            if ([string]$response.license_type -eq 'developer') {
                Write-SoundLiftLog -Category developer_access -EventName 'developer_license_used' -Severity warning -Data @{ authorization_id=$response.authorization_id; code=$response.code }
            }
            return $true
        }
        $failureCode = ConvertTo-SoundLiftSafeText $response.code 60
        Write-SoundLiftLog -Category license -EventName 'validation_failed' -Severity warning -Data @{ code=$failureCode }
        if ($failureCode -in @('INVALID_LICENSE','LICENSE_BLOCKED','LICENSE_EXPIRED','DEVICE_LIMIT')) {
            Write-SoundLiftLog -Category security -EventName 'license_rejected' -Severity warning -Data @{ code=$failureCode }
        }
        if (-not $PromptForKey) { Remove-LicenseState }
        [System.Windows.MessageBox]::Show(([string]$response.message), 'A licenc nem használható', 'OK', 'Warning') | Out-Null
        return (-not $PromptForKey -and $script:licenseMode -eq 'universal')
    } catch {
        # Rövid internetkimaradásnál 72 órás, DPAPI-val védett türelmi idő.
        if (-not $PromptForKey -and $saved -and $saved.lastSuccessUtc) {
            try {
                if (([DateTime]::UtcNow - [DateTime]::Parse([string]$saved.lastSuccessUtc).ToUniversalTime()).TotalHours -le 72) {
                    $script:currentLicenseType = if ($saved.licenseType) { [string]$saved.licenseType } else { 'customer' }
                    Write-SoundLiftLog -Category license -EventName 'offline_grace_used' -Severity warning -Data @{ grace_hours=72 }
                    return $true
                }
            } catch { }
        }
        Write-SoundLiftLog -Category license -EventName 'validation_unavailable' -Severity error -ErrorRecord $_
        if ($PromptForKey -or $script:licenseMode -eq 'custom') {
            [System.Windows.MessageBox]::Show("A licenc most nem ellenőrizhető, és nincs érvényes offline időszak.`n`n$($_.Exception.Message)", 'Licencellenőrzési hiba', 'OK', 'Error') | Out-Null
        }
        if (-not $PromptForKey) { $script:currentLicenseType = 'free' }
        return (-not $PromptForKey -and $script:licenseMode -eq 'universal')
    }
}

function Get-ApoConfigDirectory {
    $candidates = @(
        "$env:ProgramFiles\EqualizerAPO\config",
        "${env:ProgramFiles(x86)}\EqualizerAPO\config"
    ) | Where-Object { $_ -and (Test-Path $_) }
    return $candidates | Select-Object -First 1
}

# Authenticate before creating controls, tray actions, timers or hotkeys.
if (-not (Confirm-DiscordAccountLink)) {
    Write-SoundLiftLog -Category startup -EventName 'initialization_failed' -Severity warning -Data @{stage='discord_link_gate'}
    Send-SoundLiftPendingLogs
    return
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SoundLift V1.3.0" Width="1180" Height="840" MinWidth="1000" MinHeight="720"
        WindowStartupLocation="CenterScreen" Background="#070707" Foreground="#F8FAFC"
        FontFamily="Segoe UI" ResizeMode="CanResizeWithGrip" ShowInTaskbar="True"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <LinearGradientBrush x:Key="PageGradient" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#070707" Offset="0"/><GradientStop Color="#20090B" Offset="0.55"/><GradientStop Color="#070707" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="AccentGradient" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#EF233C" Offset="0"/><GradientStop Color="#8B0017" Offset="1"/>
    </LinearGradientBrush>
    <SolidColorBrush x:Key="AccentTextBrush" Color="#FF4057"/>
    <SolidColorBrush x:Key="HoverBrush" Color="#3A1016"/>
    <DropShadowEffect x:Key="CardShadow" BlurRadius="22" ShadowDepth="4" Opacity="0.25" Color="#000000"/>
    <Style TargetType="TextBlock"><Setter Property="FontFamily" Value="Segoe UI"/></Style>
    <Style TargetType="Button">
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#FFF1F2"/><Setter Property="Background" Value="#18181B"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="15,10"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource HoverBrush}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.72"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{DynamicResource AccentGradient}"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="15"/><Setter Property="Padding" Value="24,14"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="UtilityButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#17171B"/><Setter Property="BorderBrush" Value="#2B2B31"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="13,9"/><Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource UtilityButton}">
      <Setter Property="Foreground" Value="#FF7A8A"/><Setter Property="Background" Value="#241014"/>
      <Setter Property="BorderBrush" Value="#5A2029"/><Setter Property="Padding" Value="16,10"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#CBD5E1"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,4,18,4"/><Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="Slider">
      <Setter Property="Height" Value="34"/><Setter Property="Margin" Value="0,7,0,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid>
              <Border Height="8" CornerRadius="4" Background="#2A2A2E" VerticalAlignment="Center"/>
              <Track Name="PART_Track" VerticalAlignment="Center">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Background="{DynamicResource AccentGradient}" BorderThickness="0">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="{TemplateBinding Background}" CornerRadius="4"/></ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="22" Height="22" Cursor="Hand">
                    <Thumb.Template><ControlTemplate TargetType="Thumb"><Ellipse Fill="#FFFFFF" Stroke="{DynamicResource AccentTextBrush}" StrokeThickness="5"/></ControlTemplate></Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Command="Slider.IncreaseLarge" Background="Transparent" BorderThickness="0"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="VerticalEqSlider" TargetType="Slider">
      <Setter Property="Width" Value="40"/><Setter Property="Height" Value="120"/>
      <Setter Property="Margin" Value="2"/><Setter Property="Orientation" Value="Vertical"/>
    </Style>
  </Window.Resources>

  <Grid Background="{DynamicResource PageGradient}">
    <Grid.RowDefinitions><RowDefinition Height="96"/><RowDefinition Height="*"/></Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="30,20,30,13">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="440"/></Grid.ColumnDefinitions>
      <StackPanel VerticalAlignment="Center">
        <TextBlock Text="SOUNDLIFT" FontFamily="Segoe UI Black" FontSize="29" Foreground="{DynamicResource AccentTextBrush}"/>
        <TextBlock Text="S Y S T E M   A U D I O   C O N T R O L  •  V1.3.0" FontSize="11" FontWeight="Bold" Foreground="#64748B" Margin="1,3,0,0"/>
      </StackPanel>
      <Border Name="StatusBorder" Grid.Column="1" Background="#171719" CornerRadius="13" Padding="16,11" BorderBrush="#303035" BorderThickness="1">
        <StackPanel>
          <TextBlock Name="StatusText" Text="Equalizer APO keresése..." FontSize="13" FontWeight="SemiBold" Foreground="#E2E8F0"/>
          <TextBlock Name="DeviceText" Text="Aktív hangkimenet: keresés..." FontSize="12" Foreground="#8B9BB4" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </Border>
    </Grid>

    <Grid Grid.Row="1" Margin="30,0,30,28">
      <Grid.ColumnDefinitions><ColumnDefinition Width="245"/><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="#111113" CornerRadius="18" Padding="16" BorderBrush="#29292E" BorderThickness="1" Effect="{StaticResource CardShadow}">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <TextBlock Text="P R O F I L O K" FontSize="11" FontWeight="Bold" Foreground="#9A7C80" Margin="5,2,0,13"/>
          <StackPanel Grid.Row="1">
            <Button Name="MusicButton" Content="♫   Zene"/>
            <Button Name="GameButton" Content="◆   FiveM RP"/>
            <Button Name="CombatButton" Content="⌁   FiveM harc"/>
            <Button Name="R6Button" Content="◎   Rainbow Six"/>
            <Button Name="DiscordButton" Content="◉   Discord"/>
            <Button Name="MovieButton" Content="▶   Film"/>
            <Button Name="HeavyButton" Content="ϟ   Brutál basszus"/>
            <Button Name="ResetButton" Content="↺   Alaphelyzet"/>
          </StackPanel>
          <StackPanel Grid.Row="2">
            <Border Height="1" Background="#303035" Margin="0,4,0,13"/>
            <TextBlock Text="T É M A" FontSize="10" FontWeight="Bold" Foreground="#9A7C80" Margin="4,0,0,5"/>
            <ComboBox Name="ThemeCombo" Height="34" Margin="0,0,0,9" Padding="8,3"
                      Background="#F4F4F5" Foreground="#111113" BorderBrush="#52525B" FontWeight="SemiBold">
              <ComboBox.Resources>
                <Style TargetType="{x:Type ComboBoxItem}">
                  <Setter Property="Foreground" Value="#111113"/>
                  <Setter Property="Background" Value="#F4F4F5"/>
                  <Setter Property="Padding" Value="9,6"/>
                  <Style.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FFD5DB"/></Trigger>
                    <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#FFB3BE"/></Trigger>
                  </Style.Triggers>
                </Style>
              </ComboBox.Resources>
            </ComboBox>
            <TextBlock Name="VersionText" Text="Telepített verzió: 1.2.0" Foreground="#64748B" FontSize="11" Margin="4,0,0,6"/>
            <TextBlock Name="SupportIdText" Text="Támogatási ID: betöltés…" Foreground="#94A3B8" FontSize="11" Margin="4,0,0,4"/>
            <Button Name="CopySupportIdButton" Content="⧉  Támogatási ID másolása" Style="{StaticResource UtilityButton}"/>
            <TextBlock Name="LicenseStatusText" Text="Licenc: ingyenes" Foreground="#94A3B8" FontSize="11" Margin="4,5,0,4"/>
            <Button Name="LicenseButton" Content="🔑  Licenc aktiválása" Style="{StaticResource UtilityButton}"/>
            <TextBlock Name="ActiveProfileText" Text="Aktív profil: Custom" Foreground="{DynamicResource AccentTextBrush}" FontWeight="SemiBold" FontSize="12" Margin="4,0,0,10"/>
            <Button Name="AboutButton" Content="ⓘ  Névjegy és Discord" Style="{StaticResource UtilityButton}"/>
            <Button Name="ApplyButton" Content="ALKALMAZÁS" Style="{StaticResource PrimaryButton}"/>
          </StackPanel>
        </Grid>
      </Border>

      <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>
          <Border Background="#111113" CornerRadius="18" Padding="22,17" BorderBrush="#29292E" BorderThickness="1" Effect="{StaticResource CardShadow}" Margin="0,0,0,14">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel>
                <DockPanel><TextBlock Text="Hangerő-erősítés" FontSize="15" FontWeight="SemiBold"/><TextBlock Name="VolumeValue" Text="100%" FontSize="17" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}" HorizontalAlignment="Right"/></DockPanel>
                <Slider Name="VolumeSlider" Minimum="0" Maximum="300" Value="100" TickFrequency="5" IsSnapToTickEnabled="True"/>
                <TextBlock Text="Teljes tartomány: némítás–300%" FontSize="11" Foreground="#64748B"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <DockPanel><TextBlock Text="Bass Boost" FontSize="15" FontWeight="SemiBold"/><TextBlock Name="BassValue" Text="6 dB" FontSize="17" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}" HorizontalAlignment="Right"/></DockPanel>
                <Slider Name="BassSlider" Minimum="0" Maximum="24" Value="6" TickFrequency="1" IsSnapToTickEnabled="True"/>
                <TextBlock Text="Többsávos mélyhangkiemelés" FontSize="11" Foreground="#64748B"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Background="#111113" CornerRadius="18" Padding="22,17" BorderBrush="#29292E" BorderThickness="1" Effect="{StaticResource CardShadow}" Margin="0,0,0,14">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <DockPanel>
                <TextBlock Text="Basszus középfrekvencia" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock Name="FrequencyValue" Text="75 Hz" FontSize="17" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}" HorizontalAlignment="Right"/>
              </DockPanel>
              <Slider Name="FrequencySlider" Grid.Row="1" Minimum="40" Maximum="160" Value="75" TickFrequency="5" IsSnapToTickEnabled="True"/>
            </Grid>
          </Border>

          <Border Background="#111113" CornerRadius="18" Padding="22,15" BorderBrush="#29292E" BorderThickness="1" Effect="{StaticResource CardShadow}" Margin="0,0,0,14">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="V É D E L E M   É S   A U T O M A T I Z Á L Á S" FontSize="11" FontWeight="Bold" Foreground="#9A7C80" Margin="0,0,0,8"/>
                <WrapPanel>
                  <CheckBox Name="SafetyCheck" Content="Torzításvédelem" IsChecked="True"/>
                  <CheckBox Name="AutoProfileCheck" Content="Automatikus profilváltás"/>
                  <CheckBox Name="InstantCheck" Content="Azonnali alkalmazás"/>
                  <CheckBox Name="StartupCheck" Content="Indulás a Windowszal"/>
                </WrapPanel>
              </StackPanel>
              <Border Grid.Column="1" Background="#12291F" CornerRadius="9" Padding="12,7" VerticalAlignment="Center">
                <TextBlock Name="ClipText" Text="VÉDVE" Foreground="#4ADE80" FontWeight="Bold" FontSize="11"/>
              </Border>
            </Grid>
          </Border>

          <Border Background="#111113" CornerRadius="18" Padding="22,15" BorderBrush="#29292E" BorderThickness="1" Effect="{StaticResource CardShadow}" Margin="0,0,0,14">
            <StackPanel>
              <DockPanel Margin="0,0,0,10">
                <TextBlock Text="1 0   S Á V O S   E Q U A L I Z E R" FontSize="11" FontWeight="Bold" Foreground="#9A7C80"/>
                <TextBlock Text="-12 dB  •  +12 dB" HorizontalAlignment="Right" Foreground="#64748B" FontSize="11"/>
              </DockPanel>
              <Border Background="#0B0B0D" CornerRadius="12" Padding="12">
                <UniformGrid Name="EqPanel" Rows="1" Columns="10"/>
              </Border>
            </StackPanel>
          </Border>

          <Border Background="#111113" CornerRadius="18" Padding="20,17" BorderBrush="#29292E" BorderThickness="1" Effect="{StaticResource CardShadow}">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <TextBlock Text="B E Á L L Í T Á S O K   É S   E S Z K Ö Z Ö K" FontSize="11" FontWeight="Bold" Foreground="#9A7C80" Margin="2,0,0,12"/>
              <Grid Grid.Row="1">
                <Grid.ColumnDefinitions><ColumnDefinition Width="1*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="1.15*"/></Grid.ColumnDefinitions>
                <Border Background="#0B0B0D" CornerRadius="13" Padding="14,12" BorderBrush="#242429" BorderThickness="1">
                  <StackPanel>
                    <TextBlock Text="PROFILKEZELÉS" Foreground="#7C8799" FontSize="10" FontWeight="Bold" Margin="2,0,0,9"/>
                    <WrapPanel>
                      <Button Name="SaveButton" Content="＋  Saját mentés" Style="{StaticResource UtilityButton}"/>
                      <Button Name="LoadButton" Content="↗  Saját betöltés" Style="{StaticResource UtilityButton}"/>
                      <Button Name="ExportButton" Content="Export" Style="{StaticResource UtilityButton}"/>
                      <Button Name="ImportButton" Content="Import" Style="{StaticResource UtilityButton}"/>
                      <Button Name="UndoButton" Content="↶  Visszavonás" Style="{StaticResource UtilityButton}"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
                <Border Grid.Column="2" Background="#0B0B0D" CornerRadius="13" Padding="14,12" BorderBrush="#242429" BorderThickness="1">
                  <StackPanel>
                    <TextBlock Text="RENDSZERESZKÖZÖK" Foreground="#7C8799" FontSize="10" FontWeight="Bold" Margin="2,0,0,9"/>
                    <WrapPanel>
                      <Button Name="TestButton" Content="◉  60 Hz teszt" Style="{StaticResource UtilityButton}"/>
                      <Button Name="DeviceButton" Content="▣  Hangeszközök" Style="{StaticResource UtilityButton}"/>
                      <Button Name="DiagnosticsButton" Content="✓  Diagnosztika" Style="{StaticResource UtilityButton}"/>
                      <Button Name="UpdateButton" Content="↻  Frissítések" Style="{StaticResource UtilityButton}"/>
                      <Button Name="RollbackButton" Content="↶  Előző verzió visszaállítása" Style="{StaticResource UtilityButton}"/>
                      <Button Name="ChangelogButton" Content="≡  Változások" Style="{StaticResource UtilityButton}"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
              </Grid>
              <Border Grid.Row="2" Background="#150B0D" CornerRadius="12" Padding="14,10" BorderBrush="#352026" BorderThickness="1" Margin="0,12,0,0">
                <DockPanel>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="HANGFELDOLGOZÁS" Foreground="#A66B74" FontSize="10" FontWeight="Bold"/>
                    <TextBlock Text="Az Equalizer APO eredeti hangjára vált vissza." Foreground="#6F7888" FontSize="11" Margin="0,3,0,0"/>
                  </StackPanel>
                  <Button Name="BypassButton" Content="⏻  Hanghatások kikapcsolása" Style="{StaticResource DangerButton}" HorizontalAlignment="Right" Margin="16,0,0,0"/>
                </DockPanel>
              </Border>
            </Grid>
          </Border>
        </StackPanel>
      </ScrollViewer>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.Dispatcher.Add_UnhandledException({
    param($sender, $eventArgs)
    try {
        Write-SoundLiftLog -Category crash -EventName 'unhandled_runtime_error' -Severity critical -Data @{
            exception_type=$eventArgs.Exception.GetType().FullName
            message=$eventArgs.Exception.Message
            script_stack=$eventArgs.Exception.StackTrace
        }
        Send-SoundLiftPendingLogs
        [System.Windows.MessageBox]::Show("A SoundLift váratlan hibát észlelt, ezért biztonságosan bezárul.`nA részletes napló itt található:`n$script:logRoot", 'SoundLift – hiba', 'OK', 'Error') | Out-Null
    } catch { }
    $eventArgs.Handled = $true
    $script:reallyExit = $true
    $window.Close()
}.GetNewClosure())
$appIconPath = Join-Path $script:appDirectory 'SoundLift.ico'
if (Test-Path $appIconPath) {
    try { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$appIconPath) } catch { }
}
$names = @('StatusBorder','StatusText','DeviceText','VolumeValue','BassValue','FrequencyValue','VolumeSlider','BassSlider','FrequencySlider','SafetyCheck','MusicButton','GameButton','CombatButton','R6Button','DiscordButton','MovieButton','HeavyButton','ResetButton','ApplyButton','EqPanel','AutoProfileCheck','InstantCheck','StartupCheck','ClipText','SaveButton','LoadButton','ExportButton','ImportButton','UndoButton','BypassButton','TestButton','DeviceButton','DiagnosticsButton','UpdateButton','RollbackButton','ChangelogButton','AboutButton','ActiveProfileText','ThemeCombo','VersionText','SupportIdText','CopySupportIdButton','LicenseStatusText','LicenseButton')
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) }
$VersionText.Text = "Telepített verzió: $script:appVersion"
$SupportIdText.Text = "Támogatási ID: $(Get-SoundLiftSupportId)"
$CopySupportIdButton.Add_Click({
    try {
        [Windows.Forms.Clipboard]::SetText((Get-SoundLiftSupportId))
        $StatusText.Text = 'OK - Támogatási ID a vágólapra másolva'
    } catch { [System.Windows.MessageBox]::Show('A támogatási ID most nem másolható a vágólapra.', 'SoundLift', 'OK', 'Warning') | Out-Null }
})

$script:eqBands = @(31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)
$script:eqSliders = @()
$script:eqValueLabels = @()
for ($i = 0; $i -lt $script:eqBands.Count; $i++) {
    $column = New-Object Windows.Controls.StackPanel
    $column.HorizontalAlignment = 'Center'
    $bandLabel = New-Object Windows.Controls.TextBlock
    $bandLabel.Text = if ($script:eqBands[$i] -ge 1000) { "$($script:eqBands[$i] / 1000)k" } else { "$($script:eqBands[$i])" }
    $bandLabel.HorizontalAlignment = 'Center'; $bandLabel.Foreground = '#AAB2C0'
    $slider = New-Object Windows.Controls.Slider
    $slider.Minimum = -12; $slider.Maximum = 12; $slider.Value = 0; $slider.TickFrequency = 1; $slider.IsSnapToTickEnabled = $true
    $slider.Style = $window.FindResource('VerticalEqSlider')
    $valueLabel = New-Object Windows.Controls.TextBlock
    $valueLabel.Text = '0'; $valueLabel.HorizontalAlignment = 'Center'; $valueLabel.Foreground = '#FF4057'
    [void]$column.Children.Add($bandLabel); [void]$column.Children.Add($slider); [void]$column.Children.Add($valueLabel)
    [void]$EqPanel.Children.Add($column)
    $script:eqSliders += $slider; $script:eqValueLabels += $valueLabel
    $index = $i
    $slider.Add_ValueChanged({ $script:eqValueLabels[$index].Text = ([int]$script:eqSliders[$index].Value).ToString() }.GetNewClosure())
}

function Set-AppTheme([string]$themeName) {
    $theme = switch ($themeName) {
        'Black & Blue'     { @{ Accent='#22A7FF'; AccentDark='#0057B8'; Page='#071521'; Hover='#102D42' } }
        'Graphite & Green' { @{ Accent='#35D07F'; AccentDark='#087443'; Page='#092018'; Hover='#123526' } }
        default            { @{ Accent='#FF4057'; AccentDark='#8B0017'; Page='#20090B'; Hover='#3A1016' } }
    }

    $accentColor = [Windows.Media.ColorConverter]::ConvertFromString($theme.Accent)
    $accentDarkColor = [Windows.Media.ColorConverter]::ConvertFromString($theme.AccentDark)
    $pageColor = [Windows.Media.ColorConverter]::ConvertFromString($theme.Page)
    $baseColor = [Windows.Media.ColorConverter]::ConvertFromString('#070707')

    $accentGradient = [Windows.Media.LinearGradientBrush]::new()
    $accentGradient.StartPoint = [Windows.Point]::new(0, 0)
    $accentGradient.EndPoint = [Windows.Point]::new(1, 1)
    $accentGradient.GradientStops.Add([Windows.Media.GradientStop]::new($accentColor, 0))
    $accentGradient.GradientStops.Add([Windows.Media.GradientStop]::new($accentDarkColor, 1))
    $window.Resources['AccentGradient'] = $accentGradient

    $pageGradient = [Windows.Media.LinearGradientBrush]::new()
    $pageGradient.StartPoint = [Windows.Point]::new(0, 0)
    $pageGradient.EndPoint = [Windows.Point]::new(1, 1)
    $pageGradient.GradientStops.Add([Windows.Media.GradientStop]::new($baseColor, 0))
    $pageGradient.GradientStops.Add([Windows.Media.GradientStop]::new($pageColor, 0.55))
    $pageGradient.GradientStops.Add([Windows.Media.GradientStop]::new($baseColor, 1))
    $window.Resources['PageGradient'] = $pageGradient

    $window.Resources['AccentTextBrush'] = [Windows.Media.SolidColorBrush]::new($accentColor)
    $window.Resources['HoverBrush'] = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($theme.Hover))
    foreach ($label in $script:eqValueLabels) { $label.Foreground = $window.Resources['AccentTextBrush'] }
    $script:themeName = $themeName
}

$script:themeNames = @('Black & Red', 'Black & Blue', 'Graphite & Green')
foreach ($themeName in $script:themeNames) { [void]$ThemeCombo.Items.Add($themeName) }
$ThemeCombo.SelectedIndex = 0
$ThemeCombo.Add_SelectionChanged({
    if ($ThemeCombo.SelectedItem) { Set-AppTheme ([string]$ThemeCombo.SelectedItem) }
})
Set-AppTheme 'Black & Red'

function Set-EqValues([double[]]$values) {
    for ($i = 0; $i -lt $script:eqSliders.Count; $i++) { $script:eqSliders[$i].Value = $values[$i] }
}

function Update-Labels {
    $VolumeValue.Text = "$([int]$VolumeSlider.Value)%"
    $BassValue.Text = "$([int]$BassSlider.Value) dB"
    $FrequencyValue.Text = "$([int]$FrequencySlider.Value) Hz"
    $roughVolumeDb = if ([double]$VolumeSlider.Value -le 0) { -100.0 } else { 20.0 * [Math]::Log10([double]$VolumeSlider.Value / 100.0) }
    $roughPeak = $roughVolumeDb + ([double]$BassSlider.Value * 0.55)
    if ($SafetyCheck.IsChecked) {
        $ClipText.Text = 'VÉDVE'; $ClipText.Foreground = '#4ADE80'
    } elseif ($roughPeak -gt 6) {
        $ClipText.Text = 'TORZÍTÁSVESZÉLY'; $ClipText.Foreground = '#FB7185'
    } else {
        $ClipText.Text = 'OK'; $ClipText.Foreground = '#FBBF24'
    }
}

function Set-Profile([int]$volume, [int]$bass, [int]$frequency, [bool]$safe = $true) {
    $VolumeSlider.Value = $volume; $BassSlider.Value = $bass; $FrequencySlider.Value = $frequency
    $SafetyCheck.IsChecked = $safe; $ActiveProfileText.Text = "Aktív profil: $script:activeProfile"; Update-Labels
}

$VolumeSlider.Add_ValueChanged({ Update-Labels })
$BassSlider.Add_ValueChanged({ Update-Labels })
$FrequencySlider.Add_ValueChanged({ Update-Labels })
$script:activeProfile = 'Custom'
$MusicButton.Add_Click({ $script:activeProfile = 'Music'; Set-Profile 170 5 72 $true; Set-EqValues @(2,2,1,-1,-1,0,1,2,1,1) })
$GameButton.Add_Click({ $script:activeProfile = 'FiveM RP'; Set-Profile 140 2 80 $true; Set-EqValues @(-2,-1,0,-2,-2,0,2,3,1,0) })
$CombatButton.Add_Click({ $script:activeProfile = 'FiveM Combat'; Set-Profile 140 1 85 $true; Set-EqValues @(-3,-2,-1,-2,-1,1,3,3,2,0) })
$R6Button.Add_Click({ $script:activeProfile = 'R6'; Set-Profile 140 0 90 $true; Set-EqValues @(-4,-3,-2,-2,-1,1,3,4,2,0) })
$DiscordButton.Add_Click({ $script:activeProfile = 'Discord'; Set-Profile 130 0 80 $true; Set-EqValues @(-3,-2,-1,-2,-1,1,3,2,0,-1) })
$MovieButton.Add_Click({ $script:activeProfile = 'Movie'; Set-Profile 145 5 65 $true; Set-EqValues @(1,1,0,-1,-2,0,2,2,1,1) })
$HeavyButton.Add_Click({ $script:activeProfile = 'Heavy'; Set-Profile 175 11 58 $true; Set-EqValues @(2,2,1,-2,-2,-1,1,2,1,0) })
$ResetButton.Add_Click({ $script:activeProfile = 'Custom'; Set-Profile 100 0 75 $true; Set-EqValues @(0,0,0,0,0,0,0,0,0,0) })

$apoDirectory = Get-ApoConfigDirectory
if ($apoDirectory) {
    $StatusText.Text = "OK - Equalizer APO megtalálva, készen áll"
    $StatusBorder.Background = '#143126'
} else {
    $StatusText.Text = "FIGYELEM - Equalizer APO nincs telepítve, lásd a TELEPITES.txt fájlt"
    $StatusBorder.Background = '#3A2812'
}

function Read-TextWithRetry([string]$path) {
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try { return [IO.File]::ReadAllText($path) }
        catch [IO.IOException] { if ($attempt -eq 20) { throw }; [Threading.Thread]::Sleep(100) }
    }
}

function Write-LinesWithRetry([string]$path, [string[]]$lines) {
    $encoding = New-Object Text.UTF8Encoding($false)
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try { [IO.File]::WriteAllLines($path, $lines, $encoding); return }
        catch [IO.IOException] { if ($attempt -eq 20) { throw }; [Threading.Thread]::Sleep(100) }
    }
}

function Write-TextWithRetry([string]$path, [string]$value) {
    $encoding = New-Object Text.UTF8Encoding($false)
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try { [IO.File]::WriteAllText($path, $value, $encoding); return }
        catch [IO.IOException] { if ($attempt -eq 20) { throw }; [Threading.Thread]::Sleep(100) }
    }
}

$script:applyBusy = $false
$ApplyButton.Add_Click({
    if ($script:applyBusy) { return }
    $script:applyBusy = $true
    try {
        $apoDirectory = Get-ApoConfigDirectory
        if (-not $apoDirectory) {
            [System.Windows.MessageBox]::Show("Előbb telepítsd az Equalizer APO-t, majd indítsd újra az appot.`n`nA pontos lépéseket a TELEPÍTÉS.txt tartalmazza.", 'SoundLift', 'OK', 'Warning') | Out-Null
            return
        }
        if (-not (Test-Administrator)) {
            $answer = [System.Windows.MessageBox]::Show('A beállítás mentéséhez rendszergazdai jogosultság kell. Újraindítsam az appot rendszergazdaként?', 'SoundLift', 'YesNo', 'Question')
            if ($answer -eq 'Yes') {
                Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
                $window.Close()
            }
            return
        }

        $volumePercent = [double]$VolumeSlider.Value
        $bassDb = [double]$BassSlider.Value
        $frequency = [int]$FrequencySlider.Value
        $volumeDb = if ($volumePercent -le 0) { -100.0 } else { 20.0 * [Math]::Log10($volumePercent / 100.0) }
        $maxEqGain = 0.0
        foreach ($eqSlider in $script:eqSliders) { if ([double]$eqSlider.Value -gt $maxEqGain) { $maxEqGain = [double]$eqSlider.Value } }
        if ((-not $SafetyCheck.IsChecked) -and ($volumePercent -gt 200 -or $bassDb -gt 15)) {
            $warning = [System.Windows.MessageBox]::Show('Ez a beállítás torzíthat, károsíthatja a hangszórót és a hallásodat. Biztosan alkalmazod védelem nélkül?', 'Nagyon erős beállítás', 'YesNo', 'Warning')
            if ($warning -ne 'Yes') { return }
        }
        # Reserve headroom for both the volume preamp and overlapping bass filters.
        # This prevents the harsh digital clipping heard with the previous preset.
        $profileHeadroom = if ($script:activeProfile -like 'FiveM*' -or $script:activeProfile -eq 'R6') { 0.5 } else { 0.0 }
        if (-not $SafetyCheck.IsChecked) {
            $safetyReduction = 0.0
        } elseif ($script:activeProfile -eq 'Music') {
            # Music uses gentler protection so it stays lively, while the EQ cuts
            # muddy mids and reserves enough room for bass and treble transients.
            $safetyReduction = [Math]::Min(10.0, ($bassDb * 0.40) + ($maxEqGain * 0.80) + 0.7)
        } else {
            $safetyReduction = [Math]::Min(12.0, [Math]::Max(0.0, ($bassDb * 0.40) + ($maxEqGain * 0.80) + $profileHeadroom))
        }
        $preampDb = if ($volumePercent -le 0) { -100.0 } else { $volumeDb - $safetyReduction }

        $subGain = $bassDb * 0.30
        $mainBassGain = $bassDb * 0.55
        $punchGain = $bassDb * 0.15

        $ownConfig = Join-Path $apoDirectory 'TudomHogyMelegVagy.txt'
        $mainConfig = Join-Path $apoDirectory 'config.txt'
        $backupConfig = Join-Path $apoDirectory 'config.before-TudomHogyMelegVagy.bak'
        if ((Test-Path $mainConfig) -and (-not (Test-Path $backupConfig))) { [IO.File]::Copy($mainConfig, $backupConfig, $false) }
        if (Test-Path $ownConfig) { [IO.File]::Copy($ownConfig, "$ownConfig.undo", $true) }
        $content = @(
            '# SoundLift - managed configuration',
            ('# Volume: {0}% | Bass: {1} dB | Frequency: {2} Hz | Protection: {3}' -f [int]$volumePercent, [int]$bassDb, $frequency, $SafetyCheck.IsChecked),
            ('Preamp: {0} dB' -f $preampDb.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)),
            ('Filter 1: ON LS Fc 45 Hz Gain {0} dB' -f $subGain.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)),
            ('Filter 2: ON PK Fc {0} Hz Gain {1} dB Q 0.90' -f $frequency, $mainBassGain.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)),
            ('Filter 3: ON PK Fc 115 Hz Gain {0} dB Q 1.10' -f $punchGain.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)),
            'Filter 4: ON HPQ Fc 25 Hz Q 0.71'
        )
        $filterNumber = 10
        for ($i = 0; $i -lt $script:eqBands.Count; $i++) {
            $gain = [double]$script:eqSliders[$i].Value
            if ([Math]::Abs($gain) -ge 0.1) {
                $gainText = $gain.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
                $content += ('Filter {0}: ON PK Fc {1} Hz Gain {2} dB Q 1.00' -f $filterNumber, $script:eqBands[$i], $gainText)
                $filterNumber++
            }
        }
        Write-LinesWithRetry $ownConfig $content

        $includeLine = 'Include: TudomHogyMelegVagy.txt'
        $mainText = if (Test-Path $mainConfig) { Read-TextWithRetry $mainConfig } else { '' }
        # Remove every legacy marker and duplicate include, then add one clean
        # SoundLift block. This also repairs config files made by older builds.
        $mainText = [Regex]::Replace($mainText, '(?im)^\s*Include:\s*(?:BassForge|TudomHogyMelegVagy)\.txt\s*\r?\n?', '')
        $mainText = [Regex]::Replace($mainText, '(?im)^\s*#\s*(?:BassForge|Tudom,\s*hogy\s*meleg\s*vagy|SoundLift)\s*\r?\n?', '')
        $mainText = $mainText.TrimEnd() + "`r`n`r`n# SoundLift`r`n$includeLine`r`n"
        Write-TextWithRetry $mainConfig $mainText
        $StatusText.Text = "OK - Beállítás alkalmazva: $([int]$volumePercent)% / $([int]$bassDb) dB"
        $StatusBorder.Background = '#143126'
    } catch {
        Write-SoundLiftLog -Category crash -EventName 'handled_runtime_error' -Severity error -Data @{ component='apply_audio_config' } -ErrorRecord $_
        [System.Windows.MessageBox]::Show("Nem sikerült menteni:`n$($_.Exception.Message)", 'SoundLift – hiba', 'OK', 'Error') | Out-Null
    } finally {
        $script:applyBusy = $false
    }
})

function Invoke-ApplyButton {
    $args = New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)
    $ApplyButton.RaiseEvent($args)
}

function Get-AppState {
    return [PSCustomObject]@{
        version = 5; profile = $script:activeProfile; theme = $script:themeName
        onboardingCompleted = [bool]$script:onboardingCompleted
        volume = [int]$VolumeSlider.Value; bass = [int]$BassSlider.Value; frequency = [int]$FrequencySlider.Value
        safety = [bool]$SafetyCheck.IsChecked; autoProfile = [bool]$AutoProfileCheck.IsChecked; instant = [bool]$InstantCheck.IsChecked
        eq = @($script:eqSliders | ForEach-Object { [int]$_.Value })
    }
}

function Set-AppState($state) {
    if (-not $state) { return }
    $script:activeProfile = if ($state.profile) { [string]$state.profile } else { 'Custom' }
    Set-Profile ([int]$state.volume) ([int]$state.bass) ([int]$state.frequency) ([bool]$state.safety)
    if ($state.eq -and $state.eq.Count -eq 10) { Set-EqValues ([double[]]$state.eq) }
    if ($null -ne $state.autoProfile) { $AutoProfileCheck.IsChecked = [bool]$state.autoProfile }
    if ($null -ne $state.instant) { $InstantCheck.IsChecked = [bool]$state.instant }
    if ($state.theme -and $script:themeNames -contains [string]$state.theme) {
        $ThemeCombo.SelectedItem = [string]$state.theme
        Set-AppTheme ([string]$state.theme)
    }
    if ($null -ne $state.onboardingCompleted) { $script:onboardingCompleted = [bool]$state.onboardingCompleted }
}

$appDataDirectory = Join-Path $env:APPDATA 'TudomHogyMelegVagy'
if (-not (Test-Path $appDataDirectory)) { [void][IO.Directory]::CreateDirectory($appDataDirectory) }
$settingsPath = Join-Path $appDataDirectory 'settings.json'
$customProfilePath = Join-Path $appDataDirectory 'custom-profile.json'
$onboardingMarkerPath = Join-Path $appDataDirectory 'first-run-completed.txt'

function Get-DiagnosticsReport {
    $lines = New-Object Collections.Generic.List[string]
    $errors = 0
    $warnings = 0
    $activeOutput = [AudioAppNative]::GetDefaultOutputName()
    $apo = Get-ApoConfigDirectory

    $lines.Add('SOUNDLIFT – AUTOMATIKUS DIAGNOSZTIKA')
    $lines.Add(('=' * 48))
    $lines.Add("Időpont: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("Alkalmazásverzió: $script:appVersion")
    $lines.Add("Támogatási ID: $(Get-SoundLiftSupportId)")
    $lines.Add("Windows: $([Environment]::OSVersion.VersionString)")
    $lines.Add("Aktív hangkimenet: $activeOutput")
    $lines.Add('')

    if (Test-Administrator) {
        $lines.Add('[OK] Rendszergazdai jogosultság aktív.')
    } else {
        $lines.Add('[HIBA] Az alkalmazás nem rendszergazdaként fut.')
        $errors++
    }

    if ($apo) {
        $lines.Add("[OK] Equalizer APO konfigurációs mappa: $apo")
        $mainConfig = Join-Path $apo 'config.txt'
        $boosterConfig = Join-Path $apo 'TudomHogyMelegVagy.txt'

        if (Test-Path $mainConfig) {
            $lines.Add('[OK] Az Equalizer APO config.txt fájlja megtalálható.')
            try {
                $mainText = [IO.File]::ReadAllText($mainConfig)
                if ($mainText -match '(?im)^\s*Include:\s*TudomHogyMelegVagy\.txt\s*$') {
                    $lines.Add('[OK] A booster Include sora aktív a config.txt fájlban.')
                } else {
                    $lines.Add('[HIBA] Hiányzik a booster Include sora a config.txt fájlból.')
                    $errors++
                }
            } catch {
                $lines.Add("[HIBA] A config.txt nem olvasható: $($_.Exception.Message)")
                $errors++
            }
        } else {
            $lines.Add('[HIBA] Az Equalizer APO config.txt fájlja hiányzik.')
            $errors++
        }

        if (Test-Path $boosterConfig) {
            try {
                $boosterText = [IO.File]::ReadAllText($boosterConfig)
                if ($boosterText -match '(?im)^\s*Preamp:' -and $boosterText -match '(?im)^\s*Filter(?:\s+\d+)?:') {
                    $lines.Add('[OK] A booster saját konfigurációja érvényesnek tűnik.')
                } else {
                    $lines.Add('[FIGYELEM] A booster konfigurációja hiányos. Nyomd meg az ALKALMAZÁS gombot.')
                    $warnings++
                }
            } catch {
                $lines.Add("[HIBA] A booster konfigurációja nem olvasható: $($_.Exception.Message)")
                $errors++
            }
        } else {
            $lines.Add('[FIGYELEM] A booster konfigurációja még nem létezik. Válassz profilt, majd alkalmazd.')
            $warnings++
        }
    } else {
        $lines.Add('[HIBA] Az Equalizer APO telepítése nem található.')
        $errors++
    }

    $conflictProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match 'JBL|Quantum|SteelSeries|Sonar|Nahimic|SonicStudio'
    } | Select-Object -ExpandProperty ProcessName -Unique)
    if ($conflictProcesses.Count -gt 0) {
        $lines.Add("[FIGYELEM] Lehetséges gyártói hangprogram: $($conflictProcesses -join ', ')")
        $lines.Add('           Ha nincs hangváltozás, ez ütközhet az Equalizer APO-val.')
        $warnings++
    } else {
        $lines.Add('[OK] Nem látható ismert, ütközést okozó hangprogram-folyamat.')
    }

    $lines.Add('')
    $lines.Add('FONTOS: azt, hogy az APO ténylegesen az aktív eszközre van-e telepítve,')
    $lines.Add('a Device Selector Status oszlopában kell ellenőrizni.')
    $lines.Add('')
    if ($errors -eq 0 -and $warnings -eq 0) {
        $lines.Add('EREDMÉNY: Nem található nyilvánvaló hiba.')
    } elseif ($errors -eq 0) {
        $lines.Add("EREDMÉNY: $warnings figyelmeztetés található.")
    } else {
        $lines.Add("EREDMÉNY: $errors hiba és $warnings figyelmeztetés található.")
    }
    return $lines -join [Environment]::NewLine
}

function Show-DiagnosticsWindow {
    $report = Get-DiagnosticsReport
    $dialog = [Windows.Window]::new()
    $dialog.Title = "SoundLift $script:appVersion – Diagnosztika"
    $dialog.Width = 760; $dialog.Height = 590; $dialog.MinWidth = 620; $dialog.MinHeight = 440
    $dialog.WindowStartupLocation = 'CenterOwner'; $dialog.Owner = $window
    $dialog.Background = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#0B0B0D'))

    $grid = [Windows.Controls.Grid]::new()
    $grid.Margin = [Windows.Thickness]::new(18)
    $grid.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
    $buttonRow = [Windows.Controls.RowDefinition]::new(); $buttonRow.Height = [Windows.GridLength]::Auto
    $grid.RowDefinitions.Add($buttonRow)

    $reportBox = [Windows.Controls.TextBox]::new()
    $reportBox.Text = $report; $reportBox.IsReadOnly = $true
    $reportBox.AcceptsReturn = $true; $reportBox.TextWrapping = 'NoWrap'
    $reportBox.VerticalScrollBarVisibility = 'Auto'; $reportBox.HorizontalScrollBarVisibility = 'Auto'
    $reportBox.FontFamily = [Windows.Media.FontFamily]::new('Consolas'); $reportBox.FontSize = 13
    $reportBox.Padding = [Windows.Thickness]::new(14)
    $reportBox.Background = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#111113'))
    $reportBox.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#F8FAFC'))
    $reportBox.BorderBrush = $window.Resources['AccentTextBrush']
    [Windows.Controls.Grid]::SetRow($reportBox, 0); $grid.Children.Add($reportBox) | Out-Null

    $buttons = [Windows.Controls.StackPanel]::new()
    $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'
    $buttons.Margin = [Windows.Thickness]::new(0, 12, 0, 0)
    $copyButton = [Windows.Controls.Button]::new(); $copyButton.Content = 'Jelentés másolása'; $copyButton.Margin = [Windows.Thickness]::new(0,0,8,0)
    $saveButton = [Windows.Controls.Button]::new(); $saveButton.Content = 'Mentés TXT-be'; $saveButton.Margin = [Windows.Thickness]::new(0,0,8,0)
    $closeButton = [Windows.Controls.Button]::new(); $closeButton.Content = 'Bezárás'
    $copyButton.Add_Click({
        $copied = $false
        for ($attempt = 1; $attempt -le 10 -and -not $copied; $attempt++) {
            try {
                [Windows.Forms.Clipboard]::SetText($report)
                $copied = $true
            } catch {
                if ($attempt -lt 10) { Start-Sleep -Milliseconds 120 }
            }
        }
        if ($copied) {
            $StatusText.Text = 'OK - Diagnosztikai jelentés a vágólapra másolva'
        } else {
            [System.Windows.MessageBox]::Show('A Windows vágólapja jelenleg foglalt. Zárd be a vágólapot használó programot, majd próbáld újra.', 'Másolási hiba', 'OK', 'Warning') | Out-Null
        }
    }.GetNewClosure())
    $saveButton.Add_Click({
        $saveDialog = [Microsoft.Win32.SaveFileDialog]::new()
        $saveDialog.Filter = 'Szövegfájl (*.txt)|*.txt'
        $saveDialog.FileName = "SoundLift-diagnosztika-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
        if ($saveDialog.ShowDialog()) { [IO.File]::WriteAllText($saveDialog.FileName, $report, [Text.Encoding]::UTF8) }
    }.GetNewClosure())
    $closeButton.Add_Click({ $dialog.Close() }.GetNewClosure())
    $buttons.Children.Add($copyButton) | Out-Null; $buttons.Children.Add($saveButton) | Out-Null; $buttons.Children.Add($closeButton) | Out-Null
    [Windows.Controls.Grid]::SetRow($buttons, 1); $grid.Children.Add($buttons) | Out-Null
    $dialog.Content = $grid
    $dialog.ShowDialog() | Out-Null
}

$DiagnosticsButton.Add_Click({ Show-DiagnosticsWindow })

function Get-SoundLiftRollbackState {
    $rollbackDirectory = Join-Path $script:appDirectory 'rollback'
    $backupPath = Join-Path $rollbackDirectory 'SoundLift.previous.exe'
    $statePath = Join-Path $rollbackDirectory 'rollback-state.json'
    if (-not (Test-Path $backupPath) -or -not (Test-Path $statePath)) { return $null }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$state.sha256) -or [string]::IsNullOrWhiteSpace([string]$state.version)) { return $null }
        $backupVersion = [version]([string]$state.version)
        if ($backupVersion -ge [version]$script:appVersion) { return $null }
        $actualHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actualHash -ne ([string]$state.sha256).ToLowerInvariant()) { return $null }
        return [PSCustomObject]@{ path=$backupPath; version=[string]$state.version; sha256=$actualHash }
    } catch { return $null }
}

function Save-SoundLiftRollbackCopy {
    if ($script:currentLicenseType -ne 'developer') { return }
    if (-not $script:isPackagedExe -or -not (Test-Path $script:appLaunchPath)) { throw 'A futó alkalmazás nem menthető visszaállításhoz.' }
    $rollbackDirectory = Join-Path $script:appDirectory 'rollback'
    [IO.Directory]::CreateDirectory($rollbackDirectory) | Out-Null
    $backupPath = Join-Path $rollbackDirectory 'SoundLift.previous.exe'
    [IO.File]::Copy($script:appLaunchPath, $backupPath, $true)
    $hash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $state = @{ version=$script:appVersion; sha256=$hash; created_utc=[DateTime]::UtcNow.ToString('o') }
    [IO.File]::WriteAllText((Join-Path $rollbackDirectory 'rollback-state.json'), ($state | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}

function Restore-SoundLiftPreviousVersion {
    if ($script:currentLicenseType -ne 'developer') {
        Write-SoundLiftLog -Category security -EventName 'license_rejected' -Severity warning -Data @{ code='ROLLBACK_NOT_DEVELOPER' }
        return
    }
    $state = Get-SoundLiftRollbackState
    if (-not $state) { [System.Windows.MessageBox]::Show('Nem található sértetlen előző verzió.', 'SoundLift – Visszaállítás', 'OK', 'Warning') | Out-Null; return }
    $answer = [System.Windows.MessageBox]::Show("Biztosan visszaállítod a SoundLift $($state.version) verzióját?`n`nA program újra fog indulni.", 'SoundLift – Előző verzió', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    try {
        $targetPath = $script:appLaunchPath
        $command = "Start-Sleep -Seconds 2; `$actual=(Get-FileHash -LiteralPath '$($state.path.Replace("'", "''"))' -Algorithm SHA256).Hash.ToLowerInvariant(); if (`$actual -ne '$($state.sha256)') { exit 2 }; Copy-Item -LiteralPath '$($state.path.Replace("'", "''"))' -Destination '$($targetPath.Replace("'", "''"))' -Force; Start-Process -FilePath '$($targetPath.Replace("'", "''"))'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        Write-SoundLiftLog -Category update -EventName 'version_changed' -Data @{ old_version=$script:appVersion; new_version=$state.version; result='rollback_started' }
        Send-SoundLiftPendingLogs
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-NonInteractive','-WindowStyle','Hidden','-EncodedCommand',$encoded -ErrorAction Stop
        $script:reallyExit=$true; $window.Close()
    } catch { [System.Windows.MessageBox]::Show("A visszaállítás nem indítható el:`n$($_.Exception.Message)", 'SoundLift – Visszaállítás', 'OK', 'Error') | Out-Null }
}

$RollbackButton.Visibility = 'Collapsed'; $RollbackButton.IsEnabled = $false
$RollbackButton.Add_Click({ Restore-SoundLiftPreviousVersion })

function Update-DeveloperControls {
    $displayType = switch ($script:currentLicenseType) { 'developer' { 'fejlesztői' } 'customer' { 'vásárlói' } default { 'ingyenes' } }
    $LicenseStatusText.Text = "Licenc: $displayType"
    $LicenseButton.Content = if ($script:currentLicenseType -eq 'free') { '🔑  Licenc aktiválása' } else { '🔑  Licenc cseréje' }
    if ($script:currentLicenseType -eq 'developer') {
        $RollbackButton.Visibility = 'Visible'
        $RollbackButton.IsEnabled = $null -ne (Get-SoundLiftRollbackState)
    } else {
        $RollbackButton.Visibility = 'Collapsed'; $RollbackButton.IsEnabled = $false
    }
}

$LicenseButton.Add_Click({
    if (Confirm-SoundLiftLicense -PromptForKey) {
        Update-DeveloperControls
        if ($script:currentLicenseType -ne 'free') {
            $StatusText.Text = "OK - $($LicenseStatusText.Text) aktiválva"
        }
    }
})

function Install-SoundLiftUpdate([object]$release, [version]$latestVersion, [Windows.Controls.TextBlock]$statusText, [Windows.Controls.Button]$installButton) {
    $temporaryDirectory = $null
    try {
        $installerAsset = @($release.assets | Where-Object { $_.name -eq 'SoundLift Setup.exe' }) | Select-Object -First 1
        $checksumAsset = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' }) | Select-Object -First 1
        if (-not $installerAsset -or -not $checksumAsset) { throw 'A kiadásból hiányzik a telepítő vagy az ellenőrzőösszeg.' }
        foreach ($asset in @($installerAsset, $checksumAsset)) {
            $assetUri = [Uri]([string]$asset.browser_download_url)
            if ($assetUri.Scheme -ne 'https' -or $assetUri.Host -ne 'github.com') { throw 'A frissítés letöltési címe nem engedélyezett.' }
        }
        $installButton.IsEnabled = $false; $installButton.Content = 'Frissítés folyamatban…'; $statusText.Text = 'Letöltés folyamatban…'
        [Windows.Forms.Application]::DoEvents()
        $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('SoundLiftUpdate-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
        $installerPath = Join-Path $temporaryDirectory 'SoundLift Setup.exe'
        $checksumPath = Join-Path $temporaryDirectory 'SHA256SUMS.txt'
        $downloadHeaders = @{ 'User-Agent'="SoundLift/$($script:appVersion)"; 'Accept'='application/octet-stream' }
        Invoke-WebRequest -UseBasicParsing -Uri ([string]$installerAsset.browser_download_url) -Headers $downloadHeaders -OutFile $installerPath -TimeoutSec 120
        Invoke-WebRequest -UseBasicParsing -Uri ([string]$checksumAsset.browser_download_url) -Headers $downloadHeaders -OutFile $checksumPath -TimeoutSec 30
        $statusText.Text = 'Telepítő ellenőrzése…'; [Windows.Forms.Application]::DoEvents()
        $checksumLine = Get-Content -LiteralPath $checksumPath | Where-Object { $_ -match '(?i)^[a-f0-9]{64}\s+\*?SoundLift Setup\.exe$' } | Select-Object -First 1
        if (-not $checksumLine) { throw 'A telepítő ellenőrzőösszege nem található.' }
        $expectedHash = ([regex]::Match($checksumLine, '(?i)^[a-f0-9]{64}')).Value.ToLowerInvariant()
        $actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) { throw 'A letöltött telepítő ellenőrzése sikertelen.' }
        Save-SoundLiftRollbackCopy
        $statusText.Text = 'Frissítés telepítése…'; [Windows.Forms.Application]::DoEvents()
        Write-SoundLiftLog -Category update -EventName 'download_page_opened' -Data @{ old_version=$script:appVersion; new_version=$latestVersion; result='automatic_installer_started' }
        Send-SoundLiftPendingLogs
        Start-Process -FilePath $installerPath -ArgumentList '/SILENT','/SUPPRESSMSGBOXES','/NORESTART','/CLOSEAPPLICATIONS' -ErrorAction Stop
        return $true
    } catch {
        Write-SoundLiftLog -Category update -EventName 'update_check_failed' -Severity error -ErrorRecord $_ -Data @{ new_version=$latestVersion; stage='automatic_install' }
        $statusText.Text = "A frissítés sikertelen: $($_.Exception.Message)"
        $installButton.Content = 'Újrapróbálás'; $installButton.IsEnabled = $true
        if ($temporaryDirectory -and (Test-Path $temporaryDirectory)) { try { Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force } catch { } }
        return $false
    }
}

function Show-AppUpdateDialog([object]$release, [version]$latestVersion) {
    $dialog=[Windows.Window]::new(); $dialog.Title='SoundLift – Frissítés'; $dialog.Width=520; $dialog.Height=285
    $dialog.ResizeMode='NoResize'; $dialog.WindowStartupLocation='CenterOwner'; $dialog.Owner=$window; $dialog.Background='#09090B'; $dialog.Foreground='#F8FAFC'
    $panel=[Windows.Controls.StackPanel]::new(); $panel.Margin=[Windows.Thickness]::new(28)
    $title=[Windows.Controls.TextBlock]::new(); $title.Text='Új SoundLift-frissítés érhető el'; $title.FontSize=23; $title.FontWeight='Bold'; $title.Foreground='#FF4057'
    $details=[Windows.Controls.TextBlock]::new(); $details.Text="Telepített verzió: $script:appVersion`nÚj verzió: $latestVersion"; $details.FontSize=14; $details.Margin=[Windows.Thickness]::new(0,16,0,14)
    $status=[Windows.Controls.TextBlock]::new(); $status.Text='A frissítés automatikusan letöltődik és települ.'; $status.TextWrapping='Wrap'; $status.Foreground='#CBD5E1'; $status.Margin=[Windows.Thickness]::new(0,0,0,18)
    $buttons=[Windows.Controls.StackPanel]::new(); $buttons.Orientation='Horizontal'; $buttons.HorizontalAlignment='Right'
    $later=[Windows.Controls.Button]::new(); $later.Content='Később'; $later.Width=100; $later.Margin=[Windows.Thickness]::new(0,0,10,0)
    $install=[Windows.Controls.Button]::new(); $install.Content='Frissítés telepítése'; $install.Width=175
    $later.Add_Click({ $dialog.Close() }.GetNewClosure())
    $install.Add_Click({
        if (Install-SoundLiftUpdate $release $latestVersion $status $install) {
            $dialog.Close(); $script:reallyExit=$true; $window.Close()
        }
    }.GetNewClosure())
    $buttons.Children.Add($later)|Out-Null; $buttons.Children.Add($install)|Out-Null
    foreach($control in @($title,$details,$status,$buttons)){ $panel.Children.Add($control)|Out-Null }
    $dialog.Content=$panel; $dialog.ShowDialog()|Out-Null
}

function Check-AppUpdate {
    param([switch]$Silent)
    Write-SoundLiftLog -Category update -EventName 'update_check_started'
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Idkbroo1763/idkbroo-booster/releases/latest' -Headers @{ 'User-Agent'="SoundLift/$($script:appVersion)"; 'Accept'='application/vnd.github+json' } -TimeoutSec 12
        $latestVersion = [version](([string]$release.tag_name).Trim().TrimStart([char[]]'vV'))
        $currentVersion = [version]$script:appVersion
        if ($latestVersion -gt $currentVersion) {
            Write-SoundLiftLog -Category update -EventName 'update_available' -Data @{ old_version=$currentVersion; new_version=$latestVersion }
            Show-AppUpdateDialog $release $latestVersion
        } elseif (-not $Silent) {
            Write-SoundLiftLog -Category update -EventName 'update_check_succeeded' -Data @{ result='up_to_date'; current_version=$currentVersion }
            [System.Windows.MessageBox]::Show("A program naprakész.`nTelepített verzió: $currentVersion", 'SoundLift – Frissítés', 'OK', 'Information') | Out-Null
        } else { Write-SoundLiftLog -Category update -EventName 'update_check_succeeded' -Data @{ result='up_to_date'; current_version=$currentVersion } }
    } catch {
        Write-SoundLiftLog -Category update -EventName 'update_check_failed' -Severity warning -ErrorRecord $_
        if (-not $Silent) { [System.Windows.MessageBox]::Show("A frissítés most nem ellenőrizhető.`n`n$($_.Exception.Message)", 'SoundLift – Frissítés', 'OK', 'Warning') | Out-Null }
    }
}
$UpdateButton.Add_Click({ Check-AppUpdate })

function Show-AboutWindow {
    $dialog = [Windows.Window]::new()
    $dialog.Title = 'Névjegy – SoundLift'; $dialog.Width = 620; $dialog.Height = 535
    $dialog.ResizeMode = 'NoResize'; $dialog.WindowStartupLocation = 'CenterOwner'; $dialog.Owner = $window
    $dialog.Background = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#09090B'))
    if (Test-Path $appIconPath) { try { $dialog.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$appIconPath) } catch { } }

    $root = [Windows.Controls.Grid]::new(); $root.Margin = [Windows.Thickness]::new(28)
    $root.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
    $actionsRow = [Windows.Controls.RowDefinition]::new(); $actionsRow.Height = [Windows.GridLength]::Auto; $root.RowDefinitions.Add($actionsRow)
    $card = [Windows.Controls.Border]::new(); $card.CornerRadius = [Windows.CornerRadius]::new(18); $card.Padding = [Windows.Thickness]::new(24)
    $card.Background = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#111113'))
    $card.BorderBrush = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#29292E')); $card.BorderThickness = [Windows.Thickness]::new(1)
    $content = [Windows.Controls.StackPanel]::new()
    $brand = [Windows.Controls.TextBlock]::new(); $brand.Text = 'SOUNDLIFT'; $brand.FontSize = 29; $brand.FontWeight = 'Bold'; $brand.Foreground = $window.Resources['AccentTextBrush']
    $version = [Windows.Controls.TextBlock]::new(); $version.Text = "Windows rendszerhang-kezelő  •  V$script:appVersion"; $version.FontSize = 12; $version.Foreground = [Windows.Media.Brushes]::Gray; $version.Margin = [Windows.Thickness]::new(0,5,0,20)
    $description = [Windows.Controls.TextBlock]::new(); $description.Text = 'A SoundLift egy ingyenes Windows-hangvezérlő, amellyel profilok, basszuskiemelés, tízsávos equalizer és akár 300%-os hangerő-erősítés használható az Equalizer APO segítségével.'; $description.TextWrapping = 'Wrap'; $description.FontSize = 14; $description.LineHeight = 22; $description.Foreground = [Windows.Media.Brushes]::LightGray
    $creator = [Windows.Controls.TextBlock]::new(); $creator.Text = "Készítette: ɪᴅᴋʙʀᴏᴏ`nDiscord: idkbroo_6"; $creator.FontSize = 14; $creator.FontWeight = 'SemiBold'; $creator.Foreground = [Windows.Media.Brushes]::White; $creator.Margin = [Windows.Thickness]::new(0,22,0,18)
    $copyright = [Windows.Controls.TextBlock]::new(); $copyright.Text = '© 2026 idkbroo. Minden jog fenntartva. A SoundLift független projekt; az Equalizer APO neve és jogai a saját tulajdonosait illetik. A túl magas hangerő halláskárosodást okozhat.'; $copyright.TextWrapping = 'Wrap'; $copyright.FontSize = 11; $copyright.LineHeight = 17; $copyright.Foreground = [Windows.Media.Brushes]::Gray
    $content.Children.Add($brand) | Out-Null; $content.Children.Add($version) | Out-Null; $content.Children.Add($description) | Out-Null; $content.Children.Add($creator) | Out-Null; $content.Children.Add($copyright) | Out-Null
    $card.Child = $content; [Windows.Controls.Grid]::SetRow($card, 0); $root.Children.Add($card) | Out-Null

    $actions = [Windows.Controls.Grid]::new(); $actions.Margin = [Windows.Thickness]::new(0,14,0,0)
    $actions.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new()); $actions.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $discordButton = [Windows.Controls.Button]::new(); $discordButton.Content = 'Csatlakozás a Discord-szerverhez'; $discordButton.Height = 46; $discordButton.Margin = [Windows.Thickness]::new(0,0,8,0); $discordButton.Style = $window.Resources['PrimaryButton']
    $closeButton = [Windows.Controls.Button]::new(); $closeButton.Content = 'Bezárás'; $closeButton.Height = 46; $closeButton.Margin = [Windows.Thickness]::new(8,0,0,0); $closeButton.Style = $window.Resources['UtilityButton']
    $discordButton.Add_Click({ try { Start-Process 'https://discord.gg/h9CaQ47gDT' } catch { [System.Windows.MessageBox]::Show('A Discord-link nem nyitható meg.', 'Névjegy', 'OK', 'Warning') | Out-Null } })
    $closeButton.Add_Click({ $dialog.Close() }.GetNewClosure())
    $actions.Children.Add($discordButton) | Out-Null; [Windows.Controls.Grid]::SetColumn($closeButton, 1); $actions.Children.Add($closeButton) | Out-Null
    [Windows.Controls.Grid]::SetRow($actions, 1); $root.Children.Add($actions) | Out-Null
    $dialog.Content = $root; $dialog.ShowDialog() | Out-Null
}
$AboutButton.Add_Click({ Show-AboutWindow })

function Show-ChangelogWindow {
    $changelog = @"
V1.3.0 – EGYSÉGES ALKALMAZÁS ÉS LICENC
• Ugyanaz a telepítő használható ingyenes, vásárlói és fejlesztői módban.
• A licenc az alkalmazásban aktiválható, és frissítés után is megmarad.
• A fejlesztői visszaállítás továbbra is kizárólag developer licenccel érhető el.

V1.2.2 – AUTOMATIKUS FRISSÍTÉS
• Indításkor automatikusan ellenőrzi a legújabb nyilvános kiadást.
• Egy gombnyomással letölti és elindítja az új telepítőt.
• Telepítés előtt SHA-256 ellenőrzéssel védi a letöltött fájlt.
• Látható és egy kattintással másolható támogatási azonosító.
• Részletes letöltési, ellenőrzési és telepítési állapot, hiba után újrapróbálással.
• Az automatikus frissítés előtt mentett, ellenőrzött előző verzió visszaállítható.

V1.2.0 – DISCORD-FIÓK ÖSSZEKAPCSOLÁS
• Kötelező, hitelesített Discord OAuth-kapcsolat az alkalmazás használatához.
• Frissítés után is megmaradó kapcsolat és 72 órás védelem rövid backend-kiesésre.
• A logokban rövid támogatási ID és a hitelesített Discord-felhasználó jelenik meg.
• Egyszer használható, 10 perc után lejáró összekapcsolási munkamenetek.

V1.1.0 – KÖZPONTI NAPLÓZÁS
• Helyi technikai naplók és következő indításkor újrapróbált hibajelentések.
• Indítási, összeomlási, frissítési, licenc- és biztonsági események.
• Fejlesztői tesztlicenc-hozzáférések külön naplózása.
• Biztonságos backend-továbbítás: nincs Discord webhook vagy titkos kulcs a kliensben.

V1.0.1 – BIZTONSÁGI FRISSÍTÉS
• Frissítési hivatkozások átállítva az új hivatalos GitHub-címre.
• Biztonságosabb, méret- és értékkorlátos profilimportálás.
• A hangeszközválasztó csak az Equalizer APO ismert programjait indítja el.
• Rögzített buildfüggőségek és SHA-256 ellenőrzőösszeg a letöltésekhez.

V1.0.0 – ELSŐ NYILVÁNOS KIADÁS
• Modern, témázható Windows-felület.
• 0–300%-os hangerő-erősítés.
• Zene, FiveM, R6, Discord és Film profilok.
• Finomhangolt, kevésbé dobozos játék-, beszéd-, film- és basszusprofilok.
• Tízsávos equalizer, basszuskiemelés és torzításvédelem.
• Saját profil mentése, betöltése, importálása és exportálása.
• Automatikus profilváltás és globális gyorsbillentyűk.
• Első indítási varázsló és beépített diagnosztika.
• Automatikus frissítésellenőrzés és frissítési előzmények.
• Névjegy, közvetlen Discord-kapcsolat és részletes telepítési útmutató.
"@
    $dialog = [Windows.Window]::new()
    $dialog.Title = "SoundLift $script:appVersion – Frissítési előzmények"
    $dialog.Width = 720; $dialog.Height = 590; $dialog.MinWidth = 560; $dialog.MinHeight = 420
    $dialog.WindowStartupLocation = 'CenterOwner'; $dialog.Owner = $window
    $dialog.Background = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#09090B'))
    $grid = [Windows.Controls.Grid]::new(); $grid.Margin = [Windows.Thickness]::new(22)
    $grid.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
    $buttonRow = [Windows.Controls.RowDefinition]::new(); $buttonRow.Height = [Windows.GridLength]::Auto; $grid.RowDefinitions.Add($buttonRow)
    $box = [Windows.Controls.TextBox]::new(); $box.Text = $changelog.Trim(); $box.IsReadOnly = $true; $box.AcceptsReturn = $true
    $box.TextWrapping = 'Wrap'; $box.VerticalScrollBarVisibility = 'Auto'; $box.FontSize = 14; $box.Padding = [Windows.Thickness]::new(16)
    $box.Background = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#111113'))
    $box.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#F8FAFC'))
    $box.BorderBrush = $window.Resources['AccentTextBrush']; [Windows.Controls.Grid]::SetRow($box, 0); $grid.Children.Add($box) | Out-Null
    $close = [Windows.Controls.Button]::new(); $close.Content = 'Bezárás'; $close.Width = 115; $close.Height = 38; $close.HorizontalAlignment = 'Right'; $close.Margin = [Windows.Thickness]::new(0,12,0,0)
    $close.Add_Click({ $dialog.Close() }.GetNewClosure()); [Windows.Controls.Grid]::SetRow($close, 1); $grid.Children.Add($close) | Out-Null
    $dialog.Content = $grid; $dialog.ShowDialog() | Out-Null
}
$ChangelogButton.Add_Click({ Show-ChangelogWindow })

function Show-FirstRunWizard {
    $wizard = [Windows.Window]::new()
    $wizard.Title = 'SoundLift – Első indítás'; $wizard.Width = 650; $wizard.Height = 470
    $wizard.ResizeMode = 'NoResize'; $wizard.WindowStartupLocation = 'CenterOwner'; $wizard.Owner = $window
    $wizard.Background = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#09090B'))
    $root = [Windows.Controls.Grid]::new(); $root.Margin = [Windows.Thickness]::new(28)
    $root.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
    $navRow = [Windows.Controls.RowDefinition]::new(); $navRow.Height = [Windows.GridLength]::Auto; $root.RowDefinitions.Add($navRow)
    $content = [Windows.Controls.StackPanel]::new()
    $stepText = [Windows.Controls.TextBlock]::new(); $stepText.Foreground = [Windows.Media.Brushes]::Gray; $stepText.FontSize = 12
    $titleText = [Windows.Controls.TextBlock]::new(); $titleText.Foreground = [Windows.Media.Brushes]::White; $titleText.FontSize = 26; $titleText.FontWeight = 'Bold'; $titleText.Margin = [Windows.Thickness]::new(0,10,0,16)
    $bodyText = [Windows.Controls.TextBlock]::new(); $bodyText.Foreground = [Windows.Media.Brushes]::LightGray; $bodyText.FontSize = 15; $bodyText.LineHeight = 25; $bodyText.TextWrapping = 'Wrap'
    $content.Children.Add($stepText) | Out-Null; $content.Children.Add($titleText) | Out-Null; $content.Children.Add($bodyText) | Out-Null
    [Windows.Controls.Grid]::SetRow($content, 0); $root.Children.Add($content) | Out-Null
    $nav = [Windows.Controls.StackPanel]::new(); $nav.Orientation = 'Horizontal'; $nav.HorizontalAlignment = 'Right'; $nav.Margin = [Windows.Thickness]::new(0,20,0,0)
    $back = [Windows.Controls.Button]::new(); $back.Content = 'Vissza'; $back.Width = 105; $back.Height = 38; $back.Margin = [Windows.Thickness]::new(0,0,10,0)
    $next = [Windows.Controls.Button]::new(); $next.Content = 'Tovább'; $next.Width = 125; $next.Height = 38
    $nav.Children.Add($back) | Out-Null; $nav.Children.Add($next) | Out-Null; [Windows.Controls.Grid]::SetRow($nav, 1); $root.Children.Add($nav) | Out-Null
    $apo = Get-ApoConfigDirectory; $output = [AudioAppNative]::GetDefaultOutputName()
    $adminState = if (Test-Administrator) { 'Rendben' } else { 'Nincs rendszergazdai jogosultság' }
    $apoState = if ($apo) { 'Telepítve' } else { 'Nem található' }
    $pages = @(
        @{ Title='Üdv a SoundLiftben!'; Body="Ez a rövid beállítás segít, hogy a hangerő- és EQ-profilok valóban a megfelelő hangeszközön működjenek.`n`nA program az Equalizer APO-ra épül, ezért annak telepítve kell lennie." },
        @{ Title='Gyors rendszerellenőrzés'; Body="Equalizer APO: $apoState`nRendszergazdai futtatás: $adminState`nAktív hangkimenet: $output`n`nHa az APO nem található, telepítsd az Equalizer APO-t, majd indítsd újra ezt a programot." },
        @{ Title='Műszaki naplózás'; Body="A SoundLift működési, frissítési és hibaeseményeket naplóz a %LOCALAPPDATA%\SoundLift\logs mappába. Ha a kiadásban be van állítva a naplószerver, a szükséges technikai eseményeket hibakeresés és biztonság céljából annak is elküldi.`n`nNem küldünk nyers licenckulcsot, Windows-felhasználónevet, teljes gépazonosítót vagy kattintási előzményt." },
        @{ Title='Már majdnem kész'; Body="1. Nyisd meg a Hangeszközök menüt.`n2. Pipáld ki az aktív lejátszóeszközt.`n3. Indítsd újra a Windowst, ha az APO ezt kéri.`n4. Válassz egy profilt, majd nyomd meg az ALKALMAZÁS gombot.`n`nA Diagnosztika gomb később segít a hibakeresésben." }
    )
    $wizardState = @{ Page = 0 }
    $refreshPage = { $page = [int]$wizardState.Page; $stepText.Text = "ELSŐ INDÍTÁS  •  $($page + 1) / $($pages.Count)"; $titleText.Text = $pages[$page].Title; $bodyText.Text = $pages[$page].Body; $back.IsEnabled = $page -gt 0; $next.Content = if ($page -eq $pages.Count - 1) { 'Befejezés' } else { 'Tovább' } }
    $back.Add_Click({ if ($wizardState.Page -gt 0) { $wizardState.Page--; & $refreshPage } }.GetNewClosure())
    $next.Add_Click({ if ($wizardState.Page -lt $pages.Count - 1) { $wizardState.Page++; & $refreshPage; return }; try { [IO.File]::WriteAllText($onboardingMarkerPath, 'completed', [Text.Encoding]::UTF8); $state = Get-AppState; $state.onboardingCompleted = $true; $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8 } catch { }; $wizard.Close() }.GetNewClosure())
    & $refreshPage; $wizard.Content = $root; $wizard.ShowDialog() | Out-Null
}

$SaveButton.Add_Click({
    (Get-AppState) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $customProfilePath -Encoding UTF8
    $StatusText.Text = 'OK - Saját profil elmentve'
})
$LoadButton.Add_Click({
    if (Test-Path $customProfilePath) { Set-AppState (Get-Content -LiteralPath $customProfilePath -Raw | ConvertFrom-Json); $StatusText.Text = 'OK - Saját profil betöltve' }
})
$ExportButton.Add_Click({
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'EQ profil (*.json)|*.json'; $dialog.FileName = 'sajat-hangprofil.json'
    if ($dialog.ShowDialog()) { (Get-AppState) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $dialog.FileName -Encoding UTF8 }
})

function Test-ImportedProfile($state) {
    if ($null -eq $state) { throw 'A profil üres vagy nem érvényes JSON-fájl.' }
    $names = @($state.PSObject.Properties.Name)
    foreach ($required in @('volume','bass','frequency','eq')) {
        if ($names -notcontains $required) { throw "Hiányzó profilmező: $required" }
    }

    $volume = [double]$state.volume; $bass = [double]$state.bass; $frequency = [double]$state.frequency
    if ([double]::IsNaN($volume) -or [double]::IsInfinity($volume) -or $volume -lt 0 -or $volume -gt 300) { throw 'A hangerő csak 0 és 300 között lehet.' }
    if ([double]::IsNaN($bass) -or [double]::IsInfinity($bass) -or $bass -lt 0 -or $bass -gt 24) { throw 'A basszus csak 0 és 24 dB között lehet.' }
    if ([double]::IsNaN($frequency) -or [double]::IsInfinity($frequency) -or $frequency -lt 40 -or $frequency -gt 160) { throw 'A frekvencia csak 40 és 160 Hz között lehet.' }
    if ($state.eq.Count -ne 10) { throw 'Az EQ-profilnak pontosan 10 sávot kell tartalmaznia.' }
    foreach ($value in $state.eq) {
        $gain = [double]$value
        if ([double]::IsNaN($gain) -or [double]::IsInfinity($gain) -or $gain -lt -12 -or $gain -gt 12) { throw 'Minden EQ-értéknek -12 és +12 dB között kell lennie.' }
    }
    if ($state.theme -and $script:themeNames -notcontains [string]$state.theme) { throw 'Ismeretlen témabeállítás található a profilban.' }
}

$ImportButton.Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'EQ profil (*.json)|*.json'
    if ($dialog.ShowDialog()) {
        try {
            $file = Get-Item -LiteralPath $dialog.FileName -ErrorAction Stop
            if ($file.Length -gt 65536) { throw 'A profilfájl túl nagy. A megengedett maximum 64 KB.' }
            $state = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            Test-ImportedProfile $state
            Set-AppState $state
            $StatusText.Text = 'OK - Biztonságosan ellenőrzött profil importálva'
        } catch {
            [System.Windows.MessageBox]::Show("A profil nem importálható:`n$($_.Exception.Message)", 'Érvénytelen profil', 'OK', 'Warning') | Out-Null
        }
    }
})
$UndoButton.Add_Click({
    $apo = Get-ApoConfigDirectory
    if ($apo) {
        $own = Join-Path $apo 'TudomHogyMelegVagy.txt'; $undo = "$own.undo"
        if (Test-Path $undo) { [IO.File]::Copy($undo, $own, $true); $StatusText.Text = 'OK - Előző alkalmazott hang visszaállítva' }
    }
})
$BypassButton.Add_Click({
    $apo = Get-ApoConfigDirectory
    if ($apo) {
        $main = Join-Path $apo 'config.txt'
        if (Test-Path $main) {
            $text = [IO.File]::ReadAllText($main)
            $text = [Regex]::Replace($text, '(?im)^\s*Include:\s*(?:BassForge|TudomHogyMelegVagy)\.txt\s*\r?\n?', '')
            $text = [Regex]::Replace($text, '(?im)^\s*#\s*(?:BassForge|Tudom,\s*hogy\s*meleg\s*vagy|SoundLift)\s*\r?\n?', '')
            $text = $text.TrimEnd() + "`r`n"
            Write-TextWithRetry $main $text
            $StatusText.Text = 'KIKAPCSOLVA - Nyomj Alkalmazást a visszakapcsoláshoz'; $StatusBorder.Background = '#4A1F2D'
        }
    }
})
$DeviceButton.Add_Click({
    $apoConfig = Get-ApoConfigDirectory
    $installDirectory = if ($apoConfig) { Split-Path $apoConfig -Parent } else { $null }
    $candidates = @()
    if ($installDirectory) {
        $candidates += Join-Path $installDirectory 'DeviceSelector.exe'
        $candidates += Join-Path $installDirectory 'Configurator.exe'
    }
    $selector = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($selector) {
        try {
            $selectorDirectory = [IO.Path]::GetDirectoryName([string]$selector)
            $platformDirectory = Join-Path $selectorDirectory 'platforms'
            $oldQtPlatformPath = $env:QT_QPA_PLATFORM_PLUGIN_PATH
            if (Test-Path $platformDirectory) {
                $env:QT_QPA_PLATFORM_PLUGIN_PATH = $platformDirectory
            }

            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = $selector
            $startInfo.WorkingDirectory = $selectorDirectory
            $startInfo.UseShellExecute = $true
            $startInfo.Verb = 'runas'
            [void][Diagnostics.Process]::Start($startInfo)

            $env:QT_QPA_PLATFORM_PLUGIN_PATH = $oldQtPlatformPath
        } catch {
            $env:QT_QPA_PLATFORM_PLUGIN_PATH = $oldQtPlatformPath
            Write-SoundLiftLog -Category crash -EventName 'handled_runtime_error' -Severity error -Data @{ component='device_selector' } -ErrorRecord $_
            [System.Windows.MessageBox]::Show("A hangeszközválasztó nem indítható el:`n$($_.Exception.Message)", 'Eszközök') | Out-Null
        }
    } else {
        [System.Windows.MessageBox]::Show('Az Equalizer APO eszközválasztó nem található.', 'Eszközök') | Out-Null
    }
})

function Play-TestTone([int]$frequency = 60, [double]$seconds = 1.5) {
    $sampleRate = 44100; $samples = [int]($sampleRate * $seconds); $stream = New-Object IO.MemoryStream; $writer = New-Object IO.BinaryWriter($stream)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int](36 + $samples * 2)); $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16); $writer.Write([int16]1); $writer.Write([int16]1); $writer.Write([int]$sampleRate); $writer.Write([int]($sampleRate * 2)); $writer.Write([int16]2); $writer.Write([int16]16); $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([int]($samples * 2))
    for ($i = 0; $i -lt $samples; $i++) { $fade = [Math]::Min(1.0, [Math]::Min($i / 2205.0, ($samples - $i) / 2205.0)); $writer.Write([int16](7000 * $fade * [Math]::Sin(2 * [Math]::PI * $frequency * $i / $sampleRate))) }
    $stream.Position = 0; $player = New-Object Media.SoundPlayer($stream); $player.PlaySync(); $writer.Dispose(); $stream.Dispose()
}
$TestButton.Add_Click({ Play-TestTone 60 1.5 })

# Debounced instant mode prevents excessive disk writes while dragging.
$instantTimer = New-Object Windows.Threading.DispatcherTimer
$instantTimer.Interval = [TimeSpan]::FromMilliseconds(550)
$instantTimer.Add_Tick({ $instantTimer.Stop(); if ($InstantCheck.IsChecked) { Invoke-ApplyButton } })
$scheduleInstant = { if ($InstantCheck.IsChecked) { $instantTimer.Stop(); $instantTimer.Start() }; Update-Labels }
$VolumeSlider.Add_ValueChanged($scheduleInstant)
$BassSlider.Add_ValueChanged($scheduleInstant)
$FrequencySlider.Add_ValueChanged($scheduleInstant)
$SafetyCheck.Add_Click({ Update-Labels; if ($InstantCheck.IsChecked) { Invoke-ApplyButton } })
foreach ($eqSlider in $script:eqSliders) { $eqSlider.Add_ValueChanged($scheduleInstant) }

# Optional automatic switching: FiveM has priority, followed by Spotify and Discord.
$script:lastAutoProfile = ''
$autoTimer = New-Object Windows.Threading.DispatcherTimer
$autoTimer.Interval = [TimeSpan]::FromSeconds(4)
$autoTimer.Add_Tick({
    if (-not $AutoProfileCheck.IsChecked) { return }
    $processNames = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName)
    $wanted = if ($processNames -match 'FiveM|FiveM_GTAProcess|GTAProcess') { 'FiveM' } elseif ($processNames -contains 'Spotify') { 'Music' } elseif ($processNames -contains 'Discord') { 'Discord' } else { '' }
    if ($wanted -and $wanted -ne $script:lastAutoProfile) {
        $script:lastAutoProfile = $wanted
        if ($wanted -eq 'FiveM') { $GameButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
        elseif ($wanted -eq 'Music') { $MusicButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
        elseif ($wanted -eq 'Discord') { $DiscordButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
        Invoke-ApplyButton
        $StatusText.Text = "AUTO - $wanted profil aktív"
        if ($script:trayIcon) { $script:trayIcon.ShowBalloonTip(1800, 'Profilváltás', "$wanted profil bekapcsolva", [Windows.Forms.ToolTipIcon]::Info) }
    }
})
$autoTimer.Start()

# Start with Windows using a normal, removable shortcut.
$startupDirectory = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupDirectory 'SoundLift.lnk'
$StartupCheck.IsChecked = Test-Path $startupShortcut
$StartupCheck.Add_Click({
    try {
        if ($StartupCheck.IsChecked) {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($startupShortcut)
            $shortcut.TargetPath = $script:appLaunchPath
            $shortcut.WorkingDirectory = $script:appDirectory
            if (Test-Path $appIconPath) { $shortcut.IconLocation = "$appIconPath,0" }
            $shortcut.Save()
        } elseif (Test-Path $startupShortcut) {
            [IO.File]::Delete($startupShortcut)
        }
    } catch {
        Write-SoundLiftLog -Category crash -EventName 'handled_runtime_error' -Severity error -Data @{ component='startup_shortcut' } -ErrorRecord $_
        [System.Windows.MessageBox]::Show("Indítási beállítási hiba:`n$($_.Exception.Message)", 'Hiba', 'OK', 'Error') | Out-Null
    }
})

# Remember the complete UI state between launches.
if (Test-Path $settingsPath) {
    try { Set-AppState (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json) } catch { }
}
if (Test-Path $onboardingMarkerPath) { $script:onboardingCompleted = $true }
$window.Add_Closing({
    try { (Get-AppState) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8 } catch { }
})

# Display the current Windows default output and refresh it automatically.
function Update-DeviceText { $DeviceText.Text = "Aktív hangkimenet: $([AudioAppNative]::GetDefaultOutputName())" }
$deviceTimer = New-Object Windows.Threading.DispatcherTimer
$deviceTimer.Interval = [TimeSpan]::FromSeconds(5)
$deviceTimer.Add_Tick({ Update-DeviceText })
$deviceTimer.Start(); Update-DeviceText

# Global Ctrl+Alt+1..6 hotkeys. These also work while a game is focused.
$script:hotKeyButtons = @($MusicButton, $GameButton, $CombatButton, $R6Button, $DiscordButton, $MovieButton)
$script:hotKeyHook = [Windows.Interop.HwndSourceHook]{
    param([IntPtr]$hookHwnd, [int]$message, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
    if ($message -eq 0x0312) {
        $index = $wParam.ToInt32() - 101
        if ($index -ge 0 -and $index -lt $script:hotKeyButtons.Count) {
            $script:hotKeyButtons[$index].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            Invoke-ApplyButton; $handled.Value = $true
        }
    }
    return [IntPtr]::Zero
}
$window.Add_SourceInitialized({
    $helper = New-Object Windows.Interop.WindowInteropHelper($window)
    $script:windowHandle = $helper.Handle
    $script:windowSource = [Windows.Interop.HwndSource]::FromHwnd($script:windowHandle)
    $script:windowSource.AddHook($script:hotKeyHook)
    for ($i = 0; $i -lt 6; $i++) { [void][AudioAppNative]::RegisterHotKey($script:windowHandle, 101 + $i, 0x0003, 0x31 + $i) }
})

# Tray icon: minimize or close to tray, double-click to restore.
$script:reallyExit = $false
$script:trayIcon = New-Object Windows.Forms.NotifyIcon
$script:trayIcon.Icon = if (Test-Path $appIconPath) { New-Object Drawing.Icon($appIconPath) } else { [Drawing.SystemIcons]::Application }
$script:trayIcon.Text = 'SoundLift V1.3.0'
$script:trayIcon.Visible = $true
$trayMenu = New-Object Windows.Forms.ContextMenuStrip
$showItem = $trayMenu.Items.Add('Megnyitás')
$showItem.Add_Click({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })
[void]$trayMenu.Items.Add('-')
$trayProfiles = @(
    @('Zene - Ctrl+Alt+1', $MusicButton), @('FiveM RP - Ctrl+Alt+2', $GameButton),
    @('FiveM harc - Ctrl+Alt+3', $CombatButton), @('R6 - Ctrl+Alt+4', $R6Button),
    @('Discord - Ctrl+Alt+5', $DiscordButton), @('Film - Ctrl+Alt+6', $MovieButton)
)
foreach ($entry in $trayProfiles) {
    $profileButton = $entry[1]
    $item = $trayMenu.Items.Add([string]$entry[0])
    $item.Add_Click({ $profileButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))); Invoke-ApplyButton }.GetNewClosure())
}
[void]$trayMenu.Items.Add('-')
$exitItem = $trayMenu.Items.Add('Kilépés')
$exitItem.Add_Click({ $script:reallyExit = $true; $window.Close() })
$script:trayIcon.ContextMenuStrip = $trayMenu
$script:trayIcon.Add_DoubleClick({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })
# A minimalizálás normál Windows-módon működik: az app látható marad a tálcán.
# Csak az X gomb rejti a tálcaikon mellé, ahonnan dupla kattintással visszahozható.
$window.Add_StateChanged({
    if ($window.WindowState -eq 'Minimized') {
        $window.ShowInTaskbar = $true
    }
})
$window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:reallyExit) { $eventArgs.Cancel = $true; $window.Hide() }
})
$window.Add_Closed({
    for ($i = 0; $i -lt 6; $i++) { [void][AudioAppNative]::UnregisterHotKey($script:windowHandle, 101 + $i) }
    if ($script:windowSource) { $script:windowSource.RemoveHook($script:hotKeyHook) }
    $script:trayIcon.Visible = $false; $script:trayIcon.Dispose()
})

Update-Labels
$script:startupUiHandled = $false
$window.Add_ContentRendered({
    if ($script:startupUiHandled) { return }
    $script:startupUiHandled = $true
    try {
        if (-not (Confirm-SoundLiftLicense)) {
            Write-SoundLiftLog -Category startup -EventName 'initialization_failed' -Severity warning -Data @{ stage='license_gate' }
            Send-SoundLiftPendingLogs
            $script:reallyExit = $true; $window.Close(); return
        }
        Update-DeveloperControls
        if (-not $script:onboardingCompleted) { Show-FirstRunWizard }
        Check-AppUpdate -Silent
        Complete-SoundLiftStartup
    } catch {
        Write-SoundLiftLog -Category startup -EventName 'initialization_failed' -Severity critical -ErrorRecord $_
        Write-SoundLiftLog -Category crash -EventName 'startup_crash' -Severity critical -ErrorRecord $_
        Send-SoundLiftPendingLogs
        [System.Windows.MessageBox]::Show("A SoundLift indítása közben hiba történt.`nA részletes napló itt található:`n$script:logRoot", 'SoundLift – indítási hiba', 'OK', 'Error') | Out-Null
        $script:reallyExit = $true; $window.Close()
    }
})
try {
    $window.ShowDialog() | Out-Null
} catch {
    $eventName = if ($script:startupCompleted) { 'unhandled_runtime_error' } else { 'startup_crash' }
    Write-SoundLiftLog -Category crash -EventName $eventName -Severity critical -ErrorRecord $_
    if (-not $script:startupCompleted) { Write-SoundLiftLog -Category startup -EventName 'initialization_failed' -Severity critical -ErrorRecord $_ }
    Send-SoundLiftPendingLogs
    [System.Windows.MessageBox]::Show("A SoundLift váratlan hibával leállt.`nA jelentés helyileg el lett mentve:`n$script:logRoot", 'SoundLift – hiba', 'OK', 'Error') | Out-Null
}
