. (Get-WpmFunctionDefinitions -Name @(
    'Test-ExtraPathComponent','Assert-ProfileExtraPath','Copy-RequiredFile','Get-ExactFileSha256','Get-ExtraStreamSha256',
    'Read-ExtraJson','New-ExtrasManifest','Test-ExtrasManifest','Is-AllowedExtra',
    'Browser-Definitions','Get-BrowserExtraFileNames','Test-BrowserExtraRelativePath','Restore-BrowserExtras',
    'Test-NetworkDriveRemotePath','Get-DesktopRegistryValueNames','Convert-DesktopRegistryValues',
    'Write-DesktopRegistryValues','Set-DesktopRegistryValues','Quote-WindowsArgument','Invoke-ProfileRegistryCommand'
))

function Write-OperationReport([string]$Kind,[string]$Message) { }
function Update-TrackedState([string]$Status,[hashtable]$State) { }
function Get-OpenTargetBrowsers([string]$Sid) { }
function Title([string]$Text) { }

Invoke-WpmTest 'Extras browser allowlist accepts documented locations only' {
    foreach ($path in @('Default\Bookmarks','Profile 23/History','Default/Sessions/Tabs_123','Profile 1\Sessions\Session_321')) {
        Assert-WpmEqual (Test-BrowserExtraRelativePath $path) $true $path
    }
    foreach ($path in @('Default/Cookies','Default/Login Data','Default/Extension State/store',
        'Default/Sessions/../Login Data','Default/Sessions/Tabs_1.exe','../Bookmarks','Guest Profile/Bookmarks',
        'Default/Bookmarks.','AppData/Default/History')) {
        Assert-WpmEqual (Test-BrowserExtraRelativePath $path) $false $path
    }
}

Invoke-WpmTest 'Extras permits valid UNC shares and rejects namespaces and aliases' {
    foreach ($path in @('\\pc\share','\\corp.example.net\Файлы\Папка','\\192.0.2.5\Share\','\\admin-pc\C$\Logs')) {
        Assert-WpmEqual (Test-NetworkDriveRemotePath $path) $true $path
    }
    foreach ($path in @('\\.\GLOBALROOT\test','\\?\C:\Users','\\pc','\\pc\share\..','\\pc\share\a:b',
        'C:\Folder','\\pc\\share','\\pc\share.','\\pc\share\ .')) {
        Assert-WpmEqual (Test-NetworkDriveRemotePath $path) $false $path
    }
}

Invoke-WpmTest 'Extras copies verified data, preserves old bytes on mismatch, and keeps backup' {
    $archive = Join-Path $WpmTestRoot 'Archive'
    $profile = Join-Path $WpmTestRoot 'Profile'
    [void][IO.Directory]::CreateDirectory($archive)
    [void][IO.Directory]::CreateDirectory($profile)
    $source = Join-Path $archive 'sample'
    $target = Join-Path $profile 'target'
    $backup = Join-Path $WpmTestRoot 'Backup/prior'
    [IO.File]::WriteAllText($source,'new')
    [IO.File]::WriteAllText($target,'old')
    $programData = $env:ProgramData
    try {
        $env:ProgramData = $WpmTestRoot
        Assert-WpmThrows { Copy-RequiredFile $source $target $archive $profile $backup ('0' * 64) } 'SHA-256'
        Assert-WpmEqual ([IO.File]::ReadAllText($target)) 'old'
        Assert-WpmEqual ([IO.File]::Exists($backup)) $false
        Assert-WpmEqual (@(Get-ChildItem -LiteralPath $profile -Force -Filter '.WPM_*.tmp').Count) 0
        Assert-WpmEqual (Copy-RequiredFile $source $target $archive $profile $backup (Get-ExactFileSha256 $source)) $true
        Assert-WpmEqual ([IO.File]::ReadAllText($target)) 'new'
        Assert-WpmEqual ([IO.File]::ReadAllText($backup)) 'old'
        Assert-WpmEqual (Copy-RequiredFile (Join-Path $archive 'missing') (Join-Path $profile 'no') $archive $profile) $false
    } finally { $env:ProgramData = $programData }
}

Invoke-WpmTest 'Extras rejects out-of-profile paths and existing redirecting directories' {
    $profile = Join-Path $WpmTestRoot 'Profile'
    $outside = Join-Path $WpmTestRoot 'Outside'
    [void][IO.Directory]::CreateDirectory($profile)
    [void][IO.Directory]::CreateDirectory($outside)
    $redirect = Join-Path $profile 'Redirect'
    $linkType = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
    [void](New-Item -Path $redirect -ItemType $linkType -Target $outside -ErrorAction Stop)
    try {
        Assert-WpmThrows { Assert-ProfileExtraPath (Join-Path $outside 'file') $profile $true } 'Путь вне'
        Assert-WpmThrows { Assert-ProfileExtraPath (Join-Path $redirect 'file') $profile $true } 'Ссылка'
        Assert-WpmThrows { Copy-RequiredFile (Join-Path $redirect 'file') (Join-Path $profile 'copy') $profile $profile } 'Ссылка'
        $authorized = Join-Path $profile 'safe'
        [IO.File]::WriteAllText($authorized,'data')
        Assert-WpmThrows { Copy-RequiredFile $authorized (Join-Path $redirect 'file') $profile $profile } 'Ссылка'
        Assert-WpmEqual ([IO.File]::Exists((Join-Path $outside 'file'))) $false
    } finally { [IO.Directory]::Delete($redirect) }
}

Invoke-WpmTest 'Extras manifest rejects Windows aliases and duplicates, and excludes changed bytes' {
    $extras = Join-Path $WpmTestRoot 'Extras/OneC'
    [void][IO.Directory]::CreateDirectory($extras)
    $sample = Join-Path $extras 'ibases.v8i'
    [IO.File]::WriteAllText($sample,'[Синтетическая база]')
    $info = New-ExtrasManifest $WpmTestRoot
    $meta = [pscustomobject]@{SchemaVersion=7; ExtrasManifest=$info}
    $manifest = Join-Path $WpmTestRoot $info.Path
    $approved = Test-ExtrasManifest $WpmTestRoot $meta
    Assert-WpmEqual $approved['OneC\ibases.v8i'] (Get-ExactFileSha256 $sample)
    [IO.File]::WriteAllText($sample,'[Обновлено]')
    Assert-WpmEqual ((Test-ExtrasManifest $WpmTestRoot $meta).Count) 0
    $validLine = [IO.File]::ReadAllText($manifest).Trim()
    $caseAlias = $validLine.Replace('ibases.v8i','IBASES.V8I')
    [IO.File]::WriteAllLines($manifest,[string[]]@($validLine,$caseAlias))
    Assert-WpmThrows { Test-ExtrasManifest $WpmTestRoot $meta } 'Повторяющийся'
    foreach ($alias in @('ibases.v8i:stream','ibases.v8i.','NUL.ini','../ibases.v8i')) {
        [IO.File]::WriteAllText($manifest,$validLine.Replace('ibases.v8i',$alias))
        Assert-WpmThrows { Test-ExtrasManifest $WpmTestRoot $meta } 'Недопустимый путь'
    }
}

Invoke-WpmTest 'Extras browser restore skips unexpected files and keeps other browsers independent' {
    $archive = Join-Path $WpmTestRoot 'Archive'
    $profile = Join-Path $WpmTestRoot 'Profile'
    [void][IO.Directory]::CreateDirectory($profile)
    $chrome = Join-Path $archive 'Extras/Browsers/Chrome/Default'
    $edge = Join-Path $archive 'Extras/Browsers/Edge/Profile 2'
    [void][IO.Directory]::CreateDirectory($chrome)
    [void][IO.Directory]::CreateDirectory($edge)
    [IO.File]::WriteAllText((Join-Path $chrome 'Bookmarks'),'chrome')
    [IO.File]::WriteAllText((Join-Path $chrome 'Login Data'),'synthetic unexpected name')
    [IO.File]::WriteAllText((Join-Path $edge 'History'),'edge')
    $meta = [pscustomobject]@{SchemaVersion=7; ExtrasManifest=(New-ExtrasManifest $archive)}
    $approved = Test-ExtrasManifest $archive $meta
    [IO.File]::WriteAllText((Join-Path $chrome 'Bookmarks'),'changed after manifest')
    $programData = $env:ProgramData
    try {
        $env:ProgramData = $WpmTestRoot
        Restore-BrowserExtras $archive $profile 'S-1-5-21-5' $approved $true
    } finally { $env:ProgramData = $programData }
    Assert-WpmEqual ([IO.File]::Exists((Join-Path $profile 'AppData/Local/Google/Chrome/User Data/Default/Bookmarks'))) $false
    Assert-WpmEqual ([IO.File]::Exists((Join-Path $profile 'AppData/Local/Google/Chrome/User Data/Default/Login Data'))) $false
    Assert-WpmEqual ([IO.File]::ReadAllText((Join-Path $profile 'AppData/Local/Microsoft/Edge/User Data/Profile 2/History'))) 'edge'
}

Invoke-WpmTest 'Extras desktop layout accepts absent display metadata and rejects bad values before writes' {
    $valid = '{"SchemaVersion":1,"RegistryItems":{"IconLayouts":{"Type":"Binary","Data":"AQID"},"Mode":{"Type":"DWord","Data":2}}}'
    $dataPath = Join-Path $WpmTestRoot 'DesktopLayout.json'
    [IO.File]::WriteAllText($dataPath,$valid)
    $digest = Get-ExactFileSha256 $dataPath
    $values = Convert-DesktopRegistryValues (Read-ExtraJson $dataPath $WpmTestRoot $digest)
    Assert-WpmEqual $values['IconLayouts'] ([byte[]]@(1,2,3))
    Assert-WpmEqual $values['Mode'] 2
    $invalid = $valid.Replace('"Data":2','"Data":"not an integer"')
    [IO.File]::WriteAllText($dataPath,$invalid)
    Assert-WpmThrows { Read-ExtraJson $dataPath $WpmTestRoot $digest } 'изменился после проверки'
    Assert-WpmThrows { Convert-DesktopRegistryValues ($invalid | ConvertFrom-Json) } 'Недопустимый тип'
}

Invoke-WpmTest 'Extras desktop rollback restores all values after simulated partial failure' {
    $old = @{IconLayouts=[byte[]]@(4,5); Mode=2; LogicalViewMode=1; IconSize=$null}
    $key = [pscustomobject]@{Values=@{IconLayouts=$old.IconLayouts; Mode=2; LogicalViewMode=1}; Writes=0}
    $key | Add-Member ScriptMethod SetValue {
        param($Name,$Value,$Kind)
        $this.Writes++
        if ($this.Writes -eq 2) { throw 'Synthetic write failure' }
        $this.Values[$Name] = $Value
    }
    $key | Add-Member ScriptMethod DeleteValue { param($Name,$Ignored); [void]$this.Values.Remove($Name) }
    $key | Add-Member ScriptMethod Flush { }
    $key | Add-Member ScriptMethod Dispose { }
    $hive = [pscustomobject]@{Key=$key}
    $hive | Add-Member ScriptMethod CreateSubKey { param($Path); return $this.Key }
    $changes = @{Mode=4; LogicalViewMode=3; IconSize=128}
    Assert-WpmThrows { Set-DesktopRegistryValues $hive 'synthetic\Desktop' $changes $old } 'Synthetic write failure'
    Assert-WpmEqual $key.Values['IconLayouts'] ([byte[]]@(4,5))
    Assert-WpmEqual $key.Values['Mode'] 2
    Assert-WpmEqual $key.Values['LogicalViewMode'] 1
    Assert-WpmEqual $key.Values.ContainsKey('IconSize') $false
}

Invoke-WpmTest 'Extras registry launch preserves account path argument and process exit code' {
    $syntheticProcess = [pscustomobject]@{ExitCode=0; Disposed=$false}
    $syntheticProcess | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
    function Start-Process {
        [CmdletBinding()]
        param([string]$FilePath,[string]$ArgumentList,[switch]$NoNewWindow,[switch]$Wait,[switch]$PassThru)
        Assert-WpmEqual $FilePath (Join-Path $WpmTestRoot 'System32/reg.exe')
        Assert-WpmEqual $ArgumentList 'load HKU\WPM_Synthetic "C:\Профили\Имя Пользователя\NTUSER.DAT"'
        Assert-WpmEqual ($NoNewWindow -and $PassThru -and $Wait) $true
        return $syntheticProcess
    }
    $systemRoot = $env:SystemRoot
    try {
        $env:SystemRoot = $WpmTestRoot
        $arguments = @('load','HKU\WPM_Synthetic','C:\Профили\Имя Пользователя\NTUSER.DAT')
        Assert-WpmEqual (Invoke-ProfileRegistryCommand $arguments) 0
        Assert-WpmEqual $syntheticProcess.Disposed $true
        $syntheticProcess.ExitCode=5
        $syntheticProcess.Disposed=$false
        Assert-WpmEqual (Invoke-ProfileRegistryCommand $arguments) 5
        Assert-WpmEqual $syntheticProcess.Disposed $true
    } finally { $env:SystemRoot = $systemRoot }
}
