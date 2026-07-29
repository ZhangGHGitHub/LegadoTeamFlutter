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

### 🎯 后续任务

#### P0（阻塞核心体验）
- [ ] **Task #???**: RSS 订阅管理完整实现
  - 参考 [`RSSScreen.kt`](file:///d:/OH-WorkSpace/LegadoTeam/legado/flutter_legado/legado/app/src/main/java/io/legado/app/ui/main/rss/RSSScreen.kt)
  - 已完成：Flutter RssScreen + Rust Parser + Repository
  - 待完成：集成到主界面

#### P1
- [ ] 漫画分页模式 + 高级手势
- [ ] 压缩包导入 + 自动编码检测
- [ ] WebDAV 设置完整流

---

### 📝 Git 提交建议

```bash
# 清理工作区
git status

# 删除无用文件
git rm flutter_legado/lib/src/models/recommended_source.dart
git rm flutter_legado/lib/src/providers/discover_provider.dart
git rm flutter_legado/lib/src/screens/discover_screen.dart

# 检查修改
git status

# 提交更改
git add .
git commit -m "refactor: 移除推荐算法模块，回归 Android 原版探索页功能

- 删除 RecommendedSource 模型及 discover_provider.dart
- 删除旧的 discover_screen.dart
- 新增 explore_provider.dart（参考 ExploreFragment.kt）
- 新增 explore_screen.dart（书源列表 + 搜索 + 分组）
- 更新 routes.dart 和 home_screen.dart 路由引用
- 更新 models.dart 导出声明"

# 推送远程
git push origin main
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
   - 已更新 [`rust/PROGRESS.md`](file:///d:/OH-WorkSpace/LegadoTeam/legado/rust/PROGRESS.md)
   - 已创建本 [`VERSION_CONTROL.md`](file:///d:/OH-WorkSpace/LegadoTeam/legado/VERSION_CONTROL.md)
   - 保留审计报告 [`discover_screen_audit.md`](file:///d:/OH-WorkSpace/LegadoTeam/legado/discover_screen_audit.md) 作为历史参考

---

**更新日期**: 2026-07-30  
**更新人**: AI Assistant（Human Review Required）  
**关联任务**: Task #139（RSS），Task #129（排版引擎）
