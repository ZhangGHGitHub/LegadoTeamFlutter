// 阅读主题（批38）单测
//
// 覆盖：内置预设色对齐参考版、序列化往返、非法 JSON 拒绝、名称冲突后缀、
// 新建/重命名/删除/排序/置顶置底、网格列数持久化、当前主题与定位下标、
// 导出-导入往返、备份偏好透传（另见 restore_ignore_prefs_test）、
// 网格列数渲染与当前标记（widget）。
//
// 编写：全栈工程师（批38） ｜ 2026-10-29
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/reader_theme.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart'
    show ReaderBackground;
import 'package:flutter_legado/src/providers/reader/reader_theme_notifier.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/screens/reader_theme_screen.dart';
import 'package:flutter_legado/src/services/reader_theme_service.dart';

/// 等待主题 provider 完成首次异步加载
Future<void> waitThemeLoaded(ProviderContainer container) async {
  for (var i = 0; i < 100; i++) {
    if (container.read(readerThemeProvider).loaded) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('ReaderThemeProvider 超时未完成加载');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('内置主题（对齐参考版预设色）', () {
    test('5 份内置主题且全部钉死', () {
      expect(kBuiltInReaderThemes, hasLength(5));
      expect(
        [for (final theme in kBuiltInReaderThemes) theme.name],
        ['微信读书', '预设1', '预设2', '预设3', '预设4'],
      );
      expect(
        [for (final theme in kBuiltInReaderThemes) theme.style.backgroundColor],
        [0xFFC0EDC6, 0xFFFFFFFF, 0xFFDDC090, 0xFFC2D8AA, 0xFFDBB8E2],
      );
      expect(kBuiltInReaderThemeIds, hasLength(5));
      expect(kBuiltInReaderThemes.every((theme) => theme.builtIn), isTrue);
    });

    test('微信读书字号/行距/边距对齐参考 readConfig.json', () {
      final theme = kBuiltInReaderThemes.first;
      expect(theme.style.fontSize, 24.0);
      expect(theme.style.lineHeight, closeTo(1.42, 0.001));
      expect(theme.style.marginTop, 5.0);
      expect(theme.style.marginBottom, 4.0);
      expect(theme.style.marginLeft, 22.0);
      expect(theme.style.marginRight, 22.0);
      expect(theme.style.textColor, 0xFF0B0B0B);
    });
  });

  group('模型序列化', () {
    test('单份主题 JSON 往返保真', () {
      const original = ReaderTheme(
        id: 'theme-test',
        name: '柔和绿',
        style: ReaderThemeStyle(
          fontSize: 22.0,
          lineHeight: 1.8,
          backgroundColor: 0xFFC2D8AA,
          textColor: 0xFF596C44,
          fontFamily: 'Custom_TestFont',
          titleFont: 'serif',
          letterSpacing: 0.2,
          paragraphIndent: 3,
          paragraphSpacing: 6.0,
          marginTop: 30.0,
          marginBottom: 28.0,
          marginLeft: 18.0,
          marginRight: 16.0,
          textBold: 1,
          italic: true,
          bgImage: 'bg/demo.png',
        ),
      );
      final encoded = ReaderThemeCodec.encode(original);
      expect(encoded, contains('"type": "legado.readerTheme"'));
      expect(encoded, contains('#FFC2D8AA'));
      final decoded = ReaderThemeCodec.decodeAll(encoded).single;
      expect(decoded.name, original.name);
      expect(decoded.style, original.style);
    });

    test('6 位颜色补 FF；自动文字色往返为 0', () {
      expect(decodeReaderThemeColor('#C0EDC6'), 0xFFC0EDC6);
      expect(decodeReaderThemeColor(0x80112233), 0x80112233);
      final style = ReaderThemeStyle.fromJson(<String, dynamic>{
        'backgroundColor': '#C0EDC6',
        'textColor': null,
      });
      expect(style.backgroundColor, 0xFFC0EDC6);
      expect(style.textColor, 0);
      expect((style.toJson()['textColor']), isNull);
    });

    test('越界字段读取收敛到阅读页范围', () {
      final style = ReaderThemeStyle.fromJson(<String, dynamic>{
        'fontSize': 99,
        'lineHeight': 8,
        'letterSpacing': 9,
        'paragraphIndent': 9,
        'paragraphSpacing': 999,
        'marginTop': 9999,
        'marginLeft': -5,
        'textBold': 9,
      });
      expect(style.fontSize, 50.0);
      expect(style.lineHeight, 3.0);
      expect(style.letterSpacing, 1.0);
      expect(style.paragraphIndent, 3);
      expect(style.paragraphSpacing, 48.0);
      expect(style.marginTop, 400.0);
      expect(style.marginLeft, 0.0);
      expect(style.textBold, 2);
    });

    test('非法 JSON / 缺名称 / 缺样式 / 颜色非法均抛 FormatException', () {
      expect(
        () => ReaderThemeCodec.decodeAll('not json'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ReaderThemeCodec.decodeAll('{"style": {}}'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ReaderThemeCodec.decodeAll('{"name": "x"}'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ReaderThemeCodec.decodeAll(
          '{"name": "x", "style": {"backgroundColor": "red"}}',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ReaderThemeCodec.decodeAll(
          '{"name": "x", "style": {"fontSize": "big"}}',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ReaderThemeCodec.decodeAll('[]'),
        throwsA(isA<FormatException>()),
      );
    });

    test('本地持久化列表宽松解码：坏条目跳过', () {
      final raw = '[{"name":"好","style":{}},{"bad":1},42]';
      final decoded = ReaderThemeCodec.decodeStoredList(raw);
      expect(decoded, hasLength(1));
      expect(decoded.single.name, '好');
      expect(ReaderThemeCodec.decodeStoredList('broken'), isEmpty);
    });
  });

  group('名称冲突后缀', () {
    test('无冲突保持原名，冲突依次加 (2)/(3)', () {
      expect(uniqueReaderThemeName('柔和绿', <String>['预设1']), '柔和绿');
      expect(uniqueReaderThemeName('预设1', <String>['预设1']), '预设1 (2)');
      expect(
        uniqueReaderThemeName('预设1', <String>['预设1', '预设1 (2)', '预设1 (3)']),
        '预设1 (4)',
      );
    });

    test('空白名称回落「阅读主题」', () {
      expect(uniqueReaderThemeName('   ', const <String>[]), '阅读主题');
      expect(uniqueReaderThemeName('', <String>['阅读主题']), '阅读主题 (2)');
    });
  });

  group('主题存储服务', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('列数默认 4，写入收敛到 2..6', () async {
      final service = ReaderThemeService();
      expect(await service.loadGridColumns(), 4);
      await service.saveGridColumns(9);
      expect(await service.loadGridColumns(), 6);
      await service.saveGridColumns(0);
      expect(await service.loadGridColumns(), 2);
      expect(ReaderThemeService.normalizeGridColumns(3), 3);
    });

    test('自建主题落盘只含自建条目，重启后可恢复', () async {
      final service = ReaderThemeService();
      final theme = ReaderThemeService.createTheme(
        name: '我的主题',
        style: const ReaderThemeStyle(backgroundColor: 0xFF123456),
        existingNames: <String>['预设1'],
      );
      await service.saveCustomThemes(<ReaderTheme>[theme]);
      await service.saveCurrentId(theme.id);

      final reloaded = ReaderThemeService();
      final themes = await reloaded.loadCustomThemes();
      expect(themes, hasLength(1));
      expect(themes.single.name, '我的主题');
      expect(themes.single.id, theme.id);
      expect(themes.single.builtIn, isFalse);
      expect(await reloaded.loadCurrentId(), theme.id);

      final merged = ReaderThemeService.mergeThemes(themes);
      expect(merged, hasLength(6));
      expect(merged.first.builtIn, isTrue);
      expect(merged.last.name, '我的主题');
    });

    test('导出-导入往返：样式保真且名称冲突加后缀', () {
      final source = ReaderThemeService.createTheme(
        name: '往返主题',
        style: const ReaderThemeStyle(
          fontSize: 26,
          backgroundColor: 0xFFABCEE0,
          textColor: 0xFF3D4C54,
          marginLeft: 30,
        ),
        existingNames: const <String>[],
      );
      final raw = ReaderThemeCodec.encode(source);
      final imported = ReaderThemeService.importThemes(
        raw,
        existingNames: <String>['往返主题'],
      );
      expect(imported, hasLength(1));
      expect(imported.single.name, '往返主题 (2)');
      expect(imported.single.id, isNot(source.id), reason: '导入必须重新分配 id');
      expect(imported.single.style, source.style);
    });

    test('批量导入数组：逐份名称去重', () {
      const raw =
          '['
          '{"name":"A","style":{"backgroundColor":"#FFFFFF"}},'
          '{"name":"A","style":{"backgroundColor":"#000000"}}'
          ']';
      final imported = ReaderThemeService.importThemes(
        raw,
        existingNames: const <String>[],
      );
      expect([for (final theme in imported) theme.name], ['A', 'A (2)']);
      expect(imported[1].style.backgroundColor, 0xFF000000);
    });
  });

  group('应用主题的排版落点', () {
    test('背景落点：命中既有预设走索引，未命中按自定义（chip 兼容）', () {
      final presetArgb = ReaderBackground.presets
          .map((color) => color.toARGB32())
          .toList();
      expect(
        const ReaderThemeStyle(
          backgroundColor: 0xFFFFFFFF,
        ).presetBackgroundIndex(presetArgb),
        0,
        reason: '预设1 纯白 = 既有白色预设',
      );
      expect(
        const ReaderThemeStyle(
          backgroundColor: 0xFF1A1A1A,
        ).presetBackgroundIndex(presetArgb),
        4,
        reason: '纯黑 = 既有夜间预设',
      );
      expect(
        const ReaderThemeStyle(
          backgroundColor: 0xFFC0EDC6,
        ).presetBackgroundIndex(presetArgb),
        -1,
        reason: '微信读书浅绿不在既有预设色内 → 自定义 chip',
      );
      expect(
        const ReaderThemeStyle(
          backgroundColor: 0xFFDBB8E2,
        ).presetBackgroundIndex(presetArgb),
        -1,
        reason: '预设4 浅紫不在既有预设色内 → 自定义 chip',
      );
    });

    test('withThemeStyle 覆盖排版字段且不动其它阅读偏好', () {
      final base = ReaderAdvancedConfig()
        ..autoPageTurn = true
        ..autoPageTurnInterval = 30
        ..hideStatusBar = true;
      const style = ReaderThemeStyle(
        textColor: 0xFF596C44,
        titleFont: 'serif',
        letterSpacing: 0.3,
        paragraphIndent: 3,
        paragraphSpacing: 8,
        marginTop: 10,
        marginBottom: 12,
        marginLeft: 14,
        marginRight: 16,
        textBold: 2,
        italic: true,
      );
      final applied = base.withThemeStyle(style);
      expect(applied.customTextColor, 0xFF596C44);
      expect(applied.titleFont, 'serif');
      expect(applied.letterSpacing, 0.3);
      expect(applied.paragraphIndent, 3);
      expect(applied.paragraphSpacing, 8);
      expect(applied.pageMarginTop, 10);
      expect(applied.pageMarginBottom, 12);
      expect(applied.pageMarginLeft, 14);
      expect(applied.pageMarginRight, 16);
      expect(applied.textBold, 2);
      expect(applied.italic, isTrue);
      // 非主题字段保持
      expect(applied.autoPageTurn, isTrue);
      expect(applied.autoPageTurnInterval, 30);
      expect(applied.hideStatusBar, isTrue);
      // 原实例不被修改
      expect(base.customTextColor, 0);
      expect(base.pageMarginTop, 24);
    });
  });

  group('主题 Provider 操作', () {
    late ProviderContainer container;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('首次加载：内置 5 份、当前 id 空、列数 4', () async {
      await waitThemeLoaded(container);
      final state = container.read(readerThemeProvider);
      expect(state.themes, hasLength(5));
      expect(state.customThemes, isEmpty);
      expect(state.currentTheme, isNull);
      expect(state.currentIndex, -1);
      expect(state.gridColumns, 4);
    });

    test('新建：冲突名称加后缀、落盘、当前主题可标记与定位', () async {
      await waitThemeLoaded(container);
      final notifier = container.read(readerThemeProvider.notifier);

      final first = await notifier.addTheme(
        name: '预设1',
        style: const ReaderThemeStyle(backgroundColor: 0xFF101010),
      );
      final second = await notifier.addTheme(
        name: '预设1',
        style: const ReaderThemeStyle(backgroundColor: 0xFF202020),
      );
      expect(first.name, '预设1 (2)');
      expect(second.name, '预设1 (3)');

      await notifier.markCurrent(second.id);
      var state = container.read(readerThemeProvider);
      expect(state.currentTheme?.id, second.id);
      expect(state.currentIndex, 6);

      // 新容器从 prefs 恢复
      final reloaded = ProviderContainer();
      addTearDown(reloaded.dispose);
      await waitThemeLoaded(reloaded);
      final restored = reloaded.read(readerThemeProvider);
      expect(restored.customThemes.map((t) => t.name), ['预设1 (2)', '预设1 (3)']);
      expect(restored.currentId, second.id);
    });

    test('重命名：内置不可改、自建可改', () async {
      await waitThemeLoaded(container);
      final notifier = container.read(readerThemeProvider.notifier);
      final theme = await notifier.addTheme(
        name: '旧名',
        style: const ReaderThemeStyle(),
      );
      expect(
        await notifier.renameTheme(kBuiltInReaderThemes.first.id, '新名'),
        isFalse,
      );
      expect(await notifier.renameTheme(theme.id, '  新名  '), isTrue);
      final renamed = container
          .read(readerThemeProvider)
          .themes
          .firstWhere((item) => item.id == theme.id);
      expect(renamed.name, '新名');
      expect(await notifier.renameTheme(theme.id, '   '), isFalse);
    });

    test('删除：内置不可删、删除当前主题清空当前 id', () async {
      await waitThemeLoaded(container);
      final notifier = container.read(readerThemeProvider.notifier);
      final a = await notifier.addTheme(
        name: 'A',
        style: const ReaderThemeStyle(),
      );
      final b = await notifier.addTheme(
        name: 'B',
        style: const ReaderThemeStyle(),
      );
      await notifier.markCurrent(b.id);

      expect(
        await notifier.deleteThemes(<String>{kBuiltInReaderThemes.first.id}),
        0,
      );
      expect(await notifier.deleteThemes(<String>{b.id}), 1);
      final state = container.read(readerThemeProvider);
      expect(state.customThemes.map((t) => t.id), [a.id]);
      expect(state.currentId, '');
      expect(state.themes, hasLength(6));
    });

    test('排序：上下移只在自建区、置顶置底保持选中实例', () async {
      await waitThemeLoaded(container);
      final notifier = container.read(readerThemeProvider.notifier);
      final a = await notifier.addTheme(
        name: 'A',
        style: const ReaderThemeStyle(),
      );
      final b = await notifier.addTheme(
        name: 'B',
        style: const ReaderThemeStyle(),
      );
      final c = await notifier.addTheme(
        name: 'C',
        style: const ReaderThemeStyle(),
      );

      expect(await notifier.moveTheme(a.id, -1), isFalse, reason: '不能插到内置区前');
      expect(await notifier.moveTheme(c.id, 1), isFalse, reason: '已在末尾');

      expect(await notifier.moveTheme(c.id, -1), isTrue);
      expect(
        container.read(readerThemeProvider).customThemes.map((t) => t.name),
        ['A', 'C', 'B'],
      );

      await notifier.moveThemesToEdge(<String>{c.id}, toTop: true);
      expect(
        container.read(readerThemeProvider).customThemes.map((t) => t.name),
        ['C', 'A', 'B'],
      );
      await notifier.moveThemesToEdge(<String>{c.id}, toTop: false);
      expect(
        container.read(readerThemeProvider).customThemes.map((t) => t.name),
        ['A', 'B', 'C'],
      );
      expect(b.id, isNot(c.id));
    });

    test('列数持久化：Provider 写入后被新容器恢复', () async {
      await waitThemeLoaded(container);
      await container.read(readerThemeProvider.notifier).setGridColumns(6);
      expect(container.read(readerThemeProvider).gridColumns, 6);

      final reloaded = ProviderContainer();
      addTearDown(reloaded.dispose);
      await waitThemeLoaded(reloaded);
      expect(reloaded.read(readerThemeProvider).gridColumns, 6);
    });

    test('导入非法 JSON 不动现有列表；导入成功追加并加后缀', () async {
      await waitThemeLoaded(container);
      final notifier = container.read(readerThemeProvider.notifier);
      await notifier.addTheme(name: '已有', style: const ReaderThemeStyle());
      await expectLater(
        notifier.importThemes('{"name":"坏","style":{"fontSize":"x"}}'),
        throwsA(isA<FormatException>()),
      );
      expect(
        container.read(readerThemeProvider).customThemes.map((t) => t.name),
        ['已有'],
      );

      final imported = await notifier.importThemes(
        '{"name":"已有","style":{"backgroundColor":"#123456"}}',
      );
      expect(imported.single.name, '已有 (2)');
      expect(
        container.read(readerThemeProvider).customThemes.map((t) => t.name),
        ['已有', '已有 (2)'],
      );
    });

    test('恢复默认：清空自建与当前 id，保留内置', () async {
      await waitThemeLoaded(container);
      final notifier = container.read(readerThemeProvider.notifier);
      final theme = await notifier.addTheme(
        name: '临时',
        style: const ReaderThemeStyle(),
      );
      await notifier.markCurrent(theme.id);
      await notifier.restoreDefaults();
      final state = container.read(readerThemeProvider);
      expect(state.themes, hasLength(5));
      expect(state.customThemes, isEmpty);
      expect(state.currentId, '');
    });
  });

  group('主题列表 UI', () {
    testWidgets('网格列数 2..6 生效并标记当前主题', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderThemeGrid(
              themes: kBuiltInReaderThemes,
              columns: 5,
              currentId: 'builtin-preset-2',
              manageMode: false,
              selectedIds: const <String>{},
              controller: controller,
              itemKeyBuilder: (id) => GlobalKey(),
              onTap: (_) {},
              onLongPress: (_) {},
              showAddTile: true,
              onAdd: () {},
            ),
          ),
        ),
      );
      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 5);
      expect(
        find.byKey(const ValueKey<String>('theme-current-builtin-preset-2')),
        findsOneWidget,
      );
      expect(find.text('新建主题'), findsOneWidget);
    });

    testWidgets('管理态显示内置锁标记与勾选徽章', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderThemeGrid(
              themes: kBuiltInReaderThemes,
              columns: 6,
              currentId: '',
              manageMode: true,
              selectedIds: const <String>{'builtin-preset-3'},
              controller: controller,
              itemKeyBuilder: (id) => GlobalKey(),
              onTap: (_) {},
              onLongPress: (_) {},
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(5));
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });
  });
}
