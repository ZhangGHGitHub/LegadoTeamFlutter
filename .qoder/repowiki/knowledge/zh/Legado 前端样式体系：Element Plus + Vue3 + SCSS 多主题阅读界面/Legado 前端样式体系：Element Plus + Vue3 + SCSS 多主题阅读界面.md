---
kind: frontend_style
name: Legado 前端样式体系：Element Plus + Vue3 + SCSS 多主题阅读界面
category: frontend_style
scope:
    - '**'
source_files:
    - modules/web/src/config/themeConfig.ts
    - modules/web/src/main.ts
    - modules/web/src/store/bookStore.ts
    - modules/web/vite.config.ts
    - modules/web/src/components/ReadSettings.vue
    - modules/web/src/assets/bookshelf.css
    - modules/web/src/assets/code.css
    - modules/web/src/assets/kbd.css
    - flutter_legado/pubspec.yaml
---

## 系统概述

Legado 阅读器包含两个独立的前端子系统，分别采用不同的样式技术栈：

1. **Web 管理后台**（`modules/web/`）：基于 Vue 3 + Element Plus + SCSS 的 Web 应用，用于书源编辑、RSS 管理等管理功能
2. **Flutter 跨平台客户端**（`flutter_legado/`）：基于 Flutter Material Design 的跨平台阅读客户端

## Web 前端样式体系

### 核心框架与工具链
- **Vue 3** + **Vite** 构建，使用 `<script setup>` + TypeScript
- **Element Plus** 作为 UI 组件库，通过 `unplugin-vue-components` 自动按需引入
- **SCSS** 预处理器，启用 `modern-compiler` API
- **CSS 变量** 实现主题切换，通过 `element-plus/theme-chalk/dark/css-vars.css` 支持夜间模式

### 主题系统设计
主题配置集中在 `src/config/themeConfig.ts`，定义 7 种阅读主题（索引 0-6），每种主题包含三个层级：
- `body`：正文背景（支持纯色或纹理图片）
- `content`：内容区域背景
- `popup`：弹窗/设置面板背景

主题 6 为深色模式（`isNight: theme == 6`），通过监听 `bookStore.isNight` 状态在 `document.documentElement` 上切换 `dark` 类名，联动 Element Plus 的 CSS 变量。

### 样式组织方式
- **全局样式**：`src/assets/bookshelf.css` 定义基础重置和字体
- **组件样式**：各组件使用 `<style lang="scss" scoped>` 隔离样式
- **共享样式模块**：`kbd.css`、`code.css` 等通用样式通过 `@import` 组合
- **图标系统**：使用 `unplugin-icons` + `@element-plus/icons-svg`，通过 `Icon` 前缀自动注册

### 响应式策略
- 使用 CSS `@media screen and (max-width: 500px)` 处理移动端适配
- 阅读宽度通过 `readWidth` 配置项动态控制（默认 800px，最小 640px）
- 设置面板在小屏幕下自动换行显示标签

## Flutter 前端样式体系

### 设计系统与组件库
- **Material Design 3**：通过 `uses-material-design: true` 启用
- **Cupertino Icons**：iOS 风格图标支持
- **Provider** 状态管理，无专用 UI 状态库

### 主题与外观
- 依赖 Flutter 内置的主题系统，通过 `ThemeData` 统一管理颜色、字体、形状
- 未使用第三方主题包，保持原生 Material 风格一致性
- 通过 `shared_preferences` 持久化用户偏好设置

## 架构约定

### Web 端约定
1. **样式作用域**：所有组件样式必须使用 `scoped` 防止污染全局
2. **SCSS 嵌套**：遵循 BEM 命名风格的类名组织
3. **主题切换**：通过 Pinia store 集中管理主题状态，组件通过 computed 响应式获取
4. **图标使用**：优先使用 Element Plus 提供的图标，自定义图标放入 `assets/imgs/themes/`

### Flutter 端约定
1. **Material 优先**：所有 UI 组件基于 Material 规范
2. **状态管理**：使用 Provider 进行轻量级状态管理
3. **资源管理**：图片和字体通过 `pubspec.yaml` 声明

## 关键文件
- `modules/web/src/config/themeConfig.ts` - 主题配置中心
- `modules/web/src/main.ts` - 主题切换入口
- `modules/web/src/store/bookStore.ts` - 阅读配置状态管理
- `modules/web/vite.config.ts` - 构建与样式预处理配置
- `flutter_legado/pubspec.yaml` - Flutter 依赖与 Material 配置

## 约束与规范
- Web 端禁止直接修改 Element Plus 源码，通过 CSS 变量覆盖主题
- 所有新增主题必须在 `themeConfig.ts` 中统一注册
- Flutter 端禁止硬编码颜色值，必须通过 `Theme.of(context).colorScheme` 获取
- 响应式设计断点统一使用 500px 作为移动端阈值