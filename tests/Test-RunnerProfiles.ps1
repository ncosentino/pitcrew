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
$automationControlProfilePath = Join-Path `
    $runnerRoot 'profiles' 'automation-control' 'profile.json'
$automationControlDockerfilePath = Join-Path `
    $runnerRoot 'profiles' 'automation-control' 'Dockerfile'
$imageBuilderProfilePath = Join-Path $runnerRoot 'profiles' 'image-builder' 'profile.json'
$imageBuilderDockerfilePath = Join-Path $runnerRoot 'profiles' 'image-builder' 'Dockerfile'
$androidProfilePath = Join-Path $runnerRoot 'profiles' 'android-emulator' 'profile.json'
$androidDockerfilePath = Join-Path $runnerRoot 'profiles' 'android-emulator' 'Dockerfile'
$androidStartPath = Join-Path $runnerRoot 'profiles' 'android-emulator' 'start-android-emulator'
$managerPath = Join-Path $runnerRoot 'manager' 'manage-runners.sh'
$managerEntrypointPath = Join-Path $runnerRoot 'manager' 'entrypoint.sh'
$autoscalerModulePath = Join-Path $runnerRoot 'manager' 'autoscaler' 'go.mod'
$autoscalerHardwarePath = Join-Path $runnerRoot 'manager' 'autoscaler' 'hardware.go'
$managerDockerfilePath = Join-Path $runnerRoot 'manager' 'Dockerfile'
$observabilityPath = Join-Path $runnerRoot 'manager' 'observability.sh'
$diagnosticsPath = Join-Path $runnerRoot 'manager' 'diagnostics.sh'
$reconciliationPath = Join-Path $runnerRoot 'manager' 'reconciliation.sh'
$composePath = Join-Path $runnerRoot 'docker-compose.yml'
$hostAdmissionComposePath = Join-Path $runnerRoot 'host-admission.compose.yml'
$hostAdmissionManagerComposePath = Join-Path $runnerRoot 'host-admission.manager.compose.yml'
$routingPath = Join-Path $runnerRoot 'docs' 'guides' 'routing-workloads.md'
$activeManagerContractVersion = 18
$testWorkerImageId = 'sha256:1111111111111111111111111111111111111111111111111111111111111111'
$changedWorkerImageId = 'sha256:2222222222222222222222222222222222222222222222222222222222222222'
$digestWorkerImage = 'ghcr.io/example/runner@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

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
        'host-admission.compose.yml',
        'host-admission.manager.compose.yml',
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
        managerContractVersion = $activeManagerContractVersion
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
        [int]$UnchangedSlots,
        [ValidateSet(0, 1)]
        [int]$WaitForAcknowledgementRemoval,
        [ValidateRange(0, 5000)]
        [int]$DelayMilliseconds = 0
    )

    return Start-Job -ArgumentList @(
        $DesiredPath,
        $AcknowledgementPath,
        $Generation,
        $DesiredSlots,
        $AddedSlots,
        $DrainingSlots,
        $UnchangedSlots,
        $WaitForAcknowledgementRemoval,
        $DelayMilliseconds,
        $activeManagerContractVersion
    ) -ScriptBlock {
        param(
            $DesiredPath,
            $AcknowledgementPath,
            $Generation,
            $DesiredSlots,
            $AddedSlots,
            $DrainingSlots,
            $UnchangedSlots,
            $WaitForAcknowledgementRemoval,
            $DelayMilliseconds,
            $ManagerContractVersion
        )

        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        $lastObservedGeneration = 'missing'
        $lastReadError = ''
        $acknowledgementRemovalObserved = -not (
            Test-Path -LiteralPath $AcknowledgementPath -PathType Leaf
        )
        $delayApplied = $false
        do {
            if (
                $WaitForAcknowledgementRemoval -eq 1 -and
                -not $acknowledgementRemovalObserved
            ) {
                $acknowledgementRemovalObserved = -not (
                    Test-Path -LiteralPath $AcknowledgementPath -PathType Leaf
                )
                Start-Sleep -Milliseconds 50
                continue
            }
            if (
                $WaitForAcknowledgementRemoval -eq 1 -and
                $acknowledgementRemovalObserved -and
                -not $delayApplied
            ) {
                Start-Sleep -Milliseconds $DelayMilliseconds
                $delayApplied = $true
            }
            if (Test-Path -LiteralPath $DesiredPath -PathType Leaf) {
                try {
                    $desired = Get-Content -LiteralPath $DesiredPath -Raw -Encoding UTF8 |
                        ConvertFrom-Json -Depth 10 -ErrorAction Stop
                    $lastObservedGeneration = [string]$desired.generation
                    $lastReadError = ''
                    if ([int]$desired.generation -eq $Generation) {
                        [PSCustomObject][ordered]@{
                            schemaVersion = 1
                            status = 'accepted'
                            generation = $Generation
                            managerContractVersion = $ManagerContractVersion
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
                    $lastReadError = $_.Exception.Message
                    Start-Sleep -Milliseconds 50
                }
            }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)

        throw "Desired generation $Generation was not observed. Last generation: $lastObservedGeneration. Last read error: $lastReadError"
    }
}

function Set-TestObservedState {
    param(
        [string]$Path,
        [string]$InstanceId,
        [int]$Generation,
        [string]$DesiredStateHash,
        [string]$ManagerStatus,
        [string]$ObservedAt,
        [int]$DesiredSlots,
        [int]$ActiveSlots,
        [int]$EligibleSlots,
        [AllowEmptyString()]
        [string]$AutoscalingStatus
    )

    $document = [PSCustomObject][ordered]@{
        schemaVersion = 1
        managerContractVersion = 10
        profileId = 'default'
        managerInstanceId = $InstanceId
        managerStatus = $ManagerStatus
        observedAt = $ObservedAt
        scope = 'repo'
        generation = $Generation
        desiredStateHash = $DesiredStateHash
        desiredStateStatus = 'accepted'
        desiredSlots = $DesiredSlots
        configuredSlots = $DesiredSlots
        activeSlots = $ActiveSlots
        eligibleSlots = $EligibleSlots
        drainingSlots = 0
        slots = @()
        autoscaling = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($AutoscalingStatus)) {
        $document.autoscaling = [PSCustomObject][ordered]@{
            mode = 'scale-set'
            status = $AutoscalingStatus
            minimumIdleSlots = 0
            maximumSlots = $DesiredSlots
            targetSlots = $ActiveSlots
            assignedJobs = 0
            runningJobs = 0
            availableJobs = 0
            idleRunners = 0
            busyRunners = $ActiveSlots
            scaleDownDelaySeconds = 120
            scaleDownAt = $null
            scaleSetCount = 1
            lastError = $null
        }
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $document |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

$requiredPaths = @(
    $functionsPath,
    $setupPath,
    $schemaPath,
    $observedStateSchemaPath,
    $copilotProfilePath,
    $copilotDockerfilePath,
    $imageBuilderProfilePath,
    $imageBuilderDockerfilePath,
    $androidProfilePath,
    $androidDockerfilePath,
    $androidStartPath,
    $managerPath,
    $managerEntrypointPath,
    $autoscalerModulePath,
    $autoscalerHardwarePath,
    $managerDockerfilePath,
    $observabilityPath,
    $diagnosticsPath,
    $reconciliationPath,
    $composePath,
    $hostAdmissionComposePath,
    $hostAdmissionManagerComposePath,
    $routingPath
)
foreach ($path in $requiredPaths) {
    Add-Check (Test-Path -LiteralPath $path) "Required runner-profile surface is missing: $path"
}

if ($errors.Count -gt 0) {
    throw "PitCrew contract validation could not start:`n$($errors -join "`n")"
}

. $functionsPath

Add-Check (
    (Get-RunnerManagerAcknowledgementTimeoutSeconds -Autoscaling $null) -eq
        60 -and
    (Get-RunnerManagerAcknowledgementTimeoutSeconds `
        -Autoscaling ([PSCustomObject]@{ Mode = 'scale-set' })) -eq 180
) 'Manager handoff acknowledgement timeouts do not distinguish fixed and autoscaled startup.'

$supportAccessRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "pitcrew-support-access-$([Guid]::NewGuid().ToString('N'))"
$supportProfileDirectory = Join-Path $supportAccessRoot 'default'
$supportStateDirectory = Join-Path $supportProfileDirectory 'support-evidence'
$supportStatePath = Join-Path $supportStateDirectory 'desired-capacity.json'
try {
    $null = New-Item `
        -ItemType Directory `
        -Path $supportStateDirectory
    if ($IsWindows) {
        $brokerSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinUsersSid,
            $null)
        $directoryAcl = Get-Acl -LiteralPath $supportStateDirectory
        $directoryAcl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $brokerSid,
                [Security.AccessControl.FileSystemRights]::Read,
                [Security.AccessControl.InheritanceFlags]::ObjectInherit,
                [Security.AccessControl.PropagationFlags]::InheritOnly,
                [Security.AccessControl.AccessControlType]::Allow))
        Set-Acl `
            -LiteralPath $supportStateDirectory `
            -AclObject $directoryAcl
    } else {
        [IO.File]::SetUnixFileMode(
            $supportStateDirectory,
            [IO.UnixFileMode]::UserRead -bor
                [IO.UnixFileMode]::UserWrite -bor
                [IO.UnixFileMode]::UserExecute -bor
                [IO.UnixFileMode]::GroupRead -bor
                [IO.UnixFileMode]::GroupExecute)
    }
    Write-RunnerJsonAtomically `
        -Path $supportStatePath `
        -Value ([PSCustomObject]@{
            generation = 1
        })
    Write-RunnerJsonAtomically `
        -Path $supportStatePath `
        -Value ([PSCustomObject]@{
            generation = 2
        })
    $storedSupportState = Get-Content `
        -LiteralPath $supportStatePath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
    Add-Check (
        $storedSupportState.generation -eq 2 -and
        @(
            Get-ChildItem `
                -LiteralPath $supportStateDirectory `
                -Filter '*.tmp' `
                -Force).Count -eq 0
    ) 'Atomic state publication retained a temporary file or lost the latest state.'
    if ($IsWindows) {
        $fileAcl = Get-Acl -LiteralPath $supportStatePath
        Add-Check (
            @(
                $fileAcl.Access |
                    Where-Object {
                        $_.IdentityReference.Translate(
                            [Security.Principal.SecurityIdentifier]) -eq
                            $brokerSid -and
                        $_.IsInherited -and
                        ($_.FileSystemRights -band
                            [Security.AccessControl.FileSystemRights]::Read) -ne 0
                    }).Count -gt 0
        ) 'Dedicated support evidence publication did not inherit the broker file-read ACE.'
    } else {
        $fileMode = [IO.File]::GetUnixFileMode($supportStatePath)
        Add-Check (
            ($fileMode -band [IO.UnixFileMode]::GroupRead) -ne 0
        ) 'Atomic state publication removed group-readable broker access.'
    }
} finally {
    if (Test-Path -LiteralPath $supportAccessRoot -PathType Container) {
        Remove-Item `
            -LiteralPath $supportAccessRoot `
            -Recurse `
            -Force
    }
}

$profileJson = Get-Content -LiteralPath $copilotProfilePath -Raw -Encoding UTF8
Add-Check ($profileJson | Test-Json -SchemaFile $schemaPath) 'The built-in Copilot CLI profile does not conform to runner-profile.schema.json.'
$automationControlProfileJson = Get-Content `
    -LiteralPath $automationControlProfilePath `
    -Raw `
    -Encoding UTF8
$imageBuilderProfileJson = Get-Content -LiteralPath $imageBuilderProfilePath -Raw -Encoding UTF8
$androidProfileJson = Get-Content -LiteralPath $androidProfilePath -Raw -Encoding UTF8
Add-Check ($automationControlProfileJson | Test-Json -SchemaFile $schemaPath) 'The built-in automation-control profile does not conform to runner-profile.schema.json.'
Add-Check ($imageBuilderProfileJson | Test-Json -SchemaFile $schemaPath) 'The built-in image-builder profile does not conform to runner-profile.schema.json.'
Add-Check ($androidProfileJson | Test-Json -SchemaFile $schemaPath) 'The built-in Android emulator profile does not conform to runner-profile.schema.json.'
$autoscalingManifest = $profileJson | ConvertFrom-Json -Depth 20
$autoscalingManifest | Add-Member -NotePropertyName autoscaling -NotePropertyValue ([PSCustomObject]@{
    mode = 'scale-set'
    minimumIdle = 0
    scaleDownDelaySeconds = 120
    maximumActiveWorkers = 4
})
$autoscalingManifest | Add-Member -NotePropertyName resources -NotePropertyValue ([PSCustomObject]@{
    memory = '512MiB'
    memorySwap = '1g'
    cpus = '2.5'
    pids = 256
})
$autoscalingManifest | Add-Member -NotePropertyName runtime -NotePropertyValue ([PSCustomObject]@{
    devices = @('kvm')
    sharedMemory = '2g'
})
$autoscalingManifest | Add-Member -NotePropertyName hostAdmission -NotePropertyValue ([PSCustomObject]@{
    namespace = 'primary'
    capacityUnits = 12
    safetyMarginUnits = 2
    workerCostUnits = 2
    reservationUnits = 4
    borrowable = $false
})
Add-Check (
    ($autoscalingManifest | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $schemaPath
) 'The profile schema rejects valid autoscaling, runtime, resource, or host-admission policy.'
$unknownRuntimeDeviceManifest = (
    $autoscalingManifest |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$unknownRuntimeDeviceManifest.runtime.devices = @('docker-socket')
Add-Check (-not (
    ($unknownRuntimeDeviceManifest | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
)) 'The profile schema accepts an arbitrary worker device.'
$unknownRuntimeFieldManifest = (
    $autoscalingManifest |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$unknownRuntimeFieldManifest.runtime |
    Add-Member -NotePropertyName privileged -NotePropertyValue $true
Add-Check (-not (
    ($unknownRuntimeFieldManifest | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
)) 'The profile schema accepts blanket worker privilege.'
$missingBorrowableManifest = (
    $autoscalingManifest |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$missingBorrowableManifest.hostAdmission.PSObject.Properties.Remove('borrowable')
Add-Check (-not (
    ($missingBorrowableManifest | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
)) 'The profile schema accepts a host-admission reservation without explicit borrowability.'
$unknownAdmissionFieldManifest = (
    $autoscalingManifest |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$unknownAdmissionFieldManifest.hostAdmission |
    Add-Member -NotePropertyName workflowPriority -NotePropertyValue 'urgent'
Add-Check (-not (
    ($unknownAdmissionFieldManifest | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
)) 'The profile schema accepts workflow-specific host-admission policy.'
$invalidResourceManifest = (
    $autoscalingManifest |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$invalidResourceManifest.resources.PSObject.Properties.Remove('memory')
Add-Check (-not (
    ($invalidResourceManifest | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
)) 'The profile schema accepts memorySwap without memory.'
$emptyResourceManifest = (
    $autoscalingManifest |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$emptyResourceManifest.resources = [PSCustomObject]@{}
Add-Check (-not (
    ($emptyResourceManifest | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
)) 'The profile schema accepts an empty resource policy.'
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
$observedStateV10 = (
    $observedStateV9 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$observedStateV10.managerContractVersion = 10
$observedStateV10 | Add-Member -NotePropertyName eligibleSlots -NotePropertyValue 0
Add-Check (
    ($observedStateV10 | ConvertTo-Json -Depth 8) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract ten registration state does not conform to observed-state.schema.json.'
$connectedStateV10 = (
    $observedStateV7 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$connectedStateV10.managerContractVersion = 10
$connectedStateV10 | Add-Member -NotePropertyName configuredSlots -NotePropertyValue 1
$connectedStateV10 | Add-Member -NotePropertyName autoscaling -NotePropertyValue $null
$connectedStateV10 | Add-Member -NotePropertyName update -NotePropertyValue (
    [PSCustomObject][ordered]@{
        status = 'current'
        targetRevision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        currentWorkers = 1
        staleWorkers = 0
        lastError = $null
    }
)
$connectedStateV10 | Add-Member -NotePropertyName eligibleSlots -NotePropertyValue 1
$connectedStateV10.slots[0] |
    Add-Member -NotePropertyName registrationStatus -NotePropertyValue 'connected'
Add-Check (
    ($connectedStateV10 | ConvertTo-Json -Depth 8) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract ten rejects a connected fixed-capacity slot.'
$fixedStateV11 = (
    $connectedStateV10 |
        ConvertTo-Json -Depth 12 |
        ConvertFrom-Json -Depth 12
)
$fixedStateV11.managerContractVersion = 11
$fixedStateV11.update |
    Add-Member -NotePropertyName targetImage -NotePropertyValue 'example/runner:1.0'
$fixedStateV11.update |
    Add-Member -NotePropertyName targetImageId -NotePropertyValue (
        'sha256:1111111111111111111111111111111111111111111111111111111111111111')
$fixedStateV11 | Add-Member -NotePropertyName resourcePolicy -NotePropertyValue (
    [PSCustomObject][ordered]@{
        memoryBytes = 536870912
        memorySwapBytes = 1073741824
        cpuCores = '2.5'
        pids = 256
    }
)
$fixedStateV11.slots[0].resources |
    Add-Member -NotePropertyName networkRxBytes -NotePropertyValue 1048576
$fixedStateV11.slots[0].resources |
    Add-Member -NotePropertyName networkTxBytes -NotePropertyValue 131072
$fixedStateV11.slots[0].resources |
    Add-Member -NotePropertyName blockReadBytes -NotePropertyValue $null
$fixedStateV11.slots[0].resources |
    Add-Member -NotePropertyName blockWriteBytes -NotePropertyValue 2147483648
$fixedStateV11.slots[0] |
    Add-Member -NotePropertyName imageId -NotePropertyValue $testWorkerImageId
$fixedStateV11.slots[0] |
    Add-Member -NotePropertyName lastExit -NotePropertyValue (
        [PSCustomObject][ordered]@{
            observedAt = '2026-01-01T00:00:00Z'
            classification = 'oom-killed'
            exitCode = 137
            signal = 9
            dockerOomKilled = $true
            evidence = 'docker-inspect'
        }
    )
Add-Check (
    ($fixedStateV11 | ConvertTo-Json -Depth 12) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract eleven rejects a valid fixed resource, image, I/O, and exit projection.'

$autoscaledStateV11 = (
    $observedStateV10 |
        ConvertTo-Json -Depth 12 |
        ConvertFrom-Json -Depth 12
)
$autoscaledStateV11.managerContractVersion = 11
$autoscaledStateV11 | Add-Member -NotePropertyName resourcePolicy -NotePropertyValue $null
$autoscaledStateV11.autoscaling.status = 'degraded'
$autoscaledStateV11.autoscaling.lastError = 'Local worker counts diverge from GitHub runner registrations.'
$autoscaledStateV11.autoscaling |
    Add-Member -NotePropertyName maximumActiveWorkers -NotePropertyValue 4
$autoscaledStateV11.autoscaling |
    Add-Member -NotePropertyName targets -NotePropertyValue @(
        [PSCustomObject][ordered]@{
            key = 'repo-needlr'
            repository = 'https://github.com/ncosentino/needlr'
            maximumSlots = 4
            targetSlots = 2
            localActiveWorkers = 2
            localIdleWorkers = 0
            localBusyWorkers = 2
            localDrainingWorkers = 0
            statistics = [PSCustomObject][ordered]@{
                observedAt = '2026-01-01T00:00:00Z'
                availableJobs = 0
                acquiredJobs = 0
                assignedJobs = 0
                runningJobs = 0
                registeredRunners = 0
                busyRunners = 0
                idleRunners = 0
            }
        },
        [PSCustomObject][ordered]@{
            key = 'repo-project-b'
            repository = 'https://github.com/example/project-b'
            maximumSlots = 4
            targetSlots = 2
            localActiveWorkers = 2
            localIdleWorkers = 0
            localBusyWorkers = 2
            localDrainingWorkers = 0
            statistics = [PSCustomObject][ordered]@{
                observedAt = '2026-01-01T00:00:00Z'
                availableJobs = 0
                acquiredJobs = 1
                assignedJobs = 2
                runningJobs = 1
                registeredRunners = 8
                busyRunners = 2
                idleRunners = 0
            }
        }
    )
Add-Check (
    ($autoscaledStateV11 | ConvertTo-Json -Depth 12) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract eleven rejects explicit per-target local/control-plane divergence.'
Add-Check (
    $autoscaledStateV11.autoscaling.status -ceq 'degraded'
) 'Local/control-plane divergence was presented as a healthy autoscaler state.'
Add-Check (
    $autoscaledStateV11.autoscaling.targets[0].localActiveWorkers -eq 2 -and
    $autoscaledStateV11.autoscaling.targets[0].statistics.registeredRunners -eq 0
) 'The 2-live/0-registered example collapsed local and GitHub evidence.'
Add-Check (
    $autoscaledStateV11.autoscaling.targets[1].localActiveWorkers -eq 2 -and
    $autoscaledStateV11.autoscaling.targets[1].statistics.registeredRunners -eq 8
) 'The 2-live/8-registered example collapsed local and GitHub evidence.'
$unavailableStatisticsV11 = (
    $autoscaledStateV11 |
        ConvertTo-Json -Depth 12 |
        ConvertFrom-Json -Depth 12
)
$unavailableStatisticsV11.autoscaling.targets[0].statistics = $null
Add-Check (
    ($unavailableStatisticsV11 | ConvertTo-Json -Depth 12) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract eleven rejects explicitly unavailable scale-set statistics.'
$unavailableStatisticsRoundTripV11 = (
    $unavailableStatisticsV11 |
        ConvertTo-Json -Depth 12 |
        ConvertFrom-Json -Depth 12
)
Add-Check (
    $null -eq $unavailableStatisticsRoundTripV11.autoscaling.targets[0].statistics -and
    $unavailableStatisticsRoundTripV11.autoscaling.targets[1].statistics.registeredRunners -eq 8 -and
    [DateTimeOffset]$unavailableStatisticsRoundTripV11.autoscaling.targets[1].statistics.observedAt -eq
        [DateTimeOffset]'2026-01-01T00:00:00Z'
) 'Unavailable or timestamped scale-set evidence did not round-trip distinctly from measured zero.'
$missingContractV11Image = (
    $fixedStateV11 |
        ConvertTo-Json -Depth 12 |
        ConvertFrom-Json -Depth 12
)
$missingContractV11Image.slots[0].PSObject.Properties.Remove('imageId')
Add-Check (-not (
    ($missingContractV11Image | ConvertTo-Json -Depth 12) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract eleven accepts a slot without immutable image identity evidence.'
$missingContractV11Io = (
    $fixedStateV11 |
        ConvertTo-Json -Depth 12 |
        ConvertFrom-Json -Depth 12
)
$missingContractV11Io.slots[0].resources.PSObject.Properties.Remove('blockWriteBytes')
Add-Check (-not (
    ($missingContractV11Io | ConvertTo-Json -Depth 12) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract eleven accepts worker telemetry without all nullable I/O counters.'
$missingStatisticsFreshnessV11 = (
    $autoscaledStateV11 |
        ConvertTo-Json -Depth 12 |
        ConvertFrom-Json -Depth 12
)
$missingStatisticsFreshnessV11.autoscaling.targets[0].statistics.PSObject.Properties.Remove(
    'observedAt')
Add-Check (-not (
    ($missingStatisticsFreshnessV11 | ConvertTo-Json -Depth 12) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract eleven accepts scale-set statistics without freshness evidence.'
$missingRegistrationV10 = (
    $connectedStateV10 |
        ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
)
$missingRegistrationV10.slots[0].PSObject.Properties.Remove('registrationStatus')
Add-Check (-not (
    ($missingRegistrationV10 | ConvertTo-Json -Depth 8) |
        Test-Json `
            -SchemaFile $observedStateSchemaPath `
            -ErrorAction SilentlyContinue
)) 'Manager contract ten accepts a slot without registration status.'
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

$journalV12 = [PSCustomObject][ordered]@{
    status = 'current'
    capacity = 64
    highestSequence = 45
    droppedEvents = 0
    events = @(
        [PSCustomObject][ordered]@{
            sequence = 41
            managerInstanceId = 'manager-instance-a'
            observedAt = '2026-01-01T00:00:00Z'
            subsystem = 'docker'
            operation = 'docker-run'
            target = 'repo-example-000001'
            outcome = 'failed'
            durationMilliseconds = 1200
            attempt = 1
            consecutiveFailures = 1
            retryAt = $null
            reason = 'docker-failed'
            evidence = 'Worker launch was rejected by the Docker daemon'
        },
        [PSCustomObject][ordered]@{
            sequence = 42
            managerInstanceId = 'manager-instance-a'
            observedAt = '2026-01-01T00:00:10Z'
            subsystem = 'registration'
            operation = 'registration-token-request'
            target = $null
            outcome = 'timed-out'
            durationMilliseconds = 30000
            attempt = 1
            consecutiveFailures = 1
            retryAt = $null
            reason = 'timeout'
            evidence = 'Registration token request exceeded its deadline'
        },
        [PSCustomObject][ordered]@{
            sequence = 43
            managerInstanceId = 'manager-instance-a'
            observedAt = '2026-01-01T00:00:20Z'
            subsystem = 'worker-launch'
            operation = 'worker-launch'
            target = 'repo-example-000001'
            outcome = 'retry-scheduled'
            durationMilliseconds = $null
            attempt = 2
            consecutiveFailures = 2
            retryAt = '2026-01-01T00:00:50Z'
            reason = 'retry-backoff'
            evidence = 'Worker launch is waiting for its backoff window'
        },
        [PSCustomObject][ordered]@{
            sequence = 44
            managerInstanceId = 'manager-instance-b'
            observedAt = '2026-01-01T00:01:00Z'
            subsystem = 'recovery'
            operation = 'journal-restore'
            target = $null
            outcome = 'recovered'
            durationMilliseconds = 5
            attempt = $null
            consecutiveFailures = 0
            retryAt = $null
            reason = 'recovered'
            evidence = 'Restored the persisted operation journal after restart'
        },
        [PSCustomObject][ordered]@{
            sequence = 45
            managerInstanceId = 'manager-instance-b'
            observedAt = '2026-01-01T00:01:01Z'
            subsystem = 'docker'
            operation = 'docker-ping'
            target = $null
            outcome = 'succeeded'
            durationMilliseconds = 0
            attempt = 1
            consecutiveFailures = 0
            retryAt = $null
            reason = 'none'
            evidence = $null
        }
    )
}
$subsystemHealthV12 = [PSCustomObject][ordered]@{
    docker = [PSCustomObject][ordered]@{
        state = 'healthy'
        observedAt = '2026-01-01T00:01:01Z'
        consecutiveFailures = 0
        retryAt = $null
        lastSuccess = [PSCustomObject][ordered]@{
            operation = 'docker-ping'
            observedAt = '2026-01-01T00:01:01Z'
            durationMilliseconds = 0
            reason = 'none'
            evidence = $null
        }
        lastFailure = [PSCustomObject][ordered]@{
            operation = 'docker-run'
            observedAt = '2026-01-01T00:00:00Z'
            durationMilliseconds = 1200
            reason = 'docker-failed'
            evidence = 'Worker launch was rejected by the Docker daemon'
        }
    }
    github = [PSCustomObject][ordered]@{
        state = 'degraded'
        observedAt = '2026-01-01T00:01:01Z'
        consecutiveFailures = 1
        retryAt = '2026-01-01T00:01:30Z'
        lastSuccess = $null
        lastFailure = [PSCustomObject][ordered]@{
            operation = 'registration-token-request'
            observedAt = '2026-01-01T00:00:10Z'
            durationMilliseconds = 30000
            reason = 'timeout'
            evidence = 'Registration token request exceeded its deadline'
        }
    }
}
$fixedStateV12 = (
    $fixedStateV11 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$fixedStateV12.managerContractVersion = 12
$fixedStateV12 | Add-Member -NotePropertyName operationJournal -NotePropertyValue (
    $journalV12 | ConvertTo-Json -Depth 16 | ConvertFrom-Json -Depth 16
)
$fixedStateV12 | Add-Member -NotePropertyName subsystemHealth -NotePropertyValue (
    $subsystemHealthV12 | ConvertTo-Json -Depth 16 | ConvertFrom-Json -Depth 16
)
$fixedStateV12 | Add-Member -NotePropertyName capacityEvidence -NotePropertyValue (
    [PSCustomObject][ordered]@{
        fixed = [PSCustomObject][ordered]@{
            observedAt = '2026-01-01T00:01:01Z'
            freshness = 'current'
            targetSlots = 2
            activeWorkers = 1
            startingWorkers = 0
            drainingWorkers = 0
            cleanupPendingWorkers = 0
            eligibleWorkers = 1
            localDeficit = 1
            eligibilityDeficit = 1
            reason = 'retry-backoff'
            evidence = 'One worker is waiting for its launch backoff window'
        }
        targets = @()
    }
)
Add-Check (
    ($fixedStateV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract twelve rejects a valid fixed journal, health, and deficit projection.'
Add-Check (
    Test-RunnerManagerJournalBudget -Journal $fixedStateV12.operationJournal
) 'The contract-twelve journal example exceeds the documented bound.'
$roundTrippedJournalV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
).operationJournal
Add-Check (
    $roundTrippedJournalV12.events[3].managerInstanceId -cne
        $roundTrippedJournalV12.events[2].managerInstanceId -and
    $roundTrippedJournalV12.events[3].sequence -gt $roundTrippedJournalV12.events[2].sequence -and
    $roundTrippedJournalV12.highestSequence -eq $roundTrippedJournalV12.events[-1].sequence
) 'The journal did not preserve durable sequence identity across a manager restart.'
Add-Check (
    $roundTrippedJournalV12.events[4].durationMilliseconds -eq 0 -and
    $null -eq $roundTrippedJournalV12.events[2].durationMilliseconds
) 'A measured-zero duration did not round-trip distinctly from an unmeasured duration.'
$autoscaledStateV12 = (
    $autoscaledStateV11 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$autoscaledStateV12.managerContractVersion = 12
$autoscaledStateV12 | Add-Member -NotePropertyName operationJournal -NotePropertyValue (
    [PSCustomObject][ordered]@{
        status = 'current'
        capacity = 64
        highestSequence = $null
        droppedEvents = 0
        events = @()
    }
)
$autoscaledStateV12 | Add-Member -NotePropertyName subsystemHealth -NotePropertyValue (
    [PSCustomObject][ordered]@{
        docker = [PSCustomObject][ordered]@{
            state = 'unknown'
            observedAt = '2026-01-01T00:00:00Z'
            consecutiveFailures = 0
            retryAt = $null
            lastSuccess = $null
            lastFailure = $null
        }
        github = [PSCustomObject][ordered]@{
            state = 'unavailable'
            observedAt = '2026-01-01T00:00:00Z'
            consecutiveFailures = 3
            retryAt = '2026-01-01T00:00:30Z'
            lastSuccess = $null
            lastFailure = [PSCustomObject][ordered]@{
                operation = 'session-create'
                observedAt = '2026-01-01T00:00:00Z'
                durationMilliseconds = 30000
                reason = 'timeout'
                evidence = 'Scale set session creation exceeded its deadline'
            }
        }
    }
)
$autoscaledStateV12 | Add-Member -NotePropertyName capacityEvidence -NotePropertyValue (
    [PSCustomObject][ordered]@{
        fixed = $null
        targets = @(
            [PSCustomObject][ordered]@{
                key = 'repo-needlr'
                repository = 'https://github.com/ncosentino/needlr'
                observedAt = '2026-01-01T00:00:00Z'
                freshness = 'current'
                targetSlots = 2
                activeWorkers = 2
                startingWorkers = 0
                drainingWorkers = 0
                cleanupPendingWorkers = 0
                eligibleWorkers = 2
                localDeficit = 0
                eligibilityDeficit = 0
                reason = 'none'
                evidence = $null
            },
            [PSCustomObject][ordered]@{
                key = 'repo-project-b'
                repository = 'https://github.com/example/project-b'
                observedAt = '2026-01-01T00:00:00Z'
                freshness = 'stale'
                targetSlots = 2
                activeWorkers = 0
                startingWorkers = 0
                drainingWorkers = 0
                cleanupPendingWorkers = 1
                eligibleWorkers = $null
                localDeficit = 2
                eligibilityDeficit = $null
                reason = 'registration-cleanup-pending'
                evidence = 'Replacement admission is waiting for registration cleanup'
            }
        )
    }
)
Add-Check (
    ($autoscaledStateV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract twelve rejects per-target deficit evidence and an empty journal.'
Add-Check (
    $autoscaledStateV12.capacityEvidence.targets[0].targetSlots -eq
        $autoscaledStateV12.autoscaling.targets[0].targetSlots -and
    $autoscaledStateV12.capacityEvidence.targets[0].targetSlots -lt
        $autoscaledStateV12.autoscaling.targets[0].maximumSlots -and
    $autoscaledStateV12.capacityEvidence.targets[0].localDeficit -eq 0 -and
    $autoscaledStateV12.capacityEvidence.targets[0].reason -ceq 'none'
) 'A configured autoscaling maximum was presented as a capacity deficit.'
$unavailableEvidenceV12 = (
    $autoscaledStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$unavailableEvidenceV12.capacityEvidence.targets[1].freshness = 'unavailable'
$unavailableEvidenceV12.capacityEvidence.targets[1].reason = 'unknown'
Add-Check (
    ($unavailableEvidenceV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract twelve rejects explicitly unavailable capacity evidence.'
$unavailableWithReasonV12 = (
    $unavailableEvidenceV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$unavailableWithReasonV12.capacityEvidence.targets[1].reason = 'session-unavailable'
Add-Check (-not (
    ($unavailableWithReasonV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Unavailable capacity evidence claimed a blocking reason it could not observe.'
$unavailableJournalV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$unavailableJournalV12.operationJournal.status = 'unavailable'
$unavailableJournalV12.operationJournal.highestSequence = $null
$unavailableJournalV12.operationJournal.events = @()
$unavailableJournalV12.operationJournal.droppedEvents = 5
Add-Check (
    ($unavailableJournalV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'A discarded journal invalidated otherwise valid observed state.'
$retainedEventsWhileUnavailableV12 = (
    $unavailableJournalV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$retainedEventsWhileUnavailableV12.operationJournal.events = @(
    $journalV12.events[0] | ConvertTo-Json -Depth 16 | ConvertFrom-Json -Depth 16
)
Add-Check (-not (
    ($retainedEventsWhileUnavailableV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'An unavailable journal reported retained events.'
$silentTruncationV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$silentTruncationV12.operationJournal.status = 'truncated'
Add-Check (-not (
    ($silentTruncationV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A truncated journal hid the number of discarded events.'
$oversizedJournalV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$oversizedTemplate = $journalV12.events[0] |
    ConvertTo-Json -Depth 16 |
    ConvertFrom-Json -Depth 16
$oversizedEvents = [System.Collections.Generic.List[object]]::new()
foreach ($sequence in 1..65) {
    $oversizedEvent = $oversizedTemplate |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
    $oversizedEvent.sequence = $sequence
    $oversizedEvents.Add($oversizedEvent)
}
$oversizedJournalV12.operationJournal.events = @($oversizedEvents)
$oversizedJournalV12.operationJournal.highestSequence = 65
Add-Check (-not (
    ($oversizedJournalV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'The observed-state schema accepts an unbounded operation journal.'
Add-Check (-not (
    Test-RunnerManagerJournalBudget -Journal $oversizedJournalV12.operationJournal
)) 'The journal budget accepts more retained events than the contract allows.'
$oversizedBytesJournalV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$oversizedBytesEvents = [System.Collections.Generic.List[object]]::new()
foreach ($sequence in 1..64) {
    $oversizedBytesEvent = $oversizedTemplate |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
    $oversizedBytesEvent.sequence = $sequence
    $oversizedBytesEvent.evidence = 'Worker launch was rejected by the Docker daemon and is bounded'.PadRight(160, '.')
    $oversizedBytesEvents.Add($oversizedBytesEvent)
}
$oversizedBytesJournalV12.operationJournal.events = @($oversizedBytesEvents)
$oversizedBytesJournalV12.operationJournal.highestSequence = 64
Add-Check (
    ($oversizedBytesJournalV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'The observed-state schema rejects a journal that only the size budget bounds.'
Add-Check (-not (
    Test-RunnerManagerJournalBudget -Journal $oversizedBytesJournalV12.operationJournal
)) 'The journal budget accepts a serialized journal beyond the documented size gate.'
$longEvidenceJournalV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$longEvidenceJournalV12.operationJournal.events[0].evidence = 'Worker launch failed'.PadRight(161, '.')
Add-Check (-not (
    ($longEvidenceJournalV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'The observed-state schema accepts unbounded journal evidence text.'
Add-Check (-not (
    Test-RunnerManagerJournalBudget -Journal $longEvidenceJournalV12.operationJournal
)) 'The journal budget accepts unbounded journal evidence text.'
foreach ($leakedEvidence in @(
    'Docker refused https://github.com/example/project',
    'token=abcdef0123456789',
    'error: unauthorized@github')) {
    $leakedJournalV12 = (
        $fixedStateV12 |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json -Depth 16
    )
    $leakedJournalV12.operationJournal.events[0].evidence = $leakedEvidence
    Add-Check (-not (
        ($leakedJournalV12 | ConvertTo-Json -Depth 16) |
            Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
    )) "The observed-state schema accepts unsanitized journal evidence '$leakedEvidence'."
}
$invalidVocabularyV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$invalidVocabularyV12.operationJournal.events[0].operation = 'docker-run-something-new'
Add-Check (-not (
    ($invalidVocabularyV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'The observed-state schema accepts an invented journal operation name.'
$successWithFailureReasonV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$successWithFailureReasonV12.operationJournal.events[4].reason = 'docker-failed'
Add-Check (-not (
    ($successWithFailureReasonV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A succeeded journal event reported a failure reason.'
$failureWithoutReasonV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$failureWithoutReasonV12.operationJournal.events[0].reason = 'none'
Add-Check (-not (
    ($failureWithoutReasonV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A failed journal event reported no typed reason.'
$retryWithoutDeadlineV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$retryWithoutDeadlineV12.operationJournal.events[2].retryAt = $null
Add-Check (-not (
    ($retryWithoutDeadlineV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A scheduled retry omitted its next-attempt deadline.'
$malformedEventV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$malformedEventV12.operationJournal.events[0].PSObject.Properties.Remove('subsystem')
Add-Check (-not (
    ($malformedEventV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'The observed-state schema accepts a journal event without its subsystem.'
$healthyWithFailuresV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$healthyWithFailuresV12.subsystemHealth.docker.consecutiveFailures = 2
Add-Check (-not (
    ($healthyWithFailuresV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A healthy subsystem summary reported consecutive failures.'
$degradedWithoutFailureV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$degradedWithoutFailureV12.subsystemHealth.github.lastFailure = $null
Add-Check (-not (
    ($degradedWithoutFailureV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A degraded subsystem summary reported no failing operation.'
$unknownWithEvidenceV12 = (
    $autoscaledStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$unknownWithEvidenceV12.subsystemHealth.docker.lastSuccess = (
    $subsystemHealthV12.docker.lastSuccess |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
Add-Check (-not (
    ($unknownWithEvidenceV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'An unknown subsystem summary reported an operation it never performed.'
$deficitWithoutReasonV12 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$deficitWithoutReasonV12.capacityEvidence.fixed.reason = 'none'
Add-Check (-not (
    ($deficitWithoutReasonV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A capacity deficit reported no blocking reason.'
$inventedEligibilityV12 = (
    $autoscaledStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$inventedEligibilityV12.capacityEvidence.targets[1].eligibilityDeficit = 2
Add-Check (-not (
    ($inventedEligibilityV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'An eligibility deficit was reported without control-plane evidence.'
$fixedEvidenceWhileAutoscalingV12 = (
    $autoscaledStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$fixedEvidenceWhileAutoscalingV12.capacityEvidence.fixed = (
    $fixedStateV12.capacityEvidence.fixed |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
Add-Check (-not (
    ($fixedEvidenceWhileAutoscalingV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'An autoscaled profile reported fixed-mode capacity evidence.'
foreach ($requiredContractTwelveField in @(
    'operationJournal',
    'subsystemHealth',
    'capacityEvidence')) {
    $missingContractV12 = (
        $fixedStateV12 |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json -Depth 16
    )
    $missingContractV12.PSObject.Properties.Remove($requiredContractTwelveField)
    Add-Check (-not (
        ($missingContractV12 | ConvertTo-Json -Depth 16) |
            Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
    )) "Manager contract twelve accepts observed state without '$requiredContractTwelveField'."
}
Add-Check (
    ($fixedStateV11 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract eleven stopped being accepted after contract twelve was defined.'
$nullDiagnosticsV11 = (
    $fixedStateV11 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$nullDiagnosticsV11 | Add-Member -NotePropertyName operationJournal -NotePropertyValue $null
$nullDiagnosticsV11 | Add-Member -NotePropertyName subsystemHealth -NotePropertyValue $null
$nullDiagnosticsV11 | Add-Member -NotePropertyName capacityEvidence -NotePropertyValue $null
Add-Check (
    ($nullDiagnosticsV11 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Contract-twelve fields are not additive and nullable for older observations.'
Add-Check (
    Test-RunnerManagerJournalBudget -Journal $null
) 'The journal budget rejects a manager that predates contract twelve.'
Add-Check (
    Test-RunnerManagerJournalBudget -Journal $autoscaledStateV12.operationJournal
) 'The journal budget rejects an empty contract-twelve journal.'
foreach ($malformedJournalMember in @('capacity', 'events')) {
    $malformedBudgetJournal = (
        $fixedStateV12 |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json -Depth 16
    ).operationJournal
    $malformedBudgetJournal.PSObject.Properties.Remove($malformedJournalMember)
    Add-Check (-not (
        Test-RunnerManagerJournalBudget -Journal $malformedBudgetJournal
    )) "The journal budget did not discard a journal without '$malformedJournalMember'."
}

$hostHardwareV13 = [PSCustomObject][ordered]@{
    status = 'current'
    collectedAt = '2026-01-01T00:00:00Z'
    attemptedAt = '2026-01-01T00:05:00Z'
    inventoryHash = ('a' * 64)
    processorModel = 'Example Processor 9000'
    architecture = 'amd64'
    physicalCoreCount = 10
    logicalProcessorCount = 20
    performanceCoreCount = $null
    efficiencyCoreCount = $null
    memoryBytes = 34359738368
    operatingSystem = 'Docker Desktop'
    kernelVersion = '6.12.34-test'
    dockerServerVersion = '28.3.3'
    dockerStorageDriver = 'overlayfs'
    dockerBackingFilesystem = 'extfs'
}
$fixedStateV13 = (
    $fixedStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$fixedStateV13.managerContractVersion = 13
$fixedStateV13 | Add-Member -NotePropertyName host -NotePropertyValue (
    [PSCustomObject][ordered]@{
        hardware = $hostHardwareV13 |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json -Depth 16
    }
)
Add-Check (
    ($fixedStateV13 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract thirteen rejects current sanitized hardware inventory.'

$autoscaledStateV13 = (
    $autoscaledStateV12 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$autoscaledStateV13.managerContractVersion = 13
$autoscaledStateV13 | Add-Member -NotePropertyName host -NotePropertyValue (
    [PSCustomObject][ordered]@{
        hardware = $hostHardwareV13 |
            ConvertTo-Json -Depth 16 |
            ConvertFrom-Json -Depth 16
    }
)
Add-Check (
    ($autoscaledStateV13 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract thirteen rejects autoscaled hardware inventory.'

$missingHardwareV13 = (
    $fixedStateV13 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$missingHardwareV13.PSObject.Properties.Remove('host')
Add-Check (-not (
    ($missingHardwareV13 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract thirteen accepts observed state without host hardware.'

$staleHardwareV13 = (
    $fixedStateV13 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$staleHardwareV13.host.hardware.status = 'stale'
$staleHardwareV13.host.hardware.attemptedAt = '2026-01-01T00:10:00Z'
Add-Check (
    ($staleHardwareV13 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract thirteen rejects retained stale hardware inventory.'

$unavailableHardwareV13 = (
    $fixedStateV13 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$unavailableHardwareV13.host.hardware = [PSCustomObject][ordered]@{
    status = 'unavailable'
    collectedAt = $null
    attemptedAt = '2026-01-01T00:10:00Z'
    inventoryHash = $null
    processorModel = $null
    architecture = $null
    physicalCoreCount = $null
    logicalProcessorCount = $null
    performanceCoreCount = $null
    efficiencyCoreCount = $null
    memoryBytes = $null
    operatingSystem = $null
    kernelVersion = $null
    dockerServerVersion = $null
    dockerStorageDriver = $null
    dockerBackingFilesystem = $null
}
Add-Check (
    ($unavailableHardwareV13 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract thirteen rejects explicitly unavailable hardware inventory.'

$unavailableWithModelV13 = (
    $unavailableHardwareV13 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$unavailableWithModelV13.host.hardware.processorModel = 'Invented Processor'
Add-Check (-not (
    ($unavailableWithModelV13 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Unavailable hardware inventory published a processor model.'

$oversizedHardwareV13 = (
    $fixedStateV13 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$oversizedHardwareV13.host.hardware.processorModel = 'x' * 257
Add-Check (-not (
    ($oversizedHardwareV13 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Hardware inventory accepted an oversized processor model.'

Add-Check (
    ($fixedStateV12 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract twelve stopped being accepted after hardware inventory was added.'

$fixedStateV14 = (
    $fixedStateV13 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$fixedStateV14.managerContractVersion = 14
foreach ($slot in $fixedStateV14.slots) {
    $slot | Add-Member `
        -NotePropertyName runnerNameHash `
        -NotePropertyValue $(if ($slot.processRunning) { 'a' * 64 } else { $null })
}
Add-Check (
    ($fixedStateV14 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract fourteen rejects fixed runner correlation hashes.'

$autoscaledStateV14 = (
    $autoscaledStateV13 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$autoscaledStateV14.managerContractVersion = 14
foreach ($slot in $autoscaledStateV14.slots) {
    $slot | Add-Member `
        -NotePropertyName runnerNameHash `
        -NotePropertyValue $(if ($slot.processRunning) { 'b' * 64 } else { $null })
}
Add-Check (
    ($autoscaledStateV14 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract fourteen rejects autoscaled runner correlation hashes.'

$missingRunnerHashV14 = (
    $fixedStateV14 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$missingRunnerHashV14.slots[0].PSObject.Properties.Remove('runnerNameHash')
Add-Check (-not (
    ($missingRunnerHashV14 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract fourteen accepts a slot without runner correlation.'

$liveWithoutRunnerHashV14 = (
    $fixedStateV14 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$liveWithoutRunnerHashV14.slots[0].runnerNameHash = $null
Add-Check (
    ($liveWithoutRunnerHashV14 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract fourteen rejects an explicitly unavailable runner correlation.'

$contractThirteenWithoutRunnerHash = (
    $fixedStateV13 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
foreach ($slot in $contractThirteenWithoutRunnerHash.slots) {
    $slot.PSObject.Properties.Remove('runnerNameHash')
}
Add-Check (
    ($contractThirteenWithoutRunnerHash | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract thirteen stopped accepting slots without runner correlation.'

$fixedStateV15 = (
    $fixedStateV14 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$fixedStateV15.managerContractVersion = 15
foreach ($slot in $fixedStateV15.slots) {
    $slot | Add-Member -NotePropertyName currentJob -NotePropertyValue $null
}
Add-Check (
    ($fixedStateV15 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract fifteen rejects explicitly unavailable fixed job context.'

$autoscaledStateV15 = (
    $autoscaledStateV14 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$autoscaledStateV15.managerContractVersion = 15
$autoscaledStateV15.desiredSlots = 1
$autoscaledStateV15.activeSlots = 1
$autoscaledStateV15.eligibleSlots = 1
$autoscaledStateV15.slots = @(
    $fixedStateV15.slots[0] |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$autoscaledStateV15.autoscaling = [PSCustomObject][ordered]@{
    mode = 'scale-set'
    status = 'running'
    minimumIdleSlots = 0
    maximumSlots = 1
    targetSlots = 1
    assignedJobs = 1
    runningJobs = 1
    availableJobs = 0
    idleRunners = 0
    busyRunners = 1
    scaleDownDelaySeconds = 120
    scaleDownAt = $null
    scaleSetCount = 1
    lastError = $null
    maximumActiveWorkers = 1
    targets = @(
        [PSCustomObject][ordered]@{
            key = 'repo-example'
            repository = 'https://github.com/example/project'
            maximumSlots = 1
            targetSlots = 1
            localActiveWorkers = 1
            localIdleWorkers = 0
            localBusyWorkers = 1
            localDrainingWorkers = 0
            statistics = [PSCustomObject][ordered]@{
                observedAt = '2026-08-06T03:42:03Z'
                availableJobs = 0
                acquiredJobs = 1
                assignedJobs = 1
                runningJobs = 1
                registeredRunners = 1
                busyRunners = 1
                idleRunners = 0
            }
        }
    )
}
$activeJobSlotV15 = $autoscaledStateV15.slots[0]
if ($activeJobSlotV15.PSObject.Properties['activity']) {
    $activeJobSlotV15.activity = 'busy'
} else {
    $activeJobSlotV15 | Add-Member -NotePropertyName activity -NotePropertyValue 'busy'
}
$activeJobSlotV15.currentJob = [PSCustomObject][ordered]@{
    repository = 'https://github.com/example/project'
    workflowRunId = 987654321
    jobId = '123456789'
    displayName = 'Large integration build'
    eventName = 'pull_request'
    queuedAt = '2026-08-06T03:40:00Z'
    scaleSetAssignedAt = '2026-08-06T03:41:00Z'
    runnerAssignedAt = '2026-08-06T03:41:30Z'
    startedAt = '2026-08-06T03:42:03Z'
    finishedAt = $null
    result = $null
}
Add-Check (
    ($autoscaledStateV15 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract fifteen rejects bounded autoscaled job context.'

$missingCurrentJobV15 = (
    $fixedStateV15 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$missingCurrentJobV15.slots[0].PSObject.Properties.Remove('currentJob')
Add-Check (-not (
    ($missingCurrentJobV15 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract fifteen accepts a slot without explicit job availability.'

$invalidCurrentJobV15 = (
    $autoscaledStateV15 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$invalidCurrentJobSlotV15 = @(
    $invalidCurrentJobV15.slots |
        Where-Object { $null -ne $_.currentJob }
)[0]
$invalidCurrentJobSlotV15.currentJob.jobId = 'not-a-job-id'
Add-Check (-not (
    ($invalidCurrentJobV15 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract fifteen accepts an invalid job identifier.'

$oversizedCurrentJobV15 = (
    $autoscaledStateV15 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$oversizedCurrentJobSlotV15 = @(
    $oversizedCurrentJobV15.slots |
        Where-Object { $null -ne $_.currentJob }
)[0]
$oversizedCurrentJobSlotV15.currentJob.displayName = 'x' * 257
Add-Check (-not (
    ($oversizedCurrentJobV15 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract fifteen accepts an oversized job display name.'

$rawCurrentJobPayloadV15 = (
    $autoscaledStateV15 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
$rawCurrentJobPayloadSlotV15 = @(
    $rawCurrentJobPayloadV15.slots |
        Where-Object { $null -ne $_.currentJob }
)[0]
$rawCurrentJobPayloadSlotV15.currentJob |
    Add-Member -NotePropertyName workflowRef -NotePropertyValue 'private-ref'
Add-Check (-not (
    ($rawCurrentJobPayloadV15 | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract fifteen accepts an unsupported workflow payload field.'

$contractFourteenWithoutCurrentJob = (
    $fixedStateV14 |
        ConvertTo-Json -Depth 16 |
        ConvertFrom-Json -Depth 16
)
foreach ($slot in $contractFourteenWithoutCurrentJob.slots) {
    $slot.PSObject.Properties.Remove('currentJob')
}
Add-Check (
    ($contractFourteenWithoutCurrentJob | ConvertTo-Json -Depth 16) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract fourteen stopped accepting slots without job context.'

$availableHostPressureV16 = [PSCustomObject][ordered]@{
    status = 'available'
    source = 'docker-host'
    cpuUtilizationPercent = 97.5
    load1 = 18.5
    load5 = 12.25
    load15 = 8.0
    memoryTotalBytes = 34359738368
    memoryAvailableBytes = 4294967296
    swapUsedBytes = 1073741824
    cpuPressureSomeAvg10 = 35.5
    cpuPressureFullAvg10 = 5.0
    memoryPressureSomeAvg10 = 12.5
    memoryPressureFullAvg10 = 3.0
    ioPressureSomeAvg10 = 42.0
    ioPressureFullAvg10 = 18.0
}
$fixedStateV16 = (
    $fixedStateV15 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$fixedStateV16.managerContractVersion = 16
$fixedStateV16.resourceTelemetry |
    Add-Member `
        -NotePropertyName hostPressure `
        -NotePropertyValue (
            $availableHostPressureV16 |
                ConvertTo-Json -Depth 20 |
                ConvertFrom-Json -Depth 20
        )
Add-Check (
    ($fixedStateV16 | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract sixteen rejects available Docker-host pressure.'

$autoscaledStateV16 = (
    $autoscaledStateV15 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$autoscaledStateV16.managerContractVersion = 16
$partialHostPressureV16 = (
    $availableHostPressureV16 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$partialHostPressureV16.status = 'partial'
$partialHostPressureV16.cpuUtilizationPercent = $null
$autoscaledStateV16.resourceTelemetry |
    Add-Member -NotePropertyName hostPressure -NotePropertyValue $partialHostPressureV16
Add-Check (
    ($autoscaledStateV16 | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract sixteen rejects a first-sample partial pressure projection.'

$missingHostPressureV16 = (
    $fixedStateV16 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$missingHostPressureV16.resourceTelemetry.PSObject.Properties.Remove('hostPressure')
Add-Check (-not (
    ($missingHostPressureV16 | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract sixteen accepts missing Docker-host pressure.'

$unavailableWithPressureV16 = (
    $fixedStateV16 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$unavailableWithPressureV16.resourceTelemetry.hostPressure.status = 'unavailable'
Add-Check (-not (
    ($unavailableWithPressureV16 | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Unavailable Docker-host pressure retained measured values.'

$invalidPressurePercentageV16 = (
    $fixedStateV16 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$invalidPressurePercentageV16.resourceTelemetry.hostPressure.ioPressureSomeAvg10 = 101
Add-Check (-not (
    ($invalidPressurePercentageV16 | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Docker-host pressure accepted an impossible percentage.'

$contractFifteenWithoutHostPressure = (
    $fixedStateV15 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$contractFifteenWithoutHostPressure.resourceTelemetry.PSObject.Properties.Remove(
    'hostPressure')
Add-Check (
    ($contractFifteenWithoutHostPressure | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract fifteen stopped accepting telemetry without host pressure.'

$disabledHostAdmissionV18 = [PSCustomObject][ordered]@{
    status = 'disabled'
    namespace = $null
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
$unavailableHostAdmissionV18 = [PSCustomObject][ordered]@{
    status = 'unavailable'
    namespace = 'primary'
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
$availableHostAdmissionAccountingV18 = [PSCustomObject][ordered]@{
    unitCost = 1
    reservedUnits = 2
    borrowable = $true
    profilePolicyFingerprint = 'def456abc789'
    activeUnits = 3
    provisionalUnits = 1
    heldUnits = 4
    borrowedUnits = 2
    pendingUnits = 5
    withheldUnits = 5
}
$availableHostAdmissionDecisionV18 = [PSCustomObject][ordered]@{
    sequence = 42
    command = 'acquire'
    granted = $true
    failureCategory = $null
    decidedAtUnixNano = 1700000000000000000
}
$availableHostAdmissionV18 = [PSCustomObject][ordered]@{
    status = 'available'
    namespace = 'primary'
    epoch = 3
    decisionSequence = 42
    capacityUnits = 12
    safetyMarginUnits = 2
    effectiveTotalUnits = 10
    availableUnits = 4
    hostPolicyFingerprint = 'abc123def456'
    accounting = $availableHostAdmissionAccountingV18
    lastDecision = $availableHostAdmissionDecisionV18
}

function New-RunnerHostAdmissionSchemaFixture {
    param(
        [Parameter(Mandatory)][int]$ManagerContractVersion,
        [object]$HostAdmission
    )

    $fixture = (
        $fixedStateV16 |
            ConvertTo-Json -Depth 20 |
            ConvertFrom-Json -Depth 20
    )
    $fixture.managerContractVersion = $ManagerContractVersion
    if ($PSBoundParameters.ContainsKey('HostAdmission')) {
        $fixture |
            Add-Member -NotePropertyName hostAdmission -NotePropertyValue (
                $HostAdmission |
                    ConvertTo-Json -Depth 20 |
                    ConvertFrom-Json -Depth 20
            )
    }
    return $fixture
}

Add-Check (
    (
        (New-RunnerHostAdmissionSchemaFixture -ManagerContractVersion 17) |
            ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract seventeen stopped accepting state without hostAdmission.'

Add-Check (-not (
    (
        (New-RunnerHostAdmissionSchemaFixture -ManagerContractVersion 18) |
            ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract eighteen accepted state without hostAdmission.'

Add-Check (-not (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $null
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Manager contract eighteen accepted a null hostAdmission.'

Add-Check (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $disabledHostAdmissionV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract eighteen rejected an explicit disabled hostAdmission.'

Add-Check (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $unavailableHostAdmissionV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract eighteen rejected an unavailable hostAdmission with a namespace.'

Add-Check (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $availableHostAdmissionV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract eighteen rejected a fully populated available hostAdmission.'

$degradedHostAdmissionV18 = (
    $availableHostAdmissionV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$degradedHostAdmissionV18.status = 'degraded'
Add-Check (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $degradedHostAdmissionV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract eighteen rejected a fully populated degraded hostAdmission.'

$degradedUnknownDemandV18 = (
    $availableHostAdmissionV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$degradedUnknownDemandV18.status = 'degraded'
$degradedUnknownDemandV18.accounting.pendingUnits = $null
$degradedUnknownDemandV18.accounting.withheldUnits = $null
Add-Check (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $degradedUnknownDemandV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath
) 'Manager contract eighteen rejected degraded host admission with unknown demand.'

$availableUnknownDemandV18 = (
    $degradedUnknownDemandV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$availableUnknownDemandV18.status = 'available'
Add-Check (-not (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $availableUnknownDemandV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Available host admission accepted unknown pending demand.'

$disabledWithNamespaceV18 = (
    $disabledHostAdmissionV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$disabledWithNamespaceV18.namespace = 'primary'
Add-Check (-not (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $disabledWithNamespaceV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A disabled hostAdmission accepted a leaked namespace.'

$unavailableWithoutNamespaceV18 = (
    $unavailableHostAdmissionV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$unavailableWithoutNamespaceV18.namespace = $null
Add-Check (-not (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $unavailableWithoutNamespaceV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'An unavailable hostAdmission accepted a missing namespace.'

$availableWithoutNamespaceV18 = (
    $availableHostAdmissionV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$availableWithoutNamespaceV18.namespace = $null
Add-Check (-not (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $availableWithoutNamespaceV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'An available hostAdmission accepted a missing namespace.'

$staleHostAdmissionAccountingV18 = (
    $availableHostAdmissionV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$staleHostAdmissionAccountingV18.accounting.PSObject.Properties.Remove('borrowable')
Add-Check (-not (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $staleHostAdmissionAccountingV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A hostAdmission accounting object accepted a missing borrowable field.'

$invalidDecisionCommandV18 = (
    $availableHostAdmissionV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$invalidDecisionCommandV18.lastDecision.command = 'delete'
Add-Check (-not (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $invalidDecisionCommandV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A hostAdmission lastDecision accepted an unsupported command.'

$adoptDecisionV18 = (
    $availableHostAdmissionV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$adoptDecisionV18.lastDecision.command = 'adopt'
Add-Check (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $adoptDecisionV18
        ) | ConvertTo-Json -Depth 20
    ) |
        Test-Json -SchemaFile $observedStateSchemaPath
) 'A hostAdmission lastDecision rejected the supported adopt command.'

$unsafeDecisionFailureV18 = (
    $availableHostAdmissionV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$unsafeDecisionFailureV18.lastDecision.failureCategory = '/var/lib/private'
Add-Check (-not (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $unsafeDecisionFailureV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A hostAdmission lastDecision accepted path-like failure evidence.'

$availableWithoutCapacityV18 = (
    $availableHostAdmissionV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$availableWithoutCapacityV18.capacityUnits = $null
Add-Check (-not (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $availableWithoutCapacityV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'Available host admission accepted missing host capacity.'

$fabricatedZeroCapacityV18 = (
    $disabledHostAdmissionV18 |
        ConvertTo-Json -Depth 20 |
        ConvertFrom-Json -Depth 20
)
$fabricatedZeroCapacityV18.capacityUnits = 0
Add-Check (-not (
    (
        (
            New-RunnerHostAdmissionSchemaFixture `
                -ManagerContractVersion 18 `
                -HostAdmission $fabricatedZeroCapacityV18
        ) | ConvertTo-Json -Depth 20
    ) | Test-Json -SchemaFile $observedStateSchemaPath -ErrorAction SilentlyContinue
)) 'A disabled hostAdmission accepted a fabricated zero capacityUnits instead of null.'

$defaultProfile = Resolve-RunnerProfile -RootPath $runnerRoot -Profile default -HostName 'test-host'
$copilotProfile = Resolve-RunnerProfile -RootPath $runnerRoot -Profile copilot-cli -HostName 'test-host'
$automationControlProfile = Resolve-RunnerProfile `
    -RootPath $runnerRoot `
    -Profile automation-control `
    -HostName 'test-host'
$imageBuilderProfile = Resolve-RunnerProfile -RootPath $runnerRoot -Profile image-builder -HostName 'test-host'
$androidProfile = Resolve-RunnerProfile -RootPath $runnerRoot -Profile android-emulator -HostName 'test-host'

Add-Check $defaultProfile.IsDefault 'The implicit default profile is not marked as default.'
Add-Check (
    $defaultProfile.Image -eq
        'myoung34/github-runner:2.336.0-ubuntu-noble@sha256:c803ddbc5b91961aabf3411c6336cb2c838cdaa2f917f76654c15a1948934817'
) 'The default profile runner image is not pinned by version and digest.'
Add-Check ($defaultProfile.Replicas -eq 1) 'The default profile changed its backward-compatible replica count.'
Add-Check ($defaultProfile.EnvironmentPath -eq (Join-Path $runnerRoot '.env')) 'The default profile no longer uses the backward-compatible .env path.'
Add-Check ($defaultProfile.ComposeProjectName -eq 'self-hosted-runner') 'The default profile no longer uses the backward-compatible Compose project.'
Add-Check ($defaultProfile.LabelsValue -eq 'general-purpose') 'The default profile must carry the general-purpose routing label.'
Add-Check (-not $defaultProfile.DisableDefaultLabels) 'The default profile must retain GitHub default labels for backward compatibility.'
Add-Check $defaultProfile.PullImage 'The default profile must retain pre-pull behavior for its remote base image.'
Add-Check ($null -eq $defaultProfile.HostAdmission) 'The default profile unexpectedly enabled host-local admission.'
Add-Check ($null -eq $defaultProfile.Runtime) 'The default profile unexpectedly enabled a specialized worker runtime.'

Add-Check ($automationControlProfile.LabelsValue -eq 'automation-control') 'The automation-control profile exposes labels beyond its exact profile identity.'
Add-Check $automationControlProfile.DisableDefaultLabels 'The automation-control profile permits broad default runner routing.'
Add-Check (-not $automationControlProfile.PullImage) 'The locally built automation-control profile attempts to pull a remote replacement.'
Add-Check ($automationControlProfile.Autoscaling.Mode -eq 'scale-set') 'The automation-control profile is not scale-set-only.'
Add-Check ($automationControlProfile.Autoscaling.MinimumIdle -eq 0) 'The automation-control profile does not scale to zero.'
Add-Check ($automationControlProfile.Autoscaling.MaximumActiveWorkers -eq 1) 'The automation-control profile does not use a conservative default maximum.'
Add-Check (
    $automationControlProfile.Build.Arguments.RUNTIME_IMAGE -match
        '@sha256:[0-9a-f]{64}$'
) 'The automation-control runtime base is not pinned by digest.'
foreach ($argument in @(
    'GIT_SHA256',
    'RUNNER_SHA256_X64',
    'RUNNER_SHA256_ARM64',
    'GH_SHA256_X64',
    'GH_SHA256_ARM64',
    'POWERSHELL_SHA256_X64',
    'POWERSHELL_SHA256_ARM64'
)) {
    Add-Check (
        $automationControlProfile.Build.Arguments[$argument] -match
            '^[0-9a-f]{64}$'
    ) "The automation-control build argument '$argument' is not checksum pinned."
}
Add-Check (
    $automationControlProfile.VerificationCommands -contains
        '/actions-runner/bin/Runner.Listener --version'
) 'The automation-control profile does not verify the JIT listener path.'
Add-Check (
    @(
        $automationControlProfile.VerificationCommands |
            Where-Object { $_ -match '^gh --version' }
    ).Count -eq 1
) 'The automation-control profile does not verify GitHub CLI.'
Add-Check (
    @(
        $automationControlProfile.VerificationCommands |
            Where-Object { $_ -match '^pwsh ' }
    ).Count -eq 1
) 'The automation-control profile does not verify PowerShell.'
Add-Check (
    @(
        $automationControlProfile.VerificationCommands |
            Where-Object {
                $_ -match '! command -v docker' -and
                $_ -match '! command -v sudo'
            }
    ).Count -eq 1
) 'The automation-control profile does not verify its omitted-tool boundary.'

Add-Check ($imageBuilderProfile.LabelsValue -eq 'image-builder,oci-builder') 'The image-builder profile does not expose exact isolated labels.'
Add-Check ($imageBuilderProfile.ServiceNetwork.Source -eq 'pitcrew-image-builder') 'The image-builder profile does not require its isolated service network.'
Add-Check ($imageBuilderProfile.Autoscaling.MaximumActiveWorkers -eq 1) 'The image-builder profile does not isolate profile-wide cleanup to one active worker.'
Add-Check ($imageBuilderProfile.Build.Arguments.BUILDKIT_VERSION -eq '0.32.2') 'The image-builder profile does not pin the BuildKit client.'

Add-Check ($androidProfile.LabelsValue -eq 'android,android-14,android-emulator') 'The Android profile does not expose exact isolated labels.'
Add-Check ($androidProfile.Autoscaling.MaximumActiveWorkers -eq 1) 'The Android profile does not bound aggregate emulator concurrency.'
Add-Check ($androidProfile.Runtime.DevicesValue -eq 'kvm') 'The Android profile does not request the typed KVM device.'
Add-Check ($androidProfile.Runtime.SharedMemoryBytes -eq 2147483648) 'The Android profile did not canonicalize shared memory.'
Add-Check ($androidProfile.Resources.MemoryBytes -eq 8589934592) 'The Android profile did not canonicalize its memory limit.'
Add-Check ($androidProfile.Build.Arguments.DOCKER_ANDROID_IMAGE -match '@sha256:[0-9a-f]{64}$') 'The Android profile does not pin Docker-Android by digest.'

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
$admissionProfile = Resolve-RunnerProfile `
    -RootPath $runnerRoot `
    -Profile default `
    -Autoscale $true `
    -MaximumActiveWorkers 4 `
    -HostName 'test-host'
Add-Check (
    $admissionProfile.Autoscaling.MaximumActiveWorkers -eq 4
) 'The profile-wide autoscaling admission ceiling was not resolved.'
$resourceProfile = Resolve-RunnerProfile `
    -RootPath $runnerRoot `
    -Profile default `
    -WorkerMemory '512MiB' `
    -WorkerMemorySwap '1g' `
    -WorkerCpus '02.500000000' `
    -WorkerPids 256 `
    -HostName 'test-host'
Add-Check ($resourceProfile.Resources.MemoryBytes -eq 536870912) 'Worker memory was not canonicalized to bytes.'
Add-Check ($resourceProfile.Resources.MemorySwapBytes -eq 1073741824) 'Worker memory-swap was not canonicalized to bytes.'
Add-Check ($resourceProfile.Resources.CpuCores -ceq '2.5') 'Worker CPU was not canonicalized without floating-point noise.'
Add-Check ($resourceProfile.Resources.Pids -eq 256) 'Worker PID policy was not canonicalized.'
$equivalentResourceProfile = Resolve-RunnerProfile `
    -RootPath $runnerRoot `
    -Profile default `
    -WorkerMemory '536870912' `
    -WorkerMemorySwap '1024m' `
    -WorkerCpus '2.5' `
    -WorkerPids 256 `
    -HostName 'test-host'
Add-Check (
    (Get-RunnerObjectFingerprint -Value $resourceProfile.Resources) -ceq
    (Get-RunnerObjectFingerprint -Value $equivalentResourceProfile.Resources)
) 'Equivalent resource-policy inputs do not produce one canonical representation.'
Assert-RunnerResilienceContractActivation -Profile $defaultProfile
Assert-RunnerResilienceContractActivation -Profile $resourceProfile
Assert-RunnerResilienceContractActivation -Profile $admissionProfile
$legacyResourceProfile = $resourceProfile.PSObject.Copy()
$legacyResourceProfile.ManagerContractVersion = $resourceProfile.DefinedManagerContractVersion - 1
Add-ThrowsCheck `
    -Action {
        Assert-RunnerResilienceContractActivation -Profile $legacyResourceProfile
    } `
    -ExpectedMessage 'require manager contract 11.*contract 10' `
    -Failure 'A contract-10 manager accepted a resource policy it cannot enforce.'
$legacyAdmissionProfile = $admissionProfile.PSObject.Copy()
$legacyAdmissionProfile.ManagerContractVersion = $admissionProfile.DefinedManagerContractVersion - 1
Add-ThrowsCheck `
    -Action {
        Assert-RunnerResilienceContractActivation -Profile $legacyAdmissionProfile
    } `
    -ExpectedMessage 'require manager contract 11.*contract 10' `
    -Failure 'A contract-10 manager accepted a profile admission ceiling it cannot enforce.'
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
Add-ThrowsCheck `
    -Action {
        Resolve-RunnerProfile `
            -RootPath $runnerRoot `
            -Profile default `
            -MaximumActiveWorkers 4
    } `
    -ExpectedMessage 'requires autoscaling' `
    -Failure 'A profile admission ceiling was accepted without autoscaling.'
Add-ThrowsCheck `
    -Action {
        Resolve-RunnerProfile `
            -RootPath $runnerRoot `
            -Profile default `
            -Autoscale $true `
            -MaximumActiveWorkers 0
    } `
    -ExpectedMessage 'must be a positive integer' `
    -Failure 'A zero profile admission ceiling was accepted.'
Add-ThrowsCheck `
    -Action {
        Resolve-RunnerProfile `
            -RootPath $runnerRoot `
            -Profile default `
            -WorkerMemory '5m'
    } `
    -ExpectedMessage 'at least 6291456 bytes' `
    -Failure 'Docker-incompatible memory below six MiB was accepted.'
Add-ThrowsCheck `
    -Action {
        Resolve-RunnerProfile `
            -RootPath $runnerRoot `
            -Profile default `
            -WorkerMemorySwap '1g'
    } `
    -ExpectedMessage 'requires a worker memory limit' `
    -Failure 'Memory-swap was accepted without memory.'
Add-ThrowsCheck `
    -Action {
        Resolve-RunnerProfile `
            -RootPath $runnerRoot `
            -Profile default `
            -WorkerMemory '1g' `
            -WorkerMemorySwap '512m'
    } `
    -ExpectedMessage 'greater than or equal' `
    -Failure 'Memory-swap below memory was accepted.'
Add-ThrowsCheck `
    -Action {
        Resolve-RunnerProfile `
            -RootPath $runnerRoot `
            -Profile default `
            -WorkerCpus '0'
    } `
    -ExpectedMessage 'must be positive' `
    -Failure 'A zero CPU limit was accepted.'
Add-ThrowsCheck `
    -Action {
        Resolve-RunnerProfile `
            -RootPath $runnerRoot `
            -Profile default `
            -WorkerCpus '0.1234567890'
    } `
    -ExpectedMessage 'at most nine fractional digits' `
    -Failure 'A CPU limit beyond canonical Docker precision was accepted.'
Add-ThrowsCheck `
    -Action {
        Resolve-RunnerProfile `
            -RootPath $runnerRoot `
            -Profile default `
            -WorkerPids 0
    } `
    -ExpectedMessage 'between 1 and 2147483647' `
    -Failure 'A zero PID limit was accepted.'

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
Add-Check (
    $copilotProfile.Build.Arguments['RUNNER_IMAGE'] -eq
        'myoung34/github-runner:2.336.0-ubuntu-noble@sha256:c803ddbc5b91961aabf3411c6336cb2c838cdaa2f917f76654c15a1948934817'
) 'The Copilot CLI runner base image is not pinned by version and digest.'
Add-Check ($copilotProfile.Build.Arguments['COPILOT_CLI_VERSION'] -eq '1.0.71') 'The Copilot CLI version is not pinned in the profile.'
Add-Check ($copilotProfile.Build.Arguments['COPILOT_CLI_SHA256_X64'] -match '^[0-9a-f]{64}$') 'The Copilot CLI x64 checksum is not pinned.'
Add-Check ($copilotProfile.Build.Arguments['COPILOT_CLI_SHA256_ARM64'] -match '^[0-9a-f]{64}$') 'The Copilot CLI arm64 checksum is not pinned.'
Add-Check ($defaultProfile.StateVolumePath -eq '.pitcrew-state/default') 'The default profile state mount is not stable.'
Add-Check ($copilotProfile.StateVolumePath -eq '.pitcrew-state/copilot-cli') 'Named mutable state is not profile-scoped.'
Add-Check ($defaultProfile.ManagerContractVersion -eq 18) 'The setup contract does not activate the host-admission manager contract.'
Add-Check ($defaultProfile.DefinedManagerContractVersion -eq 11) 'The setup contract does not expose the defined resilience contract.'
Add-Check (
    $defaultProfile.DefinedHostAdmissionContractVersion -eq 18
) 'The setup contract does not expose the defined host-admission contract.'
Add-Check (
    $defaultProfile.DefinedDiagnosticsContractVersion -eq 18
) 'The setup contract does not expose the defined zero-capacity manager contract.'
$implementedContract = Get-RunnerImplementedManagerContract -RootPath $runnerRoot
Add-Check (
    $implementedContract.Fixed -eq $defaultProfile.ManagerContractVersion -and
    $implementedContract.Autoscaling -eq $defaultProfile.ManagerContractVersion
) 'The activated manager contract does not match both manager implementations.'
Add-Check (
    $implementedContract.Implemented -eq $defaultProfile.DefinedDiagnosticsContractVersion
) 'The active manager contract does not include the defined diagnostics contract.'
Assert-RunnerManagerContractActivation -Profile $defaultProfile
$futureProfile = $defaultProfile.PSObject.Copy()
$futureProfile.ManagerContractVersion = $defaultProfile.ManagerContractVersion + 1
Add-ThrowsCheck `
    -Action {
        Assert-RunnerManagerContractActivation -Profile $futureProfile
    } `
    -ExpectedMessage "Manager contract $($futureProfile.ManagerContractVersion) cannot activate" `
    -Failure 'A future manager contract activated before both manager modes implement it.'
$missingManagerRoot = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $missingManagerRoot | Out-Null
try {
    $missingManagerContract = Get-RunnerImplementedManagerContract -RootPath $missingManagerRoot
    Add-Check (
        $missingManagerContract.Implemented -eq 0
    ) 'An unreadable manager declaration did not fail closed.'
} finally {
    Remove-Item -LiteralPath $missingManagerRoot -Recurse -Force
}
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
$pausedRepository = New-RunnerDesiredCapacityState `
    -Generation 100 `
    -Scope repo `
    -Repositories @(
        [PSCustomObject]@{
            Url = 'https://github.com/example/project'
            Workers = 0
        }
    ) `
    -Replicas $null
$pausedOrganization = New-RunnerDesiredCapacityState `
    -Generation 101 `
    -Scope org `
    -Repositories @() `
    -Replicas 0
Add-Check ($pausedRepository.repositories[0].workers -eq 0) 'Repository desired capacity rejected an explicit pause.'
Add-Check ($pausedOrganization.replicas -eq 0) 'Organization desired capacity rejected an explicit pause.'
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
    -EnterpriseName '' `
    -ResolvedImageId $testWorkerImageId
$copilotStaticProfile = New-RunnerStaticProfileState `
    -Profile $copilotProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName '' `
    -ResolvedImageId $testWorkerImageId
$androidStaticProfile = New-RunnerStaticProfileState `
    -Profile $androidProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName '' `
    -ResolvedImageId $testWorkerImageId
$replicaOverrideProfile = Resolve-RunnerProfile `
    -RootPath $runnerRoot `
    -Profile default `
    -Replicas 9 `
    -HostName 'test-host'
$replicaOverrideStaticProfile = New-RunnerStaticProfileState `
    -Profile $replicaOverrideProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName '' `
    -ResolvedImageId $testWorkerImageId
$imageOverrideProfile = Resolve-RunnerProfile `
    -RootPath $runnerRoot `
    -Profile default `
    -Image 'example/runner:changed' `
    -HostName 'test-host'
$imageOverrideStaticProfile = New-RunnerStaticProfileState `
    -Profile $imageOverrideProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName '' `
    -ResolvedImageId $testWorkerImageId
$autoscaledStaticProfile = New-RunnerStaticProfileState `
    -Profile $autoscaledProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName '' `
    -ResolvedImageId $testWorkerImageId
$admissionStaticProfile = New-RunnerStaticProfileState `
    -Profile $admissionProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName '' `
    -ResolvedImageId $testWorkerImageId
$resourceStaticProfile = New-RunnerStaticProfileState `
    -Profile $resourceProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName '' `
    -ResolvedImageId $testWorkerImageId
$equivalentResourceStaticProfile = New-RunnerStaticProfileState `
    -Profile $equivalentResourceProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName '' `
    -ResolvedImageId $testWorkerImageId
$changedImageIdentityStaticProfile = New-RunnerStaticProfileState `
    -Profile $defaultProfile `
    -Scope repo `
    -OrgName '' `
    -EnterpriseName '' `
    -ResolvedImageId $changedWorkerImageId
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
    $autoscaledStaticProfile.fingerprint -ne $admissionStaticProfile.fingerprint
) 'The profile admission ceiling is missing from the static fingerprint.'
Add-Check (
    $autoscaledStaticProfile.workerRevision -eq $admissionStaticProfile.workerRevision
) 'A manager-only admission ceiling unnecessarily changes the worker revision.'
Add-Check (
    $defaultStaticProfile.workerRevision -ne $resourceStaticProfile.workerRevision
) 'Worker resource policy changes do not advance the worker revision.'
Add-Check (
    $resourceStaticProfile.workerRevision -eq $equivalentResourceStaticProfile.workerRevision
) 'Equivalent resource policy input changes the worker revision.'
Add-Check (
    $defaultStaticProfile.workerRevision -ne $changedImageIdentityStaticProfile.workerRevision
) 'Changed local image content does not advance the worker revision.'
Add-Check (
    (
        Get-RunnerObjectFingerprint -Value (
            Get-RunnerRefreshCompatibilityConfiguration `
                -Configuration $defaultStaticProfile.configuration)
    ) -cne (
        Get-RunnerObjectFingerprint -Value (
            Get-RunnerRefreshCompatibilityConfiguration `
                -Configuration $changedImageIdentityStaticProfile.configuration)
    )
) 'Refresh compatibility ignores changed immutable image content.'
Add-Check (
    (
        Get-RunnerObjectFingerprint -Value (
            Get-RunnerRollingCompatibilityConfiguration `
                -Configuration $defaultStaticProfile.configuration)
    ) -ceq (
        Get-RunnerObjectFingerprint -Value (
            Get-RunnerRollingCompatibilityConfiguration `
                -Configuration $resourceStaticProfile.configuration)
    )
) 'A resource-policy change is incorrectly treated as a routing-topology change.'
Add-Check (
    $defaultStaticProfile.configuration.workerRuntimeContractVersion -eq 3
) 'Static profile state does not expose the current worker runtime contract.'
Add-Check (
    $androidStaticProfile.configuration.runtime.devices[0] -ceq 'kvm' -and
    $androidStaticProfile.configuration.runtime.sharedMemoryBytes -eq 2147483648
) 'Static profile state does not retain the bounded worker runtime.'
Add-Check (
    $defaultStaticProfile.configuration.resolvedImageId -ceq $testWorkerImageId
) 'Static profile state does not retain immutable local image identity.'
$legacyRuntimeConfiguration = $defaultStaticProfile.configuration |
    ConvertTo-Json -Depth 20 |
    ConvertFrom-Json -Depth 20
$legacyRuntimeConfiguration.PSObject.Properties.Remove(
    'workerRuntimeContractVersion')
$legacyWorkerRevision = Get-RunnerObjectFingerprint -Value (
    Get-RunnerWorkerConfiguration -Configuration $legacyRuntimeConfiguration)
Add-Check (
    $legacyWorkerRevision -cne [string]$defaultStaticProfile.workerRevision
) 'Worker runtime contract changes do not advance the worker revision.'
Add-Check (
    (
        Get-RunnerObjectFingerprint -Value (
            Get-RunnerRefreshCompatibilityConfiguration `
                -Configuration $legacyRuntimeConfiguration)
    ) -ceq (
        Get-RunnerObjectFingerprint -Value (
            Get-RunnerRefreshCompatibilityConfiguration `
                -Configuration $defaultStaticProfile.configuration)
    )
) 'Internal worker runtime changes are not refresh-compatible.'
Add-Check (
    $copilotStaticProfile.configuration.build.contextSha256 -match '^[0-9a-f]{64}$'
) 'Locally built profiles do not fingerprint their complete build context.'

$copilotDockerfile = Get-Content -LiteralPath $copilotDockerfilePath -Raw -Encoding UTF8
Add-Check (
    $copilotDockerfile -match
        [regex]::Escape('FROM ${RUNNER_IMAGE}')
) 'The Copilot CLI Dockerfile does not consume its pinned runner base.'
Add-Check (
    $copilotDockerfile -notmatch
        '(?m)^FROM\s+myoung34/github-runner:[^@\r\n]+$'
) 'The Copilot CLI Dockerfile still permits a mutable runner base.'
Add-Check ($copilotDockerfile -match [regex]::Escape('sha256sum -c -')) 'The Copilot CLI image does not verify the downloaded checksum.'
Add-Check ($copilotDockerfile -match [regex]::Escape('/usr/local/bin/copilot')) 'The Copilot CLI image does not expose the documented stable executable path.'
Add-Check ($copilotDockerfile -notmatch '(?i)(COPILOT_GITHUB_TOKEN|GH_TOKEN|GITHUB_TOKEN=)') 'The Copilot CLI image contains authentication material.'
Add-Check ($profileJson -notmatch '(?i)(COPILOT_GITHUB_TOKEN|GH_TOKEN|GITHUB_TOKEN)') 'The Copilot CLI profile contains authentication material.'
$automationControlDockerfile = Get-Content `
    -LiteralPath $automationControlDockerfilePath `
    -Raw `
    -Encoding UTF8
Add-Check (
    $automationControlDockerfile -match
        'mcr\.microsoft\.com/dotnet/runtime-deps:8\.0-noble@sha256:[0-9a-f]{64}'
) 'The automation-control image does not use its pinned minimal runtime base.'
Add-Check (
    $automationControlDockerfile -notmatch
        '(?m)^FROM\s+(?:myoung34|ghcr\.io/actions/actions-runner)'
) 'The automation-control image inherits a full runner image.'
Add-Check (
    $automationControlDockerfile -match
        [regex]::Escape('/actions-runner/externals/node20_alpine') -and
    $automationControlDockerfile -match
        [regex]::Escape('/actions-runner/externals/node24_alpine') -and
    $automationControlDockerfile -match
        [regex]::Escape('/actions-runner/externals/node20/lib/node_modules') -and
    $automationControlDockerfile -match
        [regex]::Escape('/actions-runner/externals/node24/lib/node_modules')
) 'The automation-control image does not prune non-runtime Node payloads.'
Add-Check (
    $automationControlDockerfile -match 'NO_PERL=YesPlease' -and
    $automationControlDockerfile -match 'NO_PYTHON=YesPlease' -and
    $automationControlDockerfile -match 'NO_RUST=YesPlease'
) 'The automation-control Git build retains unneeded scripting runtimes.'
Add-Check (
    $automationControlDockerfile -match '(?m)^USER runner$'
) 'The automation-control image does not declare its non-root runtime identity.'
Add-Check (
    $automationControlDockerfile -notmatch
        '(?i)(GH_TOKEN|GITHUB_TOKEN|password|credential|private[_-]?key)'
) 'The automation-control image contains secret-shaped material.'
$imageBuilderDockerfile = Get-Content -LiteralPath $imageBuilderDockerfilePath -Raw -Encoding UTF8
$androidDockerfile = Get-Content -LiteralPath $androidDockerfilePath -Raw -Encoding UTF8
$androidStart = Get-Content -LiteralPath $androidStartPath -Raw -Encoding UTF8
Add-Check ($imageBuilderDockerfile -match [regex]::Escape('sha256sum -c -')) 'The image-builder profile does not checksum the BuildKit client.'
Add-Check ($imageBuilderDockerfile -match [regex]::Escape('/usr/local/bin/buildctl')) 'The image-builder profile does not expose buildctl at a stable path.'
Add-Check ($imageBuilderDockerfile -notmatch '/var/run/docker\.sock|--privileged') 'The image-builder worker image requests host Docker access.'
Add-Check ($androidDockerfile -match 'USER_BEHAVIOR_ANALYTICS=false') 'The Android profile does not disable upstream analytics by default.'
Add-Check ($androidDockerfile -notmatch '/var/run/docker\.sock|--privileged') 'The Android worker image requests broad host access.'
Add-Check ($androidStart -match 'USER_BEHAVIOR_ANALYTICS=false') 'The Android startup helper does not force analytics off.'
Add-Check ($androidStart -match 'device_status') 'The Android startup helper does not use upstream readiness state.'

$defaultEnvironment = New-RunnerEnvironmentContent `
    -Profile $defaultProfile `
    -AccessToken 'test-registration-token' `
    -WorkerRevision $defaultStaticProfile.workerRevision `
    -SessionOwner 'pitcrew-default' `
    -AssumeUnversionedCurrent $false `
    -ResolvedImageId $testWorkerImageId
$copilotEnvironment = New-RunnerEnvironmentContent `
    -Profile $copilotProfile `
    -AccessToken 'test-registration-token' `
    -WorkerRevision $copilotStaticProfile.workerRevision `
    -SessionOwner 'pitcrew-copilot-cli' `
    -AssumeUnversionedCurrent $false `
    -ResolvedImageId $testWorkerImageId
$autoscaledEnvironment = New-RunnerEnvironmentContent `
    -Profile $autoscaledProfile `
    -AccessToken 'test-registration-token' `
    -WorkerRevision $autoscaledStaticProfile.workerRevision `
    -SessionOwner 'pitcrew-autoscaled' `
    -AssumeUnversionedCurrent $false `
    -ResolvedImageId $testWorkerImageId
$resourceEnvironment = New-RunnerEnvironmentContent `
    -Profile $resourceProfile `
    -AccessToken 'test-registration-token' `
    -WorkerRevision $resourceStaticProfile.workerRevision `
    -SessionOwner 'pitcrew-resource' `
    -AssumeUnversionedCurrent $false `
    -ResolvedImageId $testWorkerImageId
$androidEnvironment = New-RunnerEnvironmentContent `
    -Profile $androidProfile `
    -AccessToken 'test-registration-token' `
    -WorkerRevision $androidStaticProfile.workerRevision `
    -SessionOwner 'pitcrew-android-emulator' `
    -AssumeUnversionedCurrent $false `
    -ResolvedImageId $testWorkerImageId
$admissionEnvironment = New-RunnerEnvironmentContent `
    -Profile $admissionProfile `
    -AccessToken 'test-registration-token' `
    -WorkerRevision $admissionStaticProfile.workerRevision `
    -SessionOwner 'pitcrew-admission' `
    -AssumeUnversionedCurrent $false `
    -ResolvedImageId $testWorkerImageId
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_PROFILE_ID=default$') 'The default environment does not identify its profile.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_LABELS=general-purpose$') 'The default environment does not emit the general-purpose label.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_NO_DEFAULT_LABELS=$') 'The default environment unexpectedly disables GitHub default labels.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_PULL_IMAGE=0$') 'Generated default state permits a second image pull after preparation.'
Add-Check ($defaultEnvironment -notmatch '(?m)^(REPO_URLS|RUNNER_REPLICAS)=') 'Mutable capacity remains embedded in the static environment.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_STATE_DIR=\.pitcrew-state/default$') 'The default environment does not mount its mutable state directory.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_MANAGER_CONTRACT_VERSION=18$') 'The environment does not pin the manager reconciliation contract.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_WORKER_REVISION=[0-9a-f]{64}$') 'The environment does not pin the worker revision.'
Add-Check ($defaultEnvironment -match "(?m)^PITCREW_WORKER_IMAGE_ID=$([regex]::Escape($testWorkerImageId))$") 'The environment does not pin immutable local image identity.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_WORKER_MEMORY_BYTES=$') 'The default memory policy is not represented as an empty manager-only value.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_WORKER_MEMORY_SWAP_BYTES=$') 'The default memory-swap policy is not represented as an empty manager-only value.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_WORKER_CPU_CORES=$') 'The default CPU policy is not represented as an empty manager-only value.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_WORKER_PIDS_LIMIT=$') 'The default PID policy is not represented as an empty manager-only value.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_WORKER_RUNTIME_DEVICES=$') 'The default environment unexpectedly configures a worker device.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_WORKER_SHM_SIZE_BYTES=$') 'The default environment unexpectedly configures shared memory.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_READ_ONLY_VOLUMES=$') 'The default environment unexpectedly configures external data volumes.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_SERVICE_NETWORK=$') 'The default environment unexpectedly configures an external service network.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS=$') 'The default admission ceiling is not represented as an empty manager-only value.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_SESSION_OWNER=pitcrew-default$') 'The environment does not pin the stable session owner.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_AUTOSCALING_MODE=$') 'Fixed profiles unexpectedly enable autoscaling.'
Add-Check ($autoscaledEnvironment -match '(?m)^PITCREW_AUTOSCALING_MODE=scale-set$') 'Autoscaling mode is missing from the manager environment.'
Add-Check ($autoscaledEnvironment -match '(?m)^PITCREW_AUTOSCALING_MIN_IDLE=1$') 'Autoscaling minimum idle is missing from the manager environment.'
Add-Check ($autoscaledEnvironment -match '(?m)^PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS=180$') 'Autoscaling scale-down delay is missing from the manager environment.'
Add-Check ($resourceEnvironment -match '(?m)^PITCREW_WORKER_MEMORY_BYTES=536870912$') 'The canonical memory policy is missing from the manager environment.'
Add-Check ($resourceEnvironment -match '(?m)^PITCREW_WORKER_MEMORY_SWAP_BYTES=1073741824$') 'The canonical memory-swap policy is missing from the manager environment.'
Add-Check ($resourceEnvironment -match '(?m)^PITCREW_WORKER_CPU_CORES=2\.5$') 'The canonical CPU policy is missing from the manager environment.'
Add-Check ($resourceEnvironment -match '(?m)^PITCREW_WORKER_PIDS_LIMIT=256$') 'The canonical PID policy is missing from the manager environment.'
Add-Check ($androidEnvironment -match '(?m)^PITCREW_WORKER_RUNTIME_DEVICES=kvm$') 'The typed KVM device is missing from the manager environment.'
Add-Check ($androidEnvironment -match '(?m)^PITCREW_WORKER_SHM_SIZE_BYTES=2147483648$') 'Canonical shared memory is missing from the manager environment.'
Add-Check ($admissionEnvironment -match '(?m)^PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS=4$') 'The profile admission ceiling is missing from the manager environment.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_PROFILE_ID=copilot-cli$') 'The specialized environment does not identify its profile.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_NO_DEFAULT_LABELS=1$') 'The specialized environment does not disable GitHub default labels.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_PULL_IMAGE=0$') 'The specialized environment does not protect its locally built image.'

$enterpriseEnvironment = New-RunnerEnvironmentContent `
    -Profile $copilotProfile `
    -AccessToken 'test-registration-token' `
    -WorkerRevision $copilotStaticProfile.workerRevision `
    -SessionOwner 'pitcrew-copilot-cli' `
    -AssumeUnversionedCurrent $false `
    -ResolvedImageId $testWorkerImageId `
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
        readOnlyVolumes = @(
            @{
                name = 'reference-data'
                source = 'pitcrew-reference-data-v1'
            }
        )
        serviceNetwork = @{
            source = 'pitcrew-browser-services-v1'
        }
        verificationCommands = @('browser --version')
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $externalManifestPath -Encoding UTF8

    $digestManifestPath = Join-Path $externalDirectory 'digest-default-profile.json'
    @{
        schemaVersion = 1
        name = 'default'
        description = 'Digest-qualified image rollback contract test.'
        image = $digestWorkerImage
        labels = @('general-purpose')
        replicas = 1
        pullImage = $true
        disableDefaultLabels = $false
        verificationCommands = @('verify-digest-image')
    } |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $digestManifestPath -Encoding UTF8

    $externalProfile = Resolve-RunnerProfile `
        -RootPath $runnerRoot `
        -ProfilePath $externalManifestPath `
        -HostName 'test-host'
    Add-Check ($externalProfile.Name -eq 'browser-testing') 'An external profile did not resolve its manifest name.'
    Add-Check ($externalProfile.Build.Context -eq $externalDirectory) 'External build context is not relative to the profile manifest.'
    Add-Check ($externalProfile.Replicas -eq 2) 'External profile replica defaults were not applied.'
    Add-Check ($externalProfile.ReadOnlyVolumes.Count -eq 1) 'External profile read-only volumes were not resolved.'
    Add-Check (
        $externalProfile.ReadOnlyVolumes[0].Target -eq '/mnt/pitcrew-data/reference-data'
    ) 'External profile read-only volume target was not derived safely.'
    Add-Check (
        $externalProfile.ReadOnlyVolumesValue -eq 'reference-data=pitcrew-reference-data-v1'
    ) 'External profile read-only volumes were not serialized canonically.'
    Add-Check (
        $externalProfile.ServiceNetwork.Source -eq 'pitcrew-browser-services-v1'
    ) 'External profile service network was not resolved.'
    Add-Check (
        $externalProfile.ServiceNetworkValue -eq 'pitcrew-browser-services-v1'
    ) 'External profile service network was not serialized canonically.'

    $admissionManifestPath = Join-Path $externalDirectory 'admission-profile.json'
    $admissionManifest = Get-Content `
        -LiteralPath $externalManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $admissionManifest |
        Add-Member -NotePropertyName hostAdmission -NotePropertyValue ([PSCustomObject]@{
            namespace = 'primary'
            capacityUnits = 12
            safetyMarginUnits = 2
            workerCostUnits = 2
            reservationUnits = 4
            borrowable = $false
        })
    $admissionManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $admissionManifestPath -Encoding UTF8
    $admissionProfile = Resolve-RunnerProfile `
        -RootPath $runnerRoot `
        -ProfilePath $admissionManifestPath `
        -HostName 'test-host'
    Assert-RunnerResilienceContractActivation -Profile $admissionProfile
    Add-Check $true 'Host-local admission did not activate now that both manager modes implement contract 18.'
    $legacyHostAdmissionProfile = $admissionProfile.PSObject.Copy()
    $legacyHostAdmissionProfile.ManagerContractVersion =
        $admissionProfile.DefinedHostAdmissionContractVersion - 1
    Add-ThrowsCheck `
        -Action {
            Assert-RunnerResilienceContractActivation -Profile $legacyHostAdmissionProfile
        } `
        -ExpectedMessage 'Host-local admission requires manager contract 18.*activates contract 17' `
        -Failure 'Host-local admission activated before both manager modes implement its contract.'
    Add-Check (
        $admissionProfile.HostAdmission.Namespace -ceq 'primary' -and
        $admissionProfile.HostAdmission.CapacityUnits -eq 12 -and
        $admissionProfile.HostAdmission.SafetyMarginUnits -eq 2 -and
        $admissionProfile.HostAdmission.EffectiveBudgetUnits -eq 10 -and
        $admissionProfile.HostAdmission.WorkerCostUnits -eq 2 -and
        $admissionProfile.HostAdmission.ReservationUnits -eq 4 -and
        -not $admissionProfile.HostAdmission.Borrowable
    ) 'External profile host-admission policy was not canonicalized.'
    Add-Check (
        $admissionProfile.HostAdmission.HostPolicyFingerprint -match '^[0-9a-f]{64}$' -and
        $admissionProfile.HostAdmission.ProfilePolicyFingerprint -match '^[0-9a-f]{64}$'
    ) 'External profile host-admission policy was not fingerprinted.'
    Add-Check (
        $admissionProfile.HostAdmissionDirectory -eq (
            Join-Path $runnerRoot '.pitcrew-state' 'host-admission' 'primary'
        ) -and
        $admissionProfile.HostAdmissionDesiredPolicyPath -eq (
            Join-Path $runnerRoot '.pitcrew-state' 'host-admission' 'primary' 'desired-policy.json'
        ) -and
        $admissionProfile.HostAdmissionAcknowledgementPath -eq (
            Join-Path $runnerRoot '.pitcrew-state' 'host-admission' 'primary' 'acknowledged-policy.json'
        ) -and
        $admissionProfile.HostAdmissionVolumeName -ceq 'pitcrew-host-admission-primary' -and
        $admissionProfile.HostAdmissionComposeProjectName -ceq 'pitcrew-host-admission-primary' -and
        $admissionProfile.HostAdmissionProtocolVersion -eq 2 -and
        $admissionProfile.HostAdmissionSocketPath -ceq
            '/var/lib/pitcrew-admission/coordinator.sock'
    ) 'External profile did not derive stable host-admission state and runtime identities.'

    $hostAdmissionPolicy = Update-RunnerHostAdmissionDesiredPolicy `
        -CurrentPolicy $null `
        -Profile $admissionProfile `
        -Generation 1
    Add-Check (
        $hostAdmissionPolicy.schemaVersion -eq 1 -and
        $hostAdmissionPolicy.generation -eq 1 -and
        $hostAdmissionPolicy.namespace -ceq 'primary' -and
        $hostAdmissionPolicy.capacityUnits -eq 12 -and
        $hostAdmissionPolicy.safetyMarginUnits -eq 2 -and
        $hostAdmissionPolicy.effectiveBudgetUnits -eq 10 -and
        $hostAdmissionPolicy.profiles.Count -eq 1 -and
        $hostAdmissionPolicy.profiles[0].profile -ceq 'browser-testing'
    ) 'Selected profile did not create a canonical desired host-admission policy.'
    $sameHostAdmissionPolicy = New-RunnerHostAdmissionDesiredPolicy `
        -Generation 99 `
        -Namespace primary `
        -CapacityUnits 12 `
        -SafetyMarginUnits 2 `
        -ProfilePolicies @(
            [PSCustomObject]@{
                Profile = 'browser-testing'
                WorkerCostUnits = 2
                ReservationUnits = 4
                Borrowable = $false
            }
        )
    Add-Check (
        (Get-RunnerHostAdmissionPolicySignature -Policy $hostAdmissionPolicy) -ceq
        (Get-RunnerHostAdmissionPolicySignature -Policy $sameHostAdmissionPolicy)
    ) 'Host-admission policy equality incorrectly depends on generation.'
    $serviceAdmissionPolicy = ConvertTo-RunnerHostAdmissionServicePolicy `
        -Policy $hostAdmissionPolicy
    Add-Check (
        $serviceAdmissionPolicy.generation -eq 1 -and
        $serviceAdmissionPolicy.totalUnits -eq 10 -and
        $serviceAdmissionPolicy.namespace -ceq 'primary' -and
        $serviceAdmissionPolicy.capacityUnits -eq 12 -and
        $serviceAdmissionPolicy.safetyMarginUnits -eq 2 -and
        $serviceAdmissionPolicy.hostPolicyFingerprint -match '^[0-9a-f]{64}$' -and
        $serviceAdmissionPolicy.profiles.Count -eq 1 -and
        $serviceAdmissionPolicy.profiles[0].profileId -ceq 'browser-testing' -and
        $serviceAdmissionPolicy.profiles[0].unitCost -eq 2 -and
        $serviceAdmissionPolicy.profiles[0].reservedUnits -eq 4 -and
        -not $serviceAdmissionPolicy.profiles[0].borrowable -and
        $serviceAdmissionPolicy.profiles[0].profilePolicyFingerprint -match '^[0-9a-f]{64}$'
    ) 'Desired host policy did not project into the coordinator wire contract.'
    $roundTrippedServicePolicy = (
        $serviceAdmissionPolicy |
            ConvertTo-Json -Depth 10 |
            ConvertFrom-Json -Depth 10
    )
    $roundTrippedServicePolicy |
        Add-Member -NotePropertyName ignoredFutureField -NotePropertyValue 'ignored'
    Add-Check (
        (
            Get-RunnerHostAdmissionServicePolicySignature `
                -Policy $serviceAdmissionPolicy
        ) -ceq (
            Get-RunnerHostAdmissionServicePolicySignature `
                -Policy $roundTrippedServicePolicy
        )
    ) 'Coordinator service-policy identity depends on JSON property order or additive fields.'

    $batchAdmissionProfile = [PSCustomObject]@{
        Name = 'batch'
        HostAdmission = ConvertTo-RunnerHostAdmissionPolicy `
            -Policy ([PSCustomObject]@{
                namespace = 'primary'
                capacityUnits = 12
                safetyMarginUnits = 2
                workerCostUnits = 3
                reservationUnits = 3
                borrowable = $true
            }) `
            -ProfileName batch
    }
    $twoProfileAdmissionPolicy = Update-RunnerHostAdmissionDesiredPolicy `
        -CurrentPolicy $hostAdmissionPolicy `
        -Profile $batchAdmissionProfile `
        -Generation 2
    Add-Check (
        ($twoProfileAdmissionPolicy.profiles.profile -join ',') -ceq
            'batch,browser-testing'
    ) 'Host-admission policy update did not preserve and sort unrelated profiles.'

    $conflictingAdmissionProfile = [PSCustomObject]@{
        Name = 'conflicting'
        HostAdmission = ConvertTo-RunnerHostAdmissionPolicy `
            -Policy ([PSCustomObject]@{
                namespace = 'primary'
                capacityUnits = 14
                safetyMarginUnits = 2
                workerCostUnits = 2
                reservationUnits = 2
                borrowable = $true
            }) `
            -ProfileName conflicting
    }
    Add-ThrowsCheck `
        -Action {
            Update-RunnerHostAdmissionDesiredPolicy `
                -CurrentPolicy $twoProfileAdmissionPolicy `
                -Profile $conflictingAdmissionProfile `
                -Generation 3
        } `
        -ExpectedMessage 'conflicts with other participating profiles' `
        -Failure 'One profile changed host-wide admission policy while other profiles remained enrolled.'

    $disabledExternalProfile = [PSCustomObject]@{
        Name = 'browser-testing'
        HostAdmission = $null
    }
    $oneProfileAdmissionPolicy = Update-RunnerHostAdmissionDesiredPolicy `
        -CurrentPolicy $twoProfileAdmissionPolicy `
        -Profile $disabledExternalProfile `
        -Generation 3
    Add-Check (
        $oneProfileAdmissionPolicy.profiles.Count -eq 1 -and
        $oneProfileAdmissionPolicy.profiles[0].profile -ceq 'batch'
    ) 'Disabling one profile removed or changed an unrelated admission policy.'
    $disabledBatchProfile = [PSCustomObject]@{
        Name = 'batch'
        HostAdmission = $null
    }
    $emptyAdmissionPolicy = Update-RunnerHostAdmissionDesiredPolicy `
        -CurrentPolicy $oneProfileAdmissionPolicy `
        -Profile $disabledBatchProfile `
        -Generation 4
    Add-Check (
        $emptyAdmissionPolicy.profiles.Count -eq 0 -and
        $emptyAdmissionPolicy.namespace -ceq 'primary'
    ) 'Removing the final profile did not preserve a drainable empty host policy.'
    Add-Check ($externalProfile.ManifestKind -eq 'external') 'An external profile did not retain its manifest source kind.'
    Add-Check (
        $externalProfile.ManifestSha256 -match '^[0-9a-f]{64}$'
    ) 'An external profile did not retain its manifest content hash.'
    $externalStaticProfile = New-RunnerStaticProfileState `
        -Profile $externalProfile `
        -Scope repo `
        -OrgName '' `
        -EnterpriseName '' `
        -ResolvedImageId $testWorkerImageId
    Add-Check (
        $externalStaticProfile.manifest.sourcePath -ceq $externalManifestPath
    ) 'Static profile state did not retain the external manifest source path.'
    Add-Check (
        $externalStaticProfile.manifest.sha256 -ceq $externalProfile.ManifestSha256
    ) 'Static profile state did not retain the external manifest content hash.'
    Add-Check (
        $externalStaticProfile.manifest.document.name -eq 'browser-testing'
    ) 'Static profile state did not retain the non-secret manifest document.'
    Add-Check (
        $externalStaticProfile.configuration.readOnlyVolumes[0].source -eq
            'pitcrew-reference-data-v1'
    ) 'Static profile state did not retain the read-only volume source.'
    Add-Check (
        $externalStaticProfile.configuration.serviceNetwork.source -eq
            'pitcrew-browser-services-v1'
    ) 'Static profile state did not retain the external service network.'
    $externalEnvironment = New-RunnerEnvironmentContent `
        -Profile $externalProfile `
        -AccessToken 'test-registration-token' `
        -WorkerRevision $externalStaticProfile.workerRevision `
        -SessionOwner 'pitcrew-browser-testing' `
        -AssumeUnversionedCurrent $false `
        -ResolvedImageId $testWorkerImageId
    Add-Check (
        $externalEnvironment -match
            '(?m)^PITCREW_READ_ONLY_VOLUMES=reference-data=pitcrew-reference-data-v1$'
    ) 'External profile environment omitted its read-only volume contract.'
    Add-Check (
        $externalEnvironment -match
            '(?m)^PITCREW_SERVICE_NETWORK=pitcrew-browser-services-v1$'
    ) 'External profile environment omitted its service network contract.'
    $admissionStaticProfile = New-RunnerStaticProfileState `
        -Profile $admissionProfile `
        -Scope repo `
        -OrgName '' `
        -EnterpriseName '' `
        -ResolvedImageId $testWorkerImageId
    Add-Check (
        $admissionStaticProfile.configuration.hostAdmission.namespace -ceq 'primary' -and
        -not $admissionStaticProfile.configuration.hostAdmission.PSObject.Properties[
            'capacityUnits'
        ]
    ) 'Static profile state did not isolate host-admission topology from mutable policy.'
    $admissionEnvironment = New-RunnerEnvironmentContent `
        -Profile $admissionProfile `
        -AccessToken 'test-registration-token' `
        -WorkerRevision $admissionStaticProfile.workerRevision `
        -SessionOwner 'pitcrew-browser-testing' `
        -AssumeUnversionedCurrent $false `
        -ResolvedImageId $testWorkerImageId
    Add-Check (
        $admissionEnvironment -match
            '(?m)^PITCREW_HOST_ADMISSION_NAMESPACE=primary$' -and
        $admissionEnvironment -match
            '(?m)^PITCREW_HOST_ADMISSION_VOLUME=pitcrew-host-admission-primary$' -and
        $admissionEnvironment -match
            '(?m)^PITCREW_HOST_ADMISSION_SOCKET=/var/lib/pitcrew-admission/coordinator\.sock$' -and
        $admissionEnvironment -match
            '(?m)^PITCREW_HOST_ADMISSION_HOST_FINGERPRINT=[0-9a-f]{64}$' -and
        $admissionEnvironment -match
            '(?m)^PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT=[0-9a-f]{64}$'
    ) 'Admission profile environment omitted its host-admission identity contract.'

    $changedAdmissionManifestPath = Join-Path $externalDirectory 'changed-admission-profile.json'
    $changedAdmissionManifest = Get-Content `
        -LiteralPath $admissionManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $changedAdmissionManifest.hostAdmission.capacityUnits = 14
    $changedAdmissionManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $changedAdmissionManifestPath -Encoding UTF8
    $changedAdmissionProfile = Resolve-RunnerProfile `
        -RootPath $runnerRoot `
        -ProfilePath $changedAdmissionManifestPath `
        -HostName 'test-host'
    Add-Check (
        $changedAdmissionProfile.HostAdmission.HostPolicyFingerprint -cne
            $admissionProfile.HostAdmission.HostPolicyFingerprint -and
        $changedAdmissionProfile.HostAdmission.ProfilePolicyFingerprint -ceq
            $admissionProfile.HostAdmission.ProfilePolicyFingerprint
    ) 'Host-wide admission changes did not isolate the host-policy fingerprint.'
    $externalStaticForAdmissionComparison = New-RunnerStaticProfileState `
        -Profile $admissionProfile `
        -Scope repo `
        -OrgName '' `
        -EnterpriseName '' `
        -ResolvedImageId $testWorkerImageId
    $changedAdmissionStatic = New-RunnerStaticProfileState `
        -Profile $changedAdmissionProfile `
        -Scope repo `
        -OrgName '' `
        -EnterpriseName '' `
        -ResolvedImageId $testWorkerImageId
    Add-Check (
        $changedAdmissionStatic.fingerprint -ceq
            $externalStaticForAdmissionComparison.fingerprint -and
        $changedAdmissionStatic.workerRevision -ceq
            $externalStaticForAdmissionComparison.workerRevision
    ) 'Mutable host-admission tuning changed manager topology or worker revision.'

    $changedProfilePolicyManifestPath = Join-Path $externalDirectory 'changed-admission-profile-policy.json'
    $changedProfilePolicyManifest = Get-Content `
        -LiteralPath $admissionManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $changedProfilePolicyManifest.hostAdmission.reservationUnits = 6
    $changedProfilePolicyManifest.hostAdmission.borrowable = $true
    $changedProfilePolicyManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $changedProfilePolicyManifestPath -Encoding UTF8
    $changedProfilePolicy = Resolve-RunnerProfile `
        -RootPath $runnerRoot `
        -ProfilePath $changedProfilePolicyManifestPath `
        -HostName 'test-host'
    Add-Check (
        $changedProfilePolicy.HostAdmission.HostPolicyFingerprint -ceq
            $admissionProfile.HostAdmission.HostPolicyFingerprint -and
        $changedProfilePolicy.HostAdmission.ProfilePolicyFingerprint -cne
            $admissionProfile.HostAdmission.ProfilePolicyFingerprint
    ) 'Per-profile admission changes did not isolate the profile-policy fingerprint.'
    $externalStaticForProfilePolicyComparison = New-RunnerStaticProfileState `
        -Profile $admissionProfile `
        -Scope repo `
        -OrgName '' `
        -EnterpriseName '' `
        -ResolvedImageId $testWorkerImageId
    $changedProfilePolicyStatic = New-RunnerStaticProfileState `
        -Profile $changedProfilePolicy `
        -Scope repo `
        -OrgName '' `
        -EnterpriseName '' `
        -ResolvedImageId $testWorkerImageId
    Add-Check (
        $changedProfilePolicyStatic.fingerprint -ceq
            $externalStaticForProfilePolicyComparison.fingerprint -and
        $changedProfilePolicyStatic.workerRevision -ceq
            $externalStaticForProfilePolicyComparison.workerRevision
    ) 'Per-profile admission tuning changed manager topology or worker revision.'

    $changedNamespaceManifestPath = Join-Path $externalDirectory 'changed-admission-namespace-profile.json'
    $changedNamespaceManifest = Get-Content `
        -LiteralPath $admissionManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $changedNamespaceManifest.hostAdmission.namespace = 'secondary'
    $changedNamespaceManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $changedNamespaceManifestPath -Encoding UTF8
    $changedNamespaceProfile = Resolve-RunnerProfile `
        -RootPath $runnerRoot `
        -ProfilePath $changedNamespaceManifestPath `
        -HostName 'test-host'
    $externalStaticForNamespaceComparison = New-RunnerStaticProfileState `
        -Profile $admissionProfile `
        -Scope repo `
        -OrgName '' `
        -EnterpriseName '' `
        -ResolvedImageId $testWorkerImageId
    $changedNamespaceStatic = New-RunnerStaticProfileState `
        -Profile $changedNamespaceProfile `
        -Scope repo `
        -OrgName '' `
        -EnterpriseName '' `
        -ResolvedImageId $testWorkerImageId
    Add-Check (
        $changedNamespaceStatic.fingerprint -cne
            $externalStaticForNamespaceComparison.fingerprint -and
        $changedNamespaceStatic.workerRevision -ceq
            $externalStaticForNamespaceComparison.workerRevision -and
        (
            Get-RunnerObjectFingerprint -Value (
                Get-RunnerRollingCompatibilityConfiguration `
                    -Configuration $changedNamespaceStatic.configuration
            )
        ) -ceq (
            Get-RunnerObjectFingerprint -Value (
                Get-RunnerRollingCompatibilityConfiguration `
                    -Configuration $externalStaticForNamespaceComparison.configuration
            )
        )
    ) 'Host-admission namespace changes did not affect manager identity independently of workers.'

    foreach ($invalidAdmissionCase in @(
        [PSCustomObject]@{
            Name = 'invalid-admission-margin-profile.json'
            Mutate = {
                param($document)
                $document.hostAdmission.safetyMarginUnits =
                    $document.hostAdmission.capacityUnits
            }
            Message = 'safety-margin units must be non-negative and lower than capacity units'
            Failure = 'A host-admission policy accepted a safety margin that consumed the full capacity.'
        },
        [PSCustomObject]@{
            Name = 'invalid-admission-cost-profile.json'
            Mutate = {
                param($document)
                $document.hostAdmission.workerCostUnits = 11
            }
            Message = 'worker-cost units must be positive and no greater than the effective host budget'
            Failure = 'A host-admission policy accepted a worker cost above the effective budget.'
        },
        [PSCustomObject]@{
            Name = 'invalid-admission-reservation-profile.json'
            Mutate = {
                param($document)
                $document.hostAdmission.reservationUnits = 11
            }
            Message = 'reservation units must be non-negative and no greater than the effective host budget'
            Failure = 'A host-admission policy accepted a reservation above the effective host budget.'
        }
    )) {
        $invalidAdmissionManifestPath = Join-Path $externalDirectory $invalidAdmissionCase.Name
        $invalidAdmissionManifest = Get-Content `
            -LiteralPath $admissionManifestPath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        & $invalidAdmissionCase.Mutate $invalidAdmissionManifest
        $invalidAdmissionManifest |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $invalidAdmissionManifestPath -Encoding UTF8
        Add-ThrowsCheck `
            -Action {
                Resolve-RunnerProfile `
                    -RootPath $runnerRoot `
                    -ProfilePath $invalidAdmissionManifestPath `
                    -HostName 'test-host'
            } `
            -ExpectedMessage $invalidAdmissionCase.Message `
            -Failure $invalidAdmissionCase.Failure
    }

    $changedVolumeManifestPath = Join-Path $externalDirectory 'changed-volume-profile.json'
    $changedVolumeManifest = Get-Content `
        -LiteralPath $externalManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $changedVolumeManifest.readOnlyVolumes[0].source =
        'pitcrew-reference-data-v2'
    $changedVolumeManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $changedVolumeManifestPath -Encoding UTF8
    $changedVolumeProfile = Resolve-RunnerProfile `
        -RootPath $runnerRoot `
        -ProfilePath $changedVolumeManifestPath `
        -HostName 'test-host'
    $changedVolumeStaticProfile = New-RunnerStaticProfileState `
        -Profile $changedVolumeProfile `
        -Scope repo `
        -OrgName '' `
        -EnterpriseName '' `
        -ResolvedImageId $testWorkerImageId
    Add-Check (
        $externalStaticProfile.workerRevision -cne
            $changedVolumeStaticProfile.workerRevision
    ) 'Changing a read-only volume source did not advance the worker revision.'
    Add-Check (
        (
            Get-RunnerObjectFingerprint -Value (
                Get-RunnerRollingCompatibilityConfiguration `
                    -Configuration $externalStaticProfile.configuration)
        ) -ceq (
            Get-RunnerObjectFingerprint -Value (
                Get-RunnerRollingCompatibilityConfiguration `
                    -Configuration $changedVolumeStaticProfile.configuration)
        )
    ) 'Changing a read-only volume source was not rolling-compatible.'
    Add-Check (
        (
            Get-RunnerObjectFingerprint -Value (
                Get-RunnerRefreshCompatibilityConfiguration `
                    -Configuration $externalStaticProfile.configuration)
        ) -cne (
            Get-RunnerObjectFingerprint -Value (
                Get-RunnerRefreshCompatibilityConfiguration `
                    -Configuration $changedVolumeStaticProfile.configuration)
        )
    ) 'Manager refresh compatibility ignored read-only volume drift.'

    $changedNetworkManifestPath = Join-Path $externalDirectory 'changed-network-profile.json'
    $changedNetworkManifest = Get-Content `
        -LiteralPath $externalManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $changedNetworkManifest.serviceNetwork.source =
        'pitcrew-browser-services-v2'
    $changedNetworkManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $changedNetworkManifestPath -Encoding UTF8
    $changedNetworkProfile = Resolve-RunnerProfile `
        -RootPath $runnerRoot `
        -ProfilePath $changedNetworkManifestPath `
        -HostName 'test-host'
    $changedNetworkStaticProfile = New-RunnerStaticProfileState `
        -Profile $changedNetworkProfile `
        -Scope repo `
        -OrgName '' `
        -EnterpriseName '' `
        -ResolvedImageId $testWorkerImageId
    Add-Check (
        $externalStaticProfile.workerRevision -cne
            $changedNetworkStaticProfile.workerRevision
    ) 'Changing the external service network did not advance the worker revision.'
    Add-Check (
        (
            Get-RunnerObjectFingerprint -Value (
                Get-RunnerRollingCompatibilityConfiguration `
                    -Configuration $externalStaticProfile.configuration)
        ) -ceq (
            Get-RunnerObjectFingerprint -Value (
                Get-RunnerRollingCompatibilityConfiguration `
                    -Configuration $changedNetworkStaticProfile.configuration)
        )
    ) 'Changing the external service network was not rolling-compatible.'
    Add-Check (
        (
            Get-RunnerObjectFingerprint -Value (
                Get-RunnerRefreshCompatibilityConfiguration `
                    -Configuration $externalStaticProfile.configuration)
        ) -cne (
            Get-RunnerObjectFingerprint -Value (
                Get-RunnerRefreshCompatibilityConfiguration `
                    -Configuration $changedNetworkStaticProfile.configuration)
        )
    ) 'Manager refresh compatibility ignored external service network drift.'

    $invalidNetworkManifestPath = Join-Path $externalDirectory 'invalid-network-profile.json'
    $invalidNetworkManifest = Get-Content `
        -LiteralPath $externalManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $invalidNetworkManifest.serviceNetwork.source = 'host/network'
    $invalidNetworkManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $invalidNetworkManifestPath -Encoding UTF8
    Add-ThrowsCheck `
        -Action {
            Resolve-RunnerProfile `
                -RootPath $runnerRoot `
                -ProfilePath $invalidNetworkManifestPath
        } `
        -ExpectedMessage 'not valid with the schema' `
        -Failure 'An external profile accepted an invalid service network name.'

    $managerNetworkManifestPath = Join-Path $externalDirectory 'manager-network-profile.json'
    $managerNetworkManifest = Get-Content `
        -LiteralPath $externalManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $managerNetworkManifest.serviceNetwork.source =
        'self-hosted-runner-browser-testing_default'
    $managerNetworkManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $managerNetworkManifestPath -Encoding UTF8
    Add-ThrowsCheck `
        -Action {
            Resolve-RunnerProfile `
                -RootPath $runnerRoot `
                -ProfilePath $managerNetworkManifestPath
        } `
        -ExpectedMessage 'reserved Docker or PitCrew manager network' `
        -Failure 'An external profile accepted a PitCrew manager Compose network.'

    $defaultBridgeManifestPath = Join-Path $externalDirectory 'default-bridge-profile.json'
    $defaultBridgeManifest = Get-Content `
        -LiteralPath $externalManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $defaultBridgeManifest.serviceNetwork.source = 'bridge'
    $defaultBridgeManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $defaultBridgeManifestPath -Encoding UTF8
    Add-ThrowsCheck `
        -Action {
            Resolve-RunnerProfile `
                -RootPath $runnerRoot `
                -ProfilePath $defaultBridgeManifestPath
        } `
        -ExpectedMessage 'reserved Docker or PitCrew manager network' `
        -Failure 'An external profile accepted Docker''s default bridge without stable service DNS.'

    $duplicateVolumeManifestPath = Join-Path $externalDirectory 'duplicate-volume-profile.json'
    $duplicateVolumeManifest = Get-Content `
        -LiteralPath $externalManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $duplicateVolumeManifest.readOnlyVolumes = @(
        $duplicateVolumeManifest.readOnlyVolumes[0],
        @{
            name = 'reference-data'
            source = 'pitcrew-reference-data-v2'
        }
    )
    $duplicateVolumeManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $duplicateVolumeManifestPath -Encoding UTF8
    Add-ThrowsCheck `
        -Action {
            Resolve-RunnerProfile `
                -RootPath $runnerRoot `
                -ProfilePath $duplicateVolumeManifestPath
        } `
        -ExpectedMessage 'read-only volume name' `
        -Failure 'An external profile accepted duplicate read-only volume names.'

    $invalidVolumeManifestPath = Join-Path $externalDirectory 'invalid-volume-profile.json'
    $invalidVolumeManifest = Get-Content `
        -LiteralPath $externalManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $invalidVolumeManifest.readOnlyVolumes[0].source = 'host/path'
    $invalidVolumeManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $invalidVolumeManifestPath -Encoding UTF8
    Add-ThrowsCheck `
        -Action {
            Resolve-RunnerProfile `
                -RootPath $runnerRoot `
                -ProfilePath $invalidVolumeManifestPath
        } `
        -ExpectedMessage 'not valid with the schema' `
        -Failure 'An external profile accepted a host path as a volume source.'

    $excessiveVolumeManifestPath = Join-Path $externalDirectory 'excessive-volume-profile.json'
    $excessiveVolumeManifest = Get-Content `
        -LiteralPath $externalManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 10
    $excessiveVolumeManifest.readOnlyVolumes = @(
        1..9 | ForEach-Object {
            @{
                name = "data-$_"
                source = "pitcrew-data-$_"
            }
        }
    )
    $excessiveVolumeManifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $excessiveVolumeManifestPath -Encoding UTF8
    Add-ThrowsCheck `
        -Action {
            Resolve-RunnerProfile `
                -RootPath $runnerRoot `
                -ProfilePath $excessiveVolumeManifestPath
        } `
        -ExpectedMessage 'not valid with the schema' `
        -Failure 'An external profile accepted more than eight read-only volumes.'

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
        'PITCREW_WORKER_IMAGE_ID',
        'PITCREW_WORKER_MEMORY_BYTES',
        'PITCREW_WORKER_MEMORY_SWAP_BYTES',
        'PITCREW_WORKER_CPU_CORES',
        'PITCREW_WORKER_PIDS_LIMIT',
        'PITCREW_WORKER_RUNTIME_DEVICES',
        'PITCREW_WORKER_SHM_SIZE_BYTES',
        'PITCREW_READ_ONLY_VOLUMES',
        'PITCREW_SERVICE_NETWORK',
        'PITCREW_AUTOSCALING_MODE',
        'PITCREW_AUTOSCALING_MIN_IDLE',
        'PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS',
        'PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS',
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
    $env:PITCREW_WORKER_IMAGE_ID = $changedWorkerImageId
    $env:PITCREW_WORKER_MEMORY_BYTES = '99'
    $env:PITCREW_WORKER_MEMORY_SWAP_BYTES = '999'
    $env:PITCREW_WORKER_CPU_CORES = '9.9'
    $env:PITCREW_WORKER_PIDS_LIMIT = '9999'
    $env:PITCREW_WORKER_RUNTIME_DEVICES = 'ambient-device'
    $env:PITCREW_WORKER_SHM_SIZE_BYTES = '9999999999'
    $env:PITCREW_READ_ONLY_VOLUMES = 'ambient=wrong-volume'
    $env:PITCREW_SERVICE_NETWORK = 'ambient-wrong-network'
    $env:PITCREW_AUTOSCALING_MODE = 'ambient-mode'
    $env:PITCREW_AUTOSCALING_MIN_IDLE = '99'
    $env:PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS = '999'
    $env:PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS = '99'
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
                -Value "compose-env`tACCESS_TOKEN=$env:ACCESS_TOKEN`tREPO_URLS=$env:REPO_URLS`tREPO_URL=$env:REPO_URL`tRUNNER_PROFILE_ID=$env:RUNNER_PROFILE_ID`tRUNNER_REPLICAS=$env:RUNNER_REPLICAS`tRUNNER_IMAGE=$env:RUNNER_IMAGE`tPITCREW_WORKER_IMAGE_ID=$env:PITCREW_WORKER_IMAGE_ID`tPITCREW_WORKER_MEMORY_BYTES=$env:PITCREW_WORKER_MEMORY_BYTES`tPITCREW_WORKER_MEMORY_SWAP_BYTES=$env:PITCREW_WORKER_MEMORY_SWAP_BYTES`tPITCREW_WORKER_CPU_CORES=$env:PITCREW_WORKER_CPU_CORES`tPITCREW_WORKER_PIDS_LIMIT=$env:PITCREW_WORKER_PIDS_LIMIT`tPITCREW_WORKER_RUNTIME_DEVICES=$env:PITCREW_WORKER_RUNTIME_DEVICES`tPITCREW_WORKER_SHM_SIZE_BYTES=$env:PITCREW_WORKER_SHM_SIZE_BYTES`tPITCREW_READ_ONLY_VOLUMES=$env:PITCREW_READ_ONLY_VOLUMES`tPITCREW_SERVICE_NETWORK=$env:PITCREW_SERVICE_NETWORK`tPITCREW_AUTOSCALING_MODE=$env:PITCREW_AUTOSCALING_MODE`tPITCREW_AUTOSCALING_MIN_IDLE=$env:PITCREW_AUTOSCALING_MIN_IDLE`tPITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS=$env:PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS`tPITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS=$env:PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS`tPITCREW_STATE_DIR=$env:PITCREW_STATE_DIR`tPITCREW_MANAGER_CONTRACT_VERSION=$env:PITCREW_MANAGER_CONTRACT_VERSION"
            if (
                $dockerArguments -contains 'build' -and
                $dockerArguments -contains 'runner-manager' -and
                $env:PITCREW_TEST_MANAGER_BUILD_FAILURE -eq '1'
            ) {
                $global:LASTEXITCODE = 1
                return
            }
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
            if ($env:PITCREW_TEST_MANAGER_EXTRA_ID) {
                Write-Output $env:PITCREW_TEST_MANAGER_EXTRA_ID
            }
        }
        if (
            $dockerArguments[0] -eq 'ps' -and
            $dockerArguments -contains '-q' -and
            $dockerArguments -contains 'label=ephemeral-managed-runner-profile=default' -and
            $env:PITCREW_TEST_WORKER_IDS
        ) {
            foreach ($workerId in ($env:PITCREW_TEST_WORKER_IDS -split ',')) {
                if ($workerId) {
                    Write-Output $workerId
                }
            }
        }
        if ($dockerArguments[0] -eq 'restart') {
            if ($env:PITCREW_TEST_RESTART_FAILURE -eq '1') {
                $global:LASTEXITCODE = 1
                return
            }
            if (
                $env:PITCREW_TEST_POST_OBSERVED_SOURCE -and
                $env:PITCREW_TEST_POST_OBSERVED_TARGET
            ) {
                Copy-Item `
                    -LiteralPath $env:PITCREW_TEST_POST_OBSERVED_SOURCE `
                    -Destination $env:PITCREW_TEST_POST_OBSERVED_TARGET `
                    -Force
            }
            if ($env:PITCREW_TEST_POST_WORKER_IDS) {
                $env:PITCREW_TEST_WORKER_IDS = $env:PITCREW_TEST_POST_WORKER_IDS
            }
            $global:LASTEXITCODE = 0
            return
        }
        if (
            $dockerArguments[0] -eq 'run' -and
            $env:PITCREW_TEST_IMAGE_RUN_FAILURE -eq '1'
        ) {
            $env:PITCREW_TEST_IMAGE_RUN_FAILURE_USED = '1'
            $global:LASTEXITCODE = 1
            return
        }
        if (
            $dockerArguments[0] -eq 'image' -and
            $dockerArguments[1] -eq 'inspect' -and
            (
                $env:PITCREW_TEST_IMAGE_MISSING -eq '1' -or
                (
                    $env:PITCREW_TEST_IMAGE_RUN_FAILURE_USED -eq '1' -and
                    $env:PITCREW_TEST_IMAGE_ROLLBACK_MISSING -eq '1'
                )
            )
        ) {
            $global:LASTEXITCODE = 1
            return
        }
        if (
            $dockerArguments[0] -eq 'image' -and
            $dockerArguments[1] -eq 'inspect' -and
            $dockerArguments -contains '{{.Id}}'
        ) {
            Write-Output $(if (
                $env:PITCREW_TEST_IMAGE_RUN_FAILURE_USED -eq '1' -and
                $env:PITCREW_TEST_IMAGE_ROLLBACK_ID
            ) {
                $env:PITCREW_TEST_IMAGE_ROLLBACK_ID
            } elseif ($env:PITCREW_TEST_WORKER_IMAGE_ID) {
                $env:PITCREW_TEST_WORKER_IMAGE_ID
            } else {
                $testWorkerImageId
            })
        }
        if (
            $dockerArguments[0] -eq 'volume' -and
            $dockerArguments[1] -eq 'inspect'
        ) {
            if ($env:PITCREW_TEST_VOLUME_MISSING -eq '1') {
                $global:LASTEXITCODE = 1
                return
            }
            Write-Output ([string]$dockerArguments[-1])
        }
        if (
            $dockerArguments[0] -eq 'network' -and
            $dockerArguments[1] -eq 'inspect'
        ) {
            if ($env:PITCREW_TEST_NETWORK_MISSING -eq '1') {
                $global:LASTEXITCODE = 1
                return
            }
            $networkName = [string]$dockerArguments[-1]
            Write-Output $(if ($env:PITCREW_TEST_NETWORK_IDENTITY) {
                $env:PITCREW_TEST_NETWORK_IDENTITY
            } else {
                "$networkName|bridge|local|false"
            })
        }
        if (
            $dockerArguments[0] -eq 'inspect' -and
            $dockerArguments -contains 'manager-container-id' -and
            $dockerArguments -contains '{{ index .Config.Labels "pitcrew-manager-contract-version" }}'
        ) {
            Write-Output $(if ($env:PITCREW_TEST_MANAGER_CONTRACT) {
                $env:PITCREW_TEST_MANAGER_CONTRACT
            } else {
                '10'
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

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -ProfilePath $changedVolumeManifestPath `
            -Token 'test-registration-token' `
            -Repos 'https://github.com/example/project=1'
        $volumeEnvironmentPath = Join-Path $fixtureRoot '.env.browser-testing'
        $volumeStaticPath = Join-Path `
            $fixtureRoot `
            '.pitcrew-state' `
            'browser-testing' `
            'static-profile.json'
        $volumeEnvironment = Get-Content `
            -LiteralPath $volumeEnvironmentPath `
            -Raw `
            -Encoding UTF8
        $volumeStatic = Get-Content `
            -LiteralPath $volumeStaticPath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json -Depth 20
        $volumeCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (
            $volumeEnvironment -match
                '(?m)^PITCREW_READ_ONLY_VOLUMES=reference-data=pitcrew-reference-data-v2$'
        ) 'Setup did not pass the approved read-only volume contract to the manager.'
        Add-Check (
            $volumeEnvironment -match
                '(?m)^PITCREW_SERVICE_NETWORK=pitcrew-browser-services-v1$'
        ) 'Setup did not pass the approved external service network to the manager.'
        Add-Check (
            $volumeStatic.configuration.readOnlyVolumes[0].target -eq
                '/mnt/pitcrew-data/reference-data'
        ) 'Setup did not persist the deterministic read-only volume target.'
        Add-Check (
            $volumeCommands -match
                "volume`tinspect`t--format`t\{\{\.Name\}\}`tpitcrew-reference-data-v2"
        ) 'Setup did not preflight the exact external Docker volume.'
        Add-Check (
            $volumeCommands -match
                "--mount`ttype=volume,src=pitcrew-reference-data-v2,dst=/mnt/pitcrew-data/reference-data,readonly,volume-nocopy"
        ) 'Image verification did not receive the read-only external volume.'
        Add-Check (
            $volumeCommands -match
                "network`tinspect`t--format`t\{\{\.Name\}\}\|\{\{\.Driver\}\}\|\{\{\.Scope\}\}\|\{\{\.Internal\}\}`tpitcrew-browser-services-v1"
        ) 'Setup did not preflight the exact external Docker service network.'
        Add-Check (
            $volumeCommands -match
                "run`t--rm`t--network`tpitcrew-browser-services-v1"
        ) 'Image verification did not join the external Docker service network.'
        Add-Check (-not ($volumeCommands -match "volume`tcreate")) 'Setup created an external Docker volume.'
        Add-Check (-not ($volumeCommands -match "volume`trm")) 'Setup removed an external Docker volume.'
        Add-Check (-not ($volumeCommands -match "network`tcreate")) 'Setup created an external Docker service network.'
        Add-Check (-not ($volumeCommands -match "network`trm")) 'Setup removed an external Docker service network.'

        $env:PITCREW_TEST_VOLUME_MISSING = '1'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -ProfilePath $changedVolumeManifestPath `
                    -Token 'test-registration-token' `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'Required external Docker volume' `
            -Failure 'Setup accepted a missing required external Docker volume.'
        $missingVolumeCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (
            -not ($missingVolumeCommands -match "compose`t.*`tup")
        ) 'A missing external Docker volume reached manager startup.'
        $env:PITCREW_TEST_VOLUME_MISSING = '0'

        $env:PITCREW_TEST_NETWORK_MISSING = '1'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -ProfilePath $changedVolumeManifestPath `
                    -Token 'test-registration-token' `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'Required external Docker service network' `
            -Failure 'Setup accepted a missing required external Docker service network.'
        $missingNetworkCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (
            -not ($missingNetworkCommands -match "compose`t.*`tup")
        ) 'A missing external Docker service network reached manager startup.'
        $env:PITCREW_TEST_NETWORK_MISSING = '0'

        $env:PITCREW_TEST_NETWORK_IDENTITY =
            'pitcrew-browser-services-v1|bridge|local|true'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -ProfilePath $changedVolumeManifestPath `
                    -Token 'test-registration-token' `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'local, non-internal bridge network' `
            -Failure 'Setup accepted an internal external Docker service network.'
        $incompatibleNetworkCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (
            -not ($incompatibleNetworkCommands -match "compose`t.*`tup")
        ) 'An incompatible external Docker service network reached manager startup.'
        Remove-Item Env:PITCREW_TEST_NETWORK_IDENTITY -ErrorAction SilentlyContinue

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -Token 'test-registration-token' `
            -WorkerMemory '512m' `
            -WorkerMemorySwap '1g' `
            -WorkerCpus '2.5' `
            -WorkerPids 256 `
            -Repos 'https://github.com/example/project=1'
        $fixedResourceEnvironment = Get-Content `
            -LiteralPath (Join-Path $fixtureRoot '.env') -Raw -Encoding UTF8
        Add-Check ($fixedResourceEnvironment -match '(?m)^PITCREW_MANAGER_CONTRACT_VERSION=18$') 'Fixed setup did not activate manager contract 18.'
        Add-Check ($fixedResourceEnvironment -match '(?m)^PITCREW_WORKER_MEMORY_BYTES=536870912$') 'The fixed manager did not receive the canonical worker memory limit.'
        Add-Check ($fixedResourceEnvironment -match '(?m)^PITCREW_WORKER_MEMORY_SWAP_BYTES=1073741824$') 'The fixed manager did not receive the canonical worker memory-swap limit.'
        Add-Check ($fixedResourceEnvironment -match '(?m)^PITCREW_WORKER_CPU_CORES=2\.5$') 'The fixed manager did not receive the canonical worker CPU limit.'
        Add-Check ($fixedResourceEnvironment -match '(?m)^PITCREW_WORKER_PIDS_LIMIT=256$') 'The fixed manager did not receive the canonical worker PID limit.'
        $fixedResourceCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($fixedResourceCommands -match "`tdown`t")) 'Activating a resource policy tore down the running pool.'
        Add-Check (-not ($fixedResourceCommands -match "^rm`t-f`t")) 'Activating a resource policy force-removed existing workers.'
        Remove-Item -LiteralPath (Join-Path $fixtureRoot '.env') -Force
        Remove-Item -LiteralPath (Join-Path $fixtureRoot '.pitcrew-state') -Recurse -Force

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -Token 'test-registration-token' `
            -Autoscale `
            -MaximumActiveWorkers 4 `
            -WorkerMemory '512m' `
            -Repos 'https://github.com/example/project=2'
        $autoscaledAdmissionEnvironment = Get-Content `
            -LiteralPath (Join-Path $fixtureRoot '.env') -Raw -Encoding UTF8
        Add-Check ($autoscaledAdmissionEnvironment -match '(?m)^PITCREW_MANAGER_CONTRACT_VERSION=18$') 'Autoscaled setup did not activate manager contract 18.'
        Add-Check ($autoscaledAdmissionEnvironment -match '(?m)^PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS=4$') 'The autoscaler did not receive the profile-wide admission ceiling.'
        Add-Check ($autoscaledAdmissionEnvironment -match '(?m)^PITCREW_WORKER_MEMORY_BYTES=536870912$') 'The autoscaler did not receive the canonical worker memory limit.'
        $admissionCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($admissionCommands -match "`tdown`t")) 'Activating an admission ceiling tore down the running pool.'
        Add-Check (-not ($admissionCommands -match "^rm`t-f`t")) 'Activating an admission ceiling force-removed existing workers.'
        Remove-Item -LiteralPath (Join-Path $fixtureRoot '.env') -Force
        Remove-Item -LiteralPath (Join-Path $fixtureRoot '.pitcrew-state') -Recurse -Force

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
        Add-Check ($defaultEnvironmentState -match "(?m)^PITCREW_WORKER_IMAGE_ID=$([regex]::Escape($testWorkerImageId))$") 'Default setup did not persist immutable worker image identity.'
        Add-Check ($defaultEnvironmentState -notmatch '(?m)^(REPO_URLS|RUNNER_REPLICAS)=') 'Default setup wrote mutable capacity into the static environment.'
        $defaultStaticProfileState = Get-Content -LiteralPath $defaultStaticProfilePath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 20
        Add-Check ($defaultStaticProfileState.configuration.resolvedImageId -ceq $testWorkerImageId) 'Default setup did not persist immutable image identity in static state.'
        Add-Check ($defaultDesiredState.generation -eq 1) 'Initial desired capacity did not start at generation one.'
        Add-Check ($defaultDesiredState.repositories[0].workers -eq 1) 'Initial desired capacity did not preserve the repository worker count.'
        $defaultCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (
            $defaultCommands -match (
                'pull.*' +
                [regex]::Escape(
                    'myoung34/github-runner:2.336.0-ubuntu-noble@sha256:c803ddbc5b91961aabf3411c6336cb2c838cdaa2f917f76654c15a1948934817'
                )
            )
        ) 'Default setup did not prepare its pinned image before replacement.'
        Add-Check ($defaultCommands -match "compose-env`tACCESS_TOKEN=`tREPO_URLS=`tREPO_URL=`tRUNNER_PROFILE_ID=`tRUNNER_REPLICAS=`tRUNNER_IMAGE=`tPITCREW_WORKER_IMAGE_ID=`tPITCREW_WORKER_MEMORY_BYTES=`tPITCREW_WORKER_MEMORY_SWAP_BYTES=`tPITCREW_WORKER_CPU_CORES=`tPITCREW_WORKER_PIDS_LIMIT=`tPITCREW_WORKER_RUNTIME_DEVICES=`tPITCREW_WORKER_SHM_SIZE_BYTES=`tPITCREW_READ_ONLY_VOLUMES=`tPITCREW_SERVICE_NETWORK=`tPITCREW_AUTOSCALING_MODE=`tPITCREW_AUTOSCALING_MIN_IDLE=`tPITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS=`tPITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS=`tPITCREW_STATE_DIR=`tPITCREW_MANAGER_CONTRACT_VERSION=$") 'Ambient profile variables were visible to Docker Compose.'
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

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -RecoverMissingManager `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage '-RecoverMissingManager requires -Refresh' `
            -Failure 'Missing-manager recovery was accepted without explicit refresh semantics.'
        $missingRecoveryGuardCommands = @(
            Get-Content -LiteralPath $dockerLog -Encoding UTF8
        )
        Add-Check (
            -not ($missingRecoveryGuardCommands -match 'compose.*\t(build|up)(\t|$)')
        ) 'An invalid missing-manager recovery reached Docker Compose.'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        $missingManagerAcknowledgement = Start-TestCapacityAcknowledgementWriter `
            -DesiredPath $defaultDesiredPath `
            -AcknowledgementPath $defaultAcknowledgementPath `
            -Generation 1 `
            -DesiredSlots 1 `
            -AddedSlots 0 `
            -DrainingSlots 0 `
            -UnchangedSlots 1 `
            -WaitForAcknowledgementRemoval 1
        try {
            & $fixtureSetup `
                -Token 'test-registration-token' `
                -Refresh `
                -RecoverMissingManager `
                -Repos 'https://github.com/example/project=1'
        }
        finally {
            Wait-Job -Job $missingManagerAcknowledgement -Timeout 65 | Out-Null
            Receive-Job `
                -Job $missingManagerAcknowledgement `
                -ErrorAction Stop | Out-Null
            Remove-Job -Job $missingManagerAcknowledgement -Force
        }
        $missingManagerCommands = @(
            Get-Content -LiteralPath $dockerLog -Encoding UTF8
        )
        $missingManagerAck = Get-Content `
            -LiteralPath $defaultAcknowledgementPath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-Check (
            $missingManagerCommands -match 'compose.*build.*runner-manager'
        ) 'Explicit missing-manager recovery did not build the manager first.'
        Add-Check (
            $missingManagerCommands -match 'compose.*up.*runner-manager'
        ) 'Explicit missing-manager recovery did not start the selected manager.'
        Add-Check (
            -not (
                $missingManagerCommands -match
                    '(stop|update|rm).*manager-container-id'
            ) -and
            -not ($missingManagerCommands -match 'compose.*\tdown(\t|$)')
        ) 'Missing-manager recovery attempted a manager or profile shutdown path.'
        Add-Check (
            $missingManagerAck.generation -eq 1 -and
            $missingManagerAck.managerContractVersion -eq 18
        ) 'Missing-manager recovery did not require a fresh current-contract acknowledgement.'

        $env:PITCREW_TEST_MANAGER_RUNNING = '1'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Refresh `
                    -RecoverMissingManager `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'already has a running manager' `
            -Failure 'Missing-manager recovery accepted an already running profile.'
        $runningRecoveryCommands = @(
            Get-Content -LiteralPath $dockerLog -Encoding UTF8
        )
        Add-Check (
            -not ($runningRecoveryCommands -match 'compose.*\t(build|up)(\t|$)')
        ) 'A rejected missing-manager recovery modified the running profile.'

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

        $env:PITCREW_TEST_WORKER_IMAGE_ID = $changedWorkerImageId
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -CapacityOnly `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'Capacity-only update cannot proceed' `
            -Failure 'Capacity-only setup ignored changed immutable image content.'
        $changedImageCapacityCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($changedImageCapacityCommands -match '(^|\t)(pull|build|run)(\t|$)|compose.*(up|down)')) 'A changed-image capacity guard mutated the live profile.'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Refresh `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'worker profile configuration is otherwise unchanged' `
            -Failure 'Manager refresh ignored changed immutable image content.'
        $changedImageRefreshCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (-not ($changedImageRefreshCommands -match '(^|\t)(pull|build|run)(\t|$)|compose.*(up|down)')) 'A changed-image refresh guard mutated the live profile.'
        Remove-Item Env:\PITCREW_TEST_WORKER_IMAGE_ID -ErrorAction SilentlyContinue

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
            -UnchangedSlots 1 `
            -WaitForAcknowledgementRemoval 0
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
            -UnchangedSlots 1 `
            -WaitForAcknowledgementRemoval 0
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
            -UnchangedSlots 1 `
            -WaitForAcknowledgementRemoval 0
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
            -UnchangedSlots 1 `
            -WaitForAcknowledgementRemoval 1
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
            -UnchangedSlots 1 `
            -WaitForAcknowledgementRemoval 1
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

        $env:PITCREW_TEST_MANAGER_BUILD_FAILURE = '1'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Refresh `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'docker compose build failed' `
            -Failure 'A failed replacement-manager build was not surfaced.'
        Remove-Item Env:\PITCREW_TEST_MANAGER_BUILD_FAILURE -ErrorAction SilentlyContinue
        $managerBuildFailureCommands = @(
            Get-Content -LiteralPath $dockerLog -Encoding UTF8
        )
        Add-Check (
            -not (
                $managerBuildFailureCommands -match (
                    "tag.*$([regex]::Escape($testWorkerImageId)).*" +
                    [regex]::Escape(
                        'myoung34/github-runner:2.336.0-ubuntu-noble@sha256:c803ddbc5b91961aabf3411c6336cb2c838cdaa2f917f76654c15a1948934817'
                    )
                )
            )
        ) 'A pre-handoff manager-build failure attempted to tag an immutable worker image.'
        Add-Check (-not ($managerBuildFailureCommands -match '^stop\t')) 'A failed replacement-manager build stopped the live manager.'

        $preRollbackEnvironment = Get-Content -LiteralPath $defaultEnvironmentPath -Raw -Encoding UTF8
        $preRollbackStatic = Get-Content -LiteralPath $defaultStaticProfilePath -Raw -Encoding UTF8
        $preRollbackDesired = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8
        $env:PITCREW_TEST_MANAGER_START_FAILURE = '1'
        Remove-Item Env:\PITCREW_TEST_MANAGER_START_FAILURE_USED -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        $rollbackAcknowledgement = Start-TestCapacityAcknowledgementWriter `
            -DesiredPath $defaultDesiredPath `
            -AcknowledgementPath $defaultAcknowledgementPath `
            -Generation 4 `
            -DesiredSlots 1 `
            -AddedSlots 0 `
            -DrainingSlots 0 `
            -UnchangedSlots 1 `
            -WaitForAcknowledgementRemoval 1 `
            -DelayMilliseconds 1000
        try {
            Add-ThrowsCheck `
                -Action {
                    & $fixtureSetup `
                        -Token 'test-registration-token' `
                        -Refresh `
                        -Repos 'https://github.com/example/project=1'
                } `
                -ExpectedMessage 'docker compose up failed' `
                -Failure 'A failed manager start was not surfaced after rollback.'
        }
        finally {
            Wait-Job -Job $rollbackAcknowledgement -Timeout 65 | Out-Null
            Receive-Job `
                -Job $rollbackAcknowledgement `
                -ErrorAction Stop |
                Out-Null
            Remove-Job -Job $rollbackAcknowledgement -Force
        }
        Remove-Item Env:\PITCREW_TEST_MANAGER_START_FAILURE -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_START_FAILURE_USED -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_CONTRACT -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_BUILD_FAILURE -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_CONTRACT -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_BUILD_FAILURE -ErrorAction SilentlyContinue
        $rollbackCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($rollbackCommands -match 'tag.*sha256:manager-image.*ephemeral-runner-manager:profile-default') 'A failed manager start did not restore the previous manager image.'
        Add-Check (
            -not (
                $rollbackCommands -match (
                    "tag.*$([regex]::Escape($testWorkerImageId)).*" +
                    [regex]::Escape(
                        'myoung34/github-runner:2.336.0-ubuntu-noble@sha256:c803ddbc5b91961aabf3411c6336cb2c838cdaa2f917f76654c15a1948934817'
                    )
                )
            )
        ) 'A failed manager start attempted to tag an immutable worker image.'
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

        $preDigestStatic = Get-Content `
            -LiteralPath $defaultStaticProfilePath `
            -Raw `
            -Encoding UTF8
        $digestProfile = Resolve-RunnerProfile `
            -RootPath $fixtureRoot `
            -ProfilePath $digestManifestPath `
            -HostName ([Environment]::MachineName)
        $digestStatic = New-RunnerStaticProfileState `
            -Profile $digestProfile `
            -Scope repo `
            -OrgName '' `
            -EnterpriseName '' `
            -ResolvedImageId $testWorkerImageId
        try {
            $digestStatic |
                ConvertTo-Json -Depth 20 |
                Set-Content `
                    -LiteralPath $defaultStaticProfilePath `
                    -Encoding UTF8

            $env:PITCREW_TEST_IMAGE_RUN_FAILURE = '1'
            Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
            Add-ThrowsCheck `
                -Action {
                    & $fixtureSetup `
                        -ProfilePath $digestManifestPath `
                        -Token 'test-registration-token' `
                        -Repos 'https://github.com/example/project=1'
                } `
                -ExpectedMessage 'Runner image verification failed.*verify-digest-image' `
                -Failure 'An unchanged digest-qualified image obscured its preparation failure.'
            $digestPreparationCommands = @(
                Get-Content -LiteralPath $dockerLog -Encoding UTF8
            )
            Add-Check (
                -not ($digestPreparationCommands -match '^tag\t')
            ) 'An unchanged digest-qualified image attempted an invalid tag rollback.'
            Add-Check (
                -not ($digestPreparationCommands -match '^stop\t|compose.*\tup(\t|$)')
            ) 'A digest-qualified image verification failure reached manager handoff.'
            Remove-Item `
                Env:\PITCREW_TEST_IMAGE_RUN_FAILURE_USED `
                -ErrorAction SilentlyContinue

            $env:PITCREW_TEST_IMAGE_ROLLBACK_ID = $changedWorkerImageId
            Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
            Add-ThrowsCheck `
                -Action {
                    & $fixtureSetup `
                        -ProfilePath $digestManifestPath `
                        -Token 'test-registration-token' `
                        -Repos 'https://github.com/example/project=1'
                } `
                -ExpectedMessage 'Immutable worker image rollback.*resolves to.*instead of' `
                -Failure 'A mismatched digest-qualified image did not fail explicitly.'
            $digestMismatchCommands = @(
                Get-Content -LiteralPath $dockerLog -Encoding UTF8
            )
            Add-Check (
                -not ($digestMismatchCommands -match '^tag\t')
            ) 'A mismatched digest-qualified image attempted an invalid tag rollback.'
            Remove-Item `
                Env:\PITCREW_TEST_IMAGE_RUN_FAILURE_USED `
                -ErrorAction SilentlyContinue
            Remove-Item `
                Env:\PITCREW_TEST_IMAGE_ROLLBACK_ID `
                -ErrorAction SilentlyContinue

            $env:PITCREW_TEST_IMAGE_ROLLBACK_MISSING = '1'
            Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
            Add-ThrowsCheck `
                -Action {
                    & $fixtureSetup `
                        -ProfilePath $digestManifestPath `
                        -Token 'test-registration-token' `
                        -Repos 'https://github.com/example/project=1'
                } `
                -ExpectedMessage 'Immutable worker image rollback.*not available locally' `
                -Failure 'A missing digest-qualified image did not fail explicitly.'
            $digestMissingCommands = @(
                Get-Content -LiteralPath $dockerLog -Encoding UTF8
            )
            Add-Check (
                -not ($digestMissingCommands -match '^tag\t')
            ) 'A missing digest-qualified image attempted an invalid tag rollback.'
            Remove-Item `
                Env:\PITCREW_TEST_IMAGE_RUN_FAILURE `
                -ErrorAction SilentlyContinue
            Remove-Item `
                Env:\PITCREW_TEST_IMAGE_RUN_FAILURE_USED `
                -ErrorAction SilentlyContinue
            Remove-Item `
                Env:\PITCREW_TEST_IMAGE_ROLLBACK_MISSING `
                -ErrorAction SilentlyContinue

            $env:PITCREW_TEST_MANAGER_BUILD_FAILURE = '1'
            Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
            Add-ThrowsCheck `
                -Action {
                    & $fixtureSetup `
                        -ProfilePath $digestManifestPath `
                        -Token 'test-registration-token' `
                        -Refresh `
                        -Repos 'https://github.com/example/project=1'
                } `
                -ExpectedMessage 'docker compose build failed' `
                -Failure 'A shared manager-update rollback rejected an unchanged digest-qualified image.'
            $digestManagerFailureCommands = @(
                Get-Content -LiteralPath $dockerLog -Encoding UTF8
            )
            Add-Check (
                -not ($digestManagerFailureCommands -match '^tag\t')
            ) 'A manager-update failure attempted to tag an immutable worker image.'
            Add-Check (
                -not ($digestManagerFailureCommands -match '^stop\t')
            ) 'A pre-handoff manager failure stopped the live manager for a digest-qualified image.'
        }
        finally {
            Set-Content `
                -LiteralPath $defaultStaticProfilePath `
                -Value $preDigestStatic `
                -NoNewline `
                -Encoding UTF8
            Remove-Item `
                Env:\PITCREW_TEST_IMAGE_RUN_FAILURE `
                -ErrorAction SilentlyContinue
            Remove-Item `
                Env:\PITCREW_TEST_IMAGE_RUN_FAILURE_USED `
                -ErrorAction SilentlyContinue
            Remove-Item `
                Env:\PITCREW_TEST_IMAGE_ROLLBACK_ID `
                -ErrorAction SilentlyContinue
            Remove-Item `
                Env:\PITCREW_TEST_IMAGE_ROLLBACK_MISSING `
                -ErrorAction SilentlyContinue
            Remove-Item `
                Env:\PITCREW_TEST_MANAGER_BUILD_FAILURE `
                -ErrorAction SilentlyContinue
        }

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
        Add-Check ($autoscalingCommands -match 'run.*Runner\.Listener') 'Setup did not verify the JIT runner image contract.'
        Add-Check (-not ($autoscalingCommands -match 'id runner')) 'Setup still requires a hard-coded JIT worker user.'
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

        $env:PITCREW_TEST_MANAGER_RUNNING = '0'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -Profile automation-control `
            -Token 'test-registration-token' `
            -Repos 'https://github.com/example/project=1'
        $automationControlStatePath = Join-Path `
            $fixtureRoot `
            '.env.automation-control'
        $automationControlState = Get-Content `
            -LiteralPath $automationControlStatePath `
            -Raw `
            -Encoding UTF8
        $automationControlCommands = @(
            Get-Content -LiteralPath $dockerLog -Encoding UTF8
        )
        Add-Check ($automationControlState -match '(?m)^RUNNER_PROFILE_ID=automation-control$') 'Automation-control setup did not write profile-specific state.'
        Add-Check ($automationControlState -match '(?m)^RUNNER_LABELS=automation-control$') 'Automation-control setup exposed labels beyond its exact profile identity.'
        Add-Check ($automationControlState -match '(?m)^RUNNER_NO_DEFAULT_LABELS=1$') 'Automation-control setup did not disable broad default labels.'
        Add-Check ($automationControlState -match '(?m)^PITCREW_AUTOSCALING_MODE=scale-set$') 'Automation-control setup did not retain scale-set-only execution.'
        Add-Check ($automationControlCommands -match 'build.*--tag.*pitcrew-automation-control:runner2\.336\.0-gh2\.98\.0-pwsh7\.6\.5-git2\.55\.0') 'Automation-control setup did not build the versioned image.'
        Add-Check ($automationControlCommands -match 'run.*--entrypoint.*/bin/sh.*Runner\.Listener --version') 'Automation-control setup did not verify the JIT listener.'
        Add-Check ($automationControlCommands -match 'run.*--entrypoint.*/bin/sh.*gh --version') 'Automation-control setup did not verify GitHub CLI.'
        Add-Check ($automationControlCommands -match 'run.*--entrypoint.*/bin/sh.*pwsh ') 'Automation-control setup did not verify PowerShell.'
        Add-Check (-not ($automationControlCommands -match '/var/run/docker\.sock')) 'Automation-control setup exposed the orchestration Docker socket.'
        Add-Check ($automationControlCommands -match 'compose.*--project-name.*self-hosted-runner-automation-control.*up') 'Automation-control setup did not start its isolated Compose project.'
        & $fixtureSetup -Profile automation-control -Down
        $env:PITCREW_TEST_MANAGER_RUNNING = '1'

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup -Profile copilot-cli -Down
        $namedDownCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($namedDownCommands -match 'compose.*--project-name.*self-hosted-runner-copilot-cli.*down') 'Named teardown did not target its Compose project.'
        Add-Check ($namedDownCommands -match 'ps.*label=ephemeral-managed-runner-profile=copilot-cli') 'Named teardown did not target its exact Docker label.'
        Add-Check (-not ($namedDownCommands | Where-Object { $_ -match '(^|\t)label=ephemeral-managed-runner$' })) 'Named teardown targeted the legacy global Docker label.'
        Add-Check (-not ($namedDownCommands -match 'name=')) 'Named teardown used a broad container-name filter.'

        $env:PITCREW_TEST_MANAGER_RUNNING = '0'
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -Profile android-emulator `
            -Token 'test-registration-token' `
            -Repos 'https://github.com/example/mobile-project=1'
        $androidStatePath = Join-Path $fixtureRoot '.env.android-emulator'
        $androidState = Get-Content -LiteralPath $androidStatePath -Raw -Encoding UTF8
        $androidCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($androidState -match '(?m)^PITCREW_WORKER_RUNTIME_DEVICES=kvm$') 'Android setup did not persist typed KVM access.'
        Add-Check ($androidState -match '(?m)^PITCREW_WORKER_SHM_SIZE_BYTES=2147483648$') 'Android setup did not persist canonical shared memory.'
        Add-Check ($androidCommands -match "--device`t/dev/kvm:/dev/kvm:rwm") 'Android image verification did not receive typed KVM access.'
        Add-Check ($androidCommands -match "--shm-size`t2147483648") 'Android image verification did not receive bounded shared memory.'
        Add-Check (-not ($androidCommands -match '--privileged')) 'Android setup emitted blanket Docker privilege.'
        Add-Check (-not ($androidCommands -match '/var/run/docker\.sock')) 'Android setup exposed the orchestration Docker socket.'
        & $fixtureSetup -Profile android-emulator -Down

        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        & $fixtureSetup `
            -Profile image-builder `
            -Token 'test-registration-token' `
            -Repos 'https://github.com/example/image-project=2'
        $imageBuilderStatePath = Join-Path $fixtureRoot '.env.image-builder'
        $imageBuilderState = Get-Content -LiteralPath $imageBuilderStatePath -Raw -Encoding UTF8
        $imageBuilderCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($imageBuilderState -match '(?m)^PITCREW_SERVICE_NETWORK=pitcrew-image-builder$') 'Image-builder setup did not persist its isolated service network.'
        Add-Check ($imageBuilderCommands -match "--network`tpitcrew-image-builder") 'Image-builder verification did not join the isolated service network.'
        Add-Check ($imageBuilderCommands -match 'buildctl --version') 'Image-builder setup did not verify the pinned BuildKit client.'
        Add-Check (-not ($imageBuilderCommands -match '/var/run/docker\.sock')) 'Image-builder setup exposed the orchestration Docker socket.'
        & $fixtureSetup -Profile image-builder -Down
        $env:PITCREW_TEST_MANAGER_RUNNING = '1'

        $defaultStateDirectory = Split-Path -Parent $defaultDesiredPath
        $defaultObservedPath = Join-Path $defaultStateDirectory 'observed-state.json'
        $defaultShutdownPath = Join-Path $defaultStateDirectory 'manager-shutdown.json'
        $postObservedPath = Join-Path $tempRoot 'post-observed-state.json'
        $env:PITCREW_TEST_POST_OBSERVED_TARGET = $defaultObservedPath

        function Reset-TestRecoveryState {
            param(
                [AllowEmptyString()]
                [string]$PreAutoscalingStatus = ''
            )

            Set-TestObservedState `
                -Path $defaultObservedPath `
                -InstanceId 'manager-instance-a' `
                -Generation 5 `
                -DesiredStateHash 'hash-5' `
                -ManagerStatus 'running' `
                -ObservedAt '2026-01-01T00:00:00Z' `
                -DesiredSlots 2 `
                -ActiveSlots 2 `
                -EligibleSlots 0 `
                -AutoscalingStatus $PreAutoscalingStatus
            $env:PITCREW_TEST_WORKER_IDS = 'worker-alpha,worker-beta'
            Remove-Item -LiteralPath $defaultShutdownPath -Force -ErrorAction SilentlyContinue
            Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        }

        function Test-TestRecoveryTouchedForbiddenSurface {
            param([string[]]$Commands)

            foreach ($command in $Commands) {
                $tokens = @($command -split "`t")
                if ($tokens[0] -in @(
                        'compose', 'build', 'pull', 'system', 'rm', 'kill',
                        'exec', 'stop', 'start', 'update', 'tag', 'run')) {
                    return $true
                }
                if ($tokens[0] -ne 'ps' -and ($command -match 'ephemeral-managed-runner')) {
                    return $true
                }
                if ($command -match 'worker-alpha|worker-beta') {
                    return $true
                }
            }
            return $false
        }

        Reset-TestRecoveryState
        Set-TestObservedState `
            -Path $postObservedPath `
            -InstanceId 'manager-instance-b' `
            -Generation 5 `
            -DesiredStateHash 'hash-5' `
            -ManagerStatus 'running' `
            -ObservedAt '2026-01-01T00:05:00Z' `
            -DesiredSlots 2 `
            -ActiveSlots 2 `
            -EligibleSlots 2 `
            -AutoscalingStatus ''
        $env:PITCREW_TEST_POST_OBSERVED_SOURCE = $postObservedPath
        $desiredCapacityBeforeRecovery = Get-Content `
            -LiteralPath $defaultDesiredPath `
            -Raw `
            -Encoding UTF8
        $recoverOutput = (
            & $fixtureSetup `
                -RecoverManager `
                -ExpectedManagerInstanceId 'manager-instance-a' `
                -ExpectedGeneration 5 `
                -ExpectedDesiredStateHash 'hash-5' `
                -RecoveryTimeoutSeconds 5 *>&1
        ) | Out-String
        $recoverCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        $restartCommands = @($recoverCommands | Where-Object { $_ -match '^restart(\t|$)' })
        Add-Check ($recoverOutput -match 'result: recovered') 'A fixed profile with matching fences was not recovered.'
        Add-Check ($restartCommands.Count -eq 1) 'Manager recovery did not issue exactly one restart.'
        Add-Check (
            $restartCommands.Count -eq 1 -and
            $restartCommands[0] -eq "restart`t--time`t60`tmanager-container-id"
        ) 'Manager recovery did not restart the exact manager container with the 60 second stop window.'
        Add-Check (
            $recoverCommands -match 'ps.*label=ephemeral-runner-manager-profile=default'
        ) 'Manager recovery did not select the manager by its exact label.'
        Add-Check (
            -not (Test-TestRecoveryTouchedForbiddenSurface -Commands $recoverCommands)
        ) 'Manager recovery ran Compose, image, cleanup, or worker-directed Docker commands.'
        Add-Check (
            $recoverOutput -match '"workersBefore":\["worker-alpha","worker-beta"\]'
        ) 'Manager recovery did not report the labelled workers observed before the restart.'
        Add-Check (
            $recoverOutput -match '"workersPreserved":\["worker-alpha","worker-beta"\]'
        ) 'Manager recovery did not report preserved workers.'
        Add-Check (
            (Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8) -eq
                $desiredCapacityBeforeRecovery
        ) 'Manager recovery changed desired capacity.'
        Add-Check (
            $recoverOutput -notmatch 'test-registration-token|ACCESS_TOKEN'
        ) 'Manager recovery disclosed registration credentials.'

        Reset-TestRecoveryState -PreAutoscalingStatus 'degraded'
        Set-TestObservedState `
            -Path $postObservedPath `
            -InstanceId 'manager-instance-b' `
            -Generation 5 `
            -DesiredStateHash 'hash-5' `
            -ManagerStatus 'running' `
            -ObservedAt '2026-01-01T00:05:00Z' `
            -DesiredSlots 2 `
            -ActiveSlots 2 `
            -EligibleSlots 0 `
            -AutoscalingStatus 'running'
        $autoscaledRecoverOutput = (
            & $fixtureSetup `
                -RecoverManager `
                -ExpectedManagerInstanceId 'manager-instance-a' `
                -ExpectedGeneration 5 `
                -ExpectedDesiredStateHash 'hash-5' `
                -RecoveryTimeoutSeconds 5 *>&1
        ) | Out-String
        Add-Check (
            $autoscaledRecoverOutput -match 'result: recovered' -and
            $autoscaledRecoverOutput -match '"mode":"autoscaled"'
        ) 'An autoscaled profile did not use the same recovery entry point and listener postcondition.'

        Reset-TestRecoveryState -PreAutoscalingStatus 'degraded'
        Set-TestObservedState `
            -Path $postObservedPath `
            -InstanceId 'manager-instance-b' `
            -Generation 5 `
            -DesiredStateHash 'hash-5' `
            -ManagerStatus 'running' `
            -ObservedAt '2026-01-01T00:05:00Z' `
            -DesiredSlots 2 `
            -ActiveSlots 2 `
            -EligibleSlots 2 `
            -AutoscalingStatus 'degraded'
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -RecoverManager `
                    -ExpectedManagerInstanceId 'manager-instance-a' `
                    -ExpectedGeneration 5 `
                    -ExpectedDesiredStateHash 'hash-5' `
                    -RecoveryTimeoutSeconds 2
            } `
            -ExpectedMessage "reported 'still-degraded'" `
            -Failure 'A returning autoscaled manager with a degraded listener was reported as recovered.'

        Reset-TestRecoveryState
        Set-TestObservedState `
            -Path $postObservedPath `
            -InstanceId 'manager-instance-b' `
            -Generation 5 `
            -DesiredStateHash 'hash-5' `
            -ManagerStatus 'running' `
            -ObservedAt '2026-01-01T00:05:00Z' `
            -DesiredSlots 2 `
            -ActiveSlots 2 `
            -EligibleSlots 0 `
            -AutoscalingStatus ''
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -RecoverManager `
                    -ExpectedManagerInstanceId 'manager-instance-a' `
                    -ExpectedGeneration 5 `
                    -ExpectedDesiredStateHash 'hash-5' `
                    -RecoveryTimeoutSeconds 2
            } `
            -ExpectedMessage "reported 'still-degraded'" `
            -Failure 'A fixed profile whose registrations never reconciled was reported as recovered.'

        Reset-TestRecoveryState
        Set-TestObservedState `
            -Path $postObservedPath `
            -InstanceId 'manager-instance-a' `
            -Generation 5 `
            -DesiredStateHash 'hash-5' `
            -ManagerStatus 'running' `
            -ObservedAt '2026-01-01T00:05:00Z' `
            -DesiredSlots 2 `
            -ActiveSlots 2 `
            -EligibleSlots 2 `
            -AutoscalingStatus ''
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -RecoverManager `
                    -ExpectedManagerInstanceId 'manager-instance-a' `
                    -ExpectedGeneration 5 `
                    -ExpectedDesiredStateHash 'hash-5' `
                    -RecoveryTimeoutSeconds 2
            } `
            -ExpectedMessage "reported 'failed'" `
            -Failure 'An unchanged manager instance was accepted as a successful recovery.'
        $unchangedInstanceCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (
            @($unchangedInstanceCommands | Where-Object { $_ -match '^restart(\t|$)' }).Count -eq 1
        ) 'Manager recovery retried the restart after an unchanged manager instance.'

        Reset-TestRecoveryState
        $env:PITCREW_TEST_POST_OBSERVED_SOURCE = ''
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -RecoverManager `
                    -ExpectedManagerInstanceId 'manager-instance-a' `
                    -ExpectedGeneration 5 `
                    -ExpectedDesiredStateHash 'hash-5' `
                    -RecoveryTimeoutSeconds 2
            } `
            -ExpectedMessage "reported 'indeterminate'" `
            -Failure 'Observed state that never advanced was not reported as indeterminate.'
        $timeoutCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (
            @($timeoutCommands | Where-Object { $_ -match '^restart(\t|$)' }).Count -eq 1
        ) 'Manager recovery retried the restart after an observed-state timeout.'
        $env:PITCREW_TEST_POST_OBSERVED_SOURCE = $postObservedPath

        Reset-TestRecoveryState
        $env:PITCREW_TEST_RESTART_FAILURE = '1'
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -RecoverManager `
                    -ExpectedManagerInstanceId 'manager-instance-a' `
                    -ExpectedGeneration 5 `
                    -ExpectedDesiredStateHash 'hash-5' `
                    -RecoveryTimeoutSeconds 2
            } `
            -ExpectedMessage "reported 'failed'" `
            -Failure 'A failed Docker restart was not reported as a failed recovery.'
        $restartFailureCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check (
            @($restartFailureCommands | Where-Object { $_ -match '^restart(\t|$)' }).Count -eq 1
        ) 'Manager recovery retried the restart after a Docker failure.'
        Add-Check (
            -not (Test-TestRecoveryTouchedForbiddenSurface -Commands $restartFailureCommands)
        ) 'A failed manager recovery escalated to Compose, cleanup, or worker commands.'
        Remove-Item Env:\PITCREW_TEST_RESTART_FAILURE -ErrorAction SilentlyContinue

        function New-TestRecoveryArguments {
            param([hashtable]$Override)

            $arguments = @{
                ExpectedManagerInstanceId = 'manager-instance-a'
                ExpectedGeneration = 5
                ExpectedDesiredStateHash = 'hash-5'
            }
            foreach ($entry in $Override.GetEnumerator()) {
                $arguments[$entry.Key] = $entry.Value
            }
            return $arguments
        }
        $recoveryRejections = @(
            [PSCustomObject]@{
                Name = 'a missing manager instance fence'
                Arguments = @{ ExpectedGeneration = 5 }
                Setup = { }
                Expected = "reported 'rejected'"
            },
            [PSCustomObject]@{
                Name = 'a missing generation fence'
                Arguments = @{ ExpectedManagerInstanceId = 'manager-instance-a' }
                Setup = { }
                Expected = "reported 'rejected'"
            },
            [PSCustomObject]@{
                Name = 'a stale manager instance'
                Arguments = New-TestRecoveryArguments -Override @{ ExpectedManagerInstanceId = 'manager-instance-old' }
                Setup = { }
                Expected = "reported 'rejected'"
            },
            [PSCustomObject]@{
                Name = 'a stale generation'
                Arguments = New-TestRecoveryArguments -Override @{ ExpectedGeneration = 4 }
                Setup = { }
                Expected = "reported 'rejected'"
            },
            [PSCustomObject]@{
                Name = 'a stale desired-state hash'
                Arguments = New-TestRecoveryArguments -Override @{ ExpectedDesiredStateHash = 'hash-4' }
                Setup = { }
                Expected = "reported 'rejected'"
            },
            [PSCustomObject]@{
                Name = 'a pending explicit shutdown request'
                Arguments = New-TestRecoveryArguments -Override @{ }
                Setup = {
                    '{"schemaVersion":1}' |
                        Set-Content -LiteralPath $defaultShutdownPath -Encoding UTF8
                }
                Expected = "reported 'rejected'"
            },
            [PSCustomObject]@{
                Name = 'no running manager'
                Arguments = New-TestRecoveryArguments -Override @{ }
                Setup = { $env:PITCREW_TEST_MANAGER_RUNNING = '0' }
                Expected = "reported 'rejected'"
            },
            [PSCustomObject]@{
                Name = 'multiple matching managers'
                Arguments = New-TestRecoveryArguments -Override @{ }
                Setup = { $env:PITCREW_TEST_MANAGER_EXTRA_ID = 'manager-container-id-2' }
                Expected = "reported 'rejected'"
            },
            [PSCustomObject]@{
                Name = 'a legacy manager contract'
                Arguments = New-TestRecoveryArguments -Override @{ }
                Setup = { $env:PITCREW_TEST_MANAGER_CONTRACT = '8' }
                Expected = "reported 'rejected'"
            },
            [PSCustomObject]@{
                Name = 'a capacity mutation'
                Arguments = New-TestRecoveryArguments -Override @{ Replicas = 4 }
                Setup = { }
                Expected = 'never changes configuration, capacity, or credentials'
            },
            [PSCustomObject]@{
                Name = 'a supplied registration token'
                Arguments = New-TestRecoveryArguments -Override @{ Token = 'test-registration-token' }
                Setup = { }
                Expected = 'never changes configuration, capacity, or credentials'
            },
            [PSCustomObject]@{
                Name = 'a combined teardown'
                Arguments = New-TestRecoveryArguments -Override @{ Down = $true }
                Setup = { }
                Expected = 'cannot be combined with'
            }
        )
        foreach ($rejection in $recoveryRejections) {
            Reset-TestRecoveryState
            & $rejection.Setup
            $rejectionArguments = @{
                RecoverManager = $true
                RecoveryTimeoutSeconds = 2
            }
            foreach ($entry in $rejection.Arguments.GetEnumerator()) {
                $rejectionArguments[$entry.Key] = $entry.Value
            }
            Add-ThrowsCheck `
                -Action { & $fixtureSetup @rejectionArguments } `
                -ExpectedMessage ([regex]::Escape($rejection.Expected)) `
                -Failure "Manager recovery accepted $($rejection.Name)."
            $rejectionCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
            Add-Check (
                @($rejectionCommands | Where-Object { $_ -match '^restart(\t|$)' }).Count -eq 0
            ) "Manager recovery restarted a manager despite $($rejection.Name)."
            Add-Check (
                -not (Test-TestRecoveryTouchedForbiddenSurface -Commands $rejectionCommands)
            ) "A rejected manager recovery ran Compose, cleanup, or worker commands for $($rejection.Name)."
            $env:PITCREW_TEST_MANAGER_RUNNING = '1'
            Remove-Item Env:\PITCREW_TEST_MANAGER_EXTRA_ID -ErrorAction SilentlyContinue
            Remove-Item Env:\PITCREW_TEST_MANAGER_CONTRACT -ErrorAction SilentlyContinue
        }

        Remove-Item Env:\PITCREW_TEST_WORKER_IDS -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_POST_OBSERVED_SOURCE -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_POST_OBSERVED_TARGET -ErrorAction SilentlyContinue

        $beforePause = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-ThrowsCheck `
            -Action {
                & $fixtureSetup `
                    -Token 'test-registration-token' `
                    -Autoscale `
                    -MinimumIdle 0 `
                    -ScaleDownDelaySeconds 120 `
                    -Pause `
                    -Repos 'https://github.com/example/project=1'
            } `
            -ExpectedMessage 'uses the existing desired-capacity targets' `
            -Failure 'Pause accepted an explicit replacement capacity target.'
        $pauseGeneration = [int]$beforePause.generation + 1
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        $env:PITCREW_TEST_REJECT_TOKEN = 'test-registration-token'
        $pauseAcknowledgement = Start-TestCapacityAcknowledgementWriter `
            -DesiredPath $defaultDesiredPath `
            -AcknowledgementPath $defaultAcknowledgementPath `
            -Generation $pauseGeneration `
            -DesiredSlots 0 `
            -AddedSlots 0 `
            -DrainingSlots 1 `
            -UnchangedSlots 0 `
            -WaitForAcknowledgementRemoval 0
        $pauseFailure = $null
        try {
            & $fixtureSetup `
                -Token 'test-registration-token' `
                -Autoscale `
                -MinimumIdle 0 `
                -ScaleDownDelaySeconds 120 `
                -Pause
        }
        catch {
            $pauseFailure = $_
        }
        finally {
            if ($pauseFailure) {
                Stop-Job -Job $pauseAcknowledgement
            } else {
                Wait-Job -Job $pauseAcknowledgement -Timeout 65 | Out-Null
                Receive-Job -Job $pauseAcknowledgement -ErrorAction Stop | Out-Null
            }
            Remove-Job -Job $pauseAcknowledgement -Force
        }
        if ($pauseFailure) {
            throw $pauseFailure
        }
        Remove-Item Env:\PITCREW_TEST_REJECT_TOKEN -ErrorAction SilentlyContinue
        $pauseCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        $pausedState = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-Check ($pausedState.generation -eq $pauseGeneration) 'Pause did not advance desired-capacity generation.'
        Add-Check ($pausedState.repositories.Count -eq 1) 'Pause removed the existing repository target.'
        Add-Check ($pausedState.repositories[0].workers -eq 0) 'Pause did not set effective capacity to zero.'
        Add-Check (-not ($pauseCommands -match 'compose.*down')) 'Pause restarted or tore down the manager.'
        Add-Check (-not ($pauseCommands -match 'rm.*-f')) 'Pause force-removed a busy worker.'

        $resumeGeneration = $pauseGeneration + 1
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        $resumeAcknowledgement = Start-TestCapacityAcknowledgementWriter `
            -DesiredPath $defaultDesiredPath `
            -AcknowledgementPath $defaultAcknowledgementPath `
            -Generation $resumeGeneration `
            -DesiredSlots 1 `
            -AddedSlots 1 `
            -DrainingSlots 0 `
            -UnchangedSlots 0 `
            -WaitForAcknowledgementRemoval 0
        $resumeFailure = $null
        try {
            & $fixtureSetup `
                -Token 'test-registration-token' `
                -Autoscale `
                -MinimumIdle 0 `
                -ScaleDownDelaySeconds 120 `
                -CapacityOnly `
                -AddRepos 'https://github.com/example/project=1'
        }
        catch {
            $resumeFailure = $_
        }
        finally {
            if ($resumeFailure) {
                Stop-Job -Job $resumeAcknowledgement
            } else {
                Wait-Job -Job $resumeAcknowledgement -Timeout 65 | Out-Null
                Receive-Job -Job $resumeAcknowledgement -ErrorAction Stop | Out-Null
            }
            Remove-Job -Job $resumeAcknowledgement -Force
        }
        if ($resumeFailure) {
            throw $resumeFailure
        }
        $resumedState = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-Check ($resumedState.generation -eq $resumeGeneration) 'Resume did not advance desired-capacity generation.'
        Add-Check ($resumedState.repositories[0].workers -eq 1) 'Resume did not restore positive capacity.'

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
        Remove-Item Env:\PITCREW_TEST_IMAGE_RUN_FAILURE -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_IMAGE_RUN_FAILURE_USED -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_IMAGE_ROLLBACK_ID -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_IMAGE_ROLLBACK_MISSING -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_START_FAILURE -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_START_FAILURE_USED -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_WORKER_IDS -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_POST_WORKER_IDS -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_POST_OBSERVED_SOURCE -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_POST_OBSERVED_TARGET -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_RESTART_FAILURE -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_EXTRA_ID -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_CONTRACT -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$manager = Get-Content -LiteralPath $managerPath -Raw -Encoding UTF8
$managerEntrypoint = Get-Content -LiteralPath $managerEntrypointPath -Raw -Encoding UTF8
$autoscalerModule = Get-Content -LiteralPath $autoscalerModulePath -Raw -Encoding UTF8
$autoscalerHardware = Get-Content -LiteralPath $autoscalerHardwarePath -Raw -Encoding UTF8
$managerDockerfile = Get-Content -LiteralPath $managerDockerfilePath -Raw -Encoding UTF8
$setupSource = Get-Content -LiteralPath $setupPath -Raw -Encoding UTF8
$functionsSource = Get-Content -LiteralPath $functionsPath -Raw -Encoding UTF8
$observability = Get-Content -LiteralPath $observabilityPath -Raw -Encoding UTF8
$diagnostics = Get-Content -LiteralPath $diagnosticsPath -Raw -Encoding UTF8
$compose = Get-Content -LiteralPath $composePath -Raw -Encoding UTF8
$hostAdmissionCompose = Get-Content `
    -LiteralPath $hostAdmissionComposePath `
    -Raw `
    -Encoding UTF8
$hostAdmissionManagerCompose = Get-Content `
    -LiteralPath $hostAdmissionManagerComposePath `
    -Raw `
    -Encoding UTF8
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
Add-Check ($manager -match [regex]::Escape('consume_slot_connect_marker "${slot_state_path}"')) 'Manager recovery still promotes an adopted worker from worker output produced before adoption.'
Add-Check ($manager -match [regex]::Escape('slot_connect_marker_is_pending "${monitored_slot_path}"')) 'Worker output can promote a slot whose connect marker was already consumed.'
Add-Check ($manager -notmatch [regex]::Escape('rm -f "${slot_state_path}/connected"')) 'The connect-marker transition is still opened outside a fresh worker launch.'
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
Add-Check (
    $hostAdmissionCompose -match '(?m)^  admission-coordinator:\r?$' -and
    $hostAdmissionCompose -match
        [regex]::Escape('/usr/local/bin/pitcrew-admission') -and
    $hostAdmissionCompose -match
        [regex]::Escape('/var/lib/pitcrew-admission/coordinator.sock') -and
    $hostAdmissionCompose -match
        'pitcrew-host-admission-namespace: \$\{PITCREW_HOST_ADMISSION_NAMESPACE\}' -and
    ([regex]::Matches(
        $hostAdmissionCompose,
        'pitcrew-host-admission-namespace: \$\{PITCREW_HOST_ADMISSION_NAMESPACE\}'
    )).Count -eq 2 -and
    $hostAdmissionCompose -match '(?m)^    network_mode: none\r?$' -and
    $hostAdmissionCompose -notmatch 'docker\.sock|ports:'
) 'The admission service Compose contract exposes Docker or a host port, or omits exact identity.'
Add-Check (
    $hostAdmissionManagerCompose -match
        'external:\s+true' -and
    $hostAdmissionManagerCompose -match
        [regex]::Escape('PITCREW_HOST_ADMISSION_SOCKET') -and
    $hostAdmissionManagerCompose -match
        [regex]::Escape('host-admission-state:/var/lib/pitcrew-admission') -and
    $hostAdmissionManagerCompose -notmatch 'docker\.sock'
) 'The manager admission override does not mount only the external internal-state volume.'
Add-Check (
    $setupSource -match
        '(?s)function Invoke-RunnerHostAdmissionCompose.*?hostAdmissionComposeEnvironmentNames.*?Remove-Item.*?finally.*?Set-Item' -and
    $setupSource -match
        [regex]::Escape('Get-RunnerHostAdmissionServicePolicySignature -Policy $status.policy')
) 'Host-admission Compose or acknowledgement handling is vulnerable to ambient environment or raw JSON ordering.'
Add-Check (
    $setupSource -match
        '(?s)Publish-RunnerHostAdmissionPolicy.*?begin-adoption.*?Stop-RunnerManagerForHandoff'
) 'Setup does not establish the durable host-wide adoption fence before manager handoff.'
Add-Check (
    $setupSource -match
        [regex]::Escape(
            'Get-RunnerManagerAcknowledgementTimeoutSeconds') -and
    $setupSource -match
        'replacement manager remains running' -and
    $setupSource -match
        '(?s)Failed to restore the previous manager image tag.*?Remove-Item.*?CapacityAcknowledgementPath.*?Wait-RunnerCapacityAcknowledgement'
) 'Manager handoff does not preserve a running replacement or verify rollback acknowledgement.'
Add-Check ($manager -match [regex]::Escape('diagnostics_initialize "${DIAGNOSTICS_DIRECTORY}"')) 'The fixed manager does not restore its durable operation journal.'
Add-Check ($manager -match [regex]::Escape('record_manager_diagnostic')) 'The fixed manager does not record operation evidence.'
Add-Check ($manager -match [regex]::Escape('render_fixed_capacity_evidence')) 'The fixed manager does not publish capacity-deficit evidence.'
$diagnosticAttributionPattern = (
    [regex]::Escape('"${DIAGNOSTICS_DIRECTORY}" \') +
    '\r?\n\s*' +
    [regex]::Escape('"${MANAGER_INSTANCE_ID}" \')
)
Add-Check ($manager -match $diagnosticAttributionPattern) 'Recorded operation evidence is not attributed to the observing manager instance.'
Add-Check ($manager -match [regex]::Escape('DIAGNOSTICS_DIRECTORY="${STATE_DIRECTORY}/diagnostics"')) 'The operation journal is not persisted in the profile state directory.'
Add-Check (
    $manager -match 'PITCREW_READ_ONLY_VOLUMES' -and
    $manager -match 'docker volume inspect' -and
    $manager -match 'type=volume,src=\$\{volume_source\},dst=/mnt/pitcrew-data/\$\{volume_name\},readonly,volume-nocopy'
) 'The fixed manager does not validate and mount external volumes read-only.'
Add-Check (
    $manager -match 'PITCREW_SERVICE_NETWORK' -and
    $manager -match 'docker network inspect' -and
    $manager -match [regex]::Escape('set -- "$@" --network "${SERVICE_NETWORK}"')
) 'The fixed manager does not validate and attach the external service network.'
Add-Check (
    $manager -match [regex]::Escape('HOST_HARDWARE_PATH="${STATE_DIRECTORY}/host-hardware.json"') -and
    $manager -match [regex]::Escape('collect_host_hardware') -and
    $observability -match [regex]::Escape('host_hardware_inventory_is_valid') -and
    $observability -match [regex]::Escape('inventoryHash')
) 'The fixed manager does not retain bounded sanitized host hardware inventory.'
$hardwareDefaultPathAssignment = 'observed_hardware_path="${HOST_HARDWARE_PATH}"'
$hardwareFallbackPathAssignment = 'observed_hardware_path="${HOST_HARDWARE_FALLBACK_PATH}"'
$hardwareObservedArgument = '"${observed_hardware_path}"'
$hardwareDefaultIndex = $manager.IndexOf($hardwareDefaultPathAssignment)
$hardwareFallbackIndex = $manager.IndexOf($hardwareFallbackPathAssignment)
$hardwareObservedArgumentIndex = $manager.LastIndexOf($hardwareObservedArgument)
Add-Check (
    $hardwareDefaultIndex -ge 0 -and
    $hardwareDefaultIndex -eq $manager.LastIndexOf($hardwareDefaultPathAssignment) -and
    $hardwareDefaultIndex -lt $hardwareFallbackIndex -and
    $hardwareFallbackIndex -lt $hardwareObservedArgumentIndex
) 'The fixed manager resets a stale hardware fallback before observed-state publication.'
Add-Check (
    $autoscalerHardware -match [regex]::Escape('hostHardwareInventoryInterval') -and
    $autoscalerHardware -match [regex]::Escape('reconcileHostHardwareInventory') -and
    $autoscalerHardware -match [regex]::Escape('DockerBackingFilesystem') -and
    $autoscalerHardware -notmatch 'DockerRootDir|Serial|MachineGuid|MACAddress'
) 'The autoscaler does not publish the sanitized hardware contract safely.'
Add-Check ($diagnostics -match [regex]::Escape('DIAGNOSTIC_JOURNAL_MAXIMUM_BYTES=16384')) 'The operation journal does not bound its serialized size.'
Add-Check ($diagnostics -match [regex]::Escape('sanitize_diagnostic_evidence')) 'Operation evidence is not sanitized before publication.'
Add-Check ($diagnostics -match [regex]::Escape('mv -f "${append_temporary}" "${append_path}"')) 'The operation journal is not persisted atomically.'
Add-Check (
    $functionsSource -match [regex]::Escape(
        '$temporaryPath = Join-Path $directory') -and
    $functionsSource -match [regex]::Escape(
        '[IO.UnixFileMode]::GroupRead')
) 'PowerShell state publication does not preserve directory-inherited broker reads.'
Add-Check (
    $manager -match [regex]::Escape(
        'chmod 0644 "${acknowledgement_temporary}"') -and
    $observability -match [regex]::Escape(
        'chmod 0644 "${observed_temporary}"')
) 'Fixed-manager state publication does not retain broker-readable file mode.'
Add-Check ($managerDockerfile -match [regex]::Escape('COPY diagnostics.sh /usr/local/bin/diagnostics.sh')) 'The manager image does not ship the operation diagnostics helper.'
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
Add-Check ($compose -match [regex]::Escape('PITCREW_READ_ONLY_VOLUMES: ${PITCREW_READ_ONLY_VOLUMES:-}')) 'Compose does not pass the read-only volume contract to the manager.'
Add-Check ($compose -match [regex]::Escape('PITCREW_SERVICE_NETWORK: ${PITCREW_SERVICE_NETWORK:-}')) 'Compose does not pass the external service network contract to the manager.'
Add-Check ($compose -match [regex]::Escape('PITCREW_WORKER_RUNTIME_DEVICES: ${PITCREW_WORKER_RUNTIME_DEVICES:-}')) 'Compose does not pass the typed worker-device contract to the manager.'
Add-Check ($compose -match [regex]::Escape('PITCREW_WORKER_SHM_SIZE_BYTES: ${PITCREW_WORKER_SHM_SIZE_BYTES:-}')) 'Compose does not pass the shared-memory contract to the manager.'
Add-Check ($compose -match [regex]::Escape('PITCREW_SESSION_OWNER: ${PITCREW_SESSION_OWNER:-}')) 'Compose does not pass the stable scale-set session owner.'
Add-Check ($compose -match [regex]::Escape('pitcrew-manager-contract-version: ${PITCREW_MANAGER_CONTRACT_VERSION:-18}')) 'Manager containers do not expose their handoff contract.'
Add-Check ($compose -match [regex]::Escape('PITCREW_HOST_PROC_PATH: /host/proc')) 'Manager containers do not use the fixed host-proc telemetry path.'
Add-Check ($compose -match [regex]::Escape('/proc:/host/proc:ro')) 'Manager containers do not mount Docker-host proc read-only.'
Add-Check ($compose -notmatch '/var/run/docker\.sock:.+runner') 'Compose appears to expose the Docker socket to a runner service.'
Add-Check ($compose -notmatch '/host/proc:.+runner') 'Compose appears to expose Docker-host proc to a runner service.'
Add-Check ($exampleEnvironment -match '(?m)^PITCREW_MANAGER_CONTRACT_VERSION=18$') 'The example environment does not pin the current manager contract.'
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
