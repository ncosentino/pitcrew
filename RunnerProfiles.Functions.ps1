#Requires -Version 7.0
Set-StrictMode -Version Latest

function ConvertTo-RunnerLabelList {
    param(
        [string[]]$Labels,
        [string]$RequiredLabel,
        [switch]$DisableDefaultLabels
    )

    $normalized = @(
        @($RequiredLabel) + @($Labels) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Sort-Object -Unique
    )

    foreach ($label in $normalized) {
        if ($label -notmatch '^[a-z0-9][a-z0-9._-]{0,62}$') {
            throw "Runner label '$label' must start with a letter or digit and contain only letters, digits, '.', '_', or '-'."
        }
    }

    if ($DisableDefaultLabels -and $normalized -contains 'self-hosted') {
        throw "An isolated profile cannot add the 'self-hosted' label because that would make broad self-hosted jobs eligible for the profile."
    }

    return @($normalized)
}

<#
.SYNOPSIS
    Resolves the effective configuration for one self-hosted runner profile.

.DESCRIPTION
    Loads an optional profile manifest, validates it against the committed schema,
    applies command-line overrides, and derives profile-specific state, Compose,
    routing, and Docker cleanup identifiers.

.PARAMETER RootPath
    Path to the PitCrew repository root.

.PARAMETER Profile
    Built-in profile name. The implicit default profile requires no manifest.

.PARAMETER ProfilePath
    Optional path to an external profile manifest.

.OUTPUTS
    PSCustomObject containing the effective profile configuration.
#>
function Resolve-RunnerProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [string]$Profile = 'default',

        [string]$ProfilePath = '',

        [Nullable[int]]$Replicas,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Labels,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$NamePrefix,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Image,

        [Nullable[bool]]$PullImage,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunnerGroup,

        [string]$HostName = 'runner'
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path
    $profileName = $Profile.Trim().ToLowerInvariant()
    if ($profileName -notmatch '^[a-z][a-z0-9-]{0,31}$') {
        throw "Profile '$Profile' must match ^[a-z][a-z0-9-]{0,31}$."
    }

    $manifest = $null
    $manifestPath = $null
    if ($ProfilePath) {
        $manifestPath = (Resolve-Path -LiteralPath $ProfilePath).Path
    } elseif ($profileName -ne 'default') {
        $candidate = Join-Path $resolvedRoot 'profiles' $profileName 'profile.json'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Runner profile '$profileName' was not found at '$candidate'. Pass -ProfilePath for an external profile."
        }
        $manifestPath = (Resolve-Path -LiteralPath $candidate).Path
    }

    $effectiveImage = 'myoung34/github-runner:ubuntu-noble'
    $effectiveReplicas = 1
    $effectiveLabels = @()
    $disableDefaultLabels = $false
    $effectiveRunnerGroup = ''
    $effectivePullImage = $true
    $verificationCommands = @()
    $build = $null

    if ($manifestPath) {
        $schemaPath = Join-Path $resolvedRoot 'runner-profile.schema.json'
        $manifestText = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
        if (-not ($manifestText | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)) {
            throw "Runner profile manifest '$manifestPath' does not conform to '$schemaPath'."
        }

        $manifest = $manifestText | ConvertFrom-Json -Depth 20
        $manifestName = ([string]$manifest.name).ToLowerInvariant()
        if ($profileName -ne 'default' -and $manifestName -ne $profileName) {
            throw "Runner profile name '$manifestName' does not match -Profile '$profileName'."
        }
        $profileName = $manifestName

        $effectiveImage = [string]$manifest.image
        $effectiveReplicas = [int]$manifest.replicas
        $effectiveLabels = @($manifest.labels)
        $disableDefaultLabels = if ($manifest.PSObject.Properties['disableDefaultLabels']) {
            [bool]$manifest.disableDefaultLabels
        } else {
            $true
        }
        $effectiveRunnerGroup = if ($manifest.PSObject.Properties['runnerGroup']) {
            [string]$manifest.runnerGroup
        } else {
            ''
        }
        $verificationCommands = if ($manifest.PSObject.Properties['verificationCommands']) {
            @($manifest.verificationCommands)
        } else {
            @()
        }

        if ($manifest.PSObject.Properties['build']) {
            $manifestDirectory = Split-Path -Parent $manifestPath
            $contextPath = Join-Path $manifestDirectory ([string]$manifest.build.context)
            if (-not (Test-Path -LiteralPath $contextPath -PathType Container)) {
                throw "Runner profile build context '$contextPath' does not exist."
            }
            $contextPath = (Resolve-Path -LiteralPath $contextPath).Path

            $dockerfilePath = Join-Path $contextPath ([string]$manifest.build.dockerfile)
            if (-not (Test-Path -LiteralPath $dockerfilePath -PathType Leaf)) {
                throw "Runner profile Dockerfile '$dockerfilePath' does not exist."
            }
            $dockerfilePath = (Resolve-Path -LiteralPath $dockerfilePath).Path

            $buildArguments = [ordered]@{}
            if ($manifest.build.PSObject.Properties['args']) {
                foreach ($property in $manifest.build.args.PSObject.Properties) {
                    if ($property.Name -match '(?i)(token|secret|password|credential|private.?key|api.?key)') {
                        throw "Runner profile build argument '$($property.Name)' looks secret-bearing. Secrets must be injected by workflows, never image builds."
                    }
                    $buildArguments[$property.Name] = [string]$property.Value
                }
            }

            $build = [PSCustomObject]@{
                Context = $contextPath
                Dockerfile = $dockerfilePath
                Arguments = $buildArguments
            }
            $effectivePullImage = $false
        }

        if ($manifest.PSObject.Properties['pullImage']) {
            $effectivePullImage = [bool]$manifest.pullImage
        }
    }

    if ($PSBoundParameters.ContainsKey('Replicas')) {
        $effectiveReplicas = [int]$Replicas
    }
    if ($effectiveReplicas -lt 0) {
        throw 'Replicas cannot be negative. Use 0 to auto-size or a positive worker count.'
    }

    if ($PSBoundParameters.ContainsKey('Image')) {
        $effectiveImage = $Image.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($effectiveImage) -or $effectiveImage -match '\s') {
        throw "Runner image '$effectiveImage' is not a valid non-empty image reference."
    }
    if ($PSBoundParameters.ContainsKey('PullImage')) {
        $effectivePullImage = [bool]$PullImage
    }

    if ($PSBoundParameters.ContainsKey('Labels')) {
        $effectiveLabels = @($Labels -split ',')
    }

    if ($PSBoundParameters.ContainsKey('RunnerGroup')) {
        $effectiveRunnerGroup = $RunnerGroup.Trim()
    }
    if ($effectiveRunnerGroup -match '[\r\n]') {
        throw 'Runner group cannot contain a newline.'
    }

    $requiredLabel = if ($profileName -eq 'default') { 'general-purpose' } else { $profileName }
    $labelList = ConvertTo-RunnerLabelList `
        -Labels $effectiveLabels `
        -RequiredLabel $requiredLabel `
        -DisableDefaultLabels:$disableDefaultLabels

    $normalizedHostName = ($HostName.ToLowerInvariant() -replace '[^a-z0-9.-]', '-')
    $normalizedHostName = $normalizedHostName -replace '^-+|-+$', ''
    if (-not $normalizedHostName) {
        $normalizedHostName = 'runner'
    }

    $effectiveNamePrefix = if ($PSBoundParameters.ContainsKey('NamePrefix')) {
        $NamePrefix.Trim()
    } elseif ($profileName -eq 'default') {
        $normalizedHostName
    } else {
        "$normalizedHostName-$profileName"
    }
    if ($effectiveNamePrefix -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') {
        throw "Runner name prefix '$effectiveNamePrefix' is not Docker-name safe."
    }

    $isDefault = $profileName -eq 'default'
    $environmentPath = if ($isDefault) {
        Join-Path $resolvedRoot '.env'
    } else {
        Join-Path $resolvedRoot ".env.$profileName"
    }
    $composeProjectName = if ($isDefault) {
        'self-hosted-runner'
    } else {
        "self-hosted-runner-$profileName"
    }

    return [PSCustomObject]@{
        Name = $profileName
        IsDefault = $isDefault
        ManifestPath = $manifestPath
        EnvironmentPath = $environmentPath
        ComposeProjectName = $composeProjectName
        ManagedRunnerLabel = "ephemeral-managed-runner-profile=$profileName"
        Image = $effectiveImage
        Replicas = $effectiveReplicas
        Labels = @($labelList)
        LabelsValue = $labelList -join ','
        DisableDefaultLabels = $disableDefaultLabels
        RunnerGroup = $effectiveRunnerGroup
        NamePrefix = $effectiveNamePrefix
        VerificationCommands = @($verificationCommands)
        Build = $build
        PullImage = $effectivePullImage
    }
}

<#
.SYNOPSIS
    Creates the Docker Compose environment content for a resolved runner profile.

.PARAMETER Profile
    Effective profile returned by Resolve-RunnerProfile.

.PARAMETER AccessToken
    Registration token written only to the gitignored profile environment file.

.OUTPUTS
    Newline-delimited Docker Compose environment content.
#>
function New-RunnerEnvironmentContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [string]$RepoUrls = '',

        [ValidateSet('repo', 'org', 'ent')]
        [string]$Scope = 'repo',

        [string]$OrgName = '',

        [string]$EnterpriseName = ''
    )

    $values = @(
        $AccessToken,
        $RepoUrls,
        $Scope,
        $OrgName,
        $EnterpriseName,
        $Profile.Name,
        $Profile.Image,
        $Profile.NamePrefix,
        $Profile.LabelsValue,
        $Profile.RunnerGroup
    )
    if ($values | Where-Object { $_ -match '[\r\n]' }) {
        throw 'Runner environment values cannot contain newlines.'
    }

    $disableDefaultLabels = if ($Profile.DisableDefaultLabels) { '1' } else { '' }
    return @(
        "ACCESS_TOKEN=$AccessToken"
        "REPO_URLS=$RepoUrls"
        "RUNNER_SCOPE=$Scope"
        "ORG_NAME=$OrgName"
        "ENTERPRISE_NAME=$EnterpriseName"
        "RUNNER_PROFILE_ID=$($Profile.Name)"
        "RUNNER_REPLICAS=$($Profile.Replicas)"
        "RUNNER_IMAGE=$($Profile.Image)"
        "RUNNER_PULL_IMAGE=0"
        "RUNNER_NAME_PREFIX=$($Profile.NamePrefix)"
        "RUNNER_LABELS=$($Profile.LabelsValue)"
        "RUNNER_NO_DEFAULT_LABELS=$disableDefaultLabels"
        "RUNNER_GROUP=$($Profile.RunnerGroup)"
    ) -join "`n"
}
