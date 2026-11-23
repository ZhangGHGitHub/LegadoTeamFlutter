# R43 剩余 28 屏深色参考截图 · 可补采性评估与执行方案

- 评估日期：2026-11-23
- 评估角色：调研子代理（只读调研 + 实测探针；**未采集任何截图、未改产品代码/台账/契约**）
- 仓库 HEAD：`dba2e083da`（`fix(rust): 升级 url 2.5.8 → 2.5.9 修复 RUSTSEC-2026-0592 栈溢出漏洞`），分支 `master`
- 前序文档：`docs/LEDGER_VERIFICATION_20261123.md`（28 屏真缺清单）、`docs/DARK_THEME_PARITY_LEDGER_20260920.md`（屏名权威来源）
- 设备动作说明：本次为完成「实测确认」，临时启动了 MuMu 实例 0 并做只读探针，**结束前已 `force-stop` 应用、还原系统夜间模式、清理设备侧临时 dump、断开 adb、关闭实例 0**，设备状态与开工前一致（两实例均 `is_android_started=false`）。

---

## 一、结论摘要

| 口径 | 数量 |
|---|---|
| 待评估屏数 | **28** |
| **A 类：可脚本化自动采（已实测 dump 验证）** | **19** |
| **B 类：可自动导航但断言弱 / 需前置数据（需人工核图）** | **5** |
| **C 类：参考版根本不存在该页，无法补采** | **4** |

**核心结论：28 屏中 24 屏（A+B）技术上可自动补采，但需要先修 3 处脚本能力缺口（display-id 支持）；另 4 屏（C）应从「待补采」改判为「参考版无此入口」，不是补采问题。**

**三条推翻既有认知的实测发现（重要）**：

1. **「阅读器自绘菜单 dump 全空」不成立**——根因是 **MuMu 多逻辑显示（multi-display）**：kazusa 窗口落在 logical display 7~13（每次冷启递增），而 `adb shell input tap` / `uiautomator dump` 默认打 **display 0**（桌面）。加上 `-d <logicalId>` 后，阅读器菜单 dump 有 **51 个节点**（`全文搜索/自动翻页/目录/朗读/设置` + 顶栏 `返回/离线缓存/刷新章节/换源/更多操作`），目录页 dump 有 **66 个节点**（`信息/目录/书签/笔记` 四页签 + 章节列表 + `使用替换规则/显示字数/反转目录`）。历史上「dump 全空」的结论应视为**多屏未加 `-d` 的假象**。
2. **「kazusa 返回栈会跳桌面」的真实根因也是多显示**——不是应用 bug：`input keyevent 4` / `input tap` 不加 `-d` 时事件发往 display 0，应用窗口在 display 7+ 收不到事件、系统把前台切回桌面。加 `-d` 后返回键与点按均正常。
3. **截图必须用 physical uniqueId，不能用 logical id**——`screencap -p -d <logicalId>` 返回 `Status: -2`；必须用 `dumpsys SurfaceFlinger --display-id` 给出的**物理 uniqueId**（如 `4619827106603731468`）。不加 `-d` 时默认取「第一个 display」= 桌面，这正是 `docs/**` 中 47 张纯黑/桌面坏图的成因之一。

---

## 二、设备实测状态（本轮真实测量，非照抄历史）

### 2.1 MuMu 实例

开工时 `MuMuManager info -v all` 实测 **两个实例均未启动**：

| index | name | Android | 开工 `is_android_started` | 本轮处置 |
|---|---|---|---|---|
| 0 | Test2 | 15.0 | `false` | **临时启动用于探针，结束后 shutdown 还原** |
| 1 | Test测试 | 15.0 | `false` | 未触碰 |

实例 0 启动后：`is_android_started=true`、`is_process_started=true`、`player_state=start_finished`、`adb_port=16384`（**该字段不可信**，`127.0.0.1:16384` 实测 `cannot connect`）。

**可用端点（实测）**：`MuMuManager sh -v 0 -c "ip addr show wlan0"` → `192.168.100.63/24`；`adb connect 192.168.100.63:5555` → `connected`，`adb devices -l` 显示 `192.168.100.63:5555 device product:r9q model:SM_G9900`。

> 与历史记录对照：2026-11-13 批次记录 `192.168.100.63:5555`（index 0 Test2）——**本轮实测一致**；`127.0.0.1:16384` 依旧不通（历史已登记该端口不可信，本次再次证实）。

### 2.2 参考版是否在装

**实测在装**（`pm list packages` + `dumpsys package`）：

| 包 | versionName | versionCode | lastUpdateTime | 说明 |
|---|---|---|---|---|
| `io.legato.kazusa` | **3.26.19** | 18759 | 2026-10-28 11:47:24 | **参考版，在装** |
| `io.legado.flutter_legado` | 2.0.510 | 511 | 2026-11-18 01:47:36 | 我方 |
| `com.legado.app.release` | 3.26082823 | 38268 | — | 原版 |

设备：1080×1920 / density 480（360dp 基准）；Android 15。

### 2.3 root 与数据可读性

- `adb root` **成功** → `uid=0(root)`（历史记录未提及，本轮新增可用能力）。
- 无 `su` 二进制，但 root adbd 足以读 `/data/data/io.legato.kazusa/`。
- 可读：`shared_prefs/*.xml`、`files/datastore/settings.preferences_pb`（8744B）、`databases/legado.db`（5.3MB）。

### 2.4 kazusa 当前数据基线（决定哪些屏「有料可拍」）

`legado.db` 实测：

| 表 | 行数 | 对补采的影响 |
|---|---|---|
| `books` | **3** | 2 本小说（重生高考前99天 ×2）+ 1 本漫画（全职高手，type=64）→ 书架/详情/阅读器/目录全部可达 |
| `chapters` | 1844 | 目录页有真实章节列表 |
| `book_sources` | **556** | 其中 `enabledExplore=1` 共 **415** 个 → 发现域源极多 |
| `txtTocRules` | 26 | TXT 目录规则页有料 |
| `dictRules` | 2 | 字典规则页有料（百度汉语/海词英文） |
| `readRecord` | 2 | 阅读记录页有料 |
| `bookmarks` | **0** | 书签页为空态（`暂无书签`） |
| `book_marks` | **0** | 无标注 |
| `replace_rules` | **0** | **替换净化页为空列表** → 2-9 编辑器需先建规则 |
| `rssSources` | 0 | RSS 域空 |

主题基线（`settings.preferences_pb` 解析）：`app_theme=0`（动态取色）、`themeMode=0`（**跟随系统**）、`pure_black=false`；系统 `ui_night_mode=null` → **当前解析为浅色**。

---

## 三、关键实测发现（决定方案可行性的硬约束）

### 3.1 多逻辑显示是本次自动化的唯一真障碍

实测序列（每次 `am force-stop` + `am start` 后）：

| 冷启次数 | kazusa 窗口 `mDisplayId` |
|---|---|
| 1 | 7 |
| 2 | 8 |
| 3 | 9 |
| 4 | 10 |
| 5 | 11 |
| 6 | 12 |
| 7 | 13 |

`dumpsys display` 同时存在 display 0（内置屏幕 mumuscreen000）、7/8…（mumuscreen00N）。`dumpsys window windows` 显示 kazusa 窗口 `mDisplayId=<N>`，而 `input tap` 无 `-d` 时投递到 display 0。

**实证对照**：

| 操作 | 结果 |
|---|---|
| `input tap 972 1822`（无 -d） | 前台切回 `com.microsoft.launcher`（桌面） |
| `input -d 7 tap 972 1822` | 正常进入「我的」页（dump 74 节点） |
| `uiautomator dump`（无 --display） | 读到桌面 46 节点 |
| `uiautomator dump --display 7` | 读到 kazusa 108 节点（书架） |
| `input keyevent 4`（无 -d） | 回桌面 |
| `input -d 7 keyevent 4` | 正常返回上一页 |

### 3.2 截图必须用物理 uniqueId

| 命令 | 结果 |
|---|---|
| `exec-out screencap -p` | 2.4MB，**内容是桌面**（"Multiple displays were found… Defaulting to the first display"） |
| `screencap -p -d <logicalId 11>` | **`Failed to take screenshot. Status: -2`**，产物 56B |
| `screencap -p -d 4619827106603731468`（physical uniqueId） | **成功**，内容为 kazusa 设置页（深色，均值 lum≈28） |

`dumpsys SurfaceFlinger --display-id` 是取得正确 id 的唯一可靠途径。

### 3.3 深色基线可无侵入获取

实测两条路径均可行：

- **路径 A（推荐，与历史 04_appearance_dark.png 采法一致）**：kazusa 内 `设置 → 外观 → 主题模式 → 深色`（`themeMode` 0→2）。历史 `RECAPTURE_20260921.md` 已记录该路径可持久化。
- **路径 B（本轮实测通过）**：`adb shell cmd uimode night yes`。因 kazusa `themeMode=0`（跟随系统），系统切深后应用即时变深——本轮用此路径截到深色设置页（均值 lum≈28），**采完 `cmd uimode night auto` 还原**。

路径 B 更省交互步骤，但会改设备全局状态（采完必须还原）；路径 A 更贴近参考版自身语义。建议 **A 为主、B 为兜底**。

### 3.4 既有采集脚本的三处能力缺口（必须补才能跑）

`scripts/parity_capture_ref.py` 与 `scripts/parity_capture_ours.py` 均为单显示假设：

| 文件 | 函数 | 现状 | 需补 |
|---|---|---|---|
| `scripts/parity_capture_ref.py:143` | `tap()` | `input tap x y` 无 `-d` | 加 display-id 参数 |
| `scripts/parity_capture_ref.py:194` | `dump()` | `uiautomator dump <path>` 无 `--display` | 加 `--display` |
| `scripts/parity_capture_ref.py:228` | `screenshot()` | `exec-out screencap -p` 无 `-d` | 改用 physical uniqueId |
| `scripts/parity_capture_ours.py:224` | `tap()` | 同上 | 同上 |
| `scripts/parity_capture_ours.py:257` | `dump()` | 同上 | 同上 |
| `scripts/parity_capture_ours.py:308` | `screenshot()` | 同上 | 同上 |

另需新增一个**每次冷启后重探 display id** 的辅助函数（因 id 递增，不能缓存）。

> 注：`scripts/parity_capture_ref.py:72` 默认设备仍是 `192.168.1.19:5555`（旧端点），需用 `--device 192.168.100.63:5555` 覆盖。

---

## 四、28 屏 A/B/C 分类（逐屏实测依据）

> 图例：A=可脚本化自动采（本轮已实测 dump 命中屏独有元素）｜B=可自动导航但断言弱或需前置数据（需人工核图）｜C=参考版无此页，无法补采

### 4.1 A 类：可脚本化自动采（19 屏）

| 屏号 | 屏名 | 实测导航路径 | 实测 dump 证据（本轮） |
|---|---|---|---|
| 1-2 | 首页页签 | 底栏「首页」 | 91 节点：`最近阅读/累计阅读/阅读时长/今日阅读目标/设定目标` |
| 1-4 | 书架溢出菜单 | 书架 → 顶栏 ⋮ | 27 节点：`远程书籍/添加本地/更新目录/布局设置/分组管理/添加网址/选择模式/书架管理/导出书单/导入书单/日志` |
| 1-5 | 书架批量多选态 | 书架 ⋮ →「选择模式」 | 124 节点：`已选0本 · 共3本` + 书卡 |
| 1-7 | 搜索结果页 | 书架 🔍 → 点搜索历史 | 107 节点：`搜索结果：重生高考前99天` + 结果项 + 标签 |
| 1-9 | 目录页 | 阅读器菜单 →「目录」 | 66 节点：`信息/目录/书签/笔记` 四页签 + 章节列表 + `2459字` 字数胶囊 |
| 1-14 | 目录·书签页签 | 目录页 →「书签」 | 40 节点：`暂无书签` 空态 + 页签行 |
| 2-2 | 发现溢出菜单 | 发现 → 顶栏 ⋮ | 28 节点：`全部/出版书源/代理书源/聚合书源/快速书源/漫画书源/轻文书源/特殊书源/通常书源/同人书源/图片书源` |
| 2-5 | 发现分类书单 | 发现 → 点源 → 点分类 | 103 节点：书单条目（书名/作者/最新章/标签/连载态） |
| 2-6 | 换源/书源弹层 | 阅读器菜单 →「换源」 | 62 节点：`换源/筛选/18 / 556 · 2` + 候选源列表 |
| 2-7 | 书源管理 | 我的 →「书源管理」 | 149 节点：源列表（名称/分组/…） |
| 3-2 | 阅读记录 | 我的 →「阅读记录」 | 83 节点：`累计阅读成就/已读 2 本书/共阅读 8小时6分钟` + 记录行 |
| 3-6 | 设置·备份与恢复 | 我的 → 设置 →「备份与恢复」 | 54 节点：`WebDav 设置/服务器地址/账号/子文件夹 legado/设备名称/测试 WebDav 配置/同步阅读进度` |
| 3-8 | 朗读 | 我的 → 设置 →「朗读设置」 | 58 节点：`常规/引擎与音色/角色与配乐` 三页签 + `默认朗读界面/播放器背景/显示朗读胶囊` 等 |
| 3-9 | 分组管理 | 书架 ⋮ →「分组管理」 | 127 节点：`在读/未读/已读/连载已读/完本已读/小说…` 分组卡 |
| 4-1 | TXT 目录规则 | 我的 →「TXT 目录规则」 | 157 节点：`目录(去空白)/目录(匹配简介)/目录(古典、轻小说备用)/数字(纯数字标题)…` + 示例 |
| 4-2 | 字典规则 | 我的 →「字典规则」 | 66 节点：`百度汉语/海词英文` |
| 4-3 | 文件管理 | 我的 →「文件管理」 | 27 节点：`筛选 • 文件管理` + `root/cache/files` |
| 4-4 | 关于页 | 我的 →「关于」 | 53 节点：`阅读 3.26.19/全新设计的阅读 3.0/开发人员/用户隐私与协议/开源许可/免责声明/崩溃日志` |
| 4-5 | 首页模块管理二级页 | 首页 → 顶栏「首页模块管理」 | 24 节点：`首页模块管理/+ 新建自定义集/浏览书源模块` |

> 4-5 注：台账标记「随裁决」。实测该页**参考版存在且可达**，但 0914 台账记载「用户裁决暂不实施」。建议**先请示再采**，否则按原裁决跳过。

### 4.2 B 类：可自动导航但断言弱 / 需前置数据（5 屏）

| 屏号 | 屏名 | 障碍（实测） | 补采条件 |
|---|---|---|---|
| 1-12 | 正文长按菜单 | 正文中部 3 个探点（y=700/900/1200）`input swipe x y x y 1000` 长按后 dump 仅 **11 节点（纯正文）**，无工具条节点 | 需改用更长按压（≥1500ms）或改用 `input draganddrop`；**截图可采但无机器断言**，必须人工核图 |
| 1-15 | 章节跳转 | 目录页无独立 FAB；`更多菜单`（[960,903]）点按后退出到正文，跳转入口未定位 | 需在目录页/阅读器菜单内探测跳转入口（可能藏在进度条长按或目录 ⋮）；**需 1 轮人工探索** |
| 1-16 | 自动翻页 | 阅读器菜单点「自动翻页」（[324,1758]）后 dump 仅 11 节点（控制条未进 a11y 树或未激活） | 控制条疑为自绘；**可截图但无断言**，需人工核图；且需先确保不残留自动翻页状态污染后续屏 |
| 2-4 | 发现源二级页（下拉） | 需选**下拉选择器型源**（`exploreUrl` 含 `"type": "select"`）。实测 `奈飞工厂` 进入后为 chips+关键字输入，未命中下拉控件；DB 中确有 6 个 select 型源（`🎨🔞老司机/🎬七猫短剧/📂网阅小说/🎭🎬露西弗同人站/🔞海棠文学/🎬电源先生`） | 需定向选这 6 个源之一并滚到 `select` 控件；已有浅色参考 `ref_batch2/04_discover_expand_dropdown.png` + `05_dropdown_options.png` 可对照形态 |
| 2-9 | 替换净化编辑器 | `replace_rules=0` → 进「替换净化」只见页标题（32 节点，空列表） | 需先在参考版**新建一条替换规则**（越界写库需授权），或用 `已归档` 的浅色 `ref_batch2/10_replace_rule_edit.png` 作形态参照后仅采空列表页 |

### 4.3 C 类：参考版根本不存在该页（4 屏）——不是补采问题

| 屏号 | 屏名 | 判定依据（双重实证） |
|---|---|---|
| 3-7 | 字体（Tt 入口） | ① `docs/SCREEN_1TO1_PARITY_LEDGER_20260914.md:268` 已定案「参考版**无独立字号/Tt 页**——「阅读界面」页实为显示/菜单参数，字号在阅读器内部调整」；② 本轮实测 `设置 → 阅读界面` dump 58 节点，全为 `屏幕显示与亮度/屏幕方向/屏幕超时/隐藏状态栏/隐藏导航栏/填充刘海区域/菜单标题显示方式/菜单不透明度`，**无字号/字体项**；滚到底仍是 `文字两端对齐/文字底部对齐/适配特殊样式/使用自定义中文分行/护眼模式`。参考版字号在**阅读器设置 Sheet**（`阅读界面` 面板，含 `字号 24/背景/翻页动画`） |
| 3-10 | 定时任务 | ① `SCREEN_1TO1_PARITY_LEDGER_20260914.md:269` 已记录「参考侧「高级」页无该项（已枚举全字段）→ 判**参考版无此入口**」；② 本轮实测：我的页全量枚举仅 `设置/书签/阅读记录/缓存管理/文件管理/关于/退出` 七项，**无「定时任务」**；③ APK 反查 `resources.arsc`（3.39MB）+ 4 个 dex（26.4MB）**「定时任务」零命中**（仅 `定时` 5 处、均为朗读定时关闭语义） |
| 3-11 | 高亮标注列表 | ① APK 反查「高亮标注」**零命中**（`高亮` 仅 `高亮规则/复用高亮规则` 等 9 处，属阅读样式规则）；② 参考版我的页只有「书签」→ 打开为「所有书签」空态（31 节点 `暂无书签`），**无「高亮标注」列表页**；③ 我方 3-11 对应 `all_bookmarks_screen`（书签列表），参考侧对应页已在 1-14/书签空态覆盖 |
| 4-6 | 超低频深页 | 台账 `SCREEN_1TO1_PARITY_LEDGER_20260914.md:81` 明载「原登记「维持不采」；批 4 到达时再请示是否豁免」。该「屏」实为**4 个分散子页拼盘**（书源调试/登录源/续读电池/朗读更多设置），无统一入口；其中「朗读更多设置」已被 3-8 的「朗读设置」覆盖。**建议维持豁免** |

---

## 五、耗时估算

| 类别 | 屏数 | 单屏实测耗时构成 | 合计估算 |
|---|---|---|---|
| 脚本改造（一次性） | — | display-id 三处 + 重探函数 + 深色切换/还原 | **~40–60 min**（含自测） |
| A 类 | 19 | 冷启 10s + 导航 3~8 步×3s + settle 4s + dump 2s + 截图 2s ≈ **60–90 s/屏** | **~25–30 min**（串行机器时间） |
| B 类 | 5 | 1-12/1-15/1-16 各需 1 轮交互探索（10–20 min）；2-4/2-9 各 ~5 min | **~40–50 min** |
| C 类 | 4 | 不可采 | **0** |
| 人工核图 | 24 | 逐张目视确认「确为参考版 + 确为深色 + 内容非错态」 | **~30–40 min** |

**若只做 A 类**：脚本改造 1h + 采集 0.5h + 核图 0.5h ≈ **2 小时**，可得 **19 屏**。
**A+B 全做**：≈ **3 小时**，可得 **24 屏**。
**C 类 4 屏**：改判即可，不耗采集时间。

---

## 六、建议

### 6.1 总体建议：**建议继续补采（A 类优先），不要整体接受现状**

理由：A 类 19 屏（占 68%）已逐屏实测 dump 命中屏独有元素，导航路径稳定、脚本化成本低；且本轮发现「阅读器 dump 全空」是假象，原先被判「只能手动」的 1-9/1-11/1-14 等其实可自动。**唯一真实障碍（多显示）是一次性脚本改造，不是每屏的人工成本。**

### 6.2 分步执行建议

1. **先做 4 屏 C 类改判（0 成本，立刻可做）**：在 `DARK_THEME_PARITY_LEDGER_20260920.md` 把 3-7 / 3-10 / 3-11 / 4-6 从「❌待补采」改为「⛔ 参考版无此入口（不适用）」，并注明依据（0914 台账定案 + APK 零命中 + 本轮实测枚举）。**这不是补采欠账，是口径错误。** 改判后真缺从 28 → 24。
2. **脚本改造（前置门禁）**：给 `scripts/parity_capture_ref.py` 补 `--display-id` 支持 + 冷启后重探 + physical uniqueId 截图；`parity_capture_ours.py` 同改。改造后用 3-3（已有归档可对照）做**回归自检**：重采 3-3 应与 `docs/parity_shots/ref_dark_20261123/b3_kazusa_settings.png` 形态一致。
3. **A 类分三波采**（按域分批，每波之间做人工核图）：
   - 第一波（书架/首页/搜索域，6 屏）：1-2、1-4、1-5、1-7、2-2、2-5
   - 第二波（阅读器域，3 屏）：1-9、1-14、2-6
   - 第三波（我的/设置/长尾，10 屏）：2-7、3-2、3-6、3-8、3-9、4-1、4-2、4-3、4-4（4-5 先请示）
4. **B 类单独排期**（交互探索性质，不适合混在批量脚本里）：1-15、1-16 各做 1 轮人工探索定坐标；2-4 定向选 6 个 select 型源；2-9 需先决策「是否允许在参考版写一条规则」（**写库属越界，需用户授权**，否则只采空列表页并注明）。
5. **1-12 单独处理**：长按工具条是 kazusa 正文自绘浮层，3 探点未命中；建议用更长按压（1500–2000ms）重试 1 轮，仍不中则按「可截图无断言」处理并人工核图。

### 6.3 采集时的硬性操作规范（本轮实测沉淀，建议写入脚本注释）

1. 每次 `am force-stop` + `am start` 后**必须重探** `mDisplayId`（递增，不可缓存）。
2. 所有 `input tap/swipe/keyevent` 必须带 `-d <logicalId>`。
3. 所有 `uiautomator dump` 必须带 `--display <logicalId>`。
4. 所有 `screencap` 必须带 `-d <physicalUniqueId>`（从 `dumpsys SurfaceFlinger --display-id` 取，**不能**用 logical id）。
5. 深色基线采完必须 `cmd uimode night auto`（若走路径 B）或把 `themeMode` 还原为 0。
6. 自动翻页状态在采集后必须复位（否则污染后续阅读器屏）。

---

## 七、47 张纯黑占位图核实（只报告，未删除）

### 7.1 核实结果：确为 **47 张**，与台账数字一致

扫描方法：`docs/**/*.png` 逐张 PIL 读入转 RGB，`getextrema()` 三通道均为 `(0,0)` 判定纯黑。结果 **47 张**，全部为 1080×1920。**47 张全部已被 git 跟踪**（`git ls-files` 全部命中，无未入库文件）。

分布：

| 目录 | 数量 | 文件 |
|---|---|---|
| `docs/evidence/batch31/` | 17 | `A_shot_3`、`B1_shot_3`、`B2_shot_3`、`C1_shot_3`、`C2_shot_2`、`C3_shot_2`、`E_review_ch1`、`E_review_ch1_3`、`E_review_panel_3`、`final_shelf_3`、`probe_d56`、`probe_d56_b`、`probe_d56_c`、`probe_d56_d`、`probe_d57`、`release_1_home`、`shot_try2` |
| `docs/parity_shots/verify_ui_20260922/` | **23** | `d9_00_initial_state`、`p29_probe_4619827144452474627`、`p29b_b1_crash_dialog`、`p29b_b5_local_reader_menu`、`p29b_probe_d6`、`p29c_03_app_display11`、`probe_4619827581455741454`、`rf_01_baseline_initial`、`rf_02_search_open`、`rf_03_search_results`、`rf_06_book_detail`、`sbd_diag_d7`、`swb_21_disp002`、`swd_1a_00_bookshelf`、`swd_1a_01_reader`、`swd_imp0`、`swd_restore_boot`、`swd_s0_app_launch`、`swd_s1_after_import_link`、`swd_s2_now`、`swd_w2_dialog`、`vui2_20_shelf_restored_check`、`vui2_sfcap_d8_new` |
| `docs/evidence/batch34/` | 1 | `sf_4619827581455741454.png` |
| `docs/evidence/batch39b/` | 1 | `01_launch.png` |
| `docs/evidence/batch45c/ui/` | 1 | `d_4619827293253378061.png` |
| `docs/materials_1101b/` | 1 | `08_lockscreen_hold.png` |
| `docs/materials_1113e/` | 1 | `b26_reader.png` |
| `docs/parity_shots/ref_dark_20260921/` | 2 | `bg_black_1080.png`、`_picked_light.png` |

> **合计核对**：17 + 23 + 1 + 1 + 1 + 1 + 1 + 2 = **47** ✅
> 与台账差异：`LEDGER_VERIFICATION_20261123.md` §4.1 记 `verify_ui_20260922` 为 20 张，本轮逐张实测为 **23 张**（台账漏计 3 张）；`batch31` 17 张与台账一致。以本轮实测为准。

### 7.2 引用情况（决定「能不能删」）

| 类别 | 数量 | 说明 |
|---|---|---|
| **有意为之的测试素材（应保留）** | 2 | `bg_black_1080.png` = 注入的纯黑测试背景（`RECAPTURE_20260921.md` §2 明载）；`_picked_light.png` = 同批「已选背景图」测试产物 |
| **被验收报告真实引用（保留，删则断链）** | 4 | `evidence/batch39b/01_launch.png`（`DEVICE_ACCEPTANCE_20261110_BATCH12/13`、`BATCH9B5C`）、`materials_1101b/08_lockscreen_hold.png`（`BATCH9B6C`）、`materials_1113e/b26_reader.png`（`DEVICE_ACCEPTANCE_20261113_BATCH26:131` 已注明「该次截图为黑屏，以 u14.xml 为准」）、`verify_ui_20260922/vui2_20_shelf_restored_check.png`（`VERIFY_UI_20260922.md`） |
| **仅被核实台账自身列举（自指）** | 27 | 只在 `docs/LEDGER_VERIFICATION_20261123.md` §4.1 的「坏图清单」里被点名，无其它用途 |
| **完全未被任何文档引用** | 14 | `batch31/probe_d56_b|c|d`、`p29_probe_4619827144452474627`、`rf_01/02/03/06_*`、`swd_1a_00/01`、`swd_s0/s1/s2/w2_*` |

（2+4+27+14 = 47 ✅）

### 7.3 处置建议（**不建议直接删除**）

**结论：不删；改为「建立机器可读的排除清单」+「对 14 张无引用者单独确认」。**

理由：
1. 这 47 张全在 git 历史里，删除会产生「验收报告引用了不存在的图」的断链风险（尤其上述 4 张真实引用）。
2. 它们的危害**仅限亮度扫描假阳性**，而该扫描是文档核对动作、非产品代码，**用清单排除即可根治，无需删文件**。
3. `LEDGER_VERIFICATION_20261123.md:33` 已记录「已全部剔除」——但剔除逻辑写在文档里、未落成可复用清单，下次扫描还会重犯。

**具体建议（三步，均属 `docs:` 范畴）**：

1. **新建 `docs/parity_shots/BLACK_PLACEHOLDER_DENYLIST.txt`**（或 `.json`），逐行列出这 47 个路径 + 分类标记（`intentional-test-asset` / `referenced-by-acceptance` / `bad-capture`）。亮度扫描脚本先读该清单做排除。
2. **在 `docs/parity_shots/ref_dark_20260921/RECAPTURE_20260921.md`** 里给 `bg_black_1080.png` / `_picked_light.png` 补一句「本两张为纯黑测试素材，非坏图，勿纳入亮度扫描」——目前该目录无此说明，容易被下次扫描误判。
3. **14 张无引用坏图**（§7.2 末行）：建议由主代理决定是否 `git rm`。若删，先确认对应批次验收报告不以图为准（如 `batch31` 的结论是否有 XML dump 兜底）。**本轮未删，仅登记。**

> 附带收益：本轮的「多显示」根因发现（§3.2）恰好解释了这批纯黑图的来源——`screencap` 无 `-d` 时抓到的可能不是应用窗口所在 display，或 `-d <logicalId>` 直接返回 `Status: -2` 产出空图。**今后补采按 §6.3 规范执行，不会再产生新的纯黑占位图。**

---

## 八、附：本轮实测命令留痕（可复现）

```powershell
# 实例与端点
& "D:\Program Files\MuMuPlayer\nx_main\MuMuManager.exe" info -v all
& "D:\Program Files\MuMuPlayer\nx_main\MuMuManager.exe" control -v 0 launch
& "D:\Program Files\MuMuPlayer\nx_main\MuMuManager.exe" sh -v 0 -c "ip addr show wlan0"
adb connect 192.168.100.63:5555

# 包与版本
adb -s 192.168.100.63:5555 shell pm list packages | findstr "legado legato"
adb -s 192.168.100.63:5555 shell dumpsys package io.legato.kazusa

# root 与数据
adb -s 192.168.100.63:5555 root
adb -s 192.168.100.63:5555 shell "sqlite3 /data/data/io.legato.kazusa/databases/legado.db 'select count(*) from books;'"

# 多显示（关键）
adb -s 192.168.100.63:5555 shell "dumpsys window windows | grep -A2 'Window{.*io.legato'"
adb -s 192.168.100.63:5555 shell "dumpsys SurfaceFlinger --display-id"
adb -s 192.168.100.63:5555 shell "input -d <logicalId> tap 972 1822"
adb -s 192.168.100.63:5555 shell "uiautomator dump --display <logicalId> /sdcard/x.xml"
adb -s 192.168.100.63:5555 shell "screencap -p -d <physicalUniqueId> /sdcard/x.png"

# 深色基线（采完还原）
adb -s 192.168.100.63:5555 shell cmd uimode night yes
adb -s 192.168.100.63:5555 shell cmd uimode night auto

# 收尾
adb -s 192.168.100.63:5555 shell am force-stop io.legato.kazusa
& "D:\Program Files\MuMuPlayer\nx_main\MuMuManager.exe" control -v 0 shutdown
```

> Git Bash 下调用 adb 需 `export MSYS2_ARG_CONV_EXCL="*"`，否则 `/sdcard/...` 会被路径转换改写成 `D:/Program Files/Git/sdcard/...`。

---

## 九、给下游的可执行入口

| 下游角色 | 可直接执行的动作 |
|---|---|
| 台账维护 | 按 §4.3 把 3-7/3-10/3-11/4-6 改判「⛔ 参考版无此入口」，真缺 28 → 24 |
| 脚本开发 | 按 §3.4 补 3 处 display-id 能力 + §6.3 规范写注释；改完用 3-3 回归自检 |
| 采集执行 | 按 §6.2 第三项三波采集 A 类 19 屏，输出到 `docs/parity_shots/ref_dark_20261123_b/`（建议新目录，避免与已归档的 20261123 混） |
| 证据卫生 | 按 §7.3 建 `BLACK_PLACEHOLDER_DENYLIST.txt` + 补 RECAPTURE 说明 + 确认 14 张无引用者去留 |
