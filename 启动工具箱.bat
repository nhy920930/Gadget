@echo off
rem ===========================================================================
rem  Gadget toolbox launcher - double-click this file to start the toolbox.
rem
rem  Folder layout it expects:
rem    .\<launcher>.bat   <- this file
rem    .\app\             <- toolbox: the .hta, the mobile .html, ocr_tiku.txt, ocr\
rem    .\tools\           <- developer scripts (release packing, capture helpers)
rem
rem  Keep this file ASCII-only: cmd.exe parses .bat using the OEM/ANSI code page,
rem  so Chinese text here turns into mojibake on some machines and can even break
rem  the parser. All Chinese guidance lives in the toolbox self-check and README.
rem
rem  Run it with --check to verify the folder without opening the toolbox.
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

rem --- locate the toolbox -----------------------------------------------------
rem app\ first, then this folder itself, so an older flat layout still launches.
set "APPDIR=%~dp0app"
if not exist "%APPDIR%\*.hta" set "APPDIR=%~dp0."

rem Wildcard instead of a fixed name: a mangled Chinese file name still works, and
rem if a stray test .hta is lying around the biggest file wins (the real one is by
rem far the biggest).
set "BEST="
set "BESTSIZE=0"
set "COUNT=0"
for %%F in ("%APPDIR%\*.hta") do (
    set /a COUNT+=1
    if %%~zF GTR !BESTSIZE! (
        set "BESTSIZE=%%~zF"
        set "BEST=%%~fF"
    )
)
if not defined BEST goto :nohta

rem --- clear the "downloaded from the internet" mark --------------------------
rem Files coming out of a browser download carry a mark that makes Windows block
rem scripts and pop a security prompt; clearing it keeps the first launch quiet.
rem Only once per copy (marker under app\data): a hidden PowerShell that walks the
rem whole tree on every single start is itself something security software watches,
rem and a freshly extracted folder never has the marker anyway.
set "GADGET_HOME=%~dp0"
if not exist "%APPDIR%\data" mkdir "%APPDIR%\data" >nul 2>nul
if not exist "%APPDIR%\data\.unblocked" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "if ($env:GADGET_HOME) { Get-ChildItem -LiteralPath $env:GADGET_HOME -Recurse -File -ErrorAction SilentlyContinue | Unblock-File }" >nul 2>nul
    if errorlevel 1 (
        echo [WARN] Could not clear the downloaded-file mark. If Windows keeps warning about
        echo        scripts, right-click the zip before extracting, choose Properties, click Unblock.
    ) else (
        type nul > "%APPDIR%\data\.unblocked"
    )
)

rem --- preflight -------------------------------------------------------------
set "MISSING="
set "PSOK=1"
where powershell >nul 2>nul
if errorlevel 1 set "PSOK=0"
if not exist "%APPDIR%\ocr\ocr_answer.ps1" set "MISSING=%MISSING% ocr\ocr_answer.ps1"
if not exist "%APPDIR%\ocr\ocr_region.ps1" set "MISSING=%MISSING% ocr\ocr_region.ps1"
if not exist "%APPDIR%\ocr\ghost_monitor.ps1" set "MISSING=%MISSING% ocr\ghost_monitor.ps1"
if not exist "%APPDIR%\ocr\ghost_texts.txt" set "MISSING=%MISSING% ocr\ghost_texts.txt"
if not exist "%APPDIR%\ocr_tiku.txt" set "MISSING=%MISSING% ocr_tiku.txt"
if "%PSOK%"=="0" echo [ERROR] Windows PowerShell not found - the OCR features need it.
if defined MISSING (
    echo [WARN] Some files are missing under app\, OCR features will not run:
    echo       %MISSING%
    echo        Extract the whole zip and keep the folder layout as shipped.
)

if /i "%~1"=="--check" goto :report

rem --- start -----------------------------------------------------------------
echo Starting toolbox: %BEST%
start "" mshta.exe "%BEST%"
endlocal
exit /b 0

:report
echo Launcher check
echo   folder    : %~dp0
echo   app       : %APPDIR%
echo   toolbox   : %BEST%
echo   size      : %BESTSIZE% bytes
echo   hta files : %COUNT%
echo   powershell: %PSOK% (1 = found)
if defined MISSING echo   missing :%MISSING%
echo   Tip: the toolbox runs its own check on start and explains anything missing.
endlocal
exit /b 0

:nohta
echo [ERROR] No .hta file found in app\ or next to this launcher.
echo         Extract the whole zip first, then run the launcher inside that folder.
pause
endlocal
exit /b 1
