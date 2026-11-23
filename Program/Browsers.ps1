# Сохраняем выбранные данные браузеров и бережно возвращаем их в профиль.

function Get-BrowserExtraFileNames {
    return @('Bookmarks','Bookmarks.bak','History','Visited Links','Favicons',
        'Top Sites','Preferences','Secure Preferences','Current Session','Last Session','Current Tabs','Last Tabs')
}

function Test-BrowserExtraRelativePath([string]$Relative) {
    $parts = $Relative -split '[/\\]'
    if ($parts.Count -lt 2 -or $parts[0] -notmatch '^(Default|Profile [0-9]+)$') { return $false }
    if ($parts.Count -eq 2) { return ($parts[1] -in @(Get-BrowserExtraFileNames)) }
    return ($parts.Count -eq 3 -and $parts[1] -eq 'Sessions' -and $parts[2] -match '^(Session|Tabs)_[0-9]+$')
}

# Сохраняет доступные закладки, историю и файлы сеансов; ошибка одного браузера не блокирует остальные.
function Export-BrowserExtras([object]$Profile,[string]$Archive) {
    # Если один браузер занят или его файлы недоступны, продолжаем проверять остальные.
    $extras = Join-Path $Archive 'Extras\Browsers'
    $busy = @(Get-OpenTargetBrowsers ([string]$Profile.SID))
    $total = 0
    $fileNames = @(Get-BrowserExtraFileNames)
    Title 'ДОПОЛНИТЕЛЬНОЕ СОХРАНЕНИЕ БРАУЗЕРОВ'
    $browserDefinitions = @(Browser-Definitions)
    $activity = 'Сохранение данных браузеров'
    $browserIndex = 0
    Write-OperationReport 'БРАУЗЕР' ('Начата проверка браузеров для экспорта. Браузеров: ' + $browserDefinitions.Count)
    try {
        foreach ($browser in $browserDefinitions) {
            $percent = [int][Math]::Floor(100.0 * $browserIndex / $browserDefinitions.Count)
            Write-Progress -Id 9 -Activity $activity -Status ("Браузеров обработано: {0} из {1}. Сейчас: {2}" -f $browserIndex,$browserDefinitions.Count,$browser.Name) -PercentComplete $percent
            $saved = 0
            $missed = 0
            $state = 'Не найден'
            $reason = ''
            try {
                $src = Join-Path (Join-Path $Profile.Path 'AppData\Local') $browser.Relative
                if (-not (Test-Path -LiteralPath $src -PathType Container)) {
                    $reason = 'Каталог пользовательских данных отсутствует'
                } elseif ($busy -contains $browser.Process) {
                    $state = 'Пропущен'
                    $reason = 'Браузер запущен. Закройте его перед повторным экспортом.'
                } else {
                    Assert-ProfileExtraPath $src $Profile.Path
                    $destRoot = Join-Path $extras $browser.Id
                    $folders = @(Get-ChildItem -LiteralPath $src -Directory -Force -ErrorAction Stop | Where-Object {
                        $_.Name -eq 'Default' -or $_.Name -match '^Profile [0-9]+$'
                    })
                    foreach ($folder in $folders) {
                        foreach ($filename in $fileNames) {
                            $from = Join-Path $folder.FullName $filename
                            $to = Join-Path (Join-Path $destRoot $folder.Name) $filename
                            try {
                                if (Copy-RequiredFile $from $to $Profile.Path $Archive) {
                                    $saved++
                                }
                            } catch {
                                $missed++
                                if ($missed -le 5) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Файл браузера ' + $browser.Name + ' пропущен: ' + $_.Exception.Message) }
                            }
                        }
                        $sessions = Join-Path $folder.FullName 'Sessions'
                        if (Test-Path -LiteralPath $sessions -PathType Container) {
                            try {
                                Assert-ProfileExtraPath $sessions $Profile.Path
                                $sessionFiles = @(Get-ChildItem -LiteralPath $sessions -File -Force -ErrorAction Stop |
                                    Where-Object { $_.Name -match '^(Session|Tabs)_[0-9]+$' })
                                foreach ($file in $sessionFiles) {
                                    $to = Join-Path (Join-Path (Join-Path $destRoot $folder.Name) 'Sessions') $file.Name
                                    try {
                                        if (Copy-RequiredFile $file.FullName $to $Profile.Path $Archive) {
                                            $saved++
                                        }
                                    } catch {
                                        $missed++
                                        if ($missed -le 5) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Файл сеанса ' + $browser.Name + ' пропущен: ' + $_.Exception.Message) }
                                    }
                                }
                            } catch {
                                $missed++
                                if ($missed -le 5) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось прочитать сеансы ' + $browser.Name + '. ' + $_.Exception.Message) }
                            }
                        }
                    }
                    if ($saved -gt 0) {
                        $state = if ($missed -gt 0) { 'Частично' } else { 'Сохранён' }
                    } elseif ($missed -gt 0) {
                        $state = 'Не удалось'
                    } else {
                        $state = 'Нет данных'
                        $reason = 'В профилях браузера не найдены поддерживаемые файлы'
                    }
                }
            } catch {
                $missed++
                $state = if ($saved -gt 0) { 'Частично' } else { 'Не удалось' }
                $reason = $_.Exception.Message
            }
            $total += $saved
            Write-Host ('{0}: {1} (файлов: {2}; пропущено: {3})' -f $browser.Name,$state,$saved,$missed)
            $line = '{0}: {1}; скопировано: {2}; пропущено: {3}' -f $browser.Name,$state,$saved,$missed
            if ($reason) { $line += '; причина: ' + $reason }
            Write-OperationReport $(if ($missed -gt 0 -or $state -in @('Пропущен','Не удалось','Частично')) { 'ПРЕДУПРЕЖДЕНИЕ' } else { 'БРАУЗЕР' }) $line
            if ($reason) { Write-Host ('  ' + $reason) -ForegroundColor Yellow }
            $browserIndex++
        }
    } finally {
        Write-Progress -Id 9 -Activity $activity -Completed
        Write-OperationReport 'БРАУЗЕР' ('Экспорт браузеров: обработано {0} из {1}, скопировано файлов {2}.' -f $browserIndex,$browserDefinitions.Count,$total)
    }
    if ($total -eq 0) { Write-Host 'Дополнительных файлов браузеров не скопировано; USMT-архив при этом сохранён.' -ForegroundColor Yellow }
    return $total
}
# Восстанавливает сохранённые файлы браузеров и резервирует заменяемые оригиналы.
function Restore-BrowserExtras([string]$Archive,[string]$TargetPath,[string]$TargetSid,[hashtable]$ApprovedExtras = $null,[bool]$AutoApprove = $false) {
    $extras = Join-Path $Archive 'Extras\Browsers'
    if (-not (Test-Path -LiteralPath $extras -PathType Container)) {
        Write-Host 'Дополнительных файлов браузеров нет: пропускаем.' -ForegroundColor Yellow
        Write-OperationReport 'БРАУЗЕР' 'Дополнительные данные браузеров в архиве отсутствуют.'
        return
    }
    Title 'ВОССТАНОВЛЕНИЕ БРАУЗЕРОВ'
    Write-Host 'Будут обработаны только данные, которые удалось сохранить при экспорте.'
    Write-Host 'Открытые браузеры автоматически пропускаются. Пароли и cookie отдельно не копируются.'
    if (-not $AutoApprove -and -not (Confirm 'Восстановить доступные файлы браузеров?')) { Write-OperationReport 'ОТМЕНА' 'Восстановление браузеров отклонено пользователем.'; return }
    $busy = @(Get-OpenTargetBrowsers $TargetSid)
    $backupBase = Join-Path $Script:WpmWorkRoot 'BrowserBackups'
    Initialize-WpmWorkDirectory $backupBase
    $recovery = Join-Path $backupBase ((Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    Update-TrackedState '' @{BrowserBackupPath=$recovery}
    $browserDefinitions = @(Browser-Definitions)
    $activity = 'Восстановление данных браузеров'
    $browserIndex = 0
    $totalRestored = 0
    $totalSkipped = 0
    $totalPrevious = 0
    Write-OperationReport 'БРАУЗЕР' ('Начата проверка браузеров для восстановления. Браузеров: ' + $browserDefinitions.Count)
    try {
        foreach ($browser in $browserDefinitions) {
            $percent = [int][Math]::Floor(100.0 * $browserIndex / $browserDefinitions.Count)
            Write-Progress -Id 9 -Activity $activity -Status ("Браузеров обработано: {0} из {1}. Сейчас: {2}" -f $browserIndex,$browserDefinitions.Count,$browser.Name) -PercentComplete $percent
            $restored = 0
            $skipped = 0
            $previous = 0
            $state = 'Нет в архиве'
            $reason = ''
            try {
                $sourceRoot = Join-Path $extras $browser.Id
                if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
                    $reason = 'Этот браузер не был сохранён'
                } elseif ($busy -contains $browser.Process) {
                    $state = 'Пропущен'
                    $reason = 'Браузер запущен на целевом устройстве. Закройте его перед повтором.'
                } else {
                    Assert-ProfileExtraPath $sourceRoot $Archive
                    $destRoot = Join-Path (Join-Path $TargetPath 'AppData\Local') $browser.Relative
                    $folders = @(Get-ChildItem -LiteralPath $sourceRoot -Directory -Force -ErrorAction Stop |
                        Where-Object { $_.Name -match '^(Default|Profile [0-9]+)$' })
                    foreach ($folder in $folders) {
                        try {
                            Assert-ProfileExtraPath $folder.FullName $Archive
                            $files = @(Get-ChildItem -LiteralPath $folder.FullName -File -Force -ErrorAction Stop)
                        } catch {
                            $skipped++
                            if ($skipped -le 5) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось прочитать профиль ' + $browser.Name + '/' + $folder.Name + ': ' + $_.Exception.Message) }
                            continue
                        }
                        $sessions = Join-Path $folder.FullName 'Sessions'
                        if (Test-Path -LiteralPath $sessions -PathType Container) {
                            try {
                                Assert-ProfileExtraPath $sessions $Archive
                                $files += @(Get-ChildItem -LiteralPath $sessions -File -Force -ErrorAction Stop)
                            } catch {
                                $skipped++
                                if ($skipped -le 5) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Не удалось прочитать сеансы ' + $browser.Name + '/' + $folder.Name + ': ' + $_.Exception.Message) }
                            }
                        }
                        foreach ($file in $files) {
                            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart([char[]]@('\','/'))
                            if (-not (Test-BrowserExtraRelativePath $relative)) {
                                $skipped++
                                if ($skipped -le 5) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Браузер: неподдерживаемый файл пропущен: ' + $browser.Name) }
                                continue
                            }
                            $manifestKey = 'Browsers\' + $browser.Id + '\' + $relative.Replace('/','\')
                            if (-not (Is-AllowedExtra $ApprovedExtras $manifestKey)) {
                                $skipped++
                                if ($skipped -le 5) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Файл ' + $browser.Name + ' пропущен: не прошёл проверку SHA-256.') }
                                continue
                            }
                            $dest = Join-Path $destRoot $relative
                            $backup = Join-Path (Join-Path $recovery $browser.Id) $relative
                            $hash = if ($null -ne $ApprovedExtras) { [string]$ApprovedExtras[$manifestKey] } else { '' }
                            try {
                                if (-not (Copy-RequiredFile -From $file.FullName -To $dest -AllowedSourceRoot $Archive -AllowedDestinationRoot $TargetPath -Backup $backup -ExpectedHash $hash)) {
                                    throw 'Файл исчез до восстановления.'
                                }
                                $restored++
                            } catch {
                                $skipped++
                                if ($skipped -le 5) { Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' ('Ошибка восстановления: ' + $browser.Name + '/' + $relative + ': ' + $_.Exception.Message) }
                            } finally {
                                if ([IO.File]::Exists($backup)) { $previous++ }
                            }
                        }
                    }
                    if ($restored -gt 0) {
                        $state = if ($skipped -gt 0) { 'Частично' } else { 'Восстановлен' }
                    } elseif ($skipped -gt 0) {
                        $state = 'Не удалось'
                    } else {
                        $state = 'Нет данных'
                    }
                }
            } catch {
                $skipped++
                $state = if ($restored -gt 0) { 'Частично' } else { 'Не удалось' }
                $reason = $_.Exception.Message
            }
            Write-Host ('{0}: {1} (восстановлено: {2}; пропущено: {3})' -f $browser.Name,$state,$restored,$skipped)
            $line = '{0}: {1}; восстановлено: {2}; пропущено: {3}; резервировано прежних файлов: {4}' -f $browser.Name,$state,$restored,$skipped,$previous
            if ($reason) { $line += '; причина: ' + $reason }
            Write-OperationReport $(if ($skipped -gt 0 -or $state -in @('Пропущен','Не удалось','Частично')) { 'ПРЕДУПРЕЖДЕНИЕ' } else { 'БРАУЗЕР' }) $line
            if ($reason) { Write-Host ('  ' + $reason) -ForegroundColor Yellow }
            $totalRestored += $restored
            $totalSkipped += $skipped
            $totalPrevious += $previous
            $browserIndex++
        }
    } finally {
        Write-Progress -Id 9 -Activity $activity -Completed
        Write-OperationReport 'БРАУЗЕР' ('Импорт браузеров: обработано {0} из {1}, восстановлено файлов {2}, ошибок и пропусков {3}, резервных копий {4}.' -f $browserIndex,$browserDefinitions.Count,$totalRestored,$totalSkipped,$totalPrevious)
    }
    Write-Host ('Резервные копии заменённых файлов (если были): ' + $recovery)
    Write-OperationReport 'РЕЗЕРВ' ('При замене браузерных файлов резервные копии сохраняются в: ' + $recovery)
    Write-Host 'Статус USMT не зависит от результатов дополнительного переноса браузеров.' -ForegroundColor Yellow
}
