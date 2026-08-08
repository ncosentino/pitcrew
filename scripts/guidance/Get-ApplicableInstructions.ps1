#Requires -Version 7.0
<#
.SYNOPSIS
    Resolve project instruction files that apply to repository-relative paths.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Path,

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$AdditionalPath = @(),

    [string]$InstructionsRoot
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
. (Join-Path $PSScriptRoot 'InstructionGlob.Functions.ps1')
if (-not $InstructionsRoot) {
    $InstructionsRoot = Join-Path $projectRoot '.github' 'instructions'
}
if (-not (Test-Path $InstructionsRoot -PathType Container)) {
    Write-Error "Instruction root not found at '$InstructionsRoot'."
}
$InstructionsRoot = (Resolve-Path $InstructionsRoot).Path

function Test-InstructionMatch {
    param(
        [string]$InstructionPath,
        [string]$RelativePath
    )

    $content = Get-Content $InstructionPath -Raw -Encoding UTF8
    $frontmatterMatch = [regex]::Match(
        $content,
        '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|$)',
        [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $frontmatterMatch.Success) {
        Write-Error "Instruction file '$InstructionPath' has invalid frontmatter."
    }
    $applyToMatches = [regex]::Matches(
        $frontmatterMatch.Groups['frontmatter'].Value,
        '(?m)^\s*applyTo\s*:\s*(.+?)\s*$')
    if ($applyToMatches.Count -eq 0) {
        Write-Error "Instruction file '$InstructionPath' has no applyTo value."
    }
    if ($applyToMatches.Count -gt 1) {
        Write-Error "Instruction file '$InstructionPath' has duplicate applyTo values."
    }
    $applyTo = $applyToMatches[0].Groups[1].Value.Trim().Trim('"', "'")
    return Test-InstructionGlobMatch `
        -ApplyTo $applyTo `
        -RelativePath $RelativePath
}

$instructions = @(
    Get-ChildItem $InstructionsRoot -Recurse -Filter '*.instructions.md' -File |
        Sort-Object FullName
)
$normalizedPaths = @(
    @($Path) + @($AdditionalPath) |
        ForEach-Object { ([string]$_) -split ',' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() } |
        Sort-Object -CaseSensitive -Unique
)
foreach ($candidate in $normalizedPaths) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        Write-Error 'Repository-relative paths must not be empty.'
    }
    if (
        [IO.Path]::IsPathRooted($candidate) -or
        $candidate -match '^[A-Za-z]:[\\/]'
    ) {
        Write-Error "Path '$candidate' must be repository-relative."
    }

    $normalized = $candidate.Replace('\', '/')
    while ($normalized.StartsWith('./', [StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }
    $normalized = $normalized.TrimStart('/')
    if (
        [string]::IsNullOrWhiteSpace($normalized) -or
        $normalized -eq '.' -or
        $normalized.Split('/') -contains '..'
    ) {
        Write-Error "Path '$candidate' must identify a file inside the repository."
    }

    foreach ($instruction in $instructions) {
        if (Test-InstructionMatch $instruction.FullName $normalized) {
            [PSCustomObject]@{
                Path = $normalized
                InstructionPath = [IO.Path]::GetRelativePath(
                    $projectRoot,
                    $instruction.FullName
                ).Replace('\', '/')
            }
        }
    }
}
