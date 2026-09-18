#Requires -Version 7.0
Set-StrictMode -Version Latest

function Assert-PitCrewDashboardUri {
    param([Parameter(Mandatory)][Uri]$Uri)

    if (-not [string]::IsNullOrEmpty($Uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($Uri.Query) -or
        -not [string]::IsNullOrEmpty($Uri.Fragment)) {
        throw 'DashboardUrl cannot contain credentials, a query string, or a fragment.'
    }
    $localHttp = $Uri.Scheme -eq 'http' -and
        $Uri.Host -in @('localhost', '127.0.0.1', '::1')
    if ($Uri.Scheme -ne 'https' -and -not $localHttp) {
        throw 'DashboardUrl must use HTTPS, except for an explicit localhost URL.'
    }
}

function Test-PitCrewTransientDashboardStatusCode {
    param([Parameter(Mandatory)][int]$StatusCode)

    return $StatusCode -in @(429, 500, 502, 503, 504)
}

function Get-PitCrewDashboardRetryDelaySeconds {
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][Net.Http.HttpResponseMessage]$Response
    )

    $retryAfter = $Response.Headers.RetryAfter
    if ($null -ne $retryAfter) {
        $delay =
            if ($null -ne $retryAfter.Delta) {
                $retryAfter.Delta.TotalSeconds
            } elseif ($null -ne $retryAfter.Date) {
                ($retryAfter.Date.Value - [DateTimeOffset]::UtcNow).TotalSeconds
            } else {
                0
            }
        if ($delay -gt 0) {
            return [int][Math]::Min(
                60,
                [Math]::Max(1, [Math]::Ceiling($delay)))
        }
    }

    if ($StatusCode -eq 429) {
        return 60
    }
    return [int][Math]::Pow(2, $Attempt - 1)
}

function New-PitCrewDashboardDiagnosticClient {
    param(
        [Parameter(Mandatory)][Uri]$DashboardUrl,
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Credential,
        [ValidateRange(0, 60000)]
        [int]$MinimumIntervalMilliseconds = 500
    )

    Assert-PitCrewDashboardUri $DashboardUrl
    if ([string]::IsNullOrWhiteSpace($Credential)) {
        throw 'Set PITCREW_DIAGNOSTICS_CREDENTIAL in the process environment.'
    }

    return [PSCustomObject][ordered]@{
        BaseUrl = $DashboardUrl.AbsoluteUri.TrimEnd('/')
        Headers = @{
            Authorization = "PitCrew-Diagnostics $Credential"
        }
        LastRequestAt = [DateTimeOffset]::MinValue
        MinimumIntervalMilliseconds = $MinimumIntervalMilliseconds
    }
}

function Invoke-PitCrewDashboardGet {
    param(
        [Parameter(Mandatory)][object]$Client,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not $Path.StartsWith('/', [StringComparison]::Ordinal)) {
        throw 'Dashboard request paths must be origin-relative.'
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $now = [DateTimeOffset]::UtcNow
        $elapsedInterval = $now - $Client.LastRequestAt
        $elapsed = $elapsedInterval.TotalMilliseconds
        $delay = $Client.MinimumIntervalMilliseconds - $elapsed
        if ($delay -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Ceiling($delay))
        }
        $Client.LastRequestAt = [DateTimeOffset]::UtcNow
        try {
            return Invoke-RestMethod `
                -Method Get `
                -Uri "$($Client.BaseUrl)$Path" `
                -Headers $Client.Headers
        } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $statusCode = [int]$_.Exception.Response.StatusCode
            if (-not (Test-PitCrewTransientDashboardStatusCode $statusCode) -or
                $attempt -eq 3) {
                throw
            }
            $retryDelay = Get-PitCrewDashboardRetryDelaySeconds `
                -StatusCode $statusCode `
                -Attempt $attempt `
                -Response $_.Exception.Response
            Start-Sleep -Seconds $retryDelay
        }
    }
}

function Get-PitCrewDashboardFleetPages {
    param(
        [Parameter(Mandatory)][scriptblock]$Request,
        [ValidateRange(1, 100)]
        [int]$Limit = 100,
        [AllowNull()][scriptblock]$StopWhen
    )

    $pages = [Collections.Generic.List[object]]::new()
    $seenCursors = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $afterNodeId = $null
    do {
        $page = & $Request $afterNodeId $Limit
        $generatedAt = $page.PSObject.Properties['generatedAt']
        $nextAfterNodeId = $page.PSObject.Properties['nextAfterNodeId']
        $projectedPage = [PSCustomObject][ordered]@{
            GeneratedAt = if ($null -eq $generatedAt) {
                $null
            } else {
                $generatedAt.Value
            }
            Nodes = @($page.nodes)
            NextAfterNodeId = if ($null -eq $nextAfterNodeId) {
                $null
            } else {
                $nextAfterNodeId.Value
            }
        }
        $pages.Add($projectedPage)
        if ($null -ne $StopWhen -and (& $StopWhen $projectedPage)) {
            break
        }
        $afterNodeId = $projectedPage.NextAfterNodeId
        if ($null -ne $afterNodeId -and
            -not $seenCursors.Add([string]$afterNodeId)) {
            throw 'Dashboard fleet pagination repeated a cursor.'
        }
    } while ($null -ne $afterNodeId)
    return @($pages)
}

function Invoke-PitCrewPagedFleetRequest {
    param(
        [Parameter(Mandatory)][scriptblock]$Request,
        [ValidateRange(1, 100)]
        [int]$Limit = 100
    )

    $nodes = [Collections.Generic.List[object]]::new()
    foreach ($page in @(
            Get-PitCrewDashboardFleetPages `
                -Request $Request `
                -Limit $Limit)) {
        foreach ($node in @($page.Nodes)) {
            $nodes.Add($node)
        }
    }
    return @($nodes)
}
