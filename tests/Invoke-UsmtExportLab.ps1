#Requires -Version 5.1
# Runs W05 and the positive ZIP case of W06 on a fresh GitHub-hosted Windows 11 VM.
# The real launcher, ScanState and UsmtUtils run locally. No profile archives or logs leave the VM.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Initialize-LabUserProfile([string]$Name, [string]$Sid, [Security.SecureString]$Password) {
    $buffer = [Text.StringBuilder]::new(1024)
    $result = [WpmLabUserEnv]::CreateProfile($Sid, $Name, $buffer, $buffer.Capacity)
    if ($result -eq 0) { return $buffer.ToString() }
    Write-Host ('CREATE_PROFILE HRESULT 0x{0:X8}' -f $result)
    if ($result.ToString('X8') -ne '800706F7') {
        [Runtime.InteropServices.Marshal]::ThrowExceptionForHR($result)
        throw 'PROFILE'
    }

    # On this Windows ARM runner the profile API can fail in RPC.
    # Let Windows initialize the fresh test account during a short local logon.
    $credential = [Management.Automation.PSCredential]::new("$env:COMPUTERNAME\$Name", $Password)
    $shell = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $process = Start-Process -FilePath $shell -Credential $credential -LoadUserProfile -WorkingDirectory $env:SystemRoot -ArgumentList '/d /c exit 0' -WindowStyle Hidden -PassThru
    try {
        [void]$process.Handle
        if ($process.WaitForExit(60000)) {
            Write-Host ('PROFILE LOGON EXIT {0}' -f $process.ExitCode)
        } else {
            Write-Host 'PROFILE LOGON TIMED OUT'
        }
    } finally {
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
    # Only the registered, signed-out profile with a hive can become a lab fixture.
    # cmd.exe's exit code is printed for diagnosis and does not establish profile creation.
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $profile = Get-CimInstance Win32_UserProfile -Filter "SID='$Sid'"
        if ($profile -and $profile.LocalPath -and -not $profile.Loaded) {
            Write-Host 'PROFILE INITIALIZED BY TEST LOGON'
            return [string]$profile.LocalPath
        }
        Start-Sleep -Seconds 1
    }
    throw 'PROFILE'
}

function New-LabProfile([string]$Prefix) {
    $name = $Prefix + [guid]::NewGuid().ToString('N').Substring(0,16)
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    $password = ConvertTo-SecureString ('aA1!' + [Convert]::ToBase64String($bytes)) -AsPlainText -Force
    try {
        $user = New-LocalUser -Name $name -Password $password
        $sid = $user.SID.Value
        $path = Initialize-LabUserProfile $name $sid $password
    } finally { $password.Dispose() }
    $profile = @(Get-CimInstance Win32_UserProfile -Filter "SID='$sid'")
    if ($profile.Count -ne 1 -or $profile[0].LocalPath -ine $path -or $profile[0].Special -or
        $profile[0].Loaded -ne $false -or -not (Test-Path -LiteralPath (Join-Path $path 'NTUSER.DAT') -PathType Leaf)) {
        throw 'PROFILE'
    }
    $docs = Join-Path $path 'Documents'
    foreach ($dir in @($path,$docs)) {
        if (Test-Path -LiteralPath $dir) {
            if ((Get-Item -LiteralPath $dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'PROFILE' }
        }
    }
    [void][IO.Directory]::CreateDirectory($docs)
    $marker = 'wpm-' + [guid]::NewGuid().ToString('N') + '.txt'
    $markerPath = Join-Path $docs $marker
    [IO.File]::WriteAllText($markerPath,[guid]::NewGuid().ToString('D'))
    return [pscustomobject]@{ Account = "$env:COMPUTERNAME\$name"; SID = $sid; Path = $path
        Marker = $marker; MarkerPath = $markerPath; Hash = (Get-FileHash -LiteralPath $markerPath).Hash }
}

function Invoke-LabMenu([string]$Root, $Source) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $start.Arguments = '/d /q /c call start.cmd'
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stderr = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        if ($Source) {
            $process.StandardInput.WriteLine('1')
            # Select only the row printed by the application for this exact, unloaded SID's account and path.
            $row = '^(\d+)\. ' + [regex]::Escape($Source.Account) + ' \| Local \| ' + [regex]::Escape($Source.Path) + '$'
            $clock = [Diagnostics.Stopwatch]::StartNew()
            do {
                $read = $process.StandardOutput.ReadLineAsync()
                $remaining = [Math]::Max(0, 60000 - [int]$clock.ElapsedMilliseconds)
                if (-not $read.Wait($remaining) -or $null -eq $read.Result) { throw 'PROFILE_MENU' }
            } until ($read.Result -match $row)
            # Профиль, без отдельной копии папок, каталог Backups, обычный ZIP, подтверждение, назад, выход.
            $inputs = @($Matches[1], '2', '1', '1', '1', '0', '0')
        } else {
            # A clean Backups directory was checked to contain exactly the ZIP from the preceding export.
            $inputs = @('3', '1', '0', '0')
        }
        $stdout = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
        foreach ($answer in $inputs) { $process.StandardInput.WriteLine($answer) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(600000)) { throw [TimeoutException]::new() }
        $stdout.GetAwaiter().GetResult()
        $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw [ComponentModel.Win32Exception]::new($process.ExitCode) }
    } finally {
        if (-not $process.HasExited) {
            # Only stop the launcher tree created above if a prompt or a migration exceeded its deadline.
            & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $process.Id *> $null
        }
        $process.Dispose()
    }
}

function Read-ZipText($Zip, [string]$Name) {
    $entry = $Zip.GetEntry($Name)
    if (-not $entry -or $entry.Length -gt 32MB) { throw 'ZIP_ENTRY' }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Assert-LabReport([string]$Root, [string]$Operation, [string[]]$Previous) {
    $new = @(Get-ChildItem -LiteralPath (Join-Path $Root 'Reports') -File -Filter '*.txt' |
        Where-Object { $_.FullName -notin $Previous })
    if ($new.Count -ne 1) { throw 'REPORT' }
    $body = [IO.File]::ReadAllText($new[0].FullName)
    if ($body -notmatch ('(?m)^Операция: ' + [regex]::Escape($Operation) + '\r?$') -or
        $body -notmatch '(?m)Код завершения UsmtUtils\.exe: 0\r?$' -or
        $body -notmatch '(?m)\] Результат операции: УСПЕШНО(, ЕСТЬ ПРЕДУПРЕЖДЕНИЯ)?\r?$' -or
        $body -notmatch '(?m)\] Предупреждений: \d+; ошибок: 0\r?$' -or
        $body -notmatch '\[ЭТАП НАЧАТ\]' -or $body -notmatch '\[ХОД ОПЕРАЦИИ\].+100% по шагам') { throw 'REPORT' }
    return $new[0].FullName
}

$stage = 'HOST'
$kit = $null
try {
    # Administrator access is needed for two fresh machine-local accounts and Microsoft's profile API.
    # Restrict this to a disposable hosted client. Existing migration data or a domain membership cancels the lab.
    if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
        $env:RUNNER_OS -ne 'Windows' -or $PSVersionTable.PSEdition -ne 'Desktop' -or
        -not [Environment]::Is64BitProcess) { throw 'HOST' }
    $os = Get-CimInstance Win32_OperatingSystem
    $admin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 22000 -or
        -not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
        (Get-CimInstance Win32_ComputerSystem).PartOfDomain -or
        (Test-Path -LiteralPath (Join-Path $env:ProgramData 'WindowsProfileMigration-Work'))) { throw 'HOST' }

    $stage = 'USMT'
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $usmt = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool\$arch"
    foreach ($file in @('ScanState.exe','LoadState.exe','UsmtUtils.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $usmt $file) -PathType Leaf)) { throw 'USMT' }
    }
    $kit = Join-Path $env:RUNNER_TEMP ('WpmExportLab-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -Path $kit -ItemType Directory)
    $project = Split-Path -Parent $PSScriptRoot
    Copy-Item -LiteralPath (Join-Path $project 'start.cmd') -Destination $kit
    Copy-Item -LiteralPath (Join-Path $project 'Program') -Destination $kit -Recurse
    $stage = 'PROFILES'
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
public static class WpmLabUserEnv {
    [DllImport("userenv.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int CreateProfile(string sid, string name, StringBuilder path, int capacity);
}
'@
    $source = New-LabProfile 'WpmS'
    $other = New-LabProfile 'WpmO'
    $profileTemp = Join-Path $source.Path 'AppData\Local\Temp'
    $nestedTemp = Join-Path $profileTemp 'WpmNested'
    [void][IO.Directory]::CreateDirectory($nestedTemp)
    [IO.File]::WriteAllText((Join-Path $profileTemp 'wpm-temp-direct.txt'),'temporary')
    [IO.File]::WriteAllText((Join-Path $nestedTemp 'wpm-temp-nested.txt'),'temporary')
    Write-Host 'PASS PROFILES'

    $stage = 'EXPORT'
    Invoke-LabMenu $kit $source
    $report = Assert-LabReport $kit 'ЭКСПОРТ' @()
    $archives = @(Get-ChildItem -LiteralPath (Join-Path $kit 'Backups') -File -Filter '*.zip')
    if ($archives.Count -ne 1) { throw 'ZIP' }
    $archive = $archives[0].FullName
    $hash = (Get-FileHash -LiteralPath $archive).Hash

    $stage = 'SCOPE'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $meta = (Read-ZipText $zip 'metadata.json') | ConvertFrom-Json
        if ($meta.SourceSid -ne $source.SID -or $meta.SourceProfilePath -ine $source.Path -or
            $meta.SourceAccount -ine $source.Account) { throw 'SOURCE' }
        $records = @((Read-ZipText $zip 'Validation/files.jsonl') -split '\r?\n' |
            Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $marker = @($records | Where-Object { $_.RelativePath -ieq ('Documents\' + $source.Marker) })
        if ($marker.Count -ne 1 -or $marker[0].SHA256 -ine $source.Hash -or
            @($records | Where-Object { $_.RelativePath -like ('*' + $other.Marker) }).Count) { throw 'MANIFEST' }
        $paths = @((Read-ZipText $zip 'Validation/usmt-files.txt') -split '\r?\n' |
            Where-Object { $_.Trim() } | ForEach-Object { $_.Trim().Trim('"').TrimEnd('\') })
        $prefix = $source.Path + '\'
        if ($source.MarkerPath -notin $paths -or @($paths | Where-Object {
            $_ -ine $source.Path -and -not $_.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
        }).Count) { throw 'SCOPE' }
        $tempPrefix = $profileTemp + '\'
        if (@($paths | Where-Object {
            $_.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)
        }).Count) { throw 'TEMP_SCOPE' }
        Write-Host 'PASS TEMP EXCLUDED'
    } finally { $zip.Dispose() }
    Write-Host 'PASS W05'

    $stage = 'VERIFY'
    Invoke-LabMenu $kit $null
    [void](Assert-LabReport $kit 'ПРОВЕРКА АРХИВА' @($report))
    if ((Get-FileHash -LiteralPath $archive).Hash -ne $hash) { throw 'ZIP' }
    Write-Host 'PASS W06-POSITIVE'
} catch {
    # Keep source paths, profile contents and native logs local. Only bounded numeric diagnostics leave the VM.
    $failure = $_.Exception
    Write-Host ('FAIL {0} {1} {2}' -f $stage,$failure.GetType().Name,$failure.HResult)
    if ($stage -eq 'PROFILES') {
        $cause = $failure.GetBaseException()
        Write-Host ('PROFILE CAUSE {0} 0x{1:X8} LINE {2}' -f $cause.GetType().Name,$cause.HResult,$_.InvocationInfo.ScriptLineNumber)
    }
    if ($failure.Message -in @('HOST','USMT','PROFILE','PROFILE_MENU','REPORT','ZIP','ZIP_ENTRY','SOURCE','SCOPE','TEMP_SCOPE','MANIFEST')) {
        Write-Host ('CHECK ' + $failure.Message)
    }
    if ($kit -and (Test-Path -LiteralPath (Join-Path $kit 'Reports'))) {
        $last = Get-ChildItem -LiteralPath (Join-Path $kit 'Reports') -Filter '*.txt' -File |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($last) {
            $body = [IO.File]::ReadAllText($last.FullName)
            $diagnostics = [ordered]@{
                NATIVE = 'Код завершения [\w.]+: (\d+)'
                LINE = '(?m)Строка: (\d+); файл: [^\r\n]*[\\/]Program[\\/]([a-zA-Z0-9_-]+\.ps1)\r?$'
                PHASE = 'выполнено этапов: (\d+)'
            }
            foreach ($key in $diagnostics.Keys) {
                $numbers = [regex]::Matches($body,$diagnostics[$key])
                if (-not $numbers.Count) { continue }
                $value = $numbers[$numbers.Count - 1].Groups[1].Value
                Write-Host ($key + ' ' + $value)
                if ($key -eq 'LINE') {
                    $tokens = $null
                    $errors = $null
                    $module = $numbers[$numbers.Count - 1].Groups[2].Value
                    $sourceFile = Join-Path (Join-Path $kit 'Program') $module
                    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { continue }
                    $ast = [Management.Automation.Language.Parser]::ParseFile($sourceFile,[ref]$tokens,[ref]$errors)
                    $function = $ast.Find({ param($node)
                        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Extent.StartLineNumber -le [int]$value -and $node.Extent.EndLineNumber -ge [int]$value
                    },$true)
                    if ($function -and $function.Name -match '^[a-zA-Z][a-zA-Z0-9-]{0,72}$') {
                        Write-Host ('FUNCTION ' + $function.Name)
                    }
                }
            }
        }
    }
    exit 1
}
