# Legado UI 修复详细计划

**计划日期**: 2026-07-30  
**计划目标**: 修复 Flutter 重构界面与原版 Android 界面的差异  
**计划范围**: P1 和 P2 优先级差异（共 12 项）  
**预计工时**: 20.5 天（4 周）

> **⚠️ 标准修订声明（2026-08-05，用户确认）**：重构对齐标准已调整为——**界面功能、页面结构与交互流程必须与 Android 原版保持一致，但 UI 视觉风格允许自由改变**。本文档中历史的"视觉一致性 ≥ 90%"、"像素级对齐"等验收标准不再适用于后续 UI 演进；后续任务以功能一致性为验收基准，视觉设计以 `docs/design_system.md` 为准。


---

## 修复概览

### 修复目标
- 修复 4 项 P1 重要差异
- 修复 8 项 P2 次要差异
- ~~视觉一致性达到 90% 以上~~（已废止，见顶部标准修订声明：功能对齐原版，视觉风格自由）
- 所有功能正常，无编译错误

### 修复原则
1. **优先级驱动**: 先修复 P1，再修复 P2
2. **增量交付**: 每完成一项修复立即测试和提交
3. **风险可控**: 高风险任务充分测试后再合并
4. **文档同步**: 每项修复附带文档更新

---

## 阶段 1: P1 差异修复（第 1 周，7 天）

### 任务 1.1: 修复 Tab 导航名称不一致（P1-1）

**目标**: 将第 4 个 Tab 名称从"设置"改为"我的"

**文件清单**:
- `flutter_legado/lib/src/screens/home_screen.dart` (修改)
- `flutter_legado/lib/src/l10n/app_strings.dart` (修改)

**实施步骤**:

1. **修改 home_screen.dart**
```dart
// 修改前
NavigationDestination(
  icon: const Icon(Icons.person_outline),
  selectedIcon: const Icon(Icons.person),
  label: AppStrings.settings,
),

// 修改后
NavigationDestination(
  icon: const Icon(Icons.person_outline),
  selectedIcon: const Icon(Icons.person),
  label: '我的',  // 或 AppStrings.my
),
```

2. **更新 app_strings.dart**
```dart
// 添加
static const String my = '我的';
```

3. **测试验证**
- [x] 启动应用
- [x] 验证第 4 个 Tab 显示“我的”
- [x] 切换到该 Tab，功能正常
- [x] 提交代码

**验收标准**:
- [x] 第 4 个 Tab 显示“我的”
- [x] 用户可正常切换到该 Tab
- [x] 功能不受影响

**预计工时**: 0.5 天  
**风险等级**: 低  
**依赖关系**: 无

---

### 任务 1.2: 添加"无动画"翻页模式（P1-2）

**目标**: 在阅读器中添加第 4 种翻页模式（无动画）

**文件清单**:
- `flutter_legado/lib/src/models/reader_config.dart` (修改)
- `flutter_legado/lib/src/screens/reader_screen.dart` (修改)
- `flutter_legado/lib/src/widgets/reader_config_panel.dart` (修改)

**实施步骤**:

1. **修改 reader_config.dart**
```dart
// 添加翻页模式枚举
enum PageFlipMode {
  simulation,  // 仿真
  slide,       // 滑动
  cover,       // 覆盖
  none,        // 无动画（新增）
}
```

2. **修改 reader_screen.dart**
```dart
// 添加无动画翻页逻辑
Widget _buildPageFlip() {
  switch (config.pageFlipMode) {
    case PageFlipMode.none:
      return _buildNoAnimationFlip();
    case PageFlipMode.simulation:
      return _buildSimulationFlip();
    // ... 其他模式
  }
}

Widget _buildNoAnimationFlip() {
  // 直接切换页面，无动画
  return PageView(
    controller: _pageController,
    children: _pages,
  );
}
```

3. **修改 reader_config_panel.dart**
```dart
// 添加"无动画"选项
ListTile(
  title: Text('无动画'),
  leading: Radio<PageFlipMode>(
    value: PageFlipMode.none,
    groupValue: config.pageFlipMode,
    onChanged: (value) {
      setState(() {
        config.pageFlipMode = value!;
      });
    },
  ),
),
```

4. **测试验证**
- [x] 打开阅读器
- [x] 进入设置面板
- [x] 选择“无动画”模式
- [x] 翻页验证无动画效果
- [x] 切换到其他模式，功能正常
- [x] 提交代码

**验收标准**:
- [x] 设置面板显示 4 种翻页模式
- [x] 选择“无动画”后翻页无动画效果
- [x] 其他翻页模式不受影响

**预计工时**: 2 天  
**风险等级**: 中  
**依赖关系**: 无

---

### 任务 1.3: 实现系统亮度调节（P1-3）

**目标**: 在阅读器亮度调节中添加系统亮度选项

**文件清单**:
- `flutter_legado/lib/src/services/system_brightness.dart` (新建)
- `flutter_legado/lib/src/screens/reader_screen.dart` (修改)
- `flutter_legado/lib/src/widgets/reader_config_panel.dart` (修改)
- `flutter_legado/android/app/src/main/kotlin/io/legado/app/MainActivity.kt` (修改)

**实施步骤**:

1. **创建 system_brightness.dart**
```dart
import 'package:flutter/services.dart';

class SystemBrightness {
  static const _channel = MethodChannel('io.legado.app/system_brightness');

  /// 获取系统亮度（0.0 - 1.0）
  static Future<double> getBrightness() async {
    try {
      final brightness = await _channel.invokeMethod('getBrightness');
      return brightness as double;
    } catch (e) {
      return 0.5; // 默认值
    }
  }

  /// 设置系统亮度（0.0 - 1.0）
  static Future<void> setBrightness(double brightness) async {
    try {
      await _channel.invokeMethod('setBrightness', brightness);
    } catch (e) {
      print('设置系统亮度失败: $e');
    }
  }

  /// 检查是否支持系统亮度调节
  static Future<bool> isSupported() async {
    try {
      final supported = await _channel.invokeMethod('isSupported');
      return supported as bool;
    } catch (e) {
      return false;
    }
  }
}
```

2. **修改 MainActivity.kt (Android)**
```kotlin
private val SYSTEM_BRIGHTNESS_CHANNEL = "io.legado.app/system_brightness"

override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_BRIGHTNESS_CHANNEL).setMethodCallHandler { call, result ->
        when (call.method) {
            "getBrightness" -> {
                val brightness = Settings.System.getInt(
                    contentResolver,
                    Settings.System.SCREEN_BRIGHTNESS,
                    128
                ) / 255.0
                result.success(brightness)
            }
            "setBrightness" -> {
                val brightness = (call.arguments as Double * 255).toInt()
                Settings.System.putInt(
                    contentResolver,
                    Settings.System.SCREEN_BRIGHTNESS,
                    brightness
                )
                result.success(null)
            }
            "isSupported" -> {
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }
}
```

3. **修改 reader_config_panel.dart**
```dart
// 添加系统亮度开关
SwitchListTile(
  title: Text('系统亮度'),
  subtitle: Text('跟随系统自动调节亮度'),
  value: useSystemBrightness,
  onChanged: (value) async {
    if (await SystemBrightness.isSupported()) {
      setState(() {
        useSystemBrightness = value;
      });
      if (value) {
        final brightness = await SystemBrightness.getBrightness();
        widget.onBrightnessChanged(brightness);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('当前设备不支持系统亮度调节')),
      );
    }
  },
),

// 手动亮度滑块（仅在关闭系统亮度时显示）
if (!useSystemBrightness)
  Slider(
    value: brightness,
    min: 0.0,
    max: 1.0,
    onChanged: widget.onBrightnessChanged,
  ),
```

4. **测试验证**
- [x] 打开阅读器
- [x] 进入亮度调节面板
- [x] 验证“系统亮度”开关显示
- [x] 开启系统亮度，验证跟随系统
- [x] 关闭系统亮度，验证手动调节
- [x] 提交代码

**验收标准**:
- [x] 亮度面板显示“系统亮度”开关
- [x] 开启后跟随系统亮度
- [x] 关闭后使用手动亮度

**预计工时**: 2 天  
**风险等级**: 中  
**依赖关系**: 无

---

### 任务 1.4: 添加分类筛选功能（P1-4）

**目标**: 在搜索界面添加分类筛选器

**文件清单**:
- `flutter_legado/lib/src/screens/search_screen.dart` (修改)
- `flutter_legado/lib/src/widgets/search_filter_panel.dart` (新建)

**实施步骤**:

1. **创建 search_filter_panel.dart**
```dart
import 'package:flutter/material.dart';

class SearchFilterPanel extends StatefulWidget {
  final List<String> categories;
  final List<String> selectedCategories;
  final ValueChanged<List<String>> onCategoriesChanged;

  const SearchFilterPanel({
    super.key,
    required this.categories,
    required this.selectedCategories,
    required this.onCategoriesChanged,
  });

  @override
  State<SearchFilterPanel> createState() => _SearchFilterPanelState();
}

class _SearchFilterPanelState extends State<SearchFilterPanel> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.selectedCategories);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: widget.categories.map((category) {
        final isSelected = _selected.contains(category);
        return FilterChip(
          label: Text(category),
          selected: isSelected,
          onSelected: (selected) {
            setState(() {
              if (selected) {
                _selected.add(category);
              } else {
                _selected.remove(category);
              }
            });
            widget.onCategoriesChanged(_selected);
          },
        );
      }).toList(),
    );
  }
}
```

2. **修改 search_screen.dart**
```dart
// 在搜索框下方添加筛选面板
Column(
  children: [
    SearchBar(...),
    if (categories.isNotEmpty)
      SearchFilterPanel(
        categories: categories,
        selectedCategories: selectedCategories,
        onCategoriesChanged: (categories) {
          setState(() {
            selectedCategories = categories;
          });
          _performSearch(); // 重新搜索
        },
      ),
    Expanded(
      child: SearchResults(...),
    ),
  ],
)
```

3. **修改搜索逻辑**
```dart
Future<void> _performSearch() async {
  final results = await rustApi.searchBooks(
    keyword: searchKeyword,
    categories: selectedCategories, // 添加分类筛选
  );
  setState(() {
    searchResults = results;
  });
}
```

4. **测试验证**
- [x] 打开搜索界面
- [x] 验证分类筛选器显示
- [x] 选择多个分类
- [x] 验证搜索结果根据分类筛选
- [x] 清除分类，验证结果更新
- [x] 提交代码

**验收标准**:
- [x] 搜索界面显示分类筛选器
- [x] 可选择多个分类
- [x] 搜索结果根据分类筛选

**预计工时**: 2 天  
**风险等级**: 中  
**依赖关系**: 无

---

## 阶段 2: P2 差异修复（第 2-3 周，13.5 天）

### 任务 2.1: 修复 Tab 导航标签文字显示（P2-1）

**目标**: 隐藏 Tab 标签文字（与 Android 一致）

**文件清单**:
- `flutter_legado/lib/src/screens/home_screen.dart` (修改)

**实施步骤**:

1. **修改 home_screen.dart**
```dart
NavigationBar(
  labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
  // 或仅显示选中项: NavigationDestinationLabelBehavior.onlyShowSelected
  destinations: [...],
)
```

2. **测试验证**
- [x] 启动应用
- [x] 验证标签文字隐藏
- [x] 切换到不同 Tab，功能正常
- [x] 提交代码

**验收标准**:
- [x] 标签文字显示方式与 Android 一致
- [x] 不影响 Tab 切换功能

**预计工时**: 0.5 天  
**风险等级**: 低  
**依赖关系**: 无

---

### 任务 2.2: 替换 Tab 导航图标（P2-2）

**目标**: 使用与 Android 一致的自定义图标

**文件清单**:
- `flutter_legado/assets/icons/ic_bottom_books.svg` (新建)
- `flutter_legado/assets/icons/ic_bottom_explore.svg` (新建)
- `flutter_legado/assets/icons/ic_bottom_rss_feed.svg` (新建)
- `flutter_legado/assets/icons/ic_bottom_person.svg` (新建)
- `flutter_legado/pubspec.yaml` (修改)
- `flutter_legado/lib/src/screens/home_screen.dart` (修改)

**实施步骤**:

1. **设计图标**
- 从 Android 项目导出 4 个图标（SVG 格式）
- 或重新设计与 Android 一致的图标

2. **添加图标到 assets**
```yaml
# pubspec.yaml
flutter:
  assets:
    - assets/icons/ic_bottom_books.svg
    - assets/icons/ic_bottom_explore.svg
    - assets/icons/ic_bottom_rss_feed.svg
    - assets/icons/ic_bottom_person.svg
```

3. **修改 home_screen.dart**
```dart
NavigationDestination(
  icon: SvgPicture.asset('assets/icons/ic_bottom_books.svg'),
  selectedIcon: SvgPicture.asset('assets/icons/ic_bottom_books.svg', color: primaryColor),
  label: '书架',
),
// ... 其他 Tab
```

4. **测试验证**
- [x] 启动应用
- [x] 验证图标显示正确
- [x] 切换到不同 Tab，图标状态正确
- [x] 在不同主题下图标显示正常
- [x] 提交代码

**验收标准**:
- [x] 图标与 Android 版本视觉一致
- [x] 图标在不同主题下显示正常

**预计工时**: 3 天  
**风险等级**: 中  
**依赖关系**: 需要设计资源

---

### 任务 2.3: 优化书架刷新组件样式（P2-3）

**目标**: 实现与 Android 一致的下拉刷新动画

**文件清单**:
- `flutter_legado/lib/src/screens/bookshelf_screen.dart` (修改)
- `flutter_legado/lib/src/widgets/custom_refresh_indicator.dart` (新建)

**实施步骤**:

1. **创建 custom_refresh_indicator.dart**
```dart
import 'package:flutter/material.dart';

class CustomRefreshIndicator extends StatefulWidget {
  final Widget child;
  final RefreshCallback onRefresh;

  const CustomRefreshIndicator({
    super.key,
    required this.child,
    required this.onRefresh,
  });

  @override
  State<CustomRefreshIndicator> createState() => _CustomRefreshIndicatorState();
}

class _CustomRefreshIndicatorState extends State<CustomRefreshIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1000),
    );
    _animation = Tween<double>(begin: 0, end: 1).animate(_controller);
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: widget.child,
      // 自定义刷新动画
      displacement: 40,
      color: Theme.of(context).primaryColor,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
```

2. **修改 bookshelf_screen.dart**
```dart
// 使用自定义刷新指示器
CustomRefreshIndicator(
  onRefresh: _refreshBookshelf,
  child: CustomScrollView(...),
)
```

3. **测试验证**
- [x] 打开书架
- [x] 下拉刷新
- [x] 验证刷新动画与 Android 一致
- [x] 验证刷新功能正常
- [x] 提交代码

**验收标准**:
- [x] 刷新动画与 Android 一致
- [x] 刷新功能正常

**预计工时**: 2 天  
**风险等级**: 中  
**依赖关系**: 无

---

### 任务 2.4-2.8: 其他 P2 差异修复

由于篇幅限制，以下任务的详细实施步骤省略，但提供关键信息：

#### 任务 2.4: 优化阅读器翻页动画效果（P2-4）
- **文件**: `reader_screen.dart`
- **工时**: 3 天
- **风险**: 高
- **关键**: 分析 Android 翻页动画源码，调整 Flutter 动画参数
- **状态**: ✅ 已完成（300ms + linear，与安卓 PageDelegate 一致）

#### 任务 2.5: 优化搜索框样式（P2-5）
- **文件**: `search_screen.dart`
- **工时**: 1 天
- **风险**: 低
- **关键**: 调整圆角、边框、内边距、图标
- **状态**: ✅ 已完成（35dp 胶囊 + 半透明填充 + 0.5dp 描边）

#### 任务 2.6: 优化 RSS 列表项样式（P2-6）
- **文件**: `rss_screen.dart`
- **工时**: 1 天
- **风险**: 低
- **关键**: 调整布局、间距、分割线
- **状态**: ✅ 已完成（4 列网格 + 50x50 圆角图标居中）

#### 任务 2.7: 优化设置项样式（P2-7）
- **文件**: `settings_screen.dart`
- **工时**: 2 天
- **风险**: 中
- **关键**: 使用 `flutter_settings_ui` 包或自定义样式
- **状态**: ✅ 已关闭（评估结论：与安卓端一致，无需调整）

#### 任务 2.8: 优化发现界面样式（P2-8）
- **文件**: `explore_screen.dart`
- **工时**: 1 天
- **风险**: 低
- **关键**: 调整列表项和搜索框样式
- **状态**: ✅ 已完成（AppBar 内嵌搜索框 + 扁平列表项）

---

## 阶段 3: 验收和发布（第 4 周，4 天）

### 任务 3.1: 全面测试（Day 18-19）

**测试范围**:
- [ ] 所有 P1 修复项功能测试
- [ ] 所有 P2 修复项功能测试
- [ ] 回归测试（确保原有功能不受影响）
- [ ] 功能一致性检查（功能入口、交互流程逐项对照原版）
- [ ] 性能测试（确保无性能下降）
- [ ] 兼容性测试（不同设备和系统版本）

**测试方法**:
1. 手动测试所有修复项
2. 运行自动化测试套件
3. 截图对比工具检查界面功能与布局一致性
4. 性能分析工具检查性能

**验收标准**:
- [ ] 所有测试通过
- [ ] 无编译错误和警告
- [ ] 功能一致性 100%（功能入口与交互流程对齐原版）；视觉风格不纳入验收（见顶部标准修订声明）
- [ ] 无性能下降

---

### 任务 3.2: 修复发现的问题（Day 20）

**修复流程**:
1. 收集测试中发现的问题
2. 按优先级排序
3. 修复关键问题
4. 重新测试验证

**预计修复时间**: 1 天

---

### 任务 3.3: 发布新版本（Day 21）

**发布流程**:
1. 更新版本号
2. 更新 CHANGELOG.md
3. 创建 Git tag
4. 构建 Release 版本
5. 发布到应用商店

**预计发布时间**: 1 天

---

## 风险缓解策略

### 技术风险

#### 风险 1: 翻页动画效果难以完全匹配
**缓解措施**:
- 提前分析 Android 翻页动画源码
- 与 Android 开发团队沟通实现细节
- 预留额外时间进行调优
- 如果无法完全匹配，确保视觉效果接近

#### 风险 2: 系统亮度调节平台通道不稳定
**缓解措施**:
- 充分测试不同设备和系统版本
- 添加异常处理和降级逻辑
- 提供手动亮度作为备选方案
- 在文档中说明已知限制

#### 风险 3: 分类筛选功能影响搜索性能
**缓解措施**:
- 优化筛选算法
- 使用索引加速查询
- 添加加载指示器
- 进行性能测试

### 时间风险

#### 风险 1: P1 修复超时
**缓解措施**:
- 优先修复低风险项（P1-1）
- 中风险项（P1-2, P1-3, P1-4）并行开发
- 如果超时，先发布 P1-1，其他延后

#### 风险 2: P2 修复超时
**缓解措施**:
- P2 修复可分批发布
- 优先修复低风险项（P2-1, P2-5, P2-6, P2-8）
- 高风险项（P2-2, P2-4）可延后到下一版本

### 资源风险

#### 风险 1: 缺乏设计资源
**缓解措施**:
- 提前准备设计资源
- 如果无法获得，使用 Material Icons 作为临时方案
- 在文档中说明需要后续优化

#### 风险 2: 缺乏 Android 源码访问
**缓解措施**:
- 提前获取 Android 源码访问权限
- 与 Android 开发团队建立沟通渠道
- 准备详细的实现文档

---

## 依赖关系图

```
P1-1 (Tab 名称) ─────┐
                      ├──> P2-1 (Tab 标签) ──> P2-2 (Tab 图标)
P1-2 (翻页模式) ─────┤
                      ├──> P2-4 (翻页动画)
P1-3 (系统亮度) ─────┘

P1-4 (分类筛选) ─────┐
                      ├──> P2-5 (搜索框样式)
                      │
P2-3 (书架刷新) ─────┘

P2-6 (RSS 列表) ─────┐
                      ├──> P2-8 (发现界面)
P2-7 (设置项) ───────┘
```

**关键路径**: P1-1 → P2-1 → P2-2（Tab 导航系列）

---

## 里程碑

### M1: P1 修复完成（第 1 周末）
- [x] 所有 P1 差异已修复
- [x] P1 修复项已测试
- [x] P1 修复项已提交

### M2: P2 修复完成（第 3 周末）
- [x] 所有 P2 差异已修复
- [x] P2 修复项已测试
- [x] P2 修复项已提交

### M3: 全面测试完成（第 4 周中）
- [ ] 所有测试通过
- [ ] 发现的问题已修复
- [ ] 功能一致性 100%（功能入口与交互流程对齐原版）；视觉风格不纳入验收（见顶部标准修订声明）

### M4: 新版本发布（第 4 周末）
- [ ] 版本号已更新
- [ ] CHANGELOG.md 已更新
- [ ] Git tag 已创建
- [ ] Release 版本已构建
- [ ] 已发布到应用商店

---

## 沟通计划

### 每日站会
- **时间**: 每天上午 10:00
- **参与**: 开发团队、测试团队、项目经理
- **内容**: 
  - 昨日完成工作
  - 今日计划工作
  - 遇到的问题和风险

### 周报
- **时间**: 每周五下午 5:00
- **参与**: 项目干系人
- **内容**:
  - 本周完成工作
  - 下周计划工作
  - 风险和缓解措施
  - 里程碑达成情况

### 里程碑评审
- **时间**: 每个里程碑结束时
- **参与**: 项目干系人、开发团队、测试团队
- **内容**:
  - 里程碑达成情况
  - 质量评估
  - 风险评估
  - 下一步计划

---

## 变更管理

### 变更请求流程
1. 提交变更请求（CR）
2. 评估变更影响
3. 审批变更请求
4. 实施变更
5. 测试变更
6. 发布变更

### 变更控制委员会（CCB）
- **成员**: 项目经理、技术负责人、测试负责人
- **职责**: 审批变更请求，评估变更影响
- **会议**: 每周三下午 2:00

---

## 质量保证

### 代码质量
- [ ] 代码符合项目编码规范
- [ ] 代码已进行静态分析
- [ ] 代码已进行单元测试
- [ ] 代码已进行代码审查

### 测试质量
- [ ] 测试用例覆盖所有修复项
- [ ] 测试用例已执行
- [ ] 所有缺陷已修复
- [ ] 回归测试已通过

### 文档质量
- [ ] 设计文档已更新
- [ ] 用户手册已更新
- [ ] API 文档已更新
- [ ] CHANGELOG.md 已更新

---

## 附录

### A. 文件清单

#### 新建文件
1. `flutter_legado/lib/src/services/system_brightness.dart`
2. `flutter_legado/lib/src/widgets/search_filter_panel.dart`
3. `flutter_legado/lib/src/widgets/custom_refresh_indicator.dart`
4. `flutter_legado/assets/icons/ic_bottom_books.svg`
5. `flutter_legado/assets/icons/ic_bottom_explore.svg`
6. `flutter_legado/assets/icons/ic_bottom_rss_feed.svg`
7. `flutter_legado/assets/icons/ic_bottom_person.svg`

#### 修改文件
1. `flutter_legado/lib/src/screens/home_screen.dart`
2. `flutter_legado/lib/src/screens/reader_screen.dart`
3. `flutter_legado/lib/src/screens/search_screen.dart`
4. `flutter_legado/lib/src/screens/bookshelf_screen.dart`
5. `flutter_legado/lib/src/screens/rss_screen.dart`
6. `flutter_legado/lib/src/screens/settings_screen.dart`
7. `flutter_legado/lib/src/screens/explore_screen.dart`
8. `flutter_legado/lib/src/widgets/reader_config_panel.dart`
9. `flutter_legado/lib/src/models/reader_config.dart`
10. `flutter_legado/lib/src/l10n/app_strings.dart`
11. `flutter_legado/pubspec.yaml`
12. `flutter_legado/android/app/src/main/kotlin/io/legado/app/MainActivity.kt`

### B. 工具清单

#### 开发工具
- Flutter SDK 3.41.7
- Android Studio
- Visual Studio Code
- Git

#### 测试工具
- Flutter Test
- Flutter Integration Test
- Screenshot Comparison Tool
- Performance Analysis Tool

#### 设计工具
- Figma
- Adobe Illustrator
- Inkscape

### C. 参考文档

1. [UI_COMPARISON_REPORT.md](UI_COMPARISON_REPORT.md) - UI 对比分析报告
2. [UI_DIFFERENCE_PRIORITIES.md](UI_DIFFERENCE_PRIORITIES.md) - 差异优先级分类文档
3. [KOTLIN_SYNC_REPORT.md](KOTLIN_SYNC_REPORT.md) - Kotlin 代码同步报告
4. [MIGRATION_WORKFLOW.md](../rust/MIGRATION_WORKFLOW.md) - 数据库迁移工作流

---

## UI 缺口修复批次（2026-08-06）

> **背景**：2026-08-06 Flutter UI 功能缺口实测审计（约 92 项：P0 2 / P1 44 / P2 46）与 Rust 源码级复查（4 项 P1 实质缺口）。本批次将 P0/P1 UI 缺口列为可执行任务清单；台账总览见 [REFACTORING_REMAINING_PLAN.md §5](REFACTORING_REMAINING_PLAN.md)，量化统计见 [REFACTORING_AUDIT_REPORT_20260806.md](REFACTORING_AUDIT_REPORT_20260806.md)。
>
> ✅ **批次状态（2026-08-06，Task #119 回写）**：批次 0-3 已全部完成——批次0 `0cde41a5c`（v2.0.1）/ 批次1 `873abea29`（v2.0.1）/ 批次2 `522e1c1be`（v2.0.2，含 Rust 前置 `b7368193a`、`9ac94b173`）/ 批次3 `13a11220e`（v2.0.3，含治理 `6633c25e3`、`0c452f4b5`）。留项清单见审计报告 §7。
>
> **验收基准**：按顶部标准修订声明——功能、页面结构与交互流程对齐 Android 原版，视觉风格不纳入验收。
>
> **FFI 铁律**：依赖新契约的批次，先查 [API_CONTRACT.md](API_CONTRACT.md)；新增 FFI 须先冻结契约再实施（[TWO_TRACK_DEV_SPEC.md](TWO_TRACK_DEV_SPEC.md)）。

### 批次 0：纯接线快赢（无 FFI 阻塞，立即可做，合计 ≤2d）——✅ 已完成（`0cde41a5c`，2026-08-06）

| # | 任务 | 依赖 | 工时 |
|---|------|------|------|
| 0-1 | 6 处日志入口接线（AppLogScreen 路由已存在，appLog* FFI 已交付，API_CONTRACT §2.38） | 无 | ≤0.5d |
| 0-2 | 朗读配置页入口：`read_aloud_config_screen.dart` 孤儿页补入口（阅读器底栏/设置页） | 无（管线接通为 P0-2 后续） | ≤0.5d |
| 0-3 | 替换规则导入接已有确认页（3 种导入通道复用现有确认页组件） | 无 | ≤0.5d |
| 0-4 | 翻页动画菜单（菜单项接既有翻页模式配置） | 无 | ≤0.5d |

### 批次 1：P0 专项（5-8 人日）——✅ 已完成（`873abea29`，2026-08-06）

#### 任务 B1-1：阅读器正文长按选择 + 9 项操作菜单（3-5d）

**目标**：对齐 ReadBookActivity 正文长按动作菜单（复制/书签/高亮/词典/朗读/搜正文等 9 项）

**涉及文件**：`reader_text_content.dart`、新增选择动作菜单 widget、`reader_notifier.dart`

**实施要点**：
1. 正文渲染接入可选中文本（SelectableText 或自建选择层，需兼容排版引擎分页结果）
2. 选择后弹出 9 项动作菜单，逐项接线：
   - 复制：Clipboard
   - 书签：bookmark* FFI（已有）
   - 高亮：highlight* 11 方法（API_CONTRACT §2.36，已交付）
   - 词典：dictLookup（已交付）
   - 朗读：跳转朗读链路（依赖 B1-2 与 Rust audioSpeak 管线）
   - 搜正文：txtSearch 系列（API_CONTRACT §2.40，本地书）/ 在线书走 search_content
3. 补 widget 测试

**FFI 依赖**：无契约阻塞（highlight*/dictLookup/bookmark* 均已交付）

**验收**：长按选中正文 → 9 项动作均可用，行为对齐原版

#### 任务 B1-2：阅读器底栏朗读按钮 + 朗读配置页接通（2-3d）

**目标**：底栏朗读按钮从存根变为可用；`read_aloud_config_screen.dart` 接通并可用

**实施要点**：
1. 底栏朗读按钮接 ReadAloud 状态机（启动/暂停/停止/跳转配置页）
2. 朗读配置页接引擎选择/语速/定时等配置持久化（getConfig/setConfig）
3. TTS 播报管线：UI 侧先完成界面与状态机；**真实播报依赖 Rust P1 缺口 audioSpeak TTS 管线**（现 `rust_api.dart` L1431 仅 http.get 探活，被 audio_notifier 实际调用，跨轨 3-5d）

**FFI 依赖**：⚠️ audioSpeak 真实管线为跨轨阻塞项（已在 API_CONTRACT §2.26 登记 audioSpeak 方法，需 Rust 轨补真实实现）；UI 可先行，管线交付后接通

**验收**：底栏按钮可启动/控制朗读；配置页可选引擎与语速；管线交付后可真实播报

### 批次 2：P1 批量（44 项，按屏幕分组，预计 3-4 周）——✅ 已完成（`522e1c1be`，2026-08-06）

> 前置已交付：Rust ① nextContentUrl 与 ④ rssUpdateSource（`b7368193a`）、② audioSpeak 真实管线（`9ac94b173` + 本批接线）、③ WebView 拦截（本批 platform_bridge_service.dart）。留项：编辑内容/反转内容持久化（待 saveChapterContent FFI）、章节购买（待 payAction FFI）、MoreConfig 其余项。

| 批次 | 屏幕/模块 | 任务（缺口功能） | 依赖的 FFI 契约 |
|------|-----------|------------------|------------------|
| B2-1 阅读器 | 顶栏 | 溢出菜单 10 项落地（编辑内容/替换规则开关/更新目录等） | 替换规则开关用既有 replaceRule*；更新目录用 refreshToc；编辑内容需确认内容编辑契约 |
| B2-1 阅读器 | 底部 | 源操作菜单（登录源/章节购买/编辑源/禁用源） | 登录 UI V2 三件套已交付未封装（API_CONTRACT §3 待封装清单，需 BookApi 封装后接入） |
| B2-1 阅读器 | 配置 | 阅读配置面板 5 项（字体/字距/首行缩进/简繁/MoreConfig） | 简繁用 setChineseConvertType（已交付）；其余无契约阻塞 |
| B2-2 缓存 | 离线缓存 | 顶栏缓存 + 书架缓存导出（对应 CacheActivity） | cache 系列已有；cacheGetChapter 已实现待封装（API_CONTRACT §2.41） |
| B2-3 书架/详情 | 书架 | 更新目录假动作修复/添加网址/书单导入导出行为对齐 | refreshToc + 既有 import/export |
| B2-3 书架/详情 | 书详情 | 登录/置顶/清缓存 3 项 | topBook/clearCache 已有；登录依赖登录 UI V2 封装 |
| B2-4 RSS | 文章列表 | 菜单 6 项 + 详情收藏按钮 | 收藏用既有 rssStar*；源更新依赖 rssUpdateSource 原子 FFI（Rust P1 ④，替代删+加 workaround） |
| B2-5 规则/换源 | 替换规则页 | 分组筛选 + 3 种导入 + 批量操作 | 导入接已有确认页（纯接线）；批量用既有 replaceRule* |
| B2-5 规则/换源 | 换源页 | 高级选项 8 项 | 既有 searchSource/switchSource |
| B2-6 听书/设置 | 听书 | 溢出菜单（换源/缓存/wakelock） | 换源用 searchSource；wakelock 为纯 Flutter 插件项 |
| B2-6 听书/设置 | 设置 | Web 服务/定时服务开关 | serverStart/serverStop 已有（rust_api.dart 占位清理见 REMAINING_PLAN §4.3 P1-1） |
| B2-6 听书/设置 | 书架管理 | 批量换源等 | 既有 switchSource 循环 |

**验收**：逐屏幕对照 Android 原版菜单/交互逐项核销；每批附 widget 测试；`flutter analyze` 0 issues + `flutter test` 全量通过。

### 批次 3：P2 收尾（46 项，随迭代消化，预计 2 周）——✅ 已完成（`13a11220e`，2026-08-06）

- 优先消化：6 处日志入口（已入批次 0）、编码/字距/边距参数、导入排序、自动任务菜单
- 结构治理：删除 `rss_config_screen.dart`（与 `rss_source_manage_screen.dart` 重复，前者 5 存根），删除前核销替代覆盖
- 逐条明细见综合报告附录；完成一项即在 [REFACTORING_REMAINING_PLAN.md §5](REFACTORING_REMAINING_PLAN.md) 销记一项

### 跨轨依赖汇总（本批次）

| 依赖项 | 提供方 | 阻塞的 UI 任务 | 状态 |
|--------|--------|------------------|------|
| audioSpeak TTS 真实管线（3-5d） | Rust 轨 | B1-2 真实播报 | ✅ 已交付（`9ac94b173` + `522e1c1be` 接线） |
| nextContentUrl 分页抓取（2-3d） | Rust 轨 | 阅读器正文完整性（分页书源） | ✅ 已交付（`b7368193a`） |
| rssUpdateSource 原子 FFI（0.5d） | Rust 轨 | B2-4 RSS 源编辑 | ✅ 已交付（`b7368193a`） |
| WebView 桥接载荷 Flutter 侧拦截（2-3d） | 跨轨 | 书源 WebView 交互类功能 | ✅ 已交付（`522e1c1be`） |
| 登录 UI V2 三件套 BookApi 封装 | UI 轨（FFI 已交付） | B2-1 源登录、B2-3 书详情登录 | ✅ 已接通（书详登录接 V2 动态协议+旧版凭据页，`522e1c1be`） |

---

**文档生成时间**: 2026-08-06  
**文档版本**: v2.2（批次0-3 全部完成销记，Task #119）  
**下次更新**: 留项（审计报告 §7）闭合后销记更新
