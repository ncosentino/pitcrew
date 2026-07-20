#Requires -Version 7.0
<#
.SYNOPSIS
    Provision, update, or stop an isolated self-hosted runner profile.

.DESCRIPTION
    Idempotent setup for the truly-ephemeral runner pool in this folder. Existing
    invocations target the implicit default profile. Named profiles add distinct
    images, labels, replica defaults, verification checks, Compose projects,
    environment files, and Docker cleanup labels without duplicating the manager.

    Each run converges only the selected profile. Capacity-only changes update
    atomically mounted desired state and are reconciled by the existing manager.
    Changes to image, routing, scope, naming, or other static configuration retain
    the full profile replacement path.

.PARAMETER Token
    Fine-grained PAT with Administration: Read and write on every target. If
    omitted, uses the authenticated gh CLI token. Written only to the selected
    profile's gitignored environment file.

.PARAMETER Replicas
    Override the profile's default workers per repo. Pass 0 to auto-size to half
    the machine's logical processors.

.PARAMETER Labels
    Override optional profile labels. The mandatory routing label remains.

.PARAMETER NamePrefix
    Override the runner-name prefix. Named profiles otherwise append their name
    to the machine hostname.

.PARAMETER Scope
    repo (default), org, or ent. Org and enterprise scopes require their
    corresponding name parameter.

.PARAMETER Repos
    Required for repo scope unless using -AddRepos. Each value is a URL or
    URL=workers.

.PARAMETER AddRepos
    Add repository targets without retyping the selected profile's full list.

.PARAMETER RemoveRepos
    Remove repository targets from the selected profile.

.PARAMETER OrgName
    Organization name required for org scope.

.PARAMETER EnterpriseName
    Enterprise name required for ent scope.

.PARAMETER Image
    Override the profile's runner image.

.PARAMETER PullImage
    Override whether the manager pulls the image before launching runners. Set
    false for locally built or otherwise locally trusted image tags.

.PARAMETER RunnerGroup
    Override the optional organization or enterprise runner group.

.PARAMETER Profile
    Built-in profile name. Defaults to the backward-compatible default profile.

.PARAMETER ProfilePath
    Path to an external profile manifest. Relative build paths resolve from the
    manifest directory.

.PARAMETER Down
    Stop only the selected profile.

.EXAMPLE
    .\Setup-Runner.ps1 -Repos https://github.com/me/repo-a

.EXAMPLE
    .\Setup-Runner.ps1 -Profile copilot-cli -Repos https://github.com/me/repo-a

.EXAMPLE
    .\Setup-Runner.ps1 -Profile copilot-cli -Down
#>
[CmdletBinding()]
param(
    [string]$Token,
    [Nullable[int]]$Replicas,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Labels,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$NamePrefix,
    [ValidateSet('repo', 'org', 'ent')]
    [string]$Scope = 'repo',
    [string[]]$Repos = @(),
    [string[]]$AddRepos = @(),
    [string[]]$RemoveRepos = @(),
    [string]$OrgName = '',
    [string]$EnterpriseName = '',
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Image,
    [Nullable[bool]]$PullImage,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$RunnerGroup,
    [string]$Profile = 'default',
    [string]$ProfilePath = '',
    [switch]$Down
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
. (Join-Path $here 'RunnerProfiles.Functions.ps1')

$resolveArguments = @{
    RootPath = $here
    Profile = $Profile
    ProfilePath = $ProfilePath
    HostName = [Environment]::MachineName
}
foreach ($parameterName in @('Replicas', 'Labels', 'NamePrefix', 'Image', 'PullImage', 'RunnerGroup')) {
    if ($PSBoundParameters.ContainsKey($parameterName)) {
        $resolveArguments[$parameterName] = Get-Variable -Name $parameterName -ValueOnly
    }
}
$profileConfig = Resolve-RunnerProfile @resolveArguments

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error 'docker not found. Install Docker Desktop and retry.'
}

$legacyLabels = @('ephemeral-managed-runner')
$composePath = Join-Path $here 'docker-compose.yml'
$composeEnvironmentNames = @(
    'ACCESS_TOKEN',
    'REPO_URLS',
    'REPO_URL',
    'RUNNER_SCOPE',
    'ORG_NAME',
    'ENTERPRISE_NAME',
    'RUNNER_PROFILE_ID',
    'RUNNER_REPLICAS',
    'RUNNER_IMAGE',
    'RUNNER_PULL_IMAGE',
    'RUNNER_NAME_PREFIX',
    'RUNNER_LABELS',
    'RUNNER_NO_DEFAULT_LABELS',
    'RUNNER_GROUP',
    'RUNNER_MEMORY_LIMIT',
    'RUNNER_MEMORY_SWAP_LIMIT',
    'RUNNER_CPU_LIMIT',
    'RUNNER_PIDS_LIMIT',
    'PITCREW_STATE_DIR',
    'PITCREW_MANAGER_CONTRACT_VERSION'
)

function Invoke-RunnerCompose {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ProfileConfig,

        [Parameter(Mandatory)]
        [string[]]$CommandArguments,

        [switch]$DiscardOutput
    )

    $savedEnvironment = @{}
    foreach ($name in $composeEnvironmentNames) {
        $item = Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        $savedEnvironment[$name] = [PSCustomObject]@{
            Exists = $null -ne $item
            Value = if ($item) { $item.Value } else { $null }
        }
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }

    $exitCode = 1
    try {
        $composeArguments = @(
            'compose',
            '--file', $composePath,
            '--project-name', $ProfileConfig.ComposeProjectName
        )
        if (Test-Path -LiteralPath $ProfileConfig.EnvironmentPath) {
            $composeArguments += @('--env-file', $ProfileConfig.EnvironmentPath)
        }
        $composeArguments += $CommandArguments

        if ($DiscardOutput) {
            & docker @composeArguments 2>&1 | Out-Null
        } else {
            & docker @composeArguments
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        foreach ($name in $composeEnvironmentNames) {
            if ($savedEnvironment[$name].Exists) {
                Set-Item -LiteralPath "Env:$name" -Value $savedEnvironment[$name].Value
            } else {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }
    }

    if ($exitCode -ne 0) {
        Write-Error "docker compose $($CommandArguments[0]) failed for profile '$($ProfileConfig.Name)'."
    }
}

function Stop-RunnerProfile {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ProfileConfig
    )

    Invoke-RunnerCompose `
        -ProfileConfig $ProfileConfig `
        -CommandArguments @('down', '--remove-orphans') `
        -DiscardOutput

    $ids = @(docker ps -aq --filter "label=$($ProfileConfig.ManagedRunnerLabel)" 2>$null)
    if ($ProfileConfig.IsDefault) {
        $ids += foreach ($label in $legacyLabels) {
            docker ps -aq --filter "label=$label" 2>$null
        }
    }

    foreach ($id in (@($ids) | Where-Object { $_ } | Select-Object -Unique)) {
        docker rm -f $id 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to remove managed runner container '$id'."
        }
    }
}

function Test-RunnerManagerRunning {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ProfileConfig
    )

    $managerIds = @(
        docker ps -q --filter "label=ephemeral-runner-manager-profile=$($ProfileConfig.Name)" 2>$null |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to inspect the manager for profile '$($ProfileConfig.Name)'."
    }
    return $managerIds.Count -gt 0
}

function New-RunnerTextStagingFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporaryPath = Join-Path $directory ".$([IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporaryPath, $Value, [Text.UTF8Encoding]::new($false))
        return $temporaryPath
    }
    catch {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function New-RunnerJsonStagingFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 20
    return New-RunnerTextStagingFile -Path $Path -Value "$json`n"
}

function Complete-RunnerStagedFile {
    param(
        [Parameter(Mandatory)]
        [string]$TemporaryPath,

        [Parameter(Mandatory)]
        [string]$Path
    )

    [IO.File]::Move($TemporaryPath, $Path, $true)
}

function Wait-RunnerCapacityAcknowledgement {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ProfileConfig,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Generation,

        [Parameter(Mandatory)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $lastReadError = $null
    do {
        if (Test-Path -LiteralPath $ProfileConfig.CapacityAcknowledgementPath -PathType Leaf) {
            try {
                $acknowledgement = Read-RunnerJsonFile -Path $ProfileConfig.CapacityAcknowledgementPath
                if (
                    [int]$acknowledgement.schemaVersion -ne 1 -or
                    [string]$acknowledgement.status -ne 'accepted'
                ) {
                    throw 'Acknowledgement has an unsupported contract.'
                }

                $acknowledgedGeneration = [int]$acknowledgement.generation
                if ($acknowledgedGeneration -eq $Generation) {
                    return $acknowledgement
                }
                if ($acknowledgedGeneration -gt $Generation) {
                    throw "Manager acknowledged generation $acknowledgedGeneration while setup was waiting for generation $Generation."
                }
                $lastReadError = $null
            } catch {
                $lastReadError = $_.Exception.Message
            }
        }
        Start-Sleep -Milliseconds 200
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    $detail = if ($lastReadError) { " Last acknowledgement error: $lastReadError" } else { '' }
    throw "Manager for profile '$($ProfileConfig.Name)' did not acknowledge desired-capacity generation $Generation within $TimeoutSeconds seconds.$detail"
}

function Get-RunnerEnvironmentFileValue {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $prefix = "$Name="
    $line = Get-Content -LiteralPath $Path -Encoding UTF8 |
        Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } |
        Select-Object -Last 1
    if ($null -eq $line) {
        return $null
    }
    return $line.Substring($prefix.Length)
}

Push-Location $here
$profileLock = $null
try {
    New-Item -ItemType Directory -Path $profileConfig.StateDirectory -Force | Out-Null
    $profileLock = Enter-RunnerProfileLock -Path $profileConfig.LockPath -TimeoutSeconds 30

    if ($Down) {
        Write-Host "[stop] Stopping profile '$($profileConfig.Name)'"
        Stop-RunnerProfile -ProfileConfig $profileConfig
        Write-Host "[done] Profile '$($profileConfig.Name)' stopped. Other profiles were not changed."
        return
    }

    Write-Host "[resolve] Resolving workers, targets, and registration credentials"
    if ($profileConfig.Replicas -eq 0) {
        $profileConfig.Replicas = [math]::Max(2, [math]::Floor([Environment]::ProcessorCount / 2))
    }
    if ($Scope -ne 'repo' -and ($Repos -or $AddRepos -or $RemoveRepos)) {
        Write-Error '-Repos, -AddRepos, and -RemoveRepos apply only to repo scope.'
    }
    if ($Scope -eq 'org' -and -not $OrgName) {
        Write-Error '-Scope org requires -OrgName.'
    }
    if ($Scope -eq 'ent' -and -not $EnterpriseName) {
        Write-Error '-Scope ent requires -EnterpriseName.'
    }
    if ($Scope -eq 'repo' -and $profileConfig.RunnerGroup) {
        Write-Error '-RunnerGroup requires org or ent scope.'
    }
    if (-not $Token -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        $Token = gh auth token 2>$null
    }
    if (-not $Token) {
        Write-Error 'No token: pass -Token <PAT>, or authenticate gh so Setup-Runner can use that token.'
    }

    $currentDesiredState = $null
    $currentDesiredReadError = $null
    if (Test-Path -LiteralPath $profileConfig.DesiredCapacityPath -PathType Leaf) {
        try {
            $storedDesiredState = Read-RunnerJsonFile -Path $profileConfig.DesiredCapacityPath
            if ([int]$storedDesiredState.schemaVersion -ne 1) {
                throw "Unsupported desired-capacity schema version '$($storedDesiredState.schemaVersion)'."
            }
            $storedReplicas = if (
                $storedDesiredState.PSObject.Properties['replicas'] -and
                $null -ne $storedDesiredState.replicas
            ) {
                [Nullable[int]][int]$storedDesiredState.replicas
            } else {
                $null
            }
            $currentDesiredState = New-RunnerDesiredCapacityState `
                -Generation ([int]$storedDesiredState.generation) `
                -Scope ([string]$storedDesiredState.scope) `
                -Repositories @(
                    @($storedDesiredState.repositories) |
                        ForEach-Object {
                            [PSCustomObject]@{
                                Url = [string]$_.url
                                Workers = [int]$_.workers
                            }
                        }
                ) `
                -Replicas $storedReplicas
        } catch {
            $currentDesiredReadError = $_.Exception.Message
        }
    }

    $repoList = @()
    if ($Scope -eq 'repo') {
        $repoList = @($Repos)
        if (($AddRepos -or $RemoveRepos) -and -not $Repos) {
            if ($currentDesiredState -and $currentDesiredState.scope -eq 'repo') {
                $repoList = @(
                    $currentDesiredState.repositories |
                        ForEach-Object { "$($_.url)=$($_.workers)" }
                )
            } elseif ($currentDesiredReadError) {
                Write-Error "Cannot apply -AddRepos or -RemoveRepos because existing desired capacity is unreadable. Pass the complete -Repos list. $currentDesiredReadError"
            } else {
                $legacyRepositories = Get-RunnerEnvironmentFileValue `
                    -Path $profileConfig.EnvironmentPath `
                    -Name 'REPO_URLS'
                if ([string]::IsNullOrWhiteSpace($legacyRepositories)) {
                    $legacyRepositories = Get-RunnerEnvironmentFileValue `
                        -Path $profileConfig.EnvironmentPath `
                        -Name 'REPO_URL'
                }
                if (-not [string]::IsNullOrWhiteSpace($legacyRepositories)) {
                    $repoList = @(
                        $legacyRepositories -split ',' |
                            ForEach-Object {
                                $legacyEntry = $_.Trim()
                                if ($legacyEntry) {
                                    if ($legacyEntry.LastIndexOf('=') -gt 0) {
                                        $legacyEntry
                                    } else {
                                        "$legacyEntry=1"
                                    }
                                }
                            }
                    )
                    Write-Host '  Imported repository targets from the pre-reconciliation profile environment.'
                }
            }
        }

        $removeUrls = @(
            $RemoveRepos |
                ForEach-Object {
                    $separator = $_.LastIndexOf('=')
                    if ($separator -gt 0) {
                        $_.Substring(0, $separator)
                    } else {
                        $_
                    }
                }
        )
        $repoCounts = @{}
        foreach ($entry in @($repoList) + @($AddRepos)) {
            if ([string]::IsNullOrWhiteSpace($entry)) {
                continue
            }

            $separator = $entry.LastIndexOf('=')
            $url = if ($separator -gt 0) {
                $entry.Substring(0, $separator).Trim()
            } else {
                $entry.Trim()
            }
            $count = $profileConfig.Replicas
            if ($separator -gt 0) {
                $countText = $entry.Substring($separator + 1)
                if (-not [int]::TryParse($countText, [ref]$count) -or $count -lt 1) {
                    Write-Error "Repository worker count must be a positive integer: '$entry'."
                }
            }
            if (-not $url) {
                Write-Error "Repository URL is missing in '$entry'."
            }
            if ($url -notin $removeUrls) {
                $repoCounts[$url] = $count
            }
        }
        $desiredRepositories = @(
            $repoCounts.Keys |
                Sort-Object |
                ForEach-Object {
                    [PSCustomObject]@{
                        Url = $_
                        Workers = [int]$repoCounts[$_]
                    }
                }
        )
        if ($desiredRepositories.Count -eq 0) {
            Write-Error '-Repos is required for repo scope (for example, -Repos https://github.com/me/a=2).'
        }
    } else {
        $desiredRepositories = @()
    }
    $total = if ($Scope -eq 'repo') {
        [int]($desiredRepositories | Measure-Object -Property Workers -Sum).Sum
    } else {
        [int]$profileConfig.Replicas
    }
    $desiredReplicas = if ($Scope -eq 'repo') {
        $null
    } else {
        [Nullable[int]][int]$profileConfig.Replicas
    }
    $desiredDraft = New-RunnerDesiredCapacityState `
        -Generation 1 `
        -Scope $Scope `
        -Repositories $desiredRepositories `
        -Replicas $desiredReplicas
    $desiredSignature = Get-RunnerDesiredCapacitySignature -State $desiredDraft
    $currentDesiredSignature = if ($currentDesiredState) {
        Get-RunnerDesiredCapacitySignature -State $currentDesiredState
    } else {
        $null
    }

    $acknowledgedGeneration = 0
    $acknowledgementValid = $false
    if (Test-Path -LiteralPath $profileConfig.CapacityAcknowledgementPath -PathType Leaf) {
        try {
            $storedAcknowledgement = Read-RunnerJsonFile -Path $profileConfig.CapacityAcknowledgementPath
            if (
                [int]$storedAcknowledgement.schemaVersion -eq 1 -and
                [string]$storedAcknowledgement.status -eq 'accepted' -and
                [int]$storedAcknowledgement.generation -gt 0
            ) {
                $acknowledgedGeneration = [int]$storedAcknowledgement.generation
                $acknowledgementValid = $true
            }
        } catch {
            $acknowledgedGeneration = 0
            $acknowledgementValid = $false
        }
    }
    $currentGeneration = if ($currentDesiredState) {
        [int]$currentDesiredState.generation
    } else {
        0
    }
    $generationBase = [math]::Max($currentGeneration, $acknowledgedGeneration)
    $acknowledgementCurrent = (
        $acknowledgementValid -and
        $acknowledgedGeneration -eq $currentGeneration
    )
    $desiredStateChanged = (
        -not $currentDesiredState -or
        $currentDesiredSignature -ne $desiredSignature -or
        $currentGeneration -lt $acknowledgedGeneration -or
        -not $acknowledgementCurrent
    )
    $nextGeneration = if ($desiredStateChanged) {
        $generationBase + 1
    } else {
        $currentGeneration
    }
    $desiredState = New-RunnerDesiredCapacityState `
        -Generation $nextGeneration `
        -Scope $Scope `
        -Repositories $desiredRepositories `
        -Replicas $desiredReplicas

    $environmentContent = New-RunnerEnvironmentContent `
        -Profile $profileConfig `
        -AccessToken $Token `
        -Scope $Scope `
        -OrgName $OrgName `
        -EnterpriseName $EnterpriseName
    $staticProfileState = New-RunnerStaticProfileState `
        -Profile $profileConfig `
        -Scope $Scope `
        -OrgName $OrgName `
        -EnterpriseName $EnterpriseName

    $managerRunning = Test-RunnerManagerRunning -ProfileConfig $profileConfig
    $environmentMatches = $false
    if (Test-Path -LiteralPath $profileConfig.EnvironmentPath -PathType Leaf) {
        $storedEnvironment = Get-Content -LiteralPath $profileConfig.EnvironmentPath -Raw -Encoding UTF8
        # Compare through the migration normalizer so that upgrading a profile
        # provisioned before the optional resource-limit knobs existed (limits
        # still unset) is not misread as drift, which would destructively
        # stop/replace the healthy, active runner pool below.
        $environmentMatches = (
            (ConvertTo-RunnerEnvironmentComparable -Content $storedEnvironment) -ceq
            (ConvertTo-RunnerEnvironmentComparable -Content $environmentContent)
        )
    }
    $staticProfileMatches = $false
    if (Test-Path -LiteralPath $profileConfig.StaticProfilePath -PathType Leaf) {
        try {
            $storedStaticProfile = Read-RunnerJsonFile -Path $profileConfig.StaticProfilePath
            $staticProfileMatches = (
                [int]$storedStaticProfile.schemaVersion -eq 1 -and
                [string]$storedStaticProfile.fingerprint -ceq [string]$staticProfileState.fingerprint
            )
        } catch {
            $staticProfileMatches = $false
        }
    }
    $capacityOnlyCompatible = (
        $managerRunning -and
        $environmentMatches -and
        $staticProfileMatches -and
        ($currentGeneration -gt 0 -or $acknowledgedGeneration -gt 0)
    )

    if ($capacityOnlyCompatible) {
        if ($desiredStateChanged) {
            Write-Host "[capacity] Publishing desired-capacity generation $nextGeneration"
            Write-RunnerJsonAtomically `
                -Path $profileConfig.DesiredCapacityPath `
                -Value $desiredState
            $acknowledgement = Wait-RunnerCapacityAcknowledgement `
                -ProfileConfig $profileConfig `
                -Generation $nextGeneration `
                -TimeoutSeconds 30

            $added = [int]$acknowledgement.addedSlots
            $draining = [int]$acknowledgement.drainingSlots
            $unchanged = [int]$acknowledgement.unchangedSlots
            if ([int]$acknowledgement.desiredSlots -ne $total) {
                throw "Manager acknowledged $($acknowledgement.desiredSlots) desired slots, but setup requested $total."
            }
            Write-Host "[done] Capacity-only change: adding $added worker(s), draining $draining worker(s), $unchanged unchanged; manager restart not required."
        } else {
            Wait-RunnerCapacityAcknowledgement `
                -ProfileConfig $profileConfig `
                -Generation $nextGeneration `
                -TimeoutSeconds 30 | Out-Null
            Write-Host "[done] Capacity unchanged: 0 added, 0 draining, $total unchanged; manager restart not required."
        }
        return
    }

    Write-Host "[image] Preparing runner image '$($profileConfig.Image)'"
    if ($profileConfig.Build) {
        $buildArguments = @(
            'build',
            '--file', $profileConfig.Build.Dockerfile,
            '--tag', $profileConfig.Image
        )
        foreach ($argument in $profileConfig.Build.Arguments.GetEnumerator()) {
            $buildArguments += @('--build-arg', "$($argument.Key)=$($argument.Value)")
        }
        $buildArguments += $profileConfig.Build.Context
        & docker @buildArguments
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Runner image build failed for profile '$($profileConfig.Name)'."
        }
    } elseif ($profileConfig.PullImage) {
        & docker pull $profileConfig.Image
        if ($LASTEXITCODE -ne 0) {
            & docker image inspect $profileConfig.Image 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Runner image '$($profileConfig.Image)' could not be pulled and is not available locally."
            }
            Write-Warning "Pull failed for '$($profileConfig.Image)'; using the locally available image."
        }
    } else {
        Write-Host '  Profile uses a locally available prebuilt runner image.'
    }

    Write-Host "[verify] Verifying runner image contract"
    foreach ($command in $profileConfig.VerificationCommands) {
        & docker run --rm --entrypoint /bin/sh $profileConfig.Image -lc $command
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Runner image verification failed for profile '$($profileConfig.Name)': $command"
        }
    }
    if ($profileConfig.VerificationCommands.Count -eq 0) {
        Write-Host '  Profile defines no runtime verification commands.'
    }

    Write-Host "[state] Staging static profile and desired capacity (workers=$total, scope=$Scope)"
    $stagedFiles = [System.Collections.Generic.List[object]]::new()
    try {
        $stagedFiles.Add([PSCustomObject]@{
            TemporaryPath = New-RunnerTextStagingFile `
                -Path $profileConfig.EnvironmentPath `
                -Value $environmentContent
            Path = $profileConfig.EnvironmentPath
        })
        $stagedFiles.Add([PSCustomObject]@{
            TemporaryPath = New-RunnerJsonStagingFile `
                -Path $profileConfig.StaticProfilePath `
                -Value $staticProfileState
            Path = $profileConfig.StaticProfilePath
        })
        $stagedFiles.Add([PSCustomObject]@{
            TemporaryPath = New-RunnerJsonStagingFile `
                -Path $profileConfig.DesiredCapacityPath `
                -Value $desiredState
            Path = $profileConfig.DesiredCapacityPath
        })

        if (-not $profileConfig.IsDefault -and -not $profileConfig.DisableDefaultLabels) {
            Write-Warning "Profile '$($profileConfig.Name)' retains GitHub's default labels, so jobs targeting only 'self-hosted' can run on it."
        }

        Write-Host "[replace] Replacing existing profile '$($profileConfig.Name)'"
        Stop-RunnerProfile -ProfileConfig $profileConfig

        foreach ($stagedFile in $stagedFiles) {
            Complete-RunnerStagedFile `
                -TemporaryPath $stagedFile.TemporaryPath `
                -Path $stagedFile.Path
            $stagedFile.TemporaryPath = $null
        }
        foreach ($managerStatePath in @(
            $profileConfig.CapacityAcknowledgementPath,
            $profileConfig.AcceptedCapacityPath
        )) {
            if (Test-Path -LiteralPath $managerStatePath) {
                Remove-Item -LiteralPath $managerStatePath -Force -ErrorAction Stop
            }
        }

        Write-Host "[start] Starting profile '$($profileConfig.Name)'"
        Invoke-RunnerCompose `
            -ProfileConfig $profileConfig `
            -CommandArguments @('up', '-d', '--build')
    }
    finally {
        foreach ($stagedFile in $stagedFiles) {
            if ($stagedFile.TemporaryPath) {
                Remove-Item `
                    -LiteralPath $stagedFile.TemporaryPath `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host "[done] $total worker(s) + 1 manager for profile '$($profileConfig.Name)'."
    Write-Host "  logs: docker compose --project-name $($profileConfig.ComposeProjectName) --env-file $([IO.Path]::GetFileName($profileConfig.EnvironmentPath)) logs -f"
    $stopSelector = if ($ProfilePath) {
        "-ProfilePath `"$ProfilePath`""
    } else {
        "-Profile $($profileConfig.Name)"
    }
    Write-Host "  stop: .\Setup-Runner.ps1 $stopSelector -Down"
}
finally {
    if ($profileLock) {
        $profileLock.Dispose()
    }
    Pop-Location
}
