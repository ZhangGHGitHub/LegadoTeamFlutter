import 'package:flutter/material.dart';

import 'src/routes.dart';
import 'src/theme/app_theme.dart';
import 'src/utils/app_scroll_behavior.dart';
import 'src/widgets/crash_log_dialog.dart';

/// Legado App 入口 Widget
class LegadoApp extends StatefulWidget {
  /// 初始路由（首次启动时为欢迎页）
  final String initialRoute;

  /// 上次崩溃日志内容（null 表示无崩溃记录）
  final String? lastCrashLog;

  const LegadoApp({
    super.key,
    this.initialRoute = AppRoutes.home,
    this.lastCrashLog,
  });

  @override
  State<LegadoApp> createState() => _LegadoAppState();
}

class _LegadoAppState extends State<LegadoApp> {
  @override
  void initState() {
    super.initState();
    // 首帧渲染后检查上次崩溃日志并弹窗提示
    if (widget.lastCrashLog != null && widget.lastCrashLog!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          CrashLogDialog.show(context, widget.lastCrashLog!);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Legado',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      // 全局统一滚动物理（BouncingScrollPhysics，对齐安卓原版回弹手感）
      scrollBehavior: AppScrollBehavior(),
      initialRoute: widget.initialRoute,
      routes: AppRoutes.routes,
    );
  }
}
