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

# ---------- 主题常量（theme constants，均为 int） ----------
const SEP_BOX := 8            # HBox/VBox 子项间距
const SEP_GRID := 8           # Grid 间距
const PAGE_MARGIN := 16       # 页面边距（整个界面到窗口边缘的距离）
const SEP_SEPARATOR := 4      # 分隔线留白

# ---------- 页面级布局（改这里即可统一缩放） ----------
const SIDEBAR_W := 340.0        # 左侧设置栏宽度
const ROW_LABEL_W := 132.0      # 设置行里「标签」列的宽度 —— 所有卡片共用同一列宽，
                                # 于是各卡片的标签在同一条竖线上，输入框/开关也从同一位置起
const LOG_MIN_H := 180.0        # 日志面板最小高度

# ---------- 窗口（AppShell autoload） ----------
# 用户能把窗口拖到的最小尺寸（**逻辑**像素）。低于这个值布局会开始互相挤压
# （左栏出现滚动条、状态卡换行），所以交给 AppShell 在启动时乘上缩放系数设成 min_size。
const WINDOW_MIN_W := 900.0
const WINDOW_MIN_H := 620.0
# 首次运行时的默认窗口大小（逻辑像素；AppShell 会按缩放换成物理像素，并钳到屏幕内）
const WINDOW_DEFAULT_W := 1060.0
const WINDOW_DEFAULT_H := 700.0

# ---------- 界面缩放（AppShell / UiScaleOption） ----------
# 可选缩放档位；0.0 这一档是「跟随系统 DPI」的哨兵值（见 app_shell.gd 的 detect_system_scale）。
const UI_SCALE_FOLLOW_SYSTEM := 0.0
const UI_SCALE_STEPS := [1.0, 1.25, 1.5, 1.75, 2.0]
const UI_SCALE_MIN := 0.75
const UI_SCALE_MAX := 3.0
