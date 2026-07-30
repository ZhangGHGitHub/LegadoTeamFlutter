---
kind: build_system
name: 多语言聚合根构建系统 — Android/Flutter/Rust 三端统一构建与发布
category: build_system
scope:
    - '**'
source_files:
    - Makefile
    - build.gradle
    - gradle.properties
    - gradle/libs.versions.toml
    - app/build.gradle
    - flutter_legado/Makefile
    - flutter_legado/pubspec.yaml
    - rust/Cargo.toml
    - rust/scripts/build-android.sh
    - flutter_legado/scripts/build-windows.ps1
---

## 1. 使用的系统与工具
- **Android 工程**：基于 Gradle + Kotlin DSL，使用 `alias(libs.plugins.*)` 集中管理插件版本（AGP 8.13.2、Kotlin 2.4.10、KSP、Room、Google Services 等），依赖版本通过 `gradle/libs.versions.toml` 统一管理。
- **Flutter 跨平台前端**：使用 Flutter SDK（Dart SDK ≥3.8.0）+ `flutter_rust_bridge` 2.11.1 调用 Rust FFI；Windows/Linux/macOS/iOS/Android 多目标由 Flutter 原生工具链处理。
- **Rust 后端工作区**：Cargo workspace 包含 8 个 crate（core/parser/net/js/book/db/ffi/server），通过 `rust/Cargo.toml` 声明成员与共享依赖，使用 `cargo build/test/clippy/check` 完成编译与检查。
- **脚本与 Makefile**：根目录 `Makefile` 提供 `check/test/lint/ci/build-android/run-windows/build-windows` 等统一入口；`flutter_legado/Makefile` 封装 flutter_rust_bridge 代码生成与 APK 构建；`rust/scripts/build-android.sh` 负责多架构 NDK 交叉编译并拷贝 .so 到 Flutter jniLibs；`flutter_legado/scripts/build-windows.ps1` 一键构建 Windows 版并复制 DLL。

## 2. 核心文件与位置
- 根级构建入口：`Makefile`、`build.gradle`、`gradle.properties`、`gradle/libs.versions.toml`
- Android 应用模块：`app/build.gradle`（含签名、资源优化、Room schema、Cronet 版本注入、ProGuard 规则）
- Flutter 模块：`flutter_legado/pubspec.yaml`、`flutter_legado/Makefile`、`flutter_legado/scripts/build-windows.ps1`
- Rust 工作区：`rust/Cargo.toml`、`rust/scripts/build-android.sh`、`rust/rust-toolchain.toml`
- CI/Release 配置：`.github/workflows/*`、`.github/release.yml`、`.github/dependabot.yml`

## 3. 架构与约定
- **分层构建**：Rust → FFI (.so/.dll) → Flutter (APK/EXE) → Android App 或桌面发行。顶层 `Makefile ci` 会依次执行 `lint`（clippy + flutter analyze）、`test-all`（cargo test + quickjs feature）、`test`（Rust 单元测试）。
- **版本策略**：Android `versionName` 采用 `3.yyMMddHH` 时间戳格式，`versionCode` 基于 Git 提交计数从基准号递增；Flutter 独立版本号 `2.0.0+2`。
- **依赖集中化**：Android 所有第三方库版本集中在 `gradle/libs.versions.toml`，通过 `[libraries]`、`[bundles]`、`[plugins]` 三段式管理；Rust 依赖在 workspace 根 `Cargo.toml` 的 `[workspace.dependencies]` 中声明。
- **多架构支持**：Rust 通过 `rustup target add` 安装 aarch64/armv7/x86_64 Android 目标，脚本自动将产物复制到 `flutter_legado/android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/`。
- **Room Schema 管理**：Schema 文件按版本号命名（1.json…95.json）存放在 `app/schemas/io.legado.app.data.AppDatabase/`，由 KSP Room 插件自动生成。
- **资源与国际化**：仅保留 en/es/ja/pt/vi/zh(zh-rHK/zh-rTW) 七种语言，通过 `resourceConfigurations` 过滤掉未使用的翻译以减小包体。

## 4. 约定与约束
- **构建命令约定**：开发者统一通过 `make check/test/lint/ci` 触发对应阶段，避免直接调用底层工具；Flutter 侧通过 `flutter_legado/Makefile gen/build/test` 封装 bridge 生成与打包。
- **NDK 环境变量**：`ANDROID_NDK_HOME` 必须设置，否则 `build-android.sh` 会直接退出（脚本显式检查并打印示例路径）。
- **签名配置**：仅在存在 `RELEASE_STORE_FILE` 等 gradle 属性时启用签名，支持 V1/V2/V3/V4 全量签名方案，debug/release 分别使用不同 applicationIdSuffix。
- **性能与安全**：release 开启 R8 混淆与资源压缩，禁用不必要的 buildFeatures（aidl/buildconfig/renderscript/resvalues/shaders），启用 `nonTransitiveRClass` 减少 R 类体积。
- **CI 一致性**：`make ci` 同时运行 clippy（-D warnings）和 flutter analyze，确保 Rust 与 Dart 静态检查在同一流程中强制执行。
- **依赖锁定**：Flutter 使用 `pubspec.lock`，Rust 使用 `Cargo.lock`，Android 通过 version catalog 锁定版本，避免上游破坏性更新影响构建。
