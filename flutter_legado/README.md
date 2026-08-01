# Legado Flutter 客户端

Legado（阅读）Flutter 客户端，使用 **Rust + Flutter** 架构。UI 层采用 Flutter 构建，核心业务逻辑由 Rust 引擎（`../rust/`）通过 `flutter_rust_bridge` 以 FFI 方式提供。

---

## 目录结构

```
flutter_legado/
├── lib/
│   ├── main.dart              # 入口
│   ├── app.dart               # MaterialApp 配置
│   └── src/
│       ├── bridge/            # flutter_rust_bridge 生成代码（不提交）
│       │   ├── api/           # 按 API 分组的桥接接口
│       │   ├── ffi/           # 底层 FFI 绑定
│       │   └── frb_generated.*.dart
│       ├── models/            # 数据模型（freezed + json_serializable）
│       │   ├── book.dart
│       │   ├── book_chapter.dart
│       │   ├── book_source.dart
│       │   ├── rss_source.dart
│       │   ├── misc.dart
│       │   └── rule/
│       ├── providers/         # 状态管理（Provider）
│       │   ├── bookshelf_provider.dart
│       │   ├── reader_provider.dart
│       │   ├── search_provider.dart
│       │   ├── source_provider.dart
│       │   ├── sync_provider.dart
│       │   ├── audio_provider.dart
│       │   ├── auto_task_provider.dart
│       │   ├── bookmark_provider.dart
│       │   ├── discover_provider.dart
│       │   ├── reading_stats_provider.dart
│       │   ├── replace_rule_provider.dart
│       │   └── rss_provider.dart
│       ├── screens/           # 页面
│       │   ├── home_screen.dart       # 主页（书架 Tab）
│       │   ├── bookshelf_screen.dart  # 书架列表
│       │   ├── book_info_screen.dart  # 书籍详情
│       │   ├── reader_screen.dart     # 阅读器
│       │   ├── search_screen.dart     # 搜索
│       │   ├── source_screen.dart     # 书源管理
│       │   ├── source_edit_screen.dart # 书源编辑
│       │   ├── source_discover_screen.dart # 书源发现
│       │   ├── audio_screen.dart      # 听书播放器
│       │   ├── auto_task_screen.dart  # 定时任务
│       │   ├── bookmark_screen.dart   # 书签管理
│       │   ├── replace_rules_screen.dart # 替换规则
│       │   ├── reading_stats_screen.dart # 阅读统计
│       │   ├── rss_screen.dart        # RSS 订阅
│       │   ├── rss_articles_screen.dart # RSS 文章列表
│       │   ├── rss_article_detail_screen.dart # RSS 文章详情
│       │   └── settings_screen.dart   # 设置
│       ├── services/          # 服务层
│       │   ├── rust_api.dart          # Rust API 封装
│       │   ├── backup_service.dart    # 备份/恢复服务
│       │   ├── settings_service.dart  # 设置持久化服务
│       │   ├── source_import_service.dart # 书源在线导入服务
│       │   └── platform_channel.dart  # 原生平台通道
│       ├── widgets/           # 复用 UI 组件
│       ├── l10n/              # 国际化字符串
│       │   └── app_strings.dart   # 中英文双语管理
│       ├── utils/             # 工具函数
│       └── routes.dart        # 路由配置
├── android/                   # Android 平台工程
├── ios/                       # iOS 平台工程
├── scripts/
│   ├── generate-bridge.sh     # Bridge 代码生成脚本
│   └── generate-bridge.ps1    # Windows 版
├── Makefile                   # 统一构建命令
├── pubspec.yaml               # Flutter 依赖
└── flutter_rust_bridge.yaml   # flutter_rust_bridge 配置
```

---

## 开发环境搭建

### 1. Flutter SDK

```bash
flutter --version   # 确保 SDK >= 3.11.5
flutter pub get     # 安装依赖
```

### 2. Rust 工具链

```bash
cd ../rust
cargo check         # 验证 Rust 侧可编译
```

### 3. flutter_rust_bridge_codegen

```bash
cargo install flutter_rust_bridge_codegen
```

### 4. 生成 Bridge 代码

每次 Rust API 变更后需重新生成：

```bash
# Linux / macOS
./scripts/generate-bridge.sh

# Windows PowerShell
.\scripts\generate-bridge.ps1

# 或直接使用 Makefile
make gen
```

---

## 构建与运行

### 开发调试（热重载）

```bash
flutter run
```

### 构建 APK

**完整流程（Rust .so + Flutter APK）：**

```bash
# 使用 Makefile（推荐）
make build          # release
make build-debug    # debug

# 或手动步骤：
cd ../rust && ./scripts/build-android.sh release
cd ../flutter_legado && flutter build apk
```

### 代码检查

```bash
make check          # Rust cargo check + Flutter analyze
```

### 运行测试

```bash
make test           # Rust cargo test + Flutter test
```

### 清理

```bash
make clean          # cargo clean + flutter clean
```

---

## 页面说明

| 页面 | 路由 | 功能 |
|------|------|------|
| **主页** | `/` | Tab 容器，承载书架、RSS、设置入口 |
| **书架** | `/` (Tab) | 显示本地书架，支持排序、分组、拖拽、长按操作 |
| **书籍详情** | `/book_info` | 书籍封面/简介/章节列表/搜索章节/加入书架 |
| **阅读器** | `/reader` | 翻页阅读，字体/背景/亮度调节，目录侧边栏，夜间模式，3 种翻页模式 |
| **搜索** | `/search` | 全网书源搜索，支持关键词联想与历史 |
| **书源管理** | `/sources` | 导入/导出/编辑书源规则 |
| **书源编辑** | `/source/edit` | 单个书源详细编辑 |
| **书源发现** | `/source/discover` | 书源发现页，浏览书源分类与探索规则 |
| **听书** | `/audio` | TTS 听书播放器 |
| **定时任务** | `/auto_task` | 定时任务管理：创建/编辑/启用/禁用 |
| **书签** | `/bookmark` | 书签管理：添加/编辑/删除/跳转 |
| **替换规则** | `/replace_rules` | 内容替换规则管理 |
| **阅读统计** | `/reading_stats` | 今日时长/字数/速度，周/月柱状图，书籍分布，热力图 |
| **RSS** | `/rss` | RSS 订阅源浏览 |
| **RSS 文章** | `/rss/articles` | RSS 文章列表 |
| **视频播放** | `/video` | 视频播放，播放控制、全屏、手势 |
| **漫画阅读** | `/reader/comic` | 漫画阅读，纵向滚动、双指缩放、图片预加载 |
| **设置** | `/settings` | 主题/语言切换、备份恢复、云同步、关于信息 |

---

## 状态管理架构

本项目使用 **Provider** 进行状态管理，各 Provider 职责如下：

| Provider | 职责 |
|----------|------|
| `BookshelfProvider` | 书架数据：加载、添加、删除、排序、分组 |
| `ReaderProvider` | 阅读状态：当前章节、翻页进度、阅读设置 |
| `SearchProvider` | 搜索状态：关键词、搜索结果、加载分页、搜索历史 |
| `SourceProvider` | 书源管理：书源列表、启用/禁用、导入导出 |
| `SyncProvider` | WebDAV 云同步：配置、上传/下载/合并同步、自动同步 |
| `ReadingStatsProvider` | 阅读统计：今日数据、每日时长、书籍分布、热力图 |
| `AudioProvider` | 听书播放：TTS 播放控制、进度管理 |
| `AutoTaskProvider` | 定时任务：任务列表、创建/编辑/启用/禁用 |
| `BookmarkProvider` | 书签管理：添加/编辑/删除/跳转 |
| `DiscoverProvider` | 书源发现：探索规则加载、分类浏览 |
| `ReplaceRuleProvider` | 替换规则：规则列表、启用/禁用、排序 |
| `RssProvider` | RSS 订阅：源列表、文章加载 |

Provider 通过 `services/rust_api.dart` 调用 Rust 侧业务逻辑，实现 UI 与数据的解耦。

---

## 数据模型

使用 `freezed` + `json_serializable` 生成不可变模型：

- `Book` — 书籍信息
- `BookChapter` — 章节
- `BookSource` — 书源规则
- `RssSource` — RSS 源规则
- `misc.dart` — 杂项枚举与辅助模型

运行代码生成：
```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

---

## 技术栈

| 类别 | 技术 |
|------|------|
| UI 框架 | Flutter 3.x |
| 状态管理 | Provider |
| 数据模型 | freezed + json_serializable |
| FFI 桥接 | flutter_rust_bridge 2.12.0 |
| 路由 | Navigator 1.0（命名路由） |
| 原生通道 | MethodChannel (platform_channel.dart) |

---

## 国际化

本项目使用手动 l10n 方案（`lib/src/l10n/app_strings.dart`），支持中文和英文双语切换：

- `AppStrings` 类提供所有 UI 字符串，通过 `setLocale()` 切换语言
- 设置页面提供语言选择（跟随系统/中文/English）
- 语言偏好通过 `SharedPreferences` 持久化
- 已国际化的页面：书架、搜索、阅读器、设置、首页

---

## 项目进度（截至 2026-07-30）

### 当前状态：39 屏幕 + 13 Provider + 24 FFI API，flutter analyze 0 issues，flutter test 167 passed，148/148 任务已完成

### 已完成
- 39 个页面：书架、书籍详情、阅读器（3种翻页+夜间模式+配置面板+仿真动画）、搜索、书内搜索、书源管理、书源编辑、书源发现、书源调试、书源登录、听书播放器、朗读配置、定时任务、书签管理、替换规则、阅读统计、设置、主题配置、RSS、RSS 文章、RSS 收藏、RSS 源编辑、浏览器、词典、字体、二维码、导入、换源、换封面、书籍分组、关联导入、欢迎页、关于、视频播放、漫画阅读
- 13 个 Provider：Bookshelf、Reader、Search、Source、Sync、ReadingStats、Audio、AutoTask、Bookmark、Discover、ReplaceRule、Rss、Association
- 服务层：RustApi（1026行 FFI 联通）、SettingsService、BackupService、SourceImportService、PlatformChannel、RustBridge
- 国际化：中英文双语切换
- Android 平台桥接：WebView/TTS/通知/文件选择器 4 个 MethodChannel
- APK 构建验证通过（雷电模拟器 x86_64）
- 24 个测试文件 / 167 tests passed

### 待完成
- Cronet QUIC 优化

> Rust 侧详细开发指南见 [DEVELOPMENT.md](../rust/DEVELOPMENT.md)
