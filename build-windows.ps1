$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$sourceScript = Join-Path $projectRoot 'TudomHogyMelegVagy.ps1'
$iconFile = Join-Path $projectRoot 'idkbroo Booster.ico'
$outputDirectory = Join-Path $projectRoot 'dist'
$outputExe = Join-Path $outputDirectory 'idkbroo Booster.exe'

if (-not (Test-Path $outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory | Out-Null }

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe

# A minimális, dokumentált paraméterkészletet használjuk. Ez elkerüli, hogy a
# GitHub runner PowerShell-verziója a metaadat-kapcsolókat LCID-ként értelmezze.
Invoke-PS2EXE $sourceScript $outputExe -IconFile $iconFile -NoConsole -RequireAdmin -STA -Verbose

if (-not (Test-Path $outputExe)) { throw 'Az EXE fordítása nem sikerült.' }
Copy-Item -LiteralPath $iconFile -Destination (Join-Path $outputDirectory 'idkbroo Booster.ico') -Force
Write-Host "Elkészült: $outputExe"
