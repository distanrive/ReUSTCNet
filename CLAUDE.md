# ReUSTCNet — 开发约定

USTC 有线网自动登录/断线重连工具。**Godot 4.7 前端（纯 GDScript，无 Python 后端）**。

界面与主题体系从 [Godot4GUI](../Godot4GUI) 模板裁剪而来（设计令牌 → 主题工厂 → 全局 Theme，
加上一批可复用控件）。模板里那份更完整的约定（控件全表、表格行内按钮、性能红线等）仍在
`D:\python_file\Godot4GUI\CLAUDE.md`，本项目只保留用得上的部分。

## 技术栈

- **Godot 4.7.x**（标准版，GDScript，非 .NET）。渲染器默认 `forward_plus` + Windows 上的 `vulkan`。
- **没有 Python 后端，也没有 autoload 形式的网络层** —— 本工具的负载是「HTTP 轮询 + 状态机 +
  注册表/进程调用」，正好落在 `gdscript-only-guide.md` 判据表的第一行「纯 GDScript，不要后端」。
  收益是交付一个 exe、目标机器不装任何运行时。
- 本机 Godot：`D:\Program Files\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe`
  （用**带 `_console` 的那个**，否则看不到 print 与报错）。
- 本机 Python（只在做一次性核对、生成字节表时用）：`C:\Users\YH\.conda\envs\normal\python.exe`
- 本地 Godot 文档（英文 MD）：`D:\python_sourse\Godot Engine 4.7 documentation in English MD`
  查控件主题项名、确认 API 签名都看这里（`gdd_*.md`）。**不要靠记忆写 API** ——
  这个项目里已经因为「以为 `Crypto.encrypt` 收裸密钥」「以为 `get_theme_color` 有带默认值的重载」
  「以为 `OS.execute` 有 working_directory」各撞过一次。

## 目录结构

```
scripts/
├── app.gd                  # 主界面：建界面 / 绑定配置 / 接核心逻辑的信号（约 600 行）
├── autoload/
│   ├── theme_manager.gd    # 启动时构建并应用全局主题
│   ├── app_shell.gd        # 窗口尺寸、DPI 缩放、配置文件路径与落盘
│   ├── app_config.gd       # 业务配置（[app] 段）+ 旧 config.json 导入
│   └── instance_guard.gd   # 单实例 + 唤起已有窗口（TCP 端口当锁）
├── theme/
│   ├── theme_palette.gd    # 设计令牌（颜色/圆角/字号/间距，**样式唯一可调来源**）
│   └── theme_factory.gd    # 由令牌构建完整 Theme
├── ui/                     # 可复用控件（都是 class_name，业务里直接 new()）
└── core/                   # 纯逻辑，**不引用任何 UI**
    ├── wlt_client.gd       # HTTP 交互 + 响应解码 + 页面判据
    ├── net_monitor.gd      # 监控状态机（主线程协程）
    ├── app_paths.gd        # 可写目录探测 / 日志目录 / command.bat 查找
    ├── secret_store.gd     # 密码加解密（AES-256-CBC）
    ├── win_registry.gd     # 注册表原语（reg.exe）
    ├── win_system.gd       # 开机自启项、系统代理开关（带业务语义）
    ├── win_shell.gd        # 起进程（阻塞/非阻塞两种）
    ├── command_scheduler.gd# 定时执行指令
    └── log_store.gd        # 日志落盘 + 轮转 + 清理
```

分层规则：`ui/` 不依赖 `core/`；`core/` 不依赖 `ui/`，也不依赖 `app.gd`；
`app.gd` 是唯一把它们接起来的地方。

## 运行与验证

```bash
GODOT="D:/Program Files/Godot_v4.7.2-stable_win64/Godot_v4.7.2-stable_win64_console.exe"

# 1) 新建 class_name 脚本后先刷全局类名缓存（否则报 Identifier not declared）
"$GODOT" --headless --path . --import

# 2) 单脚本语法检查（autoload 不加载，报 NetClient 之类的名字未定义属正常；
#    本项目没有这类 autoload 引用问题，但仍以第 3 条为准）
"$GODOT" --headless --path . --check-only --script scripts/app.gd

# 3) 跑主场景 N 帧后退出，看运行期报错（_draw / 信号 / 空引用都在这一步暴露）
"$GODOT" --headless --path . --quit-after 180

# 4) 平台相关部分的自检（改 core/ 里的编解码、注册表、加解密后必跑）
"$GODOT" --headless --path . --script res://tools/self_check.gd
```

改完界面后想**看**排版（headless 看不出来），临时写个 SceneTree 脚本把界面渲染成 PNG：

```gdscript
extends SceneTree
func _initialize() -> void: _run()
func _run() -> void:
    var app: Control = load("res://scenes/app.tscn").instantiate()
    root.add_child(app)
    for _i in 25:
        await process_frame
    await RenderingServer.frame_post_draw
    root.get_texture().get_image().save_png("D:/somewhere/shot.png")
    quit()
```

```bash
"$GODOT" --path . --script res://_shot.gd -- --ui-scale=1.25
```

命令行的 `--` 之后是用户参数（`OS.get_cmdline_user_args()`）：`--ui-scale=1.5`、`--reset-window`、
`--no-instance-guard`。

## 打包

```bat
build.bat              :: 导出 release + 冒烟测试 + 压 rar（PACK=rar）
build.bat debug        :: 导出 debug 版（带 console 包装，能看 print）
build.bat run          :: 导出后直接启动 exe（测「导出后」的行为时用）
build.bat test         :: 只导出 + 冒烟测试
build.bat templates    :: 列出已安装的导出模板（排查模板缺失）
```

配置在 `build_config.bat`（换机器只改这个文件）。脚本会自动查出 Godot 版本、
据此定位 `%APPDATA%\Godot\export_templates\<版本>\`，所以不用手填版本号。

产物是 **两个文件**：`dist\ReUSTCNet.exe`（引擎本体，约 104 MB）+ `dist\ReUSTCNet.pck`
（我们的项目数据，约 130 KB）。**分发时必须一起给，缺 pck 起不来。**

### `build.bat` / `build_config.bat` 的两个硬约束

这两个文件**必须是纯 ASCII + CRLF**。不是风格问题，是 cmd 的硬要求，三条都实测踩过：

- **非 ASCII + 代码页 65001 = cmd 解析错位，注释会被当成命令执行。**
  Godot 启动时会把控制台代码页设成 UTF-8，而我们的脚本要调 Godot，
  所以脚本自己也会 `chcp 65001`。这个组合下 cmd 逐行读 .bat 的字节偏移会算错，
  症状是报一堆 `'xxx' is not recognized as an internal or external command`，
  而 `xxx` 正是注释行的尾巴。
- **GBK + `chcp 936` 也不行**：解析是对的，但**每次调完 Godot 之后的中文 echo 全变乱码**
  （Godot 把代码页改成 UTF-8 了，之后的 GBK 字节就被当成 UTF-8 解）。所以编解码两条路都不通，
  只能让文件本身不含非 ASCII。
- **只有 LF 没有 CRLF = cmd 会吃掉字符**，症状是 `'OT_EXE'`、`'cho'`、`'h'` 这种半截命令。

同理，**`if ... ( ... )` 块里的 `echo` 不能出现没转义的 `)`** —— 它会提前闭合块，
后面的文字被当成命令执行（这次报的是 `not was unexpected at this time`，
因为 `not nested inside...` 里的 `not` 被当成了命令名）。要么写成 `^)`，要么整句避开圆括号。

中文的维护说明写在本文件里，不要写进 .bat。

### 体积（已解决：104 MB → 34 MB）

exe **就是 Godot 引擎本体**，我们的项目数据只占 126 KB —— 所以调资源/导入设置毫无意义，
只能换一个自己编译的引擎。现在用的是自编译精简模板：

| | 官方模板 | 自编译精简模板 | 旧版 Python 发布包 |
| --- | --- | --- | --- |
| exe | 104.1 MB | **33.9 MB** | ~17 MB |
| rar 发布包 | 27.8 MB | **8.9 MB** | 18.9 MB |

**重新编译模板的完整步骤**（`tools/build_template.sh` 里每一条关闭项都写了理由）：

```bash
# 一次性准备（本机已装好）
#   1. SCons:      <conda>/Scripts/scons.exe   （pip install scons）
#   2. MinGW-w64:  winget install BrechtSanders.WinLibs.POSIX.UCRT \
#                    --version 14.2.0-12.0.0-r2 --source winget ...
#      **必须带 --source winget**：msstore 源的证书有问题会直接报 0x8a15005e。
#      **必须是 POSIX 线程模型**（Godot 硬要求）。装完在
#      %LOCALAPPDATA%\Microsoft\WinGet\Packages\...\mingw64\bin\gcc.exe
#   3. Godot 源码: git clone --depth 1 --branch 4.7.2-stable \
#                    https://github.com/godotengine/godot.git D:\godot-build\godot
#      （Godot 4.7 不用子模块，第三方库直接内联在仓库里，克隆约 430 MB）
# 然后：
bash tools/build_template.sh          # 20 核约 4 分钟
# 产物: D:\godot-build\godot\bin\godot.windows.template_release.x86_64.exe
```

模板路径写在 `build_config.bat` 的 `CUSTOM_TEMPLATE`；`build.bat` 每次导出前会把它
拷进 `%APPDATA%\Godot\export_templates\<版本>\windows_release_x86_64.exe`，
并把官方模板**备份一次**为 `windows_release_x86_64.official.bak`。
`export_presets.cfg` 保持可移植（`custom_template/release` 留空），换机器只改 `build_config.bat`。

#### 关模块时的三个坑（都是实测撞出来的，别再犯）

- **`module_webp_enabled=no` 会让所有贴图加载失败**。Godot 的「无损」纹理导入
  （`compress/mode=0`）内部就是用 WebP 存的，`.ctex` 里装的是 WebP 编码的图。
  症状是所有 `themes/icons/*.svg` 报
  `Failed loading resource` + `Condition "img.is_null() || img->is_empty()" is true`。
  （第一次就是这么炸的，是 `build.bat` 的冒烟测试抓出来的。）
- **`disable_advanced_gui=yes` 不能用**：它会砍掉 `OptionButton` / `PopupMenu` / `SpinBox` /
  `RichTextLabel` / `AcceptDialog` —— 这些我们**全都在用**（出口下拉、菜单、数值框、日志区、提示框）。
- **`module_svg_enabled=no` 不能用**：`themes/icons/*.svg` 全靠它。
- 必须保留的还有 `text_server_adv`（界面全中文，fallback 文本服务器对 CJK 没把握）和
  `glslang`（运行时着色器编译）。
- 编译时要显式加 `d3d12=no winrt=no accesskit=no`：它们各自需要额外的 SDK 依赖，
  缺了会在配置阶段直接报错退出（好消息是这个过程只要几秒）。
- **`optimize=size_extra` 是安全的**：在 Godot 里它只影响 3 个头文件（字符串缓存之类的微调），
  不会砍渲染器。

## GDScript 约定

- 可复用控件用 `class_name` 声明；复合控件的子节点在 `_init()` 里建，
  保证 `new()` 之后就能访问（`TitledGroup.content`、`LabeledLineEdit.line_edit` 都是这个规矩）。
- **UI 全部用 GDScript 代码构建**（类 PyQt）。`scenes/app.tscn` 里只有一个挂脚本的空 `Control`。
- **样式只走主题**：颜色/字号用 `theme_type_variation`，**不要**在业务脚本里
  `add_theme_color_override` / `add_theme_font_size_override`。缺层级就在
  `theme_factory.gd` 的 `_type_variations()` 里加一个变体，缺颜色就在
  `_custom_types()` 里加一条。布局用的 `add_theme_constant_override("separation", N)` 是例外，允许。
- **改样式只编辑 `scripts/theme/theme_palette.gd`**。所有颜色、圆角、字号、间距、窗口尺寸都在那里。
- 可用的类型变体：
  - 按钮：`AccentButton`（主操作，一屏最多一个）/ `DangerButton`（有破坏性）/ `SuccessButton` / `GhostButton`（卡片里的次要操作：无底色无边框）
  - 标签：`PageTitle` / `SectionTitle` / `CardTitle` / `Subtitle` / `Caption` / `PathLabel` / `ValueText` / `CountdownNumber`
  - 状态：`StatusIdle` / `StatusOk` / `StatusWarn` / `StatusError`（`StatusDot` 也读这四个的 `font_color`，
    所以**状态色的唯一定义**在 `theme_factory.gd`，加一种状态不用改两处）
  - 日志：`LogView`（`RichTextLabel` 的变体）
- **数字格式**：GDScript 的 `%` 不支持 `%e` / `%g`（会运行时报 unsupported format character）。
- 给 `Range` 派生的控件（`SpinBox` / `Slider`）赋值**会发出 `value_changed`**。
  `app.gd` 的 `_load_into_ui()` 必须排在 `_connect_signals()` **之前**，否则载入配置会反过来触发一次保存。

## 这个项目特有的坑（都踩过）

### 编码：中文判据的地基

`wlt.ustc.edu.cn` 的响应头**不带 charset**，判据又全是中文串比对 —— 解错编码会**静默失效**
（表现为「网络是好的却一直报断网」）。规则见 `wlt_client.gd` 的 `decode_body()`，要点：

- **Windows 上 `get_string_from_multibyte_char()` 只认 `"gb2312"` / `"gb18030"`**。
  `"936"` / `"GBK"` / `"cp936"` 都会返回**空串**并打一行 `Conversion failed: Unknown encoding`。
- `to_multibyte_char_buffer()` **会带上结尾的 `\0`** —— 不清掉，每个中文表单参数末尾就多一个 `%00`。
- 判断「是不是 UTF-8」要用**字节结构校验**，不要数替换字符：GBK 几乎接受任意字节对，
  把 UTF-8 字节喂给 GBK 解出来往往一个替换字符都没有、只是全是错字。
- 改这里之后**必须跑 `tools/self_check.gd`**（里面有「真实 GB2312 页面片段不被误判」这条回归）。

### `Label` 的最小宽度 = 整串文字的宽度

把长文字（`"1 教育网出口（国际，仅用教育网访问，适合看文献）"`、日志目录路径、
`"重连失败：域名解析失败（DNS 不通？）"`）放进 `HBoxContainer` / `GridContainer`，
它会**把整个面板的最低宽度顶大**，窗口装不下就横向溢出（表现为右边的按钮被切掉）。
处理办法（三选一，都用到过）：

1. 界面上只放**短文本**，完整内容进 `tooltip`（`_status_text`、`_v_export` 就是这么做的）；
2. 长选项用 `_stacked()` 单独占一行铺满宽度，别跟标签挤一行；
3. 状态文字用「短状态 + 完整消息进日志」的结构（`app.gd` 的 `_on_status_changed`）。

`clip_text = true` **不能**减小最小宽度；`autowrap_mode != OFF` 才能，但会引入换行。

### 窗口尺寸与缩放

- 拉伸模式是 `disabled`，界面按**逻辑像素**排版，`AppShell` 把 `content_scale_factor`
  设成屏幕 DPI 系数。所以「最大化」是显示更多内容，不是把界面整体放大。
- `project.godot` 的 `window/size/viewport_width/height` 是**物理**像素，
  **不要**指望它给出想要的逻辑尺寸 —— 首次运行的默认大小由 `AppShell._apply_default_size()`
  按缩放系数换算，并钳到可用屏幕区域内。
- `Window.min_size` 也是物理像素，`AppShell` 会乘上缩放系数。
- `DisplayServer.screen_get_scale()` 在 Windows 上**恒返回 1.0**（官方文档：只在
  Android/iOS/Web/macOS/Linux-Wayland 上实现），所以要回退到 `screen_get_dpi() / 96`。

### 线程与协程

**这个项目没有 `Thread`、没有 `Mutex`，也不要加。** 监控是主线程上的一条协程
（`net_monitor.gd`），靠 `await` 等 HTTP 与 `SceneTreeTimer`。取消用「代号」：

```gdscript
stop() → _generation += 1
循环里每次 await 之后 → if _stale(gen): return
```

等待还被切成 0.25 秒一片，所以「停止」立刻生效。**不要写成 `stop()` 只置一个标志位、
循环里隔很久才复查** —— 旧版 Python 实现就是这么写的，结果「停止」之后还会偷偷重连一次
（见 `docs/code-review.md` 的 A1）。

`await` 的写法注意：`var r := await http.request_completed`（多参数信号 await 返回 Array）。

### Windows 调用

- 全部收口在 `win_registry.gd` / `win_system.gd` / `win_shell.gd`，参数一律用
  `PackedStringArray` 传给 `OS.execute` / `OS.create_process`，**不经 shell**（Godot 会给每个参数加引号，
  带空格的键名也安全 —— 自检里有这一条）。
- `OS.execute` **没有 `working_directory` 参数**。要指定工作目录就拼
  `cmd /c "cd /d <dir> && <命令>"`（见 `WinShell.run_cmd_in_dir`）。
- `OS.execute` **阻塞主线程**，只用于 `reg` 这种几十毫秒的命令；
  会长时间跑的（`command.bat`）用 `OS.create_process`。
- `open_console` 默认 `false`，不会弹黑框；只有显式设 `true` 且目标是控制台程序才会。
- `OS.create_process` 起的进程**不随 Godot 退出而结束**（引擎文档明确写了）。
  本项目的用途正是要它活下去，所以不接管；要收的话记得先 `OS.is_process_running(pid)` 再 `OS.kill(pid)`。

### 密码与密钥

- 密钥是一串 32 字节随机数，存 `HKCU\Software\ReUSTCNet`；配置文件里只有 `enc:` + base64。
- 注册表不可写时降级到程序目录下的 `.key`，**必须**在界面上给出明确警告（`app.gd` 的 `_log_startup_info`）。
- **不要**把 `OS.get_unique_id()` 混进密钥：官方文档明确写它「可能因重装系统/升级/更换硬件而变化，
  不要用于安全用途」，混进去只会多一个「密码突然解不开」的失败模式。
- `Crypto.encrypt()` 要的是 `CryptoKey` 资源，不是裸密钥 —— 对称加密用 `AESContext`，
  CBC 模式下自己补 PKCS#7 填充（数据必须是 16 字节整数倍）。

### 托盘与窗口

- 托盘用 `StatusIndicator` 节点（`icon` + `tooltip` + `menu: NodePath` 指向一个 `PopupMenu`），
  文档注明 **implemented on macOS and Windows**。启动时用
  `DisplayServer.has_feature(DisplayServer.FEATURE_STATUS_INDICATOR)` 探测，不支持就隐藏相关开关。
- `PopupMenu` 里**分隔线也占下标**，所以按下标改禁用态会错位 ——
  用 `get_item_index(id)` 按 id 反查（`app.gd` 的 `_tray_set_disabled`）。
- 关闭窗口的行为自己管：`get_tree().auto_accept_quit = false`
  + `NOTIFICATION_WM_CLOSE_REQUEST` 里决定「隐藏到托盘」还是「退出」。

## 加一个新控件（什么时候加、怎么加）

Godot 原生 `Button / LineEdit / SpinBox / OptionButton / CheckBox / ProgressBar / PopupMenu`
+ 全局主题已经够用。只有下面三种情况才自绘：

1. 原生没有：`StatusDot`（状态点）、`Switch`（开关）、`CircularProgressBar`（环形倒计时）；
2. 原生能力不够：`LongPressButton`（长按防误触）；
3. 交互形态特殊：`TitledGroup`（带标题的卡片）。

加的时候守四条（现有控件都这么写）：

```gdscript
class_name MyGauge                    # 1) 全局唯一的 class_name
extends Control

var value := 0.0:
    set(v):
        value = v
        queue_redraw()                # 2) 数据变了就重绘

func _init() -> void:                 # 3) 复合控件的子节点在 _init 里建
    add_child(_label)

func _theme_color(name, fallback):    # 4) 颜色走主题类型；注意 Godot 4 的
    ...                               #    get_theme_color/constant 只有 (名字, 类型) 两个参数、
                                      #    没有带默认值的重载，要用 has_theme_* 自己兜
```

然后在 `theme_factory.gd` 的 `_custom_types()` 里注册颜色/字号，并在本文件的控件表里补一行。

## 改完之后的最小验收清单

- [ ] `--import` 无 `SCRIPT ERROR`
- [ ] `--quit-after 240` 无 `ERROR:`（业务日志里的错误不算）
- [ ] `tools/self_check.gd` 全部通过
- [ ] 动过 `build.bat` / `build_config.bat` / `export_presets.cfg`：`build.bat test` 能跑通
      （导出 + 冒烟测试都过）
- [ ] 起界面看一眼：中文不折行、窗口不横向溢出、150% 缩放下不挤
- [ ] 动过 `instance_guard.gd`：起两个进程，**第二个应在 1 秒内自己退出**
      （`--quit-after 1800` 的第一个进程放后台，再起第二个并计时；第二个跑满十几秒就是没认出来）
- [ ] 动过 `net_monitor.gd`：点「停止」后日志**不再出现新行**（等 60 秒以上确认）
- [ ] 动过 `command_scheduler.gd`：点「取消」后当天还能再触发
