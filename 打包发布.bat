@rem gadget-devtool: local build button, never shipped inside the release package
@echo off
setlocal
cd /d "%~dp0"
title Build release package

echo ============================================================
echo   Build release package
echo ============================================================
echo.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" goto no_ps

echo Building folder + zip + exe, please wait ...
echo.
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0tools\make-exe.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" goto failed

echo [OK] Done. The release files are in the "dist" folder:
echo      ^<toolbox^>_v^<version^>         folder, run it in place
echo      ^<toolbox^>_v^<version^>.zip     zip of that folder
echo      ^<toolbox^>_v^<version^>.exe     single file to hand out
echo.
echo      Rebuilding the same version replaces it; other versions stay.
echo      The version comes from the newest "## x.y.z" line in CHANGELOG.md.
echo      The README preview picture was re-captured from the window above.
echo.
echo Opening the "dist" folder ...
start "" "%~dp0dist"
goto end

:no_ps
echo [X] Windows PowerShell not found:
echo     %PS%
goto end

:failed
echo [X] Build failed. Read the messages above, then run this again.
goto end

:end
echo.
pause
