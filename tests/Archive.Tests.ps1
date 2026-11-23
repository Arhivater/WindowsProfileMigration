#Requires -Version 5.1

. (Get-WpmFunctionDefinitions -Name Format-ByteSize,Assert-WindowsPathComponent,Get-WindowsRelativePathParts,
    Get-ProfileDataItem,Assert-NoReparseAncestor,Get-ArchiveFileMap,Initialize-ZipSupport,Get-ProfileZipInfo,
    Read-ProfileZipInfo,Read-BoundedArchiveMetadata,Read-ArchiveMetadataFile,
    Compress-ProfileArchive,Expand-ProfileArchive,Get-ExactFileSha256,Read-MigrationXml,
    Get-ValidationSourceDirectories,Get-ValidationSourceFiles,Read-ValidationManifestRecord,
    New-ValidationManifest,Assert-ValidationSourceStable,Assert-ValidationManifestIntegrity,Test-ValidationManifest,
    Assert-ExportProfileReady,Write-EmbeddedProfileOnlyRule,Get-CurrentProfileOnlyRuleHash,Assert-ProfileOnlyArchive,Assert-ArchiveCacheOutsideSource,
    Copy-DirectoryRobust,Quote-WindowsArgument,Inspect-UsmtFileScope)

function Write-OperationReport {}
function Test-RunningProcessStopRequest { $false }
function Get-PathFreeBytes { 8GB }

function New-TestProfileZip([string]$Path,[string[]]$EntryNames,[string]$Metadata = '{"SchemaVersion":7}') {
    Initialize-ZipSupport
    $zip = [IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in (@('metadata.json','Store/USMT.MIG') + $EntryNames)) {
            $entry = $zip.CreateEntry($name)
            if ($name.EndsWith('/')) { continue }
            $writer = [IO.StreamWriter]::new($entry.Open())
            try {
                if ($name -eq 'metadata.json') { $writer.Write($Metadata) }
                else { $writer.Write('fixture') }
            } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
}

Invoke-WpmTest 'Archive ZIP round trip preserves paths and bytes' {
    $source = Join-Path $WpmTestRoot 'исходный каталог'
    $store = Join-Path $source 'Store'
    [void][IO.Directory]::CreateDirectory($store)
    [IO.File]::WriteAllText((Join-Path $source 'metadata.json'),'{"SchemaVersion":7}')
    $original = Join-Path $store 'архив.mig'
    [IO.File]::WriteAllBytes($original,[byte[]]@(11,22,33))
    $zip = Join-Path $WpmTestRoot 'test.zip'
    Compress-ProfileArchive $source $zip
    $info = Get-ProfileZipInfo $zip
    Assert-WpmEqual $info.Files 2
    Assert-WpmEqual $info.Metadata.SchemaVersion 7
    $destination = Join-Path $WpmTestRoot 'восстановление'
    Expand-ProfileArchive $zip $destination
    $restored = Join-Path (Join-Path $destination 'Store') 'архив.mig'
    Assert-WpmEqual (Get-ExactFileSha256 $restored) (Get-ExactFileSha256 $original)
}

Invoke-WpmTest 'Archive inspection closes measured progress on success and error' {
    $events = [Collections.Generic.List[object]]::new()
    function Write-Progress([int]$Id,[string]$Activity,[string]$Status,[int]$PercentComplete,[switch]$Completed) {
        $events.Add([pscustomobject]@{ Id=$Id; Percent=$PercentComplete; Closed=[bool]$Completed })
    }

    $valid = Join-Path $WpmTestRoot 'valid.zip'
    New-TestProfileZip $valid @('Extras/example.txt')
    Assert-WpmEqual (Get-ProfileZipInfo $valid).Files 3
    Assert-WpmEqual $events[0].Percent -1
    Assert-WpmEqual $events[1].Percent 0
    Assert-WpmEqual $events[$events.Count-2].Percent 100
    Assert-WpmEqual $events[$events.Count-1].Closed $true

    $events.Clear()
    $invalid = Join-Path $WpmTestRoot 'invalid.zip'
    New-TestProfileZip $invalid @('Store/../bad.txt')
    Assert-WpmThrows { Get-ProfileZipInfo $invalid } 'Недопустимый компонент'
    Assert-WpmEqual @($events | Where-Object { $_.Percent -eq 100 }).Count 0
    Assert-WpmEqual $events[$events.Count-1].Closed $true
}

Invoke-WpmTest 'Large file hashing measures bytes and preserves the SHA-256 digest' {
    $events = [Collections.Generic.List[object]]::new()
    function Write-Progress([int]$Id,[string]$Activity,[string]$Status,[int]$PercentComplete,[switch]$Completed) {
        $events.Add([pscustomobject]@{ Id=$Id; Percent=$PercentComplete; Closed=[bool]$Completed })
    }

    $path = Join-Path $WpmTestRoot 'large.bin'
    $stream = [IO.File]::Open($path,'CreateNew','Write','None')
    try {
        $stream.SetLength(16MB)
        $stream.WriteByte(17)
    } finally { $stream.Dispose() }
    Assert-WpmEqual (Get-ExactFileSha256 $path) (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Assert-WpmEqual $events[0].Percent 0
    Assert-WpmEqual $events[$events.Count-2].Percent 100
    Assert-WpmEqual $events[$events.Count-1].Closed $true
}

Invoke-WpmTest 'ZIP rejects ambiguous path components before extraction' {
    foreach ($name in @('Store/../bad.txt','Extras/double//','Extras/file.txt:stream',
        'Extras/LPT¹.log','Extras/CONIN$.txt','Extras/COM1 .txt','Extras/name./file')) {
        $zip = Join-Path $WpmTestRoot (([guid]::NewGuid().ToString('N')) + '.zip')
        New-TestProfileZip $zip @($name)
        $destination = Join-Path $WpmTestRoot 'absent'
        Assert-WpmThrows { Expand-ProfileArchive $zip $destination } 'Недопустимый компонент'
        Assert-WpmEqual (Test-Path -LiteralPath $destination) $false
    }
}

Invoke-WpmTest 'ZIP rejects file-directory conflicts in either entry order' {
    foreach ($names in @(@('Extras/Case','Extras/case/file'),@('Extras/case/file','Extras/Case'))) {
        $zip = Join-Path $WpmTestRoot (([guid]::NewGuid().ToString('N')) + '.zip')
        New-TestProfileZip $zip $names
        Assert-WpmThrows { Get-ProfileZipInfo $zip } 'Файл ZIP используется как каталог'
    }
    $duplicate = Join-Path $WpmTestRoot 'case.zip'
    New-TestProfileZip $duplicate @('Extras/Case','Extras/case')
    Assert-WpmThrows { Get-ProfileZipInfo $duplicate } 'Повторяющееся имя'
}

Invoke-WpmTest 'ZIP requires one metadata object and one migration store' {
    $array = Join-Path $WpmTestRoot 'array.zip'
    New-TestProfileZip $array @() '[{"SchemaVersion":7}]'
    Assert-WpmThrows { Get-ProfileZipInfo $array } 'один JSON-объект'
    $multiple = Join-Path $WpmTestRoot 'multiple.zip'
    New-TestProfileZip $multiple @('Store/duplicate.mig')
    Assert-WpmThrows { Get-ProfileZipInfo $multiple } 'ровно одно USMT-хранилище'
}

Invoke-WpmTest 'ZIP extraction checks free space before creating output' {
    function Get-PathFreeBytes { 0 }
    $zip = Join-Path $WpmTestRoot 'test.zip'
    New-TestProfileZip $zip @()
    $destination = Join-Path $WpmTestRoot 'absent'
    Assert-WpmThrows { Expand-ProfileArchive $zip $destination } 'Недостаточно места'
    Assert-WpmEqual (Test-Path -LiteralPath $destination) $false
}

Invoke-WpmTest 'Archive folder and profile verification reject linked ancestors' {
    $other = Join-Path $WpmTestRoot 'other'
    [void][IO.Directory]::CreateDirectory((Join-Path $other 'nested'))
    [IO.File]::WriteAllText((Join-Path $other 'marker.txt'),'fixture')
    $profile = Join-Path $WpmTestRoot 'profile'
    [void][IO.Directory]::CreateDirectory($profile)
    $kind = if ([Environment]::OSVersion.Platform -eq 'Win32NT') { 'Junction' } else { 'SymbolicLink' }
    $link = Join-Path $profile 'Documents'
    [void](New-Item -ItemType $kind -Path $link -Target $other)
    Assert-WpmThrows { Get-ArchiveFileMap (Join-Path $link 'nested') } 'ссылку'
    Assert-WpmThrows { Read-ArchiveMetadataFile (Join-Path $link 'marker.txt') } 'ссылку'
    Assert-WpmEqual (Get-ProfileDataItem $profile 'Documents\marker.txt') $null
    Assert-WpmEqual @(Get-ValidationSourceFiles $profile).Count 0
}

Invoke-WpmTest 'Manifest verifies Unicode files and detects same-size source changes' {
    $profile = Join-Path $WpmTestRoot 'профиль'
    $desktop = Join-Path $profile 'Desktop'
    [void][IO.Directory]::CreateDirectory($desktop)
    $document = Join-Path $desktop 'файл.txt'
    [IO.File]::WriteAllText($document,'one')
    $manifest = New-ValidationManifest $profile $WpmTestRoot
    $stable = Assert-ValidationSourceStable $profile $WpmTestRoot $manifest
    $meta = [pscustomobject]@{ SchemaVersion=7; ValidationManifest=$manifest; ValidationConsistency=$stable }
    Assert-ValidationManifestIntegrity $WpmTestRoot $meta
    Assert-WpmEqual (Test-ValidationManifest $WpmTestRoot $profile $meta).Matched 1
    [IO.File]::WriteAllText($document,'two')
    Assert-WpmThrows { Assert-ValidationSourceStable $profile $WpmTestRoot $manifest } 'Источник менялся'
    Assert-WpmEqual (Test-ValidationManifest $WpmTestRoot $profile $meta).Changed 1
}

Invoke-WpmTest 'Manifest rejects duplicate aliases and invalid paths before import' {
    $validation = Join-Path $WpmTestRoot 'Validation'
    [void][IO.Directory]::CreateDirectory($validation)
    $file = Join-Path $validation 'files.jsonl'
    $line = @{ RelativePath='Desktop/file'; Length=3; SHA256=('a' * 64) } | ConvertTo-Json -Compress
    $alias = @{ RelativePath='desktop\FILE'; Length=3; SHA256=('a' * 64) } | ConvertTo-Json -Compress
    [IO.File]::WriteAllLines($file,[string[]]@($line,$alias))
    $manifest = [pscustomobject]@{ Path='Validation/files.jsonl'; Files=2; Bytes=6; SHA256=(Get-ExactFileSha256 $file) }
    $meta = [pscustomobject]@{ SchemaVersion=7; ValidationManifest=$manifest; ValidationConsistency=[pscustomobject]@{Stable=$true} }
    Assert-WpmThrows { Assert-ValidationManifestIntegrity $WpmTestRoot $meta } 'Повторяющийся путь'
    # Windows PowerShell 5.1 must release the manifest even if validation stops early.
    $exclusive = [IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $exclusive.Dispose()
    $invalid = @{ RelativePath='Desktop/..'; Length=3; SHA256=('a' * 64) } | ConvertTo-Json -Compress
    Assert-WpmThrows { Read-ValidationManifestRecord $invalid } 'Недопустимый компонент'
}

Invoke-WpmTest 'Migration XML reads valid config and refuses a DTD' {
    $file = Join-Path $WpmTestRoot 'Config.xml'
    [IO.File]::WriteAllText($file,'<Configuration><WindowsComponents /></Configuration>')
    $xml = Read-MigrationXml $file
    Assert-WpmEqual $xml.DocumentElement.Name 'Configuration'
    [IO.File]::WriteAllText($file,'<!DOCTYPE Configuration [<!ENTITY value "fixture">]><Configuration>&value;</Configuration>')
    Assert-WpmThrows { Read-MigrationXml $file } 'DTD'
}

Invoke-WpmTest 'Embedded profile-only rule matches the pinned SHA-256' {
    $file = Join-Path $WpmTestRoot 'ProfileOnly.xml'
    Write-EmbeddedProfileOnlyRule $file
    $xml = Read-MigrationXml $file
    $components = @($xml.SelectNodes('/migration/component'))
    Assert-WpmEqual $components.Count 2
    Assert-WpmEqual @($components | ForEach-Object { $_.GetAttribute('context') }) @('User','User')
}

Invoke-WpmTest 'Archive validates both Temp rules and earlier profile-only rules' {
    $rules = Join-Path $WpmTestRoot 'Rules'
    $validation = Join-Path $WpmTestRoot 'Validation'
    [void][IO.Directory]::CreateDirectory($rules)
    [void][IO.Directory]::CreateDirectory($validation)
    $rule = Join-Path $rules 'ProfileOnly.xml'
    $config = Join-Path $rules 'Config.xml'
    $list = Join-Path $validation 'usmt-files.txt'
    $profile = 'C:\Users\Synthetic'
    [IO.File]::WriteAllText($config,'<Configuration><WindowsComponents /></Configuration>')
    [IO.File]::WriteAllLines($list, [string[]]@($profile, ($profile + '\Documents\fixture.txt')))
    Write-EmbeddedProfileOnlyRule $rule
    $current = [IO.File]::ReadAllText($rule)
    $xml = Read-MigrationXml $rule
    $patterns = @($xml.SelectNodes('/migration/component/role/rules/exclude/objectSet/pattern') | ForEach-Object InnerText)
    Assert-WpmEqual @($patterns | Where-Object { $_ -like '*\Temp*' }) @(
        '%CSIDL_PROFILE%\AppData\Local\Temp [*]',
        '%CSIDL_PROFILE%\AppData\Local\Temp\* [*]'
    )
    $scope = [pscustomobject]@{
        Policy='ArhivaterProfileOnlyV1'; ProfilePath=$profile; Files=2
        RuleSHA256=(Get-ExactFileSha256 $rule); ConfigSHA256=(Get-ExactFileSha256 $config); ListSHA256=(Get-ExactFileSha256 $list)
    }
    $meta = [pscustomobject]@{ SchemaVersion=7; SourceProfilePath=$profile; ProfileScope=$scope }
    Assert-ProfileOnlyArchive $WpmTestRoot $meta

    # Removing the two new rules produces the byte-for-byte v1.11 template.
    $legacy = [regex]::Replace($current, '(?m)^ *<pattern type="File">%CSIDL_PROFILE%\\AppData\\Local\\Temp[^\n]*\n', '')
    [IO.File]::WriteAllText($rule,$legacy,[Text.UTF8Encoding]::new($false))
    $scope.RuleSHA256 = Get-ExactFileSha256 $rule
    Assert-WpmEqual $scope.RuleSHA256.ToLowerInvariant() '5bf12aa9ff9d874faec31829cc7f0b8277af82311810321ec97c89aa6803705c'
    Assert-ProfileOnlyArchive $WpmTestRoot $meta

    [IO.File]::AppendAllText($rule,"<!-- arbitrary rules -->`n")
    $scope.RuleSHA256 = Get-ExactFileSha256 $rule
    Assert-WpmThrows { Assert-ProfileOnlyArchive $WpmTestRoot $meta } 'подтверждённого шаблона'
}

Invoke-WpmTest 'USMT scope list handles BOM and releases files after approval or rejection' {
    $verifyLinks = [Environment]::OSVersion.Platform -eq 'Win32NT'
    $profile = if ($verifyLinks) { Join-Path $WpmTestRoot 'Профиль' } else { 'C:\Users\Профиль' }
    $profileFile = $profile + '\Документ.txt'
    if ($verifyLinks) {
        [void][IO.Directory]::CreateDirectory($profile)
        [IO.File]::WriteAllText($profileFile,'fixture')
    }
    $fileList = Join-Path $WpmTestRoot 'usmt-files.txt'
    [IO.File]::WriteAllLines($fileList,[string[]]@($profile, ('"' + $profileFile + '"')),[Text.Encoding]::Unicode)
    Assert-WpmEqual (Inspect-UsmtFileScope $fileList $profile $verifyLinks) 2
    [IO.File]::WriteAllLines($fileList,[string[]]@($profileFile, ($profile + '-other\external.txt')))
    Assert-WpmThrows { Inspect-UsmtFileScope $fileList $profile $verifyLinks } 'вне подтверждённой области'
    $exclusive = [IO.File]::Open($fileList,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $exclusive.Dispose()
}

Invoke-WpmTest 'Export guard rejects concurrent load or reassignment of selected SID' {
    $profile = [pscustomobject]@{ SID='S-1-5-21-1-2-3-1001'; Path='C:\Users\User' }
    $actual = [pscustomobject]@{ SID=$profile.SID; LocalPath=$profile.Path; Loaded=$false }
    function Get-CimInstance { return $actual }
    Assert-ExportProfileReady $profile 'test'
    $actual.Loaded = $true
    Assert-WpmThrows { Assert-ExportProfileReady $profile 'test' } 'Состояние выбранного профиля'
    $actual.Loaded = $false
    $actual.LocalPath = 'C:\Users\Different'
    Assert-WpmThrows { Assert-ExportProfileReady $profile 'test' } 'Состояние выбранного профиля'
}

Invoke-WpmTest 'Folder metadata requires one object and uses the same byte limit as ZIP' {
    $file = Join-Path $WpmTestRoot 'metadata.json'
    [IO.File]::WriteAllText($file,'{"SchemaVersion":7}',[Text.UTF8Encoding]::new($true))
    Assert-WpmEqual (Read-ArchiveMetadataFile $file).SchemaVersion 7
    [IO.File]::WriteAllText($file,'[{"SchemaVersion":7}]')
    Assert-WpmThrows { Read-ArchiveMetadataFile $file } 'один JSON-объект'
    $fileStream = [IO.File]::OpenWrite($file)
    try { $fileStream.SetLength(2MB + 1) }
    finally { $fileStream.Dispose() }
    Assert-WpmThrows { Read-ArchiveMetadataFile $file } 'до 2 МБ'
}

Invoke-WpmTest 'Folder archive cannot contain its cache including a volume-root selection' {
    $cache = Join-Path $WpmTestRoot 'LocalCache'
    Assert-WpmThrows { Assert-ArchiveCacheOutsideSource $WpmTestRoot $cache } 'содержит рабочий каталог'
    Assert-WpmThrows { Assert-ArchiveCacheOutsideSource $cache $cache } 'содержит рабочий каталог'
    $volume = [IO.Path]::GetPathRoot($WpmTestRoot)
    Assert-WpmThrows { Assert-ArchiveCacheOutsideSource $volume $cache } 'содержит рабочий каталог'
    Assert-ArchiveCacheOutsideSource (Join-Path $WpmTestRoot 'Local') $cache
}

Invoke-WpmTest 'Robocopy preserves the volume root and tolerates an exit racing cancellation' {
    $oldSystemRoot = $env:SystemRoot
    try {
        $env:SystemRoot = $WpmTestRoot
        $source = [IO.Path]::GetPathRoot($WpmTestRoot)
        $destination = Join-Path $WpmTestRoot 'Copy'
        $state = @{ Arguments=''; Disposed=0; Mode='Exit'; Wait=0; ExitCode=1 }
        function Test-RunningProcessStopRequest { $true }
        function Start-Process($FilePath,$ArgumentList,[switch]$PassThru,[switch]$NoNewWindow,$ErrorAction) {
            $state.Arguments = $ArgumentList
            $proc = [pscustomobject]@{ Handle=1; ExitCode=$state.ExitCode; HasExited=$false; State=$state }
            $proc | Add-Member ScriptMethod WaitForExit {
                $this.State.Wait = $args[0]
                return $false
            }
            $proc | Add-Member ScriptMethod Kill {
                if ($this.State.Mode -eq 'Exit') {
                    $this.HasExited = $true
                    throw [InvalidOperationException]::new('process exited')
                }
            }
            $proc | Add-Member ScriptMethod Dispose { $this.State.Disposed++ }
            return $proc
        }
        Copy-DirectoryRobust $source $destination 'synthetic'
        Assert-WpmEqual ($state.Arguments.StartsWith((Quote-WindowsArgument $source) + ' ')) $true
        Assert-WpmEqual $state.Disposed 1
        $state.Mode = 'Timeout'
        Assert-WpmThrows { Copy-DirectoryRobust $source $destination 'synthetic' } 'не подтвердил завершение'
        Assert-WpmEqual $state.Wait 30000
        Assert-WpmEqual $state.Disposed 2
        $state.Mode = 'Exit'
        $state.ExitCode = -1
        Assert-WpmThrows { Copy-DirectoryRobust $source $destination 'synthetic' } 'Код: -1'
    } finally { $env:SystemRoot = $oldSystemRoot }
}

# Windows PowerShell 5.1 uses the framework assembly shipped with the package.
if ($PSVersionTable.PSEdition -eq 'Desktop' -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    . (Join-Path $script:WpmProgramRoot 'Encryption.ps1')

    function Invoke-WithProtectedFixture([string]$Root, [scriptblock]$Check) {
        $fixture = @{
            Zip = Join-Path $Root 'profile.zip'
            Protected = Join-Path $Root 'profile.wpm.pgp'
            Output = Join-Path $Root 'restored.zip'
            Password = ConvertTo-SecureString 'Synthetic-Архив-42' -AsPlainText -Force
        }
        try {
            New-TestProfileZip $fixture.Zip @('Extras/UserFiles/Documents/sample.txt')
            Convert-WpmArchive $fixture.Zip $fixture.Protected $fixture.Password
            & $Check $fixture
        } finally { $fixture.Password.Dispose() }
    }

    Invoke-WpmTest 'Protected archive round trip preserves ZIP bytes with a Unicode password' {
        $events = [Collections.Generic.List[object]]::new()
        function Write-Progress([int]$Id,[string]$Activity,[string]$Status,[int]$PercentComplete,[switch]$Completed) {
            $events.Add([pscustomobject]@{ Id=$Id; Percent=$PercentComplete; Closed=[bool]$Completed })
        }
        Invoke-WithProtectedFixture $WpmTestRoot {
            param($fixture)
            Convert-WpmArchive $fixture.Protected $fixture.Output $fixture.Password -Decrypt
            Assert-WpmEqual (Get-ExactFileSha256 $fixture.Output) (Get-ExactFileSha256 $fixture.Zip)
            Assert-WpmEqual @($events | Where-Object { $_.Id -eq 15 -and $_.Percent -eq 100 }).Count 2
            Assert-WpmEqual $events[$events.Count-1].Closed $true
        }
    }

    Invoke-WpmTest 'Protected archive rejects a wrong password and tampering without leaving a ZIP' {
        Invoke-WithProtectedFixture $WpmTestRoot {
            param($fixture)
            $wrongPassword = ConvertTo-SecureString 'Different-fixture-password' -AsPlainText -Force
            try {
                Assert-WpmThrows { Convert-WpmArchive $fixture.Protected $fixture.Output $wrongPassword -Decrypt } 'Не удалось открыть архив'
                Assert-WpmEqual (Test-Path -LiteralPath $fixture.Output) $false
            } finally { $wrongPassword.Dispose() }
            $bytes = [IO.File]::ReadAllBytes($fixture.Protected)
            $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
            [IO.File]::WriteAllBytes($fixture.Protected, $bytes)
            Assert-WpmThrows { Convert-WpmArchive $fixture.Protected $fixture.Output $fixture.Password -Decrypt } 'Не удалось открыть архив'
            Assert-WpmEqual (Test-Path -LiteralPath $fixture.Output) $false
        }
    }

    Invoke-WpmTest 'Protected archive preflight stops before writing when the staging disk is full' {
        Invoke-WithProtectedFixture $WpmTestRoot {
            param($fixture)
            function Get-PathFreeBytes { 0 }
            Assert-WpmThrows { Convert-WpmArchive $fixture.Protected $fixture.Output $fixture.Password -Decrypt } 'Недостаточно места'
            Assert-WpmEqual (Test-Path -LiteralPath $fixture.Output) $false
        }
    }
}
