# `batch2b1b2a_saf_acceptance_20261102` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261102_reverify_saf`（采集 2026-11-02 ~ 2026-11-02）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 33 行（判定「需先归档」；A.2 口径 83.1 MB / 94 文件 / 唯一非日志副本 7）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261102_BATCH2B1B2A.md`
> 验收范围：批 2b-1b-2a SAF 复验；体积主要为 48MB/33MB 超大图压测夹具（按规则随同归档）

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 82 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 2 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 5 | 2.9 MB，原始过程日志 |
| 丢弃日志型 `.txt` | 5 | 149.0 KB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **94** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 5 | 5 | PASS（一致） |
| `.xml` uiautomator | 67 | 67 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `saf` | 5 |

语义树按目录分布：`data` 67。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.txt` | 8 | 11.6 KB |
| `.sql` | 1 | 232 B |
| `.jpg` | 1 | 184.2 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `cleanup_media.sql`（232 B）
- `data/apk_sha256.txt`（173 B）
- `data/download_after_cleanup.txt`（16 B）
- `data/download_old_entries.txt`（157 B）
- `data/scene1_files.txt`（485 B）
- `data/scene5_files.txt`（110 B）
- `data/theme_files_both.txt`（219 B）
- `data/ui_after_red_reselect.txt`（10.4 KB）
- `data/version.txt`（69 B）
- `fixtures/saf_12mp_green.jpg`（184.2 KB）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×5（2.9 MB），最大 `logcat/session_full.log`（2.1 MB）
- 日志型 `.txt` ×5（149.0 KB），最大 `logcat/crash_buffer.txt`（148.0 KB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261102_reverify_saf`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 94 文件 = 新归档 82 + 已在库 0 + 同目录重复 2 + 丢弃日志 10 + 排除 0，逐项相等。
- 附录 A.6 体积大头目录：99.4MB logcat / 48MB+33MB 超大图 / 5.7MB logcat / 5.3MB SQL 等。其中 `.log` 已丢弃；超大 `.png` 与 `.sql` 属可再生成夹具，但为满足「源目录 png/xml 数量与归档数量一致」的硬校验，超大图仍随同归档。
