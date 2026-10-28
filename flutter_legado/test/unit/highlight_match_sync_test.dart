/// 正文高亮匹配同步器测试（批34b P2-1/P2-4/P3-3）
///
/// 覆盖：缓存命中、未命中发起一次 FFI 与在途去重、换章清旧命中、
/// 滚动模式（未启用）不跨 FFI、规则修订号变化丢弃旧结果、
/// 失败清 key + 短退避 + 单 key 重试预算、缓存键含文本长度。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/highlight_style.dart';
import 'package:flutter_legado/src/services/highlight_match_cache.dart';
import 'package:flutter_legado/src/services/highlight_match_sync.dart';

/// 一次同步请求（默认正文/书/章）
HighlightMatchRequest request({
  bool enabled = true,
  String bookUrl = 'bk://hl-sync',
  String bookName = '同步测试书',
  String origin = 'https://origin.test',
  int chapterIndex = 0,
  String content = '第一章正文',
  int rulesRevision = 0,
}) {
  return HighlightMatchRequest(
    enabled: enabled,
    bookUrl: bookUrl,
    bookName: bookName,
    origin: origin,
    chapterIndex: chapterIndex,
    content: content,
    rulesRevision: rulesRevision,
  );
}

/// 单条命中 JSON（styleJson 为空 → 无样式，缓存/采纳只看区间）
String matchJson(int start, int end) =>
    '[{"ruleId":1,"start":$start,"end":$end,"order":10,"styleJson":""}]';

/// 等待微任务队列（异步加载在 await 后写状态）
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('HighlightMatchSync - 键与缓存', () {
    test('缓存键含文本长度/文本 hash/规则修订号', () {
      final key = HighlightMatchSync.cacheKey(
        bookUrl: 'bk://k',
        chapterIndex: 3,
        text: 'ab',
        rulesRevision: 7,
      );
      final parts = key.split('\u0000');
      expect(parts, [
        'bk://k',
        '3',
        '2',
        '${'ab'.hashCode}',
        '7',
      ]);
      // 长度不同 → 键不同（hash 碰撞时的区分项）
      expect(
        key,
        isNot(
          HighlightMatchSync.cacheKey(
            bookUrl: 'bk://k',
            chapterIndex: 3,
            text: 'abc',
            rulesRevision: 7,
          ),
        ),
      );
      // 修订号不同 → 键不同
      expect(
        key,
        isNot(
          HighlightMatchSync.cacheKey(
            bookUrl: 'bk://k',
            chapterIndex: 3,
            text: 'ab',
            rulesRevision: 8,
          ),
        ),
      );
    });

    test('缓存命中直接采用，不再跨 FFI', () {
      final cache = HighlightMatchCache();
      final key = HighlightMatchSync.cacheKey(
        bookUrl: 'bk://hl-sync',
        chapterIndex: 0,
        text: '第一章正文',
        rulesRevision: 0,
      );
      final cached = [
        HighlightMatch(
          ruleId: 9,
          start: 0,
          end: 2,
          order: 10,
          style: HighlightStyle.empty,
        ),
      ];
      cache.store(key, 0, cached);
      final sync = HighlightMatchSync(cache: cache);
      var calls = 0;

      final matches = sync.sync(
        request(),
        load: ({required text, required bookName, required origin}) {
          calls++;
          return Future.value('[]');
        },
        onLoaded: () {},
      );

      expect(calls, 0);
      expect(matches.single.ruleId, 9);
      expect(sync.key, key);
    });

    test('未命中发起一次 FFI，在途同 key 去重，结果采纳后回调一次', () async {
      final sync = HighlightMatchSync();
      var calls = 0;
      var loaded = 0;
      final completer = Completer<String>();
      Future<String> load({
        required String text,
        required String bookName,
        required String origin,
      }) {
        calls++;
        return completer.future;
      }

      expect(
        sync.sync(request(), load: load, onLoaded: () => loaded++),
        isEmpty,
      );
      expect(sync.loadingKey, isNotEmpty);
      // 同 key 在途：不重复跨 FFI
      sync.sync(request(), load: load, onLoaded: () => loaded++);
      expect(calls, 1);

      completer.complete(matchJson(0, 3));
      await settle();

      expect(sync.matches.single.start, 0);
      expect(sync.matches.single.end, 3);
      expect(loaded, 1);
      expect(sync.loadingKey, isEmpty);
    });

    test('换章立即清空旧命中（新结果未到前不套用上一章区间）', () async {
      final sync = HighlightMatchSync();
      final completers = <Completer<String>>[];
      Future<String> load({
        required String text,
        required String bookName,
        required String origin,
      }) {
        final completer = Completer<String>();
        completers.add(completer);
        return completer.future;
      }

      sync.sync(request(content: '第一章正文'), load: load, onLoaded: () {});
      completers[0].complete(matchJson(0, 2));
      await settle();
      expect(sync.matches, hasLength(1));

      final second = sync.sync(
        request(chapterIndex: 1, content: '第二章正文'),
        load: load,
        onLoaded: () {},
      );
      // 缓存未命中：本帧即清空，不等待新结果
      expect(second, isEmpty);
      expect(sync.matches, isEmpty);
      expect(completers, hasLength(2));

      // 旧章（上一章）结果即使后到也不会覆盖新章
      completers[1].complete(matchJson(1, 4));
      await settle();
      expect(sync.matches.single.start, 1);
    });
  });

  group('HighlightMatchSync - 停用与旧结果丢弃', () {
    test('滚动模式/无书（enabled=false）不调用 FFI 且清空旧命中', () async {
      final sync = HighlightMatchSync();
      var calls = 0;
      Future<String> load({
        required String text,
        required String bookName,
        required String origin,
      }) {
        calls++;
        return Future.value(matchJson(0, 2));
      }

      sync.sync(request(), load: load, onLoaded: () {});
      await settle();
      expect(calls, 1);
      expect(sync.matches, hasLength(1));

      final disabled = sync.sync(
        request(enabled: false),
        load: load,
        onLoaded: () {},
      );
      expect(disabled, isEmpty);
      expect(sync.matches, isEmpty);
      expect(sync.key, isEmpty);
      expect(calls, 1, reason: '滚动模式不得发起跨 FFI 匹配');
    });

    test('在途期间章节切换：旧章结果到达后丢弃', () async {
      final sync = HighlightMatchSync();
      final completers = <Completer<String>>[];
      var loaded = 0;
      Future<String> load({
        required String text,
        required String bookName,
        required String origin,
      }) {
        final completer = Completer<String>();
        completers.add(completer);
        return completer.future;
      }

      sync.sync(
        request(content: '第一章正文'),
        load: load,
        onLoaded: () => loaded++,
      );
      sync.sync(
        request(chapterIndex: 1, content: '第二章正文'),
        load: load,
        onLoaded: () => loaded++,
      );
      expect(completers, hasLength(2));

      completers[0].complete(matchJson(0, 3));
      await settle();
      expect(sync.matches, isEmpty, reason: '旧章结果必须丢弃');
      expect(loaded, 0);

      completers[1].complete(matchJson(5, 7));
      await settle();
      expect(sync.matches.single.start, 5);
      expect(loaded, 1);
    });

    test('规则修订号变化：旧修订号结果丢弃，新修订号结果生效', () async {
      final sync = HighlightMatchSync();
      final completers = <Completer<String>>[];
      var loaded = 0;
      Future<String> load({
        required String text,
        required String bookName,
        required String origin,
      }) {
        final completer = Completer<String>();
        completers.add(completer);
        return completer.future;
      }

      sync.sync(
        request(rulesRevision: 0),
        load: load,
        onLoaded: () => loaded++,
      );
      sync.sync(
        request(rulesRevision: 1),
        load: load,
        onLoaded: () => loaded++,
      );
      expect(completers, hasLength(2), reason: '修订号变化应重新匹配');

      completers[0].complete(matchJson(0, 2));
      await settle();
      expect(sync.matches, isEmpty, reason: '旧修订号结果必须丢弃');
      expect(loaded, 0);

      completers[1].complete(matchJson(2, 4));
      await settle();
      expect(sync.matches.single.start, 2);
      expect(loaded, 1);
    });
  });

  group('HighlightMatchSync - 失败退避与重试预算（P2-4）', () {
    test('失败清 key、按退避等待、单 key 最多尝试两次', () async {
      var now = DateTime(2026, 1, 1);
      var calls = 0;
      var loaded = 0;
      Future<String> failing({
        required String text,
        required String bookName,
        required String origin,
      }) async {
        calls++;
        throw StateError('FFI 异常');
      }

      final sync = HighlightMatchSync(
        retryDelay: const Duration(seconds: 2),
        now: () => now,
      );

      sync.sync(request(), load: failing, onLoaded: () => loaded++);
      await settle();
      expect(calls, 1);
      expect(sync.matches, isEmpty);
      expect(sync.key, isEmpty, reason: '失败后必须清 key 以允许一次重试');
      expect(loaded, 0);

      // 退避期内：不重试
      sync.sync(request(), load: failing, onLoaded: () => loaded++);
      expect(calls, 1);

      // 退避结束：第二次（也是最后一次）尝试
      now = now.add(const Duration(seconds: 3));
      sync.sync(request(), load: failing, onLoaded: () => loaded++);
      await settle();
      expect(calls, 2);

      // 预算耗尽：同章即使继续 build 也不再重试
      now = now.add(const Duration(hours: 1));
      sync.sync(request(), load: failing, onLoaded: () => loaded++);
      sync.sync(request(), load: failing, onLoaded: () => loaded++);
      await settle();
      expect(calls, 2, reason: '同 key 最多重试一次，不得每帧重试');
      expect(loaded, 0);
      expect(sync.matches, isEmpty);
    });

    test('失败后换章：新 key 重新获得独立重试预算', () async {
      var calls = 0;
      Future<String> failing({
        required String text,
        required String bookName,
        required String origin,
      }) async {
        calls++;
        throw StateError('FFI 异常');
      }

      final sync = HighlightMatchSync(retryDelay: Duration.zero);
      sync.sync(request(content: '第一章正文'), load: failing, onLoaded: () {});
      await settle();
      sync.sync(request(content: '第一章正文'), load: failing, onLoaded: () {});
      await settle();
      expect(calls, 2);
      sync.sync(request(content: '第一章正文'), load: failing, onLoaded: () {});
      await settle();
      expect(calls, 2, reason: '同章预算耗尽');

      sync.sync(
        request(chapterIndex: 1, content: '第二章正文'),
        load: failing,
        onLoaded: () {},
      );
      await settle();
      expect(calls, 3, reason: '新章节应重新发起匹配');
    });
  });
}
