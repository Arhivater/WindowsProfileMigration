#Requires -Version 5.1
# Автор: Arhivater
# WindowsProfileMigration 1.10.1 | Windows PowerShell 5.1 | Windows 10/11
# Экспорт выбранного профиля и подтверждённый автоматический импорт по WinRM.
# Учётная запись администратора запуска не подставляется вместо выбранного профиля.

param(
    [string]$ToolRoot = $PSScriptRoot,
    [string]$RemoteImportArchive = '',
    [string]$RemoteTargetAccount = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Script:WpmVersion = '1.10.1'
$Script:ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
if ($Script:ToolRoot.Length -gt [IO.Path]::GetPathRoot($Script:ToolRoot).Length) {
    $Script:ToolRoot = $Script:ToolRoot.TrimEnd('\')
}
# Один перечень версий для создания, поиска, проверки и восстановления архивов.
$Script:SupportedArchiveSchemas = @(1,2,3,4,5,6,7)
$Script:CurrentArchiveSchema = 7
$Script:BackupRoot = Join-Path $Script:ToolRoot 'Backups'
$Script:RestartRequired = $false
$Script:ReportPath = $null
$Script:ReportWriter = $null
$Script:ReportWarnings = 0
$Script:ReportErrors = 0
$Script:ReportStart = $null
$Script:ReportPhase = 'Ожидание действия'
$Script:ReportPhaseStart = $null
$Script:ProgressStep = 0
$Script:ActiveOpState = $null
$Script:HadFailures = $false
$Script:OpStateRoot = Join-Path $env:ProgramData 'WindowsProfileMigration\Operations'

# One human-readable report per operation. The file name is never reused:
# CreateNew protects against collisions even when operations start simultaneously.
# Создаёт уникальный итоговый TXT-отчёт без перезаписи предыдущих результатов.
function Start-OperationReport([string]$Operation) {
    if ($Script:ReportPath) { throw 'Предыдущий отчёт не завершён.' }
    $rootOptions = @((Join-Path $Script:ToolRoot 'Reports'),
        (Join-Path $env:ProgramData 'WindowsProfileMigration\Reports'))
    $stem = 'Итог_работы_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
    $lastError = $null
    foreach ($root in $rootOptions) {
        try {
            [void](New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop)
            for ($i=0; $i -lt 10; $i++) {
                $filename = '{0}_{1}.txt' -f $stem,([guid]::NewGuid().ToString('N').Substring(0,12))
                $candidate = Join-Path $root $filename
                $stream = $null
                $writer = $null
                try {
                    $stream = [System.IO.File]::Open($candidate,
                        [System.IO.FileMode]::CreateNew,
                        [System.IO.FileAccess]::Write,
                        [System.IO.FileShare]::Read)
                    $writer = [System.IO.StreamWriter]::new($stream,[System.Text.UTF8Encoding]::new($true))
                    $stream = $null
                    $writer.AutoFlush = $true
                    $writer.WriteLine(('WINDOWS PROFILE MIGRATION {0} - ПОЛНЫЙ ИТОГ РАБОТЫ' -f $Script:WpmVersion))
                    $writer.WriteLine(('Операция: ' + $Operation))
                    $writer.WriteLine(('Начало: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')))
                    $writer.WriteLine(('Компьютер: ' + $env:COMPUTERNAME))
                    $writer.WriteLine(('Технический администратор: ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name))
                    $writer.WriteLine(('Отчёт: ' + $candidate))
                    $writer.WriteLine(('----------------------------------------------'))
                    $Script:ReportWriter = $writer
                    $writer = $null
                    $Script:ReportPath = $candidate
                    $Script:ReportStart = Get-Date
                    $Script:ReportPhase = 'Начало операции'
                    $Script:ReportPhaseStart = Get-Date
                    $Script:ProgressStep = 0
                    $Script:ReportWarnings = 0
                    $Script:ReportErrors = 0
                    Write-Host ('Итоговый отчёт: ' + $candidate) -ForegroundColor Cyan
                    Write-OperationReport 'ДИАГНОСТИКА' ('PowerShell ' + $PSVersionTable.PSVersion +
                        '; PID=' + $PID + '; 64-битный процесс=' + [Environment]::Is64BitProcess +
                        '; операция=' + $Operation + '; версия инструмента=' + $Script:WpmVersion)
                    return
                } catch [System.IO.IOException] {
                    # On collision try another name. For a read-only drive, fall back
                    # to ProgramData instead of destroying any existing report.
                    $lastError = $_.Exception
                } finally {
                    if ($writer) { $writer.Dispose() }
                    if ($stream) { $stream.Dispose() }
                }
            }
        } catch { $lastError = $_.Exception }
    }
    throw ('Не удалось создать уникальный файл итогового отчёта: ' + $lastError.Message)
}
# Добавляет событие в общий отчёт; предупреждения и ошибки считаются отдельно.
function Write-OperationReport([string]$Category,[string]$Message) {
    if (-not $Script:ReportPath) { return }
    if ($Category -eq 'ПРЕДУПРЕЖДЕНИЕ') { $Script:ReportWarnings++ }
    if ($Category -eq 'ОШИБКА') { $Script:ReportErrors++ }
    $line = '[{0}] [{1}] [Этап: {2}] {3}' -f (Get-Date -Format 'HH:mm:ss.fff'),$Category,$Script:ReportPhase,$Message
    try {
        $Script:ReportWriter.WriteLine($line)
    } catch {
        Write-Host ('Не удалось дописать итоговый отчёт: ' + $_.Exception.Message) -ForegroundColor Red
    }
}
# Записывает итоговый статус операции и закрывает текущий отчёт.
function Finish-OperationReport([string]$Status) {
    if (-not $Script:ReportPath) { return }
    if ($Status -eq 'УСПЕШНО' -and $Script:ReportWarnings -gt 0) {
        $Status = 'УСПЕШНО, ЕСТЬ ПРЕДУПРЕЖДЕНИЯ'
    }
    if ($Script:ReportPhaseStart) {
        $seconds = [Math]::Round(((Get-Date) - $Script:ReportPhaseStart).TotalSeconds,1)
        Write-OperationReport 'ВРЕМЯ ЭТАПА' ($Script:ReportPhase + ': ' + $seconds + ' с')
    }
    Write-OperationReport 'ИТОГ' ('Результат операции: ' + $Status)
    if ($Script:ReportStart) {
        $elapsed = (Get-Date) - $Script:ReportStart
        Write-OperationReport 'ИТОГ' ('Общее время: ' + [Math]::Round($elapsed.TotalSeconds,1) + ' с')
    }
    Write-OperationReport 'ИТОГ' ('Предупреждений: ' + $Script:ReportWarnings + '; ошибок: ' + $Script:ReportErrors)
    Write-OperationReport 'ИТОГ' ('Завершено: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'))
    $completed = $Script:ReportPath
    $Script:ReportPath = $null
    try { $Script:ReportWriter.Dispose() }
    catch { Write-Host ('Не удалось закрыть отчёт: ' + $_.Exception.Message) -ForegroundColor Yellow }
    finally { $Script:ReportWriter = $null }
    foreach ($progressId in 0..6) {
        Write-Progress -Id $progressId -Activity 'Выполнение операции' -Completed
    }
    Write-Host ('Один итоговый отчёт по операции: ' + $completed) -ForegroundColor Cyan
}

# Состав этапов зависит от сценария. Считаем выполненные этапы, а проценты
# показываем только для действий с известным объёмом работы.
function Advance-OperationStage([string]$Stage) {
    if (-not $Script:ReportPath) { return }
    if ($Script:ReportPhaseStart) {
        $seconds = [Math]::Round(((Get-Date) - $Script:ReportPhaseStart).TotalSeconds,1)
        Write-OperationReport 'ВРЕМЯ ЭТАПА' ($Script:ReportPhase + ': ' + $seconds + ' с')
    }
    $Script:ReportPhase = $Stage
    $Script:ReportPhaseStart = Get-Date
    $Script:ProgressStep++
    Write-Progress -Id 0 -Activity 'Миграция профиля - выполненные этапы' -Status ($Stage +
        ' | завершено этапов: ' + $Script:ProgressStep) -PercentComplete -1
    Write-OperationReport 'ЭТАП' ($Stage + '; выполнено этапов: ' + $Script:ProgressStep)
}

# Добавляет в тот же отчёт причину сбоя, тип исключения и точку в скрипте.
# Пароли, содержимое профиля и параметры командной строки не собираются.
function Write-DiagnosticFailure([object]$ErrorRecord,[string]$Context) {
    if (-not $ErrorRecord) { return }
    try {
        $ex = $ErrorRecord.Exception
        Write-OperationReport 'ДИАГНОСТИКА' ('Контекст: ' + $Context + '; тип: ' + $ex.GetType().FullName + '; причина: ' + $ex.Message)
        if ($ex.InnerException) {
            Write-OperationReport 'ДИАГНОСТИКА' ('Внутренняя ошибка: ' + $ex.InnerException.GetType().FullName + ': ' + $ex.InnerException.Message)
        }
        if ($ErrorRecord.FullyQualifiedErrorId) {
            Write-OperationReport 'ДИАГНОСТИКА' ('Код PowerShell: ' + $ErrorRecord.FullyQualifiedErrorId)
        }
        if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptLineNumber) {
            Write-OperationReport 'ДИАГНОСТИКА' ('Строка: ' + $ErrorRecord.InvocationInfo.ScriptLineNumber +
                '; файл: ' + $ErrorRecord.InvocationInfo.ScriptName)
        }
        if ($ErrorRecord.ScriptStackTrace) {
            Write-OperationReport 'ДИАГНОСТИКА' ('Стек вызовов: ' + ($ErrorRecord.ScriptStackTrace -replace "`r?`n", ' | '))
        }
    } catch { Write-OperationReport 'ДИАГНОСТИКА' 'Не удалось сформировать подробности исключения.' }
}

# Включает диагностический фрагмент USMT в тот же итоговый TXT при сбое.
function Append-UsmtLogTail([string[]]$Options) {
    $item = @($Options | Where-Object { $_ -like '/l:*' } | Select-Object -First 1)
    if ($item.Count -eq 0) { return }
    $logPath = ([string]$item[0]).Substring(3)
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { return }
    Write-OperationReport 'ДИАГНОСТИКА' ('Последние строки USMT: ' + $logPath)
    try {
        foreach ($line in @(Get-Content -LiteralPath $logPath -Tail 35 -ErrorAction Stop)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-OperationReport 'USMT ЖУРНАЛ' ([string]$line)
            }
        }
    } catch { Write-OperationReport 'ДИАГНОСТИКА' ('Не удалось прочитать журнал USMT: ' + $_.Exception.Message) }
}

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

function New-OperationStateDirectory {
    Assert-WpmDirectoryChain $Script:OpStateRoot
    [void][IO.Directory]::CreateDirectory($Script:OpStateRoot)
    Assert-WpmDirectoryChain $Script:OpStateRoot
}

function Save-TrackedState([hashtable]$State) {
    if ([string]$State.Id -notmatch '^WPM_\d{8}_\d{6}_\d{3}_[a-f0-9]{12}$') {
        throw 'Некорректный идентификатор операции.'
    }
    New-OperationStateDirectory
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
        StagingPath=''; StagingDisposition=''; StagingPurpose=''; DesktopBackup='';
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
function Get-TrackedStates([switch]$RequireReadable,[string]$Id = '') {
    Assert-WpmDirectoryChain $Script:OpStateRoot
    if (-not (Test-Path -LiteralPath $Script:OpStateRoot -PathType Container -ErrorAction Stop)) { return }
    $results=@()
    foreach ($file in @(Get-ChildItem -LiteralPath $Script:OpStateRoot -Filter 'WPM_*.json' -File -Force -ErrorAction Stop)) {
        if ($Id -and $file.BaseName -cne $Id) { continue }
        if ($file.BaseName -notmatch '^WPM_\d{8}_\d{6}_\d{3}_[a-f0-9]{12}$') { continue }
        try {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Файл состояния является ссылкой.' }
            $stream = [IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $reader = [IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
                try { $item = ConvertFrom-Json -InputObject $reader.ReadToEnd() -ErrorAction Stop }
                finally { $reader.Dispose() }
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
    New-OperationStateDirectory
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
    $base = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'WindowsProfileMigration\Staging'))
    $full = [IO.Path]::GetFullPath($Candidate)
    if ([IO.Path]::GetDirectoryName($full) -ine $base -or
        [IO.Path]::GetFileName($full) -notmatch '^(ImportCache|Export)_\d{8}_\d{6}_\d{3}_[a-f0-9]{8}$') {
        throw 'Неверный путь временного каталога. Очистка запрещена.'
    }
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
function Clear-NetworkPartial([hashtable]$State,[bool]$Ask = $true) {
    $target=[string]$State.NetworkPartialPath
    $published=[string]$State.SourceArchive
    if ($State.Kind -ne 'Экспорт' -or -not $target -or -not $published) { throw 'Нет сетевого временного каталога для очистки.' }
    $final=[IO.Path]::GetFullPath($published).TrimEnd('\')
    $temp=[IO.Path]::GetFullPath($target).TrimEnd('\')
    $parent=[IO.Path]::GetDirectoryName($final)
    $prefix=[IO.Path]::GetFileName($final) + '.partial_'
    if ([IO.Path]::GetDirectoryName($temp) -ine $parent -or
        -not ([IO.Path]::GetFileName($temp)).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Подозрительный путь сетевого временного каталога. Очистка запрещена.'
    }
    Assert-WpmDirectoryChain $parent
    if (Test-Path -LiteralPath $temp -ErrorAction Stop) { Assert-OperationTreeHasNoReparsePoint $temp }
    if ($Ask -and -not (Confirm ('Удалить незавершённую копию ' + $temp + ' ?'))) { return }
    Assert-WpmDirectoryChain $parent
    if (Test-Path -LiteralPath $temp -ErrorAction Stop) {
        Assert-OperationTreeHasNoReparsePoint $temp
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction Stop
    }
    $State.NetworkPartialPath=''
    Save-TrackedState $State
    Write-OperationReport 'ОЧИСТКА' ('Удалена незавершённая копия: ' + $temp)
    Write-Host 'Незавершённая копия удалена.' -ForegroundColor Green
}
function Show-RecoveryMenu {
    Title 'СОСТОЯНИЕ ОПЕРАЦИЙ И УПРАВЛЯЕМАЯ ОЧИСТКА'
    $items=@(Get-TrackedStates)
    if ($items.Count -eq 0) { Write-Host 'Операций пока нет.'; return }
    for ($i=0; $i -lt $items.Count; $i++) {
        $item=$items[$i]
        Write-Host ('{0}. {1} | {2} | {3}' -f ($i+1),$item.Kind,$item.Status,$item.LastUpdated)
    }
    Write-Host '0. Назад'
    $index=Choice 'Номер операции' $items.Count
    if ($index -eq 0) { return }
    $state=$items[$index-1]
    Title ('ОПЕРАЦИЯ ' + $state.Id)
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
        $lock = Enter-ProfileMutationLock
        $state = Get-TrackedStates -RequireReadable -Id $id
        if (-not $state) { throw 'Запись выбранной операции больше недоступна.' }
        Assert-TrackedOperationStopped $state
        $hash = @{}
        foreach ($property in $state.PSObject.Properties) { $hash[$property.Name] = $property.Value }
        switch ($action) {
            1 {
                if (-not $state.StagingPath -or $state.CleanupDone) { Write-Host 'Временной копии нет.'; return }
                [void](Clear-TrackedStaging $hash $true)
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
                Restore-PreviousDesktopLayout ([string]$state.DesktopBackup)
            }
            4 {
                if (-not $state.NetworkPartialPath) { Write-Host 'Незавершённой копии нет.'; return }
                Clear-NetworkPartial $hash
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
    } catch {
        Write-Host ('Действие восстановления не выполнено: ' + $_.Exception.Message) -ForegroundColor Red
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

function Title([string]$Value) {
    Write-Host ''
    Write-Host ('=== ' + $Value + ' ===') -ForegroundColor Cyan
}
# Разрешает ввод только целого числа в заданном диапазоне.
function Choice([string]$Prompt, [int]$Maximum, [int]$Minimum = 0) {
    if ($Maximum -lt $Minimum) { throw 'Нет доступных вариантов для выбора.' }
    while ($true) {
        $answer = Read-Host $Prompt
        if ($null -eq $answer) {
            if ($Minimum -le 0 -and $Maximum -ge 0) { return 0 }
            throw [System.OperationCanceledException]::new('Ввод завершён.')
        }
        $s = $answer.Trim()
        $n = 0
        if ([int]::TryParse($s, [ref]$n) -and $n -ge $Minimum -and $n -le $Maximum) { return $n }
        Write-Host ('Введите число от {0} до {1}.' -f $Minimum, $Maximum) -ForegroundColor Yellow
    }
}
# Любое потенциально важное действие выполняется только после выбора «1».
# 0 и 2 отменяют действие, в том числе при подтверждении удаления данных.
function Confirm([string]$Prompt) {
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Yellow
    Write-Host '  1. Да, продолжить'
    Write-Host '  2. Нет, отменить'
    Write-Host '  0. Назад / отменить'
    return ((Choice 'Выберите 0, 1 или 2' 2) -eq 1)
}
# 0 также разрешён после завершения, отмены или сбоя операции.
function Pause-Menu {
    Write-Host '0. Назад'
    Write-Host '1. Вернуться в меню'
    [void](Choice 'Введите 0 или 1' 1)
}
# Проверяет ОС, архитектуру и права администратора.
function Ensure-Admin {
    if (-not [Environment]::Is64BitProcess) {
        throw 'Нужен 64-битный Windows PowerShell. Запустите Start.cmd из обычного проводника Windows.'
    }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($os.ProductType -ne 1 -or $os.Version -notmatch '^10\.') {
        throw 'Поддерживаются Windows 10 и 11.'
    }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        # UAC выполняет только Bootstrap.ps1. Повторное само-повышение
        # здесь порождало бесконечную цепочку powershell.exe.
        throw 'Повышенные права не получены. Запустите Start.cmd и подтвердите один запрос UAC; при отказе программа завершится.'
    }
}
# Ищет USMT в папке комплекта и в стандартном каталоге Windows ADK.
function Get-UsmtPath {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $kit = ${env:ProgramFiles(x86)}
    if (-not $kit) { $kit = $env:ProgramFiles }
    $paths = @(
        (Join-Path $Script:ToolRoot ("USMT\" + $arch)),
        (Join-Path $Script:ToolRoot 'USMT'),
        (Join-Path $kit ("Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool\" + $arch))
    )
    foreach ($dir in $paths) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $required = @('ScanState.exe','LoadState.exe','UsmtUtils.exe')
        if (@($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dir $_) -PathType Leaf) }).Count -eq 0) {
            return $dir
        }
    }
    return $null
}
# Выбирает официальный загрузчик ADK в зависимости от сборки Windows.
function Get-ADKDownload {
    $v = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion' -ErrorAction SilentlyContinue
    if ($v -eq '26H1') {
        return [pscustomobject]@{ Label='Windows ADK 10.1.28000.3481'; Url='https://go.microsoft.com/fwlink/?linkid=2337875' }
    }
    return [pscustomobject]@{ Label='Windows ADK 10.1.26100.9457'; Url='https://go.microsoft.com/fwlink/?linkid=2289980' }
}
# Проверяет подпись Microsoft у установщика перед запуском.
function Test-OfficialInstaller([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -lt 100KB) { return $false }
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    return ($sig.Status -eq 'Valid' -and $null -ne $sig.SignerCertificate -and
        ([string]$sig.SignerCertificate.Subject -match '(^|,)\s*(O|CN)=Microsoft Corporation(,|$)'))
}
# Скачивает ADK и с отдельного согласия устанавливает только компонент USMT.
function Install-USMT {
    $item = Get-ADKDownload
    Title 'УСТАНОВКА USMT ИЗ MICROSOFT ADK'
    Write-Host ('Источник: ' + $item.Label)
    Write-Host 'Скачается установщик с сайта Microsoft, затем установится только USMT.'
    if (-not (Confirm 'Скачать официальный установщик Windows ADK?')) { return }
    $folder = Join-Path ([IO.Path]::GetTempPath()) ('WPM_ADK_' + [guid]::NewGuid().ToString('N'))
    $installer = Join-Path $folder 'adksetup.exe'
    $downloadProtocol = [Net.ServicePointManager]::SecurityProtocol
    [void](New-Item -ItemType Directory -Path $folder -ErrorAction Stop)
    $verificationLock = $null
    $proc = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = $downloadProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Progress -Id 1 -Activity 'Подготовка USMT' -Status 'Скачивание Windows ADK' -PercentComplete -1
        Invoke-WebRequest -Uri $item.Url -OutFile $installer -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 120
        # Пока проверяется подпись и работает процесс, файл открыт только для чтения.
        $verificationLock = [IO.File]::Open($installer,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if (-not (Test-OfficialInstaller $installer)) {
            throw 'Подпись установщика не прошла проверку. Установка остановлена.'
        }
        Advance-OperationStage 'Подпись установщика Microsoft проверена'
        if (-not (Confirm 'Установить компонент USMT?')) { return }
        Write-Progress -Id 1 -Activity 'Подготовка USMT' -Status 'Установка компонента USMT' -PercentComplete -1
        $installerArguments = '/quiet /norestart /ceip off /features OptionId.UserStateMigrationTool'
        $proc = Start-Process -FilePath $installer -ArgumentList $installerArguments -PassThru -Wait -WorkingDirectory $folder -ErrorAction Stop
        $code = $proc.ExitCode
        Write-OperationReport 'ДИАГНОСТИКА' ('Код завершения установщика ADK: ' + $code)
        if ($null -eq $code -or $code -notin @(0,3010)) { throw ('Ошибка установщика ADK, код ' + $code) }
        if ($code -eq 3010) {
            $Script:RestartRequired = $true
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Для работы USMT потребуется перезагрузка Windows.'
            Write-Host 'Для работы потребуется перезагрузка Windows.' -ForegroundColor Yellow
            return
        }
        if (-not (Get-UsmtPath)) { throw 'Установка завершилась, но USMT не обнаружен.' }
        Advance-OperationStage 'Компонент USMT установлен'
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $downloadProtocol
        if ($proc) { $proc.Dispose() }
        if ($verificationLock) { $verificationLock.Dispose() }
        Write-Progress -Id 1 -Activity 'Подготовка USMT' -Completed
        try {
            $itemFolder = Get-Item -LiteralPath $folder -Force -ErrorAction Stop
            if ($itemFolder.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Временная папка установщика была заменена ссылкой.'
            }
            [IO.File]::Delete($installer)
            [IO.Directory]::Delete($folder)
        } catch {
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Папка установщика оставлена: ' + $folder + '; ' + $_.Exception.Message)
            Write-Host ('Не удалось очистить папку установщика: ' + $folder) -ForegroundColor Yellow
        }
    }
}
# Если USMT не найден, предлагает числовые варианты установки, повторного поиска или выхода.
function Require-USMT {
    while ($true) {
        if ($Script:RestartRequired) { return $null }
        $found = Get-UsmtPath
        if ($found) { return $found }
        Title 'USMT НЕ НАЙДЕН'
        Write-Host '1. Скачать и установить с сайта Microsoft'
        Write-Host '2. Повторить поиск (если USMT скопировали рядом со скриптом)'
        Write-Host '0. Назад'
        switch (Choice 'Выберите пункт' 2) {
            1 { Install-USMT }
            2 { }
            0 { return $null }
        }
    }
}
# Готовит кавычки для аргументов Windows. Нужен и для UNC, и для каталогов с пробелами.
function Quote-WindowsArgument([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    # Правила CreateProcess: экранируем кавычки и завершающие обратные слеши.
    $result = '"'
    [int]$slashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') { $slashes++; continue }
        if ($char -eq '"') {
            $result += ('\' * ($slashes * 2 + 1)) + '"'
            $slashes=0
            continue
        }
        if ($slashes) { $result += ('\' * $slashes); $slashes=0 }
        $result += $char
    }
    if ($slashes) { $result += ('\' * ($slashes*2)) }
    return $result + '"'
}
# Считывает точные проценты только из журнала USMT totalPercentageCompleted.
# Пока USMT не выдал число, показывает неопределённый ход без фиктивных процентов.
function Show-UsmtProgress([string]$ProgressPath,[string]$Caption) {
    $last = $null
    if ($ProgressPath -and (Test-Path -LiteralPath $ProgressPath -PathType Leaf)) {
        try {
            $tail = @(Get-Content -LiteralPath $ProgressPath -Tail 100 -ErrorAction Stop)
            foreach ($line in $tail) {
                if ($line -match '(?i)\btotalPercentageCompleted"?\s*[,=: ]\s*"?(\d{1,3}(?:[.,]\d+)?)(?=$|["\s;]|,(?!\d))') {
                    [double]$value = 0
                    if ([double]::TryParse($Matches[1].Replace(',','.'),[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -and $value -le 100) {
                        $last = [int][Math]::Floor($value)
                    }
                }
            }
        } catch { }
    }
    if ($null -ne $last) {
        Write-Progress -Id 1 -Activity $Caption -Status ('USMT: ' + $last + '%') -PercentComplete $last
    } else {
        Write-Progress -Id 1 -Activity $Caption -Status 'Работает USMT, ожидаем данные о прогрессе...'
    }
}
# Во время ScanState, LoadState и сетевого копирования можно запросить отмену.
# Чтение клавиши не блокирует прогресс; без интерактивной консоли отключается.
function Test-RunningProcessStopRequest([string]$Activity,[int]$ProgressId) {
    $pressed = $null
    try {
        if ([Console]::IsInputRedirected -or -not [Console]::KeyAvailable) { return $false }
        $pressed = [Console]::ReadKey($true)
    } catch {
        # В ISE/перенаправленной консоли ReadKey может быть недоступен.
        return $false
    }
    if ($pressed.KeyChar -ne '0') { return $false }
    Write-Progress -Id $ProgressId -Activity $Activity -Completed
    Write-Host ('Запрошена остановка: ' + $Activity + '. Уже перенесённые данные не удаляются автоматически.') -ForegroundColor Yellow
    return (Confirm ('Остановить выполняемый процесс: ' + $Activity + '?'))
}
# Запускает USMT и обновляет индикатор в течение выполнения процесса.
function Invoke-USMT([string]$File,[string[]]$Options,[string]$WorkingPath,[string]$ProgressPath = '') {
    $argLine = (@($Options | ForEach-Object { Quote-WindowsArgument ([string]$_) }) -join ' ')
    $proc = $null
    $code = $null
    try {
        $proc = Start-Process -FilePath $File -WorkingDirectory $WorkingPath -ArgumentList $argLine -PassThru -NoNewWindow -ErrorAction Stop
        # В Windows PowerShell Start-Process -NoNewWindow может вернуть null
        # в ExitCode после ожидания. Раннее обращение к Handle сохраняет дескриптор.
        [void]$proc.Handle
        Write-Host 'Во время работы USMT нажмите клавишу 0 (без Enter), чтобы запросить отмену.' -ForegroundColor Yellow
        while (-not $proc.WaitForExit(950)) {
            Show-UsmtProgress $ProgressPath ('Миграция: '+[IO.Path]::GetFileNameWithoutExtension($File))
            if (Test-RunningProcessStopRequest 'USMT' 1) {
                if ($proc.HasExited) { break }
                # Останавливаем только дочерний процесс, запущенный этой операцией.
                # Удаление целевого профиля и исходных данных не выполняется.
                try { $proc.Kill() }
                catch [InvalidOperationException] {
                    if ($proc.HasExited) { break }
                    throw
                }
                if (-not $proc.WaitForExit(30000)) {
                    throw 'USMT не подтвердил завершение после запроса остановки.'
                }
                throw [System.OperationCanceledException]::new(('USMT остановлен пользователем: ' + [IO.Path]::GetFileName($File)))
            }
        }
        Show-UsmtProgress $ProgressPath ('Миграция: '+[IO.Path]::GetFileNameWithoutExtension($File))
        $code = $proc.ExitCode
    } finally {
        Write-Progress -Id 1 -Activity 'USMT' -Completed
        if ($proc) { $proc.Dispose() }
    }
    if ($null -eq $code) {
        throw 'Не удалось прочитать код завершения USMT. Проверьте журнал запуска; успех не подтверждён.'
    }
    Write-OperationReport 'ДИАГНОСТИКА' ('Код завершения ' + [IO.Path]::GetFileName($File) + ': ' + $code)
    if ($code -ne 0) {
        Append-UsmtLogTail $Options
        $action = if (@($Options | Where-Object { $_ -like '/genconfig:*' }).Count -gt 0) {
            'при подготовке Config.xml'
        } else { 'при выполнении миграции' }
        throw ('USMT ({0}) {1} вернул код {2}. Проверьте журнал.' -f [IO.Path]::GetFileName($File),$action,$code)
    }
}
# Собирает обычные пользовательские профили и исключает системные учётные записи.
function Get-UserProfiles {
    $rows = @()
    foreach ($p in @(Get-CimInstance -ClassName Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath })) {
        try {
            $account = ([Security.Principal.SecurityIdentifier]::new([string]$p.SID)).Translate([Security.Principal.NTAccount]).Value
            $parts = $account -split '\\', 2
            if ($parts.Count -ne 2) { continue }
            if ($parts[0] -match '^(NT AUTHORITY|NT SERVICE|BUILTIN|Window Manager|Font Driver Host)$') { continue }
            $kind = if ($parts[0] -ieq $env:COMPUTERNAME) { 'Local' }
                elseif ($parts[0] -in @('MicrosoftAccount','AzureAD')) { 'Unsupported' } else { 'Domain' }
            $rows += [pscustomobject]@{ Account=$account; SID=[string]$p.SID; Path=[string]$p.LocalPath;
                Type=$kind; Loaded=[bool]$p.Loaded }
        } catch { }
    }
    return @($rows | Sort-Object Account)
}
# Определяет владельца Explorer в текущей сессии, не подменяя его учёткой администратора UAC.
function Get-SessionUserProfile([object[]]$Profiles) {
    # RunAs may replace WindowsIdentity with an administrator account. Explorer
    # in the current desktop SessionId keeps the actual signed-in user's SID.
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $sids = @()
    $shells = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -eq $sessionId })
    foreach ($shell in $shells) {
        try {
            $owner = Invoke-CimMethod -InputObject $shell -MethodName GetOwnerSid
            if ($owner.ReturnValue -eq 0 -and $owner.Sid) { $sids += [string]$owner.Sid }
        } catch { }
    }
    $sids = @($sids | Select-Object -Unique)
    $matches = @($Profiles | Where-Object { $_.SID -in $sids })
    if ($matches.Count -eq 1) { return $matches[0] }
    # When several sessions are present, NEVER silently choose an administrator.
    return $null
}
# Предлагает профиль пользователя сеанса только если он выгружен из Windows.
# Загруженный профиль не рекомендуется для согласованного экспорта.
function Select-Profile {
    $profiles = @(Get-UserProfiles | Where-Object { $_.Type -ne 'Unsupported' })
    if ($profiles.Count -eq 0) { throw 'Не найдены поддерживаемые пользовательские профили.' }
    $current = Get-SessionUserProfile -Profiles $profiles
    Title 'ВЫБОР ПРОФИЛЯ'
    if ($current) {
        Write-Host ('Обнаружен пользователь сеанса: ' + $current.Account) -ForegroundColor Green
        Write-Host ('Профиль: ' + $current.Path)
        if ($current.Loaded) {
            Write-Host 'Профиль пользователя сеанса загружен. Для экспорта выберите пользователя, который вышел из Windows.' -ForegroundColor Yellow
        } else {
            Write-Host '1. Выбрать профиль пользователя сеанса'
            Write-Host '2. Выбрать другой профиль из списка'
            Write-Host '0. Назад'
            switch (Choice 'Выберите пункт' 2) {
                1 { return $current }
                2 { }
                0 { return $null }
            }
        }
    } else {
        Write-Host 'Владелец текущего интерактивного сеанса не определён однозначно.' -ForegroundColor Yellow
        Write-Host 'Выберите профиль цифрой. Учётная запись администратора не подставляется автоматически.'
    }
    for ($i=0; $i -lt $profiles.Count; $i++) {
        $p = $profiles[$i]
        $status = if ($p.Loaded) { ' | ЗАГРУЖЕН' } else { '' }
        Write-Host ('{0}. {1} | {2} | {3}{4}' -f ($i+1), $p.Account, $p.Type, $p.Path, $status)
    }
    Write-Host '0. Назад'
    $n = Choice 'Номер профиля' $profiles.Count
    if ($n -eq 0) { return $null }
    return $profiles[$n-1]
}
# Показывает доступные диски для выбора места хранения.
function Get-DriveOptions {
    return @(Get-CimInstance Win32_LogicalDisk | Where-Object {
        $_.DriveType -in @(2,3) -and $_.DeviceID -and $_.FreeSpace -ne $null
    } | Sort-Object DeviceID)
}

# Преобразует объём в удобные КБ/МБ/ГБ/ТБ для меню и отчётов.
function Format-ByteSize([UInt64]$Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:N2} ТБ' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} МБ' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} КБ' -f ($Bytes / 1KB)) }
    return ($Bytes.ToString() + ' Б')
}
# Подключает системную WinAPI для определения свободного места, включая UNC-пути.
function Ensure-DiskFreeApi {
    if (-not ([System.Management.Automation.PSTypeName]'WpmDiskFree').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WpmDiskFree {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool GetDiskFreeSpaceEx(string p, out ulong available, out ulong capacity, out ulong unused);
}
'@ -ErrorAction Stop
    }
}
# Получает свободное место на локальном диске или UNC через WinAPI.
# Если определить объём невозможно, выдаёт ошибку: миграцию начинать небезопасно.
function Get-PathFreeBytes([string]$Path) {
    Ensure-DiskFreeApi
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd([char]'\') + '\'
        [UInt64]$free = 0; [UInt64]$cap = 0; [UInt64]$unused = 0
        $ok = [WpmDiskFree]::GetDiskFreeSpaceEx($full, [ref]$free, [ref]$cap, [ref]$unused)
        if (-not $ok) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $reason = ([ComponentModel.Win32Exception]::new($code)).Message
            throw ('Windows не смогла определить свободное место: ' + $reason + ' (код ' + $code + ')')
        }
        return $free
    } catch {
        throw ('Нельзя проверить свободное место для ' + $Path + '. Операция остановлена. ' + $_.Exception.Message)
    }
}
# Считает размер и число файлов без подавления ошибок доступа.
# Переходы через junction/symlink намеренно не выполняются, иначе возможны циклы.
# Если не получается прочитать хотя бы один каталог, результат НЕ используется как оценка.
function Get-FolderMetrics([string]$Path,[int]$SampleCount = 0) {
    [UInt64]$bytes = 0
    [Int64]$files = 0
    [Int64]$links = 0
    $samples = [Collections.Generic.List[string]]::new()
    try {
        $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $root.PSIsContainer) { throw 'Указанный путь не является каталогом.' }
        if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Указанный каталог является ссылкой.' }
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push([string]$root.FullName)
        while ($pending.Count -gt 0) {
            $current = $pending.Pop()
            try {
                foreach ($item in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $links++
                        continue
                    }
                    if ($item.PSIsContainer) {
                        $pending.Push([string]$item.FullName)
                    } else {
                        $bytes = [UInt64]($bytes + [UInt64]$item.Length)
                        $files++
                        if ($samples.Count -lt $SampleCount) { $samples.Add([string]$item.FullName) }
                    }
                }
            } catch {
                throw ('Ошибка чтения каталога ' + $current + ': ' + $_.Exception.Message)
            }
        }
    } catch {
        throw ('Подсчёт размера не завершён для ' + $Path + '. Миграция остановлена, чтобы не занизить объём. ' + $_.Exception.Message)
    }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files; SkippedLinks = $links; Samples = $samples.ToArray() }
}
# Запоминает стандартные папки и небольшую выборку файлов для проверки после импорта.
function Get-ProfileValidationBaseline([string]$ProfilePath) {
    $dirs = @('Desktop','Documents','Downloads','Pictures','AppData\Roaming')
    $resultDirs = @()
    $samples = @()
    foreach ($rel in $dirs) {
        $directory = Get-ProfileDataItem $ProfilePath $rel
        $exists = $directory -and $directory.PSIsContainer
        [UInt64]$bytes = 0
        [Int64]$files = 0
        if ($exists) {
            $m = Get-FolderMetrics $directory.FullName 3
            $bytes = [UInt64]$m.Bytes
            $files = [Int64]$m.Files
            foreach ($item in $m.Samples) {
                if ($item.Length -gt $ProfilePath.Length) {
                    $samples += $item.Substring($ProfilePath.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
                }
            }
        }
        $resultDirs += [pscustomobject]@{ RelativePath = $rel; Exists = $exists; FileCount = $files; TotalBytes = $bytes }
    }
    return [pscustomobject]@{
        Directories = $resultDirs
        SampleFiles = @($samples | Select-Object -Unique | Select-Object -First 12)
    }
}
# Единая область проверки: стандартные пользовательские каталоги, без AppData.
# Реестр создаётся ДО ScanState и заново проверяется ПОСЛЕ ScanState.
function Get-ValidationSourceDirectories {
    return @('Desktop','Documents','Downloads','Pictures','Music','Videos','Favorites','Saved Games')
}
# Читаем файл напрямую через .NET-поток, чтобы скрытые и системные файлы
# (например, desktop.ini) не отсеивались PowerShell FileSystemProvider.
# Закрытие потока выполняется также при ошибке чтения.
function Get-ExactFileSha256([string]$Path) {
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        return (Get-FileHash -InputStream $stream -Algorithm SHA256 -ErrorAction Stop).Hash
    } finally {
        $stream.Dispose()
    }
}
# Сверяет SHA-256 двух ZIP по блокам, показывает реальный процент и
# позволяет остановить длительную проверку клавишей 0.
function Assert-CopiedZipHash([string]$Source,[string]$Destination) {
    $srcFile = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    $dstFile = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    if ($srcFile.PSIsContainer -or $dstFile.PSIsContainer -or $srcFile.Length -ne $dstFile.Length) {
        throw 'ZIP после копирования имеет другой размер или не является файлом.'
    }
    $hashSrc = [Security.Cryptography.SHA256]::Create()
    $hashDst = [Security.Cryptography.SHA256]::Create()
    $streamSrc = $null
    $streamDst = $null
    $bufferSrc = New-Object byte[] (1024 * 1024)
    $bufferDst = New-Object byte[] (1024 * 1024)
    [UInt64]$done = 0
    try {
        $streamSrc = [IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $streamDst = [IO.File]::Open($Destination,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sourceLength = $streamSrc.Length
        if ($sourceLength -ne $streamDst.Length) { throw 'ZIP изменился перед сверкой.' }
        while (($n = $streamSrc.Read($bufferSrc,0,$bufferSrc.Length)) -gt 0) {
            $readDst = 0
            while ($readDst -lt $n) {
                $got = $streamDst.Read($bufferDst,$readDst,$n-$readDst)
                if ($got -le 0) { throw 'Сетевая копия ZIP оборвалась при сверке.' }
                $readDst += $got
            }
            [void]$hashSrc.TransformBlock($bufferSrc,0,$n,$bufferSrc,0)
            [void]$hashDst.TransformBlock($bufferDst,0,$n,$bufferDst,0)
            $done = [UInt64]($done + [UInt64]$n)
            $percent = if ($sourceLength -gt 0) { [int][Math]::Floor(100.0 * $done / [double]$sourceLength) } else { 100 }
            Write-Progress -Id 5 -Activity 'Проверка ZIP после копирования' -Status ('Сверено: ' + (Format-ByteSize $done)) -PercentComplete $percent
            if (Test-RunningProcessStopRequest 'проверку ZIP' 5) {
                throw [System.OperationCanceledException]::new('Проверка ZIP остановлена пользователем.')
            }
        }
        if ($streamDst.Read($bufferDst,0,1) -ne 0) { throw 'В ZIP после копирования есть дополнительные байты.' }
        $emptyBlock = [byte[]]@()
        [void]$hashSrc.TransformFinalBlock($emptyBlock,0,0)
        [void]$hashDst.TransformFinalBlock($emptyBlock,0,0)
        $original = [BitConverter]::ToString($hashSrc.Hash).Replace('-','')
        $copy = [BitConverter]::ToString($hashDst.Hash).Replace('-','')
        if ($original -ne $copy) { throw 'SHA-256 ZIP не совпал после копирования. Архив не опубликован.' }
        return $original
    } finally {
        Write-Progress -Id 5 -Activity 'Проверка ZIP после копирования' -Completed
        if ($streamSrc) { $streamSrc.Dispose() }
        if ($streamDst) { $streamDst.Dispose() }
        $hashSrc.Dispose()
        $hashDst.Dispose()
    }
}
# Проверка едина для ZIP, путей в манифестах и архивов-каталогов.
function Assert-WindowsPathComponent([string]$Part) {
    if (-not $Part -or $Part.EndsWith('.') -or $Part.EndsWith(' ') -or
        $Part -match '[\x00-\x1f\\/:*?"<>|]' -or
        $Part -match '^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³]) *(\..*)?$') {
        throw ('Недопустимый компонент пути Windows: ' + $Part)
    }
}
function Get-WindowsRelativePathParts([string]$RelativePath) {
    $parts = $RelativePath -split '[\\/]'
    foreach ($part in $parts) { Assert-WindowsPathComponent $part }
    return $parts
}

# Проверяем каждый компонент до входа в каталог. Отсутствующий объект
# или точку повторной обработки считаем недоступными внутри профиля.
function Get-ProfileDataItem([string]$ProfilePath,[string]$RelativePath) {
    $parts = @(Get-WindowsRelativePathParts $RelativePath)
    try {
        $item = Get-Item -LiteralPath $ProfilePath -Force -ErrorAction Stop
        foreach ($part in $parts) {
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
            $item = Get-Item -LiteralPath ([IO.Path]::Combine($item.FullName,$part)) -Force -ErrorAction Stop
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $null }
        return $item
    } catch [System.Management.Automation.ItemNotFoundException] { return $null }
}
# Проверяем существующие предки до создания каталога или копирования данных.
function Assert-NoReparseAncestor([string]$Path) {
    $pending = [Collections.Generic.Stack[string]]::new()
    for ($current = [IO.Path]::GetFullPath($Path); $current; $current = [IO.Path]::GetDirectoryName($current)) {
        $pending.Push($current)
    }
    while ($pending.Count -gt 0) {
        try { $item = Get-Item -LiteralPath $pending.Pop() -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { return }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw ('Путь проходит через ссылку: ' + $item.FullName)
        }
    }
}
# Формирует карту файлов готового архива, не следуя ссылкам/junction.
# При проверке сетевой публикации нужно сравнивать именно ВСЕ файлы,
# включая .mig, метаданные, контрольные реестры и дополнительные данные.
function Get-ArchiveFileMap([string]$ArchiveRoot) {
    Assert-NoReparseAncestor $ArchiveRoot
    $root = Get-Item -LiteralPath $ArchiveRoot -Force -ErrorAction Stop
    if (-not $root.PSIsContainer) { throw ('Архив не является каталогом: ' + $ArchiveRoot) }
    $base = [IO.Path]::GetFullPath([string]$root.FullName)
    $separator = [IO.Path]::DirectorySeparatorChar
    $files = @{}
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($base)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            Assert-WindowsPathComponent $item.Name
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw ('В архиве обнаружена ссылка, проверка остановлена: ' + $item.FullName)
            }
            if ($item.PSIsContainer) {
                $pending.Push([string]$item.FullName)
                continue
            }
            $relative = ([string]$item.FullName).Substring($base.Length).TrimStart($separator)
            if (-not $relative -or $files.ContainsKey($relative)) {
                throw ('Неоднозначное имя файла в архиве: ' + $item.FullName)
            }
            $files[$relative] = [pscustomobject]@{ Path=[string]$item.FullName; Length=[long]$item.Length }
        }
    }
    return $files
}

# Встроенный ZIP .NET не требует 7-Zip, WinRAR или сторонних программ.
function Initialize-ZipSupport {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
}
# Строго проверяет имена и размеры ZIP ДО распаковки в административном процессе.
# Защищает от путей с .., абсолютных путей, ссылок и повторяющихся имён.
function Get-ProfileZipInfo([string]$ZipPath) {
    Initialize-ZipSupport
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try { return Read-ProfileZipInfo $zip }
    finally { $zip.Dispose() }
}

function Read-BoundedArchiveMetadata([IO.Stream]$Stream,[long]$Length) {
    if ($Length -le 0 -or $Length -gt 2MB) { throw 'Размер metadata.json должен быть от 1 байта до 2 МБ.' }
    # ZIP сообщает заявленную длину, поэтому проверяем и фактический поток.
    $bytes = [byte[]]::new([int]$Length)
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $read = $Stream.Read($bytes,$offset,$bytes.Length - $offset)
        if ($read -le 0) { throw 'metadata.json обрезан.' }
        $offset += $read
    }
    if ($Stream.ReadByte() -ne -1) { throw 'Размер metadata.json не совпадает с содержимым.' }
    $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)
    try {
        $json = $reader.ReadToEnd().Trim()
        if (-not $json.StartsWith('{')) { throw 'metadata.json должен содержать один JSON-объект.' }
        $metadata = $json | ConvertFrom-Json -ErrorAction Stop
        if ($metadata -isnot [pscustomobject]) { throw 'metadata.json должен содержать один JSON-объект.' }
        return $metadata
    } finally { $reader.Dispose() }
}

function Read-ArchiveMetadataFile([string]$Path) {
    Assert-NoReparseAncestor $Path
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { return Read-BoundedArchiveMetadata $stream $stream.Length }
    finally { $stream.Dispose() }
}

function Read-ProfileZipInfo([IO.Compression.ZipArchive]$Zip) {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $filePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [UInt64]$expanded = 0
    [int]$storeFiles = 0
    $metaEntry = $null
    if ($Zip.Entries.Count -gt 1000000) { throw 'Слишком много записей в ZIP.' }
    foreach ($entry in $Zip.Entries) {
        $rel = [string]$entry.FullName
        $isDir = $rel.EndsWith('/')
        $name = if ($isDir) { $rel.Substring(0,$rel.Length - 1) } else { $rel }
        if (-not $seen.Add($name)) { throw ('Повторяющееся имя в ZIP: ' + $rel) }
        foreach ($part in $name.Split('/')) { Assert-WindowsPathComponent $part }
        # Windows reparse-point и Unix symlink внутри ZIP запрещены.
        if (($entry.ExternalAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000)) {
            throw ('Ссылка в ZIP запрещена: ' + $rel)
        }
        for ($slash = $name.LastIndexOf('/'); $slash -ge 0; $slash = $parent.LastIndexOf('/')) {
            $parent = $name.Substring(0,$slash)
            if ($filePaths.Contains($parent)) { throw ('Файл ZIP используется как каталог: ' + $parent) }
            if (-not $directories.Add($parent)) { break }
        }
        if ($isDir) {
            if ($entry.Length -ne 0) { throw ('Каталог ZIP содержит данные: ' + $rel) }
            [void]$directories.Add($name)
            continue
        }
        if ($directories.Contains($name)) { throw ('Файл ZIP используется как каталог: ' + $name) }
        [void]$filePaths.Add($name)
        if ($entry.Length -lt 0 -or $expanded -gt ([UInt64]::MaxValue - [UInt64]$entry.Length)) {
            throw 'Недопустимый размер ZIP.'
        }
        $expanded = [UInt64]($expanded + [UInt64]$entry.Length)
        if ($name -ceq 'metadata.json') { $metaEntry = $entry }
        if ($name -match '^Store/.+\.mig$') { $storeFiles++ }
    }
    if (-not $metaEntry -or $storeFiles -ne 1) {
        throw 'ZIP должен содержать metadata.json размером до 2 МБ и ровно одно USMT-хранилище.'
    }
    $stream = $metaEntry.Open()
    try { $meta = Read-BoundedArchiveMetadata $stream $metaEntry.Length }
    finally { $stream.Dispose() }
    return [pscustomobject]@{ Metadata=$meta; ExpandedBytes=$expanded; Files=$filePaths.Count }
}
# Сжимает каталог в один ZIP с поддержкой больших файлов (ZIP64) и клавиши 0.
function Compress-ProfileArchive([string]$Source,[string]$ZipPath) {
    Initialize-ZipSupport
    Write-Host 'Во время упаковки ZIP нажмите 0 без Enter, чтобы запросить отмену.' -ForegroundColor Yellow
    $items = Get-ArchiveFileMap $Source
    if ($items.Count -eq 0) { throw 'Нечего упаковывать: каталог архива пуст.' }
    [UInt64]$total = 0
    foreach ($f in $items.Values) { $total = [UInt64]($total + [UInt64]$f.Length) }
    [UInt64]$done = 0
    [int]$fileCount = 0
    $buffer = New-Object byte[] (1024 * 1024)
    $zipStream = [IO.File]::Open($ZipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $zip = $null
    try {
        $zip = [IO.Compression.ZipArchive]::new($zipStream,[IO.Compression.ZipArchiveMode]::Create,$false,[Text.Encoding]::UTF8)
        foreach ($rel in @($items.Keys | Sort-Object)) {
            $file = $items[$rel]
            $entryName = $rel.Replace('\','/')
            $level = if ($entryName -match '(?i)\.(mig|img|zip|7z|jpg|jpeg|png|mp4)$') {
                [IO.Compression.CompressionLevel]::NoCompression
            } else { [IO.Compression.CompressionLevel]::Optimal }
            $entry = $zip.CreateEntry($entryName,$level)
            $entryStream = $entry.Open()
            try {
                $inputStream = [IO.File]::Open($file.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                try {
                    while (($n = $inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                        $entryStream.Write($buffer,0,$n)
                        $done = [UInt64]($done + [UInt64]$n)
                        $percent = if ($total -gt 0) { [int][Math]::Floor(100.0 * $done / $total) } else { 100 }
                        Write-Progress -Id 6 -Activity 'Упаковка профиля в ZIP' -Status ('Файлов: ' + $fileCount + ' из ' + $items.Count) -PercentComplete $percent
                        if (Test-RunningProcessStopRequest 'упаковку ZIP' 6) {
                            throw [System.OperationCanceledException]::new('Упаковка ZIP остановлена пользователем.')
                        }
                    }
                } finally { $inputStream.Dispose() }
            } finally { $entryStream.Dispose() }
            $fileCount++
        }
    } finally {
        Write-Progress -Id 6 -Activity 'Упаковка профиля в ZIP' -Completed
        if ($zip) { $zip.Dispose() }
        $zipStream.Dispose()
    }
    $info = Get-ProfileZipInfo $ZipPath
    if ($info.Files -ne $items.Count -or $info.ExpandedBytes -ne $total) {
        throw 'Упаковка ZIP не прошла проверку состава и размеров.'
    }
    Write-OperationReport 'АРХИВ' ('Создан ZIP: ' + (Format-ByteSize ([UInt64](Get-Item -LiteralPath $ZipPath).Length)) +
        '; файлов: ' + $info.Files + '; исходный объём: ' + (Format-ByteSize $total))
}
# Распаковывает ZIP в пустой локальный каталог; каждый путь проверен заранее.
function Expand-ProfileArchive([string]$ZipPath,[string]$Destination) {
    Initialize-ZipSupport
    Write-Host 'Во время распаковки ZIP нажмите 0 без Enter, чтобы запросить отмену.' -ForegroundColor Yellow
    $separator = [IO.Path]::DirectorySeparatorChar
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd($separator)
    $prefix = $root + $separator
    [UInt64]$done = 0
    $buffer = New-Object byte[] (1024 * 1024)
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        # Проверяем тот же открытый ZIP, который будем читать. На Windows
        # файловый дескриптор не разрешает в это время запись или подмену.
        $info = Read-ProfileZipInfo $zip
        if (Test-Path -LiteralPath $root) { throw 'Каталог распаковки уже существует.' }
        Assert-NoReparseAncestor $root
        $free = Get-PathFreeBytes ([IO.Path]::GetDirectoryName($root))
        if ([double]$free -lt ([double]$info.ExpandedBytes + 1GB)) {
            throw 'Недостаточно места для распаковки открытого ZIP с резервом 1 ГБ.'
        }
        [void][IO.Directory]::CreateDirectory($root)
        foreach ($entry in $zip.Entries) {
            $full = [IO.Path]::GetFullPath((Join-Path $root ($entry.FullName.Replace([char]'/', $separator))))
            if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
                throw ('ZIP содержит путь за пределами папки распаковки: ' + $entry.FullName)
            }
            if ($entry.FullName.EndsWith('/')) {
                [void][IO.Directory]::CreateDirectory($full)
                continue
            }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
            $inputStream = $entry.Open()
            try {
                $outputStream = [IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try {
                    [UInt64]$entryBytes = 0
                    while (($n = $inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                        $entryBytes = [UInt64]($entryBytes + [UInt64]$n)
                        if ($entryBytes -gt [UInt64]$entry.Length) { throw ('Размер ZIP не совпадает с данными: ' + $entry.FullName) }
                        $outputStream.Write($buffer,0,$n)
                        $done = [UInt64]($done + [UInt64]$n)
                        $percent = if ($info.ExpandedBytes -gt 0) { [int][Math]::Floor(100.0 * $done / $info.ExpandedBytes) } else { 100 }
                        Write-Progress -Id 6 -Activity 'Распаковка архива' -Status ('Распаковано: ' + (Format-ByteSize $done)) -PercentComplete $percent
                        if (Test-RunningProcessStopRequest 'распаковку ZIP' 6) {
                            throw [System.OperationCanceledException]::new('Распаковка ZIP остановлена пользователем.')
                        }
                    }
                    if ($entryBytes -ne [UInt64]$entry.Length) { throw ('Файл ZIP распакован не полностью: ' + $entry.FullName) }
                } finally { $outputStream.Dispose() }
            } finally { $inputStream.Dispose() }
        }
    } finally {
        Write-Progress -Id 6 -Activity 'Распаковка архива' -Completed
        $zip.Dispose()
    }
    if ($done -ne $info.ExpandedBytes) { throw 'Общий размер распакованных файлов не совпал с ZIP.' }
    Write-OperationReport 'АРХИВ' ('ZIP распакован: ' + $info.Files + ' файлов, ' + (Format-ByteSize $done))
}
# UsmtUtils /verify:all уже выполнил проверку ЛОКАЛЬНОГО .mig.
# Для сетевой публикации сравниваем SHA-256 каждого файла с исходником,
# поскольку UsmtUtils может не принять UNC-путь и вернуть код 27.
function Assert-NetworkArchiveCopy([string]$Source,[string]$Destination) {
    Write-Host 'Проверка сетевой копии: SHA-256 всех файлов...' -ForegroundColor Cyan
    $sourceFiles = Get-ArchiveFileMap $Source
    $targetFiles = Get-ArchiveFileMap $Destination
    if ($sourceFiles.Count -eq 0) { throw 'Исходный архив пуст. Публикация остановлена.' }
    if ($sourceFiles.Count -ne $targetFiles.Count) {
        throw ('В сетевой копии другое количество файлов: исходно {0}, в сети {1}.' -f $sourceFiles.Count,$targetFiles.Count)
    }
    [int]$checked = 0
    [UInt64]$checkedBytes = 0
    try {
        foreach ($relative in @($sourceFiles.Keys | Sort-Object)) {
            if (-not $targetFiles.ContainsKey($relative)) {
                throw ('В сетевой копии отсутствует файл: ' + $relative)
            }
            $original = $sourceFiles[$relative]
            $copy = $targetFiles[$relative]
            if ($original.Length -ne $copy.Length) {
                throw ('Не совпадает размер файла сетевой копии: ' + $relative)
            }
            try {
                $originalHash = Get-ExactFileSha256 $original.Path
                $copyHash = Get-ExactFileSha256 $copy.Path
            } catch {
                throw ('Не удалось вычислить SHA-256 файла ' + $relative + ': ' + $_.Exception.Message)
            }
            if ($originalHash -ne $copyHash) {
                throw ('Не совпадает SHA-256 файла сетевой копии: ' + $relative)
            }
            $checked++
            $checkedBytes = [UInt64]($checkedBytes + [UInt64]$original.Length)
            Write-Progress -Id 5 -Activity 'Проверка сетевой копии' -Status ('Сверено файлов: ' + $checked + ' из ' + $sourceFiles.Count) -PercentComplete ([int][Math]::Floor(100.0 * $checked / $sourceFiles.Count))
            if (Test-RunningProcessStopRequest 'проверку сетевой копии' 5) {
                throw [System.OperationCanceledException]::new('Проверка сетевой копии остановлена пользователем.')
            }
        }
    } finally {
        Write-Progress -Id 5 -Activity 'Проверка сетевой копии' -Completed
    }
    Write-OperationReport 'ПРОВЕРКА' ('Сетевая копия: SHA-256 совпал для {0} файлов ({1}).' -f $checked,(Format-ByteSize $checkedBytes))
}
# Обход без следования junction/symlink и без подавления ошибок доступа.
function Get-ValidationSourceFiles([string]$ProfilePath) {
    foreach ($rel in @(Get-ValidationSourceDirectories)) {
        $dir = Get-ProfileDataItem $ProfilePath $rel
        if (-not $dir -or -not $dir.PSIsContainer) { continue }
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push([string]$dir.FullName)
        while ($pending.Count -gt 0) {
            $current = $pending.Pop()
            foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($child.PSIsContainer) { $pending.Push([string]$child.FullName) }
                else { $child }
            }
        }
    }
}
function Read-ValidationManifestRecord([string]$Line) {
    if (-not $Line.TrimStart().StartsWith('{')) { throw 'Недопустимая запись контрольного реестра.' }
    $record = $Line | ConvertFrom-Json -ErrorAction Stop
    $relative = @(Get-WindowsRelativePathParts ([string]$record.RelativePath)) -join '\'
    if (($record.Length -isnot [int] -and $record.Length -isnot [long]) -or $record.Length -lt 0 -or
        [string]$record.SHA256 -notmatch '\A[0-9a-fA-F]{64}\z') {
        throw ('Недопустимый размер или SHA-256 в контрольном реестре: ' + $relative)
    }
    return [pscustomobject]@{ RelativePath=$relative; Length=[long]$record.Length; SHA256=[string]$record.SHA256 }
}
function New-ValidationManifest([string]$ProfilePath,[string]$Archive) {
    $valDir = Join-Path $Archive 'Validation'
    [void](New-Item -Path $valDir -ItemType Directory -Force)
    $filename = Join-Path $valDir 'files.jsonl'
    $writer = [IO.StreamWriter]::new($filename,$false,[Text.UTF8Encoding]::new($false))
    [long]$count = 0
    [long]$bytes = 0
    try {
        $root = [IO.Path]::GetFullPath($ProfilePath).TrimEnd([IO.Path]::DirectorySeparatorChar)
        Get-ValidationSourceFiles $ProfilePath | ForEach-Object {
            $file = $_
            $relative = $file.FullName.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
            try {
                $current = Get-ProfileDataItem $ProfilePath $relative
                if (-not $current -or $current.PSIsContainer) { throw 'Файл больше недоступен внутри профиля.' }
                $length = [long]$current.Length
                $hash = Get-ExactFileSha256 $file.FullName
            } catch {
                throw ('Не удалось вычислить SHA-256 ДО ScanState для ' + $relative + ': ' + $_.Exception.Message)
            }
            $line = [ordered]@{ RelativePath=$relative; Length=$length; SHA256=$hash } | ConvertTo-Json -Compress
            $writer.WriteLine($line)
            $count++
            $bytes += $length
            if (($count % 100) -eq 0) {
                Write-Progress -Id 2 -Activity 'SHA-256 перед ScanState' -Status ('Проверено файлов: ' + $count)
            }
        }
    } finally {
        $writer.Dispose()
        Write-Progress -Id 2 -Activity 'SHA-256 перед ScanState' -Completed
    }
    $sha = Get-ExactFileSha256 $filename
    Write-OperationReport 'ПРОВЕРКА' ("Исходный реестр ДО ScanState: файлов {0}, байт {1}. SHA-256: {2}" -f $count,$bytes,$sha)
    return [pscustomobject]@{ Path='Validation/files.jsonl'; Files=$count; Bytes=$bytes; Skipped=0; SHA256=$sha }
}
# Второй проход по всем контрольным файлам. Ловит изменения, удаление и добавление
# между созданием реестра и окончанием ScanState/экспорта Extras. Изменение
# означает, что архив нельзя объявлять согласованным; экспорт завершается ошибкой.
function Assert-ValidationSourceStable([string]$ProfilePath,[string]$Archive,[object]$Manifest) {
    $manifestPath = Join-Path $Archive 'Validation\files.jsonl'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Контрольный реестр отсутствует.' }
    if ([string](Get-ExactFileSha256 $manifestPath) -ne [string]$Manifest.SHA256) {
        throw 'Файл контрольного реестра изменился после первоначального создания.'
    }
    $expected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$checked = 0
    [long]$changed = 0
    $details = New-Object 'System.Collections.Generic.List[string]'
    $reader = [IO.StreamReader]::new($manifestPath,[Text.Encoding]::UTF8)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { continue }
            $item = Read-ValidationManifestRecord $line
            $rel = $item.RelativePath
            if (-not $expected.Add($rel)) { throw ('Повторяющийся путь в реестре: ' + $rel) }
            $checked++
            try {
                $file = Get-ProfileDataItem $ProfilePath $rel
                if (-not $file -or $file.PSIsContainer -or [long]$file.Length -ne $item.Length) {
                    $changed++
                    if ($details.Count -lt 15) { $details.Add('Изменён размер: ' + $rel) }
                } elseif ((Get-ExactFileSha256 $file.FullName) -ne $item.SHA256) {
                    $changed++
                    if ($details.Count -lt 15) { $details.Add('Изменён SHA-256: ' + $rel) }
                }
            } catch {
                $changed++
                if ($details.Count -lt 15) { $details.Add('Отсутствует или недоступен: ' + $rel) }
            }
            if (($checked % 100) -eq 0) {
                Write-Progress -Id 2 -Activity 'Сверка источника после ScanState' -Status ("Проверено {0}/{1}" -f $checked,$Manifest.Files) -PercentComplete ([int][Math]::Min(100,[Math]::Floor($checked * 100.0 / [Math]::Max(1,[long]$Manifest.Files))))
            }
        }
    } finally {
        $reader.Dispose()
        Write-Progress -Id 2 -Activity 'Сверка источника после ScanState' -Completed
    }
    if ($checked -ne [long]$Manifest.Files) { throw 'Изменилось число записей контрольного реестра.' }
    [long]$newFiles = 0
    $separator = [IO.Path]::DirectorySeparatorChar
    $root = [IO.Path]::GetFullPath($ProfilePath).TrimEnd($separator)
    Get-ValidationSourceFiles $ProfilePath | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart($separator).Replace($separator,[char]'\')
        if (-not $expected.Contains($rel)) {
            $newFiles++
            if ($details.Count -lt 15) { $details.Add('Новый файл: ' + $rel) }
        }
    }
    if ($changed -gt 0 -or $newFiles -gt 0) {
        foreach ($entry in @($details.ToArray())) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' $entry }
        throw ("Источник менялся во время экспорта: изменено/пропало {0}, новых файлов {1}. Архив не помечен готовым. Закройте сеанс пользователя и повторите экспорт." -f $changed,$newFiles)
    }
    Write-OperationReport 'ПРОВЕРКА' ('Все ' + $checked + ' контрольных файлов совпадают до и после ScanState; новых файлов нет.')
    return [pscustomobject]@{ Stable=$true; Method='HashBeforeScanAndCheckAfterScan'; Files=$checked; NewFiles=0; ChangedFiles=0; Scope='Desktop,Documents,Downloads,Pictures,Music,Videos,Favorites,Saved Games'; CompletedAt=(Get-Date).ToString('o') }
}
# Сверяет сам файл реестра с SHA-256 в metadata до импорта/проверки архива.
function Assert-ValidationManifestIntegrity([string]$Archive,[object]$Meta) {
    if ([int]$Meta.SchemaVersion -lt 6) { return }
    if (-not $Meta.ValidationManifest -or -not $Meta.ValidationManifest.SHA256 -or
        -not $Meta.ValidationConsistency -or -not $Meta.ValidationConsistency.Stable) {
        throw 'Архив v6 не содержит подтверждённой согласованности источника.'
    }
    $path = Join-Path $Archive 'Validation\files.jsonl'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Отсутствует реестр файлов.' }
    $actual = Get-ExactFileSha256 $path
    if ($actual -ne [string]$Meta.ValidationManifest.SHA256) {
        throw 'SHA-256 контрольного реестра отличается от сохранённого в метаданных.'
    }
    $info = $Meta.ValidationManifest
    if ($info.Path -ne 'Validation/files.jsonl' -or [long]$info.Files -lt 0 -or [long]$info.Bytes -lt 0) {
        throw 'Некорректные метаданные контрольного реестра.'
    }
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [decimal]$bytes = 0
    foreach ($line in [IO.File]::ReadLines($path)) {
        if (-not $line.Trim()) { continue }
        $record = Read-ValidationManifestRecord $line
        if (-not $paths.Add($record.RelativePath)) { throw ('Повторяющийся путь в реестре: ' + $record.RelativePath) }
        $bytes += $record.Length
        if ($paths.Count -gt [long]$info.Files -or $bytes -gt [long]$info.Bytes) {
            throw 'Контрольный реестр превышает количество файлов или суммарный размер в метаданных.'
        }
    }
    if ($paths.Count -ne [long]$info.Files -or $bytes -ne [long]$info.Bytes) {
        throw 'Количество файлов или суммарный размер контрольного реестра не совпадает с метаданными.'
    }
    Write-OperationReport 'ПРОВЕРКА' 'Контрольный реестр файлов прошёл проверку SHA-256.'
}
# Сверяет каждый файл реестра по пути, размеру и SHA-256 после LoadState.
# Несовпадения НЕ превращаем в успешный перенос, даже если код USMT равен 0.
function Test-ValidationManifest([string]$Archive,[string]$TargetPath,[object]$Meta) {
    if (-not ($Meta.PSObject.Properties.Name -contains 'ValidationManifest')) { return $null }
    $info=$Meta.ValidationManifest
    if (-not $info -or [string]$info.Path -ne 'Validation/files.jsonl') { throw 'Сведения о контрольном реестре повреждены.' }
    $path=Join-Path $Archive 'Validation\files.jsonl'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'В новом архиве отсутствует реестр контрольных сумм.' }
    [long]$expected=[long]$info.Files
    [long]$seen=0
    [long]$ok=0
    [long]$missing=0
    [long]$modified=0
    $examples = New-Object 'System.Collections.Generic.List[string]'
    $sr=[IO.StreamReader]::new($path,[Text.Encoding]::UTF8)
    try {
        while ($null -ne ($line=$sr.ReadLine())) {
            if (-not $line.Trim()) { continue }
            $item = Read-ValidationManifestRecord $line
            $rel = $item.RelativePath
            $seen++
            try {
                $actual = Get-ProfileDataItem $TargetPath $rel
                if (-not $actual -or $actual.PSIsContainer) {
                    $missing++
                    if ($examples.Count -lt 20) { $examples.Add('Отсутствует или находится по ссылке: '+$rel) }
                } elseif ([long]$actual.Length -ne $item.Length) {
                    $modified++
                    if ($examples.Count -lt 20) { $examples.Add('Размер отличается: '+$rel) }
                } elseif ((Get-ExactFileSha256 $actual.FullName) -ne $item.SHA256) {
                    $modified++
                    if ($examples.Count -lt 20) { $examples.Add('Контрольная сумма отличается: '+$rel) }
                } else { $ok++ }
            } catch {
                $modified++
                if ($examples.Count -lt 20) { $examples.Add('Нет доступа для проверки: '+$rel) }
            }
            if ($seen % 50 -eq 0 -or $seen -eq $expected) {
                $percent=if ($expected -gt 0) { [int][Math]::Min(100,[Math]::Floor($seen*100.0/$expected)) } else { 100 }
                Write-Progress -Id 3 -Activity 'Проверка восстановленных данных' -Status ("Файлов: {0}/{1}, совпали: {2}" -f $seen,$expected,$ok) -PercentComplete $percent
            }
        }
    } finally {
        $sr.Dispose()
        Write-Progress -Id 3 -Activity 'Проверка восстановленных данных' -Completed
    }
    if ($seen -ne $expected) { throw ("Нарушена целостность реестра файлов: ожидалось {0}, найдено {1}." -f $expected,$seen) }
    return [pscustomobject]@{ Total=$seen; Matched=$ok; Missing=$missing; Changed=$modified; Errors=@($examples.ToArray()); SourceSkipped=[long]$info.Skipped }
}
# Определяет сетевой путь вида \\сервер\папка.
function Test-IsUncPath([string]$Path) {
    return ($Path -like '\\*')
}
# Проверяет доступность пути с ограниченными повторными попытками.
function Ensure-PathAvailable([string]$Path,[string]$Caption,[int]$Attempts = 3,[int]$DelaySeconds = 3) {
    for ($i = 1; $i -le $Attempts; $i++) {
        if (Test-Path -LiteralPath $Path) { return }
        if ($i -lt $Attempts) {
            Write-Host ("{0} временно недоступен, повтор {1}/{2}..." -f $Caption,$i,$Attempts) -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    throw ($Caption + ' недоступен: ' + $Path)
}
# Создаёт уникальную локальную папку для подготовки/кеширования сетевого архива.
function New-StagingDirectory([string]$Prefix) {
    $base = Join-Path $env:ProgramData 'WindowsProfileMigration\Staging'
    Assert-NoReparseAncestor $base
    [void](New-Item -ItemType Directory -Path $base -Force -ErrorAction Stop)
    $dir = Join-Path $base ('{0}_{1}_{2}' -f $Prefix,(Get-Date -Format 'yyyyMMdd_HHmmss_fff'),([guid]::NewGuid().ToString('N').Substring(0,8)))
    [void](New-Item -ItemType Directory -Path $dir -ErrorAction Stop)
    return $dir
}
# Копирует каталог через Robocopy с повторами и контролем ошибок.
function Copy-DirectoryRobust([string]$Source,[string]$Destination,[string]$Purpose,[string]$FileName = '') {
    $src = [IO.Path]::GetFullPath($Source)
    $dst = [IO.Path]::GetFullPath($Destination)
    $parent = Split-Path -Parent $dst
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [void](New-Item -ItemType Directory -Path $dst -Force)
    $args = @($src,$dst)
    if ($FileName) {
        # Копирование ОДНОГО ZIP, без каталогов рядом с ним.
        if ([IO.Path]::GetFileName($FileName) -ne $FileName) { throw 'Недопустимое имя файла для копирования.' }
        $args += $FileName
    } else { $args += '/E' }
    $args += @('/Z','/XJ','/FFT','/R:3','/W:5','/NFL','/NDL','/NJH','/NJS','/NP','/COPY:DAT','/DCOPY:DAT')
    # Start-Process принимает строку с явно экранированными путями.
    $proc=$null
    try {
        # Robocopy работает с UNC и умеет докачивать после временного сетевого сбоя.
        # Пока он копирует файлы, показываем индикатор без неподтверждённых процентов.
        $argLine=(@($args | ForEach-Object { Quote-WindowsArgument ([string]$_) }) -join ' ')
        $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
        $proc=Start-Process -FilePath $robocopy -ArgumentList $argLine -NoNewWindow -PassThru -ErrorAction Stop
        # Не теряем код завершения при -NoNewWindow в Windows PowerShell 5.1.
        [void]$proc.Handle
        Write-Host 'Во время копирования нажмите клавишу 0 (без Enter), чтобы запросить отмену.' -ForegroundColor Yellow
        while (-not $proc.WaitForExit(950)) {
            Write-Progress -Id 4 -Activity $Purpose -Status 'Копирование файлов, возможны повторные попытки...'
            if (Test-RunningProcessStopRequest $Purpose 4) {
                if ($proc.HasExited) { break }
                try { $proc.Kill() }
                catch {
                    if ($proc.HasExited) { break }
                    throw
                }
                if (-not $proc.WaitForExit(30000)) {
                    throw 'Robocopy не подтвердил завершение после запроса остановки.'
                }
                throw [System.OperationCanceledException]::new(('Копирование остановлено пользователем: ' + $Purpose))
            }
        }
        $copyCode=$proc.ExitCode
    } finally {
        Write-Progress -Id 4 -Activity $Purpose -Completed
        if ($proc) { $proc.Dispose() }
    }
    if ($null -eq $copyCode) {
        throw ('Не удалось прочитать код завершения Robocopy: ' + $Purpose + '. Успех копирования не подтверждён.')
    }
    Write-OperationReport 'ДИАГНОСТИКА' ('Код завершения Robocopy: ' + $copyCode)
    if ($copyCode -lt 0 -or $copyCode -gt 7) {
        throw ('Robocopy не смог выполнить ' + $Purpose + '. Код: ' + $copyCode)
    }
}
# Определяет системную папку профилей Windows по настройкам реестра.
function Get-ProfileStoreRoot {
    $raw = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue).ProfilesDirectory
    if (-not $raw) { return ($env:SystemDrive + '\\Users') }
    return [Environment]::ExpandEnvironmentVariables([string]$raw)
}
# Перед импортом проверяет место на разделе профилей с дополнительным резервом.
function Test-TargetFreeSpace([UInt64]$RequiredBytes) {
    $root = Get-ProfileStoreRoot
    $driveRoot = [IO.Path]::GetPathRoot($root)
    $free = Get-PathFreeBytes $driveRoot
    $buffer = [UInt64]([Math]::Max([double]1GB,[double]([Math]::Ceiling([double]$RequiredBytes * 0.15))))
    $needed = [UInt64]([Math]::Max([double]2GB,[double]($RequiredBytes + $buffer)))
    if ($free -lt $needed) {
        throw ('Недостаточно места на диске профилей ' + $driveRoot + '. Нужно примерно ' + (Format-ByteSize $needed) + ', доступно ' + (Format-ByteSize $free) + '.')
    }
    Write-Host ('Свободное место на диске профилей: ' + (Format-ByteSize $free) + '; требуется не менее ' + (Format-ByteSize $needed)) -ForegroundColor Green
    Write-OperationReport 'ПРОВЕРКА' ('Свободное место на диске профилей: ' + (Format-ByteSize $free) + '; требуется не менее ' + (Format-ByteSize $needed))
}
# После LoadState сверяет наличие профиля, основных папок и выборки файлов. Это не полная побайтовая сверка.
function Validate-RestoredProfile([object]$Meta,[object]$TargetProfile) {
    if (-not (Test-Path -LiteralPath $TargetProfile.Path -PathType Container)) {
        throw ('После импорта каталог профиля не найден: ' + $TargetProfile.Path)
    }
    $baseline = $null
    if ($Meta.PSObject.Properties.Name -contains 'ValidationBaseline') { $baseline = $Meta.ValidationBaseline }
    if (-not $baseline) {
        $baseline = [pscustomobject]@{
            Directories = @(
                [pscustomobject]@{ RelativePath='Desktop'; Exists=$true; FileCount=0; TotalBytes=0 },
                [pscustomobject]@{ RelativePath='Documents'; Exists=$true; FileCount=0; TotalBytes=0 },
                [pscustomobject]@{ RelativePath='AppData\Roaming'; Exists=$true; FileCount=0; TotalBytes=0 }
            )
            SampleFiles = @()
        }
    }
    $missingDirs = @()
    $warns = @()
    $expectedDirs = 0
    $presentDirs = 0
    foreach ($dir in @($baseline.Directories)) {
        if (-not $dir.Exists) { continue }
        $expectedDirs++
        $dest = Get-ProfileDataItem $TargetProfile.Path ([string]$dir.RelativePath)
        if ($dest -and $dest.PSIsContainer) {
            $presentDirs++
            if ([Int64]$dir.FileCount -gt 0) {
                $m = Get-FolderMetrics $dest.FullName
                if ($m.Files -eq 0) {
                    $warns += ('Каталог пуст после восстановления: ' + $dir.RelativePath)
                }
            }
        } else {
            $missingDirs += [string]$dir.RelativePath
        }
    }
    $sampleTotal = 0
    $sampleMatched = 0
    $sampleMissing = @()
    foreach ($sample in @($baseline.SampleFiles)) {
        $sampleTotal++
        $targetFile = Get-ProfileDataItem $TargetProfile.Path ([string]$sample)
        if ($targetFile -and -not $targetFile.PSIsContainer) { $sampleMatched++ }
        else { $sampleMissing += [string]$sample }
    }
    if ($expectedDirs -gt 0 -and $presentDirs -eq 0) {
        throw 'После импорта не найдена ни одна из ожидаемых основных папок профиля.'
    }
    if ($sampleTotal -gt 0 -and $sampleMatched -eq 0) {
        throw 'После импорта не найден ни один из контрольных файлов профиля.'
    }
    return [pscustomobject]@{
        ExpectedDirectories = $expectedDirs
        PresentDirectories = $presentDirs
        MissingDirectories = $missingDirs
        SampleTotal = $sampleTotal
        SampleMatched = $sampleMatched
        MissingSamples = $sampleMissing
        Warnings = $warns
    }
}
# По умолчанию использует Backups рядом с Start.cmd; другие диски выбираются цифрой.
function Select-SaveLocation {
    # Default = folder containing Start.cmd/ProfileMigration.ps1, not %USERPROFILE%
    Title 'МЕСТО СОХРАНЕНИЯ'
    Write-Host ('1. По умолчанию: ' + $Script:BackupRoot) -ForegroundColor Green
    $drives = @(Get-DriveOptions)
    for ($i=0; $i -lt $drives.Count; $i++) {
        $d=$drives[$i]
        $gb=[Math]::Round(([double]$d.FreeSpace/1GB),1)
        Write-Host ('{0}. {1}\Backups (свободно {2} ГБ)' -f ($i+2),$d.DeviceID,$gb)
    }
    Write-Host '0. Назад'
    $choice = Choice 'Куда сохранить архив? Укажите номер' ($drives.Count+1)
    if ($choice -eq 0) { return $null }
    if ($choice -eq 1) { return $Script:BackupRoot }
    return (Join-Path ($drives[$choice-2].DeviceID + '\') 'Backups')
}
# Не даёт создать архив внутри исходного профиля; проверяет запись и доступный объём.
function Test-StoreLocation([string]$Root, [string]$SourcePath, [UInt64]$RequiredBytes = 0) {
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $profile = [IO.Path]::GetFullPath($SourcePath).TrimEnd('\')
    if ($full -ieq $profile -or $full.StartsWith(($profile+'\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Архив нельзя создавать внутри переносимого профиля: выберите внешний диск или разместите комплект в сетевой папке.'
    }
    Assert-NoReparseAncestor $Root
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $Root -Force -ErrorAction Stop)
    }
    $probe = Join-Path $Root ('.write_test_' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($probe, 'OK') }
    finally {
        try { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction Stop } }
        catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалён проверочный файл: ' + $probe) }
    }
    $free = Get-PathFreeBytes $Root
    $buffer = if ($RequiredBytes -gt 0) { [UInt64]([Math]::Max([double]1GB,[double]([Math]::Ceiling([double]$RequiredBytes * 0.15)))) } else { [UInt64]2GB }
    $needed = if ($RequiredBytes -gt 0) { [UInt64]($RequiredBytes + $buffer) } else { [UInt64]2GB }
    if ($free -lt $needed) {
        throw ('Недостаточно места в папке назначения. Нужно примерно ' + (Format-ByteSize $needed) + ', доступно ' + (Format-ByteSize $free) + '.')
    }
    Write-Host ('Свободно в папке назначения: ' + (Format-ByteSize $free) + '; требуется не менее ' + (Format-ByteSize $needed)) -ForegroundColor Green
    Write-OperationReport 'ПРОВЕРКА' ('Свободно в папке назначения: ' + (Format-ByteSize $free) + '; требуется не менее ' + (Format-ByteSize $needed))
}
# Находит файл .mig в USMT-хранилище и исключает неоднозначный архив.
function MigFile([string]$Store) {
    $files = @((Get-ArchiveFileMap $Store).Values | Where-Object { [IO.Path]::GetExtension($_.Path) -ieq '.mig' })
    if ($files.Count -ne 1) { throw ('В архиве должно быть ровно 1 файл .mig; найдено: ' + $files.Count) }
    return $files[0].Path
}
# Проверяет целостность файла .mig стандартным UsmtUtils.
function Verify-Store([string]$Usmt,[string]$Store,[string]$Logs) {
    [void](New-Item -ItemType Directory -Path $Logs -Force)
    $mig = MigFile $Store
    Write-Host 'Проверка целостности USMT...' -ForegroundColor Cyan
    Invoke-USMT (Join-Path $Usmt 'UsmtUtils.exe') @('/verify:all',$mig,('/l:'+(Join-Path $Logs 'verify.log')),'/v:5') $Usmt
}

# Optional browser/desktop data not guaranteed by USMT's stock XML rules.
# Browser files are deliberately limited to non-credential history/bookmarks/sessions.
# Перечень поддерживаемых браузеров: Chrome, Edge и Яндекс Браузер.
function Browser-Definitions {
    return @(
        [pscustomobject]@{ Name='Google Chrome'; Id='Chrome'; Relative='Google\Chrome\User Data'; Process='chrome.exe' },
        [pscustomobject]@{ Name='Microsoft Edge'; Id='Edge'; Relative='Microsoft\Edge\User Data'; Process='msedge.exe' },
        [pscustomobject]@{ Name='Яндекс Браузер'; Id='Yandex'; Relative='Yandex\YandexBrowser\User Data'; Process='browser.exe' }
    )
}
# Проверяет, запущен ли браузер именно от нужного пользователя.
function Get-OpenTargetBrowsers([string]$Sid) {
    $found = @()
    $names = @(Browser-Definitions | ForEach-Object Process)
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object { $_.Name -in $names })
    } catch {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Нельзя проверить, закрыты ли браузеры: ' + $_.Exception.Message)
        return $names
    }
    foreach ($proc in $processes) {
        try {
            $who = Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid -ErrorAction Stop
            if ($who.ReturnValue -ne 0 -or -not $who.Sid) {
                throw ('GetOwnerSid вернул код ' + $who.ReturnValue)
            }
            if ([string]$who.Sid -eq $Sid) { $found += $proc.Name }
        } catch {
            $found += $proc.Name
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не определён владелец процесса ' + $proc.Name + ': ' + $_.Exception.Message)
        }
    }
    return @($found | Sort-Object -Unique)
}

function Test-ExtraPathComponent([string]$Name) {
    return ($Name -and $Name -notmatch '[<>:"|?*\x00-\x1f]|[ .]$|^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)')
}

# Проверка идёт от корня к файлу, чтобы не открывать каталог за junction.
function Assert-ProfileExtraPath([string]$Path,[string]$Root,[bool]$AllowMissing = $false) {
    $rootPath = [IO.Path]::GetFullPath($Root)
    $separator = [IO.Path]::DirectorySeparatorChar
    $prefix = $rootPath.TrimEnd([char[]]@($separator,[IO.Path]::AltDirectorySeparatorChar)) + $separator
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw ('Путь вне разрешённого каталога: ' + $full)
    }
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw ('Недопустимый корень дополнительных файлов: ' + $rootPath)
    }
    $parts = $full.Substring($prefix.Length).Split($separator)
    $current = $rootPath
    foreach ($part in $parts) {
        if (-not (Test-ExtraPathComponent $part)) { throw ('Имя в пути дополнительных файлов недопустимо: ' + $part) }
    }
    for ($i=0; $i -lt $parts.Length; $i++) {
        $current = [IO.Path]::Combine($current,$parts[$i])
        try { $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] {
            if ($AllowMissing) { return }
            throw
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw ('Ссылка в пути дополнительных файлов запрещена: ' + $current)
        }
        if ($i -lt $parts.Length-1 -and -not $item.PSIsContainer) {
            throw ('Компонент пути не является каталогом: ' + $current)
        }
    }
}

function Get-ExtraStreamSha256([IO.Stream]$Stream) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-','')
    } finally {
        $Stream.Position = 0
        $sha.Dispose()
    }
}

# Копируем с открытым источником, чтобы другой процесс не изменил его между
# чтением и проверкой. Ошибка копирования или SHA-256 не публикует файл.
function Copy-RequiredFile(
    [string]$From,
    [string]$To,
    [string]$AllowedSourceRoot = '',
    [string]$AllowedDestinationRoot = '',
    [string]$Backup = '',
    [string]$ExpectedHash = ''
) {
    if ($AllowedSourceRoot) { Assert-ProfileExtraPath $From $AllowedSourceRoot $true }
    if (-not [IO.File]::Exists($From)) { return $false }
    if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $To $AllowedDestinationRoot $true }
    $parent = Split-Path -Parent $To
    [void][IO.Directory]::CreateDirectory($parent)
    if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $To $AllowedDestinationRoot $true }
    $temporary = Join-Path $parent ('.WPM_' + [guid]::NewGuid().ToString('N') + '.tmp')
    $source = [IO.File]::Open($From,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $output = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $source.CopyTo($output)
            $output.Flush($true)
        } finally { $output.Dispose() }
        $sourceHash = Get-ExtraStreamSha256 $source
        if (($ExpectedHash -and $sourceHash -ne $ExpectedHash) -or
            $sourceHash -ne (Get-ExactFileSha256 $temporary)) {
            throw ('SHA-256 скопированного файла отличается: ' + $From)
        }
        if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $To $AllowedDestinationRoot $true }
        if ($Backup -and [IO.File]::Exists($To)) {
            if (-not (Copy-RequiredFile -From $To -To $Backup -AllowedSourceRoot $AllowedDestinationRoot -AllowedDestinationRoot $env:ProgramData)) {
                throw ('Не удалось резервировать целевой файл: ' + $To)
            }
            if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $To $AllowedDestinationRoot }
            if ((Get-ExactFileSha256 $Backup) -ne (Get-ExactFileSha256 $To)) {
                throw ('Целевой файл изменился после резервирования: ' + $To)
            }
            # Замена на том же томе сохраняет существующие права целевого файла.
            [IO.File]::Replace($temporary,$To,[NullString]::Value)
        } else { [IO.File]::Move($temporary,$To) }
        return $true
    } finally {
        $source.Dispose()
        if ([IO.File]::Exists($temporary)) {
            try {
                if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $temporary $AllowedDestinationRoot }
                [IO.File]::Delete($temporary)
            } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалён временный файл: ' + $temporary + '; ' + $_.Exception.Message) }
        }
    }
}

# Создаёт контрольный реестр Extras: путь, размер и SHA-256 каждого файла.
function New-ExtrasManifest([string]$Archive) {
    $extras=Join-Path $Archive 'Extras'
    $valid=Join-Path $Archive 'Validation'
    [void](New-Item -ItemType Directory -Path $valid -Force)
    $path=Join-Path $valid 'extras.jsonl'
    $writer=[IO.StreamWriter]::new($path,$false,[Text.UTF8Encoding]::new($false))
    [long]$count=0; [long]$skipped=0
    try {
        if (Test-Path -LiteralPath $extras -PathType Container) {
            Assert-ProfileExtraPath $extras $Archive
            foreach ($file in @(Get-ChildItem -LiteralPath $extras -Recurse -File -Force -ErrorAction Stop)) {
                $rel = $file.FullName.Substring($extras.Length).TrimStart([char[]]@('\','/')).Replace('/','\')
                try {
                    Assert-ProfileExtraPath $file.FullName $Archive
                    $sha=Get-ExactFileSha256 $file.FullName
                    $writer.WriteLine(([ordered]@{ RelativePath=$rel; Length=[long]$file.Length; SHA256=$sha } | ConvertTo-Json -Compress))
                    $count++
                } catch {
                    $skipped++
                    Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Extras: файл не прошёл хеширование ' + $rel + ': ' + $_.Exception.Message)
                }
            }
        }
    } finally { $writer.Dispose() }
    Write-OperationReport 'ПРОВЕРКА' ('Extras: записано контрольных файлов ' + $count + '; не удалось ' + $skipped)
    return [pscustomobject]@{Path='Validation/extras.jsonl'; Files=$count; Skipped=$skipped}
}
# Повреждённые файлы Extras исключаются из восстановления, но не останавливают USMT.
function Read-ExtraJson([string]$Path,[string]$Root,[string]$ExpectedHash = '') {
    Assert-ProfileExtraPath $Path $Root
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($ExpectedHash -and (Get-ExtraStreamSha256 $stream) -ne $ExpectedHash) {
            throw ('Файл дополнительных настроек изменился после проверки: ' + $Path)
        }
        $reader = [IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
        try { return ($reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop) }
        finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Test-ExtrasManifest([string]$Archive,[object]$Meta) {
    if ([int]$Meta.SchemaVersion -lt 5) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Старый архив: у Extras нет отдельного контроля SHA-256.'
        return $null
    }
    $info = $Meta.ExtrasManifest
    if (-not $info -or $info.Path -ne 'Validation/extras.jsonl') { throw 'Нет корректных метаданных Extras.' }
    $path = Join-Path $Archive 'Validation/extras.jsonl'
    Assert-ProfileExtraPath $path $Archive
    if (-not [IO.File]::Exists($path)) { throw 'Манифест Extras отсутствует.' }
    $approved = @{}
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $root = Join-Path $Archive 'Extras'
    foreach ($line in [IO.File]::ReadLines($path)) {
        if (-not $line.Trim()) { continue }
        $entry = $line | ConvertFrom-Json -ErrorAction Stop
        $rel = [string]$entry.RelativePath
        $parts = $rel -split '[/\\]'
        foreach ($part in $parts) {
            if (-not (Test-ExtraPathComponent $part)) { throw 'Недопустимый путь в манифесте Extras.' }
        }
        $key = $parts -join '\'
        if (-not $seen.Add($key)) { throw 'Повторяющийся путь в манифесте Extras.' }
        $hash = [string]$entry.SHA256
        if ($hash -notmatch '^[0-9a-fA-F]{64}$' -or [long]$entry.Length -lt 0) {
            throw 'Некорректный размер или SHA-256 в манифесте Extras.'
        }
        $full = Join-Path $root ($parts -join [IO.Path]::DirectorySeparatorChar)
        $ok = $false
        try {
            # Проверяем и корневой каталог Extras, и путь внутри него.
            Assert-ProfileExtraPath $full $Archive
            $file = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if (-not $file.PSIsContainer -and $file.Length -eq [long]$entry.Length -and
                (Get-ExactFileSha256 $full) -eq $hash) { $ok = $true }
        } catch { }
        if ($ok) { $approved[$key] = $hash }
        else { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Extras: файл отсутствует или повреждён, пропускается: ' + $rel) }
    }
    if ($seen.Count -ne [int]$info.Files) { throw 'Число записей Extras не совпадает с метаданными.' }
    if ([int]$info.Skipped -gt 0) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('При экспорте не удалось вычислить хеши Extras: ' + $info.Skipped)
    }
    Write-OperationReport 'ПРОВЕРКА' ('Extras: проверено ' + $seen.Count + '; совпало ' + $approved.Count)
    return $approved
}
function Is-AllowedExtra([hashtable]$Approved,[string]$Relative) {
    if ($null -eq $Approved) { return $true }
    return $Approved.ContainsKey($Relative.ToLowerInvariant().Replace('/','\'))
}

# Дополнительные пользовательские файлы, которые USMT может не восстановить:
# закрепления быстрого доступа Проводника и список информационных баз 1С.
# Исходные базы данных 1С (вне профиля) здесь не копируются.
function Export-ExplorerAndOneCExtras([object]$Profile,[string]$Archive) {
    $quickAccess = 'AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations\f01b4d95cf55d32a.automaticDestinations-ms'
    $quickSource = Join-Path $Profile.Path $quickAccess
    [int]$saved = 0
    if (Test-Path -LiteralPath $quickSource -PathType Leaf) {
        try {
            $quickDestination = Join-Path $Archive 'Extras\Explorer\QuickAccess.automaticDestinations-ms'
            if (Copy-RequiredFile $quickSource $quickDestination $Profile.Path $Archive) {
                $saved++
                Write-OperationReport 'ПРОВОДНИК' 'Закреплённые папки быстрого доступа: сохранён файл Explorer.'
            }
        } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Закрепления Проводника: ' + $_.Exception.Message) }
    } else { Write-OperationReport 'ПРОВОДНИК' 'Файл закреплений быстрого доступа отсутствует.' }
    $sourceDir = Join-Path $Profile.Path 'AppData\Roaming\1C\1CEStart'
    [int]$oneCSaved = 0
    if (Test-Path -LiteralPath $sourceDir -PathType Container) {
        Assert-ProfileExtraPath $sourceDir $Profile.Path
        foreach ($file in @(Get-ChildItem -LiteralPath $sourceDir -File -Force -ErrorAction Stop | Where-Object {
            $_.Name -match '(?i)^(ibases[^\\/]*\.v8i|1cestart\.cfg)$'
        })) {
            try {
                $dest = Join-Path (Join-Path $Archive 'Extras\OneC') $file.Name
                if (Copy-RequiredFile $file.FullName $dest $Profile.Path $Archive) {
                    $oneCSaved++; $saved++
                    Write-OperationReport '1С' ('Сохранён файл списка баз/настроек запуска: ' + $file.Name + '; размер ' + (Format-ByteSize ([UInt64]$file.Length)))
                }
            } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('1С: файл ' + $file.Name + ': ' + $_.Exception.Message) }
        }
    }
    Write-OperationReport '1С' ('Сохранено файлов списка информационных баз: ' + $oneCSaved)
    return $saved
}

# Восстанавливает только файлы, прошедшие SHA-256-манифест Extras.
# Старые целевые файлы резервируются до замены; ошибки модулей не отменяют USMT.
function Restore-ExplorerAndOneCExtras([string]$Archive,[string]$TargetPath,[hashtable]$ApprovedExtras) {
    $jobs = @()
    $sourceQuick = Join-Path $Archive 'Extras\Explorer\QuickAccess.automaticDestinations-ms'
    if (Test-Path -LiteralPath $sourceQuick -PathType Leaf) {
        $jobs += [pscustomobject]@{ Source=$sourceQuick; Key='Explorer\QuickAccess.automaticDestinations-ms';
            Destination=(Join-Path $TargetPath 'AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations\f01b4d95cf55d32a.automaticDestinations-ms'); Name='Быстрый доступ Проводника' }
    }
    $oneCFolder = Join-Path $Archive 'Extras\OneC'
    if (Test-Path -LiteralPath $oneCFolder -PathType Container) {
        Assert-ProfileExtraPath $oneCFolder $Archive
        foreach ($file in @(Get-ChildItem -LiteralPath $oneCFolder -File -Force -ErrorAction Stop | Where-Object {
            $_.Name -match '(?i)^(ibases[^\\/]*\.v8i|1cestart\.cfg)$'
        })) {
            $jobs += [pscustomobject]@{ Source=$file.FullName; Key=('OneC\' + $file.Name);
                Destination=(Join-Path $TargetPath ('AppData\Roaming\1C\1CEStart\' + $file.Name)); Name=('1С: ' + $file.Name) }
        }
    }
    if ($jobs.Count -eq 0) {
        Write-OperationReport 'НАСТРОЙКИ' 'Дополнительных файлов закреплений Проводника и 1С в архиве нет.'
        return
    }
    $backupRoot = Join-Path $env:ProgramData ('WindowsProfileMigration\ConfigBackups\' +
        (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    Update-TrackedState '' @{ConfigBackupPath=$backupRoot}
    [int]$done = 0
    foreach ($job in $jobs) {
        try {
            if (-not (Is-AllowedExtra $ApprovedExtras $job.Key)) {
                throw ('Файл не прошёл SHA-256: ' + $job.Key)
            }
            $dest = [string]$job.Destination
            $backup = Join-Path $backupRoot $job.Key
            $hash = if ($null -ne $ApprovedExtras) { [string]$ApprovedExtras[$job.Key] } else { '' }
            if (-not (Copy-RequiredFile -From $job.Source -To $dest -AllowedSourceRoot $Archive -AllowedDestinationRoot $TargetPath -Backup $backup -ExpectedHash $hash)) {
                throw ('Файл исчез до восстановления: ' + $job.Key)
            }
            $done++
            $backupNote = if ([IO.File]::Exists($backup)) { '; прежний файл сохранён в ' + $backup } else { '' }
            Write-OperationReport 'НАСТРОЙКИ' ('Восстановлено: ' + $job.Name + $backupNote)
        } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не перенесён ' + $job.Name + ': ' + $_.Exception.Message) }
    }
    Write-OperationReport 'НАСТРОЙКИ' ('Закрепления Проводника и 1С: восстановлено ' + $done + ' из ' + $jobs.Count + ' файлов.')
}

function Invoke-ProfileRegistryCommand([string[]]$Arguments) {
    $reg = Join-Path $env:SystemRoot 'System32/reg.exe'
    $commandLine = @($Arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join ' '
    $process = Start-Process -FilePath $reg -ArgumentList $commandLine -NoNewWindow -Wait -PassThru -ErrorAction Stop
    try {
        if ($null -eq $process.ExitCode) { throw 'reg.exe не вернул код завершения.' }
        return [int]$process.ExitCode
    } finally { $process.Dispose() }
}

# Выполняет действие с реестром именно выбранного пользователя. При отсутствии
# сеанса временно подключает NTUSER.DAT и гарантированно пытается выгрузить его.
function Invoke-ProfileHive([string]$Sid,[string]$ProfilePath,[scriptblock]$Action,[bool]$RequireOffline = $false) {
    if ($Sid -notmatch '^S-1-(?:[0-9]+-){1,14}[0-9]+$') { throw 'Некорректный SID пользовательского реестра.' }
    $hku = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users,[Microsoft.Win32.RegistryView]::Default)
    $mount = $Sid
    $mountedHere = $false
    try {
        $probe = $hku.OpenSubKey($mount,$false)
        if ($probe) {
            $probe.Dispose()
            if ($RequireOffline) { throw 'Целевой пользователь должен завершить сеанс перед изменением реестра.' }
        } else {
            $ntuser = Join-Path $ProfilePath 'NTUSER.DAT'
            Assert-ProfileExtraPath $ntuser $ProfilePath
            if (-not [IO.File]::Exists($ntuser)) { throw ('Отсутствует пользовательский реестр: ' + $ntuser) }
            $mount = 'WPM_' + [guid]::NewGuid().ToString('N')
            $code = Invoke-ProfileRegistryCommand @('load',('HKU\' + $mount),$ntuser)
            if ($code -ne 0) { throw ('reg load: код ' + $code + '; реестр: ' + $ProfilePath) }
            $mountedHere = $true
        }
        return (& $Action $hku $mount)
    } finally {
        $hku.Dispose()
        if ($mountedHere) {
            try {
                $code = Invoke-ProfileRegistryCommand @('unload',('HKU\' + $mount))
                if ($code -ne 0) { throw ('Код ' + $code) }
            } catch {
                Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('reg unload: временный реестр HKU\' + $mount + ' мог остаться подключённым; ' + $_.Exception.Message)
            }
        }
    }
}

function Test-NetworkDriveRemotePath([string]$Path) {
    if (-not $Path.StartsWith('\\') -or $Path.Length -gt 1024 -or $Path -match '[<>:"/|?*\x00-\x1f]') {
        return $false
    }
    $parts = $Path.Substring(2).TrimEnd('\').Split('\')
    if ($parts.Count -lt 2 -or $parts[0] -notmatch '^[\p{L}\p{N}_-]+(?:\.[\p{L}\p{N}_-]+)*$') {
        return $false
    }
    foreach ($part in $parts) {
        if (-not $part -or $part -match '[ .]$') { return $false }
    }
    return $true
}

# Сохраняет постоянные подключения сетевых дисков из HKCU\Network
# выбранного пользователя (пароли и учётные данные не извлекаются).
function Export-NetworkDrives([object]$Profile,[string]$Archive) {
    $drives = @(Invoke-ProfileHive $Profile.SID $Profile.Path {
        param($hku,$mount)
        $network = $hku.OpenSubKey(($mount + '\Network'),$false)
        if (-not $network) { return }
        try {
            foreach ($letter in @($network.GetSubKeyNames())) {
                if ($letter -notmatch '^[a-zA-Z]$') { continue }
                $key = $network.OpenSubKey($letter,$false)
                if (-not $key) { continue }
                try {
                    $remote = [string]$key.GetValue('RemotePath','')
                    if (-not (Test-NetworkDriveRemotePath $remote)) {
                        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Некорректный UNC-путь сетевого диска ' + $letter + ': пропущен.')
                        continue
                    }
                    [pscustomobject]@{ Letter=$letter.ToUpperInvariant(); RemotePath=$remote;
                        ProviderName=[string]$key.GetValue('ProviderName','Microsoft Windows Network');
                        ProviderType=[int]$key.GetValue('ProviderType',131072);
                        ConnectionType=[int]$key.GetValue('ConnectionType',1);
                        DeferFlags=[int]$key.GetValue('DeferFlags',4) }
                } finally { $key.Dispose() }
            }
        } finally { $network.Dispose() }
    } | Where-Object { $null -ne $_ })
    $destination = Join-Path $Archive 'Extras\NetworkDrives.json'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force -ErrorAction Stop)
    [pscustomobject]@{ SchemaVersion=1; Mappings=$drives } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $destination -Encoding UTF8 -ErrorAction Stop
    foreach ($drive in $drives) { Write-OperationReport 'СЕТЕВОЙ ДИСК' ('Сохранено: ' + $drive.Letter + ': -> ' + $drive.RemotePath) }
    Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' ('Постоянных подключений обнаружено: ' + $drives.Count)
    return $drives.Count
}

# Для вновь созданного профиля записывает постоянные диски в его HKCU.
# Существующие буквы не перезаписывает; подключение выполняется Windows при входе.
function Restore-NetworkDrives([string]$Archive,[string]$TargetSid,[string]$TargetPath,[hashtable]$ApprovedExtras) {
    $source = Join-Path $Archive 'Extras\NetworkDrives.json'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' 'Список постоянных подключений отсутствует в архиве.'
        return
    }
    if (-not (Is-AllowedExtra $ApprovedExtras 'NetworkDrives.json')) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Сетевые диски пропущены: файл не прошёл контроль SHA-256.'
        return
    }
    $hash = if ($null -ne $ApprovedExtras) { [string]$ApprovedExtras['NetworkDrives.json'] } else { '' }
    $data = Read-ExtraJson $source $Archive $hash
    if ([int]$data.SchemaVersion -ne 1) { throw 'Неизвестный формат списка сетевых дисков.' }
    $mappings = @($data.Mappings | Where-Object { $null -ne $_ })
    if ($mappings.Count -eq 0) {
        Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' 'В архиве нет постоянных подключений.'
        return
    }
    $localLetters = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType <> 4' -ErrorAction Stop |
        ForEach-Object { ([string]$_.DeviceID).TrimEnd(':') })
    $added = Invoke-ProfileHive $TargetSid $TargetPath {
        param($hku,$mount)
        [int]$count = 0
        foreach ($mapping in $mappings) {
            $letter = ''
            try {
                $letter = [string]$mapping.Letter
                $remote = [string]$mapping.RemotePath
                if ($letter -notmatch '^[A-Z]$' -or -not (Test-NetworkDriveRemotePath $remote)) {
                    throw 'Некорректная буква диска или UNC-путь.'
                }
                if ($letter -in $localLetters) { throw 'Буква занята локальным томом.' }
                $provider = [string]$mapping.ProviderName
                $providerType = [int]$mapping.ProviderType
                $connectionType = [int]$mapping.ConnectionType
                $deferFlags = [int]$mapping.DeferFlags
                if (-not $provider -or $provider.Length -gt 200 -or $provider -match '[\x00-\x1f]' -or
                    $providerType -lt 0 -or $connectionType -lt 0 -or $deferFlags -lt 0) {
                    throw 'Некорректные параметры сетевого провайдера.'
                }
                $path = $mount + '\Network\' + $letter
                $existing = $hku.OpenSubKey($path,$false)
                if ($existing) {
                    $existing.Dispose()
                    throw 'Буква уже назначена постоянному подключению.'
                }
                $key = $hku.CreateSubKey($path)
                if (-not $key) { throw ('Не удалось создать ключ Network\' + $letter) }
                try {
                    $key.SetValue('RemotePath',$remote,[Microsoft.Win32.RegistryValueKind]::String)
                    $key.SetValue('ProviderName',$provider,[Microsoft.Win32.RegistryValueKind]::String)
                    $key.SetValue('ProviderType',$providerType,[Microsoft.Win32.RegistryValueKind]::DWord)
                    $key.SetValue('ConnectionType',$connectionType,[Microsoft.Win32.RegistryValueKind]::DWord)
                    $key.SetValue('DeferFlags',$deferFlags,[Microsoft.Win32.RegistryValueKind]::DWord)
                    $key.Flush()
                } catch {
                    $key.Dispose()
                    $key = $null
                    try { $hku.DeleteSubKey($path,$false) }
                    catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалён неполный ключ сетевого диска ' + $letter + ': ' + $_.Exception.Message) }
                    throw
                } finally {
                    if ($key) { $key.Dispose() }
                }
                $count++
                Write-OperationReport 'СЕТЕВОЙ ДИСК' ('Восстановлено: ' + $letter + ': -> ' + $remote + '; подключение при входе пользователя')
            } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не восстановлен сетевой диск ' + $letter + ': ' + $_.Exception.Message) }
        }
        return $count
    } $true
    Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' ('Добавлено ' + $added + ' из ' + $mappings.Count + ' постоянных подключений.')
}

function Get-BrowserExtraFileNames {
    return @('Bookmarks','Bookmarks.bak','History','Visited Links','Favicons',
        'Top Sites','Preferences','Secure Preferences','Current Session','Last Session','Current Tabs','Last Tabs')
}

function Test-BrowserExtraRelativePath([string]$Relative) {
    $parts = $Relative -split '[/\\]'
    if ($parts.Count -lt 2 -or $parts[0] -notmatch '^(Default|Profile [0-9]+)$') { return $false }
    if ($parts.Count -eq 2) { return ($parts[1] -in @(Get-BrowserExtraFileNames)) }
    return ($parts.Count -eq 3 -and $parts[1] -eq 'Sessions' -and $parts[2] -match '^(Session|Tabs)_[0-9]+$')
}

# Сохраняет доступные закладки, историю и файлы сеансов; ошибка одного браузера не блокирует остальные.
function Export-BrowserExtras([object]$Profile,[string]$Archive) {
    # Independent best-effort capture. An open/locked browser must not stop other browsers.
    $extras = Join-Path $Archive 'Extras\Browsers'
    $busy = @(Get-OpenTargetBrowsers ([string]$Profile.SID))
    $total = 0
    $fileNames = @(Get-BrowserExtraFileNames)
    Title 'ДОПОЛНИТЕЛЬНОЕ СОХРАНЕНИЕ БРАУЗЕРОВ'
    $browserDefinitions = @(Browser-Definitions)
    [int]$browserIndex = 0
    foreach ($browser in $browserDefinitions) {
        $saved = 0
        $missed = 0
        $state = 'Не найден'
        $reason = ''
        try {
            $src = Join-Path (Join-Path $Profile.Path 'AppData\Local') $browser.Relative
            if (-not (Test-Path -LiteralPath $src -PathType Container)) {
                $reason = 'Каталог пользовательских данных отсутствует'
            } elseif ($busy -contains $browser.Process) {
                $state = 'Пропущен'
                $reason = 'Браузер запущен; не копируем активные базы и сеансы'
            } else {
                Assert-ProfileExtraPath $src $Profile.Path
                $destRoot = Join-Path $extras $browser.Id
                $folders = @(Get-ChildItem -LiteralPath $src -Directory -Force -ErrorAction Stop | Where-Object {
                    $_.Name -eq 'Default' -or $_.Name -match '^Profile [0-9]+$'
                })
                foreach ($folder in $folders) {
                    foreach ($filename in $fileNames) {
                        $from = Join-Path $folder.FullName $filename
                        $to = Join-Path (Join-Path $destRoot $folder.Name) $filename
                        try {
                            if (Copy-RequiredFile $from $to $Profile.Path $Archive) {
                                $saved++
                                Write-OperationReport 'БРАУЗЕР ФАЙЛ' ('Сохранён: ' + $browser.Name + '/' + $folder.Name + '/' + $filename)
                            }
                        } catch {
                            $missed++
                            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Пропущен: ' + $from + '; причина: ' + $_.Exception.Message)
                        }
                    }
                    $sessions = Join-Path $folder.FullName 'Sessions'
                    if (Test-Path -LiteralPath $sessions -PathType Container) {
                        try {
                            Assert-ProfileExtraPath $sessions $Profile.Path
                            $sessionFiles = @(Get-ChildItem -LiteralPath $sessions -File -Force -ErrorAction Stop |
                                Where-Object { $_.Name -match '^(Session|Tabs)_[0-9]+$' })
                            foreach ($file in $sessionFiles) {
                                $to = Join-Path (Join-Path (Join-Path $destRoot $folder.Name) 'Sessions') $file.Name
                                try {
                                    if (Copy-RequiredFile $file.FullName $to $Profile.Path $Archive) {
                                        $saved++
                                        Write-OperationReport 'БРАУЗЕР ФАЙЛ' ('Сохранён: ' + $browser.Name + '/' + $folder.Name + '/Sessions/' + $file.Name)
                                    }
                                } catch {
                                    $missed++
                                    Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Пропущен: ' + $file.FullName + '; причина: ' + $_.Exception.Message)
                                }
                            }
                        } catch {
                            $missed++
                            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Ошибка перечисления сеансов: ' + $sessions + '; ' + $_.Exception.Message)
                        }
                    }
                }
                if ($saved -gt 0) {
                    $state = if ($missed -gt 0) { 'Частично' } else { 'Сохранён' }
                } elseif ($missed -gt 0) {
                    $state = 'Не удалось'
                } else {
                    $state = 'Нет данных'
                    $reason = 'В профилях браузера не найдены поддерживаемые файлы'
                }
            }
        } catch {
            $missed++
            $state = if ($saved -gt 0) { 'Частично' } else { 'Не удалось' }
            $reason = $_.Exception.Message
        }
        $total += $saved
        Write-Host ('{0}: {1} (файлов: {2}; пропущено: {3})' -f $browser.Name,$state,$saved,$missed)
        $line = '{0}: {1}; скопировано: {2}; пропущено: {3}' -f $browser.Name,$state,$saved,$missed
        if ($reason) { $line += '; причина: ' + $reason }
        Write-OperationReport $(if ($missed -gt 0 -or $state -in @('Пропущен','Не удалось','Частично')) { 'ПРЕДУПРЕЖДЕНИЕ' } else { 'БРАУЗЕР' }) $line
        if ($reason) { Write-Host ('  ' + $reason) -ForegroundColor Yellow }
        $browserIndex++
        Write-Progress -Id 3 -Activity 'Перенос браузеров' -Status ($browser.Name + ': завершён') -PercentComplete ([int][Math]::Floor(100.0 * $browserIndex / $browserDefinitions.Count))
    }
    Write-Progress -Id 3 -Activity 'Перенос браузеров' -Completed
    if ($total -eq 0) { Write-Host 'Дополнительных файлов браузеров не скопировано; USMT-архив при этом сохранён.' -ForegroundColor Yellow }
    return $total
}
# Восстанавливает сохранённые файлы браузеров и резервирует заменяемые оригиналы.
function Restore-BrowserExtras([string]$Archive,[string]$TargetPath,[string]$TargetSid,[hashtable]$ApprovedExtras = $null,[bool]$AutoApprove = $false) {
    $extras = Join-Path $Archive 'Extras\Browsers'
    if (-not (Test-Path -LiteralPath $extras -PathType Container)) {
        Write-Host 'Дополнительных файлов браузеров нет: пропускаем.' -ForegroundColor Yellow
        Write-OperationReport 'БРАУЗЕР' 'Дополнительные данные браузеров в архиве отсутствуют.'
        return
    }
    Title 'ВОССТАНОВЛЕНИЕ БРАУЗЕРОВ'
    Write-Host 'Будут обработаны только данные, которые удалось сохранить при экспорте.'
    Write-Host 'Открытые браузеры автоматически пропускаются. Пароли и cookie отдельно не копируются.'
    if (-not $AutoApprove -and -not (Confirm 'Восстановить доступные файлы браузеров?')) { Write-OperationReport 'ОТМЕНА' 'Восстановление браузеров отклонено пользователем.'; return }
    $busy = @(Get-OpenTargetBrowsers $TargetSid)
    $recovery = Join-Path $env:ProgramData ('WindowsProfileMigration\BrowserRestoreBackup_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    Update-TrackedState '' @{BrowserBackupPath=$recovery}
    foreach ($browser in @(Browser-Definitions)) {
        $restored = 0
        $skipped = 0
        $previous = 0
        $state = 'Нет в архиве'
        $reason = ''
        try {
            $sourceRoot = Join-Path $extras $browser.Id
            if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
                $reason = 'Этот браузер не был сохранён'
            } elseif ($busy -contains $browser.Process) {
                $state = 'Пропущен'
                $reason = 'Браузер запущен на целевом устройстве'
            } else {
                Assert-ProfileExtraPath $sourceRoot $Archive
                $destRoot = Join-Path (Join-Path $TargetPath 'AppData\Local') $browser.Relative
                $folders = @(Get-ChildItem -LiteralPath $sourceRoot -Directory -Force -ErrorAction Stop |
                    Where-Object { $_.Name -match '^(Default|Profile [0-9]+)$' })
                foreach ($folder in $folders) {
                    try {
                        Assert-ProfileExtraPath $folder.FullName $Archive
                        $files = @(Get-ChildItem -LiteralPath $folder.FullName -File -Force -ErrorAction Stop)
                    } catch {
                        $skipped++
                        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось прочитать профиль ' + $browser.Name + '/' + $folder.Name + ': ' + $_.Exception.Message)
                        continue
                    }
                    $sessions = Join-Path $folder.FullName 'Sessions'
                    if (Test-Path -LiteralPath $sessions -PathType Container) {
                        try {
                            Assert-ProfileExtraPath $sessions $Archive
                            $files += @(Get-ChildItem -LiteralPath $sessions -File -Force -ErrorAction Stop)
                        } catch {
                            $skipped++
                            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось прочитать сеансы ' + $browser.Name + '/' + $folder.Name + ': ' + $_.Exception.Message)
                        }
                    }
                    foreach ($file in $files) {
                        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart([char[]]@('\','/'))
                        if (-not (Test-BrowserExtraRelativePath $relative)) {
                            $skipped++
                            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Браузер: неподдерживаемый файл пропущен: ' + $browser.Name + '/' + $relative)
                            continue
                        }
                        $manifestKey = 'Browsers\' + $browser.Id + '\' + $relative.Replace('/','\')
                        if (-not (Is-AllowedExtra $ApprovedExtras $manifestKey)) {
                            $skipped++
                            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Браузер: пропущен повреждённый файл: ' + $manifestKey)
                            continue
                        }
                        $dest = Join-Path $destRoot $relative
                        $backup = Join-Path (Join-Path $recovery $browser.Id) $relative
                        $hash = if ($null -ne $ApprovedExtras) { [string]$ApprovedExtras[$manifestKey] } else { '' }
                        try {
                            if (-not (Copy-RequiredFile -From $file.FullName -To $dest -AllowedSourceRoot $Archive -AllowedDestinationRoot $TargetPath -Backup $backup -ExpectedHash $hash)) {
                                throw 'Файл исчез до восстановления.'
                            }
                            $restored++
                            Write-OperationReport 'БРАУЗЕР ФАЙЛ' ('Восстановлен: ' + $browser.Name + '/' + $relative)
                        } catch {
                            $skipped++
                            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Ошибка восстановления: ' + $browser.Name + '/' + $relative + ': ' + $_.Exception.Message)
                        } finally {
                            if ([IO.File]::Exists($backup)) { $previous++ }
                        }
                    }
                }
                if ($restored -gt 0) {
                    $state = if ($skipped -gt 0) { 'Частично' } else { 'Восстановлен' }
                } elseif ($skipped -gt 0) {
                    $state = 'Не удалось'
                } else {
                    $state = 'Нет данных'
                }
            }
        } catch {
            $skipped++
            $state = if ($restored -gt 0) { 'Частично' } else { 'Не удалось' }
            $reason = $_.Exception.Message
        }
        Write-Host ('{0}: {1} (восстановлено: {2}; пропущено: {3})' -f $browser.Name,$state,$restored,$skipped)
        $line = '{0}: {1}; восстановлено: {2}; пропущено: {3}; резервировано прежних файлов: {4}' -f $browser.Name,$state,$restored,$skipped,$previous
        if ($reason) { $line += '; причина: ' + $reason }
        Write-OperationReport $(if ($skipped -gt 0 -or $state -in @('Пропущен','Не удалось','Частично')) { 'ПРЕДУПРЕЖДЕНИЕ' } else { 'БРАУЗЕР' }) $line
        if ($reason) { Write-Host ('  ' + $reason) -ForegroundColor Yellow }
    }
    Write-Host ('Резервные копии заменённых файлов (если были): ' + $recovery)
    Write-OperationReport 'РЕЗЕРВ' ('При замене браузерных файлов резервные копии сохраняются в: ' + $recovery)
    Write-Host 'Статус USMT не зависит от результатов дополнительного переноса браузеров.' -ForegroundColor Yellow
}
# Меняем только известные значения Explorer, сохраняя их исходные типы.
function Get-DesktopRegistryValueNames {
    return @('IconLayouts','IconSize','Mode','LogicalViewMode')
}

function Get-DesktopRegistryValues([object]$Hive,[string]$Path) {
    $key = $Hive.OpenSubKey($Path,$false)
    $values = @{}
    try {
        $names = if ($key) { @($key.GetValueNames()) } else { @() }
        foreach ($name in @(Get-DesktopRegistryValueNames)) {
            $values[$name] = $null
            if ($name -in $names) {
                $expectedKind = if ($name -eq 'IconLayouts') { 'Binary' } else { 'DWord' }
                if ([string]$key.GetValueKind($name) -ne $expectedKind) {
                    throw ('Неподдерживаемый тип значения рабочего стола: ' + $name)
                }
                $values[$name] = $key.GetValue($name)
            }
        }
    } finally {
        if ($key) { $key.Dispose() }
    }
    return $values
}

# Проверяем весь документ до открытия реестра на запись.
function Convert-DesktopRegistryValues([object]$Data,[bool]$IsBackup = $false) {
    if ([int]$Data.SchemaVersion -ne 1 -or $null -eq $Data.RegistryItems) {
        throw 'Неизвестный формат расположения значков.'
    }
    $values = @{}
    foreach ($name in @(Get-DesktopRegistryValueNames)) {
        $property = $Data.RegistryItems.PSObject.Properties[$name]
        if (-not $property) {
            if ($IsBackup) { throw ('В резервной копии отсутствует значение ' + $name) }
            continue
        }
        $item = $property.Value
        if ($IsBackup) {
            if ($item.Present -isnot [bool]) { throw ('Некорректное описание резервного значения ' + $name) }
            if (-not $item.Present) {
                $values[$name] = $null
                continue
            }
        }
        if ($name -eq 'IconLayouts' -and $item.Type -eq 'Binary' -and $item.Data -is [string]) {
            $values[$name] = [Convert]::FromBase64String($item.Data)
        } elseif ($name -ne 'IconLayouts' -and $item.Type -eq 'DWord' -and [string]$item.Data -match '^-?[0-9]{1,10}$') {
            $values[$name] = [int]$item.Data
        } else { throw ('Недопустимый тип или данные значения ' + $name) }
    }
    if (-not $IsBackup -and -not $values.ContainsKey('IconLayouts')) {
        throw 'В архиве нет значения IconLayouts.'
    }
    return $values
}

function Write-DesktopRegistryValues([object]$Key,[hashtable]$Values) {
    foreach ($name in $Values.Keys) {
        $value = $Values[$name]
        if ($null -eq $value) { $Key.DeleteValue($name,$false) }
        elseif ($name -eq 'IconLayouts') { $Key.SetValue($name,$value,[Microsoft.Win32.RegistryValueKind]::Binary) }
        else { $Key.SetValue($name,$value,[Microsoft.Win32.RegistryValueKind]::DWord) }
    }
    $Key.Flush()
}

function Set-DesktopRegistryValues([object]$Hive,[string]$Path,[hashtable]$Values,[hashtable]$Previous) {
    $key = $Hive.CreateSubKey($Path)
    if (-not $key) { throw 'Не удалось открыть ветку расположения рабочего стола.' }
    try { Write-DesktopRegistryValues $key $Values }
    catch {
        # Запись нескольких параметров не атомарна. Возвращаем снимок при сбое.
        try { Write-DesktopRegistryValues $key $Previous }
        catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Автоматический возврат расположения значков не удался: ' + $_.Exception.Message) }
        throw
    } finally { $key.Dispose() }
}

# Сохраняет последнее расположение, записанное Explorer.
function Export-DesktopLayout([object]$Profile,[string]$Archive) {
    $values = Invoke-ProfileHive $Profile.SID $Profile.Path {
        param($hku,$mount)
        Get-DesktopRegistryValues $hku ($mount + '\Software\Microsoft\Windows\Shell\Bags\1\Desktop')
    }
    if ($null -eq $values['IconLayouts']) { return $false }
    $items = @{}
    foreach ($name in $values.Keys) {
        if ($null -eq $values[$name]) { continue }
        $items[$name] = if ($name -eq 'IconLayouts') {
            @{Type='Binary'; Data=[Convert]::ToBase64String([byte[]]$values[$name])}
        } else { @{Type='DWord'; Data=[int]$values[$name]} }
    }
    $data = [ordered]@{SchemaVersion=1; SourceSid=[string]$Profile.SID; RegistryItems=$items}
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $data['PrimaryWidth'] = $screen.Width
        $data['PrimaryHeight'] = $screen.Height
        $data['DisplayCount'] = @([System.Windows.Forms.Screen]::AllScreens).Count
    } catch { }
    $layoutFile = Join-Path $Archive 'Extras/DesktopLayout.json'
    Assert-ProfileExtraPath $layoutFile $Archive $true
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $layoutFile))
    $data | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $layoutFile -Encoding UTF8 -ErrorAction Stop
    Write-Host 'Последнее сохранённое Windows расположение ярлыков записано.' -ForegroundColor Green
    return $true
}

# С подтверждением применяет сохранённые настройки значков.
function Restore-DesktopLayout(
    [string]$Archive,[string]$Sid,[string]$TargetPath,[bool]$AutoApprove = $false,[string]$ExpectedHash = ''
) {
    $layoutFile = Join-Path $Archive 'Extras/DesktopLayout.json'
    if (-not [IO.File]::Exists($layoutFile)) {
        Write-OperationReport 'НАСТРОЙКИ' 'Расположение значков отсутствует в архиве.'
        return
    }
    $data = Read-ExtraJson $layoutFile $Archive $ExpectedHash
    $values = Convert-DesktopRegistryValues $data
    Write-Host 'Найдены сохранённые позиции значков рабочего стола.' -ForegroundColor Cyan
    Write-Host 'Расположение зависит от версии Windows, масштаба, разрешения и количества мониторов.' -ForegroundColor Yellow
    if (@('PrimaryWidth','PrimaryHeight','DisplayCount' | Where-Object { $data.PSObject.Properties[$_] }).Count -eq 3) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            if ($screen.Width -ne $data.PrimaryWidth -or $screen.Height -ne $data.PrimaryHeight -or
                @([System.Windows.Forms.Screen]::AllScreens).Count -ne $data.DisplayCount) {
                Write-Host 'Конфигурация мониторов отличается. Проверьте расположение после входа.' -ForegroundColor Yellow
            }
        } catch { }
    }
    if (-not $AutoApprove -and -not (Confirm 'Попробовать применить сохранённое расположение значков?')) {
        Write-OperationReport 'ОТМЕНА' 'Позиции значков не применялись по выбору пользователя.'
        return
    }
    Invoke-ProfileHive $Sid $TargetPath {
        param($hku,$mount)
        $keyPath = $mount + '\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
        $previous = Get-DesktopRegistryValues $hku $keyPath
        $snapshot = [ordered]@{SchemaVersion=1; TargetSid=$Sid; TargetProfile=$TargetPath;
            RegistryItems=@{}; SavedAt=(Get-Date).ToString('o')}
        foreach ($name in $previous.Keys) {
            $snapshot.RegistryItems[$name] = if ($null -eq $previous[$name]) {
                @{Present=$false; Type=''; Data=$null}
            } elseif ($name -eq 'IconLayouts') {
                @{Present=$true; Type='Binary'; Data=[Convert]::ToBase64String([byte[]]$previous[$name])}
            } else { @{Present=$true; Type='DWord'; Data=[int]$previous[$name]} }
        }
        $backupFolder = Join-Path $env:ProgramData 'WindowsProfileMigration\DesktopBackups'
        $backupPath = Join-Path $backupFolder ('Desktop_' + [guid]::NewGuid().ToString('N') + '.json')
        Assert-ProfileExtraPath $backupPath $env:ProgramData $true
        [void][IO.Directory]::CreateDirectory($backupFolder)
        Assert-ProfileExtraPath $backupPath $env:ProgramData $true
        $bytes = [Text.Encoding]::UTF8.GetBytes(($snapshot | ConvertTo-Json -Depth 5))
        $out = [IO.File]::Open($backupPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $out.Write($bytes,0,$bytes.Length)
            $out.Flush($true)
        } finally { $out.Dispose() }
        Update-TrackedState '' @{DesktopBackup=$backupPath}
        Write-OperationReport 'РЕЗЕРВ' ('Прежние значения рабочего стола сохранены: ' + $backupPath)
        Set-DesktopRegistryValues $hku $keyPath $values $previous
    } $true
    Write-Host 'Расположение записано. Windows попробует применить его при входе пользователя.' -ForegroundColor Green
    Write-OperationReport 'НАСТРОЙКИ' 'Позиции значков записаны в реестр. Проверьте их при входе под целевым пользователем.'
}

# Восстанавливает только локальную резервную копию для зарегистрированного SID и пути.
function Restore-PreviousDesktopLayout([string]$BackupFile) {
    $backupRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'WindowsProfileMigration\DesktopBackups'))
    $backupPath = [IO.Path]::GetFullPath($BackupFile)
    if ([IO.Path]::GetDirectoryName($backupPath) -ine $backupRoot -or
        [IO.Path]::GetFileName($backupPath) -notmatch '^Desktop_[a-f0-9]{32}\.json$') {
        throw 'Путь вне каталога резервных копий расположения значков.'
    }
    $data = Read-ExtraJson $backupPath $env:ProgramData
    $values = Convert-DesktopRegistryValues $data $true
    $sid = [string]$data.TargetSid
    if ($sid -notmatch '^S-1-(?:[0-9]+-){1,14}[0-9]+$' -or -not $data.TargetProfile) {
        throw 'Некорректный пользователь в резервной копии.'
    }
    $registered = @(Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID='" + $sid + "'") -ErrorAction Stop)
    $targetPath = [IO.Path]::GetFullPath([string]$data.TargetProfile)
    if ($registered.Count -ne 1 -or $registered[0].Special -or
        [IO.Path]::GetFullPath([string]$registered[0].LocalPath) -ine $targetPath) {
        throw 'SID или путь зарегистрированного профиля больше не совпадает с резервной копией.'
    }
    if (-not (Confirm ('Восстановить прежние позиции значков пользователя ' + $sid + ' ?'))) { return }
    Invoke-ProfileHive $sid $targetPath {
        param($hku,$mount)
        $keyPath = $mount + '\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
        $current = Get-DesktopRegistryValues $hku $keyPath
        Set-DesktopRegistryValues $hku $keyPath $values $current
    } $true
    Write-Host 'Настройки возвращены. Проверьте их после нового входа пользователя.' -ForegroundColor Green
}

# Находит зарегистрированный в Windows целевой профиль по учётной записи.
function Get-TargetUserProfile([string]$Account) {
    $sid = ([Security.Principal.NTAccount]::new($Account)).Translate([Security.Principal.SecurityIdentifier]).Value
    $profile = @(Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID='" + $sid + "'") -ErrorAction Stop)
    if ($profile.Count -ne 1 -or $profile[0].Special -or (([int]$profile[0].Status) -band 9) -or
        -not (Test-Path -LiteralPath $profile[0].LocalPath -PathType Container)) {
        throw ('Профиль назначения после USMT не обнаружен для ' + $Account + '. Дополнительные данные сохранены в архиве, но не восстановлены.')
    }
    return [pscustomobject]@{Sid=$sid; Path=[string]$profile[0].LocalPath}
}

# Встроенный оригинал ProfileOnly.xml. Правила будут созданы автоматически,
# даже если при копировании комплекта потерялась отдельная папка Rules.
# Контрольный SHA-256 оставлен совместимым с архивами v1.9.6.
function Write-EmbeddedProfileOnlyRule([string]$Destination) {
    $xmlText = @'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Автор: Arhivater. Миграция только пользовательского контекста. -->
<migration urlid="http://www.microsoft.com/migration/1.0/migxmlext/ArhivaterProfileOnly">
  <component type="Documents" context="User">
    <displayName>Arhivater - Profile files only</displayName>
    <role role="Data">
      <rules context="User">
        <include>
          <objectSet>
            <!-- Файлы в корне профиля и во всех вложенных папках. -->
            <pattern type="File">%CSIDL_PROFILE% [*]</pattern>
            <pattern type="File">%CSIDL_PROFILE%\* [*]</pattern>
          </objectSet>
        </include>
        <exclude>
          <objectSet>
            <!-- Реестровые ульи не копируются как файлы: HKCU переносится отдельно. -->
            <pattern type="File">%CSIDL_PROFILE% [NTUSER.DAT*]</pattern>
            <pattern type="File">%CSIDL_PROFILE% [NTUSER.INI]</pattern>
            <pattern type="File">%CSIDL_PROFILE%\AppData\Local\Microsoft\Windows [UsrClass.dat*]</pattern>
          </objectSet>
        </exclude>
      </rules>
    </role>
  </component>
  <component type="Application" context="User">
    <displayName>Arhivater - User registry settings only</displayName>
    <role role="Settings">
      <rules context="User">
        <include>
          <objectSet>
            <!-- Только HKCU выбранной через /ui учётной записи. -->
            <pattern type="Registry">HKCU [*]</pattern>
            <pattern type="Registry">HKCU\* [*]</pattern>
          </objectSet>
        </include>
      </rules>
    </role>
  </component>
</migration>
'@
    # Приводим окончания строк к LF и сохраняем UTF-8 без BOM.
    # Это обеспечивает одинаковый файл и его SHA-256 на разных компьютерах.
    $normalized = ($xmlText -replace "`r`n", "`n").TrimEnd([char[]]@([char]13,[char]10)) + "`n"
    [IO.File]::WriteAllText($Destination, $normalized, [System.Text.UTF8Encoding]::new($false))
    if ((Get-ExactFileSha256 $Destination) -ne '5bf12aa9ff9d874faec31829cc7f0b8277af82311810321ec97c89aa6803705c') {
        throw 'Контрольная сумма встроенных правил ProfileOnly.xml не совпала. Экспорт остановлен.'
    }
}

# XML читается с отключённым DTD и внешними ресурсами.
function Read-MigrationXml([string]$Path) {
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 32MB
    $reader = [Xml.XmlReader]::Create($Path,$settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        return ,$document
    } finally { $reader.Dispose() }
}

# Готовит только пользовательские правила USMT. Стандартные MigDocs/MigUser
# ищут файлы по всему компьютеру, поэтому для профильного архива не используются.
# Генерируемый Config.xml отключает стандартные настройки уровня компьютера.
function New-ProfileOnlyRules([string]$Archive,[string]$Usmt,[string]$Logs) {
    $folder = Join-Path $Archive 'Rules'
    [void](New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop)
    $rule = Join-Path $folder 'ProfileOnly.xml'
    $configPath = Join-Path $folder 'Config.xml'
    Write-EmbeddedProfileOnlyRule $rule
    # Проверка XML до передачи его ScanState.
    $xml = Read-MigrationXml $rule
    $parts = @($xml.SelectNodes('/migration/component'))
    if ($parts.Count -ne 2 -or @($parts | Where-Object { $_.GetAttribute('context') -ne 'User' }).Count -gt 0) {
        throw 'Правило ProfileOnly.xml имеет неожиданную область миграции.'
    }
    Write-Host 'Подготовка ограниченных правил USMT...' -ForegroundColor Cyan
    $genconfigLog = Join-Path $Logs 'genconfig.log'
    Write-OperationReport 'ЖУРНАЛ USMT' ('Подготовка Config.xml: ' + $genconfigLog)
    Invoke-USMT (Join-Path $Usmt 'ScanState.exe') @(
        ('/i:'+$rule),('/genconfig:'+$configPath),'/v:5',('/l:'+$genconfigLog)
    ) $Usmt
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw 'USMT не создал Config.xml для ограничения настроек компьютера.'
    }
    $config = Read-MigrationXml $configPath
    if (-not $config.SelectSingleNode('/Configuration')) {
        throw 'Config.xml USMT имеет неожиданный формат.'
    }
    $machineComponents = @($config.SelectNodes('/Configuration/WindowsComponents//component'))
    foreach ($node in $machineComponents) { [void]$node.SetAttribute('migrate','no') }
    $config.Save($configPath)
    Write-OperationReport 'ПРОВЕРКА' ('Настройки Windows уровня компьютера отключены: ' + $machineComponents.Count + ' разделов.')
    return [pscustomobject]@{ Rule=$rule; Config=$configPath;
        RuleSHA256=(Get-ExactFileSha256 $rule); ConfigSHA256=(Get-ExactFileSha256 $configPath) }
}

# Читает реальный /listfiles от ScanState и завершает экспорт с ошибкой,
# если хотя бы один объект вне выбранного профиля или путь не распознан.
# USMT может записать сам корень профиля как отдельный объект списка.
# Не допускаем переходы через junction/symlink внутри профиля.
function Inspect-UsmtFileScope([string]$FileList,[string]$ProfilePath,[bool]$VerifySourceLinks = $true) {
    if (-not (Test-Path -LiteralPath $FileList -PathType Leaf)) { throw 'USMT не создал /listfiles. Область экспорта не подтверждена.' }
    $root = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
    $prefix = $root + '\'
    $cmp = [StringComparison]::OrdinalIgnoreCase
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$files = 0
    [long]$invalid = 0
    $examples = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [IO.File]::ReadLines($FileList)) {
        $candidate = ([string]$line).Trim().Trim('"')
        if (-not $candidate) { continue }
        $files++
        $reason = ''
        try {
            if ($candidate -notmatch '^[a-zA-Z]:\\') { throw 'не абсолютный локальный путь' }
            $relative = $candidate.Substring(3)
            if ($relative.EndsWith('\')) { $relative = $relative.Substring(0,$relative.Length - 1) }
            if ($relative) { [void](Get-WindowsRelativePathParts $relative) }
            $full = [IO.Path]::GetFullPath($candidate)
            # Принимаем сам корень и строго вложенные объекты. Соседние
            # профили, например a.agdamov2, остаются за пределами области.
            if (-not ($full.Equals($root,$cmp) -or $full.StartsWith($prefix,$cmp))) {
                throw 'вне выбранного профиля'
            }
            if ($VerifySourceLinks) {
                $current = $full
                while ($current.StartsWith($prefix,$cmp) -or $current.Equals($root,$cmp)) {
                    if (-not $seen.Add($current)) { break }
                    $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'переход через ссылку' }
                    if ($current.Equals($root,$cmp)) { break }
                    $current = [IO.Path]::GetDirectoryName($current)
                }
            }
        } catch { $reason = $_.Exception.Message }
        if ($reason) {
            $invalid++
            if ($examples.Count -lt 12) { $examples.Add($candidate + ' (' + $reason + ')') }
        }
    }
    if ($files -eq 0) { throw 'USMT не перечислил ни одного объекта. Экспорт не может быть подтверждён.' }
    if ($invalid -gt 0) {
        foreach ($example in @($examples.ToArray())) { Write-OperationReport 'ОШИБКА ОБЛАСТИ' $example }
        throw ('ScanState выбрал ' + $invalid + ' объектов вне подтверждённой области из ' + $files + '. Архив НЕ будет опубликован.')
    }
    Write-OperationReport 'ПРОВЕРКА' ('USMT /listfiles: ' + $files + ' объектов, все внутри ' + $root + ' или равны корню профиля')
    return $files
}

# При импорте нужен архив с тем же XML и проверенным списком файлов.
function Assert-ProfileOnlyArchive([string]$Archive,[object]$Meta) {
    if ([int]$Meta.SchemaVersion -lt 7 -or -not $Meta.ProfileScope -or
        [string]$Meta.ProfileScope.Policy -ne 'ArhivaterProfileOnlyV1') {
        throw 'Старый архив не подтверждает ограничение одним профилем. Создайте новый архив в v1.9.11 или новее.'
    }
    $proof = $Meta.ProfileScope
    if ([string]$proof.ProfilePath -ne [string]$Meta.SourceProfilePath -or [long]$proof.Files -lt 1) {
        throw 'Сведения об области пользовательского профиля повреждены.'
    }
    $rule = Join-Path $Archive 'Rules\ProfileOnly.xml'
    $config = Join-Path $Archive 'Rules\Config.xml'
    $files = Join-Path $Archive 'Validation\usmt-files.txt'
    $required = @(
        [pscustomobject]@{Path=$rule; Hash=[string]$proof.RuleSHA256}
        [pscustomobject]@{Path=$config; Hash=[string]$proof.ConfigSHA256}
        [pscustomobject]@{Path=$files; Hash=[string]$proof.ListSHA256}
    )
    foreach ($item in $required) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf) -or
            -not $item.Hash -or (Get-ExactFileSha256 ([string]$item.Path)) -ne $item.Hash) {
            throw ('Файл подтверждения области изменён или отсутствует: ' + [IO.Path]::GetFileName([string]$item.Path))
        }
    }
    # Надёжный шаблон встроен в этот файл, внешняя папка Rules не нужна.
    if ([string]$proof.RuleSHA256 -ne '5bf12aa9ff9d874faec31829cc7f0b8277af82311810321ec97c89aa6803705c') {
        throw 'Правила в архиве отличаются от подтверждённого шаблона комплекта.'
    }
    $configDoc = Read-MigrationXml $config
    if (-not $configDoc.SelectSingleNode('/Configuration')) { throw 'Config.xml не прошёл структурную проверку.' }
    foreach ($node in @($configDoc.SelectNodes('/Configuration/WindowsComponents//component'))) {
        if ($node.GetAttribute('migrate') -ne 'no') {
            throw 'В архиве обнаружены включённые системные компоненты Windows.'
        }
    }
    $actual = Inspect-UsmtFileScope $files ([string]$proof.ProfilePath) $false
    if ($actual -ne [long]$proof.Files) { throw 'Количество файлов в проверенном списке не совпадает.' }
}

# Повторно проверяет нет ли нового входа в систему, подмены каталога
# или удаления профиля за время подготовки и сверки файлов.
function Assert-ExportProfileReady([object]$Profile,[string]$Phase) {
    $actual = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object { $_.SID -eq $Profile.SID })
    if ($actual.Count -ne 1 -or [string]$actual[0].LocalPath -ine [string]$Profile.Path -or
        $null -eq $actual[0].Loaded -or $actual[0].Loaded) {
        throw ('Состояние выбранного профиля изменилось: ' + $Phase + '. ZIP не опубликован.')
    }
}

# Главный сценарий: профиль → оценка объёма → ScanState → проверка .mig → дополнения → публикация.
function Do-Export([string]$Usmt,[object]$SelectedProfile = $null,[string]$ForcedRoot = '',[bool]$KeepReportOpen = $false,[bool]$AutoApprove = $false) {
    $p = if ($SelectedProfile) { $SelectedProfile } else { Select-Profile }
    if (-not $p) { Write-OperationReport 'ОТМЕНА' 'Выбор профиля отменён.'; return }
    Advance-OperationStage 'Выбран исходный профиль'
    Write-OperationReport 'ИСТОЧНИК' ('Учётная запись: ' + $p.Account + '; тип: ' + $p.Type + '; каталог: ' + $p.Path)
    # Полностью проверяемый перенос требует выгруженного пользовательского реестра.
    # Нельзя хешировать файл после ScanState и выдавать этот хеш за содержимое .mig.
    if ($p.Loaded) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Профиль ' + $p.Account + ' загружен. Экспорт не начат из-за риска рассогласования исходных файлов и .mig.')
        Write-Host ('Профиль ' + $p.Account + ' сейчас загружен в Windows.') -ForegroundColor Yellow
        Write-Host 'Для проверенного экспорта пользователь должен выйти из Windows (не блокировать экран).' -ForegroundColor Yellow
        Write-Host 'Войдите под ДРУГИМ администратором, запустите Start.cmd и выберите профиль из списка цифрой.'
        Write-Host 'Это необходимо, чтобы контрольные суммы относились к тем же данным, что захватывает USMT.'
        return
    }
    Assert-ExportProfileReady $p 'перед оценкой файлов'
    Assert-NoReparseAncestor $p.Path
    Write-Host 'Оценка размера профиля...' -ForegroundColor Cyan
    $profileMetrics = Get-FolderMetrics $p.Path
    $estimatedBytes = [UInt64]$profileMetrics.Bytes
    $baseline = Get-ProfileValidationBaseline $p.Path
    Advance-OperationStage 'Подсчитан размер исходного профиля'
    Write-Host ('Оценочный размер профиля: ' + (Format-ByteSize $estimatedBytes) + '; файлов: ' + $profileMetrics.Files) -ForegroundColor Green
    Write-OperationReport 'ПРОВЕРКА' ('Оценочный размер профиля: ' + (Format-ByteSize $estimatedBytes) + '; файлов: ' + $profileMetrics.Files)
    if ($profileMetrics.SkippedLinks -gt 0) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не учитывались точки соединения и символические ссылки: ' + $profileMetrics.SkippedLinks)
    }
    Write-OperationReport 'ПРОВЕРКА' 'Объём профиля - оценка, а не точный размер USMT: служебные данные архива и дополнительные файлы модулей учитываются при экспорте.'
    $root = if ($ForcedRoot) { $ForcedRoot } else { Select-SaveLocation }
    if (-not $root) { Write-OperationReport 'ОТМЕНА' 'Выбор каталога сохранения отменён.'; return }
    Write-OperationReport 'ПУТЬ' ('Папка резервных копий: ' + $root)
    Test-StoreLocation $root $p.Path $estimatedBytes
    Advance-OperationStage 'Проверена папка назначения'
    $safe = $p.Account -replace '[^a-zA-Z0-9а-яА-ЯёЁ_-]', '_'
    $folderName = '{0}_{1}_{2}_{3}' -f $env:COMPUTERNAME,$safe,(Get-Date -Format 'yyyyMMdd_HHmmss_fff'),([guid]::NewGuid().ToString('N').Substring(0,8))
    $finalArchive = Join-Path $root ($folderName + '.zip')
    Start-TrackedState 'Экспорт' $finalArchive
    $networkPublish = Test-IsUncPath $root
    if ($networkPublish) { Ensure-PathAvailable $root 'Сетевая папка архива' }
    # USMT создаёт рабочий каталог; готовым результатом всегда является один ZIP.
    # Хранение каталога и ZIP одновременно требует локального свободного места.
    $stagingRoot = Join-Path $env:ProgramData 'WindowsProfileMigration\Staging'
    $stagingDrive = [IO.Path]::GetPathRoot($stagingRoot)
    $stagingFree = Get-PathFreeBytes $stagingDrive
    $stagingNeeded = [UInt64]([double]$estimatedBytes * 2.2 + [double]1GB)
    if ($stagingFree -lt $stagingNeeded) {
        throw ('Недостаточно места для создания ZIP на ' + $stagingDrive +
            '. Нужно примерно ' + (Format-ByteSize $stagingNeeded) +
            ', доступно ' + (Format-ByteSize $stagingFree) + '.')
    }
    $staging = New-StagingDirectory ('Export_' + $folderName)
    $archive = Join-Path $staging 'Payload'
    Update-TrackedState 'Подготовка экспорта' @{StagingPath=$staging; StagingPurpose='Создание ZIP'}
    [void](New-Item -ItemType Directory -Path $archive -ErrorAction Stop)
    Write-Host ('Готовый ZIP будет сохранён: ' + $finalArchive) -ForegroundColor Cyan
    Write-OperationReport 'АРХИВ' ('Временный рабочий каталог: ' + $archive)
    Write-OperationReport 'ПУТЬ' ('Готовый ZIP: ' + $finalArchive)
    Write-Host ''
    Write-Host ('Исходный пользователь: ' + $p.Account) -ForegroundColor Cyan
    Write-Host ('Администратор запуска: ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    Write-Host ('Разрешённая область файлов: ' + $p.Path) -ForegroundColor Yellow
    Write-Host ('Архив будет сохранён: ' + $finalArchive)
    Write-Host 'Перед публикацией список USMT будет проверен на выход за пределы профиля.'
    Write-Host 'Без шифрования USMT: используйте защищённый/BitLocker-накопитель.' -ForegroundColor Yellow
    Write-Host 'Установленные программы и сохранённые пароли USMT не переносит.'
    if (-not $AutoApprove -and -not (Confirm 'Начать экспорт?')) {
        Write-OperationReport 'ОТМЕНА' 'Подтверждение экспорта отклонено.'
        Update-TrackedState 'Отменено до экспорта'
        [void](Clear-TrackedStaging $Script:ActiveOpState $false)
        return
    }
    Advance-OperationStage 'Экспорт подтверждён'
    Write-OperationReport 'АРХИВ' ('Создаётся: ' + $archive)
    $store = Join-Path $archive 'Store'
    $logs = Join-Path $env:ProgramData ('WindowsProfileMigration\Logs\Export_' + $folderName)
    [void](New-Item -Path $store -ItemType Directory -Force)
    [void](New-Item -Path $logs -ItemType Directory -Force)
    $rules = New-ProfileOnlyRules $archive $Usmt $logs
    Advance-OperationStage 'Подготовлены правила USMT'
    # Перед ScanState сохраняем SHA-256, не после. Затем сверим источник повторно.
    Assert-ExportProfileReady $p 'перед созданием контрольного реестра'
    Write-Host 'Формирование контрольного списка ДО ScanState...' -ForegroundColor Cyan
    $manifest = New-ValidationManifest $p.Path $archive
    Advance-OperationStage 'Создан контрольный реестр до ScanState'
    Assert-ExportProfileReady $p 'перед ScanState'
    $listPath = Join-Path $logs 'usmt-files.txt'
    $args = @($store, ('/i:'+$rules.Rule),('/config:'+$rules.Config),('/listfiles:'+$listPath),'/localonly','/efs:abort',
        '/ue:*\*',('/ui:' + $p.Account), '/v:5',('/l:'+(Join-Path $logs 'scanstate.log')),
        ('/progress:'+(Join-Path $logs 'scan-progress.log')))
    Write-Host 'Экспорт USMT...' -ForegroundColor Cyan
    Write-OperationReport 'ЖУРНАЛ USMT' ('Экспорт: ' + (Join-Path $logs 'scanstate.log'))
    Update-TrackedState 'ScanState выполняется' @{USMTStarted=$true}
    Invoke-USMT (Join-Path $Usmt 'ScanState.exe') $args $Usmt (Join-Path $logs 'scan-progress.log')
    Advance-OperationStage 'ScanState завершён'
    Update-TrackedState 'ScanState завершён' @{USMTFinished=$true}
    Write-OperationReport 'УСПЕХ' 'USMT ScanState: экспорт завершён, код 0.'
    # До публикации проверяем ФАКТИЧЕСКИЙ перечень файлов USMT, а не оценку.
    # В случае выхода за пределы профиля уничтожаем только принадлежащую
    # этому экспорту локальную временную копию.
    try {
        $scopeCount = Inspect-UsmtFileScope $listPath $p.Path
    } catch {
        [void](Clear-TrackedStaging $Script:ActiveOpState $false)
        throw
    }
    Advance-OperationStage 'Подтверждена область одного профиля'
    $scopeList = Join-Path $archive 'Validation\usmt-files.txt'
    Copy-Item -LiteralPath $listPath -Destination $scopeList -Force -ErrorAction Stop
    $scopeProof = [ordered]@{Policy='ArhivaterProfileOnlyV1'; ProfilePath=$p.Path; Files=$scopeCount;
        RuleSHA256=$rules.RuleSHA256; ConfigSHA256=$rules.ConfigSHA256;
        ListSHA256=(Get-ExactFileSha256 $scopeList)}
    Verify-Store $Usmt $store $logs
    Advance-OperationStage 'Целостность USMT проверена'
    Write-OperationReport 'УСПЕХ' ('USMT-архив проверен. Файл: ' + (MigFile $store))
    $browserCount = 0
    try { $browserCount = Export-BrowserExtras $p $archive }
    catch { Write-Host ('Дополнительный перенос браузеров пропущен: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Браузеры: ' + $_.Exception.Message) }
    Advance-OperationStage 'Завершена обработка браузеров'
    $layoutSaved = $false
    try { $layoutSaved = Export-DesktopLayout $p $archive }
    catch { Write-Host ('Расположение значков не сохранено: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Расположение значков: ' + $_.Exception.Message) }
    try { [void](Export-ExplorerAndOneCExtras $p $archive) }
    catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Дополнительные настройки Проводника/1С: ' + $_.Exception.Message) }
    try { [void](Export-NetworkDrives $p $archive) }
    catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Сетевые диски: ' + $_.Exception.Message) }
    Advance-OperationStage 'Сохранены дополнительные настройки Проводника, 1С и дисков'
    Write-OperationReport 'НАСТРОЙКИ' ('Расположение значков: ' + $(if ($layoutSaved) { 'сохранено (без гарантии восстановления на другом мониторе)' } else { 'не сохранено' }))
    Assert-ExportProfileReady $p 'перед повторной сверкой'
    Write-Host 'Повторная сверка SHA-256 источника ПОСЛЕ ScanState...' -ForegroundColor Cyan
    $consistency = Assert-ValidationSourceStable $p.Path $archive $manifest
    Assert-ExportProfileReady $p 'после повторной сверки'
    Advance-OperationStage 'Подтверждена неизменность исходных файлов'
    $extrasManifest=New-ExtrasManifest $archive
    $exportLogs = Join-Path $archive 'Logs'
    [void](New-Item -Path $exportLogs -ItemType Directory -Force)
    Copy-Item -Path (Join-Path $logs '*.log') -Destination $exportLogs -Force
    $archiveMetrics = Get-FolderMetrics $archive
    $os = Get-CimInstance Win32_OperatingSystem
    $meta = [ordered]@{ SchemaVersion=$Script:CurrentArchiveSchema; SourceMachine=$env:COMPUTERNAME; SourceAccount=$p.Account;
        SourceSid=$p.SID; AccountType=$p.Type; SourceProfilePath=$p.Path; SourceWindows=$os.Caption;
        SourceVersion=$os.Version; CreatedAt=(Get-Date).ToString('o'); StoreFolder='Store'; BrowserFiles=$browserCount;
        DesktopLayoutSaved=$layoutSaved; EstimatedProfileBytes=$estimatedBytes; EstimatedProfileFiles=$profileMetrics.Files;
        ArchiveBytes=[UInt64]$archiveMetrics.Bytes; ValidationBaseline=$baseline; ValidationManifest=$manifest; ValidationConsistency=$consistency; ExtrasManifest=$extrasManifest;
        ProfileScope=$scopeProof }
    $meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $archive 'metadata.json') -Encoding UTF8
    Advance-OperationStage 'Созданы метаданные и манифест Extras'
    Write-OperationReport 'УСПЕХ' ('Метаданные архива записаны. Браузерных файлов сохранено: ' + $browserCount)
    Write-OperationReport 'ЖУРНАЛ USMT' ('Технические файлы: ' + $exportLogs)
    # ZIP создаётся рядом с рабочим каталогом, затем передаётся в целевую
    # папку под временным именем. Только после проверки SHA-256 переименовываем.
    $partialName = ($folderName + '.zip.partial_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $localZip = Join-Path $staging $partialName
    $publishedPartial = Join-Path $root $partialName
    try {
        Write-Host 'Упаковка экспортированного профиля в один ZIP...' -ForegroundColor Cyan
        Update-TrackedState 'Упаковка ZIP'
        Compress-ProfileArchive $archive $localZip
        Advance-OperationStage 'ZIP упакован и проверен'
        Update-TrackedState 'Публикация ZIP' @{NetworkPartialPath=$publishedPartial}
        Ensure-PathAvailable $root 'Папка назначения'
        if (Test-Path -LiteralPath $finalArchive) { throw 'Готовый ZIP с этим именем уже существует.' }
        Write-Host ('Копирование ZIP в папку: ' + $root) -ForegroundColor Cyan
        Copy-DirectoryRobust $staging $root 'копирование ZIP' $partialName
        $localHash = Assert-CopiedZipHash $localZip $publishedPartial
        Write-OperationReport 'ПРОВЕРКА' ('ZIP проверен после копирования, SHA-256: ' + $localHash)
        if (Test-Path -LiteralPath $finalArchive) { throw 'Готовый ZIP с этим именем уже существует.' }
        [IO.File]::Move($publishedPartial,$finalArchive)
        Advance-OperationStage 'ZIP опубликован в папке назначения'
        Update-TrackedState 'ZIP опубликован' @{NetworkPartialPath=''}
        Write-OperationReport 'УСПЕХ' ('ZIP проверен и опубликован: ' + $finalArchive)
        [void](Clear-TrackedStaging $Script:ActiveOpState $false)
        $archive = $finalArchive
    } catch [System.OperationCanceledException] {
        Update-TrackedState 'Публикация отменена - локальная копия сохранена' @{StagingDisposition='Рабочие данные сохранены для диагностики'}
        if ($Script:ActiveOpState.NetworkPartialPath) {
            try { Clear-NetworkPartial $Script:ActiveOpState $false }
            catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось очистить незавершённый ZIP: ' + $_.Exception.Message) }
        }
        Write-OperationReport 'ОТМЕНА' ('Создание ZIP остановлено. Временные данные сохранены: ' + $staging)
        throw
    } catch {
        Update-TrackedState 'Ошибка создания ZIP, временные данные сохранены' @{StagingDisposition='Оставлено для диагностики'}
        Write-OperationReport 'ОШИБКА' ('Не удалось создать или опубликовать ZIP. Временные данные сохранены: ' + $staging)
        throw
    }
    Update-TrackedState 'Экспорт завершён'
    Write-OperationReport 'УСПЕХ' ('Архив экспорта готов: ' + $archive)
    if (-not $KeepReportOpen) { Finish-OperationReport 'УСПЕШНО' }
    Write-Host ('Экспорт готов: ' + $archive) -ForegroundColor Green
    if (-not $KeepReportOpen) {
        Write-Host 'Для импорта запустите этот же Start.cmd на другом устройстве (или скопируйте весь комплект с Backups).'
    }
    return $archive
}
# Находит готовые архивы в указанной папке или её непосредственных подпапках.
# Не пропускает новые форматы: все проверки используют SupportedArchiveSchemas.
function Assert-ArchiveMetadata([object]$Metadata,[bool]$RequireImportSchema = $false) {
    if ($Metadata -isnot [pscustomobject]) { throw 'metadata.json должен содержать один объект.' }
    foreach ($name in @('SchemaVersion','SourceAccount','SourceSid','SourceMachine','AccountType')) {
        if (-not $Metadata.PSObject.Properties[$name]) { throw ('В metadata.json не найдено поле ' + $name + '.') }
    }
    $schema = $Metadata.SchemaVersion
    if (($schema -isnot [int] -and $schema -isnot [long]) -or $schema -notin $Script:SupportedArchiveSchemas) {
        throw 'Версия формата архива не поддерживается.'
    }
    if ($RequireImportSchema -and $schema -lt 7) {
        throw 'Формат архива не подтверждает ограничение одним профилем. Создайте новый экспорт.'
    }
    if ($Metadata.SourceAccount -isnot [string] -or
        $Metadata.SourceAccount -notmatch '^[^\\/:*?"<>|\x00-\x1F]{1,64}\\[^\\/:*?"<>|\x00-\x1F]{1,64}$' -or
        $Metadata.SourceMachine -isnot [string] -or $Metadata.SourceMachine -notmatch '^[^\\/:*?"<>|\x00-\x20]{1,64}$' -or
        $Metadata.SourceSid -isnot [string] -or $Metadata.SourceSid -notmatch '^S-1-5-21-(?:[0-9]{1,10}-){3}[0-9]{1,10}$' -or
        $Metadata.AccountType -isnot [string] -or $Metadata.AccountType -notin @('Local','Domain')) {
        throw 'Метаданные архива повреждены или тип учётной записи не поддерживается.'
    }
    if ($Metadata.AccountType -ieq 'Local' -and
        ($Metadata.SourceAccount -split '\\',2)[0] -ine $Metadata.SourceMachine) {
        throw 'Локальная исходная учётная запись не соответствует имени компьютера.'
    }
}

function Assert-ArchiveCacheOutsideSource([string]$Source,[string]$StagingRoot) {
    $separator = [IO.Path]::DirectorySeparatorChar
    $separators = [char[]]@($separator,[IO.Path]::AltDirectorySeparatorChar)
    $sourcePath = [IO.Path]::GetFullPath($Source).TrimEnd($separators)
    $cachePath = [IO.Path]::GetFullPath($StagingRoot).TrimEnd($separators)
    if ($cachePath.Equals($sourcePath,[StringComparison]::OrdinalIgnoreCase) -or
        $cachePath.StartsWith(($sourcePath + $separator),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Папка выбранного архива содержит рабочий каталог программы. Выберите архив в отдельной папке.'
    }
}

function Get-AvailableArchives([string]$Root = $Script:BackupRoot) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    try { Assert-NoReparseAncestor $Root }
    catch { return @() }
    $list = @()
    $dirs = @((Get-Item -LiteralPath $Root -ErrorAction Stop))
    $dirs += @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)
    foreach ($dir in $dirs) {
        if ($dir.Name -match '\.partial_[a-fA-F0-9]+$') { continue }
        $metadataPath = Join-Path $dir.FullName 'metadata.json'
        try {
            $meta = Read-ArchiveMetadataFile $metadataPath
            Assert-ArchiveMetadata $meta
            if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'Store') -PathType Container)) { continue }
            $date = $dir.CreationTime
            if ($meta.PSObject.Properties['CreatedAt'] -and $meta.CreatedAt) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse([string]$meta.CreatedAt,[ref]$parsed)) { $date = $parsed }
            }
            $list += [pscustomobject]@{ Path=$dir.FullName; Computer=[string]$meta.SourceMachine;
                Account=[string]$meta.SourceAccount; Date=$date; Type=[string]$meta.AccountType; Schema=[int]$meta.SchemaVersion; Format='Папка' }
        } catch { continue }
    }
    # Новый формат: один ZIP в Backups. Содержимое metadata.json читается
    # прямо из ZIP, без распаковки всего профиля при открытии меню.
    foreach ($zipFile in @(Get-ChildItem -LiteralPath $Root -File -Filter '*.zip' -Force -ErrorAction SilentlyContinue)) {
        try {
            $info = Get-ProfileZipInfo $zipFile.FullName
            $meta = $info.Metadata
            Assert-ArchiveMetadata $meta
            $date = $zipFile.LastWriteTime
            if ($meta.PSObject.Properties['CreatedAt'] -and $meta.CreatedAt) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse([string]$meta.CreatedAt,[ref]$parsed)) { $date = $parsed }
            }
            $list += [pscustomobject]@{ Path=$zipFile.FullName; Computer=[string]$meta.SourceMachine;
                Account=[string]$meta.SourceAccount; Date=$date; Type=[string]$meta.AccountType; Schema=[int]$meta.SchemaVersion; Format='ZIP' }
        } catch { continue }
    }
    return @($list | Sort-Object Date -Descending)
}
function Show-DetectedArchives([object[]]$Archives) {
    if ($Archives.Count -eq 0) { return }
    Write-Host ''
    Write-Host ('Найдены архивы рядом со скриптом: ' + $Archives.Count) -ForegroundColor Green
    for ($i=0; $i -lt [Math]::Min($Archives.Count, 5); $i++) {
        $a = $Archives[$i]
        Write-Host ('  {0}. {1} | {2} | {3:dd.MM.yyyy HH:mm} | {4}' -f ($i+1),$a.Account,$a.Computer,$a.Date,$a.Format)
    }
    if ($Archives.Count -gt 5) { Write-Host ('  ... ещё ' + ($Archives.Count-5)) }
}
# Навигатор каталогов управляется цифрами и позволяет выбрать любую доступную папку.
function Browse-ArchiveDirectory {
    Title 'ВЫБОР ПАПКИ С АРХИВОМ'
    $drives = @(Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -in @(2,3,4) -and $_.DeviceID } | Sort-Object DeviceID)
    Write-Host ('1. Папка рядом с программой: '+$Script:BackupRoot)
    for ($i=0;$i -lt $drives.Count;$i++) { Write-Host ('{0}. Диск {1}' -f ($i+2),$drives[$i].DeviceID) }
    $manual=$drives.Count+2
    Write-Host (('{0}. Указать произвольный путь к папке (необязательно)' -f $manual))
    Write-Host '0. Назад'
    $pick=Choice 'Начальная папка' $manual
    if ($pick -eq 0) { return $null }
    if ($pick -eq 1) { $cur=$Script:BackupRoot }
    elseif ($pick -eq $manual) {
        $cur=(Read-Host 'Введите путь папки или UNC-путь (0 - отменить)').Trim().Trim('"')
        if (-not $cur -or $cur -eq '0') { return $null }
    } else { $cur=$drives[$pick-2].DeviceID+'\' }
    if (-not (Test-Path -LiteralPath $cur -PathType Container)) { throw ('Папка недоступна: '+$cur) }
    while ($true) {
        Title ('ТЕКУЩАЯ ПАПКА: '+$cur)
        $found=@(Get-AvailableArchives $cur)
        Write-Host ('1. Выбрать эту папку (архивов найдено: '+$found.Count+')')
        Write-Host '2. Подняться на уровень выше'
        $dirs=@(Get-ChildItem -LiteralPath $cur -Directory -ErrorAction Stop | Sort-Object Name)
        for ($i=0;$i -lt $dirs.Count;$i++) { Write-Host ('{0}. {1}' -f ($i+3),$dirs[$i].Name) }
        Write-Host '0. Назад'
        $n=Choice 'Выберите номер' ($dirs.Count+2)
        if ($n -eq 0) { return $null }
        if ($n -eq 1) { return $cur }
        if ($n -eq 2) {
            $parent=Split-Path -Parent $cur.TrimEnd('\')
            if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
                Write-Host 'Выше перейти нельзя.' -ForegroundColor Yellow
            } else { $cur=$parent }
        } else { $cur=$dirs[$n-3].FullName }
    }
}
# По умолчанию выбирается папка с программой, но доступны и любые другие диски.
function Select-Archive {
    $root=$Script:BackupRoot
    while ($true) {
        $archives=@(Get-AvailableArchives $root)
        Title 'АРХИВЫ ДЛЯ ВОССТАНОВЛЕНИЯ'
        Write-Host ('Папка: '+$root)
        for ($i=0;$i -lt $archives.Count;$i++) {
            $a=$archives[$i]
            Write-Host ('{0}. {1} | {2} | {3:dd.MM.yyyy HH:mm} | {4} | {5}' -f ($i+1),$a.Account,$a.Computer,$a.Date,$a.Type,$a.Format)
        }
        $other=$archives.Count+1
        Write-Host ('{0}. Выбрать другую папку с архивом' -f $other)
        Write-Host '0. Назад'
        $n=Choice 'Выберите архив или папку' $other
        if ($n -eq 0) { return $null }
        if ($n -eq $other) {
            $picked=Browse-ArchiveDirectory
            # 0 внутри навигатора отменяет весь выбор архива, а не запускает его заново.
            if (-not $picked) { return $null }
            $root=$picked
            continue
        }
        return $archives[$n-1].Path
    }
}
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
function Do-Import([string]$Usmt,[bool]$JustVerify = $false,[string]$ArchiveOverride = '',[string]$TargetOverride = '',[bool]$Unattended = $false) {
    $archive = if ($ArchiveOverride) { $ArchiveOverride } else { Select-Archive }
    if (-not $archive) { Write-OperationReport 'ОТМЕНА' 'Выбор архива отменён.'; return }
    $isZip = ([IO.Path]::GetExtension($archive) -ieq '.zip')
    $archive = [IO.Path]::GetFullPath($archive)
    $selectedArchive = $archive
    $operationKind = if ($JustVerify) { 'Проверка архива' } else { 'Импорт' }
    Start-TrackedState $operationKind $selectedArchive
    $stagedArchive = $null
    $mutationLock = $null
    try {
    Advance-OperationStage 'Архив выбран'
    if ($isZip) {
        $isNetworkZip = Test-IsUncPath $archive
        if ($isNetworkZip) { Ensure-PathAvailable $archive 'Сетевой ZIP' }
        $zipInfo = Get-ProfileZipInfo $archive
        Assert-ArchiveMetadata $zipInfo.Metadata (-not $JustVerify)
        $stagingRoot = Join-Path $env:ProgramData 'WindowsProfileMigration\Staging'
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
        $stagedArchive = New-StagingDirectory 'ImportCache'
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
        $archive = $extracted
    } else {
        if (Test-IsUncPath $archive) { Ensure-PathAvailable $archive 'Выбранный сетевой архив' }
        $stagingRoot = Join-Path $env:ProgramData 'WindowsProfileMigration\Staging'
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
    if (-not $JustVerify) {
        $requiredImportBytes = if ($meta.PSObject.Properties.Name -contains 'EstimatedProfileBytes' -and $meta.EstimatedProfileBytes) { [UInt64]$meta.EstimatedProfileBytes } else { [UInt64](Get-FolderMetrics $store).Bytes }
        Test-TargetFreeSpace $requiredImportBytes
    }
    $logRoot = Join-Path $env:ProgramData ('WindowsProfileMigration\Logs\' + $(if ($JustVerify) { 'Check_' } else { 'Import_' }) + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))
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
    $targetSid = $confirmed.Sid
    if ($createLocal) {
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
            return
        }
    }
    $latest = Resolve-ImportTarget $meta $TargetOverride
    if ($latest.CreateLocal -or $latest.Sid -ne $targetSid -or $latest.Account -ine $target) {
        throw 'Целевая учётная запись изменилась до LoadState.'
    }
    Assert-ImportProfileUnused $targetSid
    $log = Join-Path $logRoot ('loadstate_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.log')
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
    $targetProfile = Get-TargetUserProfile $target
    if ($targetProfile.Sid -ne $targetSid) { throw 'SID восстановленного профиля отличается от подтверждённой учётной записи.' }
    Advance-OperationStage 'Целевой профиль обнаружен'
    Update-TrackedState 'Профиль найден, выполняется проверка' @{TargetProfile=$targetProfile.Path}
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
    Update-TrackedState 'Технически завершено, ожидает приёмки' @{ImportCompleted=$true}
    Advance-OperationStage 'Результаты восстановления записаны в отчёт'
    if (Clear-TrackedStaging $Script:ActiveOpState $false) {
        Advance-OperationStage 'Временные файлы очищены'
    }
    Finish-OperationReport ('ТЕХНИЧЕСКИ ЗАВЕРШЕНО; '+$validationStatus+'; ОЖИДАЕТ ПРИЁМКИ')
    Write-Host 'Не удаляйте источник и архив до проверки всех данных.' -ForegroundColor Yellow
    return $true
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

# Подготовка компьютера-получателя. Пользователь явно разрешает настройку WinRM.
# Сетевые профили Public, TrustedHosts и ослабление UAC автоматически не меняются.
function Prepare-RemoteReceiver {
    Title 'ПОДГОТОВКА КОМПЬЮТЕРА К ПРИЁМУ ПО СЕТИ'
    Write-Host ('Компьютер-получатель: ' + $env:COMPUTERNAME)
    Write-Host 'Настройка разрешит удалённое администрирование PowerShell для подключений, допускаемых Windows Firewall.'
    Write-Host 'Для домашней сети используйте сетевой профиль «Частная», в компании - «Доменная».'
    Write-Host 'На сервере и клиенте по-прежнему потребуются права администратора.'
    if (-not (Confirm 'Разрешить PowerShell Remoting на ЭТОМ компьютере?')) {
        Write-OperationReport 'ОТМЕНА' 'Подготовка WinRM отклонена.'
        return
    }
    Enable-PSRemoting -Force -ErrorAction Stop
    Advance-OperationStage 'WinRM настроен по правилам Windows'
    $listeners = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue)
    Write-OperationReport 'СЕТЬ' ('Слушателей WinRM: ' + $listeners.Count)
    Write-Host 'Приём сетевого переноса включён. На исходном ПК выберите пункт 5.' -ForegroundColor Green
    Write-Host ('Имя этого ПК: ' + $env:COMPUTERNAME)
    Write-Host 'Для другого домена или IP используйте сертификат WinRM HTTPS либо согласованную администраторами настройку доверия к конкретному узлу.'
    Finish-OperationReport 'УСПЕШНО'
}

# После отключения питания исходный готовый ZIP остаётся на диске.
# Новый запуск повторяет сетевой этап, не сканируя исходный профиль снова.
function Select-DirectTransferArchive {
    $files = @()
    if (Test-Path -LiteralPath $Script:WpmWorkRoot) { Assert-WpmWorkRoot }
    $roots = @(
        (Join-Path $Script:WpmWorkRoot 'DirectTransfers'),
        (Join-Path $env:ProgramData 'WindowsProfileMigration\DirectTransfers')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        Assert-WpmDirectoryChain $root
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Filter '*.zip' -ErrorAction Stop | Sort-Object LastWriteTime -Descending)) {
            try {
                $info = Get-ProfileZipInfo $file.FullName
                Assert-ArchiveMetadata $info.Metadata $true
                $files += [pscustomobject]@{Path=$file.FullName;Name=$file.Name;
                    User=[string]$info.Metadata.SourceAccount;Size=$file.Length;Date=$file.LastWriteTime}
            } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Неполный/повреждённый ZIP пропущен: ' + $file.Name + ': ' + $_.Exception.Message) }
        }
    }
    Title 'ПОВТОР ПРЕРВАННОГО СЕТЕВОГО ПЕРЕНОСА'
    if ($files.Count -eq 0) { Write-Host 'Готовых ZIP для продолжения нет.' -ForegroundColor Yellow; return $null }
    for ($i=0;$i -lt $files.Count;$i++) {
        Write-Host ('{0}. {1} | {2} | {3} | {4:dd.MM.yyyy HH:mm}' -f ($i+1),$files[$i].User,$files[$i].Name,
            (Format-ByteSize ([UInt64]$files[$i].Size)),$files[$i].Date)
    }
    Write-Host '0. Назад'
    $choice = Choice 'Выберите готовый ZIP' $files.Count
    if ($choice -eq 0) { return $null }
    return $files[$choice-1].Path
}

# Объединяет диагностику обоих ПК в один TXT источника. На целевом остаётся
# независимый TXT для аварийного случая, когда сеть оборвалась во время импорта.
function Include-RemoteReport([object]$Session,[string]$RemoteRoot) {
    if (-not $Session -or -not $RemoteRoot) { return }
    $path = Invoke-Command -Session $Session -ArgumentList $RemoteRoot -ErrorAction Stop -ScriptBlock {
        param($root)
        $folder = Join-Path $root 'Reports'
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return }
        Get-ChildItem -LiteralPath $folder -Filter 'Итог_работы_*.txt' -File |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $path) { return }
    Write-OperationReport 'УДАЛЁННЫЙ ОТЧЁТ' ('Полный TXT на получателе: ' + $path)
    $lines = Invoke-Command -Session $Session -ArgumentList $path -ErrorAction Stop -ScriptBlock {
        param($report)
        Get-Content -LiteralPath $report -Encoding UTF8 -ErrorAction Stop
    }
    foreach ($line in @($lines)) { Write-OperationReport 'ОТЧЁТ ЦЕЛЕВОГО ПК' ([string]$line) }
}

# На каждом сеансе проверяем получателя после смены DNS или долгого экспорта.
function Connect-RemoteMigration([hashtable]$Connection,[object]$ExpectedComputer) {
    $newSession = New-PSSession @Connection
    try {
        $computer = Invoke-Command -Session $newSession -ErrorAction Stop -ScriptBlock {
            $machineGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
            [pscustomobject]@{Name=$env:COMPUTERNAME; Identity=[string]$machineGuid; ProgramData=$env:ProgramData}
        }
        if ($computer.Name -ine $ExpectedComputer.Name -or
            $computer.Identity -ine $ExpectedComputer.Identity -or
            $computer.ProgramData -ine $ExpectedComputer.ProgramData) {
            throw 'Сетевой адрес ведёт на другое устройство. Перенос остановлен.'
        }
        return $newSession
    } catch {
        Remove-PSSession -Session $newSession -ErrorAction SilentlyContinue
        throw
    }
}

function Initialize-RemoteMigrationDirectory([object]$Session,[string]$TransferId) {
    Invoke-Command -Session $Session -ArgumentList $TransferId -ErrorAction Stop -ScriptBlock {
        param($id)
        if ($id -cnotmatch '^WPM_[0-9A-F]{24}$') { throw 'Неверный идентификатор прямого переноса.' }
        $programData = Get-Item -LiteralPath $env:ProgramData -Force -ErrorAction Stop
        if (-not $programData.PSIsContainer -or ($programData.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Каталог ProgramData должен быть локальным каталогом без перенаправления.'
        }
        $base = Join-Path $programData.FullName 'WindowsProfileMigration-RemoteDeploy'
        $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        if (-not (Test-Path -LiteralPath $base)) {
            # Права задаются одновременно с созданием каталога.
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner($administrators)
            $acl.SetAccessRuleProtection($true,$false)
            foreach ($identity in @($administrators,$system)) {
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                    $identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
            }
            [void][IO.Directory]::CreateDirectory($base,$acl)
        }
        $rootItem = Get-Item -LiteralPath $base -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw ('Каталог назначения должен быть локальным каталогом без перенаправления: ' + $base)
        }
        $rootAcl = Get-Acl -LiteralPath $base -ErrorAction Stop
        $owner = $rootAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        $trusted = @($administrators.Value,$system.Value)
        if (-not $rootAcl.AreAccessRulesProtected -or $owner -notin $trusted) {
            throw ('Каталог назначения не защищён от подмены: ' + $base)
        }
        foreach ($rule in $rootAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $trusted) {
                throw ('Каталог назначения доступен посторонним: ' + $base)
            }
        }
        $root = Join-Path $base $id
        $backup = Join-Path $root 'Backups'
        foreach ($folder in @($root,$backup)) {
            [void][IO.Directory]::CreateDirectory($folder)
            $item = Get-Item -LiteralPath $folder -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw ('Обнаружено перенаправление временного каталога: ' + $folder)
            }
        }
        return $root
    }
}

function Read-RemoteTransferBlock([IO.Stream]$Source,[byte[]]$Buffer,[int]$Count) {
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Source.Read($Buffer,$offset,$Count-$offset)
        if ($read -eq 0) { throw 'Исходный ZIP завершился до ожидаемой длины.' }
        $offset += $read
    }
}

function Get-RemoteTransferPrefixHash([IO.Stream]$Source,[long]$Length,[byte[]]$Buffer) {
    $remaining = $Length
    $Source.Position = 0
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        while ($remaining -gt 0) {
            $count = [int][Math]::Min([long]$Buffer.Length,$remaining)
            Read-RemoteTransferBlock $Source $Buffer $count
            [void]$hash.TransformBlock($Buffer,0,$count,$Buffer,0)
            $remaining -= $count
        }
        [void]$hash.TransformFinalBlock([byte[]]@(),0,0)
        return [BitConverter]::ToString($hash.Hash).Replace('-','')
    } finally { $hash.Dispose() }
}

function Get-RemoteArchiveReceiver {
    return {
        param($mode,[string]$complete,[long]$expectedLength,[string]$expectedHash,
            [long]$offset,[string]$blockHash,[string]$payload)
        $lockPath = $complete + '.transfer.lock'
        try { $transferLock = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None') }
        catch [IO.IOException] { throw 'Другой сеанс проверяет или записывает этот ZIP. Повторите проверку позже.' }
        try {
            $partial = $complete + '.partial'
            # Пишем только в промежуточный файл. Полный ZIP публикуется
            # переименованием на том же томе после проверки SHA-256.
            foreach ($path in @($complete,$partial)) {
                if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
                    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        throw ('Неожиданный путь сетевого файла: ' + $path)
                    }
                }
            }
            if ($mode -eq 'state') {
                $volume = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($complete))
                if ([IO.File]::Exists($complete)) {
                    $file = [IO.FileInfo]::new($complete)
                    if ($file.Length -ne $expectedLength -or
                        (Get-FileHash -LiteralPath $complete -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expectedHash) {
                        throw 'Существующий полный ZIP не совпадает с источником. Перезапись заблокирована.'
                    }
                    return [pscustomobject]@{Complete=$true; Offset=$expectedLength; Hash=$expectedHash; Free=$volume.AvailableFreeSpace}
                }
                if (-not [IO.File]::Exists($partial)) {
                    return [pscustomobject]@{Complete=$false; Offset=0L; Hash=''; Free=$volume.AvailableFreeSpace}
                }
                $incomplete = [IO.File]::Open($partial,'Open','Read','Read')
                try {
                    if ($incomplete.Length -gt $expectedLength) { throw 'Промежуточный файл больше исходного ZIP.' }
                    $prefixHash = (Get-FileHash -InputStream $incomplete -Algorithm SHA256 -ErrorAction Stop).Hash
                    return [pscustomobject]@{Complete=$false; Offset=$incomplete.Length; Hash=$prefixHash; Free=$volume.AvailableFreeSpace}
                } finally { $incomplete.Dispose() }
            }
            if ($mode -eq 'append') {
                if ([IO.File]::Exists($complete)) { throw 'ZIP уже опубликован другой операцией.' }
                $data = [Convert]::FromBase64String($payload)
                if ($offset -lt 0 -or $data.Length -le 0 -or $data.Length -gt 2MB -or $data.Length -gt ($expectedLength - $offset)) {
                    throw 'Длина блока передачи выходит за границы ZIP.'
                }
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $actual = [BitConverter]::ToString($sha.ComputeHash($data)).Replace('-','') }
                finally { $sha.Dispose() }
                if ($actual -ne $blockHash) { throw 'Контрольная сумма принятого блока не совпала.' }
                $stream = [IO.File]::Open($partial,'OpenOrCreate','Write','None')
                try {
                    if ($stream.Length -ne $offset) { throw 'Позиция записи ZIP изменилась. Требуется повторная проверка.' }
                    $stream.Position = $offset
                    $stream.Write($data,0,$data.Length)
                    $stream.Flush($true)
                    return $stream.Length
                } finally { $stream.Dispose() }
            }
            if ($mode -ne 'finish') { throw 'Неизвестное действие при передаче ZIP.' }
            $pending = [IO.File]::Open($partial,'Open','Read','Read')
            try {
                if ($pending.Length -ne $expectedLength -or
                    (Get-FileHash -InputStream $pending -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expectedHash) {
                    throw 'Размер или SHA-256 принятого ZIP не совпал. Импорт заблокирован.'
                }
            } finally { $pending.Dispose() }
            # File.Move не перезаписывает результат конкурентного запуска.
            [IO.File]::Move($partial,$complete)
        } finally { $transferLock.Dispose() }
    }
}

function Send-RemoteArchive([ref]$Session,[hashtable]$Connection,[object]$ExpectedComputer,[IO.Stream]$Source,
    [string]$Destination,[string]$ExpectedHash,[long]$ReserveBytes) {
    $activity = 'Передача ZIP по WinRM'
    $receiver = Get-RemoteArchiveReceiver
    $buffer = New-Object byte[] (2MB)
    $hash = [Security.Cryptography.SHA256]::Create()
    $length = $Source.Length
    try {
        # Повторно вычисляем SHA-256 принятого префикса после потери связи.
        for ($attempt=1; $attempt -le 3; $attempt++) {
            try {
                if ($attempt -gt 1) {
                    if ($Session.Value) { Remove-PSSession -Session $Session.Value -ErrorAction SilentlyContinue }
                    $Session.Value = $null
                    Start-Sleep -Seconds 3
                    $Session.Value = Connect-RemoteMigration $Connection $ExpectedComputer
                }
                $rpc = @{Session=$Session.Value; ScriptBlock=$receiver; ErrorAction='Stop'}
                $state = Invoke-Command @rpc -ArgumentList 'state',$Destination,$length,$ExpectedHash
                [long]$offset = $state.Offset
                if ($offset -lt 0 -or $offset -gt $length) { throw 'Получатель вернул недопустимую позицию передачи.' }
                if ($state.Complete) {
                    Write-OperationReport 'ВОЗОБНОВЛЕНИЕ' 'Полный ZIP с тем же SHA-256 уже сохранён на получателе.'
                    return
                }
                if ($state.Free -lt ($length - $offset + $ReserveBytes)) {
                    throw ('Недостаточно места для ZIP и развёртывания. Доступно: ' + (Format-ByteSize $state.Free))
                }
                if ($offset -gt 0) {
                    if ((Get-RemoteTransferPrefixHash $Source $offset $buffer) -ne $state.Hash) {
                        throw ('Полученный префикс ZIP не совпадает с источником. Промежуточный файл сохранён для проверки: ' + $Destination + '.partial')
                    }
                    Write-OperationReport 'ВОЗОБНОВЛЕНИЕ' ('Проверено и повторно используется байт: ' + $offset)
                }
                $Source.Position = $offset
                while ($offset -lt $length) {
                    $status = (Format-ByteSize $offset) + ' из ' + (Format-ByteSize $length)
                    $percent = [int][Math]::Floor(100.0*$offset/$length)
                    Write-Progress -Id 4 -Activity $activity -Status $status -PercentComplete $percent
                    if (Test-RunningProcessStopRequest $activity 4) {
                        throw [OperationCanceledException]::new('Сетевая передача отменена. Подтверждённая часть ZIP сохранена.')
                    }
                    $count = [int][Math]::Min([long]$buffer.Length,$length-$offset)
                    Read-RemoteTransferBlock $Source $buffer $count
                    $blockHash = [BitConverter]::ToString($hash.ComputeHash($buffer,0,$count)).Replace('-','')
                    $payload = [Convert]::ToBase64String($buffer,0,$count)
                    $newOffset = Invoke-Command @rpc -ArgumentList 'append',$Destination,$length,$ExpectedHash,$offset,$blockHash,$payload
                    if ($newOffset -ne ($offset+$count)) { throw 'Получатель не подтвердил длину переданного блока.' }
                    $offset = $newOffset
                }
                if (Test-RunningProcessStopRequest $activity 4) {
                    throw [OperationCanceledException]::new('Сетевая передача отменена. Подтверждённая часть ZIP сохранена.')
                }
                Invoke-Command @rpc -ArgumentList 'finish',$Destination,$length,$ExpectedHash
                return
            } catch [OperationCanceledException] { throw }
            catch {
                # Повторяем только при потере транспорта. Ошибки места,
                # хешей и прав требуют диагностики.
                $connectionFailure = $_.Exception -is [System.Management.Automation.Remoting.PSRemotingTransportException] -or
                    ($Session.Value -and $Session.Value.State -ne 'Opened')
                if (-not $connectionFailure -or $attempt -eq 3) { throw }
                Write-DiagnosticFailure $_ ('WinRM: попытка передачи ' + $attempt)
                Write-Host 'Подключение прервано. Будет перепроверена сохранённая часть ZIP.' -ForegroundColor Yellow
            }
        }
    } finally {
        $hash.Dispose()
        Write-Progress -Id 4 -Activity $activity -Completed
    }
}

# Держим файловую блокировку в том же сеансе WinRM до конца развёртывания.
# Повторный запуск не меняет файлы работающего удалённого процесса.
function Enter-RemoteMigration([object]$Session,[string]$Root,[string]$Hash,[string]$Account) {
    Invoke-Command -Session $Session -ArgumentList $Root,$Hash,$Account -ErrorAction Stop -ScriptBlock {
        param($root,$hash,$account)
        $lockPath = Join-Path $root 'import.lock'
        try { $global:WpmDeploymentLock = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None') }
        catch [IO.IOException] { throw 'В каталоге переноса уже выполняется другая операция. Проверьте состояние на целевом ПК.' }
        $started = Join-Path $root 'import-started.txt'
        $done = Join-Path $root 'import-completed.txt'
        $tag = $hash + ' ' + $account
        if ([IO.File]::Exists($done)) {
            if ([IO.File]::Exists($started) -and [IO.File]::ReadAllText($started) -ieq $tag -and [IO.File]::ReadAllText($done) -ieq $tag) {
                return 'Completed'
            }
            throw ('Есть запись о другом или повреждённом импорте. Проверьте состояние на целевом ПК: ' + $root)
        }
        if ([IO.File]::Exists($started)) {
            throw ('Предыдущий запуск мог начать LoadState. Проверьте отчёт и состояние профиля на целевом ПК: ' + $root)
        }
        return 'Ready'
    }
}

function Invoke-RemoteProfileImport([object]$Session,[string]$Root,[string]$Archive,[string]$Account,[string]$Hash) {
    Invoke-Command -Session $Session -ArgumentList $Root,$Archive,$Account,$Hash -ErrorAction Stop -ScriptBlock {
        param($root,$zip,$account,$hash)
        function Get-MigrationLaunchOptions([string]$Script) {
            $policy = Get-ExecutionPolicy -ErrorAction Stop
            $options = @('-NoProfile','-NonInteractive')
            if ($policy -eq 'Restricted') {
                $configured = @(Get-ExecutionPolicy -List -ErrorAction Stop | Where-Object ExecutionPolicy -ne 'Undefined')
                if ($configured.Count -gt 0) {
                    throw 'Настроенная политика Windows PowerShell запрещает сценарии на получателе. Импорт ещё не запущен.'
                }
                # Штатный Restricted при отсутствии настроенных политик
                # заменяется RemoteSigned только в этом дочернем процессе.
                $options += @('-ExecutionPolicy','RemoteSigned')
                $policy = 'RemoteSigned'
            }
            $remoteOrigin = $false
            if ($policy -in @('RemoteSigned','Unrestricted')) {
                $zone = @(Get-Content -LiteralPath $Script -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue)
                $remoteOrigin = @($zone | Where-Object { $_ -match '^\s*ZoneId\s*=\s*[34]\s*$' }).Count -gt 0
            }
            if ($policy -eq 'AllSigned' -or ($remoteOrigin -and $policy -in @('RemoteSigned','Unrestricted'))) {
                $signature = Get-AuthenticodeSignature -LiteralPath $Script -ErrorAction Stop
                if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate) {
                    throw 'Получатель требует подписанный сценарий. Импорт ещё не запущен.'
                }
                $thumbprint = $signature.SignerCertificate.Thumbprint
                if (-not (Test-Path -LiteralPath ('Cert:\LocalMachine\TrustedPublisher\' + $thumbprint)) -and
                    -not (Test-Path -LiteralPath ('Cert:\CurrentUser\TrustedPublisher\' + $thumbprint))) {
                    throw 'Издатель сценария не добавлен в доверенные на получателе. Импорт ещё не запущен.'
                }
            }
            return $options
        }
        function Write-ImportMarker([string]$Path,[string]$Text) {
            $buffer = [Text.Encoding]::UTF8.GetBytes($Text)
            $file = [IO.File]::Open($Path,'CreateNew','Write','None')
            try {
                $file.Write($buffer,0,$buffer.Length)
                $file.Flush($true)
            } finally { $file.Dispose() }
        }
        # Запись о начале сохраняется до запуска дочернего процесса. После
        # потери питания или связи она запрещает автоматическое повторение.
        $tag = $hash + ' ' + $account
        $script = Join-Path $root 'ProfileMigration.ps1'
        $binary = Join-Path $PSHOME 'powershell.exe'
        $started = Join-Path $root 'import-started.txt'
        $done = Join-Path $root 'import-completed.txt'
        if (-not (Test-Path -LiteralPath $script -PathType Leaf) -or -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
            throw 'Отсутствует удалённый сценарий импорта или Windows PowerShell.'
        }
        $launchOptions = @(Get-MigrationLaunchOptions $script)
        $lockedZip = [IO.File]::Open($zip,'Open','Read','Read')
        try {
            if ((Get-FileHash -InputStream $lockedZip -Algorithm SHA256 -ErrorAction Stop).Hash -ne $hash) {
                throw 'SHA-256 ZIP изменился до запуска импорта.'
            }
            Write-ImportMarker $started $tag
            & $binary @launchOptions -File $script -ToolRoot $root -RemoteImportArchive $zip -RemoteTargetAccount $account
            if ($LASTEXITCODE -ne 0) { throw ('На целевом ПК импорт завершился кодом ' + $LASTEXITCODE + '.') }
            Write-ImportMarker $done $tag
            'WPM_REMOTE_SUCCESS'
        } finally { $lockedZip.Dispose() }
    }
}

# WinRM передаёт проверяемый ZIP и запускает подтверждённый импорт.

# Требуется предварительно разрешённый администратором удалённый доступ.
function Do-RemoteDeploy([string]$Usmt,[string]$ResumeZip = '') {
    $session = $null
    $remoteRoot = $null
    $remoteArchive = $null
    $zipStream = $null
    $releaseDeploymentLock = $false
    try {
        if ($ResumeZip) {
            if (-not (Test-Path -LiteralPath $ResumeZip -PathType Leaf)) { throw 'ZIP возобновления не найден.' }
            $zipStream = [IO.File]::Open($ResumeZip,'Open','Read','Read')
            $resumeInfo = Get-ProfileZipInfo $ResumeZip
            Assert-ArchiveMetadata $resumeInfo.Metadata $true
            $sourceProfile = [pscustomobject]@{Account=[string]$resumeInfo.Metadata.SourceAccount;
                Type=[string]$resumeInfo.Metadata.AccountType;Loaded=$false;Path='(готовый ZIP)' }
            if (-not $sourceProfile.Account) { throw 'В архиве отсутствует имя исходного пользователя.' }
            Write-OperationReport 'ВОЗОБНОВЛЕНИЕ' ('Повторный перенос из готового ZIP: ' + $ResumeZip)
        } else {
            $sourceProfile = Select-Profile
            if (-not $sourceProfile) { Write-OperationReport 'ОТМЕНА' 'Профиль для прямого переноса не выбран.'; return }
        }
        if ($sourceProfile.Loaded) { throw 'Исходный профиль загружен. Пользователь должен выйти из Windows перед прямым переносом.' }
        Advance-OperationStage 'Выбран профиль для прямого переноса'

        Title 'ПРЯМОЙ ПЕРЕНОС ПО СЕТИ'
        Write-Host 'Укажите целевой ПК: имя в локальной сети, полное DNS-имя (pc.domain.local) либо IP.'
        Write-Host '0. Назад'
        $targetHost = ([string](Read-Host 'Целевой ПК / FQDN / IP')).Trim()
        if (-not $targetHost -or $targetHost -eq '0') { Write-OperationReport 'ОТМЕНА' 'Ввод сетевого адреса отменён.'; return }
        if ($targetHost -notmatch '^[a-zA-Z0-9_.:\-]{1,253}$' -or $targetHost.StartsWith('-')) {
            throw 'Неверный адрес назначения. Введите имя ПК, FQDN или IP без пробелов и обратных слешей.'
        }
        Write-Host 'Протокол подключения:'
        Write-Host '1. WinRM HTTP (Kerberos/Negotiate, обычно внутри домена или домашней сети)'
        Write-Host '2. WinRM HTTPS (требуется настроенный сертификат целевого ПК)'
        Write-Host '0. Назад'
        $transport = Choice 'Выберите протокол' 2
        if ($transport -eq 0) { Write-OperationReport 'ОТМЕНА' 'Выбор протокола отменён.'; return }
        Write-Host 'Доступ к целевому компьютеру:'
        Write-Host '1. Моя текущая учётная запись администратора (единый домен/доверие)'
        Write-Host '2. Другой администратор назначения (в том числе другой домен/локальный ПК)'
        Write-Host '0. Назад'
        $auth = Choice 'Выберите способ входа' 2
        if ($auth -eq 0) { Write-OperationReport 'ОТМЕНА' 'Выбор администратора отменён.'; return }
        $remoteCredential = $null
        if ($auth -eq 2) {
            $remoteCredential = Get-Credential -Message ('Администратор компьютера ' + $targetHost + ' (DOMAIN\user или COMPUTER\user)')
            if (-not $remoteCredential) { Write-OperationReport 'ОТМЕНА' 'Ввод учётных данных отменён.'; return }
        }
        Write-Host ('Проверка удалённого подключения: ' + $targetHost) -ForegroundColor Cyan
        Write-OperationReport 'СЕТЬ' ('Подключение к ' + $targetHost + '; протокол=' + $(if ($transport -eq 2) { 'HTTPS' } else { 'HTTP' }) + '; явные полномочия=' + ($auth -eq 2))
        $connection = @{ComputerName=$targetHost; ConfigurationName='Microsoft.PowerShell'; Authentication='Negotiate'; ErrorAction='Stop'}
        if ($transport -eq 2) { $connection['UseSSL'] = $true }
        if ($remoteCredential) { $connection['Credential'] = $remoteCredential }
        try { $session = New-PSSession @connection }
        catch {
            Write-DiagnosticFailure $_ 'WinRM: создание удалённой сессии'
            throw ('Подключение WinRM не установлено: ' + $_.Exception.Message + '. На целевом ПК запустите Start.cmd и пункт 6. Для IP/другого домена настройте WinRM HTTPS либо точечное доверие TrustedHosts по правилам вашей сети.')
        }
        Advance-OperationStage 'Соединение WinRM с целевым ПК открыто'
        $remote = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $admin = [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            $computer = Get-CimInstance Win32_ComputerSystem
            $system = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $machineGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
            $root = [IO.Path]::GetPathRoot($env:ProgramData)
            $free = [IO.DriveInfo]::new($root).AvailableFreeSpace
            [pscustomobject]@{
                Name=$env:COMPUTERNAME; Domain=$computer.Domain; PartOfDomain=$computer.PartOfDomain;
                Windows=$system.Caption; Version=$system.Version; IsAdmin=$admin; ProductType=$system.ProductType;
                Identity=[string]$machineGuid; Is64Bit=[Environment]::Is64BitProcess;
                Architecture=$env:PROCESSOR_ARCHITECTURE; FreeBytes=$free;
                ProgramData=$env:ProgramData
            }
        }
        if (-not $remote.IsAdmin) { throw 'Удалённый вход не имеет полного административного токена. Проверьте права назначения и политики удалённого UAC.' }
        if ([string]$remote.Version -notmatch '^10\.' -or $remote.ProductType -ne 1) { throw 'Целевой ПК должен работать под Windows 10 или Windows 11.' }
        if (-not $remote.Is64Bit -or $remote.Architecture -notin @('AMD64','ARM64')) { throw 'На целевом ПК требуется 64-разрядный Windows PowerShell для x64 или ARM64.' }
        $sourceIdentity = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
        if (-not $remote.Identity -or $remote.Identity -ieq $sourceIdentity) { throw 'Не удалось отличить целевой ПК от исходного. Перенос остановлен.' }
        Advance-OperationStage 'Проверены ОС, права и свободное место целевого ПК'
        Write-Host ('Целевой компьютер: ' + $remote.Name + ' | ' + $remote.Windows) -ForegroundColor Green
        Write-Host ('Домен или рабочая группа: ' + $remote.Domain)
        Write-Host ('Доступно на целевом диске: ' + (Format-ByteSize ([UInt64]$remote.FreeBytes)))

        $userName = ([string]$sourceProfile.Account -split '\\',2)[-1]
        $sameAccount = if ($sourceProfile.Type -eq 'Domain') { [string]$sourceProfile.Account }
            else { [string]$remote.Name + '\' + $userName }
        Write-Host 'Кому развернуть профиль на целевом ПК?'
        Write-Host ('1. Исходное имя пользователя: ' + $sameAccount)
        Write-Host ('2. Ввести имя локальной учётной записи на ' + $remote.Name)
        Write-Host '3. Указать учётную запись назначения DOMAIN\user или COMPUTER\user'
        Write-Host '0. Назад'
        $accountChoice = Choice 'Выберите назначение' 3
        if ($accountChoice -eq 0) { Write-OperationReport 'ОТМЕНА' 'Выбор пользователя назначения отменён.'; return }
        $targetAccount = switch ($accountChoice) {
            1 { $sameAccount }
            2 {
                $localName = (Read-Host 'Имя локальной учётной записи (0 - назад)').Trim()
                if ($localName -eq '0') { '0' }
                else { [string]$remote.Name + '\' + $localName }
            }
            3 { (Read-Host 'Введите DOMAIN\user или COMPUTER\user (0 - назад)').Trim() }
        }
        if ($targetAccount -eq '0') { Write-OperationReport 'ОТМЕНА' 'Ввод учётной записи отменён.'; return }
        if ($targetAccount -notmatch '^[^\\/:*?"<>|\x00-\x1F]{1,64}\\[^\\/:*?"<>|\x00-\x1F]{1,64}$') {
            throw 'Имя назначения должно иметь вид DOMAIN\user или COMPUTER\user.'
        }
        $targetCheck = Invoke-Command -Session $session -ArgumentList $targetAccount,([bool]$ResumeZip) -ScriptBlock {
            param($account,$checkingResume)
            $parts = $account -split '\\',2
            $existing = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special })
            if ($parts[0] -ieq $env:COMPUTERNAME) {
                if ($parts[1].Length -gt 20) { throw 'Имя локального пользователя длиннее 20 символов.' }
                $user = Get-LocalUser -Name $parts[1] -ErrorAction SilentlyContinue
                if ($user -and @($existing | Where-Object SID -eq $user.SID.Value).Count -gt 0) {
                    if ($checkingResume) { return 'Существующий профиль: будет проверено состояние прошлого переноса' }
                    throw 'Профиль назначения уже существует.'
                }
                if ($user -and -not $user.Enabled) { throw 'Локальный пользователь назначения отключён.' }
                return $(if ($user) { 'Локальный пользователь найден' } else { 'Новый локальный пользователь будет создан' })
            }
            $sid = ([Security.Principal.NTAccount]::new($account)).Translate([Security.Principal.SecurityIdentifier]).Value
            if (@($existing | Where-Object SID -eq $sid).Count -gt 0) {
                if ($checkingResume) { return 'Существующий профиль: будет проверено состояние прошлого переноса' }
                throw 'Целевой доменный пользователь уже имеет профиль.'
            }
            return 'Доменный пользователь доступен'
        } -ErrorAction Stop
        Write-OperationReport 'НАЗНАЧЕНИЕ' ('Выбрано: ' + $targetAccount + '; проверка: ' + $targetCheck)
        Advance-OperationStage 'Проверена учётная запись назначения'

        Write-Host ''
        Write-Host ('Источник: ' + $env:COMPUTERNAME + ' | ' + $sourceProfile.Account) -ForegroundColor Cyan
        Write-Host ('Назначение: ' + $remote.Name + ' | ' + $targetAccount) -ForegroundColor Cyan
        if ($ResumeZip) { Write-Host 'Будет проверено состояние переноса сохранённого ZIP на целевом ПК.' }
        else { Write-Host 'Будет автоматически: создан ZIP одного выбранного профиля, передан на целевой ПК, проверен и применён.' }
        Write-Host 'Готовый ZIP сохраняется на обоих компьютерах; прежний профиль назначения не перезаписывается.'
        if (-not (Confirm 'Начать полный прямой перенос с автоматическим развёртыванием?')) {
            Write-OperationReport 'ОТМЕНА' 'Прямой перенос отклонён.'
            return
        }
        Advance-OperationStage 'Подтверждён прямой перенос на выбранный ПК'
        # Экспорт может длиться часы. Завершаем проверочную сессию заранее,
        # чтобы ограничение WinRM по времени простоя не сорвало отправку.
        if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue; $session=$null }
        $zipPath = $ResumeZip
        if (-not $zipPath) {
            $localRoot = Join-Path $Script:WpmWorkRoot 'DirectTransfers'
            Initialize-WpmWorkDirectory $localRoot
            $zipPath = [string](Do-Export $Usmt $sourceProfile $localRoot $true $true)
        }
        if (-not $zipPath -or -not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw 'Экспорт не создал ZIP. Развёртывание остановлено.' }
        try { $session = Connect-RemoteMigration $connection $remote }
        catch { throw ('ZIP готов, но подключение к прежнему получателю не установлено. Архив сохранён: ' + $zipPath + '. При восстановлении связи выберите пункт 7. Ошибка: ' + $_.Exception.Message) }
        if (-not $zipStream) { $zipStream = [IO.File]::Open($zipPath,'Open','Read','Read') }
        $zipInfo = Get-ProfileZipInfo $zipPath
        $localHash = (Get-FileHash -InputStream $zipStream -Algorithm SHA256 -ErrorAction Stop).Hash
        Write-OperationReport 'ЭКСПОРТ' ('Готов ZIP: ' + $zipPath)
        Advance-OperationStage 'ZIP одного профиля подготовлен для отправки'

        $transferId = 'WPM_' + $localHash.Substring(0,24)
        $remoteRoot = Initialize-RemoteMigrationDirectory $session $transferId
        # Путь относится к диску получателя и не обязан существовать на источнике.
        $remoteArchive = [IO.Path]::Combine($remoteRoot,'Backups','Profile.zip')
        Write-OperationReport 'ПЕРЕДАЧА' ('ZIP получателя: ' + $remoteArchive + '; размер: ' + $zipStream.Length + ' байт')
        $reserve = [long]([decimal]$zipInfo.ExpandedBytes + [decimal]$zipInfo.Metadata.EstimatedProfileBytes + [decimal]2GB)
        Send-RemoteArchive ([ref]$session) $connection $remote $zipStream $remoteArchive $localHash $reserve
        Advance-OperationStage 'ZIP передан и проверен по SHA-256'
        Write-OperationReport 'ПРОВЕРКА' ('ZIP передан без изменений, SHA-256: ' + $localHash)

        $releaseDeploymentLock = $true
        $deployment = Enter-RemoteMigration $session $remoteRoot $localHash $targetAccount
        if ($deployment -eq 'Completed') {
            Write-OperationReport 'ВОЗОБНОВЛЕНИЕ' 'На получателе сохранено подтверждение завершения импорта этого ZIP для выбранного пользователя.'
            try { Include-RemoteReport $session $remoteRoot }
            catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось прочитать удалённый отчёт: ' + $_.Exception.Message) }
            Finish-OperationReport 'РАНЕЕ ТЕХНИЧЕСКИ ЗАВЕРШЕНО; ОЖИДАЕТ ПРОВЕРКИ ПОД ПОЛЬЗОВАТЕЛЕМ'
            Write-Host 'Этот архив уже применён для выбранной учётной записи. Проверьте профиль на целевом ПК.' -ForegroundColor Green
            return
        }
        # При возобновлении допускаем существующий профиль до чтения записи
        # о завершении. Без этой записи импорт в него запрещён и здесь.
        if ($targetCheck -like 'Существующий профиль:*') {
            throw 'Целевой профиль уже существует, а подтверждение предыдущего импорта отсутствует. Проверьте состояние на получателе.'
        }

        foreach ($filename in @('ProfileMigration.ps1','Bootstrap.ps1','Start.cmd')) {
            $sourceFile = Join-Path $Script:ToolRoot $filename
            $remoteFile = [IO.Path]::Combine($remoteRoot,$filename)
            $scriptHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256 -ErrorAction Stop).Hash
            Copy-Item -LiteralPath $sourceFile -Destination $remoteFile -ToSession $session -Force -ErrorAction Stop
            $remoteScriptHash = Invoke-Command -Session $session -ArgumentList $remoteFile -ErrorAction Stop -ScriptBlock {
                param($path)
                (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
            }
            if ($remoteScriptHash -ne $scriptHash) { throw ('SHA-256 переданного файла не совпал: ' + $filename) }
        }
        Advance-OperationStage 'Скрипты на целевом ПК сверены по SHA-256'

        $targetArch = ([string]$remote.Architecture).ToLowerInvariant()
        $targetUsmt = [IO.Path]::Combine($remoteRoot,'USMT',$targetArch)
        $hasTargetUsmt = Invoke-Command -Session $session -ArgumentList $targetUsmt,$targetArch -ErrorAction Stop -ScriptBlock {
            param($bundled,$arch)
            $kit = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
            if (-not $kit) { $kit = $env:ProgramFiles }
            $installed = Join-Path $kit ('Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool\' + $arch)
            foreach ($path in @($installed,$bundled)) {
                $missing = @('ScanState.exe','LoadState.exe','UsmtUtils.exe' | Where-Object {
                    -not (Test-Path -LiteralPath (Join-Path $path $_) -PathType Leaf)
                })
                if ($missing.Count -eq 0) { return $true }
            }
            return $false
        }
        if (-not $hasTargetUsmt) {
            $sourceArch = ([string]$env:PROCESSOR_ARCHITECTURE).ToLowerInvariant()
            if ($sourceArch -ne $targetArch) { throw 'Архитектуры ПК различаются. Установите USMT для архитектуры получателя через Start.cmd.' }
            $partialUsmt = $targetUsmt + '.partial'
            Invoke-Command -Session $session -ArgumentList $targetUsmt,$partialUsmt -ErrorAction Stop -ScriptBlock {
                param($ready,$partial)
                if (Test-Path -LiteralPath $ready) { throw 'Каталог USMT получателя неполон. Проверьте его на целевом ПК.' }
                [void][IO.Directory]::CreateDirectory($partial)
            }
            Write-Host 'Передача USMT на целевой ПК...' -ForegroundColor Cyan
            foreach ($item in Get-ChildItem -LiteralPath $Usmt -Force -ErrorAction Stop) {
                Copy-Item -LiteralPath $item.FullName -Destination $partialUsmt -Recurse -ToSession $session -Force -ErrorAction Stop
            }
            Invoke-Command -Session $session -ArgumentList $partialUsmt,$targetUsmt -ErrorAction Stop -ScriptBlock {
                param($partial,$ready)
                foreach ($name in @('ScanState.exe','LoadState.exe','UsmtUtils.exe')) {
                    if (-not (Test-Path -LiteralPath (Join-Path $partial $name) -PathType Leaf)) {
                        throw ('Не удалось полностью скопировать USMT: ' + $name)
                    }
                }
                [IO.Directory]::Move($partial,$ready)
            }
            Write-OperationReport 'ПРОВЕРКА' ('USMT передан в каталог получателя: ' + $targetUsmt)
        }
        Advance-OperationStage 'USMT доступен целевому компьютеру'

        if (Test-RunningProcessStopRequest 'Подготовка удалённого импорта' 4) {
            throw [OperationCanceledException]::new('Удалённый импорт отменён до запуска. Проверенный ZIP сохранён.')
        }
        Write-Host 'Автоматический запуск LoadState на целевом компьютере...' -ForegroundColor Cyan
        $remoteSucceeded = $false
        Invoke-RemoteProfileImport $session $remoteRoot $remoteArchive $targetAccount $localHash | ForEach-Object {
            if ([string]$_ -eq 'WPM_REMOTE_SUCCESS') { $remoteSucceeded = $true }
            else { Write-Host ([string]$_) }
        }
        if (-not $remoteSucceeded) {
            throw 'Удалённый процесс не подтвердил успешное техническое завершение импорта.'
        }
        Advance-OperationStage 'LoadState выполнен на целевом ПК'
        try {
            Include-RemoteReport $session $remoteRoot
            Advance-OperationStage 'Проверен отчёт получателя'
        } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Импорт подтверждён. Отчёт сохранён на получателе: ' + $_.Exception.Message) }
        Write-OperationReport 'ИТОГ' ('Прямой перенос: ' + $sourceProfile.Account + ' → ' + $targetAccount + '; получатель=' + $remote.Name + '; ZIP=' + $remoteArchive)
        Advance-OperationStage 'Прямой перенос завершён'
        Finish-OperationReport 'ТЕХНИЧЕСКИ ЗАВЕРШЕНО; ОЖИДАЕТ ПРОВЕРКИ ПОД ПОЛЬЗОВАТЕЛЕМ'
        Write-Host ('Готово. На целевом ПК выполнено автоматическое развёртывание: ' + $targetAccount) -ForegroundColor Green
    } catch {
        Write-DiagnosticFailure $_ 'Прямой сетевой перенос'
        if ($session -and $remoteRoot) {
            try { Include-RemoteReport $session $remoteRoot }
            catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Удалённый отчёт сейчас недоступен: ' + $_.Exception.Message) }
        }
        if ($remoteRoot) { Write-OperationReport 'ВОССТАНОВЛЕНИЕ' ('Каталог целевого ПК оставлен для повторной проверки: ' + $remoteRoot) }
        if ($remoteArchive) { Write-OperationReport 'ВОССТАНОВЛЕНИЕ' ('ZIP назначения (если уже передан): ' + $remoteArchive) }
        throw
    } finally {
        if ($zipStream) { $zipStream.Dispose() }
        if ($session) {
            if ($releaseDeploymentLock -and $session.State -eq 'Opened') {
                try {
                    Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                        $lock = Get-Variable -Name WpmDeploymentLock -Scope Global -ErrorAction SilentlyContinue
                        if ($lock) {
                            $lock.Value.Dispose()
                            Remove-Variable -Name WpmDeploymentLock -Scope Global
                        }
                    }
                } catch { }
            }
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

try {
    Ensure-Admin
    if (-not (Test-Path -LiteralPath (Join-Path $Script:ToolRoot 'Start.cmd') -PathType Leaf)) {
        throw ('Исходная папка недоступна процессу администратора: ' + $Script:ToolRoot + '. Для сетевого размещения используйте UNC-путь и предоставьте администратору доступ к общей папке.')
    }
    if ($Script:ToolRoot.StartsWith('\\')) {
        Write-Host ('Сетевая папка: ' + $Script:ToolRoot) -ForegroundColor Cyan
        Write-Host 'Профили содержат личные данные. Используйте защищённую общую папку с ограниченными правами.' -ForegroundColor Yellow
    }
    # Этот режим вызывается только из предварительно подтверждённой сессии
    # удалённого развертывания. Ни одного интерактивного запроса в этой ветке.
    if ($RemoteImportArchive -or $RemoteTargetAccount) {
        if (-not $RemoteImportArchive -or -not $RemoteTargetAccount) { throw 'Параметры удалённого импорта неполные.' }
        if (-not (Test-Path -LiteralPath $RemoteImportArchive -PathType Leaf) -or
            [IO.Path]::GetExtension($RemoteImportArchive) -ine '.zip') { throw 'Не найден локальный ZIP удалённого переноса.' }
        $remoteUsmt = Get-UsmtPath
        if (-not $remoteUsmt) { throw 'На целевом компьютере USMT отсутствует. Требуется установка или передача комплекта.' }
        Start-OperationReport 'ИМПОРТ'
        try {
            $importCompleted = Do-Import $remoteUsmt $false $RemoteImportArchive $RemoteTargetAccount $true
            if ($importCompleted -ne $true) { throw 'Удалённый импорт завершился без подтверждения результата.' }
            exit 0
        } catch {
            Write-DiagnosticFailure $_ 'Удалённый автоматический импорт'
            Finish-OperationReport 'СБОЙ УДАЛЁННОГО ИМПОРТА'
            throw
        }
    }
    # Подготовка приёмника и просмотр состояний доступны без установленного ADK.
    $usmt = Get-UsmtPath
    while ($true) {
        Title ('МИГРАЦИЯ ПРОФИЛЕЙ WINDOWS | v' + $Script:WpmVersion)
        Write-Host ('Компьютер: ' + $env:COMPUTERNAME)
        Write-Host ('Папка архивов: ' + $Script:BackupRoot)
        $readyArchives = @(Get-AvailableArchives)
        Show-DetectedArchives $readyArchives
        Write-Host ''
        Write-Host '1. Экспортировать профиль пользователя (выбор из списка)'
        if ($readyArchives.Count -gt 0) {
            Write-Host ('2. Применить сохранённый профиль (найдено: ' + $readyArchives.Count + ')') -ForegroundColor Green
        } else {
            Write-Host '2. Импортировать профиль (архивы пока не найдены)'
        }
        Write-Host '3. Проверить архив'
        Write-Host '4. Состояние операций, очистка и откат настроек'
        Write-Host '5. Напрямую перенести профиль на другой ПК по сети (автоматический импорт)'
        Write-Host '6. Подготовить этот ПК к приёму профиля по сети (WinRM)'
        Write-Host '7. Продолжить прерванный сетевой перенос из готового ZIP'
        Write-Host '0. Выход'
        $n = Choice 'Выберите действие' 7
        if ($n -eq 0) { break }
        if ($n -eq 4) { Show-RecoveryMenu; Pause-Menu; continue }
        try {
            $action = switch ($n) { 1 { 'ЭКСПОРТ' }; 2 { 'ИМПОРТ' }; 3 { 'ПРОВЕРКА АРХИВА' }; 5 { 'ПРЯМОЙ ПЕРЕНОС' }; 6 { 'ПОДГОТОВКА СЕТИ' }; 7 { 'ВОЗОБНОВЛЕНИЕ ПЕРЕНОСА' } }
            Start-OperationReport $action
            Write-OperationReport 'НАЧАТО' ('Действие: ' + $action)
            if ($n -in @(1,2,3,5,7) -and -not $usmt) {
                $usmt = Require-USMT
                if (-not $usmt) {
                    Write-OperationReport 'ПРОВЕРКА' 'USMT не готов. Миграция не запускалась.'
                    continue
                }
            }
            switch ($n) {
                1 { [void](Do-Export $usmt) }
                2 { [void](Do-Import $usmt $false) }
                3 { [void](Do-Import $usmt $true) }
                5 { Do-RemoteDeploy $usmt }
                6 { Prepare-RemoteReceiver }
                7 { $chosenZip = Select-DirectTransferArchive; if ($chosenZip) { Do-RemoteDeploy $usmt $chosenZip } }
            }
        } catch [System.OperationCanceledException] {
            Write-Host ('ОТМЕНЕНО: ' + $_.Exception.Message) -ForegroundColor Yellow
            Write-OperationReport 'ОТМЕНА' $_.Exception.Message
            Write-DiagnosticFailure $_ ('Отмена действия ' + $action)
            if ($Script:ActiveOpState) {
                try {
                    if ($Script:ActiveOpState.Kind -eq 'Экспорт') {
                        if ($Script:ActiveOpState.Status -eq 'Публикация отменена - локальная копия сохранена') {
                            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Временные данные сохранены. Просмотреть и очистить их можно через меню 4.'
                        } else {
                            Update-TrackedState 'Отменено пользователем во время USMT'
                            # Убираем только свою временную экспортную копию.
                            # Опубликованный архив и исходный профиль не затрагиваются.
                            if ($Script:ActiveOpState.StagingPath -and -not $Script:ActiveOpState.CleanupDone) {
                                [void](Clear-TrackedStaging $Script:ActiveOpState $false)
                            }
                        }
                    } elseif ($Script:ActiveOpState.Kind -eq 'Импорт' -and
                              $Script:ActiveOpState.USMTStarted -and -not $Script:ActiveOpState.USMTFinished) {
                        Write-Host 'Целевой профиль мог быть частично восстановлен. Смотрите пункт 4 меню.' -ForegroundColor Yellow
                    }
                    if ($Script:ActiveOpState.StagingPath -and -not $Script:ActiveOpState.CleanupDone) {
                        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Временная копия оставлена для проверки: ' + $Script:ActiveOpState.StagingPath)
                    }
                } catch {
                    Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось завершить учёт отмены: ' + $_.Exception.Message)
                }
            }
            Finish-OperationReport 'ОТМЕНЕНО ПОЛЬЗОВАТЕЛЕМ'
        } catch {
            $Script:HadFailures = $true
            Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
            Write-OperationReport 'ОШИБКА' $_.Exception.Message
            Write-DiagnosticFailure $_ ('Действие ' + $action)
            if ($Script:ActiveOpState) {
                try { Update-TrackedState 'Сбой - операция не завершена' @{LastError=$_.Exception.Message} }
                catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось сохранить состояние сбоя: ' + $_.Exception.Message) }
                # До запуска ScanState во временной папке ещё нет миграционного
                # архива. Такой каталог создан программой и может быть очищен.
                if ($Script:ActiveOpState.Kind -eq 'Экспорт' -and
                    -not $Script:ActiveOpState.USMTStarted -and
                    $Script:ActiveOpState.StagingPath -and
                    -not $Script:ActiveOpState.CleanupDone) {
                    try {
                        [void](Clear-TrackedStaging $Script:ActiveOpState $false)
                    } catch {
                        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось очистить временную папку до ScanState: ' + $_.Exception.Message)
                    }
                }
                if ($Script:ActiveOpState.StagingPath -and -not $Script:ActiveOpState.CleanupDone) {
                    Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Осталась временная копия: ' + $Script:ActiveOpState.StagingPath)
                }
            }
            Finish-OperationReport 'СБОЙ (операция не завершена)'
            Write-Host 'Исходные файлы не удалялись. При неполном экспорте папка архива остаётся для диагностики.'
        } finally {
            if ($Script:ActiveOpState -and $Script:ActiveOpState.ProcessId -eq $PID) {
                try { Update-TrackedState '' @{ProcessId=0;ProcessStartTicks=0} }
                catch {
                    Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось освободить запись операции: ' + $_.Exception.Message)
                    Write-Host 'Запись операции станет доступна для восстановления после выхода из программы.' -ForegroundColor Yellow
                }
            }
            # Возврат без итогового статуса означает отмену или неполное действие.
            if ($Script:ReportPath) { Finish-OperationReport 'ОТМЕНЕНО / НЕ ЗАВЕРШЕНО' }
            $Script:ActiveOpState=$null
        }
        Pause-Menu
    }
    # Код выхода передаётся через Bootstrap.ps1 в Start.cmd.
    # Отмена пользователем не ошибка; хотя бы один реальный сбой даёт код 1.
    if ($Script:HadFailures) { exit 1 }
    exit 0
} catch {
    Write-Host ('ОШИБКА ЗАПУСКА: ' + $_.Exception.Message) -ForegroundColor Red
    if (-not $RemoteImportArchive) { Pause-Menu }
    exit 1
}
