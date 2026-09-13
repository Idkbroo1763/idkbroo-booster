$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot '..'
$client=[IO.File]::ReadAllText((Join-Path $root 'SoundLift.ps1'))
$verify=[IO.File]::ReadAllText((Join-Path $root 'licensing\verify-license\index.ts'))
$schema=[IO.File]::ReadAllText((Join-Path $root 'licensing\supabase-schema.sql'))
$admin=[IO.File]::ReadAllText((Join-Path $root 'licensing\admin-license-action\index.ts'))
foreach($marker in @('extra_bass_pro','voice_boost','custom_preset_x','soundlift_license_features','get_soundlift_license_features','is_owner')){
 if(-not $schema.Contains($marker)){throw "Missing schema entitlement marker: $marker"}
}
foreach($marker in @('p_discord_id: linkedUser.discord_user_id','DISCORD_ACCOUNT_MISMATCH','list_owner_targets','simulation_license_id','OWNER_REQUIRED','get_soundlift_license_features')){
 if(-not $verify.Contains($marker)){throw "Missing secure entitlement backend marker: $marker"}
}
foreach($marker in @('set_license_feature','upsert_feature','set_owner')){if(-not $admin.Contains($marker)){throw "Missing admin action: $marker"}}
foreach($marker in @('Set-LicenseFeatures','Show-OwnerLicenseSimulator','OwnerModeButton','ExtraBassProButton','VoiceBoostButton','CustomPresetXButton')){
 if(-not $client.Contains($marker)){throw "Missing client entitlement feature: $marker"}
}
foreach($marker in @('$activate.IsDefault=$true','$dialog.DialogResult=$true','LICENSE_DIALOG_INVALID_KEY')){
 if(-not $client.Contains($marker)){throw "Missing reliable license dialog behavior: $marker"}
}
if(-not $client.Contains("[Regex]::Match(`$candidate,'(?i)SL-[A-F0-9]{32}')")){throw 'License key extraction is missing'}
if($client.Contains('$candidate=[string]$input.Text')){throw 'License dialog still uses the reserved PowerShell input variable'}
if(-not $client.Contains('$candidate=[string]$licenseInput.Text')){throw 'License dialog is not reading its textbox'}
if($client.Contains("`$script:isOwner = `$true")){throw 'Owner permission is hard-coded in the client'}
Write-Host 'PASS: backend-gated flags, Discord ownership, Owner simulation and client visibility wiring'
