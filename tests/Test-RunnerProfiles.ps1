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
$copilotProfilePath = Join-Path $runnerRoot 'profiles' 'copilot-cli' 'profile.json'
$copilotDockerfilePath = Join-Path $runnerRoot 'profiles' 'copilot-cli' 'Dockerfile'
$managerPath = Join-Path $runnerRoot 'manager' 'manage-runners.sh'
$managerDockerfilePath = Join-Path $runnerRoot 'manager' 'Dockerfile'
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
        [int]$UnchangedSlots,
        [int]$ManagerContractVersion = 7
    )

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
        [int]$ManagerContractVersion = 7
    )

    return Start-Job -ArgumentList @(
        $DesiredPath,
        $AcknowledgementPath,
        $Generation,
        $DesiredSlots,
        $AddedSlots,
        $DrainingSlots,
        $UnchangedSlots,
        $ManagerContractVersion
    ) -ScriptBlock {
        param(
            $DesiredPath,
            $AcknowledgementPath,
            $Generation,
            $DesiredSlots,
            $AddedSlots,
            $DrainingSlots,
            $UnchangedSlots,
            $ManagerContractVersion
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
                    Start-Sleep -Milliseconds 50
                }
            }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)

        throw "Desired generation $Generation was not observed."
    }
}

function Start-TestDrainCompleteWriter {
    param(
        [string]$DrainRequestPath,
        [string]$DrainCompletePath
    )

    # Simulate a cooperative (contract v7+) manager: watch for the nonce'd
    # drain-request Setup writes, then stamp drain-complete echoing the same
    # nonce. This is the responder Invoke-RunnerDrainAndFence polls for, so a
    # destructive/static replacement or contract upgrade can proceed only after
    # the manager confirms the pool is fenced and idle.
    return Start-Job -ArgumentList @(
        $DrainRequestPath,
        $DrainCompletePath
    ) -ScriptBlock {
        param(
            $DrainRequestPath,
            $DrainCompletePath
        )

        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        do {
            if (Test-Path -LiteralPath $DrainRequestPath -PathType Leaf) {
                try {
                    $request = Get-Content -LiteralPath $DrainRequestPath -Raw -Encoding UTF8 |
                        ConvertFrom-Json -Depth 10 -ErrorAction Stop
                    $nonce = [string]$request.nonce
                    if ($nonce) {
                        $payload = [PSCustomObject][ordered]@{
                            schemaVersion = 1
                            nonce = $nonce
                        } | ConvertTo-Json -Depth 10
                        $temporary = "$DrainCompletePath.tmp"
                        Set-Content -LiteralPath $temporary -Value $payload -Encoding UTF8 -NoNewline
                        Move-Item -LiteralPath $temporary -Destination $DrainCompletePath -Force
                        return
                    }
                } catch {
                    Start-Sleep -Milliseconds 50
                }
            }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)

        throw "No drain-request nonce was observed at $DrainRequestPath."
    }
}

$requiredPaths = @(
    $functionsPath,
    $setupPath,
    $schemaPath,
    $copilotProfilePath,
    $copilotDockerfilePath,
    $managerPath,
    $managerDockerfilePath,
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
Add-Check ($defaultProfile.ManagerContractVersion -eq 7) 'The setup contract does not identify the observed-state manager.'
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
Add-Check (
    $defaultStaticProfile.fingerprint -eq $replicaOverrideStaticProfile.fingerprint
) 'Mutable capacity is included in the static profile fingerprint.'
Add-Check (
    $defaultStaticProfile.fingerprint -ne $imageOverrideStaticProfile.fingerprint
) 'Worker image changes do not select full profile replacement.'
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
    -AccessToken 'test-registration-token'
$copilotEnvironment = New-RunnerEnvironmentContent `
    -Profile $copilotProfile `
    -AccessToken 'test-registration-token'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_PROFILE_ID=default$') 'The default environment does not identify its profile.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_LABELS=general-purpose$') 'The default environment does not emit the general-purpose label.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_NO_DEFAULT_LABELS=$') 'The default environment unexpectedly disables GitHub default labels.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_PULL_IMAGE=0$') 'Generated default state permits a second image pull after preparation.'
Add-Check ($defaultEnvironment -notmatch '(?m)^(REPO_URLS|RUNNER_REPLICAS)=') 'Mutable capacity remains embedded in the static environment.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_STATE_DIR=\.pitcrew-state/default$') 'The default environment does not mount its mutable state directory.'
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_MANAGER_CONTRACT_VERSION=7$') 'The environment does not pin the manager reconciliation contract.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_PROFILE_ID=copilot-cli$') 'The specialized environment does not identify its profile.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_NO_DEFAULT_LABELS=1$') 'The specialized environment does not disable GitHub default labels.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_PULL_IMAGE=0$') 'The specialized environment does not protect its locally built image.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_MEMORY_LIMIT=$') 'The default environment does not emit an unset per-runner memory limit.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_MEMORY_SWAP_LIMIT=$') 'The default environment does not emit an unset per-runner memory-swap limit.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_CPU_LIMIT=$') 'The default environment does not emit an unset per-runner CPU limit.'
Add-Check ($defaultEnvironment -match '(?m)^RUNNER_PIDS_LIMIT=$') 'The default environment does not emit an unset per-runner PID limit.'

# Issue #8 follow-up (1): upgrading a profile that was provisioned before the
# optional per-runner resource-limit knobs existed must NOT be misdetected as
# environment drift. Setup compares the on-disk .env to freshly generated
# content to decide whether to destructively stop/replace the active pool; the
# migration normalizer treats an absent limit line and an unset (empty) limit
# line as equivalent so a mere tooling upgrade never tears down healthy runners.
$legacyDefaultEnvironment = (
    $defaultEnvironment -split "`n" |
        Where-Object { $_ -notmatch '^RUNNER_(MEMORY_LIMIT|MEMORY_SWAP_LIMIT|CPU_LIMIT|PIDS_LIMIT)=' }
) -join "`n"
Add-Check ($legacyDefaultEnvironment -cne $defaultEnvironment) 'The legacy environment fixture is identical to current output, so the upgrade-drift test is not exercising the migration path.'
Add-Check (
    (ConvertTo-RunnerEnvironmentComparable -Content $legacyDefaultEnvironment) -ceq
    (ConvertTo-RunnerEnvironmentComparable -Content $defaultEnvironment)
) 'Upgrading a pre-limits profile with limits unset is treated as environment drift, which would destructively replace an active runner pool.'
Add-Check (
    (ConvertTo-RunnerEnvironmentComparable -Content $defaultEnvironment) -notmatch '(?m)^RUNNER_MEMORY_LIMIT=$'
) 'The environment comparison normalizer did not drop an unset per-runner memory limit line.'
$limitedDefaultEnvironment = $defaultEnvironment -replace '(?m)^RUNNER_MEMORY_LIMIT=$', 'RUNNER_MEMORY_LIMIT=6g'
Add-Check (
    (ConvertTo-RunnerEnvironmentComparable -Content $legacyDefaultEnvironment) -cne
    (ConvertTo-RunnerEnvironmentComparable -Content $limitedDefaultEnvironment)
) 'Setting a real per-runner memory limit is not detected as an environment change, so the manager would never receive the new constraint.'
$setupContent = Get-Content -LiteralPath $setupPath -Raw -Encoding UTF8
Add-Check ($setupContent -match [regex]::Escape('ConvertTo-RunnerEnvironmentComparable')) 'Setup does not normalize the environment before deciding whether to replace the active pool, so an unset-limits upgrade would be misread as drift.'

Add-Check ((ConvertFrom-RunnerByteValue -Value '6g') -eq 6442450944) 'ConvertFrom-RunnerByteValue miscomputed a gibibyte value.'
Add-Check ((ConvertFrom-RunnerByteValue -Value '6m') -eq 6291456) 'ConvertFrom-RunnerByteValue miscomputed a mebibyte value.'
Add-Check ((ConvertFrom-RunnerByteValue -Value '1024k') -eq 1048576) 'ConvertFrom-RunnerByteValue miscomputed a kibibyte value.'
Add-Check ((ConvertFrom-RunnerByteValue -Value '2147483648') -eq 2147483648) 'ConvertFrom-RunnerByteValue miscomputed a bare byte count.'
Add-ThrowsCheck `
    -Action { ConvertFrom-RunnerByteValue -Value '6gb' } `
    -ExpectedMessage 'not a Docker-compatible size' `
    -Failure 'ConvertFrom-RunnerByteValue accepted a malformed size.'

# Issue #8 follow-up (3): enormous byte values must fail loudly instead of
# overflowing Int64 into a lossy Double that slips past the size checks.
Add-Check ((ConvertFrom-RunnerByteValue -Value '6g') -is [long]) 'ConvertFrom-RunnerByteValue must return an exact [long], not a floating-point value.'
Add-ThrowsCheck `
    -Action { ConvertFrom-RunnerByteValue -Value '9999999999g' } `
    -ExpectedMessage "exceeds Docker's maximum" `
    -Failure 'ConvertFrom-RunnerByteValue overflowed an enormous size instead of rejecting it.'

# Issue #8 follow-up (3): CPU limits must be NanoCPU-compatible. Docker
# converts --cpus to whole NanoCPUs (value x 1e9); zero means "unlimited",
# more than nine decimals is "too precise", and huge values overflow Int64.
Add-Check ((ConvertFrom-RunnerCpuValue -Value '4') -eq 4000000000) 'ConvertFrom-RunnerCpuValue miscomputed a whole-core NanoCPU value.'
Add-Check ((ConvertFrom-RunnerCpuValue -Value '1.5') -eq 1500000000) 'ConvertFrom-RunnerCpuValue miscomputed a fractional NanoCPU value.'
Add-Check ((ConvertFrom-RunnerCpuValue -Value '0.5') -eq 500000000) 'ConvertFrom-RunnerCpuValue miscomputed a sub-core NanoCPU value.'
Add-Check ((ConvertFrom-RunnerCpuValue -Value '0.000000001') -eq 1) 'ConvertFrom-RunnerCpuValue rejected the smallest whole NanoCPU (nine decimals) that Docker accepts.'
Add-ThrowsCheck `
    -Action { ConvertFrom-RunnerCpuValue -Value '0' } `
    -ExpectedMessage 'greater than zero' `
    -Failure 'ConvertFrom-RunnerCpuValue accepted a zero cpu limit that Docker treats as unlimited.'
Add-ThrowsCheck `
    -Action { ConvertFrom-RunnerCpuValue -Value '0.0' } `
    -ExpectedMessage 'greater than zero' `
    -Failure 'ConvertFrom-RunnerCpuValue accepted a zero-valued cpu limit that Docker treats as unlimited.'
Add-ThrowsCheck `
    -Action { ConvertFrom-RunnerCpuValue -Value '1.0000000001' } `
    -ExpectedMessage 'too precise' `
    -Failure 'ConvertFrom-RunnerCpuValue accepted a cpu limit finer than one NanoCPU that Docker refuses to parse.'
Add-ThrowsCheck `
    -Action { ConvertFrom-RunnerCpuValue -Value '99999999999' } `
    -ExpectedMessage 'maximum NanoCPU range' `
    -Failure 'ConvertFrom-RunnerCpuValue accepted a cpu limit that overflows Docker NanoCPUs.'

# Issue #8 follow-up (2): a running manager can carry stale baked-in contract
# code (for issue #8, the hardened exit-status capture) even after its .env file
# has already been rewritten with the new contract version. The reconcile
# decision must therefore detect an outdated RUNNING manager and route it to a
# drain-safe coordinated upgrade FIRST, before the capacity-only fast path,
# otherwise a manager "normalized as compatible" would never receive new code.
$contractIgnoringOne = ConvertTo-RunnerEnvironmentComparable `
    -Content "RUNNER_PROFILE_ID=default`nPITCREW_MANAGER_CONTRACT_VERSION=6" `
    -IgnoreManagerContractVersion
$contractIgnoringTwo = ConvertTo-RunnerEnvironmentComparable `
    -Content "RUNNER_PROFILE_ID=default`nPITCREW_MANAGER_CONTRACT_VERSION=7" `
    -IgnoreManagerContractVersion
Add-Check ($contractIgnoringOne -ceq $contractIgnoringTwo) 'The normalizer did not drop the contract-version line, so a pure manager-code upgrade is misread as configuration drift.'
Add-Check ($contractIgnoringOne -notmatch 'PITCREW_MANAGER_CONTRACT_VERSION') 'The contract-ignoring normalizer left the manager contract-version line in place.'
Add-Check (
    (ConvertTo-RunnerEnvironmentComparable -Content "RUNNER_PROFILE_ID=default`nPITCREW_MANAGER_CONTRACT_VERSION=6") -match 'PITCREW_MANAGER_CONTRACT_VERSION=6'
) 'The default normalizer must retain the contract-version line so a genuine version pin is still compared.'

Add-Check (
    (Get-RunnerManagerReconcileAction `
        -ManagerRunning $true `
        -EnvironmentMatches $true `
        -EnvironmentMatchesIgnoringContract $true `
        -StaticProfileMatches $true `
        -HasGeneration $true `
        -RunningContractVersion 6 `
        -DesiredContractVersion 7) -eq 'contract-upgrade'
) 'An outdated running manager whose env already shows the new version is not routed to a coordinated contract upgrade.'
Add-Check (
    (Get-RunnerManagerReconcileAction `
        -ManagerRunning $true `
        -EnvironmentMatches $false `
        -EnvironmentMatchesIgnoringContract $true `
        -StaticProfileMatches $true `
        -HasGeneration $true `
        -RunningContractVersion 6 `
        -DesiredContractVersion 7) -eq 'contract-upgrade'
) 'A manager on old code with only the contract-version line differing is not routed to a coordinated upgrade.'
Add-Check (
    (Get-RunnerManagerReconcileAction `
        -ManagerRunning $true `
        -EnvironmentMatches $true `
        -EnvironmentMatchesIgnoringContract $true `
        -StaticProfileMatches $true `
        -HasGeneration $true `
        -RunningContractVersion 7 `
        -DesiredContractVersion 7) -eq 'capacity-only'
) 'A current, running manager with matching environment is not treated as a capacity-only change.'
Add-Check (
    (Get-RunnerManagerReconcileAction `
        -ManagerRunning $true `
        -EnvironmentMatches $false `
        -EnvironmentMatchesIgnoringContract $false `
        -StaticProfileMatches $true `
        -HasGeneration $true `
        -RunningContractVersion 6 `
        -DesiredContractVersion 7) -eq 'replace'
) 'A real configuration change on an old manager is not routed through the full replace path.'
Add-Check (
    (Get-RunnerManagerReconcileAction `
        -ManagerRunning $false `
        -EnvironmentMatches $true `
        -EnvironmentMatchesIgnoringContract $true `
        -StaticProfileMatches $true `
        -HasGeneration $true `
        -RunningContractVersion 0 `
        -DesiredContractVersion 7) -eq 'replace'
) 'A stopped manager is not routed through the replace path that starts a fresh pool.'
Add-Check (
    (Get-RunnerManagerReconcileAction `
        -ManagerRunning $true `
        -EnvironmentMatches $true `
        -EnvironmentMatchesIgnoringContract $true `
        -StaticProfileMatches $false `
        -HasGeneration $true `
        -RunningContractVersion 6 `
        -DesiredContractVersion 7) -eq 'replace'
) 'A static-profile change is not routed through the replace path even when a contract upgrade is also pending.'
Add-Check (
    (Get-RunnerManagerReconcileAction `
        -ManagerRunning $true `
        -EnvironmentMatches $true `
        -EnvironmentMatchesIgnoringContract $true `
        -StaticProfileMatches $true `
        -HasGeneration $true `
        -RunningContractVersion 0 `
        -DesiredContractVersion 7) -eq 'capacity-only'
) 'A manager that never reported a contract version must not be force-upgraded; fall back to the capacity-only path.'
Add-Check ($setupContent -match [regex]::Escape('Get-RunnerManagerReconcileAction')) 'Setup does not consult the reconcile decision, so an outdated manager would never receive a coordinated upgrade.'
Add-Check ($setupContent -match [regex]::Escape('Invoke-RunnerManagerContractUpgrade')) 'Setup does not perform a coordinated manager contract upgrade.'


$enterpriseEnvironment = New-RunnerEnvironmentContent `
    -Profile $copilotProfile `
    -AccessToken 'test-registration-token' `
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

    $resourcesDirectory = Join-Path $tempRoot 'resources-profile'
    New-Item -ItemType Directory -Path $resourcesDirectory -Force | Out-Null
    $resourcesManifestPath = Join-Path $resourcesDirectory 'profile.json'
    @{
        schemaVersion = 1
        name = 'heavy-dotnet'
        description = 'Resource-limited profile contract test.'
        image = 'example/heavy:1.0.0'
        labels = @('heavy-dotnet')
        replicas = 1
        resources = @{
            memory = '6g'
            memorySwap = '6g'
            cpus = '4'
            pids = 4096
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resourcesManifestPath -Encoding UTF8
    Add-Check (
        (Get-Content -LiteralPath $resourcesManifestPath -Raw -Encoding UTF8) |
            Test-Json -SchemaFile $schemaPath
    ) 'A profile declaring per-runner resource limits did not conform to the schema.'
    $resourcesProfile = Resolve-RunnerProfile `
        -RootPath $runnerRoot `
        -ProfilePath $resourcesManifestPath `
        -HostName 'test-host'
    Add-Check ($resourcesProfile.ResourceMemory -eq '6g') 'A profile memory limit was not surfaced by Resolve-RunnerProfile.'
    Add-Check ($resourcesProfile.ResourceMemorySwap -eq '6g') 'A profile memory-swap limit was not surfaced by Resolve-RunnerProfile.'
    Add-Check ($resourcesProfile.ResourceCpus -eq '4') 'A profile CPU limit was not surfaced by Resolve-RunnerProfile.'
    Add-Check ($resourcesProfile.ResourcePids -eq '4096') 'A profile PID limit was not surfaced by Resolve-RunnerProfile.'
    $resourcesEnvironment = New-RunnerEnvironmentContent `
        -Profile $resourcesProfile `
        -AccessToken 'test-registration-token'
    Add-Check ($resourcesEnvironment -match '(?m)^RUNNER_MEMORY_LIMIT=6g$') 'The resource profile environment did not publish its memory limit.'
    Add-Check ($resourcesEnvironment -match '(?m)^RUNNER_MEMORY_SWAP_LIMIT=6g$') 'The resource profile environment did not publish its memory-swap limit.'
    Add-Check ($resourcesEnvironment -match '(?m)^RUNNER_CPU_LIMIT=4$') 'The resource profile environment did not publish its CPU limit.'
    Add-Check ($resourcesEnvironment -match '(?m)^RUNNER_PIDS_LIMIT=4096$') 'The resource profile environment did not publish its PID limit.'

    $invalidCpuManifestPath = Join-Path $resourcesDirectory 'invalid-cpu.json'
    @{
        schemaVersion = 1
        name = 'heavy-dotnet'
        description = 'Invalid CPU limit contract test.'
        image = 'example/heavy:1.0.0'
        labels = @('heavy-dotnet')
        replicas = 1
        resources = @{ cpus = 'lots' }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $invalidCpuManifestPath -Encoding UTF8
    $invalidCpuConforms = (Get-Content -LiteralPath $invalidCpuManifestPath -Raw -Encoding UTF8) |
        Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
    Add-Check (-not $invalidCpuConforms) 'The schema accepted a non-numeric per-runner CPU limit.'

    $swapWithoutMemoryPath = Join-Path $resourcesDirectory 'swap-only.json'
    @{
        schemaVersion = 1
        name = 'heavy-dotnet'
        description = 'Swap-without-memory contract test.'
        image = 'example/heavy:1.0.0'
        labels = @('heavy-dotnet')
        replicas = 1
        resources = @{ memorySwap = '6g' }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $swapWithoutMemoryPath -Encoding UTF8
    Add-ThrowsCheck `
        -Action {
            Resolve-RunnerProfile -RootPath $runnerRoot -ProfilePath $swapWithoutMemoryPath
        } `
        -ExpectedMessage 'memorySwap requires memory' `
        -Failure 'A profile accepted a memory-swap limit without a memory limit.'

    # Issue #8 follow-up (2): validate Docker's semantic constraints at setup
    # time (before any destructive stop/replace), not just the value format.
    function New-ResourceManifestPath {
        param([string]$FileName, [hashtable]$Resources)
        $manifestPath = Join-Path $resourcesDirectory $FileName
        @{
            schemaVersion = 1
            name = 'heavy-dotnet'
            description = 'Docker constraint contract test.'
            image = 'example/heavy:1.0.0'
            labels = @('heavy-dotnet')
            replicas = 1
            resources = $Resources
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        return $manifestPath
    }

    foreach ($belowMinimum in @('5m', '1048576')) {
        $belowMinimumPath = New-ResourceManifestPath `
            -FileName "below-min-$belowMinimum.json" `
            -Resources @{ memory = $belowMinimum }
        Add-ThrowsCheck `
            -Action { Resolve-RunnerProfile -RootPath $runnerRoot -ProfilePath $belowMinimumPath } `
            -ExpectedMessage "below Docker's minimum" `
            -Failure "A profile accepted a memory limit ($belowMinimum) below Docker's 6MB floor."
    }

    $minimumMemoryPath = New-ResourceManifestPath -FileName 'min-memory.json' -Resources @{ memory = '6m' }
    $minimumMemoryProfile = Resolve-RunnerProfile -RootPath $runnerRoot -ProfilePath $minimumMemoryPath
    Add-Check ($minimumMemoryProfile.ResourceMemory -eq '6m') "Docker's exact minimum memory limit (6m) was rejected."

    $swapTooSmallPath = New-ResourceManifestPath -FileName 'swap-too-small.json' -Resources @{ memory = '64m'; memorySwap = '32m' }
    Add-ThrowsCheck `
        -Action { Resolve-RunnerProfile -RootPath $runnerRoot -ProfilePath $swapTooSmallPath } `
        -ExpectedMessage 'greater than or equal to memory' `
        -Failure 'A profile accepted a memory-swap limit smaller than its memory limit.'

    $validSwapPath = New-ResourceManifestPath -FileName 'valid-swap.json' -Resources @{ memory = '64m'; memorySwap = '128m' }
    $validSwapProfile = Resolve-RunnerProfile -RootPath $runnerRoot -ProfilePath $validSwapPath
    Add-Check ($validSwapProfile.ResourceMemorySwap -eq '128m') 'A memory-swap limit at or above the memory limit was rejected.'

    # Issue #8 follow-up (3): reject CPU limits Docker treats as unlimited/too
    # precise and memory magnitudes that overflow, at setup time.
    $zeroCpuPath = New-ResourceManifestPath -FileName 'zero-cpu.json' -Resources @{ cpus = '0' }
    Add-ThrowsCheck `
        -Action { Resolve-RunnerProfile -RootPath $runnerRoot -ProfilePath $zeroCpuPath } `
        -ExpectedMessage 'greater than zero' `
        -Failure 'A profile accepted a zero cpu limit that Docker treats as unlimited.'

    $precisecpuPath = New-ResourceManifestPath -FileName 'too-precise-cpu.json' -Resources @{ cpus = '1.0000000001' }
    Add-ThrowsCheck `
        -Action { Resolve-RunnerProfile -RootPath $runnerRoot -ProfilePath $precisecpuPath } `
        -ExpectedMessage 'too precise' `
        -Failure 'A profile accepted a cpu limit finer than one NanoCPU that Docker refuses to parse.'

    $validFractionalCpuPath = New-ResourceManifestPath -FileName 'fractional-cpu.json' -Resources @{ cpus = '1.5' }
    $validFractionalCpuProfile = Resolve-RunnerProfile -RootPath $runnerRoot -ProfilePath $validFractionalCpuPath
    Add-Check ($validFractionalCpuProfile.ResourceCpus -eq '1.5') 'A valid fractional cpu limit (1.5) was rejected.'

    $overflowMemoryPath = New-ResourceManifestPath -FileName 'overflow-memory.json' -Resources @{ memory = '9999999999g' }
    Add-ThrowsCheck `
        -Action { Resolve-RunnerProfile -RootPath $runnerRoot -ProfilePath $overflowMemoryPath } `
        -ExpectedMessage "exceeds Docker's maximum" `
        -Failure 'A profile accepted a memory limit that overflows Docker addressable bytes.'

    # Real-Docker validation (safe: failure-path only). Docker rejects these
    # specs during host-config validation BEFORE creating a container, so
    # nothing is created and nothing needs cleanup. Proves our setup-time
    # thresholds agree with Docker's own refusal. Skipped when Docker or a
    # local image is unavailable so the suite stays hermetic by default.
    # Real-Docker validation (safe: failure-path only). Docker rejects these
    # specs during flag parsing or host-config validation BEFORE creating a
    # container, so nothing is created and nothing needs cleanup. Proves our
    # setup-time thresholds agree with Docker's own refusal. Each probe uses a
    # unique --name and asserts on that specific name (never a global container
    # count) so the check is race-free against concurrent runners and does not
    # trip StrictMode on a null/scalar .Count. Skipped when Docker or a local
    # image is unavailable so the suite stays hermetic by default.
    $realDocker = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $localImageId = if ($realDocker) {
        & $realDocker.Source images -q 2>$null | Where-Object { $_ } | Select-Object -First 1
    } else {
        $null
    }
    if ($realDocker -and $localImageId) {
        function Invoke-DockerRejectionProbe {
            param([string[]]$CreateArguments, [string]$Because)
            $probeName = "pitcrew-probe-$([guid]::NewGuid().ToString('N'))"
            $null = & $realDocker.Source create --name $probeName @CreateArguments $localImageId 2>&1
            $probeExit = $LASTEXITCODE
            # Defensive: remove by our unique name in case Docker ever accepts it.
            & $realDocker.Source rm -f $probeName 2>&1 | Out-Null
            Add-Check ($probeExit -ne 0) $Because
            $leaked = @(& $realDocker.Source ps -aq --filter "name=$probeName" 2>$null | Where-Object { $_ })
            Add-Check ($leaked.Count -eq 0) "Real-Docker probe '$probeName' leaked a container; the check must only exercise the non-mutating failure path."
        }

        Invoke-DockerRejectionProbe `
            -CreateArguments @('--memory', '5m') `
            -Because 'Real Docker accepted a 5m memory limit that Resolve-RunnerProfile rejects; the setup-time floor is misaligned with Docker.'
        Invoke-DockerRejectionProbe `
            -CreateArguments @('--memory', '64m', '--memory-swap', '32m') `
            -Because 'Real Docker accepted a memory-swap smaller than memory that Resolve-RunnerProfile rejects; the setup-time rule is misaligned with Docker.'
        Invoke-DockerRejectionProbe `
            -CreateArguments @('--cpus', '1.0000000001') `
            -Because 'Real Docker accepted a too-precise cpu limit that Resolve-RunnerProfile rejects; the setup-time NanoCPU rule is misaligned with Docker.'
    } else {
        Write-Host '[skip] Real-Docker constraint validation skipped (docker or a local image is unavailable).' -ForegroundColor Yellow
    }

    # Issue #8 follow-up (3): the manager's runner-exit classifier must map a
    # missing/empty/corrupt capture to 'unknown' (an error), never to a clean
    # exit. Exercise the REAL function bytes under a POSIX shell by extracting
    # it from between its sentinels and sourcing it.
    $posixShellCommand = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $posixShell = if ($posixShellCommand) { $posixShellCommand.Source } else { $null }
    if (-not $posixShell) {
        foreach ($candidate in @(
            (Join-Path $env:ProgramFiles 'Git\usr\bin\sh.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Git\usr\bin\sh.exe')
        )) {
            if ($candidate -and (Test-Path -LiteralPath $candidate)) { $posixShell = $candidate; break }
        }
    }
    if ($posixShell) {
        $managerLines = Get-Content -LiteralPath $managerPath
        $startMatch = $managerLines | Select-String -SimpleMatch '>>> pitcrew:classify_runner_exit >>>'
        $endMatch = $managerLines | Select-String -SimpleMatch '<<< pitcrew:classify_runner_exit <<<'
        Add-Check ($startMatch -and $endMatch -and $endMatch.LineNumber -gt $startMatch.LineNumber) 'The manager exit classifier is not delimited for extraction.'
        if ($startMatch -and $endMatch -and $endMatch.LineNumber -gt $startMatch.LineNumber) {
            $fragment = ($managerLines[$startMatch.LineNumber..($endMatch.LineNumber - 2)]) -join "`n"
            $fragmentPath = Join-Path $resourcesDirectory 'classify-fragment.sh'
            Set-Content -LiteralPath $fragmentPath -Value $fragment -NoNewline -Encoding UTF8
            $fragmentPosix = $fragmentPath -replace '\\', '/'
            $classifyExpectations = [ordered]@{
                ''    = 'unknown'
                'abc' = 'unknown'
                '  '  = 'unknown'
                '0'   = 'clean'
                '137' = 'oom-kill'
                '139' = 'signal:11'
                '3'   = 'error:3'
            }
            foreach ($classifyInput in $classifyExpectations.Keys) {
                $observed = & $posixShell -c ". '$fragmentPosix'; classify_runner_exit '$classifyInput'"
                Add-Check ($observed -ceq $classifyExpectations[$classifyInput]) "The real runner-exit classifier mapped '$classifyInput' to '$observed' instead of '$($classifyExpectations[$classifyInput])'."
            }
        }
    } else {
        Write-Host '[skip] Behavioral runner-exit classifier test skipped (no POSIX shell available).' -ForegroundColor Yellow
    }

    # Issue #8 follow-up (4): the direct-Compose (bootstrap) startup path bypasses
    # Resolve-RunnerProfile, so the manager MUST enforce the same Docker resource
    # constraints itself or an operator can boot a silently-uncapped runner — the
    # fleet-wide OOM footgun. Exercise the REAL validator bytes under a POSIX
    # shell by extracting them from between their sentinels and sourcing them.
    if ($posixShell) {
        $managerLines = Get-Content -LiteralPath $managerPath
        $limitStart = $managerLines | Select-String -SimpleMatch '>>> pitcrew:resource_limit_validators >>>'
        $limitEnd = $managerLines | Select-String -SimpleMatch '<<< pitcrew:resource_limit_validators <<<'
        Add-Check ($limitStart -and $limitEnd -and $limitEnd.LineNumber -gt $limitStart.LineNumber) 'The manager resource-limit validators are not delimited for extraction.'
        if ($limitStart -and $limitEnd -and $limitEnd.LineNumber -gt $limitStart.LineNumber) {
            $limitFragment = ($managerLines[$limitStart.LineNumber..($limitEnd.LineNumber - 2)]) -join "`n"
            $limitFragmentPath = Join-Path $resourcesDirectory 'resource-limit-fragment.sh'
            Set-Content -LiteralPath $limitFragmentPath -Value $limitFragment -NoNewline -Encoding UTF8
            $limitFragmentPosix = $limitFragmentPath -replace '\\', '/'

            # Each case: predicate invocation -> expected boolean (accepted?).
            $limitExpectations = @(
                @{ Expr = 'is_valid_memory_value 5m';                  Accept = $false; Why = 'a 5MB memory limit below the 6MB Docker floor' },
                @{ Expr = 'is_valid_memory_value 6m';                  Accept = $true;  Why = 'a 6MB memory limit at the Docker floor' },
                @{ Expr = 'is_valid_memory_value 6291456';             Accept = $true;  Why = 'the exact 6291456-byte Docker floor' },
                @{ Expr = 'is_valid_memory_value 6291455';             Accept = $false; Why = 'one byte below the 6291456-byte Docker floor' },
                @{ Expr = 'is_valid_memory_value 06291456';            Accept = $true;  Why = 'a leading-zero-padded value at the Docker floor' },
                @{ Expr = 'is_valid_memory_value 9999999999g';         Accept = $false; Why = 'an enormous value that would overflow 64-bit byte arithmetic' },
                @{ Expr = 'is_valid_memory_value 512';                 Accept = $false; Why = 'a raw byte count below the 6MB floor' },
                @{ Expr = 'is_valid_memory_value abc';                 Accept = $false; Why = 'a non-numeric memory value' },
                @{ Expr = 'is_valid_memory_swap_pair 5m 6m';          Accept = $false; Why = 'a memory-swap smaller than memory' },
                @{ Expr = 'is_valid_memory_swap_pair 6m 6m';          Accept = $true;  Why = 'a memory-swap equal to memory' },
                @{ Expr = 'is_valid_memory_swap_pair 8m 6m';          Accept = $true;  Why = 'a memory-swap larger than memory' },
                @{ Expr = 'is_valid_memory_swap_pair 9999999999g 6m'; Accept = $false; Why = 'an overflow-scale memory-swap value' },
                @{ Expr = 'is_valid_cpu_value 0';                      Accept = $false; Why = 'a zero cpu limit Docker treats as unlimited' },
                @{ Expr = 'is_valid_cpu_value 0.0';                    Accept = $false; Why = 'a fractional-zero cpu limit Docker treats as unlimited' },
                @{ Expr = 'is_valid_cpu_value 2';                      Accept = $true;  Why = 'a whole-core cpu limit' },
                @{ Expr = 'is_valid_cpu_value 1.5';                    Accept = $true;  Why = 'a fractional cpu limit within nine decimals' },
                @{ Expr = 'is_valid_cpu_value 1.0000000001';          Accept = $false; Why = 'a cpu limit with more than nine decimals Docker calls too precise' },
                @{ Expr = 'is_valid_cpu_value 0.000000001';           Accept = $true;  Why = 'the smallest nine-decimal cpu limit Docker accepts' },
                @{ Expr = 'is_valid_cpu_value 0.000000008';           Accept = $true;  Why = 'a nine-decimal cpu fraction with a leading-zero run (no octal misparse)' },
                @{ Expr = 'is_valid_cpu_value 1000000000';            Accept = $false; Why = 'a core count large enough to overflow Int64 NanoCPUs' },
                @{ Expr = 'is_valid_cpu_value abc';                    Accept = $false; Why = 'a non-numeric cpu value' },
                @{ Expr = 'is_valid_pids_value 0';                     Accept = $false; Why = 'a zero pids limit' },
                @{ Expr = 'is_valid_pids_value 00';                    Accept = $false; Why = 'a leading-zero zero pids limit' },
                @{ Expr = 'is_valid_pids_value 100';                   Accept = $true;  Why = 'a positive pids limit' }
            )
            foreach ($limitCase in $limitExpectations) {
                $observed = & $posixShell -c ". '$limitFragmentPosix'; if $($limitCase.Expr); then echo accept; else echo reject; fi"
                $expected = if ($limitCase.Accept) { 'accept' } else { 'reject' }
                Add-Check ($observed -ceq $expected) "The direct-Compose validator '$($limitCase.Expr)' returned '$observed' for $($limitCase.Why); expected '$expected'."
            }
        }
    } else {
        Write-Host '[skip] Behavioral resource-limit validator test skipped (no POSIX shell available).' -ForegroundColor Yellow
    }

    # Issue #8 follow-up (1): the manager must publish a REAL job-busy signal
    # (busySlots / per-slot jobRunning) so a drain waits for actual GitHub jobs to
    # finish rather than for the always-alive slot supervisor to exit. Exercise the
    # real observability rendering under a POSIX shell with jq and assert that a
    # slot carrying a "Running job:" marker is reported busy, and an unmarked slot
    # is reported idle even while its supervisor process is alive.
    $observabilityPath = Join-Path $runnerRoot 'manager' 'observability.sh'
    $jqAvailable = $false
    if ($posixShell) {
        & $posixShell -c 'command -v jq >/dev/null 2>&1'
        $jqAvailable = ($LASTEXITCODE -eq 0)
    }
    if ($posixShell -and $jqAvailable -and (Test-Path -LiteralPath $observabilityPath -PathType Leaf)) {
        $busyProbeDir = Join-Path $resourcesDirectory 'busy-signal'
        New-Item -ItemType Directory -Path $busyProbeDir -Force | Out-Null
        $busyProbePath = Join-Path $busyProbeDir 'probe.sh'
        $observabilityPosix = $observabilityPath -replace '\\', '/'
        $busyProbeScript = @'
. "__OBSERVABILITY__"
work="$1"
mode="$2"
slots="${work}/slots"
rm -rf "${slots}"
mkdir -p "${slots}/slot-1"
printf 'https://github.com/example/project\n' > "${slots}/slot-1/repo"
sleep 30 &
probe_pid=$!
printf '%s\n' "${probe_pid}" > "${slots}/slot-1/pid"
jq -n '{state:"online",runnerName:"runner-1",failureCount:0,backoffSeconds:0,updatedAt:"2020-01-01T00:00:00Z"}' > "${slots}/slot-1/runtime-state.json"
if [ "${mode}" = "busy" ]; then
    : > "${slots}/slot-1/job-active"
fi
render_observed_slots "${slots}" "${work}/slots.json" || { kill "${probe_pid}" 2>/dev/null; exit 1; }
write_manager_observed_state "${work}/observed.json" "profile" "manager-1" 7 "running" "repo" 1 "hash" "accepted" 1 "${work}/slots.json" || { kill "${probe_pid}" 2>/dev/null; exit 1; }
cat "${work}/observed.json"
kill "${probe_pid}" 2>/dev/null || true
'@ -replace '__OBSERVABILITY__', $observabilityPosix
        # The probe is executed by /bin/sh (dash on CI); this .ps1 may be checked
        # out with CRLF, so strip CR to keep the emitted script strictly LF or the
        # shell fails to source it (a trailing CR breaks the sourced path/`set`).
        Set-Content -LiteralPath $busyProbePath -Value ($busyProbeScript -replace "`r", "") -NoNewline -Encoding UTF8
        $busyProbePosix = $busyProbePath -replace '\\', '/'
        $busyWorkPosix = ($busyProbeDir -replace '\\', '/')

        foreach ($probeMode in @('busy', 'idle')) {
            # Execute (not `. script args`): POSIX `.` ignores positional
            # parameters under dash (/bin/sh on CI), which would blank $work/$mode.
            $observedRaw = & $posixShell $busyProbePosix $busyWorkPosix $probeMode
            $observedJson = $null
            try { $observedJson = ($observedRaw -join "`n") | ConvertFrom-Json -Depth 10 } catch { $observedJson = $null }
            Add-Check ($null -ne $observedJson) "The observability rendering produced no valid observed-state JSON for the '$probeMode' slot."
            if ($observedJson) {
                $expectedBusy = if ($probeMode -eq 'busy') { 1 } else { 0 }
                Add-Check ($observedJson.PSObject.Properties['busySlots'] -and [int]$observedJson.busySlots -eq $expectedBusy) "The observed state reported busySlots=$($observedJson.busySlots) for a '$probeMode' slot; expected $expectedBusy."
                # The supervisor process is alive in both modes, so activeSlots must
                # stay 1 regardless — proving busySlots is a distinct, real signal
                # and not just a rename of supervisor liveness.
                Add-Check ($observedJson.PSObject.Properties['activeSlots'] -and [int]$observedJson.activeSlots -eq 1) "The observed state reported activeSlots=$($observedJson.activeSlots) for a '$probeMode' slot; expected 1 (the supervisor is alive in both modes)."
                $slotRecord = @($observedJson.slots)[0]
                $expectedJobRunning = ($probeMode -eq 'busy')
                Add-Check ($slotRecord -and $slotRecord.PSObject.Properties['jobRunning'] -and [bool]$slotRecord.jobRunning -eq $expectedJobRunning) "The '$probeMode' slot reported jobRunning=$($slotRecord.jobRunning); expected $expectedJobRunning."
            }
        }
    } else {
        Write-Host '[skip] Behavioral job-busy observability test skipped (no POSIX shell or jq available).' -ForegroundColor Yellow
    }

    # Issue #8 follow-up (1)+(2): the cooperative drain-and-fence protocol must
    # fence every slot (block new assignments) and only answer drain-complete
    # once no supervisor is alive AND no job is running. Exercise the real
    # run_drain_cycle from the manager under a POSIX shell with jq: an idle pool
    # (dead supervisor, no job-active) must be fenced and reported complete with
    # the request nonce echoed back; a busy pool (live supervisor + job-active)
    # must be fenced but must NOT report complete — proving the replacement waits
    # for the real GitHub job to finish instead of force-killing it.
    if ($posixShell -and $jqAvailable) {
        $drainProbeDir = Join-Path $resourcesDirectory 'drain-protocol'
        New-Item -ItemType Directory -Path $drainProbeDir -Force | Out-Null
        $drainProbePath = Join-Path $drainProbeDir 'probe.sh'
        $managerPosix = $managerPath -replace '\\', '/'
        $drainProbeScript = @'
set -u
work="$1"
mode="$2"
manager="$3"
awk '/>>> pitcrew:drain_protocol >>>/{f=1;next} /<<< pitcrew:drain_protocol <<</{f=0} f' "${manager}" > "${work}/frag.sh"
mark_observed_state_dirty() { :; }
wait_for_cleanup_commands() { return 0; }
STATE_DIRECTORY="${work}/state"
SLOT_DIRECTORY="${work}/slots"
DRAIN_REQUEST_PATH="${STATE_DIRECTORY}/drain-request.json"
DRAIN_COMPLETE_PATH="${STATE_DIRECTORY}/drain-complete.json"
MANAGER_CONTRACT_VERSION=7
RUNNER_STOP_TIMEOUT=5
rm -rf "${STATE_DIRECTORY}" "${SLOT_DIRECTORY}"
mkdir -p "${STATE_DIRECTORY}" "${SLOT_DIRECTORY}/slot-1"
jq -n '{schemaVersion:1,nonce:"testnonce"}' > "${DRAIN_REQUEST_PATH}"
. "${work}/frag.sh"
probe_pid=""
if [ "${mode}" = "busy" ]; then
    sleep 30 &
    probe_pid=$!
    printf '%s\n' "${probe_pid}" > "${SLOT_DIRECTORY}/slot-1/pid"
    : > "${SLOT_DIRECTORY}/slot-1/job-active"
else
    printf '999999\n' > "${SLOT_DIRECTORY}/slot-1/pid"
fi
run_drain_cycle
complete="no"
nonce=""
if [ -f "${DRAIN_COMPLETE_PATH}" ]; then
    complete="yes"
    nonce=$(jq -r '.nonce // ""' "${DRAIN_COMPLETE_PATH}")
fi
fenced="no"
[ -f "${SLOT_DIRECTORY}/slot-1/drain" ] && fenced="yes"
printf 'complete=%s nonce=%s fenced=%s\n' "${complete}" "${nonce}" "${fenced}"
[ -n "${probe_pid}" ] && kill "${probe_pid}" 2>/dev/null || true
'@
        # See the busy-probe note above: force LF so dash can source the fragment.
        Set-Content -LiteralPath $drainProbePath -Value ($drainProbeScript -replace "`r", "") -NoNewline -Encoding UTF8
        $drainProbePosix = $drainProbePath -replace '\\', '/'
        $drainWorkPosix = ($drainProbeDir -replace '\\', '/')

        # Execute the probe so dash passes the positional parameters (a sourced
        # `. script args` drops them under POSIX /bin/sh).
        $drainIdle = (& $posixShell $drainProbePosix $drainWorkPosix 'idle' $managerPosix) -join "`n"
        Add-Check ($drainIdle -match 'complete=yes') "The drain cycle did not report complete for an idle pool (dead supervisor, no job): '$drainIdle'."
        Add-Check ($drainIdle -match 'nonce=testnonce') "The drain-complete marker did not echo back the request nonce for an idle pool: '$drainIdle'."
        Add-Check ($drainIdle -match 'fenced=yes') "The drain cycle did not fence the slot for an idle pool: '$drainIdle'."

        $drainBusy = (& $posixShell $drainProbePosix $drainWorkPosix 'busy' $managerPosix) -join "`n"
        Add-Check ($drainBusy -match 'complete=no') "The drain cycle wrongly reported complete while a job was still running (busy pool): '$drainBusy'. A busy runner must never be force-drained."
        Add-Check ($drainBusy -match 'fenced=yes') "The drain cycle did not fence the slot for a busy pool: '$drainBusy'. New assignments must be blocked even while the in-flight job finishes."
    } else {
        Write-Host '[skip] Behavioral drain-protocol test skipped (no POSIX shell or jq available).' -ForegroundColor Yellow
    }


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
    $env:PITCREW_RUNNER_DOCKER_LOG = $dockerLog
    $ambientNames = @(
        'ACCESS_TOKEN',
        'REPO_URLS',
        'REPO_URL',
        'RUNNER_PROFILE_ID',
        'RUNNER_REPLICAS',
        'RUNNER_IMAGE',
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
    $env:PITCREW_STATE_DIR = 'ambient-state'
    $env:PITCREW_MANAGER_CONTRACT_VERSION = '99'
    $env:PITCREW_TEST_MANAGER_RUNNING = '0'
    # Bound every drain wait in the unit suite so a defer path (no cooperative
    # responder / a persistently busy worker) fails fast instead of blocking on
    # the production default. Fixtures that expect a successful drain simulate
    # the manager writing drain-complete or expose an idle worker within this.
    $env:PITCREW_DRAIN_TIMEOUT_SECONDS = '3'

    function global:docker {
        $dockerArguments = @($args)

        Add-Content `
            -LiteralPath $env:PITCREW_RUNNER_DOCKER_LOG `
            -Value (($dockerArguments | ForEach-Object { [string]$_ }) -join "`t")
        if ($dockerArguments[0] -eq 'compose') {
            Add-Content `
                -LiteralPath $env:PITCREW_RUNNER_DOCKER_LOG `
                -Value "compose-env`tACCESS_TOKEN=$env:ACCESS_TOKEN`tREPO_URLS=$env:REPO_URLS`tREPO_URL=$env:REPO_URL`tRUNNER_PROFILE_ID=$env:RUNNER_PROFILE_ID`tRUNNER_REPLICAS=$env:RUNNER_REPLICAS`tRUNNER_IMAGE=$env:RUNNER_IMAGE`tPITCREW_STATE_DIR=$env:PITCREW_STATE_DIR`tPITCREW_MANAGER_CONTRACT_VERSION=$env:PITCREW_MANAGER_CONTRACT_VERSION"
        }
        if (
            $dockerArguments[0] -eq 'ps' -and
            $dockerArguments -contains 'label=ephemeral-runner-manager-profile=default' -and
            $env:PITCREW_TEST_MANAGER_RUNNING -eq '1'
        ) {
            Write-Output 'manager-container-id'
        }
        # Legacy host-side job-busy probe: enumerate managed worker containers and
        # replay their logs so Test-RunnerLegacyWorkerBusy can classify idle/busy.
        if (
            $dockerArguments[0] -eq 'ps' -and
            ($dockerArguments -contains '-q') -and
            ($dockerArguments -contains 'label=ephemeral-managed-runner-profile=default') -and
            $env:PITCREW_TEST_MANAGED_WORKERS
        ) {
            foreach ($workerId in ($env:PITCREW_TEST_MANAGED_WORKERS -split ',')) {
                if (-not [string]::IsNullOrWhiteSpace($workerId)) {
                    Write-Output $workerId.Trim()
                }
            }
        }
        if ($dockerArguments[0] -eq 'logs') {
            if ($env:PITCREW_TEST_WORKER_LOG) {
                foreach ($logLine in ($env:PITCREW_TEST_WORKER_LOG -split "`n")) {
                    Write-Output $logLine
                }
            }
        }
        if (
            $dockerArguments[0] -eq 'compose' -and
            ($dockerArguments -contains 'up') -and
            $env:PITCREW_TEST_UPGRADE_ACK_SOURCE -and
            $env:PITCREW_TEST_UPGRADE_ACK_DEST -and
            (Test-Path -LiteralPath $env:PITCREW_TEST_UPGRADE_ACK_SOURCE -PathType Leaf)
        ) {
            # Simulate the recreated manager coming up on the new contract and
            # re-writing its acknowledgement with the upgraded contract version.
            Copy-Item `
                -LiteralPath $env:PITCREW_TEST_UPGRADE_ACK_SOURCE `
                -Destination $env:PITCREW_TEST_UPGRADE_ACK_DEST `
                -Force
        }
        $global:LASTEXITCODE = 0
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
        $defaultDesiredState = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-Check ($defaultEnvironmentState -match '(?m)^RUNNER_PROFILE_ID=default$') 'Default setup did not write the default profile environment.'
        Add-Check ($defaultEnvironmentState -match '(?m)^RUNNER_LABELS=general-purpose$') 'Default setup did not write the general-purpose label.'
        Add-Check ($defaultEnvironmentState -notmatch '(?m)^(REPO_URLS|RUNNER_REPLICAS)=') 'Default setup wrote mutable capacity into the static environment.'
        Add-Check ($defaultDesiredState.generation -eq 1) 'Initial desired capacity did not start at generation one.'
        Add-Check ($defaultDesiredState.repositories[0].workers -eq 1) 'Initial desired capacity did not preserve the repository worker count.'
        $defaultCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($defaultCommands -match 'pull.*myoung34/github-runner:ubuntu-noble') 'Default setup did not prepare its pullable image before replacement.'
        Add-Check ($defaultCommands -match "compose-env`tACCESS_TOKEN=`tREPO_URLS=`tREPO_URL=`tRUNNER_PROFILE_ID=`tRUNNER_REPLICAS=`tRUNNER_IMAGE=`tPITCREW_STATE_DIR=`tPITCREW_MANAGER_CONTRACT_VERSION=$") 'Ambient profile variables were visible to Docker Compose.'
        Add-Check ($env:RUNNER_PROFILE_ID -eq 'ambient-profile') 'Docker Compose isolation did not restore ambient profile variables.'

        Set-TestCapacityAcknowledgement `
            -Path $defaultAcknowledgementPath `
            -Generation 1 `
            -DesiredSlots 1 `
            -AddedSlots 1 `
            -DrainingSlots 0 `
            -UnchangedSlots 0
        $env:PITCREW_TEST_MANAGER_RUNNING = '1'
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

        # Issue #8 follow-up (2): coordinated, non-destructive manager contract
        # upgrade. The running manager reports an OLDER baked-in contract version
        # than the tooling provides (it still carries the pre-fix exit-capture
        # code). Setup must refresh it WITHOUT force-killing containers, and must
        # DEFER entirely while any slot is still busy so no active job is lost.
        $defaultObservedPath = Join-Path (Split-Path -Parent $defaultDesiredPath) 'observed-state.json'
        $currentContractGeneration = [int](
            (Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
                ConvertFrom-Json -Depth 10).generation
        )

        # Case 1: a worker is still running a job => DEFER; never recreate, never
        # force-remove, and surface the deferral so the operator re-runs later.
        # The v6 running manager predates the cooperative drain protocol, so setup
        # falls back to a host-side job-busy probe: a worker whose log shows a
        # "Running job:" with no later completion is BUSY.
        Set-TestCapacityAcknowledgement `
            -Path $defaultAcknowledgementPath `
            -Generation $currentContractGeneration `
            -DesiredSlots 1 `
            -AddedSlots 0 `
            -DrainingSlots 0 `
            -UnchangedSlots 1 `
            -ManagerContractVersion 6
        $env:PITCREW_TEST_MANAGED_WORKERS = 'worker-busy-1'
        $env:PITCREW_TEST_WORKER_LOG = "Listening for Jobs`nRunning job: build-and-test"
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        $contractDeferWarnLog = Join-Path $tempRoot 'contract-defer-warnings.log'
        try {
            & $fixtureSetup `
                -Token 'test-registration-token' `
                -Repos 'https://github.com/example/project=1' 3> $contractDeferWarnLog
        }
        finally {
            Remove-Item Env:\PITCREW_TEST_MANAGED_WORKERS -ErrorAction SilentlyContinue
            Remove-Item Env:\PITCREW_TEST_WORKER_LOG -ErrorAction SilentlyContinue
        }
        $contractDeferCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        $contractDeferWarnings = (@(Get-Content -LiteralPath $contractDeferWarnLog -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n")
        $contractDeferAck = Get-Content -LiteralPath $defaultAcknowledgementPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-Check (-not ($contractDeferCommands -match 'compose.*up')) 'A contract upgrade recreated the manager while a runner was still running a job.'
        Add-Check (-not ($contractDeferCommands -match 'compose.*down')) 'A deferred contract upgrade tore down the running manager.'
        Add-Check (-not ($contractDeferCommands -match 'rm.*-f')) 'A deferred contract upgrade force-removed a runner container.'
        Add-Check ($contractDeferWarnings -match 'Deferring the coordinated upgrade') 'A deferred contract upgrade did not surface the deferral to the operator.'
        Add-Check ([int]$contractDeferAck.managerContractVersion -eq 6) 'A deferred contract upgrade changed the running manager acknowledgement.'

        # Case 2: the pool is idle (host-side probe sees a completed job as the
        # last activity) => perform the drain-safe upgrade by recreating ONLY the
        # manager (compose up --force-recreate), never a compose down or rm -f.
        Set-TestCapacityAcknowledgement `
            -Path $defaultAcknowledgementPath `
            -Generation $currentContractGeneration `
            -DesiredSlots 1 `
            -AddedSlots 0 `
            -DrainingSlots 0 `
            -UnchangedSlots 1 `
            -ManagerContractVersion 6
        $env:PITCREW_TEST_MANAGED_WORKERS = 'worker-idle-1'
        $env:PITCREW_TEST_WORKER_LOG = "Running job: build-and-test`nJob build-and-test completed with result: Succeeded`nListening for Jobs"
        $upgradeAckSource = Join-Path $tempRoot 'upgraded-acknowledgement.json'
        Set-TestCapacityAcknowledgement `
            -Path $upgradeAckSource `
            -Generation $currentContractGeneration `
            -DesiredSlots 1 `
            -AddedSlots 0 `
            -DrainingSlots 0 `
            -UnchangedSlots 1 `
            -ManagerContractVersion 7
        $env:PITCREW_TEST_UPGRADE_ACK_SOURCE = $upgradeAckSource
        $env:PITCREW_TEST_UPGRADE_ACK_DEST = $defaultAcknowledgementPath
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        try {
            & $fixtureSetup `
                -Token 'test-registration-token' `
                -Repos 'https://github.com/example/project=1'
        }
        finally {
            Remove-Item Env:\PITCREW_TEST_UPGRADE_ACK_SOURCE -ErrorAction SilentlyContinue
            Remove-Item Env:\PITCREW_TEST_UPGRADE_ACK_DEST -ErrorAction SilentlyContinue
            Remove-Item Env:\PITCREW_TEST_MANAGED_WORKERS -ErrorAction SilentlyContinue
            Remove-Item Env:\PITCREW_TEST_WORKER_LOG -ErrorAction SilentlyContinue
        }
        $contractUpgradeCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        $contractUpgradeAck = Get-Content -LiteralPath $defaultAcknowledgementPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        $contractUpgradeState = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10
        Add-Check ($contractUpgradeCommands -match 'compose.*up.*--force-recreate') 'An idle contract upgrade did not recreate the manager onto the new contract code.'
        Add-Check (-not ($contractUpgradeCommands -match 'compose.*down')) 'An idle contract upgrade tore down the profile instead of recreating the manager in place.'
        Add-Check (-not ($contractUpgradeCommands -match 'rm.*-f')) 'An idle contract upgrade force-removed a runner container.'
        Add-Check ([int]$contractUpgradeAck.managerContractVersion -eq 7) 'The manager did not re-acknowledge on the upgraded contract version.'
        Add-Check ($contractUpgradeState.generation -eq $currentContractGeneration) 'A pure contract upgrade advanced the desired-capacity generation.'
        Remove-Item -LiteralPath $defaultObservedPath -Force -ErrorAction SilentlyContinue

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
        $immutableDrainRequestPath = Join-Path (Split-Path -Parent $defaultDesiredPath) 'drain-request.json'
        $immutableDrainCompletePath = Join-Path (Split-Path -Parent $defaultDesiredPath) 'drain-complete.json'
        $immutableDrainResponder = Start-TestDrainCompleteWriter `
            -DrainRequestPath $immutableDrainRequestPath `
            -DrainCompletePath $immutableDrainCompletePath
        try {
            & $fixtureSetup `
                -Token 'test-registration-token' `
                -Labels 'additional-capability' `
                -Repos 'https://github.com/example/project=1'
        }
        finally {
            Stop-Job -Job $immutableDrainResponder -ErrorAction SilentlyContinue
            Remove-Job -Job $immutableDrainResponder -Force -ErrorAction SilentlyContinue
        }
        $immutableCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($immutableCommands -match 'pull.*myoung34/github-runner:ubuntu-noble') 'An immutable profile change skipped image preparation.'
        Add-Check ($immutableCommands -match 'compose.*down') 'An immutable profile change did not replace the manager.'
        Add-Check ($immutableCommands -match 'compose.*up') 'An immutable profile change did not restart the profile.'
        Add-Check (-not (Test-Path -LiteralPath $immutableDrainRequestPath)) 'A completed drain-safe replacement left the drain-request marker behind.'
        Add-Check (-not (Test-Path -LiteralPath $immutableDrainCompletePath)) 'A completed drain-safe replacement left the drain-complete marker behind.'

        # Issue #8 follow-up (2): a static/resource replacement against a running
        # cooperative (v7+) manager that NEVER confirms drain-complete must DEFER,
        # never tear the pool down. With no responder the drain request times out;
        # Setup must not issue compose down / rm -f / compose up, must surface the
        # deferral, must clear the drain markers so the still-running manager
        # resumes reconciliation, and must leave the desired document untouched.
        $deferGeneration = [int](
            (Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8 |
                ConvertFrom-Json -Depth 10).generation
        )
        Set-TestCapacityAcknowledgement `
            -Path $defaultAcknowledgementPath `
            -Generation $deferGeneration `
            -DesiredSlots 1 `
            -AddedSlots 0 `
            -DrainingSlots 0 `
            -UnchangedSlots 1 `
            -ManagerContractVersion 7
        $desiredBeforeDeferredReplace = Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8
        Set-Content -LiteralPath $dockerLog -Value '' -NoNewline
        $replaceDeferWarnLog = Join-Path $tempRoot 'replace-defer-warnings.log'
        & $fixtureSetup `
            -Token 'test-registration-token' `
            -Labels 'yet-another-capability' `
            -Repos 'https://github.com/example/project=1' 3> $replaceDeferWarnLog
        $replaceDeferCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        $replaceDeferWarnings = (@(Get-Content -LiteralPath $replaceDeferWarnLog -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n")
        Add-Check (-not ($replaceDeferCommands -match 'compose.*down')) 'A cooperative static replacement that never drained tore down the running manager.'
        Add-Check (-not ($replaceDeferCommands -match 'rm.*-f')) 'A cooperative static replacement that never drained force-removed a runner container.'
        Add-Check (-not ($replaceDeferCommands -match 'compose.*up')) 'A cooperative static replacement that never drained restarted the profile.'
        Add-Check ($replaceDeferWarnings -match 'Deferring the static/resource replacement') 'A deferred static replacement did not surface the deferral to the operator.'
        Add-Check (-not (Test-Path -LiteralPath $immutableDrainRequestPath)) 'A deferred static replacement left the drain-request marker behind.'
        Add-Check (
            (Get-Content -LiteralPath $defaultDesiredPath -Raw -Encoding UTF8) -eq $desiredBeforeDeferredReplace
        ) 'A deferred static replacement changed the visible desired document.'

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
        foreach ($name in $ambientNames) {
            if ($savedAmbient[$name].Exists) {
                Set-Item -LiteralPath "Env:$name" -Value $savedAmbient[$name].Value
            } else {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }
        Remove-Item Env:\PITCREW_RUNNER_DOCKER_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGER_RUNNING -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_DRAIN_TIMEOUT_SECONDS -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_MANAGED_WORKERS -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_WORKER_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_UPGRADE_ACK_SOURCE -ErrorAction SilentlyContinue
        Remove-Item Env:\PITCREW_TEST_UPGRADE_ACK_DEST -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$manager = Get-Content -LiteralPath $managerPath -Raw -Encoding UTF8
$managerDockerfile = Get-Content -LiteralPath $managerDockerfilePath -Raw -Encoding UTF8
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
Add-Check ($manager -match [regex]::Escape('is_valid_memory_value')) 'The manager does not validate per-runner memory limits.'
Add-Check ($manager -match [regex]::Escape('is_valid_cpu_value')) 'The manager does not validate per-runner CPU limits.'
Add-Check ($manager -match [regex]::Escape('is_valid_pids_value')) 'The manager does not validate per-runner PID limits.'
Add-Check ($manager -match [regex]::Escape('set -- "$@" --memory "${RUNNER_MEMORY_LIMIT}"')) 'The manager does not apply a per-runner memory limit to worker containers.'
Add-Check ($manager -match [regex]::Escape('set -- "$@" --memory-swap "${RUNNER_MEMORY_SWAP_LIMIT}"')) 'The manager does not apply a per-runner memory-swap limit to worker containers.'
Add-Check ($manager -match [regex]::Escape('set -- "$@" --cpus "${RUNNER_CPU_LIMIT}"')) 'The manager does not apply a per-runner CPU limit to worker containers.'
Add-Check ($manager -match [regex]::Escape('set -- "$@" --pids-limit "${RUNNER_PIDS_LIMIT}"')) 'The manager does not apply a per-runner PID limit to worker containers.'
Add-Check ($manager -match [regex]::Escape('printf ''%s'' "$?" > "${runner_status_path}"')) 'The manager discards the ephemeral runner container exit status.'
Add-Check ($manager -match [regex]::Escape('classify_runner_exit()')) 'The manager does not expose a testable runner-exit classifier.'
Add-Check ($manager -match '(?m)^MANAGER_CONTRACT_VERSION=7$') 'The manager script does not bake the current contract version, so a coordinated upgrade cannot detect stale runtime code.'
Add-Check ($manager -match [regex]::Escape("''|*[!0-9]*) printf 'unknown'")) 'The manager does not classify a missing/corrupt exit capture as unknown.'
Add-Check ($manager -notmatch [regex]::Escape('runner_exit_status=0')) 'The manager still defaults a runner exit status to 0 (clean), masking an unobserved or killed runner.'
Add-Check ($manager -match 'exit status is UNKNOWN') 'The manager does not surface an unknown/unobserved runner exit as an error.'
Add-Check ($manager -match 'status 137') 'The manager does not flag a SIGKILL/OOM runner exit distinctly from a clean job completion.'
Add-Check ($manager -match 'exited cleanly') 'The manager does not log graceful runner job completion.'
Add-Check ($manager -match [regex]::Escape('observed-state.json')) 'The manager does not project credential-free observed state.'
Add-Check ($manager -match [regex]::Escape('PITCREW_OBSERVED_STATE_INTERVAL:-30')) 'The manager does not bound observed-state heartbeat writes.'
Add-Check ($manager -match [regex]::Escape(': > "${stopping_path}/drain"')) 'Manager shutdown does not drain slot supervisors before cleanup.'
Add-Check ($manager -match [regex]::Escape('docker stop \')) 'Manager shutdown does not signal worker entry points before force removal.'
Add-Check ($manager -match [regex]::Escape('--timeout "${RUNNER_STOP_TIMEOUT}"')) 'Manager shutdown does not bound graceful worker deregistration.'
Add-Check ($manager -match [regex]::Escape('if ! remove_managed_strict; then')) 'Manager shutdown can publish stopped without confirming runner cleanup.'
Add-Check ($manager -match [regex]::Escape('rm -f "${OBSERVED_STATE_DIRTY}"')) 'Observed-state publication does not preserve concurrent dirty notifications.'
# Issue #8 follow-up (1)+(2): the manager must implement the cooperative
# drain-and-fence protocol so a v7+ replacement can wait for real in-flight jobs
# to finish instead of force-killing runners. Assert the wiring is present and
# that the main loop consults the drain request before reconciling (reconcile
# clears slot drains and respawns, which would defeat the fence).
Add-Check ($manager -match [regex]::Escape('run_drain_cycle')) 'The manager does not implement a cooperative drain cycle.'
Add-Check ($manager -match [regex]::Escape('drain_requested')) 'The manager does not detect a host-side drain request.'
Add-Check ($manager -match [regex]::Escape('drain-request.json')) 'The manager does not read the drain-request marker.'
Add-Check ($manager -match [regex]::Escape('drain-complete.json')) 'The manager does not answer with a drain-complete marker.'
Add-Check ($manager -match '(?m)^\s*if drain_requested; then') 'The manager main loop does not check for a drain request before reconciling, so a fence could be undone by a respawn.'
Add-Check ($manager -match [regex]::Escape('[ -f "${idle_path}/job-active" ] && continue')) 'The manager drain cycle does not skip busy runners, so an in-flight job could be force-stopped.'
Add-Check ($managerDockerfile -match 'FROM docker:28-cli AS docker-cli') 'The manager does not isolate the Docker client build stage.'
Add-Check ($managerDockerfile -match 'FROM alpine:3\.22') 'The manager runtime is not based on minimal Alpine.'
Add-Check ($managerDockerfile -match [regex]::Escape('COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker')) 'The manager runtime does not copy only the Docker client binary.'
Add-Check ($managerDockerfile -match 'ARG JQ_VERSION=1\.8\.2') 'The manager does not pin its jq release.'
Add-Check ($managerDockerfile -match 'JQ_SHA256_AMD64=[0-9a-f]{64}') 'The manager does not checksum-pin jq for amd64.'
Add-Check ($managerDockerfile -match 'JQ_SHA256_ARM64=[0-9a-f]{64}') 'The manager does not checksum-pin jq for arm64.'
Add-Check ($managerDockerfile -match [regex]::Escape('sha256sum -c -')) 'The manager does not verify the downloaded jq binary.'
Add-Check ($managerDockerfile -match 'until wget') 'The manager does not retry transient jq download failures.'
Add-Check ($managerDockerfile -notmatch 'apk add') 'The manager still resolves jq through a mutable Alpine package repository.'
Add-Check ($compose -match [regex]::Escape('RUNNER_PROFILE_ID: ${RUNNER_PROFILE_ID:-default}')) 'Compose does not pass the profile identity to the manager.'
# Issue #8 follow-up (3): a direct `docker compose up` with no explicit
# PITCREW_MANAGER_CONTRACT_VERSION override must default to a version the
# manager's own contract guard accepts. If the Compose default lags the baked
# manager contract, the guard aborts and the pool never starts.
$composeContractMatch = [regex]::Match(
    $compose,
    'PITCREW_MANAGER_CONTRACT_VERSION:\s*\$\{PITCREW_MANAGER_CONTRACT_VERSION:-(?<version>\d+)\}')
$managerBakedContractMatch = [regex]::Match($manager, '(?m)^MANAGER_CONTRACT_VERSION=(?<version>\d+)$')
Add-Check $composeContractMatch.Success 'Compose does not default the manager contract version for direct startup.'
Add-Check ($composeContractMatch.Groups['version'].Value -eq '7') 'The Compose default manager contract version is not the current version 7; a direct `docker compose up` would fail the manager contract guard.'
Add-Check (
    $composeContractMatch.Success -and
    $managerBakedContractMatch.Success -and
    $composeContractMatch.Groups['version'].Value -eq $managerBakedContractMatch.Groups['version'].Value
) 'The Compose default manager contract version does not match the baked manager contract, so a direct `docker compose up` without an override would abort on the contract guard.'
Add-Check ($compose -match [regex]::Escape('${PITCREW_STATE_DIR:-.pitcrew-state/default}:/var/lib/pitcrew')) 'Compose does not mount the mutable state directory.'
Add-Check ($compose -match 'stop_grace_period:\s*35s') 'Compose does not allow manager shutdown to complete bounded worker cleanup.'
Add-Check ($compose -match [regex]::Escape('RUNNER_REPLICAS: ${RUNNER_REPLICAS:-1}')) 'Compose does not expose the legacy capacity bootstrap adapter.'
Add-Check ($compose -match [regex]::Escape('REPO_URLS: ${REPO_URLS:-}')) 'Compose does not expose legacy repository targets to the bootstrap adapter.'
Add-Check ($compose -match [regex]::Escape('RUNNER_MEMORY_LIMIT: ${RUNNER_MEMORY_LIMIT:-}')) 'Compose does not expose the per-runner memory limit.'
Add-Check ($compose -match [regex]::Escape('RUNNER_CPU_LIMIT: ${RUNNER_CPU_LIMIT:-}')) 'Compose does not expose the per-runner CPU limit.'
Add-Check ($compose -match [regex]::Escape('RUNNER_PIDS_LIMIT: ${RUNNER_PIDS_LIMIT:-}')) 'Compose does not expose the per-runner PID limit.'
Add-Check ($exampleEnvironment -match '(?m)^# RUNNER_MEMORY_LIMIT=') 'The example environment does not document the per-runner memory limit knob.'
Add-Check ($compose -notmatch '/var/run/docker\.sock:.+runner') 'Compose appears to expose the Docker socket to a runner service.'
Add-Check ($exampleEnvironment -match '(?m)^PITCREW_MANAGER_CONTRACT_VERSION=7$') 'The example environment does not pin the current manager contract.'
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
