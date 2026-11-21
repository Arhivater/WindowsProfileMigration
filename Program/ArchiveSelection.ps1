# Ищем архивы и помогаем выбрать нужную копию.

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
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -File -Filter '*.wpm.pgp' -Force -ErrorAction SilentlyContinue)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $list += [pscustomobject]@{Path=$item.FullName; Computer=''; Account=$item.Name; Date=$item.LastWriteTime;
            Type='С паролем'; Schema=$null; Format='OpenPGP'}
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
