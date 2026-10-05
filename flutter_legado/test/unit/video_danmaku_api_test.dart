// V-B1/V-B2 视频弹幕 Dart 侧定向测试（契约 §2.49 数据链 + §2.50 解析）
//
// 覆盖 Dart 侧可验证面：
// 1. BookApi 签名面（`Future<String?>` / `Future<List<VideoDanmakuItem>?>` +
//    命名参数，编译期形状）
// 2. MockBookApi 空态 → null（对齐 Rust「无记录降级 null」语义）
// 3. RustApi FFI 不可用（库未初始化）时降级 null 不抛异常
//    （弹幕是增强层不是数据源，对齐 §2.46/§2.50 口径）
//
// Rust 侧存储选型/阈值分流/文件往返/写失败降级由
// `rust/legado-ffi/src/api/video_api.rs` 覆盖（含 §2.50 解析 8 例）；
// Dart↔Rust 真实 DLL 运行时用例见 test/ffi/video_danmaku_runtime_test.dart。
//
// [V-B1 | 2026-10-05] 新增（契约 §2.49 video_danmaku FFI）。
// [V-B2 | 2026-10-05] 扩展（契约 §2.50 parseVideoDanmaku FFI）。

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/rust_api.dart';

void main() {
  // MockBookApi 构造经惰性样例资产读取（rootBundle）→ 需绑定初始化
  TestWidgetsFlutterBinding.ensureInitialized();

  const bookUrl = 'mock://book/video-1';

  group('MockBookApi 视频弹幕（契约 §2.49）', () {
    test('空态无弹幕 → null（降级语义）', () async {
      final api = MockBookApi();
      expect(
        await api.getVideoDanmaku(bookUrl: bookUrl, chapterIndex: 0),
        isNull,
      );
    });

    test('经 BookApi 接口调用返回 String?（编译期签名形状）', () async {
      final BookApi api = MockBookApi();
      final String? danmaku = await api.getVideoDanmaku(
        bookUrl: bookUrl,
        chapterIndex: 3,
      );
      expect(danmaku, isNull);
    });
  });

  group('RustApi FFI 不可用（契约 §2.49 降级不抛）', () {
    test('getVideoDanmaku 降级 null，不抛 FFI 异常', () async {
      final api = RustApi();
      expect(
        await api.getVideoDanmaku(
          bookUrl: 'https://example.com/book',
          chapterIndex: 0,
        ),
        isNull,
      );
    });
  });

  group('MockBookApi 弹幕解析（契约 §2.50）', () {
    test('mock 解析固定 null（不在 Dart 复制 XML 语义）', () async {
      final api = MockBookApi();
      expect(
        await api.parseVideoDanmaku(raw: '<i><d p="1,1,25,0">a</d></i>'),
        isNull,
      );
    });

    test('经 BookApi 接口调用返回 List<VideoDanmakuItem>?（签名形状）', () async {
      final BookApi api = MockBookApi();
      final List<VideoDanmakuItem>? items =
          await api.parseVideoDanmaku(raw: '<i/>');
      expect(items, isNull);
    });
  });

  group('RustApi FFI 不可用（契约 §2.50 降级不抛）', () {
    test('parseVideoDanmaku 降级 null，不抛 FFI 异常', () async {
      final api = RustApi();
      expect(
        await api.parseVideoDanmaku(raw: '<i><d p="1,1,25,0">a</d></i>'),
        isNull,
      );
    });
  });
}

