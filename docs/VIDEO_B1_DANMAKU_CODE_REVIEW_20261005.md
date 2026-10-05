# V-B1 视频弹幕数据链 独立代码审查报告

- 审查对象：`da25b7abaa` feat(rust): 视频弹幕数据链接通（16 文件 +1976/-344）
- 契约基线：docs/API_CONTRACT.md §2.49（冻结于 7285936736）
- 原版语义基线：`app/src/main/java/io/legado/app/`（只读对照）
- 审查日期：2026-10-05；审查方式：全量 diff 实读 + 原版 Kotlin 逐行对照 + 测试复跑（只读审查，未改任何被审代码）

## Summary: pass（可合并，附 3 项建议级修复）

无阻塞（P0）缺陷。六项 P0 重点核实项全部通过；P1 三项中 lyric 同落判定为「原版同链语义的自然完成」；发现 3 项建议级问题（歌词 ≥10000 文件回退缺失、variable 读-改-写并发窗口、UTF-16 口径测试未覆盖增补平面）。

---

## P0 — 正确性（重点核实项，逐条结论）

### 1. 阈值口径（UTF-16 vs 码点）——实现正确，测试钉死力度不足

**结论：实现正确。**

- `rust/legado-ffi/src/api/video_api.rs:95`：`kotlin_str_len` 用 `s.encode_utf16().count()`，即 Kotlin `String.length` 的 UTF-16 码元口径，与 `RuleDataInterface.kt:16`（`value.length < 10000`）一致。
- 判定点 `video_api.rs:269`（`< LARGE_VALUE_THRESHOLD`，阈值常量 `:55` = 10000）。
- **审查者的原始疑虑（码点计数 vs UTF-16）不成立**：没有用 `chars().count()`，增补平面字符（emoji）按 2 个码元计，与 Kotlin 行为一致——9999 个 emoji（19998 码元）会正确走文件分支。
- **但测试钉死力度不足（见 P2-3）**：`test_threshold_uses_kotlin_utf16_length`（`video_api.rs` tests，复跑通过）用 CJK 字符——CJK 在 BMP 上码点数 == UTF-16 码元数，该测试能钉死「不是按字节数」（30000 字节仍进 variable），**不能**区分「UTF-16 码元」与「码点计数」。若后人把 `kotlin_str_len` 改成 `chars().count()`，测试仍全绿。commit 声称「阈值按 UTF-16 口径钉死」，对实现成立、对测试覆盖面属过度声称。
- **实际影响评估**：弹幕 XML 中 emoji（U+1F1E6–1F1FF 国旗、U+1F600 段表情）常见，恰是两口径出偏差的区间；当前实现无偏差，风险仅在回归防护缺一口。

**修法**：给阈值测试加一例增补平面用例，如 `"😀".repeat(5000)`（UTF-16 = 10000 → 走文件；码点计数 5000 → 误进 variable），一行断言即可把口径真正钉死。

### 2. `chapters.variable` JSON 读写格式兼容性——通过

**结论：与原版双向兼容。**

- 原版写：`BookChapter.kt:73-82`（`variable = GSON.toJson(variableMap)`，`variableMap` 为 `HashMap<String,String>`，解析失败 `.getOrNull() ?: hashMapOf()` 降级空 map）。
- 我方读：`video_api.rs:100-108` `inline_variable_value` 用 serde_json 解析、只取字符串值（原版 map 值恒为 String，口径一致）；解析失败 → None（对齐原版 Gson 失败降级空 map 的读侧结果）。
- 我方写：`video_api.rs:259-267` 解析现有列 → 合并键 → `serde_json` 序列化回写。非字符串值会原样保留（serde `Value`），不会破坏其他写入方产生的键；Gson 默认的 HTML 转义（`\u003c` 等）对双方解析均透明，共用 DB 场景（用户从原版迁移）往返无损。
- 我方解析失败时 `unwrap_or_default()` 重建空 map（`video_api.rs:260`），与原版 `putDanmaku` 在 variable 列损坏时重建 map 的行为等价（原版 `variableMap` 惰性解析同样丢弃坏值）。

### 3. fetcher 分层——通过

**结论：fetcher 零触库，sink 失败不阻断正文。**

- 注入面：`rust/legado-fetcher/src/deps.rs:33`（`MediaSubContentSink` 类型）、`:118-140`（`capture_media_sub_content`：未注入 sink → eprintln + 返回 false；bookUrl 未知 → 仍以 None 交宿主兜底）。
- 落库实现只在 ffi 侧注入：`rust/legado-ffi/src/api/web_book.rs:66-86`（`ffi_deps()` 注入 `video_api::put_media_sub_content_from_capture`）。
- 抓取链接线：`rust/legado-fetcher/src/web_book.rs:1994-2016`——`is_media` 时不再调 `merge_sub_content_into_body`（该函数对 `is_media=true` 本就提前 return，`web_book.rs:3800-3805`，改前媒体分支 subContent 确为「抓到即丢」，本次改动无正文回归，既有单测 `test_merge_sub_content_skips_media_to_protect_play_url` 未动）。
- 阻断面：`capture_media_sub_content` 返回值在调用点被忽略；sink 内部 `put_media_sub_content`（`video_api.rs:219-236`）把所有错误收进 `Result` 后仅 `log::warn!`，正文返回路径无任何 `?` 上抛。契约「写失败降级仅记日志不阻断正文」成立。

### 4. 脏值链兜底——唯一命中判定严格；静默丢弹幕面已确认并评估

**结论：a/b 成立（判定严格、防多行到位）；c 面（静默丢弹幕）真实存在但已登记、面小、可接受。**

- a) 唯一命中：`rust/legado-db/src/repository/book_chapter_repository.rs:89-125` `find_book_url_by_source_and_chapter_url`——SQL `WHERE c.url = ?1 AND b.origin = ?2 LIMIT 2`，收集后 `found.len() == 1` 才 `Some`，多行（同源多书共用章节 URL）返回 None。多书同源时**不会落错书**（宁跳过不串书），歧义场景有专门测试（`test_find_book_url_by_source_and_chapter_url` 的 book3 分支，复跑通过）。
- b) 防多行：`LIMIT 2` + 精确计数，无 `LIMIT 1` 取首行的错误模式；SQL 参数化无注入面。
- c) 静默丢弹幕面：`web_book.rs` 目录链 `get_chapters_with_hints_and_vars`（`:2052`）把调用方传入的 `book_url`（refreshToc 传 tocUrl，`reader.rs:457-470` 计算 fetch_url）记入 meta 缓存（`:2150`），正文阶段该脏值经 `chapter_exists` 校验失败（`video_api.rs:189-194`）→ 走 `(sourceUrl, chapterUrl)` 反查。反查再失败（歧义/书源不匹配/书不在 DB）→ `video_api.rs:196-201` 仅 warn 日志跳过。**用户可见面**：同源多书共用同一章节 URL 的书源（聚合源低概率）在 refreshToc 链路上拿不到弹幕，且无用户可感知提示。该取舍「宁可不落库也不串书」已在代码注释、deps.rs 文档与测试中三处登记，且有正向兜底（唯一命中即正确落库）；本审查判定为**可接受的降级面**，但建议后续把 skip 事件计入可查询日志（AppLog）而非仅 eprintln/log，便于用户报障时定位。

### 5. 大文件路径往返——与原版逐段一致

**结论：通过。**

- md5 口径：`rust/legado-db/src/rule_big_data.rs:324-326` `format!("{:x}", md5::compute(input.as_bytes()))` = 输入 UTF-8 字节的 32 位小写 hex；原版 `MD5Utils.md5Encode` = hutool `digestHex`，同口径。
- 路径形状：`rule_big_data.rs:167-175` `chapter_variable_path` = `book/{md5(bookUrl)}/{md5(chapterUrl)}/{md5(key)}.txt`，与原版 `RuleBigDataHelp.kt:194-208`（putChapterVariable）/`getDanmakuFile`（md5_32("danmaku") 固定文件名）逐段一致；`bookUrl.txt` 标记文件（原版 `:140-144`）也已同步写（`rule_big_data.rs:135-139`）。
- 读回分支：`video_api.rs:129-158` Inline → File → None，File 态用同一 `chapter_variable_path` 定位写入分支所写文件，回环测试（`test_get_video_danmaku_large_file_roundtrip`，复跑通过）验证文件内容原样读回。
- 分支互斥语义对齐原版 `RuleDataInterface.putVariable`：小数据写 variable 并删同名文件、大数据删键并写文件（`video_api.rs:269-302`），原版 `putVariable` 三分支逐行对应（含「键不存在时大数据分支不动 variable 列」这一细节）。

### 6. 并发——存在窄窗口读-改-写竞争（建议级）

**结论：无阻塞缺陷，但 variable 列的读-改-写无事务/互斥，见 P2-1。**

- DB 层：`db_state.rs` r2d2 池，`with_database` 每次取独立连接；SQLite 单写者保证单条 UPDATE 原子，但 `put_media_sub_content_inner`（`video_api.rs:251-303`）是「读章节行 → 内存合并 JSON → UPDATE」三步，两次并发捕获同一章节可互相覆盖（后写赢，丢对方键）。
- 实际触发面窄：同章并发两次抓取写的是**同键同值**（danmaku 原文），结果一致；variable 列上其他键（章节规则变量）被卷入丢失的概率极低但存在。
- 与既有章节内容缓存写路径无互斥，但内容缓存在 `cached_chapters` 表，不碰 `chapters.variable`；refreshToc 的 `delete_by_book_url + insert_batch_no_tx`（`reader.rs:659-661`）会整表重写章节行（variable 列被目录抓取值覆盖），**与原版一致**（原版 `BookChapterDao` `delByBook` + `insert` 同型重写，弹幕本就随重抓恢复），非本批引入。

---

## P1 — 契约一致性

### 7. getVideoDanmaku 降级面——严格合规

- `rust/legado-ffi/src/ffi.rs:2005-2010`：`get_video_danmaku` 恒 `Ok(video_api::get_video_danmaku(...))`，无 BridgeError 上抛路径。
- Rust 内部：空 bookUrl 短路（`video_api.rs:114-116`）、章查询 Err/None（`:117-128`）、JSON 坏值、文件读失败（`:146-153`）全部降级 None；6 个 ffi 单测 + Dart 3 单测 + 契约测试复跑全绿。
- Dart 侧：`rust_api_discovery_cache.part.dart` try/catch → null；`test/unit/video_danmaku_api_test.dart` 验证 FFI 未初始化时不抛。

### 8. BookApi 292 闭合——实测确认

- `flutter test test/unit/api_contract_test.dart` 复跑 **7/7 通过**（含「文档声明的 BookApi 总数 == 程序化计数」与「每个 BookApi 方法都在契约中登记」）。
- docs/API_CONTRACT.md:180 登记 291→292 计数变更；§2.49 方法行与实现签名一致（`Future<String?>` / `Result<Option<String>, BridgeError>`）。

### 9. lyric 同落定性——原版同链语义的自然完成，属授权范围

**判定依据（三条独立证据）：**
1. **原版行号**：`BookContent.kt:150`（音频分支 `bookChapter.putLyric(subContent)`）与 `:156`（视频 `putDanmaku`）在同一段 `when` 内，是同一条 subContent 消费语义的两个并列分支；我方常量对齐（Rust `book_source_type::AUDIO=1/VIDEO=4` == Kotlin `BookSourceType.audio=1/video=4`），键名对齐（`putLyric("lyric")`）。
2. **既有消费方**：`rust/legado-ffi/src/api/audio_api.rs:109-118` `lyric_from_variable` 早已在读章节 variable 列 `lyric` 键（§2.26 `getAudioChapterMedia` 字段），但本批之前无任何写入方——lyric 同落补上了该字段的供给端，属数据链接通的自然收尾。
3. **契约文本**：§2.49 写入侧表述为「fetcher **媒体分支**从『丢弃 subContent』改为『捕获 → 分流落库』」（未限视频），字段模板明引 §2.26 `lyric` 先例；commit message 亦如实声明。

**结论：不是未授权扩展。**

**附带发现（建议级，见 P2-2）**：原版读侧 `AudioPlay.kt:408/495` 用 `chapter.getVariable("lyric")`（RuleDataInterface.getVariable = `variableMap ?: getBigVariable`，**含大文件回退**）；我方歌词读侧只读 variable 列，≥10000 字符歌词落文件后 `getAudioChapterMedia` 读不到——弹幕侧读写两态齐备，歌词侧只补了写。

---

## P2 — 工程

### 建议（应当修）

1. **variable 读-改-写并发窗口**：`rust/legado-ffi/src/api/video_api.rs:251-303`。两次并发落库（同章重复抓取、或与未来其他 variable 写入方并发）后写覆盖前写。修法：`put_media_sub_content_inner` 的读-改-写包进 `unchecked_transaction()`（BEGIN IMMEDIATE，参照换源流程 `insert_batch_no_tx` 的事务先例），或按 `(bookUrl, chapterUrl)` 加应用级互斥。
2. **歌词 ≥10000 文件回退缺失**：`rust/legado-ffi/src/api/audio_api.rs:109-118`。写入面已能产生大数据文件形态的 lyric，读取面（`getAudioChapterMedia`）缺 File 回退，原版 `AudioPlay.kt:408` 的 `getVariable` 语义未对齐。修法：`lyric_from_variable` 未命中时补一次 `RuleBigDataManager::get_chapter_variable(book_url, url, "lyric")`；或在本批不动、在 API_CONTRACT §2.26 登记「长歌词文件变体暂不读回」的已知偏差。
3. **UTF-16 口径测试未覆盖增补平面**：`video_api.rs` tests `test_threshold_uses_kotlin_utf16_length`。加 `"😀".repeat(5000)` 用例把「UTF-16 码元」从「BMP 恰好等价」升级为真正钉死（P0-1 附注）。

### 可选（可改进）

4. **空值边界偏离（两处极边缘）**：原版 subContent 为 `""` 时 `putDanmaku("")` 落 `"danmaku":""` 且读侧返回空串；我方 `put_media_sub_content` 对空值 no-op（`video_api.rs:228-230`，且 fetcher 侧空提取本就返回 None 不会到达），读侧返回 null。另一处：`resolve_danmaku`（`legado-core/src/video_state.rs:343-354`）过滤空 inline → variable 有 `"danmaku":""` 且文件存在时，Kotlin 返回 `""`，我方回落读文件。两者均无用户可见影响（空弹幕/空歌词无渲染意义），登记即可不必修。
5. **VideoPlayerState 构造偏重**：`video_api.rs:140-143` 每次查询 new 一个完整状态机只为持有 `DanmakuSource` 字段。可在 video_state 提供 `DanmakuSource::resolve(inline, file)` 自由函数，归一逻辑更轻、也更便于直接单测。职责未越界，现写法可用。
6. **skip 事件可观测性**：P0-4c 的落库跳过目前仅 log::warn/eprintln，建议计入 AppLog 可查询缓冲，便于用户报障定位（同 §2.38 体系）。

### 已核实通过（无问题项）

- **video_state.rs 激活方式（P2-10）**：`DanmakuSource` 三态仅用于查询归一（`video_api.rs:139-158`），无塞入无关职责；激活前零引用（`git grep video_state da25b7abaa^` 确认）→ 激活后仅 video_api 一处消费。
- **env 回落链（P2-11）**：`LEGADO_RULE_DATA_DIR` > DB 父目录/ruleData > temp 一次性告警（`video_api.rs:64-91`），one-shot warn 对齐 `cache_download_api.rs:186` 既有先例；根目录偏离原版 externalFiles 一事已在模块文档与 commit message 双处登记（DB 父目录 = Documents 持久目录，非 cache，语义等价）。
- **FRB codegen（P2-12）**：`frb_generated.rs` 新增仅 wire 函数模板（1 处新增 unsafe 为 FRB 标准样板，全文件 283 处 unsafe 均为既有生成模板；新写的 video_api/deps/web_book 代码零 unsafe）；`frb_generated.dart` +371/-167 为机械重生成；wire 序号 118 注册到位。
- **测试真实性**：Rust 侧 4 组测试复跑全绿（db 9、fetcher 5、ffi video_api 6、contract 7/7 + danmaku 3）；e2e 运行时测试（`flutter_legado/test/ffi/video_danmaku_runtime_test.dart`）为真实 DLL + 回环服务器全链（importBookSources → addBook → refreshToc → getChapterContentFull → getVideoDanmaku），并覆盖 refreshToc 链（meta 不含正确 bookUrl）的兜底反查路径——非泄漏答案的摆设测试。唯一保留意见即 P2-3 的口径测试覆盖面。
- **读者注意**：e2e 测试头注释称「refreshToc 链不登记 fetcher meta 缓存」与 `web_book.rs:2150` 实际行为不符（`get_chapters_with_hints_and_vars` 会登记脏 tocUrl 作 bookUrl）——测试断言本身不受影响（脏值与缺失殊途同归走兜底反查），仅注释表述不准，建议顺手修正。

---

## 证据分级与 Non-claims

- **静态证明**：P0-1/2/5 与原版 Kotlin 逐行对照（实读 `RuleDataInterface.kt`、`BookChapter.kt`、`RuleBigDataHelp.kt:140-215`、`VideoPlay.kt:279-281`、`BookChapterExtensions.kt:8`、`BookContent.kt:138-165`、`MD5Utils.kt`、`BookSourceType.kt`）。
- **冒烟证明**：全部测试为审查时实机复跑（非采信 commit message）；cargo 三包 + flutter 契约/单测共 30 个相关用例通过。
- **持久证明缺口（non-claims）**：① 未实际运行 Android 原版 App 与我方共用 DB 做迁移往返实测（JSON 兼容性结论基于两侧序列化格式静态对照 + Gson/serde 行为分析）；② 未压测并发落库窗口；③ ≥10000 歌词文件回退缺失未经真机复现（静态判定）。上述三项结论置信度：高/中/高。

## 总体结论

**pass（可合并）**。契约 §2.49 全项达成，六项 P0 重点核实项无阻塞缺陷；建议合并前或紧随其后处理 P2-1（事务化）、P2-2（歌词 File 回退）、P2-3（增补平面测试用例）三项。
