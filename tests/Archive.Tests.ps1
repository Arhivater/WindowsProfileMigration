#Requires -Version 5.1

. (Get-WpmFunctionDefinitions -Name Format-ByteSize,Assert-WindowsPathComponent,Get-WindowsRelativePathParts,
    Get-ProfileDataItem,Assert-NoReparseAncestor,Get-ArchiveFileMap,Initialize-ZipSupport,Get-ProfileZipInfo,
    Read-ProfileZipInfo,Compress-ProfileArchive,Expand-ProfileArchive,Get-ExactFileSha256,Read-MigrationXml,
    Get-ValidationSourceDirectories,Get-ValidationSourceFiles,Read-ValidationManifestRecord,
    New-ValidationManifest,Assert-ValidationSourceStable,Assert-ValidationManifestIntegrity,Test-ValidationManifest,
    Assert-ExportProfileReady,Write-EmbeddedProfileOnlyRule)

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
