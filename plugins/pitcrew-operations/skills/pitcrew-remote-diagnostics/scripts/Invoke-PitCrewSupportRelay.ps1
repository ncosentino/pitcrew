#Requires -Version 7.0
<#
.SYNOPSIS
Requests and imports one read-only PitCrew support-relay diagnostic session.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Uri]$DashboardUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [Guid]$DashboardNodeId,

    [ValidateSet(
        'ConnectorOffline',
        'CapacityMismatch',
        'JobNotAssigned',
        'HostPressure',
        'Full')]
    [string]$DiagnosticMode = 'Full',

    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
    [string]$Profile,

    [Parameter(Mandatory)]
    [string]$PreflightPath,

    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [ValidateRange(30, 1800)]
    [int]$TimeoutSeconds = 300,

    [ValidateRange(60, 3600)]
    [int]$ExpiresInSeconds = 900,

    [Guid]$SessionId,

    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RemoteDiagnostics.Core.ps1')

function ConvertFrom-PitCrewSupportBase64Url {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -notmatch '^[A-Za-z0-9_-]+$') {
        throw 'The support result contains invalid base64url data.'
    }
    $padded = $Value.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        0 {}
        2 { $padded += '==' }
        3 { $padded += '=' }
        default { throw 'The support result contains invalid base64url padding.' }
    }
    try {
        return [Convert]::FromBase64String($padded)
    } catch [FormatException] {
        throw 'The support result contains invalid base64url data.'
    }
}

function Invoke-PitCrewSupportHttp {
    param(
        [Parameter(Mandatory)][Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)][Net.Http.HttpMethod]$Method,
        [Parameter(Mandatory)][Uri]$Uri,
        [AllowNull()][object]$Body
    )

    $request = [Net.Http.HttpRequestMessage]::new($Method, $Uri)
    $response = $null
    try {
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 20 -Compress
            $request.Content = [Net.Http.StringContent]::new(
                $json,
                [Text.UTF8Encoding]::new($false),
                'application/json')
        }
        $response = $Client.Send(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        if (-not $response.IsSuccessStatusCode) {
            throw "Dashboard support API returned HTTP $([int]$response.StatusCode)."
        }
        $contentType = $response.Content.Headers.ContentType
        if ($null -eq $contentType -or
            $contentType.MediaType -ne
            'application/json' -or
            $response.Content.Headers.ContentEncoding.Count -gt 0) {
            throw 'Dashboard support API returned an unsupported content type.'
        }
        if ($response.Content.Headers.ContentLength -gt 4194304) {
            throw 'Dashboard support API returned an oversized response.'
        }
        $responseStream =
            $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $memory = [IO.MemoryStream]::new()
        $readCancellation =
            [Threading.CancellationTokenSource]::new(
                [TimeSpan]::FromSeconds(30))
        try {
            $buffer = [byte[]]::new(8192)
            while ($true) {
                $readTask = $responseStream.ReadAsync(
                    $buffer,
                    0,
                    $buffer.Length,
                    $readCancellation.Token)
                $count = $readTask.GetAwaiter().GetResult()
                if ($count -le 0) {
                    break
                }
                if ($memory.Length + $count -gt 4194304) {
                    throw 'Dashboard support API returned an oversized response.'
                }
                $memory.Write($buffer, 0, $count)
            }
            try {
                $content = [Text.UTF8Encoding]::new(
                    $false,
                    $true).GetString($memory.ToArray())
            } catch [Text.DecoderFallbackException] {
                throw 'Dashboard support API returned invalid UTF-8.'
            }
        } catch [OperationCanceledException] {
            throw 'Dashboard support API response timed out.'
        } finally {
            $readCancellation.Dispose()
            $memory.Dispose()
            $responseStream.Dispose()
        }
        try {
            return $content |
                ConvertFrom-Json -Depth 100 -ErrorAction Stop
        } catch [Management.Automation.RuntimeException] {
            throw 'Dashboard support API returned invalid JSON.'
        }
    } finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
        $request.Dispose()
    }
}

Assert-PitCrewRemoteDiagnosticUrl $DashboardUrl
if ($DashboardNodeId -eq [Guid]::Empty) {
    throw 'DashboardNodeId cannot be empty.'
}
if ($SessionId -eq [Guid]::Empty -and
    $ExpiresInSeconds -lt $TimeoutSeconds) {
    throw 'ExpiresInSeconds cannot be shorter than TimeoutSeconds.'
}
$loopbackHttp = $DashboardUrl.Scheme -eq 'http' -and
    $DashboardUrl.Host -in @('localhost', '127.0.0.1', '::1')
if ($DashboardUrl.Scheme -ne 'https' -and -not $loopbackHttp) {
    throw 'DashboardUrl must use HTTPS except for explicit loopback testing.'
}
if ($DashboardUrl.AbsolutePath -ne '/' -or
    -not [string]::IsNullOrEmpty($DashboardUrl.Query) -or
    -not [string]::IsNullOrEmpty($DashboardUrl.Fragment)) {
    throw 'DashboardUrl must be an origin-only URL.'
}
if (-not (Test-Path -LiteralPath $PreflightPath -PathType Leaf)) {
    throw 'PreflightPath is missing.'
}
$preflightItem = Get-Item -LiteralPath $PreflightPath -Force
if (($preflightItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    $preflightItem.Length -le 0 -or
    $preflightItem.Length -gt 1048576) {
    throw 'PreflightPath does not satisfy the bounded support contract.'
}
$preflight = Get-Content -LiteralPath $PreflightPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -Depth 50 -ErrorAction Stop
if ($preflight.schemaVersion -ne 1 -or
    (Test-PitCrewRemoteDiagnosticsForbiddenProperty $preflight)) {
    throw 'PreflightPath does not satisfy the read-only evidence contract.'
}

$tenantSegment = [Uri]::EscapeDataString($TenantId)
$sessionsUri = [Uri]::new(
    $DashboardUrl,
    "/api/tenants/$tenantSegment/support/v1/sessions")
$plan = [PSCustomObject][ordered]@{
    executionMode = 'Relay'
    diagnosticMode = $DiagnosticMode
    profile = if ([string]::IsNullOrWhiteSpace($Profile)) { $null } else { $Profile }
    dashboardOrigin = $DashboardUrl.AbsoluteUri
    tenantId = $TenantId
    nodeId = $DashboardNodeId.ToString('D')
    timeoutSeconds = $TimeoutSeconds
    expiresInSeconds = $ExpiresInSeconds
    sessionId = if ($SessionId -eq [Guid]::Empty) {
        $null
    } else {
        $SessionId.ToString('D')
    }
    credentialSource = 'PITCREW_DIAGNOSTICS_CREDENTIAL'
    mutation = $false
}
if ($PlanOnly) {
    return $plan
}

$credential = [Environment]::GetEnvironmentVariable(
    'PITCREW_DIAGNOSTICS_CREDENTIAL')
if ([string]::IsNullOrWhiteSpace($credential)) {
    throw 'PITCREW_DIAGNOSTICS_CREDENTIAL is required for relay diagnostics.'
}
if ($credential.Length -gt 4096 -or $credential -match '[\r\n]') {
    throw 'PITCREW_DIAGNOSTICS_CREDENTIAL is invalid.'
}

Add-Type -AssemblyName System.Net.Http
$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(30)
$client.DefaultRequestHeaders.Authorization =
    [Net.Http.Headers.AuthenticationHeaderValue]::new(
        'PitCrew-Diagnostics',
        $credential)
$client.DefaultRequestHeaders.Accept.Add(
    [Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new(
        'application/json'))

try {
    if ($SessionId -eq [Guid]::Empty) {
        $createBody = [PSCustomObject][ordered]@{
            nodeId = $DashboardNodeId.ToString('D')
            diagnosticMode = $DiagnosticMode
            profileId = if ([string]::IsNullOrWhiteSpace($Profile)) {
                $null
            } else {
                $Profile
            }
            expiresInSeconds = $ExpiresInSeconds
        }
        $session = Invoke-PitCrewSupportHttp `
            -Client $client `
            -Method ([Net.Http.HttpMethod]::Post) `
            -Uri $sessionsUri `
            -Body $createBody
        $createdSessionId = [Guid]::Empty
        if (-not [Guid]::TryParse(
                [string]$session.sessionId,
                [ref]$createdSessionId) -or
            $createdSessionId -eq [Guid]::Empty) {
            throw 'Dashboard support API returned an invalid session identity.'
        }
        $SessionId = $createdSessionId
    }
    $sessionUri = [Uri]::new(
        $DashboardUrl,
        "/api/tenants/$tenantSegment/support/v1/sessions/$($SessionId.ToString('D'))")
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $session = Invoke-PitCrewSupportHttp `
            -Client $client `
            -Method ([Net.Http.HttpMethod]::Get) `
            -Uri $sessionUri `
            -Body $null
        $sessionStatus = ([string]$session.status).ToLowerInvariant()
        switch ($sessionStatus) {
            'completed' { break }
            'rejected' { throw 'The support node rejected the diagnostic request.' }
            'cancelled' { throw 'The support diagnostic session was cancelled.' }
            'expired' { throw 'The support diagnostic session expired.' }
            'failed' { throw 'The support diagnostic session failed.' }
            'pending' {}
            'queued' {}
            'dispatched' {}
            'running' {}
            default { throw 'Dashboard support API returned an unsupported session status.' }
        }
        if ($sessionStatus -eq 'completed') {
            break
        }
        Start-Sleep -Seconds 2
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    if ($sessionStatus -ne 'completed') {
        return [PSCustomObject][ordered]@{
            sessionId = $SessionId
            sessionUrl = $sessionUri.AbsoluteUri
            status = $sessionStatus
            completed = $false
        }
    }

    if ($session.nodeSigningKeyFingerprint -notmatch '^[a-f0-9]{64}$') {
        throw 'Dashboard support API did not bind the session to an enrolled node signing key.'
    }
    $expectedNodeSigningKeyFingerprint =
        [string]$session.nodeSigningKeyFingerprint
    $attestation = $session.result.attestation
    if ($attestation.signatureAlgorithm -ne 'ES256-P1363') {
        throw 'The support result uses an unsupported signature algorithm.'
    }
    $encodedPayload = [string]$attestation.payloadBase64Url
    $encodedSignature = [string]$attestation.signatureBase64Url
    if ($encodedPayload.Length -gt 4000000 -or
        $encodedSignature.Length -gt 128) {
        throw 'The support result contains oversized attestation data.'
    }
    $payloadBytes = ConvertFrom-PitCrewSupportBase64Url `
        -Value $encodedPayload
    $signature = ConvertFrom-PitCrewSupportBase64Url `
        -Value $encodedSignature
    $encodedPublicKey = [string]$attestation.nodeSigningPublicKeySpki
    if ($encodedPublicKey.Length -gt 2048 -or
        $encodedPublicKey -notmatch '^[A-Za-z0-9+/]+={0,2}$') {
        throw 'The support result contains an invalid node signing key.'
    }
    try {
        $publicKey = [Convert]::FromBase64String($encodedPublicKey)
    } catch [FormatException] {
        throw 'The support result contains an invalid node signing key.'
    }
    if ($publicKey.Length -gt 1024) {
        throw 'The support result contains an oversized node signing key.'
    }
    $actualNodeSigningKeyFingerprint = (
        [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($publicKey))
    ).ToLowerInvariant()
    if ($actualNodeSigningKeyFingerprint -ne
        $expectedNodeSigningKeyFingerprint) {
        throw 'The support result was not signed by the enrolled node identity.'
    }
    if ($signature.Length -ne 64) {
        throw 'The support result contains an invalid node signature length.'
    }
    $ecdsa = [Security.Cryptography.ECDsa]::Create()
    try {
        try {
            $bytesRead = 0
            $ecdsa.ImportSubjectPublicKeyInfo($publicKey, [ref]$bytesRead)
            $signatureValid = $bytesRead -eq $publicKey.Length -and
                $ecdsa.KeySize -eq 256 -and
                $ecdsa.VerifyData(
                    $payloadBytes,
                    $signature,
                    [Security.Cryptography.HashAlgorithmName]::SHA256,
                    [Security.Cryptography.DSASignatureFormat]::IeeeP1363FixedFieldConcatenation)
        } catch [Security.Cryptography.CryptographicException] {
            $signatureValid = $false
        }
        if (-not $signatureValid) {
            throw 'The support result node signature is invalid.'
        }
    } finally {
        $ecdsa.Dispose()
    }
    try {
        $payloadJson = [Text.UTF8Encoding]::new(
            $false,
            $true).GetString($payloadBytes)
        $payload = $payloadJson |
            ConvertFrom-Json -Depth 100 -ErrorAction Stop
    } catch [Text.DecoderFallbackException] {
        throw 'The signed support result payload is not valid UTF-8.'
    } catch [Management.Automation.RuntimeException] {
        throw 'The signed support result payload is not valid JSON.'
    }
    $payloadSessionId = ConvertTo-PitCrewRemoteDiagnosticsGuid `
        -Value $payload.sessionId `
        -Context 'Support result session ID'
    $payloadNodeId = ConvertTo-PitCrewRemoteDiagnosticsGuid `
        -Value $payload.nodeId `
        -Context 'Support result node ID'
    if (
        $payloadSessionId -ne $SessionId -or
        $payloadNodeId -ne $DashboardNodeId -or
        [string]$payload.tenantId -cne $TenantId -or
        $payload.report.schemaVersion -ne 1 -or
        [string]$payload.report.diagnosticMode -cne $DiagnosticMode -or
        [string]$payload.report.collectionScope -cne 'file-only' -or
        $payload.report.packageId -notmatch '^[a-f0-9]{16,64}$' -or
        $payload.report.collectorSha256 -notmatch '^[a-f0-9]{64}$' -or
        $payload.report.pitcrewRoot -ne '<pitcrew-root>' -or
        (Test-PitCrewRemoteDiagnosticsForbiddenProperty $payload.report)
    ) {
        throw 'The signed support result does not satisfy the diagnostic contract.'
    }
    if (-not [string]::IsNullOrWhiteSpace($Profile) -and
        [string]$payload.report.profile -cne $Profile) {
        throw 'The signed support result does not match the requested profile.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$payload.markdown) -or
        ([string]$payload.markdown).Length -gt 1048576) {
        throw 'The signed support result contains invalid Markdown evidence.'
    }

    $resultDirectory = Join-Path `
        $OutputDirectory `
        "pitcrew-support-result-$($SessionId.ToString('N'))"
    Write-PitCrewRemoteDiagnosticsArtifacts `
        -Envelope ([PSCustomObject][ordered]@{
            report = $payload.report
            markdown = [string]$payload.markdown
        }) `
        -OutputDirectory $resultDirectory
    $importScript = Join-Path $PSScriptRoot 'Import-PitCrewDiagnostics.ps1'
    $diagnosisDirectory = Join-Path `
        $OutputDirectory `
        "pitcrew-support-diagnosis-$($SessionId.ToString('N'))"
    $imported = & $importScript `
        -InputPath $resultDirectory `
        -ExpectedPackageId ([string]$payload.report.packageId) `
        -ExpectedCollectorSha256 ([string]$payload.report.collectorSha256) `
        -PreflightPath $PreflightPath `
        -OutputDirectory $diagnosisDirectory
    [PSCustomObject][ordered]@{
        sessionId = $SessionId
        sessionUrl = $sessionUri.AbsoluteUri
        status = 'completed'
        completed = $true
        resultDirectory = (Resolve-Path -LiteralPath $resultDirectory).Path
        diagnosisJsonPath = $imported.diagnosisJsonPath
        diagnosisMarkdownPath = $imported.diagnosisMarkdownPath
    }
} finally {
    $client.Dispose()
    $handler.Dispose()
}
