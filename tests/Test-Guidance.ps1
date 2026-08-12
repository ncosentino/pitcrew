#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$validator = Join-Path $root 'scripts' 'guidance' 'Test-GuidanceContract.ps1'
$inventoryScript = Join-Path $root 'scripts' 'guidance' 'Get-ValidationInventory.ps1'
$resolver = Join-Path $root 'scripts' 'guidance' 'Get-ApplicableInstructions.ps1'
$errors = [System.Collections.Generic.List[string]]::new()
$checks = 0
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'pitcrew-guidance-tests-' + [guid]::NewGuid().ToString('N'))

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

function Add-ThrowsCheck {
    param(
        [scriptblock]$Action,
        [string]$ExpectedMessage,
        [string]$Failure
    )

    $script:checks++
    try {
        & $Action
        $script:errors.Add("$Failure No error was thrown.")
    } catch {
        if ($_.Exception.Message -notmatch $ExpectedMessage) {
            $script:errors.Add(
                "$Failure Expected '$ExpectedMessage', got '$($_.Exception.Message)'.")
        }
    }
}

function Copy-Path {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string]$RelativePath
    )

    $source = Join-Path $SourceRoot $RelativePath
    $destination = Join-Path $DestinationRoot $RelativePath
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) `
            -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
        return
    }

    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath($SourceRoot, $file.FullName)
        $target = Join-Path $DestinationRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) `
            -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}

function New-GuidanceFixture {
    param([string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    foreach ($relative in @(
        'AGENTS.md',
        'CLAUDE.md',
        'README.md',
        '.github/copilot-instructions.md',
        '.github/genesis-guidance.json',
        '.github/genesis-guidance.schema.json',
        '.github/instructions',
        '.github/skills/review-changes',
        'scripts/guidance',
        'tests/Test-Guidance.ps1',
        'docs'
    )) {
        Copy-Path -SourceRoot $root -DestinationRoot $Path -RelativePath $relative
    }

    $contract = Get-Content `
        -LiteralPath (Join-Path $Path '.github' 'genesis-guidance.json') `
        -Raw |
        ConvertFrom-Json
    foreach ($relative in @($contract.instructions.representativePaths)) {
        $target = Join-Path $Path ([string]$relative)
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) `
                -Force | Out-Null
            Set-Content -LiteralPath $target -Value '' -Encoding utf8NoBOM
        }
    }
}

try {
    $result = & $validator -ProjectRoot $root
    Add-Check ($result.instructions -eq 8) (
        'The repository guidance contract did not discover eight instructions.')
    Add-Check ($result.adrs -eq 4) (
        'The repository guidance contract did not discover all four ADRs.')
    $inventory = & $inventoryScript -ProjectRoot $root
    Add-Check (
        @(
            $inventory.powershellTests |
                Where-Object { $_ -match '^\.copilot-worktrees/' }
        ).Count -eq 0
    ) 'Validation inventory included a nested Copilot worktree.'
    $resolverOutput = @(
        & pwsh -NoProfile -File $resolver -Path README.md docs/index.md 2>&1
    )
    Add-Check ($LASTEXITCODE -eq 0) (
        'The documented multi-path resolver invocation failed.')
    Add-Check (
        ($resolverOutput -join "`n") -match 'README\.md' -and
        ($resolverOutput -join "`n") -match 'docs/index\.md'
    ) 'The multi-path resolver invocation did not return both requested paths.'

    $base = Join-Path $temporaryRoot 'base'
    New-GuidanceFixture -Path $base
    Add-Check (
        (& $validator -ProjectRoot $base).instructions -eq 8
    ) 'The clean guidance fixture did not validate.'

    $rootBudget = Join-Path $temporaryRoot 'root-budget'
    Copy-Item -LiteralPath $base -Destination $rootBudget -Recurse
    Add-Content -LiteralPath (Join-Path $rootBudget 'AGENTS.md') `
        -Value (('excess guidance' + [Environment]::NewLine) * 100)
    Add-ThrowsCheck {
        & $validator -ProjectRoot $rootBudget | Out-Null
    } 'AGENTS\.md exceeds its budget' (
        'The validator accepted an oversized AGENTS.md.')

    $missingApplyTo = Join-Path $temporaryRoot 'missing-apply-to'
    Copy-Item -LiteralPath $base -Destination $missingApplyTo -Recurse
    Set-Content `
        -LiteralPath (
            Join-Path $missingApplyTo '.github' 'instructions' 'broken.instructions.md'
        ) `
        -Value "---`n`n---`n`n# Broken`n`napplyTo: `"README.md`"`n" `
        -Encoding utf8NoBOM
    Add-ThrowsCheck {
        & $validator -ProjectRoot $missingApplyTo | Out-Null
    } 'has no applyTo value' (
        'The validator accepted an instruction without applyTo.')
    Add-ThrowsCheck {
        & (
            Join-Path $missingApplyTo `
                'scripts' 'guidance' 'Get-ApplicableInstructions.ps1'
        ) -Path README.md | Out-Null
    } 'has no applyTo value' (
        'The resolver accepted applyTo metadata outside frontmatter.')

    $duplicateApplyTo = Join-Path $temporaryRoot 'duplicate-apply-to'
    Copy-Item -LiteralPath $base -Destination $duplicateApplyTo -Recurse
    Set-Content `
        -LiteralPath (
            Join-Path $duplicateApplyTo '.github' 'instructions' 'duplicate.instructions.md'
        ) `
        -Value (
            "---`napplyTo: `"README.md`"`napplyTo: `"docs/**`"`n---`n`n# Duplicate`n"
        ) `
        -Encoding utf8NoBOM
    Add-ThrowsCheck {
        & $validator -ProjectRoot $duplicateApplyTo | Out-Null
    } 'appears multiple times' (
        'The validator accepted duplicate instruction metadata.')

    $brokenLink = Join-Path $temporaryRoot 'broken-link'
    Copy-Item -LiteralPath $base -Destination $brokenLink -Recurse
    Add-Content -LiteralPath (Join-Path $brokenLink 'docs' 'index.md') `
        -Value '[Missing](missing-page.md)'
    Add-ThrowsCheck {
        & $validator -ProjectRoot $brokenLink | Out-Null
    } 'does not resolve' (
        'The validator accepted a broken relative documentation link.')

    $contextBudget = Join-Path $temporaryRoot 'context-budget'
    Copy-Item -LiteralPath $base -Destination $contextBudget -Recurse
    $largeBody = 1..320 | ForEach-Object { "Rule $_" }
    @(
        '---'
        'applyTo: "README.md"'
        'reviewThresholdReason: "Controlled matched-context negative fixture."'
        '---'
        ''
        '# Oversized Context'
        ''
        $largeBody
    ) | Set-Content `
        -LiteralPath (
            Join-Path $contextBudget '.github' 'instructions' 'oversized.instructions.md'
        ) `
        -Encoding utf8NoBOM
    Add-ThrowsCheck {
        & $validator -ProjectRoot $contextBudget | Out-Null
    } 'exceeds its matched-context target' (
        'The validator accepted excessive matched instruction context.')

    $managedOwnership = Join-Path $temporaryRoot 'managed-ownership'
    Copy-Item -LiteralPath $base -Destination $managedOwnership -Recurse
    $managedPath = Join-Path $managedOwnership `
        '.github' 'instructions' 'genesis' 'managed.instructions.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $managedPath) `
        -Force | Out-Null
    Set-Content -LiteralPath $managedPath `
        -Value "---`napplyTo: `"README.md`"`n---`n`n# Managed`n" `
        -Encoding utf8NoBOM
    Add-ThrowsCheck {
        & $validator -ProjectRoot $managedOwnership | Out-Null
    } 'managedInstalled is false' (
        'The validator accepted an undeclared managed instruction subtree.')

    $nestedRepository = Join-Path $temporaryRoot 'nested-repository'
    Copy-Item -LiteralPath $base -Destination $nestedRepository -Recurse
    $foreignRoot = Join-Path $nestedRepository '.copilot-worktrees' 'foreign'
    New-Item -ItemType Directory -Path (
        Join-Path $foreignRoot 'foreign-only'
    ) -Force | Out-Null
    Set-Content -LiteralPath (
        Join-Path $foreignRoot 'foreign-only' 'match.txt'
    ) -Value 'foreign' -Encoding utf8NoBOM
    Set-Content -LiteralPath (
        Join-Path $nestedRepository '.github' 'instructions' 'foreign.instructions.md'
    ) -Value (
        "---`napplyTo: `"foreign-only/**`"`n---`n`n# Foreign`n"
    ) -Encoding utf8NoBOM
    Add-ThrowsCheck {
        & $validator -ProjectRoot $nestedRepository | Out-Null
    } 'does not match a current repository file' (
        'A nested worktree file satisfied a project instruction match.')

    $nestedGitRoot = Join-Path $nestedRepository 'nested-repository'
    New-Item -ItemType Directory -Path (
        Join-Path $nestedGitRoot 'tests'
    ) -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $nestedGitRoot '.git') `
        -Value 'gitdir: elsewhere' -Encoding utf8NoBOM
    Set-Content -LiteralPath (
        Join-Path $nestedGitRoot 'tests' 'Test-Foreign.ps1'
    ) -Value '# foreign' -Encoding utf8NoBOM
    $nestedInventory = & $inventoryScript -ProjectRoot $nestedRepository
    Add-Check (
        @(
            $nestedInventory.powershellTests |
                Where-Object { $_ -match 'Foreign' }
        ).Count -eq 0
    ) 'Validation inventory included a nested Git repository.'
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

if ($errors.Count -gt 0) {
    throw "Guidance tests failed after $checks checks:`n$($errors -join "`n")"
}

Write-Host "Guidance tests passed: $checks checks."
