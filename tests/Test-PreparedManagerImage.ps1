#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $root 'RunnerProfiles.Functions.ps1')
$imageId = 'sha256:' + ('1' * 64)
$profile = [pscustomobject]@{
    RootPath = $root
    Name = 'example'
    ManagerContractVersion = (Get-RunnerImplementedManagerContract -RootPath $root).Implemented
}
$sourceHash = Get-RunnerBuildContextFingerprint `
    -ContextPath (Join-Path $root 'manager') -ExcludedPaths @() -IgnoreFileModes
$script:labels = @{
    'pitcrew.manager.source-sha256' = $sourceHash
    'pitcrew.manager.contract' = [string]$profile.ManagerContractVersion
}
$script:calls = [Collections.Generic.List[string]]::new()
$script:inspectExit = 0
function docker {
    $script:calls.Add($args -join ' ')
    if ($args[0] -eq 'image') {
        $global:LASTEXITCODE = $script:inspectExit
        $script:labels | ConvertTo-Json -Compress
    } else {
        $global:LASTEXITCODE = 0
    }
}
try {
    Use-RunnerPreparedManagerImage -ProfileConfig $profile -ImageId $imageId
    if ($calls.Count -ne 2 -or $calls[1] -cne
        "tag $imageId ephemeral-runner-manager:profile-example") {
        throw 'Prepared image was not assigned exclusively to the selected profile.'
    }
    foreach ($case in @('mutable-tag', 'missing-image', 'wrong-source', 'wrong-contract')) {
        $calls.Clear()
        $inspectExit = 0
        $labels['pitcrew.manager.source-sha256'] = $sourceHash
        $labels['pitcrew.manager.contract'] = [string]$profile.ManagerContractVersion
        $selectedImage = $imageId
        switch ($case) {
            'mutable-tag' { $selectedImage = 'example:latest' }
            'missing-image' { $inspectExit = 1 }
            'wrong-source' { $labels['pitcrew.manager.source-sha256'] = 'different' }
            'wrong-contract' { $labels['pitcrew.manager.contract'] = '0' }
        }
        $rejected = $false
        try {
            Use-RunnerPreparedManagerImage -ProfileConfig $profile -ImageId $selectedImage
        } catch {
            $rejected = $_.Exception.Message -match '^Prepared manager image '
        }
        if (-not $rejected -or @($calls | Where-Object { $_ -like 'tag *' }).Count -ne 0) {
            throw "Unsafe prepared image case was not rejected before tagging: $case"
        }
    }
} finally {
    Remove-Item Function:\docker
}
Write-Host 'Prepared manager image contracts passed.'
