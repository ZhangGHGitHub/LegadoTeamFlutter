#!/bin/bash
# rust-fingerprint.sh — Rust 源码树指纹（P2-13，Linux/macOS/CI）
#
# 算法必须与 rust-fingerprint.ps1 在相同源码树上产生完全一致的指纹（跨 OS 校验依赖）:
#   1. 文件集 = rust/ 下所有常规文件，排除任意深度的 target/ 目录（构建产物）；
#   2. 每文件一行:  <相对路径(无 ./ 前缀, / 分隔)>TAB<该文件内容 SHA256 小写 hex>
#   3. 各行按整行字节序排序（LC_ALL=C）
#   4. 拼接（每行以 LF 结尾）后取 SHA256，小写 hex 即指纹
#
# 用法:
#   source 本文件后调用: rust_fingerprint [RUST_DIR]
#   或直接执行:          ./rust-fingerprint.sh [RUST_DIR]   # 打印单行指纹

rust_fingerprint() {
    local rust_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    (
        cd "$rust_dir" || exit 1
        # -type d -name target -prune: 跳过任意深度的 target/ 目录
        find . -type d -name target -prune -o -type f -print0 2>/dev/null \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' f; do
            rel="${f#./}"
            h="$(sha256sum "$f" | cut -d' ' -f1)"
            printf '%s\t%s\n' "$rel" "$h"
          done
    ) | sha256sum | cut -d' ' -f1
}

# 直接执行（非 source）时打印指纹
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    rust_fingerprint "${1:-}"
fi
