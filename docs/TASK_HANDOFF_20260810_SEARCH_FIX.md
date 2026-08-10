# 任务交接：搜索/阅读 UI 三问题修复（2026-08-10）

**交接原因**：原会话（tab1，2026-08-02 创建，会话文件 `...-285da79c6886-recovery-...jsonl`）上下文膨胀至 85 万 tokens，且 Reasonix v1.21.5 自动压缩投影未持久化导致「压缩→回滚→再压缩」循环（当日归档 49 次 / 86MB，详见 `docs/` 下方说明）。任务现场移交至新会话继续，本文档为唯一交接依据。

**交接人**：Reasonix ｜ 2026-08-10

---

## 1. 任务链回顾（原会话已完成部分）

| 阶段 | 状态 | 落点 |
|------|------|------|
| 全量审计：重构后代码（rust/ + flutter_legado/）对比上游 #672，检查进度与缺陷 | ✅ 已完成 | `docs/REFACTORING_AUDIT_REPORT_20260810.md`（v2 修订，**未提交 git**）；`docs/REFACTORING_REMAINING_PLAN.md` 已写入后续修改计划（署名 Reasonix） |
| 思兔阅读需登录书源「刷新目录失败」 | ✅ 已修复并提交 | v2.0.9（`2bc331c0b`）：XPath 引擎 xmlns 声明根治 + loginCheckJs 语义修复（`92f5d9247`） |
| 精准搜索卡顿、搜索结果排列不对齐原版、bookUrl 不能为空 | ✅ 已修复并提交 | v2.0.10（`a41fb879b`，2026-08-10 21:29:04）：① 排序对齐原版 mergeItems 四档分桶；② 卡顿修复（分桶移入批次回调）；③ bookUrl 空校验文案可读化（`822f3e58e`）。REMAINING_PLAN 版本记录 v1.22 |
| **搜索/阅读 UI 三问题（原 USER#29，中断未完成）** | 🔴 **未完成** | 见下方 §2 |

当前版本：`flutter_legado/pubspec.yaml` = **2.0.10+12**（下一批次递增为 2.0.11+13）。

## 2. 待办任务：三问题修复（本次交接核心）

用户原始反馈：「搜索时遇到问题底部会有异常书源的弹窗提示；搜索框不能完全显示搜索文字；书籍信息页简介应该默认全部显示，解决以上问题」

### 问题 1：搜索异常书源弹窗提示

- **现象**：搜索时底部出现「异常书源」弹窗提示，需确认提示来源与触发逻辑是否对齐原版
- **已完成排查**（中断点）：
  - `search_notifier.dart` 批次回调中**没有**消费 `batch['error']`（仅 `onError` 流错误 → state.error）
  - 已排除 `_buildBody` 的 ErrorView（整页错误，非底部弹窗）
  - 中断时正在全库搜 `finished_count|total_count|batch['error']|sourceName.*失败|搜索.*失败|书源.*失败` 的消费点
- **下一步**：确认 Rust 侧批次 JSON 的 error 字段（`rust/legado-ffi/src/api/search.rs` 批次结构）→ 找到或补上 Flutter 侧 SnackBar 消费点（原版为 SearchModel/批次错误弹 SnackBar），对齐原版行为

### 问题 2：搜索框不能完全显示搜索文字

- **根因已定位**（未实施）：
  - `flutter_legado/lib/src/screens/search_screen.dart` AppBar 内 TextField：`height: 36` + `contentPadding: symmetric(horizontal: 12, vertical: 0)`，但 suffixIcon 默认 `IconButton` 高 48px → 撑破 36px 高度导致文字垂直被裁切
- **修复方案**（原会话已确定）：
  - `isDense: true`
  - `textAlignVertical: TextAlignVertical.center`（垂直居中防裁切）
  - suffixIcon 改用 `IconButton(padding: EdgeInsets.zero, constraints: BoxConstraints(minWidth: 32, minHeight: 32), iconSize: 20)`（或等效缩小）
  - 高度 36 保持

### 问题 3：书籍信息页简介默认全部显示

- **根因已定位**（未实施）：
  - `flutter_legado/lib/src/screens/book_info_screen.dart:1755`：`_ExpandableText` 默认 `bool _expanded = false`（折叠 3 行 + 展开按钮）
- **修复方案**：默认 `_expanded = true`（默认展开），保留「收起」按钮（用户可收起）；`showToggle` 的 TextPainter 自适应逻辑保留（短简介不显示切换控件）

## 3. 实施要求（对齐项目规范）

1. **优先级**：P0 按问题 1→2→3 顺序；每项修完跑 `flutter test`（基线 1092 全过）
2. **验证**：`flutter analyze` + `flutter test`；随后模拟器冒烟 `.\scripts\emulator_smoke_test.ps1 -Device emulator-5556`（必做），用户验收用 `-Device emulator-5558`；必要时补 `test/unit/search_notifier_test.dart` 单测
3. **版本与文档**：本批次完成后 pubspec 递增 **2.0.11+13**，同步更新 `CHANGELOG.md`（记录版本号与贡献者 Reasonix）与 `docs/REFACTORING_REMAINING_PLAN.md`（版本记录 v1.23，登记三问题修复）；提交分批使用 `[UI]` 前缀
4. **范围红线**：只修上述三问题；不得改动无关文件；UI 视觉自由但行为对齐 Android 原版（功能基准 `com.legado.app.release` 3.26073003）

## 4. 环境与注意事项（新会话必读）

- **git 工作区当前很脏且与本任务无关**：`.qoder/repowiki/`、`.agents/skills/`、`.claude/skills/` 等有大量未提交改动（Qoder 侧历史遗留），**不要动、不要提交**；只提交本任务相关文件（用 `git add <具体文件>`，禁止 `git add -A`）
- **待提交项**：`docs/REFACTORING_AUDIT_REPORT_20260810.md` 未跟踪，属上一阶段产物，建议一并提交（可选，由新会话确认）
- **临时垃圾文件**（可提示用户清理，勿自行删除）：`_verify_batch3/`、`_verify_batch6/`、`expired_2026-08/`、`tmp_*.txt`、`flutter_legado/_align22_*.png`、`flutter_legado/_search_read_fix3_*.png`、`flutter_legado/crash_last_screenshot.png`、`rust/_build_p79_apk.log`、`reasonix.toml` 等
- **自动压缩告警**：本会话开始后若状态栏 compact 频繁出现、上下文回滚，说明压缩循环复发——立即开新会话并引用本文档（根因：Reasonix v1.21.5 压缩投影未持久化，已上报）
- **原会话存档**：`%APPDATA%\reasonix\archive\20260810-*.jsonl`（49 份，压缩归档），需要历史细节可用 `history` 工具（scope=global）检索

## 5. 新会话启动提示词（直接粘贴使用）

```
请先阅读 docs/TASK_HANDOFF_20260810_SEARCH_FIX.md（任务交接文档），然后继续执行其中 §2 的三个待办修复：
1. 搜索异常书源弹窗提示（定位 error 批次消费并补齐，对齐原版）
2. 搜索框文字显示不全（按文档方案修复 search_screen.dart 搜索框）
3. 书籍信息页简介默认全部显示（book_info_screen.dart _ExpandableText 默认展开）
要求：按文档 §3 实施要求执行（flutter analyze + flutter test + 模拟器冒烟 5556；完成后版本递增 2.0.11+13，同步 CHANGELOG 与 REMAINING_PLAN v1.23）；只提交本任务相关文件，禁止 git add -A。
```

---

*本交接文档由 Reasonix 编写，2026-08-10；依据原会话 29 条用户指令、git 提交历史（HEAD a41fb879b）与中断现场（interrupted_turn）整理。*
