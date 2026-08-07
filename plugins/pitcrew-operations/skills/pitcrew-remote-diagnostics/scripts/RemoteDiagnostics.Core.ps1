#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-PitCrewRemoteDiagnosticsProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }
    if ($InputObject -is [Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function Get-PitCrewRemoteDiagnosticsSha256 {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $stream = [IO.File]::OpenRead($LiteralPath)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($stream)
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
    return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
}

function Get-PitCrewRemoteDiagnosticsTextSha256 {
    param([Parameter(Mandatory)][string]$Value)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }
    return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
}

function Write-PitCrewRemoteDiagnosticsUtf8 {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Content
    )

    [IO.File]::WriteAllText(
        $LiteralPath,
        $Content.Replace("`r`n", "`n"),
        [Text.UTF8Encoding]::new($false))
}

function ConvertTo-PitCrewPowerShellLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return '$null'
    }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Assert-PitCrewRemoteDiagnosticUrl {
    param([Parameter(Mandatory)][Uri]$Uri)

    if ($Uri.Scheme -notin @('http', 'https') -or
        -not [string]::IsNullOrEmpty($Uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($Uri.Query) -or
        -not [string]::IsNullOrEmpty($Uri.Fragment) -or
        [string]::IsNullOrWhiteSpace($Uri.Host) -or
        $Uri.Host -match '[$`{}]') {
        throw 'ApprovedUrl values must be literal HTTP or HTTPS URLs without credentials, query strings, fragments, or shell expansions.'
    }
}

function Assert-PitCrewRemoteRootLiteral {
    param([Parameter(Mandatory)][string]$Value)

    $windowsRoot = $Value -match '^[A-Za-z]:[\\/][^\r\n\u0000]+$'
    $posixRoot = $Value -match '^/[^\r\n\u0000]+$'
    if ($Value.Length -gt 1024 -or
        (-not $windowsRoot -and -not $posixRoot) -or
        $Value -match '[$`{}]' -or
        @($Value -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0) {
        throw 'PitCrewRoot must be one explicit absolute Windows or POSIX path without traversal or shell expansions.'
    }
}

function New-PitCrewRemoteDiagnosticsPackageId {
    param(
        [Parameter(Mandatory)][string]$CollectorSha256,
        [Parameter(Mandatory)][string]$TargetPitCrewRoot,
        [Parameter(Mandatory)][string]$DiagnosticMode,
        [AllowNull()][string]$Profile,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ApprovedUrls,
        [Parameter(Mandatory)][int]$ProbeTimeoutSeconds
    )

    $identity = [PSCustomObject][ordered]@{
        schemaVersion = 1
        collectorSha256 = $CollectorSha256
        targetPitCrewRoot = $TargetPitCrewRoot
        diagnosticMode = $DiagnosticMode
        profile = $Profile
        approvedUrls = @($ApprovedUrls | Sort-Object -Unique)
        probeTimeoutSeconds = $ProbeTimeoutSeconds
    } | ConvertTo-Json -Depth 10 -Compress
    return (Get-PitCrewRemoteDiagnosticsTextSha256 $identity).Substring(0, 32)
}

function New-PitCrewDeterministicZip {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }
    $stream = [IO.File]::Open(
        $DestinationPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
    $archive = [IO.Compression.ZipArchive]::new(
        $stream,
        [IO.Compression.ZipArchiveMode]::Create,
        $false,
        [Text.UTF8Encoding]::new($false))
    try {
        $fixedTimestamp = [DateTimeOffset]::new(
            1980,
            1,
            1,
            0,
            0,
            0,
            [TimeSpan]::Zero)
        foreach ($file in Get-ChildItem `
                -LiteralPath $SourceDirectory `
                -File `
                -Recurse |
                Sort-Object FullName) {
            $relativePath = [IO.Path]::GetRelativePath(
                $SourceDirectory,
                $file.FullName).Replace('\', '/')
            $entry = $archive.CreateEntry(
                $relativePath,
                [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedTimestamp
            $entryStream = $entry.Open()
            $fileStream = [IO.File]::OpenRead($file.FullName)
            try {
                $fileStream.CopyTo($entryStream)
            } finally {
                $fileStream.Dispose()
                $entryStream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

function Expand-PitCrewRemoteDiagnosticsZip {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )

    Add-Type -AssemblyName System.IO.Compression
    $allowedFiles = @(
        'pitcrew-diagnostics.json',
        'pitcrew-diagnostics.md',
        'result-manifest.json')
    $stream = [IO.File]::OpenRead($LiteralPath)
    $archive = [IO.Compression.ZipArchive]::new(
        $stream,
        [IO.Compression.ZipArchiveMode]::Read,
        $false)
    try {
        $entryNames = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -notin $allowedFiles -or
                $entry.FullName.Contains('/') -or
                $entry.FullName.Contains('\') -or
                $entry.Length -gt 4194304 -or
                -not $entryNames.Add($entry.FullName)) {
                throw 'The returned diagnostics archive contains an unsupported entry.'
            }
        }
        if ($entryNames.Count -ne $allowedFiles.Count) {
            throw 'The returned diagnostics archive is incomplete.'
        }
        if (Test-Path -LiteralPath $DestinationDirectory) {
            throw 'The run-scoped import directory already exists.'
        }
        $null = New-Item `
            -ItemType Directory `
            -Path $DestinationDirectory
        foreach ($entry in $archive.Entries) {
            $destination = Join-Path $DestinationDirectory $entry.FullName
            $sourceStream = $entry.Open()
            $destinationStream = [IO.File]::Open(
                $destination,
                [IO.FileMode]::Create,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None)
            try {
                $sourceStream.CopyTo($destinationStream)
            } finally {
                $destinationStream.Dispose()
                $sourceStream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

function Write-PitCrewRemoteDiagnosticsArtifacts {
    param(
        [Parameter(Mandatory)][object]$Envelope,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $jsonPath = Join-Path $OutputDirectory 'pitcrew-diagnostics.json'
    $markdownPath = Join-Path $OutputDirectory 'pitcrew-diagnostics.md'
    $manifestPath = Join-Path $OutputDirectory 'result-manifest.json'
    Write-PitCrewRemoteDiagnosticsUtf8 `
        -LiteralPath $jsonPath `
        -Content ($Envelope.report | ConvertTo-Json -Depth 100)
    Write-PitCrewRemoteDiagnosticsUtf8 `
        -LiteralPath $markdownPath `
        -Content ([string]$Envelope.markdown)
    $manifest = [PSCustomObject][ordered]@{
        schemaVersion = 1
        packageId = $Envelope.report.packageId
        collectorVersion = $Envelope.report.collectorVersion
        generatedAt = [DateTimeOffset]::UtcNow
        files = @(
            [PSCustomObject][ordered]@{
                name = 'pitcrew-diagnostics.json'
                sha256 = Get-PitCrewRemoteDiagnosticsSha256 $jsonPath
            },
            [PSCustomObject][ordered]@{
                name = 'pitcrew-diagnostics.md'
                sha256 = Get-PitCrewRemoteDiagnosticsSha256 $markdownPath
            })
    }
    Write-PitCrewRemoteDiagnosticsUtf8 `
        -LiteralPath $manifestPath `
        -Content ($manifest | ConvertTo-Json -Depth 20)
    return [PSCustomObject][ordered]@{
        outputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
        jsonPath = (Resolve-Path -LiteralPath $jsonPath).Path
        markdownPath = (Resolve-Path -LiteralPath $markdownPath).Path
        manifestPath = (Resolve-Path -LiteralPath $manifestPath).Path
    }
}

function Test-PitCrewRemoteDiagnosticsForbiddenProperty {
    param([Parameter(Mandatory)][object]$Value)

    $forbidden = '(?i)(credential|secret|token|password|passwd|apikey|api_key|privatekey|authorization|cookie|environment|jit|registrationpayload|joboutput|connectoridentity)'
    $pending = [Collections.Generic.Queue[object]]::new()
    $pending.Enqueue($Value)
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        if ($null -eq $current) {
            continue
        }
        if ($current -is [string] -or
            $current.GetType().IsPrimitive -or
            $current.GetType().IsValueType) {
            continue
        }
        if ($current -is [Collections.IDictionary]) {
            foreach ($key in $current.Keys) {
                if ([string]$key -match $forbidden) {
                    return $true
                }
                $pending.Enqueue($current[$key])
            }
            continue
        }
        if ($current -is [Collections.IEnumerable] -and
            $current -isnot [PSCustomObject]) {
            foreach ($item in $current) {
                $pending.Enqueue($item)
            }
            continue
        }
        foreach ($property in $current.PSObject.Properties) {
            if ($property.Name -match $forbidden) {
                return $true
            }
            $pending.Enqueue($property.Value)
        }
    }
    return $false
}

function Assert-PitCrewRemoteDiagnosticsProperties {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Context
    )

    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -notin $Allowed) {
            throw "$Context contains unsupported property '$($property.Name)'."
        }
    }
}

function ConvertTo-PitCrewRemoteDiagnosticsSafeText {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Context,
        [ValidateRange(1, 4096)][int]$MaximumLength = 1024
    )

    if ($null -eq $Value) {
        return $null
    }
    $text = [string]$Value
    if ($text.Length -gt $MaximumLength -or
        $text -match '[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]' -or
        $text -match '(?i)(password|passwd|secret|api[_-]?key|access[_-]?token|bearer\s|authorization\s|private[_-]?key|BEGIN [A-Z ]*PRIVATE KEY)' -or
        $text -match '(?i)(?:[A-Z]:\\|/(?:home|Users|var/lib|tmp)/)' -or
        $text -match 'https?://\S+\?') {
        throw "$Context contains unsafe or unbounded text."
    }
    return $text
}

function ConvertTo-PitCrewRemoteDiagnosticsUnavailable {
    param([AllowNull()][object[]]$Items)

    $boundedItems = @($Items | Where-Object { $null -ne $_ })
    if ($boundedItems.Count -gt 256) {
        throw 'Unavailable evidence exceeds its bounded item count.'
    }
    return @(
        foreach ($item in $boundedItems) {
            Assert-PitCrewRemoteDiagnosticsProperties `
                -Value $item `
                -Allowed @('category', 'reason', 'followUp') `
                -Context 'Unavailable evidence'
            [PSCustomObject][ordered]@{
                category = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $item.category `
                    -Context 'Unavailable evidence category' `
                    -MaximumLength 128
                reason = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $item.reason `
                    -Context 'Unavailable evidence reason'
                followUp = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $item.followUp `
                    -Context 'Unavailable evidence follow-up'
            }
        })
}

function ConvertTo-PitCrewRemoteDiagnosticsHypotheses {
    param([AllowNull()][object[]]$Items)

    $boundedItems = @($Items | Where-Object { $null -ne $_ })
    if ($boundedItems.Count -gt 64) {
        throw 'Hypotheses exceed their bounded item count.'
    }
    return @(
        foreach ($item in $boundedItems) {
            Assert-PitCrewRemoteDiagnosticsProperties `
                -Value $item `
                -Allowed @('rank', 'hypothesis', 'evidence', 'followUp') `
                -Context 'Hypothesis'
            [PSCustomObject][ordered]@{
                rank = [int]$item.rank
                hypothesis = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $item.hypothesis `
                    -Context 'Hypothesis text'
                evidence = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $item.evidence `
                    -Context 'Hypothesis evidence'
                followUp = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $item.followUp `
                    -Context 'Hypothesis follow-up'
            }
        })
}

function ConvertTo-PitCrewRemoteDiagnosticsUrl {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    if ($null -eq $Value) {
        return $null
    }
    $uri = $null
    if (-not [Uri]::TryCreate(
            [string]$Value,
            [UriKind]::Absolute,
            [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw "$Context contains an unsafe URL."
    }
    return $uri.AbsoluteUri
}

function ConvertTo-PitCrewRemoteDiagnosticsInteger {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    if ($null -eq $Value) {
        return $null
    }
    $parsed = 0L
    if (-not [long]::TryParse(
            [string]$Value,
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed) -or
        $parsed -lt 0) {
        throw "$Context is not a non-negative integer."
    }
    return $parsed
}

function ConvertTo-PitCrewRemoteDiagnosticsTimestamp {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    if ($null -eq $Value) {
        return $null
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed)) {
        throw "$Context is not a timestamp."
    }
    return $parsed.ToUniversalTime()
}

function ConvertTo-PitCrewRemoteDiagnosticsGuid {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    if ($null -eq $Value) {
        return $null
    }
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$Value, [ref]$parsed)) {
        throw "$Context is not a GUID."
    }
    return $parsed
}

function ConvertTo-PitCrewRemoteDiagnosticsReportSummary {
    param([Parameter(Mandatory)][object]$Report)

    Assert-PitCrewRemoteDiagnosticsProperties `
        -Value $Report `
        -Allowed @(
            'schemaVersion',
            'collectorVersion',
            'collectorSha256',
            'packageId',
            'diagnosticMode',
            'platform',
            'platformSource',
            'profile',
            'pitcrewRoot',
            'startedAt',
            'completedAt',
            'verifiedMeasurements',
            'unavailableEvidence',
            'hypotheses') `
        -Context 'Diagnostics report'
    $verified = $Report.verifiedMeasurements
    Assert-PitCrewRemoteDiagnosticsProperties `
        -Value $verified `
        -Allowed @(
            'pitcrewVersion',
            'state',
            'connectorHealth',
            'containers',
            'capacity',
            'hostCapacity',
            'resourceWindow',
            'urlProbes',
            'commands') `
        -Context 'Verified measurements'
    $state = $verified.state
    Assert-PitCrewRemoteDiagnosticsProperties `
        -Value $state `
        -Allowed @('desired', 'acknowledged', 'static', 'observed') `
        -Context 'State measurements'
    $desired = $state.desired
    $acknowledged = $state.acknowledged
    $observed = $state.observed
    $static = $state.static
    Assert-PitCrewRemoteDiagnosticsProperties `
        -Value $desired `
        -Allowed @('generation', 'scope', 'replicas', 'repositories') `
        -Context 'Desired state'
    Assert-PitCrewRemoteDiagnosticsProperties `
        -Value $acknowledged `
        -Allowed @(
            'status',
            'generation',
            'observedAt',
            'desiredSlots',
            'addedSlots',
            'drainingSlots',
            'unchangedSlots') `
        -Context 'Acknowledged state'
    Assert-PitCrewRemoteDiagnosticsProperties `
        -Value $static `
        -Allowed @(
            'fingerprint',
            'workerRevision',
            'managerContractVersion',
            'workerRuntimeContractVersion',
            'image',
            'resolvedImageId',
            'pullImage',
            'scope',
            'autoscaling',
            'resources') `
        -Context 'Static state'
    Assert-PitCrewRemoteDiagnosticsProperties `
        -Value $observed `
        -Allowed @(
            'managerContractVersion',
            'managerStatus',
            'observedAt',
            'freshnessSeconds',
            'generation',
            'desiredStateStatus',
            'desiredSlots',
            'configuredSlots',
            'activeSlots',
            'eligibleSlots',
            'drainingSlots',
            'slots',
            'autoscaling',
            'update',
            'hostPressure') `
        -Context 'Observed state'
    $connectorSnapshot = Get-PitCrewRemoteDiagnosticsProperty `
        (Get-PitCrewRemoteDiagnosticsProperty `
            $verified `
            'connectorHealth') `
        'snapshot'
    $connectorSummary = if ($null -eq $connectorSnapshot) {
        $null
    } else {
        Assert-PitCrewRemoteDiagnosticsProperties `
            -Value $connectorSnapshot `
            -Allowed @(
                'schemaVersion',
                'state',
                'processStartedAt',
                'updatedAt',
                'lastAttemptAt',
                'lastSuccessAt',
                'activeOutageId',
                'activeOutageStartedAt',
                'lastFailureAt',
                'lastFailureCategory',
                'lastFailureProfileId',
                'lastFailureDetail',
                'consecutiveFailures',
                'nextRetryAt',
                'lastRecoveredOutageId',
                'lastRecoveredOutageStartedAt',
                'lastRecoveredAt',
                'lastRecoveredFailureCategory') `
            -Context 'Connector health snapshot'
        [PSCustomObject][ordered]@{
            state = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                -Value $connectorSnapshot.state `
                -Context 'Connector state' `
                -MaximumLength 32
            updatedAt = ConvertTo-PitCrewRemoteDiagnosticsTimestamp `
                -Value $connectorSnapshot.updatedAt `
                -Context 'Connector update time'
            lastAttemptAt = ConvertTo-PitCrewRemoteDiagnosticsTimestamp `
                -Value $connectorSnapshot.lastAttemptAt `
                -Context 'Connector attempt time'
            lastSuccessAt = ConvertTo-PitCrewRemoteDiagnosticsTimestamp `
                -Value $connectorSnapshot.lastSuccessAt `
                -Context 'Connector success time'
            activeOutageId = ConvertTo-PitCrewRemoteDiagnosticsGuid `
                -Value $connectorSnapshot.activeOutageId `
                -Context 'Connector outage ID'
            activeOutageStartedAt =
                ConvertTo-PitCrewRemoteDiagnosticsTimestamp `
                    -Value $connectorSnapshot.activeOutageStartedAt `
                    -Context 'Connector outage start'
            lastFailureAt = ConvertTo-PitCrewRemoteDiagnosticsTimestamp `
                -Value $connectorSnapshot.lastFailureAt `
                -Context 'Connector failure time'
            lastFailureCategory = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                -Value $connectorSnapshot.lastFailureCategory `
                -Context 'Connector failure category' `
                -MaximumLength 128
            consecutiveFailures =
                ConvertTo-PitCrewRemoteDiagnosticsInteger `
                    -Value $connectorSnapshot.consecutiveFailures `
                    -Context 'Connector consecutive failures'
            nextRetryAt = ConvertTo-PitCrewRemoteDiagnosticsTimestamp `
                -Value $connectorSnapshot.nextRetryAt `
                -Context 'Connector retry time'
            lastRecoveredAt = ConvertTo-PitCrewRemoteDiagnosticsTimestamp `
                -Value $connectorSnapshot.lastRecoveredAt `
                -Context 'Connector recovery time'
            lastRecoveredFailureCategory =
                ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $connectorSnapshot.lastRecoveredFailureCategory `
                    -Context 'Recovered connector failure category' `
                    -MaximumLength 128
        }
    }
    $capacityItems = @(
        $verified.capacity |
            Where-Object { $null -ne $_ })
    if ($capacityItems.Count -gt 512) {
        throw 'Capacity evidence exceeds its bounded target count.'
    }
    $capacity = @(
        foreach ($item in $capacityItems) {
            Assert-PitCrewRemoteDiagnosticsProperties `
                -Value $item `
                -Allowed @(
                    'target',
                    'desiredWorkers',
                    'liveWorkers',
                    'observedSlots',
                    'registeredWorkers',
                    'states',
                    'scaleSet',
                    'mismatch') `
                -Context 'Capacity target'
            $target = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                -Value $item.target `
                -Context 'Capacity target' `
                -MaximumLength 256
            if ($target -notmatch '^<(?:scope|unmapped:[A-Za-z0-9._:-]+)>$') {
                $target = ConvertTo-PitCrewRemoteDiagnosticsUrl `
                    -Value $target `
                    -Context 'Capacity target'
            }
            [PSCustomObject][ordered]@{
                target = $target
                desiredWorkers =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $item.desiredWorkers `
                        -Context 'Desired workers'
                liveWorkers =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $item.liveWorkers `
                        -Context 'Live workers'
                observedSlots =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $item.observedSlots `
                        -Context 'Observed slots'
                registeredWorkers =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $item.registeredWorkers `
                        -Context 'Registered workers'
                mismatch = [bool]$item.mismatch
            }
        })
    $containers = $verified.containers
    Assert-PitCrewRemoteDiagnosticsProperties `
        -Value $containers `
        -Allowed @('managers', 'workers', 'images') `
        -Context 'Container evidence'
    $managerItems = @(
        $containers.managers |
            Where-Object { $null -ne $_ })
    foreach ($manager in $managerItems) {
        Assert-PitCrewRemoteDiagnosticsProperties `
            -Value $manager `
            -Allowed @('id', 'image', 'status') `
            -Context 'Manager container'
    }
    $workers = @(
        $containers.workers |
            Where-Object { $null -ne $_ })
    $writableLayerBytes = 0L
    foreach ($worker in $workers) {
        Assert-PitCrewRemoteDiagnosticsProperties `
            -Value $worker `
            -Allowed @(
                'id',
                'image',
                'status',
                'slotKey',
                'workerRevision',
                'imageId',
                'sizeRwBytes',
                'sizeRootFsBytes') `
            -Context 'Worker container'
        if ($null -ne $worker.sizeRwBytes) {
            $writableLayerBytes +=
                ConvertTo-PitCrewRemoteDiagnosticsInteger `
                    -Value $worker.sizeRwBytes `
                    -Context 'Worker writable layer'
        }
    }
    foreach ($image in @(
            $containers.images |
                Where-Object { $null -ne $_ })) {
        Assert-PitCrewRemoteDiagnosticsProperties `
            -Value $image `
            -Allowed @('role', 'reference', 'imageId', 'repoDigests') `
            -Context 'Image evidence'
    }
    $urlItems = @(
        $verified.urlProbes |
            Where-Object { $null -ne $_ })
    if ($urlItems.Count -gt 8) {
        throw 'URL evidence exceeds the bounded probe count.'
    }
    $urlProbes = @(
        foreach ($probe in $urlItems) {
            Assert-PitCrewRemoteDiagnosticsProperties `
                -Value $probe `
                -Allowed @(
                    'origin',
                    'url',
                    'status',
                    'httpStatus',
                    'remoteIp',
                    'dnsSeconds',
                    'connectSeconds',
                    'tlsSeconds',
                    'firstByteSeconds',
                    'totalSeconds',
                    'bytesDownloaded',
                    'bytesPerSecond') `
                -Context 'URL probe'
            $remoteIp = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                -Value $probe.remoteIp `
                -Context 'URL probe remote IP' `
                -MaximumLength 64
            if ($null -ne $remoteIp) {
                $parsedAddress = $null
                if (-not [Net.IPAddress]::TryParse(
                        $remoteIp,
                        [ref]$parsedAddress)) {
                    throw 'URL probe remote IP is invalid.'
                }
            }
            [PSCustomObject][ordered]@{
                origin = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $probe.origin `
                    -Context 'URL probe origin' `
                    -MaximumLength 16
                url = ConvertTo-PitCrewRemoteDiagnosticsUrl `
                    -Value $probe.url `
                    -Context 'URL probe'
                status = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $probe.status `
                    -Context 'URL probe status' `
                    -MaximumLength 32
                httpStatus = if ($null -eq $probe.httpStatus) {
                    $null
                } else {
                    $statusCode =
                        ConvertTo-PitCrewRemoteDiagnosticsInteger `
                            -Value $probe.httpStatus `
                            -Context 'URL HTTP status'
                    if ($statusCode -gt 599) {
                        throw 'URL HTTP status is outside the valid range.'
                    }
                    $statusCode
                }
                remoteIp = $remoteIp
                dnsSeconds = if ($null -eq $probe.dnsSeconds) {
                    $null
                } else {
                    [double]$probe.dnsSeconds
                }
                connectSeconds = if ($null -eq $probe.connectSeconds) {
                    $null
                } else {
                    [double]$probe.connectSeconds
                }
                tlsSeconds = if ($null -eq $probe.tlsSeconds) {
                    $null
                } else {
                    [double]$probe.tlsSeconds
                }
                firstByteSeconds = if ($null -eq $probe.firstByteSeconds) {
                    $null
                } else {
                    [double]$probe.firstByteSeconds
                }
                totalSeconds = if ($null -eq $probe.totalSeconds) {
                    $null
                } else {
                    [double]$probe.totalSeconds
                }
                bytesDownloaded =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $probe.bytesDownloaded `
                        -Context 'Downloaded bytes'
                bytesPerSecond =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $probe.bytesPerSecond `
                        -Context 'Download throughput'
            }
        })
    $pitcrewVersion = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
        -Value $verified.pitcrewVersion `
        -Context 'PitCrew version' `
        -MaximumLength 128
    if ($null -ne $pitcrewVersion -and
        $pitcrewVersion -notmatch '^[A-Za-z0-9._+/-]{1,128}$') {
        throw 'PitCrew version evidence is invalid.'
    }
    return [PSCustomObject][ordered]@{
        startedAt = ConvertTo-PitCrewRemoteDiagnosticsTimestamp `
            -Value $Report.startedAt `
            -Context 'Collection start'
        completedAt = ConvertTo-PitCrewRemoteDiagnosticsTimestamp `
            -Value $Report.completedAt `
            -Context 'Collection completion'
        unavailableEvidence =
            ConvertTo-PitCrewRemoteDiagnosticsUnavailable `
                -Items @($Report.unavailableEvidence)
        hypotheses =
            ConvertTo-PitCrewRemoteDiagnosticsHypotheses `
                -Items @($Report.hypotheses)
        verifiedMeasurements = [PSCustomObject][ordered]@{
            pitcrewVersion = $pitcrewVersion
            state = [PSCustomObject][ordered]@{
                desiredGeneration =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $desired.generation `
                        -Context 'Desired generation'
                acknowledgedGeneration =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $acknowledged.generation `
                        -Context 'Acknowledged generation'
                observedGeneration =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $observed.generation `
                        -Context 'Observed generation'
                managerStatus = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $observed.managerStatus `
                    -Context 'Manager status' `
                    -MaximumLength 64
                observedAt = ConvertTo-PitCrewRemoteDiagnosticsTimestamp `
                    -Value $observed.observedAt `
                    -Context 'Observed-state time'
                freshnessSeconds = if ($null -eq $observed.freshnessSeconds) {
                    $null
                } else {
                    [double]$observed.freshnessSeconds
                }
                desiredStateStatus =
                    ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                        -Value $observed.desiredStateStatus `
                        -Context 'Desired-state status' `
                        -MaximumLength 64
                desiredSlots =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $observed.desiredSlots `
                        -Context 'Desired slots'
                configuredSlots =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $observed.configuredSlots `
                        -Context 'Configured slots'
                activeSlots =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $observed.activeSlots `
                        -Context 'Active slots'
                eligibleSlots =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $observed.eligibleSlots `
                        -Context 'Eligible slots'
                drainingSlots =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $observed.drainingSlots `
                        -Context 'Draining slots'
                managerContractVersion =
                    ConvertTo-PitCrewRemoteDiagnosticsInteger `
                        -Value $observed.managerContractVersion `
                        -Context 'Manager contract version'
                workerRevision = if ($null -eq $static.workerRevision) {
                    $null
                } elseif (
                    [string]$static.workerRevision -match '^[a-f0-9]{64}$'
                ) {
                    [string]$static.workerRevision
                } else {
                    throw 'Worker revision evidence is invalid.'
                }
                hostPressure = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value (Get-PitCrewRemoteDiagnosticsProperty `
                        $observed.hostPressure `
                        'state') `
                    -Context 'Host pressure state' `
                    -MaximumLength 64
            }
            connectorHealth = $connectorSummary
            capacity = $capacity
            containers = [PSCustomObject][ordered]@{
                managerCount = $managerItems.Count
                workerCount = $workers.Count
                writableLayerBytes = $writableLayerBytes
            }
            urlProbes = $urlProbes
        }
    }
}

function ConvertTo-PitCrewRemoteDiagnosticsPreflightSummary {
    param([AllowNull()][object]$Preflight)

    if ($null -eq $Preflight) {
        return $null
    }
    Assert-PitCrewRemoteDiagnosticsProperties `
        -Value $Preflight `
        -Allowed @(
            'schemaVersion',
            'capturedAt',
            'diagnosticMode',
            'dashboard',
            'github',
            'releases',
            'unavailableEvidence') `
        -Context 'Preflight'
    $dashboard = $Preflight.dashboard
    Assert-PitCrewRemoteDiagnosticsProperties `
        -Value $dashboard `
        -Allowed @(
            'nodeId',
            'status',
            'lastSeenAt',
            'incident',
            'publicEndpoint') `
        -Context 'Dashboard preflight'
    $endpoint = $dashboard.publicEndpoint
    $endpointSummary = if ($null -eq $endpoint) {
        $null
    } else {
        Assert-PitCrewRemoteDiagnosticsProperties `
            -Value $endpoint `
            -Allowed @('url', 'reachable', 'statusCode', 'observedAt') `
            -Context 'Dashboard endpoint preflight'
        [PSCustomObject][ordered]@{
            url = ConvertTo-PitCrewRemoteDiagnosticsUrl `
                -Value $endpoint.url `
                -Context 'Dashboard endpoint'
            reachable = [bool]$endpoint.reachable
            statusCode = $endpoint.statusCode
            observedAt = $endpoint.observedAt
        }
    }
    $github = $Preflight.github
    $githubSummary = if ($null -eq $github) {
        $null
    } else {
        Assert-PitCrewRemoteDiagnosticsProperties `
            -Value $github `
            -Allowed @(
                'repository',
                'runId',
                'runStatus',
                'runConclusion',
                'runCreatedAt',
                'runUpdatedAt',
                'runUrl',
                'job') `
            -Context 'GitHub preflight'
        $job = $github.job
        $jobSummary = if ($null -eq $job) {
            $null
        } else {
            Assert-PitCrewRemoteDiagnosticsProperties `
                -Value $job `
                -Allowed @(
                    'jobId',
                    'name',
                    'status',
                    'conclusion',
                    'startedAt',
                    'completedAt',
                    'url') `
                -Context 'GitHub job preflight'
            [PSCustomObject][ordered]@{
                jobId = [string]$job.jobId
                status = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $job.status `
                    -Context 'GitHub job status' `
                    -MaximumLength 64
                conclusion = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                    -Value $job.conclusion `
                    -Context 'GitHub job conclusion' `
                    -MaximumLength 64
                startedAt = $job.startedAt
                completedAt = $job.completedAt
                url = ConvertTo-PitCrewRemoteDiagnosticsUrl `
                    -Value $job.url `
                    -Context 'GitHub job URL'
            }
        }
        [PSCustomObject][ordered]@{
            repository = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                -Value $github.repository `
                -Context 'GitHub repository' `
                -MaximumLength 160
            runId = [string]$github.runId
            runStatus = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                -Value $github.runStatus `
                -Context 'GitHub run status' `
                -MaximumLength 64
            runConclusion = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                -Value $github.runConclusion `
                -Context 'GitHub run conclusion' `
                -MaximumLength 64
            runCreatedAt = $github.runCreatedAt
            runUpdatedAt = $github.runUpdatedAt
            runUrl = ConvertTo-PitCrewRemoteDiagnosticsUrl `
                -Value $github.runUrl `
                -Context 'GitHub run URL'
            job = $jobSummary
        }
    }
    if ($null -ne $githubSummary -and
        $githubSummary.repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'GitHub repository evidence is invalid.'
    }
    Assert-PitCrewRemoteDiagnosticsProperties `
        -Value $Preflight.releases `
        -Allowed @('pitcrew', 'dashboard') `
        -Context 'Release preflight'
    $releaseSummary = [ordered]@{}
    foreach ($releaseName in @('pitcrew', 'dashboard')) {
        $release = Get-PitCrewRemoteDiagnosticsProperty `
            $Preflight.releases `
            $releaseName
        if ($null -eq $release) {
            $releaseSummary[$releaseName] = $null
            continue
        }
        Assert-PitCrewRemoteDiagnosticsProperties `
            -Value $release `
            -Allowed @('tagName', 'publishedAt', 'url') `
            -Context "$releaseName release preflight"
        $tagName = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
            -Value $release.tagName `
            -Context "$releaseName release tag" `
            -MaximumLength 128
        if ($tagName -notmatch '^v?[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?$') {
            throw "$releaseName release tag is invalid."
        }
        $releaseSummary[$releaseName] = [PSCustomObject][ordered]@{
            tagName = $tagName
            publishedAt = ConvertTo-PitCrewRemoteDiagnosticsTimestamp `
                -Value $release.publishedAt `
                -Context "$releaseName release publication time"
            url = ConvertTo-PitCrewRemoteDiagnosticsUrl `
                -Value $release.url `
                -Context "$releaseName release URL"
        }
    }
    $nodeId = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
        -Value $dashboard.nodeId `
        -Context 'Dashboard node ID' `
        -MaximumLength 64
    if ($null -ne $nodeId) {
        $parsedNodeId = [Guid]::Empty
        if (-not [Guid]::TryParse($nodeId, [ref]$parsedNodeId)) {
            throw 'Dashboard node ID is invalid.'
        }
    }
    return [PSCustomObject][ordered]@{
        capturedAt = $Preflight.capturedAt
        diagnosticMode = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
            -Value $Preflight.diagnosticMode `
            -Context 'Preflight diagnostic mode' `
            -MaximumLength 64
        dashboard = [PSCustomObject][ordered]@{
            nodeId = $nodeId
            status = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                -Value $dashboard.status `
                -Context 'Dashboard node status' `
                -MaximumLength 64
            lastSeenAt = $dashboard.lastSeenAt
            incident = ConvertTo-PitCrewRemoteDiagnosticsSafeText `
                -Value $dashboard.incident `
                -Context 'Dashboard incident' `
                -MaximumLength 128
            publicEndpoint = $endpointSummary
        }
        github = $githubSummary
        releases = [PSCustomObject]$releaseSummary
        unavailableEvidence =
            ConvertTo-PitCrewRemoteDiagnosticsUnavailable `
                -Items @($Preflight.unavailableEvidence)
    }
}

function New-PitCrewRemoteDiagnosticsDiagnosis {
    param(
        [Parameter(Mandatory)][object]$Report,
        [AllowNull()][object]$Preflight
    )

    $reportSummary = ConvertTo-PitCrewRemoteDiagnosticsReportSummary `
        -Report $Report
    $preflightSummary = ConvertTo-PitCrewRemoteDiagnosticsPreflightSummary `
        -Preflight $Preflight
    $preflightCapturedAt = if ($null -eq $preflightSummary) {
        $null
    } else {
        $preflightSummary.capturedAt
    }
    $activeOutageStartedAt = Get-PitCrewRemoteDiagnosticsProperty `
        $reportSummary.verifiedMeasurements.connectorHealth `
        'activeOutageStartedAt'
    $correlation = [PSCustomObject][ordered]@{
        preflightCapturedAt = $preflightCapturedAt
        collectionStartedAt = $reportSummary.startedAt
        collectionCompletedAt = $reportSummary.completedAt
        preflightToCollectionSeconds = if ($null -eq $preflightCapturedAt) {
            $null
        } else {
            [Math]::Round(
                ($reportSummary.startedAt -
                    ([DateTimeOffset]$preflightCapturedAt)).TotalSeconds,
                3)
        }
        activeConnectorOutageOverlappedCollection = if (
            $null -eq $activeOutageStartedAt
        ) {
            $false
        } else {
            ([DateTimeOffset]$activeOutageStartedAt) -le
                $reportSummary.completedAt
        }
    }
    return [PSCustomObject][ordered]@{
        schemaVersion = 1
        packageId = $Report.packageId
        generatedAt = [DateTimeOffset]::UtcNow
        correlation = $correlation
        verifiedMeasurements = [PSCustomObject][ordered]@{
            preflight = $preflightSummary
            host = $reportSummary.verifiedMeasurements
        }
        unavailableEvidence = @($reportSummary.unavailableEvidence)
        hypotheses = @($reportSummary.hypotheses)
    }
}

function New-PitCrewRemoteDiagnosticsDiagnosisMarkdown {
    param([Parameter(Mandatory)][object]$Diagnosis)

    $builder = [Text.StringBuilder]::new()
    $null = $builder.AppendLine('# PitCrew remote diagnosis')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("- Package: ``$($Diagnosis.packageId)``")
    $null = $builder.AppendLine("- Collection window: ``$($Diagnosis.correlation.collectionStartedAt)`` to ``$($Diagnosis.correlation.collectionCompletedAt)``")
    $null = $builder.AppendLine("- Preflight-to-collection delay: ``$($Diagnosis.correlation.preflightToCollectionSeconds)`` seconds")
    $null = $builder.AppendLine("- Active connector outage overlapped collection: ``$($Diagnosis.correlation.activeConnectorOutageOverlappedCollection)``")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Verified measurements')
    $null = $builder.AppendLine()
    if ($null -eq $Diagnosis.verifiedMeasurements.preflight) {
        $null = $builder.AppendLine('- No preflight artifact was supplied.')
    } else {
        $null = $builder.AppendLine('- Remote-first preflight evidence was supplied and timestamp-correlated.')
    }
    $state = $Diagnosis.verifiedMeasurements.host.state
    $null = $builder.AppendLine("- Manager status: ``$($state.managerStatus)``")
    $null = $builder.AppendLine("- Observed-state freshness: ``$($state.freshnessSeconds)`` seconds")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Unavailable evidence')
    $null = $builder.AppendLine()
    if (@($Diagnosis.unavailableEvidence).Count -eq 0) {
        $null = $builder.AppendLine('- None.')
    } else {
        foreach ($item in $Diagnosis.unavailableEvidence) {
            $null = $builder.AppendLine("- **$($item.category):** $($item.reason) Follow-up: $($item.followUp)")
        }
    }
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Hypotheses')
    $null = $builder.AppendLine()
    foreach ($item in $Diagnosis.hypotheses) {
        $null = $builder.AppendLine("$($item.rank). **$($item.hypothesis)** $($item.evidence) Follow-up: $($item.followUp)")
    }
    return $builder.ToString()
}
