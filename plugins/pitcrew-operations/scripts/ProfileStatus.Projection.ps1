#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-PitCrewProfileStatusProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function ConvertTo-PitCrewProfileStatusInteger {
    param(
        [AllowNull()][object]$Value,
        [int]$Minimum = 0
    )

    if ($null -eq $Value) {
        return $null
    }
    $parsed = 0
    if (-not [int]::TryParse(
            [string]$Value,
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed) -or
        $parsed -lt $Minimum) {
        return $null
    }
    return $parsed
}

function ConvertTo-PitCrewProfileStatusTimestamp {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    try {
        return ([DateTimeOffset]$Value).ToUniversalTime()
    } catch {
        return $null
    }
}

function New-PitCrewProfileStatusSummary {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('configured', 'not-configured', 'unknown')]
        [string]$ConfigurationState,
        [AllowNull()][string]$RuntimeState,
        [AllowNull()][string]$CapacityMode
    )

    if ($ConfigurationState -eq 'not-configured') {
        return 'NOT CONFIGURED'
    }
    if ($ConfigurationState -eq 'unknown') {
        return 'CONFIGURATION UNKNOWN'
    }

    $mode = if ($CapacityMode -eq 'autoscaled') {
        'AUTOSCALED'
    } elseif ($CapacityMode -eq 'fixed') {
        'FIXED'
    } else {
        $null
    }
    $runtime = switch ($RuntimeState) {
        'active' { 'ACTIVE' }
        'idle' { 'IDLE' }
        'idle-scale-to-zero' { 'IDLE (SCALE-TO-ZERO)' }
        'scaling-up' { 'SCALING UP' }
        'scaling-down' { 'SCALING DOWN' }
        'paused' { 'PAUSED' }
        'manager-stopped' { 'MANAGER STOPPED' }
        'degraded' { 'DEGRADED' }
        'stale' { 'STATUS STALE' }
        default { 'STATUS UNKNOWN' }
    }
    if ($null -eq $mode) {
        return "CONFIGURED · $runtime"
    }
    return "CONFIGURED · $mode · $runtime"
}

function New-PitCrewProfileStatusModel {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
        [string]$ProfileId,
        [Parameter(Mandatory)][DateTimeOffset]$GeneratedAt,
        [Parameter(Mandatory)][bool]$ProfileConfigured,
        [Parameter(Mandatory)][bool]$InventoryAuthoritative,
        [Parameter(Mandatory)]
        [ValidateSet('complete', 'partial', 'unavailable')]
        [string]$InventoryCoverage,
        [AllowNull()][object]$ObservedProfile,
        [AllowNull()][object]$ManagerRunning,
        [ValidateRange(1, 3600)]
        [int]$ManagerFreshnessSeconds = 120,
        [bool]$ExplicitlyPaused = $false,
        [ValidateSet('local', 'dashboard')]
        [string]$Source = 'local'
    )

    if ($null -ne $ManagerRunning -and
        $ManagerRunning -isnot [bool]) {
        throw 'ManagerRunning must be true, false, or null.'
    }

    $model = [PSCustomObject][ordered]@{
        schemaVersion = 1
        source = $Source
        generatedAt = $GeneratedAt.ToUniversalTime().ToString('O')
        nodeId = $null
        profileId = $ProfileId
        inventory = [PSCustomObject][ordered]@{
            coverage = $InventoryCoverage
            authoritative = $InventoryAuthoritative
            observedAt = $null
            receivedAt = $null
            unavailableReason = if ($InventoryCoverage -eq 'complete') {
                $null
            } else {
                'inventory-not-authoritative'
            }
        }
        configurationState = $null
        runtimeState = $null
        reasonCode = $null
        summary = $null
        nodeOnline = $null
        nodeLastSeenAt = $null
        managerStatus = $null
        managerObservedAt = $null
        managerFreshnessSeconds = $null
        managerRunning = if ($null -eq $ManagerRunning) {
            $null
        } else {
            [bool]$ManagerRunning
        }
        capacityMode = $null
        explicitlyPaused = if ($ProfileConfigured) {
            $ExplicitlyPaused
        } else {
            $null
        }
        configuredMaximum = $null
        minimumIdleSlots = $null
        targetSlots = $null
        activeSlots = $null
        idleRunners = $null
        busyRunners = $null
        drainingSlots = $null
        autoscalingStatus = $null
    }

    if (-not $ProfileConfigured) {
        $model.configurationState = if ($InventoryAuthoritative) {
            'not-configured'
        } else {
            'unknown'
        }
        $model.reasonCode = if ($InventoryAuthoritative) {
            'complete-current-inventory-omits-profile'
        } else {
            'inventory-not-authoritative'
        }
        $model.summary = New-PitCrewProfileStatusSummary `
            -ConfigurationState $model.configurationState
        return $model
    }

    $model.configurationState = 'configured'
    if ($null -eq $ObservedProfile) {
        $model.runtimeState = if ($ManagerRunning -eq $false) {
            'manager-stopped'
        } else {
            'stale'
        }
        $model.reasonCode = if ($ManagerRunning -eq $false) {
            'manager-not-running'
        } else {
            'observed-state-unavailable'
        }
        $model.summary = New-PitCrewProfileStatusSummary `
            -ConfigurationState 'configured' `
            -RuntimeState $model.runtimeState
        return $model
    }

    $observedProfileId = [string](
        Get-PitCrewProfileStatusProperty $ObservedProfile 'profileId')
    if ($observedProfileId -cne $ProfileId) {
        throw 'Observed profile identity does not match the requested profile.'
    }
    $managerStatus = [string](
        Get-PitCrewProfileStatusProperty $ObservedProfile 'managerStatus')
    if ($managerStatus -notin @(
            'starting',
            'running',
            'stopping',
            'stopped')) {
        throw 'Observed profile returned an invalid manager status.'
    }
    $managerObservedAt = ConvertTo-PitCrewProfileStatusTimestamp (
        Get-PitCrewProfileStatusProperty $ObservedProfile 'observedAt')
    if ($null -eq $managerObservedAt) {
        throw 'Observed profile returned an invalid observation time.'
    }
    $model.managerStatus = $managerStatus
    $model.managerObservedAt = $managerObservedAt.ToString('O')
    $freshness = (
        $GeneratedAt.ToUniversalTime() -
        $managerObservedAt).TotalSeconds
    $model.managerFreshnessSeconds = [Math]::Max(
        0,
        [Math]::Round($freshness, 3))

    $autoscaling = Get-PitCrewProfileStatusProperty `
        $ObservedProfile `
        'autoscaling'
    $model.capacityMode = if ($null -eq $autoscaling) {
        'fixed'
    } else {
        'autoscaled'
    }
    $model.configuredMaximum =
        if ($null -eq $autoscaling) {
            ConvertTo-PitCrewProfileStatusInteger (
                Get-PitCrewProfileStatusProperty `
                    $ObservedProfile `
                    'configuredSlots')
        } else {
            ConvertTo-PitCrewProfileStatusInteger (
                Get-PitCrewProfileStatusProperty `
                    $autoscaling `
                    'maximumSlots')
        }
    $model.minimumIdleSlots =
        if ($null -eq $autoscaling) {
            $null
        } else {
            ConvertTo-PitCrewProfileStatusInteger (
                Get-PitCrewProfileStatusProperty `
                    $autoscaling `
                    'minimumIdleSlots')
        }
    $model.targetSlots =
        if ($null -eq $autoscaling) {
            ConvertTo-PitCrewProfileStatusInteger (
                Get-PitCrewProfileStatusProperty `
                    $ObservedProfile `
                    'desiredSlots')
        } else {
            ConvertTo-PitCrewProfileStatusInteger (
                Get-PitCrewProfileStatusProperty `
                    $autoscaling `
                    'targetSlots')
        }
    $model.activeSlots = ConvertTo-PitCrewProfileStatusInteger (
        Get-PitCrewProfileStatusProperty $ObservedProfile 'activeSlots')
    $model.drainingSlots = ConvertTo-PitCrewProfileStatusInteger (
        Get-PitCrewProfileStatusProperty $ObservedProfile 'drainingSlots')
    if ($null -ne $autoscaling) {
        $model.idleRunners = ConvertTo-PitCrewProfileStatusInteger (
            Get-PitCrewProfileStatusProperty $autoscaling 'idleRunners')
        $model.busyRunners = ConvertTo-PitCrewProfileStatusInteger (
            Get-PitCrewProfileStatusProperty $autoscaling 'busyRunners')
        $model.autoscalingStatus = [string](
            Get-PitCrewProfileStatusProperty $autoscaling 'status')
    }

    if ($model.managerFreshnessSeconds -gt $ManagerFreshnessSeconds) {
        $model.runtimeState = 'stale'
        $model.reasonCode = 'manager-evidence-stale'
    } elseif ($ExplicitlyPaused) {
        $model.runtimeState = 'paused'
        $model.reasonCode = 'explicit-capacity-pause'
    } elseif ($ManagerRunning -eq $false -or
        $managerStatus -in @('stopping', 'stopped')) {
        $model.runtimeState = 'manager-stopped'
        $model.reasonCode = 'manager-not-running'
    } elseif ([string](
            Get-PitCrewProfileStatusProperty `
                $ObservedProfile `
                'desiredStateStatus') -in @(
            'invalid',
            'stale',
            'conflict') -or
        $model.autoscalingStatus -eq 'degraded' -or
        -not [string]::IsNullOrWhiteSpace([string](
            Get-PitCrewProfileStatusProperty $autoscaling 'lastError'))) {
        $model.runtimeState = 'degraded'
        $model.reasonCode = 'manager-reported-degraded-state'
    } elseif ($managerStatus -eq 'starting' -or
        $model.autoscalingStatus -eq 'starting') {
        $model.runtimeState = 'scaling-up'
        $model.reasonCode = 'manager-starting'
    } elseif ($null -eq $model.targetSlots -or
        $null -eq $model.activeSlots -or
        $null -eq $model.drainingSlots) {
        $model.runtimeState = 'degraded'
        $model.reasonCode = 'capacity-evidence-incomplete'
    } elseif ($model.activeSlots -lt $model.targetSlots) {
        $model.runtimeState = 'scaling-up'
        $model.reasonCode = 'active-capacity-below-target'
    } elseif ($model.drainingSlots -gt 0 -or
        $model.activeSlots -gt $model.targetSlots -or
        ($null -ne $autoscaling -and
            $null -ne (Get-PitCrewProfileStatusProperty `
                $autoscaling `
                'scaleDownAt')) -or
        $model.autoscalingStatus -eq 'stopping') {
        $model.runtimeState = 'scaling-down'
        $model.reasonCode = 'active-capacity-above-target'
    } elseif ($model.capacityMode -eq 'autoscaled' -and
        $model.configuredMaximum -gt 0 -and
        $model.minimumIdleSlots -eq 0 -and
        $model.targetSlots -eq 0 -and
        $model.activeSlots -eq 0) {
        $model.runtimeState = 'idle-scale-to-zero'
        $model.reasonCode = 'healthy-scale-to-zero'
    } elseif ($model.activeSlots -gt 0) {
        $model.runtimeState = 'active'
        $model.reasonCode = 'active-capacity-present'
    } elseif ($model.configuredMaximum -eq 0) {
        $model.runtimeState = 'degraded'
        $model.reasonCode = 'zero-maximum-without-acknowledged-pause'
    } elseif ($model.capacityMode -eq 'fixed') {
        $model.runtimeState = 'idle'
        $model.reasonCode = 'fixed-capacity-idle'
    } else {
        $model.runtimeState = 'degraded'
        $model.reasonCode = 'autoscaling-target-not-converged'
    }

    $model.summary = New-PitCrewProfileStatusSummary `
        -ConfigurationState $model.configurationState `
        -RuntimeState $model.runtimeState `
        -CapacityMode $model.capacityMode
    return $model
}

function ConvertTo-PitCrewDashboardProfileStatusModel {
    param(
        [Parameter(Mandatory)][object]$Response,
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
        [string]$ExpectedProfileId
    )

    $configurationState = [string](
        Get-PitCrewProfileStatusProperty $Response 'configurationState')
    $runtimeStateValue = Get-PitCrewProfileStatusProperty `
        $Response `
        'runtimeState'
    $runtimeState = if ($null -eq $runtimeStateValue) {
        $null
    } else {
        [string]$runtimeStateValue
    }
    $allowedRuntimeStates = @(
        'active',
        'idle',
        'idle-scale-to-zero',
        'scaling-up',
        'scaling-down',
        'paused',
        'manager-stopped',
        'degraded',
        'stale'
    )
    if ($configurationState -notin @(
            'configured',
            'not-configured',
            'unknown')) {
        throw 'Dashboard returned an unsupported configuration state.'
    }
    if ($configurationState -eq 'configured' -and
        $runtimeState -notin $allowedRuntimeStates) {
        throw 'Dashboard returned an unsupported configured runtime state.'
    }
    if ($configurationState -ne 'configured' -and
        $null -ne $runtimeState) {
        throw 'Dashboard returned runtime state without configured profile evidence.'
    }

    $profileId = [string](
        Get-PitCrewProfileStatusProperty $Response 'profileId')
    if ($profileId -cne $ExpectedProfileId) {
        throw 'Dashboard profile status identity does not match the request.'
    }
    $generatedAt = ConvertTo-PitCrewProfileStatusTimestamp (
        Get-PitCrewProfileStatusProperty $Response 'generatedAt')
    if ($null -eq $generatedAt) {
        throw 'Dashboard profile status omitted a valid generation time.'
    }
    $inventoryCoverage = [string](
        Get-PitCrewProfileStatusProperty $Response 'inventoryCoverage')
    if ($inventoryCoverage -notin @(
            'complete',
            'partial',
            'unavailable')) {
        throw 'Dashboard returned unsupported inventory coverage.'
    }
    $inventoryAuthoritative = Get-PitCrewProfileStatusProperty `
        $Response `
        'inventoryAuthoritative'
    if ($inventoryAuthoritative -isnot [bool]) {
        throw 'Dashboard profile status omitted inventory authority.'
    }
    if ($configurationState -eq 'not-configured' -and
        -not [bool]$inventoryAuthoritative) {
        throw 'Dashboard reported profile absence without authoritative inventory.'
    }
    $capacityModeValue = Get-PitCrewProfileStatusProperty `
        $Response `
        'capacityMode'
    $capacityMode = if ($null -eq $capacityModeValue) {
        $null
    } else {
        [string]$capacityModeValue
    }
    if ($configurationState -eq 'configured' -and
        $capacityMode -notin @('fixed', 'autoscaled')) {
        throw 'Dashboard returned an unsupported configured capacity mode.'
    }
    if ($configurationState -ne 'configured' -and
        $null -ne $capacityMode) {
        throw 'Dashboard returned capacity mode without configured profile evidence.'
    }
    $nodeOnline = Get-PitCrewProfileStatusProperty $Response 'nodeOnline'
    if ($nodeOnline -isnot [bool]) {
        throw 'Dashboard profile status omitted typed node availability.'
    }
    $managerStatusValue = Get-PitCrewProfileStatusProperty `
        $Response `
        'managerStatus'
    $managerStatus = if ($null -eq $managerStatusValue) {
        $null
    } else {
        [string]$managerStatusValue
    }
    $managerObservedAt = ConvertTo-PitCrewProfileStatusTimestamp (
        Get-PitCrewProfileStatusProperty $Response 'managerObservedAt')
    $explicitlyPaused = Get-PitCrewProfileStatusProperty `
        $Response `
        'explicitlyPaused'
    if ($configurationState -eq 'configured' -and
        ($managerStatus -notin @(
                'starting',
                'running',
                'stopping',
                'stopped') -or
            $null -eq $managerObservedAt -or
            $explicitlyPaused -isnot [bool])) {
        throw 'Dashboard configured status omitted typed manager evidence.'
    }
    if ($configurationState -ne 'configured' -and
        ($null -ne $managerStatusValue -or
            $null -ne $managerObservedAt -or
            $null -ne $explicitlyPaused)) {
        throw 'Dashboard returned manager evidence without configured profile evidence.'
    }
    $reasonCode = [string](
        Get-PitCrewProfileStatusProperty $Response 'reasonCode')
    if ($reasonCode -notmatch '^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$') {
        throw 'Dashboard returned an invalid profile status reason code.'
    }
    $summary = [string](
        Get-PitCrewProfileStatusProperty $Response 'summary')
    if ([string]::IsNullOrWhiteSpace($summary) -or
        $summary.Length -gt 128) {
        throw 'Dashboard returned an invalid profile status summary.'
    }
    $expectedSummary = New-PitCrewProfileStatusSummary `
        -ConfigurationState $configurationState `
        -RuntimeState $runtimeState `
        -CapacityMode $capacityMode
    if ($summary -cne $expectedSummary) {
        throw 'Dashboard returned a non-canonical profile status summary.'
    }
    $nodeId = [Guid]::Empty
    if (-not [Guid]::TryParse(
            [string](Get-PitCrewProfileStatusProperty `
                $Response `
                'nodeId'),
            [ref]$nodeId)) {
        throw 'Dashboard profile status omitted a valid node identifier.'
    }

    return [PSCustomObject][ordered]@{
        schemaVersion = 1
        source = 'dashboard'
        generatedAt = $generatedAt.ToString('O')
        nodeId = $nodeId.ToString('D')
        profileId = $profileId
        inventory = [PSCustomObject][ordered]@{
            coverage = $inventoryCoverage
            authoritative = [bool]$inventoryAuthoritative
            observedAt = Get-PitCrewProfileStatusProperty `
                $Response `
                'inventoryObservedAt'
            receivedAt = Get-PitCrewProfileStatusProperty `
                $Response `
                'inventoryReceivedAt'
            unavailableReason = Get-PitCrewProfileStatusProperty `
                $Response `
                'inventoryUnavailableReason'
        }
        configurationState = $configurationState
        runtimeState = $runtimeState
        reasonCode = $reasonCode
        summary = $summary
        nodeOnline = [bool]$nodeOnline
        nodeLastSeenAt = Get-PitCrewProfileStatusProperty `
            $Response `
            'nodeLastSeenAt'
        managerStatus = $managerStatus
        managerObservedAt = if ($null -eq $managerObservedAt) {
            $null
        } else {
            $managerObservedAt.ToString('O')
        }
        managerFreshnessSeconds = $null
        managerRunning = $null
        capacityMode = $capacityMode
        explicitlyPaused = $explicitlyPaused
        configuredMaximum = ConvertTo-PitCrewProfileStatusInteger (
            Get-PitCrewProfileStatusProperty `
                $Response `
                'configuredMaximum')
        minimumIdleSlots = ConvertTo-PitCrewProfileStatusInteger (
            Get-PitCrewProfileStatusProperty `
                $Response `
                'minimumIdleSlots')
        targetSlots = ConvertTo-PitCrewProfileStatusInteger (
            Get-PitCrewProfileStatusProperty $Response 'targetSlots')
        activeSlots = ConvertTo-PitCrewProfileStatusInteger (
            Get-PitCrewProfileStatusProperty $Response 'activeSlots')
        idleRunners = ConvertTo-PitCrewProfileStatusInteger (
            Get-PitCrewProfileStatusProperty $Response 'idleRunners')
        busyRunners = ConvertTo-PitCrewProfileStatusInteger (
            Get-PitCrewProfileStatusProperty $Response 'busyRunners')
        drainingSlots = ConvertTo-PitCrewProfileStatusInteger (
            Get-PitCrewProfileStatusProperty $Response 'drainingSlots')
        autoscalingStatus = Get-PitCrewProfileStatusProperty `
            $Response `
            'autoscalingStatus'
    }
}
