# Ярлык переносим как обычный файл. Например, для .lnk не нужно подключаться к диску, на который он указывает.

function Read-PersonalFilesChoice {
    Write-Host 'Сделать в архиве дополнительную копию документов и загрузок?'
    Write-Host '1. Включить все локальные файлы из обеих папок'
    Write-Host '2. Оставить штатный перенос USMT'
    Write-Host '0. Отменить экспорт'
    Write-Host 'Ярлыки с рабочего стола будут сохранены в обоих вариантах.'
    $choice = Choice 'Выберите действие' 2
    if ($choice -eq 0) { throw [OperationCanceledException]::new('Выбор состава архива отменён.') }
    return $choice -eq 1
}

function Test-DesktopShortcut([string]$Name) {
    return [IO.Path]::GetExtension($Name) -in @('.lnk', '.url', '.rdp', '.website')
}

# Читаем папки владельца профиля. Переменные администратора запуска здесь дали бы чужие пути.
function Get-PersonalFolderSettings([string]$Sid, [string]$ProfileRoot) {
    return Invoke-ProfileHive $Sid $ProfileRoot {
        param($users, $mount)
        $result = @{}
        $raw = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        $shell = $users.OpenSubKey("$mount\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
        try {
            if ($shell) {
                $result.Desktop = $shell.GetValue('Desktop', $null, $raw)
                $result.Documents = $shell.GetValue('Personal', $null, $raw)
                $result.Downloads = $shell.GetValue('{374DE290-123F-4565-9164-39C4925E467B}', $null, $raw)
            }
        } finally { if ($shell) { $shell.Dispose() } }

        $environment = $users.OpenSubKey("$mount\Environment")
        try {
            if ($environment) {
                foreach ($name in @('OneDrive','OneDriveConsumer','OneDriveCommercial')) {
                    $result[$name] = $environment.GetValue($name, $null, $raw)
                }
            }
        } finally { if ($environment) { $environment.Dispose() } }
        return $result
    }
}

# Для папки вне профиля запись реестра сама по себе не подтверждает право доступа.
# Принимаем только отдельный существующий каталог, владельцем которого является выбранный пользователь.
function Get-OwnedRedirectedFolder([string]$Path, [string]$Sid) {
    if ($Path -notmatch '^[a-zA-Z]:\\' -and -not (Test-NetworkDriveRemotePath $Path)) {
        throw 'Нужен полный путь к папке на диске или сетевом ресурсе.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -eq [IO.Path]::GetPathRoot($Path).TrimEnd('\')) {
        throw 'Корень диска или сетевого ресурса не подходит.'
    }
    Assert-NoReparseAncestor $full
    $directory = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $directory.PSIsContainer -or -not (Test-PersonalFileLocal $directory)) {
        throw 'Папка должна быть доступна без перехода по ссылке или загрузки из облака.'
    }
    $acl = Get-Acl -LiteralPath $full -ErrorAction Stop
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $Sid) {
        throw 'Владелец перенаправленной папки отличается от выбранного пользователя.'
    }
    return $full
}

function Resolve-PersonalFolder([string]$Group, [string]$Sid, [string]$ProfileRoot, [hashtable]$Settings) {
    $default = Join-Path $ProfileRoot $Group
    $local = [pscustomobject]@{Path=$default; Root=$ProfileRoot; Redirected=$false; Fallback=$false}
    $value = [string]$Settings[$Group]
    if (-not $value) { return $local }
    foreach ($name in @('OneDrive','OneDriveConsumer','OneDriveCommercial','USERPROFILE')) {
        $replacement = if ($name -eq 'USERPROFILE') { $ProfileRoot } else { [string]$Settings[$name] }
        if ($replacement -and $value.StartsWith("%$name%\", [StringComparison]::OrdinalIgnoreCase)) {
            $value = $replacement.TrimEnd('\') + $value.Substring($name.Length + 2)
        }
    }
    $prefix = [IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\') + '\'
    try {
        if ($value -notmatch '^[a-zA-Z]:\\' -and -not (Test-NetworkDriveRemotePath $value)) {
            throw 'Не удалось определить полный путь перенаправленной папки.'
        }
        $value = [IO.Path]::GetFullPath($value).TrimEnd('\')
        if ($value.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $parts = @(Get-WindowsRelativePathParts $value.Substring($prefix.Length))
            if ($parts[0] -in @('AppData','Application Data','Start Menu')) {
                throw 'Служебная папка не подходит для личных файлов.'
            }
            $local.Path = Join-Path $ProfileRoot ($parts -join '\')
            Assert-ProfileExtraPath $local.Path $ProfileRoot $true
            return $local
        }
        if ($prefix.StartsWith(($value + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Нельзя использовать весь профиль или его родительскую папку.'
        }
        $external = Get-OwnedRedirectedFolder $value $Sid
        return [pscustomobject]@{Path=$external; Root=$external; Redirected=$true; Fallback=$false}
    } catch {
        $message = 'Папка {0} перенаправлена. Используется {1}. Причина: {2}' -f $Group,$default,$_.Exception.Message
        Write-Host $message -ForegroundColor Yellow
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' $message
        $local.Path = $default
        $local.Fallback = $true
        return $local
    }
}

function Get-PersonalFolders([string]$Sid, [string]$ProfileRoot, [bool]$IncludeDocuments) {
    $activity = 'Поиск личных папок'
    Write-Progress -Id 8 -Activity $activity -Status 'Чтение настроек профиля' -PercentComplete -1
    try {
        Assert-NoReparseAncestor $ProfileRoot
        $settings = Get-PersonalFolderSettings $Sid $ProfileRoot
        $groups = @('Desktop')
        if ($IncludeDocuments) { $groups += @('Documents','Downloads') }
        $folders = [ordered]@{}
        foreach ($group in $groups) { $folders[$group] = Resolve-PersonalFolder $group $Sid $ProfileRoot $settings }
        return $folders
    } finally { Write-Progress -Id 8 -Activity $activity -Completed }
}

# Не открываем ссылки, точки подключения и файлы, содержимое которых Windows должна сначала загрузить из облака.
function Test-PersonalFileLocal([IO.FileSystemInfo]$Item) {
    $notLocal = [int][IO.FileAttributes]::ReparsePoint -bor [int][IO.FileAttributes]::Offline -bor 0x40000 -bor 0x400000
    return ([int]$Item.Attributes -band $notLocal) -eq 0
}

function Get-PersonalSourceFiles([string]$Folder, [string]$ProfileRoot, [bool]$ShortcutsOnly, [hashtable]$Outcome) {
    if ($Folder -ieq $ProfileRoot) { Assert-NoReparseAncestor $Folder }
    else { Assert-ProfileExtraPath $Folder $ProfileRoot $true }
    try { $directory = Get-Item -LiteralPath $Folder -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] {
        if ($Outcome) { $Outcome.Missing = $true }
        return
    }
    if (-not $directory.PSIsContainer -or -not (Test-PersonalFileLocal $directory)) {
        throw 'Папка личных файлов недоступна для локального чтения.'
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Folder)
    while ($pending.Count) {
        $current = $pending.Pop()
        if ($current -ieq $ProfileRoot) { Assert-NoReparseAncestor $current }
        else { Assert-ProfileExtraPath $current $ProfileRoot }
        foreach ($item in (Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if ($ShortcutsOnly -and -not $item.PSIsContainer -and -not (Test-DesktopShortcut $item.Name)) { continue }
            if (-not (Test-PersonalFileLocal $item)) {
                if ($Outcome) {
                    $Outcome.Skipped++
                    if ($Outcome.Skipped -le 5) {
                        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Пропущена ссылка или облачный объект: ' + $item.Name + '. Для переноса нужна локальная копия.')
                    }
                }
                continue
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            else { $item }
        }
    }
}

function Export-PersonalFiles($Profile, [string]$Archive, [bool]$IncludeDocuments, $Folders) {
    Write-Host 'Копирование личных файлов. Для отмены нажмите 0 без Enter.'
    $counts = @{ Desktop = 0L; Documents = 0L; Downloads = 0L }
    $results = [ordered]@{}
    $activity = 'Сохранение личных файлов'
    $processed = 0
    $total = $Folders.Count
    Write-OperationReport 'ФАЙЛЫ' ('Начато копирование личных файлов. Групп: ' + $total)
    try {
        foreach ($group in $Folders.Keys) {
            $percent = [int][Math]::Floor(100.0 * $processed / $total)
            Write-Progress -Id 8 -Activity $activity -Status ("Групп обработано: {0} из {1}. Сейчас: {2}" -f $processed,$total,$group) -PercentComplete $percent
            $folder = $Folders[$group]
            $result = @{Fallback=[bool]$folder.Fallback; Missing=$false; ReadFailed=$false; Skipped=0L}
            $results[$group] = $result
            $prefix = $folder.Path.TrimEnd('\') + '\'
            $store = Join-Path $Archive ("Extras\UserFiles\$group")
            try {
                if ($folder.Redirected) { [void](Get-OwnedRedirectedFolder $folder.Path $Profile.SID) }
                Get-PersonalSourceFiles $folder.Path $folder.Root ($group -eq 'Desktop') $result | ForEach-Object {
                    $file = $_
                    $destination = Join-Path $store $file.FullName.Substring($prefix.Length)
                    try {
                        if (-not (Copy-RequiredFile $file.FullName $destination $folder.Root $Archive -AllowCancel)) {
                            throw 'Файл исчез во время экспорта.'
                        }
                        $counts[$group]++
                    } catch [OperationCanceledException] { throw }
                    catch {
                        $result.Skipped++
                        if ($result.Skipped -le 5) {
                            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось сохранить файл из группы ' + $group + '. ' + $_.Exception.Message)
                        }
                    }
                }
            } catch [OperationCanceledException] { throw }
            catch {
                $result.ReadFailed = $true
                Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось полностью прочитать группу ' + $group + '. Проверьте доступ к папке. ' + $_.Exception.Message)
            }
            $processed++
        }
        if ($total) {
            Write-Progress -Id 8 -Activity $activity -Status ("Групп обработано: {0} из {1}" -f $processed,$total) -PercentComplete 100
        }
    } finally {
        Write-Progress -Id 8 -Activity $activity -Completed
        Write-OperationReport 'ФАЙЛЫ' ("Обработано групп: {0} из {1}. Сохранено ярлыков: {2}, документов: {3}, загрузок: {4}." -f $processed,$total,$counts.Desktop,$counts.Documents,$counts.Downloads)
    }
    $inventory = [ordered]@{Version=2; SourceSid=$Profile.SID; IncludeDocuments=$IncludeDocuments; Counts=$counts; Folders=$results}
    [void](Write-PersonalFilesCoverage $inventory)
    return $inventory
}

# Старые архивы не содержат этого раздела. Для новых сверяем группы, SID и число подтверждённых SHA-256.
function Assert-PersonalFilesInventory($Metadata, [hashtable]$Approved) {
    if (-not $Metadata.PSObject.Properties['PersonalFiles']) { return }
    $info = $Metadata.PersonalFiles
    if ($info.Version -notin @(1, 2) -or $info.SourceSid -ne $Metadata.SourceSid -or $info.IncludeDocuments -isnot [bool]) {
        throw 'Некорректные сведения о личных файлах в архиве.'
    }
    $counts = @{ Desktop = 0L; Documents = 0L; Downloads = 0L }
    foreach ($key in $Approved.Keys) {
        if (-not $key.StartsWith('UserFiles\',[StringComparison]::OrdinalIgnoreCase)) { continue }
        $parts = @(Get-WindowsRelativePathParts $key)
        if ($parts.Count -lt 3 -or -not $counts.ContainsKey($parts[1])) { throw 'Неизвестная папка личных файлов.' }
        if ($parts[1] -eq 'Desktop' -and -not (Test-DesktopShortcut $parts[-1])) { throw 'В списке ярлыков найден посторонний файл.' }
        if ($parts[1] -ne 'Desktop' -and -not $info.IncludeDocuments) { throw 'Состав личных файлов отличается от выбранного при экспорте.' }
        $counts[$parts[1]]++
    }
    foreach ($group in $counts.Keys) {
        $expected = $info.Counts.PSObject.Properties[$group]
        if (-not $expected -or ($expected.Value -isnot [int] -and $expected.Value -isnot [long]) -or
            $counts[$group] -ne $expected.Value) { throw ("Не все файлы группы $group прошли проверку SHA-256.") }
    }
    if ($info.Version -eq 2) {
        $groups = @('Desktop')
        if ($info.IncludeDocuments) { $groups += @('Documents','Downloads') }
        if ($info.Folders -isnot [pscustomobject] -or @($info.Folders.PSObject.Properties).Count -ne $groups.Count) {
            throw 'Некорректный список папок личных файлов.'
        }
        foreach ($group in $groups) {
            $entry = $info.Folders.PSObject.Properties[$group]
            if (-not $entry -or $entry.Value -isnot [pscustomobject]) { throw 'Не найден результат экспорта личной папки.' }
            foreach ($flag in @('Fallback','Missing','ReadFailed')) {
                $property = $entry.Value.PSObject.Properties[$flag]
                if (-not $property -or $property.Value -isnot [bool]) { throw 'Некорректный результат экспорта личной папки.' }
            }
            $skipped = $entry.Value.PSObject.Properties['Skipped']
            if (-not $skipped -or ($skipped.Value -isnot [int] -and $skipped.Value -isnot [long]) -or $skipped.Value -lt 0) {
                throw 'Некорректное число пропущенных объектов.'
            }
        }
    }
}

# Сведения об охвате экспорта остаются в архиве даже при нулевом числе файлов.
function Write-PersonalFilesCoverage($Inventory) {
    if ($Inventory.Version -ne 2) { return $true }
    $names = @{Desktop='Ярлыки рабочего стола'; Documents='Документы'; Downloads='Загрузки'}
    $complete = $true
    foreach ($group in @('Desktop','Documents','Downloads')) {
        if ($Inventory.Folders -is [System.Collections.IDictionary]) { $result = $Inventory.Folders[$group] }
        else {
            $entry = $Inventory.Folders.PSObject.Properties[$group]
            $result = if ($entry) { $entry.Value }
        }
        if (-not $result) { continue }
        $problems = @()
        if ($result.Fallback) { $problems += 'не удалось прочитать настроенную папку, использована локальная' }
        if ($result.ReadFailed) { $problems += 'чтение папки завершилось ошибкой' }
        if ($result.Skipped -gt 0) { $problems += ('пропущено объектов: ' + $result.Skipped) }
        if ($result.Missing) {
            Write-OperationReport 'ФАЙЛЫ' ($names[$group] + ' — папка отсутствовала на исходном ПК.')
        }
        if ($problems.Count) {
            $complete = $false
            $message = $names[$group] + ' при экспорте — ' + ($problems -join ', ') + '.'
            Write-Host $message -ForegroundColor Yellow
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' $message
        }
    }
    return $complete
}

function Measure-ArchivedPersonalFiles([string]$Archive, [hashtable]$Approved) {
    [UInt64]$bytes = 0
    foreach ($key in $Approved.Keys) {
        if ($key.StartsWith('UserFiles\',[StringComparison]::OrdinalIgnoreCase)) {
            $bytes += [UInt64](Get-Item -LiteralPath (Join-Path $Archive ("Extras\" + $key)) -Force -ErrorAction Stop).Length
        }
    }
    return $bytes
}

# Проверяем ближайшую существующую папку, чтобы учесть сетевой ресурс и его квоту.
function Assert-PersonalDestinationSpace([string]$Destination, [UInt64]$Bytes) {
    $parent = [IO.Path]::GetDirectoryName($Destination)
    while ($parent -and -not [IO.Directory]::Exists($parent)) {
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
    if (-not $parent) { throw 'Не удалось определить папку назначения для проверки свободного места.' }
    if ((Get-PathFreeBytes $parent) -lt $Bytes) {
        throw ('Недостаточно места для личного файла в ' + $parent + '. Нужно ' + (Format-ByteSize $Bytes) + '.')
    }
}

# Если USMT уже восстановил тот же файл, используем его. Другой файл с тем же именем сохраняем рядом с оригиналом.
function Get-PersonalDestination([string]$Path, [string]$Root, [string]$Hash) {
    $candidate = $Path
    $attempt = 0
    while ($true) {
        Assert-ProfileExtraPath $candidate $Root $true
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -and (Test-PersonalFileLocal $item) -and (Get-ExtraFileSha256 $candidate 'сверку существующего личного файла') -eq $Hash) { return }
        $attempt++
        $extension = [IO.Path]::GetExtension($Path)
        $suffix = ' (перенос-' + $Hash.Substring(0,8) + '-' + $attempt + ')'
        $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
        $keep = 255 - $suffix.Length - $extension.Length
        if ($keep -lt 1) {
            # Не сокращаем длинное расширение: отдельный каталог сохраняет исходное имя файла.
            $parent = Join-Path ([IO.Path]::GetDirectoryName($Path)) $suffix.Trim()
            $candidate = Join-Path $parent ([IO.Path]::GetFileName($Path))
        } else {
            $name = $stem.Substring(0,[Math]::Min($stem.Length,$keep)) + $suffix + $extension
            $candidate = Join-Path ([IO.Path]::GetDirectoryName($Path)) $name
        }
    }
}

# Ошибка одного файла не прерывает остальные. При повторе файлы с тем же SHA-256 пропускаются.
function Restore-PersonalFiles([string]$Archive, $Target, $Metadata, [hashtable]$Approved) {
    if (-not $Metadata.PSObject.Properties['PersonalFiles']) { return $true }
    $keys = @($Approved.Keys | Where-Object { $_.StartsWith('UserFiles\',[StringComparison]::OrdinalIgnoreCase) } | Sort-Object)
    if (-not $keys.Count) { return $true }
    Write-OperationReport 'ФАЙЛЫ' ('Начато восстановление личных файлов. Файлов в проверенном архиве: ' + $keys.Count)
    if ($Target.Loaded) {
        $message = 'Выйдите из целевой учётной записи Windows и повторите восстановление личных файлов.'
        Write-Host $message -ForegroundColor Yellow
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' $message
        return $false
    }
    Write-Host 'Восстановление личных файлов. Для отмены нажмите 0 без Enter.'
    $restored = 0
    $matched = 0
    $fallback = 0
    try {
        $folders = Get-PersonalFolders $Target.Sid $Target.Path $Metadata.PersonalFiles.IncludeDocuments
    } catch {
        Write-Host ('Личные файлы пока не восстановлены: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось определить папки личных файлов: ' + $_.Exception.Message)
        return $false
    }
    $extras = Join-Path $Archive 'Extras'
    $activity = 'Восстановление личных файлов'
    $processed = 0
    $failed = 0
    $conflicts = 0
    $lastPercent = -1
    try {
        foreach ($key in $keys) {
            $percent = [int][Math]::Floor(100.0 * $processed / $keys.Count)
            if ($percent -ne $lastPercent) {
                Write-Progress -Id 8 -Activity $activity -Status ("Файлов обработано: {0} из {1}" -f $processed,$keys.Count) -PercentComplete $percent
                $lastPercent = $percent
            }
            try {
                $parts = $key -split '\\',3
                $folder = $folders[$parts[1]]
                if ($folder.Redirected) { [void](Get-OwnedRedirectedFolder $folder.Path $Target.Sid) }
                $desired = Join-Path $folder.Path $parts[2]
                $destination = Get-PersonalDestination $desired $folder.Root $Approved[$key]
                if (-not $destination) {
                    $matched++
                } else {
                    $source = Join-Path $extras $key
                    Assert-PersonalDestinationSpace $destination (Get-Item -LiteralPath $source -Force -ErrorAction Stop).Length
                    if (-not (Copy-RequiredFile $source $destination $Archive $folder.Root '' $Approved[$key] -AllowCancel)) {
                        throw 'Файл исчез из рабочей копии архива.'
                    }
                    $restored++
                    if ($destination -ine $desired) {
                        $conflicts++
                        if ($conflicts -le 5) {
                            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Имя занято. Копия из архива: ' + $destination)
                        }
                    }
                }
                if ($folder.Fallback) { $fallback++ }
            } catch [OperationCanceledException] {
                Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Копирование личных файлов остановлено. Готовые копии сохранены. Для оставшихся файлов воспользуйтесь повтором восстановления.'
                break
            } catch {
                $failed++
                if ($failed -le 5) {
                    Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Личный файл ' + $key + ': ' + $_.Exception.Message)
                }
            }
            $processed++
        }
        if ($processed -eq $keys.Count) {
            Write-Progress -Id 8 -Activity $activity -Status ("Файлов обработано: {0} из {1}" -f $processed,$keys.Count) -PercentComplete 100
        }
    } finally { Write-Progress -Id 8 -Activity $activity -Completed }
    $remaining = $keys.Count - $restored - $matched
    Write-OperationReport 'ФАЙЛЫ' ('Личные файлы: скопировано {0}, уже совпали {1}, ошибок {2}, осталось {3}, сохранено под другим именем {4}.' -f $restored,$matched,$failed,$remaining,$conflicts)
    if ($fallback) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Файлов в резервных локальных папках: ' + $fallback + '. Повтор доступен после подключения перенаправленной папки.')
    }
    return $remaining -eq 0 -and $fallback -eq 0
}

# Оцениваем размер дополнительных копий до выбора места для архива.
function Measure-PersonalFiles($Folders) {
    [UInt64]$bytes = 0
    $activity = 'Оценка объёма личных файлов'
    $processed = 0
    $total = $Folders.Count
    Write-OperationReport 'ФАЙЛЫ' ('Начата оценка объёма. Групп: ' + $total)
    try {
        foreach ($group in $Folders.Keys) {
            $folder = $Folders[$group]
            $percent = [int][Math]::Floor(100.0 * $processed / $total)
            Write-Progress -Id 8 -Activity $activity -Status ("Групп просмотрено: {0} из {1}. Сейчас: {2}" -f $processed,$total,$group) -PercentComplete $percent
            try {
                Get-PersonalSourceFiles $folder.Path $folder.Root ($group -eq 'Desktop') | ForEach-Object {
                    $bytes += [UInt64]$_.Length
                }
            } catch {
                Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Оценка объёма группы ' + $group + ' неполная. Проверьте доступ к папке. ' + $_.Exception.Message)
            }
            $processed++
        }
        if ($total) {
            Write-Progress -Id 8 -Activity $activity -Status ("Групп просмотрено: {0} из {1}" -f $processed,$total) -PercentComplete 100
        }
    } finally { Write-Progress -Id 8 -Activity $activity -Completed }
    Write-OperationReport 'ФАЙЛЫ' ('Оценка объёма личных файлов: ' + (Format-ByteSize $bytes))
    return $bytes
}
