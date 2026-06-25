@echo off
setlocal enabledelayedexpansion

echo ========================================
echo   USTC ReUSTCNet Build Script
echo ========================================
echo.

:: 加载配置文件
if exist "build_config.bat" (
    call "build_config.bat"
) else (
    echo [ERROR] build_config.bat not found! Please create it from build_config.bat.example.
    pause
    exit /b 1
)

if not defined PYTHON_EXE (
    echo [ERROR] PYTHON_EXE not defined in build_config.bat
    pause
    exit /b 1
)

if not exist "%PYTHON_EXE%" (
    echo [ERROR] Python not found: %PYTHON_EXE%
    pause
    exit /b 1
)

set "PROJECT_DIR=%~dp0"
set "VENV_DIR=%PROJECT_DIR%build_venv"

echo [1/5] Creating temporary virtual environment...
"%PYTHON_EXE%" -m venv "%VENV_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to create venv.
    pause
    exit /b 1
)

echo [2/5] Installing dependencies...
"%VENV_DIR%\Scripts\python.exe" -m pip install requests pystray pillow pyinstaller -q
if errorlevel 1 (
    echo [ERROR] Failed to install dependencies.
    pause
    exit /b 1
)

echo [3/5] Building executable...
:: 补充 DLL 路径（Anaconda 用户需要）
if defined ANACONDA_LIB_BIN set "PATH=%PATH%;%ANACONDA_LIB_BIN%"

:: 构建 UPX 参数
set "UPX_ARG="
if defined UPX_DIR if exist "%UPX_DIR%\upx.exe" set "UPX_ARG=--upx-dir=%UPX_DIR%"

:: 构建图标参数（exe文件图标）
set "ICON_ARG="
if defined ICON_FILE if exist "%ICON_FILE%" set "ICON_ARG=--icon=%ICON_FILE%"

:: 构建附加数据参数（将图标文件打入包中，供运行时加载）
set "ADD_DATA_ARG="
if defined ICON_FILE if exist "%ICON_FILE%" set "ADD_DATA_ARG=--add-data=%ICON_FILE%;."

"%VENV_DIR%\Scripts\pyinstaller.exe" --onefile --noconsole --clean %UPX_ARG% %ICON_ARG% %ADD_DATA_ARG% --name="%EXE_NAME%" --hidden-import=_tkinter main.py
if errorlevel 1 (
    echo [ERROR] Build failed.
    pause
    exit /b 1
)

echo [4/5] Cleaning up...
rmdir /s /q "%VENV_DIR%"
rmdir /s /q "%PROJECT_DIR%build"
del /q "%EXE_NAME%.spec" >nul 2>&1

echo [5/5] Build success!
echo Output: %PROJECT_DIR%dist\%EXE_NAME%.exe
dir "%PROJECT_DIR%dist\%EXE_NAME%.exe" | findstr /i "%EXE_NAME%.exe"
explorer "%PROJECT_DIR%dist"
pause