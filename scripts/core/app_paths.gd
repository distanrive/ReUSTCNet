class_name AppPaths
extends RefCounted
## 路径解析：程序目录、可写目录、配置文件、日志目录、command.bat。
##
## 为什么需要它：导出成 exe 之后「程序目录」不再等于 `res://`，而用户又习惯把
## 配置放在 exe 旁边（绿色版）。于是这里做一次探测：
##
##   base_dir  程序所在目录 —— 导出后是 exe 所在目录，开发期是工程目录
##   data_dir  实际可写的目录 —— 优先 base_dir；写不进去才退到 user:// 的实体路径
##
## 所有路径统一用 Godot 的 "/" 分隔形式（FileAccess / DirAccess 在 Windows 上同样接受）。
## 结果只算一次并缓存 —— 启动时探测过就不该再变，中途换目录会让「日志写哪去了」变成玄学。

static var _resolved := false
static var _base_dir := ""
static var _data_dir := ""
static var _portable := false


## 程序所在目录。导出后 = exe 目录；开发期 = 工程目录。
static func base_dir() -> String:
	_resolve()
	return _base_dir


## 实际可写的目录。正常情况等于 `base_dir()`（绿色版）；受保护目录下回退到
## `%APPDATA%\Godot\app_userdata\<工程名>\`。
static func data_dir() -> String:
	_resolve()
	return _data_dir


## 配置是否落在程序旁边（true = 绿色版；false = 已回退到用户数据目录）。
## 界面要把这件事说清楚，用户才知道该去哪儿找配置文件。
static func is_portable() -> bool:
	_resolve()
	return _portable


## 业务配置文件（AppShell 与 AppConfig 共用同一个文件，各分自己的段）。
static func config_file() -> String:
	return data_dir().path_join("config.cfg")


## 日志目录（调用前不必自己建，`LogStore` 会 make_dir_recursive）。
static func log_dir() -> String:
	return data_dir().path_join("logs")


## 密码密钥的降级存放位置（只在注册表不可写时用，见 SecretStore）。
static func fallback_key_file() -> String:
	return data_dir().path_join(".key")


## 定时执行指令的批处理文件：优先程序目录（README 里就是这么写的），
## 其次可写目录 —— 回退到 user:// 时两个位置并不相同。
## 返回第一个**存在**的路径；都不存在时返回程序目录下的路径（供报错信息使用）。
static func command_bat() -> String:
	var in_base := base_dir().path_join("command.bat")
	if FileAccess.file_exists(in_base):
		return in_base
	var in_data := data_dir().path_join("command.bat")
	if in_data != in_base and FileAccess.file_exists(in_data):
		return in_data
	return in_base


## 建目录（幂等）。返回是否成功。
static func ensure_dir(path: String) -> bool:
	if DirAccess.dir_exists_absolute(path):
		return true
	return DirAccess.make_dir_recursive_absolute(path) == OK


## 在系统文件资源管理器里打开某个目录（不阻塞主线程）。
static func open_in_explorer(path: String) -> void:
	# explorer 只认反斜杠路径；路径里的引号会破坏参数，但 Windows 路径不允许引号，可以不管。
	var native := path.replace("/", "\\")
	OS.create_process("explorer.exe", [native])


# ---------------------------------------------------------------- 内部

static func _resolve() -> void:
	if _resolved:
		return
	_resolved = true

	if OS.has_feature("editor"):
		# 开发期：工程目录（globalize_path 会带上末尾斜杠，去掉以免 path_join 出双斜杠）
		_base_dir = ProjectSettings.globalize_path("res://").trim_suffix("/")
	else:
		_base_dir = OS.get_executable_path().get_base_dir()

	_data_dir = _base_dir
	_portable = _probe_writable(_base_dir)
	if not _portable:
		_data_dir = OS.get_user_data_dir().trim_suffix("/")
		push_warning("[AppPaths] %s 不可写，配置与日志改用 %s" % [_base_dir, _data_dir])


## 试写一个临时文件来判断目录可写。
##
## 注意：不可写时 `FileAccess.open()` 会自己往控制台打一行 ERROR —— 那行是**预期内**的，
## 紧随其后的 `[AppPaths] ... 不可写` 才是结论。别看到 ERROR 就以为出了别的故障。
static func _probe_writable(dir: String) -> bool:
	var probe := dir.path_join(".wlt_write_probe")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string("probe")
	f.close()
	DirAccess.remove_absolute(probe)
	return true
