@echo off
setlocal enabledelayedexpansion
set "SCRIPT_DIR=%~dp0"
where pwsh >nul 2>nul
if !errorlevel! equ 0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%fenix-selected-skills.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%fenix-selected-skills.ps1" %*
)
set "RC=!errorlevel!"
endlocal & exit /b %RC%
