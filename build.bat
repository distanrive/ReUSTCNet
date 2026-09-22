@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  ReUSTCNet build script (Godot)
::
::  Usage:  build.bat [release|debug|run|test|templates]
::    release (default)  export release build to dist\, smoke test it
::    debug              export debug build (console wrapper, shows print output)
::    run                export release, then launch it
::    test               export release, then run it headless and grep for errors
::    templates          just list the installed export templates
::
::  Settings live in build_config.bat (edit that file only when moving machines).
::  The .exe and the .pck must always be distributed together.
::
::  NOTE: keep this file ASCII-only and CRLF-terminated.
::    - Non-ASCII in a .bat makes cmd mis-parse lines (comments get executed!)
::      whenever the console code page is 65001, which is what Godot sets on start.
::    - LF-only line endings make cmd drop characters mid-line.
::  Chinese notes for maintainers live in CLAUDE.md instead of here.
:: ============================================================

cd /d "%~dp0"

:: UTF-8 console so the engine's own log output (Godot writes UTF-8) reads correctly.
:: Harmless for our own ASCII messages, which are identical in every code page.
chcp 65001 >nul

if not exist "build_config.bat" (
    echo [ERROR] build_config.bat not found
    pause
    exit /b 1
)
:: Full path, not a bare name: some environments (cmd spawned from Git Bash) set
:: NoDefaultCurrentDirectoryInExePath=1, and then cmd refuses to look in the CWD.
call "%~dp0build_config.bat"

set "MODE=%~1"
if "%MODE%"=="" set "MODE=release"

if not exist "%GODOT_EXE%" (
    echo [ERROR] Godot not found: %GODOT_EXE%
    echo         Fix GODOT_EXE in build_config.bat
    pause
    exit /b 1
)

:: ---------- Detect the Godot version to locate the template dir ----------
:: Do not use `for /f` straight on the command output: spaces in the path plus
:: nested quotes get mangled by cmd. Write to a temp file and read that instead.
set "VERFILE=%TEMP%\_reustcnet_godot_ver.txt"
"%GODOT_EXE%" --version > "%VERFILE%" 2>&1
set "GODOT_VER="
for /f "usebackq delims=" %%v in ("%VERFILE%") do if not defined GODOT_VER set "GODOT_VER=%%v"
del /q "%VERFILE%" >nul 2>&1
:: Looks like 4.7.2.stable.official.ed1daf0bf -- the template dir only needs the first four fields
for /f "tokens=1,2,3,4 delims=." %%a in ("%GODOT_VER%") do set "TPL_VER=%%a.%%b.%%c.%%d"
if not defined TPL_VER (
    echo [ERROR] Could not read the Godot version from "%GODOT_EXE%" --version
    pause
    exit /b 1
)
set "TPL_DIR=%APPDATA%\Godot\export_templates\%TPL_VER%"

echo ============================================================
echo   ReUSTCNet build   [%MODE%]
echo ============================================================
echo   Godot      : %GODOT_EXE%
echo   Version    : %GODOT_VER%
echo   Templates  : %TPL_DIR%
echo   Preset     : %PRESET%
echo ------------------------------------------------------------

set "OUT_EXE=%OUT_DIR%\%EXE_NAME%.exe"
set "EXPORT_FLAG=--export-release"
if /i "%MODE%"=="debug" (
    set "OUT_EXE=%OUT_DIR%\%EXE_NAME%-debug.exe"
    set "EXPORT_FLAG=--export-debug"
)

if /i "%MODE%"=="templates" goto :list_templates

:: ---------- Check templates ----------
:: Branch with goto instead of nesting ifs inside parentheses: cmd chokes on
:: chained tests like that and reports "not was unexpected at this time".
set "MISSING="
if /i "%MODE%"=="debug" goto :check_debug_template
if defined CUSTOM_RELEASE_TEMPLATE goto :templates_ok
if exist "%TPL_DIR%\windows_release_x86_64.exe" goto :templates_ok
set "MISSING=windows_release_x86_64.exe"
goto :templates_ok

:check_debug_template
if defined CUSTOM_DEBUG_TEMPLATE goto :templates_ok
if exist "%TPL_DIR%\windows_debug_x86_64.exe" goto :templates_ok
set "MISSING=windows_debug_x86_64.exe"

:templates_ok
if defined MISSING (
    echo [ERROR] Missing export template: %MISSING%
    echo.
    echo   Download the templates for this Godot version and extract them to:
    echo     %TPL_DIR%\
    echo   The files must land DIRECTLY in that folder -- version.txt,
    echo   windows_release_x86_64.exe and so on -- NOT nested inside a templates\ folder.
    echo   Download: https://godotengine.org/download/windows/  ^(Export Templates^)
    echo.
    echo   See what is installed already:  build.bat templates
    pause
    exit /b 1
)
echo [1/4] Export templates OK

:: ---------- Install the custom (slim) template, if configured ----------
:: Godot only ever reads from the templates folder, so a self-compiled template has
:: to be copied in. The official one is backed up once (a *.official.bak file does
:: not collide -- Godot only looks for windows_release_x86_64.exe).
if not defined CUSTOM_TEMPLATE goto :custom_template_done
if not exist "%CUSTOM_TEMPLATE%" goto :custom_template_missing
if exist "%TPL_DIR%\windows_release_x86_64.official.bak" goto :custom_template_copy
copy /y "%TPL_DIR%\windows_release_x86_64.exe" "%TPL_DIR%\windows_release_x86_64.official.bak" >nul
echo       Backed up the official template as windows_release_x86_64.official.bak
:custom_template_copy
copy /y "%CUSTOM_TEMPLATE%" "%TPL_DIR%\windows_release_x86_64.exe" >nul
if errorlevel 1 goto :custom_template_copyfail
echo       Installed custom template
goto :custom_template_done

:custom_template_missing
echo [WARN] CUSTOM_TEMPLATE not found, falling back to the official template:
echo        %CUSTOM_TEMPLATE%
echo        Build one with tools/build_template.sh, or clear CUSTOM_TEMPLATE in
echo        build_config.bat to silence this warning.
goto :custom_template_done

:custom_template_copyfail
echo [ERROR] Could not copy the custom template into:
echo         %TPL_DIR%
echo         Clear CUSTOM_TEMPLATE in build_config.bat to use the official one.
pause
exit /b 1

:custom_template_done

:: ---------- Refresh imports and the class_name cache ----------
echo [2/4] Importing assets ^(refreshing the class_name cache^)...
"%GODOT_EXE%" --headless --path . --import >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Asset import failed. Run it alone to see the error:
    echo         "%GODOT_EXE%" --headless --path . --import
    pause
    exit /b 1
)

:: ---------- Export ----------
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
echo [3/4] Exporting ^(slow on the first run^)...
"%GODOT_EXE%" --headless --path . %EXPORT_FLAG% "%PRESET%" "%OUT_EXE%"
if errorlevel 1 (
    echo.
    echo [ERROR] Export failed. Usual causes:
    echo   * Preset name mismatch: export_presets.cfg must have name="%PRESET%"
    echo   * Export templates do not match this Godot version ^(see above^)
    echo   * application/icon points at a file that does not exist
    pause
    exit /b 1
)
if not exist "%OUT_EXE%" (
    echo [ERROR] Export reported success but %OUT_EXE% was not produced
    pause
    exit /b 1
)

echo [4/4] Output:
call :show_size "%OUT_EXE%"
call :show_size "%OUT_DIR%\%EXE_NAME%.pck"
call :show_size "%OUT_DIR%\%EXE_NAME%-debug.console.exe"

:: ---------- Smoke test / run ----------
if /i "%MODE%"=="test" (
    call :smoke "%OUT_EXE%"
    pause
    exit /b 0
)
if /i "%MODE%"=="run" (
    echo       Launching %OUT_EXE% ...
    start "" "%OUT_EXE%"
    exit /b 0
)
if "%SMOKE_TEST%"=="1" (
    call :smoke "%OUT_EXE%"
    if errorlevel 1 (
        pause
        exit /b 1
    )
)

:: ---------- Optional release archive ----------
if /i "%PACK%"=="none" goto :done
if /i "%PACK%"=="rar" goto :pack_rar
if /i "%PACK%"=="zip" goto :pack_zip
echo [WARN] Unknown PACK value "%PACK%" -- skipping archive
goto :done

:pack_rar
if not exist "%RAR_EXE%" (
    echo [WARN] %RAR_EXE% not found -- skipping archive
    goto :done
)
for /f "usebackq delims=" %%d in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmm"`) do set "STAMP=%%d"
set "ARCHIVE=%OUT_DIR%\%EXE_NAME%-%STAMP%.rar"
echo       Packing %ARCHIVE% ...
"%RAR_EXE%" a -ep1 -m5 "%ARCHIVE%" "%OUT_EXE%" "%OUT_DIR%\%EXE_NAME%.pck" >nul
call :show_size "%ARCHIVE%"
goto :done

:pack_zip
for /f "usebackq delims=" %%d in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmm"`) do set "STAMP=%%d"
set "ARCHIVE=%OUT_DIR%\%EXE_NAME%-%STAMP%.zip"
echo       Packing %ARCHIVE% ...
powershell -NoProfile -Command "Compress-Archive -Force -LiteralPath '%OUT_EXE%','%OUT_DIR%\%EXE_NAME%.pck' -DestinationPath '%ARCHIVE%'"
call :show_size "%ARCHIVE%"

:done
echo.
echo ============================================================
echo   Done. Output in %OUT_DIR%\
echo   Ship %EXE_NAME%.exe and %EXE_NAME%.pck together.
echo ============================================================
pause
exit /b 0


:: ============================================================ subroutines

:list_templates
echo Windows templates in %TPL_DIR%:
if exist "%TPL_DIR%\windows_*.exe" (
    for %%F in ("%TPL_DIR%\windows_*.exe") do echo     %%~nxF
) else (
    echo     ^(none^)
)
echo.
echo version.txt =
type "%TPL_DIR%\version.txt" 2>nul
if errorlevel 1 echo     ^(unreadable^)
pause
exit /b 0

:show_size
if exist %1 (
    for %%F in (%1) do echo        %%~nxF   %%~zF bytes
)
exit /b 0

:: Smoke test: run the exported build headless for 240 frames and grep the engine's
:: own output for errors. Errors our app merely LOGS do not count as failures.
:smoke
echo.
echo       Smoke test: running headless for 240 frames...
"%~1" --headless --quit-after 240 > "%OUT_DIR%\_smoke.log" 2>&1
findstr /C:"SCRIPT ERROR" /C:"ERROR:" "%OUT_DIR%\_smoke.log" >nul
if not errorlevel 1 (
    echo       [FAIL] The engine reported errors:
    echo       ----------------------------------------
    type "%OUT_DIR%\_smoke.log"
    echo       ----------------------------------------
    exit /b 1
)
echo       [OK] No engine errors
del /q "%OUT_DIR%\_smoke.log" >nul 2>&1
exit /b 0
