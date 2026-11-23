# `batch38_acceptance_20261029` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261029_batch38`（采集 2026-10-30 ~ 2026-10-30）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 14 行（判定「需先归档」；A.2 口径 19.6 MB / 277 文件 / 唯一非日志副本 121）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261029_BATCH38.md`
> 验收范围：批 38 设备验收（导入批量/BOM/去重）

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 267 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 2 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 3 | 13.9 KB，原始过程日志 |
| 丢弃日志型 `.txt` | 5 | 3.7 MB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **277** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 108 | 108 | PASS（一致） |
| `.xml` uiautomator | 147 | 147 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `01` | 2 |
| `02` | 2 |
| `03` | 2 |
| `04` | 2 |
| `05` | 2 |
| `07` | 2 |
| `08` | 2 |
| `09` | 2 |
| `10` | 2 |
| `12` | 2 |
| `13` | 2 |
| `14` | 2 |
| `16` | 2 |
| `17` | 2 |
| `18` | 2 |
| （其余 77 个前缀） | 78 |

语义树按目录分布：`shots` 91、`prefs` 33、`verify2/shots` 17、`verify2/prefs` 4、`pre_upgrade` 1、`restore` 1。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.json` | 5 | 22.5 KB |
| `.sh` | 2 | 719 B |
| `.py` | 2 | 17.1 KB |
| `.txt` | 1 | 1.1 KB |
| `.sql` | 1 | 458 B |
| `.db` | 1 | 292.0 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `backup_roundtrip.json`（6.7 KB）
- `cap.sh`（533 B）
- `drive.py`（9.1 KB）
- `export_QA38_BOM.json`（522 B）
- `pre_upgrade/legado.db`（292.0 KB）
- `qa38.py`（8.0 KB）
- `qa38_book.txt`（1.1 KB）
- `qa38_import_bom.json`（537 B）
- `qa38_import_dup.json`（536 B）
- `qa38_import_many.json`（14.2 KB）
- `seed_qa38.sql`（458 B）
- `ui.sh`（186 B）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×3（13.9 KB），最大 `build_flutter_apk.log`（6.5 KB）
- 日志型 `.txt` ×5（3.7 MB），最大 `logcat/logcat_session.txt`（3.0 MB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261029_batch38`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 277 文件 = 新归档 267 + 已在库 0 + 同目录重复 2 + 丢弃日志 8 + 排除 0，逐项相等。
