#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path `
    $root `
    'plugins' `
    'pitcrew-operations' `
    'scripts' `
    'ProfileStatus.Projection.ps1')

$errors = [Collections.Generic.List[string]]::new()
$checks = 0

function Add-Check {
    param(
        [object]$Condition,
        [Parameter(Mandatory)][string]$Failure
    )

    $script:checks++
    if (-not $Condition) {
        $script:errors.Add($Failure)
        Write-Host "::error title=PitCrew profile status contract::$Failure"
    }
}

function New-ObservedProfile {
    param(
        [Parameter(Mandatory)][DateTimeOffset]$ObservedAt,
        [int]$MaximumSlots = 4,
        [int]$MinimumIdleSlots = 0,
        [int]$TargetSlots = 0,
        [int]$ActiveSlots = 0,
        [string]$ManagerStatus = 'running',
        [string]$AutoscalingStatus = 'running'
    )

    return [PSCustomObject][ordered]@{
        profileId = 'default'
        managerStatus = $ManagerStatus
        observedAt = $ObservedAt.ToString('O')
        desiredStateStatus = 'accepted'
        desiredSlots = $TargetSlots
        activeSlots = $ActiveSlots
        drainingSlots = 0
        configuredSlots = $MaximumSlots
        autoscaling = [PSCustomObject][ordered]@{
            mode = 'scale-set'
            status = $AutoscalingStatus
            minimumIdleSlots = $MinimumIdleSlots
            maximumSlots = $MaximumSlots
            targetSlots = $TargetSlots
            idleRunners = 0
            busyRunners = 0
            scaleDownAt = $null
            lastError = $null
        }
    }
}

$observedAt = [DateTimeOffset]::Parse(
    '2026-10-01T12:00:00Z',
    [Globalization.CultureInfo]::InvariantCulture)

$scaleToZero = New-PitCrewProfileStatusModel `
    -ProfileId default `
    -GeneratedAt $observedAt.AddSeconds(30) `
    -ProfileConfigured $true `
    -InventoryAuthoritative $true `
    -InventoryCoverage complete `
    -ObservedProfile (New-ObservedProfile -ObservedAt $observedAt) `
    -ManagerRunning $true
Add-Check (
    $scaleToZero.configurationState -eq 'configured' -and
    $scaleToZero.runtimeState -eq 'idle-scale-to-zero' -and
    $scaleToZero.reasonCode -eq 'healthy-scale-to-zero' -and
    $scaleToZero.summary -eq
        'CONFIGURED · AUTOSCALED · IDLE (SCALE-TO-ZERO)' -and
    $scaleToZero.configuredMaximum -eq 4 -and
    $scaleToZero.targetSlots -eq 0 -and
    $scaleToZero.activeSlots -eq 0
) 'Healthy measured zero demand was not classified as configured scale-to-zero.'

$exactBoundary = New-PitCrewProfileStatusModel `
    -ProfileId default `
    -GeneratedAt $observedAt.AddSeconds(120) `
    -ProfileConfigured $true `
    -InventoryAuthoritative $true `
    -InventoryCoverage complete `
    -ObservedProfile (New-ObservedProfile -ObservedAt $observedAt) `
    -ManagerRunning $true
Add-Check (
    $exactBoundary.runtimeState -eq 'idle-scale-to-zero'
) 'Exactly 120-second-old manager evidence was treated as stale.'

$stale = New-PitCrewProfileStatusModel `
    -ProfileId default `
    -GeneratedAt $observedAt.AddSeconds(120.001) `
    -ProfileConfigured $true `
    -InventoryAuthoritative $true `
    -InventoryCoverage complete `
    -ObservedProfile (New-ObservedProfile -ObservedAt $observedAt) `
    -ManagerRunning $true
Add-Check (
    $stale.runtimeState -eq 'stale' -and
    $stale.reasonCode -eq 'manager-evidence-stale'
) 'Manager evidence older than 120 seconds was not classified as stale.'

$notConfigured = New-PitCrewProfileStatusModel `
    -ProfileId missing `
    -GeneratedAt $observedAt `
    -ProfileConfigured $false `
    -InventoryAuthoritative $true `
    -InventoryCoverage complete `
    -ObservedProfile $null `
    -ManagerRunning $null
Add-Check (
    $notConfigured.configurationState -eq 'not-configured' -and
    $null -eq $notConfigured.runtimeState -and
    $notConfigured.summary -eq 'NOT CONFIGURED'
) 'Complete authoritative inventory did not prove profile absence.'

$unknown = New-PitCrewProfileStatusModel `
    -ProfileId missing `
    -GeneratedAt $observedAt `
    -ProfileConfigured $false `
    -InventoryAuthoritative $false `
    -InventoryCoverage unavailable `
    -ObservedProfile $null `
    -ManagerRunning $null
Add-Check (
    $unknown.configurationState -eq 'unknown' -and
    $unknown.reasonCode -eq 'inventory-not-authoritative' -and
    $unknown.summary -eq 'CONFIGURATION UNKNOWN'
) 'Unavailable inventory was incorrectly treated as authoritative absence.'

$paused = New-PitCrewProfileStatusModel `
    -ProfileId default `
    -GeneratedAt $observedAt.AddSeconds(30) `
    -ProfileConfigured $true `
    -InventoryAuthoritative $true `
    -InventoryCoverage complete `
    -ObservedProfile (
        New-ObservedProfile `
            -ObservedAt $observedAt `
            -MaximumSlots 0) `
    -ManagerRunning $true `
    -ExplicitlyPaused $true
Add-Check (
    $paused.runtimeState -eq 'paused' -and
    $paused.reasonCode -eq 'explicit-capacity-pause'
) 'An acknowledged zero-capacity pause was treated as scale-to-zero.'

$stopped = New-PitCrewProfileStatusModel `
    -ProfileId default `
    -GeneratedAt $observedAt.AddSeconds(30) `
    -ProfileConfigured $true `
    -InventoryAuthoritative $true `
    -InventoryCoverage complete `
    -ObservedProfile (
        New-ObservedProfile `
            -ObservedAt $observedAt `
            -ManagerStatus stopped) `
    -ManagerRunning $false
Add-Check (
    $stopped.configurationState -eq 'configured' -and
    $stopped.runtimeState -eq 'manager-stopped'
) 'A configured stopped manager was treated as missing configuration.'

$dashboard = ConvertTo-PitCrewDashboardProfileStatusModel `
    -ExpectedProfileId default `
    -Response ([PSCustomObject][ordered]@{
        generatedAt = $observedAt.ToString('O')
        nodeId = '11111111-1111-4111-8111-111111111111'
        profileId = 'default'
        inventoryCoverage = 'complete'
        inventoryAuthoritative = $true
        inventoryObservedAt = $observedAt.ToString('O')
        inventoryReceivedAt = $observedAt.ToString('O')
        inventoryUnavailableReason = $null
        configurationState = 'configured'
        runtimeState = 'idle-scale-to-zero'
        reasonCode = 'healthy-scale-to-zero'
        summary = 'CONFIGURED · AUTOSCALED · IDLE (SCALE-TO-ZERO)'
        nodeOnline = $true
        nodeLastSeenAt = $observedAt.ToString('O')
        managerStatus = 'running'
        managerObservedAt = $observedAt.ToString('O')
        capacityMode = 'autoscaled'
        explicitlyPaused = $false
        configuredMaximum = 4
        minimumIdleSlots = 0
        targetSlots = 0
        activeSlots = 0
        idleRunners = 0
        busyRunners = 0
        drainingSlots = 0
        autoscalingStatus = 'running'
    })
Add-Check (
    $dashboard.source -eq 'dashboard' -and
    $dashboard.configurationState -eq 'configured' -and
    $dashboard.runtimeState -eq 'idle-scale-to-zero'
) 'The Dashboard profile-status response was not normalized.'

$invalidDashboardRejected = $false
try {
    ConvertTo-PitCrewDashboardProfileStatusModel `
        -ExpectedProfileId default `
        -Response ([PSCustomObject][ordered]@{
            generatedAt = $observedAt.ToString('O')
            profileId = 'default'
            inventoryCoverage = 'partial'
            inventoryAuthoritative = $false
            configurationState = 'unknown'
            runtimeState = 'active'
            reasonCode = 'inventory-not-authoritative'
            summary = 'CONFIGURATION UNKNOWN'
        }) |
        Out-Null
} catch {
    $invalidDashboardRejected = $true
}
Add-Check (
    $invalidDashboardRejected
) 'Dashboard runtime state without configured evidence was accepted.'

$invalidObservedRejected = $false
try {
    New-PitCrewProfileStatusModel `
        -ProfileId default `
        -GeneratedAt $observedAt `
        -ProfileConfigured $true `
        -InventoryAuthoritative $true `
        -InventoryCoverage complete `
        -ObservedProfile ([PSCustomObject]@{
            profileId = 'default'
            managerStatus = 'running'
            observedAt = 'invalid'
        }) `
        -ManagerRunning $true |
        Out-Null
} catch {
    $invalidObservedRejected = $true
}
Add-Check (
    $invalidObservedRejected
) 'Malformed local observed-state evidence was converted into a status.'

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    throw "PitCrew profile-status tests failed: $($errors.Count) of $checks checks."
}
Write-Host "PitCrew profile-status tests passed: $checks checks."
