# UI 全量同步重构计划（对齐参考仓剩余差异）

> 版本：v1.0 ｜ 日期：2026-09-05 ｜ 编写：Qoder UI
> 目标：全量拉齐 HapeLee/legado-with-MD3（main @ 9ce52559 基线）剩余 UI 差异。
> 用户已定：四域全做（**布局优先**）｜ 玻璃=实色版+开关预留（BackdropFilter 实现但默认关）｜ 字阶拉齐 miuix ｜ 全量一次交付验收（实现分批 commit 便于 LIFO 回滚）。

## 一、执行顺序（布局优先）

B0 地基 → **B2 顶栏布局** → **B3 底栏布局** → **B4 详情布局** → **B5 阅读菜单布局** → B1 密度与字阶 → B6 主题开关族 → B7 扫尾 → 统一验收。

## 二、页面覆盖矩阵（81 文件穷举，无漏网）

- **A 层 全局组件传导（改一处全站生效）**：`LegadoAppBar`（58 处引用，search/source/book_info 经 part 间接使用）——B2 顶栏改动全站自动获得；全局字阶（B1）全屏生效；`dialogTheme`（B7）全部对话框自动；转场 builder（crossfade 已达标）。
- **B 层 宿主与专项（逐屏点名）**：B2 专项=5 个 tab 根页（书架大标题+Dynamic 搜索行/设置枢纽/发现/订阅/我的）；B3=home_screen（底栏/悬浮/Rail 宿主）；B4=book_info(3 part)+edit_book_info+change_cover；B5=reader_screen+reader_config_panel(3 part)+reader_comic+reader widgets 三件；B1=book_list_item/book_grid_item/explore_book_list 共享行组件；B7 FastScroll 15 屏（目录/词典/替换规则/TXT规则/发现/书签/RSS源/高亮标签/阅读记录/阅读选书/搜书内文/书源/书架管理/缓存管理/TXT预览）。
- **C 层 明确不动（登记）**：welcome 启动页；video/audio（沉浸域 P3 已做顶栏动作行）；漫画电子纸/滤镜引擎本体；cupertino 体系；底栏皮肤图标消费逻辑（B3 只换容器形态）。
- 自建顶栏核对结论：search（part 内 LegadoAppBar+SearchBar ✓）、settings（LegadoLargeTitleScroll ✓ 色插值覆盖）、source_screen（part 内 LegadoAppBar ✓）；无共享顶栏者仅阅读器三件与对话框/启动页。

## 三、已核实关键参数（参考仓库源，navigation3 1.1.7 + 屏幕源码）

- 顶栏按钮 5 档：plain 40dp/图标24；tonal/outlined/glass/liquidGlass 36dp/图标20（默认 tonal）；outlined 1dp outlineVariant 描边；间距 plain 4dp/其余 8dp；mergeTopBarActions 并入 Stadium 胶囊+1dp 分隔线（onSurfaceVariant α0.15）。
- 顶栏色插值：Color.lerp(container, scrolled, collapsedFraction)；Dynamic 搜索行=SizeTransition(expandVertically)+fadeIn。
- 底栏：默认 ShortNavigationBar+label 三档（auto=仅选中/labeled=常显/unlabeled=纯图标）；bottomBarOpacity 0-100；悬浮底栏默认关：64dp 高 Stadium 胶囊、内边距 4、margin 16 水平/12+safeArea、按压 scale lerp(1,1+16/w)、图标 1→1.2；Rail=tabletInterface 三档（auto/always/landscape/off）+sw≥600。
- 详情页：取色 128px 采样→quantize64→Score（fallback 0xFF4285F4）→ ColorScheme lerp 400ms FastOutSlowIn（bookInfoFollowCoverColor 默认开）；折叠顶栏 collapsedFraction≤0.001 全透明；背景三档 off/off_for_default/on：480dp 封面+blur24+seedOverlay lerp(secondaryContainer→seed,0.42) α0.34+垂直渐变 stops 0/0.2/0.4/0.6/0.8/1；封面 112dp；ExtendedFAB 开始阅读。
- 阅读菜单：圆角 32（readMenuBottomCornerRadius）；进=fadeIn180+scaleIn0.88@220 / 出=fadeOut140+scaleOut0.88@180；标题胶囊 Stadium 16/4（readMenuTopBarTitleCapsule）；玻璃按钮双档 48/40（内 40 图标 20，选中描边 1.5dp secondary）；搜索 pill 高 40 r16 padding12 统计区 0.55 权重+1×8dp 竖分隔线；朗读胶囊 16↔48 圆角 morph+尺寸 16×8↔48×28、surfaceContainerHigh α0.94、内容切换 200/150ms scale0.9、进度环 strokeWidth2、位置拖拽持久化。
- FastScroll：idle 36×4 outlineVariant@0.8 → active 48×12 primary 形变 250ms、保持 3s 淡出 250ms。
- 字阶映射：displayLarge32/headlineMedium24/headlineSmall20/titleLarge18/titleMedium16/titleSmall14B/bodyLarge17/bodyMedium16/bodySmall12(钉)/labelLarge14(钉)/labelMedium13/labelSmall11，每槽 emphasized=+Medium。

## 四、批次内容

- **B0 地基**：palette_generator+dynamic_color 依赖；主题透存 key 全集登记 design_system.md（getConfig/setConfig 透存，Rust 不解释，无 FFI 契约变更）。
- **B2 顶栏布局**：TopBarButton 5 档+merge 胶囊+collapsedFraction 色插值+Dynamic 搜索行+4 开关（topBarButtonStyle/mergeTopBarActions/useFlexibleTopAppBar/topBarOpacity）。
- **B3 底栏布局**：label 三档+bottomBarOpacity+悬浮 64dp 胶囊+Rail 简版（expand 持久化不做，登记差异）+5 开关（showBottomView/useFloatingBottomBar/bottomBarOpacity/labelVisibilityMode/tabletInterface）。
- **B4 详情布局**：折叠顶栏+信息架构（封面 112dp/ActionCard 16/8+Summary/Intro 分区）+ExtendedFAB+取色换肤+背景三档（Crossfade 800ms）。
- **B5 阅读菜单布局**：r32 容器+scale0.88 动画统一封装+标题胶囊+搜索 pill（替换 mini FAB，销记 reader_screen.dart:489 登记）+朗读胶囊 morph；readMenuBlurMode 落 key（本轮仅 None 生效）。
- **B1 密度与字阶**：书架列表行 vertical12+horizontal8；字阶表全局生效+硬编码字号收敛；渲染矩阵断言同步。
- **B6 主题开关族**：enableBlur+topBar/bottomBar Radius/Alpha/Lens（关时灰显）；圆角覆写 overrideBaseCardCornerRadius+baseCardCornerRadius 滑杆（生效 _cardRadius/_controlRadius/_extraLargeRadius 链）；边框覆写；enableItemDivider+width/length/color（接 SettingItemDivider/PillDivider）；containerOpacity；分组圆角开关；跟随壁纸接 dynamic_color 真实生效（兼容问题则登记延后）。
- **B7 扫尾**：对话框按钮右对齐+minWidth88+间距12；登录 modalOverlay；FastScroll 15 屏+形态升级；animateItem/animateContentSize 高频点；设置行 Semantics 最小集；source_debug Colors.white 清零；渲染矩阵补页（+详情/阅读）。

## 五、门禁

每批 analyze 0+test 全过+断言同步+版本递增+CHANGELOG/updateLog 双同步+独立 commit；完成统一冒烟（5556 -CheckUI）+渲染矩阵+双包对比截图+5558 用户验收；progress/design_system/台账同步。

## 六、风险登记

enableBlur 默认关（低端机掉帧保护）；字阶全局变更以矩阵+对比度测试兜底；Rail 简版差异；dynamic_color 兼容问题则延后；readMenuBlurMode 仅 None 生效；不改域：调色板数值/Rust FFI/正文排版引擎/cupertino/响应式双栏既有实现。

---

## 七、实施状态（2026-09-05 当日交付）

| 批次 | 提交 | 版本 | 内容 |
|---|---|---|---|
| B0+B2 顶栏 | `c47a1e6383` | 2.0.168+169 | 5 档按钮+merge 胶囊+Dynamic 搜索行+布局开关族地基（uiSettingsListenable） |
| B3 底栏 | `5545a4abac` | 2.0.169+170 | label 三档+透明度+悬浮 64dp 胶囊+Rail 简版+五开关 |
| B4 详情 | `f6abc28489` | 2.0.170+171 | 取色换肤 400ms+折叠顶栏+背景三档+ExtendedFAB |
| B5 阅读菜单 | `5970caaebc` | 2.0.171+172 | scale0.88 动画+搜索 pill+标题胶囊+r32 停靠 |
| B1 字阶密度 | `22e6cbcf67` | 2.0.172+173 | miuix 字阶 15 槽+书架行 vertical12 |
| B6/B7 精简版 | `998488ee15` | 2.0.173+174 | 详情与圆角开关组+圆角覆写（卡片档）+对话框按钮规范 |

门禁：每批 analyze 0+test 全过（最终 1336）。冒烟与双包对比验收见进度文档回填。

### 剩余登记项（B6/B7 削减部分，另行排期）

- blur 家族接线（enableBlur+BackdropFilter 于顶/底栏/阅读菜单/详情背景；实色版已按参考仓 noBlur 回退就位）
- dynamic_color 接线（跟随壁纸取色真实生效——需与调色板/自定义四色并存模型整合，防破坏 B0 口径）
- 分隔线开关（enableItemDivider 接 SettingItemDivider/PillDivider）、卡片边框覆写、containerOpacity、分组圆角开关
- 登录 modalOverlay、FastScroll 全站 15 屏接入（idle 36×4→active 48×12 形态升级）、animateItem/animateContentSize 三件套、设置行 Semantics、渲染矩阵补页
- 阅读菜单退出双向动画（fadeOut140+scaleOut0.88@180）、朗读胶囊 16↔48 morph、readMenuBlurMode key
- Rail expand 持久化（简版已交付）

---

编写者：Qoder UI ｜ 2026-09-05
