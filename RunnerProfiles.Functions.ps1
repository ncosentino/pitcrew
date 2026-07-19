#Requires -Version 7.0
Set-StrictMode -Version Latest

$script:RunnerDesiredCapacitySchemaVersion = 1
$script:RunnerStaticProfileSchemaVersion = 1
$script:RunnerManagerContractVersion = 6

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
    $stateDirectory = Join-Path $resolvedRoot '.pitcrew-state' $profileName
    $stateVolumePath = ".pitcrew-state/$profileName"

    return [PSCustomObject]@{
        RootPath = $resolvedRoot
        Name = $profileName
        IsDefault = $isDefault
        ManifestPath = $manifestPath
        EnvironmentPath = $environmentPath
        StateDirectory = $stateDirectory
        StateVolumePath = $stateVolumePath
        DesiredCapacityPath = Join-Path $stateDirectory 'desired-capacity.json'
        AcceptedCapacityPath = Join-Path $stateDirectory 'last-valid-capacity.json'
        CapacityAcknowledgementPath = Join-Path $stateDirectory 'acknowledged-capacity.json'
        ObservedStatePath = Join-Path $stateDirectory 'observed-state.json'
        StaticProfilePath = Join-Path $stateDirectory 'static-profile.json'
        LockPath = Join-Path $stateDirectory 'setup.lock'
        ComposeProjectName = $composeProjectName
        ManagedRunnerLabel = "ephemeral-managed-runner-profile=$profileName"
        ManagerContractVersion = $script:RunnerManagerContractVersion
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
    Computes a conservative content fingerprint for a Docker build context.

.DESCRIPTION
    Hashes every directory, symbolic link target, and file content below the
    context except explicitly generated state paths. This may rebuild for files
    Docker later excludes, but it cannot skip a changed copied input.

.PARAMETER ContextPath
    Docker build-context directory.

.PARAMETER ExcludedPaths
    Files or directories generated by PitCrew that must not affect image
    compatibility.

.OUTPUTS
    Lowercase SHA-256 digest of the normalized context inventory.
#>
function Get-RunnerBuildContextFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ContextPath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ExcludedPaths
    )

    $resolvedContext = (Resolve-Path -LiteralPath $ContextPath).Path
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    } else {
        [StringComparison]::Ordinal
    }
    $excludedFullPaths = @(
        $ExcludedPaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [IO.Path]::GetFullPath($_) }
    )
    $builder = [Text.StringBuilder]::new()
    $items = @(
        Get-ChildItem -LiteralPath $resolvedContext -Force -Recurse |
            Sort-Object FullName
    )
    foreach ($item in $items) {
        $fullPath = [IO.Path]::GetFullPath($item.FullName)
        $isExcluded = $false
        foreach ($excludedPath in $excludedFullPaths) {
            $excludedPrefix = $excludedPath.TrimEnd('\', '/') +
                [IO.Path]::DirectorySeparatorChar
            if (
                $fullPath.Equals($excludedPath, $comparison) -or
                $fullPath.StartsWith($excludedPrefix, $comparison)
            ) {
                $isExcluded = $true
                break
            }
        }
        if ($isExcluded) {
            continue
        }

        $relativePath = [IO.Path]::GetRelativePath($resolvedContext, $fullPath)
        $relativePath = $relativePath.Replace('\', '/')
        if ($item.LinkType -in @('SymbolicLink', 'Junction')) {
            $kind = 'L'
            $value = @($item.Target) -join '|'
        } elseif ($item.PSIsContainer) {
            $kind = 'D'
            $modeValue = if ($IsWindows) {
                ''
            } else {
                ([int][IO.File]::GetUnixFileMode($fullPath)).ToString()
            }
            $value = $modeValue
        } else {
            $kind = 'F'
            $modeValue = if ($IsWindows) {
                ''
            } else {
                ([int][IO.File]::GetUnixFileMode($fullPath)).ToString()
            }
            $contentHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $value = "${modeValue}:$contentHash"
        }
        [void]$builder.Append($kind)
        [void]$builder.Append(':')
        [void]$builder.Append($relativePath.Length)
        [void]$builder.Append(':')
        [void]$builder.Append($relativePath)
        [void]$builder.Append(':')
        [void]$builder.Append($value.Length)
        [void]$builder.Append(':')
        [void]$builder.Append($value)
        [void]$builder.Append("`n")
    }

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($builder.ToString())
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
}

<#
.SYNOPSIS
    Creates and validates a desired-capacity document.

.DESCRIPTION
    Normalizes repository targets and worker counts into the non-secret state
    contract consumed by the runner manager.

.PARAMETER Generation
    Monotonically increasing desired-state generation.

.PARAMETER Scope
    GitHub runner scope represented by the state.

.PARAMETER Repositories
    Repository targets for repository scope. Each object must expose Url and
    Workers properties.

.PARAMETER Replicas
    Total desired workers for organization or enterprise scope. Must be null for
    repository scope.

.OUTPUTS
    PSCustomObject ready for atomic JSON serialization.
#>
function New-RunnerDesiredCapacityState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Generation,

        [Parameter(Mandatory)]
        [ValidateSet('repo', 'org', 'ent')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Repositories,

        [Parameter(Mandatory)]
        [AllowNull()]
        [Nullable[int]]$Replicas
    )

    $normalizedRepositories = @(
        foreach ($repository in $Repositories) {
            $url = [string]$repository.Url
            $workers = [int]$repository.Workers
            $parsedUrl = $null
            if (
                [string]::IsNullOrWhiteSpace($url) -or
                $url -eq '-' -or
                $url -ne $url.Trim() -or
                $url -match '\s' -or
                -not [Uri]::TryCreate(
                    $url,
                    [UriKind]::Absolute,
                    [ref]$parsedUrl) -or
                $parsedUrl.Scheme -notin @('http', 'https') -or
                [string]::IsNullOrWhiteSpace($parsedUrl.Host) -or
                [string]::IsNullOrWhiteSpace($parsedUrl.AbsolutePath.Trim('/')) -or
                -not [string]::IsNullOrEmpty($parsedUrl.UserInfo) -or
                -not [string]::IsNullOrEmpty($parsedUrl.Query) -or
                -not [string]::IsNullOrEmpty($parsedUrl.Fragment)
            ) {
                throw 'Repository URLs in desired capacity must be canonical absolute HTTP(S) URLs without credentials, whitespace, query strings, or fragments.'
            }
            if ($workers -lt 1) {
                throw "Repository '$url' must request at least one worker."
            }

            [PSCustomObject][ordered]@{
                url = $url
                workers = $workers
            }
        }
    )
    $normalizedRepositories = @($normalizedRepositories | Sort-Object url)
    $duplicateUrls = @(
        $normalizedRepositories |
            Group-Object url |
            Where-Object Count -gt 1
    )
    if ($duplicateUrls.Count -gt 0) {
        throw "Desired capacity contains duplicate repository URL '$($duplicateUrls[0].Name)'."
    }

    if ($Scope -eq 'repo') {
        if ($normalizedRepositories.Count -eq 0) {
            throw 'Repository scope requires at least one repository target.'
        }
        if ($null -ne $Replicas) {
            throw 'Repository-scoped desired capacity cannot define a shared replica count.'
        }
    } else {
        if ($normalizedRepositories.Count -ne 0) {
            throw 'Organization and enterprise desired capacity cannot define repository targets.'
        }
        if ($null -eq $Replicas -or $Replicas -lt 1) {
            throw 'Organization and enterprise desired capacity requires a positive replica count.'
        }
    }

    return [PSCustomObject][ordered]@{
        schemaVersion = $script:RunnerDesiredCapacitySchemaVersion
        generation = $Generation
        scope = $Scope
        repositories = @($normalizedRepositories)
        replicas = if ($null -eq $Replicas) { $null } else { [int]$Replicas }
    }
}

<#
.SYNOPSIS
    Returns the generation-independent identity of desired capacity.

.PARAMETER State
    Desired-capacity object created by New-RunnerDesiredCapacityState.

.OUTPUTS
    Compact JSON suitable for equality comparisons.
#>
function Get-RunnerDesiredCapacitySignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$State
    )

    $normalized = New-RunnerDesiredCapacityState `
        -Generation 1 `
        -Scope ([string]$State.scope) `
        -Repositories @(
            @($State.repositories) |
                ForEach-Object {
                    [PSCustomObject]@{
                        Url = [string]$_.url
                        Workers = [int]$_.workers
                    }
                }
        ) `
        -Replicas $(if ($null -eq $State.replicas) { $null } else { [Nullable[int]][int]$State.replicas })
    return $normalized | ConvertTo-Json -Depth 10 -Compress
}

<#
.SYNOPSIS
    Creates static profile metadata used to select in-place reconciliation.

.DESCRIPTION
    Produces a non-secret fingerprint over manager compatibility, image
    preparation, routing, scope, runner naming, and registration behavior.

.PARAMETER Profile
    Effective profile returned by Resolve-RunnerProfile.

.PARAMETER Scope
    GitHub runner scope.

.PARAMETER OrgName
    Organization name for organization scope.

.PARAMETER EnterpriseName
    Enterprise name for enterprise scope.

.OUTPUTS
    PSCustomObject containing the static contract and its SHA-256 fingerprint.
#>
function New-RunnerStaticProfileState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('repo', 'org', 'ent')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$OrgName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$EnterpriseName
    )

    $buildState = $null
    if ($Profile.Build) {
        $buildArguments = [ordered]@{}
        foreach ($key in @($Profile.Build.Arguments.Keys | Sort-Object)) {
            $buildArguments[$key] = [string]$Profile.Build.Arguments[$key]
        }
        $dockerfileHash = (Get-FileHash -LiteralPath $Profile.Build.Dockerfile -Algorithm SHA256).Hash.ToLowerInvariant()
        $contextHash = Get-RunnerBuildContextFingerprint `
            -ContextPath $Profile.Build.Context `
            -ExcludedPaths @(
                (Split-Path -Parent $Profile.StateDirectory),
                $Profile.EnvironmentPath
            )
        $buildState = [PSCustomObject][ordered]@{
            context = [string]$Profile.Build.Context
            dockerfile = [string]$Profile.Build.Dockerfile
            dockerfileSha256 = $dockerfileHash
            contextSha256 = $contextHash
            arguments = $buildArguments
        }
    }

    $staticConfiguration = [PSCustomObject][ordered]@{
        managerContractVersion = [int]$Profile.ManagerContractVersion
        profile = [string]$Profile.Name
        image = [string]$Profile.Image
        pullImage = [bool]$Profile.PullImage
        verificationCommands = @($Profile.VerificationCommands)
        build = $buildState
        labels = @($Profile.Labels)
        disableDefaultLabels = [bool]$Profile.DisableDefaultLabels
        scope = $Scope
        organization = $OrgName
        enterprise = $EnterpriseName
        runnerGroup = [string]$Profile.RunnerGroup
        namePrefix = [string]$Profile.NamePrefix
    }
    $configurationJson = $staticConfiguration | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($configurationJson)
    $fingerprint = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()

    return [PSCustomObject][ordered]@{
        schemaVersion = $script:RunnerStaticProfileSchemaVersion
        fingerprint = $fingerprint
        configuration = $staticConfiguration
    }
}

<#
.SYNOPSIS
    Reads a UTF-8 JSON state file.

.PARAMETER Path
    Existing JSON file to parse.

.OUTPUTS
    Parsed PSCustomObject.

.EXCEPTION
    Throws when the file is missing or contains invalid JSON.
#>
function Read-RunnerJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Runner state file '$Path' does not exist."
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 20 -ErrorAction Stop
    } catch {
        throw "Runner state file '$Path' is not valid JSON: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Atomically replaces a JSON state file.

.DESCRIPTION
    Serializes the complete document to a temporary file in the destination
    directory, flushes it, and then replaces the visible path with one rename.

.PARAMETER Path
    Destination JSON path.

.PARAMETER Value
    Complete validated object to serialize.
#>
function Write-RunnerJsonAtomically {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Value
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporaryPath = Join-Path $directory ".$([IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 20
    try {
        [IO.File]::WriteAllText($temporaryPath, "$json`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Acquires exclusive ownership of a profile setup lock.

.PARAMETER Path
    Profile-scoped lock file.

.PARAMETER TimeoutSeconds
    Maximum time to wait for another setup process to release the lock.

.OUTPUTS
    FileStream that must be disposed to release the lock.

.EXCEPTION
    Throws when the lock cannot be acquired before the timeout.
#>
function Enter-RunnerProfileLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            return [IO.File]::Open(
                $Path,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw "Timed out waiting for profile setup lock '$Path'."
            }
            Start-Sleep -Milliseconds 200
        }
    } while ($true)
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

        [ValidateSet('repo', 'org', 'ent')]
        [string]$Scope = 'repo',

        [string]$OrgName = '',

        [string]$EnterpriseName = ''
    )

    $values = @(
        $AccessToken,
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
        "RUNNER_SCOPE=$Scope"
        "ORG_NAME=$OrgName"
        "ENTERPRISE_NAME=$EnterpriseName"
        "RUNNER_PROFILE_ID=$($Profile.Name)"
        "RUNNER_IMAGE=$($Profile.Image)"
        "RUNNER_PULL_IMAGE=0"
        "RUNNER_NAME_PREFIX=$($Profile.NamePrefix)"
        "RUNNER_LABELS=$($Profile.LabelsValue)"
        "RUNNER_NO_DEFAULT_LABELS=$disableDefaultLabels"
        "RUNNER_GROUP=$($Profile.RunnerGroup)"
        "PITCREW_STATE_DIR=$($Profile.StateVolumePath)"
        "PITCREW_MANAGER_CONTRACT_VERSION=$($Profile.ManagerContractVersion)"
    ) -join "`n"
}
