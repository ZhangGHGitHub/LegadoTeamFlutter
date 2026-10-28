// RSS 阅读记录全局开关（批29）单元测试
//
// - 偏好默认 true、切换持久化、重启（新容器）后按持久化值加载；
// - 写入 helper：关闭时短路不调用 rssMarkRead，开启时透传参数，
//   写入异常不抛（不阻断阅读）。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/rss_read_record_pref_notifier.dart';
import 'package:flutter_legado/src/utils/rss_read_record.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  /// 等待异步偏好加载完成（默认值为 build 同步值，加载后切换）
  Future<void> waitForPrefState(
    ProviderContainer container,
    bool expected,
  ) async {
    for (var i = 0; i < 200; i++) {
      if (container.read(rssReadRecordPrefProvider) == expected) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('等待偏好状态 $expected 超时');
  }

  group('RssReadRecordPrefNotifier', () {
    test('默认 true（无持久化值）', () {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(rssReadRecordPrefProvider), isTrue);
    });

    test('切换后持久化，新容器（重启）加载为 false', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(rssReadRecordPrefProvider.notifier)
          .setEnabled(false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrefKeys.enableRssReadRecord), isFalse);

      // 模拟重启：新容器 build 同步默认 true，异步加载持久化 false
      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      expect(restarted.read(rssReadRecordPrefProvider), isTrue);
      await waitForPrefState(restarted, false);
      expect(restarted.read(rssReadRecordPrefProvider), isFalse);
    });

    test('resolved 等待异步加载：进程首启首击也能读到持久化的 false', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.enableRssReadRecord: false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // build 的同步默认值是 true（异步加载尚未完成），resolved 必须等待
      // 持久化值，避免关闭态在首击时漏判。
      expect(container.read(rssReadRecordPrefProvider), isTrue);
      final resolved = await container
          .read(rssReadRecordPrefProvider.notifier)
          .resolved();
      expect(resolved, isFalse);
    });

    test('加载未完成时显式设置：不被旧持久化值覆盖', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.enableRssReadRecord: false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(rssReadRecordPrefProvider.notifier);
      await notifier.setEnabled(true);
      // 等待初始加载完成（若 dirty 守卫缺失会把状态改回 false）
      await notifier.resolved();
      expect(container.read(rssReadRecordPrefProvider), isTrue);
    });

    test('重新开启恢复 true 并持久化', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.enableRssReadRecord: false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await waitForPrefState(container, false);
      expect(container.read(rssReadRecordPrefProvider), isFalse);

      await container
          .read(rssReadRecordPrefProvider.notifier)
          .setEnabled(true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrefKeys.enableRssReadRecord), isTrue);
    });
  });

  group('rssMarkReadIfEnabled', () {
    test('关闭时不调用 rssMarkRead（已有记录保留语义由调用方保证）', () async {
      final api = MockRustApi();
      await rssMarkReadIfEnabled(
        api,
        false,
        origin: 'https://s.test',
        title: '文章',
        link: 'https://s.test/a',
      );
      verifyNever(
        () => api.rssMarkRead(
          any(),
          any(),
          link: any(named: 'link'),
          type: any(named: 'type'),
          sort: any(named: 'sort'),
          image: any(named: 'image'),
          pubDate: any(named: 'pubDate'),
          durPos: any(named: 'durPos'),
        ),
      );
    });

    test('开启时透传全部参数', () async {
      final api = MockRustApi();
      when(
        () => api.rssMarkRead(
          'https://s.test',
          '文章',
          link: 'https://s.test/a',
          type: 1,
          sort: '图',
          image: 'https://s.test/c.jpg',
          pubDate: '2026-10-28',
          durPos: 3,
        ),
      ).thenAnswer((_) async {});

      await rssMarkReadIfEnabled(
        api,
        true,
        origin: 'https://s.test',
        title: '文章',
        link: 'https://s.test/a',
        type: 1,
        sort: '图',
        image: 'https://s.test/c.jpg',
        pubDate: '2026-10-28',
        durPos: 3,
      );

      verify(
        () => api.rssMarkRead(
          'https://s.test',
          '文章',
          link: 'https://s.test/a',
          type: 1,
          sort: '图',
          image: 'https://s.test/c.jpg',
          pubDate: '2026-10-28',
          durPos: 3,
        ),
      ).called(1);
    });

    test('写入异常不抛出（不阻断阅读）', () async {
      final api = MockRustApi();
      when(
        () => api.rssMarkRead(
          any(),
          any(),
          link: any(named: 'link'),
          type: any(named: 'type'),
          sort: any(named: 'sort'),
          image: any(named: 'image'),
          pubDate: any(named: 'pubDate'),
          durPos: any(named: 'durPos'),
        ),
      ).thenThrow(Exception('ffi'));

      await expectLater(
        rssMarkReadIfEnabled(
          api,
          true,
          origin: 'https://s.test',
          title: '文章',
        ),
        completes,
      );
    });
  });
}
