import 'package:flutter/material.dart';

import 'models/models.dart';
import 'screens/about_screen.dart';
import 'screens/app_log_screen.dart';
import 'screens/association_screen.dart';
import 'screens/browser_screen.dart';
import 'screens/dict_screen.dart';
import 'screens/audio_screen.dart';
import 'screens/auto_task_screen.dart';
import 'screens/book_group_screen.dart';
import 'screens/book_info_screen.dart';
import 'screens/bookshelf_manage_screen.dart';
import 'screens/cache_download_screen.dart';
import 'screens/cache_settings_screen.dart';
import 'screens/offline_cache_screen.dart';
import 'screens/edit_book_info_screen.dart';
import 'screens/bookmark_screen.dart';
import 'screens/change_cover_screen.dart';
import 'screens/change_source_screen.dart';
import 'screens/explore_show_screen.dart';
import 'screens/file_manage_screen.dart';
import 'screens/font_screen.dart';
import 'screens/highlight_rules_screen.dart';
import 'screens/other_settings_screen.dart';
import 'screens/home_screen.dart';
import 'screens/import_screen.dart';
import 'screens/qrcode_screen.dart';
import 'screens/search_content_screen.dart';
import 'screens/read_record_screen.dart';
import 'screens/reader_screen.dart';
import 'screens/reader_comic_screen.dart';
import 'screens/remote_book_screen.dart';
import 'screens/replace_rules_screen.dart';
import 'screens/rss_favorites_screen.dart';
import 'screens/rss_source_debug_screen.dart';
import 'screens/rss_source_manage_screen.dart';
import 'screens/rss_screen.dart';
import 'screens/rule_sub_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/source_screen.dart';
import 'screens/source_edit_screen.dart';
import 'screens/rss_source_edit_screen.dart';
import 'screens/source_debug_screen.dart';
import 'screens/read_aloud_config_screen.dart';
import 'screens/theme_config_screen.dart';
import 'screens/bottom_bar_skin_screen.dart';
import 'screens/toc_screen.dart';
import 'screens/txt_toc_rules_screen.dart';
import 'screens/video_screen.dart';
import 'screens/webdav_settings_screen.dart';
import 'screens/welcome_config_screen.dart';
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
  static const cacheDownloads = '/cache_downloads';
  // [UI-fix v2.0.17 | 2026-08-11] 离线缓存页（对齐原版 CacheActivity 书籍列表）— Reasonix
  static const offlineCache = '/offline_cache';
  static const rss = '/rss';
  static const ruleSub = '/rule_sub';
  static const audio = '/audio';
  static const bookInfo = '/book_info';
  static const editBookInfo = '/edit_book_info';
  static const changeSource = '/change_source';
  static const readingStats = '/reading_stats'; // 历史别名，重定向到阅读记录
  static const readRecord = '/read_record';
  static const bookmarks = '/bookmarks';
  static const replaceRules = '/replace_rules';
  static const autoTasks = '/auto_tasks';
  static const association = '/association';
  static const sourceDebug = '/sources/debug';
  static const rssSourceEdit = '/rss/edit';
  static const readAloudConfig = '/read_aloud_config';
  static const themeConfig = '/theme_config';
  static const bottomBarSkin = '/bottom_bar_skin';
  static const importBooks = '/import_books';
  static const remoteBooks = '/remote_books';
  static const bookGroups = '/book_groups';
  static const bookshelfManage = '/bookshelf/manage';
  static const searchContent = '/search_content';
  // [UI-fix v2.0.3 | 2026-08-08] 新增独立目录页路由（对齐原版 TocActivity） — Qoder
  static const toc = '/toc';
  static const about = '/about';
  static const appLog = '/app_log';
  // discover 路由已删除（原版不存在的功能）
  // [UI-fix v2.0.2 | 2026-08-06] 结构治理：删除 rssConfig 路由（原版无此页，订阅源管理统一走 rssSourceManage）— Qoder
  static const rssSourceManage = '/rss/manage';
  static const rssFavorites = '/rss/favorites';
  static const rssSourceDebug = '/rss/source_debug';
  static const changeCover = '/change_cover';
  static const txtTocRules = '/txt_toc_rules';
  static const dict = '/dict';
  static const fonts = '/fonts';
  static const highlightRules = '/highlight_rules';
  static const fileManage = '/file_manage';
  static const qrcode = '/qrcode';
  static const welcome = '/welcome';
  static const welcomeConfig = '/welcome_config';
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
        search: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          String? initialQuery;
          List<String>? sourceUrls;
          List<String>? initialGroups;
          if (args is String) {
            initialQuery = args;
          } else if (args is Map) {
            if (args['query'] is String) {
              initialQuery = args['query'] as String;
            }
            // 发现页「搜索」入口：预选指定书源（发现页修复 R2）
            if (args['sourceUrl'] is String) {
              sourceUrls = [args['sourceUrl'] as String];
            } else if (args['sourceUrls'] is List) {
              sourceUrls =
                  (args['sourceUrls'] as List).whereType<String>().toList();
            }
            // 路由 groups 参数：预选搜索分组（对齐原版 receiptIntent searchScope）
            if (args['groups'] is List) {
              initialGroups =
                  (args['groups'] as List).whereType<String>().toList();
            }
          }
          return SearchScreen(
            initialQuery: initialQuery,
            initialSourceUrls: sourceUrls,
            initialGroups: initialGroups,
          );
        },
        sources: (_) => const SourceScreen(),
        sourceEdit: (context) {
          // 发现页编辑入口传入完整 BookSource 对象；未传入则新建
          //（此前忽略 arguments → 打开空表单，「编辑页没有书源信息」根因）
          final args = ModalRoute.of(context)?.settings.arguments;
          return SourceEditScreen(source: args is BookSource ? args : null);
        },
        exploreShow: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final exploreArgs = args is ExploreShowArgs ? args : null;
          return ExploreShowScreen(args: exploreArgs);
        },
        settings: (_) => const SettingsScreen(),
        otherSettings: (_) => const OtherSettingsScreen(),
        cacheSettings: (_) => const CacheSettingsScreen(),
        cacheDownloads: (_) => const CacheDownloadScreen(),
        offlineCache: (_) => const OfflineCacheScreen(),
        rss: (_) => const RssScreen(),
        ruleSub: (_) => const RuleSubScreen(),
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
        readingStats: (_) => const ReadRecordScreen(),
        readRecord: (_) => const ReadRecordScreen(),
        bookmarks: (_) => const BookmarkScreen(),
        replaceRules: (context) {
          // [UI-fix v2.0.2 | 2026-08-06] 支持 String 路由参数：阅读器长按
          // 选中文本作为新规则 pattern 预填 — Qoder
          final args = ModalRoute.of(context)?.settings.arguments;
          final pattern = args is String ? args : null;
          return ReplaceRulesScreen(initialPattern: pattern);
        },
        autoTasks: (context) {
          // [UI-fix v2.0.3 | 2026-08-09] 支持按任务编辑/预建新建路由参数
          //（Task #39 §5.11-2）：Map<String,dynamic>
          // {'editTaskId': String} 或 {'newTask': Map<String,dynamic>}，
          // is Map 运行时兼容判定 — Qoder
          final args = ModalRoute.of(context)?.settings.arguments;
          if (args is Map) {
            final editId = args['editTaskId'];
            final newTask = args['newTask'];
            return AutoTaskScreen(
              initialEditTaskId: editId is String ? editId : null,
              initialNewTask: newTask is Map
                  ? Map<String, dynamic>.from(newTask)
                  : null,
            );
          }
          return const AutoTaskScreen();
        },
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
        bottomBarSkin: (_) => const BottomBarSkinScreen(),
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
          // [UI-fix v2.0.2 | 2026-08-06] 支持 Map 传参 {book, query}：
          // 阅读器长按选中文本作为初始查询词 — Qoder
          if (args is Map && args['book'] is Book) {
            final query = args['query'];
            return SearchContentScreen(
              book: args['book'] as Book,
              initialQuery: query is String ? query : null,
            );
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
        // [UI-fix v2.0.3 | 2026-08-08] 独立目录页（对齐原版 TocActivity）：
        // 优先接收 Book 对象，兼容 Map 传参（is Map 运行时判定规范） — Qoder
        toc: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          if (args is Book) {
            return TocScreen(book: args);
          }
          if (args is Map && args['book'] is Book) {
            return TocScreen(book: args['book'] as Book);
          }
          // 缺少书籍对象时回退到首页，避免崩溃
          return const HomeScreen();
        },
        appLog: (_) => const AppLogScreen(),
        rssSourceManage: (_) => const RssSourceManageScreen(),
        rssFavorites: (_) => const RssFavoritesScreen(),
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
        highlightRules: (_) => const HighlightRulesScreen(),
        fileManage: (_) => const FileManageScreen(),
        qrcode: (_) => const QrcodeScreen(),
        welcome: (_) => const WelcomeScreen(),
        welcomeConfig: (_) => const WelcomeConfigScreen(),
        browser: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          // 平台桥接分发携带 url/html/title（Task #114）— QoderCN
          // 路由参数统一 is Map 运行时兼容判定（Map<String,dynamic> 规范）
          if (args is Map) {
            return BrowserScreen(
              initialUrl: args['url']?.toString(),
              initialHtml: args['html']?.toString(),
              title: args['title']?.toString(),
            );
          }
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
          // [UI-fix v2.0.12] 视频源书籍：章节列表 + 当前章播放（对齐原版
          // VideoPlayerActivity 接收 bookUrl 语义）— Reasonix
          if (args is Book) {
            return VideoScreen(
              videoUrl: '',
              title: args.name,
              book: args,
            );
          }
          return const VideoScreen(videoUrl: '');
        },
        webdavSettings: (_) => const WebDavSettingsScreen(),
      };
}
