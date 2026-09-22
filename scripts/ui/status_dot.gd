class_name StatusDot
extends Control
## 状态点：一个实心圆 + 一圈半透明光晕，用来在状态卡里表示「当前处于什么状态」。
##
## 颜色**不在这里定义**：它读自己 `theme_type_variation` 对应标签变体的 `font_color`。
## 所以状态色的唯一定义仍是 `ThemeFactory._type_variations()` 里的
## `StatusIdle` / `StatusOk` / `StatusWarn` / `StatusError`，圆点与文字永远同色，
## 将来加一种状态也不用改两处。
##
## 用法：
##   var dot := StatusDot.new()
##   dot.set_status("StatusError")     # 或 dot.theme_type_variation = "StatusError"
##
## 光晕不是装饰：断网时的红点在浅色卡片上单靠实心圆边界不够醒目，外圈一点同色半透明
## 能让人一眼扫到，同时保持「不是图标、不引入素材」这条线。

const _IDLE := "StatusIdle"

var _radius := ThemePalette.DOT_RADIUS
var _halo := ThemePalette.DOT_HALO_WIDTH


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if theme_type_variation == &"":
		theme_type_variation = _IDLE
	# 主题里可以覆盖这两个尺寸（见 ThemeFactory 的 _custom_types）。
	# `get_theme_constant` 在 Godot 4 里只有 (名字, 类型) 两个参数、没有默认值重载，
	# 所以「找不到就用令牌里的默认值」得自己写（模板里那几个自绘控件也是这么做的）。
	if has_theme_constant(&"dot_radius", &"StatusDot"):
		_radius = float(get_theme_constant(&"dot_radius", &"StatusDot"))
	if has_theme_constant(&"dot_halo", &"StatusDot"):
		_halo = float(get_theme_constant(&"dot_halo", &"StatusDot"))
	var d := (_radius + _halo) * 2.0
	custom_minimum_size = Vector2(d, d)
	resized.connect(queue_redraw)


## 切换状态（传 StatusIdle / StatusOk / StatusWarn / StatusError）。
func set_status(variation: String) -> void:
	if theme_type_variation == StringName(variation):
		return
	theme_type_variation = StringName(variation)
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()


func _draw() -> void:
	var color := _status_color()
	var center := size / 2.0

	# 画在「控件中心」而不是「左上角固定半径」：这样状态点放进任意行高的容器里都居中
	if _halo > 0.0:
		draw_circle(center, _radius + _halo, Color(color, 0.22))
	draw_circle(center, _radius, color)


## 从自己的类型变体对应的标签变体里取状态色。
func _status_color() -> Color:
	var variation := theme_type_variation
	if variation == &"":
		variation = _IDLE
	if has_theme_color(&"font_color", variation):
		return get_theme_color(&"font_color", variation)
	return ThemePalette.TEXT_SEC
