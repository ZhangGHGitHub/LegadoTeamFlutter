/// 审查批6：RSS 源启用/禁用误接书源 FFI 的回归护栏（契约 §2.5）
///
/// 缺陷：`rust_api_search_rss.part.dart` 的 `enableRssSource` / `disableRssSource`
/// 曾调用书源 FFI `sourceEnable` / `sourceDisable`（走 `BookSourceRepository`）——
/// RSS-only 源报「书源不存在」，同 URL 恰有书源时误改书源。
///
/// 本测试锁定三件事：
/// 1. 两个方法只委托 `rssSourceSetEnabled`，源码中不再出现 `bridge.sourceEnable` /
///    `bridge.sourceDisable`（防回退）；
/// 2. FRB codegen 产物暴露 `rssSourceSetEnabled`（防漏跑 codegen）；
/// 3. `MockBookApi` 与 Rust 侧同语义：命中返回 true，源不存在返回 false 不抛错。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/mock_book_api.dart';

String _read(String path) => File(path).readAsStringSync();

/// 抽取方法源码（含方法体；表达式体截到分号）。
String _methodSource(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '未找到方法签名：$signature');
  final brace = src.indexOf('{', start);
  final semi = src.indexOf(';', start);
  if (brace < 0 || (semi >= 0 && semi < brace)) {
    expect(semi, greaterThan(start), reason: '方法既无方法体也无分号：$signature');
    return src.substring(start, semi + 1);
  }
  var depth = 0;
  for (var i = brace; i < src.length; i++) {
    final c = src[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  fail('方法体括号不闭合：$signature');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RustApi RSS 开关接线（契约 §2.5）', () {
    final src = _read('lib/src/services/rust_api_search_rss.part.dart');

    test('enableRssSource / disableRssSource 不再调用书源 FFI', () {
      for (final signature in <String>[
        'Future<void> enableRssSource(String sourceUrl)',
        'Future<void> disableRssSource(String sourceUrl)',
      ]) {
        final body = _methodSource(src, signature);
        expect(
          body,
          isNot(contains('bridge.sourceEnable(')),
          reason: '$signature 仍调用书源 FFI sourceEnable（RSS 源会误改/报书源不存在）',
        );
        expect(
          body,
          isNot(contains('bridge.sourceDisable(')),
          reason: '$signature 仍调用书源 FFI sourceDisable（RSS 源会误改/报书源不存在）',
        );
        expect(
          body,
          contains('rssSourceSetEnabled('),
          reason: '$signature 应委托 rssSourceSetEnabled（RSS 专用写路径）',
        );
      }
    });

    test('rssSourceSetEnabled 直连 RSS 专用 FFI 绑定', () {
      final body = _methodSource(
        src,
        'Future<bool> rssSourceSetEnabled(String sourceUrl, bool enabled)',
      );
      expect(body, contains('bridge.rssSourceSetEnabled('));
      expect(body, isNot(contains('bridge.sourceEnable(')));
      expect(body, isNot(contains('bridge.sourceDisable(')));
    });

    test('FRB codegen 产物已包含 rssSourceSetEnabled（未漏跑 codegen）', () {
      final ffi = _read('lib/src/bridge/ffi/ffi.dart');
      expect(ffi, contains('Future<bool> rssSourceSetEnabled('));
      expect(ffi, contains('crateFfiFfiRssSourceSetEnabled'));
    });
  });

  group('MockBookApi RSS 开关语义（对齐 Rust set_enabled）', () {
    late MockBookApi api;

    setUp(() {
      api = MockBookApi();
    });

    test('命中源：返回 true 且状态翻转，enable/disable 委托同一路径', () async {
      final sources = await api.getRssSources();
      expect(sources, isNotEmpty);
      final target = sources.first;

      expect(
        await api.rssSourceSetEnabled(target.sourceUrl, !target.enabled),
        isTrue,
        reason: '命中行应返回 true',
      );
      final afterSet = (await api.getRssSources()).firstWhere(
        (s) => s.sourceUrl == target.sourceUrl,
      );
      expect(afterSet.enabled, !target.enabled);

      await api.enableRssSource(target.sourceUrl);
      final afterEnable = (await api.getRssSources()).firstWhere(
        (s) => s.sourceUrl == target.sourceUrl,
      );
      expect(afterEnable.enabled, isTrue);

      await api.disableRssSource(target.sourceUrl);
      final afterDisable = (await api.getRssSources()).firstWhere(
        (s) => s.sourceUrl == target.sourceUrl,
      );
      expect(afterDisable.enabled, isFalse);
    });

    test('源不存在：返回 false，不抛错、不新增行', () async {
      final before = (await api.getRssSources()).length;
      expect(
        await api.rssSourceSetEnabled(
          'https://rss-missing.example.com/feed',
          true,
        ),
        isFalse,
        reason: '源不存在应返回 false（对齐原版静默 UPDATE 语义）',
      );
      expect((await api.getRssSources()).length, before);
    });
  });
}
