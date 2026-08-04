# 审计修复任务分配与完成报告（第一批）

**日期**: 2026-08-05
**依据**: [PROJECT_AUDIT_REPORT.md](PROJECT_AUDIT_REPORT.md)
**分支**: `feature/rust-core`
**验收方**: 用户（AI 为执行方，修复完成后由用户验收）

---

## 1. 任务分配

| 负责人 | 职责范围 | 署名 |
|---|---|---|
| Rust 核心负责人（QoderCN） | FFI 契约对接缺口：`book_api.dart` / `rust_api.dart` / `mock_book_api.dart` 及 Rust 轨专属文件 | `QoderCN` |
| Flutter UI 负责人（Qoder） | 界面缺陷、设计规范不符、UI 层逻辑健壮性：`screens/` / `widgets/` / providers | `Qoder` |

署名格式：修复点注释 `// [审计修复 §编号] 说明 — 负责人`。

---

## 2. 第一批已完成修复

### 2.1 Rust 轨 — 提交 `5603677fd`

`[Rust] 审计修复：BookApi 补齐 appLog* 五方法（契约§2.38）并为 rust_api.dart jsonDecode 强转增加守卫`

| 审计条目 | 修复内容 | 文件 |
|---|---|---|
| §1.2（P0）契约失实 | BookApi 补 `appLogPush/appLogList/appLogClear/appLogClearAll/appLogExport` 五个抽象方法；RustApi 委托 bridge 实现；MockBookApi 内存环形缓冲假实现（每级 500 条、最新在前、导出时间升序） | book_api.dart / rust_api.dart / mock_book_api.dart |
| §4.2（P1）jsonDecode 强转无守卫 | 新增 `_decodeList/_decodeMap` 守卫 helper，16 处强转改为类型不符时抛带上下文的 FormatException（方法名 + 实际类型 + JSON 前 120 字符） | rust_api.dart |
| 测试 | mock_book_api_test.dart 新增"应用日志"组 5 项用例 | test/unit/mock_book_api_test.dart |

### 2.2 UI 轨 — 提交 `6a7a68b5a`

`[UI] 审计修复：TabBar 白色前景(P0)、语义色亮暗适配、catch 补提示、硬编码颜色 Token 化、陈旧注释清理`

| 审计条目 | 修复内容 | 文件 |
|---|---|---|
| §3.1（P0）TabBar 同色不可见 | AppBar 内分组 TabBar 显式 `labelColor: white` / `unselectedLabelColor: white70` / `indicatorColor: white` | bookshelf_screen.dart |
| §3.2（P1）语义色未亮暗适配 | chipColor 按 brightness 选 shade（与白色标签搭配保对比度）；校验成功面板绿色背景/边框/图标亮暗适配 | source_debug_screen.dart / rss_source_debug_screen.dart / source_edit_screen.dart |
| §4.1（P1）catch 静默吞噬 | book_info_screen 三处补 SnackBar + debugPrint；highlight_rules_screen / reader_bottom_bar / search_notifier 四处补 debugPrint 留痕 | 4 个文件 |
| §3.3（P2）硬编码颜色 | AppBar 前景改 onPrimary、遮罩改 colorScheme.scrim、图标兜底改 onPrimary、阴影改 colorScheme.shadow；settings_screen 黄底黑图标登记对比度豁免说明（亮黄背景亮暗固定，黑色为 iOS 惯例正确搭配） | book_info_screen.dart / ios_widgets.dart / book_grid_item.dart / settings_screen.dart |
| §4.5（P3）陈旧注释 | dict_screen 词典注释更新为已接通 FFI；search_state 历史持久化注释更新并同步 freezed 生成物 | dict_screen.dart / search_state.dart / search_state.freezed.dart |

### 2.3 验证结果

- `flutter analyze`：无 error / warning（仅存量 info）
- `flutter test test/unit`：**729 项全部通过**（含新增 appLog 5 项）

### 2.4 审计复核更正（执行中发现）

- 审计 §4.1 列出的 `book_info_screen.dart L673` 与 `highlight_rules_screen.dart L345` 复核后**已有 SnackBar**，不属于静默吞噬，未做改动。
- 子代理报告"appLog 绑定在 frb_generated.dart L79-90"不准确：实际绑定在 `bridge/ffi/ffi.dart` L1242-1262（camelCase 包装），已按真实签名对接。

---

## 3. 延后批次（需独立设计/较大工作量）

| 条目 | 延后原因 |
|---|---|
| §1.1 书源校验 FFI 链路 | 需先冻结 `checkSource*` 契约 + frb codegen + UI 菜单/进度条，建议独立任务 |
| §1.2 app_log_screen 页面 | 依赖本批 appLog 接口（已交付），可作为下一批 UI 任务 |
| §2.1 验证码输入页 / 规则订阅页 | 新页面开发，独立任务 |
| §1.3 HTTP TTS 引擎接 http_tts_repository | Rust 侧逻辑改造 |
| §1.4 MOBI HUFF/CDIC + KF8 | 解析器移植，低频路径 |
| §3.4 design_system.md Token 同步 | 文档治理，需与 UI 负责人确认口径 |
| §4.3 高亮规则 JSON 解析下沉 Notifier | 结构重构，低风险但需测试覆盖 |
| §4.4 dev 构建 quickjs stub 提示 | Makefile/启动日志改造 |

---

## 4. 验收清单（供用户核对）

1. `git show 5603677fd --stat`（Rust 轨，4 文件 +212/-53）
2. `git show 6a7a68b5a --stat`（UI 轨，14 文件 +105/-35）
3. 重点目检：bookshelf 分组 Tab 白字、书源调试芯片亮暗模式、书籍信息页编辑/导出/分享失败提示
4. 复跑：`cd flutter_legado && flutter analyze && flutter test test/unit`
