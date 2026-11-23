# `batch9b4_acceptance_20261031` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261031_batch9b4`（采集 2026-10-31 ~ 2026-10-31）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 23 行（判定「需先归档」；A.2 口径 4.2 MB / 128 文件 / 唯一非日志副本 7）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261031_BATCH9B4.md`
> 验收范围：批 9b-4 设备验收（全局 UA）

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 116 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 0 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 11 | 829.1 KB，原始过程日志 |
| 丢弃日志型 `.txt` | 1 | 2.7 KB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **128** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 16 | 16 | PASS（一致） |
| `.xml` uiautomator | 92 | 92 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `00` | 1 |
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
| `99` | 1 |
| （其余 1 个前缀） | 1 |

语义树按目录分布：`data` 92。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.json` | 4 | 7.0 KB |
| `.txt` | 2 | 5.9 KB |
| `.py` | 2 | 9.6 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `data/backup_orig.json`（2.9 KB）
- `data/prefs_db_evidence_9b4.txt`（2.3 KB）
- `data/qa9b4_backup_restoreUA.json`（2.1 KB）
- `data/qa9b4_rss_sources.json`（371 B）
- `data/qa9b4_sources.json`（1.7 KB）
- `data/ua_evidence_9b4.txt`（3.7 KB）
- `server/mock9b4.py`（5.8 KB）
- `server/qa_ui.py`（3.7 KB）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×11（829.1 KB），最大 `logcat/full_session_9b4.log`（734.3 KB）
- 日志型 `.txt` ×1（2.7 KB），最大 `data/build_meta_9b4.txt`（2.7 KB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261031_batch9b4`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 128 文件 = 新归档 116 + 已在库 0 + 同目录重复 0 + 丢弃日志 12 + 排除 0，逐项相等。
