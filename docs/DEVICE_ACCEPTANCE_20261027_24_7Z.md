# 批24 7z 解压导入设备验收报告（2026-10-27）

> 范围：外部文件 7z 解压导入（`archive_list_7z_files` / `archive_import_7z`、文件管理器
> VIEW 分流、压缩包导入对话框、限额与路径安全、编码检测）及 zip/RAR/书架/阅读器回归。
> 设备：MuMu「Test测试」实例（Android 15 / x86_64，adbd 以 root 运行）。
>
> 设备端点：`192.168.100.62:5555`（实测在线）
> 源码基线：`master` HEAD `6bb3116613`（`chore: 批24 收尾（2.0.400+401 双日志与计划关闭登记）`）
> 验收时间：2026-10-27 23:18 ~ 23:40（+08:00）
> 证据目录：`tmp_debug/device_acceptance_20261027_7z/`（`.gitignore` 已忽略，不入库）
> 宿主夹具脚本/探针：同目录 `fixtures_src/`、`fixture_gen/`、`probe/`（仅用于构造与根因定位，未改业务代码）

## 一、结论总览

| # | 场景 | 结论 | 关键证据 |
|---|---|---|---|
| 1 | `normal.7z`（7-Zip 生成）列表/多选导入/书架/正文 | **PASS**（py7zr 生成同内容包为 **FAIL**，见缺陷 D1） | `screens/04_s1_normal_list.png`、`06_s1_shelf_after_import.png`、`07_s1_open_novel.png` |
| 2 | 7z 内 TXT 编码检测 | **PASS**（`编码: utf-8 (high)`） | `screens/05_s2_detect_utf8.png`、`screens/ui_05_s2_detect_utf8.xml` |
| 3 | `encrypted.7z` 明确拒绝、不崩溃、无密码框 | **PASS** | `screens/09_s3_encrypted_error.png` |
| 4 | `traversal.7z` 明确拒绝、无越界落盘 | **PASS** | `screens/10_s4_traversal_error.png`、`logs/s4_traversal_fs_check.txt` |
| 5 | `bomb.7z` 限额错误、存活、无冻结 | **PASS**（错误可见 ≤2.63s；UI 可交互） | `screens/11_s5_bomb_error.png`、`12_s5_ui_responsive_discover.png`、`logs/s5_bomb_timing.txt` |
| 6 | `corrupt.7z`（截断/CRC）明确错误、不崩溃 | **PASS** | `screens/13_s6_corrupt_truncated_error.png`、`screens/15_s6_crc_import_error.png` |
| 7 | `surface.7z`（A.txt / a.txt）列表与落盘名 | **PASS**（Android 原样保留 `A.txt`/`a.txt`） | `screens/16_s7_surface_list.png`、`17_s7_surface_shelf.png`、`logs/s7_surface_import_dir.txt` |
| 8 | zip/RAR 外部导入与普通 RSS/书架/阅读器回归 | **PASS**（RAR 为 Android 既有设计「明确不支持」） | `screens/19_s8_zip_shelf.png`、`23_s8_zip_reader.png`、`20_s8_rar_unsupported.png`、`21_s8_rss_tab.png` |
| 9 | `archive_import` 无 `.part` 残留、失败后目录干净 | **PASS** | `logs/s6_crc_archive_dir.txt`、`logs/s9_cleanliness.txt` |

**总体判定：有条件通过。** 9 个场景主路径均通过；但发现 1 个 **P1 互操作缺陷 D1**：
py7zr（以及任何把目录条目与文件条目交错排列的合法 7z）在「列表可见」的文件会在导入时被
静默漏掉，属于用户可见的数据丢失。另记录 1 个 **P3 边界**：`*.7z.001` 分卷在 UI 层不被识别
为压缩包，落到「文件不受支持」兜底框而不是专用分卷提示。

- 崩溃口径：`FATAL EXCEPTION` = **0**、`ANR in` = **0**、`E/flutter` = **0**、`panicked` = **0**；
  验收全程应用进程存活（pid 59014，结束时 PSS 172,462 KB）。证据 `logs/final_logcat_counts.txt`、
  `logs/final_process_state.txt`、`logs/logcat_all.txt`。

## 二、构建与安装

### 2.1 Rust（`rust/scripts/build-android.ps1 -Mode release`）

退出码 **0**，三 ABI 产出并复制到 `flutter_legado/android/app/src/main/jniLibs/`。

| ABI | `.so` 大小 | 备注 |
|---|---|---|
| arm64-v8a | 50,918,296 B | — |
| armeabi-v7a | 34,071,440 B | `rar` crate 报 `E0277`，沿用既有「无 quickjs」回退；本设备 x86_64 不受影响 |
| x86_64 | 51,015,568 B | 本次验收使用 |

证据：`logs/build_rust.log`（脚本完整输出）。

### 2.2 Flutter 发布包

| 项 | 值 |
|---|---|
| 命令 | `flutter build apk --release` |
| 退出码 | 0（`√ Built ... app-release.apk (187.8MB)`） |
| 大小 / sha256 | 196,891,656 B / `9a03fc446aff0280b1a12a82851ac9a77e832ffd000555928533fe2a619838e0` |
| 安装 | `adb install -r` → `Success: streamed 196891656 bytes` |
| 版本 | **versionName 2.0.400 / versionCode 401**（`dumpsys package` 实测） |

证据：`logs/build_apk.log`、`logs/apk_sha256.txt`、`logs/install_apk.txt`、`logs/version_info.txt`。

## 三、夹具

宿主生成（7-Zip CLI / py7zr / sevenz-rust2 小例程），push 到 `/sdcard/Download/`，
设备侧哈希与宿主一致（`logs/device_fixtures_sha256.txt`）。

| 夹具 | 生成方式 | 大小 | sha256 | 用途 |
|---|---|---|---|---|
| `normal.7z` | 7-Zip CLI（目录在前） | 1,022 B | `9f72b76e…36d114` | 场景 1/2 主路径 |
| `normal_py7zr.7z` | py7zr（目录与文件交错） | 1,025 B | `c2c743cd…61226a` | D1 复现 |
| `nested_py7zr.7z` | py7zr（`dir1/one.txt`、`dir2/two.txt`） | 225 B | `8aed9b81…d90486` | D1 决定性复现 |
| `encrypted.7z` | py7zr AES | 201 B | `10435d63…098d38c` | 场景 3 |
| `traversal.7z` | sevenz-rust2 writer（条目名 `../evil.txt`） | 186 B | `b3421a5a…c18618d8` | 场景 4 |
| `bomb.7z` | py7zr，2 GiB 零字节单条目 | 312,582 B | `1fd80840…cf6aeb8` | 场景 5 |
| `corrupt.7z` | `normal.7z` 截断到 64 B | 64 B | `fc759c09…d60d3751` | 场景 6（截断） |
| `corrupt_crc.7z` | 7-Zip `-mx=0` + 数据区翻 1 字节 | 182 B | `ff3423aa…c52624b5` | 场景 6（CRC） |
| `surface.7z` | py7zr | 189 B | `d7e6a28e…e4deca2` | 场景 7 |
| `regression.zip` | Python zipfile | 195 B | `bacc34d7…5b676fb` | 场景 8（zip 回归） |
| `regression.rar` | 手写 RAR4 store 格式（unrar crate 验证可读） | 104 B | `86300203…26fd63` | 场景 8（RAR 边界） |

完整哈希：`logs/fixture_sha256_host_final.txt`。

## 四、逐场景明细

### 1. `normal.7z` 列表 / 多选导入 / 书架 / 正文 —— PASS

- VIEW 打开（与文件管理器「用阅读打开」同一 Intent 路径）后对话框列出 `book.epub`、`novel.txt`，
  **未列出** `readme.md`；默认全选（`导入 (2)`）。
  证据：`screens/04_s1_normal_list.png`、`screens/ui_04_s1_normal_list.xml`。
- 点击「导入 (2)」后书架出现 `7z验收EPUB`（EPUB 元数据标题）与 `novel` 两本；
  `archive_import/` 落盘 `book.epub` 1,404 B、`novel.txt` 137 B。
  证据：`screens/06_s1_shelf_after_import.png`、`logs/db_books_after_all.txt`。
- 打开 `novel` 阅读器显示中文正文：`第一章 测试`、`这是一段用于设备验收的中文正文。`、
  `Legado 7z 导入验收 — 第24批。`、`第二章 结束`、`全书完。`
  证据：`screens/07_s1_open_novel.png`、`screens/ui_07_s1_open_novel.xml`。

**子项 FAIL（缺陷 D1）**：同样内容改由 py7zr 生成（`normal_py7zr.7z`）时，对话框同样列出
`book.epub`/`novel.txt`，但导入只落盘 `book.epub`，`novel.txt` 被静默跳过；用
`nested_py7zr.7z`（`one.txt`/`two.txt`）在清空目录后复现：列表两项、导入只得到 `one.txt`。
详见 §五。

### 2. 7z 内 TXT 编码检测 —— PASS

在 `normal.7z` 列表对话框中点「检测编码」，`novel.txt` 行出现 `编码: utf-8 (high)`。
证据：`screens/05_s2_detect_utf8.png`、`screens/ui_05_s2_detect_utf8.xml`。

说明：该按钮内部同样走 `archiveImport7z` 解压到临时目录，因此 D1 的包会出现「点了无结果」
（实为 txt 条目未被解出，非按钮失效）；`normal.7z` 上功能正常。

### 3. `encrypted.7z` —— PASS

- 对话框「加载失败」区域显示：`Book parsing error: 7z列表失败: 暂不支持加密 7z（请先解密后再导入）`。
- 列表区无任何文件项，`导入 (0)` 禁用；7z 类型**不显示密码框**（仅 RAR 显示）。
- 应用无崩溃，可正常「取消」返回书架。
  证据：`screens/09_s3_encrypted_error.png`、`screens/ui_09_s3_encrypted_error.xml`。

### 4. `traversal.7z` —— PASS

- 明确拒绝：`Book parsing error: 7z列表失败: 非法 7z 条目名（路径穿越）: ../evil.txt`。
- 文件系统核查（root 直查）：`/sdcard/Download/evil.txt` 不存在；
  `/sdcard/Android/data/io.legado.flutter_legado`（应用未创建外部目录）无该文件；
  `find /data/data/io.legado.flutter_legado -name evil.txt` 为空；
  `find /sdcard -maxdepth 3 -name evil.txt` 为空。
  证据：`screens/10_s4_traversal_error.png`、`logs/s4_traversal_fs_check.txt`。

### 5. `bomb.7z`（2 GiB 零字节条目）—— PASS

- 在声明大小检查阶段即拒绝：`7z 单条目过大 [big_zero.txt]（2147483648 字节，上限 268435456 字节）`。
- 从 VIEW Intent 发出到错误可见 **≤2.63 s**（首轮 uiautomator 转储耗时即已包含；未发生长时间冻结）。
- 关闭对话框后立即能切换到「发现」Tab（显示「当前没有发现源！」）并返回书架，UI 可交互。
- 全程 `FATAL EXCEPTION`/`ANR` 均为 0，进程 pid 不变。
  证据：`screens/11_s5_bomb_error.png`、`12_s5_ui_responsive_discover.png`、
  `logs/s5_bomb_timing.txt`、`logs/final_logcat_counts.txt`。

### 6. `corrupt.7z` —— PASS

- 截断包：`Book parsing error: 7z列表失败: 7z 解析失败: next header offset out of range`
  （`screens/13_s6_corrupt_truncated_error.png`）。
- CRC 包（7-Zip `-mx=0` + 数据区翻字节）：列表正常，点导入后 SnackBar 显示
  `解压失败: [crc_payload.txt]: 7z 文件校验失败（CRC 错误，文件可能损坏）`，对话框保持打开可重试
  （`screens/15_s6_crc_import_error.png`）。
- 失败后 `archive_import/` 为空目录（仅 `.`/`..`），无半成品：
  `logs/s6_crc_archive_dir.txt`。

### 7. `surface.7z`（`A.txt` / `a.txt`）—— PASS

- 列表：`A.txt`、`a.txt`（Android ext4 大小写敏感，按实现原样保留）。
- 导入落盘：`A.txt` 16 B、`a.txt` 16 B，同名大小写不互相覆盖；书架出现 `A`、`a` 两本。
- 平台差异：Windows 宿主探针按 `FOLD_OUTPUT_NAME_CASE=true` 输出 `A.txt`/`a_2.txt`；
  Android 不折叠，符合批24c 设计口径。
  证据：`screens/16_s7_surface_list.png`、`17_s7_surface_shelf.png`、`logs/s7_surface_import_dir.txt`、
  `logs/host_probe_errors.txt`。

### 8. zip / RAR / RSS / 书架 / 阅读器回归 —— PASS

- zip：`regression.zip` 列表 `zip_normal.txt`，导入落盘 69 B，书架出现 `zip_normal`，
  打开阅读器显示 `zip 回归中文正文`（`screens/23_s8_zip_reader.png`、`logs/s8_zip_import_dir.txt`）。
- RAR：`regression.rar`（unrar crate 验证可读的合法 RAR4）在设备上给出
  `Book parsing error: Android 平台暂不支持 RAR 解压`；这是 `archive.rs` 中
  `cfg(any(target_os = "android", target_os = "ios"))` 的既有设计，不是 7z 回归
  （`screens/20_s8_rar_unsupported.png`）。
- 普通 RSS：「订阅」Tab 正常渲染（本机无订阅源，显示「当前没有订阅源！」）
  （`screens/21_s8_rss_tab.png`）。
- 书架/阅读器：书架正常列出测试书，7z 与 zip 导入书均可进入阅读并渲染正文
  （`screens/06_s1_shelf_after_import.png`、`screens/07_s1_open_novel.png`、`screens/23_s8_zip_reader.png`）。

### 9. `archive_import` 残留与失败清洁 —— PASS

- 全部流程后 `find /data/data/io.legado.flutter_legado -name '*.part'` 为空；
  `/sdcard/Download` 也无 `.part`。
- 「先成功导入 zip，再导入 CRC 损坏包」：失败后 `archive_import` 仍保留原有
  `zip_normal.txt`，未被半成品覆盖；失败发生在空目录时目录保持为空。
  证据：`logs/s9_cleanliness.txt`、`logs/s6_crc_archive_dir.txt`。

## 五、缺陷 D1（P1）：交错目录布局的 7z 导入静默漏文件

**现象**：列表显示 N 个书籍条目，导入只落盘其中一部分；用户选中并看到「成功导入」提示，
缺失文件没有任何错误或提示。

**复现（设备，干净目录）**：

1. `adb shell rm -rf /data/data/io.legado.flutter_legado/app_flutter/archive_import`
2. VIEW 打开 `/sdcard/Download/nested_py7zr.7z`
3. 对话框列出 `one.txt`、`two.txt`，默认全选，点「导入 (2)」
4. 预期：`archive_import/` 出现 `one.txt` 与 `two.txt`；实际：只有 `one.txt`
   （`logs/defect_nested_import_dir.txt`、`screens/24_defect_nested_list.png`、`25_defect_nested_shelf.png`）

`normal_py7zr.7z` 同样复现：列表 `book.epub`/`novel.txt`，导入仅 `book.epub`
（`logs/s1_py7zr_import_dir.txt`、`screens/08_defect_py7zr_only_epub.png`）。

**宿主根因探针**（`logs/defect_py7zr_iteration.txt`）：

```
### 7-Zip CLI archive (normal.7z)
file[0] 中文目录 (dir)  file[1] 中文目录/嵌套 (dir)
file[2] book.epub  file[3] readme.md  file[4] 中文目录/嵌套/novel.txt
callback: book.epub, readme.md, 嵌套/novel.txt, 中文目录, 中文目录/嵌套
import -> [book.epub, novel.txt]

### py7zr archive (normal_py7zr.7z)
file[0] 中文目录 (dir)  file[1] 中文目录/book.epub  file[2] 中文目录/readme.md
file[3] 中文目录/嵌套 (dir)  file[4] 中文目录/嵌套/novel.txt
callback: book.epub, readme.md, 中文目录/嵌套, 中文目录      <-- 缺 novel.txt
import -> [book.epub]

### py7zr nested (nested_py7zr.7z)
file[0] dir1 (dir) file[1] dir1/one.txt file[2] dir2 (dir) file[3] dir2/two.txt
callback: dir1/one.txt, dir2, dir1                     <-- 缺 dir2/two.txt
import -> [one.txt]
```

**根因**：`sevenz-rust2 0.24.1` 的 `ArchiveReader::for_each_entries` →
`BlockDecoder::for_each_entries` 以「块起始文件索引 + 子流数」连续遍历
（`block_first_file_index` 起 `num_unpack_sub_streams` 个文件索引），假定同一块内
有数据流的条目在 `archive.files` 中连续。py7zr 把目录条目与文件条目交错写入
（`dir, file, dir, file`，7z 规范允许，`kEmptyStream` 位图标记无流条目），
连续索引会撞到无流的目录条目并漏掉其后的文件。`list_7z_book_files` 直接遍历
`archive.files`（名称完整），`import_7z_file` 用 `for_each_entries`（丢文件），
于是出现「列表可见、导入缺失」；且缺失条目不产生错误，`list`/`import` 结果不一致。

- 影响面：任何非 7-Zip 原生排序的 7z（py7zr、部分第三方打包器；目录与文件交错、
  或含空文件混排）都会触发；单目录扁平包与 7-Zip CLI 生成的包不受影响。
- 现有单元测试（批24 系列）均使用 `compress_to_path`/7-Zip 式布局，未覆盖该形态。
- 修复方向（未实施，交由 Rust 轨评估）：导入改为按 `archive.files` 逐条目
  `read_file`/流式读取，或修正/绕过上游 `block_first_file_index` 语义；
  补一条「目录与文件交错」的回归用例，并断言 list 与 import 的文件集合一致。

## 六、支持边界与遗留

| 边界 | 实测行为 | 说明 |
|---|---|---|
| 加密 7z（AES256） | 列表即失败：`暂不支持加密 7z（请先解密后再导入）`，无密码框 | 设计内（§2.34） |
| 分卷 7z（`*.001`） | **UI 未识别为压缩包**：落「文件 volume_test.7z.001 不受支持，是否继续打开？」兜底框 | `classifyFileExtension` 取最后后缀 `001`，`is_multi_volume_7z_path` 的专用提示从文件管理器路径不可达（P3，证据 `screens/27_boundary_multivolume.png`） |
| 大小写平台差异 | Android 保留 `A.txt`/`a.txt`；Windows 宿主按 `A.txt`/`a_2.txt` 折叠 | 与 `FOLD_OUTPUT_NAME_CASE` 设计一致 |
| RAR（Android） | 明确 `Android 平台暂不支持 RAR 解压` | `unrar_sys` 无法交叉编译，既有边界 |
| 限额 | 512 MiB 输入 / 256 MiB 单条目 / 512 MiB 总量 / 10000 条目 / 128 MiB 字典 | 本机仅实测单条目超限（bomb）；其余为代码常量 |
| D1 互操作 | 交错目录布局 7z 静默漏文件 | **新发现 P1，需修复** |

## 七、清理与可复现性

- 验收前 DB 备份：`db/legado.db.orig`（274,432 B，
  sha256 `677072864dabbdaf7cb072982399594f53abf6502f25e00d60d03987619d29dd`）。
- 结束时 `am force-stop` 后恢复 DB，删除 `-wal/-shm`，`chown u0_a62:u0_a62`；
  `books` 计数回到 **0**，书架显示空态（`screens/26_restored_empty_shelf.png`）。
- 已删除 `archive_import/`、`cache/external_import/`、`files/external_import/` 与
  `/sdcard/Download/` 下全部推送夹具；`evil.txt`、`*.part` 全盘检索为空。
- 已停止宿主 logcat 采集；应用保持 2.0.400/401（`logs/version_after_restore.txt`）。
- 清理记录：`logs/cleanup.txt`。

## 八、证据索引

- 截图/UI 树：`tmp_debug/device_acceptance_20261027_7z/screens/`（编号见各场景）
- 日志：`tmp_debug/device_acceptance_20261027_7z/logs/`
  - 构建/安装：`build_rust.log`、`build_apk.log`、`apk_sha256.txt`、`install_apk.txt`、`version_info.txt`
  - 夹具哈希：`fixture_sha256_host_final.txt`、`device_fixtures_sha256*.txt`
  - 错误路径：`host_probe_errors.txt`、`defect_py7zr_iteration.txt`、`s1_py7zr_import_dir.txt`、`defect_nested_import_dir.txt`
  - 安全/清洁：`s4_traversal_fs_check.txt`、`s6_crc_archive_dir.txt`、`s7_surface_import_dir.txt`、`s9_cleanliness.txt`
  - 稳定性：`final_logcat_counts.txt`、`final_process_state.txt`、`logcat_all.txt`
  - 清理：`cleanup.txt`、`version_after_restore.txt`

---

## 九、回修复验（批24d，2026-10-28）

> 本节仅追加修复后的复验记录，**不改变** §一~§八 的历史结论（D1 在修复前为 FAIL）。
> 修复提交：`ee82a010c8`（fix）+ `4aaeca5b2d`（test）；本节随批24d docs 提交落盘。
> 证据目录：`tmp_debug/device_acceptance_20261027_7z/verify2/`（`.gitignore` 已忽略，不入库）。

### 9.1 根因与修法

- **根因**：`sevenz-rust2 0.24.1` 的 `BlockDecoder::for_each_entries`（及
  `ArchiveReader::read_file` 的 solid 分支）按
  `block_first_file_index + num_unpack_sub_streams` 连续索引遍历 `archive.files`，
  假定同块内有流条目连续。py7zr 把目录条目与文件条目交错写入（7z 规范允许，
  `kEmptyStream` 位图），区间撞到无流目录条目后提前结束，后续文件被静默跳过；
  列表走 `archive.files` 所以完整。
- **修法（`legado-book/src/archive.rs`）**：① 以 `archive.files` 为权威清单，
  仍按原始文件序经 `plan_book_output_names` 规划输出名（列表口径）；② 导入前
  `normalize_7z_block_file_ranges` 按块重排内存文件表并重写 `stream_map`，使每个
  块的连续区间恰好覆盖其全部子流（不改名称/大小/CRC，`blocks` 与子流数不变）；
  ③ 主迭代按输出名记录已写出集合，未覆盖条目回退 `read_7z_entry_strict`
  （`read_file` 逐条读取 + 声明长度校验），缺失/空读/长度不符整包报
  「7z 条目读取不完整」，不再静默成功；④ 落盘与 `extracted_files` 按原始文件序
  返回，与列表一致。
- 宿主探针确认：对同一 `nested_py7zr.7z`，旧 `for_each_entries` 只回调
  `dir1/one.txt`、`dir2`、`dir1`，且 `read_file("dir2/two.txt")` 返回
  `FileNotFound`（solid 分支同样受上游连续区间影响）；归一化后迭代与
  `read_file` 均覆盖 `dir2/two.txt`。

### 9.2 红→绿（宿主）

- **红**：在 HEAD 旧实现（`a1a7d7ffce`）的临时 worktree 中运行交错夹具断言
  `list == import` → **FAILED**：`list=["one.txt","two.txt"]`，
  `import=["one.txt"]`。证据 `verify2/red_host_test.txt`。
- **绿**：修复后 `cargo test -p legado-book --lib archive::tests` → **43 passed**
  （含新增 4 个交错/回退用例）；`archive::tests::test_import_7z_interleaved_*`
  两用例通过，日志含「检测到目录/文件交错布局（1 个无流条目），已归一化块文件区间」。
  证据 `verify2/green_host_test.txt`。
- 全量门禁：`cargo fmt --all -- --check`、`cargo clippy --workspace --all-targets
  -- -D warnings`、quickjs 组合 clippy、`cargo test -p legado-book -p legado-ffi
  --features quickjs`、`cargo test --workspace` 全部通过；workspace 合计
  **3496 passed / 0 failed / 26 ignored**（`verify2/cargo_test_workspace.log`）。
  `flutter analyze` 无问题；`flutter test` 全量 **+2825 ~1 / All tests passed**
  （`verify2/flutter_test.log`）；真实 DLL 7z 用例 8/8 通过（新增交错布局用例，
  `verify2/flutter_ffi_7z_runtime.log`）。

### 9.3 构建与设备复验

| 项 | 值 |
|---|---|
| Rust | `rust/scripts/build-android.ps1 -Mode release` 退出 0；arm64 48.6MB / v7a 32.5MB（既有无 quickjs 回退）/ x86_64 48.7MB（`verify2/build_rust.log`、`so_sha256.txt`） |
| APK | `flutter build apk --release` 退出 0，196,957,192 B，sha256 `4f906f5f…17c164`（`verify2/build_apk.log`、`apk_sha256.txt`） |
| 安装 | streamed 196957192 bytes；2.0.400 / 401，lastUpdateTime 2026-10-28 00:00:06（`verify2/install_apk.txt`、`final_state.txt`） |
| 夹具 | `/sdcard/Download/nested_py7zr.7z`，sha256 `8aed9b81…d90486`（与 §三 原夹具一致） |

**D1 主复验（nested_py7zr.7z，交错目录布局）**：

1. 清空 `archive_import/` 后 VIEW 打开，对话框完整列出 `one.txt`、`two.txt`
   （`verify2/screens/01_after_intent.png`）。
2. 点「导入 (2)」→ `archive_import/` 落盘 **`one.txt` 18 B、`two.txt` 18 B**
   （`verify2/import_dir.txt`），内容分别为 `ONE 一号正文`、`TWO 二号正文`
   （`verify2/content_and_cleanliness.txt`；`adb shell` 输出会把 LF 转为 CRLF，
   文件实际大小以 `ls` 的 18 B 为准）。
3. 书架新增 `one`、`two`（`verify2/screens/02_after_import.png`），打开 `two`
   阅读器显示「TWO 二号正文」（`verify2/screens/03_open_two_reader.png`）。
   DB `books` = `7z验收EPUB, novel, one, two`（`verify2/db_books.txt`）。

**回归（normal.7z，7-Zip 生成）**：列表 `book.epub`/`novel.txt`
（`verify2/screens/04_normal_dialog.png`），导入落盘 `book.epub` 1404 B、
`novel.txt` 137 B（`verify2/normal_import_dir.txt`），书架出现
`7z验收EPUB`/`novel`（`verify2/screens/06_normal_shelf.png`）。

**清洁与稳定性**：`/data/data/io.legado.flutter_legado` 与 `/sdcard/Download`
下 `*.part` 均为 **0**；`FATAL EXCEPTION` = **0**、`ANR in` = **0**、
`E/flutter` = **0**、`panicked` = **0**，进程存活（`verify2/final_state.txt`、
`verify2/final_logcat_counts.txt`、`logcat_verify2.txt`）。

**收尾**：恢复验收前 DB（sha256 与 `db/legado.db.orig` 一致，`books` 计数 0），
删除 `archive_import/` 与推送夹具，书架恢复空态
（`verify2/cleanup.txt`、`verify2/screens/07_restored_empty_shelf.png`）。

### 9.4 残余风险

- **回退读取性能**：`read_file` 对 solid 包会从块首重复解压到目标条目；归一化后
  主迭代应一次读全，回退仅在「主迭代未覆盖」时触发（本次设备复验未触发），
  单条目最坏仍受 256 MiB / 总 512 MiB 限额约束。
- **solid 重复解压**：若上游再次出现块区间偏差导致回退，多个缺失条目可能重复解压
  同一块；属异常兜底路径，不影响正常包。
- **诊断日志**：release 包内 Rust `eprintln!` 未进入 logcat（stdout/stderr 未挂接），
  归一化/回退计数仅在宿主测试可见；建议后续若要设备可观测，改走统一日志桥。
- **上游依赖**：块区间语义修复依赖 `sevenz-rust2` 公开的 `Archive`/`stream_map`
  字段；升级 0.24.x 后需重跑交错夹具与真实 DLL 用例。

编写：QA 子代理（设备验收） 2026-10-27；回修复验：全栈工程师子代理 2026-10-28

