import base64
import ctypes
import json
import os
import re
import subprocess
import sys
import threading
import time
import tkinter as tk
import winreg
from ctypes import wintypes
from datetime import datetime
from tkinter import ttk, messagebox, scrolledtext

import pystray
import requests
from PIL import Image, ImageDraw

# ---------- 单实例检查 ----------
MUTEX_NAME = "Global\\ReUSTCNet_SingleInstance"
kernel32 = ctypes.windll.kernel32
kernel32.CreateMutexW.argtypes = [wintypes.LPCVOID, wintypes.BOOL, wintypes.LPCWSTR]
kernel32.CreateMutexW.restype = wintypes.HANDLE
kernel32.GetLastError.restype = wintypes.DWORD

def is_already_running():
    mutex = kernel32.CreateMutexW(None, False, MUTEX_NAME)
    if not mutex:
        return True
    if kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        ctypes.windll.kernel32.CloseHandle(mutex)
        return True
    return False

if is_already_running():
    ctypes.windll.user32.MessageBoxW(0, "ReUSTCNet 已经在运行。", "USTC 网络重连器", 0x40)
    sys.exit(0)

# ---------- 路径 ----------
if getattr(sys, 'frozen', False):
    BASE_DIR = os.path.dirname(sys.executable)
else:
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))

def resource_path(relative_path):
    if getattr(sys, 'frozen', False):
        return os.path.join(sys._MEIPASS, relative_path)  # pylint: disable=protected-access  # noqa: type: ignore[attr-defined]
    return os.path.join(BASE_DIR, relative_path)

ICON_FILE_NAME = "icon.ico"
ICON_PATH = resource_path(ICON_FILE_NAME) if os.path.exists(resource_path(ICON_FILE_NAME)) else None

CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
LOG_DIR = os.path.join(BASE_DIR, "logs")
os.makedirs(LOG_DIR, exist_ok=True)

# ---------- DPAPI ----------
CRYPTPROTECT_UI_FORBIDDEN = 0x1

class DATA_BLOB(ctypes.Structure):  # pylint: disable=invalid-name  # noqa: N801 — matches Windows API naming
    _fields_ = [
        ("cbData", wintypes.DWORD),
        ("pbData", ctypes.POINTER(ctypes.c_char))
    ]

crypt32 = ctypes.windll.crypt32
crypt32.CryptProtectData.restype = wintypes.BOOL
crypt32.CryptProtectData.argtypes = [
    ctypes.POINTER(DATA_BLOB),
    wintypes.LPCWSTR,
    ctypes.POINTER(DATA_BLOB),
    ctypes.c_void_p,
    ctypes.c_void_p,
    wintypes.DWORD,
    ctypes.POINTER(DATA_BLOB)
]
crypt32.CryptUnprotectData.restype = wintypes.BOOL
crypt32.CryptUnprotectData.argtypes = [
    ctypes.POINTER(DATA_BLOB),
    ctypes.POINTER(wintypes.LPWSTR),
    ctypes.POINTER(DATA_BLOB),
    ctypes.c_void_p,
    ctypes.c_void_p,
    wintypes.DWORD,
    ctypes.POINTER(DATA_BLOB)
]

def dpapi_encrypt(plaintext: str) -> str:
    data_in = plaintext.encode('utf-8')
    blob_in = DATA_BLOB(len(data_in), ctypes.cast(data_in, ctypes.POINTER(ctypes.c_char)))  # type: ignore[arg-type]
    blob_out = DATA_BLOB()
    if not crypt32.CryptProtectData(
        ctypes.byref(blob_in), None, None, None, None,
        CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(blob_out)
    ):
        raise OSError("DPAPI 加密失败")
    encrypted_bytes = ctypes.string_at(blob_out.pbData, blob_out.cbData)
    ctypes.windll.kernel32.LocalFree(blob_out.pbData)
    return base64.b64encode(encrypted_bytes).decode('utf-8')

def dpapi_decrypt(encrypted_b64: str) -> str:
    encrypted_bytes = base64.b64decode(encrypted_b64)
    blob_in = DATA_BLOB(len(encrypted_bytes), ctypes.cast(encrypted_bytes, ctypes.POINTER(ctypes.c_char)))  # type: ignore[arg-type]
    blob_out = DATA_BLOB()
    if not crypt32.CryptUnprotectData(
        ctypes.byref(blob_in), None, None, None, None,
        CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(blob_out)
    ):
        raise OSError("DPAPI 解密失败（可能用户账户已变更）")
    decrypted_bytes = ctypes.string_at(blob_out.pbData, blob_out.cbData)
    ctypes.windll.kernel32.LocalFree(blob_out.pbData)
    return decrypted_bytes.decode('utf-8')

# ---------- 配置管理器 ----------
class ConfigManager:
    def __init__(self):
        self.config = self.load_config()

    def load_config(self):
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
                    config = json.load(f)
                pwd = config.get("password", "")
                if config.get("password_encrypted", False) or pwd.startswith("enc:"):
                    if pwd.startswith("enc:"):
                        pwd = pwd[4:]
                    try:
                        config["password"] = dpapi_decrypt(pwd)
                    except Exception:  # noqa: broad-except — 解密失败可能是 OSError/base64/Unicode 等多种异常
                        config["password"] = ""
                if "startup_on_boot" in config and "auto_start" not in config:
                    config["auto_start"] = config.pop("startup_on_boot")
                if "auto_command" not in config:
                    config["auto_command"] = config.pop("auto_shutdown", False)
                    config["command_hour"] = config.pop("shutdown_hour", 23)
                    config["command_minute"] = config.pop("shutdown_minute", 0)
                    config.setdefault("command_countdown", 30)
                config.setdefault("command_last_triggered", "")
                return config
            except Exception:  # noqa: broad-except — 配置文件损坏时回退到默认配置
                pass

        default_config = {
            "username": "",
            "password": "",
            "export_type": "0",
            "expire": "0",
            "fast_retry_interval": 60,
            "normal_check_interval": 900,
            "auto_start": False,
            "auto_command": False,
            "command_hour": 23,
            "command_minute": 0,
            "command_countdown": 30,
            "command_last_triggered": ""
        }
        self.save_config(default_config)
        return default_config

    def save_config(self, config):
        config_to_save = config.copy()
        pwd = config_to_save.get("password", "")
        if pwd:
            config_to_save["password"] = "enc:" + dpapi_encrypt(pwd)
            config_to_save["password_encrypted"] = True
        else:
            config_to_save["password"] = ""
            config_to_save["password_encrypted"] = False
        config_to_save.pop("startup_on_boot", None)
        with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
            json.dump(config_to_save, f, indent=4, ensure_ascii=False)
        self.config = config

# ---------- 网络管理器 ----------
class NetworkManager:
    def __init__(self, config_manager):
        self.config_manager = config_manager
        self.running = False
        self.persistent_session = None

    @staticmethod
    def set_encoding(response):
        """智能检测编码：优先使用 requests 检测结果，失败则回退到 gb2312"""
        if response.apparent_encoding and response.apparent_encoding.lower() not in ('ascii', 'iso-8859-1'):
            response.encoding = response.apparent_encoding
        else:
            response.encoding = 'gb2312'

    def safe_get(self, session, url, **kwargs):
        try:
            kwargs.setdefault('timeout', 5)
            r = session.get(url, **kwargs)
            self.set_encoding(r)
            return r
        except Exception as e:
            print(f"GET {url} 失败: {e}")
            return None

    def safe_post(self, session, url, data, headers=None):
        try:
            kwargs = {'timeout': 5}
            if headers:
                kwargs['headers'] = headers
            r = session.post(url, data=data, **kwargs)
            self.set_encoding(r)
            return r
        except Exception as e:
            print(f"POST {url} 失败: {e}")
            return None

    def get_client_ip(self, session):
        base_url = "http://wlt.ustc.edu.cn/cgi-bin/ip"
        r = self.safe_get(session, base_url)
        if not r:
            return None
        match = re.search(r'IP地址</td>\s*<td[^>]*>([\d.]+)\s*</td>', r.text)
        if match:
            return match.group(1)
        return None

    def is_already_logged_in(self, session):
        base_url = "http://wlt.ustc.edu.cn/cgi-bin/ip"
        r = self.safe_get(session, base_url, params={"cmd": "disp"})
        if not r:
            return False
        return "拥有的权限" in r.text

    def login(self, session, ip):
        base_url = "http://wlt.ustc.edu.cn/cgi-bin/ip"
        data = {
            "cmd": "login",
            "name": self.config_manager.config["username"],
            "password": self.config_manager.config["password"],
            "ip": ip,
            "go": "登录帐户",
        }
        headers = {
            "Referer": f"{base_url}",
            "Origin": "http://wlt.ustc.edu.cn",
        }
        r = self.safe_post(session, base_url, data=data, headers=headers)
        if not r:
            return False, "网络请求失败"
        if "用户" in r.text and "拥有的权限" in r.text:
            return True, "登录成功"
        if "密码错误" in r.text:
            return False, "密码错误"
        if "用户不存在" in r.text:
            return False, "用户不存在"
        if "网络故障" in r.text:
            return False, "网络故障"
        return False, f"登录失败: {r.text[:50]}..."

    def activate_network(self, session):
        base_url = "http://wlt.ustc.edu.cn/cgi-bin/ip"
        params = {
            "cmd": "set",
            "type": self.config_manager.config["export_type"],
            "exp": self.config_manager.config["expire"],
            "go": " 开通网络 ",
        }
        r = self.safe_get(session, base_url, params=params)
        if not r:
            return False, "网络请求失败"
        if "网络设置成功" in r.text or "权限: 国际" in r.text:
            return True, "网络设置成功"
        return False, f"设置失败: {r.text[:50]}..."

    def check_permission(self):
        if self.persistent_session is None:
            return False
        base_url = "http://wlt.ustc.edu.cn/cgi-bin/ip"
        r = self.safe_get(self.persistent_session, base_url, params={"cmd": "disp"})
        if not r:
            return False
        return "权限: 国际" in r.text

    def get_current_port_info(self):
        if self.persistent_session is None:
            return "未知"
        base_url = "http://wlt.ustc.edu.cn/cgi-bin/ip"
        r = self.safe_get(self.persistent_session, base_url, params={"cmd": "disp"})
        if not r:
            return "未知"
        port_map = {
            "0": "1教育网出口",
            "1": "2电信网出口",
            "2": "3联通网出口",
            "3": "4电信网出口2",
            "4": "5联通网出口2",
            "5": "6电信网出口3",
            "6": "7联通网出口3",
            "7": "8教育网出口2",
            "8": "9移动网出口"
        }
        current_type = self.config_manager.config["export_type"]
        return port_map.get(current_type, f"未知出口({current_type})")

    def full_reconnect(self):
        if self.persistent_session is None:
            self.persistent_session = requests.Session()
            self.persistent_session.headers.update({
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            })
        sess = self.persistent_session
        ip = self.get_client_ip(sess)
        if not ip:
            self.persistent_session = None
            return False, "获取IP失败"
        if not self.is_already_logged_in(sess):
            success, msg = self.login(sess, ip)
            if not success:
                self.persistent_session = None
                return False, msg
        success, msg = self.activate_network(sess)
        if success:
            return True, f"当前连接到: {self.get_current_port_info()}"
        return False, msg

    def start_monitoring(self, status_callback):
        self.running = True
        fast_interval = self.config_manager.config["fast_retry_interval"]
        normal_interval = self.config_manager.config["normal_check_interval"]
        interval = fast_interval
        state = "fast"
        status_callback("正在初始化连接...", None)
        success, msg = self.full_reconnect()
        status_callback(msg, not success)
        if success:
            state = "normal"
            interval = normal_interval
        while self.running:
            try:
                if state == "normal":
                    time.sleep(interval)
                    if self.check_permission():
                        status_callback(f"连接正常 - 当前连接到: {self.get_current_port_info()}", False)
                    else:
                        status_callback("网络异常，正在重连...", True)
                        success, msg = self.full_reconnect()
                        status_callback(msg, not success)
                        if not success:
                            status_callback("重连失败，切换到快速重试模式", True)
                            interval = fast_interval
                            state = "fast"
                else:  # state == "fast"
                    if self.check_permission():
                        status_callback(f"网络已恢复 - 当前连接到: {self.get_current_port_info()}", False)
                        interval = normal_interval
                        state = "normal"
                        continue
                    status_callback("网络断开，尝试重连...", True)
                    success, msg = self.full_reconnect()
                    if success:
                        status_callback(msg, False)
                        interval = normal_interval
                        state = "normal"
                        continue
                    status_callback(msg, True)
                    time.sleep(interval)
            except Exception as e:
                status_callback(f"检测异常: {str(e)}", True)
                time.sleep(fast_interval)

    def stop_monitoring(self):
        self.running = False
        session_to_close = self.persistent_session
        self.persistent_session = None
        if session_to_close:
            threading.Thread(target=session_to_close.close, daemon=True).start()

# ---------- 图形界面 ----------
class USTCNetApp:
    EXPORT_TYPES = [
        ("1教育网出口(国际,仅用教育网访问,适合看文献)", "0"),
        ("2电信网出口(国际,到教育网走教育网)", "1"),
        ("3联通网出口(国际,到教育网走教育网)", "2"),
        ("4电信网出口2(国际,到教育网免费地址走教育网)", "3"),
        ("5联通网出口2(国际,到教育网免费地址走教育网)", "4"),
        ("6电信网出口3(国际,默认电信,其他分流)", "5"),
        ("7联通网出口3(国际,默认联通,其他分流)", "6"),
        ("8教育网出口2(国际,默认教育网,其他分流)", "7"),
        ("9移动网出口(国际,无P2P或带宽限制)", "8")
    ]

    # --- widget 属性类型声明（在 create_widgets / setup_tray_icon 中赋值）---
    username_var: tk.StringVar
    username_entry: ttk.Entry
    password_var: tk.StringVar
    password_entry: ttk.Entry
    remember_password_var: tk.BooleanVar
    remember_cb: ttk.Checkbutton
    clear_password_btn: ttk.Button
    status_result_var: tk.StringVar
    status_result_label: ttk.Label
    connection_info_var: tk.StringVar
    connection_info_label: ttk.Label
    export_type_var: tk.StringVar
    export_type_combo: ttk.Combobox
    normal_interval_var: tk.StringVar
    fast_interval_var: tk.StringVar
    startup_var: tk.BooleanVar
    startup_check: ttk.Checkbutton
    clear_startup_btn: ttk.Button
    auto_command_var: tk.BooleanVar
    command_cb: ttk.Checkbutton
    command_hour_var: tk.StringVar
    command_minute_var: tk.StringVar
    command_countdown_var: tk.StringVar
    reset_command_btn: ttk.Button
    log_text: scrolledtext.ScrolledText
    start_button: ttk.Button
    stop_button: ttk.Button
    icon: pystray.Icon
    tray_thread: threading.Thread

    def __init__(self):
        self.root = tk.Tk()
        self.root.title("USTC 有线网络登录重连器")
        self.root.geometry("600x550")
        if ICON_PATH:
            self.root.iconbitmap(ICON_PATH)
        self.root.rowconfigure(0, weight=1)
        self.root.columnconfigure(0, weight=1)

        self.config_manager = ConfigManager()
        self.network_manager = NetworkManager(self.config_manager)
        self.monitoring_thread = None
        self.command_thread = None
        self.command_dialog = None
        self._command_hour = 23
        self._command_minute = 0
        self._command_countdown = 30
        self._command_last_triggered = ""

        # 托盘图标（在 setup_tray_icon 中创建，由 create_widgets 调用）
        self.icon = None
        self.tray_thread = None

        self.create_widgets()
        self.load_settings()
        self.startup_var.set(self.is_startup_enabled())

        if (self.config_manager.config.get("auto_start", False) and
                self.config_manager.config.get("username", "") and
                self.config_manager.config.get("password", "")):
            self.start_monitoring()

    @staticmethod
    def format_spinbox(var, max_val):
        try:
            val = int(var.get())
            if val < 0:
                val = 0
            elif val > max_val:
                val = max_val
            var.set(f"{val:02d}")
        except ValueError:
            var.set("00")

    @staticmethod
    def format_countdown(var):
        try:
            val = int(var.get())
            if val < 1:
                val = 1
            elif val > 3600:
                val = 3600
            var.set(str(val))
        except ValueError:
            var.set("30")

    def create_widgets(self):
        main_frame = ttk.Frame(self.root, padding="10")
        main_frame.grid(row=0, column=0, sticky="nsew")

        for i in range(4):
            main_frame.columnconfigure(i, weight=1)
        main_frame.rowconfigure(2, weight=1)

        # 账户信息
        account_frame = ttk.LabelFrame(main_frame, text="账户信息", padding="10")
        account_frame.grid(row=0, column=0, columnspan=2, sticky="new", pady=(0, 10))
        account_frame.columnconfigure(1, weight=1)

        ttk.Label(account_frame, text="账号:").grid(row=0, column=0, sticky="w", padx=(0, 5))
        self.username_var = tk.StringVar()
        self.username_entry = ttk.Entry(account_frame, textvariable=self.username_var, width=20)
        self.username_entry.grid(row=0, column=1, sticky="we")

        ttk.Label(account_frame, text="密码:").grid(row=1, column=0, sticky="w", padx=(0, 5), pady=(5, 0))
        self.password_var = tk.StringVar()
        self.password_entry = ttk.Entry(account_frame, textvariable=self.password_var, show="*", width=20)
        self.password_entry.grid(row=1, column=1, sticky="we", pady=(5, 0))

        checkbox_frame = ttk.Frame(account_frame)
        checkbox_frame.grid(row=2, column=0, columnspan=2, sticky="w", pady=(5, 0))

        self.remember_password_var = tk.BooleanVar()
        self.remember_cb = ttk.Checkbutton(checkbox_frame, text="记住密码", variable=self.remember_password_var)
        self.remember_cb.pack(side=tk.LEFT)

        self.clear_password_btn = ttk.Button(checkbox_frame, text="清除已保存的密码", command=self.clear_saved_password)
        self.clear_password_btn.pack(side=tk.LEFT, padx=(10, 0))

        # 状态区域
        status_frame = ttk.LabelFrame(main_frame, text="状态", padding="10")
        status_frame.grid(row=0, column=2, columnspan=2, sticky="new", padx=(10, 0), pady=(0, 10))
        status_frame.columnconfigure(1, weight=1)

        ttk.Label(status_frame, text="连接状态:").grid(row=0, column=0, sticky="w", padx=(0, 5))
        self.status_result_var = tk.StringVar(value="未启动")
        self.status_result_label = ttk.Label(status_frame, textvariable=self.status_result_var, foreground="gray")
        self.status_result_label.grid(row=0, column=1, sticky="we")

        ttk.Label(status_frame, text="连接出口:").grid(row=1, column=0, sticky="w", padx=(0, 5), pady=(5, 0))
        self.connection_info_var = tk.StringVar(value="等待启动")
        self.connection_info_label = ttk.Label(status_frame, textvariable=self.connection_info_var, foreground="gray")
        self.connection_info_label.grid(row=1, column=1, sticky="we", pady=(5, 0))

        # 参数设置
        settings_frame = ttk.LabelFrame(main_frame, text="参数设置", padding="10")
        settings_frame.grid(row=1, column=0, columnspan=4, sticky="we", pady=(0, 10))
        settings_frame.columnconfigure(1, weight=1)

        ttk.Label(settings_frame, text="连接端口:").grid(row=0, column=0, sticky="w", padx=(0, 5))
        self.export_type_var = tk.StringVar()
        self.export_type_combo = ttk.Combobox(settings_frame, textvariable=self.export_type_var,
                                              values=[name for name, value in self.EXPORT_TYPES],
                                              state="readonly", width=40)
        self.export_type_combo.grid(row=0, column=1, sticky="we", padx=(5, 0))

        ttk.Label(settings_frame, text="一般连接检测时间(秒):").grid(row=1, column=0, sticky="w", padx=(0, 5), pady=(5, 0))
        self.normal_interval_var = tk.StringVar()
        ttk.Entry(settings_frame, textvariable=self.normal_interval_var, width=10).grid(row=1, column=1, sticky="w",
                                                                                        padx=(5, 0), pady=(5, 0))

        ttk.Label(settings_frame, text="断网重连检测时间(秒):").grid(row=2, column=0, sticky="w", padx=(0, 5), pady=(5, 0))
        self.fast_interval_var = tk.StringVar()
        ttk.Entry(settings_frame, textvariable=self.fast_interval_var, width=10).grid(row=2, column=1, sticky="w",
                                                                                      padx=(5, 0), pady=(5, 0))

        # 分隔线与自启动行
        ttk.Separator(settings_frame, orient='horizontal').grid(row=3, column=0, columnspan=2, sticky="we", pady=(10, 0))

        self.startup_var = tk.BooleanVar()
        self.startup_check = ttk.Checkbutton(settings_frame, text="自启动", variable=self.startup_var,
                                             command=self.toggle_auto_start)
        self.startup_check.grid(row=4, column=0, sticky="w", padx=(5, 0), pady=(5, 0))

        self.clear_startup_btn = ttk.Button(settings_frame, text="删除自启项", command=self.remove_startup_entry)
        self.clear_startup_btn.grid(row=4, column=1, sticky="w", padx=(10, 0), pady=(5, 0))

        # 定时执行指令区域（Spinbox 带循环与格式化）
        ttk.Separator(settings_frame, orient='horizontal').grid(row=5, column=0, columnspan=2, sticky="we", pady=(10, 0))

        self.auto_command_var = tk.BooleanVar()
        self.command_cb = ttk.Checkbutton(settings_frame, text="定时执行指令", variable=self.auto_command_var,
                                          command=self.on_auto_command_toggle)
        self.command_cb.grid(row=6, column=0, sticky="w", padx=(5, 0), pady=(5, 0))

        command_time_frame = ttk.Frame(settings_frame)
        command_time_frame.grid(row=6, column=1, sticky="w", padx=(10, 0))

        ttk.Label(command_time_frame, text="运行时间:").pack(side=tk.LEFT)

        self.command_hour_var = tk.StringVar(value="23")
        hour_spin = tk.Spinbox(command_time_frame, from_=0, to=23, width=3,
                               textvariable=self.command_hour_var,
                               wrap=True, command=self.save_settings)
        hour_spin.pack(side=tk.LEFT)
        hour_spin.bind("<FocusOut>", lambda e: self.format_spinbox(self.command_hour_var, 23))

        ttk.Label(command_time_frame, text=":").pack(side=tk.LEFT)

        self.command_minute_var = tk.StringVar(value="00")
        minute_spin = tk.Spinbox(command_time_frame, from_=0, to=59, width=3,
                                 textvariable=self.command_minute_var,
                                 wrap=True, command=self.save_settings)
        minute_spin.pack(side=tk.LEFT)
        minute_spin.bind("<FocusOut>", lambda e: self.format_spinbox(self.command_minute_var, 59))

        ttk.Label(command_time_frame, text="(24h)").pack(side=tk.LEFT)

        # 确认倒计时（与运行时间同一行）
        ttk.Label(command_time_frame, text="  确认倒计时(秒):").pack(side=tk.LEFT, padx=(15, 0))
        self.command_countdown_var = tk.StringVar(value="30")
        countdown_spin = tk.Spinbox(command_time_frame, from_=1, to=3600, width=6,
                                    textvariable=self.command_countdown_var,
                                    command=self.save_settings)
        countdown_spin.pack(side=tk.LEFT)
        countdown_spin.bind("<FocusOut>", lambda e: self.format_countdown(self.command_countdown_var))

        # 重置触发状态
        self.reset_command_btn = ttk.Button(settings_frame, text="重置触发", command=self.reset_command_triggered)
        self.reset_command_btn.grid(row=7, column=1, sticky="w", padx=(10, 0), pady=(5, 0))

        # 日志区域
        log_frame = ttk.LabelFrame(main_frame, text="最新日志", padding="5")
        log_frame.grid(row=2, column=0, columnspan=4, sticky="nsew", pady=(0, 10))
        self.log_text = scrolledtext.ScrolledText(log_frame, height=8, state=tk.DISABLED)
        self.log_text.grid(row=0, column=0, sticky="nsew")

        # 控制按钮
        button_frame = ttk.Frame(main_frame)
        button_frame.grid(row=3, column=0, columnspan=4, pady=(0, 10))
        self.start_button = ttk.Button(button_frame, text="启动", command=self.start_monitoring)
        self.start_button.grid(row=0, column=0, padx=(0, 10))
        self.stop_button = ttk.Button(button_frame, text="停止", command=self.stop_monitoring)
        self.stop_button.grid(row=0, column=1)

        log_frame.columnconfigure(0, weight=1)
        log_frame.rowconfigure(0, weight=1)
        self.setup_tray_icon()

    def on_auto_command_toggle(self):
        self.save_settings()
        if self.auto_command_var.get():
            self.start_command_watcher()
        else:
            self.stop_command_watcher()

    def start_command_watcher(self):
        if self.command_thread and self.command_thread.is_alive():
            return
        self.command_thread = threading.Thread(target=self._command_watcher_loop, daemon=True)
        self.command_thread.start()

    def stop_command_watcher(self):
        self.command_thread = None

    def reset_command_triggered(self):
        self._command_last_triggered = ""
        self.save_settings()
        self.add_log("已重置定时执行指令触发状态")

    def _on_command_triggered(self):
        self.save_settings()
        self.show_command_dialog()

    def _command_watcher_loop(self):
        while self.auto_command_var.get():
            try:
                now = datetime.now()
                target_h = self._command_hour
                target_m = self._command_minute
                trigger_key = now.strftime("%Y-%m-%d %H:%M")
                if (now.hour == target_h and now.minute == target_m and
                        self._command_last_triggered != trigger_key):
                    self._command_last_triggered = trigger_key
                    self.root.after(0, self._on_command_triggered)
            except Exception as e:
                print(f"指令守护线程异常: {e}")
            time.sleep(1)

    def show_command_dialog(self):
        if self.command_dialog and self.command_dialog.winfo_exists():
            return

        command_bat = os.path.join(BASE_DIR, "command.bat")
        if not os.path.exists(command_bat):
            self.add_log("定时执行指令已触发，但未找到 command.bat 文件，已跳过")
            messagebox.showerror(
                "定时执行指令",
                f"未找到指令文件：\n{command_bat}\n\n"
                "请在程序根目录创建 command.bat，并在其中写入需要执行的指令。"
            )
            return

        countdown = self._command_countdown
        self.add_log(f"定时执行指令已触发，进入 {countdown} 秒倒计时")

        dialog = tk.Toplevel(self.root)
        dialog.title("定时执行指令")
        dialog.geometry("340x150")
        dialog.resizable(False, False)
        dialog.transient(self.root)
        dialog.grab_set()

        if ICON_PATH:
            try:
                dialog.iconbitmap(ICON_PATH)
            except tk.TclError:
                pass

        running = [True]

        countdown_var = tk.StringVar(value=str(countdown))
        tk.Label(dialog, text="系统将在", font=("微软雅黑", 12)).pack(pady=(10, 0))
        tk.Label(dialog, textvariable=countdown_var, font=("微软雅黑", 24, "bold"), fg="red").pack()
        tk.Label(dialog, text="秒后执行 command.bat，是否取消？", font=("微软雅黑", 12)).pack()

        button_frame = tk.Frame(dialog)
        button_frame.pack(pady=10)

        def execute_command():
            if not running[0]:
                return
            running[0] = False
            self.add_log("正在执行 command.bat ...")
            try:
                subprocess.Popen(["cmd", "/c", command_bat], cwd=BASE_DIR)
                self.add_log("command.bat 已启动")
            except Exception as e:  # noqa: broad-except — 启动批处理失败时给出明确提示
                self.add_log(f"执行 command.bat 失败: {e}")
                messagebox.showerror("定时执行指令", f"执行 command.bat 失败:\n{e}")
            dialog.destroy()

        def cancel_command():
            running[0] = False
            self.add_log("定时执行指令已取消")
            dialog.destroy()

        tk.Button(button_frame, text="立即执行", command=execute_command, width=10).pack(side=tk.LEFT, padx=5)
        tk.Button(button_frame, text="取消", command=cancel_command, width=10).pack(side=tk.LEFT, padx=5)

        def update_countdown(remaining):
            if not running[0]:
                return
            if remaining >= 0:
                countdown_var.set(str(remaining))
                dialog.after(1000, update_countdown, remaining - 1)
            else:
                execute_command()

        update_countdown(countdown)
        self.command_dialog = dialog

    def load_settings(self):
        config = self.config_manager.config
        self.username_var.set(config.get("username", ""))
        self.password_var.set(config.get("password", ""))
        self.remember_password_var.set(len(config.get("password", "")) > 0)

        export_names = [name for name, value in self.EXPORT_TYPES]
        self.export_type_combo['values'] = export_names

        current_export_type = config.get("export_type", "0")
        for i, (name, value) in enumerate(self.EXPORT_TYPES):
            if value == current_export_type:
                self.export_type_combo.current(i)
                break

        self.normal_interval_var.set(str(config.get("normal_check_interval", 900)))
        self.fast_interval_var.set(str(config.get("fast_retry_interval", 60)))
        self.startup_var.set(config.get("auto_start", False))

        command_hour = config.get("command_hour", 23)
        command_minute = config.get("command_minute", 0)
        self.command_hour_var.set(f"{int(command_hour):02d}")
        self.command_minute_var.set(f"{int(command_minute):02d}")
        self._command_hour = int(command_hour)
        self._command_minute = int(command_minute)
        command_countdown = config.get("command_countdown", 30)
        self.command_countdown_var.set(str(int(command_countdown)))
        self._command_countdown = int(command_countdown)
        self._command_last_triggered = config.get("command_last_triggered", "")
        self.auto_command_var.set(config.get("auto_command", False))

        if self.auto_command_var.get():
            self.start_command_watcher()

    def save_settings(self):
        try:
            h = int(self.command_hour_var.get())
            m = int(self.command_minute_var.get())
        except ValueError:
            h, m = 23, 0
        try:
            countdown = int(self.command_countdown_var.get())
            if countdown < 1:
                countdown = 1
        except ValueError:
            countdown = 30
        config = {
            "username": self.username_var.get(),
            "password": self.password_var.get() if self.remember_password_var.get() else "",
            "export_type": self.get_current_export_type_value(),
            "expire": "0",
            "fast_retry_interval": int(self.fast_interval_var.get()) if self.fast_interval_var.get().isdigit() else 60,
            "normal_check_interval": int(self.normal_interval_var.get()) if self.normal_interval_var.get().isdigit() else 900,
            "auto_start": self.startup_var.get(),
            "auto_command": self.auto_command_var.get(),
            "command_hour": h,
            "command_minute": m,
            "command_countdown": countdown,
            "command_last_triggered": self._command_last_triggered,
        }
        self.config_manager.save_config(config)
        self._command_hour = h
        self._command_minute = m
        self._command_countdown = countdown
        self.command_hour_var.set(f"{h:02d}")
        self.command_minute_var.set(f"{m:02d}")
        self.command_countdown_var.set(str(countdown))

    def clear_saved_password(self):
        self.password_var.set("")
        self.remember_password_var.set(False)
        self.save_settings()
        messagebox.showinfo("已清除", "密码已从本地配置中删除。")

    def toggle_auto_start(self):
        try:
            key_path = r"Software\Microsoft\Windows\CurrentVersion\Run"
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path, 0, winreg.KEY_SET_VALUE) as key:
                exe_path = os.path.abspath(sys.argv[0])
                if self.startup_var.get():
                    winreg.SetValueEx(key, "ReUSTCNet", 0, winreg.REG_SZ, exe_path)
                else:
                    try:
                        winreg.DeleteValue(key, "ReUSTCNet")
                    except FileNotFoundError:
                        pass
        except Exception as e:
            messagebox.showerror("错误", f"设置自启动失败: {str(e)}")
        finally:
            self.save_settings()

    def remove_startup_entry(self):
        self.startup_var.set(False)
        try:
            key_path = r"Software\Microsoft\Windows\CurrentVersion\Run"
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path, 0, winreg.KEY_SET_VALUE) as key:
                try:
                    winreg.DeleteValue(key, "ReUSTCNet")
                except FileNotFoundError:
                    pass
        except Exception as e:
            messagebox.showerror("错误", f"删除自启动项失败: {str(e)}")
            return
        self.save_settings()
        messagebox.showinfo("已删除", "自启动注册表项已删除。")

    def get_current_export_type_value(self):
        current_selection = self.export_type_combo.get()
        for name, value in self.EXPORT_TYPES:
            if name == current_selection:
                return value
        return "0"

    @staticmethod
    def write_log_to_file(message):
        log_filename = os.path.join(LOG_DIR, f"log_{datetime.now().strftime('%Y-%m-%d')}.txt")
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        with open(log_filename, 'a', encoding='utf-8') as f:
            f.write(f"[{timestamp}] {message}\n")

    def update_status(self, message, is_error=None):
        """线程安全的状态更新。is_error: True=错误, False=正常, None=中性（不改变状态指示器）"""
        self.root.after(0, lambda: self._update_status_impl(message, is_error))

    def _update_status_impl(self, message, is_error):
        def extract_port(msg):
            match = re.search(r'当前连接到:\s*(.+)', msg)
            if match:
                return match.group(1).strip()
            return msg

        display_msg = extract_port(message)
        if is_error is True:
            self.status_result_var.set("失败")
            self.status_result_label.config(foreground="red")
            self.connection_info_var.set(display_msg)
            self.connection_info_label.config(foreground="red")
        elif is_error is False:
            self.status_result_var.set("成功")
            self.status_result_label.config(foreground="green")
            self.connection_info_var.set(display_msg)
            self.connection_info_label.config(foreground="blue")
        else:
            self.status_result_var.set("处理中")
            self.status_result_label.config(foreground="gray")
            self.connection_info_var.set(display_msg)
            self.connection_info_label.config(foreground="gray")
        self.add_log(message)

    def add_log(self, message):
        self.log_text.config(state=tk.NORMAL)
        self.log_text.insert(tk.END, f"[{time.strftime('%H:%M:%S')}] {message}\n")
        self.log_text.see(tk.END)
        self.log_text.config(state=tk.DISABLED)
        self.write_log_to_file(message)

    def start_monitoring(self):
        if not self.username_var.get() or not self.password_var.get():
            messagebox.showerror("错误", "请输入账号和密码")
            return
        self.save_settings()
        if not self.network_manager.running:
            self.network_manager = NetworkManager(self.config_manager)
            self.monitoring_thread = threading.Thread(
                target=self.network_manager.start_monitoring,
                args=(self.update_status,)
            )
            self.monitoring_thread.daemon = True
            self.monitoring_thread.start()
            self.start_button.config(state=tk.DISABLED)
            self.stop_button.config(state=tk.NORMAL)
            self.add_log("开始监控网络连接")
            if self.auto_command_var.get():
                self.start_command_watcher()

    def stop_monitoring(self):
        if self.network_manager.running:
            self.network_manager.stop_monitoring()
            self.start_button.config(state=tk.NORMAL)
            self.stop_button.config(state=tk.DISABLED)
            self.add_log("停止监控网络连接")
            self.status_result_var.set("未启动")
            self.status_result_label.config(foreground="gray")
            self.connection_info_var.set("等待启动")
            self.connection_info_label.config(foreground="gray")

    @staticmethod
    def is_startup_enabled():
        try:
            key_path = r"Software\Microsoft\Windows\CurrentVersion\Run"
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path) as key:
                value, _ = winreg.QueryValueEx(key, "ReUSTCNet")
                exe_path = os.path.abspath(sys.argv[0])
                return value == exe_path
        except FileNotFoundError:
            return False
        except OSError:
            return False

    def setup_tray_icon(self):
        if ICON_PATH:
            image = Image.open(ICON_PATH)
        else:
            image = Image.new('RGB', (64, 64), 'white')
            draw = ImageDraw.Draw(image)
            draw.ellipse((10, 10, 54, 54), fill='blue', outline='black')
            draw.rectangle((25, 20, 39, 44), fill='white')
        self.icon = pystray.Icon("ReUSTCNet", image, menu=pystray.Menu(
            pystray.MenuItem("显示", self.show_window, default=True),
            pystray.MenuItem("退出", self.quit_app)
        ))
        def run_icon():
            self.icon.run()
        self.tray_thread = threading.Thread(target=run_icon, daemon=True)
        self.tray_thread.start()

    def show_window(self, _icon, _item):
        self.root.deiconify()

    def quit_app(self, _icon, _item):
        self.stop_command_watcher()
        self.network_manager.stop_monitoring()
        self.icon.stop()
        self.root.quit()

    def on_closing(self):
        if self.network_manager.running:
            self.root.withdraw()
        else:
            self.quit_app(None, None)

    def run(self):
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)
        self.root.mainloop()

if __name__ == "__main__":
    app = USTCNetApp()
    app.run()
