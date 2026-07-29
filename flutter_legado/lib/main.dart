import 'package:flutter/material.dart';
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
import 'src/services/rust_api.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 首次启动检测：未展示过欢迎页时以欢迎页为初始路由
  final prefs = await SharedPreferences.getInstance();
  final welcomeShown = prefs.getBool(WelcomeScreen.kWelcomeShownKey) ?? false;
  final initialRoute = welcomeShown ? AppRoutes.home : AppRoutes.welcome;

  // 初始化 Rust FFI 桥接（含 frb runtime + tokio runtime + 数据库打开）
  final rustApi = RustApi();
  try {
    await rustApi.initialize();
  } catch (e, stack) {
    debugPrint('[Legado] Rust FFI 初始化失败: $e');
    debugPrintStack(stackTrace: stack);
    runApp(_FfiErrorApp(error: e.toString()));
    return;
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<RustApi>.value(value: rustApi),
        ChangeNotifierProvider(
          create: (_) => BookshelfProvider(rustApi)..loadSettings(),
        ),
        ChangeNotifierProvider(
          create: (_) => ReaderProvider(rustApi)..loadSettings(),
        ),
        ChangeNotifierProvider(
          create: (_) => SearchProvider(rustApi),
        ),
        ChangeNotifierProvider(
          create: (_) => SourceProvider(rustApi),
        ),
        ChangeNotifierProvider(
          create: (_) => ExploreProvider(rustApi),
        ),
        ChangeNotifierProvider(
          create: (_) => RssProvider(rustApi),
        ),
        ChangeNotifierProvider(
          create: (_) => ReadingStatsProvider(rustApi),
        ),
        ChangeNotifierProvider(
          create: (_) => SyncProvider(rustApi),
        ),
        ChangeNotifierProvider(
          create: (_) => BookmarkProvider(rustApi),
        ),
        ChangeNotifierProvider(
          create: (_) => ReplaceRuleProvider(rustApi),
        ),
        ChangeNotifierProvider(
          create: (_) => AutoTaskProvider(),
        ),
      ],
      child: LegadoApp(initialRoute: initialRoute),
    ),
  );
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
                  '请确认 APK 包含对应架构的 liblegado_ffi.so\n'
                  '可通过重新交叉编译 Rust FFI 并重新构建 APK 解决',
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
