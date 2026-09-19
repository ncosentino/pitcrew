#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pluginRoot = Join-Path $root 'plugins' 'pitcrew-operations'
$projectionPath = Join-Path `
    $pluginRoot `
    'scripts' `
    'HostAdmission.Projection.ps1'
$commandPath = Join-Path `
    $pluginRoot `
    'skills' `
    'pitcrew-admission-snapshot' `
    'scripts' `
    'New-PitCrewAdmissionSnapshot.ps1'
$schemaPath = Join-Path `
    $pluginRoot `
    'skills' `
    'pitcrew-admission-snapshot' `
    'references' `
    'admission-snapshot.schema.json'
. $projectionPath

$errors = [Collections.Generic.List[string]]::new()
$checks = 0
$generatedAt = [DateTimeOffset]'2026-09-18T21:00:00Z'
$observedAt = $generatedAt.AddSeconds(-15)
$receivedAt = $generatedAt.AddSeconds(-14)
$nodeId = [Guid]'22222222-2222-4222-8222-222222222222'

function Add-Check {
    param(
        [object]$Condition,
        [string]$Failure
    )

    $script:checks++
    if (-not $Condition) {
        $script:errors.Add($Failure)
    }
}

function New-TestAdmissionProfile {
    param(
        [string]$Status = 'available',
        [int]$ManagerContractVersion = 22,
        [AllowNull()][Nullable[long]]$Epoch = 4,
        [AllowNull()][Nullable[long]]$DecisionSequence = 51,
        [AllowNull()][Nullable[long]]$UnitCost = 2,
        [AllowNull()][Nullable[long]]$AllocatableUnits = 6,
        [AllowNull()][Nullable[long]]$AllocatableWorkers = 3,
        [AllowNull()][Nullable[long]]$TheoreticalMaximumUnits = 10,
        [AllowNull()][Nullable[long]]$TheoreticalMaximumWorkers = 5,
        [AllowNull()][Nullable[long]]$PendingUnits = 0,
        [AllowNull()][Nullable[long]]$WithheldUnits = 0,
        [AllowNull()][object]$WithholdingReason = $null,
        [string]$ProfileId = 'project-ci'
    )

    $accounting = if ($Status -eq 'available') {
        [PSCustomObject][ordered]@{
            unitCost = $UnitCost
            reservedUnits = 4
            borrowable = $false
            profilePolicyFingerprint = 'fixture-profile-policy'
            activeUnits = 2
            provisionalUnits = 0
            heldUnits = 2
            borrowedUnits = 0
            pendingUnits = $PendingUnits
            withheldUnits = $WithheldUnits
            allocatableUnits = $AllocatableUnits
            allocatableWorkers = $AllocatableWorkers
            theoreticalMaximumUnits = $TheoreticalMaximumUnits
            theoreticalMaximumWorkers = $TheoreticalMaximumWorkers
            withholdingReason = $WithholdingReason
        }
    } else {
        $null
    }
    return [PSCustomObject][ordered]@{
        schemaVersion = 1
        managerContractVersion = $ManagerContractVersion
        profileId = $ProfileId
        managerInstanceId = 'fixture-manager-private-identity'
        managerStatus = 'running'
        observedAt = $script:observedAt.ToString('O')
        hostAdmission = [PSCustomObject][ordered]@{
            status = $Status
            namespace = 'fixture-private-namespace'
            epoch = $Epoch
            decisionSequence = $DecisionSequence
            capacityUnits = 12
            safetyMarginUnits = 2
            effectiveTotalUnits = 10
            availableUnits = $AllocatableUnits
            hostPolicyFingerprint = if ($Status -eq 'available') {
                'fixture-host-policy'
            } else {
                $null
            }
            accounting = $accounting
            lastDecision = $null
        }
        slots = @(
            [PSCustomObject]@{
                runnerName = 'fixture-private-runner'
                repository = 'private/example'
                containerId = 'fixture-private-container'
            })
        update = [PSCustomObject]@{
            targetImage = 'registry.example.invalid/private/image:latest'
        }
        hostPath = 'C:\private\pitcrew'
    }
}

function New-TestAdmissionEvidence {
    param(
        [string]$Status = 'available',
        [string]$Freshness = 'current',
        [string]$Coverage = 'complete',
        [string]$Retention = 'live',
        [AllowNull()][object]$UnavailableReason = $null
    )

    $value = if ($Coverage -eq 'unavailable') {
        $null
    } else {
        $Status
    }
    return [PSCustomObject][ordered]@{
        profileId = 'project-ci'
        dashboardReceivedAt = $script:receivedAt.ToString('O')
        claims = @(
            [PSCustomObject][ordered]@{
                name = 'host-admission'
                authority = 'pitcrew-manager'
                source = 'host-admission'
                sourceIdentity = 'fixture-manager-private-identity'
                sourceObservedAt = $script:observedAt.ToString('O')
                dashboardReceivedAt = $script:receivedAt.ToString('O')
                evaluatedAt = $script:generatedAt.ToString('O')
                verifiedAt = $null
                responseGeneratedAt = $script:generatedAt.ToString('O')
                freshnessBoundary =
                    $script:observedAt.AddMinutes(2).ToString('O')
                coverage = $Coverage
                retention = $Retention
                freshness = $Freshness
                value = $value
                unavailableReason = $UnavailableReason
            })
    }
}

function New-TestAdmissionSnapshot {
    param(
        [Parameter(Mandatory)][object]$Profile,
        [Parameter(Mandatory)][object]$Evidence,
        [int]$RequestedWorkers = 2
    )

    return New-PitCrewAdmissionSnapshotModel `
        -NodeId $script:nodeId `
        -ProfileId project-ci `
        -RequestedWorkers $RequestedWorkers `
        -GeneratedAt $script:generatedAt `
        -ObservedProfile $Profile `
        -ProfileEvidence $Evidence
}

$sufficient = New-TestAdmissionSnapshot `
    -Profile (New-TestAdmissionProfile) `
    -Evidence (New-TestAdmissionEvidence) `
    -RequestedWorkers 2
Add-Check (
    $sufficient.disposition -eq 'admissible-now' -and
    $sufficient.reason -eq 'current-allocatable-capacity-sufficient' -and
    $sufficient.admission.requestedUnits -eq 4 -and
    $sufficient.admission.allocatableWorkers -eq 3 -and
    $sufficient.admission.theoreticalMaximumWorkers -eq 5
) 'Fresh sufficient coordinator capacity was not classified as admissible now.'
Add-Check (
    $sufficient.evidence.freshness -eq 'current' -and
    $sufficient.evidence.coverage -eq 'complete' -and
    $sufficient.evidence.retention -eq 'live' -and
    $sufficient.evidence.completeness -eq 'complete'
) 'Fresh complete host-admission provenance was not preserved.'
Add-Check (
    (($sufficient | ConvertTo-Json -Depth 12) |
        Test-Json -SchemaFile $schemaPath)
) 'A valid admission snapshot did not satisfy its published JSON schema.'

$withheld = New-TestAdmissionSnapshot `
    -Profile (New-TestAdmissionProfile `
        -AllocatableUnits 0 `
        -AllocatableWorkers 0 `
        -PendingUnits 4 `
        -WithheldUnits 4 `
        -WithholdingReason budget-exhausted) `
    -Evidence (New-TestAdmissionEvidence) `
    -RequestedWorkers 1
Add-Check (
    $withheld.disposition -eq 'insufficient-now' -and
    $withheld.admission.allocatableWorkers -eq 0 -and
    $withheld.admission.allocatableUnits -eq 0 -and
    $withheld.admission.withholdingReason -eq 'budget-exhausted'
) 'Measured-zero capacity or active withholding was not preserved.'

$fairShareBlocked = New-TestAdmissionSnapshot `
    -Profile (New-TestAdmissionProfile `
        -DecisionSequence 52 `
        -AllocatableUnits 0 `
        -AllocatableWorkers 0 `
        -PendingUnits 2 `
        -WithheldUnits 2 `
        -WithholdingReason fair-share-contention) `
    -Evidence (New-TestAdmissionEvidence) `
    -RequestedWorkers 1
$fairShareChanged = New-TestAdmissionSnapshot `
    -Profile (New-TestAdmissionProfile `
        -DecisionSequence 53 `
        -AllocatableUnits 4 `
        -AllocatableWorkers 2 `
        -PendingUnits 0 `
        -WithheldUnits 0) `
    -Evidence (New-TestAdmissionEvidence) `
    -RequestedWorkers 1
Add-Check (
    $fairShareBlocked.disposition -eq 'insufficient-now' -and
    $fairShareBlocked.admission.withholdingReason -eq
        'fair-share-contention' -and
    $fairShareChanged.disposition -eq 'admissible-now' -and
    $fairShareChanged.admission.decisionSequence -eq 53
) 'Point-in-time fair-share changes were not reflected without retaining an earlier decision.'

$stale = New-TestAdmissionSnapshot `
    -Profile (New-TestAdmissionProfile) `
    -Evidence (New-TestAdmissionEvidence -Freshness stale) `
    -RequestedWorkers 1
Add-Check (
    $stale.disposition -eq 'unknown' -and
    $stale.reason -eq 'host-admission-stale' -and
    $stale.admission.status -eq 'available' -and
    $null -eq $stale.admission.allocatableWorkers
) 'Stale admission evidence produced a current capacity conclusion.'

$degraded = New-TestAdmissionSnapshot `
    -Profile (New-TestAdmissionProfile -Status degraded) `
    -Evidence (New-TestAdmissionEvidence `
        -Status degraded `
        -Freshness partial `
        -Coverage partial `
        -UnavailableReason source-partial) `
    -RequestedWorkers 1
Add-Check (
    $degraded.disposition -eq 'unknown' -and
    $degraded.admission.status -eq 'degraded' -and
    $degraded.evidence.freshness -eq 'partial'
) 'Degraded host admission was not kept distinct from available capacity.'

$unavailable = New-TestAdmissionSnapshot `
    -Profile (New-TestAdmissionProfile -Status unavailable) `
    -Evidence (New-TestAdmissionEvidence `
        -Status unavailable `
        -Freshness unavailable `
        -Coverage unavailable `
        -UnavailableReason source-unavailable) `
    -RequestedWorkers 1
Add-Check (
    $unavailable.disposition -eq 'unknown' -and
    $unavailable.admission.status -eq 'unavailable' -and
    $unavailable.evidence.unavailableReason -eq 'source-unavailable'
) 'Unavailable host admission was not kept distinct from measured zero.'

$disabled = New-TestAdmissionSnapshot `
    -Profile (New-TestAdmissionProfile -Status disabled) `
    -Evidence (New-TestAdmissionEvidence -Status disabled) `
    -RequestedWorkers 1
Add-Check (
    $disabled.disposition -eq 'unknown' -and
    $disabled.reason -eq 'host-admission-disabled' -and
    $disabled.admission.status -eq 'disabled'
) 'Disabled host admission was not preserved as a distinct unknown disposition.'

$incompleteProfile = New-TestAdmissionProfile
$incompleteProfile.hostAdmission.accounting.PSObject.Properties.Remove(
    'theoreticalMaximumWorkers')
$incomplete = New-TestAdmissionSnapshot `
    -Profile $incompleteProfile `
    -Evidence (New-TestAdmissionEvidence) `
    -RequestedWorkers 1
Add-Check (
    $incomplete.disposition -eq 'unknown' -and
    $incomplete.evidence.completeness -eq 'incomplete' -and
    $incomplete.reason -eq 'host-admission-accounting-incomplete'
) 'Incomplete contract-19 accounting produced a capacity conclusion.'

$legacy = New-TestAdmissionSnapshot `
    -Profile (New-TestAdmissionProfile -ManagerContractVersion 19) `
    -Evidence ([PSCustomObject]@{
        profileId = 'project-ci'
        claims = @()
    }) `
    -RequestedWorkers 1
Add-Check (
    $legacy.disposition -eq 'unknown' -and
    $legacy.evidence.completeness -eq 'unsupported' -and
    $legacy.reason -eq 'host-admission-freshness-unsupported'
) 'Contract-19 evidence without authoritative freshness was treated as current.'

$missingNode = New-PitCrewAdmissionSnapshotModel `
    -NodeId $nodeId `
    -ProfileId project-ci `
    -RequestedWorkers 1 `
    -GeneratedAt $generatedAt `
    -MissingReason node-not-found
Add-Check (
    $missingNode.disposition -eq 'unknown' -and
    $missingNode.reason -eq 'node-not-found' -and
    $missingNode.evidence.freshness -eq 'unavailable'
) 'An absent scoped node was not recorded as unavailable evidence.'
Add-Check (
    @(
        @(
            $withheld,
            $fairShareBlocked,
            $stale,
            $degraded,
            $unavailable,
            $disabled,
            $incomplete,
            $legacy,
            $missingNode) |
            Where-Object {
                -not (($_ | ConvertTo-Json -Depth 12) |
                    Test-Json -SchemaFile $schemaPath)
            }
    ).Count -eq 0
) 'One or more non-admissible snapshots violated the published JSON schema.'

$privacyJson = $sufficient | ConvertTo-Json -Depth 12
Add-Check (
    $privacyJson -notmatch 'fixture-manager-private-identity' -and
    $privacyJson -notmatch 'fixture-private-namespace' -and
    $privacyJson -notmatch 'fixture-private-runner' -and
    $privacyJson -notmatch 'private/example' -and
    $privacyJson -notmatch 'fixture-private-container' -and
    $privacyJson -notmatch 'registry\.example\.invalid' -and
    $privacyJson -notmatch 'C:\\private'
) 'The admission snapshot leaked non-allowlisted profile or host evidence.'

$outputRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "pitcrew-admission-snapshot-$([Guid]::NewGuid().ToString('N'))"
$outputPath = Join-Path $outputRoot 'pitcrew-admission-snapshot.json'
$missingProfilePath = Join-Path $outputRoot 'missing-profile.json'
$previousCredential = [Environment]::GetEnvironmentVariable(
    'PITCREW_DIAGNOSTICS_CREDENTIAL')
$global:PitCrewAdmissionTestCalls =
    [Collections.Generic.List[string]]::new()
$global:PitCrewAdmissionTestGeneratedAt = $generatedAt
$global:PitCrewAdmissionTestTargetNode = $nodeId.ToString('D')
$global:PitCrewAdmissionTestProfile = New-TestAdmissionProfile
$global:PitCrewAdmissionTestEvidence = New-TestAdmissionEvidence
function Start-Sleep {
    param(
        [int]$Milliseconds,
        [int]$Seconds
    )
}
function Invoke-RestMethod {
    param(
        [string]$Method,
        [object]$Uri,
        [hashtable]$Headers
    )

    $uriText = [string]$Uri
    $global:PitCrewAdmissionTestCalls.Add(
        "$Method|$uriText|$($Headers.Authorization)")
    if ($uriText -notmatch 'afterNodeId=') {
        return [PSCustomObject][ordered]@{
            generatedAt =
                $global:PitCrewAdmissionTestGeneratedAt.ToString('O')
            nodes = @(
                [PSCustomObject]@{
                    nodeId = '11111111-1111-4111-8111-111111111111'
                    profiles = @()
                    profileEvidence = @()
                })
            nextAfterNodeId =
                '11111111-1111-4111-8111-111111111111'
        }
    }
    return [PSCustomObject][ordered]@{
        generatedAt = $global:PitCrewAdmissionTestGeneratedAt.ToString('O')
        nodes = @(
            [PSCustomObject]@{
                nodeId = $global:PitCrewAdmissionTestTargetNode
                displayName = 'fixture-private-node'
                profiles = @($global:PitCrewAdmissionTestProfile)
                profileEvidence = @($global:PitCrewAdmissionTestEvidence)
            })
        nextAfterNodeId = '33333333-3333-4333-8333-333333333333'
    }
}
try {
    [Environment]::SetEnvironmentVariable(
        'PITCREW_DIAGNOSTICS_CREDENTIAL',
        'fixture-diagnostic-credential')
    & $commandPath `
        -DashboardUrl https://dashboard.example `
        -TenantId example `
        -NodeId $nodeId `
        -Profile project-ci `
        -RequestedWorkers 2 `
        -OutputPath $outputPath
    $commandSnapshot = Get-Content `
        -LiteralPath $outputPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 20
    Add-Check (
        $commandSnapshot.disposition -eq 'admissible-now' -and
        $commandSnapshot.scope.nodeId -eq $nodeId.ToString('D') -and
        $commandSnapshot.scope.profileId -eq 'project-ci'
    ) 'The supported command did not write the selected admission snapshot.'
    Add-Check (
        ((Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8) |
            Test-Json -SchemaFile $schemaPath)
    ) 'The supported command wrote JSON outside the published schema.'
    Add-Check (
        $global:PitCrewAdmissionTestCalls.Count -eq 2 -and
        @(
            $global:PitCrewAdmissionTestCalls |
                Where-Object {
                    $_ -notmatch
                        '^Get\|https://dashboard\.example/api/diagnostics/v1/tenants/example/fleet/nodes\?' -or
                    $_ -notmatch
                        '\|PitCrew-Diagnostics fixture-diagnostic-credential$'
                }).Count -eq 0 -and
        @(
            $global:PitCrewAdmissionTestCalls |
                Where-Object { $_ -match '/history|/api/tenants/' }
        ).Count -eq 0
    ) 'The supported command used an unscoped, mutating, or historical Dashboard surface.'

    & $commandPath `
        -DashboardUrl https://dashboard.example `
        -TenantId example `
        -NodeId $nodeId `
        -Profile other-profile `
        -RequestedWorkers 1 `
        -OutputPath $missingProfilePath
    $missingProfile = Get-Content `
        -LiteralPath $missingProfilePath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json -Depth 20
    Add-Check (
        $missingProfile.disposition -eq 'unknown' -and
        $missingProfile.reason -eq 'profile-not-found'
    ) 'An absent scoped profile did not produce an explicit unknown snapshot.'

    $callsBeforeInvalidUrl = $global:PitCrewAdmissionTestCalls.Count
    $invalidUrlRejected = $false
    try {
        & $commandPath `
            -DashboardUrl 'https://user:secret@dashboard.example' `
            -TenantId example `
            -NodeId $nodeId `
            -Profile project-ci `
            -RequestedWorkers 1 `
            -OutputPath (Join-Path $outputRoot 'invalid-url.json')
    } catch {
        $invalidUrlRejected =
            $_.Exception.Message -match 'cannot contain credentials'
    }
    Add-Check (
        $invalidUrlRejected -and
        $global:PitCrewAdmissionTestCalls.Count -eq $callsBeforeInvalidUrl
    ) 'A credential-bearing Dashboard URL reached the HTTP boundary.'

    [Environment]::SetEnvironmentVariable(
        'PITCREW_DIAGNOSTICS_CREDENTIAL',
        $null)
    $missingCredentialRejected = $false
    try {
        & $commandPath `
            -DashboardUrl https://dashboard.example `
            -TenantId example `
            -NodeId $nodeId `
            -Profile project-ci `
            -RequestedWorkers 1 `
            -OutputPath (Join-Path $outputRoot 'missing-credential.json')
    } catch {
        $missingCredentialRejected =
            $_.Exception.Message -match
                'Set PITCREW_DIAGNOSTICS_CREDENTIAL'
    }
    Add-Check (
        $missingCredentialRejected -and
        $global:PitCrewAdmissionTestCalls.Count -eq $callsBeforeInvalidUrl
    ) 'A missing diagnostic credential reached the HTTP boundary.'
} finally {
    [Environment]::SetEnvironmentVariable(
        'PITCREW_DIAGNOSTICS_CREDENTIAL',
        $previousCredential)
    Remove-Item Function:\Invoke-RestMethod -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Sleep -Force -ErrorAction SilentlyContinue
    foreach ($name in @(
            'PitCrewAdmissionTestCalls',
            'PitCrewAdmissionTestGeneratedAt',
            'PitCrewAdmissionTestTargetNode',
            'PitCrewAdmissionTestProfile',
            'PitCrewAdmissionTestEvidence')) {
        Remove-Variable `
            -Name $name `
            -Scope Global `
            -Force `
            -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $outputRoot) {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force
    }
}

if ($errors.Count -gt 0) {
    throw "Admission snapshot test failed ($($errors.Count)/$checks):`n$($errors -join "`n")"
}

Write-Host "Admission snapshot test passed ($checks assertions)."
