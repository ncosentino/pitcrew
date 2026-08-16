#Requires -Version 7.0
<#
.SYNOPSIS
Runs or packages the portable PitCrew diagnostics collector.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Direct', 'Ssh', 'WinRM', 'Package', 'Relay')]
    [string]$ExecutionMode,

    [string]$PitCrewRoot,

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
    [string]$PreflightPath,

    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [string]$SshHostName,

    [string]$SshUserName,

    [string]$SshKeyFilePath,

    [string]$WinRMComputerName,

    [PSCredential]$WinRMCredential,

    [Uri]$DashboardUrl,

    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
    [string]$TenantId,

    [Guid]$DashboardNodeId = [Guid]::Empty,

    [ValidateRange(30, 1800)]
    [int]$RelayTimeoutSeconds = 300,

    [ValidateRange(60, 3600)]
    [int]$RelayExpiresInSeconds = 900,

    [Guid]$SupportSessionId = [Guid]::Empty,

    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RemoteDiagnostics.Core.ps1')
. (Join-Path $PSScriptRoot 'RemoteDiagnostics.Transport.ps1')

if ($ExecutionMode -eq 'Relay') {
    foreach ($required in @(
            @{ Name = 'DashboardUrl'; Value = $DashboardUrl },
            @{ Name = 'TenantId'; Value = $TenantId })) {
        if ($null -eq $required.Value -or
            [string]::IsNullOrWhiteSpace([string]$required.Value)) {
            throw "Relay mode requires $($required.Name)."
        }
    }
    if ($DashboardNodeId -eq [Guid]::Empty) {
        throw 'Relay mode requires DashboardNodeId.'
    }
    $relayScript = Join-Path $PSScriptRoot 'Invoke-PitCrewSupportRelay.ps1'
    $relayArguments = @{
        DashboardUrl = $DashboardUrl
        TenantId = $TenantId
        DashboardNodeId = $DashboardNodeId
        DiagnosticMode = $DiagnosticMode
        PreflightPath = $PreflightPath
        OutputDirectory = $OutputDirectory
        TimeoutSeconds = $RelayTimeoutSeconds
        ExpiresInSeconds = $RelayExpiresInSeconds
        PlanOnly = $PlanOnly
    }
    if ($SupportSessionId -ne [Guid]::Empty) {
        $relayArguments.SessionId = $SupportSessionId
    }
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $relayArguments.Profile = $Profile
    }
    return & $relayScript @relayArguments
}

if ([string]::IsNullOrWhiteSpace($PitCrewRoot)) {
    throw "$ExecutionMode mode requires PitCrewRoot."
}
Assert-PitCrewRemoteRootLiteral $PitCrewRoot
$collectorPath = Join-Path $PSScriptRoot 'Collect-PitCrewDiagnostics.ps1'
$packageScript = Join-Path $PSScriptRoot 'New-PitCrewDiagnosticsPackage.ps1'
$importScript = Join-Path $PSScriptRoot 'Import-PitCrewDiagnostics.ps1'
$transportScript = Join-Path $PSScriptRoot 'RemoteDiagnostics.Transport.ps1'
foreach ($requiredPath in @(
        $collectorPath,
        $packageScript,
        $importScript,
        $transportScript,
        $PreflightPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw 'A required remote-diagnostics script or preflight artifact is missing.'
    }
}
$preflight = Get-Content `
    -LiteralPath $PreflightPath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json -Depth 50 -ErrorAction Stop
if ($preflight.schemaVersion -ne 1 -or
    $null -eq $preflight.capturedAt -or
    (Test-PitCrewRemoteDiagnosticsForbiddenProperty $preflight)) {
    throw 'PreflightPath does not satisfy the read-only evidence contract.'
}
if ($ExecutionMode -eq 'Ssh' -and
    ($SshHostName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$' -or
        $SshUserName -notmatch '^[A-Za-z0-9._-]{1,64}$')) {
    throw 'Ssh mode requires explicit literal SshHostName and SshUserName values.'
}
if ($ExecutionMode -eq 'WinRM' -and
    $WinRMComputerName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$') {
    throw 'WinRM mode requires an explicit literal WinRMComputerName.'
}
$resolvedSshKeyPath = $null
if ($ExecutionMode -eq 'Ssh' -and
    -not [string]::IsNullOrWhiteSpace($SshKeyFilePath)) {
    $resolvedKey = Resolve-Path `
        -LiteralPath $SshKeyFilePath `
        -ErrorAction Stop
    if ((Get-Item -LiteralPath $resolvedKey.Path).PSIsContainer) {
        throw 'SshKeyFilePath must identify one explicit key file.'
    }
    $resolvedSshKeyPath = $resolvedKey.Path
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
    -TargetPitCrewRoot $PitCrewRoot `
    -DiagnosticMode $DiagnosticMode `
    -Profile $Profile `
    -ApprovedUrls $safeUrls `
    -ProbeTimeoutSeconds $ProbeTimeoutSeconds

$plan = [PSCustomObject][ordered]@{
    executionMode = $ExecutionMode
    diagnosticMode = $DiagnosticMode
    packageId = $packageId
    profile = if ([string]::IsNullOrWhiteSpace($Profile)) {
        $null
    } else {
        $Profile
    }
    approvedUrls = $safeUrls
    probeTimeoutSeconds = $ProbeTimeoutSeconds
    transport = switch ($ExecutionMode) {
        'Direct' {
            [PSCustomObject][ordered]@{
                type = 'local-process'
                command = 'pwsh Collect-PitCrewDiagnostics.ps1 <fixed-arguments>'
            }
        }
        'Ssh' {
            [PSCustomObject][ordered]@{
                type = 'powershell-remoting-ssh'
                hostName = $SshHostName
                userName = $SshUserName
                keyFile = if ([string]::IsNullOrWhiteSpace($SshKeyFilePath)) {
                    $null
                } else {
                    '<explicit-key-file>'
                }
                command = 'Invoke-Command -HostName <explicit-host> -ScriptBlock <fixed-collector-runner>'
            }
        }
        'WinRM' {
            [PSCustomObject][ordered]@{
                type = 'powershell-remoting-winrm'
                computerName = $WinRMComputerName
                credentialSupplied = $null -ne $WinRMCredential
                command = 'Invoke-Command -ComputerName <explicit-host> -ScriptBlock <fixed-collector-runner>'
            }
        }
        'Package' {
            [PSCustomObject][ordered]@{
                type = 'agent-handoff'
                command = 'pwsh Invoke-Collection.ps1'
            }
        }
    }
}
if ($PlanOnly) {
    $plan
    return
}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path

if ($ExecutionMode -eq 'Package') {
    $packageArguments = @{
        TargetPitCrewRoot = $PitCrewRoot
        DiagnosticMode = $DiagnosticMode
        ApprovedUrl = $safeUrls
        ProbeTimeoutSeconds = $ProbeTimeoutSeconds
        OutputDirectory = $resolvedOutput
    }
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $packageArguments.Profile = $Profile
    }
    & $packageScript @packageArguments
    return
}

$collectorArguments = @{
    PitCrewRoot = $PitCrewRoot
    DiagnosticMode = $DiagnosticMode
    ApprovedUrl = $safeUrls
    ProbeTimeoutSeconds = $ProbeTimeoutSeconds
    PackageId = $packageId
}
if (-not [string]::IsNullOrWhiteSpace($Profile)) {
    $collectorArguments.Profile = $Profile
}

$resultDirectory = Join-Path `
    $resolvedOutput `
    "pitcrew-diagnostics-$packageId"
if ($ExecutionMode -eq 'Direct') {
    $collectorArguments.OutputDirectory = $resultDirectory
    $artifacts = & $collectorPath @collectorArguments
} else {
    $collectorArguments.PassThruOnly = $true
    $collectorSource = Get-Content `
        -LiteralPath $collectorPath `
        -Raw `
        -Encoding UTF8
    $argumentsJson = $collectorArguments |
        ConvertTo-Json -Depth 20 -Compress
    $transportArguments = @{
        ExecutionMode = $ExecutionMode
        CollectorSource = $collectorSource
        ArgumentsJson = $argumentsJson
        SshHostName = $SshHostName
        SshUserName = $SshUserName
        SshKeyFilePath = $resolvedSshKeyPath
        WinRMComputerName = $WinRMComputerName
        WinRMCredential = $WinRMCredential
    }
    $localEnvelope = Invoke-PitCrewCollectorTransport @transportArguments
    $artifacts = Complete-PitCrewCollectorTransport `
        -Envelope $localEnvelope `
        -CollectorSha256 $collectorSha256 `
        -OutputDirectory $resultDirectory
}

& $importScript `
    -InputPath $artifacts.outputDirectory `
    -ExpectedPackageId $packageId `
    -ExpectedCollectorSha256 $collectorSha256 `
    -PreflightPath $PreflightPath `
    -OutputDirectory (Join-Path `
        $resolvedOutput `
        "pitcrew-diagnosis-$packageId")
