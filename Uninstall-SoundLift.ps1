$ErrorActionPreference = 'SilentlyContinue'

function Remove-SoundLiftInclude([string]$configPath) {
    if (-not (Test-Path -LiteralPath $configPath)) { return }
    $text = [IO.File]::ReadAllText($configPath)
    $text = [Regex]::Replace($text, '(?im)^\s*#\s*SoundLift\s*\r?\n\s*Include:[^\r\n]+\r?\n?', '')
    $text = [Regex]::Replace($text, '(?im)^\s*Include:\s*SoundLift\.txt\s*\r?\n?', '')
    [IO.File]::WriteAllText($configPath, ($text.TrimEnd() + "`r`n"), [Text.UTF8Encoding]::new($false))
}

$apoDirectories = @(
    (Join-Path $env:ProgramFiles 'EqualizerAPO\config'),
    $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'EqualizerAPO\config' })
) | Where-Object { $_ }

foreach ($apoDirectory in $apoDirectories) {
    Remove-SoundLiftInclude (Join-Path $apoDirectory 'config.txt')
    foreach ($fileName in @('SoundLift.txt', 'SoundLift.txt.undo', 'config.before-SoundLift-repair.bak')) {
        $path = Join-Path $apoDirectory $fileName
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'SoundLift.lnk'
if (Test-Path -LiteralPath $startupShortcut) { Remove-Item -LiteralPath $startupShortcut -Force }

foreach ($localData in @((Join-Path $env:APPDATA 'SoundLift'), (Join-Path $env:LOCALAPPDATA 'SoundLift'))) {
    if (Test-Path -LiteralPath $localData) { Remove-Item -LiteralPath $localData -Recurse -Force }
}
