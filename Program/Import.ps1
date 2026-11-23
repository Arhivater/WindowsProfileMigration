# Импорт проверяет архив и назначение до записи в профиль.

# Создаёт случайный пароль новой локальной учётной записи без записи в лог.
function New-StrongPassword {
    $buffer = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return ('A1!' + [Convert]::ToBase64String($buffer).TrimEnd('=').Replace('/','b').Replace('+','K'))
}
function Get-ImportLocalUser([string]$Name) {
    # Query errors are distinct from a successful enumeration without that user.
    Get-LocalUser -ErrorAction Stop | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
}

function Resolve-ImportTarget([object]$Metadata,[string]$Override) {
    $source = [string]$Metadata.SourceAccount
    $target = if ($Override) { $Override } elseif ($Metadata.AccountType -ieq 'Local') {
        $env:COMPUTERNAME + '\' + ($source -split '\\',2)[1]
    } else { $source }
    if ($target -notmatch '^[^\\/:*?"<>|\x00-\x20]{1,64}\\[^\\/:*?"<>|\x00-\x1F]{1,64}$') {
        throw 'Неверное имя назначения. Требуется DOMAIN\user или COMPUTER\user.'
    }
    $qualifier,$name = $target -split '\\',2
    if ($qualifier -in @('BUILTIN','NT AUTHORITY','NT SERVICE','WINDOW MANAGER','FONT DRIVER HOST')) {
        throw 'Системная учётная запись не может быть назначением.'
    }
    $sid = ''
    $create = $false
    $mapping = $null
    $local = $qualifier -ieq $env:COMPUTERNAME
    if ($local) {
        if ($name -notmatch '^[^\\/:*?"<>|\[\];=,+\x00-\x1F]{1,20}$' -or $name -match '^[ ]|[. ]$' -or
            $name -match '^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)' -or
            $name -in @('Administrator','Администратор','Guest','Гость','DefaultAccount','WDAGUtilityAccount')) {
            throw 'Имя локальной учётной записи не подходит для импорта.'
        }
        $account = Get-ImportLocalUser $name
        if ($account) {
            $sid = [string]$account.SID.Value
            if (-not $account.Enabled) { throw 'Локальная учётная запись назначения отключена.' }
            if ($sid -notmatch '^S-1-5-21-(?:[0-9]{1,10}-){3}[0-9]{1,10}$' -or
                [uint32]($sid -split '-')[-1] -lt 1000) {
                throw 'Встроенная локальная учётная запись не может быть назначением.'
            }
            $name = [string]$account.Name
        } else {
            $create = $true
        }
        $target = $env:COMPUTERNAME + '\' + $name
        $mapping = '/mu:' + $source + ':' + $target
    } else {
        if (-not (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain) {
            throw 'Целевой компьютер не в домене. Укажите локальную учётную запись COMPUTER\user.'
        }
        try {
            $securityId = ([Security.Principal.NTAccount]::new($target)).Translate([Security.Principal.SecurityIdentifier])
            $sid = $securityId.Value
            $canonical = $securityId.Translate([Security.Principal.NTAccount]).Value
        } catch {
            throw ('Не удалось подтвердить доменную учётную запись назначения: ' + $target)
        }
        if ($sid -notmatch '^S-1-5-21-(?:[0-9]{1,10}-){3}[0-9]{1,10}$' -or
            ($canonical -split '\\',2)[0] -ieq $env:COMPUTERNAME) {
            throw 'Укажите пользователя целевого домена или локальное назначение COMPUTER\user.'
        }
        if (-not $Override -and $sid -ne $Metadata.SourceSid) {
            throw 'SID доменного пользователя отличается от исходного.'
        }
        $target = $canonical
        if ($target -ine $source -or $Metadata.AccountType -ine 'Domain' -or $sid -ne $Metadata.SourceSid) {
            $mapping = '/mu:' + $source + ':' + $target
        }
    }
    return [pscustomobject]@{ Account=$target; Sid=$sid; Local=$local; Name=$name; CreateLocal=$create; Mapping=$mapping }
}

function Select-ImportDestination([object]$Metadata) {
    Title 'НАЗНАЧЕНИЕ ВОССТАНОВЛЕНИЯ'
    if ($Metadata.AccountType -ieq 'Local') {
        $default = $env:COMPUTERNAME + '\' + ($Metadata.SourceAccount -split '\\',2)[1]
    } else {
        $default = [string]$Metadata.SourceAccount
    }
    Write-Host ('1. Использовать учётную запись ' + $default)
    Write-Host '2. Указать другую учётную запись DOMAIN\user или COMPUTER\user'
    Write-Host '0. Назад'
    switch (Choice 'Выберите назначение' 2) {
        1 { return [pscustomobject]@{Override=''} }
        2 {
            $value = (Read-Host 'Введите DOMAIN\user или COMPUTER\user (0 - назад)').Trim()
            if ($value -and $value -ne '0') { return [pscustomobject]@{Override=$value} }
        }
    }
}

function Assert-ImportProfileUnused([string]$Sid,[string]$PossibleLocalName = '') {
    if ($Sid) {
        if (@(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object { $_.SID -eq $Sid }).Count -gt 0) {
            throw 'У учётной записи уже есть профиль Windows. Перезапись заблокирована.'
        }
        # Win32_UserProfile может не показать резервный ключ или незавершённую регистрацию.
        $registry = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        foreach ($key in @($Sid, ($Sid + '.bak'))) {
            if (Test-Path -LiteralPath (Join-Path $registry $key) -ErrorAction Stop) {
                throw 'В реестре уже есть запись целевого профиля. Проверьте её средствами Windows.'
            }
        }
    }
    if ($PossibleLocalName) {
        $possible = Join-Path (Get-ProfileStoreRoot) $PossibleLocalName
        if (Test-Path -LiteralPath $possible -ErrorAction Stop) {
            throw ('Обнаружен каталог возможного профиля: ' + $possible + '. Требуется ручная проверка.')
        }
    }
}

function Assert-NoUnreviewedImport([object]$Target) {
    foreach ($prior in @(Get-TrackedStates -Legacy)) {
        if ($prior.Kind -ne 'Импорт') { continue }
        $sameSid = $Target.Sid -and (
            ($prior.PSObject.Properties['TargetSid'] -and $prior.TargetSid -eq $Target.Sid) -or
            ($prior.PSObject.Properties['CreatedSid'] -and $prior.CreatedSid -eq $Target.Sid)
        )
        if (-not $sameSid -and $prior.TargetAccount -ine $Target.Account) { continue }
        $pending = $prior.PSObject.Properties['AccountCreationPending'] -and $prior.AccountCreationPending -eq $true
        if (($prior.USMTStarted -and -not $prior.USMTFinished) -or $pending) {
            throw ('Найдена старая незавершённая операция ' + $prior.Id +
                '. Проверьте профиль и сохраните запись операции отдельно перед повторным импортом.')
        }
    }
    foreach ($prior in @(Get-TrackedStates -RequireReadable)) {
        if ($prior.Kind -ne 'Импорт' -or $prior.Id -eq $Script:ActiveOpState.Id) { continue }
        if ($prior.PSObject.Properties['RecoveryReviewed'] -and $prior.RecoveryReviewed -eq $true) { continue }
        $sameSid = $Target.Sid -and $prior.PSObject.Properties['TargetSid'] -and $Target.Sid -eq $prior.TargetSid
        $pending = $prior.PSObject.Properties['AccountCreationPending'] -and $prior.AccountCreationPending -eq $true
        if (($sameSid -or $prior.TargetAccount -ieq $Target.Account) -and ($prior.USMTStarted -or $pending)) {
            throw ('Для назначения уже есть операция ' + $prior.Id + '. Проверьте её состояние в пункте 4 перед повторным импортом.')
        }
    }
}

# Главный сценарий: выбор архива → локальный кеш при UNC → Verify → LoadState → проверка → дополнения.
# Сначала записываем начало импорта в журнал. Даже после сбоя будет видно, запускался ли LoadState.
function Invoke-ProfileLoad($Usmt, $Store, $Archive, $Map, $LogRoot, $Log) {
    $progressLog = Join-Path $logRoot 'load-progress.log'
    $opts = @($store,('/i:'+(Join-Path $archive 'Rules\ProfileOnly.xml')),
        ('/config:'+(Join-Path $archive 'Rules\Config.xml')),'/v:5',('/l:'+$log),('/progress:'+$progressLog))
    if ($map) { $opts += $map }
    Update-TrackedState 'LoadState выполняется' @{USMTStarted=$true}
    Write-Host 'Импорт USMT...' -ForegroundColor Cyan
    Write-OperationReport 'ЖУРНАЛ USMT' ('Импорт: ' + $log)
    Invoke-USMT (Join-Path $Usmt 'LoadState.exe') $opts $Usmt $progressLog
    Advance-OperationStage 'LoadState завершён'
    Update-TrackedState 'LoadState завершён, проверка продолжается' @{USMTFinished=$true}
    Write-OperationReport 'USMT' 'LoadState завершился с кодом 0; проверка файлов выполняется отдельно.'
    Write-Host 'USMT завершился с кодом 0. Выполняется проверка восстановленного профиля...' -ForegroundColor Green
}

# Создаём учётную запись только после подтверждения. В журнал сохраняется её SID, по которому Windows узнаёт пользователя.
function New-ImportLocalAccount([string]$LocalName, [string]$Target, [bool]$Unattended) {
    $password = New-StrongPassword
    $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
    try {
        Update-TrackedState 'Создаётся локальная учётная запись' @{AccountCreationPending=$true}
        $createdUser = New-LocalUser -Name $localName -Password $secure -Description 'Created by WindowsProfileMigration' -ErrorAction Stop
        $targetSid = [string]$createdUser.SID.Value
        Update-TrackedState 'Создан локальный пользователь, импорт не завершён' @{
            CreatedByTool=$true;CreatedAccount=$target;CreatedSid=$targetSid;TargetSid=$targetSid;AccountCreationPending=$false
        }
        if ($Unattended) {
            Write-Host ('Локальная учётная запись создана: ' + $target + '. Администратор получателя должен задать пароль перед входом.')
        } else {
            Write-Host ('НОВЫЙ ПАРОЛЬ УЧЁТНОЙ ЗАПИСИ ' + $localName + ':') -ForegroundColor Yellow
            Write-Host $password -ForegroundColor Yellow
            Write-Host 'Запишите пароль в защищённое место. Скрипт не сохраняет его в отчёте.'
        }
    } finally {
        $secure.Dispose()
        $password = $null
    }
    Write-OperationReport 'УЧЁТНАЯ ЗАПИСЬ' ('Создан локальный пользователь: ' + $localName + '. Пароль в отчёт не записывается.')
    if (-not $Unattended -and -not (Confirm 'Пароль записан, продолжить миграцию?')) {
        Update-TrackedState 'Импорт отменён до LoadState; локальная учётная запись сохранена'
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Импорт отменён. Учётная запись уже создана и доступна в меню восстановления.'
        return $null
    }
    return $targetSid
}

function Do-Import([string]$Usmt,[bool]$JustVerify = $false,[string]$ArchiveOverride = '',[string]$TargetOverride = '',[bool]$Unattended = $false, [Security.SecureString]$ArchivePassword = $null, $PersonalRetry = $null) {
    $archive = if ($ArchiveOverride) { $ArchiveOverride } else { Select-Archive }
    if (-not $archive) { Write-OperationReport 'ОТМЕНА' 'Выбор архива отменён.'; return }
    $isZip = ([IO.Path]::GetExtension($archive) -ieq '.zip')
    $archive = [IO.Path]::GetFullPath($archive)
    $selectedArchive = $archive
    $operationKind = if ($PersonalRetry) { 'Повтор личных файлов' } elseif ($JustVerify) { 'Проверка архива' } else { 'Импорт' }
    Start-TrackedState $operationKind $selectedArchive
    $stagedArchive = $null
    $mutationLock = $null
    try {
    $plainFile = $null
    $ownedPassword = $false
    try {
    Advance-OperationStage 'Архив выбран'
    if (Test-WpmProtectedArchive $archive) {
        if (-not $ArchivePassword) {
            if ($Unattended) { throw 'Для защищённого архива нужен пароль.' }
            $ArchivePassword = Read-WpmArchivePassword
            $ownedPassword = $true
        }
        $stagedArchive = New-StagingDirectory 'ImportCache'
        Update-TrackedState 'Открытие защищённого архива' @{StagingPath=$stagedArchive; StagingPurpose='Проверка защищённого архива'}
        $plainFile = Join-Path $stagedArchive 'profile.zip'
        Convert-WpmArchive $archive $plainFile $ArchivePassword -Decrypt
        $archive = $plainFile
        $isZip = $true
    }
    if ($isZip) {
        $isNetworkZip = Test-IsUncPath $archive
        if ($isNetworkZip) { Ensure-PathAvailable $archive 'Сетевой ZIP' }
        $zipInfo = Get-ProfileZipInfo $archive
        Assert-ArchiveMetadata $zipInfo.Metadata (-not $JustVerify)
        $stagingRoot = $Script:WpmStagingRoot
        $stagingDrive = [IO.Path]::GetPathRoot($stagingRoot)
        $stagingFree = Get-PathFreeBytes $stagingDrive
        $zipBytes = [UInt64](Get-Item -LiteralPath $archive -ErrorAction Stop).Length
        $copyBytes = if ($isNetworkZip) { [double]$zipBytes } else { [double]0 }
        $stagingNeeded = [UInt64]([double]$zipInfo.ExpandedBytes + $copyBytes +
            [Math]::Max([double]1GB,[double]$zipInfo.ExpandedBytes * 0.1))
        if ($stagingFree -lt $stagingNeeded) {
            throw ('Недостаточно места для распаковки ZIP на ' + $stagingDrive +
                '. Нужно примерно ' + (Format-ByteSize $stagingNeeded) +
                ', доступно ' + (Format-ByteSize $stagingFree) + '.')
        }
        Assert-WpmDirectoryChain $stagingRoot
        if (-not $stagedArchive) { $stagedArchive = New-StagingDirectory 'ImportCache' }
        [void](Assert-SafeStaging $stagedArchive)
        Update-TrackedState 'Подготовка распаковки ZIP' @{StagingPath=$stagedArchive; StagingPurpose='Распаковка ZIP для импорта'}
        $zipToExpand = $archive
        if ($isNetworkZip) {
            Write-Host 'Копирование ZIP из сети на локальный диск...' -ForegroundColor Cyan
            Copy-DirectoryRobust (Split-Path -Parent $archive) $stagedArchive 'копирование ZIP для импорта' ([IO.Path]::GetFileName($archive))
            $zipToExpand = Join-Path $stagedArchive ([IO.Path]::GetFileName($archive))
            $localHash = Assert-CopiedZipHash $archive $zipToExpand
            Write-OperationReport 'ПРОВЕРКА' ('Сетевой ZIP перенесён без изменений, SHA-256: ' + $localHash)
        }
        $extracted = Join-Path $stagedArchive 'Archive'
        Write-Host 'Распаковка ZIP перед проверкой и импортом...' -ForegroundColor Cyan
        Expand-ProfileArchive $zipToExpand $extracted
        if ($plainFile) { [IO.File]::Delete($plainFile); $plainFile = $null }
        $archive = $extracted
    } else {
        if (Test-IsUncPath $archive) { Ensure-PathAvailable $archive 'Выбранный сетевой архив' }
        $stagingRoot = $Script:WpmStagingRoot
        Assert-ArchiveCacheOutsideSource $archive $stagingRoot
        $metadataPath = Join-Path $archive 'metadata.json'
        $earlyMeta = Read-ArchiveMetadataFile $metadataPath
        Assert-ArchiveMetadata $earlyMeta (-not $JustVerify)
        # USMT читает только локальную копию, которую проверили после копирования.
        $archiveFiles = Get-ArchiveFileMap $archive
        [UInt64]$folderBytes = 0
        foreach ($file in $archiveFiles.Values) { $folderBytes += [UInt64]$file.Length }
        $stagingDrive = [IO.Path]::GetPathRoot($stagingRoot)
        $stagingFree = Get-PathFreeBytes $stagingDrive
        $stagingNeeded = [UInt64]([double]$folderBytes + [Math]::Max([double]1GB,[double]$folderBytes * 0.10))
        if ($stagingFree -lt $stagingNeeded) {
            throw ('Недостаточно места для локальной копии архива на ' + $stagingDrive +
                '. Нужно примерно ' + (Format-ByteSize $stagingNeeded) + ', доступно ' + (Format-ByteSize $stagingFree) + '.')
        }
        Assert-WpmDirectoryChain $stagingRoot
        $stagedArchive = New-StagingDirectory 'ImportCache'
        [void](Assert-SafeStaging $stagedArchive)
        Update-TrackedState 'Подготовка локального кеша' @{StagingPath=$stagedArchive; StagingPurpose='Локальная копия архива'}
        Write-Host 'Создаётся локальная копия архива перед проверкой и импортом...' -ForegroundColor Cyan
        Copy-DirectoryRobust $archive $stagedArchive 'локальное кэширование архива'
        Assert-NetworkArchiveCopy $archive $stagedArchive
        $archive = $stagedArchive
    }
    Write-OperationReport 'АРХИВ' ('Выбран: ' + $selectedArchive)
    Advance-OperationStage 'Архив подготовлен локально'
    Update-TrackedState 'Архив подготовлен'
    $meta = Read-ArchiveMetadataFile (Join-Path $archive 'metadata.json')
    Assert-ArchiveMetadata $meta (-not $JustVerify)
    Advance-OperationStage 'Проверены метаданные архива'
    $store = Join-Path $archive 'Store'
    if (-not $JustVerify -and -not $PersonalRetry) {
        $requiredImportBytes = if ($meta.PSObject.Properties.Name -contains 'EstimatedProfileBytes' -and $meta.EstimatedProfileBytes) { [UInt64]$meta.EstimatedProfileBytes } else { [UInt64](Get-FolderMetrics $store).Bytes }
        Test-TargetFreeSpace $requiredImportBytes
    }
    if ($PersonalRetry) { return (Restore-TrackedPersonalFiles $archive $meta $PersonalRetry) }
    $logBase = Join-Path $Script:WpmWorkRoot 'Logs'
    Initialize-WpmWorkDirectory $logBase
    $logRoot = Join-Path $logBase ($(if ($JustVerify) { 'Check_' } else { 'Import_' }) + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    [void](New-Item -ItemType Directory -Path $logRoot -Force)
    Write-Host ('Исходная учётная запись: ' + $meta.SourceAccount)
    Write-Host ('Источник: ' + $meta.SourceMachine)
    Write-OperationReport 'ИСТОЧНИК' ('Учётная запись: ' + $meta.SourceAccount + '; компьютер: ' + $meta.SourceMachine)
    Write-OperationReport 'ЖУРНАЛ USMT' ('Проверка: ' + (Join-Path $logRoot 'verify.log'))
    Assert-ValidationManifestIntegrity $archive $meta
    if ([int]$meta.SchemaVersion -ge 7) { Assert-ProfileOnlyArchive $archive $meta }
    elseif ($JustVerify) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Архив старого формата не подтверждает ограничения одним пользователем и не допускается к импорту.' }
    Advance-OperationStage 'Проверены манифесты и ограничение профиля'
    Verify-Store $Usmt $store $logRoot
    Advance-OperationStage 'USMT-архив проверен'
    Write-OperationReport 'АРХИВ' 'Целостность USMT проверена; это не доказывает полноту исходных данных.'
    try {
        $approvedExtras = Test-ExtrasManifest $archive $meta
        Advance-OperationStage 'Проверены манифест и хеши дополнительных файлов'
    } catch {
        if ($JustVerify) { throw }
        $approvedExtras = @{}
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Дополнительные файлы пропущены: ' + $_.Exception.Message)
        Advance-OperationStage 'Дополнительные файлы исключены из импорта'
    }
    Assert-PersonalFilesInventory $meta $approvedExtras
    $sourcePersonalFilesComplete = $true
    if ($meta.PSObject.Properties['PersonalFiles']) {
        $sourcePersonalFilesComplete = Write-PersonalFilesCoverage $meta.PersonalFiles
        if (-not $JustVerify) { $additionalBytes = Measure-ArchivedPersonalFiles $archive $approvedExtras }
    }
    if ($JustVerify) {
        if ([int]$meta.SchemaVersion -ge 5 -and $approvedExtras.Count -ne [int]$meta.ExtrasManifest.Files) {
            throw 'Проверка USMT завершена, но один или несколько дополнительных файлов не прошли проверку.'
        }
        Write-Host 'Проверка USMT-хранилища завершена. Подробности проверки дополнительных файлов в отчёте.' -ForegroundColor Green
        Advance-OperationStage 'Проверка архива завершена'
        Update-TrackedState 'Проверка архива завершена'
        if (Clear-TrackedStaging $Script:ActiveOpState $false) {
            Advance-OperationStage 'Временные файлы проверки очищены'
        }
        Finish-OperationReport 'УСПЕШНО'
        return $true
    }
    $targetWindows = (Get-CimInstance Win32_OperatingSystem).Caption
    if ($meta.PSObject.Properties['SourceWindows'] -and [string]$meta.SourceWindows -match 'Windows 11' -and $targetWindows -match 'Windows 10') {
        throw 'Перенос с Windows 11 на Windows 10 не поддерживается этим комплектом.'
    }
    if ($meta.SourceMachine -ieq $env:COMPUTERNAME) {
        Write-Host 'ВНИМАНИЕ: имя исходного и целевого компьютера совпадает.' -ForegroundColor Yellow
        if ($Unattended -or -not (Confirm 'Это другой экземпляр Windows? Продолжить проверку импорта?')) { Write-OperationReport 'ОТМЕНА' 'Отказано в импорте на компьютер с тем же именем.'; return }
    }
    if (-not $Unattended -and -not $TargetOverride) {
        $selection = Select-ImportDestination $meta
        if (-not $selection) { Write-OperationReport 'ОТМЕНА' 'Выбор назначения отменён.'; return }
        $TargetOverride = $selection.Override
    }
    $mutationLock = Enter-ProfileMutationLock
    $destination = Resolve-ImportTarget $meta $TargetOverride
    $target = $destination.Account
    $map = $destination.Mapping
    $createLocal = $destination.CreateLocal
    $localName = $destination.Name
    $possibleProfileName = if ($createLocal) { $localName } else { '' }
    Assert-ImportProfileUnused $destination.Sid $possibleProfileName
    Assert-NoUnreviewedImport $destination
    Update-TrackedState 'Назначение проверено' @{TargetAccount=$target;TargetSid=$destination.Sid}
    Advance-OperationStage 'Проверена целевая учётная запись'
    Write-Host ('Назначение: ' + $target) -ForegroundColor Cyan
    Write-Host 'До импорта установите программы, нужные пользователю.'
    Write-Host 'После импорта будет выполнена проверка фактически восстановленных данных.' -ForegroundColor Yellow
    if ($createLocal) { Write-Host 'Локальная учётная запись будет создана с новым случайным паролем.' }
    Write-OperationReport 'НАЗНАЧЕНИЕ' ('Целевая учётная запись: ' + $target + '; создание локального пользователя: ' + $createLocal)
    if (-not $Unattended -and -not (Confirm 'НАЧАТЬ ВОССТАНОВЛЕНИЕ ПРОФИЛЯ?')) { Write-OperationReport 'ОТМЕНА' 'Подтверждение импорта отклонено.'; return }
    Advance-OperationStage 'Импорт подтверждён'
    # Пока пользователь подтверждал импорт, другое ПО могло изменить учётную запись или профиль.
    $confirmed = Resolve-ImportTarget $meta $TargetOverride
    if ($confirmed.Account -ine $destination.Account -or $confirmed.Sid -ne $destination.Sid -or
        $confirmed.CreateLocal -ne $destination.CreateLocal) {
        throw 'Учётная запись назначения изменилась после проверки.'
    }
    Assert-ImportProfileUnused $confirmed.Sid $possibleProfileName
    # До LoadState назначения ещё нет. Резервируем место на томе профилей,
    # а перенаправленные папки проверяем по фактическому пути перед записью.
    if ($meta.PSObject.Properties['PersonalFiles'] -and $additionalBytes -gt 0) {
        Test-TargetFreeSpace ([UInt64]($requiredImportBytes + $additionalBytes))
    }
    $targetSid = $confirmed.Sid
    if ($createLocal) {
        $targetSid = New-ImportLocalAccount $localName $target $Unattended
        if (-not $targetSid) { return }
    }
    $latest = Resolve-ImportTarget $meta $TargetOverride
    if ($latest.CreateLocal -or $latest.Sid -ne $targetSid -or $latest.Account -ine $target) {
        throw 'Целевая учётная запись изменилась до LoadState.'
    }
    Assert-ImportProfileUnused $targetSid
    $log = Join-Path $logRoot ('loadstate_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.log')
    if ($meta.PSObject.Properties['PersonalFiles'] -and @($approvedExtras.Keys -like 'UserFiles\*').Count) {
        Update-TrackedState '' @{
            PersonalFilesPending = $true
            PersonalMetadataHash = Get-ExactFileSha256 (Join-Path $archive 'metadata.json')
            PersonalManifestHash = Get-ExactFileSha256 (Join-Path $archive 'Validation\extras.jsonl')
        }
    }
    Invoke-ProfileLoad $Usmt $store $archive $map $logRoot $log
    $targetProfile = Get-TargetUserProfile $target
    if ($targetProfile.Sid -ne $targetSid) { throw 'SID восстановленного профиля отличается от подтверждённой учётной записи.' }
    Advance-OperationStage 'Целевой профиль обнаружен'
    Update-TrackedState 'Профиль найден, выполняется проверка' @{TargetProfile=$targetProfile.Path}
    $personalFilesComplete = Restore-PersonalFiles $archive $targetProfile $meta $approvedExtras
    if ($personalFilesComplete) {
        Update-TrackedState '' @{PersonalFilesPending=$false}
    } else {
        $retryHint = 'Часть личных файлов осталось восстановить. Откройте пункт 4 и выберите «Повторить восстановление личных файлов».'
        Write-Host $retryHint -ForegroundColor Yellow
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' $retryHint
    }
    $validation = Validate-RestoredProfile $meta $targetProfile
    $validationStatus = 'ОГРАНИЧЕННАЯ ПРОВЕРКА - ДЛЯ СТАРОГО ФОРМАТА НЕТ ПОЛНОГО РЕЕСТРА'
    $fileCheck = $null
    if ([int]$meta.SchemaVersion -ge 4) {
        $fileCheck = Test-ValidationManifest $archive $targetProfile.Path $meta
        if ($fileCheck.Total -gt 0 -and $fileCheck.Missing -eq 0 -and $fileCheck.Changed -eq 0 -and $fileCheck.SourceSkipped -eq 0 -and [int]$meta.SchemaVersion -ge 6) {
            $validationStatus = 'ПО КОНТРОЛЬНОМУ РЕЕСТРУ SHA-256 СОВПАДЕНИЕ; СОГЛАСОВАННОСТЬ ИСТОЧНИКА ПРОВЕРЕНА ДО И ПОСЛЕ ScanState'
        } elseif ($fileCheck.Total -gt 0 -and $fileCheck.Missing -eq 0 -and $fileCheck.Changed -eq 0 -and [int]$meta.SchemaVersion -lt 6) {
            $validationStatus = 'КОНТРОЛЬНЫЕ ФАЙЛЫ СОВПАЛИ; ДЛЯ АРХИВОВ v4/v5 НЕЛЬЗЯ ПОДТВЕРДИТЬ ИХ СОГЛАСОВАННОСТЬ НА МОМЕНТ ScanState'
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Для старого формата v4/v5 контрольные суммы могли быть созданы позже ScanState.'
        } else {
            $validationStatus = 'НЕПОЛНОЕ СОВПАДЕНИЕ - НУЖНА РУЧНАЯ ПРОВЕРКА'
        }
        Write-OperationReport 'ПРОВЕРКА' ("Реестр: {0} файлов; совпали: {1}; отсутствуют: {2}; различаются: {3}; не считались на источнике: {4}" -f $fileCheck.Total,$fileCheck.Matched,$fileCheck.Missing,$fileCheck.Changed,$fileCheck.SourceSkipped)
        foreach ($issue in $fileCheck.Errors) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' $issue }
        if ($fileCheck.Total -eq 0 -or $fileCheck.Missing -gt 0 -or $fileCheck.Changed -gt 0 -or $fileCheck.SourceSkipped -gt 0) {
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Есть расхождения в контрольном списке файлов. Нельзя считать перенос полностью проверенным.'
        }
    } else {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Старый формат архива: возможна только ограниченная проверка существования каталогов и отдельных файлов.'
    }
    Write-OperationReport 'СТАТУС ПРОВЕРКИ' $validationStatus
    Advance-OperationStage 'Проверено содержимое восстановленного профиля'
    Write-OperationReport 'ПРОВЕРКА' ('Основные каталоги профиля: найдено ' + $validation.PresentDirectories + ' из ' + $validation.ExpectedDirectories)
    if ($validation.SampleTotal -gt 0) {
        Write-OperationReport 'ПРОВЕРКА' ('Контрольные файлы: найдено ' + $validation.SampleMatched + ' из ' + $validation.SampleTotal)
    }
    foreach ($missingDir in @($validation.MissingDirectories)) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('После импорта отсутствует каталог: ' + $missingDir)
    }
    foreach ($warn in @($validation.Warnings)) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' $warn
    }
    foreach ($missingSample in @($validation.MissingSamples | Select-Object -First 5)) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не найден контрольный файл: ' + $missingSample)
    }
    if ((Test-Path -LiteralPath (Join-Path $archive 'Extras\Browsers')) -or
        (Test-Path -LiteralPath (Join-Path $archive 'Extras\DesktopLayout.json')) -or
        (Test-Path -LiteralPath (Join-Path $archive 'Extras\Explorer')) -or
        (Test-Path -LiteralPath (Join-Path $archive 'Extras\OneC')) -or
        (Test-Path -LiteralPath (Join-Path $archive 'Extras\NetworkDrives.json'))) {
        try {
            try { Restore-BrowserExtras $archive $targetProfile.Path $targetProfile.Sid $approvedExtras $Unattended }
            catch { Write-Host ('Дополнительные данные браузеров пропущены: ' + $_.Exception.Message) -ForegroundColor Yellow
                Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Дополнительные данные браузеров: ' + $_.Exception.Message) }
            try {
                if (Is-AllowedExtra $approvedExtras 'DesktopLayout.json') {
                    Restore-DesktopLayout $archive $targetProfile.Sid $targetProfile.Path $Unattended -ExpectedHash ($approvedExtras['DesktopLayout.json'])
                } else { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Позиции значков не применены: не прошли проверку Extras.' }
            }
            catch { Write-Host ('Расположение значков не удалось восстановить: ' + $_.Exception.Message) -ForegroundColor Yellow
                Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Расположение значков: ' + $_.Exception.Message) }
            try { Restore-ExplorerAndOneCExtras $archive $targetProfile.Path $approvedExtras }
            catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Восстановление закреплений Проводника/списка 1С: ' + $_.Exception.Message) }
            try { Restore-NetworkDrives $archive $targetProfile.Sid $targetProfile.Path $approvedExtras }
            catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Восстановление сетевых дисков: ' + $_.Exception.Message) }
        } catch { Write-Host ('Дополнительные настройки пропущены: ' + $_.Exception.Message) -ForegroundColor Yellow
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Дополнительные настройки: ' + $_.Exception.Message) }
    }
    Advance-OperationStage 'Завершена обработка дополнительных настроек'
    Write-Host 'Проверьте вход пользователя, файлы, историю браузеров и значки рабочего стола.' -ForegroundColor Green
    Write-Host ('Пользователь: '+$target)
    Write-Host ('Журнал: '+$log)
    Write-OperationReport 'ПРОВЕРИТЬ' 'Рекомендуется войти под целевым пользователем и проверить документы, историю браузеров, приложения и значки рабочего стола.'
    Write-OperationReport 'ПРИЁМКА' 'Не выполнена. Для подтверждения доступа, настроек и программ пользователь должен войти под своей учётной записью.'
    Write-OperationReport 'USMT' ('Технический импорт выполнен для: '+$target)
    $personalStatus = if ($personalFilesComplete) { '' } else { '; ЛИЧНЫЕ ФАЙЛЫ ВОССТАНОВЛЕНЫ НЕ ПОЛНОСТЬЮ' }
    if (-not $sourcePersonalFilesComplete) { $personalStatus += '; ЧАСТЬ ЛИЧНЫХ ПАПОК ПРОПУЩЕНА ПРИ ЭКСПОРТЕ' }
    $trackedStatus = if (-not $personalFilesComplete) { 'USMT завершён, личные файлы требуют повтора' }
        elseif (-not $sourcePersonalFilesComplete) { 'USMT завершён, архив личных файлов неполный' }
        else { 'Технически завершено, ожидает приёмки' }
    Update-TrackedState $trackedStatus @{ImportCompleted=$true}
    Advance-OperationStage 'Результаты восстановления записаны в отчёт'
    if (Clear-TrackedStaging $Script:ActiveOpState $false) {
        Advance-OperationStage 'Временные файлы очищены'
    }
    Finish-OperationReport ('ТЕХНИЧЕСКИ ЗАВЕРШЕНО; '+$validationStatus+$personalStatus+'; ОЖИДАЕТ ПРИЁМКИ')
    Write-Host 'Не удаляйте источник и архив до проверки всех данных.' -ForegroundColor Yellow
    return $true
    } finally {
        if ($ownedPassword -and $ArchivePassword) { $ArchivePassword.Dispose() }
        if ($plainFile -and [IO.File]::Exists($plainFile)) { [IO.File]::Delete($plainFile) }
    }
    } catch [System.OperationCanceledException] {
        # При остановке LoadState профиль мог быть создан частично.
        # Сохраняем состояние для пункта 4, но не удаляем учётную запись.
        $partial = $Script:ActiveOpState.USMTStarted -and -not $Script:ActiveOpState.USMTFinished
        $status = if ($partial) { 'Отменено во время LoadState - возможен частичный профиль' }
                  elseif ($Script:ActiveOpState.USMTFinished) { 'Отменено после LoadState - требуется проверка профиля' }
                  else { 'Отменено до LoadState' }
        Update-TrackedState $status @{LastError=$_.Exception.Message}
        if ($partial) {
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'LoadState остановлен. Целевой профиль может быть частично восстановлен; автоматическое удаление запрещено.'
        }
        throw
    } catch {
        Write-DiagnosticFailure $_ 'Импорт/проверка архива'
        Update-TrackedState 'Сбой - импорт не завершён' @{LastError=$_.Exception.Message}
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Импорт не завершён. Повторный запуск и управляемая очистка описаны в пункте 4 главного меню. Автоматического удаления профиля нет.'
        throw
    } finally {
        try {
            # Ошибка удаления не затрагивает исходный архив и не меняет результат LoadState.
            if ($stagedArchive -and $Script:ActiveOpState -and -not $Script:ActiveOpState.CleanupDone) {
                try {
                    if (-not $Script:ActiveOpState.StagingPath) { $Script:ActiveOpState.StagingPath = $stagedArchive }
                    [void](Clear-TrackedStaging $Script:ActiveOpState $false)
                } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Очистка кеша импорта не завершена: ' + $_.Exception.Message) }
            }
            if ($Script:ActiveOpState) {
                $status = if ([string]$Script:ActiveOpState.Status -in @('Начато','Подготовка локального кеша','Архив подготовлен','Назначение проверено')) {
                    'Отменено до запуска LoadState'
                } else { '' }
                try { Update-TrackedState $status @{ProcessId=0;ProcessStartTicks=0} }
                catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось закрыть запись операции: ' + $_.Exception.Message) }
            }
        } finally {
            if ($null -ne $mutationLock) { $mutationLock.Dispose() }
        }
    }
}
