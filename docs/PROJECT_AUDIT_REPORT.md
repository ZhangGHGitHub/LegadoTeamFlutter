# Legado 全项目系统性审计报告

**审计日期**: 2026-08-05
**审计范围**: `app/`（Android 原版）、`flutter_legado/`（Flutter 重构）、`rust/`（Rust 核心）、FFI 契约对接
**对齐标准**: 界面功能、页面结构与交互流程对齐 Android 原版（基准 `com.legado.app.release` v3.26073003）；UI 视觉风格自由（2026-08-05 校准）
**审计方法**: 四维并行盘查（功能缺口 / 代码质量 / FFI 契约 / 设计规范）+ 关键结论逐项代码复核

---

## 0. 执行摘要

| 维度 | 结论 |
|------|------|
| 整体完成度 | **高**。39 个功能页面全部落地，190 个契约方法基本接通，Rust 侧零 `todo!()`/`unimplemented!()` 桩 |
| 架构健康度 | **好**。全库验证：UI 层（screens/widgets）**零 bridge/frb_generated 直调**，业务数据已统一走 BookApi+Notifier |
| P0 问题 | 2 项（BookApi 接口缺口、TabBar 同色不可见风险） |
| P1 问题 | 6 项（书源校验入口缺失、验证码页缺失、异常静默吞噬、暗色语义色、jsonDecode 强转、文档失实） |
| P2/P3 问题 | 10+ 项（缺失次要页面、硬编码颜色、间距 magic number 等） |

> ⚠️ **重要澄清**：本次审计对子代理的初步结论做了逐项代码复核，纠正了 4 处误报（详见 §6"已排除的误报"）。本报告仅收录经代码实证的问题。

---

## 1. 未重构的功能模块

### 1.1 P1 — 书源校验（CheckSource）功能链路缺失

| 项 | 内容 |
|---|---|
| Android 原版 | [CheckSourceService](../app/src/main/java/io/legado/app/service/CheckSourceService.kt)（前台服务批量校验书源可用性）+ 书源管理页"校验"菜单入口 |
| 当前状态 | Rust 侧已有 source_checker 实现（约 962 行），但 **FFI 未暴露**，`API_CONTRACT.md` 无 `checkSource*` 契约，Flutter 书源管理页无校验入口；`source_edit_screen` 的"校验关键字"仅为表单字段 |
| 影响 | 用户无法批量检测失效书源——这是原版书源管理的核心高频功能 |
| 修复建议 | ① Rust 轨：登记 `checkSourceStart/checkSourceProgress(Stream)/checkSourceStop` 契约并暴露 FFI；② UI 轨：书源管理页补"校验所选/校验全部"菜单 + 进度条 |

### 1.2 P1 — 应用日志页面未接入（appLog* 契约已交付但 UI 不可达）

| 项 | 内容 |
|---|---|
| Android 原版 | `AppLogDialog`（关于页入口，查看 message/crash/http 三级日志） |
| 当前状态 | 契约 §2.38 五个方法已登记"✅ 已完成"，Rust `log_api.rs` 已实现，`frb_generated.dart` 绑定已生成；**但 [book_api.dart](../flutter_legado/lib/src/services/book_api.dart) 抽象接口缺失 appLog\* 五个方法**（已 grep 验证零匹配），UI 层依架构铁律无法触达，日志页面也未创建 |
| 影响 | 契约"已完成"状态失实；日志功能整链路对用户不可用 |
| 修复建议 | BookApi 补 5 个抽象方法 → RustApi/MockBookApi 双实现 → 新建 app_log_screen（约半天工作量） |

### 1.3 P2 — HTTP TTS 引擎列表硬编码

Android 原版朗读引擎选择读取 HttpTTS 数据库配置；当前 Rust `list_engines` 返回硬编码"示例引擎"，应改从 `http_tts_repository` 读取真实配置（契约 §2.25 的 CRUD 已具备，仅引擎枚举一处未接通）。

### 1.4 P2 — MOBI HUFF/CDIC 压缩与 KF8 章节结构未移植

Android 原版支持 MOBI 全格式；Rust 解析器目前缺 HUFF/CDIC 解压与 KF8 结构解析，受影响面为部分 .mobi/.azw3 本地书导入。属低频路径，可延后。

### 1.5 平台差异豁免项（不计缺口）

- **AppWidget 桌面小部件**（`app/.../widget/`）：Android 平台特有，跨平台版本不要求。
- **WebTileService 快捷设置磁贴**、**SharedReceiverActivity 系统分享接收**：同上，属 Android 系统集成点，Windows 端以其他形态覆盖或豁免。

---

## 2. 未重构的 UI 界面

39 个 Flutter 页面对照 Android 54 个 Activity 的盘点结论（完整映射见审计底稿）：

### 2.1 确认缺失（P1-P2）

| Android 界面 | 路径 | 缺失说明 | 优先级 |
|---|---|---|---|
| 验证码输入 | `ui/association/VerificationCodeActivity` | 书源反爬验证码人工识别入口。缺失时相关书源在真实网络下**功能性不可用** | **P1** |
| 规则订阅管理 | `ui/rss/subscription/RuleSubActivity` | 订阅书源/RSS/替换规则的聚合更新管理页 | P2 |
| 跳转确认 | `ui/association/OpenUrlConfirmActivity` | 外链打开前确认弹窗（可降级为通用 Dialog 实现，工作量小） | P2 |
| 底栏皮肤 | `ui/config/BottomBarSkinActivity` | 新标准下视觉风格自由，**建议豁免**（记录决策即可） | P3 |

### 2.2 部分实现待补齐（P2）

| 界面 | 差距 |
|---|---|
| 书源调试 / RSS 源调试 | 页面框架已建，四链路（搜索/详情/目录/正文）调试结果展示与原版日志粒度有差距 |
| 远程书籍导入（RemoteBook） | URL 下载 + 编码检测流程不完整 |
| 文件关联 / HandleFile | 桌面端文件关联打开（TXT/EPUB/MOBI 等）仅部分覆盖 |
| 代码编辑器（CodeEditActivity） | 并入 source_edit_screen，缺语法高亮与行号 |

### 2.3 Flutter 多余页面（纯迁移原则核查）

- `rss_history_screen`（RSS 已读历史页）：Android 原版无独立页面。但其后端 `rssListReadRecords` 已在契约 §2.35 登记，属既成小幅超集，**建议保留并在契约中标注"Flutter 扩展"**，不算违规膨胀。
- 推荐算法/阅读统计页已按纯迁移原则删除（记忆确认），无残留。

---

## 3. 设计缺陷（依据 design_system.md 现行规范）

### 3.1 P0 — AppBar 内 TabBar 同色不可见风险

[bookshelf_screen.dart](../flutter_legado/lib/src/screens/bookshelf_screen.dart) L112-126：分组 Tab 位于 AppBar 内，未显式设置 `labelColor`，继承全局 `tabBarTheme`（labelColor = primary）。**AppBar 背景同为 primary → 选中标签同色不可见**。这正是记忆库中已登记的既往缺陷模式（"AppBar 内 TabBar 与 TextButton 必须用白色系前景"），属规范明令禁止项。
**修复**：TabBar 显式 `labelColor: Colors.white`、`unselectedLabelColor: Colors.white70`（或 onPrimary 系）。

### 3.2 P1 — 语义色未做亮暗适配（WCAG AA 风险）

- [source_debug_screen.dart](../flutter_legado/lib/src/screens/source_debug_screen.dart) L444-456 `chipColor`：直接返回 `Colors.green/orange/red`，未按 brightness 区分（同文件 L413-428 的 `color()` 方法已正确适配，两者不一致）。
- [rss_source_debug_screen.dart](../flutter_legado/lib/src/screens/rss_source_debug_screen.dart) L329-340：同样问题。
- [source_edit_screen.dart](../flutter_legado/lib/src/screens/source_edit_screen.dart) L639/L644/L661：校验结果面板 `Colors.green` 三处未适配。
**修复**：统一为 `brightness == dark ? shade300 : shade800` 模式（前景）/ shade 容器色（背景）。

### 3.3 P2 — 硬编码颜色违规（8 处，豁免场景外）

| 位置 | 问题 | 修复 |
|---|---|---|
| book_info_screen.dart L87 | AppBar `foregroundColor: Colors.white` 硬编码 | 改 `colorScheme.onPrimary` |
| book_info_screen.dart L228 | 信息页遮罩 `Colors.black` 半透明 | 改 Theme Token 或登记豁免 |
| settings_screen.dart L248 | `iconColor: AppColors.black`（暗色下不可见） | 改 `onSurfaceVariant` |
| source_debug_screen.dart L276 | FilterChip 选中前景 `Colors.white` | 改 `onPrimary` |
| book_grid_item.dart L61 | 阴影 `Colors.black` | 改 `colorScheme.shadow` |
| ios_widgets.dart L208 | 图标兜底 `Colors.white` | 改 `onPrimary` |

阅读器/漫画阅读器/滑动按钮等 12 处硬编码属 §7.4 豁免场景，合规。

### 3.4 P2 — design_system.md 与代码 Token 漂移（文档治理）

`app_colors.dart` 实际采用 iOS 色系（primary `#007AFF` 等），而 design_system.md 记录的是 M3 旧值（`#039BE5` 等）。新标准下 iOS 色系合法，但**违反"单一事实源"**——需将 design_system.md 的 Token 表更新为当前实现值（文档已有"修改 Token 需同步更新本档"的定位说明，按此执行即可）。

### 3.5 P3 — 间距 magic number

`book_info_screen`（18/6）、`book_grid_item`（5/6）等少量非 Token 间距，建议归一到 4/8/16 体系或登记为内部微调 Token。无障碍抽查（IconButton tooltip、破坏性操作二次确认）总体良好。

---

## 4. 逻辑 bug 与健壮性问题

### 4.1 P1 — catch 静默吞噬异常（用户无感知失败）

经复核区分后，真正"完全静默"的风险点：

| 位置 | 问题 |
|---|---|
| [book_info_screen.dart](../flutter_legado/lib/src/screens/book_info_screen.dart) L107/L122/L146/L673 | `catch (_)` 完全吞掉，加载/操作失败无任何提示 |
| highlight_rules_screen.dart L319/L345 | `catch (_)` 吞掉规则保存/解析失败 |
| widgets/reader/reader_bottom_bar.dart L55 | `catch (_)` 吞掉 |
| search_notifier.dart L61-63 | 历史持久化失败静默（有注释说明"不阻断 UI"，属有意设计，**可接受但建议 debugPrint 留痕**） |

> 注：source_screen.dart 的 7 处 catch 复核后均有 SnackBar 用户提示，**不属于**吞异常（子代理误报，已排除）。

**修复**：统一错误出口——吞掉的 catch 至少补 SnackBar 或 AppLog 上报（appLog FFI 接通后正好承接）。

### 4.2 P1 — jsonDecode 强制类型转换无守卫

[rust_api.dart](../flutter_legado/lib/src/services/rust_api.dart) L110/L119/L134 等大量 `jsonDecode(json) as List/Map` 直接强转。契约 §1.4 已有 3 次"Map 包装 vs 裸数组"崩溃事故（Task #29/#42），当前模式下**任何一次 Rust 返回结构漂移都会直接抛 TypeError 崩溃**而非优雅降级。
**修复建议**：在 rust_api.dart 增加统一的 `_decodeList/_decodeMap` 守卫函数（类型不符时抛带上下文的 BridgeError，附方法名与原始 JSON 前缀），一处修改全局受益，也与记忆中"路由参数 is Map 运行时判断"的规范同构。

### 4.3 P2 — 高亮规则页 UI 层解析 JSON

highlight_rules_screen.dart L43/L316 在 **UI 层**直接 `jsonDecode` 高亮规则 JSON 并强转。虽未触碰 bridge（不违反铁律字面），但业务数据解析应下沉至 Notifier/模型层，UI 层仅消费类型化状态。

### 4.4 P2 — quickjs 构建口径需固化

已验证：`flutter_legado/scripts/build-windows.ps1`、`run-windows.ps1`、`rust/scripts/build-android.ps1` 均带 `--features quickjs`（生产链路无问题）；但 `flutter_legado/Makefile` 存在"开发态快速构建（不启用 quickjs，走 stub）"目标。**开发态下 loginUi V2 / jsSourceExtract 会返回 JsEngine 错误**，与 Mock 模式行为差异易被误判为 bug。
**建议**：在 dev 构建的错误信息或启动日志中明示"当前 DLL 为非 quickjs stub 构建"，避免排障绕路。

### 4.5 P3 — 陈旧注释误导

- dict_screen.dart L12 注释仍写"本地内置词典为静态占位数据（真实词典查询待 Rust 契约）"，而 dict_notifier.dart L89 实际已切换 `bookApiProvider.dictLookup` 真实 FFI。
- search_state.dart L32 注释仍写"持久化于 SharedPreferences"，实际 search_notifier.dart L39/L60 已走 `BookApi.getSearchHistory/addSearchKeyword`。
**修复**：清理注释（连带重跑 freezed 生成物），避免下一轮审计再次误报。

---

## 5. FFI 契约对接情况

| 检查项 | 结论 |
|---|---|
| 契约 190 方法 vs frb_generated | ✅ 全部存在（appLog*/highlight*/jsSource*/reviewGetReplies/searchCover/dictLookup/loginV2 逐一核对） |
| Rust api/ 桩实现 | ✅ 零 `todo!()`/`unimplemented!()`；错误处理统一 Result/BridgeError；unwrap 集中在测试代码 |
| §1.4 Map 包装兼容点 | ✅ getChapters/refreshToc/searchSource 三处 Dart 侧均已提取字段；reviewGetReplies 已登记对象包装 |
| **BookApi 接口完整性** | ❌ **appLog\* 五方法缺失**（见 §1.2，契约 §1.2 变更规则第③步未执行） |
| Dart 侧本地实现替代 FFI | ⚠️ scanLocalBooks/parseTxt/parseEpub/audioSpeak 为 Dart 侧实现（历史决策，行为对齐即可，建议在契约中标注"Dart 实现"以免误判） |
| Mock/真实模式行为差 | ⚠️ 仅 quickjs 相关方法在 stub 构建下有差（§4.4），生产构建无差 |

---

## 6. 已排除的误报（复核记录）

以下子代理初步结论经代码实证**不成立**，明确排除以免误导后续修复：

1. ❌ "4 个 screen 直调 bridge" — 全库 grep `import.*(bridge/|frb_generated|rust_api)` 于 screens/widgets **零匹配**，change_source_screen 等越界已在 Phase 6 治理完成。
2. ❌ "searchCover/dictLookup 仍走 Mock 假数据" — change_cover_notifier.dart L31、dict_notifier.dart L89 均已真实调用 `bookApiProvider.searchCover/dictLookup`（仅注释陈旧，见 §4.5）。
3. ❌ "Windows 生产构建未启用 quickjs 导致登录 V2 全线不可用" — 三个标准构建脚本均带 `--features quickjs`，仅 dev 快速构建例外（降级为 §4.4 的口径固化建议）。
4. ❌ "source_screen 7 处 catch 吞异常" — 均有 SnackBar 提示，不属于静默吞噬。

---

## 7. 修复路线图（按优先级）

### 第一批（P0，1-2 天）
1. **BookApi 补 appLog\* 五方法** + RustApi/MockBookApi 双实现（§1.2）——解锁日志页面开发
2. **bookshelf_screen TabBar 白色系前景**（§3.1）——一处改动消除不可见风险

### 第二批（P1，1 周）
3. 书源校验契约登记 + FFI 暴露 + UI 入口（§1.1，跨轨，需 Rust 轨先行）
4. 验证码输入页（§2.1）——书源真实可用性依赖
5. catch 静默点补用户提示/日志上报（§4.1）
6. rust_api.dart 统一 jsonDecode 守卫（§4.2）
7. 语义色亮暗适配三处（§3.2）
8. app_log_screen 日志页面（依赖第 1 项）

### 第三批（P2，2 周）
9. 硬编码颜色 6 处清理（§3.3）+ design_system.md Token 表同步（§3.4）
10. 规则订阅页、跳转确认弹窗、调试页展示补齐（§2.1/§2.2）
11. HTTP TTS 引擎列表接真实配置（§1.3）
12. 高亮规则解析下沉 Notifier（§4.3）+ 陈旧注释清理（§4.5）
13. quickjs dev 构建提示（§4.4）

### 延后/豁免（P3）
14. MOBI HUFF/CDIC + KF8（§1.4）
15. 底栏皮肤页豁免决策记录（§2.1）
16. 间距 Token 归一（§3.5）

---

## 8. 与 Android 原版对比总评

- **功能对等性**：核心链路（书架/搜索/阅读/书源/RSS/替换/备份/听书/漫画/自动任务/高亮/段评）已全线打通并接通真实 FFI，对等度约 **92%**。剩余缺口集中在书源校验、验证码、规则订阅三个原版功能点，以及若干调试/关联类页面的深度。
- **架构质量**：Flutter 侧铁律（UI 禁触 bridge、业务数据走 BookApi+Notifier）经全库验证已实质达成，优于文档记载的历史状态；Rust 侧无桩实现、错误处理统一。
- **主要风险面**：① 接口/契约/实现三方的"最后一公里"脱节（appLog 模式——契约标完成但 UI 不可达，建议契约状态增加"UI 可达"验收位）；② JSON 边界的类型脆弱性（已有 3 次崩溃前科，守卫函数是性价比最高的加固）；③ 文档/注释与代码漂移（本次 4 处误报全部源于此，治理注释即是治理审计成本）。
