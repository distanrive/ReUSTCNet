class_name WinRegistry
extends RefCounted
## 注册表读写（走 `reg.exe`）。
##
## 用途：密码密钥（见 SecretStore）、系统代理开关，以及**清理旧版遗留的自启项**。
## GDScript 没有 Win32 API，所以只能靠 `reg.exe`；命令参数全部经 PackedStringArray
## 传递、由 Godot 负责加引号，因此带空格的键名（`...\Internet Settings`）也是安全的。

## 旧版把开机自启写在这里。**现在只用它做搬迁**：见 `WinSystem.migrate_legacy_autostart()`。
## 写这个键是杀软的高频特征，新版改成在启动文件夹里建快捷方式了。
const RUN_KEY := "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
const APP_KEY := "HKCU\\Software\\ReUSTCNet"

## 自启项的名字。**沿用旧版 Python 实现的值名 / 文件名**，这样已经装过旧版的用户
## 升级后两边的叫法仍然对得上（搬迁时不会建出第二条，或者漏删旧的）。
const AUTOSTART_VALUE := "ReUSTCNet"


## 读一个 REG_SZ 值。返回 `{"ok": bool, "value": String}`。
## 值不存在时 ok=false（`reg query` 返回非 0），这属于正常情况，不是错误。
static func read_string(key: String, value_name: String) -> Dictionary:
	var r := WinShell.run("reg.exe", PackedStringArray(["query", key, "/v", value_name]))
	if not r["ok"]:
		return {"ok": false, "value": ""}
	return {"ok": true, "value": _parse_reg_sz(str(r["out"]), value_name)}


## 值是否存在（不看内容）。比读出来再比较可靠 —— 内容里的非 ASCII 字符
## 在 `OS.execute` 拿到时可能已经被系统代码页转换坏掉。
static func value_exists(key: String, value_name: String) -> bool:
	var r := WinShell.run("reg.exe", PackedStringArray(["query", key, "/v", value_name]))
	return bool(r["ok"])


static func write_string(key: String, value_name: String, value: String) -> bool:
	var r := WinShell.run("reg.exe", PackedStringArray([
		"add", key, "/v", value_name, "/t", "REG_SZ", "/d", value, "/f"]))
	return bool(r["ok"])


static func write_dword(key: String, value_name: String, value: int) -> bool:
	var r := WinShell.run("reg.exe", PackedStringArray([
		"add", key, "/v", value_name, "/t", "REG_DWORD", "/d", str(value), "/f"]))
	return bool(r["ok"])


## 删一个值。值本来就不存在时返回 true（幂等）。
static func delete_value(key: String, value_name: String) -> bool:
	var r := WinShell.run("reg.exe", PackedStringArray(["delete", key, "/v", value_name, "/f"]))
	return bool(r["ok"])


# ---------------------------------------------------------------- 内部

## 从 `reg query` 的输出里抠出 REG_SZ 的值。
##
## `reg query` 的输出长这样（每行都是「缩进 + 值名 + 类型 + 值」，值本身可以含空格）：
##     HKEY_CURRENT_USER\Software\...\Run
##         ReUSTCNet    REG_SZ    C:\Program Files\ReUSTCNet\ReUSTCNet.exe
##
## 所以只能按「行首是值名 + 类型标记」定位，不能按空白切分取第 N 段。
static func _parse_reg_sz(output: String, value_name: String) -> String:
	for raw_line in output.split("\n"):
		var line := raw_line.strip_edges()
		if not line.begins_with(value_name):
			continue
		# 值名后面必须跟空白，否则 "ReUSTCNet2" 也会被当成本值名
		if line.length() > value_name.length():
			var next := line[value_name.length()]
			if next != " " and next != "\t":
				continue
		var at := line.find("REG_SZ")
		if at < 0:
			continue        # REG_DWORD / REG_EXPAND_SZ 等，本函数不管
		return line.substr(at + "REG_SZ".length()).strip_edges()
	return ""
