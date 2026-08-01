# Legado Flutter + Rust 三端通用重构计划（含并行分工）

> **指令：立即切换开发计划**
>
> 从现在开始，完全终止并忽略之前讨论的所有开发计划、代码生成方向、架构设计及任何未完成的旧任务。
>
> 新的唯一依据是以下《Legado Flutter + Rust 三端通用重构计划》，请严格以此为准开展工作。

---

## 一、目标架构确认（统一蓝图）

最终架构必须达到以下分层，所有代码归属严格执行：

```text
┌────────────────────────────────────────────┐
│               Flutter App                  │
│  ┌──────────┐ ┌──────────┐ ┌───────────┐  │
│  │  Pages   │ │ Widgets  │ │  State    │  │
│  │ (书架/阅读│ │ (组件库) │ │ (Riverpod)│  │
│  │  发现/设置)│ │          │ │           │  │
│  └────┬─────┘ └────┬─────┘ └─────┬─────┘  │
│       │             │              │       │
│       └─────────────┼──────────────┘       │
│                     │                      │
│             ┌───────▼────────┐             │
│             │  Rust Bridge   │             │
│             │(flutter_rust_  │             │
│             │   bridge)      │             │
│             └───────┬────────┘             │
└─────────────────────┼──────────────────────┘
                      │
┌─────────────────────▼──────────────────────┐
│                  Rust Core                 │
│  ┌───────────┐ ┌──────────┐ ┌───────────┐ │
│  │ 书源引擎  │ │ 解析规则  │ │ 文本解析  │ │
│  │(JsEngine  │ │(替换/净化│ │(txt/epub  │ │
│  │  执行沙箱)│ │  规则)   │ │  解析)    │ │
│  └─────┬─────┘ └────┬─────┘ └─────┬─────┘ │
│        └────────────┼──────────────┘       │
│                     │                      │
│  ┌──────────┐ ┌─────▼──────┐ ┌───────────┐ │
│  │ 网络层   │ │  数据库层  │ │  工具库   │ │
│  │(HTTP,   │ │ (SQLite,  │ │(编码,加密 │ │
│  │ Cookie, │ │  缓存)    │ │ ,压缩)    │ │
│  │ 重试)   │ │           │ │           │ │
│  └──────────┘ └───────────┘ └───────────┘ │
└────────────────────────────────────────────┘
```

### 核心原则

- UI 层绝不包含业务逻辑，仅负责界面渲染、交互和状态管理（调用 Rust API）。
- Rust 核心承载所有与界面无关的逻辑。
- 平台桥接层仅保留必须用原生 API 的功能，优先用成熟 Flutter 插件。
- 数据流：Flutter UI → Rust API → 返回纯数据 → 更新 UI。

---

## 二、对原 Android 源码的分层解剖（锁定移植范围）

原工程 legado 结构清晰，需 Agent 协助完成"代码分类"，将每个源文件/模块打上标签：

| 原模块 | 类别 | 目标归属 |
| --- | --- | --- |
| model/ 数据模型（Book, BookSource, Rule） | 纯逻辑 | Rust |
| help/ 各类解析器（JSEngine, CSS规则, 替换净化） | 纯逻辑 | Rust |
| network/ 网络请求、Cookie管理、重试 | 可移植逻辑 | Rust |
| database/ 实体、DAO、数据库操作 | 数据层 | Rust |
| ui/ Activity, Adapter, View | UI描述 | Flutter |
| service/ 后台下载服务 | 部分原生依赖 | 原生 + Rust逻辑 |
| widget/ 自定义阅读器控件 | UI | Flutter 重写 |
| 文件读写（本地书籍导入） | 平台依赖 | Flutter 插件 + Rust 解析 |
| 分享、Intent 处理 | 平台依赖 | Platform Channel |

### Agent 输出

1. 一份 **模块→目标归属** 映射表（csv/md）。
2. 每个"归入 Rust"模块的公开 API 清单（原方法签名 → Rust 函数签名草案）。
3. 强依赖 Android Context/系统服务的代码清单及替代方案建议。

### 与已有 Flutter 代码的融合

审视 LegadoTeamFlutter 现有代码，找出已实现功能，对应到分类中，避免重复迁移。如书架页已有 UI 骨架，只需对接 Rust 数据。

---

## 三、搭建 Rust 核心工程，定义 API 边界

### 3.1 初始化 Rust 工作区

项目根目录创建 `rust_core/`，使用 `flutter_rust_bridge` 模板初始化。推荐结构：

```text
rust_core/
  Cargo.toml          # workspace
  core/
    Cargo.toml
    src/
      lib.rs, models.rs, book_source.rs, rule_engine.rs,
      text_parser.rs, network.rs, db.rs, error.rs
  ffi_bridge/
    Cargo.toml
    src/
      api/            # 分模块暴露：bookshelf.rs, reader.rs, discover.rs, settings.rs
      lib.rs
```

### Agent 任务

- 生成 `Cargo.toml`，包含 `flutter_rust_bridge`、`serde`、`reqwest`、`rusqlite`、`thiserror`、`quickjs` 等依赖。
- 对齐原 Kotlin data class，实现 Rust 侧带 `Serialize`/`Deserialize` 的模型。
- 将可移植逻辑翻译为 Rust 函数。

### 3.2 难点攻克方案

| 难点 | 原 Android 实现 | Rust 替代 | 备注 |
| --- | --- | --- | --- |
| JS 书源执行 | Rhino/WebView | quickjs-rs 沙箱 | 禁用危险 API，超时 5s |
| CSS 选择器规则 | Jsoup | scraper crate | 适配原规则语法 |
| 文本替换/净化 | 自研引擎 | 直接移植为 Rust 处理 | 保持规则格式兼容 |
| 本地书籍解析 | 自研解析器 | epub, chardetng 等 | 保证编码探测准确 |
| 网络请求 + Cookie | OkHttp | reqwest + cookie_store | 模拟移动端 UA |
| 数据库 | Room | rusqlite | 表结构一致，迁移用 Rust 宏 |

> 每项均需先做最小原型验证，再正式迁移。

### 3.3 FFI 边界定义

使用 `flutter_rust_bridge v2` 自动生成。在 `ffi_bridge/src/api/` 下编写公开函数，原则：

- 所有函数返回 `Result<T, AppError>`，禁止 panic。
- 异步操作使用 `async fn`，自动转换为 Dart `Future`。

**示例：**

```rust
pub fn get_bookshelf() -> Result<Vec<Book>, String> { ... }
pub async fn search_online(source_url: &str, keyword: &str) -> Result<Vec<BookItem>, String> { ... }
```

---

## 四、Flutter 端重建 UI 并对接 Rust 数据

> **详细实施方案**：[UI_RESTRUCTURE_PLAN.md](UI_RESTRUCTURE_PLAN.md) — 包含职责边界定义、Riverpod 迁移方案、组件设计、三端响应式布局、分阶段实施计划与验收标准。

### 4.1 已有 UI 梳理与调整

- 输出当前 Flutter 页面树，确认状态管理方案（推荐统一为 riverpod）。
- 抽离业务逻辑：保持 UI 不变，将其数据调用替换为 Rust API。例如 `BookShelfPage` 原从本地数据库加载，改为 `rustApi.getBookshelf()`。
- 统一主题与组件：参照原 Android 截图微调样式，使用 `Theme.of(context)` 全局管理。
- 复杂组件重写：如阅读器翻页，必要时用 `CustomPainter` 精细控制。

### 4.2 状态管理规约

- 使用 riverpod，每个功能模块对应一个 `Notifier`，内部只调用 Rust 函数。
- 数据模型用 freezed 生成，与 Rust 模型镜像。

### 4.3 UI 开发优先级

1. 书架
2. 阅读器核心
3. 发现页
4. 设置/书源管理
5. 规则编辑器

---

## 五、分阶段迁移路线（绞杀者模式）

| 阶段 | 目标 | 关键操作 | 成功标准 |
| --- | --- | --- | --- |
| Phase 0 审计 | 摸清现有家底 | 输出 LegadoTeamFlutter 已完成功能、仍在 Dart 层的逻辑、与 Rust 断点 | 形成《现状与目标架构差距分析》文档 |
| Phase 1 核心连通 | Rust 核心能跑，Flutter 可调用 | 1. 搭建 Rust 工程，完成模型、网络、DB 封装<br>2. 实现 ping 与书架列表<br>3. 替换书架页数据源为 Rust | 书架页使用 Rust 数据展示，功能无回退 |
| Phase 2 书源引擎 | 搜索/发现切到 Rust | 1. Rust 实现书源解析、JS 沙箱<br>2. 暴露搜索 API<br>3. Flutter 发现页调用 | 发现页可搜索，结果与原版一致 |
| Phase 3 阅读器 | 阅读体验一致 | 1. Rust 提供章节内容流<br>2. Flutter 阅读器异步加载<br>3. 文本净化在 Rust 执行 | 阅读器流畅度不低于原版，规则效果相同 |
| Phase 4 管理功能 | 完全脱离原生依赖 | 书源导入导出、备份恢复、规则编辑器 | 所有管理功能可用 |
| Phase 5 清理优化 | 移除旧代码，统一风格 | 删除残留逻辑，性能调优，适配桌面端 | 代码库干净，三端可编译 |

> 每个 Phase 内 Agent 通用工作流：分析原模块 → 写 Rust + 测试 → 生成 Dart 绑定 → 修改 Flutter UI → 人工验收。

---

## 六、多人并行开发策略（UI 一人，Rust 一人）

这是本架构的核心优势：UI 与核心逻辑天然解耦，可完全并行开发。

### 6.1 角色与职责

#### A：Flutter UI 负责人

- 所有 Dart 代码：页面、组件、状态管理、路由、主题。
- 调用数据接口（Mock 或真实 Rust API），不包含业务计算。
- 使用 freezed 维护与 Rust 一致的数据模型。
- 平台功能优先用插件，必要时编写原生透传代码。

#### B：Rust 核心负责人

- `rust_core` 内所有代码：模型、网络、数据库、书源引擎、文本解析。
- 暴露 API 并通过 `flutter_rust_bridge` 生成 Dart 绑定或手动维护绑定。
- 编写单元测试，保证逻辑与原版一致。
- 编译各平台库，交付集成。

### 6.2 契约先行：API 契约 + Mock

互不阻塞的核心在于提前定义 API 契约，形成独立开发的基础。

**创建 `api_contract.md`（双方共同维护）：**

```yaml
functions:
  - name: getBookshelf
    description: 获取书架所有书籍
    input: 无
    output: Result<Vec<Book>, AppError>
    models:
      Book: { id: String, name: String, author: String, cover_url: Option<String>, ... }

  - name: searchBooks
    description: 在线搜索
    input: { source_url: String, keyword: String }
    output: Result<Vec<SearchResultItem>, AppError>

errors:
  AppError: [Network, Parse, Database, JsExecution]
```

**Flutter 侧 Mock 实现：**

```dart
abstract class CoreApi {
  Future<List<Book>> getBookshelf();
  Future<List<SearchResultItem>> searchBooks(String sourceUrl, String keyword);
}

class MockCoreApi implements CoreApi {
  // 返回硬编码样本数据，完全模拟真实返回格式
}

class RealCoreApi implements CoreApi {
  final RustLib _rustLib;
  // 包装自动生成的 Rust 调用
}
```

> 应用初始化时根据环境注入 `MockCoreApi` 或 `RealCoreApi`。UI 开发者完全不需要 Rust 环境，直接用 Mock 数据迭代所有页面和交互。

### 6.3 并行迭代流程

| 阶段 | Rust 开发者 | Flutter UI 开发者 | 同步点 |
| --- | --- | --- | --- |
| 契约定义 | 参与讨论数据模型、函数签名 | 从 UI 需求补充字段和交互 | 共同输出 `api_contract.md` |
| 骨架搭建 | 创建 Rust 工程，完成模型和基础封装，ping API | 搭建 Flutter 工程，集成 Mock API，搭建所有页面骨架 | 无，完全并行 |
| 模块冲刺 | 实现 `getBookshelf` 并写测试 | 用 Mock 数据完善书架页所有交互（下拉刷新、排序等） | Rust API 完成后，联调几分钟 |
| 复杂模块 | 实现文本解析流 `getChapterStream` | 基于 Mock 分段数据实现阅读器翻页、主题等 | 阅读器性能需密切配合 |
| 集成清理 | 优化性能，配置各平台编译 | 移除 Mock，统一主题，适配桌面端 | 最终全量联调 |

> **关键优势：** 集成时仅需将注入的实例从 `MockCoreApi` 切换为 `RealCoreApi`，页面代码零修改。

### 6.4 协作规范

- 契约文档随代码版本控制，任何修改需两人确认。
- Mock 数据：从原 Android 抓取真实 JSON 响应作为样本，保证界面调试真实。
- 分支策略：`feature/ui-*` 与 `feature/rust-*` 独立开发，集成时创建 `integration/*` 分支合并。
- CI：Rust 侧跑 `cargo test`；Flutter 侧跑 Widget 测试（利用 Mock）；集成时加冒烟测试。

---

## 七、必须注意的坑（Agent 执行强制规则）

- **JS 引擎安全：** 沙箱限制，禁用网络/文件系统，超时 5 秒。
- **数据库路径：** Rust 无法获取应用目录，须由 Flutter 通过 `init(app_dir: String)` 传入。
- **线程安全：** 所有 Rust 函数默认工作线程，长时间操作需明确异步或 `spawn_blocking`，不卡 UI。
- **统一错误处理：** 定义 `AppError` 枚举并实现 `Display`，Dart 侧 try-catch 处理。
- **编解码一致性：** 使用 `chardetng` 处理 GBK 等编码，移植时提供对比测试。
- **热重载失效：** Rust 修改需重启应用，开发阶段可先用 Mock 调 UI。
- **契约变更：** 若 Rust 实现需调整 API，必须立即更新契约并通知 UI 方，但 UI 改动量极小（通常只改 Mock 数据和字段）。

---

## 八、工具链与自动化

| 用途 | 工具 |
| --- | --- |
| Rust 编译 Android | cargo-ndk + Android NDK |
| Rust 编译 iOS | cargo lipo 或 Xcode 集成 |
| 代码生成 | `flutter_rust_bridge_codegen generate` |
| 自动化脚本 | Makefile / just（含 gen、run、test） |
| Flutter 状态管理 | riverpod + riverpod_generator |
| 数据模型 | freezed |
| 日志 | Rust: log + android_logger; Flutter: logger |
| 测试 | `cargo test`, `flutter test` |
| 网络抓包对比 | Charles / Proxyman |

---

## 九、与已有 Flutter 项目整合的第一步行动（Agent 启动指令）

1. **审计与对比：** 分析 legado 和 LegadoTeamFlutter，输出已迁移页面、未迁移功能、状态管理方式、本地存储方式，形成差距报告。
2. **契约草案（书架+搜索）：** 根据原 Android 的 Bookshelf 和 Search 相关类，输出初始 `api_contract.md` 草案，供两人确认。
3. **搭建 Rust 工作区并配置 bridge：** 在 LegadoTeamFlutter 根目录集成 `flutter_rust_bridge`，提供修改后的 `pubspec.yaml` 和 `Cargo.toml`。
4. **构建 Mock 服务脚手架：** 为 Flutter 创建 `CoreApi` 抽象、`MockCoreApi` 和注入切换逻辑，确保 UI 可独立启动。
5. **从书架模块开始"换心"：** Rust 实现 `getBookshelf`（可先返回模拟数据），Flutter 侧切换数据源，验证架构可行，然后逐模块推进。

---

## 十、Rust 功能实现规则

- 任何新的 Rust 功能实现前，必须先搜索 crates.io、GitHub、Lib.rs 寻找现成的高质量库。
- 使用"搜索→评估→确认→集成"四步流程，禁止直接手写可替代的逻辑。
- 优先选择 MIT 或 Apache 2.0 许可、维护活跃的库。
- 集成时保持对外 API 契约不变，必要时编写适配层。
- 在代码注释中标注来源仓库 URL。

---

## 附：执行要求

1. 忘记此前所有对话中关于本项目的技术栈选择、目录结构、实现顺序等任何信息。
2. 只认这份新计划里的架构（Flutter + Rust）、分层规则、分阶段步骤和 API 契约。
3. 所有回答、代码生成、建议都必须基于新计划，不可再引用旧方案。
4. 如果我在对话中无意识提到旧方案，请忽略并以新计划为准提醒我。

> 请先复述你理解的新计划核心目标，确认切换完毕，然后从 Phase 0（审计）开始给出具体执行步骤。
