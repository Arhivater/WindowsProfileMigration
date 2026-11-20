@echo off
REM Автор: Arhivater
setlocal
REM Точка входа. Bootstrap.ps1 обрабатывает сетевой путь и запрос прав администратора.
if not exist "%~dp0Bootstrap.ps1" (
    echo Bootstrap.ps1 not found.
    pause
    exit /b 1
)
REM Bootstrap.ps1 сам определяет папку запуска, включая UNC-путь.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Bootstrap.ps1"
if errorlevel 1 (
    echo.
    echo Operation stopped or failed. See the on-screen message.
    pause
)
endlocal
