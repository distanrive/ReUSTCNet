extends Control
## 主界面。
##
## 这一层只做三件事：**建界面**、**把控件与 AppConfig 对齐**、**把界面接到核心逻辑的信号上**。
## 网络与状态机在 `scripts/core/`（纯逻辑，不引用任何 UI），样式在 `scripts/theme/`。
##
## 两条约定（与 CLAUDE.md 一致）：
##   * 字号/颜色一律走 `theme_type_variation`，不在这里 `add_theme_*_override`；
##   * 网络请求只经 `WltClient`，重连策略只经 `NetMonitor`，这里不自己拼 URL。

const APP_TITLE := "ReUSTCNet 有线网登录重连器"

enum LogLevel { INFO, OK, WARN, ERROR }

const _LOG_MAX_PARAGRAPHS := 2000

# 托盘菜单项的 id（分隔线也占 id，这样用 get_item_index 反查下标，不怕以后挪动顺序）
const _TRAY_SHOW := 0
const _TRAY_START := 1
const _TRAY_STOP := 2
const _TRAY_QUIT := 3
const _TRAY_SEP_A := 90
const _TRAY_SEP_B := 91

var _client: WltClient
var _monitor: NetMonitor
var _scheduler: CommandScheduler
var _log_store: LogStore

# ---- 头部与状态卡 ----
var _dot: StatusDot
var _card_dot: StatusDot
var _status_text: FlashLabel
var _card_status: Label
var _v_export: Label
var _v_ip: Label
var _v_uptime: Label
var _v_last_check: Label
var _start_btn: Button
var _stop_btn: Button
var _hide_btn: Button

# ---- 设置 ----
var _username: LabeledLineEdit
var _password: LabeledLineEdit
var _remember: Switch
var _export_option: OptionButton
var _normal_spin: SpinBox
var _fast_spin: SpinBox
var _proxy_switch: Switch
var _command_switch: Switch
var _hour_spin: SpinBox
var _minute_spin: SpinBox
var _countdown_spin: SpinBox
var _autostart_switch: Switch
var _auto_monitor_switch: Switch
var _tray_switch: Switch
var _scale_option: UiScaleOption

var _log_view: RichTextLabel

var _tray_available := false
var _tray: StatusIndicator
var _tray_menu: PopupMenu

var _save_timer: Timer
var _ui_timer: Timer
var _alert_dialog: AcceptDialog
var _cd_dialog: Window
var _cd_ring: CircularProgressBar
var _cd_number: Label
var _cd_timer: Timer
var _cd_remaining := 0
var _cd_total := 0
var _cd_key := ""


func _ready() -> void:
	# 关闭窗口要不要真的退出，由 _on_close_requested() 按界面上的选项决定
	get_tree().auto_accept_quit = false

	_log_store = LogStore.new(AppPaths.log_dir())
	_client = WltClient.new()
	_client.name = "WltClient"
	add_child(_client)
	_monitor = NetMonitor.new()
	_scheduler = CommandScheduler.new()

	# 先探测托盘能力：_build_ui() 里要根据它决定「关闭窗口时」那一项是否可用
	_tray_available = DisplayServer.has_feature(DisplayServer.FEATURE_STATUS_INDICATOR)

	_build_ui()
	_install_tray()
	_make_timers()
	_load_into_ui()          # 必须在 _connect_signals() 之前：设置控件的初值会触发 value_changed
	_connect_signals()

	_log_startup_info()
	AppShell.set_window_title(APP_TITLE)

	if bool(AppConfig.get_value("auto_start_monitor")) and _has_credentials():
		_start_monitoring()


# ================================================================ 界面构建

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)
	margin.add_child(page)

	page.add_child(_build_header())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(body)

	body.add_child(_build_sidebar())
	body.add_child(_build_main_area())


func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	header.add_child(_label(APP_TITLE, "PageTitle"))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_dot = StatusDot.new()
	_dot.set_status("StatusIdle")
	header.add_child(_vcenter(_dot))

	_status_text = FlashLabel.new()
	_status_text.text = "未启动"
	_status_text.theme_type_variation = "StatusIdle"
	_status_text.interval = 0.7
	_status_text.min_alpha = 0.3      # 柔和脉冲：报警但不刺眼
	# 头部只放**短状态**（「已连接」「重连中」这种），整句话进日志 —— 见 _on_status_changed。
	# 定一个最小宽度是为了让右边的按钮不随状态字数变化来回跳。
	_status_text.custom_minimum_size.x = 96
	header.add_child(_vcenter(_status_text))

	_start_btn = _button("启动", "AccentButton", _start_monitoring)
	_stop_btn = _button("停止", "DangerButton", _stop_monitoring)
	_stop_btn.disabled = true
	header.add_child(_start_btn)
	header.add_child(_stop_btn)

	_hide_btn = _button("隐藏到托盘", "GhostButton", _hide_to_tray)
	_hide_btn.visible = _tray_available
	header.add_child(_hide_btn)
	return header


func _build_sidebar() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(ThemePalette.SIDEBAR_W, 0)
	# 必须关掉横向滚动，否则里面的卡片会按「内容想要的宽度」撑开、顶出窗口
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 12)
	scroll.add_child(side)

	side.add_child(_build_account_card())
	side.add_child(_build_network_card())
	side.add_child(_build_command_card())
	side.add_child(_build_startup_card())
	return scroll


func _build_account_card() -> Control:
	var card := TitledGroup.new()
	card.title = "账户"

	_username = LabeledLineEdit.new()
	_username.label_text = "账号"
	_username.label_width = ThemePalette.ROW_LABEL_W
	_username.line_edit.placeholder_text = "校园网账号"
	card.content.add_child(_username)

	_password = LabeledLineEdit.new()
	_password.label_text = "密码"
	_password.label_width = ThemePalette.ROW_LABEL_W
	_password.line_edit.secret = true
	_password.line_edit.placeholder_text = "校园网密码"
	card.content.add_child(_password)

	_remember = Switch.new()
	card.content.add_child(_switch_row("记住密码", _remember,
			"勾选后密码会加密写进配置文件；不勾选则只在本次运行期间保留。"))

	card.content.add_child(_button("清除已保存的密码", "GhostButton", _clear_password))
	return card


func _build_network_card() -> Control:
	var card := TitledGroup.new()
	card.title = "网络"

	# 出口名很长（官方原文），单独占一行铺满卡片宽度，比挤在标签右边好读
	_export_option = OptionButton.new()
	for pair in WltClient.EXPORT_TYPES:
		_export_option.add_item(pair[1])
	_export_option.tooltip_text = "登录后要开通的出口；编号与校园网页面上的下拉框一致。"
	card.content.add_child(_stacked("出口", _export_option))

	_normal_spin = _spin(5, 86400, " 秒")
	_normal_spin.tooltip_text = "联网正常时多久检查一次。"
	card.content.add_child(_row("常规检测", _normal_spin))

	_fast_spin = _spin(5, 3600, " 秒")
	_fast_spin.tooltip_text = "检测到断网后多久重试一次。"
	card.content.add_child(_row("断网重试", _fast_spin))

	_proxy_switch = Switch.new()
	card.content.add_child(_switch_row("断网时关闭系统代理", _proxy_switch,
			"检测到断网时把 Windows 系统代理开关置 0（保留代理地址）。联网后不会自动恢复。"))
	return card


func _build_command_card() -> Control:
	var card := TitledGroup.new()
	card.title = "定时执行指令"

	_command_switch = Switch.new()
	card.content.add_child(_switch_row("启用", _command_switch,
			"到点弹出确认倒计时；倒计时结束后执行程序目录下的 command.bat。"))

	_hour_spin = _spin(0, 23, " 时")
	_minute_spin = _spin(0, 59, " 分")
	_hour_spin.custom_minimum_size.x = 78
	_minute_spin.custom_minimum_size.x = 78
	var time_row := HBoxContainer.new()
	time_row.add_child(_vcenter(_row_label("运行时间")))
	time_row.add_child(_vcenter(_hour_spin))
	time_row.add_child(_vcenter(_minute_spin))
	card.content.add_child(time_row)

	_countdown_spin = _spin(1, 3600, " 秒")
	_countdown_spin.tooltip_text = "执行前留给你取消的时间。"
	card.content.add_child(_row("确认倒计时", _countdown_spin))

	var reset := _button("重置触发状态", "GhostButton", _reset_command_triggered)
	reset.tooltip_text = "清掉「今天已经执行过」的记录，当天可以再触发一次。"
	card.content.add_child(reset)

	var hint := _label("指令内容写在程序目录下的 command.bat 里。", "Caption")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card.content.add_child(hint)
	return card


func _build_startup_card() -> Control:
	var card := TitledGroup.new()
	card.title = "启动与外观"

	_auto_monitor_switch = Switch.new()
	card.content.add_child(_switch_row("启动后自动监控", _auto_monitor_switch,
			"程序一启动（含开机自启）就自动开始监控。"))

	_autostart_switch = Switch.new()
	card.content.add_child(_switch_row("开机自启", _autostart_switch,
			"在注册表 HKCU\\...\\Run 里加一项，登录 Windows 后自动运行本程序。"))
	# 开发期写进注册表的会是 Godot 编辑器本身，没有意义，直接禁掉（见 WinSystem 的说明）
	if not WinSystem.autostart_supported():
		_autostart_switch.disabled = true

	var tray_label := "关窗时进托盘" if _tray_available else "关窗时最小化"
	_tray_switch = Switch.new()
	card.content.add_child(_switch_row(tray_label, _tray_switch,
			"开：点关闭按钮只是隐藏窗口，监控继续跑，退出要从托盘菜单走。\n"
			+ "关：点关闭按钮直接退出程序（监控一起停）。"))
	if not _tray_available:
		_tray_switch.disabled = true

	_scale_option = UiScaleOption.new()
	card.content.add_child(_row("界面缩放", _scale_option))
	return card


func _build_main_area() -> Control:
	var main := VBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 12)
	main.add_child(_build_status_card())
	main.add_child(_build_log_card())
	return main


func _build_status_card() -> Control:
	var card := TitledGroup.new()
	card.title = "运行状态"

	var grid := GridContainer.new()
	grid.columns = 2

	# 「连接状态」这一行的值不是纯文字，而是「状态点 + 状态文字」，与头部保持一致
	_card_dot = StatusDot.new()
	_card_dot.set_status("StatusIdle")
	_card_status = _label("未启动", "StatusIdle")
	var status_line := HBoxContainer.new()
	status_line.add_theme_constant_override("separation", 6)
	status_line.add_child(_vcenter(_card_dot))
	status_line.add_child(_vcenter(_card_status))

	_v_export = _label("—", "ValueText")
	_v_ip = _label("—", "ValueText")
	_v_uptime = _label("—", "ValueText")
	_v_last_check = _label("—", "ValueText")

	for pair in [
		["连接状态", status_line], ["目标出口", _v_export], ["本机 IP", _v_ip],
		["连续运行", _v_uptime], ["最后检测", _v_last_check],
	]:
		grid.add_child(_vcenter(_grid_label(pair[0])))
		grid.add_child(_vcenter(pair[1]))
	card.content.add_child(grid)
	return card


func _build_log_card() -> Control:
	var card := TitledGroup.new()
	card.title = "运行日志"
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)
	toolbar.add_child(_button("清空", "GhostButton", _clear_log))
	# 日志目录不摆在界面上：路径是一整串没有空格的文字，`Label` 的最小宽度就是它整串的宽度，
	# 放进这一行会把整个右侧面板的最低宽度顶大，窗口装不下就横向溢出。
	# 放进 tooltip + 启动时写一行日志，信息一样查得到。
	var open_dir := _button("打开日志目录", "GhostButton", _open_log_dir)
	open_dir.tooltip_text = "日志目录：\n%s" % _log_store.dir_path()
	toolbar.add_child(open_dir)
	card.content.add_child(toolbar)

	_log_view = RichTextLabel.new()
	_log_view.theme_type_variation = "LogView"
	_log_view.bbcode_enabled = true
	_log_view.scroll_following = true
	_log_view.selection_enabled = true
	_log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_view.custom_minimum_size = Vector2(0, ThemePalette.LOG_MIN_H)
	card.content.add_child(_log_view)
	return card


# ================================================================ 小部件工厂

func _label(text: String, variation := "") -> Label:
	var l := Label.new()
	l.text = text
	if not variation.is_empty():
		l.theme_type_variation = variation
	return l


## 让控件在行内垂直居中。行高由最高的那个子项决定，不这样设的话矮的会贴顶。
func _vcenter(control: Control) -> Control:
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return control


func _button(text: String, variation: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	if not variation.is_empty():
		b.theme_type_variation = variation
	b.pressed.connect(handler)
	return b


func _spin(min_value: int, max_value: int, suffix: String) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_value
	s.max_value = max_value
	s.step = 1
	s.suffix = suffix
	s.allow_greater = false
	s.allow_lesser = false
	s.custom_minimum_size.x = 118
	return s


## 一行「标签 + 可伸缩控件」，标签列宽全卡片统一（见 ThemePalette.ROW_LABEL_W）。
func _row(text: String, content: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_child(_vcenter(_row_label(text)))
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_vcenter(content))
	return row


## 一行「标签 + 开关」。开关紧跟标签（而不是被推到最右），
## 这样各行的圆钮落在同一列上，扫一眼就能看出一排状态。
func _switch_row(text: String, sw: Switch, tooltip := "") -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_child(_vcenter(_row_label(text)))
	row.add_child(_vcenter(sw))
	if not tooltip.is_empty():
		row.tooltip_text = tooltip
	return row


## 标签在上、控件在下铺满整行。给「选项文字很长」的场合用（比如出口列表）。
func _stacked(text: String, content: Control) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_label(text))
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(content)
	return box


func _row_label(text: String) -> Label:
	var l := _label(text)
	l.custom_minimum_size.x = ThemePalette.ROW_LABEL_W
	return l


func _grid_label(text: String) -> Label:
	var l := _label(text, "Subtitle")
	l.custom_minimum_size.x = 84
	return l


# ================================================================ 托盘

func _install_tray() -> void:
	if not _tray_available:
		return

	_tray_menu = PopupMenu.new()
	_tray_menu.name = "TrayMenu"
	_tray_menu.add_item("显示主界面", _TRAY_SHOW)
	_tray_menu.add_separator("", _TRAY_SEP_A)
	_tray_menu.add_item("启动监控", _TRAY_START)
	_tray_menu.add_item("停止监控", _TRAY_STOP)
	_tray_menu.add_separator("", _TRAY_SEP_B)
	_tray_menu.add_item("退出", _TRAY_QUIT)
	_tray_menu.id_pressed.connect(_on_tray_menu)
	add_child(_tray_menu)

	_tray = StatusIndicator.new()
	_tray.name = "Tray"
	_tray.icon = load("res://themes/icons/app.svg")
	_tray.tooltip = APP_TITLE
	_tray.pressed.connect(_on_tray_pressed)
	add_child(_tray)
	# menu 是个 NodePath，得等菜单进了场景树才拿得到路径
	_tray.menu = _tray_menu.get_path()

	_tray_set_disabled(_TRAY_START, false)
	_tray_set_disabled(_TRAY_STOP, true)


func _tray_set_disabled(id: int, disabled: bool) -> void:
	if _tray_menu == null:
		return
	# 按 id 反查下标：菜单里有分隔线，id 与下标并不相等
	var index := _tray_menu.get_item_index(id)
	if index >= 0:
		_tray_menu.set_item_disabled(index, disabled)


func _on_tray_pressed(_mouse_button: int, _position: Vector2i) -> void:
	_show_window()


func _on_tray_menu(id: int) -> void:
	match id:
		_TRAY_SHOW:
			_show_window()
		_TRAY_START:
			_start_monitoring()
		_TRAY_STOP:
			_stop_monitoring()
		_TRAY_QUIT:
			_quit()


# ================================================================ 定时器

func _make_timers() -> void:
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.6      # 输入框每敲一个字就写一次配置太浪费，防抖一下
	_save_timer.timeout.connect(_commit_settings)
	add_child(_save_timer)

	_ui_timer = Timer.new()
	_ui_timer.wait_time = 1.0
	_ui_timer.timeout.connect(_refresh_runtime)
	add_child(_ui_timer)
	_ui_timer.start()


func _connect_signals() -> void:
	_monitor.status_changed.connect(_on_status_changed)
	_monitor.running_changed.connect(_on_running_changed)
	_scheduler.triggered.connect(_on_command_triggered)
	InstanceGuard.raise_requested.connect(_show_window)

	for control in [_username.line_edit, _password.line_edit]:
		control.text_changed.connect(_on_setting_edited)
	for control in [_remember, _proxy_switch, _command_switch, _auto_monitor_switch, _tray_switch]:
		control.toggled.connect(_on_setting_edited)
	for control in [_normal_spin, _fast_spin, _hour_spin, _minute_spin, _countdown_spin]:
		control.value_changed.connect(_on_setting_edited)
	_export_option.item_selected.connect(_on_setting_edited)
	_autostart_switch.toggled.connect(_on_autostart_toggled)


# ================================================================ 配置 ←→ 界面

## 把配置灌进控件。**必须在 `_connect_signals()` 之前调用** ——
## 给 `SpinBox.value` 赋值会发出 `value_changed`，先连信号的话这里会反过来触发一次保存。
func _load_into_ui() -> void:
	_username.text = str(AppConfig.get_value("username"))
	_password.text = AppConfig.password
	_remember.set_pressed_no_signal(bool(AppConfig.get_value("remember_password")))
	_proxy_switch.set_pressed_no_signal(bool(AppConfig.get_value("auto_close_proxy")))
	_auto_monitor_switch.set_pressed_no_signal(bool(AppConfig.get_value("auto_start_monitor")))
	_tray_switch.set_pressed_no_signal(bool(AppConfig.get_value("minimize_to_tray")))
	_command_switch.set_pressed_no_signal(bool(AppConfig.get_value("auto_command")))

	_normal_spin.value = int(AppConfig.get_value("normal_check_interval"))
	_fast_spin.value = int(AppConfig.get_value("fast_retry_interval"))
	_hour_spin.value = int(AppConfig.get_value("command_hour"))
	_minute_spin.value = int(AppConfig.get_value("command_minute"))
	_countdown_spin.value = int(AppConfig.get_value("command_countdown"))

	var export_value := str(AppConfig.get_value("export_type"))
	for i in WltClient.EXPORT_TYPES.size():
		if WltClient.EXPORT_TYPES[i][0] == export_value:
			_export_option.select(i)
			break

	_autostart_switch.set_pressed_no_signal(WinSystem.autostart_entry_exists())
	_push_scheduler_config()
	_refresh_v_export()


func _on_setting_edited(_unused: Variant = null) -> void:
	_save_timer.start()


## 把界面上的值收回 AppConfig（只收，不落盘）。
func _collect() -> void:
	AppConfig.password = _password.text
	AppConfig.set_values({
		"username": _username.text.strip_edges(),
		"remember_password": _remember.is_pressed(),
		"export_type": _selected_export(),
		"fast_retry_interval": int(_fast_spin.value),
		"normal_check_interval": int(_normal_spin.value),
		"auto_close_proxy": _proxy_switch.is_pressed(),
		"auto_command": _command_switch.is_pressed(),
		"command_hour": int(_hour_spin.value),
		"command_minute": int(_minute_spin.value),
		"command_countdown": int(_countdown_spin.value),
		"auto_start_monitor": _auto_monitor_switch.is_pressed(),
		"minimize_to_tray": _tray_switch.is_pressed(),
	})


## 防抖到点：收回设置 → 落盘 → 把新参数推给正在跑的监控与定时器。
func _commit_settings() -> void:
	_collect()
	AppConfig.save()
	_push_scheduler_config()
	if _monitor.running:
		_monitor.set_params(AppConfig.monitor_params())
	_refresh_v_export()


func _push_scheduler_config() -> void:
	_scheduler.configure(
			bool(AppConfig.get_value("auto_command")),
			int(AppConfig.get_value("command_hour")),
			int(AppConfig.get_value("command_minute")),
			str(AppConfig.get_value("command_last_triggered")))


func _selected_export() -> String:
	var index := _export_option.selected
	if index < 0 or index >= WltClient.EXPORT_TYPES.size():
		return "0"
	return WltClient.EXPORT_TYPES[index][0]


func _refresh_v_export() -> void:
	var value := _selected_export()
	_v_export.text = WltClient.export_short_name(value)
	_v_export.tooltip_text = "%s\n\n编号 %s。这是配置里选定的出口，不一定是网页上当前生效的那个。" % [
		WltClient.export_name(value), value]


func _clear_password() -> void:
	_password.text = ""
	_remember.set_pressed_no_signal(false)
	AppConfig.password = ""
	_collect()
	AppConfig.save()
	_log("已清除本地保存的密码", LogLevel.INFO)


# ================================================================ 监控

func _has_credentials() -> bool:
	return not str(AppConfig.get_value("username")).is_empty() and not AppConfig.password.is_empty()


func _start_monitoring() -> void:
	_collect()
	AppConfig.save()
	if not _has_credentials():
		_alert("信息不完整", "请先填写账号和密码。")
		return
	_monitor.set_params(AppConfig.monitor_params())
	_monitor.start(self, _client, AppConfig.monitor_params())


func _stop_monitoring() -> void:
	_monitor.stop()


func _on_running_changed(running: bool) -> void:
	_start_btn.disabled = running
	_stop_btn.disabled = not running
	_tray_set_disabled(_TRAY_START, running)
	_tray_set_disabled(_TRAY_STOP, not running)
	if not running:
		_set_status("未启动", "StatusIdle", false)
		_refresh_runtime()


func _on_status_changed(text: String, kind: int) -> void:
	# **头部与状态卡只显示「状态」，不显示整句话。**
	# 一来看起来干净，二来有实际原因：`Label` 的最小宽度就是整串文字的宽度，
	# 把「重连失败：域名解析失败（DNS 不通？）（60 秒后重试）」这种放进头部，
	# 它会把整个头部顶宽、把右边的按钮挤出窗口。完整原因全部进日志。
	_set_status(_short_status(kind), _status_variation(kind),
			kind == NetMonitor.Kind.WARN or kind == NetMonitor.Kind.ERROR)
	_status_text.tooltip_text = text      # 完整原因看这里，或者往下看日志
	match kind:
		NetMonitor.Kind.OK:
			_log(text, LogLevel.OK)
		NetMonitor.Kind.WARN:
			_log(text, LogLevel.WARN)
		NetMonitor.Kind.ERROR:
			_log(text, LogLevel.ERROR)
		_:
			_log(text, LogLevel.INFO)


static func _short_status(kind: int) -> String:
	match kind:
		NetMonitor.Kind.OK:
			return "已连接"
		NetMonitor.Kind.WARN:
			return "重连中"
		NetMonitor.Kind.ERROR:
			return "连接失败"
		_:
			return "未启动"


static func _status_variation(kind: int) -> String:
	match kind:
		NetMonitor.Kind.OK:
			return "StatusOk"
		NetMonitor.Kind.WARN:
			return "StatusWarn"
		NetMonitor.Kind.ERROR:
			return "StatusError"
		_:
			return "StatusIdle"


## 头部状态点、头部文字、卡片里的状态点与文字 —— 四处必须一起改。
## 集中在这一个函数里改，免得哪次漏掉一处、界面上两个地方说法不一致。
func _set_status(text: String, variation: String, flash: bool) -> void:
	_dot.set_status(variation)
	_card_dot.set_status(variation)
	_card_status.text = text
	_card_status.theme_type_variation = variation
	_status_text.theme_type_variation = variation
	_status_text.text = text
	if flash:
		_status_text.flash_color = ThemePalette.DANGER if variation == "StatusError" \
				else ThemePalette.WARNING
		_status_text.start()
	else:
		_status_text.stop()


func _refresh_runtime() -> void:
	_v_ip.text = _monitor.last_ip if not _monitor.last_ip.is_empty() else "—"
	_v_uptime.text = _format_duration(_monitor.uptime_seconds())
	if _monitor.last_check_unix <= 0.0:
		_v_last_check.text = "—"
	else:
		var when := Time.get_datetime_dict_from_unix_time(int(_monitor.last_check_unix))
		var state := "成功" if _monitor.last_check_ok else "失败"
		# 连续失败次数只在 ≥2 时显示 —— 一次失败多半只是抖一下，连着失败才值得警觉
		if not _monitor.last_check_ok and _monitor.consecutive_failures > 1:
			state += " · 连续 %d 次" % _monitor.consecutive_failures
		_v_last_check.text = "%02d:%02d:%02d（%s）" % [when["hour"], when["minute"], when["second"], state]


static func _format_duration(seconds: float) -> String:
	if seconds < 1.0:
		return "—"
	var total := int(seconds)
	return "%02d:%02d:%02d" % [total / 3600, (total % 3600) / 60, total % 60]


# ================================================================ 开机自启

func _on_autostart_toggled(on: bool) -> void:
	var ok := WinSystem.enable_autostart() if on else WinSystem.disable_autostart()
	if not ok:
		# 失败就把开关拨回去，别让界面显示一个并没有生效的状态
		_autostart_switch.set_pressed_no_signal(not on)
		_alert("设置失败", "没能修改开机自启项，可能是注册表权限受限。")
		return
	_log("已%s开机自启" % ("启用" if on else "关闭"), LogLevel.INFO)


# ================================================================ 定时执行指令

func _reset_command_triggered() -> void:
	_scheduler.reset_triggered()
	AppConfig.set_value("command_last_triggered", "")
	AppConfig.save()
	_log("已重置定时执行指令的触发记录，今天可以再触发一次", LogLevel.INFO)


func _on_command_triggered(key: String) -> void:
	if _cd_dialog != null and is_instance_valid(_cd_dialog):
		_scheduler.resolve(key, false)
		return

	var bat := AppPaths.command_bat()
	if not FileAccess.file_exists(bat):
		# 不消耗持久记录：把文件补上之后，当天还能再触发一次
		_scheduler.resolve(key, false)
		_log("定时执行指令已触发，但没找到 %s，本次跳过" % bat, LogLevel.WARN)
		_alert("未找到指令文件",
				"没找到 %s\n\n请在程序目录下新建 command.bat，并写入需要执行的指令。" % bat)
		return

	_open_countdown_dialog(key, bat)


## 倒计时对话框：环形进度条 + 中间的大数字。
##
## 环形与数字是**两个控件叠在一起**（都铺满 + 居中），不是新写的控件 ——
## `CircularProgressBar` 中心显示的是百分比，而这里要显示的是剩余秒数。
func _open_countdown_dialog(key: String, bat: String) -> void:
	_cd_key = key
	_cd_total = maxi(int(AppConfig.get_value("command_countdown")), 1)
	_cd_remaining = _cd_total
	_log("定时执行指令已触发，%d 秒后执行 %s" % [_cd_total, bat], LogLevel.WARN)

	var win := Window.new()
	win.title = "定时执行指令"
	win.transient = true
	win.exclusive = true
	win.unresizable = true
	win.close_requested.connect(_cancel_command)
	add_child(win)
	_cd_dialog = win

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	win.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	var headline := _label("倒计时结束后将执行以下指令", "Subtitle")
	headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(headline)

	var stack := Control.new()
	stack.custom_minimum_size = Vector2(128, 128)
	_cd_ring = CircularProgressBar.new()
	_cd_ring.show_text = false
	_cd_ring.ring_width = 9.0
	_cd_ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stack.add_child(_cd_ring)
	_cd_number = _label(str(_cd_remaining), "CountdownNumber")
	_cd_number.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cd_number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cd_number.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	stack.add_child(_cd_number)
	var center := CenterContainer.new()
	center.add_child(stack)
	box.add_child(center)

	var path := _label(bat, "PathLabel")
	path.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	path.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(path)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 10)
	buttons.add_child(_button("取消", "AccentButton", _cancel_command))

	# 「立即执行」用长按按钮防误触：command.bat 里通常写的是 shutdown 这类不可撤销的指令，
	# 误点一次代价太大。按住 1 秒才触发，按住期间按钮底部走一条进度条。
	var run := LongPressButton.new()
	run.text = "立即执行（按住 1 秒）"
	run.theme_type_variation = "DangerButton"
	run.hold_duration = 1.0
	run.long_pressed.connect(_execute_command)
	buttons.add_child(run)
	box.add_child(buttons)

	_cd_timer = Timer.new()
	_cd_timer.wait_time = 1.0
	_cd_timer.timeout.connect(_tick_countdown)
	win.add_child(_cd_timer)
	_cd_timer.start()

	# 尺寸贴着内容给：headline 19 + 环 128 + 路径 16 + 按钮 32 + 间距与页面边距 ≈ 270
	win.popup_centered(Vector2i(400, 300))


func _tick_countdown() -> void:
	if _cd_remaining <= 1:
		_execute_command()
		return
	_cd_remaining -= 1
	_cd_number.text = str(_cd_remaining)
	_cd_ring.value = float(_cd_remaining) / float(_cd_total)


func _execute_command() -> void:
	if not _close_countdown():
		return            # 已经处理过了（长按按钮与倒计时可能几乎同时到）
	_scheduler.resolve(_cd_key, true)
	AppConfig.set_value("command_last_triggered", _scheduler.last_triggered)
	AppConfig.save()

	var bat := AppPaths.command_bat()
	if not FileAccess.file_exists(bat):
		_log("准备执行时 %s 已不存在，本次跳过" % bat, LogLevel.ERROR)
		_alert("执行失败", "没有找到 %s。" % bat)
		return

	# 用 create_process 而不是 OS.execute：后者会阻塞主线程直到批处理结束，
	# 而 command.bat 里可能是 shutdown 这类会挂住的操作。见 WinShell 的说明。
	var pid := WinShell.run_cmd_in_dir("\"%s\"" % bat.replace("/", "\\"), AppPaths.base_dir())
	if pid > 0:
		_log("已启动 command.bat（pid=%d）" % pid, LogLevel.WARN)
	else:
		_log("启动 command.bat 失败", LogLevel.ERROR)
		_alert("执行失败", "无法启动 %s，请检查文件权限。" % bat)


func _cancel_command() -> void:
	if not _close_countdown():
		return
	# **取消不算「今天已触发」**：旧版在弹窗之前就把记录写死了，点了取消当天再也不会响。
	_scheduler.resolve(_cd_key, false)
	_log("定时执行指令已取消（不会消耗今天的触发机会）", LogLevel.INFO)


## 关掉倒计时对话框。返回 false 表示它本来就关着（调用方据此避免重复处理）。
func _close_countdown() -> bool:
	if _cd_dialog == null or not is_instance_valid(_cd_dialog):
		return false
	if _cd_timer != null and is_instance_valid(_cd_timer):
		_cd_timer.stop()
	_cd_dialog.hide()
	_cd_dialog.queue_free()
	_cd_dialog = null
	_cd_ring = null
	_cd_number = null
	_cd_timer = null
	return true


# ================================================================ 日志

func _log(message: String, level: int = LogLevel.INFO) -> void:
	var stamp := Time.get_datetime_dict_from_system()
	var hms := "%02d:%02d:%02d" % [stamp["hour"], stamp["minute"], stamp["second"]]
	var color := _level_color(level)
	_log_view.append_text("[color=#%s]%s[/color]  %s\n" % [color.to_html(false), hms,
			_bbcode_escape(message)])
	while _log_view.get_paragraph_count() > _LOG_MAX_PARAGRAPHS:
		_log_view.remove_paragraph(0)
	_log_store.append("[%s] %s" % [_level_tag(level), message])


static func _level_color(level: int) -> Color:
	match level:
		LogLevel.OK:
			return ThemePalette.SUCCESS
		LogLevel.WARN:
			return ThemePalette.WARNING
		LogLevel.ERROR:
			return ThemePalette.DANGER
		_:
			return ThemePalette.TEXT_SEC


static func _level_tag(level: int) -> String:
	match level:
		LogLevel.OK:
			return "正常"
		LogLevel.WARN:
			return "警告"
		LogLevel.ERROR:
			return "错误"
		_:
			return "信息"


## 消息里可能带 `[`（路径、方括号说明都会），在 bbcode 里会被当标签解析，得转义。
static func _bbcode_escape(text: String) -> String:
	return text.replace("[", "[lb]")


func _clear_log() -> void:
	_log_view.clear()
	_log("日志窗口已清空（磁盘上的日志文件不受影响）", LogLevel.INFO)


func _open_log_dir() -> void:
	AppPaths.open_in_explorer(_log_store.dir_path())


func _log_startup_info() -> void:
	_log("配置文件：%s" % AppShell.config_path, LogLevel.INFO)
	_log("日志目录：%s" % _log_store.dir_path(), LogLevel.INFO)
	if not AppPaths.is_portable():
		_log("程序目录不可写，配置与日志已改存到用户数据目录", LogLevel.WARN)
	_log("密码密钥存储：%s" % SecretStore.key_source_text(),
			LogLevel.INFO if SecretStore.key_source() == SecretStore.Source.REGISTRY else LogLevel.WARN)
	if not _tray_available:
		_log("当前系统不支持状态栏图标，关闭窗口只能最小化到任务栏", LogLevel.WARN)
	if not WinSystem.autostart_supported():
		_log("在编辑器里运行，开机自启不可用（导出成 exe 后可用）", LogLevel.INFO)


# ================================================================ 窗口与退出

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_on_close_requested()


func _on_close_requested() -> void:
	_collect()
	AppConfig.save()
	if _tray_available and bool(AppConfig.get_value("minimize_to_tray")):
		_hide_to_tray()
	else:
		_quit()


func _hide_to_tray() -> void:
	var win := get_window()
	win.hide()
	if win.visible:
		# 个别平台上主窗口隐藏不了，退回最小化 —— 至少别让用户以为程序卡死了
		win.mode = Window.MODE_MINIMIZED
		_log("当前平台无法隐藏窗口，已改为最小化到任务栏", LogLevel.WARN)
	else:
		_log("已隐藏到系统托盘（托盘图标上右键可退出）", LogLevel.INFO)


func _show_window() -> void:
	var win := get_window()
	if not win.visible:
		win.show()
	if win.mode == Window.MODE_MINIMIZED:
		win.mode = Window.MODE_WINDOWED
	win.move_to_foreground()


func _quit() -> void:
	_monitor.stop()
	_scheduler.stop()
	_collect()
	AppConfig.save()
	get_tree().quit()


# ================================================================ 提示框

func _alert(title: String, text: String) -> void:
	if _alert_dialog == null or not is_instance_valid(_alert_dialog):
		_alert_dialog = AcceptDialog.new()
		_alert_dialog.ok_button_text = "知道了"
		add_child(_alert_dialog)
	_alert_dialog.title = title
	_alert_dialog.dialog_text = text
	_alert_dialog.popup_centered()
