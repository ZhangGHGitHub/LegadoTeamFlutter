# 未完成项与搁置项开发建议（对齐差异清单 §十 审计结论）

> 编写：Qoder UI ｜ 2026-09-09
>
> **口径**：功能基准=`legado-upstream`（原版 Android 源码，路径 `D:\OH-WorkSpace\LegadoTeam\legado-upstream`）；实现/架构基准=`Projects/legado_flutter`（重构版工程）；视觉基准=参考版 kazusa 实机截图（差异清单内）。
> **红线提醒**：未经授权禁止新增原版不存在功能；FFI/接口变更须先冻结 `docs/API_CONTRACT.md`。

## A. 待语义核实类 → **核实结论（2026-09-11 完成，源码为准）**

| 项 | 核实依据（源码） | 结论与决策 |
|---|---|---|
| A1 搜索顶栏三钮（⚙/定位/筛选） | 原版 `ui/book/search/SearchActivity.kt`；重构版 `features/search/search_page.dart` L545-590 | 原版与重构版**均无三钮**，能力全在 ⋮ 溢出菜单（精准搜索/搜索范围/全部书源/书源管理）；三钮为闭源参考版特有、语义无源可依 → **不实施**（我方已有等价 ⋮ 菜单，原版对齐优先） |
| A2 换源形态 | 原版 `ui/book/changesource/ChangeBookSourceDialog.kt`（`BaseDialogFragment(R.layout.dialog_book_change_source)`），布局含 `refresh_progress_bar`（搜索进度）+ `recycler_view`（源卡）+ `ll_bottom_bar`（dur/top/bottom） | **确认原版即弹层**且与参考版截图形态一致 → **实施为弹层**（保留我方换源变量链逻辑不动），见批 E |
| A3 替换编辑器 | 原版 `ui/replace/edit/ReplaceEditActivity.kt` + `activity_replace_edit.xml` | **确认原版即整页**（规则列表=ReplaceRuleActivity）→ 我方弹窗表单改为**整页编辑器**（字段全覆盖已有），列入编辑器批 |
| A4 发现页（卡片底/顶栏⋮/二级页 3 列 chips） | 原版 `ui/book/explore/ExploreShowActivity.kt` + `ExploreShowAdapter.kt`；重构版 `features/explore/explore_list_page.dart`、`explore_tab_page.dart` | 基准齐备 → 随发现页批实施（批 D） |

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

## F. 排期与实施状态（2026-09-11 更新）

| 批次 | 内容 | 状态 |
|---|---|---|
| 批 A | 源码核实 4 项（结论见上表） | ✅ **已完成**（A1 不实施；A2/A3/A4 决策落地） |
| 批 B | 书籍详情页形态对齐（B1） | 🚧 实施中（full-stack-engineer 子代理） |
| 批 C-I | 体验增强：C5 阅读记录按天视图 | 🚧 实施中（子代理并行） |
| 批 C-II | C1 书源管理复选框批量 / C2 字典规则管理 / C3 字体行内面板 / C4 仅本书开关 | 待派发 |
| 批 D | C6 外观预览 / C9 编辑器帮助（已完成²）/ C10 自动翻页面板 / A4 发现页 / A3 替换编辑器整页 | 待派发 |
| 批 E | A2 换源弹层化（含 R1 E2E 回归） | 待派发 |
| 取证尾巴 | 参考侧截图补采 | 待模拟器稳定 |

注²：C9 编辑器帮助（2.0.224）、C7 备份测试配置行（2.0.225）已于 2026-09-09/10 完成。
