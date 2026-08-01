#!/bin/bash
# build-ios.sh — 编译 Rust 为 iOS 各架构的静态库并打包 XCFramework
# 用法: ./build-ios.sh [release|debug] [--stub]
#
# ⚠️ 本脚本未在 macOS/iOS 实机验证（编写环境为 Windows）。
#    在 macOS 上的验证步骤见脚本末尾注释。
#
# 交付方式: XCFramework（含真机 + 模拟器切片，Apple 推荐）
# 目标架构:
#   - aarch64-apple-ios       (真机 arm64)
#   - aarch64-apple-ios-sim   (Apple Silicon 模拟器)
#   - x86_64-apple-ios        (Intel 模拟器)
#
# 产物路径: ../flutter_legado/ios/Frameworks/legado_ffi.xcframework
#
# 选项:
#   release|debug   编译模式（默认 release）
#   --stub          不启用 quickjs feature（轻量变体）

set -euo pipefail

# ========== 参数解析 ==========
MODE="release"
FEATURES="quickjs"

for arg in "$@"; do
    case "$arg" in
        release|debug)
            MODE="$arg"
            ;;
        --stub)
            FEATURES=""
            ;;
        *)
            echo "Error: 未知参数 '$arg'"
            echo "用法: ./build-ios.sh [release|debug] [--stub]"
            exit 1
            ;;
    esac
done

# ========== 前置检查 ==========

# 检查是否在 macOS 上运行
if [ "$(uname -s)" != "Darwin" ]; then
    echo "Error: 本脚本仅支持在 macOS 上运行（iOS 交叉编译需要 Apple 工具链）"
    echo "当前系统: $(uname -s)"
    exit 1
fi

# 检查 xcodebuild 是否可用
if ! command -v xcodebuild &>/dev/null; then
    echo "Error: 未找到 xcodebuild，请安装 Xcode 并执行:"
    echo "  xcode-select --install"
    exit 1
fi

# 检查 lipo 是否可用
if ! command -v lipo &>/dev/null; then
    echo "Error: 未找到 lipo 工具（通常随 Xcode Command Line Tools 安装）"
    exit 1
fi

# 检查 rustup 是否可用
if ! command -v rustup &>/dev/null; then
    echo "Error: 未找到 rustup，请先安装 Rust: https://rustup.rs"
    exit 1
fi

# ========== 目标定义 ==========
# 真机目标
DEVICE_TARGET="aarch64-apple-ios"
# 模拟器目标
SIM_TARGETS=("aarch64-apple-ios-sim" "x86_64-apple-ios")
# 全部目标
ALL_TARGETS=("$DEVICE_TARGET" "${SIM_TARGETS[@]}")

echo "=== Legado Rust iOS Build ==="
echo "Mode:     $MODE"
echo "Features: ${FEATURES:-（无，stub 模式）}"
echo "Targets:  ${ALL_TARGETS[*]}"
echo ""

# ========== 检查并安装 Rust targets ==========
echo ">> 检查 Rust targets 是否已安装..."
MISSING_TARGETS=()
for target in "${ALL_TARGETS[@]}"; do
    if ! rustup target list --installed | grep -q "$target"; then
        MISSING_TARGETS+=("$target")
    fi
done

if [ ${#MISSING_TARGETS[@]} -gt 0 ]; then
    echo ">> 安装缺失的 Rust targets: ${MISSING_TARGETS[*]}"
    rustup target add "${MISSING_TARGETS[@]}"
fi

# ========== 切到 rust workspace 目录 ==========
cd "$(dirname "$0")/.."

# ========== 构建 feature 参数 ==========
FEATURE_FLAG=""
if [ -n "$FEATURES" ]; then
    FEATURE_FLAG="--features $FEATURES"
fi

# ========== 编译各目标 ==========
for target in "${ALL_TARGETS[@]}"; do
    echo ""
    echo ">> 编译 $target..."
    if [ "$MODE" = "release" ]; then
        cargo build --release --target "$target" -p legado-ffi $FEATURE_FLAG
    else
        cargo build --target "$target" -p legado-ffi $FEATURE_FLAG
    fi
    echo "   ✓ $target 编译完成"
done

# ========== 确定产物子目录 ==========
if [ "$MODE" = "release" ]; then
    PROFILE_DIR="release"
else
    PROFILE_DIR="debug"
fi

# ========== 合成模拟器 universal 静态库 ==========
echo ""
echo ">> 使用 lipo 合成模拟器 universal 静态库..."

SIM_UNIVERSAL_DIR="target/ios-sim-universal"
mkdir -p "$SIM_UNIVERSAL_DIR"

lipo -create \
    "target/aarch64-apple-ios-sim/$PROFILE_DIR/liblegado_ffi.a" \
    "target/x86_64-apple-ios/$PROFILE_DIR/liblegado_ffi.a" \
    -output "$SIM_UNIVERSAL_DIR/liblegado_ffi.a"

echo "   ✓ 模拟器 universal: $SIM_UNIVERSAL_DIR/liblegado_ffi.a"

# ========== 打包 XCFramework ==========
echo ""
echo ">> 打包 XCFramework..."

FRAMEWORK_NAME="legado_ffi"
OUTPUT_DIR="../flutter_legado/ios/Frameworks"
XCFRAMEWORK_PATH="$OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"

# 清理旧产物
rm -rf "$XCFRAMEWORK_PATH"
mkdir -p "$OUTPUT_DIR"

# 为 XCFramework 准备头文件目录
HEADERS_DIR="target/ios-headers"
mkdir -p "$HEADERS_DIR"

# 如果存在 cbindgen 生成的头文件则复制，否则生成空占位
if [ -f "legado-ffi/include/legado_ffi.h" ]; then
    cp "legado-ffi/include/legado_ffi.h" "$HEADERS_DIR/"
elif [ -f "target/legado_ffi.h" ]; then
    cp "target/legado_ffi.h" "$HEADERS_DIR/"
else
    # 生成最小占位头文件（flutter_rust_bridge 场景下 Dart FFI 不依赖 C 头文件）
    cat > "$HEADERS_DIR/legado_ffi.h" << 'EOF'
/* legado_ffi.h — 占位头文件
 * flutter_rust_bridge 通过 Dart FFI 直接绑定符号，不依赖此头文件。
 * 如需 C 接口，请使用 cbindgen 生成。
 */
#ifndef LEGADO_FFI_H
#define LEGADO_FFI_H
#endif /* LEGADO_FFI_H */
EOF
fi

# 创建静态库的 framework 目录结构（xcodebuild -create-xcframework 需要）
DEVICE_FW_DIR="target/ios-frameworks/device/${FRAMEWORK_NAME}.framework"
SIM_FW_DIR="target/ios-frameworks/sim/${FRAMEWORK_NAME}.framework"

rm -rf "target/ios-frameworks"
mkdir -p "$DEVICE_FW_DIR/Headers"
mkdir -p "$SIM_FW_DIR/Headers"

# 复制静态库
cp "target/$DEVICE_TARGET/$PROFILE_DIR/liblegado_ffi.a" "$DEVICE_FW_DIR/${FRAMEWORK_NAME}"
cp "$SIM_UNIVERSAL_DIR/liblegado_ffi.a" "$SIM_FW_DIR/${FRAMEWORK_NAME}"

# 复制头文件
cp "$HEADERS_DIR/legado_ffi.h" "$DEVICE_FW_DIR/Headers/"
cp "$HEADERS_DIR/legado_ffi.h" "$SIM_FW_DIR/Headers/"

# 创建 Info.plist（device）
cat > "$DEVICE_FW_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>io.legado.ffi</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>MinimumOSVersion</key>
    <string>12.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneOS</string>
    </array>
</dict>
</plist>
EOF

# 创建 Info.plist（simulator）
cat > "$SIM_FW_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>io.legado.ffi</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>MinimumOSVersion</key>
    <string>12.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneSimulator</string>
    </array>
</dict>
</plist>
EOF

# 使用 xcodebuild 创建 XCFramework
xcodebuild -create-xcframework \
    -framework "$DEVICE_FW_DIR" \
    -framework "$SIM_FW_DIR" \
    -output "$XCFRAMEWORK_PATH"

echo "   ✓ XCFramework 已生成: $XCFRAMEWORK_PATH"

# ========== 完成 ==========
echo ""
echo "=== Build complete! ==="
echo "产物: $XCFRAMEWORK_PATH"
echo "  - ios-arm64/            (真机 aarch64)"
echo "  - ios-arm64_x86_64-simulator/  (模拟器 universal)"
echo ""
echo "集成方式: 在 Xcode 中将 ${FRAMEWORK_NAME}.xcframework 拖入"
echo "  flutter_legado/ios/Runner 的 Frameworks, Libraries 即可。"

# ========== macOS 验证步骤（本脚本未在实机验证） ==========
# 在 macOS 上验证本脚本的步骤:
#   1. rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#   2. cd rust/scripts && chmod +x build-ios.sh
#   3. ./build-ios.sh release            # 含 quickjs
#      ./build-ios.sh release --stub     # 不含 quickjs
#   4. 预期产物: flutter_legado/ios/Frameworks/legado_ffi.xcframework
#      内含 ios-arm64/ 和 ios-arm64_x86_64-simulator/ 两个切片
#   5. 验证: xcodebuild -create-xcframework 无报错，lipo -info 确认架构
