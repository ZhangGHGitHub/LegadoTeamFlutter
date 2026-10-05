# B1 音频章节文件缓存 —— 独立代码审查报告（2026-10-04）

- 审查对象：`0226c6f096`（feat: 只读与清理面）、`1b80ea6bdd`（test: 运行时验证）、`e82625596e`（docs: 契约冻结）
- 审查方式：只读审查 + 真实运行验证（cargo / flutter test 实跑）；基线对照原版 Kotlin `app/src/main/java/io/legado/app/`
- 证据等级声明：键口径 / Unicode 边界 / 路径穿越等结论为「源码逐行对照 + 定向测试实跑」级；全量测试套件与 release/真机行为未复验，见文末 non-claims

## Summary: pass（可合并，附 1 项 P1 随下一批收口）

实现与契约 §2.47 逐条对齐，未发现正确性或安全缺陷。唯一实质问题（预下载 UI 与新读面永久脱节）为本批之前已存在的非回归项，契约已明示延后裁决，但必须在下一批收口。

---

## 逐项核查结论（对应审查任务 P0/P1/P2）

### P0-1 md5Encode16 口径 —— 核实无误，无问题

- 原版链条实证：`app/src/main/java/io/legado/app/model/AudioCacheKey.kt:20-23` → `MD5Utils.md5Encode16` = hutool `DigestUtil.digester("MD5").digestHex(str)`（`utils/MD5Utils.kt:23-33`，**无盐**、小写 hex）后 `substring(8, 24)`。
- 实现：`rust/legado-ffi/src/api/audio_cache_api.rs:118-121` `md5_mid16` = `format!("{:x}", md5::compute(input))` 取 `[8..24)`。`md5::compute(&str)` 摘要 UTF-8 字节，`{:x}` 输出小写，无 trim、大小写敏感、不含 bookUrl、不含 url+title 拼接。
- **stub 理由核实成立**：`rust/legado-js/src/host_api/encoding.rs:389` `#[cfg(not(feature = "quickjs"))]` 下 `stub_encoding::md5_encode_16`（`:401-403`）确实返回错误字符串 `"encoding not available: build with --features quickjs"`；真实实现仅在 `:15` `#[cfg(feature = "quickjs")]` 分支。绕开它、复用 `image_cache_api.rs:148-155` 同款直算既正确又避免把工具函数耦合到 JS 引擎 feature。
- 测试向量实测：`md5("hello")[8..24) = "bc4b2a76b9719d91"`、`md5("")[8..24) = "8f00b204e9800998"` 等 4 向量在 cargo 实跑中通过。

### P0-2 ifBlank 语义 —— 核实无误，无问题

- `audio_cache_api.rs:124-137`：`kotlin_char_is_whitespace` 排除 `U+00A0 / U+2007 / U+202F / U+0085`，与 Java `Character.isWhitespace`（= Zs/Zl/Zp 去除三个不换行空格；U+0085 为 Cc 不算）逐码点一致；`09-0D / 1C-1F` 分支与 Rust `char::is_whitespace` 重叠，冗余但无害。空串经 `chars().all()` 得 true，与 Kotlin `isBlank()` 一致。
- 两侧字符集版本漂移仅影响 Zs 类新增（近年为零），无实际分歧码点。NBSP 不退回标题有测试钉死（`key_if_blank_and_sensitivity`，实跑通过）。

### P0-3 命中三条件 —— 核实无误，无问题

- `is_committed`（`audio_cache_api.rs:216-222`）= `size > 0`（`meta.len()==0` 拒）+ 同名 `.complete` 存在；`latest_committed_file`（`:225-243`）再叠加五段式正则 + key 匹配。`audio_cache_list` 对每条同样过三条件。**不存在**「只查 key 即命中」路径。
- 对照原版 `AudioCacheManager.kt:358-373`（committedCacheFiles：`size > 0 && name in completeNames && isCacheFile`）语义等价。

### P0-4 路径穿越 —— 核实无风险

- `book_dir`（`audio_cache_api.rs:145-147`）目录名 = `book_` + `md5_mid16(bookUrl)`，输出恒为 16 个 `[0-9a-f]` 字符，bookUrl 任何内容（含 `../`、盘符、分隔符）都无法进入路径。
- 清理面删除目标仅来自 `read_dir_entries` 对目标目录的真实枚举（`audio_cache_api.rs:227-243` / `:282-296` / `:301-312`），文件名是磁盘事实而非用户输入；解析出的 `chapter_index` / `key16` 不参与任何路径构造。五段式正则锚定 `^…$` 且各段字符类不含分隔符。
- 结论：不存在穿越出缓存根的路径。

### P0-5 同名取最新 —— 逻辑正确，一处非缺陷备注

- `modified > best` 严格大于，平局保留先枚举者；Kotlin `maxByOrNull` 同为「序中第一个最大值」。两侧目录枚举顺序均未指定（NTFS/SAF/ext4 各异），平局行为在原版与本实现中都非确定——非本批引入的缺陷，仅记录。
- `meta.modified().unwrap_or(UNIX_EPOCH)` 不 panic、不抛异常，符合降级纪律。

### P1-6 四方法签名/降级 —— 与 §2.47 逐条一致

- `ffi.rs:1885-1937`：4 个导出签名、返回 `Result<bool/Vec<i32>/i32/i32, BridgeError>` 恒 `Ok`，与契约表逐格一致；query/list 只读、clear 幂等、全失败降级。`set_audio_cache_dir`（`:152-162`）与 §1.6.1 登记一致。

### P1-7 audioCacheList 章节下标 —— 确实解析，计数仅 debug 级（P2 备注）

- `audio_cache_api.rs:246-268`：从文件名第一段 `parse::<i32>()` 取章节下标（溢出跳过，对齐原版 `toIntOrNull()`），去重升序（BTreeSet）。
- 「跳过并计数」落实为 `skipped` 变量 + `log::debug!`。返回类型冻结为 `Vec<i32>` 无法携带计数，debug 日志在 release 通常不可见——无用户可见错误，但契约措辞「计数」的可观测性偏弱。建议（可选）：升级为 `log::info!` 或在 §2.47 注明计数仅日志面。

### P1-8 清理计数口径 —— 实现与契约一致，契约对原版为已裁决偏离（P2 建议补注）

- 实证：原版 `AudioCacheManager.kt:338-356` `removeCacheFiles` 返回 `dataTargets.size`，**不含** `.complete` 标记；契约 §2.47 与实现（`audio_cache_clear_chapter` 数据文件 + 标记合并计数）均为「含 .complete」。
- 定性：这是契约层面对原版的显式偏离且已冻结，实现无错。当前 4 方法无任何 UI 调用方（全仓 grep 证实），暂无用户可见差异；下一批接线后「已删除 N 个文件」类提示将比原版每文件多计 1（标记）。建议在 §2.47 补一句「原版 removeCacheFiles 仅计数据文件，本节显式偏离」，防后续批次误判为 bug。

### P2-9 回落路径与一次性告警 —— 一致，通过

- `audio_cache_api.rs:39,96-104`：`<temp_dir>/legado-audio-cache` + `DEFAULT_DIR_WARNED` compare_exchange 一次性告警；§1.6.1 已在 `e82625596e` 登记（5→6 导出）。

### P2-10 删除 legado-core/src/audio_cache.rs —— 零引用属实

- 全工作区 `grep -rn "mod audio_cache|legado_core::audio_cache"` 仅命中新 `audio_cache_api` 模块；`rust/legado-core/src/lib.rs` 声明已移除；Cargo.toml、FFI、Dart bridge 均无残留引用；`cargo test -p legado-ffi` 实跑通过佐证编译闭合。

### P2-11 Dart 降级同型 —— 与 §2.46 一致，通过

- `rust_api_discovery_cache.part.dart:339-410` 四方法 try/catch 全包，降级 `false / const [] / 0`，与 `saveImageCache`（`:305-318`）同型；`audioCacheList` 返回的 `Int32List` 即 `List<int>`，类型闭合（api_contract_test「BookApi ⊆ RustApi」实测通过）。

### P2-12 孤儿写入脱节 —— 真实用户可见问题，P1 必修（随下一批，不阻断本批）

- 事实链：`audio_screen.dart:983-1022` `_cacheAudioRange` 仍是活路径（用户点「缓存第 X-Y 章」→ snack「开始缓存…」→ 下载全量音频 → 写 `${bookUrl.hashCode}_$i.audio`）。写入目标为 SAF tree（`kAudioCacheTreeUriKey`）或 **`getApplicationSupportDirectory()/audio_cache`**（`:973`）；而新读面根为 **`getApplicationCacheDirectory()/audio_cache`**（`rust_api.dart` `_initAudioCacheDir:296-306`）。目录不同 + 键不同 + 无 `.complete` → 新读面**永远**读不到，UI 却提示「已缓存 N 章到…」。
- 原版对照：`AudioPlay.kt:388-413` 播放第一步经 `AudioCacheManager.getCachedAudio` 读 **同一** `audioCacheTreeUri`（与 `AudioCacheService.kt` 写入同目录同键），预下载即时生效。我方现状为「预下载永远无效、播放永远在线」，每次触发净耗流量/电量/存储。
- 定性：本批之前读面不存在、写入本就无人读（非回归）；契约已裁决「UI 去留下一批」并加了注释。但冻结≠问题消失。**建议**：下一批要么接通读面（写入改五段式 + `.complete` + 指向注入的 `getApplicationCacheDirectory()/audio_cache`），要么先行下线预下载入口或改为「功能迁移中」提示。注意 SAF 目录与新读面（应用私有目录）结构性不兼容，接线时写入路径必须一并迁移。

### P2-13 运行时测试真实性与 codegen —— 属实

- `test/ffi/audio_cache_runtime_test.dart:45-49` 经 `RustLib.init(externalLibrary: ExternalLibrary.open(_resolveDll()))` 加载真实 DLL；`rust/target/debug/legado_ffi.dll` 实存（mtime 13:06 早于提交 13:08）。4 例覆盖三条件/ifBlank 回退/清理幂等/整书清理，全程真实 FRB wire + 真实文件系统，**非 mock 自证**。
- FRB codegen：`frb_generated.rs` 20 处 audio_cache 登记、wire 表机械编号（`9977: 18 => wire__…audio_cache_query_impl`）；io/web dart 仅新增 codec plumbing；未见手改生成物痕迹。

### P2-14 unsafe / 内存 / TOCTOU —— 无问题

- 无 `unsafe`；仅读 metadata 不读文件内容（无大文件入内存）；清理为「枚举快照 → 逐个 remove」，中途文件消失则删除失败不计数，良性；查询竞态保守判 miss。`tmp_{key}_*.part` 清理缺口见下。

---

## 发现汇总（按严重度）

| # | 严重度 | 位置 | 问题 | 建议 |
|---|--------|------|------|------|
| 1 | **P1 必修**（随下一批收口，不阻断本批） | `flutter_legado/lib/src/screens/audio_screen.dart:983-1022` | 预下载 UI 与新读面永久脱节：目录（support vs cache）、键（旧 hashCode vs 五段式 md5）、标记三重不匹配，UI 提示「已缓存」但永远读不到；原版为同目录同键即写即读（AudioPlay.kt:388-413） | 下一批接通读面并把写入迁移到注入目录（五段式 + .complete），或先下线该入口/改提示 |
| 2 | P2 建议 | `docs/API_CONTRACT.md` §2.47 | 清理计数「含 .complete」对原版（仅计数据文件，AudioCacheManager.kt:338-356）为显式偏离，未在契约中注明出处 | 契约补注偏离说明，防后续误判 |
| 3 | P2 建议 | `audio_cache_api.rs:282-296` | `clear_chapter` 不删原版会删的 `tmp_{key}_*.part` 临时文件（isTemporaryFile L383-387）；我方无写入面故目录中不会出现，暂无影响 | 下一批若补写入面必须同步补上；可在 §2.47 预登记 |
| 4 | P2 可选 | `audio_cache_api.rs:265-267` | list「跳过并计数」仅 `log::debug!`，release 下不可见 | 升级 info 级或在契约注明可观测性口径 |
| 5 | P2 备注 | `audio_cache_api.rs:236-241` | lastModified 平局取「先枚举者」，与原版同样依赖未指定的目录枚举顺序（两侧均非确定） | 无需修改，仅记录 |

## P0 项结论一览

1. md5 口径：**正确**（原版无盐 hutool hex [8,24)；stub 理由核实成立，encoding.rs:389/401-403）
2. ifBlank Unicode 边界：**正确**（四排除码点与 Java isWhitespace 一致，NBSP 有测试钉死）
3. 命中三条件：**完备**（无「只查 key 即命中」路径）
4. 路径穿越：**无风险**（bookUrl 先哈希再拼路径；删除目标仅来自真实目录枚举）
5. 同名取最新：**正确**（平局非确定性两侧同源，见汇总 #5）

## 行为验证记录（实跑）

- `cargo test -p legado-ffi --lib audio_cache`：**11/11 通过**
- `flutter test`（runtime 4 + unit 5 + contract 7）：**16/16 通过**，运行时链路走真实 DLL
- `flutter analyze`：**No issues found**
- 全量 `flutter test`：审查期间实跑复验 **2069/2069 全部通过**（与提交声明一致）
- 门禁不取代行为验证：以上为真实数据链证据（键向量 + 真实 DLL + 真实文件系统）

## 契约与实现不一致清单

- 实现 vs 契约 §2.47：**无不一致**（签名、返回、降级、幂等、只读、回落路径、一次性告警逐条对齐）
- 契约 vs 原版（已裁决偏离，实现随契约）：① 清理计数含 `.complete`（原版仅计数据文件）；② 不处理 `tmp_*.part`（我方无写入面）；③ 旧键不读不迁移；④ 无写入面/导入导出
- 暂态（契约明示）：预下载 UI 未接读面（见汇总 #1）

## non-claims

- 未验证 Android 真机 / SAF 实际行为、release 构建、Windows 以外平台文件系统差异
- 全量 cargo test / clippy 未复跑（仅定向 audio_cache 11 例 + 提交门禁声明）
- 未评估下一批播放链接线设计，仅指出脱节事实与约束（SAF 与应用私有目录不兼容）

## 总体结论：可合并

无 P0、无实现-契约偏离；1 项 P1 为非回归的既有脱节且契约已排期，须在下一批收口；4 项 P2 均为文档/可观测性建议。
