# `batch27_29_acceptance_20261028` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261028_batch2729`（采集 2026-10-28 ~ 2026-10-28）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 8 行（判定「需先归档」；A.2 口径 14.0 MB / 108 文件 / 唯一非日志副本 82）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261028_BATCH2729.md`
> 验收范围：批 27~29 合并设备验收（含 DB 升级前后快照）

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 94 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 1 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 1 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 6 | 72.3 KB，原始过程日志 |
| 丢弃日志型 `.txt` | 6 | 3.1 MB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **108** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 70 | 70 | PASS（一致） |
| `.xml` uiautomator | 3 | 3 | PASS（一致） |

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
| `14` | 1 |
| （其余 55 个前缀） | 55 |

语义树按目录分布：`db` 2、`screenshots` 1。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.txt` | 10 | 2.3 KB |
| `.db` | 5 | 1.4 MB |
| `.json` | 3 | 26.5 KB |
| `.py` | 2 | 9.1 KB |
| `.db-shm` | 1 | 32.0 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `backup/backup_v5_assertions.txt`（1.0 KB）
- `backup/backup_v5_with_memo_assertions.txt`（159 B）
- `backup/legado_backup_v5_20261028.json`（9.5 KB）
- `backup/legado_backup_v5_with_memo.json`（9.6 KB）
- `backup/qa_v4_legacy_backup.json`（7.5 KB）
- `db/_probe.db`（268.0 KB）
- `db/legado_after_reading.db`（284.0 KB）
- `db/legado_after_upgrade.db`（284.0 KB）
- `db/legado_migrated_clean.db`（284.0 KB）
- `db/legado_pre_upgrade_2.0.401.db-shm`（32.0 KB）
- `db/scene2_read_record_delta.txt`（383 B）
- `db/scene3_restore_v4_db.txt`（189 B）
- `db/scene3_restore_v5_db.txt`（216 B）
- `db/scene4_rss_clear_db.txt`（37 B）
- `db/scene6_book_source_rule_fields.txt`（108 B）
- `db/scene6_rss_next_content_url.txt`（49 B）
- `db/scene8_cleanup_verify.txt`（17 B）
- `db/scene_seed_after_upgrade.txt`（118 B）
- `db/seed_after_upgrade.py`（4.3 KB）
- `db/seed_v112.db`（268.0 KB）
- `mock/mock_booksource.py`（4.8 KB）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×6（72.3 KB），最大 `logcat/rust_build.log`（56.4 KB）
- 日志型 `.txt` ×6（3.1 MB），最大 `logcat/logcat_full_session.txt`（2.9 MB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261028_batch2729`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 108 文件 = 新归档 94 + 已在库 1 + 同目录重复 1 + 丢弃日志 12 + 排除 0，逐项相等。
