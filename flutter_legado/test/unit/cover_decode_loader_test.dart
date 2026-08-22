import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/book_source.dart';
import 'package:flutter_legado/src/services/cover_decode_loader.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 最小 JPEG（1×1）供缓存/魔数校验
Uint8List _tinyJpeg() => Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
      0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
      0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
      0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
      0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
      0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
      0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
      0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
      0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x14, 0x00, 0x01,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x08, 0xFF, 0xC4, 0x00, 0x14, 0x10, 0x01, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
      0x7F, 0xFF, 0xD9,
    ]);

/// 可控延迟的 fetchImageWithDecode Mock
class _SlowDecodeApi extends MockBookApi {
  _SlowDecodeApi({this.delay = const Duration(milliseconds: 80)});

  final Duration delay;
  int fetchCount = 0;
  int peakConcurrent = 0;
  int _inflight = 0;

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async {
    fetchCount++;
    _inflight++;
    if (_inflight > peakConcurrent) peakConcurrent = _inflight;
    await Future<void>.delayed(delay);
    _inflight--;
    final b64 = base64Encode(_tinyJpeg());
    return jsonEncode({'base64': b64, 'len': _tinyJpeg().length});
  }
}

void main() {
  setUp(CoverDecodeLoader.clearForTest);
  tearDown(CoverDecodeLoader.clearForTest);

  group('CoverDecodeLoader.patchSourceJsonForCoverDecode', () {
    test('无 coverDecodeJs → 空串（直连）', () {
      final patched = CoverDecodeLoader.patchSourceJsonForCoverDecode(
        jsonEncode({'bookSourceUrl': 'https://a', 'coverDecodeJs': ''}),
      );
      expect(patched, '');
    });

    test('有 coverDecodeJs → 映射到 ruleContent.imageDecode', () {
      final patched = CoverDecodeLoader.patchSourceJsonForCoverDecode(
        jsonEncode({
          'bookSourceUrl': 'https://a',
          'coverDecodeJs': 'java.aes()',
          'ruleContent': <String, dynamic>{},
        }),
      );
      expect(patched, isNotNull);
      expect(patched, isNotEmpty);
      final map = jsonDecode(patched!) as Map<String, dynamic>;
      expect(
        (map['ruleContent'] as Map)['imageDecode'],
        'java.aes()',
      );
    });
  });

  group('CoverDecodeLoader 缓存与并发', () {
    test('needsFfiDecode：空 patch 且非复合 → false', () {
      expect(
        CoverDecodeLoader.needsFfiDecode(
          coverUrl: 'https://cdn/a.jpg',
          patchedSourceJson: '',
        ),
        isFalse,
      );
    });

    test('needsFfiDecode：有 patch → true', () {
      expect(
        CoverDecodeLoader.needsFfiDecode(
          coverUrl: 'https://cdn/a.jpg',
          patchedSourceJson: '{"ruleContent":{}}',
        ),
        isTrue,
      );
    });

    test('LRU 命中不重复打 FFI', () async {
      final api = _SlowDecodeApi(delay: Duration.zero);
      final bytes = await CoverDecodeLoader.load(
        api: api,
        coverUrl: 'https://cdn/1.jpg',
        patchedSourceJson: '{"x":1}',
        originOrEmpty: 'https://src',
        isCancelled: () => false,
      );
      expect(bytes, isNotNull);
      expect(api.fetchCount, 1);

      final hit = await CoverDecodeLoader.load(
        api: api,
        coverUrl: 'https://cdn/1.jpg',
        patchedSourceJson: '{"x":1}',
        originOrEmpty: 'https://src',
        isCancelled: () => false,
      );
      expect(hit, isNotNull);
      expect(api.fetchCount, 1);
      expect(CoverDecodeLoader.debugCacheSize, 1);
    });

    test('并发上限不超过 maxConcurrent', () async {
      final api = _SlowDecodeApi(delay: const Duration(milliseconds: 60));
      final futures = <Future<Uint8List?>>[];
      for (var i = 0; i < 10; i++) {
        futures.add(CoverDecodeLoader.load(
          api: api,
          coverUrl: 'https://cdn/$i.jpg',
          patchedSourceJson: '{"x":1}',
          originOrEmpty: 'https://src',
          isCancelled: () => false,
        ));
      }
      // 启动后短暂观察：排队应 >0，活跃 ≤ maxConcurrent
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        CoverDecodeLoader.debugActiveCount,
        lessThanOrEqualTo(CoverDecodeLoader.maxConcurrent),
      );
      expect(CoverDecodeLoader.debugQueueLength, greaterThan(0));

      await Future.wait(futures);
      expect(api.peakConcurrent, lessThanOrEqualTo(CoverDecodeLoader.maxConcurrent));
      expect(api.fetchCount, 10);
    });

    test('取消排队票证后不进入 FFI', () async {
      final api = _SlowDecodeApi(delay: const Duration(milliseconds: 100));
      // 占满并发槽
      final blockers = <Future<Uint8List?>>[];
      for (var i = 0; i < CoverDecodeLoader.maxConcurrent; i++) {
        blockers.add(CoverDecodeLoader.load(
          api: api,
          coverUrl: 'https://cdn/block$i.jpg',
          patchedSourceJson: '{"x":1}',
          originOrEmpty: 'https://src',
          isCancelled: () => false,
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));

      CoverDecodeTicket? ticket;
      final cancelled = CoverDecodeLoader.load(
        api: api,
        coverUrl: 'https://cdn/cancel-me.jpg',
        patchedSourceJson: '{"x":1}',
        originOrEmpty: 'https://src',
        isCancelled: () => ticket?.isCancelled == true,
        onTicket: (t) => ticket = t,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(ticket, isNotNull);
      ticket!.cancel();

      final result = await cancelled;
      expect(result, isNull);

      await Future.wait(blockers);
      // 被取消的那条不应发起 fetch（fetchCount == 占满槽的数量）
      expect(api.fetchCount, CoverDecodeLoader.maxConcurrent);
    });

    test('origin 书源解析缓存：第二次不调 getBookSources', () async {
      final api = _CountingSourcesApi();
      final a = await CoverDecodeLoader.resolvePatchedSourceJson(
        api: api,
        sourceOrigin: 'https://missing-origin',
      );
      expect(a, '');
      expect(api.getSourcesCount, 1);

      final b = await CoverDecodeLoader.resolvePatchedSourceJson(
        api: api,
        sourceOrigin: 'https://missing-origin',
      );
      expect(b, '');
      expect(api.getSourcesCount, 1);
    });
  });
}

class _CountingSourcesApi extends MockBookApi {
  int getSourcesCount = 0;

  @override
  Future<List<BookSource>> getBookSources() async {
    getSourcesCount++;
    return super.getBookSources();
  }
}
