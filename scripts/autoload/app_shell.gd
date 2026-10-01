extends Node
## 应用外壳（Autoload）：窗口尺寸、系统 DPI 缩放、界面缩放记忆。
##
## 为什么需要它：本工程的拉伸模式是 `disabled`（见 project.godot 的说明），
## 于是「界面在高 DPI 屏上太小」这件事必须由代码补上 —— Godot 官方对非游戏应用的
## 建议就是「disabled + 在 autoload 里把 stretch scale 设成屏幕缩放系数」。
##
## 做三件事：
##   1. **最小窗口尺寸**：拖太小会把左栏挤坏，这里设 `Window.min_size`；
##   2. **界面缩放**：`content_scale_factor`。默认「跟随系统」，
##      用 `screen_get_scale()`；Windows 上它恒为 1.0（官方文档明确「仅在 Android/iOS/Web/
##      macOS/Linux Wayland 上实现」），所以回退到 `screen_get_dpi() / 96`。
##      界面里可用 `UiScaleOption` 手动选，或命令行 `--ui-scale=1.5` 覆盖。
##   3. **记忆**：窗口尺寸/是否最大化 + 缩放档位存配置文件，重启不丢。
##
## 配置文件位置走 `AppPaths.config_file()`（优先 exe 同级，写不进去才退到 user://），
## 它同时是**业务配置**的落点：业务脚本用 `AppShell.config` 这个 ConfigFile 读写自己的段。

signal ui_scale_changed(scale: float)

const _SEC_UI := "ui"
const _SEC_WINDOW := "window"

## ConfigFile 实例本身就是对外接口（业务可复用它存参数），所以不藏起来。
var config := ConfigFile.new()

## 配置文件的实际路径。暴露出来是为了在界面上告诉用户「配置存在哪」。
var config_path := ""

var _scale_setting := ThemePalette.UI_SCALE_FOLLOW_SYSTEM   # 0 = 跟随系统
var _scale_from_cli := false     # 命令行给的缩放是临时覆盖，不写回配置文件
var _restore_window := true
var _save_countdown := -1.0      # >0 表示有待落盘的改动（防抖）


func _ready() -> void:
	var cli := _parse_cli()
	config_path = AppPaths.config_file()
	AppPaths.ensure_dir(config_path.get_base_dir())
	config.load(config_path)     # 首次运行没有这个文件，返回非 OK，忽略即可

	var source := "跟随系统"
	if cli.has("ui_scale"):
		_scale_setting = cli["ui_scale"]
		_scale_from_cli = true
		source = "命令行 --ui-scale"
	elif config.has_section_key(_SEC_UI, "scale"):
		_scale_setting = float(config.get_value(_SEC_UI, "scale"))
		source = config_path
	if cli.has("reset_window"):
		_restore_window = false

	_apply_scale()
	if _restore_window:
		_restore_window_geometry()

	var win := get_window()
	win.size_changed.connect(_on_window_changed)
	win.close_requested.connect(_flush_now)
	set_process(true)
	# 打一行出来：「界面怎么这么大/这么小」「配置写到哪去了」在别人机器上是最常被问的问题，
	# 有这行就能立刻区分是系统 DPI、配置文件还是命令行参数导致的。
	print("[AppShell] 界面缩放 %.2f×（来源：%s），窗口 %d×%d，配置文件 %s" % [
		_effective_scale(), source, win.size.x, win.size.y, config_path])
	# 把两个原始读数也打出来：「界面怎么比别人的小/大」这类问题，答案全在这三个数里。
	# `screen_get_scale()` 在 Windows 上恒定 1.0（文档：只在 Android/iOS/Web/macOS/
	# Linux-Wayland 上实现），所以实际生效的是 `screen_get_dpi() / 96`；
	# 而 dpi 读出来是多少，取决于**进程有没有向 Windows 声明自己是 DPI-aware** ——
	# 不声明的话系统一律按 96 报，界面就整整小一圈（编辑器与导出版可能不一样）。
	print("[AppShell] screen_get_scale=%.2f  screen_get_dpi=%d  screen_get_size=%s" % [
		DisplayServer.screen_get_scale(), DisplayServer.screen_get_dpi(),
		DisplayServer.screen_get_size()])


func _process(delta: float) -> void:
	if _save_countdown < 0.0:
		return
	_save_countdown -= delta
	if _save_countdown <= 0.0:
		_flush_now()


# ---------------------------------------------------------------- 对外接口

## 当前生效的缩放系数（已把「跟随系统」解析成具体数值）。
func get_effective_scale() -> float:
	return _effective_scale()


## 用户设定的档位：0 = 跟随系统，其余为具体倍数。
func get_ui_scale_setting() -> float:
	return _scale_setting


func is_following_system() -> bool:
	return _scale_setting <= ThemePalette.UI_SCALE_FOLLOW_SYSTEM


## 设置缩放档位（0 = 跟随系统）。会立即生效并记忆下来。
func set_ui_scale(scale: float) -> void:
	if scale > ThemePalette.UI_SCALE_FOLLOW_SYSTEM:
		scale = clampf(scale, ThemePalette.UI_SCALE_MIN, ThemePalette.UI_SCALE_MAX)
	if is_equal_approx(scale, _scale_setting):
		return
	_scale_setting = scale
	# 用户自己在界面里选过了，这次选择就是「要记住的」—— 覆盖掉命令行的临时性
	_scale_from_cli = false
	_apply_scale()
	_flush_now()


## 把自己写进 `config` 的内容落盘（业务脚本改了 `config` 之后调它一下）。
func save_config() -> void:
	_flush_now()


## 设置窗口标题。**要改标题就用这个函数**，别直接写 `Window.title`，也别自己调 DisplayServer。
##
## 这里面的两步都是必需的（在 Godot 4.7.2 / Windows 上实测过三种写法）：
##
## | 写法 | OS 上的标题实际变成 |
## |---|---|
## | `get_window().title = "X"` | `X (DEBUG)` —— 调试版下引擎会把后缀加回来 |
## | `DisplayServer.window_set_title("X")` 直接写在 `_ready()` 里 | `项目名 (DEBUG)` —— 被引擎的默认标题盖掉 |
## | 本函数（等一帧 + `DisplayServer`） | `X` ✅ |
##
## 「等一帧」不能省：引擎是在**窗口首帧显示时**才写那一次默认标题的，晚于 `_ready()`。
## 正式导出（Release）本来就没有这个后缀，所以这纯粹是开发期观感问题。
func set_window_title(text: String) -> void:
	await get_tree().process_frame
	DisplayServer.window_set_title(text)


## 系统/屏幕的缩放系数。
##
## 顺序：`screen_get_scale()` 优先（macOS/Wayland/移动端上是准的），
## 它没实现时（Windows 恒返回 1.0）回退到 DPI 猜测 —— 96 dpi = 100%，144 dpi = 150%。
func detect_system_scale() -> float:
	var s := DisplayServer.screen_get_scale()
	if s > 1.001:
		return clampf(s, ThemePalette.UI_SCALE_MIN, ThemePalette.UI_SCALE_MAX)
	var dpi := DisplayServer.screen_get_dpi()
	if dpi <= 0:
		return 1.0           # 该平台不支持查询，只能按 100% 处理
	return clampf(float(dpi) / 96.0, ThemePalette.UI_SCALE_MIN, ThemePalette.UI_SCALE_MAX)


# ---------------------------------------------------------------- 内部

func _effective_scale() -> float:
	if _scale_setting <= ThemePalette.UI_SCALE_FOLLOW_SYSTEM:
		return detect_system_scale()
	return clampf(_scale_setting, ThemePalette.UI_SCALE_MIN, ThemePalette.UI_SCALE_MAX)


func _apply_scale() -> void:
	var factor := _effective_scale()
	# 拉伸模式是 disabled：界面仍按原生像素绘制（清晰），只是整体放大 factor 倍。
	get_tree().root.content_scale_factor = factor
	_update_min_size(factor)
	ui_scale_changed.emit(factor)


func _update_min_size(factor: float) -> void:
	var win := get_window()
	if win == null:
		return
	# Window.min_size 是**物理像素**，所以要跟着缩放乘一遍，
	# 否则 150% 缩放下界面会被压进一个太小的窗口里。
	win.min_size = Vector2i(
			int(round(ThemePalette.WINDOW_MIN_W * factor)),
			int(round(ThemePalette.WINDOW_MIN_H * factor)))


func _restore_window_geometry() -> void:
	var win := get_window()
	if win == null:
		return
	if bool(config.get_value(_SEC_WINDOW, "maximized", false)):
		win.mode = Window.MODE_MAXIMIZED
		return
	var w := int(config.get_value(_SEC_WINDOW, "width", 0))
	var h := int(config.get_value(_SEC_WINDOW, "height", 0))
	if w > 0 and h > 0:
		win.size = Vector2i(maxi(w, win.min_size.x), maxi(h, win.min_size.y))
	else:
		_apply_default_size()


## 首次运行（还没有记过窗口尺寸）时给一个合适的默认大小。
##
## 不能靠 `project.godot` 的 `viewport_width/height` 来定：拉伸模式是 disabled，
## 那两个值是**物理**像素，而界面是按逻辑像素排的 —— 屏幕缩放 125% 时 1080 物理只有
## 864 逻辑，比最小尺寸还小，窗口会被 `min_size` 顶回去，结果每次都在最小尺寸下打开。
## 所以这里按当前缩放系数换算出「想要的逻辑尺寸 → 物理尺寸」，并且不超出可用屏幕区域。
func _apply_default_size() -> void:
	var win := get_window()
	var factor := _effective_scale()
	var want := Vector2i(int(round(ThemePalette.WINDOW_DEFAULT_W * factor)),
			int(round(ThemePalette.WINDOW_DEFAULT_H * factor)))
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	if screen.size.x > 0 and screen.size.y > 0:
		# 留一点余量，别顶满屏幕（否则任务栏/窗口边框会把它挤到刚好的边缘）
		want.x = mini(want.x, screen.size.x - 60)
		want.y = mini(want.y, screen.size.y - 80)
	win.size = Vector2i(maxi(want.x, win.min_size.x), maxi(want.y, win.min_size.y))


func _on_window_changed() -> void:
	# 拖窗口会连续触发几十次 size_changed，防抖一下再落盘
	_save_countdown = 0.8


func _flush_now() -> void:
	_save_countdown = -1.0
	var win := get_window()
	if win == null:
		return
	# 本进程是「多余的第二个实例」时不要落盘：它几百毫秒后就退出了，
	# 这一写会把正在运行的那个实例刚改过的配置覆盖回去（见 InstanceGuard 的说明）。
	if InstanceGuard.quitting_as_secondary:
		return
	# 命令行来的缩放是**临时覆盖**，不写回文件 —— 否则一次 `--ui-scale=1.5` 的试跑
	# 会在用户随后拖动窗口时被顺手记成永久设置，下次启动莫名其妙就是 1.5×。
	if not _scale_from_cli:
		config.set_value(_SEC_UI, "scale", _scale_setting)
	config.set_value(_SEC_WINDOW, "maximized", win.mode == Window.MODE_MAXIMIZED)
	if win.mode == Window.MODE_WINDOWED:
		config.set_value(_SEC_WINDOW, "width", win.size.x)
		config.set_value(_SEC_WINDOW, "height", win.size.y)
	var err := config.save(config_path)
	if err != OK:
		push_warning("[AppShell] 无法写入 %s（err=%d）" % [config_path, err])


func _notification(what: int) -> void:
	# Alt+F4 / 点关闭按钮时也要把窗口状态存下来
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_flush_now()


func _parse_cli() -> Dictionary:
	var out := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ui-scale="):
			out["ui_scale"] = arg.substr("--ui-scale=".length()).to_float()
		elif arg == "--reset-window":
			out["reset_window"] = true
	return out
