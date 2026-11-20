# Проверки импорта на синтетических данных без изменения профилей Windows.
. (Get-WpmFunctionDefinitions -ScriptName 'ProfileMigration.ps1' -Name @(
    'Assert-ArchiveMetadata','Assert-WpmDirectoryChain','New-OperationStateDirectory',
    'Save-TrackedState','Get-TrackedStates','Enter-ProfileMutationLock','Assert-TrackedOperationStopped',
    'Assert-OperationTreeHasNoReparsePoint','Assert-SafeStaging','Resolve-ImportTarget',
    'Select-ImportDestination','Assert-NoUnreviewedImport'
))

function New-ImportTestMetadata {
    [pscustomobject]@{
        SchemaVersion=7;SourceAccount='SOURCE\пользователь';SourceSid='S-1-5-21-1-2-3-1001';
        SourceMachine='SOURCE';AccountType='Local'
    }
}
function New-ImportTestState([string]$Id = 'WPM_20260402_123456_789_abcdef012345') {
    @{
        Id=$Id;Kind='Импорт';Status='Начато';TargetAccount='TARGET\пользователь';
        USMTStarted=$false;USMTFinished=$false;CreatedByTool=$false
    }
}

Invoke-WpmTest 'Import metadata recognizes only supported integral schemas' {
    $script:SupportedArchiveSchemas = @(1,2,3,4,5,6,7)
    $meta = New-ImportTestMetadata
    Assert-ArchiveMetadata $meta $true
    $meta.SchemaVersion = 6
    Assert-ArchiveMetadata $meta
    Assert-WpmThrows { Assert-ArchiveMetadata $meta $true } 'не подтверждает'
    $meta.SchemaVersion = '7'
    Assert-WpmThrows { Assert-ArchiveMetadata $meta } 'Версия формата'
    $meta.SchemaVersion = 8
    Assert-WpmThrows { Assert-ArchiveMetadata $meta } 'Версия формата'
    $meta.SchemaVersion = 7.0
    Assert-WpmThrows { Assert-ArchiveMetadata $meta } 'Версия формата'
}

Invoke-WpmTest 'Import metadata rejects malformed identity and local namespace mismatch' {
    $script:SupportedArchiveSchemas = @(7)
    $meta = New-ImportTestMetadata
    $meta.SourceAccount = 'OTHER\пользователь'
    Assert-WpmThrows { Assert-ArchiveMetadata $meta } 'не соответствует'
    $meta.SourceAccount = 'SOURCE\user:override'
    Assert-WpmThrows { Assert-ArchiveMetadata $meta } 'Метаданные'
    $meta.SourceAccount = 'SOURCE\user'
    $meta.SourceSid = 'S-1-5-18'
    Assert-WpmThrows { Assert-ArchiveMetadata $meta } 'Метаданные'
    $meta.PSObject.Properties.Remove('SourceSid')
    Assert-WpmThrows { Assert-ArchiveMetadata $meta } 'SourceSid'
}

Invoke-WpmTest 'State replace preserves exactly one complete durable record' {
    $script:OpStateRoot = Join-Path $WpmTestRoot 'Operations'
    $state = New-ImportTestState
    Save-TrackedState $state
    $state.USMTStarted = $true
    $state.Status = 'LoadState выполняется'
    Save-TrackedState $state
    $records = @(Get-TrackedStates -RequireReadable)
    Assert-WpmEqual $records.Count 1
    Assert-WpmEqual $records[0].USMTStarted $true
    Assert-WpmEqual $records[0].Status 'LoadState выполняется'
    Assert-WpmEqual @(Get-ChildItem -LiteralPath $script:OpStateRoot -File).Count 1
    Assert-WpmThrows { Save-TrackedState @{Id='../invalid'} } 'идентификатор'
}

Invoke-WpmTest 'Corrupt retained operation cannot be mistaken for no prior import' {
    $script:OpStateRoot = Join-Path $WpmTestRoot 'Operations'
    $state = New-ImportTestState
    Save-TrackedState $state
    $file = Join-Path $script:OpStateRoot ($state.Id + '.json')
    [IO.File]::WriteAllText($file, '{')
    Assert-WpmThrows { Get-TrackedStates -RequireReadable } 'Не удалось проверить состояние'
}

Invoke-WpmTest 'Mutation lock rejects another writer and supports reacquisition' {
    $script:OpStateRoot = Join-Path $WpmTestRoot 'Operations'
    $lock = Enter-ProfileMutationLock
    try {
        Assert-WpmThrows { $conflicting = Enter-ProfileMutationLock; $conflicting.Dispose() } 'блокировку'
    } finally { $lock.Dispose() }
    $lock = Enter-ProfileMutationLock
    $lock.Dispose()
}

Invoke-WpmTest 'Recovery blocks active-process records but allows released records' {
    $state = [pscustomobject]@{ Id='active';ProcessId=$PID;ProcessStartTicks=0 }
    $process = Get-Process -Id $PID
    try { $state.ProcessStartTicks = $process.StartTime.ToUniversalTime().Ticks }
    finally { $process.Dispose() }
    $script:ActiveOpState = @{ Id=$state.Id }
    try {
        Assert-WpmThrows { Assert-TrackedOperationStopped $state } 'Операция выполняется'
        $state.ProcessId = 0
        Assert-TrackedOperationStopped $state
    } finally { $script:ActiveOpState = $null }
}

Invoke-WpmTest 'Interrupted import requires review for matching SID or saved name' {
    $script:OpStateRoot = Join-Path $WpmTestRoot 'Operations'
    $script:ActiveOpState = @{Id='current'}
    try {
        $prior = New-ImportTestState
        $prior.USMTStarted = $true
        $prior.TargetSid = 'S-1-5-21-1-2-3-1001'
        Save-TrackedState $prior
        $alias = [pscustomobject]@{Account='ALIAS\user';Sid=$prior.TargetSid}
        $sameName = [pscustomobject]@{Account=$prior.TargetAccount;Sid='S-1-5-21-1-2-3-1002'}
        Assert-WpmThrows { Assert-NoUnreviewedImport $alias } 'Проверьте её состояние'
        Assert-WpmThrows { Assert-NoUnreviewedImport $sameName } 'Проверьте её состояние'
        $prior.RecoveryReviewed = $true
        Save-TrackedState $prior
        Assert-NoUnreviewedImport $alias
    } finally { $script:ActiveOpState = $null }
}

Invoke-WpmTest 'Account creation without a saved SID requires review after interruption' {
    $script:OpStateRoot = Join-Path $WpmTestRoot 'Operations'
    $script:ActiveOpState = @{Id='current'}
    try {
        $prior = New-ImportTestState
        $prior.AccountCreationPending = $true
        Save-TrackedState $prior
        Assert-WpmThrows {
            Assert-NoUnreviewedImport ([pscustomobject]@{Account=$prior.TargetAccount;Sid=''})
        } 'Проверьте её состояние'
    } finally { $script:ActiveOpState = $null }
}

Invoke-WpmTest 'Account mapping substitutes only the destination computer and retains Unicode' {
    $savedComputer = $env:COMPUTERNAME
    $env:COMPUTERNAME = 'TARGET'
    function Get-ImportLocalUser([string]$Name) { return $null }
    try {
        $target = Resolve-ImportTarget (New-ImportTestMetadata) ''
        Assert-WpmEqual $target.Account 'TARGET\пользователь'
        Assert-WpmEqual $target.Mapping '/mu:SOURCE\пользователь:TARGET\пользователь'
        Assert-WpmEqual $target.CreateLocal $true
        Assert-WpmThrows { Resolve-ImportTarget (New-ImportTestMetadata) 'TARGET\CON' } 'Имя локальной'
        Assert-WpmThrows { Resolve-ImportTarget (New-ImportTestMetadata) 'TARGET\user:bad' } 'Неверное имя назначения'
    } finally { $env:COMPUTERNAME = $savedComputer }
}

Invoke-WpmTest 'Disabled and renamed built-in local accounts are blocked by state and SID' {
    $savedComputer = $env:COMPUTERNAME
    $env:COMPUTERNAME = 'TARGET'
    $user = [pscustomobject]@{ Name='test';Enabled=$false;SID=[pscustomobject]@{Value='S-1-5-21-1-2-3-1001'} }
    function Get-ImportLocalUser([string]$Name) { return $user }
    try {
        Assert-WpmThrows { Resolve-ImportTarget (New-ImportTestMetadata) 'TARGET\test' } 'отключена'
        $user.Enabled = $true
        $user.SID.Value = 'S-1-5-21-1-2-3-500'
        Assert-WpmThrows { Resolve-ImportTarget (New-ImportTestMetadata) 'TARGET\test' } 'Встроенная'
        $user.SID.Value = 'S-1-5-21-1-2-3-1001'
        $target = Resolve-ImportTarget (New-ImportTestMetadata) 'TARGET\test'
        Assert-WpmEqual $target.Sid $user.SID.Value
        Assert-WpmEqual $target.CreateLocal $false
    } finally { $env:COMPUTERNAME = $savedComputer }
}

Invoke-WpmTest 'Destination menu zero stops before reading a name' {
    function Title([string]$Value) {}
    function Choice([string]$Prompt,[int]$Maximum) { return 0 }
    function Read-Host { throw 'Unexpected prompt' }
    $selection = Select-ImportDestination (New-ImportTestMetadata)
    Assert-WpmEqual ($null -eq $selection) $true
}

Invoke-WpmTest 'Cleanup accepts only the direct owned staging directory' {
    $savedProgramData = $env:ProgramData
    $env:ProgramData = $WpmTestRoot
    try {
        $root = Join-Path $env:ProgramData 'WindowsProfileMigration\Staging'
        $valid = Join-Path $root 'ImportCache_20260402_123456_789_abcdef01'
        $nested = Join-Path (Join-Path $root 'other') 'ImportCache_20260402_123456_789_abcdef01'
        $prefixOnly = Join-Path $root 'ImportCache_unowned'
        [void][IO.Directory]::CreateDirectory($valid)
        Assert-WpmEqual (Assert-SafeStaging $valid) $valid
        Assert-WpmThrows { Assert-SafeStaging $nested } 'Очистка запрещена'
        Assert-WpmThrows { Assert-SafeStaging $prefixOnly } 'Очистка запрещена'
    } finally { $env:ProgramData = $savedProgramData }
}

function Invoke-ImportFixture([object]$Metadata,[int]$StagedSchema,[uint64]$Available,[scriptblock]$Verify) {
    . (Get-WpmFunctionDefinitions -ScriptName 'ProfileMigration.ps1' -Name @(
        'Do-Import','Read-ArchiveMetadataFile','Read-BoundedArchiveMetadata','Assert-NoReparseAncestor'))
    $archive = Join-Path $WpmTestRoot 'backup.zip'
    [IO.File]::WriteAllBytes($archive,[byte[]]@(1,2,3))
    $savedProgramData = $env:ProgramData
    $env:ProgramData = $WpmTestRoot
    $script:SupportedArchiveSchemas = @(1,2,3,4,5,6,7)
    $fixture = @{ ExpandCalls=0;VerifyCalls=0;CleanupCalls=0;LockCalls=0 }
    function Start-TrackedState([string]$Kind,[string]$Archive) {
        $script:ActiveOpState = @{ Status='Начато';USMTStarted=$false;USMTFinished=$false;CleanupDone=$false;StagingPath='' }
    }
    function Update-TrackedState([string]$Status,[hashtable]$Fields = @{}) {
        if ($Status) { $script:ActiveOpState.Status = $Status }
        foreach ($key in $Fields.Keys) { $script:ActiveOpState[$key] = $Fields[$key] }
    }
    function Advance-OperationStage([string]$Stage) {}
    function Write-OperationReport([string]$Category,[string]$Message) {}
    function Write-DiagnosticFailure([object]$ErrorRecord,[string]$Context) {}
    function Test-IsUncPath([string]$Path) { return $false }
    function Get-ProfileZipInfo([string]$Path) { return [pscustomobject]@{Metadata=$Metadata;ExpandedBytes=3} }
    function Get-PathFreeBytes([string]$Path) { return $Available }
    function Format-ByteSize([uint64]$Bytes) { return [string]$Bytes }
    function New-StagingDirectory([string]$Prefix) {
        $root = Join-Path $env:ProgramData 'WindowsProfileMigration\Staging'
        $path = Join-Path $root 'ImportCache_20260402_123456_789_abcde123'
        [void][IO.Directory]::CreateDirectory($path)
        return $path
    }
    function Expand-ProfileArchive([string]$ZipPath,[string]$Destination) {
        $fixture.ExpandCalls++
        [void][IO.Directory]::CreateDirectory($Destination)
        $meta = New-ImportTestMetadata
        $meta.SchemaVersion = $StagedSchema
        $meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'metadata.json') -Encoding UTF8
    }
    function Assert-ValidationManifestIntegrity([string]$Path,[object]$Meta) { $fixture.VerifyCalls++ }
    function Test-TargetFreeSpace([uint64]$Bytes) { throw 'Unexpected import target check' }
    function Enter-ProfileMutationLock { $fixture.LockCalls++; throw 'Unexpected import lock' }
    function Clear-TrackedStaging([hashtable]$State,[bool]$Ask) {
        $fixture.CleanupCalls++
        return $true
    }
    try {
        & $Verify $archive $fixture
    } finally {
        $env:ProgramData = $savedProgramData
        $script:ActiveOpState = $null
    }
}

Invoke-WpmTest 'Legacy ZIP fails before staging or target mutation in import mode' {
    $meta = New-ImportTestMetadata
    $meta.SchemaVersion = 6
    Invoke-ImportFixture $meta 6 3GB {
        param($archive,$fixture)
        Assert-WpmThrows { Do-Import 'unused' $false $archive } 'не подтверждает'
        Assert-WpmEqual $fixture.ExpandCalls 0
        Assert-WpmEqual $fixture.LockCalls 0
    }
}

Invoke-WpmTest 'Insufficient staging space fails before decompression' {
    Invoke-ImportFixture (New-ImportTestMetadata) 7 0 {
        param($archive,$fixture)
        Assert-WpmThrows { Do-Import 'unused' $false $archive } 'Недостаточно места'
        Assert-WpmEqual $fixture.ExpandCalls 0
        Assert-WpmEqual $fixture.LockCalls 0
    }
}

Invoke-WpmTest 'Changed staged archive schema fails before integrity or profile mutation' {
    Invoke-ImportFixture (New-ImportTestMetadata) 6 3GB {
        param($archive,$fixture)
        Assert-WpmThrows { Do-Import 'unused' $false $archive } 'не подтверждает'
        Assert-WpmEqual $fixture.ExpandCalls 1
        Assert-WpmEqual $fixture.VerifyCalls 0
        Assert-WpmEqual $fixture.CleanupCalls 1
        Assert-WpmEqual $fixture.LockCalls 0
    }
}
