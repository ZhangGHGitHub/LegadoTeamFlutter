import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/utils/url_utils.dart';

void main() {
  group('resolveAbsoluteUrl 视频相对路径', () {
    test('绝对 URL 原样返回', () {
      expect(
        resolveAbsoluteUrl(
          'https://site.com/play/1.html',
          'https://cdn.com/v.mp4',
        ),
        'https://cdn.com/v.mp4',
      );
    });

    test('协议相对 // 补 https', () {
      expect(
        resolveAbsoluteUrl(
          'https://site.com/play/1.html',
          '//cdn.com/v.mp4',
        ),
        'https://cdn.com/v.mp4',
      );
    });

    test('根路径相对以章节 host 为 base', () {
      expect(
        resolveAbsoluteUrl(
          'https://site.com/play/ep1.html',
          '/videos/ep1.mp4',
        ),
        'https://site.com/videos/ep1.mp4',
      );
    });

    test('同目录相对路径', () {
      expect(
        resolveAbsoluteUrl(
          'https://site.com/play/ep1.html',
          'ep1.mp4',
        ),
        'https://site.com/play/ep1.mp4',
      );
    });
  });
}
