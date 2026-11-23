# `batch17_acceptance_20261027_backup_pwd` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261027_backup_pwd`（采集 2026-10-27 ~ 2026-10-27）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 4 行（判定「需先归档」；A.2 口径 15.4 MB / 176 文件 / 唯一非日志副本 58）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261027_17_BACKUP_PASSWORD.md`
> 验收范围：批 17 备份加密口令验收

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 158 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 4 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 4 | 6.8 KB，原始过程日志 |
| 丢弃日志型 `.txt` | 10 | 2.5 MB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **176** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 36 | 36 | PASS（一致） |
| `.xml` uiautomator | 90 | 90 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `00` | 1 |
| `01` | 1 |
| `03` | 1 |
| `06` | 1 |
| `07` | 1 |
| `100` | 1 |
| `103` | 1 |
| `105` | 1 |
| `109` | 1 |
| `10` | 1 |
| `110` | 1 |
| `117` | 1 |
| `11` | 1 |
| `127` | 1 |
| `128` | 1 |
| （其余 21 个前缀） | 21 |

语义树按目录分布：`screens` 87、`logs` 2、`.` 1。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.txt` | 10 | 13.9 KB |
| `.b64` | 6 | 544 B |
| `.json` | 5 | 4.1 MB |
| `.py` | 4 | 4.0 KB |
| `.zip` | 4 | 1.1 MB |
| `.sh` | 3 | 4.1 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `backup_own_1793065958719.json`（4.1 MB）
- `check_backup_sensitive.py`（2.4 KB）
- `db/baseline_before_install.txt`（13.0 KB）
- `db/s1_after.txt`（158 B）
- `db/s1_before.txt`（98 B）
- `db/s2_after_empty.txt`（53 B）
- `db/s3_after_wrong.txt`（111 B）
- `db/s4_after_correct.txt`（260 B）
- `db/s4b_after_repeat.txt`（110 B）
- `db/s5_after_cancel.txt`（86 B）
- `db/s6_after_corrupt.txt`（53 B）
- `db/s9_after.txt`（74 B）
- `list_zip.py`（303 B）
- `make_packages.sh`（2.9 KB）
- `make_zip.py`（301 B）
- `packages/backup_accept_A.zip`（506 B）
- `packages/backup_accept_B.zip`（909 B）
- `packages/backup_accept_C.zip`（164 B）
- `packages/cookies_B.json.b64`（88 B）
- `packages/original_real_backup.zip`（1.1 MB）
- `packages/real_servers.b64`（24 B）
- `packages/runtime_B.json.b64`（88 B）
- `packages/servers_A.json.b64`（152 B）
- `packages/servers_B.json.b64`（152 B）
- `packages/servers_C_truncated.b64`（40 B）
- `parse_ui.py`（1.0 KB）
- `plain/bookSource_accept.json`（181 B）
- `plain/cookies_accept.json`（63 B）
- `plain/runtime_accept.json`（58 B）
- `plain/servers_accept.json`（108 B）
- `shot.sh`（584 B）
- `ui.sh`（701 B）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×4（6.8 KB），最大 `logs/build_rust_android.log`（3.1 KB）
- 日志型 `.txt` ×10（2.5 MB），最大 `logs/full_logcat_final.txt`（1.7 MB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261027_backup_pwd`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 176 文件 = 新归档 158 + 已在库 0 + 同目录重复 4 + 丢弃日志 14 + 排除 0，逐项相等。
