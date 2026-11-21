#Requires -Version 5.1

Invoke-WpmTest 'Program scripts include the Windows PowerShell UTF-8 BOM' {
    foreach ($file in Get-ChildItem -LiteralPath $script:WpmProgramRoot -File -Filter '*.ps1') {
        $scriptName = $file.Name
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        Assert-WpmEqual ($bytes[0..2] -join ' ') '239 187 191' "$scriptName BOM"
    }
}

Invoke-WpmTest 'Menu rejects invalid numbers and accepts zero' {
    . (Get-WpmFunctionDefinitions -Name Choice)
    $responses = [Collections.Generic.Queue[string]]::new()
    foreach ($inputValue in @('no', '-1', '3', '2147483648', ' 0 ')) { $responses.Enqueue($inputValue) }
    function Read-Host { $responses.Dequeue() }
    function Write-Host {}
    Assert-WpmEqual (Choice 'Selection' 2) 0
    Assert-WpmEqual $responses.Count 0
}

Invoke-WpmTest 'Menu confirmation executes only for 1' {
    . (Get-WpmFunctionDefinitions -Name Choice,Confirm)
    $responses = [Collections.Generic.Queue[string]]::new()
    foreach ($inputValue in @('0', '2', '1')) { $responses.Enqueue($inputValue) }
    function Read-Host { $responses.Dequeue() }
    function Write-Host {}
    Assert-WpmEqual (Confirm 'Confirm') $false
    Assert-WpmEqual (Confirm 'Confirm') $false
    Assert-WpmEqual (Confirm 'Confirm') $true
}

Invoke-WpmTest 'End of console input cancels instead of retrying' {
    . (Get-WpmFunctionDefinitions -Name Choice,Confirm)
    function Read-Host { return $null }
    function Write-Host {}
    Assert-WpmEqual (Choice 'Selection' 2) 0
    Assert-WpmEqual (Confirm 'Confirm') $false
    Assert-WpmThrows { Choice 'Selection' 2 1 } 'Ввод завершён'
    Assert-WpmThrows { Choice 'Selection' 0 1 } 'доступных вариантов'
}

Invoke-WpmTest 'Profile menu returns exactly the selected account or cancellation' {
    . (Get-WpmFunctionDefinitions -Name Choice,Select-Profile)
    $responses = [Collections.Generic.Queue[string]]::new()
    foreach ($inputValue in @('2','0')) { $responses.Enqueue($inputValue) }
    function Read-Host { $responses.Dequeue() }
    function Write-Host {}
    function Title {}
    function Get-SessionUserProfile { return $null }
    function Get-UserProfiles {
        [pscustomobject]@{ Account='LAB\OtherAdmin'; Type='Local'; Path='C:\Users\OtherAdmin'; Loaded=$true }
        [pscustomobject]@{ Account='DOMAIN\Selected'; Type='Domain'; Path='C:\Users\Selected'; Loaded=$false }
        [pscustomobject]@{ Account='AzureAD\Excluded'; Type='Unsupported'; Path='C:\Users\Excluded'; Loaded=$false }
    }
    $selected = Select-Profile
    Assert-WpmEqual $selected.Account 'DOMAIN\Selected'
    Assert-WpmEqual (Select-Profile) $null
}

Invoke-WpmTest 'Session profile uses the current Explorer SID and rejects ambiguity' {
    . (Get-WpmFunctionDefinitions -Name Get-SessionUserProfile)
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $shells = [Collections.Generic.List[object]]::new()
    $shells.Add([pscustomobject]@{ SessionId=$sessionId; Owner='S-1-5-21-123-432-765-1001' })
    $shells.Add([pscustomobject]@{ SessionId=($sessionId + 1); Owner='S-1-5-21-123-432-765-1002' })
    function Get-CimInstance { $shells }
    function Invoke-CimMethod($InputObject, $MethodName) {
        Assert-WpmEqual $MethodName 'GetOwnerSid'
        [pscustomobject]@{ ReturnValue=0; Sid=$InputObject.Owner }
    }
    $profiles = @(
        [pscustomobject]@{ Account='PC\Owner'; SID='S-1-5-21-123-432-765-1001' }
        [pscustomobject]@{ Account='PC\Admin'; SID='S-1-5-21-123-432-765-1002' }
    )
    Assert-WpmEqual ((Get-SessionUserProfile -Profiles $profiles).Account) 'PC\Owner'
    $shells.Add([pscustomobject]@{ SessionId=$sessionId; Owner='S-1-5-21-123-432-765-1002' })
    Assert-WpmEqual (Get-SessionUserProfile -Profiles $profiles) $null
}

Invoke-WpmTest 'Windows process arguments preserve account, UNC, spaces and quotes' {
    . (Get-WpmFunctionDefinitions -Name Quote-WindowsArgument)
    Assert-WpmEqual (Quote-WindowsArgument '') '""'
    Assert-WpmEqual (Quote-WindowsArgument '/ui:DOMAIN\user') '/ui:DOMAIN\user'
    Assert-WpmEqual (Quote-WindowsArgument '/mu:DOMAIN\user:LAB\local') '/mu:DOMAIN\user:LAB\local'
    Assert-WpmEqual (Quote-WindowsArgument '\\server\общая папка\') '"\\server\общая папка\\"'
    Assert-WpmEqual (Quote-WindowsArgument 'a"b') '"a\"b"'
    Assert-WpmEqual (Quote-WindowsArgument 'a\"b') '"a\\\"b"'
}

Invoke-WpmTest 'Bootstrap rejects empty launch folders and quotes trailing separators' {
    . (Get-WpmFunctionDefinitions -ScriptName Bootstrap.ps1 -Name Resolve-OriginalFolder,Quote-LaunchPath)
    Assert-WpmThrows { Resolve-OriginalFolder ' ' } 'папка комплекта'
    Assert-WpmEqual (Quote-LaunchPath 'C:\') '"C:\\"'
    Assert-WpmEqual (Quote-LaunchPath '\\host\Общая папка\') '"\\host\Общая папка\\"'
    Assert-WpmEqual (Quote-LaunchPath 'C:\папка тестов\ProfileMigration.ps1') '"C:\папка тестов\ProfileMigration.ps1"'
}

Invoke-WpmTest 'USMT discovery requires all three executables' {
    . (Get-WpmFunctionDefinitions -Name Get-UsmtPath)
    $oldToolRoot = Get-Variable -Scope Script -Name ToolRoot -ValueOnly -ErrorAction SilentlyContinue
    $oldProgramFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
    $oldProgramFiles86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $oldArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
    try {
        $script:ToolRoot = $WpmTestRoot
        [Environment]::SetEnvironmentVariable('ProgramFiles', $WpmTestRoot)
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $WpmTestRoot)
        [Environment]::SetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'AMD64')
        $usmt = Join-Path $WpmTestRoot 'USMT'
        [void][IO.Directory]::CreateDirectory($usmt)
        foreach ($name in @('ScanState.exe','LoadState.exe')) {
            [IO.File]::WriteAllText((Join-Path $usmt $name), 'synthetic fixture')
        }
        Assert-WpmEqual (Get-UsmtPath) $null
        [IO.File]::WriteAllText((Join-Path $usmt 'UsmtUtils.exe'), 'synthetic fixture')
        Assert-WpmEqual (Get-UsmtPath) $usmt
    } finally {
        $script:ToolRoot = $oldToolRoot
        [Environment]::SetEnvironmentVariable('ProgramFiles', $oldProgramFiles)
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $oldProgramFiles86)
        [Environment]::SetEnvironmentVariable('PROCESSOR_ARCHITECTURE', $oldArchitecture)
    }
}

Invoke-WpmTest 'Dependency menu cancellation does not install components' {
    . (Get-WpmFunctionDefinitions -Name Require-USMT)
    $oldRestart = Get-Variable -Scope Script -Name RestartRequired -ValueOnly -ErrorAction SilentlyContinue
    try {
        $script:RestartRequired = $false
        function Get-UsmtPath { return $null }
        function Write-Host {}
        function Title {}
        function Choice { return 0 }
        function Install-USMT { throw 'Installer must not be invoked on cancellation.' }
        Assert-WpmEqual (Require-USMT) $null
    } finally {
        $script:RestartRequired = $oldRestart
    }
}

Invoke-WpmTest 'USMT consumes native exit 0 and propagates nonzero or missing codes' {
    . (Get-WpmFunctionDefinitions -Name Quote-WindowsArgument,Invoke-USMT)
    $run = @{ Code = 0; Args = ''; Disposed = 0; Log = 0; Report = '' }
    function Write-Host {}
    function Write-Progress {}
    function Show-UsmtProgress {}
    function Append-UsmtLogTail { $run.Log++ }
    function Write-OperationReport($Category,$Message) { $run.Report = $Message }
    function Start-Process {
        [CmdletBinding()]
        param($FilePath, $WorkingDirectory, $ArgumentList, [switch]$PassThru, [switch]$NoNewWindow)
        Assert-WpmEqual $FilePath 'ScanState.exe'
        Assert-WpmEqual $WorkingDirectory $WpmTestRoot
        Assert-WpmEqual ([bool]$PassThru) $true
        $run.Args = $ArgumentList
        $process = [pscustomobject]@{ Handle = 1; ExitCode = $run.Code; State = $run }
        $process | Add-Member ScriptMethod WaitForExit { return $true }
        $process | Add-Member ScriptMethod Dispose { $this.State.Disposed++ }
        return $process
    }
    $currentDirectory = (Get-Location).Path
    Invoke-USMT 'ScanState.exe' @('C:\data with space','/ui:DOMAIN\user') $WpmTestRoot
    Assert-WpmEqual $run.Args '"C:\data with space" /ui:DOMAIN\user'
    Assert-WpmEqual (Get-Location).Path $currentDirectory
    Assert-WpmEqual $run.Log 0
    Assert-WpmEqual ($run.Report -match ': 0$') $true
    $run.Code = 27
    Assert-WpmThrows { Invoke-USMT 'ScanState.exe' @('/genconfig:c:\fixture.xml') $WpmTestRoot } '27'
    Assert-WpmEqual $run.Log 1
    $run.Code = $null
    Assert-WpmThrows { Invoke-USMT 'ScanState.exe' @('/ui:DOMAIN\user') $WpmTestRoot } 'код завершения'
    Assert-WpmEqual $run.Disposed 3
    Assert-WpmEqual (Get-Location).Path $currentDirectory
}

Invoke-WpmTest 'USMT confirmed cancellation terminates only the started child' {
    . (Get-WpmFunctionDefinitions -Name Quote-WindowsArgument,Invoke-USMT)
    $state = @{ Kill = 0; Wait = 0; Disposed = 0; ProgressClosed = $false; CancelTimeout = 0 }
    function Show-UsmtProgress {}
    function Write-Host {}
    function Write-Progress($Id, $Activity, [switch]$Completed) { if ($Completed) { $state.ProgressClosed = $true } }
    function Test-RunningProcessStopRequest { return $true }
    function Start-Process {
        [CmdletBinding()]
        param($FilePath,$WorkingDirectory,$ArgumentList,[switch]$PassThru,[switch]$NoNewWindow)
        $process = [pscustomobject]@{ Handle = 1; ExitCode = 1; HasExited = $false; State = $state }
        $process | Add-Member ScriptMethod WaitForExit {
            $this.State.Wait++
            if ($this.State.Kill -eq 0) { return $false }
            if (-not $args.Count) { return }
            $this.State.CancelTimeout = $args[0]
            return $true
        }
        $process | Add-Member ScriptMethod Kill { $this.State.Kill++ }
        $process | Add-Member ScriptMethod Dispose { $this.State.Disposed++ }
        return $process
    }
    $before = (Get-Location).Path
    Assert-WpmThrows { Invoke-USMT 'ScanState.exe' @('/ui:DOMAIN\user') $WpmTestRoot } 'остановлен'
    Assert-WpmEqual $state.Kill 1
    Assert-WpmEqual $state.Wait 2
    Assert-WpmEqual ($state.CancelTimeout -ge 1 -and $state.CancelTimeout -le 60000) $true
    Assert-WpmEqual $state.Disposed 1
    Assert-WpmEqual $state.ProgressClosed $true
    Assert-WpmEqual (Get-Location).Path $before
}

Invoke-WpmTest 'USMT progress uses valid measured percentages and ignores malformed records' {
    . (Get-WpmFunctionDefinitions -Name Show-UsmtProgress)
    $observed = @{ Percent = $null; Activity = '' }
    function Write-Progress($Id,$Activity,$Status,$PercentComplete) {
        $observed.Percent = $PercentComplete
        $observed.Activity = $Activity
    }
    $log = Join-Path $WpmTestRoot 'progress.log'
    [IO.File]::WriteAllLines($log, [string[]]@(
        '01 Nov 2026, 10:11:00, totalPercentageCompleted, 1000',
        '01 Nov 2026, 10:12:00, totalPercentageCompleted, 100.1'
    ))
    Show-UsmtProgress $log 'ScanState'
    Assert-WpmEqual $observed.Percent $null
    Assert-WpmEqual $observed.Activity 'ScanState'
    [IO.File]::AppendAllLines($log, [string[]]@(
        '01 Nov 2026, 10:13:00, totalPercentageCompleted, 12.8',
        '01 Nov 2026, 10:14:00, totalPercentageCompleted, 900'
    ))
    Show-UsmtProgress $log 'ScanState'
    Assert-WpmEqual $observed.Percent 12
    [IO.File]::AppendAllLines($log, [string[]]@('01 Nov 2026, 10:15:00, totalPercentageCompleted, 100'))
    Show-UsmtProgress $log 'ScanState'
    Assert-WpmEqual $observed.Percent 100
}

Invoke-WpmTest 'Insufficient synthetic profile volume space stops import preflight' {
    . (Get-WpmFunctionDefinitions -Name Test-TargetFreeSpace,Format-ByteSize)
    function Get-ProfileStoreRoot { return $WpmTestRoot }
    function Get-PathFreeBytes { return 1GB }
    function Write-OperationReport {}
    function Write-Host {}
    Assert-WpmThrows { Test-TargetFreeSpace 1GB } 'Недостаточно места'
}

Invoke-WpmTest 'Unsupported Windows version is rejected before privileged work' {
    . (Get-WpmFunctionDefinitions -Name Ensure-Admin)
    function Get-CimInstance { return [pscustomobject]@{ Version = '6.3.9600'; ProductType = 1 } }
    Assert-WpmThrows { Ensure-Admin } 'Windows (10|PowerShell)'
}

Invoke-WpmTest 'Windows Server does not pass the workstation preflight' {
    . (Get-WpmFunctionDefinitions -Name Ensure-Admin)
    function Get-CimInstance { return [pscustomobject]@{ Version = '10.0.20348'; ProductType = 3 } }
    Assert-WpmThrows { Ensure-Admin } 'Windows (10|PowerShell)'
}

Invoke-WpmTest 'SHA-256 hashes use exact fixture bytes' {
    . (Get-WpmFunctionDefinitions -Name Get-ExactFileSha256)
    $file = Join-Path $WpmTestRoot 'данные.bin'
    [IO.File]::WriteAllBytes($file, [byte[]]@(97,98,99))
    Assert-WpmEqual ((Get-ExactFileSha256 $file).ToLowerInvariant()) 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
}

Invoke-WpmTest 'ZIP copy verification rejects same-size corruption' {
    . (Get-WpmFunctionDefinitions -Name Assert-CopiedZipHash,Get-ExactFileSha256,Format-ByteSize)
    function Write-OperationReport {}
    function Test-RunningProcessStopRequest { $false }
    $source = Join-Path $WpmTestRoot 'source.zip'
    $target = Join-Path $WpmTestRoot 'target.zip'
    [IO.File]::WriteAllBytes($source, [byte[]]@(97,98,99))
    [IO.File]::WriteAllBytes($target, [byte[]]@(97,98,99))
    Assert-CopiedZipHash $source $target | Out-Null
    [IO.File]::WriteAllBytes($target, [byte[]]@(97,98,100))
    Assert-WpmThrows { Assert-CopiedZipHash $source $target } 'SHA-256'
}

Invoke-WpmTest 'Report records warning, duration and final status; all progress is closed' {
    . (Get-WpmFunctionDefinitions -Name Write-OperationReport,Advance-OperationStage,Finish-OperationReport)
    $reportFile = Join-Path $WpmTestRoot 'fixture-report.txt'
    $closedProgress = [Collections.Generic.List[int]]::new()
    function Write-Host {}
    function Write-Progress($Id,$Activity,$Status,$PercentComplete,[switch]$Completed) {
        if ($Completed) { $closedProgress.Add([int]$Id) }
    }
    $writer = [IO.StreamWriter]::new($reportFile, $false, [Text.UTF8Encoding]::new($true))
    $initial = @{
        ReportPath = $reportFile
        ReportWriter = $writer
        ReportWarnings = 0
        ReportErrors = 0
        ReportStart = (Get-Date).AddSeconds(-2)
        ReportPhase = 'Предыдущий этап'
        ReportPhaseStart = (Get-Date).AddSeconds(-1)
        ProgressStep = 0
    }
    $previous = @{}
    foreach ($key in $initial.Keys) {
        $variable = Get-Variable -Scope Script -Name $key -ErrorAction SilentlyContinue
        if ($variable) { $previous[$key] = $variable.Value }
        Set-Variable -Scope Script -Name $key -Value $initial[$key]
    }
    try {
        Advance-OperationStage 'Проверка данных'
        Write-OperationReport 'ПРЕДУПРЕЖДЕНИЕ' 'Синтетическое предупреждение'
        Finish-OperationReport 'УСПЕШНО'
        Assert-WpmEqual $script:ReportWriter $null
        Assert-WpmEqual $script:ReportPath $null
        Assert-WpmEqual $closedProgress.ToArray() @(0,1,2,3,4,5,6)
        $report = [IO.File]::ReadAllText($reportFile)
        Assert-WpmEqual ($report -match 'Синтетическое предупреждение') $true
        Assert-WpmEqual ($report -match 'ВРЕМЯ ЭТАПА.*Предыдущий этап') $true
        Assert-WpmEqual ($report -match 'ВРЕМЯ ЭТАПА.*Проверка данных') $true
        Assert-WpmEqual ($report -match 'УСПЕШНО, ЕСТЬ ПРЕДУПРЕЖДЕНИЯ') $true
        Assert-WpmEqual ($report -match 'Предупреждений: 1; ошибок: 0') $true
    } finally {
        $writer.Dispose()
        foreach ($key in $initial.Keys) {
            if ($previous.ContainsKey($key)) {
                Set-Variable -Scope Script -Name $key -Value $previous[$key]
            } else {
                Remove-Variable -Scope Script -Name $key -ErrorAction SilentlyContinue
            }
        }
    }
}

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    Invoke-WpmTest 'Windows drive root and UNC share remain absolute' {
        . (Get-WpmFunctionDefinitions -ScriptName Bootstrap.ps1 -Name Resolve-OriginalFolder)
        $nativeRoot = [IO.Path]::GetPathRoot($env:SystemRoot)
        Assert-WpmEqual (Resolve-OriginalFolder $nativeRoot) $nativeRoot
        Assert-WpmEqual (Resolve-OriginalFolder '\\fixtures\Общая папка\каталог\') '\\fixtures\Общая папка\каталог'
    }

    Invoke-WpmTest 'CMD launcher forwards success and errors from a harmless fixture' {
        $kit = Join-Path $WpmTestRoot 'комплект с пробелами!'
        $program = Join-Path $kit 'Program'
        [void][IO.Directory]::CreateDirectory($program)
        $launcher = Join-Path $kit 'start.cmd'
        $fixture = Join-Path $program 'Bootstrap.ps1'
        [IO.File]::Copy((Join-Path $script:WpmProjectRoot 'start.cmd'), $launcher)
        foreach ($code in @(0,19,1223)) {
            [IO.File]::WriteAllText($fixture, "exit $code")
            # Pass the precise CMD command line and close stdin to release its pause.
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $env:ComSpec
            $start.Arguments = '/d /v:off /s /c ""{0}""' -f $launcher
            $start.UseShellExecute = $false
            $start.RedirectStandardInput = $true
            $start.CreateNoWindow = $true
            $process = [Diagnostics.Process]::Start($start)
            try {
                $process.StandardInput.Close()
                if (-not $process.WaitForExit(20000)) {
                    $process.Kill()
                    throw 'The fixture launcher did not exit.'
                }
                Assert-WpmEqual $process.ExitCode $code 'Code through start.cmd'
            } finally { $process.Dispose() }
        }
    }
} else {
    Write-Host 'BLOCKED Windows-only CMD launcher and local/UNC root tests'
}
