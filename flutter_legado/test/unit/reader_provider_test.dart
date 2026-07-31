import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_legado/src/providers/reader_provider.dart';
import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/bridge/ffi.dart';

import '../mocks/mocks.dart';

void main() {
  late ReaderProvider provider;
  late MockRustApi mockApi;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    provider = ReaderProvider(mockApi);
  });

  group('ReaderProvider 初始状态', () {
    test('初始无当前书籍', () {
      expect(provider.currentBook, isNull);
      expect(provider.chapters, isEmpty);
      expect(provider.chapterContent, equals(''));
    });

    test('初始非加载状态', () {
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
    });

    test('初始控制面板隐藏', () {
      expect(provider.showControls, isFalse);
    });

    test('初始阅读设置默认值', () {
      expect(provider.fontSize, equals(18.0));
      expect(provider.lineHeight, equals(1.6));
      expect(provider.backgroundColor, equals(ReaderBackground.white));
      // 默认翻页模式为 cover（对齐 Android 原版）
      expect(provider.pageTurnMode, equals(PageTurnMode.cover));
    });

    test('初始无上一章/下一章', () {
      expect(provider.hasPreviousChapter, isFalse);
      expect(provider.hasNextChapter, isFalse);
    });

    test('初始进度为 0', () {
      expect(provider.readingProgress, equals(0));
    });

    test('初始 currentChapter 为 null', () {
      expect(provider.currentChapter, isNull);
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
      final mode = PageTurnMode.fromStorage('cover', null);
      expect(mode, equals(PageTurnMode.cover));
    });

    test('name 优先：name="slide" 即使 legacyIndex=0 也返回 slide', () {
      final mode = PageTurnMode.fromStorage('slide', 0);
      expect(mode, equals(PageTurnMode.slide));
    });

    test('name 优先：name="none" 返回 none', () {
      final mode = PageTurnMode.fromStorage('none', null);
      expect(mode, equals(PageTurnMode.none));
    });

    test('name 优先：name="scroll" 返回 scroll', () {
      final mode = PageTurnMode.fromStorage('scroll', null);
      expect(mode, equals(PageTurnMode.scroll));
    });

    test('name 优先：name="simulate" 返回 simulate', () {
      final mode = PageTurnMode.fromStorage('simulate', null);
      expect(mode, equals(PageTurnMode.simulate));
    });

    test('name 为空时回退 legacyIndex=0 → scroll', () {
      final mode = PageTurnMode.fromStorage(null, 0);
      expect(mode, equals(PageTurnMode.scroll));
    });

    test('name 为空时回退 legacyIndex=1 → slide', () {
      final mode = PageTurnMode.fromStorage(null, 1);
      expect(mode, equals(PageTurnMode.slide));
    });

    test('name 为空时回退 legacyIndex=2 → simulate', () {
      final mode = PageTurnMode.fromStorage(null, 2);
      expect(mode, equals(PageTurnMode.simulate));
    });

    test('name 为空时回退 legacyIndex=3 → none', () {
      final mode = PageTurnMode.fromStorage(null, 3);
      expect(mode, equals(PageTurnMode.none));
    });

    test('name 为空时回退 legacyIndex=4 → cover', () {
      final mode = PageTurnMode.fromStorage(null, 4);
      expect(mode, equals(PageTurnMode.cover));
    });

    test('name 为空字符串时回退 legacyIndex', () {
      final mode = PageTurnMode.fromStorage('', 1);
      expect(mode, equals(PageTurnMode.slide));
    });

    test('name 无效且 legacyIndex 有效时回退 legacyIndex', () {
      final mode = PageTurnMode.fromStorage('invalid_name', 2);
      expect(mode, equals(PageTurnMode.simulate));
    });

    test('name 和 legacyIndex 都无效时默认 cover', () {
      final mode = PageTurnMode.fromStorage(null, null);
      expect(mode, equals(PageTurnMode.cover));
    });

    test('name 无效且 legacyIndex 为负数时默认 cover', () {
      final mode = PageTurnMode.fromStorage('bad', -1);
      expect(mode, equals(PageTurnMode.cover));
    });

    test('name 无效且 legacyIndex 越界时默认 cover', () {
      final mode = PageTurnMode.fromStorage('bad', 99);
      expect(mode, equals(PageTurnMode.cover));
    });

    test('name 和 legacyIndex 都为 null 时默认 cover', () {
      final mode = PageTurnMode.fromStorage(null, null);
      expect(mode, equals(PageTurnMode.cover));
    });
  });

  group('ReaderProvider 翻页模式', () {
    test('updatePageTurnMode 切换到 cover', () {
      provider.updatePageTurnMode(PageTurnMode.cover);
      expect(provider.pageTurnMode, equals(PageTurnMode.cover));
    });

    test('updatePageTurnMode 切换到滑动', () {
      provider.updatePageTurnMode(PageTurnMode.slide);
      expect(provider.pageTurnMode, equals(PageTurnMode.slide));
    });

    test('updatePageTurnMode 切换到仿真', () {
      provider.updatePageTurnMode(PageTurnMode.simulate);
      expect(provider.pageTurnMode, equals(PageTurnMode.simulate));
    });

    test('updatePageTurnMode 切换到无动画', () {
      provider.updatePageTurnMode(PageTurnMode.none);
      expect(provider.pageTurnMode, equals(PageTurnMode.none));
    });

    test('updatePageTurnMode 切换回滚动', () {
      provider.updatePageTurnMode(PageTurnMode.slide);
      provider.updatePageTurnMode(PageTurnMode.scroll);
      expect(provider.pageTurnMode, equals(PageTurnMode.scroll));
    });

    test('updatePageTurnMode 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.updatePageTurnMode(PageTurnMode.simulate);
      expect(notified, isTrue);
    });
  });

  group('ReaderProvider 阅读设置', () {
    test('updateFontSize 正常设置', () {
      provider.updateFontSize(22.0);
      expect(provider.fontSize, equals(22.0));
    });

    test('updateFontSize 低于下限被 clamp 到 12', () {
      provider.updateFontSize(8.0);
      expect(provider.fontSize, equals(12.0));
    });

    test('updateFontSize 超过上限被 clamp 到 32', () {
      provider.updateFontSize(50.0);
      expect(provider.fontSize, equals(32.0));
    });

    test('updateLineHeight 正常设置', () {
      provider.updateLineHeight(2.0);
      expect(provider.lineHeight, equals(2.0));
    });

    test('updateLineHeight 低于下限被 clamp 到 1.0', () {
      provider.updateLineHeight(0.5);
      expect(provider.lineHeight, equals(1.0));
    });

    test('updateLineHeight 超过上限被 clamp 到 2.5', () {
      provider.updateLineHeight(4.0);
      expect(provider.lineHeight, equals(2.5));
    });

    test('updateBackgroundColor 设置为预设绿色', () {
      provider.updateBackgroundColor(ReaderBackground.green);
      expect(provider.backgroundColor, equals(ReaderBackground.green));
    });

    test('updateBackgroundColor 设置为预设夜间', () {
      provider.updateBackgroundColor(ReaderBackground.dark);
      expect(provider.backgroundColor, equals(ReaderBackground.dark));
    });

    test('updateBackgroundColor 设置为护眼色', () {
      provider.updateBackgroundColor(ReaderBackground.eyeProtect);
      expect(provider.backgroundColor, equals(ReaderBackground.eyeProtect));
    });

    test('updateBackgroundColor 设置为自定义颜色', () {
      const custom = Color(0xFF123456);
      provider.updateBackgroundColor(custom);
      expect(provider.backgroundColor, equals(custom));
    });

    test('updateFontSize 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.updateFontSize(20.0);
      expect(notified, isTrue);
    });

    test('updateLineHeight 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.updateLineHeight(1.8);
      expect(notified, isTrue);
    });

    test('updateBackgroundColor 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.updateBackgroundColor(ReaderBackground.brown);
      expect(notified, isTrue);
    });
  });

  group('ReaderProvider loadSettings（SharedPreferences）', () {
    test('loadSettings 加载字体大小', () async {
      SharedPreferences.setMockInitialValues({
        'reader_font_size': 24.0,
      });
      final p = ReaderProvider(mockApi);
      await p.loadSettings();
      expect(p.fontSize, equals(24.0));
    });

    test('loadSettings 加载行距', () async {
      SharedPreferences.setMockInitialValues({
        'reader_line_height': 2.0,
      });
      final p = ReaderProvider(mockApi);
      await p.loadSettings();
      expect(p.lineHeight, equals(2.0));
    });

    test('loadSettings 加载背景色索引', () async {
      SharedPreferences.setMockInitialValues({
        'reader_bg_color_index': 1,
      });
      final p = ReaderProvider(mockApi);
      await p.loadSettings();
      expect(p.backgroundColor, equals(ReaderBackground.green));
    });

    test('loadSettings 背景色索引越界时保持默认', () async {
      SharedPreferences.setMockInitialValues({
        'reader_bg_color_index': 99,
      });
      final p = ReaderProvider(mockApi);
      await p.loadSettings();
      expect(p.backgroundColor, equals(ReaderBackground.white));
    });

    test('loadSettings 翻页模式 name 优先', () async {
      SharedPreferences.setMockInitialValues({
        'reader_flip_mode_name': 'slide',
        'reader_flip_mode': 0,
      });
      final p = ReaderProvider(mockApi);
      await p.loadSettings();
      expect(p.pageTurnMode, equals(PageTurnMode.slide));
    });

    test('loadSettings 翻页模式回退 legacyIndex', () async {
      SharedPreferences.setMockInitialValues({
        'reader_flip_mode': 2,
      });
      final p = ReaderProvider(mockApi);
      await p.loadSettings();
      expect(p.pageTurnMode, equals(PageTurnMode.simulate));
    });

    test('loadSettings 翻页模式无存储时默认 cover', () async {
      SharedPreferences.setMockInitialValues({});
      final p = ReaderProvider(mockApi);
      await p.loadSettings();
      expect(p.pageTurnMode, equals(PageTurnMode.cover));
    });

    test('loadSettings 触发通知', () async {
      SharedPreferences.setMockInitialValues({});
      final p = ReaderProvider(mockApi);
      var notified = false;
      p.addListener(() => notified = true);
      await p.loadSettings();
      expect(notified, isTrue);
    });
  });

  group('ReaderProvider openBook（mock API）', () {
    final testBook = const Book(
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

    test('openBook 成功加载章节列表', () async {
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => testChapters);
      when(() => mockApi.getChapterContent(any(), any()))
          .thenAnswer((_) async => '章节内容');
      when(() => mockApi.updateReadingProgress(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterPos: any(named: 'chapterPos'),
          )).thenAnswer((_) async {});

      await provider.openBook(testBook);

      expect(provider.currentBook, equals(testBook));
      expect(provider.chapters.length, equals(3));
      expect(provider.currentChapterIndex, equals(0));
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
    });

    test('openBook 加载章节内容', () async {
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => testChapters);
      when(() => mockApi.getChapterContent(any(), any()))
          .thenAnswer((_) async => '第一章正文内容');
      when(() => mockApi.updateReadingProgress(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterPos: any(named: 'chapterPos'),
          )).thenAnswer((_) async {});

      await provider.openBook(testBook);
      expect(provider.chapterContent, equals('第一章正文内容'));
    });

    test('openBook 失败时设置 BridgeError 错误', () async {
      when(() => mockApi.getChapters(any()))
          .thenThrow(const BridgeError(message: '书籍不存在'));

      await provider.openBook(testBook);

      expect(provider.error, equals('书籍不存在'));
      expect(provider.loading, isFalse);
    });

    test('openBook 失败时设置普通异常错误', () async {
      when(() => mockApi.getChapters(any()))
          .thenThrow(Exception('网络错误'));

      await provider.openBook(testBook);

      expect(provider.error, contains('网络错误'));
      expect(provider.loading, isFalse);
    });

    test('openBook durChapterIndex 越界时重置为 0', () async {
      final book = testBook.copyWith(durChapterIndex: 99);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => testChapters);
      when(() => mockApi.getChapterContent(any(), any()))
          .thenAnswer((_) async => '内容');
      when(() => mockApi.updateReadingProgress(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterPos: any(named: 'chapterPos'),
          )).thenAnswer((_) async {});

      await provider.openBook(book);
      expect(provider.currentChapterIndex, equals(0));
    });

    test('openBook 后 hasPreviousChapter/hasNextChapter 正确', () async {
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => testChapters);
      when(() => mockApi.getChapterContent(any(), any()))
          .thenAnswer((_) async => '内容');
      when(() => mockApi.updateReadingProgress(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterPos: any(named: 'chapterPos'),
          )).thenAnswer((_) async {});

      await provider.openBook(testBook);
      expect(provider.hasPreviousChapter, isFalse);
      expect(provider.hasNextChapter, isTrue);
    });

    test('openBook 后 readingProgress 正确', () async {
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => testChapters);
      when(() => mockApi.getChapterContent(any(), any()))
          .thenAnswer((_) async => '内容');
      when(() => mockApi.updateReadingProgress(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterPos: any(named: 'chapterPos'),
          )).thenAnswer((_) async {});

      await provider.openBook(testBook);
      // 第 0 章 / 共 3 章 = 1/3
      expect(provider.readingProgress, closeTo(0.333, 0.01));
    });

    test('openBook 后 currentChapter 正确', () async {
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => testChapters);
      when(() => mockApi.getChapterContent(any(), any()))
          .thenAnswer((_) async => '内容');
      when(() => mockApi.updateReadingProgress(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterPos: any(named: 'chapterPos'),
          )).thenAnswer((_) async {});

      await provider.openBook(testBook);
      expect(provider.currentChapter?.title, equals('第一章'));
    });
  });

  group('ReaderProvider 章节导航（mock API）', () {
    final testBook = const Book(
      bookUrl: 'https://book.com/1',
      name: '导航测试',
      origin: 'https://source.com',
      durChapterIndex: 0,
    );

    final testChapters = [
      const BookChapter(title: '第一章', index: 0),
      const BookChapter(title: '第二章', index: 1),
      const BookChapter(title: '第三章', index: 2),
    ];

    setUp(() {
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => testChapters);
      when(() => mockApi.getChapterContent(any(), any()))
          .thenAnswer((_) async => '章节内容');
      when(() => mockApi.updateReadingProgress(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterPos: any(named: 'chapterPos'),
          )).thenAnswer((_) async {});
    });

    test('nextChapter 切换到下一章', () async {
      await provider.openBook(testBook);
      await provider.nextChapter();
      expect(provider.currentChapterIndex, equals(1));
      expect(provider.currentChapterPos, equals(0));
    });

    test('nextChapter 在最后一章时不切换', () async {
      final book = testBook.copyWith(durChapterIndex: 2);
      await provider.openBook(book);
      await provider.nextChapter();
      expect(provider.currentChapterIndex, equals(2));
    });

    test('prevChapter 切换到上一章', () async {
      final book = testBook.copyWith(durChapterIndex: 1);
      await provider.openBook(book);
      await provider.prevChapter();
      expect(provider.currentChapterIndex, equals(0));
    });

    test('prevChapter 在第一章时不切换', () async {
      await provider.openBook(testBook);
      await provider.prevChapter();
      expect(provider.currentChapterIndex, equals(0));
    });

    test('goToChapter 跳转到指定章节', () async {
      await provider.openBook(testBook);
      await provider.goToChapter(2);
      expect(provider.currentChapterIndex, equals(2));
    });

    test('goToChapter 负索引不跳转', () async {
      await provider.openBook(testBook);
      await provider.goToChapter(-1);
      expect(provider.currentChapterIndex, equals(0));
    });

    test('goToChapter 越界索引不跳转', () async {
      await provider.openBook(testBook);
      await provider.goToChapter(99);
      expect(provider.currentChapterIndex, equals(0));
    });

    test('goToChapter 隐藏控制面板', () async {
      await provider.openBook(testBook);
      provider.toggleControls(); // 先显示
      await provider.goToChapter(1);
      expect(provider.showControls, isFalse);
    });
  });

  group('ReaderProvider 控制面板', () {
    test('toggleControls 显示控制面板', () {
      provider.toggleControls();
      expect(provider.showControls, isTrue);
    });

    test('toggleControls 再次切换隐藏', () {
      provider.toggleControls();
      provider.toggleControls();
      expect(provider.showControls, isFalse);
    });

    test('hideControls 隐藏已显示的面板', () {
      provider.toggleControls();
      provider.hideControls();
      expect(provider.showControls, isFalse);
    });

    test('hideControls 对已隐藏面板无效', () {
      provider.hideControls();
      expect(provider.showControls, isFalse);
    });

    test('toggleControls 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.toggleControls();
      expect(notified, isTrue);
    });
  });

  group('ReaderProvider 阅读位置', () {
    test('updatePosition 更新当前位置', () {
      provider.updatePosition(100);
      expect(provider.currentChapterPos, equals(100));
    });

    test('updatePosition 可多次更新', () {
      provider.updatePosition(50);
      provider.updatePosition(200);
      expect(provider.currentChapterPos, equals(200));
    });
  });

  group('ReaderProvider saveProgress（mock API）', () {
    test('saveProgress 无书籍时不调用 API', () async {
      await provider.saveProgress();
      verifyNever(() => mockApi.updateReadingProgress(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterPos: any(named: 'chapterPos'),
          ));
    });

    test('saveProgress 有书籍时调用 API', () async {
      final testBook = const Book(bookUrl: 'https://b.com/1', name: 'test');
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => [
            const BookChapter(title: 'ch1', index: 0),
          ]);
      when(() => mockApi.getChapterContent(any(), any()))
          .thenAnswer((_) async => '内容');
      when(() => mockApi.updateReadingProgress(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterPos: any(named: 'chapterPos'),
          )).thenAnswer((_) async {});

      await provider.openBook(testBook);
      await provider.saveProgress();

      verify(() => mockApi.updateReadingProgress(
            bookUrl: 'https://b.com/1',
            chapterIndex: 0,
            chapterPos: 0,
          )).called(greaterThan(0));
    });
  });

  group('ReaderBackground 预设', () {
    test('预设列表包含 5 种颜色', () {
      expect(ReaderBackground.presets.length, equals(5));
    });

    test('标签列表与预设对应', () {
      expect(ReaderBackground.labels.length, equals(ReaderBackground.presets.length));
    });

    test('预设包含白色', () {
      expect(ReaderBackground.presets, contains(ReaderBackground.white));
    });

    test('预设包含护眼色', () {
      expect(ReaderBackground.presets, contains(ReaderBackground.eyeProtect));
    });

    test('标签包含中文名称', () {
      expect(ReaderBackground.labels, contains('白色'));
      expect(ReaderBackground.labels, contains('夜间'));
    });
  });
}
