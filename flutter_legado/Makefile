.PHONY: gen build test check clean

# flutter_rust_bridge 代码生成
gen:
	flutter_rust_bridge_codegen generate

# 静态检查（Rust + Flutter）
check:
	cd ../rust && cargo check
	flutter analyze

# 运行测试（Rust + Flutter）
test:
	cd ../rust && cargo test
	flutter test

# 完整构建（Rust .so + Flutter APK）
build:
	cd ../rust && bash scripts/build-android.sh release
	flutter build apk

# Debug 构建
build-debug:
	cd ../rust && bash scripts/build-android.sh debug
	flutter build apk --debug

# 清理构建产物
clean:
	cd ../rust && cargo clean
	flutter clean
