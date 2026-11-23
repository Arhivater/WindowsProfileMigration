# Загружаем библиотеку только при выборе защищённого архива.
function Initialize-WpmEncryption {
    if ('WindowsProfileMigration.OpenPgpArchive' -as [type]) { return }
    $dll = Join-Path $PSScriptRoot 'Vendor\BouncyCastle.Cryptography.dll'
    if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne '4F96977E9C67334742C683410B3A361258219F0D3084A5E0BC10FBA96CF23A0D') {
        throw 'Контрольная сумма библиотеки шифрования не совпала. Распакуйте комплект заново.'
    }
    $activity = 'Подготовка защиты архива'
    Write-Progress -Id 15 -Activity $activity -Status 'Загрузка библиотеки OpenPGP' -PercentComplete -1
    try {
        [void][Reflection.Assembly]::LoadFrom($dll)
        Add-Type -Path (Join-Path $PSScriptRoot 'OpenPgpArchive.cs') -ReferencedAssemblies $dll -ErrorAction Stop
        Write-OperationReport 'АРХИВ' 'Библиотека OpenPGP загружена, контрольная сумма подтверждена.'
    } finally {
        Write-Progress -Id 15 -Activity $activity -Completed
    }
}

function Test-WpmProtectedArchive([string]$Path) {
    return $Path.EndsWith('.wpm.pgp',[StringComparison]::OrdinalIgnoreCase)
}

function Read-WpmArchivePassword {
    $secret = Read-Host 'Пароль архива (пустой ввод отменяет действие)' -AsSecureString
    if (-not $secret -or $secret.Length -eq 0) {
        if ($secret) { $secret.Dispose() }
        throw [OperationCanceledException]::new('Ввод пароля отменён.')
    }
    return $secret
}

function Read-WpmExportPassword {
    Write-Host '1. Обычный ZIP   2. Защитить архив паролем   0. Отмена'
    $mode = Choice 'Защита архива' 2
    if ($mode -eq 0) { throw [OperationCanceledException]::new('Экспорт отменён.') }
    if ($mode -eq 1) { return }
    Initialize-WpmEncryption
    while ($true) {
        $first = Read-WpmArchivePassword
        $again = $null
        $accepted = $false
        try {
            Write-Host 'Введите тот же пароль ещё раз.'
            $again = Read-WpmArchivePassword
            $accepted = [WindowsProfileMigration.OpenPgpArchive]::SamePassword($first,$again)
            if ($accepted) { return $first }
            Write-Host 'Пароли различаются. Повторите ввод.'
        } finally {
            if ($again) { $again.Dispose() }
            if (-not $accepted) { $first.Dispose() }
        }
    }
}

# OpenPGP содержит несжатый ZIP, поэтому его размер служит верхней границей для временной копии.
function Assert-WpmDecryptionSpace([long]$ArchiveLength, [string]$Destination) {
    $volume = [IO.Path]::GetPathRoot($Destination)
    $free = Get-PathFreeBytes $volume
    $needed = [decimal]$ArchiveLength + 1GB
    Write-OperationReport 'АРХИВ' ('Проверка места для расшифровки. Размер входа {0} байт, нужно {1}, доступно {2}.' -f $ArchiveLength,$needed,$free)
    if ($free -lt $needed) {
        throw ('Недостаточно места для расшифровки архива на ' + $volume + '. Нужно не менее ' +
            (Format-ByteSize ([UInt64]$needed)) + ', доступно ' + (Format-ByteSize $free) + '.')
    }
}

# Считаем байты входного файла. 100% показываем после подтверждения результата.
function Write-WpmCryptoProgress([string]$Activity, [IO.Stream]$InputStream, [Diagnostics.Stopwatch]$Clock) {
    if ($Clock.ElapsedMilliseconds -lt 250) { return }
    $length = $InputStream.Length
    $position = $InputStream.Position
    $percent = if ($length -gt 0) { [int][Math]::Min(99,[Math]::Floor(100.0 * $position / $length)) } else { 0 }
    Write-Progress -Id 15 -Activity $Activity -Status ('Прочитано {0} из {1} байт' -f $position,$length) -PercentComplete $percent
    $Clock.Restart()
}

# Читаем исходник без разрешения на запись. При ошибке удаляем только созданную здесь копию.
function Convert-WpmArchive([string]$Source, [string]$Destination, [Security.SecureString]$Password, [switch]$Decrypt) {
    Initialize-WpmEncryption
    if ($Decrypt) { Assert-NoReparseAncestor $Source }
    $reader = [IO.File]::Open($Source,'Open','Read','Read')
    $created = $false
    $complete = $false
    $activity = if ($Decrypt) { 'Расшифровка архива' } else { 'Шифрование архива' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $length = $reader.Length
    try {
        Write-OperationReport 'АРХИВ' ('Начало операции «{0}». Размер входного файла {1} байт.' -f $activity,$length)
        Write-Progress -Id 15 -Activity $activity -Status 'Подготовка потока' -PercentComplete 0
        if ($Decrypt) { Assert-WpmDecryptionSpace $reader.Length $Destination }
        try {
            $writer = [IO.File]::Open($Destination,'CreateNew','Write','None')
            $created = $true
            try {
                $cancel = [Func[bool]]{
                    Write-WpmCryptoProgress $activity $reader $clock
                    Test-RunningProcessStopRequest 'обработку защищённого архива' 15
                }
                if ($Decrypt) { [WindowsProfileMigration.OpenPgpArchive]::Decrypt($reader,$writer,$Password,$cancel) }
                else { [WindowsProfileMigration.OpenPgpArchive]::Encrypt($reader,$writer,$Password,$cancel) }
                $writer.Flush($true)
                $outputBytes = $writer.Length
                $complete = $true
            } finally { $writer.Dispose() }
            Write-Progress -Id 15 -Activity $activity -Status 'Результат записан' -PercentComplete 100
            Write-OperationReport 'АРХИВ' ('Операция «{0}» завершилась. Записано {1} байт.' -f $activity,$outputBytes)
        } catch {
            $cause = $_.Exception.GetBaseException()
            Write-OperationReport 'ДИАГНОСТИКА' ('Операция «{0}» прервана. Тип ошибки {1}.' -f $activity,$cause.GetType().Name)
            if ($cause -is [OperationCanceledException]) { throw $cause }
            if ($Decrypt) { throw 'Не удалось открыть архив. Проверьте пароль, целостность файла и свободное место.' }
            throw
        }
    } finally {
        Write-Progress -Id 15 -Activity $activity -Completed
        $reader.Dispose()
        if ($created -and -not $complete) { [IO.File]::Delete($Destination) }
    }
}

# Расшифровываем в закрытой папке и читаем ZIP только после проверки OpenPGP.
function Get-WpmTransferArchiveInfo([string]$Path, [Security.SecureString]$Password) {
    if (-not (Test-WpmProtectedArchive $Path)) { return Get-ProfileZipInfo $Path }
    Initialize-WpmEncryption
    Initialize-ZipSupport
    Initialize-WpmWorkDirectory $Script:WpmStagingRoot
    $temp = Join-Path $Script:WpmStagingRoot ([guid]::NewGuid().ToString('N') + '.tmp')
    Assert-NoReparseAncestor $Path
    $inputFile = [IO.File]::Open($Path,'Open','Read','Read')
    $activity = 'Проверка защищённого архива перед передачей'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        Write-OperationReport 'АРХИВ' ('Начата проверка защищённого архива перед передачей. Размер {0} байт.' -f $inputFile.Length)
        Write-Progress -Id 15 -Activity $activity -Status 'Подготовка потока' -PercentComplete 0
        Assert-WpmDecryptionSpace $inputFile.Length $temp
        $cache = [IO.FileStream]::new($temp,'CreateNew','ReadWrite','None',65536,'DeleteOnClose')
        try {
            $cancel = [Func[bool]]{
                Write-WpmCryptoProgress $activity $inputFile $clock
                Test-RunningProcessStopRequest 'расшифровку сетевого архива' 15
            }
            try { [WindowsProfileMigration.OpenPgpArchive]::Decrypt($inputFile,$cache,$Password,$cancel) }
            catch {
                $cause = $_.Exception.GetBaseException()
                Write-OperationReport 'ДИАГНОСТИКА' ('Защищённый архив не подготовлен к передаче. Тип ошибки {0}.' -f $cause.GetType().Name)
                if ($cause -is [OperationCanceledException]) { throw $cause }
                throw 'Не удалось открыть архив. Проверьте пароль, целостность файла и свободное место.'
            }
            Write-Progress -Id 15 -Activity $activity -Status 'Целостность защищённого архива проверена' -PercentComplete 100
            Write-Progress -Id 15 -Activity $activity -Completed
            Write-OperationReport 'АРХИВ' ('Расшифровано {0} байт. Проверяется структура ZIP.' -f $cache.Length)
            $cache.Position = 0
            $zip = [IO.Compression.ZipArchive]::new($cache,'Read',$true)
            try { return Read-ProfileZipInfo $zip } finally { $zip.Dispose() }
        } finally { $cache.Dispose() }
    } finally {
        Write-Progress -Id 15 -Activity $activity -Completed
        $inputFile.Dispose()
    }
}
