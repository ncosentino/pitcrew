#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [ValidateRange(1, 825)]
    [int]$ValidDays = 90,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-SerialNumber {
    $serial = [byte[]]::new(16)
    [Security.Cryptography.RandomNumberGenerator]::Fill($serial)
    $serial[0] = $serial[0] -band 0x7f
    if (($serial | Where-Object { $_ -ne 0 }).Count -eq 0) {
        $serial[15] = 1
    }
    return $serial
}

function Write-PemFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    [IO.File]::WriteAllText(
        $Path,
        $Content.TrimEnd() + "`n",
        [Text.UTF8Encoding]::new($false))
}

$resolvedParent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputDirectory))
if (-not (Test-Path -LiteralPath $resolvedParent -PathType Container)) {
    New-Item -ItemType Directory -Path $resolvedParent -Force | Out-Null
}
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $resolvedOutput) {
    $existing = @(Get-ChildItem -LiteralPath $resolvedOutput -Force)
    if ($existing.Count -gt 0 -and -not $Force) {
        throw "Certificate output '$resolvedOutput' is not empty. Pass -Force to replace only the known certificate files."
    }
} else {
    New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
}

$authorityDirectory = Join-Path $resolvedOutput 'authority'
$serverDirectory = Join-Path $resolvedOutput 'server'
$clientDirectory = Join-Path $resolvedOutput 'client'
foreach ($directory in @($authorityDirectory, $serverDirectory, $clientDirectory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$knownFiles = @(
    (Join-Path $authorityDirectory 'ca.pem'),
    (Join-Path $authorityDirectory 'ca-key.pem'),
    (Join-Path $serverDirectory 'ca.pem'),
    (Join-Path $serverDirectory 'server-cert.pem'),
    (Join-Path $serverDirectory 'server-key.pem'),
    (Join-Path $clientDirectory 'ca.pem'),
    (Join-Path $clientDirectory 'cert.pem'),
    (Join-Path $clientDirectory 'key.pem')
)
if ($Force) {
    Remove-Item -LiteralPath $knownFiles -Force -ErrorAction SilentlyContinue
}

$notBefore = [DateTimeOffset]::UtcNow.AddMinutes(-5)
$notAfter = [DateTimeOffset]::UtcNow.AddDays($ValidDays)
$caKey = [Security.Cryptography.RSA]::Create(3072)
$serverKey = [Security.Cryptography.RSA]::Create(3072)
$clientKey = [Security.Cryptography.RSA]::Create(3072)
$caCertificate = $null
$serverCertificate = $null
$clientCertificate = $null
try {
    $caRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=PitCrew BuildKit CA',
        $caKey,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $caRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
            $true,
            $false,
            0,
            $true))
    $caRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign `
                -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign,
            $true))
    $caRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new(
            $caRequest.PublicKey,
            $false))
    $caCertificate = $caRequest.CreateSelfSigned($notBefore, $notAfter)

    $serverRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=buildkitd',
        $serverKey,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $serverRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
            $false,
            $false,
            0,
            $true))
    $serverRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature `
                -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment,
            $true))
    $serverUsage = [Security.Cryptography.OidCollection]::new()
    $null = $serverUsage.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    $serverRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
            $serverUsage,
            $true))
    $serverNames =
        [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $serverNames.AddDnsName('buildkitd')
    $serverRequest.CertificateExtensions.Add($serverNames.Build($true))
    $serverCertificate = $serverRequest.Create(
        $caCertificate,
        $notBefore,
        $notAfter,
        (New-SerialNumber))

    $clientRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=pitcrew-image-builder-client',
        $clientKey,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $clientRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
            $false,
            $false,
            0,
            $true))
    $clientRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,
            $true))
    $clientUsage = [Security.Cryptography.OidCollection]::new()
    $null = $clientUsage.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.2'))
    $clientRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
            $clientUsage,
            $true))
    $clientCertificate = $clientRequest.Create(
        $caCertificate,
        $notBefore,
        $notAfter,
        (New-SerialNumber))

    $caPem = $caCertificate.ExportCertificatePem()
    Write-PemFile -Path (Join-Path $authorityDirectory 'ca.pem') -Content $caPem
    Write-PemFile `
        -Path (Join-Path $authorityDirectory 'ca-key.pem') `
        -Content $caKey.ExportPkcs8PrivateKeyPem()
    Write-PemFile -Path (Join-Path $serverDirectory 'ca.pem') -Content $caPem
    Write-PemFile `
        -Path (Join-Path $serverDirectory 'server-cert.pem') `
        -Content $serverCertificate.ExportCertificatePem()
    Write-PemFile `
        -Path (Join-Path $serverDirectory 'server-key.pem') `
        -Content $serverKey.ExportPkcs8PrivateKeyPem()
    Write-PemFile -Path (Join-Path $clientDirectory 'ca.pem') -Content $caPem
    Write-PemFile `
        -Path (Join-Path $clientDirectory 'cert.pem') `
        -Content $clientCertificate.ExportCertificatePem()
    Write-PemFile `
        -Path (Join-Path $clientDirectory 'key.pem') `
        -Content $clientKey.ExportPkcs8PrivateKeyPem()

    [PSCustomObject][ordered]@{
        outputDirectory = $resolvedOutput
        authorityDirectory = $authorityDirectory
        serverDirectory = $serverDirectory
        clientDirectory = $clientDirectory
        caSha256 = $caCertificate.GetCertHashString(
            [Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
        serverSha256 = $serverCertificate.GetCertHashString(
            [Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
        clientSha256 = $clientCertificate.GetCertHashString(
            [Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
        expiresAt = $notAfter.ToString('O')
    }
} finally {
    if ($null -ne $clientCertificate) {
        $clientCertificate.Dispose()
    }
    if ($null -ne $serverCertificate) {
        $serverCertificate.Dispose()
    }
    if ($null -ne $caCertificate) {
        $caCertificate.Dispose()
    }
    $clientKey.Dispose()
    $serverKey.Dispose()
    $caKey.Dispose()
}
