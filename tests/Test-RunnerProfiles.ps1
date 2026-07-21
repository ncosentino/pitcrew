#Requires -Version 7.0
<#
.SYNOPSIS
    Runs hermetic contract tests for self-hosted runner profiles.

.DESCRIPTION
    Validates profile manifests, default compatibility, effective labels, generated
    environment files, image-build and verification commands, and exact per-profile
    Compose and Docker teardown isolation. Docker is replaced with a recording
    function; no daemon, network access, or registration token is required.

.EXAMPLE
    pwsh tests/Test-RunnerProfiles.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$functionsPath = Join-Path $runnerRoot 'RunnerProfiles.Functions.ps1'
$setupPath = Join-Path $runnerRoot 'Setup-Runner.ps1'
$schemaPath = Join-Path $runnerRoot 'runner-profile.schema.json'
$observedStateSchemaPath = Join-Path $runnerRoot 'observed-state.schema.json'
$copilotProfilePath = Join-Path $runnerRoot 'profiles' 'copilot-cli' 'profile.json'
$copilotDockerfilePath = Join-Path $runnerRoot 'profiles' 'copilot-cli' 'Dockerfile'
$managerPath = Join-Path $runnerRoot 'manager' 'manage-runners.sh'
$managerEntrypointPath = Join-Path $runnerRoot 'manager' 'entrypoint.sh'
$autoscalerModulePath = Join-Path $runnerRoot 'manager' 'autoscaler' 'go.mod'
$managerDockerfilePath = Join-Path $runnerRoot 'manager' 'Dockerfile'
$observabilityPath = Join-Path $runnerRoot 'manager' 'observability.sh'
$reconciliationPath = Join-Path $runnerRoot 'manager' 'reconciliation.sh'
$composePath = Join-Path $runnerRoot 'docker-compose.yml'
$routingPath = Join-Path $runnerRoot 'docs' 'guides' 'routing-workloads.md'

$errors = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Add-Check {
    param(
        [object]$Condition,
        [string]$Failure
    )

    $script:checks++
    $passed = if ($Condition -is [array]) {
        $Condition.Count -gt 0
    } else {
        [bool]$Condition
    }
    if (-not $passed) {
        $script:errors.Add($Failure)
    }
}

function Add-ThrowsCheck {
    param(
        [scriptblock]$Action,
        [string]$ExpectedMessage,
        [string]$Failure
    )

    $script:checks++
    try {
        & $Action
        $script:errors.Add("$Failure No error was thrown.")
    } catch {
        if ($_.Exception.Message -notmatch $ExpectedMessage) {
            $script:errors.Add("$Failure Expected '$ExpectedMessage', got '$($_.Exception.Message)'.")
        }
    }
}

function Copy-RunnerFixture {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($relativePath in @(
        'Setup-Runner.ps1',
        'RunnerProfiles.Functions.ps1',
        'runner-profile.schema.json',
        'docker-compose.yml',
        'manager',
        'profiles'
    )) {
        $sourcePath = Join-Path $Source $relativePath
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $Destination $relativePath)
            continue
        }

        foreach ($file in Get-ChildItem -LiteralPath $sourcePath -File -Recurse) {
            $fileRelativePath = [IO.Path]::GetRelativePath($Source, $file.FullName)
            $destinationPath = Join-Path $Destination $fileRelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destinationPath
        }
    }
}

function Set-TestCapacityAcknowledgement {
    param(
        [string]$Path,
        [int]$Generation,
        [int]$DesiredSlots,
        [int]$AddedSlots,
        [int]$DrainingSlots,
        [int]$UnchangedSlots
    )

    [PSCustomObject][ordered]@{
        schemaVersion = 1
        status = 'accepted'
        generation = $Generation
        managerContractVersion = 9
        desiredStateHash = 'test'
        observedAt = '2026-01-01T00:00:00Z'
        desiredSlots = $DesiredSlots
        addedSlots = $AddedSlots
        drainingSlots = $DrainingSlots
        unchangedSlots = $UnchangedSlots
        addedKeys = @()
        drainingKeys = @()
        unchangedKeys = @()
    } |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Start-TestCapacityAcknowledgementWriter {
    param(
        [string]$DesiredPath,
        [string]$AcknowledgementPath,
        [int]$Generation,
        [int]$DesiredSlots,
        [int]$AddedSlots,
        [int]$DrainingSlots,
        [int]$UnchangedSlots
    )

    return Start-Job -ArgumentList @(
        $DesiredPath,
        $AcknowledgementPath,
        $Generation,
        $DesiredSlots,
        $AddedSlots,
        $DrainingSlots,
        $UnchangedSlots
    ) -ScriptBlock {
        param(
            $DesiredPath,
            $AcknowledgementPath,
            $Generation,
            $DesiredSlots,
            $AddedSlots,
            $DrainingSlots,
            $UnchangedSlots
        )

        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        do {
            if (Test-Path -LiteralPath $DesiredPath -PathType Leaf) {
                try {
                    $desired = Get-Content -LiteralPath $DesiredPath -Raw -Encoding UTF8 |
                        ConvertFrom-Json -Depth 10 -ErrorAction Stop
                    if ([int]$desired.generation -eq $Generation) {
                        [PSCustomObject][ordered]@{
                            schemaVersion = 1
                            status = 'accepted'
                            generation = $Generation
                            managerContractVersion = 9
                            desiredStateHash = 'test'
                            observedAt = '2026-01-01T00:00:00Z'
                            desiredSlots = $DesiredSlots
                            addedSlots = $AddedSlots
                            drainingSlots = $DrainingSlots
                            unchangedSlots = $UnchangedSlots
                            addedKeys = @()
                            drainingKeys = @()
                            unchangedKeys = @()
                        } |
                            ConvertTo-Json -Depth 10 |
                            Set-Content -LiteralPath $AcknowledgementPath -Encoding UTF8
                        return
                    }
                } catch {
                    Start-Sleep -Milliseconds 50
                }
            }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)

        throw "Desired generation $Generation was not observed."
    }
}

$requiredPaths = @(
    $functionsPath,
    $setupPath,
    $schemaPath,
    $observedStateSchemaPath,
    $copilotProfilePath,
    $copilotDockerfilePath,
    $managerPath,
    $managerEntrypointPath,
    $autoscalerModulePath,
    $managerDockerfilePath,
    $observabilityPath,
    $reconciliationPath,
    $composePath,
    $routingPath
)
foreach ($path in $requiredPaths) {
    Add-Check (Test-Path -LiteralPath $path) "Required runner-profile surface is missing: $path"
}

if ($errors.Count -gt 0) {
    throw "PitCrew contract validation could not start:`n$($errors -join "`n")"
}

. $functionsPath

$profileJson = Get-Content -LiteralPath $copilotProfilePath -Raw -Encoding UTF8
Add-Check ($profileJson | Test-Json -SchemaFile $schemaPath) 'The built-in Copilot CLI profile does not conform to runner-profile.schema.json.'
$autoscalingManifest = $profileJson | ConvertFrom-Json -Depth 20
$autoscalingManifest | Add-Member -NotePropertyName autoscaling -NotePropertyValue ([PSCustomObject]@{
    mode = 'scale-set'
    minimumIdle = 0
    scaleDownDelaySeconds = 120
})
Add-Check (
    ($autoscalingManifest | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $schemaPath
) 'The profile schema rejects a valid scale-set autoscaling policy.'
$observedStateV7 = [PSCustomObject][ordered]@{
    schemaVersion = 1
    managerContractVersion = 7
    profileId = 'default'
    managerInstanceId = 'manager-instance'
    managerStatus = 'running'
    observedAt = '2026-01-01T00:00:00Z'
    scope = 'repo'
    generation = 1
    desiredStateHash = 'hash'
    desiredStateStatus = 'accepted'
    desiredSlots = 1
    activeSlots = 1
    drainingSlots = 0
    slots = @(
        [PSCustomObject][ordered]@{
            key = 'repo-example-000001'
            repository = 'https://github.com/example/project'
            desired = $true
            processRunning = $true
            state = 'online'
            failureCount = 0
            backoffSeconds = 0
            updatedAt = '2026-01-01T00:00:00Z'
            resources = [PSCustomObject][ordered]@{
                cpuCores = 0.25
                memoryWorkingSetBytes = 134217728
                pids = 12
            }
        }
    )
    resourceTelemetry = [PSCustomObject][ordered]@{
        sampledAt = '2026-01-01T00:00:00Z'
        status = 'available'
        host = [PSCustomObject][ordered]@{
            logicalProcessorCount = 16
            memoryBytes = 34359738368
        }
        manager = [PSCustomObject][ordered]@{
            cpuCores = 0.01
            memoryWorkingSetBytes = 33554432
            pids = 7
        }
    }
}
$observedStateV6 = $observedStateV7.PSObject.Copy()
$observedStateV6.managerContractVersion = 6
$observedStateV6.PSObject.Properties.Remove('resourceTelemetry')
$observedStateV6.slots = @(
    [PSCustomObject][ordered]@{
        key = 'repo-example-000001'
        repository = 'https://github.com/example/project'
        desired = $true
        processRunning = $true
        state = 'online'
        failureCount = 0
        backoffSeconds = 0
        updatedAt = '2026-01-01T00:00:00Z'
    }
)
Add-Check (
    ($observedStateV7 | ConvertTo-Json -Depth 8) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract seven does not conform to observed-state.schema.json.'
$observedStateV8 = (
    $observedStateV7 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$observedStateV8.managerContractVersion = 8
$observedStateV8 | Add-Member -NotePropertyName configuredSlots -NotePropertyValue 1
$observedStateV8 | Add-Member -NotePropertyName autoscaling -NotePropertyValue $null
Add-Check (
    ($observedStateV8 | ConvertTo-Json -Depth 8) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract eight fixed-mode state does not conform to observed-state.schema.json.'
$autoscaledStateV8 = (
    $observedStateV8 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$autoscaledStateV8.desiredSlots = 0
$autoscaledStateV8.configuredSlots = 30
$autoscaledStateV8.activeSlots = 0
$autoscaledStateV8.slots = @()
$autoscaledStateV8.autoscaling = [PSCustomObject][ordered]@{
    mode = 'scale-set'
    status = 'running'
    minimumIdleSlots = 0
    maximumSlots = 30
    targetSlots = 0
    assignedJobs = 0
    runningJobs = 0
    availableJobs = 0
    idleRunners = 0
    busyRunners = 0
    scaleDownDelaySeconds = 120
    scaleDownAt = $null
    scaleSetCount = 1
    lastError = $null
}
Add-Check (
    ($autoscaledStateV8 | ConvertTo-Json -Depth 8) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract eight autoscaling state does not conform to observed-state.schema.json.'
$observedStateV9 = (
    $autoscaledStateV8 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$observedStateV9.managerContractVersion = 9
$observedStateV9 | Add-Member -NotePropertyName update -NotePropertyValue (
    [PSCustomObject][ordered]@{
        status = 'rolling'
        targetRevision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        currentWorkers = 0
        staleWorkers = 1
        lastError = $null
    }
)
Add-Check (
    ($observedStateV9 | ConvertTo-Json -Depth 8) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract nine rolling-update state does not conform to observed-state.schema.json.'
$missingConfiguredV8 = (
    $observedStateV8 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$missingConfiguredV8.PSObject.Properties.Remove('configuredSlots')
Add-Check (-not (
    ($missingConfiguredV8 | ConvertTo-Json -Depth 8) |
        Test-Json `
            -SchemaFile $observedStateSchemaPath `
            -ErrorAction SilentlyContinue
)) 'Manager contract eight accepts missing configured capacity.'
Add-Check (
    ($observedStateV6 | ConvertTo-Json -Depth 8) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'The observed-state schema no longer accepts pre-telemetry managers.'
$nullTelemetryV7 = (
    $observedStateV7 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$nullTelemetryV7.resourceTelemetry = $null
Add-Check (-not (
    ($nullTelemetryV7 | ConvertTo-Json -Depth 8) |
        Test-Json `
            -SchemaFile $observedStateSchemaPath `
            -ErrorAction SilentlyContinue
)) 'The observed-state schema accepts null telemetry for manager contract seven.'
$missingSlotResourcesV7 = (
    $observedStateV7 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$missingSlotResourcesV7.slots[0].PSObject.Properties.Remove('resources')
Add-Check (-not (
    ($missingSlotResourcesV7 | ConvertTo-Json -Depth 8) |
        Test-Json `
            -SchemaFile $observedStateSchemaPath `
            -ErrorAction SilentlyContinue
)) 'The observed-state schema accepts a contract-seven slot without resources.'
$availableWithoutHostV7 = (
    $observedStateV7 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$availableWithoutHostV7.resourceTelemetry.host = $null
Add-Check (-not (
    ($availableWithoutHostV7 | ConvertTo-Json -Depth 8) |
        Test-Json `
            -SchemaFile $observedStateSchemaPath `
            -ErrorAction SilentlyContinue
)) 'The observed-state schema accepts available telemetry without host capacity.'
$emptyPartialV7 = (
    $observedStateV7 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$emptyPartialV7.resourceTelemetry.status = 'partial'
$emptyPartialV7.resourceTelemetry.host = $null
$emptyPartialV7.resourceTelemetry.manager = $null
$emptyPartialV7.slots[0].resources = $null
Add-Check (-not (
    ($emptyPartialV7 | ConvertTo-Json -Depth 8) |
        Test-Json `
            -SchemaFile $observedStateSchemaPath `
            -ErrorAction SilentlyContinue
)) 'The observed-state schema accepts an empty partial telemetry sample.'
$unavailableWithSlotV7 = (
    $observedStateV7 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$unavailableWithSlotV7.resourceTelemetry.status = 'unavailable'
$unavailableWithSlotV7.resourceTelemetry.host = $null
$unavailableWithSlotV7.resourceTelemetry.manager = $null
Add-Check (-not (
    ($unavailableWithSlotV7 | ConvertTo-Json -Depth 8) |
        Test-Json `
            -SchemaFile $observedStateSchemaPath `
            -ErrorAction SilentlyContinue
)) 'The observed-state schema accepts worker resources in unavailable telemetry.'

$defaultProfile = Resolve-RunnerProfile -RootPath $runnerRoot -Profile default -HostName 'test-host'
$copilotProfile = Resolve-RunnerProfile -RootPath $runnerRoot -Profile copilot-cli -HostName 'test-host'

Add-Check $defaultProfile.IsDefault 'The implicit default profile is not marked as default.'
Add-Check ($defaultProfile.Image -eq 'myoung34/github-runner:ubuntu-noble') 'The default profile changed its backward-compatible image.'
Add-Check ($defaultProfile.Replicas -eq 1) 'The default profile changed its backward-compatible replica count.'
Add-Check ($defaultProfile.EnvironmentPath -eq (Join-Path $runnerRoot '.env')) 'The default profile no longer uses the backward-compatible .env path.'
Add-Check ($defaultProfile.ComposeProjectName -eq 'self-hosted-runner') 'The default profile no longer uses the backward-compatible Compose project.'
Add-Check ($defaultProfile.LabelsValue -eq 'general-purpose') 'The default profile must carry the general-purpose routing label.'
Add-Check (-not $defaultProfile.DisableDefaultLabels) 'The default profile must retain GitHub default labels for backward compatibility.'
Add-Check $defaultProfile.PullImage 'The default profile must retain pre-pull behavior for its remote base image.'

$localDefaultProfile = Resolve-RunnerProfile `
    -RootPath $runnerRoot `
    -Profile default `
    -Image 'self-hosted-runner:local' `
    -PullImage:$false
Add-Check (-not $localDefaultProfile.PullImage) 'The command line cannot disable pulls for a local default-profile image.'

$autoscaledProfile = Resolve-RunnerProfile `
    -RootPath $runnerRoot `
    -Profile default `
    -Autoscale $true `
    -MinimumIdle 1 `
    -ScaleDownDelaySeconds 180 `
    -HostName 'test-host'
Add-Check ($autoscaledProfile.Autoscaling.Mode -eq 'scale-set') 'Autoscaling mode did not resolve to scale-set.'
Add-Check ($autoscaledProfile.Autoscaling.MinimumIdle -eq 1) 'Autoscaling minimum idle override was not applied.'
Add-Check ($autoscaledProfile.Autoscaling.ScaleDownDelaySeconds -eq 180) 'Autoscaling scale-down delay override was not applied.'
Add-ThrowsCheck `
    -Action {
        Resolve-RunnerProfile `
            -RootPath $runnerRoot `
            -Profile default `
            -MinimumIdle 1
    } `
    -ExpectedMessage 'requires autoscaling' `
    -Failure 'A minimum-idle override was accepted without autoscaling.'
Add-ThrowsCheck `
    -Action {
        Resolve-RunnerProfile `
            -RootPath $runnerRoot `
            -Profile default `
            -Autoscale $true `
            -ScaleDownDelaySeconds 10
    } `
    -ExpectedMessage 'between 30 and 3600' `
    -Failure 'An unsafe autoscaling scale-down delay was accepted.'

Add-Check (-not $copilotProfile.IsDefault) 'The Copilot CLI profile is incorrectly marked as default.'
Add-Check ($copilotProfile.DisableDefaultLabels) 'Specialized profiles must disable GitHub default labels by default.'
Add-Check ($copilotProfile.Labels -contains 'copilot-cli') 'The profile name is not enforced as a routing label.'
Add-Check ($copilotProfile.Labels -contains 'agentic-tooling') 'The Copilot CLI capability label is missing.'
Add-Check ($copilotProfile.Labels -notcontains 'self-hosted') 'The isolated Copilot CLI profile must not carry self-hosted.'
Add-Check ($copilotProfile.ComposeProjectName -eq 'self-hosted-runner-copilot-cli') 'The Copilot CLI Compose project is not isolated.'
Add-Check ($copilotProfile.ManagedRunnerLabel -eq 'ephemeral-managed-runner-profile=copilot-cli') 'The Copilot CLI Docker cleanup label is not profile-specific.'
Add-Check ($defaultProfile.ManagedRunnerLabel -ne $copilotProfile.ManagedRunnerLabel) 'Default and specialized profiles share a Docker cleanup label.'
Add-Check ($copilotProfile.EnvironmentPath -eq (Join-Path $runnerRoot '.env.copilot-cli')) 'The Copilot CLI profile state file is not isolated.'
Add-Check ($copilotProfile.NamePrefix -eq 'test-host-copilot-cli') 'Named profile runner names do not include the profile.'
Add-Check ($copilotProfile.VerificationCommands.Count -eq 2) 'The Copilot CLI profile must verify path and version at runtime.'
Add-Check (-not $copilotProfile.PullImage) 'A locally built profile must not be replaced by a remote pull.'
Add-Check ($copilotProfile.Build.Arguments['COPILOT_CLI_VERSION'] -eq '1.0.71') 'The Copilot CLI version is not pinned in the profile.'
Add-Check ($copilotProfile.Build.Arguments['COPILOT_CLI_SHA256_X64'] -match '^[0-9a-f]{64}$') 'The Copilot CLI x64 checksum is not pinned.'
Add-Check ($copilotProfile.Build.Arguments['COPILOT_CLI_SHA256_ARM64'] -match '^[0-9a-f]{64}$') 'The Copilot CLI arm64 checksum is not pinned.'
Add-Check ($defaultProfile.StateVolumePath -eq '.pitcrew-state/default') 'The default profile state mount is not stable.'
Add-Check ($copilotProfile.StateVolumePath -eq '.pitcrew-state/copilot-cli') 'Named mutable state is not profile-scoped.'
Add-Check ($defaultProfile.ManagerContractVersion -eq 9) 'The setup contract does not identify the rolling-update-capable manager.'
Add-Check ($defaultProfile.ObservedStatePath -eq (Join-Path $defaultProfile.StateDirectory 'observed-state.json')) 'The profile does not expose its observed-state path.'

$fiveWorkers = New-RunnerDesiredCapacityState `
    -Generation 4 `
    -Scope repo `
    -Repositories @(
        [PSCustomObject]@{
            Url = 'https://github.com/example/project'
            Workers = 5
        }
    ) `
    -Replicas $null
$sixWorkers = New-RunnerDesiredCapacityState `
    -Generation 5 `
    -Scope repo `
    -Repositories @(
        [PSCustomObject]@{
            Url = 'https://github.com/example/project'
            Workers = 6
        }
    ) `
    -Replicas $null
$sameFiveWorkers = New-RunnerDesiredCapacityState `
    -Generation 99 `
    -Scope repo `
    -Repositories @(
        [PSCustomObject]@{
            Url = 'https://github.com/example/project'
            Workers = 5
        }
    ) `
    -Replicas $null
Add-Check (
    (Get-RunnerDesiredCapacitySignature -State $fiveWorkers) -eq
    (Get-RunnerDesiredCapacitySignature -State $sameFiveWorkers)
) 'Desired-capacity equality incorrectly depends on generation.'
Add-Check (
    (Get-RunnerDesiredCapacitySignature -State $fiveWorkers) -ne
    (Get-RunnerDesiredCapacitySignature -State $sixWorkers)
) 'Desired-capacity equality ignores worker-count changes.'
Add-ThrowsCheck `
    -Action {
        New-RunnerDesiredCapacityState `
            -Generation 1 `
            -Scope repo `
            -Repositories @(
                [PSCustomObject]@{
                    Url = 'https://token@github.com/example/project'
                    Workers = 1
                }
            ) `
            -Replicas $null
    } `
    -ExpectedMessage 'without credentials' `
    -Failure 'Desired capacity accepted repository URL credentials.'
Add-ThrowsCheck `
    -Action {
        New-RunnerDesiredCapacityState `
            -Generation 1 `
            -Scope repo `
            -Repositories @(
                [PSCustomObject]@{
                    Url = 'https://github.com/example/project?token=secret'
                    Workers = 1
                }
            ) `
            -Replicas $null
    } `
    -ExpectedMessage 'query strings' `
    -Failure 'Desired capacity accepted repository URL query parameters.'
Add-ThrowsCheck `
    -Action {
        New-RunnerDesiredCapacityState `
            -Generation 1 `
            -Scope repo `
            -Repositories @(
                [PSCustomObject]@{
                    Url = ' https://token@github.com/example/project'
                    Workers = 1
                }
            ) `
            -Replicas $null
    } `
    -ExpectedMessage 'canonical absolute HTTP' `
    -Failure 'Desired capacity accepted leading URL whitespace.'

$cloneStyleState = New-RunnerDesiredCapacityState `
    -Generation 1 `
    -Scope repo `
    -Repositories @(
        [PSCustomObject]@{
            Url = 'https://GitHub.com/example/project.git/'
            Workers = 1
        }
    ) `
    -Replicas $null
Add-Check (
    $cloneStyleState.repositories[0].url -eq 'https://github.com/example/project'
) 'Desired capacity did not canonicalize a clone-style repository URL.'
Add-ThrowsCheck `
    -Action {
        New-RunnerDesiredCapacityState `
            -Generation 1 `
            -Scope repo `
            -Repositories @(
                [PSCustomObject]@{
                    Url = 'https://github.com/example/project'
                    Workers = 1
                },
                [PSCustomObject]@{
                    Url = 'https://github.com/example/project.git/'
                    Workers = 1
                }
            ) `
            -Replicas $null
    } `
    -ExpectedMessage 'duplicate repository URL' `
    -Failure 'Desired capacity accepted duplicate canonical repository URLs.'

$defaultStaticProfile = New-RunnerStaticProfileState `
    -Profile $defaultProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName ''
$copilotStaticProfile = New-RunnerStaticProfileState `
    -Profile $copilotProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName ''
$replicaOverrideProfile = Resolve-RunnerProfile `
    -RootPath $runnerRoot `
    -Profile default `
    -Replicas 9 `
    -HostName 'test-host'
$replicaOverrideStaticProfile = New-RunnerStaticProfileState `
    -Profile $replicaOverrideProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName ''
$imageOverrideProfile = Resolve-RunnerProfile `
    -RootPath $runnerRoot `
    -Profile default `
    -Image 'example/runner:changed' `
    -HostName 'test-host'
$imageOverrideStaticProfile = New-RunnerStaticProfileState `
    -Profile $imageOverrideProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName ''
$autoscaledStaticProfile = New-RunnerStaticProfileState `
    -Profile $autoscaledProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName ''
Add-Check (
    $defaultStaticProfile.fingerprint -eq $replicaOverrideStaticProfile.fingerprint
) 'Mutable capacity is included in the static profile fingerprint.'
Add-Check (
    $defaultStaticProfile.fingerprint -ne $imageOverrideStaticProfile.fingerprint
) 'Worker image changes do not select full profile replacement.'
Add-Check (
    $defaultStaticProfile.fingerprint -ne $autoscaledStaticProfile.fingerprint
) 'Autoscaling mode changes do not select full profile replacement.'
Add-Check (
    $copilotStaticProfile.configuration.build.contextSha256 -match '^[0-9a-f]{64}$'
) 'Locally built profiles do not fingerprint their complete build context.'

$copilotDockerfile = Get-Content -LiteralPath $copilotDockerfilePath -Raw -Encoding UTF8
Add-Check ($copilotDockerfile -match [regex]::Escape('sha256sum -c -')) 'The Copilot CLI image does not verify the downloaded checksum.'
Add-Check ($copilotDockerfile -match [regex]::Escape('/usr/local/bin/copilot')) 'The Copilot CLI image does not expose the documented stable executable path.'
Add-Check ($copilotDockerfile -notmatch '(?i)(COPILOT_GITHUB_TOKEN|GH_TOKEN|GITHUB_TOKEN=)') 'The Copilot CLI image contains authentication material.'
Add-Check ($profileJson -notmatch '(?i)(COPILOT_GITHUB_TOKEN|GH_TOKEN|GITHUB_TOKEN)') 'The Copilot CLI profile contains authentication material.'

$defaultEnvironment = New-RunnerEnvironmentContent `
    -Profile $defaultProfile `
    -AccessToken 'test-registration-token' `
    -WorkerRevision $defaultStaticProfile.workerRevision `
    -SessionOwner 'pitcrew-default' `
    -AssumeUnversionedCurrent $false
$copilotEnvironment = New-RunnerEnvironmentContent `
    -Profile $copilotProfile `
    -AccessToken 'test-registration-token' `
    -WorkerRevision $copilotStaticProfile.workerRevision `
    -SessionOwner 'pitcrew-copilot-cli' `
    -AssumeUnversionedCurrent $false
$autoscaledEnvironment = New-RunnerEnvironmentContent `
    -Profile $autoscaledProfile `
    -AccessToken 'test-registration-token' `
    -WorkerRevision $autoscaledStaticProfile.workerRevision `
    -SessionOwner 'pitcrew-autoscaled' `
    -AssumeUnversionedCurrent $false
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_PROFILE_ID=default$') 'The default environment does not identify its profile.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_LABELS=general-purpose$') 'The default environment does not emit the general-purpose label.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_NO_DEFAULT_LABELS=$') 'The default environment unexpectedly disables GitHub default labels.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_PULL_IMAGE=0$') 'Generated default state permits a second image pull after preparation.'
Add-Check ($defaultEnvironment -notmatch '(?m)^(REPO_URLS|RUNNER_REPLICAS)=') 'Mutable capacity remains embedded in the static environment.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_STATE_DIR=\.pitcrew-state/default$') 'The default environment does not mount its mutable state directory.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_MANAGER_CONTRACT_VERSION=9$') 'The environment does not pin the manager reconciliation contract.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_WORKER_REVISION=[0-9a-f]{64}$') 'The environment does not pin the worker revision.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_SESSION_OWNER=pitcrew-default$') 'The environment does not pin the stable session owner.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_AUTOSCALING_MODE=$') 'Fixed profiles unexpectedly enable autoscaling.'
Add-Check ($autoscaledEnvironment -match '(?m)^PITCREW_AUTOSCALING_MODE=scale-set$') 'Autoscaling mode is missing from the manager environment.'
Add-Check ($autoscaledEnvironment -match '(?m)^PITCREW_AUTOSCALING_MIN_IDLE=1$') 'Autoscaling minimum idle is missing from the manager environment.'
Add-Check ($autoscaledEnvironment -match '(?m)^PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS=180$') 'Autoscaling scale-down delay is missing from the manager environment.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_PROFILE_ID=copilot-cli$') 'The specialized environment does not identify its profile.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_NO_DEFAULT_LABELS=1$') 'The specialized environment does not disable GitHub default labels.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_PULL_IMAGE=0$') 'The specialized environment does not protect its locally built image.'

$enterpriseEnvironment = New-RunnerEnvironmentContent `
    -Profile $copilotProfile `
    -AccessToken 'test-registration-token' `
    -WorkerRevision $copilotStaticProfile.workerRevision `
    -SessionOwner 'pitcrew-copilot-cli' `
    -AssumeUnversionedCurrent $false `
    -Scope ent `
    -EnterpriseName 'example-enterprise'
Add-Check ($enterpriseEnvironment -match '(?m)^ENTERPRISE_NAME=example-enterprise$') 'Enterprise runner state does not include the enterprise name.'

Add-ThrowsCheck `
    -Action {
        Resolve-RunnerProfile `
            -RootPath $runnerRoot `
            -Profile copilot-cli `
            -Labels 'self-hosted'
    } `
    -ExpectedMessage 'cannot add the.*self-hosted' `
    -Failure 'An isolated profile accepted the self-hosted label.'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pitcrew-runner-profile-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $fingerprintContext = Join-Path $tempRoot 'fingerprint-context'
    $excludedContextState = Join-Path $fingerprintContext '.pitcrew-state'
    New-Item -ItemType Directory -Path $excludedContextState -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fingerprintContext 'Dockerfile') -Value 'FROM scratch' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $fingerprintContext 'copied-tool.txt') -Value 'version-one' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $excludedContextState 'ack.json') -Value 'generation-one' -Encoding UTF8
    $contextFingerprintOne = Get-RunnerBuildContextFingerprint `
        -ContextPath $fingerprintContext `
        -ExcludedPaths @($excludedContextState)
    Set-Content -LiteralPath (Join-Path $fingerprintContext 'copied-tool.txt') -Value 'version-two' -Encoding UTF8
    $contextFingerprintTwo = Get-RunnerBuildContextFingerprint `
        -ContextPath $fingerprintContext `
        -ExcludedPaths @($excludedContextState)
    Set-Content -LiteralPath (Join-Path $excludedContextState 'ack.json') -Value 'generation-two' -Encoding UTF8
    $contextFingerprintThree = Get-RunnerBuildContextFingerprint `
        -ContextPath $fingerprintContext `
        -ExcludedPaths @($excludedContextState)
    Add-Check ($contextFingerprintOne -ne $contextFingerprintTwo) 'A changed Docker build input did not change the context fingerprint.'
    Add-Check ($contextFingerprintTwo -eq $contextFingerprintThree) 'Generated reconciliation state changed the Docker build-context fingerprint.'

    $hardLinkTarget = Join-Path $tempRoot 'hard-link-target.txt'
    $hardLinkPath = Join-Path $fingerprintContext 'hard-linked-input.txt'
    Set-Content -LiteralPath $hardLinkTarget -Value 'hard-link-one' -Encoding UTF8
    New-Item -ItemType HardLink -Path $hardLinkPath -Target $hardLinkTarget | Out-Null
    $hardLinkFingerprintOne = Get-RunnerBuildContextFingerprint `
        -ContextPath $fingerprintContext `
        -ExcludedPaths @($excludedContextState)
    Set-Content -LiteralPath $hardLinkTarget -Value 'hard-link-two' -Encoding UTF8
    $hardLinkFingerprintTwo = Get-RunnerBuildContextFingerprint `
        -ContextPath $fingerprintContext `
        -ExcludedPaths @($excludedContextState)
    Add-Check ($hardLinkFingerprintOne -ne $hardLinkFingerprintTwo) 'Changed hard-linked build content was omitted from the context fingerprint.'

    if (-not $IsWindows) {
        $modeInputPath = Join-Path $fingerprintContext 'copied-tool.txt'
        & chmod 0644 $modeInputPath
        $modeFingerprintOne = Get-RunnerBuildContextFingerprint `
            -ContextPath $fingerprintContext `
            -ExcludedPaths @($excludedContextState)
        & chmod 0755 $modeInputPath
        $modeFingerprintTwo = Get-RunnerBuildContextFingerprint `
            -ContextPath $fingerprintContext `
            -ExcludedPaths @($excludedContextState)
        Add-Check ($modeFingerprintOne -ne $modeFingerprintTwo) 'Changed Unix build-input mode was omitted from the context fingerprint.'
    }

    $lockPath = Join-Path $tempRoot 'lock-contract' 'setup.lock'
    $firstLock = Enter-RunnerProfileLock -Path $lockPath -TimeoutSeconds 1
    try {
        Add-ThrowsCheck `
            -Action {
                $contendingLock = Enter-RunnerProfileLock -Path $lockPath -TimeoutSeconds 1
                $contendingLock.Dispose()
            } `
            -ExpectedMessage 'Timed out waiting for profile setup lock' `
            -Failure 'Concurrent profile setup was not serialized.'
    }
    finally {
        $firstLock.Dispose()
    }
    $releasedLock = Enter-RunnerProfileLock -Path $lockPath -TimeoutSeconds 1
    $releasedLock.Dispose()
    Add-Check $true 'A released profile setup lock could not be reacquired.'

    $externalDirectory = Join-Path $tempRoot 'external-profile'
    New-Item -ItemType Directory -Path $externalDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $externalDirectory 'Dockerfile') -Value 'FROM scratch' -Encoding UTF8
    $externalManifestPath = Join-Path $externalDirectory 'profile.json'
    @{
        schemaVersion = 1
        name = 'browser-testing'
        description = 'External profile contract test.'
        image = 'example/browser:1.0.0'
        labels = @('browser')
        replicas = 2
        disableDefaultLabels = $true
        build = @{
            context = '.'
            dockerfile = 'Dockerfile'
            args = @{
                BROWSER_VERSION = '1.0.0'
            }
        }
        verificationCommands = @('browser --version')
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $externalManifestPath -Encoding UTF8

    $externalProfile = Resolve-RunnerProfile `
        -RootPath $runnerRoot `
        -ProfilePath $externalManifestPath `
        -HostName 'test-host'
    Add-Check ($externalProfile.Name -eq 'browser-testing') 'An external profile did not resolve its manifest name.'
    Add-Check ($externalProfile.Build.Context -eq $externalDirectory) 'External build context is not relative to the profile manifest.'
    Add-Check ($externalProfile.Replicas -eq 2) 'External profile replica defaults were not applied.'

    $secretManifest = Get-Content -LiteralPath $externalManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10
    $secretManifest.build.args = [PSCustomObject]@{ API_TOKEN = 'not-a-real-token' }
    $secretManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $externalManifestPath -Encoding UTF8
    Add-ThrowsCheck `
        -Action {
            Resolve-RunnerProfile -RootPath $runnerRoot -ProfilePath $externalManifestPath
        } `
        -ExpectedMessage 'looks secret-bearing' `
        -Failure 'A profile accepted a secret-shaped Docker build argument.'

    $fixtureParent = Join-Path $tempRoot 'fixture'
    $fixtureRoot = Join-Path $fixtureParent 'self-hosted-runner'
    New-Item -ItemType Directory -Path $fixtureParent -Force | Out-Null
    Copy-RunnerFixture -Source $runnerRoot -Destination $fixtureRoot
    $fixtureSetup = Join-Path $fixtureRoot 'Setup-Runner.ps1'
    $dockerLog = Join-Path $tempRoot 'docker.log'

    $previousDockerFunction = Get-Item Function:\global:docker -ErrorAction SilentlyContinue
    $previousInvokeRestMethodFunction = Get-Item Function:\global:Invoke-RestMethod -ErrorAction SilentlyContinue
    $env:PITCREW_RUNNER_DOCKER_LOG = $dockerLog
    $ambientNames = @(
        'ACCESS_TOKEN',
        'REPO_URLS',
        'REPO_URL',
        'RUNNER_PROFILE_ID',
        'RUNNER_REPLICAS',
        'RUNNER_IMAGE',
        'PITCREW_AUTOSCALING_MODE',
        'PITCREW_AUTOSCALING_MIN_IDLE',
        'PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS',
        'PITCREW_STATE_DIR',
        'PITCREW_MANAGER_CONTRACT_VERSION'
    )
    $savedAmbient = @{}
    foreach ($name in $ambientNames) {
        $item = Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        $savedAmbient[$name] = [PSCustomObject]@{
            Exists = $null -ne $item
            Value = if ($item) { $item.Value } else { $null }
        }
    }
    $env:ACCESS_TOKEN = 'ambient-registration-token'
    $env:REPO_URLS = 'https://github.com/ambient/wrong=99'
    $env:REPO_URL = 'https://github.com/ambient/wrong'
    $env:RUNNER_PROFILE_ID = 'ambient-profile'
    $env:RUNNER_REPLICAS = '99'
    $env:RUNNER_IMAGE = 'ambient/image:wrong'
    $env:PITCREW_AUTOSCALING_MODE = 'ambient-mode'
    $env:PITCREW_AUTOSCALING_MIN_IDLE = '99'
    $env:PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS = '999'
    $env:PITCREW_STATE_DIR = 'ambient-state'
    $env:PITCREW_MANAGER_CONTRACT_VERSION = '99'
    $env:PITCREW_TEST_MANAGER_RUNNING = '0'

    function global:docker {
        $dockerArguments = @($args)

        Add-Content `
            -LiteralPath $env:PITCREW_RUNNER_DOCKER_LOG `
            -Value (($dockerArguments | ForEach-Object { [string]$_ }) -join "`t")
        if ($dockerArguments[0] -eq 'compose') {
            Add-Content `
                -LiteralPath $env:PITCREW_RUNNER_DOCKER_LOG `
                -Value "compose-env`tACCESS_TOKEN=$env:ACCESS_TOKEN`tREPO_URLS=$env:REPO_URLS`tREPO_URL=$env:REPO_URL`tRUNNER_PROFILE_ID=$env:RUNNER_PROFILE_ID`tRUNNER_REPLICAS=$env:RUNNER_REPLICAS`tRUNNER_IMAGE=$env:RUNNER_IMAGE`tPITCREW_AUTOSCALING_MODE=$env:PITCREW_AUTOSCALING_MODE`tPITCREW_AUTOSCALING_MIN_IDLE=$env:PITCREW_AUTOSCALING_MIN_IDLE`tPITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS=$env:PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS`tPITCREW_STATE_DIR=$env:PITCREW_STATE_DIR`tPITCREW_MANAGER_CONTRACT_VERSION=$env:PITCREW_MANAGER_CONTRACT_VERSION"
            if (
                $dockerArguments -contains 'up' -and
                $env:PITCREW_TEST_MANAGER_START_FAILURE -eq '1' -and
                $env:PITCREW_TEST_MANAGER_START_FAILURE_USED -ne '1'
            ) {
                $env:PITCREW_TEST_MANAGER_START_FAILURE_USED = '1'
                $global:LASTEXITCODE = 1
                return
            }
        }
        if (
            $dockerArguments[0] -eq 'ps' -and
            $dockerArguments -contains 'label=ephemeral-runner-manager-profile=default' -and
            $env:PITCREW_TEST_MANAGER_RUNNING -eq '1'
        ) {
            Write-Output 'manager-container-id'
        }
        if (
            $dockerArguments[0] -eq 'image' -and
            $dockerArguments[1] -eq 'inspect' -and
            $env:PITCREW_TEST_IMAGE_MISSING -eq '1'
        ) {
            $global:LASTEXITCODE = 1
            return
        }
        if (
            $dockerArguments[0] -eq 'inspect' -and
            $dockerArguments -contains 'manager-container-id' -and
            $dockerArguments -contains '{{ index .Config.Labels "pitcrew-manager-contract-version" }}'
        ) {
            Write-Output $(if ($env:PITCREW_TEST_MANAGER_CONTRACT) {
                $env:PITCREW_TEST_MANAGER_CONTRACT
            } else {
                '9'
            })
        }
        if (
            $dockerArguments[0] -eq 'inspect' -and
            $dockerArguments -contains 'manager-container-id' -and
            $dockerArguments -contains '{{.Image}}'
        ) {
            Write-Output 'sha256:manager-image'
        }
        $global:LASTEXITCODE = 0
    }

    function global:Invoke-RestMethod {
        param(
            [object]$Method,
            [object]$Uri,
            [hashtable]$Headers,
            [object]$ErrorAction
        )

        if (
            $env:PITCREW_TEST_REJECT_TOKEN -and
            $Headers.Authorization -eq "Bearer $env:PITCREW_TEST_REJECT_TOKEN"
        ) {
            throw 'Test registration token rejected.'
        }
        return [PSCustomObject]@{
            token = 'short-lived-registration-token'
        }
    }

    try {
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Scope org `
                    -OrgName example `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'apply only to repo scope' `
            -Failure 'Organization setup accepted repository-scoped targets.'
        $invalidCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($invalidCommands -match 'compose.*down')) 'Invalid profile input tore down the running pool before validation.'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Repos 'https://github.com/example/project=0'
            } `
            -ExpectedMessage 'positive integer' `
            -Failure 'Setup accepted a zero repository worker count.'
        $invalidCountCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($invalidCountCommands -match 'compose.*down')) 'An invalid repository count tore down the running pool.'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Repos 'http://github.com/example/project=1'
            } `
            -ExpectedMessage 'only HTTPS github.com repository URLs' `
            -Failure 'Setup sent a registration token to a plaintext repository host.'
        $plaintextHostCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($plaintextHostCommands -match 'compose.*down')) 'A plaintext repository URL stopped a running profile.'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Repos 'https://example.com/example/project=1'
            } `
            -ExpectedMessage 'only HTTPS github.com repository URLs' `
            -Failure 'Setup sent a registration token to an untrusted repository host.'
        $untrustedHostCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($untrustedHostCommands -match 'compose.*down')) 'An untrusted repository URL stopped a running profile.'

        @(
            'ACCESS_TOKEN=legacy-registration-token'
            'REPO_URLS=https://github.com/example/existing-a=2,https://github.com/example/existing-b'
            'RUNNER_SCOPE=repo'
            'RUNNER_REPLICAS=1'
            'RUNNER_PROFILE_ID=default'
            'RUNNER_IMAGE=myoung34/github-runner:ubuntu-noble'
            'RUNNER_NAME_PREFIX=legacy-runner'
            'RUNNER_LABELS=general-purpose'
        ) -join "`n" |
            Set-Content -LiteralPath (Join-Path $fixtureRoot '.env') -NoNewline -Encoding UTF8
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -Token 'test-registration-token' `
            -Replicas 4 `
            -AddRepos 'https://github.com/example/new-project=3'
        $migratedDesiredPath = Join-Path $fixtureRoot '.pitcrew-state' 'default' 'desired-capacity.json'
        $migratedDesired = Get-Content -LiteralPath $migratedDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        $migratedRepositories = @($migratedDesired.repositories | ForEach-Object url)
        Add-Check ($migratedRepositories.Count -eq 3) 'First-upgrade -AddRepos dropped a legacy repository target.'
        Add-Check ($migratedRepositories -contains 'https://github.com/example/existing-a') 'Legacy repository A was not migrated into desired state.'
        Add-Check ($migratedRepositories -contains 'https://github.com/example/existing-b') 'Legacy repository B was not migrated into desired state.'
        Add-Check ($migratedRepositories -contains 'https://github.com/example/new-project') 'The newly added repository was not included during migration.'
        Add-Check (
            ($migratedDesired.repositories |
                Where-Object url -eq 'https://github.com/example/existing-b').workers -eq 1
        ) 'A bare legacy repository URL did not preserve its one-worker default.'
        Remove-Item -LiteralPath (Join-Path $fixtureRoot '.env') -Force
        Remove-Item -LiteralPath (Join-Path $fixtureRoot '.pitcrew-state') -Recurse -Force

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -Token 'test-registration-token' `
            -Repos 'https://github.com/example/project=1'
        $defaultEnvironmentPath = Join-Path $fixtureRoot '.env'
        $defaultEnvironmentState = Get-Content -LiteralPath $defaultEnvironmentPath -Raw -Encoding UTF8
        $defaultDesiredPath = Join-Path $fixtureRoot '.pitcrew-state' 'default' 'desired-capacity.json'
        $defaultAcknowledgementPath = Join-Path $fixtureRoot '.pitcrew-state' 'default' 'acknowledged-capacity.json'
        $defaultStaticProfilePath = Join-Path $fixtureRoot '.pitcrew-state' 'default' 'static-profile.json'
        $defaultDesiredState = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-Check ($defaultEnvironmentState -match '(?m)^RUNNER_PROFILE_ID=default$') 'Default setup did not write the default profile environment.'
        Add-Check ($defaultEnvironmentState -match '(?m)^RUNNER_LABELS=general-purpose$') 'Default setup did not write the general-purpose label.'
        Add-Check ($defaultEnvironmentState -notmatch '(?m)^(REPO_URLS|RUNNER_REPLICAS)=') 'Default setup wrote mutable capacity into the static environment.'
        Add-Check ($defaultDesiredState.generation -eq 1) 'Initial desired capacity did not start at generation one.'
        Add-Check ($defaultDesiredState.repositories[0].workers -eq 1) 'Initial desired capacity did not preserve the repository worker count.'
        $defaultCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($defaultCommands -match 'pull.*myoung34/github-runner:ubuntu-noble') 'Default setup did not prepare its pullable image before replacement.'
        Add-Check ($defaultCommands -match "compose-env`tACCESS_TOKEN=`tREPO_URLS=`tREPO_URL=`tRUNNER_PROFILE_ID=`tRUNNER_REPLICAS=`tRUNNER_IMAGE=`tPITCREW_AUTOSCALING_MODE=`tPITCREW_AUTOSCALING_MIN_IDLE=`tPITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS=`tPITCREW_STATE_DIR=`tPITCREW_MANAGER_CONTRACT_VERSION=$") 'Ambient profile variables were visible to Docker Compose.'
        Add-Check ($env:RUNNER_PROFILE_ID -eq 'ambient-profile') 'Docker Compose isolation did not restore ambient profile variables.'

        Set-TestCapacityAcknowledgement `
            -Path $defaultAcknowledgementPath `
            -Generation 1 `
            -DesiredSlots 1 `
            -AddedSlots 1 `
            -DrainingSlots 0 `
            -UnchangedSlots 0

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -CapacityOnly `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'Capacity-only update cannot proceed' `
            -Failure 'A required capacity-only update fell back to profile replacement.'
        $capacityGuardCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($capacityGuardCommands -match 'compose.*down')) 'A failed capacity-only guard stopped the selected profile.'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Refresh `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'Refresh will not start a stopped profile' `
            -Failure 'Refresh started an intentionally stopped profile.'
        $stoppedRefreshCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($stoppedRefreshCommands -match 'compose.*up')) 'A stopped profile refresh started a manager.'

        $env:PITCREW_TEST_MANAGER_RUNNING = '1'
        $savedStaticProfile = Get-Content -LiteralPath $defaultStaticProfilePath -Raw -Encoding UTF8
        Remove-Item -LiteralPath $defaultStaticProfilePath -Force
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Refresh `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'worker profile configuration is otherwise unchanged' `
            -Failure 'Refresh accepted missing prior static profile state.'
        $missingStaticRefreshCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($missingStaticRefreshCommands -match 'compose.*down')) 'A refresh with missing static state stopped the selected profile.'
        Set-Content `
            -LiteralPath $defaultStaticProfilePath `
            -Value $savedStaticProfile `
            -NoNewline `
            -Encoding UTF8

        $env:PITCREW_TEST_IMAGE_MISSING = '1'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Refresh `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'Runner image.*is not available' `
            -Failure 'Refresh stopped a profile without an available worker image.'
        $missingImageRefreshCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($missingImageRefreshCommands -match 'compose.*down')) 'A refresh with a missing worker image stopped the selected profile.'
        Remove-Item Env:\PITCREW_TEST_IMAGE_MISSING -ErrorAction SilentlyContinue

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        $scaleUpAcknowledgement = Start-TestCapacityAcknowledgementWriter `
            -DesiredPath $defaultDesiredPath `
            -AcknowledgementPath $defaultAcknowledgementPath `
            -Generation 2 `
            -DesiredSlots 2 `
            -AddedSlots 1 `
            -DrainingSlots 0 `
            -UnchangedSlots 1
        try {
            & $fixtureSetup `
                -Token 'test-registration-token' `
                -CapacityOnly `
                -Repos 'https://github.com/example/project=2'
        }
        finally {
            Wait-Job -Job $scaleUpAcknowledgement -Timeout 65 | Out-Null
            Receive-Job -Job $scaleUpAcknowledgement -ErrorAction Stop | Out-Null
            Remove-Job -Job $scaleUpAcknowledgement -Force
        }
        $scaleUpCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        $scaledUpState = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-Check ($scaledUpState.generation -eq 2) 'Scale-up did not advance desired-capacity generation.'
        Add-Check ($scaledUpState.repositories[0].workers -eq 2) 'Scale-up did not publish the requested worker count.'
        Add-Check (-not ($scaleUpCommands -match 'compose.*down')) 'Capacity-only scale-up restarted the manager.'
        Add-Check (-not ($scaleUpCommands -match '(^|\t)(pull|build|run)(\t|$)')) 'Capacity-only scale-up prepared or reverified the unchanged image.'
        Add-Check (-not ($scaleUpCommands -match 'rm.*-f')) 'Capacity-only scale-up ran broad worker cleanup.'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        $scaleDownAcknowledgement = Start-TestCapacityAcknowledgementWriter `
            -DesiredPath $defaultDesiredPath `
            -AcknowledgementPath $defaultAcknowledgementPath `
            -Generation 3 `
            -DesiredSlots 1 `
            -AddedSlots 0 `
            -DrainingSlots 1 `
            -UnchangedSlots 1
        try {
            & $fixtureSetup `
                -Token 'test-registration-token' `
                -CapacityOnly `
                -Repos 'https://github.com/example/project=1'
        }
        finally {
            Wait-Job -Job $scaleDownAcknowledgement -Timeout 65 | Out-Null
            Receive-Job -Job $scaleDownAcknowledgement -ErrorAction Stop | Out-Null
            Remove-Job -Job $scaleDownAcknowledgement -Force
        }
        $scaleDownCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        $scaledDownState = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-Check ($scaledDownState.generation -eq 3) 'Scale-down did not advance desired-capacity generation.'
        Add-Check ($scaledDownState.repositories[0].workers -eq 1) 'Scale-down did not publish the requested worker count.'
        Add-Check (-not ($scaleDownCommands -match 'compose.*down')) 'Capacity-only scale-down restarted the manager.'
        Add-Check (-not ($scaleDownCommands -match 'rm.*-f')) 'Capacity-only scale-down force-removed a worker.'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -Token 'test-registration-token' `
            -Repos 'https://github.com/example/project=1'
        $idempotentCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        $idempotentState = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-Check ($idempotentState.generation -eq 3) 'Reapplying identical capacity advanced its generation.'
        Add-Check (-not ($idempotentCommands -match 'compose.*down')) 'Reapplying identical capacity restarted the manager.'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -CapacityOnly `
            -Repos 'https://github.com/example/project=1'
        $storedTokenCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($storedTokenCommands -match 'compose.*down')) 'Reusing the stored profile token changed an otherwise identical profile.'

        $env:PITCREW_TEST_REJECT_TOKEN = 'test-registration-token'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -CapacityOnly `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'stored token does not have runner registration access' `
            -Failure 'Setup accepted a rejected stored registration token.'
        $rejectedTokenCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($rejectedTokenCommands -match 'compose.*down')) 'A rejected stored token stopped the selected profile.'
        Remove-Item Env:\PITCREW_TEST_REJECT_TOKEN -ErrorAction SilentlyContinue

        Set-TestCapacityAcknowledgement `
            -Path $defaultAcknowledgementPath `
            -Generation 2 `
            -DesiredSlots 1 `
            -AddedSlots 0 `
            -DrainingSlots 0 `
            -UnchangedSlots 1
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        $recoveryAcknowledgement = Start-TestCapacityAcknowledgementWriter `
            -DesiredPath $defaultDesiredPath `
            -AcknowledgementPath $defaultAcknowledgementPath `
            -Generation 4 `
            -DesiredSlots 1 `
            -AddedSlots 0 `
            -DrainingSlots 0 `
            -UnchangedSlots 1
        try {
            & $fixtureSetup `
                -Token 'test-registration-token' `
                -CapacityOnly `
                -Repos 'https://github.com/example/project=1'
        }
        finally {
            Wait-Job -Job $recoveryAcknowledgement -Timeout 65 | Out-Null
            Receive-Job -Job $recoveryAcknowledgement -ErrorAction Stop | Out-Null
            Remove-Job -Job $recoveryAcknowledgement -Force
        }
        $recoveredState = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        $recoveryCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($recoveredState.generation -eq 4) 'A stale acknowledgement did not force a recoverable generation.'
        Add-Check (-not ($recoveryCommands -match 'compose.*down')) 'Acknowledgement recovery restarted the manager.'

        $defaultStateDirectory = Split-Path -Parent $defaultDesiredPath
        Remove-Item `
            -LiteralPath (Join-Path $defaultStateDirectory 'manager-session-owner.txt') `
            -Force
        [PSCustomObject][ordered]@{
            schemaVersion = 1
            managerContractVersion = 8
            profileId = 'default'
            managerInstanceId = 'legacy-session-owner'
        } |
            ConvertTo-Json |
            Set-Content `
                -LiteralPath (Join-Path $defaultStateDirectory 'observed-state.json') `
                -Encoding UTF8
        $env:PITCREW_TEST_MANAGER_CONTRACT = '8'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        $legacyRefreshAcknowledgement = Start-TestCapacityAcknowledgementWriter `
            -DesiredPath $defaultDesiredPath `
            -AcknowledgementPath $defaultAcknowledgementPath `
            -Generation 4 `
            -DesiredSlots 1 `
            -AddedSlots 0 `
            -DrainingSlots 0 `
            -UnchangedSlots 1
        try {
            & $fixtureSetup `
                -Token 'test-registration-token' `
                -Refresh `
                -Repos 'https://github.com/example/project=1'
        }
        finally {
            Wait-Job -Job $legacyRefreshAcknowledgement -Timeout 65 | Out-Null
            Receive-Job -Job $legacyRefreshAcknowledgement -ErrorAction Stop | Out-Null
            Remove-Job -Job $legacyRefreshAcknowledgement -Force
        }
        $legacyRefreshCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        $legacyRefreshEnvironment = Get-Content -LiteralPath $defaultEnvironmentPath -Raw -Encoding UTF8
        Add-Check ($legacyRefreshCommands -match 'update.*--restart=no.*manager-container-id') 'A legacy manager refresh did not disable automatic restart.'
        Add-Check ($legacyRefreshCommands -match 'rm.*-f.*manager-container-id') 'A legacy manager refresh signaled its destructive shutdown path.'
        Add-Check (-not ($legacyRefreshCommands -match 'compose.*\tdown(\t|$)')) 'A legacy manager refresh stopped the complete profile.'
        Add-Check ($legacyRefreshEnvironment -match '(?m)^PITCREW_SESSION_OWNER=legacy-session-owner$') 'A legacy autoscaler refresh did not preserve its session owner.'

        $env:PITCREW_TEST_MANAGER_CONTRACT = '9'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        $refreshAcknowledgement = Start-TestCapacityAcknowledgementWriter `
            -DesiredPath $defaultDesiredPath `
            -AcknowledgementPath $defaultAcknowledgementPath `
            -Generation 4 `
            -DesiredSlots 1 `
            -AddedSlots 0 `
            -DrainingSlots 0 `
            -UnchangedSlots 1
        try {
            & $fixtureSetup `
                -Token 'test-registration-token' `
                -Refresh `
                -Repos 'https://github.com/example/project=1'
        }
        finally {
            Wait-Job -Job $refreshAcknowledgement -Timeout 65 | Out-Null
            Receive-Job -Job $refreshAcknowledgement -ErrorAction Stop | Out-Null
            Remove-Job -Job $refreshAcknowledgement -Force
        }
        $refreshCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        $refreshedState = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-Check (-not ($refreshCommands -match '^(pull|build|run)(\t|$)')) 'An explicit manager refresh mutated or reverified the shared runner image.'
        Add-Check (-not ($refreshCommands -match 'compose.*\tdown(\t|$)')) 'An explicit profile refresh stopped the selected profile.'
        Add-Check ($refreshCommands -match 'compose.*build.*runner-manager') 'An explicit profile refresh did not build the replacement manager first.'
        Add-Check ($refreshCommands -match 'stop.*--time.*60.*manager-container-id') 'An explicit profile refresh did not hand off the running manager.'
        Add-Check ($refreshCommands -match 'compose.*up.*--force-recreate.*runner-manager') 'An explicit profile refresh did not recreate only the selected manager.'
        Add-Check ($refreshedState.generation -eq 4) 'An explicit profile refresh changed identical desired capacity.'

        $preRollbackEnvironment = Get-Content -LiteralPath $defaultEnvironmentPath -Raw -Encoding UTF8
        $preRollbackStatic = Get-Content -LiteralPath $defaultStaticProfilePath -Raw -Encoding UTF8
        $preRollbackDesired = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8
        $env:PITCREW_TEST_MANAGER_START_FAILURE = '1'
        Remove-Item Env:\PITCREW_TEST_MANAGER_START_FAILURE_USED -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Refresh `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'docker compose up failed' `
            -Failure 'A failed manager start was not surfaced after rollback.'
        Remove-Item Env:\PITCREW_TEST_MANAGER_START_FAILURE -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_START_FAILURE_USED -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_CONTRACT -ErrorAction SilentlyContinue
        $rollbackCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($rollbackCommands -match 'tag.*sha256:manager-image.*ephemeral-runner-manager:profile-default') 'A failed manager start did not restore the previous manager image.'
        Add-Check (
            (Get-Content -LiteralPath $defaultEnvironmentPath -Raw -Encoding UTF8) -ceq
            $preRollbackEnvironment
        ) 'A failed manager start did not restore the previous environment.'
        Add-Check (
            (Get-Content -LiteralPath $defaultStaticProfilePath -Raw -Encoding UTF8) -ceq
            $preRollbackStatic
        ) 'A failed manager start did not restore the previous static profile.'
        Add-Check (
            (Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8) -ceq
            $preRollbackDesired
        ) 'A failed manager start did not restore desired capacity.'

        if (-not $IsWindows) {
            $defaultStateDirectory = Split-Path -Parent $defaultDesiredPath
            & chmod 0555 $defaultStateDirectory
            try {
                Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
                $unchangedBeforeFailedWrite = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8
                Add-ThrowsCheck `
                    -Action {
                        & $fixtureSetup `
                            -Token 'test-registration-token' `
                            -CapacityOnly `
                            -Repos 'https://github.com/example/project=2'
                    } `
                    -ExpectedMessage '(denied|permission|read-only)' `
                    -Failure 'A failed atomic desired-state write was not surfaced.'
                $failedWriteCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
                Add-Check (-not ($failedWriteCommands -match 'compose.*down')) 'A failed desired-state write restarted the running manager.'
                Add-Check (-not ($failedWriteCommands -match 'rm.*-f')) 'A failed desired-state write removed a running worker.'
                Add-Check (
                    (Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8) -eq
                    $unchangedBeforeFailedWrite
                ) 'A failed desired-state write changed the visible desired document.'
            }
            finally {
                & chmod 0755 $defaultStateDirectory
            }
        }

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Labels 'additional-capability' `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'cannot roll safely' `
            -Failure 'A live routing change bypassed the explicit-stop requirement.'
        $immutableCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($immutableCommands -match 'compose.*\t(build|up|down)(\t|$)')) 'A rejected routing change modified the live profile.'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Autoscale `
                    -MinimumIdle 0 `
                    -ScaleDownDelaySeconds 120 `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'cannot roll safely' `
            -Failure 'A live fixed-to-scale-set migration bypassed the explicit-stop requirement.'
        $env:PITCREW_TEST_MANAGER_RUNNING = '0'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -Token 'test-registration-token' `
            -Autoscale `
            -MinimumIdle 0 `
            -ScaleDownDelaySeconds 120 `
            -Repos 'https://github.com/example/project=1'
        $autoscalingCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        $autoscalingEnvironment = Get-Content -LiteralPath $defaultEnvironmentPath -Raw -Encoding UTF8
        Add-Check ($autoscalingEnvironment -match '(?m)^PITCREW_AUTOSCALING_MODE=scale-set$') 'Setup did not persist scale-set mode.'
        Add-Check ($autoscalingEnvironment -match '(?m)^PITCREW_AUTOSCALING_MIN_IDLE=0$') 'Setup did not persist autoscaling minimum idle.'
        Add-Check ($autoscalingEnvironment -match '(?m)^PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS=120$') 'Setup did not persist autoscaling scale-down delay.'
        Add-Check ($autoscalingCommands -match 'run.*Runner\.Listener.*id runner') 'Setup did not verify the JIT runner image contract.'
        Add-Check (-not ($autoscalingCommands -match 'compose.*\tdown(\t|$)')) 'Starting a stopped autoscaling profile ran broad teardown.'
        $env:PITCREW_TEST_MANAGER_RUNNING = '1'

        $defaultDesiredBeforeNamed = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -Profile copilot-cli `
            -Token 'test-registration-token' `
            -Repos 'https://github.com/example/project=1'
        $copilotStatePath = Join-Path $fixtureRoot '.env.copilot-cli'
        $copilotState = Get-Content -LiteralPath $copilotStatePath -Raw -Encoding UTF8
        $namedCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($copilotState -match '(?m)^RUNNER_PROFILE_ID=copilot-cli$') 'Named setup did not write profile-specific state.'
        Add-Check ($copilotState -match '(?m)^RUNNER_NO_DEFAULT_LABELS=1$') 'Named setup did not write isolated routing state.'
        Add-Check ((Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8) -eq $defaultDesiredBeforeNamed) 'Provisioning a named profile changed the default desired capacity.'
        Add-Check ($namedCommands -match 'build.*--tag.*pitcrew-copilot-cli:1\.0\.71') 'Named setup did not build the profile image.'
        Add-Check ($namedCommands -match 'run.*--entrypoint.*/bin/sh.*copilot --version') 'Named setup did not run profile verification commands.'
        Add-Check ($namedCommands -match 'compose.*--project-name.*self-hosted-runner-copilot-cli.*up') 'Named setup did not start its isolated Compose project.'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup -Profile copilot-cli -Down
        $namedDownCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($namedDownCommands -match 'compose.*--project-name.*self-hosted-runner-copilot-cli.*down') 'Named teardown did not target its Compose project.'
        Add-Check ($namedDownCommands -match 'ps.*label=ephemeral-managed-runner-profile=copilot-cli') 'Named teardown did not target its exact Docker label.'
        Add-Check (-not ($namedDownCommands | Where-Object { $_ -match '(^|\t)label=ephemeral-managed-runner$' })) 'Named teardown targeted the legacy global Docker label.'
        Add-Check (-not ($namedDownCommands -match 'name=')) 'Named teardown used a broad container-name filter.'

        Remove-Item `
            -LiteralPath (Join-Path (Split-Path -Parent $defaultDesiredPath) 'observed-state.json') `
            -Force `
            -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup -Down
        $defaultDownCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($defaultDownCommands -match 'compose.*--project-name.*self-hosted-runner.*down') 'Default teardown changed its Compose project.'
        Add-Check ($defaultDownCommands | Where-Object { $_ -match '(^|\t)label=ephemeral-managed-runner$' }) 'Default teardown no longer migrates the legacy global Docker label.'
        Add-Check (-not ($defaultDownCommands -match 'name=')) 'Default teardown can remove another profile through a broad container-name filter.'
    }
    finally {
        Remove-Item Function:\global:docker -ErrorAction SilentlyContinue
        if ($previousDockerFunction) {
            Set-Item Function:\global:docker -Value $previousDockerFunction.ScriptBlock
        }
        Remove-Item Function:\global:Invoke-RestMethod -ErrorAction SilentlyContinue
        if ($previousInvokeRestMethodFunction) {
            Set-Item Function:\global:Invoke-RestMethod -Value $previousInvokeRestMethodFunction.ScriptBlock
        }
        foreach ($name in $ambientNames) {
            if ($savedAmbient[$name].Exists) {
                Set-Item -LiteralPath "Env:$name" -Value $savedAmbient[$name].Value
            } else {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }
        Remove-Item Env:\PITCREW_RUNNER_DOCKER_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_RUNNING -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_REJECT_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_IMAGE_MISSING -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_START_FAILURE -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_START_FAILURE_USED -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$manager = Get-Content -LiteralPath $managerPath -Raw -Encoding UTF8
$managerEntrypoint = Get-Content -LiteralPath $managerEntrypointPath -Raw -Encoding UTF8
$autoscalerModule = Get-Content -LiteralPath $autoscalerModulePath -Raw -Encoding UTF8
$managerDockerfile = Get-Content -LiteralPath $managerDockerfilePath -Raw -Encoding UTF8
$observability = Get-Content -LiteralPath $observabilityPath -Raw -Encoding UTF8
$compose = Get-Content -LiteralPath $composePath -Raw -Encoding UTF8
$exampleEnvironment = Get-Content -LiteralPath (Join-Path $runnerRoot '.env.example') -Raw -Encoding UTF8
$routing = Get-Content -LiteralPath $routingPath -Raw -Encoding UTF8
Add-Check ($manager -match [regex]::Escape('MANAGED_LABEL="${MANAGED_LABEL_KEY}=${PROFILE_ID}"')) 'The manager cleanup label is not profile-specific.'
Add-Check ($manager -match [regex]::Escape('-e NO_DEFAULT_LABELS=1')) 'The manager does not support isolated registration without GitHub default labels.'
Add-Check ($manager -match [regex]::Escape('-e UNSET_CONFIG_VARS=false')) 'The runner entry point cannot retain its private credential for graceful deregistration.'
Add-Check ($manager -match [regex]::Escape('-e DISABLE_AUTOMATIC_DEREGISTRATION=false')) 'The manager does not require worker deregistration on graceful stop.'
Add-Check ($manager -match [regex]::Escape('RUNNER_PULL_IMAGE:-1')) 'The manager cannot distinguish pullable and locally prepared images.'
Add-Check ($manager -match [regex]::Escape('last-valid-capacity.json')) 'The manager does not persist the last valid desired state.'
Add-Check ($manager -match [regex]::Escape('bootstrap_legacy_desired_state')) 'The manager does not bootstrap pre-reconciliation capacity.'
Add-Check ($manager -match [regex]::Escape('acknowledgement_matches_current')) 'The manager does not repair stale acknowledgements.'
Add-Check ($manager -match [regex]::Escape('LAST_DESIRED_DOCUMENT_HASH')) 'The manager reparses unchanged desired JSON on every poll.'
Add-Check ($manager -notmatch 'grep -Fqx') 'The manager still performs a quadratic desired-key scan.'
Add-Check ($manager -match [regex]::Escape('/drain')) 'The manager does not represent graceful slot draining.'
Add-Check ($manager -match [regex]::Escape('ephemeral-managed-runner-slot')) 'Worker containers do not expose stable slot identity.'
Add-Check ($manager -match [regex]::Escape('pitcrew-worker-revision')) 'Worker containers do not expose their rolling-update revision.'
Add-Check ($manager -match [regex]::Escape('restore_managed_slots')) 'A replacement manager cannot adopt workers from its predecessor.'
Add-Check ($manager -match [regex]::Escape('received manager handoff signal; preserving managed runner containers')) 'Manager handoff still tears down profile workers.'
Add-Check ($manager -match [regex]::Escape('docker run --rm --detach')) 'Fixed workers are not detached for manager adoption.'
Add-Check ($manager -notmatch 'clearing any leftover managed runners') 'Manager startup still destroys workers left by its predecessor.'
Add-Check ($manager -match [regex]::Escape('observed-state.json')) 'The manager does not project credential-free observed state.'
Add-Check ($manager -match [regex]::Escape('PITCREW_OBSERVED_STATE_INTERVAL:-30')) 'The manager does not bound observed-state heartbeat writes.'
Add-Check ($manager -match [regex]::Escape('collect_resource_telemetry')) 'The manager does not collect resource telemetry through observed state.'
Add-Check ($managerEntrypoint -match [regex]::Escape('PITCREW_AUTOSCALING_MODE')) 'The manager entrypoint does not select autoscaling mode.'
Add-Check ($managerEntrypoint -match [regex]::Escape('exec /usr/local/bin/pitcrew-autoscaler')) 'The manager entrypoint does not launch the scale-set autoscaler.'
Add-Check ($autoscalerModule -match 'github\.com/actions/scaleset v0\.4\.0') 'The autoscaler does not pin the reviewed scale-set client version.'
Add-Check ($manager -match [regex]::Escape('if [ "${STOPPING}" -eq 1 ]; then')) 'Manager shutdown can block on a fresh resource-telemetry sample.'
Add-Check ($manager -match [regex]::Escape(': > "${stopping_path}/drain"')) 'Manager shutdown does not drain slot supervisors before cleanup.'
Add-Check ($manager -match [regex]::Escape('docker stop \')) 'Manager shutdown does not signal worker entry points before force removal.'
Add-Check ($manager -match [regex]::Escape('--timeout "${RUNNER_STOP_TIMEOUT}"')) 'Manager shutdown does not bound graceful worker deregistration.'
Add-Check ($manager -match [regex]::Escape('if ! remove_managed_strict; then')) 'Manager shutdown can publish stopped without confirming runner cleanup.'
Add-Check ($manager -match [regex]::Escape('rm -f "${OBSERVED_STATE_DIRTY}"')) 'Observed-state publication does not preserve concurrent dirty notifications.'
Add-Check ($managerDockerfile -match 'FROM docker:28-cli AS docker-cli') 'The manager does not isolate the Docker client build stage.'
Add-Check ($managerDockerfile -match 'FROM golang:1\.25\.3-alpine AS autoscaler-build') 'The manager does not pin the autoscaler Go build stage.'
Add-Check ($managerDockerfile -match [regex]::Escape('COPY --from=autoscaler-build /out/pitcrew-autoscaler /usr/local/bin/pitcrew-autoscaler')) 'The manager runtime does not include the scale-set autoscaler.'
Add-Check ($managerDockerfile -match 'FROM alpine:3\.22') 'The manager runtime is not based on minimal Alpine.'
Add-Check ($managerDockerfile -match [regex]::Escape('COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker')) 'The manager runtime does not copy only the Docker client binary.'
Add-Check ($managerDockerfile -match 'ARG JQ_VERSION=1\.8\.2') 'The manager does not pin its jq release.'
Add-Check ($managerDockerfile -match 'JQ_SHA256_AMD64=[0-9a-f]{64}') 'The manager does not checksum-pin jq for amd64.'
Add-Check ($managerDockerfile -match 'JQ_SHA256_ARM64=[0-9a-f]{64}') 'The manager does not checksum-pin jq for arm64.'
Add-Check ($managerDockerfile -match [regex]::Escape('sha256sum -c -')) 'The manager does not verify the downloaded jq binary.'
Add-Check ($managerDockerfile -match 'until wget') 'The manager does not retry transient jq download failures.'
Add-Check ($managerDockerfile -notmatch 'apk add') 'The manager still resolves jq through a mutable Alpine package repository.'
Add-Check ($managerDockerfile -match [regex]::Escape('ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]')) 'The manager image does not use the mode-selecting entrypoint.'
Add-Check ($observability -match [regex]::Escape('docker stats')) 'Resource telemetry does not use the existing manager Docker client.'
Add-Check ($observability -match [regex]::Escape('timeout "${command_timeout}"')) 'Resource telemetry Docker calls do not have a hard deadline.'
Add-Check ($observability -match [regex]::Escape('cpuCores')) 'Resource telemetry does not expose normalized CPU cores.'
Add-Check ($observability -match [regex]::Escape('memoryWorkingSetBytes')) 'Resource telemetry does not expose memory working-set bytes.'
Add-Check ($compose -match [regex]::Escape('RUNNER_PROFILE_ID: ${RUNNER_PROFILE_ID:-default}')) 'Compose does not pass the profile identity to the manager.'
Add-Check ($compose -match [regex]::Escape('image: ephemeral-runner-manager:profile-${RUNNER_PROFILE_ID:-default}')) 'Manager image tags are not isolated by profile.'
Add-Check ($compose -match [regex]::Escape('${PITCREW_STATE_DIR:-.pitcrew-state/default}:/var/lib/pitcrew')) 'Compose does not mount the mutable state directory.'
Add-Check ($compose -match 'stop_grace_period:\s*60s') 'Compose does not allow autoscaling manager shutdown to complete bounded cleanup.'
Add-Check ($compose -match [regex]::Escape('RUNNER_REPLICAS: ${RUNNER_REPLICAS:-1}')) 'Compose does not expose the legacy capacity bootstrap adapter.'
Add-Check ($compose -match [regex]::Escape('REPO_URLS: ${REPO_URLS:-}')) 'Compose does not expose legacy repository targets to the bootstrap adapter.'
Add-Check ($compose -match [regex]::Escape('PITCREW_WORKER_REVISION: ${PITCREW_WORKER_REVISION:-}')) 'Compose does not pass worker revision state to the manager.'
Add-Check ($compose -match [regex]::Escape('PITCREW_SESSION_OWNER: ${PITCREW_SESSION_OWNER:-}')) 'Compose does not pass the stable scale-set session owner.'
Add-Check ($compose -match [regex]::Escape('pitcrew-manager-contract-version: ${PITCREW_MANAGER_CONTRACT_VERSION:-9}')) 'Manager containers do not expose their handoff contract.'
Add-Check ($compose -notmatch '/var/run/docker\.sock:.+runner') 'Compose appears to expose the Docker socket to a runner service.'
Add-Check ($exampleEnvironment -match '(?m)^PITCREW_MANAGER_CONTRACT_VERSION=9$') 'The example environment does not pin the current manager contract.'
Add-Check ($routing -match 'general-purpose') 'Routing guidance does not define the general-purpose pool label.'
Add-Check ($routing -match 'runs-on: \[linux, x64, copilot-cli\]') 'Routing guidance does not show isolated specialized routing.'
Add-Check ($routing -match 'Do not add `self-hosted`') 'Routing guidance does not warn against defeating specialized isolation.'

if ($errors.Count -gt 0) {
    foreach ($errorMessage in $errors) {
        Write-Host "ERROR: $errorMessage" -ForegroundColor Red
    }
    throw "PitCrew contract validation failed with $($errors.Count) error(s)."
}

Write-Host "PitCrew contract validation passed: $checks assertions." -ForegroundColor Green
