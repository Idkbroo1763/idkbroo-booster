$ErrorActionPreference = 'Stop'
Write-Warning 'A külön Custom build megszűnt. Ugyanaz az univerzális SoundLift.exe kezeli az ingyenes, vásárlói és fejlesztői licenceket.'
& (Join-Path $PSScriptRoot 'build-windows.ps1')
