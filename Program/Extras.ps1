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

# Один проход одновременно считает SHA-256 и, если нужен выходной поток, копирует файл.
function Get-ExtraStreamSha256([IO.Stream]$Stream, [IO.Stream]$Destination = $null, [string]$Activity = '') {
    $sha = [Security.Cryptography.SHA256]::Create()
    $showProgress = $false
    try {
        $Stream.Position = 0
        if (-not $Destination -and -not $Activity) {
            return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-','')
        }
        $buffer = [byte[]]::new(1MB)
        $length = if ($Activity) { $Stream.Length } else { 0 }
        # Короткие файлы видны на общей полосе. Отдельная нужна, когда файл читается несколькими блоками.
        $showProgress = $length -gt $buffer.Length
        $lastPercent = 0
        if ($showProgress) {
            Write-Progress -Id 3 -ParentId 8 -Activity $Activity -Status ('Байт обработано: 0 из ' + $length) -PercentComplete 0
        }
        while (($count = $Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($Activity -and (Test-RunningProcessStopRequest $Activity 3)) {
                throw [OperationCanceledException]::new('Операция с личным файлом отменена.')
            }
            if ($Destination) { $Destination.Write($buffer,0,$count) }
            [void]$sha.TransformBlock($buffer,0,$count,$null,0)
            if ($showProgress) {
                $percent = [int][Math]::Min(100.0,[Math]::Floor(100.0 * $Stream.Position / $length))
                if ($percent -ne $lastPercent) {
                    Write-Progress -Id 3 -ParentId 8 -Activity $Activity -Status ('Байт обработано: {0} из {1}' -f $Stream.Position,$length) -PercentComplete $percent
                    $lastPercent = $percent
                }
            }
        }
        [void]$sha.TransformFinalBlock([byte[]]@(),0,0)
        return [BitConverter]::ToString($sha.Hash).Replace('-','')
    } finally {
        if ($showProgress) { Write-Progress -Id 3 -ParentId 8 -Activity $Activity -Completed }
        $Stream.Position = 0
        $sha.Dispose()
    }
}

function Get-ExtraFileSha256([string]$Path, [string]$Activity) {
    $stream = [IO.File]::Open($Path,'Open','Read','Read')
    try { return Get-ExtraStreamSha256 $stream -Activity $Activity }
    finally { $stream.Dispose() }
}

# Копируем с открытым источником, чтобы другой процесс не изменил его между
# чтением и проверкой. Ошибка копирования или SHA-256 не публикует файл.
function Copy-RequiredFile(
    [string]$From,
    [string]$To,
    [string]$AllowedSourceRoot = '',
    [string]$AllowedDestinationRoot = '',
    [string]$Backup = '',
    [string]$ExpectedHash = '',
    [switch]$AllowCancel
) {
    if ($AllowedSourceRoot) { Assert-ProfileExtraPath $From $AllowedSourceRoot $true }
    if (-not [IO.File]::Exists($From)) { return $false }
    if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $To $AllowedDestinationRoot $true }
    $parent = Split-Path -Parent $To
    [void][IO.Directory]::CreateDirectory($parent)
    if ($AllowedDestinationRoot) { Assert-ProfileExtraPath $To $AllowedDestinationRoot $true }
    $temporary = Join-Path $parent ('.WPM_' + [guid]::NewGuid().ToString('N') + '.tmp')
    $source = [IO.File]::Open($From,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $activity = if ($AllowCancel) { 'копирование личного файла' } else { '' }
    try {
        $output = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $sourceHash = Get-ExtraStreamSha256 $source $output $activity
            $output.Flush($true)
        } finally { $output.Dispose() }
        $verifyActivity = if ($AllowCancel) { 'сверку копии личного файла' } else { '' }
        if (($ExpectedHash -and $sourceHash -ne $ExpectedHash) -or
            $sourceHash -ne (Get-ExtraFileSha256 $temporary $verifyActivity)) {
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
    $activity = 'Контрольные суммы дополнительных файлов'
    $total = 0
    Write-OperationReport 'ПРОВЕРКА' 'Начато создание списка SHA-256 для дополнительных файлов.'
    try {
        Write-Progress -Id 9 -Activity $activity -Status 'Поиск дополнительных файлов в архиве' -PercentComplete -1
        if (Test-Path -LiteralPath $extras -PathType Container) {
            Assert-ProfileExtraPath $extras $Archive
            $files = @(Get-ChildItem -LiteralPath $extras -Recurse -File -Force -ErrorAction Stop)
            $total = $files.Count
            if ($total) { Write-Progress -Id 9 -Activity $activity -Status ('Файлов обработано: 0 из ' + $total) -PercentComplete 0 }
            $lastPercent = 0
            foreach ($file in $files) {
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
                    if ($skipped -le 5) {
                        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось вычислить SHA-256 для ' + $rel + '. ' + $_.Exception.Message)
                    }
                }
                $processed = $count + $skipped
                $percent = [int][Math]::Floor(100.0 * $processed / $total)
                if ($percent -ne $lastPercent) {
                    Write-Progress -Id 9 -Activity $activity -Status ('Файлов обработано: {0} из {1}' -f $processed,$total) -PercentComplete $percent
                    $lastPercent = $percent
                }
            }
        }
    } finally {
        Write-Progress -Id 9 -Activity $activity -Completed
        $writer.Dispose()
        Write-OperationReport 'ПРОВЕРКА' ('Дополнительные файлы: найдено {0}, контрольных сумм записано {1}, пропущено {2}.' -f $total,$count,$skipped)
    }
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
    $activity = 'Проверка дополнительных файлов'
    $expected = [int]$info.Files
    $rejected = 0
    $lineNumber = 0
    $lastPercent = 0
    Write-OperationReport 'ПРОВЕРКА' ('Начата сверка SHA-256 дополнительных файлов. Записей по данным архива: ' + $expected)
    # Закрываем поток и при ошибке разбора или проверки записи.
    $reader = [IO.StreamReader]::new($path,[Text.Encoding]::UTF8,$true)
    try {
        if ($expected -gt 0) {
            Write-Progress -Id 9 -Activity $activity -Status ('Записей обработано: 0 из ' + $expected) -PercentComplete 0
        } else {
            Write-Progress -Id 9 -Activity $activity -Status 'Чтение контрольного списка' -PercentComplete -1
        }
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNumber++
            if (-not $line.Trim()) { continue }
            try { $entry = $line | ConvertFrom-Json -ErrorAction Stop }
            catch { throw ('Некорректный JSON в манифесте дополнительных файлов на строке ' + $lineNumber + '.') }
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
            $reason = ''
            try {
                # Проверяем и корневой каталог Extras, и путь внутри него.
                Assert-ProfileExtraPath $full $Archive
                $file = Get-Item -LiteralPath $full -Force -ErrorAction Stop
                if ($file.PSIsContainer) { $reason = 'в архиве находится папка вместо файла' }
                elseif ($file.Length -ne [long]$entry.Length) { $reason = 'изменился размер файла' }
                elseif ((Get-ExactFileSha256 $full) -ne $hash) { $reason = 'не совпадает SHA-256' }
            } catch [System.Management.Automation.ItemNotFoundException] { $reason = 'файл отсутствует' }
            catch { $reason = 'файл недоступен для чтения или путь отклонён (' + $_.Exception.GetType().Name + ')' }
            if ($reason) {
                $rejected++
                if ($rejected -le 5) {
                    Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Дополнительный файл ' + $rel + ' пропущен: ' + $reason + '.')
                }
            } else { $approved[$key] = $hash }
            if ($expected -gt 0) {
                $percent = [int][Math]::Min(100.0,[Math]::Floor(100.0 * $seen.Count / $expected))
                if ($percent -ne $lastPercent) {
                    Write-Progress -Id 9 -Activity $activity -Status ('Записей обработано: {0} из {1}' -f $seen.Count,$expected) -PercentComplete $percent
                    $lastPercent = $percent
                }
            }
        }
    } finally {
        Write-Progress -Id 9 -Activity $activity -Completed
        $reader.Dispose()
        Write-OperationReport 'ПРОВЕРКА' ('Дополнительные файлы: записей обработано {0} из {1}, совпало {2}, отклонено {3}.' -f $seen.Count,$expected,$approved.Count,$rejected)
    }
    if ($seen.Count -ne $expected) { throw 'Число записей Extras не совпадает с метаданными.' }
    if ([int]$info.Skipped -gt 0) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('При экспорте не удалось вычислить хеши Extras: ' + $info.Skipped)
    }
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
    Write-OperationReport 'НАСТРОЙКИ' 'Начато сохранение закреплений Проводника и параметров 1С.'
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
    $total = 0
    $activity = 'Сохранение параметров 1С'
    if (Test-Path -LiteralPath $sourceDir -PathType Container) {
        try {
            Write-Progress -Id 9 -Activity $activity -Status 'Поиск файлов настроек' -PercentComplete -1
            Assert-ProfileExtraPath $sourceDir $Profile.Path
            $files = @(Get-ChildItem -LiteralPath $sourceDir -File -Force -ErrorAction Stop | Where-Object {
                $_.Name -match '(?i)^(ibases[^\\/]*\.v8i|1cestart\.cfg)$'
            })
            $total = $files.Count
            $processed = 0
            foreach ($file in $files) {
                $percent = [int][Math]::Floor(100.0 * $processed / $total)
                Write-Progress -Id 9 -Activity $activity -Status ('Файлов обработано: {0} из {1}' -f $processed,$total) -PercentComplete $percent
                try {
                    $dest = Join-Path (Join-Path $Archive 'Extras\OneC') $file.Name
                    if (-not (Copy-RequiredFile $file.FullName $dest $Profile.Path $Archive)) { throw 'Файл исчез во время экспорта.' }
                    $oneCSaved++
                    $saved++
                } catch {
                    if (($processed - $oneCSaved) -lt 5) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось сохранить настройки 1С: ' + $_.Exception.Message) }
                }
                $processed++
            }
        } finally { Write-Progress -Id 9 -Activity $activity -Completed }
    }
    Write-OperationReport '1С' ('Файлов настроек сохранено: {0} из {1}.' -f $oneCSaved,$total)
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
    $processed = 0
    $backedUp = 0
    $activity = 'Восстановление настроек Проводника и 1С'
    Write-OperationReport 'НАСТРОЙКИ' ('Начато восстановление настроек Проводника и 1С. Файлов: ' + $jobs.Count)
    try {
        foreach ($job in $jobs) {
            $percent = [int][Math]::Floor(100.0 * $processed / $jobs.Count)
            Write-Progress -Id 9 -Activity $activity -Status ('Файлов обработано: {0} из {1}' -f $processed,$jobs.Count) -PercentComplete $percent
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
                if ([IO.File]::Exists($backup)) { $backedUp++ }
            } catch {
                if (($processed - $done) -lt 5) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не перенесён ' + $job.Name + ': ' + $_.Exception.Message) }
            }
            $processed++
        }
    } finally {
        Write-Progress -Id 9 -Activity $activity -Completed
        Write-OperationReport 'НАСТРОЙКИ' ('Проводник и 1С: восстановлено файлов {0} из {1}, резервных копий {2}.' -f $done,$jobs.Count,$backedUp)
    }
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
    $activity = 'Сохранение сетевых дисков'
    Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' 'Начато чтение постоянных сетевых подключений.'
    Write-Progress -Id 9 -Activity $activity -Status 'Чтение реестра профиля' -PercentComplete -1
    try {
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
    } finally { Write-Progress -Id 9 -Activity $activity -Completed }
    $destination = Join-Path $Archive 'Extras\NetworkDrives.json'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force -ErrorAction Stop)
    [pscustomobject]@{ SchemaVersion=1; Mappings=$drives } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $destination -Encoding UTF8 -ErrorAction Stop
    Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' ('Сохранено постоянных подключений: ' + $drives.Count)
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
    $restoreMappings = {
        param($hku,$mount)
        [int]$count = 0
        $processed = 0
        foreach ($mapping in $mappings) {
            $percent = [int][Math]::Floor(100.0 * $processed / $mappings.Count)
            Write-Progress -Id 9 -Activity $activity -Status ('Подключений проверено: {0} из {1}' -f $processed,$mappings.Count) -PercentComplete $percent
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
            } catch {
                if (($processed - $count) -lt 5) {
                    Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не восстановлено постоянное подключение. ' + $_.Exception.Message)
                }
            }
            $processed++
        }
        return $count
    }
    $activity = 'Восстановление сетевых дисков'
    Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' ('Начато восстановление постоянных подключений. Записей: ' + $mappings.Count)
    Write-Progress -Id 9 -Activity $activity -Status 'Открытие реестра профиля' -PercentComplete -1
    try { $added = Invoke-ProfileHive $TargetSid $TargetPath $restoreMappings $true }
    finally { Write-Progress -Id 9 -Activity $activity -Completed }
    Write-OperationReport 'СЕТЕВЫЕ ДИСКИ' ('Добавлено постоянных подключений: {0} из {1}. Windows подключит их при входе пользователя.' -f $added,$mappings.Count)
}
