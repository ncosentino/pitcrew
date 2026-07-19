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
        [int]$UnchangedSlots
    )

    [PSCustomObject][ordered]@{
        schemaVersion = 1
        status = 'accepted'
        generation = $Generation
        managerContractVersion = 6
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
                            managerContractVersion = 6
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
Add-Check ($defaultProfile.ManagerContractVersion -eq 6) 'The setup contract does not identify the observed-state manager.'
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
Add-Check ($defaultEnvironment -match '(?m)^PITCREW_MANAGER_CONTRACT_VERSION=6$') 'The environment does not pin the manager reconciliation contract.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_PROFILE_ID=copilot-cli$') 'The specialized environment does not identify its profile.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_NO_DEFAULT_LABELS=1$') 'The specialized environment does not disable GitHub default labels.'
Add-Check ($copilotEnvironment -match '(?m)^RUNNER_PULL_IMAGE=0$') 'The specialized environment does not protect its locally built image.'

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
        & $fixtureSetup `
            -Token 'test-registration-token' `
            -Labels 'additional-capability' `
            -Repos 'https://github.com/example/project=1'
        $immutableCommands = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8)
        Add-Check ($immutableCommands -match 'pull.*myoung34/github-runner:ubuntu-noble') 'An immutable profile change skipped image preparation.'
        Add-Check ($immutableCommands -match 'compose.*down') 'An immutable profile change did not replace the manager.'
        Add-Check ($immutableCommands -match 'compose.*up') 'An immutable profile change did not restart the profile.'

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
Add-Check ($manager -match [regex]::Escape('observed-state.json')) 'The manager does not project credential-free observed state.'
Add-Check ($manager -match [regex]::Escape('PITCREW_OBSERVED_STATE_INTERVAL:-30')) 'The manager does not bound observed-state heartbeat writes.'
Add-Check ($manager -match [regex]::Escape(': > "${stopping_path}/drain"')) 'Manager shutdown does not drain slot supervisors before cleanup.'
Add-Check ($manager -match [regex]::Escape('docker stop \')) 'Manager shutdown does not signal worker entry points before force removal.'
Add-Check ($manager -match [regex]::Escape('--timeout "${RUNNER_STOP_TIMEOUT}"')) 'Manager shutdown does not bound graceful worker deregistration.'
Add-Check ($manager -match [regex]::Escape('if ! remove_managed_strict; then')) 'Manager shutdown can publish stopped without confirming runner cleanup.'
Add-Check ($manager -match [regex]::Escape('rm -f "${OBSERVED_STATE_DIRTY}"')) 'Observed-state publication does not preserve concurrent dirty notifications.'
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
Add-Check ($compose -match [regex]::Escape('${PITCREW_STATE_DIR:-.pitcrew-state/default}:/var/lib/pitcrew')) 'Compose does not mount the mutable state directory.'
Add-Check ($compose -match 'stop_grace_period:\s*35s') 'Compose does not allow manager shutdown to complete bounded worker cleanup.'
Add-Check ($compose -match [regex]::Escape('RUNNER_REPLICAS: ${RUNNER_REPLICAS:-1}')) 'Compose does not expose the legacy capacity bootstrap adapter.'
Add-Check ($compose -match [regex]::Escape('REPO_URLS: ${REPO_URLS:-}')) 'Compose does not expose legacy repository targets to the bootstrap adapter.'
Add-Check ($compose -notmatch '/var/run/docker\.sock:.+runner') 'Compose appears to expose the Docker socket to a runner service.'
Add-Check ($exampleEnvironment -match '(?m)^PITCREW_MANAGER_CONTRACT_VERSION=6$') 'The example environment does not pin the current manager contract.'
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
