# Поиск пользователя, его профиля и доступного места на диске.

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
