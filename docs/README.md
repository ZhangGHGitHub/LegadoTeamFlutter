# 项目文档索引

本文件夹统一存放 Legado 项目根目录的过程、报告、交接、分析与规范类文档。

> 说明：`README.md`、`CHANGELOG.md`、`LICENSE` 按社区惯例保留在项目根目录；`rust/`、`flutter_legado/` 等子项目内部文档仍保留在各自目录下。

## 当前状态（权威）

> **本节为项目状态的唯一权威入口，其它文档的状态描述以本节为准。**

### ✅ 已完成项

- **Phase 0-4 功能迁移**：审计、核心连通、书源引擎、阅读器、管理功能各阶段主体迁移完成
- **quickjs 启用**：JS 沙箱引擎接入并启用
- **内容搜索净化对等**：搜索/发现净化行为与 Android 原版对齐
- **importLocalBook 修复**：本地书籍导入链路修复
- **iOS 构建脚本**：iOS 平台构建脚本就位
- **集成冒烟 CI**：集成冒烟测试纳入 CI 流程
- **Mock 真实样本**：Mock 数据层接入真实样本
- **RSS 分组筛选**：RSS 分组筛选功能完成
- **书架分享**：书架分享功能完成
- **导出契约对齐**：导出行为与接口契约对齐
- **净化规则接入阅读链路**：净化规则在阅读链路中生效
- **沙箱安全加固**：JS 沙箱安全加固完成
- **Rust 延后项 Phase 1**：HTTP 单例化 ✅
- **Rust 延后项 Phase 2**：取章合并 ✅
- **Rust 延后项 Phase 3**：RSS 历史 FFI ✅
- **Rust 延后项 Phase 4**：DB 读写分离 ✅

> 🎉 **Rust 重构主体已全部完成**：148/148 原子任务完成，零 TODO/桩实现。

### 📊 测试统计（2026-08-01 实测）

| 模块 | 测试数 |
|------|--------|
| Rust DB（legado-db） | 220（215 单元 + 4 集成 + 1 文档） |
| Rust FFI（legado-ffi） | 105 |
| Flutter | 953 |
| **总计（含全部 Rust crate）** | **2362** |

### 🔄 进行中项

无。所有已规划任务均已完成。

### 👥 各轨负责人与分支

| 轨道 | 负责人 | 分支 |
| --- | --- | --- |
| Rust 核心 | Rust 负责人 | `feature/rust-core` |
| UI | UI 负责人 | `feature/ui` |

---

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
