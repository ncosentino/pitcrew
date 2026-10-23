#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'RunnerProfiles.Functions.ps1')
$fixture = Get-Content (Join-Path $root 'docs/examples/nested-docker-profile.json') -Raw
$temporary = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
$manifestPath = Join-Path $temporary 'profile.json'
try {
    $fixture | Set-Content $manifestPath -Encoding utf8
    $profile = Resolve-RunnerProfile -RootPath $root -ProfilePath $manifestPath
    if ($profile.Runtime.DockerMode -cne 'privileged-local' -or
        $profile.Runtime.DockerStorageBytes -ne 4294967296) {
        throw 'Nested runtime normalization did not retain the exact typed policy.'
    }
    $static = New-RunnerStaticProfileState -Profile $profile -Scope repo -OrgName '' -EnterpriseName ''
    if ($static.Configuration.workerRuntimeContractVersion -ne 4) {
        throw 'Nested workers did not select their dedicated runtime contract.'
    }
    $environment = New-RunnerEnvironmentContent -Profile $profile -AccessToken synthetic `
        -WorkerRevision ('a' * 64) -SessionOwner fixture -AssumeUnversionedCurrent $false `
        -ResolvedImageId ('sha256:' + ('b' * 64))
    if ($environment -notmatch 'PITCREW_WORKER_DOCKER_MODE=privileged-local' -or
        $environment -notmatch 'PITCREW_WORKER_DOCKER_STORAGE_BYTES=4294967296') {
        throw 'Nested runtime policy did not reach the manager environment.'
    }
    $cases = @(
        @{ Name = 'fixed'; Edit = { param($p) $p.Remove('autoscaling') | Out-Null }; Error = 'scale-set' }
        @{ Name = 'admission'; Edit = { param($p) $p.Remove('hostAdmission') | Out-Null }; Error = 'host admission' }
        @{ Name = 'mutable-image'; Edit = { param($p) $p.image = 'example/runner:latest' }; Error = 'immutable image digest' }
        @{ Name = 'swap'; Edit = { param($p) $p.resources.memorySwap = '9GiB' }; Error = 'swap-disabled' }
        @{ Name = 'storage'; Edit = { param($p) $p.runtime.docker.storage = '8GiB' }; Error = 'storage smaller' }
        @{ Name = 'cpu'; Edit = { param($p) $p.resources.Remove('cpus') | Out-Null }; Error = 'explicit CPU' }
        @{ Name = 'devices'; Edit = { param($p) $p.runtime.devices = @('kvm') }; Error = 'cannot combine' }
        @{ Name = 'unknown-mode'; Edit = { param($p) $p.runtime.docker.mode = 'host' }; Error = 'schema' }
        @{ Name = 'unknown-flag'; Edit = { param($p) $p.runtime.docker.flags = '--privileged' }; Error = 'schema' }
    )
    foreach ($case in $cases) {
        $manifest = $fixture | ConvertFrom-Json -AsHashtable
        & $case.Edit $manifest
        $manifest | ConvertTo-Json -Depth 20 | Set-Content $manifestPath -Encoding utf8
        $rejected = $false
        try {
            Resolve-RunnerProfile -RootPath $root -ProfilePath $manifestPath | Out-Null
        } catch {
            if ($_.Exception.Message -notmatch $case.Error) { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw "Invalid nested profile '$($case.Name)' was accepted." }
    }
    $ordinary = Resolve-RunnerProfile -RootPath $root -Profile android-emulator
    $before = New-RunnerStaticProfileState -Profile $ordinary -Scope repo -OrgName '' -EnterpriseName ''
    $ordinary.Runtime.PSObject.Properties.Remove('DockerMode')
    $ordinary.Runtime.PSObject.Properties.Remove('DockerStorageBytes')
    $legacy = New-RunnerStaticProfileState -Profile $ordinary -Scope repo -OrgName '' -EnterpriseName ''
    if ($before.Fingerprint -cne $legacy.Fingerprint -or
        $before.Configuration.workerRuntimeContractVersion -ne 3 -or
        $before.Configuration.runtime.PSObject.Properties['docker']) {
        throw 'Ordinary runtime identity or legacy-object compatibility changed.'
    }
    $tokens = $null
    $parseErrors = $null
    $setup = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'Setup-Runner.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'Setup could not be parsed for hermetic preflight coverage.' }
    $preflight = $setup.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-RunnerNestedDockerImage'
    }, $true).Body.GetScriptBlock()
    $script:dockerCalls = [Collections.Generic.List[string]]::new()
    $script:hostMetadata = 'linux|x86_64|2|name=seccomp'
    $script:imageMetadata = 'linux|amd64||0'
    function docker {
        $command = $args -join ' '
        $script:dockerCalls.Add($command)
        $global:LASTEXITCODE = 0
        switch ($args[0]) {
            info { return $script:hostMetadata }
            image { return $script:imageMetadata }
            run {
                if ($command -notmatch '--privileged --cgroupns private' -or
                    $command -notmatch 'PITCREW_NESTED_DOCKER_VERIFY_ONLY=1') {
                    throw 'Setup verification omitted the exact nested runtime contract.'
                }
                return
            }
            default { throw 'Unexpected Docker call in the hermetic nested preflight.' }
        }
    }
    & $preflight -Profile $profile
    if ($script:dockerCalls.Count -ne 3) { throw 'Supported setup preflight did not verify host, image and readiness.' }
    foreach ($metadata in @('linux|amd64|1001|0', 'linux|amd64|root|1', 'linux|arm64|root|0')) {
        $script:imageMetadata = $metadata
        $script:dockerCalls.Clear()
        $rejected = $false
        try { & $preflight -Profile $profile } catch {
            if ($_.Exception.Message -notmatch 'root-user image') { throw }
            $rejected = $true
        }
        if (-not $rejected -or $script:dockerCalls.Count -ne 2) {
            throw 'Unsupported image/user reached readiness execution.'
        }
    }
    Write-Host 'Nested Docker profile contracts passed; no Docker daemon was invoked.'
} finally {
    if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
    Remove-Item -LiteralPath $temporary -Force
}
