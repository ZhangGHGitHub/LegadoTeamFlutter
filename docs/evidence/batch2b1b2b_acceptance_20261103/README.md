# `batch2b1b2b_acceptance_20261103` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261103_batch2b1b2b`（采集 2026-11-03 ~ 2026-11-03）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 34 行（判定「需先归档」；A.2 口径 58.2 MB / 379 文件 / 唯一非日志副本 145）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261103_BATCH2B1B2B.md`
> 验收范围：批 2b-1b-2b 设备验收（水波纹帧序列 + 12MP 大图）

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 371 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 1 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 5 | 901.4 KB，原始过程日志 |
| 丢弃日志型 `.txt` | 2 | 214 B，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **379** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 194 | 194 | PASS（一致） |
| `.xml` uiautomator | 154 | 154 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `p2` | 30 |
| `s1` | 25 |
| `n3` | 16 |
| `qa` | 10 |
| `b1` | 10 |
| `s6` | 10 |
| `s8` | 7 |
| `s4` | 6 |
| `s7` | 5 |
| `f018` | 3 |
| `f021` | 3 |
| `f024` | 3 |
| `f027` | 3 |
| `f030` | 3 |
| `f033` | 3 |
| （其余 39 个前缀） | 57 |

语义树按目录分布：`data` 154。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.txt` | 13 | 18.4 KB |
| `.py` | 4 | 18.1 KB |
| `.mp4` | 3 | 1.1 MB |
| `.jpg` | 2 | 1.0 MB |
| `.json` | 1 | 10.8 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `data/apk_sha256.txt`（112 B）
- `data/apk_sha256_installed.txt`（163 B）
- `data/backup_s1.json`（10.8 KB）
- `data/mem_baseline_small9.txt`（3.0 KB）
- `data/mem_big12mp9.txt`（3.0 KB）
- `data/mem_big12mp_jpg.txt`（3.0 KB）
- `data/mem_huge35mp9.txt`（3.0 KB）
- `data/mem_item_big12mp9.txt`（3.0 KB）
- `data/mem_item_huge35mp9.txt`（3.0 KB）
- `data/qa_ripple.mp4`（336.8 KB）
- `data/qa_ripple2.mp4`（384.3 KB）
- `data/qa_ripple3.mp4`（360.8 KB）
- `data/s4_font13_counts.txt`（9 B）
- `data/s4_font16_counts.txt`（15 B）
- `data/s7_stability_counts.txt`（12 B）
- `data/version_final.txt`（69 B）
- `fixtures/qa_big12mp.jpg`（1016.6 KB）
- `fixtures/qa_book.txt`（191 B）
- `fixtures/qa_plain.jpg`（9.2 KB）
- `scripts/make_fixtures.py`（6.2 KB）
- `scripts/qa.py`（4.4 KB）
- `scripts/set_large.py`（4.4 KB）
- `scripts/ui.py`（3.2 KB）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×5（901.4 KB），最大 `logcat/full_tests.log`（864.8 KB）
- 日志型 `.txt` ×2（214 B），最大 `data/so_info.txt`（119 B）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261103_batch2b1b2b`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 379 文件 = 新归档 371 + 已在库 0 + 同目录重复 1 + 丢弃日志 7 + 排除 0，逐项相等。
