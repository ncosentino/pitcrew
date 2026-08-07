#Requires -Version 7.0
Set-StrictMode -Version Latest

function Invoke-PitCrewCollectorTransport {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Ssh', 'WinRM')]
        [string]$ExecutionMode,

        [Parameter(Mandatory)]
        [string]$CollectorSource,

        [Parameter(Mandatory)]
        [string]$ArgumentsJson,

        [string]$SshHostName,

        [string]$SshUserName,

        [string]$SshKeyFilePath,

        [string]$WinRMComputerName,

        [PSCredential]$WinRMCredential,

        [scriptblock]$TransportInvoker
    )

    $remoteRunner = {
        param(
            [string]$CollectorSource,
            [string]$ArgumentsJson
        )

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $arguments = $ArgumentsJson |
            ConvertFrom-Json -AsHashtable -Depth 20
        $collector = [scriptblock]::Create($CollectorSource)
        $result = & $collector @arguments
        if (@($result).Count -ne 1 -or
            $null -eq $result.report -or
            $null -eq $result.markdown) {
            throw 'The fixed collector returned an invalid envelope.'
        }
        [PSCustomObject][ordered]@{
            reportJson = $result.report |
                ConvertTo-Json -Depth 100 -Compress
            markdown = [string]$result.markdown
        }
    }
    if ($null -ne $TransportInvoker) {
        $envelope = & $TransportInvoker `
            $ExecutionMode `
            $remoteRunner `
            $CollectorSource `
            $ArgumentsJson
    } elseif ($ExecutionMode -eq 'Ssh') {
        $invokeArguments = @{
            HostName = $SshHostName
            UserName = $SshUserName
            ScriptBlock = $remoteRunner
            ArgumentList = @($CollectorSource, $ArgumentsJson)
        }
        if (-not [string]::IsNullOrWhiteSpace($SshKeyFilePath)) {
            $invokeArguments.KeyFilePath = $SshKeyFilePath
        }
        $envelope = Invoke-Command @invokeArguments
    } else {
        $invokeArguments = @{
            ComputerName = $WinRMComputerName
            ScriptBlock = $remoteRunner
            ArgumentList = @($CollectorSource, $ArgumentsJson)
        }
        if ($null -ne $WinRMCredential) {
            $invokeArguments.Credential = $WinRMCredential
        }
        $envelope = Invoke-Command @invokeArguments
    }
    if (@($envelope).Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$envelope.reportJson) -or
        $null -eq $envelope.markdown) {
        throw 'The explicit remote transport returned an invalid collector envelope.'
    }
    return [PSCustomObject][ordered]@{
        report = $envelope.reportJson |
            ConvertFrom-Json -Depth 100 -ErrorAction Stop
        markdown = [string]$envelope.markdown
    }
}

function Complete-PitCrewCollectorTransport {
    param(
        [Parameter(Mandatory)][object]$Envelope,
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string]$CollectorSha256,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    $Envelope.report.collectorSha256 = $CollectorSha256
    return Write-PitCrewRemoteDiagnosticsArtifacts `
        -Envelope $Envelope `
        -OutputDirectory $OutputDirectory
}
