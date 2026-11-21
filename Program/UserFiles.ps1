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

# Доверяем только подкаталогам этого профиля. Запись в реестре пользователя не даёт программе права читать чужие файлы.
function Resolve-PersonalFolder([string]$Group, [string]$ProfileRoot, [hashtable]$Settings) {
    $default = Join-Path $ProfileRoot $Group
    $value = [string]$Settings[$Group]
    if (-not $value) { return $default }
    foreach ($name in @('OneDrive','OneDriveConsumer','OneDriveCommercial','USERPROFILE')) {
        $replacement = if ($name -eq 'USERPROFILE') { $ProfileRoot } else { [string]$Settings[$name] }
        if ($replacement -and $value.StartsWith("%$name%\", [StringComparison]::OrdinalIgnoreCase)) {
            $value = $replacement.TrimEnd('\') + $value.Substring($name.Length + 2)
        }
    }
    $prefix = [IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\') + '\'
    if ($value.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        $parts = @(Get-WindowsRelativePathParts $value.Substring($prefix.Length))
        if ($parts[0] -notin @('AppData','Application Data','Start Menu')) {
            return Join-Path $ProfileRoot ($parts -join '\')
        }
    }
    Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ("Для $Group задан путь вне доступных папок профиля. Используется локальная папка $default.")
    return $default
}

function Get-PersonalFolders([string]$Sid, [string]$ProfileRoot, [bool]$IncludeDocuments) {
    Assert-NoReparseAncestor $ProfileRoot
    $settings = Get-PersonalFolderSettings $Sid $ProfileRoot
    $groups = @('Desktop')
    if ($IncludeDocuments) { $groups += @('Documents','Downloads') }
    $folders = [ordered]@{}
    foreach ($group in $groups) { $folders[$group] = Resolve-PersonalFolder $group $ProfileRoot $settings }
    return $folders
}

# Не открываем ссылки, точки подключения и файлы, содержимое которых Windows должна сначала загрузить из облака.
function Test-PersonalFileLocal([IO.FileSystemInfo]$Item) {
    $notLocal = [int][IO.FileAttributes]::ReparsePoint -bor [int][IO.FileAttributes]::Offline -bor 0x40000 -bor 0x400000
    return ([int]$Item.Attributes -band $notLocal) -eq 0
}

function Get-PersonalSourceFiles([string]$Folder, [string]$ProfileRoot, [bool]$ShortcutsOnly) {
    Assert-ProfileExtraPath $Folder $ProfileRoot $true
    if (-not [IO.Directory]::Exists($Folder)) { return }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Folder)
    while ($pending.Count) {
        $current = $pending.Pop()
        Assert-ProfileExtraPath $current $ProfileRoot
        foreach ($item in (Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (-not (Test-PersonalFileLocal $item)) {
                Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Пропущена ссылка или облачный объект: ' + $item.FullName)
                continue
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            elseif (-not $ShortcutsOnly -or (Test-DesktopShortcut $item.Name)) { $item }
        }
    }
}

function Export-PersonalFiles($Profile, [string]$Archive, [bool]$IncludeDocuments, $Folders) {
    $counts = @{ Desktop = 0L; Documents = 0L; Downloads = 0L }
    foreach ($group in $Folders.Keys) {
        $folder = $Folders[$group]
        $prefix = $folder.TrimEnd('\') + '\'
        $store = Join-Path $Archive ("Extras\UserFiles\$group")
        foreach ($file in (Get-PersonalSourceFiles $folder $Profile.Path ($group -eq 'Desktop'))) {
            $relative = $file.FullName.Substring($prefix.Length)
            $destination = Join-Path $store $relative
            if (-not (Copy-RequiredFile $file.FullName $destination $Profile.Path $Archive)) {
                throw ('Во время экспорта исчез файл: ' + $file.FullName)
            }
            $counts[$group]++
        }
    }
    Write-OperationReport 'ФАЙЛЫ' ("Сохранено ярлыков: {0}, документов: {1}, загрузок: {2}." -f $counts.Desktop,$counts.Documents,$counts.Downloads)
    return [ordered]@{ Version=1; SourceSid=$Profile.SID; IncludeDocuments=$IncludeDocuments; Counts=$counts }
}

# Старые архивы не содержат этого раздела. Для новых сверяем группы, SID и число подтверждённых SHA-256.
function Assert-PersonalFilesInventory($Metadata, [hashtable]$Approved) {
    if (-not $Metadata.PSObject.Properties['PersonalFiles']) { return }
    $info = $Metadata.PersonalFiles
    if ($info.Version -ne 1 -or $info.SourceSid -ne $Metadata.SourceSid -or $info.IncludeDocuments -isnot [bool]) {
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
}

# Если USMT уже восстановил тот же файл, используем его. Другой файл с тем же именем сохраняем рядом с оригиналом.
function Get-PersonalDestination([string]$Path, [string]$Root, [string]$Hash) {
    $candidate = $Path
    $attempt = 0
    while ($true) {
        Assert-ProfileExtraPath $candidate $Root $true
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -and (Test-PersonalFileLocal $item) -and (Get-ExactFileSha256 $candidate) -eq $Hash) { return }
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

function Restore-PersonalFiles([string]$Archive, $Target, $Metadata, [hashtable]$Approved) {
    if (-not $Metadata.PSObject.Properties['PersonalFiles']) { return }
    $folders = Get-PersonalFolders $Target.Sid $Target.Path $Metadata.PersonalFiles.IncludeDocuments
    $extras = Join-Path $Archive 'Extras'
    foreach ($key in $Approved.Keys) {
        if (-not $key.StartsWith('UserFiles\',[StringComparison]::OrdinalIgnoreCase)) { continue }
        $parts = $key -split '\\',3
        $desired = Join-Path $folders[$parts[1]] $parts[2]
        $destination = Get-PersonalDestination $desired $Target.Path $Approved[$key]
        if (-not $destination) { continue }
        $source = Join-Path $extras $key
        if (-not (Copy-RequiredFile $source $destination $Archive $Target.Path '' $Approved[$key])) {
            throw ('В архиве отсутствует личный файл: ' + $key)
        }
        if ($destination -ine $desired) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Файл с таким именем уже был. Копия из архива: ' + $destination) }
    }
    Write-OperationReport 'ФАЙЛЫ' 'Копирование документов, загрузок и ярлыков по выбранному составу завершено.'
}

# Оцениваем размер дополнительных копий до выбора места для архива.
function Measure-PersonalFiles($Folders, [string]$ProfileRoot) {
    [UInt64]$bytes = 0
    foreach ($group in $Folders.Keys) {
        Get-PersonalSourceFiles $Folders[$group] $ProfileRoot ($group -eq 'Desktop') | ForEach-Object {
            $bytes += [UInt64]$_.Length
        }
    }
    return $bytes
}
