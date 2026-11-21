#Requires -Version 5.1
# Автор: Arhivater
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Script:WpmVersion = '1.11.0'
# Program лежит рядом с папками для отчётов и архивов. Корень диска тоже допустим.
$Script:KitRoot = [IO.Directory]::GetParent($PSScriptRoot).FullName

# Если меню не открылось, этот отчёт подскажет, на каком шаге остановился запуск.
function Get-BootstrapFailureText([object]$Record) {
    return (@(
        ('WINDOWS PROFILE MIGRATION {0} - ОШИБКА ЗАПУСКА' -f $Script:WpmVersion),
        ('Время: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')),
        ('Компьютер: ' + $env:COMPUTERNAME),
        'Этап: Bootstrap / UAC',
        ('Тип: ' + $Record.Exception.GetType().FullName),
        ('Причина: ' + $Record.Exception.Message),
        ('Стек: ' + [string]$Record.ScriptStackTrace)
    ) -join [Environment]::NewLine)
}

function Write-BootstrapFailure([object]$Record) {
    $content = Get-BootstrapFailureText $Record
    $paths = @((Join-Path $Script:KitRoot 'Reports'), (Join-Path $env:TEMP 'WindowsProfileMigration\Reports'))
    $name = 'Итог_работы_ЗАПУСК_{0}_{1}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), [guid]::NewGuid().ToString('N').Substring(0,12)
    foreach ($folder in $paths) {
        try {
            [void](New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop)
            $file = Join-Path $folder $name
            [IO.File]::WriteAllText($file, $content, [Text.UTF8Encoding]::new($true))
            Write-Host ('Итоговый отчёт об ошибке запуска: ' + $file) -ForegroundColor Yellow
            return
        } catch { } # Если папка комплекта недоступна для записи, пробуем временную папку.
    }
}

# Буква сетевого диска может исчезнуть после повышения прав. Узнаём имя общей папки заранее.
function Get-NetworkDriveShare([string]$Letter) {
    try {
        $network = New-Object -ComObject WScript.Network
        $drives = $network.EnumNetworkDrives()
        for ($i = 0; $i -lt [int]$drives.Count; $i += 2) {
            $share = [string]$drives.Item($i + 1)
            if (([string]$drives.Item($i)).TrimEnd('\') -ieq $Letter -and $share.StartsWith('\\')) { return $share }
        }
    } catch { }
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $Letter + "'") -ErrorAction Stop
        if ($disk.ProviderName -and ([string]$disk.ProviderName).StartsWith('\\')) { return $disk.ProviderName }
    } catch { }
    try {
        $mapping = Get-SmbMapping -ErrorAction Stop | Where-Object { $_.LocalPath -ieq $Letter -and $_.RemotePath } | Select-Object -First 1
        if ($mapping -and ([string]$mapping.RemotePath).StartsWith('\\')) { return $mapping.RemotePath }
    } catch { }
}

function Resolve-OriginalFolder([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Не определена папка комплекта.' }
    $path = [IO.Path]::GetFullPath($Path)
    # Сохраняем завершающий слеш в корне диска и общей папки.
    if ($path.Length -gt [IO.Path]::GetPathRoot($path).Length) { $path = $path.TrimEnd('\') }
    if ($path -notmatch '^[a-zA-Z]:\\') { return $path }

    $share = Get-NetworkDriveShare $path.Substring(0,2)
    if ($share) { return ($share.TrimEnd('\') + $path.Substring(2)).TrimEnd('\') }
    return $path
}

# После преобразования подключённого диска используем тот же абсолютный путь.
# Это исключает запуск временной копии, созданной до повышения прав.
function Quote-LaunchPath([string]$Path) {
    return ('"' + ($Path -replace '(\\+)$','$1$1') + '"')
}

# Главный процесс получает путь к комплекту. UAC спрашиваем только если консоль ещё не повышена.
function Start-MigrationProcess([string]$Root) {
    $main = Join-Path $Root 'Program\ProfileMigration.ps1'
    if (-not (Test-Path -LiteralPath $main -PathType Leaf)) { throw ('Не найден основной скрипт: ' + $main) }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $launch = @{
        FilePath = Join-Path $PSHOME 'powershell.exe'
        WorkingDirectory = $PSHOME
        ArgumentList = '-NoProfile -ExecutionPolicy Bypass -File {0} -ToolRoot {1}' -f (Quote-LaunchPath $main),(Quote-LaunchPath $Root)
        PassThru = $true
    }
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $launch.NoNewWindow = $true }
    else { $launch.Verb = 'RunAs' }
    return (Start-Process @launch)
}

$exitCode = 1
$process = $null
try {
    $root = Resolve-OriginalFolder $Script:KitRoot
    Write-Host ('Папка комплекта: ' + $root)
    $process = Start-MigrationProcess $root
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
