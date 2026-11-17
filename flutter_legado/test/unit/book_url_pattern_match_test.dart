// C7：`matchesBookUrlPattern` 下沉 FFI 的 Dart 侧守护（契约 §2.17）
//
// 校验三件事：
// 1. MockBookApi 的近似实现（`^(?:pattern)$` 全匹配）与 Rust 唯一真源同口径：
//    搜索页不被 `(https?://)?(www.)?m.qibuge.com` 命中（Rust 侧 `is_match`
//    部分匹配会误命中，这正是锚定的原因）；
// 2. 空/空白 pattern 一律 false（未配置不参与判定）；
// 3. 非法正则静默 false，不抛 FormatException；
// 4. 源码守卫：书架「添加网址」不得再自行编译书源 pattern（`RegExp(pattern)`
//    在 bookshelf_screen.dart 中必须消失），且必须调用
//    `api.matchesBookUrlPattern`。

import 'dart:io';

import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BookApi.matchesBookUrlPattern（Mock 近似实现同 Rust 口径）', () {
    late BookApi api;

    setUp(() => api = MockBookApi());

    test('全匹配：搜索页不被详情页正则命中', () async {
      const pattern = r'(https?://)?(www\.)?m\.qibuge\.com';
      expect(
        await api.matchesBookUrlPattern(pattern, 'https://m.qibuge.com'),
        isTrue,
      );
      expect(
        await api.matchesBookUrlPattern(
          pattern,
          'https://m.qibuge.com/s.php?q=x',
        ),
        isFalse,
        reason: '部分匹配会把搜索页误判为详情页（Rust 侧锚定全匹配的原因）',
      );
    });

    test('空 / 空白 pattern 一律 false', () async {
      expect(await api.matchesBookUrlPattern('', 'https://a.com/b'), isFalse);
      expect(
        await api.matchesBookUrlPattern('   ', 'https://a.com/b'),
        isFalse,
      );
    });

    test('非法正则静默 false（不抛 FormatException）', () async {
      expect(
        await api.matchesBookUrlPattern('[invalid', 'https://a.com/b'),
        isFalse,
      );
    });

    test('正则特殊字符按正则语义生效', () async {
      expect(
        await api.matchesBookUrlPattern(
          r'https://example\.com/book/\d+\.html',
          'https://example.com/book/123.html',
        ),
        isTrue,
      );
      expect(
        await api.matchesBookUrlPattern(
          r'https://example\.com/book/\d+\.html',
          'https://example.com/book/abc.html',
        ),
        isFalse,
      );
    });
  });

  group('C7 源码守卫：书架添加网址不再自行编译书源 pattern', () {
    test('书架与共用工具均无 RegExp(pattern) 调用，且走 FFI', () {
      final screen = File(
        'lib/src/screens/bookshelf_screen.dart',
      ).readAsStringSync();
      // 只查真实调用形态（文档注释里保留历史说明属正常）
      expect(
        screen.contains('RegExp(pattern).hasMatch'),
        isFalse,
        reason: 'Dart 侧 RegExp 书源匹配已下沉 Rust（契约 §2.17 C7），不得回退',
      );
      // [C4] 匹配实现已抽到共用工具，书架只做委托
      expect(
        screen.contains('matchBookSourceForUrl'),
        isTrue,
        reason: '「添加网址」书源匹配必须走共用匹配工具',
      );
      final shared = File(
        'lib/src/utils/book_source_match.dart',
      ).readAsStringSync();
      expect(
        shared.contains('api.matchesBookUrlPattern'),
        isTrue,
        reason: '共用匹配工具的正则段必须走 FFI matchesBookUrlPattern',
      );
      expect(
        shared.contains('RegExp(pattern)'),
        isFalse,
        reason: '共用匹配工具不得自行编译书源 pattern',
      );
    });

    test('Rust 侧唯一真源仍在 legado-fetcher（防止实现被删除后静默失效）', () {
      final src = File(
        '../rust/legado-fetcher/src/web_book.rs',
      ).readAsStringSync();
      expect(
        src.contains('pub fn matches_book_url_pattern'),
        isTrue,
        reason: 'Rust 唯一真源缺失',
      );
      // [C7 审查 P1-2] 锚定全匹配（对齐 Kotlin String.matches）已收敛到
      // `legado_core::compile_full_match_regex_safe`（长度上限按原始 pattern
      // 判定，锚定包装 +6 字节不占用户额度），fetcher 必须走该入口。
      expect(
        src.contains('compile_full_match_regex_safe'),
        isTrue,
        reason: 'Rust 侧必须走锚定全匹配入口（否则语义退化为部分匹配）',
      );
      // lookaround 等 regex crate 不支持的方言必须回退 fancy，否则静默失效
      expect(
        src.contains('compile_full_match_fancy_regex_safe'),
        isTrue,
        reason: 'lookahead/lookbehind pattern 必须回退 fancy-regex，否则永不匹配',
      );
      final core = File(
        '../rust/legado-core/src/regex_safe.rs',
      ).readAsStringSync();
      expect(
        core.contains(r'^(?:'),
        isTrue,
        reason: r'锚定实现必须仍是 ^(?:pattern)$ 全匹配语义',
      );
      expect(
        core.contains(r'FULL_MATCH_ANCHOR_SUFFIX: &str = ")$"'),
        isTrue,
        reason: r'锚定后缀必须仍为 )$',
      );
    });
  });
}
