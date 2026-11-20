#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$AnalyzerModule = 'PSScriptAnalyzer'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name $AnalyzerModule -ErrorAction Stop

$syntax = 'PSUseCompatibleSyntax'
$cmdlets = 'PSUseCompatibleCmdlets'
$types = 'PSUseCompatibleTypes'
$settings = @{
    IncludeRules = @($syntax,$cmdlets,$types)
    Rules = @{
        PSUseCompatibleSyntax = @{ Enable=$true; TargetVersions=@('5.1') }
        PSUseCompatibleCmdlets = @{ Compatibility=@('desktop-5.1.14393.206-windows') }
        PSUseCompatibleTypes = @{ Enable=$true; TargetProfiles=@('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework') }
    }
}

$findings = @(
    foreach ($file in @('ProfileMigration.ps1','Bootstrap.ps1')) {
        Invoke-ScriptAnalyzer -Path (Join-Path $ProjectRoot $file) -Settings $settings
    }
)
$findings | Select-Object RuleName,ScriptName,Line,Message | Format-List
$syntaxCount = @($findings | Where-Object RuleName -eq $syntax).Count
$cmdletCount = @($findings | Where-Object RuleName -eq $cmdlets).Count
$typeCount = @($findings | Where-Object RuleName -eq $types).Count
Write-Output ('COMPATIBILITY syntax={0} cmdlets={1} types={2}' -f $syntaxCount,$cmdletCount,$typeCount)
if ($syntaxCount -or $cmdletCount) { exit 1 }
