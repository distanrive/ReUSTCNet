@echo off
:: ============================================================
::  ReUSTCNet build settings
::  Only this file needs editing when you move to another machine.
::  (ASCII only + CRLF -- see the note at the top of build.bat.)
:: ============================================================

:: Godot executable. Use the *_console.exe* one, otherwise build.bat
:: cannot show the export log or the errors.
set "GODOT_EXE=D:\Program Files\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe"

:: Export preset name -- must match name= in export_presets.cfg exactly.
set "PRESET=Windows Desktop"

:: Output folder and file name.
set "OUT_DIR=dist"
set "EXE_NAME=ReUSTCNet"

:: Run a smoke test after building (headless, 240 frames, greps for engine errors).
:: 1 = yes, 0 = no
set "SMOKE_TEST=1"

:: Build the native window extension (bin\native_window.windows.x86_64.dll) before
:: exporting. It is what lets "close the window" hide it from the taskbar instead of
:: just minimizing. Needs bash + MinGW gcc; see tools/build_native_window.sh.
:: 1 = yes, 0 = skip (keep whatever dll already exists)
set "BUILD_NATIVE=1"

:: Also produce a release archive: none / zip / rar
::   rar needs WinRAR (give the full path to Rar.exe below).
set "PACK=rar"
set "RAR_EXE=C:\Program Files\WinRAR\Rar.exe"

:: Custom (slim) export template compiled by yourself -- see tools/build_template.sh.
:: The official Windows template is 104 MB; this one is ~34 MB after removing
:: 3D/audio/navigation/XR/texture-codec modules that this project never uses.
:: build.bat copies it over windows_release_x86_64.exe in the templates folder,
:: backing up the official one once as windows_release_x86_64.official.bak.
:: Empty = use the official template as-is.
set "CUSTOM_TEMPLATE=D:\godot-build\godot\bin\godot.windows.template_release.x86_64.exe"
