# `batch37_acceptance_20261029` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261029_batch37`（采集 2026-10-29 ~ 2026-10-29）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 13 行（判定「需先归档」；A.2 口径 17.1 MB / 181 文件 / 唯一非日志副本 85）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261029_BATCH37.md`
> 验收范围：批 37 设备验收（含编码回归 DB 前后快照）

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 170 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 0 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 3 | 15.9 KB，原始过程日志 |
| 丢弃日志型 `.txt` | 8 | 3.8 MB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **181** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 73 | 73 | PASS（一致） |
| `.xml` uiautomator | 79 | 79 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `01` | 1 |
| `02` | 1 |
| `03` | 1 |
| `04` | 1 |
| `05` | 1 |
| `06` | 1 |
| `07` | 1 |
| `08` | 1 |
| `09` | 1 |
| `10` | 1 |
| `11` | 1 |
| `12` | 1 |
| `13` | 1 |
| `14` | 1 |
| `15` | 1 |
| （其余 58 个前缀） | 58 |

语义树按目录分布：`shots` 75、`restore` 4。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.txt` | 6 | 7.7 KB |
| `.sh` | 3 | 2.8 KB |
| `.py` | 3 | 15.2 KB |
| `.sql` | 2 | 4.2 KB |
| `.epub` | 2 | 2.6 KB |
| `.db` | 2 | 584.0 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `cap.sh`（533 B）
- `data/qa37_dav.epub`（1.2 KB）
- `data/qa37_gbk.txt`（4.5 KB）
- `data/qa37_utf8.epub`（1.5 KB）
- `data/qa37_utf8.txt`（188 B）
- `db_after_charset_regression.txt`（1.3 KB）
- `db_before_charset_regression.txt`（1.3 KB）
- `db_chapters_after.txt`（274 B）
- `db_chapters_before.txt`（182 B）
- `drive.py`（9.1 KB）
- `mock_server.py`（5.5 KB）
- `open_config.sh`（2.1 KB）
- `pre_upgrade_db/legado.db`（292.0 KB）
- `restore/db_after_tests.db`（292.0 KB）
- `seed_batch37.sql`（3.0 KB）
- `seed_source2.sql`（1.2 KB）
- `texts.py`（571 B）
- `ui.sh`（186 B）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×3（15.9 KB），最大 `build_rust.log`（7.5 KB）
- 日志型 `.txt` ×8（3.8 MB），最大 `logcat/logcat_final.txt`（3.4 MB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261029_batch37`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 181 文件 = 新归档 170 + 已在库 0 + 同目录重复 0 + 丢弃日志 11 + 排除 0，逐项相等。
