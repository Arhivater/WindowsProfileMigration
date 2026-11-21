# Проверки импорта на синтетических данных без изменения профилей Windows.
. (Get-WpmFunctionDefinitions -ScriptName 'ProfileMigration.ps1' -Name @(
    'Assert-ArchiveMetadata','Assert-WpmDirectoryChain','New-WpmWorkDirectoryAcl','Assert-WpmWorkAcl',
    'Initialize-WpmWorkDirectory','Assert-WpmWorkRoot',
    'Save-TrackedState','Get-TrackedStates','Read-BoundedArchiveMetadata','Enter-ProfileMutationLock','Assert-TrackedOperationStopped',
    'Assert-OperationTreeHasNoReparsePoint','Assert-SafeStaging','Resolve-ImportTarget',
    'Select-ImportDestination','Assert-NoUnreviewedImport','Show-RecoveryMenu','Assert-RegularNetworkPartial',
    'Clear-NetworkPartial','Restore-PreviousDesktopLayout','Read-ExtraJson','Assert-ProfileExtraPath',
    'Get-ExtraStreamSha256','Test-ExtraPathComponent'
))

function Set-ImportTestDirectories([string]$Root) {
    $script:WpmWorkRoot = Join-Path $Root 'Private'
    $script:OpStateRoot = Join-Path $script:WpmWorkRoot 'Operations'
    $script:WpmStagingRoot = Join-Path $script:WpmWorkRoot 'Staging'
    $script:LegacyOpStateRoot = Join-Path $Root 'Legacy'
}
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
    Set-ImportTestDirectories $WpmTestRoot
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

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    Invoke-WpmTest 'Windows operation directories restrict access and the journal inherits their DACL' {
        Set-ImportTestDirectories $WpmTestRoot
        $state = New-ImportTestState
        Save-TrackedState $state
        $journal = Join-Path $script:OpStateRoot ($state.Id + '.json')
        $administrators = 'S-1-5-32-544'
        $system = 'S-1-5-18'
        $sidType = [Security.Principal.SecurityIdentifier]
        foreach ($path in @($script:WpmWorkRoot, $script:OpStateRoot, $journal)) {
            $isJournal = $path -eq $journal
            $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
            Assert-WpmEqual $acl.AreAccessRulesProtected (-not $isJournal) "DACL protection for $path"
            if (-not $isJournal) {
                Assert-WpmEqual ($acl.GetOwner($sidType).Value) $administrators "Directory owner for $path"
            }
            $rules = $acl.GetAccessRules($true, $true, $sidType)
            $identities = @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object)
            Assert-WpmEqual $identities @($system, $administrators) "Access identities for $path"
            foreach ($rule in $rules) {
                Assert-WpmEqual $rule.IsInherited $isJournal "Inherited rule for $path"
                Assert-WpmEqual $rule.AccessControlType ([Security.AccessControl.AccessControlType]::Allow) "Rule type for $path"
                Assert-WpmEqual $rule.FileSystemRights ([Security.AccessControl.FileSystemRights]::FullControl) "Access rights for $path"
                if (-not $isJournal) {
                    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
                    Assert-WpmEqual $rule.InheritanceFlags $inheritance "Directory inheritance for $path"
                    Assert-WpmEqual $rule.PropagationFlags ([Security.AccessControl.PropagationFlags]::None) "Rule propagation for $path"
                }
            }
        }
    }
}

Invoke-WpmTest 'Corrupt retained operation cannot be mistaken for no prior import' {
    Set-ImportTestDirectories $WpmTestRoot
    $state = New-ImportTestState
    Save-TrackedState $state
    $file = Join-Path $script:OpStateRoot ($state.Id + '.json')
    [IO.File]::WriteAllText($file, '{')
    Assert-WpmThrows { Get-TrackedStates -RequireReadable } 'Не удалось проверить состояние'
}

Invoke-WpmTest 'State reader rejects arrays and oversized journals' {
    Set-ImportTestDirectories $WpmTestRoot
    $state = New-ImportTestState
    Save-TrackedState $state
    $file = Join-Path $script:OpStateRoot ($state.Id + '.json')
    [IO.File]::WriteAllText($file,('[' + ($state | ConvertTo-Json -Depth 4) + ']'))
    Assert-WpmThrows { Get-TrackedStates -RequireReadable } 'Не удалось проверить состояние'
    $stream = [IO.File]::Open($file,'Open','Write','None')
    try { $stream.SetLength(2MB + 1) } finally { $stream.Dispose() }
    Assert-WpmThrows { Get-TrackedStates -RequireReadable } 'Не удалось проверить состояние'
}

Invoke-WpmTest 'Mutation lock rejects another writer and supports reacquisition' {
    Set-ImportTestDirectories $WpmTestRoot
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
    Set-ImportTestDirectories $WpmTestRoot
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
    Set-ImportTestDirectories $WpmTestRoot
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
    Set-ImportTestDirectories $WpmTestRoot
    $root = $script:WpmStagingRoot
    Initialize-WpmWorkDirectory $root
    $valid = Join-Path $root 'ImportCache_20260402_123456_789_abcdef01'
    $nested = Join-Path (Join-Path $root 'other') 'ImportCache_20260402_123456_789_abcdef01'
    $prefixOnly = Join-Path $root 'ImportCache_unowned'
    [void][IO.Directory]::CreateDirectory($valid)
    Assert-WpmEqual (Assert-SafeStaging $valid) $valid
    Assert-WpmThrows { Assert-SafeStaging $nested } 'Очистка запрещена'
    Assert-WpmThrows { Assert-SafeStaging $prefixOnly } 'Очистка запрещена'
}

function Invoke-ImportFixture([object]$Metadata,[int]$StagedSchema,[uint64]$Available,[scriptblock]$Verify) {
    . (Get-WpmFunctionDefinitions -ScriptName 'ProfileMigration.ps1' -Name @(
        'Do-Import','Read-ArchiveMetadataFile','Read-BoundedArchiveMetadata','Assert-NoReparseAncestor'))
    $archive = Join-Path $WpmTestRoot 'backup.zip'
    [IO.File]::WriteAllBytes($archive,[byte[]]@(1,2,3))
    Set-ImportTestDirectories $WpmTestRoot
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
        $root = $script:WpmStagingRoot
        Initialize-WpmWorkDirectory $root
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

function Write-LegacyTestState([hashtable]$Record) {
    [void][IO.Directory]::CreateDirectory($script:LegacyOpStateRoot)
    $path = Join-Path $script:LegacyOpStateRoot ($Record.Id + '.json')
    [IO.File]::WriteAllText($path,($Record | ConvertTo-Json -Depth 4))
    return $path
}

Invoke-WpmTest 'Legacy JSON is never a recovery mutation authority' {
    Set-ImportTestDirectories $WpmTestRoot
    $legacy = New-ImportTestState
    $legacy.CreatedByTool = $true
    $legacy.DesktopBackup = 'forged'
    $legacy.NetworkPartialPath = 'forged'
    $legacy.LastUpdated = '2026-04-02'
    $file = Write-LegacyTestState $legacy
    $original = [IO.File]::ReadAllText($file)
    $trace = @{ Choices=0 }
    function Title([string]$Label) {}
    function Choice([string]$Label,[int]$Options) {
        $trace.Choices++
        return 1
    }
    function Enter-ProfileMutationLock { throw 'Legacy state reached a mutation' }
    Show-RecoveryMenu
    Assert-WpmEqual $trace.Choices 1
    Assert-WpmEqual ([IO.File]::ReadAllText($file)) $original
    Assert-WpmEqual (Test-Path -LiteralPath $script:WpmWorkRoot) $false
}

Invoke-WpmTest 'Legacy interrupted matching import requires manual review despite untrusted reviewed flag' {
    Set-ImportTestDirectories $WpmTestRoot
    $script:ActiveOpState = @{Id='current'}
    try {
        $legacy = New-ImportTestState
        $legacy.USMTStarted = $true
        $legacy.RecoveryReviewed = $true
        [void](Write-LegacyTestState $legacy)
        Assert-WpmThrows {
            Assert-NoUnreviewedImport ([pscustomobject]@{Account=$legacy.TargetAccount;Sid=''})
        } 'старая незавершённая операция'
        Assert-NoUnreviewedImport ([pscustomobject]@{Account='OTHER\user';Sid='S-1-5-21-1-2-3-1001'})
    } finally { $script:ActiveOpState = $null }
}

Invoke-WpmTest 'Partial ZIP cleanup accepts one exact generated file only and preserves completed ZIP' {
    Set-ImportTestDirectories $WpmTestRoot
    function Write-OperationReport([string]$Category,[string]$Message) {}
    $archive = Join-Path $WpmTestRoot 'profile.zip'
    $temp = $archive + '.partial_a123bcde'
    $state = New-ImportTestState
    $state.Kind = 'Экспорт'
    $state.SourceArchive = $archive
    $state.NetworkPartialPath = $archive + '.partial_unowned'
    Assert-WpmThrows { Clear-NetworkPartial $state $false } 'Подозрительное имя'
    $state.NetworkPartialPath = $temp
    [void][IO.Directory]::CreateDirectory($temp)
    Assert-WpmThrows { Clear-NetworkPartial $state $false } 'обычным файлом'
    Assert-WpmEqual (Test-Path -LiteralPath $temp -PathType Container) $true
    [IO.Directory]::Delete($temp)
    [IO.File]::WriteAllText($archive,'completed archive')
    [IO.File]::WriteAllText($temp,'partial archive')
    Clear-NetworkPartial $state $false
    Assert-WpmEqual (Test-Path -LiteralPath $temp) $false
    Assert-WpmEqual ([IO.File]::ReadAllText($archive)) 'completed archive'
}

Invoke-WpmTest 'Desktop rollback rejects missing or tampered trusted digest before registry' {
    Set-ImportTestDirectories $WpmTestRoot
    $root = Join-Path $script:WpmWorkRoot 'DesktopBackups'
    Initialize-WpmWorkDirectory $root
    $file = Join-Path $root 'Desktop_00112233445566778899aabbccddeeff.json'
    [IO.File]::WriteAllText($file,'original')
    $digest = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($file,'tampered')
    function Get-CimInstance { throw 'Unexpected profile lookup' }
    Assert-WpmThrows { Restore-PreviousDesktopLayout $file '' } 'контрольная сумма'
    Assert-WpmThrows { Restore-PreviousDesktopLayout $file $digest } 'изменился после проверки'
}

Invoke-WpmTest 'Private work initializer rejects paths outside its direct child boundary' {
    Set-ImportTestDirectories $WpmTestRoot
    $outside = Join-Path $WpmTestRoot 'Outside'
    $nested = Join-Path $script:WpmStagingRoot 'Nested'
    Assert-WpmThrows { Initialize-WpmWorkDirectory $outside } 'Недопустимый рабочий каталог'
    Assert-WpmThrows { Initialize-WpmWorkDirectory $nested } 'Недопустимый рабочий каталог'
    Assert-WpmEqual (Test-Path -LiteralPath $outside) $false
}
