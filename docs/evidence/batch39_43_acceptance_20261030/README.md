# `batch39_43_acceptance_20261030` —— 设备验收证据归档

> 归档日期：2026-11-23 ｜ 来源目录：`tmp_debug/device_acceptance_20261030_batch39_43`（采集 2026-10-30 ~ 2026-10-30）
> 分类依据：`docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.2 第 16 行（判定「需先归档」；A.2 口径 38.5 MB / 908 文件 / 唯一非日志副本 50）
> 对应验收报告：`docs/DEVICE_ACCEPTANCE_20261030_BATCH39_43.md`
> 验收范围：批 39~43 合并验收（773 个 uiautomator dump 语义树为主要证据）

## 一、归档内容

| 类别 | 数量 | 说明 |
|---|---|---|
| 新归档文件 | 874 | 本次写入本目录（含全部 `.png`/`.xml`） |
| 非承重证据已在库（SHA-256 命中） | 0 | `.db`/`.json`/`.sql` 等已在 `docs/evidence/**` 或 `docs/materials_*/**`，未重复落盘；原路径见 `MANIFEST.txt` |
| 非承重证据同目录重复 | 1 | 内容相同（如同一夹具在根与 `fixtures/` 各一份），只留一份 |
| 丢弃 `.log` | 26 | 16.6 MB，原始过程日志 |
| 丢弃日志型 `.txt` | 7 | 3.2 MB，logcat/构建/测试过程输出 |
| 排除 `*/target/*` | 0 | 0 B，可 `cargo build` 重建 |
| 排除零字节 `nul` | 0 | Windows 重定向残留，`.gitignore` 已忽略 |
| **源目录文件合计** | **908** | 校验：以上各类之和严格相等 |

## 二、承重证据：截图与语义树

| 项 | 源目录 | 本目录落盘 | 数量校验 |
|---|---|---|---|
| `.png` 截图 | 49 | 49 | PASS（一致） |
| `.xml` uiautomator | 773 | 773 | PASS（一致） |

承重证据（`.png`/`.xml`）**一律全量落盘、不做内容去重**，因此本目录内数量与源目录严格相等 —— 这是阶段 2 的硬校验条件。部分截图此前已单独存于 `docs/materials_*/`（如 `materials_1108/` 下的 `b2b2b_*.png`），本目录仍保留一份副本，使本目录自足可查；Git 按内容寻址，重复字节不额外占用对象库。

截图场景（按文件名前缀归类）：

| 场景前缀 | 张数 |
|---|---|
| `27e` | 2 |
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
| （其余 33 个前缀） | 33 |

语义树按目录分布：`data` 773。

## 三、随同归档的其他唯一副本

| 类型 | 数量 | 字节 |
|---|---|---|
| `.sh` | 37 | 8.5 KB |
| `.json` | 7 | 21.4 KB |
| `.py` | 3 | 4.0 KB |
| `.txt` | 3 | 6.8 KB |
| `.zip` | 1 | 1.1 KB |
| `.epub` | 1 | 1.3 KB |

文件清单（完整去向见 `MANIFEST.txt`）：

- `check_dump.py`（296 B）
- `data/config2.json`（8.4 KB）
- `data/config_txt_toc_rules.json`（8.4 KB）
- `data/qa41_backup.zip`（1.1 KB）
- `data/qa42_dead.json`（419 B）
- `data/qa42_sources.json`（1.4 KB）
- `data/qa42_sources2.json`（1.0 KB）
- `data/qa42_sources3.json`（1.0 KB）
- `data/qa43_block_source.json`（672 B）
- `data/qa43_non_txt.epub`（1.3 KB）
- `data/qa43_rule_book.txt`（6.7 KB）
- `data/t0.txt`（12 B）
- `data/t1.txt`（12 B）
- `db41.sh`（219 B）
- `dbbooks.sh`（150 B）
- `dbcache.sh`（266 B）
- `dbcache2.sh`（171 B）
- `dbcache3.sh`（157 B）
- `dbcheck.sh`（307 B）
- `dbchk.sh`（223 B）
- `dbck2.sh`（264 B）
- `dbck3.sh`（189 B）
- `dbckpt.sh`（161 B）
- `dbclean.sh`（216 B）
- `dbclean2.sh`（207 B）
- `dbclean3.sh`（162 B）
- `dbcleanup.sh`（368 B）
- `dbcnt.sh`（131 B）
- `dbcols.sh`（129 B）
- `dbexplore.sh`（193 B）
- `dbfix.sh`（603 B）
- `dbfix2.sh`（573 B）
- `dbhex.sh`（192 B）
- `dbpref.sh`（162 B）
- `dbpref2.sh`（160 B）
- `dbpref_final.sh`（211 B）
- `dbq.sh`（97 B）
- `dbq43.sh`（373 B）
- `dbq_toc.sh`（191 B）
- `dbrule.sh`（311 B）
- `dbseed_book.sh`（523 B）
- `dbsrc.sh`（246 B）
- `dbsrc2.sh`（194 B）
- `dbsrc3.sh`（184 B）
- `dbsrc4.sh`（213 B）
- `dbsrc5.sh`（246 B）
- `dbsrc6.sh`（190 B）
- `dbsrc7.sh`（159 B）
- `dbtbl.sh`（157 B）
- `dbweb.sh`（249 B）
- `server/mock2.py`（1.8 KB）
- `server/mock2_log.py`（2.0 KB）

## 四、丢弃明细

按附录 A.1 口径，`.log`/`.txt` 原始过程日志不入库（验收结论已由报告固化）；文件名与字节数逐条记录于 `MANIFEST.txt` 的 `discard-*` 行。

- `.log` ×26（16.6 MB），最大 `logcat/full_session.log`（2.3 MB）
- 日志型 `.txt` ×7（3.2 MB），最大 `logcat/logcat_apply2.txt`（1.7 MB）

> 说明：`fixtures/` 下的 `.txt` 与 `data/qa*.txt` 等**测试载荷**（小说正文、GBK 编码样本、种子文本）不属日志，已随同归档，未丢弃。

## 五、来源追溯与处置

- 归档后已删除原目录 `tmp_debug/device_acceptance_20261030_batch39_43`（本 README + `MANIFEST.txt` 为删除前完整性证明）。
- 完整性校验：源 908 文件 = 新归档 874 + 已在库 0 + 同目录重复 1 + 丢弃日志 33 + 排除 0，逐项相等。
