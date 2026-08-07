#Requires -Version 7.0
<#
.SYNOPSIS
Captures remote-first Dashboard, GitHub, endpoint, and release evidence.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'ConnectorOffline',
        'CapacityMismatch',
        'JobNotAssigned',
        'HostPressure',
        'Full')]
    [string]$DiagnosticMode,

    [Uri]$PublicDashboardUrl,

    [Uri]$GitHubRunUrl,

    [string]$DashboardNodeId,

    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
    [string]$DashboardNodeStatus,

    [DateTimeOffset]$DashboardNodeLastSeenAt,

    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')]
    [string]$DashboardIncident,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RemoteDiagnostics.Core.ps1')

function Invoke-PitCrewPreflightGhJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][Collections.Generic.List[object]]$Unavailable
    )

    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
        $Unavailable.Add([PSCustomObject][ordered]@{
            category = $Operation
            reason = 'GitHub CLI is unavailable.'
            followUp = 'Authenticate gh and repeat the read-only metadata query.'
        })
        return $null
    }
    $output = & gh @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        $Unavailable.Add([PSCustomObject][ordered]@{
            category = $Operation
            reason = 'GitHub metadata could not be read.'
            followUp = 'Verify gh access to the explicitly approved repository and repeat without requesting logs.'
        })
        return $null
    }
    try {
        return ($output -join "`n") |
            ConvertFrom-Json -Depth 50 -ErrorAction Stop
    } catch [Management.Automation.RuntimeException] {
        $Unavailable.Add([PSCustomObject][ordered]@{
            category = $Operation
            reason = 'GitHub returned invalid JSON metadata.'
            followUp = 'Repeat the bounded gh metadata query.'
        })
        return $null
    }
}

$unavailable = [Collections.Generic.List[object]]::new()
$capturedAt = [DateTimeOffset]::UtcNow
$endpointEvidence = $null
if ($null -ne $PublicDashboardUrl) {
    Add-Type -AssemblyName System.Net.Http
    Assert-PitCrewRemoteDiagnosticUrl $PublicDashboardUrl
    $localHttp = $PublicDashboardUrl.Scheme -eq 'http' -and
        $PublicDashboardUrl.Host -in @('localhost', '127.0.0.1', '::1')
    if ($PublicDashboardUrl.Scheme -ne 'https' -and -not $localHttp) {
        throw 'PublicDashboardUrl must use HTTPS except for an explicit loopback URL.'
    }
    if ($PublicDashboardUrl.AbsolutePath -ne '/') {
        throw 'PublicDashboardUrl must be an origin-only URL.'
    }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    $request = $null
    $response = $null
    $endpointFailed = $false
    try {
        $request = [Net.Http.HttpRequestMessage]::new(
            [Net.Http.HttpMethod]::Get,
            $PublicDashboardUrl)
        $response = $client.Send(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        $endpointEvidence = [PSCustomObject][ordered]@{
            url = $PublicDashboardUrl.AbsoluteUri
            reachable = $true
            statusCode = [int]$response.StatusCode
            observedAt = [DateTimeOffset]::UtcNow
        }
    } catch [Net.Http.HttpRequestException] {
        $endpointFailed = $true
    } catch [Threading.Tasks.TaskCanceledException] {
        $endpointFailed = $true
    } catch [InvalidOperationException] {
        $endpointFailed = $true
    } finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
        if ($null -ne $request) {
            $request.Dispose()
        }
        $client.Dispose()
    }
    if ($endpointFailed) {
        $endpointEvidence = [PSCustomObject][ordered]@{
            url = $PublicDashboardUrl.AbsoluteUri
            reachable = $false
            statusCode = $null
            observedAt = [DateTimeOffset]::UtcNow
        }
        $unavailable.Add([PSCustomObject][ordered]@{
            category = 'public-dashboard-endpoint'
            reason = 'The public Dashboard endpoint did not respond within the bounded preflight.'
            followUp = 'Verify the public endpoint from an independent network without changing the host connector.'
        })
    }
} else {
    $unavailable.Add([PSCustomObject][ordered]@{
        category = 'public-dashboard-endpoint'
        reason = 'No public Dashboard URL was supplied.'
        followUp = 'Supply the exact public Dashboard origin for the next preflight.'
    })
}

$githubEvidence = $null
if ($null -ne $GitHubRunUrl) {
    if ($GitHubRunUrl.Scheme -ne 'https' -or
        $GitHubRunUrl.Host -ne 'github.com' -or
        -not [string]::IsNullOrEmpty($GitHubRunUrl.UserInfo) -or
        -not [string]::IsNullOrEmpty($GitHubRunUrl.Query) -or
        -not [string]::IsNullOrEmpty($GitHubRunUrl.Fragment)) {
        throw 'GitHubRunUrl must be an exact query-free github.com Actions run or job URL.'
    }
    $match = [regex]::Match(
        $GitHubRunUrl.AbsolutePath,
        '^/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)/actions/runs/(?<run>[1-9][0-9]*)(?:/job/(?<job>[1-9][0-9]*))?/?$')
    if (-not $match.Success) {
        throw 'GitHubRunUrl must identify one GitHub Actions run or job.'
    }
    $repository = "$($match.Groups['owner'].Value)/$($match.Groups['repo'].Value)"
    $runId = $match.Groups['run'].Value
    $run = Invoke-PitCrewPreflightGhJson `
        -Arguments @(
            'api',
            "repos/$repository/actions/runs/$runId") `
        -Operation 'github-run' `
        -Unavailable $unavailable
    $job = $null
    if ($match.Groups['job'].Success) {
        $job = Invoke-PitCrewPreflightGhJson `
            -Arguments @(
                'api',
                "repos/$repository/actions/jobs/$($match.Groups['job'].Value)") `
            -Operation 'github-job' `
            -Unavailable $unavailable
    }
    if ($null -ne $run) {
        $githubEvidence = [PSCustomObject][ordered]@{
            repository = $repository.ToLowerInvariant()
            runId = [string]$run.id
            runStatus = [string]$run.status
            runConclusion = $run.conclusion
            runCreatedAt = $run.created_at
            runUpdatedAt = $run.updated_at
            runUrl = [string]$run.html_url
            job = if ($null -eq $job) {
                $null
            } else {
                [PSCustomObject][ordered]@{
                    jobId = [string]$job.id
                    name = [string]$job.name
                    status = [string]$job.status
                    conclusion = $job.conclusion
                    startedAt = $job.started_at
                    completedAt = $job.completed_at
                    url = [string]$job.html_url
                }
            }
        }
    }
} else {
    $unavailable.Add([PSCustomObject][ordered]@{
        category = 'github-actions'
        reason = 'No GitHub Actions run or job URL was supplied.'
        followUp = 'Supply the exact affected run or job URL when the incident concerns assignment or workload progress.'
    })
}

$pitcrewRelease = Invoke-PitCrewPreflightGhJson `
    -Arguments @(
        'release',
        'view',
        '--repo',
        'ncosentino/pitcrew',
        '--json',
        'tagName,publishedAt,url') `
    -Operation 'pitcrew-release' `
    -Unavailable $unavailable
$dashboardRelease = Invoke-PitCrewPreflightGhJson `
    -Arguments @(
        'release',
        'view',
        '--repo',
        'ncosentino/pitcrew-dashboard',
        '--json',
        'tagName,publishedAt,url') `
    -Operation 'dashboard-release' `
    -Unavailable $unavailable

$preflight = [PSCustomObject][ordered]@{
    schemaVersion = 1
    capturedAt = $capturedAt
    diagnosticMode = $DiagnosticMode
    dashboard = [PSCustomObject][ordered]@{
        nodeId = if ([string]::IsNullOrWhiteSpace($DashboardNodeId)) {
            $null
        } else {
            $DashboardNodeId
        }
        status = if ([string]::IsNullOrWhiteSpace($DashboardNodeStatus)) {
            $null
        } else {
            $DashboardNodeStatus
        }
        lastSeenAt = if ($null -eq $DashboardNodeLastSeenAt -or
            $DashboardNodeLastSeenAt -eq [DateTimeOffset]::MinValue) {
            $null
        } else {
            $DashboardNodeLastSeenAt.ToUniversalTime()
        }
        incident = if ([string]::IsNullOrWhiteSpace($DashboardIncident)) {
            $null
        } else {
            $DashboardIncident
        }
        publicEndpoint = $endpointEvidence
    }
    github = $githubEvidence
    releases = [PSCustomObject][ordered]@{
        pitcrew = $pitcrewRelease
        dashboard = $dashboardRelease
    }
    unavailableEvidence = @($unavailable)
}
$directory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($directory)) {
    $null = New-Item -ItemType Directory -Path $directory -Force
}
Write-PitCrewRemoteDiagnosticsUtf8 `
    -LiteralPath $OutputPath `
    -Content ($preflight | ConvertTo-Json -Depth 50)
[PSCustomObject][ordered]@{
    preflightPath = (Resolve-Path -LiteralPath $OutputPath).Path
    capturedAt = $capturedAt
}
