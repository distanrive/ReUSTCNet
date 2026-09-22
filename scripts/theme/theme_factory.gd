class_name ThemeFactory
extends RefCounted
## 由 ThemePalette 设计令牌构建完整 Theme。
##
## 主题在运行时由 ThemeManager autoload 调用 `build()` 后应用到根窗口，
## 因此这里与 ThemePalette 是唯二的样式来源，业务脚本不要 per-control 打补丁。
##
## 本文件是从 Godot4GUI 模板裁剪来的：模板里给 DataTable / TreeTable / TrendChart /
## IntensityMap / FileDropBox / PartitionIndicator 等控件准备的段落已随那些控件一起删除。
## **需要新层级（新控件类型或新的语义变体）时在这里加一段**，不要在业务脚本里
## `add_theme_color_override` / `add_theme_font_size_override` —— 那会让「改一个文件
## 全局生效」这条链断掉。

const _TRANSPARENT := Color(0, 0, 0, 0)


## 构建全局主题（样式统一，颜色/字号/圆角全部来自 ThemePalette）。
static func build() -> Theme:
	var t := Theme.new()
	t.default_font_size = ThemePalette.FONT_MD
	_colors(t)
	_styleboxes(t)
	_icons(t)
	_constants(t)
	_custom_types(t)
	_type_variations(t)
	return t


# ---------- 颜色 ----------

static func _colors(t: Theme) -> void:
	_set_text_colors(t, "Label", ThemePalette.TEXT)
	_set_text_colors(t, "RichTextLabel", ThemePalette.TEXT)

	# 按钮系（CheckBox / OptionButton / SpinBox 都继承 Button）
	t.set_color("font_color", "Button", ThemePalette.TEXT)
	t.set_color("font_hover_color", "Button", ThemePalette.TEXT)
	t.set_color("font_pressed_color", "Button", ThemePalette.TEXT)
	t.set_color("font_focus_color", "Button", ThemePalette.TEXT)
	t.set_color("font_hover_pressed_color", "Button", ThemePalette.TEXT)
	t.set_color("font_disabled_color", "Button", ThemePalette.TEXT_DIS)

	for typ in ["CheckBox", "OptionButton"]:
		t.set_color("font_color", typ, ThemePalette.TEXT)
		t.set_color("font_hover_color", typ, ThemePalette.TEXT)
		t.set_color("font_pressed_color", typ, ThemePalette.TEXT)
		t.set_color("font_focus_color", typ, ThemePalette.TEXT)
		t.set_color("font_hover_pressed_color", typ, ThemePalette.TEXT)
		t.set_color("font_disabled_color", typ, ThemePalette.TEXT_DIS)

	# 输入框
	t.set_color("font_color", "LineEdit", ThemePalette.TEXT)
	t.set_color("font_placeholder_color", "LineEdit", ThemePalette.TEXT_SEC)
	t.set_color("font_selected_color", "LineEdit", ThemePalette.TEXT_ON_ACCENT)
	t.set_color("caret_color", "LineEdit", ThemePalette.ACCENT)
	t.set_color("selection_color", "LineEdit", Color(ThemePalette.ACCENT, 0.35))

	t.set_color("font_color", "SpinBox", ThemePalette.TEXT)

	# 弹出菜单（OptionButton 的下拉、托盘菜单都走这里）
	t.set_color("font_color", "PopupMenu", ThemePalette.TEXT)
	t.set_color("font_hover_color", "PopupMenu", ThemePalette.TEXT)
	t.set_color("font_disabled_color", "PopupMenu", ThemePalette.TEXT_DIS)
	t.set_color("font_accelerator_color", "PopupMenu", ThemePalette.TEXT_SEC)

	# 工具提示
	t.set_color("font_color", "TooltipLabel", ThemePalette.TEXT)


# ---------- StyleBox ----------

static func _styleboxes(t: Theme) -> void:
	# 中性按钮
	var btn := _sb(ThemePalette.SURFACE, ThemePalette.BORDER, ThemePalette.RADIUS_SM, 1,
			ThemePalette.PAD_BUTTON_H, ThemePalette.PAD_BUTTON_V)
	var btn_hover := _sb(ThemePalette.SURFACE_ALT, ThemePalette.BORDER_STRONG, ThemePalette.RADIUS_SM, 1,
			ThemePalette.PAD_BUTTON_H, ThemePalette.PAD_BUTTON_V)
	var btn_pressed := _sb(ThemePalette.ACCENT_SOFT, ThemePalette.ACCENT, ThemePalette.RADIUS_SM, 1,
			ThemePalette.PAD_BUTTON_H, ThemePalette.PAD_BUTTON_V)
	var btn_hover_pressed := _sb(ThemePalette.ACCENT_SOFT_HOVER, ThemePalette.ACCENT, ThemePalette.RADIUS_SM, 1,
			ThemePalette.PAD_BUTTON_H, ThemePalette.PAD_BUTTON_V)
	var btn_disabled := _sb(ThemePalette.SURFACE, ThemePalette.BORDER, ThemePalette.RADIUS_SM, 1,
			ThemePalette.PAD_BUTTON_H, ThemePalette.PAD_BUTTON_V)
	var btn_focus := _outline(ThemePalette.ACCENT, ThemePalette.RADIUS_SM)

	_apply_button_styles(t, "Button", btn, btn_hover, btn_pressed, btn_disabled, btn_focus)
	t.set_stylebox("hover_pressed", "Button", btn_hover_pressed)

	# 输入框
	t.set_stylebox("normal", "LineEdit", _sb(ThemePalette.SURFACE, ThemePalette.BORDER,
			ThemePalette.RADIUS_SM, 1, ThemePalette.PAD_INPUT_H, ThemePalette.PAD_INPUT_V))
	t.set_stylebox("focus", "LineEdit", _sb(ThemePalette.SURFACE, ThemePalette.ACCENT,
			ThemePalette.RADIUS_SM, 1, ThemePalette.PAD_INPUT_H, ThemePalette.PAD_INPUT_V))

	# 数值框
	t.set_stylebox("normal", "SpinBox", _sb(ThemePalette.SURFACE, ThemePalette.BORDER, ThemePalette.RADIUS_SM, 1))
	t.set_stylebox("updown", "SpinBox", _sb(ThemePalette.SURFACE_ALT, ThemePalette.BORDER, ThemePalette.RADIUS_SM, 1))

	# 面板 / 卡片（TitledGroup 就是 PanelContainer）
	t.set_stylebox("panel", "PanelContainer", _sb(ThemePalette.SURFACE, ThemePalette.BORDER,
			ThemePalette.RADIUS_MD, 1, ThemePalette.PAD_PANEL, ThemePalette.PAD_PANEL))
	# 滚动区域不画底，露出应用背景
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	# 弹出菜单
	t.set_stylebox("panel", "PopupMenu", _sb(ThemePalette.SURFACE, ThemePalette.BORDER,
			ThemePalette.RADIUS_MD, 1, ThemePalette.PAD_POPUP, ThemePalette.PAD_POPUP))
	t.set_stylebox("hover", "PopupMenu", _sb(ThemePalette.ACCENT_SOFT, _TRANSPARENT,
			ThemePalette.RADIUS_SM, 0, ThemePalette.PAD_POPUP, 3.0))

	# 对话框
	var dialog := _sb(ThemePalette.SURFACE, ThemePalette.BORDER, ThemePalette.RADIUS_MD, 1,
			ThemePalette.PAD_PANEL, ThemePalette.PAD_PANEL)
	t.set_stylebox("panel", "AcceptDialog", dialog)
	t.set_stylebox("panel", "ConfirmationDialog", dialog)

	# 内嵌窗口（对话框）的标题栏：引擎默认是深灰，跟浅色主题不搭。
	# 换色时**必须保留默认的内容边距**（content_margin_top = 28 是标题栏高度、
	# expand_margin = 32 是投影留白）：边距给小了标题文字会被裁掉 ——
	# 这就是「覆盖 embedded_border 之后标题栏消失」的真正原因，不是不能覆盖。
	var embed := StyleBoxFlat.new()
	embed.bg_color = ThemePalette.SURFACE_ALT
	embed.border_color = ThemePalette.BORDER
	embed.set_border_width_all(1)
	embed.set_corner_radius_all(ThemePalette.RADIUS_MD)
	embed.expand_margin_left = 32.0
	embed.expand_margin_top = 32.0
	embed.expand_margin_right = 32.0
	embed.expand_margin_bottom = 32.0
	embed.content_margin_left = 10.0
	embed.content_margin_top = 28.0
	embed.content_margin_right = 10.0
	embed.content_margin_bottom = 8.0
	# 保留一点投影，否则对话框和浅色背景贴在一起分不出层次
	embed.shadow_color = Color(0.0, 0.0, 0.0, 0.16)
	embed.shadow_size = 10
	t.set_stylebox("embedded_border", "Window", embed)
	t.set_stylebox("embedded_unfocused_border", "Window", embed)
	t.set_color("title_color", "Window", ThemePalette.TEXT)
	t.set_color("title_outline_modulate", "Window", _TRANSPARENT)
	t.set_font_size("title_font_size", "Window", ThemePalette.FONT_MD)
	# 关闭按钮：引擎默认是「白色叉」，浅色标题栏上会看不见，必须换成深色图标
	t.set_icon("close", "Window", _icon("close.svg"))
	t.set_icon("close_pressed", "Window", _icon("close_pressed.svg"))

	# 滚动条：轨道 + 滑块（ScrollBar 的 grabber 是 StyleBox，非图标）
	t.set_stylebox("scroll", "ScrollBar", _sb(ThemePalette.SURFACE_ALT, _TRANSPARENT, ThemePalette.RADIUS_SM, 0))
	t.set_stylebox("scroll_focus", "ScrollBar", _sb(ThemePalette.SURFACE_ALT, _TRANSPARENT, ThemePalette.RADIUS_SM, 0))
	t.set_stylebox("grabber", "ScrollBar", _sb(ThemePalette.BORDER_STRONG, _TRANSPARENT, ThemePalette.RADIUS_SM, 0))
	t.set_stylebox("grabber_highlight", "ScrollBar", _sb(ThemePalette.BORDER_STRONG.lightened(0.25), _TRANSPARENT, ThemePalette.RADIUS_SM, 0))
	t.set_stylebox("grabber_pressed", "ScrollBar", _sb(ThemePalette.ACCENT, _TRANSPARENT, ThemePalette.RADIUS_SM, 0))

	# 工具提示
	t.set_stylebox("panel", "TooltipPanel", _sb(ThemePalette.SURFACE, ThemePalette.BORDER_STRONG,
			ThemePalette.RADIUS_SM, 1, ThemePalette.PAD_INPUT_H, ThemePalette.PAD_INPUT_V))

	# 分隔线
	t.set_stylebox("separator", "Separator", _sb(ThemePalette.BORDER, _TRANSPARENT, 0, 0))


# ---------- 图标 ----------

static func _icons(t: Theme) -> void:
	var check_on := _icon("check_checked.svg")
	var check_off := _icon("check_unchecked.svg")
	var radio_on := _icon("radio_checked.svg")
	var radio_off := _icon("radio_unchecked.svg")
	var arrow_down := _icon("arrow_down.svg")
	var dot := _icon("dot.svg")
	var empty := _icon("empty.svg")

	t.set_icon("checked", "CheckBox", check_on)
	t.set_icon("unchecked", "CheckBox", check_off)
	t.set_icon("radio_checked", "CheckBox", radio_on)
	t.set_icon("radio_unchecked", "CheckBox", radio_off)

	t.set_icon("arrow", "OptionButton", arrow_down)

	t.set_icon("up", "SpinBox", _icon("arrow_up.svg"))
	t.set_icon("down", "SpinBox", arrow_down)

	# 弹出菜单：仅当前选项用圆点标记，其余不显示任何标记
	t.set_icon("checked", "PopupMenu", dot)
	t.set_icon("radio_checked", "PopupMenu", dot)
	t.set_icon("unchecked", "PopupMenu", empty)
	t.set_icon("radio_unchecked", "PopupMenu", empty)


# ---------- 常量 ----------

static func _constants(t: Theme) -> void:
	t.set_constant("separation", "BoxContainer", ThemePalette.SEP_BOX)
	t.set_constant("h_separation", "GridContainer", ThemePalette.SEP_GRID)
	t.set_constant("v_separation", "GridContainer", ThemePalette.SEP_GRID)
	for m in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		t.set_constant(m, "MarginContainer", ThemePalette.PAGE_MARGIN)
	t.set_constant("separation", "Separator", ThemePalette.SEP_SEPARATOR)

	# 图标与文字间距（CheckBox 继承 Button）
	t.set_constant("h_separation", "Button", 6)


# ---------- 自定义控件类型 ----------

static func _custom_types(t: Theme) -> void:
	# 开关（自绘）
	t.set_color("on_color", "Switch", ThemePalette.SUCCESS)
	t.set_color("off_color", "Switch", ThemePalette.BORDER_STRONG)
	t.set_color("knob_color", "Switch", ThemePalette.SURFACE)

	# 长按按钮的按压进度条（自绘）。控件优先按自己的 theme_type_variation 找这个颜色，
	# 找不到才回落到 LongPressButton 的默认值 —— 所以下面给 DangerButton 单独配一个：
	# 「立即执行」是红底按钮，蓝进度条压在上面看不清。
	t.set_color("progress_color", "LongPressButton", Color(ThemePalette.ACCENT, 0.85))
	t.set_color("progress_color", "DangerButton", Color(ThemePalette.TEXT_ON_ACCENT, 0.5))

	# 环形进度条（自绘）
	t.set_color("track_color", "CircularProgressBar", ThemePalette.SURFACE_ALT)
	t.set_color("progress_color", "CircularProgressBar", ThemePalette.ACCENT)
	t.set_color("text_color", "CircularProgressBar", ThemePalette.TEXT)

	# 日志面板（RichTextLabel 的变体）：等宽感的小字 + 卡片底色
	t.set_type_variation("LogView", "RichTextLabel")
	t.set_color("default_color", "LogView", ThemePalette.TEXT_SEC)
	t.set_font_size("normal_font_size", "LogView", ThemePalette.FONT_SM)
	t.set_stylebox("normal", "LogView", _sb(ThemePalette.SURFACE, ThemePalette.BORDER,
			ThemePalette.RADIUS_SM, 1, ThemePalette.PAD_INPUT_H, ThemePalette.PAD_INPUT_V))

	# 状态点（自绘圆点）：颜色**不自带**，由控件读自己 theme_type_variation 对应的
	# StatusOk/StatusWarn/StatusError/StatusIdle 的 font_color —— 这样状态色仍然只有
	# 一处定义（下面的 _add_label_variation），新增状态不用改两个地方。
	t.set_constant("dot_radius", "StatusDot", int(ThemePalette.DOT_RADIUS))
	t.set_constant("dot_halo", "StatusDot", int(ThemePalette.DOT_HALO_WIDTH))


# ---------- 类型变体（语义化样式） ----------

static func _type_variations(t: Theme) -> void:
	# 语义按钮：颜色按**视觉权重**分，不是按好看分。
	#   AccentButton  = 主操作，一屏最多一个
	#   DangerButton  = 有破坏性/安全相关的操作（停止、立即执行）
	#   SuccessButton = 确认执行
	var semantic := [
		["AccentButton", ThemePalette.ACCENT, ThemePalette.ACCENT_HOVER, ThemePalette.ACCENT_PRESS],
		["DangerButton", ThemePalette.DANGER, ThemePalette.DANGER_HOVER, ThemePalette.DANGER_PRESS],
		["SuccessButton", ThemePalette.SUCCESS, ThemePalette.SUCCESS_HOVER, ThemePalette.SUCCESS_PRESS],
	]
	for spec in semantic:
		_add_button_variation(t, spec[0], spec[1], spec[2], spec[3], ThemePalette.TEXT_ON_ACCENT)
	# 幽灵按钮（无底色无边框、只有文字，悬停才浮出浅底）：卡片/工具栏里的次要操作
	_add_ghost_variation(t)

	# 标签变体：字号/颜色只在这里定义，业务脚本不要 add_theme_font_size_override
	# （否则「全局可调」就断了），需要新层级时在这里加一个变体即可。
	_add_label_variation(t, "PageTitle", ThemePalette.TEXT, ThemePalette.FONT_XL)
	_add_label_variation(t, "SectionTitle", ThemePalette.TEXT, ThemePalette.FONT_XL)
	_add_label_variation(t, "CardTitle", ThemePalette.ACCENT, ThemePalette.FONT_LG)
	_add_label_variation(t, "Subtitle", ThemePalette.TEXT_SEC, ThemePalette.FONT_SM)
	_add_label_variation(t, "Caption", ThemePalette.TEXT_SEC, ThemePalette.FONT_XS)
	# 路径用等宽感的小字：一眼能看出「这是个文件路径」而不是正文
	_add_label_variation(t, "PathLabel", ThemePalette.TEXT_SEC, ThemePalette.FONT_XS)

	# 状态标签：用文字色表达状态，**不要用 modulate 染深色文字**（会越乘越暗、读不清）。
	# StatusDot 也读这四个变体的 font_color，所以状态色的唯一定义就在这里。
	_add_label_variation(t, "StatusIdle", ThemePalette.TEXT_SEC, ThemePalette.FONT_MD)
	_add_label_variation(t, "StatusOk", ThemePalette.SUCCESS, ThemePalette.FONT_MD)
	_add_label_variation(t, "StatusWarn", ThemePalette.WARNING, ThemePalette.FONT_MD)
	_add_label_variation(t, "StatusError", ThemePalette.DANGER, ThemePalette.FONT_MD)
	# 状态卡里的「值」：比正文醒目一点，且用等宽感对齐数字
	_add_label_variation(t, "ValueText", ThemePalette.TEXT, ThemePalette.FONT_MD)
	# 倒计时对话框中间那个大数字
	_add_label_variation(t, "CountdownNumber", ThemePalette.TEXT, ThemePalette.FONT_XXL)


static func _add_label_variation(t: Theme, type_name: String, color: Color, size: int) -> void:
	t.set_type_variation(type_name, "Label")
	t.set_color("font_color", type_name, color)
	t.set_font_size("font_size", type_name, size)


# ---------- 工具 ----------

## 设置 Label/RichTextLabel 的 default_color / font_color。
static func _set_text_colors(t: Theme, typ: String, c: Color) -> void:
	if typ == "Label":
		t.set_color("font_color", typ, c)
	else:
		t.set_color("default_color", typ, c)


## 构建一个 StyleBoxFlat。
static func _sb(bg: Color, border: Color, radius: int, bw: int,
		pad_h := 0.0, pad_v := 0.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	if bw > 0:
		sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_right = pad_h
	sb.content_margin_bottom = pad_v
	return sb


## 焦点描边：只画边框（draw_center=false），叠加在 base 之上不遮挡背景。
static func _outline(color: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.draw_center = false
	sb.border_color = color
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(radius)
	return sb


static func _apply_button_styles(t: Theme, typ: String,
		normal: StyleBox, hover: StyleBox, pressed: StyleBox,
		disabled: StyleBox, focus: StyleBox) -> void:
	t.set_stylebox("normal", typ, normal)
	t.set_stylebox("hover", typ, hover)
	t.set_stylebox("pressed", typ, pressed)
	t.set_stylebox("disabled", typ, disabled)
	t.set_stylebox("focus", typ, focus)


static func _add_button_variation(t: Theme, type_name: String,
		bg: Color, bg_hover: Color, bg_pressed: Color, text: Color,
		pad_h := ThemePalette.PAD_BUTTON_H, pad_v := ThemePalette.PAD_BUTTON_V) -> void:
	t.set_type_variation(type_name, "Button")
	t.set_color("font_color", type_name, text)
	t.set_color("font_hover_color", type_name, text)
	t.set_color("font_pressed_color", type_name, text)
	t.set_color("font_focus_color", type_name, text)
	t.set_color("font_hover_pressed_color", type_name, text)
	t.set_color("font_disabled_color", type_name, Color(text, 0.6))

	var normal := _sb(bg, _TRANSPARENT, ThemePalette.RADIUS_SM, 0, pad_h, pad_v)
	var hover := _sb(bg_hover, _TRANSPARENT, ThemePalette.RADIUS_SM, 0, pad_h, pad_v)
	var pressed := _sb(bg_pressed, _TRANSPARENT, ThemePalette.RADIUS_SM, 0, pad_h, pad_v)
	var disabled := _sb(Color(bg, 0.4), _TRANSPARENT, ThemePalette.RADIUS_SM, 0, pad_h, pad_v)
	_apply_button_styles(t, type_name, normal, hover, pressed, disabled,
			_outline(bg, ThemePalette.RADIUS_SM))
	t.set_stylebox("hover_pressed", type_name, pressed)


static func _add_ghost_variation(t: Theme) -> void:
	t.set_type_variation("GhostButton", "Button")
	t.set_color("font_color", "GhostButton", ThemePalette.ACCENT)
	t.set_color("font_hover_color", "GhostButton", ThemePalette.ACCENT_HOVER)
	t.set_color("font_pressed_color", "GhostButton", ThemePalette.ACCENT_PRESS)
	t.set_color("font_focus_color", "GhostButton", ThemePalette.ACCENT)
	t.set_color("font_hover_pressed_color", "GhostButton", ThemePalette.ACCENT_PRESS)
	t.set_color("font_disabled_color", "GhostButton", ThemePalette.TEXT_DIS)

	var empty := _sb(_TRANSPARENT, _TRANSPARENT, ThemePalette.RADIUS_SM, 0,
			ThemePalette.PAD_BUTTON_H, ThemePalette.PAD_BUTTON_V)
	var hover := _sb(ThemePalette.ACCENT_SOFT, _TRANSPARENT, ThemePalette.RADIUS_SM, 0,
			ThemePalette.PAD_BUTTON_H, ThemePalette.PAD_BUTTON_V)
	_apply_button_styles(t, "GhostButton", empty, hover, hover, empty,
			_outline(ThemePalette.ACCENT, ThemePalette.RADIUS_SM))
	t.set_stylebox("hover_pressed", "GhostButton", hover)


static func _icon(name: String) -> Texture2D:
	return load("res://themes/icons/" + name) as Texture2D
