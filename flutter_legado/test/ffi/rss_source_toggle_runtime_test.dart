/// 审查批6：RSS 源开关真实 DLL 运行时验证（契约 §2.5 `rssSourceSetEnabled`）
///
/// 加载 `rust/target/debug/legado_ffi.dll`（解析策略对齐
/// `test/ffi/cache_download_failed_chapters_runtime_test.dart`），经真实 FRB wire 验证：
/// - RSS-only 源（书源表无同 URL）可启用/禁用，返回 `true`；
/// - 同 URL 存在书源时，RSS 开关只改 `rssSources.enabled`，书源 `enabled` 不变
///   （缺陷回归：旧实现误走 `source_enable` 会改书源）；
/// - 源不存在返回 `false`（不抛错、不新增行），对齐原版 `RssSourceDao.enable`
///   的 Room UPDATE 静默语义。
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
    // flutter test 的 Directory.current 即 flutter_legado/
    '${Directory.current.parent.path}${sep}rust${sep}target${sep}debug$sep$libName',
    '${Directory.current.path}$sep..${sep}rust${sep}target${sep}debug$sep$libName',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  throw StateError('未找到 legado_ffi.dll，请先在 rust/ 下构建');
}

Map<String, dynamic>? _findByUrl(String json, String key, String url) {
  final list = jsonDecode(json) as List<dynamic>;
  for (final item in list) {
    if (item is Map && item[key] == url) {
      return Map<String, dynamic>.from(item);
    }
  }
  return null;
}

void main() {
  // 该测试依赖 Windows 构建的 DLL 产物（rust/target/debug），
  // CI（ubuntu/macOS）无产物：注册阶段整体跳过（仅留占位用例可见）
  if (!Platform.isWindows) {
    test('跳过 FFI 运行时 RSS 开关测试：需要 Windows DLL 产物（仅本机验证）', () {});
    return;
  }

  const rssOnlyUrl = 'https://rss-toggle-runtime.example.com/feed';
  const sharedUrl = 'https://rss-toggle-runtime.example.com/shared';
  const missingUrl = 'https://rss-toggle-runtime.example.com/missing';
  late RustApi api;

  Future<bool> enabledOf(String url) async {
    final json = await bridge.rssListSources();
    return _findByUrl(json, 'sourceUrl', url)!['enabled'] as bool;
  }

  setUpAll(() async {
    final lib = ExternalLibrary.open(_resolveDll());
    await RustLib.init(externalLibrary: lib);
    await bridge.init();
    // 隔离数据库，保证断言确定性
    final sep = Platform.pathSeparator;
    final dbDir = Directory('.dart_tool${sep}ffi_rss_toggle_test');
    dbDir.createSync(recursive: true);
    final dbFile = File('${dbDir.path}${sep}rss_source_toggle.db');
    if (dbFile.existsSync()) {
      dbFile.deleteSync();
    }
    await bridge.dbOpen(path: dbFile.path);
    api = RustApi();

    // RSS-only 源（初始禁用）
    await bridge.rssAddSource(
      sourceJson: jsonEncode({
        'sourceUrl': rssOnlyUrl,
        'sourceName': 'RSS-only 源',
        'enabled': false,
      }),
    );
    // 同 URL 同时存在 RSS 源与书源（缺陷复现前提）
    await bridge.rssAddSource(
      sourceJson: jsonEncode({
        'sourceUrl': sharedUrl,
        'sourceName': '同 URL RSS 源',
        'enabled': true,
      }),
    );
    await bridge.sourceAdd(
      sourceJson: jsonEncode({
        'bookSourceUrl': sharedUrl,
        'bookSourceName': '同 URL 书源',
        'enabled': true,
      }),
    );
  });

  group('RSS 源开关真实 DLL 运行时验证（契约 §2.5）', () {
    test('RSS-only 源：启用/禁用返回 true 且状态翻转', () async {
      expect(await enabledOf(rssOnlyUrl), isFalse);
      expect(await api.rssSourceSetEnabled(rssOnlyUrl, true), isTrue);
      expect(await enabledOf(rssOnlyUrl), isTrue);
      await api.disableRssSource(rssOnlyUrl);
      expect(await enabledOf(rssOnlyUrl), isFalse);
      await api.enableRssSource(rssOnlyUrl);
      expect(await enabledOf(rssOnlyUrl), isTrue);
    });

    test('同 URL 书源不被 RSS 开关改动（缺陷回归）', () async {
      expect(await api.rssSourceSetEnabled(sharedUrl, false), isTrue);
      expect(await enabledOf(sharedUrl), isFalse);
      final book = _findByUrl(
        await bridge.sourceList(),
        'bookSourceUrl',
        sharedUrl,
      );
      expect(book, isNotNull, reason: '书源应存在');
      expect(book!['enabled'], isTrue, reason: 'RSS 源开关不得改动书源 enabled');
    });

    test('源不存在：返回 false，不抛错、不新增行', () async {
      final before = (jsonDecode(await bridge.rssListSources()) as List).length;
      expect(await api.rssSourceSetEnabled(missingUrl, true), isFalse);
      final after = (jsonDecode(await bridge.rssListSources()) as List).length;
      expect(after, before, reason: '源不存在时不得静默插入新行');
    });
  });
}
