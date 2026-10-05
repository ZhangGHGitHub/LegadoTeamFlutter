# Dart 侧缺口盘点与裁决项技术前提复核（2026-10-04）

> 调研代理产出 ｜ 基线 HEAD：`4c1a4c27c0`（2.0.353+354）｜ 只读复核，零代码改动
> 分工边界：本文不涉及 SAF 目录语义、事件驱动刷新、清理面取锁、Rust stub、Active 计划 :486 六项（另一代理负责）。
> 静态健康度：`flutter_legado/analysis_options.yaml` 存在；`flutter analyze`＝**No issues found**（0 诊断，15s）。

## 〇、结论摘要

1. **三条待裁决项的技术前提全部准确**（本文核实其中两条 Dart 端前提；「缓存目录 SAF」一条按分工未碰）：
   - ① 朗读条定时器下沉——两套计时**确实并存且互不感知**，双计时并行冲突真实可达；
   - ② `readConfig.ttsEngine` 字段**真实存在**（模型层）但 Flutter 侧**确无任何写入方**；原版为书级存储 + 全局回退。
2. **Dart 侧真实缺口：无**。契约测试 7/7 绿（BookApi 290 一致），生产代码（mock_book_api_* 之外）未发现「看似实现实则返回常量」的方法；英文标记命中 5 处均为设计内。
3. **四条已知限制：3 条仍成立、1 条部分演进**（loading 提示已覆盖全部入口，但联网抓取延迟这一限制本身仍真）。

---

## 一、任务 1：待裁决项技术前提核实

### 1.1 朗读条定时器下沉（缺口③）

**前提核实结论：准确，且冲突比台账描述更进一步。**

#### 两套计时的现状

| | 朗读条页面级 Timer | AudioNotifier A4 计时（已下沉） |
|---|---|---|
| 载体 | `ReadAloudBar` StatefulWidget 本地字段 | `AudioNotifier`（Riverpod，随听书会话存活） |
| 分钟倒计时 | `_stopTimer`（`read_aloud_bar.dart:63`），`:157-175` 启动 | `_sleepTicker`（`audio_notifier.dart:199`），`startSleepTimer :1040-1050` |
| 按章停 | `_chapterStopTarget`（`read_aloud_bar.dart:70`），build 检查 `:357-366` | `_chaptersToStopRemaining`（`audio_notifier.dart:195`），`startChapterStop :1057-1066`，章末计数 `_consumeChapterStopAtBoundary :1109-1119` |
| 暂停期行为 | **照常递减**（`:161-174` 无 isPlaying 守卫） | **冻结**（`audio_notifier.dart:1089` `if (!state.isPlaying) return;`，对齐原版 doDs 守卫） |
| 到点动作 | `pause()`（`read_aloud_bar.dart:171`；按章停 `:364`） | `stop()`（`audio_notifier.dart:1095`） |
| 失效时机 | 收起朗读条（`reader_screen.dart:739` 置 `_aloudBarHidden` 卸载组件）或离开阅读器路由 → dispose 取消（`read_aloud_bar.dart:100`），**静默丢失** | 退出听书页**不失效**（`audio_notifier.dart:189` 注释明示「A4：定时停止（下沉 Notifier，退出听书页不失效）」）；仅 `stop()` 会话结束才清（`:1150-1153` `_clearSleepTimerState`） |
| 通知栏剩余量 | 无 | 有（`sleepTimerRemainingLabel :224-233` + `_pushMediaSessionMetadata`，`startSleepTimer :1049` / `startChapterStop :1065` / 取消 `:1074` / 每秒 tick 节流 `:1101`） |

听书页入口已全部接 Notifier API：`audio_screen.dart:158/190`（分钟）、`:209/241`（按章）、`:393/423`（取消）。**阅读器朗读条完全未接**（`read_aloud_bar.dart` 全文件无 `startSleepTimer/startChapterStop/cancelSleepTimer` 调用）。

#### 两者的关系与冲突

- **关系：完全独立、互不感知、无互斥。** 朗读条 `_startTimer`（`read_aloud_bar.dart:157-175`）只操作本地 `_remainingSeconds`，不触碰 Notifier 定时；反向 `startSleepTimer/_clearSleepTimerState`（`audio_notifier.dart:1040/1077`）也不知道朗读条的本地 Timer 存在。
- **「两处都启动定时」的真实后果（用户可到达）**：
  1. 用户在听书页 `startSleepTimer(20)`（通知栏开始显示「剩余 20 分钟」），返回阅读器继续朗读，在朗读条再设 10 分钟 → **两条独立倒计时并行**：第 10 分钟朗读条 `pause()`（`read_aloud_bar.dart:171`），此后 Notifier 倒计时因暂停冻结（`:1089`），恢复播放后于第 20 分钟 `stop()`。用户在同一会话先后遭遇两次不同动作，且两处剩余量展示互不可见（通知栏只显示 Notifier 的，朗读条只显示本地的）。
  2. 反向时序同样成立：朗读条先设 10 分钟 → 转听书页设 20 分钟（阅读器仍在导航栈内、朗读条保持挂载，其 Timer 不取消）→ 两计时并行。
  3. **幽灵暂停**：Notifer `stop()` 结束会话后朗读条 Timer 不受影响继续走完；若用户在归零前手动重新启动朗读，旧定时归零时会 `pause()` 意外暂停新会话（`pause()` 的 `state == playing` 守卫 `audio_notifier.dart:1121-1122` 只挡住已停止的情形）。
- **语义分歧清单（若仅做「接 API」不做裁决会遗留）**：到点动作 pause→stop（台账已登记为用户可感知变更）；暂停期递减→冻结（现状朗读条在暂停期间「倒计时在走但朗读没在放」，与原版 `if (!pause)` 守卫相悖）。

**台账前提对照**：`AUDIO_REMAINING_GAPS_SURVEY_20261003.md:75-94`（缺口③）所述「dispose 即取消、转后台静默失效、Notifier API 已就绪、到点动作 pause→stop 需裁决」逐条与当前 HEAD 代码一致（该文档行号基于旧版本，本文已按 HEAD 重新给出）。

### 1.2 「朗读引擎管理页点行是否同时设为默认」——`readConfig.ttsEngine` 前提

**前提核实结论：准确。字段存在、无写入方、原版为书级存储 + 全局回退。**

- **字段存在（Dart）**：`ReadConfig.ttsEngine` 声明于 `flutter_legado/lib/src/models/book.dart:36`；freezed 字段 `final String? ttsEngine`（`book.freezed.dart:394-395`）；JSON 序列化 `book.g.dart:17/39`。随 Book 模型可从 Rust/DB 反序列化。
- **无写入方（已全量检索）**：`grep -rn ttsEngine flutter_legado/lib` 命中**仅上述 3 个模型/生成文件**——providers、screens、widgets、services 零赋值、零 `copyWith(ttsEngine:)`、零业务读取。台账 `AUDIO_REMAINING_GAPS_SURVEY_20261003.md:60/122` 的「无写入点」结论在 HEAD 上复核成立。
- **原版对应（Kotlin）**：
  - 书级存储：`Book.setTtsEngine/getTtsEngine`（`app/src/main/java/io/legado/app/data/entities/Book.kt:267-272`）写读 `config.ttsEngine`（`BookConfig` 字段，`Book.kt:501`），**随书持久化**。
  - 解析作用域：`ReadAloud.kt:41` `val ttsEngine get() = ReadBook.book?.getTtsEngine() ?: AppConfig.ttsEngine` —— **书级优先、空则回退全局**；全局为 SharedPreferences 键（`AppConfig.kt:506-509`）。
  - 消费：`TTSReadAloudService.kt:60` 将该值按 `SelectItem<String>` JSON 解析取引擎。
  - 交互语义：`SpeakEngineDialog.kt` 行点击仅更新对话框内选中态；「本书」按钮 `:169-175` 写书级；「通用」按钮 `:176-181` = 书级置 null + 写 `AppConfig.ttsEngine`（显式清理书级覆盖）。
- **我方管理页现状**：`read_aloud_config_screen.dart:184-221` 引擎行 `ListTile` **无 onTap**，仅 trailing 编辑/删除两按钮——点行不选中、不设默认，前提「管理页行点击选为我方确实缺失」成立。
- **裁决所需技术事实已齐备**：持久化层级三选一（全局 config 键 / 书级 `readConfig.ttsEngine`（模型字段已就绪，写路径只需 `api.updateBook` 带 `copyWith`）/ 维持现状会话级 + 自动选默认）在两侧代码层面均无阻塞，无契约变更需求，可随时提请用户裁决。

### 1.3 「缓存目录 SAF」一条

按分工**未核实**（另一代理负责），本文零涉及。

---

## 二、任务 2：Dart 侧真实缺口盘点（`flutter_legado/lib/`）

**结论：无新的真实缺口。** 检索方法与证据：

1. **英文标记全量检索**（`TODO|FIXME|XXX|HACK|UnimplementedError|UnsupportedError|not implemented|NotImplemented`，剔除 `*.g.dart`/`*.freezed.dart`）仅 5 处，逐一定性：
   - `src/bridge/frb_generated.dart:10244/:10370` — FRB 生成器守卫（StreamSink 解码方向不可达），与四分类台账 `docs/STUB_FALLBACK_CLASSIFICATION_2026-08-22.md` A1/A2 同类，**有意为之**；
   - `src/services/local_media_source_web.dart:11` `UnsupportedError('Web 平台不支持本地 TTS 音频文件播放')` — web 编译守卫（配套注释 `local_media_source.dart:5`），**有意为之**；
   - `src/screens/offline_cache_screen.dart:35` — 注释中「销记 bookshelf_screen TODO」，是**已关闭项的留痕**，非开放缺口。
2. **假实现桩扫描**（`mock|stub|fake|placeholder|dummy|sample|demo` + 常量返回模式 `=> Future.value|return const []|=> false|=> 0;` 等）：
   - `rust_api*.part.dart` 八个 part 文件逐一抽查**缓存/下载/播放**关键方法，全部真实走 FFI bridge：`ttsSpeak`（`rust_api_media_format.part.dart:393-405`→`bridge.ttsSpeak`）、`getAudioChapterMedia`（`:416-425`→`bridge.audioGetChapterMedia`）、进度读写（`:429-452`→`bridge.audioGetProgress/audioSaveProgress`）、`audioCacheDownload/audioCacheCancel`（`rust_api_discovery_cache.part.dart:417-435`→FFI，契约 §2.48）、`getChapterContentFull`（`rust_api_reader_data.part.dart:246-256`→`bridge.readerGetContentFull`，含平台桥接拦截点）；
   - `PlatformBridgeService.interceptResult`（`platform_bridge_service.dart:152-162`）：FFI 调用**先行**，仅当整体结果恰为 webView 桥接载荷时执行并回填，失败退回原文——是解析增强不是假实现（Task #114 登记设计）；
   - 常量返回命中均为入参空守卫（`app_update_service.dart:246`、`bottom_bar_skin_service.dart:200`、`platform_bridge_service.dart:830/838`）或 mock part 内（设计内，`USE_MOCK` 双轨开关，四分类台账 B3）；
   - `txt_toc_rules_screen.dart:32` `_sampleText` 为目录规则预览样例文本（功能本体），`replace_rule_edit_screen.dart:303-402` sample 为用户输入预览——**非假数据**。
3. **契约一致性实测**：`flutter test test/unit/api_contract_test.dart` → **7/7 通过**（契约文档结构、BookApi ⊆ RustApi、BookApi ⊆ MockBookApi、公共额外方法钉死 RustApi={toString, refreshReadBookConfig}、每方法登记、§2.x 行数自洽、总数=程序化计数 290）。`API_CONTRACT.md` 2026-10-03 条目载明 BookApi 288→290（§2.48 两写入方法），与实测一致。
4. **既有四分类台账交叉核对**：`docs/STUB_FALLBACK_CLASSIFICATION_2026-08-22.md`（基线 `3b61f0883`）的 A/B/C/D 四类在当前 HEAD 复查类别无新增、无漂移（生成器不可达行号自 8830/8926 漂移至 10244/10370，属 FRB 重新生成，定性不变）。

**判定**：除 `mock_book_api_*.part.dart`（`--dart-define=USE_MOCK=true` UI 轨开发档，双轨规范允许）外，未发现「看似实现实则返回常量/空值」的生产方法。**Dart 侧当前无可登记的新缺口。**

---

## 三、任务 3：四条已知限制复核

| # | 限制（台账表述） | 结论 | 证据 |
|---|---|---|---|
| 1 | 旧孤儿键 `${bookUrl.hashCode}_$i.audio` 文件已在用户设备落盘、**无任何读取方** | **仍成立** | `flutter_legado/lib` 全量零命中（`hashCode}_` 模式）；唯一出现处为**守卫测试** `test/widget/audio_cache_predownload_offline_test.dart:15/:54`（断言旧写入路径不得复活，防回归用）；Rust 读面 `rust/legado-ffi/src/api/audio_cache_api.rs:31-33` 文档明示「不读不迁移：不匹配五段式正则且无 `.complete`，扫描时天然跳过」，`parse_cache_file_name`（`:215`）拒绝旧键形态（测试 `:1207/:1297` 锁死）；Kotlin 原版零命中（原版 `AudioCacheKey` 为五段式，与本重构版自创键无关） |
| 2 | `kAudioCacheTreeUriKey` 保留但**无读写方** | **仍成立** | 全 `flutter_legado/lib` 仅定义一处：`src/utils/audio_skip_policy.dart:18`（`const String kAudioCacheTreeUriKey = 'audioCacheTreeUri';`），无任何 import 方引用该常量；`rust/` 全工作区 `audioCacheTreeUri/audio_cache_tree_uri` 零命中 |
| 3 | 在线书首次朗读「秒回」变「联网抓正文」，弱网体验待观察——loading 提示是否覆盖所有入口 | **loading 已覆盖两处入口**；联网延迟这一限制本身**仍真** | 状态置位：`startReadAloud` 预取前 `PlayerState.loading`（`audio_notifier.dart:452`，预取 `:454`）；直接/恢复播放统一汇入 `_playTtsParagraphs`（置 loading `:624`，预取 `:629`；`play :499-506`、`resumeOrPlay :1138-1147` 均到此处）；音频书流模式同（`_playAudioBookStream :509`）。展示面：朗读条播放键转圈（`read_aloud_bar.dart:558-564`）+ 状态文案「加载中」（`:726-727`）+ 沙漏图标（`:421-422`）；听书页 FAB 转圈（`audio_screen.dart:645-655`）。失败有可见提示（`:651-657` errorMessage → 朗读条横幅 `:394-395` / 听书页 `:508-520`） |
| 4 | 抓取失败时预取与 play **各尝试一次（最多两次网络请求）**，无重试退避 | **仍成立** | `startReadAloud` 预取失败仅 `debugPrint` 吞掉（`audio_notifier.dart:465-466`）后继续 `await play()`（`:468`）→ `_playTtsParagraphs` 二次 `_ensureChapterContent`（`:629`）；`_inFlightChapterContent` 仅去重**并发在途**（`:666-677`，`finally` 移除），失败结果无负缓存，第二次调用必然重发；二次失败走 `:651-657` 用户可见报错。全链无第三次尝试点 |

---

## 四、任务 4：下一批建议

1. **朗读条定时器下沉（缺口③）可提请用户裁决后实施**——解决什么：消除「双计时并行 + 幽灵暂停 + 转后台/收起静默失效」，一并获得通知栏剩余量与暂停冻结语义；涉及文件：`flutter_legado/lib/src/widgets/reader/read_aloud_bar.dart`（删 `_stopTimer/_remainingSeconds/_chapterStopTarget` 本地实现，`_showTimerPicker` 改调 Notifier API）、`flutter_legado/lib/src/providers/audio/audio_notifier.dart`（复用 `startSleepTimer/startChapterStop/cancelSleepTimer`，零契约变更）；**需用户裁决**：是（唯一分歧点到点动作 pause→stop，用户可感知）；理由：本文已逐行核实冲突路径真实可达、前提无一失效，实施本身约半天量级。
2. **其余：无。** Dart 侧经英文标记、假实现桩、契约测试三路盘点未发现值得新开批次的真实缺口；`readConfig.ttsEngine` 管理页交互属既有登记的设计决策（技术事实已齐备，见 §1.2），不建议在裁决前抢先实现。

---

## 附：检索口径备忘

- 中文检索一律未采用（Windows shell 可靠性）；缺口定位全部走英文标记、符号名与源码逐行阅读。
- 台账旧行号（如 `audio_notifier.dart:160/:1011-1030`）与 HEAD 有漂移，本文行号均为 `4c1a4c27c0` 实读值。
- `flutter test test/unit/api_contract_test.dart` 与 `flutter analyze` 均为只读验证命令，未产生任何文件改动。

（编写：调研代理 ｜ 2026-10-04 ｜ 基线 4c1a4c27c0）
