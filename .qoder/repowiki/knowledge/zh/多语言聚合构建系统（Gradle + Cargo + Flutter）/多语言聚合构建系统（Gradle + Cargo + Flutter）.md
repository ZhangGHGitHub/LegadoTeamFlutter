---
kind: build_system
name: 多语言聚合构建系统（Gradle + Cargo + Flutter）
category: build_system
scope:
    - '**'
source_files:
    - Makefile
    - build.gradle
    - settings.gradle
    - gradle.properties
    - gradle/libs.versions.toml
    - app/build.gradle
    - app/download.gradle
    - rust/Cargo.toml
    - rust/scripts/build-android.sh
    - flutter_legado/Makefile
    - flutter_legado/pubspec.yaml
    - flutter_legado/scripts/build-windows.ps1
---

## 构建系统概述

Legado 采用 **三语言聚合构建** 架构，通过顶层 Makefile 统一协调 Android(Kotlin)、Flutter(Dart) 与 Rust 三个子工程的构建流程，实现从旧工程向 Rust+Flutter 的渐进式迁移。

## 核心构建工具链

### Gradle (Android/Kotlin)
- **版本管理**: 使用 `gradle/libs.versions.toml` 集中管理所有依赖版本，包括 Kotlin 2.4.10、AGP 8.13.2、Room 2.8.4 等
- **模块化结构**: 根工程包含 `app`、`modules:book`、`modules:rhino` 三个模块，通过 `settings.gradle` 统一管理
- **插件体系**: 通过 `alias libs.plugins.*` 方式声明式应用插件，支持 Android Application/Library、Kotlin、KSP、Room、Google Services 等
- **构建配置**: `build.gradle` 中启用 ViewBinding、BuildConfig，配置 Java 17 工具链，支持 ARM 架构过滤

### Cargo (Rust)
- **工作区模式**: `rust/Cargo.toml` 定义 workspace，包含 8 个 crate：legado-core、legado-parser、legado-net、legado-js、legado-book、legado-db、legado-ffi、legado-server
- **依赖管理**: 通过 `[workspace.dependencies]` 共享公共依赖，如 serde、tokio、thiserror 等
- **目标平台**: 支持 Android 多架构编译（aarch64、armv7、x86_64），通过 NDK 交叉编译生成 .so 文件

### Flutter/Dart
- **跨平台支持**: 同时支持 Android、iOS、Windows、Linux、macOS、Web 平台
- **FFI 集成**: 通过 `flutter_rust_bridge` 与 Rust 核心引擎通信，版本 ^2.7.0
- **包管理**: `pubspec.yaml` 管理 Dart 依赖，使用 `flutter_lints` 进行代码检查

## 构建脚本与自动化

### 顶层 Makefile
提供统一的构建入口：
- `check`: 执行 Rust workspace 检查
- `test/test-all`: 运行 Rust 和 QuickJS 特性测试
- `lint`: 并行执行 Rust clippy 和 Flutter analyze
- `build-android`: 调用 Rust 脚本编译 Android .so
- `build-windows/build-windows-release`: Windows 平台构建

### Rust Android 构建脚本
`rust/scripts/build-android.sh` 实现：
- 自动安装 Rust 目标平台
- 并行编译三种 Android ABI 架构
- 将生成的 .so 文件复制到 Flutter jniLibs 目录

### Flutter Windows 构建脚本
`flutter_legado/scripts/build-windows.ps1` 实现：
- 一键构建 Rust FFI DLL 和 Flutter Windows 应用
- 自动复制 DLL 到 Flutter 输出目录
- 支持 Debug/Release 模式和可选的运行步骤

### Cronet 动态下载
`app/download.gradle` 实现：
- 根据 `gradle.properties` 中的版本号动态下载 Chromium Cronet 库
- 支持 5 种 ABI 架构的 .so 文件下载
- 生成 MD5 校验和并写入 assets/cronet.json

## 版本与发布策略

### Android 版本管理
- **versionCode**: 基于 Git 提交计数动态生成，基础值 37540
- **versionName**: 格式为 "3.YYMMDDHH"，确保每次构建唯一性
- **签名配置**: 支持命令行参数传入密钥信息，启用 V1/V2/V3/V4 签名
- **资源优化**: 启用 R8 压缩、资源精简、非传递 R 类

### 数据库迁移
- Room 数据库 schema 版本化管理，95 个版本文件位于 `app/schemas/io.legado.app.data.AppDatabase/`
- 通过 KSP 注解处理器自动生成迁移代码

## 构建约束与规范

### 强制约束
- **JVM 参数**: 配置 -Xmx6g 内存限制，启用并行 GC
- **AndroidX**: 强制使用 AndroidX，禁用 Jetifier
- **命名空间**: 启用 `android.nonTransitiveRClass=true` 减少 R 类大小
- **依赖锁定**: 通过 `dependencyResolutionManagement` 禁止子项目自定义仓库

### 开发规范
- **代码风格**: Kotlin 使用官方风格，启用严格警告检查
- **测试覆盖**: Rust 使用 cargo test，Flutter 使用 flutter test，Android 使用 JUnit + Espresso
- **静态分析**: Rust clippy 作为 CI 检查的一部分，Flutter analyze 同步执行

## 多语言协作模式

构建系统通过以下机制协调多语言模块：
1. **依赖顺序**: Rust → Flutter → Android，确保底层依赖先构建
2. **产物传递**: Rust .so/.dll → Flutter jniLibs → Android APK
3. **接口契约**: flutter_rust_bridge 自动生成类型安全的 FFI 绑定
4. **环境隔离**: 各语言独立的环境变量和工具链配置

该构建系统体现了现代移动应用的多语言架构趋势，通过清晰的职责分离和自动化构建流程，实现了复杂项目的可维护性和可扩展性。