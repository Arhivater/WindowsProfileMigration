#Requires -Version 5.1
# Автор: Arhivater
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# При отказе UAC/ошибке запуска оставляем один диагностический TXT.
# В штатном запуске отдельный отчёт не создаётся: его пишет основной скрипт.
function Write-BootstrapFailure([object]$Record) {
    $paths = @((Join-Path $PSScriptRoot 'Reports'),
        (Join-Path $env:TEMP 'WindowsProfileMigration\Reports'))
    foreach ($folder in $paths) {
        try {
            [void](New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop)
            $file = Join-Path $folder ('Итог_работы_ЗАПУСК_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' +
                [guid]::NewGuid().ToString('N').Substring(0,12) + '.txt')
            $content = @(
                'WINDOWS PROFILE MIGRATION 1.10.0 - ОШИБКА ЗАПУСКА',
                ('Время: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')),
                ('Компьютер: ' + $env:COMPUTERNAME),
                ('Этап: Bootstrap / UAC'),
                ('Тип: ' + $Record.Exception.GetType().FullName),
                ('Причина: ' + $Record.Exception.Message),
                ('Стек: ' + [string]$Record.ScriptStackTrace)
            ) -join [Environment]::NewLine
            [IO.File]::WriteAllText($file,$content,[Text.UTF8Encoding]::new($true))
            Write-Host ('Итоговый отчёт об ошибке запуска: ' + $file) -ForegroundColor Yellow
            return
        } catch { }
    }
}

# Папку комплекта определяем по расположению Bootstrap.ps1.
# Путь не передаётся через аргумент CMD: завершающий слеш перед кавычкой
# иногда искажает аргумент и вызывает ошибку GetFullPath.
# Преобразуем букву подключённого сетевого диска в UNC до запроса прав UAC.
function Resolve-OriginalFolder([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Не определена папка комплекта.' }
    # UNC уже абсолютный путь, поэтому GetFullPath для него не требуется.
    if ($Path.StartsWith('\\')) { return $Path.TrimEnd('\') }
    $path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($path -notmatch '^[a-zA-Z]:\\') { return $path }
    $driveLetter = $path.Substring(0,2)
    try {
        $network = New-Object -ComObject WScript.Network
        $mapped = $network.EnumNetworkDrives()
        for ($i=0; $i -lt [int]$mapped.Count; $i+=2) {
            if (([string]$mapped.Item($i)).TrimEnd('\') -ieq $driveLetter) {
                $unc = ([string]$mapped.Item($i+1)).TrimEnd('\') + $path.Substring(2)
                if ($unc.StartsWith('\\')) { return $unc.TrimEnd('\') }
            }
        }
    } catch { }
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $driveLetter + "'") -ErrorAction Stop
        if ($disk.ProviderName -and ([string]$disk.ProviderName).StartsWith('\\')) {
            return (([string]$disk.ProviderName).TrimEnd('\') + $path.Substring(2)).TrimEnd('\')
        }
    } catch { }
    # Дополнительная попытка получить UNC для диска пользователя до UAC.
    # Позволяет использовать любую букву сетевого диска, а не заданную в коде.
    try {
        $mapping = @(Get-SmbMapping -ErrorAction Stop | Where-Object {
            $_.LocalPath -ieq $driveLetter -and $_.RemotePath
        } | Select-Object -First 1)
        if ($mapping.Count -gt 0) {
            return (([string]$mapping[0].RemotePath).TrimEnd('\') + $path.Substring(2)).TrimEnd('\')
        }
    } catch { }
    return $path
}

# Повышенные права могут скрыть сетевой диск: копируем только код во временную локальную папку.
# Архивы и отчёты при этом остаются рядом с исходным Start.cmd.
$stage = $null
$stageRoot = $null
$exitCode = 1
try {
    $root = Resolve-OriginalFolder $PSScriptRoot
    $main = Join-Path $root 'ProfileMigration.ps1'
    if (-not (Test-Path -LiteralPath $main -PathType Leaf)) {
        throw ('Не найден основной скрипт: ' + $main)
    }
    # Never invoke the privileged script through a mapped drive, which UAC may hide.
    # The single PS1 is staged locally and receives the original UNC ToolRoot.
    $stageRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $stage = Join-Path $stageRoot ('WPM_Elevate_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $stage -ErrorAction Stop)
    $copy = Join-Path $stage 'ProfileMigration.ps1'
    Copy-Item -LiteralPath $main -Destination $copy -ErrorAction Stop
    Write-Host ('Папка комплекта: ' + $root)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $args = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ToolRoot "{1}"' -f $copy,$root)
    $launch = @{
        FilePath = "$PSHOME\powershell.exe";
        ArgumentList = $args;
        PassThru = $true;
        Wait = $true
    }
    if (-not $admin) { $launch['Verb'] = 'RunAs' }
    $process = Start-Process @launch
    if ($null -eq $process -or $null -eq $process.ExitCode) {
        throw 'Не удалось получить код завершения основной программы.'
    }
    $exitCode = [int]$process.ExitCode
} catch {
    Write-Host ('ОШИБКА ЗАПУСКА: ' + $_.Exception.Message) -ForegroundColor Red
    Write-BootstrapFailure $_
    $exitCode = 1
} finally {
    # Ошибка очистки TEMP никогда не должна перекрывать итог работы программы.
    # Проверяем точный путь своего каталога, не удаляем родительские папки.
    if ($stage -and $stageRoot) {
        try {
            $safe = [IO.Path]::GetFullPath($stage).TrimEnd('\')
            $parent = [IO.Path]::GetDirectoryName($safe).TrimEnd('\')
            if ($parent -ine $stageRoot -or
                [IO.Path]::GetFileName($safe) -notmatch '^WPM_Elevate_[a-fA-F0-9]{32}$') {
                throw 'Неожиданный путь временного каталога. Удаление запрещено.'
            }
            if ([IO.Directory]::Exists($safe)) {
                [IO.Directory]::Delete($safe,$true)
            }
        } catch {
            Write-Host ('ПРЕДУПРЕЖДЕНИЕ: временную копию кода удалить не удалось: ' + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}
exit $exitCode
