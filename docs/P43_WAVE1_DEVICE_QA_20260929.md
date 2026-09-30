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
