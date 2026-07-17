#Requires -Version 7.0
<#
.SYNOPSIS
    Provision, update, or stop an isolated self-hosted runner profile.

.DESCRIPTION
    Idempotent setup for the truly-ephemeral runner pool in this folder. Existing
    invocations target the implicit default profile. Named profiles add distinct
    images, labels, replica defaults, verification checks, Compose projects,
    environment files, and Docker cleanup labels without duplicating the manager.

    Each run converges only the selected profile:
      1. Resolves and validates repository targets and credentials.
      2. Builds the profile image when its manifest defines a build.
      3. Verifies the image contract.
      4. Writes the selected profile's gitignored environment file.
      5. Replaces only that profile's existing manager and runners.
      6. Starts that profile's manager.

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
    'RUNNER_GROUP'
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

Push-Location $here
try {
    if ($Down) {
        Write-Host "[1/1] Stopping profile '$($profileConfig.Name)'"
        Stop-RunnerProfile -ProfileConfig $profileConfig
        Write-Host "[done] Profile '$($profileConfig.Name)' stopped. Other profiles were not changed."
        return
    }

    Write-Host "[1/6] Resolving workers, targets, and registration credentials"
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

    $repoList = @()
    $repoUrls = ''
    if ($Scope -eq 'repo') {
        $repoList = @($Repos)
        if (($AddRepos -or $RemoveRepos) -and -not $Repos -and (Test-Path -LiteralPath $profileConfig.EnvironmentPath)) {
            $current = (
                Get-Content -LiteralPath $profileConfig.EnvironmentPath |
                    Where-Object { $_ -match '^REPO_URLS=' }
            ) -replace '^REPO_URLS=', ''
            $current = ([string]$current).Trim()
            if ($current) {
                $repoList = @($current -split ',')
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
        $repoList = @(
            $repoCounts.Keys |
                Sort-Object |
                ForEach-Object { "$_=$($repoCounts[$_])" }
        )
        $repoUrls = ($repoList -join ',').Trim()
        if (-not $repoUrls) {
            Write-Error '-Repos is required for repo scope (for example, -Repos https://github.com/me/a=2).'
        }
    }
    $total = if ($Scope -eq 'repo') {
        ($repoList | ForEach-Object { [int]($_ -split '=')[1] } | Measure-Object -Sum).Sum
    } else {
        $profileConfig.Replicas
    }

    Write-Host "[2/6] Preparing runner image '$($profileConfig.Image)'"
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

    Write-Host "[3/6] Verifying runner image contract"
    foreach ($command in $profileConfig.VerificationCommands) {
        & docker run --rm --entrypoint /bin/sh $profileConfig.Image -lc $command
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Runner image verification failed for profile '$($profileConfig.Name)': $command"
        }
    }
    if ($profileConfig.VerificationCommands.Count -eq 0) {
        Write-Host '  Profile defines no runtime verification commands.'
    }

    Write-Host "[4/6] Writing $([IO.Path]::GetFileName($profileConfig.EnvironmentPath)) (workers=$total, scope=$Scope)"
    $environmentContent = New-RunnerEnvironmentContent `
        -Profile $profileConfig `
        -AccessToken $Token `
        -RepoUrls $repoUrls `
        -Scope $Scope `
        -OrgName $OrgName `
        -EnterpriseName $EnterpriseName
    Set-Content `
        -LiteralPath $profileConfig.EnvironmentPath `
        -Value $environmentContent `
        -NoNewline `
        -Encoding UTF8

    if (-not $profileConfig.IsDefault -and -not $profileConfig.DisableDefaultLabels) {
        Write-Warning "Profile '$($profileConfig.Name)' retains GitHub's default labels, so jobs targeting only 'self-hosted' can run on it."
    }

    Write-Host "[5/6] Replacing existing profile '$($profileConfig.Name)'"
    Stop-RunnerProfile -ProfileConfig $profileConfig

    Write-Host "[6/6] Starting profile '$($profileConfig.Name)'"
    Invoke-RunnerCompose `
        -ProfileConfig $profileConfig `
        -CommandArguments @('up', '-d', '--build')

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
    Pop-Location
}
