// L10N 阶段 1（裁决 4=B：补齐英文、贴近参考版）验收测试
//
// 覆盖：
// 1. AppStrings 英文基座：4 个高频界面（书架/阅读器/搜索/设置）抽取出的
//    代表性 key 在 en 下必须是英文、zh 下必须是中文，且 zh/en 不允许相同
//    （同形项如 English 单独排除）。
// 2. `system` locale 语义：跟随 PlatformDispatcher.locale（中文 → zh，
//    其余 → en），不再无条件回落中文。
// 3. 参数化文案（计数/错误）在两种 locale 下插值正确。
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/l10n/app_strings.dart';

/// 抽取覆盖的代表性静态 key（按界面分组）
const Map<String, List<String Function()>> _samples = {
  '书架': [
    _shelfSelectAll,
    _shelfBookGroupMenu,
    _shelfImportBookList,
    _shelfPrivateGroup,
    _shelfBookTypeNovel,
  ],
  '阅读器': [
    _readerAddToShelfTitle,
    _readerPageMargins,
    _readerToolbarStyle,
    _readerTapActionNextPage,
    _readerCompactTitle,
  ],
  '搜索': [
    _searchScope,
    _searchPreciseSearch,
    _searchStopSearch,
    _searchClearSearchHistory,
    _searchResultFilterTitle,
  ],
  '设置': [
    _settingsAppearanceEntry,
    _settingsAutoRefreshLabel,
    _settingsCompressDatabaseLabel,
    _settingsCheckSourceConfigLabel,
    _settingsExitLabel,
  ],
};

String _shelfSelectAll() => AppStrings.selectAll;
String _shelfBookGroupMenu() => AppStrings.bookGroupMenu;
String _shelfImportBookList() => AppStrings.importBookList;
String _shelfPrivateGroup() => AppStrings.privateGroup;
String _shelfBookTypeNovel() => AppStrings.bookTypeNovel;

String _readerAddToShelfTitle() => AppStrings.addToShelfTitle;
String _readerPageMargins() => AppStrings.pageMargins;
String _readerToolbarStyle() => AppStrings.toolbarStyle;
String _readerTapActionNextPage() => AppStrings.tapActionNextPage;
String _readerCompactTitle() => AppStrings.compactTitle;

String _searchScope() => AppStrings.searchScope;
String _searchPreciseSearch() => AppStrings.preciseSearch;
String _searchStopSearch() => AppStrings.stopSearch;
String _searchClearSearchHistory() => AppStrings.clearSearchHistory;
String _searchResultFilterTitle() => AppStrings.resultFilterTitle;

String _settingsAppearanceEntry() => AppStrings.appearanceEntry;
String _settingsAutoRefreshLabel() => AppStrings.autoRefreshLabel;
String _settingsCompressDatabaseLabel() => AppStrings.compressDatabaseLabel;
String _settingsCheckSourceConfigLabel() => AppStrings.checkSourceConfigLabel;
String _settingsExitLabel() => AppStrings.exitLabel;

/// 中文字符检测（CJK 统一表意文字基本区）
bool _hasCjk(String value) =>
    RegExp(r'[\u4e00-\u9fff]').hasMatch(value);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => AppStrings.setLocale('zh'));

  group('L10N 阶段 1：4 个高频界面抽取的文案双语齐备', () {
    for (final entry in _samples.entries) {
      group(entry.key, () {
        for (final sample in entry.value) {
          test('英文 locale 下无中文残留（${sample()}）', () {
            AppStrings.setLocale('en');
            final value = sample();
            expect(value, isNotEmpty);
            expect(
              _hasCjk(value),
              isFalse,
              reason: '英文 locale 下仍出现中文：$value',
            );
          });

          test('中文 locale 下为中文（${sample()}）', () {
            AppStrings.setLocale('zh');
            final value = sample();
            expect(value, isNotEmpty);
            expect(_hasCjk(value), isTrue, reason: '中文 locale 下缺少中文：$value');
          });
        }
      });
    }
  });

  group('L10N 阶段 1：参数化文案双语插值', () {
    test('书架：书籍数 / 删除确认 / 分组计数', () {
      AppStrings.setLocale('zh');
      expect(AppStrings.bookCount(3), '3 本');
      expect(AppStrings.confirmDeleteBookNamed('测试书'), '确定要删除《测试书》吗？');
      expect(AppStrings.selectedCount(2), '已选2本');

      AppStrings.setLocale('en');
      expect(AppStrings.bookCount(3), '3 book(s)');
      expect(AppStrings.confirmDeleteBookNamed('Test'), 'Delete "Test"?');
      expect(AppStrings.selectedCount(2), '2 selected');
    });

    test('搜索：进度胶囊 / 失败横幅 / 空结果引导', () {
      AppStrings.setLocale('zh');
      expect(AppStrings.searchProgress(5, 2, 8), '结果 5 · 进度 2/8');
      expect(AppStrings.searchFailureMultiple(3), '3 个书源搜索失败，点击展开');

      AppStrings.setLocale('en');
      expect(AppStrings.searchProgress(5, 2, 8), 'Results 5 · Progress 2/8');
      expect(AppStrings.searchFailureMultiple(3), '3 sources failed. Tap to expand.');
      expect(
        AppStrings.emptyScopeDisablePrecise('A'),
        'No results in group A. Disable precise search?',
      );
    });

    test('阅读器：放入书架确认 / 全局页码 / 书签提示', () {
      AppStrings.setLocale('zh');
      expect(AppStrings.addToShelfConfirm('书A'), '是否将《书A》放入书架？');
      expect(AppStrings.globalPageIndicator(2, 9), '全局页 2 / 9');

      AppStrings.setLocale('en');
      expect(AppStrings.addToShelfConfirm('Book'), 'Add "Book" to the bookshelf?');
      expect(AppStrings.globalPageIndicator(2, 9), 'Global page 2 / 9');
      expect(AppStrings.bookmarkAdded('Ch1'), 'Bookmark added: Ch1');
    });

    test('设置：端口 / 缓存 / 校验摘要', () {
      AppStrings.setLocale('zh');
      expect(AppStrings.currentPort(1122), '当前端口 1122');
      expect(AppStrings.currentPortStopped(0), '当前端口 0（已停止）');

      AppStrings.setLocale('en');
      expect(AppStrings.currentPort(1122), 'Current port: 1122');
      expect(AppStrings.currentPortStopped(0), 'Current port: 0 (stopped)');
      expect(AppStrings.configuredCount(4), '4 entries configured');
    });
  });

  group('L10N 阶段 1：system locale 语义（跟随系统，不再固定中文）', () {
    test('系统为 zh → zh', () {
      expect(
        AppStrings.startupLocaleOf('system',
            systemLocaleOverride: const Locale('zh', 'CN')),
        'zh',
      );
      expect(AppStrings.systemLocale(const Locale('zh', 'TW')), 'zh');
    });

    test('系统非 zh（en/ja/fr）→ en', () {
      for (final code in ['en', 'ja', 'fr', 'ko']) {
        expect(
          AppStrings.startupLocaleOf('system',
              systemLocaleOverride: Locale(code)),
          'en',
          reason: '系统语言 $code 应回落英文基座',
        );
      }
    });

    test('显式 zh/en 优先于系统语言；脏值仍兜底 zh', () {
      expect(
        AppStrings.startupLocaleOf('zh',
            systemLocaleOverride: const Locale('en', 'US')),
        'zh',
      );
      expect(
        AppStrings.startupLocaleOf('en',
            systemLocaleOverride: const Locale('zh', 'CN')),
        'en',
      );
      expect(
        AppStrings.startupLocaleOf('fr',
            systemLocaleOverride: const Locale('en', 'US')),
        'zh',
      );
    });
  });
}
