#Requires -Version 7.0
<#
.SYNOPSIS
    Public read-only checker for a reflect-work proposal report.
.DESCRIPTION
    Checks the closed report schema, evidence lineage and references, scope coverage,
    ownership, current repository HEAD, and local target hashes. It never applies a
    proposal, executes commands from evidence, or contacts GitHub.

    A valid receipt proves these structural checks only. It is not approval, proof of
    a causal explanation, verification of external citations, or a behavioral eval.
.PARAMETER ReportPath
    Explicit report JSON file, no larger than one MiB.
.PARAMETER TargetPath
    Root of the repository whose current HEAD and proposed local targets are checked.
.PARAMETER Json
    Emit compact JSON rather than a PSCustomObject.
.OUTPUTS
    A report-only receipt. Invalid or stale reports throw.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$TargetPath,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'ReflectionJson.Functions.ps1')

function Assert-RelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -match '[\\:*?"<>|\x00-\x1f]' -or $Path.StartsWith('/') -or
        $Path -match '(^|/)(?:\.|\.\.|\.git)(?:/|$)' -or
        $Path.Contains('//') -or $Path.EndsWith('/') -or $Path.StartsWith('~') -or
        @($Path.Split('/') | Where-Object { $_.EndsWith('.') -or $_.EndsWith(' ') }).Count) {
        throw "Invalid repository-relative target path '$Path'. Use portable paths without traversal."
    }
}

function Assert-References {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$References,
        [Parameter(Mandatory)][string]$Context,
        [switch]$AllowRetracted
    )

    foreach ($reference in $References) {
        if (-not $script:evidenceById.ContainsKey([string]$reference)) {
            throw "$Context contains unknown evidence reference '$reference'."
        }
        if (-not $AllowRetracted -and
            $script:evidenceById[[string]$reference].status -ceq 'retracted') {
            throw "$Context relies on retracted evidence '$reference'."
        }
    }
}

function Get-ObservedLineages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$References,
        [ValidateSet('', 'incident', 'context', 'outcome')][string]$Role = ''
    )

    return @(
        $References | ForEach-Object { $script:evidenceById[[string]$_] } |
            Where-Object { $_.status -ceq 'observed' -and
                ([string]::IsNullOrEmpty($Role) -or $_.role -ceq $Role) } |
            ForEach-Object { $_.lineage } | Sort-Object -CaseSensitive -Unique
    )
}

function Assert-LocalTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Target)

    if ($Target.path -match '^(?:\.github/instructions/genesis)(?:/|$)') {
        throw "Repository proposals cannot edit the Genesis-managed subtree '$($Target.path)'."
    }
    if ($Target.path -match '^\.claude/rules/generated(?:/|$)') {
        throw "Repository proposals cannot edit the generated mirror '$($Target.path)'."
    }

    $current = $script:targetRoot
    $parts = $Target.path.Split('/')
    for ($index = 0; $index -lt $parts.Count; $index++) {
        $part = $parts[$index]
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Target path '$($Target.path)' traverses a link or reparse point."
            }
            if ($index -lt $parts.Count - 1 -and -not $item.PSIsContainer) {
                throw "Target path '$($Target.path)' has a non-directory ancestor."
            }
        }
    }
    $exists = Test-Path -LiteralPath $current -PathType Leaf
    if ($Target.action -ceq 'add') {
        if ((Test-Path -LiteralPath $current) -or $null -ne $Target.beforeSha256) {
            throw "Add target '$($Target.path)' already exists or has a before hash."
        }
    } else {
        if (-not $exists -or $null -eq $Target.beforeSha256) {
            throw "Existing target '$($Target.path)' needs a current file and before hash."
        }
        $actual = (Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash
        if (-not $actual.Equals([string]$Target.beforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Target hash changed for '$($Target.path)'; recollect evidence before review."
        }
    }
}

$schemaPath = Join-Path $PSScriptRoot '..' 'reference' 'reflection-report.schema.json'
$inputDocument = Read-ReflectionJson -Path $ReportPath -SchemaPath $schemaPath `
    -SchemaLabel 'reflection-report' -MaxBytes 1MB
$report = $inputDocument.Value
$targetRoot = (Resolve-Path -LiteralPath $TargetPath).Path
if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
    throw 'TargetPath must be an existing repository root.'
}
$rootOutput = @(& git --no-optional-locks -C $targetRoot rev-parse --show-toplevel 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve repository root: $($rootOutput -join '; ')"
}
$gitRoot = (Resolve-Path -LiteralPath ([string]$rootOutput[0])).Path
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if (-not $targetRoot.Equals($gitRoot, $comparison)) {
    throw 'TargetPath must identify the repository root, not a subdirectory.'
}
$headOutput = @(& git --no-optional-locks -C $targetRoot rev-parse --verify 'HEAD^{commit}' 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Unable to resolve HEAD: $($headOutput -join '; ')" }
$head = ([string]$headOutput[0]).Trim()
if (-not $head.Equals([string]$report.repository.headSha, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Report HEAD is stale or belongs to another repository revision.'
}

$from = [DateTimeOffset]::Parse([string]$report.window.from, [Globalization.CultureInfo]::InvariantCulture)
$to = [DateTimeOffset]::Parse([string]$report.window.to, [Globalization.CultureInfo]::InvariantCulture)
if ($from -ge $to) { throw 'Reflection window must have from earlier than to.' }

$evidenceById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($item in $report.evidence) {
    if (-not $evidenceById.TryAdd([string]$item.id, $item)) {
        throw "Duplicate evidence id '$($item.id)'."
    }
    if ($item.source -ceq 'external-source' -and $item.role -cne 'context') {
        throw "External research '$($item.id)' is context, not a repository incident or evaluation outcome."
    }
}
$areas = @('instructions', 'documentation', 'hooks', 'root-guidance', 'skills', 'enforcement', 'ci', 'tests')
$seenAreas = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($coverage in $report.coverage) {
    if (-not $seenAreas.Add([string]$coverage.area)) { throw "Duplicate coverage '$($coverage.area)'." }
    Assert-References -References @($coverage.evidenceRefs) -Context "coverage '$($coverage.area)'"
    if ($coverage.status -ceq 'reviewed' -and
        @(Get-ObservedLineages -References @($coverage.evidenceRefs)).Count -eq 0) {
        throw "Reviewed coverage '$($coverage.area)' needs observed evidence."
    }
}
if ($seenAreas.Count -ne $areas.Count -or @($areas | Where-Object { -not $seenAreas.Contains($_) }).Count) {
    throw 'Report coverage must account for all eight reflection areas.'
}
if (@($report.coverage | Where-Object { $_.status -ceq 'unavailable' }).Count -gt 0 -and
    $report.status -cne 'partial') {
    throw "Unavailable evidence requires status 'partial', not a complete result."
}

$findingKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$targetComparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$targetKeys = [Collections.Generic.HashSet[string]]::new($targetComparer)
$actionableCount = 0
foreach ($finding in $report.findings) {
    if (-not $findingKeys.Add([string]$finding.key)) { throw "Duplicate finding '$($finding.key)'." }
    $context = "Finding '$($finding.key)'"
    Assert-References -References @($finding.evidenceRefs) -Context $context
    Assert-References -References @($finding.counterEvidenceRefs) -Context $context -AllowRetracted
    Assert-References -References @($finding.genesis.evidenceRefs) -Context "$context Genesis"
    Assert-References -References @($finding.evaluation.evidenceRefs) -Context "$context evaluation"
    if ($finding.evidenceRefs.Count -eq 0) { throw "$context needs supporting evidence." }
    $actionable = $finding.disposition -cin @('recommend', 'retract')
    if ($actionable) {
        $actionableCount++
        $lineages = @(Get-ObservedLineages -References @($finding.evidenceRefs) -Role 'incident')
        $minimum = if ($finding.impact -cin @('critical', 'high')) { 1 } else { 2 }
        if ($lineages.Count -lt $minimum) {
            throw "$context needs $minimum independent observed incident lineage(s)."
        }
        if ($null -eq $finding.target) { throw "$context needs an exact proposed target." }
        if ($finding.enforcement.outcome -ceq 'unknown') {
            throw "$context must investigate deterministic enforcement before recommending a change."
        }
        if ($finding.evaluation.status -ceq 'regression') {
            throw "$context cannot recommend a candidate with an observed regression."
        }
    }
    if ($finding.disposition -ceq 'retract' -and $finding.supersedes.Count -eq 0) {
        throw "$context retraction must identify the superseded finding or guidance."
    }
    if ($finding.evaluation.status -ceq 'observed-improvement' -and
        @(Get-ObservedLineages -References @($finding.evaluation.evidenceRefs) -Role 'outcome').Count -eq 0) {
        throw "$context claims improvement without observed evaluation evidence."
    }
    if ($null -eq $finding.target) { continue }
    $target = $finding.target
    Assert-RelativePath -Path $target.path
    if ($actionable -and -not $targetKeys.Add("$($target.owner):$($target.path)")) {
        throw "$context duplicates an actionable target; consolidate its proposed changes."
    }
    if ($target.surface -ceq 'instruction' -and [string]::IsNullOrWhiteSpace($target.applyTo)) {
        throw "$context instruction needs its intended applyTo population."
    }
    $targetName = $target.path.Split('/')[-1]
    if (($target.surface -ceq 'root-guidance' -or
        $targetName -in @('AGENTS.md', 'CLAUDE.md', 'copilot-instructions.md')) -and
        [string]::IsNullOrWhiteSpace($finding.rootJustification)) {
        throw "$context rootJustification must explain why narrower mechanisms are insufficient."
    }
    if ($target.owner -ceq 'repository') {
        Assert-LocalTarget -Target $target
    } elseif ($target.owner -ceq 'genesis' -and $actionable) {
        if ($finding.genesis.status -cnotin @('gap', 'partial') -or
            $null -eq $finding.genesis.baselineCommit -or
            @(Get-ObservedLineages -References @($finding.genesis.evidenceRefs)).Count -eq 0) {
            throw "$context needs an evidenced Genesis gap or partial coverage and exact baseline commit."
        }
    }
}
if ($report.status -ceq 'no-change' -and $actionableCount -gt 0) {
    throw 'A no-change report cannot contain actionable recommendations or retractions.'
}
$receipt = [PSCustomObject][ordered]@{
    schemaVersion = 1
    mode = 'report-only'
    valid = $true
    approvalRequired = $true
    status = $report.status
    headSha = $head
    evidenceCount = $evidenceById.Count
    findingCount = $findingKeys.Count
    actionableCount = $actionableCount
    reportSha256 = $inputDocument.Sha256
    limitations = @(
        'Structural validation is not approval or verification of causality and external citations.'
        'Recommendations have not been applied or behaviorally evaluated by this checker.'
    )
}
if ($Json) { $receipt | ConvertTo-Json -Depth 10 -Compress } else { $receipt }
