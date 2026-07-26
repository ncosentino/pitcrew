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
Add-Check ($plugin.version -eq '1.6.0') 'The operations plugin version was not advanced for profile recovery.'
Add-Check ($plugin.skills -eq 'skills/') 'The plugin manifest does not expose its skills directory.'
Add-Check ($plugin.license -eq 'MIT') 'The plugin manifest license is incorrect.'

$expectedSkills = @(
    'pitcrew-capacity',
    'pitcrew-dashboard-update',
    'pitcrew-host-diagnostics',
    'pitcrew-pool-update',
    'pitcrew-profile-recover'
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

$dashboardUpdateSkill = Get-Content `
    -LiteralPath (Join-Path $skillsRoot 'pitcrew-dashboard-update' 'SKILL.md') `
    -Raw `
    -Encoding UTF8
Add-Check (
    $dashboardUpdateSkill -match 'Enable-PitCrewCapacityOperations\.ps1'
) 'The dashboard update skill does not invoke the capacity-operations installer.'
Add-Check (
    $dashboardUpdateSkill -match 'restores the connector container if service startup fails'
) 'The dashboard update skill omits connector migration rollback.'
Add-Check (
    $dashboardUpdateSkill -match 'win-x64' -and
    $dashboardUpdateSkill -match 'win-arm64'
) 'The dashboard update skill does not require Windows connector release assets.'
Add-Check (
    $dashboardUpdateSkill -match 'Get-Service PitCrewConnector' -and
    $dashboardUpdateSkill -match 'requests UAC\s+elevation' -and
    $dashboardUpdateSkill -match 'explicit result'
) 'The dashboard update skill does not automate or verify Windows Service installation.'
Add-Check (
    $dashboardUpdateSkill -match 'Do not manually copy credentials'
) 'The dashboard update skill still delegates identity migration to the user.'

$hostDiagnosticsSkill = Get-Content `
    -LiteralPath (Join-Path $skillsRoot 'pitcrew-host-diagnostics' 'SKILL.md') `
    -Raw `
    -Encoding UTF8
Add-Check (
    $hostDiagnosticsSkill -match '(?m)^## Dry-run mode' -and
    $hostDiagnosticsSkill -match 'Create no container, download nothing, and change nothing\.'
) 'The host diagnostics skill has no state-preserving dry-run mode.'
foreach ($requiredLabel in @(
        'label=ephemeral-runner-manager-profile=<profile>',
        'label=ephemeral-managed-runner-profile=<profile>',
        'ephemeral-managed-runner-slot',
        'pitcrew-worker-revision')) {
    Add-Check (
        $hostDiagnosticsSkill -match [regex]::Escape($requiredLabel)
    ) "The host diagnostics skill does not filter Docker queries by the exact label '$requiredLabel'."
}
Add-Check (
    $hostDiagnosticsSkill -match 'docker image inspect' -and
    $hostDiagnosticsSkill -match 'RepoDigests'
) 'The host diagnostics skill does not resolve exact local image IDs and digests.'
Add-Check (
    $hostDiagnosticsSkill -match 'docker stats --no-stream' -and
    $hostDiagnosticsSkill -match '\{\{\.PIDs\}\}' -and
    $hostDiagnosticsSkill -match '\{\{\.NetIO\}\}' -and
    $hostDiagnosticsSkill -match '\{\{\.BlockIO\}\}' -and
    $hostDiagnosticsSkill -match 'Never run `docker stats` without `--no-stream`'
) 'The host diagnostics skill does not capture bounded docker stats evidence.'
Add-Check (
    $hostDiagnosticsSkill -match 'docker system df' -and
    $hostDiagnosticsSkill -match 'docker network ls'
) 'The host diagnostics skill omits Docker disk and network inventory evidence.'
Add-Check (
    $hostDiagnosticsSkill -match 'df -P <docker-root>' -and
    $hostDiagnosticsSkill -match 'df -Pi <docker-root>' -and
    $hostDiagnosticsSkill -match '/proc/net/dev' -and
    $hostDiagnosticsSkill -match 'Get-PSDrive -PSProvider FileSystem' -and
    $hostDiagnosticsSkill -match 'Get-NetAdapterStatistics' -and
    $hostDiagnosticsSkill -match 'curl\.exe'
) 'The host diagnostics skill does not select Windows and Linux host commands.'
Add-Check (
    $hostDiagnosticsSkill -match 'Never fabricate, estimate, or interpolate an unsupported measurement\.' -and
    $hostDiagnosticsSkill -match 'unavailable \(NTFS has no inode budget\)'
) 'The host diagnostics skill does not report unsupported measurements as unavailable.'
Add-Check (
    $hostDiagnosticsSkill -match 'Validate each URL before use' -and
    $hostDiagnosticsSkill -match 'the scheme is `http` or `https`' -and
    $hostDiagnosticsSkill -match 'no embedded credentials' -and
    $hostDiagnosticsSkill -match 'explicitly approved'
) 'The host diagnostics skill does not validate caller-approved URLs.'
Add-Check (
    $hostDiagnosticsSkill -match 'docker run --rm --cidfile <run-scoped-cidfile> --name pitcrew-diagnostics-' -and
    $hostDiagnosticsSkill -match 'label pitcrew-diagnostics-session=<session-id>' -and
    $hostDiagnosticsSkill -match 'Persist nothing that was downloaded\.'
) 'The host diagnostics skill does not time URLs from one disposable, non-persisting container.'
Add-Check (
    $hostDiagnosticsSkill -match '--cidfile' -and
    $hostDiagnosticsSkill -match '`docker create` . capture the printed ID . `docker start --attach`' -and
    $hostDiagnosticsSkill -notmatch 'Capture the container name and ID at creation'
) 'The host diagnostics skill does not make disposable-container identity provable client-side.'
Add-Check (
    $hostDiagnosticsSkill -match 'docker rm --force <exact-diagnostic-container-id>' -and
    $hostDiagnosticsSkill -match 'docker inspect <exact-diagnostic-container-id> --format' -and
    $hostDiagnosticsSkill -match 'Never clean up by name pattern'
) 'The host diagnostics skill does not restrict cleanup to the exact container it created.'
Add-Check (
    $hostDiagnosticsSkill -notmatch '--max-time 30\b' -and
    $hostDiagnosticsSkill -match '--max-time <probe-timeout-seconds>' -and
    $hostDiagnosticsSkill -match 'default of 300 seconds' -and
    $hostDiagnosticsSkill -match 'Never hard-code a short'
) 'The host diagnostics skill still hard-codes a short probe timeout.'
Add-Check (
    $hostDiagnosticsSkill -match 'report it as `timed-out` partial evidence' -and
    $hostDiagnosticsSkill -match 'Never record a timed-out probe as zero throughput'
) 'The host diagnostics skill does not report timed-out probes as partial evidence.'
Add-Check (
    $hostDiagnosticsSkill -match '--write-out "%\{http_code\} %\{remote_ip\} %\{time_namelookup\} %\{time_connect\} %\{time_appconnect\} %\{time_starttransfer\} %\{time_total\} %\{size_download\} %\{speed_download\}'
) 'The host diagnostics skill does not capture CDN edge and TLS handshake timing.'
Add-Check (
    $hostDiagnosticsSkill -match '(?m)^### Paired snapshots and deltas' -and
    $hostDiagnosticsSkill -match 'immediately before the URL probes and a\s+second immediately after' -and
    $hostDiagnosticsSkill -match '`NetIO` and `BlockIO` delta' -and
    $hostDiagnosticsSkill -match 'adapter error and drop counter deltas' -and
    $hostDiagnosticsSkill -match '`docker system df` delta' -and
    $hostDiagnosticsSkill -match 'report the delta as\s+unavailable instead of treating the missing side as zero'
) 'The host diagnostics skill does not capture paired before/after resource deltas.'
Add-Check (
    $hostDiagnosticsSkill -match '(?m)^### Per-worker writable layer' -and
    $hostDiagnosticsSkill -match 'docker inspect --size <exact-container-id>' -and
    $hostDiagnosticsSkill -match '\{\{\.SizeRw\}\}' -and
    $hostDiagnosticsSkill -match 'Include `SizeRootFs` only when' -and
    $hostDiagnosticsSkill -match 'never inspect every container on the\s+host'
) 'The host diagnostics skill does not capture exact-ID per-worker writable-layer evidence.'
Add-Check (
    $hostDiagnosticsSkill -match '(?m)^## Capacity reconciliation evidence' -and
    $hostDiagnosticsSkill -match 'live worker containers counted above' -and
    $hostDiagnosticsSkill -match 'autoscaling\.targetSlots' -and
    $hostDiagnosticsSkill -match '`observedAt` freshness' -and
    $hostDiagnosticsSkill -match 'Never make a credentialed GitHub API query'
) 'The host diagnostics skill does not compare live worker counts with registered capacity.'
Add-Check (
    $hostDiagnosticsSkill -match 'A single host-versus-container pair never establishes a root cause\.' -and
    $hostDiagnosticsSkill -match 'CDN edge and route variability' -and
    $hostDiagnosticsSkill -match 'load-sensitive host contention' -and
    $hostDiagnosticsSkill -match 'single paired sample'
) 'The host diagnostics skill infers a root cause from one host/container pair.'
Add-Check (
    $hostDiagnosticsSkill -match 'absolute host paths, replaced with `<pitcrew-root>`' -and
    $hostDiagnosticsSkill -match 'any URL query string' -and
    $hostDiagnosticsSkill -match 'JIT\s+configuration'
) 'The host diagnostics skill does not redact its handoff report.'
Add-Check (
    $hostDiagnosticsSkill -match '\*\*Verified measurements\*\*' -and
    $hostDiagnosticsSkill -match '\*\*Unavailable evidence\*\*' -and
    $hostDiagnosticsSkill -match '\*\*Hypotheses\*\*'
) 'The host diagnostics report does not separate measurements from unavailable evidence and hypotheses.'
Add-Check (
    $hostDiagnosticsSkill -match 'Never restart Docker' -and
    $hostDiagnosticsSkill -match 'Never run `docker system prune`' -and
    $hostDiagnosticsSkill -match 'Never enter a running worker with `docker exec`'
) 'The host diagnostics skill does not forbid destructive host operations.'

$profileRecoverSkill = Get-Content `
    -LiteralPath (Join-Path $skillsRoot 'pitcrew-profile-recover' 'SKILL.md') `
    -Raw `
    -Encoding UTF8
$recoveryReferencePath = Join-Path $pluginRoot 'references' 'manager-recovery.md'
Add-Check (
    Test-Path -LiteralPath $recoveryReferencePath -PathType Leaf
) 'The manager-only recovery reference is missing.'
$recoveryReference = if (Test-Path -LiteralPath $recoveryReferencePath -PathType Leaf) {
    Get-Content -LiteralPath $recoveryReferencePath -Raw -Encoding UTF8
} else {
    ''
}

foreach ($requiredReference in @(
        '../../references/safety.md',
        '../../references/profile-replay.md',
        '../../references/manager-recovery.md')) {
    Add-Check (
        $profileRecoverSkill -match [regex]::Escape($requiredReference)
    ) "The profile recovery skill does not read '$requiredReference'."
}

function Get-SkillCommandLine {
    param([string]$Content)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($block in [regex]::Matches($Content, '(?ms)^\s*```[a-z]*\r?\n(?<body>.*?)^\s*```')) {
        foreach ($line in ($block.Groups['body'].Value -split '\r?\n')) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $lines.Add($line.Trim())
            }
        }
    }
    return @($lines)
}

$forbiddenCommandPattern =
    '(?i)(compose\s+down|docker\s+(stop|kill|rm|exec|pause|start|restart|prune|build|pull|update|system|compose)|prune|Restart-Service|Restart-Computer|Stop-Computer|shutdown\s|-Down\b|--force)'
$recoverCommandLines = @(Get-SkillCommandLine -Content $profileRecoverSkill)
$recoveryReferenceCommandLines = @(Get-SkillCommandLine -Content $recoveryReference)
Add-Check ($recoverCommandLines.Count -gt 0) 'The profile recovery skill prints no resolved commands.'
Add-Check (
    -not (@($recoverCommandLines) | Where-Object { $_ -match $forbiddenCommandPattern })
) 'The profile recovery skill contains a destructive command.'
Add-Check (
    -not (@($recoveryReferenceCommandLines) | Where-Object { $_ -match $forbiddenCommandPattern })
) 'The manager-only recovery reference contains a destructive command.'

$recoverDockerLines = @($recoverCommandLines | Where-Object { $_ -match '^docker\s' })
Add-Check ($recoverDockerLines.Count -gt 0) 'The profile recovery skill collects no Docker evidence.'
Add-Check (
    -not (
        @($recoverDockerLines) |
            Where-Object {
                $_ -notmatch 'label=ephemeral-runner-manager-profile=<profile>' -and
                $_ -notmatch 'label=ephemeral-managed-runner-profile=<profile>' -and
                $_ -notmatch 'docker inspect <exact-manager-id>'
            }
    )
) 'The profile recovery skill queries Docker outside exact PitCrew labels and the exact manager ID.'
Add-Check (
    -not (@($recoverDockerLines) | Where-Object { $_ -notmatch '^docker (ps|inspect)\s' })
) 'The profile recovery skill runs a Docker command that is not read-only.'

$recoverSetupLines = @(
    @($recoverCommandLines) + @($recoveryReferenceCommandLines) |
        Where-Object { $_ -match 'Setup-Runner\.ps1' }
)
Add-Check (
    $recoverSetupLines.Count -eq 2
) 'The recovery surface does not publish exactly one supported invocation per document.'
Add-Check (
    -not (
        @($recoverSetupLines) |
            Where-Object {
                $_ -notmatch '-RecoverManager' -or
                $_ -notmatch '-ExpectedManagerInstanceId' -or
                $_ -notmatch '-ExpectedGeneration'
            }
    )
) 'The recovery surface invokes Setup-Runner.ps1 without the first-class recovery operation and its fences.'

Add-Check (
    $profileRecoverSkill -match '(?m)^## Dry-run mode' -and
    $profileRecoverSkill -match 'Change nothing during the dry run\.' -and
    $profileRecoverSkill -match '(?m)^## Explicit confirmation' -and
    $profileRecoverSkill -match 'never approval to restart a manager'
) 'The profile recovery skill does not gate recovery behind a dry run and explicit confirmation.'
Add-Check (
    $profileRecoverSkill -match 'An omitted profile is never permission to' -and
    $profileRecoverSkill -match 'stop and ask which profile to recover'
) 'The profile recovery skill can treat an omitted profile as every profile.'
foreach ($requiredResult in @(
        'recovered',
        'still-degraded',
        'rejected',
        'failed',
        'indeterminate')) {
    Add-Check (
        $profileRecoverSkill -match "``$requiredResult``"
    ) "The profile recovery skill does not report the '$requiredResult' result."
    Add-Check (
        $recoveryReference -match "``$requiredResult``"
    ) "The manager-only recovery reference does not define the '$requiredResult' result."
}
Add-Check (
    $profileRecoverSkill -match '(?m)^## One attempt only' -and
    $profileRecoverSkill -match 'never repeat the\s+recovery on your own initiative'
) 'The profile recovery skill allows an automatic second attempt.'
Add-Check (
    $profileRecoverSkill -match '(?m)^## Multiple profiles' -and
    $profileRecoverSkill -match 'Stop the\s+whole batch after the first'
) 'The profile recovery skill does not stop a batch after an unsafe result.'
Add-Check (
    $profileRecoverSkill -match '(?m)^## Redaction' -and
    $profileRecoverSkill -match '<pitcrew-root>' -and
    $profileRecoverSkill -match 'Never open `\.env`'
) 'The profile recovery skill does not redact its report or forbid credential access.'
Add-Check (
    $profileRecoverSkill -match 'manager contract is below 9' -and
    $profileRecoverSkill -match 'manager-shutdown\.json' -and
    $profileRecoverSkill -match 'zero or more than one container'
) 'The profile recovery skill does not fail closed on contract, shutdown request, or ambiguous manager identity.'
Add-Check (
    $profileRecoverSkill -match 'finished its ephemeral job' -and
    $profileRecoverSkill -match 'never describe such an exit as a worker that\s+recovery stopped'
) 'The profile recovery skill can misreport a naturally completed worker as killed by recovery.'

$setupRunnerContent = Get-Content `
    -LiteralPath (Join-Path $root 'Setup-Runner.ps1') `
    -Raw `
    -Encoding UTF8
Add-Check (
    $setupRunnerContent -match '\[switch\]\$RecoverManager' -and
    $setupRunnerContent -match '(?m)^\.PARAMETER RecoverManager' -and
    $setupRunnerContent -match '(?m)^\.PARAMETER ExpectedManagerInstanceId' -and
    $setupRunnerContent -match '(?m)^\.PARAMETER ExpectedGeneration' -and
    $setupRunnerContent -match '(?m)^\.PARAMETER ExpectedDesiredStateHash' -and
    $setupRunnerContent -match '(?m)^\.PARAMETER RecoveryTimeoutSeconds'
) 'Setup-Runner.ps1 does not document the first-class manager recovery operation the skill invokes.'

if ($errors.Count -gt 0) {
    foreach ($errorMessage in $errors) {
        Write-Host "ERROR: $errorMessage" -ForegroundColor Red
    }
    throw "Copilot plugin validation failed with $($errors.Count) error(s)."
}

Write-Host "Copilot plugin validation passed: $checks assertions." -ForegroundColor Green
