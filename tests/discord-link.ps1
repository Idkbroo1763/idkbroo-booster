$ErrorActionPreference='Stop'
$source = Get-Content "$PSScriptRoot/../SoundLift.ps1" -Raw
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-DiscordLinkOfflineGrace'},$true)
Invoke-Expression $function.Extent.Text
$script:installationId='test-install'; $script:discordLinkGraceHours=720
function Get-DiscordLinkCache { return $script:testCache }
foreach($case in @(
 @{age=1;id='test-install';expected=$true},
 @{age=719;id='test-install';expected=$true},
 @{age=721;id='test-install';expected=$false},
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
if (-not $buildSource.Contains('RELEASE_CONFIGURATION_EMBEDDING_VERIFIED')) { throw 'Missing release configuration verification' }
if (-not $source.Contains("`$script:appVersion = '1.3.19'")) { throw 'Application version was not updated to 1.3.19' }
foreach ($requiredFeature in @('Invoke-SoundLiftDownload','Repair-SoundLiftApoInclude','Show-ProblemReportWindow','Show-PostUpdateResult','Show-PrivacyWindow','Disable-SoundLiftEffects')) {
    if (-not $source.Contains("function $requiredFeature")) { throw "Missing required SoundLift feature: $requiredFeature" }
}
foreach ($requiredStartupFix in @('function Start-AsyncAppUpdateCheck', 'DownloadStringAsync', 'if (Test-DiscordLinkOfflineGrace) { return $true }')) {
    if (-not $source.Contains($requiredStartupFix)) { throw "Missing responsive startup behavior: $requiredStartupFix" }
}
foreach ($requiredControlFeature in @(
 'function Invoke-QuickMute', 'function Register-SoundLiftHotKeys', 'function Show-HotkeyEditor',
 'Gyorsprofilok', 'DoNotDisturbCheck', 'ToolTip=',
 '$script:hotKeyVirtualKeys', 'Select-Object -Unique'
)) {
    if (-not $source.Contains($requiredControlFeature)) { throw "Missing V1.3.15 quick-control feature: $requiredControlFeature" }
}
if ($source.Contains('Check-AppUpdate -Silent')) { throw 'Blocking startup update check is still enabled' }
$installerSource = Get-Content "$PSScriptRoot/../installer.iss" -Raw
$uninstallerSource = Get-Content "$PSScriptRoot/../Uninstall-SoundLift.ps1" -Raw
foreach ($requiredCleanupMarker in @('[UninstallRun]', 'Uninstall-SoundLift.ps1')) {
    if (-not $installerSource.Contains($requiredCleanupMarker)) { throw "Missing clean uninstall integration: $requiredCleanupMarker" }
}
foreach ($requiredCleanupBehavior in @('Remove-SoundLiftInclude', "Join-Path `$env:APPDATA 'SoundLift'", "Join-Path `$env:LOCALAPPDATA 'SoundLift'", "'SoundLift.lnk'")) {
    if (-not $uninstallerSource.Contains($requiredCleanupBehavior)) { throw "Missing clean uninstall behavior: $requiredCleanupBehavior" }
}
if (-not $source.Contains("`$script:discordLinkGraceHours = 720")) { throw 'Offline grace period is not 30 days' }
foreach ($requiredThemeMarker in @('#A855F7','#22D3EE','#FB923C','#F5C451','OLED fekete')) {
    if (-not $source.Contains($requiredThemeMarker)) { throw "Missing SoundLift theme marker: $requiredThemeMarker" }
}
foreach ($requiredUiFix in @(
    '<ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Hidden"',
    'function Test-SoundLiftProblemReportService',
    'function Test-SoundLiftProblemReportQueued',
    'Test-Path $script:logQueueFile',
    '<Style x:Key="VerticalEqSlider" TargetType="Slider">',
    '$ApplyButton.Foreground = $window.Resources[''AccentContrastBrush'']'
)) {
    if (-not $source.Contains($requiredUiFix)) { throw "Missing V1.3.6 UI fix: $requiredUiFix" }
}
foreach ($requiredReportFix in @(
    '$response.discord_forwarded -ge [int]$response.accepted',
    '<TextBlock Text="{TemplateBinding Content}" Foreground="{DynamicResource PrimaryTextBrush}"',
    '<TextBlock Text="{TemplateBinding Content}" Foreground="{DynamicResource AccentContrastBrush}"',
    '<Setter Property="Foreground" Value="{DynamicResource PrimaryTextBrush}"/>'
)) {
    if (-not $source.Contains($requiredReportFix)) { throw "Missing V1.3.9 report/theme fix: $requiredReportFix" }
}
$logEventsSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\licensing\log-events\index.ts'))
foreach ($requiredBackendFix in @('manual_diagnostic_report','user_description','diagnostic_report','submitted_by_user','discord_forwarded: discordForwarded')) {
    if (-not $logEventsSource.Contains($requiredBackendFix)) { throw "Missing manual report backend support: $requiredBackendFix" }
}
$backendLoggerSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\licensing\_shared\backend-logger.ts'))
foreach ($requiredEncodingFix in @('function repairMojibake', 'new TextDecoder("utf-8", { fatal: true })')) {
    if (-not $backendLoggerSource.Contains($requiredEncodingFix)) { throw "Missing Discord encoding repair: $requiredEncodingFix" }
}
foreach ($requiredUpdaterFragment in @(
 'https://api.github.com/repos/Idkbroo1763/SoundLift/releases/latest',
 "`$_.name -in @('SoundLift.Setup.exe', 'SoundLift Setup.exe')",
 "SoundLift[ .]Setup\.exe",
 "[Text.UTF8Encoding]::new(`$false).GetBytes(`$body)",
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
 $script:appVersion='1.3.19'
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
