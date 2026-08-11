import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/utils/video_play_utils.dart';

void main() {
  group('prepareVideoContent / isMpdVideoContent', () {
    test('MPD 以 < 开头原样保留', () {
      const mpd = '  <MPD xmlns="urn:mpeg:dash:schema:mpd:2011">...</MPD>  ';
      expect(isMpdVideoContent(mpd), isTrue);
      expect(prepareVideoContent(mpd), mpd.trim());
    });

    test('多行正文只取首个非空行（防 subContent 污染）', () {
      const raw = 'https://cdn.example/a.m3u8\n{"danmaku":[]}\n';
      expect(prepareVideoContent(raw), 'https://cdn.example/a.m3u8');
    });
  });

  group('extractVideoUrl', () {
    test('复合 URL 保留 JSON 后缀', () {
      const raw =
          'https://cdn.example/v.mp4,{"headers":{"Referer":"https://site.com"}}';
      expect(extractVideoUrl(raw), raw);
    });

    test('iframe src 提取', () {
      expect(
        extractVideoUrl('<iframe src="https://cdn.example/embed"></iframe>'),
        'https://cdn.example/embed',
      );
    });
  });

  group('splitUrlOption / mergeVideoHeaders', () {
    test('解析 UrlOption headers', () {
      final split = splitUrlOption(
        'https://cdn.example/v.mp4,{"headers":{"Referer":"https://a.com","User-Agent":"UA"}}',
      );
      expect(split.url, 'https://cdn.example/v.mp4');
      expect(split.headers['Referer'], 'https://a.com');
      expect(split.headers['User-Agent'], 'UA');
    });

    test('合并书源 header 与 UrlOption，补默认 UA', () {
      final h = mergeVideoHeaders(
        sourceHeaders: {'Cookie': 'a=1'},
        optionHeaders: {'Referer': 'https://site.com'},
        referer: 'https://fallback.com',
      );
      expect(h['Cookie'], 'a=1');
      expect(h['Referer'], 'https://site.com');
      expect(h['User-Agent'], kDefaultVideoUserAgent);
    });
  });

  group('findPlayableChapterIndex', () {
    test('跳过卷标题选下一集', () {
      expect(findPlayableChapterIndex([true, true, false, false], 0), 2);
      expect(findPlayableChapterIndex([false, true, false], 1), 2);
      expect(findPlayableChapterIndex([true, true], 0), 0);
    });
  });

  group('resolveVideoPlayTarget', () {
    test('相对路径绝对化 + 书源 Referer', () {
      final t = resolveVideoPlayTarget(
        content: '/videos/ep1.mp4',
        chapterUrl: 'https://site.com/play/ep1.html',
        sourceHeaders: const {},
      );
      expect(t.url, 'https://site.com/videos/ep1.mp4');
      expect(t.isMpd, isFalse);
      expect(t.headers['Referer'], 'https://site.com/play/ep1.html');
      expect(t.headers['User-Agent'], isNotEmpty);
    });

    test('复合 URL 拆出 header', () {
      final t = resolveVideoPlayTarget(
        content:
            'https://cdn.example/v.mp4,{"headers":{"Referer":"https://gate.com"}}',
        chapterUrl: 'https://site.com/c.html',
      );
      expect(t.url, 'https://cdn.example/v.mp4');
      expect(t.headers['Referer'], 'https://gate.com');
    });

    test('MPD 正文不走 URL 提取', () {
      const mpd = '<MPD><Period></Period></MPD>';
      final t = resolveVideoPlayTarget(
        content: mpd,
        chapterUrl: 'https://site.com/c.html',
      );
      expect(t.isMpd, isTrue);
      expect(t.mpdContent, mpd);
      expect(t.url, isEmpty);
    });

    test('副内容污染行被剥掉后仍能解析直链', () {
      final t = resolveVideoPlayTarget(
        content: 'https://cdn.example/v.m3u8\n[danmaku junk]',
        chapterUrl: 'https://site.com/c.html',
      );
      expect(t.url, 'https://cdn.example/v.m3u8');
    });
  });

  group('parseSourceHeaderMap', () {
    test('JSON header', () {
      final m = parseSourceHeaderMap('{"Referer":"https://a.com","UA":"x"}');
      expect(m['Referer'], 'https://a.com');
      expect(m['UA'], 'x');
    });

    test('行格式 header', () {
      final m = parseSourceHeaderMap('Referer: https://a.com\nUser-Agent: y');
      expect(m['Referer'], 'https://a.com');
      expect(m['User-Agent'], 'y');
    });
  });
}
