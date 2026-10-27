// RSS 图片 data: URI 解码单测（批15g③）
//
// 对齐原版 `ReadRssViewModel.webData2bitmap`（`ReadRssViewModel.kt:248-256`）：
// 图片地址不是合法 URL 时按 base64 data URI 解码，不走网络下载。
// 覆盖：解码、MIME→扩展名、非法/超长输入的明确错误（不崩溃）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/image_data_uri.dart';

/// 1x1 透明 PNG（68 字节，PNG 魔数合法）
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  group('isDataUri', () {
    test('识别 data: 前缀（大小写/前导空白不敏感）', () {
      expect(isDataUri('data:image/png;base64,AAAA'), isTrue);
      expect(isDataUri('  DATA:image/jpeg;base64,AAAA'), isTrue);
      expect(isDataUri('\tDaTa:image/jpeg;base64,AAAA'), isTrue);
    });

    test('普通 URL/本地路径/空串/前缀不足不算 data URI', () {
      expect(isDataUri('https://s.test/a.png'), isFalse);
      expect(isDataUri('file:///tmp/a.png'), isFalse);
      expect(isDataUri(''), isFalse);
      expect(isDataUri('data'), isFalse);
      expect(isDataUri('dat'), isFalse);
    });

    test('超长正文只比较前缀（不因正文内容误判）', () {
      final huge = 'data:image/png;base64,${'A' * (1024 * 1024)}';
      expect(isDataUri(huge), isTrue);
      expect(isDataUri('x$huge'), isFalse);
    });
  });

  group('parseImageDataUri', () {
    test('合法 PNG：解码字节、MIME 与扩展名', () {
      final image = parseImageDataUri('data:image/png;base64,$_pngBase64');

      expect(image, isNotNull);
      expect(image!.mimeType, 'image/png');
      expect(image.extension, '.png');
      expect(image.bytes, base64Decode(_pngBase64));
      expect(image.bytes.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
    });

    test('非 data: URI 返回 null（调用方继续网络/本地路径）', () {
      expect(parseImageDataUri('https://s.test/a.png'), isNull);
    });

    test('base64 正文中的空白/换行被剥离', () {
      final wrapped = _pngBase64.replaceAllMapped(
        RegExp(r'.{20}'),
        (m) => '${m[0]}\n',
      );
      final image = parseImageDataUri(
        'data:image/png;base64,$wrapped',
      );
      expect(image!.bytes, base64Decode(_pngBase64));
    });

    test('MIME 参数（charset）不影响解析', () {
      final image = parseImageDataUri(
        'data:image/jpeg;charset=utf-8;base64,$_pngBase64',
      );
      expect(image!.mimeType, 'image/jpeg');
      expect(image.extension, '.jpg');
    });

    test('缺少逗号分隔符 → 明确错误', () {
      expect(
        () => parseImageDataUri('data:image/png;base64'),
        throwsA(
          isA<ImageDataUriException>().having(
            (e) => e.message,
            'message',
            contains('逗号'),
          ),
        ),
      );
    });

    test('非图片 MIME → 明确错误', () {
      expect(
        () => parseImageDataUri('data:text/html;base64,AAAA'),
        throwsA(
          isA<ImageDataUriException>().having(
            (e) => e.message,
            'message',
            contains('不是图片类型'),
          ),
        ),
      );
    });

    test('未声明 MIME → 明确错误', () {
      expect(
        () => parseImageDataUri('data:;base64,AAAA'),
        throwsA(
          isA<ImageDataUriException>().having(
            (e) => e.message,
            'message',
            contains('未声明图片类型'),
          ),
        ),
      );
    });

    test('缺少 base64 标记 → 明确错误', () {
      expect(
        () => parseImageDataUri('data:image/png,AAAA'),
        throwsA(
          isA<ImageDataUriException>().having(
            (e) => e.message,
            'message',
            contains('base64'),
          ),
        ),
      );
    });

    test('空正文 → 明确错误', () {
      expect(
        () => parseImageDataUri('data:image/png;base64,   '),
        throwsA(
          isA<ImageDataUriException>().having(
            (e) => e.message,
            'message',
            contains('为空'),
          ),
        ),
      );
    });

    test('非法 base64 → 明确错误（不抛底层 FormatException）', () {
      expect(
        () => parseImageDataUri('data:image/png;base64,@@@not-base64@@@'),
        throwsA(
          isA<ImageDataUriException>().having(
            (e) => e.message,
            'message',
            contains('base64 数据无效'),
          ),
        ),
      );
    });

    test('超过字节上限 → 明确错误', () {
      // maxBytes=2：4 个 base64 字符解出 3 字节，已超限
      expect(
        () => parseImageDataUri(
          'data:image/png;base64,AAAA',
          maxBytes: 2,
        ),
        throwsA(
          isA<ImageDataUriException>().having(
            (e) => e.message,
            'message',
            contains('图片数据过大'),
          ),
        ),
      );
    });

    test('编码文本超过长度上限 → 明确错误', () {
      // maxBytes=3 → 编码上限 8 字符；12 个字符先被长度检查拦下
      expect(
        () => parseImageDataUri(
          'data:image/png;base64,AAAAAAAAAAAA',
          maxBytes: 3,
        ),
        throwsA(
          isA<ImageDataUriException>().having(
            (e) => e.message,
            'message',
            contains('图片数据过大'),
          ),
        ),
      );
    });

    test('超长输入在解码前被拦截（非法 base64 也报「数据过大」）', () {
      // 批19 审查 P3-1：9 个 '@' 既超编码上限（8）又不是合法 base64。
      // 若先解码应报「base64 数据无效」；报「数据过大」证明预检先于解码。
      expect(
        () => parseImageDataUri(
          'data:image/png;base64,@@@@@@@@@',
          maxBytes: 3,
        ),
        throwsA(
          isA<ImageDataUriException>().having(
            (e) => e.message,
            'message',
            contains('图片数据过大'),
          ),
        ),
      );
    });

    test('整串长度粗判先于任何拷贝（超大输入直接拒绝）', () {
      // 批19 审查 P2-2：maxBytes=3 时粗判上限约 528 字符；
      // 600 个非法字符若进入 trim/substring/解码会报 base64 无效。
      final huge = 'data:image/png;base64,${'@' * 600}';
      expect(
        () => parseImageDataUri(huge, maxBytes: 3),
        throwsA(
          isA<ImageDataUriException>().having(
            (e) => e.message,
            'message',
            contains('图片数据过大'),
          ),
        ),
      );
    });

    test('非空白字符精确预检：空白不放大体积判定', () {
      // 9 个非空白字符（夹空格）超过 maxBytes=3 的编码上限 8；
      // 长度远低于粗判上限，必须在 substring/解码前按非空白计数拒绝。
      expect(
        () => parseImageDataUri(
          'data:image/png;base64,${'@ ' * 9}',
          maxBytes: 3,
        ),
        throwsA(
          isA<ImageDataUriException>().having(
            (e) => e.message,
            'message',
            contains('图片数据过大'),
          ),
        ),
      );
    });
  });

  group('imageExtensionForMime', () {
    test('常见图片 MIME 映射', () {
      expect(imageExtensionForMime('image/jpeg'), '.jpg');
      expect(imageExtensionForMime('image/jpg'), '.jpg');
      expect(imageExtensionForMime('image/png'), '.png');
      expect(imageExtensionForMime('image/gif'), '.gif');
      expect(imageExtensionForMime('image/webp'), '.webp');
      expect(imageExtensionForMime('image/bmp'), '.bmp');
      expect(imageExtensionForMime('image/svg+xml'), '.svg');
      expect(imageExtensionForMime('image/avif'), '.avif');
    });

    test('大小写/空白不敏感；未知 image 子类型回落 .jpg', () {
      expect(imageExtensionForMime(' IMAGE/PNG '), '.png');
      expect(imageExtensionForMime('image/x-weird'), '.jpg');
      expect(imageExtensionForMime(''), '.jpg');
    });
  });
}
