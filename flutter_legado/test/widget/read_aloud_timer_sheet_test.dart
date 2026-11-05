// 统一朗读定时 Sheet 测试（设置批5c）
//
// 覆盖：
// 1) 分钟/章节页签互斥，章节模式隐藏「读完本章再停」并说明原因；
// 2) 预设 Chip 与滑块写入设置值（分钟 0–180 / 章节 0–50）；
// 3) 开始 / 取消 / 停止定时三个动作；
// 4) 持久化回显：模式/分钟/章节/开关，重启只回显不恢复倒计时；
// 5) 运行中显示剩余量，切换模式后由 Notifier 单一数据源更新。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/read_aloud_timer_settings.dart';
import 'package:flutter_legado/src/widgets/read_aloud_timer_sheet.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi api;
  late FakeStreamAudioPlayer fakePlayer;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockRustApi();
    fakePlayer = FakeStreamAudioPlayer();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        streamAudioPlayerProvider.overrideWithValue(fakePlayer),
      ],
    );
    addTearDown(container.dispose);

    when(() => api.getConfig(any())).thenAnswer((_) async => null);
    when(() => api.getChapters(any())).thenAnswer(
      (_) async => [
        const BookChapter(title: '第一章', index: 0),
        const BookChapter(title: '第二章', index: 1),
      ],
    );
    when(() => api.getBook(any())).thenAnswer((_) async => null);
  });

  AudioNotifier readNotifier() =>
      container.read(audioNotifierProvider.notifier);

  Widget host() {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showReadAloudTimerSheet(context),
                child: const Text('打开定时'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 打开 Sheet：helper 先异步读取持久化设置，再弹 bottom sheet。
  Future<void> openSheet(
    WidgetTester tester, {
    Size size = const Size(1000, 1800),
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(host());
    await tester.tap(find.text('打开定时'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> tapChip(WidgetTester tester, String label) async {
    final target = find.widgetWithText(ChoiceChip, label);
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await tester.pump();
  }

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  testWidgets('分钟/章节页签互斥；章节模式隐藏「读完本章再停」并说明', (tester) async {
    await openSheet(tester);
    expect(
      find.byKey(const ValueKey('read-aloud-timer-minute-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('read-aloud-timer-finish-chapter-switch')),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(Tab, '章节'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('read-aloud-timer-chapter-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('read-aloud-timer-finish-chapter-switch')),
      findsNothing,
    );
    expect(find.text('章节模式会在读完设定章数后的章末停止，无需「读完本章再停」。'), findsOneWidget);
    expect(
      (await prefs()).getString(PrefKeys.readAloudTimerMode),
      ReadAloudTimerMode.chapter.storageValue,
    );

    await tester.tap(find.widgetWithText(Tab, '分钟'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('read-aloud-timer-finish-chapter-switch')),
      findsOneWidget,
    );
    expect(
      (await prefs()).getString(PrefKeys.readAloudTimerMode),
      ReadAloudTimerMode.minute.storageValue,
    );
  });

  testWidgets('预设与滑块写入设置值；开始后回调 Notifier', (tester) async {
    await openSheet(tester);
    await tapChip(tester, '30 分钟');
    expect((await prefs()).getInt(PrefKeys.readAloudTimerMinutes), 30);
    expect(find.text('30 分钟'), findsWidgets);

    // 滑块（45 分钟）：拖动中只更新 UI，松手写设置
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('read-aloud-timer-minutes-slider')),
    );
    slider.onChanged!(45);
    await tester.pump();
    expect((await prefs()).getInt(PrefKeys.readAloudTimerMinutes), 30);
    slider.onChangeEnd!(45);
    await tester.pump();
    expect((await prefs()).getInt(PrefKeys.readAloudTimerMinutes), 45);

    await tester.tap(find.widgetWithText(FilledButton, '开始'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ReadAloudTimerSheet), findsNothing);
    expect(readNotifier().sleepRemainingSeconds, 45 * 60);

    readNotifier().cancelSleepTimer();
  });

  testWidgets('「读完本章再停」开关写入设置并同步 Notifier 镜像', (tester) async {
    await openSheet(tester);
    final switchFinder = find.byKey(
      const ValueKey('read-aloud-timer-finish-chapter-switch'),
    );
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);

    await tapChip(tester, '10 分钟');
    await tester.tap(switchFinder);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
    expect(
      (await prefs()).getBool(PrefKeys.finishCurrentChapterAfterTimer),
      isTrue,
    );
    expect(readNotifier().finishCurrentChapterAfterTimer, isTrue);

    await tester.tap(find.widgetWithText(FilledButton, '开始'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(readNotifier().sleepRemainingSeconds, 10 * 60);
    expect(readNotifier().finishCurrentChapterAfterTimer, isTrue);

    readNotifier().cancelSleepTimer();
  });

  testWidgets('取消不启动；运行中可停止定时', (tester) async {
    await openSheet(tester);
    await tapChip(tester, '10 分钟');
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ReadAloudTimerSheet), findsNothing);
    expect(readNotifier().isSleepTimerActive, isFalse);

    // 已启动后重开：显示剩余量 + 停止按钮
    readNotifier().startSleepTimer(10);
    await tester.tap(find.text('打开定时'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('剩余 10:00'), findsOneWidget);
    expect(find.text('停止定时'), findsOneWidget);

    await tester.tap(find.text('停止定时'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(readNotifier().isSleepTimerActive, isFalse);
    expect(find.byType(ReadAloudTimerSheet), findsNothing);
  });

  testWidgets('持久化回显：章节模式/章数/开关；重启只回显不恢复倒计时', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.readAloudTimerMode: ReadAloudTimerMode.chapter.storageValue,
      PrefKeys.readAloudTimerMinutes: 20,
      PrefKeys.readAloudTimerChapters: 5,
      PrefKeys.finishCurrentChapterAfterTimer: true,
    });
    await openSheet(tester);

    // 章节页签回显（TabBar 选中 + 预设 Chip 选中）
    expect(
      find.byKey(const ValueKey('read-aloud-timer-chapter-panel')),
      findsOneWidget,
    );
    final chapterSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('read-aloud-timer-chapters-slider')),
    );
    expect(chapterSlider.value, 5);
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '5 章'),
    );
    expect(chip.selected, isTrue);

    // 重启语义：设置值可回显，但运行中倒计时不会自动恢复
    final config = await ReadAloudTimerSettings.load();
    expect(config.mode, ReadAloudTimerMode.chapter);
    expect(config.minutes, 20);
    expect(config.chapters, 5);
    expect(config.finishCurrentChapterAfterTimer, isTrue);
    expect(readNotifier().isSleepTimerActive, isFalse);

    await tester.tap(find.widgetWithText(FilledButton, '开始'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(readNotifier().sleepTimerMode, SleepTimerMode.chapters);
    expect(readNotifier().chaptersToStopRemaining, 5);
    readNotifier().cancelSleepTimer();
  });

  testWidgets('分钟模式回显分钟值与开关', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.readAloudTimerMode: ReadAloudTimerMode.minute.storageValue,
      PrefKeys.readAloudTimerMinutes: 20,
      PrefKeys.finishCurrentChapterAfterTimer: true,
    });
    await openSheet(tester);
    final minuteSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('read-aloud-timer-minutes-slider')),
    );
    expect(minuteSlider.value, 20);
    final switchFinder = find.byKey(
      const ValueKey('read-aloud-timer-finish-chapter-switch'),
    );
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
  });

  testWidgets('320dp + 1.6 字体：底部按钮换行不溢出', (tester) async {
    await openSheet(tester, size: const Size(320, 1800), textScale: 1.6);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('read-aloud-timer-start-button')),
      findsOneWidget,
    );
    expect(find.text('取消'), findsOneWidget);
  });
}
