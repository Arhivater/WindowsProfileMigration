# Загружаем библиотеку только при выборе защищённого архива.
function Initialize-WpmEncryption {
    if ('WindowsProfileMigration.OpenPgpArchive' -as [type]) { return }
    $dll = Join-Path $PSScriptRoot 'Vendor\BouncyCastle.Cryptography.dll'
    if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne '4F96977E9C67334742C683410B3A361258219F0D3084A5E0BC10FBA96CF23A0D') {
        throw 'Контрольная сумма библиотеки шифрования не совпала. Распакуйте комплект заново.'
    }
    [void][Reflection.Assembly]::LoadFrom($dll)
    Add-Type -Path (Join-Path $PSScriptRoot 'OpenPgpArchive.cs') -ReferencedAssemblies $dll -ErrorAction Stop
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

# Читаем исходник без разрешения на запись. При ошибке удаляем только созданную здесь копию.
function Convert-WpmArchive([string]$Source, [string]$Destination, [Security.SecureString]$Password, [switch]$Decrypt) {
    Initialize-WpmEncryption
    $reader = [IO.File]::Open($Source,'Open','Read','Read')
    $created = $false
    $complete = $false
    try {
        $writer = [IO.File]::Open($Destination,'CreateNew','Write','None')
        $created = $true
        try {
            $cancel = [Func[bool]]{ Test-RunningProcessStopRequest 'обработку защищённого архива' 5 }
            if ($Decrypt) { [WindowsProfileMigration.OpenPgpArchive]::Decrypt($reader,$writer,$Password,$cancel) }
            else { [WindowsProfileMigration.OpenPgpArchive]::Encrypt($reader,$writer,$Password,$cancel) }
            $writer.Flush($true)
            $complete = $true
        } finally { $writer.Dispose() }
    } catch {
        if ($_.Exception.GetBaseException() -is [OperationCanceledException]) { throw $_.Exception.GetBaseException() }
        if ($Decrypt) { throw 'Не удалось открыть архив. Проверьте пароль, целостность файла и свободное место.' }
        throw
    } finally {
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
    $cache = [IO.FileStream]::new($temp,'CreateNew','ReadWrite','None',65536,'DeleteOnClose')
    try {
        $inputFile = [IO.File]::Open($Path,'Open','Read','Read')
        try {
            [WindowsProfileMigration.OpenPgpArchive]::Decrypt($inputFile,$cache,$Password,$null)
        } finally { $inputFile.Dispose() }
        $cache.Position = 0
        $zip = [IO.Compression.ZipArchive]::new($cache,'Read',$true)
        try { return Read-ProfileZipInfo $zip } finally { $zip.Dispose() }
    } finally { $cache.Dispose() }
}
