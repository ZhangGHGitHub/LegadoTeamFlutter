#!/usr/bin/env bash
# verify-ffi-android.sh — 校验 Android jniLibs 与 FRB content hash + Rust 源码树指纹是否同步（Linux/macOS/CI）
#
# P2-13: FRB content hash 只覆盖 FFI 导出面，只改 Rust 内部逻辑时 hash 不变，
# 会误判 in sync 打包旧 .so。现追加 rust/** 源码树指纹比对（算法见 rust-fingerprint.sh，
# 与 rust-fingerprint.ps1 一致）：
#   - .meta 有 rustFingerprint 且与当前源码树不一致 → 硬失败（.so 陈旧）；
#   - .meta 无 rustFingerprint（旧版构建产物）→ 仅告警不失败（迁移期 CI 兼容；
#     重跑 build-android.sh 后自动补上指纹，此后按硬失败判定）。
#   本地 Windows 流程（verify-ffi-android.ps1）对「无指纹」采取保守重编，口径不同属有意为之。
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

# P2-13: 当前 Rust 源码树指纹
source "$SCRIPT_DIR/rust-fingerprint.sh"
RUST_FP="$(rust_fingerprint "$RUST_DIR")"

declare -A ABI_MAP=(
    ["aarch64"]="arm64-v8a"
    ["armv7"]="armeabi-v7a"
    ["x86_64"]="x86_64"
)

read_hash() {
    local file="$1"
    local pattern="$2"
    # content hash 为 i32 可为负：尾段必须保留负号（仅取数字会把 -2007339931
    # 误读成 2007339931，导致与 .so.meta 比对恒失败）
    grep -oP "$pattern" "$file" | head -1 | grep -oP -- '-?\d+$'
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
            # P2-13: FRB hash 一致后再比对 Rust 源码树指纹（防止只改内部逻辑时误判 in sync）
            meta_fp="$(python3 -c "import json; d=json.load(open('$meta_path')); v=d.get('rustFingerprint'); print(v if isinstance(v,str) else '')" 2>/dev/null || true)"
            if [[ -z "$meta_fp" ]]; then
                echo "[WARN] $abi .so.meta 缺 rustFingerprint（旧版构建产物），建议重跑 build-android.sh 记录指纹"
            elif [[ "$meta_fp" != "$RUST_FP" ]]; then
                ISSUES+=("$abi Rust 源码已变更（.so 指纹 ${meta_fp:0:16}… ≠ 当前 ${RUST_FP:0:16}…），.so 陈旧，需重编")
            else
                echo "[OK] $abi（meta 校验通过：FRB hash + Rust 源码指纹一致）"
            fi
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
        # P2-13: 无 .meta 的旧 .so 通过二进制 hash 但无指纹记录 → 源码树状态未知。
        # CI 迁移期仅告警不硬失败；回填 .meta（不含指纹）以便后续 FRB 校验走 meta 路径。
        # 重跑 build-android.sh 后 .meta 会带上 rustFingerprint，此后按「指纹一致」判定。
        echo "[WARN] $abi .so 无源码树指纹记录（.so 可能来自更早源码树），建议重跑 build-android.sh"
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
    echo "=== FFI 校验通过（FFI 面与 Rust 源码指纹一致，复用现有 .so）==="
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
