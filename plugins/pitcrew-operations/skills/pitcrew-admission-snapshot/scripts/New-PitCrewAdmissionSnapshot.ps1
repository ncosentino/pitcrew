#Requires -Version 7.0
<#
.SYNOPSIS
Captures one read-only current PitCrew host-admission snapshot.

.DESCRIPTION
Queries only the scoped PitCrew Dashboard current-fleet diagnostic endpoint,
selects one exact node and profile, and writes a sanitized versioned JSON
snapshot. It never reserves capacity or mutates a workflow, runner, manager,
Docker daemon, container, image, network, volume, or host.

.PARAMETER DashboardUrl
Base URL of the PitCrew Dashboard deployment.

.PARAMETER TenantId
Dashboard tenant identifier authorized by the diagnostic credential.

.PARAMETER NodeId
Exact Dashboard node identifier.

.PARAMETER Profile
Exact PitCrew profile identifier.

.PARAMETER RequestedWorkers
Positive worker count to compare with coordinator-reported allocatable workers.

.PARAMETER OutputPath
Explicit JSON output path.

.EXAMPLE
$env:PITCREW_DIAGNOSTICS_CREDENTIAL = '<credential>'
./New-PitCrewAdmissionSnapshot.ps1 `
    -DashboardUrl https://dashboard.example `
    -TenantId example `
    -NodeId 00000000-0000-0000-0000-000000000001 `
    -Profile project-ci `
    -RequestedWorkers 4 `
    -OutputPath ./pitcrew-admission-snapshot.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Uri]$DashboardUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [Guid]$NodeId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
    [string]$Profile,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$RequestedWorkers,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
. (Join-Path $pluginRoot 'scripts' 'DashboardDiagnostics.Client.ps1')
. (Join-Path $pluginRoot 'scripts' 'HostAdmission.Projection.ps1')

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    throw 'OutputPath cannot be empty or whitespace.'
}
Assert-PitCrewDashboardUri $DashboardUrl
$resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $resolvedOutputPath -PathType Container) {
    throw 'OutputPath must identify a JSON file, not a directory.'
}

$credential = [Environment]::GetEnvironmentVariable(
    'PITCREW_DIAGNOSTICS_CREDENTIAL')
$credentialPresent = -not [string]::IsNullOrWhiteSpace($credential)
Write-Host 'Admission snapshot request:'
Write-Host "  Dashboard origin: $($DashboardUrl.GetLeftPart([UriPartial]::Authority))"
Write-Host "  Tenant: $TenantId"
Write-Host "  Node: $($NodeId.ToString('D'))"
Write-Host "  Profile: $Profile"
Write-Host "  Requested workers: $RequestedWorkers"
Write-Host "  Output: $resolvedOutputPath"
Write-Host "  Diagnostic credential present: $credentialPresent"

$dashboardClient = New-PitCrewDashboardDiagnosticClient `
    -DashboardUrl $DashboardUrl `
    -Credential $credential
$tenantPath = [Uri]::EscapeDataString($TenantId)
$pages = @(
    Get-PitCrewDashboardFleetPages `
        -Request {
        param($afterNodeId, $limit)

        $query = "limit=$limit"
        if ($null -ne $afterNodeId) {
            $query += "&afterNodeId=$([Uri]::EscapeDataString(
                [string]$afterNodeId))"
        }
        Invoke-PitCrewDashboardGet `
            -Client $dashboardClient `
            -Path "/api/diagnostics/v1/tenants/$tenantPath/fleet/nodes?$query"
    } `
        -StopWhen {
        param($page)

        return @(
            $page.Nodes |
                Where-Object {
                    [string](Get-PitCrewAdmissionProperty $_ 'nodeId') -ceq
                        $NodeId.ToString('D')
                }).Count -gt 0
    })

$nodeMatches = [Collections.Generic.List[object]]::new()
foreach ($page in $pages) {
    foreach ($node in @($page.Nodes)) {
        if ([string](Get-PitCrewAdmissionProperty $node 'nodeId') -ceq
            $NodeId.ToString('D')) {
            $nodeMatches.Add([PSCustomObject][ordered]@{
                Page = $page
                Node = $node
            })
        }
    }
}
if ($nodeMatches.Count -gt 1) {
    throw 'Dashboard returned the requested node more than once.'
}

$generatedAtValue = if ($nodeMatches.Count -eq 1) {
    $nodeMatches[0].Page.GeneratedAt
} elseif ($pages.Count -gt 0) {
    $pages[$pages.Count - 1].GeneratedAt
} else {
    $null
}
if ($null -eq $generatedAtValue) {
    throw 'Dashboard current-fleet response omitted its generation time.'
}
try {
    $generatedAt = [DateTimeOffset]$generatedAtValue
} catch {
    throw 'Dashboard current-fleet response returned an invalid generation time.'
}

$observedProfile = $null
$profileEvidence = $null
$missingReason = 'node-not-found'
if ($nodeMatches.Count -eq 1) {
    $node = $nodeMatches[0].Node
    $profiles = @(
        Get-PitCrewAdmissionProperty $node 'profiles' @() |
            Where-Object {
                [string](Get-PitCrewAdmissionProperty $_ 'profileId') -ceq
                    $Profile
            })
    if ($profiles.Count -gt 1) {
        throw 'Dashboard returned the requested profile more than once.'
    }
    if ($profiles.Count -eq 1) {
        $observedProfile = $profiles[0]
        $missingReason = $null
        $profileEvidenceMatches = @(
            Get-PitCrewAdmissionProperty $node 'profileEvidence' @() |
                Where-Object {
                    [string](Get-PitCrewAdmissionProperty $_ 'profileId') -ceq
                        $Profile
                })
        if ($profileEvidenceMatches.Count -gt 1) {
            throw 'Dashboard returned duplicate evidence for the requested profile.'
        }
        if ($profileEvidenceMatches.Count -eq 1) {
            $profileEvidence = $profileEvidenceMatches[0]
        }
    } else {
        $missingReason = 'profile-not-found'
    }
}

$snapshotParameters = @{
    NodeId = $NodeId
    ProfileId = $Profile
    RequestedWorkers = $RequestedWorkers
    GeneratedAt = $generatedAt
    ObservedProfile = $observedProfile
    ProfileEvidence = $profileEvidence
}
if ($null -ne $missingReason) {
    $snapshotParameters.MissingReason = $missingReason
}
$snapshot = New-PitCrewAdmissionSnapshotModel @snapshotParameters
$outputDirectory = Split-Path -Parent $resolvedOutputPath
[IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$json = $snapshot | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText(
    $resolvedOutputPath,
    "$json`n",
    [Text.UTF8Encoding]::new($false))

Write-Host 'Admission snapshot written:'
Write-Host "  JSON: $resolvedOutputPath"
Write-Host "  Disposition: $($snapshot.disposition)"
Write-Host "  Reason: $($snapshot.reason)"
