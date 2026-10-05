# B1「音频缓存数据链」调研报告（2026-10-03）

编写者：调研员（子代理）｜ 2026-10-03
性质：只读调研 + 契约条文拟稿。**未修改任何代码与 `docs/API_CONTRACT.md`**；本文档为唯一新增文件。
基线声明：参考版（kazusa）源码未在工作区内找到（搜索过 `D:\OH-WorkSpace\LegadoTeam` 两级目录及本仓全树，无命中），**本报告以 Android 原版 Kotlin 为唯一语义基线**。

---

## 结论摘要（先行）

1. **原版缓存键不是 `md5Encode16(chapterUrl + "|" + title)`**：是 `MD5Utils.md5Encode16(chapterUrl.ifBlank { chapterTitle })`，即「章节 URL（为空才用标题）」的 MD5 hex **中段 16 字符**（`substring(8,24)`）。无分隔符拼接、无 bookUrl 参与。
2. 原版写入（预下载）只发生在 `AudioCacheService` 前台服务（用户菜单「缓存范围」触发）；**播放链只读缓存、从不写**。缓存命中完全跳过网络。
3. 我方现状：播放链**无任何音频文件缓存读取**；`audio_screen.dart:996` 的旧键 `'${bookUrl.hashCode}_$i.audio'` 是**孤儿写**（写完永远没人读）；目录页无缓存徽标。Rust 侧有一个**未接线的孤儿模块** `legado-core/src/audio_cache.rs`（不持久、键规则与原版不符、策略自创）。
4. **B1 必须改 FFI 边界**（理由与最小方法集见任务 C），必须先冻结 `docs/API_CONTRACT.md`。
5. 「按原版数据恢复」**跨应用不能直读**：原版音频缓存不在 app 私有目录，而在**用户选定的 SAF 目录**（`AppConfig.audioCacheTreeUri`）；我方 app 重新授权选同一目录后可完整读写（SAF 授权按 app+URI 授予，不继承）。恢复 = 按**原版键规则解析** + 读**原版目录**（用户重新授权），两者缺一不可。
6. 写入归属推荐：Android 侧走 **Dart `saf` 插件写用户 SAF 目录**（对齐原版 + 与原版数据互通），桌面端 Rust 写私有目录；Rust FFI 承载查询/清理/键规则的统一语义（详见任务 E）。

---

## 任务 A — 原版音频缓存基线（Android Kotlin）

### A1. 缓存键完整生成规则

**键规则原文**（`app/src/main/java/io/legado/app/model/AudioCacheKey.kt:16-27`）：

```kotlin
fun from(chapter: BookChapter): AudioCacheKey {
    return from(chapter.url, chapter.title)
}

internal fun from(chapterUrl: String, chapterTitle: String): AudioCacheKey {
    val identity = chapterUrl.ifBlank { chapterTitle }
    return AudioCacheKey(MD5Utils.md5Encode16(identity))
}
```

- `md5Encode16`（`app/src/main/java/io/legado/app/utils/MD5Utils.kt:29-33`）：

```kotlin
fun md5Encode16(str: String): String {
    var reStr = md5Encode(str)          // hutool MD5，小写 hex（32 字符）
    reStr = reStr.substring(8, 24)      // 中段 16 字符
    return reStr
}
```

| 要点 | 结论 | 证据 |
|---|---|---|
| 分隔符拼接？ | **无**。identity 只有 chapterUrl，为空白时才整体换成 chapterTitle；不存在 `url + "\|" + title` | AudioCacheKey.kt:21 |
| bookUrl 参与？ | **不参与键**；bookUrl 只决定**书级子目录名** `book_${md5Encode16(bookUrl)}` | AudioCacheManager.kt:210, 228 |
| 编码细节 | MD5 小写 hex 取 `[8..24)`；键对象 init 强校验 16 位 hex（`value.length == 16 && isDigit \|\| in 'a'..'f'`），`parse` 侧 lowercase | AudioCacheKey.kt:8-10, 25-27 |
| 与我方旧键关系 | 完全不同（我方旧键 = `${bookUrl.hashCode}_$i.audio`，下见任务 D） | flutter_legado/lib/src/screens/audio_screen.dart:996 |

### A2. 落盘位置与文件名（AudioCacheManager.kt）

- **目录**：用户 SAF 选定 tree（`AppConfig.audioCacheTreeUri`，`help/config/AppConfig.kt:728-734`，SharedPreferences 键 `audioCacheTreeUri`；选目录交互 `ui/book/audio/AudioPlayActivity.kt:114-137, 254-260`）→ 子目录 `LegadoAudioCache/`（AudioCacheManager.kt:41）→ 书级子目录 `book_${md5Encode16(bookUrl)}/`（AudioCacheManager.kt:226-229）。tree 无效/未选时 `getCacheRoot` 返回 null → 缓存整体不可用（AudioCacheManager.kt:214-221）。
- **文件名**（`AudioCachePolicy.buildFileName`，`help/audio/AudioCachePolicy.kt:67-98`）：

```kotlin
String.format(Locale.ROOT, "%05d_%s_%s_%s_%s.%s",
    chapterIndex, key.value, safeTitle, playUrlHash, revision, extension)
```

  即 `00001_<key16>_<safeTitle≤40字>_<playUrlHash16>_<revision8>.<ext>`：
  - `safeTitle`：`normalizeFileName()`（非法文件名字符替换 `_`，`utils/StringExtensions.kt:162-164`）+ 去控制字符 + trim + 截 40 字符，空则 `chapter`（AudioCachePolicy.kt:79-87）；
  - `playUrlHash = md5Encode16(playUrl)`（AudioCacheManager.kt:167）；
  - `revision = UUID 随机前 8 hex`（AudioCacheManager.kt:162）——同一章可有多代缓存文件并存，读取取 `lastModified` 最新（AudioCacheManager.kt:201-203）；
  - 扩展名：Content-Type 映射 → URL 推断 → 缺省 `audio`；白名单 mp3/m4a/m4b/aac/ogg/oga/opus/wav/flac/webm/amr/3gp（AudioCachePolicy.kt:15-18, 35-65）。
- **解析正则**（读侧识别缓存文件）：`^(\d{5,})_([0-9a-f]{16})_.+_([0-9a-f]{16})_([0-9a-f]{8})\.([a-z0-9]{2,6})$`（AudioCachePolicy.kt:11-13, 100-110）。
- **是否分片**：不分片；**HLS（.m3u8/.m3u）与多段音频（JSON 数组 playUrl）明确拒绝缓存**（AudioCachePolicy.kt:25-33, 45-47）。
- **大小上限**：无文件/总量大小上限。
- **原子写与校验**（AudioCacheManager.kt:132-199, 232-336）：
  1. 先写临时文件 `tmp_{key}_{revision}_{uuid}.part`（:171-173）；
  2. `requireComplete`：size>0 且（能取到时）== Content-Length（AudioCachePolicy.kt:112-114; AudioCacheManager.kt:328-336）；
  3. rename 到正式名（rename 失败降级复制，:232-264）；
  4. 写 `.complete` 标记文件（正式名 + `.complete` 后缀），内容 = `"1\n{md5Encode16(playUrl)}\n{playUrl}"`（`AudioCacheMetadata`，AudioCachePolicy.kt:137-153; AudioCacheManager.kt:266-281）——写后读回校验，失败即删标记抛错；
  5. 删除同 key 其余旧代文件（AudioCacheManager.kt:188）；
  6. 失败回滚：删除已装文件、标记与 staged（:190-197）。
- **读侧有效性判定** = 文件 size>0 **且** 存在同名 `.complete` 标记（`committedCacheFiles`，AudioCacheManager.kt:358-373）；**无时间过期概念**。孤儿清理：1 小时前的未提交文件（`STALE_PARTIAL_AGE_MILLIS = 60min`，AudioCacheManager.kt:43, 302-314）。
- **并发**：16 把 Mutex 按 `(bookUrl.hashCode, key.hashCode)` 分桶锁章（AudioCacheManager.kt:44, 414-416）。

### A3. 缓存决策条件（AudioCachePolicy.kt）

| 条件 | 内容 | 证据 |
|---|---|---|
| 拒绝：空 playUrl | `playUrl.isBlank()` 抛 IllegalStateException | AudioCachePolicy.kt:26 |
| 拒绝：多段音频 | playUrl 是 JSON 数组 | AudioCachePolicy.kt:27-29 |
| 拒绝：HLS | URL 路径以 .m3u8/.m3u 结尾（含重定向后 finalUrl） | AudioCachePolicy.kt:30-32, 116-119 |
| 拒绝：分卷章 | `chapter.isVolume` | AudioCacheManager.kt:115 |
| 有「缓存开关」？ | **无**（不存在 `setCache` 之类检查）；范围缓存完全由用户显式发起 | 全文核对 |
| 大小上限/网络类型限制 | **无** | 全文核对 |

### A4. AudioCacheService：前台服务、纯预下载、与播放链解耦

- **前台服务**（非 WorkManager/Job）：`BaseService` + `startForeground(NotificationId.AudioCacheService, ...)`（`service/AudioCacheService.kt:125-127`），通知渠道 `AppConst.channelIdDownload`，带「停止」动作（:86-98），`START_NOT_STICKY`（:112）。
- **任务模型**：`ArrayDeque<CacheTask>` 队列 + 单 worker 协程（`lifecycleScope.launch(IO)`，:145-152, 154-185）；入口静态 `start(context, bookUrl, start, end)`（:47-63）由 AudioPlayActivity「缓存范围」菜单触发（AudioPlayActivity.kt:281-311）。
- **预下载，不是播放顺带写**：`AudioCacheManager.cacheChapter` 的调用方**全仓只有 AudioCacheService.kt:217**（已 grep 全树核实；AudioPlay 播放链只有 `getCachedAudio`/`getCachedUriString`/`removeCachedChapter` 三个读删调用，AudioPlay.kt:389/508/575）。
- **执行序列**（AudioCacheService.kt:187-234）：查目录可用 → 取书/书源（非音频书直接返回）→ 目录缺失时先拉目录入库（`ensureChapterList`，:236-257）→ 归一化区间（AudioCachePolicy.normalizeRange）→ 预读 `listCachedChapterKeys` 去重 → 逐章 `cacheChapter` → 成功后 `postEvent(AUDIO_CACHE_CHANGED, AudioCacheStateChanged(...))`（:220-225）。
- **与 AudioPlay 取址链耦合度**：零调用耦合，仅通过 `AUDIO_CACHE_CHANGED` 事件与目录页徽标通信（事件载荷 `model/AudioCacheStateChanged.kt:3-8`：bookUrl/key/cached/treeUri）。

### A5. AudioPlay 取址链中缓存的优先级位置（model/AudioPlay.kt）

`loadPlayUrl()`（AudioPlay.kt:365-437）完整顺序：

1. `addLoading(index)` 防重入（:367）；
2. 卷章直接 `skipTo(index+1)`（:376-380）；
3. `val skipCache = consumeSkipCacheOnce(cacheKey)`（:387）——「跳过缓存一次」集合（播放失败重试时置入）；
4. **第一步就查缓存**：`Coroutine.async { if (skipCache) null else AudioCacheManager.getCachedAudio(cacheTreeUri, book.bookUrl, chapter) }`（:388-393）；
5. **命中**（:399-413）：`durPlayUrl = cachedAudio.playUrl ?: chapter.resourceUrl`（playUrl 来自 `.complete` 标记元数据）、`durMediaUrl = cachedAudio.mediaUri`（SAF 文件 URI）→ `upPlayUrl()` 直接播放。**完全跳过网络请求**（WebBook.getContent 不会被调用），且 `playUrlPreloadStore.invalidate` 作废在途网络预取；
6. **未命中**（:414-415）：`loadRemotePlayUrl` → 先消费下一章播放 URL 预取缓存（:446-456）→ 否则 `WebBook.getContent` 网络（:458）；
7. **缓存读失败**（onError，:420-428）：同样回落网络取址；
8. **下一章预取**（`preloadNextPlayUrl`，:501-543）：先查下一章缓存（`getCachedUriString`，:507-512），**缓存命中则取消网络预取**（命中即返回，:519-522）——保证下一章自然走缓存命中路径；
9. **缓存损坏的运行时处理**（`retryAfterCachedPlaybackError`，:545-603）：播放出错且当前正在用缓存（`playingCacheKey` 非空）→ 删除该缓存文件（`removeCachedChapter`）→ `skipCacheOnceKeys.add`（本次强制直连）→ 重新 `loadPlayUrl()` 走网络；并广播 `AUDIO_CACHE_CHANGED(cached=false)` 让徽标熄灭。
10. **过期**：无过期逻辑，`.complete` + size 校验是唯一有效性判据（见 A2）。

### A6. BookCacheInfo 的字段与清理时机

**结论：`BookCacheInfo` 与音频缓存无关**——它是**文本章节缓存清理**用的 SQL 投影：

- 实体（`data/entities/BookCacheInfo.kt:8-14`）：`bookUrl / name / origin / originName / type`；`getFolderName()` = 书名去非法字符取前 9 字符 + `md5Encode16(bookUrl)`（:21-25）——这是**文本缓存目录名**的算法。
- 来源：`BookDao.getCacheCleanupBooks()`：`@Query("SELECT bookUrl, name, origin, originName, type FROM books")`（`data/dao/BookDao.kt:153-155`）——**不是独立表，无写入时机**，每次清理实时从 books 表投影。
- 消费方：`BookHelp.clearInvalidCache()`（`help/book/BookHelp.kt:151-184`）：清「已删除书」的文本缓存目录（books 表里不存在的目录名一律删除）与 epub 解压缓存；调用时机为应用启动后的维护链路。
- **音频缓存自身的清理时机**（与 BookCacheInfo 无关）：① 菜单「清当前章缓存」`clearCurrentAudioCache`（AudioPlayActivity.kt:237, 318-346，删当前章 + 事件熄徽标）；② 播放中坏缓存自动删除（AudioPlay.kt:545-603）；③ 未提交残片 1 小时后清理（AudioCacheManager.kt:302-314）。**无**「缓存满自动清理」「切换书清理」「设置变更清理」。

### A7. AudioPlayActivity / 目录页的缓存徽标

- AudioPlayActivity 本体无徽标（目录复用全局 `ChapterListFragment`，经 `TocActivityResult` 跳转，AudioPlayActivity.kt:99-107）。
- **数据来源**：目录页打开时后台 `AudioCacheManager.listCachedChapterKeys(treeUri, bookUrl)` 列目录解析出 `Set<AudioCacheKey>`，灌入 `adapter.audioCacheKeys`（`ui/book/toc/ChapterListFragment.kt:154-184`，book.isAudio 分支；treeUri 变更时循环重读，:156-172）。
- **显示条件**（`ui/book/toc/ChapterListAdapter.kt:192-198`）：

```kotlin
val cached = callback.isLocalBook || isVolume ||
        if (callback.isAudioBook) {
            !callback.isAudioCacheStateReady ||
                    audioCacheKeys.contains(AudioCacheKey.from(chapter))
        } else {
            cacheFileNames.contains(chapter.getFileName())
        }
```

  即音频书按 key 命中点亮；`isAudioCacheStateReady == false`（列表尚未读完）时**全亮**（避免初始全暗闪烁，ChapterListAdapter.kt:194, 358-360, ChapterListFragment.kt:57, 123, 179）。
- **刷新时机**：① 目录页重进/重载（全量重扫，ChapterListFragment.kt:154-184）；② `AUDIO_CACHE_CHANGED` 事件增量增删 key 并 `notifyItemChanged` 可见行（:196-208）；事件带 `treeUri`，与当前 `AppConfig.audioCacheTreeUri` 不一致时忽略（:199，防止换目录后旧事件错刷）。

---

## 任务 B — 我方现状盘点（Rust + Dart）

### B1. Rust FFI 音频导出现状

`rust/legado-ffi/src/api/` 下与音频相关的导出**只有** `audio_api.rs`（FFI 导出面 `rust/legado-ffi/src/ffi.rs:2027-2049, 2622-2633`）：

| 导出 | 实现 | 存储 | 证据 |
|---|---|---|---|
| `audio_get_progress` | `get_audio_progress` | caches 表键 `audio_progress:{bookUrl}:{chapterIndex}` | audio_api.rs:26, 49-58 |
| `audio_save_progress` | `save_audio_progress` | 同上，永不过期 | audio_api.rs:61-72 |
| `audio_get_chapter_media` | `get_audio_chapter_media` | 取址链：卷章短路 → DB `cached_chapters` 文本命中（`fromCache=true`）→ 无书源回退 resourceUrl/chapterUrl → WebBook.getContent → **把 playUrl 文本写回 `cached_chapters`** | audio_api.rs:122-260 |
| `audio_with_play_mode` | `with_audio_play_mode` | readConfig JSON 变换 | audio_api.rs:74-80 |
| `audio_resolve_play_book` | `resolve_audio_play_book` | DB books 查询 | audio_api.rs:83-107 |

**没有任何音频「文件」缓存 FFI**（无下载、无落盘、无查询、无清理）。我方现存的音频「缓存」仅是 **DB 里播放 URL 的文本缓存**（与阅读正文共用 `cached_chapters` 表），不是原版那种音频二进制文件缓存。

**孤儿模块警告**：`rust/legado-core/src/audio_cache.rs`（`legado-core/src/lib.rs:26` 导出 `pub mod audio_cache;`）自称「移植自 Kotlin AudioCacheManager + Policy + Service」，但全 workspace **零调用方**（grep `legado-ffi/src`、各 Cargo.toml 无引用），且三处与原版语义冲突：① entries 是内存 HashMap，**重启即丢索引、不持久**（audio_cache.rs:79, 91）；② 文件键 = `md5(chapter_url)` **全长 32 hex**（audio_cache.rs:221-224），≠ 原版 `md5Encode16` 中段 16 字符；③ 策略（500MB/30 天/1000 条 LRU，audio_cache.rs:23-44）为自创，原版无此策略。实施时须裁决「重写对齐」还是「删除重来」（任务 F-10）。

Dart 侧封装签名（`flutter_legado/lib/src/services/rust_api_media_format.part.dart:411-452`）：

```dart
Future<Map<String, dynamic>> getAudioChapterMedia(String bookUrl, int chapterIndex)  // bridge.audioGetChapterMedia → jsonDecode
Future<Map<String, dynamic>?> getAudioProgress(String bookUrl, int chapterIndex)      // bridge.audioGetProgress → {'position': int, 'chapterIndex': int}
Future<void> saveAudioProgress(String bookUrl, int chapterIndex, int positionMs)      // bridge.audioSaveProgress
```

### B2. 播放链取址顺序与缓存插桩点（audio_notifier.dart）

`_playAudioBookStream`（`flutter_legado/lib/src/providers/audio/audio_notifier.dart:472-544`）：

1. `state = loading`，`token = ++_playToken`（:473-474）；
2. 循环：`final media = await _api.getAudioChapterMedia(state.bookUrl, index)`（:478）——**取址全部依赖该 FFI，其内部就是 B1 的「DB 文本缓存→网络」链**；
3. 卷章 / `mediaUrl` 空 → 跳下一章或报错（:480-495）；
4. 更新 state（mediaUrl/lyric/playing，:496-504）；
5. **`await _streamPlayer.playUrl(mediaUrl, speed, tag: (bookUrl, chapterIndex))`**（:507-511）——`StreamAudioPlayer.playUrl` 走 `VideoPlayerController.networkUrl`（`services/stream_audio_player.dart:59-72`），纯网络流；
6. `_syncMediaSession` → `getAudioProgress` 恢复进度（>1500ms 才 seek，含近章尾判零）→ 片头跳过（:513-536）。

**缓存插桩点（明确答案）**：第 4 步与第 5 步之间——即 `mediaUrl` 非空判定完成之后（:481-495）、`_streamPlayer.playUrl` 之前（:507）。命中缓存时改为 `await _streamPlayer.playLocalFile(cachedPath, speed, tag)`（该 API 已存在且被 TTS 链使用，stream_audio_player.dart:80-97，支持绝对路径与 `file://` URI）；tag 与进度恢复链（P1 竞态修复，:505-506 注释、:549-553 归属校验）原样复用。更深一层（更对齐原版）：把「优先读缓存」下沉到 Rust `get_audio_chapter_media` 内部——命中时 `mediaUrl` 直接返回本地路径（原版 `durMediaUrl = cachedAudio.mediaUri` 即本地 URI，AudioPlay.kt:407），Dart 播放链零改动（播放器侧需识别本地路径自动分流 `playLocalFile`，待验证 `video_player` 对 `content://` URI 的支持，若不支持则 SAF 文件须先落地临时文件或走 `openFileDescriptor`）。

### B3. 旧缓存键的写入方/读取方与徽标 UI

- **唯一引用点** = `flutter_legado/lib/src/screens/audio_screen.dart:996`（`final name = '${bookUrl.hashCode}_$i.audio';`）。全仓 grep（`hashCode}_$`、`audio_cache`、`.audio` 后缀）仅此一处。
- **写入方**：`_cacheAudioRange`（audio_screen.dart:972-1018）——菜单「缓存范围」（菜单项 :285-286，入口 :789）触发：`getAudioChapterMedia` 取 playUrl → `bridgeHttpGetBytes` 全量下载 → **有 treeUri 时 `saf.writeFileBytes` 写 tree 根部**（:997-1004，注意：无 `LegadoAudioCache/`、无书级子目录），否则写 `getApplicationSupportDirectory()/audio_cache/`（:979-985）；无 Content-Type/大小校验、无完整标记、异常静默吞（:1012）。
- **读取方：不存在**。`_playAudioBookStream` 与任何其他代码都不读这两种路径的文件 → **旧缓存是孤儿写**（写了永远没人读，纯占空间）。
- **徽标 UI：不存在**。听书屏 `_buildChapterList`（audio_screen.dart:690-715）leading 只有「当前章播放图标 / 序号」，无缓存态；菜单也**没有**「清当前章缓存」项（audio_screen.dart:266 注释里提到对标原版，但 :274-298 实际菜单无此项）。
- 附属：treeUri 配置键 `kAudioCacheTreeUriKey = 'audioCacheTreeUri'`（`utils/audio_skip_policy.dart:18`，经 `setConfig` 存 DB）。

### B4. 我方现有「缓存」概念盘点（可复用性判断）

| 概念 | 契约 | 键 | 落盘位置 | 访问模式 | 实现层 | 证据 |
|---|---|---|---|---|---|---|
| 图片磁盘缓存 | §2.46 | 书目录 `sanitize(bookUrl)+_{md5_8(bookUrl)}` + 文件 `md5_16(url).{suffix}` | Dart 注入的应用私有缓存目录 `image_cache/`（未注入回落 temp） | 读写（Rust `std::fs` 直写直读，失败静默降级） | Rust | `rust/legado-ffi/src/api/image_cache_api.rs:66-214`；契约 docs/API_CONTRACT.md:863-873 |
| 单章文本缓存 | §2.16 | DB `cached_chapters` 行（book_url + chapter_index/chapter_url，读侧做 URL 一致性校验 [B-5]） | SQLite | 读写（Rust DB） | Rust | `rust/legado-ffi/src/api/cache_api.rs:70-116` |
| 目录缓存态 | §2.43 | 同上表 SELECT 投影（url→wordCount） | SQLite（只读） | 只读 | Rust | cache_api.rs:123-204 |
| 批量下载任务 | §2.43.7 | 进程内任务表 + 落库恢复 | DB/内存 | 读写 | Rust | `rust/legado-ffi/src/api/cache_download_api.rs:177-404` |
| JS 缓存 / TTS 音频缓存 | §1.6.1 / §2.42 | `set_cache_dir` / `ttsSetCacheDir` 注入目录；TTS 文件 MD5 命名 | 应用私有目录 | 读写 | Rust | `rust/legado-ffi/src/api/tts_speak_api.rs:28-46` |

**共性**：所有既有缓存的基础设施都在 Rust 侧（`with_database` 或 `std::fs`），Dart 只经 BookApi 调用；且 **Rust 侧写二进制音频文件已有在产先例**（TTS 合成管线：HTTP 拉流 → MD5 命名落盘 → 返回本地路径，tts_speak_api.rs:5-60）。
**对 B1 的含义**：若缓存落应用私有目录，可完整复用 `image_cache` 的「目录注入 + fs 读写 + 静默降级」模式与 `tts_speak` 的「流式下载落盘」模式；若落 SAF 目录，Rust 无能为力（content:// URI 只有 Android 侧能解），必须 Dart/Kotlin 写。

### B5. SAF / 存储通道现状

- **`StorageBridge.kt`（`legado/storage` MethodChannel，`flutter_legado/android/app/src/main/kotlin/io/legado/flutter/StorageBridge.kt:43-217`）**：**仅一个方法** `saveImageToDownloads`——MediaStore 直写 `Download/legado/`（API 29+），整段 `byte[]` 写 + 写后读回校验（SIZE 精确相等 + 首 8 字节比对，防 MuMu 幻影写入，:27-33, 173-204）。**非 SAF tree**、无读、无列表、无删除、无流式。
- **第三方 `saf` 插件 2.1.0**（`flutter_legado/pubspec.yaml:35`，`package:saf/saf.dart`）：听书屏与书签导出在用（audio_screen.dart:6, 987；bookmark_export.dart:6, 105-112）。能力面齐全（`~/.pub/Cache/hosted/pub.dev/saf-2.1.0/lib/src/v2/saf.dart:32-216`）：`pickDirectory / list / stat / child / mkdirp / delete / rename / copyTo / moveTo / readFileBytes / readFileStream / writeFileBytes / writeFileStream / openFileDescriptor / withFileDescriptor`。→ **SAF 流式读写大文件、列目录、删除均可行**，无需新增 Kotlin 桥。
- **Rust 侧文件 IO 能力**：`std::fs` 直接可用且已有两处在产使用（image_cache、tts cache）；`legado-db` 是 SQLite 仓储层（可存缓存索引）；`legado-core` 有上述孤儿 `audio_cache.rs`。Rust **没有**任何 SAF/ContentResolver 能力（全 workspace 无 JNI/Android 依赖路径）。

---

## 任务 C — API_CONTRACT 影响面与契约条文拟稿

### C0. 契约结构与自动校验机制（先读结论）

- 结构：§1 总则（含 §1.6.1 进程注入型 FFI、§1.7 命名等价表）→ §2 方法清单（**43 个方法模块 §2.1–§2.46，编号跳过 2.24/2.27**，docs/API_CONTRACT.md:173-177）→ §3 UI 轨需求登记区 → 附录（:979-1026）。
- `test/unit/api_contract_test.dart` 程序化校验五件事（flutter_legado/test/unit/api_contract_test.dart:1-12, 146-263）：① BookApi ⊆ RustApi 且 ⊆ MockBookApi（:152-168）；② RustApi 额外公共方法钉死 = `{toString, refreshReadBookConfig}`（:170-182）；③ 每个 BookApi 方法都在 §2.x 行或 §1.7 等价对登记（:184-200）；④ **§2.x 每节标题声明数 == 表格实际行数**（:202-209）；⑤ **附录行与 §2.x 节标题双射 + 合计行 = 各行之和 + 文档声明 BookApi 总数 == book_api.dart 程序计数**（:211-263）。
- **现行计数（以文档现值为准；任务书里的 283/271/3 是 2026-10-03 cbz 批 D 之前的旧口径）**：BookApi **284**（:176，cbz 批 D 已把 `cbzReadPage` 封装进 BookApi，book_api.dart:1010 已核实）；附录合计 **287**（:1026）；与 BookApi 同名 **272**（:1032）；§1.7 等价对 8 + 登录 4（:1029-1030）；**纯 FFI 2**（`chapterPayAction`/`rssUpdateSource`，:1031）。

### C1. 拟新增 FFI 方法清单（按既有 §2.x 行格式拟稿，**仅进本报告，不改契约**）

建议编号：**新增 §2.47「音频章节文件缓存」（N=4 个方法）**，模块总数 43→44。理由：① 存储型缓存独立成节有 §2.46「图片磁盘缓存」直接先例（语义聚类：取址/进度归 §2.26，文件缓存归 §2.47）；② 不污染 §2.26 的 4 方法计数与既有登记行；③ 附录/总则仅加一行改一数，测试自动校验可全量接管。备选方案（并入 §2.26 音频播放 4→8）同样合法，差异仅在模块行归属。

拟稿条文（格式对齐 §2.46，docs/API_CONTRACT.md:863-873）：

> ### 2.47 音频章节文件缓存（audio_cache FFI，4 个方法）
>
> [B1 | 2026-10-03] 加法式新增（不改既有签名/行为）：音频章节**音频文件**的磁盘缓存查询/列出/清理/登记，对齐原版 `AudioCacheManager`（listCachedChapterKeys / removeCachedChapter / cacheChapter）+ `AudioCacheKey`（`md5Encode16(chapterUrl.ifBlank{title})`）+ `AudioCachePolicy.buildFileName` 五段式文件名 + `.complete` 标记语义。写入链路（预下载/播放顺带）与存储通道（SAF/私有目录）另行冻结，不在本节方法面内。
>
> | 方法 | 入参 | 返回 | 说明 |
> |------|------|------|------|
> | `audioCacheQuery(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<bool>` | 查询某章音频是否已缓存（存在有效 `.complete` 文件）。**只读**；无效 treeUri / 目录不存在返回 false（静默降级，不抛异常，对齐原版 getCachedAudio runCatching 语义） |
> | `audioCacheList(String bookUrl)` | bookUrl | `Future<String>` | 列出某书已缓存章节，JSON 数组 `[{"chapterIndex":1,"title":"...","key":"0123abcd...","fileName":"00001_...mp3","sizeBytes":123}]`（按 chapterIndex 升序）。**只读**；解析失败的文件名跳过（对齐原版 parseFileName） |
> | `audioCacheClearChapter(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<int>` | 清理某章缓存（音频文件 + `.complete` 标记 + 残片），返回删除的文件数；章不存在/文件不存在为 no-op 成功返回 0。**幂等**、有写（删除）；成功后 UI 层自行熄灭徽标（对齐原版 AUDIO_CACHE_CHANGED(cached=false)） |
> | `audioCacheClearBook(String bookUrl)` | bookUrl | `Future<int>` | 清理某书整本音频缓存（`LegadoAudioCache/book_{md5_16(bookUrl)}/` 整目录或私有目录等价物），返回删除文件数；无缓存返回 0。**幂等**、有写（删除） |

（可选第 5 方法 `audioCacheFileName(String bookUrl, int chapterIndex) → Future<String>`：返回按原版规则的规范文件名，供 Dart SAF 写入侧与 Rust 索引保持单一实现；若采纳任务 E 方案二则必选，见下。）

### C2. 缓存写入是否需要新 FFI？

**分通道裁决**：

| 写入通道 | 是否需要新写入 FFI | 说明 |
|---|---|---|
| A. Android SAF tree（用户目录，原版布局） | **不需要**（推荐） | Dart `saf` 插件 `writeFileStream`/`writeFileBytes` 已够（B5）；下载用既有 `httpGetBytes`（§2.20）或 Rust 侧提供 `audioCacheDownloadStream`（可选，见下）；**文件名构造/`.complete` 内容必须与 Rust 索引同源**——用 `audioCacheFileName` FFI 或测试锁死双实现 |
| B. 应用私有目录（Windows/桌面 或 Android 无 SAF 回退） | **需要**（推荐形态） | 形态一：`audioCacheSave({bookUrl, chapterIndex, bytesBase64})` 复用 `saveImageCache`（§2.46）模式——**不推荐**：音频数十 MB，base64 膨胀 4/3 + 全量内存穿 FFI。形态二（**推荐**）：`audioCacheDownload(bookUrl, chapterIndex) → Future<bool>`——Rust 端到端（内部 get_audio_chapter_media 取 playUrl → legado-net 流式拉取 → staged+rename+`.complete` 两段式落盘），零 base64、崩溃一致性与原版同构（先例 tts_speak 流式管线） |
| C. 播放读缓存 | **不需要新 FFI**（推荐） | 扩展既有 `getAudioChapterMedia`（§2.26）行为：缓存命中时 `mediaUrl` 返回本地路径、`fromCache=true`——**行为变更需在契约 §2.26 行内补记**，签名不变，非破坏性 |

**结论：只读查询/清理面必须新增 FFI（C1 的 4 个方法没有既有替代——`getCachedChapter` 是 DB 文本缓存语义，与文件缓存无关，不可复用，§2.16/§2.41 行为已冻结）；写入面按通道可选（SAF 通道免新增、私有目录通道推荐 `audioCacheDownload`）。**

### C3. 编号归属

建议 **§2.47**（新节，理由见 C1）；编号 2.24/2.27 维持跳过不动；2.47 > 2.46 无冲突。

### C4. 计数变化与需同步修改的位置

设最终冻结 N=4 个方法、全部封装进 BookApi：

| 位置 | 现值 | 变更后 | 证据（docs/API_CONTRACT.md） |
|---|---|---|---|
| §2.47 新节标题 | 无 | 「### 2.47 音频章节文件缓存（4 个方法）」 | 新增 |
| 总则模块数（:175） | 43 个方法模块 | **44** | :175 |
| BookApi 总数（:176） | 284 | **288**（封装进 BookApi 时） | :176 |
| 附录新增行 | 无 | 「47 \| 音频章节文件缓存 \| 4」 | :981-1025 |
| 附录合计（:1026） | 287 | **291** | :1026 |
| 口径说明（:1028-1033） | 同名 272 / 纯 FFI 2 | 同名 **276**（+4）；登记新日期与批次号；纯 FFI 维持 2 | :1028-1033 |
| MockBookApi | — | 必须补 4 个假实现（测试 ①BookApi⊆Mock 会失败否则，api_contract_test.dart:161-167） | — |
| 若走纯 FFI（不封装 BookApi） | — | BookApi 284 不变；口径登记「纯 FFI 2→6」；参考 cbz 批 B 先例（:11） | :11, :1029-1031 |

`api_contract_test.dart` 自动校验并强制同步的数字：§2.47 节标题声明数、附录双射与合计、BookApi 程序计数——文档漏改任一处即 CI 失败（:202-263）。**不需要**改 §1.6.1 注入表与 §1.7 等价表（新方法按同名登记，不走等价对）。

### C5. B1 是否必须改 FFI 边界？——**是**

- 「播放优先读缓存」理论上可纯 Dart 实现（SAF list + 文件名解析 + playLocalFile），但**违反项目红线**「UI 层不含业务逻辑、数据经 Rust Bridge 获取」（AGENTS.md:49）——缓存键规则、文件名五段式、有效性判定是业务规则；且桌面端（Windows 主构建目标）无 SAF，纯 Dart 方案直接不可用。
- 查询某章是否缓存 / 列出 / 清理没有任何既有 FFI 可复用（`getCachedChapter`/`listCachedChapters` 是 DB 文本缓存语义，键与介质都不同，硬复用会污染 §2.16 冻结语义）。
- **最小 FFI 变更集** = C1 的 4 个查询/清理方法 + （走私有目录写入时）1 个 `audioCacheDownload` + （走 SAF 写入时可选）1 个 `audioCacheFileName`；播放读缓存复用 §2.26 行为扩展（契约行内补记）。全部为加法式，无破坏性变更。

---

## 任务 D — 旧缓存兼容与回落迁移方案

### D1. 新旧键如何区分？

| | 旧键（我方 2.0.39+41 批） | 新键（原版规则） |
|---|---|---|
| 文件名 | `${bookUrl.hashCode}_$i.audio`（两段式，`_` 分隔） | `00001_<key16>_<title>_<hash16>_<rev8>.<ext>`（五段式 + 白名单扩展名） |
| 目录 | `audio_cache/`（app 私有）或 SAF tree **根部**（无子目录） | `LegadoAudioCache/book_{md5_16(bookUrl)}/` |
| 可判别性 | **文件名形态本身就是版本标记**：旧键名不匹配原版解析正则（第二段非 16 hex，AudioCachePolicy.kt:11-13），新键名不会被旧逻辑读（旧逻辑本就无读取方） | 同左 |

**结论：不需要额外语义版本标记，按目录布局 + 文件名正则即可互斥识别。** 但注意：旧键里的 `bookUrl.hashCode` 是 **Dart `String.hashCode`**——同一 Flutter 引擎内确定，但 Dart 规范不保证跨引擎版本稳定，且 hash 不可逆（文件名里无 bookUrl 明文），只能「逐书计算 hashCode 后比对目录内文件名」归册。

### D2. 回落与迁移：两种取法

| 取法 | 流程 | 优点 | 缺点 |
|---|---|---|---|
| A. 只读不迁（**推荐**） | 新键 miss → 计算旧键路径 → 读到即播（不重命名/不复制） | 零写风险；SAF 只需读权限；旧数据可随時废弃，无「洗白」 | 播放链永久双读路径；旧数据可信度低（见 D3）却享受与可信缓存同等地位 |
| B. 读后迁移 | 旧键命中 → 复制/重命名到新键目录 → 走统一新链 | 数据链收敛单一 | ① 需要旧目录写权限；② 把不可信数据永久固化为「已验证缓存」（错章风险洗白）；③ 与原版目录互通时还会把两段式异类文件写进原版布局，污染互操作 |

**推荐 A**，且默认建议进一步收紧为「旧键数据默认**不读**，仅在设置中提供一次性『尝试恢复旧缓存』开关」（见任务 F-3），理由是 D3 的错位风险无法校验、而旧数据本就是从没被消费过的孤儿数据——「恢复」它的实际价值需要用户确认（用户当年缓存的可能本就是错误/陈旧内容）。

### D3. 风险量化：hashCode 碰撞与章节下标错位

| 风险 | 量化 | 后果 | 缓解 |
|---|---|---|---|
| `bookUrl.hashCode` 碰撞（不同书同名缓存文件） | Dart String.hashCode 32 位；书架 N 本书的碰撞对概率 ≈ N(N-1)/2 / 2³²。N=200 → 约 4.7×10⁻⁶；N=1000 → 约 1.2×10⁻⁴ | 两本书缓存互相覆盖（写侧 overwrite:true 已在覆盖，audio_screen.dart:1003） | 单用户视角极低；但**无法事后检测**（文件无归属元数据） |
| **章节下标 `i` 错位（主要风险）** | TOC 重排/换源/书源插删集数后 `index ≠ 同一章`；音频书章节序变动是常态（每次目录刷新都可能发生）。错位概率 ≈ 目录变动比例，**远高于 hash 碰撞** | 把别的章节音频当当前章播放——用户可感知的「张冠李戴」 | 原版靠 `md5(chapterUrl)` 内容寻址天然规避（URL 变则 miss）。旧键无元数据、文件即裸字节，**没有任何事后校验手段**；最接近的弱校验 = 播放前 HTTP HEAD 比对 Content-Length（弱信号，同长度不等于同内容） |

**缓解建议**：旧键命中视为「低可信数据」——只读不迁（D2-A）、不点亮目录徽标、播放出错不重试旧键直接走网络；并在方案文档明确告知用户「旧缓存可能错章」。

### D4. 旧数据实际位置与「跨应用恢复」的真相（方案分歧点，已查清）

| 数据 | 实际位置 | 我方可直读？ |
|---|---|---|
| 原版音频缓存 | **用户选定的 SAF tree** 下 `LegadoAudioCache/book_{md5_16(bookUrl)}/`（不存在 app 私有默认路径：`AppConfig.audioCacheTreeUri` 未设置时缓存整体不可用，AudioCacheManager.kt:214-221; AudioPlayActivity.kt:262-279） | **不能免授权直读**；但用户在我方 app 内重新 pickDirectory 授权**同一目录**后可完整读写（SAF 授权按 app+URI 授予，不继承原版授权）。若该目录在共享存储，MediaStore 只读枚举理论上可行但无法按 tree 结构稳定解析——不推荐 |
| 我方旧缓存（SAF 分支） | 用户 tree **根部** `{hash}_{i}.audio`（audio_screen.dart:997-1004） | 我方自己授权后可读 |
| 我方旧缓存（回退分支） | `getApplicationSupportDirectory()/audio_cache/`（app 私有，audio_screen.dart:979-985） | 我方可读；**其他应用（含原版）不可读**；用户想把它给原版也做不到（除非 root/备份提取） |

**明确结论（分歧点裁决材料）**：
1. 「按原版数据恢复」**不可能**解释为「跨应用直读原版私有目录」——原版根本没有私有目录缓存可读。
2. 可行的解释 = **两条同时实现**：① 按**原版键规则**解析（`md5Encode16(chapterUrl)` + 五段式文件名 + `.complete` 校验，A1/A2）；② 读**原版目录**——用户在我方 app 的「缓存目录」里重新选择原版当年用的同一 SAF 目录（重新授权）。
3. 只做 ①：只能恢复我方自己按新规则写的数据（原版数据读不到）；只做 ②：无法解析原版文件名。两者缺一不可。
4. 我方旧 `hash_i.audio` 数据与「原版数据恢复」**无关**（另一套命名、无元数据、本就无人读取），是否值得恢复见 F-3 裁决。

---

## 任务 E — SAF 写入归属分析

### E1/E2. 对比与事实

| 维度 | Rust 侧写（应用私有目录） | Dart 经 `saf` 插件写（用户 SAF tree） |
|---|---|---|
| 线程模型 | Rust 阻塞线程池/异步，FFI 立即返回（webbook* 同型，契约 §2.17 注） | MethodChannel 平台线程 + Dart await；`writeFileStream` 分块穿 codec |
| 大文件流式 | 原生流（reqwest 流 → `std::io::copy`；TTS 管线同型先例 tts_speak_api.rs:5-60） | 支持：`readFileStream`/`writeFileStream`（saf-2.1.0 v2/saf.dart:287, :133），`withFileDescriptor` 可拿 raw fd（:215-216） |
| 路径权限 | 私有目录免授权 | 需用户 pickDirectory 持久授权（每 app 独立） |
| 崩溃一致性 | 可完整复刻原版两段式（staged `.part` → rename → `.complete`） | SAF `renameTo` 支持（saf.dart:117）但 provider 实现质量参差；两段式可做但多一次 provider 往返 |
| 跨应用互通（原版互读/换机） | 否（私有） | **是**（用户目录，原版可写同目录、换机可整目录拷贝） |
| 现有设施 | image_cache 注入目录 + fs；tts 流式下载先例 | `saf` 插件齐全；`StorageBridge` 无 SAF 方法（仅 MediaStore 整段写，帮不上音频缓存） |

**MuMu/真机 SAF 流式写大文件**：saf 2.1.0 提供 `writeFileStream` 与 `openFileDescriptor`（'w'/'rw'），协议层面支持流式；但 MuMu ROM 对 MediaStore 有幻影写入前科（StorageBridge.kt:27-33 证据）——SAF provider 同样建议**写后 stat(size) 读回校验**（原版也做了 `requireComplete` size 校验，AudioCacheManager.kt:328-336）。

### E3. 推荐

**推荐「双通道、Android 优先 SAF」**：

1. **Android：缓存目录 = 用户 SAF tree（对齐原版 `audioCacheTreeUri` 交互），写入走 Dart `saf` 插件**（`writeFileStream` 流式 + stat 校验 + `.complete` 标记）。核心理由：用户已明确的硬需求「按原版数据恢复」要求我方与原版**共读同一目录**——我方新写数据落原版布局（`LegadoAudioCache/book_{md5_16}/`）后，与原版历史缓存天然融合，迁移成本为零；Rust 无法访问 content://，SAF 通道只能 Dart/Kotlin 写。
2. **Windows/桌面（无 SAF）：Rust 写私有目录**（复刻原版两段式，先例 image_cache + tts），保证桌面端 B1 不缺席。
3. **键规则/文件名构造单一实现**：键计算、五段式文件名、`.complete` 内容放 Rust 并经 FFI 暴露（`audioCacheFileName`，C1 可选第 5 方法），Dart SAF 写入侧调用之，避免双实现漂移；若用户拒绝加这个方法，则 Dart 复制实现并以单元测试锁死一致性（维护成本次之）。
4. **索引查询/清理统一走 FFI**（§2.47 四方法）：Rust 内部对私有目录直查文件系统；对 SAF 目录由 Dart list 后调用 `audioCacheFileName` 逐章比对（或 Dart 直解 + 测试锁定）——保证播放链「是否已缓存」判定在两端语义一致。

**若必须二选一**（用户简化裁决）：选 **Dart(SAF) 写入 + FFI 查询/清理**。理由：「原版数据互通」是本任务存在的前提；Rust 私有目录数据原版读不到、换机迁移不走 SAF 备份，作为唯一通道会把 B1 做成孤岛。

---

## 任务 F — 风险与待用户裁决清单

| # | 裁决点 | 推荐选项 | 理由 | 影响面 |
|---|---|---|---|---|
| F-1 | **缓存默认开关**：播放时是否「顺带写缓存」？ | 不自动写；仅菜单「缓存范围」预下载（对齐原版：播放链只读，cacheChapter 仅服务调用，A4） | 对齐原版行为；避免用户流量意外消耗 | 播放链、契约写入面大小 |
| F-2 | **缓存目录交互**：无 SAF tree 时强制先选目录（原版）还是回退应用私有目录（我方现状）？ | Android 对齐原版强制选择；桌面用私有目录 | 对齐原版 + 保证数据落在用户可备份的位置 | audio_screen 菜单流、写入通道 |
| F-3 | **我方旧 `hash_i.audio` 孤儿数据**：A 只读不迁 / B 读后迁移 / C 废弃不读 | C（默认不读）；若用户坚持恢复则 A + 「不点亮徽标 + 出错即弃」 | 旧数据无元数据、有错章风险、从未被消费过；「恢复」价值存疑 | D2/D3、播放链插桩复杂度 |
| F-4 | **「按原版数据恢复」交互**：是否引导用户重新授权原版目录 + 在 UI 明示「将读取原版缓存」？ | 是（缓存目录选择文案区分「新建目录/恢复原版数据」） | D4 结论：恢复必须重新授权；不引导用户会以为自动恢复 | audio_screen 缓存目录菜单、文案 |
| F-5 | **缓存大小上限/自动清理**：原版无；孤儿 Rust 模块有 500MB/30 天/1000 条 LRU | V1 不引入（对齐原版），列后续增强 | 对齐原版；自创策略属「未授权新功能」风险（AGENTS.md:46） | 是否复活孤儿模块的策略面 |
| F-6 | **是否预取下一章**（原版只预取播放 URL 不下载文件，AudioPlay.kt:501-543） | V1 不做文件预取；播放 URL 预取链我方现状也无，暂不对齐 | 范围控制；预取只省一次取址请求，收益小 | 播放链 |
| F-7 | **写入归属终裁**（任务 E）：双通道（推荐）/ 仅 SAF / 仅 Rust 私有目录 | 双通道 | 见 E3 | FFI 方法集（±audioCacheDownload/±audioCacheFileName）、Dart 桥工作量 |
| F-8 | **徽标数据源**：走 FFI（§2.47 audioCacheList）还是 Dart SAF 直解文件名 | 走 FFI（语义统一 + UI 层红线）；SAF 目录场景 Rust 无感时由 Dart list 后过 FFI 比对 | AGENTS.md:49；两端一致 | 目录页数据链、轮询成本 |
| F-9 | **`.complete` 标记与五段式文件名是否逐字节复刻** | 逐字节复刻（含 normalizeFileName、UUID revision、元数据版本行） | 与原版互操作是硬需求；差一字符即互不识别 | 键/文件名实现与测试 |
| F-10 | **孤儿模块 `rust/legado-core/src/audio_cache.rs` 处置** | 删除并按原版语义重写（键/持久化/策略三处不符，B1 警告框） | 留着会被误当可用基线；其键规则与原版冲突 | legado-core/lib.rs 导出面、cargo test |

---

## 附：最容易踩的坑（实施前必读）

1. **键规则想当然**：不是 `md5Encode16(chapterUrl + "|" + title)`，而是 `md5Encode16(chapterUrl.ifBlank{title})` 的 MD5 hex **中段 16 字符**（`substring(8,24)`）；书级目录是 `md5Encode16(bookUrl)`。任何一个字符算错，全部缓存永不命中且无法察觉（只是 miss）。
2. **把孤儿写当可用数据迁移**：`hash_i.audio` 无归属元数据、章节下标在目录变动后必然错位（D3）；直接「复制到新键」= 把错章音频洗白成已验证缓存，用户可感知且不可逆。
3. **大文件走 base64 穿 FFI**：复用 `saveImageCache`（§2.46）模式写音频会 base64 膨胀 + 全量驻内存；必须流式（Rust reqwest 直落盘 / saf `writeFileStream`），并保留写后 size 读回校验（MuMu 幻影写入前科，StorageBridge.kt:27-33）。
4. **播放链插桩破坏进度归属**：插桩点必须在 `mediaUrl` 空判定之后、`playUrl` 之前（B2）；`playLocalFile` 必须带上与 `playUrl` 相同的 `tag`（bookUrl, chapterIndex）并复用 P1 竞态修复的归属校验链（audio_notifier.dart:505-511, 549-553），否则旧章迟到回调会写错进度键。

## 附：本报告证据文件清单（绝对路径）

原版基线：
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\model\AudioCacheKey.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\help\audio\AudioCachePolicy.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\help\audio\AudioCacheManager.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\service\AudioCacheService.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\model\AudioPlay.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\model\AudioCacheStateChanged.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\data\entities\BookCacheInfo.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\data\dao\BookDao.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\help\book\BookHelp.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\ui\book\audio\AudioPlayActivity.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\ui\book\toc\ChapterListFragment.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\ui\book\toc\ChapterListAdapter.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\utils\MD5Utils.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\utils\StringExtensions.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\help\config\AppConfig.kt`

我方现状：
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-ffi\src\api\audio_api.rs`
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-ffi\src\ffi.rs`
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-core\src\audio_cache.rs`（孤儿模块）
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-core\src\lib.rs`
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-ffi\src\api\image_cache_api.rs`
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-ffi\src\api\cache_api.rs`
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-ffi\src\api\cache_download_api.rs`
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-ffi\src\api\tts_speak_api.rs`
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\services\rust_api_media_format.part.dart`
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\providers\audio\audio_notifier.dart`
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\services\stream_audio_player.dart`
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\screens\audio_screen.dart`
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\utils\audio_skip_policy.dart`
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\android\app\src\main\kotlin\io\legado\flutter\StorageBridge.kt`
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\pubspec.yaml`（saf 2.1.0）
- `C:\Users\admin\AppData\Local\Pub\Cache\hosted\pub.dev\saf-2.1.0\lib\src\v2\saf.dart`

契约与测试：
- `D:\OH-WorkSpace\LegadoTeam\legado\docs\API_CONTRACT.md`
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\test\unit\api_contract_test.dart`
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\services\book_api.dart`
