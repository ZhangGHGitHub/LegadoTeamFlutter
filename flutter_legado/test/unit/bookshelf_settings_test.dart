// 书架布局配置模型/持久化（设置批6a-1）
//
// 覆盖：参考版默认值逐项、越界收敛、键名、旧 bookshelf_layout 一次性迁移、
// 变更键增量写盘、「忽略书架布局」备份过滤。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/bookshelf_settings.dart';
import 'package:flutter_legado/src/providers/bookshelf_settings/bookshelf_settings_notifier.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  group('BookshelfSettings 默认值（参考 BookshelfSettings.kt:5-57）', () {
    test('字段数与持久化键数一致（48 项，对齐参考 BookshelfSettings 字段）', () {
      expect(BookshelfSettings.prefKeys, hasLength(48));
      expect(BookshelfSettings.defaults.toPrefMap(), hasLength(48));
    });

    test('默认值逐项对齐参考版', () {
      const s = BookshelfSettings.defaults;
      expect(s.bookGroupStyle, 0);
      expect(s.hideEmptyGroups, isTrue);
      expect(s.bookshelfSort, 0);
      expect(s.bookshelfSortOrder, 1);
      expect(s.showUnread, isTrue);
      expect(s.showUnreadNew, isTrue);
      expect(s.showTip, isFalse);
      expect(s.showBookCount, isTrue);
      expect(s.showLastUpdateTime, isFalse);
      expect(s.showBookIntro, isFalse);
      expect(s.bookshelfShowIntro, isTrue);
      expect(s.bookshelfShowTag, isTrue);
      expect(s.bookshelfShowLatestChapter, isTrue);
      expect(s.bookshelfIntroMaxLines, 0);
      expect(s.showWaitUpCount, isFalse);
      expect(s.showBookshelfFastScroller, isFalse);
      expect(s.shouldShowExpandButton, isFalse);
      expect(s.bookshelfRefreshingLimit, 0);
      expect(s.bookshelfLayoutModePortrait, 1);
      expect(s.bookshelfLayoutGridPortrait, 3);
      expect(s.bookshelfLayoutModeLandscape, 1);
      expect(s.bookshelfLayoutGridLandscape, 7);
      expect(s.bookshelfLayoutListPortrait, 1);
      expect(s.bookshelfLayoutListLandscape, 1);
      expect(s.bookshelfGridLayout, 0);
      expect(s.bookshelfLayoutCompact, isFalse);
      expect(s.bookshelfListCoverCenter, isTrue);
      expect(s.bookshelfListIntroBelowContent, isFalse);
      expect(s.bookshelfShowDivider, isTrue);
      expect(s.bookshelfTitleSmallFont, isFalse);
      expect(s.bookshelfTitleCenter, isTrue);
      expect(s.bookshelfTitleMaxLines, 2);
      expect(s.bookshelfCoverShadow, isFalse);
      expect(s.bookshelfCardColor, 0);
      expect(s.bookshelfCardColorDark, 0);
      expect(s.bookshelfListCoverWidth, 84);
      expect(s.bookshelfGridCoverWidth, 120);
      // 文件夹模式默认值（6a-2，对齐参考 BookshelfSettings.kt）
      expect(s.bookshelfFolderLayoutModePortrait, 1);
      expect(s.bookshelfFolderLayoutGridPortrait, 3);
      expect(s.bookshelfFolderLayoutModeLandscape, 1);
      expect(s.bookshelfFolderLayoutGridLandscape, 7);
      expect(s.bookshelfFolderLayoutListPortrait, 1);
      expect(s.bookshelfFolderLayoutListLandscape, 1);
      expect(s.bookshelfGroupListStyle, 0);
      expect(s.bookshelfGroupCoverCount, 4);
      expect(s.bookshelfSearchActionDirectToSearch, isTrue);
      expect(s.autoRefreshBook, isFalse);
      expect(s.saveTabPosition, -1);
    });

    test('按方向读取布局模式/列数', () {
      const s = BookshelfSettings(
        bookshelfLayoutModePortrait: 0,
        bookshelfLayoutModeLandscape: 1,
        bookshelfLayoutGridPortrait: 4,
        bookshelfLayoutGridLandscape: 9,
        bookshelfLayoutListPortrait: 2,
        bookshelfLayoutListLandscape: 3,
        bookshelfFolderLayoutModePortrait: 0,
        bookshelfFolderLayoutModeLandscape: 1,
        bookshelfFolderLayoutGridPortrait: 5,
        bookshelfFolderLayoutGridLandscape: 11,
        bookshelfFolderLayoutListPortrait: 2,
        bookshelfFolderLayoutListLandscape: 4,
      );
      expect(s.layoutModeFor(isLandscape: false), 0);
      expect(s.layoutModeFor(isLandscape: true), 1);
      expect(s.gridColumnsFor(isLandscape: false), 4);
      expect(s.gridColumnsFor(isLandscape: true), 9);
      expect(s.listColumnsFor(isLandscape: false), 2);
      expect(s.listColumnsFor(isLandscape: true), 3);
      expect(s.folderLayoutModeFor(isLandscape: false), 0);
      expect(s.folderLayoutModeFor(isLandscape: true), 1);
      expect(s.folderGridColumnsFor(isLandscape: false), 5);
      expect(s.folderGridColumnsFor(isLandscape: true), 11);
      expect(s.folderListColumnsFor(isLandscape: false), 2);
      expect(s.folderListColumnsFor(isLandscape: true), 4);
      expect(s.cardColorFor(isDark: true), 0);
    });
  });

  group('BookshelfSettings 越界收敛', () {
    test('列数/封面宽/行数/刷新限制全部夹到参考范围', () {
      const raw = BookshelfSettings(
        bookGroupStyle: 9,
        bookshelfSort: -2,
        bookshelfSortOrder: 5,
        bookshelfRefreshingLimit: 999,
        bookshelfLayoutModePortrait: 3,
        bookshelfLayoutGridPortrait: 0,
        bookshelfLayoutGridLandscape: 99,
        bookshelfLayoutListPortrait: 0,
        bookshelfLayoutListLandscape: 9,
        bookshelfGridLayout: 7,
        bookshelfTitleMaxLines: 0,
        bookshelfIntroMaxLines: 99,
        bookshelfListCoverWidth: 10,
        bookshelfGridCoverWidth: 300,
        bookshelfGroupCoverCount: 0,
      );
      final s = raw.normalized();
      expect(s.bookGroupStyle, 2);
      expect(s.bookshelfSort, 0);
      expect(s.bookshelfSortOrder, 1);
      expect(s.bookshelfRefreshingLimit, 100);
      expect(s.bookshelfLayoutModePortrait, 1);
      expect(s.bookshelfLayoutGridPortrait, 1);
      expect(s.bookshelfLayoutGridLandscape, 15);
      expect(s.bookshelfLayoutListPortrait, 1);
      expect(s.bookshelfLayoutListLandscape, 5);
      expect(s.bookshelfGridLayout, 2);
      expect(s.bookshelfTitleMaxLines, 1);
      expect(s.bookshelfIntroMaxLines, 10);
      expect(s.bookshelfListCoverWidth, 40);
      expect(s.bookshelfGridCoverWidth, 150);
      expect(s.bookshelfGroupCoverCount, 1);
    });

    test('fromPrefMap 兼容数字字符串/浮点并收敛', () {
      final s = BookshelfSettings.fromPrefMap({
        BookshelfSettings.keyBookshelfLayoutGridPortrait: '5',
        BookshelfSettings.keyBookshelfLayoutListPortrait: 2.0,
        BookshelfSettings.keyBookshelfGridCoverWidth: 999,
        BookshelfSettings.keyShowUnread: 'false',
        BookshelfSettings.keyHideEmptyGroups: false,
      });
      expect(s.bookshelfLayoutGridPortrait, 5);
      expect(s.bookshelfLayoutListPortrait, 2);
      expect(s.bookshelfGridCoverWidth, 150);
      expect(s.showUnread, isFalse);
      expect(s.hideEmptyGroups, isFalse);
    });
  });

  group('BookshelfSettingsNotifier 持久化/迁移', () {
    test('旧 bookshelf_layout=true → 横竖屏都写网格', () async {
      SharedPreferences.setMockInitialValues({'bookshelf_layout': true});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(bookshelfSettingsProvider.notifier);
      await notifier.waitForLoad();

      final s = container.read(bookshelfSettingsProvider);
      expect(s.bookshelfLayoutModePortrait, 1);
      expect(s.bookshelfLayoutModeLandscape, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(BookshelfSettings.keyBookshelfLayoutModePortrait), 1);
      expect(
        prefs.getInt(BookshelfSettings.keyBookshelfLayoutModeLandscape),
        1,
      );
    });

    test('旧 bookshelf_layout=false → 横竖屏都写列表', () async {
      SharedPreferences.setMockInitialValues({'bookshelf_layout': false});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(bookshelfSettingsProvider.notifier).waitForLoad();

      final s = container.read(bookshelfSettingsProvider);
      expect(s.bookshelfLayoutModePortrait, 0);
      expect(s.bookshelfLayoutModeLandscape, 0);
    });

    test('新方向键存在时忽略旧键（已显式设置保留）', () async {
      SharedPreferences.setMockInitialValues({
        'bookshelf_layout': false,
        BookshelfSettings.keyBookshelfLayoutModePortrait: 1,
        BookshelfSettings.keyBookshelfLayoutModeLandscape: 1,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(bookshelfSettingsProvider.notifier).waitForLoad();

      final s = container.read(bookshelfSettingsProvider);
      expect(s.bookshelfLayoutModePortrait, 1);
      expect(s.bookshelfLayoutModeLandscape, 1);
    });

    test('旧 Android 键 bookshelfLayout 同样迁移（bool）', () async {
      SharedPreferences.setMockInitialValues({'bookshelfLayout': false});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(bookshelfSettingsProvider.notifier).waitForLoad();

      final s = container.read(bookshelfSettingsProvider);
      expect(s.bookshelfLayoutModePortrait, 0);
      expect(s.bookshelfLayoutModeLandscape, 0);
    });

    test('旧键兼容 int / string 类型（不因类型不同抛错/跳过）', () async {
      SharedPreferences.setMockInitialValues({
        'bookshelfLayout': 'false',
        'bookshelf_layout': 1,
      });
      var container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(bookshelfSettingsProvider.notifier).waitForLoad();
      // 优先读取我方历史键 bookshelf_layout=1
      expect(
        container.read(bookshelfSettingsProvider).bookshelfLayoutModePortrait,
        1,
      );

      container.dispose();
      SharedPreferences.setMockInitialValues({'bookshelfLayout': 0});
      container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(bookshelfSettingsProvider.notifier).waitForLoad();
      expect(
        container.read(bookshelfSettingsProvider).bookshelfLayoutModePortrait,
        0,
      );
    });

    test('单方向新键已存在时只迁移缺失方向', () async {
      SharedPreferences.setMockInitialValues({
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        'bookshelfLayout': true,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(bookshelfSettingsProvider.notifier).waitForLoad();

      final s = container.read(bookshelfSettingsProvider);
      expect(s.bookshelfLayoutModePortrait, 0, reason: '已显式设置保留');
      expect(s.bookshelfLayoutModeLandscape, 1, reason: '缺失方向按旧键补网格');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(BookshelfSettings.keyBookshelfLayoutModeLandscape),
        1,
      );
    });

    test('update 只写发生变化的键并即时更新状态', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(bookshelfSettingsProvider.notifier);
      await notifier.waitForLoad();

      await notifier.update(
        (s) => s.copyWith(
          bookshelfSort: 2,
          bookshelfSortOrder: 0,
          bookshelfGridCoverWidth: 100,
        ),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(BookshelfSettings.keyBookshelfSort), 2);
      expect(prefs.getInt(BookshelfSettings.keyBookshelfSortOrder), 0);
      expect(prefs.getInt(BookshelfSettings.keyBookshelfGridCoverWidth), 100);
      expect(
        prefs.containsKey(BookshelfSettings.keyShowUnread),
        isFalse,
        reason: '未变化键不写盘',
      );
      expect(container.read(bookshelfSettingsProvider).bookshelfSort, 2);
    });

    test('持久化值重启后恢复', () async {
      SharedPreferences.setMockInitialValues({
        BookshelfSettings.keyBookshelfSort: 5,
        BookshelfSettings.keyBookshelfTitleMaxLines: 4,
        BookshelfSettings.keyBookshelfShowDivider: false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(bookshelfSettingsProvider.notifier).waitForLoad();

      final s = container.read(bookshelfSettingsProvider);
      expect(s.bookshelfSort, 5);
      expect(s.bookshelfTitleMaxLines, 4);
      expect(s.bookshelfShowDivider, isFalse);
    });

    test('reload 重新读取持久化值（备份恢复同会话生效）', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(bookshelfSettingsProvider.notifier);
      await notifier.waitForLoad();
      expect(container.read(bookshelfSettingsProvider).bookshelfSort, 0);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(BookshelfSettings.keyBookshelfSort, 4);
      await prefs.setInt(BookshelfSettings.keyBookshelfTitleMaxLines, 5);
      await notifier.reload();

      final s = container.read(bookshelfSettingsProvider);
      expect(s.bookshelfSort, 4);
      expect(s.bookshelfTitleMaxLines, 5);
    });
  });

  group('备份恢复忽略书架布局', () {
    test('全部书架键在 bookshelfLayout 忽略项下不参与备份', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('bookshelfShowTag', false);
      await prefs.setInt(BookshelfSettings.keyBookshelfSort, 2);
      await prefs.setInt(BookshelfSettings.keyBookshelfGridCoverWidth, 90);
      await prefs.setBool('bookshelf_layout', true);
      await prefs.setString('unrelated_key', 'keep');

      for (final key in BookshelfSettings.prefKeys) {
        expect(
          RestoreIgnorePrefs.keyIsNotIgnore(key, {'bookshelfLayout': true}),
          isFalse,
          reason: '$key 应受书架布局忽略项约束',
        );
      }
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore('bookshelf_layout', {
          'bookshelfLayout': true,
        }),
        isFalse,
      );

      final collected = await RestoreIgnorePrefs.collectForBackup({
        'bookshelfLayout': true,
      });
      expect(
        collected.containsKey(BookshelfSettings.keyBookshelfSort),
        isFalse,
      );
      expect(collected.containsKey('bookshelfShowTag'), isFalse);
      expect(collected['unrelated_key'], 'keep');

      final kept = await RestoreIgnorePrefs.collectForBackup({});
      expect(kept[BookshelfSettings.keyBookshelfSort], 2);
      expect(kept[BookshelfSettings.keyBookshelfGridCoverWidth], 90);
    });
  });
}
