---
kind: configuration_system
name: Legado 应用配置系统（SharedPreferences + 多端持久化）
category: configuration_system
scope:
    - '**'
source_files:
    - app/src/main/java/io/legado/app/help/config/AppConfig.kt
    - app/src/main/java/io/legado/app/constant/PreferKey.kt
    - app/src/main/java/io/legado/app/App.kt
    - flutter_legado/lib/main.dart
    - rust/Cargo.toml
    - gradle.properties
    - app/build.gradle
---

## 1. 系统与框架
- Android 端：基于 `android.content.SharedPreferences` 的键值对配置，通过自定义扩展函数 `getPref*` / `putPref*` / `removePref` 统一读写。
- Flutter 跨平台端：使用 `shared_preferences` 插件进行本地持久化，与 Rust FFI 引擎配合。
- Rust 核心：通过 Cargo workspace 管理多个 crate，数据库迁移由 `legado-db` 模块负责，运行时配置通过 FFI 暴露给 Flutter/Dart。

## 2. 关键文件与包
- `app/src/main/java/io/legado/app/help/config/AppConfig.kt`：全局应用配置单例，实现 `SharedPreferences.OnSharedPreferenceChangeListener`，集中暴露所有用户偏好项。
- `app/src/main/java/io/legado/app/constant/PreferKey.kt`：所有 SharedPreferences key 的集中定义，作为配置的“命名空间”。
- `app/src/main/java/io/legado/app/App.kt`：Application 入口，注册 `AppConfig` 为 SharedPreferences 监听器，并在启动时初始化各类配置相关服务。
- `app/src/main/res/values/strings.xml` 及多语言目录：UI 文案与部分默认值。
- `flutter_legado/lib/main.dart`：Flutter 侧启动流程，通过 `SharedPreferences.getInstance()` 读取首次启动标记，并初始化 Rust FFI。
- `rust/Cargo.toml`：Rust workspace 根配置，声明各 crate 成员与共享依赖。
- `gradle.properties`、`app/build.gradle`：构建期配置（Cronet 版本、签名、资源优化等）。

## 3. 架构与设计约定
- **单一配置入口**：`AppConfig` 对象是 Android 端唯一的配置访问点，所有偏好项以属性形式暴露，内部委托给 `appCtx.getPref*` / `putPref*` 工具方法。
- **Key 集中管理**：`PreferKey` 对象集中定义所有字符串 key，避免魔法字符串散落各处。
- **实时响应变更**：`AppConfig` 实现 `OnSharedPreferenceChangeListener`，在 `onSharedPreferenceChanged` 中根据 key 同步内存状态（如主题模式、字体缩放、点击区域等），并通过 `App.kt` 在 `defaultSharedPreferences.registerOnSharedPreferenceChangeListener(AppConfig)` 完成注册。
- **分层配置**：除全局 `AppConfig` 外，还有按功能域划分的配置类（如 `ReadBookConfig`、`ThemeConfig`），分别管理阅读设置与主题配置，默认数据从 `assets/defaultData` 加载。
- **多端一致性**：Flutter 端通过 `shared_preferences` 保持与 Android 端一致的键名约定；Rust 层通过 FFI 提供跨平台能力，Flutter 侧 Provider 模式管理状态。

## 4. 约定与约束
- **所有配置必须通过 PreferKey 定义的 key 访问**，禁止直接使用字符串字面量。
- **配置变更必须通过 AppConfig 的属性 setter**，确保监听器能正确触发状态同步。
- **敏感信息（如 jsSourceApiToken）使用独立 SharedPreferences 文件存储**（`js_source_api_credentials`），并进行 normalize 处理。
- **构建期配置通过 Gradle properties 和 build.gradle 注入**，如 Cronet 版本、签名信息等。
- **Flutter 端首次启动逻辑通过 SharedPreferences 标记控制**，未展示欢迎页则进入欢迎界面。
- **Rust 配置通过 Cargo workspace 统一管理**，各 crate 依赖集中在 `[workspace.dependencies]` 中声明。

## 5. 配置来源层次
1. **构建期常量**：`BuildConfig` 字段（如 Cronet 版本）
2. **默认资源**：`assets/defaultData` 中的 JSON 配置文件
3. **用户偏好**：`SharedPreferences` 持久化存储
4. **运行时动态配置**：通过 API 或 UI 修改后实时更新内存状态

该配置系统采用经典的 Android SharedPreferences 模式，通过集中化的 Key 管理和单例配置对象，实现了良好的可维护性和类型安全。多端架构下，Android、Flutter、Rust 各自使用最适合的持久化方案，通过约定的 key 命名和 FFI 接口保持配置一致性。