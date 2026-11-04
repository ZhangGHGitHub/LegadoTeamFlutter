// [批4b] 自定义翻页键 Sheet / 入口测试
//
// 编写：全栈工程师（批4b） ｜ 2026-11-04
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/page_key_config_sheet.dart';
import 'package:flutter_legado/src/screens/read_config_screen.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/utils/page_key_codes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlatformBridgeService.instance.volumeKeyCaptureOverride = true;
  });

  tearDown(() async {
    await PlatformBridgeService.instance.setKeyRecording(false);
    PlatformBridgeService.instance.volumeKeyCaptureOverride = null;
  });

  Widget sheetHarness(ReaderAdvancedConfig config, ValueChanged<ReaderAdvancedConfig> onChanged) {
    return MaterialApp(
      home: Scaffold(
        body: PageKeyConfigSheet(config: config, onChanged: onChanged),
      ),
    );
  }

  testWidgets('录制追加/切换分组/删除/清空/确定保存', (tester) async {
    ReaderAdvancedConfig? updated;
    final cfg = ReaderAdvancedConfig()
      ..prevKeyCodes = '24'
      ..nextKeyCodes = '';
    await tester.pumpWidget(sheetHarness(cfg, (v) => updated = v));
    await tester.pump();
    expect(find.byKey(const ValueKey('page-key-sheet')), findsOneWidget);
    expect(PlatformBridgeService.instance.keyRecording.value, isTrue);
    expect(find.byKey(const ValueKey('page-key-chip-24')), findsOneWidget);

    // 默认上一页组：record 92 追加
    PlatformBridgeService.instance.debugEmitPageKeyRecord(92);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('page-key-chip-92')), findsOneWidget);

    // 切到下一页组：record 25/93
    await tester.tap(find.byKey(const ValueKey('page-key-group-1')));
    await tester.pump();
    PlatformBridgeService.instance.debugEmitPageKeyRecord(25);
    PlatformBridgeService.instance.debugEmitPageKeyRecord(93);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('page-key-chip-25')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-key-chip-93')), findsOneWidget);

    // 删除 92
    final chip92 = tester.widget<InputChip>(
      find.byKey(const ValueKey('page-key-chip-92')),
    );
    chip92.onDeleted!();
    await tester.pump();
    expect(find.byKey(const ValueKey('page-key-chip-92')), findsNothing);

    // 清空上一页组
    await tester.tap(find.byKey(const ValueKey('page-key-clear-0')));
    await tester.pump();
    expect(find.byKey(const ValueKey('page-key-chip-24')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('page-key-confirm')));
    await tester.pump();
    expect(updated, isNotNull);
    expect(PageKeyCodes.parse(updated!.prevKeyCodes), isEmpty);
    expect(PageKeyCodes.parse(updated!.nextKeyCodes), [25, 93]);
  });

  testWidgets('取消不改动原配置；关闭后停止录制', (tester) async {
    ReaderAdvancedConfig? updated;
    final cfg = ReaderAdvancedConfig()..prevKeyCodes = '24';
    await tester.pumpWidget(sheetHarness(cfg, (v) => updated = v));
    await tester.pump();
    PlatformBridgeService.instance.debugEmitPageKeyRecord(92);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('page-key-cancel')));
    await tester.pumpAndSettle();
    expect(updated, isNull);
    expect(PlatformBridgeService.instance.keyRecording.value, isFalse);
    expect(cfg.prevKeyCodes, '24');
  });

  testWidgets('非 Android：提示仅 Android 生效且不进入录制', (tester) async {
    PlatformBridgeService.instance.volumeKeyCaptureOverride = false;
    await tester.pumpWidget(
      sheetHarness(ReaderAdvancedConfig(), (_) {}),
    );
    await tester.pump();
    expect(find.text('仅 Android 生效'), findsOneWidget);
    expect(PlatformBridgeService.instance.keyRecording.value, isFalse);
  });

  testWidgets('阅读器「更多」入口 + 长按开关落盘', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReaderConfigPanel(
                config: ReaderAdvancedConfig(),
                section: ReaderConfigSection.more,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final entry = find.byKey(const ValueKey('reader-page-key-entry'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('page-key-sheet')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('page-key-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final switchFinder = find.byKey(
      const ValueKey('reader-key-page-longpress-switch'),
    );
    await tester.ensureVisible(switchFinder);
    await tester.tap(switchFinder);
    await tester.pump();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('keyPageOnLongPress'), isTrue);
  });

  testWidgets('独立阅读设置页入口打开同一 Sheet', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
        child: const MaterialApp(home: ReadConfigScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('read-config-page-key-entry'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('page-key-sheet')), findsOneWidget);
  });
}
