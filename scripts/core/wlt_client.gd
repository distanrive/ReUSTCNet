class_name WltClient
extends Node
## 与 wlt.ustc.edu.cn 的 HTTP 交互：取 IP / 登录 / 开通出口 / 检测状态。
##
## 只做「发请求 + 判断页面」这一件事，不含任何重连策略（那是 NetMonitor 的活）。
##
## **必须挂进场景树**（`HTTPRequest` 是节点）。两种方法都是协程，用 `await` 等结果，
## 不阻塞主线程，也不需要 Thread / Mutex —— 整个监控循环因此可以跑在主线程上。

const BASE_URL := "http://wlt.ustc.edu.cn/cgi-bin/ip"
const TIMEOUT := 6.0

# ---------- 页面判据 ----------
# 中文判据本身是普通字符串比对；**难点在把响应正确解成中文**，见 decode_body()。
# 已实测：请求头是 `Content-Type: text/html`（不带 charset），页面里写着 gb2312。
const MARK_HAS_ACCOUNT := "拥有的权限"   # disp 页面：已登录的标志（比旧版的「用户」硬得多）
const MARK_INTL := "权限: 国际"          # disp 页面：国际出口已开通
const MARK_SET_OK := "网络设置成功"      # cmd=set 的应答
const MARK_BAD_PASSWORD := "密码错误"
const MARK_NO_USER := "用户不存在"
const MARK_NET_FAULT := "网络故障"

## 解码后没解出来的那些字会变成这个字符（U+FFFD）。
const REPLACEMENT := "�"

## 出口编号 → 界面显示名。编号即 `cmd=set` 的 type 参数。
## 顺序与文案沿用旧版（含括号里的官方说明），不要随手改：用户是照着它在网页上对号的。
const EXPORT_TYPES: Array = [
	["0", "1 教育网出口（国际，仅用教育网访问，适合看文献）"],
	["1", "2 电信网出口（国际，到教育网走教育网）"],
	["2", "3 联通网出口（国际，到教育网走教育网）"],
	["3", "4 电信网出口2（国际，到教育网免费地址走教育网）"],
	["4", "5 联通网出口2（国际，到教育网免费地址走教育网）"],
	["5", "6 电信网出口3（国际，默认电信，其他分流）"],
	["6", "7 联通网出口3（国际，默认联通，其他分流）"],
	["7", "8 教育网出口2（国际，默认教育网，其他分流）"],
	["8", "9 移动网出口（国际，无 P2P 或带宽限制）"],
]

## 一次请求的结果。
##   online  这次请求拿到了**可以用的**响应吗（没网/超时/非 2xx = false）
##   ok      业务上成功了吗（由各方法自己按页面判据判定）
class Reply:
	var online := false
	var ok := false
	var code := 0            # HTTP 状态码（仅失败信息里用得到）
	var message := ""
	var text := ""


# ---------------------------------------------------------------- 对外操作

## 读本机 IP（页面表格里的「IP地址」一行）。成功时 `message` 是 IP。
func fetch_ip() -> Reply:
	var r := await _http_get({})
	if not r.online:
		return r
	var ip := _extract_ip(r.text)
	if ip.is_empty():
		# 旧版这里返回「获取IP失败」，但分不清「页面变了」还是「真的没 IP」。
		# 把原因写清楚，省得下次又靠猜。
		r.ok = false
		r.message = "没能从页面里解析出本机 IP（页面结构可能变了）"
		return r
	r.ok = true
	r.message = ip
	return r


## disp 页面（`cmd=disp`）。已登录时页面里会出现「拥有的权限」。
func fetch_status() -> Reply:
	return await _http_get({"cmd": "disp"})


## 是否已登录。判据是「拥有的权限」—— 旧版用的 `"用户" in text` 太宽，
## 登录页本身就有「用户」二字，会把「还在登录页」误判成「已登录」。
func is_logged_in() -> Reply:
	var r := await fetch_status()
	if not r.online:
		return r
	r.ok = r.text.contains(MARK_HAS_ACCOUNT)
	r.message = "已登录" if r.ok else "未登录"
	return r


## 国际出口是否已开通。这是**唯一**用来判断「联网正常」的判据（与旧版一致）。
func check_permission() -> Reply:
	var r := await fetch_status()
	if not r.online:
		return r
	r.ok = r.text.contains(MARK_INTL)
	r.message = "出口正常" if r.ok else "未开通国际出口"
	return r


## 登录。成功判据是页面里出现「拥有的权限」（与 is_logged_in 同一条证据）。
func login(username: String, password: String, ip: String) -> Reply:
	var r := await _http_post({
		"cmd": "login",
		"name": username,
		"password": password,
		"ip": ip,
		"go": "登录帐户",
	})
	if not r.online:
		return r
	if r.text.contains(MARK_BAD_PASSWORD):
		r.message = "密码错误"
	elif r.text.contains(MARK_NO_USER):
		r.message = "用户不存在"
	elif r.text.contains(MARK_NET_FAULT):
		r.message = "网络故障"
	elif r.text.contains(MARK_HAS_ACCOUNT):
		r.ok = true
		r.message = "登录成功"
	else:
		r.message = "登录失败：%s" % _headline(r.text)
	return r


## 开通网络（选出口）。`expire` 参数旧版恒为 "0"（页面上的默认有效期），这里沿用。
func activate(export_type: String) -> Reply:
	var r := await _http_get({
		"cmd": "set",
		"type": export_type,
		"exp": "0",
		"go": " 开通网络 ",
	})
	if not r.online:
		return r
	if r.text.contains(MARK_SET_OK) or r.text.contains(MARK_INTL):
		r.ok = true
		r.message = "出口已开通"
	else:
		r.message = "出口设置失败：%s" % _headline(r.text)
	return r


## 出口编号 → 界面显示名。
static func export_name(value: String) -> String:
	for pair in EXPORT_TYPES:
		if pair[0] == value:
			return pair[1]
	return "未知出口（%s）" % value


## 去掉括号里那段官方说明的短名字（"1 教育网出口（国际，仅用教育网访问，适合看文献）" → "1 教育网出口"）。
##
## 状态卡里必须用短名字：完整名字有 26 个字，`Label` 的最小宽度就是整串文字的宽度，
## 放进 `GridContainer` 会把整个右侧面板的宽度顶出去，窗口装不下就横向溢出。
## 完整名字放进 tooltip，信息不丢。
static func export_short_name(value: String) -> String:
	var full := export_name(value)
	var at := full.find("（")
	return full.substr(0, at).strip_edges() if at > 0 else full


# ---------------------------------------------------------------- HTTP

func _http_get(params: Dictionary) -> Reply:
	var url := BASE_URL
	if not params.is_empty():
		url += "?" + _encode_form(params)
	return await _request(url, HTTPClient.METHOD_GET, "")


func _http_post(fields: Dictionary) -> Reply:
	return await _request(BASE_URL, HTTPClient.METHOD_POST, _encode_form(fields))


func _request(url: String, method: HTTPClient.Method, body: String) -> Reply:
	var reply := Reply.new()
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	add_child(http)          # HTTPRequest 必须在场景树里才能工作

	var headers := PackedStringArray([
		"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
		"Referer: " + BASE_URL,
		"Origin: http://wlt.ustc.edu.cn",
	])
	if method == HTTPClient.METHOD_POST:
		headers.append("Content-Type: application/x-www-form-urlencoded")

	var err := http.request(url, headers, method, body)
	if err != OK:
		# ERR_BUSY 理论上到不了这里（每次请求都用新节点），留个明确的报错总比静默好
		http.queue_free()
		reply.message = "请求未能发出：%s" % error_string(err)
		return reply

	var completed: Array = await http.request_completed
	var result: int = completed[0]
	var code: int = completed[1]
	var raw: PackedByteArray = completed[3]
	http.queue_free()
	reply.code = code

	if result != HTTPRequest.RESULT_SUCCESS:
		reply.message = "网络请求失败：%s" % _result_text(result)
		return reply

	# RESULT_SUCCESS 只表示「请求跑完了」，不代表拿到了页面 —— 404/500 也会走到这里，
	# 而那时 body 是错误页，拿它去比对中文判据只会得到一个误导性的「未开通国际出口」。
	# 所以非 2xx 直接当失败处理，并把状态码写进消息里。
	# （重定向不用担心：HTTPRequest 默认会自己跟最多 8 跳。）
	if code < 200 or code >= 300:
		reply.message = "服务器返回 HTTP %d" % code
		return reply

	reply.online = true
	reply.text = decode_body(raw)
	return reply


static func _result_text(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "连不上服务器（网络不通？）"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "域名解析失败（DNS 不通？）"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "连接被断开"
		HTTPRequest.RESULT_TIMEOUT:
			return "请求超时"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS 握手失败"
		_:
			return "错误码 %d" % result


## 表单编码。**按 GB2312 编码后再做百分号转义** ——
## 这个站点的表单是 GB2312 页面，浏览器提交时发的是 GB2312 字节；
## 旧版 Python 用 requests 发的是 UTF-8 字节（对同一个站点其实是错的编码，
## 只是因为服务端没校验这几个中文字段的取值才没暴露）。
static func _encode_form(fields: Dictionary) -> String:
	var parts := PackedStringArray()
	for key in fields:
		parts.append("%s=%s" % [_percent(str(key), true), _percent(str(fields[key]), false)])
	return "&".join(parts)


static func _percent(text: String, ascii_only: bool) -> String:
	var bytes: PackedByteArray
	if ascii_only:
		bytes = text.to_utf8_buffer()
	else:
		bytes = text.to_multibyte_char_buffer("gb2312")
		if bytes.is_empty() and not text.is_empty():
			bytes = text.to_utf8_buffer()      # 该 API 只在 Windows 上实现，别的平台退回 UTF-8
	bytes = _trim_trailing_nuls(bytes)
	var out := ""
	for b in bytes:
		if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) \
				or (b >= 0x30 and b <= 0x39) \
				or b == 0x2D or b == 0x5F or b == 0x2E or b == 0x7E:
			out += char(b)
		elif b == 0x20:
			out += "+"          # application/x-www-form-urlencoded 里空格就是 +
		else:
			out += "%%%02X" % b
	return out


## 砍掉结尾的 NUL。
##
## `String.to_multibyte_char_buffer()` 转到系统多字节代码页时**会带上结尾的 `\0`**，
## 不清掉的话每个非 ASCII 的表单值末尾都会多出一个 `%00` 发给服务端
## （实测：`"登录帐户"` 会变成 `%B5%C7%C2%BC%D5%CA%BB%A7%00`）。
## 真实的多字节字符串不需要结尾 NUL，所以统一在这里砍掉。
static func _trim_trailing_nuls(bytes: PackedByteArray) -> PackedByteArray:
	var end := bytes.size()
	while end > 0 and bytes[end - 1] == 0:
		end -= 1
	return bytes if end == bytes.size() else bytes.slice(0, end)


# ---------------------------------------------------------------- 解码

## 把响应体解成字符串。
##
## 为什么要这么费劲：响应头是 `Content-Type: text/html`，**不带 charset**，
## 旧版 Python 只能靠 `requests.apparent_encoding` 猜，猜错就整条中文判据静默失效
## （表现为「网络明明是好的却一直报断网」）。
##
## 这里的顺序是：页面自己声明的 charset → 按它选解码器 → 没有声明才两种都试、取替换字符少的。
## 页面的 `<META ... charset=gb2312>` 是权威依据，不用猜。
static func decode_body(raw: PackedByteArray) -> String:
	var data := _maybe_gunzip(raw)
	if data.is_empty():
		return ""
	var declared := _declared_charset(data)

	# 1) 明确声明 UTF-8 的页面。（声明也可能与实际不符，所以还要兜一次）
	if declared.begins_with("utf"):
		return _decode_utf8_with_gb_fallback(data)

	# 2) 字节本身就是**合法的、含多字节字符的 UTF-8** → 就是 UTF-8，不管它声明了什么。
	#    这一步同时兜住「页面没声明 charset」和「声明写错了」两种情况。
	#    为什么这个判据比「数替换字符」可靠：GBK 几乎能接受任意字节对，把 UTF-8 字节喂给
	#    GBK 解出来的东西往往一个替换字符都没有，只是内容全是错字 —— 光看替换字符分辨不出来。
	#    而合法 UTF-8 的字节结构（首字节 + 连续的 10xxxxxx）约束很严，真实的 GB2312
	#    页面基本不可能碰巧满足（wlt 的首页实测按 UTF-8 解会出 244 个替换字符）。
	if _is_utf8_multibyte(data):
		return data.get_string_from_utf8()

	# 3) 声明了 GB 家族 → 按 GB2312 解
	if declared.begins_with("gb") or declared.begins_with("cp936") or declared == "ms936":
		return _decode_gb(data)
	if declared == "ascii" or declared == "us-ascii" or declared.begins_with("iso-8859"):
		return data.get_string_from_ascii()

	# 4) 其余：两种都试，取替换字符少的
	return _pick_better(_decode_gb(data), data.get_string_from_utf8())


static func _decode_utf8_with_gb_fallback(data: PackedByteArray) -> String:
	var utf := data.get_string_from_utf8()
	if not utf.contains(REPLACEMENT):
		return utf
	var gb := _decode_gb(data)
	return gb if not gb.contains(REPLACEMENT) and not gb.is_empty() else utf


## data 是不是**合法的、且含多字节字符**的 UTF-8。
static func _is_utf8_multibyte(data: PackedByteArray) -> bool:
	var i := 0
	var saw_multibyte := false
	while i < data.size():
		var b := data[i]
		var extra := 0
		if b < 0x80:
			extra = 0
		elif b >= 0xC2 and b <= 0xDF:
			extra = 1
		elif b >= 0xE0 and b <= 0xEF:
			extra = 2
		elif b >= 0xF0 and b <= 0xF4:
			extra = 3
		else:
			return false          # 0x80..0xC1、0xF5..0xFF 都不是合法的 UTF-8 首字节
		if extra == 0:
			i += 1
			continue
		if i + extra >= data.size():
			return false
		for k in range(1, extra + 1):
			var c := data[i + k]
			if c < 0x80 or c > 0xBF:
				return false      # 续字节必须是 10xxxxxx
		saw_multibyte = true
		i += extra + 1
	return saw_multibyte


## 按 GB2312 解码。走 Windows 的「系统多字节代码页」接口。
##
## **编码名必须写 "gb2312"**（实测过：`"936"` / `"GBK"` / `"cp936"` 都不认，
## 会返回空串并打一行 `Conversion failed: Unknown encoding`；`"gb2312"` 与 `"gb18030"`
## 可用）。这个 API 只在 Windows 上实现，别的平台返回空串 —— 那时退回 UTF-8。
static func _decode_gb(data: PackedByteArray) -> String:
	var s := data.get_string_from_multibyte_char("gb2312")
	if s.is_empty() and not data.is_empty():
		return data.get_string_from_utf8()
	return s


static func _pick_better(gb: String, utf8: String) -> String:
	return gb if gb.count("�") <= utf8.count("�") else utf8


## 从页面头部（ASCII 区域）里读出声明的 charset。
static func _declared_charset(data: PackedByteArray) -> String:
	var head := data.slice(0, mini(1024, data.size())).get_string_from_ascii().to_lower()
	var at := head.find("charset")
	if at < 0:
		return ""
	at = head.find("=", at)
	if at < 0:
		return ""
	var out := ""
	for i in range(at + 1, head.length()):
		var c := head[i]
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "-" or c == "_":
			out += c
		elif out.is_empty() and (c == "\"" or c == "'" or c == " "):
			continue          # 跳过引号与空格，继续找名字
		else:
			break
	return out


## gzip 嗅探：万一服务端/中间层压缩了响应，先解开再解码。
static func _maybe_gunzip(raw: PackedByteArray) -> PackedByteArray:
	if raw.size() < 2 or raw[0] != 0x1F or raw[1] != 0x8B:
		return raw
	var out := raw.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	return out if not out.is_empty() else raw


# ---------------------------------------------------------------- 页面解析

## 抓 `IP地址</td><td>1.2.3.4</td>` 里的 IP。
## 旧版用的是同一条正则；这里改成手工扫描，因为 GDScript 的字符串里写正则要多一层转义，
## 而这条判据本来就只是「找到 IP地址 之后第一串数字和点」。
static func _extract_ip(html: String) -> String:
	var at := html.find("IP地址")
	if at < 0:
		return ""
	var i := at
	while i < html.length():
		var c := html[i]
		if (c >= "0" and c <= "9") or c == ".":
			var ip := ""
			while i < html.length():
				var d := html[i]
				if (d >= "0" and d <= "9") or d == ".":
					ip += d
					i += 1
				else:
					break
			# 只接受形如 a.b.c.d 且每段都非空的串
			var parts := ip.split(".")
			if parts.size() == 4 and not parts[0].is_empty() and not parts[3].is_empty():
				return ip
			return ""
		if c == "<":
			return ""        # 撞到标签了，说明这一行里没有 IP
		i += 1
	return ""


## 把 HTML 摘要成一行，用来当失败信息 —— 旧版直接把 50 个字符的 HTML 塞进日志，
## 里面带换行和标签，一条错误摊成好几行，时间戳也对不上。
static func _headline(html: String) -> String:
	var text := ""
	var in_tag := false
	for i in html.length():
		var c := html[i]
		if c == "<":
			in_tag = true
		elif c == ">":
			in_tag = false
			text += " "
		elif not in_tag:
			text += c
		if text.length() >= 80:
			break
	text = text.strip_edges().replace("\n", " ").replace("\r", " ").replace("  ", " ")
	return text if not text.is_empty() else "（页面无文字内容）"
