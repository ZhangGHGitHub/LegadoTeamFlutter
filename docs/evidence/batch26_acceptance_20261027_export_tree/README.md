# `batch26_acceptance_20261027_export_tree` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261027_export_tree`（采集 2026-10-28 ~ 2026-10-28）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 5 行（判定「需先归档」；A.2 口径 8.6 MB / 122 文件 / 唯一非日志副本 49）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261027_26_EXPORT_TREE.md`
> 验收范围：批 26 导出目录树/SAF 目录选择验收

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 94 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 4 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 2 | 12.9 KB，原始过程日志 |
| 丢弃日志型 `.txt` | 22 | 3.9 MB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **122** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 42 | 42 | PASS（一致） |
| `.xml` uiautomator | 41 | 41 | PASS（一致） |

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
| `08` | 2 |
| `00` | 1 |
| `09` | 1 |
| `10` | 1 |
| `11` | 1 |
| `12` | 1 |
| `13` | 1 |
| `14` | 1 |
| （其余 19 个前缀） | 19 |

语义树按目录分布：`screens` 38、`logs` 3。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.txt` | 8 | 6.5 KB |
| `.json` | 2 | 2.1 KB |
| `.py` | 1 | 5.9 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `logs/d1_booksource_first.json`（1.7 KB）
- `logs/d7_highlight_tree.json`（397 B）
- `ui.py`（5.9 KB）
- `verify2/apk_sha256.txt`（112 B）
- `verify2/install_apk.txt`（73 B）
- `verify2/launch.txt`（82 B）
- `verify2/p2_1_clear_tree_release.txt`（3.4 KB）
- `verify2/p2_3_restart_pid.txt`（161 B）
- `verify2/p2_3_second_save.txt`（1.5 KB）
- `verify2/uri_grants_after_restart.txt`（663 B）
- `verify2/zero_after_all.txt`（574 B）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×2（12.9 KB），最大 `logs/build_apk.log`（6.4 KB）
- 日志型 `.txt` ×22（3.9 MB），最大 `logs/logcat_final2.txt`（1.5 MB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261027_export_tree`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 122 文件 = 新归档 94 + 已在库 0 + 同目录重复 4 + 丢弃日志 24 + 排除 0，逐项相等。
