#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-PitCrewAdmissionProperty {
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

function ConvertTo-PitCrewAdmissionTimestamp {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    try {
        return ([DateTimeOffset]$Value).ToUniversalTime().ToString('O')
    } catch {
        return $null
    }
}

function ConvertTo-PitCrewAdmissionInteger {
    param(
        [AllowNull()][object]$Value,
        [long]$Minimum = 0
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
        $parsed -lt $Minimum) {
        return $null
    }
    return $parsed
}

function Test-PitCrewAdmissionFingerprint {
    param([AllowNull()][object]$Value)

    return $null -ne $Value -and
        [string]$Value -match '^[A-Za-z0-9_-]{1,128}$'
}

function New-PitCrewAdmissionSnapshotModel {
    param(
        [Parameter(Mandatory)][Guid]$NodeId,
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
        [string]$ProfileId,
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$RequestedWorkers,
        [Parameter(Mandatory)][DateTimeOffset]$GeneratedAt,
        [AllowNull()][object]$ObservedProfile,
        [AllowNull()][object]$ProfileEvidence,
        [AllowNull()]
        [ValidatePattern('^[a-z][a-z0-9]*(-[a-z0-9]+)*$')]
        [string]$MissingReason
    )

    $normalizedMissingReason =
        if ([string]::IsNullOrWhiteSpace($MissingReason)) {
            $null
        } else {
            $MissingReason
        }
    $evidence = [PSCustomObject][ordered]@{
        authority = $null
        source = $null
        managerContractVersion = $null
        sourceObservedAt = $null
        dashboardReceivedAt = $null
        evaluatedAt = $null
        responseGeneratedAt = $null
        freshnessBoundary = $null
        freshness = 'unavailable'
        coverage = 'unavailable'
        retention = $null
        completeness = 'unsupported'
        unavailableReason = $normalizedMissingReason
    }
    $admission = [PSCustomObject][ordered]@{
        status = $null
        epoch = $null
        decisionSequence = $null
        hostPolicyFingerprint = $null
        profilePolicyFingerprint = $null
        unitCost = $null
        requestedUnits = $null
        allocatableUnits = $null
        allocatableWorkers = $null
        theoreticalMaximumUnits = $null
        theoreticalMaximumWorkers = $null
        pendingUnits = $null
        withheldUnits = $null
        withholdingReason = $null
    }
    $snapshot = [PSCustomObject][ordered]@{
        schemaVersion = 1
        generatedAt = $GeneratedAt.ToUniversalTime().ToString('O')
        scope = [PSCustomObject][ordered]@{
            nodeId = $NodeId.ToString('D')
            profileId = $ProfileId
            requestedWorkers = $RequestedWorkers
        }
        evidence = $evidence
        admission = $admission
        disposition = 'unknown'
        reason = if ($null -eq $normalizedMissingReason) {
            'host-admission-evidence-unavailable'
        } else {
            $normalizedMissingReason
        }
        limitations = @(
            'This is a point-in-time observation, not a capacity reservation or a promise that a later acquisition will succeed.',
            'Fair-share rotation, intervening leases, and new demand may change the next coordinator decision.',
            'Admission units are abstract policy accounting, not CPU, memory, worker priority, or universal workload weights.',
            'The snapshot does not estimate GitHub queue wait or workflow completion time.'
        )
    }
    if ($null -eq $ObservedProfile) {
        return $snapshot
    }
    if ([string](Get-PitCrewAdmissionProperty `
            $ObservedProfile `
            'profileId') -cne $ProfileId) {
        $evidence.completeness = 'incomplete'
        $snapshot.reason = 'profile-identity-mismatch'
        $evidence.unavailableReason = $snapshot.reason
        return $snapshot
    }
    $evidenceProfileId = Get-PitCrewAdmissionProperty `
        $ProfileEvidence `
        'profileId'
    if ($null -ne $evidenceProfileId -and
        [string]$evidenceProfileId -cne $ProfileId) {
        $evidence.completeness = 'incomplete'
        $snapshot.reason = 'profile-evidence-identity-mismatch'
        $evidence.unavailableReason = $snapshot.reason
        return $snapshot
    }

    $managerContractVersion = ConvertTo-PitCrewAdmissionInteger `
        -Value (Get-PitCrewAdmissionProperty `
            $ObservedProfile `
            'managerContractVersion') `
        -Minimum 1
    $evidence.managerContractVersion = $managerContractVersion
    $hostAdmission = Get-PitCrewAdmissionProperty `
        $ObservedProfile `
        'hostAdmission'
    $status = [string](Get-PitCrewAdmissionProperty `
        $hostAdmission `
        'status')
    if ($status -in @(
            'available',
            'degraded',
            'unavailable',
            'disabled')) {
        $admission.status = $status
    }

    if ($null -eq $managerContractVersion -or
        $managerContractVersion -lt 19) {
        $snapshot.reason = 'contract-19-required'
        $evidence.unavailableReason = $snapshot.reason
        return $snapshot
    }

    $claims = @(
        Get-PitCrewAdmissionProperty $ProfileEvidence 'claims' @() |
            Where-Object {
                [string](Get-PitCrewAdmissionProperty $_ 'name') -ceq
                    'host-admission'
            })
    if ($claims.Count -eq 0) {
        $snapshot.reason = 'host-admission-freshness-unsupported'
        $evidence.unavailableReason = $snapshot.reason
        return $snapshot
    }
    if ($claims.Count -ne 1) {
        $evidence.completeness = 'incomplete'
        $snapshot.reason = 'host-admission-claim-ambiguous'
        $evidence.unavailableReason = $snapshot.reason
        return $snapshot
    }

    $claim = $claims[0]
    $claimAuthority = [string](Get-PitCrewAdmissionProperty `
        $claim `
        'authority')
    $claimSource = [string](Get-PitCrewAdmissionProperty $claim 'source')
    $evidence.authority = if ($claimAuthority -ceq 'pitcrew-manager') {
        $claimAuthority
    } else {
        $null
    }
    $evidence.source = if ($claimSource -ceq 'host-admission') {
        $claimSource
    } else {
        $null
    }
    $evidence.sourceObservedAt = ConvertTo-PitCrewAdmissionTimestamp (
        Get-PitCrewAdmissionProperty $claim 'sourceObservedAt')
    $evidence.dashboardReceivedAt = ConvertTo-PitCrewAdmissionTimestamp (
        Get-PitCrewAdmissionProperty $claim 'dashboardReceivedAt')
    $evidence.evaluatedAt = ConvertTo-PitCrewAdmissionTimestamp (
        Get-PitCrewAdmissionProperty $claim 'evaluatedAt')
    $evidence.responseGeneratedAt = ConvertTo-PitCrewAdmissionTimestamp (
        Get-PitCrewAdmissionProperty $claim 'responseGeneratedAt')
    $evidence.freshnessBoundary = ConvertTo-PitCrewAdmissionTimestamp (
        Get-PitCrewAdmissionProperty $claim 'freshnessBoundary')
    $claimFreshness = [string](Get-PitCrewAdmissionProperty `
        $claim `
        'freshness')
    $claimCoverage = [string](Get-PitCrewAdmissionProperty `
        $claim `
        'coverage')
    $claimRetention = [string](Get-PitCrewAdmissionProperty `
        $claim `
        'retention')
    $claimUnavailableReason = Get-PitCrewAdmissionProperty `
        $claim `
        'unavailableReason'
    $evidence.freshness = if ($claimFreshness -in @(
            'current',
            'stale',
            'partial',
            'unavailable',
            'last-known')) {
        $claimFreshness
    } else {
        'unavailable'
    }
    $evidence.coverage = if ($claimCoverage -in @(
            'complete',
            'partial',
            'unavailable')) {
        $claimCoverage
    } else {
        'unavailable'
    }
    $evidence.retention = if ($claimRetention -in @(
            'live',
            'last-known')) {
        $claimRetention
    } else {
        $null
    }
    if ($null -ne $claimUnavailableReason -and
        [string]$claimUnavailableReason -match
            '^[a-z][a-z0-9]*(-[a-z0-9]+)*$') {
        $evidence.unavailableReason = [string]$claimUnavailableReason
    }

    $claimValue = Get-PitCrewAdmissionProperty $claim 'value'
    $claimValueValid = if ($claimCoverage -eq 'unavailable') {
        $null -eq $claimValue
    } else {
        [string]$claimValue -ceq $admission.status
    }
    $claimStateValid = switch ($claimFreshness) {
        'current' {
            $claimCoverage -eq 'complete' -and
                $claimRetention -eq 'live'
        }
        'stale' {
            $claimCoverage -eq 'complete' -and
                $claimRetention -eq 'live'
        }
        'partial' {
            $claimCoverage -eq 'partial' -and
                $claimRetention -eq 'live'
        }
        'unavailable' {
            $claimCoverage -eq 'unavailable' -and
                $claimRetention -eq 'live'
        }
        'last-known' {
            $claimCoverage -eq 'complete' -and
                $claimRetention -eq 'last-known'
        }
        default {
            $false
        }
    }
    $generatedAtText = $GeneratedAt.ToUniversalTime().ToString('O')
    $claimShapeValid =
        $claimAuthority -ceq 'pitcrew-manager' -and
        $claimSource -ceq 'host-admission' -and
        $claimStateValid -and
        $null -ne $admission.status -and
        $claimValueValid -and
        $null -ne $evidence.responseGeneratedAt -and
        $evidence.responseGeneratedAt -ceq $generatedAtText
    if (-not $claimShapeValid) {
        $evidence.completeness = 'incomplete'
        $snapshot.reason = 'host-admission-claim-invalid'
        $evidence.unavailableReason = $snapshot.reason
        return $snapshot
    }

    if ($claimFreshness -ne 'current' -or
        $claimCoverage -ne 'complete' -or
        $claimRetention -ne 'live') {
        $evidence.completeness = 'complete'
        $snapshot.reason = "host-admission-$claimFreshness"
        if ($null -eq $evidence.unavailableReason) {
            $evidence.unavailableReason = $snapshot.reason
        }
        return $snapshot
    }

    if ($null -in @(
            $evidence.sourceObservedAt,
            $evidence.dashboardReceivedAt,
            $evidence.evaluatedAt,
            $evidence.freshnessBoundary) -or
        $evidence.evaluatedAt -cne $generatedAtText) {
        $evidence.completeness = 'incomplete'
        $snapshot.reason = 'host-admission-claim-incomplete'
        $evidence.unavailableReason = $snapshot.reason
        return $snapshot
    }

    if ($admission.status -ne 'available') {
        $evidence.completeness = 'complete'
        $snapshot.reason = "host-admission-$($admission.status)"
        return $snapshot
    }

    $accounting = Get-PitCrewAdmissionProperty $hostAdmission 'accounting'
    $epoch = ConvertTo-PitCrewAdmissionInteger (
        Get-PitCrewAdmissionProperty $hostAdmission 'epoch')
    $decisionSequence = ConvertTo-PitCrewAdmissionInteger (
        Get-PitCrewAdmissionProperty $hostAdmission 'decisionSequence')
    $unitCost = ConvertTo-PitCrewAdmissionInteger `
        -Value (Get-PitCrewAdmissionProperty $accounting 'unitCost') `
        -Minimum 1
    $allocatableUnits = ConvertTo-PitCrewAdmissionInteger (
        Get-PitCrewAdmissionProperty $accounting 'allocatableUnits')
    $allocatableWorkers = ConvertTo-PitCrewAdmissionInteger (
        Get-PitCrewAdmissionProperty $accounting 'allocatableWorkers')
    $theoreticalMaximumUnits = ConvertTo-PitCrewAdmissionInteger (
        Get-PitCrewAdmissionProperty `
            $accounting `
            'theoreticalMaximumUnits')
    $theoreticalMaximumWorkers = ConvertTo-PitCrewAdmissionInteger (
        Get-PitCrewAdmissionProperty `
            $accounting `
            'theoreticalMaximumWorkers')
    $pendingUnits = ConvertTo-PitCrewAdmissionInteger (
        Get-PitCrewAdmissionProperty $accounting 'pendingUnits')
    $withheldUnits = ConvertTo-PitCrewAdmissionInteger (
        Get-PitCrewAdmissionProperty $accounting 'withheldUnits')
    $hostPolicyFingerprint = Get-PitCrewAdmissionProperty `
        $hostAdmission `
        'hostPolicyFingerprint'
    $profilePolicyFingerprint = Get-PitCrewAdmissionProperty `
        $accounting `
        'profilePolicyFingerprint'
    $withholdingReason = Get-PitCrewAdmissionProperty `
        $accounting `
        'withholdingReason'
    $withholdingReasonValid = $null -eq $withholdingReason -or
        [string]$withholdingReason -in @(
            'budget-exhausted',
            'protected-reservation',
            'fair-share-contention',
            'adoption-pending')
    $accountingComplete = $null -notin @(
            $epoch,
            $decisionSequence,
            $unitCost,
            $allocatableUnits,
            $allocatableWorkers,
            $theoreticalMaximumUnits,
            $theoreticalMaximumWorkers,
            $pendingUnits,
            $withheldUnits) -and
        (Test-PitCrewAdmissionFingerprint $hostPolicyFingerprint) -and
        (Test-PitCrewAdmissionFingerprint $profilePolicyFingerprint)
    $accountingValid = $accountingComplete -and
        $allocatableWorkers -eq
            [Math]::Floor($allocatableUnits / $unitCost) -and
        $theoreticalMaximumWorkers -eq
            [Math]::Floor($theoreticalMaximumUnits / $unitCost) -and
        $allocatableUnits -le $theoreticalMaximumUnits -and
        $pendingUnits -eq $withheldUnits -and
        $withholdingReasonValid -and
        ($null -eq $withholdingReason -or
            ($allocatableUnits -eq 0 -and
                $allocatableWorkers -eq 0))
    if (-not $accountingValid) {
        $evidence.completeness = 'incomplete'
        $snapshot.reason = if ($accountingComplete) {
            'host-admission-accounting-invalid'
        } else {
            'host-admission-accounting-incomplete'
        }
        $evidence.unavailableReason = $snapshot.reason
        return $snapshot
    }

    $evidence.completeness = 'complete'
    $evidence.unavailableReason = $null
    $admission.epoch = $epoch
    $admission.decisionSequence = $decisionSequence
    $admission.hostPolicyFingerprint = [string]$hostPolicyFingerprint
    $admission.profilePolicyFingerprint = [string]$profilePolicyFingerprint
    $admission.unitCost = $unitCost
    $admission.requestedUnits = [long]$RequestedWorkers * $unitCost
    $admission.allocatableUnits = $allocatableUnits
    $admission.allocatableWorkers = $allocatableWorkers
    $admission.theoreticalMaximumUnits = $theoreticalMaximumUnits
    $admission.theoreticalMaximumWorkers = $theoreticalMaximumWorkers
    $admission.pendingUnits = $pendingUnits
    $admission.withheldUnits = $withheldUnits
    $admission.withholdingReason = if ($null -eq $withholdingReason) {
        $null
    } else {
        [string]$withholdingReason
    }
    if ($RequestedWorkers -le $allocatableWorkers) {
        $snapshot.disposition = 'admissible-now'
        $snapshot.reason = 'current-allocatable-capacity-sufficient'
    } else {
        $snapshot.disposition = 'insufficient-now'
        $snapshot.reason = 'current-allocatable-capacity-insufficient'
    }
    return $snapshot
}
