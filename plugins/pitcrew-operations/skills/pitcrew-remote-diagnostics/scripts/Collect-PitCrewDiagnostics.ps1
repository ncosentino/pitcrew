#Requires -Version 7.0
<#
.SYNOPSIS
Collects a bounded, read-only PitCrew host diagnostic report.

.DESCRIPTION
Reads only generated non-secret PitCrew state, the standard connector health
journal, exact-label Docker evidence, and optional caller-approved URL timing.
It never reads environment files, connector identity, job output, JIT material,
or registration payloads.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PitCrewRoot,

    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
    [string]$Profile,

    [ValidateSet(
        'ConnectorOffline',
        'CapacityMismatch',
        'JobNotAssigned',
        'HostPressure',
        'Full')]
    [string]$DiagnosticMode = 'Full',

    [ValidateSet('Auto', 'Windows', 'Linux')]
    [string]$Platform = 'Auto',

    [ValidateCount(0, 4)]
    [Uri[]]$ApprovedUrl = @(),

    [ValidateRange(1, 900)]
    [int]$ProbeTimeoutSeconds = 300,

    [string]$OutputDirectory,

    [ValidatePattern('^[a-f0-9]{16,64}$')]
    [string]$PackageId,

    [switch]$PassThruOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CollectorVersion = '1.0.0'
$script:Unavailable = [Collections.Generic.List[object]]::new()
$script:Commands = [Collections.Generic.List[object]]::new()

function Get-PitCrewProperty {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

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

function ConvertTo-PitCrewMarkdownText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ''
    }
    $text = [regex]::Replace([string]$Value, '\s+', ' ')
    foreach ($replacement in @(
            @('\', '&#92;'),
            @('|', '&#124;'),
            @('`', '&#96;'),
            @('*', '&#42;'),
            @('_', '&#95;'),
            @('[', '&#91;'),
            @(']', '&#93;'))) {
        $text = $text.Replace($replacement[0], $replacement[1])
    }
    return $text
}

function Get-PitCrewSha256 {
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

function Add-PitCrewUnavailable {
    param(
        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Reason,

        [Parameter(Mandatory)]
        [string]$FollowUp
    )

    $script:Unavailable.Add([PSCustomObject][ordered]@{
        category = $Category
        reason = $Reason
        followUp = $FollowUp
    })
}

function Add-PitCrewUnreadableJson {
    param([Parameter(Mandatory)][string]$EvidenceName)

    Add-PitCrewUnavailable `
        -Category $EvidenceName `
        -Reason "$EvidenceName could not be read as valid JSON." `
        -FollowUp "Inspect the owning PitCrew component without opening secret files, then regenerate $EvidenceName."
}

function Read-PitCrewBoundedJson {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,

        [Parameter(Mandatory)]
        [string]$EvidenceName,

        [ValidateRange(1, 4194304)]
        [int]$MaximumBytes = 1048576
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        Add-PitCrewUnavailable `
            -Category $EvidenceName `
            -Reason "$EvidenceName is absent." `
            -FollowUp "Confirm the selected profile is configured and allow its manager or connector to publish $EvidenceName."
        return $null
    }
    try {
        $item = Get-Item -LiteralPath $LiteralPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Add-PitCrewUnavailable `
                -Category $EvidenceName `
                -Reason "$EvidenceName is linked outside its fixed state location." `
                -FollowUp 'Replace the linked diagnostic state with the supported regular file.'
            return $null
        }
        if ($item.Length -le 0 -or $item.Length -gt $MaximumBytes) {
            Add-PitCrewUnavailable `
                -Category $EvidenceName `
                -Reason "$EvidenceName is empty or exceeds its bounded size." `
                -FollowUp "Regenerate $EvidenceName through the supported PitCrew component."
            return $null
        }
        return Get-Content `
            -LiteralPath $LiteralPath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json -Depth 100 -ErrorAction Stop
    } catch [Management.Automation.RuntimeException] {
        Add-PitCrewUnreadableJson $EvidenceName
        return $null
    } catch [IO.IOException] {
        Add-PitCrewUnreadableJson $EvidenceName
        return $null
    } catch [UnauthorizedAccessException] {
        Add-PitCrewUnreadableJson $EvidenceName
        return $null
    }
}

function Test-PitCrewUnlinkedPath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    $base = [IO.Path]::GetFullPath($BasePath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $target = [IO.Path]::GetFullPath($TargetPath)
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    } else {
        [StringComparison]::Ordinal
    }
    if (-not $target.Equals($base, $comparison) -and
        -not $target.StartsWith(
            "$base$([IO.Path]::DirectorySeparatorChar)",
            $comparison)) {
        return $false
    }
    $current = $base
    $paths = [Collections.Generic.List[string]]::new()
    $paths.Add($current)
    $relative = [IO.Path]::GetRelativePath($base, $target)
    if ($relative -ne '.') {
        foreach ($segment in $relative -split '[\\/]') {
            $current = Join-Path $current $segment
            $paths.Add($current)
        }
    }
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
    }
    return $true
}

function Resolve-PitCrewProcessCommand {
    param([Parameter(Mandatory)][string]$Name)

    $command = Get-Command `
        -Name $Name `
        -CommandType Application, ExternalScript `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        return $null
    }
    if ($command.CommandType -eq 'ExternalScript') {
        $pwsh = Get-Command `
            -Name pwsh `
            -CommandType Application `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $pwsh) {
            return $null
        }
        return [PSCustomObject]@{
            fileName = $pwsh.Source
            prefixArguments = @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-File',
                $command.Source)
        }
    }
    return [PSCustomObject]@{
        fileName = $command.Source
        prefixArguments = @()
    }
}

function Invoke-PitCrewProcess {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$DisplayCommand,

        [ValidateRange(1, 7200)]
        [int]$TimeoutSeconds = 30
    )

    $resolved = Resolve-PitCrewProcessCommand -Name $Name
    $startedAt = [DateTimeOffset]::UtcNow
    if ($null -eq $resolved) {
        $script:Commands.Add([PSCustomObject][ordered]@{
            command = $DisplayCommand
            startedAt = $startedAt
            completedAt = [DateTimeOffset]::UtcNow
            exitCode = $null
            timedOut = $false
            status = 'unavailable'
        })
        return [PSCustomObject]@{
            available = $false
            exitCode = $null
            timedOut = $false
            output = ''
        }
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolved.fileName
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @($resolved.prefixArguments) + $Arguments) {
        $startInfo.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'The process did not start.'
        }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            try {
                $process.Kill($true)
            } catch [InvalidOperationException] {
            } catch [NotSupportedException] {
            }
            $process.WaitForExit()
        }
        $output = $outputTask.GetAwaiter().GetResult()
        $null = $errorTask.GetAwaiter().GetResult()
        $exitCode = if ($completed) {
            $process.ExitCode
        } else {
            $null
        }
        $script:Commands.Add([PSCustomObject][ordered]@{
            command = $DisplayCommand
            startedAt = $startedAt
            completedAt = [DateTimeOffset]::UtcNow
            exitCode = $exitCode
            timedOut = -not $completed
            status = if (-not $completed) {
                'timed-out'
            } elseif ($exitCode -eq 0) {
                'completed'
            } else {
                'failed'
            }
        })
        return [PSCustomObject]@{
            available = $true
            exitCode = $exitCode
            timedOut = -not $completed
            output = $output
        }
    } catch [ComponentModel.Win32Exception] {
        $script:Commands.Add([PSCustomObject][ordered]@{
            command = $DisplayCommand
            startedAt = $startedAt
            completedAt = [DateTimeOffset]::UtcNow
            exitCode = $null
            timedOut = $false
            status = 'failed'
        })
        return [PSCustomObject]@{
            available = $false
            exitCode = $null
            timedOut = $false
            output = ''
        }
    } catch [InvalidOperationException] {
        $script:Commands.Add([PSCustomObject][ordered]@{
            command = $DisplayCommand
            startedAt = $startedAt
            completedAt = [DateTimeOffset]::UtcNow
            exitCode = $null
            timedOut = $false
            status = 'failed'
        })
        return [PSCustomObject]@{
            available = $false
            exitCode = $null
            timedOut = $false
            output = ''
        }
    } catch [AggregateException] {
        $script:Commands.Add([PSCustomObject][ordered]@{
            command = $DisplayCommand
            startedAt = $startedAt
            completedAt = [DateTimeOffset]::UtcNow
            exitCode = $null
            timedOut = $false
            status = 'failed'
        })
        return [PSCustomObject]@{
            available = $false
            exitCode = $null
            timedOut = $false
            output = ''
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-PitCrewDocker {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$DisplayCommand,

        [ValidateRange(1, 7200)]
        [int]$TimeoutSeconds = 30
    )

    return Invoke-PitCrewProcess `
        -Name docker `
        -Arguments $Arguments `
        -DisplayCommand $DisplayCommand `
        -TimeoutSeconds $TimeoutSeconds
}

function ConvertFrom-PitCrewDelimitedLines {
    param(
        [AllowNull()]
        [string]$Text,

        [ValidateRange(1, 20)]
        [int]$MinimumFields
    )

    return @(
        foreach ($line in @($Text -split '\r?\n')) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $parts = @($line -split '\|')
            if ($parts.Count -ge $MinimumFields) {
                ,$parts
            }
        }
    )
}

function ConvertTo-PitCrewSizeBytes {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $trimmed = $Value.Trim()
    $match = [regex]::Match(
        $trimmed,
        '^(?<value>[0-9]+(?:\.[0-9]+)?)\s*(?<unit>B|kB|MB|GB|TB|KiB|MiB|GiB|TiB)$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }
    $number = [double]$match.Groups['value'].Value
    $factor = switch ($match.Groups['unit'].Value.ToLowerInvariant()) {
        'b' { 1 }
        'kb' { 1000 }
        'mb' { 1000000 }
        'gb' { 1000000000 }
        'tb' { 1000000000000 }
        'kib' { 1024 }
        'mib' { 1048576 }
        'gib' { 1073741824 }
        'tib' { 1099511627776 }
    }
    return [long][Math]::Round($number * $factor)
}

function ConvertTo-PitCrewSizePair {
    param([AllowNull()][string]$Value)

    $parts = @($Value -split '\s*/\s*')
    return [PSCustomObject][ordered]@{
        firstBytes = if ($parts.Count -ge 1) {
            ConvertTo-PitCrewSizeBytes $parts[0]
        } else {
            $null
        }
        secondBytes = if ($parts.Count -ge 2) {
            ConvertTo-PitCrewSizeBytes $parts[1]
        } else {
            $null
        }
    }
}

function ConvertTo-PitCrewSafeUrl {
    param([Parameter(Mandatory)][Uri]$Uri)

    if ($Uri.Scheme -notin @('http', 'https') -or
        -not [string]::IsNullOrEmpty($Uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($Uri.Query) -or
        -not [string]::IsNullOrEmpty($Uri.Fragment) -or
        [string]::IsNullOrWhiteSpace($Uri.Host) -or
        $Uri.Host -match '[$`{}]') {
        throw 'ApprovedUrl values must be literal HTTP or HTTPS URLs without credentials, query strings, fragments, or shell expansions.'
    }
    return $Uri.AbsoluteUri
}

function ConvertTo-PitCrewStateSummary {
    param(
        [AllowNull()][object]$Desired,
        [AllowNull()][object]$Acknowledged,
        [AllowNull()][object]$Static,
        [AllowNull()][object]$Observed,
        [Parameter(Mandatory)][DateTimeOffset]$CollectedAt
    )

    $observedAt = $null
    $observedAtValue = Get-PitCrewProperty $Observed 'observedAt'
    if ($null -ne $observedAtValue) {
        try {
            $observedAt = ([DateTimeOffset]$observedAtValue).ToUniversalTime()
        } catch [FormatException] {
            $observedAt = $null
        } catch [InvalidCastException] {
            $observedAt = $null
        }
    }
    $repositories = @(
        foreach ($repository in @(
                Get-PitCrewProperty $Desired 'repositories' @())) {
            [PSCustomObject][ordered]@{
                url = [string](Get-PitCrewProperty $repository 'url')
                workers = Get-PitCrewProperty $repository 'workers'
            }
        }
    )
    $slots = @(
        foreach ($slot in @(
                Get-PitCrewProperty $Observed 'slots' @())) {
            $currentJob = Get-PitCrewProperty $slot 'currentJob'
            [PSCustomObject][ordered]@{
                key = [string](Get-PitCrewProperty $slot 'key')
                repository = Get-PitCrewProperty $slot 'repository'
                desired = Get-PitCrewProperty $slot 'desired'
                processRunning = Get-PitCrewProperty $slot 'processRunning'
                state = Get-PitCrewProperty $slot 'state'
                activity = Get-PitCrewProperty $slot 'activity'
                registrationStatus = Get-PitCrewProperty $slot 'registrationStatus'
                target = Get-PitCrewProperty $slot 'target'
                currentJob = if ($null -eq $currentJob) {
                    $null
                } else {
                    [PSCustomObject][ordered]@{
                        repository = Get-PitCrewProperty $currentJob 'repository'
                        workflowRunId = Get-PitCrewProperty $currentJob 'workflowRunId'
                        jobId = Get-PitCrewProperty $currentJob 'jobId'
                        displayName = Get-PitCrewProperty $currentJob 'displayName'
                        eventName = Get-PitCrewProperty $currentJob 'eventName'
                        startedAt = Get-PitCrewProperty $currentJob 'startedAt'
                        finishedAt = Get-PitCrewProperty $currentJob 'finishedAt'
                        result = Get-PitCrewProperty $currentJob 'result'
                    }
                }
            }
        }
    )
    $autoscaling = Get-PitCrewProperty $Observed 'autoscaling'
    $autoscalingTargets = @(
        foreach ($target in @(
                Get-PitCrewProperty $autoscaling 'targets' @())) {
            $statistics = Get-PitCrewProperty $target 'statistics'
            [PSCustomObject][ordered]@{
                key = Get-PitCrewProperty $target 'key'
                repository = Get-PitCrewProperty $target 'repository'
                maximumSlots = Get-PitCrewProperty $target 'maximumSlots'
                targetSlots = Get-PitCrewProperty $target 'targetSlots'
                localActiveWorkers = Get-PitCrewProperty $target 'localActiveWorkers'
                localIdleWorkers = Get-PitCrewProperty $target 'localIdleWorkers'
                localBusyWorkers = Get-PitCrewProperty $target 'localBusyWorkers'
                localDrainingWorkers = Get-PitCrewProperty $target 'localDrainingWorkers'
                statistics = if ($null -eq $statistics) {
                    $null
                } else {
                    [PSCustomObject][ordered]@{
                        observedAt = Get-PitCrewProperty $statistics 'observedAt'
                        availableJobs = Get-PitCrewProperty $statistics 'availableJobs'
                        acquiredJobs = Get-PitCrewProperty $statistics 'acquiredJobs'
                        assignedJobs = Get-PitCrewProperty $statistics 'assignedJobs'
                        runningJobs = Get-PitCrewProperty $statistics 'runningJobs'
                        registeredRunners = Get-PitCrewProperty $statistics 'registeredRunners'
                        busyRunners = Get-PitCrewProperty $statistics 'busyRunners'
                        idleRunners = Get-PitCrewProperty $statistics 'idleRunners'
                    }
                }
            }
        }
    )
    $configuration = Get-PitCrewProperty $Static 'configuration'
    $update = Get-PitCrewProperty $Observed 'update'
    $resourceTelemetry = Get-PitCrewProperty $Observed 'resourceTelemetry'
    return [PSCustomObject][ordered]@{
        desired = [PSCustomObject][ordered]@{
            generation = Get-PitCrewProperty $Desired 'generation'
            scope = Get-PitCrewProperty $Desired 'scope'
            replicas = Get-PitCrewProperty $Desired 'replicas'
            repositories = $repositories
        }
        acknowledged = [PSCustomObject][ordered]@{
            status = Get-PitCrewProperty $Acknowledged 'status'
            generation = Get-PitCrewProperty $Acknowledged 'generation'
            observedAt = Get-PitCrewProperty $Acknowledged 'observedAt'
            desiredSlots = Get-PitCrewProperty $Acknowledged 'desiredSlots'
            addedSlots = Get-PitCrewProperty $Acknowledged 'addedSlots'
            drainingSlots = Get-PitCrewProperty $Acknowledged 'drainingSlots'
            unchangedSlots = Get-PitCrewProperty $Acknowledged 'unchangedSlots'
        }
        static = [PSCustomObject][ordered]@{
            fingerprint = Get-PitCrewProperty $Static 'fingerprint'
            workerRevision = Get-PitCrewProperty $Static 'workerRevision'
            managerContractVersion = Get-PitCrewProperty $configuration 'managerContractVersion'
            workerRuntimeContractVersion = Get-PitCrewProperty $configuration 'workerRuntimeContractVersion'
            image = Get-PitCrewProperty $configuration 'image'
            resolvedImageId = Get-PitCrewProperty $configuration 'resolvedImageId'
            pullImage = Get-PitCrewProperty $configuration 'pullImage'
            scope = Get-PitCrewProperty $configuration 'scope'
            autoscaling = Get-PitCrewProperty $configuration 'autoscaling'
            resources = Get-PitCrewProperty $configuration 'resources'
        }
        observed = [PSCustomObject][ordered]@{
            managerContractVersion = Get-PitCrewProperty $Observed 'managerContractVersion'
            managerStatus = Get-PitCrewProperty $Observed 'managerStatus'
            observedAt = $observedAt
            freshnessSeconds = if ($null -eq $observedAt) {
                $null
            } else {
                [Math]::Max(
                    0,
                    [Math]::Round(($CollectedAt - $observedAt).TotalSeconds, 3))
            }
            generation = Get-PitCrewProperty $Observed 'generation'
            desiredStateStatus = Get-PitCrewProperty $Observed 'desiredStateStatus'
            desiredSlots = Get-PitCrewProperty $Observed 'desiredSlots'
            configuredSlots = Get-PitCrewProperty $Observed 'configuredSlots'
            activeSlots = Get-PitCrewProperty $Observed 'activeSlots'
            eligibleSlots = Get-PitCrewProperty $Observed 'eligibleSlots'
            drainingSlots = Get-PitCrewProperty $Observed 'drainingSlots'
            slots = $slots
            autoscaling = if ($null -eq $autoscaling) {
                $null
            } else {
                [PSCustomObject][ordered]@{
                    mode = Get-PitCrewProperty $autoscaling 'mode'
                    status = Get-PitCrewProperty $autoscaling 'status'
                    minimumIdleSlots = Get-PitCrewProperty $autoscaling 'minimumIdleSlots'
                    maximumSlots = Get-PitCrewProperty $autoscaling 'maximumSlots'
                    targetSlots = Get-PitCrewProperty $autoscaling 'targetSlots'
                    assignedJobs = Get-PitCrewProperty $autoscaling 'assignedJobs'
                    runningJobs = Get-PitCrewProperty $autoscaling 'runningJobs'
                    availableJobs = Get-PitCrewProperty $autoscaling 'availableJobs'
                    idleRunners = Get-PitCrewProperty $autoscaling 'idleRunners'
                    busyRunners = Get-PitCrewProperty $autoscaling 'busyRunners'
                    errorReported = -not [string]::IsNullOrWhiteSpace(
                        [string](Get-PitCrewProperty $autoscaling 'lastError'))
                    targets = $autoscalingTargets
                }
            }
            update = if ($null -eq $update) {
                $null
            } else {
                [PSCustomObject][ordered]@{
                    status = Get-PitCrewProperty $update 'status'
                    targetImage = Get-PitCrewProperty $update 'targetImage'
                    targetImageId = Get-PitCrewProperty $update 'targetImageId'
                    targetRevision = Get-PitCrewProperty $update 'targetRevision'
                    currentWorkers = Get-PitCrewProperty $update 'currentWorkers'
                    staleWorkers = Get-PitCrewProperty $update 'staleWorkers'
                    errorReported = -not [string]::IsNullOrWhiteSpace(
                        [string](Get-PitCrewProperty $update 'lastError'))
                }
            }
            hostPressure = Get-PitCrewProperty $resourceTelemetry 'hostPressure'
            hostAdmission = Get-PitCrewProperty $Observed 'hostAdmission'
        }
    }
}

function Get-PitCrewConnectorHealth {
    param([Parameter(Mandatory)][string]$HostPlatform)

    $connectorBaseRoot = if ($HostPlatform -eq 'Windows') {
        $programData = [Environment]::GetEnvironmentVariable('ProgramData')
        if ([string]::IsNullOrWhiteSpace($programData)) {
            $programData = [Environment]::GetFolderPath(
                [Environment+SpecialFolder]::CommonApplicationData)
        }
        $programData
    } else {
        '/var/lib'
    }
    if ([string]::IsNullOrWhiteSpace($connectorBaseRoot)) {
        Add-PitCrewUnavailable `
            -Category 'connector-health' `
            -Reason 'The standard connector data root is unavailable on this platform.' `
            -FollowUp 'Run the collector on the connector host with its native platform detected.'
        return $null
    }
    $dataRoot = if ($HostPlatform -eq 'Windows') {
        Join-Path $connectorBaseRoot 'PitCrew' 'Connector'
    } else {
        Join-Path $connectorBaseRoot 'pitcrew-connector'
    }
    $healthRoot = Join-Path $dataRoot 'health'
    if (-not (Test-PitCrewUnlinkedPath `
            -BasePath $connectorBaseRoot `
            -TargetPath $healthRoot)) {
        Add-PitCrewUnavailable `
            -Category 'connector-health' `
            -Reason 'The connector health path contains a linked directory.' `
            -FollowUp 'Restore the standard unlinked connector data directory before collecting local health evidence.'
        return $null
    }
    $snapshot = Read-PitCrewBoundedJson `
        -LiteralPath (Join-Path $healthRoot 'connector-health.json') `
        -EvidenceName 'connector-health-snapshot' `
        -MaximumBytes 65536
    $eventsPath = Join-Path $healthRoot 'connector-events.jsonl'
    $events = @()
    if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
        try {
            $item = Get-Item -LiteralPath $eventsPath -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $item.Length -gt 1048832) {
                throw 'The event journal is outside its bounded contract.'
            }
            $parsedEvents = [Collections.Generic.List[object]]::new()
            foreach ($line in Get-Content -LiteralPath $eventsPath -Encoding UTF8) {
                if ([string]::IsNullOrWhiteSpace($line) -or
                    $line.Length -gt 4096) {
                    continue
                }
                try {
                    $event = $line | ConvertFrom-Json -Depth 20 -ErrorAction Stop
                    if ((Get-PitCrewProperty $event 'schemaVersion') -eq 1) {
                        $parsedEvents.Add([PSCustomObject][ordered]@{
                            eventId = Get-PitCrewProperty $event 'eventId'
                            kind = Get-PitCrewProperty $event 'kind'
                            occurredAt = Get-PitCrewProperty $event 'occurredAt'
                            state = Get-PitCrewProperty $event 'state'
                            outageId = Get-PitCrewProperty $event 'outageId'
                            outageStartedAt = Get-PitCrewProperty $event 'outageStartedAt'
                            failureCategory = Get-PitCrewProperty $event 'failureCategory'
                            profileId = Get-PitCrewProperty $event 'profileId'
                            consecutiveFailures = Get-PitCrewProperty $event 'consecutiveFailures'
                            retryDelaySeconds = Get-PitCrewProperty $event 'retryDelaySeconds'
                            detail = Get-PitCrewProperty $event 'detail'
                        })
                    }
                } catch [Management.Automation.RuntimeException] {
                }
            }
            $events = @($parsedEvents | Select-Object -Last 256)
        } catch [Management.Automation.RuntimeException] {
            Add-PitCrewUnavailable `
                -Category 'connector-health-events' `
                -Reason 'The connector event journal is unreadable or outside its bounded contract.' `
                -FollowUp 'Inspect the native connector service and allow it to replace the local event projection.'
        } catch [IO.IOException] {
            Add-PitCrewUnavailable `
                -Category 'connector-health-events' `
                -Reason 'The connector event journal is unreadable or outside its bounded contract.' `
                -FollowUp 'Inspect the native connector service and allow it to replace the local event projection.'
        } catch [UnauthorizedAccessException] {
            Add-PitCrewUnavailable `
                -Category 'connector-health-events' `
                -Reason 'The connector event journal is unreadable or outside its bounded contract.' `
                -FollowUp 'Inspect the native connector service and allow it to replace the local event projection.'
        }
    } else {
        Add-PitCrewUnavailable `
            -Category 'connector-health-events' `
            -Reason 'The connector event journal is absent; this is compatible with older connectors.' `
            -FollowUp 'Update the connector to a release that publishes the local health journal.'
    }
    return [PSCustomObject][ordered]@{
        snapshot = if ($null -eq $snapshot) {
            $null
        } else {
            [PSCustomObject][ordered]@{
                schemaVersion = Get-PitCrewProperty $snapshot 'schemaVersion'
                state = Get-PitCrewProperty $snapshot 'state'
                processStartedAt = Get-PitCrewProperty $snapshot 'processStartedAt'
                updatedAt = Get-PitCrewProperty $snapshot 'updatedAt'
                lastAttemptAt = Get-PitCrewProperty $snapshot 'lastAttemptAt'
                lastSuccessAt = Get-PitCrewProperty $snapshot 'lastSuccessAt'
                activeOutageId = Get-PitCrewProperty $snapshot 'activeOutageId'
                activeOutageStartedAt = Get-PitCrewProperty $snapshot 'activeOutageStartedAt'
                lastFailureAt = Get-PitCrewProperty $snapshot 'lastFailureAt'
                lastFailureCategory = Get-PitCrewProperty $snapshot 'lastFailureCategory'
                lastFailureProfileId = Get-PitCrewProperty $snapshot 'lastFailureProfileId'
                lastFailureDetail = Get-PitCrewProperty $snapshot 'lastFailureDetail'
                consecutiveFailures = Get-PitCrewProperty $snapshot 'consecutiveFailures'
                nextRetryAt = Get-PitCrewProperty $snapshot 'nextRetryAt'
                lastRecoveredOutageId = Get-PitCrewProperty $snapshot 'lastRecoveredOutageId'
                lastRecoveredOutageStartedAt = Get-PitCrewProperty $snapshot 'lastRecoveredOutageStartedAt'
                lastRecoveredAt = Get-PitCrewProperty $snapshot 'lastRecoveredAt'
                lastRecoveredFailureCategory = Get-PitCrewProperty $snapshot 'lastRecoveredFailureCategory'
            }
        }
        events = $events
    }
}

function Get-PitCrewContainerInventory {
    param(
        [Parameter(Mandatory)][string]$SelectedProfile,
        [AllowNull()][object]$StateSummary
    )

    $managerResult = Invoke-PitCrewDocker `
        -Arguments @(
            'ps',
            '--filter',
            "label=ephemeral-runner-manager-profile=$SelectedProfile",
            '--format',
            '{{.ID}}|{{.Image}}|{{.Status}}') `
        -DisplayCommand "docker ps --filter `"label=ephemeral-runner-manager-profile=$SelectedProfile`" --format `"{{.ID}}|{{.Image}}|{{.Status}}`""
    $workerResult = Invoke-PitCrewDocker `
        -Arguments @(
            'ps',
            '--filter',
            "label=ephemeral-managed-runner-profile=$SelectedProfile",
            '--format',
            '{{.ID}}|{{.Image}}|{{.Status}}|{{.Label "ephemeral-managed-runner-slot"}}|{{.Label "pitcrew-worker-revision"}}') `
        -DisplayCommand "docker ps --filter `"label=ephemeral-managed-runner-profile=$SelectedProfile`" --format `"{{.ID}}|{{.Image}}|{{.Status}}|{{.Label \`"ephemeral-managed-runner-slot\`"}}|{{.Label \`"pitcrew-worker-revision\`"}}`""
    if (-not $managerResult.available -or -not $workerResult.available) {
        Add-PitCrewUnavailable `
            -Category 'docker-inventory' `
            -Reason 'Docker container inventory is unavailable.' `
            -FollowUp 'Confirm Docker is reachable without restarting it, then repeat the exact-label inventory.'
    }
    $managers = @(
        foreach ($parts in ConvertFrom-PitCrewDelimitedLines `
                -Text $managerResult.output `
                -MinimumFields 3) {
            [PSCustomObject][ordered]@{
                id = $parts[0]
                image = $parts[1]
                status = $parts[2]
            }
        }
    )
    $workers = @(
        foreach ($parts in ConvertFrom-PitCrewDelimitedLines `
                -Text $workerResult.output `
                -MinimumFields 5) {
            [PSCustomObject][ordered]@{
                id = $parts[0]
                image = $parts[1]
                status = $parts[2]
                slotKey = $parts[3]
                workerRevision = $parts[4]
                imageId = $null
                sizeRwBytes = $null
                sizeRootFsBytes = $null
            }
        }
    )
    foreach ($worker in $workers) {
        if ($worker.id -notmatch '^[a-f0-9]{12,64}$') {
            continue
        }
        $inspect = Invoke-PitCrewDocker `
            -Arguments @(
                'inspect',
                '--size',
                $worker.id,
                '--format',
                '{{.Image}}|{{.SizeRw}}|{{.SizeRootFs}}') `
            -DisplayCommand "docker inspect --size $($worker.id) --format `"{{.Image}}|{{.SizeRw}}|{{.SizeRootFs}}`""
        $parts = @(ConvertFrom-PitCrewDelimitedLines `
                -Text $inspect.output `
                -MinimumFields 3 |
                Select-Object -First 1)
        if ($parts.Count -eq 1) {
            $worker.imageId = $parts[0][0]
            $worker.sizeRwBytes = if ($parts[0][1] -match '^[0-9]+$') {
                [long]$parts[0][1]
            } else {
                $null
            }
            $worker.sizeRootFsBytes = if ($parts[0][2] -match '^[0-9]+$') {
                [long]$parts[0][2]
            } else {
                $null
            }
        }
    }
    $managerImage = if ($managers.Count -eq 1) {
        $managers[0].image
    } else {
        $null
    }
    if ($managers.Count -ne 1) {
        Add-PitCrewUnavailable `
            -Category 'manager-identity' `
            -Reason "Expected one exact-label manager but observed $($managers.Count)." `
            -FollowUp 'Resolve duplicate or absent manager identity before interpreting manager-specific evidence.'
    }
    $workerImage = Get-PitCrewProperty `
        (Get-PitCrewProperty $StateSummary 'static') `
        'image'
    $imageEvidence = @(
        foreach ($entry in @(
                [PSCustomObject]@{ role = 'manager'; reference = $managerImage },
                [PSCustomObject]@{ role = 'worker'; reference = $workerImage })) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.reference)) {
                continue
            }
            $inspect = Invoke-PitCrewDocker `
                -Arguments @(
                    'image',
                    'inspect',
                    [string]$entry.reference,
                    '--format',
                    '{{.Id}}|{{json .RepoDigests}}') `
                -DisplayCommand "docker image inspect $($entry.reference) --format `"{{.Id}}|{{json .RepoDigests}}`""
            $parts = @(ConvertFrom-PitCrewDelimitedLines `
                    -Text $inspect.output `
                    -MinimumFields 2 |
                    Select-Object -First 1)
            [PSCustomObject][ordered]@{
                role = $entry.role
                reference = $entry.reference
                imageId = if ($parts.Count -eq 1) {
                    $parts[0][0]
                } else {
                    $null
                }
                repoDigests = if ($parts.Count -eq 1) {
                    try {
                        @($parts[0][1] | ConvertFrom-Json -ErrorAction Stop)
                    } catch [Management.Automation.RuntimeException] {
                        @()
                    }
                } else {
                    @()
                }
            }
        }
    )
    return [PSCustomObject][ordered]@{
        managers = $managers
        workers = $workers
        images = $imageEvidence
    }
}

function Get-PitCrewContainerStats {
    param(
        [Parameter(Mandatory)][object[]]$Containers,
        [Parameter(Mandatory)][string]$SnapshotName
    )

    $ids = @(
        $Containers |
            ForEach-Object { [string]$_.id } |
            Where-Object { $_ -match '^[a-f0-9]{12,64}$' } |
            Sort-Object -Unique)
    if ($ids.Count -eq 0) {
        return [PSCustomObject][ordered]@{
            name = $SnapshotName
            observedAt = [DateTimeOffset]::UtcNow
            containers = @()
        }
    }
    $result = Invoke-PitCrewDocker `
        -Arguments (@(
                'stats',
                '--no-stream',
                '--format',
                '{{.Container}}|{{.CPUPerc}}|{{.MemUsage}}|{{.PIDs}}|{{.NetIO}}|{{.BlockIO}}') + $ids) `
        -DisplayCommand "docker stats --no-stream --format `"{{.Container}}|{{.CPUPerc}}|{{.MemUsage}}|{{.PIDs}}|{{.NetIO}}|{{.BlockIO}}`" <exact-ids>" `
        -TimeoutSeconds 20
    if ($result.timedOut -or $result.exitCode -ne 0) {
        Add-PitCrewUnavailable `
            -Category "container-stats-$SnapshotName" `
            -Reason "The bounded Docker stats $SnapshotName snapshot was unavailable." `
            -FollowUp 'Repeat docker stats --no-stream with the same exact container IDs.'
    }
    $stats = @(
        foreach ($parts in ConvertFrom-PitCrewDelimitedLines `
                -Text $result.output `
                -MinimumFields 6) {
            $memory = ConvertTo-PitCrewSizePair $parts[2]
            $network = ConvertTo-PitCrewSizePair $parts[4]
            $block = ConvertTo-PitCrewSizePair $parts[5]
            $cpuPercent = 0.0
            $hasCpuPercent = [double]::TryParse(
                $parts[1].TrimEnd('%'),
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$cpuPercent)
            [PSCustomObject][ordered]@{
                id = $parts[0]
                cpuPercent = if ($hasCpuPercent) {
                    $cpuPercent
                } else {
                    $null
                }
                memoryUsageBytes = $memory.firstBytes
                memoryLimitBytes = $memory.secondBytes
                pids = if ($parts[3] -match '^[0-9]+$') {
                    [int]$parts[3]
                } else {
                    $null
                }
                networkRxBytes = $network.firstBytes
                networkTxBytes = $network.secondBytes
                blockReadBytes = $block.firstBytes
                blockWriteBytes = $block.secondBytes
            }
        }
    )
    return [PSCustomObject][ordered]@{
        name = $SnapshotName
        observedAt = [DateTimeOffset]::UtcNow
        containers = $stats
    }
}

function Get-PitCrewStatsDelta {
    param(
        [AllowNull()][object]$Before,
        [AllowNull()][object]$After
    )

    $beforeMap = @{}
    foreach ($item in @(
            Get-PitCrewProperty $Before 'containers' @())) {
        $beforeMap[[string]$item.id] = $item
    }
    return @(
        foreach ($item in @(
                Get-PitCrewProperty $After 'containers' @())) {
            $prior = $beforeMap[[string]$item.id]
            [PSCustomObject][ordered]@{
                id = $item.id
                networkRxBytes = if ($null -ne $prior -and
                    $null -ne $prior.networkRxBytes -and
                    $null -ne $item.networkRxBytes) {
                    [long]$item.networkRxBytes - [long]$prior.networkRxBytes
                } else {
                    $null
                }
                networkTxBytes = if ($null -ne $prior -and
                    $null -ne $prior.networkTxBytes -and
                    $null -ne $item.networkTxBytes) {
                    [long]$item.networkTxBytes - [long]$prior.networkTxBytes
                } else {
                    $null
                }
                blockReadBytes = if ($null -ne $prior -and
                    $null -ne $prior.blockReadBytes -and
                    $null -ne $item.blockReadBytes) {
                    [long]$item.blockReadBytes - [long]$prior.blockReadBytes
                } else {
                    $null
                }
                blockWriteBytes = if ($null -ne $prior -and
                    $null -ne $prior.blockWriteBytes -and
                    $null -ne $item.blockWriteBytes) {
                    [long]$item.blockWriteBytes - [long]$prior.blockWriteBytes
                } else {
                    $null
                }
            }
        }
    )
}

function Get-PitCrewDockerSystemSnapshot {
    param([Parameter(Mandatory)][string]$SnapshotName)

    $result = Invoke-PitCrewDocker `
        -Arguments @(
            'system',
            'df',
            '--format',
            '{{json .}}') `
        -DisplayCommand 'docker system df --format "{{json .}}"'
    $rows = @(
        foreach ($line in @($result.output -split '\r?\n')) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $row = $line | ConvertFrom-Json -ErrorAction Stop
                [PSCustomObject][ordered]@{
                    type = Get-PitCrewProperty $row 'Type'
                    totalCount = Get-PitCrewProperty $row 'TotalCount'
                    active = Get-PitCrewProperty $row 'Active'
                    size = Get-PitCrewProperty $row 'Size'
                    reclaimable = Get-PitCrewProperty $row 'Reclaimable'
                }
            } catch [Management.Automation.RuntimeException] {
            }
        }
    )
    return [PSCustomObject][ordered]@{
        name = $SnapshotName
        observedAt = [DateTimeOffset]::UtcNow
        rows = $rows
    }
}

function Get-PitCrewAdapterSnapshot {
    param(
        [Parameter(Mandatory)][string]$HostPlatform,
        [Parameter(Mandatory)][string]$SnapshotName
    )

    if ($HostPlatform -eq 'Windows') {
        $command = Get-Command `
            -Name Get-NetAdapterStatistics `
            -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            Add-PitCrewUnavailable `
                -Category "adapter-statistics-$SnapshotName" `
                -Reason 'Get-NetAdapterStatistics is unavailable.' `
                -FollowUp 'Install or enable the read-only NetAdapter module, then repeat the snapshot.'
            return [PSCustomObject][ordered]@{
                name = $SnapshotName
                observedAt = [DateTimeOffset]::UtcNow
                adapters = @()
            }
        }
        $index = 0
        $adapters = @(
            foreach ($adapter in Get-NetAdapterStatistics) {
                $index++
                [PSCustomObject][ordered]@{
                    adapter = "adapter-$index"
                    receivedBytes = Get-PitCrewProperty $adapter 'ReceivedBytes'
                    sentBytes = Get-PitCrewProperty $adapter 'SentBytes'
                    receivedDiscards = Get-PitCrewProperty $adapter 'ReceivedDiscardedPackets'
                    sentDiscards = Get-PitCrewProperty $adapter 'OutboundDiscardedPackets'
                    receivedErrors = Get-PitCrewProperty $adapter 'ReceivedPacketErrors'
                    sentErrors = Get-PitCrewProperty $adapter 'OutboundPacketErrors'
                }
            }
        )
    } else {
        if (-not (Test-Path -LiteralPath '/proc/net/dev' -PathType Leaf)) {
            Add-PitCrewUnavailable `
                -Category "adapter-statistics-$SnapshotName" `
                -Reason '/proc/net/dev is unavailable.' `
                -FollowUp 'Collect read-only interface counters from the host networking subsystem.'
            return [PSCustomObject][ordered]@{
                name = $SnapshotName
                observedAt = [DateTimeOffset]::UtcNow
                adapters = @()
            }
        }
        $index = 0
        $adapters = @(
            foreach ($line in Get-Content -LiteralPath '/proc/net/dev' |
                    Select-Object -Skip 2) {
                $parts = @($line.Trim() -split '\s+')
                if ($parts.Count -lt 17) {
                    continue
                }
                $index++
                [PSCustomObject][ordered]@{
                    adapter = "adapter-$index"
                    receivedBytes = [long]$parts[1]
                    sentBytes = [long]$parts[9]
                    receivedDiscards = [long]$parts[4]
                    sentDiscards = [long]$parts[12]
                    receivedErrors = [long]$parts[3]
                    sentErrors = [long]$parts[11]
                }
            }
        )
    }
    return [PSCustomObject][ordered]@{
        name = $SnapshotName
        observedAt = [DateTimeOffset]::UtcNow
        adapters = $adapters
    }
}

function Get-PitCrewAdapterDelta {
    param(
        [AllowNull()][object]$Before,
        [AllowNull()][object]$After
    )

    $beforeItems = @(
        Get-PitCrewProperty $Before 'adapters' @())
    $afterItems = @(
        Get-PitCrewProperty $After 'adapters' @())
    if ($beforeItems.Count -ne $afterItems.Count) {
        return @()
    }
    return @(
        for ($index = 0; $index -lt $afterItems.Count; $index++) {
            [PSCustomObject][ordered]@{
                adapter = $afterItems[$index].adapter
                receivedBytes = [long]$afterItems[$index].receivedBytes -
                    [long]$beforeItems[$index].receivedBytes
                sentBytes = [long]$afterItems[$index].sentBytes -
                    [long]$beforeItems[$index].sentBytes
                receivedDiscards = [long]$afterItems[$index].receivedDiscards -
                    [long]$beforeItems[$index].receivedDiscards
                sentDiscards = [long]$afterItems[$index].sentDiscards -
                    [long]$beforeItems[$index].sentDiscards
                receivedErrors = [long]$afterItems[$index].receivedErrors -
                    [long]$beforeItems[$index].receivedErrors
                sentErrors = [long]$afterItems[$index].sentErrors -
                    [long]$beforeItems[$index].sentErrors
            }
        }
    )
}

function Get-PitCrewHostCapacity {
    param([Parameter(Mandatory)][string]$HostPlatform)

    $info = Invoke-PitCrewDocker `
        -Arguments @(
            'info',
            '--format',
            '{{.DockerRootDir}}|{{.OperatingSystem}}|{{.ServerVersion}}') `
        -DisplayCommand 'docker info --format "{{.DockerRootDir}}|{{.OperatingSystem}}|{{.ServerVersion}}"'
    $infoParts = @(ConvertFrom-PitCrewDelimitedLines `
            -Text $info.output `
            -MinimumFields 3 |
            Select-Object -First 1)
    $dockerRoot = if ($infoParts.Count -eq 1) {
        $infoParts[0][0]
    } else {
        $null
    }
    $network = Invoke-PitCrewDocker `
        -Arguments @('network', 'ls', '--format', '{{.ID}}') `
        -DisplayCommand 'docker network ls --format "{{.ID}}"'
    $networkCount = @(
        $network.output -split '\r?\n' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($HostPlatform -eq 'Windows') {
        $drives = @(
            Get-PSDrive -PSProvider FileSystem |
                Sort-Object Name |
                ForEach-Object {
                    [PSCustomObject][ordered]@{
                        drive = $_.Name
                        usedBytes = [long]$_.Used
                        freeBytes = [long]$_.Free
                    }
                }
        )
        $inodes = $null
        Add-PitCrewUnavailable `
            -Category 'host-inodes' `
            -Reason 'NTFS has no inode budget equivalent.' `
            -FollowUp 'Use free-space and writable-layer evidence on Windows.'
    } else {
        $drives = @()
        $inodes = $null
        if (-not [string]::IsNullOrWhiteSpace($dockerRoot)) {
            $space = Invoke-PitCrewProcess `
                -Name df `
                -Arguments @('-P', $dockerRoot) `
                -DisplayCommand 'df -P <docker-root>'
            $inodeResult = Invoke-PitCrewProcess `
                -Name df `
                -Arguments @('-Pi', $dockerRoot) `
                -DisplayCommand 'df -Pi <docker-root>'
            $spaceLine = @(
                $space.output -split '\r?\n' |
                    Select-Object -Skip 1 |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -Last 1)
            $spaceFields = @(
                if ($spaceLine.Count -eq 1) {
                    $spaceLine[0].Trim() -split '\s+'
                })
            $drives = if ($spaceFields.Count -ge 6) {
                @([PSCustomObject][ordered]@{
                    totalKiB = $spaceFields[1] -as [long]
                    usedKiB = $spaceFields[2] -as [long]
                    availableKiB = $spaceFields[3] -as [long]
                    capacity = $spaceFields[4]
                    mount = '<docker-root>'
                })
            } else {
                @()
            }
            $inodeLine = @(
                $inodeResult.output -split '\r?\n' |
                    Select-Object -Skip 1 |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -Last 1)
            $inodeFields = @(
                if ($inodeLine.Count -eq 1) {
                    $inodeLine[0].Trim() -split '\s+'
                })
            $inodes = if ($inodeFields.Count -ge 6) {
                [PSCustomObject][ordered]@{
                    total = $inodeFields[1] -as [long]
                    used = $inodeFields[2] -as [long]
                    available = $inodeFields[3] -as [long]
                    capacity = $inodeFields[4]
                    mount = '<docker-root>'
                }
            } else {
                $null
            }
        } else {
            Add-PitCrewUnavailable `
                -Category 'docker-root-capacity' `
                -Reason 'Docker root could not be resolved.' `
                -FollowUp 'Repeat docker info and then run df against the exact Docker root.'
        }
    }
    return [PSCustomObject][ordered]@{
        docker = [PSCustomObject][ordered]@{
            operatingSystem = if ($infoParts.Count -eq 1) {
                $infoParts[0][1]
            } else {
                $null
            }
            serverVersion = if ($infoParts.Count -eq 1) {
                $infoParts[0][2]
            } else {
                $null
            }
            root = if ($null -eq $dockerRoot) {
                $null
            } else {
                '<docker-root>'
            }
            networkCount = $networkCount
        }
        filesystem = [PSCustomObject][ordered]@{
            drives = $drives
            inodes = $inodes
        }
    }
}

function ConvertFrom-PitCrewCurlOutput {
    param(
        [Parameter(Mandatory)][string]$Url,
        [AllowNull()][object]$Result,
        [Parameter(Mandatory)][string]$Origin
    )

    $line = @(
        $Result.output -split '\r?\n' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Last 1)
    $parts = @(
        if ($line.Count -eq 1) {
            $line[0] -split '\s+'
        })
    return [PSCustomObject][ordered]@{
        origin = $Origin
        url = $Url
        status = if ($Result.timedOut -or $Result.exitCode -eq 28) {
            'timed-out'
        } elseif ($Result.exitCode -eq 0 -and $parts.Count -ge 9) {
            'completed'
        } else {
            'failed'
        }
        httpStatus = if ($parts.Count -ge 1) { $parts[0] } else { $null }
        remoteIp = if ($parts.Count -ge 2) { $parts[1] } else { $null }
        dnsSeconds = if ($parts.Count -ge 3) { $parts[2] -as [double] } else { $null }
        connectSeconds = if ($parts.Count -ge 4) { $parts[3] -as [double] } else { $null }
        tlsSeconds = if ($parts.Count -ge 5) { $parts[4] -as [double] } else { $null }
        firstByteSeconds = if ($parts.Count -ge 6) { $parts[5] -as [double] } else { $null }
        totalSeconds = if ($parts.Count -ge 7) { $parts[6] -as [double] } else { $null }
        bytesDownloaded = if ($parts.Count -ge 8) { $parts[7] -as [long] } else { $null }
        bytesPerSecond = if ($parts.Count -ge 9) { $parts[8] -as [long] } else { $null }
    }
}

function Invoke-PitCrewUrlProbes {
    param(
        [Parameter(Mandatory)][string[]]$Urls,
        [Parameter(Mandatory)][string]$HostPlatform,
        [Parameter(Mandatory)][string]$WorkerImageId,
        [Parameter(Mandatory)][string]$SelectedProfile,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$RunTemp,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $results = [Collections.Generic.List[object]]::new()
    foreach ($url in $Urls) {
        $curlName = if ($HostPlatform -eq 'Windows') {
            'curl.exe'
        } else {
            'curl'
        }
        $outputTarget = if ($HostPlatform -eq 'Windows') {
            'NUL'
        } else {
            '/dev/null'
        }
        $writeOut = '%{http_code} %{remote_ip} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{speed_download}\n'
        $hostProbe = Invoke-PitCrewProcess `
            -Name $curlName `
            -Arguments @(
                '--disable',
                '--silent',
                '--show-error',
                '--max-redirs',
                '0',
                '--max-time',
                [string]$TimeoutSeconds,
                '--output',
                $outputTarget,
                '--write-out',
                $writeOut,
                $url) `
            -DisplayCommand "$curlName --disable --silent --show-error --max-redirs 0 --max-time $TimeoutSeconds --output $outputTarget --write-out `"<timing-fields>`" $url" `
            -TimeoutSeconds ($TimeoutSeconds + 5)
        $results.Add(
            (ConvertFrom-PitCrewCurlOutput `
                -Url $url `
                -Result $hostProbe `
                -Origin 'host'))

        if ($WorkerImageId -notmatch '^sha256:[a-f0-9]{64}$') {
            Add-PitCrewUnavailable `
                -Category 'container-url-probe' `
                -Reason 'The immutable configured worker image ID is unavailable.' `
                -FollowUp 'Restore static-profile resolved-image evidence, then repeat the same approved URL probe.'
            continue
        }
        $cidFile = Join-Path $RunTemp "diagnostic-$RunId.cid"
        $containerName = "pitcrew-diagnostics-$SelectedProfile-$($RunId.Substring(0, 12))"
        $containerProbe = Invoke-PitCrewDocker `
            -Arguments @(
                'run',
                '--rm',
                '--cidfile',
                $cidFile,
                '--name',
                $containerName,
                '--label',
                "pitcrew-diagnostics-session=$RunId",
                '--pull=never',
                '--entrypoint',
                'curl',
                $WorkerImageId,
                '--disable',
                '--silent',
                '--show-error',
                '--max-redirs',
                '0',
                '--max-time',
                [string]$TimeoutSeconds,
                '--output',
                '/dev/null',
                '--write-out',
                $writeOut,
                $url) `
            -DisplayCommand "docker run --rm --cidfile <run-scoped-cidfile> --name $containerName --label pitcrew-diagnostics-session=$RunId --pull=never --entrypoint curl $WorkerImageId --disable --silent --show-error --max-redirs 0 --max-time $TimeoutSeconds --output /dev/null --write-out `"<timing-fields>`" $url" `
            -TimeoutSeconds ($TimeoutSeconds + 15)
        $results.Add(
            (ConvertFrom-PitCrewCurlOutput `
                -Url $url `
                -Result $containerProbe `
                -Origin 'container'))
        if (Test-Path -LiteralPath $cidFile -PathType Leaf) {
            $containerId = (
                Get-Content -LiteralPath $cidFile -Raw -Encoding UTF8).Trim()
            if ($containerId -match '^[a-f0-9]{12,64}$') {
                $label = Invoke-PitCrewDocker `
                    -Arguments @(
                        'inspect',
                        $containerId,
                        '--format',
                        '{{index .Config.Labels "pitcrew-diagnostics-session"}}') `
                    -DisplayCommand "docker inspect $containerId --format `"{{index .Config.Labels \`"pitcrew-diagnostics-session\`"}}`""
                if ($label.exitCode -eq 0 -and
                    $label.output.Trim() -eq $RunId) {
                    $null = Invoke-PitCrewDocker `
                        -Arguments @('rm', '--force', $containerId) `
                        -DisplayCommand "docker rm --force $containerId"
                }
            }
            Remove-Item -LiteralPath $cidFile -Force
        }
    }
    return @($results)
}

function Get-PitCrewCapacityComparison {
    param(
        [AllowNull()][object]$StateSummary,
        [AllowNull()][object]$Inventory
    )

    $desiredMap = @{}
    foreach ($repository in @(
            Get-PitCrewProperty `
                (Get-PitCrewProperty $StateSummary 'desired') `
                'repositories' `
                @())) {
        $desiredMap[[string]$repository.url] = $repository.workers
    }
    $observedSlots = @(
        Get-PitCrewProperty `
            (Get-PitCrewProperty $StateSummary 'observed') `
            'slots' `
            @())
    $slotRepositoryMap = @{}
    foreach ($slot in $observedSlots) {
        $slotRepositoryMap[[string]$slot.key] = $slot.repository
    }
    $liveByRepository = @{}
    foreach ($worker in @(
            Get-PitCrewProperty $Inventory 'workers' @())) {
        $repository = $slotRepositoryMap[[string]$worker.slotKey]
        $key = if ([string]::IsNullOrWhiteSpace([string]$repository)) {
            "<unmapped:$($worker.slotKey)>"
        } else {
            [string]$repository
        }
        $liveByRepository[$key] = 1 + [int](
            Get-PitCrewProperty $liveByRepository $key 0)
    }
    $observedGroups = @{}
    foreach ($slot in $observedSlots) {
        $key = if ([string]::IsNullOrWhiteSpace([string]$slot.repository)) {
            '<scope>'
        } else {
            [string]$slot.repository
        }
        if (-not $observedGroups.ContainsKey($key)) {
            $observedGroups[$key] = [Collections.Generic.List[object]]::new()
        }
        $observedGroups[$key].Add($slot)
    }
    $targets = @(
        Get-PitCrewProperty `
            (Get-PitCrewProperty `
                (Get-PitCrewProperty $StateSummary 'observed') `
                'autoscaling') `
            'targets' `
            @())
    $targetMap = @{}
    foreach ($target in $targets) {
        $key = if ([string]::IsNullOrWhiteSpace([string]$target.repository)) {
            '<scope>'
        } else {
            [string]$target.repository
        }
        $targetMap[$key] = $target
    }
    $keys = @(
        @($desiredMap.Keys) +
            @($liveByRepository.Keys) +
            @($observedGroups.Keys) +
            @($targetMap.Keys) |
            Sort-Object -Unique)
    return @(
        foreach ($key in $keys) {
            $group = @($observedGroups[$key])
            $registered = @(
                $group |
                    Where-Object {
                        $_.registrationStatus -eq 'connected'
                    }).Count
            $live = [int](
                Get-PitCrewProperty $liveByRepository $key 0)
            [PSCustomObject][ordered]@{
                target = $key
                desiredWorkers = Get-PitCrewProperty $desiredMap $key
                liveWorkers = $live
                observedSlots = $group.Count
                registeredWorkers = $registered
                states = @($group.state)
                scaleSet = Get-PitCrewProperty $targetMap $key
                mismatch = if ($group.Count -eq 0) {
                    $live -gt 0
                } else {
                    $live -ne $registered
                }
            }
        }
    )
}

function New-PitCrewHypotheses {
    param(
        [AllowNull()][object]$StateSummary,
        [AllowNull()][object]$ConnectorHealth,
        [AllowNull()][object[]]$Capacity,
        [AllowNull()][object[]]$UrlProbes
    )

    $items = [Collections.Generic.List[object]]::new()
    $rank = 0
    $snapshot = Get-PitCrewProperty $ConnectorHealth 'snapshot'
    if ($null -ne $snapshot -and
        $null -ne $snapshot.activeOutageId) {
        $rank++
        $items.Add([PSCustomObject][ordered]@{
            rank = $rank
            hypothesis = 'The connector synchronization path is currently degraded.'
            evidence = "The local connector journal reports '$($snapshot.lastFailureCategory)' with $($snapshot.consecutiveFailures) consecutive failure(s)."
            followUp = 'Compare the outage interval with Dashboard heartbeat history and test outbound HTTPS from the host without changing connector state.'
        })
    }
    $observed = Get-PitCrewProperty $StateSummary 'observed'
    if ($null -ne $observed -and
        ($observed.freshnessSeconds -as [double]) -gt 120) {
        $rank++
        $items.Add([PSCustomObject][ordered]@{
            rank = $rank
            hypothesis = 'Manager observed state may be stale.'
            evidence = "Observed state is $($observed.freshnessSeconds) seconds old."
            followUp = 'Inspect the exact-label manager container and repeat the read-only observed-state collection.'
        })
    }
    $mismatches = @($Capacity | Where-Object mismatch)
    if ($mismatches.Count -gt 0) {
        $rank++
        $items.Add([PSCustomObject][ordered]@{
            rank = $rank
            hypothesis = 'Local worker containers and registered capacity are not reconciled.'
            evidence = "$($mismatches.Count) target(s) report a live-versus-registered mismatch."
            followUp = 'Compare each mismatched target with fresh manager diagnostics and GitHub runner registration evidence through an approved read-only operator.'
        })
    }
    $pairedUrls = @(
        $UrlProbes |
            Group-Object url |
            Where-Object Count -ge 2)
    foreach ($pair in $pairedUrls) {
        $hostProbeItem = @(
            $pair.Group |
                Where-Object origin -eq 'host' |
                Select-Object -First 1)
        $container = @($pair.Group | Where-Object origin -eq 'container' | Select-Object -First 1)
        if ($hostProbeItem.Count -eq 1 -and
            $container.Count -eq 1 -and
            $hostProbeItem[0].status -eq 'completed' -and
            $container[0].status -eq 'completed' -and
            $hostProbeItem[0].remoteIp -ne $container[0].remoteIp) {
            $rank++
            $items.Add([PSCustomObject][ordered]@{
                rank = $rank
                hypothesis = 'CDN edge or route selection may explain the host/container timing difference.'
                evidence = "The paired probes selected different remote IPs for $($pair.Name)."
                followUp = 'Repeat the same URL, timeout, worker image, and stated worker load to separate route variability from a Docker networking effect.'
            })
        }
    }
    if ($items.Count -eq 0) {
        $items.Add([PSCustomObject][ordered]@{
            rank = 1
            hypothesis = 'The collected sample does not isolate a root cause.'
            evidence = 'No decisive outage, staleness, capacity mismatch, or paired-route difference was verified.'
            followUp = 'Repeat the same diagnostic mode during the next incident and correlate its timestamps with Dashboard and GitHub evidence.'
        })
    }
    return @($items)
}

function New-PitCrewMarkdownReport {
    param([Parameter(Mandatory)][object]$Report)

    $builder = [Text.StringBuilder]::new()
    $null = $builder.AppendLine('# PitCrew remote diagnostics')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("- Package: ``$($Report.packageId)``")
    $null = $builder.AppendLine("- Mode: ``$($Report.diagnosticMode)``")
    $null = $builder.AppendLine("- Profile: ``$($Report.profile)``")
    $null = $builder.AppendLine("- Platform: ``$($Report.platform)``")
    $null = $builder.AppendLine("- Window: ``$($Report.startedAt.ToString('O'))`` to ``$($Report.completedAt.ToString('O'))``")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Verified measurements')
    $null = $builder.AppendLine()
    $observed = $Report.verifiedMeasurements.state.observed
    $null = $builder.AppendLine("- Manager status: ``$(ConvertTo-PitCrewMarkdownText $observed.managerStatus)``")
    $null = $builder.AppendLine("- Desired / acknowledged / observed generation: ``$($Report.verifiedMeasurements.state.desired.generation)`` / ``$($Report.verifiedMeasurements.state.acknowledged.generation)`` / ``$($observed.generation)``")
    $null = $builder.AppendLine("- Observed-state freshness: ``$($observed.freshnessSeconds)`` seconds")
    $connectorSnapshot = Get-PitCrewProperty $Report.verifiedMeasurements.connectorHealth 'snapshot'
    if ($null -ne $connectorSnapshot) {
        $null = $builder.AppendLine("- Connector state: ``$($connectorSnapshot.state)``; last failure: ``$($connectorSnapshot.lastFailureCategory)``")
    }
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('### Capacity')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('| Target | Desired | Live | Observed | Registered | Mismatch |')
    $null = $builder.AppendLine('| --- | ---: | ---: | ---: | ---: | --- |')
    foreach ($item in $Report.verifiedMeasurements.capacity) {
        $null = $builder.AppendLine(
            "| $(ConvertTo-PitCrewMarkdownText $item.target) | $($item.desiredWorkers) | $($item.liveWorkers) | $($item.observedSlots) | $($item.registeredWorkers) | $($item.mismatch) |")
    }
    $null = $builder.AppendLine()
    if (@($Report.verifiedMeasurements.urlProbes).Count -gt 0) {
        $null = $builder.AppendLine('### URL probes')
        $null = $builder.AppendLine()
        $null = $builder.AppendLine('| Origin | URL | Status | Remote IP | Total seconds | Bytes/sec |')
        $null = $builder.AppendLine('| --- | --- | --- | --- | ---: | ---: |')
        foreach ($probe in $Report.verifiedMeasurements.urlProbes) {
            $null = $builder.AppendLine(
                "| $($probe.origin) | $(ConvertTo-PitCrewMarkdownText $probe.url) | $($probe.status) | $(ConvertTo-PitCrewMarkdownText $probe.remoteIp) | $($probe.totalSeconds) | $($probe.bytesPerSecond) |")
        }
        $null = $builder.AppendLine()
        $null = $builder.AppendLine('One host/container pair is one sample, not a root cause or host benchmark.')
        $null = $builder.AppendLine()
    }
    $null = $builder.AppendLine('### Exact commands')
    $null = $builder.AppendLine()
    foreach ($command in $Report.verifiedMeasurements.commands) {
        $null = $builder.AppendLine(
            "- ``$(ConvertTo-PitCrewMarkdownText $command.command)`` - $($command.status)")
    }
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Unavailable evidence')
    $null = $builder.AppendLine()
    if (@($Report.unavailableEvidence).Count -eq 0) {
        $null = $builder.AppendLine('- None.')
    } else {
        foreach ($item in $Report.unavailableEvidence) {
            $null = $builder.AppendLine(
                "- **$(ConvertTo-PitCrewMarkdownText $item.category):** $(ConvertTo-PitCrewMarkdownText $item.reason) Follow-up: $(ConvertTo-PitCrewMarkdownText $item.followUp)")
        }
    }
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Hypotheses')
    $null = $builder.AppendLine()
    foreach ($item in $Report.hypotheses) {
        $null = $builder.AppendLine(
            "$($item.rank). **$(ConvertTo-PitCrewMarkdownText $item.hypothesis)** Evidence: $(ConvertTo-PitCrewMarkdownText $item.evidence) Follow-up: $(ConvertTo-PitCrewMarkdownText $item.followUp)")
    }
    return $builder.ToString()
}

function Write-PitCrewUtf8File {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Content
    )

    [IO.File]::WriteAllText(
        $LiteralPath,
        $Content.Replace("`r`n", "`n"),
        [Text.UTF8Encoding]::new($false))
}

function Write-PitCrewResultArtifacts {
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$Markdown,
        [Parameter(Mandatory)][string]$Destination
    )

    $null = New-Item -ItemType Directory -Path $Destination -Force
    $jsonPath = Join-Path $Destination 'pitcrew-diagnostics.json'
    $markdownPath = Join-Path $Destination 'pitcrew-diagnostics.md'
    $manifestPath = Join-Path $Destination 'result-manifest.json'
    Write-PitCrewUtf8File `
        -LiteralPath $jsonPath `
        -Content ($Report | ConvertTo-Json -Depth 100)
    Write-PitCrewUtf8File `
        -LiteralPath $markdownPath `
        -Content $Markdown
    $manifest = [PSCustomObject][ordered]@{
        schemaVersion = 1
        packageId = $Report.packageId
        collectorVersion = $Report.collectorVersion
        generatedAt = [DateTimeOffset]::UtcNow
        files = @(
            [PSCustomObject][ordered]@{
                name = 'pitcrew-diagnostics.json'
                sha256 = Get-PitCrewSha256 $jsonPath
            },
            [PSCustomObject][ordered]@{
                name = 'pitcrew-diagnostics.md'
                sha256 = Get-PitCrewSha256 $markdownPath
            })
    }
    Write-PitCrewUtf8File `
        -LiteralPath $manifestPath `
        -Content ($manifest | ConvertTo-Json -Depth 20)
    return [PSCustomObject][ordered]@{
        outputDirectory = (Resolve-Path -LiteralPath $Destination).Path
        jsonPath = (Resolve-Path -LiteralPath $jsonPath).Path
        markdownPath = (Resolve-Path -LiteralPath $markdownPath).Path
        manifestPath = (Resolve-Path -LiteralPath $manifestPath).Path
    }
}

$startedAt = [DateTimeOffset]::UtcNow
if ([string]::IsNullOrWhiteSpace($PackageId)) {
    $PackageId = [Guid]::NewGuid().ToString('N')
}
$hostPlatform = if ($Platform -eq 'Auto') {
    if ($IsWindows) {
        'Windows'
    } elseif ($IsLinux) {
        'Linux'
    } else {
        throw 'Only Windows and Linux PitCrew hosts are supported.'
    }
} else {
    $Platform
}
$inputRootItem = Get-Item -LiteralPath $PitCrewRoot -Force -ErrorAction Stop
if (($inputRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Linked PitCrew installation roots are not supported.'
}
$resolvedRoot = (Resolve-Path -LiteralPath $PitCrewRoot -ErrorAction Stop).Path
foreach ($requiredFile in @(
        'Setup-Runner.ps1',
        'RunnerProfiles.Functions.ps1',
        'docker-compose.yml')) {
    if (-not (Test-Path `
            -LiteralPath (Join-Path $resolvedRoot $requiredFile) `
            -PathType Leaf)) {
        throw 'PitCrewRoot does not contain the supported PitCrew installation contract.'
    }
}
$stateRoot = Join-Path $resolvedRoot '.pitcrew-state'
if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    throw 'PitCrewRoot has no configured profile state.'
}
if (-not (Test-PitCrewUnlinkedPath `
        -BasePath $resolvedRoot `
        -TargetPath $stateRoot)) {
    throw 'Linked PitCrew state directories are not supported.'
}
$profileDirectories = @(
    Get-ChildItem -LiteralPath $stateRoot -Directory -Force |
        Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
        } |
        Sort-Object Name)
if ([string]::IsNullOrWhiteSpace($Profile)) {
    if ($profileDirectories.Count -ne 1) {
        throw 'Profile is required when the PitCrew installation contains zero or multiple profiles.'
    }
    $Profile = $profileDirectories[0].Name
}
$profileDirectory = Join-Path $stateRoot $Profile
if (-not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
    throw 'The selected PitCrew profile does not exist.'
}
$profileItem = Get-Item -LiteralPath $profileDirectory -Force
if (($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Linked PitCrew profile state directories are not supported.'
}
$desired = Read-PitCrewBoundedJson `
    -LiteralPath (Join-Path $profileDirectory 'desired-capacity.json') `
    -EvidenceName 'desired-capacity'
$acknowledged = Read-PitCrewBoundedJson `
    -LiteralPath (Join-Path $profileDirectory 'acknowledged-capacity.json') `
    -EvidenceName 'acknowledged-capacity'
$static = Read-PitCrewBoundedJson `
    -LiteralPath (Join-Path $profileDirectory 'static-profile.json') `
    -EvidenceName 'static-profile'
$observed = Read-PitCrewBoundedJson `
    -LiteralPath (Join-Path $profileDirectory 'observed-state.json') `
    -EvidenceName 'observed-state' `
    -MaximumBytes 2097152
$collectedAt = [DateTimeOffset]::UtcNow
$stateSummary = ConvertTo-PitCrewStateSummary `
    -Desired $desired `
    -Acknowledged $acknowledged `
    -Static $static `
    -Observed $observed `
    -CollectedAt $collectedAt
$connectorHealth = Get-PitCrewConnectorHealth -HostPlatform $hostPlatform
$includeDocker = $DiagnosticMode -ne 'ConnectorOffline'
$inventory = if ($includeDocker) {
    Get-PitCrewContainerInventory `
        -SelectedProfile $Profile `
        -StateSummary $stateSummary
} else {
    [PSCustomObject][ordered]@{
        managers = @()
        workers = @()
        images = @()
    }
}
$capacity = Get-PitCrewCapacityComparison `
    -StateSummary $stateSummary `
    -Inventory $inventory
$includeResources = $DiagnosticMode -in @('HostPressure', 'Full')
$containers = @($inventory.managers) + @($inventory.workers)
$beforeStats = if ($includeResources) {
    Get-PitCrewContainerStats `
        -Containers $containers `
        -SnapshotName 'before'
} else {
    $null
}
$beforeDockerSystem = if ($includeResources) {
    Get-PitCrewDockerSystemSnapshot -SnapshotName 'before'
} else {
    $null
}
$beforeAdapters = if ($includeResources) {
    Get-PitCrewAdapterSnapshot `
        -HostPlatform $hostPlatform `
        -SnapshotName 'before'
} else {
    $null
}
$hostCapacity = if ($includeResources) {
    Get-PitCrewHostCapacity -HostPlatform $hostPlatform
} else {
    $null
}
$safeUrls = @(
    $ApprovedUrl |
        ForEach-Object { ConvertTo-PitCrewSafeUrl $_ } |
        Sort-Object -Unique)
$runTemp = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "pitcrew-diagnostics-$PackageId-$([Guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $runTemp
try {
    $urlProbes = if ($safeUrls.Count -gt 0) {
        Invoke-PitCrewUrlProbes `
            -Urls $safeUrls `
            -HostPlatform $hostPlatform `
            -WorkerImageId ([string]$stateSummary.static.resolvedImageId) `
            -SelectedProfile $Profile `
            -RunId $PackageId `
            -RunTemp $runTemp `
            -TimeoutSeconds $ProbeTimeoutSeconds
    } else {
        @()
    }
} finally {
    if (Test-Path -LiteralPath $runTemp -PathType Container) {
        Remove-Item -LiteralPath $runTemp -Recurse -Force
    }
}
$afterStats = if ($includeResources -and $safeUrls.Count -gt 0) {
    Get-PitCrewContainerStats `
        -Containers $containers `
        -SnapshotName 'after'
} else {
    $null
}
$afterDockerSystem = if ($includeResources -and $safeUrls.Count -gt 0) {
    Get-PitCrewDockerSystemSnapshot -SnapshotName 'after'
} else {
    $null
}
$afterAdapters = if ($includeResources -and $safeUrls.Count -gt 0) {
    Get-PitCrewAdapterSnapshot `
        -HostPlatform $hostPlatform `
        -SnapshotName 'after'
} else {
    $null
}
$gitVersion = Invoke-PitCrewProcess `
    -Name git `
    -Arguments @(
        '-C',
        $resolvedRoot,
        'describe',
        '--tags',
        '--always',
        '--dirty') `
    -DisplayCommand 'git -C <pitcrew-root> describe --tags --always --dirty'
$completedAt = [DateTimeOffset]::UtcNow
$hypotheses = New-PitCrewHypotheses `
    -StateSummary $stateSummary `
    -ConnectorHealth $connectorHealth `
    -Capacity $capacity `
    -UrlProbes $urlProbes
$report = [PSCustomObject][ordered]@{
    schemaVersion = 1
    collectorVersion = $script:CollectorVersion
    collectorSha256 = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath) -and
        (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
        Get-PitCrewSha256 $PSCommandPath
    } else {
        $null
    }
    packageId = $PackageId
    diagnosticMode = $DiagnosticMode
    platform = $hostPlatform
    platformSource = if ($Platform -eq 'Auto') { 'detected' } else { 'explicit' }
    profile = $Profile
    pitcrewRoot = '<pitcrew-root>'
    startedAt = $startedAt
    completedAt = $completedAt
    verifiedMeasurements = [PSCustomObject][ordered]@{
        pitcrewVersion = if ($gitVersion.exitCode -eq 0) {
            $gitVersion.output.Trim()
        } else {
            $null
        }
        state = $stateSummary
        connectorHealth = $connectorHealth
        containers = $inventory
        capacity = $capacity
        hostCapacity = $hostCapacity
        resourceWindow = [PSCustomObject][ordered]@{
            beforeContainers = $beforeStats
            afterContainers = $afterStats
            containerDeltas = Get-PitCrewStatsDelta `
                -Before $beforeStats `
                -After $afterStats
            beforeDockerSystem = $beforeDockerSystem
            afterDockerSystem = $afterDockerSystem
            beforeAdapters = $beforeAdapters
            afterAdapters = $afterAdapters
            adapterDeltas = Get-PitCrewAdapterDelta `
                -Before $beforeAdapters `
                -After $afterAdapters
        }
        urlProbes = $urlProbes
        commands = @($script:Commands)
    }
    unavailableEvidence = @($script:Unavailable)
    hypotheses = $hypotheses
}
$markdown = New-PitCrewMarkdownReport -Report $report
if ($PassThruOnly) {
    [PSCustomObject][ordered]@{
        report = $report
        markdown = $markdown
    }
    return
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path `
        (Get-Location).Path `
        "pitcrew-diagnostics-$PackageId"
}
Write-PitCrewResultArtifacts `
    -Report $report `
    -Markdown $markdown `
    -Destination $OutputDirectory
