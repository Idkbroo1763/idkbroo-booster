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
Write-Host 'PASS: PowerShell syntax, expiry, future-clock rejection, installation binding, early gate'
