$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$sourceScript = Join-Path $projectRoot 'TudomHogyMelegVagy.ps1'
$iconFile = Join-Path $projectRoot 'SoundLift.ico'
$outputDirectory = Join-Path $projectRoot 'dist'
$outputExe = Join-Path $outputDirectory 'SoundLift.exe'
$temporarySource = Join-Path $env:TEMP 'SoundLift-Public.generated.ps1'

if (-not (Test-Path $outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory | Out-Null }

if (-not (Get-Module -ListAvailable -Name ps2exe | Where-Object Version -eq '1.0.18')) {
    Install-Module ps2exe -RequiredVersion 1.0.18 -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -RequiredVersion 1.0.18

function ConvertTo-SingleQuotedLiteral([string]$value) { return $value.Replace("'", "''") }
$source = [IO.File]::ReadAllText($sourceScript)
if (-not [string]::IsNullOrWhiteSpace($env:SOUNDLIFT_LOG_API_URL)) {
    $source = $source.Replace("`$script:logApiUrl = ''", "`$script:logApiUrl = '$(ConvertTo-SingleQuotedLiteral $env:SOUNDLIFT_LOG_API_URL)'")
}
if (-not [string]::IsNullOrWhiteSpace($env:SOUNDLIFT_LOG_ANON_KEY)) {
    $source = $source.Replace("`$script:logAnonKey = ''", "`$script:logAnonKey = '$(ConvertTo-SingleQuotedLiteral $env:SOUNDLIFT_LOG_ANON_KEY)'")
}
[IO.File]::WriteAllText($temporarySource, $source, [Text.UTF8Encoding]::new($true))

# A minimális, dokumentált paraméterkészletet használjuk. Ez elkerüli, hogy a
# GitHub runner PowerShell-verziója a metaadat-kapcsolókat LCID-ként értelmezze.
try {
    Invoke-PS2EXE $temporarySource $outputExe -IconFile $iconFile -NoConsole -RequireAdmin -STA -Verbose
    if (-not (Test-Path $outputExe)) { throw 'Az EXE fordítása nem sikerült.' }
    Copy-Item -LiteralPath $iconFile -Destination (Join-Path $outputDirectory 'SoundLift.ico') -Force
    Write-Host "Elkészült: $outputExe"
} finally {
    if (Test-Path $temporarySource) { [IO.File]::Delete($temporarySource) }
}
