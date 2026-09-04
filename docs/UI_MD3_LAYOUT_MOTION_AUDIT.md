# 布局与动效对齐审计（HapeLee 90–99% 照搬基线）

> 版本：v1.0 ｜ 日期：2026-09-04 ｜ 编写：Qoder
> 目标：https://github.com/HapeLee/legado-with-MD3（HEAD 0ce6805，M3 分支）
> 依据：三路 Explore 只读深挖（弹层按钮 / 顶栏导航设置行 / 动效字体阅读器）+ Rust 缺口 + 遗漏面 + PS7 回滚排查
> 用户决策：90–99% 照搬布局（特有功能可调）/ M3 标准转场 / 统一 M3 加载 / 先布局后动效 / 分组卡圆角 16dp / 设置拆扁平 / R3 做（0→auto）/ R4 新增 FFI

---

## 一、全局标尺

| 项 | HapeLee（M3） | 本地现状 | 动作 |
|---|---|---|---|
| 页面水平边距 | 16dp | 各屏 18/16/12 不一 | 统一 16 |
| 书架内容边距 | top8 + horizontal4 | 非 token | 对齐 |
| 网格间距 | grid 8dp / list 0dp | 非 token | 对齐 |
| 卡内四档 | 16/12/8/4 | 不一 | 对齐 |
| 列表行 | vertical12 + horizontal8 | 不一 | 对齐 |
| 分组卡圆角 | 16dp（SplicedColumnGroup，可配/可关） | cardTheme 20dp | **16dp（已确认）** |
| 封面 | 宽 84 aspect5/7 圆角 4dp | 未定宽/圆角 | 对齐 |
| 搜索框 | 圆角 32dp + bottom4dp，surfaceContainerLow | 48高/24圆角/Highest | 对齐 32dp + Low |
| 详情避让 | 底 88dp（FAB）+ 底部 120dp | 无 | 对齐 |
| 转场 | slide480+fade360 / pop scale0.8 / 阅读 fade600 / 详情条件 fade300 | 零 PageRouteBuilder | PageTransitionsTheme 全站 |
| Hero | `book-cover:$bookUrl` + sharedBounds 圆角过渡 | 裸 Hero 仅书架↔详情，tag `cover:bookUrl` | tag 统一 + flightShuttle |
| 骨架屏 | shimmer 1200ms + Highest→High + 圆角 8/封面 16 | 无 | 新增 |
| 下拉刷新 | PullToRefreshBox TopCenter | 旧 spinner | M3 化 |

---

## 二、组件主题未同步项（L1 输入，app_theme.dart）

| 组件 | HapeLee | 本地 | 动作 |
|---|---|---|---|
| Dialog 容器 | surfaceContainer | surfaceContainerHigh | 改 |
| Sheet 背景/抓手 | surfaceContainer + 抓手 onSurfaceVariant | surfaceContainerLow + showDragHandle=false | 改背景 + 开抓手 |
| Menu 容器/elev | surfaceContainerLow + elev4 | surfaceContainer + elev3 | 改 |
| MenuItem 行规 | small 圆角 + surface + 48 高 + 120 宽 + 选中 primary | 无 menuTheme | 新增 |
| Tooltip | surfaceContainerLow/onSurface | inverseSurface | 改 |
| FAB 前景 | primary | onPrimaryContainer | 改（最大色差） |
| Outlined 描边 | outline | outlineVariant | 改 |
| 按钮高 | 40dp | 44dp | 改 |
| Card | 4/8/12/16dp 多规格 | 一刀切 20dp | 新增 SettingCard/TextCard/OptionCard/CardTabRow |
| chip/switch/checkbox/radio/slider/iconButton/searchBar | M3 默认 | 主题全缺 | 新增 7 主题 |
| TextField | 4dp 上圆角 + 底线聚焦 | 12dp 全圆角 + 1.5 全框 | **维持现状，登记形态差异** |
| Divider | 2dp 20% 胶囊 outlineVariant60% | 1px 全宽 | 新增 PillDivider + SettingItemDivider 开关（默认关） |
| 对话框按钮 | 右对齐 + min88 + 间距 12 | 全局 64+24 | dialog 层复刻 |

---

## 三、顶栏导航设置行未同步项（L2/L3 输入）

- 顶栏：36/40dp 容器规格 + 5 档 style + collapsedFraction 色插值（surface→surfaceContainer）+ 透明变体 + Dynamic 搜索行动画；liquid 合并胶囊不做。
- 底栏：ShortNavigationBar 形态差异登记（本地标准 NavigationBar 保留）；指示器 alpha 0.72→本地不透明登记差异；三档 label、悬浮底栏、Rail 延后（接口预留）。
- 设置行：去 32dp primaryContainer 图标方块改裸 Icon（onSurfaceVariant）；值文本 primary-labelMediumEmphasized；M3 补 Chevron；分隔线开关默认关 80% pill；分组圆角 16。
- Tab：edge0/min0/无分割线/labelLargeEmphasized；CardTabRow 新增。
- 搜索框：32dp + surfaceContainerLow + autofocus + 提交清焦点藏键盘。
- 主题页开关（blur 家族/圆角边框覆写/分隔线/顶栏按钮/悬浮底栏/背景图/跟随封面色）：本地主题页缺整套，L3 按需补开关 UI（值走 getConfig/setConfig 透存，Rust 不解释）。

---

## 四、动效加载未同步项（M1/M2 输入）

- 转场数值见一节；登录 modalOverlay；predictiveBack 门控；AnimatedVisibility/animateItem/animateContentSize；FastScroll（48×12dp，primary/idle-outlineVariant0.8，降级 scrollbar 定制）。
- 字体：HapeLee 为 miuix 压缩字阶（display32 起/title18/body17/label13），本地标准 M3——**保持本地，登记差异**。
- 加载：下拉 M3 化；骨架新增；Contained 指示器 + LoadMore 三态 footer（24px）；空态 240 宽 + SmallTonal + isLoading；波浪加载器加 RepaintBoundary。
- 阅读器 chrome：slide+fade 菜单、圆角 morph、搜索 pill、胶囊 180/220-0.88；haze 不做。
- 触感震动：P2（门控偏好）。

---

## 五、Rust 缺口（R 批输入）

| # | 事项 | 动作 |
|---|---|---|
| R3 | `get_theme_mode "0"→light` 丢失 auto | 改映射 `0→auto`（None 仍回退 light）+ 单测，需双轨评审 |
| R4 | `get_read_book_config` 无注入通道 | 新增 `set_read_book_config` void FFI（对齐 set_theme 模式）+ codegen + Dart/Mock |
| R5 | 默认 JSON 仅 7 键 | 契约登记注入键集合（isNightTheme 必需，其余可选透传） |
| R6 | `deleteConfig` 有契约无 FFI | 契约登记空串=删键约定 |
| — | 书架网格/封面宽/themeConfigList/paletteId/背景图/模糊圆角开关 | 仅登记（getConfig/setConfig 透存 + set_theme 不透明透传，Rust 不解释；内存级重启重注时序写进契约） |

---

## 六、遗漏面（批次归属）

- 平板 Rail/双栏/断点错配/横屏：M（Rail 本轮预留接口），验收矩阵补 600/840/1200 宽。
- a11y：设置行 Semantics 最小集（M）；触控 48dp、字体缩放全页覆盖（L 收尾）。
- elink/transparent 穿帮核对：收尾（守护豁免不变）。
- 波浪加载器耗电：M2 顺带 RepaintBoundary。
- 文案国际化缺口：P2 登记不做。
- 渲染矩阵补页：收尾。
- 背景 blur：明确不做。

---

## 七、PS7 回滚预案（专属）

- 唯一执行器 `pwsh.exe -NoProfile -ExecutionPolicy Bypass`；脚本补 `$PSNativeCommandUseErrorActionPreference=$false`、`[Console]::InputEncoding`+`$OutputEncoding=utf8`、`Set-Content -AsByteStream`；BOM 章节降为 PS5.1 兼容备注。
- revert 逆序 LIFO：`a3f2e111e6→c8cc3d824d→0356e8efd4→a58415b94e→8d4554f605→024208d49a→281951dd08`，`--no-commit` 先暂存；shim 不单拎；超 500 行 `git add -p` 按屏拆；FRB 回滚必三连（hash -1221949263）；CI 重跑限定 fork 仓。

---

编写者：Qoder ｜ 2026-09-04
