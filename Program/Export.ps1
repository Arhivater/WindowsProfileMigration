# Экспорт создаёт архив только выбранного пользователя.

# Встроенный оригинал ProfileOnly.xml. Правила будут созданы автоматически,
# даже если при копировании комплекта потерялась отдельная папка Rules.
# Контрольный SHA-256 оставлен совместимым с архивами v1.9.6.
function Write-EmbeddedProfileOnlyRule([string]$Destination) {
    $xmlText = @'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Автор: Arhivater. Миграция только пользовательского контекста. -->
<migration urlid="http://www.microsoft.com/migration/1.0/migxmlext/ArhivaterProfileOnly">
  <component type="Documents" context="User">
    <displayName>Arhivater - Profile files only</displayName>
    <role role="Data">
      <rules context="User">
        <include>
          <objectSet>
            <!-- Файлы в корне профиля и во всех вложенных папках. -->
            <pattern type="File">%CSIDL_PROFILE% [*]</pattern>
            <pattern type="File">%CSIDL_PROFILE%\* [*]</pattern>
          </objectSet>
        </include>
        <exclude>
          <objectSet>
            <!-- Реестровые ульи не копируются как файлы: HKCU переносится отдельно. -->
            <pattern type="File">%CSIDL_PROFILE% [NTUSER.DAT*]</pattern>
            <pattern type="File">%CSIDL_PROFILE% [NTUSER.INI]</pattern>
            <pattern type="File">%CSIDL_PROFILE%\AppData\Local\Microsoft\Windows [UsrClass.dat*]</pattern>
          </objectSet>
        </exclude>
      </rules>
    </role>
  </component>
  <component type="Application" context="User">
    <displayName>Arhivater - User registry settings only</displayName>
    <role role="Settings">
      <rules context="User">
        <include>
          <objectSet>
            <!-- Только HKCU выбранной через /ui учётной записи. -->
            <pattern type="Registry">HKCU [*]</pattern>
            <pattern type="Registry">HKCU\* [*]</pattern>
          </objectSet>
        </include>
      </rules>
    </role>
  </component>
</migration>
'@
    # Приводим окончания строк к LF и сохраняем UTF-8 без BOM.
    # Это обеспечивает одинаковый файл и его SHA-256 на разных компьютерах.
    $normalized = ($xmlText -replace "`r`n", "`n").TrimEnd([char[]]@([char]13,[char]10)) + "`n"
    [IO.File]::WriteAllText($Destination, $normalized, [System.Text.UTF8Encoding]::new($false))
    if ((Get-ExactFileSha256 $Destination) -ne '5bf12aa9ff9d874faec31829cc7f0b8277af82311810321ec97c89aa6803705c') {
        throw 'Контрольная сумма встроенных правил ProfileOnly.xml не совпала. Экспорт остановлен.'
    }
}

# XML читается с отключённым DTD и внешними ресурсами.
function Read-MigrationXml([string]$Path) {
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 32MB
    $reader = [Xml.XmlReader]::Create($Path,$settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        return ,$document
    } finally { $reader.Dispose() }
}

# Готовит только пользовательские правила USMT. Стандартные MigDocs/MigUser
# ищут файлы по всему компьютеру, поэтому для профильного архива не используются.
# Генерируемый Config.xml отключает стандартные настройки уровня компьютера.
function New-ProfileOnlyRules([string]$Archive,[string]$Usmt,[string]$Logs) {
    $folder = Join-Path $Archive 'Rules'
    [void](New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop)
    $rule = Join-Path $folder 'ProfileOnly.xml'
    $configPath = Join-Path $folder 'Config.xml'
    Write-EmbeddedProfileOnlyRule $rule
    # Проверка XML до передачи его ScanState.
    $xml = Read-MigrationXml $rule
    $parts = @($xml.SelectNodes('/migration/component'))
    if ($parts.Count -ne 2 -or @($parts | Where-Object { $_.GetAttribute('context') -ne 'User' }).Count -gt 0) {
        throw 'Правило ProfileOnly.xml имеет неожиданную область миграции.'
    }
    Write-Host 'Подготовка ограниченных правил USMT...' -ForegroundColor Cyan
    $genconfigLog = Join-Path $Logs 'genconfig.log'
    Write-OperationReport 'ЖУРНАЛ USMT' ('Подготовка Config.xml: ' + $genconfigLog)
    Invoke-USMT (Join-Path $Usmt 'ScanState.exe') @(
        ('/i:'+$rule),('/genconfig:'+$configPath),'/v:5',('/l:'+$genconfigLog)
    ) $Usmt -TrackProcess
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw 'USMT не создал Config.xml для ограничения настроек компьютера.'
    }
    $config = Read-MigrationXml $configPath
    if (-not $config.SelectSingleNode('/Configuration')) {
        throw 'Config.xml USMT имеет неожиданный формат.'
    }
    $machineComponents = @($config.SelectNodes('/Configuration/WindowsComponents//component'))
    foreach ($node in $machineComponents) { [void]$node.SetAttribute('migrate','no') }
    $config.Save($configPath)
    Write-OperationReport 'ПРОВЕРКА' ('Настройки Windows уровня компьютера отключены: ' + $machineComponents.Count + ' разделов.')
    return [pscustomobject]@{ Rule=$rule; Config=$configPath;
        RuleSHA256=(Get-ExactFileSha256 $rule); ConfigSHA256=(Get-ExactFileSha256 $configPath) }
}

# Читает реальный /listfiles от ScanState и завершает экспорт с ошибкой,
# если хотя бы один объект вне выбранного профиля или путь не распознан.
# USMT может записать сам корень профиля как отдельный объект списка.
# Не допускаем переходы через junction/symlink внутри профиля.
function Inspect-UsmtFileScope([string]$FileList,[string]$ProfilePath,[bool]$VerifySourceLinks = $true) {
    if (-not (Test-Path -LiteralPath $FileList -PathType Leaf)) { throw 'USMT не создал /listfiles. Область экспорта не подтверждена.' }
    $root = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
    $prefix = $root + '\'
    $cmp = [StringComparison]::OrdinalIgnoreCase
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$files = 0
    [long]$invalid = 0
    $examples = New-Object 'System.Collections.Generic.List[string]'
    $reader = [IO.StreamReader]::new($FileList,[Text.Encoding]::UTF8,$true)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            $candidate = ([string]$line).Trim().Trim('"')
            if (-not $candidate) { continue }
            $files++
            $reason = ''
            try {
                if ($candidate -notmatch '^[a-zA-Z]:\\') { throw 'не абсолютный локальный путь' }
                $relative = $candidate.Substring(3)
                if ($relative.EndsWith('\')) { $relative = $relative.Substring(0,$relative.Length - 1) }
                if ($relative) { [void](Get-WindowsRelativePathParts $relative) }
                $full = [IO.Path]::GetFullPath($candidate)
                # Принимаем сам корень и строго вложенные объекты. Соседние
                # профили, например a.agdamov2, остаются за пределами области.
                if (-not ($full.Equals($root,$cmp) -or $full.StartsWith($prefix,$cmp))) {
                    throw 'вне выбранного профиля'
                }
                if ($VerifySourceLinks) {
                    $current = $full
                    while ($current.StartsWith($prefix,$cmp) -or $current.Equals($root,$cmp)) {
                        if (-not $seen.Add($current)) { break }
                        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'переход через ссылку' }
                        if ($current.Equals($root,$cmp)) { break }
                        $current = [IO.Path]::GetDirectoryName($current)
                    }
                }
            } catch { $reason = $_.Exception.Message }
            if ($reason) {
                $invalid++
                if ($examples.Count -lt 12) { $examples.Add($candidate + ' (' + $reason + ')') }
            }
        }
    } finally { $reader.Dispose() }
    if ($files -eq 0) { throw 'USMT не перечислил ни одного объекта. Экспорт не может быть подтверждён.' }
    if ($invalid -gt 0) {
        foreach ($example in @($examples.ToArray())) { Write-OperationReport 'ОШИБКА ОБЛАСТИ' $example }
        throw ('ScanState выбрал ' + $invalid + ' объектов вне подтверждённой области из ' + $files + '. Архив НЕ будет опубликован.')
    }
    Write-OperationReport 'ПРОВЕРКА' ('USMT /listfiles: ' + $files + ' объектов, все внутри ' + $root + ' или равны корню профиля')
    return $files
}

# При импорте нужен архив с тем же XML и проверенным списком файлов.
function Assert-ProfileOnlyArchive([string]$Archive,[object]$Meta) {
    if ([int]$Meta.SchemaVersion -lt 7 -or -not $Meta.ProfileScope -or
        [string]$Meta.ProfileScope.Policy -ne 'ArhivaterProfileOnlyV1') {
        throw 'Старый архив не подтверждает ограничение одним профилем. Создайте новый архив в v1.9.11 или новее.'
    }
    $proof = $Meta.ProfileScope
    if ([string]$proof.ProfilePath -ne [string]$Meta.SourceProfilePath -or [long]$proof.Files -lt 1) {
        throw 'Сведения об области пользовательского профиля повреждены.'
    }
    $rule = Join-Path $Archive 'Rules\ProfileOnly.xml'
    $config = Join-Path $Archive 'Rules\Config.xml'
    $files = Join-Path $Archive 'Validation\usmt-files.txt'
    $required = @(
        [pscustomobject]@{Path=$rule; Hash=[string]$proof.RuleSHA256}
        [pscustomobject]@{Path=$config; Hash=[string]$proof.ConfigSHA256}
        [pscustomobject]@{Path=$files; Hash=[string]$proof.ListSHA256}
    )
    foreach ($item in $required) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf) -or
            -not $item.Hash -or (Get-ExactFileSha256 ([string]$item.Path)) -ne $item.Hash) {
            throw ('Файл подтверждения области изменён или отсутствует: ' + [IO.Path]::GetFileName([string]$item.Path))
        }
    }
    # Надёжный шаблон встроен в этот файл, внешняя папка Rules не нужна.
    if ([string]$proof.RuleSHA256 -ne '5bf12aa9ff9d874faec31829cc7f0b8277af82311810321ec97c89aa6803705c') {
        throw 'Правила в архиве отличаются от подтверждённого шаблона комплекта.'
    }
    $configDoc = Read-MigrationXml $config
    if (-not $configDoc.SelectSingleNode('/Configuration')) { throw 'Config.xml не прошёл структурную проверку.' }
    foreach ($node in @($configDoc.SelectNodes('/Configuration/WindowsComponents//component'))) {
        if ($node.GetAttribute('migrate') -ne 'no') {
            throw 'В архиве обнаружены включённые системные компоненты Windows.'
        }
    }
    $actual = Inspect-UsmtFileScope $files ([string]$proof.ProfilePath) $false
    if ($actual -ne [long]$proof.Files) { throw 'Количество файлов в проверенном списке не совпадает.' }
}

# Повторно проверяет нет ли нового входа в систему, подмены каталога
# или удаления профиля за время подготовки и сверки файлов.
function Assert-ExportProfileReady([object]$Profile,[string]$Phase) {
    $actual = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object { $_.SID -eq $Profile.SID })
    if ($actual.Count -ne 1 -or [string]$actual[0].LocalPath -ine [string]$Profile.Path -or
        $null -eq $actual[0].Loaded -or $actual[0].Loaded) {
        throw ('Состояние выбранного профиля изменилось: ' + $Phase + '. ZIP не опубликован.')
    }
}

# Главный сценарий: профиль → оценка объёма → ScanState → проверка .mig → дополнения → публикация.
# ScanState упаковывает данные. Параметр /ui выбирает ровно одну учётную запись.
function Invoke-ProfileScan($Usmt, $Store, $Rules, $Logs, $ListPath, $Account) {
    $scanArguments = @($store, ('/i:'+$rules.Rule),('/config:'+$rules.Config),('/listfiles:'+$listPath),'/localonly','/efs:abort',
        '/ue:*\*',('/ui:' + $Account), '/v:5',('/l:'+(Join-Path $logs 'scanstate.log')),
        ('/progress:'+(Join-Path $logs 'scan-progress.log')))
    Write-Host 'Экспорт USMT...' -ForegroundColor Cyan
    Write-OperationReport 'ЖУРНАЛ USMT' ('Экспорт: ' + (Join-Path $logs 'scanstate.log'))
    Update-TrackedState 'ScanState выполняется' @{USMTStarted=$true}
    Invoke-USMT (Join-Path $Usmt 'ScanState.exe') $scanArguments $Usmt (Join-Path $logs 'scan-progress.log') -TrackProcess
    Advance-OperationStage 'ScanState завершён'
    Update-TrackedState 'ScanState завершён' @{USMTFinished=$true}
    Write-OperationReport 'УСПЕХ' 'USMT ScanState: экспорт завершён, код 0.'
}

# Сверяем список, который выдал ScanState, и сохраняем доказательство для будущего импорта.
function Save-ProfileScopeProof($ListPath, $ProfilePath, $Archive, $Rules) {
    # До публикации проверяем ФАКТИЧЕСКИЙ перечень файлов USMT, а не оценку.
    # В случае выхода за пределы профиля уничтожаем только принадлежащую
    # этому экспорту локальную временную копию.
    try {
        $scopeCount = Inspect-UsmtFileScope $listPath $ProfilePath
    } catch {
        [void](Clear-TrackedStaging $Script:ActiveOpState $false)
        throw
    }
    Advance-OperationStage 'Подтверждена область одного профиля'
    $scopeList = Join-Path $archive 'Validation\usmt-files.txt'
    Copy-Item -LiteralPath $listPath -Destination $scopeList -Force -ErrorAction Stop
    return [ordered]@{Policy='ArhivaterProfileOnlyV1'; ProfilePath=$ProfilePath; Files=$scopeCount;
        RuleSHA256=$rules.RuleSHA256; ConfigSHA256=$rules.ConfigSHA256;
        ListSHA256=(Get-ExactFileSha256 $scopeList)}
}

function Do-Export([string]$Usmt,[object]$SelectedProfile = $null,[string]$ForcedRoot = '',[bool]$KeepReportOpen = $false,[bool]$AutoApprove = $false, [Security.SecureString]$ArchivePassword = $null) {
    Advance-OperationStage 'Выбор исходного профиля' -Starting -MilestoneActivity 'Экспорт профиля' -Milestone 0 -TotalMilestones 8
    $p = if ($SelectedProfile) { $SelectedProfile } else { Select-Profile }
    if (-not $p) { Write-OperationReport 'ОТМЕНА' 'Выбор профиля отменён.'; return }
    Advance-OperationStage 'Выбран исходный профиль'
    Write-OperationReport 'ИСТОЧНИК' ('Учётная запись: ' + $p.Account + '; тип: ' + $p.Type + '; каталог: ' + $p.Path)
    # Полностью проверяемый перенос требует выгруженного пользовательского реестра.
    # Нельзя хешировать файл после ScanState и выдавать этот хеш за содержимое .mig.
    if ($p.Loaded) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Профиль ' + $p.Account + ' загружен. Экспорт не начат из-за риска рассогласования исходных файлов и .mig.')
        Write-Host ('Профиль ' + $p.Account + ' сейчас загружен в Windows.') -ForegroundColor Yellow
        Write-Host 'Для проверенного экспорта пользователь должен выйти из Windows (не блокировать экран).' -ForegroundColor Yellow
        Write-Host 'Войдите под ДРУГИМ администратором, запустите Start.cmd и выберите профиль из списка цифрой.'
        Write-Host 'Это необходимо, чтобы контрольные суммы относились к тем же данным, что захватывает USMT.'
        return
    }
    Assert-ExportProfileReady $p 'перед оценкой файлов'
    $ownedPassword = -not $PSBoundParameters.ContainsKey('ArchivePassword')
    try {
    Advance-OperationStage 'Выбор файлов и защиты архива' -Starting
    $includeDocuments = Read-PersonalFilesChoice
    if ($ownedPassword) { $ArchivePassword = Read-WpmExportPassword }
    Assert-NoReparseAncestor $p.Path
    Write-Host 'Оценка размера профиля...' -ForegroundColor Cyan
    Advance-OperationStage 'Оценка объёма профиля' -Starting
    $profileMetrics = Get-FolderMetrics $p.Path
    $estimatedBytes = [UInt64]$profileMetrics.Bytes
    $personalFolders = Get-PersonalFolders $p.SID $p.Path $includeDocuments
    $personalBytes = Measure-PersonalFiles $personalFolders
    $packageInputBytes = [UInt64]($estimatedBytes + $personalBytes)
    $baseline = Get-ProfileValidationBaseline $p.Path
    Advance-OperationStage 'Подсчитан размер исходного профиля' -MilestoneActivity 'Экспорт профиля' -Milestone 1 -TotalMilestones 8
    Write-Host ('Оценочный размер профиля: ' + (Format-ByteSize $estimatedBytes) + '; файлов: ' + $profileMetrics.Files) -ForegroundColor Green
    Write-OperationReport 'ПРОВЕРКА' ('Оценочный размер профиля: ' + (Format-ByteSize $estimatedBytes) + '; файлов: ' + $profileMetrics.Files)
    if ($profileMetrics.SkippedLinks -gt 0) {
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не учитывались точки соединения и символические ссылки: ' + $profileMetrics.SkippedLinks)
    }
    Write-OperationReport 'ПРОВЕРКА' 'Объём профиля - оценка, а не точный размер USMT: служебные данные архива и дополнительные файлы модулей учитываются при экспорте.'
    Advance-OperationStage 'Проверка папки и свободного места для экспорта' -Starting
    $root = if ($ForcedRoot) { $ForcedRoot } else { Select-SaveLocation }
    if (-not $root) { Write-OperationReport 'ОТМЕНА' 'Выбор каталога сохранения отменён.'; return }
    Write-OperationReport 'ПУТЬ' ('Папка резервных копий: ' + $root)
    Test-StoreLocation $root $p.Path $packageInputBytes
    Advance-OperationStage 'Проверена папка назначения'
    $safe = $p.Account -replace '[^a-zA-Z0-9а-яА-ЯёЁ_-]', '_'
    $folderName = '{0}_{1}_{2}_{3}' -f $env:COMPUTERNAME,$safe,(Get-Date -Format 'yyyyMMdd_HHmmss_fff'),([guid]::NewGuid().ToString('N').Substring(0,8))
    $extension = '.zip'
    if ($ArchivePassword) { $folderName = 'Profile_' + [guid]::NewGuid().ToString('N'); $extension = '.wpm.pgp' }
    $finalArchive = Join-Path $root ($folderName + $extension)
    Start-TrackedState 'Экспорт' $finalArchive
    $networkPublish = Test-IsUncPath $root
    if ($networkPublish) { Ensure-PathAvailable $root 'Сетевая папка архива' }
    # USMT создаёт рабочий каталог; готовым результатом всегда является один ZIP.
    # Хранение каталога и ZIP одновременно требует локального свободного места.
    $stagingRoot = $Script:WpmStagingRoot
    $stagingDrive = [IO.Path]::GetPathRoot($stagingRoot)
    $stagingFree = Get-PathFreeBytes $stagingDrive
    $stagingNeeded = [UInt64]([double]$packageInputBytes * $(if ($ArchivePassword) { 3.3 } else { 2.2 }) + [double]1GB)
    if ($stagingFree -lt $stagingNeeded) {
        throw ('Недостаточно места для создания ZIP на ' + $stagingDrive +
            '. Нужно примерно ' + (Format-ByteSize $stagingNeeded) +
            ', доступно ' + (Format-ByteSize $stagingFree) + '.')
    }
    $staging = New-StagingDirectory 'Export'
    $archive = Join-Path $staging 'Payload'
    Update-TrackedState 'Подготовка экспорта' @{StagingPath=$staging; StagingPurpose='Создание ZIP'}
    [void](New-Item -ItemType Directory -Path $archive -ErrorAction Stop)
    Write-Host ('Готовый ZIP будет сохранён: ' + $finalArchive) -ForegroundColor Cyan
    Write-OperationReport 'АРХИВ' ('Временный рабочий каталог: ' + $archive)
    Write-OperationReport 'ПУТЬ' ('Готовый ZIP: ' + $finalArchive)
    Write-Host ''
    Write-Host ('Исходный пользователь: ' + $p.Account) -ForegroundColor Cyan
    Write-Host ('Администратор запуска: ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    Write-Host ('Разрешённая область файлов: ' + $p.Path) -ForegroundColor Yellow
    Write-Host ('Архив будет сохранён: ' + $finalArchive)
    Write-Host 'Перед публикацией список USMT будет проверен на выход за пределы профиля.'
    Write-Host 'Без шифрования USMT: используйте защищённый/BitLocker-накопитель.' -ForegroundColor Yellow
    Write-Host 'Установленные программы и сохранённые пароли USMT не переносит.'
    if (-not $AutoApprove -and -not (Confirm 'Начать экспорт?')) {
        Write-OperationReport 'ОТМЕНА' 'Подтверждение экспорта отклонено.'
        Update-TrackedState 'Отменено до экспорта'
        [void](Clear-TrackedStaging $Script:ActiveOpState $false)
        return
    }
    Advance-OperationStage 'Экспорт подтверждён' -MilestoneActivity 'Экспорт профиля' -Milestone 2 -TotalMilestones 8
    Write-OperationReport 'АРХИВ' ('Создаётся: ' + $archive)
    $store = Join-Path $archive 'Store'
    $logBase = Join-Path $Script:WpmWorkRoot 'Logs'
    Initialize-WpmWorkDirectory $logBase
    $logs = Join-Path $logBase ('Export_' + $folderName)
    [void](New-Item -Path $store -ItemType Directory -Force)
    [void](New-Item -Path $logs -ItemType Directory -Force)
    Advance-OperationStage 'Подготовка правил USMT' -Starting
    $rules = New-ProfileOnlyRules $archive $Usmt $logs
    Advance-OperationStage 'Подготовлены правила USMT'
    # Перед ScanState сохраняем SHA-256, не после. Затем сверим источник повторно.
    Assert-ExportProfileReady $p 'перед созданием контрольного реестра'
    Write-Host 'Формирование контрольного списка ДО ScanState...' -ForegroundColor Cyan
    Advance-OperationStage 'Расчёт контрольных сумм источника' -Starting
    $manifest = New-ValidationManifest $p.Path $archive
    Advance-OperationStage 'Создан контрольный реестр до ScanState' -MilestoneActivity 'Экспорт профиля' -Milestone 3 -TotalMilestones 8
    Assert-ExportProfileReady $p 'перед ScanState'
    $listPath = Join-Path $logs 'usmt-files.txt'
    Advance-OperationStage 'Сохранение профиля через ScanState' -Starting
    Invoke-ProfileScan $Usmt $store $rules $logs $listPath $p.Account
    $scopeProof = Save-ProfileScopeProof $listPath $p.Path $archive $rules
    Advance-OperationStage 'Проверка созданного хранилища USMT' -Starting
    Verify-Store $Usmt $store $logs
    Advance-OperationStage 'Целостность USMT проверена' -MilestoneActivity 'Экспорт профиля' -Milestone 4 -TotalMilestones 8
    Write-OperationReport 'УСПЕХ' ('USMT-архив проверен. Файл: ' + (MigFile $store))
    Advance-OperationStage 'Сохранение настроек браузеров' -Starting
    $browserCount = 0
    try { $browserCount = Export-BrowserExtras $p $archive }
    catch { Write-Host ('Дополнительный перенос браузеров пропущен: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Браузеры: ' + $_.Exception.Message) }
    Advance-OperationStage 'Завершена обработка браузеров'
    Advance-OperationStage 'Сохранение значков, настроек и сетевых дисков' -Starting
    $layoutSaved = $false
    try { $layoutSaved = Export-DesktopLayout $p $archive }
    catch { Write-Host ('Расположение значков не сохранено: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Расположение значков: ' + $_.Exception.Message) }
    try { [void](Export-ExplorerAndOneCExtras $p $archive) }
    catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Дополнительные настройки Проводника/1С: ' + $_.Exception.Message) }
    try { [void](Export-NetworkDrives $p $archive) }
    catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Сетевые диски: ' + $_.Exception.Message) }
    Advance-OperationStage 'Сохранены дополнительные настройки Проводника, 1С и дисков'
    Write-OperationReport 'НАСТРОЙКИ' ('Расположение значков: ' + $(if ($layoutSaved) { 'сохранено (без гарантии восстановления на другом мониторе)' } else { 'не сохранено' }))
    Assert-ExportProfileReady $p 'перед повторной сверкой'
    Advance-OperationStage 'Сохранение личных файлов и ярлыков' -Starting
    $personalFiles = Export-PersonalFiles $p $archive $includeDocuments $personalFolders
    Write-Host 'Повторная сверка SHA-256 источника ПОСЛЕ ScanState...' -ForegroundColor Cyan
    Advance-OperationStage 'Повторная сверка контрольных сумм источника' -Starting
    $consistency = Assert-ValidationSourceStable $p.Path $archive $manifest
    Assert-ExportProfileReady $p 'после повторной сверки'
    Advance-OperationStage 'Подтверждена неизменность исходных файлов' -MilestoneActivity 'Экспорт профиля' -Milestone 5 -TotalMilestones 8
    Advance-OperationStage 'Подготовка метаданных и манифеста дополнительных файлов' -Starting
    $extrasManifest=New-ExtrasManifest $archive
    $exportLogs = Join-Path $archive 'Logs'
    [void](New-Item -Path $exportLogs -ItemType Directory -Force)
    Copy-Item -Path (Join-Path $logs '*.log') -Destination $exportLogs -Force
    $archiveMetrics = Get-FolderMetrics $archive
    $os = Get-CimInstance Win32_OperatingSystem
    $meta = [ordered]@{ SchemaVersion=$Script:CurrentArchiveSchema; SourceMachine=$env:COMPUTERNAME; SourceAccount=$p.Account;
        SourceSid=$p.SID; AccountType=$p.Type; SourceProfilePath=$p.Path; SourceWindows=$os.Caption;
        SourceVersion=$os.Version; CreatedAt=(Get-Date).ToString('o'); StoreFolder='Store'; BrowserFiles=$browserCount;
        DesktopLayoutSaved=$layoutSaved; EstimatedProfileBytes=$estimatedBytes; EstimatedProfileFiles=$profileMetrics.Files;
        ArchiveBytes=[UInt64]$archiveMetrics.Bytes; ValidationBaseline=$baseline; ValidationManifest=$manifest; ValidationConsistency=$consistency; ExtrasManifest=$extrasManifest;
        ProfileScope=$scopeProof; PersonalFiles=$personalFiles }
    $meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $archive 'metadata.json') -Encoding UTF8
    Advance-OperationStage 'Созданы метаданные и манифест Extras' -MilestoneActivity 'Экспорт профиля' -Milestone 6 -TotalMilestones 8
    Write-OperationReport 'УСПЕХ' ('Метаданные архива записаны. Браузерных файлов сохранено: ' + $browserCount)
    Write-OperationReport 'ЖУРНАЛ USMT' ('Технические файлы: ' + $exportLogs)
    # ZIP создаётся рядом с рабочим каталогом, затем передаётся в целевую
    # папку под временным именем. Только после проверки SHA-256 переименовываем.
    $partialName = ($folderName + $extension + '.partial_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $localZip = Join-Path $staging $partialName
    $publishedPartial = Join-Path $root $partialName
    try {
        Advance-OperationStage 'Упаковка и защита архива' -Starting
        Write-Host 'Упаковка экспортированного профиля в один ZIP...' -ForegroundColor Cyan
        Update-TrackedState 'Упаковка ZIP'
        if ($ArchivePassword) {
            $plain = Join-Path $staging 'profile.zip'
            try {
                Compress-ProfileArchive $archive $plain
                Convert-WpmArchive $plain $localZip $ArchivePassword
            } finally { [IO.File]::Delete($plain) }
        } else { Compress-ProfileArchive $archive $localZip }
        Advance-OperationStage 'ZIP упакован и проверен' -MilestoneActivity 'Экспорт профиля' -Milestone 7 -TotalMilestones 8
        Advance-OperationStage 'Копирование и публикация архива' -Starting
        Update-TrackedState 'Публикация ZIP' @{NetworkPartialPath=$publishedPartial}
        Ensure-PathAvailable $root 'Папка назначения'
        if (Test-Path -LiteralPath $finalArchive) { throw 'Готовый ZIP с этим именем уже существует.' }
        Write-Host ('Копирование ZIP в папку: ' + $root) -ForegroundColor Cyan
        Copy-DirectoryRobust $staging $root 'копирование ZIP' $partialName
        $localHash = Assert-CopiedZipHash $localZip $publishedPartial
        Write-OperationReport 'ПРОВЕРКА' ('ZIP проверен после копирования, SHA-256: ' + $localHash)
        if (Test-Path -LiteralPath $finalArchive) { throw 'Готовый ZIP с этим именем уже существует.' }
        [IO.File]::Move($publishedPartial,$finalArchive)
        Advance-OperationStage 'ZIP опубликован в папке назначения'
        Update-TrackedState 'ZIP опубликован' @{NetworkPartialPath=''}
        Write-OperationReport 'УСПЕХ' ('ZIP проверен и опубликован: ' + $finalArchive)
        Advance-OperationStage 'Очистка рабочей копии экспорта' -Starting
        [void](Clear-TrackedStaging $Script:ActiveOpState $false)
        $archive = $finalArchive
    } catch [System.OperationCanceledException] {
        Update-TrackedState 'Публикация отменена - локальная копия сохранена' @{StagingDisposition='Рабочие данные сохранены для диагностики'}
        if ($Script:ActiveOpState.NetworkPartialPath) {
            try { [void](Clear-NetworkPartial $Script:ActiveOpState $false) }
            catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось очистить незавершённый ZIP: ' + $_.Exception.Message) }
        }
        Write-OperationReport 'ОТМЕНА' ('Создание ZIP остановлено. Временные данные сохранены: ' + $staging)
        throw
    } catch {
        Update-TrackedState 'Ошибка создания ZIP, временные данные сохранены' @{StagingDisposition='Оставлено для диагностики'}
        Write-OperationReport 'ОШИБКА' ('Не удалось создать или опубликовать ZIP. Временные данные сохранены: ' + $staging)
        throw
    }
    Update-TrackedState 'Экспорт завершён'
    Advance-OperationStage 'Экспорт завершён' -MilestoneActivity 'Экспорт профиля' -Milestone 8 -TotalMilestones 8
    Write-OperationReport 'УСПЕХ' ('Архив экспорта готов: ' + $archive)
    if (-not $KeepReportOpen) { Finish-OperationReport 'УСПЕШНО' }
    Write-Host ('Экспорт готов: ' + $archive) -ForegroundColor Green
    if (-not $KeepReportOpen) {
        Write-Host 'Для импорта запустите этот же Start.cmd на другом устройстве (или скопируйте весь комплект с Backups).'
    }
    return $archive
    } finally {
        if ($ownedPassword -and $ArchivePassword) { $ArchivePassword.Dispose() }
        Write-Progress -Id 7 -Activity 'Экспорт профиля' -Completed
    }
}
