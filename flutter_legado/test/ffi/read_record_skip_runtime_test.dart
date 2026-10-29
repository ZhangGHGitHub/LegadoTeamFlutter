/// [批35b P3-7] 书籍级阅读记录开关的 Dart↔Rust 真实数据链运行时验证
///
/// 加载 rust/target/debug/legado_ffi.dll（解析策略对齐
/// cache_download_failed_chapters_runtime_test.dart），经真实 FRB wire 验证：
///
/// - `setReadRecordDisabled(true)` 后 `putReadRecord(bookUrl)` **真正触发
///   Rust 侧跳过**：返回 `false`（Rust 哨兵 -1 折算）、readRecord 零写入；
/// - 重新开启后同一调用返回 `true` 并写入记录（恢复路径不被误跳过）。
///
/// 前置条件：先在 rust/ 下构建 DLL
/// （cargo build -p legado-ffi --features quickjs）。
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_legado/src/bridge/ffi/ffi.dart' as bridge;
import 'package:flutter_legado/src/bridge/frb_generated.dart';
import 'package:flutter_legado/src/models/models.dart';
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
    test('跳过 FFI 运行时阅读记录守卫测试：需要 Windows DLL 产物（仅本机验证）', () {});
    return;
  }

  const bookUrl = 'https://p35b-read-record.example.com/book/1';
  const bookName = '批35b运行时守卫书';
  late RustApi api;

  setUpAll(() async {
    final lib = ExternalLibrary.open(_resolveDll());
    await RustLib.init(externalLibrary: lib);
    await bridge.init();
    // 隔离数据库（每次运行重建，避免上一轮残留开关/记录）
    final sep = Platform.pathSeparator;
    final dbDir = Directory('.dart_tool${sep}ffi_read_record_skip_test');
    dbDir.createSync(recursive: true);
    final dbFile = File('${dbDir.path}${sep}p35b_read_record_skip.db');
    if (dbFile.existsSync()) {
      dbFile.deleteSync();
    }
    await bridge.dbOpen(path: dbFile.path);
    api = RustApi();
    // 造一本在线书（type=text，origin=http，非本地书）
    await bridge.bookshelfAdd(
      bookJson: jsonEncode({
        'bookUrl': bookUrl,
        'name': bookName,
        'author': '',
        'origin': 'https://p35b-read-record.example.com',
        'type': 8,
      }),
    );
  });

  group('书籍级阅读记录开关真实 DLL 运行时验证（批35b P3-7）', () {
    test('开关为真：putReadRecord(bookUrl) 返回 false 且零写入', () async {
      await bridge.readRecordClear();
      await bridge.bookSetReadRecordDisabled(bookUrl: bookUrl, disabled: true);

      final written = await api.putReadRecord(
        const ReadRecord(bookName: bookName, readTime: 5000, lastRead: 1),
        bookUrl: bookUrl,
      );
      expect(written, isFalse, reason: 'Rust 按库内开关跳过，Dart 折算为 false');
      expect(
        await api.getReadRecords(),
        isEmpty,
        reason: '跳过时 readRecord 必须零写入',
      );
    });

    test('重新开启：同一调用返回 true 并写入记录', () async {
      await bridge.readRecordClear();
      await bridge.bookSetReadRecordDisabled(bookUrl: bookUrl, disabled: false);

      final written = await api.putReadRecord(
        const ReadRecord(bookName: bookName, readTime: 7000, lastRead: 1),
        bookUrl: bookUrl,
      );
      expect(written, isTrue, reason: '开启后应真正写入');
      final records = await api.getReadRecords();
      expect(
        records.where((r) => r.bookName == bookName).single.readTime,
        7000,
      );
    });

    test('不传 bookUrl（recordReadingTime 契约形状）：开关不生效', () async {
      await bridge.readRecordClear();
      await bridge.bookSetReadRecordDisabled(bookUrl: bookUrl, disabled: true);

      // [批35b P3-6] 契约登记：不传 bookUrl 的旧统计入口不受书级开关约束
      await api.recordReadingTime(bookName, 3);
      expect(
        (await api.getReadRecords()).any((r) => r.bookName == bookName),
        isTrue,
        reason: 'recordReadingTime 不传 bookUrl，Rust 侧无从判断书级开关',
      );
    });
  });
}
