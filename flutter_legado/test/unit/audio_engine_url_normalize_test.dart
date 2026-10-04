// P0 缺陷回归：朗读引擎 URL 归一（2026-10-03）
//
// 背景：朗读条引擎选择器曾把 '名称,URL' 复合串写入 TtsConfig.engineUrl，
// 而 Rust tts_speak 把 engineUrl 原样当 URL 模板与缓存键
// （rust/legado-ffi/src/api/tts_speak_api.rs:57-59）→ 选完引擎合成必失败。
// 修复：选择器只存裸 URL；消费端（audioSpeak 前）对历史复合形态归一。
//
// 本文件钉住：
// 1) normalizeTtsEngineUrl：裸 URL 无损、「名称,URL」还原、名称含逗号仍正确、
//    非 http(s) 形态不做猜测性截断；
// 2) AudioNotifier 合成链路确实把归一后的裸 URL 传给 audioSpeak（mock 断言）。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  group('normalizeTtsEngineUrl（历史「名称,URL」→ 裸 URL）', () {
    test('裸 URL 原样返回（首尾空白裁剪）', () {
      const bare = 'http://192.168.1.2:8770/tts?text={{text}}';
      expect(normalizeTtsEngineUrl(bare), bare);
      expect(
        normalizeTtsEngineUrl('  https://tts.example.com/api?text={{speakText}}  '),
        'https://tts.example.com/api?text={{speakText}}',
      );
      expect(normalizeTtsEngineUrl(''), isEmpty);
    });

    test('「名称,URL」复合形态取 URL 部分', () {
      expect(
        normalizeTtsEngineUrl('本地引擎,http://192.168.1.2:8770/tts?text={{text}}'),
        'http://192.168.1.2:8770/tts?text={{text}}',
      );
      expect(
        normalizeTtsEngineUrl('1.百度,https://tts.example.com/{{speakText}}'),
        'https://tts.example.com/{{speakText}}',
      );
      // 逗号后带空格
      expect(
        normalizeTtsEngineUrl('本地引擎 , http://host/tts'),
        'http://host/tts',
      );
    });

    test('名称含逗号：仍取到真正的 URL 起点（不是首个逗号后的名称残段）', () {
      expect(
        normalizeTtsEngineUrl('我的,引擎,http://host/tts?text={{text}}'),
        'http://host/tts?text={{text}}',
      );
    });

    test('URL 自身含逗号：整串以 http(s) 开头，不拆', () {
      const url = 'http://host/tts?text={{text}}&style=1,2';
      expect(normalizeTtsEngineUrl(url), url);
    });

    test('逗号后不是 http(s)：不做猜测性截断', () {
      // 原版 POST 模板（本就不是可用形态）：保持原样交由管线报错
      const post = 'http://tts.baidu.com/text2audio,{"method":"POST"}';
      expect(normalizeTtsEngineUrl(post), post);
      const noUrl = '引擎,{json}';
      expect(normalizeTtsEngineUrl(noUrl), noUrl);
    });
  });

  group('AudioNotifier 合成消费端归一（audioSpeak 收到裸 URL）', () {
    late MockRustApi mockApi;
    late FakeStreamAudioPlayer fakePlayer;
    late ProviderContainer container;

    /// audioSpeak 收到的 engineUrl（按调用序）
    final receivedEngineUrls = <String>[];

    setUp(() {
      mockApi = MockRustApi();
      fakePlayer = FakeStreamAudioPlayer();
      receivedEngineUrls.clear();
      container = ProviderContainer(
        overrides: [
          bookApiProvider.overrideWithValue(mockApi),
          streamAudioPlayerProvider.overrideWithValue(fakePlayer),
        ],
      );
      addTearDown(container.dispose);

      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [const BookChapter(title: '第一章', index: 0)],
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(() => mockApi.getChapterContentFull(any(), any()))
          .thenAnswer((_) async => '正文内容。');
      when(() => mockApi.audioSpeak(
            text: any(named: 'text'),
            engineUrl: any(named: 'engineUrl'),
            speed: any(named: 'speed'),
            pitch: any(named: 'pitch'),
            volume: any(named: 'volume'),
            voiceName: any(named: 'voiceName'),
          )).thenAnswer((invocation) async {
        receivedEngineUrls
            .add(invocation.namedArguments[#engineUrl] as String);
        return '/tmp/tts/para.mp3';
      });
    });

    Future<void> speakWith(String storedEngineUrl) async {
      final notifier = container.read(audioNotifierProvider.notifier);
      await notifier.loadChapters('url');
      notifier.updateConfig(engineUrl: storedEngineUrl);
      await notifier.play();
    }

    testWidgets('存量「名称,http://…」→ audioSpeak 收到裸 URL', (tester) async {
      await speakWith('本地引擎,http://192.168.1.2:8770/tts?text={{text}}');

      expect(receivedEngineUrls, ['http://192.168.1.2:8770/tts?text={{text}}']);
      expect(fakePlayer.playedLocalFiles, hasLength(1));
      final state = container.read(audioNotifierProvider);
      expect(state.errorMessage, isNull);
    });

    testWidgets('名称含逗号的存量复合串同样归一（取真正 URL 起点）', (tester) async {
      await speakWith('我的,引擎,http://host/tts?text={{text}}');

      expect(receivedEngineUrls, ['http://host/tts?text={{text}}']);
      expect(fakePlayer.playedLocalFiles, hasLength(1));
    });

    testWidgets('裸 URL（新选择器形态）原样传给 audioSpeak', (tester) async {
      await speakWith('https://tts.example.com/api?text={{speakText}}');

      expect(
        receivedEngineUrls,
        ['https://tts.example.com/api?text={{speakText}}'],
      );
    });
  });
}
