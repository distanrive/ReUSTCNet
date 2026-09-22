class_name WinSystem
extends RefCounted
## Windows 系统集成：开机自启项、系统代理开关。
##
## `WinRegistry` 是「读写注册表」的底层原语，这里是带业务语义的一层
## （哪个键、哪个值名、开关意味着什么）。两处都只影响当前用户（HKCU），不需要管理员权限。

const INTERNET_SETTINGS_KEY := "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"


# ---------------------------------------------------------------- 系统代理

## 关闭 Windows 系统代理开关（**保留代理地址**，只把 ProxyEnable 置 0）。
##
## 与旧版行为一致：只在断网时关，联网后**不自动恢复** —— 恢复与否是用户自己的事，
## 程序擅自改回可能把人家的代理设置弄乱。
static func disable_system_proxy() -> bool:
	return WinRegistry.write_dword(INTERNET_SETTINGS_KEY, "ProxyEnable", 0)


# ---------------------------------------------------------------- 开机自启

## 自启项在当前运行方式下是否有意义。
##
## 开发期（在编辑器里跑）`OS.get_executable_path()` 指的是 Godot 编辑器本身，
## 写进注册表只会得到一条「开机启动 Godot 编辑器」的废项 —— 旧版 Python 实现就是
## 把 `main.py` 的路径写了进去，用户点了「自启」却什么都没发生。这里直接禁掉。
static func autostart_supported() -> bool:
	return not OS.has_feature("editor")


## 自启项是否存在（不看它指向哪）。
static func autostart_entry_exists() -> bool:
	if not autostart_supported():
		return false
	return WinRegistry.value_exists(WinRegistry.RUN_KEY, WinRegistry.AUTOSTART_VALUE)


## 自启项里记的路径（取不到返回空串）。
static func autostart_value() -> String:
	if not autostart_supported():
		return ""
	var r := WinRegistry.read_string(WinRegistry.RUN_KEY, WinRegistry.AUTOSTART_VALUE)
	return str(r["value"]) if r["ok"] else ""


## 项存在、但指向的不是**当前**这个 exe（程序被挪过地方、或换了版本目录）。
static func autostart_needs_update() -> bool:
	if not autostart_entry_exists():
		return false
	var stored := autostart_value()
	# 读不回内容时（路径里的非 ASCII 字符可能被系统代码页转换坏）当成「需要更新」——
	# 更新就是重写一遍，幂等，没有副作用。
	return stored.is_empty() or stored != executable_path()


## 写入自启项，指向当前 exe。**路径取自 `OS.get_executable_path()`**，
## 不是 `sys.argv[0]` —— 后者在开发期是脚本路径，导出后才是 exe。
static func enable_autostart() -> bool:
	if not autostart_supported():
		return false
	return WinRegistry.write_string(WinRegistry.RUN_KEY, WinRegistry.AUTOSTART_VALUE,
			executable_path())


## 删除自启项（不存在时也算成功）。
static func disable_autostart() -> bool:
	return WinRegistry.delete_value(WinRegistry.RUN_KEY, WinRegistry.AUTOSTART_VALUE)


static func executable_path() -> String:
	return OS.get_executable_path().replace("/", "\\")
