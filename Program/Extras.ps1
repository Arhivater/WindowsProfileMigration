# Сохранение и восстановление дополнительных настроек выбранного пользователя.

# Optional browser/desktop data not guaranteed by USMT's stock XML rules.
# Browser files are deliberately limited to non-credential history/bookmarks/sessions.
# Перечень поддерживаемых браузеров: Chrome, Edge и Яндекс Браузер.
function Browser-Definitions {
    return @(
        [pscustomobject]@{ Name='Google Chrome'; Id='Chrome'; Relative='Google\Chrome\User Data'; Process='chrome.exe' },
        [pscustomobject]@{ Name='Microsoft Edge'; Id='Edge'; Relative='Microsoft\Edge\User Data'; Process='msedge.exe' },
        [pscustomobject]@{ Name='Яндекс Браузер'; Id='Yandex'; Relative='Yandex\YandexBrowser\User Data'; Process='browser.exe' }
    )
}
# Проверяет, запущен ли браузер именно от нужного пользователя.
function Get-OpenTargetBrowsers([string]$Sid) {
    $found = @()
    $names = @(Browser-Definitions | ForEach-Object Process)
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object { $_.Name -in $names })
    } catch {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Нельзя проверить, закрыты ли браузеры: ' + $_.Exception.Message)
        return $names
    }
    foreach ($proc in $processes) {
        try {
            $who = Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid -ErrorAction Stop
            if ($who.ReturnValue -ne 0 -or -not $who.Sid) {
                throw ('GetOwnerSid вернул код ' + $who.ReturnValue)
            }
            if ([string]$who.Sid -eq $Sid) { $found += $proc.Name }
        } catch {
            $found += $proc.Name
            Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не определён владелец процесса ' + $proc.Name + ': ' + $_.Exception.Message)
        }
    }
    return @($found | Sort-Object -Unique)
}

function Test-ExtraPathComponent([string]$Name) {
    return ($Name -and $Name -notmatch '[<>:"|?*\x00-\x1f]|[ .]$|^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)')
}

# Проверка идёт от корня к файлу, чтобы не открывать каталог за junction.
function Assert-ProfileExtraPath([string]$Path,[string]$Root,[bool]$AllowMissing = $false) {
    $rootPath = [IO.Path]::GetFullPath($Root)
    $separator = [IO.Path]::DirectorySeparatorChar
    $prefix = $rootPath.TrimEnd([char[]]@($separator,[IO.Path]::AltDirectorySeparatorChar)) + $separator
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw ('Путь вне разрешённого каталога: ' + $full)
    }
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw ('Недопустимый корень дополнительных файлов: ' + $rootPath)
    }
    $parts = $full.Substring($prefix.Length).Split($separator)
    $current = $rootPath
    foreach ($part in $parts) {
        if (-not (Test-ExtraPathComponent $part)) { throw ('Имя в пути дополнительных файлов недопустимо: ' + $part) }
    }
    for ($i=0; $i -lt $parts.Length; $i++) {
        $current = [IO.Path]::Combine($current,$parts[$i])
        try { $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] {
            if ($AllowMissing) { return }
            throw
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw ('Ссылка в пути дополнительных файлов запрещена: ' + $current)
        }
        if ($i -lt $parts.Length-1 -and -not $item.PSIsContainer) {
            throw ('Компонент пути не является каталогом: ' + $current)
        }
    }
}

function Get-ExtraStreamSha256([IO.Stream]$Stream) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-','')
    } finally {
        $Stream.Position = 0
        $sha.Dispose()
    }
}

# Копируем с открытым источником, чтобы другой процесс не изменил его между
# чтением и проверкой. Ошибка копирования или SHA-256 не публикует файл.
function Copy-RequiredFile(
    [string]$From,
    [string]$To,
    [string]$AllowedSourceRoot = '',
    [string]$AllowedDestinationRoot = '',
    [string]$Backup = '',
    [string]$ExpectedHash = ''
) {
    if ($AllowedSourceRoot) { Assert-ProfileExtraPath $From $AllowedSourceRoot $true }
    if (-not [IO.File]::Exists($From)) { return $false }
    if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $To $AllowedDestinationRoot $true }
    $parent = Split-Path -Parent $To
    [void][IO.Directory]::CreateDirectory($parent)
    if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $To $AllowedDestinationRoot $true }
    $temporary = Join-Path $parent ('.WPM_' + [guid]::NewGuid().ToString('N') + '.tmp')
    $source = [IO.File]::Open($From,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $output = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $source.CopyTo($output)
            $output.Flush($true)
        } finally { $output.Dispose() }
        $sourceHash = Get-ExtraStreamSha256 $source
        if (($ExpectedHash -and $sourceHash -ne $ExpectedHash) -or
            $sourceHash -ne (Get-ExactFileSha256 $temporary)) {
            throw ('SHA-256 скопированного файла отличается: ' + $From)
        }
        if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $To $AllowedDestinationRoot $true }
        if ($Backup -and [IO.File]::Exists($To)) {
            if (-not (Copy-RequiredFile -From $To -To $Backup -AllowedSourceRoot $AllowedDestinationRoot -AllowedDestinationRoot $env:ProgramData)) {
                throw ('Не удалось резервировать целевой файл: ' + $To)
            }
            if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $To $AllowedDestinationRoot }
            if ((Get-ExactFileSha256 $Backup) -ne (Get-ExactFileSha256 $To)) {
                throw ('Целевой файл изменился после резервирования: ' + $To)
            }
            # Замена на том же томе сохраняет существующие права целевого файла.
            [IO.File]::Replace($temporary,$To,[NullString]::Value)
        } else { [IO.File]::Move($temporary,$To) }
        return $true
    } finally {
        $source.Dispose()
        if ([IO.File]::Exists($temporary)) {
            try {
                if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $temporary $AllowedDestinationRoot }
                [IO.File]::Delete($temporary)
            } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалён временный файл: ' + $temporary + '; ' + $_.Exception.Message) }
        }
    }
}

# Создаёт контрольный реестр Extras: путь, размер и SHA-256 каждого файла.
function New-ExtrasManifest([string]$Archive) {
    $extras=Join-Path $Archive 'Extras'
    $valid=Join-Path $Archive 'Validation'
    [void](New-Item -ItemType Directory -Path $valid -Force)
    $path=Join-Path $valid 'extras.jsonl'
    $writer=[IO.StreamWriter]::new($path,$false,[Text.UTF8Encoding]::new($false))
    [long]$count=0; [long]$skipped=0
    try {
        if (Test-Path -LiteralPath $extras -PathType Container) {
            Assert-ProfileExtraPath $extras $Archive
            foreach ($file in @(Get-ChildItem -LiteralPath $extras -Recurse -File -Force -ErrorAction Stop)) {
                $rel = $file.FullName.Substring($extras.Length).TrimStart([char[]]@('\','/')).Replace('/','\')
                try {
                    Assert-ProfileExtraPath $file.FullName $Archive
                    $sha=Get-ExactFileSha256 $file.FullName
                    $writer.WriteLine(([ordered]@{ RelativePath=$rel; Length=[long]$file.Length; SHA256=$sha } | ConvertTo-Json -Compress))
                    $count++
                } catch {
                    if ($rel.StartsWith('UserFiles\',[StringComparison]::OrdinalIgnoreCase)) {
                        throw ('Не удалось проверить сохранённый личный файл: ' + $rel)
                    }
                    $skipped++
                    Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Extras: файл не прошёл хеширование ' + $rel + ': ' + $_.Exception.Message)
                }
            }
        }
    } finally { $writer.Dispose() }
    Write-OperationReport 'ПРОВЕРКА' ('Extras: записано контрольных файлов ' + $count + '; не удалось ' + $skipped)
    return [pscustomobject]@{Path='Validation/extras.jsonl'; Files=$count; Skipped=$skipped}
}
# Повреждённые файлы Extras исключаются из восстановления, но не останавливают USMT.
function Read-ExtraJson([string]$Path,[string]$Root,[string]$ExpectedHash = '') {
    Assert-ProfileExtraPath $Path $Root
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($ExpectedHash -and (Get-ExtraStreamSha256 $stream) -ne $ExpectedHash) {
            throw ('Файл дополнительных настроек изменился после проверки: ' + $Path)
        }
        $reader = [IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
        try { return ($reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop) }
        finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Test-ExtrasManifest([string]$Archive,[object]$Meta) {
    if ([int]$Meta.SchemaVersion -lt 5) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Старый архив: у Extras нет отдельного контроля SHA-256.'
        return $null
    }
    $info = $Meta.ExtrasManifest
    if (-not $info -or $info.Path -ne 'Validation/extras.jsonl') { throw 'Нет корректных метаданных Extras.' }
    $path = Join-Path $Archive 'Validation/extras.jsonl'
    Assert-ProfileExtraPath $path $Archive
    if (-not [IO.File]::Exists($path)) { throw 'Манифест Extras отсутствует.' }
    $approved = @{}
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $root = Join-Path $Archive 'Extras'
    # Закрываем поток и при ошибке разбора или проверки записи.
    $reader = [IO.StreamReader]::new($path,[Text.Encoding]::UTF8,$true)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { continue }
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
            $rel = [string]$entry.RelativePath
            $parts = $rel -split '[/\\]'
            foreach ($part in $parts) {
                if (-not (Test-ExtraPathComponent $part)) { throw 'Недопустимый путь в манифесте Extras.' }
            }
            $key = $parts -join '\'
            if (-not $seen.Add($key)) { throw 'Повторяющийся путь в манифесте Extras.' }
            $hash = [string]$entry.SHA256
            if ($hash -notmatch '^[0-9a-fA-F]{64}$' -or [long]$entry.Length -lt 0) {
                throw 'Некорректный размер или SHA-256 в манифесте Extras.'
            }
            $full = Join-Path $root ($parts -join [IO.Path]::DirectorySeparatorChar)
            $ok = $false
            try {
                # Проверяем и корневой каталог Extras, и путь внутри него.
                Assert-ProfileExtraPath $full $Archive
                $file = Get-Item -LiteralPath $full -Force -ErrorAction Stop
                if (-not $file.PSIsContainer -and $file.Length -eq [long]$entry.Length -and
                    (Get-ExactFileSha256 $full) -eq $hash) { $ok = $true }
            } catch { }
            if ($ok) { $approved[$key] = $hash }
            else { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Extras: файл отсутствует или повреждён, пропускается: ' + $rel) }
        }
    } finally { $reader.Dispose() }
    if ($seen.Count -ne [int]$info.Files) { throw 'Число записей Extras не совпадает с метаданными.' }
    if ([int]$info.Skipped -gt 0) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('При экспорте не удалось вычислить хеши Extras: ' + $info.Skipped)
    }
    Write-OperationReport 'ПРОВЕРКА' ('Extras: проверено ' + $seen.Count + '; совпало ' + $approved.Count)
    return $approved
}
function Is-AllowedExtra([hashtable]$Approved,[string]$Relative) {
    if ($null -eq $Approved) { return $true }
    return $Approved.ContainsKey($Relative.ToLowerInvariant().Replace('/','\'))
}

# Дополнительные пользовательские файлы, которые USMT может не восстановить:
# закрепления быстрого доступа Проводника и список информационных баз 1С.
# Исходные базы данных 1С (вне профиля) здесь не копируются.
function Export-ExplorerAndOneCExtras([object]$Profile,[string]$Archive) {
    $quickAccess = 'AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations\f01b4d95cf55d32a.automaticDestinations-ms'
    $quickSource = Join-Path $Profile.Path $quickAccess
    [int]$saved = 0
    if (Test-Path -LiteralPath $quickSource -PathType Leaf) {
        try {
            $quickDestination = Join-Path $Archive 'Extras\Explorer\QuickAccess.automaticDestinations-ms'
            if (Copy-RequiredFile $quickSource $quickDestination $Profile.Path $Archive) {
                $saved++
                Write-OperationReport 'ПРОВОДНИК' 'Закреплённые папки быстрого доступа: сохранён файл Explorer.'
            }
        } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Закрепления Проводника: ' + $_.Exception.Message) }
    } else { Write-OperationReport 'ПРОВОДНИК' 'Файл закреплений быстрого доступа отсутствует.' }
    $sourceDir = Join-Path $Profile.Path 'AppData\Roaming\1C\1CEStart'
    [int]$oneCSaved = 0
    if (Test-Path -LiteralPath $sourceDir -PathType Container) {
        Assert-ProfileExtraPath $sourceDir $Profile.Path
        foreach ($file in @(Get-ChildItem -LiteralPath $sourceDir -File -Force -ErrorAction Stop | Where-Object {
            $_.Name -match '(?i)^(ibases[^\\/]*\.v8i|1cestart\.cfg)$'
        })) {
            try {
                $dest = Join-Path (Join-Path $Archive 'Extras\OneC') $file.Name
                if (Copy-RequiredFile $file.FullName $dest $Profile.Path $Archive) {
                    $oneCSaved++; $saved++
                    Write-OperationReport '1С' ('Сохранён файл списка баз/настроек запуска: ' + $file.Name + '; размер ' + (Format-ByteSize ([UInt64]$file.Length)))
                }
            } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('1С: файл ' + $file.Name + ': ' + $_.Exception.Message) }
        }
    }
    Write-OperationReport '1С' ('Сохранено файлов списка информационных баз: ' + $oneCSaved)
    return $saved
}

# Восстанавливает только файлы, прошедшие SHA-256-манифест Extras.
# Старые целевые файлы резервируются до замены; ошибки модулей не отменяют USMT.
function Restore-ExplorerAndOneCExtras([string]$Archive,[string]$TargetPath,[hashtable]$ApprovedExtras) {
    $jobs = @()
    $sourceQuick = Join-Path $Archive 'Extras\Explorer\QuickAccess.automaticDestinations-ms'
    if (Test-Path -LiteralPath $sourceQuick -PathType Leaf) {
        $jobs += [pscustomobject]@{ Source=$sourceQuick; Key='Explorer\QuickAccess.automaticDestinations-ms';
            Destination=(Join-Path $TargetPath 'AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations\f01b4d95cf55d32a.automaticDestinations-ms'); Name='Быстрый доступ Проводника' }
    }
    $oneCFolder = Join-Path $Archive 'Extras\OneC'
    if (Test-Path -LiteralPath $oneCFolder -PathType Container) {
        Assert-ProfileExtraPath $oneCFolder $Archive
        foreach ($file in @(Get-ChildItem -LiteralPath $oneCFolder -File -Force -ErrorAction Stop | Where-Object {
            $_.Name -match '(?i)^(ibases[^\\/]*\.v8i|1cestart\.cfg)$'
        })) {
            $jobs += [pscustomobject]@{ Source=$file.FullName; Key=('OneC\' + $file.Name);
                Destination=(Join-Path $TargetPath ('AppData\Roaming\1C\1CEStart\' + $file.Name)); Name=('1С: ' + $file.Name) }
        }
    }
    if ($jobs.Count -eq 0) {
        Write-OperationReport 'НАСТРОЙКИ' 'Дополнительных файлов закреплений Проводника и 1С в архиве нет.'
        return
    }
    $backupBase = Join-Path $Script:WpmWorkRoot 'ConfigBackups'
    Initialize-WpmWorkDirectory $backupBase
    $backupRoot = Join-Path $backupBase ((Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    Update-TrackedState '' @{ConfigBackupPath=$backupRoot}
    [int]$done = 0
    foreach ($job in $jobs) {
        try {
            if (-not (Is-AllowedExtra $ApprovedExtras $job.Key)) {
                throw ('Файл не прошёл SHA-256: ' + $job.Key)
            }
            $dest = [string]$job.Destination
            $backup = Join-Path $backupRoot $job.Key
            $hash = if ($null -ne $ApprovedExtras) { [string]$ApprovedExtras[$job.Key] } else { '' }
            if (-not (Copy-RequiredFile -From $job.Source -To $dest -AllowedSourceRoot $Archive -AllowedDestinationRoot $TargetPath -Backup $backup -ExpectedHash $hash)) {
                throw ('Файл исчез до восстановления: ' + $job.Key)
            }
            $done++
            $backupNote = if ([IO.File]::Exists($backup)) { '; прежний файл сохранён в ' + $backup } else { '' }
            Write-OperationReport 'НАСТРОЙКИ' ('Восстановлено: ' + $job.Name + $backupNote)
        } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не перенесён ' + $job.Name + ': ' + $_.Exception.Message) }
    }
    Write-OperationReport 'НАСТРОЙКИ' ('Закрепления Проводника и 1С: восстановлено ' + $done + ' из ' + $jobs.Count + ' файлов.')
}

function Invoke-ProfileRegistryCommand([string[]]$Arguments) {
    $reg = Join-Path $env:SystemRoot 'System32/reg.exe'
    $commandLine = @($Arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join ' '
    $process = Start-Process -FilePath $reg -ArgumentList $commandLine -NoNewWindow -Wait -PassThru -ErrorAction Stop
    try {
        if ($null -eq $process.ExitCode) { throw 'reg.exe не вернул код завершения.' }
        return [int]$process.ExitCode
    } finally { $process.Dispose() }
}

# Выполняет действие с реестром именно выбранного пользователя. При отсутствии
# сеанса временно подключает NTUSER.DAT и гарантированно пытается выгрузить его.
function Invoke-ProfileHive([string]$Sid,[string]$ProfilePath,[scriptblock]$Action,[bool]$RequireOffline = $false) {
    if ($Sid -notmatch '^S-1-(?:[0-9]+-){1,14}[0-9]+$') { throw 'Некорректный SID пользовательского реестра.' }
    $hku = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users,[Microsoft.Win32.RegistryView]::Default)
    $mount = $Sid
    $mountedHere = $false
    try {
        $probe = $hku.OpenSubKey($mount,$false)
        if ($probe) {
            $probe.Dispose()
            if ($RequireOffline) { throw 'Целевой пользователь должен завершить сеанс перед изменением реестра.' }
        } else {
            $ntuser = Join-Path $ProfilePath 'NTUSER.DAT'
            Assert-ProfileExtraPath $ntuser $ProfilePath
            if (-not [IO.File]::Exists($ntuser)) { throw ('Отсутствует пользовательский реестр: ' + $ntuser) }
            $mount = 'WPM_' + [guid]::NewGuid().ToString('N')
            $code = Invoke-ProfileRegistryCommand @('load',('HKU\' + $mount),$ntuser)
            if ($code -ne 0) { throw ('reg load: код ' + $code + '; реестр: ' + $ProfilePath) }
            $mountedHere = $true
        }
        return (& $Action $hku $mount)
    } finally {
        $hku.Dispose()
        if ($mountedHere) {
            try {
                $code = Invoke-ProfileRegistryCommand @('unload',('HKU\' + $mount))
                if ($code -ne 0) { throw ('Код ' + $code) }
            } catch {
                Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('reg unload: временный реестр HKU\' + $mount + ' мог остаться подключённым; ' + $_.Exception.Message)
            }
        }
    }
}

function Test-NetworkDriveRemotePath([string]$Path) {
    if (-not $Path.StartsWith('\\') -or $Path.Length -gt 1024 -or $Path -match '[<>:"/|?*\x00-\x1f]') {
        return $false
    }
    $parts = $Path.Substring(2).TrimEnd('\').Split('\')
    if ($parts.Count -lt 2 -or $parts[0] -notmatch '^[\p{L}\p{N}_-]+(?:\.[\p{L}\p{N}_-]+)*$') {
        return $false
    }
    foreach ($part in $parts) {
        if (-not $part -or $part -match '[ .]$') { return $false }
    }
    return $true
}

# Сохраняет постоянные подключения сетевых дисков из HKCU\Network
# выбранного пользователя (пароли и учётные данные не извлекаются).
function Export-NetworkDrives([object]$Profile,[string]$Archive) {
    $drives = @(Invoke-ProfileHive $Profile.SID $Profile.Path {
        param($hku,$mount)
        $network = $hku.OpenSubKey(($mount + '\Network'),$false)
        if (-not $network) { return }
        try {
            foreach ($letter in @($network.GetSubKeyNames())) {
                if ($letter -notmatch '^[a-zA-Z]$') { continue }
                $key = $network.OpenSubKey($letter,$false)
                if (-not $key) { continue }
                try {
                    $remote = [string]$key.GetValue('RemotePath','')
                    if (-not (Test-NetworkDriveRemotePath $remote)) {
                        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Некорректный UNC-путь сетевого диска ' + $letter + ': пропущен.')
                        continue
                    }
                    [pscustomobject]@{ Letter=$letter.ToUpperInvariant(); RemotePath=$remote;
                        ProviderName=[string]$key.GetValue('ProviderName','Microsoft Windows Network');
                        ProviderType=[int]$key.GetValue('ProviderType',131072);
                        ConnectionType=[int]$key.GetValue('ConnectionType',1);
                        DeferFlags=[int]$key.GetValue('DeferFlags',4) }
                } finally { $key.Dispose() }
            }
        } finally { $network.Dispose() }
    } | Where-Object { $null -ne $_ })
    $destination = Join-Path $Archive 'Extras\NetworkDrives.json'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force -ErrorAction Stop)
    [pscustomobject]@{ SchemaVersion=1; Mappings=$drives } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $destination -Encoding UTF8 -ErrorAction Stop
    foreach ($drive in $drives) { Write-OperationReport 'СЕТЕВОЙ ДИСК' ('Сохранено: ' + $drive.Letter + ': -> ' + $drive.RemotePath) }
    Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' ('Постоянных подключений обнаружено: ' + $drives.Count)
    return $drives.Count
}

# Для вновь созданного профиля записывает постоянные диски в его HKCU.
# Существующие буквы не перезаписывает; подключение выполняется Windows при входе.
function Restore-NetworkDrives([string]$Archive,[string]$TargetSid,[string]$TargetPath,[hashtable]$ApprovedExtras) {
    $source = Join-Path $Archive 'Extras\NetworkDrives.json'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' 'Список постоянных подключений отсутствует в архиве.'
        return
    }
    if (-not (Is-AllowedExtra $ApprovedExtras 'NetworkDrives.json')) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Сетевые диски пропущены: файл не прошёл контроль SHA-256.'
        return
    }
    $hash = if ($null -ne $ApprovedExtras) { [string]$ApprovedExtras['NetworkDrives.json'] } else { '' }
    $data = Read-ExtraJson $source $Archive $hash
    if ([int]$data.SchemaVersion -ne 1) { throw 'Неизвестный формат списка сетевых дисков.' }
    $mappings = @($data.Mappings | Where-Object { $null -ne $_ })
    if ($mappings.Count -eq 0) {
        Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' 'В архиве нет постоянных подключений.'
        return
    }
    $localLetters = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType <> 4' -ErrorAction Stop |
        ForEach-Object { ([string]$_.DeviceID).TrimEnd(':') })
    $added = Invoke-ProfileHive $TargetSid $TargetPath {
        param($hku,$mount)
        [int]$count = 0
        foreach ($mapping in $mappings) {
            $letter = ''
            try {
                $letter = [string]$mapping.Letter
                $remote = [string]$mapping.RemotePath
                if ($letter -notmatch '^[A-Z]$' -or -not (Test-NetworkDriveRemotePath $remote)) {
                    throw 'Некорректная буква диска или UNC-путь.'
                }
                if ($letter -in $localLetters) { throw 'Буква занята локальным томом.' }
                $provider = [string]$mapping.ProviderName
                $providerType = [int]$mapping.ProviderType
                $connectionType = [int]$mapping.ConnectionType
                $deferFlags = [int]$mapping.DeferFlags
                if (-not $provider -or $provider.Length -gt 200 -or $provider -match '[\x00-\x1f]' -or
                    $providerType -lt 0 -or $connectionType -lt 0 -or $deferFlags -lt 0) {
                    throw 'Некорректные параметры сетевого провайдера.'
                }
                $path = $mount + '\Network\' + $letter
                $existing = $hku.OpenSubKey($path,$false)
                if ($existing) {
                    $existing.Dispose()
                    throw 'Буква уже назначена постоянному подключению.'
                }
                $key = $hku.CreateSubKey($path)
                if (-not $key) { throw ('Не удалось создать ключ Network\' + $letter) }
                try {
                    $key.SetValue('RemotePath',$remote,[Microsoft.Win32.RegistryValueKind]::String)
                    $key.SetValue('ProviderName',$provider,[Microsoft.Win32.RegistryValueKind]::String)
                    $key.SetValue('ProviderType',$providerType,[Microsoft.Win32.RegistryValueKind]::DWord)
                    $key.SetValue('ConnectionType',$connectionType,[Microsoft.Win32.RegistryValueKind]::DWord)
                    $key.SetValue('DeferFlags',$deferFlags,[Microsoft.Win32.RegistryValueKind]::DWord)
                    $key.Flush()
                } catch {
                    $key.Dispose()
                    $key = $null
                    try { $hku.DeleteSubKey($path,$false) }
                    catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалён неполный ключ сетевого диска ' + $letter + ': ' + $_.Exception.Message) }
                    throw
                } finally {
                    if ($key) { $key.Dispose() }
                }
                $count++
                Write-OperationReport 'СЕТЕВОЙ ДИСК' ('Восстановлено: ' + $letter + ': -> ' + $remote + '; подключение при входе пользователя')
            } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не восстановлен сетевой диск ' + $letter + ': ' + $_.Exception.Message) }
        }
        return $count
    } $true
    Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' ('Добавлено ' + $added + ' из ' + $mappings.Count + ' постоянных подключений.')
}
