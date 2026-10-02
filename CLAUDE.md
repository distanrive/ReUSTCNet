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
native_window.gdextension   # 原生扩展的清单（Godot 靠扫这个文件发现扩展）
bin/                        # 原生扩展的产物（*.dll，由 tools/build_native_window.sh 生成）
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
tools/
├── build_template.sh       # 编译精简引擎模板
├── build_native_window.sh  # 编译原生窗口扩展（bin/native_window.windows.x86_64.dll）
├── native_window/          # 那个扩展的 C 源码 + vendored 的 GDExtension 接口头
└── self_check.gd           # 平台相关部分的自检
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

产物是 **三个文件**：

| 文件 | 大小 | 缺了会怎样 |
| --- | --- | --- |
| `dist\ReUSTCNet.exe` | ~34 MB | 就是引擎本体（见下面「体积」） |
| `dist\ReUSTCNet.pck` | ~260 KB | **起不来** |
| `dist\native_window.windows.x86_64.dll` | ~58 KB | 能起来，但「关窗后从任务栏消失」退化成最小化（启动日志里会写一行警告） |

`.dll` 由 `build.bat` 的第 `[2/5]` 步（`bash tools/build_native_window.sh`）编出来，
Godot 在导出时会自动把它拷到 exe 旁边。

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

### 体积（104 MB → 29.4 MB）

exe **就是 Godot 引擎本体**，我们的项目数据只占 190 KB —— 所以调资源/导入设置毫无意义，
只能换一个自己编译的引擎。现在是自编译精简模板 + 类级裁剪，**保留 Vulkan**：

| | 官方模板 | 精简模板 | + 安全开关 | + 类级裁剪（现在） |
| --- | --- | --- | --- | --- |
| exe | 104.1 MB | 32.8 MB | 31.6 MB | **29.4 MB** |
| rar 发布包 | 27.8 MB | 8.6 MB | 8.1 MB | **7.5 MB** |

**两级杠杆，都别漏**：

1. **SCons 选项**（模块 + core 开关）—— 见 `tools/build_template.sh`，每条关闭项都写了理由。
   收益有限（3.7%），因为那些 `.o` 的体积大头是调试信息，LTO + section GC 之后留下的不多。
2. **类级裁剪**（`.gdbuild` 的 `disabled_classes`）—— 再省 7.8%。**这一级只能由编辑器 GUI 生成**：
   项目 → 工具 → Engine Compilation Configuration Editor → **Detect from Project** → Save As
   存成 `tools/reustcnet.gdbuild`。构建脚本会把它作为 `build_profile=` 传进去。

> **试过但放弃的**：`vulkan=no`（再省 2.6 MB）—— 要连带把工程的 `rendering_method` 改成
> `gl_compatibility`，收益和类裁剪相当却动了渲染路径，不划算。界面渲染实测两者只有
> 字形边缘的亚像素差（2.17% 像素不同、布局配色一致），哪天真要省可以走这条路。
> **UPX** 也不用（会破坏内嵌 PCK 和图标替换，且报毒）。

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

#### 关开关时的坑（都是实测撞出来的，别再犯）

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
- **`brotli=no` 会让所有内置字体加载失败**（**关掉的是编译器依赖，不是「用不到的功能」**）。
  Godot 的内置字体全是 WOFF2：`thirdparty/fonts/` 下的 `Inter_Regular/Inter_Bold`
  （默认 UI 字体）与 `DroidSansFallback`（**中文兜底字体**），而 WOFF2 解压靠
  FreeType + brotli（`modules/text_server_adv/SCsub` 里的 `FT_CONFIG_OPTION_USE_BROTLI`）。
  关掉之后两种字体都解不出来，文字**静默退化成 Windows 系统字体** ——
  英文与数字变成衬线体（Times 那一路）、中文变宋体式的细笔画，界面整体"字变小了、变淡了"，
  **日志里一行错都不报**。这一项只占 0.3 MB，别省。
  （症状和当年 `module_webp=no` 把贴图全搞挂是同一类：都是「看着用不到、其实是内部依赖」。）
- **`optimize=size_extra` 是安全的**：在 Godot 里它只影响 3 个头文件（字符串缓存之类的微调），
  不会砍渲染器。

#### 类级裁剪（`tools/reustcnet.gdbuild`）的三个坑

那份 profile 是**编辑器 GUI 生成**的（没有 CLI，`EditorBuildProfileManager::_detect_from_project()`
没暴露给脚本），所以它会被反复覆盖。**每次重新 Detect 之后都要回来核对这四条**：

1. **`forward_plus_renderer` / `rendering_device` / `vulkan` 必须是 `true`。**
   Detect 是**照着工程当时的状态**判断的 —— 如果那一刻工程的 `rendering_method` 不是
   forward_plus（比如调试别的渲染器时），它会把这几个判成「用不到」并写成 `false`，
   编出来的模板就是个跑不了 forward_plus 的引擎，而且**要到导出后才暴露**。
2. **`GDExtension` 不能留在禁用表里。** 检测器只看工程里的场景与脚本，
   **看不到「我们运行时会加载 `native_window.gdextension`」** —— 这正是官方文档列出的
   盲区之一（「GDExtension」被明确点名）。禁掉它等于自废武功。
3. **开关的语义是「这个选项最终取什么值」**，不是「禁用与否」：
   `module_openxr_enabled: false` = 关掉；`disable_3d: true` = 打开这个开关。
   别反着读。
4. **类裁剪的验证只能用导出版。** 编辑器跑的是编辑器本体（自带全部类），
   `--import` / `--quit-after 240` / `self_check.gd` **都证明不了模板是好的** ——
   必须 `build.bat test` 跑冒烟测试，再真跑一次导出后的 exe
   （自检里那条「原生窗口扩展」也要用窗口模式跑，headless 下会跳过）。

漏掉一个类的表现是**脚本解析失败**（`Identifier not declared`），在导出的冒烟测试里一定会炸，
所以只要老老实实跑 steps 4，就不会带着坏模板发出去。真正危险的是「某个类只出现在很久才走一次的
分支里」—— 本项目最远的一条是**定时执行指令的倒计时对话框**，验证时至少要手动触发一次。

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
  - 日志：`LogView` 是**控件**（`scripts/ui/log_view.gd`），不是类型变体；
    它内部那个 `RichTextLabel` 用 `LogText` 变体（小一号的字），级别配色读 `LogView` 类型
    （`info_color` / `ok_color` / `warn_color` / `error_color` / `system_color` / `time_color` / `source_color`）
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

### 滚动条：粗细完全由样式盒的 `content_margin` 决定

**给 0 就没有滚动条。** 自定义主题里 `ScrollBar` 的 `scroll` / `grabber` 样式盒曾经是
`_sb(..., pad=0)`，实测 `VScrollBar.get_combined_minimum_size() == (0, 0)` ——
轨道和滑块都画不出来，界面上只剩贴着右缘的一条淡痕，抓不住也点不中，
而且**不报任何错**（跑 headless、跑场景都干干净净，只有截图放大才看得出来）。

宽度取自 `ThemePalette.SCROLLBAR_W`（12px），`tools/self_check.gd` 里有断言钉着它。
另外**没定义的图标会回落到引擎默认主题**，而默认滚动条两端是有箭头的 ——
本项目用全透明的 `empty.svg` 把它们压掉了（尺寸仍是 8×8，点两端步进还在）。

### 界面布局：一个 3×3 网格（运行日志占右下 2×2）

排布是：

```
账户          ｜ 网络          ｜ 运行状态
定时执行指令   ｜  运行日志（占右下 2×2）
启动与外观     ｜  运行日志（续）
```

左边一列（账户 / 定时执行指令 / 启动与外观）和上面一行共用「账户」那一格。

**Godot 的 `GridContainer` 不支持跨格**，所以这个排布是用**嵌套**实现的：
外层是个 2 列的 `GridContainer`，第 1 行右格塞一个 `HBoxContainer`（里面横排网络 + 运行状态），
第 2 行左格塞一个 `VBoxContainer`（里面竖排定时执行指令 + 启动与外观）。
几何上与外层那个 3×3（380 + 402 + 340 + 两道 12px 缝 = 1226）**完全一致**，
「运行日志」的左边界与「账户」的右边界严格重合。

几条容易改坏的地方：

- **`GridContainer` 把富余宽度在可扩展列之间「平均」分，根本不看 `size_flags_stretch_ratio`**
  （源码里就是 `remaining_space.width / col_expanded.size()`）。想靠 ratio 调列宽是白费劲。
- 它的分配还有个反直觉之处：**某一列的固有宽度超过剩余空间一半时，那一列会被钉死，
  剩下的宽度全塞给另一列**。所以让左列也参与扩展的话，默认尺寸下会变成 442｜402｜400
  —— 左列白白胖胖，右边两张反而更窄。现在的做法是**左列不设 EXPAND**、
  宽度钉在 `ThemePalette.CARD_MIN_W` 上，多出来的宽度全给右边 → 400｜422｜422。
- 外面套一层**页面级 `ScrollContainer`**：窗口比内容小时整体滚动，两行一起动。
  横向用 `AUTO` 而不是 `DISABLED` —— 这套布局的固有最小宽度有一千两百多像素
  （「网络」卡里那串长出口名的宽度），屏幕小/缩放大的机器上出个横向滚动条兜底，
  总比把右边裁掉强。**不要**给某一列单独套 `ScrollContainer`：那就成了「一边滚一边不动」，
  接缝立刻错开。
- 日志框要填满整张卡片，需要 `card.content.size_flags_vertical = SIZE_EXPAND_FILL`：
  卡片被网格拉高之后，内容容器不跟着伸的话，日志框只占自己的最小高度，下面留一大片白。
- **左列的「最后一张卡」必须设 `size_flags_vertical = SIZE_EXPAND_FILL`**，
  否则它的底边和右边「运行日志」的底边会差一截。原因是：左列是个 VBox
  （定时执行指令 / 启动与外观），两张卡都只有自然高度，而网格已把这一格拉到和日志一样高 ——
  多出来的那截如果没人接手，会留在 VBox 底部，也就是**卡片外面**。
  让最后一张卡长起来，余白就移到卡片内部（和上面被撑高的「账户」卡片表现一致）。
- `WINDOW_DEFAULT_W/H` 是**量出来的**（打印 `GridContainer.get_combined_minimum_size()`），
  不是估的。改了卡片内容记得重新量一遍，否则「初始窗口能装下所有内容」这条会悄悄失效。

### 窗口尺寸与缩放

- 拉伸模式是 `disabled`，界面按**逻辑像素**排版，`AppShell` 把 `content_scale_factor`
  设成屏幕 DPI 系数。所以「最大化」是显示更多内容，不是把界面整体放大。
- `project.godot` 的 `window/size/viewport_width/height` 是**物理**像素，
  **不要**指望它给出想要的逻辑尺寸 —— 首次运行的默认大小由 `AppShell._apply_default_size()`
  按缩放系数换算，并钳到可用屏幕区域内。
- `Window.min_size` 也是物理像素，`AppShell` 会乘上缩放系数。
- `DisplayServer.screen_get_scale()` 在 Windows 上**恒返回 1.0**（官方文档：只在
  Android/iOS/Web/macOS/Linux-Wayland 上实现），所以要回退到 `screen_get_dpi() / 96`。
- **别把「配置里选了具体档位」误读成「系统 DPI 没读对」**（我误诊过一次）：
  启动日志那行的 `来源` 字段就是答案 —— 写的是**配置文件路径**，说明档位是**配置里存着的**
  （`scale=1.0` = 用户选了 100%），这时 `_effective_scale()` 直接返回它、**压根不去问系统 DPI**；
  只有值是 `0.0` 那个哨兵（`UI_SCALE_FOLLOW_SYSTEM`）时才是「跟随系统」，才会调
  `detect_system_scale()`。要验证系统 DPI，得先把配置删了或者在界面里选「跟随系统」。

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

### 定时执行指令：`configure()` 不等于 `start()`

`CommandScheduler` 要两步：`configure()` 只把参数收进去，**真正起轮询协程的是 `start(host)`**。
`app.gd` 里曾经只调了 `configure()`、漏了 `start()` —— 后果是这个功能**从重写以来一次都没触发过**，
而且**不报任何错**：配置读得对、触发后的记账逻辑写得好、界面也齐，就是没有任何东西在轮询。
这一类静默失效只有真去等一分钟才看得见，所以验收清单里那条别偷懒。

`start()` 有 `if _host != null: return` 的幂等保护，重复调用无害；
放在 `_connect_signals()` **之后**（`triggered` 先接上再开跑）。

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

### 开机自启：启动文件夹里的快捷方式，**不要写注册表 Run 键**

`HKCU\...\CurrentVersion\Run` 是杀软启发式里权重最高的持久化位置之一，
一个没有代码签名的 exe 往那儿写值很容易被直接拦掉（本程序就被拦过）。
所以 `WinSystem.enable_autostart()` 改成在
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\` 放一个 `ReUSTCNet.lnk` ——
效果一样（登录后自动启动），但是没有那个特征。

- 建 `.lnk` 要借 PowerShell 的 `WScript.Shell` COM 接口（GDScript 没有这个能力），
  见 `WinShell.run_powershell()`。它刻意用 `-Command` 而不是「临时 .ps1 + `-File`」：
  后者要额外带 `-ExecutionPolicy Bypass`、还要往磁盘丢脚本文件，两样都是杀软特征。
- **`script` 里只能出现单引号**：Godot 给参数加引号时不转义里面的 `"`，
  双引号会把参数劈开。路径里的单引号用 `WinShell.ps_quote()` 翻倍转义。
- 实测建一次约 **0.75 秒**，而 `OS.execute` 阻塞主线程 —— 所以界面上先让一帧画出来
  （`await get_tree().process_frame`）再动手，否则用户看到的是「点了开关，窗口卡死」。
- `enable_autostart()` **认文件不认退出码**：COM 对象创建失败时 PowerShell 的
  退出码照样是 0（报错只走 stderr），只看退出码会让开关显示成开着、实际什么都没发生。
- **开关的初始状态永远是「关」**：程序自己不建那个快捷方式，也不「替用户保住原来的选择」。
  早期版本做过「删掉注册表项、顺手把快捷方式建好」，结果是升级完打开界面一看开关自己就是开的，
  像是程序擅自动了启动项 —— 现在只清不建。
- `WinSystem.cleanup_legacy_autostart()` 把旧版遗留在 `HKCU\...\Run` 里的项**静默删掉**
  （那个位置会被杀软拦），界面上不提示、日志里也不写。
  它在**还没有快捷方式时**才去查注册表，再被 `AppConfig.legacy_autostart_checked` 挡一层
  —— 查一次要起一个 `reg.exe`，不该每次启动都做。

### 图标：`config/icon` 管窗口、`windows_native_icon` 管任务栏、preset 管 exe

三处是**分开的**，只改一处会出现「Explorer 里是 A、任务栏里是 B」：

| 位置 | 设置项 | 管什么 |
| --- | --- | --- |
| `project.godot` | `application/config/icon` | 通用窗口图标（各平台），PNG |
| `project.godot` | `application/config/windows_native_icon` | **Windows 的任务栏/窗口图标**，ICO，启动时自动 `DisplayServer.set_native_icon()` |
| `export_presets.cfg` | `application/icon` | **exe 文件本身的图标**，ICO |

- 原来只设了前者的第一项（还是张 16×16 的 SVG），`icon.ico` 躺在工程根目录里
   **一处都没被引用** —— 这就是「为什么没用上 icon.ico」。
- `.ico` **必须含全部尺寸**（16/24/32/48/64/128/256）：官方文档明确写了，
  缺哪个尺寸，那个尺寸上就会退回**引擎默认的 Godot 图标**。
  原来的 `icon.ico` 只有 256×256 一档，就算引用了，Explorer 的小图标视图也会是 Godot 机器人。
- `icon.ico` 不是 Godot 认识的纹理格式，**不能**当 `config/icon`（那是要 import 的资源）。
  要 `set_native_icon()` 读的是**文件名**，所以得让它进 pck：
  `export_presets.cfg` 的 `include_filter="icon.ico"`（`all_resources` 模式不带非资源文件）。
- 托盘图标另有一份 `themes/icons/tray.png`（32×32）：托盘实际只显示 16~24 像素，
  拿 256×256 的图去缩会糊成一团。
- `icon.ico` / `icon.png` **进仓库**（`.gitignore` 里只留 `icon.psd` 那个源文件）。
  它们是三处图标设置的唯一来源，缺了导出会失败、窗口/托盘图标也会退回 Godot 默认图。
  README 顶部那张 logo 用的就是 `icon.png` —— 改图标时三处 + README 一起换。

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
- **「隐藏到托盘」必须借原生扩展**（见下一节）。Godot 自己做不到这件事，
  而旧代码是 `win.hide()` 之后读 `win.visible` —— 那**每一次**都会走进「隐藏失败」分支
  （`hide()` 必然失败，见下节），于是打一条看起来像偶发故障的警告、再去最小化。
- 隐藏期间把 `Engine.max_fps` 压到 10（`_HIDDEN_MAX_FPS`）：Godot 并不知道窗口没了，
  照常按 60fps 渲染，一个待在托盘里待机一整天的程序没必要一直烤 GPU。
  **别想着用 `render_target_update_mode` 停渲染** —— 那个属性只注册在 `SubViewport` 上
  （`ADD_PROPERTY` 写在 `SubViewport::_bind_methods` 里，虽然枚举是在 `viewport.h` 声明的），
  根窗口写上去是运行时报错。不压到 1fps 是因为托盘菜单也是 Godot 画的，1fps 下要等一秒才弹。

### 原生窗口扩展（`tools/native_window/`）

**为什么需要它**：Godot **从设计上禁止隐藏主窗口**，三条硬证据都在源码里：

| 证据 | 位置 |
| --- | --- |
| `ERR_FAIL_NULL_MSG(get_parent(), "Can't change visibility of main window.")` —— 主窗口（`get_tree().root`）没有父节点，`hide()` 必然失败 | `scene/main/window.cpp` 的 `Window::set_visible()` |
| `DisplayServer` 没有任何 hide 接口，最接近的只有 `window_set_mode(MINIMIZED)` | `gdd_1242_DisplayServer.md` |
| 主窗口**恒定**带 `WS_EX_APPWINDOW`（= 必须出现在任务栏），只有带外部父 HWND 时才跳过 | `display_server_windows.cpp` 的 `_get_window_style()` |
| `WINDOW_FLAG_POPUP` 明确拒绝主窗口 | 同上，`window_set_flag` |

所以要「关窗后任务栏上不留按钮」，只能拿 `DisplayServer.window_get_native_handle(WINDOW_HANDLE)`
得到 HWND，绕过引擎调 Win32 的 `ShowWindow`。GDScript 调不了 Win32，于是有了这个扩展。

- **手写 C，不依赖 godot-cpp**（`native_window.c` 顶部有完整理由）。整份代码只包两个函数，
  为它拉一整套 C++ 绑定（几百 MB + 一次长编译）不划算。
- 代价是**与 Godot 的 ABI 版本绑定**：`tools/native_window/gdextension_interface.h` 是从
  对应版本的 Godot 源码里拷来的（`core/extension/gdextension_interface.gen.h`），
  升级引擎要重新拷并核对结构体。本工程固定 4.7.2，`self_check.gd` 有探针兜底。
- **坑（撞过，崩溃现场极难查）**：`GDExtensionPropertyInfo.class_name` **不能给 NULL**。
  头文件里它是个指针，看着「没有类」就该填 NULL，但 Godot 侧的
  `PropertyInfo(const GDExtensionPropertyInfo &)` 是无条件解引用的 ——
  给 NULL 就是空指针，表现为**加载扩展时整个进程 signal 11 崩溃**，
  而且崩在 Godot 自己的代码里、堆栈没有符号。`hint_string` 同理（要空的 `String`，不是 NULL）。
- **GDScript 侧一律用 `ClassDB.class_call_static(&"NativeWindow", &"hide_window", hwnd)`
  这种动态写法**，不要在业务脚本里直接写类名：那样 .dll 一旦缺失就是**整个脚本编译不过**，
  连「退回最小化」的机会都没有。
- 扩展清单 `.gdextension` **不在 `res://` 里被扫到就不会加载**。Godot 运行期是从
  `.godot/extension_list.cfg` 读这份清单的，而那个文件由**编辑器扫描工程时**生成 ——
  新增扩展后要跑一次 `--import`（或开一次编辑器），否则 `ClassDB.class_exists("NativeWindow")`
  永远是 false，且**一句报错都没有**。
- 导出时 Godot 会自动把 `.dll` 拷到 exe 旁边（`dist/native_window.windows.x86_64.dll`），
  **不用**写进 `include_filter`。所以发布包是**三个文件**：exe + pck + dll。
- **`bin/` 里的 dll 是提交进仓库的**（不像 `icon.png` / `icon.ico` 那样只留在工作区）。
  理由是：清单文件在、库文件不在时，Godot **每次启动都会打三行 ERROR**
  （`GDExtension dynamic library not found`），虽然功能会优雅降级成最小化，
  但「`--quit-after 240` 无 ERROR」这条验收标准就过不去了。
  58 KB 而已，直接带上，克隆下来按 F5 就能跑。
  配套地，链接时加了 `-Wl,--no-insert-timestamp` 让**产物可复现** ——
  否则每次 build.bat 都会因为 PE 头里的时间戳让 git 显示「dll 被改过」。
- 改了它之后：`bash tools/build_native_window.sh` → `godot --headless --path . --import`
  → `godot --path . --script res://tools/self_check.gd`（最后那条是用**窗口模式**跑，
  它会用一个临时窗口真的隐藏/显示一次并断言 `IsWindowVisible`）。

## 加一个新控件（什么时候加、怎么加）

Godot 原生 `Button / LineEdit / SpinBox / OptionButton / CheckBox / ProgressBar / PopupMenu`
+ 全局主题已经够用。只有下面三种情况才自绘：

1. 原生没有：`StatusDot`（状态点）、`Switch`（开关）、`CircularProgressBar`（环形倒计时）、
   `LogView`（可回看、可复制、带行数上限的日志区）；
2. 原生能力不够：`LongPressButton`（长按防误触）；
3. 交互形态特殊：`TitledGroup`（带标题的卡片）。

日志**不要**再写成「一个 `Label` 反复 `text = msg`」—— 那样只能看见最后一条，
出问题想往回翻就没了。用 `LogView.append(text, level, source)`，`level` 走级别配色，
行数有上限、超出成块裁掉，文本里的方括号会自动转义（随便丢数据进去都不会被当成 BBCode）。

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
- [ ] 重编过模板（`tools/build_template.sh`）或动过 `tools/reustcnet.gdbuild`：
      先按「类级裁剪的三个坑」核对那四条（渲染开关 + GDExtension），
      再 `build.bat test`，最后**真跑一次导出的 exe**（窗口模式，看一眼界面 + 触发一次定时指令）。
      只跑编辑器是**查不出**模板问题的 —— 编辑器用的是它自己那套类
- [ ] 起界面看一眼：中文不折行、窗口不横向溢出、150% 缩放下不挤
      （窗口缩到最小尺寸 900×620 也要看一眼：应当只出竖向滚动条）
- [ ] 动过 `theme_palette.gd` / `theme_factory.gd`：`self_check.gd` 的滚动条两项过，
      并且**截图确认滚动条真的画出来了**（0 宽的那种坏法不报错，只有看图才发现）
- [ ] 动过开机自启：导出成 exe 后勾一次开关，确认
      `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ReUSTCNet.lnk` 出现了、
      指向当前 exe，再取消勾选确认它被删掉
- [ ] 动过图标设置：`build.bat test` 后确认 exe 图标是自定义的（不是 Godot 机器人），
      且 `icon.ico` 在 `dist\ReUSTCNet.pck` 里（`grep -a "res://icon.ico" dist\ReUSTCNet.pck`）
- [ ] 动过 `tools/native_window/` 或 `.gdextension`：`bash tools/build_native_window.sh`
      → `--import` → **用窗口模式**跑 `self_check.gd`（headless 下那一项会跳过），
      确认三条断言都过；再 `build.bat test`，确认 `dist\` 里有那个 dll、
      且导出后跑一次的日志里有「窗口隐藏扩展已加载」
- [ ] 动过界面布局：**截图看一眼**（`--script` 渲成 PNG）—— 三列宽度大致相等、
      接缝对齐、初始窗口 1300×760 下**不出现任何滚动条**。改过卡片内容后重新量
      `GridContainer.get_combined_minimum_size()`，必要时同步 `WINDOW_DEFAULT_W/H`
- [ ] 动过 `instance_guard.gd`：起两个进程，**第二个应在 1 秒内自己退出**
      （`--quit-after 1800` 的第一个进程放后台，再起第二个并计时；第二个跑满十几秒就是没认出来）
- [ ] 动过 `net_monitor.gd`：点「停止」后日志**不再出现新行**（等 60 秒以上确认）
- [ ] 动过 `command_scheduler.gd` 或 `app.gd` 的启动流程：把触发时间设到**一分钟之后**，
      **真等它响一次**（弹窗出现、日志里有「已触发」），再确认点「取消」后当天还能再触发。
      只跑 `--quit-after` 是**查不出**「`start()` 漏调」这种静默失效的（踩过）
