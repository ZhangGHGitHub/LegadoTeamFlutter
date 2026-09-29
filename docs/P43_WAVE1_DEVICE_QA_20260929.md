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
