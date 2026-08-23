#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$schemaPath = Join-Path $root 'image-candidate.schema.json'
$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$item = Get-Item -LiteralPath $resolvedPath -Force
if ($item.PSIsContainer -or $item.Length -le 0 -or $item.Length -gt 16384) {
    throw "Image candidate must be one file between 1 and 16384 bytes."
}

$json = [IO.File]::ReadAllText(
    $resolvedPath,
    [Text.UTF8Encoding]::new($false, $true))
$valid = try {
    $json | Test-Json -SchemaFile $schemaPath -ErrorAction Stop
} catch {
    $false
}
if (-not $valid) {
    throw 'Image candidate does not satisfy image-candidate.schema.json.'
}

return $json | ConvertFrom-Json -Depth 12
