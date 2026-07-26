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
