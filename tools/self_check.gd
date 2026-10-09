extends SceneTree
## 自检：把「没法靠看界面发现、但一坏就全坏」的平台相关部分逐个验一遍。
##
##   页面解析    从真实页面结构里抠不抠得出本机 IP（隔着标签也要抠得出）
##   编码解码    GB2312 页面能不能解成中文（判据全靠它，错了会静默失效）
##   表单编码    中文参数有没有按 GB2312 出去、有没有多带结尾空字节
##   密码往返    SecretStore 加密→解密能不能还原（含中文密码）
##   注册表往返  带空格的键名 / 带空格与非 ASCII 的值能不能正确读回
##   自启项      WinSystem 建的启动快捷方式能不能用、是否指向当前程序
##   滚动条      宽度是不是还大于 0（为 0 = 整个界面的滚动条都看不见、抓不住）
##   日志控件    LogView 的行数上限裁剪与 BBCode 转义
##   原生窗口    那个 GDExtension 能不能加载、「隐藏」是不是真的生效
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
	failed += _check_extract_ip()
	failed += _check_decode()
	failed += _check_form_encoding()
	failed += _check_session_cookies()
	failed += _check_secret_round_trip()
	failed += _check_log_purge()
	failed += _check_registry_round_trip()
	failed += _check_autostart_helpers()
	failed += await _check_scrollbars()
	failed += _check_log_view()
	failed += await _check_native_window()
	print("\n==== 自检结束：%s ====" % ("全部通过" if failed == 0 else "有 %d 项失败" % failed))
	quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- 各项检查

## 从页面里抠本机 IP。
##
## 这条盯的是一个**移植时丢掉的细节**：真实页面里「IP地址」和值之间**隔着两个标签**——
##     <td width=290 align=right>IP地址</td>
##     <td width=290>114.214.186.54 </td>
## 第一版 `_extract_ip()` 是「从 IP地址 往后扫，撞到 `<` 就认为这行没有 IP」，
## 于是它撞上 `</td>` 立刻返回空串、**永远解不出 IP**（界面上表现为
## 「没能从页面里解析出本机 IP（页面结构可能变了）」）。
## 下面这段就是 2026-10-03 从真站抓下来的原文，别再让它退化。
func _check_extract_ip() -> int:
	var real := "\n\t\t\t<td width=290 align=right>IP地址</td>\n" \
			+ "\t\t\t<td width=290>114.214.186.54 </td>\n" \
			+ "\t\t\t<input type=hidden name=ip value=114.214.186.54>\n"
	var failed := _report("页面解析（标记与值之间隔着标签）",
			WltClient._extract_ip(real) == "114.214.186.54",
			"解出 %s" % WltClient._extract_ip(real))

	# 标签挨着写（旧版 Python 的正则就是按这个形状写的）
	var inline := "<td>IP地址</td><td class=x>10.0.0.7</td>"
	failed += _report("页面解析（紧凑写法）",
			WltClient._extract_ip(inline) == "10.0.0.7", "解出 %s" % WltClient._extract_ip(inline))

	# 没有这个标记就该老实返回空串，别去页面别处乱抓数字
	var absent := "<html><body>网络通</body></html>"
	failed += _report("页面解析（没有 IP地址 标记时返回空串）",
			WltClient._extract_ip(absent) == "", "解出 %s" % WltClient._extract_ip(absent))

	# 标记后面的数字不构成 a.b.c.d 时也别硬凑
	var garbage := "<td>IP地址</td><td>版本 2.5 </td>"
	failed += _report("页面解析（数字不构成 IP 时返回空串）",
			WltClient._extract_ip(garbage) == "", "解出 %s" % WltClient._extract_ip(garbage))
	return failed



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


## 会话 cookie：登录响应里的 `Set-Cookie` 必须被收下、并在后续请求里带回去。
##
## 这一条是 2026-10-03 那次「连不上」的根因回归。站点在登录成功时下发
## `Set-Cookie: rn=<会话号>`（`Path=/cgi-bin`），之后的 `cmd=disp` / `cmd=set`
## **不带它就一律返回登录页** —— HTTP 状态码 200、页面也能正常解码，
## 只有中文判据对不上，最后只表现成一句「出口设置失败：网络通…」
## （`网络通` 是登录页的 `<TITLE>`）。旧版 Python 用 `requests.Session`
## 自动带 cookie，所以这条线索在移植时整个是隐形的。
func _check_session_cookies() -> int:
	var c := WltClient.new()
	c._remember_cookies(PackedStringArray([
		"Date: Sat, 03 Oct 2026 06:55:20 GMT",
		"Set-Cookie: rn=5AF8BF3D5393AB266C5AE5DA354B0BF8511107C9",
		"Content-Type: text/html",
	]))
	var failed := _report("会话 cookie 收下（rn）",
			str(c._cookies.get("rn", "")) == "5AF8BF3D5393AB266C5AE5DA354B0BF8511107C9",
			"得到 %s" % str(c._cookies))
	failed += _report("会话 cookie 带回去",
			c._cookie_header() == "rn=5AF8BF3D5393AB266C5AE5DA354B0BF8511107C9",
			"得到 %s" % c._cookie_header())

	# 属性（Path=…）不属于 cookie 的值；头名大小写不敏感
	c._remember_cookies(PackedStringArray(["set-cookie: SID=abc; Path=/cgi-bin; HttpOnly"]))
	failed += _report("会话 cookie 丢属性、认小写头名",
			c._cookie_header().contains("SID=abc") and not c._cookie_header().contains("Path"),
			"得到 %s" % c._cookie_header())

	# 空值 = 服务端要求删除
	c._remember_cookies(PackedStringArray(["Set-Cookie: SID="]))
	failed += _report("会话 cookie 空值即删除", not c._cookies.has("SID"), "得到 %s" % str(c._cookies))

	# 别的头不能被误收
	var before := c._cookies.size()
	c._remember_cookies(PackedStringArray(["Content-Type: text/html", "X-Set-Cookie: bad=1"]))
	failed += _report("非 Set-Cookie 头不误收", c._cookies.size() == before, "得到 %s" % str(c._cookies))

	c.free()
	return failed


## 过期日志清理：**这个函数会删用户的文件**，只准删超过 `KEEP_DAYS` 天的。
##
## 顺带钉住时区：文件名里是**本地**日期，而 `get_unix_time_from_datetime_string()`
## 按 **UTC** 解，不减掉 bias 的话每个文件都被算早 8 小时，边界那天会提前被删。
func _check_log_purge() -> int:
	var dir := OS.get_cache_dir().path_join("reustcnet_selfcheck_logs")
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))

	var now := int(Time.get_unix_time_from_system())
	var old_name := "log_%s.txt" % _local_date(now - 15 * 86400)
	var fresh_name := "log_%s.txt" % _local_date(now - 13 * 86400)
	for n in [old_name, fresh_name, "not_a_log.txt"]:
		var f := FileAccess.open(dir.path_join(n), FileAccess.WRITE)
		f.store_string("x\n")
		f.close()

	var _store := LogStore.new(dir)      # _init 里就会跑一次清理
	var left := DirAccess.get_files_at(dir)
	var failed := _report("过期日志被删（15 天前）", not left.has(old_name), "剩下 %s" % str(left))
	failed += _report("未过期日志保留（13 天前，KEEP_DAYS=%d）" % LogStore.KEEP_DAYS,
			left.has(fresh_name))
	failed += _report("不匹配命名规则的文件不动", left.has("not_a_log.txt"))

	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	return failed


## 本地日期串（`YYYY-MM-DD`）。**注意 `get_datetime_dict_from_unix_time()` 给的是 UTC**，
## 要自己加时区偏移（bias 的单位是分钟）。
static func _local_date(unix_sec: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(
			unix_sec + int(Time.get_time_zone_from_system().bias) * 60)
	return "%04d-%02d-%02d" % [d.year, d.month, d.day]


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


## 自启快捷方式的读写。**写完立刻还原现场**，不给用户留垃圾。
##
## 这一项验的是「PowerShell 那条命令真的能建出 .lnk，并且指向当前 exe」——
## 拼错一个引号、或者 WScript.Shell 的 ComObject 没建成，界面上的开关就会
## 显示成开着、实际什么都没发生（`enable_autostart()` 认的是文件，不是退出码）。
func _check_autostart_helpers() -> int:
	if not WinSystem.autostart_supported():
		return _report("开机自启（编辑器里运行，跳过）", true, "导出成 exe 后才可用")

	var path := WinSystem.autostart_shortcut_path()
	var existed_before := FileAccess.file_exists(path)

	var failed := _report("开机自启创建快捷方式", WinSystem.enable_autostart(),
			"位置 %s" % path)
	failed += _report("开机自启存在性判断", WinSystem.autostart_entry_exists())
	failed += _report("开机自启指向当前程序", not WinSystem.autostart_needs_update(),
			"快捷方式指向 %s" % WinSystem.autostart_target())
	failed += _report("开机自启关闭后不再存在",
			WinSystem.disable_autostart() and not WinSystem.autostart_entry_exists())

	if existed_before:
		WinSystem.enable_autostart()     # 本来就开着：还原回去
	return failed


# ---------------------------------------------------------------- 界面控件

## 滚动条**必须**有实际宽度。
##
## 这一条钉的是本项目真实踩过的坑：`ThemeFactory._sb()` 的 content_margin 默认是 0，
## 而滚动条的粗细**完全由样式盒的最小尺寸决定** —— 于是整个界面的滚动条都成了
## 贴着右缘的 0 宽细痕（`VScrollBar.get_combined_minimum_size() == (0, 0)`），
## 看不见、抓不住，而且**不报任何错**。改主题时最容易顺手改回去，所以钉在断言里。
func _check_scrollbars() -> int:
	# `--script` 跑的是自己的 SceneTree，autoload 那套不在，主题得显式建一次
	root.theme = ThemeFactory.build()

	var bar := VScrollBar.new()
	root.add_child(bar)
	await process_frame
	var w := bar.get_combined_minimum_size().x
	var failed := _report("竖滚动条有实际宽度",
			w >= ThemePalette.SCROLLBAR_W - 0.01,
			"最小宽度 %.1fpx（0 就是「滚动条消失」那个缺陷）" % w)

	var hbar := HScrollBar.new()
	root.add_child(hbar)
	await process_frame
	var h := hbar.get_combined_minimum_size().y
	failed += _report("横滚动条同理（两个方向共用一条令牌）",
			h >= ThemePalette.SCROLLBAR_W - 0.01, "最小高度 %.1fpx" % h)
	bar.free()
	hbar.free()
	return failed


## 日志控件的裁剪与转义。
##
## 两条都是「错了也不报错、只让日志悄悄不对」的类型：`max_lines` 比 TRIM_CHUNK 小时
## 裁剪算出的保留行数是负数，会把整屏日志一次清空；BBCode 转义漏了的话，
## 消息里的方括号（路径里很常见）会被当成标记，那一行显示就花了。
func _check_log_view() -> int:
	var log_view := LogView.new()
	root.add_child(log_view)
	log_view.append("第一条")
	log_view.append("第二条", "warn")
	log_view.append("路径 [D:/logs/run[3]] 不该被当成 BBCode")
	var failed := _report("日志追加行数", log_view.line_count() == 3,
			"line_count() = %d" % log_view.line_count())
	failed += _report("日志转义方括号",
			log_view.get_lines()[2] == "路径 [D:/logs/run[3]] 不该被当成 BBCode",
			"读回 %s" % log_view.get_lines()[2])
	log_view.clear()
	failed += _report("清空日志", log_view.line_count() == 0)

	# max_lines < TRIM_CHUNK 的边界：曾经会把日志一次清空
	log_view.max_lines = 100
	for i in 500:
		log_view.append("批量 %d" % i)
	var n := log_view.line_count()
	failed += _report("超过行数上限后裁到上限内、且不会一次清空",
			n > 0 and n <= 100 and log_view.get_lines()[n - 1] == "批量 499",
			"500 条之后还剩 %d 行" % n)
	log_view.free()
	return failed


## 原生窗口扩展（`bin/native_window.windows.x86_64.dll`）。
##
## 它干的那件事在 Godot 里没有替代品：把主窗口从任务栏上藏起来
## （为什么必须绕过引擎，见 `tools/native_window/native_window.c` 顶部的长注释）。
##
## 这里验三件事：类在不在、四个方法在不在、以及**隐藏/显示真的生效**。
## 用一个临时窗口验，不动主窗口 —— 免得跑个自检把用户的窗口弄没了。
## headless 下没有窗口系统，整项跳过。
func _check_native_window() -> int:
	if not ClassDB.class_exists(&"NativeWindow"):
		return _report("原生窗口扩展（NativeWindow 类已注册）", false,
				"没注册。是不是忘了编？bash tools/build_native_window.sh，再 --import 一次")

	var names := PackedStringArray()
	for m in ClassDB.class_get_method_list(&"NativeWindow", true):
		names.append(str(m["name"]))
	var missing := PackedStringArray()
	for want in ["hide_window", "show_window", "is_supported", "is_window_visible"]:
		if not names.has(want):
			missing.append(want)
	var failed := _report("原生窗口扩展的方法齐全", missing.is_empty(),
			"缺 %s" % str(missing) if not missing.is_empty() else str(names))
	if failed > 0:
		return failed

	if DisplayServer.get_name() == "headless":
		return _report("原生窗口扩展的隐藏/显示（headless 下没有窗口系统，跳过）", true)

	var probe := Window.new()
	probe.title = "ReUSTCNet self_check"
	probe.size = Vector2i(240, 160)
	root.add_child(probe)
	await process_frame
	await process_frame

	var hwnd := DisplayServer.window_get_native_handle(
			DisplayServer.WINDOW_HANDLE, probe.get_window_id())
	if hwnd == 0:
		probe.queue_free()
		return _report("取得到窗口句柄", false, "window_get_native_handle 返回 0")

	var was_visible := bool(ClassDB.class_call_static(&"NativeWindow", &"is_window_visible", hwnd))
	ClassDB.class_call_static(&"NativeWindow", &"hide_window", hwnd)
	await process_frame
	var now_visible := bool(ClassDB.class_call_static(&"NativeWindow", &"is_window_visible", hwnd))
	ClassDB.class_call_static(&"NativeWindow", &"show_window", hwnd)
	await process_frame
	var back_visible := bool(ClassDB.class_call_static(&"NativeWindow", &"is_window_visible", hwnd))

	failed += _report("hide_window 真的把窗口藏起来了（IsWindowVisible 变假）",
			was_visible and not now_visible,
			"调用前 %s，调用后 %s" % [was_visible, now_visible])
	failed += _report("show_window 能把它叫回来", back_visible, "恢复后 %s" % back_visible)

	probe.queue_free()
	await process_frame
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
