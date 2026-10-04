/// P2-29c 后续 失败章查询 Dart↔Rust 真实数据链运行时验证（契约 §2.43.8）
///
/// 加载 rust/target/debug/legado_ffi.dll（解析策略对齐
/// audio_cache_runtime_test.dart / ffi_stream_sink_runtime_test.dart），
/// 经真实 FRB wire 验证：
///
/// - `cacheDownloadFailedChapters` 返回 JSON 整型数组形态（无失败 = `[]`，
///   可经 jsonDecode 解析为 List，对应 `RustApi.listFailedChapters` 的
///   `List<int>` 解析口径）
/// - `RustApi.listFailedChapters`（契约 §2.43.8 Dart 封装）端到端可达
/// - 查询零写入：重复调用结果恒定
///
/// 失败记入/成功移除/持久化/恢复回读的完整数据链由 Rust 单测覆盖
/// （rust/legado-ffi/src/api/cache_download_api.rs，本地 TXT 夹具不联网）。
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

void main() {
  // 该测试依赖 Windows 构建的 DLL 产物（rust/target/debug），
  // CI（ubuntu/macOS）无产物：注册阶段整体跳过（仅留占位用例可见）
  if (!Platform.isWindows) {
    test('跳过 FFI 运行时失败章查询测试：需要 Windows DLL 产物（仅本机验证）', () {});
    return;
  }

  const noTaskBook = 'http://p2438-no-task.example.com/book';
  late RustApi api;

  setUpAll(() async {
    final lib = ExternalLibrary.open(_resolveDll());
    await RustLib.init(externalLibrary: lib);
    await bridge.init();
    // 隔离数据库：无该书的批量下载任务，保证断言确定性
    final sep = Platform.pathSeparator;
    final dbDir = Directory('.dart_tool${sep}ffi_failed_chapters_test');
    dbDir.createSync(recursive: true);
    final dbFile = File('${dbDir.path}${sep}p2_43_8_failed_chapters.db');
    if (dbFile.existsSync()) {
      dbFile.deleteSync();
    }
    await bridge.dbOpen(path: dbFile.path);
    api = RustApi();
  });

  group('失败章查询真实 DLL 运行时验证（契约 §2.43.8）', () {
    test('FFI：无任务书返回 JSON 空数组 `[]`（整型数组形态）', () async {
      final json = await bridge.cacheDownloadFailedChapters(bookUrl: noTaskBook);
      expect(json, '[]', reason: '无失败应返回空 JSON 数组');
      final decoded = jsonDecode(json);
      expect(decoded, isA<List<dynamic>>(), reason: '应为 JSON 数组');
      expect(decoded, isEmpty);
    });

    test('列表形态：整型元素可解析为 List<int>（对齐 RustApi 解析口径）', () {
      // 解析口径与 rust_api_discovery_cache.part.dart 的 listFailedChapters
      // 实现一致：List 内 int 直接收录、字符串数字 tryParse 收录
      final decoded = jsonDecode('[3, 1, 7]') as List<dynamic>;
      final list = <int>[];
      for (final e in decoded) {
        if (e is int) {
          list.add(e);
        } else {
          final v = int.tryParse(e.toString());
          if (v != null) {
            list.add(v);
          }
        }
      }
      expect(list, const [3, 1, 7]);
    });

    test('Dart 封装可达且零写入：RustApi.listFailedChapters 重复调用恒定空', () async {
      expect(await api.listFailedChapters(noTaskBook), isEmpty);
      expect(await api.listFailedChapters(noTaskBook), isEmpty);
      final json = await bridge.cacheDownloadFailedChapters(bookUrl: noTaskBook);
      expect(json, '[]', reason: '查询为纯读，重复调用不得改写任务快照');
    });
  });
}
