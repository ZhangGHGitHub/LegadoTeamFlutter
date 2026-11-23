# `batch18_acceptance_20261027_remote_book` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261027_remote_book`（采集 2026-10-27 ~ 2026-10-27）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 6 行（判定「需先归档」；A.2 口径 10.8 MB / 113 文件 / 唯一非日志副本 80）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261027_18_REMOTE_BOOK.md`
> 验收范围：批 18 远程书籍（WebDAV）验收

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 97 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 0 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 9 | 28.6 KB，原始过程日志 |
| 丢弃日志型 `.txt` | 7 | 643.7 KB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **113** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 73 | 73 | PASS（一致） |
| `.xml` uiautomator | 6 | 6 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `10` | 2 |
| `11` | 2 |
| `12` | 2 |
| `13` | 2 |
| `14` | 2 |
| `15` | 2 |
| `20` | 2 |
| `21` | 2 |
| `23` | 2 |
| `24` | 2 |
| `25` | 2 |
| `26` | 2 |
| `27` | 2 |
| `30` | 2 |
| `31` | 2 |
| （其余 38 个前缀） | 43 |

语义树按目录分布：`evidence` 4、`verify2` 2。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.txt` | 11 | 3.5 KB |
| `.py` | 2 | 19.6 KB |
| `.zip` | 1 | 272 B |
| `(无扩展名)` | 1 | 6.0 KB |
| `.c` | 1 | 405 B |
| `.json` | 1 | 641 B |
| `.sql` | 1 | 372 B |

文件清单（完整去向见 `MANIFEST.txt`）：

- `evidence/28_runtime_handle_bug_repro.txt`（80 B）
- `evidence/db_dav_books.txt`（166 B）
- `evidence/db_servers_final.txt`（323 B）
- `mock_webdav.py`（9.7 KB）
- `servers_restore_test.zip`（272 B）
- `setuid_helper`（6.0 KB）
- `setuid_helper.c`（405 B）
- `v3_legacy_remote.json`（641 B）
- `verify2/01_p0_red_before_fix.txt`（1.0 KB）
- `verify2/02_p0_green_after_fix.txt`（323 B）
- `verify2/07_installed_so_identity.txt`（210 B）
- `verify2/16_db_origin_custom.txt`（120 B）
- `verify2/22_db_origin_custom_fixed.txt`（199 B）
- `verify2/29_db_origin_default.txt`（382 B）
- `verify2/34_db_servers_after_empty_save.txt`（201 B）
- `verify2/41_install_identity_final.txt`（471 B）
- `verify2/inject_servers.sql`（372 B）
- `verify2/mock_webdav.py`（10.0 KB）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×9（28.6 KB），最大 `verify2/05_build_android_so.log`（8.5 KB）
- 日志型 `.txt` ×7（643.7 KB），最大 `verify2/04_flutter_test_all.txt`（542.4 KB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261027_remote_book`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 113 文件 = 新归档 97 + 已在库 0 + 同目录重复 0 + 丢弃日志 16 + 排除 0，逐项相等。
