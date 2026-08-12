#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ServerCertificateDirectory = '',

    [switch]$Down
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serviceRoot = $PSScriptRoot
$pitcrewRoot = (Resolve-Path (Join-Path $serviceRoot '..' '..')).Path
$composePath = Join-Path $serviceRoot 'docker-compose.yml'
$stateDirectory = Join-Path $pitcrewRoot '.pitcrew-state' 'image-builder-service'
$statePath = Join-Path $stateDirectory 'service.json'
$projectName = 'pitcrew-image-builder-service'
$networkName = 'pitcrew-image-builder'
$stateVolume = 'pitcrew-image-builder-state'
$defaultCertificateVolume = 'pitcrew-image-builder-certs'
$serviceImage =
    'moby/buildkit:v0.32.2-rootless@sha256:504731e577c20559c00f968f33219f30115e70be29ab96728d1d06e963fc494b'

function Invoke-Docker {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)

    $output = & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($Arguments -join ' ') failed."
    }
    return $output
}

function Read-ServiceState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 10 -ErrorAction Stop
    } catch {
        throw "Image-builder service state '$statePath' is invalid: $($_.Exception.Message)"
    }
    if (
        [int]$state.schemaVersion -ne 1 -or
        [string]$state.certificateVolume -notmatch
            '^pitcrew-image-builder-certs(?:-[0-9a-f]{16})?$' -or
        [string]$state.certificateSha256 -notmatch '^[0-9a-f]{64}$'
    ) {
        throw "Image-builder service state '$statePath' has an unsupported contract."
    }
    return $state
}

function Write-ServiceState {
    param(
        [Parameter(Mandatory)]
        [string]$CertificateVolume,

        [Parameter(Mandatory)]
        [string]$CertificateSha256
    )

    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    $temporaryPath = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
    [PSCustomObject][ordered]@{
        schemaVersion = 1
        certificateVolume = $CertificateVolume
        certificateSha256 = $CertificateSha256
        updatedAt = [DateTimeOffset]::UtcNow.ToString('O')
    } |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $temporaryPath -Encoding utf8NoBOM
    [IO.File]::Move($temporaryPath, $statePath, $true)
}

function Invoke-ServiceCompose {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)

    Invoke-Docker `
        compose `
        --project-name $projectName `
        --file $composePath `
        @Arguments
}

function Get-ExactContainer {
    $ids = @(
        & docker ps -q `
            --filter "label=com.docker.compose.project=$projectName" `
            --filter 'label=com.docker.compose.service=buildkitd'
    )
    if ($LASTEXITCODE -ne 0 -or $ids.Count -ne 1) {
        throw "Expected exactly one running '$projectName' BuildKit container."
    }
    return (& docker inspect ([string]$ids[0]) | ConvertFrom-Json -Depth 30)[0]
}

function Assert-ServiceContract {
    $container = Get-ExactContainer
    if ($container.HostConfig.Privileged) {
        throw 'Rootless BuildKit service unexpectedly runs privileged.'
    }
    $securityOptions = @($container.HostConfig.SecurityOpt)
    foreach ($required in @(
            'seccomp=unconfined',
            'apparmor=unconfined')) {
        if ($securityOptions -notcontains $required) {
            throw "Rootless BuildKit service is missing security option '$required'."
        }
    }
    if (
        @($container.HostConfig.MaskedPaths).Count -ne 0 -or
        @($container.HostConfig.ReadonlyPaths).Count -ne 0
    ) {
        throw 'Rootless BuildKit service did not apply systempaths=unconfined.'
    }
    if (
        @(
            $container.Mounts |
                Where-Object { $_.Source -eq '/var/run/docker.sock' }
        ).Count
    ) {
        throw 'Rootless BuildKit service unexpectedly mounts the orchestration Docker socket.'
    }
    if ($container.State.Health.Status -cne 'healthy') {
        throw "Rootless BuildKit service health is '$($container.State.Health.Status)'."
    }
    if (
        $null -eq $container.NetworkSettings.Networks.PSObject.Properties[$networkName]
    ) {
        throw "Rootless BuildKit service is not attached to '$networkName'."
    }
}

function Restore-EnvironmentValue {
    param(
        [string]$Name,
        [AllowNull()][string]$Value,
        [bool]$Existed
    )

    if ($Existed) {
        Set-Item -LiteralPath "Env:$Name" -Value $Value
    } else {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker is required.'
}
Invoke-Docker compose version | Out-Null
$previousState = Read-ServiceState
$certificateEnvironmentName = 'PITCREW_IMAGE_BUILDER_CERT_VOLUME'
$previousEnvironmentItem = Get-Item `
    -LiteralPath "Env:$certificateEnvironmentName" `
    -ErrorAction SilentlyContinue
$previousEnvironmentExisted = $null -ne $previousEnvironmentItem
$previousEnvironmentValue = if ($previousEnvironmentItem) {
    $previousEnvironmentItem.Value
} else {
    $null
}

if ($Down) {
    $certificateVolume = if ($previousState) {
        [string]$previousState.certificateVolume
    } else {
        $defaultCertificateVolume
    }
    try {
        $env:PITCREW_IMAGE_BUILDER_CERT_VOLUME = $certificateVolume
        Invoke-ServiceCompose down | Out-Null
    } finally {
        Restore-EnvironmentValue `
            -Name $certificateEnvironmentName `
            -Value $previousEnvironmentValue `
            -Existed $previousEnvironmentExisted
    }
    Write-Host '[done] Image-builder service stopped; certificate and state volumes were preserved.'
    return
}

if ([string]::IsNullOrWhiteSpace($ServerCertificateDirectory)) {
    throw '-ServerCertificateDirectory is required unless -Down is used.'
}
$resolvedCertificates = (Resolve-Path -LiteralPath $ServerCertificateDirectory).Path
if ($resolvedCertificates.Contains(',')) {
    throw 'Server certificate directory cannot contain a comma.'
}
$certificatePaths = [ordered]@{
    ca = Join-Path $resolvedCertificates 'ca.pem'
    cert = Join-Path $resolvedCertificates 'server-cert.pem'
    key = Join-Path $resolvedCertificates 'server-key.pem'
}
foreach ($path in $certificatePaths.Values) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required server certificate file is missing: $path"
    }
}

$serverCertificate =
    [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile(
        $certificatePaths.cert,
        $certificatePaths.key)
$caCertificate =
    [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
        [IO.File]::ReadAllText($certificatePaths.ca))
try {
    if ($serverCertificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) {
        throw 'BuildKit server certificate is expired.'
    }
    if ($caCertificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) {
        throw 'BuildKit certificate authority is expired.'
    }
    $serverUsage = @(
        $serverCertificate.Extensions |
            Where-Object {
                $_ -is [
                    Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]
            } |
            ForEach-Object { $_.EnhancedKeyUsages } |
            ForEach-Object { $_.Value }
    )
    if ($serverUsage -notcontains '1.3.6.1.5.5.7.3.1') {
        throw 'BuildKit server certificate does not permit server authentication.'
    }
    $subjectAlternativeName = @(
        $serverCertificate.Extensions |
            Where-Object { $_.Oid.Value -eq '2.5.29.17' } |
            ForEach-Object { $_.Format($false) }
    ) -join "`n"
    if ($subjectAlternativeName -notmatch '(?i)DNS(?: Name)?[=:]buildkitd') {
        throw "BuildKit server certificate does not contain DNS name 'buildkitd'."
    }
    $certificateSha256 = $serverCertificate.GetCertHashString(
        [Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
} finally {
    $caCertificate.Dispose()
    $serverCertificate.Dispose()
}
$targetCertificateVolume =
    "pitcrew-image-builder-certs-$($certificateSha256.Substring(0, 16))"

$network = & docker network inspect `
    --format '{{.Name}}|{{.Driver}}|{{.Scope}}|{{.Internal}}' `
    $networkName 2>$null
if ($LASTEXITCODE -ne 0) {
    Invoke-Docker network create --driver bridge $networkName | Out-Null
} elseif ([string]$network -cne "$networkName|bridge|local|false") {
    throw "Existing network '$networkName' is not an exact local, non-internal bridge network."
}
foreach ($volume in @($stateVolume, $targetCertificateVolume)) {
    $resolvedVolume = & docker volume inspect --format '{{.Name}}' $volume 2>$null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Docker volume create $volume | Out-Null
    } elseif ([string]$resolvedVolume -cne $volume) {
        throw "Existing Docker volume '$volume' resolved ambiguously."
    }
}

Invoke-Docker `
    run `
    --rm `
    --user 0 `
    --mount "type=bind,src=$resolvedCertificates,dst=/source,readonly" `
    --mount "type=volume,src=$targetCertificateVolume,dst=/target" `
    --entrypoint /bin/sh `
    $serviceImage `
    -lc (
        'set -eu; ' +
        'rm -f /target/ca.pem /target/server-cert.pem /target/server-key.pem; ' +
        'cp /source/ca.pem /target/ca.pem; ' +
        'cp /source/server-cert.pem /target/server-cert.pem; ' +
        'cp /source/server-key.pem /target/server-key.pem; ' +
        'chown 1000:1000 /target/ca.pem /target/server-cert.pem /target/server-key.pem; ' +
        'chmod 0644 /target/ca.pem /target/server-cert.pem; ' +
        'chmod 0600 /target/server-key.pem'
    ) | Out-Null

$applyError = $null
try {
    $env:PITCREW_IMAGE_BUILDER_CERT_VOLUME = $targetCertificateVolume
    Invoke-ServiceCompose config --quiet | Out-Null
    Invoke-ServiceCompose up --detach --wait --force-recreate | Out-Null
    Assert-ServiceContract
    Write-ServiceState `
        -CertificateVolume $targetCertificateVolume `
        -CertificateSha256 $certificateSha256
} catch {
    $applyError = $_
    if (
        $previousState -and
        [string]$previousState.certificateVolume -cne $targetCertificateVolume
    ) {
        try {
            $env:PITCREW_IMAGE_BUILDER_CERT_VOLUME =
                [string]$previousState.certificateVolume
            Invoke-ServiceCompose up --detach --wait --force-recreate | Out-Null
            Assert-ServiceContract
            Invoke-Docker volume rm $targetCertificateVolume | Out-Null
        } catch {
            throw (
                "Image-builder service update failed and rollback also failed. " +
                "Apply error: $($applyError.Exception.Message) " +
                "Rollback error: $($_.Exception.Message)")
        }
    }
    throw $applyError
} finally {
    Restore-EnvironmentValue `
        -Name $certificateEnvironmentName `
        -Value $previousEnvironmentValue `
        -Existed $previousEnvironmentExisted
}

Write-Host '[done] Rootless image-builder service is healthy.'
Write-Host "  Network: $networkName"
Write-Host "  State volume: $stateVolume"
Write-Host "  Certificate volume: $targetCertificateVolume"
Write-Host "  Server certificate SHA-256: $certificateSha256"
