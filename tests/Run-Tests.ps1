#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string[]]$Suite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:WpmProjectRoot = (Get-Item -LiteralPath $ProjectRoot).FullName
$script:WpmTestCases = [Collections.Generic.List[object]]::new()
$script:WpmScriptAsts = @{}

function Get-WpmFunctionDefinitions {
    param(
        [ValidateSet('ProfileMigration.ps1','Bootstrap.ps1')]
        [string]$ScriptName = 'ProfileMigration.ps1',
        [string[]]$Name
    )
    $definitions = @($script:WpmScriptAsts[$ScriptName].EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
            (-not $Name -or $_.Name -in $Name)
    })
    $defined = @($definitions | ForEach-Object Name)
    $missing = @($Name | Where-Object { $_ -and $_ -notin $defined })
    if ($missing.Count) {
        throw ('Functions missing from {0}: {1}' -f $ScriptName, ($missing -join ', '))
    }
    return [scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine)
}

function Assert-WpmEqual {
    param($Actual, $Expected, [string]$Message = 'Unexpected value')
    $actualValues = @($Actual)
    $expectedValues = @($Expected)
    $equal = $actualValues.Count -eq $expectedValues.Count
    for ($index = 0; $equal -and $index -lt $actualValues.Count; $index++) {
        $equal = $actualValues[$index] -ceq $expectedValues[$index]
    }
    if (-not $equal) {
        throw ('{0}. Expected [{1}], received [{2}].' -f $Message, ($expectedValues -join ', '), ($actualValues -join ', '))
    }
}

function Assert-WpmThrows {
    param([scriptblock]$Action, [string]$Pattern = '.')
    try {
        & $Action | Out-Null
    } catch {
        if ($_.Exception.Message -match $Pattern) { return }
        throw ('Expected error matching /{0}/, received "{1}".' -f $Pattern, $_.Exception.Message)
    }
    throw ('Expected error matching /{0}/, operation returned normally.' -f $Pattern)
}

function Invoke-WpmTest {
    param([string]$WpmCaseLabel, [scriptblock]$WpmCaseScript)
    $WpmTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('WPM_Test_' + [guid]::NewGuid().ToString('N'))
    $private:failure = $null
    try {
        [void][IO.Directory]::CreateDirectory($WpmTestRoot)
        & $WpmCaseScript | Out-Null
    } catch {
        $failure = $_
    } finally {
        try {
            if (Test-Path -LiteralPath $WpmTestRoot -PathType Container) {
                Remove-Item -LiteralPath $WpmTestRoot -Recurse -Force
            }
        } catch {
            if (-not $failure) { $failure = $_ }
        }
    }
    if ($failure) {
        Write-Host ('FAIL {0} - {1}' -f $WpmCaseLabel, $failure.Exception.Message) -ForegroundColor Red
        Write-Host $failure.ScriptStackTrace
    } else {
        Write-Host ('PASS {0}' -f $WpmCaseLabel) -ForegroundColor Green
    }
    $script:WpmTestCases.Add([pscustomobject]@{ Name = $WpmCaseLabel; Passed = ($null -eq $failure) })
}

Write-Host ('PowerShell {0} | {1}' -f $PSVersionTable.PSVersion, [Environment]::OSVersion.Platform)
foreach ($name in @('Bootstrap.ps1', 'ProfileMigration.ps1')) {
    $path = Join-Path $script:WpmProjectRoot $name
    Invoke-WpmTest "Parse $name" {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if (@($errors).Count) {
            throw (($errors | ForEach-Object { '{0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) -join [Environment]::NewLine)
        }
        Assert-WpmEqual ([string]$ast.ScriptRequirements.RequiredPSVersion) '5.1'
        $script:WpmScriptAsts[$name] = $ast
    }
}

if ($script:WpmScriptAsts.Count -eq 2) {
    $testDirectory = Join-Path $script:WpmProjectRoot 'tests'
    $files = @(Get-ChildItem -LiteralPath $testDirectory -File -Filter '*.Tests.ps1' | Sort-Object Name)
    if ($Suite) {
        $selected = @($Suite | ForEach-Object { $_ + '.Tests.ps1' })
        $available = @($files | ForEach-Object Name)
        $missing = @($selected | Where-Object { $_ -notin $available })
        if ($missing.Count) { throw ('Test suites missing: ' + ($missing -join ', ')) }
        $files = @($files | Where-Object { $_.Name -in $selected })
    }
    if (-not $files.Count) { throw 'No test suites found.' }
    foreach ($file in $files) {
        # Give each suite a child scope while keeping the runner's script scope
        # available to helper functions and synthetic application state.
        & { . $file.FullName }
    }
}

$failed = @($script:WpmTestCases | Where-Object { -not $_.Passed }).Count
$passed = $script:WpmTestCases.Count - $failed
Write-Host ('SUMMARY total={0} pass={1} fail={2}' -f $script:WpmTestCases.Count, $passed, $failed)
if ($failed) { exit 1 }
