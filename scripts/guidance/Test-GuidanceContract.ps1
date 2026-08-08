#Requires -Version 7.0
<#
.SYNOPSIS
    Validate PitCrew's layered guidance contract.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
. (Join-Path $PSScriptRoot 'InstructionGlob.Functions.ps1')

$errors = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Add-Check {
    param(
        [object]$Condition,
        [string]$Failure
    )

    $script:checks++
    if (-not [bool]$Condition) {
        $script:errors.Add($Failure)
    }
}

function Get-RelativePath {
    param([string]$Path)
    return [IO.Path]::GetRelativePath($ProjectRoot, $Path).Replace('\', '/')
}

function Get-TextMetric {
    param([string]$RelativePath)

    $path = Join-Path $ProjectRoot ($RelativePath.Replace(
        '/',
        [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [PSCustomObject]@{
            path = $RelativePath
            exists = $false
            lines = 0
            bytes = 0
            content = ''
        }
    }

    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    return [PSCustomObject]@{
        path = $RelativePath
        exists = $true
        lines = @(Get-Content -LiteralPath $path -Encoding UTF8).Count
        bytes = [Text.Encoding]::UTF8.GetByteCount($content)
        content = $content
    }
}

function Get-FrontmatterValue {
    param(
        [string]$Content,
        [string]$Name
    )

    $frontmatter = Get-FrontmatterContent -Content $Content
    if ($null -eq $frontmatter) {
        return ''
    }
    $matches = [regex]::Matches(
        $frontmatter,
        "(?m)^\s*$([regex]::Escape($Name))\s*:\s*(.+?)\s*$")
    if ($matches.Count -gt 1) {
        throw "Frontmatter field '$Name' appears multiple times."
    }
    if ($matches.Count -eq 0) {
        return ''
    }
    return $matches[0].Groups[1].Value.Trim().Trim('"', "'")
}

function Get-FrontmatterContent {
    param([string]$Content)

    $match = [regex]::Match(
        $Content,
        '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|$)',
        [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups['frontmatter'].Value
}

function Get-ProjectFiles {
    $excluded = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(
        '.git',
        '.copilot-worktrees',
        '.pitcrew-state',
        'bin',
        'coverage',
        'dist',
        'node_modules',
        'obj',
        'site'
    )) {
        [void]$excluded.Add($name)
    }

    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($ProjectRoot)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            if ($item.PSIsContainer) {
                $isNestedRepository = Test-Path `
                    -LiteralPath (Join-Path $item.FullName '.git')
                if (
                    -not $excluded.Contains($item.Name) -and
                    -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
                    -not $isNestedRepository
                ) {
                    $pending.Push($item.FullName)
                }
            } else {
                $item
            }
        }
    }
}

$contractPath = Join-Path $ProjectRoot '.github' 'genesis-guidance.json'
$schemaPath = Join-Path $ProjectRoot '.github' 'genesis-guidance.schema.json'
Add-Check (Test-Path -LiteralPath $contractPath -PathType Leaf) (
    'Guidance contract is missing.')
Add-Check (Test-Path -LiteralPath $schemaPath -PathType Leaf) (
    'Guidance schema is missing.')
if ($errors.Count -gt 0) {
    throw "Guidance contract validation failed:`n$($errors -join "`n")"
}

$contractRaw = Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8
try {
    Add-Check (
        $contractRaw | Test-Json -SchemaFile $schemaPath -ErrorAction Stop
    ) 'Guidance contract does not conform to its schema.'
} catch {
    $errors.Add("Guidance schema validation failed: $($_.Exception.Message)")
}

try {
    $contract = $contractRaw | ConvertFrom-Json -Depth 20
} catch {
    throw "Guidance contract JSON is invalid: $($_.Exception.Message)"
}

$agents = Get-TextMetric ([string]$contract.agents.path)
Add-Check $agents.exists 'AGENTS.md is missing.'
Add-Check (
    $agents.lines -le [int]$contract.agents.maxLines -and
    $agents.bytes -le [int]$contract.agents.maxBytes
) (
    "AGENTS.md exceeds its budget: $($agents.lines) lines/$($agents.bytes) bytes.")

$claude = Get-TextMetric ([string]$contract.agents.redirects.claude)
Add-Check (
    $claude.exists -and
    $claude.lines -eq 1 -and
    $claude.content.TrimEnd("`r", "`n") -ceq '@AGENTS.md'
) 'CLAUDE.md must be the one-line @AGENTS.md redirect.'

$copilot = Get-TextMetric ([string]$contract.agents.redirects.copilot)
Add-Check (
    $copilot.exists -and
    $copilot.lines -le 3 -and
    $copilot.bytes -le 128 -and
    $copilot.content -match 'AGENTS\.md'
) 'The Copilot root redirect exceeds its budget or does not point to AGENTS.md.'

$docsRoot = Join-Path $ProjectRoot 'docs'
$mapPath = Join-Path $ProjectRoot ([string]$contract.docs.mapPath)
$allDocs = @(
    Get-ChildItem -LiteralPath $docsRoot -Recurse -Filter '*.md' -File |
        Sort-Object FullName
)
Add-Check (Test-Path -LiteralPath $mapPath -PathType Leaf) (
    "Documentation map '$($contract.docs.mapPath)' is missing.")

$visitedDocs = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
$pendingDocs = [Collections.Generic.Queue[string]]::new()
if (Test-Path -LiteralPath $mapPath -PathType Leaf) {
    $pendingDocs.Enqueue((Resolve-Path -LiteralPath $mapPath).Path)
}
while ($pendingDocs.Count -gt 0) {
    $current = $pendingDocs.Dequeue()
    if (-not $visitedDocs.Add($current)) {
        continue
    }

    $content = Get-Content -LiteralPath $current -Raw -Encoding UTF8
    foreach ($match in [regex]::Matches($content, '\]\((?<target>[^)]+)\)')) {
        $target = ($match.Groups['target'].Value -split '\s+')[0].Trim('<', '>')
        if (
            [string]::IsNullOrWhiteSpace($target) -or
            $target.StartsWith('#') -or
            $target -match '^[a-z][a-z0-9+.-]*:'
        ) {
            continue
        }

        $target = ($target -split '[?#]')[0]
        if ([string]::IsNullOrWhiteSpace($target)) {
            continue
        }
        $resolved = [IO.Path]::GetFullPath(
            (Join-Path (Split-Path -Parent $current) $target))
        Add-Check (
            $resolved.StartsWith(
                $ProjectRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolved -PathType Leaf)
        ) "Documentation link '$target' from '$(Get-RelativePath $current)' does not resolve."

        if (
            $resolved.StartsWith(
                $docsRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetExtension($resolved).Equals(
                '.md',
                [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolved -PathType Leaf)
        ) {
            $pendingDocs.Enqueue($resolved)
        }
    }
}

foreach ($doc in $allDocs) {
    Add-Check ($visitedDocs.Contains($doc.FullName)) (
        "Documentation page '$(Get-RelativePath $doc.FullName)' is not reachable from '$($contract.docs.mapPath)'.")
}

$adrIndexPath = Join-Path $ProjectRoot ([string]$contract.docs.adrIndexPath)
Add-Check (Test-Path -LiteralPath $adrIndexPath -PathType Leaf) (
    "ADR index '$($contract.docs.adrIndexPath)' is missing.")
$adrIndexContent = if (Test-Path -LiteralPath $adrIndexPath -PathType Leaf) {
    Get-Content -LiteralPath $adrIndexPath -Raw -Encoding UTF8
} else {
    ''
}
$adrRecords = @(
    Get-ChildItem -LiteralPath (Split-Path -Parent $adrIndexPath) `
        -Filter 'adr-*.md' -File |
        Where-Object Name -match '^adr-\d{4}-.+\.md$' |
        Sort-Object Name
)
foreach ($adr in $adrRecords) {
    $content = Get-Content -LiteralPath $adr.FullName -Raw -Encoding UTF8
    $frontmatter = Get-FrontmatterContent -Content $content
    Add-Check ($null -ne $frontmatter) (
        "ADR '$($adr.Name)' has invalid frontmatter.")
    foreach ($field in @(
        'title',
        'status',
        'date',
        'authors',
        'tags',
        'supersedes',
        'superseded_by'
    )) {
        Add-Check (
            $null -ne $frontmatter -and
            $frontmatter -match "(?m)^\s*$([regex]::Escape($field))\s*:"
        ) "ADR '$($adr.Name)' is missing frontmatter field '$field'."
    }
    foreach ($field in @('title', 'status', 'date')) {
        Add-Check (-not [string]::IsNullOrWhiteSpace(
            (Get-FrontmatterValue -Content $content -Name $field)
        )) "ADR '$($adr.Name)' has an empty frontmatter field '$field'."
    }
    $status = Get-FrontmatterValue -Content $content -Name 'status'
    Add-Check (
        $status -in @(
            'Proposed',
            'Accepted',
            'Deprecated',
            'Superseded',
            'Rejected'
        )
    ) "ADR '$($adr.Name)' has unsupported status '$status'."
    Add-Check (
        $adrIndexContent -match [regex]::Escape($adr.Name)
    ) "ADR '$($adr.Name)' is missing from the ADR index."
}

$instructionRoot = Join-Path $ProjectRoot ([string]$contract.instructions.root)
$instructionFiles = @(
    Get-ChildItem -LiteralPath $instructionRoot -Recurse `
        -Filter '*.instructions.md' -File |
        Sort-Object FullName
)
$projectFiles = @(
    Get-ProjectFiles |
        ForEach-Object { Get-RelativePath $_.FullName }
)
$instructionRecords = [System.Collections.Generic.List[object]]::new()
foreach ($instruction in $instructionFiles) {
    $content = Get-Content -LiteralPath $instruction.FullName -Raw -Encoding UTF8
    $relative = Get-RelativePath $instruction.FullName
    $frontmatter = Get-FrontmatterContent -Content $content
    Add-Check ($null -ne $frontmatter) (
        "Instruction '$relative' has invalid frontmatter.")
    $applyTo = ''
    try {
        $applyTo = Get-FrontmatterValue -Content $content -Name 'applyTo'
    } catch {
        $errors.Add("Instruction '$relative' has invalid metadata: $($_.Exception.Message)")
    }
    Add-Check (-not [string]::IsNullOrWhiteSpace($applyTo)) (
        "Instruction '$relative' has no applyTo value.")
    if (-not [string]::IsNullOrWhiteSpace($applyTo)) {
        try {
            [void](Split-InstructionGlobPatterns -ApplyTo $applyTo)
        } catch {
            $errors.Add("Instruction '$relative' has invalid applyTo '$applyTo': $($_.Exception.Message)")
        }
    }

    $lines = @(Get-Content -LiteralPath $instruction.FullName -Encoding UTF8).Count
    $bytes = [Text.Encoding]::UTF8.GetByteCount($content)
    if (
        $lines -gt [int]$contract.instructions.individualReviewThreshold.lines -or
        $bytes -gt [int]$contract.instructions.individualReviewThreshold.bytes
    ) {
        Add-Check (-not [string]::IsNullOrWhiteSpace(
            (Get-FrontmatterValue -Content $content -Name 'reviewThresholdReason')
        )) "Instruction '$relative' exceeds its review threshold without a reason."
    }
    Add-Check (
        $content -notmatch '\.instructions\.md'
    ) "Instruction '$relative' names another instruction file."

    $matchCount = 0
    if (-not [string]::IsNullOrWhiteSpace($applyTo)) {
        foreach ($candidate in $projectFiles) {
            if (Test-InstructionGlobMatch -ApplyTo $applyTo -RelativePath $candidate) {
                $matchCount++
            }
        }
    }
    Add-Check ($matchCount -gt 0) (
        "Instruction '$relative' does not match a current repository file.")
    $instructionRecords.Add([PSCustomObject]@{
        path = $relative
        applyTo = $applyTo
        lines = $lines
        bytes = $bytes
    })
}

$managedRoot = Join-Path $ProjectRoot ([string]$contract.instructions.managedRoot)
if ([bool]$contract.instructions.managedInstalled) {
    Add-Check (Test-Path -LiteralPath $managedRoot -PathType Container) (
        'Managed instructions are declared installed but the managed root is missing.')
} else {
    Add-Check (-not (Test-Path -LiteralPath $managedRoot)) (
        'Managed instructions exist while managedInstalled is false.')
}

$contextMetrics = [System.Collections.Generic.List[object]]::new()
foreach ($representativePath in @($contract.instructions.representativePaths)) {
    $candidate = ([string]$representativePath).Replace('\', '/')
    Add-Check (
        -not [string]::IsNullOrWhiteSpace($candidate) -and
        -not ($candidate.Split('/') -contains '..') -and
        (Test-Path -LiteralPath (
            Join-Path $ProjectRoot $candidate.Replace(
                '/',
                [IO.Path]::DirectorySeparatorChar)
        ) -PathType Leaf)
    ) "Representative path '$candidate' is missing or invalid."

    $matches = @(
        $instructionRecords |
            Where-Object {
                $_.applyTo -and
                (Test-InstructionGlobMatch `
                    -ApplyTo $_.applyTo `
                    -RelativePath $candidate)
            }
    )
    $lines = [int](($matches | Measure-Object lines -Sum).Sum ?? 0)
    $bytes = [int](($matches | Measure-Object bytes -Sum).Sum ?? 0)
    $exception = @(
        $contract.contextExceptions |
            Where-Object {
                Test-InstructionGlobMatch `
                    -ApplyTo ([string]$_.pattern) `
                    -RelativePath $candidate
            }
    ) | Select-Object -First 1
    $lineLimit = if ($exception) {
        [int]$exception.maxLines
    } else {
        [int]$contract.instructions.matchedContext.targetLines
    }
    $byteLimit = if ($exception) {
        [int]$exception.maxBytes
    } else {
        [int]$contract.instructions.matchedContext.targetBytes
    }
    Add-Check (
        $lines -le [int]$contract.instructions.matchedContext.maxLines -and
        $bytes -le [int]$contract.instructions.matchedContext.maxBytes
    ) "Representative path '$candidate' exceeds the hard matched-context ceiling."
    Add-Check (
        $lines -le $lineLimit -and
        $bytes -le $byteLimit
    ) (
        "Representative path '$candidate' exceeds its matched-context target: " +
        "$lines lines/$bytes bytes.")
    $contextMetrics.Add([PSCustomObject]@{
        path = $candidate
        instructionPaths = @($matches.path)
        lines = $lines
        bytes = $bytes
    })
}

foreach ($property in $contract.review.PSObject.Properties) {
    $relative = [string]$property.Value
    Add-Check (
        Test-Path -LiteralPath (
            Join-Path $ProjectRoot $relative.Replace(
                '/',
                [IO.Path]::DirectorySeparatorChar)
        ) -PathType Leaf
    ) "Review surface '$relative' is missing."
}

$reviewSkill = Get-TextMetric ([string]$contract.review.skillPath)
Add-Check (
    $reviewSkill.lines -le 200 -and
    $reviewSkill.bytes -le 8192
) "The review skill exceeds 200 lines or 8 KiB."
Add-Check (
    $reviewSkill.content -match 'Get-ApplicableInstructions\.ps1' -and
    $reviewSkill.content -match 'Get-ValidationInventory\.ps1'
) 'The review skill does not resolve instructions and validation dynamically.'

$mirrorRoot = Join-Path $ProjectRoot '.claude' 'rules' 'generated'
if (@($contract.generatedMirrors).Count -eq 0) {
    Add-Check (-not (Test-Path -LiteralPath $mirrorRoot)) (
        'Generated mirror files exist without a declared owning command.')
} else {
    foreach ($mirror in @($contract.generatedMirrors)) {
        Add-Check (
            Test-Path -LiteralPath (
                Join-Path $ProjectRoot ([string]$mirror.path)
            )
        ) "Generated mirror '$($mirror.path)' is missing."
    }
}

if ($errors.Count -gt 0) {
    throw "Guidance contract validation failed:`n$($errors -join "`n")"
}

$maxContext = $contextMetrics |
    Sort-Object lines, bytes -Descending |
    Select-Object -First 1
$result = [PSCustomObject]@{
    checks = $checks
    docs = $allDocs.Count
    adrs = $adrRecords.Count
    instructions = $instructionRecords.Count
    maximumMatchedContext = $maxContext
}

if ($Json) {
    $result | ConvertTo-Json -Depth 10
} else {
    $result
}
