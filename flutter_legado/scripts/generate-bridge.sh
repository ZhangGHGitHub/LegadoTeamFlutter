#!/bin/bash
# generate-bridge.sh — 运行 flutter_rust_bridge 代码生成
# 用法: ./generate-bridge.sh

set -e

# 切到 flutter_legado 目录
cd "$(dirname "$0")/.."

echo "=== flutter_rust_bridge Code Generation ==="
echo "Working dir: $(pwd)"
echo ""

# 检查 flutter_rust_bridge_codegen 是否已安装
if ! command -v flutter_rust_bridge_codegen &>/dev/null; then
    echo "flutter_rust_bridge_codegen not found."
    echo "Install it with:"
    echo "  cargo install flutter_rust_bridge_codegen"
    exit 1
fi

echo ">> Running codegen..."
flutter_rust_bridge_codegen generate

echo ""
echo "Bridge code generated successfully!"
echo "Generated files are in lib/src/bridge/"
