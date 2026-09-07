[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9_-]{2,63}$')][string]$ProductId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CustomerName,
    [Parameter(Mandatory)][ValidatePattern('^\d{15,25}$')][string]$DiscordId,
    [ValidateSet('customer','developer')][string]$Type = 'customer',
    [ValidateRange(1,3650)][int]$ExpiresInDays
)

$bytes = New-Object byte[] 16
$rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$key = 'SL-' + ([BitConverter]::ToString($bytes)).Replace('-', '')

$sha = [Security.Cryptography.SHA256]::Create()
try {
    $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-', '').ToLowerInvariant()
} finally { $sha.Dispose() }

function ConvertTo-SqlLiteral([string]$value) { return $value.Replace("'", "''") }
$safeProduct = ConvertTo-SqlLiteral $ProductId
$safeName = ConvertTo-SqlLiteral $CustomerName
$safeDiscord = ConvertTo-SqlLiteral $DiscordId
$expiry = if ($PSBoundParameters.ContainsKey('ExpiresInDays')) { "now() + interval '$ExpiresInDays days'" } else { 'null' }

$sql = @"
insert into public.licenses(product_id, key_hash, customer_name, customer_discord_id, license_type, expires_at)
select id, '$hash', '$safeName', '$safeDiscord', '$Type', $expiry
from public.license_products where product_id = '$safeProduct';
"@

Write-Host ''
Write-Host 'FONTOS: a nyers kulcsot csak a jogosult személy kapja meg.' -ForegroundColor Yellow
Write-Host "Licenctípus: $Type"
Write-Host "Nyers licenckulcs: $key" -ForegroundColor Green
Write-Host ''
Write-Host 'A Supabase SQL Editorba másolandó parancs:' -ForegroundColor Cyan
Write-Output $sql
