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
    omitted, reuses the selected profile's stored token before trying the
    authenticated gh CLI token. Written only to the selected profile's
    gitignored environment file.

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

.PARAMETER Autoscale
    Enable demand-driven GitHub runner scale-set mode for the selected profile.
    Configured worker counts become maximums rather than always-running slots.

.PARAMETER MinimumIdle
    Warm idle runners retained by an autoscaled target. Defaults to zero.

.PARAMETER ScaleDownDelaySeconds
    Time demand must remain below active capacity before excess idle runners are
    removed. Defaults to 120 seconds.

.PARAMETER Profile
    Built-in profile name. Defaults to the backward-compatible default profile.

.PARAMETER ProfilePath
    Path to an external profile manifest. Relative build paths resolve from the
    manifest directory.

.PARAMETER Down
    Stop only the selected profile.

.PARAMETER Refresh
    Build and hot-swap the selected profile manager while preserving an
    otherwise unchanged worker profile and any active jobs.

.PARAMETER CapacityOnly
    Require an in-place capacity reconciliation. Setup fails instead of
    replacing the selected profile when its manager or static configuration is
    not compatible with a capacity-only update.

.EXAMPLE
    .\Setup-Runner.ps1 -Repos https://github.com/me/repo-a

.EXAMPLE
    .\Setup-Runner.ps1 -Profile copilot-cli -Repos https://github.com/me/repo-a

.EXAMPLE
    .\Setup-Runner.ps1 -Profile copilot-cli -Down

.EXAMPLE
    .\Setup-Runner.ps1 -Profile copilot-cli -Repos https://github.com/me/repo-a -Refresh

.EXAMPLE
    .\Setup-Runner.ps1 -Profile copilot-cli -AddRepos https://github.com/me/repo-a=4 -CapacityOnly

.EXAMPLE
    .\Setup-Runner.ps1 -Profile copilot-cli -Autoscale -MinimumIdle 0 -Repos https://github.com/me/repo-a=30
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
    [switch]$Autoscale,
    [Nullable[int]]$MinimumIdle,
    [Nullable[int]]$ScaleDownDelaySeconds,
    [string]$Profile = 'default',
    [string]$ProfilePath = '',
    [switch]$Down,
    [switch]$Refresh,
    [switch]$CapacityOnly
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
foreach ($parameterName in @(
    'Replicas',
    'Labels',
    'NamePrefix',
    'Image',
    'PullImage',
    'RunnerGroup',
    'Autoscale',
    'MinimumIdle',
    'ScaleDownDelaySeconds'
)) {
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
    'PITCREW_WORKER_REVISION',
    'PITCREW_SESSION_OWNER',
    'PITCREW_ASSUME_UNVERSIONED_CURRENT',
    'PITCREW_AUTOSCALING_MODE',
    'PITCREW_AUTOSCALING_MIN_IDLE',
    'PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS',
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

    $shutdownRequestWritten = $false
    try {
        $managerContainerId = Get-RunnerManagerContainerId -ProfileConfig $ProfileConfig
        $managerContract = if ($managerContainerId) {
            Get-RunnerManagerContractVersion -ContainerId $managerContainerId
        } else {
            0
        }
        if (
            $managerContract -ge 9 -and
            -not [string]::IsNullOrWhiteSpace($managerContainerId)
        ) {
            Write-RunnerJsonAtomically `
                -Path $ProfileConfig.ShutdownRequestPath `
                -Value ([PSCustomObject][ordered]@{
                    schemaVersion = 1
                    managerContainerId = $managerContainerId
                    requestedAt = [DateTime]::UtcNow.ToString('o')
                })
            $shutdownRequestWritten = $true
        }

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
    finally {
        if ($shutdownRequestWritten -or (Test-Path -LiteralPath $ProfileConfig.ShutdownRequestPath)) {
            Remove-Item `
                -LiteralPath $ProfileConfig.ShutdownRequestPath `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Get-RunnerManagerContainerId {
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
    if ($managerIds.Count -gt 1) {
        throw "Profile '$($ProfileConfig.Name)' has multiple running manager containers."
    }
    if ($managerIds.Count -eq 0) {
        return $null
    }
    return [string]$managerIds[0]
}

function Get-RunnerManagerContractVersion {
    param(
        [Parameter(Mandatory)]
        [string]$ContainerId
    )

    $contractOutput = & docker inspect `
        --format '{{ index .Config.Labels "pitcrew-manager-contract-version" }}' `
        $ContainerId 2>$null
    if ($LASTEXITCODE -ne 0) {
        return 0
    }
    $managerContract = 0
    [void][int]::TryParse(([string]$contractOutput).Trim(), [ref]$managerContract)
    return $managerContract
}

function Test-RunnerManagerRunning {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ProfileConfig
    )

    return -not [string]::IsNullOrWhiteSpace(
        (Get-RunnerManagerContainerId -ProfileConfig $ProfileConfig)
    )
}

function Get-RunnerObservedManager {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ProfileConfig
    )

    if (-not (Test-Path -LiteralPath $ProfileConfig.ObservedStatePath -PathType Leaf)) {
        return $null
    }
    try {
        $observed = Read-RunnerJsonFile -Path $ProfileConfig.ObservedStatePath
        if (
            [int]$observed.schemaVersion -ne 1 -or
            [string]$observed.profileId -cne [string]$ProfileConfig.Name
        ) {
            return $null
        }
        return $observed
    } catch {
        return $null
    }
}

function Get-RunnerSessionOwner {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ProfileConfig,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$ObservedManager
    )

    if (Test-Path -LiteralPath $ProfileConfig.SessionOwnerPath -PathType Leaf) {
        $stored = (
            Get-Content -LiteralPath $ProfileConfig.SessionOwnerPath -Raw -Encoding UTF8
        ).Trim()
        if ($stored -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$') {
            throw "Stored manager session owner for profile '$($ProfileConfig.Name)' is invalid."
        }
        return $stored
    }

    if (
        $ObservedManager -and
        -not [string]::IsNullOrWhiteSpace([string]$ObservedManager.managerInstanceId)
    ) {
        $legacyOwner = [string]$ObservedManager.managerInstanceId
        if ($legacyOwner -match '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$') {
            return $legacyOwner
        }
    }

    return "pitcrew-$($ProfileConfig.Name)-$([guid]::NewGuid().ToString('N'))"
}

function Stop-RunnerManagerForHandoff {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ProfileConfig,

        [Parameter(Mandatory)]
        [string]$ContainerId
    )

    $managerContract = Get-RunnerManagerContractVersion -ContainerId $ContainerId
    $supportsHandoff = $managerContract -ge 9
    if ($supportsHandoff) {
        Write-Host "[handoff] Stopping manager '$ContainerId' while preserving profile workers"
        & docker stop --time 60 $ContainerId 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Manager '$ContainerId' did not stop cleanly for handoff."
        }
        return
    }

    Write-Host "[handoff] Removing legacy manager '$ContainerId' without signaling its destructive shutdown path"
    & docker update --restart=no $ContainerId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to disable restart policy for legacy manager '$ContainerId'."
    }
    & docker rm -f $ContainerId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove legacy manager '$ContainerId' for handoff."
    }
}

function Restore-RunnerImageTag {
    param(
        [Parameter(Mandatory)]
        [string]$ImageId,

        [Parameter(Mandatory)]
        [string]$Image
    )

    & docker tag $ImageId $Image
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restore worker image '$Image' to '$ImageId'."
    }
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
        [int]$TimeoutSeconds,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$MinimumManagerContractVersion
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
                $acknowledgedContract = [int]$acknowledgement.managerContractVersion
                if (
                    $acknowledgedGeneration -eq $Generation -and
                    $acknowledgedContract -ge $MinimumManagerContractVersion
                ) {
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
    throw "Manager for profile '$($ProfileConfig.Name)' did not acknowledge desired-capacity generation $Generation with contract $MinimumManagerContractVersion or newer within $TimeoutSeconds seconds.$detail"
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

function Get-RunnerRegistrationAccessValidation {
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [ValidateSet('repo', 'org', 'ent')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Repositories,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$OrgName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$EnterpriseName
    )

    $targets = switch ($Scope) {
        'repo' {
            foreach ($repository in $Repositories) {
                $repositoryUri = [Uri][string]$repository.Url
                if (
                    $repositoryUri.Scheme -ne 'https' -or
                    $repositoryUri.Host -ne 'github.com'
                ) {
                    return [PSCustomObject]@{
                        IsValid = $false
                        Target = [string]$repository.Url
                        Reason = 'Automatic registration-token validation accepts only HTTPS github.com repository URLs.'
                    }
                }
                $pathSegments = @(
                    $repositoryUri.AbsolutePath.Trim('/') -split '/' |
                        Where-Object { $_ }
                )
                if ($pathSegments.Count -ne 2) {
                    return [PSCustomObject]@{
                        IsValid = $false
                        Target = [string]$repository.Url
                        Reason = 'Repository URLs must identify one owner and repository.'
                    }
                }
                $owner = [Uri]::EscapeDataString($pathSegments[0])
                $repositoryName = [Uri]::EscapeDataString(
                    ($pathSegments[1] -replace '\.git$', ''))
                [PSCustomObject]@{
                    Name = [string]$repository.Url
                    Uri = "https://api.github.com/repos/$owner/$repositoryName/actions/runners/registration-token"
                }
            }
        }
        'org' {
            [PSCustomObject]@{
                Name = "organization '$OrgName'"
                Uri = "https://api.github.com/orgs/$([Uri]::EscapeDataString($OrgName))/actions/runners/registration-token"
            }
        }
        'ent' {
            [PSCustomObject]@{
                Name = "enterprise '$EnterpriseName'"
                Uri = "https://api.github.com/enterprises/$([Uri]::EscapeDataString($EnterpriseName))/actions/runners/registration-token"
            }
        }
    }

    $headers = @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $Token"
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'PitCrew'
    }
    foreach ($target in $targets) {
        try {
            $response = Invoke-RestMethod `
                -Method Post `
                -Uri $target.Uri `
                -Headers $headers `
                -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace([string]$response.token)) {
                return [PSCustomObject]@{
                    IsValid = $false
                    Target = $target.Name
                    Reason = 'GitHub returned no registration token.'
                }
            }
        } catch {
            return [PSCustomObject]@{
                IsValid = $false
                Target = $target.Name
                Reason = $_.Exception.Message
            }
        }
    }

    return [PSCustomObject]@{
        IsValid = $true
        Target = ''
        Reason = ''
    }
}

Push-Location $here
$profileLock = $null
try {
    New-Item -ItemType Directory -Path $profileConfig.StateDirectory -Force | Out-Null
    $profileLock = Enter-RunnerProfileLock -Path $profileConfig.LockPath -TimeoutSeconds 30

    if ($Down) {
        if ($Refresh -or $CapacityOnly) {
            Write-Error '-Down cannot be combined with -Refresh or -CapacityOnly.'
        }
        Write-Host "[stop] Stopping profile '$($profileConfig.Name)'"
        Stop-RunnerProfile -ProfileConfig $profileConfig
        Write-Host "[done] Profile '$($profileConfig.Name)' stopped. Other profiles were not changed."
        return
    }

    Write-Host "[resolve] Resolving workers, targets, and registration credentials"
    $tokenSource = if ($Token) { 'parameter' } else { '' }
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
    if (-not $Token) {
        $Token = Get-RunnerEnvironmentFileValue `
            -Path $profileConfig.EnvironmentPath `
            -Name 'ACCESS_TOKEN'
        if ($Token) {
            $tokenSource = 'stored'
            Write-Host '  Reusing the selected profile registration token.'
        }
    }
    if (-not $Token -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        $Token = gh auth token 2>$null
        if ($Token) {
            $tokenSource = 'gh'
        }
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
    $registrationAccess = Get-RunnerRegistrationAccessValidation `
        -Token $Token `
        -Scope $Scope `
        -Repositories @($desiredDraft.repositories) `
        -OrgName $OrgName `
        -EnterpriseName $EnterpriseName
    if (-not $registrationAccess.IsValid) {
        $sourceDescription = if ($tokenSource -eq 'stored') {
            'The selected profile stored token'
        } else {
            'The supplied registration token'
        }
        throw "$sourceDescription does not have runner registration access for $($registrationAccess.Target). Pass a valid -Token or update GitHub CLI authentication. $($registrationAccess.Reason)"
    }

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

    $staticProfileState = New-RunnerStaticProfileState `
        -Profile $profileConfig `
        -Scope $Scope `
        -OrgName $OrgName `
        -EnterpriseName $EnterpriseName

    $managerContainerId = Get-RunnerManagerContainerId -ProfileConfig $profileConfig
    $managerRunning = -not [string]::IsNullOrWhiteSpace($managerContainerId)
    $observedManager = Get-RunnerObservedManager -ProfileConfig $profileConfig
    $sessionOwner = Get-RunnerSessionOwner `
        -ProfileConfig $profileConfig `
        -ObservedManager $observedManager
    $storedWorkerRevision = Get-RunnerEnvironmentFileValue `
        -Path $profileConfig.EnvironmentPath `
        -Name 'PITCREW_WORKER_REVISION'
    $storedAssumeUnversioned = Get-RunnerEnvironmentFileValue `
        -Path $profileConfig.EnvironmentPath `
        -Name 'PITCREW_ASSUME_UNVERSIONED_CURRENT'
    $assumeUnversionedCurrent = (
        (
            $storedAssumeUnversioned -eq '1' -and
            $storedWorkerRevision -ceq [string]$staticProfileState.workerRevision
        ) -or (
            $Refresh -and
            $managerRunning -and
            [string]::IsNullOrWhiteSpace($storedWorkerRevision)
        )
    )
    $environmentContent = New-RunnerEnvironmentContent `
        -Profile $profileConfig `
        -AccessToken $Token `
        -WorkerRevision ([string]$staticProfileState.workerRevision) `
        -SessionOwner $sessionOwner `
        -AssumeUnversionedCurrent $assumeUnversionedCurrent `
        -Scope $Scope `
        -OrgName $OrgName `
        -EnterpriseName $EnterpriseName

    $environmentMatches = (
        (Test-Path -LiteralPath $profileConfig.EnvironmentPath -PathType Leaf) -and
        (Get-Content -LiteralPath $profileConfig.EnvironmentPath -Raw -Encoding UTF8) -ceq $environmentContent
    )
    $storedStaticProfile = $null
    $staticProfileMatches = $false
    $refreshConfigurationMatches = $false
    $rollingConfigurationMatches = $false
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
        $refreshConfigurationMatches = (
            $null -ne $storedStaticProfile -and
            $storedStaticProfile.PSObject.Properties['configuration'] -and
            (
                Get-RunnerObjectFingerprint -Value (
                    Get-RunnerWorkerConfiguration `
                        -Configuration $storedStaticProfile.configuration
                )
            ) -ceq [string]$staticProfileState.workerRevision
        )
        $rollingConfigurationMatches = (
            $null -ne $storedStaticProfile -and
            $storedStaticProfile.PSObject.Properties['configuration'] -and
            (
                Get-RunnerObjectFingerprint -Value (
                    Get-RunnerRollingCompatibilityConfiguration `
                        -Configuration $storedStaticProfile.configuration
                )
            ) -ceq (
                Get-RunnerObjectFingerprint -Value (
                    Get-RunnerRollingCompatibilityConfiguration `
                        -Configuration $staticProfileState.configuration
                )
            )
        )
    }
    if ($Refresh -and $CapacityOnly) {
        throw '-Refresh and -CapacityOnly cannot be used together.'
    }
    if ($Refresh -and -not $refreshConfigurationMatches) {
        throw '-Refresh can update the manager only when the worker profile configuration is otherwise unchanged. Apply worker image, labels, scope, or other static changes separately.'
    }
    if ($Refresh -and -not $managerRunning) {
        throw "Profile '$($profileConfig.Name)' is not running. Refresh will not start a stopped profile."
    }
    if (
        -not $Refresh -and
        $managerRunning -and
        -not $staticProfileMatches -and
        -not $rollingConfigurationMatches
    ) {
        throw "Profile '$($profileConfig.Name)' changes registration topology or routing that cannot roll safely. Stop the profile explicitly with -Down before applying this configuration."
    }
    if ($Refresh) {
        & docker image inspect $profileConfig.Image 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Runner image '$($profileConfig.Image)' is not available. Run the complete setup command without -Refresh to prepare it."
        }
    }
    $capacityOnlyCompatible = (
        -not $Refresh -and
        $managerRunning -and
        $environmentMatches -and
        $staticProfileMatches -and
        ($currentGeneration -gt 0 -or $acknowledgedGeneration -gt 0)
    )
    if ($CapacityOnly -and -not $capacityOnlyCompatible) {
        throw "Capacity-only update cannot proceed for profile '$($profileConfig.Name)' because its manager, environment, static configuration, or acknowledged state is not current."
    }

    if ($capacityOnlyCompatible) {
        if ($desiredStateChanged) {
            Write-Host "[capacity] Publishing desired-capacity generation $nextGeneration"
            Write-RunnerJsonAtomically `
                -Path $profileConfig.DesiredCapacityPath `
                -Value $desiredState
            $acknowledgement = Wait-RunnerCapacityAcknowledgement `
                -ProfileConfig $profileConfig `
                -Generation $nextGeneration `
                -TimeoutSeconds 30 `
                -MinimumManagerContractVersion 1

            $added = [int]$acknowledgement.addedSlots
            $draining = [int]$acknowledgement.drainingSlots
            $unchanged = [int]$acknowledgement.unchangedSlots
            if ([int]$acknowledgement.desiredSlots -ne $total) {
                throw "Manager acknowledged $($acknowledgement.desiredSlots) desired slots, but setup requested $total."
            }
            if (
                $acknowledgement.PSObject.Properties['activationMode'] -and
                [string]$acknowledgement.activationMode -eq 'autoscaled'
            ) {
                $active = [int]$acknowledgement.activeSlots
                $minimumIdle = [int]$acknowledgement.minimumIdleSlots
                Write-Host "[done] Autoscaling maximum updated to $total worker(s): $active active, minimum idle $minimumIdle; manager restart not required."
            } else {
                Write-Host "[done] Capacity-only change: adding $added worker(s), draining $draining worker(s), $unchanged unchanged; manager restart not required."
            }
        } else {
            $acknowledgement = Wait-RunnerCapacityAcknowledgement `
                -ProfileConfig $profileConfig `
                -Generation $nextGeneration `
                -TimeoutSeconds 30 `
                -MinimumManagerContractVersion 1
            if (
                $acknowledgement.PSObject.Properties['activationMode'] -and
                [string]$acknowledgement.activationMode -eq 'autoscaled'
            ) {
                Write-Host "[done] Autoscaling maximum unchanged at $total worker(s): $([int]$acknowledgement.activeSlots) active; manager restart not required."
            } else {
                Write-Host "[done] Capacity unchanged: 0 added, 0 draining, $total unchanged; manager restart not required."
            }
        }
        return
    }

    $previousWorkerImage = if (
        $storedStaticProfile -and
        $storedStaticProfile.PSObject.Properties['configuration']
    ) {
        [string]$storedStaticProfile.configuration.image
    } else {
        ''
    }
    $previousWorkerImageId = $null
    if (
        $managerRunning -and
        -not [string]::IsNullOrWhiteSpace($previousWorkerImage)
    ) {
        $workerImageOutput = & docker image inspect `
            --format '{{.Id}}' `
            $previousWorkerImage 2>$null
        if ($LASTEXITCODE -eq 0) {
            $previousWorkerImageId = ([string]$workerImageOutput).Trim()
        } elseif ($previousWorkerImage -ceq [string]$profileConfig.Image) {
            throw "Cannot record the current worker image '$previousWorkerImage' before replacing its tag."
        }
    }

    if ($Refresh) {
        Write-Host "[image] Reusing the unchanged runner image '$($profileConfig.Image)'"
    } else {
        try {
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
            if ($profileConfig.Autoscaling) {
                & docker run `
                    --rm `
                    --entrypoint /bin/sh `
                    $profileConfig.Image `
                    -lc 'test -x /actions-runner/bin/Runner.Listener && id runner >/dev/null'
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Runner image '$($profileConfig.Image)' does not satisfy the scale-set JIT runtime contract."
                }
            }
        }
        catch {
            $imagePreparationError = $_
            if ($previousWorkerImageId) {
                try {
                    Restore-RunnerImageTag `
                        -ImageId $previousWorkerImageId `
                        -Image $previousWorkerImage
                } catch {
                    throw "Worker image preparation failed: $($imagePreparationError.Exception.Message) Worker image rollback also failed: $($_.Exception.Message)"
                }
            }
            throw
        }
    }

    Write-Host "[state] Staging static profile and desired capacity (workers=$total, scope=$Scope)"
    $stagedFiles = [System.Collections.Generic.List[object]]::new()
    $rollbackFiles = [System.Collections.Generic.List[object]]::new()
    foreach ($rollbackPath in @(
        $profileConfig.EnvironmentPath,
        $profileConfig.StaticProfilePath,
        $profileConfig.DesiredCapacityPath,
        $profileConfig.SessionOwnerPath,
        $profileConfig.CapacityAcknowledgementPath
    )) {
        $exists = Test-Path -LiteralPath $rollbackPath -PathType Leaf
        $rollbackFiles.Add([PSCustomObject]@{
            Path = $rollbackPath
            Exists = $exists
            Content = if ($exists) {
                Get-Content -LiteralPath $rollbackPath -Raw -Encoding UTF8
            } else {
                $null
            }
        })
    }
    $previousManagerContract = if ($managerRunning) {
        Get-RunnerManagerContractVersion -ContainerId $managerContainerId
    } else {
        0
    }
    $previousManagerImageId = $null
    if ($managerRunning -and $previousManagerContract -ge 9) {
        $previousManagerImageId = (
            & docker inspect --format '{{.Image}}' $managerContainerId 2>$null
        ).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($previousManagerImageId)) {
            throw "Cannot record the current manager image for profile '$($profileConfig.Name)' before handoff."
        }
    }
    $managerStoppedForHandoff = $false
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
        $stagedFiles.Add([PSCustomObject]@{
            TemporaryPath = New-RunnerTextStagingFile `
                -Path $profileConfig.SessionOwnerPath `
                -Value "$sessionOwner`n"
            Path = $profileConfig.SessionOwnerPath
        })

        if (-not $profileConfig.IsDefault -and -not $profileConfig.DisableDefaultLabels) {
            Write-Warning "Profile '$($profileConfig.Name)' retains GitHub's default labels, so jobs targeting only 'self-hosted' can run on it."
        }

        if ($Refresh) {
            Write-Host "[refresh] Building a replacement manager for profile '$($profileConfig.Name)'"
        } else {
            Write-Host "[replace] Building a rolling replacement for profile '$($profileConfig.Name)'"
        }
        $stagedEnvironment = $stagedFiles |
            Where-Object { $_.Path -ceq $profileConfig.EnvironmentPath } |
            Select-Object -First 1
        $buildProfileConfig = $profileConfig.PSObject.Copy()
        $buildProfileConfig.EnvironmentPath = $stagedEnvironment.TemporaryPath
        Invoke-RunnerCompose `
            -ProfileConfig $buildProfileConfig `
            -CommandArguments @('build', 'runner-manager')

        if ($managerRunning) {
            Stop-RunnerManagerForHandoff `
                -ProfileConfig $profileConfig `
                -ContainerId $managerContainerId
            $managerStoppedForHandoff = $true
        }

        foreach ($stagedFile in $stagedFiles) {
            Complete-RunnerStagedFile `
                -TemporaryPath $stagedFile.TemporaryPath `
                -Path $stagedFile.Path
            $stagedFile.TemporaryPath = $null
        }
        foreach ($managerStatePath in @(
            $profileConfig.CapacityAcknowledgementPath
        )) {
            if (Test-Path -LiteralPath $managerStatePath) {
                Remove-Item -LiteralPath $managerStatePath -Force -ErrorAction Stop
            }
        }

        Write-Host "[start] Starting profile '$($profileConfig.Name)'"
        Invoke-RunnerCompose `
            -ProfileConfig $profileConfig `
            -CommandArguments @(
                'up',
                '-d',
                '--no-deps',
                '--force-recreate',
                'runner-manager'
            )

        if ($managerRunning) {
            $acknowledgement = Wait-RunnerCapacityAcknowledgement `
                -ProfileConfig $profileConfig `
                -Generation $nextGeneration `
                -TimeoutSeconds 60 `
                -MinimumManagerContractVersion $profileConfig.ManagerContractVersion
        }
    }
    catch {
        $updateError = $_
        if ($previousWorkerImageId -and -not $managerStoppedForHandoff) {
            try {
                Restore-RunnerImageTag `
                    -ImageId $previousWorkerImageId `
                    -Image $previousWorkerImage
            } catch {
                throw "Manager update failed before handoff: $($updateError.Exception.Message) Worker image rollback also failed: $($_.Exception.Message)"
            }
        }
        if ($managerRunning -and $managerStoppedForHandoff) {
            if ($previousManagerContract -ge 9 -and $previousManagerImageId) {
                $rollbackError = $null
                try {
                    $currentManagerId = Get-RunnerManagerContainerId -ProfileConfig $profileConfig
                    if ($currentManagerId) {
                        Stop-RunnerManagerForHandoff `
                            -ProfileConfig $profileConfig `
                            -ContainerId $currentManagerId
                    }
                    if ($previousWorkerImageId) {
                        Restore-RunnerImageTag `
                            -ImageId $previousWorkerImageId `
                            -Image $previousWorkerImage
                    }
                    foreach ($rollbackFile in $rollbackFiles) {
                        if ($rollbackFile.Exists) {
                            $rollbackTemporary = New-RunnerTextStagingFile `
                                -Path $rollbackFile.Path `
                                -Value $rollbackFile.Content
                            Complete-RunnerStagedFile `
                                -TemporaryPath $rollbackTemporary `
                                -Path $rollbackFile.Path
                        } elseif (Test-Path -LiteralPath $rollbackFile.Path) {
                            Remove-Item -LiteralPath $rollbackFile.Path -Force -ErrorAction Stop
                        }
                    }
                    & docker tag `
                        $previousManagerImageId `
                        "ephemeral-runner-manager:profile-$($profileConfig.Name)"
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to restore the previous manager image tag."
                    }
                    Invoke-RunnerCompose `
                        -ProfileConfig $profileConfig `
                        -CommandArguments @(
                            'up',
                            '-d',
                            '--no-deps',
                            '--force-recreate',
                            'runner-manager'
                        )
                } catch {
                    $rollbackError = $_.Exception.Message
                }
                if ($rollbackError) {
                    throw "Manager update failed: $($updateError.Exception.Message) Rollback also failed: $rollbackError"
                }
            } else {
                if ($previousWorkerImageId) {
                    try {
                        Restore-RunnerImageTag `
                            -ImageId $previousWorkerImageId `
                            -Image $previousWorkerImage
                    } catch {
                        throw "Manager update failed after the legacy manager was removed: $($updateError.Exception.Message) Existing workers were preserved, and worker image rollback also failed: $($_.Exception.Message)"
                    }
                }
                throw "Manager update failed after the legacy manager was removed: $($updateError.Exception.Message) Existing workers were preserved, but the legacy manager was not restarted because its startup cleanup would remove them."
            }
        }
        throw
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

    if ($profileConfig.Autoscaling) {
        Write-Host "[done] Autoscaling manager for profile '$($profileConfig.Name)': maximum $total worker(s), minimum idle $($profileConfig.Autoscaling.MinimumIdle)."
    } else {
        Write-Host "[done] $total worker(s) + 1 manager for profile '$($profileConfig.Name)'."
    }
    $updatedObserved = Get-RunnerObservedManager -ProfileConfig $profileConfig
    if (
        $updatedObserved -and
        $updatedObserved.PSObject.Properties['update'] -and
        [string]$updatedObserved.update.status -eq 'rolling'
    ) {
        Write-Host (
            "  rollout: $([int]$updatedObserved.update.currentWorkers) current, " +
            "$([int]$updatedObserved.update.staleWorkers) stale worker(s) still converging"
        )
    }
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
