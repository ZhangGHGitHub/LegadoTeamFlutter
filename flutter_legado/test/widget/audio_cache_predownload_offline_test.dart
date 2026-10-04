// B1 P1 收口守卫：音频预下载 UI 与新读面（契约 §2.47 audio_cache FFI）脱节。
//
// 原版取证（app/src/main/java/io/legado/app/）：
// - 写入与读取同目录同键：预下载写 AudioCacheManager.cacheChapter
//   （AudioCacheService.kt:217 为全仓唯一调用方），播放第一步读
//   getCachedAudio（AudioPlay.kt:388-413），键均为 AudioCacheKey.from(chapter)
//   （AudioCacheKey.kt:20-23 = md5Encode16(chapterUrl.ifBlank { chapterTitle })），
//   目录均为 {缓存根}/LegadoAudioCache/book_{md5Encode16(bookUrl)}
//   （AudioCacheManager.kt:205-230）；.complete 标记在下载完成并通过
//   size 校验后才写（AudioCacheManager.kt:174-189,266-281）。
// - 原版章节列表「已缓存」徽标依据 AudioCacheManager.listCachedChapterKeys
//   （ChapterListFragment.kt:154-184 → ChapterListAdapter.kt:195），
//   即 .complete + size>0 的同一命中判定。
// - 原版预下载是前台服务（AudioCacheService : BaseService 队列 + 通知 + 事件，
//   AudioCacheService.kt:39-63,86-98,187-234），与播放链解耦。
//
// 我方旧实现（本批前）为页面内循环，写 `${bookUrl.hashCode}_$i.audio`
// （无 .complete、目录为 support/SAF），与新读面
// （应用私有 cache/audio_cache + 五段式文件名 + .complete）目录/键/标记
// 三重不匹配，UI 仍提示「已缓存」→ 用户每次触发净耗流量。
// 契约 §2.47 不设写入面（写入链路另行冻结），故本批按方案 B 收口：
// 下线预下载入口并清理旧写入路径，待专门预下载服务批次按原版语义恢复。
//
// 守卫内容：
// 1. 源码不得再出现旧孤儿键写入/页面内预下载实现/「已缓存」承诺；
// 2. 听书页溢出菜单不得再提供缓存目录/缓存范围入口；
// 3. 溢出菜单其余原版可用项保持齐备（防过度删除）。
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
  group('源码守卫：旧孤儿预下载写入路径已清理', () {
    final src =
        File('lib/src/screens/audio_screen.dart').readAsStringSync();

    test('页面内预下载实现与旧孤儿键写入零残留', () {
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
        reason: '不得再向用户承诺「已缓存」——该写入永远不被新读面命中',
      );
    });

    test('预下载入口已从溢出菜单下线', () {
      expect(src.contains("'cacheRange'"), isFalse,
          reason: '缓存范围入口对应旧写入路径，本批下线');
      expect(src.contains("'cacheFolder'"), isFalse,
          reason: '缓存目录入口只服务旧写入路径，本批下线');
      expect(src.contains("Text('缓存范围')"), isFalse);
      expect(src.contains("Text('缓存目录')"), isFalse);
    });

    test('溢出菜单原版可用项保持齐备（防过度删除）', () {
      for (final value in [
        'changeSource',
        'login',
        'copyAudioUrl',
        'wakeLock',
        'skipCredits',
        'editSource',
        'log',
      ]) {
        expect(
          src.contains("'$value'"),
          isTrue,
          reason: '溢出菜单项 $value 不应被本次收口误删',
        );
      }
    });
  });

  group('行为守卫：听书页溢出菜单（音频书）', () {
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

    testWidgets('音频书菜单不再出现缓存目录/缓存范围', (tester) async {
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [const BookChapter(title: '第一章', index: 0)],
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer(
        (_) async => {'mediaUrl': '', 'isVolume': false},
      );
      when(() => mockApi.getAudioProgress(any(), any()))
          .thenAnswer((_) async => null);

      // 预载章节，避免 initState 后帧重复 load 的异步竞态
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

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();

      // 菜单确实已展开（防「菜单未打开导致假绿」）
      expect(find.text('换源'), findsOneWidget);
      expect(
        find.text('缓存目录'),
        findsNothing,
        reason: '缓存目录入口已下线（旧写入路径清理）',
      );
      expect(
        find.text('缓存范围'),
        findsNothing,
        reason: '缓存范围入口已下线（旧写入路径清理）',
      );
    });
  });
}
