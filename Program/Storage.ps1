# Подготовка места, копирование и проверка хранилища USMT.

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
    $base = $Script:WpmStagingRoot
    Initialize-WpmWorkDirectory $base
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
