param(
    [string]$Workspace,
    [ValidateSet('suite', 'transfer', 'mutation')]
    [string]$Operation = 'suite',
    [ValidateSet('none', 'copy', 'ack', 'interrupt-before', 'interrupt-after')]
    [string]$Fault = 'none',
    [switch]$Reverse
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'RunnerProfiles.Functions.ps1')

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Docker([string[]]$Arguments) {
    $output = & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker operation failed: $($Arguments[0])" }
    return $output
}

function Get-Profile([string]$Side) {
    Resolve-RunnerProfile -RootPath (Join-Path $Workspace $Side) `
        -ProfilePath (Join-Path $Workspace 'profile.json') -HostName 'fixture'
}

function Read-Receipt {
    Read-RunnerJsonFile -Path (Join-Path $Workspace 'cutover.json')
}

function Set-Receipt([string]$Phase, [string]$Authority) {
    Write-RunnerJsonAtomically -Path (Join-Path $Workspace 'cutover.json') -Value @{
        phase = $Phase
        authority = $Authority
    }
    foreach ($side in @('a', 'b')) {
        Write-RunnerJsonAtomically -Path (Join-Path (Get-Profile $side).StateDirectory 'relocation.json') -Value @{
            schemaVersion = 1
            operationId = $configuration.operationId
            role = if ($side -eq $Authority) { 'target' } else { 'source' }
            status = if ($Phase -eq 'committed') { 'committed' } else { 'prepared' }
        }
    }
}

function Start-Manager($Profile) {
    $script:composePath = Join-Path $Profile.RootPath 'docker-compose.yml'
    $script:githubAppManagerComposePath = Join-Path $Profile.RootPath 'github-app.manager.compose.yml'
    Invoke-RunnerCompose -ProfileConfig $Profile -CommandArguments @(
        'up', '-d', '--no-build', '--no-deps', '--force-recreate', 'runner-manager'
    )
}

function Stop-Manager($Profile) {
    $id = Get-RunnerManagerContainerId -ProfileConfig $Profile
    Assert-That ([bool]$id) 'Expected exactly one running test manager.'
    Assert-That ((Get-RunnerManagerContractVersion -ContainerId $id) -ge 9) `
        'Prototype requires non-destructive manager handoff.'
    Stop-RunnerManagerForHandoff -ProfileConfig $Profile -ContainerId $id
    Assert-That (-not (Get-RunnerManagerContainerId -ProfileConfig $Profile)) `
        'Manager was not quiescent before state transfer.'
}

function Copy-FinalState($Source, $Target) {
    # This transfer is fixture-only: no real registration material is present.
    foreach ($item in Get-ChildItem -LiteralPath $Target.StateDirectory -Force) {
        if ($item.Name -notin @('setup.lock', 'relocation.json')) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
        }
    }
    foreach ($item in Get-ChildItem -LiteralPath $Source.StateDirectory -Force) {
        if ($item.Name -notin @('setup.lock', 'relocation.json')) {
            Copy-Item -LiteralPath $item.FullName -Destination $Target.StateDirectory -Recurse
        }
    }
    Copy-Item -LiteralPath $Source.EnvironmentPath -Destination $Target.EnvironmentPath -Force
    Remove-Item -LiteralPath $Target.CapacityAcknowledgementPath -ErrorAction SilentlyContinue
}

function Wait-Manager($Profile, [string]$PreviousInstance = '') {
    $generation = (Read-RunnerJsonFile -Path $Profile.DesiredCapacityPath).generation
    $acknowledgement = Wait-RunnerCapacityAcknowledgement -ProfileConfig $Profile -Generation $generation `
        -TimeoutSeconds 60 -MinimumManagerContractVersion 9
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $observed = if (Test-Path -LiteralPath $Profile.ObservedStatePath) {
            Read-RunnerJsonFile -Path $Profile.ObservedStatePath
        } else { $null }
        if ($observed -and $observed.managerStatus -eq 'running' -and
            $observed.managerInstanceId -ne $PreviousInstance -and
            $observed.desiredStateHash -ceq $acknowledgement.desiredStateHash -and
            [DateTimeOffset]$observed.observedAt -gt [DateTimeOffset]::UtcNow.AddSeconds(-15)) {
            return $observed
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Replacement manager did not publish fresh running state.'
}

function Invoke-Transfer {
    $sourceSide = if ($Reverse) { 'b' } else { 'a' }
    $targetSide = if ($Reverse) { 'a' } else { 'b' }
    $source = Get-Profile $sourceSide
    $target = Get-Profile $targetSide
    $locks = [Collections.Generic.List[IDisposable]]::new()
    try {
        foreach ($side in @('a', 'b')) {
            $locks.Add((Enter-RunnerProfileLock -Path (Get-Profile $side).LockPath `
                -TimeoutSeconds 2 -RelocationId $configuration.operationId))
        }
        $receipt = Read-Receipt
        Assert-That ($receipt.phase -eq 'committed' -and $receipt.authority -eq $sourceSide) `
            'Prototype source is retired or cutover requires reconciliation.'
        $engine = [string](Invoke-Docker @('info', '--format', '{{.ID}}'))
        Assert-That ($engine.Trim() -eq $configuration.engine) 'Docker engine fence moved.'
        $before = Read-RunnerJsonFile -Path $source.ObservedStatePath
        Set-Receipt 'source-quiescing' $sourceSide
        Stop-Manager $source
        Set-Receipt 'source-quiesced' $sourceSide
        if ($Fault -eq 'copy') {
            Copy-Item -LiteralPath $source.DesiredCapacityPath -Destination $target.DesiredCapacityPath
            Set-Receipt 'rollback-required' $sourceSide
            throw 'Injected copy failure.'
        }
        Copy-FinalState $source $target
        if ($Fault -eq 'interrupt-before') {
            Set-Receipt 'interrupt-before' $sourceSide
            while ($true) { Start-Sleep -Seconds 1 }
        }
        # Persist uncertainty before issuing a start: client death must not imply no manager.
        Set-Receipt 'target-starting' $targetSide
        Start-Manager $target
        if ($Fault -eq 'interrupt-after') {
            Set-Receipt 'interrupt-after' $targetSide
            while ($true) { Start-Sleep -Seconds 1 }
        }
        if ($Fault -eq 'ack') {
            Set-Receipt 'indeterminate' $targetSide
            throw 'Injected acknowledgement failure after target startup.'
        }
        Wait-Manager $target $before.managerInstanceId | Out-Null
        Set-Receipt 'committed' $targetSide
    } finally {
        foreach ($lock in $locks) { $lock.Dispose() }
    }
}

Assert-That ($IsLinux -and $env:GITHUB_ACTIONS -eq 'true') `
    'This disposable Docker experiment runs only in Linux CI, never on a workstation.'
if ($Operation -ne 'suite') {
    Assert-That ($Workspace -and (Test-Path -LiteralPath (Join-Path $Workspace 'fixture.json'))) `
        'Only a generated disposable fixture is accepted.'
    $configuration = Read-RunnerJsonFile -Path (Join-Path $Workspace 'fixture.json')
    Assert-That ($configuration.profile -match '^migration-[a-f0-9]{12}$') 'Invalid fixture identity.'
    if ($Operation -eq 'transfer') {
        Invoke-Transfer
    } else {
        $lease = Enter-RunnerProfileLock -Path (Get-Profile 'a').LockPath -TimeoutSeconds 2
        try {
            $receipt = Read-Receipt
            Assert-That ($receipt.phase -eq 'committed' -and $receipt.authority -eq 'a') `
                'Prototype source is retired or cutover requires reconciliation.'
            Write-Host 'Mutation probe admitted the source.'
        } finally { $lease.Dispose() }
    }
    exit
}

Assert-That (-not $Workspace) 'The suite creates its own isolated workspace.'
$Workspace = Join-Path ([IO.Path]::GetTempPath()) "pitcrew-migration-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $Workspace | Out-Null
$profileName = "migration-$([guid]::NewGuid().ToString('N').Substring(0,12))"
$image = "pitcrew-fake-runner:$profileName"
$volume = "pitcrew-fixture-$profileName"
$children = [Collections.Generic.List[Diagnostics.Process]]::new()
$imageCreated = $false
$volumeCreated = $false
$configuration = @{
    profile = $profileName
    operationId = [guid]::NewGuid().ToString('D')
    engine = ([string](Invoke-Docker @('info', '--format', '{{.ID}}'))).Trim()
}
$results = [Collections.Generic.List[string]]::new()

function Start-Child([string]$ChildOperation, [string]$ChildFault = 'none', [switch]$Back) {
    $start = [Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath,
        '-Workspace', $Workspace, '-Operation', $ChildOperation, '-Fault', $ChildFault)) {
        $start.ArgumentList.Add($argument)
    }
    if ($Back) { $start.ArgumentList.Add('-Reverse') }
    $start.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($start)
    $children.Add($process)
    return $process
}

function Wait-Child($Process, [bool]$Success) {
    Assert-That ($Process.WaitForExit(120000)) 'Prototype child stalled.'
    Assert-That (($Process.ExitCode -eq 0) -eq $Success) 'Unexpected prototype child outcome.'
}

function Wait-Phase([string]$Phase, $Process) {
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        if ((Read-Receipt).phase -eq $Phase) { return }
        Assert-That (-not $Process.HasExited) "Child exited before phase $Phase."
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Child never reached exact phase $Phase."
}

function Read-Progress {
    [int]([string](Invoke-Docker @('exec', $script:worker, 'cat', '/tmp/progress'))).Trim()
}

function Assert-Worker {
    $ids = @(Invoke-Docker @('ps', '-q', '--filter', "label=ephemeral-managed-runner-profile=$profileName"))
    Assert-That ($ids.Count -eq 1 -and $ids[0] -eq $script:worker) 'Worker identity changed.'
    $before = Read-Progress
    Start-Sleep -Seconds 2
    Assert-That ((Read-Progress) -gt $before) 'Worker task stopped making progress.'
}

try {
    Write-RunnerJsonAtomically -Path (Join-Path $Workspace 'fixture.json') -Value $configuration
    foreach ($side in @('a', 'b')) {
        $destination = Join-Path $Workspace $side
        New-Item -ItemType Directory -Path $destination | Out-Null
        foreach ($name in @('Setup-Runner.ps1', 'Move-RunnerProfile.ps1', 'RunnerProfiles.Functions.ps1', 'runner-profile.schema.json',
            'docker-compose.yml', 'github-app.manager.compose.yml', 'manager')) {
            Copy-Item -LiteralPath (Join-Path $root $name) -Destination $destination -Recurse
        }
    }
    Write-RunnerJsonAtomically -Path (Join-Path $Workspace 'profile.json') -Value @{
        schemaVersion = 1; name = $profileName; image = $image; labels = @('migration-fixture')
        description = 'Disposable same-engine state-root handoff experiment.'
        replicas = 1; pullImage = $false; disableDefaultLabels = $true
        resources = @{ memory = '128m'; cpus = '0.25'; pids = 64 }
        readWriteVolumes = @(@{ name = 'handoff'; source = $volume })
    }
    $a = Get-Profile 'a'
    $b = Get-Profile 'b'
    Invoke-Docker @('build', '-q', '-t', $image, (Join-Path $PSScriptRoot 'fake-runner')) | Out-Null
    $imageCreated = $true
    Invoke-Docker @('volume', 'create', $volume) | Out-Null
    $volumeCreated = $true
    Invoke-Docker @('run', '--rm', '--mount', "type=volume,src=$volume,dst=/data",
        '--entrypoint', 'sh', $image, '-c', 'touch /data/migration-fixture') | Out-Null
    # The existing integration suite uses the same token-validation stub.
    function Invoke-RestMethod {
        param($Method, $Uri, $Headers, $ErrorAction)
        [pscustomobject]@{ token = 'integration-registration-token' }
    }
    & (Join-Path $a.RootPath 'Setup-Runner.ps1') -ProfilePath (Join-Path $Workspace 'profile.json') `
        -Token 'integration-token' -Repos 'https://github.com/example/integration=1' -NamePrefix $profileName
    Wait-Manager $a | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $ids = @(Invoke-Docker @('ps', '-q', '--filter', "label=ephemeral-managed-runner-profile=$profileName"))
        if ($ids.Count -eq 1) { break }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert-That ($ids.Count -eq 1) 'Expected exactly one disposable worker.'
    $script:worker = $ids[0]
    Start-Sleep -Seconds 2
    Assert-Worker
    $firstObserved = Read-RunnerJsonFile -Path $a.ObservedStatePath
    $firstDesired = Read-RunnerJsonFile -Path $a.DesiredCapacityPath
    & (Join-Path $root 'Move-RunnerProfile.ps1') -Profile $profileName -SourceRoot $a.RootPath `
        -DestinationRoot $b.RootPath -Apply -ExpectedManagerInstanceId $firstObserved.managerInstanceId `
        -ExpectedGeneration $firstDesired.generation -ExpectedDesiredStateHash $firstObserved.desiredStateHash
    Assert-Worker
    $sourceRejected = $false
    try {
        & (Join-Path $a.RootPath 'Setup-Runner.ps1') -ProfilePath (Join-Path $Workspace 'profile.json') `
            -CapacityOnly -NamePrefix $profileName
    } catch {
        $sourceRejected = $_.Exception.Message -match 'root is retired or relocation is incomplete'
    }
    Assert-That $sourceRejected 'Real Setup-Runner did not reject the retired source through its shared guard.'
    Remove-Item Function:\Invoke-RestMethod
    $targetDesired = Read-RunnerJsonFile -Path $b.DesiredCapacityPath
    $targetDesired.generation = [int]$targetDesired.generation + 1
    Write-RunnerJsonAtomically -Path $b.DesiredCapacityPath -Value $targetDesired
    $targetObserved = Wait-Manager $b
    $productLatestHash = (Get-FileHash $b.DesiredCapacityPath).Hash
    & (Join-Path $root 'Move-RunnerProfile.ps1') -Profile $profileName -SourceRoot $a.RootPath `
        -DestinationRoot $b.RootPath -Action rollback -Apply -ExpectedManagerInstanceId $targetObserved.managerInstanceId `
        -ExpectedGeneration $targetDesired.generation -ExpectedDesiredStateHash $targetObserved.desiredStateHash
    Assert-Worker
    Assert-That ((Get-FileHash $a.DesiredCapacityPath).Hash -ceq $productLatestHash) `
        'Product rollback lost the newer acknowledged desired state.'
    $results.Add('product-relocation-and-rollback: real command preserved the original progressing worker and newer state')
    $results.Add('product-source-fence: real Setup-Runner rejected the retired root')
    $desiredHash = (Get-FileHash $a.DesiredCapacityPath).Hash
    $staticHash = (Get-FileHash $a.StaticProfilePath).Hash
    $ownerHash = (Get-FileHash $a.SessionOwnerPath).Hash
    Set-Receipt 'committed' 'a'
    Wait-Child (Start-Child 'mutation') $true

    $copyFailure = Start-Child 'transfer' 'copy'
    Wait-Child $copyFailure $false
    Assert-That ((Read-Receipt).phase -eq 'rollback-required') 'Copy failure was not classified.'
    Assert-Worker
    Start-Manager $a
    Wait-Manager $a | Out-Null
    Set-Receipt 'committed' 'a'
    $results.Add('copy-failure: source resumed; same worker progressed')

    foreach ($phase in @('interrupt-before', 'interrupt-after')) {
        $child = Start-Child 'transfer' $phase
        Wait-Phase $phase $child
        $rejected = Start-Child 'mutation'
        Wait-Child $rejected $false
        $child.Kill()
        $child.WaitForExit()
        Assert-That ((Read-Receipt).phase -eq $phase) 'Interruption lost durable phase.'
        $rejected = Start-Child 'mutation'
        Wait-Child $rejected $false
        if ($phase -eq 'interrupt-before') {
            Assert-That (-not (Get-RunnerManagerContainerId -ProfileConfig $a)) 'Unexpected running manager.'
            Start-Manager $a
        } else {
            # Explicit reconciliation, not automatic rollback after ambiguous startup.
            Wait-Manager $b | Out-Null
            Stop-Manager $b
            Copy-FinalState $b $a
            Start-Manager $a
        }
        Wait-Manager $a | Out-Null
        Set-Receipt 'committed' 'a'
        Assert-Worker
        $results.Add("${phase}: durable fence survived client death; explicit recovery preserved worker")
    }

    $ackFailure = Start-Child 'transfer' 'ack'
    Wait-Child $ackFailure $false
    Assert-That ((Read-Receipt).phase -eq 'indeterminate') 'Ack failure was not indeterminate.'
    Assert-Worker
    Wait-Manager $b | Out-Null
    Set-Receipt 'committed' 'b'
    Wait-Child (Start-Child 'mutation') $false
    $sourceObserved = (Get-FileHash $a.ObservedStatePath).Hash
    Start-Sleep -Seconds 2
    Assert-That ((Get-FileHash $a.ObservedStatePath).Hash -eq $sourceObserved) 'Retired source kept publishing.'
    Assert-That ((Get-FileHash $b.DesiredCapacityPath).Hash -eq $desiredHash) 'Desired capacity changed.'
    Assert-That ((Get-FileHash $b.StaticProfilePath).Hash -eq $staticHash) 'Worker configuration changed.'
    Assert-That ((Get-FileHash $b.SessionOwnerPath).Hash -eq $ownerHash) 'Session owner changed.'
    $results.Add('ack-failure: target retained; no second manager; source mutation rejected')

    # A legitimate post-cutover desired-state update must survive reverse transfer.
    $desired = Read-RunnerJsonFile -Path $b.DesiredCapacityPath
    $desired.generation = [int]$desired.generation + 1
    Write-RunnerJsonAtomically -Path $b.DesiredCapacityPath -Value $desired
    Wait-Manager $b | Out-Null
    $latestHash = (Get-FileHash $b.DesiredCapacityPath).Hash
    Wait-Child (Start-Child 'transfer' 'none' -Back) $true
    Assert-That ((Get-FileHash $a.DesiredCapacityPath).Hash -eq $latestHash) 'Rollback lost newer state.'
    Assert-Worker
    $results.Add('rollback: latest acknowledged generation retained; same worker progressed')
    Wait-Child (Start-Child 'transfer') $true
    Assert-Worker
    $results.Add('handoff: final copy and new acknowledgement; same worker progressed')
    Stop-Manager $b
    Invoke-Docker @('exec', $script:worker, 'touch', '/mnt/pitcrew-data/handoff/finish') | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $remaining = @(Invoke-Docker @('ps', '-q', '--filter', "label=ephemeral-managed-runner-profile=$profileName"))
        if (-not $remaining.Count) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert-That ($remaining.Count -eq 0) 'Fixture did not exit naturally.'
    Invoke-Docker @('run', '--rm', '--mount', "type=volume,src=$volume,dst=/data",
        '--entrypoint', 'sh', $image, '-c', 'test -s /data/completed') | Out-Null
    $results.Add('completion: original worker finished naturally after all handoffs')
    $results | ForEach-Object { Write-Host "PASS $_" }
    if ($env:GITHUB_STEP_SUMMARY) {
        @(
            '## Disposable state-root prototype'
            ($results | ForEach-Object { "- PASS $_" })
            ''
            'Fixed fake-worker lifecycle only. Includes production Move-RunnerProfile, rollback and shared root fencing.'
            'Not proven: autoscaled listener migration, Windows/WSL mounts, real credentials, connector migration.'
        ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }
} finally {
    foreach ($child in $children) {
        if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
        $child.Dispose()
    }
    # Only exact randomly named fixture labels are eligible for cleanup.
    foreach ($label in @("ephemeral-runner-manager-profile=$profileName",
        "ephemeral-managed-runner-profile=$profileName")) {
        $ids = @(& docker ps -aq --filter "label=$label")
        if ($LASTEXITCODE -ne 0) { throw 'Fixture cleanup inventory failed.' }
        foreach ($id in $ids) { Invoke-Docker @('rm', '-f', $id) | Out-Null }
    }
    if ($volumeCreated) { Invoke-Docker @('volume', 'rm', $volume) | Out-Null }
    if ($imageCreated) { Invoke-Docker @('image', 'rm', $image) | Out-Null }
}
