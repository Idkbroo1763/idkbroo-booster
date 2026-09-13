[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9_-]{2,63}$')][string]$ProductId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CustomerName,
    [Parameter(Mandatory)][ValidatePattern('^\d{15,25}$')][string]$DiscordId,
    [ValidateSet('customer','developer')][string]$Type = 'customer',
    [string[]]$Features = @(),
    [switch]$Owner,
    [ValidateRange(1,3650)][int]$ExpiresInDays
)

$bytes = New-Object byte[] 16
if($Owner -and $Type -ne 'developer'){throw 'Owner jogosultság csak developer típusú saját licenchez adható.'}
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

$featureValues=@($Features|Where-Object{$_ -match '^[a-z][a-z0-9_]{2,63}$'}|Select-Object -Unique)
if($featureValues.Count-ne $Features.Count){throw 'Minden feature kulcs formátuma legyen például: extra_bass_pro'}
$featureSql=if($featureValues.Count){
    $quoted=($featureValues|ForEach-Object{"'$(ConvertTo-SqlLiteral $_)'"})-join ','
@"
insert into public.soundlift_license_features(license_id,feature_id)
select new_license.id,f.id from new_license cross join public.soundlift_features f where f.feature_key in ($quoted)
returning license_id;
"@
}else{'select id as license_id from new_license;'}
$ownerSql=if($Owner){'true'}else{'false'}
$sql=@"
with new_license as (
  insert into public.licenses(product_id,key_hash,customer_name,customer_discord_id,license_type,is_owner,expires_at)
  select id,'$hash','$safeName','$safeDiscord','$Type',$ownerSql,$expiry
  from public.license_products where product_id='$safeProduct'
  returning id
)
$featureSql
"@

Write-Host ''
Write-Host 'FONTOS: a nyers kulcsot csak a jogosult személy kapja meg.' -ForegroundColor Yellow
Write-Host "Licenctípus: $Type"
Write-Host "Owner jogosultság: $([bool]$Owner)"
Write-Host "Funkciók: $($featureValues -join ', ')"
Write-Host "Nyers licenckulcs: $key" -ForegroundColor Green
Write-Host ''
Write-Host 'A Supabase SQL Editorba másolandó parancs:' -ForegroundColor Cyan
Write-Output $sql
