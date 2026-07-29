---
kind: dependency_management
name: 多语言工程依赖管理（Gradle Version Catalog + Cargo Workspace + Flutter Pub + npm）
category: dependency_management
scope:
    - '**'
source_files:
    - gradle/libs.versions.toml
    - build.gradle
    - app/build.gradle
    - app/download.gradle
    - gradle.properties
    - rust/Cargo.toml
    - rust/Cargo.lock
    - flutter_legado/pubspec.yaml
    - flutter_legado/pubspec.lock
    - modules/web/package.json
    - modules/web/pnpm-lock.yaml
    - .github/dependabot.yml
---

## 1. 使用的系统与工具

- **Android/Java/Kotlin**：使用 Gradle 的 **Version Catalog**（`gradle/libs.versions.toml`）集中声明所有第三方库版本与插件版本，子模块通过 `alias libs.plugins.*` 和 `libs.*` 引用。
- **Rust**：使用 Cargo workspace（`rust/Cargo.toml`）统一管理 8 个 crate，并通过 `[workspace.dependencies]` 共享依赖版本；每个 crate 的 `Cargo.toml` 仅声明自身所需依赖。
- **Flutter/Dart**：使用 `pubspec.yaml` 声明依赖，配合 `pubspec.lock` 锁定精确版本。
- **Web（Vue 前端）**：使用 `package.json` + `pnpm-lock.yaml` 管理依赖。
- **自动化更新**：通过 `.github/dependabot.yml` 对 Gradle、GitHub Actions、npm 三个生态执行每周自动 PR。

## 2. 关键文件与位置

| 生态 | 核心清单文件 | 锁文件/版本锁定 | 说明 |
|---|---|---|---|
| Android/Gradle | `gradle/libs.versions.toml`、`build.gradle`、`app/build.gradle`、`modules/*/build.gradle` | 无全局 lockfile（由 Gradle 缓存） | 统一版本目录 + 子模块引用 |
| Rust | `rust/Cargo.toml`（workspace）、各 crate 的 `Cargo.toml` | `rust/Cargo.lock` | workspace 共享依赖版本 |
| Flutter | `flutter_legado/pubspec.yaml` | `flutter_legado/pubspec.lock` | pub.dev 托管包 |
| Web | `modules/web/package.json` | `modules/web/pnpm-lock.yaml` | pnpm 包管理器 |
| 动态下载 | `app/download.gradle` | — | 构建时从 Google Storage 拉取 Cronet JAR/so |
| 自动化 | `.github/dependabot.yml` | — | 定期升级依赖并提 PR |

## 3. 架构与约定

### 3.1 Gradle Version Catalog 集中管控
- 所有 Android 相关库版本集中在 `gradle/libs.versions.toml` 的 `[versions]` 段，`[libraries]` 段以 `{ module = "...", version.ref = "..." }` 形式引用。
- 插件版本同样在 `[plugins]` 段定义，根 `build.gradle` 通过 `alias libs.plugins.* apply false` 统一应用。
- 子模块（`app`、`modules/book`、`modules/rhino`）不再硬编码版本号，全部通过 `implementation(libs.xxx)` / `alias libs.plugins.*` 引用，保证全仓库版本一致。

### 3.2 Rust Workspace 共享依赖
- `rust/Cargo.toml` 中 `[workspace.dependencies]` 定义了 serde、tokio、thiserror、aes、regex 等公共依赖的版本范围（如 `serde = { version = "1", features = ["derive"] }`），各 crate 直接引用而不重复写版本。
- `Cargo.lock` 被提交到仓库，确保跨平台构建可重现。

### 3.3 Flutter 与 Web 独立依赖管理
- Flutter 项目通过 `pubspec.yaml` 声明依赖，`pubspec.lock` 锁定精确版本，不纳入 Git 的版本漂移。
- Web 子模块使用 pnpm，`package.json` 声明依赖，`pnpm-lock.yaml` 锁定版本。

### 3.4 动态二进制依赖下载（Cronet）
- `app/download.gradle` 定义多个 Gradle task，构建时从 `https://storage.googleapis.com/chromium-cronet/android/<version>/Release/cronet/` 下载指定版本的 Cronet JAR 与各 ABI 的 `.so` 文件。
- 下载完成后生成 `cronet.json` 元数据（含各 so 的 MD5 校验值），写入 `src/main/assets/cronet.json`。
- 版本号由 `gradle.properties` 中的 `CronetVersion` 控制，升级时需先改版本号再执行 `gradlew app:downloadCronet`。

### 3.5 本地 Jar/AAR 与私有库
- `app/cronetlib/` 下存放已下载的 Cronet JAR，作为 `fileTree(dir: 'cronetlib', include: ['*.jar', '*.aar'])` 引入。
- `modules/rhino/lib/rhino-1.7.14.jar` 为内嵌 Rhino JS 引擎旧版 jar，通过 `api(fileTree(...))` 方式引入（当前已被 `htmlunit-core-js` 替代，但保留兼容路径）。

## 4. 约定与约束

- **版本集中化**：所有 Android/Kotlin 依赖版本必须通过 `libs.versions.toml` 声明，禁止在子模块 `build.gradle` 中硬编码版本号。
- **破坏性变更冻结**：`libs.versions.toml` 中对部分依赖添加了 `#noinspection NewerVersionAvailable` 注释并固定版本（如 `hutool=5.8.22`、`protobufJavalite=3.25.9`、`jsoup=1.16.2`、`commonsText=1.13.1`、`media3=1.10.1`、`gsyvideoplayer=13.1.0`、`webkit=1.14.0`、`activity=1.13.0`、`lifecycle=2.10.0`、`room=2.8.4`、`recyclerview=1.4.0`、`viewpager2=1.1.0`、`firebaseBom=34.14.1`），原因是上游存在已知破坏性变更或兼容性问题，升级需评估影响。
- **Lockfile 提交**：`Cargo.lock`、`pubspec.lock`、`pnpm-lock.yaml` 均提交到仓库，确保构建可重现。
- **Dependabot 自动升级**：配置了每周一次的 Gradle、GitHub Actions、npm 依赖更新 PR，但 Kotlin/KSP 被归入 `kotlin_KSP` 组以便批量处理。
- **Cronet 版本同步**：升级 Cronet 必须先修改 `gradle.properties` 中的 `CronetVersion`，再执行 `downloadCronet` task，否则构建会因缺失对应 so 文件而失败。
- **资源优化**：`gradle.properties` 启用 `android.nonTransitiveRClass=true`、`android.enableResourceOptimizations=true` 以减少 APK 体积。
- **私有/本地依赖策略**：对于无法通过 Maven Central/Pub.dev 获取的二进制（如 Cronet、Rhino jar），采用构建时下载或本地 `fileTree` 引入的方式，避免将大二进制文件提交到 Git。