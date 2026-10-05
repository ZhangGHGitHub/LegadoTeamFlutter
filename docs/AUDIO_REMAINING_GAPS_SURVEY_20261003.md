# 听书/朗读链残留缺口调研报告（2026-10-03）

调研性质：只读评估（不改代码、不改契约文档）。所有结论均附 文件:行号 证据；「已确认事实」与「推测/待验证」分开标注。基线版本：2.0.350+351（提交 `534c6deb4d` 之后的工作区）。

---

## 缺口①（最高优先）D6：朗读文本是章节 URL 的 JSON，不是正文

### 结论
**该修，确认缺陷（非设计），P0 级语义缺陷，对在线书 100% 复现。**
根因一句话：TTS 文本链选用了 `getChapterContent`，该 FFI 对**本地书**返回正文、对**在线书**直接返回章节 URL 的 JSON 元数据（Rust 注释自证这是「简化占位」），而阅读器走的是 `getChapterContentFull`（缓存检查 → 联网抓取 → 净化，始终返回纯正文）。Dart 侧从未做注释要求的「进一步处理」。

### 明确技术答案：当前送去合成的到底是什么
对在线书籍：送进 `audioSpeak` 的是形如以下的 JSON 串（按空行/换行切段后的片段）：

```json
{"chapter_url":"...","base_url":"...","title":"...","need_fetch":true}
```

对本地书（`is_local_book` 命中 .epub/.txt/.mobi/.pdf/.cbz 等，reader.rs:364-375）：送的是正文（行为正确）。

### 我方调用链（已确认，逐行证据）
1. UI 起点：`flutter_legado/lib/src/screens/reader_screen.dart:857-871` `_startReadAloud` → `AudioNotifier.startReadAloud(bookUrl, chapterIndex)`。
2. `flutter_legado/lib/src/providers/audio/audio_notifier.dart:378-433` `startReadAloud` → :418 调 `_ensureChapterContent(state.currentIndex)`。
3. `audio_notifier.dart:623-635` `_ensureChapterContent` → **:626** `_api.getChapterContent(state.bookUrl, chapterIndex)`；**:628-632 把返回值原样写入 `AudioChapter.text` 内存缓存**（JSON 从此被当作「章节正文」复用）。
4. Dart 桥：`flutter_legado/lib/src/services/rust_api_reader_data.part.dart:230` → `bridge.readerGetContent`。
5. FFI 入口：`rust/legado-ffi/src/ffi.rs:706`；其注释 **:703-705** 明写「本地书籍直接返回正文文本；**在线书籍返回 JSON（含 chapter_url 等信息，需 Dart 侧进一步获取）**」。
6. 实现：`rust/legado-ffi/src/api/reader.rs:295-316` `get_chapter_content` / `get_chapter_content_inner`；**在线书籍分支 reader.rs:346-354** 返回 `serde_json::json!({"chapter_url", "base_url", "title", "need_fetch": true})` 序列化字符串，且**不查正文缓存、不联网**；:342-343 注释「简化实现：返回章节 URL 供 Dart 侧进一步处理」。
7. 回到 Dart：`audio_notifier.dart:587-621` `_playTtsParagraphs` → :593 取 content、:595-596 `_splitParagraphsWithOffsets` 切段 → **:690** `text = _paragraphs[_paragraphIndex]` → **:705-712** `_api.audioSpeak(text: text, ...)` 送 Rust 合成。

QA 佐证：`docs/REFACTORING_ACTIVE_PLAN.md:755` round3 验收残留 O2「该源朗读文本为章节 URL JSON 非正文（既有 D6）」。

### 原版对照（原版如何拿到「纯正文段落」）
- 常规朗读：`app/src/main/java/io/legado/app/service/BaseReadAloudService.kt:355-371` `newReadAloud`：取 `ReadBook.curTextChapter`（阅读器分页排版后的净化正文）→ `textChapter.getNeedReadAloud(0, readAloudByPage, 0).split("\n").filter { it.isNotEmpty() }` 得纯段落列表。
- 语音跟随/独立取章：`BaseReadAloudService.kt:918-932` `loadSpeechChapterOnly`：`BookHelp.getContent(book, chapter)`（读缓存/文件）→ 为空则 `CacheBook.getOrCreate(source, book).downloadAwait(chapter)` **联网抓取** → `contentProcessor.getContent(book, chapter, content, includeTitle = false)` 净化 → `ChapterProvider.getTextChapterAsync` 分页 → :950-953 同样 `getNeedReadAloud(...).split("\n")`。
- 送合成：`app/src/main/java/io/legado/app/service/HttpReadAloudService.kt:305/:408` 取 contentList；:313/:416 `speakText = content.replace(AppPattern.notReadAloudRegex, "")` 送合成。
- 原版从未把「章节 URL / JSON 元数据」当作朗读文本；取不到正文时兜底为「加载正文失败」文案并停止（:925-927）。

### 我方已有的可复用能力（不需要新增 FFI）
- 契约层：`flutter_legado/lib/src/services/book_api.dart:564-568` `getChapterContentFull`，声明「本地书籍直接解析返回；在线书籍自动从网络抓取并返回净化后的正文。**始终返回纯正文字符串，不返回 JSON 元数据**」。
- Rust 实现：`rust/legado-ffi/src/api/reader.rs:967-1000` `get_chapter_content_full`：在线书取 `book.origin` 为书源 → 内部调 `fetch_chapter_content_inner`（:721 起，**先查 DB 正文缓存** reader.rs:733-765，未命中才联网，返回前净化）。
- 阅读器已在用同链路：`flutter_legado/lib/src/widgets/reader/reader_page_view.dart:927-932`（注释明确「getChapterContent 仅读本地缓存不取网」——实为在线书返回 JSON）、`flutter_legado/lib/src/providers/reader/reader_notifier.dart:828-847`。

### 修法、影响面与工作量
- 核心改动一处：`audio_notifier.dart:626` 改为 `_api.getChapterContentFull(...)`。`startReadAloud`（:418）与 `_playTtsParagraphs`（:593）共用 `_ensureChapterContent`，单点生效；**不触及 FFI 边界**（能力已上线）。
- 附带收益：选中段落朗读传 `startParagraphText`（`flutter_legado/lib/src/widgets/reader/text_selection_panel.dart:449-470、655-668`）经 `audio_notifier.dart:423-428` `_mapTextToParagraph(content, ...)` 匹配——在线书时 content 是 JSON 永远匹配不到 → 只能回退章首；换 `getChapterContentFull` 后段落级起播定位同步恢复正确。
- 风险点：
  1. 在线书 `book.origin` 为空时 `get_chapter_content_full` 报错（reader.rs:988-992）——现有 catch 已覆盖（`audio_notifier.dart:429-431` 回退章首、:615-620 错误态），行为可接受但提示文案需核对。
  2. `AudioChapter.text` 内存缓存（:628-632）在改后存正文，同会话重复播放不再重复联网（`_ensureChapterContent` 缓存语义保留）。
  3. 测试适配：依赖 `getChapterContent` 的 mock（`flutter_legado/lib/src/services/mock_book_api_reader_data.part.dart:127` 等）与 audio 族单测需同步改桩。
- 工作量：核心 1 文件 + 测试 1-2 文件，0.5 天内。

---

## 缺口② 朗读引擎列表项点击不设为默认（含 QA 残留 O1）

### 我方现状（已确认）
- **引擎管理页**（`flutter_legado/lib/src/screens/read_aloud_config_screen.dart:184-220`）：`ListTile` **无 `onTap`**，行上只有 trailing 的编辑（:207-211）/删除（:212-218）按钮——点击行无任何行为，管理页内**无法**把某引擎设为当前/默认。
- **朗读条引擎对话框**（`flutter_legado/lib/src/widgets/reader/read_aloud_bar.dart:301-332`）：`RadioGroup.onChanged`（:308-318）在选中**不同**项时 pop 对话框 + `updateConfig(engineUrl: engine.url)` + Snack；但 `RadioListTile`（:323-326）无 `onTap`，点击**已选中**项不触发 `onChanged`（Radio 组件同值不回调）→ 对话框不关闭（QA O1，plan:755）。
- **持久化现状**：`TtsConfig.engineUrl` 仅内存（`audio_state.dart:34-56`，`toJson` 无任何消费方；`audio_notifier.dart:276` 每次 build 重建为空 config）。重启后由 `_ensureDefaultEngine`（`audio_notifier.dart:443-461`）自动选「首个 GET+占位符兼容引擎」，并非用户选择。Book 模型有 `readConfig.ttsEngine` 字段（`book.freezed.dart:394-395`，对齐原版书级引擎）但 Flutter 侧**无写入点**（已搜索 providers/screens 全部 dart，未找到赋值处）。

### 原版对照（`app/src/main/java/io/legado/app/ui/book/read/config/SpeakEngineDialog.kt`）
- **行点击**（:315-326）：`cbName.setOnClickListener` → `upTts(id)`。`upTts`（:277-290）**只更新对话框内存选中态**（`ttsEngine` 字段 + 单选圆点 + adapter 刷新），**不持久化、不关闭对话框**；有登录能力的引擎选中时跳转 `SourceLoginActivity`（:326-332）。长按（:334-344）仅跳登录。
- **设为默认靠显式确认按钮**：「本书」:169-175（`ReadBook.book?.setTtsEngine(ttsEngine)` + `dismissAllowingStateLoss()`）；「通用」:176-181（`AppConfig.ttsEngine = ttsEngine` + dismiss）；取消 :182-184 仅 dismiss。
- 即原版行点击行为 = 改对话框内选中态（**既非立即设默认、也非关闭**）；持久化分「书级 / 全局」两级、由用户显式选择。

### 结论
1. 「点击不设为默认」需要拆成两个子问题：
   - **管理页行点击选中**：我方确实缺失（原版对话框有行点击选中态，参考版另有 SetDefaultEngine）；但**选中的持久化层级**（全局 config 键 / 书级 `readConfig.ttsEngine`（模型字段已就绪）/ 维持现状会话级+自动选默认）是设计决策——**需用户裁决**后再动。
   - 若沿用「朗读条对话框即选即用」语义，则现状已覆盖（onChanged 即 updateConfig），缺的只是持久化。
2. **O1（点已选项对话框不关闭）**：独立小修——`read_aloud_bar.dart:323-326` 给每个 `RadioListTile` 加 `onTap`（已选项仅 pop 关闭；未选项 pop + updateConfig），约 10 行 + 补 1 例 widget 测试（现有 `test/widget/read_aloud_engine_select_test.dart` 可挂靠）。0.5 小时级。原版语义上「点已选项」本就允许无动作，允许关闭属 QA 建议的 UX 放宽，低风险。

---

## 缺口③ 朗读条用页面级本地 Timer（通知栏无剩余量）

### 现状（已确认）
- 页面级状态与计时：`read_aloud_bar.dart:62-64`（`Timer? _stopTimer; int _remainingSeconds = 0;`）；:156-175 `_startTimer`——`Timer.periodic(1s)` 每秒递减 **setState 驱动 UI**（定时按钮高亮与 tooltip :449-464、倒计时文本 mm:ss :465-471），到点 `_remainingSeconds <= 0` 时调 **`pause()`**（:171）。
- 按章停同样是页面级：:70 `_chapterStopTarget`；:246-256 设置「读完本章后停止」；:347-356 build 期检测 `audio.currentIndex >= target` → **`pause()`**（:354）。
- 与 `AudioNotifier` 的关系：仅到点调用一次 `notifier.pause()`；计时过程 Notifier 完全不感知 → 第2项已实现的**通知栏剩余量在此期间不显示**（该能力位于 `audio_notifier.dart:192-201` `sleepTimerRemainingLabel`、:872-878 `_composePlaybackLabel`、:857-866 `_pushMediaSessionMetadata`、:1011-1030 `_ensureSleepTicker`）。
- 生命周期缺口：朗读条 dispose 即取消 Timer（:100），「转后台」（朗读继续、阅读器路由退出）后朗读条定时**静默失效**且无提示——与 A4 批下沉 Notifier 的动机（`audio_notifier.dart:959-957` 段注释「退出听书页不失效」）相悖。

### 剩余量目前在哪里算（上一批已实现部分）
`AudioNotifier` 内：分钟倒计时 `_sleepRemainingSeconds`（:160）+ ticker（:1011-1030），按章停止 `_chaptersToStopRemaining`（:163）+ 章末计数 `_consumeChapterStopAtBoundary`（:1036-1046）；展示文案 `sleepTimerRemainingLabel`（:192-201，形态对齐原版 BaseReadAloudService.kt:701-707）；经 `_pushMediaSessionMetadata`（:857-866）推到通知/锁屏。听书页入口已接（A4 批），**阅读器朗读条未接**。

### 原版到点行为（对照基准）
- 分钟定时：`BaseReadAloudService.kt:553-559` `setTimer`（clamp 0..180、清按章停）；:584-601 `doDs` 60s 循环 + `if (!pause)` 暂停冻结守卫；到点 `timeMinute == 0` → **`ReadAloud.stop(this)`**（:596-599）。`ReadAloud.stop`（`model/ReadAloud.kt:136-142`）→ IntentAction.stop → 服务停止播放并收通知——**是 STOP，不是 PAUSE**。
- 按章停止：`service/ChapterStopTimer.kt:29-33` `onChapterCompleted` 计数归零 → `BaseReadAloudService.kt:885-896` `nextChapter(auto=true)` → `stopSelf()`——同样是 STOP。
- 我方 Notifier 自身 ticker 到点已是 `stop()`（`audio_notifier.dart:1019-1024`），与原版一致。

### 评估结论
- **该做**：迁移本身低风险、收益明确——朗读条复用 Notifier 已有 API（`startSleepTimer` :967 / `startChapterStop` :984 / `cancelSleepTimer` :996 / `sleepRemainingSeconds` 读回），一次性获得：通知栏剩余量显示、转后台不失效、语义与听书页统一。
- 动哪些文件：`read_aloud_bar.dart`（删除 `_stopTimer`/`_remainingSeconds`/`_chapterStopTarget`/`_startTimer`/`_cancelTimer`，改调 Notifier API；倒计时展示改读 `notifier.sleepRemainingSeconds`；现有 `addListener(_onParagraphChanged)`（:87-89）已能感知 Notifier notifyListeners 刷新 UI）+ 相关 widget 测试。预估 1 文件 + 测试，0.5-1 天。
- **行为变更（需用户裁决）**：到点动作将从 **pause() 变为 stop()**（对齐原版 doDs 与 Notifier ticker）——用户可感知差异：pause 保留朗读条与进度可继续；stop 结束朗读会话、通知清除、朗读条回 idle 且再次开始需重播当前段。按章停同理（页面级现为 pause，原版为 stop）。若坚持保留 pause 语义需给 `startSleepTimer` 加「到点动作」参数，造成两套语义分叉，不建议。

---

## 缺口④ 朗读条「选择朗读引擎」按钮热区（人工复核）

### 证据（已确认）
- 按钮实现：`read_aloud_bar.dart:624-629`——标准 `IconButton(icon: Icons.record_voice_over_outlined, tooltip: '选择朗读引擎')`，**无自定义 SizedBox/padding/GestureDetector 收缩**；外层 `_buildSpeedRow` 的 Row 无压缩约束（:586-632）。Material `IconButton` 默认最小触控区为 48x48 逻辑像素（kMinInteractiveDimension）。
- round3 真机实测（plan:755）：content-desc 定位 bounds `[912,1632][1056,1776]` = 144x144 物理像素；MuMu 3x 密度下恰为 **48dp**（若按 2x 密度换算则 72dp），满足且不小于 48dp 触控建议。

### 结论
**无需调整**，当前热区已达 48dp 建议下限。仅当未来在更窄布局中对该行加 `shrinkWrap` 类压缩时需回归复查此项。

---

## 实施建议顺序（按收益/风险）

| 序 | 项 | 收益 | 风险 | 工作量 | 裁决需求 |
|---|---|---|---|---|---|
| 1 | 缺口① TTS 正文（`getChapterContent`→`getChapterContentFull`） | 在线书朗读从「读 JSON」变为「读正文」，语义修复收益最大；附带修复选段起播定位 | 低（FFI 不动，catch 已兜底；mock/测试改桩） | 0.5 天内 | 否 |
| 2 | 缺口②-O1 对话框点已选项可关闭 | 高频可感知 UX | 极低 | 0.5 小时级 | 否（QA 已建议允许） |
| 3 | 缺口③ 朗读条定时下沉 Notifier | 通知栏剩余量 + 转后台不失效 + 语义统一 | 中（到点动作 pause→stop 是**用户可感知行为变更**） | 0.5-1 天 | **是**（到点动作 stop 与否） |
| 4 | 缺口②-主体 管理页选中 + 默认引擎持久化层级 | 补齐管理页选中能力、重启后保持用户选择 | 中（涉及持久化层级设计：全局/书级/会话） | 视裁决 0.5-1.5 天 | **是**（持久化层级） |
| — | 缺口④ 按钮热区 | — | — | 无需改动 | 否 |

## 附：搜索方法与边界说明
- 本次未使用 gitnexus 图谱（本轮任务为定点验证，全部结论均经源码逐行确认，无「仅图谱导航」结论）。
- 中文搜索统一使用 `rg`（Git Bash `grep` 中文不可信）。
- 「未找到」项：Flutter 侧对 `readConfig.ttsEngine` 的写入点（providers/screens 全量 `rg ttsEngine`）；`TtsConfig.toJson` 的消费方（全量 `rg`）——均确认不存在。
