#Requires -Version 7.0
<#
.SYNOPSIS
Returns canonical configuration and runtime status for one PitCrew profile.

.DESCRIPTION
Uses either the exact Dashboard diagnostic profile-status endpoint or complete
local PitCrew profile inventory plus non-secret observed state. It never uses
GitHub's current runner list as configuration authority and never mutates
PitCrew, Docker, GitHub, Dashboard, or the host.
#>
[CmdletBinding(DefaultParameterSetName = 'Local')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
    [string]$Profile,

    [Parameter(ParameterSetName = 'Local')]
    [ValidateNotNullOrEmpty()]
    [string]$PitCrewRoot = '.',

    [Parameter(Mandatory, ParameterSetName = 'Dashboard')]
    [Uri]$DashboardUrl,

    [Parameter(Mandatory, ParameterSetName = 'Dashboard')]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
    [string]$TenantId,

    [Parameter(Mandatory, ParameterSetName = 'Dashboard')]
    [Guid]$NodeId,

    [AllowEmptyString()][string]$OutputPath = '',

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
. (Join-Path $pluginRoot 'scripts' 'ProfileStatus.Projection.ps1')

$generatedAt = [DateTimeOffset]::UtcNow
if ($PSCmdlet.ParameterSetName -eq 'Dashboard') {
    . (Join-Path $pluginRoot 'scripts' 'DashboardDiagnostics.Client.ps1')
    Assert-PitCrewDashboardUri $DashboardUrl
    if ($DashboardUrl.AbsolutePath -ne '/') {
        throw 'DashboardUrl must be an origin-only URL.'
    }
    $credential = [Environment]::GetEnvironmentVariable(
        'PITCREW_DIAGNOSTICS_CREDENTIAL')
    $credentialPresent = -not [string]::IsNullOrWhiteSpace($credential)
    Write-Host 'PitCrew profile status request:'
    Write-Host "  Source: Dashboard"
    Write-Host "  Dashboard origin: $($DashboardUrl.GetLeftPart([UriPartial]::Authority))"
    Write-Host "  Tenant: $TenantId"
    Write-Host "  Node: $($NodeId.ToString('D'))"
    Write-Host "  Profile: $Profile"
    Write-Host "  Diagnostic credential present: $credentialPresent"

    $client = New-PitCrewDashboardDiagnosticClient `
        -DashboardUrl $DashboardUrl `
        -Credential $credential
    $tenantPath = [Uri]::EscapeDataString($TenantId)
    $nodePath = [Uri]::EscapeDataString($NodeId.ToString('D'))
    $profilePath = [Uri]::EscapeDataString($Profile)
    $response = Invoke-PitCrewDashboardGet `
        -Client $client `
        -Path "/api/diagnostics/v1/tenants/$tenantPath/fleet/nodes/$nodePath/profiles/$profilePath/status"
    $status = ConvertTo-PitCrewDashboardProfileStatusModel `
        -Response $response `
        -ExpectedProfileId $Profile
} else {
    $resolvedRoot = [IO.Path]::GetFullPath($PitCrewRoot)
    foreach ($required in @(
        'Setup-Runner.ps1',
        'RunnerProfiles.Functions.ps1',
        'docker-compose.yml'
    )) {
        if (-not (Test-Path `
                -LiteralPath (Join-Path $resolvedRoot $required) `
                -PathType Leaf)) {
            throw "PitCrewRoot is missing required file '$required'."
        }
    }

    $stateRoot = Join-Path $resolvedRoot '.pitcrew-state'
    $inventoryAuthoritative = $false
    $profileDirectory = $null
    if (Test-Path -LiteralPath $stateRoot -PathType Container) {
        $directories = @(
            Get-ChildItem `
                -LiteralPath $stateRoot `
                -Directory `
                -Force `
                -ErrorAction Stop)
        $inventoryAuthoritative = $true
        $matches = @(
            $directories |
                Where-Object Name -CEQ $Profile)
        if ($matches.Count -gt 1) {
            throw 'Local profile inventory returned a duplicate profile.'
        }
        if ($matches.Count -eq 1) {
            $profileDirectory = $matches[0].FullName
        }
    }

    $observedProfile = $null
    if ($null -ne $profileDirectory) {
        $observedPath = Join-Path $profileDirectory 'observed-state.json'
        if (Test-Path -LiteralPath $observedPath -PathType Leaf) {
            $observedProfile = Get-Content `
                -LiteralPath $observedPath `
                -Raw `
                -Encoding UTF8 |
                ConvertFrom-Json -Depth 100
        }
    }

    $managerRunning = $null
    $dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -ne $dockerCommand) {
        $managerIds = @(
            & docker ps `
                --filter "label=ephemeral-runner-manager-profile=$Profile" `
                --format '{{.ID}}' |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_)
                })
        if ($LASTEXITCODE -eq 0) {
            if ($managerIds.Count -gt 1) {
                throw 'More than one running manager matches the exact profile.'
            }
            $managerRunning = $managerIds.Count -eq 1
        } else {
            Write-Warning 'Docker manager status is unavailable; classification will use generated state only.'
        }
    }

    Write-Host 'PitCrew profile status request:'
    Write-Host '  Source: local generated state'
    Write-Host "  Profile: $Profile"
    Write-Host "  Complete profile inventory: $inventoryAuthoritative"
    Write-Host "  Running manager evidence: $(if ($null -eq $managerRunning) { 'unavailable' } else { $managerRunning })"
    $status = New-PitCrewProfileStatusModel `
        -ProfileId $Profile `
        -GeneratedAt $generatedAt `
        -ProfileConfigured ($null -ne $profileDirectory) `
        -InventoryAuthoritative $inventoryAuthoritative `
        -InventoryCoverage $(if ($inventoryAuthoritative) {
            'complete'
        } else {
            'unavailable'
        }) `
        -ObservedProfile $observedProfile `
        -ManagerRunning $managerRunning `
        -ManagerFreshnessSeconds 120
}

Write-Host ''
Write-Host $status.summary
Write-Host "  Configuration: $($status.configurationState)"
Write-Host "  Runtime: $(if ($null -eq $status.runtimeState) { 'not-applicable' } else { $status.runtimeState })"
Write-Host "  Reason: $($status.reasonCode)"
Write-Host "  Configured maximum: $(if ($null -eq $status.configuredMaximum) { 'unavailable' } else { $status.configuredMaximum })"
Write-Host "  Target slots: $(if ($null -eq $status.targetSlots) { 'unavailable' } else { $status.targetSlots })"
Write-Host "  Active slots: $(if ($null -eq $status.activeSlots) { 'unavailable' } else { $status.activeSlots })"

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $resolvedOutputPath -PathType Container) {
        throw 'OutputPath must identify a JSON file, not a directory.'
    }
    [IO.Directory]::CreateDirectory(
        (Split-Path -Parent $resolvedOutputPath)) |
        Out-Null
    $json = $status | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText(
        $resolvedOutputPath,
        "$json`n",
        [Text.UTF8Encoding]::new($false))
    Write-Host "  JSON: $resolvedOutputPath"
}
if ($PassThru) {
    return $status
}
