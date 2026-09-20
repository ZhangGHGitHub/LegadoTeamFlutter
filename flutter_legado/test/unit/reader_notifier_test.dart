import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/providers/theme/theme_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    // 创建容器并覆盖 bookApiProvider 注入 mock
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
      ],
    );
    addTearDown(container.dispose);
  });

  /// 等待异步初始化完成（build() 中的 _loadSettings microtask）
  Future<void> pumpInit() async {
    await Future.delayed(Duration.zero);
    await Future.delayed(Duration.zero);
  }

  ReaderState readState() => container.read(readerNotifierProvider);
  ReaderNotifier readNotifier() =>
      container.read(readerNotifierProvider.notifier);

  // ===== 测试数据 =====

  const testBook = Book(
    bookUrl: 'https://book.com/1',
    name: '测试书籍',
    author: '作者',
    origin: 'https://source.com',
    durChapterIndex: 0,
  );

  final testChapters = [
    const BookChapter(title: '第一章', index: 0),
    const BookChapter(title: '第二章', index: 1),
    const BookChapter(title: '第三章', index: 2),
  ];

  /// 配置 openBook 所需的完整 mock 链
  void stubOpenBook({List<BookChapter>? chapters, String content = '章节内容'}) {
    when(() => mockApi.getChapters(any()))
        .thenAnswer((_) async => chapters ?? testChapters);
    when(() => mockApi.getChapterContentFull(any(), any()))
        .thenAnswer((_) async => content);
    when(() => mockApi.updateReadingProgress(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
          chapterPos: any(named: 'chapterPos'),
        )).thenAnswer((_) async {});
  }

  group('ReaderState 初始状态', () {
    test('初始无当前书籍', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().currentBook, isNull);
      expect(readState().chapters, isEmpty);
      expect(readState().chapterContent, equals(''));
    });

    test('初始非加载状态', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().isLoading, isFalse);
      expect(readState().error, isNull);
    });

    test('初始控制面板隐藏', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().showControls, isFalse);
    });

    test('初始阅读设置默认值', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      // [PARITY C2 R1/R2] 默认字号 18→20、行距 1.67→1.7（对齐参考）
      expect(readState().fontSize, equals(20.0));
      expect(readState().lineHeight, equals(1.7));
      expect(readState().backgroundColor, equals(ReaderBackground.white));
      // 默认翻页模式为 cover（对齐 Android 原版）
      expect(readState().pageTurnMode, equals(PageTurnMode.cover));
    });

    test('初始无上一章/下一章', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().hasPreviousChapter, isFalse);
      expect(readState().hasNextChapter, isFalse);
    });

    test('初始进度为 0', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().readingProgress, equals(0));
    });

    test('初始 currentChapter 为 null', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().currentChapter, isNull);
    });
  });

  group('PageTurnMode 枚举', () {
    test('displayName 返回正确中文名', () {
      expect(PageTurnMode.scroll.displayName, equals('滚动'));
      expect(PageTurnMode.slide.displayName, equals('滑动'));
      expect(PageTurnMode.simulate.displayName, equals('仿真'));
      expect(PageTurnMode.none.displayName, equals('无动画'));
      expect(PageTurnMode.cover.displayName, equals('覆盖'));
    });

    test('icon 返回正确表情', () {
      expect(PageTurnMode.scroll.icon, equals('📜'));
      expect(PageTurnMode.slide.icon, equals('👈'));
      expect(PageTurnMode.simulate.icon, equals('📖'));
      expect(PageTurnMode.none.icon, equals('⚡'));
      expect(PageTurnMode.cover.icon, equals('📄'));
    });

    test('values 包含 5 种模式', () {
      expect(PageTurnMode.values.length, equals(5));
    });
  });

  group('PageTurnMode.fromStorage 双通道恢复', () {
    test('name 优先：name="cover" 返回 cover', () {
      expect(PageTurnMode.fromStorage('cover', null), PageTurnMode.cover);
    });

    test('name 优先：name="slide" 即使 legacyIndex=0 也返回 slide', () {
      expect(PageTurnMode.fromStorage('slide', 0), PageTurnMode.slide);
    });

    test('name 为空时回退 legacyIndex=0 → scroll', () {
      expect(PageTurnMode.fromStorage(null, 0), PageTurnMode.scroll);
    });

    test('name 为空时回退 legacyIndex=3 → none', () {
      expect(PageTurnMode.fromStorage(null, 3), PageTurnMode.none);
    });

    test('name 为空字符串时回退 legacyIndex', () {
      expect(PageTurnMode.fromStorage('', 1), PageTurnMode.slide);
    });

    test('name 无效且 legacyIndex 有效时回退 legacyIndex', () {
      expect(PageTurnMode.fromStorage('invalid_name', 2), PageTurnMode.simulate);
    });

    test('name 和 legacyIndex 都无效时默认 cover', () {
      expect(PageTurnMode.fromStorage(null, null), PageTurnMode.cover);
      expect(PageTurnMode.fromStorage('bad', -1), PageTurnMode.cover);
      expect(PageTurnMode.fromStorage('bad', 99), PageTurnMode.cover);
    });
  });

  group('ReaderNotifier 阅读设置', () {
    test('updateFontSize 正常设置', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().updateFontSize(22.0);
      expect(readState().fontSize, equals(22.0));
    });

    test('updateFontSize 低于下限被 clamp 到 12', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().updateFontSize(8.0);
      expect(readState().fontSize, equals(12.0));
    });

    test('updateFontSize 超过上限被 clamp 到 32', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().updateFontSize(50.0);
      expect(readState().fontSize, equals(32.0));
    });

    test('updateLineHeight 正常设置', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().updateLineHeight(2.0);
      expect(readState().lineHeight, equals(2.0));
    });

    test('updateLineHeight 低于下限被 clamp 到 1.0', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().updateLineHeight(0.5);
      expect(readState().lineHeight, equals(1.0));
    });

    // [UI-fix v2.0.4 | 2026-08-08] 行距上限 2.5 → 3.0（同步界面 Sheet
    // 行距滑条 1.0-3.0，对标原版 dsbLineSize 范围） — Qoder
    test('updateLineHeight 超过上限被 clamp 到 3.0', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().updateLineHeight(4.0);
      expect(readState().lineHeight, equals(3.0));
    });

    test('updateBackgroundColor 设置为预设绿色', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().updateBackgroundColor(ReaderBackground.green);
      expect(readState().backgroundColor, equals(ReaderBackground.green));
    });

    test('updateBackgroundColor 设置为自定义颜色', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      const custom = Color(0xFF123456);
      readNotifier().updateBackgroundColor(custom);
      expect(readState().backgroundColor, equals(custom));
    });

    test('updatePageTurnMode 切换翻页模式', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().updatePageTurnMode(PageTurnMode.slide);
      expect(readState().pageTurnMode, equals(PageTurnMode.slide));
      readNotifier().updatePageTurnMode(PageTurnMode.scroll);
      expect(readState().pageTurnMode, equals(PageTurnMode.scroll));
    });
  });

  group('ReaderNotifier loadSettings（SharedPreferences）', () {
    test('加载字体大小', () async {
      SharedPreferences.setMockInitialValues({'reader_font_size': 24.0});
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().fontSize, equals(24.0));
    });

    test('加载行距', () async {
      SharedPreferences.setMockInitialValues({'reader_line_height': 2.0});
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().lineHeight, equals(2.0));
    });

    test('加载背景色索引', () async {
      SharedPreferences.setMockInitialValues({'reader_bg_color_index': 1});
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().backgroundColor, equals(ReaderBackground.green));
    });

    test('背景色索引越界时保持默认', () async {
      SharedPreferences.setMockInitialValues({'reader_bg_color_index': 99});
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().backgroundColor, equals(ReaderBackground.white));
    });

    test('翻页模式 name 优先', () async {
      SharedPreferences.setMockInitialValues({
        'reader_flip_mode_name': 'slide',
        'reader_flip_mode': 0,
      });
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().pageTurnMode, equals(PageTurnMode.slide));
    });

    test('翻页模式回退 legacyIndex', () async {
      SharedPreferences.setMockInitialValues({'reader_flip_mode': 2});
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().pageTurnMode, equals(PageTurnMode.simulate));
    });
  });

  group('ReaderNotifier openBook（mock API）', () {
    test('成功加载章节列表', () async {
      stubOpenBook();
      container.read(readerNotifierProvider);
      await pumpInit();

      await readNotifier().openBook(testBook);

      expect(readState().currentBook, equals(testBook));
      expect(readState().chapters.length, equals(3));
      expect(readState().currentChapterIndex, equals(0));
      expect(readState().isLoading, isFalse);
      expect(readState().error, isNull);
    });

    test('加载章节内容', () async {
      stubOpenBook(content: '第一章正文内容');
      container.read(readerNotifierProvider);
      await pumpInit();

      await readNotifier().openBook(testBook);
      expect(readState().chapterContent, equals('第一章正文内容'));
    });

    test('失败时设置 BridgeError 错误', () async {
      when(() => mockApi.getChapters(any()))
          .thenThrow(const BridgeError(message: '书籍不存在'));
      container.read(readerNotifierProvider);
      await pumpInit();

      await readNotifier().openBook(testBook);

      expect(readState().error, equals('书籍不存在'));
      expect(readState().isLoading, isFalse);
    });

    test('失败时设置普通异常错误', () async {
      when(() => mockApi.getChapters(any())).thenThrow(Exception('网络错误'));
      container.read(readerNotifierProvider);
      await pumpInit();

      await readNotifier().openBook(testBook);

      expect(readState().error, contains('网络错误'));
      expect(readState().isLoading, isFalse);
    });

    test('durChapterIndex 越界时重置为 0', () async {
      stubOpenBook();
      container.read(readerNotifierProvider);
      await pumpInit();

      final book = testBook.copyWith(durChapterIndex: 99);
      await readNotifier().openBook(book);
      expect(readState().currentChapterIndex, equals(0));
    });

    test('openBook 后派生属性正确', () async {
      stubOpenBook();
      container.read(readerNotifierProvider);
      await pumpInit();

      await readNotifier().openBook(testBook);
      expect(readState().hasPreviousChapter, isFalse);
      expect(readState().hasNextChapter, isTrue);
      // 第 0 章 / 共 3 章 = 1/3
      expect(readState().readingProgress, closeTo(0.333, 0.01));
      expect(readState().currentChapter?.title, equals('第一章'));
    });
  });

  group('ReaderNotifier 章节导航（mock API）', () {
    setUp(() {
      stubOpenBook();
    });

    test('nextChapter 切换到下一章', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      await readNotifier().openBook(testBook);
      await readNotifier().nextChapter();
      expect(readState().currentChapterIndex, equals(1));
      expect(readState().currentChapterPos, equals(0));
    });

    test('nextChapter 在最后一章时不切换', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      final book = testBook.copyWith(durChapterIndex: 2);
      await readNotifier().openBook(book);
      await readNotifier().nextChapter();
      expect(readState().currentChapterIndex, equals(2));
    });

    test('prevChapter 切换到上一章', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      final book = testBook.copyWith(durChapterIndex: 1);
      await readNotifier().openBook(book);
      await readNotifier().prevChapter();
      expect(readState().currentChapterIndex, equals(0));
    });

    test('prevChapter 在第一章时不切换', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      await readNotifier().openBook(testBook);
      await readNotifier().prevChapter();
      expect(readState().currentChapterIndex, equals(0));
    });

    test('goToChapter 跳转到指定章节', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      await readNotifier().openBook(testBook);
      await readNotifier().goToChapter(2);
      expect(readState().currentChapterIndex, equals(2));
    });

    test('goToChapter 负索引不跳转', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      await readNotifier().openBook(testBook);
      await readNotifier().goToChapter(-1);
      expect(readState().currentChapterIndex, equals(0));
    });

    test('goToChapter 越界索引不跳转', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      await readNotifier().openBook(testBook);
      await readNotifier().goToChapter(99);
      expect(readState().currentChapterIndex, equals(0));
    });

    test('goToChapter 隐藏控制面板', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      await readNotifier().openBook(testBook);
      readNotifier().toggleControls(); // 先显示
      await readNotifier().goToChapter(1);
      expect(readState().showControls, isFalse);
    });
  });

  group('ReaderNotifier 控制面板', () {
    test('toggleControls 显示控制面板', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().toggleControls();
      expect(readState().showControls, isTrue);
    });

    test('toggleControls 再次切换隐藏', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().toggleControls();
      readNotifier().toggleControls();
      expect(readState().showControls, isFalse);
    });

    test('hideControls 隐藏已显示的面板', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().toggleControls();
      readNotifier().hideControls();
      expect(readState().showControls, isFalse);
    });

    test('hideControls 对已隐藏面板无效', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().hideControls();
      expect(readState().showControls, isFalse);
    });
  });

  group('ReaderNotifier 阅读位置', () {
    test('updatePosition 更新当前位置', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().updatePosition(100);
      expect(readState().currentChapterPos, equals(100));
    });

    test('updatePosition 可多次更新', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      readNotifier().updatePosition(50);
      readNotifier().updatePosition(200);
      expect(readState().currentChapterPos, equals(200));
    });
  });

  group('ReaderNotifier saveProgress（mock API）', () {
    test('无书籍时不调用 API', () async {
      container.read(readerNotifierProvider);
      await pumpInit();
      await readNotifier().saveProgress();
      verifyNever(() => mockApi.updateReadingProgress(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterPos: any(named: 'chapterPos'),
          ));
    });

    test('有书籍时调用 API', () async {
      stubOpenBook(chapters: [const BookChapter(title: 'ch1', index: 0)]);
      container.read(readerNotifierProvider);
      await pumpInit();

      const book = Book(bookUrl: 'https://b.com/1', name: 'test');
      await readNotifier().openBook(book);
      await readNotifier().saveProgress();

      verify(() => mockApi.updateReadingProgress(
            bookUrl: 'https://b.com/1',
            chapterIndex: 0,
            chapterPos: 0,
          )).called(greaterThan(0));
    });
  });

  group('ReaderState 派生属性', () {
    test('isDarkBackground 深色背景为 true', () {
      const state = ReaderState(backgroundColor: ReaderBackground.dark);
      expect(state.isDarkBackground, isTrue);
    });

    test('isDarkBackground 浅色背景为 false', () {
      const state = ReaderState(backgroundColor: ReaderBackground.white);
      expect(state.isDarkBackground, isFalse);
    });

    test('isDarkBackground 主题默认纯黑（M1 收尾微调）为 true', () {
      final state = ReaderState(backgroundColor: const Color(0xFF000000));
      expect(state.isDarkBackground, isTrue);
      expect(state.textColor, equals(const Color(0xFFCCCCCC)));
    });

    test('textColor 深色背景返回浅灰', () {
      const state = ReaderState(backgroundColor: ReaderBackground.dark);
      expect(state.textColor, equals(const Color(0xFFCCCCCC)));
    });

    test('textColor 浅色背景返回深灰', () {
      const state = ReaderState(backgroundColor: ReaderBackground.white);
      expect(state.textColor, equals(const Color(0xFF333333)));
    });
  });

  group('ReaderBackground 预设', () {
    test('预设列表包含 5 种颜色', () {
      expect(ReaderBackground.presets.length, equals(5));
    });

    test('标签列表与预设对应', () {
      expect(ReaderBackground.labels.length,
          equals(ReaderBackground.presets.length));
    });

    test('预设包含白色与护眼色', () {
      expect(ReaderBackground.presets, contains(ReaderBackground.white));
      expect(ReaderBackground.presets, contains(ReaderBackground.eyeProtect));
    });

    test('标签包含中文名称', () {
      expect(ReaderBackground.labels, contains('白色'));
      expect(ReaderBackground.labels, contains('夜间'));
    });
  });

  // ===== [M1 深色态默认修复] 深色主题下背景默认跟随深色 =====
  //
  // 行为契约：
  // - 深色主题 + 从未显式设置背景 → 默认纯黑 0xFF000000（对齐参考实测；
  //   夜间预设 ReaderBackground.dark 0xFF1A1A1A 保留为显式选项）
  // - 亮色主题 + 从未显式设置背景 → 默认白色（原行为不变）
  // - 用户显式选择（预设索引 / 自定义色）→ 一律保留，主题切换也不变
  // - 主题切换（setThemeMode，toggleDayNight 同路）→ 仅「从未显式设置」
  //   路径重新解析默认；ref.listen 钩子挂在 ReaderNotifier 上，
  //   监听值为切换后的新模式（setThemeMode 异步落盘，此刻不能重读 prefs）
  group('[M1] 深色态背景默认解析', () {
    test('深色主题 + 从未设置背景 → 默认纯黑（对齐参考）', () async {
      SharedPreferences.setMockInitialValues({'app_theme_mode': 'dark'});
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().backgroundColor, equals(const Color(0xFF000000)));
    });

    test('亮色主题 + 从未设置背景 → 默认白色（原默认不变）', () async {
      SharedPreferences.setMockInitialValues({'app_theme_mode': 'light'});
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().backgroundColor, equals(ReaderBackground.white));
    });

    test('深色主题 + 显式预设索引 1 → 保留 green', () async {
      SharedPreferences.setMockInitialValues({
        'app_theme_mode': 'dark',
        'reader_bg_color_index': 1,
      });
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().backgroundColor, equals(ReaderBackground.green));
    });

    test('深色主题 + 自定义背景 → 保留 custom', () async {
      const custom = Color(0xFF232323);
      SharedPreferences.setMockInitialValues({
        'app_theme_mode': 'dark',
        'reader_bg_use_custom': true,
        'reader_custom_bg_color': 0xFF232323,
      });
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().backgroundColor, equals(custom));
    });

    test('主题切换 深色→亮色 + 从未设置 → 重解析为白色', () async {
      SharedPreferences.setMockInitialValues({'app_theme_mode': 'dark'});
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().backgroundColor, equals(const Color(0xFF000000)));

      // 触发 ref.listen 钩子：监听值 next.themeMode=light 直接传入
      // reapply（此刻 prefs 尚未落盘，不能重读）
      await container
          .read(themeNotifierProvider.notifier)
          .setThemeMode(ThemeMode.light);
      await pumpInit();
      expect(readState().backgroundColor, equals(ReaderBackground.white));
    });

    test('主题切换 深色→亮色 + 显式 green → 仍 green（尊重显式选择）',
        () async {
      SharedPreferences.setMockInitialValues({
        'app_theme_mode': 'dark',
        'reader_bg_color_index': 1,
      });
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().backgroundColor, equals(ReaderBackground.green));

      await container
          .read(themeNotifierProvider.notifier)
          .setThemeMode(ThemeMode.light);
      await pumpInit();
      expect(readState().backgroundColor, equals(ReaderBackground.green));
    });

    test('主题切换 深色→亮色 + 自定义背景 → 仍 custom（尊重显式选择）',
        () async {
      const custom = Color(0xFF232323);
      SharedPreferences.setMockInitialValues({
        'app_theme_mode': 'dark',
        'reader_bg_use_custom': true,
        'reader_custom_bg_color': 0xFF232323,
      });
      container.read(readerNotifierProvider);
      await pumpInit();
      expect(readState().backgroundColor, equals(custom));

      await container
          .read(themeNotifierProvider.notifier)
          .setThemeMode(ThemeMode.light);
      await pumpInit();
      expect(readState().backgroundColor, equals(custom));
    });
  });
}
