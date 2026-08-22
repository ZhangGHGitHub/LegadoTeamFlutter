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
- **缺口清单清零批次**（2026-08-05，Task #162~#168）：图片书 PDF 导出（对齐 #483）/ RSA-SM2 非对称加密 JS API / txt_search frb 主链路 / 繁简转换 FFI 透传 / DB v101 偏离表补列 / unzip 断线修复 + JS 零星 API / unrar 降级处置，缺口清单 7 项全部清零（详见过期文档/REFACTORING_REMAINING_PLAN.md §4.2.4）

> ⚠️ **Rust 重构主体阶段已完成**：历史任务记录为 168/168；当前分支仍有未合流项、服务端搜索空实现、FFI 流运行时验证和 A* 外部验收，当前状态以 [REFACTORING_ACTIVE_PLAN.md](REFACTORING_ACTIVE_PLAN.md) 为准。
>
> ⚠️ **口径修正（批次3治理，Task #118，2026-08-06）**：早期「零 TODO/桩实现」声明与源码不符，已废止。实际口径：① 内置词典为小规模静态数据（契约达标、覆盖为占位级）；② legado-server 正文端点、subContent/contentRule.replaceRegex 等为 P2 待补项；③ Dart 侧 **getAudioChapterMedia 为在用真实 FFI**（audio_notifier/audio_screen 接线）；scanLocalBooks/parseTxt 仍为死代码 fallback（rust_api.dart 注释标注）；④ platform.rs 5 个死代码桩已于本批次删除。详见 [REFACTORING_REMAINING_PLAN.md](过期文档/REFACTORING_REMAINING_PLAN.md) §4.2.3 与 §5.7。

### 📊 测试统计（当前 HEAD 门禁）

| 模块 | 最近记录 |
|------|----------|
| Rust `cargo test --workspace --features quickjs` | **parser 249/0、js 497/0 + 2 ignored、ffi 355/0 + 27 ignored、server 171/0**（2026-08-22，`81ad6e220`） |
| Flutter `flutter analyze` | **0 issues**（2026-08-22） |
| Flutter `flutter test` | **+1190 全过**（2026-08-22） |

> 上表为集成分支 `integration/rust-parser-gap-fix` HEAD `81ad6e220`（P0-2 合流，2026-08-22）的可复现门禁结果；双模拟器冒烟（emulator-5554 / emulator-5556，后者为 AVD legado_5558 用户验收机）均通过。当前执行计划见 [REFACTORING_ACTIVE_PLAN.md](REFACTORING_ACTIVE_PLAN.md)。

### 🔄 进行中项

- **当前执行计划**：见 [REFACTORING_ACTIVE_PLAN.md](REFACTORING_ACTIVE_PLAN.md)。P0 三项已全部关闭（P0-1 质量门禁 2026-08-20、P0-2 parser/search 分支合流 2026-08-22、P0-3 Server 多源搜索空实现 2026-08-20）；当前焦点为 P1：FRB 流运行时验证、AutoTask action 保真、API 契约自动校验和状态口径统一。
- **残余风险与用户验收**：见 [RESIDUAL_RISKS_2026-08-13.md](RESIDUAL_RISKS_2026-08-13.md)，A\* 环境验收仍需真实素材，不能替代工程门禁。
- **源码兼容与解析 parity**：见 [SOURCE_DIFF_AUDIT_2026-08-13.md](SOURCE_DIFF_AUDIT_2026-08-13.md) 和 [PARSER_GAP_FIX_PROGRESS_20260815.md](PARSER_GAP_FIX_PROGRESS_20260815.md)。
- **历史计划与报告**：统一保存在 [过期文档](过期文档/README.md)，不作为当前任务来源。

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
| [REFACTORING_PROGRESS_DEEP_AUDIT_20260819.md](REFACTORING_PROGRESS_DEEP_AUDIT_20260819.md) | 最新重构深度审计与计划修订依据 |
| [REFACTORING_FIX_REPORT.md](过期文档/REFACTORING_FIX_REPORT.md) | 历史重构修正报告（已归档） |
| [TASK_76_SUMMARY.md](过期文档/TASK_76_SUMMARY.md) | 历史测试覆盖率总结（已归档） |

### 计划类

| 文档 | 说明 |
| --- | --- |
| [REFACTORING_ACTIVE_PLAN.md](REFACTORING_ACTIVE_PLAN.md) | 当前唯一后续重构执行计划与开放项台账 |
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
