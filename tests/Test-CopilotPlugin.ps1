#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$marketplacePath = Join-Path $root '.github' 'plugin' 'marketplace.json'
$pluginRoot = Join-Path $root 'plugins' 'pitcrew-operations'
$pluginPath = Join-Path $pluginRoot 'plugin.json'
$skillsRoot = Join-Path $pluginRoot 'skills'
$errors = [System.Collections.Generic.List[string]]::new()
$checks = 0

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

foreach ($path in @($marketplacePath, $pluginPath, $skillsRoot)) {
    Add-Check (Test-Path -LiteralPath $path) "Required plugin surface is missing: $path"
}
if ($errors.Count -gt 0) {
    throw "Copilot plugin validation could not start:`n$($errors -join "`n")"
}

$marketplace = Get-Content -LiteralPath $marketplacePath -Raw -Encoding UTF8 |
    ConvertFrom-Json -Depth 20
$plugin = Get-Content -LiteralPath $pluginPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -Depth 20

Add-Check ($marketplace.name -eq 'pitcrew') 'The marketplace name is not pitcrew.'
Add-Check ($marketplace.owner.name) 'The marketplace owner is missing.'
Add-Check (@($marketplace.plugins).Count -eq 1) 'The marketplace must publish exactly one PitCrew operations plugin.'
$marketplacePlugin = @($marketplace.plugins)[0]
Add-Check ($marketplacePlugin.name -eq 'pitcrew-operations') 'The marketplace plugin name is incorrect.'
Add-Check ($marketplacePlugin.source -eq './plugins/pitcrew-operations') 'The marketplace plugin source is incorrect.'
Add-Check ($marketplacePlugin.version -eq $plugin.version) 'Marketplace and plugin versions do not match.'
Add-Check ($marketplace.metadata.version -eq $plugin.version) 'Marketplace metadata and plugin versions do not match.'

Add-Check ($plugin.name -eq 'pitcrew-operations') 'The plugin manifest name is incorrect.'
Add-Check ($plugin.version -eq '1.1.0') 'The operations plugin version was not advanced for the autoscaling skill update.'
Add-Check ($plugin.skills -eq 'skills/') 'The plugin manifest does not expose its skills directory.'
Add-Check ($plugin.license -eq 'MIT') 'The plugin manifest license is incorrect.'

$expectedSkills = @(
    'pitcrew-capacity',
    'pitcrew-dashboard-update',
    'pitcrew-pool-update'
)
$skillDirectories = @(
    Get-ChildItem -LiteralPath $skillsRoot -Directory |
        Sort-Object Name
)
Add-Check (
    (@($skillDirectories.Name) -join ',') -eq ($expectedSkills -join ',')
) 'The operations plugin skill set changed unexpectedly.'

foreach ($skillDirectory in $skillDirectories) {
    $skillPath = Join-Path $skillDirectory.FullName 'SKILL.md'
    Add-Check (Test-Path -LiteralPath $skillPath -PathType Leaf) "Skill '$($skillDirectory.Name)' has no SKILL.md."
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        continue
    }

    $content = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
    $frontmatterMatch = [regex]::Match(
        $content,
        '\A---\r?\n(?<frontmatter>.*?)\r?\n---\r?\n',
        [Text.RegularExpressions.RegexOptions]::Singleline)
    Add-Check $frontmatterMatch.Success "Skill '$($skillDirectory.Name)' has invalid YAML frontmatter boundaries."
    if (-not $frontmatterMatch.Success) {
        continue
    }

    $frontmatter = $frontmatterMatch.Groups['frontmatter'].Value
    $nameMatch = [regex]::Match($frontmatter, '(?m)^name:\s*(?<value>[a-z0-9-]+)\s*$')
    $descriptionMatch = [regex]::Match($frontmatter, '(?m)^description:\s*(?<value>.+?)\s*$')
    Add-Check (
        $nameMatch.Success -and
        $nameMatch.Groups['value'].Value -eq $skillDirectory.Name
    ) "Skill '$($skillDirectory.Name)' frontmatter name does not match its directory."
    Add-Check (
        $descriptionMatch.Success -and
        $descriptionMatch.Groups['value'].Value.Length -ge 40
    ) "Skill '$($skillDirectory.Name)' has no useful description."
    Add-Check (
        $frontmatter -notmatch '(?m)^allowed-tools:'
    ) "Skill '$($skillDirectory.Name)' pre-approves command execution."

    foreach ($linkMatch in [regex]::Matches($content, '\]\((?<path>\.\./\.\./references/[^)]+\.md)\)')) {
        $referencePath = Join-Path $skillDirectory.FullName $linkMatch.Groups['path'].Value
        Add-Check (
            Test-Path -LiteralPath $referencePath -PathType Leaf
        ) "Skill '$($skillDirectory.Name)' references a missing file: $referencePath"
    }
}

if ($errors.Count -gt 0) {
    foreach ($errorMessage in $errors) {
        Write-Host "ERROR: $errorMessage" -ForegroundColor Red
    }
    throw "Copilot plugin validation failed with $($errors.Count) error(s)."
}

Write-Host "Copilot plugin validation passed: $checks assertions." -ForegroundColor Green
