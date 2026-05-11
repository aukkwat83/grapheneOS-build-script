@echo off
rem === pixelflash.bat ===
rem Wrapper that launches pixelflash.ps1 with ExecutionPolicy Bypass,
rem so the user does NOT have to change Windows execution policy.
rem Double-click this file, or run ".\pixelflash.bat" from PowerShell/cmd.
rem All arguments are forwarded to the .ps1 (e.g. -SkipFlash, -DepsOnly).

setlocal
set "PS1=%~dp0pixelflash.ps1"

if not exist "%PS1%" (
    echo [FAIL] pixelflash.ps1 not found next to this .bat
    echo        Expected: %PS1%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
