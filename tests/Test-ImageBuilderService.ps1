#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$serviceRoot = Join-Path $root 'services' 'image-builder'
$certificateScript = Join-Path $serviceRoot 'New-PitCrewBuildKitCertificates.ps1'
$setupScript = Join-Path $serviceRoot 'Setup-PitCrewImageBuilderService.ps1'
$composePath = Join-Path $serviceRoot 'docker-compose.yml'
$configPath = Join-Path $serviceRoot 'buildkitd.toml'
$profilePath = Join-Path $root 'profiles' 'image-builder' 'profile.json'
$dockerfilePath = Join-Path $root 'profiles' 'image-builder' 'Dockerfile'
$helperPath = Join-Path $root 'profiles' 'image-builder' 'pitcrew-build-image'
$candidateSchemaPath = Join-Path $root 'image-candidate.schema.json'
$candidateValidatorPath = Join-Path $root 'scripts' 'Test-PitCrewImageCandidate.ps1'
$integrationPath = Join-Path `
    $root `
    'tests' `
    'integration' `
    'Test-IsolatedImageBuilder.sh'
$attributesPath = Join-Path $root '.gitattributes'

$errors = [Collections.Generic.List[string]]::new()
$checks = 0

function Add-Check {
    param([object]$Condition, [string]$Failure)
    $script:checks++
    if (-not [bool]$Condition) {
        $script:errors.Add($Failure)
    }
}

function Add-ThrowsCheck {
    param([scriptblock]$Action, [string]$ExpectedMessage, [string]$Failure)
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

foreach ($path in @(
        $certificateScript,
        $setupScript,
        $composePath,
        $configPath,
        $profilePath,
        $dockerfilePath,
        $helperPath,
        $candidateSchemaPath,
        $candidateValidatorPath,
        $integrationPath,
        $attributesPath)) {
    Add-Check (Test-Path -LiteralPath $path -PathType Leaf) "Required image-builder surface is missing: $path"
}
if ($errors.Count) {
    throw "Image-builder service tests could not start:`n$($errors -join "`n")"
}

$compose = Get-Content -LiteralPath $composePath -Raw -Encoding UTF8
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
$setup = Get-Content -LiteralPath $setupScript -Raw -Encoding UTF8
$dockerfile = Get-Content -LiteralPath $dockerfilePath -Raw -Encoding UTF8
$helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8
$integration = Get-Content `
    -LiteralPath $integrationPath `
    -Raw `
    -Encoding UTF8
$helperBytes = [IO.File]::ReadAllBytes($helperPath)
$attributes = Get-Content -LiteralPath $attributesPath -Raw -Encoding UTF8
$profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 |
    ConvertFrom-Json -Depth 20

Add-Check (
    $compose -match 'moby/buildkit:v0\.32\.2-rootless@sha256:[0-9a-f]{64}'
) 'Service Compose does not pin the rootless BuildKit image.'
foreach ($option in @(
        'seccomp=unconfined',
        'apparmor=unconfined',
        'systempaths=unconfined')) {
    Add-Check ($compose -match [regex]::Escape($option)) "Service Compose omits '$option'."
}
Add-Check ($compose -notmatch '(?m)^\s*privileged\s*:|/var/run/docker\.sock') 'Service Compose exposes broad Docker host control.'
Add-Check ($compose -notmatch '(?m)^\s*ports\s*:') 'Service Compose publishes a host port.'
Add-Check ($compose -match 'external:\s+true') 'Service Compose does not preserve external network and volume identities.'
Add-Check ($compose -match 'mem_limit: \$\{PITCREW_IMAGE_BUILDER_MEMORY_LIMIT:-8g\}') 'Service Compose does not bound memory by default.'
Add-Check ($compose -match 'memswap_limit: \$\{PITCREW_IMAGE_BUILDER_MEMORY_SWAP_LIMIT:-8g\}') 'Service Compose does not prevent unbounded swap.'
Add-Check ($compose -match 'cpus: \$\{PITCREW_IMAGE_BUILDER_CPU_LIMIT:-4\}') 'Service Compose does not bound CPU by default.'
Add-Check ($compose -match 'pids_limit: \$\{PITCREW_IMAGE_BUILDER_PIDS_LIMIT:-4096\}') 'Service Compose does not bound processes by default.'
Add-Check ($config -match 'root = "/home/user/\.local/share/buildkit"') 'BuildKit state is not rooted in the rootless user directory.'
Add-Check ($config -match 'rootless = true') 'BuildKit OCI worker is not explicitly rootless.'
Add-Check ($config -match 'noProcessSandbox = false') 'BuildKit process isolation is not explicitly retained.'
Add-Check ($config -match 'allowedRepositories = \[ "docker\.io/docker/dockerfile" \]') 'BuildKit gateway frontend is not restricted to the Dockerfile frontend.'
Add-Check ($setup -match 'HostConfig\.Privileged') 'Service setup does not verify the non-privileged boundary.'
Add-Check ($setup -match 'SecurityOpt') 'Service setup does not verify exact security options.'
Add-Check (
    $setup -match 'MaskedPaths' -and $setup -match 'ReadonlyPaths'
) 'Service setup does not verify systempaths=unconfined through Docker inspect.'
Add-Check (
    $setup -match 'HostConfig\.Memory' -and
    $setup -match 'HostConfig\.MemorySwap' -and
    $setup -match 'HostConfig\.NanoCpus' -and
    $setup -match 'HostConfig\.PidsLimit'
) 'Service setup does not verify effective resource ceilings.'
Add-Check ($setup -match 'pitcrew-image-builder-certs-\$\(\$certificateSha256\.Substring') 'Service setup does not version certificate volumes by identity.'
Add-Check ($setup -match 'force-recreate') 'Service setup does not force certificate reload.'
Add-Check ($setup -match 'rollback also failed') 'Service setup does not surface failed certificate rollback.'
Add-Check ($setup -match 'Write-ServiceState') 'Service setup does not persist the active certificate volume.'
Add-Check ($setup -match 'X509Certificate2\]::CreateFromPem\(') 'Service setup does not use the cross-platform certificate-only PEM loader.'
Add-Check ($setup -notmatch 'docker\s+(system\s+prune|rm\s+-f\s+\$\(|volume\s+prune)') 'Service setup contains broad Docker cleanup.'
Add-Check ($profile.build.args.CRANE_VERSION -eq '0.21.9') 'Image-builder profile does not pin crane 0.21.9.'
$craneVerification = @(
    $profile.verificationCommands |
        Where-Object { $_ -match 'crane version' }
)
Add-Check (
    $craneVerification.Count -eq 1 -and
    $craneVerification[0] -ceq 'test "$(crane version)" = "0.21.9"'
) 'Image-builder profile does not require crane exact output 0.21.9.'
Add-Check ($dockerfile -match 'CRANE_SHA256_X64') 'Image-builder Dockerfile does not verify the crane download.'
Add-Check (
    $dockerfile -match [regex]::Escape(
        "sed -i 's/\r$//' /usr/local/bin/pitcrew-build-image")
) 'Image-builder Dockerfile does not normalize the helper to LF.'
Add-Check (
    $dockerfile -match [regex]::Escape(
        'grep -q "$(printf ''\r'')" /usr/local/bin/pitcrew-build-image') -and
    $dockerfile -match 'bash -n /usr/local/bin/pitcrew-build-image'
) 'Image-builder Dockerfile does not reject carriage returns and invalid Bash.'
$helperVerification = @(
    $profile.verificationCommands |
        Where-Object { $_ -match '/usr/local/bin/pitcrew-build-image' }
)
Add-Check (
    $helperVerification.Count -eq 1 -and
    $helperVerification[0] -ceq (
        'test -x /usr/local/bin/pitcrew-build-image && ' +
        '! grep -q "$(printf ''\r'')" /usr/local/bin/pitcrew-build-image && ' +
        'bash -n /usr/local/bin/pitcrew-build-image')
) 'Image-builder profile does not verify LF-only valid Bash helper bytes.'
Add-Check (
    -not ($helperBytes -contains [byte]13)
) 'Checked-in image-builder helper contains unsupported carriage returns.'
Add-Check (
    $attributes -match (
        '(?m)^profiles/image-builder/pitcrew-build-image text eol=lf\r?$')
) 'Git attributes do not force LF for the extensionless image-builder helper.'
foreach ($argument in @(
        '--build-arg',
        '--label',
        '--platform',
        '--output-oci',
        '--verify-registry',
        '--candidate-output',
        '--recipe-id',
        '--source-repository',
        '--source-commit',
        '--workflow-run-id')) {
    Add-Check ($helper -match [regex]::Escape($argument)) "Image-builder helper omits '$argument'."
}
Add-Check ($helper -notmatch '\beval\b|/var/run/docker\.sock') 'Image-builder helper uses unsafe evaluation or Docker access.'
Add-Check (
    $helper -match [regex]::Escape(
        'Candidate output must be outside the reviewed build context.') -and
    $helper -match [regex]::Escape(
        'Published candidates require --verify-registry.') -and
    $helper -match [regex]::Escape(
        'mv -f "${report_temporary}" "${candidate_output}"') -and
    $helper -match [regex]::Escape(
        'chmod 0600 "${report_temporary}"')
) 'Image-builder helper does not constrain and atomically publish candidate evidence.'
$historyPruneIndex = $helper.IndexOf(
    'prune-histories',
    [StringComparison]::Ordinal)
$cachePruneIndex = $helper.IndexOf(
    'prune --all',
    [StringComparison]::Ordinal)
Add-Check (
    $historyPruneIndex -ge 0 -and
    $cachePruneIndex -gt $historyPruneIndex
) 'Image-builder helper does not delete histories before pruning cache.'
Add-Check (
    $helper -match '\bdu\b' -and
    $helper -match [regex]::Escape("--format '{{json .}}'") -and
    $helper -match 'debug histories' -and
    $helper -match '\$\{usage\}" == "null"' -and
    $helper -match [regex]::Escape(
        'PITCREW_BUILDER_CLEANUP_TIMEOUT_SECONDS:-180') -and
    $helper -match 'while true' -and
    $helper -match 'if \(\(SECONDS >= cleanup_deadline\)\)' -and
    $helper -match 'stage=\$\{cleanup_stage\}' -and
    $helper -match 'attempts=\$\{cleanup_attempts\}' -and
    $helper -match 'cacheRecords=\$\{usage_records\}' -and
    $helper -match 'inUseRecords=\$\{in_use_records\}' -and
    $helper -match 'historyRecords=\$\{history_records\}'
) 'Image-builder helper does not verify bounded empty cache and history state.'
$interruptPhaseIndex = $integration.IndexOf(
    'interrupt_logs="$(docker logs',
    [StringComparison]::Ordinal)
$interruptKillIndex = $integration.IndexOf(
    'docker kill --signal KILL',
    [StringComparison]::Ordinal)
Add-Check (
    $integration -match 'INTERRUPT_PHASE="RUN sleep 15"' -and
    $integration -match [regex]::Escape(
        "--format '{{.State.Running}}'") -and
    $integration -match [regex]::Escape(
        "--format '{{.State.ExitCode}}'") -and
    $integration -match
        '\$\{interrupt_logs\}" == \*"\$\{INTERRUPT_PHASE\}"\*' -and
    $integration -notmatch
        '--output type=(cacheonly|oci,dest=/tmp/interrupted\.tar)' -and
    $integration -match
        'PITCREW_BUILDER_CLEANUP_TIMEOUT_SECONDS=3' -and
    $integration -match
        'failureCategory == "builder-cleanup-failed"' -and
    $integration -match [regex]::Escape(
        '-ServerCertificateDirectory "${SERVER_CERTIFICATE_DIRECTORY}"') -and
    $interruptPhaseIndex -ge 0 -and
    $interruptKillIndex -gt $interruptPhaseIndex
) 'The image-builder interruption fixture does not classify direct cleanup versus exact service recovery.'

$readyCandidate = @{
    schemaVersion = 1
    status = 'ready'
    recipeId = 'application-ci'
    createdAt = '2026-08-23T00:00:00Z'
    source = @{
        repository = 'example-org/example-app'
        commit = ('a' * 40) -join ''
        workflowRunId = 123
    }
    image = @{
        reference = 'ghcr.io/example-org/application-ci:candidate'
        digest = 'sha256:' + (('b' * 64) -join '')
        immutableReference =
            'ghcr.io/example-org/application-ci@sha256:' +
                (('b' * 64) -join '')
        platform = 'linux/amd64'
        outputMode = 'registry'
    }
    qualifications = @(
        @{ name = 'image-build'; status = 'passed' },
        @{ name = 'buildkit-digest'; status = 'passed' },
        @{ name = 'registry-digest'; status = 'passed' },
        @{ name = 'builder-cleanup'; status = 'passed' }
    )
    failureCategory = $null
    failureDetail = $null
} | ConvertTo-Json -Depth 10
Add-Check (
    $readyCandidate | Test-Json -SchemaFile $candidateSchemaPath
) 'Image-candidate schema rejects a valid ready registry candidate.'

$failedCandidate = @{
    schemaVersion = 1
    status = 'failed'
    recipeId = 'application-ci'
    createdAt = '2026-08-23T00:00:00Z'
    source = @{
        repository = $null
        commit = $null
        workflowRunId = $null
    }
    image = @{
        reference = 'registry.example/application-ci:candidate'
        digest = $null
        immutableReference = $null
        platform = 'linux/arm64'
        outputMode = 'oci'
    }
    qualifications = @(
        @{ name = 'image-build'; status = 'failed' },
        @{ name = 'buildkit-digest'; status = 'unavailable' },
        @{ name = 'oci-manifest'; status = 'unavailable' },
        @{ name = 'builder-cleanup'; status = 'passed' }
    )
    failureCategory = 'build-failed'
    failureDetail = 'Image build did not complete.'
} | ConvertTo-Json -Depth 10
Add-Check (
    $failedCandidate | Test-Json -SchemaFile $candidateSchemaPath
) 'Image-candidate schema rejects a valid failed candidate.'

$invalidCandidate = $readyCandidate | ConvertFrom-Json -Depth 10
$invalidCandidate.qualifications[0].status = 'unavailable'
Add-Check (-not (
    ($invalidCandidate | ConvertTo-Json -Depth 10) |
        Test-Json -SchemaFile $candidateSchemaPath -ErrorAction SilentlyContinue
)) 'Image-candidate schema accepts ready evidence with unavailable qualification.'

$candidateFixtureRoot = Join-Path (
    [IO.Path]::GetTempPath()
) "pitcrew-image-candidate-tests-$([guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $candidateFixtureRoot | Out-Null
    $readyCandidatePath = Join-Path $candidateFixtureRoot 'ready.json'
    [IO.File]::WriteAllText(
        $readyCandidatePath,
        $readyCandidate,
        [Text.UTF8Encoding]::new($false))
    $validatedCandidate = & $candidateValidatorPath -Path $readyCandidatePath
    Add-Check (
        $validatedCandidate.status -ceq 'ready' -and
        $validatedCandidate.recipeId -ceq 'application-ci'
    ) 'Image-candidate validator did not return the validated candidate.'

    $invalidCandidatePath = Join-Path $candidateFixtureRoot 'invalid.json'
    [IO.File]::WriteAllText(
        $invalidCandidatePath,
        ($invalidCandidate | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    Add-ThrowsCheck `
        -Action {
            & $candidateValidatorPath -Path $invalidCandidatePath | Out-Null
        } `
        -ExpectedMessage 'does not satisfy' `
        -Failure 'Image-candidate validator accepted invalid ready evidence.'

    $oversizedCandidatePath = Join-Path $candidateFixtureRoot 'oversized.json'
    [IO.File]::WriteAllText(
        $oversizedCandidatePath,
        'x' * 16385,
        [Text.UTF8Encoding]::new($false))
    Add-ThrowsCheck `
        -Action {
            & $candidateValidatorPath -Path $oversizedCandidatePath | Out-Null
        } `
        -ExpectedMessage 'between 1 and 16384 bytes' `
        -Failure 'Image-candidate validator accepted oversized evidence.'
} finally {
    if (Test-Path -LiteralPath $candidateFixtureRoot) {
        Remove-Item -LiteralPath $candidateFixtureRoot -Recurse -Force
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pitcrew-buildkit-cert-tests-$([guid]::NewGuid().ToString('N'))"
try {
    $result = & $certificateScript -OutputDirectory $tempRoot -ValidDays 2
    foreach ($path in @(
            (Join-Path $result.authorityDirectory 'ca.pem'),
            (Join-Path $result.authorityDirectory 'ca-key.pem'),
            (Join-Path $result.serverDirectory 'ca.pem'),
            (Join-Path $result.serverDirectory 'server-cert.pem'),
            (Join-Path $result.serverDirectory 'server-key.pem'),
            (Join-Path $result.clientDirectory 'ca.pem'),
            (Join-Path $result.clientDirectory 'cert.pem'),
            (Join-Path $result.clientDirectory 'key.pem'))) {
        Add-Check (Test-Path -LiteralPath $path -PathType Leaf) "Certificate generator omitted '$path'."
    }
    Add-Check ($result.caSha256 -match '^[0-9a-f]{64}$') 'Certificate generator returned an invalid CA fingerprint.'
    Add-Check ($result.serverSha256 -match '^[0-9a-f]{64}$') 'Certificate generator returned an invalid server fingerprint.'
    Add-Check ($result.clientSha256 -match '^[0-9a-f]{64}$') 'Certificate generator returned an invalid client fingerprint.'

    $serverCertificate =
        [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile(
            (Join-Path $result.serverDirectory 'server-cert.pem'),
            (Join-Path $result.serverDirectory 'server-key.pem'))
    $clientCertificate =
        [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile(
            (Join-Path $result.clientDirectory 'cert.pem'),
            (Join-Path $result.clientDirectory 'key.pem'))
    try {
        $serverUsage = @(
            $serverCertificate.Extensions |
                Where-Object {
                    $_ -is [
                        Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]
                } |
                ForEach-Object { $_.EnhancedKeyUsages } |
                ForEach-Object { $_.Value }
        )
        $clientUsage = @(
            $clientCertificate.Extensions |
                Where-Object {
                    $_ -is [
                        Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]
                } |
                ForEach-Object { $_.EnhancedKeyUsages } |
                ForEach-Object { $_.Value }
        )
        Add-Check ($serverUsage -contains '1.3.6.1.5.5.7.3.1') 'Generated server certificate lacks server authentication.'
        Add-Check ($clientUsage -contains '1.3.6.1.5.5.7.3.2') 'Generated client certificate lacks client authentication.'
        $serverNames = @(
            $serverCertificate.Extensions |
                Where-Object { $_.Oid.Value -eq '2.5.29.17' } |
                ForEach-Object { $_.Format($false) }
        ) -join "`n"
        Add-Check ($serverNames -match '(?i)DNS(?: Name)?[=:]buildkitd') 'Generated server certificate lacks the buildkitd DNS identity.'
    } finally {
        $clientCertificate.Dispose()
        $serverCertificate.Dispose()
    }

    Add-ThrowsCheck `
        -Action { & $certificateScript -OutputDirectory $tempRoot | Out-Null } `
        -ExpectedMessage 'is not empty' `
        -Failure 'Certificate generator overwrote existing private material without -Force.'
    $forced = & $certificateScript -OutputDirectory $tempRoot -ValidDays 2 -Force
    Add-Check ($forced.serverSha256 -ne $result.serverSha256) 'Forced certificate rotation reused the prior server identity.'
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if ($errors.Count) {
    throw "Image-builder service tests failed after $checks checks:`n$($errors -join "`n")"
}
Write-Host "Image-builder service tests passed: $checks checks."
