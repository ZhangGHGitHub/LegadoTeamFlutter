# 双轨协作开发规范（UI 轨与 Rust 轨）

**日期**: 2026-08-01
**版本**: v1.0
**维护人**: Legado 开发团队（Qoder / QoderCN）

---

## 1. 背景与目标

### 1.1 为什么分轨

Legado Flutter 重构采用 **Rust 核心引擎 + Flutter 跨平台 UI** 架构，两端通过 `flutter_rust_bridge`（FFI）连接。在实际开发中暴露出以下痛点：

- **UI 迭代被 Rust 交叉编译拖慢**：每次修改 Rust 代码都需重新编译 cdylib、执行 codegen、同步 DLL，一次完整循环耗时数分钟，严重拖慢 UI 调整节奏。
- **UI 对齐安卓需要高频迭代**：Flutter 端需逐屏对照 Android 原版精调像素级差异，要求秒级热重载。
- **两人可并行**：项目采用 Qoder 与 QoderCN 双向协作模式，天然适合一人专注 UI、一人专注 Rust 引擎的并行分工。

### 1.2 目标

| 目标 | 说明 |
|------|------|
| 解耦迭代节奏 | UI 轨无需等待 Rust 编译即可全速开发 |
| 明确文件归属 | 消除双轨同时修改同一文件导致的冲突 |
| 契约驱动协作 | 通过 BookApi 抽象接口 + Mock 机制实现松耦合 |
| 规避已知坑 | codegen 产物一致性、DLL 前置重编译等铁律固化 |

---

## 2. 轨道划分与工作范围

### 2.1 目录级边界表

| 轨道 | 允许修改 | 禁止修改 |
|------|----------|----------|
| **UI 轨** | `flutter_legado/lib/src/{screens,widgets,providers,theme,utils,l10n}`、`flutter_legado/test/` | `rust/`、`rust_api.dart` 方法签名、`bridge/`、`frb_generated*`、`pubspec.yaml` 原生依赖段 |
| **Rust 轨** | `rust/`、`rust_api.dart`（新增方法）、`bridge/`、codegen 产物（`frb_generated.dart` / `frb_generated.rs`） | `flutter_legado/lib/src/{screens,widgets,theme}`（UI 层） |

### 2.2 灰色地带约定

- **providers 属 UI 轨**，但 provider 调用的 `BookApi` 方法若需新增，走第 4 节"契约变更流程"。
- **pubspec.yaml**：纯 Dart 依赖（如 UI 库）由 UI 轨自行添加；涉及原生插件或 `flutter_rust_bridge` 版本变更由 Rust 轨负责。
- **公共配置文件**（`Cargo.toml`、`settings.gradle`、`build.gradle`）：修改前必须通知对方，沿用既有协作规范。

---

## 3. FFI 边界铁律

> 本节规则为强制性，违反将导致运行时崩溃。

### 3.1 codegen 归属

- `flutter_rust_bridge_codegen generate` **只由 Rust 轨执行**。
- 产物 `frb_generated.dart` 与 `frb_generated.rs` **必须由同一次 codegen 生成并一次性提交**。
- 禁止手改 `frb_generated*` 任何内容（包括 content hash），codegen 会覆盖手改。

### 3.2 已知坑：content hash 不匹配

每次 codegen 会重新计算双侧 content hash。若 codegen 后未重编译 Rust DLL，旧 DLL 中嵌入的 hash 与新生成的 Dart 侧 hash 不一致，启动即报：

```
Content hash on Dart side (X) is different from Rust side (Y),
indicating out-of-sync code
```

**正确做法**：codegen 与 `cargo build -p legado-ffi` 绑定为原子操作（Makefile `gen` 目标已实现）。

### 3.3 UI 轨禁区

- UI 轨**永远不手改** `bridge/` 目录下任何文件。
- UI 轨**不执行** codegen 命令。
- 若 UI 轨发现 FFI 调用报错，应报告 Rust 轨处理，而非自行修改。

### 3.4 DLL / .so 构建

- 构建由 Rust 轨负责。
- Windows 平台遵循项目既有 CMake 自动复制机制（构建时自动将 `legado_ffi.dll` 复制到 Flutter 构建输出目录）。
- DLL 被运行进程锁定时需先停止 Flutter 进程再编译。

---

## 4. 契约变更流程

项目通过 `BookApi` 抽象接口实现 UI 与 Rust 的解耦：

```
BookApi（抽象接口）
  ├── RustApi（真实 FFI 实现）
  └── MockBookApi（假数据实现）
```

切换机制：`--dart-define=USE_MOCK=true` 启用 Mock，否则走真实 FFI。

### 4.1 新增 API

- Rust 轨可自由添加新方法，但必须**同步完成三件事**：
  1. `BookApi` 接口新增抽象方法
  2. `RustApi` 提供真实实现
  3. `MockBookApi` 补对应假数据实现
- 更新 `API_CONTRACT.md` 登记新方法签名与返回结构。

### 4.2 修改 / 删除已有 API（破坏性变更）

- 必须**双轨评审确认**后才能修改。
- 同步修改：接口定义 → RustApi → MockBookApi → 全部 UI 调用点。
- 在 PR 描述中明确标注"破坏性变更"及影响范围。

### 4.3 UI 轨需要新数据时

流程如下：

1. **登记需求**：在 `API_CONTRACT.md` 的"需求区"登记（方法名 + 入参 + 返回 JSON 结构示例）。
2. **Mock 先行**：UI 轨自行在 `MockBookApi` 添加假实现，继续 UI 开发。
3. **Rust 交付**：Rust 轨按契约实现真实方法，更新 `RustApi`。
4. **验证切换**：UI 轨去掉 `USE_MOCK=true`，验证真实数据流通。

---

## 5. Mock 开发工作流（UI 轨日常）

### 5.1 启动命令

```bash
flutter run -d windows --dart-define=USE_MOCK=true
```

- 无需 DLL、无需 Rust 编译环境。
- 秒级热重载，专注 UI 调整。

### 5.2 日常流程

1. 启动 Mock 模式。
2. 对照 `docs/baseline_android/` 截图逐屏精调。
3. 使用 `flutter analyze` 确保静态分析无错误。
4. 编写 / 更新 `flutter_legado/test/` 下对应 Widget 测试。
5. 提交到 `feature/ui-<描述>` 分支。

### 5.3 实机验证

- 里程碑节点才构建 APK 上模拟器 / 实机对照。
- APK 构建由 Rust 轨或 CI 执行（涉及 Rust 交叉编译）。
- UI 轨不自行执行含 Rust 编译的构建流程。

---

## 6. Git 分支规范

### 6.1 分支命名

| 轨道 | 分支前缀 | 示例 |
|------|----------|------|
| UI 轨 | `feature/ui-<描述>` | `feature/ui-bookshelf-grid` |
| Rust 轨 | `feature/rust-<描述>` | `feature/rust-search-engine` |
| 修复 | `fix/<描述>` | `fix/content-hash-sync` |

### 6.2 冲突处理

- FFI 边界文件（`bridge/`、`frb_generated*`、`rust_api.dart`）冲突时**以 Rust 轨为准**。
- UI 层文件冲突时以 UI 轨为准。
- 公共文件冲突双方协商。

### 6.3 合并顺序

```
Rust 轨先合（含 codegen 产物 + 重编译 DLL）
        ↓
UI 轨 rebase 到最新 master 后合入
```

- 此顺序确保 UI 轨 rebase 后拿到最新 FFI 产物，避免 hash 不匹配。

### 6.4 提交信息

- 使用中文（项目既有规范）。
- 格式建议：`[UI] 书架页网格布局调整` / `[Rust] 搜索引擎添加分页支持`。

---

## 7. 集成节奏

### 7.1 周期

- 建议**每周一次**集成验证。
- 里程碑前可增加频次。

### 7.2 集成验证步骤

1. 合并双轨分支到集成分支 / master。
2. 全量 `flutter test`（UI 轨负责确保通过）。
3. 全量 `cargo test`（Rust 轨负责确保通过）。
4. APK / Windows 构建。
5. 模拟器 / 桌面端冒烟测试。

### 7.3 集成失败处理

| 失败类型 | 责任方 | 处理方式 |
|----------|--------|----------|
| FFI 调用崩溃 / hash 不匹配 | Rust 轨 | 回退 Rust 轨提交，重新 codegen + 编译 |
| UI 渲染异常（Mock 通过但真实数据异常） | 双方协同 | 检查契约是否一致，修正数据格式 |
| 编译错误（Dart 侧） | UI 轨 | 修复后重新提交 |
| 编译错误（Rust 侧） | Rust 轨 | 修复后重新提交 |

- 集成失败时，优先回退到上一个已知良好的集成点，再逐步排查。

---

## 8. 附则

### 8.1 与既有文档的关系

| 文档 | 关系 |
|------|------|
| [legado-dev-conventions.md](../.qoder/rules/legado-dev-conventions.md) | 通用开发规范，本规范为其在双轨场景下的补充 |
| [API_CONTRACT.md](API_CONTRACT.md) | 契约登记表，本规范第 4 节流程的操作载体 |
| [VERSION_CONTROL.md](VERSION_CONTROL.md) | 版本记录，集成里程碑在此登记 |
| [DEVELOPMENT.md](DEVELOPMENT.md) | 开发者指南，含构建与运行说明 |

### 8.2 生效与修订

- **生效日期**：2026-08-01
- **修订流程**：任何一轨提出修订 → 双方评审确认 → 更新本文档并记录版本号 → 通知全员。
- 修订时同步更新文档头部版本与日期。

### 8.3 术语表

| 术语 | 含义 |
|------|------|
| UI 轨 | 负责 Flutter UI 层开发的轨道 |
| Rust 轨 | 负责 Rust 引擎 + FFI 边界的轨道 |
| codegen | `flutter_rust_bridge_codegen generate`，生成 FFI 桥接代码 |
| 契约 | `BookApi` 抽象接口定义的方法签名与数据结构约定 |
| Mock 模式 | `--dart-define=USE_MOCK=true` 启用假数据实现 |

---

**最后更新**: 2026-08-01
**维护者**: Legado 开发团队
