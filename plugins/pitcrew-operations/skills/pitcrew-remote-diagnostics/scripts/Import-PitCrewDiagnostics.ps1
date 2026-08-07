#Requires -Version 7.0
<#
.SYNOPSIS
Verifies and imports a returned PitCrew diagnostics result.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InputPath,

    [ValidatePattern('^[a-f0-9]{16,64}$')]
    [string]$ExpectedPackageId,

    [ValidatePattern('^[a-f0-9]{64}$')]
    [string]$ExpectedCollectorSha256,

    [string]$PreflightPath,

    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RemoteDiagnostics.Core.ps1')

$resolvedInput = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
$temporaryDirectory = $null
$resultDirectory = if ((Get-Item -LiteralPath $resolvedInput.Path).PSIsContainer) {
    $resolvedInput.Path
} else {
    if ([IO.Path]::GetExtension($resolvedInput.Path) -ne '.zip') {
        throw 'InputPath must be a result directory or ZIP archive.'
    }
    $null
}

try {
    if ($null -eq $resultDirectory) {
    $temporaryDirectory = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "pitcrew-diagnostics-import-$([Guid]::NewGuid().ToString('N'))"
        Expand-PitCrewRemoteDiagnosticsZip `
            -LiteralPath $resolvedInput.Path `
            -DestinationDirectory $temporaryDirectory
        $resultDirectory = $temporaryDirectory
    }
    $manifestPath = Join-Path $resultDirectory 'result-manifest.json'
    $jsonPath = Join-Path $resultDirectory 'pitcrew-diagnostics.json'
    $markdownPath = Join-Path $resultDirectory 'pitcrew-diagnostics.md'
    foreach ($requiredPath in @(
            $manifestPath,
            $jsonPath,
            $markdownPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw 'The returned diagnostics result is incomplete.'
        }
        $item = Get-Item -LiteralPath $requiredPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Length -le 0 -or
            $item.Length -gt 4194304) {
            throw 'A returned diagnostics file is linked, empty, or oversized.'
        }
    }
    $manifest = Get-Content `
        -LiteralPath $manifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 20 -ErrorAction Stop
    if ($manifest.schemaVersion -ne 1 -or
        $manifest.packageId -notmatch '^[a-f0-9]{16,64}$') {
        throw 'The returned result manifest is invalid.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPackageId) -and
        $manifest.packageId -ne $ExpectedPackageId) {
        throw 'The returned result package ID does not match the requested package.'
    }
    $fileMap = @{}
    foreach ($file in @($manifest.files)) {
        if ($file.name -notin @(
                'pitcrew-diagnostics.json',
                'pitcrew-diagnostics.md') -or
            $file.sha256 -notmatch '^[a-f0-9]{64}$' -or
            $fileMap.ContainsKey([string]$file.name)) {
            throw 'The returned result manifest contains an invalid file entry.'
        }
        $fileMap[[string]$file.name] = [string]$file.sha256
    }
    if ($fileMap.Count -ne 2 -or
        (Get-PitCrewRemoteDiagnosticsSha256 $jsonPath) -ne
            $fileMap['pitcrew-diagnostics.json'] -or
        (Get-PitCrewRemoteDiagnosticsSha256 $markdownPath) -ne
            $fileMap['pitcrew-diagnostics.md']) {
        throw 'The returned diagnostics file checksum verification failed.'
    }
    $report = Get-Content `
        -LiteralPath $jsonPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 100 -ErrorAction Stop
    if ($report.schemaVersion -ne 1 -or
        $report.packageId -ne $manifest.packageId -or
        $report.pitcrewRoot -ne '<pitcrew-root>') {
        throw 'The returned diagnostics report does not satisfy the versioned redaction contract.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCollectorSha256) -and
        $report.collectorSha256 -ne $ExpectedCollectorSha256) {
        throw 'The returned diagnostics report used a different collector.'
    }
    if (Test-PitCrewRemoteDiagnosticsForbiddenProperty $report) {
        throw 'The returned diagnostics report contains a forbidden property.'
    }
    $preflight = $null
    if (-not [string]::IsNullOrWhiteSpace($PreflightPath)) {
        $resolvedPreflight = Resolve-Path `
            -LiteralPath $PreflightPath `
            -ErrorAction Stop
        $preflightItem = Get-Item -LiteralPath $resolvedPreflight.Path -Force
        if (($preflightItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $preflightItem.Length -le 0 -or
            $preflightItem.Length -gt 1048576) {
            throw 'The preflight artifact is linked, empty, or oversized.'
        }
        $preflight = Get-Content `
            -LiteralPath $resolvedPreflight.Path `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json -Depth 50 -ErrorAction Stop
        if ($preflight.schemaVersion -ne 1 -or
            $null -eq $preflight.capturedAt -or
            (Test-PitCrewRemoteDiagnosticsForbiddenProperty $preflight)) {
            throw 'The preflight artifact does not satisfy the read-only evidence contract.'
        }
    }
    $diagnosis = New-PitCrewRemoteDiagnosticsDiagnosis `
        -Report $report `
        -Preflight $preflight
    $diagnosisMarkdown = New-PitCrewRemoteDiagnosticsDiagnosisMarkdown `
        -Diagnosis $diagnosis
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $baseDirectory = if (
            (Get-Item -LiteralPath $resolvedInput.Path).PSIsContainer
        ) {
            Split-Path -Parent $resolvedInput.Path
        } else {
            Split-Path -Parent $resolvedInput.Path
        }
        $OutputDirectory = Join-Path `
            $baseDirectory `
            "pitcrew-diagnosis-$($manifest.packageId)"
    }
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $diagnosisJsonPath = Join-Path `
        $OutputDirectory `
        'pitcrew-diagnostics-diagnosis.json'
    $diagnosisMarkdownPath = Join-Path `
        $OutputDirectory `
        'pitcrew-diagnostics-diagnosis.md'
    Write-PitCrewRemoteDiagnosticsUtf8 `
        -LiteralPath $diagnosisJsonPath `
        -Content ($diagnosis | ConvertTo-Json -Depth 100)
    Write-PitCrewRemoteDiagnosticsUtf8 `
        -LiteralPath $diagnosisMarkdownPath `
        -Content $diagnosisMarkdown
    [PSCustomObject][ordered]@{
        packageId = $manifest.packageId
        diagnosisJsonPath = (
            Resolve-Path -LiteralPath $diagnosisJsonPath).Path
        diagnosisMarkdownPath = (
            Resolve-Path -LiteralPath $diagnosisMarkdownPath).Path
    }
} finally {
    if ($null -ne $temporaryDirectory -and
        (Test-Path -LiteralPath $temporaryDirectory -PathType Container)) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
