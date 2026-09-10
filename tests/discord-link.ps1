$ErrorActionPreference='Stop'
$source = Get-Content "$PSScriptRoot/../SoundLift.ps1" -Raw
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-DiscordLinkOfflineGrace'},$true)
Invoke-Expression $function.Extent.Text
$script:installationId='test-install'; $script:discordLinkGraceHours=72
function Get-DiscordLinkCache { return $script:testCache }
foreach($case in @(
 @{age=1;id='test-install';expected=$true},
 @{age=73;id='test-install';expected=$false},
 @{age=-1;id='test-install';expected=$false},
 @{age=1;id='other-install';expected=$false}
)) {
 $script:testCache=@{linked=$true;installationId=$case.id;lastVerifiedUtc=[DateTime]::UtcNow.AddHours(-$case.age).ToString('o')}
 if ((Test-DiscordLinkOfflineGrace) -ne $case.expected) { throw "Offline grace case failed: $($case|Out-String)" }
}
$gate=$source.IndexOf('if (-not (Confirm-DiscordAccountLink))')
if($gate -lt 0 -or $gate -gt $source.IndexOf('$xaml =')) { throw 'Discord gate must precede UI creation' }
$buildSource = Get-Content "$PSScriptRoot/../build-windows.ps1" -Raw
foreach ($requiredUniversalBuildFragment in @(
 "licenseMode = 'universal'",
 "licenseProductId = 'soundlift-custom'",
 '/verify-license',
 'SOUNDLIFT_LOG_ANON_KEY'
)) {
 if (-not $buildSource.Contains($requiredUniversalBuildFragment)) { throw "Missing universal build behavior: $requiredUniversalBuildFragment" }
}
if (-not $source.Contains("`$script:appVersion = '1.3.1'")) { throw 'Application version was not updated to 1.3.1' }
foreach ($requiredUpdaterFragment in @(
 'https://api.github.com/repos/Idkbroo1763/SoundLift/releases/latest',
 "Get-FileHash -LiteralPath `$installerPath -Algorithm SHA256",
 "`$assetUri.Scheme -ne 'https' -or `$assetUri.Host -ne 'github.com'",
 "Start-Process -FilePath `$installerPath",
 "`$statusText.Text = 'Let",
 "`$statusText.Text = 'Telep",
 "`$installButton.Content = '",
 'CopySupportIdButton',
 'LicenseStatusText',
 'LicenseButton',
 "`$script:licenseMode -notin @('universal','custom')",
 'RollbackButton',
 "`$script:currentLicenseType -ne 'developer'",
 "`$RollbackButton.Visibility = 'Collapsed'"
)) {
 if (-not $source.Contains($requiredUpdaterFragment)) { throw "Missing secure updater behavior: $requiredUpdaterFragment" }
}
foreach ($name in @('Get-SoundLiftRollbackState', 'Save-SoundLiftRollbackCopy')) {
 $definition = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
 Invoke-Expression $definition.Extent.Text
}
$script:appDirectory = Join-Path ([IO.Path]::GetTempPath()) ('soundlift-rollback-' + [Guid]::NewGuid())
[IO.Directory]::CreateDirectory($script:appDirectory) | Out-Null
$script:appLaunchPath = Join-Path $script:appDirectory 'SoundLift.exe'; $script:isPackagedExe=$true; $script:appVersion='1.2.1'; $script:currentLicenseType='free'
try {
 [IO.File]::WriteAllBytes($script:appLaunchPath, [byte[]](1,2,3,4,5))
 Save-SoundLiftRollbackCopy
 if (Test-Path (Join-Path $script:appDirectory 'rollback\SoundLift.previous.exe')) { throw 'Free user received a rollback executable' }
 $script:currentLicenseType='developer'
 Save-SoundLiftRollbackCopy
 $script:appVersion='1.3.1'
 if (-not (Get-SoundLiftRollbackState)) { throw 'Valid rollback copy was rejected' }
 [IO.File]::AppendAllText((Join-Path $script:appDirectory 'rollback\SoundLift.previous.exe'), 'tampered')
 if (Get-SoundLiftRollbackState) { throw 'Tampered rollback copy was accepted' }
 Write-Host 'PASS: rollback backup is created and hash tampering is rejected'
} finally { Remove-Item -LiteralPath $script:appDirectory -Recurse -Force }
Write-Host 'PASS: PowerShell syntax, expiry, future-clock rejection, installation binding, early gate'

# Exercise the application's assembly loading and real DPAPI persistence in a
# fresh Windows PowerShell process, before any other code can load System.Security.
Invoke-Expression $source.Substring(0, $source.IndexOf('# PS2EXE'))
foreach ($name in @('Protect-LicenseState', 'Unprotect-LicenseState', 'Get-InstallationProof')) {
 $definition = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
 Invoke-Expression $definition.Extent.Text
}
$script:logRoot = Join-Path ([IO.Path]::GetTempPath()) ('soundlift-dpapi-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $script:logRoot | Out-Null
try {
 $proof = Get-InstallationProof
 if ($proof -notmatch '^[a-f0-9]{64}$') { throw 'Invalid generated proof' }
 if ((Get-InstallationProof) -cne $proof) { throw 'Proof did not survive disk round trip' }
 $stored = [IO.File]::ReadAllText((Join-Path $script:logRoot 'installation-proof.dat'))
 if ($stored.Contains($proof)) { throw 'Proof stored without encryption' }
 $state = Unprotect-LicenseState (Protect-LicenseState @{linked=$true;supportId='SL-TEST'})
 if ($state.linked -ne $true -or $state.supportId -ne 'SL-TEST') { throw 'Link cache round trip failed' }
 Write-Host 'PASS: explicit assembly loading, real DPAPI encryption, persistent proof and cache'
} finally { Remove-Item -LiteralPath $script:logRoot -Recurse -Force }
