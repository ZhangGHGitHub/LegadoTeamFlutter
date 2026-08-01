.PHONY: gen gen-only build test check clean run-windows rebuild-ffi rebuild-ffi-stub

# flutter_rust_bridge 代码生成 + 自动重编译 DLL（防止 content hash 不同步）
#
# 关键：codegen 会重新生成两侧 frb_generated 的 content hash，
# 若不同步重编译 DLL，运行时会报 "Content hash on Dart side ... different from Rust side"。
# 因此 gen 必须紧跟一次 DLL 重编译，两者绑定为原子操作。
gen: gen-only rebuild-ffi

# 仅生成代码（不重编译 DLL，一般不单独使用）
gen-only:
	flutter_rust_bridge_codegen generate

# 重编译 Rust FFI 动态库（出厂/发布路径：启用 quickjs 真实 JS 引擎）
# 使书源 @js: 规则生效；应用加载的 DLL 含真实 QuickJS 引擎。
rebuild-ffi:
	cd ../rust && cargo build -p legado-ffi --features quickjs

# 开发态快速构建（不启用 quickjs，走 stub，编译更快）
# 注意：此路径下书源 @js: 规则降级返回空，仅用于快速迭代调试。
rebuild-ffi-stub:
	cd ../rust && cargo build -p legado-ffi

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

# Windows 开发运行：先确保 DLL 与当前代码同步，再启动
# 避免反复出现 content hash 不同步导致的 Rust 引擎初始化失败
run-windows: rebuild-ffi
	flutter run -d windows
