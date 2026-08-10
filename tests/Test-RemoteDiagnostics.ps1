#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$skillRoot = Join-Path `
    $root `
    'plugins' `
    'pitcrew-operations' `
    'skills' `
    'pitcrew-remote-diagnostics'
$scriptsRoot = Join-Path $skillRoot 'scripts'
$collector = Join-Path $scriptsRoot 'Collect-PitCrewDiagnostics.ps1'
$packageScript = Join-Path $scriptsRoot 'New-PitCrewDiagnosticsPackage.ps1'
$importScript = Join-Path $scriptsRoot 'Import-PitCrewDiagnostics.ps1'
$orchestrator = Join-Path $scriptsRoot 'Invoke-PitCrewRemoteDiagnostics.ps1'
$preflightScript = Join-Path $scriptsRoot 'New-PitCrewDiagnosticsPreflight.ps1'
$coreScript = Join-Path $scriptsRoot 'RemoteDiagnostics.Core.ps1'
$transportScript = Join-Path $scriptsRoot 'RemoteDiagnostics.Transport.ps1'
$releaseAssetScript = Join-Path `
    $root `
    'scripts' `
    'release' `
    'New-PitCrewReleaseAssets.ps1'
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

function Add-ThrowsCheck {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$ExpectedMessage,
        [Parameter(Mandatory)][string]$Failure
    )

    try {
        & $Action
        Add-Check $false $Failure
    } catch {
        Add-Check (
            $_.Exception.Message -match [regex]::Escape($ExpectedMessage)
        ) "$Failure Actual: $($_.Exception.Message)"
    }
}

function Write-Utf8 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    [IO.File]::WriteAllText(
        $Path,
        $Content.Replace("`r`n", "`n"),
        [Text.UTF8Encoding]::new($false))
}

function Get-FixtureHashes {
    param([Parameter(Mandatory)][string]$Path)

    $hashes = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $Path -File -Recurse |
            Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($Path, $file.FullName)
        $hashes[$relative] = (
            Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $hashes
}

function Test-HashMapsEqual {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Expected,
        [Parameter(Mandatory)][Collections.IDictionary]$Actual
    )

    if ($Expected.Count -ne $Actual.Count) {
        return $false
    }
    foreach ($key in $Expected.Keys) {
        if (-not $Actual.Contains($key) -or
            $Expected[$key] -ne $Actual[$key]) {
            return $false
        }
    }
    return $true
}

foreach ($path in @(
        $collector,
        $packageScript,
        $importScript,
        $orchestrator,
        $preflightScript,
        $coreScript,
        $transportScript,
        $releaseAssetScript,
        (Join-Path $skillRoot 'SKILL.md'))) {
    Add-Check (
        Test-Path -LiteralPath $path -PathType Leaf
    ) "Remote diagnostics surface is missing: $path"
}
. $coreScript

$tempRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "pitcrew-remote-diagnostics-test-$([Guid]::NewGuid().ToString('N'))"
$fixtureRoot = Join-Path $tempRoot 'pitcrew'
$profileRoot = Join-Path $fixtureRoot '.pitcrew-state' 'default'
$fakeBin = Join-Path $tempRoot 'bin'
$outputRoot = Join-Path $tempRoot 'output'
$programData = Join-Path $tempRoot 'program-data'
$commandLog = Join-Path $tempRoot 'commands.log'
$originalPath = $env:PATH
$originalProgramData = $env:ProgramData
$originalCommandLog = $env:PITCREW_TEST_COMMAND_LOG
$originalSessionId = $env:PITCREW_TEST_SESSION_ID
try {
    foreach ($directory in @(
            $fixtureRoot,
            $profileRoot,
            $fakeBin,
            $outputRoot)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    Write-Utf8 `
        -Path (Join-Path $fixtureRoot 'Setup-Runner.ps1') `
        -Content '# fixture'
    Write-Utf8 `
        -Path (Join-Path $fixtureRoot 'RunnerProfiles.Functions.ps1') `
        -Content '# fixture'
    Write-Utf8 `
        -Path (Join-Path $fixtureRoot 'docker-compose.yml') `
        -Content 'services: {}'
    Write-Utf8 `
        -Path (Join-Path $fixtureRoot '.env') `
        -Content 'ACCESS_TOKEN=REMOTE_DIAGNOSTICS_SECRET_SENTINEL'
    Write-Utf8 `
        -Path (Join-Path $fixtureRoot 'job-output.txt') `
        -Content 'REMOTE_DIAGNOSTICS_JOB_OUTPUT_SENTINEL'
    Write-Utf8 `
        -Path (Join-Path $profileRoot 'desired-capacity.json') `
        -Content (@{
            schemaVersion = 1
            generation = 4
            scope = 'repo'
            repositories = @(
                @{
                    url = 'https://github.com/example/project'
                    workers = 2
                })
            replicas = $null
        } | ConvertTo-Json -Depth 20)
    Write-Utf8 `
        -Path (Join-Path $profileRoot 'acknowledged-capacity.json') `
        -Content (@{
            schemaVersion = 1
            status = 'accepted'
            generation = 4
            managerContractVersion = 18
            desiredStateHash = ('a' * 64)
            observedAt = '2026-08-07T08:59:55Z'
            desiredSlots = 2
            addedSlots = 1
            drainingSlots = 0
            unchangedSlots = 1
        } | ConvertTo-Json -Depth 20)
    Write-Utf8 `
        -Path (Join-Path $profileRoot 'static-profile.json') `
        -Content (@{
            schemaVersion = 1
            fingerprint = ('b' * 64)
            workerRevision = ('c' * 64)
            manifest = $null
            configuration = @{
                managerContractVersion = 18
                workerRuntimeContractVersion = 1
                profile = 'default'
                image = 'ghcr.io/example/worker:1.0.0'
                resolvedImageId = 'sha256:' + ('d' * 64)
                pullImage = $true
                scope = 'repo'
                autoscaling = $null
                resources = @{
                    memoryBytes = 2147483648
                    memorySwapBytes = 4294967296
                    cpuCores = '2'
                    pids = 1024
                }
            }
        } | ConvertTo-Json -Depth 20)
    Write-Utf8 `
        -Path (Join-Path $profileRoot 'observed-state.json') `
        -Content (@{
            schemaVersion = 1
            managerContractVersion = 18
            profileId = 'default'
            managerStatus = 'running'
            observedAt = '2026-08-07T09:00:00Z'
            scope = 'repo'
            generation = 4
            desiredStateStatus = 'accepted'
            desiredSlots = 2
            configuredSlots = 2
            activeSlots = 1
            eligibleSlots = 1
            drainingSlots = 0
            slots = @(
                @{
                    key = 'slot-1'
                    repository = 'https://github.com/example/project'
                    desired = $true
                    processRunning = $true
                    state = 'online'
                    activity = 'busy'
                    registrationStatus = 'connected'
                    target = 'https://github.com/example/project'
                    currentJob = @{
                        repository = 'https://github.com/example/project'
                        workflowRunId = 123
                        jobId = '456'
                        displayName = 'build'
                        eventName = 'push'
                        startedAt = '2026-08-07T08:58:00Z'
                        finishedAt = $null
                        result = $null
                    }
                })
            autoscaling = $null
            update = @{
                status = 'current'
                targetImage = 'ghcr.io/example/worker:1.0.0'
                targetImageId = 'sha256:' + ('d' * 64)
                targetRevision = ('c' * 64)
                currentWorkers = 1
                staleWorkers = 0
                lastError = 'C:\synthetic\REMOTE_DIAGNOSTICS_MANAGER_ERROR_SENTINEL'
            }
            resourceTelemetry = @{
                hostPressure = @{
                    state = 'healthy'
                    observedAt = '2026-08-07T09:00:00Z'
                    summary = 'within-policy'
                }
            }
            hostAdmission = @{
                status = 'available'
                namespace = 'shared-ci'
                epoch = 3
                decisionSequence = 9
                capacityUnits = 10
                safetyMarginUnits = 2
                effectiveTotalUnits = 8
                availableUnits = 0
                hostPolicyFingerprint = ('e' * 64)
                accounting = @{
                    unitCost = 2
                    reservedUnits = 2
                    borrowable = $false
                    profilePolicyFingerprint = ('f' * 64)
                    activeUnits = 2
                    provisionalUnits = 0
                    heldUnits = 2
                    borrowedUnits = 0
                    pendingUnits = 2
                    withheldUnits = 2
                }
                lastDecision = @{
                    sequence = 9
                    command = 'acquire'
                    granted = $false
                    failureCategory = 'budget-exceeded'
                    decidedAtUnixNano = 1786093200000000000
                }
            }
            capacityEvidence = @{
                fixed = $null
                targets = @(
                    @{
                        key = 'repo:acme/private-repository'
                        repository =
                            'https://github.com/acme/private-repository'
                        observedAt = '2026-08-07T09:00:00Z'
                        freshness = 'current'
                        targetSlots = 2
                        activeWorkers = 1
                        startingWorkers = 0
                        drainingWorkers = 0
                        cleanupPendingWorkers = 0
                        eligibleWorkers = 1
                        localDeficit = 1
                        eligibilityDeficit = 1
                        reason = 'host-admission-withheld'
                        evidence = 'Host admission withheld one worker'
                    })
            }
        } | ConvertTo-Json -Depth 30)

    $healthRoot = Join-Path $programData 'PitCrew' 'Connector' 'health'
    Write-Utf8 `
        -Path (Join-Path $healthRoot 'connector-health.json') `
        -Content (@{
            schemaVersion = 1
            state = 'degraded'
            processStartedAt = '2026-08-07T08:00:00Z'
            updatedAt = '2026-08-07T09:00:00Z'
            lastAttemptAt = '2026-08-07T09:00:00Z'
            lastSuccessAt = '2026-08-07T08:55:00Z'
            activeOutageId = '11111111-1111-1111-1111-111111111111'
            activeOutageStartedAt = '2026-08-07T08:56:00Z'
            lastFailureAt = '2026-08-07T09:00:00Z'
            lastFailureCategory = 'synchronization-network'
            lastFailureProfileId = $null
            lastFailureDetail = 'Connector synchronization could not reach Dashboard.'
            consecutiveFailures = 3
            nextRetryAt = '2026-08-07T09:05:00Z'
            lastRecoveredOutageId = $null
            lastRecoveredOutageStartedAt = $null
            lastRecoveredAt = $null
            lastRecoveredFailureCategory = $null
        } | ConvertTo-Json -Depth 20)
    $event = @{
        schemaVersion = 1
        eventId = '22222222-2222-2222-2222-222222222222'
        kind = 'synchronization-failed'
        occurredAt = '2026-08-07T09:00:00Z'
        state = 'degraded'
        outageId = '11111111-1111-1111-1111-111111111111'
        outageStartedAt = '2026-08-07T08:56:00Z'
        failureCategory = 'synchronization-network'
        profileId = $null
        consecutiveFailures = 3
        retryDelaySeconds = 300
        detail = 'Connector synchronization could not reach Dashboard.'
    } | ConvertTo-Json -Compress
    Write-Utf8 `
        -Path (Join-Path $healthRoot 'connector-events.jsonl') `
        -Content "$event`n"
    Write-Utf8 `
        -Path (Join-Path $programData 'PitCrew' 'Connector' 'identity.json') `
        -Content '{"credential":"REMOTE_DIAGNOSTICS_IDENTITY_SENTINEL"}'

    $dockerScript = @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CommandArguments
)
$ErrorActionPreference = 'Stop'
Add-Content -LiteralPath $env:PITCREW_TEST_COMMAND_LOG -Value ("docker`t" + ($CommandArguments -join "`t"))
$joined = $CommandArguments -join ' '
if ($CommandArguments[0] -eq 'ps' -and $joined -match 'ephemeral-runner-manager-profile') {
    'aaaaaaaaaaaa|ephemeral-runner-manager:profile-default|Up 5 minutes'
    exit 0
}
if ($CommandArguments[0] -eq 'ps' -and $joined -match 'ephemeral-managed-runner-profile') {
    'bbbbbbbbbbbb|ghcr.io/example/worker:1.0.0|Up 4 minutes|slot-1|cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
    exit 0
}
if ($CommandArguments[0] -eq 'image' -and $CommandArguments[1] -eq 'inspect') {
    if ($CommandArguments[2] -match 'manager') {
        'sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee|["example/manager@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]'
    } else {
        'sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd|["ghcr.io/example/worker@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"]'
    }
    exit 0
}
if ($CommandArguments[0] -eq 'inspect' -and $CommandArguments -contains '--size') {
    'sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd|1024|2048'
    exit 0
}
if ($CommandArguments[0] -eq 'stats') {
    foreach ($id in $CommandArguments | Where-Object { $_ -match '^[ab]{12}$' }) {
        "$id|12.5%|128MiB / 2GiB|9|1MiB / 2MiB|3MiB / 4MiB"
    }
    exit 0
}
if ($CommandArguments[0] -eq 'system' -and $CommandArguments[1] -eq 'df') {
    '{"Type":"Images","TotalCount":"2","Active":"2","Size":"3GB","Reclaimable":"0B"}'
    '{"Type":"Containers","TotalCount":"2","Active":"2","Size":"2MB","Reclaimable":"0B"}'
    exit 0
}
if ($CommandArguments[0] -eq 'info') {
    '/var/lib/docker|Fixture Linux|28.0.0'
    exit 0
}
if ($CommandArguments[0] -eq 'network') {
    'network-one'
    'network-two'
    exit 0
}
if ($CommandArguments[0] -eq 'run') {
    $cidIndex = [Array]::IndexOf($CommandArguments, '--cidfile')
    Set-Content -LiteralPath $CommandArguments[$cidIndex + 1] -Value 'cccccccccccc' -NoNewline
    '200 192.0.2.20 0.010 0.020 0.030 0.040 0.500 1000 2000'
    exit 0
}
if ($CommandArguments[0] -eq 'inspect' -and $CommandArguments[1] -eq 'cccccccccccc') {
    $env:PITCREW_TEST_SESSION_ID
    exit 0
}
if ($CommandArguments[0] -eq 'rm' -and $CommandArguments[1] -eq '--force' -and $CommandArguments[2] -eq 'cccccccccccc') {
    'cccccccccccc'
    exit 0
}
exit 1
'@
    Write-Utf8 `
        -Path (Join-Path $fakeBin 'docker.ps1') `
        -Content $dockerScript
    Write-Utf8 `
        -Path (Join-Path $fakeBin 'curl.ps1') `
        -Content @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CommandArguments
)
Add-Content -LiteralPath $env:PITCREW_TEST_COMMAND_LOG -Value ("curl`t" + ($CommandArguments -join "`t"))
'200 192.0.2.10 0.010 0.020 0.030 0.040 0.250 1000 4000'
'@
    Write-Utf8 `
        -Path (Join-Path $fakeBin 'git.ps1') `
        -Content @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CommandArguments
)
Add-Content -LiteralPath $env:PITCREW_TEST_COMMAND_LOG -Value ("git`t" + ($CommandArguments -join "`t"))
'v0.6.0'
'@
    Write-Utf8 `
        -Path (Join-Path $fakeBin 'gh.ps1') `
        -Content @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CommandArguments
)
Add-Content -LiteralPath $env:PITCREW_TEST_COMMAND_LOG -Value ("gh`t" + ($CommandArguments -join "`t"))
$joined = $CommandArguments -join ' '
if ($CommandArguments[0] -eq 'api' -and $joined -match '/actions/runs/123$') {
    '{"id":123,"status":"in_progress","conclusion":null,"created_at":"2026-08-07T08:50:00Z","updated_at":"2026-08-07T08:59:00Z","html_url":"https://github.com/example/project/actions/runs/123"}'
    exit 0
}
if ($CommandArguments[0] -eq 'api' -and $joined -match '/actions/jobs/456$') {
    '{"id":456,"name":"build","status":"in_progress","conclusion":null,"started_at":"2026-08-07T08:58:00Z","completed_at":null,"html_url":"https://github.com/example/project/actions/runs/123/job/456"}'
    exit 0
}
if ($CommandArguments[0] -eq 'release' -and $joined -match 'ncosentino/pitcrew-dashboard') {
    '{"tagName":"v0.8.0","publishedAt":"2026-08-06T15:30:00Z","url":"https://github.com/ncosentino/pitcrew-dashboard/releases/tag/v0.8.0"}'
    exit 0
}
if ($CommandArguments[0] -eq 'release' -and $joined -match 'ncosentino/pitcrew') {
    '{"tagName":"v0.6.0","publishedAt":"2026-08-06T15:28:00Z","url":"https://github.com/ncosentino/pitcrew/releases/tag/v0.6.0"}'
    exit 0
}
exit 1
'@
    Write-Utf8 `
        -Path (Join-Path $fakeBin 'df.ps1') `
        -Content @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CommandArguments
)
Add-Content -LiteralPath $env:PITCREW_TEST_COMMAND_LOG -Value ("df`t" + ($CommandArguments -join "`t"))
if ($CommandArguments[0] -eq '-Pi') {
    'Filesystem Inodes IUsed IFree IUse% Mounted on'
    '/dev/fake 100000 1000 99000 1% /var/lib/docker'
} else {
    'Filesystem 1024-blocks Used Available Capacity Mounted on'
    '/dev/fake 1000000 100000 900000 10% /var/lib/docker'
}
'@
    $env:PATH = "$fakeBin$([IO.Path]::PathSeparator)$originalPath"
    $env:ProgramData = $programData
    $env:PITCREW_TEST_COMMAND_LOG = $commandLog
    Write-Utf8 -Path $commandLog -Content ''

    Write-Host 'Remote diagnostics test: remote-first preflight'
    $preflightPath = Join-Path $tempRoot 'preflight.json'
    $preflightResult = & $preflightScript `
        -DiagnosticMode ConnectorOffline `
        -PublicDashboardUrl http://127.0.0.1:1 `
        -GitHubRunUrl https://github.com/example/project/actions/runs/123/job/456 `
        -DashboardNodeId '33333333-3333-3333-3333-333333333333' `
        -DashboardNodeStatus offline `
        -DashboardNodeLastSeenAt '2026-08-07T01:58:00-07:00' `
        -DashboardIncident connector-offline `
        -OutputPath $preflightPath
    $preflightJson = Get-Content `
        -LiteralPath $preflightPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 50
    Add-Check (
        $preflightJson.github.runId -eq '123' -and
        $preflightJson.github.job.jobId -eq '456'
    ) 'The remote-first preflight did not capture bounded GitHub run and job metadata.'
    Add-Check (
        $preflightJson.releases.pitcrew.tagName -eq 'v0.6.0' -and
        $preflightJson.releases.dashboard.tagName -eq 'v0.8.0'
    ) 'The remote-first preflight did not capture published release evidence.'
    Add-Check (
        @($preflightJson.unavailableEvidence |
                Where-Object category -eq 'public-dashboard-endpoint').Count -eq 1
    ) 'The preflight did not mark a failed bounded public endpoint probe as unavailable.'
    Add-Check (
        $preflightJson.dashboard.publicEndpoint.reachable -eq $false
    ) 'The preflight reported a refused loopback endpoint as reachable.'
    Add-Check (
        ([DateTimeOffset]$preflightJson.dashboard.lastSeenAt) -eq
            [DateTimeOffset]'2026-08-07T08:58:00Z'
    ) 'The preflight did not preserve an explicit Dashboard timestamp in UTC.'

    Write-Host 'Remote diagnostics test: minimal preflight'
    $minimalPreflightPath = Join-Path $tempRoot 'preflight-minimal.json'
    $null = & $preflightScript `
        -DiagnosticMode HostPressure `
        -OutputPath $minimalPreflightPath
    $minimalPreflightJson = Get-Content `
        -LiteralPath $minimalPreflightPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 50
    Add-Check (
        $null -eq $minimalPreflightJson.dashboard.lastSeenAt
    ) 'The preflight did not preserve an omitted Dashboard timestamp as null.'
    Add-Check (
        @($minimalPreflightJson.unavailableEvidence |
                Where-Object category -eq 'public-dashboard-endpoint').Count -eq 1 -and
        @($minimalPreflightJson.unavailableEvidence |
                Where-Object category -eq 'github-actions').Count -eq 1
    ) 'The minimal preflight did not record omitted remote evidence as unavailable.'
    $minimalPlanOutput = Join-Path `
        $outputRoot `
        'minimal-plan-should-not-exist'
    $minimalPlan = & $orchestrator `
        -ExecutionMode Package `
        -PitCrewRoot 'C:\PitCrew' `
        -Profile default `
        -DiagnosticMode HostPressure `
        -PreflightPath $minimalPreflightPath `
        -OutputDirectory $minimalPlanOutput `
        -PlanOnly
    Add-Check (
        $minimalPlan.transport.type -eq 'agent-handoff' -and
        $minimalPlan.diagnosticMode -eq 'HostPressure'
    ) 'The minimal preflight could not be consumed by package plan mode.'
    Add-Check (
        -not (Test-Path -LiteralPath $minimalPlanOutput)
    ) 'Minimal package plan mode wrote output instead of remaining dry.'

    $beforeHashes = Get-FixtureHashes -Path $fixtureRoot
    Write-Host 'Remote diagnostics test: Windows collector'
    $windowsPackageId = '11111111111111111111111111111111'
    $env:PITCREW_TEST_SESSION_ID = $windowsPackageId
    $windowsOutput = Join-Path $outputRoot 'windows'
    $windowsArtifacts = & $collector `
        -PitCrewRoot $fixtureRoot `
        -Profile default `
        -DiagnosticMode ConnectorOffline `
        -Platform Windows `
        -PackageId $windowsPackageId `
        -OutputDirectory $windowsOutput
    $windowsReport = Get-Content `
        -LiteralPath $windowsArtifacts.jsonPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 100
    Add-Check (
        $windowsReport.platform -eq 'Windows'
    ) 'The collector did not execute its Windows evidence branch.'
    Add-Check (
        $windowsReport.verifiedMeasurements.connectorHealth.snapshot.state -eq
            'degraded'
    ) 'The Windows collector did not import the connector health snapshot.'
    Add-Check (
        $windowsReport.verifiedMeasurements.connectorHealth.events.Count -eq 1
    ) 'The Windows collector did not import the bounded connector event journal.'
    $windowsText = (
        Get-Content -LiteralPath $windowsArtifacts.jsonPath -Raw -Encoding UTF8) +
        (Get-Content -LiteralPath $windowsArtifacts.markdownPath -Raw -Encoding UTF8)
    foreach ($sentinel in @(
            'REMOTE_DIAGNOSTICS_SECRET_SENTINEL',
            'REMOTE_DIAGNOSTICS_JOB_OUTPUT_SENTINEL',
            'REMOTE_DIAGNOSTICS_IDENTITY_SENTINEL',
            'REMOTE_DIAGNOSTICS_MANAGER_ERROR_SENTINEL',
            $fixtureRoot)) {
        Add-Check (
            $windowsText -notmatch [regex]::Escape($sentinel)
        ) "The Windows collector leaked '$sentinel'."
    }

    Write-Host 'Remote diagnostics test: Linux collector'
    $linuxPackageId = '22222222222222222222222222222222'
    $env:PITCREW_TEST_SESSION_ID = $linuxPackageId
    $linuxOutput = Join-Path $outputRoot 'linux'
    $linuxArtifacts = & $collector `
        -PitCrewRoot $fixtureRoot `
        -Profile default `
        -DiagnosticMode Full `
        -Platform Linux `
        -ApprovedUrl https://example.test/artifact `
        -ProbeTimeoutSeconds 60 `
        -PackageId $linuxPackageId `
        -OutputDirectory $linuxOutput
    $linuxReport = Get-Content `
        -LiteralPath $linuxArtifacts.jsonPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 100
    Add-Check (
        $linuxReport.platform -eq 'Linux'
    ) 'The collector did not execute its Linux evidence branch.'
    Add-Check (
        $linuxReport.verifiedMeasurements.containers.workers.Count -eq 1
    ) 'The Linux collector did not preserve exact-label worker inventory.'
    Add-Check (
        $linuxReport.verifiedMeasurements.capacity[0].mismatch -eq $false
    ) 'The Linux collector reported a false live-versus-registered mismatch.'
    Add-Check (
        $linuxReport.verifiedMeasurements.state.observed.hostAdmission.status -eq
            'available' -and
        $linuxReport.verifiedMeasurements.state.observed.hostAdmission.accounting.withheldUnits -eq
            2
    ) 'The collector omitted contract-18 host-admission accounting.'
    Add-Check (
        $linuxReport.verifiedMeasurements.state.observed.capacityEvidence.targets[0].reason -eq
            'host-admission-withheld'
    ) 'The collector omitted admission-specific capacity-deficit evidence.'
    $privateTarget = 'repo:acme/private-repository'
    $privateRepositoryUrl =
        'https://github.com/acme/private-repository'
    Add-Check (
        $linuxReport.verifiedMeasurements.state.observed.capacityEvidence.targets[0].keyHash -eq
            (Get-PitCrewRemoteDiagnosticsTextSha256 -Value $privateTarget) -and
        $null -eq
            $linuxReport.verifiedMeasurements.state.observed.capacityEvidence.targets[0].PSObject.Properties['repository'] -and
        ($linuxReport | ConvertTo-Json -Depth 100) -notmatch
            [regex]::Escape($privateRepositoryUrl)
    ) 'The collector retained a private capacity target identity.'
    Add-Check (
        @($linuxReport.verifiedMeasurements.urlProbes).Count -eq 2
    ) 'The Linux collector did not produce one host and one container URL sample.'
    Add-Check (
        @($linuxReport.verifiedMeasurements.urlProbes |
                Where-Object status -ne 'completed').Count -eq 0
    ) 'The fake paired URL samples did not complete.'
    $commandText = Get-Content -LiteralPath $commandLog -Raw -Encoding UTF8
    Add-Check (
        $commandText -match 'label=ephemeral-runner-manager-profile=default' -and
        $commandText -match 'label=ephemeral-managed-runner-profile=default'
    ) 'The collector did not scope Docker inventory by exact PitCrew labels.'
    Add-Check (
        $commandText -match 'docker\trm\t--force\tcccccccccccc'
    ) 'The collector did not clean only its exact labelled diagnostic container.'
    Add-Check (
        $commandText -match '--pull=never\t--entrypoint\tcurl\tsha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' -and
        $commandText -match '--disable' -and
        $commandText -match '--max-redirs\t0' -and
        $commandText -notmatch '--location'
    ) 'The container probe could pull or execute a worker entrypoint, or a probe could follow an unapproved redirect.'
    Add-Check (
        $commandText -notmatch '(?i)(\texec\t|\tprune\t|\tstop\t|\tkill\t|system\tprune)'
    ) 'The collector invoked a prohibited Docker operation.'
    $afterHashes = Get-FixtureHashes -Path $fixtureRoot
    Add-Check (
        Test-HashMapsEqual -Expected $beforeHashes -Actual $afterHashes
    ) 'The collector mutated the PitCrew fixture or secret sentinels.'

    Write-Host 'Remote diagnostics test: contract-17 missing registration evidence'
    $legacyFixtureRoot = Join-Path $tempRoot 'pitcrew-contract17'
    Copy-Item `
        -LiteralPath $fixtureRoot `
        -Destination $legacyFixtureRoot `
        -Recurse
    $legacyProfileRoot = Join-Path `
        $legacyFixtureRoot `
        '.pitcrew-state' `
        'default'
    $legacyAcknowledgedPath = Join-Path `
        $legacyProfileRoot `
        'acknowledged-capacity.json'
    $legacyAcknowledged = Get-Content `
        -LiteralPath $legacyAcknowledgedPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 30
    $legacyAcknowledged.managerContractVersion = 17
    Write-Utf8 `
        -Path $legacyAcknowledgedPath `
        -Content ($legacyAcknowledged | ConvertTo-Json -Depth 30)
    $legacyStaticPath = Join-Path $legacyProfileRoot 'static-profile.json'
    $legacyStatic = Get-Content `
        -LiteralPath $legacyStaticPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 30
    $legacyStatic.configuration.managerContractVersion = 17
    Write-Utf8 `
        -Path $legacyStaticPath `
        -Content ($legacyStatic | ConvertTo-Json -Depth 30)
    $legacyObservedPath = Join-Path $legacyProfileRoot 'observed-state.json'
    $legacyObserved = Get-Content `
        -LiteralPath $legacyObservedPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 50
    $legacyObserved.managerContractVersion = 17
    $legacyObserved.slots[0].PSObject.Properties.Remove(
        'registrationStatus')
    $legacyObserved.PSObject.Properties.Remove('hostAdmission')
    $legacyObserved.PSObject.Properties.Remove('capacityEvidence')
    Write-Utf8 `
        -Path $legacyObservedPath `
        -Content ($legacyObserved | ConvertTo-Json -Depth 50)
    $legacyPackageId = '33333333333333333333333333333333'
    $env:PITCREW_TEST_SESSION_ID = $legacyPackageId
    $legacyOutput = Join-Path $outputRoot 'contract17'
    $legacyArtifacts = & $collector `
        -PitCrewRoot $legacyFixtureRoot `
        -Profile default `
        -DiagnosticMode CapacityMismatch `
        -Platform Windows `
        -PackageId $legacyPackageId `
        -OutputDirectory $legacyOutput
    $legacyReport = Get-Content `
        -LiteralPath $legacyArtifacts.jsonPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 100
    $legacyCapacity = @(
        $legacyReport.verifiedMeasurements.capacity)[0]
    Add-Check (
        $legacyCapacity.observedSlots -eq 1 -and
        $null -eq $legacyCapacity.registeredWorkers -and
        $null -eq $legacyCapacity.mismatch
    ) 'The collector fabricated registration reconciliation when contract-17 evidence was absent.'
    $legacySummary =
        ConvertTo-PitCrewRemoteDiagnosticsReportSummary -Report $legacyReport
    $legacySummaryCapacity = @(
        $legacySummary.verifiedMeasurements.capacity)[0]
    Add-Check (
        $null -eq $legacySummaryCapacity.registeredWorkers -and
        $null -eq $legacySummaryCapacity.mismatch
    ) 'The strict remote-diagnostics projection converted unavailable registration evidence to zero or false.'

    Write-Host 'Remote diagnostics test: explicit transport envelopes'
    . $coreScript
    . $transportScript
    $collectorSource = Get-Content `
        -LiteralPath $collector `
        -Raw `
        -Encoding UTF8
    $collectorSha256 = Get-PitCrewRemoteDiagnosticsSha256 $collector
    $transportArgumentsJson = @{
        PitCrewRoot = $fixtureRoot
        Profile = 'default'
        DiagnosticMode = 'ConnectorOffline'
        Platform = 'Windows'
        ApprovedUrl = @()
        ProbeTimeoutSeconds = 60
        PackageId = '44444444444444444444444444444444'
        PassThruOnly = $true
    } | ConvertTo-Json -Depth 20 -Compress
    $transportInvoker = {
        param(
            [string]$Mode,
            [scriptblock]$RemoteRunner,
            [string]$Source,
            [string]$ArgumentsJson
        )

        & $RemoteRunner $Source $ArgumentsJson
    }
    $sshEnvelope = Invoke-PitCrewCollectorTransport `
        -ExecutionMode Ssh `
        -CollectorSource $collectorSource `
        -ArgumentsJson $transportArgumentsJson `
        -SshHostName zephyr.example `
        -SshUserName operator `
        -TransportInvoker $transportInvoker
    $sshTransportOutput = Join-Path $outputRoot 'ssh-transport'
    $sshArtifacts = Complete-PitCrewCollectorTransport `
        -Envelope $sshEnvelope `
        -CollectorSha256 $collectorSha256 `
        -OutputDirectory $sshTransportOutput
    $sshReportText = Get-Content `
        -LiteralPath $sshArtifacts.jsonPath `
        -Raw `
        -Encoding UTF8
    $sshReport = $sshReportText | ConvertFrom-Json -Depth 100
    Add-Check (
        $sshReport.collectorSha256 -eq $collectorSha256 -and
        $sshReportText -notmatch 'PSComputerName|RunspaceId|PSShowComputerName'
    ) 'The SSH transport envelope did not attest the collector or strip remoting host metadata.'
    $winRMEnvelope = Invoke-PitCrewCollectorTransport `
        -ExecutionMode WinRM `
        -CollectorSource $collectorSource `
        -ArgumentsJson $transportArgumentsJson `
        -WinRMComputerName fixture-node.example `
        -TransportInvoker $transportInvoker
    Add-Check (
        $winRMEnvelope.report.packageId -eq
            '44444444444444444444444444444444'
    ) 'The WinRM transport envelope did not preserve the fixed collector result.'

    Write-Host 'Remote diagnostics test: deterministic package'
    $packageOutput = Join-Path $outputRoot 'packages'
    $firstPackage = & $packageScript `
        -TargetPitCrewRoot $fixtureRoot `
        -Profile default `
        -DiagnosticMode ConnectorOffline `
        -OutputDirectory $packageOutput
    $firstHash = (
        Get-FileHash -LiteralPath $firstPackage.zipPath -Algorithm SHA256).Hash
    $secondPackage = & $packageScript `
        -TargetPitCrewRoot $fixtureRoot `
        -Profile default `
        -DiagnosticMode ConnectorOffline `
        -OutputDirectory $packageOutput
    $secondHash = (
        Get-FileHash -LiteralPath $secondPackage.zipPath -Algorithm SHA256).Hash
    Add-Check (
        $firstPackage.packageId -eq $secondPackage.packageId -and
        $firstHash -eq $secondHash
    ) 'Equivalent handoff inputs did not produce a deterministic package and checksum.'
    $differentRootPackage = & $packageScript `
        -TargetPitCrewRoot "$fixtureRoot-other" `
        -Profile default `
        -DiagnosticMode ConnectorOffline `
        -OutputDirectory $packageOutput
    Add-Check (
        $differentRootPackage.packageId -ne $firstPackage.packageId
    ) 'Different target installation roots reused the same package identity.'

    Write-Host 'Remote diagnostics test: release assets'
    $releaseOutput = Join-Path $outputRoot 'release-assets'
    $releaseAssets = & $releaseAssetScript `
        -OutputDirectory $releaseOutput
    $sourceCollectorHash = (
        Get-FileHash -LiteralPath $collector -Algorithm SHA256).Hash.ToLowerInvariant()
    $releaseChecksum = (
        Get-Content `
            -LiteralPath $releaseAssets.checksumPath `
            -Raw `
            -Encoding UTF8).Split(
                ' ',
                [StringSplitOptions]::RemoveEmptyEntries)[0]
    Add-Check (
        $releaseAssets.sha256 -eq $sourceCollectorHash -and
        $releaseChecksum -eq $sourceCollectorHash
    ) 'The staged release collector or SHA-256 sidecar does not match the plugin collector.'

    Write-Host 'Remote diagnostics test: package collect import'
    $expandedPackage = Join-Path $tempRoot 'expanded-package'
    Expand-Archive `
        -LiteralPath $firstPackage.zipPath `
        -DestinationPath $expandedPackage
    $packageManifest = Get-Content `
        -LiteralPath (Join-Path $expandedPackage 'manifest.json') `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 20
    $agentPrompt = Get-Content `
        -LiteralPath (Join-Path $expandedPackage 'AGENT-PROMPT.md') `
        -Raw `
        -Encoding UTF8
    Add-Check (
        $agentPrompt -match [regex]::Escape($firstPackage.packageId) -and
        $agentPrompt -match 'Diagnostic mode: ConnectorOffline' -and
        $agentPrompt -notmatch '\$packageId|\$DiagnosticMode'
    ) 'The generated agent prompt did not embed its package correlation values.'
    Add-Check (
        (Get-FileHash `
            -LiteralPath (Join-Path $expandedPackage 'Collect-PitCrewDiagnostics.ps1') `
            -Algorithm SHA256).Hash.ToLowerInvariant() -eq
            $packageManifest.collectorSha256
    ) 'The handoff bundle collector does not match its manifest checksum.'
    $env:PITCREW_TEST_SESSION_ID = $firstPackage.packageId
    & (Join-Path $expandedPackage 'Invoke-Collection.ps1') | Out-Null
    $returnedZip = Join-Path $tempRoot 'returned-results.zip'
    Compress-Archive `
        -LiteralPath @(
            (Join-Path $expandedPackage 'results' 'pitcrew-diagnostics.json'),
            (Join-Path $expandedPackage 'results' 'pitcrew-diagnostics.md'),
            (Join-Path $expandedPackage 'results' 'result-manifest.json')) `
        -DestinationPath $returnedZip
    $diagnosisOutput = Join-Path $outputRoot 'imported'
    $diagnosis = & $importScript `
        -InputPath $returnedZip `
        -ExpectedPackageId $firstPackage.packageId `
        -ExpectedCollectorSha256 $packageManifest.collectorSha256 `
        -PreflightPath $preflightPath `
        -OutputDirectory $diagnosisOutput
    Add-Check (
        Test-Path -LiteralPath $diagnosis.diagnosisJsonPath -PathType Leaf
    ) 'The package-to-collect-to-import flow produced no JSON diagnosis.'
    Add-Check (
        Test-Path -LiteralPath $diagnosis.diagnosisMarkdownPath -PathType Leaf
    ) 'The package-to-collect-to-import flow produced no Markdown diagnosis.'
    $diagnosisJson = Get-Content `
        -LiteralPath $diagnosis.diagnosisJsonPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 100
    Add-Check (
        ([DateTimeOffset]$diagnosisJson.correlation.preflightCapturedAt) -eq
            ([DateTimeOffset]$preflightResult.capturedAt)
    ) 'The importer did not correlate the preflight timestamp.'
    Add-Check (
        $diagnosisJson.verifiedMeasurements.host.state.hostAdmissionStatus -ceq
            'available'
    ) 'The imported diagnosis did not surface the bounded host admission status.'
    $diagnosedAdmission =
        $diagnosisJson.verifiedMeasurements.host.state.hostAdmission
    Add-Check (
        $diagnosedAdmission.namespace -eq 'shared-ci' -and
        $diagnosedAdmission.epoch -eq 3 -and
        $diagnosedAdmission.decisionSequence -eq 9 -and
        $diagnosedAdmission.accounting.unitCost -eq 2 -and
        $diagnosedAdmission.accounting.reservedUnits -eq 2 -and
        $diagnosedAdmission.accounting.heldUnits -eq 2 -and
        $diagnosedAdmission.accounting.withheldUnits -eq 2 -and
        $diagnosedAdmission.lastDecision.failureCategory -eq 'budget-exceeded'
    ) 'The imported diagnosis omitted the complete bounded admission contract.'
    Add-Check (
        $diagnosisJson.verifiedMeasurements.host.state.capacityEvidence.targets[0].reason -eq
            'host-admission-withheld'
    ) 'The imported diagnosis did not preserve capacity-deficit reasons.'

    $unavailableReport = $linuxReport |
        ConvertTo-Json -Depth 100 |
        ConvertFrom-Json -Depth 100
    $unavailableReport.verifiedMeasurements.state.observed.hostAdmission =
        [PSCustomObject][ordered]@{
            status = 'unavailable'
            namespace = 'shared-ci'
            epoch = $null
            decisionSequence = $null
            capacityUnits = $null
            safetyMarginUnits = $null
            effectiveTotalUnits = $null
            availableUnits = $null
            hostPolicyFingerprint = $null
            accounting = $null
            lastDecision = $null
        }
    $unavailableReport.verifiedMeasurements.state.observed.capacityEvidence =
        [PSCustomObject][ordered]@{
            fixed = $null
            targets = @(
                [PSCustomObject][ordered]@{
                    key = 'fixture-target'
                    repository = 'https://github.com/acme/private-repository'
                    observedAt = '2026-08-07T09:00:00Z'
                    freshness = 'current'
                    targetSlots = 2
                    activeWorkers = 1
                    startingWorkers = 0
                    drainingWorkers = 0
                    cleanupPendingWorkers = 0
                    eligibleWorkers = 1
                    localDeficit = 1
                    eligibilityDeficit = 1
                    reason = 'host-admission-unavailable'
                    evidence = 'Host admission evidence unavailable'
                })
        }
    $unavailableDiagnosis = New-PitCrewRemoteDiagnosticsDiagnosis `
        -Report $unavailableReport `
        -Preflight $null
    Add-Check (
        @($unavailableDiagnosis.unavailableEvidence |
            Where-Object category -eq 'host-admission').Count -eq 1 -and
        $unavailableDiagnosis.verifiedMeasurements.host.state.hostAdmission.status -eq
            'unavailable' -and
        $null -eq
            $unavailableDiagnosis.verifiedMeasurements.host.state.hostAdmission.availableUnits -and
        $unavailableDiagnosis.verifiedMeasurements.host.state.capacityEvidence.targets[0].reason -eq
            'host-admission-unavailable'
    ) 'Unavailable coordinator evidence was not preserved as unavailable.'
    Add-Check (
        $unavailableDiagnosis.verifiedMeasurements.host.state.capacityEvidence.targets[0].keyHash -eq
            (Get-PitCrewRemoteDiagnosticsTextSha256 -Value 'fixture-target') -and
        ($unavailableDiagnosis | ConvertTo-Json -Depth 100) -notmatch
            [regex]::Escape('https://github.com/acme/private-repository')
    ) 'The importer retained a private capacity target identity.'

    $structuredNamespace = $linuxReport.verifiedMeasurements.state.observed.hostAdmission |
        ConvertTo-Json -Depth 30 |
        ConvertFrom-Json -Depth 30
    $structuredNamespace.namespace = 'secret-ci'
    Add-Check (
        (
            ConvertTo-PitCrewRemoteDiagnosticsHostAdmission `
                -Admission $structuredNamespace
        ).namespace -eq 'secret-ci'
    ) 'A contract-valid structured namespace was rejected by generic secret-text filtering.'
    $newlineNamespace = $structuredNamespace |
        ConvertTo-Json -Depth 30 |
        ConvertFrom-Json -Depth 30
    $newlineNamespace.namespace = "shared-ci`n"
    Add-ThrowsCheck `
        -Action {
            ConvertTo-PitCrewRemoteDiagnosticsHostAdmission `
                -Admission $newlineNamespace |
                Out-Null
        } `
        -ExpectedMessage 'Host admission namespace is invalid.' `
        -Failure 'A namespace with trailing control data was accepted.'

    $degradedReport = $linuxReport |
        ConvertTo-Json -Depth 100 |
        ConvertFrom-Json -Depth 100
    $degradedReport.verifiedMeasurements.state.observed.hostAdmission.status =
        'degraded'
    $degradedReport.verifiedMeasurements.state.observed.hostAdmission.hostPolicyFingerprint =
        $null
    $degradedDiagnosis = New-PitCrewRemoteDiagnosticsDiagnosis `
        -Report $degradedReport `
        -Preflight $null
    Add-Check (
        @($degradedDiagnosis.unavailableEvidence |
            Where-Object category -eq 'host-admission-policy').Count -eq 1
    ) 'Degraded policy-identity evidence was not classified explicitly.'
    $missingAccountingReport = $degradedReport |
        ConvertTo-Json -Depth 100 |
        ConvertFrom-Json -Depth 100
    $missingAccountingReport.verifiedMeasurements.state.observed.hostAdmission.accounting =
        $null
    $missingAccountingDiagnosis = New-PitCrewRemoteDiagnosticsDiagnosis `
        -Report $missingAccountingReport `
        -Preflight $null
    Add-Check (
        @($missingAccountingDiagnosis.unavailableEvidence |
            Where-Object category -eq 'host-admission-policy').Count -eq 1 -and
        @($missingAccountingDiagnosis.unavailableEvidence |
            Where-Object category -eq 'host-admission-demand').Count -eq 0
    ) 'Missing profile accounting was misclassified as a demand-only gap.'

    Write-Host 'Remote diagnostics test: direct orchestrator'
    $directOutput = Join-Path $outputRoot 'direct'
    $env:PITCREW_TEST_SESSION_ID = $firstPackage.packageId
    $direct = & $orchestrator `
        -ExecutionMode Direct `
        -PitCrewRoot $fixtureRoot `
        -Profile default `
        -DiagnosticMode ConnectorOffline `
        -PreflightPath $preflightPath `
        -OutputDirectory $directOutput
    Add-Check (
        Test-Path -LiteralPath $direct.diagnosisJsonPath -PathType Leaf
    ) 'Direct orchestration did not collect and import a diagnosis.'

    Write-Host 'Remote diagnostics test: transport plans'
    $sshPlanOutput = Join-Path $outputRoot 'ssh-plan-should-not-exist'
    $sshPlan = & $orchestrator `
        -ExecutionMode Ssh `
        -PitCrewRoot 'C:\PitCrew' `
        -Profile default `
        -DiagnosticMode HostPressure `
        -SshHostName zephyr.example `
        -SshUserName operator `
        -PreflightPath $preflightPath `
        -OutputDirectory $sshPlanOutput `
        -PlanOnly
    Add-Check (
        $sshPlan.transport.type -eq 'powershell-remoting-ssh'
    ) 'SSH plan mode did not preserve the explicit transport.'
    Add-Check (
        -not (Test-Path -LiteralPath $sshPlanOutput)
    ) 'SSH plan mode wrote output or connected instead of remaining dry.'
    $winRMPlan = & $orchestrator `
        -ExecutionMode WinRM `
        -PitCrewRoot 'C:\PitCrew' `
        -Profile default `
        -DiagnosticMode CapacityMismatch `
        -WinRMComputerName fixture-node.example `
        -PreflightPath $preflightPath `
        -OutputDirectory (Join-Path $outputRoot 'winrm-plan-should-not-exist') `
        -PlanOnly
    Add-Check (
        $winRMPlan.transport.type -eq 'powershell-remoting-winrm'
    ) 'WinRM plan mode did not preserve the explicit transport.'

    Add-ThrowsCheck `
        -Action {
            & $orchestrator `
                -ExecutionMode Ssh `
                -PitCrewRoot 'C:\PitCrew' `
                -DiagnosticMode Full `
                -SshHostName 'bad host' `
                -SshUserName operator `
                -PreflightPath $preflightPath `
                -OutputDirectory (Join-Path $outputRoot 'bad-plan') `
                -PlanOnly
        } `
        -ExpectedMessage 'explicit literal SshHostName' `
        -Failure 'SSH plan mode accepted an ambiguous or shell-like host.'
    Add-ThrowsCheck `
        -Action {
            & $packageScript `
                -TargetPitCrewRoot "C:\PitCrew`nWrite-Host injected" `
                -DiagnosticMode Full `
                -OutputDirectory (Join-Path $outputRoot 'bad-root')
        } `
        -ExpectedMessage 'explicit absolute Windows or POSIX path' `
        -Failure 'The handoff package accepted a multiline or shell-like target root.'

    Write-Host 'Remote diagnostics test: tamper rejection'
    $tamperedDirectory = Join-Path $tempRoot 'tampered'
    Copy-Item `
        -LiteralPath (Join-Path $expandedPackage 'results') `
        -Destination $tamperedDirectory `
        -Recurse
    Add-Content `
        -LiteralPath (Join-Path $tamperedDirectory 'pitcrew-diagnostics.json') `
        -Value 'tampered'
    Add-ThrowsCheck `
        -Action {
            & $importScript `
                -InputPath $tamperedDirectory `
                -ExpectedPackageId $firstPackage.packageId
        } `
        -ExpectedMessage 'checksum verification failed' `
        -Failure 'The importer accepted a checksum-mismatched result.'

    $secretDirectory = Join-Path $tempRoot 'secret-bearing-result'
    Copy-Item `
        -LiteralPath (Join-Path $expandedPackage 'results') `
        -Destination $secretDirectory `
        -Recurse
    $secretReportPath = Join-Path `
        $secretDirectory `
        'pitcrew-diagnostics.json'
    $secretManifestPath = Join-Path `
        $secretDirectory `
        'result-manifest.json'
    $secretReport = Get-Content `
        -LiteralPath $secretReportPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 100
    $secretReport.hypotheses[0].evidence =
        'password=REMOTE_DIAGNOSTICS_RECOMPUTED_SECRET'
    Write-Utf8 `
        -Path $secretReportPath `
        -Content ($secretReport | ConvertTo-Json -Depth 100)
    $secretManifest = Get-Content `
        -LiteralPath $secretManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 20
    ($secretManifest.files |
        Where-Object name -eq 'pitcrew-diagnostics.json').sha256 = (
            Get-FileHash `
                -LiteralPath $secretReportPath `
                -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8 `
        -Path $secretManifestPath `
        -Content ($secretManifest | ConvertTo-Json -Depth 20)
    Add-ThrowsCheck `
        -Action {
            & $importScript `
                -InputPath $secretDirectory `
                -ExpectedPackageId $firstPackage.packageId
        } `
        -ExpectedMessage 'unsafe or unbounded text' `
        -Failure 'The importer persisted recomputed secret-bearing evidence under an allowed property name.'

    $invalidOutageDirectory = Join-Path $tempRoot 'invalid-outage-result'
    Copy-Item `
        -LiteralPath $windowsOutput `
        -Destination $invalidOutageDirectory `
        -Recurse
    $invalidOutageReportPath = Join-Path `
        $invalidOutageDirectory `
        'pitcrew-diagnostics.json'
    $invalidOutageManifestPath = Join-Path `
        $invalidOutageDirectory `
        'result-manifest.json'
    $invalidOutageReport = Get-Content `
        -LiteralPath $invalidOutageReportPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 100
    $invalidOutageReport.verifiedMeasurements.connectorHealth.snapshot.activeOutageId =
        'secret=REMOTE_DIAGNOSTICS_OUTAGE_SENTINEL'
    Write-Utf8 `
        -Path $invalidOutageReportPath `
        -Content ($invalidOutageReport | ConvertTo-Json -Depth 100)
    $invalidOutageManifest = Get-Content `
        -LiteralPath $invalidOutageManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 20
    ($invalidOutageManifest.files |
        Where-Object name -eq 'pitcrew-diagnostics.json').sha256 = (
            Get-FileHash `
                -LiteralPath $invalidOutageReportPath `
                -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8 `
        -Path $invalidOutageManifestPath `
        -Content ($invalidOutageManifest | ConvertTo-Json -Depth 20)
    Add-ThrowsCheck `
        -Action {
            & $importScript `
                -InputPath $invalidOutageDirectory `
                -ExpectedPackageId $windowsPackageId
        } `
        -ExpectedMessage 'not a GUID' `
        -Failure 'The importer persisted an unvalidated connector outage identifier.'

    $traversalZip = Join-Path $tempRoot 'traversal-results.zip'
    Add-Type -AssemblyName System.IO.Compression
    $traversalStream = [IO.File]::Open(
        $traversalZip,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
    $traversalArchive = [IO.Compression.ZipArchive]::new(
        $traversalStream,
        [IO.Compression.ZipArchiveMode]::Create,
        $false)
    try {
        $entry = $traversalArchive.CreateEntry('../escape.txt')
        $entryStream = $entry.Open()
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes('escape')
            $entryStream.Write($bytes, 0, $bytes.Length)
        } finally {
            $entryStream.Dispose()
        }
    } finally {
        $traversalArchive.Dispose()
        $traversalStream.Dispose()
    }
    Add-ThrowsCheck `
        -Action {
            & $importScript -InputPath $traversalZip
        } `
        -ExpectedMessage 'unsupported entry' `
        -Failure 'The importer accepted a path-traversal archive entry.'
    Add-Check (
        -not (Test-Path -LiteralPath (Join-Path $tempRoot 'escape.txt'))
    ) 'The importer wrote a path-traversal archive entry outside its run-scoped directory.'

    $linkedRoot = Join-Path $tempRoot 'linked-pitcrew'
    $null = New-Item -ItemType Directory -Path $linkedRoot
    foreach ($requiredFile in @(
            'Setup-Runner.ps1',
            'RunnerProfiles.Functions.ps1',
            'docker-compose.yml')) {
        Copy-Item `
            -LiteralPath (Join-Path $fixtureRoot $requiredFile) `
            -Destination (Join-Path $linkedRoot $requiredFile)
    }
    $linkedStatePath = Join-Path $linkedRoot '.pitcrew-state'
    $linkType = if ($IsWindows) {
        'Junction'
    } else {
        'SymbolicLink'
    }
    $null = New-Item `
        -ItemType $linkType `
        -Path $linkedStatePath `
        -Target (Join-Path $fixtureRoot '.pitcrew-state')
    Add-ThrowsCheck `
        -Action {
            & $collector `
                -PitCrewRoot $linkedRoot `
                -Profile default `
                -DiagnosticMode ConnectorOffline `
                -PackageId '55555555555555555555555555555555' `
                -PassThruOnly
        } `
        -ExpectedMessage 'Linked PitCrew state directories are not supported.' `
        -Failure 'The collector followed a linked PitCrew state parent.'
    Remove-Item -LiteralPath $linkedStatePath -Force
} finally {
    $env:PATH = $originalPath
    $env:ProgramData = $originalProgramData
    $env:PITCREW_TEST_COMMAND_LOG = $originalCommandLog
    $env:PITCREW_TEST_SESSION_ID = $originalSessionId
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if ($errors.Count -gt 0) {
    foreach ($failure in $errors) {
        Write-Host "ERROR: $failure" -ForegroundColor Red
    }
    throw "Remote diagnostics validation failed with $($errors.Count) error(s)."
}

Write-Host "Remote diagnostics validation passed: $checks assertions." -ForegroundColor Green
