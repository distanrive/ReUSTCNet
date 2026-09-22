extends SceneTree
## 自检：把「没法靠看界面发现、但一坏就全坏」的平台相关部分逐个验一遍。
##
##   编码解码    GB2312 页面能不能解成中文（判据全靠它，错了会静默失效）
##   表单编码    中文参数有没有按 GB2312 出去、有没有多带结尾空字节
##   密码往返    SecretStore 加密→解密能不能还原（含中文密码）
##   注册表往返  带空格的键名 / 带空格与非 ASCII 的值能不能正确读回
##   自启项      WinSystem 的读写与「路径是否指向当前程序」判断
##
## 用法：
##   godot --headless --path <项目> --script res://tools/self_check.gd
##   （退出码 0 = 全部通过，1 = 有失败项）
##
## **只碰本程序自己的键**（`HKCU\Software\ReUSTCNet*`），跑完会清理干净，
## 不会动用户的系统代理、系统自启项或任何其他设置。
##
## 这份检查存在的理由：上面每一项都在真实开发中被抓出过 bug ——
## 结尾 NUL 是这里发现的，`"936"` 不是合法的编码名也是先在这里撞到的。

const _REPLACEMENT := "\uFFFD"


func _initialize() -> void:
	var failed := 0
	failed += _check_decode()
	failed += _check_form_encoding()
	failed += _check_secret_round_trip()
	failed += _check_registry_round_trip()
	failed += _check_autostart_helpers()
	print("\n==== 自检结束：%s ====" % ("全部通过" if failed == 0 else "有 %d 项失败" % failed))
	quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- 各项检查

## GB2312 页面解码。用合成的字节（「网络通 IP地址 帐户」），不联网。
##
## 这一项是整个判据链的地基：中文解不出来，`"权限: 国际" in text` 就会静默失效，
## 表现成「网络明明是好的却一直报断网」—— 旧版 Python 实现正是死在这里。
func _check_decode() -> int:
	var page := _page("gb2312", PackedByteArray([
		0xCD, 0xF8, 0xC2, 0xE7, 0xCD, 0xA8, 0x20,
		0x49, 0x50, 0xB5, 0xD8, 0xD6, 0xB7, 0x20,
		0xD5, 0xCA, 0xBB, 0xA7]))
	var text := WltClient.decode_body(page)
	var failed := _report("编码解码（声明 gb2312 的页面）",
			text.contains("网络通") and text.contains("IP地址") and text.contains("帐户")
			and not text.contains(_REPLACEMENT),
			"解出 %s" % text.strip_edges())

	# 站点哪天改成 UTF-8 也得认
	var utf8_text := WltClient.decode_body(_page("utf-8", "网络通 IP地址 帐户".to_utf8_buffer()))
	failed += _report("编码解码（声明 utf-8 的页面）",
			utf8_text.contains("网络通") and not utf8_text.contains(_REPLACEMENT),
			"解出 %s" % utf8_text.strip_edges())

	# wlt 的响应头**不带 charset**；页面里也没有 META 时得自己认出来
	var bare := "网络通 IP地址 帐户".to_utf8_buffer()
	failed += _report("编码解码（没有任何 charset 声明）",
			WltClient.decode_body(bare).contains("网络通"),
			"解出 %s" % WltClient.decode_body(bare).strip_edges())

	# 页面声明 gb2312、实际给的却是 UTF-8 字节：按声明解会得到乱码，得能兜回来
	var lying := _page("gb2312", "网络通 IP地址 帐户".to_utf8_buffer())
	failed += _report("编码解码（声明与实际不符）",
			WltClient.decode_body(lying).contains("网络通"),
			"解出 %s" % WltClient.decode_body(lying).strip_edges())

	# **关键回归**：一段真实的 GB2312 页面片段（含全部中文判据）不能被误判成 UTF-8。
	# decode_body 里「字节是不是合法 UTF-8」这条判据很强，但一旦它对真实的 GB2312 页面
	# 也成立，整条链路就会把页面解成乱码 —— 这一条专门盯住这个风险。
	# 字节由 Python `s.encode("gb2312")` 生成，s 见下面 _REAL_PAGE_TEXT。
	var real := WltClient.decode_body(_page_without_charset(_real_page_gb2312))
	failed += _report("编码解码（真实 GB2312 页面片段不被误判）",
			real.contains("权限: 国际") and real.contains("网络设置成功")
			and not real.contains(_REPLACEMENT),
			"解出 %s" % real.strip_edges())
	return failed


## 一段按 GB2312 编码的真实页面片段，用来盯住「别把 GB2312 误判成 UTF-8」这条回归。
## 内容对应的原文：`<HTML><HEAD><TITLE>网络通</TITLE></HEAD>权限: 国际 网络设置成功
## 密码错误 用户不存在 网络故障 IP地址 拥有的权限`
##
## （用成员变量而不是 `const`：`PackedByteArray(...)` 是构造函数调用，
## GDScript 的常量表达式不接受它。）
var _real_page_gb2312 := PackedByteArray([
	0x3C, 0x48, 0x54, 0x4D, 0x4C, 0x3E, 0x3C, 0x48, 0x45, 0x41, 0x44, 0x3E, 0x3C, 0x54, 0x49, 0x54,
	0x4C, 0x45, 0x3E, 0xCD, 0xF8, 0xC2, 0xE7, 0xCD, 0xA8, 0x3C, 0x2F, 0x54, 0x49, 0x54, 0x4C, 0x45,
	0x3E, 0x3C, 0x2F, 0x48, 0x45, 0x41, 0x44, 0x3E, 0xC8, 0xA8, 0xCF, 0xDE, 0x3A, 0x20, 0xB9, 0xFA,
	0xBC, 0xCA, 0x20, 0xCD, 0xF8, 0xC2, 0xE7, 0xC9, 0xE8, 0xD6, 0xC3, 0xB3, 0xC9, 0xB9, 0xA6, 0x20,
	0xC3, 0xDC, 0xC2, 0xEB, 0xB4, 0xED, 0xCE, 0xF3, 0x20, 0xD3, 0xC3, 0xBB, 0xA7, 0xB2, 0xBB, 0xB4,
	0xE6, 0xD4, 0xDA, 0x20, 0xCD, 0xF8, 0xC2, 0xE7, 0xB9, 0xCA, 0xD5, 0xCF, 0x20, 0x49, 0x50, 0xB5,
	0xD8, 0xD6, 0xB7, 0x20, 0xD3, 0xB5, 0xD3, 0xD0, 0xB5, 0xC4, 0xC8, 0xA8, 0xCF, 0xDE])


## 中文表单参数必须按 **GB2312** 百分号转义，且**不能带结尾的 `%00`**。
##
## `%00` 那条是自检抓出来的真 bug：`String.to_multibyte_char_buffer()` 会带一个结尾 NUL，
## 不清掉的话每个中文参数末尾都会多一个空字节发给服务端。
## 期望值取自 Python `"登录帐户".encode("gb2312")`，不是我手写的。
func _check_form_encoding() -> int:
	var got := WltClient._percent("登录帐户", false)
	var ascii_part := WltClient._percent("a b&c", true)
	return _report("表单编码（中文走 GB2312 且无结尾 NUL）",
			got == "%B5%C7%C2%BC%D5%CA%BB%A7", "得到 %s" % got) \
			+ _report("表单编码（ASCII 与空格）", ascii_part == "a+b%26c", "得到 %s" % ascii_part)


## 密码加解密往返。顺带确认「密文不是明文」。
func _check_secret_round_trip() -> int:
	var plain := "P@ssw0rd-中文密码-12345"
	var cipher := SecretStore.encrypt(plain)
	var back := SecretStore.decrypt(cipher)
	var failed := _report("密码往返（含中文）",
			cipher.begins_with(SecretStore.PREFIX) and not cipher.contains(plain) and back == plain,
			"密文 %d 字符，解回 %s" % [cipher.length(), back])
	failed += _report("密码往返（空值）",
			SecretStore.encrypt("") == "" and SecretStore.decrypt("") == "")
	failed += _report("密码往返（不以 enc: 开头的按明文处理）",
			SecretStore.decrypt("没加密的明文") == "没加密的明文")
	failed += _report("密钥来源可用", SecretStore.key_source() != SecretStore.Source.NONE,
			SecretStore.key_source_text())
	return failed


## 注册表往返：**故意用带空格的键名和带空格/中文的值** ——
## 这两样正是「参数没被正确加引号」时会翻车的地方。
func _check_registry_round_trip() -> int:
	var key := WinRegistry.APP_KEY + " Probe Key"
	var value := "C:\\Program Files\\测试 目录\\app.exe"

	var failed := _report("注册表写入（带空格键名与中文值）",
			WinRegistry.write_string(key, "Path", value))
	var read_back: Dictionary = WinRegistry.read_string(key, "Path")
	failed += _report("注册表读回", bool(read_back["ok"]) and str(read_back["value"]) == value,
			"读回 %s" % str(read_back["value"]))
	failed += _report("注册表存在性判断", WinRegistry.value_exists(key, "Path"))
	failed += _report("注册表删除", WinRegistry.delete_value(key, "Path"))
	failed += _report("删除后存在性判断", not WinRegistry.value_exists(key, "Path"))

	# 清掉探针键本身（删掉值之后键还在）
	WinShell.run("reg.exe", PackedStringArray(["delete", key, "/f"]))
	return failed


## 自启项的读写。**写完立刻还原现场**，不给用户留垃圾。
func _check_autostart_helpers() -> int:
	if not WinSystem.autostart_supported():
		return _report("开机自启（编辑器里运行，跳过）", true, "导出成 exe 后才可用")

	var existed_before := WinSystem.autostart_entry_exists()
	var previous := WinSystem.autostart_value()

	var failed := _report("开机自启写入", WinSystem.enable_autostart())
	failed += _report("开机自启存在性判断", WinSystem.autostart_entry_exists())
	failed += _report("开机自启指向当前程序", not WinSystem.autostart_needs_update(),
			"写入的是 %s" % WinSystem.autostart_value())

	if existed_before and not previous.is_empty():
		WinRegistry.write_string(WinRegistry.RUN_KEY, WinRegistry.AUTOSTART_VALUE, previous)
	else:
		WinSystem.disable_autostart()
	return failed


# ---------------------------------------------------------------- 工具

## 拼一个「声明了 charset=X 的页面」。
static func _page(charset: String, body: PackedByteArray) -> PackedByteArray:
	return _page_without_charset(body, charset)


## 拼一个页面；`charset` 留空就不写 META（模拟「响应头和页面都没声明编码」）。
static func _page_without_charset(body: PackedByteArray, charset := "") -> PackedByteArray:
	if charset.is_empty():
		return body.duplicate()
	var header := "<META http-equiv=\"Content-Type\" content=\"text/html; charset=%s\">\n" % charset
	var out := header.to_utf8_buffer()
	out.append_array(body)
	return out


## 打印一行结果，通过返回 0、失败返回 1（方便调用方累加）。
static func _report(name: String, ok: bool, detail := "") -> int:
	var suffix := "" if detail.is_empty() else "  —— %s" % detail
	print("%s  %s%s" % ["[通过]" if ok else "[失败]", name, suffix])
	return 0 if ok else 1
