// 「跟随系统」语速解析单元测试（设备验收 2026-11-11 批9B5C P2-1 回修）
//
// 语义：ttsFollowSys=true 表示「语速由引擎默认值决定」，但用户在朗读设置页
// 显式设置过语速（prefs ttsSpeechRate）时必须使用该值；follow=false（手动）
// 使用用户设定值；切换开关不得重置为 1.0。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/system_tts_service.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi api;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    when(() => api.getConfig(any())).thenAnswer((_) async => null);
  });

  AudioState readState() => container.read(audioNotifierProvider);
  AudioNotifier readNotifier() =>
      container.read(audioNotifierProvider.notifier);

  Future<void> seedSpeed(double speed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(PrefKeys.ttsSpeechRate, ttsSpeechRateFromSpeed(speed));
  }

  group('resolveFollowSystemTtsSpeed（纯函数）', () {
    test('用户显式设置 1.5x（参考刻度 10）→ 1.5', () {
      expect(resolveFollowSystemTtsSpeed(10), 1.5);
    });

    test('用户显式设置 2.0x（参考刻度 15）→ 2.0', () {
      expect(resolveFollowSystemTtsSpeed(15), 2.0);
    });

    test('从未设置（null）→ 引擎默认 1.0x', () {
      expect(resolveFollowSystemTtsSpeed(null), kEngineDefaultTtsSpeed);
      expect(kEngineDefaultTtsSpeed, 1.0);
    });

    test('越界参考刻度收敛到 UI 语速范围', () {
      expect(resolveFollowSystemTtsSpeed(80), kMaxTtsSpeed);
      expect(resolveFollowSystemTtsSpeed(-5), kMinTtsSpeed);
    });
  });

  group('AudioNotifier.applyTtsSpeedPreference', () {
    test('follow=true + prefs 1.5x → 有效语速 1.5x', () async {
      await seedSpeed(1.5);

      await readNotifier().applyTtsSpeedPreference(followSystem: true);

      expect(readState().config.speed, 1.5);
    });

    test('follow=false + prefs 1.5x → 1.5x（手动使用用户设定值）', () async {
      await seedSpeed(1.5);

      await readNotifier().applyTtsSpeedPreference(followSystem: false);

      expect(readState().config.speed, 1.5);
    });

    test('follow=true + 从未设置 → 引擎默认 1.0x', () async {
      readNotifier().updateConfig(speed: 2.0);

      await readNotifier().applyTtsSpeedPreference(followSystem: true);

      expect(readState().config.speed, kEngineDefaultTtsSpeed);
    });

    test('follow=false + 从未设置 → 保持当前语速（不重置为 1.0）', () async {
      readNotifier().updateConfig(speed: 2.0);

      await readNotifier().applyTtsSpeedPreference(followSystem: false);

      expect(readState().config.speed, 2.0);
    });

    test('切换跟随/手动不重置用户语速', () async {
      await seedSpeed(1.5);

      await readNotifier().applyTtsSpeedPreference(followSystem: true);
      expect(readState().config.speed, 1.5);

      await readNotifier().applyTtsSpeedPreference(followSystem: false);
      expect(readState().config.speed, 1.5, reason: '切到手动不得重置语速');

      await readNotifier().applyTtsSpeedPreference(followSystem: true);
      expect(readState().config.speed, 1.5, reason: '切回跟随应为用户语速');
    });

    test('音调/音量既有行为不变（只解析语速）', () async {
      await seedSpeed(1.5);
      readNotifier().updateConfig(pitch: 1.2, volume: 0.8);

      await readNotifier().applyTtsSpeedPreference(followSystem: true);

      final cfg = readState().config;
      expect(cfg.speed, 1.5);
      expect(cfg.pitch, 1.2);
      expect(cfg.volume, 0.8);
    });

    test('不触发书级 playSpeed 回写（读回偏好不等于用户调整）', () async {
      await seedSpeed(1.5);
      readNotifier().bindBook(const Book(bookUrl: 'u', name: '书'));

      await readNotifier().applyTtsSpeedPreference(followSystem: true);

      expect(readState().config.speed, 1.5);
      verifyNever(() => api.updateBook(any()));
    });
  });
}
