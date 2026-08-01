// AudioNotifier 单元测试
//
// 由原 AudioProvider（ChangeNotifier）测试迁移而来，测试点逐一对齐：
// 初始状态 / TtsConfig / AudioChapter / loadChapters / 播放控制 /
// 播放模式 / updateConfig / PlayerState / AudioPlayMode 枚举。
//
// 迁移范式：ProviderContainer + bookApiProvider.overrideWithValue(mockApi)。
// AudioService 依赖走 audioServiceProvider，默认单例在测试环境未初始化，
// 其所有平台通道调用均为静默 no-op（与原测试使用真实单例的行为一致），
// 故此处无需 override audioServiceProvider。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  AudioState readState() => container.read(audioNotifierProvider);
  AudioNotifier readNotifier() =>
      container.read(audioNotifierProvider.notifier);

  group('AudioNotifier 初始状态', () {
    test('初始状态为 idle', () {
      expect(readState().state, equals(PlayerState.idle));
    });

    test('初始播放模式为 sequential', () {
      expect(readState().mode, equals(AudioPlayMode.sequential));
    });

    test('初始无章节', () {
      expect(readState().chapters, isEmpty);
      expect(readState().hasChapters, isFalse);
      expect(readState().totalChapters, equals(0));
    });

    test('初始索引为 0', () {
      expect(readState().currentIndex, equals(0));
    });

    test('初始无错误', () {
      expect(readState().errorMessage, isNull);
    });

    test('初始 bookUrl 和 bookName 为空', () {
      expect(readState().bookUrl, equals(''));
      expect(readState().bookName, equals(''));
    });

    test('初始 isPlaying 为 false', () {
      expect(readState().isPlaying, isFalse);
    });

    test('初始 isLoading 为 false', () {
      expect(readState().isLoading, isFalse);
    });

    test('初始 currentChapter 为 null', () {
      expect(readState().currentChapter, isNull);
    });

    test('初始 hasPrevious 为 false', () {
      expect(readState().hasPrevious, isFalse);
    });

    test('初始 hasNext 为 false', () {
      expect(readState().hasNext, isFalse);
    });

    test('初始 progress 为 0', () {
      expect(readState().progress, equals(0.0));
    });

    test('初始媒体会话未就绪', () {
      expect(readState().isMediaSessionReady, isFalse);
    });
  });

  group('TtsConfig 配置', () {
    test('默认配置值', () {
      final config = TtsConfig();
      expect(config.engineUrl, equals(''));
      expect(config.voiceName, isNull);
      expect(config.speed, equals(1.0));
      expect(config.pitch, equals(1.0));
      expect(config.volume, equals(1.0));
    });

    test('自定义配置值', () {
      final config = TtsConfig(
        engineUrl: 'https://tts.example.com',
        voiceName: 'xiaoming',
        speed: 1.5,
        pitch: 0.8,
        volume: 0.9,
      );
      expect(config.engineUrl, equals('https://tts.example.com'));
      expect(config.voiceName, equals('xiaoming'));
      expect(config.speed, equals(1.5));
      expect(config.pitch, equals(0.8));
      expect(config.volume, equals(0.9));
    });

    test('toJson 序列化正确', () {
      final config = TtsConfig(
        engineUrl: 'https://tts.com',
        voiceName: 'voice1',
        speed: 2.0,
        pitch: 1.5,
        volume: 0.5,
      );
      final json = config.toJson();
      expect(json['engine_url'], equals('https://tts.com'));
      expect(json['voice_name'], equals('voice1'));
      expect(json['speed'], equals(2.0));
      expect(json['pitch'], equals(1.5));
      expect(json['volume'], equals(0.5));
    });

    test('toJson voiceName 为 null 时正确序列化', () {
      final config = TtsConfig();
      final json = config.toJson();
      expect(json['voice_name'], isNull);
    });
  });

  group('AudioChapter 模型', () {
    test('fromJson 正确解析', () {
      final chapter = AudioChapter.fromJson({
        'index': 3,
        'title': '第三章',
        'text': '内容',
        'duration_estimate_ms': 5000,
      });
      expect(chapter.index, equals(3));
      expect(chapter.title, equals('第三章'));
      expect(chapter.text, equals('内容'));
      expect(chapter.durationEstimateMs, equals(5000));
    });

    test('fromJson 缺失字段使用默认值', () {
      final chapter = AudioChapter.fromJson({});
      expect(chapter.index, equals(0));
      expect(chapter.title, equals(''));
      expect(chapter.text, equals(''));
      expect(chapter.durationEstimateMs, isNull);
    });

    test('构造函数创建实例', () {
      final chapter = AudioChapter(
        index: 1,
        title: '测试',
        text: '正文',
        durationEstimateMs: 3000,
      );
      expect(chapter.index, equals(1));
      expect(chapter.title, equals('测试'));
      expect(chapter.text, equals('正文'));
      expect(chapter.durationEstimateMs, equals(3000));
    });
  });

  group('AudioNotifier loadChapters（mock API）', () {
    test('loadChapters 成功加载章节列表', () async {
      final chapters = [
        const BookChapter(title: '第一章', index: 0),
        const BookChapter(title: '第二章', index: 1),
        const BookChapter(title: '第三章', index: 2),
      ];
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => chapters);

      await readNotifier().loadChapters('https://book.com/1');

      expect(readState().bookUrl, equals('https://book.com/1'));
      expect(readState().chapters.length, equals(3));
      expect(readState().hasChapters, isTrue);
      expect(readState().totalChapters, equals(3));
      expect(readState().state, equals(PlayerState.idle));
      expect(readState().currentIndex, equals(0));
      expect(readState().errorMessage, isNull);
    });

    test('loadChapters 章节标题正确映射', () async {
      final chapters = [
        const BookChapter(title: '序章', index: 0),
        const BookChapter(title: '终章', index: 1),
      ];
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => chapters);

      await readNotifier().loadChapters('https://book.com/2');

      expect(readState().chapters[0].title, equals('序章'));
      expect(readState().chapters[1].title, equals('终章'));
      // 内容初始为空（按需加载）
      expect(readState().chapters[0].text, equals(''));
    });

    test('loadChapters 失败时设置错误状态', () async {
      when(() => mockApi.getChapters(any()))
          .thenThrow(Exception('加载失败'));

      await readNotifier().loadChapters('https://book.com/bad');

      expect(readState().state, equals(PlayerState.error));
      expect(readState().errorMessage, contains('加载失败'));
    });

    test('loadChapters 触发通知', () async {
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => []);
      var notifyCount = 0;
      container.listen(audioNotifierProvider, (_, __) => notifyCount++);

      await readNotifier().loadChapters('https://book.com/1');
      // loading → idle 至少两次状态变更
      expect(notifyCount, greaterThanOrEqualTo(2));
    });

    test('loadChapters 后 hasPrevious/hasNext 正确', () async {
      final chapters = [
        const BookChapter(title: 'ch1', index: 0),
        const BookChapter(title: 'ch2', index: 1),
        const BookChapter(title: 'ch3', index: 2),
      ];
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => chapters);

      await readNotifier().loadChapters('url');

      expect(readState().hasPrevious, isFalse);
      expect(readState().hasNext, isTrue);
    });

    test('loadChapters 后 currentChapter 正确', () async {
      final chapters = [
        const BookChapter(title: '第一章', index: 0),
      ];
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => chapters);

      await readNotifier().loadChapters('url');
      expect(readState().currentChapter?.title, equals('第一章'));
    });

    test('loadChapters 后 progress 正确', () async {
      final chapters = [
        const BookChapter(title: 'ch1', index: 0),
        const BookChapter(title: 'ch2', index: 1),
        const BookChapter(title: 'ch3', index: 2),
        const BookChapter(title: 'ch4', index: 3),
      ];
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => chapters);

      await readNotifier().loadChapters('url');
      // (0+1)/4 = 0.25
      expect(readState().progress, equals(0.25));
    });
  });

  group('AudioNotifier 播放控制（mock API）', () {
    setUp(() {
      final chapters = [
        const BookChapter(title: 'ch1', index: 0),
        const BookChapter(title: 'ch2', index: 1),
        const BookChapter(title: 'ch3', index: 2),
      ];
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => chapters);
      when(() => mockApi.getChapterContent(any(), any()))
          .thenAnswer((_) async => '章节正文内容');
      when(() => mockApi.audioSpeak(
            text: any(named: 'text'),
            engineUrl: any(named: 'engineUrl'),
            speed: any(named: 'speed'),
            pitch: any(named: 'pitch'),
            volume: any(named: 'volume'),
            voiceName: any(named: 'voiceName'),
          )).thenAnswer((_) async {});
    });

    test('play 无章节时不执行', () async {
      await readNotifier().play();
      expect(readState().state, equals(PlayerState.idle));
    });

    test('play 有章节且配置了引擎时进入 playing 状态', () async {
      await readNotifier().loadChapters('url');
      readNotifier().updateConfig(engineUrl: 'https://tts.com');

      await readNotifier().play();

      expect(readState().state, equals(PlayerState.playing));
      expect(readState().isPlaying, isTrue);
    });

    test('play 无引擎 URL 时仍进入 playing 状态', () async {
      await readNotifier().loadChapters('url');
      // 不设置 engineUrl，默认为空

      await readNotifier().play();

      expect(readState().state, equals(PlayerState.playing));
    });

    test('play 加载章节内容', () async {
      await readNotifier().loadChapters('url');
      await readNotifier().play();

      // 验证 getChapterContent 被调用
      verify(() => mockApi.getChapterContent('url', 0)).called(1);
    });

    test('play 失败时进入 error 状态', () async {
      when(() => mockApi.getChapterContent(any(), any()))
          .thenThrow(Exception('内容加载失败'));

      await readNotifier().loadChapters('url');
      await readNotifier().play();

      expect(readState().state, equals(PlayerState.error));
      expect(readState().errorMessage, contains('内容加载失败'));
    });

    test('pause 从 playing 切换到 paused', () async {
      await readNotifier().loadChapters('url');
      await readNotifier().play();
      readNotifier().pause();

      expect(readState().state, equals(PlayerState.paused));
      expect(readState().isPlaying, isFalse);
    });

    test('pause 非 playing 状态时无效', () async {
      await readNotifier().loadChapters('url');
      // 状态为 idle
      readNotifier().pause();
      expect(readState().state, equals(PlayerState.idle));
    });

    test('stop 重置为 idle', () async {
      await readNotifier().loadChapters('url');
      await readNotifier().play();
      readNotifier().stop();

      expect(readState().state, equals(PlayerState.idle));
    });

    test('next 切换到下一章', () async {
      await readNotifier().loadChapters('url');
      await readNotifier().play();
      await readNotifier().next();

      expect(readState().currentIndex, equals(1));
    });

    test('next 在最后一章时不切换（sequential 模式）', () async {
      await readNotifier().loadChapters('url');
      // 手动设置到最后一章
      await readNotifier().jumpTo(2);
      await readNotifier().next();

      // sequential 模式下最后一章不切换
      expect(readState().currentIndex, equals(2));
    });

    test('previous 切换到上一章', () async {
      await readNotifier().loadChapters('url');
      await readNotifier().jumpTo(1);
      await readNotifier().previous();

      expect(readState().currentIndex, equals(0));
    });

    test('previous 在第一章时不切换', () async {
      await readNotifier().loadChapters('url');
      await readNotifier().previous();

      expect(readState().currentIndex, equals(0));
    });

    test('jumpTo 跳转到指定章节', () async {
      await readNotifier().loadChapters('url');
      await readNotifier().jumpTo(2);

      expect(readState().currentIndex, equals(2));
    });

    test('jumpTo 负索引不跳转', () async {
      await readNotifier().loadChapters('url');
      await readNotifier().jumpTo(-1);

      expect(readState().currentIndex, equals(0));
    });

    test('jumpTo 越界索引不跳转', () async {
      await readNotifier().loadChapters('url');
      await readNotifier().jumpTo(99);

      expect(readState().currentIndex, equals(0));
    });

    test('singleLoop 模式下 next 重播当前章', () async {
      await readNotifier().loadChapters('url');
      readNotifier().setMode(AudioPlayMode.singleLoop);
      await readNotifier().jumpTo(2); // 最后一章

      await readNotifier().next();

      // singleLoop 模式下仍停留在当前章
      expect(readState().currentIndex, equals(2));
      expect(readState().state, equals(PlayerState.playing));
    });
  });

  group('AudioNotifier 播放模式', () {
    test('setMode 切换到 singleLoop', () {
      readNotifier().setMode(AudioPlayMode.singleLoop);
      expect(readState().mode, equals(AudioPlayMode.singleLoop));
    });

    test('setMode 切换到 shuffle', () {
      readNotifier().setMode(AudioPlayMode.shuffle);
      expect(readState().mode, equals(AudioPlayMode.shuffle));
    });

    test('setMode 切换回 sequential', () {
      readNotifier().setMode(AudioPlayMode.shuffle);
      readNotifier().setMode(AudioPlayMode.sequential);
      expect(readState().mode, equals(AudioPlayMode.sequential));
    });

    test('setMode 触发通知', () {
      var notified = false;
      container.listen(audioNotifierProvider, (_, __) => notified = true);
      readNotifier().setMode(AudioPlayMode.singleLoop);
      expect(notified, isTrue);
    });
  });

  group('AudioNotifier updateConfig', () {
    test('更新 engineUrl', () {
      readNotifier().updateConfig(engineUrl: 'https://tts.new.com');
      expect(readState().config.engineUrl, equals('https://tts.new.com'));
    });

    test('更新 voiceName', () {
      readNotifier().updateConfig(voiceName: 'xiaohong');
      expect(readState().config.voiceName, equals('xiaohong'));
    });

    test('更新 speed 正常值', () {
      readNotifier().updateConfig(speed: 2.0);
      expect(readState().config.speed, equals(2.0));
    });

    test('speed 低于下限被 clamp 到 0.5', () {
      readNotifier().updateConfig(speed: 0.1);
      expect(readState().config.speed, equals(0.5));
    });

    test('speed 超过上限被 clamp 到 3.0', () {
      readNotifier().updateConfig(speed: 5.0);
      expect(readState().config.speed, equals(3.0));
    });

    test('更新 pitch 正常值', () {
      readNotifier().updateConfig(pitch: 1.5);
      expect(readState().config.pitch, equals(1.5));
    });

    test('pitch 低于下限被 clamp 到 0.5', () {
      readNotifier().updateConfig(pitch: 0.1);
      expect(readState().config.pitch, equals(0.5));
    });

    test('pitch 超过上限被 clamp 到 2.0', () {
      readNotifier().updateConfig(pitch: 3.0);
      expect(readState().config.pitch, equals(2.0));
    });

    test('更新 volume 正常值', () {
      readNotifier().updateConfig(volume: 0.7);
      expect(readState().config.volume, equals(0.7));
    });

    test('volume 低于下限被 clamp 到 0.0', () {
      readNotifier().updateConfig(volume: -0.5);
      expect(readState().config.volume, equals(0.0));
    });

    test('volume 超过上限被 clamp 到 1.0', () {
      readNotifier().updateConfig(volume: 2.0);
      expect(readState().config.volume, equals(1.0));
    });

    test('同时更新多个配置', () {
      readNotifier().updateConfig(
        engineUrl: 'https://multi.com',
        speed: 1.5,
        volume: 0.8,
      );
      expect(readState().config.engineUrl, equals('https://multi.com'));
      expect(readState().config.speed, equals(1.5));
      expect(readState().config.volume, equals(0.8));
    });

    test('null 参数不更新对应字段', () {
      readNotifier().updateConfig(engineUrl: 'https://keep.com');
      readNotifier().updateConfig(speed: 2.0); // 不传 engineUrl
      expect(readState().config.engineUrl, equals('https://keep.com'));
      expect(readState().config.speed, equals(2.0));
    });

    test('updateConfig 触发通知', () {
      var notified = false;
      container.listen(audioNotifierProvider, (_, __) => notified = true);
      readNotifier().updateConfig(speed: 1.2);
      expect(notified, isTrue);
    });
  });

  group('PlayerState 枚举', () {
    test('包含所有预期状态', () {
      expect(PlayerState.values, containsAll([
        PlayerState.idle,
        PlayerState.playing,
        PlayerState.paused,
        PlayerState.loading,
        PlayerState.error,
      ]));
    });
  });

  group('AudioPlayMode 枚举', () {
    test('包含所有预期模式', () {
      expect(AudioPlayMode.values, containsAll([
        AudioPlayMode.sequential,
        AudioPlayMode.singleLoop,
        AudioPlayMode.shuffle,
      ]));
    });
  });
}
