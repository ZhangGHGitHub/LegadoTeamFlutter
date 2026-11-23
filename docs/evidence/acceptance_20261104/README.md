# `acceptance_20261104` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261104`（采集 2026-11-03 ~ 2026-11-03）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 42 行（判定「需先归档」；A.2 口径 16.9 MB / 342 文件 / 唯一非日志副本 86）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261104_BATCH2B2C / _BATCH9B3 / _P2E1.md`
> 验收范围：批 2b-2c / 9b-3 / P2-E1 三报告共用同一证据目录（列表-详情、漫画本地/夹具、冷启动深链导入）

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 331 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 4 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 6 | 1.7 MB，原始过程日志 |
| 丢弃日志型 `.txt` | 1 | 9.5 KB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **342** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 147 | 147 | PASS（一致） |
| `.xml` uiautomator | 127 | 127 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `0604d5aed42e5748` | 1 |
| `06de5f6cdc7f13a0` | 1 |
| `0c015f3c58ef0ff1` | 1 |
| `13215ae056712b8c` | 1 |
| `1676f4b9ed96490d` | 1 |
| `1b7fb8fdd42f93f3` | 1 |
| `483a32634560ed4c` | 1 |
| `507397c6af39d4ee` | 1 |
| `52b3823caad9d29f` | 1 |
| `74e1f214e3014a59` | 1 |
| `8368c18c8ea26e9b` | 1 |
| `9861d35e415a67b5` | 1 |
| `9d9490b7efdd3e92` | 1 |
| `ad881dddddb7fd3a` | 1 |
| `b79d411a24d1b1b2` | 1 |
| （其余 132 个前缀） | 132 |

语义树按目录分布：`data` 125、`fixture_www` 2。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.html` | 26 | 30.7 KB |
| `.txt` | 19 | 12.4 KB |
| `.sql` | 4 | 17.2 KB |
| `.json` | 3 | 1.8 KB |
| `.py` | 3 | 11.9 KB |
| `.cbz` | 1 | 350 B |
| `.mp4` | 1 | 1.0 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `data/apk_sha256.txt`（127 B）
- `data/c1_images_after.txt`（1.7 KB）
- `data/c2_images_after.txt`（1.2 KB）
- `data/c2b_images_after_prev.txt`（1.2 KB）
- `data/c3_images_after0.txt`（1.6 KB）
- `data/c4_images_after.txt`（328 B）
- `data/c5_images_after.txt`（236 B）
- `data/cleanup_final.txt`（49 B）
- `data/db_baseline.txt`（747 B）
- `data/db_books_rows.txt`（576 B）
- `data/db_books_schema.txt`（1.0 KB）
- `data/db_cached_schema.txt`（202 B）
- `data/db_rss_rows.txt`（119 B）
- `data/db_sources_rows.txt`（164 B）
- `data/db_tables.txt`（806 B）
- `data/device_baseline.txt`（1011 B）
- `data/so_evidence.txt`（1.1 KB）
- `data/version_installed.txt`（232 B）
- `fixture_payload/cbz/qa9b3_local.cbz`（350 B）
- `fixture_payload/cleanup.sql`（389 B）
- `fixture_payload/loc/qa_b2c_book_c.txt`（153 B）
- `fixture_payload/meta.json`（848 B）
- `fixture_payload/meta_composite.json`（730 B）
- `fixture_payload/seed.sql`（12.3 KB）
- `fixture_payload/seed_cbz.sql`（1.1 KB）
- `fixture_payload/seed_composite.sql`（3.4 KB）
- `fixture_www/book_a.html`（4.0 KB）
- `fixture_www/book_b.html`（4.0 KB）
- `fixture_www/book_c.html`（4.0 KB）
- `fixture_www/comic/ch0.html`（68 B）
- `fixture_www/comic/ch1.html`（68 B）
- `fixture_www/comic/ch10.html`（69 B）
- `fixture_www/comic/ch11.html`（69 B）
- `fixture_www/comic/ch12.html`（69 B）
- `fixture_www/comic/ch13.html`（69 B）
- `fixture_www/comic/ch14.html`（69 B）
- `fixture_www/comic/ch15.html`（69 B）
- `fixture_www/comic/ch16.html`（69 B）
- `fixture_www/comic/ch17.html`（69 B）
- `fixture_www/comic/ch2.html`（68 B）
- `fixture_www/comic/ch3.html`（68 B）
- `fixture_www/comic/ch4.html`（68 B）
- `fixture_www/comic/ch5.html`（68 B）
- `fixture_www/comic/ch6.html`（68 B）
- `fixture_www/comic/ch7.html`（68 B）
- `fixture_www/comic/ch8.html`（68 B）
- `fixture_www/comic/ch9.html`（68 B）
- `fixture_www/explore.html`（16.4 KB）
- `fixture_www/login.html`（243 B）
- `fixture_www/rss_article1.html`（276 B）
- `fixture_www/rss_article2.html`（276 B）
- `fixture_www/rss_article3.html`（276 B）
- `fixture_www/source.json`（241 B）
- `fixture_www/video.mp4`（1.0 KB）
- `scripts/dev.py`（3.6 KB）
- `scripts/make_composite.py`（3.3 KB）
- `scripts/make_fixture.py`（4.9 KB）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×6（1.7 MB），最大 `logcat/flutter_test_all.log`（888.8 KB）
- 日志型 `.txt` ×1（9.5 KB），最大 `data/crash_log_2245.txt`（9.5 KB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261104`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 342 文件 = 新归档 331 + 已在库 0 + 同目录重复 4 + 丢弃日志 7 + 排除 0，逐项相等。
