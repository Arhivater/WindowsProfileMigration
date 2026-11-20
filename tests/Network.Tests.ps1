#Requires -Version 5.1
. (Get-WpmFunctionDefinitions -Name @(
    'Read-RemoteTransferBlock','Get-RemoteTransferPrefixHash','Get-RemoteArchiveReceiver',
    'Send-RemoteArchive','Enter-RemoteMigration','Connect-RemoteMigration'))

function Format-ByteSize([UInt64]$Bytes) { return [string]$Bytes }
function Write-OperationReport([string]$Category,[string]$Message) {}
function Write-DiagnosticFailure($ErrorRecord,[string]$Context) {}
function Test-RunningProcessStopRequest([string]$Activity,[int]$ProgressId) { return $false }

Invoke-WpmTest 'Network receiver checks block hash and offset before publishing verified file' {
    $source = Join-Path $WpmTestRoot 'source.zip'
    $destination = Join-Path $WpmTestRoot 'destination.zip'
    [IO.File]::WriteAllBytes($source,[byte[]](1,2,3,4,5))
    $prefix = [IO.MemoryStream]::new([byte[]](1,2))
    $suffix = [IO.MemoryStream]::new([byte[]](3,4,5))
    try {
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $firstHash = (Get-FileHash -InputStream $prefix -Algorithm SHA256).Hash
        $lastHash = (Get-FileHash -InputStream $suffix -Algorithm SHA256).Hash
        $firstPayload = [Convert]::ToBase64String([byte[]](1,2))
        $lastPayload = [Convert]::ToBase64String([byte[]](3,4,5))
        $receiver = Get-RemoteArchiveReceiver
        Assert-WpmThrows { & $receiver 'append' $destination 5 $sourceHash 0 $lastHash $firstPayload } 'Контрольная сумма'
        Assert-WpmEqual (Test-Path -LiteralPath ($destination + '.partial')) $false
        Assert-WpmEqual (& $receiver 'append' $destination 5 $sourceHash 0 $firstHash $firstPayload) 2
        Assert-WpmThrows { & $receiver 'append' $destination 5 $sourceHash 0 $firstHash $firstPayload } 'Позиция записи'
        Assert-WpmThrows { & $receiver 'finish' $destination 5 $sourceHash } 'Размер или SHA'
        Assert-WpmEqual (Test-Path -LiteralPath $destination) $false
        $state = & $receiver 'state' $destination 5 $sourceHash
        Assert-WpmEqual $state.Offset 2
        Assert-WpmEqual $state.Hash $firstHash
        Assert-WpmEqual (& $receiver 'append' $destination 5 $sourceHash 2 $lastHash $lastPayload) 5
        & $receiver 'finish' $destination 5 $sourceHash
        Assert-WpmEqual (Test-Path -LiteralPath ($destination + '.partial')) $false
        Assert-WpmEqual ((& $receiver 'state' $destination 5 $sourceHash).Complete) $true
        Assert-WpmThrows { & $receiver 'state' $destination 5 $lastHash } 'Перезапись заблокирована'
    } finally {
        $prefix.Dispose()
        $suffix.Dispose()
    }
}

Invoke-WpmTest 'Network resume reuses committed bytes after a lost block acknowledgement' {
    $data = [byte[]]::new(2MB+17)
    for ($i=0; $i -lt $data.Length; $i+=137) { $data[$i] = [byte]($i % 251) }
    $destination = Join-Path $WpmTestRoot 'destination.zip'
    [IO.File]::WriteAllBytes(($destination + '.partial'),[byte[]]($data[0..4]))
    $source = [IO.MemoryStream]::new($data)
    $expectedHash = (Get-FileHash -InputStream $source -Algorithm SHA256).Hash
    $session = [pscustomobject]@{State='Opened'}
    $offsets = [Collections.Generic.List[long]]::new()
    function Remove-PSSession { param($Session,$ErrorAction) }
    function Start-Sleep { param($Seconds) }
    function Connect-RemoteMigration { param($Connection,$ExpectedComputer) return [pscustomobject]@{State='Opened'} }
    function Invoke-Command {
        param($Session,[scriptblock]$ScriptBlock,[object[]]$ArgumentList,$ErrorAction)
        $result = & $ScriptBlock @ArgumentList
        if ($ArgumentList[0] -eq 'append') {
            $offsets.Add([long]$ArgumentList[4])
            if ($offsets.Count -eq 1) {
                $Session.State = 'Broken'
                throw 'Simulated lost response after receiver flush'
            }
        }
        return $result
    }
    try {
        Send-RemoteArchive ([ref]$session) @{} @{} $source $destination $expectedHash 0
        Assert-WpmEqual @($offsets) @(5L,(2MB+5L))
        Assert-WpmEqual (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash $expectedHash
        Assert-WpmEqual $session.State 'Opened'
    } finally { $source.Dispose() }
}

Invoke-WpmTest 'Network refuses corrupted saved prefix, cancellation and insufficient space' {
    $destination = Join-Path $WpmTestRoot 'destination.zip'
    $partial = $destination + '.partial'
    [IO.File]::WriteAllBytes($partial,[byte[]](99,2))
    $source = [IO.MemoryStream]::new([byte[]](1,2,3,4,5))
    $expectedHash = (Get-FileHash -InputStream $source -Algorithm SHA256).Hash
    $session = [pscustomobject]@{State='Opened'}
    function Invoke-Command {
        param($Session,[scriptblock]$ScriptBlock,[object[]]$ArgumentList,$ErrorAction)
        & $ScriptBlock @ArgumentList
    }
    function Test-RunningProcessStopRequest([string]$Activity,[int]$ProgressId) { return $true }
    try {
        Assert-WpmThrows { Send-RemoteArchive ([ref]$session) @{} @{} $source $destination $expectedHash 0 } 'префикс ZIP'
        Assert-WpmEqual ([IO.File]::ReadAllBytes($partial)) ([byte[]](99,2))
        [IO.File]::WriteAllBytes($partial,[byte[]](1,2))
        Assert-WpmThrows { Send-RemoteArchive ([ref]$session) @{} @{} $source $destination $expectedHash ([long]::MaxValue-5) } 'Недостаточно места'
        Assert-WpmThrows { Send-RemoteArchive ([ref]$session) @{} @{} $source $destination $expectedHash 0 } 'передача отменена'
        Assert-WpmEqual ([IO.File]::ReadAllBytes($partial)) ([byte[]](1,2))
        Assert-WpmEqual (Test-Path -LiteralPath $destination) $false
    } finally { $source.Dispose() }
}

Invoke-WpmTest 'Network deployment lock and durable marker refuse ambiguous or different imports' {
    $started = Join-Path $WpmTestRoot 'import-started.txt'
    $done = Join-Path $WpmTestRoot 'import-completed.txt'
    $account = 'PC\User'
    $hash = 'A'*64
    $marker = $hash + ' ' + $account
    function Invoke-Command {
        param($Session,[scriptblock]$ScriptBlock,[object[]]$ArgumentList,$ErrorAction)
        & $ScriptBlock @ArgumentList
    }
    function Clear-WpmSyntheticRemoteLock {
        $lock = Get-Variable -Name WpmDeploymentLock -Scope Global -ErrorAction SilentlyContinue
        if ($lock) {
            $lock.Value.Dispose()
            Remove-Variable -Name WpmDeploymentLock -Scope Global
        }
    }
    try {
        Assert-WpmEqual (Enter-RemoteMigration $null $WpmTestRoot $hash $account) 'Ready'
        Assert-WpmThrows { Enter-RemoteMigration $null $WpmTestRoot $hash $account } 'другая операция'
        Clear-WpmSyntheticRemoteLock
        [IO.File]::WriteAllText($started,$marker)
        Assert-WpmThrows { Enter-RemoteMigration $null $WpmTestRoot $hash $account } 'мог начать LoadState'
        Clear-WpmSyntheticRemoteLock
        [IO.File]::WriteAllText($done,$marker)
        Assert-WpmEqual (Enter-RemoteMigration $null $WpmTestRoot $hash $account) 'Completed'
        Clear-WpmSyntheticRemoteLock
        Assert-WpmThrows { Enter-RemoteMigration $null $WpmTestRoot $hash 'PC\Different' } 'другом или повреждённом'
    } finally { Clear-WpmSyntheticRemoteLock }
}

Invoke-WpmTest 'Network reconnect rejects a different device with same hostname' {
    $existing = [pscustomobject]@{Name='PC'; Identity='First'; ProgramData='C:\ProgramData'}
    $fakeSession = [pscustomobject]@{Removed=$false}
    function New-PSSession { return $fakeSession }
    function Invoke-Command {
        param($Session,$ErrorAction,$ScriptBlock)
        return [pscustomobject]@{Name='PC'; Identity='Second'; ProgramData='C:\ProgramData'}
    }
    function Remove-PSSession { param($Session,$ErrorAction) $Session.Removed = $true }
    Assert-WpmThrows { Connect-RemoteMigration @{} $existing } 'другое устройство'
    Assert-WpmEqual $fakeSession.Removed $true
}
