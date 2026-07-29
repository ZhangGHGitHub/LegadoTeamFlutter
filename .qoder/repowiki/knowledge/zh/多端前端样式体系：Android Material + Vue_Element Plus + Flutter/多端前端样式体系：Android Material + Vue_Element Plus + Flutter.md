---
kind: frontend_style
name: 多端前端样式体系：Android Material + Vue/Element Plus + Flutter
category: frontend_style
scope:
    - '**'
source_files:
    - app/src/main/res/values/colors.xml
    - app/src/main/res/values-night/colors.xml
    - app/src/main/res/values/styles.xml
    - modules/web/package.json
    - modules/web/vite.config.ts
    - modules/web/src/assets/bookshelf.css
    - modules/web/src/assets/code.css
    - modules/web/src/assets/kbd.css
    - modules/web/src/assets/sourceeditor.css
    - modules/web/src/config/themeConfig.ts
    - flutter_legado/analysis_options.yaml
---

Legado 工程包含三个独立的前端实现，各自采用不同的样式与主题系统，整体呈现“原生 Android + Web 管理页 + Flutter 跨平台”的多端样式架构。

## 1. Android 原生 UI（app 模块）
- **框架与主题**：基于 `Theme.AppCompat.DayNight.NoActionBar` 的 Material Design 2 风格，通过 `values/` 与 `values-night/` 资源目录实现亮/暗主题切换。
- **颜色体系**：`colors.xml` 集中定义 primary、accent、background、text、divider 等语义化颜色，并引用 md_* 调色板；`styles.xml` 定义 AppTheme、Toolbar、Dialog、Text 等样式基类。
- **布局与资源**：XML layout 文件按功能划分（layout/layout-land），drawable/color/menu 等资源按用途组织；支持夜间模式与透明窗口主题。
- **约束**：所有颜色通过命名资源引用，避免硬编码；主题切换由 DayNight 自动处理。

## 2. Web 管理界面（modules/web）
- **技术栈**：Vue 3 + Vite + TypeScript，UI 组件库使用 Element Plus（含图标集 @element-plus/icons-vue）。
- **构建配置**：`vite.config.ts` 启用 unplugin-auto-import、unplugin-vue-components、unplugin-icons 实现按需导入与自动注册；SCSS 预处理器使用 modern-compiler API。
- **样式组织**：CSS 文件分散在 `src/assets/` 下（bookshelf.css、code.css、kbd.css、sourceeditor.css），采用模块化 CSS 而非全局样式；通过 `@import` 组合样式。
- **主题系统**：`themeConfig.ts` 定义阅读主题（body/content/popup 三色组合 + 背景纹理图片）与字体列表，以运行时配置方式切换。
- **代码规范**：ESLint + Prettier + Vue ESLint 配置，TypeScript 严格模式。

## 3. Flutter 跨平台应用（flutter_legado）
- **技术栈**：Flutter + Dart，遵循官方 Flutter Lints 规范。
- **样式策略**：当前 lib/src 目录为空，表明 Flutter 前端尚未完全实现或处于迁移初期；analysis_options.yaml 启用 flutter_lints 并排除生成代码。
- **状态**：该模块作为 Rust FFI 的跨平台载体存在，但 UI 层尚未填充。

## 4. 设计令牌与一致性
- **Android**：Material Design 颜色命名 + DayNight 资源覆盖。
- **Web**：Element Plus 设计令牌（如 `--el-fill-color-light`）+ 自定义主题配置。
- **Flutter**：待实现。
- **多端差异**：各端独立维护样式，无共享设计令牌系统，主题切换逻辑各自实现。