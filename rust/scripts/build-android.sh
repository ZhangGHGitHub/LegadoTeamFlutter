#!/bin/bash
# build-android.sh — 编译 Rust 为 Android 各架构的 .so 文件
# 用法: ./build-android.sh [release|debug]

set -e

MODE=${1:-release}
TARGETS=("aarch64-linux-android" "armv7-linux-androideabi" "x86_64-linux-android")

# 检查 Android NDK
if [ -z "$ANDROID_NDK_HOME" ]; then
    echo "Error: ANDROID_NDK_HOME not set"
    echo "Please set ANDROID_NDK_HOME to your Android NDK installation path"
    echo "Example: export ANDROID_NDK_HOME=\$HOME/Android/Sdk/ndk/<version>"
    exit 1
fi

echo "=== Legado Rust Android Build ==="
echo "Mode:    $MODE"
echo "NDK:     $ANDROID_NDK_HOME"
echo "Targets: ${TARGETS[*]}"
echo ""

# 切到 rust 目录（脚本所在目录的上级）
cd "$(dirname "$0")/.."

# 安装 targets
echo ">> Installing Rust targets..."
rustup target add "${TARGETS[@]}"

# 编译
for target in "${TARGETS[@]}"; do
    echo ""
    echo ">> Building for $target..."
    if [ "$MODE" = "release" ]; then
        cargo build --release --target "$target" -p legado-ffi --features quickjs
    else
        cargo build --target "$target" -p legado-ffi --features quickjs
    fi
done

# 复制到 Flutter jniLibs
FLUTTER_JNI="../flutter_legado/android/app/src/main/jniLibs"
mkdir -p "$FLUTTER_JNI/arm64-v8a"
mkdir -p "$FLUTTER_JNI/armeabi-v7a"
mkdir -p "$FLUTTER_JNI/x86_64"

if [ "$MODE" = "release" ]; then
    FLAG="release"
else
    FLAG="debug"
fi

echo ""
echo ">> Copying .so files to Flutter jniLibs..."
cp "target/aarch64-linux-android/$FLAG/liblegado_ffi.so"          "$FLUTTER_JNI/arm64-v8a/"
cp "target/armv7-linux-androideabi/$FLAG/liblegado_ffi.so"        "$FLUTTER_JNI/armeabi-v7a/"
cp "target/x86_64-linux-android/$FLAG/liblegado_ffi.so"           "$FLUTTER_JNI/x86_64/"

echo ""
echo "Build complete! .so files copied to $FLUTTER_JNI"
echo "  arm64-v8a/liblegado_ffi.so"
echo "  armeabi-v7a/liblegado_ffi.so"
echo "  x86_64/liblegado_ffi.so"
