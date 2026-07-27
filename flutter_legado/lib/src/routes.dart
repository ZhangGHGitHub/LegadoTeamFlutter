import 'package:flutter/material.dart';

import 'screens/association_screen.dart';
import 'screens/audio_screen.dart';
import 'screens/auto_task_screen.dart';
import 'screens/book_info_screen.dart';
import 'screens/bookmark_screen.dart';
import 'screens/change_source_screen.dart';
import 'screens/home_screen.dart';
import 'screens/reading_stats_screen.dart';
import 'screens/reader_screen.dart';
import 'screens/replace_rules_screen.dart';
import 'screens/rss_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/source_screen.dart';
import 'screens/source_edit_screen.dart';
import 'screens/source_discover_screen.dart';

/// 路由配置
class AppRoutes {
  static const home = '/';
  static const reader = '/reader';
  static const search = '/search';
  static const sources = '/sources';
  static const sourceEdit = '/sources/edit';
  static const sourceDiscover = '/sources/discover';
  static const settings = '/settings';
  static const rss = '/rss';
  static const audio = '/audio';
  static const bookInfo = '/book_info';
  static const changeSource = '/change_source';
  static const readingStats = '/reading_stats';
  static const bookmarks = '/bookmarks';
  static const replaceRules = '/replace_rules';
  static const autoTasks = '/auto_tasks';
  static const association = '/association';
  // rssArticles 和 rssArticleDetail 通过 Navigator.push 传参，不在此注册

  static Map<String, WidgetBuilder> get routes => {
        home: (_) => const HomeScreen(),
        reader: (_) => const ReaderScreen(),
        search: (_) => const SearchScreen(),
        sources: (_) => const SourceScreen(),
        sourceEdit: (_) => const SourceEditScreen(),
        sourceDiscover: (_) => const SourceDiscoverScreen(),
        settings: (_) => const SettingsScreen(),
        rss: (_) => const RssScreen(),
        audio: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          if (args is Map<String, String>) {
            return AudioScreen(
              bookUrl: args['bookUrl'] ?? '',
              bookName: args['bookName'] ?? '',
            );
          }
          return const AudioScreen(bookUrl: '');
        },
        bookInfo: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final bookUrl = args is String ? args : '';
          return BookInfoScreen(bookUrl: bookUrl);
        },
        changeSource: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          if (args is Map<String, String>) {
            return ChangeSourceScreen(
              bookUrl: args['bookUrl'] ?? '',
              bookName: args['bookName'] ?? '',
              author: args['author'] ?? '',
              currentSourceUrl: args['currentSourceUrl'] ?? '',
            );
          }
          return const ChangeSourceScreen(
            bookUrl: '',
            bookName: '',
            author: '',
            currentSourceUrl: '',
          );
        },
        readingStats: (_) => const ReadingStatsScreen(),
        bookmarks: (_) => const BookmarkScreen(),
        replaceRules: (_) => const ReplaceRulesScreen(),
        autoTasks: (_) => const AutoTaskScreen(),
        association: (_) => const AssociationScreen(),
      };
}
