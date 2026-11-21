# При сетевом переносе получатель сверяет архив, затем запускает импорт.

# Подготовка компьютера-получателя. Пользователь явно разрешает настройку WinRM.
# Сетевые профили Public, TrustedHosts и ослабление UAC автоматически не меняются.
function Prepare-RemoteReceiver {
    Title 'ПОДГОТОВКА КОМПЬЮТЕРА К ПРИЁМУ ПО СЕТИ'
    Write-Host ('Компьютер-получатель: ' + $env:COMPUTERNAME)
    Write-Host 'Настройка разрешит удалённое администрирование PowerShell для подключений, допускаемых Windows Firewall.'
    Write-Host 'Для домашней сети используйте сетевой профиль «Частная», в компании - «Доменная».'
    Write-Host 'На сервере и клиенте по-прежнему потребуются права администратора.'
    if (-not (Confirm 'Разрешить PowerShell Remoting на ЭТОМ компьютере?')) {
        Write-OperationReport 'ОТМЕНА' 'Подготовка WinRM отклонена.'
        return
    }
    Enable-PSRemoting -Force -ErrorAction Stop
    Advance-OperationStage 'WinRM настроен по правилам Windows'
    $listeners = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue)
    Write-OperationReport 'СЕТЬ' ('Слушателей WinRM: ' + $listeners.Count)
    Write-Host 'Приём сетевого переноса включён. На исходном ПК выберите пункт 5.' -ForegroundColor Green
    Write-Host ('Имя этого ПК: ' + $env:COMPUTERNAME)
    Write-Host 'Для другого домена или IP используйте сертификат WinRM HTTPS либо согласованную администраторами настройку доверия к конкретному узлу.'
    Finish-OperationReport 'УСПЕШНО'
}

# После отключения питания исходный готовый ZIP остаётся на диске.
# Новый запуск повторяет сетевой этап, не сканируя исходный профиль снова.
function Select-DirectTransferArchive {
    $files = @()
    if (Test-Path -LiteralPath $Script:WpmWorkRoot) { Assert-WpmWorkRoot }
    $roots = @(
        (Join-Path $Script:WpmWorkRoot 'DirectTransfers'),
        (Join-Path $env:ProgramData 'WindowsProfileMigration\DirectTransfers')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        Assert-WpmDirectoryChain $root
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Filter '*.zip' -ErrorAction Stop | Sort-Object LastWriteTime -Descending)) {
            try {
                $info = Get-ProfileZipInfo $file.FullName
                Assert-ArchiveMetadata $info.Metadata $true
                $files += [pscustomobject]@{Path=$file.FullName;Name=$file.Name;
                    User=[string]$info.Metadata.SourceAccount;Size=$file.Length;Date=$file.LastWriteTime}
            } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Неполный/повреждённый ZIP пропущен: ' + $file.Name + ': ' + $_.Exception.Message) }
        }
    }
    Title 'ПОВТОР ПРЕРВАННОГО СЕТЕВОГО ПЕРЕНОСА'
    if ($files.Count -eq 0) { Write-Host 'Готовых ZIP для продолжения нет.' -ForegroundColor Yellow; return $null }
    for ($i=0;$i -lt $files.Count;$i++) {
        Write-Host ('{0}. {1} | {2} | {3} | {4:dd.MM.yyyy HH:mm}' -f ($i+1),$files[$i].User,$files[$i].Name,
            (Format-ByteSize ([UInt64]$files[$i].Size)),$files[$i].Date)
    }
    Write-Host '0. Назад'
    $choice = Choice 'Выберите готовый ZIP' $files.Count
    if ($choice -eq 0) { return $null }
    return $files[$choice-1].Path
}

# Объединяет диагностику обоих ПК в один TXT источника. На целевом остаётся
# независимый TXT для аварийного случая, когда сеть оборвалась во время импорта.
function Include-RemoteReport([object]$Session,[string]$RemoteRoot) {
    if (-not $Session -or -not $RemoteRoot) { return }
    $path = Invoke-Command -Session $Session -ArgumentList $RemoteRoot -ErrorAction Stop -ScriptBlock {
        param($root)
        $folder = Join-Path $root 'Reports'
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return }
        Get-ChildItem -LiteralPath $folder -Filter 'Итог_работы_*.txt' -File |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $path) { return }
    Write-OperationReport 'УДАЛЁННЫЙ ОТЧЁТ' ('Полный TXT на получателе: ' + $path)
    $lines = Invoke-Command -Session $Session -ArgumentList $path -ErrorAction Stop -ScriptBlock {
        param($report)
        Get-Content -LiteralPath $report -Encoding UTF8 -ErrorAction Stop
    }
    foreach ($line in @($lines)) { Write-OperationReport 'ОТЧЁТ ЦЕЛЕВОГО ПК' ([string]$line) }
}

# На каждом сеансе проверяем получателя после смены DNS или долгого экспорта.
function Connect-RemoteMigration([hashtable]$Connection,[object]$ExpectedComputer) {
    $newSession = New-PSSession @Connection
    try {
        $computer = Invoke-Command -Session $newSession -ErrorAction Stop -ScriptBlock {
            $machineGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
            [pscustomobject]@{Name=$env:COMPUTERNAME; Identity=[string]$machineGuid; ProgramData=$env:ProgramData}
        }
        if ($computer.Name -ine $ExpectedComputer.Name -or
            $computer.Identity -ine $ExpectedComputer.Identity -or
            $computer.ProgramData -ine $ExpectedComputer.ProgramData) {
            throw 'Сетевой адрес ведёт на другое устройство. Перенос остановлен.'
        }
        return $newSession
    } catch {
        Remove-PSSession -Session $newSession -ErrorAction SilentlyContinue
        throw
    }
}

function Initialize-RemoteMigrationDirectory([object]$Session,[string]$TransferId) {
    Invoke-Command -Session $Session -ArgumentList $TransferId -ErrorAction Stop -ScriptBlock {
        param($id)
        if ($id -cnotmatch '^WPM_[0-9A-F]{24}$') { throw 'Неверный идентификатор прямого переноса.' }
        $programData = Get-Item -LiteralPath $env:ProgramData -Force -ErrorAction Stop
        if (-not $programData.PSIsContainer -or ($programData.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Каталог ProgramData должен быть локальным каталогом без перенаправления.'
        }
        $base = Join-Path $programData.FullName 'WindowsProfileMigration-RemoteDeploy'
        $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        if (-not (Test-Path -LiteralPath $base)) {
            # Права задаются одновременно с созданием каталога.
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner($administrators)
            $acl.SetAccessRuleProtection($true,$false)
            foreach ($identity in @($administrators,$system)) {
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                    $identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
            }
            [void][IO.Directory]::CreateDirectory($base,$acl)
        }
        $rootItem = Get-Item -LiteralPath $base -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw ('Каталог назначения должен быть локальным каталогом без перенаправления: ' + $base)
        }
        $rootAcl = Get-Acl -LiteralPath $base -ErrorAction Stop
        $owner = $rootAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        $trusted = @($administrators.Value,$system.Value)
        if (-not $rootAcl.AreAccessRulesProtected -or $owner -notin $trusted) {
            throw ('Каталог назначения не защищён от подмены: ' + $base)
        }
        foreach ($rule in $rootAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $trusted) {
                throw ('Каталог назначения доступен посторонним: ' + $base)
            }
        }
        $root = Join-Path $base $id
        $backup = Join-Path $root 'Backups'
        foreach ($folder in @($root,$backup)) {
            [void][IO.Directory]::CreateDirectory($folder)
            $item = Get-Item -LiteralPath $folder -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw ('Обнаружено перенаправление временного каталога: ' + $folder)
            }
        }
        return $root
    }
}

function Read-RemoteTransferBlock([IO.Stream]$Source,[byte[]]$Buffer,[int]$Count) {
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Source.Read($Buffer,$offset,$Count-$offset)
        if ($read -eq 0) { throw 'Исходный ZIP завершился до ожидаемой длины.' }
        $offset += $read
    }
}

function Get-RemoteTransferPrefixHash([IO.Stream]$Source,[long]$Length,[byte[]]$Buffer) {
    $remaining = $Length
    $Source.Position = 0
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        while ($remaining -gt 0) {
            $count = [int][Math]::Min([long]$Buffer.Length,$remaining)
            Read-RemoteTransferBlock $Source $Buffer $count
            [void]$hash.TransformBlock($Buffer,0,$count,$Buffer,0)
            $remaining -= $count
        }
        [void]$hash.TransformFinalBlock([byte[]]@(),0,0)
        return [BitConverter]::ToString($hash.Hash).Replace('-','')
    } finally { $hash.Dispose() }
}

function Get-RemoteArchiveReceiver {
    return {
        param($mode,[string]$complete,[long]$expectedLength,[string]$expectedHash,
            [long]$offset,[string]$blockHash,[string]$payload)
        $lockPath = $complete + '.transfer.lock'
        try { $transferLock = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None') }
        catch [IO.IOException] { throw 'Другой сеанс проверяет или записывает этот ZIP. Повторите проверку позже.' }
        try {
            $partial = $complete + '.partial'
            # Пишем только в промежуточный файл. Полный ZIP публикуется
            # переименованием на том же томе после проверки SHA-256.
            foreach ($path in @($complete,$partial)) {
                if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
                    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        throw ('Неожиданный путь сетевого файла: ' + $path)
                    }
                }
            }
            if ($mode -eq 'state') {
                $volume = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($complete))
                if ([IO.File]::Exists($complete)) {
                    $file = [IO.FileInfo]::new($complete)
                    if ($file.Length -ne $expectedLength -or
                        (Get-FileHash -LiteralPath $complete -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expectedHash) {
                        throw 'Существующий полный ZIP не совпадает с источником. Перезапись заблокирована.'
                    }
                    return [pscustomobject]@{Complete=$true; Offset=$expectedLength; Hash=$expectedHash; Free=$volume.AvailableFreeSpace}
                }
                if (-not [IO.File]::Exists($partial)) {
                    return [pscustomobject]@{Complete=$false; Offset=0L; Hash=''; Free=$volume.AvailableFreeSpace}
                }
                $incomplete = [IO.File]::Open($partial,'Open','Read','Read')
                try {
                    if ($incomplete.Length -gt $expectedLength) { throw 'Промежуточный файл больше исходного ZIP.' }
                    $prefixHash = (Get-FileHash -InputStream $incomplete -Algorithm SHA256 -ErrorAction Stop).Hash
                    return [pscustomobject]@{Complete=$false; Offset=$incomplete.Length; Hash=$prefixHash; Free=$volume.AvailableFreeSpace}
                } finally { $incomplete.Dispose() }
            }
            if ($mode -eq 'append') {
                if ([IO.File]::Exists($complete)) { throw 'ZIP уже опубликован другой операцией.' }
                $data = [Convert]::FromBase64String($payload)
                if ($offset -lt 0 -or $data.Length -le 0 -or $data.Length -gt 2MB -or $data.Length -gt ($expectedLength - $offset)) {
                    throw 'Длина блока передачи выходит за границы ZIP.'
                }
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $actual = [BitConverter]::ToString($sha.ComputeHash($data)).Replace('-','') }
                finally { $sha.Dispose() }
                if ($actual -ne $blockHash) { throw 'Контрольная сумма принятого блока не совпала.' }
                $stream = [IO.File]::Open($partial,'OpenOrCreate','Write','None')
                try {
                    if ($stream.Length -ne $offset) { throw 'Позиция записи ZIP изменилась. Требуется повторная проверка.' }
                    $stream.Position = $offset
                    $stream.Write($data,0,$data.Length)
                    $stream.Flush($true)
                    return $stream.Length
                } finally { $stream.Dispose() }
            }
            if ($mode -ne 'finish') { throw 'Неизвестное действие при передаче ZIP.' }
            $pending = [IO.File]::Open($partial,'Open','Read','Read')
            try {
                if ($pending.Length -ne $expectedLength -or
                    (Get-FileHash -InputStream $pending -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expectedHash) {
                    throw 'Размер или SHA-256 принятого ZIP не совпал. Импорт заблокирован.'
                }
            } finally { $pending.Dispose() }
            # File.Move не перезаписывает результат конкурентного запуска.
            [IO.File]::Move($partial,$complete)
        } finally { $transferLock.Dispose() }
    }
}

function Send-RemoteArchive([ref]$Session,[hashtable]$Connection,[object]$ExpectedComputer,[IO.Stream]$Source,
    [string]$Destination,[string]$ExpectedHash,[long]$ReserveBytes) {
    $activity = 'Передача ZIP по WinRM'
    $receiver = Get-RemoteArchiveReceiver
    $buffer = New-Object byte[] (2MB)
    $hash = [Security.Cryptography.SHA256]::Create()
    $length = $Source.Length
    try {
        # Повторно вычисляем SHA-256 принятого префикса после потери связи.
        for ($attempt=1; $attempt -le 3; $attempt++) {
            try {
                if ($attempt -gt 1) {
                    if ($Session.Value) { Remove-PSSession -Session $Session.Value -ErrorAction SilentlyContinue }
                    $Session.Value = $null
                    Start-Sleep -Seconds 3
                    $Session.Value = Connect-RemoteMigration $Connection $ExpectedComputer
                }
                $rpc = @{Session=$Session.Value; ScriptBlock=$receiver; ErrorAction='Stop'}
                $state = Invoke-Command @rpc -ArgumentList 'state',$Destination,$length,$ExpectedHash
                [long]$offset = $state.Offset
                if ($offset -lt 0 -or $offset -gt $length) { throw 'Получатель вернул недопустимую позицию передачи.' }
                if ($state.Complete) {
                    Write-OperationReport 'ВОЗОБНОВЛЕНИЕ' 'Полный ZIP с тем же SHA-256 уже сохранён на получателе.'
                    return
                }
                if ($state.Free -lt ($length - $offset + $ReserveBytes)) {
                    throw ('Недостаточно места для ZIP и развёртывания. Доступно: ' + (Format-ByteSize $state.Free))
                }
                if ($offset -gt 0) {
                    if ((Get-RemoteTransferPrefixHash $Source $offset $buffer) -ne $state.Hash) {
                        throw ('Полученный префикс ZIP не совпадает с источником. Промежуточный файл сохранён для проверки: ' + $Destination + '.partial')
                    }
                    Write-OperationReport 'ВОЗОБНОВЛЕНИЕ' ('Проверено и повторно используется байт: ' + $offset)
                }
                $Source.Position = $offset
                while ($offset -lt $length) {
                    $status = (Format-ByteSize $offset) + ' из ' + (Format-ByteSize $length)
                    $percent = [int][Math]::Floor(100.0*$offset/$length)
                    Write-Progress -Id 4 -Activity $activity -Status $status -PercentComplete $percent
                    if (Test-RunningProcessStopRequest $activity 4) {
                        throw [OperationCanceledException]::new('Сетевая передача отменена. Подтверждённая часть ZIP сохранена.')
                    }
                    $count = [int][Math]::Min([long]$buffer.Length,$length-$offset)
                    Read-RemoteTransferBlock $Source $buffer $count
                    $blockHash = [BitConverter]::ToString($hash.ComputeHash($buffer,0,$count)).Replace('-','')
                    $payload = [Convert]::ToBase64String($buffer,0,$count)
                    $newOffset = Invoke-Command @rpc -ArgumentList 'append',$Destination,$length,$ExpectedHash,$offset,$blockHash,$payload
                    if ($newOffset -ne ($offset+$count)) { throw 'Получатель не подтвердил длину переданного блока.' }
                    $offset = $newOffset
                }
                if (Test-RunningProcessStopRequest $activity 4) {
                    throw [OperationCanceledException]::new('Сетевая передача отменена. Подтверждённая часть ZIP сохранена.')
                }
                Invoke-Command @rpc -ArgumentList 'finish',$Destination,$length,$ExpectedHash
                return
            } catch [OperationCanceledException] { throw }
            catch {
                # Повторяем только при потере транспорта. Ошибки места,
                # хешей и прав требуют диагностики.
                $connectionFailure = $_.Exception -is [System.Management.Automation.Remoting.PSRemotingTransportException] -or
                    ($Session.Value -and $Session.Value.State -ne 'Opened')
                if (-not $connectionFailure -or $attempt -eq 3) { throw }
                Write-DiagnosticFailure $_ ('WinRM: попытка передачи ' + $attempt)
                Write-Host 'Подключение прервано. Будет перепроверена сохранённая часть ZIP.' -ForegroundColor Yellow
            }
        }
    } finally {
        $hash.Dispose()
        Write-Progress -Id 4 -Activity $activity -Completed
    }
}

# Держим файловую блокировку в том же сеансе WinRM до конца развёртывания.
# Повторный запуск не меняет файлы работающего удалённого процесса.
function Enter-RemoteMigration([object]$Session,[string]$Root,[string]$Hash,[string]$Account) {
    Invoke-Command -Session $Session -ArgumentList $Root,$Hash,$Account -ErrorAction Stop -ScriptBlock {
        param($root,$hash,$account)
        $lockPath = Join-Path $root 'import.lock'
        try { $global:WpmDeploymentLock = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None') }
        catch [IO.IOException] { throw 'В каталоге переноса уже выполняется другая операция. Проверьте состояние на целевом ПК.' }
        $started = Join-Path $root 'import-started.txt'
        $done = Join-Path $root 'import-completed.txt'
        $tag = $hash + ' ' + $account
        if ([IO.File]::Exists($done)) {
            if ([IO.File]::Exists($started) -and [IO.File]::ReadAllText($started) -ieq $tag -and [IO.File]::ReadAllText($done) -ieq $tag) {
                return 'Completed'
            }
            throw ('Есть запись о другом или повреждённом импорте. Проверьте состояние на целевом ПК: ' + $root)
        }
        if ([IO.File]::Exists($started)) {
            throw ('Предыдущий запуск мог начать LoadState. Проверьте отчёт и состояние профиля на целевом ПК: ' + $root)
        }
        return 'Ready'
    }
}

function Invoke-RemoteProfileImport([object]$Session,[string]$Root,[string]$Archive,[string]$Account,[string]$Hash) {
    Invoke-Command -Session $Session -ArgumentList $Root,$Archive,$Account,$Hash -ErrorAction Stop -ScriptBlock {
        param($root,$zip,$account,$hash)
        function Get-MigrationLaunchOptions([string]$Script) {
            $policy = Get-ExecutionPolicy -ErrorAction Stop
            $options = @('-NoProfile','-NonInteractive')
            if ($policy -eq 'Restricted') {
                $configured = @(Get-ExecutionPolicy -List -ErrorAction Stop | Where-Object ExecutionPolicy -ne 'Undefined')
                if ($configured.Count -gt 0) {
                    throw 'Настроенная политика Windows PowerShell запрещает сценарии на получателе. Импорт ещё не запущен.'
                }
                # Штатный Restricted при отсутствии настроенных политик
                # заменяется RemoteSigned только в этом дочернем процессе.
                $options += @('-ExecutionPolicy','RemoteSigned')
                $policy = 'RemoteSigned'
            }
            $remoteOrigin = $false
            if ($policy -in @('RemoteSigned','Unrestricted')) {
                $zone = @(Get-Content -LiteralPath $Script -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue)
                $remoteOrigin = @($zone | Where-Object { $_ -match '^\s*ZoneId\s*=\s*[34]\s*$' }).Count -gt 0
            }
            if ($policy -eq 'AllSigned' -or ($remoteOrigin -and $policy -in @('RemoteSigned','Unrestricted'))) {
                $signature = Get-AuthenticodeSignature -LiteralPath $Script -ErrorAction Stop
                if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate) {
                    throw 'Получатель требует подписанный сценарий. Импорт ещё не запущен.'
                }
                $thumbprint = $signature.SignerCertificate.Thumbprint
                if (-not (Test-Path -LiteralPath ('Cert:\LocalMachine\TrustedPublisher\' + $thumbprint)) -and
                    -not (Test-Path -LiteralPath ('Cert:\CurrentUser\TrustedPublisher\' + $thumbprint))) {
                    throw 'Издатель сценария не добавлен в доверенные на получателе. Импорт ещё не запущен.'
                }
            }
            return $options
        }
        function Write-ImportMarker([string]$Path,[string]$Text) {
            $buffer = [Text.Encoding]::UTF8.GetBytes($Text)
            $file = [IO.File]::Open($Path,'CreateNew','Write','None')
            try {
                $file.Write($buffer,0,$buffer.Length)
                $file.Flush($true)
            } finally { $file.Dispose() }
        }
        # Запись о начале сохраняется до запуска дочернего процесса. После
        # потери питания или связи она запрещает автоматическое повторение.
        $tag = $hash + ' ' + $account
        $script = Join-Path $root 'ProfileMigration.ps1'
        $binary = Join-Path $PSHOME 'powershell.exe'
        $started = Join-Path $root 'import-started.txt'
        $done = Join-Path $root 'import-completed.txt'
        if (-not (Test-Path -LiteralPath $script -PathType Leaf) -or -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
            throw 'Отсутствует удалённый сценарий импорта или Windows PowerShell.'
        }
        $launchOptions = @(Get-MigrationLaunchOptions $script)
        $lockedZip = [IO.File]::Open($zip,'Open','Read','Read')
        try {
            if ((Get-FileHash -InputStream $lockedZip -Algorithm SHA256 -ErrorAction Stop).Hash -ne $hash) {
                throw 'SHA-256 ZIP изменился до запуска импорта.'
            }
            Write-ImportMarker $started $tag
            & $binary @launchOptions -File $script -ToolRoot $root -RemoteImportArchive $zip -RemoteTargetAccount $account
            if ($LASTEXITCODE -ne 0) { throw ('На целевом ПК импорт завершился кодом ' + $LASTEXITCODE + '.') }
            Write-ImportMarker $done $tag
            'WPM_REMOTE_SUCCESS'
        } finally { $lockedZip.Dispose() }
    }
}

# WinRM передаёт проверяемый ZIP и запускает подтверждённый импорт.

# Требуется предварительно разрешённый администратором удалённый доступ.
function Do-RemoteDeploy([string]$Usmt,[string]$ResumeZip = '') {
    $session = $null
    $remoteRoot = $null
    $remoteArchive = $null
    $zipStream = $null
    $releaseDeploymentLock = $false
    try {
        if ($ResumeZip) {
            if (-not (Test-Path -LiteralPath $ResumeZip -PathType Leaf)) { throw 'ZIP возобновления не найден.' }
            $zipStream = [IO.File]::Open($ResumeZip,'Open','Read','Read')
            $resumeInfo = Get-ProfileZipInfo $ResumeZip
            Assert-ArchiveMetadata $resumeInfo.Metadata $true
            $sourceProfile = [pscustomobject]@{Account=[string]$resumeInfo.Metadata.SourceAccount;
                Type=[string]$resumeInfo.Metadata.AccountType;Loaded=$false;Path='(готовый ZIP)' }
            if (-not $sourceProfile.Account) { throw 'В архиве отсутствует имя исходного пользователя.' }
            Write-OperationReport 'ВОЗОБНОВЛЕНИЕ' ('Повторный перенос из готового ZIP: ' + $ResumeZip)
        } else {
            $sourceProfile = Select-Profile
            if (-not $sourceProfile) { Write-OperationReport 'ОТМЕНА' 'Профиль для прямого переноса не выбран.'; return }
        }
        if ($sourceProfile.Loaded) { throw 'Исходный профиль загружен. Пользователь должен выйти из Windows перед прямым переносом.' }
        Advance-OperationStage 'Выбран профиль для прямого переноса'

        Title 'ПРЯМОЙ ПЕРЕНОС ПО СЕТИ'
        Write-Host 'Укажите целевой ПК: имя в локальной сети, полное DNS-имя (pc.domain.local) либо IP.'
        Write-Host '0. Назад'
        $targetHost = ([string](Read-Host 'Целевой ПК / FQDN / IP')).Trim()
        if (-not $targetHost -or $targetHost -eq '0') { Write-OperationReport 'ОТМЕНА' 'Ввод сетевого адреса отменён.'; return }
        if ($targetHost -notmatch '^[a-zA-Z0-9_.:\-]{1,253}$' -or $targetHost.StartsWith('-')) {
            throw 'Неверный адрес назначения. Введите имя ПК, FQDN или IP без пробелов и обратных слешей.'
        }
        Write-Host 'Протокол подключения:'
        Write-Host '1. WinRM HTTP (Kerberos/Negotiate, обычно внутри домена или домашней сети)'
        Write-Host '2. WinRM HTTPS (требуется настроенный сертификат целевого ПК)'
        Write-Host '0. Назад'
        $transport = Choice 'Выберите протокол' 2
        if ($transport -eq 0) { Write-OperationReport 'ОТМЕНА' 'Выбор протокола отменён.'; return }
        Write-Host 'Доступ к целевому компьютеру:'
        Write-Host '1. Моя текущая учётная запись администратора (единый домен/доверие)'
        Write-Host '2. Другой администратор назначения (в том числе другой домен/локальный ПК)'
        Write-Host '0. Назад'
        $auth = Choice 'Выберите способ входа' 2
        if ($auth -eq 0) { Write-OperationReport 'ОТМЕНА' 'Выбор администратора отменён.'; return }
        $remoteCredential = $null
        if ($auth -eq 2) {
            $remoteCredential = Get-Credential -Message ('Администратор компьютера ' + $targetHost + ' (DOMAIN\user или COMPUTER\user)')
            if (-not $remoteCredential) { Write-OperationReport 'ОТМЕНА' 'Ввод учётных данных отменён.'; return }
        }
        Write-Host ('Проверка удалённого подключения: ' + $targetHost) -ForegroundColor Cyan
        Write-OperationReport 'СЕТЬ' ('Подключение к ' + $targetHost + '; протокол=' + $(if ($transport -eq 2) { 'HTTPS' } else { 'HTTP' }) + '; явные полномочия=' + ($auth -eq 2))
        $connection = @{ComputerName=$targetHost; ConfigurationName='Microsoft.PowerShell'; Authentication='Negotiate'; ErrorAction='Stop'}
        if ($transport -eq 2) { $connection['UseSSL'] = $true }
        if ($remoteCredential) { $connection['Credential'] = $remoteCredential }
        try { $session = New-PSSession @connection }
        catch {
            Write-DiagnosticFailure $_ 'WinRM: создание удалённой сессии'
            throw ('Подключение WinRM не установлено: ' + $_.Exception.Message + '. На целевом ПК запустите Start.cmd и пункт 6. Для IP/другого домена настройте WinRM HTTPS либо точечное доверие TrustedHosts по правилам вашей сети.')
        }
        Advance-OperationStage 'Соединение WinRM с целевым ПК открыто'
        $remote = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $admin = [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            $computer = Get-CimInstance Win32_ComputerSystem
            $system = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $machineGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
            $root = [IO.Path]::GetPathRoot($env:ProgramData)
            $free = [IO.DriveInfo]::new($root).AvailableFreeSpace
            [pscustomobject]@{
                Name=$env:COMPUTERNAME; Domain=$computer.Domain; PartOfDomain=$computer.PartOfDomain;
                Windows=$system.Caption; Version=$system.Version; IsAdmin=$admin; ProductType=$system.ProductType;
                Identity=[string]$machineGuid; Is64Bit=[Environment]::Is64BitProcess;
                Architecture=$env:PROCESSOR_ARCHITECTURE; FreeBytes=$free;
                ProgramData=$env:ProgramData
            }
        }
        if (-not $remote.IsAdmin) { throw 'Удалённый вход не имеет полного административного токена. Проверьте права назначения и политики удалённого UAC.' }
        if ([string]$remote.Version -notmatch '^10\.' -or $remote.ProductType -ne 1) { throw 'Целевой ПК должен работать под Windows 10 или Windows 11.' }
        if (-not $remote.Is64Bit -or $remote.Architecture -notin @('AMD64','ARM64')) { throw 'На целевом ПК требуется 64-разрядный Windows PowerShell для x64 или ARM64.' }
        $sourceIdentity = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
        if (-not $remote.Identity -or $remote.Identity -ieq $sourceIdentity) { throw 'Не удалось отличить целевой ПК от исходного. Перенос остановлен.' }
        Advance-OperationStage 'Проверены ОС, права и свободное место целевого ПК'
        Write-Host ('Целевой компьютер: ' + $remote.Name + ' | ' + $remote.Windows) -ForegroundColor Green
        Write-Host ('Домен или рабочая группа: ' + $remote.Domain)
        Write-Host ('Доступно на целевом диске: ' + (Format-ByteSize ([UInt64]$remote.FreeBytes)))

        $userName = ([string]$sourceProfile.Account -split '\\',2)[-1]
        $sameAccount = if ($sourceProfile.Type -eq 'Domain') { [string]$sourceProfile.Account }
            else { [string]$remote.Name + '\' + $userName }
        Write-Host 'Кому развернуть профиль на целевом ПК?'
        Write-Host ('1. Исходное имя пользователя: ' + $sameAccount)
        Write-Host ('2. Ввести имя локальной учётной записи на ' + $remote.Name)
        Write-Host '3. Указать учётную запись назначения DOMAIN\user или COMPUTER\user'
        Write-Host '0. Назад'
        $accountChoice = Choice 'Выберите назначение' 3
        if ($accountChoice -eq 0) { Write-OperationReport 'ОТМЕНА' 'Выбор пользователя назначения отменён.'; return }
        $targetAccount = switch ($accountChoice) {
            1 { $sameAccount }
            2 {
                $localName = (Read-Host 'Имя локальной учётной записи (0 - назад)').Trim()
                if ($localName -eq '0') { '0' }
                else { [string]$remote.Name + '\' + $localName }
            }
            3 { (Read-Host 'Введите DOMAIN\user или COMPUTER\user (0 - назад)').Trim() }
        }
        if ($targetAccount -eq '0') { Write-OperationReport 'ОТМЕНА' 'Ввод учётной записи отменён.'; return }
        if ($targetAccount -notmatch '^[^\\/:*?"<>|\x00-\x1F]{1,64}\\[^\\/:*?"<>|\x00-\x1F]{1,64}$') {
            throw 'Имя назначения должно иметь вид DOMAIN\user или COMPUTER\user.'
        }
        $targetCheck = Invoke-Command -Session $session -ArgumentList $targetAccount,([bool]$ResumeZip) -ScriptBlock {
            param($account,$checkingResume)
            $parts = $account -split '\\',2
            $existing = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special })
            if ($parts[0] -ieq $env:COMPUTERNAME) {
                if ($parts[1].Length -gt 20) { throw 'Имя локального пользователя длиннее 20 символов.' }
                $user = Get-LocalUser -Name $parts[1] -ErrorAction SilentlyContinue
                if ($user -and @($existing | Where-Object SID -eq $user.SID.Value).Count -gt 0) {
                    if ($checkingResume) { return 'Существующий профиль: будет проверено состояние прошлого переноса' }
                    throw 'Профиль назначения уже существует.'
                }
                if ($user -and -not $user.Enabled) { throw 'Локальный пользователь назначения отключён.' }
                return $(if ($user) { 'Локальный пользователь найден' } else { 'Новый локальный пользователь будет создан' })
            }
            $sid = ([Security.Principal.NTAccount]::new($account)).Translate([Security.Principal.SecurityIdentifier]).Value
            if (@($existing | Where-Object SID -eq $sid).Count -gt 0) {
                if ($checkingResume) { return 'Существующий профиль: будет проверено состояние прошлого переноса' }
                throw 'Целевой доменный пользователь уже имеет профиль.'
            }
            return 'Доменный пользователь доступен'
        } -ErrorAction Stop
        Write-OperationReport 'НАЗНАЧЕНИЕ' ('Выбрано: ' + $targetAccount + '; проверка: ' + $targetCheck)
        Advance-OperationStage 'Проверена учётная запись назначения'

        Write-Host ''
        Write-Host ('Источник: ' + $env:COMPUTERNAME + ' | ' + $sourceProfile.Account) -ForegroundColor Cyan
        Write-Host ('Назначение: ' + $remote.Name + ' | ' + $targetAccount) -ForegroundColor Cyan
        if ($ResumeZip) { Write-Host 'Будет проверено состояние переноса сохранённого ZIP на целевом ПК.' }
        else { Write-Host 'Будет автоматически: создан ZIP одного выбранного профиля, передан на целевой ПК, проверен и применён.' }
        Write-Host 'Готовый ZIP сохраняется на обоих компьютерах; прежний профиль назначения не перезаписывается.'
        if (-not (Confirm 'Начать полный прямой перенос с автоматическим развёртыванием?')) {
            Write-OperationReport 'ОТМЕНА' 'Прямой перенос отклонён.'
            return
        }
        Advance-OperationStage 'Подтверждён прямой перенос на выбранный ПК'
        # Экспорт может длиться часы. Завершаем проверочную сессию заранее,
        # чтобы ограничение WinRM по времени простоя не сорвало отправку.
        if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue; $session=$null }
        $zipPath = $ResumeZip
        if (-not $zipPath) {
            $localRoot = Join-Path $Script:WpmWorkRoot 'DirectTransfers'
            Initialize-WpmWorkDirectory $localRoot
            $zipPath = [string](Do-Export $Usmt $sourceProfile $localRoot $true $true)
        }
        if (-not $zipPath -or -not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw 'Экспорт не создал ZIP. Развёртывание остановлено.' }
        try { $session = Connect-RemoteMigration $connection $remote }
        catch { throw ('ZIP готов, но подключение к прежнему получателю не установлено. Архив сохранён: ' + $zipPath + '. При восстановлении связи выберите пункт 7. Ошибка: ' + $_.Exception.Message) }
        if (-not $zipStream) { $zipStream = [IO.File]::Open($zipPath,'Open','Read','Read') }
        $zipInfo = Get-ProfileZipInfo $zipPath
        $localHash = (Get-FileHash -InputStream $zipStream -Algorithm SHA256 -ErrorAction Stop).Hash
        Write-OperationReport 'ЭКСПОРТ' ('Готов ZIP: ' + $zipPath)
        Advance-OperationStage 'ZIP одного профиля подготовлен для отправки'

        $transferId = 'WPM_' + $localHash.Substring(0,24)
        $remoteRoot = Initialize-RemoteMigrationDirectory $session $transferId
        # Путь относится к диску получателя и не обязан существовать на источнике.
        $remoteArchive = [IO.Path]::Combine($remoteRoot,'Backups','Profile.zip')
        Write-OperationReport 'ПЕРЕДАЧА' ('ZIP получателя: ' + $remoteArchive + '; размер: ' + $zipStream.Length + ' байт')
        $reserve = [long]([decimal]$zipInfo.ExpandedBytes + [decimal]$zipInfo.Metadata.EstimatedProfileBytes + [decimal]2GB)
        Send-RemoteArchive ([ref]$session) $connection $remote $zipStream $remoteArchive $localHash $reserve
        Advance-OperationStage 'ZIP передан и проверен по SHA-256'
        Write-OperationReport 'ПРОВЕРКА' ('ZIP передан без изменений, SHA-256: ' + $localHash)

        $releaseDeploymentLock = $true
        $deployment = Enter-RemoteMigration $session $remoteRoot $localHash $targetAccount
        if ($deployment -eq 'Completed') {
            Write-OperationReport 'ВОЗОБНОВЛЕНИЕ' 'На получателе сохранено подтверждение завершения импорта этого ZIP для выбранного пользователя.'
            try { Include-RemoteReport $session $remoteRoot }
            catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось прочитать удалённый отчёт: ' + $_.Exception.Message) }
            Finish-OperationReport 'РАНЕЕ ТЕХНИЧЕСКИ ЗАВЕРШЕНО; ОЖИДАЕТ ПРОВЕРКИ ПОД ПОЛЬЗОВАТЕЛЕМ'
            Write-Host 'Этот архив уже применён для выбранной учётной записи. Проверьте профиль на целевом ПК.' -ForegroundColor Green
            return
        }
        # При возобновлении допускаем существующий профиль до чтения записи
        # о завершении. Без этой записи импорт в него запрещён и здесь.
        if ($targetCheck -like 'Существующий профиль:*') {
            throw 'Целевой профиль уже существует, а подтверждение предыдущего импорта отсутствует. Проверьте состояние на получателе.'
        }

        foreach ($filename in @('ProfileMigration.ps1','Bootstrap.ps1','Start.cmd')) {
            $sourceFile = Join-Path $Script:ToolRoot $filename
            $remoteFile = [IO.Path]::Combine($remoteRoot,$filename)
            $scriptHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256 -ErrorAction Stop).Hash
            Copy-Item -LiteralPath $sourceFile -Destination $remoteFile -ToSession $session -Force -ErrorAction Stop
            $remoteScriptHash = Invoke-Command -Session $session -ArgumentList $remoteFile -ErrorAction Stop -ScriptBlock {
                param($path)
                (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
            }
            if ($remoteScriptHash -ne $scriptHash) { throw ('SHA-256 переданного файла не совпал: ' + $filename) }
        }
        Advance-OperationStage 'Скрипты на целевом ПК сверены по SHA-256'

        $targetArch = ([string]$remote.Architecture).ToLowerInvariant()
        $targetUsmt = [IO.Path]::Combine($remoteRoot,'USMT',$targetArch)
        $hasTargetUsmt = Invoke-Command -Session $session -ArgumentList $targetUsmt,$targetArch -ErrorAction Stop -ScriptBlock {
            param($bundled,$arch)
            $kit = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
            if (-not $kit) { $kit = $env:ProgramFiles }
            $installed = Join-Path $kit ('Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool\' + $arch)
            foreach ($path in @($installed,$bundled)) {
                $missing = @('ScanState.exe','LoadState.exe','UsmtUtils.exe' | Where-Object {
                    -not (Test-Path -LiteralPath (Join-Path $path $_) -PathType Leaf)
                })
                if ($missing.Count -eq 0) { return $true }
            }
            return $false
        }
        if (-not $hasTargetUsmt) {
            $sourceArch = ([string]$env:PROCESSOR_ARCHITECTURE).ToLowerInvariant()
            if ($sourceArch -ne $targetArch) { throw 'Архитектуры ПК различаются. Установите USMT для архитектуры получателя через Start.cmd.' }
            $partialUsmt = $targetUsmt + '.partial'
            Invoke-Command -Session $session -ArgumentList $targetUsmt,$partialUsmt -ErrorAction Stop -ScriptBlock {
                param($ready,$partial)
                if (Test-Path -LiteralPath $ready) { throw 'Каталог USMT получателя неполон. Проверьте его на целевом ПК.' }
                [void][IO.Directory]::CreateDirectory($partial)
            }
            Write-Host 'Передача USMT на целевой ПК...' -ForegroundColor Cyan
            foreach ($item in Get-ChildItem -LiteralPath $Usmt -Force -ErrorAction Stop) {
                Copy-Item -LiteralPath $item.FullName -Destination $partialUsmt -Recurse -ToSession $session -Force -ErrorAction Stop
            }
            Invoke-Command -Session $session -ArgumentList $partialUsmt,$targetUsmt -ErrorAction Stop -ScriptBlock {
                param($partial,$ready)
                foreach ($name in @('ScanState.exe','LoadState.exe','UsmtUtils.exe')) {
                    if (-not (Test-Path -LiteralPath (Join-Path $partial $name) -PathType Leaf)) {
                        throw ('Не удалось полностью скопировать USMT: ' + $name)
                    }
                }
                [IO.Directory]::Move($partial,$ready)
            }
            Write-OperationReport 'ПРОВЕРКА' ('USMT передан в каталог получателя: ' + $targetUsmt)
        }
        Advance-OperationStage 'USMT доступен целевому компьютеру'

        if (Test-RunningProcessStopRequest 'Подготовка удалённого импорта' 4) {
            throw [OperationCanceledException]::new('Удалённый импорт отменён до запуска. Проверенный ZIP сохранён.')
        }
        Write-Host 'Автоматический запуск LoadState на целевом компьютере...' -ForegroundColor Cyan
        $remoteSucceeded = $false
        Invoke-RemoteProfileImport $session $remoteRoot $remoteArchive $targetAccount $localHash | ForEach-Object {
            if ([string]$_ -eq 'WPM_REMOTE_SUCCESS') { $remoteSucceeded = $true }
            else { Write-Host ([string]$_) }
        }
        if (-not $remoteSucceeded) {
            throw 'Удалённый процесс не подтвердил успешное техническое завершение импорта.'
        }
        Advance-OperationStage 'LoadState выполнен на целевом ПК'
        try {
            Include-RemoteReport $session $remoteRoot
            Advance-OperationStage 'Проверен отчёт получателя'
        } catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Импорт подтверждён. Отчёт сохранён на получателе: ' + $_.Exception.Message) }
        Write-OperationReport 'ИТОГ' ('Прямой перенос: ' + $sourceProfile.Account + ' → ' + $targetAccount + '; получатель=' + $remote.Name + '; ZIP=' + $remoteArchive)
        Advance-OperationStage 'Прямой перенос завершён'
        Finish-OperationReport 'ТЕХНИЧЕСКИ ЗАВЕРШЕНО; ОЖИДАЕТ ПРОВЕРКИ ПОД ПОЛЬЗОВАТЕЛЕМ'
        Write-Host ('Готово. На целевом ПК выполнено автоматическое развёртывание: ' + $targetAccount) -ForegroundColor Green
    } catch {
        Write-DiagnosticFailure $_ 'Прямой сетевой перенос'
        if ($session -and $remoteRoot) {
            try { Include-RemoteReport $session $remoteRoot }
            catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Удалённый отчёт сейчас недоступен: ' + $_.Exception.Message) }
        }
        if ($remoteRoot) { Write-OperationReport 'ВОССТАНОВЛЕНИЕ' ('Каталог целевого ПК оставлен для повторной проверки: ' + $remoteRoot) }
        if ($remoteArchive) { Write-OperationReport 'ВОССТАНОВЛЕНИЕ' ('ZIP назначения (если уже передан): ' + $remoteArchive) }
        throw
    } finally {
        if ($zipStream) { $zipStream.Dispose() }
        if ($session) {
            if ($releaseDeploymentLock -and $session.State -eq 'Opened') {
                try {
                    Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                        $lock = Get-Variable -Name WpmDeploymentLock -Scope Global -ErrorAction SilentlyContinue
                        if ($lock) {
                            $lock.Value.Dispose()
                            Remove-Variable -Name WpmDeploymentLock -Scope Global
                        }
                    }
                } catch { }
            }
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}
