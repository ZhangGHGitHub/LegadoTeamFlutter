# `batch16_acceptance_20261027` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261027`（采集 2026-10-27 ~ 2026-10-27）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 2 行（判定「需先归档」；A.2 口径 32.6 MB / 407 文件 / 唯一非日志副本 146）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261027_16X.md`
> 验收范围：批 8~16 合并设备验收（备份/恢复扩展、RSS 引擎、直链上传、导出树、关联导入）

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 361 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 10 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 5 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 6 | 20.1 KB，原始过程日志 |
| 丢弃日志型 `.txt` | 25 | 2.1 MB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **407** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 129 | 129 | PASS（一致） |
| `.xml` uiautomator | 186 | 186 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `v2` | 25 |
| `06F` | 13 |
| `probe` | 10 |
| `08H` | 8 |
| `final` | 5 |
| `case3` | 5 |
| `case1` | 4 |
| `01A` | 4 |
| `03C` | 4 |
| `10` | 4 |
| `case2` | 3 |
| `case4` | 3 |
| `02B` | 3 |
| `07G` | 3 |
| `00` | 2 |
| （其余 20 个前缀） | 33 |

语义树按目录分布：`screens` 118、`screens_d1` 43、`.` 25。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.txt` | 33 | 18.8 KB |
| `.json` | 7 | 4.1 MB |
| `.py` | 4 | 15.9 KB |
| `.zip` | 1 | 227 B |
| `.jsonl` | 1 | 6.9 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `BookSource_QA2.json`（2.2 KB）
- `HighlightRules_exported.json`（409 B）
- `backup_v4.json`（4.1 MB）
- `cache_after.txt`（502 B）
- `cache_before.txt`（502 B）
- `d1_download_after.txt`（289 B）
- `d1_download_before.txt`（1.7 KB）
- `d1_download_final.txt`（447 B）
- `d1_download_final_root.txt`（155 B）
- `d1_highlight_legado.json`（409 B）
- `d1_verify2/apk_sha256.txt`（127 B）
- `d1_verify2/apk_sha256_final.txt`（127 B）
- `d1_verify2/apk_sha256_final2.txt`（127 B）
- `d1_verify2/authority_lines.txt`（3.8 KB）
- `d1_verify2/p23_green_after_fix.txt`（145 B）
- `d1_verify2/p23_red_before_fix.txt`（587 B）
- `d1_verify2/p31_green_after_fix.txt`（274 B）
- `d1_verify2/p31_red_before_fix.txt`（365 B）
- `d1_verify3/apk_sha256.txt`（161 B）
- `d1_verify3/apk_sha256_final.txt`（161 B）
- `d1_verify3/ls_download_after_all.txt`（2.6 KB）
- `d1_verify3/ls_download_before.txt`（2.4 KB）
- `d1_verify3/ls_legado_after_case2.txt`（488 B）
- `d1_verify3/ls_legado_after_case3.txt`（634 B）
- `d1_verify3/ls_legado_before.txt`（442 B）
- `d1_verify3/zero_after_all.txt`（401 B）
- `d1_verify3/zero_before_files.txt`（346 B）
- `d1_verify3/zero_before_list.txt`（89 B）
- `d1_verify3/zero_legado_after_all.txt`（111 B）
- `d1_verify3/zero_legado_after_case2.txt`（62 B）
- `db_counts_after_zip_restore.txt`（14 B）
- `db_directlink_rule.txt`（147 B）
- `device_fetch.txt`（1.1 KB）
- `files/2515847fccb8.json`（534 B）
- `files/bf21a9e8fbc5.json`（232 B）
- `files/d07318d784e1.json`（543 B）
- `final_apk_sha256.txt`（161 B）
- `final_env.txt`（312 B）
- `legacy_backup_min.zip`（227 B）
- `mock_server.py`（8.6 KB）
- `ping.txt`（31 B）
- `raw_listen.py`（611 B）
- `req.txt`（61 B）
- `typerule.py`（826 B）
- `ui.py`（5.9 KB）
- `upload_log.jsonl`（6.9 KB）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×6（20.1 KB），最大 `crash_save_local.log`（7.9 KB）
- 日志型 `.txt` ×25（2.1 MB），最大 `flutter_test_full.txt`（524.7 KB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261027`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 407 文件 = 新归档 361 + 已在库 10 + 同目录重复 5 + 丢弃日志 31 + 排除 0，逐项相等。
