// [批4b] 自定义/硬编码翻页键 ReaderScreen 事件分流测试
//
// 编写：全栈工程师（批4b） ｜ 2026-11-04
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/screens/reader_screen.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_view.dart';

import '../mocks/mocks.dart';

const _book = Book(
  bookUrl: 'https://book.com/page-key',
  name: '翻页键书',
  author: '作者P',
  origin: 'https://source-p.com',
  originName: '源P',
);
const _chapters = [
  BookChapter(url: 'https://book.com/page-key/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/page-key/c2', title: '第二章', index: 1),
];
final _longContent = List.filled(6000, '测').join();

MockRustApi _stubApi() {
  final api = MockRustApi();
  when(() => api.getChapters(any())).thenAnswer((_) async => _chapters);
  when(
    () => api.getChapterContentFull(any(), any()),
  ).thenAnswer((_) async => _longContent);
  when(() => api.getChapterContent(any(), any())).thenAnswer((_) async => '');
  when(() => api.getBookSources()).thenAnswer((_) async => const []);
  when(() => api.getConfig(any())).thenAnswer((_) async => '');
  when(() => api.getBook(any())).thenAnswer((_) async => _book);
  when(
    () => api.updateReadingProgress(
      bookUrl: any(named: 'bookUrl'),
      chapterIndex: any(named: 'chapterIndex'),
      chapterPos: any(named: 'chapterPos'),
    ),
  ).thenAnswer((_) async {});
  return api;
}

void _mockPrefs({bool volumeKeyPage = false}) {
  SharedPreferences.setMockInitialValues({
    'enableReadRecord': false,
    'sliderVibrator': true,
    'volumeKeyPage': volumeKeyPage,
    'keyPageOnLongPress': false,
    'prevKeyCodes': '92',
    'nextKeyCodes': '93',
  });
}

Future<ProviderContainer> _pumpReader(WidgetTester tester) async {
  final api = _stubApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(api)],
      child: const MaterialApp(home: ReaderScreen()),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(ReaderScreen)),
  );
  await container.read(readerNotifierProvider.notifier).openBook(_book);
  await tester.pumpAndSettle();
  await _applyConfig(container);
  return container;
}

Future<void> _applyConfig(
  ProviderContainer container, {
  bool keyPageOnLongPress = false,
  bool? volumeKeyPage,
}) async {
  final cfg =
      (container.read(readerAdvConfigProvider) ??
              await ReaderAdvancedConfig.load())
          .copy()
        ..keyPageOnLongPress = keyPageOnLongPress
        ..sliderVibrator = true;
  if (volumeKeyPage != null) cfg.volumeKeyPage = volumeKeyPage;
  await cfg.save();
  container.read(readerAdvConfigProvider.notifier).apply(cfg);
}

Future<void> _emitPageKey(
  WidgetTester tester, {
  required String direction,
  required String source,
  bool longPress = false,
}) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'legado/reader_keys',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('pageKey', <String, Object>{
        'direction': direction,
        'longPress': longPress,
        'source': source,
      }),
    ),
    (_) {},
  );
  await tester.pumpAndSettle();
}

void main() {
  late int turns;

  setUp(() {
    turns = 0;
    ReaderPageViewState.onPageTurnedHaptic = () => turns++;
    PlatformBridgeService.instance.volumeKeyCaptureOverride = true;
  });

  tearDown(() {
    ReaderPageViewState.onPageTurnedHaptic = HapticFeedback.selectionClick;
    PlatformBridgeService.instance.volumeKeyCaptureOverride = null;
  });

  testWidgets('custom/hardcoded 绕过 volumeKeyPage；volume 受开关限制', (tester) async {
    _mockPrefs(volumeKeyPage: false);
    await _pumpReader(tester);

    await _emitPageKey(tester, direction: 'down', source: 'custom');
    expect(turns, 1, reason: '自定义键优先且不受 volumeKeyPage 影响');

    await _emitPageKey(tester, direction: 'down', source: 'volume');
    expect(turns, 1, reason: 'volume source 受 volumeKeyPage=false 限制');

    await _emitPageKey(tester, direction: 'up', source: 'hardcoded');
    expect(turns, 2, reason: '硬编码键始终可用');
  });

  testWidgets('volume source 在开关开启时翻页', (tester) async {
    _mockPrefs(volumeKeyPage: true);
    await _pumpReader(tester);
    await _emitPageKey(tester, direction: 'down', source: 'volume');
    expect(turns, 1);
  });

  testWidgets('菜单展开时 custom/hardcoded 不翻页', (tester) async {
    _mockPrefs();
    final container = await _pumpReader(tester);
    container.read(readerNotifierProvider.notifier).toggleControls();
    await tester.pumpAndSettle();

    await _emitPageKey(tester, direction: 'down', source: 'custom');
    await _emitPageKey(tester, direction: 'down', source: 'hardcoded');
    expect(turns, 0);
  });

  testWidgets('keyPageOnLongPress=false 忽略 repeat；true 逐次翻页', (tester) async {
    _mockPrefs();
    final container = await _pumpReader(tester);

    await _emitPageKey(
      tester,
      direction: 'down',
      source: 'custom',
      longPress: true,
    );
    expect(turns, 0, reason: '默认长按 repeat 忽略');

    await _applyConfig(container, keyPageOnLongPress: true);
    await _emitPageKey(
      tester,
      direction: 'down',
      source: 'custom',
      longPress: true,
    );
    expect(turns, 1, reason: '开启后 repeat 翻页');
  });

  testWidgets('录制态在菜单展开时重新开启捕获', (tester) async {
    _mockPrefs();
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('legado/reader_keys'),
      (call) async {
        calls.add(call);
        return true;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('legado/reader_keys'),
        null,
      );
    });
    final container = await _pumpReader(tester);
    container.read(readerNotifierProvider.notifier).toggleControls();
    await tester.pumpAndSettle();
    List<MethodCall> captures() => calls
        .where((c) => c.method == 'setVolumeKeyCapture')
        .toList(growable: false);
    expect(captures().last.arguments, isFalse, reason: '菜单展开释放捕获');

    await PlatformBridgeService.instance.setKeyRecording(true);
    await tester.pumpAndSettle();
    expect(
      captures().last.arguments,
      isTrue,
      reason: '录制态即使菜单展开也要捕获 recordKey',
    );

    await PlatformBridgeService.instance.setKeyRecording(false);
    await tester.pumpAndSettle();
    expect(captures().last.arguments, isFalse, reason: '录制结束回到菜单门控');
  });

  testWidgets('子路由压栈时 page 键不翻页；返回后恢复', (tester) async {
    _mockPrefs();
    final container = await _pumpReader(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('目录'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _emitPageKey(tester, direction: 'down', source: 'custom');
    expect(turns, 0);

    navigator.pop();
    await tester.pumpAndSettle();
    await _emitPageKey(tester, direction: 'down', source: 'custom');
    expect(turns, 1);
    container.read(readerNotifierProvider.notifier).hideControls();
  });
}
