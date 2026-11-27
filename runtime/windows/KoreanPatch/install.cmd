@echo off
setlocal
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\KoreanPatch.ps1" install
set "PATCH_RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %PATCH_RESULT%
