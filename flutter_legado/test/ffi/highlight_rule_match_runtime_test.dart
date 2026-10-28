/// 批34：高亮规则正文匹配真实 DLL 运行时验证（契约 §2.36 `highlightRuleMatch`）
///
/// 加载 `rust/target/debug/legado_ffi.dll`（解析策略对齐
/// `test/ffi/rss_source_toggle_runtime_test.dart`），经真实 FRB wire 验证：
/// - 字面量/正则（Java `\uXXXX` 方言）匹配与 UTF-16 半开区间；
/// - 高 order 覆盖低 order（截断）、applyToBody/scope 过滤、maxMatches=0；
/// - 无效正则跳过不影响其他规则。
///
/// 前置条件：先在 rust/ 下构建 DLL
/// （cargo build -p legado-ffi --features quickjs）。
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_legado/src/bridge/ffi/ffi.dart' as bridge;
import 'package:flutter_legado/src/bridge/frb_generated.dart';
import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

/// 从 rust/target/debug 解析真实 DLL 路径（对齐 rust_api.dart 的搜索策略）
String _resolveDll() {
  const libName = 'legado_ffi.dll';
  final sep = Platform.pathSeparator;
  final candidates = <String>[
    '${Directory.current.parent.path}${sep}rust${sep}target${sep}debug$sep$libName',
    '${Directory.current.path}$sep..${sep}rust${sep}target${sep}debug$sep$libName',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  throw StateError('未找到 legado_ffi.dll，请先在 rust/ 下构建');
}

void main() {
  // 该测试依赖 Windows 构建的 DLL 产物（rust/target/debug），
  // CI（ubuntu/macOS）无产物：注册阶段整体跳过（仅留占位用例可见）
  if (!Platform.isWindows) {
    test('跳过 FFI 运行时高亮匹配测试：需要 Windows DLL 产物（仅本机验证）', () {});
    return;
  }

  const bookName = '批34运行时匹配书';
  const origin = 'https://highlight-runtime.example.com';
  const text = '😀关键词与关键词，尾部关键词。';
  late RustApi api;

  Future<int> saveRule({
    required String name,
    required String pattern,
    required bool isRegex,
    required int sortOrder,
    bool applyToTitle = false,
    bool applyToBody = true,
  }) {
    return api.highlightRuleSave(
      ruleJson: jsonEncode({
        'name': name,
        'pattern': pattern,
        'isRegex': isRegex,
        'scope': bookName,
        'isEnabled': true,
        'style': '{"fill":-2130710154}',
        'sortOrder': sortOrder,
        'timeoutMillisecond': 3000,
        'applyToTitle': applyToTitle,
        'applyToBody': applyToBody,
      }),
    );
  }

  setUpAll(() async {
    final lib = ExternalLibrary.open(_resolveDll());
    await RustLib.init(externalLibrary: lib);
    await bridge.init();
    final sep = Platform.pathSeparator;
    final dbDir = Directory('.dart_tool${sep}ffi_highlight_match_test');
    dbDir.createSync(recursive: true);
    final dbFile = File('${dbDir.path}${sep}highlight_match.db');
    if (dbFile.existsSync()) {
      dbFile.deleteSync();
    }
    await bridge.dbOpen(path: dbFile.path);
    api = RustApi();
  });

  group('highlightRuleMatch 真实 DLL 运行时验证（契约 §2.36）', () {
    test('字面量：UTF-16 区间 + styleJson 原样透传', () async {
      final id = await saveRule(
        name: '字面量',
        pattern: '关键词',
        isRegex: false,
        sortOrder: 10,
      );
      final raw = await api.highlightRuleMatch(
        text: text,
        bookName: bookName,
        origin: origin,
      );
      final matches = (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .where((m) => m['ruleId'] == id)
          .toList();
      // 😀 占 2 个 code unit → 首个命中起点 2
      expect(matches.map((m) => (m['start'], m['end'])).toList(), [
        (2, 5),
        (6, 9),
        (12, 15),
      ]);
      expect(matches.first['order'], 10);
      expect(matches.first['styleJson'], '{"fill":-2130710154}');
      expect(await api.highlightRuleDelete(id: id), isTrue);
    });

    test('正则 Java 方言 + 无效正则跳过', () async {
      final good = await saveRule(
        name: '正则',
        pattern: r'\u5173.词',
        isRegex: true,
        sortOrder: 20,
      );
      final bad = await saveRule(
        name: '坏正则',
        pattern: '(',
        isRegex: true,
        sortOrder: 30,
      );
      final raw = await api.highlightRuleMatch(
        text: text,
        bookName: bookName,
        origin: origin,
      );
      final ids = (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map((m) => m['ruleId'])
          .toSet();
      expect(ids, contains(good));
      expect(ids, isNot(contains(bad)));
      expect(await api.highlightRuleDelete(id: good), isTrue);
      expect(await api.highlightRuleDelete(id: bad), isTrue);
    });

    test('重叠：高 order 覆盖低 order 并截断', () async {
      final low = await saveRule(
        name: '低',
        pattern: 'abcdef',
        isRegex: false,
        sortOrder: 1,
      );
      final high = await saveRule(
        name: '高',
        pattern: 'cde',
        isRegex: false,
        sortOrder: 5,
      );
      final raw = await api.highlightRuleMatch(
        text: 'xxabcdefyy',
        bookName: bookName,
        origin: origin,
      );
      final own = (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .where((m) => m['ruleId'] == low || m['ruleId'] == high)
          .map((m) => (m['ruleId'], m['start'], m['end']))
          .toList();
      expect(own, [(low, 2, 4), (low, 7, 8), (high, 4, 7)]);
      expect(await api.highlightRuleDelete(id: low), isTrue);
      expect(await api.highlightRuleDelete(id: high), isTrue);
    });

    test('applyToTitle 过滤 + maxMatches=0', () async {
      final titleOnly = await saveRule(
        name: '仅标题',
        pattern: '标题词',
        isRegex: false,
        sortOrder: 5,
        applyToTitle: true,
        applyToBody: false,
      );
      final bodyRaw = await api.highlightRuleMatch(
        text: '标题词',
        bookName: bookName,
        origin: origin,
      );
      expect(
        (jsonDecode(bodyRaw) as List).any((m) => m['ruleId'] == titleOnly),
        isFalse,
      );
      final titleRaw = await api.highlightRuleMatch(
        text: '标题词',
        bookName: bookName,
        origin: origin,
        applyToTitle: true,
      );
      expect(
        (jsonDecode(titleRaw) as List).any((m) => m['ruleId'] == titleOnly),
        isTrue,
      );
      expect(
        await api.highlightRuleMatch(
          text: '标题词',
          bookName: bookName,
          origin: origin,
          maxMatches: 0,
        ),
        '[]',
      );
      expect(await api.highlightRuleDelete(id: titleOnly), isTrue);
    });
  });
}
