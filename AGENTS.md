# AGENTS.md — Legado 项目 Agent 工作入口

本文件为编码 agent 提供进入 Legado 代码库的统一入口：模块地图、验证命令与规范路由。
项目概览详见 [README.md](README.md)。

## 项目概览

Legado：Rust + Flutter 跨平台阅读器，与 Android 原版（gedoor/legado）保持双轨对齐的阅读应用。

## 模块地图

| 路径 | 内容 |
|---|---|
| `app/` | Kotlin Android 主模块（1200+ 源文件），含 `app/src/main/java/io/legado/app/` |
| `modules/book/`、`modules/rhino/`、`modules/web/` | Android 子模块（书源、Rhino JS 引擎、Web 辅助） |
| `flutter_legado/` | Flutter UI（Windows 构建主模块），`lib/` 为 Dart 源码 |
| `rust/` | Rust 工作区（legado-book / legado-core / legado-db / legado-ffi / legado-js / legado-net / legado-parser / legado-server） |
| `docs/` | 项目文档（计划、报告、规范、API 契约） |
| `.qoder/` | Qoder 配置（rules 规则、skills、agents、specs、repowiki） |

## 验证命令

- **Android 单元测试**：`./gradlew :app:testAppReleaseUnitTest`（CI：`.github/workflows/test.yml`）
- **Flutter**：在 `flutter_legado/` 下 `flutter analyze && flutter test`（CI：`.github/workflows/flutter-ci.yml`）
- **Rust**：在 `rust/` 下 `cargo test`（CI：`.github/workflows/rust-ci.yml`）
- **CI 总览**：`.github/workflows/`（test / rust-ci / flutter-ci / release / BetaRelease / web 等）

## 规范与文档路由（改动前必读）

1. [.qoder/rules/legado-dev-conventions.md](.qoder/rules/legado-dev-conventions.md) — 开发规范：优先级分类（P0/P1/P2）、验证优先工作流、Git 安全实践、Windows 编码处理、文档存放规范
2. [docs/TWO_TRACK_DEV_SPEC.md](docs/TWO_TRACK_DEV_SPEC.md) — 双轨开发规范：Rust+Flutter FFI 契约冻结、Mock 驱动、原子化工作流
3. [docs/UI_FIX_PLAN.md](docs/UI_FIX_PLAN.md) — UI 修复的权威执行依据（四步文档研读流程）
4. [docs/API_CONTRACT.md](docs/API_CONTRACT.md) — FFI API 契约（跨轨变更必须先冻结契约）
5. [docs/design_system.md](docs/design_system.md) — 设计系统
6. [docs/REFACTORING_PLAN.md](docs/REFACTORING_PLAN.md) 与 [docs/REFACTORING_REMAINING_PLAN.md](docs/REFACTORING_REMAINING_PLAN.md) — 重构计划与剩余项

## 关键约束

- **原版对齐**：功能实现逻辑必须参照 Android 原版源码（功能基准：`com.legado.app.release` 3.26073003）；界面功能、页面结构与交互流程必须与原版保持一致；**UI 视觉风格允许自由改变**（配色、字体、设计语言等不受原版约束，2026-08-05 用户确认），且 UI 开发必须使用 apple-ui-designer 技能
- **双轨并存**：旧 Android 代码暂不删除，保持双轨并存；Rust 核心逻辑 + Flutter UI 为新架构
- **FFI 变更**：修改 Rust/Dart FFI 边界前，先更新 `docs/API_CONTRACT.md` 契约，再实施代码；跨轨阻塞项须 Rust 轨先行交付契约；契约修改需双方（Qoder/QoderCN）确认；Mock 数据使用从原 Android 应用抓取的真实 JSON
- **重构红线**：本项目为重构项目，禁止新增 Android 原版不存在的创意功能；发现偏离项（如推荐算法、阅读统计等）必须清理，一切以不偏离重构核心为目标
- **执行边界**：不得超范围删除或修改文件，删除/修改代码前必须先确认范围无误
- **计划驱动**：每阶段开发前先审查计划与进度文档（DEVELOPMENT.md / PROGRESS.md / REFACTORING_PLAN.md 等），确认进度符合度后按 P0/P1/P2 优先级顺序执行
- **UI 层职责边界**：UI 层只做界面渲染、交互与状态管理，不含业务逻辑；数据经 Rust Bridge 获取；遵循 UI 层与底层分离原则
- **文档存放**：新建计划/报告/交接类 `.md` 必须放 `docs/`；根目录仅保留 README.md、CHANGELOG.md、LICENSE、AGENTS.md 等约定文件
- **全中文规范**：汇报、commit 说明、代码注释全部使用中文

## Git 纪律与版本控制

- 每次改动验证通过后立即 commit 到本地；阶段性成果须 commit 并 push
- 跨轨（Rust/UI）改动须分批提交，并使用 `[Rust]` / `[UI]` 前缀标注
- 分支策略：`feature/rust-*` 与 `feature/ui-*` 独立开发，集成使用 `integration/*` 分支；仅从当前 HEAD 创建规范分支，不得改动已提交历史
- 署名规范：UI 层代码署名「— 子代理名称 + UI」，Bridge 层代码署名「— 子代理名称 + Bridge」，文档末尾附编写者署名与日期
- 批次修复按 pubspec 版本 patch 递增（如 2.0.0+2 → 2.0.1+3），每批同步更新 CHANGELOG，记录版本号与贡献者
- 进度文档（PROGRESS.md 等）须与 git 提交记录保持同步，任务编号不得重叠

## 验证与交付流程

- 每轮修复后的两级验证：子代理先在安卓模拟器（端口 5556）测试，测试通过后再安装到安卓模拟器（端口 5558）通知用户实测验收
- **模拟器冒烟测试为必做步骤**（构建+安装+启动+崩溃检查统一脚本）：`.\scripts\emulator_smoke_test.ps1 -Device emulator-5556`（子代理测试）；用户验收前执行 `-Device emulator-5558`（可加 `-CheckUI` 做书架主界面元素检查；复用 APK 加 `-SkipBuild`）；退出码 0=通过 1=失败
- 汇报纪律：确认问题彻底解决后才能汇报完成，如实汇报，不得夸大进度或完成度
- 反复出现的问题必须深挖根因、永久解决，禁止临时修补；发现的重大技术风险须正式写入重构计划文档并说明原因
- 当前开发环境为 Windows，无 make 命令：给用户的命令必须是可直接执行的 CMD 或 PowerShell 命令行，不要给 Makefile 目标

## 多代理协作规则

- 主 Agent（Qoder）职责：① 拆解并分发任务至子代理；② 推进任务，子代理卡住时主动跟进协助解困；③ 验收任务
- 冲突避让：多个子代理同时改代码时必须避让同一文件/模块；任务分配须满足文件不重叠、工作量平均、技能匹配三项原则
- 文档维护：每阶段结束须及时检查并更新所有相关文档（重构计划、进度、README 等），保证后续开发者可顺利接手
- 口头约定正式化：主动提示用户是否需要将对话中达成的口头约定整理成清单写入规则文件

## Qoder 配置说明

- `.qoder/agents/builtin/`：Qoder 产品内置专家团模板（code-reviewer、full-stack-engineer、qa、researcher、ui-operator），仅含 frontmatter，由产品自动维护，**勿手动编辑**；需要项目专用 agent 请创建到 `.qoder/agents/`（非 builtin 目录）
- `.agents/skills/`：**技能权威路径**，当前 53 个技能（资产清单与 lint 仅统计该处）
- `.qoder/skills/` 与 `.claude/skills/`：同源副本，当前 43 个与权威路径逐字节一致；10 个 flutter-* 技能尚未同步到副本。修改技能请改 `.agents/skills/` 并同步副本
- `.qoder/rules/legado-dev-conventions.md`：项目唯一规则文件，与本文档配合使用

编写者：Qoder ｜ 2026-08-10
