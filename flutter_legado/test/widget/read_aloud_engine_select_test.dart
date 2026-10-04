// P0 缺陷回归：朗读条引擎选择器（2026-10-03）
//
// 背景：选择器曾把 '名称,URL' 复合串存入 TtsConfig.engineUrl，Rust tts_speak
// 把该值当 URL 模板与缓存键 → 选完引擎合成仍失败、朗读降级。修复后统一存裸
// URL；对话框当前项高亮改按 URL 匹配（不再 split(',') 取名）。
//
// 本用例走真实交互路径（点开引擎对话框 → 选中引擎），断言：
// 1) 选中后 config.engineUrl == engine.url（不含逗号）；
// 2) 重开对话框：当前引擎按裸 URL 匹配高亮；
// 3) 存量「名称,URL」形态也能正确高亮（显示侧归一）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/widgets/reader/read_aloud_bar.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  const engineName = '本地引擎';
  const engineUrl = 'http://192.168.1.2:8770/tts?text={{text}}';

  late MockRustApi api;
  late MockAudioService audioService;
  late FakeStreamAudioPlayer fakePlayer;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockRustApi();
    audioService = MockAudioService();
    fakePlayer = FakeStreamAudioPlayer();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        streamAudioPlayerProvider.overrideWithValue(fakePlayer),
        audioServiceProvider.overrideWithValue(audioService),
      ],
    );
    addTearDown(container.dispose);

    when(() => api.getConfig(any())).thenAnswer((_) async => null);
    when(() => api.getHttpTts()).thenAnswer(
      (_) async => [const HttpTts(id: 1, name: engineName, url: engineUrl)],
    );
    when(() => audioService.dispose()).thenAnswer((_) async {});
  });

  Future<void> pumpBar(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ReadAloudBar(
                  onDismiss: () {},
                  onOpenCatalog: () {},
                  onBackstage: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openEngineDialog(WidgetTester tester) async {
    await tester.tap(find.byTooltip('选择朗读引擎'));
    await tester.pumpAndSettle();
    expect(find.text('选择朗读引擎'), findsOneWidget);
  }

  /// 让 SnackBar 自动关闭计时器走完，避免用例结束残留 pending timer
  Future<void> settleSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('选中引擎后 engineUrl 存裸 URL（不含逗号）', (tester) async {
    await pumpBar(tester);
    await openEngineDialog(tester);

    await tester.tap(find.text(engineName));
    await tester.pumpAndSettle();

    final stored = container.read(audioNotifierProvider).config.engineUrl;
    expect(stored, engineUrl);
    expect(stored.contains(','), isFalse);
    expect(find.text('已切换引擎：$engineName'), findsOneWidget);

    await settleSnackBar(tester);
  });

  testWidgets('重开对话框：当前引擎按裸 URL 匹配高亮', (tester) async {
    await pumpBar(tester);
    container.read(audioNotifierProvider.notifier).updateConfig(
          engineUrl: engineUrl,
        );
    await tester.pump();

    await openEngineDialog(tester);

    final group = tester.widget<RadioGroup<String>>(
      find.byType(RadioGroup<String>),
    );
    expect(group.groupValue, engineName);

    // 关闭对话框：点选当前项（幂等，仍写入裸 URL）
    await tester.tap(find.text(engineName));
    await tester.pumpAndSettle();
    await settleSnackBar(tester);
  });

  testWidgets('点击已选中的引擎项：对话框关闭（已项不再吞点击）', (tester) async {
    await pumpBar(tester);
    container.read(audioNotifierProvider.notifier).updateConfig(
          engineUrl: engineUrl,
        );
    await tester.pump();

    await openEngineDialog(tester);
    expect(find.text('选择朗读引擎'), findsOneWidget);

    // 已选中项：RadioListTile 默认对 checked 直接 return（本版无 onTap 参数）；
    // 修复后（toggleable + onChanged 兜底当前项）点击应关闭对话框
    await tester.tap(find.text(engineName));
    await tester.pumpAndSettle();

    expect(find.text('选择朗读引擎'), findsNothing);
    await settleSnackBar(tester);
  });

  testWidgets('存量「名称,URL」形态：显示侧归一并正确高亮', (tester) async {
    await pumpBar(tester);
    container.read(audioNotifierProvider.notifier).updateConfig(
          engineUrl: '$engineName,$engineUrl',
        );
    await tester.pump();

    await openEngineDialog(tester);

    final group = tester.widget<RadioGroup<String>>(
      find.byType(RadioGroup<String>),
    );
    expect(group.groupValue, engineName);

    // 关闭对话框：RadioGroup 对已选中项不再回调 onChanged，点遮罩收起
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });
}
