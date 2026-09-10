# 未完成项与搁置项开发建议（对齐差异清单 §十 审计结论）

> 编写：Qoder UI ｜ 2026-09-09
>
> **口径**：功能基准=`legado-upstream`（原版 Android 源码，路径 `D:\OH-WorkSpace\LegadoTeam\legado-upstream`）；实现/架构基准=`Projects/legado_flutter`（重构版工程）；视觉基准=参考版 kazusa 实机截图（差异清单内）。
> **红线提醒**：未经授权禁止新增原版不存在功能；FFI/接口变更须先冻结 `docs/API_CONTRACT.md`。

## A. 待语义核实类（先核实、后实施，避免盲改）

### A1. 搜索顶栏三钮（筛选 / 定位 / 设置）
- **现状**：我方顶栏=←+胶囊输入条+前进→+⋮；参考版=←+⚙+定位+筛选（实心）。语义未知，此前按审计纪律未改。
- **核实基准**：重构版 `Projects/legado_flutter/lib/features/search/search_page.dart`（顶栏构成与三钮动作）；原点击对应原版 `ui/book/search/SearchActivity.kt` 菜单项（精准搜索/显示搜索记录/书源管理/分组或书源/日志）。
- **建议方案**：维持我方 ⋮ 菜单承载原版菜单项；在 ⋮ 左侧**新增筛选图标钮**，复用现有"分组或书源"范围菜单（`search_screen_scope_sheet.part.dart`），图标换 `filter_alt`；⚙/定位若核实为书源管理/书源定位语义，则分别映射 `AppRoutes.sources` 与"定位当前书源"（现有 scope 内能力）。
- **风险**：低（纯 UI）；勿动既有 ⋮ 行为。
- **估算**：0.5 天。**建议**：核实后并入下一体验增强批。

### A2. 换源形态（底部弹层 vs 整页）
- **现状**：我方=整页（书名头+搜索/刷新/⋮+空态+FAB+底部源 URL 条）；参考版=底部弹层（把手+图标行+筛选输入+搜索进度条+源卡列表）。
- **核实基准**：原版 `ui/book/changesource/ChangeBookSourceDialog.kt`（原版即为 **Dialog/弹层**语义 + `ChangeBookSourceAdapter.kt` 源卡行）。
- **建议方案**：按原版语义将 `change_source_screen.dart` 改为 `showModalBottomSheet` 形态或保留整页但补齐：筛选输入、搜索进度（`searchedCount/totalCount` 已有同款数据）、源卡三项信息（作者/最新章节/字数chip）、当前源高亮、图钉置顶、暂停。**注意**：换源变量链与 persist 逻辑（3 号提交 30edc8527d）不得动，仅改外壳与信息密度。
- **风险**：中（涉及换源链路 UI 重组，需回归换源 E2E 夹具测试）。
- **估算**：1.5 天。**建议**：独立小批，实施前跑一遍 R1 换源 E2E。

### A3. 替换净化编辑器（弹窗 → 整页）
- **现状**：我方=弹窗表单；参考版=整页编辑器（含作用域 chips/正则/范围 + 保存 FAB）。
- **核实基准**：原版替换规则编辑 UI（`data/entities/ReplaceRule.kt` 字段全集；编辑入口在 `ui/replace/` 下 dialog 或 `ReplaceRuleController` 关联页——实施前打开确认弹窗/整页归属）。
- **建议方案**：若原版亦为弹窗 → 维持现状仅补齐字段呈现（作用域 chips 化）；若原版为整页 → 新建 `replace_rule_edit_screen.dart` 整页（复用现有字段与保存逻辑，弹窗保留为快捷编辑）。
- **风险**：低（字段已全）。**估算**：1 天。**建议**：随 A4 同批。

### A4. 发现页：行卡片底 + 顶栏 ⋮；发现源二级页 3 列 chips
- **现状**：我方=无卡片底平铺行 + 文件夹图标；二级页=源名下拉+分类 chips+通栏瓦片。参考版=卡片底行 + ⋮；二级页=排行榜通栏+3 列 chips（巅峰榜/出版榜…）+热门标签。
- **核实基准**：重构版 `features/explore/explore_list_page.dart`、`explore_tab_page.dart`；原版 `ui/book/explore/ExploreShowActivity.kt`。
- **建议方案**：行加圆角卡底（`surfaceContainer` 16dp，沿用 T1 订阅页瓦片规范）；顶栏文件夹图标旁补 ⋮（菜单项按原版 ExploreShowActivity 菜单）；二级页子分类从通栏瓦片改 3 列 chips 网格（`Wrap`/`GridView.count(crossAxisCount:3)`）。
- **风险**：低。**估算**：1 天。**建议**：并入发现页批次。

## B. 中优功能对齐

### B1. 书籍详情页（沉浸头一致，差异在主体）
- **现状**：我方封面居中大图 + 五宫格（移出书架/目录/分组/换源/阅读记录）+ 底部双按钮；参考版封面左置+信息右置 + 四宫格（已在书架/查看目录/书源/阅读记录）+ 在读/最新/共N章强调排版 + 右下浮动阅读钮。
- **核实基准**：原版 `ui/book/info/BookInfoActivity.kt` + `res/layout/activity_book_info.xml`（原版封面/信息排布与按钮位以此为准）；重构版 `features/book/book_info_page.dart`。
- **建议方案**：①头部改「封面左置 96×128 + 右侧书名/作者/来源/字数/分类标签」两栏；②四宫格保留我方"换源/分组"入口（原版"书源"入口语义=查看该书源，二者并存可 6 宫格两行或收起为 ⋮）；③在读/最新/共N章 三行强调排版（复用 `state.chapters` 与 `readRecord` 数据）；④右下浮动胶囊阅读钮替代底部双按钮（浮动钮样式复用设置主页 FAB 规范）。
- **风险**：中（详情页入口多，注意与批量态、阅读记录跳转不回退）。
- **估算**：2 天。**建议**：独立批次「详情页对齐」。

## C. 低优增强（建议合成一个"体验增强批"，按子项开关灰度）

| 项 | 基准（可移植实现） | 方案要点 | 估算 |
|---|---|---|---|
| C1 书源管理复选框批量+状态点+类型注记 | 重构版 `features/sources/sources_page.dart` | 行首加 `Checkbox`（批量模式与现有底部条联动）；行尾状态绿点（可用/失效，取源可用性字段）；源名后类型注记（文本/音频/视频/图片） | 1 天 |
| C2 字典规则管理列表 | 重构版 `features/my/dict_rule_page.dart` | 我方字典规则直达查询页 → 顶部补「规则」入口，列表行=词典源（百度汉语/海词英文形态）+开关+编辑+删除+FAB；**前置**：核实词典源数据来源（`book_api` 无 dictRule 接口 → 若需 FFI 新接口，先契约冻结） | 1.5 天（含契约） |
| C3 字体 Tt 行内面板（正文字体/正文字距/标题字体 + 斜体/字重/简繁） | 原版 `ui/book/read/config/ReadStyleDialog.kt` + `ui/font/FontSelectDialog.kt` | 阅读界面弹层新增「字体」页签：正文字体（跳字体页）、字距滑条（已有）、标题字体/字距（`PageChrome` 已有 titleSize 可扩展）、斜体开关（新增 TextStyle.fontStyle 透传，测量同源已支持） | 1.5 天 |
| C4 全文搜索「仅本书」开关 | 重构版 `features/reader/search_content_page.dart` | `search_content_screen.dart` 顶栏加 `FilterChip('仅本书')`，关闭时走多书搜索范围（复用 `AppRoutes.search` 能力或后端范围参数） | 0.5 天 |
| C5 阅读记录按天分组+成就卡 | 重构版 `features/my/read_record_page.dart` | 现有每日时长数据（`readRecordDailyList`）已在 → 顶部成就卡（已读 N 本/总时长）+ 今天/昨天分组折叠，热力图保留 | 1 天 |
| C6 设置·外观预览模型 | 重构版 `features/settings/theme_config_page.dart` | 主题设置页顶部加手机预览 mock（底色/文字色/强调色实时联动） | 0.5 天 |
| C7 备份「测试配置」行 | 重构版 `features/my/webdav_config_dialog.dart` | WebDAV 页加「测试配置」行：对服务器地址做一次 Dart 侧 PROPFIND/HEAD 探测并回显结果（纯 Dart，无 FFI） | 0.5 天 |
| C8 发现源二级页 3 列 chips | 同 A4 | 与 A4 合并实施 | — |
| C9 书源编辑器帮助体系 | 重构版 `features/sources/source_editor_page.dart`、`rule_sub_page.dart`、`rule_complete.dart` | 编辑器顶部 ? 入口弹「规则语法帮助」弹层（阅读3.0规则说明/@规则语法/jsLib 链接，内容静态） | 0.5 天 |
| C10 自动翻页运行时面板 | 重构版 `features/reader/auto_read_panel.dart` | 菜单「自动翻页」点击后浮出运行时面板（速度 stepper+停止+设置），与现有配置卡并存（参考版语义） | 0.5 天 |

合计约 **8.5 天**；建议拆两批（C1-C5 / C6-C10），每批独立提交。

## D. 取证尾巴（非开发，补采后归档）

| 项 | 方法 |
|---|---|
| 发现分类书单页 / 分组管理页 / 关于页（参考侧） | 重启模拟器后按《差异清单·续采驱动配方》逐屏补采（先 force-stop 我方 App，每步落点验证） |
| 参考版首页模块管理「新建自定义集」/有模块列表态 | 依赖 kazusa 侧数据构造 |
| 书源编辑器深页 / 朗读深页 | 低频，随批次顺带 |
| RSS 源二级页（参考侧） | 参考版订阅页无源，不可达——维持登记 |

## E. 搁置项：首页模块管理（用户裁决暂不实施）

- **现状**：参考版首页齿轮→「首页模块管理」：新建自定义集 / 浏览书源模块（按源分卡，显示「N 个模块」）。
- **性质**：参考版特有深功能，原版 legado 无对应（原版首页=书架），**实施前需用户明确授权**（红线口径）。
- **若未来解禁的建议路径**：①数据模型=`自定义集(名称/排序/包含的模块列表)` + `模块(源URL/入口标题/图标/参数)`，Rust 侧新增两张表与 CRUD FFI（**契约先行**：`docs/API_CONTRACT.md` 增补 `homeModuleList/Upsert/Delete`）；②UI=首页齿轮入口→管理页（列表+新建表单+源模块浏览页）；③联动=首页按集渲染模块卡（点击跳发现源对应入口）。
- **估算**：**3~5 天**（含 Rust 轨契约与实现），建议独立立项、不并入 UI 批次。

## F. 建议排期

| 批次 | 内容 | 前置 | 估算 |
|---|---|---|---|
| 批 A（核实前置） | A1 搜索三钮语义、A2/A3 原版弹窗归属核实（只读源码，产出结论） | 无 | 0.5 天 |
| 批 B（详情页对齐） | B1 | 批 A 结论 | 2 天 |
| 批 C（体验增强 I） | C1/C2/C3/C4/C5 | C2 契约冻结 | 5.5 天 |
| 批 D（体验增强 II） | C6/C7/C9/C10 + A4 发现页 | — | 2.5 天 |
| 批 E（换源外壳） | A2（含 R1 E2E 回归） | 批 A 结论 | 1.5 天 |
| 取证尾巴 | D 表 | 模拟器稳定 | 0.5 天 |
| 搁置解禁 | E（独立立项） | **用户授权** | 3~5 天 |
