#Requires -Version 7.0
<#
.SYNOPSIS
    Inventory PitCrew validation and delivery surfaces.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

function Get-RelativePath {
    param([string]$Path)
    return [IO.Path]::GetRelativePath($ProjectRoot, $Path).Replace('\', '/')
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

$files = @(Get-ProjectFiles)
$workflows = @(
    $files |
        Where-Object {
            $_.FullName -match '[\\/]\.github[\\/]workflows[\\/].+\.ya?ml$'
        } |
        Sort-Object FullName |
        ForEach-Object {
            $content = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
            $nameMatch = [regex]::Match($content, '(?m)^name:\s*(.+?)\s*$')
            [PSCustomObject]@{
                path = Get-RelativePath $_.FullName
                name = if ($nameMatch.Success) {
                    $nameMatch.Groups[1].Value.Trim("'`"")
                } else {
                    $_.BaseName
                }
            }
        }
)

$deliveryPath = Join-Path $ProjectRoot '.github' 'genesis-delivery.json'
$inventory = [PSCustomObject]@{
    projectRoot = $ProjectRoot
    powershellTests = @(
        $files |
            Where-Object {
                $_.FullName -match '[\\/]tests[\\/]Test-.+\.ps1$'
            } |
            Sort-Object FullName |
            ForEach-Object { Get-RelativePath $_.FullName }
    )
    shellTests = @(
        $files |
            Where-Object {
                $_.FullName -match '[\\/]tests[\\/].*Test-.+\.sh$'
            } |
            Sort-Object FullName |
            ForEach-Object { Get-RelativePath $_.FullName }
    )
    shellSources = @(
        $files |
            Where-Object {
                $_.FullName -match '[\\/]manager[\\/].+\.sh$'
            } |
            Sort-Object FullName |
            ForEach-Object { Get-RelativePath $_.FullName }
    )
    goModules = @(
        $files |
            Where-Object Name -CEQ 'go.mod' |
            Sort-Object FullName |
            ForEach-Object { Get-RelativePath $_.FullName }
    )
    dockerComposeFiles = @(
        $files |
            Where-Object Name -CEQ 'docker-compose.yml' |
            Sort-Object FullName |
            ForEach-Object { Get-RelativePath $_.FullName }
    )
    dockerfiles = @(
        $files |
            Where-Object Name -CEQ 'Dockerfile' |
            Sort-Object FullName |
            ForEach-Object { Get-RelativePath $_.FullName }
    )
    documentation = [PSCustomObject]@{
        config = if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'mkdocs.yml')) {
            'mkdocs.yml'
        } else {
            $null
        }
        requirements = if (
            Test-Path -LiteralPath (Join-Path $ProjectRoot 'requirements-docs.txt')
        ) {
            'requirements-docs.txt'
        } else {
            $null
        }
        hooks = @(
            $files |
                Where-Object {
                    $_.FullName -match '[\\/]docs[\\/]hooks[\\/].+\.py$'
                } |
                Sort-Object FullName |
                ForEach-Object { Get-RelativePath $_.FullName }
        )
    }
    workflows = $workflows
    delivery = if (Test-Path -LiteralPath $deliveryPath -PathType Leaf) {
        Get-Content -LiteralPath $deliveryPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
    } else {
        $null
    }
}

if ($Json) {
    $inventory | ConvertTo-Json -Depth 12
} else {
    $inventory
}
