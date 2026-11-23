# Главное меню связывает выбор пользователя с нужным действием.

function Invoke-WpmMainMenu {
$remoteReportStarted = $false
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
    if ($RemoteImportArchive -or $RemoteTargetAccount -or $RemotePasswordFromInput) {
        Start-OperationReport 'ИМПОРТ'
        $remoteReportStarted = $true
        $remotePassword = $null
        try {
            Advance-OperationStage 'Подготовка удалённого импорта' -Starting
            if (-not $RemoteImportArchive -or -not $RemoteTargetAccount) { throw 'Параметры удалённого импорта неполные.' }
            $isProtected = Test-WpmProtectedArchive $RemoteImportArchive
            if (-not (Test-Path -LiteralPath $RemoteImportArchive -PathType Leaf) -or
                (-not $isProtected -and [IO.Path]::GetExtension($RemoteImportArchive) -ine '.zip')) {
                throw 'Не найден локальный архив удалённого переноса.'
            }
            if ($isProtected -ne [bool]$RemotePasswordFromInput) { throw 'Режим передачи пароля не соответствует архиву.' }
            $remoteUsmt = Get-UsmtPath
            if (-not $remoteUsmt) { throw 'На целевом компьютере USMT отсутствует. Требуется установка или передача комплекта.' }
            if ($isProtected) {
                Advance-OperationStage 'Получение пароля архива по закрытому каналу' -Starting
                $remotePassword = Read-RemoteArchivePassword
            }
            $outcome = Do-Import $remoteUsmt $false $RemoteImportArchive $RemoteTargetAccount $true -ArchivePassword $remotePassword
            if (-not $outcome -or -not $outcome.PSObject.Properties['Result']) {
                throw 'Удалённый импорт завершился без подтверждения результата.'
            }
            # Коды 11–25 передают причины неполного переноса или ограниченной проверки. Код 1 означает сбой запуска или импорта.
            if ($outcome.Result) { exit (10 + [int]$outcome.Result) }
            exit 0
        } catch {
            Write-OperationReport 'ОШИБКА' $_.Exception.Message
            Write-DiagnosticFailure $_ 'Удалённый автоматический импорт'
            Finish-OperationReport 'СБОЙ УДАЛЁННОГО ИМПОРТА'
            throw
        } finally {
            if ($remotePassword) { $remotePassword.Dispose() }
        }
    }
    Invoke-InteractiveMenu
    # Код выхода передаётся через Bootstrap.ps1 в Start.cmd.
    # Отмена пользователем не ошибка; хотя бы один реальный сбой даёт код 1.
    if ($Script:HadFailures) { exit 1 }
    exit 0
} catch {
    $failure = $_
    if (-not $remoteReportStarted) {
        try {
            if (-not $Script:ReportPath) { Start-OperationReport 'ЗАПУСК' }
            Write-OperationReport 'ОШИБКА' $failure.Exception.Message
            Write-DiagnosticFailure $failure 'Запуск программы или главного меню'
            Finish-OperationReport 'СБОЙ ЗАПУСКА'
        } catch { Write-Host ('Отчёт о сбое запуска недоступен: ' + $_.Exception.Message) -ForegroundColor Yellow }
    }
    Write-Host ('ОШИБКА ЗАПУСКА: ' + $failure.Exception.Message) -ForegroundColor Red
    if (-not $RemoteImportArchive) { Pause-Menu }
    exit 1
}
}

function Read-MainMenuChoice {
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
    Write-Host '7. Продолжить прерванный сетевой перенос из готового архива'
    Write-Host '0. Выход'
    return (Choice 'Выберите действие' 7)
}

function Invoke-MenuAction([int]$Number, [string]$Usmt) {
    switch ($Number) {
        1 { [void](Do-Export $Usmt) }
        2 { [void](Do-Import $Usmt $false) }
        3 { [void](Do-Import $Usmt $true) }
        5 { Do-RemoteDeploy $Usmt }
        6 { Prepare-RemoteReceiver }
        7 {
            $archive = Select-DirectTransferArchive
            if ($archive) { Do-RemoteDeploy $Usmt $archive }
        }
    }
}

# При отмене сохраняем сведения, по которым позже можно продолжить или убрать временную копию.
function Save-CanceledOperationState([hashtable]$State) {
    if ($State.Kind -eq 'Экспорт') {
        if ($State.Status -eq 'Публикация отменена - локальная копия сохранена') {
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Временные данные сохранены. Просмотреть и очистить их можно через меню 4.'
        } else {
            Update-TrackedState 'Экспорт отменён пользователем'
            # Убираем только свою временную экспортную копию.
            # Опубликованный архив и исходный профиль не затрагиваются.
            if ($State.StagingPath -and -not $State.CleanupDone) {
                [void](Clear-TrackedStaging $State $false)
            }
        }
    } elseif ($State.Kind -eq 'Импорт' -and
              $State.USMTStarted -and -not $State.USMTFinished) {
        Write-Host 'Целевой профиль мог быть частично восстановлен. Смотрите пункт 4 меню.' -ForegroundColor Yellow
    }
    if ($State.StagingPath -and -not $State.CleanupDone) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Временная копия оставлена для проверки: ' + $State.StagingPath)
    }
}

function Write-CanceledOperation($Failure, [string]$Action) {
    Write-Host ('ОТМЕНЕНО: ' + $Failure.Exception.Message) -ForegroundColor Yellow
    Write-OperationReport 'ОТМЕНА' $Failure.Exception.Message
    Write-DiagnosticFailure $Failure ('Отмена действия ' + $action)
    if ($Script:ActiveOpState) {
        try { Save-CanceledOperationState $Script:ActiveOpState }
        catch {
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось завершить учёт отмены: ' + $_.Exception.Message)
        }
    }
    Finish-OperationReport 'ОТМЕНЕНО ПОЛЬЗОВАТЕЛЕМ'
}

# Оставляем сведения о сбое. Пустую рабочую папку раннего экспорта можно убрать сразу.
function Save-FailedOperationState([hashtable]$State, [string]$Message) {
    try { Update-TrackedState 'Сбой - операция не завершена' @{LastError=$Message} }
    catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось сохранить состояние сбоя: ' + $_.Exception.Message) }
    # До запуска ScanState во временной папке ещё нет миграционного
    # архива. Такой каталог создан программой и может быть очищен.
    if ($State.Kind -eq 'Экспорт' -and
        -not $State.USMTStarted -and
        $State.StagingPath -and
        -not $State.CleanupDone) {
        try {
            [void](Clear-TrackedStaging $State $false)
        } catch {
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось очистить временную папку до ScanState: ' + $_.Exception.Message)
        }
    }
    if ($State.StagingPath -and -not $State.CleanupDone) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Осталась временная копия: ' + $State.StagingPath)
    }
}

function Write-FailedOperation($Failure, [string]$Action) {
    $Script:HadFailures = $true
    Write-Host ('ОШИБКА: ' + $Failure.Exception.Message) -ForegroundColor Red
    Write-OperationReport 'ОШИБКА' $Failure.Exception.Message
    Write-DiagnosticFailure $Failure ('Действие ' + $action)
    if ($Script:ActiveOpState) {
        Save-FailedOperationState $Script:ActiveOpState $Failure.Exception.Message
    }
    Finish-OperationReport 'СБОЙ (операция не завершена)'
    Write-Host 'Исходные файлы не удалялись. При неполном экспорте папка архива остаётся для диагностики.'
}

function Close-MenuOperation {
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

function Invoke-InteractiveMenu {
    # Для просмотра состояния и подготовки приёмника USMT не нужен.
    $usmt = Get-UsmtPath
    $actions = @{
        1 = 'ЭКСПОРТ'
        2 = 'ИМПОРТ'
        3 = 'ПРОВЕРКА АРХИВА'
        5 = 'ПРЯМОЙ ПЕРЕНОС'
        6 = 'ПОДГОТОВКА СЕТИ'
        7 = 'ВОЗОБНОВЛЕНИЕ ПЕРЕНОСА'
    }
    while ($true) {
        $number = Read-MainMenuChoice
        if ($number -eq 0) { return }
        if ($number -eq 4) {
            Show-RecoveryMenu
            Pause-Menu
            continue
        }
        $action = $actions[$number]
        try {
            Start-OperationReport $action
            Write-OperationReport 'НАЧАТО' ('Действие: ' + $action)
            if ($number -ne 6 -and -not $usmt) {
                Advance-OperationStage 'Поиск установленного USMT' -Starting
                $usmt = Require-USMT
                if (-not $usmt) {
                    Write-OperationReport 'ПРОВЕРКА' 'USMT не готов. Миграция не запускалась.'
                    continue
                }
            }
            if ($number -ne 6) { Write-OperationReport 'USMT' ('Каталог USMT: ' + $usmt) }
            Invoke-MenuAction $number $usmt
        } catch [System.OperationCanceledException] {
            Write-CanceledOperation $_ $action
        } catch {
            Write-FailedOperation $_ $action
        } finally {
            Close-MenuOperation
        }
        Pause-Menu
    }
}
