# TXT 解码缓存容量上限分析（R32）

- 日期：2026-11-23
- 对应登记：`docs/REMAINING_WORK_INVENTORY_20261120.md` R32「TXT 解码缓存 >64 MiB 退化（无提速但正确）」
- 代码基线：HEAD `6f32c2e115`
- 结论：**采纳路线 A（提高上限 64 MiB → 128 MiB），并附带解码前预留空间（`reserve`）**。路线 B/C 不实施，理由见 §5。

---

## 1. 退化点的确切位置

`rust/legado-book/src/txt_cache.rs`（批35 交付）：

| 项 | 值 | 位置 |
| --- | --- | --- |
| 条目数上限 | 4（生产）/ 1024（测试） | `MAX_ENTRIES` |
| 解码文本总字节上限 | **64 MiB**（生产）/ 1 GiB（测试） | `MAX_BYTES` |
| 单条超限处理 | `insert` 直接 `return`，不写缓存 | `TextCache::insert` 的 `text.len() > self.max_bytes` 守卫 |

退化不是「缓存写满后淘汰」，而是**单条解码文本超过总上限时彻底不缓存**：`load_decoded_text` 每次调用都 `seek(0)` + `read_to_end` + `decode_text` 全量解码。缓存代码路径与正确性无关，只是失去提速。

## 2. 章节索引语义：确认是「解码后文本偏移」

结论：**是解码后文本（UTF-8）的字节偏移，不是原始文件字节偏移。** 三处交叉印证：

1. `rust/legado-book/src/txt.rs:209` —— `let total_len = text.len() as i64;` 其中 `text` 是 `load_decoded_text` 返回的解码结果；`ChapterInfo.start/end` 全部由它派生。
2. `rust/legado-book/src/txt.rs:221-229` —— `end` 回填用 `chapters[i + 1].start` 与 `text.len()`，同一坐标系。
3. `rust/legado-ffi/src/api/reader.rs:678-686` `chapter_to_local_info` —— 直接把 DB 的 `ch.start/end` 原样透传给 `legado_book::ChapterInfo`，落库与读出之间无单位换算。

因此上游 Android 的「按原始字节 512KB 窗口 seek」（`TextFile.kt:118-127`）在本实现**不可直接移植**：GBK/Big5/UTF-16 与 UTF-8 之间无线性映射，`start` 无法反推原始文件偏移。这也是批35 选择「整书解码缓存」而非「窗口 seek」的根因，本文档延续该结论。

## 3. 触发退化的原始文件门槛（实测）

解码后文本大小 = 原始字节 × 编码膨胀比。以 `MAX_BYTES = 64 MiB` 反解原始文件门槛：

| 编码 | 膨胀比（实测/理论） | 触发退化的原始文件大小 |
| --- | --- | --- |
| UTF-8 | 1.0× | **> 64 MiB** |
| GBK / GB2312 | 1.43~1.50× | **> ~42.7 MiB** |
| Big5 | ~1.5× | **> ~42.7 MiB** |
| UTF-16LE/BE | 0.5×（2 字节/字符 → UTF-8 1~3 字节） | **> ~32 MiB** |

膨胀比实测：`中文正文 × 40` 样本 GBK 856 B → UTF-8 1283 B（1.499×）；混合 ASCII 样本 1.357×。

**关键判断**：批35 设备验收用的 `QA35_A4_60MB.txt`（60,291,264 B ≈ 57.5 MiB，6000 章）**如果**是 GBK，解码后 ≈ 82~86 MiB，早已越过 64 MiB 门槛——即该验收样本本身就在退化区间内。批次登记称其「首开 488ms、跳章 427-543ms」，与「未缓存、每章全量读取」的量级一致（见 §4 实测 98ms/章 + 分页开销）。

## 4. 退化代价实测

宿主（Windows x64，release）基准，6000 章夹具，逐章 `get_chapter_content`：

| 夹具 | 原始大小 | 解码后 | 64 MiB 档（退化） | 128 MiB 档（命中） | 倍率 |
| --- | --- | --- | --- | --- | --- |
| GBK 6000 章 | 59.6 MiB | ~89 MiB | **98.46 ms/章** | **0.111 ms/章** | **887×** |
| UTF-8 6000 章 | 89.4 MiB | ~89 MiB | 54.27 ms/章 | 0.074 ms/章 | 733× |
| GBK 40 MiB | 40.0 MiB | ~57 MiB | 0.111 ms/章（命中） | 0.119 ms/章（命中） | 1× |

**放大效应**：`flutter_legado/lib/src/screens/reader_screen.dart` 的 `_preloadAdjacentChapters` 对**前后各 2 章**预载（本地书同样生效，与 `reader_notifier.dart` 的 `_preDownloadNextChapters` 不同——后者对本地书短路）。未命中时单次翻页实际触发 5 次全文件读取+解码 ≈ 5 × 98 ms ≈ **0.49 s**。

**线程模型**：`reader_get_content_full` 经 FRB `executeNormal` 在 worker 池执行（`flutter_legado/lib/src/bridge/frb_generated.dart:7476`），不阻塞 UI 线程；退化的表现是**翻页等待延迟**，不是卡帧。

## 5. 四条路线评估

### 路线 A：提高上限（**采纳**）

改动：`MAX_BYTES` 生产值 64 MiB → 128 MiB（抽出 `PROD_MAX_BYTES` 常量）。

**收益**：解码后 64~128 MiB 的书全部进入缓存（GBK 原始 43~85 MiB、UTF-8 原始 64~128 MiB、UTF-16 原始 32~64 MiB），覆盖批35 验收的 57.5 MiB 中文 TXT 与绝大多数「超大 TXT」。

**内存代价**：实测**不升反略降**。

| 场景 | 64 MiB 档峰值 | 128 MiB 档峰值 |
| --- | --- | --- |
| GBK 59.6 MiB（单本） | 161.5 MiB | 159.1 MiB |
| UTF-8 89.4 MiB（单本） | 186.7 MiB | 184.3 MiB |
| 3 本 120 MiB 解码文本交替 | 208.4 MiB | 326.8 MiB → **206.8 MiB（加 reserve 后）** |

单本场景峰值基本持平：退化路径「原文件 + 解码副本」双份峰值 vs 缓存路径「单份解码文本常驻」，量级相同。**真正的风险在「多本大书交替」**——纯提上限会让缓存最多驻留 128 MiB 常驻 + 解码期临时副本，实测峰值冲到 326.8 MiB。

因此本次**同时加入 `reserve`**（见 §6）：解码前按本次原始字节数先淘汰 LRU 条目，把共存峰值压回「预算 + 单本解码」量级。加 reserve 后该场景峰值 206.8 MiB，与 64 MiB 档的 208.4 MiB 持平甚至更低。

**低端机风险**：稳态 RSS 上限 128 MiB（实测 128.5 MiB），且只在用户实际阅读超大 TXT 时才占满；普通网文（几 MiB）下缓存占用随书大小而非上限。`reserve` 保证峰值不超过「128 MiB + 单本解码副本」，最坏约 210 MiB 量级。原 64 MiB 档的退化路径峰值并不更低（208 MiB），所以这不是「新增」风险，而是把「无提速的高峰值」换成「有提速的同高峰值」。

**解码后 > 128 MiB 的书**（原始 GBK > 85 MiB）在两档下都不可缓存，实测峰值完全一致（258.5 MiB vs 258.6 MiB），即上限提高不改变这类书的资源特征；`reserve` 对这类书主动跳过（见 §6），不会白丢其他书的命中。

### 路线 B：分块缓存（不实施）

按章或固定大小分块缓存解码结果，内存可控。**不实施原因**：

1. **解码必须从头顺序进行**：`encoding_rs` 的 `decode()` 是无状态 API，但编码检测（`detect_encoding_from_sample`，B21 起 64KB 样本 + chardetng 兜底）需要文件前缀；块边界必须落在字符边界上，否则会产生替换字符。块内起点需要「从文件头解码到该点」才能确定，等价于仍需全量解码。
2. 缓存键需扩展为 `(path, encoding, block_index)`，失效检测要覆盖每块的文件戳——失效逻辑复杂度上升一个量级，而收益（内存从「单本解码大小」降到「块大小」）在 128 MiB 档下已不显著。
3. 实现复杂度与批35 已建立的「整书缓存 + 首中尾指纹失效」正确性模型不兼容，回归风险高。

### 路线 C：原始字节索引 + DB 迁移（不实施）

盘点所述彻底方案：把 `ChapterInfo.start/end` 改为原始字节偏移，正文读取按字节 seek 窗口解码。**不实施原因**：

1. 需改章节索引语义 + 迁移全部既有本地书的章节表（`book_chapters.start/end`），属 DB schema 迁移。
2. 窗口解码仍需处理「窗口起点落在多字节字符中间」——需向前回退最多 4 字节并丢弃半字符，且 GBK 双字节编码的合法起点判定依赖前文（`0x81-0xFE` 首字节 + `0x40-0xFE` 尾字节），窗口内可能出现「看似合法」的错位切分。
3. 收益相对路线 A 有限：路线 A 已把「解码后 ≤ 128 MiB」的书全部纳入，剩余退化区间是「解码后 > 128 MiB」，即原始 GBK > 85 MiB / UTF-8 > 128 MiB / UTF-16 > 64 MiB 的书——比 57.5 MiB 验收样本再大一倍以上。

### 路线 D：不做（**未采纳**）

判定依据：批35 验收样本（57.5 MiB 中文 TXT）本身落在 GBK 门槛（42.7 MiB）之上，说明「触发退化的书」并非极端个例，而是**已达验收规模**。加上预载放大 5 倍，退化表现为近 0.5 s 的翻页等待，用户可感知。因此不能登记为已知边界。

## 6. 本次改动

`rust/legado-book/src/txt_cache.rs`：

1. `MAX_BYTES` 生产值 64 MiB → 128 MiB，抽出 `PROD_MAX_BYTES` 常量并附完整实测依据注释。
2. 新增 `TextCache::reserve(need)`：解码前按本次原始字节数淘汰 LRU，压低「缓存常驻 + 解码临时副本」的叠加峰值。
   - `need >= max_bytes` 时**直接跳过、不清空**：原始字节是解码后大小的下界（GBK/UTF-8），这种书解码后必然超预算、`insert` 会放弃写入；若在此清空，超大书的每章读取都会白丢其他书的缓存命中，属净损失。
3. 新增单测：
   - `test_reserve_evicts_lru_until_space_available`（只淘汰到刚好够用）
   - `test_reserve_skips_when_need_exceeds_capacity`（`need >= 上限` 不清空，含边界 `need == max_bytes`）
   - `test_reserve_does_not_change_insert_oversize_guard`（不改变单条超限守卫）
   - `test_reserve_then_insert_caches_new_entry`（预留后仍可缓存）
   - `test_prod_capacity_covers_oversized_books`（`const` 断言 `PROD_MAX_BYTES >= 96 MiB` + 用生产值构造实例验证 >64 MiB 单条可缓存）

`rust/legado-book/src/txt.rs`：

4. 新增 `test_over_64mib_txt_chapter_reads_hit_cache`：70 MiB UTF-8 夹具（50 章），断言跨章跳读只做 1 次全文件读取+解码。

### 突变验证

| 突变 | 变红的用例 |
| --- | --- |
| `PROD_MAX_BYTES` 改回 64 MiB | `test_prod_capacity_covers_oversized_books`（const 断言编译期即失败） |
| `reserve` 改为 no-op | 3 条 `test_reserve_*`（淘汰类断言全部变红） |
| `reserve` 对 `need >= max_bytes` 清空 | `test_reserve_skips_when_need_exceeds_capacity` |

> 注意：`test_over_64mib_*` 在 `cfg!(test)` 档（1 GiB）下运行，**不**保护生产常量；生产常量的守卫是 `test_prod_capacity_covers_oversized_books` 的 const 断言。

## 7. 残余边界（登记）

- **解码后 > 128 MiB 的书仍退化**（原始 GBK > 85 MiB / UTF-8 > 128 MiB / UTF-16 > 64 MiB）。仍正确，仍无提速；实测峰值与 64 MiB 档一致（258.5 vs 258.6 MiB），即本次改动不改变这类书的资源特征。
- 缓存最多驻留 128 MiB 解码文本；阅读超大书时稳态 RSS 上限 128 MiB，峰值（含单本解码副本）实测 ≤ 207 MiB；不可缓存的更大书峰值约 259 MiB（与旧档相同）。
- 章节坐标仍为解码后偏移，未引入原始字节索引；如需按字节窗口读取，属路线 C（DB 迁移）范围。

## 8. 门禁

```
cargo fmt --all -- --check                            → 0
cargo clippy --workspace --all-targets -- -D warnings → 0
cargo test --workspace -- --test-threads=4            → 4362 passed / 0 failed
```
