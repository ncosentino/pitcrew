#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,

    [Parameter(Mandatory)]
    [string]$AdmissionProfile,

    [Parameter(Mandatory)]
    [string]$AutoscalerProfile,

    [string]$ChangedFilesPath,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [ValidateRange(1, 25)]
    [int]$LowestCount = 10,

    [ValidateRange(4096, 49152)]
    [int]$MaximumReportBytes = 49152
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$invariantCulture = [Globalization.CultureInfo]::InvariantCulture

function Get-ModulePath {
    param([string]$ModuleRoot)

    $goModPath = Join-Path $ModuleRoot 'go.mod'
    if (-not (Test-Path -LiteralPath $goModPath -PathType Leaf)) {
        throw "Required Go module file '$goModPath' does not exist."
    }

    $moduleLine = Get-Content -LiteralPath $goModPath -Encoding UTF8 |
        Where-Object { $_ -match '^\s*module\s+\S+\s*$' } |
        Select-Object -First 1
    if ($null -eq $moduleLine) {
        throw "Required Go module file '$goModPath' has no module declaration."
    }

    return ([regex]::Match(
            $moduleLine,
            '^\s*module\s+(?<path>\S+)\s*$')).Groups['path'].Value
}

function Get-FunctionCoverage {
    param(
        [string]$ModuleName,
        [string]$ModuleRoot,
        [string]$ModulePath,
        [string]$ProfilePath
    )

    Push-Location $ModuleRoot
    try {
        $output = @(& go tool cover "-func=$ProfilePath" 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "go tool cover failed for required module '$ModuleName': " +
                ($output -join [Environment]::NewLine)
        }
    } finally {
        Pop-Location
    }

    $functions = [Collections.Generic.List[object]]::new()
    foreach ($line in $output) {
        $text = [string]$line
        if ($text -match '^total:\s+\(statements\)\s+\d+(?:\.\d+)?%$') {
            continue
        }

        $match = [regex]::Match(
            $text,
            '^(?<file>.+):(?<line>\d+):\s+(?<name>\S+)\s+' +
            '(?<coverage>\d+(?:\.\d+)?)%$')
        if (-not $match.Success) {
            throw "Malformed go tool cover output for required module " +
                "'$ModuleName': '$text'."
        }

        $file = $match.Groups['file'].Value.Replace('\', '/')
        if (-not $file.StartsWith(
                "$ModulePath/",
                [StringComparison]::Ordinal)) {
            throw "go tool cover returned an unexpected file path for required " +
                "module '$ModuleName'."
        }
        $file = $file.Substring($ModulePath.Length + 1)

        $functions.Add([PSCustomObject][ordered]@{
            Module = $ModuleName
            File = $file
            Line = [int]$match.Groups['line'].Value
            Name = $match.Groups['name'].Value
            Coverage = [decimal]::Parse(
                $match.Groups['coverage'].Value,
                $invariantCulture)
        })
    }

    if ($functions.Count -eq 0) {
        throw "Coverage profile '$ProfilePath' produced no function coverage for " +
            "required module '$ModuleName'."
    }

    return $functions
}

function Read-CoverageProfile {
    param(
        [string]$ModuleName,
        [string]$ModuleRoot,
        [string]$ProfilePath
    )

    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
        throw "Coverage profile '$ProfilePath' does not exist."
    }

    $lines = @(Get-Content -LiteralPath $ProfilePath -Encoding UTF8)
    if ($lines.Count -lt 2 -or $lines[0] -notmatch '^mode: (set|count|atomic)$') {
        throw "Malformed coverage profile '$ProfilePath': missing valid mode or blocks."
    }

    $modulePath = Get-ModulePath -ModuleRoot $ModuleRoot
    $modulePrefix = "$modulePath/"
    $files = @{}
    $coveredStatements = 0L
    $totalStatements = 0L
    $measuredBlocks = 0

    foreach ($line in $lines | Select-Object -Skip 1) {
        $match = [regex]::Match(
            $line,
            '^(?<file>.+):(?<startLine>\d+)\.(?<startColumn>\d+),' +
            '(?<endLine>\d+)\.(?<endColumn>\d+) ' +
            '(?<statements>\d+) (?<count>\d+)$')
        if (-not $match.Success) {
            throw "Malformed coverage profile '$ProfilePath': '$line'."
        }

        $file = $match.Groups['file'].Value.Replace('\', '/')
        if (-not $file.StartsWith($modulePrefix, [StringComparison]::Ordinal)) {
            continue
        }

        $statements = [long]$match.Groups['statements'].Value
        $count = [long]$match.Groups['count'].Value
        $relativeFile = $file.Substring($modulePrefix.Length)
        if (-not $files.ContainsKey($relativeFile)) {
            $files[$relativeFile] = [PSCustomObject][ordered]@{
                Module = $ModuleName
                File = $relativeFile
                CoveredStatements = 0L
                TotalStatements = 0L
            }
        }

        $fileCoverage = $files[$relativeFile]
        $fileCoverage.TotalStatements += $statements
        $totalStatements += $statements
        if ($count -gt 0) {
            $fileCoverage.CoveredStatements += $statements
            $coveredStatements += $statements
        }
        $measuredBlocks++
    }

    if ($measuredBlocks -eq 0 -or $totalStatements -eq 0) {
        throw "Coverage profile '$ProfilePath' did not measure required module " +
            "'$ModuleName' ($modulePath)."
    }

    $functionCoverage = Get-FunctionCoverage `
        -ModuleName $ModuleName `
        -ModuleRoot $ModuleRoot `
        -ModulePath $modulePath `
        -ProfilePath $ProfilePath

    return [PSCustomObject][ordered]@{
        Name = $ModuleName
        CoveredStatements = $coveredStatements
        TotalStatements = $totalStatements
        Files = @($files.Values)
        Functions = @($functionCoverage)
    }
}

function Format-Percentage {
    param(
        [long]$Covered,
        [long]$Total
    )

    if ($Total -le 0) {
        throw 'Coverage percentage requires a positive statement total.'
    }

    return [string]::Format(
        $invariantCulture,
        '{0:F1}%',
        (($Covered * 100.0) / $Total))
}

function Escape-MarkdownCell {
    param([string]$Value)

    return $Value.
        Replace('`', '\`').
        Replace('|', '\|').
        Replace("`r", '').
        Replace("`n", ' ')
}

$resolvedProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$admission = Read-CoverageProfile `
    -ModuleName 'Admission' `
    -ModuleRoot (Join-Path $resolvedProjectRoot 'manager' 'admission') `
    -ProfilePath $AdmissionProfile
$autoscaler = Read-CoverageProfile `
    -ModuleName 'Autoscaler' `
    -ModuleRoot (Join-Path $resolvedProjectRoot 'manager' 'autoscaler') `
    -ProfilePath $AutoscalerProfile
$modules = @($admission, $autoscaler)
$combinedCovered = [long]($modules |
        Measure-Object -Property CoveredStatements -Sum).Sum
$combinedTotal = [long]($modules |
        Measure-Object -Property TotalStatements -Sum).Sum

$lines = [Collections.Generic.List[string]]::new()
$lines.Add('## Go coverage')
$lines.Add('')
$lines.Add('| Module | Covered statements | Statement coverage |')
$lines.Add('| --- | ---: | ---: |')
foreach ($module in $modules) {
    $lines.Add(
        "| $($module.Name) | $($module.CoveredStatements) / " +
        "$($module.TotalStatements) | " +
        "$(Format-Percentage $module.CoveredStatements $module.TotalStatements) |")
}
$lines.Add(
    "| Combined | $combinedCovered / $combinedTotal | " +
    "$(Format-Percentage $combinedCovered $combinedTotal) |")

$fileCoverage = @(
    $modules.Files |
        Where-Object TotalStatements -gt 0 |
        ForEach-Object {
            [PSCustomObject][ordered]@{
                Module = $_.Module
                File = $_.File
                CoveredStatements = $_.CoveredStatements
                TotalStatements = $_.TotalStatements
                Coverage = ($_.CoveredStatements * 100.0) / $_.TotalStatements
            }
        } |
        Sort-Object Coverage, Module, File |
        Select-Object -First $LowestCount
)
$lines.Add('')
$lines.Add("### Lowest-covered Go files (up to $LowestCount)")
$lines.Add('')
$lines.Add('| Module | File | Covered statements | Statement coverage |')
$lines.Add('| --- | --- | ---: | ---: |')
foreach ($file in $fileCoverage) {
    $lines.Add(
        "| $($file.Module) | ``$(Escape-MarkdownCell $file.File)`` | " +
        "$($file.CoveredStatements) / $($file.TotalStatements) | " +
        "$([string]::Format($invariantCulture, '{0:F1}%', $file.Coverage)) |")
}

$functionCoverage = @(
    $modules.Functions |
        Sort-Object Coverage, Module, File, Line, Name |
        Select-Object -First $LowestCount
)
$lines.Add('')
$lines.Add("### Lowest-covered Go functions (up to $LowestCount)")
$lines.Add('')
$lines.Add('| Module | Function | Location | Statement coverage |')
$lines.Add('| --- | --- | --- | ---: |')
foreach ($function in $functionCoverage) {
    $lines.Add(
        "| $($function.Module) | ``$(Escape-MarkdownCell $function.Name)`` | " +
        "``$(Escape-MarkdownCell $function.File):$($function.Line)`` | " +
        "$([string]::Format(
            $invariantCulture,
            '{0:F1}%',
            $function.Coverage)) |")
}

$lines.Add('')
$lines.Add('### Changed Go files')
$lines.Add('')
if ($ChangedFilesPath) {
    if (-not (Test-Path -LiteralPath $ChangedFilesPath -PathType Leaf)) {
        throw "Changed-files input '$ChangedFilesPath' does not exist."
    }

    $changedFiles = @(
        Get-Content -LiteralPath $ChangedFilesPath -Encoding UTF8 |
            ForEach-Object { $_.Trim().Replace('\', '/') } |
            Where-Object {
                $_ -match '^manager/(admission|autoscaler)/.+\.go$'
            } |
            Sort-Object -Unique
    )
    if ($changedFiles.Count -eq 0) {
        $lines.Add('No changed Go files were detected in the measured modules.')
    } else {
        foreach ($changedFile in $changedFiles | Select-Object -First 50) {
            $lines.Add("- ``$(Escape-MarkdownCell $changedFile)``")
        }
        if ($changedFiles.Count -gt 50) {
            $lines.Add("- ... and $($changedFiles.Count - 50) more.")
        }
    }
} else {
    $lines.Add('Changed-file comparison is unavailable for this workflow event.')
}

$lines.Add('')
$lines.Add(
    '**Coverage boundary:** PowerShell and shell coverage is not fabricated. ' +
    'Their normal contract tests remain required and report pass/fail evidence ' +
    'through CI.')
$lines.Add('')
$lines.Add(
    'Coverage profiles remain runner-local and are not uploaded as GitHub artifacts.')
$report = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
$reportBytes = [Text.Encoding]::UTF8.GetByteCount($report)
if ($reportBytes -gt $MaximumReportBytes) {
    throw "Coverage report is $reportBytes bytes, exceeding the " +
        "$MaximumReportBytes-byte job-output limit."
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
[IO.File]::WriteAllText(
    $OutputPath,
    $report,
    [Text.UTF8Encoding]::new($false))
