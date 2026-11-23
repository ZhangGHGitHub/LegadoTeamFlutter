# `batch21_acceptance_20261027_rss_bridge` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261027_rss_bridge`（采集 2026-10-27 ~ 2026-10-27）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 7 行（判定「需先归档」；A.2 口径 8.9 MB / 106 文件 / 唯一非日志副本 71）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261027_21_RSS_BRIDGE.md`
> 验收范围：批 21 RSS 桥接验收

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 85 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 2 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 4 | 17.2 KB，原始过程日志 |
| 丢弃日志型 `.txt` | 15 | 2.1 MB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **106** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 51 | 51 | PASS（一致） |
| `.xml` uiautomator | 14 | 14 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `00` | 2 |
| `01` | 2 |
| `02` | 2 |
| `04` | 2 |
| `05` | 2 |
| `06` | 2 |
| `07` | 2 |
| `08` | 2 |
| `09` | 2 |
| `10` | 2 |
| `11` | 2 |
| `12` | 2 |
| `13` | 2 |
| `14` | 2 |
| `15` | 2 |
| （其余 21 个前缀） | 21 |

语义树按目录分布：`verify2/screens` 13、`screens` 1。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.sql` | 8 | 15.1 KB |
| `.py` | 3 | 19.3 KB |
| `.txt` | 2 | 2.1 KB |
| `.jsonl` | 2 | 30.5 KB |
| `.js` | 2 | 24.1 KB |
| `.json` | 2 | 138 B |
| `.orig` | 1 | 268.0 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `db/gen_fixtures.py`（6.2 KB）
- `db/legado.db.orig`（268.0 KB）
- `db/qa_sources_runtime_dump.txt`（1.9 KB）
- `db/seed_book.sql`（1.1 KB）
- `db/seed_sources.sql`（6.8 KB）
- `db/update_log.sql`（291 B）
- `db/update_log2.sql`（392 B）
- `db/update_log3.sql`（716 B）
- `db/update_log4.sql`（152 B）
- `db/update_probe.sql`（1.1 KB）
- `mock/mock_server.py`（7.3 KB）
- `mock/requests.jsonl`（22.0 KB）
- `verify2/gen_fixtures_verify2.py`（5.8 KB）
- `verify2/mock/requests.jsonl`（8.5 KB）
- `verify2/red_green_sync_shim.txt`（177 B）
- `verify2/seed_verify2.sql`（4.6 KB）
- `verify2/sync_shim_after.js`（12.3 KB）
- `verify2/sync_shim_after.out.json`（114 B）
- `verify2/sync_shim_before.js`（11.8 KB）
- `verify2/sync_shim_before.out.json`（24 B）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×4（17.2 KB），最大 `logs/build_rust.log`（7.9 KB）
- 日志型 `.txt` ×15（2.1 MB），最大 `logs/logcat_all.txt`（1.3 MB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261027_rss_bridge`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 106 文件 = 新归档 85 + 已在库 0 + 同目录重复 2 + 丢弃日志 19 + 排除 0，逐项相等。
