import 'package:flutter/material.dart';

import 'models/models.dart';
import 'screens/about_screen.dart';
import 'screens/association_screen.dart';
import 'screens/browser_screen.dart';
import 'screens/dict_screen.dart';
import 'screens/audio_screen.dart';
import 'screens/auto_task_screen.dart';
import 'screens/book_group_screen.dart';
import 'screens/book_info_screen.dart';
import 'screens/bookshelf_manage_screen.dart';
import 'screens/cache_settings_screen.dart';
import 'screens/edit_book_info_screen.dart';
import 'screens/bookmark_screen.dart';
import 'screens/change_cover_screen.dart';
import 'screens/change_source_screen.dart';
import 'screens/explore_show_screen.dart';
import 'screens/font_screen.dart';
import 'screens/other_settings_screen.dart';
import 'screens/home_screen.dart';
import 'screens/import_screen.dart';
import 'screens/qrcode_screen.dart';
import 'screens/search_content_screen.dart';
import 'screens/reading_stats_screen.dart';
import 'screens/reader_screen.dart';
import 'screens/reader_comic_screen.dart';
import 'screens/remote_book_screen.dart';
import 'screens/replace_rules_screen.dart';
import 'screens/rss_config_screen.dart';
import 'screens/rss_favorites_screen.dart';
import 'screens/rss_history_screen.dart';
import 'screens/rss_source_debug_screen.dart';
import 'screens/rss_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/source_screen.dart';
import 'screens/source_edit_screen.dart';
import 'screens/rss_source_edit_screen.dart';
import 'screens/source_debug_screen.dart';
import 'screens/read_aloud_config_screen.dart';
import 'screens/theme_config_screen.dart';
import 'screens/txt_toc_rules_screen.dart';
import 'screens/video_screen.dart';
import 'screens/webdav_settings_screen.dart';
import 'screens/welcome_screen.dart';

/// 路由配置
class AppRoutes {
  static const home = '/';
  static const reader = '/reader';
  static const readerComic = '/reader-comic';
  static const search = '/search';
  static const sources = '/sources';
  static const sourceEdit = '/sources/edit';
  static const exploreShow = '/explore_show';
  static const settings = '/settings';
  static const otherSettings = '/other_settings';
  static const cacheSettings = '/cache_settings';
  static const rss = '/rss';
  static const audio = '/audio';
  static const bookInfo = '/book_info';
  static const editBookInfo = '/edit_book_info';
  static const changeSource = '/change_source';
  static const readingStats = '/reading_stats';
  static const bookmarks = '/bookmarks';
  static const replaceRules = '/replace_rules';
  static const autoTasks = '/auto_tasks';
  static const association = '/association';
  static const sourceDebug = '/sources/debug';
  static const rssSourceEdit = '/rss/edit';
  static const readAloudConfig = '/read_aloud_config';
  static const themeConfig = '/theme_config';
  static const importBooks = '/import_books';
  static const remoteBooks = '/remote_books';
  static const bookGroups = '/book_groups';
  static const bookshelfManage = '/bookshelf/manage';
  static const searchContent = '/search_content';
  static const about = '/about';
  // discover 路由已删除（原版不存在的功能）
  static const rssConfig = '/rss/config';
  static const rssFavorites = '/rss/favorites';
  static const rssHistory = '/rss/history';
  static const rssSourceDebug = '/rss/source_debug';
  static const changeCover = '/change_cover';
  static const txtTocRules = '/txt_toc_rules';
  static const dict = '/dict';
  static const fonts = '/fonts';
  static const qrcode = '/qrcode';
  static const welcome = '/welcome';
  static const browser = '/browser';
  static const video = '/video';
  static const webdavSettings = '/webdav_settings';
  // rssArticles 和 rssArticleDetail 通过 Navigator.push 传参，不在此注册

  static Map<String, WidgetBuilder> get routes => {
      home: (_) => const HomeScreen(),
        reader: (_) => const ReaderScreen(),
        readerComic: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final bookUrl = args is String ? args : (args is Map ? (args['bookUrl'] as String? ?? '') : '');
          return ReaderComicScreen(bookUrl: bookUrl);
        },
        search: (_) => const SearchScreen(),
        sources: (_) => const SourceScreen(),
        sourceEdit: (_) => const SourceEditScreen(),
        exploreShow: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final exploreArgs = args is ExploreShowArgs ? args : null;
          return ExploreShowScreen(args: exploreArgs);
        },
        settings: (_) => const SettingsScreen(),
        otherSettings: (_) => const OtherSettingsScreen(),
        cacheSettings: (_) => const CacheSettingsScreen(),
        rss: (_) => const RssScreen(),
        audio: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          // 路由参数规范化：优先接收 Book 对象
          if (args is Book) {
            return AudioScreen(book: args);
          }
          // 向后兼容：支持 Map<String, String> 传参
          if (args is Map<String, String>) {
            return AudioScreen(
              bookUrl: args['bookUrl'] ?? '',
              bookName: args['bookName'] ?? '',
            );
          }
          return const AudioScreen();
        },
        bookInfo: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          // 路由参数规范化：优先接收 Book 对象
          if (args is Book) {
            return BookInfoScreen(book: args);
          }
          // 向后兼容：支持 String(bookUrl) 传参
          final bookUrl = args is String ? args : '';
          return BookInfoScreen(bookUrl: bookUrl);
        },
        editBookInfo: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          // 路由参数规范化：接收 Book 对象
          if (args is Book) {
            return EditBookInfoScreen(book: args);
          }
          // 缺少书籍对象时回退到首页，避免崩溃
          return const HomeScreen();
        },
        changeSource: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          // 路由参数规范化：优先接收 Book 对象
          if (args is Book) {
            return ChangeSourceScreen(book: args);
          }
          // 向后兼容：支持 Map<String, String> 传参
          if (args is Map<String, String>) {
            return ChangeSourceScreen(
              bookUrl: args['bookUrl'] ?? '',
              bookName: args['bookName'] ?? '',
              author: args['author'] ?? '',
              currentSourceUrl: args['currentSourceUrl'] ?? '',
            );
          }
          return const ChangeSourceScreen();
        },
        readingStats: (_) => const ReadingStatsScreen(),
        bookmarks: (_) => const BookmarkScreen(),
        replaceRules: (_) => const ReplaceRulesScreen(),
        autoTasks: (_) => const AutoTaskScreen(),
        association: (_) => const AssociationScreen(),
        sourceDebug: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final sourceUrl = args is String ? args : null;
          return SourceDebugScreen(sourceUrl: sourceUrl);
        },
        rssSourceEdit: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final source = args is RssSource ? args : null;
          return RssSourceEditScreen(source: source);
        },
        readAloudConfig: (_) => const ReadAloudConfigScreen(),
        themeConfig: (_) => const ThemeConfigScreen(),
        importBooks: (_) => const ImportScreen(),
        remoteBooks: (_) => const RemoteBookScreen(),
        bookGroups: (_) => const BookGroupScreen(),
        bookshelfManage: (_) => const BookshelfManageScreen(),
        searchContent: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          // 路由参数规范化：优先接收 Book 对象
          if (args is Book) {
            return SearchContentScreen(book: args);
          }
          // 向后兼容：支持 Map<String, String> 传参
          if (args is Map<String, String>) {
            return SearchContentScreen(
              bookUrl: args['bookUrl'] ?? '',
              bookName: args['bookName'] ?? '',
            );
          }
          return const SearchContentScreen();
        },
        about: (_) => const AboutScreen(),
        
        rssConfig: (_) => const RssConfigScreen(),
        rssFavorites: (_) => const RssFavoritesScreen(),
        rssHistory: (_) => const RssHistoryScreen(),
        rssSourceDebug: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final sourceUrl = args is String ? args : null;
          return RssSourceDebugScreen(sourceUrl: sourceUrl);
        },
        changeCover: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          // 路由参数规范化：优先接收 Book 对象
          if (args is Book) {
            return ChangeCoverScreen(book: args);
          }
          // 向后兼容：支持 Map<String, String> 传参
          if (args is Map<String, String>) {
            return ChangeCoverScreen(
              bookUrl: args['bookUrl'] ?? '',
              bookName: args['bookName'] ?? '',
              currentCover: args['coverUrl'],
            );
          }
          return const ChangeCoverScreen();
        },
        txtTocRules: (_) => const TxtTocRulesScreen(),
        dict: (_) => const DictScreen(),
        fonts: (_) => const FontScreen(),
        qrcode: (_) => const QrcodeScreen(),
        welcome: (_) => const WelcomeScreen(),
        browser: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final url = args is String ? args : null;
          return BrowserScreen(initialUrl: url);
        },
        video: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          if (args is Map<String, String>) {
            return VideoScreen(
              videoUrl: args['videoUrl'] ?? '',
              title: args['title'] ?? '视频播放',
            );
          }
          return const VideoScreen(videoUrl: '');
        },
        webdavSettings: (_) => const WebDavSettingsScreen(),
      };
}
