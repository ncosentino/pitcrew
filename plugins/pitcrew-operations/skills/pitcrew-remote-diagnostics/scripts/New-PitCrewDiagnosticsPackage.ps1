#Requires -Version 7.0
<#
.SYNOPSIS
Creates a deterministic PitCrew diagnostics handoff bundle.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TargetPitCrewRoot,

    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
    [string]$Profile,

    [ValidateSet(
        'ConnectorOffline',
        'CapacityMismatch',
        'JobNotAssigned',
        'HostPressure',
        'Full')]
    [string]$DiagnosticMode = 'Full',

    [ValidateCount(0, 4)]
    [Uri[]]$ApprovedUrl = @(),

    [ValidateRange(1, 900)]
    [int]$ProbeTimeoutSeconds = 300,

    [Parameter(Mandatory)]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RemoteDiagnostics.Core.ps1')

Assert-PitCrewRemoteRootLiteral $TargetPitCrewRoot
$collectorPath = Join-Path $PSScriptRoot 'Collect-PitCrewDiagnostics.ps1'
if (-not (Test-Path -LiteralPath $collectorPath -PathType Leaf)) {
    throw 'The portable collector is missing from the installed skill.'
}
$safeUrls = @(
    foreach ($url in $ApprovedUrl) {
        Assert-PitCrewRemoteDiagnosticUrl $url
        $url.AbsoluteUri
    })
$safeUrls = @($safeUrls | Sort-Object -Unique)
$collectorSha256 = Get-PitCrewRemoteDiagnosticsSha256 $collectorPath
$packageId = New-PitCrewRemoteDiagnosticsPackageId `
    -CollectorSha256 $collectorSha256 `
    -TargetPitCrewRoot $TargetPitCrewRoot `
    -DiagnosticMode $DiagnosticMode `
    -Profile $Profile `
    -ApprovedUrls $safeUrls `
    -ProbeTimeoutSeconds $ProbeTimeoutSeconds
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path
$stageDirectory = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "pitcrew-diagnostics-package-$packageId-$([Guid]::NewGuid().ToString('N'))"
$zipPath = Join-Path `
    $resolvedOutput `
    "pitcrew-diagnostics-$packageId.zip"
$checksumPath = "$zipPath.sha256"
$null = New-Item -ItemType Directory -Path $stageDirectory
try {
    Copy-Item `
        -LiteralPath $collectorPath `
        -Destination (Join-Path $stageDirectory 'Collect-PitCrewDiagnostics.ps1')
    Write-PitCrewRemoteDiagnosticsUtf8 `
        -LiteralPath (Join-Path $stageDirectory 'collector.sha256') `
        -Content "$collectorSha256  Collect-PitCrewDiagnostics.ps1`n"
    $manifest = [PSCustomObject][ordered]@{
        schemaVersion = 1
        packageId = $packageId
        collectorVersion = '1.0.0'
        collectorSha256 = $collectorSha256
        diagnosticMode = $DiagnosticMode
        profile = if ([string]::IsNullOrWhiteSpace($Profile)) {
            $null
        } else {
            $Profile
        }
        approvedUrls = $safeUrls
        probeTimeoutSeconds = $ProbeTimeoutSeconds
        targetPitCrewRoot = $TargetPitCrewRoot
        expectedResultFiles = @(
            'pitcrew-diagnostics.json',
            'pitcrew-diagnostics.md',
            'result-manifest.json')
    }
    Write-PitCrewRemoteDiagnosticsUtf8 `
        -LiteralPath (Join-Path $stageDirectory 'manifest.json') `
        -Content ($manifest | ConvertTo-Json -Depth 20)

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add("    -PitCrewRoot $(ConvertTo-PitCrewPowerShellLiteral $TargetPitCrewRoot) ``")
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $arguments.Add("    -Profile $(ConvertTo-PitCrewPowerShellLiteral $Profile) ``")
    }
    $arguments.Add("    -DiagnosticMode $(ConvertTo-PitCrewPowerShellLiteral $DiagnosticMode) ``")
    $arguments.Add("    -ProbeTimeoutSeconds $ProbeTimeoutSeconds ``")
    $arguments.Add("    -PackageId $(ConvertTo-PitCrewPowerShellLiteral $packageId) ``")
    if ($safeUrls.Count -gt 0) {
        $urlLiterals = @(
            $safeUrls |
                ForEach-Object {
                    ConvertTo-PitCrewPowerShellLiteral $_
                })
        $arguments.Add("    -ApprovedUrl @($($urlLiterals -join ', ')) ``")
    }
    $arguments.Add("    -OutputDirectory (Join-Path `$PSScriptRoot 'results')")
    $invokeContent = @"
#Requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$collector = Join-Path `$PSScriptRoot 'Collect-PitCrewDiagnostics.ps1'
`$expected = (Get-Content -LiteralPath (Join-Path `$PSScriptRoot 'collector.sha256') -Raw -Encoding UTF8).Split(' ', [StringSplitOptions]::RemoveEmptyEntries)[0]
`$actual = (Get-FileHash -LiteralPath `$collector -Algorithm SHA256).Hash.ToLowerInvariant()
if (`$actual -ne `$expected) {
    throw 'Collector checksum verification failed.'
}
& `$collector ``
$($arguments -join "`n")
"@
    Write-PitCrewRemoteDiagnosticsUtf8 `
        -LiteralPath (Join-Path $stageDirectory 'Invoke-Collection.ps1') `
        -Content $invokeContent

    $prompt = @"
# PitCrew diagnostics handoff

Run only the included, checksum-pinned collector. Do not inspect environment
files, connector identity, JIT material, registration payloads, job output, or
unrelated paths. Do not restart or stop Docker, services, managers, workers, or
the host. Do not prune or clean up anything except the collector's exact
run-scoped temporary diagnostic container if the script created one.

1. Extract this ZIP into a new empty directory on the PitCrew node.
2. From that directory run:

```powershell
pwsh ./Invoke-Collection.ps1
```

3. Confirm the command reports three files below `results`.
4. Create a ZIP containing only:
   - `pitcrew-diagnostics.json`
   - `pitcrew-diagnostics.md`
   - `result-manifest.json`
5. Return that ZIP without adding logs, screenshots, environment files, or any
   other host content.

Package ID: $packageId
Diagnostic mode: $DiagnosticMode
"@
    Write-PitCrewRemoteDiagnosticsUtf8 `
        -LiteralPath (Join-Path $stageDirectory 'AGENT-PROMPT.md') `
        -Content $prompt
    New-PitCrewDeterministicZip `
        -SourceDirectory $stageDirectory `
        -DestinationPath $zipPath
    $zipSha256 = Get-PitCrewRemoteDiagnosticsSha256 $zipPath
    Write-PitCrewRemoteDiagnosticsUtf8 `
        -LiteralPath $checksumPath `
        -Content "$zipSha256  $([IO.Path]::GetFileName($zipPath))`n"
} finally {
    if (Test-Path -LiteralPath $stageDirectory) {
        Remove-Item -LiteralPath $stageDirectory -Recurse -Force
    }
}

[PSCustomObject][ordered]@{
    packageId = $packageId
    zipPath = (Resolve-Path -LiteralPath $zipPath).Path
    checksumPath = (Resolve-Path -LiteralPath $checksumPath).Path
    sha256 = Get-PitCrewRemoteDiagnosticsSha256 $zipPath
}
