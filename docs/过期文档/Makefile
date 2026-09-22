# [2026-09-22 归档注] 本 Makefile 自仓库根目录移入 docs/过期文档/（PENDING_DELETE_20260920.md §P4）：
# 当前开发环境为 Windows、无 make 命令（见 AGENTS.md「关键约束」），且 gen/build 等目标已不存在，
# 此处仅留档备查；构建与验证命令以 AGENTS.md「验证命令」与 scripts/generate-bridge.ps1 为准。
.PHONY: check test lint ci build run-windows build-windows build-windows-release

check:
	cd rust && cargo check --workspace

test:
	cd rust && cargo test --workspace

test-quickjs:
	cd rust && cargo test -p legado-js --features quickjs

test-all: test test-quickjs

lint:
	cd rust && cargo clippy --workspace -- -D warnings
	cd flutter_legado && flutter analyze

ci: lint test-all

build-server:
	cd rust && cargo build -p legado-server --release

build-android:
	cd rust && ./scripts/build-android.sh

run-windows:
	cd rust && cargo build -p legado-ffi
	cd flutter_legado && powershell -File scripts/build-windows.ps1 -BuildOnly
	cd flutter_legado && flutter run -d windows

build-windows:
	powershell -File flutter_legado/scripts/build-windows.ps1 -BuildOnly

build-windows-release:
	powershell -File flutter_legado/scripts/build-windows.ps1 -BuildOnly -Release
