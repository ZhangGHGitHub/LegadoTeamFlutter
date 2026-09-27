# 过期文档归档

本目录保存已经被当前计划、最新审计或后续源码提交替代的历史材料。文档保留用于追溯，不再作为当前开发任务、完成度或测试状态的依据。

当前依据：

- [后续重构执行计划](../REFACTORING_ACTIVE_PLAN.md)
- [项目文档索引](../README.md)
- [API 契约](../API_CONTRACT.md)
- [双轨开发规范](../TWO_TRACK_DEV_SPEC.md)
- [残余风险](../RESIDUAL_RISKS_2026-08-13.md)
- [源码差异审计](../SOURCE_DIFF_AUDIT_2026-08-13.md)
- [最新深度审计](REFACTORING_PROGRESS_DEEP_AUDIT_20260819.md)（2026-08-19 历史快照，已归档于本目录；当前状态以 Active 计划为准）

归档规则：

1. 历史报告可以引用当时的提交和测试数字，但不得覆盖当前状态。
2. 归档文档中的相对路径仅保证在归档目录结构下可追溯；新增任务不得继续追加到这些文件。
3. 移动归档文档时同步更新当前文档的入口链接，避免把历史文件误列为活跃计划。

## 替代关系（2026-09-27 文档统一批次）

> 16 篇于 2026-09-27 经未结项核验后归档；逐条证据（commit/行号级）见本目录 `RESEARCH_LEGACY_PLANS_20260927_A.md` / `RESEARCH_LEGACY_PLANS_20260927_UI.md`；移动映射见 `ARCHIVE_MAP_20260922.md` §四。

| 归档文档 | 替代去向 / 仍有效指针 |
|---|---|
| AUDIT_FIX_ASSIGNMENT.md | 修复证据在提交与源码；无未结项 |
| IOS_TRACK_FEASIBILITY_20260830.md | 仍有效项已登记 Active P2-23 / P3-8；签名矩阵、插件对照表、平台限制为勘察证据保留全文 |
| PARSER_GAP_FIX_PROGRESS_20260815.md | A* 验收由 Active P2-4 + RESIDUAL_RISKS §A* 跟踪 |
| SEARCH_PARITY_REMEDIATION_PLAN_20260828.md | 主体已收口（S0-C / F1 / P2-19）；3 条开放项挂 Active P3-6；armv7 决策项待裁决（P2-24） |
| UI_FIX_PLAN.md | 视觉标准由 [SCREEN_1TO1_PARITY_SPEC_20260914.md](../SCREEN_1TO1_PARITY_SPEC_20260914.md) 取代 |
| UI_MD3_PLAN.md | 由 [SCREEN_1TO1_PARITY_SPEC_20260914.md](../SCREEN_1TO1_PARITY_SPEC_20260914.md) 接管；动态取色残余见 Active D9 段 |
| UI_MD3_ALIGNMENT_PLAN.md | 90-98% 复刻口径被一比一取代；「自定义主题并存」「阅读器沉浸域」两条决策仍有效 |
| UI_MD3_LAYOUT_PLAN.md / UI_MD3_LAYOUT_PLAN_PROGRESS_20260905.md | 四批已交付收口（2.0.161-165）；保留项被一比一台账与 UI_MD3_GAP_REPORT 吸收 |
| UI_ONE_TO_ONE_CLONE_PLAN_20260905.md | 由 [SCREEN_1TO1_PARITY_SPEC_20260914.md](../SCREEN_1TO1_PARITY_SPEC_20260914.md) 取代；**§〇 红线豁免授权记录仍有效**（AI 摘要改写/角色卡/相关书） |
| UI_SYNC_REFACTOR_PLAN_20260905.md | 当日交付收口；§三参数取证可引用；渲染矩阵补页已登记 Active 低优候选 |
| UI_REMAINING_DEV_SUGGESTIONS_20260909.md | 批 A-E 完成；§E 首页模块管理「2026-09-11 暂不」裁决仍有效 |
| PARITY_FIX_TASKS_B2_20260916.md | 批 2 已交付（2.0.264-266）；状态由 parity 台账承载 |
| SESSION_REPORTS_20260829-31.md / LEGADO_TEAM_DEV_HISTORY.md | 开发史记录（保留原文），不代表当前工具或流程 |
| PENDING_DELETE_20260920.md | 清理已执行核销；P1 项经 Active P2-17 闭环 |

编写者：Codex ｜ 2026-08-19
