param(
    [Parameter(Mandatory=$true)][ValidateSet('detach_device')][string]$Action,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9-]{36}$')][string]$LicenseId,
    [Parameter(Mandatory=$true)][ValidateLength(3,200)][string]$Reason,
    [string]$ApiUrl = $env:SOUNDLIFT_ADMIN_API_URL,
    [string]$AdminKey = $env:SOUNDLIFT_ADMIN_API_KEY
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ApiUrl)) { throw 'Hiányzik a SOUNDLIFT_ADMIN_API_URL környezeti változó.' }
if ([string]::IsNullOrWhiteSpace($AdminKey) -or $AdminKey.Length -lt 32) { throw 'Hiányzik vagy túl rövid a SOUNDLIFT_ADMIN_API_KEY.' }

$headers = @{ 'Content-Type'='application/json'; 'x-soundlift-admin-key'=$AdminKey }
$body = @{ action=$Action; license_id=$LicenseId.ToLowerInvariant(); reason=$Reason } | ConvertTo-Json -Compress
$result = Invoke-RestMethod -Uri $ApiUrl -Method Post -Headers $headers -Body $body -TimeoutSec 20
if (-not $result.ok) { throw "A művelet sikertelen: $($result.code)" }
Write-Host 'A gép leválasztása sikerült, és a művelet bekerült a licenc- és Discord-naplóba.' -ForegroundColor Green
