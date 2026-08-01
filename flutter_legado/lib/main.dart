import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'src/providers/auto_task_provider.dart';
import 'src/providers/bookmark_provider.dart';
import 'src/providers/bookshelf_provider.dart';
import 'src/providers/reader_provider.dart';
import 'src/providers/reading_stats_provider.dart';
import 'src/providers/replace_rule_provider.dart';
import 'src/providers/rss_provider.dart';
import 'src/providers/search_provider.dart';
import 'src/providers/explore_provider.dart';
import 'src/providers/source_provider.dart';
import 'src/providers/sync_provider.dart';
import 'src/routes.dart';
import 'src/screens/welcome_screen.dart';
import 'src/services/crash_log_service.dart';
import 'src/services/book_api.dart';
import 'src/services/mock_book_api.dart';
import 'src/services/rust_api.dart';

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
    sw = Stopwatch()..start();
    const useMock = bool.fromEnvironment('USE_MOCK', defaultValue: false);
    final BookApi rustApi;
    final SharedPreferences prefs;
    try {
      if (useMock) {
        // Mock 模式：跳过 Rust 引擎初始化，使用纯 Dart Mock 实现
        rustApi = MockBookApi();
        prefs = await SharedPreferences.getInstance();
        await rustApi.initialize();
      } else {
        final realApi = RustApi();
        final results = await Future.wait([
          SharedPreferences.getInstance(),
          realApi.initialize(),
        ]);
        prefs = results[0] as SharedPreferences;
        rustApi = realApi;
      }
    } catch (e, stack) {
      CrashLogService.instance.logError(e, stack);
      debugPrint('[Legado] 初始化失败：$e');
      runApp(_FfiErrorApp(error: e.toString()));
      return;
    }
    debugPrint('[启动] 并行初始化（prefs+FFI）耗时：${sw.elapsedMilliseconds}ms');

    // 5. 计算初始路由
    final welcomeShown = prefs.getBool(WelcomeScreen.kWelcomeShownKey) ?? false;
    final initialRoute = welcomeShown ? AppRoutes.home : AppRoutes.welcome;

    debugPrint('[启动] 总启动耗时：${totalSw.elapsedMilliseconds}ms');
    
    // 6. 启动应用（传入崩溃日志）
    // ProviderScope 为 Riverpod 全局作用域（过渡期与 provider 共存）
    runApp(
      ProviderScope(
        child: MultiProvider(
          providers: [
            Provider<BookApi>.value(value: rustApi),
            // 移除 ..loadSettings() 级联，下沉到各屏幕首帧回调
            ChangeNotifierProvider(create: (_) => BookshelfProvider(rustApi)),
            ChangeNotifierProvider(create: (_) => ReaderProvider(rustApi)),
            ChangeNotifierProvider(create: (_) => SearchProvider(rustApi)),
            ChangeNotifierProvider(create: (_) => SourceProvider(rustApi)),
            ChangeNotifierProvider(create: (_) => ExploreProvider(rustApi)),
            ChangeNotifierProvider(create: (_) => RssProvider(rustApi)),
            ChangeNotifierProvider(create: (_) => ReadingStatsProvider(rustApi)),
            ChangeNotifierProvider(create: (_) => SyncProvider(rustApi)),
            ChangeNotifierProvider(create: (_) => BookmarkProvider(rustApi)),
            ChangeNotifierProvider(create: (_) => ReplaceRuleProvider(rustApi)),
            ChangeNotifierProvider(create: (_) => AutoTaskProvider(rustApi: rustApi)),
          ],
          child: LegadoApp(initialRoute: initialRoute, lastCrashLog: lastCrash),
        ),
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
                const Text(
                  '请确认已构建 Rust FFI 动态库：\n'
                  'cd rust && cargo build -p legado-ffi\n'
                  '然后重新运行应用',
                  style: TextStyle(fontSize: 14, color: Colors.white70),
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
