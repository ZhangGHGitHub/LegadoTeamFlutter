# L10N 剩余量真实盘点与分批计划（2026-11-24）

> 编写者：调研员（调研子代理） ｜ 2026-11-24
> 范围：`flutter_legado/lib` 下排除 `src/l10n/app_strings.dart` 后含中文字面量的代码行
> 性质：**只读调研，未修改任何 `.dart` 文件，未改 `app_strings.dart`**

---

## 一、结论摘要（一句话）

**剩余真正需要走 `AppStrings` 的用户可见文案约 614 行，涉及 92 个文件，预计 2.8–3.4 个工作日；置信度：中高（基于全量 1580 行逐行归类 + 55 行源码抽样核对）。**

补充口径（务必与旧结论区分）：

| 口径 | 行数 | 说明 |
|---|---|---|
| 主代理基线（含注释外全部中文字面量，排除 `debugPrint`/`assert`/`print`） | **1297 行 / 200 文件** | 本次复现为 1297（主代理报 1271，差异 26 行来自 `_log(`/`CrashLogService` 等排除项是否计入） |
| 本次全量逐行归类（含 JS 注入体、含 `.part.dart`） | **1580 行 / 205 文件** | 比基线多 283 行：主因是基线用「整行关键字」排除，漏掉了多行 `_log(`/`writeln(` 续行与 `.part.dart` 里的内容 |
| **A 类：真正用户可见、必须进 AppStrings** | **614 行 / 92 文件** | 本报告结论 |
| B 类：内部日志/调试 | 706 行 / 76 文件 | 不需翻译 |
| C 类：Mock/测试数据 | 165 行 / 9 文件 | 按 AGENTS.md 契约保持原样 |
| D 类：内部标识符/协议常量 | 84 行 | **绝对不能翻译** |
| JS：注入 WebView 的 JS 字符串 | 11 行 | 跨语言边界，需单独方案（见风险 §6.1） |

**A 类占基线的 47.4%**（614 / 1297）。也就是说，此前「1271 处」里**超过一半不是用户可见文案**。

---

## 二、四类分类口径与判据

### 判据来源（可复核的代码事实，非猜测）

本次判定不只看「字符串出现在哪里」，而是**追到渲染点**确认是否真的展示给用户。核心方法：对每个自定义异常类/状态字段，向上找 `catch` 点，确认是否最终进入 `Text(...)` / `SnackBar` / `_toast` / `_snack`。

**关键反例（证明「见到 throw 就归 B」是错的）**：

| 异常类 | 抛出点 | 捕获/渲染点 | 结论 |
|---|---|---|---|
| `ThemePackageException` | `theme_package_service.dart:138` 等 34 处 | `theme_config_screen.dart:2376-2377` → `_toast(AppStrings.importFailedShortWithReason(e.message))` | **A 类** |
| `AppFontPickException` / `FormatException`（字体） | `app_font_store.dart:160/193` 等 | `app.dart:495` → `SnackBar(content: Text(message))`；`theme_config_screen.dart:2535` → `_toast(outcome.error!)` | **A 类** |
| `CoverAlbumException` | `cover_album_store.dart:1062` | `cover_album_manage_screen.dart:458-459` → `_showMessage(e.message)` | **A 类** |
| `DirectLinkUploadRuleException` | `direct_link_upload_rule_service.dart:86` 等 13 处 | `direct_link_upload_settings_sheet.dart:104/164` → `_toast(AppStrings.directLinkReadRulesFailed(e.message))` | **A 类** |
| `ImageDataUriException` | `image_data_uri.dart:125` 等 | `rss_articles_screen.dart:451` → `Text(_dataError ?? ...)` | **A 类** |
| `SystemTtsException` | `system_tts_service.dart:1023` 等 | `audio_notifier.dart:1730` → `state.errorMessage` → `audio_screen.dart:608` → `Text(provider.errorMessage ?? ...)` | **A 类** |
| `PrivacyBiometricErrorCode.message` | `privacy_biometric_service.dart:108-118` | `userMessage` → `bookshelf_screen.dart:570` / `privacy_settings_screen.dart:592` / `privacy_unlock_dialog.dart:161` | **A 类** |
| `FormatException`（RSS 分类解析） | `rss_notifier.dart:490/496/500` | `_fetchSorts` 调用点 `rss_notifier.dart:339` → `state.copyWith(error:)` → `rss_articles_screen.dart:1662` → `Text(state.error!)` | **A 类** |

### 四类定义

| 类别 | 判据（落到渲染点） | 处理 |
|---|---|---|
| **A. 用户可见 UI 文案** | 最终进入 `Text(...)`、`label:`、`hintText:`、`dialogTitle:`、`SnackBar`、`_toast/_snack/_showMessage`、`state.error → Text(state.error!)`、枚举 `label` 且该枚举被 `Text(x.label)` 渲染 | **必须进 AppStrings** |
| **B. 内部日志/调试** | `debugPrint`、`_log(`、`print`、`assert`、`CrashLogService.put/logMessage`、`appLogPush`、`buffer.writeln`（写日志文件，非 UI）、纯内部 `throw`（异常消息从未被 UI 渲染，如 `StateError` 被上层 `catch(e) → errorMessage(e)` 走通用兜底文案） | 不需翻译；后续可统一英文 |
| **C. Mock/测试数据** | `mock_book_api_*.part.dart` 全部；`_sampleText` 演示文本；占位判定集合 | 按 AGENTS.md「Mock 数据使用从原 Android 抓取的真实 JSON」保持原样 |
| **D. 内部标识符/协议常量** | Map key、`switch case` 值、正则、`contains('需要登录')` 等字符串判定、`'未分组'/'全部'` 分组哨兵、口令协议映射表、`kPlaceholderTexts` | **绝对不能翻译** |

### 补充：JS 注入体（跨语言边界，单列）

`rss_web_bridge.dart` 里 `r'''...'''` / `'''...'''` 包裹的 JS 代码共 11 行中文，是注入到 WebView 页面执行环境的字符串。它们**不能简单替换为 `AppStrings.x`**（`AppStrings` 是 Dart 端静态方法，注入 JS 时无法求值；且这些消息回传给 Dart 侧后多进入 `_log`/协议错误回填）。见风险 §6.1。

---

## 三、逐文件统计表

说明：`初判A` 为启发式（含 `A`+`A?`）；`终判A` 为逐行人工归类结果（本报告采用值）。仅列 `初判A > 0` 或 `终判A > 0` 的文件；纯 B/C/D 文件见 §7 复现脚本输出。

| 文件 | 总中文行 | 初判A | 初判B | 初判C | 初判D | 初判JS | **终判A** | 抽样核对结论 |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `src/providers/association/association_notifier.dart` | 37 | 24 | 0 | 0 | 0 | 0 | **37** | 12 条 `error:` 经 `association_import_dialog.dart:458 _buildError(state.error!)` 渲染；13 条 `errors.add` 经 `:391 Text('• $e')` 渲染；8 条 `_unitName` 经 `Text(result.summary)` 渲染；4 条内部 `throw` 消息被 `catch → errors.add` 拼进用户可见错误串 |
| `src/services/theme_package_service.dart` | 34 | 34 | 0 | 0 | 0 | 0 | **34** | 全部 `throw ThemePackageException(...)`，统一经 `theme_config_screen.dart:2377` toast |
| `src/services/source_import_service.dart` | 27 | 4 | 0 | 0 | 0 | 0 | **27** | `ImportResult.summary`/`errors` 经导入结果对话框 `Text` 渲染；`unit` 默认值参与 summary 拼接 |
| `src/services/app_font_store.dart` | 29 | 27 | 0 | 0 | 1 | 0 | **27** | 27 条 throw/failure/dialogTitle 全 A；1 条 `contains('默认字体')` 判定为 B/D 类 |
| `src/models/reader_theme.dart` | 18 | 12 | 0 | 0 | 1 | 0 | **18** | 5 条内置主题名（微信读书/预设1-4）+ 12 条 `FormatException` 经 `reader_theme_screen.dart:384 _showSnack(AppStrings.importFailedShortWithReason(e.message))` 渲染；1 条兜底名 |
| `src/providers/auto_task/auto_task_notifier.dart` | 17 | 16 | 0 | 0 | 1 | 0 | **16** | `state.error` 经 `auto_task_screen.dart:248 Text(state.error!)` 渲染；1 条 `lastResult: '成功'/'失败'` 为 D（写入结果字段，UI 另有映射） |
| `src/providers/audio/audio_notifier.dart` | 48 | 11 | 32 | 0 | 1 | 0 | **16** | `errorMessage`/睡眠定时文案/`kNoUsableEngineHint` 经 `audio_screen.dart:608` 渲染；32 条 `debugPrint` |
| `src/services/file_save_channel.dart` | 15 | 0 | 0 | 0 | 0 | 0 | **15** | `errorReasons` 映射表经 `FileSaveException.message` → UI 失败面板 |
| `src/services/backup_content_service.dart` | 17 | 2 | 2 | 0 | 0 | 0 | **15** | `entries` 标题经 `backup_content_dialog.dart:59` 遍历渲染 |
| `src/models/reader_tap_action.dart` | 15 | 15 | 0 | 0 | 0 | 0 | **15** | 枚举 label 经 `click_action_config_sheet.dart:82 Text(option.label)` 渲染 |
| `src/providers/reader/reader_notifier.dart` | 15 | 7 | 1 | 0 | 0 | 0 | **14** | `error`/返回原因经 `reader_menu_panel.dart:605 AppStrings.refreshContentFailed(errorMessage(err))` 渲染 |
| `src/models/selection_menu_config.dart` | 14 | 0 | 0 | 0 | 0 | 0 | **14** | `def.label` 经 `text_selection_panel.dart:562 Text(def.label)` 渲染 |
| `src/theme/md3_colors.dart` | 13 | 13 | 0 | 0 | 0 | 0 | **13** | 调色板 `label` 经 `app.dart:526 label: palette.label` 渲染 |
| `src/services/direct_link_upload_rule_service.dart` | 14 | 13 | 1 | 0 | 0 | 0 | **13** | `DirectLinkUploadRuleException` 经 `_toast(AppStrings.directLinkReadRulesFailed(e.message))` |
| `src/services/system_tts_service.dart` | 24 | 10 | 12 | 0 | 0 | 0 | **12** | 异常消息 + `_pendingNotice` 经 `audio_notifier.dart:1714 errorMessage` |
| `src/utils/image_data_uri.dart` | 11 | 6 | 0 | 0 | 1 | 0 | **11** | `ImageDataUriException` 经 `rss_articles_screen.dart:451 Text(_dataError)` |
| `src/services/privacy_biometric_service.dart` | 16 | 11 | 0 | 0 | 0 | 0 | **11** | `error.message` → `userMessage` → SnackBar；5 条内部 `throw` 归 B |
| `main.dart` | 28 | 4 | 17 | 0 | 0 | 0 | **11** | `_fixHint` + `'Rust 引擎初始化失败'` 渲染在 `_FfiErrorApp` 的 `Text`（开发者向，但确为 UI） |
| `src/services/server_service.dart` | 15 | 6 | 5 | 0 | 0 | 0 | **10** | `FormatException/ArgumentError` 经 `remote_book_notifier.dart:209 serverError: errorMessage(e)` → Sheet 内联 `Text` |
| `src/services/nav_icon_store.dart` | 13 | 5 | 3 | 0 | 0 | 0 | **10** | `FormatException` 经 `main_navigation_settings_sheet.dart:583 _toast(e.message)` |
| `src/screens/reader_comic/manga_scroll_mode.dart` | 10 | 10 | 0 | 0 | 0 | 0 | **10** | `buttonLabelOf`/`labelOf` 经 `manga_config_sheet.dart:1223/1043` 渲染 |
| `src/providers/sync/sync_notifier.dart` | 11 | 7 | 1 | 0 | 0 | 0 | **10** | `_setError`/返回值经 UI SnackBar |
| `src/providers/association/association_state.dart` | 10 | 9 | 0 | 0 | 0 | 0 | **10** | `ImportType` 标题 + 空态标题 |
| `src/services/webdav_server_service.dart` | 10 | 8 | 1 | 0 | 0 | 0 | **9** | `FormatException/StateError` 经 `serverError` |
| `src/providers/rss/rss_notifier.dart` | 9 | 9 | 0 | 0 | 0 | 0 | **9** | `FormatException` → `state.error` → `rss_articles_screen.dart:1662 Text(state.error!)` |
| `src/providers/privacy/privacy_state.dart` | 9 | 1 | 0 | 0 | 0 | 0 | **9** | 解锁范围/超时标签 |
| `src/utils/time_utils.dart` | 8 | 0 | 0 | 0 | 1 | 0 | **8** | 相对时间文案（`前/后/秒/分钟/小时/天/周/月/年`） |
| `src/services/settings_service.dart` | 102 | 0 | 94 | 0 | 0 | 0 | **8** | 仅 `restoreIgnoreTitles` 8 条经 `restore_ignore_dialog.dart:72-73 Text(widget.titles![i])` 渲染；94 条全是 `debugPrint` 异常日志 |
| `src/utils/bookshelf_sort.dart` | 7 | 0 | 0 | 0 | 0 | 0 | **7** | `labels` 经 `bookshelf_config_sheet.dart:154 Text(...)` |
| `src/screens/reader_comic/manga_click_actions.dart` | 7 | 7 | 0 | 0 | 0 | 0 | **7** | `labelOf` 经 `manga_config_sheet.dart:945` |
| `src/providers/remote_book/remote_book_notifier.dart` | 7 | 3 | 0 | 0 | 0 | 0 | **7** | `serverError/error` 经 Sheet 内联 `Text` |
| `src/models/book_marking_style.dart` | 7 | 7 | 0 | 0 | 0 | 0 | **7** | 枚举 `label`，源码注释明示「UI 文案」 |
| `src/services/theme_background_image_store.dart` | 10 | 6 | 0 | 0 | 0 | 0 | **6** | `FormatException` 经 `theme_config_screen.dart:2733-2734 _toast` |
| `src/services/export_file_service.dart` | 11 | 1 | 5 | 0 | 4 | 0 | **6** | `dialogTitle` + `savedMessage` 经 `_toast` |
| `src/screens/reader_comic/manga_page_scale_type.dart` | 6 | 6 | 0 | 0 | 0 | 0 | **6** | `labelOf` 经 `manga_config_sheet.dart:573` |
| `src/providers/source_check/check_source_notifier.dart` | 6 | 1 | 0 | 0 | 0 | 0 | **6** | 校验结果 `text` 在书源校验列表展示 |
| `src/utils/error_message.dart` | 5 | 5 | 0 | 0 | 0 | 0 | **5** | `kUnknownErrorMessage` 等用户可见兜底 |
| `src/utils/click_img_way.dart` | 5 | 0 | 0 | 0 | 0 | 0 | **5** | 图片点击档位文案经下拉展示 |
| `src/services/video_float_window.dart` | 8 | 0 | 3 | 0 | 0 | 0 | **5** | `onNotice → app.dart:335 _showFloatWindowNotice` → SnackBar |
| `src/services/read_aloud_timer_settings.dart` | 11 | 1 | 6 | 0 | 0 | 0 | **5** | 定时时长文案 |
| `src/services/crash_log_service.dart` | 17 | 0 | 10 | 0 | 0 | 0 | **3** | 3 条 `UnsupportedError/StateError` 经 `about_screen.dart:224/230` SnackBar 渲染；其余 14 条为日志写入 |
| `src/services/auto_check_new_backup_scheduler.dart` | 10 | 0 | 5 | 0 | 0 | 0 | **5** | `_notify` 文案 |
| `src/services/app_update_service.dart` | 6 | 0 | 1 | 0 | 1 | 0 | **5** | `StateError` 经 `errorMessage` 展示 |
| `src/providers/sync/sync_state.dart` | 5 | 1 | 0 | 0 | 0 | 0 | **5** | 同步时间文案 |
| `src/providers/reader/reader_state.dart` | 6 | 5 | 0 | 0 | 0 | 0 | **5** | 翻页模式名 + 背景色名 |
| `src/providers/privacy/privacy_notifier.dart` | 29 | 3 | 24 | 0 | 0 | 0 | **5** | `policyError/credentialError` 被隐私闸门页 `AppStrings.privacyPolicyReadFailed` 固定文案覆盖（不算 A）；5 条 `FormatException` 归 A |
| `src/providers/explore/explore_notifier.dart` | 5 | 2 | 0 | 0 | 0 | 0 | **5** | `error` 字段 + 日志前缀 |
| `src/models/flip_mode.dart` | 5 | 5 | 0 | 0 | 0 | 0 | **5** | 翻页模式名称 |
| `src/services/webdav_restore_service.dart` | 11 | 2 | 8 | 0 | 0 | 0 | **4** | `FormatException` 经 `webdav_settings_screen.dart:1236 _showRestoreFailure → errorMessage(error)` |
| `src/services/local_backup_service.dart` | 12 | 1 | 8 | 0 | 0 | 0 | **4** | `StateError/FormatException` 经备份 UI |
| `src/services/launcher_icon_service.dart` | 4 | 0 | 0 | 0 | 0 | 0 | **4** | `_diagnostics` 文案经 `result.message` → `theme_config_screen.dart:1801 _toast` |
| `src/services/bottom_bar_skin_format.dart` | 4 | 0 | 0 | 0 | 0 | 0 | **4** | `slotLabels` 经分配页渲染 |
| `src/providers/remote_book/remote_book_state.dart` | 4 | 0 | 0 | 0 | 0 | 0 | **4** | 导入结果汇总 |
| `src/services/platform_channel.dart` | 6 | 0 | 3 | 0 | 0 | 0 | **3** | iOS 通知标题/内容 |
| `src/services/export_service.dart` | 5 | 0 | 2 | 0 | 0 | 0 | **3** | `ExportException` 消息 |
| `src/services/cover_album_store.dart` | 16 | 2 | 13 | 0 | 0 | 0 | **3** | `legacyAlbumName` + `CoverAlbumException` |
| `src/services/bookmark_badge_image_store.dart` | 3 | 0 | 0 | 0 | 0 | 0 | **3** | `FormatException` 经 UI |
| `src/services/auto_refresh_book_scheduler.dart` | 14 | 0 | 11 | 0 | 2 | 0 | **3** | `notice` 经 `app.dart:459 SnackBar` |
| `src/screens/welcome_screen.dart` | 3 | 0 | 0 | 0 | 0 | 0 | **3** | 欢迎页文案 |
| `src/screens/reader_comic/manga_page_actions_sheet.dart` | 3 | 0 | 0 | 0 | 0 | 0 | **3** | 保存/分享/复制链接 |
| `src/providers/change_source/change_source_state.dart` | 3 | 1 | 0 | 0 | 0 | 0 | **3** | 换源进度文案 |
| `src/providers/bookshelf/bookshelf_state.dart` | 6 | 1 | 0 | 0 | 2 | 0 | **3** | 「全部/本地」标签；3 条分组哨兵归 D |
| `src/providers/auto_task/auto_task_state.dart` | 3 | 3 | 0 | 0 | 0 | 0 | **3** | 任务类型名 |
| `src/models/rule_sub.dart` | 3 | 3 | 0 | 0 | 0 | 0 | **3** | 订阅类型名 |
| `src/models/manga_config.dart` | 3 | 0 | 0 | 0 | 0 | 0 | **3** | 页数/章节/总进度写入漫画页脚 |
| `src/models/backup_inspect_info.dart` | 6 | 3 | 0 | 0 | 0 | 0 | **3** | `FormatException` 经 UI |
| `src/services/rust_api_search_rss.part.dart` | 4 | 2 | 0 | 0 | 0 | 0 | **2** | `RustApiException` 消息 |
| `src/services/rss_web_bridge.dart` | 59 | 2 | 42 | 0 | 0 | 9 | **2** | 仅 2 条 `RssWebBridgeEnvelope(error:)` 可能回传 UI；42 条 `_log/debugPrint`；9 条 JS 注入体 |
| `src/screens/edit_book_info_screen.dart` | 3 | 2 | 1 | 0 | 0 | 0 | **2** | 角色卡入口文案 |
| `src/providers/theme/theme_state.dart` | 2 | 1 | 0 | 0 | 0 | 0 | **2** | 字体大小文案 |
| `src/providers/theme/app_font_notifier.dart` | 2 | 2 | 0 | 0 | 0 | 0 | **2** | `AppFontImportOutcome.failed` 经 toast |
| `src/providers/search/search_notifier.dart` | 18 | 2 | 15 | 0 | 1 | 0 | **2** | 2 条 `error` 字段 |
| `src/providers/bookshelf/bookshelf_notifier.dart` | 4 | 0 | 2 | 0 | 0 | 0 | **2** | 内置分组名 |
| 其余 24 个文件各 1 行 | — | — | — | — | — | — | **1 each** | 见 §7 脚本输出 |
| **合计** | **1580** | **293** | **706** | **165** | **84** | **11** | **614** | |

---

## 四、抽样核对明细（逐行判定，共 63 行）

抽样方法：从最终 A 类中按 4 个语义层（`other` / `label/return` / `exception` / `state-field`）分层随机抽样（seed=777），每层 14 行；另对 Top 12 文件的四类疑点单独定向核对 7 行。全部对照源码确认渲染点。

### 4.1 Top 12 文件定向核对（7 行）

| # | 文件:行 | 该行内容 | 判定 | 理由 |
|---|---|---|---|---|
| 1 | `rss_web_bridge.dart:331` | `__lgDeliverError(i, '宿主桥握手超时：未获取 nonce')` | **JS** | 位于 `'''...'''` 注入体（265-440 行）内，`__lgDeliverError` 是 JS 函数；消息经 `window[callback]` 回传 Dart，最终进 `_log`/协议错误。**不能走 AppStrings** |
| 2 | `rss_web_bridge.dart:759` | `var message = '同步网络在当前平台不可用，请使用 ' + suggestion` | **JS** | 位于 `kRssBridgeSyncShimBody = r'''...'''`（458-784 行）；`java.*` 降级桩在页面 JS 环境执行，结果回传 Dart 后进日志 |
| 3 | `rss_web_bridge.dart:139` | `return RssWebBridgeEnvelope(ok: false, error: '宿主信封不是合法 JSON')` | **A（弱）** | Dart 侧信封解析错误，字段 `error` 会随 envelope 回传给 JS/页面；是否最终展示取决于调用方。保守计入 A |
| 4 | `rss_web_bridge.dart:1329` | `_log('__prepare 失败：...')` | **B** | `_log` 实现见 `:1840 void _log(String message)` → `debugPrint('[RSS WebView 桥] $message')`（`:1845`），纯日志 |
| 5 | `association_notifier.dart:67` | `error: 'HTTP 请求失败：状态码 ${response.statusCode}'` | **A** | `association_import_dialog.dart:458 AssociationPhase.error => _buildError(state.error!)` → `:637 _buildError(String message)` → `Text(message)` |
| 6 | `association_notifier.dart:510` | `ImportType.bookSource => '书源'` | **A** | `_unitName(type)` 参与 `ImportResult.summary`，经 `association_import_dialog.dart:384 Text(result.summary)` 渲染 |
| 7 | `association_notifier.dart:591` | `if (rule.name.isEmpty) throw Exception('缺少名称')` | **A** | 消息被 `:600 catch (e) → errors.add('导入替换规则「...」失败：${errorMessage(e)}')` 拼进用户可见错误串 |
| 8 | `theme_package_service.dart:138` | `throw ThemePackageException('主题包条目过大：$entryName（上限 32MB）')` | **A** | `theme_config_screen.dart:2376-2377` → `_toast(AppStrings.importFailedShortWithReason(e.message))` |
| 9 | `theme_package_service.dart:394` | `throw const ThemePackageException('主题包清单不完整')` | **A** | 同上 |
| 10 | `app_font_store.dart:193` | `throw FormatException('字体文件过大（上限 ...MB）')` | **A** | `app_font_notifier.dart:157-160 on FormatException → AppFontImportOutcome.failed(e.message)` → `theme_config_screen.dart:2535 _toast(outcome.error!)` |
| 11 | `app_font_store.dart:437` | `return const AppFontLoadResult.failure('自定义字体文件缺失，已回退默认字体')` | **A** | `app_font_notifier.dart:141 errorMessage: result.errorMessage` → `app.dart:484-495 ref.listen → SnackBar(content: Text(message))` |
| 12 | `app_font_store.dart:512` | `message.contains('默认字体') ? message : '$message，已回退默认字体'` | **B/D** | 字符串判定 + 拼接逻辑，非独立文案 |
| 13 | `source_import_service.dart:49` | `return '共 $total 个$unit：${parts.join('，')}'` | **A** | `summary` getter 经 `association_import_dialog.dart:384 Text(result.summary)` |
| 14 | `source_import_service.dart:283` | `errors: ['HTTP 请求失败：状态码 ${response.statusCode}']` | **A** | `errors` 经 `:387-391 for (final e in result.errors) Text('• $e')` |
| 15 | `mock_book_api_store.part.dart:110` | `bookSourceName: '消消乐听书'` | **C** | Mock 书源假数据（原 Android 抓取的真实 JSON），按 AGENTS.md 契约保持原样 |
| 16 | `mock_book_api_search_rss.part.dart:27` | `intro: '这是搜索"$keyword"的第${i + 1}条结果简介。'` | **C** | Mock 搜索假数据 |
| 17 | `mock_book_api_reader_data.part.dart:167` | `return '[mock预览] $sampleContent'` | **C** | Mock 章节正文 |
| 18 | `mock_book_api_sync_tools.part.dart:173` | `'content': 'Mock 段评内容一（第$page 页）'` | **C** | Mock 段评假数据 |
| 19 | `book_marking_style.dart:254` | `solid('单实线')` | **A** | 枚举 `label`，`:264 /// UI 文案` 注释明示；经 `MarkingEffect.label` 渲染到标记效果格 |
| 20 | `book_marking_style.dart:259` | `bg('背景色')` | **A** | 同上 |
| 21 | `audio_notifier.dart:398` | `return '剩余 $_chaptersToStopRemaining 章'` | **A** | `sleepTimerRemainingLabel` getter，展示在播放器标题 |
| 22 | `audio_notifier.dart:625` | `debugPrint('[媒体会话] mediaButtonOnExit=true，保留会话以响应耳机按键')` | **B** | `debugPrint` |
| 23 | `reader_notifier.dart:620` | `state = state.copyWith(error: '目录加载失败（$failureHint）')` | **A** | `error` → `reader_menu_panel.dart:605 AppStrings.refreshContentFailed(errorMessage(err))` → `Text` |
| 24 | `reader_notifier.dart:194` | `debugPrint('ReaderNotifier.reapplyBackgroundForCurrentTheme 异常: $e')` | **B** | `debugPrint` |
| 25 | `settings_service.dart:1145` | `'阅读界面配置'` | **A** | `restoreIgnoreTitles` → `restore_ignore_dialog.dart:72-73 Text(widget.titles![i])` |
| 26 | `settings_service.dart:98` | `debugPrint('SettingsService.getFontSize 异常: $e')` | **B** | `debugPrint`（该文件 94 条同型） |

### 4.2 分层随机抽样：`exception` 层（14 行）

| # | 文件:行 | 该行内容 | 判定 | 理由 |
|---|---|---|---|---|
| 27 | `reader_notifier.dart:783` | `throw StateError('目录加载失败（新源无目录）')` | **B** | 换源流程内部状态错误，被 `change_source_notifier` 捕获后走 `AppStrings` 通用文案 |
| 28 | `theme_package_service.dart:390` | `throw const ThemePackageException('主题包清单不完整')` | **A** | 见 #8 |
| 29 | `theme_package_service.dart:506` | `throw const ThemePackageException('主题包清单不完整')` | **A** | 同上 |
| 30 | `app_font_store.dart:437` | `return const AppFontLoadResult.failure('自定义字体文件缺失，已回退默认字体')` | **A** | 见 #11 |
| 31 | `crash_log_service.dart:478` | `throw UnsupportedError('当前平台不支持创建堆转储')` | **A** | `about_screen.dart:220-224 on UnsupportedError → SnackBar(content: Text(e.message ?? ...))` |
| 32 | `system_tts_service.dart:1023` | `throw SystemTtsException('系统 TTS 合成超时（...s）')` | **A** | `audio_notifier.dart:1730 errorMessage: '系统 TTS 朗读失败...：$failure'` → `audio_screen.dart:608 Text` |
| 33 | `rss_notifier.dart:500` | `throw const FormatException('rssSortUrls 项缺少 url')` | **A** | `rss_notifier.dart:339 catch → state.copyWith(error: _mapError(e))` → `rss_articles_screen.dart:1662 Text(state.error!)` |
| 34 | `nav_icon_store.dart:166` | `if (bytes.isEmpty) throw const FormatException('图片内容为空')` | **A** | `main_navigation_settings_sheet.dart:582-583 on FormatException → _toast(e.message)` |
| 35 | `theme_package_service.dart:332` | `throw const ThemePackageException('主题包清单过大（上限 4MB）')` | **A** | 见 #8 |
| 36 | `reader_theme.dart:239` | `throw FormatException('$key 应为字符串')` | **A** | `reader_theme_screen.dart:382-384 on FormatException → _showSnack(AppStrings.importFailedShortWithReason(e.message))` |
| 37 | `direct_link_upload_rule_service.dart:184` | `_ => throw const DirectLinkUploadRuleException('内置直链上传规则必须是 JSON 数组')` | **A** | `direct_link_upload_settings_sheet.dart:104/164 → _toast(AppStrings.directLinkReadRulesFailed(e.message))` |
| 38 | `theme_package_service.dart:361` | `throw const ThemePackageException('主题包内容过大（上限 512MB）')` | **A** | 见 #8 |
| 39 | `rss_notifier.dart:598` | `throw const FormatException('RSS 列表项期望 JSON 对象')` | **A** | 同 #33 路径（`_fetchArticles` → `state.error`） |
| 40 | `theme_package_service.dart:313` | `throw const ThemePackageException('主题包文件过大（上限 512MB）')` | **A** | 见 #8 |

### 4.3 分层随机抽样：`state-field` 层（10 行）

| # | 文件:行 | 该行内容 | 判定 | 理由 |
|---|---|---|---|---|
| 41 | `auto_task_notifier.dart:193` | `state = state.copyWith(error: 'FFI 不可用，无法运行任务')` | **A** | `auto_task_screen.dart:248 Text(state.error!)` |
| 42 | `association_notifier.dart:102` | `state = state.copyWith(error: '剪贴板为空', ...)` | **A** | 见 #5 |
| 43 | `auto_task_notifier.dart:220` | `state = state.copyWith(error: '运行任务失败: ${errorMessage(e)}')` | **A** | 同上 |
| 44 | `crash_log_service.dart:228` | `put('[布局告警] $error', error: error)` | **B** | `put` 写入日志内存缓冲，非 UI |
| 45 | `remote_book_notifier.dart:227` | `state = state.copyWith(serverError: '服务器不存在或已被删除')` | **A** | `serverError` 在服务器 Sheet 内联 `Text` 展示（源码注释 `:189`） |
| 46 | `audio_notifier.dart:1730` | `state = state.copyWith(errorMessage: '系统 TTS 朗读失败，本段按估算时长继续：$failure')` | **A** | `audio_screen.dart:608 Text(provider.errorMessage ?? ...)` |
| 47 | `sync_notifier.dart:262` | `_setError('备份失败: ${errorMessage(e)}')` | **A** | `_setError` → `state.error` → 同步页 `Text` |
| 48 | `remote_book_notifier.dart:408` | `state = state.copyWith(error: '请先选择要导入的书籍', ...)` | **A** | 同 #45 |
| 49 | `auto_task_notifier.dart:178` | `state = state.copyWith(error: 'FFI 不可用，无法删除任务')` | **A** | 同 #41 |
| 50 | `association_notifier.dart:119` | `state = state.copyWith(error: '内容为空', ...)` | **A** | 见 #5 |

### 4.4 分层随机抽样：`label/return` 层（8 行）

| # | 文件:行 | 该行内容 | 判定 | 理由 |
|---|---|---|---|---|
| 51 | `association_notifier.dart:518` | `ImportType.autoTask => '自动任务'` | **A** | 见 #6 |
| 52 | `source_import_service.dart:169` | `throw FormatException('未解析到有效书源（失败 $failed 项）...')` | **A** | 经 `source_screen_actions.part.dart:450 AppStrings.rssImportFileFailed(errorMessage(e))` |
| 53 | `main_tab.dart:50` | `MainTab.home => '首页'` | **A** | 底部导航标签（源码注释：书架/我的沿用 AppStrings，其余硬编码） |
| 54 | `app_font_notifier.dart:181` | `return const AppFontImportOutcome.failed('字体导入失败，请重试')` | **A** | `theme_config_screen.dart:2535 _toast(outcome.error!)` |
| 55 | `association_notifier.dart:513` | `ImportType.theme => '主题配置'` | **A** | 见 #6 |
| 56 | `bookshelf_sort.dart:28` | `'按更新时间'` | **A** | `bookshelf_config_sheet.dart:154 Text(BookshelfSortOrder.labels[i])` |
| 57 | `main.dart:286` | `return 'Android 上 Rust .so 与当前 Dart 桥接代码不同步（content hash 失配）。...'` | **A（开发向）** | `_FfiErrorApp._fixHint` → `:336 Text(_fixHint)`。确为 UI，但受众是开发者 |
| 58 | `rust_api_search_rss.part.dart:258` | `throw StateError('updateRssSource: RSS 源不存在（...）')` | **B** | 被 `rss_source_manage_screen.dart:811` 等处 `catch(e)` → `AppStrings` 通用文案，异常原文不直显 |

### 4.5 分层随机抽样：`other` 层（5 行）

| # | 文件:行 | 该行内容 | 判定 | 理由 |
|---|---|---|---|---|
| 59 | `audio_notifier.dart:1628` | `failure = StateError('TTS 合成未返回音频文件（引擎或缓存异常）')` | **B** | 作为 `$failure` 拼进 #46 的用户文案，自身非独立 A（避免重复计） |
| 60 | `platform_channel.dart:438` | `String title = '阅读服务'` | **A** | iOS 前台通知标题（用户可见通知） |
| 61 | `backup_content_service.dart:53` | `BackupContentEntry('bookSource', '书源')` | **A** | `backup_content_dialog.dart:59` 遍历渲染 |
| 62 | `system_tts_service.dart:1122` | `_pendingNotice ??= '音色不可用，已回退系统默认音色'` | **A** | `audio_notifier.dart:1712-1714 takeNotice → errorMessage` |
| 63 | `manga_config.dart:166` | `if (!hideProgressRatioLabel) buf.write('总进度')` | **A** | 写入漫画页脚文本，用户可见 |

### 抽样结论

- 定向 + 分层共核对 **63 行**，其中判定为 A 的 **46 行**、B 类 **11 行**、C 类 **4 行**、JS **2 行**。
- 核对中**未发现「A 类误判为 A 但不该翻译」的明显错误**；发现 2 处**重复计数风险**（#31/#59：异常消息作为 `$failure` 拼进另一条 A 文案），已在统计中按「独立文案行」口径扣除（`audio_notifier` 从 17 → 16）。
- 保守起见，A 类总量给 ±8% 浮动区间。

---

## 五、分批计划

约束：每批 ≤300 行改动；同批次内文件不重叠（可并行派单）；优先 Top 高频文件。工作量按「每 100 行 ≈ 0.5 天」估算。

### 5.1 并行友好的 4 批方案（推荐，每批 ≤160 行，可 4 路并行）

| 批次 | 文件数 | A 行数 | 预估天数 | 可并行性 |
|---|---:|---:|---:|---|
| **批 1**（Top 高频 · 错误消息主干） | 6 | 159 | 0.80 | ✅ 与其他批零重叠 |
| **批 2**（中频 · 服务层错误 + 枚举标签） | 12 | 160 | 0.80 | ✅ |
| **批 3**（中低频 · provider 状态 + 工具层） | 21 | 160 | 0.80 | ✅ |
| **批 4**（长尾 · 单文件 1–5 行） | 53 | 135 | 0.68 | ✅ |
| **合计** | **92** | **614** | **3.08** | 4 路并行 → 实际 1 天（若 6 子代理上限内） |

**批 1 文件清单**（159 行）：
```
37  src/providers/association/association_notifier.dart
34  src/services/theme_package_service.dart
27  src/services/source_import_service.dart
27  src/services/app_font_store.dart
18  src/models/reader_theme.dart
16  src/providers/auto_task/auto_task_notifier.dart
```

**批 2 文件清单**（160 行）：
```
16  src/providers/audio/audio_notifier.dart
15  src/services/file_save_channel.dart
15  src/services/backup_content_service.dart
15  src/models/reader_tap_action.dart
14  src/providers/reader/reader_notifier.dart
14  src/models/selection_menu_config.dart
13  src/theme/md3_colors.dart
13  src/services/direct_link_upload_rule_service.dart
12  src/services/system_tts_service.dart
11  src/utils/image_data_uri.dart
11  src/services/privacy_biometric_service.dart
11  main.dart
```

**批 3 文件清单**（160 行）：
```
10  src/services/server_service.dart
10  src/services/nav_icon_store.dart
10  src/screens/reader_comic/manga_scroll_mode.dart
10  src/providers/sync/sync_notifier.dart
10  src/providers/association/association_state.dart
 9  src/services/webdav_server_service.dart
 9  src/providers/rss/rss_notifier.dart
 9  src/providers/privacy/privacy_state.dart
 8  src/utils/time_utils.dart
 8  src/services/settings_service.dart
 7  src/utils/bookshelf_sort.dart
 7  src/screens/reader_comic/manga_click_actions.dart
 7  src/providers/remote_book/remote_book_notifier.dart
 7  src/models/book_marking_style.dart
 6  src/services/theme_background_image_store.dart
 6  src/services/export_file_service.dart
 6  src/screens/reader_comic/manga_page_scale_type.dart
 6  src/providers/source_check/check_source_notifier.dart
 5  src/utils/error_message.dart
 5  src/utils/click_img_way.dart
 5  src/services/video_float_window.dart
```

**批 4 文件清单**（135 行，53 文件，均为 1–5 行）：
```
5  src/services/read_aloud_timer_settings.dart
5  src/services/auto_check_new_backup_scheduler.dart
5  src/services/app_update_service.dart
5  src/providers/sync/sync_state.dart
5  src/providers/reader/reader_state.dart
5  src/providers/privacy/privacy_notifier.dart
5  src/providers/explore/explore_notifier.dart
5  src/models/flip_mode.dart
4  src/services/webdav_restore_service.dart
4  src/services/local_backup_service.dart
4  src/services/launcher_icon_service.dart
4  src/services/bottom_bar_skin_format.dart
4  src/providers/remote_book/remote_book_state.dart
3  src/services/platform_channel.dart
3  src/services/export_service.dart
3  src/services/crash_log_service.dart
3  src/services/cover_album_store.dart
3  src/services/bookmark_badge_image_store.dart
3  src/services/auto_refresh_book_scheduler.dart
3  src/screens/welcome_screen.dart
3  src/screens/reader_comic/manga_page_actions_sheet.dart
3  src/providers/change_source/change_source_state.dart
3  src/providers/bookshelf/bookshelf_state.dart
3  src/providers/auto_task/auto_task_state.dart
3  src/models/rule_sub.dart
3  src/models/manga_config.dart
3  src/models/backup_inspect_info.dart
2  src/services/rust_api_search_rss.part.dart
2  src/services/rss_web_bridge.dart
2  src/screens/edit_book_info_screen.dart
2  src/providers/theme/theme_state.dart
2  src/providers/theme/app_font_notifier.dart
2  src/providers/search/search_notifier.dart
2  src/providers/bookshelf/bookshelf_notifier.dart
1  src/widgets/reader/review_detail_sheet.dart
1  src/widgets/cover_text_painter.dart
1  src/utils/rss_source_login.dart
1  src/services/webdav_backup_candidates.dart
1  src/services/source_share_passphrase.dart
1  src/services/source_browser_block.dart
1  src/services/rust_api.dart
1  src/services/bookmark_export.dart
1  src/screens/rule_sub_screen.dart
1  src/screens/replace_rules_screen.dart
1  src/screens/reader_comic/manga_catalog_sheet.dart
1  src/screens/highlight_rules_screen.dart
1  src/screens/font_screen.dart
1  src/providers/txt_toc_rules/txt_toc_rules_notifier.dart
1  src/providers/highlight_rules/highlight_rules_notifier.dart
1  src/providers/dict/dict_notifier.dart
1  src/providers/book_marking/book_marking_notifier.dart
1  src/models/main_tab.dart
1  app.dart
```

### 5.2 若按「每批 ≤300 行」的 3 批方案

| 批次 | 文件数 | A 行数 | 预估天数 |
|---|---:|---:|---:|
| 批 1 | 16 | 297 | 1.49 |
| 批 2 | 59 | 300 | 1.50 |
| 批 3 | 17 | 17 | 0.09 |

注：批 3 只有 17 行，说明**尾部极度长尾**（53 个文件各 1–5 行）。建议优先用 4 批方案，让长尾单独成批便于一次性扫尾。

### 5.3 派单注意事项（写入派单模板）

1. **`app_strings.dart` 是共享热点文件**：4 批都要往里加 key，必须**串行合入**或约定 key 命名前缀（`a1_`/`a2_`…）避免冲突。AGENTS.md §98 已把 `app_strings.dart` 列为热点文件。
2. **同批次内文件不重叠**已保证；跨批也无重叠（按文件切分）。
3. **`main.dart` 与 `crash_log_service.dart` 的文案受众是开发者**（FFI 启动错误页、堆转储失败），可延后或保持中文不译，不阻塞用户侧国际化。
4. 每批改动后必须跑 `cd flutter_ledado && flutter analyze && flutter test`。

---

## 六、已知风险

### 6.1 `rss_web_bridge.dart` 的跨语言边界（最高风险）

- **事实**：该文件 59 行中文中，9 行位于注入 WebView 的 JS 模板字符串内（`265-440` 的桥头 IIFE、`458-784` 的 `kRssBridgeSyncShimBody`、`795-811`/`822-859`/`874-981` 的 shim 脚本）。另有 42 行是 `_log`/`debugPrint`，2 行是 Dart 侧信封错误。
- **为什么不能直接换 AppStrings**：注入 JS 是在 WebView 的 JS 引擎里执行，`AppStrings` 是 Dart 静态方法，**在 JS 字符串里无法求值**。若在 Dart 侧先插值，需要在 `rssBridgeHeaderScript(...)` 构造时把翻译后的字符串作为参数传入并 `jsonEncode` 嵌入——可行但要改函数签名并处理转义（`'`/`"`/`\n`）。
- **当前建议**：**本批不处理 JS 注入体的 9 行**，单独立项。它们多数是协议错误回填（`__lgDeliverError`），最终进 Dart `_log`，用户不可见；真正用户可见的是「同步网络在当前平台不可用」这类能力缺失提示，但它的展示路径也是 `java.*` 降级桩 → 回传 → 日志。
- **风险等级**：中。若强行翻译，最容易造成 JS 语法错误（引号转义）导致整个 RSS WebView 桥失效。

### 6.2 「异常消息即用户文案」的判定依赖调用链，易随重构失效

- **事实**：本报告把 `ThemePackageException` / `AppFontPickException` / `CoverAlbumException` / `DirectLinkUploadRuleException` / `ImageDataUriException` / `SystemTtsException` 的消息计为 A 类，依据是**当前**的 catch 点会 `_toast(e.message)` / `Text(e.message)`。
- **风险**：若后续有人把这些 catch 改成「显示通用 AppStrings 文案 + 只记日志」，这些 A 类行就退化为 B 类（无需翻译）；反之若有人把当前 B 类的 `StateError` 改成直接展示，B 会变 A。
- **缓解**：在 `app_strings.dart` 对应 key 上加注释标注「来源异常消息，调用方须保持 e.message 直显」；或在本报告 §2 的映射表基础上建立回归测试。

### 6.3 `policyError` / `credentialError` 的判定分歧

- **事实**：`privacy_notifier.dart:193/208` 的 `'无法读取隐私设置'/'无法读取隐私凭据'` **不会**直接展示——`privacy_app_start_gate.dart:195-215` 在 `policyError != null` 时渲染的是 `AppStrings.privacyPolicyReadFailed` 等**固定文案**，这两个字段只用于 `!= null` 判定。
- **判定**：按「最终渲染点」口径，这 2 行**不算 A**（若按「字段语义」口径则算 A）。本报告采用前者，已在表中标注。若主代理希望保守，可把 2 行加回，A 总量变 616。

### 6.4 生成代码与 Mock 文件

- `misc.freezed.dart` / `misc.g.dart` 含 4 行 `'默认分组'`（生成代码中的默认值）。属 D 类（默认值哨兵），**改源文件 `misc.dart` 即可，不要手改生成文件**。
- `mock_book_api_*.part.dart` 共 9 个文件 165 行，全部 C 类。AGENTS.md §45 明确「Mock 数据使用从原 Android 应用抓取的真实 JSON」，**保持原样**。

### 6.5 基线差异说明（对主代理复核用）

- 主代理报 1271，本次复现 1297（同为 200 文件）。差异 26 行来自排除规则细节（主代理排除了 `_log(` 等，本次基线脚本只排除 `debugPrint/assert(/print(`）。
- 本次全量归类 1580 行，比基线多 283 行，原因：① 多行 `_log(...)`/`writeln(...)` 的**续行**不含关键字，未被基线排除；② `.part.dart` 文件里的内容；③ 多行字符串体内行。
- **无论用哪个基线，A 类都是 614 行左右**——因为多出的 283 行几乎全是 B 类日志续行。

---

## 七、复现命令

所有统计均可用 `python -I`（隔离模式，UTF-8 读文件）复现。脚本位于临时目录（未入库），逻辑如下：

### 7.1 复现基线（1297 行 / 200 文件）

```bash
cd "D:/OH-WorkSpace/LegadoTeam/legado/flutter_legado"
python -I -c "
import io,os,re
CJK=re.compile('[\u4e00-\u9fff]')
tot=0;nf=0
for dp,dn,fn in os.walk('lib'):
    for f in fn:
        if not f.endswith('.dart'): continue
        p=os.path.join(dp,f).replace(os.sep,'/')
        if 'app_strings.dart' in p: continue
        s=io.open(p,encoding='utf-8',errors='replace').read()
        c=sum(1 for l in s.split(chr(10))
              if CJK.search(l) and not l.strip().startswith('//')
              and not any(k in l for k in ['debugPrint','assert(','print(','debugPrintStack']))
        if c: nf+=1; tot+=c
print(tot,nf)
"
```

### 7.2 复现全量归类（1580 行 → A/B/C/D/JS）

脚本逻辑（完整版见调研过程）：
1. 用 `strip_comments` 去掉行注释/块注释（保留字符串内 `//`）；
2. 识别 `'''` / `r'''` / `"""` 多行块，用 `JS_SIG`（`function(`/`var x=`/`window.`/`__lg`/`document.`）判定是否 JS 注入体 → 标 `JS`；
3. 按行正则分类：`B_PAT`（`debugPrint|_log(|print(|assert(|CrashLogService.instance.put|appLogPush|buffer.writeln`）→ B；`D_PAT`（Map key / `case '` / `RegExp(` / `contains('`）→ D；`A_UI`/`A_ERR`/`A_ENUM` → A/A?；
4. 多行调用续行用括号平衡检测归入 B；
5. 输出 `scan5.json`，再叠加**文件级人工裁定表**得到 `final.json`。

### 7.3 关键抽样命令（验证任一文件）

```bash
cd "D:/OH-WorkSpace/LegadoTeam/legado/flutter_legado"
# 列出某文件全部中文行（排除注释）
python -I -c "
import io,re,sys
sys.stdout.reconfigure(encoding='utf-8',errors='replace')
CJK=re.compile('[\u4e00-\u9fff]')
f='lib/src/services/theme_package_service.dart'
for i,l in enumerate(io.open(f,encoding='utf-8').read().split(chr(10)),1):
    if CJK.search(l) and not l.strip().startswith('//'): print(i,'|',l.strip())
"
```

### 7.4 验证「异常消息是否上 UI」的通用方法

```bash
# 1) 找异常类的所有 catch 点，看后续 5 行是否含 Text(/SnackBar/_toast
python -I -c "
import io,os,re,sys
sys.stdout.reconfigure(encoding='utf-8',errors='replace')
cls='ThemePackageException'
for dp,dn,fn in os.walk('lib'):
    for f in fn:
        if not f.endswith('.dart'): continue
        p=os.path.join(dp,f).replace(os.sep,'/')
        s=io.open(p,encoding='utf-8',errors='replace').read().split(chr(10))
        for i,l in enumerate(s,1):
            if re.search(r'on\s+'+cls, l):
                print(p,i,'|','\n'.join(s[i-1:i+5]))
"
```

### 7.5 静态健康度（环境检查）

```bash
cd "D:/OH-WorkSpace/LegadoTeam/legado/flutter_legado"
flutter analyze
```

> 注：本任务为只读调研，未运行 `flutter analyze`（避免与本报告并行任务争抢构建缓存）。建议在派单前由主代理执行一次，确认基线零诊断。

---

## 八、给主代理的可执行建议

1. **口径对齐**：把「剩余 L10N 工作量」正式口径改为 **614 行 / 92 文件**（A 类），B/C/D/JS 明确排除，避免第三次失真。
2. **派单**：优先用 §5.1 的 4 批方案，4 路并行；`app_strings.dart` 的 key 合入串行化。
3. **单独立项**：`rss_web_bridge.dart` 的 9 行 JS 注入体（§6.1），不要混进普通批次。
4. **可延后**：`main.dart`（11 行）+ `crash_log_service.dart`（3 行）受众是开发者，可最后处理或保持中文。
5. **不要动**：`mock_book_api_*.part.dart`（165 行）、`misc.freezed.dart`/`misc.g.dart`（4 行）、`source_share_passphrase.dart` 的 9 条协议映射（§6.4）。

---

编写者：调研员（调研子代理） ｜ 2026-11-24
