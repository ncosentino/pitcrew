#Requires -Version 7.0
<#
.SYNOPSIS
Relocates one configured profile on the same Docker engine without rebuilding images.
.DESCRIPTION
Dry run is the default. Apply fences both roots, quiesces only the manager,
transfers final state and protected authentication files, and requires a fresh
target acknowledgement. Ambiguous startup leaves both roots fenced for reconciliation.
Windows-to-WSL relocation uses native PowerShell for target locks and lifecycle operations.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')][string]$Profile,
    [string]$SourceRoot = $PSScriptRoot,
    [Parameter(Mandatory)][string]$DestinationRoot,
    [string]$TargetDistribution = '',
    [switch]$Apply,
    [ValidateSet('move', 'rollback', 'target-check', 'target-prepare', 'target-material-check', 'target-start', 'target-quiesce')][string]$Action = 'move',
    [string]$OperationId = '',
    [string]$ExpectedEngine = '',
    [string]$ExpectedManagerInstanceId = '',
    [int]$ExpectedGeneration = 0,
    [string]$ExpectedDesiredStateHash = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RunnerProfiles.Functions.ps1')
if ($IsLinux -and (($Apply) -or $Action -in @('target-prepare', 'target-material-check', 'target-start', 'target-quiesce'))) {
    $uid = & id -u
    if ($LASTEXITCODE -ne 0 -or ([string]$uid).Trim() -ne '0') {
        throw 'Native relocation requires root authority for manager-owned protected state.'
    }
}

function Get-RelocationProfile([string]$RootPath) {
    $state = Join-Path $RootPath '.pitcrew-state' $Profile
    [pscustomobject]@{
        RootPath = $RootPath
        Name = $Profile
        EnvironmentPath = Join-Path $RootPath $(if ($Profile -eq 'default') { '.env' } else { ".env.$Profile" })
        StateDirectory = $state
        LockPath = Join-Path $state 'setup.lock'
        StaticProfilePath = Join-Path $state 'static-profile.json'
        DesiredCapacityPath = Join-Path $state 'desired-capacity.json'
        CapacityAcknowledgementPath = Join-Path $state 'acknowledged-capacity.json'
        ObservedStatePath = Join-Path $state 'observed-state.json'
        SessionOwnerPath = Join-Path $state 'manager-session-owner.txt'
        HostAdmission = $null
        ComposeProjectName = if ($Profile -eq 'default') { 'self-hosted-runner' } else { "self-hosted-runner-$Profile" }
        ManagedRunnerLabel = "ephemeral-managed-runner-profile=$Profile"
    }
}

function Assert-UnlinkedPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Relocation does not accept linked source or destination material.'
    }
}

function Get-EngineId {
    $id = & docker info --format '{{.ID}}'
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($id)) {
        throw 'Docker engine identity is unavailable.'
    }
    ([string]$id).Trim()
}

function Get-RelocationCodeHash([string]$Path) {
    Get-RunnerObjectFingerprint -Value ([IO.File]::ReadAllText($Path).Replace("`r`n", "`n"))
}

function Write-RelocationReceipt($Config, [string]$Role, [string]$Status, $Transfer) {
    Write-RunnerJsonAtomically -Path (Join-Path $Config.StateDirectory 'relocation.json') -Value ([ordered]@{
        schemaVersion = 1
        operationId = $OperationId
        role = $Role
        status = $Status
        transfer = $Transfer
    })
}

function Invoke-Target([string]$TargetAction) {
    $targetScript = if ($TargetDistribution) { "$DestinationRoot/Move-RunnerProfile.ps1" } else {
        Join-Path $DestinationRoot 'Move-RunnerProfile.ps1'
    }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
        $targetScript,
        '-Profile', $Profile, '-DestinationRoot', $DestinationRoot,
        '-Action', $TargetAction
    )
    if ($OperationId) { $arguments += @('-OperationId', $OperationId) }
    if ($ExpectedEngine) { $arguments += @('-ExpectedEngine', $ExpectedEngine) }
    if ($ExpectedManagerInstanceId) { $arguments += @('-ExpectedManagerInstanceId', $ExpectedManagerInstanceId) }
    if ($ExpectedGeneration -gt 0) { $arguments += @('-ExpectedGeneration', $ExpectedGeneration) }
    if ($ExpectedDesiredStateHash) { $arguments += @('-ExpectedDesiredStateHash', $ExpectedDesiredStateHash) }
    if ($TargetDistribution) {
        & wsl.exe --distribution $TargetDistribution --user root --exec pwsh @arguments
    } else {
        & pwsh @arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Native target action '$TargetAction' failed; inspect durable relocation receipts before recovery."
    }
}

function Copy-RelocationState($From, $To) {
    $sourceFiles = @{}
    $sourceItems = @(Get-ChildItem -LiteralPath $From.StateDirectory -Force -Recurse)
    foreach ($item in $sourceItems) {
        Assert-UnlinkedPath $item.FullName
        $relative = [IO.Path]::GetRelativePath($From.StateDirectory, $item.FullName)
        $sourceFiles[$relative] = $true
    }
    foreach ($item in Get-ChildItem -LiteralPath $To.StateDirectory -Force -Recurse -File) {
        Assert-UnlinkedPath $item.FullName
        $relative = [IO.Path]::GetRelativePath($To.StateDirectory, $item.FullName)
        if ($relative -notin @('setup.lock', 'relocation.json') -and
            ($relative -eq 'manager-shutdown.json' -or -not $sourceFiles.ContainsKey($relative))) {
            Remove-Item -LiteralPath $item.FullName -Force
        }
    }
    foreach ($item in $sourceItems) {
        $relative = [IO.Path]::GetRelativePath($From.StateDirectory, $item.FullName)
        if ($relative -in @('setup.lock', 'relocation.json', 'manager-shutdown.json')) { continue }
        $targetPath = Join-Path $To.StateDirectory $relative
        if ($item.PSIsContainer) {
            New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
            continue
        }
        $parent = Split-Path -Parent $targetPath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $temporaryPath = Join-Path $parent ".$($item.Name).$([guid]::NewGuid().ToString('N')).tmp"
        try {
            Copy-Item -LiteralPath $item.FullName -Destination $temporaryPath
            Complete-RunnerStagedFile -TemporaryPath $temporaryPath -Path $targetPath
        } finally {
            if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
        }
    }
}

function Copy-RelocationEnvironment($From, $To, [string]$KeyPath = '') {
    $environment = @(Get-Content -LiteralPath $From.EnvironmentPath -Encoding UTF8)
    $environment = @($environment | ForEach-Object {
        if ($_.StartsWith('PITCREW_STATE_DIR=')) { "PITCREW_STATE_DIR=.pitcrew-state/$Profile" }
        elseif ($KeyPath -and $_.StartsWith('PITCREW_GITHUB_APP_PRIVATE_KEY_SOURCE=')) {
            "PITCREW_GITHUB_APP_PRIVATE_KEY_SOURCE=$KeyPath"
        } else { $_ }
    })
    $staging = New-RunnerTextStagingFile -Path $To.EnvironmentPath -Value (($environment -join "`n") + "`n")
    Complete-RunnerStagedFile -TemporaryPath $staging -Path $To.EnvironmentPath
}

function Get-RelocationBuildState($Config, $Static, $Transfer) {
    if (-not $Static.configuration.build) { return $null }
    $replay = Resolve-RunnerProfile -RootPath $Config.RootPath -ProfilePath $Static.manifest.sourcePath
    $nativeState = New-RunnerStaticProfileState -Profile $replay -Scope $Static.configuration.scope `
        -OrgName ([string]$Static.configuration.organization) -EnterpriseName ([string]$Static.configuration.enterprise) `
        -ResolvedImageId $Static.configuration.resolvedImageId
    $portableHash = Get-RunnerBuildContextFingerprint -ContextPath $replay.Build.Context `
        -ExcludedPaths @((Split-Path -Parent $replay.StateDirectory), $replay.EnvironmentPath) -IgnoreFileModes
    if ($portableHash -cne $Transfer.portableBuildHash -or
        $nativeState.configuration.build.dockerfileSha256 -cne $Static.configuration.build.dockerfileSha256 -or
        (Get-RunnerObjectFingerprint -Value $nativeState.configuration.build.arguments) -cne
            (Get-RunnerObjectFingerprint -Value $Static.configuration.build.arguments)) {
        throw 'Native build material does not match the approved source bytes and arguments.'
    }
    return $nativeState.configuration.build
}

if ($Action -in @('target-check', 'target-prepare', 'target-material-check', 'target-start', 'target-quiesce')) {
    $destination = Get-RelocationProfile ([IO.Path]::GetFullPath($DestinationRoot))
    Assert-UnlinkedPath $destination.RootPath
    if ((Get-EngineId) -cne $ExpectedEngine) { throw 'Target Docker engine does not match the source.' }
    if ($IsLinux) {
        $filesystem = & findmnt -n -o FSTYPE -T $destination.RootPath
        if ($LASTEXITCODE -ne 0 -or ([string]$filesystem).Trim() -ne 'ext4') {
            throw 'The Linux relocation destination must be native ext4, not a Windows mount.'
        }
    }
    if ($Action -eq 'target-check') {
        foreach ($name in @('Move-RunnerProfile.ps1', 'RunnerProfiles.Functions.ps1', 'docker-compose.yml', 'github-app.manager.compose.yml', 'runner-profile.schema.json')) {
            [pscustomobject]@{ file = $name; sha256 = Get-RelocationCodeHash (Join-Path $destination.RootPath $name) } |
                ConvertTo-Json -Compress
        }
        exit
    }
    $id = [guid]::Empty
    if (-not [guid]::TryParse($OperationId, [ref]$id) -or $id -eq [guid]::Empty) {
        throw 'Target operations require a valid relocation operation identifier.'
    }
    $receiptPath = Join-Path $destination.StateDirectory 'relocation.json'
    if ($Action -eq 'target-prepare') {
        if ((Test-Path -LiteralPath $destination.StateDirectory) -or
            (Test-Path -LiteralPath $destination.EnvironmentPath) -or
            (Test-Path -LiteralPath (Join-Path $destination.RootPath '.pitcrew-private' $Profile)) -or
            (Test-Path -LiteralPath (Join-Path $destination.RootPath '.pitcrew-deployment' $Profile))) {
            throw 'Destination profile material already exists; refusing to overwrite it.'
        }
        $lease = Enter-RunnerProfileLock -Path $destination.LockPath -TimeoutSeconds 30
        try {
            Write-RelocationReceipt $destination 'target' 'prepared' $null
            if ($IsLinux) {
                & chmod 0700 $destination.RootPath $destination.StateDirectory
                if ($LASTEXITCODE -ne 0) { throw 'Cannot protect destination state.' }
            }
        } finally { $lease.Dispose() }
        exit
    }
    $lease = Enter-RunnerProfileLock -Path $destination.LockPath -TimeoutSeconds 30 -RelocationId $OperationId
    try {
        $receipt = Read-RunnerJsonFile -Path $receiptPath
        if ($receipt.operationId -cne $OperationId) { throw 'Target relocation identity does not match.' }
        if ($Action -eq 'target-quiesce') {
            if ($receipt.role -ne 'target' -or $receipt.status -notin @('committed', 'starting', 'indeterminate')) {
                throw 'Target is not an active or explicitly reconcilable relocation.'
            }
            $observed = Read-RunnerJsonFile -Path $destination.ObservedStatePath
            $desired = Read-RunnerJsonFile -Path $destination.DesiredCapacityPath
            $currentStatic = Read-RunnerJsonFile -Path $destination.StaticProfilePath
            if ($observed.managerInstanceId -cne $ExpectedManagerInstanceId -or
                $desired.generation -ne $ExpectedGeneration -or $observed.desiredStateHash -cne $ExpectedDesiredStateHash) {
                throw 'Rollback target fences moved.'
            }
            if ($currentStatic.workerRevision -cne $receipt.transfer.workerRevision) {
                throw 'Worker configuration changed after relocation; roll back that rollout separately first.'
            }
            $keySource = Get-RunnerEnvironmentFileValue -Path $destination.EnvironmentPath -Name 'PITCREW_GITHUB_APP_PRIVATE_KEY_SOURCE'
            $expectedKeySource = Join-Path $destination.RootPath '.pitcrew-private' $Profile 'github-app.pem'
            if ($keySource -and $keySource -cne $expectedKeySource) {
                throw 'Authentication moved outside the relocation-owned key path; reconcile it before rollback.'
            }
            $managerId = Get-RunnerManagerContainerId -ProfileConfig $destination
            if (-not $managerId -or (Get-RunnerManagerContractVersion -ContainerId $managerId) -lt 9) {
                throw 'Rollback requires one handoff-capable target manager.'
            }
            $currentImage = & docker inspect $managerId --format '{{.Image}}'
            if ($LASTEXITCODE -ne 0 -or ([string]$currentImage).Trim() -cne $receipt.transfer.managerImageId) {
                throw 'Manager image changed after relocation; refusing to quiesce it for this rollback.'
            }
            $transfer = $receipt.transfer
            $transfer.managerInstanceId = $ExpectedManagerInstanceId
            $transfer.desiredStateHash = $ExpectedDesiredStateHash
            Write-RelocationReceipt $destination 'source' 'prepared' $transfer
            Stop-RunnerManagerForHandoff -ProfileConfig $destination -ContainerId $managerId
            if (Get-RunnerManagerContainerId -ProfileConfig $destination) { throw 'Rollback target did not quiesce.' }
            $transfer.staticHash = (Get-FileHash $destination.StaticProfilePath).Hash
            $transfer.desiredHash = (Get-FileHash $destination.DesiredCapacityPath).Hash
            $transfer.ownerHash = (Get-FileHash $destination.SessionOwnerPath).Hash
            Write-RelocationReceipt $destination 'source' 'quiesced' $transfer
            exit
        }
        if ($receipt.role -ne 'target' -or $receipt.status -ne 'prepared' -or -not $receipt.transfer) {
            throw 'Target is not prepared with a completed final transfer.'
        }
        $transfer = $receipt.transfer
        $static = Read-RunnerJsonFile -Path $destination.StaticProfilePath
        $nativeBuild = Get-RelocationBuildState $destination $static $transfer
        if ($Action -eq 'target-material-check') {
            $transfer.nativeBuild = $nativeBuild
            Write-RelocationReceipt $destination 'target' 'prepared' $transfer
            exit
        }
        if ($nativeBuild -and $nativeBuild.contextSha256 -cne $transfer.nativeBuild.contextSha256 -and
            $nativeBuild.contextSha256 -cne $static.configuration.build.contextSha256) {
            throw 'Native build permissions or inputs moved after material qualification.'
        }
        $desired = Read-RunnerJsonFile -Path $destination.DesiredCapacityPath
        if ((Get-FileHash $destination.StaticProfilePath).Hash -cne $transfer.staticHash -or
            (Get-FileHash $destination.DesiredCapacityPath).Hash -cne $transfer.desiredHash -or
            (Get-FileHash $destination.SessionOwnerPath).Hash -cne $transfer.ownerHash) {
            throw 'Transferred immutable state or session ownership changed.'
        }
        if (Get-RunnerManagerContainerId -ProfileConfig $destination) {
            throw 'A manager is already running; target startup requires reconciliation.'
        }
        $imageId = & docker image inspect "ephemeral-runner-manager:profile-$Profile" --format '{{.Id}}'
        if ($LASTEXITCODE -ne 0 -or ([string]$imageId).Trim() -cne $transfer.managerImageId) {
            throw 'Manager image moved; relocation never pulls or rebuilds images.'
        }
        $revision = Get-RunnerEnvironmentFileValue -Path $destination.EnvironmentPath -Name 'PITCREW_WORKER_REVISION'
        if ($revision -cne $static.workerRevision) { throw 'Transferred worker revision does not match static state.' }
        $workerImageId = & docker image inspect $static.configuration.image --format '{{.Id}}'
        if ($LASTEXITCODE -ne 0 -or ([string]$workerImageId).Trim() -cne $static.configuration.resolvedImageId) {
            throw 'Worker image identity moved; relocation never pulls or rebuilds it.'
        }
        if ($IsLinux) {
            & chmod -R go-rwx $destination.StateDirectory
            if ($LASTEXITCODE -ne 0) { throw 'Cannot protect transferred private state.' }
            & chmod 0600 $destination.EnvironmentPath
            if ($LASTEXITCODE -ne 0) { throw 'Cannot protect destination environment.' }
            $privateDirectory = Join-Path $destination.RootPath '.pitcrew-private' $Profile
            if (Test-Path -LiteralPath $privateDirectory) {
                & chmod -R go-rwx $privateDirectory
                if ($LASTEXITCODE -ne 0) { throw 'Cannot protect destination authentication files.' }
            }
        }
        if (Test-Path -LiteralPath $destination.CapacityAcknowledgementPath) {
            Remove-Item -LiteralPath $destination.CapacityAcknowledgementPath
        }
        Write-RelocationReceipt $destination 'target' 'starting' $transfer
        Invoke-RunnerCompose -ProfileConfig $destination -CommandArguments @(
            'up', '-d', '--no-build', '--no-deps', '--force-recreate', 'runner-manager'
        )
        $timeout = Get-RunnerManagerAcknowledgementTimeoutSeconds -Autoscaling $static.configuration.autoscaling
        $ack = Wait-RunnerCapacityAcknowledgement -ProfileConfig $destination `
            -Generation $desired.generation -TimeoutSeconds $timeout -MinimumManagerContractVersion 9
        $watch = [Diagnostics.Stopwatch]::StartNew()
        do {
            $observed = Read-RunnerJsonFile -Path $destination.ObservedStatePath
            $fresh = $observed.managerStatus -eq 'running' -and
                -not [string]::IsNullOrWhiteSpace($observed.managerInstanceId) -and
                $observed.managerInstanceId -cne $transfer.managerInstanceId -and
                $observed.desiredStateHash -ceq $transfer.desiredStateHash -and
                [DateTimeOffset]$observed.observedAt -gt [DateTimeOffset]::UtcNow.AddSeconds(-30)
            if ($fresh) { break }
            Start-Sleep -Milliseconds 200
        } while ($watch.Elapsed.TotalSeconds -lt $timeout)
        if ($ack.desiredStateHash -cne $transfer.desiredStateHash -or -not $fresh) {
            throw 'Replacement manager did not publish fresh compatible state.'
        }
        $managerId = Get-RunnerManagerContainerId -ProfileConfig $destination
        if (-not $managerId) { throw 'Replacement manager is no longer running.' }
        $runningImage = & docker inspect $managerId --format '{{.Image}}'
        if ($LASTEXITCODE -ne 0 -or ([string]$runningImage).Trim() -cne $transfer.managerImageId) {
            throw 'Replacement manager identity moved before commit.'
        }
        Write-RelocationReceipt $destination 'target' 'committed' $transfer
        if ($IsWindows) {
            $attributes = [IO.File]::GetAttributes($destination.LockPath)
            [IO.File]::SetAttributes($destination.LockPath, ($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
        }
        Write-Host "Profile '$Profile' acknowledged generation $($desired.generation) at the native destination."
    } catch {
        if (Test-Path -LiteralPath $receiptPath) {
            $failed = Read-RunnerJsonFile -Path $receiptPath
            if ($failed.status -eq 'starting') {
                Write-RelocationReceipt $destination 'target' 'indeterminate' $failed.transfer
            }
        }
        throw
    } finally { $lease.Dispose() }
    exit
}

$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$source = Get-RelocationProfile $SourceRoot
Assert-UnlinkedPath $SourceRoot
Assert-UnlinkedPath $source.StateDirectory
Assert-UnlinkedPath $source.EnvironmentPath
if ($TargetDistribution) {
    if (-not $IsWindows -or $TargetDistribution -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$' -or
        $DestinationRoot -notmatch '^/[a-zA-Z0-9_./-]+$' -or $DestinationRoot.Contains('..')) {
        throw 'Windows-to-WSL relocation requires an explicit safe native destination and distribution.'
    }
    $destinationFiles = "\\wsl.localhost\$TargetDistribution" + $DestinationRoot.Replace('/', '\')
} else {
    $DestinationRoot = [IO.Path]::GetFullPath($DestinationRoot)
    $destinationFiles = $DestinationRoot
}
if ($SourceRoot -eq $destinationFiles) { throw 'Source and destination roots must differ.' }
$destination = Get-RelocationProfile $destinationFiles
if ($Action -eq 'rollback') {
    if (-not $Apply -or -not $ExpectedManagerInstanceId -or $ExpectedGeneration -le 0 -or -not $ExpectedDesiredStateHash) {
        throw 'Rollback requires -Apply and explicit current target instance, generation and desired-state-hash fences.'
    }
    $prior = Read-RunnerJsonFile -Path (Join-Path $source.StateDirectory 'relocation.json')
    $OperationId = [string]$prior.operationId
    $currentEngine = Get-EngineId
    if ($ExpectedEngine -and $ExpectedEngine -cne $currentEngine) { throw 'Expected source engine identity moved.' }
    if ($currentEngine -cne $prior.transfer.engineId -or
        $prior.transfer.sourceRoot -cne $SourceRoot -or $prior.transfer.targetRoot -cne $DestinationRoot -or
        $prior.transfer.targetDistribution -cne $TargetDistribution) {
        throw 'Rollback engine or root identity does not match the original relocation.'
    }
    $ExpectedEngine = $currentEngine
    $lease = Enter-RunnerProfileLock -Path $source.LockPath -TimeoutSeconds 30 -RelocationId $OperationId
    try {
        if ($prior.role -ne 'source') { throw 'The original source is not retired.' }
        Invoke-Target 'target-quiesce'
        $quiesced = Read-RunnerJsonFile -Path (Join-Path $destination.StateDirectory 'relocation.json')
        if ($quiesced.operationId -cne $OperationId -or $quiesced.status -ne 'quiesced') {
            throw 'Target final state is not fenced and quiescent.'
        }
        $restoredKeyPath = ''
        $nativeKeySource = Get-RunnerEnvironmentFileValue -Path $destination.EnvironmentPath -Name 'PITCREW_GITHUB_APP_PRIVATE_KEY_SOURCE'
        if ($nativeKeySource) {
            $keyFile = Join-Path $destinationFiles '.pitcrew-private' $Profile 'github-app.pem'
            Assert-UnlinkedPath $keyFile
            $sourcePrivate = Join-Path $SourceRoot '.pitcrew-private' $Profile
            New-Item -ItemType Directory -Path $sourcePrivate -Force | Out-Null
            if ($IsLinux) {
                & chmod 0700 $sourcePrivate
                if ($LASTEXITCODE -ne 0) { throw 'Cannot protect rollback authentication directory.' }
            }
            $restoredKeyPath = Join-Path $sourcePrivate "github-app-rollback-$OperationId.pem"
            Copy-Item -LiteralPath $keyFile -Destination $restoredKeyPath
        }
        $originalManifest = (Read-RunnerJsonFile -Path $source.StaticProfilePath).manifest
        Copy-RelocationState $destination $source
        Copy-RelocationEnvironment $destination $source $restoredKeyPath
        $restoredStatic = Read-RunnerJsonFile -Path $source.StaticProfilePath
        $restoredStatic.manifest = $originalManifest
        Write-RunnerJsonAtomically -Path $source.StaticProfilePath -Value $restoredStatic
        $quiesced.transfer.staticHash = (Get-FileHash $source.StaticProfilePath).Hash
        Write-RelocationReceipt $source 'target' 'prepared' $quiesced.transfer
        # The local startup child owns its own lock after the final snapshot is complete.
        $lease.Dispose()
        & pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $SourceRoot 'Move-RunnerProfile.ps1') `
            -Profile $Profile -DestinationRoot $SourceRoot -Action target-start `
            -OperationId $OperationId -ExpectedEngine $ExpectedEngine
        if ($LASTEXITCODE -ne 0) { throw 'Rollback source startup is indeterminate; do not start another manager.' }
        Write-RelocationReceipt $destination 'source' 'committed' $quiesced.transfer
        Write-Host "Rollback committed for '$Profile' using the target's latest durable state."
    } finally { $lease.Dispose() }
    exit
}
$static = Read-RunnerJsonFile -Path $source.StaticProfilePath
$desired = Read-RunnerJsonFile -Path $source.DesiredCapacityPath
$observed = Read-RunnerJsonFile -Path $source.ObservedStatePath
if ($static.configuration.profile -cne $Profile -or $static.configuration.hostAdmission) {
    throw 'Relocation requires exact profile identity with shared host admission disabled.'
}
if ($observed.managerStatus -ne 'running' -or
    [DateTimeOffset]$observed.observedAt -lt [DateTimeOffset]::UtcNow.AddSeconds(-120)) {
    throw 'Source manager evidence must be fresh and running before relocation.'
}
Assert-RunnerProfileOperationAuthority -Directory $source.StateDirectory
$currentEngine = Get-EngineId
if ($ExpectedEngine -and $ExpectedEngine -cne $currentEngine) { throw 'Expected source engine identity moved.' }
$ExpectedEngine = $currentEngine
$targetChecks = @(Invoke-Target 'target-check' | ForEach-Object { $_ | ConvertFrom-Json })
foreach ($check in $targetChecks) {
    if ((Get-RelocationCodeHash (Join-Path $SourceRoot $check.file)) -cne $check.sha256) {
        throw 'Source and target relocation/lifecycle/Compose code must match exactly.'
    }
}
if ($targetChecks.Count -ne 5) { throw 'Target preflight did not provide complete code identity.' }
Write-Host "Relocation dry run: '$Profile'; same engine; current manager and worker images; generation $($desired.generation)."
Write-Host 'Workers, capacity, routing, session ownership, NAS volumes and Docker remain unchanged.'
Write-Host 'Source setup becomes fenced; only the manager stops. No image pull, build or automatic ambiguous rollback.'
if (-not $Apply) { exit }
if (-not $ExpectedManagerInstanceId -or $ExpectedGeneration -le 0 -or -not $ExpectedDesiredStateHash) {
    throw 'Apply requires explicit current manager-instance, generation and desired-state-hash fences.'
}
if ($observed.managerInstanceId -cne $ExpectedManagerInstanceId -or $desired.generation -ne $ExpectedGeneration -or
    $observed.desiredStateHash -cne $ExpectedDesiredStateHash) {
    throw 'Source fences changed; no relocation started.'
}
$OperationId = [guid]::NewGuid().ToString('D')
$lease = Enter-RunnerProfileLock -Path $source.LockPath -TimeoutSeconds 30
$targetStartRequested = $false
$sourceStopped = $false
try {
    $recheck = Read-RunnerJsonFile -Path $source.ObservedStatePath
    $desired = Read-RunnerJsonFile -Path $source.DesiredCapacityPath
    if ($recheck.managerInstanceId -cne $ExpectedManagerInstanceId -or $desired.generation -ne $ExpectedGeneration -or
        $recheck.desiredStateHash -cne $ExpectedDesiredStateHash -or (Get-EngineId) -cne $ExpectedEngine) {
        throw 'Source fences changed under the operation lock.'
    }
    $managerId = Get-RunnerManagerContainerId -ProfileConfig $source
    if (-not $managerId -or (Get-RunnerManagerContractVersion -ContainerId $managerId) -lt 9) {
        throw 'Relocation requires exactly one non-destructive handoff-capable manager.'
    }
    $managerImageId = & docker inspect $managerId --format '{{.Image}}'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot fence source manager image.' }
    $transfer = @{
        engineId = $ExpectedEngine
        sourceRoot = $SourceRoot
        targetRoot = $DestinationRoot
        targetDistribution = $TargetDistribution
        managerInstanceId = $ExpectedManagerInstanceId
        desiredStateHash = $ExpectedDesiredStateHash
        managerImageId = ([string]$managerImageId).Trim()
        staticHash = (Get-FileHash $source.StaticProfilePath).Hash
        desiredHash = (Get-FileHash $source.DesiredCapacityPath).Hash
        ownerHash = (Get-FileHash $source.SessionOwnerPath).Hash
        workerRevision = $static.workerRevision
        portableBuildHash = ''
        nativeBuild = $null
        workersBefore = @(Get-RunnerWorkerContainerIdList -ProfileConfig $source)
    }
    if ($static.configuration.build) {
        Assert-UnlinkedPath $static.configuration.build.context
        Assert-UnlinkedPath $static.configuration.build.dockerfile
        $exclusions = @((Split-Path -Parent $source.StateDirectory), $source.EnvironmentPath)
        $currentBuildHash = Get-RunnerBuildContextFingerprint -ContextPath $static.configuration.build.context `
            -ExcludedPaths $exclusions
        if ($currentBuildHash -cne $static.configuration.build.contextSha256 -or
            (Get-FileHash $static.configuration.build.dockerfile).Hash.ToLowerInvariant() -cne
                $static.configuration.build.dockerfileSha256) {
            throw 'Source build provenance changed; no relocation started.'
        }
        $transfer.portableBuildHash = Get-RunnerBuildContextFingerprint -ContextPath $static.configuration.build.context `
            -ExcludedPaths $exclusions -IgnoreFileModes
    }
    $keySource = Get-RunnerEnvironmentFileValue -Path $source.EnvironmentPath -Name 'PITCREW_GITHUB_APP_PRIVATE_KEY_SOURCE'
    if ($static.configuration.autoscaling -and -not $keySource) {
        throw 'Autoscaled relocation requires the existing protected GitHub App key source.'
    }
    if ($keySource) {
        Assert-UnlinkedPath $keySource
        $keyLease = [IO.File]::Open($keySource, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ($keyLease.Length -eq 0) { throw 'Protected key source is empty.' }
        } finally { $keyLease.Dispose() }
    }
    Invoke-Target 'target-prepare'
    $targetStatic = $null
    if ($static.manifest) {
        $manifestFiles = Join-Path $destinationFiles '.pitcrew-deployment' $Profile
        New-Item -ItemType Directory -Path $manifestFiles -Force | Out-Null
        $manifest = $static.manifest.document | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        if ($static.configuration.build) {
            $buildFiles = Join-Path $manifestFiles 'build'
            New-Item -ItemType Directory -Path $buildFiles -Force | Out-Null
            foreach ($item in Get-ChildItem -LiteralPath $static.configuration.build.context -Force -Recurse) {
                Assert-UnlinkedPath $item.FullName
                if ($item.Name -eq '.git' -or $item.Name -like '.env*' -or $item.Extension -in @('.pem', '.key')) {
                    throw 'Build-context relocation requires a credential-free, unlinked context.'
                }
            }
            foreach ($item in Get-ChildItem -LiteralPath $static.configuration.build.context -Force) {
                Assert-UnlinkedPath $item.FullName
                if ($item.Name -eq '.git' -or $item.Name -like '.env*' -or $item.Extension -in @('.pem', '.key')) {
                    throw 'Build-context relocation requires a credential-free, unlinked context.'
                }
                Copy-Item -LiteralPath $item.FullName -Destination $buildFiles -Recurse
            }
            $manifest.build.context = './build'
            $manifest.build.dockerfile = [IO.Path]::GetRelativePath(
                $static.configuration.build.context, $static.configuration.build.dockerfile).Replace('\', '/')
        }
        $manifestPath = Join-Path $manifestFiles 'profile.json'
        Write-RunnerJsonAtomically -Path $manifestPath -Value $manifest
        $targetStatic = $static.PSObject.Copy()
        $targetStatic.manifest.kind = 'external'
        $targetStatic.manifest.sourcePath = if ($TargetDistribution) {
            "$DestinationRoot/.pitcrew-deployment/$Profile/profile.json"
        } else { $manifestPath }
        $targetStatic.manifest.document = $manifest
        $targetStatic.manifest.sha256 = (Get-FileHash $manifestPath).Hash.ToLowerInvariant()
        Write-RunnerJsonAtomically -Path $destination.StaticProfilePath -Value $targetStatic
        Write-RelocationReceipt $destination 'target' 'prepared' $transfer
        Invoke-Target 'target-material-check'
        $materialReceipt = Read-RunnerJsonFile -Path (Join-Path $destination.StateDirectory 'relocation.json')
        if ($materialReceipt.operationId -cne $OperationId -or $materialReceipt.status -ne 'prepared') {
            throw 'Native material qualification lost the operation fence.'
        }
        $transfer.nativeBuild = $materialReceipt.transfer.nativeBuild
    }
    $nativeKeyPath = ''
    if ($keySource) {
        Assert-UnlinkedPath $keySource
        $privateFiles = Join-Path $destinationFiles '.pitcrew-private' $Profile
        New-Item -ItemType Directory -Path $privateFiles -Force | Out-Null
        Copy-Item -LiteralPath $keySource -Destination (Join-Path $privateFiles 'github-app.pem')
        $nativeKeyPath = if ($TargetDistribution) { "$DestinationRoot/.pitcrew-private/$Profile/github-app.pem" } else {
            Join-Path $privateFiles 'github-app.pem'
        }
    }
    Write-RelocationReceipt $source 'source' 'prepared' $transfer
    if ($IsWindows) {
        [IO.File]::SetAttributes($source.LockPath,
            ([IO.File]::GetAttributes($source.LockPath) -bor [IO.FileAttributes]::ReadOnly))
    }
    Stop-RunnerManagerForHandoff -ProfileConfig $source -ContainerId $managerId
    $sourceStopped = $true
    if (Get-RunnerManagerContainerId -ProfileConfig $source) { throw 'Source manager is not quiescent.' }
    Write-RelocationReceipt $source 'source' 'quiesced' $transfer
    Copy-RelocationState $source $destination
    if ($targetStatic) {
        Write-RunnerJsonAtomically -Path $destination.StaticProfilePath -Value $targetStatic
        $transfer.staticHash = (Get-FileHash $destination.StaticProfilePath).Hash
    }
    Copy-RelocationEnvironment $source $destination $nativeKeyPath
    Write-RelocationReceipt $destination 'target' 'prepared' $transfer
    Write-RelocationReceipt $source 'source' 'starting' $transfer
    $targetStartRequested = $true
    Invoke-Target 'target-start'
    $targetReceipt = Read-RunnerJsonFile -Path (Join-Path $destination.StateDirectory 'relocation.json')
    if ($targetReceipt.status -ne 'committed' -or $targetReceipt.operationId -cne $OperationId) {
        throw 'Target did not commit this exact relocation.'
    }
    $transfer.workersAfter = @(Get-RunnerWorkerContainerIdList -ProfileConfig $source)
    Write-RelocationReceipt $source 'source' 'committed' $transfer
    Write-Host "Relocation committed for '$Profile'. Source root is retired; target generation remains $ExpectedGeneration."
} catch {
    if ($sourceStopped -and -not $targetStartRequested) {
        if (Get-RunnerManagerContainerId -ProfileConfig $source) {
            Write-RelocationReceipt $source 'source' 'indeterminate' $transfer
        } else {
            $transfer.staticHash = (Get-FileHash $source.StaticProfilePath).Hash
            Write-RelocationReceipt $source 'target' 'prepared' $transfer
            $lease.Dispose()
            & pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $SourceRoot 'Move-RunnerProfile.ps1') `
                -Profile $Profile -DestinationRoot $SourceRoot -Action target-start `
                -OperationId $OperationId -ExpectedEngine $ExpectedEngine
            if ($LASTEXITCODE -ne 0) { throw 'Pre-start recovery failed; source remains fenced for reconciliation.' }
        }
    }
    throw
} finally { $lease.Dispose() }
