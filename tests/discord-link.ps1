$ErrorActionPreference='Stop'
$source = Get-Content "$PSScriptRoot/../TudomHogyMelegVagy.ps1" -Raw
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
foreach ($requiredUpdaterFragment in @(
 'https://api.github.com/repos/Idkbroo1763/idkbroo-booster/releases/latest',
 "Get-FileHash -LiteralPath `$installerPath -Algorithm SHA256",
 "`$assetUri.Scheme -ne 'https' -or `$assetUri.Host -ne 'github.com'",
 "Start-Process -FilePath `$installerPath"
)) {
 if (-not $source.Contains($requiredUpdaterFragment)) { throw "Missing secure updater behavior: $requiredUpdaterFragment" }
}
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
