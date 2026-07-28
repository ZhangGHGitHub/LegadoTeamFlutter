import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_legado/src/providers/reader_provider.dart';
import 'package:flutter_legado/src/services/rust_api.dart';

void main() {
  late ReaderProvider provider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    provider = ReaderProvider(RustApi());
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
      expect(provider.pageTurnMode, equals(PageTurnMode.scroll));
    });
  });

  group('ReaderProvider 翻页模式', () {
    test('updatePageTurnMode 切换到滑动', () {
      provider.updatePageTurnMode(PageTurnMode.slide);
      expect(provider.pageTurnMode, equals(PageTurnMode.slide));
    });

    test('updatePageTurnMode 切换到仿真', () {
      provider.updatePageTurnMode(PageTurnMode.simulate);
      expect(provider.pageTurnMode, equals(PageTurnMode.simulate));
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
  });

  group('ReaderProvider 进度计算', () {
    test('空章节时进度为 0', () {
      expect(provider.readingProgress, equals(0));
    });

    test('空章节时无上一章/下一章', () {
      expect(provider.hasPreviousChapter, isFalse);
      expect(provider.hasNextChapter, isFalse);
    });

    test('空章节时 currentChapter 为 null', () {
      expect(provider.currentChapter, isNull);
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
      provider.toggleControls(); // 先显示
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
  });
}
