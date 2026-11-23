# 设备验收证据归档：2026-11-03 `batch2b2c`（设置批 2b-2c 双栏 list-detail）

## 1. 基本信息

| 项 | 值 |
|---|---|
| 来源目录 | `tmp_debug/device_acceptance_20261103_batch2b2c/`（原目录，`.gitignore:49` 的 `/tmp_*` 规则忽略，`git ls-files` = 0） |
| 采集日期 | 2026-11-03（宿主时间；目录内 mtime 20:32 ~ 20:41） |
| 归档日期 | 2026-11-23 |
| 归档位置 | `docs/evidence/acceptance_20261103_batch2b2c/` |
| 文件数 | **86**（归档前后一致，`diff -r` 校验完全相同） |
| 体积 | 4,295,878 B（约 4.1 MB） |
| 设备 | MuMu 实例 index 1「Test测试」，adb `192.168.100.62:5555`；SM-G9900 伪装 / Android 15 / x86_64 |
| 宽屏覆盖 | `wm size 1920x1200` + `wm density 240`（1280×800 dp）；`data/wm_original.txt` 记录物理 1080×1920 / 480 |
| 应用版本 | **2.0.443+444**（源码基线 `master` HEAD `b77a77dfd0`「chore: 2b-2c 收尾」；见 §3） |
| 批次 | **设置批 2b-2c**「书架/发现/RSS 列表-详情双栏」设备验收（首轮） |

## 2. 推断用途（附证据）

**结论：这批证据是「设置批 2b-2c（书架/发现/RSS list-detail 双栏）」的**首轮**设备验收原始证据，
且记录了该批最关键的 P1 缺陷（宽屏发现双栏点书 → 左侧发现页被 `ErrorWidget` 灰块覆盖）。**

### 2.1 直接文档锚点

- `docs/REFACTORING_ACTIVE_PLAN.md:1029`（2026-11-03，2b-2c 工程关闭）描述本批范围：
  「书架/发现/RSS list-detail 双栏；`MainDetailPaneController`/Scope；右栏宽 744→360/840→456/
  1000→576/1280→744；书架未读单击/长按、发现书单、RSS 源→文章列表→文章详情进右栏；
  左列表选择 `replace` 替换栈…」——与本目录语义树逐步一一对应（见 2.2）。
- `docs/DEVICE_ACCEPTANCE_20261104_BATCH2B2C.md` 是同一批次的**正式验收报告**（首轮 22:30~23:20 +
  §六 23:42~23:57 回修复验），报告 §五「证据与产物索引」指向**另一目录**
  `tmp_debug/device_acceptance_20261104/`（后续正式轮），而本目录对应其**更早的首轮尝试**
  （2026-11-03 20:30~20:41，即 2b-2c 收尾提交后立即进行的验收）。
- `docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.5 将本目录列为「无文档来源」，
  但附录 A.2 第 37 行已记录其类型分布（`.xml×33、.png×26、.html×17、.txt×4`），与本次实测一致。

### 2.2 目录内自证据（逐步对应 2b-2c 验收场景）

| 证据文件 | 内容 | 对应 2b-2c 场景 |
|---|---|---|
| `data/00_startup.xml`、`data/00b_shelf_all.xml` | 启动落书架（「书架分组」「搜索」） | 启动基线 |
| `data/01_more_menu.xml`、`02_picker.xml`、`03_picker_search.xml` | 更多菜单、文件选择器、选择器搜索 | 导入本地书（TXT） |
| `data/04_book_a_imported.xml`、`04b_shelf.xml`、`05_two_books.xml`、`06_bookshelf_two.xml` | 两本书入书架（`qa_b2c_book_a` / `qa_b2c_book_b`） | 书架夹具准备 |
| `data/11_bookA_info_t2.xml`、`12_back_to_bookinfo.xml`、`12b_bookinfo_full.xml` | 未读单击→右栏 BookInfo→返回 | **场景 1：书架未读单击** |
| `data/13_longpress_bookB.xml` | 长按书 B → 右栏 BookInfo（「编辑书籍信息」「分享」） | **场景 1：长按入口** |
| `data/14_back_empty_after_replace.xml` | 点另一本替换后返回→右栏空（不叠栈） | **场景 1：replace 替换栈** |
| `data/16_auto_reader_t3.xml` | 未读自动开读→阅读器（`第一章 起点 … 33.3%`） | **场景 1：未读自动开读** |
| `data/19_readbook_direct_reader.xml` | 已读直读→阅读器 root 全屏（`第二章 重逢 … 100.0%`） | **场景 1：已读直读** |
| `data/21_explore_wide.xml`、`21b_explore_all.xml` | 发现宽屏（「选择发现分类」「QA_B2C源」） | **场景 2：发现双栏** |
| `data/22_explore_expanded.xml`、`23_explore_books.xml` | 展开源→`QA分类`→书单（3 本书） | **场景 2：分类书单** |
| `data/24_explore_bookinfo_right.xml` | 点书 A → 右栏 BookInfo（`QA_B2C未读书` / `来源：QA_B2C源` / `共 3 章`） | **场景 2：右栏 BookInfo（P1 触发点）** |
| `data/25_explore_back_list.xml`、`26_explore_bookB_right.xml`、`27_explore_back_after_replace.xml` | 返回书单→点书 B→右栏替换 | **场景 2：替换栈** |
| `data/30_rss_list_wide.xml`、`31_rss_articles_right.xml`、`32_rss_article_detail.xml`、`33_back_article_list.xml`、`34_back_rss_empty.xml` | RSS 源→文章列表→文章详情→逐级返回 | **场景 3：RSS 三级下钻** |
| `shots/24_explore_bookinfo_right.png`、`shots/27_explore_back_after_replace.png` | **左侧发现页整块灰色 `ErrorWidget`**，右侧 BookInfo/书单正常 | **P1 缺陷的直接视觉证据** |
| `server/`（17 个 `.html` + `feed.xml`） | 本地 mock 站：`explore.html`（QA 分类书单）、`book1~3`（书籍/目录/章节）、`feed.xml`（3 篇 RSS）、`article1~3`、`login.html` | 书源/RSS 夹具（宿主 `192.168.100.52:8899`） |
| `data/seed_sources.sql` | 种子 `QA_B2C源`（exploreUrl → `192.168.100.52:8899/explore.html`）与 `QA_B2C_RSS`（→ `/feed.xml`） | 夹具入库脚本 |
| `logcat/http_server.log` | 宿主 mock 访问日志：`GET /feed.xml`、`/explore.html`、`/book1.html`、`/book1_toc.html`、`/book2*` 均 200 | 证明夹具链路真实跑通 |
| `logcat/build_release.log` | `flutter build apk --release` → `app-release.apk (191.2MB)`，`assembleRelease 86.8s` | 构建产物 |
| `logcat/install.log` | `Success: streamed 200484764 bytes` | 安装（APK 200,484,764 B） |
| `data/apk_sha256.txt` | `b2c2fe6e4bb11c3c0bc7db8099397330ca73a45135427b5b0d3cf816002bd05b` | APK 哈希 |
| `data/qa_b2c_book_a.txt` / `qa_b2c_book_b.txt` | 「QA_B2C 未读测试书」/「QA_B2C 已读测试书」正文夹具 | 书架两本书源文本 |
| `data/wm_original.txt` | 物理 1080×1920 / 480 dpi | 宽屏 override 前状态 |
| `logcat/session_all.log` | 4153 行全量 logcat（20:34:58 ~ 20:41:14），`FATAL`=0、`ANR`=0、`Bad state`=0、`E/flutter`=0 | 崩溃标记核查 |
| `scripts/dev.py` | QA 交互脚本，docstring 明写「QA 2b-2c 设备交互辅助脚本（仅本机 MuMu 验收使用，不修改应用代码）。扩展自 2b-2b dev.py」 | **批次号直接自证** |

### 2.3 关键判定：这是 2b-2c 的「首轮」，与正式报告目录不同

- 本目录 mtime 集中在 **2026-11-03 20:32~20:41**，而 `b77a77dfd0`（2b-2c 收尾，pubspec
  升至 2.0.443+444）提交时间为 **20:30:08** —— 时间上紧接收尾提交，属收尾后立即验收。
- `docs/DEVICE_ACCEPTANCE_20261104_BATCH2B2C.md` 记录的首轮验收时间为 22:30~23:20、
  源码基线 `ec0a146d09`（22:30:32，已含 9b-3）、版本 2.0.445+446、证据目录
  `tmp_debug/device_acceptance_20261104/`、APK sha `690767f1…`、大小 200,697,868 B。
- 本目录的 APK 为 **200,484,764 B / `b2c2fe6e…`**、版本应为 **2.0.443+444**、无 9b-3 相关
  内容（`data/` 中无漫画图片保留项、无 `rust_build.log`）——因此本目录是**更早的一次
  2b-2c 首轮尝试**（20:30 左右），非报告所指的 22:30 那一轮。
- 两轮共同确认了同一 P1：`shots/24_explore_bookinfo_right.png` 的左侧灰色 ErrorWidget，
  与报告 §3.2 / P1-O1 描述的「`Bad state: Too many elements`（`md3_fast_scroller.dart:51`）」
  完全同构。

> 说明：本目录 `logcat/session_all.log` 中未出现 `Bad state` 文本（计数 0），因为该异常由
> 应用自捕获写入应用私有目录的 crash 文件，不进 logcat；`docs/DEVICE_ACCEPTANCE_20261104_BATCH2B2C.md`
> 所引 `data/crash_log_2245.txt` 属 22:30 那轮目录。本目录的 P1 证据以截图为准。

## 3. 批次归属判定

- **批次 = 设置批 2b-2c**「书架/发现/RSS 列表-详情双栏」设备验收（首轮，2026-11-03 20:30~20:41）。
- 版本：**2.0.443+444**（依据：收尾提交 `b77a77dfd0` 时间 20:30:08 且 pubspec 为
  `2.0.443+444`；本目录文件全部晚于该提交；下一版本 2.0.444+445 的 P2-E1 收尾提交在 21:05，
  晚于本目录最后 mtime 20:41）。**注：目录内未直接留存 versionName 文本**，此为时间链推断，
  非目录内自证。
- 批次号另有**直接自证**：`scripts/dev.py` docstring「QA 2b-2c 设备交互辅助脚本…
  扩展自 2b-2b dev.py」。
- **来源明确，非「来源不明」**。

## 4. 内容清单（按类型与子目录）

### 4.1 按类型

| 类型 | 数量 | 说明 |
|---|---|---|
| `.xml` | 33 | uiautomator 语义树，全部在 `data/`（`00_startup` ~ `34_back_rss_empty`），另有 `server/feed.xml` |
| `.png` | 26 | 截图，全部在 `shots/` |
| `.html` | 17 | 本地 mock 站页面，全部在 `server/` |
| `.txt` | 4 | `data/apk_sha256.txt`、`wm_original.txt`、`qa_b2c_book_a.txt`、`qa_b2c_book_b.txt` |
| `.log` | 4 | `logcat/` 下 `build_release.log`、`install.log`、`http_server.log`、`session_all.log` |
| `.sql` | 1 | `data/seed_sources.sql`（书源/RSS 种子） |
| `.py` | 1 | `scripts/dev.py`（QA 交互辅助） |
| **合计** | **86** | |

### 4.2 按子目录

| 子目录 | 文件数 | 组成 |
|---|---|---|
| `data/` | 37 | `.xml`×32、`.txt`×4、`.sql`×1 |
| `shots/` | 26 | `.png`×26 |
| `server/` | 18 | `.html`×17、`.xml`×1（`feed.xml`） |
| `logcat/` | 4 | `.log`×4 |
| `scripts/` | 1 | `.py`×1 |
| **合计** | **86** | |

### 4.3 注意：`data/` 与 `shots/` 编号不完全对齐

截图编号 `00/04/06/10/11/12/13/14/15/16/17/18/19/20/21/22/23/24/25/26/27/30/31/32/33/34`
共 26 张；语义树含 `02/03/05/21b/30b/32b/32c` 等截图未覆盖的步骤。两者互补，不是一一对应。

## 5. 归档说明

- 整目录复制，**未筛选**（含 mock server 的 17 个 HTML、种子 SQL、dev.py 脚本、全量 logcat）。
- 复制使用保留时间戳方式（`cp -a`），文件 mtime 仍为 2026-11-03 原始值。
- 归档前后 `diff -r` 完全一致，文件数 86 → 86。
- 原目录 `tmp_debug/device_acceptance_20261103_batch2b2c/` 在归档校验通过后已删除。
- 与并行归档的关系：本目录是 `docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.5
  点名的两个「无文档来源」目录之一；另一为 `acceptance_20261026/`。
- **不重复归档声明**：同批次后续两轮（22:30 首轮正式报告轮、23:42 回修复验轮）的证据目录
  `tmp_debug/device_acceptance_20261104/`、`tmp_debug/reverify_a2/` 不在本次范围内，由并行线处理。
