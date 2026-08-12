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
        $helperPath)) {
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
Add-Check ($config -match 'root = "/home/user/\.local/share/buildkit"') 'BuildKit state is not rooted in the rootless user directory.'
Add-Check ($config -match 'rootless = true') 'BuildKit OCI worker is not explicitly rootless.'
Add-Check ($config -match 'noProcessSandbox = false') 'BuildKit process isolation is not explicitly retained.'
Add-Check ($config -match 'allowedRepositories = \[ "docker\.io/docker/dockerfile" \]') 'BuildKit gateway frontend is not restricted to the Dockerfile frontend.'
Add-Check ($setup -match 'HostConfig\.Privileged') 'Service setup does not verify the non-privileged boundary.'
Add-Check ($setup -match 'SecurityOpt') 'Service setup does not verify exact security options.'
Add-Check ($setup -match 'pitcrew-image-builder-certs-\$\(\$certificateSha256\.Substring') 'Service setup does not version certificate volumes by identity.'
Add-Check ($setup -match 'force-recreate') 'Service setup does not force certificate reload.'
Add-Check ($setup -match 'rollback also failed') 'Service setup does not surface failed certificate rollback.'
Add-Check ($setup -match 'Write-ServiceState') 'Service setup does not persist the active certificate volume.'
Add-Check ($setup -notmatch 'docker\s+(system\s+prune|rm\s+-f\s+\$\(|volume\s+prune)') 'Service setup contains broad Docker cleanup.'
Add-Check ($profile.build.args.CRANE_VERSION -eq '0.21.9') 'Image-builder profile does not pin crane 0.21.9.'
Add-Check ($dockerfile -match 'CRANE_SHA256_X64') 'Image-builder Dockerfile does not verify the crane download.'
foreach ($argument in @(
        '--build-arg',
        '--label',
        '--platform',
        '--output-oci',
        '--verify-registry')) {
    Add-Check ($helper -match [regex]::Escape($argument)) "Image-builder helper omits '$argument'."
}
Add-Check ($helper -notmatch '\beval\b|/var/run/docker\.sock') 'Image-builder helper uses unsafe evaluation or Docker access.'

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
