/// [批43b] TXT 目录规则 Dart↔Rust 真实数据链运行时验证
///
/// 加载 `rust/target/debug/legado_ffi.dll`（解析策略对齐
/// `read_record_skip_runtime_test.dart`），经真实 FRB wire 验证：
/// - `setBookTocRule` → `getChaptersWithMeta` 透出 `usedCustomRule`；
/// - set 返回的 Book 派生字段为 0，`updateBook` 陈旧快照不得打回 N；
/// - 恢复默认（null）后陈旧快照不得复活旧 `tocUrl`，目录按默认规则解析。
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
    if (File(path).existsSync()) {
      return path;
    }
  }
  throw StateError('未找到 legado_ffi.dll，请先在 rust/ 下构建');
}

void main() {
  // 该测试依赖 Windows 构建的 DLL 产物（rust/target/debug），
  // CI（ubuntu/macOS）无产物：注册阶段整体跳过（仅留占位用例可见）
  if (!Platform.isWindows) {
    test('跳过 FFI 运行时 TXT 目录规则测试：需要 Windows DLL 产物（仅本机验证）', () {});
    return;
  }

  late RustApi api;

  setUpAll(() async {
    final lib = ExternalLibrary.open(_resolveDll());
    await RustLib.init(externalLibrary: lib);
    await bridge.init();
    final sep = Platform.pathSeparator;
    final root = Directory('.dart_tool${sep}ffi_txt_toc_rule_test')
      ..createSync(recursive: true);
    final dbFile = File('${root.path}${sep}p43b_toc_rule.db');
    for (final entity in root.listSync()) {
      if (entity is File) {
        try {
          entity.deleteSync();
        } catch (_) {
          // 上一轮进程仍持有 DB 文件时忽略（Windows 文件锁）
        }
      }
    }
    await bridge.dbOpen(path: dbFile.path);
    final books = Directory('${root.path}${sep}books')..createSync(recursive: true);
    File('${books.path}${sep}rules.txt').writeAsStringSync(
      '\n【第一篇】 开端\n甲。\n【第二篇】 继续\n乙。\n第五章 默认\n丙。\n',
    );
    api = RustApi();
    final imported = await api.importLocalBook('books/rules.txt');
    expect(imported.bookUrl, 'books/rules.txt');
  });

  test('set rule → 元信息 → 陈旧整书写回 → 恢复默认全链', () async {
    const bookUrl = 'books/rules.txt';
    const ruleA = r'^【第.+篇】.*$';

    // 1) 应用规则：返回的 Book 派生字段已失效（0/NULL）
    final stale = await api.setBookTocRule(
      bookUrl,
      jsonEncode({'rule': ruleA, 'replacement': ''}),
    );
    expect(stale.totalChapterNum, 0, reason: '设置规则后旧派生字段应失效');

    // 2) 重新解析：used_custom_rule 透出 true，books 行回填 N=2
    final meta = await api.getChaptersWithMeta(bookUrl);
    expect(meta.chapters.length, 2);
    expect(meta.usedCustomRule, isTrue, reason: '规则命中应透出 usedCustomRule');
    final expectedLatest = meta.chapters.last.title;

    // 3) 陈旧 Book 整书写回：派生字段保持 2/末章标题
    await api.updateBook(stale);
    final afterUpdate = await api.getBook(bookUrl);
    expect(afterUpdate?.totalChapterNum, 2, reason: '陈旧快照不得把章数打回 0');
    expect(afterUpdate?.latestChapterTitle, expectedLatest);

    // 4) 恢复默认：目录按内置规则解析（1 章），usedCustomRule=false
    await api.setBookTocRule(bookUrl, null);
    final restored = await api.getChaptersWithMeta(bookUrl);
    expect(restored.chapters.length, 1);
    expect(restored.chapters.first.title, '第五章 默认');
    expect(restored.usedCustomRule, isFalse);

    // 5) 旧快照（tocUrl=规则 A）整书写回：不得复活旧规则
    await api.updateBook(stale);
    final saved = await api.getBook(bookUrl);
    expect(saved?.tocUrl, '', reason: '恢复默认后的空 tocUrl 不得被旧快照复活');
    expect(saved?.totalChapterNum, 1);
    final afterStale = await api.getChaptersWithMeta(bookUrl);
    expect(afterStale.chapters.length, 1, reason: '旧规则不得复活');
    expect(afterStale.chapters.first.title, '第五章 默认');
  });
}
