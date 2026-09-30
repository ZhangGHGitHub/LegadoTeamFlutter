# P4-3 第一波真机 QA 验收报告（STAGE-QA-P43W1）

- 日期：2026-09-29
- 执行代理：STAGE-QA-P43W1（QA 子代理，真机设备独占波次）
- 设备：MuMu 模拟器（192.168.100.62:5555，Android 15），adb root 已开启
- 被测应用：`io.legado.flutter_legado`（Rust+Flutter 重构版）
- 参考应用：`io.legato.kazusa`（参考版，仅只读基准采集）
- 证据目录：`D:\OH-WorkSpace\LegadoTeam\legado\docs\materials_1301\evidence\`（截图 + uiautomator dump）
- 纪律遵守：全程只读验证 + 书源导入；未改任何生产代码；未卸载/未清数据任何包；导入写库前已做 DB 备份。

---

## 一、验收结论总览

| 验收项 | 结论 | 关键证据 |
|---|---|---|
| 书源导入（UI 路径，写库前备份） | 通过 | 导入前 DB 备份拉回证据目录；DB 查询确认漫画书源 🎨 组 38 条在库 |
| 漫画源 #1 搜索→详情→目录→阅读器出图（hqqh 七七漫画） | 通过 | 前波截图 + books 行「全职高手」type=64 + image_cache/hqqh 域 7 jpg |
| 漫画源 #2 搜索→详情→目录→阅读器出图（🎨图库漫画 tuku.cc） | 通过 | `75_tuku_detail_crows.png`、`76_tuku_reader_crows_p1.png`、`77_tuku_reader_crows_p2.png`、ui252/254/255 |
| P4-1 漫画页级进度 | 通过 | ui256/257/258：「页数1/126 总进度0.8%」→「页数2/126 总进度1.6%」 |
| P4-2a 图片磁盘缓存 | 通过 | `image_cache/` 三域目录（guoman8.cc / hqqh.cc / tuku.cc），tuku 域 2026-09-29 20:27-28 新增 |
| 视频源 搜索→详情→播放 | 通过 | `79_video_player_ep01_waited.png`（ONE PIECE 开场帧，播放证实）；ui262/264/265 |
| P4-2b 书架视频分组 | 通过 | ui269/ui270 + `80_shelf_video_group.png`：书架出现「视频 Tab 2 of 2」，选中后仅显示视频书 |
| kazusa 参考基准 | 部分通过 | 书架分组、阅读器工具条、设置 阅读/夜间模式 tab、暗色主题均已截获；「其他设置」tab 与长按菜单未截获（见 §5 限制） |

总体判定：**P4-1 / P4-2a / P4-2b 三项功能真机验收全部通过**；视频播放链路打通；书源导入链路可用。kazusa 基准主体可用，两项子项存在采集限制（如实记录，未硬造证据）。

---

## 二、书源导入结果

- 导入方式：**UI 本地导入**（主路径），未走 DB 直写兜底。
- 导入前备份：`legado.db`（WAL 模式）已备份并拉回证据目录（前波操作，备份件在 `docs/materials_1301/evidence/` 下 db_backup 相关文件中）。
- 导入量（前波执行，本波核实在库）：
  - 漫画书源 🎨 组 **38 条**（`SELECT bookSourceGroup, COUNT(*) FROM book_sources GROUP BY bookSourceGroup` 确认 38）。
  - 影视频源 🎬 组 **10 条**（本波导入 9 条 + 其他批次 1 条），另复合组含 🎬 的 6 条。
- 视频源清单（本波查询，全部 enabled=1）：奈飞工厂、七猫短剧、非凡资源网、茶杯狐狸、量子资源网、艾格动漫、U酷资源、电源先生、榴莲影视、GScenes短剧 及各复合组源（麻豆传媒AI/黄豆短剧/VirtalTaboo/露西弗×2/终极全栖聚合）。
- 本波实测可用视频源：**非凡资源网**（http://23.225.142.42）；**奈飞工厂**详情失败（Connection reset by peer，见 §4.2 失败记录）。

---

## 三、漫画验证

### 3.1 漫画源 #1：hqqh（七七漫画）— 前波完成，本波复核

- 全链路：搜索「全职高手」→ 详情 → 目录 → 阅读器出图（前波截图）。
- 数据库复核：`books` 表存在「全职高手（hqqh）」type=64 行；`image_cache/https___hqqh.cc_index.php_qqmhcomic_quanzhigaoshou.html_81392f07/images/` 内 7 个 jpg。
- 「海贼王艾斯（国漫吧）」type=1088 行亦在前波验证（guoman8.cc 缓存域）。

### 3.2 漫画源 #2：🎨图库漫画（tuku.cc）— 本波完成（CROWS海贼版）

选择唯一关键词「CROWS海贼版」以规避同名卡片歧义（「海贼王」搜索结果卡片落点多次漂移到 🎨W漫画/再漫画卡片）。

| 步骤 | 结果 | 证据 |
|---|---|---|
| 搜索「CROWS海贼版」 | 结果 481 · 进度 62/62；顶部提示「7 个书源搜索失败，点击展开」「1 个书源需要登录」 | `ui252.xml` |
| 进入详情 | 来源：🎨图库漫画；**无换源确认弹窗**（books 表无 CROWS 行，详情纯由被点搜索结果构建） | `ui254.xml`、`75_tuku_detail_crows.png`（1,485,556 B） |
| 目录 | 1 章 126 页（第1-6话） | `ui255.xml` |
| 阅读器出图 p1 | 漫画图正常渲染 | `76_tuku_reader_crows_p1.png`（2,808,117 B） |
| 翻页（垂直滑动 540,1500→540,400） | 页数 2/126 | `77_tuku_reader_crows_p2.png`（902,495 B） |

> 备注：水平滑动不翻页——该源为**长图/滚动模式**，需垂直滑动，符合滚动式漫画阅读预期。

### 3.3 P4-1 漫画页级进度 — 通过

- 语义证据（uiautomator dump，非截图猜测）：
  - 初始：`content-desc="第1-6话 (126p) 页数1/126 章节1/1 总进度0.8%"`（`ui256.xml`/`ui257.xml`）
  - 翻页后：`content-desc="... 页数2/126 章节1/1 总进度1.6%"`（`ui258.xml`）
- 结论：进度按**页级**推进（1/126 → 2/126），总进度百分比同步重算（0.8% → 1.6%），章节位置（章节1/1）独立显示。页级进度功能真机成立。
- 旁证：hqqh「全职高手」durChapterPos 页级字段（前波 DB 复核）。

### 3.4 P4-2a 图片磁盘缓存 — 通过（三域）

`/data/data/io.legado.flutter_legado/cache/image_cache/`（注意：不在 app_flutter 下）：

```
http___www.guoman8.cc_44900__b9e0b3c9            (前波, 19:57)
https___hqqh.cc_index.php_qqmhcomic_quanzhigaoshou.html_81392f07   (前波, 18:47, 7 jpg)
https___www.tuku.cc_manga-73562__62b1be09         (本波, 20:27 新建, images/ 内 5 jpg, 20:28)
```

- 结论：图片按**域名分目录**落盘缓存；本波 tuku.cc 读图后新增第三域，时间戳与本波阅读操作吻合。双域以上磁盘缓存成立。

---

## 四、视频验证

### 4.1 播放链路 — 通过（非凡资源网）

| 步骤 | 结果 | 证据 |
|---|---|---|
| 视频范围搜索「海贼王」 | 结果 118 · 进度 16/16；「3 个书源搜索失败」；卡片含「更新至第1180集」 | `ui262.xml` |
| 详情（非凡资源网卡片） | 章节列表正常（第01集…） | `ui264.xml`、`ui265.xml` |
| 播放器 | 起播 30-55s 后出现真实视频帧（ONE PIECE 开场动画帧，非黑屏/错误页） | `78_video_player_ep01.png`（黑屏等待帧）、`79_video_player_ep01_waited.png`（出画面） |
| 加入书架 | toast 提示加入成功 | `ui268.xml` |

### 4.2 源级失败（如实记录，非代码缺陷）

- **奈飞工厂**（https://www.netflixgc.com）：详情页报 `ClientException SocketException Connection reset by peer`，章节「暂无章节」。属外部站点不可达/源失效，未硬造证据。
- 视频范围 3 个书源搜索失败、漫画范围 7 个书源搜索失败（🎨必应漫画 biyingmh.com、🎨拷贝漫画 api.mangacopy.com、🎨📦喜漫漫画 favcomic.com、🎨MY漫画辞晨（需登录）、🎨📦污漫天堂 wumtt.com 等），错误形态统一为 `Network error: Connection failed: error sending request`（Rust HTTP 客户端侧）。前波 62/62 全失败经修复后收敛为本规模，收敛方向正确。

### 4.3 P4-2b 书架视频分组 — 通过

- 语义证据：
  - `ui269.xml`（书架「全部」tab）：`content-desc="全部&#10;Tab 1 of 2"` + `content-desc="视频&#10;Tab 2 of 2"`；「全部」列表同时含小说/漫画/视频书（斗罗大陆、重生高考前99天、全职高手、阅文漫画、海贼王[视频]）。
  - `ui270.xml`（切到「视频」tab）：列表**只剩**「海贼王 99+ 第1180集」一条视频书——过滤行为成立。
- 截图：`80_shelf_video_group.png`（225,210 B，书架视频 tab 状态）。
- DB 佐证：`books` 表「海贼王（非凡资源网）」行 **type=4（视频）**，与分组过滤依据一致。
- 结论：视频书加入书架后，书架分组出现「视频」组，且该组按视频类型过滤，P4-2b 成立。

---

## 五、参考版 kazusa 基准（只读采集）

包名 `io.legato.kazusa`（注意：不是 com.legato.kazusa）。启动 `io.legado.app.ui.main.MainActivity`。

### 5.1 已截获基准点

| 基准点 | 观察 | 证据 |
|---|---|---|
| 书架分组 tabs | 未读 / 小说 / 全部 / 网络未分组 | `kz1_home.png`（+ `kz1_home.xml`） |
| 阅读器（暗色） | 深褐底（采样约 RGB(30,27,19)）白字；页脚：书名｜章节｜4/236｜100%｜Legado | `kz2_reader_open.png` |
| 阅读器工具条（点 (540,700) 唤出，非中心点——中心点会隐藏 chrome） | 顶栏：返回｜书名｜章节｜⋮｜100%｜进度圆环；底栏：目录｜书签｜⚙设置｜☰列表｜4/236｜Legado｜下一章 | `kz4_tap_top.png` |
| 设置 dialog（⚙ 578,1843） | 标题「心境」；3 tab：阅读 / 夜间模式 / 其他设置；页脚「保存/关闭」 | `kz5_reader_settings.png` |
| 设置·阅读 tab | 字号18 / 行距1.3 / 行宽400 / 宋体 / 自动翻页关 / 翻页动画切换 / 翻页模式滑动 / 左对齐 | `kz5_reader_settings.png`、`_kz5_check.jpg` |
| 设置·夜间模式 tab | 背景白色 / 日间 / 浅灰色 / 夜间模式关 / 文字黑色 / 链接#0000EE / 分隔线#00000000 | `kz6_settings_night.png` |
| 暗色主题 | 阅读器与设置 dialog 均为暗色渲染（深褐底白字），与重构版暗色阅读对比基准 | kz2/kz5/kz6 经 PIL 转 JPEG 复核（`_kz5_check.jpg` 等） |

### 5.2 未截获项（限制，如实记录）

1. **设置·其他设置 tab**：多坐标点击（x=660/690/700/780, y=1385-1395）、双击、微滑（`input swipe 690 1385 690 1386 120`）均无法切换，dialog 停留在阅读/夜间模式。可能该 tab 在当前书型下无内容或控件失效——作为参考版行为观察记录，未硬造其内容。
2. **长按图片行为基准**：kazusa 书架仅有 2 本小说（斗破苍穹/斗罗大陆），无漫画书；修改 kazusa 数据库导入漫画属越界（只读纪律）。改用小说文本页长按代理（`input swipe 540 800 540 800 900` + `kz9_longpress.png`），但**未观察到文本选择工具条**——长按事件疑似未生效（MuMu 模拟器 ROM 干扰）。结论：漫画图片长按基准在 kazusa 上**不可证明**，建议后续用可写库的参照环境补采。
3. **kazusa 阅读器语义树不可得**：uiautomator dump 在 kazusa 阅读器/设置场景一律返回过期的「书架」窗口 XML（26,735 B，与 `kz1_home.xml` 一致）——MuMu ROM 限制。kazusa 基准只能以截图为证据。

### 5.3 环境操作要点（供后续波次）

- kazusa 存在抢前台/回栈问题：切换应用前 `am force-stop io.legato.kazusa` 再重启。
- 阅读器工具条唤出点是 (540,700) 附近，中心点 (540,960) 会隐藏 chrome 而非唤出。

---

## 六、新发现清单（累计，供开发/设计波次）

1. **换源确认弹窗可绕过**：books 表无该书行时，详情纯由被点搜索结果构建，不再弹「换源确认」；删除 books 行即可复现无弹窗路径。换源本身更新的是 origin 字段而非 bookUrl。
2. **书架「全部」tab 隐藏 type=1088（其他漫画）行**（前波发现，本波 ui269 复核：全部 tab 列表无 type=1088 的「斗罗大陆(卡拉)/海贼王艾斯」行，仅视频分组出现后结构变化需再核对）。
3. **搜索结果实时性**：`searchBooks` 表仅存 rt=-1 的目录行，实时搜索结果不落库；「加载下一页」会重新触发实时搜索（本波结果数 338→397、481 等变化均如此）。
4. **搜索结果过滤仅「屏蔽词」一种**（搜索设置项，无类型过滤）。
5. **加载下一页按钮与卡片重叠**：列表滚动只能靠卡片区滑动，按钮落点易误触。
6. **搜索框输入追加 bug**：`input text` 输入会追加到旧文本后（需先清空）。
7. **崩溃恢复弹窗**：确定按钮位置漂移（前波多次遇到，位置不固定）。
8. **MuMu/ADB 方法论**（后续波次直接复用）：
   - 截图必须 `exec-out screencap -p > 本机文件.png`（screencap 无法写 /sdcard）；且产出为 **RGBA PNG**，直接 Read 预览可能深浅色误判——**必须 PIL `convert('RGB')` 转 JPEG 复核**再下结论。
   - 所有 `adb shell` 参数前加 `MSYS_NO_PATHCONV=1`，否则 Git Bash 会改写 /sdcard 类路径。
   - uiautomator dump 可能自杀：用重试循环；dump 可能拿到旧窗口（flutter/kazusa 场景高发），用文件大小/内容比对识别。
   - 避免设备端 `grep` 中文/二进制内容；`input text` 对中文可用。
   - logcat 有 `E MESA` 噪声需过滤。
   - 漫画读者翻页：滚动式长图源垂直滑动翻页，水平滑动无效。

---

## 七、阻塞项 / 未证明项

| 项 | 状态 | 说明 |
|---|---|---|
| kazusa 设置·其他设置 tab 内容 | 未证明 | tab 点击无响应，内容不可采；不影响 P4 验收（属参考版基准缺口） |
| kazusa 漫画图片长按基准 | 不可证明 | kazusa 无漫画书且禁改其库；长按代理亦被 MuMu 干扰 |
| 奈飞工厂视频详情 | 外部失败 | Connection reset by peer，源失效，非代码缺陷 |
| 漫画范围 7 源 / 视频范围 3 源搜索失败 | 外部失败 | 站点不可达/需登录，如实记录 |

无代码级阻塞项。P4-1 / P4-2a / P4-2b 全部真机验证通过。

---

## 八、证据索引（全部位于 `docs/materials_1301/evidence/`）

**截图（PNG，RGBA，已 PIL 复核关键件）**
- `75_tuku_detail_crows.png` tuku 详情（来源：🎨图库漫画）
- `76_tuku_reader_crows_p1.png` / `77_tuku_reader_crows_p2.png` 阅读器 p1/p2
- `78_video_player_ep01.png` / `79_video_player_ep01_waited.png` 视频播放器（出帧）
- `80_shelf_video_group.png` 书架视频分组 tab
- `kz1_home.png` `kz2_reader_open.png` `kz4_tap_top.png` `kz5_reader_settings.png` `kz6_settings_night.png` `kz9_longpress.png`（kazusa 基准）
- PIL 复核件：`_kz5_check.jpg` `_kz8_check.jpg` `_kz8b_check.jpg` `_kz9_check.jpg`

**uiautomator dump**
- `ui252.xml` CROWS 搜索（481 结果）｜`ui254.xml` tuku 详情｜`ui255.xml` 目录 126 页
- `ui256.xml`/`ui257.xml`/`ui258.xml` 页级进度 1/126→2/126
- `ui262.xml` 视频搜索（118 结果）｜`ui264.xml`/`ui265.xml` 视频详情/目录｜`ui268.xml` 加书架 toast
- `ui269.xml`/`ui270.xml` 书架 全部/视频 分组（P4-2b 语义证据）
- `kz1_home.xml` kazusa 书架语义（唯一可用的 kazusa dump）

**DB / 文件系统（命令内联证据）**
- `sqlite3 ... "SELECT bookSourceGroup, COUNT(*) ..."`：漫画书源 🎨=38、影视频源 🎬=10
- `sqlite3 ... books`：8 行，含「海贼王（非凡资源网）」type=4
- `ls /data/data/io.legado.flutter_legado/cache/image_cache/`：三域目录（含 tuku.cc 2026-09-29 20:27 新建）

---

*报告完。纪律自检：未改生产代码；未卸载/未清数据三包；DB 写前有备份；外部失败全部如实记录；本波次为设备唯一占用代理。*

---

## 2.0.325 冒烟与 V3 点验（2026-09-29）

> 版本 `2.0.325+326`（HEAD `b08c38b64c`）。本批改动为**纯 Dart（零 Rust）**：视频全屏新增「倍速 / 选集」浮层（对齐原版 `ChoiceSpeedDialog` / `ChoiceEpisodeDialog`，二者入口仅存在于全屏控制器）。执行代理：STAGE-QA-P43W1-SMOKE（QA 子代理）。纪律：全程只读 + 设备点验，未改任何生产代码。

### 一、冒烟测试（构建 + 安装 + 启动 + 崩溃检查）

- 命令：`pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\emulator_smoke_test.ps1 -Device 192.168.100.62:5555`
- **退出码：`0`（PASSED，7 通过 / 0 失败）**
- **构建形态：FFI REUSE + 轻构建**。FFI 校验 `[OK] arm64-v8a / x86_64`（Rust 源码指纹 `2895a9fc…` 与 content hash `1549248103` 一致，**复用现有 .so，未触发 Rust 重编**）；Dart 侧 `assembleDebug` 仅 **5.3s**（增量，产物 282.3 MB）。与本批「纯 Dart（零 Rust）→ 预期 REUSE / 轻构建」一致，如实记录。
- **版本复核：`已装版本与 pubspec 一致（2.0.325）`**（pubspec `2.0.325+326`，versionName=2.0.325 / buildNumber=326）。
- **FATAL：`0`**（`[PASS] 无崩溃日志（FATAL/E/flutter）`）。
- 进程存活：`pidof` → pid 47781（`R io.legado.flutter_legado`）。
- 结论：冒烟**通过**。本批纯 Dart 改动下构建链路无回归。

> 旁证（前段会话，非本冒烟产生）：应用启动时曾出现应用内「上次运行发生崩溃（崩溃时间 2026-09-29 20:30:27）」恢复弹窗（`v3_01_crash_dialog.png`），其崩溃时间点早于本次冒烟（约 20:47），属**前一会话**崩溃，非本批构建引入；本次冒烟 FATAL=0，当前构建干净。

### 二、V3 全屏「倍速 / 选集」点验（用设备已有视频书：非凡资源网·海贼王，第02集）

**方法说明**：视频播放中 uiautomator 无法达到 idle（`could not get idle state`，位置持续更新 / 视频持续渲染），故采用「**双击暂停视频 → 画面静止 → uiautomator dump（content-desc 语义树）**」技巧取证，辅以截图与 `[VideoPlay]` logcat。所有播放屏语义证据均取自**暂停态**（可复现、非截图猜测）。

| 步骤 | 验证点 | 结论 | 关键证据（content-desc / 日志 / 截图） |
|---|---|---|---|
| a | 书架视频组 → 海贼王 → 进播放屏并起播 | 通过 | `[VideoPlay] chapter=第01集 url=…/10135_…/index.m3u8`；`v3_04_video_screen.png`、`v3_05_current.png` |
| b | **全屏**：底栏出现「倍速」「选集」入口；**非全屏**：二者不存在 | 通过 | 非全屏 `v3pause_portrait.xml`（底栏仅 播放/14:25//25:19/全屏，无倍速/选集）+ `v3_06_portrait_nofull.png`；全屏 `v3_fullscreen.xml`（`content-desc="倍速"` 与 `"选集"` 各 1，位于 `退出全屏` 左侧）+ `v3_07_fullscreen.png`。与代码 `if (_isFullScreen) …倍速/选集…` 一致 |
| c | 倍速浮层：8 档**降序** + 当前 1.0 高亮 → 选 1.5x → 入口文案变「1.5X」+ 屏中提示「1.5倍播放中」 | 通过 | 浮层 `v3_speed_dialog.xml`：8 项依序 `3.0X/2.5X/2.0X/1.5X/1.25X/1.0X/0.75X/0.5X`（右靠 30% 宽全高）+ `v3_08_speed_dialog.png`；选 1.5X 后 `v3_speed15.xml`：`content-desc="1.5X"`（入口，位于原倍速位 `[1368,924][1560,1068]`）+ `content-desc="1.5倍播放中"`（屏中提示）+ `v3_09_speed15_tip.png` |
| d | 切下一集（第02集）→ 倍速**保持 1.5x**（会话级） | 通过 | `[VideoPlay] chapter=第02集 url=…/10134_…/index.m3u8` + `controller ready` + `after play isPlaying=true`；暂停后 `v3_ep2_paused.xml` 入口仍 `content-desc="1.5X"`（非「倍速」）+ `v3_11_ep2_speed15.png`。与代码「新章 controller init 时 `_playbackSpeed!=1.0` 则 setPlaybackSpeed 恢复」一致 |
| e | 选集浮层：章节列表 + 当前集定位 → 点集跳转 | 通过 | `v3_episode_dialog.xml`：标题 `content-desc="选集（1180）"`（海贼王 1180 集），右靠 40% 宽全高，列表 `第01集…第07集`（当前集第01集位于列表顶部）+ `v3_10_episode_dialog.png`；点「第02集」后 logcat `chapter=第02集` 证实跳转成功 |
| f | 退出并**重进应用** → 倍速回 **1.0**（不持久化） | 通过 | `am force-stop` + 重启（新 pid 46885）→ 重新进入海贼王视频屏（resumed 第02集）→ 进全屏后 `v3_f_fullscreen.xml` 入口为 `content-desc="倍速"`（=1.0，**非** `1.5X`）+ `v3_14_reenter_fullscreen.png`。与代码 `_playbackSpeed=1.0` 为会话级字段、**从不写入 SharedPreferences** 一致 |

**总体判定：V3 全屏「倍速 / 选集」六项点验（a–f）全部通过**，行为与原版语义一致（入口仅全屏、倍速会话级不持久化、选集按集跳转、切集保持倍速）。

### 三、方法与限制（如实记录，未硬造）

1. **uiautomator idle 失效**：视频屏（播放/全屏）无法 `uiautomator dump`（`could not get idle state`）。对策：双击暂停视频令画面静止后 dump 成功。**所有播放屏语义证据均取自暂停态**，非播放中实采。
2. **倍速高亮（1.0X）为视觉态**：uiautomator dump 无法区分高亮底色。该项以**代码逻辑**（`highlighted: (value - currentSpeed).abs() < 0.001`，currentSpeed=1.0 → `1.0X` 项高亮）+ 截图 `v3_08_speed_dialog.png`（视觉证据）确认；dump 仅证明 8 项**存在且顺序正确**。
3. **实际播放速率（1.5x）为 ExoPlayer 内部态**：uiautomator 无法直接读取。经「入口文案 `1.5X` + 提示 `1.5倍播放中` + 代码路径（`_controller.setPlaybackSpeed(1.5)` 及新章恢复）」三方印证，未单独断言解码器倍速值。
4. **当前集滚动定位**：本次验证时处于第01集（首集），列表天然置顶，`setSelectionFromTop`（current>0 才滚动）的**中段剧集滚动定位**未在「中间集」场景实测，如实记录为未覆盖分支（代码逻辑已核对）。
5. **VM service `ext.flutter.*` 扩展方法不可用**：本连接对 `ext.flutter.*` 一律 `Method not found`（-32601），故坐标 / 状态读取改走 uiautomator dump（暂停态）+ logcat 路线；未影响结论。
6. **崩溃恢复弹窗**（前段会话，见一、旁证）：非本批构建引入，本次冒烟 FATAL=0。

### 四、本段证据索引（均位于 `docs/materials_1301/evidence/`）

**截图（PNG，命名 `v3_*.png`）**
- `v3_00_app_current.png` / `v3_01_crash_dialog.png` / `v3_02_video_group.png` / `v3_03_after_tap_hai.png` / `v3_04_video_screen.png` / `v3_05_current.png`（a：进入播放屏）
- `v3_06_portrait_nofull.png`（b：非全屏，无倍速/选集）｜`v3_07_fullscreen.png`（b：全屏，倍速/选集在列）
- `v3_08_speed_dialog.png`（c：倍速浮层 8 档）｜`v3_09_speed15_tip.png`（c：1.5X + 提示）
- `v3_10_episode_dialog.png`（e：选集浮层 选集（1180））｜`v3_11_ep2_speed15.png`（d：切第02集后仍 1.5X）
- `v3_12_relaunch.png` / `v3_13_reenter_video.png` / `v3_14_reenter_fullscreen.png`（f：重进后倍速回 1.0）

**uiautomator dump（content-desc 语义树，`.xml`）**
- `v3pause_portrait.xml`（非全屏底栏，无倍速/选集）｜`v3_fullscreen.xml`（全屏底栏，倍速/选集/退出全屏）
- `v3_speed_dialog.xml`（倍速 8 档降序）｜`v3_speed15.xml`（1.5X 入口 + 1.5倍播放中）
- `v3_episode_dialog.xml`（选集（1180）+ 剧集列表）｜`v3_ep2_paused.xml`（第02集暂停，入口仍 1.5X）
- `v3_relaunch.xml` / `v3_video_group.xml`（重进·书架/视频组）｜`v3_f_reenter1.xml`（重进·非全屏）｜`v3_f_fullscreen.xml`（重进·全屏，入口「倍速」=1.0）

**logcat（`[VideoPlay]`，命令内联证据）**
- 第01集 / 第02集 chapter 加载、`controller ready`、`after play isPlaying=true`（切集与起播）
- 重进后 `chapter=第02集`（last-watched 恢复）

*本段纪律自检：未改生产代码；设备点验全程只读；暂停/重进均为可恢复操作；限制项（高亮/实际倍速/中段滚动/VM 扩展）全部如实标注，未硬造证据。*

## 2.0.326 冒烟与波次2 漫画点验（2026-09-29）

> 本段为 STAGE5-SMOKE-326（STAGE-QA-P43W2-SMOKE）：QA 子代理，对波次 2 漫画阅读器改动做最终真机验证。仓库 HEAD `b13b067e82`，版本 `2.0.326+327`。本批为纯 Dart 改动（含此前波次累计），构建预期 FFI REUSE + 轻构建。全程设备点验只读，**未改任何生产代码**；任何与预期不符处均如实记为问题项，不硬造证据。

### 一、冒烟测试（构建 + 安装 + 启动 + 崩溃检查）

- 命令：`pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\emulator_smoke_test.ps1 -Device 192.168.100.62:5555`
- **结果：PASSED 7/7（exit 0）**。构建形态为 **FFI REUSE + 轻构建**（符合纯 Dart 批次预期）；版本号 `2.0.326+327`；logcat **无 FATAL**。
- 证据：`w2_00_smoke_home.png`（启动首页）/ `w2_01_home.xml`。

### 二、设备环境与素材

- 设备：MuMu「Test测试」`192.168.100.62:5555`（Android 15），adb `D:\Android\platform-tools\adb.exe`，1920×1080 横屏 / density 480；dump 坐标可直接用于 `input tap`。
- 包名：`io.legado.flutter_legado`。
- 漫画素材：任务原「CROWS 海贼版 / 七七漫画·全职高手」素材不可达（源未收录），本波**以《咒术回战》（tuku.cc / 📜图库漫画，309 章，最长 198 页）替代**；替代一事记为问题项（见 ②）。

### 三、逐项点验结论（8 项）

| # | 项目 | 结论 | 关键证据（页脚 / content-desc / 截图） |
|---|---|---|---|
| 1 | 默认回归（条漫默认 / 翻页 / 页脚页码 / 退出重进进度恢复） | **通过** | 默认模式=条漫（`w2_81_settings_default.xml`「翻页模式&#10;条漫」）；阅读器打开页脚「第00卷 (198p) 页数1/198 章节1/309」（`w2_78_reader_open.xml`）；退出重进恢复至 页数2/198（`w2_80_reenter.xml`） |
| 2 | 滚动模式 5 项切换（条漫/条漫（间隔）/L2R/R2L/T2B），默认条漫，R2L 反转 | **部分通过（1 项不符）** | 5 项均可切换、默认条漫确认；**R2L 九区未反转**（左区=上一页，与 L2R 相同；任务预期左=下一页）→ 见问题 ③ |
| 3 | 九区点击 + 章节边界（末页 next→下一章、首页 prev→上一章） | **通过（含 2 项不符）** | 末页 15/15 右区→落下一章 ch156 页数1/17（`w2_95`）；首页左区→落上一章 ch155 页数1/15（`w2_95`）；不符项 ⑪⑫ 已记录 |
| 4 | 恢复会话后切章落点（须落 1/N） | **通过** | ch155 读至 页数3/15 → 退出 → 重进恢复 页数3/15（`w2_93_reenter_p3.xml`）→ 下一章 → **落 页数1/17 章节156/309**（`w2_94_ch156_landing.xml`） |
| 5 | 长按页面菜单（分享图片/复制链接/保存图片；复制出 toast；关闭后阅读继续） | **通过（toast 文本不可证）** | 菜单 3 项 `保存图片 / 分享图片 / 复制链接`（`w2_96_longpress_menu.xml`）；复制链接后菜单关闭、阅读继续；toast 文本 a11y 不可读 → 见 ⑭ |
| 6 | 自动翻页（开关 + 1-15 速度滑杆；分页自动翻、条漫自动滚；控制栏打开时暂停；关闭停止；滑杆持久 / 开关不持久） | **通过** | 详述见下（`w2_98/99/100/102/103` 双轮证据） |
| 7 | 页面适配（单页 6 选项；条漫不显示；选中改变渲染） | **通过（1 项标签不符）** | 6 项下拉「全屏适配/拉伸/适配宽度/适配高度/原始大小/智能适配」（`w2_88_fit_dropdown.xml`）；条漫面板无「页面适配」行（`w2_90_taoman_panel.xml`）；选「适配宽度」渲染可见变化（`w2_89_fit_width.xml`）；第 6 项标签「原始大小」vs 任务「原始尺寸」→ 见 ⑤ |
| 8 | （可选）条漫自动滚动跨章且不跳章尾 | **通过（含长停留）** | 条漫自动滚动确有位移（像素差证明），重进落 ch157 1/18 证明发生跨章；但边界停留极长（≥90s）→ 见 ⑬；未跳章尾内容（先精确停在末页 17/17，`w2_101_taoman_autostop.xml`） |

#### 点验 6（自动翻页）详述
- **开 + 自动翻**：L2R 单页模式开关 ON 后页面自动前进（5→8→10→17/17）；滑杆 3 档起，拖至 10 档后显示「自动速度&#10;10 档」（`w2_98_auto_speed10.xml`）。
- **控制栏打开时暂停**：控制栏打开期间页脚固定 + 像素差为 0（L2R 与条漫两态均证），即控制栏打开时自动翻页/滚动暂停，关闭后恢复。
- **关闭停止**：开关 OFF 后页面固定 20s 不动（`w2_99_switch_off_10.xml` 全部 Switch `checked=false`）。
- **重启持久化（双轮证据）**：
  - `w2_100_slider_persist.xml`：force-stop + 冷启动后打开开关显示「自动速度 10 档」→ **滑杆值持久化**。
  - `w2_102_after_restart_panel.xml`：冷启动后自动翻页 Switch `checked=false`（force-stop 前为 ON）→ **开关状态不持久**（符合预期：开关不持久、滑杆值持久）。
  - `w2_103_slider_persist2.xml`：第二次冷启动复证——开关打开后仍显示「自动速度 10 档」，滑杆值仍为 10 档。

#### 点验 3（九区）单页模式行为小结
- L2R：左区=上一页、右区=下一页（底区=下一页）。
- R2L：左区=上一页（**未反转**，与 L2R 相同）→ 问题 ③；T2B 顶区点击打开控制栏而非上一页 → 问题 ④。
- 边界：末页右区→下一章、首页左区→上一章（均通过，`w2_95`）。

### 四、问题清单（如实记录，与预期不符均记为问题项）

| # | 问题 | 级别 | 证据 |
|---|---|---|---|
| ① | 搜索结果列表不可用（搜索结果页点击无响应/死态）——非本波代码引入 | 中 | `w2_73-75`（前波证据） |
| ② | 「CROWS 海贼版 / 七七漫画·全职高手」素材不可达，本波以《咒术回战》(tuku) 替代 | 素材 | — |
| ③ | R2L 九区未反转：左区=上一页（与 L2R 相同），任务预期左=下一页 | 高 | `w2_83` / `w2_85` |
| ④ | T2B 顶区点击打开控制栏，而非翻到上一页 | 中 | — |
| ⑤ | 页面适配第 6 项标签为「原始大小」，任务书作「原始尺寸」（标签不一致） | 低 | `w2_88_fit_dropdown.xml` |
| ⑥ | 页脚在页面列表加载完成前显示占位「页数1/1」 | 低 | — |
| ⑦ | 条漫首点中心被吞（需第二次点击才开控制栏） | 低 | `w2_102` |
| ⑧ | 阅读器退出后「阅读」按钮一度无响应，直至进程重启（transient） | 高 | `w2_91_readbtn_dead.png/.xml` |
| ⑨ | T2B 中心单击一次跳至 ch155（50.2%）（一次性） | 低 | — |
| ⑩ | TOC 页数元数据与实际页数不符（5p→15 页、6p→17 页，源数据问题） | 低 | `w2_94/95` |
| ⑪ | 末页左区点击→落到章首（1/17）而非上一页（16/17） | 中 | `w2_95` |
| ⑫ | 分页自动翻页停在章末页（L2R 不自动跨章） | 低 | — |
| ⑬ | 条漫自动跨章边界停留极长（≥90s） | 中 | `w2_101` |
| ⑭ | 复制链接 toast 文本不可证（a11y/OCR 限制） | 低 | `w2_97_copylink_toast.png` |
| ⑮ | ch155/156 加载卡顿 30-90s（网络） | 环境 | — |
| ⑯ | 启动时 logcat「A RenderFlex overflowed by 250 pixels on the bottom」布局告警 | 低 | logcat |

### 五、方法与限制（如实记录，未硬造）

1. **当前模型不支持图片输入**：全部视觉识别走 uiautomator dump（text/content-desc 节点）或 PIL 程序化亮度/方差/差值分析；未直接「看图」。
2. **uiautomator 动画/播放中无法 idle**：均取暂停态取证；滚动位移以像素差（15s 截图差，step 8，阈值 >30）证明。
3. **页脚页码文字（如「页数3/126」）是最可靠落点证据**，优先采用。
4. **九区点击均为轻点（tap，非 swipe）**；翻页动画结束后再点下一次。
5. **toast 文本 / 自动翻页速度**为内部态不可直读，经「入口文案 + 像素差 + 代码路径」三方印证，未单独断言。
6. **多次冷启动 / 退出**均为可恢复操作，不影响后续点验。

### 六、本段证据索引（均位于 `docs/materials_1301/evidence/`）

**冒烟 / 启动**：`w2_00_smoke_home.png` / `w2_01_home.xml`

**搜索 / 探索 / 进入读者**：`w2_59-76` 系列（tuku 过滤、展开卡片、全部 chip、咒术回战行、详情页、`w2_77_jujutsu_detail`）

**读者默认 / 进度恢复**：`w2_78_reader_open`（条漫 1/198）/ `w2_80_reenter`（恢复 2/198）/ `w2_81_settings_default.xml`（默认条漫）

**模式切换 / 九区**：`w2_83_r2l`（R2L）/ `w2_84_r2l_p2` / `w2_85_r2l_after_lefttap` / `w2_86_t2b_p1` / `w2_89_fit_width`（适配宽度渲染）

**页面适配**：`w2_87_fit_row`（适配行）/ `w2_88_fit_dropdown`（6 项下拉）

**条漫面板**：`w2_90_taoman_panel`（无「页面适配」行）

**「阅读」按钮死态**：`w2_91_readbtn_dead`

**切章落点**：`w2_92_ch155_p3` / `w2_93_reenter_p3` / `w2_94_ch156_landing`（1/17）/ `w2_95_lastpage_next`（边界）

**长按菜单**：`w2_96_longpress_menu`（3 项）/ `w2_97_copylink_toast`

**自动翻页**：`w2_98_auto_speed10`（10 档）/ `w2_99_switch_off_10`（开关关）/ `w2_100_slider_persist`（重启后滑杆持久）

**条漫自动跨章**：`w2_101_taoman_autostop` / `w2_101_taoman_scroll_p1`

**重启后面板**：`w2_102_after_restart_panel`（开关关）/ `w2_103_slider_persist2`（滑杆仍 10 档）

*本段纪律自检：未改生产代码；设备点验全程只读；重启/退出均为可恢复操作；限制项（toast 文本 / 自动翻页速度 / R2L 未反转 / 标签不一致）全部如实标注，未硬造证据。*

---

## 2.0.327 复验与 ⑧④ 取证（2026-09-30）

> 本轮为 QA 子代理 RE2 批次：Wave-2 条漫批量修复 9993170c76（滚动完成回调当下复检章末即切章，不再多等一周期）在 2.0.327+328（HEAD=4f21559f7f）上的设备复验，外加 ⑧（阅读按钮孤儿 overlay）复现取证与 ④（T2B 顶中格点击）顺带核实。
> 设备：MuMu「Test测试」 192.168.100.62:5555（Android 15，横屏 1920×1080）；包名 io.legado.flutter_legado；全程只读，未改任何生产代码。
> 素材：《咒术回战》（详情来源=天脉漫画，219 章；tuku.cc 源未沿用，任务允许另选可达源）。

### 一、冒烟（emulator_smoke_test.ps1 -SkipBuild -CheckUI）

- **构建形态**：复用仓库既有 APK `flutter_legado/build/app/outputs/flutter-apk/app-debug.apk`（mtime 2026-09-30 09:21，与设备 lastUpdateTime=2026-09-30 09:21:37 一致）。版本链：已装 versionName=2.0.327 == pubspec `2.0.327+328`；版本号仅在 HEAD（4f21559f7f）升至 2.0.327 → 该 APK 必为 HEAD 构建，含修复 9993170c76。
- **结果：7 PASS / 0 FAIL，退出码 0**：设备在线 / install -r 成功 / 版本一致 2.0.327 / 进程存活（pid 15691）/ 无 FATAL 与 E/flutter 崩溃日志 / UI 主界面（书架/发现/订阅/我的）正常。

### 二、⑬ 条漫自动翻页章尾切章时机（复验，闭项）

- 设置：翻页模式=条漫，自动翻页 ON，自动速度三档各测：15档（100%，最快）/ 中速（64% 左右）/ 滑块最左（0%，最慢）。条漫刻度 15 档（任务书 5–10 档为单页 10 档刻度，条漫实际刻度 15 档，已如实换算）。
- 量化（设备时间戳逐样本轮询，间隔为上限值）：
  - **15 档（最快）**：14 次有效跨章，章尾 X/X → 新章 1/N 间隔 2.7–13.7s；
  - **中速**：与 15 档同批时间线（hires_15dang.txt）；
  - **最慢档（0%）**：22 次跨章（第29→52话），间隔 2.8–17.1s（均值 10.3s），**无 ≥30s 停顿**；
  - 缓存章跨章（如 21→22 / 35→36 / 37→38）间隔 ≤2.9s ≈ 落定+500ms；冷章跨章 ≈10–17s，延长部分为新章网络加载窗口（过渡期 content-desc 缺失的 LOADING 窗口，最长 ~24s），非切换逻辑等待。
- **结论：三档速度共 49 次跨章，均无 ≥90s 额外周期；旧缺陷（低速多等一周期 ≥90s）未复现。修复 9993170c76 有效，⑬ 闭项。**
- 证据：`timeline_13.txt`（15档）/ `hires_15dang.txt`（中速）/ `lowspeed_13.txt`（低速）/ `re2_13_tankobon_autoscroll.png`

### 三、⑫ L2R 单页自动翻页跨章页脚（复验，闭项）

- 设置：翻页模式=从左到右（L2R 单页），自动翻页 ON，自动速度 SeekBar=100%（单页 10 档拉满）。材料：第52→53→54 话（近期已加载区，加载快）。
- 量化（`l2r_12.txt`，60 样本 10:15:58–10:21:02，约 5.1s/样本）：
  - 52 6/6 → 53 1/19：章尾末次采样 10:16:08，新章 1/19 首现 10:16:13，间隔 ≤5.1s（一个轮询周期）；
  - 53 19/19 → 54 1/20：末次 10:20:50，新章首现 10:20:55，间隔 ≤5.1s；
  - 章尾页 N/N 驻留最多 2–3 个采样（≤10s）后即切新章；页内连续 18 次翻页节奏 5.1s/页（=轮询周期，定时周期 ≤5.1s）。
- **结论：跨章后页脚在约 1–2 个周期内推进到新章 1/N；上次"停在 17/17"页脚冻结未复现，⑫ 闭项。**
- 证据：`re2_12_l2r_start.png` / `l2r_12.txt`

### 四、⑧ 阅读按钮孤儿 overlay 拦截（复现取证）

- 复现路径：阅读器（L2R 自动翻页中）→ BACK 回详情页 → 立即点 阅读 FAB（1727,948）；另加一次详情页 HOME 后台→前台（am start 恢复）变体。
- **共 7 次尝试（10:21:51 / 10:22:05 / 10:22:18 / 10:22:31 / 10:22:49 / 10:23:10 / 10:23:28，毫秒级时间戳见草稿），7/7 全部成功进入阅读器**（页脚 第54话 3/20）。
- 点按前详情页 dump（`re2_08_detail_page_dump.xml`）：视图树正常；全屏 [0,0][1920,1080] 节点仅为标准根 FrameLayout/LinearLayout/content/Flutter View，**未观察到**上次报告的"同层全屏 ImageView 孤儿覆盖层"；阅读 FAB 节点 clickable=true enabled=true，bounds=[1583,864][1872,1032]。
- **结论：本会话 7/7 未复现 ⑧（概率性缺陷，证据不足）。按要求如实记录尝试步骤与次数，不强行下"已修复"结论；⑧ 维持开放，待后续会话再取证。**
- 证据：`re2_08_detail_page_before_tap.png` / `re2_08_detail_page_dump.xml` / `re2_08_reader_opened_after_tap.xml`

### 五、④ T2B 顶中格点击核实（顺带）

- 设置：T2B 单页（从上到下），自动翻页 OFF，第54话 3/20，控制栏隐藏。
- 试验：点九区顶中格（x=960 屏幕中心，y≈1/6 高度）3 次（10:24:33 / 10:24:41 / 10:24:50），每次 2s 后 dump 均仅页脚节点、控制栏未出现 → **纯 no-op**；对照组点屏幕中心（960,540）→ 控制栏正常出现，证明输入通路正常（no-op 非"点不进去"）。
- **结论：T2B 顶中格=纯 no-op，与参考版本（-1=纯 no-op）一致；上次观察到的"顶中点击打开控制栏"偏差本次 3/3 未复现 → ④ 核实通过，无待修偏差。**
- 证据：`re2_04_t2b_reader.png` / `re2_04_t2b_topcenter_noop.xml`

### 六、本段证据索引（均位于 `docs/materials_1301/evidence/`）

**冒烟 / 残留状态**：`re2_00_preset_residual.png/.xml` / `re2_10_home.png`

**⑬ 条漫自动跨章**：`re2_13_tankobon_autoscroll.png` / `timeline_13.txt` / `hires_15dang.txt` / `lowspeed_13.txt`

**⑫ L2R 单页跨章**：`re2_12_l2r_start.png` / `l2r_12.txt`

**⑧ 阅读按钮取证**：`re2_08_detail_page_before_tap.png` / `re2_08_detail_page_dump.xml` / `re2_08_reader_opened_after_tap.xml`

**④ T2B 顶中格**：`re2_04_t2b_reader.png` / `re2_04_t2b_topcenter_noop.xml`

**过程草稿（含毫秒级尝试时间戳）**：`re2_draft.md`

*本段纪律自检：未改任何生产代码；设备操作全程只读/可恢复；跨章间隔为轮询上限值（2s 或 5.1s 采样粒度）已如实标注；⑧ 未复现按概率性缺陷如实记录 7 次尝试不硬造结论；④ 以对照组排除输入通路因素；tuku 源不可达/换源情况已注明。*


## 2.0.328 冒烟（2026-09-30）

> 本轮为 QA 子代理 RE3 批次（STAGE5-SMOKE-328）：2.0.328+329（HEAD=7b7bbe6175）装机冒烟（快速）。本批 E4 漫画 0图错误态 / 章级重试 / 卷分隔页小改动已由 3 项 widget 测试覆盖，无需真机行为点验；此处只做设备可用性冒烟 + 漫画屏无回归简单点验（出图 / 翻页 / 退出）。
> 设备：MuMu「Test测试」 192.168.100.62:5555（竖屏 1080×1920）；包名 io.legado.flutter_legado；全程只读，未改任何生产代码，亦未做换源/导入等数据变更。
> 书架漫画书：共 4 本（进度 100/17/50/0），其中 2 本漫画：《月球探索…》（国漫·冒险·连载中，共 101 章，来源=七七漫画）与《海贼王》（共 1180 章，来源=非凡资源网）。

### 一、冒烟（emulator_smoke_test.ps1 -Device 192.168.100.62:5555）

- **构建形态**：flutter build apk --debug 全量执行（Gradle assembleDebug 14.0s，√ Built，282.3 MB）；FFI content hash 校验通过（arm64/x86_64 指纹一致，复用现有 .so）。
- **结果：7 PASS / 0 FAIL，退出码 0**：设备在线 / install -r 成功 / 版本一致 2.0.328（与 pubspec 一致，HEAD=7b7bbe6175）/ 进程存活（pid 27515）/ 无 FATAL 与 E/flutter 崩溃日志。
- 证据：`re3_smoke_raw.log`
- （首次调用因 Git Bash 反斜杠路径把 pwsh 参数转义为 `.scriptsemulator_smoke_test.ps1` 报 64；改正斜杠绝对路径重跑成功——环境问题，非脚本缺陷。）

### 二、漫画屏简单点验（无回归）

- 路径：启动应用 → 书架 → 第 3 本漫画封面点选直达阅读器（续读，进度 50%）→ 点屏幕唤出控制栏（返回 / 漫画设置 / 50%）→ 漫画设置（阅读模式=从上到下 T2B 单页、全屏适配、自动翻页 OFF、灰度/电子纸）→ 上滑翻页 → 点「返回」回书架。
- **出图**：阅读器全屏 ImageView [0,0][1080,1920] 正常渲染（首图 1.7MB PNG，非空白），漫画屏无崩溃 / 白屏 / 0图错误。
- **翻页**：T2B 模式上滑翻页，翻页前后 screencap 哈希不同（`5eadc061…` → `b92e9603…`），页面切换生效。
- **退出**：点「返回」干净退回书架，应用仍存活、无 FATAL。
- **来源说明（如实）**：本机书架漫画书为七七漫画 / 非凡资源网源，**非** tuku.cc / 天脉漫画（RE2 会话的《咒术回战》=天脉漫画已不在本书架）；换源面板可正常打开（源名在 a11y 树不可读），未做换源以免改数据。漫画屏出图 + 翻页已在漫画书上验证，E4 本批无真机行为点验项（widget 测试已覆盖）。
- 证据：`re3_20_manga_reader_p1.png`（首屏）/ `re3_22_manga_reader_p1.png`（翻页前）/ `re3_21_manga_reader_p2.png`（翻页后）/ `re3_30_shelf_final.png`（书架收尾）

### 三、环境陷阱（供后续设备 QA）

- Git Bash 下 `adb shell uiautomator dump /sdcard/...` 参数被 MSYS 路径转换破坏 → uiautomator 未写新文件、pull 一直拿到旧文件（表象「dump 不随界面变化」）；用 `export MSYS_NO_PATHCONV=1` 或唯一文件名规避。
- uiautomator dump 进程 Shutdown thread 偶发 SIGSEGV（无害，但当次可能不写文件）。
- 点选「无响应」先核查是否读到陈旧 dump；原生 `input tap/keyevent` 实际生效。

*本段纪律自检：未改任何生产代码；设备操作全程只读/可恢复（未做换源/导入/数据变更）；漫画书来源非 tuku.cc/天脉已如实注明、不硬造「按目标源完成」；翻页判定以 screencap 哈希差异为准（当前模型不支持图像输入，以 a11y 树 + 哈希对比为证据）。*

## M1 菜单 UI 装机采证（2026-09-30）

> STAGE-QA-P43M1（QA 子代理）：2.0.329-dev 漫画菜单重构（对齐参考版：顶栏胶囊+底栏两行）装机采证——构建装机 + 结构 dump + 截图，供主代理视觉比对。HEAD=11a4ea3d9a，pubspec 2.0.328+329（装机显示 2.0.328，本批未升版本号属预期）。设备 MuMu「Test测试」192.168.100.62:5555（竖屏 1080×1920）。被测书：阅文漫画《全职高手》（共 101 章），测试起点 ch25「预告」。
> 判定方法：当前模型不支持图像输入，结构断言以 uiautomator dump（content-desc/bounds）+ PIL 像素采样为证据；截图（`docs/materials_1301/evidence/m1_*.png`）为人工视觉比对素材。全程未改任何生产代码。

### 一、冒烟（emulator_smoke_test.ps1 -Device 192.168.100.62:5555）

- **结果：7 PASS / 0 FAIL，退出码 0**。构建形态 flutter build apk --debug（322 MB；FFI content hash 校验通过，复用 .so）；版本 2.0.328 与 pubspec 一致；进程存活（pid 5649）；无 FATAL/E/flutter。
- 证据：`m1_smoke_raw.log`

### 二、逐项结构断言表（浅色菜单 `m1_menu_open.xml`；ch25 预告 p4/24）

| 断言项 | 期望 | 实测（bounds / content-desc） | 判定 |
| --- | --- | --- | --- |
| 顶栏·返回 | 顶栏左键 | Button [48,84][168,204] desc=返回 | 通过 |
| 顶栏·标题胶囊 | 书名+章名单行省略号 | View [216,84][864,204] desc=书名+章名（⚠ 混入污染书名列表，见异常 1） | 通过（UI 侧正确） |
| 顶栏·刷新 | 顶栏右键 | Button [912,84][1032,204] desc=刷新 | 通过 |
| 底栏 Row1·上一章 | 滑条左 | Button [99,1533][219,1653] desc=上一章 | 通过 |
| 底栏 Row1·滑条 | 页数 X/N 语义 | SeekBar [306,1521][450,1665] desc=「页数 4/24」 | 通过 |
| 底栏 Row1·下一章 | 滑条右 | Button [861,1533][981,1653] desc=下一章 | 通过 |
| 底栏 Row2·目录 | 左 | Button [99,1683][219,1803] desc=目录 | 通过 |
| 底栏 Row2·自动 | 中（开起后=停止） | Button [480,1683][600,1803] desc=自动 | 通过 |
| 底栏 Row2·翻页设置 | 右 | Button [861,1683][981,1803] desc=翻页设置 | 通过 |
| 目录 sheet | 标题「目录(N)」/ 当前章高亮 / 点行跳章 | desc=目录(101)；最新在前（25=预告=当前章）；row25 高亮底 (236,223,220) vs 其他行 (226,226,226)；点 row26→第01话 p1/50、26/101、24.8% | 通过 |
| 自动切换 | 自动↔停止往返 | desc 自动→(tap)停止→(tap)自动；ON 态截图 `m1_auto_toggled.png` | 通过 |
| 翻页设置 | MangaConfigSheet 打开 | 「漫画设置」+阅读模式/翻页模式（从上到下、全屏适配）/自动翻页 Switch/显示效果/色彩滤镜 | 通过 |
| 刷新 | 收起菜单+重载当前章 | 缓存命中即时恢复（两帧 md5 相同，loading 中间帧未捕获——如实注明）；恢复后状态正常 | 通过 |
| 收起态 | 动画后干净画面+页脚 | `m1_menu_collapsed.png`（该态 xml 仅页脚节点） | 通过 |
| 滑入动画 | 200ms 淡入/滑入 | 代码 `_menuCtrl` 200ms（reader_comic_screen.dart L225-227）；录屏 `m1_anim_record.mp4` 抽帧：中间帧 `m1_menu_anim_mid.png`（t≈0.62s 顶栏 alpha≈90%）+ 落定帧 `m1_menu_anim_settled.png`，两端点态互证 | 通过 |
| 暗色主题菜单 | 面板/胶囊暗色系，非恒黑非纯白 | 切深色→重进阅读器（ch26）采证 `m1_menu_open_dark.png/xml`：结构 bounds 与浅色一致；胶囊底 (29,32,36)、底栏面板 (67,67,67)；浅色对照 (240,240,240)/(193,191,189)；已切回「跟随系统」还原（`m1_theme_restored.png` 背景 (244,244,244)） | 通过 |

- 证据总表（`docs/materials_1301/evidence/`）：`m1_smoke_raw.log`、`m1_home.png/xml`、`m1_reader_open.png/xml`、`m1_menu_open.png/xml`、`m1_toc_sheet.png/xml`、`m1_toc_scrolled.png/xml`、`m1_toc_row25.png/xml`、`m1_after_chapter_jump.png/xml`、`m1_auto_toggled.png`、`m1_config_sheet.png/xml`、`m1_refresh_loading.png`、`m1_refresh_done.png/xml`、`m1_menu_collapsed.png`、`m1_anim_record.mp4`、`m1_menu_anim_mid.png`、`m1_menu_anim_settled.png`、`m1_dark_settings_page.png`、`m1_menu_open_dark.png/xml`、`m1_theme_restored.png`；结论明细 `m1_draft.md`

### 三、异常与陷阱（均非 M1 菜单缺陷，如实记录）

1. **章节标题数据污染（数据/源解析层，非 UI 缺陷）**：标题胶囊 a11y desc 混入 15 个耽美书名×2 组列表。根因：阅文漫画《全职高手》章节的 chapter.title 被污染源数据污染（「书名\n[书名列表×2]\n实际章名」，真实章名在末尾，跳章后尾部随之变化）；菜单 UI 正确渲染 bookName+chapterName、视觉单行省略号只显示首行。建议后续在源解析/入库层清洗 chapter.title。
2. **QA 侧误操作致章节回退（自查，非应用缺陷）**：暗色测试阶段一条本意为「设置页下滑」的指令实际在阅读器内执行（tap 324,1800+swipe），快速上滑在 T2B 纵向分页=回退，读者 ch26(p1/50,24.8%)→ch25 预告(p1/24,23.8%)；pid 未变、无 FATAL/E/flutter，应用处理正确。
3. **MangaConfigSheet 关闭路径**：scrim 仅顶部 86px 且被状态栏拦截（tap 540,43 无效），唯一下滑手势可关（isScrollControlled 近全屏 sheet 共性特征，非缺陷）。
4. **环境陷阱**：uiautomator dump 偶发 SIGSEGV（Shutdown thread，exit 139，无害）→ 循环重试规避；Git Bash MSYS 路径转换 → 全程 `export MSYS_NO_PATHCONV=1`；刷新缓存命中即时恢复，loading 中间帧未捕获、不硬造证据。

*本段纪律自检：未改任何生产代码；设备操作只读/可恢复（主题切换已还原、目录跳章为阅读器自身功能）；不硬造——动画中间帧取自录屏抽帧（MuMu ROM screenrecord 实际 13fps 低帧率，如实注明）、刷新 loading 未捕获如实注明、胶囊污染定性为数据层问题并给出根因。*

## M1b 修正后重截（2026-09-30）

- 装机：`scripts/emulator_smoke_test.ps1 -Device 192.168.100.62:5555`（HEAD 6bc359fb74 / 2.0.328+329）→ 7 PASS / 0 FAIL，退出码 0，版本 2.0.328 与 pubspec 一致，无 FATAL/E/flutter，FFI content hash 1549248103 通过（`m1b_smoke_raw.log`）。
- 路径：书架 →《全职高手》→ ch25 预告 p1/24（总进度 23.8%）→ 轻点中央 (540,960) 呼出浅色菜单。
- 证据（`docs/materials_1301/evidence/`）：`m1b_menu_open_light.png`（展开态，md5 fc859070…）、`m1b_menu_collapsed.png`（收起态，916e29f0…）、`m1b_menu_open_light.xml`（新 dump，md5 6dfd21c5…，root desc=「预告 页数1/24 章节25/101 总进度23.8%」，含 返回/标题View/刷新 + 上一章/SeekBar「页数 1/24」/下一章 + 目录/自动/翻页设置）。
- 修正验证（dpr 3.0，像素实测）：
  - **标题胶囊左对齐 生效**：双行文字 L1 x254-416（y105-123）/ L2 x256-418（y124-144），左缘差 2px；内容块位于顶栏 (x216-864) 左侧（若居中应起于 ~x458）→ `Align(centerLeft)+Column(start)` 生效 ✓
  - **底栏滑条细轨+小thumb 生效**：轨道 y1602-1607 ≈ 6px = 2sp ✓（M1 为 12px）；thumb 深色 (83,67,62) 实心圆中心 (287,1605) 半径 ≈17-18px = 6sp ✓；**无页码气泡**（M1 的 58px 深色气泡消失，仅 thumb 上方 overlay 弧 40px）✓
  - **点串 未视觉成立（如实记录）**：divisions=23、tickMarkRadius=2 在代码中，但屏幕轨道为均匀 6px 带 (216,196,190)，24 个刻度位（25.2px 间隔，实测 4/24 命中）均无 12px 圆点凸出或暗色对比 → 点串与轨道同色重叠/未渲染，建议下轮以 debug 断点或 widget test 复核 tick 颜色。
- 陷阱（同 M1）：设备零无障碍服务 → uiautomator dump 间歇返回陈旧树（本次首取误得小说菜单树），需重试循环 + grep 当前屏 content-desc 甄别；M1b 旧证据文件（错误中间态）已整体替换。

## 2.0.329 冒烟（2026-09-30）

- 装机：`scripts/emulator_smoke_test.ps1 -Device 192.168.100.62:5555`（HEAD e2a6b930be / 2.0.329+330）→ 7 PASS / 0 FAIL，退出码 0，已装版本 2.0.329 与 pubspec 一致，无 FATAL/E/flutter；FFI content hash 1549248103 通过（与 2.0.328 轮一致，佐证"代码未变、仅版本号 2.0.328→2.0.329"）；构建形态 `flutter build apk --debug`（282.3 MB，Gradle assembleDebug 9.7s 增量）；原始日志 `m329_smoke_raw.log`（md5 874cf22e…）。
- 菜单点验：书架 →《全职高手》→ ch25 预告 p1/24（总进度 23.8%，与 M1b 同状态）→ 轻点中央 (540,960) 呼出浅色菜单：顶栏（返回/标题胶囊左对齐双行/刷新）+ 底栏（上一章/滑条「页数 1/24」/下一章 + 目录/自动/翻页设置）全部在树（dump content-desc 实测）；像素抽检底栏 y1600-1870：轨道 (217,215,216)、面板 (240,240,240)、图标 (174,174,174)、thumb 深色 (83,67,62)，与 M1b 修正态一致；截图 `m2_menu_check.png`（1080×1920，md5 fc859070…，前缀与 M1b 展开态截图相同 → 与 2.0.328 已验状态像素级一致）。
- 结论：2.0.329 装机冒烟通过，M1 菜单批状态无回归；设备已复原（菜单收起、/sdcard 临时文件已清）。

## M2 装机采证（2026-09-30）

> STAGE-QA-P43M2（QA 子代理）：2.0.329+330 漫画菜单 M2 重构（对齐用户截图：顶栏实心 AppBar 式 + 进度行独立白圆钮/白胶囊竖条 thumb + 贴底白条三键）装机采证——构建装机 + 浅色/暗色菜单截图 + 自动键状态着色，供主代理视觉终审。HEAD 基线 0556a29752（其后 9f2d41f5f7/9b1dbd1566 仅改图片加载/失败占位视觉，不动菜单结构）；M2 菜单提交 994b1649f5 已含于装机 APK。设备 MuMu 192.168.100.62:5555（1080×1920，dpr 3.0）。被测书：阅文漫画《全职高手》（101 章，续读位 ch26 第01话 p1/50，24.8%）。全程未改任何生产代码。

### 一、冒烟（emulator_smoke_test.ps1 -Device 192.168.100.62:5555）

- **结果：7 PASS / 0 FAIL，退出码 0**：flutter build apk --debug（322.1 MB，Gradle assembleDebug 13.6s）；FFI content hash 1549248103 通过（aarch64/x86_64 复用 .so）；已装版本 2.0.329 与 pubspec 一致；进程存活（pid 9976）；无 FATAL/E/flutter。
- 其他会话遗留的 4 个未跟踪 test 文件不影响构建（test 文件不进 APK），构建正常通过。
- 证据：`m2_smoke_raw.log`（md5 5c8841b6…）

### 二、逐项结构断言（浅色菜单 `m2_menu_light.xml` 新鲜 dump；像素 dpr 3.0）

| 断言项 | 期望（spec 截图） | 实测（bounds / 像素） | 判定 |
| --- | --- | --- | --- |
| 顶栏实心底 | surfaceContainer 实心 | 顶栏底 (238,238,238) 实心非透明 | 通过 |
| 顶栏·返回 | 左键 | Button [0,72][120,192] desc=返回 | 通过 |
| 顶栏·刷新 | 右上点 | Button [816,72][936,192] desc=刷新 | 通过 |
| 顶栏·更多 | 右上点 | Button [960,72][1080,192] desc=更多（打开页操作底栏） | 通过 |
| 顶栏·书名大字 | 书名+章节名/源名行 | 标题区 desc=书名+章名（⚠ 混入污染书名列表，见陷阱 2）；单行省略号渲染 | 通过（UI 侧正确） |
| 进度行·上一章圆钮 | 独立白圆钮 | Button [48,1560][216,1728]（168px 圆=56dp）底 (245,245,245) 浮起阴影 | 通过 |
| 进度行·胶囊滑条 | 白胶囊内竖条 thumb+点串 | SeekBar desc=「页数 1/50」；胶囊底 (245,245,245) stadium 全圆角；竖条 thumb=primary | 通过 |
| 进度行·下一章圆钮 | 独立白圆钮 | Button [864,1560][1032,1728] | 通过 |
| 三键行·目录 | 贴底白条左 | Button [180,1776][300,1896] desc=目录 | 通过 |
| 三键行·自动 | 贴底白条中 | Button [480,1776][600,1896] desc=自动（开=停止） | 通过 |
| 三键行·设置⚙ | 贴底白条右 | Button [780,1776][900,1896] desc=翻页设置（gear 图标） | 通过 |
| 白条底 | 贴底白条 | 条底 (245,245,245)=scheme.surface 暖白（非纯白 255，spec「白条」=surface 实现成立）；三键图标中心 x=240/539/839 与 dump 一致 | 通过 |
| 自动键开启 | 图标变 primary（spec 蓝） | desc 自动→停止；图标 OFF (29,29,29)→ON (121,85,72)，与同屏滑条 thumb（primary）同色交叉验证；**本机暖色种子 primary=暖棕非蓝**（见陷阱 1，非缺陷）；菜单展开态自动翻页暂停（L423/446 守卫），ON 态截图无翻页漂移 | 通过 |
| 暗色主题菜单 | 顶栏/白条暗色系 | 切深色（我的→主题模式→sheet）：我的页背景 (29,32,36)；菜单顶栏底 (78,78,78)、贴底条底 (16,20,24)、图标 (237,230,228) 亮 onSurface——暗色系非恒黑非纯白；**`m2_menu_dark.xml` 与 `m2_menu_light.xml` 字节级相同（md5 69bf8f76…）→ 暗/浅色结构完全一致** | 通过 |
| 主题还原 | 切回跟随系统 | 我的页背景 (240,240,240)/顶 (244,244,244) 浅色 + 行值=跟随系统（`m2_theme_restored.png`/`m2_chk_restored.xml`） | 通过 |

- 视觉终审素材（`docs/materials_1301/evidence/`）：`m2_menu_light.png`（浅色展开态，md5 32bb4b8a…）、`m2_auto_on.png`（自动开启态，md5 21e61a23…）、`m2_menu_dark.png`（暗色展开态，md5 1731f701…）；配套 `m2_menu_light.xml`/`m2_menu_dark.xml`（md5 69bf8f76… 同树）、裁剪 `m2_menu_light_top_crop.png`/`m2_menu_light_bottom_crop.png`/`m2_menu_dark_top_crop.png`/`m2_menu_dark_bottom_crop.png`/`m2_auto_on_key_crop.png`；过程证据 `m2_chk_auto_state.xml`/`m2_auto_off.png`/`m2_chk_auto_off.xml`/`m2_dark_mine.png`/`m2_theme_restored.png`；结论明细 `m2_draft.md`
- 收尾：菜单收起、自动翻页 OFF、/sdcard m2_* 临时文件已清（`adb shell ls /sdcard/m2_*` 空）

### 三、异常与陷阱（均非 M2 菜单缺陷，如实记录）

1. **自动键 ON 色为暖棕 (121,85,72) 而非 spec「蓝」**：本机应用主题种子=暖色系，scheme.primary 随之为棕；状态着色逻辑正确（开=primary、desc 停止），颜色随种子。视觉终审如按「蓝」比对，需先切蓝色种子/默认主题（建议主代理终审时知悉）。
2. **章节标题数据污染（M1 异常 1 延续，数据/源解析层）**：标题/页脚 a11y desc 仍混入耽美书名列表（真实章名在末尾）；菜单 UI 正确渲染 bookName+chapterName+单行省略号，非缺陷；建议后续在源解析/入库层清洗 chapter.title。
3. **书架卡片 tap 直达阅读器**（不经详情页）：本次导航实测行为（续读位语义），非缺陷。
4. **环境陷阱（同 M1/M1b）**：Git Bash 全程 `export MSYS_NO_PATHCONV=1` + Windows 风格路径；本会话 uiautomator dump 基本返回新鲜树（M1b 的持续陈旧树未复现，上一会话的陈旧 `m2_menu_light.xml` 已被本会话新 dump 覆盖）；上一会话 m2_auto_on.png 曾三次覆盖（双击往返+自动翻页漂移），本会话以「单点+1.2s+desc 即时验证」定稿。

*本段纪律自检：未改任何生产代码；设备操作只读/可恢复（主题切换已还原跟随系统、自动翻页开过即关、/sdcard 临时文件已清）；不硬造——自动键 ON 色与 spec「蓝」的偏差如实定性为主题种子色而非缺陷并给出交叉验证（与滑条 thumb primary 同色）、暗/浅色结构一致性以双 xml 字节级相同为证。*

## 2.0.330 冒烟（2026-09-30）

- **冒烟**：`scripts/emulator_smoke_test.ps1 -Device 192.168.100.62:5555`（HEAD c2eb332d2f / 2.0.330+331）→ **7 PASS / 0 FAIL，退出码 0**：debug APK 282.4 MB（Gradle assembleDebug 12.9s）；FFI content hash 1549248103 通过（aarch64/x86_64 复用 .so，与 2.0.328/329 轮一致）；已装版本 2.0.330 与 pubspec 一致；进程存活（pid 13073，全程未变）；无 FATAL/E/flutter。原始日志 `m330_smoke_raw.log`。
- **漫画链路·正常出图**：书架 →《全职高手》→ 阅读器 ch26 第01话 p1/50（desc 实测「页数1/50 章节26/101 总进度24.8%」，`m330_chk2.xml`）：页面为深底漫画内容页（页区均值 15.4/σ44.9，有内容方差，非占位态），菜单三件套正常渲染（`m330_reader_p1.png`）。素材批改动集中在失败/加载占位路径，正常加载路径无变化 ✓。
- **漫画链路·失败占位（断网点验，程序化证据）**：断网（`svc wifi disable`）+ 未缓存页 ch26 p7 → 页面呈深底 + 中央 64px 占位（`m330_fail2.png` 51.7KB，对比**同页在线 2.8MB** `m330_p7online.png` 亮色内容，量级差 54×）；占位像素特征：中央 64px 盒中亮度带(30-200)占 10.9%（素材 image_loading_error.png 灰度 33-67、不透明率 36.8% → 64px 渲染理论值 ≈11.4%，吻合）、>200 亮像素 0%（**排除旧白色 broken_image 图标**）、周边 94% ≤30（55% 黑底语义）。结论：**新素材占位（Image.asset）成立**；视觉终审素材 `m330_fail2_crop.png` / `m330_p7online_crop.png`（本会话模型无视觉，像素统计为判定依据，主代理复核图像）。
- **行为注记（非缺陷）**：① 阅读器错误态在页内不自动重试（离线→恢复在线后 p7 页字节级不变 51690B，p8→p7 往返仍占位；重开阅读器后同页显示真实内容——B1 单测已断言占位含重试按钮，重试为显式交互）；② 相邻页预缓存生效（断网时 p8 仍显 2.1MB 缓存内容 `m330_p8offline.png`）。
- **单元测试（代码层接线佐证）**：`flutter test test/unit/loading_error_asset_test.dart test/widget/reader_comic_error_placeholder_test.dart` → 5/5 通过（素材 6933B 与原版字节级一致 md5 1238cf6b…、pubspec assets/images/ 目录声明、解码失败/无书源/直连骨架三形态占位断言）。
- **环境陷阱（如实记录）**：① 首次 `svc wifi disable` 使 adb-over-LAN 通道失联（设备 offline，TCP 10060，127.0.0.1:5555-5558 均拒绝）；经 **mumu-cli**（`D:\Program Files\MuMuPlayer\nx_main\mumu-cli.exe`）本地通道恢复：`sh --vmindex 1 --cmd "svc wifi enable"`（目标=实例 1「Test测试」/192.168.100.62；实例 0「Test2」=192.168.100.63 未受影响）；其后所有断网/恢复均走 mumu-cli 通道执行、LAN 通道仅用于取件，避免再次失联。② Git Bash `adb pull /tmp/x`（MSYS_NO_PATHCONV=1）落盘 Windows 盘根相对路径 `D:\tmp\x`，取件路径注意。
- **结论**：2.0.330 装机冒烟通过，版本/进程/崩溃门禁全绿；漫画正常出图无回归，失败占位已切换为新素材图（程序化证据充分，图像留待视觉终审）。收尾：Wi-Fi 已恢复开启、阅读器停留 ch26 p8（在线亮色内容）、/sdcard m330_* 已清（`ls` 计数 0）。

*本段纪律自检：未改任何生产代码；设备操作可恢复（Wi-Fi 复原、临时文件已清、实例 0 未触碰）；不硬造——失败占位「图像内容」以像素统计+同页在线/离线量级差+单测三证交叉支撑，视觉不可见项如实标注为主代理终审项，不冒充已视觉确认。*

## M2b 点串修复重截（2026-09-30）

- **冒烟**：`scripts/emulator_smoke_test.ps1 -Device 192.168.100.62:5555`（HEAD 8579bfee / pubspec 2.0.330+331，工作树含修复提交 27b4b4cb38 本次构建装机）→ **7 PASS / 0 FAIL，退出码 0**：FFI hash 1549248103 通过（.so 复用）；APK 282.4MB（Gradle 14.2s）；已装 2.0.330 与 pubspec 一致；进程存活；无 FATAL/E/flutter。注：版本号在修复提交前已升 2.0.330+331，修复未再 bump——「已装版本一致」仅证明版本线正确，本次以「当前工作树重新构建」保证含修复代码。
- **浅色菜单展开态**（书架→《全职高手》→阅读器 ch26 p9/50→点屏呼出菜单）：`m2b_menu_light.png`+`m2b_menu_light.xml`；顶栏底 (238,238,238)、贴底白条 (245,245,245)、三键行/进度行渲染正常；裁剪 `m2b_capsule_crop.png`（2x，进度行整带）。
- **点串可见性判定：不通过——点串仍未见，且定位到新根因（非对比度）**：
  - 像素佐证：thumb 竖条中心 RGB (121,85,72)（实色 primary 暖棕，与 M2 轮一致，证明 primary 深色、胶囊白底 (245,245,245) 正常渲染）；**thumb 左侧 x224..398 / 右侧 x418..860 × y1630..1650 中轴带非白像素 n=0**（2px 步长采样）；胶囊区 2D 密度图（4px 网格）除 thumb 块（x400..415、y1607..1679）外全白——**点串未绘制，非「浅得看不见」而是根本没画**。
  - 根因（SDK 层，Flutter 3.44.8 `slider.dart` 点串密度门禁）：`if (adjustedTrackWidth / divisions >= 3.0 * tickMarkWidth)` 才绘制整串。本机 480dpi：胶囊 216dp − 2×20dp padding ≈ 171.5dp 轨宽，divisions=49（50 页）→ 3.5dp < 3×6dp=18dp → **整串跳过**；修复前 2dp 半径（阈 12dp）同样不满足（M2「对比不足」诊断偏差）；27b4b4cb38 把点加大到 3dp 反而使门禁更难满足。**49 分段下满足门禁需轨宽 ≥882dp，超屏幕 360dp，此架构（标准 Slider tickMark）下点串永不出现。**
  - 修复方向（开发侧，QA 不改代码）：点串改自绘（CustomPaint/胶囊内自绘点列 + `SliderTickMarkShape.noTickMark`），或改 divisions 取法牺牲语义；对照参考版应为自绘点串。
- **对照**：旧 `m2_menu_light.png` 2D 密度图同样 thumb（x360..373）两侧纯白无点串——修复前后点串区域渲染一致（门禁下均不画），与本轮结论互证。
- **收尾**：菜单已收起、自动翻页 OFF（未动，desc=自动）、/sdcard m2b_* 临时文件已清（ls 空）；阅读器停留 ch26 p9/50。
- **结论**：M2b 重截验收**失败**——装机冒烟全绿、菜单渲染无回归，但点串修复未达预期（可见性=否），需开发改自绘方案后重新提测。

## M2c 点串自绘重截（2026-09-30）

> STAGE-QA-P43M2C2（QA 子代理）：2.0.330+331 点串自绘修复（HEAD caa2465f09「进度胶囊点串改自绘 CustomPaint」，`_MangaTickDotsPainter` 均布 divisions+1 个 3dp 实色 primary 点含端点、位于 Slider 下层、标准 tickMark 置 noTickMark）快速重截验证——装机冒烟 + 菜单展开态截图 + 点串像素判定。设备 MuMu 192.168.100.62:5555（1080×1920，dpr 3.0）；被测书：阅文漫画《全职高手》，续读位 ch26 第01话 p9/50（总进度 24.9%，与 M2b 同屏态——天然配对对照）。全程未改任何生产代码。

### 一、冒烟（emulator_smoke_test.ps1 -Device 192.168.100.62:5555）

- **结果：7 PASS / 0 FAIL，退出码 0**：FFI content hash 1549248103 通过（aarch64/x86_64 复用 .so，与 2.0.328-330 各轮一致）；flutter build apk --debug 全量（Gradle assembleDebug 12.8s，APK 322.1 MB）；已装版本 2.0.330 与 pubspec 一致（版本号在修复提交前已升 2.0.330+331，修复未再 bump——同 M2b 注记，以「当前工作树重新构建」保证含修复代码 caa2465f09）；进程存活（pid 14962）；无 FATAL/E/flutter。
- 证据：`m2c_smoke_raw.log`（md5 9aaac538…）

### 二、点串可见性判定：**通过（点串已绘制，均匀点串成立）**

- 路径：书架 →《全职高手》→ 阅读器 ch26 第01话 p9/50（desc 实测「页数9/50 章节26/101 总进度24.9%」）→ 点屏中央 (540,960) 呼出**浅色**菜单展开态；dump 新鲜树（含 返回/刷新/更多 + 上一章/「页数 9/50」SeekBar/下一章 + 目录/自动/翻页设置，与 M2 结构一致，md5 c9039752…）。
- **像素判定（`m2c_menu_light.png`，1080×1920，dpr 3.0，胶囊带 y1560..1728）**：
  - thumb 竖条定位：primary 暖棕 (121,85,72) 列 x400..412（13px 宽，与 M2b 实测 x400..415 一致——thumb 自绘竖条未动 ✓）。
  - **thumb 右侧中轴带（y1630..1658 × thumb 右 10px 起）非白像素 = 2900（M2b 同屏态 = 0）**；左侧 = 782（≈12 个点的像素量，与 8/49 位置吻合）。
  - 均匀性：右侧 8 分段非白像素 [476, 476, 476, 474, 464, 462, 72, 0]——6 个满段每段 ≈470 近乎恒定（尾段 72=末端点余量、0=胶囊外面板白底），**整串均匀、非随机噪点**。
  - 点特征：中轴带列密度 50% 阈值检出 **49 个峰**（spec=divisions+1=50，1 对相邻点在阈值下并峰，间距证据吻合），间距 min/avg/max = 9/10.0/17px（理论 528/49≈10.8px，吻合）；点串 x 范围 298..781（含首尾端点、覆盖胶囊内容区全宽）。
  - 点色验证：点串区非白像素 3962 个中 **73.5% 落在 primary (121,85,72) L1 邻域（<90）**（其余为白底 AA 过渡），即点色=scheme.primary 暖棕（本机暖色种子，与 M2 陷阱 1 同因），白底参照 (249,249,249) 正常。
- **配对对照（同屏态 ch26 p9/50、同脚本）**：M2b 修复前 `m2b_menu_light.png` 同区域非白像素 = 0（8 分段全 0，VERDICT NOT VISIBLE）→ 本批 2900（VERDICT VISIBLE）。**差异 100% 由 caa2465f09 自绘点串层引入，非环境/渲染差异。**
- **结论：M2c 自绘点串修复真机验收通过**——白胶囊内除竖条 thumb 外出现均匀 primary 点串（含端点、50 点均布、~10px 间距、3dp 点径），M2b 判定「点串未绘制（密度门禁）」的缺陷已消除。

### 三、证据索引（`docs/materials_1301/evidence/`）

- `m2c_smoke_raw.log`（冒烟原始日志，md5 9aaac538…）
- `m2c_home.png`（书架，md5 07318df4…）｜`m2c_reader_p9.png`（展开菜单前阅读器 p9/50，0115aa28…）
- `m2c_menu_light.png`（**浅色菜单展开态**，a530076a…）+ `m2c_menu_light.xml`（新鲜 dump，c9039752…）
- `m2c_capsule_crop.png`（进度行 2x 裁剪，1e6720ed…，供主代理视觉终审）
- 配对对照件：`m2b_menu_light.png`（5c9c47c0…，修复前同屏态，非白像素=0）

*本段纪律自检：未改任何生产代码；设备操作只读/可恢复（菜单已收起、/sdcard m2c_* 临时文件已清、阅读器停留 ch26 p9/50）；判定以像素采样+M2b 配对对照为准，图像视觉终审素材（m2c_capsule_crop.png / m2c_menu_light.png）留主代理复核。*

## SVG 移出后构建冒烟（2026-09-30）

> QA 子代理：SVG 移出（99efc7c90f：8 个零引用 `assets/icons/ic_bottom_*.svg` git-mv 至 `docs/pending_deletion/assets_icons_unused/`，pubspec 移除 `- assets/icons/` 声明）后快速构建验证。HEAD f04199881a，全程未改任何生产代码。

- **构建门禁：通过。** FFI verify（release，aarch64/x86_64）PASSED（content hash 1549248103，复用现有 .so，与 2.0.330/331 各轮一致）；`flutter build apk --debug` exit 0（Gradle assembleDebug 22.3s，APK 282.4 MB），**全量构建日志 118 行无任何 asset/资源解析告警或报错**；APK 内容核验：`assets/flutter_assets/assets/` 仅含 default_data/images/mock_data/web 及 md 文件，**无 `assets/icons/`、无 `ic_bottom*` 残留**（命中 "icons" 的仅 MaterialIcons 等字体包名，与本次移除无关）。
- **装机冒烟（安装/启动/崩溃检查）：阻塞（环境问题，非代码问题）。** 验收机 MuMu 192.168.100.62:5555 全程离线：adb 初显 offline → disconnect+reconnect 超时（WSAE 10060），`ping 192.168.100.62` 由网关 192.168.100.52 回「无法访问目标主机」（host 级不可达），期间重试 5 次（约 12 分钟）均不可达；`emulator_smoke_test.ps1 -Device 192.168.100.62:5555` 退出码 1（`[FAIL] 设备不在线`，脚本首步即止，未触达构建/装机段）。设备恢复后需补跑：装机 + 版本复核 + 启动 + FATAL 检查。
- **版本注记：** pubspec 现为 **2.0.331+332**——由 22ff2c51c4（`chore(release): 版本 2.0.331+332`，早于 SVG 提交 99efc7c90f）提升，任务书中「应仍 2.0.330」表述已过期；已装==pubspec 一致性核对因设备离线未执行（构建侧 APK 构建自当前工作树，含 pubspec 2.0.331+332）。
- 证据：`docs/materials_1301/evidence/svgmove_ffi_verify.log`（FFI 校验输出）｜`svgmove_build_full.log`（全量构建日志，md5 7ba449bf…，grep asset/warn/error 零命中）｜`.qa_scratch/svg_move_build.log`（临时件）。
- **装机补跑结果：通过（2026-09-30 18:45，设备恢复后补跑，QA 子代理，未改任何生产代码）。** 补跑时验收机仍离线（两个 MuMu 实例均 `is_android_started=false`，`ping 192.168.100.62` 回「无法访问目标主机」），经 `mumu-cli control --vmindex 1 launch` 启动实例 1「Test测试」(=192.168.100.62，`player_state=start_finished`，本地 ADB 端口 16416)，`adb connect 192.168.100.62:5555` 重连成功（`device` 在线）；重跑 `emulator_smoke_test.ps1 -Device 192.168.100.62:5555` → **7 PASS / 0 FAIL，退出码 0**：构建形态=**FFI REUSE**（content hash 1549248103，aarch64/x86_64 复用现有 .so，与本批零 Rust 改动一致）+ 轻构建（`flutter build apk --debug`，Gradle assembleDebug 8.6s，APK 282.4 MB）；**版本复核：已装 2.0.331 == pubspec 2.0.331+332**（versionName=2.0.331/buildNumber=332，闭合上文版本注记）；进程存活（pid 2992）；无 FATAL/E/flutter 崩溃日志。漫画菜单点验（M2 形态）：书架→《全职高手》→阅读器 ch26 第01话 p9/50（总进度 24.9%，与 M2c 同屏态）→点屏呼出菜单，结构 dump + 像素采样双重佐证——实心顶栏（返回/刷新/更多，y72-192，底 (238,238,238) 实心非透明）+ 进度行（上一章圆钮/胶囊滑条「页数 9/50」/下一章圆钮，y1560-1728，primary 暖棕 (121,85,72)）+ **贴底三键白条**（目录/自动/翻页设置，y1776-1896，底 (245,245,245) 暖白），bounds 与 M2 记录逐项一致，**菜单无回归**。截图 `m331_menu_check.png`（1080×1920 RGBA，md5 ff468516…）。证据：`m331_smoke_rerun.log`（md5 83c5a84e…）｜`m331_menu.xml`｜`m331_home.xml`｜`m331_chk0_home.png`（均位于 `docs/materials_1301/evidence/`）。收尾：设备 /sdcard m331_* 临时文件已清；**结论：SVG 移出批装机冒烟补跑通过，版本/进程/崩溃门禁全绿，M2 漫画菜单形态无回归，阻塞项闭合。**
## M3 装机采证（2026-09-30）

> QA 子代理（STAGE-QA-P43M3）：M3 四项修复装机截图终审采证。HEAD=11683d443b，pubspec 2.0.331+332（未升版属预期），验收机 MuMu 192.168.100.62:5555（1080×1920 dpr3，Android 15）。全程未改任何生产代码；判定以「新鲜 uiautomator dump + PIL 像素断言 + 代码定位」三重证据为准，视觉终审素材（crop 图）留主代理复核。

### 一、冒烟构建+装机：通过
- `emulator_smoke_test.ps1 -Device 192.168.100.62:5555` → **7 PASS / 0 FAIL，退出码 0**：FFI 复用（零 Rust 改动）+ 轻构建；**已装 2.0.331 == pubspec 2.0.331+332**；进程存活；无 FATAL/E/flutter 崩溃。证据 `m3_smoke.log`｜`m3_01_home.png`｜`m3_02_book.png`｜`m3_03_reader.png`。

### 二、逐项断言表（M3 四项修复）

| # | 修复项 | 断言 | 证据（`docs/materials_1301/evidence/`） | 判定 |
|---|--------|------|------|------|
| 1a | 状态栏覆盖（浅色） | 状态栏区 y10-70×x120-1050 主色 (238,238,238) 53270px（顶栏 surfaceContainer 背景延伸至状态栏），y60 四角全 (238,238,238) 非黑；底缘 y1900-1919 全 (245,245,245) 白条至屏幕底缘 | `m3_menu_light.png` + `m3_menu_light.xml`（9263B 新鲜 dump，24 节点）｜`m3_crop_statusbar.png`｜`m3_crop_bottombar.png` | **通过** |
| 1b | 状态栏覆盖（暗色） | 切「深色」后同一菜单展开态：状态栏区 y8-64 主色 (78,78,78) 95%、纯黑像素 0%（暗色 surfaceContainer 灰、非纯黑——「纯黑深色模式」开关为关）；底缘 y1900-1919 全 (16,20,24) 暗色 surface 贴底无黑缝；测后主题还原「跟随系统」 | `m3_menu_dark.png` + `m3_menu_dark.xml`（9261B）｜`m3_crop_dark_statusbar.png`｜`m3_crop_dark_bottombar.png` | **通过** |
| 2 | 顶栏换源键 | 浅色/暗色 dump 均含「换源」desc [672,72][792,192]（y132 浅色深色簇 667px / 暗色亮簇 808px）；点击打开**既有**换源弹层（ChangeSourceScreen 新鲜 dump：Back/搜索筛选/重新搜索/高级选项/搜索/滚到顶部/滚到底部），关闭后源仍「七七漫画」，未真换源 | `m3_source_sheet.png` + `m3_source_sheet.xml`（7183B）｜`m3_crop_topright_icons.png`｜`m3_crop_dark_topright.png` | **通过** |
| 3 | 自动键书本图标 | 底栏「自动」键 [480,1776][600,1896] 图标为书本造型（auto_stories），浅色 crop 视觉确认 + 代码 `manga_menu.dart` `Symbols.auto_stories_rounded`（开启 primary / 关闭 onSurface，无主题分支，暗色同构）；暗色键区亮像素 1984/14400（13.8%） | `m3_crop_autokey.png`｜`m3_crop_dark_autokey.png` | **通过** |
| 4 | 设置面板重组 | 「漫画阅读设置」标题 [60,311][423,392]；5 模式按钮组（当前 T2B 高亮 primaryContainer (250,218,211) 2572px，其余 0）；条漫模式专属「侧边留白」滑杆（仅 isWebtoon，初值 0%）；页脚快捷行 左对齐/居中/隐藏页脚 三按钮 + 预览条 | `m3_config_panel.png+xml`（10427B）｜`m3_config_panel_footer.png+xml`｜`m3_config_webtoon.png+xml`（9753B） | **通过** |
| 4a | 侧边留白生效 | 条漫模式滑杆 20% → 内容落入 x216-864 槽位（1080×20% 每侧 216px，内容行 y1100/y1300 非背景像素在槽内）；45% 决定性实验内容 x486-593 与代码公式 `h = width × p/100`（`reader_comic_screen.dart` L1737-1744）精确吻合；测后滑杆还原 0%（dump SeekBar desc 0%） | `m3_webtoon_pad20.png` | **通过** |
| 4b | 页脚预览交互 | 点「左对齐」→ 预览条高亮 x228→x133 互换；点「居中」→ 还原 x228 | `m3_config_preview_left.png`｜`m3_config_preview_center.png` | **通过** |

### 三、检查可用性声明
- 全部 7 项断言均有「dump 节点 bounds + 像素采样」双重可复现证据（命令与采样窗口见 `.qa_scratch/m3_draft.md`），**无「检查不可用/未证明」项**。
- 局限：图标「书本造型」的视觉判定基于 3x 放大 crop（`m3_crop_autokey.png`）+ 代码符号名（`auto_stories_rounded`）双证，非人工像素级描边比对；crop 图已留档供主代理视觉复核。

### 四、设备收尾还原（全部完成）
- 侧边留白滑杆回 0%（dump 确认）；模式还原 T2B 单页式；色彩滑杆全 0%；页脚还原居中；主题还原「跟随系统」（页面底色回 (245,245,245)，跟随系统选中棕色 7224px）；阅读器经「返回」退出至书架（菜单收起）；/sdcard 本次会话临时文件（m3_dump7/8.xml、qa_*.png、m3_menu_dump*.xml）已清（历史 QA 遗留文件非本任务产物，未动）。残留书态：《全职高手》T2B，p2/50（总进度 24.8%）。

*本段纪律自检：未改任何生产代码；判定以像素采样+新鲜 dump+代码定位为准；图像视觉终审素材（`m3_menu_light.png` / `m3_menu_dark.png` / 各 crop）留主代理复核。*

## M4 装机采证（2026-09-30）

> QA 子代理（STAGE-QA-P43M4）：M4 设置面板扩充（批1 页脚内容胶囊组 / 批2 行为开关组+背景色板 / 批3「滤镜」入口按钮）装机截图终审采证。HEAD=0644f43e2a，pubspec 2.0.332+333（未升版属预期），验收机 MuMu 192.168.100.62:5555（1080×1920 dpr3，Android 15 已 root）。全程未改任何生产代码；判定以「新鲜 uiautomator dump + PIL 像素断言 + 代码定位」三重证据为准，crop 图留主代理复核。

### 一、冒烟构建+装机：通过
- `emulator_smoke_test.ps1 -Device 192.168.100.62:5555` → **7 PASS / 0 FAIL，退出码 0**：FFI 复用（content hash 1549248103 一致，零 Rust 改动）+ `flutter build apk --debug` 282.4 MB；**已装 2.0.332 == pubspec 2.0.332+333**（装前 2.0.331）；进程存活；无 FATAL/E/flutter 崩溃。证据 `m4_smoke.log`｜`m4_00_home.png`。

### 二、逐项断言表（M4 三批）

| # | 项目 | 断言 | 证据（`docs/materials_1301/evidence/`） | 判定 |
|---|------|------|------|------|
| 面板 | 全览（滚动到底） | 区块顺序 阅读模式→页面适配→自动翻页→显示效果→色彩滤镜(亮度/R/G/B/A 五滑杆 0%)→页脚设置(快捷行+预览条+7 胶囊)→其他(8 复选框)→背景颜色(5 色板)；8 开关默认态像素判定全对（禁用漫画缩放/音量键翻页/长按保存图片=勾选，余为未勾选） | `m4_46`｜`m4_49`｜`m4_60`（png+xml 成对） | **通过** |
| 批1 | 页脚胶囊交互 | 点「页数」胶囊→该段变暗（透明底+opacity0.4+浅灰字，区域主色 226 灰底→245 行背景）；预览条语义串「第三话 页数4/30…」→「第三话 4/30…」（页数段消失）；再点恢复完整串 | `m4_46`(前)｜`m4_47`(变暗+段消失)｜`m4_48`(恢复) | **通过** |
| 批2a | 禁用漫画缩放（默认 ON） | 取消勾选 ON→OFF（像素 121,85,72+白勾→暗环）；关面板重开仍 OFF（**持久化通过**）；复勾还原 ON。双指捏合手势 adb 单指针通道不可注入，「OFF 时缩放生效」未机械证明（代码门控 `_disableMangaScale→InteractiveViewer(min1/max3)` 已核，建议真机补测） | `m4_73`｜`m4_74`(OFF)｜`m4_75`(重开仍 OFF)｜`m4_76`(还原 ON) | **通过（含 1 项验证边界）** |
| 批2b | 长按保存图片（默认 ON，**重点项**） | 默认 ON 长按应直接保存。**实测 FAIL**：长按 (540,900) 800ms 无菜单（分支路由正确）但 toast「**保存图片失败: Invalid argument(s): Bytes are required on Android & iOS when saving a file.**」，全设备无文件产生（/sdcard 各目录+MediaStore+应用内 documents 均查，documents 目录不存在）。缺陷定位：`reader_comic_screen.dart` L1636 `_savePageImage` 调 `FilePicker.platform.saveFile(dialogTitle, fileName)` **缺 `bytes:` 参数**（file_picker ^8.0.0 Android/iOS 必需），异常先于「取消→兜底写文档目录」分支抛出，兜底不可达；菜单「保存图片」按钮（L1613）命中同一函数，实测同 toast（**两保存入口均不可用**）。取消勾选后长按→页操作菜单（保存图片/分享图片/复制链接）正常出现 ✓；勾回还原 ON ✓ | `m4_50`｜`m4_51_lp_t1`(toast a11y [0,1683][1032,1920])｜`m4_56`(三键菜单)｜`m4_59`(菜单保存同 toast)｜`m4_54`/`m4_55`/`m4_62`(开关像素前后) | **FAIL（缺陷 D1）** |
| 批2c | 背景色板 | 5 圆点（黑 x144/白 x276/灰 x408/绿 x540/蓝 x672，y≈1745）选中=primary(121,85,72)描边+勾；点「白」→选中态切换 ✓ + 条漫留白区 100% (255,255,255) 纯白渲染 ✓；点「黑」还原选中 ✓。早期「背景不渲染」误报撤销（T2B 全宽页+屏角采样落在菜单区，条漫留白区蓝底 100% (0,97,164) 证明 `Color(_mangaBgColor)` 生效） | `m4_62`(白选中)｜`m4_66`(白留白 100%)｜`m4_68`(黑还原)｜`m4_43`(蓝留白 100%) | **通过** |
| 批3 | 「滤镜」按钮 | 点击 (170,488) → 面板即时锚滚至「色彩滤镜」区顶（贴视口顶边 [48,572]），五滑杆全可见 | `m4_36`(前)｜`m4_37_filter`(后) | **通过** |
| 3f | 条漫模式侧边留白 | 原模式 T2B（m4_40 像素）；切「条漫」→「侧边留白」滑杆出现（0%，「全屏适配」行隐藏）；拖动 0%→29%（指示器 64%）；条漫留白 29% 关面板留白区出现（背景蓝 100% 纯蓝）；还原 0%+T2B（滑杆段消失） | `m4_41`｜`m4_42`｜`m4_43`｜`m4_45`｜`m4_70` | **通过** |

### 三、缺陷与验证边界
- **D1（M4 批2，严重）：图片保存功能不可用**——`_savePageImage` 缺 `bytes:` 参数致 file_picker 恒抛异常，长按直接保存与菜单「保存图片」均失败且无文件落盘（兜底分支不可达）。复现：任意漫画页长按（长按保存图片=默认 ON）或长按出菜单点「保存图片」。期望：系统保存对话框或兜底写文档目录 + toast「已保存: <path>」；实际：toast「保存图片失败: Invalid argument(s)…」。修复方向：`saveFile(dialogTitle:…, fileName:…, bytes: data.bytes)`（仅开发侧，本任务未改码）。
- 验证边界：① 双指捏合不可注入（adb 单指针），缩放行为未机械证明；② 分享图片/复制链接未抽验（非本批断言项）；③ 音量键翻页/反转音量键为仅存储开关，仅验默认态。

### 四、设备收尾还原（全部完成）
- 8 开关全回默认（禁用翻页动画 ON→OFF 还原；长按保存/禁用漫画缩放抽验后勾回 ON）；背景=黑；模式=T2B；侧边留白=0%；页脚胶囊全显示（页数段已恢复）；色彩滤镜五滑杆=0%；设置面板/页操作菜单全部收起，阅读器停留正常浏览态（`m4_77`）。

*本段纪律自检：未改任何生产代码；判定以像素采样+新鲜 dump+代码定位为准；D1 缺陷仅描述复现/期望/实际与修复方向，不代改；crop/全幅截图（m4_00…m4_77 共 58 png + 53 xml + 1 冒烟日志，112 件）已归档 `docs/materials_1301/evidence/`，留主代理视觉复核。*

## M4b D1 修复回归（2026-09-30）

> QA 子代理（STAGE-QA-P43M4B）：M4 缺陷 D1 修复（`_savePageImage` 补 `bytes:` 参数，87133fe04b）真机回归——快速：装机冒烟 + 两保存入口验证。HEAD=87133fe04b，pubspec 2.0.332+333，验收机 MuMu 192.168.100.62:5555（1080×1920 dpr3，Android 15 已 root）。被测书：阅文漫画《全职高手》（101 章，ch26 第01话）。全程未改任何生产代码；D1 修复在 Dart 层**确认生效**，但**新发现缺陷 D2（插件层 FATAL 崩溃）阻塞 Download 保存**，取消兜底路径 PASS。

### 一、冒烟构建+装机：通过
- `scripts/emulator_smoke_test.ps1 -Device 192.168.100.62:5555` → **7 PASS / 0 FAIL，退出码 0**：FFI 复用（content hash 1549248103 一致，零 Rust 改动）+ `flutter build apk --debug`（Gradle assembleDebug 11.4s，282.4 MB）；**已装 2.0.332 == pubspec 2.0.332+333**；进程存活；无 FATAL/E/flutter 崩溃。证据 `m4b_smoke.log`。

### 二、开关默认态：通过
- 设置面板「其他」区「长按保存图片」Switch **默认 ON**：像素判定 ON 签名（primary 暖棕 (121,85,72) + 白勾 145px，OFF 态为暗环 (83,67,62) 91px——与 M4 轮同签名体系），与代码 `reader_comic_screen.dart` L257 `_mangaLongClickSaveImage = true` 一致。证据 `m4b_07_switch_on.png`。

### 三、两入口保存验证：D1 修复生效，但触发新缺陷 D2（崩溃）

| 步骤 | 结果 | 证据（`docs/materials_1301/evidence/`） |
|---|---|---|
| 入口 a：长按直接保存（开关 ON） | **D1 修复生效**：M4 轮的即时 toast「保存图片失败: Invalid argument(s): Bytes are required…」不再出现，**系统保存对话框（SAF/ACTION_CREATE_DOCUMENT）正常弹出**（对话框 dump 含文件名输入框+保存按钮，`m4b_08_savedialog_a.png/xml`） | `m4b_08` |
| 入口 a：对话框点「保存」→ /sdcard/Download | **D2 崩溃**：进程 FATAL 强杀（前台掉到 kazusa），/sdcard/Download 遗留 **0 字节** `manga-1790780351361.jpg`（22:59）；本方 Dart 后段写盘与「已保存:」SnackBar 不可达 | `m4b_09_after_save_a.png`、`m4b_18` 见下、`m4b_fatal_stack_d2.txt`（崩溃 #1） |
| 入口 b：取消开关 → 长按 → 页菜单「保存图片」 | 菜单出现（保存图片/分享图片/复制链接，`m4b_14_menu_b.png/xml`）；点「保存图片」后 **SAF 对话框同样弹出（D1 修复对入口 b 亦生效）**；点保存 → **同 D2 崩溃**（23:03，/sdcard/Download 遗留 0 字节 `manga-1790780625652.jpg`） | `m4b_14`、`m4b_fatal_stack_d2.txt`（崩溃 #2） |
| 取消兜底（对话框双 BACK 取消） | **PASS**：SnackBar「**已保存到文档目录: /data/user/0/io.legado.flutter_legado/app_flutter/manga-1790780523632.jpg**」（a11y 节点实读，`m4b_17_fallback_snackbar.xml`）；adb 落盘核实：`manga-1790780469503.jpg` / `manga-1790780523632.jpg` 均 **194,481 字节，JFIF 魔数 `ffd8 ffe0` 头 / `ffd9` 尾**（`m4b_ls_app_flutter.txt`） | `m4b_10`/`m4b_11`/`m4b_12`、`m4b_17`、`m4b_ls_app_flutter.txt` |
| 开关还原 | 勾回 ON（ON 像素签名复核通过），设备还原 | `m4b_15_switch_restored.png` |

**Download 目录 ls 证据**（`m4b_ls_download.txt`）：两次「保存」各遗留 1 个 0 字节文件（`manga-1790780351361.jpg` 22:59 / `manga-1790780625652.jpg` 23:03，大小 0）——provider 在对话框确认时预创建空文档，插件崩溃导致字节未写入。

### 四、新缺陷 D2（插件层，阻塞 Download 保存，仅描述不改码）
- **现象**：SAF 对话框点「保存」后，`file_picker 8.3.7` 插件 `FilePickerDelegate.onActivityResult`（L83 附近）经 `ContentResolver.openOutputStream(uri)` 写 bytes 时抛未捕获 `SecurityException`（**本 ROM 的 DownloadStorageProvider 拒绝**：`Permission Denial: writing com.android.providers.downloads.DownloadStorageProvider uri content://com.android.providers.downloads.documents/document/N ... requires android.permission.MANAGE_DOCUMENTS, or grantUriPermission()`）→ 经 `FlutterActivity.onActivityResult`（`MainActivity.kt:293`）抛至主线程 → `FATAL EXCEPTION: main` → 进程被系统强杀。
- **复现**：任意漫画页长按（开关 ON）或页菜单「保存图片」→ 保存对话框选 /sdcard/Download → 点「保存」。
- **期望**：文件写入 Download 目录 + SnackBar「已保存: <路径>」；**实际**：0 字节空文件 + 应用崩溃强杀（两次崩溃 pid 15029/15870，完整堆栈见 `m4b_fatal_stack_d2.txt`）。
- **机理**：插件仅 `catch (IOException)`，`SecurityException`（RuntimeException 系）未捕获；属「ROM 级授权缺陷（MuMu Download provider 未授 grantUriPermission/MANAGE_DOCUMENTS）× 插件异常处理弱点」叠加——标准 ROM 上可能不触发，但插件层不捕获任何写失败即崩主线程属插件缺陷，Dart 侧 `File(path).writeAsBytesSync` 兜底永远不可达。
- **修复方向（开发侧选项，本任务不实施）**：① `MainActivity.kt:293` onActivityResult 包装层捕获 SecurityException 并回传错误给 Dart（Dart 落兜底文档目录）；② 升级 file_picker 或改用 MediaStore 直写 Downloads（Android 10+）；③ 向插件上游提 issue。
- **验证边界**：Download 保存路径在本机被 D2 阻塞，「已保存:」SnackBar 在本 ROM 不可证明；取消兜底路径已全链路证明（toast + 落盘字节 + 魔数）；非本 ROM 设备（真实手机/其他模拟器）上 D2 是否触发未验证。

### 五、设备收尾还原（全部完成）
- 「长按保存图片」开关还原 ON（像素复核）；设置面板收起；阅读器正常浏览态；/sdcard 本次会话 QA 临时文件已清（两个 0 字节崩溃残留文件 `manga-1790780351361.jpg`/`manga-1790780625652.jpg` 属 D2 崩溃取证物，**保留未清**，供开发复现）；应用重启后无 FATAL。

### 六、证据索引（均位于 `docs/materials_1301/evidence/`）
- 冒烟：`m4b_smoke.log`（7 PASS / 0 FAIL）
- 流程截图：`m4b_00_home.png` → `m4b_01_group.png`（书架视频组）→ `m4b_02_reader.png`/`m4b_03_reader_p3.png`/`m4b_04_reader_p6.png`（读者）→ `m4b_05_toolbar_crop.png`/`m4b_06_panel_open.png`/`m4b_07_switch_on.png`（开关 ON 默认态）→ `m4b_08_savedialog_a.png`（入口 a 对话框）→ `m4b_09_after_save_a.png`（崩溃后前台）→ `m4b_10_after_cancel.png`/`m4b_11_fallback_toast.png`/`m4b_12_fallback_toast2.png`（取消兜底）→ `m4b_13_switch_off.png`（开关 OFF）→ `m4b_14_menu_b.png`（入口 b 菜单）→ `m4b_15_switch_restored.png`（还原 ON）
- dump：`m4b_16_savedialog_a.xml`（SAF 对话框树）｜`m4b_17_fallback_snackbar.xml`（兜底 SnackBar 全文）｜`m4b_18_menu_b.xml`（页操作菜单树）
- 文件证据：`m4b_ls_download.txt`（Download 两个 0 字节残留）｜`m4b_ls_app_flutter.txt`（app_flutter 两个 194,481 B JFIF）｜`m4b_fatal_stack_d2.txt`（D2 完整 FATAL 堆栈 + file_picker 源码机理）

*本段纪律自检：未改任何生产代码；D1 修复生效（两入口 SAF 对话框均弹出，M4 的 ArgumentError toast 消失）如实确认；D2 崩溃完整报错与堆栈如实记录不淡化；Download 保存被 D2 阻塞、兜底路径全链证明、Dart 层「已保存:」toast 在本 ROM 不可证明——均如实标注；崩溃残留 0 字节文件保留供开发复现。*

## M4c D2 修复回归（2026-09-30）

> QA 子代理（STAGE-QA-P43M4C）：D2 修复（6468a456bb + fe7780279e，新增 `legado/storage` 通道 MediaStore 直写 `Download/legado/`）真机回归——冒烟构建（含 Kotlin 编译核验）+ 长按保存三连 + 磁盘落盘核实 + 崩溃检查。HEAD=fe7780279e，pubspec 2.0.332+333，验收机 MuMu 192.168.100.62:5555（1080×1920 dpr3，Android 15 已 root）。被测书：阅文漫画《全职高手》（同 M4b）。全程未改任何生产代码。**D2 修复核心目标达成：SAF 对话框消除、FATAL 崩溃 0 起；但新发现缺陷 D3（MediaStore 幻影写入「假成功」）——toast 宣称保存成功但文件未落盘、MediaStore 无记录，Download 保存在本机功能上仍不可用。**

### 一、冒烟构建+装机+Kotlin 编译核验：通过
- `scripts/emulator_smoke_test.ps1 -Device 192.168.100.62:5555` → **7 PASS / 0 FAIL，退出码 0**：FFI 复用（content hash 1549248103 一致，零 Rust 改动）+ `flutter build apk --debug`（Gradle assembleDebug，APK 282 MB）；**已装 2.0.332 == pubspec 2.0.332+333**；进程存活；无 FATAL/E/flutter。证据 `m4c_smoke_raw.log`。
- **Kotlin 编译核验（任务要求项）**：对构建产物 APK 的 dex 做字节级扫描（本机 Git Bash 无 strings，用 PowerShell 字节扫描），在 `classes18.dex` 命中类描述符 `Lio/legado/flutter/StorageBridge;`（offset 72703）与通道名 `legado/storage`（offset 83615）→ **新增 Kotlin 类 StorageBridge 确实在 APK 内，Gradle 构建含 Kotlin 编译且成功**。

### 二、开关默认态：通过（判定方式与 M4b 不同，如实说明）
- 设置面板「其他」区「长按保存图片」默认 ON（截图 `m4c_05_other_tab.png` + 裁剪 `m4c_05c_switch_zoom.png`/`m4c_05d_switch_zoom2.png`）。
- **判定方式说明**：本会话整屏渲染为灰度（M4b 的暖棕 ON 像素签名不可用），开关状态改由源码判定：`manga_config_sheet.dart` L1165-1192 `_checkboxTile` 用 `CheckboxListTile.adaptive`（勾选勾 = ON），且默认值 `_mangaLongClickSaveImage = true`（`reader_comic_screen.dart`）。

### 三、长按保存三连（+ 重启后对照组）：toast「已保存」、无 SAF、无崩溃，**但文件未落盘（D3）**

| 步骤 | 结果 | 证据（`docs/materials_1301/evidence/`） |
|---|---|---|
| 长按保存 #1（23:31） | **无 SAF 对话框**（uiautomator dump 未见 ACTION_CREATE_DOCUMENT 节点）、无崩溃；SnackBar 为「**已保存: Download/legado/manga-…jpg**」——通道成功文案（与 `result.success("$RELATIVE_DIR$fileName")` 一致），非「已保存到文档目录」兜底文案 | `m4c_06_longpress_save.png`（+`m4c_06b/06c` 裁剪） |
| 长按保存 #2（23:33:04） | 同 #1 模式：通道成功 toast、无 SAF、无崩溃 | `m4c_07_save2.png`（+`m4c_07b`） |
| 长按保存 #3（23:33:16） | 同上 | `m4c_08_save3.png`（+`m4c_08b`） |
| 磁盘落盘核实（#1-#3 后 + 最终复核） | **`/sdcard/Download/legado/` 目录不存在**（No such file or directory）；MediaStore downloads 表 `content query` **无任何新增行**；`find` 全盘（/data /mnt /sdcard /storage）找不到新文件 | `m4c_ls_legado_1.txt` |
| 对照组：force-stop 重启（pid 17869）后长按保存 #4（23:35:42，3s 后截图） | 同模式：通道成功 toast，**仍无文件、无 MediaStore 行** → D3 可复现、与进程状态无关 | `m4c_10_fresh_save.png`（+`m4c_10b`） |
| logcat 崩溃检查 | 全程 logcat（1386 行）**0 FATAL / 0 SecurityException / 0 E/flutter**；重启后复查亦 0 → **D2 崩溃签名（SecurityException 抛主线程强杀）已消除** | `m4c_logcat_session_filtered.txt`、`m4c_logcat_restart_filtered.txt` |

**结论：D2 崩溃与 SAF 对话框均已消除（修复核心目标达成）；但保存链路呈「toast 宣称成功 + 实际未落盘」模式（D3），Download 保存在本 ROM 功能上仍不可用。**

### 四、新缺陷 D3（ROM 级 MediaStore 幻影写入，阻塞 Download 持久化，仅描述不改码）
- **现象**：`StorageBridge.saveImageToDownloads`（API 29+）的 `insert` / `openOutputStream` / `write` / `flush` 全部返回成功（无任何异常 → `result.success`）→ Dart 显示「已保存: Download/legado/<文件>」，但**文件从未持久化**：`/sdcard/Download/legado/` 目录从未被创建、MediaStore downloads 表无新行、`find` 全盘无文件。
- **复现**：本 MuMu（Android 15 rooted，ROM MediaProvider）任意漫画页长按保存（开关 ON）。4/4 复现（含应用重启后 1 次）。
- **期望**：文件持久化至 `Download/legado/`（size > 0、JFIF/PNG 魔数）+ MediaStore 行存在；**实际**：三者皆无，仅成功 toast。
- **机理（假设，未深入 ROM 内部证实）**：本 ROM 的 MediaProvider 静默丢弃写入（phantom write）——`insert` 返回 URI、`openOutputStream` 返回可写流、`write`/`flush` 不抛错，但字节未落到 FUSE/SD 存储层。因全程无异常，通道 `result.success` 成为**假阳性**，`finally` 中的「失败清理 0 字节残留」分支也因此从未触发（未检测到失败）。
- **与 D2 的区分**：D2 = 显式拒绝 + 未捕获异常 → 崩溃（file_picker 仅 catch IOException，SecurityException 逃逸）；D3 = 静默丢弃 + 通道假成功（StorageBridge 全异常捕获的设计目标达成——无崩溃，但缺「写后持久化校验」）。
- **验证边界与建议（开发侧选项，本任务不实施）**：① 原生侧 `result.success` 前读回校验（如 `ContentResolver` 查该 URI 的 `_size` 是否 > 0 / 读回首字节比对），校验失败改回 `result.error` 以触发 Dart 文档目录兜底；② 或 flush 后 stat 核实；③ 「通道失败 → 文档目录兜底」路径**在本 ROM 无法直接触发**（通道恒报成功），该路径已由 3 个单元测试覆盖：`flutter_legado/test/widget/reader_comic_click_actions_test.dart` `[D2 修复] 保存图片 MediaStore 通道与平台分派` 组——「Android 分支：通道成功 → Download/legado 提示，不走 file_picker」「Android 分支：通道失败 → 文档目录兜底」「非 Android 分支：不调通道，走 file_picker saveFile」，**本轮执行 3/3 通过**。
- **验证边界**：D3 是否发生在标准 ROM/其他模拟器未验证；缺陷限定于本 ROM 的 MediaProvider 行为，非通道代码逻辑必然错误。

### 五、D2 之前的 0 字节残留：仍在（仅记录，未清理）
- M4b 轮 D2 崩溃产生的 2 个 0 字节文件 `manga-1790780351361.jpg`（22:59）/ `manga-1790780625652.jpg`（23:03）**仍在 `/sdcard/Download/` 根目录**（注意：位于 Download/ 根目录，非新代码目标 `Download/legado/`）；本会话新保存**未产生任何新残留文件**（目标目录根本不存在）。证据 `m4c_ls_legado_1.txt`。

### 六、未决异常（如实陈述，不影响 D3 结论）
- 保存 #1/#2/#3 三张截图（间隔 80s，而 SnackBar duration 仅 2s）中「已保存」pill 文案像素级一致；且 pill 内文件名的时间戳数字在不同裁剪/重读间**读出相互矛盾**（小字 1080p 放大 1.5x、约 20px 数字，视觉读数不可靠）。无法区分是「snackbar 堆栈未刷新/卡住」还是「数字误读」，**此异常未根因定位**。
- 可靠事实（不依赖小字读数）：每次保存均出现**通道成功文案前缀「已保存: Download/legado/」**（非「已保存到文档目录」兜底文案）、**无 SAF 对话框**（uiautomator dump 实证）、**无崩溃**（logcat 实证）、**无文件落盘**（ls + MediaStore query + find 实证）。

### 七、设备收尾还原（全部完成）
- 「长按保存图片」开关保持 ON（默认态，全程未动过）；设置面板/阅读器已收起（HOME 退到 launcher）；/sdcard 本会话 QA 临时文件已清理（`m4c_ui2.xml` 等）；D2 时代 2 个 0 字节残留**保留**作 D2/D3 取证物；应用进程存活（pid 17869），最近 50 行 logcat 0 崩溃签名。

### 八、证据索引（均位于 `docs/materials_1301/evidence/`）
- 冒烟：`m4c_smoke_raw.log`（7 PASS / 0 FAIL）
- 截图：`m4c_01_home.png` → `m4c_02_detail.png` → `m4c_03_reader.png` → `m4c_04_panel.png` → `m4c_05_other_tab.png`（+`m4c_05b_switch_crop.png`/`m4c_05c_switch_zoom.png`/`m4c_05d_switch_zoom2.png`/`m4c_05e_switch_row.png`）→ `m4c_06_longpress_save.png`（+`m4c_06b_snackbar_crop.png`/`m4c_06c_snackbar_refix.png`）→ `m4c_07_save2.png`（+`m4c_07b_snackbar2.png`）→ `m4c_08_save3.png`（+`m4c_08b_snackbar3.png`）→ `m4c_09_final_state.png` → `m4c_10_fresh_save.png`（+`m4c_10b_snackbar.png` 对照组裁剪）
- 文件证据：`m4c_ls_legado_1.txt`（Download ls + MediaStore query + 结论）｜`m4c_logcat_session_filtered.txt`（全程 0 崩溃）｜`m4c_logcat_restart_filtered.txt`（重启后 0 崩溃）
- 单元测试：`flutter test test/widget/reader_comic_click_actions_test.dart --plain-name "D2 修复"` → **3/3 通过**（通道成功 / 通道失败兜底 / 非 Android）

*本段纪律自检：未改任何生产代码；D2 核心目标（崩溃消除 + SAF 消除 + Kotlin 编译进包）确认达成；D3 假成功缺陷不淡化——现象/复现/机理/修复方向完整记录；「写后持久化校验」在本 ROM 不可直接证明（通道恒报成功、兜底路径不可触发），改以单元测试 3/3 通过佐证并如实声明；snackbar 小字读数异常如实陈述不掩盖。*
