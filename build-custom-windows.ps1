$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$sourcePath = Join-Path $projectRoot 'TudomHogyMelegVagy.ps1'
$temporarySource = Join-Path $env:TEMP 'SoundLift-Custom.generated.ps1'
$outputDirectory = Join-Path $projectRoot 'dist-custom'
$outputExe = Join-Path $outputDirectory 'SoundLift Custom.exe'
$iconFile = Join-Path $projectRoot 'SoundLift.ico'

foreach ($name in @('SOUNDLIFT_LICENSE_API_URL','SOUNDLIFT_LICENSE_PRODUCT_ID','SOUNDLIFT_LICENSE_ANON_KEY')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Hiányzó környezeti változó: $name" }
}

function ConvertTo-SingleQuotedLiteral([string]$value) { return $value.Replace("'", "''") }

$source = [IO.File]::ReadAllText($sourcePath)
$source = $source.Replace("`$script:licenseMode = 'free'", "`$script:licenseMode = 'custom'")
$source = $source.Replace("`$script:licenseApiUrl = ''", "`$script:licenseApiUrl = '$(ConvertTo-SingleQuotedLiteral $env:SOUNDLIFT_LICENSE_API_URL)'")
$source = $source.Replace("`$script:licenseProductId = ''", "`$script:licenseProductId = '$(ConvertTo-SingleQuotedLiteral $env:SOUNDLIFT_LICENSE_PRODUCT_ID)'")
$source = $source.Replace("`$script:licenseAnonKey = ''", "`$script:licenseAnonKey = '$(ConvertTo-SingleQuotedLiteral $env:SOUNDLIFT_LICENSE_ANON_KEY)'")
if (-not [string]::IsNullOrWhiteSpace($env:SOUNDLIFT_LOG_API_URL)) {
    $source = $source.Replace("`$script:logApiUrl = ''", "`$script:logApiUrl = '$(ConvertTo-SingleQuotedLiteral $env:SOUNDLIFT_LOG_API_URL)'")
}
if (-not [string]::IsNullOrWhiteSpace($env:SOUNDLIFT_LOG_ANON_KEY)) {
    $source = $source.Replace("`$script:logAnonKey = ''", "`$script:logAnonKey = '$(ConvertTo-SingleQuotedLiteral $env:SOUNDLIFT_LOG_ANON_KEY)'")
}
[IO.File]::WriteAllText($temporarySource, $source, [Text.UTF8Encoding]::new($true))

try {
    if (-not (Test-Path $outputDirectory)) { [void][IO.Directory]::CreateDirectory($outputDirectory) }
    if (-not (Get-Module -ListAvailable -Name ps2exe | Where-Object Version -eq '1.0.18')) {
        Install-Module ps2exe -RequiredVersion 1.0.18 -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module ps2exe -RequiredVersion 1.0.18
    Invoke-PS2EXE $temporarySource $outputExe -IconFile $iconFile -NoConsole -RequireAdmin -STA -Verbose
    if (-not (Test-Path $outputExe)) { throw 'A vásárlói EXE fordítása nem sikerült.' }
    Copy-Item -LiteralPath $iconFile -Destination (Join-Path $outputDirectory 'SoundLift.ico') -Force
    Write-Host "Elkészült: $outputExe"
} finally {
    if (Test-Path $temporarySource) { [IO.File]::Delete($temporarySource) }
}
