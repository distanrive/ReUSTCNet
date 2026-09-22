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

cd /d/godot-build/godot

echo "开始编译（-j20，lto=full 的链接阶段会比较久）..."
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
    d3d12=no \
    winrt=no \
    accesskit=no \
    $ARGS

# d3d12=no     —— 我们用 Vulkan（forward_plus）。官方默认还要编 D3D12 驱动，
#                 而那需要额外的 DirectX 12 SDK 依赖；关掉既省事又省体积。
# winrt=no     —— WinRT/OneCore TTS（语音合成），与本程序无关。
# accesskit=no —— 屏幕阅读器无障碍支持，同样需要额外依赖。
# **opengl3 保留**：它是 Vulkan 不可用时（RDP / 虚拟机 / 老 Intel 核显）的兜底，
# 工控机和远程桌面上真会遇到，这点体积不值得省。
