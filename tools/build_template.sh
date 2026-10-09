#!/bin/bash
# 编译 ReUSTCNet 专用的 Godot 4.7.2 精简导出模板。
#
# 这是「一次性」工具链脚本，不属于项目仓库；产物拷到项目后由 build.bat 使用。
# 目标：把 104 MB 的官方 Windows 模板压到 20 MB 上下。
#
# 关掉的模块依据（逐个核对过本项目用不用）：
#   * 纹理压缩/解码类（astcenc/bcdec/cvtt/etcpak/betsy/ktx/dds）—— 我们的贴图全是
#     compress/mode=0 无损导入，没有任何 VRAM 压缩纹理
#   * 图片格式类（bmp/tga/jpg/webp/hdr/tinyexr）—— 只有 PNG（core）与 SVG（保留 svg 模块）
#   * 3D 相关（fbx/gltf/csg/gridmap/vhacd/meshoptimizer/lightmapper_rd/raycast/
#     xatlas_unwrap/msdfgen/visual_shader/jolt_physics/godot_physics_3d）—— disable_3d=yes
#   * 音频（ogg/vorbis/mp3/theora/interactive_music）—— 程序无音频
#   * 网络（enet/websocket/webrtc/upnp/jsonrpc/multiplayer）—— 只用 HTTPRequest（core）
#   * XR（openxr/webxr/mobile_vr）、导航（navigation_2d/3d）、杂项（noise/camera/
#     objectdb_profiler/regex/zip/mono/cvtt）
# 必须保留的：
#   * svg          —— themes/icons/*.svg 全靠它
#   * text_server_adv —— 界面全是中文，fallback 文本服务器对 CJK 没把握
#   * glslang      —— 运行时着色器编译
#   * freetype / gdscript
#   * mbedtls      —— HTTPRequest 的 TLS 支持（core 的 AES 用的是 thirdparty 里的
#                     mbedtls，与本模块无关，关不关都不影响密码加解密）

set -e

# winget 把 MinGW 装在用户目录下的包里，路径每次可能不同，用 find 定位
GCC=$(find /c/Users/YH/AppData/Local/Microsoft/WinGet/Packages -maxdepth 5 -iname 'gcc.exe' 2>/dev/null | head -1)
if [ -z "$GCC" ]; then
    echo "[错误] 找不到 gcc.exe（winget 装的 MinGW）"
    exit 1
fi
export PATH="$(dirname "$GCC"):$PATH"
echo "编译器: $(gcc --version | head -1)"

SCONS="C:/Users/YH/.conda/envs/normal/Scripts/scons.exe"
[ -x "$SCONS" ] || { echo "[错误] 找不到 scons: $SCONS"; exit 1; }

# ---- 给 Godot 源码打上「chunk 长度行容错」补丁（必须，幂等）----
# 不开这个补丁，本程序在校园网上**一条请求都发不出去**：wlt.ustc.edu.cn 的分块长度行
# 末尾多一个空格（违反 RFC，但 curl/浏览器都容错），而 Godot 4.7 的 HTTP 客户端是严格的，
# 会把它判成 STATUS_CONNECTION_ERROR —— 表面看像"连接被断开"。完整的排查过程见
# tools/patch_godot_chunked.py 顶部。**用官方模板导出的 exe 会连不上**，所以这一步不能省。
PY="C:/Users/YH/.conda/envs/normal/python.exe"
[ -x "$PY" ] || PY="python"
"$PY" tools/patch_godot_chunked.py || { echo "[错误] 补丁未打上，别用官方模板导出（会连不上校园网）"; exit 1; }

# 注意 **webp 不能关**：Godot 的「无损」纹理导入（compress/mode=0）内部就是用 WebP
# 存的，.ctex 里装的是 WebP 编码的图。关掉它会让所有贴图在运行时加载失败
# （实测症状：`Failed loading resource: res://themes/icons/*.svg` +
#  `Condition "img.is_null() || img.is_empty()" is true`）。第一版就是栽在这上面，
# 是 build.bat 的冒烟测试抓出来的。
MODULES_OFF="astcenc basis_universal bcdec betsy bmp camera csg cvtt dds enet etcpak \
fbx gltf godot_physics_2d godot_physics_3d gridmap hdr interactive_music jolt_physics \
jpg jsonrpc ktx lightmapper_rd meshoptimizer mobile_vr mono mp3 msdfgen multiplayer \
navigation_2d navigation_3d noise objectdb_profiler ogg openxr raycast regex tga theora \
tinyexr upnp vhacd visual_shader vorbis webrtc websocket webxr xatlas_unwrap zip"

ARGS=""
for m in $MODULES_OFF; do
    ARGS="$ARGS module_${m}_enabled=no"
done

# 类级裁剪的 profile（`.gdbuild`）。**必须在 cd 之前算出绝对路径** ——
# 脚本马上要切到 Godot 源码目录去跑 scons，相对路径会指错地方。
# 用 cygpath 转成 Windows 路径：scons 是原生 Windows 进程，不认 /d/... 这种 MSYS 路径。
PROFILE_WIN="$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)/tools/reustcnet.gdbuild" 2>/dev/null || echo "")"
if [ -z "$PROFILE_WIN" ] || [ ! -f "$PROFILE_WIN" ]; then
    echo "[错误] 找不到类裁剪 profile: tools/reustcnet.gdbuild"
    exit 1
fi

cd /d/godot-build/godot

echo "开始编译（-j20，lto=full 的链接阶段会比较久）..."
echo "类裁剪 profile: $PROFILE_WIN"
echo "输出: bin/godot.windows.template_release.x86_64.exe"
echo

"$SCONS" -j20 \
    platform=windows \
    target=template_release \
    tools=no \
    arch=x86_64 \
    use_mingw=yes \
    production=yes \
    optimize=size_extra \
    lto=full \
    disable_3d=yes \
    disable_physics_2d=yes \
    disable_xr=yes \
    disable_navigation_2d=yes \
    disable_navigation_3d=yes \
    deprecated=no \
    minizip=no \
    sdl=no \
    builtin_pcre2_with_jit=no \
    disable_overrides=yes \
    d3d12=no \
    winrt=no \
    accesskit=no \
    "build_profile=$PROFILE_WIN" \
    $ARGS

# ---- 下面这一组是「core 开关」，与上面的模块开关**不是一回事**，别互相替代 ----
# disable_physics_2d —— 纯 GUI，没有任何 2D 物理。只关模块
#   （module_godot_physics_2d_enabled=no）的话，引擎还会留一条「退回 dummy server」的
#   死路径并在启动时打警告；这个 core 开关才是真正把它编掉。
# disable_xr / disable_navigation_2d/3d —— 同上：模块关了，节点与服务器还留着。
# disable_overrides  —— 不用 override.cfg。
# deprecated=no       —— 不要「兼容已废弃 API」的那一层。我们写的就是 4.7 的 API，
#                       扩展用的也都是现行接口（classdb_register_extension_class6 等）。
# minizip=no          —— 不用 ZIPReader / ZIPPacker（pck 不是 zip）。
#
# **brotli 千万别关**（踩过，而且症状极具迷惑性）：Godot 的内置字体全是 WOFF2 ——
# thirdparty/fonts/ 下的 Inter_Regular/Inter_Bold（默认 UI 字体）与
# DroidSansFallback（**中文兜底字体**），而 WOFF2 解压靠 FreeType + brotli
# （modules/text_server_adv/SCsub 里的 FT_CONFIG_OPTION_USE_BROTLI）。
# 关掉 brotli 的后果是：两种内置字体都加载不出来，文字**静默退化成 Windows 系统字体**
# （数字与英文变衬线体、中文变宋体那样的细笔画），界面看着"字变小了/变淡了"，
# 而日志里一行错都不报 —— 和当年 module_webp=no 把贴图全搞挂是同一类坑。
# sdl=no              —— **SDL3 在 Windows 上只用于手柄输入**（display_server_windows.cpp
#                       里唯一的用处就是 `JoypadSDL`），键盘鼠标 GUI 完全用不到。
#                        这一个能扔掉整个 SDL3。
# builtin_pcre2_with_jit=no —— 不用正则（wlt_client 的 IP 解析是手写扫描，见那里的注释）。
#
# ---- 刻意**不关**的 ----
# opengl3  —— Vulkan 不可用时（RDP / 虚拟机 / 老 Intel 核显）的兜底，工控机和远程桌面上
#             真会遇到，这点体积不值得省。相应地 vulkan 也保留（渲染器是 forward_plus）。
# mbedtls  —— HTTPRequest 的 TLS。wlt 站点现在是 http://，但换 https 只差一个字符，
#             把这条路留着。（core 的 AES 用的是 thirdparty 里的 mbedtls，与本模块无关。）
# zstd     —— pck / FileAccess 的压缩。
#
# ---- 还有一步可做（本轮没做）：类级裁剪 ----
# SCons 选项只能砍「模块」，砍「类」要靠 `build_profile=<.gdbuild>` 里的
# `disabled_classes`。它**只能由编辑器 GUI 生成**（项目 → 工具 → Engine Compilation
# Configuration Editor → Detect from Project → Save As），没有 CLI ——
# `EditorBuildProfileManager::_detect_from_project()` 没有暴露给脚本。
# 工程里那份 tools/reustcnet.gdbuild 目前只有 disabled_build_options（等于把命令行抄了一遍），
# **classes 列表是空的**，所以现在编进去没有任何额外效果。
# 要用它：先在编辑器里点一次 Detect from Project 存到同一个文件，再把下面这行打开：
#     build_profile=tools/reustcnet.gdbuild

