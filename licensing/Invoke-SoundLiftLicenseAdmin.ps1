param(
    [Parameter(Mandatory=$true)][ValidateSet('detach_device','upsert_feature','set_license_feature','set_owner')][string]$Action,
    [ValidatePattern('^[a-fA-F0-9-]{36}$')][string]$LicenseId,
    [ValidateLength(3,200)][string]$Reason,
    [ValidatePattern('^[a-z][a-z0-9_]{2,63}$')][string]$FeatureKey,
    [ValidateLength(1,80)][string]$DisplayName,
    [ValidateLength(0,500)][string]$Description,
    [bool]$Enabled = $true,
    [hashtable]$Config = @{},
    [string]$ApiUrl = $env:SOUNDLIFT_ADMIN_API_URL,
    [string]$AdminKey = $env:SOUNDLIFT_ADMIN_API_KEY
)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ApiUrl)){throw 'Hiányzik a SOUNDLIFT_ADMIN_API_URL környezeti változó.'}
if([string]::IsNullOrWhiteSpace($AdminKey)-or $AdminKey.Length-lt 32){throw 'Hiányzik vagy túl rövid a SOUNDLIFT_ADMIN_API_KEY.'}
$body=@{action=$Action;enabled=$Enabled}
switch($Action){
    'detach_device' { if(-not $LicenseId-or-not $Reason){throw 'A LicenseId és Reason kötelező.'};$body.license_id=$LicenseId.ToLowerInvariant();$body.reason=$Reason }
    'upsert_feature' { if(-not $FeatureKey-or-not $DisplayName){throw 'A FeatureKey és DisplayName kötelező.'};$body.feature_key=$FeatureKey;$body.display_name=$DisplayName;$body.description=$Description }
    'set_license_feature' { if(-not $LicenseId-or-not $FeatureKey){throw 'A LicenseId és FeatureKey kötelező.'};$body.license_id=$LicenseId.ToLowerInvariant();$body.feature_key=$FeatureKey;$body.config=$Config }
    'set_owner' { if(-not $LicenseId){throw 'A LicenseId kötelező.'};$body.license_id=$LicenseId.ToLowerInvariant() }
}
$headers=@{'Content-Type'='application/json; charset=utf-8';'x-soundlift-admin-key'=$AdminKey}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($body|ConvertTo-Json -Compress -Depth 8))
$result=Invoke-RestMethod -Uri $ApiUrl -Method Post -Headers $headers -Body $bytes -TimeoutSec 20
if(-not $result.ok){throw "A művelet sikertelen: $($result.code)"}
Write-Host "Sikeres SoundLift adminművelet: $Action" -ForegroundColor Green
