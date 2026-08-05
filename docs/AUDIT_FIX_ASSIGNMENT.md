# 审计修复任务分配与完成报告（第一批 + 第二批）

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

| 条目 | 状态 | 备注 |
|---|---|---|
| §1.1 书源校验 FFI 链路 | ⛳ 继续延后 | 评估结论见 §5.4；另有并行会话在改书源管理页，UI 入口必冲突 |
| §1.2 app_log_screen 页面 | ✅ 第二批完成 | 见 §5.1 |
| §2.1 验证码输入页 / 规则订阅页 | ⛳ 待排期 | 依赖 Rust 轨：验证码仅有被动检测（CaptchaInfo）无 UI 链路；规则订阅 Rust 侧 DB/Repository/HTTP 已备但 FFI 空缺，均需契约冻结+codegen |
| §2.1 跳转确认（OpenUrlConfirm） | ✅ 第三批完成 | 降级为通用 Dialog，见 §5.6 |
| §1.3 HTTP TTS 引擎接 http_tts_repository | ✅ 无需修复 | 审计描述过期：`list_engines` 已接通 `HttpTtsRepository::find_enabled`（见 §5.3） |
| §1.4 MOBI HUFF/CDIC + KF8 | ⛳ 待排期 | 解析器移植，低频路径 |
| §3.4 design_system.md Token 同步 | ✅ 第二批完成 | 见 §5.2 |
| §4.3 高亮规则 JSON 解析下沉 Notifier | ✅ 第二批完成 | 见 §5.1 |
| §4.4 dev 构建 quickjs stub 提示 | ✅ 第二批完成 | 见 §5.2 |

---

## 4. 验收清单（供用户核对）

1. `git show 5603677fd --stat`（Rust 轨，4 文件 +212/-53）
2. `git show 6a7a68b5a --stat`（UI 轨，14 文件 +105/-35）
3. 重点目检：bookshelf 分组 Tab 白字、书源调试芯片亮暗模式、书籍信息页编辑/导出/分享失败提示
4. 复跑：`cd flutter_legado && flutter analyze && flutter test test/unit`

---

## 5. 第二批完成情况（2026-08-05）

### 5.1 UI 轨 — app 日志页 — 提交 `160affb0d`；高亮规则下沉 — 提交 `a62de97af`

`[UI] 审计修复第二批：新增应用日志页（message/crash/http 三级页签）+ 关于页入口 + 路由`

| 审计条目 | 修复内容 | 文件 |
|---|---|---|
| §1.2 应用日志页 | 新建 app_log 三件套（state/notifier/screen）：三级 TabBar 白色前景、刷新/清空/导出菜单、二次确认、错误 SnackBar；关于页加入口，routes 注册 `/app_log` | providers/app_log/×2、app_log_screen.dart、about_screen.dart、routes.dart |
| §4.3 高亮规则 JSON 下沉 | 新建类型化模型 `HighlightRule`（fromJson/toJson/displayName/styleTextColor）与 `HighlightRulesNotifier`（load/toggle/delete/save）；UI 层不再触碰 raw map，jsonDecode 全部移除 | providers/highlight_rules/×2、highlight_rules_screen.dart |
| §4.1 遗留 | about_screen 版本加载 catch 补 debugPrint（顺手修复） | about_screen.dart |

### 5.2 文档与构建轨 — 随本文档提交

| 审计条目 | 修复内容 | 文件 |
|---|---|---|
| §3.4 Token 表同步 | design_system.md 亮/暗两套 ColorScheme 表同步为 app_colors.dart 实际 iOS 色值（primary #007AFF/#0A84FF 等），头部说明改为 iOS 体系，补充 ios* 系统色清单 | docs/design_system.md |
| §4.4 stub 构建提示 | `rebuild-ffi-stub` 构建时 echo 降级提示；新增 `run-windows-stub` 开发目标 | flutter_legado/Makefile |

### 5.3 审计复核更正（第二批）

- §1.3 审计描述过期：`legado-server/src/handlers/tts.rs` 的 `list_engines` 已接通 `HttpTtsRepository::new(db.connection()).find_enabled()`，非“硬编码示例引擎”，无需代码修复。

### 5.4 §1.1 书源校验 FFI 链路评估结论（继续延后）

- **Rust 侧已就绪**：`legado-net::source_checker`（SourceChecker / CheckerConfig / CheckResult / CaptchaInfo / RedirectInfo）完整；HTTP 路由 `POST /sources/check` 与 MCP 工具 `check_sources` 均已接通并有测试。
- **FFI 侧空缺**：`legado-ffi` 与 Dart bridge 均无 `checkSource*` 绑定；`API_CONTRACT.md` 无对应条目（仅有 jsSourceSyntaxCheck 语法检查）。
- **实施路径**：冻结契约（入参书源 JSON 数组 + 搜索关键词，出参 CheckResult 数组 JSON）→ ffi.rs 薄包装 → frb codegen（两侧 frb_generated 全量重生成 + DLL content hash 同步）→ BookApi/RustApi/Mock → Notifier + UI。
- **延后原因**：① frb codegen 影响面大（生成物全量重刷 + hash 同步风险）；② **当前有并行会话正在修改书源管理页，校验 UI 入口恰在该页，实施必然冲突**。建议待书源管理页改动合入后作为独立任务执行。

### 5.5 第二批验证结果

- `flutter analyze`：无 error / warning（214 项存量 info，均在 test 目录且不涉及本批文件）
- `flutter test`：**1092 项全部通过**（含高亮规则 widget 测试 5 项回归验证）
- 提交时只精确 add 本批文件，不触碰书源管理页相关文件（避免与并行会话冲突）

### 5.6 第三批 — 跳转确认对话框（2026-08-05）

`[UI] 审计修复第三批：新增外链跳转确认对话框（对齐原版 OpenUrlConfirmDialog，降级 Dialog 实现）`

| 审计条目 | 修复内容 | 文件 |
|---|---|---|
| §2.1 跳转确认（P2） | 新建 `open_url_confirm_dialog.dart`：确认文案对齐原版「正在请求跳转链接/应用，是否跳转？」，含来源名副标题、URL 可选展示、失败提示；RSS 文章详情 WebView 拦截外链接入确认 | widgets/open_url_confirm_dialog.dart、rss_article_detail_screen.dart |

**接入范围决策**：仅内容/网页请求跳转（WebView 拦截外链）走确认；用户显式操作（关于页仓库/捐赠、词典规则、书源登录链接、「在浏览器打开」按钮、RSS 收藏打开原文）保持直开，对齐原版触发语义（原版仅书源/内容规则跳转触发）。

**降级登记**：原版菜单「禁用书源/删除书源」依赖书源管理接口，且书源管理页正由并行会话修改，本批不实现。

**验证码/规则订阅侦察结论**（同批）：验证码 Rust 侧仅 source_checker 被动检测（CaptchaInfo），无推送 UI/回填链路；规则订阅 Rust 侧 rule_subs 表/RuleSubRepository/rule_update handler/HTTP 路由已备，但 legado-ffi 与契约均空缺——两项均需 Rust 轨先行（契约冻结+codegen），继续待排期。
