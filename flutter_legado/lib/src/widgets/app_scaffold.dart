import 'package:flutter/material.dart';

/// Legado 统一页壳（对齐参考版 `AppScaffold` 语义的轻量子集）
///
/// [GLOBALCOMP B4] 参考版 `AppScaffold`（59 文件引用）是统一页壳：HazeState
/// 模糊采样 + 液态玻璃 backdrop + 背景图透明化 + edge-to-edge + snackbarHost
/// + FAB 位。本项目走「主题层统一」，其中多数语义已由既有基建承担，本壳
/// **不重复实现**，仅提供结构收敛点：
///
/// - **背景**：由 `ThemeData.scaffoldBackgroundColor` 统一供给（app_theme）。
///   设置背景图时 app.dart 将其置为透明以露出全局壁纸层（P1-8），故
///   [backgroundColor] 默认 null（跟随主题），**勿在无特殊语义处硬编码色值**。
/// - **系统栏**：`SystemBarBinder`（app.dart 单点）统一同步状态栏/导航栏；
///   顶栏透明度/毛玻璃由 `LegadoAppBar` 承担。
/// - **snackbarHost**：MaterialApp 级 ScaffoldMessenger 已提供全局宿主
///   （跨页 SnackBar 归位），等价参考版 `snackbarHost` 语义，无需页壳参数。
/// - **液态玻璃/模糊采样**：不做（维持 TopBarButton 实色回退既有裁决；
///   做真模糊属新特性，须用户批准）。
///
/// 参数面对齐参考版命名：[topBar]≈`topBar`、[bottomBar]≈`bottomBar`、
/// [floatingActionButton]≈`floatingActionButton(+Position)`、[body] 承载
/// `content`。**只收敛主流形态**（appBar+body，可带底栏/FAB/背景色，
/// 盘点占比 60/70）；`extendBody`/`extendBodyBehindAppBar`/`drawer`/
/// `resizeToAvoidBottomInset` 等非主流参数不提供，需要时用原生 Scaffold
/// 并在统一批台账登记。
///
/// 本壳对参数**零改写**直通 `Scaffold`，迁移点视觉/交互逐参数等价
/// （widget 测试 test/widget/app_scaffold_test.dart 有同构等价用例）。
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    this.topBar,
    this.bottomBar,
    required this.body,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.backgroundColor,
  });

  /// 顶栏（映射 `Scaffold.appBar`）；null = 无顶栏（首页容器/我的等根页）。
  /// 典型值：LegadoAppBar、DynamicSearchAppBar（均为 PreferredSizeWidget）。
  final PreferredSizeWidget? topBar;

  /// 底栏（映射 `Scaffold.bottomNavigationBar`）。典型值：NavigationBar、
  /// 自绘底栏、SafeArea 包裹的批量操作条。
  final Widget? bottomBar;

  /// 页面主体（映射 `Scaffold.body`）。
  final Widget body;

  /// 悬浮操作钮（映射 `Scaffold.floatingActionButton`）。
  final Widget? floatingActionButton;

  /// FAB 位置（映射 `Scaffold.floatingActionButtonLocation`）。
  final FloatingActionButtonLocation? floatingActionButtonLocation;

  /// 页背景色；null = 跟随主题（推荐；背景图透明策略依赖此项为 null）。
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: topBar,
      bottomNavigationBar: bottomBar,
      body: body,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      backgroundColor: backgroundColor,
    );
  }
}
