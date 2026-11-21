@echo off
setlocal DisableDelayedExpansion
REM Arhivater - WindowsProfileMigration
set "ERRORLEVEL="
set "WPM_ENGINE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "WPM_ENGINE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0Program\Bootstrap.ps1" goto missing
if not exist "%WPM_ENGINE%" goto missing

"%WPM_ENGINE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Program\Bootstrap.ps1"
set "WPM_EXIT=%ERRORLEVEL%"
if "%WPM_EXIT%"=="0" goto done
if "%WPM_EXIT%"=="1223" goto done
goto failed

:missing
set "WPM_EXIT=1"

:failed
set "WPM_CODEPAGE="
for /f "tokens=2 delims=:" %%C in ('chcp') do set "WPM_CODEPAGE=%%C"
chcp 65001 >nul
echo.
echo Запуск или операция завершились с ошибкой. Проверьте комплект и итоговый отчёт.
pause
if defined WPM_CODEPAGE chcp %WPM_CODEPAGE% >nul

:done
endlocal & exit /b %WPM_EXIT%
