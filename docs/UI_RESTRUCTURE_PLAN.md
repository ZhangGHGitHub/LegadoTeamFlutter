# Legado Flutter UI 重构实施方案

> 角色：A — Flutter UI 负责人
> 职责边界：所有 Dart 代码（页面/组件/状态管理/路由/主题），通过 BookApi 调用 Rust 获取数据，不包含任何业务计算逻辑。

## 零、职责边界定义（刚性约束）

### 0.1 UI 轨允许做的事

| 类别 | 具体内容 |
|------|----------|
| 界面渲染 | Widget 树构建、布局排版、动画、主题样式 |
| 交互响应 | 手势识别、导航跳转、表单输入、拖拽排序的视觉反馈 |
| 状态管理 | Riverpod Notifier 管理 UI 状态（loading/error/data 三态） |
| API 调用编排 | 决定何时调用 BookApi（如预加载时机），但不处理返回数据的业务含义 |
| 展示层变换 | 列表分组显示、视图模式切换（网格/列表）——仅改变呈现形式，不改变数据本身 |
| Mock 维护 | MockBookApi 假数据实现（UI 轨独立开发用） |
| 数据模型 | freezed 模型定义（与 Rust 模型镜像，仅用于序列化/反序列化） |

### 0.2 UI 轨禁止做的事

| 禁止行为 | 正确做法 |
|----------|----------|
| 在 Notifier/Widget 中实现排序算法 | 调用 `BookApi.sortBookSources()` 由 Rust 排序后返回 |
| 在 Dart 侧解析/执行书源规则 | 调用 `BookApi.parseRule()` / `webbookSearch()` |
| 在 Dart 侧做文本净化/替换 | 调用 `BookApi.getChapterContent()`（Rust 已应用规则） |
| 在 Dart 侧做编码转换/格式解析 | 调用 `BookApi.parseTxt()` / `archiveDetectEncoding()` |
| 在 Dart 侧实现搜索匹配/合并逻辑 | 调用 `BookApi.searchBooks()` / `searchMulti()` |
| 修改 `bridge/` 目录、执行 codegen | 报告 Rust 轨处理 |
| 修改 `rust_api.dart` 方法签名 | 走契约变更流程（API_CONTRACT.md 登记） |
| 在 Notifier 中做网络请求重试/超时策略 | Rust 侧网络层负责，UI 只展示错误 |

### 0.3 判断准则

> 如果一个操作改变了数据的「内容」或「顺序」，它属于业务逻辑 → 必须由 Rust 完成。
> 如果一个操作只改变了数据的「呈现形式」（如切换网格/列表、展开/折叠分组），它属于 UI 状态 → 可在 Notifier 中完成。

---

## 一、现状审计摘要

### 1.1 已有资产

| 维度 | 现状 | 评估 |
|------|------|------|
| 页面 | 30+ Screen 已搭建骨架 | 功能覆盖完整，需精调对齐 Android |
| 状态管理 | `provider` + `ChangeNotifier`（14 个 Provider） | **需迁移至 Riverpod**（计划强制要求） |
| 数据模型 | `freezed` + `json_serializable`（Book, BookSource, BookChapter 等） | 已对齐 Rust 模型，保留 |
| API 抽象 | `BookApi` 接口 + `RustApi`(FFI) + `MockBookApi` | 架构正确，保留并增强 |
| 设计系统 | `app_colors.dart` / `app_theme.dart` / `app_typography.dart` | 已对齐 Android M3，保留 |
| 响应式 | `Responsive` 工具类（3 断点） | 基础可用，需扩展桌面端适配 |
| 路由 | 命名路由 `Map<String, WidgetBuilder>` | 可保留，后期可考虑 go_router |
| 组件库 | 12+ 公共 Widget（BookCover, BookGridItem 等） | 需补充和统一 |

### 1.2 核心差距

1. **状态管理不符**：当前用 `provider`，计划要求 `riverpod` + `riverpod_generator`
2. **UI 层混入业务逻辑**：`BookshelfProvider._getGroupKey()` 包含分组规则判断、`reorderBook()` 包含排序计算——需审查哪些是展示层变换（可保留）、哪些应委托 Rust
3. **响应式不足**：仅有网格列数计算，缺少桌面端 NavigationRail/双栏布局
4. **组件标准化不够**：缺少统一的 Loading/Error/Empty 状态组件
5. **阅读器复杂度**：1285 行单文件，需拆分为子组件

---

## 二、技术选型确认

| 用途 | 选型 | 版本约束 | 说明 |
|------|------|----------|------|
| 状态管理 | `flutter_riverpod` + `riverpod_annotation` | ^2.5.0 | 替代 provider |
| 代码生成 | `riverpod_generator` + `build_runner` | ^2.4.0 | Notifier 自动生成 |
| 数据模型 | `freezed` + `json_serializable` | 已有 | 保持不变 |
| FFI 桥接 | `flutter_rust_bridge` | 2.11.1（锁定） | 保持不变 |
| 图片加载 | `cached_network_image` | 已有 | 保持不变 |
| 响应式 | `LayoutBuilder` + 自研断点 | — | 扩展 Responsive 类 |
| 路由 | 保持命名路由 | — | 不引入 go_router（减少变动） |
| 主题 | `Theme.of(context).colorScheme` | — | 遵循 design_system.md |
| 测试 | `flutter_test` + `mocktail` | 已有 | Widget 测试 + Provider 测试 |

### pubspec.yaml 变更

```yaml
# 新增
flutter_riverpod: ^2.5.0
riverpod_annotation: ^2.3.0

# 移除（迁移完成后）
provider: ^6.0.0

# dev_dependencies 新增
riverpod_generator: ^2.4.0
custom_lint: ^0.6.0
riverpod_lint: ^2.3.0
```

---

## 三、架构分层设计

### 3.1 目标目录结构

```
flutter_legado/lib/
├── main.dart                    # 入口：ProviderScope 包裹
├── app.dart                     # MaterialApp 配置
├── src/
│   ├── bridge/                  # [Rust轨] FFI 生成代码（UI轨禁触）
│   ├── models/                  # [共享] freezed 数据模型
│   ├── services/
│   │   ├── book_api.dart        # [共享] 抽象接口
│   │   ├── rust_api.dart        # [Rust轨] FFI 实现
│   │   ├── mock_book_api.dart   # [UI轨] Mock 实现
│   │   └── settings_service.dart
│   ├── providers/               # [UI轨] Riverpod Notifier（重构重点）
│   │   ├── bookshelf/
│   │   │   ├── bookshelf_notifier.dart
│   │   │   └── bookshelf_state.dart
│   │   ├── reader/
│   │   │   ├── reader_notifier.dart
│   │   │   └── reader_state.dart
│   │   ├── explore/
│   │   ├── search/
│   │   ├── source/
│   │   ├── rss/
│   │   ├── settings/
│   │   └── providers.dart       # 统一导出 + BookApi 注入
│   ├── screens/                 # [UI轨] 页面（纯渲染 + 交互）
│   ├── widgets/                 # [UI轨] 可复用组件
│   │   ├── common/              # 通用状态组件
│   │   │   ├── loading_view.dart
│   │   │   ├── error_view.dart
│   │   │   ├── empty_view.dart
│   │   │   └── async_value_widget.dart
│   │   ├── book/                # 书籍相关组件
│   │   ├── reader/              # 阅读器子组件
│   │   └── source/              # 书源相关组件
│   ├── theme/                   # [UI轨] 主题系统
│   ├── utils/                   # [UI轨] 工具
│   │   └── responsive.dart      # 扩展响应式
│   └── l10n/                    # [UI轨] 国际化
```

### 3.2 数据流规约

```
用户交互 → Screen(Widget) → 调用 Notifier 方法
                                  ↓
                          Notifier 内部调用 BookApi
                                  ↓
                     BookApi (RustApi / MockBookApi)
                                  ↓
                          返回纯数据 (Model)
                                  ↓
                     Notifier 更新 State (immutable)
                                  ↓
                     Widget 通过 ref.watch 自动重建
```

**铁律**（对齐职责边界 §0.2）：
- Screen/Widget 中**禁止**直接调用 `BookApi`，必须经 Notifier 中转
- Notifier 中**禁止**包含 UI 控制逻辑（动画、ScrollController、焦点管理属于 Widget 层）
- Notifier 中**禁止**包含业务计算（排序算法、规则解析、文本处理、编码转换）
- Notifier 的唯一职责：调用 BookApi → 接收纯数据 → 更新 immutable State
- 展示层变换（网格/列表切换、分组折叠状态）允许在 Notifier 中管理
- 数据排序/过滤若涉及业务规则，必须调用 BookApi 由 Rust 完成后返回

### 3.3 BookApi 注入方案

```dart
// providers/providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/book_api.dart';
import '../services/rust_api.dart';
import '../services/mock_book_api.dart';

/// BookApi 全局 Provider
/// 启动时根据 --dart-define=USE_MOCK 决定注入哪个实现
final bookApiProvider = Provider<BookApi>((ref) {
  const useMock = bool.fromEnvironment('USE_MOCK', defaultValue: false);
  return useMock ? MockBookApi() : RustApi();
});
```

---

## 四、Riverpod 状态管理迁移方案

### 4.1 迁移策略：逐模块绞杀

不一次性重写，而是按优先级逐模块从 `ChangeNotifier` 迁移到 `Riverpod Notifier`：

| 批次 | 模块 | 原文件 | 新文件 |
|------|------|--------|--------|
| 1 | 书架 | `bookshelf_provider.dart` | `providers/bookshelf/` |
| 2 | 阅读器 | `reader_provider.dart` | `providers/reader/` |
| 3 | 发现页 | `explore_provider.dart` + `explore_show_provider.dart` | `providers/explore/` |
| 4 | 搜索 | `search_provider.dart` | `providers/search/` |
| 5 | 书源管理 | `source_provider.dart` | `providers/source/` |
| 6 | RSS | `rss_provider.dart` | `providers/rss/` |
| 7 | 设置 | `settings_service.dart` 部分 | `providers/settings/` |
| 8 | 其余 | 书签/替换规则/统计等 | 对应子目录 |

### 4.2 Notifier 模板（以书架为例）

Notifier 职责严格限定：调用 BookApi + 管理 UI 状态（loading/error/data）+ 展示层变换。

```dart
// providers/bookshelf/bookshelf_state.dart
part of 'bookshelf_notifier.dart';

@freezed
class BookshelfState with _$BookshelfState {
  const factory BookshelfState({
    @Default([]) List<Book> books,  // Rust 返回的原始数据（已排序）
    @Default(false) bool isLoading,
    String? error,
    @Default(true) bool isGridView,          // 展示层：视图模式
    @Default(GroupMode.none) GroupMode groupMode,  // 展示层：分组显示模式
  }) = _BookshelfState;
}

/// 分组模式 —— 纯展示层概念，仅决定 UI 如何分块显示
/// 不涉及业务规则计算
enum GroupMode { none, bySource, byGroup }
```

```dart
// providers/bookshelf/bookshelf_notifier.dart
import 'package:riverpod_annotation/riverpod_annotation.dart';
part 'bookshelf_notifier.g.dart';
part 'bookshelf_state.dart';

@riverpod
class BookshelfNotifier extends _$BookshelfNotifier {
  @override
  BookshelfState build() {
    _loadBooks();
    return const BookshelfState();
  }

  BookApi get _api => ref.read(bookApiProvider);

  /// 调用 Rust API 获取数据 —— Notifier 不做任何数据处理
  Future<void> _loadBooks() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final books = await _api.getBooks();  // Rust 负责排序/过滤
      state = state.copyWith(books: books, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: mapApiError(e), isLoading: false);
    }
  }

  Future<void> refresh() => _loadBooks();

  /// 删除：调用 Rust API 后同步本地 UI 状态
  /// 注意：这里的 where 过滤是「UI 状态同步」而非「业务逻辑」
  Future<void> removeBook(String bookUrl) async {
    try {
      await _api.deleteBook(bookUrl);  // 业务操作在 Rust
      // 仅同步 UI 列表状态
      state = state.copyWith(
        books: state.books.where((b) => b.bookUrl != bookUrl).toList(),
      );
    } catch (e) {
      state = state.copyWith(error: mapApiError(e));
    }
  }

  /// 以下为纯展示层状态切换，不涉及数据内容变更
  void toggleViewMode() {
    state = state.copyWith(isGridView: !state.isGridView);
  }

  void setGroupMode(GroupMode mode) {
    state = state.copyWith(groupMode: mode);
  }
}
```

**Notifier 边界说明**：
- `_loadBooks()`：只调用 API、存储结果、管理 loading/error —— 合规
- `removeBook()`：调用 API 后从本地列表移除已删项 —— 属于 UI 状态同步，合规
- `toggleViewMode()` / `setGroupMode()`：改变呈现形式，不改变数据 —— 合规
- 若需按书名/作者排序：必须调用 `_api.sortBookSources()` 或新增 API，不可在 Dart 侧 sort

### 4.3 Screen 消费方式

```dart
class BookshelfScreen extends ConsumerWidget {
  const BookshelfScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bookshelfNotifierProvider);

    if (state.isLoading) return const LoadingView();
    if (state.error != null) return ErrorView(message: state.error!);
    if (state.books.isEmpty) return const EmptyView(icon: Icons.library_books);

    return state.isGridView
        ? _buildGrid(context, ref, state)
        : _buildList(context, ref, state);
  }
}
```

### 4.4 过渡期兼容

迁移期间 `provider` 和 `riverpod` 共存：
- `main.dart` 同时包裹 `ProviderScope`（Riverpod）
- 已迁移模块用 `ConsumerWidget`，未迁移模块保持 `Consumer`（provider）
- 全部迁移完成后移除 `provider` 依赖

---

## 五、UI 组件体系设计

### 5.1 通用状态组件（新建）

| 组件 | 职责 | 对齐 Android |
|------|------|-------------|
| `LoadingView` | 居中 CircularProgressIndicator + 可选文字 | 原版加载对话框 |
| `ErrorView` | 错误图标 + 消息 + 重试按钮 | 原版错误提示 |
| `EmptyView` | 空状态图标 + 提示文字 + 可选操作按钮 | 原版空书架提示 |
| `AsyncValueWidget<T>` | 封装 Riverpod AsyncValue 三态切换 | — |
| `PaginatedListView` | 上拉加载更多 + 下拉刷新 | 原版分页列表 |

### 5.2 书籍组件（已有，需增强）

| 组件 | 现状 | 改进 |
|------|------|------|
| `BookCover` | 63 行，基础封面 | 增加加载占位、错误回退、圆角统一 |
| `BookGridItem` | 134 行 | 增加长按菜单、进度指示器 |
| `BookListItem` | 需新建 | 列表模式下的横向条目 |
| `BookSectionHeader` | 需新建 | 分组头（ sticky header） |

### 5.3 阅读器组件（从 1285 行拆分）

```
widgets/reader/
├── reader_page_view.dart       # 翻页容器（PageView/CustomPainter）
├── reader_text_content.dart    # 正文排版渲染
├── reader_toolbar.dart         # 顶部/底部工具栏
├── reader_settings_panel.dart  # 字体/亮度/主题设置面板
├── reader_chapter_drawer.dart  # 目录侧滑抽屉
├── reader_progress_bar.dart    # 底部进度条
└── reader_page_indicator.dart  # 页码指示
```

---

## 六、三端响应式布局方案

### 6.1 断点体系（扩展 `Responsive`）

| 断点 | 宽度范围 | 设备 | 布局策略 |
|------|----------|------|----------|
| compact | < 600dp | 手机竖屏 | 单栏、底部 NavigationBar |
| medium | 600–840dp | 手机横屏/小平板 | 单栏加宽、底部导航 |
| expanded | 840–1200dp | 平板 | 双栏（列表+详情）、NavigationRail |
| large | > 1200dp | 桌面 | 三栏可选、NavigationRail + 侧面板 |

### 6.2 各页面适配策略

| 页面 | compact | expanded/large |
|------|---------|----------------|
| 书架 | 2-3 列网格 | 4-6 列网格 + 右侧详情面板 |
| 阅读器 | 全屏沉浸 | 居中内容区（最大宽度 720dp）+ 侧边目录 |
| 发现页 | 单栏列表 | 左侧书源列表 + 右侧内容 |
| 搜索 | 全屏搜索 | 对话框式搜索 + 结果双栏 |
| 设置 | 单栏列表 | 双栏（左菜单 + 右内容） |
| 书源管理 | 单栏列表 | 列表 + 编辑面板（双栏） |

### 6.3 导航适配

```dart
// 根据断点切换导航形式
Widget _buildNavigation(BuildContext context) {
  final isExpanded = MediaQuery.sizeOf(context).width >= 840;
  if (isExpanded) {
    return NavigationRail(...);  // 平板/桌面
  }
  return NavigationBar(...);     // 手机
}
```

---

## 七、API 对接方案

### 7.1 现有契约覆盖度

当前 `BookApi` 已定义 **158 个方法**，覆盖 34 个模块，与 REFACTORING_PLAN.md 中所有 UI 需求对应：

| UI 模块 | 依赖 API 模块 | 方法数 | 状态 |
|---------|--------------|--------|------|
| 书架 | 书架操作 + 书籍分组 | 12 | 已实现 |
| 阅读器 | 阅读器操作 + 书签 + 替换规则 | 18 | 已实现 |
| 发现页 | 发现页操作 + 搜索操作 | 7 | 已实现 |
| 书源管理 | 书源操作 + WebBook | 14 | 已实现 |
| 设置 | 配置 + 备份 + 缓存 + WebDAV | 16 | 已实现 |
| 规则编辑器 | 规则解析 + 替换规则 | 7 | 已实现 |

### 7.2 Mock 数据策略

- `MockBookApi`（1251 行）已提供全量假数据
- UI 开发全程使用 `--dart-define=USE_MOCK=true`
- Mock 数据从 Android 原版抓取真实 JSON 作为样本
- 集成验证时切换为 `RustApi`，页面代码零修改

### 7.3 错误处理统一（UI 展示层）

```dart
// utils/error_mapper.dart
// 将异常转换为用户可读的 UI 提示文本 —— 纯展示层逻辑
String mapApiError(Object e) {
  if (e is BridgeError) return e.message;  // Rust 侧已封装的错误消息
  if (e is TimeoutException) return '请求超时，请重试';
  return '未知错误：$e';
}
```

> 边界说明：错误分类、重试策略、网络恢复等逻辑由 Rust 网络层负责。
> UI 侧仅将异常映射为提示文本 + 提供「重试」按钮（重新调用同一 API）。

---

## 八、分阶段实施计划

### Phase 1：书架模块（第 1–2 周）

| 任务 | 产出 | 验收标准 |
|------|------|----------|
| 1.1 添加 riverpod 依赖，配置 ProviderScope | pubspec.yaml + main.dart | 编译通过 |
| 1.2 实现 `BookshelfNotifier` (Riverpod) | providers/bookshelf/ | 单元测试通过 |
| 1.3 重构 `BookshelfScreen` 为 ConsumerWidget | screens/bookshelf_screen.dart | Mock 模式正常渲染 |
| 1.4 实现通用状态组件 | widgets/common/ | 三态切换正确 |
| 1.5 网格/列表切换 + 下拉刷新 + 长按菜单 | 交互完整 | 对齐 Android 原版 |
| 1.6 响应式：2/3/4/6 列自适应 | Responsive 扩展 | 手机/平板/桌面三端验证 |
| 1.7 分组展示 + 拖拽排序 | 分组头 + ReorderableGrid | 与原版交互一致 |
| 1.8 Widget 测试 | test/bookshelf/ | 覆盖率 > 80% |

### Phase 2：阅读器核心（第 3–5 周）

| 任务 | 产出 | 验收标准 |
|------|------|----------|
| 2.1 实现 `ReaderNotifier`（调用 API 加载章节、保存进度） | providers/reader/ | 异步加载不卡 UI |
| 2.2 拆分 ReaderScreen 为 7 个子组件 | widgets/reader/ | 单文件 < 300 行 |
| 2.3 翻页模式：覆盖/仿真/滑动/无动画 | reader_page_view.dart | 流畅度 >= 60fps |
| 2.4 正文排版渲染：字体/行距/段距/背景色 | reader_text_content.dart | 与原版视觉一致 |
| 2.5 工具栏 + 设置面板 | reader_toolbar/settings | 动画流畅 |
| 2.6 目录抽屉 + 书签 + 进度跳转 | reader_chapter_drawer | 功能完整 |
| 2.7 预加载调用时机控制（前后各 2 章的 API 调用编排） | Notifier 调用策略 | 翻页无等待感 |
| 2.8 桌面端：居中内容 + 键盘快捷键 | 响应式适配 | 桌面可用 |
| 2.9 漫画阅读器适配 | reader_comic_screen | 分页/缩放手势 |

> 2.7 边界说明：Notifier 仅决定「何时调用 `getChapterContent()`」，
> 文本解析/净化/替换全部由 Rust 在 `getChapterContent` 内部完成，UI 侧拿到的已是最终渲染文本。

### Phase 3：发现页 + 搜索（第 6–7 周）

| 任务 | 产出 | 验收标准 |
|------|------|----------|
| 3.1 实现 `ExploreNotifier`（调用 exploreParseUrl/exploreFetchBooks） | providers/explore/ | 分类解析正确 |
| 3.2 发现页：书源列表 + 分类 Tab + 书籍网格 | explore_screen 重构 | 对齐 ExploreFragment.kt |
| 3.3 搜索：SearchNotifier 迁移（searchBooks + 加载态 + 结果展示） | search_screen 重构 | 搜索结果与原版一致 |
| 3.4 搜索历史 + 联想 | SearchNotifier 联想（客户端前缀过滤） | 输入实时联想，对标原版 flowSearch |
| 3.5 发现页双栏（平板） | 响应式 | 左侧源/右侧内容 |

> 边界说明：多源搜索的并行调度、结果合并、去重均由 Rust `searchMulti()` 完成。
> UI 侧 Notifier 只负责：发起调用 → 显示进度 → 渲染返回结果列表。

> **3.3 实施决议（跨轨需求登记）**：原版 Android `SearchModel.kt` 为逐源流式搜索 +
> `onSearchProgress(searched, total)` x/y 进度（协程 flow，每源返回即增量合并结果）。
> 当前 Rust FFI `searchBooks`/`searchMulti` 均为 `Future<String>` 一次性返回（`runtime::block_on`
> 等全部源完成），无 Stream 版本，故 UI 侧无法还原逐源渐进进度，「进度指示」当前仅能落地为
> 不确定加载态。经决议：Phase 3.3 保持 `searchBooks`（结构化返回、行为不变）仅做 Riverpod 迁移；
> **渐进搜索 + x/y 进度需 Rust 轨新增 `Stream<SearchResult>` FFI API**（flutter_rust_bridge 支持），
> 属 FFI 契约变更，登记为跨轨需求待 Rust 轨排期，UI 轨不触碰。

> **3.4 实施决议（跨轨需求登记）**：原版 Android 搜索历史为 DB 后端（`searchKeywordDao`，实体
> `SearchKeyword(word, usage, lastUseTime)`），联想为 `flowSearch(key)` 前缀匹配 + `bookDao.flowSearch`
> 书架内搜索。调研发现两个跨轨缺口：① Rust `get_search_history` 返回 DTO 字段为 `keyword/book_name/time`，
> 与 Dart `SearchKeyword` 模型（`word/usage/lastUseTime`，对齐原版实体）不匹配，`fromJson` 解析后 `word`
> 恒为空（真实 FFI 历史显示为空的既有 bug，同样影响书内搜索历史）；② 前缀联想所需的
> `SearchKeywordRepository::find_by_prefix` 未暴露至 FFI bridge。
> 经决议：Phase 3.4 历史存储保持 SharedPreferences（与重构前 Flutter 一致、真实 FFI 模式亦可用、不回归）；
> 联想以客户端对已有历史做前缀过滤实现（对标原版 `flowSearch` UX，无需新 FFI）；
> **Rust 字段对齐 + `searchHistoryByPrefix` FFI 暴露**已登记至 `API_CONTRACT.md` 需求区，
> 待 Rust 轨交付后再将历史/联想后端切换为 BookApi。

### Phase 4：设置 / 书源管理（第 8–9 周）

| 任务 | 产出 | 验收标准 |
|------|------|----------|
| 4.1 设置页重构（分组列表 + 双栏桌面） | settings_screen | 对齐原版设置项 |
| 4.2 书源管理：列表/搜索/启用/禁用/排序 | source_screen | CRUD 完整 |
| 4.3 书源导入/导出（URL/文件/二维码） | 导入流程 | 与原版兼容 |
| 4.4 WebDAV 同步设置 | webdav_settings | 配置+同步可用 |
| 4.5 主题切换 + 字体设置 | theme_config | 亮/暗/跟随系统 |
| 4.6 备份/恢复 + 缓存清理 | 设置子功能 | 功能正确 |

> **4.1 实施决议（枢纽菜单重构）**：原 `settings_screen.dart`（1014 行单体、内联 7 分组）重构为
> **枢纽菜单**，对标 Android 原版「我的」页 `pref_main.xml`：顶部管理入口（书源管理/定时任务/
> TXT 目录规则/替换净化/词典规则/主题模式）+「设置」分组（备份恢复/主题设置/其他设置）+「其他」分组
> （书签/阅读统计/关于）。子设置页拆分：主题设置→`theme_config_screen`（既有）；新增
> `other_settings_screen` 承接语言/默认阅读设置/网络（代理·超时·QUIC）/缓存入口；备份恢复聚合为
> 底部弹窗（备份/恢复/WebDAV），WebDAV 详情→既有 `webdav_settings_screen`；注册孤儿页
> `cache_settings_screen` 路由。原版中 Flutter 无对应实现的项（Web 服务/MCP 服务/定时服务开关/
> 文件管理/退出）按「禁止新增功能」原则跳过。状态管理暂保持 `provider`（迁移留待 Phase 5.4 统一移除）。
> 注：其他会话在 `settings_screen` 网络设置中新增的 QUIC/HTTP3 开关已迁移至 `other_settings_screen` 保留。

> **4.2 实施决议（书源排序）**：`source_screen` 列表/搜索/启用/禁用/批量/导入导出已完备，本次补齐
> **排序**缺口，对标 Android `BookSourceSort`。`SourceProvider` 新增 `SourceSort` 枚举（手动 customOrder /
> 权重 weight / 名称 / URL / 更新时间 / 启用状态 / 响应时间）+ 升降序状态 + 比较器，排序与分组筛选叠加生效；
> `source_screen` 新增排序菜单（对标 `action_sort` 子菜单：手动/自动/名称/URL + 降序切换，当前项打勾）。
> 排序为纯 UI 状态同步（展示层排序，不改 Rust 数据），符合越界检查清单。补充 10 个排序单元测试。

> **4.3 实施决议（导入/导出对齐原版）**：`source_screen` 原仅有 URL/剪贴板导入 + 剪贴板导出，本次补齐
> 对标 Android `BookSourceActivity` 的三种导入与文件导出：①「从文件导入」（FilePicker txt/json →
> 复用 `SourceProvider.importFromFile`）；②「扫码导入」（跳转 `QrcodeScreen`，按内容分流：HTTP URL→
> `importFromUrl`、书源 JSON→`importFromJson`、legado://→提示用关联导入页）；③「导出到文件」
> （`getDirectoryPath` 选目录写 `bookSources_<时间戳>.json`）。`qrcode_screen` 集成 `mobile_scanner`
> 相机实时扫码（Android/iOS），桌面/测试环境降级手动输入。新增 `mobile_scanner` 依赖 + Android
> CAMERA 权限 + iOS `NSCameraUsageDescription`。补充 3 个 widget 测试。

> **4.4 实施决议（WebDAV 同步设置，模拟转真实 + 对齐原版）**：原 `webdav_settings_screen`（586 行自设计
> 「同步中心」：连接测试/同步进度/同步日志/自动同步频率，且连接测试与同步均为 `Future.delayed` 模拟）
> 重构为对标 Android `BackupConfigFragment` 的 **WebDAV 设置组** Preference 列表页。调研确认 Rust 侧
> WebDAV API 已真实实现（`webdav_api.rs`：listDir/upload/download/delete/fullSync，`WebDavConfig{url,
> username,password}`），且 `BookApi` 契约已暴露，故同步后端**由模拟切换为真实 BookApi 调用**：
> ①「备份」=`webdavFullSync`（上传本地书架+书源序列化 JSON）；②「恢复」=`webdavFullSync` 取远端合并
> 数据 → 书源经 `importBookSources` 回写。设置项补齐原版「设备名称/同步书籍进度/同步书籍进度增强」
> （`SettingsService` 新增 3 键持久化，进度增强依赖进度开关）。移除原版没有的连接测试按钮/同步日志/
> 自动同步频率（`SyncProvider.autoSync` 状态保留但不再上 UI）。备份/恢复组中本地备份路径/恢复忽略项/
> 缓存清理属 Phase 4.6。**跨轨需求登记**：书架批量回写受限于 `BookApi` 暂无 `importBooks(jsonArray)`
> 批量导入契约（现仅单本 `addBook`），恢复时书架回写待 Rust 轨补契约；`WebDavConfig` 暂无设备名字段，
> 设备名仅 UI-only 存储。`SyncProvider` 同步方法重构为 `backupToWebDav`/`restoreFromWebDav`（移除模拟的
> `syncUpload/syncDownload/syncMerge`）。重写 sync_provider 单元测试（23 个）+ webdav 页面 widget 测试
> （3 个，替换原 18 个自搭片段测试）。全量 960 测试通过。

> **4.5 实施决议（主题切换全局生效 + 全局字体缩放）**：核心缺口为 `app.dart` 硬编码
> `themeMode: ThemeMode.system`——settings_screen/theme_config_screen 保存的主题模式「保存了但不生效」
> （MaterialApp 不读取、不监听）。新增 `ThemeProvider`（ChangeNotifier，暂保持 provider，迁移留待 Phase 5.4）
> 集中管理主题模式 + 全局字体缩放；`app.dart` 经 `Consumer<ThemeProvider>` 驱动 `themeMode`，`builder` 覆盖
> 全局 `textScaler`。字体缩放对齐原版 `AppContextWrapper.getFontScale` 语义（PreferKey.fontScale：0=跟随系统，
> 8~16→0.8x~1.6x，「默认」按钮重置跟随系统），`SettingsService` 新增 `app_font_scale` 持久化；theme_config_screen
> 新增「全局字体大小」选择对话框（Slider 0.8~1.6 + 跟随系统），原「字体大小」更名「阅读器字体大小」（阅读器级，
> 对应原版阅读器排版）。settings_screen/theme_config_screen 主题模式选择统一接入 ThemeProvider 全局实时生效。
> 原版重型主题项（图标更换/欢迎样式/沉浸状态栏/elevation/封面配置/主题列表/底栏皮肤/日夜间 ColorPicker/
> 背景图）按「禁止新增功能」原则 + design_system M3 统一 ColorScheme Token 全部跳过。补充 theme_provider 单测
> （13）+ theme_config widget 测试（3）+ settings 主题切换测试（1）+ settings_service fontScale 测试（3）。全量 980 测试通过。

> **4.6 实施决议（本地备份/恢复真实落盘 + 缓存清理确认 + 延后项占位）**：核心缺口为 settings_screen
> 本地备份/恢复未接入 Rust 契约——`_doBackup` 仅 `BackupService.fullBackup()` 生成内存 JSON 显示长度（未落盘），
> `_doRestore` 仅粘贴 JSON 恢复书源。调研确认 `RustApi.backup(dirPath)`（收集 books/bookmarks/sources/
> rssSources/replaceRules/httpTts 写 `legado_backup_<时间戳>.json`）与 `restore(backupPath)`（全量回写）
> 已真实实现，备份路径持久化亦已有（`CrashLogService.getBackupPath/setBackupPath`，对应原版 `AppConfig.backupPath`），
> 故备份/恢复**由内存模拟切换为真实 BookApi 落盘**：①「备份」读取备份路径（无则 `FilePicker.getDirectoryPath`
> 选目录并持久化）→ `api.backup(dirPath)` 提示备份文件路径；②「恢复」`FilePicker.pickFiles`（json/zip）→
> `api.restore(backupPath)` 全量恢复 + 刷新书架。缓存管理（`CacheService` + `cache_settings_screen`：统计/
> 自动过期/清理）经确认已完备（otherSettings 入口 + 路由已接线），本次无需改动。原版 `BackupConfigFragment` 的
> **恢复忽略项（restoreIgnore）/导入旧版数据（importOldData）/日志菜单（menu_log）**列为延后项，不修改 Rust 契约：
> 备份恢复弹窗为「恢复忽略项」「导入旧版数据」各增加禁用 ListTile（副标题「后续版本支持」）占位；设置页底部新增
> 「导出日志」入口，经 `CrashLogService.exportLogsToFile`（聚合内存/崩溃/消息日志为临时文件）+ `share_plus` 系统分享。
> 移除 settings_screen 对 `BackupService` 的依赖（`BackupService` 本身保留，source_provider 与单测仍用）。

### Phase 5：规则编辑器 + 收尾（第 10–12 周）

| 任务 | 产出 | 验收标准 |
|------|------|----------|
| 5.1 书源编辑表单（多 Tab：基本/搜索/发现/详情/目录/正文） | source_edit_screen | 字段完整 |
| 5.2 规则调试器（输入 URL → 执行规则 → 展示结果） | source_debug_screen | 可实时调试 |
| 5.3 替换规则编辑器 | replace_rules_screen | CRUD + 正则预览 |
| 5.4 移除 `provider` 依赖，全量 Riverpod | pubspec.yaml | 编译通过 |
| 5.5 三端全量冒烟测试 | 测试报告 | 无 P0/P1 缺陷 |
| 5.6 性能优化（列表懒加载、图片缓存策略） | 优化提交 | 首屏 < 1s |
| 5.7 暗色模式全量检查 | 逐屏验证 | WCAG AA 达标 |

> **5.1 实施决议（书源编辑表单多 Tab + 字段完整）**：`source_edit_screen` 原已存在（5 Tab：基本/搜索/目录/内容/测试），
> 但缺「发现」「详情」Tab 且现有 Tab 字段覆盖不全。本次重构为数据驱动表单（`_Field` 字段定义 + controller 按 key
> 惰性创建），与原版 `BookSourceEditActivity` 基于 `EditEntity` 列表的配置化编辑思路一致。Tab 扩为 8 个：
> 基本信息/搜索规则/发现规则/详情规则/目录规则/内容规则/评论规则/测试——其中「评论」Tab 为用户决策追加
> （忠实还原原版 7 Tab 结构），「测试」Tab 为 Flutter 既有便利功能予以保留。字段全量覆盖 SearchRule/ExploreRule/
> BookInfoRule/TocRule/ContentRule/ReviewRule（达成「字段完整」验收），并新增「启用发现」（enabledExplore）与
> 「启用段评」（ReviewRule.enabled）开关。原有规则验证对话框（webbookSearch/Info/Chapters/Content）与测试 Tab
> 逻辑原样保留。新增 `source_edit_test.dart` 5 个 widget 测试（8 Tab 结构/新 Tab 字段与开关可见/必填校验/保存创建/
> 编辑模式回填发现·详情·评论规则）。全量 986 测试通过，改动文件 analyze 0 issues。
>
> **5.2 核验决议（规则调试器）**：`source_debug_screen` 已存在且功能闭环（输入书源 URL + 关键词 → `webbookSearch`
> → 分级日志展示/级别过滤/清空）。原版 `BookSourceDebugActivity` 通过 WebSocket 流式输出分步日志（搜索/详情/目录/
> 正文）+ 快捷帮助面板 + 源码 HTML 查看菜单，但 Flutter 侧受 FFI bridge 契约冻结约束（无分步日志流 API），直连
> `webbookSearch` 是合理适配，满足「输入 URL → 执行规则 → 展示结果」验收，本次无需改动。
>
> **5.3 实施决议（替换规则编辑器）**：`replace_rules_screen` 的 CRUD（增删改查 + 启停 + 拖拽排序）已完整。经核对
> 原版 `ReplaceEditActivity`，验收项「正则预览」在原版中并不存在（编辑菜单仅全屏编辑/保存/复制/粘贴 + 正则教程链接），
> 按「禁止新增功能」原则不予添加。真实缺口是编辑表单缺少原版与 Dart 模型均支持的 5 个字段：分组（group）/作用于标题
> （scopeTitle）/作用于正文（scopeContent）/排除范围（excludeScope）/超时（timeoutMillisecond）。本次按用户决策补全
> 这 5 个字段，忠实还原原版字段集与顺序。新增 `replace_rules_test.dart` 3 个 widget 测试（全字段可见/保存全字段传递/
> 编辑模式回填全字段与开关）。全量 989 测试通过，改动文件 analyze 0 issues。
>
> **5.4 实施决议（移除 provider 依赖，全量 Riverpod）**：采用「多 agent 并行 + 主控整合」模式（用户决策：freezed+Notifier
> 完整重写、全部 6 个 agent 同时跑）。将原 10 个 `ChangeNotifierProvider`（theme/bookshelf/source/rss/reading_stats/sync/
> bookmark/replace_rule/auto_task/association/audio）与 `Provider<BookApi>` 全部迁移为 Riverpod `NotifierProvider`（freezed
> 不可变 State + `Notifier`），统一经全局 `bookApiProvider` 取 API。新建 `providers/{theme,sync,replace_rule,auto_task,
> association,audio,reading_stats,rss,source,bookmark}/` 模块（bookshelf 复用 Phase 1.2-1.3 已建的 `bookshelf/`）；消费方
> 屏幕改 `ConsumerWidget/ConsumerStatefulWidget` + `ref.watch/read`；`main.dart` 移除 `MultiProvider` 仅留 `ProviderScope`；
> `pubspec.yaml` 移除 `provider` 依赖（lib 中 `package:provider` 引用归零）。测试改 `ProviderContainer`/`ProviderScope` +
> `bookApiProvider.overrideWithValue(mock)` 范式。**并行协作要点**：6 个 agent 按文件互斥分派、不碰共享文件（main/app/
> pubspec/settings 等）、不跑 build_runner（freezed 由主控统一生成）；主控整合阶段修复 agent 产出缺陷（缺失 rust_api 导入、
> 误用 `hide Provider`、未完成的 book_group/book_info BookApi 消费点迁移、移除 12 处未使用导入）。**测试注意**：
> `SharedPreferences` 单例跨测试缓存，`setMockInitialValues` 后须先读取 provider 触发 `build()` 再冲刷微任务，否则自动
> 加载不生效。**git 隔离**：并行会话的「跨章节连续分页 + 书籍信息编辑」功能改动（reader/*、paragraph_layout_engine、
> routes.dart、bookshelf_screen 等）予以排除；`reader_screen` 还原后仅重做 bookmark/BookApi 迁移部分（分页功能留待该会话
> 重新应用）。删除与 `bookshelf_notifier_test` 重复的 `bookshelf_provider_test`。全量 952 测试通过，analyze 0 error/warning。

---

## 九、验收标准总则

### 9.1 功能验收

- [ ] 所有页面功能与 Android 原版（gedoor/legado）对等，无新增功能
- [ ] Mock 模式下所有页面可正常渲染和交互
- [ ] 真实 RustApi 模式下数据流通正确
- [ ] 错误场景（网络超时、数据为空、FFI 异常）有合理 UI 反馈

### 9.2 视觉验收

- [ ] 逐屏对照 `docs/baseline_android/` 截图，像素级对齐
- [ ] 亮色/暗色主题全部正确（无硬编码颜色）
- [ ] 字体层级、间距、圆角遵循 `design_system.md`

### 9.3 架构验收

- [ ] UI 层零业务逻辑（所有计算通过 BookApi 委托 Rust）
- [ ] 状态管理全部为 Riverpod Notifier
- [ ] 无循环依赖，分层清晰
- [ ] `flutter analyze` 零 warning/error

### 9.4 性能验收

- [ ] 书架首屏加载 < 500ms（Mock）/ < 1s（真实 API）
- [ ] 阅读器翻页 >= 60fps
- [ ] 列表滚动无掉帧（100+ 条目）
- [ ] 内存占用稳定（无泄漏）

### 9.5 测试验收

- [ ] 每个 Notifier 有单元测试
- [ ] 核心页面有 Widget 测试
- [ ] 测试覆盖率 > 70%（核心模块 > 80%）

---

## 十、风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| Riverpod 迁移引入回归 | 功能中断 | 逐模块迁移 + 每模块测试通过后再下一个 |
| 阅读器翻页性能 | 用户体验差 | CustomPainter + RepaintBoundary 隔离 |
| 桌面端布局适配工作量大 | 延期 | 优先保证手机端，桌面端在 Phase 5 集中处理 |
| Rust API 返回格式变更 | UI 崩溃 | 契约冻结 + 双兼容点登记机制 |
| 三端样式不一致 | 视觉偏差 | 统一使用 Theme Token，禁止平台判断改色 |

---

## 十一、协作接口与越界处理

### 11.1 职责分界

| 归属 | 文件/目录 | 负责人 |
|------|-----------|--------|
| UI 轨 | `screens/`、`widgets/`、`providers/`、`theme/`、`utils/`、`l10n/`、`mock_book_api.dart` | A（本方案） |
| Rust 轨 | `rust/`、`bridge/`、`rust_api.dart`（新增方法）、`frb_generated*` | B |
| 共享 | `book_api.dart`（接口定义）、`models/`（freezed 模型） | 双方评审 |

### 11.2 协作流程

- 新增 API 需求：在 `API_CONTRACT.md` § 3 登记 → UI 轨先在 MockBookApi 补假实现 → Rust 轨交付真实方法 → UI 轨去掉 USE_MOCK 验证
- 每周一次集成验证（合并双轨分支 → 全量测试 → 冒烟）
- 契约变更必须双方确认，UI 轨不单方面修改接口签名

### 11.3 越界检查清单（Code Review 时强制核对）

- [ ] Notifier 中是否存在 `List.sort()` / `Iterable.where()` 用于业务过滤（非 UI 状态同步）？
- [ ] Widget 中是否存在直接 `new RustApi()` 或 FFI 调用？
- [ ] 是否有 Dart 侧正则替换/文本处理逻辑？
- [ ] 是否有 Dart 侧网络请求（http 包直接调用）替代了 BookApi？
- [ ] 是否有新增文件位于 `bridge/` 目录？
- [ ] 以上任一项为「是」→ 拒绝合入，修正后重新提交
