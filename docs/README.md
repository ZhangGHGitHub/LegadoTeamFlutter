# 项目文档索引

本文件夹统一存放 Legado 项目根目录的过程、报告、交接、分析与规范类文档。

> 说明：`README.md`、`CHANGELOG.md`、`LICENSE` 按社区惯例保留在项目根目录；`rust/`、`flutter_legado/` 等子项目内部文档仍保留在各自目录下。

## 重构状态与流程

- 当前任务、优先级、状态和进度：只查看 [REFACTORING_ACTIVE_PLAN.md](REFACTORING_ACTIVE_PLAN.md)。
- Agent 派发、实施、验证、证据和关闭：遵循 [REFACTORING_WORKFLOW.md](REFACTORING_WORKFLOW.md)。
- 本文件不维护测试数字、分支负责人或第二份阶段状态，避免旧基线被误认为当前结果。

## 📑 文档目录

### UI 修复系列

| 文档 | 说明 |
| --- | --- |
| [UI_FIX_README.md](过期文档/UI_FIX_README.md) | 历史 UI 批次材料索引；不得作为当前任务入口 |
| [UI_FIX_HANDOFF.md](过期文档/UI_FIX_HANDOFF.md) | 历史 UI 批次交接记录 |
| [UI_FIX_PLAN.md](UI_FIX_PLAN.md) | 已废止的 UI 修复计划，仅供追溯；视觉标准已过时 |
| [UI_FIX_SUMMARY.md](过期文档/UI_FIX_SUMMARY.md) | 历史 UI 批次总结 |
| [UI_COMPARISON_REPORT.md](过期文档/UI_COMPARISON_REPORT.md) | 历史 UI 对比材料；当前视觉验收见 Parity 规范与台账 |
| [UI_DIFFERENCE_PRIORITIES.md](过期文档/UI_DIFFERENCE_PRIORITIES.md) | 历史 UI 差异分类 |

### Kotlin 同步

| 文档 | 说明 |
| --- | --- |
| [KOTLIN_SYNC_REPORT.md](过期文档/KOTLIN_SYNC_REPORT.md) | Kotlin 代码同步历史报告 |
| [KOTLIN_LAYOUT_ANALYSIS.md](过期文档/KOTLIN_LAYOUT_ANALYSIS.md) | Kotlin 排版引擎历史分析 |

### 报告类

| 文档 | 说明 |
| --- | --- |
| [REFACTORING_PROGRESS_DEEP_AUDIT_20260819.md](过期文档/REFACTORING_PROGRESS_DEEP_AUDIT_20260819.md) | 2026-08-19 重构深度审计（历史快照，当前状态须复核） |
| [REFACTORING_FIX_REPORT.md](过期文档/REFACTORING_FIX_REPORT.md) | 历史重构修正报告（已归档） |
| [TASK_76_SUMMARY.md](过期文档/TASK_76_SUMMARY.md) | 历史测试覆盖率总结 |

### 计划类

| 文档 | 说明 |
| --- | --- |
| [REFACTORING_ACTIVE_PLAN.md](REFACTORING_ACTIVE_PLAN.md) | 当前唯一后续重构执行计划与开放项台账 |
| [REFACTORING_WORKFLOW.md](REFACTORING_WORKFLOW.md) | Agent 派发、实施、验证与关闭的统一流程 |
| [READING_FLOW_DEFECT_HUNT_PLAN_20260924.md](READING_FLOW_DEFECT_HUNT_PLAN_20260924.md) | 阅读主流程缺陷发现与取证方法；开放状态以 Active 计划为准 |
| [SCREEN_1TO1_PARITY_SPEC_20260914.md](SCREEN_1TO1_PARITY_SPEC_20260914.md) | 参考版视觉一比一规范 |
| [RESIDUAL_RISKS_2026-08-13.md](RESIDUAL_RISKS_2026-08-13.md) | 残余风险与 A* 外部验收矩阵 |
| [SOURCE_DIFF_AUDIT_2026-08-13.md](SOURCE_DIFF_AUDIT_2026-08-13.md) | 源码级差异证据 |
| [PARSER_GAP_FIX_PROGRESS_20260815.md](PARSER_GAP_FIX_PROGRESS_20260815.md) | 解析 parity 进度与交接 |
| [过期文档/README.md](过期文档/README.md) | 历史阶段计划、审计与用户验收材料归档 |

### 规范类

| 文档 | 说明 |
| --- | --- |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Legado 开发指南（含版本控制与发布流程） |
| [VERSION_CONTROL.md](VERSION_CONTROL.md) | 项目版本控制记录 |
| [TWO_TRACK_DEV_SPEC.md](TWO_TRACK_DEV_SPEC.md) | 双轨协作开发规范（UI 轨与 Rust 轨分离开发） |
| [API_CONTRACT.md](API_CONTRACT.md) | BookApi 接口契约文档（UI 轨与 Rust 轨唯一接口基准） |
| [api.md](api.md) | 阅读 API 接口文档 |

## 📁 文档存放规范

为维护项目根目录整洁，特制定以下文档存放规范：

1. **统一存放位置**：后续所有新建的计划、报告、交接、分析类 `.md` 文档必须创建在 `docs/` 文件夹内，**不允许散落在项目根目录**。
2. **子项目文档**：`rust/`、`flutter_legado/` 等子项目内部文档保留在各自子项目目录下。
3. **根目录例外**：`README.md`、`CHANGELOG.md`、`LICENSE` 按社区惯例保留在项目根目录。
4. **引用路径**：跨目录引用文档时使用正确的相对路径（如 `docs/` 内文档引用 `rust/` 下文档应写为 `../rust/xxx.md`）。
