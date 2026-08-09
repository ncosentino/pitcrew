#Requires -Version 7.0
Set-StrictMode -Version Latest

$script:RunnerDesiredCapacitySchemaVersion = 1
$script:RunnerStaticProfileSchemaVersion = 1
$script:RunnerHostAdmissionPolicySchemaVersion = 1
$script:RunnerManagerContractVersion = 17
$script:RunnerDefinedManagerContractVersion = 11
$script:RunnerDefinedHostAdmissionContractVersion = 18
$script:RunnerDefinedDiagnosticsContractVersion = 17
$script:RunnerWorkerRuntimeContractVersion = 2
$script:RunnerManagerJournalMaximumEvents = 64
$script:RunnerManagerJournalMaximumBytes = 16384
$script:RunnerManagerJournalMaximumEvidenceLength = 160

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
    Converts a Docker-compatible byte limit to a canonical integer.

.DESCRIPTION
    Accepts an integer byte count or a binary unit suffix from bytes through
    tebibytes. The result is overflow-safe and stable across equivalent input.

.PARAMETER Value
    Byte limit such as 6291456, 6m, or 6MiB.

.PARAMETER LimitName
    Public setting name included in validation errors.

.PARAMETER MinimumBytes
    Smallest accepted canonical byte count.

.OUTPUTS
    Signed 64-bit canonical byte count.
#>
function ConvertTo-RunnerByteLimit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$LimitName,

        [long]$MinimumBytes = 1
    )

    $normalized = $Value.Trim().ToLowerInvariant()
    $match = [regex]::Match(
        $normalized,
        '^(?<amount>[0-9]+)(?<unit>b|k|kb|ki|kib|m|mb|mi|mib|g|gb|gi|gib|t|tb|ti|tib)?$')
    if (-not $match.Success) {
        throw "$LimitName '$Value' must be an integer byte count or use a Docker-compatible binary unit such as 6m, 512MiB, or 2g."
    }

    $amount = [Numerics.BigInteger]::Zero
    if (-not [Numerics.BigInteger]::TryParse(
        $match.Groups['amount'].Value,
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$amount
    )) {
        throw "$LimitName '$Value' is not a valid byte count."
    }
    $multipliers = @{
        '' = [Numerics.BigInteger]::One
        b = [Numerics.BigInteger]::One
        k = [Numerics.BigInteger]::Pow(1024, 1)
        kb = [Numerics.BigInteger]::Pow(1024, 1)
        ki = [Numerics.BigInteger]::Pow(1024, 1)
        kib = [Numerics.BigInteger]::Pow(1024, 1)
        m = [Numerics.BigInteger]::Pow(1024, 2)
        mb = [Numerics.BigInteger]::Pow(1024, 2)
        mi = [Numerics.BigInteger]::Pow(1024, 2)
        mib = [Numerics.BigInteger]::Pow(1024, 2)
        g = [Numerics.BigInteger]::Pow(1024, 3)
        gb = [Numerics.BigInteger]::Pow(1024, 3)
        gi = [Numerics.BigInteger]::Pow(1024, 3)
        gib = [Numerics.BigInteger]::Pow(1024, 3)
        t = [Numerics.BigInteger]::Pow(1024, 4)
        tb = [Numerics.BigInteger]::Pow(1024, 4)
        ti = [Numerics.BigInteger]::Pow(1024, 4)
        tib = [Numerics.BigInteger]::Pow(1024, 4)
    }
    $bytes = $amount * $multipliers[$match.Groups['unit'].Value]
    if ($bytes -gt [long]::MaxValue) {
        throw "$LimitName '$Value' exceeds the supported 64-bit byte range."
    }
    if ($bytes -lt $MinimumBytes) {
        throw "$LimitName must be at least $MinimumBytes bytes."
    }
    return [long]$bytes
}

<#
.SYNOPSIS
    Converts a Docker CPU limit to a canonical decimal string.

.DESCRIPTION
    Accepts a positive decimal with at most nine fractional digits and removes
    insignificant leading and trailing zeroes without using floating point.

.PARAMETER Value
    CPU limit such as 0.5, 2, or 2.250000000.

.OUTPUTS
    Canonical invariant-culture decimal string.
#>
function ConvertTo-RunnerCpuLimit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $normalized = $Value.Trim()
    if ($normalized -notmatch '^[0-9]+(?:\.[0-9]{1,9})?$') {
        throw "Worker CPU limit '$Value' must be a positive decimal with at most nine fractional digits."
    }
    try {
        $cpu = [decimal]::Parse(
            $normalized,
            [Globalization.NumberStyles]::AllowDecimalPoint,
            [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        throw "Worker CPU limit '$Value' is outside the supported decimal range."
    }
    if ($cpu -le 0) {
        throw 'Worker CPU limit must be positive.'
    }
    $maximum = [decimal]::Parse(
        '9223372036.854775807',
        [Globalization.CultureInfo]::InvariantCulture)
    if ($cpu -gt $maximum) {
        throw "Worker CPU limit '$Value' exceeds the supported Docker nano-CPU range."
    }
    return $cpu.ToString(
        '0.#########',
        [Globalization.CultureInfo]::InvariantCulture)
}

<#
.SYNOPSIS
    Validates and canonicalizes one profile's host-local admission policy.

.DESCRIPTION
    Keeps host-wide capacity inputs separate from profile cost and reservation
    inputs while deriving stable fingerprints for later host-policy publication.

.PARAMETER Policy
    Manifest hostAdmission object.

.PARAMETER ProfileName
    Canonical profile identity used in the profile-policy fingerprint.

.OUTPUTS
    Canonical host-local admission policy with derived effective budget and
    fingerprints.
#>
function ConvertTo-RunnerHostAdmissionPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Policy,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z][a-z0-9-]{0,31}$')]
        [string]$ProfileName
    )

    $namespace = ([string]$Policy.namespace).Trim().ToLowerInvariant()
    if ($namespace -notmatch '^[a-z][a-z0-9-]{0,31}$') {
        throw "Host admission namespace '$($Policy.namespace)' must match ^[a-z][a-z0-9-]{0,31}$."
    }

    $capacityUnits = [long]$Policy.capacityUnits
    $safetyMarginUnits = [long]$Policy.safetyMarginUnits
    $workerCostUnits = [long]$Policy.workerCostUnits
    $reservationUnits = [long]$Policy.reservationUnits
    $borrowable = [bool]$Policy.borrowable

    if ($capacityUnits -lt 1 -or $capacityUnits -gt [int]::MaxValue) {
        throw 'Host admission capacity units must be between 1 and 2147483647.'
    }
    if (
        $safetyMarginUnits -lt 0 -or
        $safetyMarginUnits -ge $capacityUnits
    ) {
        throw 'Host admission safety-margin units must be non-negative and lower than capacity units.'
    }

    $effectiveBudgetUnits = $capacityUnits - $safetyMarginUnits
    if ($workerCostUnits -lt 1 -or $workerCostUnits -gt $effectiveBudgetUnits) {
        throw 'Host admission worker-cost units must be positive and no greater than the effective host budget.'
    }
    if ($reservationUnits -lt 0 -or $reservationUnits -gt $effectiveBudgetUnits) {
        throw 'Host admission reservation units must be non-negative and no greater than the effective host budget.'
    }

    $hostPolicy = [PSCustomObject][ordered]@{
        schemaVersion = 1
        namespace = $namespace
        capacityUnits = [int]$capacityUnits
        safetyMarginUnits = [int]$safetyMarginUnits
        effectiveBudgetUnits = [int]$effectiveBudgetUnits
    }
    $profilePolicy = [PSCustomObject][ordered]@{
        schemaVersion = 1
        namespace = $namespace
        profile = $ProfileName
        workerCostUnits = [int]$workerCostUnits
        reservationUnits = [int]$reservationUnits
        borrowable = $borrowable
    }

    return [PSCustomObject][ordered]@{
        SchemaVersion = 1
        Namespace = $namespace
        CapacityUnits = [int]$capacityUnits
        SafetyMarginUnits = [int]$safetyMarginUnits
        EffectiveBudgetUnits = [int]$effectiveBudgetUnits
        WorkerCostUnits = [int]$workerCostUnits
        ReservationUnits = [int]$reservationUnits
        Borrowable = $borrowable
        HostPolicyFingerprint = Get-RunnerObjectFingerprint -Value $hostPolicy
        ProfilePolicyFingerprint = Get-RunnerObjectFingerprint -Value $profilePolicy
    }
}

<#
.SYNOPSIS
    Derives stable host-side and container-side admission identities.
#>
function New-RunnerHostAdmissionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z][a-z0-9-]{0,31}$')]
        [string]$Namespace
    )

    $resolvedRoot = [IO.Path]::GetFullPath($RootPath)
    $directory = Join-Path `
        (Join-Path $resolvedRoot '.pitcrew-state' 'host-admission') `
        $Namespace
    return [PSCustomObject][ordered]@{
        Namespace = $Namespace
        Directory = $directory
        DesiredPolicyPath = Join-Path $directory 'desired-policy.json'
        AcknowledgementPath = Join-Path $directory 'acknowledged-policy.json'
        LockPath = Join-Path $directory 'setup.lock'
        EnvironmentPath = Join-Path $resolvedRoot ".env.host-admission-$Namespace"
        ComposeProjectName = "pitcrew-host-admission-$Namespace"
        VolumeName = "pitcrew-host-admission-$Namespace"
        SocketPath = '/var/lib/pitcrew-admission/coordinator.sock'
        ProtocolVersion = 1
    }
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

.PARAMETER WorkerMemory
    Optional per-worker memory limit in bytes or a Docker-compatible binary unit.

.PARAMETER WorkerMemorySwap
    Optional total per-worker memory-plus-swap limit. Requires WorkerMemory.

.PARAMETER WorkerCpus
    Optional positive per-worker CPU limit with at most nine fractional digits.

.PARAMETER WorkerPids
    Optional positive per-worker process limit.

.PARAMETER MaximumActiveWorkers
    Optional aggregate active-worker ceiling for an autoscaled profile.

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

        [Nullable[bool]]$Autoscale,

        [Nullable[int]]$MinimumIdle,

        [Nullable[int]]$ScaleDownDelaySeconds,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$WorkerMemory,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$WorkerMemorySwap,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$WorkerCpus,

        [Nullable[long]]$WorkerPids,

        [Nullable[int]]$MaximumActiveWorkers,

        [string]$HostName = 'runner'
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path
    $profileName = $Profile.Trim().ToLowerInvariant()
    if ($profileName -notmatch '^[a-z][a-z0-9-]{0,31}$') {
        throw "Profile '$Profile' must match ^[a-z][a-z0-9-]{0,31}$."
    }

    $manifest = $null
    $manifestPath = $null
    $manifestKind = 'implicit'
    $manifestSha256 = $null
    if ($ProfilePath) {
        $manifestPath = (Resolve-Path -LiteralPath $ProfilePath).Path
        $manifestKind = 'external'
    } elseif ($profileName -ne 'default') {
        $candidate = Join-Path $resolvedRoot 'profiles' $profileName 'profile.json'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Runner profile '$profileName' was not found at '$candidate'. Pass -ProfilePath for an external profile."
        }
        $manifestPath = (Resolve-Path -LiteralPath $candidate).Path
        $manifestKind = 'built-in'
    }

    $effectiveImage = 'myoung34/github-runner:ubuntu-noble'
    $effectiveReplicas = 1
    $effectiveLabels = @()
    $disableDefaultLabels = $false
    $effectiveRunnerGroup = ''
    $effectivePullImage = $true
    $verificationCommands = @()
    $effectiveReadOnlyVolumes = @()
    $effectiveServiceNetwork = $null
    $build = $null
    $effectiveAutoscaling = $null
    $effectiveHostAdmission = $null
    $effectiveResources = [ordered]@{
        Memory = $null
        MemorySwap = $null
        Cpus = $null
        Pids = $null
    }

    if ($manifestPath) {
        $schemaPath = Join-Path $resolvedRoot 'runner-profile.schema.json'
        $manifestText = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
        if (-not ($manifestText | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)) {
            throw "Runner profile manifest '$manifestPath' does not conform to '$schemaPath'."
        }

        $manifest = $manifestText | ConvertFrom-Json -Depth 20
        $manifestSha256 = (
            Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
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
        if ($manifest.PSObject.Properties['readOnlyVolumes']) {
            $volumeNames = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal)
            $volumeSources = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal)
            $effectiveReadOnlyVolumes = @(
                foreach ($volume in @($manifest.readOnlyVolumes)) {
                    $name = [string]$volume.name
                    $source = [string]$volume.source
                    if (-not $volumeNames.Add($name)) {
                        throw "Runner profile read-only volume name '$name' is duplicated."
                    }
                    if (-not $volumeSources.Add($source)) {
                        throw "Runner profile read-only volume source '$source' is duplicated."
                    }
                    [PSCustomObject][ordered]@{
                        Name = $name
                        Source = $source
                        Target = "/mnt/pitcrew-data/$name"
                    }
                }
            ) | Sort-Object Name
        }
        if ($manifest.PSObject.Properties['serviceNetwork']) {
            $serviceNetworkSource = [string]$manifest.serviceNetwork.source
            if (
                $serviceNetworkSource -ceq 'bridge' -or
                $serviceNetworkSource -match
                    '^self-hosted-runner(?:-[a-z][a-z0-9-]{0,31})?_default$'
            ) {
                throw "Runner profile service network '$serviceNetworkSource' identifies a reserved Docker or PitCrew manager network."
            }
            $effectiveServiceNetwork = [PSCustomObject][ordered]@{
                Source = $serviceNetworkSource
            }
        }
        if ($manifest.PSObject.Properties['autoscaling']) {
            $effectiveAutoscaling = [PSCustomObject][ordered]@{
                Mode = [string]$manifest.autoscaling.mode
                MinimumIdle = if ($manifest.autoscaling.PSObject.Properties['minimumIdle']) {
                    [int]$manifest.autoscaling.minimumIdle
                } else {
                    0
                }
                ScaleDownDelaySeconds = if ($manifest.autoscaling.PSObject.Properties['scaleDownDelaySeconds']) {
                    [int]$manifest.autoscaling.scaleDownDelaySeconds
                } else {
                    120
                }
                MaximumActiveWorkers = if ($manifest.autoscaling.PSObject.Properties['maximumActiveWorkers']) {
                    [int]$manifest.autoscaling.maximumActiveWorkers
                } else {
                    $null
                }
            }
        }
        if ($manifest.PSObject.Properties['resources']) {
            if ($manifest.resources.PSObject.Properties['memory']) {
                $effectiveResources.Memory = [string]$manifest.resources.memory
            }
            if ($manifest.resources.PSObject.Properties['memorySwap']) {
                $effectiveResources.MemorySwap = [string]$manifest.resources.memorySwap
            }
            if ($manifest.resources.PSObject.Properties['cpus']) {
                $effectiveResources.Cpus = [string]$manifest.resources.cpus
            }
            if ($manifest.resources.PSObject.Properties['pids']) {
                $effectiveResources.Pids = [long]$manifest.resources.pids
            }
        }
        if ($manifest.PSObject.Properties['hostAdmission']) {
            $effectiveHostAdmission = ConvertTo-RunnerHostAdmissionPolicy `
                -Policy $manifest.hostAdmission `
                -ProfileName $profileName
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

    if ($PSBoundParameters.ContainsKey('Autoscale')) {
        $effectiveAutoscaling = if ([bool]$Autoscale) {
            [PSCustomObject][ordered]@{
                Mode = 'scale-set'
                MinimumIdle = 0
                ScaleDownDelaySeconds = 120
                MaximumActiveWorkers = $null
            }
        } else {
            $null
        }
    }
    if ($PSBoundParameters.ContainsKey('MinimumIdle')) {
        if ($null -eq $effectiveAutoscaling) {
            throw '-MinimumIdle requires autoscaling to be enabled.'
        }
        $effectiveAutoscaling.MinimumIdle = [int]$MinimumIdle
    }
    if ($PSBoundParameters.ContainsKey('ScaleDownDelaySeconds')) {
        if ($null -eq $effectiveAutoscaling) {
            throw '-ScaleDownDelaySeconds requires autoscaling to be enabled.'
        }
        $effectiveAutoscaling.ScaleDownDelaySeconds = [int]$ScaleDownDelaySeconds
    }
    if ($PSBoundParameters.ContainsKey('MaximumActiveWorkers')) {
        if ($null -eq $effectiveAutoscaling) {
            throw '-MaximumActiveWorkers requires autoscaling to be enabled.'
        }
        $effectiveAutoscaling.MaximumActiveWorkers = [int]$MaximumActiveWorkers
    }
    if ($effectiveAutoscaling) {
        if ($effectiveAutoscaling.MinimumIdle -lt 0) {
            throw 'Autoscaling minimum idle runners cannot be negative.'
        }
        if (
            $effectiveAutoscaling.ScaleDownDelaySeconds -lt 30 -or
            $effectiveAutoscaling.ScaleDownDelaySeconds -gt 3600
        ) {
            throw 'Autoscaling scale-down delay must be between 30 and 3600 seconds.'
        }
        if (
            $null -ne $effectiveAutoscaling.MaximumActiveWorkers -and
            $effectiveAutoscaling.MaximumActiveWorkers -lt 1
        ) {
            throw 'Autoscaling maximum active workers must be a positive integer.'
        }
    }

    if ($PSBoundParameters.ContainsKey('WorkerMemory')) {
        $effectiveResources.Memory = $WorkerMemory
    }
    if ($PSBoundParameters.ContainsKey('WorkerMemorySwap')) {
        $effectiveResources.MemorySwap = $WorkerMemorySwap
    }
    if ($PSBoundParameters.ContainsKey('WorkerCpus')) {
        $effectiveResources.Cpus = $WorkerCpus
    }
    if ($PSBoundParameters.ContainsKey('WorkerPids')) {
        $effectiveResources.Pids = [long]$WorkerPids
    }
    $hasResources = @(
        $effectiveResources.Values |
            Where-Object { $null -ne $_ }
    ).Count -gt 0
    $resourcePolicy = $null
    if ($hasResources) {
        $memoryBytes = if ($null -ne $effectiveResources.Memory) {
            ConvertTo-RunnerByteLimit `
                -Value ([string]$effectiveResources.Memory) `
                -LimitName 'Worker memory limit' `
                -MinimumBytes 6291456
        } else {
            $null
        }
        $memorySwapBytes = if ($null -ne $effectiveResources.MemorySwap) {
            if ($null -eq $memoryBytes) {
                throw 'Worker memory-swap limit requires a worker memory limit.'
            }
            ConvertTo-RunnerByteLimit `
                -Value ([string]$effectiveResources.MemorySwap) `
                -LimitName 'Worker memory-swap limit'
        } else {
            $null
        }
        if ($null -ne $memorySwapBytes -and $memorySwapBytes -lt $memoryBytes) {
            throw 'Worker memory-swap limit must be greater than or equal to the worker memory limit.'
        }
        $cpuCores = if ($null -ne $effectiveResources.Cpus) {
            ConvertTo-RunnerCpuLimit -Value ([string]$effectiveResources.Cpus)
        } else {
            $null
        }
        $pids = if ($null -ne $effectiveResources.Pids) {
            $candidate = [long]$effectiveResources.Pids
            if ($candidate -lt 1 -or $candidate -gt [int]::MaxValue) {
                throw 'Worker PID limit must be between 1 and 2147483647.'
            }
            [int]$candidate
        } else {
            $null
        }
        $resourcePolicy = [PSCustomObject][ordered]@{
            MemoryBytes = $memoryBytes
            MemorySwapBytes = $memorySwapBytes
            CpuCores = $cpuCores
            Pids = $pids
        }
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
    $hostAdmissionContext = if ($effectiveHostAdmission) {
        New-RunnerHostAdmissionContext `
            -RootPath $resolvedRoot `
            -Namespace $effectiveHostAdmission.Namespace
    } else {
        $null
    }

    return [PSCustomObject]@{
        RootPath = $resolvedRoot
        Name = $profileName
        IsDefault = $isDefault
        ManifestPath = $manifestPath
        ManifestKind = $manifestKind
        ManifestSha256 = $manifestSha256
        ManifestDocument = $manifest
        EnvironmentPath = $environmentPath
        StateDirectory = $stateDirectory
        StateVolumePath = $stateVolumePath
        DesiredCapacityPath = Join-Path $stateDirectory 'desired-capacity.json'
        AcceptedCapacityPath = Join-Path $stateDirectory 'last-valid-capacity.json'
        CapacityAcknowledgementPath = Join-Path $stateDirectory 'acknowledged-capacity.json'
        ObservedStatePath = Join-Path $stateDirectory 'observed-state.json'
        StaticProfilePath = Join-Path $stateDirectory 'static-profile.json'
        ShutdownRequestPath = Join-Path $stateDirectory 'manager-shutdown.json'
        SessionOwnerPath = Join-Path $stateDirectory 'manager-session-owner.txt'
        LockPath = Join-Path $stateDirectory 'setup.lock'
        HostAdmissionDirectory = if ($hostAdmissionContext) {
            $hostAdmissionContext.Directory
        } else {
            $null
        }
        HostAdmissionDesiredPolicyPath = if ($hostAdmissionContext) {
            $hostAdmissionContext.DesiredPolicyPath
        } else {
            $null
        }
        HostAdmissionAcknowledgementPath = if ($hostAdmissionContext) {
            $hostAdmissionContext.AcknowledgementPath
        } else {
            $null
        }
        HostAdmissionLockPath = if ($hostAdmissionContext) {
            $hostAdmissionContext.LockPath
        } else {
            $null
        }
        HostAdmissionEnvironmentPath = if ($hostAdmissionContext) {
            $hostAdmissionContext.EnvironmentPath
        } else {
            $null
        }
        HostAdmissionComposeProjectName = if ($hostAdmissionContext) {
            $hostAdmissionContext.ComposeProjectName
        } else {
            ''
        }
        HostAdmissionVolumeName = if ($hostAdmissionContext) {
            $hostAdmissionContext.VolumeName
        } else {
            ''
        }
        HostAdmissionSocketPath = if ($hostAdmissionContext) {
            $hostAdmissionContext.SocketPath
        } else {
            ''
        }
        HostAdmissionProtocolVersion = if ($hostAdmissionContext) {
            $hostAdmissionContext.ProtocolVersion
        } else {
            0
        }
        ComposeProjectName = $composeProjectName
        ManagedRunnerLabel = "ephemeral-managed-runner-profile=$profileName"
        ManagerContractVersion = $script:RunnerManagerContractVersion
        DefinedManagerContractVersion = $script:RunnerDefinedManagerContractVersion
        DefinedHostAdmissionContractVersion =
            $script:RunnerDefinedHostAdmissionContractVersion
        DefinedDiagnosticsContractVersion = $script:RunnerDefinedDiagnosticsContractVersion
        Image = $effectiveImage
        Replicas = $effectiveReplicas
        Labels = @($labelList)
        LabelsValue = $labelList -join ','
        DisableDefaultLabels = $disableDefaultLabels
        RunnerGroup = $effectiveRunnerGroup
        Autoscaling = $effectiveAutoscaling
        HostAdmission = $effectiveHostAdmission
        Resources = $resourcePolicy
        ReadOnlyVolumes = @($effectiveReadOnlyVolumes)
        ReadOnlyVolumesValue = @(
            $effectiveReadOnlyVolumes |
                ForEach-Object { "$($_.Name)=$($_.Source)" }
        ) -join ','
        ServiceNetwork = $effectiveServiceNetwork
        ServiceNetworkValue = if ($effectiveServiceNetwork) {
            [string]$effectiveServiceNetwork.Source
        } else {
            ''
        }
        NamePrefix = $effectiveNamePrefix
        VerificationCommands = @($verificationCommands)
        Build = $build
        PullImage = $effectivePullImage
    }
}

<#
.SYNOPSIS
    Reports the manager contract both manager implementations provide.

.DESCRIPTION
    Reads the contract version declared by the POSIX fixed manager and by the Go
    autoscaler. The implemented contract is the lower of the two, so a contract
    that only one manager mode provides is never treated as available. An
    unreadable or unparsable declaration reports zero so activation fails closed.

.PARAMETER RootPath
    Installation root that contains the manager sources.

.OUTPUTS
    Object with Fixed, Autoscaling, and Implemented contract versions.
#>
function Get-RunnerImplementedManagerContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath
    )

    $declarations = @(
        [PSCustomObject]@{
            Name = 'Fixed'
            Path = Join-Path $RootPath 'manager' 'manage-runners.sh'
            Pattern = '(?m)^MANAGER_CONTRACT_VERSION=(\d+)\s*$'
        },
        [PSCustomObject]@{
            Name = 'Autoscaling'
            Path = Join-Path $RootPath 'manager' 'autoscaler' 'config.go'
            Pattern = '(?m)^const\s+managerContractVersion\s*=\s*(\d+)\s*$'
        }
    )
    $versions = [ordered]@{}
    foreach ($declaration in $declarations) {
        $version = 0
        if (Test-Path -LiteralPath $declaration.Path) {
            $content = Get-Content -LiteralPath $declaration.Path -Raw
            $match = [regex]::Match($content, $declaration.Pattern)
            if ($match.Success) {
                $version = [int]$match.Groups[1].Value
            }
        }
        $versions[$declaration.Name] = $version
    }

    return [PSCustomObject]@{
        Fixed = $versions['Fixed']
        Autoscaling = $versions['Autoscaling']
        Implemented = [Math]::Min($versions['Fixed'], $versions['Autoscaling'])
    }
}

<#
.SYNOPSIS
    Rejects a manager contract that both manager modes do not implement.

.DESCRIPTION
    Contract 12 operation, subsystem-health, and capacity-deficit evidence is
    defined before the fixed manager and the autoscaler publish it. Setup selects
    a contract for the manager through the generated environment, so a selection
    ahead of either implementation must fail before Docker, image, or generated
    state mutation.

.PARAMETER Profile
    Effective profile returned by Resolve-RunnerProfile.

.EXCEPTION
    Throws when the selected contract exceeds the contract both managers provide.
#>
function Assert-RunnerManagerContractActivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile
    )

    $implemented = Get-RunnerImplementedManagerContract -RootPath $Profile.RootPath
    if ($Profile.ManagerContractVersion -gt $implemented.Implemented) {
        throw (
            "Manager contract $($Profile.ManagerContractVersion) cannot activate because the fixed manager " +
            "implements contract $($implemented.Fixed) and the autoscaler implements contract " +
            "$($implemented.Autoscaling). Activate a contract only after both manager modes implement it; " +
            'no Docker, image, or generated state was changed.'
        )
    }
}

<#
.SYNOPSIS
    Reads an optional member from projected manager state.

.DESCRIPTION
    Observed state is deserialized from a file a manager wrote, so a member can
    be missing. Strict mode turns a missing member into a terminating error, and
    contract 12 requires malformed evidence to be discarded rather than to fail
    the whole projection.

.PARAMETER Value
    Deserialized object or dictionary.

.PARAMETER Name
    Member name to read.

.OUTPUTS
    Member value, or null when the member is absent.
#>
function Get-RunnerOptionalMember {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) {
            return ,$Value[$Name]
        }

        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return ,$property.Value
}

<#
.SYNOPSIS
    Reports whether a manager operation journal fits the contract-12 budget.

.DESCRIPTION
    Contract 12 keeps operation evidence bounded so a connector heartbeat stays
    small and cannot relay unbounded manager output. The journal is limited to a
    fixed retained-event count, a short sanitized evidence field per event, and a
    strict total serialized size.

.PARAMETER Journal
    Operation journal projected in observed state, or null when a manager
    predates contract 12.

.OUTPUTS
    Boolean that is true when the journal is absent or within every documented
    limit. A malformed journal is out of budget rather than an error, so a
    caller can discard it without discarding valid observed state.
#>
function Test-RunnerManagerJournalBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Journal
    )

    if ($null -eq $Journal) {
        return $true
    }

    $capacity = Get-RunnerOptionalMember -Value $Journal -Name 'capacity'
    if ($capacity -isnot [int] -and $capacity -isnot [long]) {
        return $false
    }
    if ($capacity -gt $script:RunnerManagerJournalMaximumEvents) {
        return $false
    }
    $declaredEvents = Get-RunnerOptionalMember -Value $Journal -Name 'events'
    if ($null -eq $declaredEvents) {
        return $false
    }
    $events = @($declaredEvents)
    if ($events.Count -gt $script:RunnerManagerJournalMaximumEvents) {
        return $false
    }
    foreach ($event in $events) {
        $evidence = Get-RunnerOptionalMember -Value $event -Name 'evidence'
        if (
            $null -ne $evidence -and
            "$evidence".Length -gt $script:RunnerManagerJournalMaximumEvidenceLength
        ) {
            return $false
        }
    }

    $serialized = $Journal | ConvertTo-Json -Depth 12 -Compress
    $serializedBytes = [Text.UTF8Encoding]::new($false).GetByteCount($serialized)
    return $serializedBytes -le $script:RunnerManagerJournalMaximumBytes
}

<#
.SYNOPSIS
    Rejects resilience settings that the active manager contract cannot enforce.

.DESCRIPTION
    Resource and profile-wide admission policies require the manager contract that
    defines them. This release activates that contract, so the guard passes for a
    supported policy and continues to fail closed if the active contract is ever
    older than the contract those policies require.

.PARAMETER Profile
    Effective profile returned by Resolve-RunnerProfile.

.EXCEPTION
    Throws when the profile requests a contract-11 policy while the active
    manager contract is older.
#>
function Assert-RunnerResilienceContractActivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile
    )

    $requestsAdmissionCeiling = (
        $Profile.Autoscaling -and
        $null -ne $Profile.Autoscaling.MaximumActiveWorkers
    )
    if (
        ($Profile.Resources -or $requestsAdmissionCeiling) -and
        $Profile.ManagerContractVersion -lt $Profile.DefinedManagerContractVersion
    ) {
        throw (
            "Runner resource limits and profile-wide admission require manager contract " +
            "$($Profile.DefinedManagerContractVersion), but this release activates contract " +
            "$($Profile.ManagerContractVersion). Upgrade after both manager implementations support contract " +
            "$($Profile.DefinedManagerContractVersion); the requested policy was not applied."
        )
    }
    if (
        $Profile.HostAdmission -and
        $Profile.ManagerContractVersion -lt
            $Profile.DefinedHostAdmissionContractVersion
    ) {
        throw (
            "Host-local admission requires manager contract " +
            "$($Profile.DefinedHostAdmissionContractVersion), but this release activates contract " +
            "$($Profile.ManagerContractVersion). Upgrade after both manager implementations support contract " +
            "$($Profile.DefinedHostAdmissionContractVersion); no Docker, image, or generated state was changed."
        )
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
            $canonicalPath = $parsedUrl.AbsolutePath.TrimEnd('/')
            if ($canonicalPath.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
                $canonicalPath = $canonicalPath.Substring(0, $canonicalPath.Length - 4)
            }
            if ([string]::IsNullOrWhiteSpace($canonicalPath.Trim('/'))) {
                throw "Repository URL '$url' does not identify a repository."
            }
            $canonicalBuilder = [UriBuilder]::new($parsedUrl)
            $canonicalBuilder.Scheme = $parsedUrl.Scheme.ToLowerInvariant()
            $canonicalBuilder.Host = $parsedUrl.Host.ToLowerInvariant()
            if ($parsedUrl.IsDefaultPort) {
                $canonicalBuilder.Port = -1
            }
            $canonicalBuilder.Path = $canonicalPath
            $canonicalBuilder.Query = ''
            $canonicalBuilder.Fragment = ''
            $url = $canonicalBuilder.Uri.AbsoluteUri.TrimEnd('/')
            if ($workers -lt 0) {
                throw "Repository '$url' cannot request a negative worker count."
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
        if ($null -eq $Replicas -or $Replicas -lt 0) {
            throw 'Organization and enterprise desired capacity requires a nonnegative replica count.'
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
    Creates one versioned desired host-admission policy document.

.DESCRIPTION
    Canonicalizes host-wide capacity and profile-specific policy into the
    non-secret state later consumed by the dedicated admission service.

.PARAMETER Generation
    Monotonically increasing host-policy generation.

.PARAMETER Namespace
    Single active admission namespace on the Docker daemon.

.PARAMETER CapacityUnits
    Measured abstract host capacity before safety margin.

.PARAMETER SafetyMarginUnits
    Units withheld from the effective admission budget.

.PARAMETER ProfilePolicies
    Profile policy objects exposing Profile, WorkerCostUnits,
    ReservationUnits, and Borrowable.
#>
function New-RunnerHostAdmissionDesiredPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Generation,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z][a-z0-9-]{0,31}$')]
        [string]$Namespace,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$CapacityUnits,

        [Parameter(Mandatory)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$SafetyMarginUnits,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$ProfilePolicies
    )

    $normalizedProfiles = @(
        foreach ($profilePolicy in $ProfilePolicies) {
            $profileName = ([string]$profilePolicy.Profile).Trim().ToLowerInvariant()
            if ($profileName -notmatch '^[a-z][a-z0-9-]{0,31}$') {
                throw "Host admission profile '$($profilePolicy.Profile)' must match ^[a-z][a-z0-9-]{0,31}$."
            }
            $canonical = ConvertTo-RunnerHostAdmissionPolicy `
                -Policy ([PSCustomObject]@{
                    namespace = $Namespace
                    capacityUnits = $CapacityUnits
                    safetyMarginUnits = $SafetyMarginUnits
                    workerCostUnits = [int]$profilePolicy.WorkerCostUnits
                    reservationUnits = [int]$profilePolicy.ReservationUnits
                    borrowable = [bool]$profilePolicy.Borrowable
                }) `
                -ProfileName $profileName
            [PSCustomObject][ordered]@{
                profile = $profileName
                workerCostUnits = $canonical.WorkerCostUnits
                reservationUnits = $canonical.ReservationUnits
                borrowable = $canonical.Borrowable
                profilePolicyFingerprint = $canonical.ProfilePolicyFingerprint
            }
        }
    )
    $normalizedProfiles = @($normalizedProfiles | Sort-Object profile)
    $duplicateProfiles = @(
        $normalizedProfiles |
            Group-Object profile |
            Where-Object Count -gt 1
    )
    if ($duplicateProfiles.Count -gt 0) {
        throw "Host admission policy contains duplicate profile '$($duplicateProfiles[0].Name)'."
    }

    $hostPolicy = ConvertTo-RunnerHostAdmissionPolicy `
        -Policy ([PSCustomObject]@{
            namespace = $Namespace
            capacityUnits = $CapacityUnits
            safetyMarginUnits = $SafetyMarginUnits
            workerCostUnits = 1
            reservationUnits = 0
            borrowable = $true
        }) `
        -ProfileName 'host-policy'

    return [PSCustomObject][ordered]@{
        schemaVersion = $script:RunnerHostAdmissionPolicySchemaVersion
        generation = $Generation
        namespace = $hostPolicy.Namespace
        capacityUnits = $hostPolicy.CapacityUnits
        safetyMarginUnits = $hostPolicy.SafetyMarginUnits
        effectiveBudgetUnits = $hostPolicy.EffectiveBudgetUnits
        hostPolicyFingerprint = $hostPolicy.HostPolicyFingerprint
        profiles = @($normalizedProfiles)
    }
}

<#
.SYNOPSIS
    Returns the generation-independent host-admission policy identity.
#>
function Get-RunnerHostAdmissionPolicySignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Policy
    )

    $normalized = New-RunnerHostAdmissionDesiredPolicy `
        -Generation 1 `
        -Namespace ([string]$Policy.namespace) `
        -CapacityUnits ([int]$Policy.capacityUnits) `
        -SafetyMarginUnits ([int]$Policy.safetyMarginUnits) `
        -ProfilePolicies @(
            @($Policy.profiles) |
                ForEach-Object {
                    [PSCustomObject]@{
                        Profile = [string]$_.profile
                        WorkerCostUnits = [int]$_.workerCostUnits
                        ReservationUnits = [int]$_.reservationUnits
                        Borrowable = [bool]$_.borrowable
                    }
                }
        )
    return $normalized | ConvertTo-Json -Depth 10 -Compress
}

<#
.SYNOPSIS
    Updates one selected profile in an existing desired host policy.

.DESCRIPTION
    Preserves every unrelated profile and rejects host-wide policy drift while
    another profile remains enrolled. A profile with no HostAdmission policy is
    removed from the next generation.
#>
function Update-RunnerHostAdmissionDesiredPolicy {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [PSCustomObject]$CurrentPolicy,

        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Generation
    )

    if ($null -eq $CurrentPolicy) {
        if ($null -eq $Profile.HostAdmission) {
            return $null
        }
        return New-RunnerHostAdmissionDesiredPolicy `
            -Generation $Generation `
            -Namespace $Profile.HostAdmission.Namespace `
            -CapacityUnits $Profile.HostAdmission.CapacityUnits `
            -SafetyMarginUnits $Profile.HostAdmission.SafetyMarginUnits `
            -ProfilePolicies @(
                [PSCustomObject]@{
                    Profile = $Profile.Name
                    WorkerCostUnits = $Profile.HostAdmission.WorkerCostUnits
                    ReservationUnits = $Profile.HostAdmission.ReservationUnits
                    Borrowable = $Profile.HostAdmission.Borrowable
                }
            )
    }

    if (
        -not $CurrentPolicy.PSObject.Properties['schemaVersion'] -or
        [int]$CurrentPolicy.schemaVersion -ne $script:RunnerHostAdmissionPolicySchemaVersion
    ) {
        throw "Unsupported host-admission policy schema version '$($CurrentPolicy.schemaVersion)'."
    }

    $unrelatedProfiles = @(
        @($CurrentPolicy.profiles) |
            Where-Object { [string]$_.profile -cne [string]$Profile.Name }
    )
    $namespace = [string]$CurrentPolicy.namespace
    $capacityUnits = [int]$CurrentPolicy.capacityUnits
    $safetyMarginUnits = [int]$CurrentPolicy.safetyMarginUnits
    $nextProfiles = @($unrelatedProfiles)

    if ($Profile.HostAdmission) {
        if ($unrelatedProfiles.Count -gt 0) {
            if (
                [string]$Profile.HostAdmission.Namespace -cne $namespace -or
                [string]$Profile.HostAdmission.HostPolicyFingerprint -cne
                    [string]$CurrentPolicy.hostPolicyFingerprint
            ) {
                throw "Profile '$($Profile.Name)' host-wide admission policy conflicts with other participating profiles."
            }
        } else {
            $namespace = [string]$Profile.HostAdmission.Namespace
            $capacityUnits = [int]$Profile.HostAdmission.CapacityUnits
            $safetyMarginUnits = [int]$Profile.HostAdmission.SafetyMarginUnits
        }
        $nextProfiles += [PSCustomObject]@{
            Profile = $Profile.Name
            WorkerCostUnits = $Profile.HostAdmission.WorkerCostUnits
            ReservationUnits = $Profile.HostAdmission.ReservationUnits
            Borrowable = $Profile.HostAdmission.Borrowable
        }
    }

    return New-RunnerHostAdmissionDesiredPolicy `
        -Generation $Generation `
        -Namespace $namespace `
        -CapacityUnits $capacityUnits `
        -SafetyMarginUnits $safetyMarginUnits `
        -ProfilePolicies $nextProfiles
}

<#
.SYNOPSIS
    Projects desired host policy into the coordinator wire contract.
#>
function ConvertTo-RunnerHostAdmissionServicePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Policy
    )

    $normalized = New-RunnerHostAdmissionDesiredPolicy `
        -Generation ([int]$Policy.generation) `
        -Namespace ([string]$Policy.namespace) `
        -CapacityUnits ([int]$Policy.capacityUnits) `
        -SafetyMarginUnits ([int]$Policy.safetyMarginUnits) `
        -ProfilePolicies @(
            @($Policy.profiles) |
                ForEach-Object {
                    [PSCustomObject]@{
                        Profile = [string]$_.profile
                        WorkerCostUnits = [int]$_.workerCostUnits
                        ReservationUnits = [int]$_.reservationUnits
                        Borrowable = [bool]$_.borrowable
                    }
                }
        )
    return [PSCustomObject][ordered]@{
        generation = [int]$normalized.generation
        totalUnits = [int]$normalized.effectiveBudgetUnits
        profiles = @(
            $normalized.profiles |
                ForEach-Object {
                    [PSCustomObject][ordered]@{
                        profileId = [string]$_.profile
                        unitCost = [int]$_.workerCostUnits
                        reservedUnits = [int]$_.reservationUnits
                        borrowable = [bool]$_.borrowable
                    }
                }
        )
    }
}

<#
.SYNOPSIS
    Returns the canonical identity of a coordinator service policy.
#>
function Get-RunnerHostAdmissionServicePolicySignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Policy
    )

    $normalized = [PSCustomObject][ordered]@{
        generation = [int]$Policy.generation
        totalUnits = [int]$Policy.totalUnits
        profiles = @(
            @($Policy.profiles) |
                ForEach-Object {
                    [PSCustomObject][ordered]@{
                        profileId = [string]$_.profileId
                        unitCost = [int]$_.unitCost
                        reservedUnits = [int]$_.reservedUnits
                        borrowable = [bool]$_.borrowable
                    }
                } |
                Sort-Object profileId
        )
    }
    return Get-RunnerObjectFingerprint -Value $normalized
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

.PARAMETER ResolvedImageId
    Immutable local Docker image ID resolved after image preparation.

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
        [string]$EnterpriseName,

        [AllowNull()]
        [ValidatePattern('^$|^sha256:[0-9a-f]{64}$')]
        [string]$ResolvedImageId = ''
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
        workerRuntimeContractVersion = $script:RunnerWorkerRuntimeContractVersion
        profile = [string]$Profile.Name
        image = [string]$Profile.Image
        resolvedImageId = if ([string]::IsNullOrWhiteSpace($ResolvedImageId)) {
            $null
        } else {
            $ResolvedImageId.ToLowerInvariant()
        }
        pullImage = [bool]$Profile.PullImage
        verificationCommands = @($Profile.VerificationCommands)
        build = $buildState
        labels = @($Profile.Labels)
        disableDefaultLabels = [bool]$Profile.DisableDefaultLabels
        scope = $Scope
        organization = $OrgName
        enterprise = $EnterpriseName
        runnerGroup = [string]$Profile.RunnerGroup
        autoscaling = if ($Profile.Autoscaling) {
            [PSCustomObject][ordered]@{
                mode = [string]$Profile.Autoscaling.Mode
                minimumIdle = [int]$Profile.Autoscaling.MinimumIdle
                scaleDownDelaySeconds = [int]$Profile.Autoscaling.ScaleDownDelaySeconds
                maximumActiveWorkers = if (
                    $null -eq $Profile.Autoscaling.MaximumActiveWorkers
                ) {
                    $null
                } else {
                    [int]$Profile.Autoscaling.MaximumActiveWorkers
                }
            }
        } else {
            $null
        }
        hostAdmission = if ($Profile.HostAdmission) {
            [PSCustomObject][ordered]@{
                namespace = [string]$Profile.HostAdmission.Namespace
            }
        } else {
            $null
        }
        resources = if ($Profile.Resources) {
            [PSCustomObject][ordered]@{
                memoryBytes = $Profile.Resources.MemoryBytes
                memorySwapBytes = $Profile.Resources.MemorySwapBytes
                cpuCores = $Profile.Resources.CpuCores
                pids = $Profile.Resources.Pids
            }
        } else {
            $null
        }
        readOnlyVolumes = @(
            $Profile.ReadOnlyVolumes |
                ForEach-Object {
                    [PSCustomObject][ordered]@{
                        name = [string]$_.Name
                        source = [string]$_.Source
                        target = [string]$_.Target
                    }
                }
        )
        serviceNetwork = if ($Profile.ServiceNetwork) {
            [PSCustomObject][ordered]@{
                source = [string]$Profile.ServiceNetwork.Source
            }
        } else {
            $null
        }
        namePrefix = [string]$Profile.NamePrefix
    }
    $fingerprint = Get-RunnerObjectFingerprint -Value $staticConfiguration
    $workerRevision = Get-RunnerObjectFingerprint -Value (
        Get-RunnerWorkerConfiguration -Configuration $staticConfiguration
    )

    return [PSCustomObject][ordered]@{
        schemaVersion = $script:RunnerStaticProfileSchemaVersion
        fingerprint = $fingerprint
        workerRevision = $workerRevision
        manifest = if ($Profile.ManifestPath) {
            [PSCustomObject][ordered]@{
                kind = [string]$Profile.ManifestKind
                sourcePath = [string]$Profile.ManifestPath
                sha256 = [string]$Profile.ManifestSha256
                document = $Profile.ManifestDocument
            }
        } else {
            $null
        }
        configuration = $staticConfiguration
    }
}

<#
.SYNOPSIS
    Computes a stable SHA-256 fingerprint for a JSON-compatible value.

.PARAMETER Value
    Value whose ordered JSON representation identifies the contract.

.OUTPUTS
    Lowercase SHA-256 digest.
#>
function Get-RunnerObjectFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
}

<#
.SYNOPSIS
    Selects the configuration that changes a worker container revision.

.DESCRIPTION
    Excludes manager-only settings and autoscaling policy so manager refreshes
    and policy tuning can preserve compatible workers across a handoff.

.PARAMETER Configuration
    Static profile configuration from New-RunnerStaticProfileState.

.OUTPUTS
    Ordered worker configuration suitable for hashing or equality checks.
#>
function Get-RunnerWorkerConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Configuration
    )

    $workerRuntimeContractVersion = if (
        $Configuration.PSObject.Properties['workerRuntimeContractVersion']
    ) {
        [int]$Configuration.workerRuntimeContractVersion
    } else {
        1
    }
    return [PSCustomObject][ordered]@{
        workerRuntimeContractVersion = $workerRuntimeContractVersion
        profile = [string]$Configuration.profile
        image = [string]$Configuration.image
        resolvedImageId = if ($Configuration.PSObject.Properties['resolvedImageId']) {
            $Configuration.resolvedImageId
        } else {
            $null
        }
        build = $Configuration.build
        resources = if ($Configuration.PSObject.Properties['resources']) {
            $Configuration.resources
        } else {
            $null
        }
        readOnlyVolumes = if (
            $Configuration.PSObject.Properties['readOnlyVolumes']
        ) {
            @($Configuration.readOnlyVolumes)
        } else {
            @()
        }
        serviceNetwork = if (
            $Configuration.PSObject.Properties['serviceNetwork']
        ) {
            $Configuration.serviceNetwork
        } else {
            $null
        }
        labels = @($Configuration.labels)
        disableDefaultLabels = [bool]$Configuration.disableDefaultLabels
        scope = [string]$Configuration.scope
        organization = [string]$Configuration.organization
        enterprise = [string]$Configuration.enterprise
        runnerGroup = [string]$Configuration.runnerGroup
        namePrefix = [string]$Configuration.namePrefix
    }
}

<#
.SYNOPSIS
    Selects worker configuration that must remain unchanged for manager refresh.

.DESCRIPTION
    Excludes PitCrew's internal worker runtime contract version so a published
    manager refresh can roll workers onto a corrected launch contract while
    still rejecting operator-visible image, label, scope, or build changes.

.PARAMETER Configuration
    Static profile configuration from New-RunnerStaticProfileState.

.OUTPUTS
    Ordered refresh-compatible worker configuration suitable for hashing.
#>
function Get-RunnerRefreshCompatibilityConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Configuration
    )

    $worker = Get-RunnerWorkerConfiguration -Configuration $Configuration
    return [PSCustomObject][ordered]@{
        profile = [string]$worker.profile
        image = [string]$worker.image
        resolvedImageId = $worker.resolvedImageId
        build = $worker.build
        resources = $worker.resources
        readOnlyVolumes = @($worker.readOnlyVolumes)
        serviceNetwork = $worker.serviceNetwork
        labels = @($worker.labels)
        disableDefaultLabels = [bool]$worker.disableDefaultLabels
        scope = [string]$worker.scope
        organization = [string]$worker.organization
        enterprise = [string]$worker.enterprise
        runnerGroup = [string]$worker.runnerGroup
        namePrefix = [string]$worker.namePrefix
    }
}

<#
.SYNOPSIS
    Selects the topology that must remain stable for a rolling replacement.

.DESCRIPTION
    Image and manager implementation changes can roll in place. Registration
    scope, manager mode, runner group, and naming changes require an explicit
    full stop because existing workers cannot be safely rehomed.

.PARAMETER Configuration
    Static profile configuration from New-RunnerStaticProfileState.

.OUTPUTS
    Ordered topology configuration suitable for equality checks.
#>
function Get-RunnerRollingCompatibilityConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Configuration
    )

    return [PSCustomObject][ordered]@{
        profile = [string]$Configuration.profile
        labels = @($Configuration.labels)
        disableDefaultLabels = [bool]$Configuration.disableDefaultLabels
        scope = [string]$Configuration.scope
        organization = [string]$Configuration.organization
        enterprise = [string]$Configuration.enterprise
        runnerGroup = [string]$Configuration.runnerGroup
        autoscalingMode = if ($Configuration.autoscaling) {
            [string]$Configuration.autoscaling.mode
        } else {
            ''
        }
        namePrefix = [string]$Configuration.namePrefix
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
    Creates the non-secret Compose environment for one admission service.
#>
function New-RunnerHostAdmissionEnvironmentContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile
    )

    if ($null -eq $Profile.HostAdmission) {
        throw "Profile '$($Profile.Name)' does not define host-local admission."
    }
    return @(
        "PITCREW_HOST_ADMISSION_NAMESPACE=$($Profile.HostAdmission.Namespace)"
        "PITCREW_HOST_ADMISSION_VOLUME=$($Profile.HostAdmissionVolumeName)"
        "PITCREW_HOST_ADMISSION_PROTOCOL_VERSION=$($Profile.HostAdmissionProtocolVersion)"
    ) -join "`n"
}

<#
.SYNOPSIS
    Creates the Docker Compose environment content for a resolved runner profile.

.PARAMETER Profile
    Effective profile returned by Resolve-RunnerProfile.

.PARAMETER AccessToken
    Registration token written only to the gitignored profile environment file.

.PARAMETER WorkerRevision
    SHA-256 revision assigned to newly launched worker containers.

.PARAMETER SessionOwner
    Stable non-secret owner name used for scale-set message sessions.

.PARAMETER AssumeUnversionedCurrent
    Whether workers created before revision labels should be adopted as current.

.PARAMETER ResolvedImageId
    Immutable local Docker image ID used for the target worker revision.

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

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-f]{64}$')]
        [string]$WorkerRevision,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$')]
        [string]$SessionOwner,

        [Parameter(Mandatory)]
        [bool]$AssumeUnversionedCurrent,

        [Parameter(Mandatory)]
        [ValidatePattern('^sha256:[0-9a-f]{64}$')]
        [string]$ResolvedImageId,

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
        $Profile.RunnerGroup,
        $Profile.ReadOnlyVolumesValue,
        $Profile.ServiceNetworkValue,
        $Profile.HostAdmissionVolumeName,
        $Profile.HostAdmissionSocketPath,
        $WorkerRevision,
        $SessionOwner,
        $ResolvedImageId
    )
    if ($values | Where-Object { $_ -match '[\r\n]' }) {
        throw 'Runner environment values cannot contain newlines.'
    }

    $disableDefaultLabels = if ($Profile.DisableDefaultLabels) { '1' } else { '' }
    $assumeUnversionedCurrentValue = if ($AssumeUnversionedCurrent) { '1' } else { '0' }
    $autoscalingMode = if ($Profile.Autoscaling) { [string]$Profile.Autoscaling.Mode } else { '' }
    $minimumIdle = if ($Profile.Autoscaling) { [string]$Profile.Autoscaling.MinimumIdle } else { '' }
    $scaleDownDelay = if ($Profile.Autoscaling) {
        [string]$Profile.Autoscaling.ScaleDownDelaySeconds
    } else {
        ''
    }
    $maximumActiveWorkers = if (
        $Profile.Autoscaling -and
        $null -ne $Profile.Autoscaling.MaximumActiveWorkers
    ) {
        [string]$Profile.Autoscaling.MaximumActiveWorkers
    } else {
        ''
    }
    $memoryBytes = if ($Profile.Resources -and $null -ne $Profile.Resources.MemoryBytes) {
        [string]$Profile.Resources.MemoryBytes
    } else {
        ''
    }
    $memorySwapBytes = if (
        $Profile.Resources -and
        $null -ne $Profile.Resources.MemorySwapBytes
    ) {
        [string]$Profile.Resources.MemorySwapBytes
    } else {
        ''
    }
    $cpuCores = if ($Profile.Resources -and $null -ne $Profile.Resources.CpuCores) {
        [string]$Profile.Resources.CpuCores
    } else {
        ''
    }
    $pidsLimit = if ($Profile.Resources -and $null -ne $Profile.Resources.Pids) {
        [string]$Profile.Resources.Pids
    } else {
        ''
    }
    $readOnlyVolumes = [string]$Profile.ReadOnlyVolumesValue
    $serviceNetwork = [string]$Profile.ServiceNetworkValue
    $hostAdmissionNamespace = if ($Profile.HostAdmission) {
        [string]$Profile.HostAdmission.Namespace
    } else {
        ''
    }
    $hostAdmissionHostFingerprint = if ($Profile.HostAdmission) {
        [string]$Profile.HostAdmission.HostPolicyFingerprint
    } else {
        ''
    }
    $hostAdmissionProfileFingerprint = if ($Profile.HostAdmission) {
        [string]$Profile.HostAdmission.ProfilePolicyFingerprint
    } else {
        ''
    }
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
        "PITCREW_WORKER_REVISION=$WorkerRevision"
        "PITCREW_WORKER_IMAGE_ID=$ResolvedImageId"
        "PITCREW_WORKER_MEMORY_BYTES=$memoryBytes"
        "PITCREW_WORKER_MEMORY_SWAP_BYTES=$memorySwapBytes"
        "PITCREW_WORKER_CPU_CORES=$cpuCores"
        "PITCREW_WORKER_PIDS_LIMIT=$pidsLimit"
        "PITCREW_READ_ONLY_VOLUMES=$readOnlyVolumes"
        "PITCREW_SERVICE_NETWORK=$serviceNetwork"
        "PITCREW_SESSION_OWNER=$SessionOwner"
        "PITCREW_ASSUME_UNVERSIONED_CURRENT=$assumeUnversionedCurrentValue"
        "PITCREW_AUTOSCALING_MODE=$autoscalingMode"
        "PITCREW_AUTOSCALING_MIN_IDLE=$minimumIdle"
        "PITCREW_AUTOSCALING_SCALE_DOWN_DELAY_SECONDS=$scaleDownDelay"
        "PITCREW_AUTOSCALING_MAX_ACTIVE_WORKERS=$maximumActiveWorkers"
        "PITCREW_HOST_ADMISSION_NAMESPACE=$hostAdmissionNamespace"
        "PITCREW_HOST_ADMISSION_VOLUME=$($Profile.HostAdmissionVolumeName)"
        "PITCREW_HOST_ADMISSION_SOCKET=$($Profile.HostAdmissionSocketPath)"
        "PITCREW_HOST_ADMISSION_HOST_FINGERPRINT=$hostAdmissionHostFingerprint"
        "PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT=$hostAdmissionProfileFingerprint"
        "PITCREW_STATE_DIR=$($Profile.StateVolumePath)"
        "PITCREW_MANAGER_CONTRACT_VERSION=$($Profile.ManagerContractVersion)"
    ) -join "`n"
}
