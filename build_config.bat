@echo off
:: ============================================
:: USTC ReUSTCNet 打包配置文件
:: 请根据你的环境修改以下路径
:: ============================================

:: Python 解释器路径（Anaconda 或标准 Python）
set "PYTHON_EXE=C:\ProgramData\anaconda3\python.exe"

:: UPX 可执行文件所在目录（留空则不使用 UPX 压缩）
set "UPX_DIR=D:\python_file\upx-5.2.0-win64\upx"

:: 生成的 exe 名称
set "EXE_NAME=reustcnet"

:: Anaconda 的 Library\bin 路径（用于补充 DLL，标准 Python 不需要）
set "ANACONDA_LIB_BIN=C:\ProgramData\anaconda3\Library\bin"

:: 程序图标文件（可选，留空则不设置图标）
set "ICON_FILE=icon.ico"