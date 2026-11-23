# `batch2b2a_reverify_acceptance_20261103` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261103_reverify`（采集 2026-11-03 ~ 2026-11-03）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 41 行（判定「可删」；A.2 口径 9.6 MB / 158 文件 / 唯一非日志副本 2）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261102_BATCH2B2A.md`
> 验收范围：批 2b-2a 复验；无截图，147 个 xml 语义树此前未归档

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 150 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 0 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 6 | 6.1 MB，原始过程日志 |
| 丢弃日志型 `.txt` | 2 | 724.1 KB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **158** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 0 | 0 | PASS（一致） |
| `.xml` uiautomator | 147 | 147 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

语义树按目录分布：`data` 147。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.py` | 2 | 7.6 KB |
| `.txt` | 1 | 153 B |

文件清单（完整去向见 `MANIFEST.txt`）：

- `data/version_final.txt`（153 B）
- `scripts/open_nav_sheet.py`（3.2 KB）
- `scripts/ui.py`（4.3 KB）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×6（6.1 MB），最大 `logcat/full_buffer.log`（4.5 MB）
- 日志型 `.txt` ×2（724.1 KB），最大 `logcat/crash_buffer.txt`（723.6 KB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261103_reverify`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 158 文件 = 新归档 150 + 已在库 0 + 同目录重复 0 + 丢弃日志 8 + 排除 0，逐项相等。
- 附录 A.3 判定为「可删」（截图已 100% 命中归档）；本次复核确认截图字节均在 `docs/materials_*/` 中，同时把此前**从未入库的 147 个 `.xml` 语义树**补归档，再删除原目录。
