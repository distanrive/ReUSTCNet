class_name ThemePalette
extends RefCounted
## 设计令牌（Design Tokens）——全项目样式唯一可调来源。
##
## 所有颜色、圆角、字号、间距都在这里集中定义；`ThemeFactory` 据此构建全局主题，
## 自绘控件（Switch / StatusDot / CircularProgressBar / LongPressButton）也从此读取默认值。
## 想统一调整样式时，只改这一个文件即可全局生效，无需触碰任何控件脚本。

# ---------- 中性色 ----------
const BG := Color(0.957, 0.961, 0.969)            # 应用背景          #f4f5f7
const SURFACE := Color(1.0, 1.0, 1.0)             # 卡片/输入底色     #ffffff
const SURFACE_ALT := Color(0.929, 0.937, 0.949)   # 悬停底色          #edf0f2
const BORDER := Color(0.847, 0.867, 0.898)        # 常规边框          #d8dde5
const BORDER_STRONG := Color(0.761, 0.788, 0.827) # 强边框/按下       #c2c9d3

# ---------- 文字 ----------
const TEXT := Color(0.122, 0.153, 0.200)          # 主文字            #1f2733
const TEXT_SEC := Color(0.333, 0.376, 0.431)      # 次要文字          #55606e
const TEXT_DIS := Color(0.596, 0.631, 0.675)      # 禁用文字          #98a1ac
const TEXT_ON_ACCENT := Color(1.0, 1.0, 1.0)      # 强调底上的文字     #ffffff

# ---------- 强调 / 主色 ----------
const ACCENT := Color(0.290, 0.565, 0.850)        # 主色              #4a90d9
const ACCENT_HOVER := Color(0.243, 0.486, 0.745)
const ACCENT_PRESS := Color(0.204, 0.408, 0.627)
const ACCENT_SOFT := Color(0.882, 0.933, 0.973)   # 选中浅底          #e1eef8
const ACCENT_SOFT_HOVER := Color(0.827, 0.902, 0.961)

# ---------- 语义色 ----------
const SUCCESS := Color(0.184, 0.627, 0.435)       # 正常              #2fa06f
const SUCCESS_HOVER := Color(0.157, 0.533, 0.369)
const SUCCESS_PRESS := Color(0.133, 0.447, 0.310)

const DANGER := Color(0.839, 0.271, 0.271)        # 危险 / 断开       #d64545
const DANGER_HOVER := Color(0.729, 0.220, 0.220)
const DANGER_PRESS := Color(0.604, 0.180, 0.180)

const WARNING := Color(0.851, 0.541, 0.122)       # 警告              #d98a1f

# ---------- 状态点（StatusDot，自绘） ----------
# 颜色不存在这里：StatusDot 读自己 theme_type_variation 对应的
# StatusOk/StatusWarn/StatusError/StatusIdle 变体的 font_color，
# 这样「状态色的定义」仍然只有 ThemeFactory._type_variations() 一处。
const DOT_RADIUS := 5.0          # 实心圆半径
const DOT_HALO_WIDTH := 2.0      # 外圈光晕宽度（0 = 不画光晕）

# ---------- 圆角 ----------
const RADIUS_SM := 4
const RADIUS_MD := 6
const RADIUS_LG := 8

# ---------- 字号 ----------
const FONT_XS := 11
const FONT_SM := 12
const FONT_MD := 14          # 全局默认正文字号
const FONT_LG := 16
const FONT_XL := 20
const FONT_XXL := 28         # 倒计时对话框中间那个大数字

# ---------- 间距 / 留白（StyleBox content margin） ----------
const PAD_BUTTON_H := 10.0
const PAD_BUTTON_V := 6.0
const PAD_INPUT_H := 8.0
const PAD_INPUT_V := 5.0
const PAD_PANEL := 12.0
const PAD_POPUP := 6.0
const PAD_CARD_V := 10.0        # 卡片内标题与内容的垂直间距（TitledGroup）

# ---------- 滚动条（ScrollBar / ScrollContainer） ----------
# **滚动条的粗细完全由样式盒的最小尺寸决定**（= `content_margin` 左 + 右），所以这一项
# 不能是 0。它曾经等价于 0（`theme_factory._sb()` 的 pad 默认值是 0），实测后果是
# `VScrollBar.get_combined_minimum_size() == (0, 0)`：轨道和滑块都画不出来，
# 页面上只剩贴着右缘的一条淡痕，抓不住也点不中 —— **而且不报任何错**，
# 跑 headless、跑场景都干干净净，只有截图放大才看得出来。
const SCROLLBAR_W := 12.0

# ---------- 主题常量（theme constants，均为 int） ----------
const SEP_BOX := 8            # HBox/VBox 子项间距
const SEP_GRID := 8           # Grid 间距
const PAGE_MARGIN := 16       # 页面边距（整个界面到窗口边缘的距离）
const SEP_SEPARATOR := 4      # 分隔线留白

# ---------- 页面级布局（改这里即可统一缩放） ----------
# 卡片最小宽度。左列那一沓（账户 / 定时执行指令 / 启动与外观）和右列的「网络」都按它对，
# 于是两列看起来一样宽 —— 它们的内容用不了这么宽，定这个值纯粹是为了**视觉配平**。
#
# 注意这只是下限：「网络」那张卡里有一串很长的出口名
# （"1 教育网出口（国际，仅用教育网访问，适合看文献）"），Label / OptionButton 的
# 最小宽度就是整串文字的宽度，实测 402px —— 它才是布局真正的固有下限，比这里的 400 还大一点。
#
# **左列（账户 / 定时执行指令 / 启动与外观）不参与扩展**，宽度就钉在这个值上；
# 多出来的宽度全给右列（网络 / 运行日志）。这是试出来的：Godot 的 GridContainer 在
# 「某一列的固有宽度超过剩余空间一半」时会**把那一列钉死、把剩下的全塞给另一列**，
# 于是让左列也参与扩展的话，左列会白白胖胖、右边的日志反而更窄。见 app.gd 的 _build_ui。
const CARD_MIN_W := 400.0
const ROW_LABEL_W := 132.0      # 设置行里「标签」列的宽度 —— 所有卡片共用同一列宽，
                                # 于是各卡片的标签在同一条竖线上，输入框/开关也从同一位置起
const LOG_MIN_H := 180.0        # 日志面板最小高度

# ---------- 窗口（AppShell autoload） ----------
# 用户能把窗口拖到的最小尺寸（**逻辑**像素），交给 AppShell 在启动时乘上缩放系数设成 min_size。
# 拖到这个尺寸以下**不会**把布局挤坏：整页有 ScrollContainer 兜底，出滚动条就是。
# 所以这个值只是「再小就不像个控制台了」的下限，不是「内容的固有最小宽度」。
const WINDOW_MIN_W := 820.0
const WINDOW_MIN_H := 620.0
# 首次运行时的默认窗口大小（逻辑像素；AppShell 会按缩放换成物理像素，并钳到屏幕内）。
#
# **这两个数是量出来的，不是估的**：整套卡片排完版后的固有最小尺寸是
# 814 × 641（`--script` 里打印 `GridContainer.get_combined_minimum_size()` 得到），
# 加上页面边距 32 与竖向滚动条 12 → 整个内容最少要 858 × 733。
# 比这更小就会一进去就看见滚动条 —— 「初始窗口要能囊括所有项目」说的就是这个。
#
# 宽度**贴着固有宽度**（858 + 一点余量 = 900）就是刻意的：左列固定 400，
# 多出来的宽度全归右列，所以窗口每加宽 100px，右列的「网络 / 运行日志」就胖 100px ——
# 给到 1100 那会儿右列有 656px，界面横向明显空荡。900 下右列约 456，和左列配平。
# （高度给 760 是因为固有的是 733，再加一点免得一进去就出竖向滚动条。）
const WINDOW_DEFAULT_W := 900.0
const WINDOW_DEFAULT_H := 760.0

# ---------- 界面缩放（AppShell / UiScaleOption） ----------
# 可选缩放档位；0.0 这一档是「跟随系统 DPI」的哨兵值（见 app_shell.gd 的 detect_system_scale）。
const UI_SCALE_FOLLOW_SYSTEM := 0.0
const UI_SCALE_STEPS := [1.0, 1.25, 1.5, 1.75, 2.0]
const UI_SCALE_MIN := 0.75
const UI_SCALE_MAX := 3.0
