class_name NetMonitor
extends RefCounted
## 网络监控状态机：初始化连接 → 常规检测 ⇄ 断网重连。
##
## 一条主线程上的协程，没有 Thread / Mutex。这样写的直接好处是「停止」立刻生效：
## 旧版 Python 实现把循环放在后台线程里，`stop()` 只置了个标志位，而线程可能正卡在
## `time.sleep(900)` 里 —— 醒来后它**不复查标志**就继续跑检测，发现 session 已被清空，
## 于是走「网络异常」分支真的重新登录了一次。用户点了「停止」，程序却还在后台联网。
##
## 这里每次 `await` 之后第一件事就是核对 `_alive()`：`stop()` 把代号加一，
## 所有旧协程在下一个检查点直接 `return`，不可能再往下走一步。

## 状态种类，界面据此选颜色（StatusDot 的 theme_type_variation / 日志级别）。
enum Kind { IDLE, OK, WARN, ERROR }

enum Phase { IDLE, FAST, NORMAL }

signal status_changed(text: String, kind: int)
signal running_changed(running: bool)

const _SLEEP_STEP := 0.25      # 等待的切片长度：让「停止」最多 0.25 秒就生效

var running := false
var phase := Phase.IDLE

# ---- 给状态卡用的统计 ----
var connected_since := 0.0       # 本次连续在线开始的时间（unix 秒）；0 = 未在线
var last_check_unix := 0.0
var last_check_ok := false
var consecutive_failures := 0    # 连续失败次数（界面据此显示「连续 N 次」，一眼看出是不是线路不稳）
var last_ip := ""                # 最近一次取到的本机 IP（给状态卡显示）

var _generation := 0
var _host: Node                  # 用来取 SceneTree 建计时器
var _client: WltClient
var _params := {}                # 见 set_params()
var _proxy_closed := false


## 参数快照（运行中改参数调这个，下一次循环生效）。
##   username / password / export_type / fast_interval / normal_interval / auto_close_proxy
func set_params(params: Dictionary) -> void:
	_params = params.duplicate()


func start(host: Node, client: WltClient, params: Dictionary) -> void:
	if running:
		return
	_host = host
	_client = client
	set_params(params)
	running = true
	phase = Phase.FAST
	_generation += 1
	running_changed.emit(true)
	_loop(_generation)          # 不 await：跑起来就返回，这是「起一条协程」的写法


func stop() -> void:
	if not running:
		return
	running = false
	phase = Phase.IDLE
	connected_since = 0.0
	_generation += 1            # 旧协程在下一个检查点自杀
	running_changed.emit(false)
	_emit("已停止监控网络连接", Kind.IDLE)


## 本次连续在线的秒数（供状态卡显示「连续运行」）；不在线时返回 0。
func uptime_seconds() -> float:
	if connected_since <= 0.0:
		return 0.0
	return Time.get_unix_time_from_system() - connected_since


# ---------------------------------------------------------------- 主循环

func _loop(gen: int) -> void:
	_emit("正在初始化连接…", Kind.WARN)
	var first := await _reconnect(gen)
	if not _alive(gen):
		return
	if first["ok"]:
		_mark_online()
		phase = Phase.NORMAL
		_emit("已连接 - %s" % _ok_message(), Kind.OK)
	else:
		phase = Phase.FAST
		_emit("初始连接失败：%s" % first["message"], Kind.ERROR)

	# 循环条件里除了代号还要看「宿主还在不在」：`_sleep()` 在宿主失效时不 await 直接返回，
	# 而 await 一个不 yield 的调用会立刻继续 —— 只看代号的话这里会全速空转、进程退不出去。
	while _alive(gen):
		await _sleep(_interval_for_phase(), gen)
		if not _alive(gen):
			return

		last_check_unix = Time.get_unix_time_from_system()
		var r: WltClient.Reply = await _client.check_permission()
		if not _alive(gen):
			return
		last_check_ok = r.online and r.ok

		if last_check_ok:
			var recovered := phase == Phase.FAST
			phase = Phase.NORMAL
			_mark_online()
			if recovered:
				_emit("网络已恢复 - %s" % _ok_message(), Kind.OK)
			else:
				_emit("连接正常 - %s" % _ok_message(), Kind.OK)
			continue

		# ---- 以下都是「确认断网」的路径 ----
		consecutive_failures += 1
		if r.online:
			_emit("网络异常，准备重连", Kind.WARN)
		else:
			_emit("检测失败：%s" % r.message, Kind.WARN)

		_maybe_close_proxy()
		if not _alive(gen):
			return

		var again := await _reconnect(gen)
		if not _alive(gen):
			return
		if again["ok"]:
			_mark_online()
			phase = Phase.NORMAL
			_emit("重连成功 - %s" % _ok_message(), Kind.OK)
		else:
			phase = Phase.FAST
			_emit("重连失败：%s（%d 秒后重试）" % [again["message"], _fast_interval()], Kind.ERROR)


## 完整重连：取 IP → 必要时登录 → 开通出口。返回 `{"ok": bool, "message": String}`。
func _reconnect(gen: int) -> Dictionary:
	var ip_reply: WltClient.Reply = await _client.fetch_ip()
	if not _alive(gen):
		return {"ok": false, "message": "已取消"}
	if not ip_reply.ok:
		return {"ok": false, "message": ip_reply.message}
	var ip := ip_reply.message
	last_ip = ip

	var logged: WltClient.Reply = await _client.is_logged_in()
	if not _alive(gen):
		return {"ok": false, "message": "已取消"}
	if not logged.online:
		return {"ok": false, "message": logged.message}
	if not logged.ok:
		var login := await _client.login(str(_params.get("username", "")),
				str(_params.get("password", "")), ip)
		if not _alive(gen):
			return {"ok": false, "message": "已取消"}
		if not login.ok:
			return {"ok": false, "message": login.message}

	var activated: WltClient.Reply = await _client.activate(str(_params.get("export_type", "0")))
	if not _alive(gen):
		return {"ok": false, "message": "已取消"}
	if not activated.ok:
		return {"ok": false, "message": activated.message}
	return {"ok": true, "message": activated.message}


# ---------------------------------------------------------------- 辅助

## 统一的「已确认联网」出口。**normal 与 fast 两条路径都必须经过这里** ——
## 旧版只在 fast 分支复位了 proxy_closed，于是「一次运行里系统代理只会被关一次」：
## 首次断网关掉之后，标志位一直是 true，之后再断网就再也不关了。
func _mark_online() -> void:
	connected_since = Time.get_unix_time_from_system()
	consecutive_failures = 0
	_proxy_closed = false


func _maybe_close_proxy() -> void:
	if _proxy_closed:
		return
	if not bool(_params.get("auto_close_proxy", false)):
		return
	if WinSystem.disable_system_proxy():
		_proxy_closed = true
		_emit("检测到断网，已关闭系统代理", Kind.WARN)
	else:
		_emit("尝试关闭系统代理失败（注册表写入被拒绝）", Kind.WARN)


func _ok_message() -> String:
	return "当前出口 %s" % WltClient.export_name(str(_params.get("export_type", "")))


func _interval_for_phase() -> float:
	return _fast_interval() if phase == Phase.FAST else _normal_interval()


func _fast_interval() -> float:
	return maxf(float(_params.get("fast_interval", 60)), 5.0)


func _normal_interval() -> float:
	return maxf(float(_params.get("normal_interval", 900)), 5.0)


## 这个协程还能不能继续跑：代号没被换代，且宿主（场景里的节点）还活着。
## 循环条件与每个检查点都用它，别只看代号 —— 理由见 `_sleep()`。
func _alive(gen: int) -> bool:
	if gen != _generation or _host == null or not is_instance_valid(_host):
		return false
	return _host.get_tree() != null


## 把一次等待切成若干小片。
##
## 两个作用：一是「停止」最多 0.25 秒就生效（旧版要等满 900 秒）；
## 二是每次 await 都有界，协程不会挂在某个长期不触发的东西上。
func _sleep(seconds: float, gen: int) -> void:
	if not _alive(gen):
		return
	var tree := _host.get_tree()
	var remaining := seconds
	while remaining > 0.0 and _alive(gen):
		var step := minf(remaining, _SLEEP_STEP)
		await tree.create_timer(step).timeout
		remaining -= step


func _emit(text: String, kind: int) -> void:
	status_changed.emit(text, kind)
