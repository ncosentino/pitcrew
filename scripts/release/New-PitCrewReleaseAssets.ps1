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
$sources = [ordered]@{
    'Collect-PitCrewDiagnostics.ps1' = Join-Path `
        $root `
        'plugins' `
        'pitcrew-operations' `
        'skills' `
        'pitcrew-remote-diagnostics' `
        'scripts' `
        'Collect-PitCrewDiagnostics.ps1'
    'support-broker-access.json' = Join-Path `
        $root `
        'support-broker-access.json'
    'support-broker-access.schema.json' = Join-Path `
        $root `
        'support-broker-access.schema.json'
}
foreach ($source in $sources.Values) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required release asset source is missing: '$source'."
    }
}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path
$assets = @(
    foreach ($name in $sources.Keys) {
        $assetPath = Join-Path $resolvedOutput $name
        $checksumPath = "$assetPath.sha256"
        [IO.File]::Copy(
            $sources[$name],
            $assetPath,
            $true)
        $assetSha256 = (
            Get-FileHash `
                -LiteralPath $assetPath `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText(
            $checksumPath,
            "$assetSha256  $name`n",
            [Text.UTF8Encoding]::new($false))
        [PSCustomObject][ordered]@{
            name = $name
            path = (Resolve-Path -LiteralPath $assetPath).Path
            checksumPath = (Resolve-Path -LiteralPath $checksumPath).Path
            sha256 = $assetSha256
        }
    }
)
$collector = @(
    $assets |
        Where-Object name -eq 'Collect-PitCrewDiagnostics.ps1')

[PSCustomObject][ordered]@{
    collectorPath = $collector[0].path
    checksumPath = $collector[0].checksumPath
    sha256 = $collector[0].sha256
    assets = $assets
}
