# Проверка Windows и запуск инструментов Microsoft для переноса профиля.

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
function Invoke-USMT([string]$File,[string[]]$Options,[string]$WorkingPath,[string]$ProgressPath = '',[switch]$TrackProcess) {
    $argLine = (@($Options | ForEach-Object { Quote-WindowsArgument ([string]$_) }) -join ' ')
    $proc = $null
    $code = $null
    if ($TrackProcess) {
        # Сначала записываем имя. Если PowerShell завершится в момент запуска,
        # меню восстановления проверит это имя, даже когда PID ещё неизвестен.
        Update-TrackedState '' @{UsmtProcessName=[IO.Path]::GetFileNameWithoutExtension($File); UsmtProcessId=0; UsmtProcessStartTicks=0}
    }
    try {
        $proc = Start-Process -FilePath $File -WorkingDirectory $WorkingPath -ArgumentList $argLine -PassThru -NoNewWindow -ErrorAction Stop
        # В Windows PowerShell Start-Process -NoNewWindow может вернуть null
        # в ExitCode после ожидания. Раннее обращение к Handle сохраняет дескриптор.
        [void]$proc.Handle
        if ($TrackProcess -and -not $proc.HasExited) {
            try { $startTicks = $proc.StartTime.ToUniversalTime().Ticks }
            catch [InvalidOperationException] {
                if (-not $proc.HasExited) { throw }
                $startTicks = 0
            }
            if ($startTicks) {
                Update-TrackedState '' @{UsmtProcessId=$proc.Id; UsmtProcessStartTicks=$startTicks}
            }
        }
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
        try {
            if ($TrackProcess -and $proc -and $proc.HasExited) {
                Update-TrackedState '' @{UsmtProcessName=''; UsmtProcessId=0; UsmtProcessStartTicks=0}
            }
        } finally {
            if ($proc) { $proc.Dispose() }
            Write-Progress -Id 1 -Activity 'USMT' -Completed
        }
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
