# Legado UI 对比分析报告

**分析日期**: 2026-07-30（v1.0） / 2026-08-01（v1.1 状态更新） / 2026-08-04（v1.3 系统性对齐）  
**分析目标**: 对比 Flutter 重构界面与原版 Android 界面差异  
**分析范围**: 主要界面（书架、阅读器、搜索、RSS、设置、发现）

> **v1.1 状态总览**（2026-08-01 复核）：
> - P1-1 Tab 导航：✅ 已修复（第 4 个 Tab 改为「我的」、标签隐藏、使用原版 SVG 图标 ic_bottom_*）
> - P1-2 阅读器翻页模式：✅ 已修复（覆盖/滑动/仿真/滚动/无动画 5 种，见 PageTurnMode）
> - P1-3 系统亮度：✅ 已修复（SystemBrightness 平台通道 + 阅读器亮度滑杆，-1 跟随系统）
> - P1-4 搜索筛选：✅ 已修复（SearchFilterPanel 分组或书源筛选，对标 menu_search_scope）
> - 新增对齐：书架顶部分组 TabBar（对标 fragment_bookshelf1.xml TabLayout）与 shelf_header（统计文本 + 继续阅读行）
> - 用户反馈 ui1~ui6（书架 FAB/菜单、发现分组按钮、订阅 FAB/搜索框、源管理菜单、状态栏全白）：✅ 全部修复，见 docs/UI_E2E_FINAL_REPORT.md

---

## 一、Tab 导航结构对比

### Android 原版
```xml
<!-- app/src/main/res/menu/main_bnv.xml -->
<menu>
    <item android:id="@+id/menu_bookshelf" android:title="@string/bookshelf" />
    <item android:id="@+id/menu_discovery" android:title="@string/discovery" />
    <item android:id="@+id/menu_rss" android:title="@string/rss" />
    <item android:id="@+id/menu_my_config" android:title="@string/my" />
</menu>
```

**特点**:
- 4 个底部 Tab：书架、发现、RSS、我的
- 使用 BottomNavigationView + ViewPager
- Tab 图标：ic_bottom_books, ic_bottom_explore, ic_bottom_rss_feed, ic_bottom_person
- 无标签文字（labelVisibilityMode="unlabeled"）

### Flutter 重构版
```dart
// flutter_legado/lib/src/screens/home_screen.dart
NavigationBar(
  destinations: [
    NavigationDestination(icon: Icon(Icons.library_books), label: '书架'),
    NavigationDestination(icon: Icon(Icons.explore), label: '发现'),
    NavigationDestination(icon: Icon(Icons.rss_feed), label: 'RSS'),
    NavigationDestination(icon: Icon(Icons.person), label: '设置'),
  ],
)
```

**特点**:
- 4 个底部 Tab：书架、发现、RSS、设置
- 使用 NavigationBar + IndexedStack
- Tab 图标：library_books, explore, rss_feed, person
- 有标签文字

### 差异分析

| 对比项 | Android 原版 | Flutter 重构版 | 差异等级 |
|--------|--------------|----------------|----------|
| Tab 数量 | 4 个 | 4 个 | ✅ 一致 |
| Tab 名称 | 书架/发现/RSS/我的 | 书架/发现/RSS/设置 | ⚠️ 第 4 个 Tab 名称不同 |
| 导航组件 | BottomNavigationView | NavigationBar | ⚠️ 组件不同 |
| 页面切换 | ViewPager | IndexedStack | ⚠️ 实现不同 |
| 标签文字 | 隐藏 | 显示 | ⚠️ 视觉差异 |
| 图标样式 | 自定义 drawable | Material Icons | ⚠️ 图标不同 |

**优先级**: P1（重要差异）

**修复建议**:
1. 将第 4 个 Tab 名称从"设置"改为"我的"
2. 考虑隐藏标签文字（labelVisibilityMode）
3. 使用与 Android 一致的自定义图标

---

## 二、书架界面 (BookshelfScreen) 对比

### Android 原版
**布局文件**: `app/src/main/res/layout/fragment_bookshelf.xml`

**核心组件**:
- SwipeRefreshLayout（下拉刷新）
- RecyclerView（书籍列表）
- FloatingActionButton（添加书籍）
- 支持网格/列表视图切换

**交互特性**:
- 下拉刷新
- 长按多选模式
- 拖拽排序
- 书籍分组显示

### Flutter 重构版
**布局文件**: `flutter_legado/lib/src/screens/bookshelf_screen.dart`

**核心组件**:
- RefreshIndicator（下拉刷新）
- CustomScrollView + SliverGrid/SliverList（书籍列表）
- FloatingActionButton（添加书籍）
- 支持网格/列表视图切换

**交互特性**:
- 下拉刷新
- 长按多选模式
- ReorderableListView（拖拽排序）
- 书籍分组显示

### 差异分析

| 对比项 | Android 原版 | Flutter 重构版 | 差异等级 |
|--------|--------------|----------------|----------|
| 刷新组件 | SwipeRefreshLayout | RefreshIndicator | ⚠️ 组件不同 |
| 列表组件 | RecyclerView | CustomScrollView | ⚠️ 实现不同 |
| 视图切换 | 支持 | 支持 | ✅ 一致 |
| 下拉刷新 | 支持 | 支持 | ✅ 一致 |
| 多选模式 | 支持 | 支持 | ✅ 一致 |
| 拖拽排序 | 支持 | 支持 | ✅ 一致 |
| 书籍分组 | 支持 | 支持 | ✅ 一致 |

**优先级**: P2（次要差异）

**修复建议**:
1. 调整 RefreshIndicator 样式以匹配 SwipeRefreshLayout
2. 优化书籍卡片样式以匹配 Android 版本

---

## 三、阅读器界面 (ReaderScreen) 对比

### Android 原版
**布局文件**: `app/src/main/res/layout/activity_book_read.xml`

**核心组件**:
- ReadView（自定义阅读视图）
- 翻页动画：仿真、滑动、覆盖、无动画
- 设置面板：字体、亮度、背景色、行距
- 段评弹窗：ParagraphCommentDialog
- 目录抽屉：TocDrawer

**交互特性**:
- 多种翻页模式
- 实时字体大小调整
- 亮度调节（系统/手动）
- 背景色切换（日间/夜间模式）
- 段评显示和交互

### Flutter 重构版
**布局文件**: `flutter_legado/lib/src/screens/reader_screen.dart`

**核心组件**:
- PageView（翻页）
- 翻页动画：仿真、滑动、覆盖
- 设置面板：ReaderConfigPanel
- 段评弹窗：ParagraphCommentDialog
- 目录抽屉：TocDrawer

**交互特性**:
- 多种翻页模式
- 实时字体大小调整
- 亮度调节（手动）
- 背景色切换（日间/夜间模式）
- 段评显示和交互

### 差异分析

| 对比项 | Android 原版 | Flutter 重构版 | 差异等级 |
|--------|--------------|----------------|----------|
| 翻页模式 | 4 种（仿真/滑动/覆盖/无） | 3 种（仿真/滑动/覆盖） | ❌ 缺少"无动画"模式 |
| 翻页组件 | ReadView（自定义） | PageView | ⚠️ 实现不同 |
| 设置面板 | 底部弹出 | 底部弹出 | ✅ 一致 |
| 段评弹窗 | ParagraphCommentDialog | ParagraphCommentDialog | ✅ 一致 |
| 目录抽屉 | TocDrawer | TocDrawer | ✅ 一致 |
| 亮度调节 | 系统+手动 | 仅手动 | ⚠️ 缺少系统亮度 |
| 字体调整 | 实时 | 实时 | ✅ 一致 |
| 背景色 | 日间/夜间 | 日间/夜间 | ✅ 一致 |

**优先级**: P1（重要差异）

**修复建议**:
1. 添加"无动画"翻页模式
2. 实现系统亮度调节功能
3. 优化翻页动画效果以匹配 Android 版本

---

## 四、搜索界面 (SearchScreen) 对比

### Android 原版
**布局文件**: `app/src/main/res/layout/activity_book_search.xml`

**核心组件**:
- SearchView（搜索框）
- RecyclerView（搜索结果列表）
- 筛选器：源选择、分类筛选
- 搜索历史记录

**交互特性**:
- 实时搜索建议
- 搜索历史记录
- 多源筛选
- 搜索结果预览

### Flutter 重构版
**布局文件**: `flutter_legado/lib/src/screens/search_screen.dart`

**核心组件**:
- TextField（搜索框）
- ListView（搜索结果列表）
- 筛选器：源选择
- 搜索历史记录

**交互特性**:
- 实时搜索建议
- 搜索历史记录
- 多源筛选
- 搜索结果预览

### 差异分析

| 对比项 | Android 原版 | Flutter 重构版 | 差异等级 |
|--------|--------------|----------------|----------|
| 搜索框 | SearchView | TextField | ⚠️ 组件不同 |
| 搜索结果 | RecyclerView | ListView | ⚠️ 组件不同 |
| 筛选器 | 源选择+分类筛选 | 仅源选择 | ❌ 缺少分类筛选 |
| 搜索历史 | 支持 | 支持 | ✅ 一致 |
| 实时建议 | 支持 | 支持 | ✅ 一致 |
| 多源筛选 | 支持 | 支持 | ✅ 一致 |

**优先级**: P1（重要差异）

**修复建议**:
1. 添加分类筛选功能
2. 优化搜索框样式以匹配 SearchView
3. 优化搜索结果卡片样式

---

## 五、RSS 界面 (RssScreen) 对比

### Android 原版
**布局文件**: `app/src/main/res/layout/fragment_rss.xml`

**核心组件**:
- RecyclerView（RSS 源列表）
- FloatingActionButton（添加源）
- RSS 文章阅读 WebView

**交互特性**:
- RSS 源管理
- 文章列表浏览
- WebView 阅读文章
- 文章收藏

### Flutter 重构版
**布局文件**: `flutter_legado/lib/src/screens/rss_screen.dart`

**核心组件**:
- ListView（RSS 源列表）
- FloatingActionButton（添加源）
- RSS 文章阅读 WebView

**交互特性**:
- RSS 源管理
- 文章列表浏览
- WebView 阅读文章
- 文章收藏

### 差异分析

| 对比项 | Android 原版 | Flutter 重构版 | 差异等级 |
|--------|--------------|----------------|----------|
| 列表组件 | RecyclerView | ListView | ⚠️ 组件不同 |
| 添加源 | FloatingActionButton | FloatingActionButton | ✅ 一致 |
| WebView | 支持 | 支持 | ✅ 一致 |
| 文章收藏 | 支持 | 支持 | ✅ 一致 |

**优先级**: P2（次要差异）

**修复建议**:
1. 优化 RSS 源列表项样式
2. 优化文章列表卡片样式

---

## 六、设置界面 (SettingsScreen) 对比

### Android 原版
**布局文件**: `app/src/main/res/layout/activity_config.xml`

**核心组件**:
- PreferenceFragmentCompat（设置列表）
- 各类设置对话框
- 主题切换
- 备份恢复

**交互特性**:
- 标准 Android 设置界面
- 开关、选择器、输入框
- 主题切换（日间/夜间/跟随系统）
- 备份/恢复功能

### Flutter 重构版
**布局文件**: `flutter_legado/lib/src/screens/settings_screen.dart`

**核心组件**:
- ListView（设置列表）
- 各类设置对话框
- 主题切换
- 备份恢复

**交互特性**:
- 自定义设置界面
- 开关、选择器、输入框
- 主题切换（日间/夜间/跟随系统）
- 备份/恢复功能

### 差异分析

| 对比项 | Android 原版 | Flutter 重构版 | 差异等级 |
|--------|--------------|----------------|----------|
| 设置组件 | PreferenceFragmentCompat | ListView | ⚠️ 组件不同 |
| 对话框 | 标准 Android 对话框 | 自定义对话框 | ⚠️ 样式不同 |
| 主题切换 | 支持 | 支持 | ✅ 一致 |
| 备份恢复 | 支持 | 支持 | ✅ 一致 |
| 设置项 | 完整 | 完整 | ✅ 一致 |

**优先级**: P2（次要差异）

**修复建议**:
1. 优化设置项样式以匹配 Android 标准设置界面
2. 优化对话框样式

---

## 七、发现界面 (ExploreScreen) 对比

### Android 原版
**布局文件**: `app/src/main/res/layout/fragment_explore.xml`

**核心组件**:
- RecyclerView（发现规则列表）
- SearchView（搜索框）
- 分组菜单

**交互特性**:
- 发现规则浏览
- 规则搜索
- 分组筛选
- 规则执行（跳转到源详情）

### Flutter 重构版
**布局文件**: `flutter_legado/lib/src/screens/explore_screen.dart`

**核心组件**:
- ListView（发现规则列表）
- TextField（搜索框）
- 分组菜单

**交互特性**:
- 发现规则浏览
- 规则搜索
- 分组筛选
- 规则执行（跳转到源详情）

### 差异分析

| 对比项 | Android 原版 | Flutter 重构版 | 差异等级 |
|--------|--------------|----------------|----------|
| 列表组件 | RecyclerView | ListView | ⚠️ 组件不同 |
| 搜索框 | SearchView | TextField | ⚠️ 组件不同 |
| 分组菜单 | SubMenu | PopupMenuButton | ⚠️ 组件不同 |
| 规则浏览 | 支持 | 支持 | ✅ 一致 |
| 规则搜索 | 支持 | 支持 | ✅ 一致 |
| 分组筛选 | 支持 | 支持 | ✅ 一致 |

**优先级**: P2（次要差异）

**修复建议**:
1. 优化发现规则列表项样式
2. 优化搜索框样式

---

## 八、差异总结

### 按优先级分类

#### P0 - 关键差异（必须修复）
- 无

#### P1 - 重要差异（应该修复）
1. **Tab 导航**: 第 4 个 Tab 名称不同（"设置" vs "我的"）
2. **阅读器**: 缺少"无动画"翻页模式
3. **阅读器**: 缺少系统亮度调节功能
4. **搜索**: 缺少分类筛选功能

#### P2 - 次要差异（可选修复）
1. **Tab 导航**: 标签文字显示/隐藏差异
2. **Tab 导航**: 图标样式差异（Material Icons vs 自定义 drawable）
3. **书架**: 刷新组件样式差异
4. **阅读器**: 翻页动画效果差异
5. **搜索**: 搜索框样式差异
6. **RSS**: 列表项样式差异
7. **设置**: 设置项样式差异
8. **发现**: 列表项和搜索框样式差异

#### P3 - 微小差异（可忽略）
1. 像素级渲染差异
2. 字体渲染差异
3. 动画时序差异

---

## 九、修复计划

### 第一阶段（P1 差异修复）- 预计 3-5 天

1. **Tab 导航修复**
   - 修改第 4 个 Tab 名称为"我的"
   - 隐藏标签文字
   - 使用自定义图标

2. **阅读器修复**
   - 添加"无动画"翻页模式
   - 实现系统亮度调节功能

3. **搜索界面修复**
   - 添加分类筛选功能

### 第二阶段（P2 差异修复）- 预计 1-2 周

1. **书架界面优化**
   - 调整刷新组件样式
   - 优化书籍卡片样式

2. **阅读器优化**
   - 优化翻页动画效果

3. **搜索界面优化**
   - 优化搜索框样式
   - 优化搜索结果卡片样式

4. **RSS 界面优化**
   - 优化 RSS 源列表项样式
   - 优化文章列表卡片样式

5. **设置界面优化**
   - 优化设置项样式
   - 优化对话框样式

6. **发现界面优化**
   - 优化发现规则列表项样式
   - 优化搜索框样式

---

## 十、风险评估

### 低风险
- Tab 名称修改
- 标签文字隐藏
- 设置项样式调整

### 中风险
- 添加"无动画"翻页模式（需要修改翻页逻辑）
- 实现系统亮度调节（需要平台通道）
- 添加分类筛选功能（需要修改搜索逻辑）

### 高风险
- 翻页动画效果优化（需要深入理解 Android 动画实现）
- 自定义图标替换（需要设计资源）

---

## 十一、下一步建议

1. **立即执行**: 修复 P1 差异（Tab 名称、翻页模式、系统亮度、分类筛选）
2. **短期执行**: 优化 P2 差异（样式调整）
3. **长期执行**: 根据用户反馈持续优化

---

**报告生成时间**: 2026-08-04  
**报告版本**: v1.3  
**下次更新**: 发现新差异时

---

## 十二、v1.1 补充：书架分组 Tab 对齐（2026-08-01）

### 差异背景

原版 `fragment_bookshelf1.xml` 结构：TitleBar（内嵌 `view_tab_layout_min.xml` TabLayout）+ `view_bookshelf_header.xml`（统计 + 继续阅读）+ ViewPager。
`BookshelfFragment1` 在多分组时顶栏展示可滚动分组 Tab（MODE_SCROLLABLE），每个 Tab 对应一个分组的书籍列表；Tab 位置持久化到 `AppConfig.saveTabPosition`。
此前 Flutter 书架仅有「分组展示模式」（页面内分块），缺少原版顶栏分组 Tab 入口。

### 修复内容

| 原版行为 | Flutter 实现 |
|----------|--------------|
| 多分组时 TitleBar 内嵌 TabLayout（MODE_SCROLLABLE） | `BookshelfScreen` 多分组时 AppBar bottom 显示 isScrollable TabBar（TabAlignment.start） |
| 每个 Tab = 一个分组的 BooksFragment | `BookshelfState.currentGroupBooks` 按 groupId 过滤（自定义组用 book.group 位掩码；支持 全部/本地/音频/视频/未分组 特殊组） |
| Tab 位置持久化 AppConfig.saveTabPosition | `SettingsService.get/setBookshelfTabPosition`（SharedPreferences） |
| upGroup 无分组时保证「全部」组存在 | `BookshelfNotifier._loadGroups` 空分组回退单一「全部」组（此时不显示 TabBar） |
| shelf_header 统计文本（N 本书 · M 在读） | `_buildStatsSliver` 单行摘要文本 |
| shelf_header continue_reading 行（书名/章节/百分比/箭头，点击阅读，长按书籍信息） | `_buildRecentReadingSliver` 单行继续阅读行 |

变更文件：`bookshelf_state.dart`（+BookGroupId/currentGroupBooks）、`bookshelf_notifier.dart`（+_loadGroups/selectGroup）、`settings_service.dart`（+Tab 位置持久化）、`bookshelf_screen.dart`（StatefulWidget + TabBar + shelf_header 对齐）。

测试：新增 6 项分组 Tab 单元测试（位掩码过滤/隐藏组过滤/Tab 持久化恢复），书架相关 51 项测试全部通过。

---

## 十三、v1.2 补充：分组 Tab 实机验证与两处缺陷修复（2026-08-01）

模拟器（emulator-5556，720x1280）验证过程中发现并修复两个阻塞问题：

### 1. Rust 分组 DTO 序列化契约不一致（导致分组 Tab 不显示分组名）

- 现象：分组管理页创建的 TestGroup 在书架 TabBar 上不显示（分组名解析为空）。
- 根因：`rust/legado-ffi/src/api/book_group_api.rs` 的 `BookGroupDto` 无 serde rename，
  输出 snake_case（`group_id`/`group_name`）；Dart `BookGroup.fromJson` 期望 camelCase
  （`@JsonKey(name: 'groupId')`），缺字段回落默认值。
- 修复：`BookGroupDto` 增加 `#[serde(rename_all = "camelCase")]`（对齐 `search_books` 等既有 camelCase 契约），
  新增 `test_dto_serializes_camel_case` 回归测试；重建 x86_64 .so 并重新打包 APK。

### 2. TabController 在 build 期间同步 index 失效（导致点击 Tab 无响应）

- 现象：点击分组 Tab 指示器不移动。
- 根因：`_ensureTabController` 在 build 中直接给 `controller.index` 赋值，与 TabBar 内部状态竞争。
- 修复：`bookshelf_screen.dart` 改为 listener 驱动——TabController 变化 → `selectGroup` 持久化；
  状态变化 → postFrameCallback `animateTo` 对齐指示器。

### 实机验证结果

| 验证项 | 结果 |
|--------|------|
| 多分组时顶栏显示「全部」+「TestGroup」双 Tab | ✅（`_group_tab_21_loaded.png`） |
| 点击「全部」Tab 指示器切换 | ✅（`_group_tab_25_crop.png` 裁剪放大确认） |
| Tab 位置持久化（重启后恢复选中项） | ✅（截图 26 重启后仍在「全部」） |
| 空分组显示空态、不崩溃 | ✅ |
| 搜索页溢出菜单 5 项对齐原版 book_search.xml | ✅（精准搜索/显示搜索记录/书源管理/分组或书源/日志） |
| 搜索链路端到端（输入→提交→结果空态提示） | ✅ |

另修复 `rust/scripts/build-android.ps1` 交叉编译环境问题：① `rustup target add @triples` 改为 `$triples`（PS 兼容）；② CC/AR 改用 target 限定变量（`CC_x86_64_linux_android`），避免全局 CC 污染宿主机构建导致 rquickjs-sys 叠加 MSVC CFLAGS 编译失败；③ CFLAGS/CXXFLAGS 置空（不能 Remove-Item，用户级作用域会重新透出）。

---

## 十四、v1.3：系统性对齐重构（2026-08-04）

本轮以 `app/src/main` 原版布局/菜单/交互为基准，对 Flutter 全量页面做了五阶段系统性对齐（仅改 `flutter_legado/lib/src/{screens,widgets,theme,l10n,utils}`、`lib/app.dart`、`test/`，未触碰 bridge/frb/FFI 契约/Rust 源码）。

### 差异清单修复状态

| # | 差异（原计划编号） | 状态 | 实现要点 |
|---|-------------------|------|----------|
| 1 | 主页无左右滑动切页（P0） | ✅ | `home_screen.dart` PageView+PageController 与 NavigationBar 双向同步，保留首次滑入懒加载；实机验证左右滑动切页正常 |
| 2 | 发现/RSS 顶栏结构错误（P0） | ✅ | 搜索框移入 AppBar title 槽位与菜单图标同行、移除标题文字（对标 view_search.xml 胶囊搜索框） |
| 3 | 书架列表项信息密度低（P0） | ✅ | 新建 `BookListItem` 对齐 item_bookshelf_list.xml：66x90 封面 + 书名 16sp + 作者/更新时间行 + 进度行 + 最新章节行 + 2dp 进度条 + 未读角标；缺失字段优雅降级 |
| 4 | 书架网格项结构（P1） | ✅ | `BookGridItem` 重构：右上未读角标 + 封面底部 2dp 进度条 + 书名 2 行居中 12sp |
| 5 | 书架网格列数（P1） | ✅ | 手机 3 列对齐原版默认值，宽屏可增列 |
| 6 | 书架顶栏常驻视图切换按钮（P1） | ✅ | 移除常驻按钮；溢出菜单「书架布局」切换并持久化（本轮验证时发现未持久化，已补 `bookshelf_layout` 键 + 启动恢复） |
| 7 | 未读书籍点击行为（P1） | ✅ | `_openBook`：无进度时进书籍信息页，否则进阅读器 |
| 8 | 底栏双击回顶/返回键两段式（P1） | ✅ | 双击书架回顶/发现收起；返回键先回书架再「再按一次退出程序」（实机截图 05/06 验证） |
| 9 | 我的页缺帮助按钮（P1） | ✅ | AppBar 帮助 IconButton + 帮助对话框（实机截图 04） |
| 10 | 发现页多余 FilterChip 分组行（P1） | ✅ | 移除 body 内分组行，分组仅保留顶栏弹出菜单 |
| 11 | 发现页列表项内嵌编辑/删除图标（P2） | ✅ | 改为「名称+展开箭头」，编辑/删除移入长按弹出菜单 |
| 12 | RSS 项内边距/列数（P2） | ✅ | 手机 4 列（宽屏限 6），项内边距恢复 16dp（窄屏 12dp） |
| 13 | 我的页菜单项文案（P2） | ✅ | 与 pref_main.xml/values-zh 逐项核对对齐 |
| 14 | 分组头/空态/刷新指示器（P2） | ✅ | 逐项核对对齐 |

### 阶段 4/5 二级页面与阅读器

- 搜索页（activity_search.xml）：自动聚焦、历史标签、溢出菜单 5 项对齐。
- 书详页（activity_book_info.xml）：头部封面/书名/作者区与操作按钮排布对齐。
- 书源页（activity_book_source.xml）：顶栏内嵌搜索框 + 调试/分组/排序/添加菜单。
- 书架管理（activity_book_arrange.xml）：多选操作条与批量项对齐。
- 阅读器底栏（view_read_menu.xml）：亮度行（自动亮度切换+滑条，SystemBrightness 平台通道）+「上一章/下一章」文字按钮+进度滑条 + 目录/朗读/界面/设置四按钮；「界面」→ReaderSettingsSheet（对标 ReadStyleDialog），「设置」→ReaderConfigPanel 高级面板（对标 MoreConfigDialog）。
- 书源编辑页签改原版短标签：基本/搜索/发现/详情/目录/正文/段评/调试（对标 source_tab_*）。
- 替换净化页（activity_replace_rule.xml）：顶栏内嵌搜索框+过滤；item 增加编辑图标与 more_vert 菜单（对标 iv_edit/iv_menu_more）。
- 主题/其它/WebDAV/设置枢纽文案与 pref_config_theme/pref_config_other/pref_config_backup 逐项核对匹配。

### 测试与验收结果

| 验证项 | 结果 |
|--------|------|
| `flutter analyze` | 210 项与存量基线持平，本轮修改文件零新增问题 |
| 全量测试 | **1082 项全部通过**（含新增布局持久化/恢复 2 项） |
| 新增测试 | 主页滑动切页/双击回顶/返回键；BookListItem、BookGridItem 结构与角标；书架列数；布局持久化 |
| 实机截图（emulator-5556，720x1280） | `flutter_legado/docs/screenshots/v1_3/`：01 书架网格空态、02 发现（滑动切入）、03 RSS（滑动切入）、04 我的（帮助按钮）、05 返回回书架、06 「再按一次退出程序」、07 书架溢出菜单（含书架布局项）、08 列表布局空态、10 重启恢复；布局切换 `bookshelf_layout` 键往返持久化（false→true）经 SharedPreferences 验证 |

### 本轮验证中发现并修复的问题

1. **FFI content hash 不匹配**：jniLibs 中 .so 过时（Dart 侧 -470414355 vs Rust 侧 -1734057445）。经 `scripts/build-apk.ps1 -Targets "x86_64"` 重新交叉编译（仅重编译现有 Rust 代码，未改源码）后启动正常，总启动耗时 294ms。
2. **书架布局切换未持久化**：`toggleViewMode` 原仅改内存状态；补 `SettingsService.get/setBookshelfLayout`（键 `bookshelf_layout`，默认网格），启动时 `_loadSettings` 恢复；实机验证往返切换写入 + 单测覆盖恢复。

### 残留可接受差异（不影响操作习惯）

| 差异 | 理由 |
|------|------|
| ArcView 弧形头部用圆角近似 | Flutter 无同名控件，视觉近似不影响功能 |
| 书源 JS 徽标不显示 | Book 模型无 hasJs 字段，不改 FFI 契约前提下降级 |
| 阅读器浮动 FAB 组（搜索/自动翻页/替换规则/夜间）未移植 | 低频快捷入口，对应功能在菜单/面板中可达 |
| 夜间模式按钮从底栏移至顶栏 | 入口保留，位置差异 |
| 朗读功能为占位（按钮已就位） | TTS 链路依赖 Rust 侧尚未移植的能力 |
| WebDAV「仅保留最新备份/自动检查新备份」开关未实现 | 低频配置项 |
| 朗读配置项（pref_config_aloud：忽略音频焦点等）未移植 | 依赖朗读链路 |
| TXT 本地导入在实机上失败（Rust 侧，DB 无新增记录） | 存量数据层问题，超出本轮 UI 文件边界（不改 Rust/FFI），已记录待后续排查 |
| RuleSubActivity（规则订阅）未移植 | Rust FFI 无 ruleSub 系列 API，超出 UI 轨文件边界 |
| VerificationCodeActivity（验证码）未移植 | 源登录验证码链路 FFI 未就绪 |
| BottomBarSkin*（底栏皮肤自定义）未移植 | 主题模式已由 theme_config 覆盖，底栏图标集自定义为低频功能 |


## 十三、v2.0 iOS 设计语言全量重构（2026-08-05）

### 目标

用户反馈「重构的 UI 界面还是太差了和原版差距很大」，要求：全界面 UI 列表盘点 + 全量重设计（功能 100% 对等原版）+ Apple/iOS 设计语言 + 补齐缺失页面，不与 Rust 冲突、遵循 UI 版本控制。

### 设计系统基座（theme 三件套重写，API 名向后兼容）

| 文件 | 改进前 | 改进后（iOS HIG） |
|------|--------|--------------------|
| `app_colors.dart` | Material 默认紫/蓝体系 | iOS 调色板：Tint 蓝 #007AFF、分组背景 #F2F2F7、卡片白、Secondary Label 3C3C43@60%、hairline 分隔 3C3C43@29%、系统红/绿/橙/黄/靛/紫/粉/青/棕全套明暗色 |
| `app_typography.dart` | Material 默认字阶 | iOS Dynamic Type：34/28/22/20/17/16/15/13/12/11，行高 1.21/1.47/1.38 |
| `app_theme.dart` | 蓝底白字 AppBar + Material 默认组件 | 浅色导航栏+深色标题+hairline 底边；iOS tab bar（半透明+顶部 hairline+tint 选中）；iOS 绿开关白滑块；填充式搜索框（10 圆角）；12 圆角卡片；13 圆角弹出菜单；按亮度翻转状态栏图标 |
| `ios_widgets.dart`（新增） | 无 | IosGroupedBody/IosSectionHeader/IosSectionFooter/IosGroup（白卡+hairline+左缩进）/IosListTile（30x30 色块图标）/IosGrabber |

### 逐屏改进前后对比

| 屏 | 改进前 | 改进后 |
|----|--------|--------|
| 主框架 | Material 导航栏 onSecondaryContainer 选中色 | NavigationBar tint 蓝选中、labelBehavior alwaysHide |
| 书架 | 封面直角无阴影 | 封面 10 圆角 + 柔和阴影（主屏 App 图标感），分组 TabBar 走 tint |
| 发现 | 全 theme 驱动 | 无需改动（确认 theme 驱动后自动继承 iOS 体系） |
| RSS | 4dp 网格间距、无图标阴影 | 8dp 间距 + 图标阴影 + 占位首字母用 onSurfaceVariant；文章列表分隔线缩进至文字列、缩略图 10 圆角、chevron 返回 |
| 设置/我的 | 卡片分区 + 自绘 section header | iOS grouped inset list（三组 IosGroup + 色块图标 + hairline 分隔），全部回调原样保留 |
| 搜索 | 封面 4 圆角 | 封面 10 圆角、来源徽标 6 圆角胶囊 |
| 书详 | 面板 16 圆角、小按钮 2 圆角、章节搜索框描边式 | sheet 风 20 圆角面板、胶囊小按钮、填充式章节搜索框、底部按钮 12 圆角、封面 10 圆角 |
| 阅读器 | elevation 阴影工具栏 + arrow_back | hairline 边工具栏 + chevron 返回 + 设置 sheet grabber；阅读主题渲染（功能）不动 |
| 书源管理 | 绿点 #43A047 硬编码 | iOS 系统绿；开关自动走 iOS 绿样式 |
| source/rss 搜索框 | 蓝底白字假设（浅色导航栏下不可见） | theme 感知色（onSurface/onSurfaceVariant） |

### 补齐的缺失页面（对照原版 53 Activity 差集）

| 原版页面 | Flutter 实现 | 数据链路 |
|----------|--------------|----------|
| HighlightRuleActivity + HighlightRuleEditDialog | 新增 `highlight_rules_screen.dart`（iOS grouped 列表 + 编辑 sheet：名称/模式/正则/应用标题/范围/颜色预设/预览） | BookApi.highlightRuleList/Save/Delete（Rust highlight_api 已就绪）；阅读器菜单「高亮规则」接入 |
| FileManageActivity | 新增 `file_manage_screen.dart`（路径面包屑 + 筛选框 + .. 上级项 + 目录进入/文件分享打开/长按删除确认 + 两段式返回） | path_provider 沙盒目录 + share_plus；设置页「文件管理」接入 |

其余 Activity 差集结论：TocActivity/ReadRecordActivity/CodeEditActivity 等已由现有屏内功能覆盖；RuleSub/验证码/底栏皮肤因上游 FFI 未就绪列入残留可接受差异。

### 验证

- `flutter analyze`：0 error / 0 warning
- 全量测试：1087/1087 通过（含新增 highlight_rules_test 5 项；阅读器组件测试同步更新 chevron 断言）
- 文件边界：仅触碰 `lib/src/{screens,widgets,theme}`、`routes.dart`、`test/`；未触碰 bridge/frb_generated/Rust 侧，无 Rust 冲突
- UI 版本控制：theme API 名全部向后兼容，后续可按 [UI] 前缀独立提交

### 二级 / 三级页面覆盖核查（2026-08-05 审计）

重构机制分两层：**① theme 基座继承**（app_colors/app_typography/app_theme 重写后，所有使用 theme 令牌的页面自动切换 iOS 视觉：浅色导航栏 + hairline、tint 选中、iOS 绿开关、填充搜索框、12 圆角卡片、Dynamic Type 字阶）；**② 逐屏精修**（对视觉细节超标的页面定点修正）。53 个 screens 全部落在两层之一，无遗漏。

| 层级 | 页面 | 状态 |
|------|------|------|
| 二级 | 设置页 `settings_screen` | ✅ 精修：iOS grouped inset list 三组 + 色块图标 |
| 二级 | 搜索页 `search_screen` | ✅ 精修：封面 10 圆角、来源徽标胶囊 |
| 二级 | 书详情 `book_info_screen` | ✅ 精修：sheet 20 圆角、胶囊按钮、填充搜索框、封面 elevation 8 对标原版 CardView |
| 二级 | 书源管理 `source_screen` | ✅ 精修：iOS 系统绿、theme 感知搜索框 |
| 二级 | RSS 订阅 `rss_screen` / 文章列表 `rss_articles_screen` | ✅ 精修：8dp 间距、图标阴影、chevron 返回、缩略图 10 圆角 |
| 二级 | 书架管理 `bookshelf_manage_screen`、分组 `book_group_screen`、导入 `import_screen`、阅读统计 `reading_stats_screen`、替换规则 `replace_rules_screen`、自动任务 `auto_task_screen`、关联 `association_screen`、发现展示 `explore_show_screen` | ✅ theme 基座继承 |
| 三级 | 书源编辑 `source_edit_screen`、书源调试 `source_debug_screen`、源登录 `source_login_screen` | ✅ theme 基座继承（编辑表单已随 theme 搜索框/开关体系 iOS 化） |
| 三级 | RSS 配置 `rss_config_screen`、RSS 源编辑 `rss_source_edit_screen`、RSS 调试 `rss_source_debug_screen`、收藏 `rss_favorites_screen`、历史 `rss_history_screen`、文章详情 `rss_article_detail_screen` | ✅ theme 基座继承 |
| 三级 | 阅读器 `reader_screen` 及其子页：书签 `bookmark_screen`、内容搜索 `search_content_screen`、字典 `dict_screen`、字体 `font_screen`、高亮规则 `highlight_rules_screen`（新增）、换源 `change_source_screen`、换封面 `change_cover_screen`、编辑书信息 `edit_book_info_screen`、漫画阅读 `comic_reader_screen` / `reader_comic_screen`、音频 `audio_screen`、视频 `video_screen` | ✅ 精修/继承：工具栏 hairline + chevron + grabber；漫画阅读器深色沉浸配色为对标原版的刻意保留 |
| 三级 | 设置子页：其他设置 `other_settings_screen`、缓存 `cache_settings_screen`、WebDAV `webdav_settings_screen`、主题配置 `theme_config_screen`（阅读主题预设色为数据色）、朗读配置 `read_aloud_config_screen`、TXT 目录规则 `txt_toc_rules_screen`、关于 `about_screen`、文件管理 `file_manage_screen`（新增）、二维码 `qrcode_screen` | ✅ theme 基座继承 |
| 特殊 | 欢迎页 `welcome_screen`、浏览器 `browser_screen` | ✅ 继承；browser 内 `arrow_back` 为浏览器语义图标（对标原版 WebBrowser 返回），保留 |

静态扫描证据：screens 目录内无 Material 蓝/紫等硬编码主题色背景、无残留 elevation（唯一 elevation:8 为书详封面卡，对标原版 CardView）；漫画阅读器与阅读主题预设的深色/数据色为刻意保留。



