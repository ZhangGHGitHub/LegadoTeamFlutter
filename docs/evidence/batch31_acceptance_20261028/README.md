# `batch31_acceptance_20261028` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261028_batch31`（采集 2026-10-29 ~ 2026-10-29）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 9 行（判定「需先归档」；A.2 口径 13.7 MB / 85 文件 / 唯一非日志副本 60）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261028_BATCH31.md`
> 验收范围：批 31 设备验收（阅读设置/Web 保存书）

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 70 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 4 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 5 | 3.3 MB，原始过程日志 |
| 丢弃日志型 `.txt` | 6 | 46.3 KB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **85** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 52 | 52 | PASS（一致） |
| `.xml` uiautomator | 1 | 1 | PASS（一致） |

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
| `08b` | 1 |
| `09` | 1 |
| `10` | 1 |
| `10a` | 1 |
| `11` | 1 |
| `12` | 1 |
| （其余 37 个前缀） | 37 |

语义树按目录分布：`prefs` 1。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.txt` | 9 | 2.1 KB |
| `.json` | 4 | 13.4 KB |
| `.py` | 2 | 8.4 KB |
| `.db` | 2 | 604.0 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `backup/backup_prefs_assertions.txt`（687 B）
- `backup/legado_backup_batch31.json`（9.1 KB）
- `db/legado_pre_upgrade_2.0.406.db`（284.0 KB）
- `db/scene1_counts_vs_shelf.txt`（263 B）
- `db/scene2_baseline_readconfig.txt`（73 B）
- `db/scene2_readconfig_after_toggle.txt`（230 B）
- `db/scene3_readconfig_double_on.txt`（229 B）
- `db/scene3_readconfig_reverseToc_only.txt`（230 B）
- `db/scene5_after_web_save.txt`（247 B）
- `db/scene7_cleanup_verify.txt`（56 B）
- `db/scene7_config_after_cleanup.txt`（168 B）
- `db/seed_batch31.db`（320.0 KB）
- `seed_batch31.py`（4.6 KB）
- `ui.py`（3.8 KB）
- `web/getBookshelf.json`（3.4 KB）
- `web/saveBook_payload.json`（952 B）
- `web/saveBook_response.json`（42 B）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×5（3.3 MB），最大 `logcat/logcat_cleanup_launch.log`（1.6 MB）
- 日志型 `.txt` ×6（46.3 KB），最大 `logcat/logcat_app_lines.txt`（44.0 KB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261028_batch31`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 85 文件 = 新归档 70 + 已在库 0 + 同目录重复 4 + 丢弃日志 11 + 排除 0，逐项相等。
