#Requires -Version 7.0
<#
.SYNOPSIS
Public command: summarize bounded, normalized CI evidence without network access.
.DESCRIPTION
Validates ci-evidence.schema.json plus chronology, identities, and attempt coverage.
All supplied timestamps must lie in the inclusive observation window; crossing
records are rejected, not clipped. Missing or unfinished durations remain unknown.
Runner occupancy sums completed measured jobs. Elapsed span uses observed timestamps
only, including run creation, and never extends unfinished jobs to capture time.
Minutes are rounded to nine decimal places. Collection completeness is a declaration,
not independently verified evidence. No paths, job names, or raw logs are returned.
.PARAMETER InputPath
Local UTF-8 JSON file, at most 2 MiB, with at most 100 attempts and 1000 total jobs.
.PARAMETER Json
Emit compact JSON instead of a PSCustomObject.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $InputPath,

    [switch] $Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ReflectionJson.Functions.ps1')

function ConvertTo-EvidenceTimestamp {
    <#
    .SYNOPSIS
    Parse a calendar-valid, explicitly UTC evidence timestamp without culture coercion.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Value)

    $timestamp = [DateTimeOffset]::MinValue
    $formats = [string[]] @("yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'")
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTimeOffset]::TryParseExact($Value, $formats, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref] $timestamp)) {
        throw 'Invalid CI evidence: timestamp must be a valid UTC date with explicit Z timezone.'
    }
    return $timestamp
}

$schemaPath = Join-Path $PSScriptRoot '..' 'reference' 'ci-evidence.schema.json'
$inputDocument = Read-ReflectionJson -Path $InputPath -SchemaPath $schemaPath `
    -SchemaLabel 'ci-evidence' -MaxBytes 2MB
$evidence = $inputDocument.Value

$from = ConvertTo-EvidenceTimestamp -Value $evidence.window.from
$to = ConvertTo-EvidenceTimestamp -Value $evidence.window.to
$capture = ConvertTo-EvidenceTimestamp -Value $evidence.capturedAt
if ($from -ge $to -or ($to - $from).TotalDays -gt 366) {
    throw 'Invalid CI evidence: window must increase and span at most 366 days.'
}
if ($capture -lt $to) { throw 'Invalid CI evidence: capturedAt precedes window.to.' }

$runKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$jobKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$runsById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$normalizedRuns = [Collections.Generic.List[object]]::new()
$timestamps = [Collections.Generic.List[DateTimeOffset]]::new()
$jobCount = 0
foreach ($run in $evidence.runs) {
    $attempt = [int]$run.attempt
    $key = '{0}:{1}' -f $run.id, $attempt
    if (-not $runKeys.Add($key)) { throw 'Invalid CI evidence: duplicate run+attempt identity.' }
    $created = ConvertTo-EvidenceTimestamp -Value $run.createdAt
    if ($created -lt $from -or $created -gt $to) {
        throw 'Invalid CI evidence: timestamp outside window; crossing records must be excluded or the window widened.'
    }
    $timestamps.Add($created)
    if (-not $runsById.ContainsKey($run.id)) {
        $runsById.Add($run.id, [Collections.Generic.List[object]]::new())
    }
    $jobs = [Collections.Generic.List[object]]::new()
    foreach ($job in $run.jobs) {
        $jobCount++
        if ($jobCount -gt 1000) { throw 'Invalid CI evidence: more than 1000 total jobs.' }
        if (-not $jobKeys.Add($job.id)) { throw 'Invalid CI evidence: duplicate job identity.' }
        if (($job.status -eq 'completed') -ne ($null -ne $job.conclusion)) {
            throw 'Invalid CI evidence: only completed jobs must have a non-null conclusion.'
        }
        if (($job.status -ne 'completed' -and $null -ne $job.completedAt) -or
            ($job.status -eq 'queued' -and $null -ne $job.startedAt)) {
            throw 'Invalid CI evidence: job status contradicts timestamps.'
        }
        $dates = @{}
        $previous = $created
        foreach ($field in @('createdAt', 'startedAt', 'completedAt')) {
            $date = $null
            if ($null -ne $job[$field]) {
                $date = ConvertTo-EvidenceTimestamp -Value $job[$field]
                if ($date -lt $from -or $date -gt $to) {
                    throw 'Invalid CI evidence: timestamp outside window; crossing records must be excluded or the window widened.'
                }
                if ($date -lt $previous) { throw 'Invalid CI evidence: reversed timestamp chronology.' }
                $previous = $date
                $timestamps.Add($date)
            }
            $dates[$field] = $date
        }
        $jobs.Add([pscustomobject]@{
            Name = $job.name
            Status = $job.status
            Conclusion = $job.conclusion
            Created = $dates.createdAt
            Started = $dates.startedAt
            Completed = $dates.completedAt
        })
    }
    $normalized = [pscustomobject]@{
        Id = $run.id
        Attempt = $attempt
        Sha = $run.headSha.ToLowerInvariant()
        Workflow = $run.workflow
        Created = $created
        Jobs = $jobs
    }
    $normalizedRuns.Add($normalized)
    $runsById[$run.id].Add($normalized)
}

$declaredComplete = $evidence.collection.attempts -ceq 'all' -and $evidence.collection.complete
foreach ($group in $runsById.Values) {
    $ordered = @($group | Sort-Object -Property Attempt)
    for ($index = 0; $index -lt $ordered.Count; $index++) {
        if ($ordered[$index].Sha -cne $ordered[0].Sha -or $ordered[$index].Workflow -cne $ordered[0].Workflow) {
            throw 'Invalid CI evidence: one run identity has inconsistent SHA or workflow.'
        }
        if ($index -gt 0 -and $ordered[$index].Created -lt $ordered[$index - 1].Created) {
            throw 'Invalid CI evidence: reversed attempt chronology.'
        }
        if ($declaredComplete -and $ordered[$index].Attempt -ne ($index + 1)) {
            throw 'Invalid CI evidence: all+complete requires contiguous attempts starting at 1.'
        }
    }
}

[decimal]$runnerTicks = 0
[decimal]$retryTicks = 0
[decimal]$preStartTicks = 0
$measured = 0
$completed = 0
$preStartMeasured = 0
foreach ($run in $normalizedRuns) {
    foreach ($job in $run.Jobs) {
        if ($job.Status -eq 'completed') { $completed++ }
        if ($job.Status -eq 'completed' -and $null -ne $job.Started -and $null -ne $job.Completed) {
            $ticks = ($job.Completed - $job.Started).Ticks
            $runnerTicks += $ticks
            if ($run.Attempt -gt 1) { $retryTicks += $ticks }
            $measured++
        }
        if ($null -ne $job.Created -and $null -ne $job.Started) {
            $preStartTicks += ($job.Started - $job.Created).Ticks
            $preStartMeasured++
        }
    }
}

$suspected = 0
foreach ($group in $runsById.Values) {
    $failures = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($run in @($group | Sort-Object -Property Attempt)) {
        foreach ($job in $run.Jobs) {
            if ($job.Conclusion -ceq 'success' -and $null -ne $job.Completed -and $failures.ContainsKey($job.Name)) {
                if ($job.Completed -gt $failures[$job.Name].Completed -and $run.Attempt -gt $failures[$job.Name].Attempt) {
                    $suspected++
                }
            }
        }
        foreach ($job in $run.Jobs) {
            if ($job.Conclusion -ceq 'failure' -and $null -ne $job.Completed) {
                if (-not $failures.ContainsKey($job.Name) -or $job.Completed -lt $failures[$job.Name].Completed) {
                    $failures[$job.Name] = [pscustomobject]@{ Completed = $job.Completed; Attempt = $run.Attempt }
                }
            }
        }
    }
}

$elapsed = $null
if ($timestamps.Count -gt 0) {
    $bounds = @($timestamps | Sort-Object)
    $elapsed = [decimal]($bounds[-1] - $bounds[0]).Ticks / 10000000
}
$cautions = [Collections.Generic.List[string]]::new()
$cautions.Add('All totals cover only supplied records; collection completeness is declared, not independently verified.')
$cautions.Add('Known-subset runner occupancy is not CPU time, financial cost, billing, human time, or proof of waste.')
$cautions.Add('Out-of-window timestamps are rejected, including crossing attempts; no intervals are clipped.')
$cautions.Add('Pre-start delay includes dependencies, approvals, and concurrency; it is not pure runner queue time.')
$cautions.Add('Observed elapsed span includes gaps and parallel overlap, and never extrapolates unfinished jobs to capture time.')
if (-not $declaredComplete) {
    $cautions.Add('Attempt coverage is partial or unknown; latest-only exports cannot establish total retry occupancy.')
}
if ($jobCount -gt $measured) {
    $cautions.Add('Missing or unfinished durations are unknown, not zero; runner totals describe the measured subset only.')
}
if ($jobCount -gt $preStartMeasured) {
    $cautions.Add('Missing pre-start timestamp pairs remain unknown; pre-start totals cover measured pairs only.')
}
if ($timestamps.Count -eq 0) { $cautions.Add('No observed timestamps; elapsed span is unknown, not zero.') }
if ($suspected -gt 0) {
    $cautions.Add('Same-run, same-SHA, same-name fail-then-pass is suspected nondeterminism only; environment and job equivalence remain evidence gaps, not confirmed flakiness or duplicate work.')
}
$sortedCautions = $cautions.ToArray()
[Array]::Sort($sortedCautions, [StringComparer]::Ordinal)
$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    inputSha256 = $inputDocument.Sha256
    scope = [pscustomobject][ordered]@{
        window = [pscustomobject][ordered]@{ from = $evidence.window.from; to = $evidence.window.to }
        capturedAt = $evidence.capturedAt
        collection = [pscustomobject][ordered]@{ attempts = $evidence.collection.attempts; complete = $evidence.collection.complete }
    }
    method = 'completed-job-known-subset; inclusive-window-reject-crossing; observed-timestamp-span'
    collectionCompleteness = $(if ($declaredComplete) { 'declared_all_complete' } else { 'partial_or_unknown' })
    runIdentityCount = $runsById.Count
    runAttemptCount = $normalizedRuns.Count
    jobCount = $jobCount
    completedJobCount = $completed
    measuredJobCount = $measured
    unmeasuredJobCount = $jobCount - $measured
    incompleteDurationCount = $jobCount - $measured
    runnerSecondsKnown = $runnerTicks / 10000000
    runnerMinutesKnown = [decimal]::Round($runnerTicks / 600000000, 9)
    retryRunnerSecondsKnown = $retryTicks / 10000000
    preStartSecondsKnown = $preStartTicks / 10000000
    preStartMeasuredJobCount = $preStartMeasured
    preStartIncompleteCount = $jobCount - $preStartMeasured
    observedElapsedSeconds = $elapsed
    suspectedNondeterminismCount = $suspected
    nondeterminismAssessment = $(if ($suspected -gt 0) { 'suspected_only' } else { 'not_observed' })
    environmentEquivalenceVerified = $false
    cautions = $sortedCautions
}
if ($Json) { $result | ConvertTo-Json -Depth 8 -Compress } else { $result }
