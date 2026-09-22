class_name CommandScheduler
extends RefCounted
## 定时执行指令：到点发一次 `triggered`，由界面去弹确认倒计时。
##
## 触发记账的规则（旧版 Python 实现在这里有个语义 bug，这里改掉了）：
##
##   * `last_triggered`（**持久化**，落进配置文件）只在**用户确认执行之后**才写。
##     旧版在弹出对话框之前就把它写死了，于是用户点「取消」也算「今天已触发」，
##     当天再也不会响 —— 与 README 里「执行后…不会重复触发」的说法不符。
##   * 另外还有一份**内存里**的 `_handled_key`：无论用户是执行还是取消，
##     同一分钟内都不再重复弹窗（否则每 0.25 秒就会弹一次）。
##
## 调用约定：收到 `triggered` 的一方**必须**调一次 `resolve()`，否则这一个分钟会一直弹。

signal triggered(key: String)

const TICK := 0.25

var enabled := false
var hour := 23
var minute := 0
## 上次**已执行**的触发时刻，格式 "YYYY-MM-DD HH:MM"。空串 = 今天还没执行过。
var last_triggered := ""

var _host: Node
var _generation := 0
var _handled_key := ""       # 本次进程内已经处理过的分钟（执行或取消都算）


func configure(is_enabled: bool, h: int, m: int, last: String) -> void:
	enabled = is_enabled
	hour = clampi(h, 0, 23)
	minute = clampi(m, 0, 59)
	last_triggered = last


func start(host: Node) -> void:
	if _host != null:
		return
	_host = host
	_generation += 1
	_watch(_generation)


func stop() -> void:
	_generation += 1
	_host = null


## 用户确认执行：记进持久化的 `last_triggered`。
func resolve(key: String, executed: bool) -> void:
	_handled_key = key
	if executed:
		last_triggered = key


## 界面上「重置触发」按钮：清掉持久记录，当天可以再触发一次。
func reset_triggered() -> void:
	last_triggered = ""
	_handled_key = ""


func _watch(gen: int) -> void:
	while _alive(gen):
		var now := _now()
		var key := _minute_key(now)
		if enabled and now["hour"] == hour and now["minute"] == minute \
				and key != _handled_key and key != last_triggered:
			_handled_key = key
			triggered.emit(key)
		await _sleep(TICK, gen)


## 循环条件里**必须带上「宿主还在不在」**，不能只看代号。
##
## 原因：`_sleep()` 在宿主失效时是不 `await` 直接返回的，而 `await` 一个不 yield 的调用
## 会立刻继续往下——只看代号的话这个 while 就会全速空转，进程再也退不出去。
## 宿主失效时 `_alive()` 同时为假，循环自然结束。
func _alive(gen: int) -> bool:
	if gen != _generation or _host == null or not is_instance_valid(_host):
		return false
	return _host.get_tree() != null


func _sleep(seconds: float, gen: int) -> void:
	if not _alive(gen):
		return
	await _host.get_tree().create_timer(seconds).timeout


static func _now() -> Dictionary:
	return Time.get_datetime_dict_from_system()


static func _minute_key(now: Dictionary) -> String:
	return "%04d-%02d-%02d %02d:%02d" % [now["year"], now["month"], now["day"], now["hour"], now["minute"]]
