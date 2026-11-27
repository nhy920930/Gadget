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
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0tools\make-exe.ps1" -NoPreview -NoCloud
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" goto failed

echo Refreshing dist\MHToolbox: newest version only, Pan client is not started ...
echo.
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0tools\sync-cloud.ps1" -NoOpen
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" goto stage_failed

echo Verifying the package: hashes + exe unpack check, please wait ...
echo.
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0tools\verify-release.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" goto verify_failed

echo [OK] Done. The release files are in the "dist" folder:
echo      ^<toolbox^>_v^<version^>         folder, run it in place
echo      ^<toolbox^>_v^<version^>.zip     zip of that folder
echo      ^<toolbox^>_v^<version^>.exe     single file to hand out
echo.
echo [OK] Verification passed: zip and folder match the sources, and the exe
echo      unpacks byte-identical (no toolbox window opens).
echo.
echo      Rebuilding the same version replaces it; other versions stay.
echo      The version comes from the newest "## x.y.z" line in CHANGELOG.md.
echo      dist\MHToolbox now holds this version only (zip / exe / CHANGELOG),
echo      ready to drop into "My Drive / MHToolbox". The Pan client was not started.
echo      Preview screenshot is skipped on purpose.
echo      Need the client and the staging folder opened? Run tools\sync-cloud.ps1.
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

:stage_failed
echo [X] The package was built, but refreshing dist\MHToolbox failed.
echo     Close whatever is holding that folder (an open zip, or the Pan
echo     client previewing an upload), then build again.
goto end

:verify_failed
echo [X] The package was built, but verification failed. Read the FAIL lines above.
echo     Nothing was deleted; fix the cause and build again.
goto end

:end
echo.
pause
