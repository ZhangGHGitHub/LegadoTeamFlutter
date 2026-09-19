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

# P2-13: 引入 Rust 源码树指纹工具（算法须与 rust-fingerprint.ps1 保持一致）
source "$(cd "$(dirname "$0")" && pwd)/rust-fingerprint.sh"

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

# 读取 FRB content hash
CONTENT_HASH=""
if [ -f "legado-ffi/src/frb_generated.rs" ]; then
    CONTENT_HASH=$(grep -oP 'FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH:\s*i32\s*=\s*\K-?\d+' legado-ffi/src/frb_generated.rs | head -1)
    echo "FRB content hash: $CONTENT_HASH"
fi

# P2-13: 计算当前 Rust 源码树指纹（FRB content hash 只覆盖 FFI 面，内部逻辑变更不改变它；
# 指纹覆盖整个 rust/** 源码树，随 .so.meta 落盘，供 verify-ffi-android.sh/.ps1 判定 .so 是否陈旧）
RUST_FP="$(rust_fingerprint "$(pwd)")"
echo "Rust source fingerprint: ${RUST_FP:0:16}..."

write_meta() {
    local so_path="$1"
    if [ -n "$CONTENT_HASH" ]; then
        # 经环境变量传值，避免路径/指纹中的特殊字符破坏内联 Python 代码
        META_SO_PATH="$so_path" META_CONTENT_HASH="$CONTENT_HASH" META_MODE="$MODE" META_RUST_FP="$RUST_FP" \
        python3 -c "
import json, os, datetime
meta = {'contentHash': int(os.environ['META_CONTENT_HASH']), 'mode': os.environ['META_MODE'], 'builtAt': datetime.datetime.now().isoformat()}
fp = os.environ.get('META_RUST_FP')
if fp:
    meta['rustFingerprint'] = fp
open(os.environ['META_SO_PATH'] + '.meta', 'w').write(json.dumps(meta, separators=(',', ':')))
"
    fi
}

cp "target/aarch64-linux-android/$FLAG/liblegado_ffi.so"          "$FLUTTER_JNI/arm64-v8a/"
write_meta "$FLUTTER_JNI/arm64-v8a/liblegado_ffi.so"
cp "target/armv7-linux-androideabi/$FLAG/liblegado_ffi.so"        "$FLUTTER_JNI/armeabi-v7a/"
write_meta "$FLUTTER_JNI/armeabi-v7a/liblegado_ffi.so"
cp "target/x86_64-linux-android/$FLAG/liblegado_ffi.so"           "$FLUTTER_JNI/x86_64/"
write_meta "$FLUTTER_JNI/x86_64/liblegado_ffi.so"

echo ""
echo "Build complete! .so files copied to $FLUTTER_JNI"
echo "  arm64-v8a/liblegado_ffi.so"
echo "  armeabi-v7a/liblegado_ffi.so"
echo "  x86_64/liblegado_ffi.so"
