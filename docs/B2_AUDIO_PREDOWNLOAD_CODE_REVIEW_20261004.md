# B2 音频预下载写入面 独立代码审查报告（2026-10-04）

- 审查对象：`5f35ccb473`（feat(rust) 音频章节预下载写入面与两原版入口，15 文件 +3228/-673）、`08fca97036`（feat(ui) 听书目录音频缓存徽标，2 文件）、工作区未提交契约 `docs/API_CONTRACT.md` §2.48。
- 语义基线：`app/src/main/java/io/legado/app/help/audio/AudioCachePolicy.kt`、`AudioCacheManager.kt`、`service/AudioCacheService.kt`、`ui/book/audio/AudioPlayActivity.kt`、`help/http/HttpHelper.kt`（只读对照）。
- 审查方式：只读（未改任何被审代码）。逐条 diff + 基线对照 + 实跑验证（见「证据分级」）。
- **Summary: needs changes（需修后合并）**——无 P0 阻断；1 项 P1（同 key 并发缺互斥，UI 可达的缓存静默丢失）+ 1 项契约文本失准需主代理同步；其余为 P2。

---

## 一、P0 清单项核实结论（先给判定，证据附后）

| # | 清单项 | 判定 | 一句话结论 |
|---|--------|------|-----------|
| 1 | 流式落盘 | **通过** | `next_chunk`→reqwest `chunk()`→BufWriter 直写盘，diff 无任何全量收集点 |
| 2 | 路径穿越/目录逃逸 | **通过** | safeTitle 全链净化、文件名恒有 `%05d_` 前缀、playUrl 仅以 md5 进名 |
| 3 | ext 白名单强制 | **通过** | 探测→构名→解析三重白名单把关，白名单外扩展名无法落盘 |
| 4 | `.complete` 回读校验 | **通过** | 写后读回 decode==playUrl，不一致删标记并 Err |
| 5 | 取消代数正确性 | **通过（含固有窗口，已登记）** | 无「误杀新任务」；无在途返回 false 符合契约「尽力提示」；停滞流由客户端 60s 总超时兜底 |
| 6 | 失败清理彻底性 | **通过** | Err 路径统一删 final+marker+staged；回环测试验证零残留 |
| 7 | TOCTOU/并发同 key | **未通过（P1-1）** | 缺原版 `chapterLocks` 互斥；UI 可达的双批次并发会互删对方已装文件，双方报成功但缓存净丢失 |

---

## 二、Errors / Warnings（分级明细）

### P1-1（必修）同 key 并发下载无互斥，互相删除对方产物，双方报成功但缓存净丢失

- **归类**：并发网关缺失（写入边界）。
- **涉及文件**：`rust/legado-ffi/src/api/audio_cache_api.rs:758-973`（`audio_cache_download_with_client` 全程无按 (bookUrl, key16) 的互斥）；对照原版 `AudioCacheManager.kt:44,117`（`chapterLocks = Array(16) { Mutex() }` + `chapterLock(bookUrl, key).withLock { cacheChapterLocked(...) }`）。
- **症状（期望 X vs 实际 Y）**：
  - 期望：同章节两个并发下载被串行化（原版语义），最终目录收敛为恰好一份已提交缓存。
  - 实际：两个任务可全程交错——各自的 `rev8` 随机名保证**中间产物**不互相覆盖，但：
    1. 任务 A 步骤⑦ `remove_cache_files(dir, key16, Some(finalA))`（`audio_cache_api.rs:951`、`683-703`）会删除任务 B **正在写入的** `tmp_{key16}_*.part`（`is_temporary_file` 同 key 命中，无 1h 阈值保护——1h 阈值只在步骤③ `cleanup_uncommitted_files` 生效）；
    2. A、B 先后安装 `finalA`/`finalB` + 各自标记后，A 的清理删 `finalB+markerB`，B 的清理删 `finalA+markerA`——**两个任务都返回 `Ok("installed")` 且 path 指向已不存在的文件**，目录净空，缓存静默丢失（用户重新播放/重下=浪费流量；徽标不亮）。
- **UI 可达性**：`flutter_legado/lib/src/screens/audio_screen.dart`——「缓存章节范围」菜单项未在 `_audioCacheRunning` 时禁用（`:299-306` 仅有 `if (_canCopyPlayUrl)`），`_showAudioCacheRange` 以 `unawaited(_runAudioCacheBatch(...))` 启动（第二批令牌自增只会让第一批循环在**当前章 FFI 返回后**退出，当前在途下载不受影响）；两个批次范围重叠时，同章 `audioCacheDownload` 并发成立。原版经单 worker + `chapterLocks` 双重排除，我方两层都没有。
- **建议修法**（二选一，推荐 a）：
  - a. Rust 侧对齐原版：按 `hash(bookUrl, key16) % N` 分片 `Mutex`（原版 16 片先例），覆盖从幂等检查到步骤⑦清理的整段；这也顺带修复「清理并发任务在写 tmp」问题。
  - b. 最小修：Dart 侧 `_audioCacheRunning` 时隐藏/禁用 `cacheRange` 菜单项并在 `_runAudioCacheBatch` 入口重入直接 return（但这只堵 UI，FFI 面仍无原版等价保证，建议作为 a 的过渡而非替代）。
- **Proof**：代码路径推演（上列行号）；并发复现命令骨架——对同一 (bookUrl, key16) 用两个线程同时调 `audio_cache_download_with_client`（回环慢速服务器），断言结束后 `read_dir_entries(book_dir)` 非空且 `audio_cache_query == true`。现有测试全部串行（`TEST_LOCK`），未覆盖该竞态。

### P1-2（必修，主代理契约动作）契约 §2.48 playUrl 来源文本与实现不一致

- **归类**：契约一致性（冻结文本 vs 实现）。
- **涉及**：`docs/API_CONTRACT.md` §2.48（工作区未提交版）写「playUrl 由 Dart 经既有 **getChapterContentFull**（内容链）解析后传入」；实现为 `audio_screen.dart` `_runAudioCacheBatch` 调 **`getAudioChapterMedia(bookUrl, index).mediaUrl`**（契约 §2.26，对齐 `AudioPlay → WebBook.getContent`）。
- **判定**：**实现正确、契约文本失准**——原版写入链的 playUrl = `WebBook.getContentAwait`（`AudioCacheManager.kt:139-144`）即播放链同源原串；`getChapterContentFull` 若叠加替换规则/简繁转换会污染 URL，实现选择 `getAudioChapterMedia` 恰好是对齐原版的正确决定（提交信息已自登记「契约措辞偏差」）。但契约是唯一依据且处于冻结态，文本不改，后续任何以契约为准的验收/回放都会判这条为「偏离」。
- **建议**：主代理修订 §2.48 该句为「playUrl 由 Dart 经既有 `getAudioChapterMedia`（§2.26 播放链同源）取 `mediaUrl` 传入；**不用** `getChapterContentFull`（会应用替换规则/简繁转换污染 URL）」并在变更日志登记措辞修正。
- **Proof**：`grep -n "getChapterContentFull" docs/API_CONTRACT.md`（§2.48 行）vs `rg -n "getAudioChapterMedia" flutter_legado/lib/src/screens/audio_screen.dart`。

### P2-1（建议）「清除本章缓存」对「仅剩 `.complete` 标记」残态的提示与原版相反

- **涉及**：`audio_screen.dart` `_clearCurrentAudioCache`（`removed > 0` → 「已清除本章缓存」，否则「本章没有缓存」）vs 原版 `AudioPlayActivity.kt:318-349`（`removeCachedChapter` → `hasCacheFiles` 含标记文件 → 同态返回 true → 报「已清除」）。
- **症状**：目录里某章只剩孤儿 `.complete`（数据文件被外部删除/历史中断）时，实际：计数 0 → 提示「本章没有缓存」且标记**不会被清除**；期望（原版）：报「已清除」且标记被删。
- **影响**：极窄残态（正常流程标记与数据同生共死），仅提示文案差异 + 孤儿标记滞留（`audio_cache_list`/命中判定不受影响，因 `is_committed` 要求同名数据文件存在）。
- **建议**：可不修；若修，`audio_cache_clear_chapter` 返回值改为「数据文件计数，但全空且删了标记时返回 1」会破坏「只统计数据文件」的冻结口径——更稳妥是在 Dart 侧改为先 `audioCacheQuery` 后清理的提示逻辑，或接受现状并在 B1 报告补一句边界登记。

### P2-2（建议）批量循环「已缓存跳过」按下标而非 key，TOC 重排后可能漏下章节

- **涉及**：`audio_screen.dart` `_runAudioCacheBatch`（`cachedIndexes.contains(index)` 跳过）vs 原版 `AudioCacheService.kt:208-216`（`key !in cachedKeys`，键为 `AudioCacheKey.from(chapter)`）。
- **症状**：`audioCacheList`（§2.47）返回的是**文件名中记录的章节下标**（下载时刻的 TOC 序）；若下载后目录重排（换源/刷新 TOC），下标错位时本章实际未缓存却被跳过。Rust 侧幂等判定（key16 + `.complete`）只兜住「多下」方向，兜不住「少下」方向。
- **建议**：接受现状（换源后缓存本就不跨键复用，影响一次批量任务），或在批量循环内改为对每章调 `audioCacheQuery(bookUrl, index, chapter.url, chapter.title)`（逐章 FFI，代价可接受，键语义与原版对齐）。

### P2-3（建议）`audio_screen.dart:473` 格式回归

- **症状**：`final scheme = Theme.of(context).colorScheme;    return Padding(` 两条语句挤在一行，系本批 diff 引入；`dart format --output=none` 判定该文件非格式干净。`flutter analyze` 不查格式，故未被门禁拦截。
- **建议**：合入前跑一次 `dart format lib/src/screens/audio_screen.dart`（单行变更，不涉逻辑）。

### P2-4（备注，不建议修）Dart 循环对「章节下标越界」计 fail 与原版不计不一致

- `audio_screen.dart`：`chapter == null` → `_bumpAudioCacheProgress(fail: true)`；原版 `AudioCacheService.kt:213-231` 对 null 章节仅 `doneCount++`。因 range 已按 `chapters.length` 规范化，该分支实际不可达，仅为口径备注。

---

## 三、实际核实过的关键点（证据）

### 3.1 流式落盘（P0-1）——通过

- `rust/legado-net/src/response.rs:163-169`：`next_chunk` = `reqwest::Response::chunk().await`，逐块返回 `Option<Vec<u8>>`；`LegadoStreamResponse`（`:85-115`）构造时只收集响应头，body 保持未读。
- `audio_cache_api.rs:919-937`：循环 `block_on(response.next_chunk())` → `writer.write_all(&chunk)`（BufWriter 直写 `fs::File::create(&staged_path)`）。
- 对 `5f35ccb473` 全量 diff grep `bytes()/to_vec/collect::/read_to_end/body()`：仅命中 `install_staged_file` 回退分支的 `io::copy`（流式）、marker 回读 `fs::read_to_string`（几十字节）、测试代码——**无整文件入内存路径**。
- 60s 佐证：`client.rs:222`（`.timeout(config.read_timeout)` 为 reqwest **总超时**，含读 body）对照原版 `HttpHelper.kt:60-63` `callTimeout(60, SECONDS)`（同为含 body 的整调用超时）——**语义一致，非缺陷**；大音频在慢速连接下两边同样会被 60s 掐断，属忠实对齐而非新增性能回归。

### 3.2 路径穿越（P0-2）——通过

- `safe_title`（`audio_cache_api.rs:409-433`）：`\\ / : * ? " < > |` → `_`（`:413`），去 C0/C1 控制符（`:395-397,417`），trim（Kotlin 空白语义）→ 去首尾 `_` → 空则 `chapter` → 截 40 → 去尾 `.`/空格 → 空则 `chapter`。单测 `safe_title_normalization`（`:1523-1548`）覆盖含 NBSP、控制符、点串等 13 个边界。
- 文件名恒为 `%05d_{key16}_{safeTitle}_{hash16}_{rev8}.{ext}`（`build_file_name:571-575`）：`chapter_index < 0` 直接 Err（`:559`），首段恒为数字——**首 token 不可能是 Windows 保留名（CON/NUL/COM1…），保留名攻击面不成立**。
- `playUrl` 仅经 `md5_mid16(play_url)` 进名（`:911`）；`key16`/`rev8`/`tmp uuid` 均为小写 hex（`random_hex:615-631`，计数器+纳秒+RandomState 合成）；`bookUrl` 仅经 `book_dir` 的 md5 进目录（`:194-196`）。
- 对原版链的忠实度补注：`normalizeFileName` 替换集与 `AppPattern.fileNameRegex2` 对齐；`take(40)` 的 UTF-16/Unicode-scalar 截断差异已在代码注释登记为有意差异（`:405-408`），认可。

### 3.3 ext 白名单（P0-3）——通过

- 探测层：`detect_extension`（`:492-541`）只产出 Content-Type 映射值、`extension_from_url`（`:439-450`，白名单内才返回）、或 `"audio"`；Content-Type 含 `mpegurl`/最终 URL 为 HLS → Err。
- 构名层：`build_file_name` 再次断言 `extension ∈ 白名单 ∪ {"audio"}`（`:568`），白名单外扩展名根本构不出文件名。
- 解析层：`parse_cache_file_name`（`:220-222`）读侧第三重把关。
- 结论：`.exe/.sh/.php` 无法落盘也无法被识别为缓存文件。与 `AudioCachePolicy.kt:15-18,121-128` 逐值一致（12 扩展 + audio）。

### 3.4 `.complete` 回读校验（P0-4）——通过

- `write_complete_marker`（`:1021-1039`）：写 `1\n{md5_16(playUrl)}\n{playUrl}` → flush → `fs::read_to_string` 回读 → `decode_metadata` 比对 `== play_url`，不一致删标记并 Err「音频缓存完成标记校验失败」。与 `createCompleteMarker:266-281` + `AudioCacheMetadata.decode:145-152` 一致（`splitn(3,'\n')` 对齐 Kotlin `split(limit=3)`）。集成测试 `download_installs_and_cleans_old_versions`（`:1929-1933`）断言标记内容逐字节等于 `encode_metadata`。

### 3.5 取消代数（P0-5）——通过（含已登记固有窗口）

- `CANCEL_GEN`（`:88`）/`IN_FLIGHT`（`:93`）；下载任务先取快照再登记（`:831-832`），块边界与关键步骤后共 4 处 `cancel_generation_changed` 检查（`:925,934,945` 及流结束前）。
- 「取消后新任务被误杀」：不存在——cancel 先于新任务注册到达时因 `IN_FLIGHT==0` 返回 false 且**不**递增代数（`:735-739`），新任务快照即新代数。
- 「取消无效」：唯一窗口是「任务已 load 快照但未 `fetch_add` IN_FLIGHT」的纳秒级间隙，此刻 cancel 返回 false——契约明文「尽力提示，不作同步保证」覆盖，认可。
- 停滞流：块边界检查在无数据块到达时不会执行，但客户端 60s 总超时（`client.rs:222`）保证 `next_chunk` 至多挂 60s 后转 Err 走失败清理——**取消至多延迟 60s，不会永久挂死**（与原版 ensureActive 在阻塞 read 间的局限等价）。
- 实测：`cancel_aborts_inflight_download`（`:2056-2141`）——慢速服务器在途取消，断言 Err「音频缓存下载已取消」、目录零残留、IN_FLIGHT 复位、无在途返回 false。本审查实跑通过。

### 3.6 限速许可持有/释放（P1-10）——通过

- `send_stream`（`client.rs:696-713`）获取的 `OwnedSemaphorePermit` 移入 `LegadoStreamResponse._permit`，随流消费结束/结构丢弃释放（`response.rs:90-91`）——与 `get_raw`「许可活到 body 读完才释放」（`client.rs:471-488`，permit 局部变量存活至 `collect_raw_response` 返回）**等价**，无泄漏（reqwest::Response 与 permit 均随结构 drop；panic 时 InFlightGuard/结构 drop 亦复位）。
- 「长期持有是否阻塞后续请求」：许可数 = 域并发上限；但 FFI 共享客户端 `LegadoClientConfig::default()` `rate_limit: None`（`client.rs:123`）、`http_state.rs:370-377` 以默认配置构建——**当前主链路未启用域限流，permit 恒为 None**，不构成阻塞面。若未来启用限流，长下载占住一个域许可属设计内语义（与 get_raw 等价），建议在启用时复核。
- cookie/重试/门控语义与 `send` 一致：同 factory（默认头+cookie 注入+`COOKIE_JAR_HEADER` 写侧门控；音频请求头经 `parse_source_headers` 携带标记，`web_book.rs:941+`）、同 `retry_executor`；`timing` 事件有意不伪造（`client.rs:657-658` 注释）。UA 轮换/代理中间件在 `send` 同样未实际接线（`middleware_chain` 仅构建未运行，既有现状）——非本批回归。
- 音频路径自带的重试循环（`audio_cache_api.rs:882-889`）与 `legado-fetcher/analyze_request.rs:141-170` `send_with_options` 逐条一致（非 2xx/3xx 立即重发至多 retry 次、Err 直接上抛、followRedirects=false 走派生客户端）。

### 3.7 spawn_blocking 桥接（P1-11）——通过

- `ffi.rs:62-72,1952-1969`：`audio_cache_download` = async + `tokio::task::spawn_blocking`；内部 `crate::runtime::block_on`（多线程 runtime，`runtime.rs:18-24,82-84`）从阻塞池线程进入 runtime，合法、无嵌套死锁。单个下载占一个阻塞线程，tokio 阻塞池动态扩容（上限远大于并发 FFI 数），且受 60s 总超时约束——不会长占导致其他 FFI 卡顿。与 §2.17 webbook* 先例同型。

### 3.8 清理计数口径（P1-9）——通过

- `remove_cache_files`（`:683-703`）：dataTargets = 五段式数据文件 + `tmp_*.part`，**不含 `.complete`**；标记进 markerTargets 照删不计——对齐原版 `removeCacheFiles:338-356` `return dataTargets.size`。
- `audio_cache_clear_book`（`:369-389`）：跳过 `.complete` 计数、随后单独删标记。与冻结口径一致，DLL 运行时用例（clearChapter 2→1、clearBook 4→2）佐证。

### 3.9 失败清理（P0-6）——通过

- `audio_cache_api.rs:919-965`：install/marker/cleanup 全部包进 result 闭包，Err 统一删 `final_path + marker_path + staged_path`（`:956-964`）；`install_staged_file` 内部分支失败各自删目标（`:986-1013`）；marker 写失败删标记（`:1027-1030`）。
- 实测：`download_failures_leave_no_residue`（`:1963-2052`）——HTTP 500 / 空体 / 声明 100 实发 10 三场景后目录零残留。本审查实跑通过。
- 幂等：命中（key16 + `.complete` + size>0，`latest_committed_file:284-301`）返回 `already_cached` 且不发请求（测试断言 `hits==1`，`:1943-1956`）。

### 3.10 TOC 徽标批（P2-13）——通过

- `toc_screen.dart`：音频书判定 `(bookType & BookType.audio) != 0`（位标记正确）；轮询与初始加载均在 `_isAudioBook && !_isLocal` 守卫下才调 `audioCacheList`——**非音频书/本地书零 FFI**；`audioChanged` 并入无变化跳过 setState 守卫（空集未变不重建）；查询失败保留旧态。widget 测试 6 用例（含 Text 实例同一性断言）本审查实跑通过。
- 轮询成本备注：音频书目录打开期间每秒一次目录扫描（每章 2 文件量级），沿用本屏既有 1s 轮询模式，未引入 setState 风暴，可接受。

### 3.11 「缓存目录」入口（P2-15）——通过

- `audio_screen.dart` 全文：`cacheRange`/`clearCurrentCache` 已恢复，`缓存目录` 仅存在于注释（`:283,989`），无死代码入口、无半成品绑定；`kAudioCacheTreeUriKey` 残留于 `utils/audio_skip_policy.dart` 系 B1 批已登记的保留配置键（无读取方），非本批引入。「加回即假功能」的判断正确。

### 3.12 frb_generated / 安全杂项（P2-14）——通过（格式回归除外，见 P2-3）

- `frb_generated.rs`/`.dart` 抽查：两个新 wire 函数（`wire__crate__ffi__ffi__audio_cache_download_impl` / `..._audio_cache_cancel_impl`）签名与手写 ffi.rs 一致，其余为机械重排。
- 新增 Rust 代码无 `unsafe`；日志（log::warn/debug）不含 playUrl/凭证；Dart `debugPrint` 仅记错误消息，与仓库既有模式一致。

---

## 四、契约与实现不一致清单

| # | 条目 | 性质 | 处置 |
|---|------|------|------|
| 1 | §2.48「playUrl 经 getChapterContentFull」 vs 实现用 `getAudioChapterMedia`（§2.26） | **契约文本失准，实现更贴原版**（原版 `cacheChapterLocked:139-144` 即播放链 `WebBook.getContentAwait` 同源） | 主代理修订冻结文本并登记（P1-2） |
| 2 | 同 key 并发：契约「逐条对齐 AudioCacheManager.kt:132-199」隐含 `chapterLocks`（:117）串行化，实现无互斥 | 实现缺契约所声明的对齐项 | 修复（P1-1） |
| 3 | §2.48「无超时（原版无）」——实现沿用共享客户端 60s 总超时 | **非不一致**：原版 `HttpHelper.kt:63` 同有 `callTimeout(60s)`，契约句指「不新增超时」，口径自洽 | 无需动作（本表留档防误读） |
| 4 | `isCacheDirAvailable` 无对应 FFI，目录不可用时逐章 Err 而非原版一次性预检/对话框 | 契约已登记「由 Dart 侧组合既有方法完成」+ 逐章粒度差异；目录为应用私有 `create_dir_all` 几乎不失败 | 无需动作（接受） |
| 5 | Dart「已缓存跳过」按下标 vs 原版按 key | UI 编排层口径差异（决策门仍在 Rust 幂等），见 P2-2 | 建议 / 接受 |

## 五、证据分级与 non-claims

- **本审查实跑**：`cargo test -p legado-ffi --lib audio_cache`（20/20 绿，含回环安装全链路/幂等/失败清理/取消中止）；`flutter test` 定向 26 项（audio_cache_api_test + test/ffi/audio_cache_runtime_test + toc_audio_cache_badge_test + audio_cache_predownload_offline_test）全绿；`api_contract_test`（BookApi 290 闭合）绿。
- **代理声明、本审查未复跑**（非 claims）：全量 `flutter test` 2086 绿、`cargo test -p legado-ffi` 429 lib + 集成全绿、`cargo clippy -D warnings` 0、`cargo fmt --check`、DLL 重编。此为代理自报门禁，本报告不为其背书。
- **并发缺陷（P1-1）为代码路径推演 + UI 可达性论证，未跑并发复现**（现有测试串行锁排除了并发；复现用例建议随修复补入）。
- 审查范围限于两提交 + 工作区契约 §2.48；未审 e0c374d95b 之前批次。

## 六、总体结论

**需修后合并**。P0 五项关键安全/正确性面（流式、穿越、白名单、回读、取消、失败清理）全部核实通过且对齐原版；唯一必修缺陷是 P1-1 同 key 并发互斥缺失（UI 可达、后果为缓存静默丢失），连同 P1-2 契约文本同步，两项收口后即可合并；P2 各项均为边缘残态/口径备注。

**处置决定：convert_to_check**——将 P1-1（同 key 互斥 + 并发复现测试）与 P1-2（契约 §2.48 playUrl 来源措辞修订）转为主代理下一批次的验收检查项；P2-3（格式）随手批带走；P2-1/P2-2/P2-4 留档不强制。
