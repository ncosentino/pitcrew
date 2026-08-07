#Requires -Version 7.0
<#
.SYNOPSIS
Stages PitCrew release assets that are published outside container workflows.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$collectorSource = Join-Path `
    $root `
    'plugins' `
    'pitcrew-operations' `
    'skills' `
    'pitcrew-remote-diagnostics' `
    'scripts' `
    'Collect-PitCrewDiagnostics.ps1'
if (-not (Test-Path -LiteralPath $collectorSource -PathType Leaf)) {
    throw 'The portable diagnostics collector is missing.'
}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path
$collectorAsset = Join-Path `
    $resolvedOutput `
    'Collect-PitCrewDiagnostics.ps1'
$checksumAsset = "$collectorAsset.sha256"
[IO.File]::Copy(
    $collectorSource,
    $collectorAsset,
    $true)
$sha256 = (
    Get-FileHash `
        -LiteralPath $collectorAsset `
        -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(
    $checksumAsset,
    "$sha256  Collect-PitCrewDiagnostics.ps1`n",
    [Text.UTF8Encoding]::new($false))

[PSCustomObject][ordered]@{
    collectorPath = (Resolve-Path -LiteralPath $collectorAsset).Path
    checksumPath = (Resolve-Path -LiteralPath $checksumAsset).Path
    sha256 = $sha256
}
