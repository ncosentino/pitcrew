#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-PitCrewProperty {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

        [object]$Default = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function ConvertTo-PitCrewUtc {
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    return ([DateTimeOffset]$Value).ToUniversalTime()
}

function Get-PitCrewSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }
    $hex = [BitConverter]::ToString($hash).Replace('-', '')
    return $hex.ToLowerInvariant()
}

function ConvertTo-PitCrewRepositoryIdentity {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $trimmed = $Value.Trim()
    $uri = $null
    $identity = if ([Uri]::TryCreate(
            $trimmed,
            [UriKind]::Absolute,
            [ref]$uri) -and
        $uri.Host -ieq 'github.com') {
        $uri.AbsolutePath.Trim('/').ToLowerInvariant()
    } else {
        $trimmed.Trim('/').ToLowerInvariant()
    }
    return [regex]::Replace(
        $identity,
        '\.git$',
        '',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function ConvertTo-PitCrewMarkdownText {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }
    $text = [string]$Value
    $text = [regex]::Replace($text, '\s+', ' ')
    $text = [Net.WebUtility]::HtmlEncode($text)
    foreach ($replacement in @(
            @('`', '&#96;'),
            @('|', '&#124;'),
            @('*', '&#42;'),
            @('_', '&#95;'),
            @('[', '&#91;'),
            @(']', '&#93;'),
            @('!', '&#33;'),
            @('\', '&#92;'))) {
        $text = $text.Replace($replacement[0], $replacement[1])
    }
    return $text
}

function Test-PitCrewLiteralTextFilter {
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [string[]]$Filters
    )

    if ($Filters.Count -eq 0) {
        return $true
    }
    foreach ($filter in $Filters) {
        if ($Value.IndexOf(
                $filter,
                [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Get-PitCrewPercentile {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [double[]]$Values,

        [Parameter(Mandatory)]
        [ValidateRange(0, 1)]
        [double]$Percentile
    )

    if ($Values.Count -eq 0) {
        return $null
    }
    $ordered = @($Values | Sort-Object)
    $index = [Math]::Max(
        0,
        [Math]::Ceiling($Percentile * $ordered.Count) - 1)
    return [Math]::Round([double]$ordered[$index], 3)
}

function Get-PitCrewMedian {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [double[]]$Values
    )

    if ($Values.Count -eq 0) {
        return $null
    }
    $ordered = @($Values | Sort-Object)
    $middle = [Math]::Floor($ordered.Count / 2)
    if ($ordered.Count % 2 -eq 1) {
        return [Math]::Round([double]$ordered[$middle], 3)
    }
    return [Math]::Round(
        ([double]$ordered[$middle - 1] + [double]$ordered[$middle]) / 2,
        3)
}

function Get-PitCrewDurationStatistics {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Jobs
    )

    $durations = @(
        $Jobs |
            Where-Object { $null -ne $_.durationSeconds } |
            ForEach-Object { [double]$_.durationSeconds }
    )
    $concludedJobs = @(
        $Jobs |
            Where-Object { $null -ne $_.conclusion })
    $timedOutOrCancelled = @(
        $concludedJobs |
            Where-Object {
                $_.conclusion -in @('cancelled', 'timed_out')
            }
    ).Count
    $rate = if ($concludedJobs.Count -eq 0) {
        $null
    } else {
        [Math]::Round(
            $timedOutOrCancelled / $concludedJobs.Count,
            4)
    }
    return [PSCustomObject][ordered]@{
        count = $Jobs.Count
        completedCount = $durations.Count
        concludedCount = $concludedJobs.Count
        unfinishedCount = $Jobs.Count - $concludedJobs.Count
        medianSeconds = Get-PitCrewMedian -Values $durations
        p95Seconds = Get-PitCrewPercentile -Values $durations -Percentile 0.95
        minimumSeconds = if ($durations.Count -eq 0) {
            $null
        } else {
            [Math]::Round(($durations | Measure-Object -Minimum).Minimum, 3)
        }
        maximumSeconds = if ($durations.Count -eq 0) {
            $null
        } else {
            [Math]::Round(($durations | Measure-Object -Maximum).Maximum, 3)
        }
        rangeSeconds = if ($durations.Count -eq 0) {
            $null
        } else {
            [Math]::Round(
                (($durations | Measure-Object -Maximum).Maximum -
                    ($durations | Measure-Object -Minimum).Minimum),
                3)
        }
        timedOutOrCancelled = $timedOutOrCancelled
        timedOutOrCancelledRate = $rate
    }
}

function Get-PitCrewOverlapSeconds {
    param(
        [Parameter(Mandatory)]
        [DateTimeOffset]$StartedAt,

        [Parameter(Mandatory)]
        [DateTimeOffset]$CompletedAt,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$OtherJobs
    )

    $intervals = @(
        foreach ($job in $OtherJobs) {
            $start = if ($job._startedAt -gt $StartedAt) {
                $job._startedAt
            } else {
                $StartedAt
            }
            $end = if ($job._completedAt -lt $CompletedAt) {
                $job._completedAt
            } else {
                $CompletedAt
            }
            if ($end -gt $start) {
                [PSCustomObject]@{ Start = $start; End = $end }
            }
        }
    )
    if ($intervals.Count -eq 0) {
        return 0.0
    }
    $ordered = @($intervals | Sort-Object Start, End)
    $currentStart = $ordered[0].Start
    $currentEnd = $ordered[0].End
    $seconds = 0.0
    foreach ($interval in $ordered | Select-Object -Skip 1) {
        if ($interval.Start -le $currentEnd) {
            if ($interval.End -gt $currentEnd) {
                $currentEnd = $interval.End
            }
            continue
        }
        $seconds += ($currentEnd - $currentStart).TotalSeconds
        $currentStart = $interval.Start
        $currentEnd = $interval.End
    }
    $seconds += ($currentEnd - $currentStart).TotalSeconds
    return [Math]::Round($seconds, 3)
}

function Invoke-PitCrewPagedFleetRequest {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Request,

        [ValidateRange(1, 100)]
        [int]$Limit = 100
    )

    $nodes = [Collections.Generic.List[object]]::new()
    $afterNodeId = $null
    do {
        $page = & $Request $afterNodeId $Limit
        foreach ($node in @($page.nodes)) {
            $nodes.Add($node)
        }
        $afterNodeId = Get-PitCrewProperty `
            -InputObject $page `
            -Name 'nextAfterNodeId'
    } while ($null -ne $afterNodeId)
    return @($nodes)
}

function Get-PitCrewPartitionedWorkflowRuns {
    param(
        [Parameter(Mandatory)]
        [DateTimeOffset]$From,

        [Parameter(Mandatory)]
        [DateTimeOffset]$To,

        [Parameter(Mandatory)]
        [scriptblock]$Request
    )

    if ($To -le $From) {
        throw 'Workflow-run partition end must be after its start.'
    }
    $pending = [Collections.Generic.Queue[object]]::new()
    $pending.Enqueue([PSCustomObject]@{ From = $From; To = $To })
    $runs = @{}
    while ($pending.Count -gt 0) {
        $partition = $pending.Dequeue()
        $response = & $Request $partition.From $partition.To
        $totalCount = [long]$response.TotalCount
        if ($totalCount -ge 1000) {
            if (($partition.To - $partition.From).TotalSeconds -le 1) {
                throw 'GitHub returned at least 1,000 workflow runs inside one second; the bounded query cannot prove completeness.'
            }
            $ticks = [long](($partition.To - $partition.From).Ticks / 2)
            $middle = $partition.From.AddTicks($ticks)
            $pending.Enqueue([PSCustomObject]@{
                From = $partition.From
                To = $middle
            })
            $pending.Enqueue([PSCustomObject]@{
                From = $middle
                To = $partition.To
            })
            continue
        }
        foreach ($run in @($response.Runs)) {
            $runs[[string]$run.id] = $run
        }
    }
    return @(
        $runs.Values |
            Sort-Object created_at, id
    )
}

function Test-PitCrewUntimedJobRelevant {
    param(
        [AllowNull()]
        [string]$Conclusion,

        [AllowNull()]
        [string]$RunStatus,

        [AllowNull()]
        [object]$RunCreatedAt,

        [AllowNull()]
        [object]$RunUpdatedAt,

        [Parameter(Mandatory)]
        [DateTimeOffset]$From,

        [Parameter(Mandatory)]
        [DateTimeOffset]$To
    )

    if ($Conclusion -eq 'skipped') {
        return $false
    }
    if ($RunStatus -ne 'completed') {
        return $null -eq $RunCreatedAt -or
            (ConvertTo-PitCrewUtc $RunCreatedAt) -lt $To
    }
    if ($null -eq $RunCreatedAt -or $null -eq $RunUpdatedAt) {
        return $true
    }
    $createdAt = ConvertTo-PitCrewUtc $RunCreatedAt
    $updatedAt = ConvertTo-PitCrewUtc $RunUpdatedAt
    return $createdAt -lt $To -and $updatedAt -gt $From
}

function Test-PitCrewWorkflowRunRelevant {
    param(
        [AllowNull()]
        [string]$Status,

        [AllowNull()]
        [object]$CreatedAt,

        [AllowNull()]
        [object]$UpdatedAt,

        [Parameter(Mandatory)]
        [DateTimeOffset]$From,

        [Parameter(Mandatory)]
        [DateTimeOffset]$To
    )

    if ($null -ne $CreatedAt -and
        (ConvertTo-PitCrewUtc $CreatedAt) -ge $To) {
        return $false
    }
    if ($Status -eq 'completed' -and
        $null -ne $UpdatedAt -and
        (ConvertTo-PitCrewUtc $UpdatedAt) -le $From) {
        return $false
    }
    return $true
}

function ConvertTo-PitCrewTelemetrySample {
    param(
        [Parameter(Mandatory)]
        [object]$Sample
    )

    $fields = @(
        'observedAt',
        'sampledAt',
        'telemetryStatus',
        'desiredSlots',
        'activeSlots',
        'drainingSlots',
        'configuredSlots',
        'eligibleSlots',
        'targetSlots',
        'maximumSlots',
        'assignedJobs',
        'runningJobs',
        'availableJobs',
        'idleRunners',
        'busyRunners',
        'localRunningWorkers',
        'managerCpuCores',
        'managerMemoryBytes',
        'managerPids',
        'hostLogicalProcessorCount',
        'hostMemoryBytes',
        'workerCpuCores',
        'workerMemoryBytes',
        'workerPids',
        'networkRxBytes',
        'networkTxBytes',
        'blockReadBytes',
        'blockWriteBytes',
        'exitReports',
        'adverseExitReports',
        'localCapacityDeficit',
        'eligibilityCapacityDeficit',
        'capacityDeficitReason',
        'capacityDeficitFreshness'
    )
    $projection = [ordered]@{}
    foreach ($field in $fields) {
        $projection[$field] = Get-PitCrewProperty $Sample $field
    }
    return [PSCustomObject]$projection
}

function ConvertTo-PitCrewHardware {
    param(
        [AllowNull()]
        [object]$Hardware
    )

    if ($null -eq $Hardware) {
        return $null
    }
    $fields = @(
        'status',
        'collectedAt',
        'attemptedAt',
        'inventoryHash',
        'processorModel',
        'architecture',
        'physicalCoreCount',
        'logicalProcessorCount',
        'performanceCoreCount',
        'efficiencyCoreCount',
        'memoryBytes',
        'operatingSystem',
        'kernelVersion',
        'dockerServerVersion',
        'dockerStorageDriver',
        'dockerBackingFilesystem'
    )
    $projection = [ordered]@{}
    foreach ($field in $fields) {
        $projection[$field] = Get-PitCrewProperty $Hardware $field
    }
    return [PSCustomObject]$projection
}

function ConvertTo-PitCrewHardwareRevision {
    param(
        [Parameter(Mandatory)]
        [object]$Revision
    )

    return [PSCustomObject][ordered]@{
        inventoryHash = Get-PitCrewProperty $Revision 'inventoryHash'
        collectedAt = Get-PitCrewProperty $Revision 'collectedAt'
        firstObservedAt = Get-PitCrewProperty $Revision 'firstObservedAt'
        lastObservedAt = Get-PitCrewProperty $Revision 'lastObservedAt'
        hardware = ConvertTo-PitCrewHardware `
            (Get-PitCrewProperty $Revision 'hardware')
    }
}

function ConvertTo-PitCrewRetention {
    param(
        [Parameter(Mandatory)]
        [object]$Retention
    )

    $fields = @(
        'earliestRetainedSample',
        'droppedSamples',
        'earliestRetainedRollup',
        'droppedRollups',
        'earliestRetainedEvent',
        'droppedEvents',
        'earliestRetainedSubsystemHealthChange',
        'droppedSubsystemHealthChanges',
        'earliestRetainedCapacityDeficit',
        'droppedCapacityDeficits',
        'earliestRetainedRunnerAssignment',
        'droppedRunnerAssignments',
        'rejectedFutureSamples',
        'historyExpiredAt'
    )
    $projection = [ordered]@{}
    foreach ($field in $fields) {
        $projection[$field] = Get-PitCrewProperty $Retention $field
    }
    return [PSCustomObject]$projection
}

function New-PitCrewPerformanceReportModel {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Jobs,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Nodes,

        [Parameter(Mandatory)]
        [Collections.IDictionary]$Histories,

        [Parameter(Mandatory)]
        [DateTimeOffset]$From,

        [Parameter(Mandatory)]
        [DateTimeOffset]$To,

        [Parameter(Mandatory)]
        [string[]]$Repositories,

        [ValidateRange(1, 86400)]
        [int]$ExpectedCadenceSeconds = 15,

        [DateTimeOffset]$GeneratedAt = [DateTimeOffset]::UtcNow
    )

    if ($To -le $From) {
        throw 'The performance-report end time must be after its start time.'
    }

    $orderedNodes = @($Nodes | Sort-Object nodeId)
    $nodeKeys = @{}
    for ($index = 0; $index -lt $orderedNodes.Count; $index++) {
        $nodeKeys[[string]$orderedNodes[$index].nodeId] = "node-$($index + 1)"
    }

    $assignmentsByHash = @{}
    $seenAssignments = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $nodeMeasurements = [Collections.Generic.List[object]]::new()
    $nodeMeasurementsByKey = @{}
    $unavailable = [Collections.Generic.List[object]]::new()
    $mappingIncompleteNodes = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $mappingIncompleteProfiles = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $hardwareIncompleteNodes = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $assignmentUniverseIncomplete = $false
    foreach ($node in $orderedNodes) {
        $nodeId = [string]$node.nodeId
        $history = $Histories[$nodeId]
        if ($null -eq $history) {
            $assignmentUniverseIncomplete = $true
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'node-history'
                nodeKey = $nodeKeys[$nodeId]
                reason = 'Dashboard history was unavailable for the requested node.'
            })
            continue
        }
        $nodeKey = $nodeKeys[$nodeId]
        if (Get-PitCrewProperty $history 'profileEnumerationIncomplete' $false) {
            $assignmentUniverseIncomplete = $true
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'profile-history'
                nodeKey = $nodeKey
                reason = 'Credential scope exposed only current profiles, so removed profile history could not be enumerated.'
            })
        }
        if (Get-PitCrewProperty $node 'currentFleetUnavailable' $false) {
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'current-fleet'
                nodeKey = $nodeKey
                reason = 'The explicitly requested node was absent from the scoped current fleet page.'
            })
        }
        foreach ($missingProfile in @(
                Get-PitCrewProperty `
                    $history `
                    'requestedProfilesUnavailable' `
                    @())) {
            $assignmentUniverseIncomplete = $true
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'profile-history'
                nodeKey = $nodeKey
                profileId = [string]$missingProfile
                reason = 'The requested retained profile history was unavailable or outside credential scope.'
            })
        }
        foreach ($assignment in @(
                Get-PitCrewProperty $history 'runnerAssignments' @())) {
            $hash = [string]$assignment.runnerNameHash
            $assignmentKey =
                "$nodeId|$($assignment.profileId)|$hash"
            if (-not $seenAssignments.Add($assignmentKey)) {
                continue
            }
            if (-not $assignmentsByHash.ContainsKey($hash)) {
                $assignmentsByHash[$hash] =
                    [Collections.Generic.List[object]]::new()
            }
            $assignmentsByHash[$hash].Add([PSCustomObject][ordered]@{
                runnerNameHash = $hash
                nodeId = $nodeId
                nodeKey = $nodeKeys[$nodeId]
                profileId = [string]$assignment.profileId
                slotKey = [string]$assignment.slotKey
                repository = ConvertTo-PitCrewRepositoryIdentity `
                    (Get-PitCrewProperty $assignment 'repository')
                target = Get-PitCrewProperty $assignment 'target'
                firstObservedAt = ConvertTo-PitCrewUtc $assignment.firstObservedAt
                lastObservedAt = ConvertTo-PitCrewUtc $assignment.lastObservedAt
            })
        }
        foreach ($flag in @(
                @('pointsTruncated', 'telemetry-points'),
                @('eventsTruncated', 'manager-events'),
                @('diagnosticsTruncated', 'manager-diagnostics'),
                @('hardwareRevisionsTruncated', 'hardware-history'))) {
            if (Get-PitCrewProperty $history $flag[0] $false) {
                $unavailable.Add([PSCustomObject][ordered]@{
                    kind = $flag[1]
                    nodeKey = $nodeKey
                    reason = "Dashboard reported '$($flag[0])' for the requested range."
                })
                if ($flag[0] -eq 'hardwareRevisionsTruncated') {
                    $hardwareIncompleteNodes.Add($nodeKey) | Out-Null
                }
            }
        }
        if (Get-PitCrewProperty $history 'hardwareHistoryUnavailable' $false) {
            $hardwareIncompleteNodes.Add($nodeKey) | Out-Null
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'hardware-history'
                nodeKey = $nodeKey
                reason = 'Credential scope permitted profile history but not node hardware history.'
            })
        }
        if (Get-PitCrewProperty $history 'runnerAssignmentsTruncated' $false) {
            $assignmentUniverseIncomplete = $true
            $mappingIncompleteNodes.Add($nodeKey) | Out-Null
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'runner-assignments'
                nodeKey = $nodeKey
                reason = 'The Dashboard runner-assignment response was truncated.'
            })
        }
        foreach ($floor in @(
                Get-PitCrewProperty $history 'incompletenessFloors' @())) {
            $droppedAssignments = [long](
                Get-PitCrewProperty $floor 'droppedRunnerAssignments' 0)
            $droppedHardware = [long](
                Get-PitCrewProperty $floor 'droppedHardwareRevisions' 0)
            if ($droppedAssignments -gt 0) {
                $assignmentUniverseIncomplete = $true
                $mappingIncompleteNodes.Add($nodeKey) | Out-Null
            }
            if ($droppedHardware -gt 0) {
                $hardwareIncompleteNodes.Add($nodeKey) | Out-Null
            }
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'history-retention-floor'
                nodeKey = $nodeKey
                scope = Get-PitCrewProperty $floor 'scope'
                reason = "Dashboard compacted history provenance; $droppedAssignments runner assignments were deleted."
            })
        }
        $profileMeasurements = @(
            foreach ($profile in @(
                    Get-PitCrewProperty $history 'profiles' @())) {
                $profileId = [string]$profile.profileId
                $samples = @(
                    Get-PitCrewProperty $profile 'samples' @())
                $projectedSamples = @(
                    $samples |
                        ForEach-Object {
                            ConvertTo-PitCrewTelemetrySample $_
                        })
                foreach ($sample in $samples) {
                if ((Get-PitCrewProperty $sample 'telemetryStatus') -in
                    @('partial', 'unavailable', 'unreported')) {
                    $unavailable.Add([PSCustomObject][ordered]@{
                        kind = 'telemetry'
                            nodeKey = $nodeKey
                            profileId = $profileId
                        observedAt = [string]$sample.observedAt
                        reason = "Telemetry was '$($sample.telemetryStatus)'."
                    })
                }
            }
                if ($samples.Count -eq 0) {
                    $unavailable.Add([PSCustomObject][ordered]@{
                        kind = 'telemetry-coverage'
                        nodeKey = $nodeKey
                        profileId = $profileId
                        reason = 'No resource samples were retained in the requested range.'
                    })
                } else {
                    $sampleTimes = @(
                        $samples |
                            ForEach-Object {
                                ConvertTo-PitCrewUtc $_.observedAt
                            } |
                            Sort-Object)
                    $allowedGap = $ExpectedCadenceSeconds * 2
                    $startGap = ($sampleTimes[0] - $From).TotalSeconds
                    $endGap = ($To - $sampleTimes[-1]).TotalSeconds
                    $interiorGap = $false
                    for ($sampleIndex = 1;
                        $sampleIndex -lt $sampleTimes.Count;
                        $sampleIndex++) {
                        if (($sampleTimes[$sampleIndex] -
                                $sampleTimes[$sampleIndex - 1]).TotalSeconds -gt
                            $allowedGap) {
                            $interiorGap = $true
                            break
                        }
                    }
                    if ($startGap -gt $allowedGap -or
                        $endGap -gt $allowedGap -or
                        $interiorGap) {
                        $unavailable.Add([PSCustomObject][ordered]@{
                            kind = 'telemetry-coverage'
                            nodeKey = $nodeKey
                            profileId = $profileId
                            reason = 'Retained samples do not cover the complete requested range.'
                        })
                    }
                }
                $retention = ConvertTo-PitCrewRetention $profile.retention
                $dropped = [long]$retention.droppedSamples +
                    [long]$retention.droppedRollups +
                    [long]$retention.droppedEvents +
                    [long]$retention.droppedSubsystemHealthChanges +
                    [long]$retention.droppedCapacityDeficits +
                    [long]$retention.droppedRunnerAssignments +
                    [long]$retention.rejectedFutureSamples
                if ($dropped -gt 0 -or
                    $null -ne $retention.historyExpiredAt) {
                    if ([long]$retention.droppedRunnerAssignments -gt 0) {
                        $assignmentUniverseIncomplete = $true
                        $mappingIncompleteProfiles.Add(
                            "$nodeKey|$profileId") | Out-Null
                    }
                    $unavailable.Add([PSCustomObject][ordered]@{
                        kind = 'profile-retention'
                        nodeKey = $nodeKey
                        profileId = $profileId
                        reason = "Dashboard retention or clock rejection removed $dropped profile observations."
                    })
                }
                [PSCustomObject][ordered]@{
                    profileId = $profileId
                    samples = $projectedSamples
                    retention = $retention
                }
            })
        $hardware = ConvertTo-PitCrewHardware `
            (Get-PitCrewProperty $node 'hardware')
        if ($null -eq $hardware) {
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'hardware'
                nodeKey = $nodeKey
                reason = 'Current sanitized hardware inventory was unreported.'
            })
        } elseif ((Get-PitCrewProperty $hardware 'status') -ne 'current') {
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'hardware'
                nodeKey = $nodeKey
                reason = "Current sanitized hardware inventory was '$($hardware.status)', not current."
            })
        }
        $measurement = [PSCustomObject][ordered]@{
            nodeId = $nodeId
            nodeKey = $nodeKey
            hardware = $hardware
            hardwareRevisions = @(
                Get-PitCrewProperty $history 'hardwareRevisions' @() |
                    ForEach-Object {
                        ConvertTo-PitCrewHardwareRevision $_
                    })
            profiles = $profileMeasurements
        }
        $nodeMeasurements.Add($measurement)
        $nodeMeasurementsByKey[$nodeKey] = $measurement
    }

    $jobWork = [Collections.Generic.List[object]]::new()
    $seenJobs = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($job in $Jobs) {
        $startedValue = Get-PitCrewProperty $job 'startedAt'
        $completedValue = Get-PitCrewProperty $job 'completedAt'
        if ($null -eq $startedValue) {
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'job-timing'
                repository = [string]$job.repository
                jobId = [string]$job.jobId
                reason = 'GitHub did not report a job start time.'
            })
            continue
        }
        $startedAt = ConvertTo-PitCrewUtc $startedValue
        $completedAt = if ($null -eq $completedValue) {
            $To
        } else {
            ConvertTo-PitCrewUtc $completedValue
        }
        if ($completedAt -le $From -or $startedAt -ge $To) {
            continue
        }
        $runnerName = [string](Get-PitCrewProperty $job 'runnerName' '')
        if ([string]::IsNullOrWhiteSpace($runnerName)) {
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'runner-mapping'
                repository = [string]$job.repository
                jobId = [string]$job.jobId
                reason = 'GitHub did not report an exact runner name.'
            })
            continue
        }
        $hash = Get-PitCrewSha256 $runnerName
        $repository = ConvertTo-PitCrewRepositoryIdentity $job.repository
        $jobIdentity = "$repository|$($job.jobId)"
        if (-not $seenJobs.Add($jobIdentity)) {
            continue
        }
        $candidates = @(
            if ($assignmentsByHash.ContainsKey($hash)) {
                $assignmentsByHash[$hash] |
                    Where-Object {
                        $_.firstObservedAt -lt $completedAt -and
                        $_.lastObservedAt -ge $startedAt -and
                        ($null -eq $_.repository -or
                            $_.repository -eq $repository)
                    }
            }
        )
        $candidate = if ($candidates.Count -eq 1) {
            $candidates[0]
        } else {
            $null
        }
        $incompleteMapping = $null -ne $candidate -and
            ($assignmentUniverseIncomplete -or
                $mappingIncompleteNodes.Contains($candidate.nodeKey) -or
                $mappingIncompleteProfiles.Contains(
                    "$($candidate.nodeKey)|$($candidate.profileId)"))
        $mappingStatus = if ($incompleteMapping) {
            'incomplete'
        } elseif ($candidates.Count -eq 1) {
            'matched'
        } elseif ($candidates.Count -eq 0) {
            'unavailable'
        } else {
            'ambiguous'
        }
        if ($mappingStatus -ne 'matched') {
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'runner-mapping'
                repository = $repository
                jobId = [string]$job.jobId
                runnerNameHash = $hash
                reason = if ($mappingStatus -eq 'ambiguous') {
                    'More than one retained assignment matched the exact runner hash and interval.'
                } elseif ($mappingStatus -eq 'incomplete') {
                    'The retained assignment matched, but assignment truncation or retention loss makes uniqueness unverified.'
                } else {
                    'No retained assignment matched the exact runner hash and interval.'
                }
            })
        }
        if ($mappingStatus -ne 'matched') {
            $candidate = $null
        }
        $duration = if ($null -eq $completedValue) {
            $null
        } else {
            [Math]::Round(($completedAt - $startedAt).TotalSeconds, 3)
        }
        $hardwareInventoryHash = $null
        if ($null -ne $candidate -and
            -not $hardwareIncompleteNodes.Contains($candidate.nodeKey)) {
            $measurement = $nodeMeasurementsByKey[$candidate.nodeKey]
            $revisions = @(
                if ($null -ne $measurement) {
                    @($measurement.hardwareRevisions)
                }
            )
            $hardwareCandidates = @(
                if ($revisions.Count -gt 0) {
                    $revisions |
                        Where-Object {
                            $revisionHardware =
                                Get-PitCrewProperty $_ 'hardware'
                            $null -ne $revisionHardware -and
                            (Get-PitCrewProperty `
                                $revisionHardware `
                                'status') -eq 'current' -and
                            (ConvertTo-PitCrewUtc $_.firstObservedAt) -lt
                                $completedAt -and
                            (ConvertTo-PitCrewUtc $_.lastObservedAt) -ge
                                $startedAt
                        } |
                        ForEach-Object { $_.inventoryHash } |
                        Sort-Object -Unique
                }
            )
            if ($hardwareCandidates.Count -eq 1) {
                $hardwareInventoryHash = $hardwareCandidates[0]
            } elseif ($revisions.Count -eq 0 -and
                $null -ne $measurement.hardware) {
                $currentHash = Get-PitCrewProperty `
                    $measurement.hardware `
                    'inventoryHash'
                $collectedAt = Get-PitCrewProperty `
                    $measurement.hardware `
                    'collectedAt'
                if ($null -ne $currentHash -and
                    $null -ne $collectedAt -and
                    (Get-PitCrewProperty `
                        $measurement.hardware `
                        'status') -eq 'current' -and
                    (ConvertTo-PitCrewUtc $collectedAt) -le $From) {
                    $hardwareInventoryHash = $currentHash
                }
            }
            if ($null -eq $hardwareInventoryHash) {
                $reason = if ($revisions.Count -eq 0) {
                    'No in-range hardware changes were retained and current hardware was not established before the range.'
                } elseif ($hardwareCandidates.Count -eq 0) {
                    'No retained hardware revision overlapped the mapped job.'
                } else {
                    'More than one hardware revision overlapped the mapped job.'
                }
                $unavailable.Add([PSCustomObject][ordered]@{
                    kind = 'hardware-timing'
                    nodeKey = $candidate.nodeKey
                    jobId = [string]$job.jobId
                    reason = $reason
                })
            }
        } elseif ($null -ne $candidate) {
            $unavailable.Add([PSCustomObject][ordered]@{
                kind = 'hardware-timing'
                nodeKey = $candidate.nodeKey
                jobId = [string]$job.jobId
                reason = 'Hardware history was truncated, unavailable, or retention-damaged for the mapped node.'
            })
        }
        $workflowName = [string]$job.workflowName
        $workflowId = [string](
            Get-PitCrewProperty $job 'workflowId' $workflowName)
        $jobName = [string]$job.jobName
        $labels = @($job.labels | Sort-Object -Unique)
        $jobDefinitionKey = Get-PitCrewSha256(
            "$repository`n$workflowId`n$jobName`n$($labels -join "`n")")
        $cohortKey = $jobDefinitionKey
        $jobWork.Add([PSCustomObject][ordered]@{
            repository = $repository
            workflowRunId = [string]$job.workflowRunId
            workflowId = $workflowId
            workflowName = $workflowName
            runAttempt = [int](Get-PitCrewProperty $job 'runAttempt' 1)
            jobId = [string]$job.jobId
            jobName = $jobName
            jobDefinitionKey = $jobDefinitionKey
            cohortKey = $cohortKey
            runnerNameHash = $hash
            labels = $labels
            startedAt = $startedAt.ToString('O')
            completedAt = if ($null -eq $completedValue) {
                $null
            } else {
                $completedAt.ToString('O')
            }
            durationSeconds = $duration
            status = [string]$job.status
            conclusion = Get-PitCrewProperty $job 'conclusion'
            mappingStatus = $mappingStatus
            nodeId = if ($null -eq $candidate) { $null } else { $candidate.nodeId }
            nodeKey = if ($null -eq $candidate) { $null } else { $candidate.nodeKey }
            profileId = if ($null -eq $candidate) { $null } else { $candidate.profileId }
            slotKey = if ($null -eq $candidate) { $null } else { $candidate.slotKey }
            hardwareInventoryHash = $hardwareInventoryHash
            _startedAt = $startedAt
            _completedAt = $completedAt
            _overlapStartedAt = if ($startedAt -lt $From) {
                $From
            } else {
                $startedAt
            }
            _overlapCompletedAt = if ($completedAt -gt $To) {
                $To
            } else {
                $completedAt
            }
        })
    }

    foreach ($job in $jobWork) {
        $otherJobs = @(
            $jobWork |
                Where-Object {
                    $_.jobId -ne $job.jobId -and
                    $null -ne $job.nodeKey -and
                    $_.nodeKey -eq $job.nodeKey -and
                    $_.profileId -ne $job.profileId -and
                    $_._overlapStartedAt -lt
                        $job._overlapCompletedAt -and
                    $_._overlapCompletedAt -gt
                        $job._overlapStartedAt
                }
        )
        $overlap = Get-PitCrewOverlapSeconds `
            -StartedAt $job._overlapStartedAt `
            -CompletedAt $job._overlapCompletedAt `
            -OtherJobs @(
                $otherJobs |
                    ForEach-Object {
                        [PSCustomObject]@{
                            _startedAt = $_._overlapStartedAt
                            _completedAt = $_._overlapCompletedAt
                        }
                    })
        $job | Add-Member `
            -NotePropertyName crossProfileOverlapSeconds `
            -NotePropertyValue $overlap
        $job | Add-Member `
            -NotePropertyName crossProfileOverlap `
            -NotePropertyValue ($overlap -gt 0)
    }

    $reportedJobs = @(
        foreach ($job in $jobWork) {
            $job |
                Select-Object * -ExcludeProperty `
                    _startedAt, `
                    _completedAt, `
                    _overlapStartedAt, `
                    _overlapCompletedAt
        }
    )
    $matched = @($reportedJobs | Where-Object mappingStatus -eq 'matched')
    $nodeSummaries = @(
        $matched |
            Group-Object nodeKey |
            Sort-Object Name |
            ForEach-Object {
                [PSCustomObject][ordered]@{
                    nodeKey = $_.Name
                    statistics = Get-PitCrewDurationStatistics $_.Group
                }
            }
    )
    $profileSummaries = @(
        $matched |
            Group-Object {
                "$($_.nodeKey)|$($_.profileId)|$($_.cohortKey)"
            } |
            Sort-Object Name |
            ForEach-Object {
                $first = $_.Group[0]
                [PSCustomObject][ordered]@{
                    nodeKey = $first.nodeKey
                    profileId = $first.profileId
                    repository = $first.repository
                    workflowId = $first.workflowId
                    workflowName = $first.workflowName
                    jobName = $first.jobName
                    jobDefinitionKey = $first.jobDefinitionKey
                    statistics = Get-PitCrewDurationStatistics $_.Group
                }
            }
    )
    $jobNodeSummaries = @(
        $matched |
            Group-Object { "$($_.nodeKey)|$($_.cohortKey)" } |
            Sort-Object Name |
            ForEach-Object {
                $first = $_.Group[0]
                [PSCustomObject][ordered]@{
                    nodeKey = $first.nodeKey
                    repository = $first.repository
                    workflowId = $first.workflowId
                    workflowName = $first.workflowName
                    jobName = $first.jobName
                    jobDefinitionKey = $first.jobDefinitionKey
                    statistics = Get-PitCrewDurationStatistics $_.Group
                }
            }
    )
    $overlapComparisons = @(
        $matched |
            Group-Object { "$($_.nodeKey)|$($_.cohortKey)" } |
            Sort-Object Name |
            ForEach-Object {
                $first = $_.Group[0]
                $baselineJobs = @(
                    $_.Group |
                        Where-Object { -not $_.crossProfileOverlap })
                $overlapJobs = @(
                    $_.Group |
                        Where-Object crossProfileOverlap)
                $baseline = Get-PitCrewDurationStatistics $baselineJobs
                $overlap = Get-PitCrewDurationStatistics $overlapJobs
                $delta = if ($null -eq $baseline.medianSeconds -or
                    $baseline.medianSeconds -eq 0 -or
                    $null -eq $overlap.medianSeconds) {
                    $null
                } else {
                    [Math]::Round(
                        (($overlap.medianSeconds - $baseline.medianSeconds) /
                            $baseline.medianSeconds) * 100,
                        2)
                }
                [PSCustomObject][ordered]@{
                    nodeKey = $first.nodeKey
                    repository = $first.repository
                    workflowId = $first.workflowId
                    workflowName = $first.workflowName
                    jobName = $first.jobName
                    jobDefinitionKey = $first.jobDefinitionKey
                    withoutCrossProfileOverlap = $baseline
                    withCrossProfileOverlap = $overlap
                    medianDeltaPercent = $delta
                }
            }
    )

    $hypotheses = [Collections.Generic.List[object]]::new()
    $contention = @(
        $overlapComparisons |
            Where-Object {
                $null -ne $_.medianDeltaPercent -and
                $_.medianDeltaPercent -gt 0 -and
                -not $mappingIncompleteNodes.Contains($_.nodeKey)
            } |
            Sort-Object medianDeltaPercent -Descending
    )
    if ($contention.Count -gt 0) {
        $hypotheses.Add([PSCustomObject][ordered]@{
            rank = 1
            hypothesis = 'Cross-profile host contention is associated with longer job duration.'
            evidence = "Largest like-for-like median increase was $($contention[0].medianDeltaPercent)% for '$($contention[0].jobName)' on $($contention[0].nodeKey)."
            followUp = 'Repeat the same jobs at the same concurrency with cross-profile overlap deliberately absent and present.'
        })
    }
    $crossNodeHardwareCohorts = @(
        $matched |
            Where-Object {
                $null -ne $_.durationSeconds -and
                $null -ne $_.hardwareInventoryHash
            } |
            Group-Object cohortKey |
            Where-Object {
                $nodeGroups = @($_.Group | Group-Object nodeKey)
                $nodeMedians = @(
                    $nodeGroups |
                        ForEach-Object {
                            $statistics =
                                Get-PitCrewDurationStatistics $_.Group
                            $statistics.medianSeconds
                        } |
                        Where-Object { $null -ne $_ } |
                        Sort-Object -Unique
                )
                $nodeGroups.Count -gt 1 -and
                @(
                    $_.Group.hardwareInventoryHash |
                        Sort-Object -Unique
                ).Count -gt 1 -and
                $nodeMedians.Count -gt 1
            }
    )
    if ($crossNodeHardwareCohorts.Count -gt 0) {
        $cohort = $crossNodeHardwareCohorts[0].Group[0]
        $hypotheses.Add([PSCustomObject][ordered]@{
            rank = $hypotheses.Count + 1
            hypothesis = 'Different sanitized hardware or runtime inventory may explain cross-node duration differences.'
            evidence = "Like-for-like '$($cohort.jobName)' measurements ran on $(@($crossNodeHardwareCohorts[0].Group.nodeKey | Sort-Object -Unique).Count) nodes with different time-aligned hardware hashes."
            followUp = 'Repeat one representative job without overlap on each node using the same worker image and input data.'
        })
    }
    if ($unavailable.Count -gt 0) {
        $hypotheses.Add([PSCustomObject][ordered]@{
            rank = $hypotheses.Count + 1
            hypothesis = 'Missing or truncated evidence may be hiding an alternative explanation.'
            evidence = "$($unavailable.Count) evidence gaps were recorded."
            followUp = 'Repeat the bounded collection with a node-scoped diagnostic credential and a range fully covered by retention.'
        })
    }

    return [PSCustomObject][ordered]@{
        schemaVersion = 1
        generatedAt = $GeneratedAt.ToUniversalTime().ToString('O')
        range = [PSCustomObject][ordered]@{
            from = $From.ToUniversalTime().ToString('O')
            to = $To.ToUniversalTime().ToString('O')
        }
        repositories = @($Repositories)
        verifiedMeasurements = [PSCustomObject][ordered]@{
            jobs = $reportedJobs
            nodeSummaries = $nodeSummaries
            jobNodeSummaries = $jobNodeSummaries
            profileSummaries = $profileSummaries
            overlapComparisons = $overlapComparisons
            nodes = @($nodeMeasurements)
        }
        unavailableEvidence = @($unavailable)
        hypotheses = @($hypotheses)
        limitations = @(
            'Correlation is not causation.',
            'One paired sample is not a host benchmark.',
            'A missing assignment or telemetry sample remains unavailable rather than being inferred.'
        )
    }
}

function ConvertTo-PitCrewPerformanceMarkdown {
    param(
        [Parameter(Mandatory)]
        [object]$Report
    )

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# PitCrew performance correlation report')
    $lines.Add('')
    $lines.Add(
        "Range: ``$($Report.range.from)`` to ``$($Report.range.to)``")
    $lines.Add('')
    $lines.Add('> Correlation is not causation. One paired sample is not a host benchmark.')
    $lines.Add('')
    $lines.Add('## Verified measurements')
    $lines.Add('')
    $lines.Add('| Repository | Job | Node | Profile | Duration (s) | Cross-profile overlap (s) | Conclusion |')
    $lines.Add('| --- | --- | --- | --- | ---: | ---: | --- |')
    foreach ($job in @($Report.verifiedMeasurements.jobs)) {
        $duration = if ($null -eq $job.durationSeconds) {
            'unavailable'
        } else {
            [string]$job.durationSeconds
        }
        $repository = ConvertTo-PitCrewMarkdownText $job.repository
        $jobName = ConvertTo-PitCrewMarkdownText $job.jobName
        $nodeKey = if ($null -eq $job.nodeKey) {
            'unmatched'
        } else {
            ConvertTo-PitCrewMarkdownText $job.nodeKey
        }
        $profileId = if ($null -eq $job.profileId) {
            'unmatched'
        } else {
            ConvertTo-PitCrewMarkdownText $job.profileId
        }
        $conclusion = if ($null -eq $job.conclusion) {
            ConvertTo-PitCrewMarkdownText $job.status
        } else {
            ConvertTo-PitCrewMarkdownText $job.conclusion
        }
        $lines.Add(
            "| $repository | $jobName | $nodeKey | $profileId | $duration | $($job.crossProfileOverlapSeconds) | $conclusion |")
    }
    $lines.Add('')
    $lines.Add('### Node duration summaries')
    $lines.Add('')
    $lines.Add('| Node | Jobs | Median (s) | p95 (s) | Range (s) | Timeout/cancellation rate |')
    $lines.Add('| --- | ---: | ---: | ---: | ---: | ---: |')
    foreach ($summary in @($Report.verifiedMeasurements.nodeSummaries)) {
        $statistics = $summary.statistics
        $nodeKey = ConvertTo-PitCrewMarkdownText $summary.nodeKey
        $lines.Add(
            "| $nodeKey | $($statistics.count) | $($statistics.medianSeconds) | $($statistics.p95Seconds) | $($statistics.rangeSeconds) | $($statistics.timedOutOrCancelledRate) |")
    }
    $lines.Add('')
    $lines.Add('### Like-for-like job/node summaries')
    $lines.Add('')
    $lines.Add('| Repository | Workflow | Job | Node | Count | Median (s) | p95 (s) | Range (s) |')
    $lines.Add('| --- | --- | --- | --- | ---: | ---: | ---: | ---: |')
    foreach ($summary in @($Report.verifiedMeasurements.jobNodeSummaries)) {
        $statistics = $summary.statistics
        $repository = ConvertTo-PitCrewMarkdownText $summary.repository
        $workflowName = ConvertTo-PitCrewMarkdownText $summary.workflowName
        $jobName = ConvertTo-PitCrewMarkdownText $summary.jobName
        $nodeKey = ConvertTo-PitCrewMarkdownText $summary.nodeKey
        $lines.Add(
            "| $repository | $workflowName | $jobName | $nodeKey | $($statistics.count) | $($statistics.medianSeconds) | $($statistics.p95Seconds) | $($statistics.rangeSeconds) |")
    }
    $lines.Add('')
    $lines.Add('### Like-for-like overlap comparisons')
    $lines.Add('')
    $lines.Add('| Repository | Workflow | Job | Node | Baseline median (s) | Overlap median (s) | Delta |')
    $lines.Add('| --- | --- | --- | --- | ---: | ---: | ---: |')
    foreach ($comparison in @(
            $Report.verifiedMeasurements.overlapComparisons)) {
        $repository = ConvertTo-PitCrewMarkdownText $comparison.repository
        $workflowName = ConvertTo-PitCrewMarkdownText $comparison.workflowName
        $jobName = ConvertTo-PitCrewMarkdownText $comparison.jobName
        $nodeKey = ConvertTo-PitCrewMarkdownText $comparison.nodeKey
        $lines.Add(
            "| $repository | $workflowName | $jobName | $nodeKey | $($comparison.withoutCrossProfileOverlap.medianSeconds) | $($comparison.withCrossProfileOverlap.medianSeconds) | $($comparison.medianDeltaPercent)% |")
    }
    $lines.Add('')
    $lines.Add('### Complete sanitized measurement payload')
    $lines.Add('')
    $lines.Add('<pre><code>')
    $lines.Add([Net.WebUtility]::HtmlEncode(
            ($Report.verifiedMeasurements | ConvertTo-Json -Depth 30)))
    $lines.Add('</code></pre>')
    $lines.Add('')
    $lines.Add('## Unavailable evidence')
    $lines.Add('')
    if (@($Report.unavailableEvidence).Count -eq 0) {
        $lines.Add('- None recorded.')
    } else {
        foreach ($item in @($Report.unavailableEvidence)) {
            $kind = ConvertTo-PitCrewMarkdownText $item.kind
            $reason = ConvertTo-PitCrewMarkdownText $item.reason
            $lines.Add("- **$kind**: $reason")
        }
    }
    $lines.Add('')
    $lines.Add('<pre><code>')
    $lines.Add([Net.WebUtility]::HtmlEncode(
            (@($Report.unavailableEvidence) | ConvertTo-Json -Depth 20)))
    $lines.Add('</code></pre>')
    $lines.Add('')
    $lines.Add('## Hypotheses')
    $lines.Add('')
    if (@($Report.hypotheses).Count -eq 0) {
        $lines.Add('- No ranked hypothesis is supported by the available measurements.')
    } else {
        foreach ($item in @($Report.hypotheses | Sort-Object rank)) {
            $hypothesis = ConvertTo-PitCrewMarkdownText $item.hypothesis
            $evidence = ConvertTo-PitCrewMarkdownText $item.evidence
            $followUp = ConvertTo-PitCrewMarkdownText $item.followUp
            $lines.Add("$($item.rank). **$hypothesis** $evidence Follow-up: $followUp")
        }
    }
    $lines.Add('')
    $lines.Add('## Limitations')
    $lines.Add('')
    foreach ($limitation in @($Report.limitations)) {
        $lines.Add("- $(ConvertTo-PitCrewMarkdownText $limitation)")
    }
    return $lines -join "`n"
}

function Write-PitCrewPerformanceReport {
    param(
        [Parameter(Mandatory)]
        [object]$Report,

        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    $resolved = [IO.Path]::GetFullPath($OutputDirectory)
    [IO.Directory]::CreateDirectory($resolved) | Out-Null
    $jsonPath = Join-Path $resolved 'pitcrew-performance-report.json'
    $markdownPath = Join-Path $resolved 'pitcrew-performance-report.md'
    $Report |
        ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM
    ConvertTo-PitCrewPerformanceMarkdown $Report |
        Set-Content -LiteralPath $markdownPath -Encoding utf8NoBOM
    return [PSCustomObject][ordered]@{
        JsonPath = $jsonPath
        MarkdownPath = $markdownPath
    }
}
