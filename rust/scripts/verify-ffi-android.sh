#!/usr/bin/env bash
# verify-ffi-android.sh — 校验 Android jniLibs 与 FRB content hash 是否同步（Linux/macOS/CI）
#
# 用法:
#   ./verify-ffi-android.sh
#   ./verify-ffi-android.sh debug "aarch64,x86_64" --auto-build

set -euo pipefail

MODE="${1:-debug}"
TARGETS="${2:-aarch64,x86_64}"
AUTO_BUILD="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$RUST_DIR/.." && pwd)"
FLUTTER_DIR="$ROOT_DIR/flutter_legado"
JNILIBS_DIR="$FLUTTER_DIR/android/app/src/main/jniLibs"
DART_FRB="$FLUTTER_DIR/lib/src/bridge/frb_generated.dart"
RUST_FRB="$RUST_DIR/legado-ffi/src/frb_generated.rs"
BUILD_SCRIPT="$SCRIPT_DIR/build-android.sh"

declare -A ABI_MAP=(
    ["aarch64"]="arm64-v8a"
    ["armv7"]="armeabi-v7a"
    ["x86_64"]="x86_64"
)

read_hash() {
    local file="$1"
    local pattern="$2"
    grep -oP "$pattern" "$file" | head -1 | grep -oP '\-?\d+'
}

DART_HASH="$(read_hash "$DART_FRB" 'rustContentHash\s*=>\s*-?\d+')"
RUST_HASH="$(read_hash "$RUST_FRB" 'FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH:\s*i32\s*=\s*-?\d+')"

if [[ -z "$DART_HASH" || -z "$RUST_HASH" ]]; then
    echo "[FFI] 无法解析 content hash" >&2
    exit 1
fi

if [[ "$DART_HASH" != "$RUST_HASH" ]]; then
    echo "[FFI] Dart/Rust frb_generated hash 不一致（Dart=$DART_HASH Rust=$RUST_HASH）" >&2
    exit 1
fi

echo "=== Legado Android FFI 校验 ==="
echo "期望 content hash: $DART_HASH"
echo "构建模式: $MODE"
echo "目标 ABI: $TARGETS"
echo ""

ISSUES=()
IFS=',' read -ra KEYS <<< "$TARGETS"
for key in "${KEYS[@]}"; do
    key="$(echo "$key" | xargs)"
    abi="${ABI_MAP[$key]:-}"
    if [[ -z "$abi" ]]; then
        echo "未知 target: $key" >&2
        exit 1
    fi
    so_path="$JNILIBS_DIR/$abi/liblegado_ffi.so"
    meta_path="$so_path.meta"

    if [[ ! -f "$so_path" ]]; then
        ISSUES+=("缺少 $abi/liblegado_ffi.so")
        continue
    fi

    if [[ -f "$meta_path" ]]; then
        meta_hash="$(python3 -c "import json; print(json.load(open('$meta_path'))['contentHash'])" 2>/dev/null || true)"
        if [[ -n "$meta_hash" && "$meta_hash" == "$DART_HASH" ]]; then
            echo "[OK] $abi（meta 校验通过）"
            continue
        fi
        if [[ -n "$meta_hash" ]]; then
            ISSUES+=("$abi .so.meta hash=$meta_hash，期望 $DART_HASH")
            continue
        fi
    fi

    # 二进制内嵌 hash（小端 i32）
    if python3 -c "
import struct, pathlib
h = int($DART_HASH)
needle = struct.pack('<i', h)
data = pathlib.Path('$so_path').read_bytes()
raise SystemExit(0 if needle in data else 1)
" 2>/dev/null; then
        echo "[OK] $abi（二进制 hash 校验通过）"
        python3 -c "
import json, datetime, pathlib
meta = {'contentHash': int($DART_HASH), 'mode': '$MODE', 'builtAt': datetime.datetime.now().isoformat()}
pathlib.Path('$meta_path').write_text(json.dumps(meta, separators=(',', ':')))
"
    else
        ISSUES+=("$abi liblegado_ffi.so 未嵌入期望 hash $DART_HASH")
    fi
done

if [[ ${#ISSUES[@]} -eq 0 ]]; then
    echo ""
    echo "=== FFI 校验通过 ==="
    exit 0
fi

echo "" >&2
echo "=== FFI 校验失败 ===" >&2
for item in "${ISSUES[@]}"; do
    echo "  - $item" >&2
done
echo "" >&2
echo "请执行: cd rust && ./scripts/build-android.sh $MODE" >&2

if [[ "$AUTO_BUILD" == "--auto-build" ]]; then
    echo ">> 自动调用 build-android.sh ..."
    bash "$BUILD_SCRIPT" "$MODE"
    exec "$0" "$MODE" "$TARGETS"
fi

exit 1
