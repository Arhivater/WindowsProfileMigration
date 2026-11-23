# Чтение и создание архивов с проверкой путей, размеров и контрольных сумм.

# Читаем файл напрямую через .NET-поток, чтобы скрытые и системные файлы
# (например, desktop.ini) не отсеивались PowerShell FileSystemProvider.
# Закрытие потока выполняется также при ошибке чтения.
function Get-ExactFileSha256([string]$Path) {
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $length = $stream.Length
        if ($length -lt 16MB) {
            return (Get-FileHash -InputStream $stream -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        # Для крупных файлов показываем долю реально прочитанных байтов.
        $activity = 'Вычисление SHA-256 крупного файла'
        $hash = [Security.Cryptography.SHA256]::Create()
        $buffer = [byte[]]::new(1MB)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            Write-Progress -Id 15 -Activity $activity -Status 'Чтение файла' -PercentComplete 0
            while (($read = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
                [void]$hash.TransformBlock($buffer,0,$read,$buffer,0)
                if ($clock.ElapsedMilliseconds -ge 250 -or $stream.Position -eq $length) {
                    $percent = [int][Math]::Min(100,[Math]::Floor(100.0 * $stream.Position / $length))
                    Write-Progress -Id 15 -Activity $activity -Status ('Прочитано {0} из {1} байт' -f $stream.Position,$length) -PercentComplete $percent
                    $clock.Restart()
                }
            }
            [void]$hash.TransformFinalBlock([byte[]]::new(0),0,0)
            return [BitConverter]::ToString($hash.Hash).Replace('-','')
        } finally {
            $hash.Dispose()
            Write-Progress -Id 15 -Activity $activity -Completed
        }
    } finally {
        $stream.Dispose()
    }
}
# Сверяет SHA-256 двух ZIP по блокам, показывает реальный процент и
# позволяет остановить длительную проверку клавишей 0.
function Assert-CopiedZipHash([string]$Source,[string]$Destination) {
    $srcFile = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    $dstFile = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    if ($srcFile.PSIsContainer -or $dstFile.PSIsContainer -or $srcFile.Length -ne $dstFile.Length) {
        throw 'ZIP после копирования имеет другой размер или не является файлом.'
    }
    $hashSrc = [Security.Cryptography.SHA256]::Create()
    $hashDst = [Security.Cryptography.SHA256]::Create()
    $streamSrc = $null
    $streamDst = $null
    $bufferSrc = New-Object byte[] (1024 * 1024)
    $bufferDst = New-Object byte[] (1024 * 1024)
    [UInt64]$done = 0
    try {
        $streamSrc = [IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $streamDst = [IO.File]::Open($Destination,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sourceLength = $streamSrc.Length
        if ($sourceLength -ne $streamDst.Length) { throw 'ZIP изменился перед сверкой.' }
        Write-OperationReport 'ПРОВЕРКА' ('Сверка исходника и копии ZIP по SHA-256, размер каждого файла {0} байт.' -f $sourceLength)
        Write-Progress -Id 5 -Activity 'Проверка ZIP после копирования' -Status 'Чтение исходника и копии' -PercentComplete 0
        while (($n = $streamSrc.Read($bufferSrc,0,$bufferSrc.Length)) -gt 0) {
            $readDst = 0
            while ($readDst -lt $n) {
                $got = $streamDst.Read($bufferDst,$readDst,$n-$readDst)
                if ($got -le 0) { throw 'Сетевая копия ZIP оборвалась при сверке.' }
                $readDst += $got
            }
            [void]$hashSrc.TransformBlock($bufferSrc,0,$n,$bufferSrc,0)
            [void]$hashDst.TransformBlock($bufferDst,0,$n,$bufferDst,0)
            $done = [UInt64]($done + [UInt64]$n)
            $percent = if ($sourceLength -gt 0) { [int][Math]::Floor(100.0 * $done / [double]$sourceLength) } else { 100 }
            Write-Progress -Id 5 -Activity 'Проверка ZIP после копирования' -Status ('Сверено {0} из {1}' -f (Format-ByteSize $done),(Format-ByteSize $sourceLength)) -PercentComplete $percent
            if (Test-RunningProcessStopRequest 'проверку ZIP' 5) {
                throw [System.OperationCanceledException]::new('Проверка ZIP остановлена пользователем.')
            }
        }
        if ($streamDst.Read($bufferDst,0,1) -ne 0) { throw 'В ZIP после копирования есть дополнительные байты.' }
        $emptyBlock = [byte[]]@()
        [void]$hashSrc.TransformFinalBlock($emptyBlock,0,0)
        [void]$hashDst.TransformFinalBlock($emptyBlock,0,0)
        $original = [BitConverter]::ToString($hashSrc.Hash).Replace('-','')
        $copy = [BitConverter]::ToString($hashDst.Hash).Replace('-','')
        if ($original -ne $copy) { throw 'SHA-256 ZIP не совпал после копирования. Архив не опубликован.' }
        Write-OperationReport 'ПРОВЕРКА' ('ZIP после копирования совпал по SHA-256, сверено {0} байт.' -f $done)
        return $original
    } finally {
        Write-Progress -Id 5 -Activity 'Проверка ZIP после копирования' -Completed
        if ($streamSrc) { $streamSrc.Dispose() }
        if ($streamDst) { $streamDst.Dispose() }
        $hashSrc.Dispose()
        $hashDst.Dispose()
    }
}
# Проверка едина для ZIP, путей в манифестах и архивов-каталогов.
function Assert-WindowsPathComponent([string]$Part) {
    if (-not $Part -or $Part.EndsWith('.') -or $Part.EndsWith(' ') -or
        $Part -match '[\x00-\x1f\\/:*?"<>|]' -or
        $Part -match '^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³]) *(\..*)?$') {
        throw ('Недопустимый компонент пути Windows: ' + $Part)
    }
}
function Get-WindowsRelativePathParts([string]$RelativePath) {
    $parts = $RelativePath -split '[\\/]'
    foreach ($part in $parts) { Assert-WindowsPathComponent $part }
    return $parts
}

# Проверяем каждый компонент до входа в каталог. Отсутствующий объект
# или точку повторной обработки считаем недоступными внутри профиля.
function Get-ProfileDataItem([string]$ProfilePath,[string]$RelativePath) {
    $parts = @(Get-WindowsRelativePathParts $RelativePath)
    try {
        $item = Get-Item -LiteralPath $ProfilePath -Force -ErrorAction Stop
        foreach ($part in $parts) {
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
            $item = Get-Item -LiteralPath ([IO.Path]::Combine($item.FullName,$part)) -Force -ErrorAction Stop
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $null }
        return $item
    } catch [System.Management.Automation.ItemNotFoundException] { return $null }
}
# Проверяем существующие предки до создания каталога или копирования данных.
function Assert-NoReparseAncestor([string]$Path) {
    $pending = [Collections.Generic.Stack[string]]::new()
    for ($current = [IO.Path]::GetFullPath($Path); $current; $current = [IO.Path]::GetDirectoryName($current)) {
        $pending.Push($current)
    }
    while ($pending.Count -gt 0) {
        try { $item = Get-Item -LiteralPath $pending.Pop() -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { return }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw ('Путь проходит через ссылку: ' + $item.FullName)
        }
    }
}
# Формирует карту файлов готового архива, не следуя ссылкам/junction.
# При проверке сетевой публикации нужно сравнивать именно ВСЕ файлы,
# включая .mig, метаданные, контрольные реестры и дополнительные данные.
function Get-ArchiveFileMap([string]$ArchiveRoot) {
    Assert-NoReparseAncestor $ArchiveRoot
    $root = Get-Item -LiteralPath $ArchiveRoot -Force -ErrorAction Stop
    if (-not $root.PSIsContainer) { throw ('Архив не является каталогом: ' + $ArchiveRoot) }
    $base = [IO.Path]::GetFullPath([string]$root.FullName)
    $separator = [IO.Path]::DirectorySeparatorChar
    $files = @{}
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($base)
    $activity = 'Обход содержимого архива'
    $directories = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Write-Progress -Id 13 -Activity $activity -Status 'Подсчёт папок и файлов' -PercentComplete -1
    try {
        while ($pending.Count -gt 0) {
            $current = $pending.Pop()
            $directories++
            foreach ($item in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
                Assert-WindowsPathComponent $item.Name
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw ('В архиве обнаружена ссылка, проверка остановлена: ' + $item.FullName)
                }
                if ($item.PSIsContainer) {
                    $pending.Push([string]$item.FullName)
                    continue
                }
                $relative = ([string]$item.FullName).Substring($base.Length).TrimStart($separator)
                if (-not $relative -or $files.ContainsKey($relative)) {
                    throw ('Неоднозначное имя файла в архиве: ' + $item.FullName)
                }
                $files[$relative] = [pscustomobject]@{ Path=[string]$item.FullName; Length=[long]$item.Length }
            }
            if ($clock.ElapsedMilliseconds -ge 250) {
                Write-Progress -Id 13 -Activity $activity -Status ('Проверено папок {0}, файлов {1}' -f $directories,$files.Count) -PercentComplete -1
                $clock.Restart()
            }
        }
    } catch {
        Write-OperationReport 'ДИАГНОСТИКА' ('Обход папки архива прерван. Проверено папок {0}, файлов {1}.' -f $directories,$files.Count)
        throw
    } finally {
        Write-Progress -Id 13 -Activity $activity -Completed
    }
    Write-OperationReport 'ДИАГНОСТИКА' ('Обход папки архива завершён. Проверено папок {0}, файлов {1}.' -f $directories,$files.Count)
    return $files
}

# Встроенный ZIP .NET не требует 7-Zip, WinRAR или сторонних программ.
function Initialize-ZipSupport {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
}
# Строго проверяет имена и размеры ZIP ДО распаковки в административном процессе.
# Защищает от путей с .., абсолютных путей, ссылок и повторяющихся имён.
function Get-ProfileZipInfo([string]$ZipPath) {
    Initialize-ZipSupport
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try { return Read-ProfileZipInfo $zip }
    finally { $zip.Dispose() }
}

function Read-BoundedArchiveMetadata([IO.Stream]$Stream,[long]$Length) {
    if ($Length -le 0 -or $Length -gt 2MB) { throw 'Размер metadata.json должен быть от 1 байта до 2 МБ.' }
    # ZIP сообщает заявленную длину, поэтому проверяем и фактический поток.
    $bytes = [byte[]]::new([int]$Length)
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $read = $Stream.Read($bytes,$offset,$bytes.Length - $offset)
        if ($read -le 0) { throw 'metadata.json обрезан.' }
        $offset += $read
    }
    if ($Stream.ReadByte() -ne -1) { throw 'Размер metadata.json не совпадает с содержимым.' }
    $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)
    try {
        $json = $reader.ReadToEnd().Trim()
        if (-not $json.StartsWith('{')) { throw 'metadata.json должен содержать один JSON-объект.' }
        $metadata = $json | ConvertFrom-Json -ErrorAction Stop
        if ($metadata -isnot [pscustomobject]) { throw 'metadata.json должен содержать один JSON-объект.' }
        return $metadata
    } finally { $reader.Dispose() }
}

function Read-ArchiveMetadataFile([string]$Path) {
    Assert-NoReparseAncestor $Path
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { return Read-BoundedArchiveMetadata $stream $stream.Length }
    finally { $stream.Dispose() }
}

function Read-ProfileZipInfo([IO.Compression.ZipArchive]$Zip) {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $filePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [UInt64]$expanded = 0
    [int]$storeFiles = 0
    $metaEntry = $null
    $activity = 'Проверка структуры ZIP'
    $checked = 0
    $total = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Write-Progress -Id 13 -Activity $activity -Status 'Чтение оглавления архива' -PercentComplete -1
    try {
        $entries = $Zip.Entries
        $total = $entries.Count
        if ($total -gt 1000000) { throw 'Слишком много записей в ZIP.' }
        Write-Progress -Id 13 -Activity $activity -Status ('Проверяется {0} записей' -f $total) -PercentComplete 0
        foreach ($entry in $entries) {
            if ($clock.ElapsedMilliseconds -ge 250) {
                $percent = [int][Math]::Floor(100.0 * $checked / $total)
                Write-Progress -Id 13 -Activity $activity -Status ('Проверено {0} из {1} записей' -f $checked,$total) -PercentComplete $percent
                $clock.Restart()
            }
            $checked++
            $rel = [string]$entry.FullName
            $isDir = $rel.EndsWith('/')
            $name = if ($isDir) { $rel.Substring(0,$rel.Length - 1) } else { $rel }
            if (-not $seen.Add($name)) { throw ('Повторяющееся имя в ZIP: ' + $rel) }
            foreach ($part in $name.Split('/')) { Assert-WindowsPathComponent $part }
            # Windows reparse-point и Unix symlink внутри ZIP запрещены.
            if (($entry.ExternalAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000)) {
                throw ('Ссылка в ZIP запрещена: ' + $rel)
            }
            for ($slash = $name.LastIndexOf('/'); $slash -ge 0; $slash = $parent.LastIndexOf('/')) {
                $parent = $name.Substring(0,$slash)
                if ($filePaths.Contains($parent)) { throw ('Файл ZIP используется как каталог: ' + $parent) }
                if (-not $directories.Add($parent)) { break }
            }
            if ($isDir) {
                if ($entry.Length -ne 0) { throw ('Каталог ZIP содержит данные: ' + $rel) }
                [void]$directories.Add($name)
                continue
            }
            if ($directories.Contains($name)) { throw ('Файл ZIP используется как каталог: ' + $name) }
            [void]$filePaths.Add($name)
            if ($entry.Length -lt 0 -or $expanded -gt ([UInt64]::MaxValue - [UInt64]$entry.Length)) {
                throw 'Недопустимый размер ZIP.'
            }
            $expanded = [UInt64]($expanded + [UInt64]$entry.Length)
            if ($name -ceq 'metadata.json') { $metaEntry = $entry }
            if ($name -match '^Store/.+\.mig$') { $storeFiles++ }
        }
        if (-not $metaEntry -or $storeFiles -ne 1) {
            throw 'ZIP должен содержать metadata.json размером до 2 МБ и ровно одно USMT-хранилище.'
        }
        $stream = $metaEntry.Open()
        try { $meta = Read-BoundedArchiveMetadata $stream $metaEntry.Length }
        finally { $stream.Dispose() }
        Write-Progress -Id 13 -Activity $activity -Status 'Записи и метаданные проверены' -PercentComplete 100
    } catch {
        Write-OperationReport 'ДИАГНОСТИКА' ('Проверка структуры ZIP прервана на записи {0} из {1}.' -f $checked,$total)
        throw
    } finally {
        Write-Progress -Id 13 -Activity $activity -Completed
    }
    Write-OperationReport 'ПРОВЕРКА' ('Структура ZIP проверена. Записей {0}, файлов {1}, объём распаковки {2} байт.' -f $total,$filePaths.Count,$expanded)
    return [pscustomobject]@{ Metadata=$meta; ExpandedBytes=$expanded; Files=$filePaths.Count }
}
# Сжимает каталог в один ZIP с поддержкой больших файлов (ZIP64) и клавиши 0.
function Compress-ProfileArchive([string]$Source,[string]$ZipPath) {
    Initialize-ZipSupport
    Write-Host 'Во время упаковки ZIP нажмите 0 без Enter, чтобы запросить отмену.' -ForegroundColor Yellow
    $items = Get-ArchiveFileMap $Source
    if ($items.Count -eq 0) { throw 'Нечего упаковывать: каталог архива пуст.' }
    [UInt64]$total = 0
    foreach ($f in $items.Values) { $total = [UInt64]($total + [UInt64]$f.Length) }
    [UInt64]$done = 0
    [int]$fileCount = 0
    $buffer = New-Object byte[] (1024 * 1024)
    $zipStream = [IO.File]::Open($ZipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $zip = $null
    try {
        $zip = [IO.Compression.ZipArchive]::new($zipStream,[IO.Compression.ZipArchiveMode]::Create,$false,[Text.Encoding]::UTF8)
        Write-OperationReport 'АРХИВ' ('Начата упаковка ZIP. Файлов {0}, исходный объём {1} байт.' -f $items.Count,$total)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Write-Progress -Id 6 -Activity 'Упаковка профиля в ZIP' -Status 'Запись первых файлов' -PercentComplete 0
        foreach ($rel in @($items.Keys | Sort-Object)) {
            $file = $items[$rel]
            $entryName = $rel.Replace('\','/')
            $level = if ($entryName -match '(?i)\.(mig|img|zip|7z|jpg|jpeg|png|mp4)$') {
                [IO.Compression.CompressionLevel]::NoCompression
            } else { [IO.Compression.CompressionLevel]::Optimal }
            $entry = $zip.CreateEntry($entryName,$level)
            $entryStream = $entry.Open()
            try {
                $inputStream = [IO.File]::Open($file.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                try {
                    while (($n = $inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                        $entryStream.Write($buffer,0,$n)
                        $done = [UInt64]($done + [UInt64]$n)
                        if ($clock.ElapsedMilliseconds -ge 250) {
                            $percent = if ($total -gt 0) { [int][Math]::Min(99,[Math]::Floor(100.0 * $done / $total)) } else { 0 }
                            Write-Progress -Id 6 -Activity 'Упаковка профиля в ZIP' -Status ('Записано {0} из {1}, готовых файлов {2} из {3}' -f (Format-ByteSize $done),(Format-ByteSize $total),$fileCount,$items.Count) -PercentComplete $percent
                            $clock.Restart()
                        }
                        if (Test-RunningProcessStopRequest 'упаковку ZIP' 6) {
                            throw [System.OperationCanceledException]::new('Упаковка ZIP остановлена пользователем.')
                        }
                    }
                } finally { $inputStream.Dispose() }
            } finally { $entryStream.Dispose() }
            $fileCount++
        }
        Write-Progress -Id 6 -Activity 'Упаковка профиля в ZIP' -Status ('Обработано файлов {0}' -f $fileCount) -PercentComplete 100
    } catch {
        Write-OperationReport 'ДИАГНОСТИКА' ('Упаковка ZIP прервана. Записано {0} из {1} байт, завершено файлов {2} из {3}.' -f $done,$total,$fileCount,$items.Count)
        throw
    } finally {
        Write-Progress -Id 6 -Activity 'Упаковка профиля в ZIP' -Completed
        if ($zip) { $zip.Dispose() }
        $zipStream.Dispose()
    }
    $info = Get-ProfileZipInfo $ZipPath
    if ($info.Files -ne $items.Count -or $info.ExpandedBytes -ne $total) {
        throw 'Упаковка ZIP не прошла проверку состава и размеров.'
    }
    Write-OperationReport 'АРХИВ' ('Создан ZIP: ' + (Format-ByteSize ([UInt64](Get-Item -LiteralPath $ZipPath).Length)) +
        '; файлов: ' + $info.Files + '; исходный объём: ' + (Format-ByteSize $total))
}
# Распаковывает ZIP в пустой локальный каталог; каждый путь проверен заранее.
function Expand-ProfileArchive([string]$ZipPath,[string]$Destination) {
    Initialize-ZipSupport
    Write-Host 'Во время распаковки ZIP нажмите 0 без Enter, чтобы запросить отмену.' -ForegroundColor Yellow
    $separator = [IO.Path]::DirectorySeparatorChar
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd($separator)
    $prefix = $root + $separator
    [UInt64]$done = 0
    $buffer = New-Object byte[] (1024 * 1024)
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    $fileCount = 0
    try {
        # Проверяем тот же открытый ZIP, который будем читать. На Windows
        # файловый дескриптор не разрешает в это время запись или подмену.
        $info = Read-ProfileZipInfo $zip
        if (Test-Path -LiteralPath $root) { throw 'Каталог распаковки уже существует.' }
        Assert-NoReparseAncestor $root
        $free = Get-PathFreeBytes ([IO.Path]::GetDirectoryName($root))
        Write-OperationReport 'АРХИВ' ('Подготовка к распаковке ZIP. Файлов {0}, объём {1} байт, свободно {2} байт, резерв 1 ГБ.' -f $info.Files,$info.ExpandedBytes,$free)
        if ([double]$free -lt ([double]$info.ExpandedBytes + 1GB)) {
            throw 'Недостаточно места для распаковки открытого ZIP с резервом 1 ГБ.'
        }
        [void][IO.Directory]::CreateDirectory($root)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Write-Progress -Id 6 -Activity 'Распаковка архива' -Status 'Чтение первых файлов' -PercentComplete 0
        foreach ($entry in $zip.Entries) {
            $full = [IO.Path]::GetFullPath((Join-Path $root ($entry.FullName.Replace([char]'/', $separator))))
            if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
                throw ('ZIP содержит путь за пределами папки распаковки: ' + $entry.FullName)
            }
            if ($entry.FullName.EndsWith('/')) {
                [void][IO.Directory]::CreateDirectory($full)
                continue
            }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
            $inputStream = $entry.Open()
            try {
                $outputStream = [IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try {
                    [UInt64]$entryBytes = 0
                    while (($n = $inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                        $entryBytes = [UInt64]($entryBytes + [UInt64]$n)
                        if ($entryBytes -gt [UInt64]$entry.Length) { throw ('Размер ZIP не совпадает с данными: ' + $entry.FullName) }
                        $outputStream.Write($buffer,0,$n)
                        $done = [UInt64]($done + [UInt64]$n)
                        if ($clock.ElapsedMilliseconds -ge 250) {
                            $percent = if ($info.ExpandedBytes -gt 0) { [int][Math]::Min(99,[Math]::Floor(100.0 * $done / $info.ExpandedBytes)) } else { 0 }
                            Write-Progress -Id 6 -Activity 'Распаковка архива' -Status ('Распаковано {0} из {1}, готовых файлов {2} из {3}' -f (Format-ByteSize $done),(Format-ByteSize $info.ExpandedBytes),$fileCount,$info.Files) -PercentComplete $percent
                            $clock.Restart()
                        }
                        if (Test-RunningProcessStopRequest 'распаковку ZIP' 6) {
                            throw [System.OperationCanceledException]::new('Распаковка ZIP остановлена пользователем.')
                        }
                    }
                    if ($entryBytes -ne [UInt64]$entry.Length) { throw ('Файл ZIP распакован не полностью: ' + $entry.FullName) }
                } finally { $outputStream.Dispose() }
            } finally { $inputStream.Dispose() }
            $fileCount++
        }
        Write-Progress -Id 6 -Activity 'Распаковка архива' -Status ('Обработано файлов {0}' -f $fileCount) -PercentComplete 100
    } catch {
        Write-OperationReport 'ДИАГНОСТИКА' ('Распаковка ZIP прервана. Распаковано {0} байт, завершено файлов {1}.' -f $done,$fileCount)
        throw
    } finally {
        Write-Progress -Id 6 -Activity 'Распаковка архива' -Completed
        $zip.Dispose()
    }
    if ($done -ne $info.ExpandedBytes) { throw 'Общий размер распакованных файлов не совпал с ZIP.' }
    Write-OperationReport 'АРХИВ' ('ZIP распакован: ' + $info.Files + ' файлов, ' + (Format-ByteSize $done))
}
# UsmtUtils /verify:all уже выполнил проверку ЛОКАЛЬНОГО .mig.
# Для сетевой публикации сравниваем SHA-256 каждого файла с исходником,
# поскольку UsmtUtils может не принять UNC-путь и вернуть код 27.
function Assert-NetworkArchiveCopy([string]$Source,[string]$Destination) {
    Write-Host 'Проверка сетевой копии: SHA-256 всех файлов...' -ForegroundColor Cyan
    $sourceFiles = Get-ArchiveFileMap $Source
    $targetFiles = Get-ArchiveFileMap $Destination
    if ($sourceFiles.Count -eq 0) { throw 'Исходный архив пуст. Публикация остановлена.' }
    if ($sourceFiles.Count -ne $targetFiles.Count) {
        throw ('В сетевой копии другое количество файлов: исходно {0}, в сети {1}.' -f $sourceFiles.Count,$targetFiles.Count)
    }
    [int]$checked = 0
    [UInt64]$checkedBytes = 0
    Write-OperationReport 'ПРОВЕРКА' ('Начата сверка SHA-256 сетевой копии. Файлов {0}.' -f $sourceFiles.Count)
    Write-Progress -Id 5 -Activity 'Проверка сетевой копии' -Status 'Чтение первых файлов' -PercentComplete 0
    try {
        foreach ($relative in @($sourceFiles.Keys | Sort-Object)) {
            if (-not $targetFiles.ContainsKey($relative)) {
                throw ('В сетевой копии отсутствует файл: ' + $relative)
            }
            $original = $sourceFiles[$relative]
            $copy = $targetFiles[$relative]
            if ($original.Length -ne $copy.Length) {
                throw ('Не совпадает размер файла сетевой копии: ' + $relative)
            }
            try {
                $originalHash = Get-ExactFileSha256 $original.Path
                $copyHash = Get-ExactFileSha256 $copy.Path
            } catch {
                throw ('Не удалось вычислить SHA-256 файла ' + $relative + ': ' + $_.Exception.Message)
            }
            if ($originalHash -ne $copyHash) {
                throw ('Не совпадает SHA-256 файла сетевой копии: ' + $relative)
            }
            $checked++
            $checkedBytes = [UInt64]($checkedBytes + [UInt64]$original.Length)
            Write-Progress -Id 5 -Activity 'Проверка сетевой копии' -Status ('Сверено файлов: ' + $checked + ' из ' + $sourceFiles.Count) -PercentComplete ([int][Math]::Floor(100.0 * $checked / $sourceFiles.Count))
            if (Test-RunningProcessStopRequest 'проверку сетевой копии' 5) {
                throw [System.OperationCanceledException]::new('Проверка сетевой копии остановлена пользователем.')
            }
        }
    } catch {
        Write-OperationReport 'ДИАГНОСТИКА' ('Проверка сетевой копии прервана. Сверено файлов {0} из {1}, байт {2}.' -f $checked,$sourceFiles.Count,$checkedBytes)
        throw
    } finally {
        Write-Progress -Id 5 -Activity 'Проверка сетевой копии' -Completed
    }
    Write-OperationReport 'ПРОВЕРКА' ('Сетевая копия: SHA-256 совпал для {0} файлов ({1}).' -f $checked,(Format-ByteSize $checkedBytes))
}
