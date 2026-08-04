import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import 'src/providers/theme/theme_notifier.dart';
import 'src/routes.dart';
import 'src/theme/app_theme.dart';
import 'src/utils/app_scroll_behavior.dart';
import 'src/widgets/crash_log_dialog.dart';

/// Legado App 入口 Widget
class LegadoApp extends ConsumerStatefulWidget {
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
  ConsumerState<LegadoApp> createState() => _LegadoAppState();
}

class _LegadoAppState extends ConsumerState<LegadoApp> {
  @override
  void initState() {
    super.initState();
    // 无 AppBar 页面（欢迎页/阅读器全屏等）的状态栏图标兜底样式：
    // 页面背景为浅色，图标用深色，避免白底白图标全白不可见。
    // 有 AppBar 的页面由 AppBarTheme.systemOverlayStyle 覆盖为白色图标。
    // 注意：不设置 statusBarColor——状态栏底色由 Android 主题
    // （styles.xml android:statusBarColor，primaryDark 色）固化，
    // 此处若传 transparent 会在运行时覆盖主题色，导致顶部显示白色窗口背景。
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ));
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
    final themeState = ref.watch(themeNotifierProvider);
    return MaterialApp(
      title: 'Legado',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      // 主题模式由 ThemeNotifier 驱动（亮/暗/跟随系统，全局实时切换）
      themeMode: themeState.themeMode,
      // 全局统一滚动物理（BouncingScrollPhysics，对齐安卓原版回弹手感）
      scrollBehavior: AppScrollBehavior(),
      // 全局字体缩放：对齐原版 AppContextWrapper.getFontScale
      // （fontScale 为 null 表示跟随系统，不覆盖平台缩放）
      builder: (context, child) {
        final scale = themeState.fontScale;
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
  }
}
