# 项目版本控制记录

## v2.1.0 - 重构功能修正版 (2026-07-30)

### 🔄 核心变更

#### ❌ **删除新增的推荐算法模块**
**原因**: 这是重构项目，不是创新项目。Flutter 版本应忠实还原 Android 原版功能，不应添加新设计的功能模块。

**删除内容**:
1. `flutter_legado/lib/src/models/recommended_source.dart` - 新建的数据结构（非 Android 原有）
2. `flutter_legado/lib/src/providers/discover_provider.dart` - 错误的 Provider 实现
3. `flutter_legado/lib/src/screens/discover_screen.dart` - 完全偏离原版的发现页 UI
4. `models.dart`中的导出声明

**影响范围**:
- `home_screen.dart` - Tab 2 从 DiscoverScreen 改为 ExploreScreen
- `routes.dart` - 路由路径 `/discover` 改为 `/explore`
- 所有引用 discover_provider 的代码需要更新

#### ✅ **引入 Android 原版探索页逻辑**
**参考对象**: [`ExploreFragment.kt`](file:///d:/OH-WorkSpace/LegadoTeam/legado/flutter_legado/legado/app/src/main/java/io/legado/app/ui/main/explore/ExploreFragment.kt)

**新增内容**:
1. `flutter_legado/lib/src/providers/explore_provider.dart` - 基于 BookSource 的状态管理
2. `flutter_legado/lib/src/screens/explore_screen.dart` - 书源列表展示 + 搜索 + 分组筛选

**核心功能**:
- ✅ 显示已安装的书源列表（BookSource 表）
- ✅ 实时搜索过滤（按名称/URL）
- ✅ 按分组筛选书源（动态分组菜单）
- ✅ 一键卸载书源（本地 CRUD）
- ⚠️ 不展示未安装的书源（Android 原版无此功能）
- ⚠️ 无热门推荐排行榜（Android 原版无此功能）

---

### 📊 代码变更统计

| 文件类型 | 新增 | 修改 | 删除 |
|---------|------|------|------|
| Dart Models | 0 | 1 | 1 |
| Providers | 1 | 0 | 1 |
| Screens | 1 | 2 | 1 |
| Routes | 1 | 2 | 0 |
| **总计** | **3** | **5** | **3** |

---

### 🔍 技术细节

#### ExploreProvider 架构设计
```dart
class ExploreProvider extends ChangeNotifier {
  List<BookSource> _bookSources = []; // 本地数据
  Set<String> _groups = {};           // 分组集合
  String _selectedGroup = '';         // 当前分组
  
  List<BookSource> get filteredBookSources {
    // 1. 先按搜索关键词过滤
    // 2. 再按分组过滤
    return list.where(...).toList();
  }
}
```

#### Android vs Flutter 对比

| 特性 | Android (ExploreFragment.kt) | Flutter (ExploreScreen.dart) | 状态 |
|------|------------------------------|-------------------------------|------|
| 数据来源 | Room Database (BookSourceDao) | BookSourceRepository | ✅ 对等 |
| 搜索机制 | SearchView.onQueryTextChange() | TextField.controller | ✅ 对等 |
| 分组选择 | BottomSheet 弹窗 / Chip 行 | ListView + FilterChip | ✅ 等价 |
| 书源操作 | RecyclerView.Adapter 编辑 | Card + 按钮 | ✅ 等价 |
| 热门排行 | ❌ 不存在 | ❌ 已删除 | ✅ 一致 |
| 推荐引擎 | ❌ 不存在 | ❌ 已删除 | ✅ 一致 |

---

### 📝 Git 提交建议

```bash
# 检查当前工作区状态
git status

# 本次清理涉及的文件变更：
# 已删除：
git rm flutter_legado/lib/src/providers/discover_provider.dart
git rm flutter_legado/lib/src/screens/source_discover_screen.dart
git rm flutter_legado/test/widget/discover_screen_test.dart

# 已修改：
git add flutter_legado/lib/main.dart
git add flutter_legado/lib/src/routes.dart
git add flutter_legado/lib/src/screens/settings_screen.dart
git add flutter_legado/lib/src/screens/home_screen.dart
git add flutter_legado/lib/src/providers/explore_provider.dart

# 提交
git commit -m "refactor: 清理推荐算法残留，接入发现页 ExploreScreen

- 删除 discover_provider.dart / source_discover_screen.dart / discover_screen_test.dart
- main.dart: DiscoverProvider → ExploreProvider
- home_screen.dart: 4 tabs ↔ 4 destinations 对齐（书架/发现/订阅/我的）
- settings_screen.dart: 移除 AppRoutes.discover 死引用
- explore_provider.dart: 增加 enabledExplore + exploreUrl 过滤"
```

---

### 📌 重要说明

1. **重构原则**: 
   - ✅ 只移植 Android 原版已有功能
   - ❌ 不添加新设计的创新模块
   - 🎯 忠实还原原始实现

2. **功能对标**:
   - Flutter 版本 ExploreScreen ≈ Android ExploreFragment
   - 使用相同的数据模型（BookSource）
   - 实现相同的交互逻辑（搜索 + 分组 + CRUD）

3. **文档同步**:
   - 已更新 [`rust/PROGRESS.md`](file:///d:/OH-WorkSpace/LegadoTeam/legado/rust/PROGRESS.md) — 任务进度跟踪（含发现页后续增强任务）
   - 已创建本 [`VERSION_CONTROL.md`](file:///d:/OH-WorkSpace/LegadoTeam/legado/VERSION_CONTROL.md) — 版本变更决策记录

---

**更新日期**: 2026-07-30  
**更新人**: AI Assistant（Human Review Required）  
**关联任务**: Task #139（RSS），Task #129（排版引擎）

---

## 崩溃防护与启动优化

### 新增文件
| 文件路径 | 说明 |
|---------|------|
| `flutter_legado/lib/src/services/crash_log_service.dart` | 崩溃日志服务（单例），支持错误捕获、日志写入、崩溃记录读取 |
| `flutter_legado/lib/src/widgets/crash_log_dialog.dart` | 崩溃日志弹窗组件，支持详情展开和日志清除 |

### 修改文件
| 文件路径 | 改动说明 |
|---------|----------|
| `flutter_legado/lib/main.dart` | runZonedGuarded 包裹、CrashLogService 初始化、全局错误捕获、Future.wait 并行初始化、Stopwatch 计时日志、崩溃日志读取传递 |
| `flutter_legado/lib/app.dart` | LegadoApp 改为 StatefulWidget，新增 lastCrashLog 参数，首帧弹窗展示崩溃日志 |
| `flutter_legado/lib/src/services/settings_service.dart` | 全部 30 个方法添加 try-catch 异常保护，返回安全默认值 |
| `flutter_legado/lib/src/services/cache_service.dart` | SharedPreferences 调用添加 try-catch 保护 |
| `flutter_legado/lib/src/screens/home_screen.dart` | IndexedStack Tab 懒构建，未访问 Tab 延迟创建 |
| `flutter_legado/lib/src/screens/bookshelf_screen.dart` | loadSettings 下沉到首帧回调 |
| `flutter_legado/lib/src/screens/reader_screen.dart` | loadSettings 下沉到首帧回调 |

### 功能要点
- 四层崩溃防护：CrashLogService 全局捕获 + runZonedGuarded 异步兜底 + StorageService 安全访问 + 启动崩溃日志弹窗
- 启动优化：SharedPreferences 与 Rust FFI 并行初始化、Tab 懒构建减少首帧开销、loadSettings 下沉
