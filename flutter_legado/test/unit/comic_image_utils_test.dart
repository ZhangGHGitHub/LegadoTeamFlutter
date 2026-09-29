// [P4-1 C5 | 2026-09-29] comic_image_utils 全分支用例矩阵（纯单测，零行为变更）
//
// 覆盖 `lib/src/utils/comic_image_utils.dart` 的全部函数面与分支：
// - isCompositeImageUrl / stripCompositeImageUrl：`, {` 判定与剥离边界
// - looksLikeImageUrl：媒体后缀排除（m3u8/mp4/flv/mkv/webm + ?/# 边界）、
//   路径关键字排除（m3u8/ffzy-plays/ffzy-play）、图片后缀 / 路径白名单分支
// - parseComicImageUrls：正则四分支（复合 src 双/单引号、data-src/
//   data-original/data-srcset、普通双引号 src、其它 data-*/src）+ 行解析兜底
// - isImageDominantContent：空内容 / 无图 URL / 文本残留 <24 阈值边界
// - looksLikeImageBytes：JPEG/PNG/GIF/WEBP 魔数 + 短字节 / 非图片负例
//
// 历史回归组（必应漫画样例等）保留于 book_open_and_comic_url_test.dart，
// 本文件为函数级全分支矩阵（STAGE-UI-P41B · C5 Dart 侧）。

import 'package:flutter_legado/src/utils/comic_image_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isCompositeImageUrl', () {
    test('url,{json 判定为复合 URL', () {
      const url =
          r'https://cdn.example.com/a.webp,{"headers":{"Referer":"https://x/"}}';
      expect(isCompositeImageUrl(url), isTrue);
    });

    test('纯 URL 非复合', () {
      expect(isCompositeImageUrl('https://cdn.example.com/a.webp'), isFalse);
    });

    test('含逗号但非 ,{ 起始段非复合', () {
      expect(isCompositeImageUrl('https://cdn.example.com/a,1.jpg'), isFalse);
    });

    test('逗号后带空格非复合（仅严格 ,{ 判定）', () {
      expect(isCompositeImageUrl('https://cdn.example.com/a, {x}'), isFalse);
    });

    test('{ 在首位（comma==0）非复合', () {
      expect(isCompositeImageUrl(',{...}'), isFalse);
    });
  });

  group('stripCompositeImageUrl', () {
    test('复合 URL 剥离 ,{json 后缀', () {
      const url = r'https://cdn.example.com/a.webp,{"headers":{"Referer":"y"}}';
      expect(stripCompositeImageUrl(url), 'https://cdn.example.com/a.webp');
    });

    test('纯 URL 原样返回', () {
      const url = 'https://cdn.example.com/plain.png';
      expect(stripCompositeImageUrl(url), url);
    });

    test('{ 在首位时不剥离（comma==0 边界）', () {
      const url = ',{json}tail';
      expect(stripCompositeImageUrl(url), url);
    });
  });

  group('looksLikeImageUrl', () {
    test('媒体后缀排除（.m3u8/.mp4/.flv/.mkv/.webm 行尾）', () {
      for (final u in [
        'https://x/v.m3u8',
        'https://x/v.mp4',
        'https://x/v.flv',
        'https://x/v.mkv',
        'https://x/v.webm',
      ]) {
        expect(looksLikeImageUrl(u), isFalse, reason: u);
      }
    });

    test('媒体后缀带 ? 查询 / # 片段仍排除', () {
      expect(looksLikeImageUrl('https://x/img/v.mp4?token=1'), isFalse);
      expect(looksLikeImageUrl('https://x/img/v.m3u8#at5'), isFalse);
    });

    test('媒体后缀命中优先级高于 /img 路径白名单', () {
      // 路径含 /img 但后缀是流媒体 → 仍排除
      expect(looksLikeImageUrl('https://x/img/v.mp4'), isFalse);
    });

    test('路径含 m3u8 / ffzy-plays / ffzy-play 关键字排除', () {
      expect(looksLikeImageUrl('https://x/m3u8/file'), isFalse);
      expect(
        looksLikeImageUrl('https://vip.ffzy-plays.com/x/index.m3u8'),
        isFalse,
      );
      expect(looksLikeImageUrl('https://ffzy-play.example/x'), isFalse);
    });

    test('六种图片后缀识别（含大小写不敏感）', () {
      for (final u in [
        'https://x/a.jpg',
        'https://x/a.jpeg',
        'https://x/a.png',
        'https://x/a.gif',
        'https://x/a.webp',
        'https://x/a.bmp',
        'https://x/a.JPG',
      ]) {
        expect(looksLikeImageUrl(u), isTrue, reason: u);
      }
    });

    test('路径白名单 /image /img /pic（无后缀也识别）', () {
      expect(looksLikeImageUrl('https://x/image/71'), isTrue);
      expect(looksLikeImageUrl('https://x/IMG/71'), isTrue);
      expect(looksLikeImageUrl('https://x/pics/71'), isTrue);
    });

    test('非图片非白名单 → 否', () {
      expect(looksLikeImageUrl('https://x/photo/file'), isFalse);
      expect(looksLikeImageUrl('https://x/video/file'), isFalse);
    });

    test('复合 URL 先剥 ,{json 再判后缀', () {
      expect(
        looksLikeImageUrl(
          r'https://x/img/a.webp,{"headers":{"Referer":"https://x/"}}',
        ),
        isTrue,
      );
      expect(
        looksLikeImageUrl(
          r'https://x/v.mp4,{"headers":{"Referer":"https://x/"}}',
        ),
        isFalse,
      );
    });
  });

  group('parseComicImageUrls 正则分支', () {
    test('复合 src 双引号（JSON 内嵌双引号完整抽出，不截断）', () {
      const html =
          r'''<img src="https://cdn.example.com/a.webp,{"headers":{"Referer":"https://site.com/"}}">''';
      expect(parseComicImageUrls(html), [
        r'https://cdn.example.com/a.webp,{"headers":{"Referer":"https://site.com/"}}',
      ]);
    });

    test('复合 src 单引号', () {
      const html =
          r'''<img src='https://cdn.example.com/b.jpg,{"headers":{"User-Agent":"X"}}'>''';
      expect(parseComicImageUrls(html), [
        r'https://cdn.example.com/b.jpg,{"headers":{"User-Agent":"X"}}',
      ]);
    });

    test('data-src / data-original / data-srcset 分支', () {
      for (final attr in ['data-src', 'data-original', 'data-srcset']) {
        final html =
            '<img $attr="https://cdn.example.com/c.png" alt="1">';
        expect(parseComicImageUrls(html), ['https://cdn.example.com/c.png'],
            reason: attr);
      }
    });

    test('普通双引号 src 分支', () {
      const html = '<img src="https://cdn.example.com/d.gif">';
      expect(parseComicImageUrls(html), ['https://cdn.example.com/d.gif']);
    });

    test('其它 data-* / 单引号 src 兜底分支', () {
      expect(
        parseComicImageUrls("<img data-lazy-src='https://cdn.example.com/e.bmp'>"),
        ['https://cdn.example.com/e.bmp'],
      );
      expect(
        parseComicImageUrls("<img src='https://cdn.example.com/f.png'>"),
        ['https://cdn.example.com/f.png'],
      );
    });

    test('多图混合各分支各取其一', () {
      const html = '''
<img src="https://cdn.example.com/1.webp">
<img data-src="https://cdn.example.com/2.webp">
<img data-original='https://cdn.example.com/3.png'>
''';
      expect(parseComicImageUrls(html), [
        'https://cdn.example.com/1.webp',
        'https://cdn.example.com/2.webp',
        'https://cdn.example.com/3.png',
      ]);
    });
  });

  group('parseComicImageUrls 行解析兜底', () {
    test('纯 URL 行（图片后缀）逐行收集', () {
      const content = '''
https://cdn.example.com/a/1.webp
https://cdn.example.com/a/2.webp
''';
      expect(parseComicImageUrls(content), [
        'https://cdn.example.com/a/1.webp',
        'https://cdn.example.com/a/2.webp',
      ]);
    });

    test('非 http 行 / 非图片行被跳过', () {
      const content = '''
/chapter/1
https://cdn.example.com/page/index.html
https://cdn.example.com/video/index.mp4
https://cdn.example.com/pic/9.jpg
''';
      expect(parseComicImageUrls(content), [
        'https://cdn.example.com/pic/9.jpg',
      ]);
    });

    test('复合 URL 行兜底识别', () {
      const line =
          r'https://cdn.example.com/pic/1.webp,{"headers":{"Referer":"https://x/"}}';
      expect(parseComicImageUrls(line), [line]);
    });

    test('HTML 命中正则时不走行兜底（正则结果优先）', () {
      const html = '''
<img src="https://cdn.example.com/a/1.webp">
https://cdn.example.com/b/2.webp
''';
      // 正则命中 → 行兜底不生效，纯 URL 行不混入
      expect(parseComicImageUrls(html), ['https://cdn.example.com/a/1.webp']);
    });

    test('空内容返回空列表', () {
      expect(parseComicImageUrls(''), isEmpty);
    });
  });

  group('isImageDominantContent', () {
    test('空 / 纯空白内容 → 否', () {
      expect(isImageDominantContent(''), isFalse);
      expect(isImageDominantContent('   \n  '), isFalse);
    });

    test('无图片 URL 的短文本 → 否', () {
      expect(isImageDominantContent('short'), isFalse);
    });

    test('纯 img HTML（几乎无文本）→ 是', () {
      const html = '''
<img src="https://cdn.example.com/a/1.webp">
<img src="https://cdn.example.com/a/2.webp">
''';
      expect(isImageDominantContent(html), isTrue);
    });

    test('图文混排（实质段落）→ 否', () {
      const html =
          '<p>这是一段足够长的小说正文，用来避免被误判成纯图片章节。</p><img src="https://cdn.example.com/a.jpg">';
      expect(isImageDominantContent(html), isFalse);
    });

    test('文本残留 23 字符（<24 阈值内）→ 是；24 字符 → 否', () {
      final img = '<img src="https://cdn.example.com/a.jpg">\n';
      final text23 = 'a' * 23;
      final text24 = 'a' * 24;
      expect(isImageDominantContent('$text23\n$img'), isTrue);
      expect(isImageDominantContent('$text24\n$img'), isFalse);
    });

    test('纯图片 URL 行（无 HTML 标签）：残留计入阈值，短内容主导、长内容否', () {
      // 实现事实：textOnly 只剥离 <tag> 与空白，URL 行本身计入 24 字符残留阈值。
      // 单行短 URL（残留 14 < 24）→ 是；两行（残留 28 ≥ 24）→ 否。
      expect(isImageDominantContent('http://a/1.jpg'), isTrue);
      const content = '''
http://a/1.jpg
http://a/2.jpg
''';
      expect(isImageDominantContent(content), isFalse);
    });
  });

  group('looksLikeImageBytes 魔数', () {
    test('JPEG/PNG/GIF/WEBP 魔数识别', () {
      expect(looksLikeImageBytes([0xFF, 0xD8, 0xFF, 0xE0]), isTrue);
      expect(looksLikeImageBytes([0x89, 0x50, 0x4E, 0x47]), isTrue);
      expect(looksLikeImageBytes([0x47, 0x49, 0x46, 0x38]), isTrue);
      expect(
        looksLikeImageBytes([
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
        ]),
        isTrue,
      );
    });

    test('不足 4 字节 → 否', () {
      expect(looksLikeImageBytes([]), isFalse);
      expect(looksLikeImageBytes([0xFF, 0xD8, 0xFF]), isFalse);
    });

    test('非图片魔数（密文/文本）→ 否', () {
      expect(looksLikeImageBytes([0x01, 0x02, 0x03, 0x04]), isFalse);
      expect(looksLikeImageBytes([0x7F, 0x45, 0x4C, 0x46]), isFalse);
    });

    test('WEBP 需 RIFF@0 且 WEBP@8（12 字节对齐）', () {
      // RIFF 头但 8-11 不是 WEBP → 否
      expect(
        looksLikeImageBytes([
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x00,
        ]),
        isFalse,
      );
      // 仅 11 字节（长度不足 12）→ 否
      expect(
        looksLikeImageBytes([
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42,
        ]),
        isFalse,
      );
    });
  });
}
