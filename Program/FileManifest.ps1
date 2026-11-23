# Реестр связывает каждый файл выбранного профиля с размером и контрольной суммой.

# Обход без следования junction/symlink и без подавления ошибок доступа.
function Get-ValidationSourceFiles([string]$ProfilePath) {
    $activity = 'Обход контрольных папок профиля'
    $directories = @(Get-ValidationSourceDirectories)
    $checked = 0
    $files = 0L
    $links = 0L
    try {
        foreach ($rel in $directories) {
            $percent = [int][Math]::Floor(100.0 * $checked / $directories.Count)
            Write-Progress -Id 14 -Activity $activity -Status ('Готовых папок {0} из {1}, найдено файлов {2}' -f $checked,$directories.Count,$files) -PercentComplete $percent
            $checked++
            $dir = Get-ProfileDataItem $ProfilePath $rel
            if (-not $dir -or -not $dir.PSIsContainer) { continue }
            $pending = New-Object 'System.Collections.Generic.Stack[string]'
            $pending.Push([string]$dir.FullName)
            while ($pending.Count -gt 0) {
                $current = $pending.Pop()
                foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
                    if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        $links++
                        continue
                    }
                    if ($child.PSIsContainer) { $pending.Push([string]$child.FullName) }
                    else {
                        $files++
                        $child
                    }
                }
            }
        }
        Write-Progress -Id 14 -Activity $activity -Status ('Обход завершён, найдено файлов {0}' -f $files) -PercentComplete 100
    } finally {
        Write-Progress -Id 14 -Activity $activity -Completed
    }
    Write-OperationReport 'ПРОВЕРКА' ('Обход контрольных папок завершён. Файлов {0}, пропущено ссылок {1}.' -f $files,$links)
}
function Read-ValidationManifestRecord([string]$Line) {
    if (-not $Line.TrimStart().StartsWith('{')) { throw 'Недопустимая запись контрольного реестра.' }
    $record = $Line | ConvertFrom-Json -ErrorAction Stop
    $relative = @(Get-WindowsRelativePathParts ([string]$record.RelativePath)) -join '\'
    if (($record.Length -isnot [int] -and $record.Length -isnot [long]) -or $record.Length -lt 0 -or
        [string]$record.SHA256 -notmatch '\A[0-9a-fA-F]{64}\z') {
        throw ('Недопустимый размер или SHA-256 в контрольном реестре: ' + $relative)
    }
    return [pscustomobject]@{ RelativePath=$relative; Length=[long]$record.Length; SHA256=[string]$record.SHA256 }
}
function New-ValidationManifest([string]$ProfilePath,[string]$Archive) {
    $valDir = Join-Path $Archive 'Validation'
    [void](New-Item -Path $valDir -ItemType Directory -Force)
    $filename = Join-Path $valDir 'files.jsonl'
    $writer = [IO.StreamWriter]::new($filename,$false,[Text.UTF8Encoding]::new($false))
    [long]$count = 0
    [long]$bytes = 0
    Write-OperationReport 'ПРОВЕРКА' 'Начато создание контрольного реестра файлов перед ScanState.'
    try {
        $root = [IO.Path]::GetFullPath($ProfilePath).TrimEnd([IO.Path]::DirectorySeparatorChar)
        Get-ValidationSourceFiles $ProfilePath | ForEach-Object {
            $file = $_
            $relative = $file.FullName.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
            try {
                $current = Get-ProfileDataItem $ProfilePath $relative
                if (-not $current -or $current.PSIsContainer) { throw 'Файл больше недоступен внутри профиля.' }
                $length = [long]$current.Length
                $hash = Get-ExactFileSha256 $file.FullName
            } catch {
                throw ('Не удалось вычислить SHA-256 ДО ScanState для ' + $relative + ': ' + $_.Exception.Message)
            }
            $line = [ordered]@{ RelativePath=$relative; Length=$length; SHA256=$hash } | ConvertTo-Json -Compress
            $writer.WriteLine($line)
            $count++
            $bytes += $length
            if (($count % 100) -eq 0) {
                Write-Progress -Id 2 -Activity 'SHA-256 перед ScanState' -Status ('Сверено файлов {0}, байт {1}' -f $count,$bytes) -PercentComplete -1
            }
        }
    } catch {
        Write-OperationReport 'ДИАГНОСТИКА' ('Создание реестра прервано. Записей {0}, проверено {1} байт.' -f $count,$bytes)
        throw
    } finally {
        $writer.Dispose()
        Write-Progress -Id 2 -Activity 'SHA-256 перед ScanState' -Completed
    }
    $sha = Get-ExactFileSha256 $filename
    Write-OperationReport 'ПРОВЕРКА' ("Исходный реестр ДО ScanState: файлов {0}, байт {1}. SHA-256: {2}" -f $count,$bytes,$sha)
    return [pscustomobject]@{ Path='Validation/files.jsonl'; Files=$count; Bytes=$bytes; Skipped=0; SHA256=$sha }
}
# Второй проход по всем контрольным файлам. Ловит изменения, удаление и добавление
# между созданием реестра и окончанием ScanState/экспорта Extras. Изменение
# означает, что архив нельзя объявлять согласованным; экспорт завершается ошибкой.
function Assert-ValidationSourceStable([string]$ProfilePath,[string]$Archive,[object]$Manifest) {
    $manifestPath = Join-Path $Archive 'Validation\files.jsonl'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Контрольный реестр отсутствует.' }
    if ([string](Get-ExactFileSha256 $manifestPath) -ne [string]$Manifest.SHA256) {
        throw 'Файл контрольного реестра изменился после первоначального создания.'
    }
    $expected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$checked = 0
    [long]$changed = 0
    $details = New-Object 'System.Collections.Generic.List[string]'
    $reader = [IO.StreamReader]::new($manifestPath,[Text.Encoding]::UTF8)
    $activity = 'Сверка источника после ScanState'
    Write-OperationReport 'ПРОВЕРКА' ('Начата повторная сверка источника после ScanState. Записей {0}.' -f $Manifest.Files)
    Write-Progress -Id 2 -Activity $activity -Status 'Повторная сверка контрольных файлов' -PercentComplete 0
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { continue }
            $item = Read-ValidationManifestRecord $line
            $rel = $item.RelativePath
            if (-not $expected.Add($rel)) { throw ('Повторяющийся путь в реестре: ' + $rel) }
            $checked++
            try {
                $file = Get-ProfileDataItem $ProfilePath $rel
                if (-not $file -or $file.PSIsContainer -or [long]$file.Length -ne $item.Length) {
                    $changed++
                    if ($details.Count -lt 15) { $details.Add('Изменён размер: ' + $rel) }
                } elseif ((Get-ExactFileSha256 $file.FullName) -ne $item.SHA256) {
                    $changed++
                    if ($details.Count -lt 15) { $details.Add('Изменён SHA-256: ' + $rel) }
                }
            } catch {
                $changed++
                if ($details.Count -lt 15) { $details.Add('Отсутствует или недоступен: ' + $rel) }
            }
            if (($checked % 100) -eq 0 -or $checked -eq $Manifest.Files) {
                Write-Progress -Id 2 -Activity $activity -Status ("Проверено {0} из {1}, расхождений {2}" -f $checked,$Manifest.Files,$changed) -PercentComplete ([int][Math]::Min(100,[Math]::Floor($checked * 100.0 / [Math]::Max(1,[long]$Manifest.Files))))
            }
        }
    } finally {
        $reader.Dispose()
        Write-Progress -Id 2 -Activity $activity -Completed
    }
    if ($checked -ne [long]$Manifest.Files) { throw 'Изменилось число записей контрольного реестра.' }
    [long]$newFiles = 0
    $separator = [IO.Path]::DirectorySeparatorChar
    $root = [IO.Path]::GetFullPath($ProfilePath).TrimEnd($separator)
    Get-ValidationSourceFiles $ProfilePath | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart($separator).Replace($separator,[char]'\')
        if (-not $expected.Contains($rel)) {
            $newFiles++
            if ($details.Count -lt 15) { $details.Add('Новый файл: ' + $rel) }
        }
    }
    if ($changed -gt 0 -or $newFiles -gt 0) {
        foreach ($entry in @($details.ToArray())) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' $entry }
        throw ("Источник менялся во время экспорта: изменено/пропало {0}, новых файлов {1}. Архив не помечен готовым. Закройте сеанс пользователя и повторите экспорт." -f $changed,$newFiles)
    }
    Write-OperationReport 'ПРОВЕРКА' ('Все ' + $checked + ' контрольных файлов совпадают до и после ScanState; новых файлов нет.')
    return [pscustomobject]@{ Stable=$true; Method='HashBeforeScanAndCheckAfterScan'; Files=$checked; NewFiles=0; ChangedFiles=0; Scope='Desktop,Documents,Downloads,Pictures,Music,Videos,Favorites,Saved Games'; CompletedAt=(Get-Date).ToString('o') }
}
# Сверяет сам файл реестра с SHA-256 в metadata до импорта/проверки архива.
function Assert-ValidationManifestIntegrity([string]$Archive,[object]$Meta) {
    if ([int]$Meta.SchemaVersion -lt 6) { return }
    if (-not $Meta.ValidationManifest -or -not $Meta.ValidationManifest.SHA256 -or
        -not $Meta.ValidationConsistency -or -not $Meta.ValidationConsistency.Stable) {
        throw 'Архив v6 не содержит подтверждённой согласованности источника.'
    }
    $path = Join-Path $Archive 'Validation\files.jsonl'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Отсутствует реестр файлов.' }
    Write-OperationReport 'ПРОВЕРКА' 'Начата проверка SHA-256 и записей контрольного реестра.'
    $actual = Get-ExactFileSha256 $path
    if ($actual -ne [string]$Meta.ValidationManifest.SHA256) {
        throw 'SHA-256 контрольного реестра отличается от сохранённого в метаданных.'
    }
    $info = $Meta.ValidationManifest
    if ($info.Path -ne 'Validation/files.jsonl' -or [long]$info.Files -lt 0 -or [long]$info.Bytes -lt 0) {
        throw 'Некорректные метаданные контрольного реестра.'
    }
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [decimal]$bytes = 0
    $reader = [IO.StreamReader]::new($path,[Text.Encoding]::UTF8,$true)
    $activity = 'Проверка записей контрольного реестра'
    Write-Progress -Id 14 -Activity $activity -Status 'Чтение записей' -PercentComplete 0
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { continue }
            $record = Read-ValidationManifestRecord $line
            if (-not $paths.Add($record.RelativePath)) { throw ('Повторяющийся путь в реестре: ' + $record.RelativePath) }
            $bytes += $record.Length
            if ($paths.Count -gt [long]$info.Files -or $bytes -gt [long]$info.Bytes) {
                throw 'Контрольный реестр превышает количество файлов или суммарный размер в метаданных.'
            }
            if ($paths.Count % 100 -eq 0 -or $paths.Count -eq $info.Files) {
                $percent = [int][Math]::Floor(100.0 * $paths.Count / [long]$info.Files)
                Write-Progress -Id 14 -Activity $activity -Status ('Проверено {0} из {1} записей' -f $paths.Count,$info.Files) -PercentComplete $percent
            }
        }
    } finally {
        $reader.Dispose()
        Write-Progress -Id 14 -Activity $activity -Completed
    }
    if ($paths.Count -ne [long]$info.Files -or $bytes -ne [long]$info.Bytes) {
        throw 'Количество файлов или суммарный размер контрольного реестра не совпадает с метаданными.'
    }
    Write-OperationReport 'ПРОВЕРКА' ('Контрольный реестр прошёл проверку SHA-256. Записей {0}, суммарный размер файлов {1} байт.' -f $paths.Count,$bytes)
}
# Сверяет каждый файл реестра по пути, размеру и SHA-256 после LoadState.
# Несовпадения НЕ превращаем в успешный перенос, даже если код USMT равен 0.
function Test-ValidationManifest([string]$Archive,[string]$TargetPath,[object]$Meta) {
    if (-not ($Meta.PSObject.Properties.Name -contains 'ValidationManifest')) { return $null }
    $info=$Meta.ValidationManifest
    if (-not $info -or [string]$info.Path -ne 'Validation/files.jsonl') { throw 'Сведения о контрольном реестре повреждены.' }
    $path=Join-Path $Archive 'Validation\files.jsonl'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'В новом архиве отсутствует реестр контрольных сумм.' }
    [long]$expected=[long]$info.Files
    [long]$seen=0
    [long]$ok=0
    [long]$missing=0
    [long]$modified=0
    $examples = New-Object 'System.Collections.Generic.List[string]'
    $sr=[IO.StreamReader]::new($path,[Text.Encoding]::UTF8)
    Write-OperationReport 'ПРОВЕРКА' ('Начата сверка восстановленных файлов. Ожидается записей {0}.' -f $expected)
    Write-Progress -Id 3 -Activity 'Проверка восстановленных данных' -Status 'Чтение записей' -PercentComplete 0
    try {
        while ($null -ne ($line=$sr.ReadLine())) {
            if (-not $line.Trim()) { continue }
            $item = Read-ValidationManifestRecord $line
            $rel = $item.RelativePath
            $seen++
            try {
                $actual = Get-ProfileDataItem $TargetPath $rel
                if (-not $actual -or $actual.PSIsContainer) {
                    $missing++
                    if ($examples.Count -lt 20) { $examples.Add('Отсутствует или находится по ссылке: '+$rel) }
                } elseif ([long]$actual.Length -ne $item.Length) {
                    $modified++
                    if ($examples.Count -lt 20) { $examples.Add('Размер отличается: '+$rel) }
                } elseif ((Get-ExactFileSha256 $actual.FullName) -ne $item.SHA256) {
                    $modified++
                    if ($examples.Count -lt 20) { $examples.Add('Контрольная сумма отличается: '+$rel) }
                } else { $ok++ }
            } catch {
                $modified++
                if ($examples.Count -lt 20) { $examples.Add('Нет доступа для проверки: '+$rel) }
            }
            if ($seen % 50 -eq 0 -or $seen -eq $expected) {
                $percent=if ($expected -gt 0) { [int][Math]::Min(100,[Math]::Floor($seen*100.0/$expected)) } else { 100 }
                Write-Progress -Id 3 -Activity 'Проверка восстановленных данных' -Status ("Файлов: {0}/{1}, совпали: {2}" -f $seen,$expected,$ok) -PercentComplete $percent
            }
        }
    } finally {
        $sr.Dispose()
        Write-Progress -Id 3 -Activity 'Проверка восстановленных данных' -Completed
    }
    if ($seen -ne $expected) { throw ("Нарушена целостность реестра файлов: ожидалось {0}, найдено {1}." -f $expected,$seen) }
    return [pscustomobject]@{ Total=$seen; Matched=$ok; Missing=$missing; Changed=$modified; Errors=@($examples.ToArray()); SourceSkipped=[long]$info.Skipped }
}
