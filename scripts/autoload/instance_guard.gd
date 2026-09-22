extends Node
## 单实例 + 「再开一次就把已有窗口叫到前面」（Autoload）。
##
## 用一个只绑 127.0.0.1 的 TCP 端口当锁：**端口占用是内核级的**，没有「先检查再创建」
## 那种竞态（锁文件就有）。旧版 Python 实现用的是 CreateMutexW，功能上没错，
## 但它依赖「CPython 不会自动 CloseHandle 局部变量」这个巧合才成立，而且没法把已有窗口叫出来
## （FindWindowW 靠窗口标题匹配，标题一改就失效）。
##
## 端口被**无关程序**占着时不能冤枉对方，也不能因此拒绝启动，所以逐个端口：
##   listen 成功            → 我是本实例
##   listen 失败、PING 有 PONG → 是本程序的另一个实例 → 请它把窗口叫到前面，自己退出
##   两者都不是              → 换下一个端口；全都不行就记一条警告，
##                            **不做单实例保护照常启动**（宁可少一层保护，也别起不来）

signal raise_requested

const PORTS := [49731, 49732, 49733]
const MAGIC_PING := "REUSTCNET-PING"
const MAGIC_PONG := "REUSTCNET-PONG"
const MAGIC_RAISE := "REUSTCNET-RAISE"

const _PROBE_TIMEOUT_MS := 600

var is_primary := false
var port := 0

## 已经判定「本进程是对外多余的第二个实例、马上就要退出」。
##
## 别的 autoload 靠它避免在这种「活不过几百毫秒」的进程里往配置文件写东西 ——
## 它们的 `_ready()` 都在第 1 帧就跑完了，而这个判断要等 TCP 探测（最多几百毫秒）才有结果，
## 中间那段时间里 `AppShell` 的窗口尺寸防抖落盘可能刚好触发，把**正在运行的**那个实例
## 刚改过的配置覆盖回去。概率很低、后果也有界，但既然能一行挡掉就挡掉。
var quitting_as_secondary := false

var _server: TCPServer
## 已接入但还没读够一行的连接：`[{"peer": StreamPeerTCP, "deadline": int}]`
var _incoming: Array = []


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--no-instance-guard"):
		return
	for p in PORTS:
		if _try_listen(p):
			is_primary = true
			port = p
			set_process(true)
			return
		if await _talk(p, true):
			# 已有实例：已请它到前台，自己退场
			quitting_as_secondary = true
			get_tree().quit()
			return
	push_warning("[InstanceGuard] %s 都被占用且不响应，本次不做单实例保护" % str(PORTS))


func _exit_tree() -> void:
	if _server != null:
		_server.stop()


# ---------------------------------------------------------------- 成为主实例

func _try_listen(p: int) -> bool:
	var server := TCPServer.new()
	if server.listen(p, "127.0.0.1") != OK:
		server.stop()
		return false
	_server = server
	return true


# ---------------------------------------------------------------- 叫醒已有实例

## 连上端口打个招呼，确认对面是**本程序**（会回 PONG）就请它把窗口叫到前面。
## 返回 true 表示「已有实例，请自己退出」。
func _talk(p: int, send_raise: bool) -> bool:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", p) != OK:
		return false

	# **每一步都要先 `poll()`**：文档原话是「Polls the socket, updating its state. See get_status()」——
	# `get_status()` / `get_available_bytes()` 读的都是上一次 poll 缓存的快照，不 poll 就永远停在
	# STATUS_CONNECTING（第一版就是漏了这个，结果第二个实例根本认不出第一个，老老实实跑完了自己的一生）。
	var deadline := Time.get_ticks_msec() + _PROBE_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTING:
			break
		await get_tree().process_frame
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		peer.disconnect_from_host()
		return false

	peer.put_data((MAGIC_PING + "\n").to_utf8_buffer())

	var buffer := ""
	deadline = Time.get_ticks_msec() + _PROBE_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		var available := peer.get_available_bytes()
		if available > 0:
			buffer += peer.get_utf8_string(available)
			if buffer.contains(MAGIC_PONG):
				break
		await get_tree().process_frame
	if not buffer.contains(MAGIC_PONG):
		peer.disconnect_from_host()
		return false

	if send_raise:
		peer.put_data((MAGIC_RAISE + "\n").to_utf8_buffer())
		# 给对面几帧时间把 RAISE 读走 —— 连接一断，没读走的数据就没了
		for _i in 3:
			await get_tree().process_frame
	peer.disconnect_from_host()
	return true


# ---------------------------------------------------------------- 作为服务端

func _process(_delta: float) -> void:
	if not is_primary:
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer != null:
			_incoming.append({"peer": peer, "deadline": Time.get_ticks_msec() + 1000})

	var now := Time.get_ticks_msec()
	var keep: Array = []
	for entry in _incoming:
		var peer: StreamPeerTCP = entry["peer"]
		peer.poll()          # 同 _talk：状态与可用字节都靠 poll 刷新
		var alive := peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
		if alive and peer.get_available_bytes() > 0:
			var line := peer.get_utf8_string(peer.get_available_bytes())
			if line.contains(MAGIC_PING):
				peer.put_data((MAGIC_PONG + "\n").to_utf8_buffer())
			if line.contains(MAGIC_RAISE):
				raise_requested.emit()
		if alive and now < int(entry["deadline"]):
			keep.append(entry)
		else:
			peer.disconnect_from_host()
	_incoming = keep
