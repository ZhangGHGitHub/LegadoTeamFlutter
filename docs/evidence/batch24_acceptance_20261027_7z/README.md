# `batch24_acceptance_20261027_7z` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261027_7z`（采集 2026-10-27 ~ 2026-10-28）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 3 行（判定「需先归档」；A.2 口径 21.4 MB / 228 文件 / 唯一非日志副本 72）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261027_24_7Z.md`
> 验收范围：批 24 7z 解压能力验收（含 7z 炸弹/路径穿越/加密/分卷夹具）

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 108 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 2 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 12 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 7 | 874.5 KB，原始过程日志 |
| 丢弃日志型 `.txt` | 38 | 1.2 MB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 61 | 13.3 MB，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **228** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 37 | 37 | PASS（一致） |
| `.xml` uiautomator | 36 | 36 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `01` | 2 |
| `02` | 2 |
| `03` | 2 |
| `04` | 2 |
| `05` | 2 |
| `06` | 2 |
| `07` | 2 |
| `00` | 1 |
| `02b` | 1 |
| `02c` | 1 |
| `02d` | 1 |
| `02e` | 1 |
| `08` | 1 |
| `09` | 1 |
| `10` | 1 |
| （其余 15 个前缀） | 15 |

语义树按目录分布：`screens` 33、`verify2` 2、`fixtures_src/epub_src/META-INF` 1。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.txt` | 12 | 1.9 KB |
| `.7z` | 9 | 308.3 KB |
| `.lock` | 2 | 60.4 KB |
| `.toml` | 2 | 364 B |
| `.rs` | 2 | 1.8 KB |
| `.zip` | 1 | 195 B |
| `.py` | 1 | 5.9 KB |
| `.orig` | 1 | 268.0 KB |
| `(无扩展名)` | 1 | 20 B |
| `.xhtml` | 1 | 197 B |
| `.opf` | 1 | 481 B |
| `.epub` | 1 | 1.4 KB |
| `.md` | 1 | 50 B |

文件清单（完整去向见 `MANIFEST.txt`）：

- `bomb.7z`（305.3 KB）
- `corrupt.7z`（64 B）
- `corrupt_crc.7z`（182 B）
- `db/legado.db.orig`（268.0 KB）
- `encrypted.7z`（201 B）
- `fixture_gen/Cargo.lock`（4.9 KB）
- `fixture_gen/Cargo.toml`（171 B）
- `fixture_gen/src/main.rs`（747 B）
- `fixtures_src/crc_payload.txt`（60 B）
- `fixtures_src/epub_src/OEBPS/chapter1.xhtml`（197 B）
- `fixtures_src/epub_src/OEBPS/content.opf`（481 B）
- `fixtures_src/epub_src/mimetype`（20 B）
- `fixtures_src/中文目录/book.epub`（1.4 KB）
- `fixtures_src/中文目录/readme.md`（50 B）
- `fixtures_src/中文目录/嵌套/novel.txt`（137 B）
- `nested_py7zr.7z`（225 B）
- `nested_src/dir1/one.txt`（18 B）
- `nested_src/dir2/two.txt`（18 B）
- `normal.7z`（1022 B）
- `normal_py7zr.7z`（1.0 KB）
- `probe/Cargo.lock`（55.5 KB）
- `probe/Cargo.toml`（193 B）
- `probe/src/main.rs`（1.1 KB）
- `regression.zip`（195 B）
- `surface.7z`（189 B）
- `traversal.7z`（186 B）
- `ui.py`（5.9 KB）
- `verify2/apk_sha256.txt`（112 B）
- `verify2/cleanup.txt`（331 B）
- `verify2/content_and_cleanliness.txt`（485 B）
- `verify2/db_books.txt`（52 B）
- `verify2/import_dir.txt`（36 B）
- `verify2/install_apk.txt`（73 B）
- `verify2/normal_import_dir.txt`（235 B）
- `verify2/so_sha256.txt`（410 B）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×7（874.5 KB），最大 `verify2/flutter_test.log`（587.1 KB）
- 日志型 `.txt` ×38（1.2 MB），最大 `logs/logcat_all.txt`（1.0 MB）
- 构建产物 `*/target/*` ×61（13.3 MB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261027_7z`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 228 文件 = 新归档 108 + 已在库 2 + 同目录重复 12 + 丢弃日志 45 + 排除 61，逐项相等。
