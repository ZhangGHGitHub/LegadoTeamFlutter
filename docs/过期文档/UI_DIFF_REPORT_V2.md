# Legado Flutter 重构 — 逐屏 UI 差异对比报告（V2）

> 生成时间：2026-07-31 ｜ 性质：取证对比 + 对齐施工清单，不修改应用代码
> 基准文档：docs/baseline_android/ANDROID_UI_BASELINE.md · docs/baseline_flutter/FLUTTER_UI_CAPTURE.md

## 0 两套基准的取证依据

| 项 | 安卓基准 | Flutter 基准 |
|---|---|---|
| 截图目录 | docs/baseline_android/ | docs/baseline_flutter/ |
| 包名 | com.legado.app.release | io.legado.flutter_legado |
| 版本 | versionName=3.26073003（本仓库安卓 release 构建） | 2.0.0（versionCode=2，当前源码 debug 构建） |
| 构建 | Gradle release | flutter build apk --debug + Rust NDK 28.2 x86_64 交叉编译 |
| 取证时间 | 2026-07-31 | 2026-07-31 14:00 |
| 环境 | LDPlayer9 emulator-5556 · Android 9（API28）· 720x1280@320dpi | 同左 |
| 有效截图 | 12 张（含阅读器 5 张） | 10 张（08_reader_text.png 无效，见 §7） |
| 有效性核实 | dumpsys package 确认版本号；更新提示 3.26073102 反证装机版本 | Rust 引擎 content hash 匹配；test_book.txt（548B）导入成功 |

## 1 已知线索的源码核实结论（本轮新增，无需模拟器复验）

以下线索已在当前 Flutter 源码（flutter_legado/lib/）中逐条核实：
1. **底部导航文字标签 —— 已修复**：home_screen.dart L37 使用 NavigationDestinationLabelBehavior.alwaysHide，与安卓「仅图标无文字标签」一致，截图亦证实；旧版「带文字标签」问题在当前构建已不存在。
2. **底部导航第三项命名 —— 仍不一致**：label 硬编码为 RSS（home_screen.dart L107），安卓原版为「订阅」；rss_screen.dart L122 标题「RSS 订阅」需同步改。
3. **主题色 —— 不一致根因确认**：app.dart L53 使用 ColorScheme.fromSeed(seedColor: Color(0xFF455A64))（蓝灰）+ useMaterial3: true，派生青/浅蓝视觉体系；安卓原版为红色强调（约 #E53935）+ 深棕褐顶栏（约 #6B4F43）。
4. **翻页动画默认值 —— 不一致**：reader_provider.dart L79 默认 PageTurnMode.scroll（上下滚动），安卓默认「覆盖」；且 PageTurnMode 枚举（L11-15）仅 scroll/slide/simulate/none，**缺「覆盖」选项**（flip_mode.dart 的 cover 未被阅读器使用）。
5. **书架长按 —— 不一致**：bookshelf_screen.dart L332/341 onLongPress 调 _showBookMenu（L391，底部弹窗：查看详情/置顶/编辑信息/分组/导出）；安卓原版长按 = **直接打开书籍信息页**，无中间菜单。
6. **发现页命名与定位 —— 不一致**：explore_screen.dart L49 标题「书源」，安卓原版为「发现」（顶栏内嵌「筛选发现源」搜索框 + 筛选图标）。

## 2 逐屏差异明细
### 2.1 书架（空状态）
- 安卓：docs/baseline_android/01_bookshelf.png
- Flutter 空状态：docs/baseline_flutter/01_bookshelf_menu.png 背景（01_bookshelf.png 为有 1 本书状态）

| # | 维度 | 安卓原版 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| 1 | 布局结构 | 顶栏=深棕褐背景+分组标签「全部」（红下划线）+搜索图标+三点菜单；中央空状态文字 | 白色顶栏=「书架」大标题+搜索/列表视图/更多三图标；统计卡片（全部1/在读0）+FAB | P1 |
| 2 | 视觉 | 深棕褐 #6B4F43 顶栏、红色强调；空状态为纯灰字居中 | 白顶栏、蓝灰 M3；统计卡浅蓝底、FAB 浅蓝圆钮 | P1 |
| 3 | 状态反馈 | 「书架还空着，先去搜索书籍或从发现里添加吧！」 | 「书架空空」+「点击下方按钮添加本地书籍」+「添加」按钮 | P2 |
| 4 | 交互 | 添加入口在三点菜单（添加本地/远程书籍/添加网址等） | FAB「+」为显眼入口 | P2 |

### 2.2 书架（有书状态）
- 安卓：docs/baseline_android/01b_bookshelf_with_book.png
- Flutter：docs/baseline_flutter/01_bookshelf.png


| # | 维度 | 安卓原版 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| 1 | 布局结构 | 顶部新增「本地」分组标签（全部/本地）；条目=横卡：封面+书名加粗+作者图标行+最新章节「第1章(1)」+书签图标 | 无分组标签；条目=灰色占位方块+书名+「未读」，缺作者/章节行 | P1 |
| 2 | 视觉 | 封面为实际渲染图（竖排书名文字+花纹）；条目信息密度大 | 灰色占位封面；仅两行信息 | P2 |
| 3 | 交互手势 | 单击=继续阅读；长按=**直接打开书籍信息**（无中间菜单） | 单击=打开书籍；长按=**底部弹窗菜单**（查看详情/置顶/编辑/分组/导出，源码 bookshelf_screen.dart L332/L391） | P1 |


### 2.3 发现页
- 安卓：docs/baseline_android/02_discover.png
- Flutter：docs/baseline_flutter/02_discover.png

| # | 维度 | 安卓原版 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| 1 | 布局结构 | 深棕褐顶栏=内嵌「筛选发现源」搜索框+右侧筛选网格图标；无返回键（Tab 页） | 白顶栏=返回箭头+「书源」标题+刷新图标；下方「搜索书源」搜索框 | P1 |
| 2 | 视觉 | 棕底白字；空状态=纯灰字居中「当前没有发现源！」 | 白底黑字；空状态=灰图标+「暂无书源」+「请先导入或添加书源」两行 | P2 |
| 3 | 交互 | 搜索框筛选发现源；右侧为筛选（田形网格）图标 | 刷新图标；搜索框「搜索书源」 | P2 |
| 4 | 命名定位 | 页名「发现」 | 标题「书源」（explore_screen.dart L49），定位偏书源管理 | P1 |


### 2.4 RSS 订阅
- 安卓：docs/baseline_android/03_rss.png（含 5 个订阅源，数据态）
- Flutter：docs/baseline_flutter/03_rss.png（空态）

| # | 维度 | 安卓原版 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| 1 | 布局结构 | 深棕褐顶栏=「订阅」搜索框+历史/收藏/筛选/设置 4 图标；内容=4 列网格卡（方图标+标签） | 白顶栏=返回箭头+「RSS 订阅」标题+刷新图标；空状态图标+两行文字+FAB「添加源」 | P1 |
| 2 | 命名 | 「订阅」 | 「RSS 订阅」（rss_screen.dart L122）；底部导航 label 为 RSS（home_screen.dart L107） | P1 |
| 3 | 交互 | 顶栏 4 个功能入口（历史/收藏/筛选/设置） | 仅刷新+FAB 添加源；缺历史/收藏/筛选入口（rss_favorites_screen.dart 已存在，入口待接） | P2 |
| 4 | 状态反馈 | 数据态：4 列网格淡紫卡片 | 空态：「暂无 RSS 订阅」+「点击右下角按钮添加 RSS 源」 | P2（数据态对比待补） |


### 2.5 我的 / 设置
- 安卓：docs/baseline_android/04_mine.png
- Flutter：docs/baseline_flutter/04_settings.png + 04_settings_scrolled.png

| # | 维度 | 安卓原版 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| 1 | 布局结构 | 深棕褐顶栏「我的」+帮助(?)图标；设置列表（无分组）：书源管理/定时任务/运行定时任务[开关]/TXT目录规则/替换净化/字典规则/主题模式[跟随系统] | 白顶栏返回箭头+「设置」；分组式：外观设置(主题模式/语言/主题配置/字体管理)+阅读设置(默认字体大小18/行距/背景色/阅读统计/朗读引擎)+网络设置(代理) | P1 |
| 2 | 视觉 | 各项=红图标+标题+灰副标题 | 青色分组标题+图标+标题+右侧值 | P1 |
| 3 | 交互定位 | 「我的」=全局设置枢纽，含管理入口（书源管理/定时任务/替换净化等） | 纯设置页，缺管理入口（对应 screen 源码已存在：source_screen/auto_task_screen/replace_rules_screen/txt_toc_rules_screen，入口待接） | P1 |
| 4 | 内容项 | 主题模式[跟随系统]为列表项之一 | 主题模式/语言均跟随系统（一致）；多出阅读统计/朗读引擎/代理设置（安卓原版置于子页） | P2 |


### 2.6 搜索页
- 安卓：docs/baseline_android/07_search.png
- Flutter：docs/baseline_flutter/07_search.png（另有 07_search_input.png / 07_search_no_results.png）

| # | 维度 | 安卓原版 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| 1 | 布局结构 | 深棕褐顶栏=返回+内嵌搜索框「搜索书名、作者」（左放大镜右「>」）+三点菜单 | 白顶栏=返回+搜索框「搜索书名…」+排序图标+蓝色「搜索」按钮 | P1 |
| 2 | 交互 | 「>」/回车=跨源搜索；三点菜单=精准搜索/书源管理/分组或书源/日志 | 独立蓝色「搜索」按钮触发；排序图标 | P2 |
| 3 | 状态反馈 | 默认显示「搜索历史」区域+可删历史标签 | 默认显示大放大镜图标+「搜索书籍」+「输入书名或作者名开始搜索」 | P2 |


### 2.7 本地导入
- 安卓：无独立截图（流程见 ANDROID_UI_BASELINE.md §3：书架三点菜单→添加本地→ImportBookActivity→选文件夹→勾选 txt→「放入书架」）
- Flutter：docs/baseline_flutter/05_local_import.png

| # | 维度 | 安卓原版 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| 1 | 交互 | 入口=书架三点菜单「添加本地」；首次需设公共目录子目录（如 Download） | 入口=书架菜单「添加本地书籍」；格式过滤(.EPUB/.TXT/.MOBI/.PDF)+存储目录卡片(app_flutter/files) | P2 |
| 2 | 视觉 | 导入页基准截图待补 | 浅蓝勾选格式 pill+目录卡片+灰色「未选择书籍」底按钮 | P3（安卓截图待补） |
| 3 | 状态反馈 | 勾选后「放入书架」 | 「未选择书籍」→选中后显数量；结果「1 成功 / 0 失败 / 0 跳过」 | P2 |


### 2.8 书架三点菜单
- 安卓：ANDROID_UI_BASELINE.md §3（11 项）
- Flutter：docs/baseline_flutter/01_bookshelf_menu.png

| # | 维度 | 安卓原版 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| 1 | 布局结构 | 更新目录/添加本地/远程书籍/添加网址/书架管理/缓存导出/分组管理/书架布局/导出书单/导入书单/日志 | 更新全部/添加本地书籍/分组管理/管理书架/书源管理+分隔线+分组单选(不分组/按来源/按分组) | P1 |
| 2 | 交互 | 分组管理为独立入口 | 分组单选混入菜单 | P2 |
| 3 | 命名 | 更新目录/添加本地/书架管理 | 更新全部/添加本地书籍/管理书架 | P2 |

### 2.9 书籍详情页
- 安卓：docs/baseline_android/05_book_detail.png（书架长按直接进入）
- Flutter：**未取证**（模拟器中部触摸映射问题；源码 book_info_screen.dart 存在）

安卓基准记录：模糊封面背景+居中封面+书名+红徽章(201字/548 b)；信息区=作者(空)/来源:test_book.txt+红「换源」/最新:第1章(1)/分组:本地未分组+「设置分组」/目录:第1章(1)+「查看目录」；底栏=「删除书籍」浅粉描边+「阅读」红实心。Flutter 侧对比见 §7 待补项。


### 2.10 阅读器（安卓有完整基准；Flutter 待补）
- 安卓：08_reader_text / 10_reader_menu / 11_reader_settings / 12_reader_appearance / 13_tap_zones.png
- Flutter：docs/baseline_flutter/08_reader_text.png 为**无效截图**（实际内容是书架副本）

安卓基准要点（摘自 ANDROID_UI_BASELINE.md §2.8-2.12）：
- 正文：沉浸式无顶/底栏；章首加粗大标题；两端对齐+首行缩进+段间留白；微信读书绿底+黑字；底细进度条=左书名右「1/2 50.0%」
- 菜单（点中央唤起）：顶浮层(返回+书名+TXT目录规则/设置编码/菜单)+章节行+左侧竖向亮度滑条+底面板(全文搜索/自动翻页/替换净化/深色模式；上一章+进度滑条+下一章；目录/朗读/界面/设置)
- 界面面板：chips(中/粗/细·字体·缩进·简/繁·边距·信息)+滑条(字号24·字距0.0·行距0.0·段距0.6，拖动实时)+翻页动画 覆盖(选中)/滑动/仿真/滚动/无动画+背景色环(微信读书绿选中)+「共用布局」开关
- 设置面板：屏幕方向跟随系统/超时默认/隐藏状态栏(关)/隐藏导航栏(关)/扩展到刘海(开)/填充刘海区域(关)
- 点击区域：3x3 网格默认 中央=菜单（首启浮层，一次性）

Flutter 侧已确认的源码级差异（无需进模拟器）：

| # | 差异 | 证据 | 优先级 |
|---|---|---|---|
| 1 | 翻页默认 scroll（安卓为覆盖）；PageTurnMode 枚举**缺 cover 选项** | reader_provider.dart L11-15、L79；reader_screen.dart L936 附近 ChoiceChip 无覆盖 | P1 |
| 2 | 长按书架=弹窗菜单，非直接开书籍信息 | bookshelf_screen.dart L332/L341/L391 | P1 |
| 3 | 其余面板项（亮度滑条/微信读书绿默认底/点击区域浮层等）源码存在(reader_config_panel.dart)，实屏对比待补 | — | 待补 |


## 3 全局视觉规范差异

| # | 项 | 安卓原版 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| 1 | 强调色 | 红 约 #E53935（选中/填充/徽章/按钮） | 蓝灰 seed 0xFF455A64 派生青/浅蓝（app.dart L53） | P1 |
| 2 | 顶栏 | 统一深棕褐 约 #6B4F43 底+白图标+内嵌搜索框 | 白底+黑字+返回箭头标题式（M3 AppBar） | P1 |
| 3 | 底导航选中态 | 红色填充图标 | 浅蓝圆形指示器（secondaryContainer） | P1 |
| 4 | 内容背景 | 浅灰白 约 #F2F2F2 | 浅灰白（接近） | P3 |
| 5 | 字号规范 | 顶栏标题 18-20sp/列表 16sp/次灰 13-14sp；卡边距 12-16dp 圆角 8-12dp | M3 默认字阶；卡圆角 12dp（app.dart）；精确值待测 | P2 |
| 6 | 空状态范式 | 纯居中灰字 | 灰图标+粗标题+灰副标题两行式 | P2 |


## 4 动画与过渡（基于基准文档观察记录）

| # | 项 | 安卓原版 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| 1 | 翻页动画 | 默认「覆盖」；选项：覆盖/滑动/仿真/滚动/无动画 | 默认滚动；选项：滚动/滑动/仿真/无动画（缺覆盖）——源码确认 | P1 |
| 2 | 导航切换 | 红色选中即时切换 | IndexedStack 即时切换（home_screen.dart），行为接近 | P3 |
| 3 | 控制菜单/面板 | 底部上滑浮层 | showModalBottomSheet 底部弹窗（长按菜单已确认）；阅读器菜单实屏待验 | 待补 |
| 4 | 阅读器首启 | 「点击区域设置」3x3 浮层（一次性） | 源码是否实现待查 | 待补 |

## 5 差异汇总表（界面 × 优先级）

| 界面 | P1 | P2 | P3 | 待补 |
|---|---|---|---|---|
| 书架（空） | 2 | 2 | 0 | 0 |
| 书架（有书） | 2 | 1 | 0 | 0 |
| 发现页 | 2 | 2 | 0 | 0 |
| RSS 订阅 | 2 | 2 | 0 | 1（数据态） |
| 我的/设置 | 3 | 1 | 0 | 0 |
| 搜索页 | 1 | 2 | 0 | 0 |
| 本地导入 | 0 | 2 | 1 | 0 |
| 书架菜单 | 1 | 2 | 0 | 0 |
| 书籍详情 | — | — | — | 全部（未取证） |
| 阅读器 | 2（源码级） | 0 | 0 | 全部（实屏） |
| 全局视觉 | 3 | 2 | 1 | 0 |
| 动画过渡 | 1 | 0 | 1 | 2 |
| **合计** | **19** | **16** | **2** | **3+** |


## 6 P1 差异施工清单（UI 对齐工单）

> 共 19 项，按施工便利度排序：主题层（一改全改，ROI 最高）→ 组件层 → 页面层 → 待实屏验证项。
> 「相关文件」为据当前源码结构推断的施工入口。

### 主题层（影响全部页面）
1. **强调色改红**：app.dart _buildLightTheme() 的 seedColor 0xFF455A64 → 红色系（约 0xFFE53935），或手工 ColorScheme 精确复刻安卓红（徽章/按钮/选中）。文件：flutter_legado/lib/app.dart
2. **顶栏改深棕褐**：AppBarTheme 改为深棕褐（约 #6B4F43）底+白图标/白文字，替换当前白底黑字标题式。文件：flutter_legado/lib/app.dart（appBarTheme）
3. **底导航选中态改红**：navigationBarTheme.indicatorColor 由 secondaryContainer → 红色填充（安卓选中=红色填充图标、无圆形背景）。文件：flutter_legado/lib/app.dart、flutter_legado/lib/src/screens/home_screen.dart

### 组件层
4. **底导航第三项命名**：RSS → 订阅（home_screen.dart L107）；rss_screen.dart 标题 RSS 订阅 → 订阅（L122）
5. **翻页动画**：PageTurnMode 枚举补 cover（覆盖）+ 默认 scroll → cover（reader_provider.dart L11-15、L79）；reader_screen.dart 约 L936 的 ChoiceChip 组补「覆盖」选项
6. **书架长按**：_showBookMenu 弹窗 → 直接 Navigator.push 书籍信息页（bookshelf_screen.dart L332/L341/L391），对齐安卓「长按=直接开书籍信息」

### 页面层
7. **书架顶栏结构**：去「书架」大标题+统计卡片，改分组 Tab（「全部」红下划线+动态分组如「本地」）+搜索图标+三点菜单。文件：flutter_legado/lib/src/screens/bookshelf_screen.dart
8. **书籍条目信息密度**：补作者行、最新章节行（第X章）、书签图标；封面用实际渲染替代灰色占位。文件：bookshelf_screen.dart
9. **发现页重定位**：标题 书源 → 发现，去返回箭头（Tab 页），搜索框改「筛选发现源」，右图标改筛选网格。文件：flutter_legado/lib/src/screens/explore_screen.dart
10. **RSS 顶栏补齐**：去返回箭头，标题 → 订阅，补 历史/收藏/筛选/设置 4 图标（rss_favorites_screen.dart 已存在，接入口）。文件：flutter_legado/lib/src/screens/rss_screen.dart
11. **我的页重定位**：settings_screen.dart 标题 设置 → 我的，去返回箭头，补管理入口（书源管理/定时任务/运行定时任务开关/TXT目录规则/替换净化/字典规则/主题模式），各项=红图标+标题+灰副标题、去分组头；顶栏补帮助(?)图标。对应 screen 已存在：source_screen/auto_task_screen/txt_toc_rules_screen/replace_rules_screen/dict_screen
12. **搜索顶栏样式**：改深棕褐内嵌搜索框+右「>」提交+三点菜单（精准搜索/书源管理/分组或书源/日志），去独立蓝色「搜索」按钮。文件：flutter_legado/lib/src/screens/search_screen.dart
13. **书架三点菜单补齐**：补缺项 远程书籍/添加网址/缓存导出/书架布局/导出书单/导入书单/日志（先核对功能完成度，参源码重构审计）；命名对齐 更新目录/添加本地/书架管理。文件：bookshelf_screen.dart

### 待实屏验证后施工（取证缺口）
14. 书籍详情页整体对比（Flutter 未取证；book_info_screen.dart 存在）
15. 阅读器正文排版（微信读书绿默认底、首行缩进、进度条格式）
16. 阅读器控制菜单结构（亮度滑条、4+3+4 按钮布局）
17. 阅读器界面面板（chips/滑条/色环/共用布局开关）
18. 阅读器设置面板（刘海相关选项）
19. 点击区域 3x3 设置浮层（首启一次性）


## 7 待补项

1. **Flutter 阅读器逐屏对比**（08 正文/10 菜单/11 设置/12 界面/13 点击区域）：本轮因 LDPlayer 中部区域（y≈300-700）adb input tap 映射偏移未取成；按任务指示放弃替代输入（touchscreen swipe/keyevent 等）尝试。**建议真机或触摸校准后补做**。注：docs/baseline_flutter/08_reader_text.png 为无效截图（实际内容是书架副本），应删除或重拍。
2. **书籍详情页**：Flutter 侧未取证（同一触摸问题），P1 第 14 项待实屏验证。
3. **发现页带源状态 / RSS 数据态**：两套基准均无源数据，仅对比空态；4 列网格卡片等布局差异待补。
4. **动画逐帧对比**：翻页动画（覆盖 vs 滚动）、菜单浮层上滑曲线需录屏逐帧比对。
5. **安卓 ImportBookActivity 截图**：本地导入对比 §2.7 缺安卓截图，仅流程记录。
6. **字号精确测量**：安卓 sp/dp 值与 Flutter M3 字阶的精确 pt/间距对比。
7. **搜索历史功能**：安卓默认显「搜索历史」区，Flutter 搜索历史实现状态待源码核实。
8. **在线书差异**：两套基准均仅本地书（test_book.txt），在线书源徽章等差异未覆盖。

## 8 结论

- 本轮共确认 **19 项 P1 / 16 项 P2 / 2 项 P3** 差异，覆盖 8 个可对比界面 + 全局规范 + 动画维度。
- **视觉不一致的核心根因在主题层**（seedColor 0xFF455A64 + M3 白顶栏），改 app.dart 一处即可全局提升一致性，建议作为第一施工优先级。
- **旧版「底部导航带文字标签」问题已修复**（alwaysHide，源码+截图双确认）；残留命名差异（RSS → 订阅）为小范围修改。
- **阅读器是对比缺口最大的区域**：安卓有 5 张完整阅读器基准，Flutter 无有效实屏；源码级已确认 2 项 P1（翻页默认/缺覆盖、长按弹窗）。
- 施工顺序建议：主题层（1-3）→ 组件层（4-6）→ 页面层（7-13）→ 阅读器实屏补齐与施工（14-19）。
