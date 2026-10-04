// B1/B2 音频预下载守卫：旧孤儿键写入清理 + 契约 §2.48 新入口行为。
//
// 原版取证（app/src/main/java/io/legado/app/）：
// - 写入与读取同目录同键：预下载写 AudioCacheManager.cacheChapter
//   （AudioCacheService.kt:217 为全仓唯一调用方），播放第一步读
//   getCachedAudio（AudioPlay.kt:388-413），键均为 AudioCacheKey.from(chapter)
//   （AudioCacheKey.kt:20-23 = md5Encode16(chapterUrl.ifBlank { chapterTitle })），
//   目录均为 {缓存根}/LegadoAudioCache/book_{md5Encode16(bookUrl)}
//   （AudioCacheManager.kt:205-230）；.complete 标记在下载完成并通过
//   size 校验后才写（AudioCacheManager.kt:174-189,266-281）。
// - 原版预下载是前台服务（AudioCacheService : BaseService 队列 + 通知 + 事件，
//   AudioCacheService.kt:39-63,86-98,187-234）；契约 §2.48 裁决服务编排不上
//   FFI，由本页循环逐章调 audioCacheDownload 自持 done/total/fail。
//
// 我方旧实现（B1 批前）为页面内循环，写 `${bookUrl.hashCode}_$i.audio`
// （无 .complete、目录为 support/SAF），与新读面三重不匹配。B1 批删除旧写入
// 路径；B2 批按契约 §2.48 恢复「缓存章节范围」「清除本章缓存」入口（写入
// 下沉 Rust：流式下载安装 + `.complete`），「缓存目录」因 SAF 与冻结私有
// 缓存根冲突不在本批。
//
// 守卫内容：
// 1. 源码不得再出现旧孤儿键写入/旧 support 目录写入；
// 2. 听书页溢出菜单提供缓存章节范围/清除本章缓存，且不再出现「缓存目录」；
// 3. 批量循环行为：逐章取址 + audioCacheDownload 调用 + 进度计数 + 停止取消；
// 4. 溢出菜单其余原版可用项保持齐备（防过度删除）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/audio_screen.dart';

import '../mocks/mocks.dart';

void main() {
  group('源码守卫：旧孤儿预下载写入路径已清理（B1 收口不回归）', () {
    final src =
        File('lib/src/screens/audio_screen.dart').readAsStringSync();

    test('旧页面内预下载实现与旧孤儿键写入零残留', () {
      expect(
        src.contains('_cacheAudioRange'),
        isFalse,
        reason: '旧页面内预下载实现必须删除（写入落点与新读面三重不匹配）',
      );
      expect(
        src.contains(r'hashCode}_$i.audio'),
        isFalse,
        reason: '旧孤儿键（hashCode 下标命名、无 .complete）不得再被写入，'
            '按用户裁决默认不读不迁移',
      );
      expect(
        src.contains('getApplicationSupportDirectory'),
        isFalse,
        reason: '旧回退目录（support/audio_cache）与新读面注入目录'
            '（cache/audio_cache）不一致',
      );
      expect(
        src.contains('已缓存 \$okCount'),
        isFalse,
        reason: '不得再向用户承诺旧写入路径的「已缓存」',
      );
    });

    test('新入口经契约 §2.48 方法（不走自造键/自造目录）', () {
      expect(
        src.contains('audioCacheDownload'),
        isTrue,
        reason: '写入必须经 Rust 写入面（流式 + .complete），不得页面内自写文件',
      );
      expect(
        src.contains('audioCacheCancel'),
        isTrue,
        reason: '停止必须调 audioCacheCancel 中止在途下载',
      );
      expect(
        src.contains('audioCacheList'),
        isTrue,
        reason: '已缓存跳过应复用读面列举（原版 listCachedChapterKeys 语义）',
      );
    });

    test('溢出菜单原版可用项保持齐备（防过度删除）', () {
      for (final value in [
        'changeSource',
        'login',
        'copyAudioUrl',
        'cacheRange',
        'clearCurrentCache',
        'wakeLock',
        'skipCredits',
        'editSource',
        'log',
      ]) {
        expect(
          src.contains("'$value'"),
          isTrue,
          reason: '溢出菜单项 $value 不应被误删',
        );
      }
      // 原版菜单文案（values-zh）
      expect(src.contains("Text('缓存章节范围')"), isTrue);
      expect(src.contains("Text('清除本章缓存')"), isTrue);
    });
  });

  group('行为守卫：听书页溢出菜单与批量缓存（音频书）', () {
    late MockRustApi mockApi;
    late FakeStreamAudioPlayer fakePlayer;
    late ProviderContainer container;

    setUpAll(registerFallbacks);

    setUp(() {
      mockApi = MockRustApi();
      fakePlayer = FakeStreamAudioPlayer();
      container = ProviderContainer(
        overrides: [
          bookApiProvider.overrideWithValue(mockApi),
          streamAudioPlayerProvider.overrideWithValue(fakePlayer),
        ],
      );
      addTearDown(container.dispose);
    });

    Future<void> pumpScreen(WidgetTester tester) async {
      when(() => mockApi.getAudioProgress(any(), any()))
          .thenAnswer((_) async => null);
      await container
          .read(audioNotifierProvider.notifier)
          .loadChapters('url');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: AudioScreen(
              book: Book(bookUrl: 'url', name: '测试书', bookType: 32),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('菜单出现缓存章节范围/清除本章缓存，不再出现缓存目录', (tester) async {
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [const BookChapter(title: '第一章', index: 0)],
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer(
        (_) async => {'mediaUrl': '', 'isVolume': false},
      );
      await pumpScreen(tester);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();

      // 菜单确实已展开（防「菜单未打开导致假绿」）
      expect(find.text('换源'), findsOneWidget);
      expect(find.text('缓存章节范围'), findsOneWidget);
      expect(find.text('清除本章缓存'), findsOneWidget);
      expect(
        find.text('缓存目录'),
        findsNothing,
        reason: 'SAF 缓存目录与冻结的私有缓存根冲突，不在本批入口（见报告）',
      );
    });

    testWidgets('缓存章节范围：对话框文案对齐原版，确定后逐章调用 audioCacheDownload',
        (tester) async {
      final chapters = [
        const BookChapter(title: '第一章', index: 0, url: 'https://x/1'),
        const BookChapter(title: '第二章', index: 1, url: 'https://x/2'),
      ];
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => chapters);
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.audioCacheList(bookUrl: any(named: 'bookUrl')))
          .thenAnswer((_) async => <int>[]);
      when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer(
        (inv) async => {
          'mediaUrl': 'https://cdn.example/${inv.positionalArguments[1]}.mp3',
        },
      );
      when(() => mockApi.audioCacheDownload(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterUrl: any(named: 'chapterUrl'),
            chapterTitle: any(named: 'chapterTitle'),
            playUrl: any(named: 'playUrl'),
          )).thenAnswer((_) async => '{"status":"installed"}');

      await pumpScreen(tester);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存章节范围'));
      await tester.pumpAndSettle();

      // 对话框文案（values-zh：audio_cache_range/chapter/start/to/end）
      expect(find.text('缓存章节范围'), findsOneWidget);
      expect(find.text('章'), findsOneWidget);
      expect(find.text('开始'), findsOneWidget);
      expect(find.text('至'), findsOneWidget);
      expect(find.text('结束'), findsOneWidget);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      // 逐章调用：章节四元标识 + 内容链 playUrl（与播放链同源）
      verify(() => mockApi.audioCacheDownload(
            bookUrl: 'url',
            chapterIndex: 0,
            chapterUrl: 'https://x/1',
            chapterTitle: '第一章',
            playUrl: 'https://cdn.example/0.mp3',
          )).called(1);
      verify(() => mockApi.audioCacheDownload(
            bookUrl: 'url',
            chapterIndex: 1,
            chapterUrl: 'https://x/2',
            chapterTitle: '第二章',
            playUrl: 'https://cdn.example/1.mp3',
          )).called(1);
      verifyNever(() => mockApi.audioCacheCancel());
      // 完成后进度条隐藏（等价原版服务结束移除通知）
      expect(find.text('音频缓存'), findsNothing);
    });

    testWidgets('停止：audioCacheCancel 中止在途下载并停发后续章节', (tester) async {
      final gate = Completer<String>();
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [
          const BookChapter(title: '第一章', index: 0, url: 'https://x/1'),
          const BookChapter(title: '第二章', index: 1, url: 'https://x/2'),
        ],
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.audioCacheList(bookUrl: any(named: 'bookUrl')))
          .thenAnswer((_) async => <int>[]);
      when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer(
        (_) async => {'mediaUrl': 'https://cdn.example/0.mp3'},
      );
      when(() => mockApi.audioCacheDownload(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterUrl: any(named: 'chapterUrl'),
            chapterTitle: any(named: 'chapterTitle'),
            playUrl: any(named: 'playUrl'),
          )).thenAnswer((_) => gate.future);
      when(() => mockApi.audioCacheCancel()).thenAnswer((_) async => true);

      await pumpScreen(tester);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存章节范围'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump();

      // 进度条（原版通知等价物）可见：标题/文案/停止动作
      expect(find.text('音频缓存'), findsOneWidget);
      expect(find.textContaining('已缓存'), findsOneWidget);
      expect(find.text('停止'), findsOneWidget);

      await tester.tap(find.text('停止'));
      await tester.pumpAndSettle();

      verify(() => mockApi.audioCacheCancel()).called(1);
      // 只发起过第一章（停止后不再发起后续章节）
      verify(() => mockApi.audioCacheDownload(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: 0,
            chapterUrl: any(named: 'chapterUrl'),
            chapterTitle: any(named: 'chapterTitle'),
            playUrl: any(named: 'playUrl'),
          )).called(1);
      verifyNever(() => mockApi.audioCacheDownload(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: 1,
            chapterUrl: any(named: 'chapterUrl'),
            chapterTitle: any(named: 'chapterTitle'),
            playUrl: any(named: 'playUrl'),
          ));
      expect(find.text('音频缓存'), findsNothing);
      gate.complete('{"status":"installed"}');
      await tester.pumpAndSettle();
    });

    testWidgets('清除本章缓存：命中提示已清除', (tester) async {
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [const BookChapter(title: '第一章', index: 0, url: 'https://x/1')],
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer(
        (_) async => {'mediaUrl': '', 'isVolume': false},
      );
      when(() => mockApi.audioCacheClearChapter(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterUrl: any(named: 'chapterUrl'),
            chapterTitle: any(named: 'chapterTitle'),
          )).thenAnswer((_) async => 1);

      await pumpScreen(tester);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除本章缓存'));
      await tester.pumpAndSettle();

      verify(() => mockApi.audioCacheClearChapter(
            bookUrl: 'url',
            chapterIndex: any(named: 'chapterIndex'),
            chapterUrl: any(named: 'chapterUrl'),
            chapterTitle: any(named: 'chapterTitle'),
          )).called(1);
      expect(find.text('已清除本章缓存'), findsOneWidget);
    });

    testWidgets('清除本章缓存：未命中提示本章没有缓存', (tester) async {
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [const BookChapter(title: '第一章', index: 0, url: 'https://x/1')],
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer(
        (_) async => {'mediaUrl': '', 'isVolume': false},
      );
      when(() => mockApi.audioCacheClearChapter(
            bookUrl: any(named: 'bookUrl'),
            chapterIndex: any(named: 'chapterIndex'),
            chapterUrl: any(named: 'chapterUrl'),
            chapterTitle: any(named: 'chapterTitle'),
          )).thenAnswer((_) async => 0);

      await pumpScreen(tester);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除本章缓存'));
      await tester.pumpAndSettle();

      expect(find.text('本章没有缓存'), findsOneWidget);
    });
  });
}
