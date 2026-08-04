#Requires -Version 7.0
<#
.SYNOPSIS
Creates a redacted PitCrew performance-correlation report.

.DESCRIPTION
Queries only scoped PitCrew Dashboard diagnostic endpoints and GitHub Actions
job metadata. It never reads logs, artifacts, environments, runner
registration material, or host/Docker state.

.PARAMETER DashboardUrl
Base URL of the PitCrew Dashboard deployment.

.PARAMETER TenantId
Dashboard tenant identifier authorized by the diagnostic credential.

.PARAMETER Repositories
Explicit GitHub repositories in OWNER/REPOSITORY form.

.PARAMETER From
Inclusive UTC start of the bounded report range.

.PARAMETER To
Exclusive UTC end of the bounded report range.

.PARAMETER OutputDirectory
Directory that receives equivalent Markdown and JSON reports.

.PARAMETER NodeId
Optional Dashboard node identifiers to include.

.PARAMETER Profile
Optional profile identifiers to include.

.PARAMETER Workflow
Optional case-insensitive workflow-name filters.

.PARAMETER Job
Optional case-insensitive job-name filters.

.EXAMPLE
$env:PITCREW_DIAGNOSTICS_CREDENTIAL = '<credential>'
./New-PitCrewPerformanceReport.ps1 `
    -DashboardUrl https://dashboard.example `
    -TenantId example `
    -Repositories owner/repository `
    -From 2026-08-01T00:00:00Z `
    -To 2026-08-02T00:00:00Z
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Uri]$DashboardUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Repositories,

    [Parameter(Mandatory)]
    [DateTimeOffset]$From,

    [Parameter(Mandatory)]
    [DateTimeOffset]$To,

    [string]$OutputDirectory,

    [Guid[]]$NodeId = @(),

    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
    [string[]]$Profile = @(),

    [string[]]$Workflow = @(),

    [string[]]$Job = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PerformanceReport.Core.ps1')
$script:LastDashboardRequestAt = [DateTimeOffset]::MinValue
$script:DashboardMinimumIntervalMilliseconds = 500

function Assert-PitCrewDashboardUri {
    param([Parameter(Mandatory)][Uri]$Uri)

    if (-not [string]::IsNullOrEmpty($Uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($Uri.Query) -or
        -not [string]::IsNullOrEmpty($Uri.Fragment)) {
        throw 'DashboardUrl cannot contain credentials, a query string, or a fragment.'
    }
    $localHttp = $Uri.Scheme -eq 'http' -and
        $Uri.Host -in @('localhost', '127.0.0.1', '::1')
    if ($Uri.Scheme -ne 'https' -and -not $localHttp) {
        throw 'DashboardUrl must use HTTPS, except for an explicit localhost URL.'
    }
}

function Invoke-PitCrewDashboardGet {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $base = $DashboardUrl.AbsoluteUri.TrimEnd('/')
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $now = [DateTimeOffset]::UtcNow
        $elapsedInterval = $now - $script:LastDashboardRequestAt
        $elapsed = $elapsedInterval.TotalMilliseconds
        $delay = $script:DashboardMinimumIntervalMilliseconds - $elapsed
        if ($delay -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Ceiling($delay))
        }
        $script:LastDashboardRequestAt = [DateTimeOffset]::UtcNow
        try {
            return Invoke-RestMethod `
                -Method Get `
                -Uri "$base$Path" `
                -Headers $Headers
        } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            if ([int]$_.Exception.Response.StatusCode -ne 429 -or
                $attempt -eq 3) {
                throw
            }
            $retryAfter = 60
            $header = $_.Exception.Response.Headers.RetryAfter
            if ($null -ne $header -and $null -ne $header.Delta) {
                $retryAfter = [Math]::Max(
                    1,
                    [Math]::Ceiling($header.Delta.TotalSeconds))
            }
            Start-Sleep -Seconds $retryAfter
        }
    }
}

function Invoke-PitCrewGhJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Operation
    )

    $output = & gh @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI failed while $Operation."
    }
    return ($output -join "`n") | ConvertFrom-Json -Depth 100
}

function Get-PitCrewGitHubJobs {
    param(
        [Parameter(Mandatory)]
        [string[]]$ApprovedRepositories,

        [Parameter(Mandatory)]
        [DateTimeOffset]$RangeStart,

        [Parameter(Mandatory)]
        [DateTimeOffset]$RangeEnd
    )

    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is required for job metadata.'
    }
    $jobs = [Collections.Generic.List[object]]::new()
    # GitHub permits a workflow run to remain active for up to 35 days,
    # including protected-environment waits.
    foreach ($repository in $ApprovedRepositories) {
        if ($repository -notmatch
            '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            throw "Repository '$repository' must use OWNER/REPOSITORY form."
        }
        $runs = Get-PitCrewPartitionedWorkflowRuns `
            -From $RangeStart.AddDays(-35) `
            -To $RangeEnd `
            -Request {
                param($partitionStart, $partitionEnd)
                $runPages = Invoke-PitCrewGhJson `
                    -Operation "listing workflow runs for '$repository'" `
                    -Arguments @(
                        'api',
                        '--paginate',
                        '--slurp',
                        '-X', 'GET',
                        "repos/$repository/actions/runs",
                        '-f',
                        "created=$($partitionStart.ToString('O'))..$($partitionEnd.ToString('O'))",
                        '-f', 'per_page=100')
                $partitionRuns = @(
                    foreach ($page in @($runPages)) {
                        @($page.workflow_runs)
                    })
                [PSCustomObject]@{
                    TotalCount = if (@($runPages).Count -eq 0) {
                        0
                    } else {
                        [long]$runPages[0].total_count
                    }
                    Runs = $partitionRuns
                }
            }
        foreach ($run in $runs) {
            $workflowName = [string]$run.name
            if (-not (Test-PitCrewLiteralTextFilter `
                    -Value $workflowName `
                    -Filters $Workflow)) {
                continue
            }
            if (-not (Test-PitCrewWorkflowRunRelevant `
                    -Status ([string]$run.status) `
                    -CreatedAt $run.created_at `
                    -UpdatedAt $run.updated_at `
                    -From $RangeStart `
                    -To $RangeEnd)) {
                continue
            }
            $jobPages = Invoke-PitCrewGhJson `
                -Operation "listing jobs for workflow run '$($run.id)'" `
                -Arguments @(
                    'api',
                    '--paginate',
                    '--slurp',
                    '-X', 'GET',
                    "repos/$repository/actions/runs/$($run.id)/jobs",
                    '-f', 'filter=all',
                    '-f', 'per_page=100')
            foreach ($page in @($jobPages)) {
                foreach ($githubJob in @($page.jobs)) {
                    $jobName = [string]$githubJob.name
                    if (-not (Test-PitCrewLiteralTextFilter `
                            -Value $jobName `
                            -Filters $Job)) {
                        continue
                    }
                    $startedAt = if ($null -eq $githubJob.started_at) {
                        $null
                    } else {
                        ConvertTo-PitCrewUtc $githubJob.started_at
                    }
                    $completedAt = if ($null -eq $githubJob.completed_at) {
                        $null
                    } else {
                        ConvertTo-PitCrewUtc $githubJob.completed_at
                    }
                    if ($null -eq $startedAt -and
                        -not (Test-PitCrewUntimedJobRelevant `
                            -Conclusion $githubJob.conclusion `
                            -RunStatus ([string]$run.status) `
                            -RunCreatedAt $run.created_at `
                            -RunUpdatedAt $run.updated_at `
                            -From $RangeStart `
                            -To $RangeEnd)) {
                        continue
                    }
                    $effectiveEnd = if ($null -eq $completedAt) {
                        $RangeEnd
                    } else {
                        $completedAt
                    }
                    if ($null -ne $startedAt -and
                        ($effectiveEnd -le $RangeStart -or
                            $startedAt -ge $RangeEnd)) {
                        continue
                    }
                    $jobs.Add([PSCustomObject][ordered]@{
                        repository = $repository.ToLowerInvariant()
                        workflowRunId = [string]$run.id
                        workflowId = [string]$run.workflow_id
                        workflowName = $workflowName
                        runAttempt = [int](
                            Get-PitCrewProperty `
                                $githubJob `
                                'run_attempt' `
                                (Get-PitCrewProperty $run 'run_attempt' 1))
                        jobId = [string]$githubJob.id
                        jobName = $jobName
                        runnerName = [string]$githubJob.runner_name
                        labels = @($githubJob.labels)
                        startedAt = $startedAt
                        completedAt = $completedAt
                        status = [string]$githubJob.status
                        conclusion = $githubJob.conclusion
                    })
                }
            }
        }
    }
    return @($jobs)
}

Assert-PitCrewDashboardUri $DashboardUrl
if ($To -le $From) {
    throw 'To must be after From.'
}
$Repositories = @(
    $Repositories |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Sort-Object -Unique)
$NodeId = @($NodeId | Sort-Object -Unique)
$Profile = @($Profile | Sort-Object -Unique)
$Workflow = @($Workflow | Sort-Object -Unique)
$Job = @($Job | Sort-Object -Unique)
if ($Profile.Count -gt 0 -and $NodeId.Count -eq 0) {
    throw 'Profile filters require explicit NodeId values so removed retained profiles remain enumerable.'
}
$credential = [Environment]::GetEnvironmentVariable(
    'PITCREW_DIAGNOSTICS_CREDENTIAL')
if ([string]::IsNullOrWhiteSpace($credential)) {
    throw 'Set PITCREW_DIAGNOSTICS_CREDENTIAL in the process environment.'
}
$headers = @{
    Authorization = "PitCrew-Diagnostics $credential"
}
$tenantPath = [Uri]::EscapeDataString($TenantId)
$capabilities = Invoke-PitCrewDashboardGet `
    -Path "/api/diagnostics/v1/tenants/$tenantPath/fleet/history/capabilities" `
    -Headers $headers
$maximumRange = [TimeSpan]::FromHours(
    [double]$capabilities.maximumRangeHours)
if (($To - $From) -gt $maximumRange) {
    throw "The requested range exceeds Dashboard's $($capabilities.maximumRangeHours)-hour limit."
}

$nodes = Invoke-PitCrewPagedFleetRequest -Request {
    param($afterNodeId, $limit)
    $query = "limit=$limit"
    if ($null -ne $afterNodeId) {
        $query += "&afterNodeId=$([Uri]::EscapeDataString([string]$afterNodeId))"
    }
    Invoke-PitCrewDashboardGet `
        -Path "/api/diagnostics/v1/tenants/$tenantPath/fleet/nodes?$query" `
        -Headers $headers
}
if ($NodeId.Count -gt 0) {
    $selectedNodes = @($NodeId | ForEach-Object { $_.ToString('D') })
    $nodes = @(
        $nodes |
            Where-Object { [string]$_.nodeId -in $selectedNodes })
    $returnedNodeIds = @($nodes.nodeId | ForEach-Object { [string]$_ })
    foreach ($selectedNodeId in $selectedNodes) {
        if ($selectedNodeId -notin $returnedNodeIds) {
            $nodes += [PSCustomObject][ordered]@{
                nodeId = $selectedNodeId
                profiles = @()
                hardware = $null
                currentFleetUnavailable = $true
            }
        }
    }
}
$query = @(
    "from=$([Uri]::EscapeDataString($From.ToUniversalTime().ToString('O')))",
    "to=$([Uri]::EscapeDataString($To.ToUniversalTime().ToString('O')))",
    'resolution=raw',
    "points=$([int]$capabilities.maximumPoints)",
    "events=$([int]$capabilities.maximumEvents)",
    "diagnostics=$([int]$capabilities.maximumDiagnostics)"
) -join '&'
$histories = @{}
foreach ($node in $nodes) {
    $nodeIdText = [string]$node.nodeId
    $encodedNode = [Uri]::EscapeDataString($nodeIdText)
    try {
        $nodeHistory = Invoke-PitCrewDashboardGet `
            -Path "/api/diagnostics/v1/tenants/$tenantPath/fleet/nodes/$encodedNode/history?$query" `
            -Headers $headers
        if ($Profile.Count -gt 0) {
            $availableProfiles = @(
                $nodeHistory.profiles.profileId |
                    Sort-Object -Unique)
            $missingProfiles = @(
                $Profile |
                    Where-Object { $_ -notin $availableProfiles })
            $nodeHistory.profiles = @(
                $nodeHistory.profiles |
                    Where-Object { $_.profileId -in $Profile })
            $nodeHistory.runnerAssignments = @(
                $nodeHistory.runnerAssignments |
                    Where-Object { $_.profileId -in $Profile })
            $nodeHistory | Add-Member `
                -NotePropertyName requestedProfilesUnavailable `
                -NotePropertyValue $missingProfiles `
                -Force
        }
        $histories[$nodeIdText] = $nodeHistory
        continue
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        if ([int]$_.Exception.Response.StatusCode -ne 403) {
            throw
        }
    }

    $profileResponses = [Collections.Generic.List[object]]::new()
    $missingProfiles = [Collections.Generic.List[string]]::new()
    $profileEnumerationIncomplete = $Profile.Count -eq 0
    $profileIdsToQuery = if ($Profile.Count -gt 0) {
        @($Profile)
    } else {
        @($node.profiles.profileId)
    }
    foreach ($profileId in $profileIdsToQuery) {
        $encodedProfile = [Uri]::EscapeDataString($profileId)
        try {
            $response = Invoke-PitCrewDashboardGet `
                -Path "/api/diagnostics/v1/tenants/$tenantPath/fleet/nodes/$encodedNode/profiles/$encodedProfile/history?$query" `
                -Headers $headers
            if (@($response.profiles).Count -eq 0) {
                $missingProfiles.Add($profileId)
            } else {
                $profileResponses.Add($response)
            }
        } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            if ([int]$_.Exception.Response.StatusCode -notin @(403, 404)) {
                throw
            }
            $missingProfiles.Add($profileId)
        }
    }
    $floorMap = @{}
    foreach ($response in $profileResponses) {
        foreach ($floor in @($response.incompletenessFloors)) {
            $key = $floor | ConvertTo-Json -Depth 10 -Compress
            $floorMap[$key] = $floor
        }
    }
    $histories[$nodeIdText] = [PSCustomObject][ordered]@{
        profiles = @(
            foreach ($response in $profileResponses) {
                @($response.profiles)
            })
        runnerAssignments = @(
            foreach ($response in $profileResponses) {
                @($response.runnerAssignments)
            })
        runnerAssignmentsTruncated = @(
            $profileResponses |
                Where-Object runnerAssignmentsTruncated).Count -gt 0
        hardwareRevisions = @()
        hardwareHistoryUnavailable = $true
        pointsTruncated = @(
            $profileResponses |
                Where-Object pointsTruncated).Count -gt 0
        eventsTruncated = @(
            $profileResponses |
                Where-Object eventsTruncated).Count -gt 0
        diagnosticsTruncated = @(
            $profileResponses |
                Where-Object diagnosticsTruncated).Count -gt 0
        incompletenessFloors = @($floorMap.Values)
        requestedProfilesUnavailable = @($missingProfiles)
        profileEnumerationIncomplete = $profileEnumerationIncomplete
    }
}

$jobs = Get-PitCrewGitHubJobs `
    -ApprovedRepositories $Repositories `
    -RangeStart $From `
    -RangeEnd $To
$report = New-PitCrewPerformanceReportModel `
    -Jobs $jobs `
    -Nodes $nodes `
    -Histories $histories `
    -From $From `
    -To $To `
    -Repositories $Repositories `
    -ExpectedCadenceSeconds ([int]$capabilities.expectedRawCadenceSeconds)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $OutputDirectory = Join-Path `
        (Get-Location).Path `
        "pitcrew-performance-report-$stamp"
}
$written = Write-PitCrewPerformanceReport `
    -Report $report `
    -OutputDirectory $OutputDirectory
Write-Host "Performance report written:"
Write-Host "  Markdown: $($written.MarkdownPath)"
Write-Host "  JSON: $($written.JsonPath)"
Write-Host "  Jobs: $(@($report.verifiedMeasurements.jobs).Count)"
Write-Host "  Evidence gaps: $(@($report.unavailableEvidence).Count)"
