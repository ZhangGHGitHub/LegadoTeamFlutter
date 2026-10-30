import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'src/l10n/app_strings.dart';
import 'src/providers/providers.dart';
import 'src/routes.dart';
import 'src/services/book_api.dart';
import 'src/services/crash_log_service.dart';
import 'src/services/mock_book_api.dart';
import 'src/services/rust_api.dart';
import 'src/services/server_service.dart';
import 'src/services/settings_service.dart';
import 'src/utils/book_open_utils.dart';
import 'src/utils/image_paint_utils.dart';

void main() {
  runZonedGuarded(() async {
    final totalSw = Stopwatch()..start();

    WidgetsFlutterBinding.ensureInitialized();

    // 1. 崩溃日志服务（最先初始化，确保后续异常可被捕获）
    var sw = Stopwatch()..start();
    await CrashLogService.instance.init();
    debugPrint('[启动] CrashLogService 初始化耗时：${sw.elapsedMilliseconds}ms');

    // 2. 注册全局错误捕获
    FlutterError.onError = (details) {
      CrashLogService.instance.logError(details.exception, details.stack);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      CrashLogService.instance.logError(error, stack);
      return true;
    };

    // 3. 读取上次崩溃日志
    final lastCrash = await CrashLogService.instance.getLastCrashLog();

    // 4. 并行初始化：SharedPreferences 与 Rust FFI 无依赖，可并行
    // SharedPreferences 预热供 SettingsService；RustApi.initialize 装载引擎单例
    //（bookApiProvider 随后取同一 FFI 句柄）。
    sw = Stopwatch()..start();
    const useMock = bool.fromEnvironment('USE_MOCK', defaultValue: false);
    late final BookApi startupApi;
    try {
      if (useMock) {
        startupApi = MockBookApi();
      } else {
        startupApi = RustApi();
      }
      await Future.wait([
        SharedPreferences.getInstance(),
        startupApi.initialize(),
      ]);
    } catch (e, stack) {
      CrashLogService.instance.logError(e, stack);
      debugPrint('[Legado] 初始化失败：$e');
      runApp(_FfiErrorApp(error: e.toString()));
      return;
    }
    debugPrint('[启动] 并行初始化（prefs+FFI）耗时：${sw.elapsedMilliseconds}ms');

    // 5. 远程书库服务器：legacy prefs（remote_servers）→ servers 表一次性迁移
    //（批18a）。失败只记崩溃日志，不阻断启动；标记已置时直接跳过。
    sw = Stopwatch()..start();
    try {
      await ServerService(api: startupApi).migrateLegacyPrefs();
      debugPrint('[启动] 远程书库服务器迁移耗时：${sw.elapsedMilliseconds}ms');
    } catch (e, stack) {
      CrashLogService.instance.logError(e, stack);
      debugPrint('[启动] 远程书库服务器迁移失败（不阻断启动）：$e');
    }

    // 5b. 全局偏好镜像与设备级启动设置（批9a，失败不阻断启动）：
    // - 语言：冷启动读 app_locale 初始化 AppStrings（system→zh，与
    //   other_settings_screen 约定一致）；运行中切换仍即时 setLocale（现行为），
    //   AppStrings 无变更通知机制，重启生效语义与原版 attachBaseContext 一致。
    // - 抗锯齿/图片绘制缓存镜像：翻页 painter 与漫画绘制处的同步快照。
    // - 全局解码缓存上限：bitmapCacheSize（1..1024 MB，越界回落 50，
    //   对齐原版 ImageProvider.kt 的钳制）应用到 imageCache.maximumSizeBytes。
    sw = Stopwatch()..start();
    try {
      final locale = await SettingsService().getLocale();
      // P3-1：启动映射抽为 AppStrings.startupLocaleOf（system 与脏值→zh，
      // en/zh 直通），与单测共用同一口径
      AppStrings.setLocale(AppStrings.startupLocaleOf(locale));
      await ImagePaintPrefs.refresh();
      ImagePaintPrefs.applyImageCacheLimit();
      // 批9a 项4：漫画浏览开书分流镜像启动初始化
      await BookOpenUtils.refreshShowMangaUi();
      debugPrint('[启动] 语言/图片绘制偏好初始化耗时：${sw.elapsedMilliseconds}ms');
    } catch (e, stack) {
      CrashLogService.instance.logError(e, stack);
      debugPrint('[启动] 语言/图片绘制偏好初始化失败（不阻断启动）：$e');
    }

    // 6. 冷启动始终经闪屏路由（对齐 WelcomeActivity；时长 0 则立即进主页）
    const initialRoute = AppRoutes.welcome;

    debugPrint('[启动] 总启动耗时：${totalSw.elapsedMilliseconds}ms');
    
    // 7. 启动应用（传入崩溃日志）
    // ProviderScope 为 Riverpod 全局作用域：全部状态管理已迁移至 Riverpod Notifier
    // （主题/书架/书源/RSS/阅读统计/同步/书签/替换规则/定时任务/阅读器/搜索/发现等）
    // bookApiProvider 复用启动期实例：Mock 模式下保证内存态一致（迁移结果可见），
    // 真实模式复用同一已初始化句柄。
    runApp(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(startupApi)],
        child: LegadoApp(initialRoute: initialRoute, lastCrashLog: lastCrash),
      ),
    );
  }, (error, stack) {
    // Zone 级异常兜底：记录到崩溃日志
    CrashLogService.instance.logError(error, stack);
  });
}

/// FFI 初始化失败时显示的错误页面
class _FfiErrorApp extends StatelessWidget {
  final String error;

  const _FfiErrorApp({required this.error});

  String get _fixHint {
    final lower = error.toLowerCase();
    final isHashMismatch = lower.contains('content hash') ||
        lower.contains('out-of-sync') ||
        lower.contains('rustcontenthash');

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      if (isHashMismatch) {
        return 'Android 上 Rust .so 与当前 Dart 桥接代码不同步（content hash 失配）。\n\n'
            '请在仓库根目录执行：\n'
            '.\\rust\\scripts\\build-android.ps1 -Mode debug -Targets "aarch64,x86_64"\n\n'
            '或使用统一入口：\n'
            '.\\flutter_legado\\scripts\\build-apk.ps1\n\n'
            '然后重新构建并安装 APK。';
      }
      return '请确认已构建 Android Rust FFI 动态库：\n'
          '.\\rust\\scripts\\build-android.ps1 -Mode debug\n'
          '然后执行 flutter build apk --debug 并重新安装。';
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return '请使用开发脚本启动（会自动重编译 DLL）：\n'
          '.\\flutter_legado\\scripts\\run-windows.ps1\n\n'
          '或手动：cd rust && cargo build -p legado-ffi --features quickjs';
    }

    return '请确认已构建 Rust FFI 动态库，然后重新运行应用。\n'
        '纯 UI 开发可使用：flutter run --dart-define=USE_MOCK=true';
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 24),
                const Text(
                  'Rust 引擎初始化失败',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  error,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 24),
                Text(
                  _fixHint,
                  style: const TextStyle(fontSize: 14, color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
