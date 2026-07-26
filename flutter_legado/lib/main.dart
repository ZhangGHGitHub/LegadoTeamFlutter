import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'src/providers/auto_task_provider.dart';
import 'src/providers/bookmark_provider.dart';
import 'src/providers/bookshelf_provider.dart';
import 'src/providers/discover_provider.dart';
import 'src/providers/reader_provider.dart';
import 'src/providers/reading_stats_provider.dart';
import 'src/providers/replace_rule_provider.dart';
import 'src/providers/rss_provider.dart';
import 'src/providers/search_provider.dart';
import 'src/providers/source_provider.dart';
import 'src/providers/sync_provider.dart';
import 'src/services/rust_api.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 Rust FFI 桥接（含 frb runtime + tokio runtime + 数据库打开）
  final rustApi = RustApi();
  await rustApi.initialize();

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
        ChangeNotifierProvider(
          create: (_) => DiscoverProvider(rustApi),
        ),
      ],
      child: const LegadoApp(),
    ),
  );
}
