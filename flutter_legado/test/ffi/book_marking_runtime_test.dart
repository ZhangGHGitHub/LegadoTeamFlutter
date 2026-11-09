/// 批7b-1：书签标记真实 DLL 运行时验证（契约 §2.52）
///
/// 加载 `rust/target/debug/legado_ffi.dll`（解析策略对齐
/// `test/ffi/highlight_rule_match_runtime_test.dart`），经真实 FRB wire 验证
/// RustApi 的类型化解码与 Rust 侧语义：
/// - 空 id 生成 UUID v4、createdAt<=0 补当前毫秒、updatedAt 恒写；
/// - 按书名+作者跨源列表（chapterIndex 升序、createdAt 升序）；
/// - 按源查询 Some 时含 chapterIndex IS NULL、None 取全书；
/// - setEnabled/delete 不存在 no-op；空 anchorJson 报 BridgeError。
///
/// 前置条件：先在 rust/ 下构建 DLL（cargo build -p legado-ffi）。
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_legado/src/bridge/ffi/ffi.dart' as bridge;
import 'package:flutter_legado/src/bridge/ffi.dart' show BridgeError;
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
    test('跳过 FFI 运行时书签标记测试：需要 Windows DLL 产物（仅本机验证）', () {});
    return;
  }

  const bookName = '批7b1运行时标记书';
  const bookAuthor = '运行时作者';
  const bookUrl = 'https://marking-runtime.example.com/book';
  late RustApi api;

  BookMarking marking({
    String id = '',
    String url = bookUrl,
    int? chapterIndex = 0,
    int createdAt = 0,
    String anchorJson = '{"p":1}',
  }) {
    return BookMarking(
      id: id,
      bookUrl: url,
      bookName: bookName,
      bookAuthor: bookAuthor,
      chapterIndex: chapterIndex,
      anchorJson: anchorJson,
      styleJson: '{"textColor":-1}',
      note: '运行时备注',
      chapterName: '运行时章',
      createdAt: createdAt,
    );
  }

  setUpAll(() async {
    final lib = ExternalLibrary.open(_resolveDll());
    await RustLib.init(externalLibrary: lib);
    await bridge.init();
    final sep = Platform.pathSeparator;
    final dbDir = Directory('.dart_tool${sep}ffi_book_marking_test');
    dbDir.createSync(recursive: true);
    final dbFile = File('${dbDir.path}${sep}book_marking.db');
    if (dbFile.existsSync()) {
      dbFile.deleteSync();
    }
    await bridge.dbOpen(path: dbFile.path);
    api = RustApi();
  });

  group('书签标记 RustApi 类型化解码（契约 §2.52）', () {
    test('save：空 id 生成 UUID v4，createdAt/updatedAt 补当前毫秒', () async {
      final before = DateTime.now().millisecondsSinceEpoch;
      final saved = await api.saveBookMarking(marking());
      final after = DateTime.now().millisecondsSinceEpoch;

      expect(saved, isA<BookMarking>());
      expect(saved.id, isNotEmpty);
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(saved.id),
        isTrue,
        reason: '空 id 应为 UUID v4，实际 ${saved.id}',
      );
      expect(saved.createdAt, inInclusiveRange(before, after));
      expect(saved.updatedAt, inInclusiveRange(before, after));
      expect(saved.enabled, isTrue);
      expect(saved.chapterIndex, 0);
      expect(saved.styleJson, '{"textColor":-1}');

      // 同 id 二次保存：id/createdAt 保留，updatedAt 重写
      final updated = await api.saveBookMarking(
        saved.copyWith(note: '二次备注', createdAt: 1, updatedAt: 1),
      );
      expect(updated.id, saved.id);
      expect(updated.createdAt, 1, reason: '显式 createdAt>0 予以保留');
      expect(updated.note, '二次备注');
      expect(updated.updatedAt, greaterThanOrEqualTo(saved.updatedAt));

      await api.deleteBookMarking(saved.id);
    });

    test('listByBook：跨源 + chapterIndex 升序（NULL 在前）+ createdAt 升序', () async {
      final c0late = await api.saveBookMarking(
        marking(id: 'rt-c0-late', chapterIndex: 0, createdAt: 300),
      );
      final c0early = await api.saveBookMarking(
        marking(id: 'rt-c0-early', chapterIndex: 0, createdAt: 200),
      );
      final global = await api.saveBookMarking(
        marking(id: 'rt-global', chapterIndex: null, createdAt: 400),
      );
      final otherSource = await api.saveBookMarking(
        marking(
          id: 'rt-other-source',
          url: 'https://marking-runtime.example.com/other',
          chapterIndex: 1,
          createdAt: 100,
        ),
      );

      final list = await api.getBookMarkingsByBook(bookName, bookAuthor);
      expect(list, isA<List<BookMarking>>());
      expect(
        list.map((m) => m.id).toList(),
        [global.id, c0early.id, c0late.id, otherSource.id],
      );

      final chapter = await api.getBookMarkingsForChapter(bookUrl, 0);
      expect(chapter.map((m) => m.id).toList(), [c0early.id, c0late.id, global.id]);

      final all = await api.getBookMarkingsForChapter(bookUrl, null);
      expect(all, hasLength(3));

      final miss = await api.getBookMarkingsForChapter(bookUrl, 9);
      expect(miss.map((m) => m.id).toList(), [global.id]);

      for (final m in list) {
        await api.deleteBookMarking(m.id);
      }
    });

    test('setEnabled/delete：存在生效，不存在 no-op', () async {
      final saved = await api.saveBookMarking(marking(id: 'rt-enable'));

      await api.setBookMarkingEnabled(saved.id, false);
      final listed = await api.getBookMarkingsForChapter(bookUrl, 0);
      expect(listed.single.enabled, isFalse);
      expect(listed.single.updatedAt, greaterThanOrEqualTo(saved.updatedAt));

      await api.setBookMarkingEnabled('不存在的-id', true); // no-op
      await api.deleteBookMarking('不存在的-id'); // no-op

      await api.deleteBookMarking(saved.id);
      expect(await api.getBookMarkingsForChapter(bookUrl, 0), isEmpty);
    });

    test('空 anchorJson → BridgeError（Rust 参数错误透传）', () async {
      await expectLater(
        api.saveBookMarking(marking(anchorJson: '   ')),
        throwsA(
          isA<BridgeError>().having(
            (e) => e.message,
            'message',
            contains('anchorJson 不能为空'),
          ),
        ),
      );
    });
  });
}
