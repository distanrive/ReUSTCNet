class_name LogStore
extends RefCounted
## 日志落盘：按天一个文件，单文件超过上限就轮转，并清理过期文件。
##
## 旧版 Python 实现是「按天无限追加」，跑久了单文件能到几十 MB 且从不清理；
## 这里补上轮转与清理。界面上的日志用的是另一份内存缓冲（见 app.gd），本类只管落盘。

const MAX_BYTES := 2 * 1024 * 1024   # 单文件上限，超了就轮转成 .1
const KEEP_DAYS := 14                # 保留多少天

var _dir := ""
var _today := ""
var _path := ""
var _size := -1


func _init(dir_path: String) -> void:
	_dir = dir_path
	AppPaths.ensure_dir(_dir)
	_purge_old()
	_roll_if_needed()


## 追加一行（自动加 `[HH:MM:SS] ` 前缀）。消息里的换行会被压成空格 ——
## 旧版把带换行的 HTML 片段直接写进日志，一条错误摊成好几行、时间戳也对不上。
func append(message: String) -> void:
	_roll_if_needed()
	var line := "[%s] %s\n" % [_now_hms(), message.replace("\n", " ").replace("\r", " ")]
	# 注意 `READ_WRITE` **不会创建文件**（只有 `WRITE` 会），拿它开一个还不存在的日志文件
	# 会返回 null —— 那样「今天的第一条日志」就被静默丢掉了。所以分两种开法。
	var f: FileAccess
	if FileAccess.file_exists(_path):
		f = FileAccess.open(_path, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		return                       # 日志写不进去不该影响主流程，静默跳过
	f.store_string(line)
	_size += line.to_utf8_buffer().size()
	f.close()


func dir_path() -> String:
	return _dir


# ---------------------------------------------------------------- 内部

static func _now_hms() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%02d:%02d:%02d" % [d["hour"], d["minute"], d["second"]]


static func _today_stamp() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d" % [d["year"], d["month"], d["day"]]


## 日期变了换新文件；文件超限就先把它挪成 .1 再开新的（只留一代备份）。
func _roll_if_needed() -> void:
	var today := _today_stamp()
	if today != _today:
		_today = today
		_path = _dir.path_join("log_%s.txt" % today)
		_size = _file_size(_path)
	if _size > MAX_BYTES:
		var backup := _dir.path_join("log_%s.1.txt" % _today)
		DirAccess.remove_absolute(backup)
		DirAccess.rename_absolute(_path, backup)
		_size = 0


static func _file_size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n


## 删掉超过 KEEP_DAYS 天的 `log_YYYY-MM-DD*.txt`。
func _purge_old() -> void:
	var dir := DirAccess.open(_dir)
	if dir == null:
		return
	var cutoff := Time.get_unix_time_from_system() - KEEP_DAYS * 86400.0
	# 文件名里是**本地**日期，而 `get_unix_time_from_datetime_string()` 把字符串按 **UTC** 解
	# （实测：`"2026-10-03T00:00:00"` 解出来正是 UTC 的那一秒）。不减掉时区偏移的话，
	# 每个文件都会被当成早 8 小时 —— 到期的那个会提前 8 小时被删掉。
	var bias := int(Time.get_time_zone_from_system().bias)
	for name in dir.get_files():
		if not name.begins_with("log_") or not name.ends_with(".txt"):
			continue
		# 从文件名里取前 10 个字符（YYYY-MM-DD）当日期；取不到就跳过，不猜
		var stamp := name.substr(4, 10)
		var unix := int(Time.get_unix_time_from_datetime_string(stamp + "T00:00:00")) - bias * 60
		if unix <= 0.0:
			continue
		if unix < cutoff:
			DirAccess.remove_absolute(_dir.path_join(name))
