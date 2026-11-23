# Здесь программа записывает ход операции и показывает, где искать причину сбоя.

# Создаёт уникальный итоговый TXT-отчёт без перезаписи предыдущих результатов.
function Start-OperationReport([string]$Operation) {
    if ($Script:ReportPath) { throw 'Предыдущий отчёт не завершён.' }
    $protectedReports = Join-Path $Script:WpmWorkRoot 'Reports'
    $rootOptions = @((Join-Path $Script:ToolRoot 'Reports'),$protectedReports)
    $stem = 'Итог_работы_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
    $lastError = $null
    foreach ($root in $rootOptions) {
        try {
            if ($root -eq $protectedReports) { Initialize-WpmWorkDirectory $root }
            else { [void](New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop) }
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
                        '; Windows=' + [Environment]::OSVersion.Version + '; архитектура процесса=' + $env:PROCESSOR_ARCHITECTURE +
                        '; PID=' + $PID + '; 64-битный процесс=' + [Environment]::Is64BitProcess +
                        '; часовой пояс=' + [TimeZoneInfo]::Local.Id)
                    Write-OperationReport 'ДИАГНОСТИКА' ('Идентификатор отчёта: ' + [IO.Path]::GetFileNameWithoutExtension($filename))
                    if ($root -eq $protectedReports -and $lastError) {
                        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Основную папку отчётов открыть не удалось: ' + $lastError.Message)
                    }
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
    # Исключение или внешний журнал не должны превращаться в поддельные строки отчёта.
    $messageLine = $Message -replace '[\x00-\x1F\x7F]', ' '
    $line = '[{0}] [{1}] [Этап: {2}] {3}' -f (Get-Date -Format 'HH:mm:ss.fff'),$Category,$Script:ReportPhase,$messageLine
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
    foreach ($progressId in 0..15) {
        Write-Progress -Id $progressId -Activity 'Выполнение операции' -Completed
    }
    Write-Host ('Один итоговый отчёт по операции: ' + $completed) -ForegroundColor Cyan
}

# Отмечаем начало до долгой операции, чтобы после сбоя было видно, где она остановилась.
# Общий процент считаем по заданным контрольным шагам, а не по прошедшему времени.
function Advance-OperationStage([string]$Stage, [switch]$Starting, [string]$MilestoneActivity = '',
    [int]$Milestone = 0, [int]$TotalMilestones = 0) {
    if (-not $Script:ReportPath) { return }
    if ($Script:ReportPhaseStart) {
        $seconds = [Math]::Round(((Get-Date) - $Script:ReportPhaseStart).TotalSeconds,1)
        Write-OperationReport 'ВРЕМЯ ЭТАПА' ($Script:ReportPhase + ': ' + $seconds + ' с')
    }
    $Script:ReportPhase = $Stage
    $Script:ReportPhaseStart = Get-Date
    if ($Starting) {
        Write-Progress -Id 0 -Activity 'Текущее действие' -Status $Stage -PercentComplete -1
        Write-OperationReport 'ЭТАП НАЧАТ' $Stage
    } else {
        $Script:ProgressStep++
        Write-Progress -Id 0 -Activity 'Текущее действие' -Status $Stage -PercentComplete -1
        Write-OperationReport 'ЭТАП' ($Stage + '; выполнено этапов: ' + $Script:ProgressStep)
    }
    if ($TotalMilestones -gt 0) {
        $percent = [int][Math]::Floor(100.0 * $Milestone / $TotalMilestones)
        $status = '{0}% по шагам ({1}/{2}) · {3}' -f $percent,$Milestone,$TotalMilestones,$Stage
        Write-Progress -Id 7 -Activity $MilestoneActivity -Status $status -PercentComplete $percent
        Write-OperationReport 'ХОД ОПЕРАЦИИ' ($MilestoneActivity + ' · ' + $status)
    }
}

# Добавляет в тот же отчёт причину сбоя, тип исключения и точку в скрипте.
# Пароли, содержимое профиля и параметры командной строки не собираются.
function Write-DiagnosticFailure([object]$ErrorRecord,[string]$Context) {
    if (-not $ErrorRecord) { return }
    try {
        $ex = $ErrorRecord.Exception
        Write-OperationReport 'ДИАГНОСТИКА' ('Контекст: ' + $Context + '; тип: ' + $ex.GetType().FullName + '; причина: ' + $ex.Message)
        $cause = $ex.GetBaseException()
        Write-OperationReport 'ДИАГНОСТИКА' ('HRESULT: 0x{0:X8}' -f $ex.HResult)
        if ($cause -ne $ex) {
            Write-OperationReport 'ДИАГНОСТИКА' ('Первопричина: {0}, HRESULT 0x{1:X8}. {2}' -f $cause.GetType().FullName,$cause.HResult,$cause.Message)
        }
        if ($cause -is [ComponentModel.Win32Exception]) {
            Write-OperationReport 'ДИАГНОСТИКА' ('Код Windows: ' + $cause.NativeErrorCode)
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
