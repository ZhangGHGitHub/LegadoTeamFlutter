# Legado Flutter UI 一致性修复计划

> ✅ **全部完成**：本计划四阶段共 13 项任务已于 **2026-07-31 全部完成并验证通过**（Task #34-#41）。文档转入归档核销状态。

**计划日期**: 2026-07-31  
**完成日期**: 2026-07-31  
**文档版本**: v2.0（全部完成）  
**计划范围**: 布局适配、交互统一、样式规范、性能优化四大维度  
**关联文档**: [UI_COMPARISON_REPORT.md](UI_COMPARISON_REPORT.md) / [UI_FIX_PLAN.md](UI_FIX_PLAN.md) / [UI_FIX_SUMMARY.md](UI_FIX_SUMMARY.md) / [KOTLIN_LAYOUT_ANALYSIS.md](KOTLIN_LAYOUT_ANALYSIS.md) / [UI_REFACTORING_ANALYSIS_AND_SOLUTION.md](UI_REFACTORING_ANALYSIS_AND_SOLUTION.md)

---

## 背景与现状

依据 `docs/UI_COMPARISON_REPORT.md`、`docs/UI_FIX_PLAN.md`、`docs/UI_FIX_SUMMARY.md`、`docs/KOTLIN_LAYOUT_ANALYSIS.md` 及 `rust/PROGRESS.md` 的审计结论：

- P1/P2 差异修复已标记完成（Tab 名称、无动画翻页、系统亮度、分类筛选、仿真翻页 300ms 曲线等）
- 尚存的核心缺口：排版引擎渲染侧未整合（`paragraph_layout_engine.dart` 622 行算法已移植但 `reader_screen.dart` 仍用 Column+Text 简单分段）、响应式适配不完整、主题/字体规范未系统化、渲染与内存性能未做基准化管控
- 分析成果已汇总至 `docs/UI_REFACTORING_ANALYSIS_AND_SOLUTION.md`

> 📎 本计划已整合至 [REFACTORING_REMAINING_PLAN.md](REFACTORING_REMAINING_PLAN.md) 的「UI 一致性修复（整合 UI_CONSISTENCY_FIX_PLAN.md）」章节，状态映射与执行顺序见该章节。

---

## 阶段一：布局适配（优先级 P0，约 1 周）——✅ 已完成

### 1.1 响应式网格布局 ✅（Task #35）

- 文件：`flutter_legado/lib/src/screens/bookshelf_screen.dart`、`rss_screen.dart`、`explore_screen.dart`
- 将 `SliverGridDelegateWithFixedCrossAxisCount`（固定列数）替换为 `SliverGridDelegateWithMaxCrossAxisExtent`，配合 `LayoutBuilder` 按可用宽度自适应（手机 2-3 列 / 平板 4+ 列）
- 新建公共工具 `flutter_legado/lib/src/utils/responsive.dart`：统一断点定义（<400 / 400-600 / >=600 dp）与宽高比计算

### 1.2 SafeArea 与安全边距 ✅（Task #36）

- 文件：`flutter_legado/lib/src/screens/home_screen.dart`（134 行）
- 底部 `NavigationBar` 与主体 `IndexedStack` 补充 SafeArea 处理，覆盖手势导航与刘海屏场景

### 1.3 阅读器排版引擎接线（对应 PROGRESS.md P0 项） ✅（Task #34）

- 文件：`flutter_legado/lib/src/screens/reader_screen.dart`（约 754 行处）
- 将 Column+Text 简单分段替换为已移植的 `paragraph_layout_engine.dart` 分页渲染，实现中文避头尾与两端对齐（对标 `TextChapterLayout.kt` 算法）
- 此项工作量最大（预估 2-3 周），可与其他阶段并行推进

---

## 阶段二：交互统一（优先级 P1，约 1 周）——✅ 已完成

### 2.1 翻页动画参数核对 ✅（Task #10 + Task #27）

- 文件：`flutter_legado/lib/src/screens/reader_screen.dart`、仿真翻页实现（已移植 SimulationPageDelegate.kt 贝塞尔算法）
- 回归验证 4 种翻页模式（仿真/滑动/覆盖/无动画）的动画时长（300ms）与曲线和安卓 PageDelegate 一致，补充翻页阴影效果

### 2.2 手势精确化 ✅（Task #37）

- 文件：`flutter_legado/lib/src/widgets/` 下书籍卡片组件
- 长按多选仅在封面区域生效，标题区域排除，消除误触

### 2.3 下拉刷新与滚动物理 ✅（Task #8 + Task #38）

- 统一 `RefreshIndicator` 的 displacement/颜色与安卓 SwipeRefreshLayout 视觉对齐
- 全局注册统一的 `ScrollBehavior`（BouncingScrollPhysics），保证各列表滚动手感一致

---

## 阶段三：样式规范（优先级 P1，约 1 周）——✅ 已完成

### 3.1 主题系统集中化 ✅（Task #39）

- 新建 `flutter_legado/lib/src/theme/app_theme.dart`：以安卓端 `app/src/main/res/values/colors.xml` 为唯一色值来源，定义 light/dark 双 ColorScheme（Material 3）
- 消除各 screen 内散落的硬编码颜色（如 `main.dart` L121-136、各 screen 中的内联 TextStyle）

### 3.2 排版层级统一 ✅（Task #39）

- 新建 `flutter_legado/lib/src/theme/app_typography.dart`：定义字号层级（28/22/18/16/14/12）与行高规范，接入 ThemeData.textTheme
- 各 screen 改为引用 `Theme.of(context).textTheme`，禁止内联 fontSize

### 3.3 Dark Mode 完整校验 ✅（Task #41）

- 对 42 个 screen 逐页核验暗色模式下的对比度（WCAG >= 4.5）与图标可见性
- 新增 `docs/design_system.md` 设计规范文档（颜色/字体/间距 token）

---

## 阶段四：性能优化（优先级 P1-P2，约 1 周）——✅ 已完成

### 4.1 图片缓存 ✅（Task #40）

- 引入 `cached_network_image`（pubspec.yaml），封面统一走内存+磁盘双缓存，设置 memCacheWidth/Height 防止大图解码
- 涉及：书架、搜索结果、换封面、RSS 列表

### 4.2 列表渲染优化 ✅（Task #40）

- 长列表项外包 `RepaintBoundary`、使用稳定 Key、开启合理 cacheExtent
- 静态组件补充 const 构造，消除 build 中临时对象创建

### 4.3 资源释放审计 ✅（Task #40）

- 审计各 Provider/Screen 的 dispose：Timer、StreamSubscription、WebSocket、AnimationController 是否全部释放（重点：reader、audio、video、comic 相关 screen）

### 4.4 性能基线 ✅（Task #40）

- 建立基准：冷启动 < 3s、列表滚动 FPS > 55、阅读器翻页无掉帧
- 新增 `flutter_legado/test/performance/` 基准测试

---

## 质量保证措施

1. 每项修改后运行 `flutter analyze`（0 issues 门禁）与 `flutter test`（现有 167 测试不回退）
2. 视觉一致性：以安卓 3.26073003 版本 `com.legado.app.release` 为 UI 基准截图对比，目标一致性 > 90%
3. 多尺寸设备测试矩阵：小屏手机 / 标准手机 / 大屏手机 / 平板（Windows 端为主要验证平台，参照项目环境约定）
4. 每阶段完成后同步更新 `UI_FIX_PLAN.md`、`UI_FIX_SUMMARY.md`、`PROGRESS.md` 三份文档
5. 代码审查清单：响应式布局使用、SafeArea 覆盖、主题 token 引用、dispose 完整性

---

## 执行顺序与依赖

- 阶段一 1.1/1.2 与阶段三 3.1/3.2 可并行（互不冲突：布局改 screen 结构，主题改样式引用）
- 阶段二依赖阶段一完成（避免同文件冲突：reader_screen.dart 先接排版引擎再调动画）
- 阶段四最后执行（在功能稳定基础上做性能收尾）
- 排版引擎接线（1.3）为最长关键路径，建议单独分支推进

```
阶段一 (1.1/1.2) ──┬──> 阶段二 (2.1/2.2/2.3) ──> 阶段四 (4.1-4.4)
阶段三 (3.1/3.2) ──┘
阶段一 (1.3 排版引擎) ────────（独立分支，并行推进）────────>
```

---

## 假设与约束

- 遵循项目"纯功能迁移"原则：严格复刻安卓原版视觉与交互，不引入新设计
- 旧 Android 代码（app/src）保持双轨并存，仅作为对照基准不做修改
- Rust 后端（rust/）本次不涉及改动；如排版引擎需要 zh_layout FFI 暴露，另行评估
- 全部注释与提交说明使用中文

---

**文档生成时间**: 2026-07-31  
**最后更新**: 2026-07-31（四阶段 13 项全部完成）  
**下次更新**: 归档，如有后续迭代另行记录
