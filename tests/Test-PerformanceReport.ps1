#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$corePath = Join-Path `
    $root `
    'plugins' `
    'pitcrew-operations' `
    'skills' `
    'pitcrew-performance-report' `
    'scripts' `
    'PerformanceReport.Core.ps1'
$commandPath = Join-Path `
    (Split-Path -Parent $corePath) `
    'New-PitCrewPerformanceReport.ps1'
$fixturePath = Join-Path `
    $PSScriptRoot `
    'fixtures' `
    'performance-report' `
    'input.json'
. $corePath

$errors = [Collections.Generic.List[string]]::new()
$checks = 0

function Add-Check {
    param(
        [object]$Condition,
        [string]$Failure
    )

    $script:checks++
    if (-not $Condition) {
        $script:errors.Add($Failure)
    }
}

$fixture = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 |
    ConvertFrom-Json -Depth 30
$histories = @{}
foreach ($property in $fixture.histories.PSObject.Properties) {
    $histories[$property.Name] = $property.Value
}
$outsideJob = [PSCustomObject][ordered]@{
    repository = 'example/project'
    workflowRunId = 'outside'
    workflowName = 'build'
    runAttempt = 1
    jobId = 'outside'
    jobName = 'outside range'
    runnerName = 'runner-a-build'
    labels = @('self-hosted')
    startedAt = '2026-07-31T10:00:00Z'
    completedAt = '2026-07-31T10:10:00Z'
    status = 'completed'
    conclusion = 'success'
}
$report = New-PitCrewPerformanceReportModel `
    -Jobs (@($fixture.jobs) + @($outsideJob)) `
    -Nodes @($fixture.nodes) `
    -Histories $histories `
    -From ([DateTimeOffset]$fixture.from) `
    -To ([DateTimeOffset]$fixture.to) `
    -Repositories @($fixture.repositories) `
    -GeneratedAt ([DateTimeOffset]'2026-08-02T00:00:00Z')

$jobs = @($report.verifiedMeasurements.jobs)
$matched = @($jobs | Where-Object mappingStatus -eq 'matched')
$steps = @($report.verifiedMeasurements.steps)
$matchedSteps = @($steps | Where-Object mappingStatus -eq 'matched')
Add-Check (
    [int]$report.schemaVersion -eq 2
) 'Range reports no longer preserve the existing schema version.'
Add-Check (
    $null -eq $report.PSObject.Properties['selection']
) 'Range reports gained an exact-run-only selection field.'
Add-Check ($jobs.Count -eq 6) 'The report did not enforce the requested time bounds.'
Add-Check ($matched.Count -eq 5) 'Exact runner hashes did not map the expected jobs.'
Add-Check ($steps.Count -eq 5) 'Selected GitHub step metadata was not preserved.'
Add-Check ($matchedSteps.Count -eq 4) 'Mapped step measurements did not inherit job mapping.'
Add-Check (
    ($matched | Where-Object jobId -eq '2003').crossProfileOverlapSeconds -eq 900
) 'The build overlap window was calculated incorrectly.'
Add-Check (
    ($matched | Where-Object jobId -eq '2004').crossProfileOverlapSeconds -eq 900
) 'The test overlap window was calculated incorrectly.'
Add-Check (
    ($matched | Where-Object jobId -eq '2005').hardwareInventoryHash -eq
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
) 'Stable pre-range hardware was not time-aligned to an in-range job.'

$nodeAComparison = $report.verifiedMeasurements.overlapComparisons |
    Where-Object nodeKey -eq 'node-1'
$buildSummary = $report.verifiedMeasurements.jobNodeSummaries |
    Where-Object {
        $_.nodeKey -eq 'node-1' -and
        $_.workflowName -eq 'build' -and
        $_.jobName -eq 'build'
    }
Add-Check (
    $buildSummary.statistics.count -eq 3 -and
    $buildSummary.statistics.medianSeconds -eq 600
) 'Per-job/node statistics mixed unlike job cohorts.'
$nodeASummary = $report.verifiedMeasurements.nodeSummaries |
    Where-Object nodeKey -eq 'node-1'
Add-Check (
    $nodeASummary.statistics.medianSeconds -eq 900
) 'The even-sample node median was not averaged conventionally.'
Add-Check (
    $nodeAComparison.withoutCrossProfileOverlap.medianSeconds -eq 600
) 'The stable node baseline median was calculated incorrectly.'
Add-Check (
    $nodeAComparison.withCrossProfileOverlap.medianSeconds -eq 1200
) 'The overlap median was calculated incorrectly.'
Add-Check (
    $nodeAComparison.medianDeltaPercent -eq 100
) 'The overlap slowdown percentage was calculated incorrectly.'
$nodeAStepSummary = $report.verifiedMeasurements.stepNodeSummaries |
    Where-Object {
        $_.nodeKey -eq 'node-1' -and
        $_.stepName -eq 'Run fixed contracts'
    }
Add-Check (
    $nodeAStepSummary.statistics.count -eq 3 -and
    $nodeAStepSummary.statistics.medianSeconds -eq 180 -and
    $nodeAStepSummary.statistics.p95Seconds -eq 600
) 'Per-step node statistics did not preserve the selected timing cohort.'
$nodeBStepSummary = $report.verifiedMeasurements.stepProfileSummaries |
    Where-Object {
        $_.nodeKey -eq 'node-2' -and
        $_.profileId -eq 'build' -and
        $_.stepName -eq 'Run fixed contracts'
    }
Add-Check (
    $nodeBStepSummary.statistics.count -eq 1 -and
    $nodeBStepSummary.statistics.medianSeconds -eq 90
) 'Per-step profile statistics did not preserve the mapped node context.'
$overlappedStep = $matchedSteps |
    Where-Object jobId -eq '2003'
Add-Check (
    $overlappedStep.jobCrossProfileOverlapSeconds -eq 900
) 'Selected step timing did not retain its job-level overlap context.'
Add-Check (
    @($report.unavailableEvidence |
        Where-Object kind -eq 'step-timing').Count -eq 1
) 'Missing GitHub step timestamps were not reported as unavailable evidence.'

Add-Check (
    @($report.verifiedMeasurements.nodes |
        Where-Object nodeKey -eq 'node-1')[0].hardwareRevisions.Count -eq 1
) 'Hardware inventory changes were not retained in the report.'
Add-Check (
    @($report.unavailableEvidence |
        Where-Object kind -eq 'telemetry').Count -eq 1
) 'Partial telemetry was not reported as unavailable evidence.'
Add-Check (
    @($report.unavailableEvidence |
        Where-Object {
            $_.kind -eq 'telemetry-coverage' -and
            $_.nodeKey -eq 'node-1' -and
            $_.profileId -eq 'build'
        }).Count -eq 1
) 'An interior telemetry gap was not reported as unavailable evidence.'
Add-Check (
    @($report.unavailableEvidence |
        Where-Object kind -eq 'runner-mapping').Count -eq 1
) 'The unmatched job was not reported explicitly.'
Add-Check (
    @($report.hypotheses |
        Where-Object hypothesis -match 'Cross-profile').Count -eq 1
) 'The stable-baseline versus overlap fixture did not produce a contention hypothesis.'
Add-Check (
    @($report.hypotheses |
        Where-Object hypothesis -match 'hardware').Count -eq 1
) 'Different hardware inventories did not remain a competing hypothesis.'
$buildAdmission = $report.verifiedMeasurements.admissionSummaries |
    Where-Object {
        $_.nodeKey -eq 'node-1' -and
        $_.profileId -eq 'build'
    }
Add-Check (
    $buildAdmission.statusCounts.available -eq 2 -and
    $buildAdmission.latest.epoch -eq 2 -and
    $buildAdmission.latest.decisionSequence -eq 14
) 'Contract-18 admission status and decision progress were not summarized.'
Add-Check (
    $buildAdmission.maximumHeldUnits -eq 8 -and
    $buildAdmission.maximumWithheldUnits -eq 4 -and
    $buildAdmission.withheldSampleCount -eq 1
) 'Admission held and withheld unit summaries were calculated incorrectly.'
Add-Check (
    @($buildAdmission.deficitReasons |
        Where-Object reason -eq 'host-admission-withheld').Count -eq 1
) 'The report omitted the admission-specific capacity-deficit reason.'
$admissionGapSummary = New-PitCrewHostAdmissionSummary `
    -NodeKey node-gap `
    -ProfileId gap-profile `
    -Samples @(
        [PSCustomObject]@{
            observedAt = '2026-08-01T00:00:00Z'
            hostAdmissionStatus = 'available'
            hostAdmissionEpoch = 1
            hostAdmissionDecisionSequence = 2
        },
        [PSCustomObject]@{
            observedAt = '2026-08-01T00:01:00Z'
        })
Add-Check (
    $admissionGapSummary.latest.status -eq 'unreported' -and
    $null -eq $admissionGapSummary.latest.epoch -and
    $admissionGapSummary.unreportedSampleCount -eq 1
) 'A newer unreported sample was hidden behind older available admission evidence.'
$legacyAdmissionSummary = New-PitCrewHostAdmissionSummary `
    -NodeKey node-legacy `
    -ProfileId legacy-profile `
    -Samples @(
        [PSCustomObject]@{
            observedAt = '2026-08-01T00:00:00Z'
        })
$mixedReasonSummary = New-PitCrewHostAdmissionSummary `
    -NodeKey node-mixed `
    -ProfileId mixed-profile `
    -Samples @(
        [PSCustomObject]@{
            observedAt = '2026-08-01T00:00:00Z'
            capacityDeficitReason = 'none'
        },
        [PSCustomObject]@{
            observedAt = '2026-08-01T00:01:00Z'
        })
Add-Check (
    (ConvertTo-PitCrewAdmissionDeficitReasonText `
        -Summary $legacyAdmissionSummary) -eq 'unreported' -and
    (ConvertTo-PitCrewAdmissionDeficitReasonText `
        -Summary $mixedReasonSummary) -eq 'unavailable'
) 'Legacy missing admission evidence was rendered as a measured no-deficit state.'
$deduplicatedReasonSummary = New-PitCrewHostAdmissionSummary `
    -NodeKey node-deduplicated `
    -ProfileId deduplicated-profile `
    -Samples @(
        [PSCustomObject]@{
            observedAt = '2026-08-01T00:00:00Z'
            capacityDeficitReason = 'host-admission-withheld'
        }) `
    -CapacityDeficits @(
        [PSCustomObject]@{
            observedAt = '2026-08-01T00:00:00Z'
            reason = 'host-admission-withheld'
        })
Add-Check (
    $deduplicatedReasonSummary.deficitReasons.Count -eq 1 -and
    $deduplicatedReasonSummary.deficitReasons[0].samples -eq 1
) 'Sample and per-target admission reasons were counted twice.'
$jsonElementDocument =
    [Text.Json.JsonDocument]::Parse('{"reason":"none"}')
try {
    $singleReasonSummary = New-PitCrewHostAdmissionSummary `
        -NodeKey node-single-reason `
        -ProfileId single-reason-profile `
        -Samples @() `
        -CapacityDeficits @($jsonElementDocument.RootElement)
    Add-Check (
        (
            $singleReasonSummary.reportedDeficitReasonObservationCount +
            $singleReasonSummary.unreportedDeficitReasonObservationCount
        ) -eq 1
    ) 'A single live diagnostic reason required a synthetic Count property.'
} finally {
    $jsonElementDocument.Dispose()
}
$admissionDeficitReasons = @(
    $report.verifiedMeasurements.admissionSummaries |
        ForEach-Object { @($_.deficitReasons) } |
        ForEach-Object { $_.reason } |
        Sort-Object -Unique)
Add-Check (
    @(
        @(
            'host-admission-degraded',
            'host-admission-unavailable',
            'host-admission-withheld') |
            Where-Object { $_ -notin $admissionDeficitReasons }
    ).Count -eq 0
) 'The report did not keep all admission deficit reasons distinct.'
Add-Check (
    @($report.unavailableEvidence |
        Where-Object kind -eq 'host-admission-unavailable').Count -eq 1
) 'Unavailable coordinator evidence was not classified honestly.'
Add-Check (
    @($report.unavailableEvidence |
        Where-Object kind -eq 'host-admission-degraded').Count -eq 1
) 'Degraded admission evidence was not reported explicitly.'
Add-Check (
    $buildAdmission.capacityDeficitsTruncated -and
    @($report.unavailableEvidence |
        Where-Object kind -eq 'host-admission-deficits-truncated').Count -eq 1
) 'Truncated per-target admission history was not reported as unavailable evidence.'
Add-Check (
    (ConvertTo-PitCrewRepositoryIdentity `
        'https://github.com/example/project.git/') -eq 'example/project'
) 'Repository canonicalization did not remove the accepted .git suffix.'
Add-Check (
    Test-PitCrewLiteralTextFilter `
        -Value 'test [ubuntu]' `
        -Filters @('test [ubuntu]')
) 'A literal matrix-job filter did not match itself.'
Add-Check (-not (
        Test-PitCrewLiteralTextFilter `
            -Value 'test ubuntu' `
            -Filters @('test *')
    )) 'A literal job filter was interpreted as a wildcard.'
$selectedStepMetadata = @(
    Select-PitCrewGitHubStepMetadata `
        -Steps @(
            [PSCustomObject]@{
                number = 3
                name = 'Run fixed [contracts]'
                started_at = '2026-08-01T10:00:00Z'
                completed_at = '2026-08-01T10:00:05Z'
                status = 'completed'
                conclusion = 'success'
            },
            [PSCustomObject]@{
                number = 4
                name = 'Other step'
                started_at = '2026-08-01T10:00:05Z'
                completed_at = '2026-08-01T10:00:06Z'
                status = 'completed'
                conclusion = 'success'
            }
        ) `
        -Filters @('Run fixed [contracts]')
)
Add-Check (
    $selectedStepMetadata.Count -eq 1 -and
    $selectedStepMetadata[0].number -eq 3 -and
    $selectedStepMetadata[0].name -eq 'Run fixed [contracts]' -and
    $selectedStepMetadata[0].startedAt -is [DateTimeOffset] -and
    $selectedStepMetadata[0].completedAt -is [DateTimeOffset]
) 'GitHub step metadata selection was not literal, bounded, or UTC-normalized.'
Add-Check (
    @(
        Select-PitCrewGitHubStepMetadata `
            -Steps @($selectedStepMetadata) `
            -Filters @('Run fixed *')
    ).Count -eq 0
) 'A selected step filter was interpreted as a wildcard.'
Add-Check (
    @(
        Select-PitCrewGitHubStepMetadata `
            -Steps @($selectedStepMetadata) `
            -Filters @(' ')
    ).Count -eq 0
) 'A blank selected step filter expanded to every GitHub step.'

$json = $report | ConvertTo-Json -Depth 30
Add-Check ($json -notmatch 'runner-a-build') 'The JSON report exposed a raw runner name.'
Add-Check ($json -notmatch 'fixture-node-a') 'The JSON report exposed a node display name.'
Add-Check ($json -notmatch 'fixture-manager-instance') 'The JSON report exposed a manager instance identity.'
Add-Check ($json -notmatch 'registry.example.invalid') 'The JSON report exposed a worker image reference.'
Add-Check ($json -notmatch 'fixture update detail') 'The JSON report exposed a free-form update error.'
Add-Check ($json -notmatch '\.github/workflows') 'The JSON report exposed a workflow file path.'
Add-Check ($json -notmatch 'fixture-unselected-profile') 'The JSON report exposed a hardware source profile.'
Add-Check (
    $json -match '31b0f683149e60f42ad58db94b6a509e5f2d7b5c7deac939d9f4573b05260b38'
) 'The JSON report omitted the exact runner correlation hash.'
Add-Check (
    $json -match '"hostAdmissionWithheldUnits": 4'
) 'The JSON report omitted the retained host-admission fields.'

$duplicateFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
$duplicateFixture.jobs = @(
    @($duplicateFixture.jobs) +
        @($duplicateFixture.jobs[0]))
$duplicateFixture.histories.'11111111-1111-1111-1111-111111111111'.runnerAssignments = @(
    @($duplicateFixture.histories.'11111111-1111-1111-1111-111111111111'.runnerAssignments) +
        @($duplicateFixture.histories.'11111111-1111-1111-1111-111111111111'.runnerAssignments[0]))
$duplicateHistories = @{}
foreach ($property in $duplicateFixture.histories.PSObject.Properties) {
    $duplicateHistories[$property.Name] = $property.Value
}
$duplicateReport = New-PitCrewPerformanceReportModel `
    -Jobs @($duplicateFixture.jobs) `
    -Nodes @($duplicateFixture.nodes) `
    -Histories $duplicateHistories `
    -From ([DateTimeOffset]$duplicateFixture.from) `
    -To ([DateTimeOffset]$duplicateFixture.to) `
    -Repositories @('example/project', 'example/project')
Add-Check (
    @($duplicateReport.verifiedMeasurements.jobs).Count -eq 6
) 'Duplicate job input inflated report counts.'
Add-Check (
    ($duplicateReport.verifiedMeasurements.jobs |
        Where-Object jobId -eq '2001').mappingStatus -eq 'matched'
) 'Duplicate assignment input made an exact mapping ambiguous.'

$workflowIdentityFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
$otherWorkflowJob = $workflowIdentityFixture.jobs[0] |
    ConvertTo-Json -Depth 10 |
    ConvertFrom-Json -Depth 10
$otherWorkflowJob.workflowRunId = '1010'
$otherWorkflowJob.workflowId = '99'
$otherWorkflowJob.workflowPath = '.github/workflows/other.yml'
$otherWorkflowJob.jobId = '2010'
$otherWorkflowJob.startedAt = '2026-08-01T10:20:00Z'
$otherWorkflowJob.completedAt = '2026-08-01T10:30:00Z'
$workflowIdentityFixture.jobs = @(
    @($workflowIdentityFixture.jobs) +
        @($otherWorkflowJob))
$workflowIdentityHistories = @{}
foreach ($property in $workflowIdentityFixture.histories.PSObject.Properties) {
    $workflowIdentityHistories[$property.Name] = $property.Value
}
$workflowIdentityReport = New-PitCrewPerformanceReportModel `
    -Jobs @($workflowIdentityFixture.jobs) `
    -Nodes @($workflowIdentityFixture.nodes) `
    -Histories $workflowIdentityHistories `
    -From ([DateTimeOffset]$workflowIdentityFixture.from) `
    -To ([DateTimeOffset]$workflowIdentityFixture.to) `
    -Repositories @($workflowIdentityFixture.repositories)
Add-Check (
    @($workflowIdentityReport.verifiedMeasurements.jobNodeSummaries |
        Where-Object {
            $_.nodeKey -eq 'node-1' -and
            $_.jobName -eq 'build'
        }).Count -eq 2
) 'Different workflow definitions with the same display names were merged.'

$markdown = ConvertTo-PitCrewPerformanceMarkdown $report
foreach ($section in @(
        '## Verified measurements',
        '## Unavailable evidence',
        '## Hypotheses')) {
    Add-Check ($markdown -match [regex]::Escape($section)) "The Markdown report omitted '$section'."
}
Add-Check (
    $markdown -match 'Correlation is not causation'
) 'The report omitted the correlation caveat.'
Add-Check (
    $markdown -match 'one paired sample is not a host benchmark'
) 'The report omitted the benchmark caveat.'
Add-Check (
    $markdown -match 'Complete sanitized measurement payload'
) 'The Markdown report does not carry the equivalent sanitized measurements.'
Add-Check (
    $markdown -match 'Host-admission observations' -and
    $markdown -match 'host-admission-withheld'
) 'The Markdown report omitted host-admission interpretation.'
Add-Check (
    $markdown -match 'Selected job step measurements' -and
    $markdown -match 'Step duration summaries' -and
    $markdown -match 'Run fixed contracts'
) 'The Markdown report omitted selected step timing evidence.'
Add-Check (
    @($report.limitations |
        Where-Object {
            $_ -match 'abstract policy accounting' -and
            $_ -match 'universal workload weights'
        }).Count -eq 1 -and
    @($report.limitations |
        Where-Object {
            $_ -match 'do not prove GitHub queue delay'
        }).Count -eq 1
) 'The report omitted host-admission interpretation limits.'
$malicious = ConvertTo-PitCrewMarkdownText "bad`n<img src=https://example.invalid/a>` ````"
Add-Check (
    $malicious -notmatch '<img|https://example\.invalid/a>`'
) 'Repository-controlled metadata remained active in Markdown.'

$rate = Get-PitCrewDurationStatistics @(
    [PSCustomObject]@{
        durationSeconds = 10
        conclusion = 'cancelled'
    },
    [PSCustomObject]@{
        durationSeconds = $null
        conclusion = $null
    })
Add-Check (
    $rate.timedOutOrCancelledRate -eq 1 -and
    $rate.unfinishedCount -eq 1
) 'Cancellation rate included an unfinished job in its denominator.'

Add-Check (-not (
        Test-PitCrewUntimedJobRelevant `
            -Conclusion skipped `
            -RunStatus completed `
            -RunCreatedAt '2026-08-01T10:00:00Z' `
            -RunUpdatedAt '2026-08-01T10:01:00Z' `
            -From ([DateTimeOffset]$fixture.from) `
            -To ([DateTimeOffset]$fixture.to)
    )) 'A skipped untimed job was included in the report.'
Add-Check (-not (
        Test-PitCrewUntimedJobRelevant `
            -Conclusion failure `
            -RunStatus completed `
            -RunCreatedAt '2026-07-01T10:00:00Z' `
            -RunUpdatedAt '2026-07-01T10:01:00Z' `
            -From ([DateTimeOffset]$fixture.from) `
            -To ([DateTimeOffset]$fixture.to)
    )) 'An out-of-range untimed job was included in the report.'
Add-Check (
    Test-PitCrewUntimedJobRelevant `
        -Conclusion $null `
        -RunStatus in_progress `
        -RunCreatedAt '2026-07-01T10:00:00Z' `
        -RunUpdatedAt '2026-07-01T10:01:00Z' `
        -From ([DateTimeOffset]$fixture.from) `
        -To ([DateTimeOffset]$fixture.to)
) 'An active untimed job was discarded because its run update time was old.'
Add-Check (-not (
        Test-PitCrewWorkflowRunRelevant `
            -Status completed `
            -CreatedAt '2026-07-01T10:00:00Z' `
            -UpdatedAt '2026-07-01T10:30:00Z' `
            -From ([DateTimeOffset]$fixture.from) `
            -To ([DateTimeOffset]$fixture.to)
    )) 'A completed workflow run outside the range still required job pagination.'
Add-Check (
    Test-PitCrewWorkflowRunRelevant `
        -Status in_progress `
        -CreatedAt '2026-07-01T10:00:00Z' `
        -UpdatedAt '2026-07-01T10:30:00Z' `
        -From ([DateTimeOffset]$fixture.from) `
        -To ([DateTimeOffset]$fixture.to)
) 'An active workflow run was excluded only because its update time was old.'

$pageCalls = [Collections.Generic.List[string]]::new()
$paged = Invoke-PitCrewPagedFleetRequest -Limit 2 -Request {
    param($afterNodeId, $limit)
    $pageCalls.Add("$afterNodeId|$limit")
    if ($null -eq $afterNodeId) {
        return [PSCustomObject]@{
            nodes = @(
                [PSCustomObject]@{ nodeId = 'one' },
                [PSCustomObject]@{ nodeId = 'two' })
            nextAfterNodeId = 'two'
        }
    }
    return [PSCustomObject]@{
        nodes = @([PSCustomObject]@{ nodeId = 'three' })
        nextAfterNodeId = $null
    }
}
Add-Check ($paged.Count -eq 3) 'Fleet pagination did not return every page.'
Add-Check (
    ($pageCalls -join ',') -eq '|2,two|2'
) 'Fleet pagination did not propagate the exact cursor and bound.'

$partitionCalls = 0
$partitionedRuns = Get-PitCrewPartitionedWorkflowRuns `
    -From ([DateTimeOffset]'2026-08-01T00:00:00Z') `
    -To ([DateTimeOffset]'2026-08-02T00:00:00Z') `
    -Request {
        param($partitionStart, $partitionEnd)
        $script:partitionCalls++
        if (($partitionEnd - $partitionStart).TotalHours -gt 12) {
            return [PSCustomObject]@{ TotalCount = 1000; Runs = @() }
        }
        $first = [PSCustomObject]@{
            id = 1
            created_at = $partitionStart.ToString('O')
        }
        $second = [PSCustomObject]@{
            id = 2
            created_at = $partitionEnd.ToString('O')
        }
        return [PSCustomObject]@{
            TotalCount = 2
            Runs = @($first, $second)
        }
    }
Add-Check ($partitionCalls -eq 3) 'Workflow-run search did not split a capped partition.'
Add-Check ($partitionedRuns.Count -eq 2) 'Workflow-run partition results were not deduplicated.'

$incompleteFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
$incompleteFixture.histories.'11111111-1111-1111-1111-111111111111'.runnerAssignmentsTruncated = $true
$incompleteHistories = @{}
foreach ($property in $incompleteFixture.histories.PSObject.Properties) {
    $incompleteHistories[$property.Name] = $property.Value
}
$incompleteReport = New-PitCrewPerformanceReportModel `
    -Jobs @($incompleteFixture.jobs) `
    -Nodes @($incompleteFixture.nodes) `
    -Histories $incompleteHistories `
    -From ([DateTimeOffset]$incompleteFixture.from) `
    -To ([DateTimeOffset]$incompleteFixture.to) `
    -Repositories @($incompleteFixture.repositories)
Add-Check (
    ($incompleteReport.verifiedMeasurements.jobs |
        Where-Object jobId -eq '2001').mappingStatus -eq 'incomplete'
) 'Truncated assignment history still produced a verified exact mapping.'
Add-Check (
    @($incompleteReport.hypotheses |
        Where-Object hypothesis -match 'Cross-profile').Count -eq 0
) 'Assignment-incomplete evidence still produced a contention hypothesis.'

$otherNodeIncompleteFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
$otherNodeIncompleteFixture.histories.'22222222-2222-2222-2222-222222222222'.runnerAssignmentsTruncated = $true
$otherNodeIncompleteHistories = @{}
foreach ($property in $otherNodeIncompleteFixture.histories.PSObject.Properties) {
    $otherNodeIncompleteHistories[$property.Name] = $property.Value
}
$otherNodeIncompleteReport = New-PitCrewPerformanceReportModel `
    -Jobs @($otherNodeIncompleteFixture.jobs) `
    -Nodes @($otherNodeIncompleteFixture.nodes) `
    -Histories $otherNodeIncompleteHistories `
    -From ([DateTimeOffset]$otherNodeIncompleteFixture.from) `
    -To ([DateTimeOffset]$otherNodeIncompleteFixture.to) `
    -Repositories @($otherNodeIncompleteFixture.repositories)
Add-Check (
    ($otherNodeIncompleteReport.verifiedMeasurements.jobs |
        Where-Object jobId -eq '2001').mappingStatus -eq 'incomplete'
) 'Assignment loss on another selected node still permitted a verified mapping.'

$postBoundaryRetentionFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
foreach ($profile in @(
        $postBoundaryRetentionFixture.histories.
            '11111111-1111-1111-1111-111111111111'.profiles[0],
        $postBoundaryRetentionFixture.histories.
            '22222222-2222-2222-2222-222222222222'.profiles[0])) {
    $profile.retention.droppedRunnerAssignments = 10
    $profile.retention |
        Add-Member `
            -NotePropertyName earliestRetainedRunnerAssignment `
            -NotePropertyValue '2026-08-01T08:30:00Z' `
            -Force
}
$postBoundaryRetentionHistories = @{}
foreach ($property in $postBoundaryRetentionFixture.histories.PSObject.Properties) {
    $postBoundaryRetentionHistories[$property.Name] = $property.Value
}
$postBoundaryRetentionReport = New-PitCrewPerformanceReportModel `
    -Jobs @($postBoundaryRetentionFixture.jobs) `
    -Nodes @($postBoundaryRetentionFixture.nodes) `
    -Histories $postBoundaryRetentionHistories `
    -From ([DateTimeOffset]$postBoundaryRetentionFixture.from) `
    -To ([DateTimeOffset]$postBoundaryRetentionFixture.to) `
    -Repositories @($postBoundaryRetentionFixture.repositories)
Add-Check (
    ($postBoundaryRetentionReport.verifiedMeasurements.jobs |
        Where-Object jobId -eq '2001').mappingStatus -eq 'matched'
) 'Assignment deletions known to predate the range invalidated a unique mapping.'

$overlappingRetentionFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
$overlappingRetention =
    $overlappingRetentionFixture.histories.
        '11111111-1111-1111-1111-111111111111'.profiles[0].retention
$overlappingRetention.droppedRunnerAssignments = 10
$overlappingRetention |
    Add-Member `
        -NotePropertyName earliestRetainedRunnerAssignment `
        -NotePropertyValue '2026-08-01T09:30:00Z' `
        -Force
$overlappingRetentionHistories = @{}
foreach ($property in $overlappingRetentionFixture.histories.PSObject.Properties) {
    $overlappingRetentionHistories[$property.Name] = $property.Value
}
$overlappingRetentionReport = New-PitCrewPerformanceReportModel `
    -Jobs @($overlappingRetentionFixture.jobs) `
    -Nodes @($overlappingRetentionFixture.nodes) `
    -Histories $overlappingRetentionHistories `
    -From ([DateTimeOffset]$overlappingRetentionFixture.from) `
    -To ([DateTimeOffset]$overlappingRetentionFixture.to) `
    -Repositories @($overlappingRetentionFixture.repositories)
Add-Check (
    ($overlappingRetentionReport.verifiedMeasurements.jobs |
        Where-Object jobId -eq '2001').mappingStatus -eq 'incomplete'
) 'Assignment retention overlapping the range still produced a verified mapping.'

$unknownRetentionFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
$unknownRetentionFixture.histories.
    '22222222-2222-2222-2222-222222222222'.
    profiles[0].
    retention.
    droppedRunnerAssignments = 10
$unknownRetentionHistories = @{}
foreach ($property in $unknownRetentionFixture.histories.PSObject.Properties) {
    $unknownRetentionHistories[$property.Name] = $property.Value
}
$unknownRetentionReport = New-PitCrewPerformanceReportModel `
    -Jobs @($unknownRetentionFixture.jobs) `
    -Nodes @($unknownRetentionFixture.nodes) `
    -Histories $unknownRetentionHistories `
    -From ([DateTimeOffset]$unknownRetentionFixture.from) `
    -To ([DateTimeOffset]$unknownRetentionFixture.to) `
    -Repositories @($unknownRetentionFixture.repositories)
Add-Check (
    ($unknownRetentionReport.verifiedMeasurements.jobs |
        Where-Object jobId -eq '2001').mappingStatus -eq 'incomplete'
) 'Unknown assignment retention boundaries did not remain fail-closed.'

$missingProfileFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
$missingProfileFixture.histories.'11111111-1111-1111-1111-111111111111' |
    Add-Member `
        -NotePropertyName requestedProfilesUnavailable `
        -NotePropertyValue @('removed-profile') `
        -Force
$missingProfileHistories = @{}
foreach ($property in $missingProfileFixture.histories.PSObject.Properties) {
    $missingProfileHistories[$property.Name] = $property.Value
}
$missingProfileReport = New-PitCrewPerformanceReportModel `
    -Jobs @($missingProfileFixture.jobs) `
    -Nodes @($missingProfileFixture.nodes) `
    -Histories $missingProfileHistories `
    -From ([DateTimeOffset]$missingProfileFixture.from) `
    -To ([DateTimeOffset]$missingProfileFixture.to) `
    -Repositories @($missingProfileFixture.repositories)
Add-Check (
    @($missingProfileReport.unavailableEvidence |
        Where-Object {
            $_.kind -eq 'profile-history' -and
            $_.profileId -eq 'removed-profile'
        }).Count -eq 1
) 'A removed or unauthorized requested profile was silently omitted.'
Add-Check (
    ($missingProfileReport.verifiedMeasurements.jobs |
        Where-Object jobId -eq '2001').mappingStatus -eq 'incomplete'
) 'Missing requested profile history still permitted a verified mapping.'

$cadenceFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
$cadenceFixture.histories.'11111111-1111-1111-1111-111111111111'.profiles[0].samples = @(
    [PSCustomObject]@{
        observedAt = '2026-08-01T09:00:10Z'
        telemetryStatus = 'available'
    })
$cadenceHistories = @{}
foreach ($property in $cadenceFixture.histories.PSObject.Properties) {
    $cadenceHistories[$property.Name] = $property.Value
}
$cadenceReport = New-PitCrewPerformanceReportModel `
    -Jobs @($cadenceFixture.jobs) `
    -Nodes @($cadenceFixture.nodes) `
    -Histories $cadenceHistories `
    -From ([DateTimeOffset]'2026-08-01T09:00:00Z') `
    -To ([DateTimeOffset]'2026-08-01T09:00:20Z') `
    -Repositories @($cadenceFixture.repositories) `
    -ExpectedCadenceSeconds 15
Add-Check (
    @($cadenceReport.unavailableEvidence |
        Where-Object {
            $_.kind -eq 'telemetry-coverage' -and
            $_.nodeKey -eq 'node-1' -and
            $_.profileId -eq 'build'
        }).Count -eq 0
) 'Cadence-covered telemetry was reported as incomplete.'

$singleNodeJobs = @(
    $fixture.jobs |
        Where-Object runnerName -ne 'runner-b-build')
$singleNodeReport = New-PitCrewPerformanceReportModel `
    -Jobs $singleNodeJobs `
    -Nodes @($fixture.nodes) `
    -Histories $histories `
    -From ([DateTimeOffset]$fixture.from) `
    -To ([DateTimeOffset]$fixture.to) `
    -Repositories @($fixture.repositories)
Add-Check (
    @($singleNodeReport.hypotheses |
        Where-Object hypothesis -match 'hardware').Count -eq 0
) 'Hardware differences produced a hypothesis without cross-node like-for-like jobs.'

$equalDurationFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
($equalDurationFixture.jobs |
    Where-Object jobId -eq '2005').completedAt =
    '2026-08-01T10:20:00Z'
$equalDurationHistories = @{}
foreach ($property in $equalDurationFixture.histories.PSObject.Properties) {
    $equalDurationHistories[$property.Name] = $property.Value
}
$equalDurationReport = New-PitCrewPerformanceReportModel `
    -Jobs @($equalDurationFixture.jobs) `
    -Nodes @($equalDurationFixture.nodes) `
    -Histories $equalDurationHistories `
    -From ([DateTimeOffset]$equalDurationFixture.from) `
    -To ([DateTimeOffset]$equalDurationFixture.to) `
    -Repositories @($equalDurationFixture.repositories)
Add-Check (
    @($equalDurationReport.hypotheses |
        Where-Object hypothesis -match 'hardware').Count -eq 0
) 'Different hardware produced a hypothesis without a duration difference.'

$hardwareIncompleteFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
$hardwareIncompleteFixture.histories.'11111111-1111-1111-1111-111111111111' |
    Add-Member `
        -NotePropertyName hardwareRevisionsTruncated `
        -NotePropertyValue $true `
        -Force
$hardwareIncompleteHistories = @{}
foreach ($property in $hardwareIncompleteFixture.histories.PSObject.Properties) {
    $hardwareIncompleteHistories[$property.Name] = $property.Value
}
$hardwareIncompleteReport = New-PitCrewPerformanceReportModel `
    -Jobs @($hardwareIncompleteFixture.jobs) `
    -Nodes @($hardwareIncompleteFixture.nodes) `
    -Histories $hardwareIncompleteHistories `
    -From ([DateTimeOffset]$hardwareIncompleteFixture.from) `
    -To ([DateTimeOffset]$hardwareIncompleteFixture.to) `
    -Repositories @($hardwareIncompleteFixture.repositories)
Add-Check (
    @($hardwareIncompleteReport.verifiedMeasurements.jobs |
        Where-Object {
            $_.nodeKey -eq 'node-1' -and
            $null -ne $_.hardwareInventoryHash
        }).Count -eq 0
) 'Hardware-truncated history still produced verified job hardware hashes.'
Add-Check (
    @($hardwareIncompleteReport.hypotheses |
        Where-Object hypothesis -match 'hardware').Count -eq 0
) 'Hardware-truncated history still produced a hardware hypothesis.'

$staleHardwareFixture = $fixture |
    ConvertTo-Json -Depth 30 |
    ConvertFrom-Json -Depth 30
$staleHardwareFixture.nodes[1].hardware.status = 'stale'
$staleHardwareHistories = @{}
foreach ($property in $staleHardwareFixture.histories.PSObject.Properties) {
    $staleHardwareHistories[$property.Name] = $property.Value
}
$staleHardwareReport = New-PitCrewPerformanceReportModel `
    -Jobs @($staleHardwareFixture.jobs) `
    -Nodes @($staleHardwareFixture.nodes) `
    -Histories $staleHardwareHistories `
    -From ([DateTimeOffset]$staleHardwareFixture.from) `
    -To ([DateTimeOffset]$staleHardwareFixture.to) `
    -Repositories @($staleHardwareFixture.repositories)
Add-Check (
    ($staleHardwareReport.verifiedMeasurements.jobs |
        Where-Object jobId -eq '2005').hardwareInventoryHash -eq $null
) 'Stale current hardware was treated as verified job hardware.'
Add-Check (
    @($staleHardwareReport.hypotheses |
        Where-Object hypothesis -match 'hardware').Count -eq 0
) 'Stale current hardware produced a hardware hypothesis.'

$boundaryJob = $fixture.jobs[0] |
    ConvertTo-Json -Depth 10 |
    ConvertFrom-Json -Depth 10
$boundaryJob.jobId = 'boundary'
$boundaryJob.startedAt = '2026-08-01T08:00:00Z'
$boundaryJob.completedAt = '2026-08-01T10:00:00Z'
$boundaryReport = New-PitCrewPerformanceReportModel `
    -Jobs @($boundaryJob) `
    -Nodes @($fixture.nodes) `
    -Histories $histories `
    -From ([DateTimeOffset]'2026-08-01T09:00:00Z') `
    -To ([DateTimeOffset]'2026-08-01T11:00:00Z') `
    -Repositories @($fixture.repositories)
Add-Check (
    ($boundaryReport.verifiedMeasurements.jobs |
        Where-Object jobId -eq 'boundary').crossProfileOverlapSeconds -eq 0
) 'Boundary-crossing overlap was not clipped to the requested range.'

$outputDirectory = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "pitcrew-performance-report-$([Guid]::NewGuid().ToString('n'))"
try {
    $written = Write-PitCrewPerformanceReport `
        -Report $report `
        -OutputDirectory $outputDirectory
    Add-Check (
        Test-Path -LiteralPath $written.JsonPath -PathType Leaf
    ) 'The JSON report file was not written.'
    Add-Check (
        Test-Path -LiteralPath $written.MarkdownPath -PathType Leaf
    ) 'The Markdown report file was not written.'
    $writtenJson = Get-Content `
        -LiteralPath $written.JsonPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 30
    Add-Check (
        [int]$writtenJson.schemaVersion -eq 2 -and
        @($writtenJson.verifiedMeasurements.jobs).Count -eq $jobs.Count -and
        @($writtenJson.verifiedMeasurements.steps).Count -eq $steps.Count
    ) 'The written JSON does not match the in-memory report.'
} finally {
    if (Test-Path -LiteralPath $outputDirectory) {
        Remove-Item -LiteralPath $outputDirectory -Recurse -Force
    }
}

$ciOutputDirectory = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "pitcrew-ci-performance-report-$([Guid]::NewGuid().ToString('n'))"
$global:PitCrewTestCiGhCalls = [Collections.Generic.List[string]]::new()
$global:PitCrewTestCiDashboardCalls =
    [Collections.Generic.List[string]]::new()
$global:PitCrewTestCiDashboardMode = 'success'
$global:PitCrewTestCiCapabilitiesAttempts = 0
$global:PitCrewTestCiSleepCalls =
    [Collections.Generic.List[string]]::new()
$global:PitCrewTestCiFixture = $fixture
$previousCredential = [Environment]::GetEnvironmentVariable(
    'PITCREW_DIAGNOSTICS_CREDENTIAL')
function gh {
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$CliArguments
    )

    $call = $CliArguments -join ' '
    $global:PitCrewTestCiGhCalls.Add($call)
    $global:LASTEXITCODE = 0
    if ($call -match
        '^api -X GET repos/example/project/actions/runs/1001$') {
        return [PSCustomObject][ordered]@{
            id = 1001
            workflow_id = 10
            name = 'build'
            status = 'completed'
            run_attempt = 2
            created_at = '2026-08-01T09:59:00Z'
            updated_at = '2026-08-01T10:11:00Z'
        } | ConvertTo-Json -Depth 10 -Compress
    }
    if ($call -match
        'repos/example/project/actions/runs/1001/attempts/1/jobs') {
        $fixtureJob = $global:PitCrewTestCiFixture.jobs[0]
        $apiSteps = @(
            foreach ($step in @($fixtureJob.steps)) {
                [PSCustomObject][ordered]@{
                    number = $step.number
                    name = $step.name
                    started_at = $step.startedAt
                    completed_at = $step.completedAt
                    status = $step.status
                    conclusion = $step.conclusion
                }
            })
        return @(
            [PSCustomObject][ordered]@{
                jobs = @(
                    [PSCustomObject][ordered]@{
                        id = [long]$fixtureJob.jobId
                        name = $fixtureJob.jobName
                        runner_name = $fixtureJob.runnerName
                        labels = @($fixtureJob.labels)
                        started_at = $fixtureJob.startedAt
                        completed_at = $fixtureJob.completedAt
                        status = $fixtureJob.status
                        conclusion = $fixtureJob.conclusion
                        run_attempt = 1
                        steps = $apiSteps
                    })
            }) | ConvertTo-Json -Depth 20 -Compress
    }
    throw "Unexpected GitHub CLI call: $call"
}
function New-PitCrewTestHttpResponseException {
    param(
        [Parameter(Mandatory)][Net.HttpStatusCode]$StatusCode,
        [int]$RetryAfterSeconds = 0
    )

    $response = [Net.Http.HttpResponseMessage]::new($StatusCode)
    if ($RetryAfterSeconds -gt 0) {
        $response.Headers.RetryAfter =
            [Net.Http.Headers.RetryConditionHeaderValue]::new(
                [TimeSpan]::FromSeconds($RetryAfterSeconds))
    }
    return [Microsoft.PowerShell.Commands.HttpResponseException]::new(
        "Fixture HTTP status $([int]$StatusCode).",
        $response)
}
function Start-Sleep {
    param(
        [int]$Milliseconds,
        [int]$Seconds
    )

    if ($PSBoundParameters.ContainsKey('Milliseconds')) {
        $global:PitCrewTestCiSleepCalls.Add("milliseconds:$Milliseconds")
    }
    if ($PSBoundParameters.ContainsKey('Seconds')) {
        $global:PitCrewTestCiSleepCalls.Add("seconds:$Seconds")
    }
}
function Invoke-RestMethod {
    param(
        [string]$Method,
        [object]$Uri,
        [hashtable]$Headers
    )

    $uriText = [string]$Uri
    $global:PitCrewTestCiDashboardCalls.Add($uriText)
    if ($uriText -match '/fleet/history/capabilities$') {
        $global:PitCrewTestCiCapabilitiesAttempts++
        if ($global:PitCrewTestCiDashboardMode -eq 'transient-once' -and
            $global:PitCrewTestCiCapabilitiesAttempts -eq 1) {
            throw (
                New-PitCrewTestHttpResponseException `
                    -StatusCode BadGateway)
        }
        if ($global:PitCrewTestCiDashboardMode -eq 'transient-always') {
            throw (
                New-PitCrewTestHttpResponseException `
                    -StatusCode ServiceUnavailable)
        }
        if ($global:PitCrewTestCiDashboardMode -eq 'retry-after-once' -and
            $global:PitCrewTestCiCapabilitiesAttempts -eq 1) {
            throw (
                New-PitCrewTestHttpResponseException `
                    -StatusCode TooManyRequests `
                    -RetryAfterSeconds 7)
        }
        if ($global:PitCrewTestCiDashboardMode -eq 'permanent') {
            throw (
                New-PitCrewTestHttpResponseException `
                    -StatusCode Unauthorized)
        }
        return [PSCustomObject][ordered]@{
            maximumRangeHours = 24
            maximumPoints = 1000
            maximumEvents = 1000
            maximumDiagnostics = 1000
            expectedRawCadenceSeconds = 15
        }
    }
    if ($uriText -match '/fleet/nodes\?') {
        return [PSCustomObject][ordered]@{
            nodes = @($global:PitCrewTestCiFixture.nodes)
            nextAfterNodeId = $null
        }
    }
    if ($uriText -match '/fleet/nodes/([^/]+)/history\?') {
        $nodeId = [Uri]::UnescapeDataString($Matches[1])
        return $global:PitCrewTestCiFixture.histories.PSObject.Properties[$nodeId].Value
    }
    throw "Unexpected Dashboard request: $uriText"
}
try {
    [Environment]::SetEnvironmentVariable(
        'PITCREW_DIAGNOSTICS_CREDENTIAL',
        'fixture-credential')
    & $commandPath `
        -DashboardUrl https://dashboard.example `
        -TenantId example `
        -Repository example/project `
        -RunId 1001 `
        -RunAttempt 1 `
        -Step 'Run fixed contracts' `
        -OutputDirectory $ciOutputDirectory

    $ciJsonPath = Join-Path `
        $ciOutputDirectory `
        'pitcrew-performance-report.json'
    $ciMarkdownPath = Join-Path `
        $ciOutputDirectory `
        'pitcrew-performance-report.md'
    Add-Check (
        (Test-Path -LiteralPath $ciJsonPath -PathType Leaf) -and
        (Test-Path -LiteralPath $ciMarkdownPath -PathType Leaf)
    ) 'Exact-run mode did not write stable report filenames.'
    $ciReport = Get-Content `
        -LiteralPath $ciJsonPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 30
    Add-Check (
        [int]$ciReport.schemaVersion -eq 3 -and
        $ciReport.selection.mode -eq 'workflow-run-attempt' -and
        $ciReport.selection.workflowRun.repository -eq 'example/project' -and
        $ciReport.selection.workflowRun.runId -eq '1001' -and
        [int]$ciReport.selection.workflowRun.attempt -eq 1
    ) 'Exact-run mode did not write the versioned workflow-run selection contract.'
    Add-Check (
        $ciReport.selection.workflowRun.jobInterval.from -eq
            '2026-08-01T10:00:00.0000000+00:00' -and
        $ciReport.selection.workflowRun.jobInterval.to -eq
            '2026-08-01T10:10:00.0000000+00:00' -and
        $ciReport.range.from -eq '2026-08-01T09:59:30.0000000+00:00' -and
        $ciReport.range.to -eq '2026-08-01T10:10:30.0000000+00:00'
    ) 'Exact-run mode did not derive the bounded padded Dashboard interval.'
    Add-Check (
        @($ciReport.verifiedMeasurements.jobs).Count -eq 1 -and
        $ciReport.verifiedMeasurements.jobs[0].jobId -eq '2001' -and
        @($ciReport.verifiedMeasurements.steps).Count -eq 1
    ) 'Exact-run mode selected jobs outside the requested run attempt.'
    $ciJson = Get-Content -LiteralPath $ciJsonPath -Raw -Encoding UTF8
    $ciMarkdown = Get-Content `
        -LiteralPath $ciMarkdownPath `
        -Raw `
        -Encoding UTF8
    Add-Check (
        $ciJson -notmatch 'runner-a-build|fixture-node-a|fixture-credential'
    ) 'Exact-run output exposed a raw runner, node display name, or credential.'
    Add-Check (
        $ciMarkdown -match
            'Selection: `example/project` run `1001` attempt `1`'
    ) 'Exact-run Markdown omitted its sanitized selection identity.'
    Add-Check (
        $global:PitCrewTestCiGhCalls.Count -eq 2 -and
        $global:PitCrewTestCiGhCalls[0] -match
            '^api -X GET repos/example/project/actions/runs/1001$' -and
        $global:PitCrewTestCiGhCalls[1] -match
            'actions/runs/1001/attempts/1/jobs' -and
        @($global:PitCrewTestCiGhCalls | Where-Object {
                $_ -match 'actions/runs(?:\s|$).*created='
            }).Count -eq 0
    ) 'Exact-run mode scanned unrelated workflow runs or selected the wrong attempt.'

    $dashboardCallsBeforeInvalidAttempt =
        $global:PitCrewTestCiDashboardCalls.Count
    $invalidAttemptRejected = $false
    try {
        & $commandPath `
            -DashboardUrl https://dashboard.example `
            -TenantId example `
            -Repository example/project `
            -RunId 1001 `
            -RunAttempt 3 `
            -OutputDirectory "$ciOutputDirectory-invalid"
    } catch {
        $invalidAttemptRejected = (
            $_.Exception.Message -match
                'has only 2 attempt\(s\); attempt 3 is unavailable'
        )
    }
    Add-Check (
        $invalidAttemptRejected -and
        $global:PitCrewTestCiDashboardCalls.Count -eq
            $dashboardCallsBeforeInvalidAttempt
    ) 'Invalid exact attempts did not fail before Dashboard history collection.'

    $transientOutputDirectory = "$ciOutputDirectory-transient"
    $global:PitCrewTestCiDashboardMode = 'transient-once'
    $global:PitCrewTestCiCapabilitiesAttempts = 0
    $global:PitCrewTestCiSleepCalls.Clear()
    & $commandPath `
        -DashboardUrl https://dashboard.example `
        -TenantId example `
        -Repository example/project `
        -RunId 1001 `
        -RunAttempt 1 `
        -OutputDirectory $transientOutputDirectory
    $retrySleeps = @(
        $global:PitCrewTestCiSleepCalls |
            Where-Object { $_.StartsWith('seconds:', [StringComparison]::Ordinal) }
    )
    Add-Check (
        $global:PitCrewTestCiCapabilitiesAttempts -eq 2 -and
        $retrySleeps.Count -eq 1 -and
        $retrySleeps[0] -eq 'seconds:1' -and
        (Test-Path `
            -LiteralPath (
                Join-Path `
                    $transientOutputDirectory `
                    'pitcrew-performance-report.json') `
            -PathType Leaf)
    ) 'A transient Dashboard failure did not recover with bounded backoff.'

    $retryAfterOutputDirectory = "$ciOutputDirectory-retry-after"
    $global:PitCrewTestCiDashboardMode = 'retry-after-once'
    $global:PitCrewTestCiCapabilitiesAttempts = 0
    $global:PitCrewTestCiSleepCalls.Clear()
    & $commandPath `
        -DashboardUrl https://dashboard.example `
        -TenantId example `
        -Repository example/project `
        -RunId 1001 `
        -RunAttempt 1 `
        -OutputDirectory $retryAfterOutputDirectory
    $retrySleeps = @(
        $global:PitCrewTestCiSleepCalls |
            Where-Object { $_.StartsWith('seconds:', [StringComparison]::Ordinal) }
    )
    Add-Check (
        $global:PitCrewTestCiCapabilitiesAttempts -eq 2 -and
        $retrySleeps.Count -eq 1 -and
        $retrySleeps[0] -eq 'seconds:7'
    ) 'Dashboard retry did not honor the bounded Retry-After duration.'

    $exhaustedOutputDirectory = "$ciOutputDirectory-exhausted"
    $global:PitCrewTestCiDashboardMode = 'transient-always'
    $global:PitCrewTestCiCapabilitiesAttempts = 0
    $global:PitCrewTestCiSleepCalls.Clear()
    $exhaustedStatusCode = 0
    try {
        & $commandPath `
            -DashboardUrl https://dashboard.example `
            -TenantId example `
            -Repository example/project `
            -RunId 1001 `
            -RunAttempt 1 `
            -OutputDirectory $exhaustedOutputDirectory
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        $exhaustedStatusCode = [int]$_.Exception.Response.StatusCode
    }
    $retrySleeps = @(
        $global:PitCrewTestCiSleepCalls |
            Where-Object { $_.StartsWith('seconds:', [StringComparison]::Ordinal) }
    )
    Add-Check (
        $global:PitCrewTestCiCapabilitiesAttempts -eq 3 -and
        $exhaustedStatusCode -eq 503 -and
        $retrySleeps.Count -eq 2 -and
        $retrySleeps[0] -eq 'seconds:1' -and
        $retrySleeps[1] -eq 'seconds:2'
    ) 'Transient Dashboard exhaustion did not preserve the final response.'

    $permanentOutputDirectory = "$ciOutputDirectory-permanent"
    $global:PitCrewTestCiDashboardMode = 'permanent'
    $global:PitCrewTestCiCapabilitiesAttempts = 0
    $global:PitCrewTestCiSleepCalls.Clear()
    $permanentStatusCode = 0
    try {
        & $commandPath `
            -DashboardUrl https://dashboard.example `
            -TenantId example `
            -Repository example/project `
            -RunId 1001 `
            -RunAttempt 1 `
            -OutputDirectory $permanentOutputDirectory
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        $permanentStatusCode = [int]$_.Exception.Response.StatusCode
    }
    Add-Check (
        $global:PitCrewTestCiCapabilitiesAttempts -eq 1 -and
        $permanentStatusCode -eq 401 -and
        @(
            $global:PitCrewTestCiSleepCalls |
                Where-Object {
                    $_.StartsWith(
                        'seconds:',
                        [StringComparison]::Ordinal)
                }
        ).Count -eq 0
    ) 'A permanent Dashboard response did not fail immediately.'
} finally {
    [Environment]::SetEnvironmentVariable(
        'PITCREW_DIAGNOSTICS_CREDENTIAL',
        $previousCredential)
    Remove-Item Function:\gh -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Sleep -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-RestMethod -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\New-PitCrewTestHttpResponseException `
        -Force `
        -ErrorAction SilentlyContinue
    Remove-Variable `
        -Name PitCrewTestCiGhCalls `
        -Scope Global `
        -Force `
        -ErrorAction SilentlyContinue
    Remove-Variable `
        -Name PitCrewTestCiDashboardCalls `
        -Scope Global `
        -Force `
        -ErrorAction SilentlyContinue
    Remove-Variable `
        -Name PitCrewTestCiDashboardMode `
        -Scope Global `
        -Force `
        -ErrorAction SilentlyContinue
    Remove-Variable `
        -Name PitCrewTestCiCapabilitiesAttempts `
        -Scope Global `
        -Force `
        -ErrorAction SilentlyContinue
    Remove-Variable `
        -Name PitCrewTestCiSleepCalls `
        -Scope Global `
        -Force `
        -ErrorAction SilentlyContinue
    Remove-Variable `
        -Name PitCrewTestCiFixture `
        -Scope Global `
        -Force `
        -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $ciOutputDirectory) {
        Remove-Item -LiteralPath $ciOutputDirectory -Recurse -Force
    }
    if (Test-Path -LiteralPath "$ciOutputDirectory-invalid") {
        Remove-Item `
            -LiteralPath "$ciOutputDirectory-invalid" `
            -Recurse `
            -Force
    }
    foreach ($suffix in @(
            'transient',
            'retry-after',
            'exhausted',
            'permanent')) {
        $retryOutputDirectory = "$ciOutputDirectory-$suffix"
        if (Test-Path -LiteralPath $retryOutputDirectory) {
            Remove-Item `
                -LiteralPath $retryOutputDirectory `
                -Recurse `
                -Force
        }
    }
}

if ($errors.Count -gt 0) {
    foreach ($errorMessage in $errors) {
        Write-Host "ERROR: $errorMessage" -ForegroundColor Red
    }
    throw "Performance report validation failed with $($errors.Count) error(s)."
}

Write-Host "Performance report validation passed: $checks assertions." -ForegroundColor Green
