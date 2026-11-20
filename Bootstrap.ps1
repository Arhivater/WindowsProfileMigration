#Requires -Version 5.1
# Автор: Arhivater
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Script:WpmVersion = '1.10.1'

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
                ('WINDOWS PROFILE MIGRATION {0} - ОШИБКА ЗАПУСКА' -f $Script:WpmVersion),
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
    $path = [IO.Path]::GetFullPath($Path)
    # C:\ и корень SMB-ресурса остаются абсолютными путями.
    if ($path.Length -gt [IO.Path]::GetPathRoot($path).Length) {
        $path = $path.TrimEnd('\')
    }
    if ($path.StartsWith('\\')) { return $path }
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

# После преобразования подключённого диска используем тот же абсолютный путь.
# Это исключает запуск временной копии, созданной до повышения прав.
function Quote-LaunchPath([string]$Path) {
    return ('"' + ($Path -replace '(\\+)$','$1$1') + '"')
}

$exitCode = 1
$process = $null
try {
    $root = Resolve-OriginalFolder $PSScriptRoot
    $main = Join-Path $root 'ProfileMigration.ps1'
    if (-not (Test-Path -LiteralPath $main -PathType Leaf)) {
        throw ('Не найден основной скрипт: ' + $main)
    }
    Write-Host ('Папка комплекта: ' + $root)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $engine = Join-Path $PSHOME 'powershell.exe'
    $launch = @{
        FilePath = $engine
        WorkingDirectory = $PSHOME
        ArgumentList = '-NoProfile -ExecutionPolicy Bypass -File {0} -ToolRoot {1}' -f (Quote-LaunchPath $main),(Quote-LaunchPath $root)
        PassThru = $true
    }
    if ($admin) { $launch.NoNewWindow = $true }
    else { $launch.Verb = 'RunAs' }
    $process = Start-Process @launch
    if ($null -eq $process) { throw 'Не удалось запустить основную программу.' }
    [void]$process.Handle
    $process.WaitForExit()
    $code = $process.ExitCode
    if ($null -eq $code) { throw 'Не удалось получить код завершения основной программы.' }
    $exitCode = [int]$code
} catch {
    Write-BootstrapFailure $_
    $cause = $_.Exception
    while ($cause -and $cause -isnot [ComponentModel.Win32Exception]) { $cause = $cause.InnerException }
    if ($cause -and $cause.NativeErrorCode -eq 1223) {
        Write-Host 'Запрос административных прав отменён.' -ForegroundColor Yellow
        $exitCode = 1223
    } else {
        Write-Host ('ОШИБКА ЗАПУСКА: ' + $_.Exception.Message) -ForegroundColor Red
        $exitCode = 1
    }
} finally {
    if ($process) { $process.Dispose() }
}
exit $exitCode
