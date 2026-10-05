import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import 'src/models/models.dart';
import 'src/providers/providers.dart';
import 'src/providers/ui_settings/ui_settings_notifier.dart';
import 'src/providers/theme/theme_colors_notifier.dart';
import 'src/providers/theme/theme_notifier.dart';
import 'src/routes.dart';
import 'src/screens/video_screen.dart';
import 'src/services/auto_task_scheduler.dart';
import 'src/services/deep_link_service.dart';
import 'src/services/platform_bridge_service.dart';
import 'src/services/video_float_window.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/theme_engine_parameterized.dart';
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

  /// 弹出「上次运行发生崩溃」提示弹窗（[P2-13 2026-09-18]）。
  ///
  /// 弹窗必须挂在 [MaterialApp.navigatorKey]（即
  /// [PlatformBridgeService.navigatorKey]，见 [build]）的 **Navigator 自身
  /// context** 上，而不是构建 [MaterialApp] 的 State 的 context：
  /// 后者是 Navigator 的祖先，`showDialog` → `Navigator.of(context)` 只能
  /// **向上** 查找，其上方没有 Navigator（Navigator 是它的后代）→
  /// `Null check operator used on a null value`。该异常被 main.dart 注册的
  /// `FlutterError.onError` 捕获后 `CrashLogService.logError` 重写
  /// `crash_log.txt` 并重新置崩溃标记 → 下次启动再次弹窗再次抛异常，
  /// 形成启动崩溃循环（crash_log.txt 每次启动都被刷新）。
  ///
  /// 首帧渲染完成时 [MaterialApp] 已构建、Navigator 已挂载，
  /// `navigatorKey.currentContext` 非空，`showDialog` 自该 context 向上
  /// 即可命中本 Navigator（与 [PlatformBridgeService] L661、
  /// [DeepLinkService] attach 模式同源）。
  ///
  /// 返回是否已调度弹窗；Navigator 尚未装配（如宿主未挂
  /// [PlatformBridgeService.navigatorKey]）时静默跳过本轮——崩溃日志
  /// 仍留在磁盘文件中，下次启动继续提示，不丢数据、不抛异常。
  static bool showCrashLogDialog(String crashLog) {
    final navContext = PlatformBridgeService.navigatorKey.currentContext;
    if (navContext == null) return false;
    CrashLogDialog.show(navContext, crashLog);
    return true;
  }

  /// 调度「上次崩溃」弹窗：等冷启动闪屏退出后再弹出（P2-13b）。
  ///
  /// 冷启动固定经闪屏路由（main.dart `initialRoute = AppRoutes.welcome`），
  /// [WelcomeScreen] 延时后经 `pushReplacementNamed(home)` 退出闪屏——
  /// pushReplacement 替换的是**当时栈顶路由**：若弹窗已在首帧 postFrame
  /// 弹出（栈顶），闪屏退出时弹窗路由会被一并替换掉，用户看不到提示
  /// （且「确定」不会被点按，crash_log 永不清除，每次启动重复提示）。
  ///
  /// 因此经 [TopRouteWatcher]（须已注册进
  /// `MaterialApp(navigatorObservers:)`，见 [_LegadoAppState.build]）监听
  /// 栈顶路由变化：确认栈顶不再是 [AppRoutes.welcome] 即弹窗。
  /// 当前 SDK 的 `NavigatorState` 不再公开 `routes` 列表，
  /// `NavigatorObserver.didChangeTop` 是受支持的栈顶路由观察 API。
  /// 若 [maxFrames] 帧内未观察到「已非闪屏」（60Hz 下 90 帧≈1.5s，
  /// 覆盖闪屏最大 800ms 延时 + 设置读取耗时；或 watcher 未注册）则
  /// 兜底弹出——崩溃日志仍在磁盘文件中，下次启动继续提示，
  /// 不丢数据、不抛异常。
  ///
  /// [isAlive] 供宿主 State 传入 `() => mounted`：State 已卸载即停止
  /// 重试，避免对已销毁界面弹窗。
  static void scheduleCrashLogDialog(
    String crashLog,
    bool Function() isAlive, {
    TopRouteWatcher? watcher,
    int maxFrames = 90,
  }) {
    final probe = watcher ?? TopRouteWatcher();
    var shown = false;

    void attempt(int frame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!isAlive() || shown) return;
        if (probe.didObserveTopChange &&
            probe.topRouteName != AppRoutes.welcome) {
          // 栈顶已确认非闪屏（含无名字路由）→ 弹出
          shown = true;
          showCrashLogDialog(crashLog);
          return;
        }
        if (frame < maxFrames) {
          attempt(frame + 1);
        } else {
          // 超时兜底：事件未观察到（如 watcher 未注册）或闪屏未退出
          shown = true;
          showCrashLogDialog(crashLog);
        }
      });
    }

    attempt(0);
  }

  /// [V-B3-ROUTE 2026-10-05] 悬浮窗回全屏导航调度：等闪屏 /welcome 退出
  /// 栈顶后再压栈。
  ///
  /// 缺陷（round2 真机 2/2 复现，`.tmp/video_qa/round2/c2_*.png`）：冷启动
  /// 经 [AppRoutes.welcome] 闪屏；MainActivity.onCreate 把悬浮窗播放状态经
  /// Intent 交给 Dart（[VideoFloatWindowBridge.attach] →
  /// `_consumeInitialReturn`），回全屏导航在首帧附近触发。此时直接
  /// `pushNamed(video)` 会把 /video 压在 /welcome 之上，而 [WelcomeScreen]
  /// 延后执行的 `pushReplacementNamed(home)` 替换的是**当时栈顶**——刚压入
  /// 的 /video 被一并替换：可见播放页闪现后被书架顶掉、播放中断。
  ///
  /// 门控条件取「路由栈顶已非 /welcome」（[TopRouteWatcher] 的
  /// `didChangeTop` 由框架在路由栈变化时同步更新，天然无竞态）：
  /// - 热路径（App 已存活，onNewIntent 回全屏）：栈顶非 welcome →
  ///   [push] 同步执行，零额外延迟；
  /// - 冷启动（Navigator 未就绪或闪屏未退出）：按 [interval] 轮询，
  ///   至多 [maxAttempts] 次（默认 50ms × 60 = 3s）后放弃并回调
  ///   [onTimeout]——宁可不导航（停留当前页），也不重演「压栈后被欢迎页
  ///   替换」的错误导航。
  ///
  /// 不用「[WelcomeScreen] `_goNext` 的 `await pushReplacementNamed` 之后
  /// 置标志」：`Navigator.pushReplacement` 返回的是**新路由的 popped
  /// future**（Flutter 3.44 `navigator.dart` `return newRoute.popped;`），
  /// home 不弹栈该 await 永不完成，手写标志将永不置位（本批探针测试已实证）。
  /// 路由栈本身才是权威信号，故经 [TopRouteWatcher] 观察。
  static void scheduleFloatReturnNavigation({
    required TopRouteWatcher watcher,
    required NavigatorState? Function() navigator,
    required void Function(NavigatorState navigator) push,
    int maxAttempts = 60,
    Duration interval = const Duration(milliseconds: 50),
    VoidCallback? onTimeout,
  }) {
    void attempt(int attemptNo) {
      final nav = navigator();
      final welcomeGone = watcher.didObserveTopChange &&
          watcher.topRouteName != AppRoutes.welcome;
      if (nav != null && welcomeGone) {
        push(nav);
        return;
      }
      if (attemptNo >= maxAttempts) {
        onTimeout?.call();
        return;
      }
      Timer(interval, () => attempt(attemptNo + 1));
    }

    attempt(0);
  }

  @override
  ConsumerState<LegadoApp> createState() => _LegadoAppState();
}

/// 栈顶路由观察器（P2-13b 崩溃弹窗调度的一次性事件源）
///
/// 经 `MaterialApp(navigatorObservers:)` 注册；栈顶路由变化时
/// [didChangeTop]（当前 SDK 的 `NavigatorObserver` 受支持 API——
/// `NavigatorState` 不再公开 `routes` 列表）更新 [topRouteName]。
/// [didObserveTopChange] 用于区分「已观察到栈顶（无名路由为 null）」
/// 与「尚未观察到任何栈顶变化事件」。
class TopRouteWatcher extends NavigatorObserver {
  /// 自注册以来是否已观察到栈顶路由变化事件
  bool didObserveTopChange = false;

  /// 最近观察到的栈顶路由名（路由无名时为 `null`）
  String? topRouteName;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    didObserveTopChange = true;
    topRouteName = topRoute.settings.name;
  }
}

class _LegadoAppState extends ConsumerState<LegadoApp> {
  /// 栈顶路由观察器（注册进 `MaterialApp(navigatorObservers:)`，见
  /// [build]），两个只读消费者：
  /// - [P2-13b] 崩溃弹窗调度（[scheduleCrashLogDialog]）；
  /// - [V-B3-ROUTE] 悬浮窗回全屏门控（[scheduleFloatReturnNavigation]）——
  ///   确认闪屏 /welcome 已被替换出栈顶后才压入 /video。
  final TopRouteWatcher _topRouteWatcher = TopRouteWatcher();

  @override
  void initState() {
    super.initState();
    // 系统栏样式由 [SystemBarBinder] 按偏好与主题统一驱动
    // 首帧渲染后检查上次崩溃日志并弹窗提示
    // [P2-13 2026-09-18] 弹窗上下文改用全局 Navigator（见
    // [showCrashLogDialog]）：本 State 自身 context 是 MaterialApp 的
    // **祖先**，showDialog 向上找 Navigator 时其上方并无 Navigator
    // （Navigator 是它的后代）→ 抛异常 → FlutterError.onError 重写
    // crash_log.txt 并置崩溃标记 → 下次启动再弹再抛，形成启动崩溃循环。
    // [P2-13b 2026-09-19] 实机验证发现冷启动闪屏 /welcome 退出时
    // pushReplacementNamed 会连同栈顶的弹窗路由一起替换掉（弹窗一闪
    // 即逝），故经 [scheduleCrashLogDialog] + [TopRouteWatcher]（didChangeTop
    // 事件驱动 + 90 帧超时兜底）确认闪屏退出后再弹；watcher 已在下方
    // MaterialApp.navigatorObservers 注册。
    if (widget.lastCrashLog != null && widget.lastCrashLog!.isNotEmpty) {
      LegadoApp.scheduleCrashLogDialog(
        widget.lastCrashLog!,
        () => mounted,
        watcher: _topRouteWatcher,
      );
    }
    // [UI-fix v2.0.3 | 2026-08-08] 定时任务应用内调度器启动装配
    //（Task #146，对齐原版 App.kt 启动时 AutoTaskScheduler.refresh；
    // 引擎已在 main.dart 先行初始化，此处可直接注入 BookApi） — QoderCN
    AutoTaskScheduler.instance.attach(ref.read(bookApiProvider));
    // P1-11：监听系统 legado:// / yuedu:// 深链 → Association
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DeepLinkService.instance.attach(PlatformBridgeService.navigatorKey);
    });
    // [V-B3] 视频悬浮窗：注册原生事件处理与回全屏导航后 attach
    // （attach 会拉取冷启动经 MainActivity Intent 带回的播放状态）
    VideoFloatWindowCoordinator.instance
      ..openFullscreen = _openVideoFromFloatWindow
      ..onNotice = _showFloatWindowNotice;
    VideoFloatWindowBridge.instance.attach();
  }

  /// [V-B3] 悬浮窗「全屏」/通知点击回传：导航到视频页从交回位置续播
  ///
  /// [V-B3-ROUTE] 冷启动时须等闪屏 /welcome 退出栈顶后再压栈，否则会与
  /// `pushReplacementNamed(home)` 竞争、刚压入的 /video 被整体替换
  /// （round2 真机 2/2；详见 [scheduleFloatReturnNavigation]）。
  void _openVideoFromFloatWindow(VideoFloatWindowState state, Book? book) {
    final args = VideoScreenArgs(
      videoUrl: state.directUrl ?? book?.bookUrl ?? '',
      title: state.chapterTitle?.isNotEmpty == true
          ? state.chapterTitle!
          : (state.title.isNotEmpty ? state.title : '视频播放'),
      book: book,
      presetUrl: state.url,
      presetHeaders: state.headers,
      presetMpdPath: state.mpdTempPath,
      initialResumeMs: state.positionMs,
      initialChapterIndex: state.chapterIndex >= 0 ? state.chapterIndex : null,
      initialSpeed: state.speed,
      initialPlaying: state.playing,
    );
    // 统一就绪循环覆盖两段等待：冷启动首帧前 Navigator 未装配（原
    // addPostFrameCallback 推迟逻辑）+ 闪屏 /welcome 未退出栈顶（本批修复）。
    LegadoApp.scheduleFloatReturnNavigation(
      watcher: _topRouteWatcher,
      navigator: () => PlatformBridgeService.navigatorKey.currentState,
      push: (navigator) =>
          navigator.pushNamed(AppRoutes.video, arguments: args),
      onTimeout: () => debugPrint(
        '[VideoFloat] 闪屏未在等待窗口内退出，放弃本次回全屏导航（停留当前页）',
      ),
    );
  }

  /// [V-B3] 悬浮窗用户可见提示（经全局 Navigator context）
  void _showFloatWindowNotice(String message) {
    final context = PlatformBridgeService.navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeNotifierProvider);
    // [UI-FIX v2.0.5 | 2026-08-08] 自定义主题颜色接入 MaterialApp（对齐原版
    // ThemeConfigFragment 日间/夜间颜色配置，设置页修改后全局即时生效） — Qoder
    final themeColors = ref.watch(themeColorsProvider);
    Color? c(int? argb) => argb != null ? Color(argb) : null;

    // [MD3 Batch 0 | 2026-08-28] 按 paletteId 装配内置 MD3 调色板
    //（阶段D 2.0.270 起默认 def「默认」；自定义 themeConfigList 4 色仍可叠加，
    // 自定义已应用色优先于内置 palette role——UI_MD3_PLAN.md 第九节并存模型）
    final palette = Md3Palettes.byId(themeState.paletteId);
    // [UI_SYNC_REFACTOR S4] 主题引擎参数化：themeStyle 非 none 时按
    // paletteStyle/contrastLevel 从调色板锚点 seed 生成明暗两套角色
    //（material_color_utilities Scheme* 类，对齐参考 ThemeEngine）；
    // AMOLED 仅暗色纯黑。并存模型保持：动态壁纸 > 自定义四色 > 参数化
    // seed > 内置色板（自定义四色仍叠加于参数化结果之上）
    final uiTheme = ref.watch(uiSettingsProvider);
    var effectivePalette = palette;
    if (uiTheme.themeStyle != 'none') {
      final seed = c(themeColors.primary) != null
          ? c(themeColors.primary)!.toARGB32()
          : palette.seed;
      final contrast = double.tryParse(uiTheme.themeContrastLevel) ?? 0.0;
      final generated = buildParameterizedRoles(
        style: uiTheme.themeStyle,
        seed: seed,
        contrastLevel: contrast,
        amoledDark: uiTheme.themeAmoled,
      );
      effectivePalette = Md3Palette(
        id: '${palette.id}__param',
        label: palette.label,
        seed: seed,
        light: generated.light,
        dark: generated.dark,
      );
    }

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
        palette: effectivePalette,
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
        palette: effectivePalette,
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
      // [P2-13b 2026-09-19] _topRouteWatcher：崩溃弹窗调度器（见
      // [LegadoApp.scheduleCrashLogDialog]）监听 didChangeTop，确认冷启动
      // 闪屏 /welcome 退出（pushReplacementNamed 换栈顶）后才弹窗
      navigatorObservers: [appRouteObserver, _topRouteWatcher],
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
