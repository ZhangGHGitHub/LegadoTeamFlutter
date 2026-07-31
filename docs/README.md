# 项目文档索引

本文件夹统一存放 Legado 项目根目录的过程、报告、交接、分析与规范类文档。

> 说明：`README.md`、`CHANGELOG.md`、`LICENSE` 按社区惯例保留在项目根目录；`rust/`、`flutter_legado/` 等子项目内部文档仍保留在各自目录下。

## 📑 文档目录

### UI 修复系列

| 文档 | 说明 |
| --- | --- |
| [UI_FIX_README.md](UI_FIX_README.md) | UI 修复项目文档索引 |
| [UI_FIX_HANDOFF.md](UI_FIX_HANDOFF.md) | UI 修复工作交接文档（当前状态与进度） |
| [UI_FIX_PLAN.md](UI_FIX_PLAN.md) | Legado UI 修复详细计划与时间表 |
| [UI_FIX_SUMMARY.md](UI_FIX_SUMMARY.md) | UI 修复工作完整总结 |
| [UI_COMPARISON_REPORT.md](UI_COMPARISON_REPORT.md) | Flutter 与 Android UI 对比分析报告 |
| [UI_DIFFERENCE_PRIORITIES.md](UI_DIFFERENCE_PRIORITIES.md) | UI 差异优先级分类文档（P0-P3） |

### Kotlin 同步

| 文档 | 说明 |
| --- | --- |
| [KOTLIN_SYNC_REPORT.md](KOTLIN_SYNC_REPORT.md) | Kotlin 代码同步报告 |
| [KOTLIN_LAYOUT_ANALYSIS.md](KOTLIN_LAYOUT_ANALYSIS.md) | Kotlin 排版引擎深度分析报告 |

### 报告类

| 文档 | 说明 |
| --- | --- |
| [REFACTORING_FIX_REPORT.md](REFACTORING_FIX_REPORT.md) | 重构修正执行报告 |
| [TASK_76_SUMMARY.md](TASK_76_SUMMARY.md) | Task #76：自动化测试覆盖率提升最终总结 |

### 计划类

| 文档 | 说明 |
| --- | --- |
| [REFACTORING_REMAINING_PLAN.md](REFACTORING_REMAINING_PLAN.md) | 重构剩余工作计划（P0-P3 遗留任务清单与执行顺序） |

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
