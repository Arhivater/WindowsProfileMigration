# Здесь хранятся записи о незавершённых операциях и правила их безопасного восстановления.

# Оформление заголовка меню в консоли.
# Хранит состояние операции на целевом устройстве. Пароли не записываются.
function Assert-WpmDirectoryChain([string]$Path) {
    $entry = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path))
    while ($null -ne $entry) {
        try {
            $item = Get-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw ('Рабочий каталог или его родитель является ссылкой либо файлом: ' + $entry.FullName)
            }
        } catch [System.Management.Automation.ItemNotFoundException] {
            # Каталог может ещё не существовать, но его родители должны быть безопасны.
        }
        $entry = $entry.Parent
    }
}

function New-WpmWorkDirectoryAcl {
    $admin = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($admin)
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($identity in @($admin,$system)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    return $acl
}

function Assert-WpmWorkAcl([string]$Path) {
    Assert-WpmDirectoryChain $Path
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $trusted = @('S-1-5-32-544','S-1-5-18')
    $aclRules = $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    if (-not $acl.AreAccessRulesProtected -or
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) {
        throw ('Рабочий каталог не защищён. Проверьте владельца и права каталога: ' + $Path)
    }
    foreach ($rule in $aclRules) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $trusted) {
            throw ('Рабочий каталог доступен посторонним: ' + $Path)
        }
    }
}

function Assert-WpmWorkRoot {
    Assert-WpmWorkAcl $Script:WpmWorkRoot
}

function Initialize-WpmWorkDirectory([string]$Path) {
    $root = [IO.Path]::GetFullPath($Script:WpmWorkRoot)
    $directory = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($directory) -ine $root) { throw 'Недопустимый рабочий каталог.' }
    foreach ($candidate in @($root,$directory)) {
        Assert-WpmDirectoryChain $candidate
        if (-not (Test-Path -LiteralPath $candidate -PathType Container -ErrorAction Stop)) {
            # В Windows владелец и DACL устанавливаются при создании, до появления данных.
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                $acl = New-WpmWorkDirectoryAcl
                if ($PSVersionTable.PSEdition -eq 'Desktop') {
                    [void][IO.Directory]::CreateDirectory($candidate,$acl)
                } else {
                    [void][IO.FileSystemAclExtensions]::CreateDirectory($acl,$candidate)
                }
            } else {
                [void][IO.Directory]::CreateDirectory($candidate)
            }
        }
        Assert-WpmWorkAcl $candidate
    }
}
function Save-TrackedState([hashtable]$State) {
    if ([string]$State.Id -notmatch '^WPM_\d{8}_\d{6}_\d{3}_[a-f0-9]{12}$') {
        throw 'Некорректный идентификатор операции.'
    }
    Initialize-WpmWorkDirectory $Script:OpStateRoot
    $path = Join-Path $Script:OpStateRoot ($State.Id + '.json')
    $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $stream = $null
    try {
        $State.LastUpdated = (Get-Date).ToString('o')
        $bytes = [Text.Encoding]::UTF8.GetBytes(($State | ConvertTo-Json -Depth 7 -ErrorAction Stop))
        $stream = [IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        # После сбоя читатель видит предыдущую или новую полную запись.
        if ([IO.File]::Exists($path)) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Файл состояния является ссылкой.' }
            [IO.File]::Replace($tmp,$path,[NullString]::Value)
        } else {
            [IO.File]::Move($tmp,$path)
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        # Ошибка очистки временного JSON не перекрывает результат операции.
        try {
            if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
        } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Временный файл состояния остался: ' + $tmp) }
    }
}
function Start-TrackedState([string]$Kind,[string]$Archive) {
    $process = Get-Process -Id $PID -ErrorAction Stop
    try { $startTicks = $process.StartTime.ToUniversalTime().Ticks }
    finally { $process.Dispose() }
    $state = @{
        Id=('WPM_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,12));
        Kind=$Kind; Status='Начато'; SourceArchive=$Archive; TargetAccount='';
        CreatedAccount=''; CreatedSid=''; CreatedByTool=$false; AccountCreationPending=$false;
        TargetSid=''; TargetProfile=''; RecoveryReviewed=$false; ImportCompleted=$false;
        StagingPath=''; StagingDisposition=''; StagingPurpose=''; DesktopBackup=''; DesktopBackupSha256='';
        NetworkPartialPath=''; BrowserBackupPath=''; ConfigBackupPath='';
        USMTStarted=$false; USMTFinished=$false; CleanupDone=$false;
        LastError=''; LastUpdated=''; Report=[string]$Script:ReportPath;
        ProcessId=$PID; ProcessStartTicks=$startTicks
    }
    Save-TrackedState $state
    $Script:ActiveOpState=$state
}
function Update-TrackedState([string]$Status,[hashtable]$Fields = @{}) {
    if (-not $Script:ActiveOpState) { return }
    if ($Status) { $Script:ActiveOpState.Status = $Status }
    foreach ($key in $Fields.Keys) { $Script:ActiveOpState[$key] = $Fields[$key] }
    Save-TrackedState $Script:ActiveOpState
}
function Get-TrackedStates([switch]$RequireReadable,[string]$Id = '',[switch]$Legacy) {
    $root = if ($Legacy) { $Script:LegacyOpStateRoot } else { $Script:OpStateRoot }
    if (-not $root) { return }
    Assert-WpmDirectoryChain $root
    if (-not (Test-Path -LiteralPath $root -PathType Container -ErrorAction Stop)) { return }
    if (-not $Legacy) {
        Assert-WpmWorkRoot
        Assert-WpmWorkAcl $root
    }
    $results=@()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter 'WPM_*.json' -File -Force -ErrorAction Stop)) {
        if ($Id -and $file.BaseName -cne $Id) { continue }
        if ($file.BaseName -notmatch '^WPM_\d{8}_\d{6}_\d{3}_[a-f0-9]{12}$') { continue }
        try {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Файл состояния является ссылкой.' }
            $stream = [IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,
                ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
            try {
                $item = Read-BoundedArchiveMetadata $stream $stream.Length
            } finally { $stream.Dispose() }
            if ($item -isnot [pscustomobject] -or $item.Id -cne $file.BaseName -or
                $item.Kind -isnot [string] -or $item.Status -isnot [string] -or
                $item.TargetAccount -isnot [string] -or $item.USMTStarted -isnot [bool] -or
                $item.USMTFinished -isnot [bool] -or $item.CreatedByTool -isnot [bool]) {
                throw 'Файл состояния повреждён.'
            }
            $results += $item
        } catch {
            $message = 'Не удалось проверить состояние операции: ' + $file.FullName
            if ($RequireReadable) { throw $message }
            Write-Host $message -ForegroundColor Yellow
        }
    }
    $results | Sort-Object LastUpdated -Descending
}

# Общая блокировка получателя защищает импорт и управляемый откат разных сеансов.
# Сам файл остаётся на месте, а дескриптор освобождается при завершении процесса.
function Enter-ProfileMutationLock {
    Initialize-WpmWorkDirectory $Script:OpStateRoot
    $path = Join-Path $Script:OpStateRoot 'profile-mutation.lock'
    if (Test-Path -LiteralPath $path -ErrorAction Stop) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Некорректный файл блокировки импорта.'
        }
    }
    try {
        return [IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    } catch {
        throw ('Не удалось получить блокировку. Проверьте, что другой импорт или восстановление завершены. ' + $_.Exception.Message)
    }
}

function Assert-TrackedOperationStopped([object]$State) {
    if (-not $State.PSObject.Properties['ProcessId'] -or -not $State.PSObject.Properties['ProcessStartTicks'] -or
        [int]$State.ProcessId -le 0) { return }
    if ([int]$State.ProcessId -eq $PID -and (-not $Script:ActiveOpState -or $Script:ActiveOpState.Id -ne $State.Id)) { return }
    $process = Get-Process -Id ([int]$State.ProcessId) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return }
    try {
        if ($process.StartTime.ToUniversalTime().Ticks -eq [long]$State.ProcessStartTicks) {
            throw 'Операция выполняется. Восстановление и очистка пока недоступны.'
        }
    } finally { $process.Dispose() }
}

function Assert-OperationTreeHasNoReparsePoint([string]$Path) {
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $item = Get-Item -LiteralPath ($pending.Pop()) -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw ('Зарегистрированный путь содержит ссылку: ' + $item.FullName)
        }
        if ($item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
                $pending.Push($child.FullName)
            }
        }
    }
}
# Разрешена очистка только собственных временных каталогов под ProgramData.
function Assert-SafeStaging([string]$Candidate) {
    if (-not $Candidate) { throw 'Временная папка не указана.' }
    $base = [IO.Path]::GetFullPath($Script:WpmStagingRoot)
    $full = [IO.Path]::GetFullPath($Candidate)
    if ([IO.Path]::GetDirectoryName($full) -ine $base -or
        [IO.Path]::GetFileName($full) -notmatch '^(ImportCache|Export)_\d{8}_\d{6}_\d{3}_[a-f0-9]{8}$') {
        throw 'Неверный путь временного каталога. Очистка запрещена.'
    }
    Assert-WpmWorkRoot
    Assert-WpmWorkAcl $base
    Assert-WpmDirectoryChain $full
    if (Test-Path -LiteralPath $full -ErrorAction Stop) { Assert-OperationTreeHasNoReparsePoint $full }
    return $full
}
function Clear-TrackedStaging([hashtable]$State,[bool]$Ask = $false) {
    if (-not $State.StagingPath) { return $true }
    $safe=Assert-SafeStaging ([string]$State.StagingPath)
    if ($Ask -and -not (Confirm ('Удалить только временный каталог ' + $safe + ' ?'))) { return $false }
    try {
        if ($Ask) { $safe = Assert-SafeStaging ([string]$State.StagingPath) }
        if (Test-Path -LiteralPath $safe -ErrorAction Stop) { Remove-Item -LiteralPath $safe -Recurse -Force -ErrorAction Stop }
        $State.CleanupDone=$true; $State.StagingDisposition='Временная копия удалена'
        Save-TrackedState $State
        Write-OperationReport 'ОЧИСТКА' ('Удалён временный каталог: ' + $safe)
        return $true
    } catch {
        $State.CleanupDone=$false; $State.StagingDisposition='Ошибка удаления: '+$_.Exception.Message
        Save-TrackedState $State
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось очистить временный каталог: ' + $safe + '; ' + $_.Exception.Message)
        return $false
    }
}

# Меню для незавершённых импортов: исходные профили и пользовательские данные не удаляются.
# Удалять сетевую недокопированную папку можно только внутри места публикации,
# которое записано в исходном состоянии операции.
function Assert-RegularNetworkPartial([string]$Path) {
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file -isnot [IO.FileInfo] -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Незавершённый ZIP должен быть обычным файлом. Очистка запрещена.'
    }
}

function Clear-NetworkPartial([hashtable]$State,[bool]$Ask = $true) {
    $target=[string]$State.NetworkPartialPath
    $published=[string]$State.SourceArchive
    if ($State.Kind -ne 'Экспорт' -or -not $target -or -not $published) { throw 'Нет сетевого временного каталога для очистки.' }
    $final=[IO.Path]::GetFullPath($published).TrimEnd('\')
    $temp=[IO.Path]::GetFullPath($target).TrimEnd('\')
    $parent=[IO.Path]::GetDirectoryName($final)
    $finalName = [IO.Path]::GetFileName($final)
    $partialPattern = '^' + [regex]::Escape($finalName) + '\.partial_[a-f0-9]{8}$'
    if ([IO.Path]::GetExtension($finalName) -ine '.zip' -or
        [IO.Path]::GetDirectoryName($temp) -ine $parent -or
        [IO.Path]::GetFileName($temp) -notmatch $partialPattern) {
        throw 'Подозрительное имя незавершённого ZIP. Очистка запрещена.'
    }
    Assert-WpmDirectoryChain $parent
    if (Test-Path -LiteralPath $temp -ErrorAction Stop) {
        Assert-RegularNetworkPartial $temp
    }
    if ($Ask -and -not (Confirm ('Удалить незавершённую копию ' + $temp + ' ?'))) { return $false }
    Assert-WpmDirectoryChain $parent
    if (Test-Path -LiteralPath $temp -ErrorAction Stop) {
        Assert-RegularNetworkPartial $temp
        [IO.File]::Delete($temp)
    }
    $State.NetworkPartialPath=''
    Save-TrackedState $State
    Write-OperationReport 'ОЧИСТКА' ('Удалена незавершённая копия: ' + $temp)
    Write-Host 'Незавершённая копия удалена.' -ForegroundColor Green
    return $true
}
function Show-RecoveryMenu {
    Title 'СОСТОЯНИЕ ОПЕРАЦИЙ И УПРАВЛЯЕМАЯ ОЧИСТКА'
    $items = @(
        foreach ($record in @(Get-TrackedStates)) { [pscustomobject]@{State=$record;Legacy=$false} }
        foreach ($record in @(Get-TrackedStates -Legacy)) { [pscustomobject]@{State=$record;Legacy=$true} }
    )
    if ($items.Count -eq 0) { Write-Host 'Операций пока нет.'; return }
    for ($i=0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        $label = if ($item.Legacy) { 'Старая запись, только просмотр' } else { $item.State.Kind }
        $status = [string]$item.State.Status -replace '[\x00-\x1F\x7F-\x9F]', '?'
        $when = if ($item.State.PSObject.Properties['LastUpdated']) {
            [string]$item.State.LastUpdated -replace '[\x00-\x1F\x7F-\x9F]', '?'
        } else { '' }
        Write-Host ('{0}. {1} | {2} | {3}' -f ($i+1),$label,$status,$when)
    }
    Write-Host '0. Назад'
    $index=Choice 'Номер операции' $items.Count
    if ($index -eq 0) { return }
    $selection = $items[$index-1]
    $state = $selection.State
    Title ('ОПЕРАЦИЯ ' + $state.Id)
    if ($selection.Legacy) {
        foreach ($field in @('Kind','Status','LastUpdated','SourceArchive','TargetAccount','StagingPath','NetworkPartialPath','DesktopBackup','LastError')) {
            if ($state.PSObject.Properties[$field] -and $state.$field) {
                Write-Host ($field + ': ' + ([string]$state.$field -replace '[\x00-\x1F\x7F-\x9F]', '?'))
            }
        }
        Write-Host 'Старая запись доступна для просмотра. Проверьте перечисленные данные средствами Windows.'
        return
    }
    Write-Host ('Результат: ' + $state.Status)
    Write-Host ('Исходный архив: ' + $state.SourceArchive)
    Write-Host ('Целевая учётная запись: ' + $state.TargetAccount)
    Write-Host ('Профиль: ' + $state.TargetProfile)
    Write-Host ('Создана программой: ' + $state.CreatedByTool)
    Write-Host ('Временная копия: ' + $state.StagingPath)
    Write-Host ('Незавершённая публикация архива: ' + $state.NetworkPartialPath)
    Write-Host ('Резерв значков: ' + $state.DesktopBackup)
    foreach ($entry in @(@('BrowserBackupPath','Резерв браузеров'),@('ConfigBackupPath','Резерв настроек'))) {
        if ($state.PSObject.Properties[$entry[0]] -and $state.($entry[0])) {
            Write-Host ($entry[1] + ': ' + $state.($entry[0]))
        }
    }
    if ($state.LastError) { Write-Host ('Ошибка: ' + $state.LastError) -ForegroundColor Yellow }
    Write-Host 'Перед повторным импортом проверьте, что учётная запись назначения и её каталог не содержат данных.'
    Write-Host '1. Удалить зарегистрированную временную копию'
    Write-Host '2. Удалить только созданную программой локальную учётную запись без профиля'
    Write-Host '3. Восстановить прежние параметры значков'
    Write-Host '4. Удалить незавершённую копию архива'
    Write-Host '5. Подтвердить возможность повторного импорта'
    Write-Host '0. Назад'
    $action = Choice 'Выберите действие' 5
    if ($action -eq 0) { return }
    $id = $state.Id
    $lock = $null
    try {
        Start-OperationReport 'ВОССТАНОВЛЕНИЕ'
        Write-OperationReport 'ДЕЙСТВИЕ' ('Операция ' + $id + ', пункт ' + $action)
        $lock = Enter-ProfileMutationLock
        $state = Get-TrackedStates -RequireReadable -Id $id
        if (-not $state) { throw 'Запись выбранной операции больше недоступна.' }
        Assert-TrackedOperationStopped $state
        $hash = @{}
        foreach ($property in $state.PSObject.Properties) { $hash[$property.Name] = $property.Value }
        switch ($action) {
            1 {
                if (-not $state.StagingPath -or $state.CleanupDone) { Write-Host 'Временной копии нет.'; return }
                if (-not (Clear-TrackedStaging $hash $true)) { return }
            }
            2 {
                if ($state.Kind -ne 'Импорт' -or -not $state.CreatedByTool -or -not $state.CreatedAccount -or
                    -not $state.CreatedSid -or $state.USMTStarted) {
                    throw 'Допускается удаление только подтверждённой учётной записи до запуска LoadState.'
                }
                $computer,$name = [string]$state.CreatedAccount -split '\\',2
                if ($computer -ine $env:COMPUTERNAME -or -not $name) { throw 'Учётная запись не локальная.' }
                $account = Get-ImportLocalUser $name
                if (-not $account -or $account.SID.Value -ne [string]$state.CreatedSid) {
                    throw 'Локальный пользователь отсутствует или его SID уже отличается от зарегистрированного.'
                }
                Assert-ImportProfileUnused $account.SID.Value $account.Name
                if (-not (Confirm ('Удалить только пустую учётную запись ' + $state.CreatedAccount + ' ?'))) { return }
                if (-not (Confirm 'Повторное подтверждение удаления учётной записи')) { return }
                $account = Get-ImportLocalUser $name
                if (-not $account -or $account.SID.Value -ne [string]$state.CreatedSid) {
                    throw 'Учётная запись изменилась после подтверждения.'
                }
                Assert-ImportProfileUnused $account.SID.Value $account.Name
                Remove-LocalUser -SID $account.SID -ErrorAction Stop
                $hash.Status = 'Пустая учётная запись удалена по подтверждению'
                $hash.CreatedByTool = $false
                Save-TrackedState $hash
                Write-Host 'Пустая учётная запись удалена.' -ForegroundColor Green
            }
            3 {
                if (-not $state.DesktopBackup) { Write-Host 'Резервной копии значков нет.'; return }
                if (-not $state.PSObject.Properties['DesktopBackupSha256'] -or -not $state.DesktopBackupSha256) {
                    throw 'Для резервной копии отсутствует зарегистрированная контрольная сумма.'
                }
                if (-not (Restore-PreviousDesktopLayout ([string]$state.DesktopBackup) ([string]$state.DesktopBackupSha256))) { return }
            }
            4 {
                if (-not $state.NetworkPartialPath) { Write-Host 'Незавершённой копии нет.'; return }
                if (-not (Clear-NetworkPartial $hash)) { return }
            }
            5 {
                $pending = $state.PSObject.Properties['AccountCreationPending'] -and $state.AccountCreationPending -eq $true
                if ($state.Kind -ne 'Импорт' -or -not $state.TargetAccount -or (-not $state.USMTStarted -and -not $pending)) {
                    throw 'Нет незавершённой записи, требующей проверки перед повторным импортом.'
                }
                if ($state.PSObject.Properties['RecoveryReviewed'] -and $state.RecoveryReviewed -eq $true) {
                    Write-Host 'Возможность повторного импорта уже подтверждена.'; return
                }
                $recordedSid = if ($state.PSObject.Properties['TargetSid']) { [string]$state.TargetSid } else { [string]$state.CreatedSid }
                $identity = [pscustomobject]@{SourceAccount=$state.TargetAccount;SourceSid=$recordedSid;AccountType='Domain'}
                $target = Resolve-ImportTarget $identity $state.TargetAccount
                if ($recordedSid -and $target.Sid -and $recordedSid -ne $target.Sid) {
                    throw 'SID назначения отличается от сохранённого. Проверьте учётную запись вручную.'
                }
                $possibleLocalName = if ($target.Local) { $target.Name } else { '' }
                Assert-ImportProfileUnused $target.Sid $possibleLocalName
                if (-not (Confirm ('Разрешить повторный импорт для ' + $state.TargetAccount + ' после ручной проверки?'))) { return }
                Assert-ImportProfileUnused $target.Sid $possibleLocalName
                $hash.RecoveryReviewed = $true
                Save-TrackedState $hash
                Write-Host 'Проверка записана. Импорт можно заново запустить через главное меню.' -ForegroundColor Green
            }
        }
        Finish-OperationReport 'УСПЕШНО'
    } catch {
        $Script:HadFailures = $true
        Write-OperationReport 'ОШИБКА' $_.Exception.Message
        Write-DiagnosticFailure $_ 'Восстановление состояния'
        Finish-OperationReport 'СБОЙ ВОССТАНОВЛЕНИЯ'
        Write-Host ('Действие восстановления не выполнено: ' + $_.Exception.Message) -ForegroundColor Red
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
        if ($Script:ReportPath) { Finish-OperationReport 'ОТМЕНЕНО / НЕ ЗАВЕРШЕНО' }
    }
}
