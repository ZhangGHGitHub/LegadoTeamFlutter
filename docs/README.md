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
- **上游同步窗口 2**：LegadoTeam/legado 141 提交同步（e1c102803→308ac7b1e #543）+ 全部 P0/P1/P2 跟进项完成（提交 b10285b8c、bcb583f17、c81977f01、e954c3178、94c3e1e55、e5dcf6b9e、2a6d4c865、98e6e264~24281fdd）
- **高亮体系数据层**：DB v99 迁移对齐上游 + highlights/highlightRules 表 + Repository + FFI 11 方法（一期完成）
- **E2E 遗留修复闭环**：E2E 会话遗留 6 文件全部处置提交（b3aa3fa~32fb823）
- **跨轨阻塞四连解除**：MOBI 完整解析（HUFF/CDIC + INDX/TAGX + KF8(AZW3) + NCX/封面，d994a4fdb）/ 书源校验 FFI（sourceCheck/sourceCheckStream/sourceCheckCancel，86c299923）/ 规则订阅全链路（schema v100 + FFI 7 方法，94b257390）/ 验证码交互通道（JS 钩子 + FFI 事件流 + 提交回传，6f5614e24）
- **缺口清单清零批次**（2026-08-05，Task #162~#168）：图片书 PDF 导出（对齐 #483）/ RSA-SM2 非对称加密 JS API / txt_search frb 主链路 / 繁简转换 FFI 透传 / DB v101 偏离表补列 / unzip 断线修复 + JS 零星 API / unrar 降级处置，缺口清单 7 项全部清零（详见 docs/REFACTORING_REMAINING_PLAN.md §4.2.4）

> 🎉 **Rust 重构主体已全部完成**：168/168 原子任务完成。
>
> ⚠️ **口径修正（批次3治理，Task #118，2026-08-06）**：早期「零 TODO/桩实现」声明与源码不符，已废止。实际口径：① 内置词典为小规模静态数据（契约达标、覆盖为占位级）；② legado-server 正文端点、subContent/contentRule.replaceRegex 等为 P2 待补项；③ Dart 侧 **getAudioChapterMedia 为在用真实 FFI**（audio_notifier/audio_screen 接线）；scanLocalBooks/parseTxt 仍为死代码 fallback（rust_api.dart 注释标注）；④ platform.rs 5 个死代码桩已于本批次删除。详见 [REFACTORING_REMAINING_PLAN.md](REFACTORING_REMAINING_PLAN.md) §4.2.3 与 §5.7。

### 📊 测试统计（2026-08-05 实测）

| 模块 | 测试数 |
|------|--------|
| Rust（workspace 全 crate） | workspace 默认 2283 + quickjs feature 547 |
| Flutter | 1087 |
| **总计** | **约 3400**（以实测为准：2026-08-05 全量回归零失败） |

> 2026-08-05 全量回归实测：Rust workspace 2283 + quickjs feature 547 + Flutter 1087，零失败；flutter analyze 0 issues。（缺口清单清零批次新增测试统计待回归更新）

### 🔄 进行中项

- **残留风险收口（2026-08-13）**：见 [RESIDUAL_RISKS_2026-08-13.md](RESIDUAL_RISKS_2026-08-13.md)（D1/F1–F7/T6 等多数已闭合；**A\*** 环境验收仍 ⛔）；主台账 [REFACTORING_REMAINING_PLAN.md](REFACTORING_REMAINING_PLAN.md) v1.43。
- **源码兼容 backlog**：见 [SOURCE_DIFF_AUDIT_2026-08-13.md](SOURCE_DIFF_AUDIT_2026-08-13.md) / REMAINING **§5.15**（工程项已空；仅剩 A\* 实网/素材验收）。
- **schema**：v104 + **v105**（Migration104To105，ruleSubs/dictRules/keyboardAssists Room 对齐）已落地。

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
| [REFACTORING_REMAINING_PLAN.md](REFACTORING_REMAINING_PLAN.md) | 重构剩余工作计划（P0-P3 遗留任务清单与执行顺序；§5.15 SOURCE_DIFF backlog） |
| [RESIDUAL_RISKS_2026-08-13.md](RESIDUAL_RISKS_2026-08-13.md) | 残留风险销账表（工程收口；A* 仍 ⛔） |
| [SOURCE_DIFF_AUDIT_2026-08-13.md](SOURCE_DIFF_AUDIT_2026-08-13.md) | 源码级差异审计（工程开放项已销；仅剩 A\*） |
| [GAP_AUDIT_2026-08-12.md](GAP_AUDIT_2026-08-12.md) | 原版 vs 重构缺口审计 |
| [USER_TEST_RESULTS_2026-08-13.md](USER_TEST_RESULTS_2026-08-13.md) | 5556 全量门禁实测 |

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
