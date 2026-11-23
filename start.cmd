@echo off
setlocal DisableDelayedExpansion
REM Arhivater - WindowsProfileMigration
set "ERRORLEVEL="
set "WPM_ENGINE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "WPM_ENGINE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
set "WPM_BOOTSTRAP=%~dp0Program\Bootstrap.ps1"
if not exist "%WPM_BOOTSTRAP%" goto missing
if not exist "%WPM_ENGINE%" goto missing

REM Use a local working directory so CMD and PowerShell release the network folder.
pushd "%SystemRoot%" || goto missing
"%WPM_ENGINE%" -NoProfile -ExecutionPolicy Bypass -File "%WPM_BOOTSTRAP%"
set "WPM_EXIT=%ERRORLEVEL%"
popd
goto done

:missing
set "WPM_EXIT=1"

set "WPM_CODEPAGE="
for /f "tokens=2 delims=:" %%C in ('chcp') do set "WPM_CODEPAGE=%%C"
chcp 65001 >nul
echo.
echo Не удалось открыть комплект или Windows PowerShell. Проверьте пути к файлам.
if defined WPM_CODEPAGE chcp %WPM_CODEPAGE% >nul

:done
endlocal & exit /b %WPM_EXIT%
