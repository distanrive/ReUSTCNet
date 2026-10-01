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
#
# **用启动文件夹里的快捷方式，不写注册表的 `Run` 键。**
#
# 这不是口味问题：`HKCU\...\CurrentVersion\Run` 是杀软启发式里权重最高的持久化位置之一，
# 一个没有代码签名的 exe 往那儿写值，很容易被当成木马行为直接拦掉（本程序就被拦过）。
# 启动文件夹的快捷方式是 Windows 给用户的**正规入口**（「右键 → 发送到 → 桌面快捷方式」
# 那一套的同一个位置），效果完全一样 —— 登录后自动启动 —— 但没有那个特征。
#
# 实现上要借 PowerShell 的 `WScript.Shell` COM 接口：GDScript 里没有创建 `.lnk` 的能力，
# 自己手写 Shell Link 的二进制结构（MS-SHLLINK）能做，但那是几百行极易写错的代码，
# 换来的只是省掉一次几百毫秒的 PowerShell 调用。

## 启动文件夹（当前用户）。`%APPDATA%` 在 Windows 上一定有，取不到就说明环境很不对。
static func startup_dir() -> String:
	var appdata := OS.get_environment("APPDATA")
	if appdata.is_empty():
		return ""
	return appdata.replace("\\", "/").rstrip("/") \
			+ "/Microsoft/Windows/Start Menu/Programs/Startup"


## 快捷方式文件的完整路径（目录取不到时返回空串）。
static func autostart_shortcut_path() -> String:
	var dir := startup_dir()
	if dir.is_empty():
		return ""
	return dir.path_join("%s.lnk" % WinRegistry.AUTOSTART_VALUE)


## 自启项在当前运行方式下是否有意义。
##
## 开发期（在编辑器里跑）`OS.get_executable_path()` 指的是 Godot 编辑器本身，
## 建出来的快捷方式只会得到一条「开机启动 Godot 编辑器」的废项 —— 旧版 Python 实现就是
## 把 `main.py` 的路径写了进去，用户点了「自启」却什么都没发生。这里直接禁掉。
static func autostart_supported() -> bool:
	return not OS.has_feature("editor") and not startup_dir().is_empty()


## 自启项是否存在（不看它指向哪）。**以快捷方式文件为准**，读文件比查注册表快得多，
## 也正是我们唯一会去创建的东西。
static func autostart_entry_exists() -> bool:
	var path := autostart_shortcut_path()
	return not path.is_empty() and FileAccess.file_exists(path)


## 快捷方式指向的路径（取不到返回空串）。
##
## 这条要起一次 PowerShell，所以**只在排查时用**（自检里），启动路径上不要调。
static func autostart_target() -> String:
	var path := autostart_shortcut_path()
	if not autostart_entry_exists():
		return ""
	var r := WinShell.run_powershell(
			"(New-Object -ComObject WScript.Shell).CreateShortcut(%s).TargetPath"
			% WinShell.ps_quote(native(path)))
	return str(r["out"]).strip_edges() if r["ok"] else ""


## 项存在、但指向的不是**当前**这个 exe（程序被挪过地方、或换了版本目录）。
static func autostart_needs_update() -> bool:
	if not autostart_entry_exists():
		return false
	var stored := autostart_target()
	# 读不回内容时当成「需要更新」—— 更新就是重写一遍，幂等，没有副作用。
	return stored.is_empty() or stored != executable_path()


## 建快捷方式，指向当前 exe。**路径取自 `OS.get_executable_path()`** ——
## 开发期它是 Godot 编辑器（所以上面直接禁掉了），导出后才是 exe。
static func enable_autostart() -> bool:
	if not autostart_supported():
		return false
	var path := autostart_shortcut_path()
	AppPaths.ensure_dir(startup_dir().replace("/", "\\"))
	var script := ("$s = New-Object -ComObject WScript.Shell; "
			+ "$l = $s.CreateShortcut(%s); "
			+ "$l.TargetPath = %s; $l.WorkingDirectory = %s; "
			+ "$l.Description = %s; $l.Save()") % [
		WinShell.ps_quote(native(path)),
		WinShell.ps_quote(executable_path()),
		WinShell.ps_quote(native(AppPaths.base_dir())),
		WinShell.ps_quote(WinRegistry.AUTOSTART_VALUE)]
	var r := WinShell.run_powershell(script)
	# 不信退出码，认文件：PowerShell 返回 0 却没建出文件的情况是存在的
	# （COM 对象创建失败的报错默认只走 stderr，退出码照样是 0）。
	if bool(r["ok"]) and FileAccess.file_exists(path):
		return true
	push_warning("[WinSystem] 创建启动快捷方式失败：%s" % str(r["out"]).strip_edges())
	return false


## 删除自启项（不存在时也算成功）。顺手清掉旧版写在注册表里的那一条。
static func disable_autostart() -> bool:
	var ok := true
	var path := autostart_shortcut_path()
	if not path.is_empty() and FileAccess.file_exists(path):
		ok = DirAccess.remove_absolute(path) == OK
	WinRegistry.delete_value(WinRegistry.RUN_KEY, WinRegistry.AUTOSTART_VALUE)
	return ok


## 清掉旧版写在 `HKCU\...\Run` 里的自启项。返回是否真的删掉了东西。
##
## **只删，不建。** 开着机自启是用户的明确选择，程序不替他做这个决定 ——
## 之前的做法是「删掉注册表项、顺手把快捷方式建好，把用户原来的选择保住」，
## 结果是升级完打开界面一看开关自己就是开的，像程序擅自动了启动项。
## 现在只把那个**会被杀软拦的**旧位置清掉，**不碰开关**：开关的初始状态永远是关，
## 要自启得用户自己去勾。
##
## 只在**还没有快捷方式**时才去查注册表 —— 查一次要起一个 `reg.exe`，
## 而正常情况下这条路径一辈子只会走到一次。
static func cleanup_legacy_autostart() -> bool:
	if not autostart_supported() or autostart_entry_exists():
		return false
	if not WinRegistry.value_exists(WinRegistry.RUN_KEY, WinRegistry.AUTOSTART_VALUE):
		return false
	return WinRegistry.delete_value(WinRegistry.RUN_KEY, WinRegistry.AUTOSTART_VALUE)


static func executable_path() -> String:
	return OS.get_executable_path().replace("/", "\\")


## Godot 的路径（正斜杠）换成 Windows 的原生形式 —— PowerShell 收路径时用它。
static func native(path: String) -> String:
	return path.replace("/", "\\")
