#Requires -Version 7.0
<#
.SYNOPSIS
    Builds a built-in runner profile image and validates its runtime contract.

.DESCRIPTION
    Resolves a profile manifest with the shared profile functions, builds its image
    with the manifest's pinned build arguments, and runs every verification command
    the setup script would run. Each verification command is repeated with Docker
    networking disabled so a prewarmed profile is proven to need no downloads at
    job time. Requires a working Docker daemon.

.PARAMETER Profile
    Built-in profile name under profiles/.

.EXAMPLE
    pwsh tests/Test-ProfileImage.ps1 -Profile dotnet-node
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Profile
)

$ErrorActionPreference = 'Stop'

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'RunnerProfiles.Functions.ps1')

$profileConfig = Resolve-RunnerProfile -RootPath $runnerRoot -Profile $Profile -HostName 'profile-image-test'
if (-not $profileConfig.Build) {
    throw "Profile '$Profile' does not build an image."
}
if ($profileConfig.VerificationCommands.Count -eq 0) {
    throw "Profile '$Profile' does not declare runtime verification commands."
}

Write-Host "[build] Building '$($profileConfig.Image)' for profile '$($profileConfig.Name)'"
$buildArguments = @(
    'build',
    '--file', $profileConfig.Build.Dockerfile,
    '--tag', $profileConfig.Image
)
foreach ($argument in $profileConfig.Build.Arguments.GetEnumerator()) {
    $buildArguments += @('--build-arg', "$($argument.Key)=$($argument.Value)")
}
$buildArguments += $profileConfig.Build.Context
& docker @buildArguments
if ($LASTEXITCODE -ne 0) {
    throw "Runner image build failed for profile '$($profileConfig.Name)'."
}

foreach ($network in @('bridge', 'none')) {
    foreach ($command in $profileConfig.VerificationCommands) {
        Write-Host "[verify] (network=$network) $command"
        & docker run --rm --network $network --entrypoint /bin/sh $profileConfig.Image -lc $command
        if ($LASTEXITCODE -ne 0) {
            throw "Runner image verification failed for profile '$($profileConfig.Name)' with network '$network': $command"
        }
    }
}

Write-Host "Profile image contract passed for '$($profileConfig.Name)'." -ForegroundColor Green
