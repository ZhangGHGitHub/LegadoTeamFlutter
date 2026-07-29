---
kind: frontend_style
name: 前端样式系统：Android原生资源 + Flutter跨平台UI + Web管理端三套风格并存
category: frontend_style
scope:
    - '**'
source_files:
    - app/src/main/res/values/
    - app/src/main/res/layout/
    - app/src/main/res/drawable/
    - app/src/main/res/values-night/
    - flutter_legado/pubspec.yaml
    - flutter_legado/lib/
    - modules/web/src/assets/bookshelf.css
    - modules/web/src/assets/code.css
    - modules/web/src/assets/sourceeditor.css
    - modules/web/.prettierrc.json
    - modules/web/eslint.config.mjs
---

本仓库包含三个独立的前端实现，各自维护自己的样式体系，不存在统一的跨工程样式规范。

1. Android 主应用（app/）
- 使用传统 Android XML 资源体系：`res/values/` 存放主题、颜色、尺寸等设计令牌；`res/layout/` 定义界面布局；`res/drawable/` 存放矢量与位图图标；`res/color/` 与 `res/mipmap-*` 提供多分辨率图标。
- 支持夜间模式（`values-night/`）、横屏适配（`layout-land/`）以及多语言资源（`values-zh/`、`values-es-rES/`、`values-ja-rJP/` 等），通过 Android 资源限定符自动切换。
- 动画与过渡效果集中在 `res/anim/` 与 `res/animator/`。
- 未引入 Jetpack Compose，仍基于 View 系统的 XML 声明式 UI。

2. Flutter 跨平台阅读应用（flutter_legado/）
- 使用 Flutter 框架的 Dart 代码构建 UI，样式以 Widget 属性内联为主，未见独立的 CSS/Sass 文件。
- 项目结构遵循 Flutter 标准：`lib/src/` 存放业务组件，`pubspec.yaml` 声明依赖，`analysis_options.yaml` 配置静态分析规则。
- 测试覆盖 widget 层（`test/widget/`）与单元测试（`test/unit/`），样式相关逻辑随组件一同测试。
- 通过 flutter_rust_bridge 调用 Rust 核心引擎，UI 层与样式完全由 Flutter 管理。

3. Web 管理端（modules/web/）
- 基于 Vue 3 + TypeScript + Vite 的单页应用，样式采用模块化 CSS（`.css` 文件按功能拆分：`bookshelf.css`、`code.css`、`kbd.css`、`sourceeditor.css` 等）。
- 使用 Prettier（`.prettierrc.json`）与 ESLint（`eslint.config.mjs`）统一代码风格，`.editorconfig` 约束基础格式。
- 组件化组织：`src/components/` 存放可复用 Vue 组件，`src/views/` 为页面级视图，`src/assets/` 集中管理字体与图片资源。
- 无 Tailwind CSS 或第三方 UI 库，样式自管且轻量。

4. 跨工程约束与约定
- 三个前端子系统相互独立，无共享样式变量或设计令牌机制。
- Android 与 Web 均使用 XML/CSS 声明式样式，Flutter 使用 Dart 内联样式，三者风格不互通。
- 未检测到全局主题系统、CSS-in-JS 方案或跨平台样式抽象层。