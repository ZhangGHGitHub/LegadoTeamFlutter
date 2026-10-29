# 批 35 设备验收报告（书架标签 / 批量删除源文件 / 书籍级阅读记录开关）

> 范围：批 35（参考版书架功能第一批）——书架展示标签四项偏好（`bookshelfShowTag` /
> `bookshelfShowCustomTags` / `bookshelfShowSourceTags` / `bookshelfShowWordCount`）、
> 批量删除书籍可选删除本地源文件（`deleteBooks(urls, deleteOriginal)`，含
> Documents/Cache 信任边界与符号链接防护）、书籍级「独立关闭阅读记录」
> （`setReadRecordDisabled` + `putReadRecord(bookUrl:)` 写入门控）、DB schema 116→117
> （`books.disableReadRecord`）。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测在线，adbd root）。
>
> **结论**：场景 1~7 全部 **PASS**。未发现功能缺陷；3 项观察项（阅读记录按书名记录、
> 删除弹窗勾选态无 uiautomator 语义、备份恢复覆盖 appPrefs）记录在 §五，均非本批引入。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu 实例「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 | SM_G9900（MuMu 伪装）/ Android 15 |
| 分辨率 / 密度 | 1080x1920 / 480dpi |
| adb | `D:\Android\platform-tools\adb.exe`（adbd root，`uid=0`） |
| 应用包名 | `io.legado.flutter_legado` |
| 升级前版本 | versionName **2.0.411** / versionCode **412**，DB v116、299,008 字节、书架空 |
| 验收版本 | versionName **2.0.413** / versionCode **414**（设备 `dumpsys` 与 APK badging 一致） |
| 源码基线 | `master` HEAD `e79d2f9d06`（`chore: 批35 收尾（2.0.413+414 双日志与计划关闭登记）`） |
| 验收时间 | 2026-10-29 19:01 ~ 19:40（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261029_batch35/`（`tmp_debug/` 在 `.gitignore`，不入库） |

### 1.1 升级前备份

安装前完整拉取设备 DB 与偏好：`db/legado_pre_upgrade_2.0.411.db`（v116，299,008 字节）、
`prefs/FlutterSharedPreferences_pre_upgrade.xml`。

### 1.2 构建

- `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release`
  退出码 **0**（`logcat/rust_build_batch35.log`）；三 ABI `liblegado_ffi.so` 已更新到
  `flutter_legado/android/app/src/main/jniLibs/`。
  - 既有环境项（非本批引入）：armv7 + quickjs 编译失败（`rar` 3 errors），脚本按既有逻辑
    回退重试后成功；本机 x86_64 不受影响。
- `cd flutter_legado && flutter build apk --release` 退出码 **0**
  （`logcat/flutter_build_batch35.log`），产物
  `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`（197,473,420 字节，
  sha1 `e3bf8b01b3b5d5e406aed0c039b3f6c287eddbab`，`logcat/apk_sha1.txt`）。
- `adb install -r` 成功（`logcat/install_batch35.log`）。

### 1.3 升级后 schema

首启后 `PRAGMA user_version=117`，`books` 表出现 `disableReadRecord INTEGER NOT NULL
DEFAULT 0`（共 39 列），与契约一致（`db/legado_after_upgrade_empty.db`）。

## 二、验收场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 书架标签：默认显示/总开关/三项分别关闭/空值/列表+网格/重启保持/备份 JSON | **PASS** | `shots/01~08`、`prefs/prefs_after_tag_toggles.xml`、`db/legado_backup_*.json` |
| 2 | 批量删除源文件：Checkbox 条件/勾选/不勾选/在线书不受影响/计数 | **PASS** | `shots/20~24`、文件与 DB 查询（§3.2） |
| 3 | 路径防护：应用目录外文件 / 符号链接拒绝删除 | **PASS** | `shots/25`、`db/final_db_state.txt`（§3.3） |
| 4 | 单本关阅读记录：不增/恢复增长/其它书不受影响/重启/备份恢复 | **PASS** | `shots/09、10、12、33、34`、`db/legado_backup_*.json`、DB 查询（§3.4） |
| 5 | 整书保存不重置开关（改书名/分组） | **PASS** | `shots/17、19`、DB 查询（§3.5） |
| 6 | 回归（书架/阅读器/目录/RSS/设置）+ FATAL/ANR | **PASS** | `shots/26~32`、`logcat/logcat_full_session.log`、`logcat/exit_info.log` |
| 7 | 清理（恢复 DB/偏好、删除测试书/文件） | **PASS** | `db/post_cleanup_state.txt`、`shots/35` |

> 原始命令输出与逐步记录：`tmp_debug/device_acceptance_20261029_batch35/evidence_notes.txt`。

## 三、逐场景说明

### 场景 1：书架标签 — PASS

种子书：《QA35标签书》（`customTag=都市,爽文`、`kind=玄幻,修真`、`wordCount=12.3万字`）、
《QA35空标签书》（三项均 NULL）。

- **默认显示**：列表 `shots/01_bookshelf_default_list.png` 显示「都市 爽文 玄幻 修真
  12.3万字」；《QA35空标签书》仅有作者行，无标签行（空值不产生标签）。
- **网格布局**：`shots/02_grid_tags_default.png` 网格书卡同样渲染标签行。
- **总开关关闭**：布局设置面板「显示标签」置 false 后，网格 `shots/03_grid_tags_off.png`、
  列表 `shots/04_list_tags_off.png` 均无标签；「标签显示内容」行变灰不可点。
- **三项分别关闭**（一次只关一项，其余保持）：
  - 用户标签关 → `shots/05_list_custom_tags_off.png`：都市/爽文消失，玄幻/修真/12.3万字保留；
  - 书源分类关 → `shots/06_list_source_tags_off.png`：仅剩 12.3万字；
  - 字数关 → `shots/07_list_all_tags_off.png`：全部消失。
- **重启保持**：杀进程重启后 `shots/08_after_restart_tags_off.png` 仍无标签，面板摘要
  「未选择显示内容」；`prefs/prefs_after_tag_toggles.xml` 实测四键落盘
  （`bookshelfShowTag=true`，其余三键 false）。
- **备份 JSON**：`db/legado_backup_1793272821469.json` 的 `appPrefs` 同时含
  `bookshelfShowTag` / `bookshelfShowCustomTags` / `bookshelfShowSourceTags` /
  `bookshelfShowWordCount` 四键（均 true）及 `bookshelf_layout`。

### 场景 2：批量删除源文件 — PASS

使用《QA35删除本地书》（`books/qa_batch35_delete.txt`，文件在
`app_flutter/books/`）与《QA35在线书》（URL 书，同目录放置同名诱饵文件
`books/qa_batch35_online.txt`）。

- **Checkbox 仅本地显示**：只选在线书 → 弹窗「已选1本」，**无**「删除源文件」
  （`shots/20_delete_dialog_online_only.png`）；混选本地+在线 → 出现「删除源文件」，
  默认未勾选（`shots/21_delete_dialog_mixed.png`）。
- **勾选删除**：勾选后确认 → 本地文件 `qa_batch35_delete.txt` 被删除（`No such file or
  directory`），在线书同名诱饵文件保留 101 字节；两条记录删除（books 8→6）
  （`shots/22_after_delete_mixed_checked.png`）。
- **不勾选删除**：两名本地书（`del2`/`del3`）选中后直接确认 → 提示
  「**已删除 2 本书籍**」（`shots/24_after_delete_unchecked_snackbar.png`），
  两条记录删除（8→6），两个文件均保留 23 字节（校验内容未变）。
- **计数**：成功提示使用 Rust 返回的实际删除数（2），与选中数一致；路径防护场景提示
  见下节（实际删除 2 本 + 逐条未删除原因）。

### 场景 3：路径防护 — PASS

- 《QA35越界书》：`bookUrl=/sdcard/Download/qa_batch35_outside.txt`（origin=loc_book，
  文件真实存在，48 字节）；《QA35链接书》：`bookUrl=books/qa_batch35_symlink.txt`
  （adb 创建符号链接指向上述目录外文件）。
- 勾选「删除源文件」批量删除后提示原文（`shots/25_path_guard_snackbar.png`）：
  「已删除 2 本书籍；部分源文件未删除：《QA35越界书》原文件不在应用 Documents/Cache
  目录内，已跳过文件删除；《QA35链接书》原文件是符号链接，已跳过文件删除」。
- 文件复核：`/sdcard/Download/qa_batch35_outside.txt` 仍存在且内容未变；
  `app_flutter/books/qa_batch35_symlink.txt` 链接仍在；两条书籍记录已删除（books 6→4）。

### 场景 4：单本关阅读记录 — PASS

种子：`readRecord` 两条各 60000ms（QA35阅读书 / QA35对照书）。

1. 详情页菜单开启「独立关闭阅读记录」→ DB `disableReadRecord=1`、snackbar
   「已关闭本书阅读记录」、菜单勾选（`shots/10_detail_menu_checked.png`）。
2. 阅读 35s 后：`readRecord` 仍 `60000`、`lastRead` 仍 0、`readRecordDaily` 空。
3. 杀进程重启：DB 仍 1、菜单仍勾选（`shots/12_after_restart_switch_checked.png`）。
4. 重新开启（DB=0）后阅读 32s：`readTime 60000→97900`、`lastRead` 更新、
   `readRecordDaily=2026-10-29|37`。
5. 其它书不受影响：QA35对照书阅读 30s 后 `60000→95678`。
6. 记录页 UI 复核：关闭状态下阅读 30s，`shots/33_record_page_before_disabled_read.png`
   与 `shots/34_record_page_after_disabled_read.png` 均显示「QA35阅读书 1分钟37秒」，
   期间 DB 保持 97900（不增）。
7. 备份/恢复：备份 JSON 中《QA35阅读书》`disableReadRecord=true`；先把开关改回 0，
   再从本地备份恢复（`shots/15_restore_confirm.png`、`shots/16_after_restore.png`）→
   DB 恢复为 1，阅读记录同步恢复（97900 / 95678）。备份/恢复后开关保持。

### 场景 5：整书保存不重置开关 — PASS

开关关闭（DB=1）时：

- 编辑书籍信息改名 `QA35阅读书` → `QA35阅读书QA35-EDIT` 并保存 → DB 书名已变、
  `disableReadRecord` 仍 1（`shots/17_after_edit_name.png`）。
- 「设置分组」选择新建分组 `QA35G`（groupId=1793273312950）→ DB `group` 已变、
  `disableReadRecord` 仍 1（`shots/19_after_group_change.png`）。
- 两条路径均为整书快照写（`updateBook`），验证了批 35b 缺键保留/显式携带语义在 UI
  生产路径不回退开关。

### 场景 6：回归 — PASS

- 书架列表/网格、详情页、阅读器（第一章/第二章正文加载）、目录页
  （目录/书签/标注三页签）、阅读记录页（按书/按天、累计时长）、订阅页空态、发现/首页/
  我的、设置与备份恢复界面均正常（`shots/11、13、14、26~32`）。
- **FATAL=0、ANR=0**：`logcat/logcat_full_session.log` grep 计数均为 0；
  `logcat/crash_buffer.log` 无 `FATAL EXCEPTION`；`dumpsys activity exit-info` 仅见
  USER REQUESTED/FORCE STOP/PACKAGE UPDATED，无 CRASH/ANR（`logcat/exit_info.log`）。

### 场景 7：清理 — PASS

- 恢复升级前 DB（`db/legado_pre_upgrade_2.0.411.db`）与偏好
  （`prefs/FlutterSharedPreferences_pre_upgrade.xml`）；
- 删除 `app_flutter/books/` 全部测试文件、`/sdcard/Download/qa_batch35_outside.txt`、
  测试备份 JSON、外部 files/backup 目录与 `/data/local/tmp/seed_batch35.sql`；
- 重启应用复核（`db/post_cleanup_state.txt`）：user_version=117（迁移后）、books=0、
  chapters=0、readRecord=0、book_groups=0；偏好恢复为升级前五项；
  应用 2.0.413/414 正常运行、书架空态（`shots/35_after_cleanup.png`），FATAL/ANR=0。

## 四、门禁与证据固化

- 本批为设备验收，不重复 CI 覆盖项（`cargo test` / `flutter analyze && flutter test` /
  `:app:testAppReleaseUnitTest` 以 CI 为准）。
- 设备侧证据：截图 35 张、DB/偏好快照、备份 JSON、构建/安装/日志文件，均位于
  `tmp_debug/device_acceptance_20261029_batch35/`（不入库）。

## 五、观察项与遗留

1. **阅读记录按书名记录**：改名后记录页仍显示旧书名（本次改名后
   「QA35阅读书」记录未随书名迁移）。原版/参考版同为按书名作为记录键，属既有语义，
   非批 35 引入；如需迁移应另批处理（本批未改动）。
2. **删除弹窗勾选态语义**：批量删除弹窗的「删除源文件」为自绘 `InkWell + Checkbox`，
   uiautomator 语义树不暴露 `checked` 状态（点击后行为正确、文件确实被删除）；
   仅影响自动化/无障碍可读性，功能无影响。
3. **备份恢复覆盖 appPrefs**：恢复默认会整体覆盖四键（未勾选「忽略书架布局」时），
   本批四键按预期往返；与既有 appPrefs 恢复语义一致。

> 登记（沿用批 35/35b 范围声明，本次设备验收未改代码）：WebDAV 删除只清本机缓存不请求
> 远端；封面/章节缓存/下载任务不随删书清理；标签颜色管理未做；`recordReadingTime`
> 不传 bookUrl 不受书级开关（无生产调用方）。

编写者：QA（ZCode）｜ 2026-10-29
