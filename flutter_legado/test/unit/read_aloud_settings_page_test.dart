// 朗读设置页 widget 测试（设置批5a-1）
//
// 覆盖：
// 1) 三页签（常规/引擎与音色/角色与配乐）与设置主页入口导航；
// 2) 常规开关读写（忽略音频焦点/唤醒锁/退出保持/媒体键翻章）与选择对话框；
// 3) 置灰项不可点（胶囊/来电暂停/安卓媒体控制/流式/角色与配乐 8 项）；
// 4) 引擎与音色页：系统引擎/音色选择、空态、语速/音调/音量滑块范围与持久化；
// 5) 「其他设置」旧「忽略音频焦点」行已移除（唯一入口迁移）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/other_settings_screen.dart';
import 'package:flutter_legado/src/screens/read_aloud_settings_screen.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';
import 'package:flutter_legado/src/services/platform_channel.dart';
import 'package:flutter_legado/src/services/system_tts_service.dart';
import 'package:flutter_legado/src/utils/read_aloud_content_split.dart';
import 'package:flutter_legado/src/widgets/reader/read_aloud_bar.dart';

import '../mocks/mocks.dart';

/// 页面测试用的系统 TTS 平台 Fake（无副作用，固定引擎/音色）
class _PageFakePlatform implements SystemTtsPlatform {
  _PageFakePlatform({this.engines = const [], this.voices = const []});

  List<SystemTtsEngine> engines;
  List<SystemTtsVoice> voices;

  /// 按引擎返回不同音色（key=引擎包名；未配置时用 [voices]）
  Map<String, List<SystemTtsVoice>> voicesByEngine = const {};
  String? _currentEngine;

  /// 非空时 setEngine 等待该闸门（模拟引擎初始化永不返回）
  Completer<void>? setEngineGate;

  final List<String> selectedEngines = [];
  final List<SystemTtsVoice> selectedVoices = [];
  int clearVoiceCount = 0;
  int resetEngineCount = 0;

  @override
  bool get supportsEngineSelection => true;

  @override
  bool get supportsSynthesis => true;

  @override
  Future<void> init() async {}

  @override
  Future<List<SystemTtsEngine>> getEngines() async => engines;

  @override
  Future<List<SystemTtsVoice>> getVoices() async =>
      voicesByEngine[_currentEngine] ?? voices;

  @override
  Future<void> setEngine(String engineName) async {
    final gate = setEngineGate;
    if (gate != null) await gate.future;
    selectedEngines.add(engineName);
    _currentEngine = engineName;
  }

  @override
  Future<void> resetEngine() async => resetEngineCount++;

  @override
  Future<void> setVoice(SystemTtsVoice voice) async =>
      selectedVoices.add(voice);

  @override
  Future<void> clearVoice() async => clearVoiceCount++;

  @override
  Future<void> setSpeechRate(double speed) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> synthesizeToFile(String text, String fullPath) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> resetClient() async {
    _currentEngine = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRustApi mockApi;
  late _PageFakePlatform fakePlatform;
  late SystemTtsService systemTts;
  late ProviderContainer container;
  late Directory tempDir;

  /// 平台覆盖必须在测试体内复位（binding 不变量校验先于 tearDown）
  void testAndroid(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  void testOnPlatform(
    TargetPlatform platform,
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    uiSettingsListenable.value = const UiSettingsState();
    tempDir = Directory.systemTemp.createTempSync('read_aloud_page_test');
    mockApi = MockRustApi();
    fakePlatform = _PageFakePlatform(
      engines: const [SystemTtsEngine(name: 'com.example.tts', label: '示例引擎')],
      voices: const [SystemTtsVoice(name: 'zh-cn-x', locale: 'zh-CN')],
    );
    systemTts = SystemTtsService(
      platform: fakePlatform,
      baseDirectoryProvider: () async => tempDir,
      synthesisTimeout: const Duration(milliseconds: 50),
    );
    when(() => mockApi.getHttpTts()).thenAnswer((_) async => []);
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    when(
      () => mockApi.setHttpLogRecording(any()),
    ).thenAnswer((_) async => true);

    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        systemTtsServiceProvider.overrideWithValue(systemTts),
      ],
    );
    addTearDown(container.dispose);

    // 系统设置通道：电池优化查询固定「未豁免」，跳转固定成功
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformChannel.systemSettings, (call) async {
          if (call.method == 'isIgnoringBatteryOptimizations') return false;
          return true;
        });
  });

  tearDown(() {
    uiSettingsListenable.value = const UiSettingsState();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformChannel.systemSettings, null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Widget wrap(Widget child, {Map<String, WidgetBuilder>? routes}) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child, routes: routes ?? const {}),
    );
  }

  Future<void> pumpPage(WidgetTester tester, {Widget? child}) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(child ?? const ReadAloudSettingsScreen()));
    await tester.pumpAndSettle();
  }

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  /// 等待异步回调完成（tap 的 async handler 不阻塞 pumpAndSettle）
  Future<void> waitFor(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// 取某标题所在行的 ListTile（判定置灰/可点）
  ListTile tileOf(WidgetTester tester, String title) {
    return tester.widget<ListTile>(
      find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
    );
  }

  group('三页签与入口', () {
    testAndroid('渲染三个页签，默认常规页', (tester) async {
      await pumpPage(tester);
      expect(find.text('常规'), findsOneWidget);
      expect(find.text('引擎与音色'), findsOneWidget);
      expect(find.text('角色与配乐'), findsOneWidget);
      expect(find.text('默认朗读界面'), findsOneWidget);
      expect(find.text('朗读设置'), findsOneWidget);
    });

    testAndroid('设置主页「朗读设置」入口可导航到本页', (tester) async {
      tester.view.physicalSize = const Size(1000, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final routes = Map<String, WidgetBuilder>.from(AppRoutes.routes)
        ..remove(AppRoutes.home);
      await tester.pumpWidget(wrap(const SettingsHomeScreen(), routes: routes));
      await tester.pumpAndSettle();

      expect(find.text('朗读设置'), findsOneWidget);
      await tester.tap(find.text('朗读设置'));
      await tester.pumpAndSettle();
      expect(find.byType(ReadAloudSettingsScreen), findsOneWidget);
      expect(find.text('引擎与音色'), findsOneWidget);
    });
  });

  group('常规开关读写', () {
    testAndroid('忽略音频焦点开关写偏好（自其他设置迁入）', (tester) async {
      await pumpPage(tester);
      expect(tileOf(tester, '忽略音频焦点').enabled, isTrue);
      await tapText(tester, '忽略音频焦点');
      expect((await prefs()).getBool(PrefKeys.ignoreAudioFocus), isTrue);
    });

    testAndroid('朗读唤醒锁开关写偏好并即时通知 Notifier', (tester) async {
      await pumpPage(tester);
      await tapText(tester, '朗读唤醒锁');
      expect((await prefs()).getBool(PrefKeys.readAloudWakeLock), isTrue);
    });

    testAndroid('退出阅读时继续朗读开关写偏好', (tester) async {
      await pumpPage(tester);
      await tapText(tester, '退出阅读时继续朗读');
      expect((await prefs()).getBool(PrefKeys.keepReadAloudOnExit), isTrue);
    });

    testAndroid('媒体键翻章开关写偏好', (tester) async {
      await pumpPage(tester);
      await tapText(tester, '媒体键上一首/下一首翻章');
      expect((await prefs()).getBool(PrefKeys.mediaButtonPerNext), isTrue);
    });

    testAndroid('默认朗读界面对话框：选择「播放器」写入偏好', (tester) async {
      await pumpPage(tester);
      await tapText(tester, '默认朗读界面');
      expect(find.text('阅读器内朗读控制条'), findsOneWidget);
      await tapText(tester, '播放器');
      expect(
        (await prefs()).getString(PrefKeys.defaultReadAloudInterface),
        'player',
      );
      expect(find.text('播放器'), findsOneWidget, reason: '行尾值应更新');
    });

    testAndroid('播放器背景：模糊/流光置灰不可选，透明可选', (tester) async {
      await pumpPage(tester);
      await tapText(tester, '播放器背景');
      // 模糊为置灰项：点击后对话框保持打开、偏好不变
      await tapText(tester, '模糊');
      expect(find.text('流光'), findsOneWidget, reason: '对话框不应关闭');
      expect(
        (await prefs()).getString(PrefKeys.readAloudPlayerBackground),
        isNull,
      );
      await tapText(tester, '透明');
      expect(
        (await prefs()).getString(PrefKeys.readAloudPlayerBackground),
        'transparent',
      );
    });

    testAndroid('TTS 缓存行展示统计/保留时间并可清理', (tester) async {
      await pumpPage(tester);
      expect(find.text('TTS 缓存'), findsOneWidget);
      expect(find.textContaining('保留 10 分钟'), findsOneWidget);
      await tapText(tester, 'TTS 缓存');
      expect(find.textContaining('系统 TTS 合成缓存'), findsOneWidget);
      // 保留时间入口已收敛到独立行；对话框只展示当前值 + 清理
      expect(find.textContaining('当前保留：10 分钟'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tts-cache-retention-slider')),
        findsNothing,
      );
      expect(find.text('清理'), findsOneWidget);
      await tapText(tester, '取消');
    });

    testAndroid('缓存保留时间行：0 即听即焚写入偏好并回显', (tester) async {
      await pumpPage(tester);
      expect(tileOf(tester, '缓存保留时间').enabled, isTrue);
      expect(
        find.byKey(const ValueKey('read-aloud-cache-retention')),
        findsOneWidget,
      );

      await tapText(tester, '缓存保留时间');
      expect(find.text('缓存保留时间'), findsWidgets);
      expect(find.textContaining('0 表示即听即焚'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, '即听即焚'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        (await prefs()).getInt(PrefKeys.readAloudCacheRetentionMinutes),
        0,
      );
      expect(
        container
            .read(audioNotifierProvider.notifier)
            .readAloudCacheRetentionMinutes,
        0,
      );

      await tapText(tester, '完成');
      expect(find.text('即听即焚'), findsOneWidget, reason: '行尾值回显');
    });
  });

  group('置灰项不可点', () {
    testAndroid('常规页高成本项全部 disabled', (tester) async {
      await pumpPage(tester);
      for (final title in [
        '显示朗读胶囊',
        '自动收缩朗读胶囊',
        '重置朗读胶囊位置',
        '来电时暂停朗读',
        '安卓媒体控制兼容',
        '流式朗读',
      ]) {
        expect(tileOf(tester, title).enabled, isFalse, reason: '$title 应置灰');
      }
    });

    testAndroid('角色与配乐 8 项全部 disabled（可见但不可点）', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('角色与配乐'));
      await tester.pumpAndSettle();
      for (final title in [
        '多角色朗读',
        '角色分配',
        '人物配音',
        '声音池',
        'BGM 分配',
        'BGM 池',
        '本章 BGM',
        'AI 场景识别',
      ]) {
        expect(tileOf(tester, title).enabled, isFalse, reason: '$title 应置灰');
        expect(find.text('暂未支持'), findsWidgets);
      }
    });

    testOnPlatform(TargetPlatform.windows, '非 Android：唤醒锁/媒体键/电池优化置灰', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(tileOf(tester, '朗读唤醒锁').enabled, isFalse);
      expect(tileOf(tester, '媒体键上一首/下一首翻章').enabled, isFalse);
      expect(tileOf(tester, '后台保活 / 电池优化').enabled, isFalse);

      // P2-1：Windows 无 synthesizeToFile → 系统 TTS/音色置灰并注明平台
      await tester.tap(find.text('引擎与音色'));
      await tester.pumpAndSettle();
      expect(tileOf(tester, '系统 TTS').enabled, isFalse);
      expect(tileOf(tester, '音色').enabled, isFalse);
      expect(find.text('仅 Android/iOS/macOS 支持'), findsWidgets);
    });
  });

  group('引擎与音色页', () {
    testAndroid('默认选中系统 TTS；系统引擎/音色可选', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('引擎与音色'));
      await tester.pumpAndSettle();

      // 系统 TTS 选中态（radio checked）
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('read-aloud-engine-system')),
          matching: find.byIcon(Icons.radio_button_checked),
        ),
        findsOneWidget,
      );

      await tapText(tester, '系统引擎');
      await tapText(tester, '示例引擎');
      expect(
        (await prefs()).getString(PrefKeys.systemTtsEngine),
        'com.example.tts',
      );

      await tapText(tester, '音色');
      await tapText(tester, 'zh-cn-x（zh-CN）');
      expect((await prefs()).getString(PrefKeys.systemTtsVoice), 'zh-cn-x');
      expect((await prefs()).getString(PrefKeys.systemTtsVoiceLocale), 'zh-CN');
    });

    testAndroid('系统引擎/音色空态：置灰且提示', (tester) async {
      fakePlatform.engines = const [];
      fakePlatform.voices = const [];
      await pumpPage(tester);
      await tester.tap(find.text('引擎与音色'));
      await tester.pumpAndSettle();

      expect(find.text('系统未安装 TTS 引擎'), findsOneWidget);
      expect(find.text('无可用音色'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(
              find.ancestor(
                of: find.text('系统引擎'),
                matching: find.byType(ListTile),
              ),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<ListTile>(
              find.ancestor(
                of: find.text('音色'),
                matching: find.byType(ListTile),
              ),
            )
            .enabled,
        isFalse,
      );
    });

    testAndroid('语速/音调/音量滑块范围正确，拖动后持久化并写入 Notifier', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('引擎与音色'));
      await tester.pumpAndSettle();

      Slider sliderOf(String key) => tester.widget<Slider>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(Slider),
        ),
      );

      final speed = sliderOf('read-aloud-speed-slider');
      expect(speed.min, kMinTtsSpeed);
      expect(speed.max, kMaxTtsSpeed);
      final pitch = sliderOf('read-aloud-pitch-slider');
      expect(pitch.min, 0.5);
      expect(pitch.max, 2.0);
      final volume = sliderOf('read-aloud-volume-slider');
      expect(volume.min, 0.0);
      expect(volume.max, 1.0);

      speed.onChanged!(2.0);
      pitch.onChanged!(1.2);
      volume.onChanged!(0.5);
      await tester.pump();
      final config = container.read(audioNotifierProvider).config;
      expect(config.speed, 2.0);
      expect(config.pitch, 1.2);
      expect(config.volume, 0.5);

      speed.onChangeEnd!(2.0);
      pitch.onChangeEnd!(1.2);
      volume.onChangeEnd!(0.5);
      await tester.pumpAndSettle();

      final p = await prefs();
      expect(p.getInt(PrefKeys.ttsSpeechRate), ttsSpeechRateFromSpeed(2.0));
      expect(p.getInt(PrefKeys.ttsPitch), ttsPitchToStored(1.2));
      expect(p.getInt(PrefKeys.ttsVolume), ttsVolumeToStored(0.5));
    });

    testAndroid('设置页语速 1.5x → 朗读条显示 1.5x（跟随系统不覆盖，停止重播保持）', (tester) async {
      // 设备验收 P2 缺陷回归：设置页 1.5x，朗读条挂载后曾被强制回 1.0x
      await pumpPage(tester);
      await tester.tap(find.text('引擎与音色'));
      await tester.pumpAndSettle();

      final speed = tester.widget<Slider>(
        find.descendant(
          of: find.byKey(const ValueKey('read-aloud-speed-slider')),
          matching: find.byType(Slider),
        ),
      );
      speed.onChanged!(1.5);
      speed.onChangeEnd!(1.5);
      await tester.pumpAndSettle();
      expect(container.read(audioNotifierProvider).config.speed, 1.5);

      Widget barHost() => Scaffold(
        body: Stack(
          children: [
            ReadAloudBar(
              onDismiss: () {},
              onOpenCatalog: () {},
              onBackstage: () {},
            ),
          ],
        ),
      );

      // 进入朗读条：同一 config 为唯一数据源，follow 缺省 true 也不得覆盖
      await pumpPage(tester, child: barHost());
      expect(
        container.read(audioNotifierProvider).config.speed,
        1.5,
        reason: '朗读条挂载后不得覆盖设置页语速',
      );
      expect(find.text('1.5x'), findsOneWidget);

      // 停止后重播（重建朗读条）仍保持 1.5
      container.read(audioNotifierProvider.notifier).stop();
      await tester.pumpWidget(wrap(barHost()));
      await tester.pumpAndSettle();
      expect(container.read(audioNotifierProvider).config.speed, 1.5);
      expect(find.text('1.5x'), findsOneWidget);
    });

    testAndroid('系统 TTS 设置/电池优化跳转（Android 可点并调用原生）', (tester) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PlatformChannel.systemSettings, (
            call,
          ) async {
            calls.add(call.method);
            if (call.method == 'isIgnoringBatteryOptimizations') return false;
            return true;
          });
      await pumpPage(tester);
      await tester.tap(find.text('引擎与音色'));
      await tester.pumpAndSettle();
      await tapText(tester, '系统 TTS 设置');
      expect(calls, contains('openTtsSettings'));

      await tester.tap(find.text('常规'));
      await tester.pumpAndSettle();
      await tapText(tester, '后台保活 / 电池优化');
      expect(calls, contains('openBatteryOptimizationSettings'));
    });
  });

  group('审查回修 P2-4 滑块落盘', () {
    Slider sliderOf(WidgetTester tester, String key) => tester.widget<Slider>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Slider),
      ),
    );

    testAndroid('仅拖音量只写音量键，不改语速/音调', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('引擎与音色'));
      await tester.pumpAndSettle();

      final volume = sliderOf(tester, 'read-aloud-volume-slider');
      volume.onChanged!(0.4);
      await tester.pump();
      volume.onChangeEnd!(0.4);
      await tester.pumpAndSettle();

      final p = await prefs();
      expect(p.getInt(PrefKeys.ttsVolume), ttsVolumeToStored(0.4));
      expect(p.getInt(PrefKeys.ttsSpeechRate), isNull);
      expect(p.getInt(PrefKeys.ttsPitch), isNull);
    });

    testAndroid('流媒体模式下语速滑块不改音频书语速', (tester) async {
      container.read(audioNotifierProvider.notifier).setAudioBookMode(true);
      await pumpPage(tester);
      await tester.tap(find.text('引擎与音色'));
      await tester.pumpAndSettle();

      final before = container.read(audioNotifierProvider).config.speed;
      final speed = sliderOf(tester, 'read-aloud-speed-slider');
      speed.onChanged!(2.0);
      await tester.pump();
      expect(
        container.read(audioNotifierProvider).config.speed,
        before,
        reason: '流媒体语速归书级 playSpeed，不得被设置页改写',
      );
      speed.onChangeEnd!(2.0);
      await tester.pumpAndSettle();
      expect(
        (await prefs()).getInt(PrefKeys.ttsSpeechRate),
        ttsSpeechRateFromSpeed(2.0),
        reason: '全局 TTS 偏好仍应落盘',
      );
    });

    testAndroid('切引擎刷新音色列表并清除新引擎不可用的音色', (tester) async {
      const voiceA = SystemTtsVoice(name: 'a', locale: 'zh-CN');
      const voiceB = SystemTtsVoice(name: 'b', locale: 'zh-CN');
      fakePlatform.engines = const [
        SystemTtsEngine(name: 'engine-a', label: '引擎A'),
        SystemTtsEngine(name: 'engine-b', label: '引擎B'),
      ];
      fakePlatform.voicesByEngine = const {
        'engine-a': [voiceA],
        'engine-b': [voiceB],
      };
      SharedPreferences.setMockInitialValues({
        PrefKeys.systemTtsVoice: 'a',
        PrefKeys.systemTtsVoiceLocale: 'zh-CN',
      });
      await pumpPage(tester);
      await tester.tap(find.text('引擎与音色'));
      await tester.pumpAndSettle();

      await tapText(tester, '系统引擎');
      await tapText(tester, '引擎B');
      await waitFor(tester, () => systemTts.selectedVoice == null);
      expect((await prefs()).getString(PrefKeys.systemTtsEngine), 'engine-b');
      expect(systemTts.selectedVoice, isNull, reason: 'service 应清除失效音色');
      expect(
        (await prefs()).getString(PrefKeys.systemTtsVoice),
        isNull,
        reason: '原音色不在新引擎列表，应清除持久化',
      );
      expect(
        systemTts.takeNotice(),
        isNull,
        reason: '页面 toast 已提示，服务一次性提示应被消费，避免播放时重复',
      );

      await tapText(tester, '音色');
      expect(find.text('b（zh-CN）'), findsOneWidget);
      expect(find.text('a（zh-CN）'), findsNothing);
      await tapText(tester, '取消');
    });

    testAndroid('P2-A 引擎初始化超时：回滚选中态并提示失败', (tester) async {
      fakePlatform.engines = const [
        SystemTtsEngine(name: 'engine-a', label: '引擎A'),
        SystemTtsEngine(name: 'engine-b', label: '引擎B'),
      ];
      fakePlatform.voicesByEngine = const {
        'engine-a': [SystemTtsVoice(name: 'a', locale: 'zh-CN')],
        'engine-b': [SystemTtsVoice(name: 'b', locale: 'zh-CN')],
      };
      SharedPreferences.setMockInitialValues({
        PrefKeys.systemTtsEngine: 'engine-a',
      });
      await pumpPage(tester);
      await tester.tap(find.text('引擎与音色'));
      await tester.pumpAndSettle();

      fakePlatform.setEngineGate = Completer<void>();
      await tapText(tester, '系统引擎');
      await tapText(tester, '引擎B');
      await waitFor(tester, () => find.text('引擎初始化失败').evaluate().isNotEmpty);

      expect(find.text('引擎初始化失败'), findsOneWidget);
      expect(
        (await prefs()).getString(PrefKeys.systemTtsEngine),
        'engine-a',
        reason: '失败需回滚持久化选择',
      );
      expect(find.text('引擎A'), findsWidgets, reason: '选中态回滚到引擎A');
      if (!fakePlatform.setEngineGate!.isCompleted) {
        fakePlatform.setEngineGate!.complete();
      }
    });
  });

  group('旧入口迁移', () {
    testAndroid('其他设置不再出现「忽略音频焦点」行', (tester) async {
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      tester.view.physicalSize = const Size(1000, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(const OtherSettingsScreen()));
      await tester.pumpAndSettle();

      // 滚动到旧行位置（现「自动清除过期搜索数据」）
      await tester.dragUntilVisible(
        find.text('自动清除过期搜索数据'),
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(find.text('忽略音频焦点'), findsNothing);
      expect(find.text('自动清除过期搜索数据'), findsOneWidget);
    });
  });

  group('内容分析（设置批5b）', () {
    FilterChip chipOf(WidgetTester tester, String symbol) =>
        tester.widget<FilterChip>(
          find.byKey(ValueKey('read-aloud-split-symbol-$symbol')),
        );

    Slider intervalSlider(WidgetTester tester) => tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const ValueKey('read-aloud-paragraph-interval-slider')),
        matching: find.byType(Slider),
      ),
    );

    testAndroid('渲染内容分析组与默认值，推理级别置灰', (tester) async {
      await pumpPage(tester);
      expect(find.text('内容分析'), findsOneWidget);
      expect(find.text('章节分片方式'), findsOneWidget);
      expect(find.text('推理级别'), findsOneWidget);
      expect(find.text('内容划分方式'), findsOneWidget);
      expect(find.text('段落间隔'), findsOneWidget);

      // 默认值
      expect(find.text('规则'), findsOneWidget);
      expect(find.text('关闭'), findsOneWidget);
      expect(find.text('默认'), findsOneWidget);
      expect(find.text('0 ms'), findsOneWidget);
      expect(tileOf(tester, '推理级别').enabled, isFalse);

      // 默认非 symbols 模式不展开标点
      expect(find.byType(FilterChip), findsNothing);
    });

    testAndroid('章节分片方式：AI 两项置灰，仅规则可写入', (tester) async {
      await pumpPage(tester);
      await tapText(tester, '章节分片方式');
      expect(find.text('规则+AI'), findsOneWidget);
      expect(find.text('AI 理解'), findsOneWidget);

      // 置灰项点击不关闭对话框、不写偏好
      await tapText(tester, '规则+AI');
      expect(find.text('AI 理解'), findsOneWidget, reason: '对话框不应关闭');
      expect((await prefs()).getString(PrefKeys.speechAnalysisMode), isNull);

      // 行尾值也显示「规则」，点击需限定在对话框内
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('规则'),
        ),
      );
      await tester.pumpAndSettle();
      expect((await prefs()).getString(PrefKeys.speechAnalysisMode), 'rule');
    });

    testAndroid('内容划分方式切到「按符号」：展开 14 个 chip，空存储回显句末标点', (tester) async {
      await pumpPage(tester);
      await tapText(tester, '内容划分方式');
      await tapText(tester, '按符号');

      expect(
        (await prefs()).getString(PrefKeys.readAloudContentSplitMode),
        'symbols',
      );
      expect(find.byType(FilterChip), findsNWidgets(14));
      for (final symbol in ['。', '！', '？', '…']) {
        expect(
          chipOf(tester, symbol).selected,
          isTrue,
          reason: '空存储时 $symbol 应显示为选中',
        );
      }
      expect(chipOf(tester, '，').selected, isFalse);
      expect(find.textContaining('未选择时按句末标点'), findsOneWidget);
    });

    testAndroid('标点多选：切换按参考版 StringList 写入，已在句末集合上追加', (tester) async {
      await pumpPage(tester);
      await tapText(tester, '内容划分方式');
      await tapText(tester, '按符号');

      await tester.tap(find.byKey(const ValueKey('read-aloud-split-symbol-，')));
      await tester.pumpAndSettle();

      expect(chipOf(tester, '，').selected, isTrue);
      expect(
        (await prefs()).getStringList(PrefKeys.readAloudContentSplitSymbols),
        ['。', '！', '？', '…', '，'],
      );
      expect(find.textContaining('已选 5 个标点'), findsOneWidget);
    });

    testAndroid('标点至少保留一个：取消最后一个时不写入', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readAloudContentSplitMode: 'symbols',
        PrefKeys.readAloudContentSplitSymbols: '。',
      });
      await pumpPage(tester);
      expect(chipOf(tester, '。').selected, isTrue);

      await tester.tap(find.byKey(const ValueKey('read-aloud-split-symbol-。')));
      await tester.pumpAndSettle();

      expect(chipOf(tester, '。').selected, isTrue, reason: '最后一个标点不可取消');
      expect(
        (await prefs()).getString(PrefKeys.readAloudContentSplitSymbols),
        '。',
      );
      expect(find.text('至少保留一个标点'), findsOneWidget);
    });

    testAndroid('段落间隔滑块范围 0–5000ms，拖动后持久化并同步 Notifier', (tester) async {
      await pumpPage(tester);
      final slider = intervalSlider(tester);
      expect(slider.min, 0);
      expect(slider.max, kMaxTtsParagraphIntervalMs.toDouble());

      slider.onChanged!(1500);
      await tester.pump();
      expect(find.text('1500 ms'), findsOneWidget);
      expect(
        container.read(audioNotifierProvider.notifier).ttsParagraphIntervalMs,
        1500,
      );

      slider.onChangeEnd!(1500);
      await tester.pumpAndSettle();
      expect((await prefs()).getInt(PrefKeys.ttsParagraphInterval), 1500);
    });

    testAndroid('重启回显：模式/标点/间隔/分片方式/推理级别', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readAloudContentSplitMode: 'symbols',
        // 参考版 StringSet/外部备份数组形态
        PrefKeys.readAloudContentSplitSymbols: <String>['。', '！'],
        PrefKeys.ttsParagraphInterval: 1500,
        PrefKeys.speechAnalysisMode: 'ai_understanding',
        PrefKeys.speechAnalysisReasoningLevel: 'high',
      });
      await pumpPage(tester);

      expect(find.text('按符号'), findsOneWidget);
      expect(find.text('AI 理解'), findsOneWidget);
      expect(find.textContaining('AI 分片暂未支持，实际按规则分片'), findsOneWidget);
      expect(find.text('高'), findsOneWidget);
      expect(find.text('1500 ms'), findsOneWidget);
      expect(find.byType(FilterChip), findsNWidgets(14));
      expect(chipOf(tester, '。').selected, isTrue);
      expect(chipOf(tester, '！').selected, isTrue);
      expect(chipOf(tester, '？').selected, isFalse);
    });
  });
}
