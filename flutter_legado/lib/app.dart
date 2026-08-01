import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/providers/theme_provider.dart';
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
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, _) {
        return MaterialApp(
          title: 'Legado',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          // 主题模式由 ThemeProvider 驱动（亮/暗/跟随系统，全局实时切换）
          themeMode: themeProvider.themeMode,
          // 全局统一滚动物理（BouncingScrollPhysics，对齐安卓原版回弹手感）
          scrollBehavior: AppScrollBehavior(),
          // 全局字体缩放：对齐原版 AppContextWrapper.getFontScale
          // （fontScale 为 null 表示跟随系统，不覆盖平台缩放）
          builder: (context, child) {
            final scale = themeProvider.fontScale;
            if (scale == null) return child!;
            return MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            );
          },
          initialRoute: widget.initialRoute,
          routes: AppRoutes.routes,
        );
      },
    );
  }
}
