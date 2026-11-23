#Requires -Version 5.1
# Tests the real launcher from a disposable SMB share on the Windows runner.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WpmTestConsole {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
'@

function Assert-KitFilesReleased([string]$Path) {
    foreach ($file in @('start.cmd', 'Program\Bootstrap.ps1', 'Program\ProfileMigration.ps1')) {
        $stream = [IO.File]::Open((Join-Path $Path $file), 'Open', 'ReadWrite', 'None')
        $stream.Dispose()
    }
}

$project = Split-Path -Parent $PSScriptRoot
$share = 'wpm-exit-' + [guid]::NewGuid().ToString('N')
$scratch = Join-Path $env:TEMP $share
$kit = Join-Path $scratch 'kit'
$unc = '\\localhost\' + $share
$launcher = Join-Path $unc 'start.cmd'
$shareCreated = $false
$console = $null
$menu = $null
try {
    [void][IO.Directory]::CreateDirectory($kit)
    Copy-Item -LiteralPath (Join-Path $project 'Program') -Destination $kit -Recurse
    Copy-Item -LiteralPath (Join-Path $project 'start.cmd') -Destination $kit
    New-SmbShare -Name $share -Path $kit -FullAccess ([Security.Principal.WindowsIdentity]::GetCurrent().Name) | Out-Null
    $shareCreated = $true

    $info = [Diagnostics.ProcessStartInfo]::new($env:ComSpec, ('/d /s /c ""{0}""' -f $launcher))
    $info.WorkingDirectory = $scratch
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $console = [Diagnostics.Process]::Start($info)
    $console.StandardInput.WriteLine('0')
    $console.StandardInput.Flush()
    if (-not $console.WaitForExit(30000) -or $console.ExitCode -ne 0) {
        throw 'The launcher failed to exit normally from the SMB share after entering 0.'
    }
    Assert-KitFilesReleased $unc
    Write-Host 'PASS menu exit from SMB and exclusive reopen of kit files'
    $console.Dispose()
    $console = $null

    # Record the HWND in a new console, then launch the kit in that same console.
    $windowFile = Join-Path $scratch 'window.txt'
    @'
Add-Type -Namespace WpmTest -Name Window -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'window.txt'), [string][long][WpmTest.Window]::GetConsoleWindow())
'@ | Set-Content -LiteralPath (Join-Path $scratch 'window.ps1') -Encoding ASCII
    @"
@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0window.ps1"
call "$launcher"
"@ | Set-Content -LiteralPath (Join-Path $scratch 'close-test.cmd') -Encoding ASCII
    $console = Start-Process -FilePath $env:ComSpec -ArgumentList '/d /q /c close-test.cmd' -WorkingDirectory $scratch -PassThru
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 250
        $running = Get-CimInstance Win32_Process -Filter ("ParentProcessId = {0} AND Name = 'powershell.exe'" -f $console.Id) |
            Where-Object { $_.CommandLine -like '*\Program\Bootstrap.ps1*' } | Select-Object -First 1
    } until ($console.HasExited -or $timer.Elapsed.TotalSeconds -ge 30 -or ($running -and (Test-Path -LiteralPath $windowFile)))
    if (-not $running -or $console.HasExited) { throw 'The network launcher did not start in a separate console.' }
    $menu = [Diagnostics.Process]::GetProcessById($running.ProcessId)
    $window = [IntPtr]([long][IO.File]::ReadAllText($windowFile))
    if ($window -eq [IntPtr]::Zero -or $window -eq [WpmTestConsole]::GetConsoleWindow()) {
        throw 'The test console did not get its own window.'
    }
    # WM_CLOSE follows the same console shutdown path as clicking the close button.
    if (-not [WpmTestConsole]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    if (-not $console.WaitForExit(15000) -or -not $menu.WaitForExit(15000)) {
        throw 'Closing the console left the launcher or PowerShell running.'
    }
    Assert-KitFilesReleased $unc
    Write-Host 'PASS close button from SMB and exclusive reopen of kit files'
} finally {
    foreach ($process in @($menu, $console)) {
        if ($null -eq $process) { continue }
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
    if ($shareCreated) { Remove-SmbShare -Name $share -Force }
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
