// 视角 C：阅读主流程「失败与边界 —— 进程生命周期」缺陷猎捕 —— 红态复现用例
//
// 本文件**故意断言「本应成立的不变量」**：当前实现不满足 → 用例红。
// 红 = 缺陷复现证据。严禁为了让本文件变绿而改生产代码。
//
// C3 章内进度不落盘（后台 / 被杀）：
// - 现状：ReaderNotifier._saveProgress 只在「翻章 / 目录跳章 / 换源重载 /
//   PopScope 返回退出」被调用（reader_notifier.dart:202-235,250-281,583；
//   reader_screen.dart:417-423），**没有任何 AppLifecycle 观察者**；
//   章内翻页（updatePosition）只改内存 state。
// - 对齐口径（原版）：ReadBookActivity.onPause() → ReadBook.saveRead()
//   （app/src/main/java/io/legado/app/ui/book/read/ReadBookActivity.kt:466-476）
//   —— 原版切后台即落盘，划掉/回收进程不丢章内位置。
// - 真机实测（MuMu，2026-09-24）：翻到 4/16 页 → DB durChapterPos 仍 0；
//   按 HOME 进后台 → 仍 0；force-stop 重启重进 → 回到 1/16（进度丢失）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels, StringCodec;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_screen.dart';

import '../mocks/mocks.dart';

const _book = Book(
  bookUrl: 'https://book.com/lifecycle',
  name: '生命周期书',
  author: '作者',
  origin: 'https://source-a.com',
  originName: '源A',
  durChapterIndex: 0,
);

const _chapters = [
  BookChapter(url: 'https://book.com/lifecycle/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/lifecycle/c2', title: '第二章', index: 1),
];

void main() {
  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({'enableReadRecord': false});
  });

  /// 记录每次 updateReadingProgress 的 (chapterIndex, chapterPos) 写库调用
  void stubApi(MockRustApi api, List<List<int>> writes) {
    when(() => api.getChapters(any())).thenAnswer((_) async => _chapters);
    when(() => api.getChapterContentFull(any(), any()))
        .thenAnswer((i) async => 'CH${i.positionalArguments[1]}');
    when(() => api.getChapterContent(any(), any())).thenAnswer((_) async => '');
    when(() => api.getBookSources()).thenAnswer((_) async => const []);
    when(() => api.getConfig(any())).thenAnswer((_) async => '');
    when(
      () => api.updateReadingProgress(
        bookUrl: any(named: 'bookUrl'),
        chapterIndex: any(named: 'chapterIndex'),
        chapterPos: any(named: 'chapterPos'),
      ),
    ).thenAnswer((inv) async {
      writes.add([
        inv.namedArguments[#chapterIndex] as int,
        inv.namedArguments[#chapterPos] as int,
      ]);
    });
  }

  /// 启动 App（首页按钮 push 真实 ReaderScreen，使 PopScope 可被触发）
  Future<(ProviderContainer, ReaderNotifier)> pumpReader(
    WidgetTester tester,
    MockRustApi api,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<Route<dynamic>>(
                      builder: (_) => const ReaderScreen(),
                    ),
                  ),
                  child: const Text('进入阅读'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('进入阅读'));
    await tester.pumpAndSettle();

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ReaderScreen)));
    final notifier = container.read(readerNotifierProvider.notifier);
    await notifier.openBook(_book);
    await tester.pumpAndSettle();
    return (container, notifier);
  }

  /// 模拟系统下发生命周期事件（flutter/lifecycle 通道，平台→框架方向）
  Future<void> sendLifecycle(WidgetTester tester, String state) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.lifecycle.name,
      const StringCodec().encodeMessage(state),
      (_) {},
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('C3 章内进度落盘 / 进程生命周期', () {
    testWidgets('[C3a] 阅读器进入后台（paused）时当前章内位置必须落库', (tester) async {
      final writes = <List<int>>[];
      final api = MockRustApi();
      stubApi(api, writes);
      final (container, notifier) = await pumpReader(tester, api);
      addTearDown(container.dispose);

      // 用户在本章内翻到第 5 页（章内翻页，不换章）
      notifier.updatePosition(5);
      await tester.pump();
      expect(
        container.read(readerNotifierProvider).currentChapterPos,
        5,
        reason: '基线：内存里位置已更新为 5',
      );

      // 用户按 HOME / 被系统切到后台
      await sendLifecycle(tester, 'AppLifecycleState.paused');
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        writes,
        isNotEmpty,
        reason:
            '进入后台后没有任何 updateReadingProgress 落库调用：'
            '章内进度只存在于内存，_saveProgress 仅在翻章/返回退出时触发；'
            '原版 ReadBookActivity.onPause → ReadBook.saveRead 切后台即落盘。'
            '后果：读了一半被系统回收/划掉 → 重进回到上次翻章位置（章首）'
            '（真机实测：翻到 4/16 按 HOME → DB durChapterPos 仍 0）',
      );
      expect(writes.last[1], 5, reason: '落库位置应为当前章内位置 5');
    });

    testWidgets('[C3b] 对照组：系统返回退出阅读时确实落库（机制存在，仅后台事件未接线）',
        (tester) async {
      final writes = <List<int>>[];
      final api = MockRustApi();
      stubApi(api, writes);
      final (container, notifier) = await pumpReader(tester, api);
      addTearDown(container.dispose);

      notifier.updatePosition(7);
      await tester.pump();

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();

      expect(
        writes.map((w) => w[1]).toList(),
        contains(7),
        reason: 'PopScope.onPopInvokedWithResult → saveProgress 路径应把 7 落库',
      );
    });
  });
}
