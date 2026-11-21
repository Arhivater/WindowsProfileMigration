#Requires -Version 5.1
# Автор: Arhivater
# WindowsProfileMigration 1.11.0 | Windows PowerShell 5.1 | Windows 10/11
# Экспорт выбранного профиля и подтверждённый автоматический импорт по WinRM.
# Учётная запись администратора запуска не подставляется вместо выбранного профиля.

param(
    [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$RemoteImportArchive = '',
    [string]$RemoteTargetAccount = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Script:WpmVersion = '1.11.0'
$Script:ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
if ($Script:ToolRoot.Length -gt [IO.Path]::GetPathRoot($Script:ToolRoot).Length) {
    $Script:ToolRoot = $Script:ToolRoot.TrimEnd('\')
}
# Один перечень версий для создания, поиска, проверки и восстановления архивов.
$Script:SupportedArchiveSchemas = @(1,2,3,4,5,6,7)
$Script:CurrentArchiveSchema = 7
$Script:BackupRoot = Join-Path $Script:ToolRoot 'Backups'
$Script:RestartRequired = $false
$Script:ReportPath = $null
$Script:ReportWriter = $null
$Script:ReportWarnings = 0
$Script:ReportErrors = 0
$Script:ReportStart = $null
$Script:ReportPhase = 'Ожидание действия'
$Script:ReportPhaseStart = $null
$Script:ProgressStep = 0
$Script:ActiveOpState = $null
$Script:HadFailures = $false
$Script:WpmWorkRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'WindowsProfileMigration-Work'
$Script:OpStateRoot = Join-Path $Script:WpmWorkRoot 'Operations'
$Script:WpmStagingRoot = Join-Path $Script:WpmWorkRoot 'Staging'
$Script:LegacyOpStateRoot = Join-Path $env:ProgramData 'WindowsProfileMigration\Operations'

# Загружаем только перечисленные части программы из папки рядом с этим файлом.
$runtimeFiles = @(
    'Reporting.ps1'
    'Recovery.ps1'
    'Console.ps1'
    'Usmt.ps1'
    'Profiles.ps1'
    'Archives.ps1'
    'FileManifest.ps1'
    'Storage.ps1'
    'Extras.ps1'
    'Browsers.ps1'
    'Desktop.ps1'
    'Export.ps1'
    'ArchiveSelection.ps1'
    'Import.ps1'
    'Network.ps1'
    'MainMenu.ps1'
)
foreach ($file in $runtimeFiles) {
    . (Join-Path $PSScriptRoot $file)
}

Invoke-WpmMainMenu
