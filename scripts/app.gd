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

# ---- 头部 ----
var _dot: StatusDot
var _status_text: FlashLabel
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

var _log_view: LogView

var _tray_available := false
var _tray: StatusIndicator
var _tray_menu: PopupMenu

var _save_timer: Timer
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
	_cleanup_legacy_autostart_once()   # 必须排在 _load_into_ui() 之前：开关要读到清理后的状态
	_load_into_ui()          # 必须在 _connect_signals() 之前：设置控件的初值会触发 value_changed
	_connect_signals()
	# **必须真把它跑起来**：`configure()` 只是把参数收进去，轮询协程要 `start()` 才起。
	# 之前这里漏了这一行，于是「定时执行指令」永远不触发（配置、触发后记账、界面全都对，
	# 就是没人轮询）—— 一个只有真去等一分钟才发现得了的静默失效。
	_scheduler.start(self)

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

	# **页面级滚动**：窗口比内容小时整体滚动，而不是把右下角直接切掉。
	# 拉伸模式是 `disabled`（见 project.godot 的说明），所以「窗口变小 = 显示更少内容」，
	# 兜底就靠这一层。两行**一起滚**是刻意的 —— 见下面 GridContainer 的说明。
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 横向留 AUTO：这套布局的固有最小宽度有一千多像素（「网络」那张卡里有一串
	# 「1 教育网出口（国际，仅用教育网访问，适合看文献）」，`Label`/`OptionButton`
	# 的最小宽度就是整串文字的宽度），屏幕小或缩放大的机器上出个横向滚动条兜底，
	# 总比把右边裁掉强。默认窗口尺寸已经按「装得下全部内容」算过了，正常看不到它。
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	page.add_child(scroll)

	# 整体是「2 列 × 2 行」的网格，布局是：
	#
	#     账户          | 网络
	#     定时执行指令   | 运行日志
	#     启动与外观     | 运行日志（续）
	#
	# 左边那两格是同一个 VBox（定时执行指令 / 启动与外观），左下那条竖向分界线
	# 因此与「账户」的右边界严格对齐；「运行日志」占满整个右列 ——
	# GridContainer 不支持跨格，所以它落在第 2 行右格，纵向自己长满。
	# 列宽别指望 `size_flags_stretch_ratio`：Godot 的 GridContainer 把富余宽度在
	# 可扩展的列之间**平均**分（`grid_container.cpp` 里是
	# `remaining_space.width / col_expanded.size()`）。
	var body := GridContainer.new()
	body.columns = 2
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 页面上其它间距都是 12（`page` / 各列内部），网格这里也统一成 12，
	# 否则各分块之间会夹着一圈 8px 的缝（GridContainer 的主题默认值）。
	body.add_theme_constant_override("h_separation", 12)
	body.add_theme_constant_override("v_separation", 12)
	scroll.add_child(body)

	# 第 1 行左：账户
	body.add_child(_build_account_card())

	# 第 1 行右：网络
	body.add_child(_build_network_card())

	# 第 2 行左：定时执行指令 / 启动与外观（竖排）
	var bottom_left := VBoxContainer.new()
	bottom_left.add_theme_constant_override("separation", 12)
	bottom_left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 与同一列上方的「账户」同宽（网格第 0 列的宽度取两者中较大的那个）
	bottom_left.custom_minimum_size.x = ThemePalette.CARD_MIN_W
	bottom_left.add_child(_build_command_card())
	bottom_left.add_child(_build_startup_card())
	body.add_child(bottom_left)

	# 第 2 行右：运行日志
	body.add_child(_build_log_card())


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

	_start_btn = _button("启动", "SuccessButton", _start_monitoring)
	_stop_btn = _button("停止", "DangerButton", _stop_monitoring)
	_stop_btn.disabled = true
	header.add_child(_start_btn)
	header.add_child(_stop_btn)

	_hide_btn = _button("隐藏到托盘", "GhostButton", _hide_to_tray)
	_hide_btn.tooltip_text = "把窗口从任务栏上收起来；托盘图标仍常驻，点它可以调回来。"
	_hide_btn.visible = _tray_available
	header.add_child(_hide_btn)
	return header


func _build_account_card() -> Control:
	var card := TitledGroup.new()
	card.title = "账户"
	# 横向**不设 EXPAND**：第 0 列（= 本卡片与下方的「定时执行指令 / 启动与外观」）
	# 宽度就钉在 CARD_MIN_W 上，窗口变宽时多出来的宽度全给右列的「网络 / 运行日志」——
	# 日志需要宽度（见 CARD_MIN_W 的注释）。
	# 纵向不设 —— 第 1 行的高度由右邻的「网络」卡决定，本卡片被那一行撑高，
	# 接缝才落在同一条横线上。
	card.custom_minimum_size.x = ThemePalette.CARD_MIN_W

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
	# 独占第 1 行右格：横向 EXPAND，跟着窗口一起变宽
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

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
	# **纵向 EXPAND：这一列的最后一张卡要把余下的高度吃掉。**
	#
	# 左列是个 VBox（定时执行指令 / 启动与外观），两张卡都只有自然高度；
	# 而网格把这一格拉到与右边「运行日志」一样高，多出来的那截如果没人接手，
	# 就会留在 VBox 底部 —— 也就是**卡片外面**，于是日志的底边比启动与外观低一截。
	# 让最后一张卡长起来，它的下边界就与日志卡片对齐，余白改到卡片内部
	# （和上面一行被撑高的「账户」卡片是同一种表现，观感一致）。
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_auto_monitor_switch = Switch.new()
	card.content.add_child(_switch_row("启动后自动监控", _auto_monitor_switch,
			"程序一启动（含开机自启）就自动开始监控。"))

	_autostart_switch = Switch.new()
	card.content.add_child(_switch_row("开机自启", _autostart_switch,
			"在「启动」文件夹里放一个本程序的快捷方式，登录 Windows 后自动运行。\n"
			+ "不用注册表：往 HKCU\\...\\Run 写值会被杀软当成木马行为拦下来。"))
	# 开发期写进注册表的会是 Godot 编辑器本身，没有意义，直接禁掉（见 WinSystem 的说明）
	if not WinSystem.autostart_supported():
		_autostart_switch.disabled = true

	var tray_label := "关窗时隐藏到托盘" if _tray_available else "关窗时最小化"
	_tray_switch = Switch.new()
	card.content.add_child(_switch_row(tray_label, _tray_switch,
			"开：点关闭按钮只是把窗口藏起来，监控继续跑；要退出走托盘菜单的「退出」。\n"
			+ "关：点关闭按钮直接退出程序（监控一起停）。"))
	if not _tray_available:
		_tray_switch.disabled = true

	_scale_option = UiScaleOption.new()
	card.content.add_child(_row("界面缩放", _scale_option))
	return card


func _build_log_card() -> Control:
	var card := TitledGroup.new()
	card.title = "运行日志"
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 卡片会被拉得比内容高，内容容器必须跟着伸，日志框才填得满整张卡片 ——
	# 否则日志框只占「最小高度」，下面留一大片白（原样就是这样）。
	card.content.size_flags_vertical = Control.SIZE_EXPAND_FILL

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

	_log_view = LogView.new()
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
	# 托盘图标用**缩小过的** PNG，不是那张 256×256 的 icon.png：
	# 托盘实际只显示 16~24 像素，拿 256 的图去缩会糊成一团。
	_tray.icon = load("res://themes/icons/tray.png")
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


func _on_status_changed(text: String, kind: int) -> void:
	# **头部只显示「状态」，不显示整句话。**
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


## 头部状态点与状态文字必须一起改（同一个状态在两处说法不一致最难查）。
func _set_status(text: String, variation: String, flash: bool) -> void:
	_dot.set_status(variation)
	_status_text.theme_type_variation = variation
	_status_text.text = text
	if flash:
		_status_text.flash_color = ThemePalette.DANGER if variation == "StatusError" \
				else ThemePalette.WARNING
		_status_text.start()
	else:
		_status_text.stop()


# ================================================================ 开机自启

## 清掉旧版遗留在注册表里的自启项，**一次性、静默**。
##
## 注意这里**不会**替用户打开开机自启：程序自己永远不去建那个快捷方式，
## 开关的初始状态永远是「关」（= 启动文件夹里没有快捷方式）。
## `WinSystem.cleanup_legacy_autostart()` 只删旧位置，界面上不提示、日志里也不写。
func _cleanup_legacy_autostart_once() -> void:
	if bool(AppConfig.get_value("legacy_autostart_checked")):
		return
	# 编辑器和导出版用的是**不同的配置文件**（工程目录 vs exe 同级），但这里仍然要先挡一道：
	# 编辑器里 `autostart_supported()` 是 false，迁移根本无从谈起，
	# 这时候要是把「已检查」记下来，等真的导出成 exe 跑起来时就不会再清理了。
	if not WinSystem.autostart_supported():
		return
	AppConfig.set_value("legacy_autostart_checked", true)
	WinSystem.cleanup_legacy_autostart()      # 静默清掉，不打扰用户
	AppConfig.save()


func _on_autostart_toggled(on: bool) -> void:
	# 建快捷方式要起一次 PowerShell，实测约 0.75 秒，而 `OS.execute` 是**阻塞主线程**的。
	# 所以先让界面把「处理中」这一帧画出来再动手，否则用户看到的是「点了开关，窗口卡死」。
	_autostart_switch.disabled = true
	_log("正在%s开机自启（要起一次 PowerShell，界面会短暂无响应）…" % ("启用" if on else "关闭"),
			LogLevel.INFO)
	await get_tree().process_frame
	var ok := WinSystem.enable_autostart() if on else WinSystem.disable_autostart()
	_autostart_switch.disabled = false
	if not ok:
		# 失败就把开关拨回去，别让界面显示一个并没有生效的状态
		_autostart_switch.set_pressed_no_signal(not on)
		_alert("设置失败",
				"没能在启动文件夹里%s快捷方式。\n\n位置：%s" % [
					"创建" if on else "删除", WinSystem.startup_dir()])
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

## 写一行日志。界面上那份交给 `LogView`（自带时间戳、级别配色、500 行一批的裁剪、
## BBCode 转义），磁盘上那份交给 `LogStore`（按天轮转）。
func _log(message: String, level: int = LogLevel.INFO) -> void:
	_log_view.append(message, _level_name(level))
	_log_store.append("[%s] %s" % [_level_tag(level), message])


## 界面的日志级别名 —— `LogView.append()` 收的是字符串，不是枚举。
static func _level_name(level: int) -> String:
	match level:
		LogLevel.OK:
			return "ok"
		LogLevel.WARN:
			return "warn"
		LogLevel.ERROR:
			return "error"
		_:
			return "info"


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


func _clear_log() -> void:
	_log_view.clear()
	_log("日志窗口已清空（磁盘上的日志文件不受影响）", LogLevel.INFO)


func _open_log_dir() -> void:
	AppPaths.open_in_explorer(_log_store.dir_path())


func _log_startup_info() -> void:
	_log("配置文件：%s" % AppShell.config_path, LogLevel.INFO)
	_log("日志目录：%s" % _log_store.dir_path(), LogLevel.INFO)
	# **实际生效**的渲染器，不是工程里写的那个。
	# 工程里是 `gl_compatibility`，但如果自编译模板没把那条路径编进去，引擎会
	# **静默回退**到别的渲染器——不报错、界面也照常，只有这一行能看出来。
	# 导出的 exe 是 GUI 子系统、没有 stdout，所以 Godot 自己那行启动输出根本看不到，
	# 必须由我们自己写进日志文件。（两个 API 的返回值枚举见 RenderingServer 文档。）
	_log("渲染器：%s（驱动 %s）" % [
			RenderingServer.get_current_rendering_method(),
			RenderingServer.get_current_rendering_driver_name()], LogLevel.INFO)
	if not AppPaths.is_portable():
		_log("程序目录不可写，配置与日志已改存到用户数据目录", LogLevel.WARN)
	_log("密码密钥存储：%s" % SecretStore.key_source_text(),
			LogLevel.INFO if SecretStore.key_source() == SecretStore.Source.REGISTRY else LogLevel.WARN)
	if not _tray_available:
		_log("当前系统不支持状态栏图标，关闭窗口只能最小化到任务栏", LogLevel.WARN)
	# 这一条是给「换机器忘了带 dll」准备的：缺了它程序照跑，只是关窗时变成最小化，
	# 界面上看不出区别 —— 日志里有这行才好查。
	if _native_window_available():
		_log("窗口隐藏扩展已加载（关窗后任务栏上不会留按钮）", LogLevel.INFO)
	else:
		_log("窗口隐藏扩展不可用（缺 native_window.windows.x86_64.dll，"
				+ "它应当和 exe 放在一起），关窗时只能最小化到任务栏", LogLevel.WARN)
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


## 「关闭窗口时」进托盘：把窗口**真正藏起来**（任务栏和 Alt+Tab 上都没有它）。
##
## 这一步必须借 `NativeWindow` 这个原生扩展直接调 Win32 的 `ShowWindow` ——
## Godot 自己的 API 做不到，原因见 `tools/native_window/native_window.c` 顶部的长注释
## （一句话：`Window::set_visible()` 对主窗口直接 `ERR_FAIL`，而 Windows 后端给主窗口
## 恒定加 `WS_EX_APPWINDOW`，那就是「必须出现在任务栏」的意思）。
##
## 扩展没编出来（`bin/native_window.windows.x86_64.dll` 缺失）时**退回最小化** ——
## 窗口会在任务栏上留一个按钮，但「关窗后程序继续跑」这件事不受影响。
func _hide_to_tray() -> void:
	# 隐藏成功**不写日志**：这是日常操作，一天可能点好几次，记进日志只会淹掉有用信息。
	# 退回最小化是降级路径（原生扩展没加载），那种情况要留下痕迹。
	if _native_hide():
		return
	get_window().mode = Window.MODE_MINIMIZED
	_log("已最小化到任务栏（原生扩展不可用，Godot 自己不允许隐藏主窗口）。"
			+ "程序继续在后台运行，点托盘图标可以把它调回来", LogLevel.WARN)


## 把窗口从隐藏/最小化调回前台。托盘图标被点、或第二个实例启动时都会走到这里。
func _show_window() -> void:
	if _native_show():
		return
	var win := get_window()
	# 主窗口永远是 visible，不需要（也不能）`show()`
	if win.mode == Window.MODE_MINIMIZED:
		win.mode = Window.MODE_WINDOWED
	win.move_to_foreground()


# ---------------------------------------------------------------- 原生窗口扩展
#
# 全部走 `ClassDB.class_call_static()` 这种**动态**调用，而不是在脚本里直接写
# `NativeWindow.hide_window(...)`：后者的前提是那个类必须在编译期就存在，
# 一旦 .dll 没编出来，**整个脚本会编译不过**（连"退回最小化"的机会都没有）。
# 动态调用的代价只是每次都查一次 ClassDB，而这里一次关窗只调一次，无所谓。

## 窗口当前是不是被原生扩展藏起来了（`_show_window` 据此决定要不要恢复）。
var _window_native_hidden := false

## 藏起来之前的帧率上限，`_native_show()` 要还原回去。
var _max_fps_before_hide := 0

## 窗口藏起来之后把帧率压到多少。
##
## 为什么不干脆停掉渲染：`Viewport.render_target_update_mode` 这个属性**只注册在
## `SubViewport` 上**（虽然是 `viewport.h` 里声明的那个枚举，但 `ADD_PROPERTY` 写在
## `SubViewport::_bind_methods` 里），根窗口拿不到它，写上去是运行时报错。
## 所以退而求其次，用 `Engine.max_fps` 把整个主循环憋住 —— 渲染、物理、动画全跟着慢，
## 而**计时器与协程走的是真实时间**，监控照常跑。
##
## 不压到 1（更省）是因为托盘菜单也是 Godot 画的：1fps 下右键托盘图标要等一秒才弹出来。
## 10fps 既省了 5/6 的开销，菜单又是「立刻」出来的感觉。
const _HIDDEN_MAX_FPS := 10


static func _native_window_available() -> bool:
	return ClassDB.class_exists(&"NativeWindow") \
			and bool(ClassDB.class_call_static(&"NativeWindow", &"is_supported"))


static func _native_window_handle() -> int:
	return DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)


func _native_hide() -> bool:
	if not _native_window_available():
		return false
	# 幂等：已经藏起来了就直接返回。**这个守卫是必需的**，不只是省一次调用 ——
	# 下面要「读回当前的 viewport 更新模式、等显示时写回去」，重复调用会把
	# 自己刚写进去的 DISABLED 当成「原值」存下来，窗口再显示出来就是永久冻住的。
	if _window_native_hidden:
		return true
	var hwnd := _native_window_handle()
	if hwnd == 0:
		return false
	ClassDB.class_call_static(&"NativeWindow", &"hide_window", hwnd)
	_window_native_hidden = true
	# 窗口藏起来了，但 **Godot 并不知道** —— 它照样按 60fps 渲染。一个「待在托盘里
	# 待机一整天」的程序没必要一直烤 GPU，所以把帧率压下来（见 _HIDDEN_MAX_FPS）。
	_max_fps_before_hide = Engine.max_fps
	Engine.max_fps = _HIDDEN_MAX_FPS
	_set_root_viewport_updates(false)
	return true


func _native_show() -> bool:
	if not _window_native_hidden:
		return false
	var hwnd := _native_window_handle()
	if hwnd == 0:
		return false
	# **先恢复更新、再显示**：反过来的话窗口会先以「冻住的旧画面」出现，
	# 要等下一次内容变化才刷新。
	_set_root_viewport_updates(true)
	ClassDB.class_call_static(&"NativeWindow", &"show_window", hwnd)
	_window_native_hidden = false
	# **先还原帧率再返回**：让它紧接着的那一帧就按正常帧率画出来，
	# 否则用户点完托盘图标会先看到一秒的卡顿感。
	Engine.max_fps = _max_fps_before_hide
	# 扩展把窗口置于最前了（SetForegroundWindow），这里不用再 move_to_foreground
	return true


## 藏起来之前根 viewport 的更新模式；-1 = 当前没被我们停掉。
var _viewport_update_before_hide := -1


## 停 / 恢复**根 viewport 的更新**。
##
## 为什么还需要这一步（`Engine.max_fps` 和 `low_processor_mode` 都不够）：
##
## - `Engine.max_fps = 10` 只是「最多画多快」，帧还是要画；
## - `low_processor_mode` 只是「**没变化**就不画」—— 可隐藏期间画面偏偏会变：
##   报警态下 `FlashLabel` 每 0.7 秒翻一次透明度，断网重连时状态文字也在改，
##   于是每 0.7 秒就重绘一次整窗，而窗口根本看不见。
##
## 走的是 RenderingServer 这一层，不是 `Viewport.render_target_update_mode`：
## 后者只在 `SubViewport` 上注册，根窗口写上去是运行时报错（见 CLAUDE.md）。
## RenderingServer 这层**文档没写能不能用在根 viewport 上**，2026-10-09 实测可以：
## 禁用后往日志写一行，画面像素变化 0.000%；恢复之后那行正常出现。
##
## **托盘菜单和倒计时对话框不受影响**：它们是独立的原生窗口、各自有 viewport
## （`Viewport.gui_embed_subwindows` 在桌面平台默认 false，本工程没改过）。
##
## 恢复时**照原样写回读到的值**，不写死 `VIEWPORT_UPDATE_ALWAYS` —— 那个值是
## 「每帧都重画」，会把 `low_processor_mode` 省下来的又还回去。
func _set_root_viewport_updates(on: bool) -> void:
	var rid := get_viewport().get_viewport_rid()
	if on:
		if _viewport_update_before_hide >= 0:
			RenderingServer.viewport_set_update_mode(rid, _viewport_update_before_hide)
			_viewport_update_before_hide = -1
		return
	# 已经是停掉的状态就别再读一次（见 _native_hide 的幂等守卫）
	var current := RenderingServer.viewport_get_update_mode(rid)
	if current == RenderingServer.VIEWPORT_UPDATE_DISABLED:
		return
	_viewport_update_before_hide = current
	RenderingServer.viewport_set_update_mode(rid, RenderingServer.VIEWPORT_UPDATE_DISABLED)


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
