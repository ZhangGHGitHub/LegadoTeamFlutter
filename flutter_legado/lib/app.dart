import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import 'src/providers/providers.dart';
import 'src/providers/ui_settings/ui_settings_notifier.dart';
import 'src/providers/theme/theme_colors_notifier.dart';
import 'src/providers/theme/theme_notifier.dart';
import 'src/routes.dart';
import 'src/services/auto_task_scheduler.dart';
import 'src/services/deep_link_service.dart';
import 'src/services/platform_bridge_service.dart';
import 'src/theme/app_theme.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'src/theme/md3_colors.dart';
import 'src/utils/app_route_observer.dart';
import 'src/utils/app_scroll_behavior.dart';
import 'src/widgets/system_bar_binder.dart';
import 'src/widgets/crash_log_dialog.dart';
import 'src/widgets/verification_code_listener.dart';
import 'src/widgets/webview_bridge_listener.dart';

/// Legado App 入口 Widget
class LegadoApp extends ConsumerStatefulWidget {
  /// 初始路由（冷启动为闪屏 /welcome，对齐 WelcomeActivity）
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
    // 系统栏样式由 [SystemBarBinder] 按偏好与主题统一驱动
    // 首帧渲染后检查上次崩溃日志并弹窗提示
    if (widget.lastCrashLog != null && widget.lastCrashLog!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          CrashLogDialog.show(context, widget.lastCrashLog!);
        }
      });
    }
    // [UI-fix v2.0.3 | 2026-08-08] 定时任务应用内调度器启动装配
    //（Task #146，对齐原版 App.kt 启动时 AutoTaskScheduler.refresh；
    // 引擎已在 main.dart 先行初始化，此处可直接注入 BookApi） — QoderCN
    AutoTaskScheduler.instance.attach(ref.read(bookApiProvider));
    // P1-11：监听系统 legado:// / yuedu:// 深链 → Association
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DeepLinkService.instance.attach(PlatformBridgeService.navigatorKey);
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeNotifierProvider);
    // [UI-FIX v2.0.5 | 2026-08-08] 自定义主题颜色接入 MaterialApp（对齐原版
    // ThemeConfigFragment 日间/夜间颜色配置，设置页修改后全局即时生效） — Qoder
    final themeColors = ref.watch(themeColorsProvider);
    Color? c(int? argb) => argb != null ? Color(argb) : null;

    // [MD3 Batch 0 | 2026-08-28] 按 paletteId 装配内置 MD3 调色板
    //（默认 WH；自定义 themeConfigList 4 色仍可叠加，自定义已应用色优先
    // 于内置 palette role——UI_MD3_PLAN.md 第九节并存模型） — Qoder UI
    final palette = Md3Palettes.byId(themeState.paletteId);

    // P1-8：有背景图时 Scaffold 透明，露出全局壁纸层（对齐原版
    // BaseActivity.upBackgroundImage → decorView.background）
    // [UI_SYNC_REFACTOR R1] 跟随壁纸取色（Material You）：开关开启且系统
    // 提供动态色板时，primary/accent 取动态色 role，其余 role 沿用内置
    // palette；关闭或无动态色板时维持原并存模型（自定义四色 > palette）
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final uiSettings = ref.watch(uiSettingsProvider);
    final followWallpaper = uiSettings.wallpaperColorFollow;
    final lightTheme = _withOptionalTransparentScaffold(
      AppTheme.palette(
        brightness: Brightness.light,
        palette: palette,
        primary: followWallpaper ? lightDynamic?.primary : c(themeColors.primary),
        accent: followWallpaper ? lightDynamic?.tertiary : c(themeColors.accent),
        background: followWallpaper ? null : c(themeColors.background),
        bottomBackground:
            followWallpaper ? null : c(themeColors.bottomBackground),
      ),
      themeColors.bgImage,
    );
    final darkTheme = _withOptionalTransparentScaffold(
      AppTheme.palette(
        brightness: Brightness.dark,
        palette: palette,
        primary:
            followWallpaper ? darkDynamic?.primary : c(themeColors.primaryNight),
        accent:
            followWallpaper ? darkDynamic?.tertiary : c(themeColors.accentNight),
        background: followWallpaper ? null : c(themeColors.backgroundNight),
        bottomBackground:
            followWallpaper ? null : c(themeColors.bottomBackgroundNight),
      ),
      themeColors.bgImageNight,
    );

    return MaterialApp(
      title: 'Legado',
      // [UI-FIX v2.0.2 | 2026-08-06] 平台桥接服务经此 Key 分发页面跳转 / SnackBar
      //（Task #114，服务层无 BuildContext） — QoderCN
      navigatorKey: PlatformBridgeService.navigatorKey,
      // [UI-FIX v2.0.7 | 2026-08-09] 全局路由观察器（Task #26）：目录页等
      // 「返回重现需刷新」的页面经 RouteAware 订阅，从阅读器返回时
      // 即时刷新缓存云图标/当前章节（对齐原版 SAVE_CONTENT 事件刷新）
      navigatorObservers: [appRouteObserver],
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      // 主题模式由 ThemeNotifier 驱动（亮/暗/跟随系统，全局实时切换）
      themeMode: themeState.themeMode,
      // 全局统一滚动物理（BouncingScrollPhysics，对齐安卓原版回弹手感）
      scrollBehavior: AppScrollBehavior(),
      // 全局字体缩放：对齐原版 AppContextWrapper.getFontScale
      // （fontScale 为 null 表示跟随系统，不覆盖平台缩放）
      builder: (context, child) {
        final scale = themeState.fontScale;
        // 全局验证码请求监听（对标原版 SourceVerificationHelp 全局监听，
        // 书源 JS 挂起等待验证码时跨页面弹窗）
        Widget wrapped = VerificationCodeListener(child: child!);
        // BackstageWebView DOM 通道（@webjs / 正文 webJs / java.webView*）
        wrapped = WebViewBridgeListener(child: wrapped);
        // 沉浸式状态栏 / 导航栏：对齐原版 transparentStatusBar / immNavigationBar
        wrapped = SystemBarBinder(child: wrapped);
        // P1-8：按当前亮度叠全局背景图（分组卡片仍自带不透明底，可读性保留）
        wrapped = _ThemeBackgroundLayer(
          path: themeColors.bgImageFor(Theme.of(context).brightness),
          child: wrapped,
        );
        if (scale == null) return wrapped;
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: wrapped,
        );
      },
      initialRoute: widget.initialRoute,
      // [UI-fix v2.0.167] routes map → onGenerateRoute：命名路由统经
      // AppRoutes.generateRoute 构建，Android 上按分档覆盖转场时长
      onGenerateRoute: AppRoutes.generateRoute,
        );
      },
    );
  }

  /// 本地背景图可用时让 Scaffold 透明，露出下层壁纸
  ThemeData _withOptionalTransparentScaffold(ThemeData base, String path) {
    if (!_bgFileUsable(path)) return base;
    return base.copyWith(scaffoldBackgroundColor: Colors.transparent);
  }
}

/// 全局主题背景图层（对齐原版 ThemeConfig.getBgImage）
class _ThemeBackgroundLayer extends StatelessWidget {
  final String path;
  final Widget child;

  const _ThemeBackgroundLayer({required this.path, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!_bgFileUsable(path)) return child;
    return DecoratedBox(
      decoration: BoxDecoration(
        image: DecorationImage(
          image: FileImage(File(path)),
          fit: BoxFit.cover,
          alignment: Alignment.center,
        ),
      ),
      child: child,
    );
  }
}

bool _bgFileUsable(String path) {
  if (kIsWeb || path.isEmpty) return false;
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}
