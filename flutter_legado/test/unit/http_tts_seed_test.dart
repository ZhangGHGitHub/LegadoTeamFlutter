// D3 缺陷回归：Flutter 轨 httpTTS 种子导入与可用性如实登记。
//
// 背景（QA 证据 .tmp/tts_qa/device_legado.db / screen_12_ttsconfig.png）：
// dict/rss/txtToc 均有种子导入器，httpTTS 缺失 → 首启引擎表为空。
// 种子内容（app/src/main/assets/defaultData/httpTTS.json）依赖原版
// AnalyzeUrl 的 POST/@js/loginUrl 能力，当前 Rust 合成管线（GET + 占位符）
// 不支持（QA 实测种子「1.百度」无参数返回错误 JSON）。
//
// 本文件钉住修复契约：
// 1. 种子资产存在且非空（确实存在才导入）；
// 2. syncDefaultHttpTts 只导入 name/url 非空条目、幂等、失败不抛；
// 3. 导入即置 isEnabled=false（失效引擎不当可用）；
// 4. ensureDefaultHttpTts 版本门控；
// 5. 自动选默认引擎跳过不兼容模板，只接受 GET+文本占位符。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/audio/http_tts_seed.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

/// 原版种子「1.百度」URL（POST/JS 形态，Rust 管线不支持）
const _seedBaiduUrl =
    'http://tts.baidu.com/text2audio,{"method": "POST","body": "tex=...&aue=6"}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(registerFallbacks);

  group('种子资产（确实存在且不为空）', () {
    test('assets/default_data/httpTTS.json 存在且每个条目 name/url 非空', () {
      final file = File(kDefaultHttpTtsAsset);
      expect(file.existsSync(), isTrue, reason: '种子资源必须随 Flutter 轨打包');
      final text = file.readAsStringSync().trim();
      expect(text, isNotEmpty);

      final list = jsonDecode(text) as List<dynamic>;
      expect(list, isNotEmpty, reason: '种子为空则不应导入');
      for (final item in list.whereType<Map<String, dynamic>>()) {
        expect((item['name'] as String?)?.trim(), isNotEmpty);
        expect((item['url'] as String?)?.trim(), isNotEmpty);
      }
    });
  });

  group('syncDefaultHttpTts 导入', () {
    late MockRustApi api;
    late List<HttpTts> added;
    late List<({int id, bool enabled})> enableCalls;
    var nextId = 100;

    setUp(() {
      api = MockRustApi();
      added = [];
      enableCalls = [];
      nextId = 100;
      when(() => api.getHttpTts()).thenAnswer((_) async => []);
      when(() => api.addHttpTts(any())).thenAnswer((invocation) async {
        final tts = invocation.positionalArguments[0] as HttpTts;
        added.add(tts);
        return tts.copyWith(id: nextId++);
      });
      when(() => api.httpTtsSetEnabled(any(), any()))
          .thenAnswer((invocation) async {
        enableCalls.add((
          id: invocation.positionalArguments[0] as int,
          enabled: invocation.positionalArguments[1] as bool,
        ));
        return true;
      });
    });

    test('非空种子：导入 name/url 并置 isEnabled=false（如实登记不可用）', () async {
      final json = jsonEncode([
        {
          'id': -100,
          'name': '1.百度',
          'url': _seedBaiduUrl,
          'contentType': 'audio/wav',
        },
        {
          'id': -29,
          'name': '2.阿里云语音',
          'url': 'https://nls.example.com/tts',
          'loginUrl': 'function login(){}',
        },
      ]);

      final count = await syncDefaultHttpTts(api, jsonOverride: json);

      expect(count, 2);
      expect(added.map((e) => e.name), ['1.百度', '2.阿里云语音']);
      expect(added.first.url, _seedBaiduUrl);
      expect(enableCalls, [
        (id: 100, enabled: false),
        (id: 101, enabled: false),
      ]);
    });

    test('空种子 / 空串 / 非法 JSON：返回 0 且不写库、不抛出', () async {
      expect(await syncDefaultHttpTts(api, jsonOverride: ''), 0);
      expect(await syncDefaultHttpTts(api, jsonOverride: '   '), 0);
      expect(await syncDefaultHttpTts(api, jsonOverride: '[]'), 0);
      expect(await syncDefaultHttpTts(api, jsonOverride: 'not-json'), 0);
      expect(await syncDefaultHttpTts(api, jsonOverride: '{"a":1}'), 0);
      verifyNever(() => api.addHttpTts(any()));
    });

    test('缺 name/url 的条目被过滤', () async {
      const json = '''
      [
        {"id": 1, "name": "", "url": "http://a"},
        {"id": 2, "name": "B", "url": ""},
        {"id": 3, "name": "C", "url": "http://c"}
      ]
      ''';

      final count = await syncDefaultHttpTts(api, jsonOverride: json);

      expect(count, 1);
      expect(added.single.name, 'C');
    });

    test('幂等：库中已有同名同 URL 时跳过', () async {
      when(() => api.getHttpTts()).thenAnswer(
        (_) async => [HttpTts(name: '1.百度', url: _seedBaiduUrl)],
      );
      final json = jsonEncode([
        {'id': -100, 'name': '1.百度', 'url': _seedBaiduUrl},
      ]);

      final count = await syncDefaultHttpTts(api, jsonOverride: json);

      expect(count, 0);
      verifyNever(() => api.addHttpTts(any()));
    });
  });

  group('ensureDefaultHttpTts 版本门控', () {
    late MockRustApi api;
    setUp(() {
      api = MockRustApi();
      when(() => api.getHttpTts()).thenAnswer((_) async => []);
      when(() => api.addHttpTts(any())).thenAnswer(
        (invocation) async =>
            (invocation.positionalArguments[0] as HttpTts).copyWith(id: 1),
      );
      when(() => api.httpTtsSetEnabled(any(), any()))
          .thenAnswer((_) async => true);
    });

    test('首启导入一次并写版本号，再次调用不再导入', () async {
      SharedPreferences.setMockInitialValues({});
      const json = '[{"id": -100, "name": "1.百度", "url": "http://a/tts?t={{speakText}}"}]';

      await ensureDefaultHttpTts(api, jsonOverride: json);
      verify(() => api.addHttpTts(any())).called(1);

      await ensureDefaultHttpTts(api, jsonOverride: json);
      verifyNever(() => api.addHttpTts(any()));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(kHttpTtsSeedVersionKey), kHttpTtsSeedVersion);
    });

    test('版本已是最新：完全跳过（不读库不导入）', () async {
      SharedPreferences.setMockInitialValues({
        kHttpTtsSeedVersionKey: kHttpTtsSeedVersion,
      });

      await ensureDefaultHttpTts(api, jsonOverride: '[{"name":"x","url":"http://x"}]');

      verifyNever(() => api.getHttpTts());
    });
  });

  group('引擎 URL 兼容性判定（自动选默认引擎）', () {
    test('原版种子模板均不兼容（POST/@js/无占位符）', () {
      expect(isCompatibleHttpTtsEngineUrl(_seedBaiduUrl), isFalse);
      expect(
        isCompatibleHttpTtsEngineUrl(
          'https://nls-gateway.example.com/tts,{"method":"POST"}',
        ),
        isFalse,
      );
      expect(isCompatibleHttpTtsEngineUrl('@js:apiurl(speakText,speakSpeed)'),
          isFalse);
      expect(isCompatibleHttpTtsEngineUrl('http://tts.example.com/tts'), isFalse);
      expect(isCompatibleHttpTtsEngineUrl(''), isFalse);
      expect(isCompatibleHttpTtsEngineUrl('ftp://tts.example.com/{{text}}'),
          isFalse);
    });

    test('GET + 文本占位符（Rust 管线支持）为兼容', () {
      expect(
        isCompatibleHttpTtsEngineUrl('http://192.168.1.2:8770/tts?text={{text}}&speed={{speed}}'),
        isTrue,
      );
      expect(
        isCompatibleHttpTtsEngineUrl(
            'https://tts.example.com/api?text={{speakText}}&speed={{speakSpeed}}'),
        isTrue,
      );
    });
  });

  group('AudioNotifier 自动选默认引擎（D3 集成）', () {
    late MockRustApi api;
    late FakeStreamAudioPlayer fakePlayer;
    late ProviderContainer container;

    setUpAll(registerFallbacks);

    setUp(() {
      // 版本已最新：跳过种子导入，聚焦默认引擎筛选
      SharedPreferences.setMockInitialValues({
        kHttpTtsSeedVersionKey: kHttpTtsSeedVersion,
      });
      api = MockRustApi();
      fakePlayer = FakeStreamAudioPlayer();
      container = ProviderContainer(
        overrides: [
          bookApiProvider.overrideWithValue(api),
          streamAudioPlayerProvider.overrideWithValue(fakePlayer),
        ],
      );
      addTearDown(container.dispose);

      when(() => api.getChapters(any())).thenAnswer(
        (_) async => [const BookChapter(title: '第一章', index: 0)],
      );
      when(() => api.getBook(any())).thenAnswer((_) async => null);
      when(() => api.getChapterContent(any(), any()))
          .thenAnswer((_) async => '正文内容。');
      when(() => api.audioSpeak(
            text: any(named: 'text'),
            engineUrl: any(named: 'engineUrl'),
            speed: any(named: 'speed'),
            pitch: any(named: 'pitch'),
            volume: any(named: 'volume'),
            voiceName: any(named: 'voiceName'),
          )).thenAnswer((_) async => '/tmp/tts/para.mp3');
    });

    test('库中只有不兼容种子 → 不自动选中，保持无引擎降级（不冒充可用）',
        () async {
      when(() => api.getHttpTts()).thenAnswer(
        (_) async => [
          HttpTts(
            id: -100,
            name: '1.百度',
            url: _seedBaiduUrl,
          ),
        ],
      );

      await container
          .read(audioNotifierProvider.notifier)
          .startReadAloud(bookUrl: 'url', bookName: '书');

      final state = container.read(audioNotifierProvider);
      expect(state.config.engineUrl, isEmpty);
      expect(state.state, PlayerState.playing);
      // 无引擎路径不调用合成（降级估算），也不报错
      verifyNever(() => api.audioSpeak(
            text: any(named: 'text'),
            engineUrl: any(named: 'engineUrl'),
            speed: any(named: 'speed'),
            pitch: any(named: 'pitch'),
            volume: any(named: 'volume'),
            voiceName: any(named: 'voiceName'),
          ));
      expect(state.errorMessage, isNull);
    });

    test('库中含兼容引擎 → 跳过不兼容项选中兼容项', () async {
      when(() => api.getHttpTts()).thenAnswer(
        (_) async => [
          HttpTts(id: -100, name: '1.百度', url: _seedBaiduUrl),
          HttpTts(
            id: 5,
            name: '本地引擎',
            url: 'http://192.168.1.2:8770/tts?text={{text}}',
          ),
        ],
      );

      await container
          .read(audioNotifierProvider.notifier)
          .startReadAloud(bookUrl: 'url', bookName: '书');

      final state = container.read(audioNotifierProvider);
      expect(state.config.engineUrl, 'http://192.168.1.2:8770/tts?text={{text}}');
      expect(fakePlayer.playedLocalFiles, hasLength(1));
    });
  });
}
