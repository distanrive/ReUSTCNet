extends Node
## 业务配置（Autoload）。
##
## 存在 `AppShell.config` 这个 ConfigFile 的 `[app]` 段里，与窗口/缩放状态共用一个文件
## （文件位置见 `AppPaths.config_file()`：优先程序目录，写不进去才退到 user://）。
##
## **密码不以明文落盘**：进磁盘时过 `SecretStore.encrypt()`，读出来由它解密，
## 内存里才拿得到明文。密钥从哪来见 `SecretStore` 的说明。

const SEC := "app"
const PASSWORD_PREFIX := "enc:"

## 旧版 Python 程序的配置文件（exe 同级）。首次运行时会自动导入并改名，
## 免得用户升级后所有设置都要重填一遍。
const LEGACY_FILE := "config.json"
const LEGACY_IMPORTED := "config.json.imported"

## 密码明文（只在内存里）。空串 = 没保存密码。
var password := ""

var _data := {}
var _saved_cipher := ""      # 上次落盘的密文，用来避免「没改也重新加密一遍」


func _ready() -> void:
	_load()
	_try_import_legacy()


# ---------------------------------------------------------------- 取值

func get_value(key: String, default: Variant = null) -> Variant:
	if _data.has(key):
		return _data[key]
	return _defaults().get(key, default)


func set_value(key: String, value: Variant) -> void:
	if _data.get(key) == value:
		return
	_data[key] = value


func set_values(values: Dictionary) -> void:
	for k in values:
		set_value(k, values[k])


## 一次性取出 NetMonitor 需要的参数快照。
func monitor_params() -> Dictionary:
	return {
		"username": str(get_value("username")),
		"password": password,
		"export_type": str(get_value("export_type")),
		"fast_interval": int(get_value("fast_retry_interval")),
		"normal_interval": int(get_value("normal_check_interval")),
		"auto_close_proxy": bool(get_value("auto_close_proxy")),
	}


# ---------------------------------------------------------------- 存取

func save() -> void:
	var cfg := AppShell.config
	cfg.set_value(SEC, "username", str(get_value("username")))
	cfg.set_value(SEC, "export_type", str(get_value("export_type")))
	cfg.set_value(SEC, "fast_retry_interval", int(get_value("fast_retry_interval")))
	cfg.set_value(SEC, "normal_check_interval", int(get_value("normal_check_interval")))
	cfg.set_value(SEC, "remember_password", bool(get_value("remember_password")))
	cfg.set_value(SEC, "auto_start_monitor", bool(get_value("auto_start_monitor")))
	cfg.set_value(SEC, "auto_close_proxy", bool(get_value("auto_close_proxy")))
	cfg.set_value(SEC, "auto_command", bool(get_value("auto_command")))
	cfg.set_value(SEC, "command_hour", int(get_value("command_hour")))
	cfg.set_value(SEC, "command_minute", int(get_value("command_minute")))
	cfg.set_value(SEC, "command_countdown", int(get_value("command_countdown")))
	cfg.set_value(SEC, "command_last_triggered", str(get_value("command_last_triggered")))
	cfg.set_value(SEC, "minimize_to_tray", bool(get_value("minimize_to_tray")))
	cfg.set_value(SEC, "password", _cipher_for_disk())
	AppShell.save_config()


# ---------------------------------------------------------------- 内部

func _load() -> void:
	var cfg := AppShell.config
	_data = {}
	for key in _defaults():
		_data[key] = cfg.get_value(SEC, key, _defaults()[key])
	_saved_cipher = str(cfg.get_value(SEC, "password", ""))
	password = SecretStore.decrypt(_saved_cipher)


## 要落盘的密文。**「记住密码」关着就返回空串** —— 密码仍然留在内存里供本次监控使用，
## 只是不写进磁盘。
##
## 另外，密码只在**明文变化时**才重新加密。旧版每次保存都重新 DPAPI 加密一次，
## 同样的密码产生不同的密文，配置文件因此每次写入都变 —— 「配置有没有被改过」
## 用文件哈希就判断不出来了。
func _cipher_for_disk() -> String:
	if password.is_empty() or not bool(get_value("remember_password")):
		_saved_cipher = ""
		return ""
	if not _saved_cipher.is_empty() and SecretStore.decrypt(_saved_cipher) == password:
		return _saved_cipher
	_saved_cipher = SecretStore.encrypt(password)
	return _saved_cipher


static func _defaults() -> Dictionary:
	return {
		"username": "",
		"export_type": "0",
		"fast_retry_interval": 60,
		"normal_check_interval": 900,
		"remember_password": false,
		"auto_start_monitor": false,      # 程序启动后自动开始监控
		"auto_close_proxy": false,
		"auto_command": false,
		"command_hour": 23,
		"command_minute": 0,
		"command_countdown": 30,
		"command_last_triggered": "",
		"minimize_to_tray": true,         # 关闭窗口时隐藏到托盘（监控类工具的合理默认）
	}


## 导入旧版 `config.json`。
##
## 密码导不过来：旧版存的是 Windows DPAPI 密文（绑当前用户账户），GDScript 解不开。
## 所以只搬非密码字段，并明确告诉用户「密码需要重填」—— 静默丢掉比报错更糟。
func _try_import_legacy() -> void:
	var legacy := AppPaths.base_dir().path_join(LEGACY_FILE)
	if not FileAccess.file_exists(legacy):
		return
	var text := FileAccess.get_file_as_string(legacy)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[AppConfig] %s 解析失败，未导入" % legacy)
		return

	var old: Dictionary = parsed
	# 旧版字段名 -> 新字段名。`startup_on_boot` / `auto_shutdown` 那一串是更早版本的叫法，
	# 旧版 Python 自己也会迁移，这里一并认下来。
	set_value("username", str(old.get("username", get_value("username"))))
	set_value("export_type", str(old.get("export_type", get_value("export_type"))))
	set_value("fast_retry_interval", int(old.get("fast_retry_interval", get_value("fast_retry_interval"))))
	set_value("normal_check_interval", int(old.get("normal_check_interval", get_value("normal_check_interval"))))
	set_value("auto_close_proxy", bool(old.get("auto_close_proxy", get_value("auto_close_proxy"))))
	set_value("auto_start_monitor", bool(old.get("auto_start", old.get("startup_on_boot", false))))

	var had_command := old.has("auto_command")
	set_value("auto_command", bool(old.get("auto_command", old.get("auto_shutdown", false))))
	if had_command or old.has("auto_shutdown"):
		set_value("command_hour", int(old.get("command_hour", old.get("shutdown_hour", 23))))
		set_value("command_minute", int(old.get("command_minute", old.get("shutdown_minute", 0))))
		set_value("command_countdown", int(old.get("command_countdown", 30)))
		set_value("command_last_triggered", str(old.get("command_last_triggered", "")))

	save()
	# 改名而不是删除：万一用户还想回头看看里面写了什么
	DirAccess.rename_absolute(legacy, AppPaths.base_dir().path_join(LEGACY_IMPORTED))
	print("[AppConfig] 已从旧版 config.json 导入设置（密码是 DPAPI 密文，解不开，需要重填）")
