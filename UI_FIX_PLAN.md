# Legado UI 修复详细计划

**计划日期**: 2026-07-30  
**计划目标**: 修复 Flutter 重构界面与原版 Android 界面的差异  
**计划范围**: P1 和 P2 优先级差异（共 12 项）  
**预计工时**: 20.5 天（4 周）

---

## 修复概览

### 修复目标
- 修复 4 项 P1 重要差异
- 修复 8 项 P2 次要差异
- 视觉一致性达到 90% 以上
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
- [ ] 启动应用
- [ ] 验证第 4 个 Tab 显示"我的"
- [ ] 切换到该 Tab，功能正常
- [ ] 提交代码

**验收标准**:
- [ ] 第 4 个 Tab 显示"我的"
- [ ] 用户可正常切换到该 Tab
- [ ] 功能不受影响

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
- [ ] 打开阅读器
- [ ] 进入设置面板
- [ ] 选择"无动画"模式
- [ ] 翻页验证无动画效果
- [ ] 切换到其他模式，功能正常
- [ ] 提交代码

**验收标准**:
- [ ] 设置面板显示 4 种翻页模式
- [ ] 选择"无动画"后翻页无动画效果
- [ ] 其他翻页模式不受影响

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
- [ ] 打开阅读器
- [ ] 进入亮度调节面板
- [ ] 验证"系统亮度"开关显示
- [ ] 开启系统亮度，验证跟随系统
- [ ] 关闭系统亮度，验证手动调节
- [ ] 提交代码

**验收标准**:
- [ ] 亮度面板显示"系统亮度"开关
- [ ] 开启后跟随系统亮度
- [ ] 关闭后使用手动亮度

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
- [ ] 打开搜索界面
- [ ] 验证分类筛选器显示
- [ ] 选择多个分类
- [ ] 验证搜索结果根据分类筛选
- [ ] 清除分类，验证结果更新
- [ ] 提交代码

**验收标准**:
- [ ] 搜索界面显示分类筛选器
- [ ] 可选择多个分类
- [ ] 搜索结果根据分类筛选

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
- [ ] 启动应用
- [ ] 验证标签文字隐藏
- [ ] 切换到不同 Tab，功能正常
- [ ] 提交代码

**验收标准**:
- [ ] 标签文字显示方式与 Android 一致
- [ ] 不影响 Tab 切换功能

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
- [ ] 启动应用
- [ ] 验证图标显示正确
- [ ] 切换到不同 Tab，图标状态正确
- [ ] 在不同主题下图标显示正常
- [ ] 提交代码

**验收标准**:
- [ ] 图标与 Android 版本视觉一致
- [ ] 图标在不同主题下显示正常

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
- [ ] 打开书架
- [ ] 下拉刷新
- [ ] 验证刷新动画与 Android 一致
- [ ] 验证刷新功能正常
- [ ] 提交代码

**验收标准**:
- [ ] 刷新动画与 Android 一致
- [ ] 刷新功能正常

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

#### 任务 2.5: 优化搜索框样式（P2-5）
- **文件**: `search_screen.dart`
- **工时**: 1 天
- **风险**: 低
- **关键**: 调整圆角、边框、内边距、图标

#### 任务 2.6: 优化 RSS 列表项样式（P2-6）
- **文件**: `rss_screen.dart`
- **工时**: 1 天
- **风险**: 低
- **关键**: 调整布局、间距、分割线

#### 任务 2.7: 优化设置项样式（P2-7）
- **文件**: `settings_screen.dart`
- **工时**: 2 天
- **风险**: 中
- **关键**: 使用 `flutter_settings_ui` 包或自定义样式

#### 任务 2.8: 优化发现界面样式（P2-8）
- **文件**: `explore_screen.dart`
- **工时**: 1 天
- **风险**: 低
- **关键**: 调整列表项和搜索框样式

---

## 阶段 3: 验收和发布（第 4 周，4 天）

### 任务 3.1: 全面测试（Day 18-19）

**测试范围**:
- [ ] 所有 P1 修复项功能测试
- [ ] 所有 P2 修复项功能测试
- [ ] 回归测试（确保原有功能不受影响）
- [ ] 视觉一致性检查（截图对比）
- [ ] 性能测试（确保无性能下降）
- [ ] 兼容性测试（不同设备和系统版本）

**测试方法**:
1. 手动测试所有修复项
2. 运行自动化测试套件
3. 截图对比工具检查视觉一致性
4. 性能分析工具检查性能

**验收标准**:
- [ ] 所有测试通过
- [ ] 无编译错误和警告
- [ ] 视觉一致性 > 90%
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
- [ ] 所有 P1 差异已修复
- [ ] P1 修复项已测试
- [ ] P1 修复项已提交

### M2: P2 修复完成（第 3 周末）
- [ ] 所有 P2 差异已修复
- [ ] P2 修复项已测试
- [ ] P2 修复项已提交

### M3: 全面测试完成（第 4 周中）
- [ ] 所有测试通过
- [ ] 发现的问题已修复
- [ ] 视觉一致性 > 90%

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
4. [MIGRATION_WORKFLOW.md](rust/MIGRATION_WORKFLOW.md) - 数据库迁移工作流

---

**文档生成时间**: 2026-07-30  
**文档版本**: v1.0  
**下次更新**: 完成 P1 差异修复后
