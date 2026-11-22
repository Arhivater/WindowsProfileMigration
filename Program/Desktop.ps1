# Чтение и восстановление расположения значков на рабочем столе.

# Меняем только известные значения Explorer, сохраняя их исходные типы.
function Get-DesktopRegistryValueNames {
    return @('IconLayouts','IconSize','Mode','LogicalViewMode')
}

function Get-DesktopRegistryValues([object]$Hive,[string]$Path) {
    $key = $Hive.OpenSubKey($Path,$false)
    $values = @{}
    try {
        $names = if ($key) { @($key.GetValueNames()) } else { @() }
        foreach ($name in @(Get-DesktopRegistryValueNames)) {
            $values[$name] = $null
            if ($name -in $names) {
                $expectedKind = if ($name -eq 'IconLayouts') { 'Binary' } else { 'DWord' }
                if ([string]$key.GetValueKind($name) -ne $expectedKind) {
                    throw ('Неподдерживаемый тип значения рабочего стола: ' + $name)
                }
                $values[$name] = $key.GetValue($name)
            }
        }
    } finally {
        if ($key) { $key.Dispose() }
    }
    return $values
}

# Проверяем весь документ до открытия реестра на запись.
function Convert-DesktopRegistryValues([object]$Data,[bool]$IsBackup = $false) {
    if ([int]$Data.SchemaVersion -ne 1 -or $null -eq $Data.RegistryItems) {
        throw 'Неизвестный формат расположения значков.'
    }
    $values = @{}
    foreach ($name in @(Get-DesktopRegistryValueNames)) {
        $property = $Data.RegistryItems.PSObject.Properties[$name]
        if (-not $property) {
            if ($IsBackup) { throw ('В резервной копии отсутствует значение ' + $name) }
            continue
        }
        $item = $property.Value
        if ($IsBackup) {
            if ($item.Present -isnot [bool]) { throw ('Некорректное описание резервного значения ' + $name) }
            if (-not $item.Present) {
                $values[$name] = $null
                continue
            }
        }
        if ($name -eq 'IconLayouts' -and $item.Type -eq 'Binary' -and $item.Data -is [string]) {
            $values[$name] = [Convert]::FromBase64String($item.Data)
        } elseif ($name -ne 'IconLayouts' -and $item.Type -eq 'DWord' -and [string]$item.Data -match '^-?[0-9]{1,10}$') {
            $values[$name] = [int]$item.Data
        } else { throw ('Недопустимый тип или данные значения ' + $name) }
    }
    if (-not $IsBackup -and -not $values.ContainsKey('IconLayouts')) {
        throw 'В архиве нет значения IconLayouts.'
    }
    return $values
}

function Write-DesktopRegistryValues([object]$Key,[hashtable]$Values) {
    foreach ($name in $Values.Keys) {
        $value = $Values[$name]
        if ($null -eq $value) { $Key.DeleteValue($name,$false) }
        elseif ($name -eq 'IconLayouts') { $Key.SetValue($name,$value,[Microsoft.Win32.RegistryValueKind]::Binary) }
        else { $Key.SetValue($name,$value,[Microsoft.Win32.RegistryValueKind]::DWord) }
    }
    $Key.Flush()
}

function Set-DesktopRegistryValues([object]$Hive,[string]$Path,[hashtable]$Values,[hashtable]$Previous) {
    $key = $Hive.CreateSubKey($Path)
    if (-not $key) { throw 'Не удалось открыть ветку расположения рабочего стола.' }
    try { Write-DesktopRegistryValues $key $Values }
    catch {
        # Запись нескольких параметров не атомарна. Возвращаем снимок при сбое.
        try { Write-DesktopRegistryValues $key $Previous }
        catch { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Автоматический возврат расположения значков не удался: ' + $_.Exception.Message) }
        throw
    } finally { $key.Dispose() }
}

# Сохраняет последнее расположение, записанное Explorer.
function Export-DesktopLayout([object]$Profile,[string]$Archive) {
    $values = Invoke-ProfileHive $Profile.SID $Profile.Path {
        param($hku,$mount)
        Get-DesktopRegistryValues $hku ($mount + '\Software\Microsoft\Windows\Shell\Bags\1\Desktop')
    }
    if ($null -eq $values['IconLayouts']) { return $false }
    $items = @{}
    foreach ($name in $values.Keys) {
        if ($null -eq $values[$name]) { continue }
        $items[$name] = if ($name -eq 'IconLayouts') {
            @{Type='Binary'; Data=[Convert]::ToBase64String([byte[]]$values[$name])}
        } else { @{Type='DWord'; Data=[int]$values[$name]} }
    }
    $data = [ordered]@{SchemaVersion=1; SourceSid=[string]$Profile.SID; RegistryItems=$items}
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $data['PrimaryWidth'] = $screen.Width
        $data['PrimaryHeight'] = $screen.Height
        $data['DisplayCount'] = @([System.Windows.Forms.Screen]::AllScreens).Count
    } catch { }
    $layoutFile = Join-Path $Archive 'Extras/DesktopLayout.json'
    Assert-ProfileExtraPath $layoutFile $Archive $true
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $layoutFile))
    $data | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $layoutFile -Encoding UTF8 -ErrorAction Stop
    Write-Host 'Последнее сохранённое Windows расположение ярлыков записано.' -ForegroundColor Green
    return $true
}

# С подтверждением применяет сохранённые настройки значков.
function Restore-DesktopLayout(
    [string]$Archive,[string]$Sid,[string]$TargetPath,[bool]$AutoApprove = $false,[string]$ExpectedHash = ''
) {
    $layoutFile = Join-Path $Archive 'Extras/DesktopLayout.json'
    if (-not [IO.File]::Exists($layoutFile)) {
        Write-OperationReport 'НАСТРОЙКИ' 'Расположение значков отсутствует в архиве.'
        return
    }
    $data = Read-ExtraJson $layoutFile $Archive $ExpectedHash
    $values = Convert-DesktopRegistryValues $data
    Write-Host 'Найдены сохранённые позиции значков рабочего стола.' -ForegroundColor Cyan
    Write-Host 'Расположение зависит от версии Windows, масштаба, разрешения и количества мониторов.' -ForegroundColor Yellow
    if (@('PrimaryWidth','PrimaryHeight','DisplayCount' | Where-Object { $data.PSObject.Properties[$_] }).Count -eq 3) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            if ($screen.Width -ne $data.PrimaryWidth -or $screen.Height -ne $data.PrimaryHeight -or
                @([System.Windows.Forms.Screen]::AllScreens).Count -ne $data.DisplayCount) {
                Write-Host 'Конфигурация мониторов отличается. Проверьте расположение после входа.' -ForegroundColor Yellow
            }
        } catch { }
    }
    if (-not $AutoApprove -and -not (Confirm 'Попробовать применить сохранённое расположение значков?')) {
        Write-OperationReport 'ОТМЕНА' 'Позиции значков не применялись по выбору пользователя.'
        return
    }
    Invoke-ProfileHive $Sid $TargetPath {
        param($hku,$mount)
        $keyPath = $mount + '\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
        $previous = Get-DesktopRegistryValues $hku $keyPath
        $snapshot = [ordered]@{SchemaVersion=1; TargetSid=$Sid; TargetProfile=$TargetPath;
            RegistryItems=@{}; SavedAt=(Get-Date).ToString('o')}
        foreach ($name in $previous.Keys) {
            $snapshot.RegistryItems[$name] = if ($null -eq $previous[$name]) {
                @{Present=$false; Type=''; Data=$null}
            } elseif ($name -eq 'IconLayouts') {
                @{Present=$true; Type='Binary'; Data=[Convert]::ToBase64String([byte[]]$previous[$name])}
            } else { @{Present=$true; Type='DWord'; Data=[int]$previous[$name]} }
        }
        $backupFolder = Join-Path $Script:WpmWorkRoot 'DesktopBackups'
        Initialize-WpmWorkDirectory $backupFolder
        $backupPath = Join-Path $backupFolder ('Desktop_' + [guid]::NewGuid().ToString('N') + '.json')
        $bytes = [Text.Encoding]::UTF8.GetBytes(($snapshot | ConvertTo-Json -Depth 5))
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $snapshotHash = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-','') }
        finally { $hasher.Dispose() }
        $out = [IO.File]::Open($backupPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $out.Write($bytes,0,$bytes.Length)
            $out.Flush($true)
        } finally { $out.Dispose() }
        Update-TrackedState '' @{DesktopBackup=$backupPath;DesktopBackupSha256=$snapshotHash}
        Write-OperationReport 'РЕЗЕРВ' ('Прежние значения рабочего стола сохранены: ' + $backupPath)
        Set-DesktopRegistryValues $hku $keyPath $values $previous
    } $true
    Write-Host 'Расположение записано. Windows попробует применить его при входе пользователя.' -ForegroundColor Green
    Write-OperationReport 'НАСТРОЙКИ' 'Позиции значков записаны в реестр. Проверьте их при входе под целевым пользователем.'
}

# Восстанавливает только локальную резервную копию для зарегистрированного SID и пути.
function Restore-PreviousDesktopLayout([string]$BackupFile,[string]$ExpectedHash) {
    if ($ExpectedHash -notmatch '^[a-f0-9]{64}$') { throw 'Некорректная контрольная сумма резервной копии.' }
    $backupRoot = [IO.Path]::GetFullPath((Join-Path $Script:WpmWorkRoot 'DesktopBackups'))
    Assert-WpmWorkRoot
    Assert-WpmWorkAcl $backupRoot
    $backupPath = [IO.Path]::GetFullPath($BackupFile)
    if ([IO.Path]::GetDirectoryName($backupPath) -ine $backupRoot -or
        [IO.Path]::GetFileName($backupPath) -notmatch '^Desktop_[a-f0-9]{32}\.json$') {
        throw 'Путь вне каталога резервных копий расположения значков.'
    }
    $data = Read-ExtraJson $backupPath $Script:WpmWorkRoot $ExpectedHash
    $values = Convert-DesktopRegistryValues $data $true
    $sid = [string]$data.TargetSid
    if ($sid -notmatch '^S-1-(?:[0-9]+-){1,14}[0-9]+$' -or -not $data.TargetProfile) {
        throw 'Некорректный пользователь в резервной копии.'
    }
    $registered = @(Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID='" + $sid + "'") -ErrorAction Stop)
    $targetPath = [IO.Path]::GetFullPath([string]$data.TargetProfile)
    if ($registered.Count -ne 1 -or $registered[0].Special -or
        [IO.Path]::GetFullPath([string]$registered[0].LocalPath) -ine $targetPath) {
        throw 'SID или путь зарегистрированного профиля больше не совпадает с резервной копией.'
    }
    if (-not (Confirm ('Восстановить прежние позиции значков пользователя ' + $sid + ' ?'))) { return $false }
    Invoke-ProfileHive $sid $targetPath {
        param($hku,$mount)
        $keyPath = $mount + '\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
        $current = Get-DesktopRegistryValues $hku $keyPath
        Set-DesktopRegistryValues $hku $keyPath $values $current
    } $true
    Write-Host 'Настройки возвращены. Проверьте их после нового входа пользователя.' -ForegroundColor Green
    return $true
}

# Находит зарегистрированный в Windows целевой профиль по учётной записи.
function Get-TargetUserProfile([string]$Account) {
    $sid = ([Security.Principal.NTAccount]::new($Account)).Translate([Security.Principal.SecurityIdentifier]).Value
    $profile = @(Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID='" + $sid + "'") -ErrorAction Stop)
    if ($profile.Count -ne 1 -or $profile[0].Special -or (([int]$profile[0].Status) -band 9) -or
        -not (Test-Path -LiteralPath $profile[0].LocalPath -PathType Container)) {
        throw ('Профиль назначения после USMT не обнаружен для ' + $Account + '. Дополнительные данные сохранены в архиве, но не восстановлены.')
    }
    return [pscustomobject]@{Sid=$sid; Path=[string]$profile[0].LocalPath; Loaded=[bool]$profile[0].Loaded}
}
