// 阅读主题（批38）单测
//
// 覆盖：内置预设色对齐参考版、序列化往返、颜色编解码闭环（负 int/超 32 位
// 掩码）、导入 BOM 兼容、非法 JSON 拒绝、名称冲突后缀（含重命名）、
// 新建/重命名/删除/排序/置顶置底、网格列数持久化、当前主题与定位下标、
// 导入/导出往返、首载竞态（磁盘主题库不被空状态覆盖）、应用主题全字段
// 写回、恢复默认（清空自建 + 应用预设1）、400 项惰性网格定位、
// 整卡点击、加载中入口禁用、备份偏好透传（另见 restore_ignore_prefs_test）。
//
// 编写：全栈工程师（批38） ｜ 2026-10-29（批38b 回修补测）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/reader_theme.dart';
import 'package:flutter_legado/src/providers/providers.dart'
    show bookApiProvider;
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart'
    show ReaderBackground, readerNotifierProvider;
import 'package:flutter_legado/src/providers/reader/reader_theme_notifier.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/screens/reader_theme_screen.dart';
import 'package:flutter_legado/src/services/reader_theme_service.dart';

import '../mocks/mocks.dart';

/// 等待主题 provider 完成首次异步加载
Future<void> waitThemeLoaded(ProviderContainer container) async {
  for (var i = 0; i < 100; i++) {
    if (container.read(readerThemeProvider).loaded) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('ReaderThemeProvider 超时未完成加载');
}

/// 轮询直到条件成立（每轮推进一帧并让出 microtask）
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String? reason,
  int maxFrames = 300,
}) async {
  for (var i = 0; i < maxFrames; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 10));
  }
  fail(reason ?? '等待条件超时');
}

/// 轮询直到目标控件出现
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 300,
}) async {
  await pumpUntil(
    tester,
    () => finder.evaluate().isNotEmpty,
    reason: '等待控件超时：$finder',
    maxFrames: maxFrames,
  );
}

/// 渲染阅读主题页并返回其 [ProviderContainer]
Future<ProviderContainer> pumpThemeScreen(
  WidgetTester tester, {
  List<Override> overrides = const <Override>[],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MaterialApp(home: ReaderThemeScreen()),
    ),
  );
  return ProviderScope.containerOf(
    tester.element(find.byType(ReaderThemeScreen)),
  );
}

/// 永不完成首载的 Notifier：模拟「加载中」UI 态（批38b P2-1 门禁用例）
class _NeverLoadingThemeNotifier extends ReaderThemeNotifier {
  @override
  ReaderThemeState build() => const ReaderThemeState(
    themes: kBuiltInReaderThemes,
  );
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

  group('颜色编解码闭环（批38b P1-1）', () {
    test('负 int 编码为 8 位 hex，可被解码回 32 位 ARGB', () {
      // -16711680 = 0xFF010000 的有符号表示：修复前编码为 '#0-FF0100'，
      // 重启/再次导入时解码抛 FormatException，主题整份丢失
      expect(encodeReaderThemeColor(-16711680), '#FF010000');
      expect(decodeReaderThemeColor('#FF010000'), 0xFF010000);
      expect(decodeReaderThemeColor(-16711680), 0xFF010000);
      expect(decodeReaderThemeColor(-1), 0xFFFFFFFF);
      expect(encodeReaderThemeColor(-1), '#FFFFFFFF');
    });

    test('超过 32 位的 int 掩码到低 32 位', () {
      expect(encodeReaderThemeColor(0x1FF010000), '#FF010000');
      expect(decodeReaderThemeColor(0x1FF010000), 0xFF010000);
      expect(decodeReaderThemeColor(0x123456789ABC), 0x56789ABC);
    });

    test('正常 ARGB 与样式 JSON 往返保真', () {
      for (final argb in <int>[
        0x00000000,
        0xFF000000,
        0xFFFFFFFF,
        0x80C2D8AA,
        0x00112233,
      ]) {
        expect(
          decodeReaderThemeColor(encodeReaderThemeColor(argb)),
          argb,
          reason: '颜色 $argb 编解码不闭环',
        );
      }

      // 负 int 脏数据落盘后再解码：等价于「保存主题 → 重启应用」链路
      const original = ReaderTheme(
        id: 'theme-negative',
        name: '负色值',
        style: ReaderThemeStyle(
          backgroundColor: -16711680,
          textColor: -1,
        ),
      );
      final encoded = ReaderThemeCodec.encode(original);
      expect(encoded, contains('#FF010000'));
      expect(encoded, isNot(contains('#0-')));
      final decoded = ReaderThemeCodec.decodeAll(encoded).single;
      expect(decoded.style.backgroundColor, 0xFF010000);
      expect(decoded.style.textColor, 0xFFFFFFFF);
    });
  });

  group('导入 BOM 兼容（批38b P2-2）', () {
    test('单份/数组带 UTF-8 BOM 均可解析', () {
      final single = ReaderThemeService.importThemes(
        '\uFEFF{"name":"BOM 主题","style":{"backgroundColor":"#123456"}}',
        existingNames: const <String>[],
      );
      expect(single.single.name, 'BOM 主题');
      expect(single.single.style.backgroundColor, 0xFF123456);

      // 前导空白 + BOM 混合
      final batch = ReaderThemeCodec.decodeAll(
        '  \uFEFF[{"name":"A","style":{}},{"name":"B","style":{}}]',
      );
      expect([for (final theme in batch) theme.name], ['A', 'B']);
    });

    test('BOM 之外的非法 JSON 仍抛 FormatException', () {
      expect(
        () => ReaderThemeCodec.decodeAll('\uFEFFnot json'),
        throwsA(isA<FormatException>()),
      );
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

    test('首载未完成就变更：磁盘主题库不被空状态覆盖（批38b P2-1）', () async {
      // 模拟上一次运行留下的磁盘主题库
      final service = ReaderThemeService();
      final onDisk = ReaderThemeService.createTheme(
        name: '磁盘主题',
        style: const ReaderThemeStyle(backgroundColor: 0xFF445566),
        existingNames: const <String>[],
      );
      await service.saveCustomThemes(<ReaderTheme>[onDisk]);

      // 新容器：加载是异步的，紧接着就新建主题（不等 loaded）
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      final notifier = fresh.read(readerThemeProvider.notifier);
      await notifier.addTheme(
        name: '新主题',
        style: const ReaderThemeStyle(backgroundColor: 0xFF778899),
      );

      final state = fresh.read(readerThemeProvider);
      expect(state.loaded, isTrue);
      expect(
        state.customThemes.map((t) => t.name),
        containsAll(<String>['磁盘主题', '新主题']),
        reason: '首载前变更必须先把磁盘主题库读进来再追加',
      );

      // 落盘同样保留两份
      final persisted = await ReaderThemeService().loadCustomThemes();
      expect(
        persisted.map((t) => t.name),
        containsAll(<String>['磁盘主题', '新主题']),
      );
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

    test('重命名：内置不可改、自建可改、重名自动加后缀', () async {
      await waitThemeLoaded(container);
      final notifier = container.read(readerThemeProvider.notifier);
      final theme = await notifier.addTheme(
        name: '旧名',
        style: const ReaderThemeStyle(),
      );
      expect(
        await notifier.renameTheme(kBuiltInReaderThemes.first.id, '新名'),
        isNull,
        reason: '内置主题不可重命名',
      );
      expect(await notifier.renameTheme(theme.id, '  新名  '), '新名');
      final renamed = container
          .read(readerThemeProvider)
          .themes
          .firstWhere((item) => item.id == theme.id);
      expect(renamed.name, '新名');
      expect(await notifier.renameTheme(theme.id, '   '), isNull);

      // 与另一自建主题重名 → 自动加 (2) 后缀（批38b 审查 P3-1）
      final other = await notifier.addTheme(
        name: '另一个',
        style: const ReaderThemeStyle(),
      );
      expect(await notifier.renameTheme(other.id, '新名'), '新名 (2)');
      expect(
        container.read(readerThemeProvider).customThemes.map((t) => t.name),
        ['新名', '新名 (2)'],
      );
      // 改成自己当前名称不应被追加后缀
      expect(await notifier.renameTheme(other.id, '新名 (2)'), '新名 (2)');
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

  group('备份恢复后重建（批38c P2）', () {
    // 设备验收现象：备份恢复成功后同一会话进「阅读主题」页无限转圈、入口
    // 显示「未应用主题（自定义）」；重启后正常。根因是 `ref.invalidate` 会
    // 触发 `onDispose`，而 Riverpod 2.x 重建时复用同一个 Notifier 实例，
    // 旧的 `_disposed = true` 未被复位 → `_loadLoop` 直接返回，`loaded`
    // 永远为 false。恢复链路正是 `applyFromBackup` 写 prefs 后
    // `ref.invalidate(readerThemeProvider)`（webdav_settings_screen）。
    const restoredTheme = ReaderTheme(
      id: 'theme-from-backup',
      name: '备份主题',
      style: ReaderThemeStyle(backgroundColor: 0xFF123456),
    );

    /// 模拟恢复：备份里的主题库/当前 id 写入本地 prefs（与
    /// RestoreIgnorePrefs.applyFromBackup 同一 SharedPreferences 路径）
    Future<void> writeRestoredPrefs() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        ReaderThemeService.themesKey,
        ReaderThemeCodec.encodeStoredList(<ReaderTheme>[restoredTheme]),
      );
      await prefs.setString(ReaderThemeService.currentIdKey, restoredTheme.id);
    }

    test('invalidate 后重建：重读磁盘 prefs，loaded=true 且当前 id 生效', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await waitThemeLoaded(container);
      expect(container.read(readerThemeProvider).loaded, isTrue);

      await writeRestoredPrefs();
      container.invalidate(readerThemeProvider);

      // 重建后必须重新完成加载（否则 waitThemeLoaded 超时）
      await waitThemeLoaded(container);
      final state = container.read(readerThemeProvider);
      expect(state.loaded, isTrue);
      expect(state.customThemes.map((theme) => theme.name), <String>['备份主题']);
      expect(state.currentId, 'theme-from-backup');
      expect(state.currentTheme?.name, '备份主题');
    });

    test('重建后变更操作可用：markCurrent/新建不因旧生命周期卡住', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await waitThemeLoaded(container);

      await writeRestoredPrefs();
      container.invalidate(readerThemeProvider);
      await waitThemeLoaded(container);

      final notifier = container.read(readerThemeProvider.notifier);
      final created = await notifier.addTheme(
        name: '恢复后新建',
        style: const ReaderThemeStyle(backgroundColor: 0xFF654321),
      );
      await notifier.markCurrent(created.id);
      final state = container.read(readerThemeProvider);
      expect(state.loaded, isTrue);
      expect(
        state.customThemes.map((theme) => theme.name),
        <String>['备份主题', '恢复后新建'],
      );
      expect(state.currentId, created.id);
      // 落盘同样包含备份主题，未被空状态覆盖
      final persisted = await ReaderThemeService().loadCustomThemes();
      expect(
        persisted.map((theme) => theme.name),
        <String>['备份主题', '恢复后新建'],
      );
    });

    testWidgets('恢复后重建不无限转圈：主题页加载完成并标记当前', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = await pumpThemeScreen(
        tester,
        overrides: <Override>[bookApiProvider.overrideWithValue(MockRustApi())],
      );
      await pumpUntilFound(tester, find.byType(ReaderThemeGrid));

      // 同一会话内恢复：prefs 换成备份内容 + invalidate（webdav 设置页路径）
      await writeRestoredPrefs();
      container.invalidate(readerThemeProvider);
      await tester.pump();
      expect(
        find.byType(CircularProgressIndicator),
        findsOneWidget,
        reason: '重建后应短暂回到加载中态（证明本次确实重建了 provider）',
      );

      // 卡在 loaded=false 时这里会一直转圈直到超时
      await pumpUntilFound(tester, find.byType(ReaderThemeGrid));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('备份主题'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('theme-current-theme-from-backup'),
        ),
        findsOneWidget,
        reason: '恢复的当前主题 id 应被标记',
      );
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

    testWidgets('整卡可点：点名称区也能应用主题/新建（批38b P2-3）', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final tappedIds = <String>[];
      var addTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderThemeGrid(
              // 3 列保证名称行在 800x600 测试视口内可命中
              themes: kBuiltInReaderThemes.take(2).toList(),
              columns: 3,
              currentId: '',
              manageMode: false,
              selectedIds: const <String>{},
              controller: controller,
              itemKeyBuilder: (id) => GlobalKey(),
              onTap: (theme) => tappedIds.add(theme.id),
              onLongPress: (_) {},
              showAddTile: true,
              onAdd: () => addTaps++,
            ),
          ),
        ),
      );

      await tester.tap(find.text('预设1'));
      await tester.pump();
      expect(tappedIds, <String>['builtin-preset-1']);

      await tester.tap(find.text('新建主题'));
      await tester.pump();
      expect(addTaps, 1);
    });
  });

  group('应用主题与恢复默认（批38b）', () {
    const fullTheme = ReaderTheme(
      id: 'theme-full',
      name: '全字段主题',
      style: ReaderThemeStyle(
        fontSize: 26.0,
        lineHeight: 2.1,
        backgroundColor: 0xFF1A2B3C,
        textColor: 0xFFEEDDCC,
        fontFamily: 'Custom_TestFont',
        titleFont: 'serif',
        letterSpacing: 0.35,
        paragraphIndent: 3,
        paragraphSpacing: 9.0,
        marginTop: 33.0,
        marginBottom: 31.0,
        marginLeft: 19.0,
        marginRight: 17.0,
        textBold: 1,
        italic: true,
      ),
    );

    /// 预热阅读器设置加载（正常使用中阅读设置先于主题页加载完成；
    /// 这里避免 ReaderNotifier 首载结果覆盖刚应用的主题字段）
    Future<void> warmReader(WidgetTester tester, ProviderContainer c) async {
      c.read(readerNotifierProvider);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }

    testWidgets('应用主题：阅读样式/排版/字体/当前标记全字段写回', (tester) async {
      // 加高视口让第 6 张卡（自定义主题）的名称行可命中
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues(<String, Object>{});
      await ReaderThemeService().saveCustomThemes(<ReaderTheme>[fullTheme]);

      final container = await pumpThemeScreen(
        tester,
        overrides: <Override>[bookApiProvider.overrideWithValue(MockRustApi())],
      );
      await warmReader(tester, container);
      await pumpUntilFound(tester, find.text('全字段主题'));

      await tester.tap(find.text('全字段主题'));
      await pumpUntil(
        tester,
        () => container.read(readerThemeProvider).currentId == 'theme-full',
        reason: '应用主题后当前 id 未标记',
      );
      await tester.pump(const Duration(milliseconds: 20));

      // 阅读页状态：字号/行距/背景
      final readerState = container.read(readerNotifierProvider);
      expect(readerState.fontSize, 26.0);
      expect(readerState.lineHeight, 2.1);
      expect(readerState.backgroundColor.toARGB32(), 0xFF1A2B3C);

      // 背景链路：非既有预设色 → 自定义背景标志置位
      expect(
        container.read(readerNotifierProvider.notifier).useCustomBackground,
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('reader_custom_bg_color'), 0xFF1A2B3C);
      expect(prefs.getBool('reader_bg_use_custom'), isTrue);
      expect(prefs.getString('reader_font_family'), 'Custom_TestFont');

      // 排版字段全量落盘（重新 load 校验每条写入）
      final adv = await ReaderAdvancedConfig.load(isNight: false);
      expect(adv.customTextColor, 0xFFEEDDCC);
      expect(adv.titleFont, 'serif');
      expect(adv.letterSpacing, 0.35);
      expect(adv.paragraphIndent, 3);
      expect(adv.paragraphSpacing, 9.0);
      expect(adv.pageMarginTop, 33.0);
      expect(adv.pageMarginBottom, 31.0);
      expect(adv.pageMarginLeft, 19.0);
      expect(adv.pageMarginRight, 17.0);
      expect(adv.textBold, 1);
      expect(adv.italic, isTrue);

      // 已应用到内存中的排版配置
      final applied = container.read(readerAdvConfigProvider);
      expect(applied?.customTextColor, 0xFFEEDDCC);
      expect(applied?.pageMarginTop, 33.0);

      // 当前主题标记
      expect(container.read(readerThemeProvider).currentId, 'theme-full');
    });

    testWidgets('应用内置预设1：命中既有预设背景链路，不算自定义（P3-2）', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = await pumpThemeScreen(
        tester,
        overrides: <Override>[bookApiProvider.overrideWithValue(MockRustApi())],
      );
      await warmReader(tester, container);
      await pumpUntilFound(tester, find.text('预设1'));

      await tester.tap(find.text('预设1'));
      await pumpUntil(
        tester,
        () =>
            container.read(readerThemeProvider).currentId == 'builtin-preset-1',
        reason: '应用预设1后当前 id 未标记',
      );
      await tester.pump(const Duration(milliseconds: 20));

      final notifier = container.read(readerNotifierProvider.notifier);
      expect(
        notifier.useCustomBackground,
        isFalse,
        reason: '预设背景不能亮自定义 chip',
      );
      expect(
        container.read(readerNotifierProvider).backgroundColor,
        ReaderBackground.white,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('reader_bg_use_custom'), isFalse);
    });

    testWidgets('恢复默认：清空自建并应用内置预设1', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = ReaderThemeService();
      final custom = ReaderThemeService.createTheme(
        name: '待清除',
        style: const ReaderThemeStyle(backgroundColor: 0xFF1A2B3C),
        existingNames: const <String>[],
      );
      await service.saveCustomThemes(<ReaderTheme>[custom]);
      await service.saveCurrentId(custom.id);

      final container = await pumpThemeScreen(
        tester,
        overrides: <Override>[bookApiProvider.overrideWithValue(MockRustApi())],
      );
      await warmReader(tester, container);
      await pumpUntilFound(tester, find.byTooltip('更多'));

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复默认主题'));
      await tester.pumpAndSettle();
      expect(
        find.text('将删除全部自建主题，并把阅读样式恢复为内置「预设1」，是否继续？'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, '恢复'));
      await pumpUntil(
        tester,
        () => container.read(readerThemeProvider).currentId ==
            'builtin-preset-1',
        reason: '恢复默认后应把阅读样式应用为内置预设1',
      );
      await tester.pumpAndSettle();

      final themeState = container.read(readerThemeProvider);
      expect(themeState.customThemes, isEmpty);
      expect(themeState.currentId, 'builtin-preset-1');

      // 阅读样式回到预设1：白底、黑色文字
      expect(
        container.read(readerNotifierProvider).backgroundColor,
        ReaderBackground.white,
      );
      final adv = await ReaderAdvancedConfig.load(isNight: false);
      expect(adv.customTextColor, 0xFF000000);

      // 自建主题库已清空落盘
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ReaderThemeService.themesKey), '[]');
    });
  });

  group('惰性网格定位（批38b P1-2）', () {
    testWidgets('400 项 / 2 列：定位第 200 项后目标卡可见', (tester) async {
      // 加高测试视口，让 2 列卡片（高约 934）完整可判定「是否在可视区」
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final themes = <ReaderTheme>[
        for (var i = 0; i < 400; i++)
          ReaderTheme(
            id: 'bulk-$i',
            name: '批量 $i',
            style: ReaderThemeStyle(backgroundColor: 0xFF000000 | i),
          ),
      ];
      final service = ReaderThemeService();
      await service.saveCustomThemes(themes);
      await service.saveCurrentId('bulk-195'); // 合并内置后下标 = 200
      await service.saveGridColumns(2);

      final container = await pumpThemeScreen(tester);
      await pumpUntilFound(tester, find.byType(ReaderThemeGrid));
      final delegate =
          tester.widget<GridView>(find.byType(GridView)).gridDelegate
              as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 2);
      expect(container.read(readerThemeProvider).currentIndex, 200);

      final marker = find.byKey(
        const ValueKey<String>('theme-current-bulk-195'),
      );
      expect(marker, findsNothing, reason: '第 200 项初始不在可视区/缓存区');

      await tester.tap(find.byTooltip('定位当前'));
      await tester.pumpAndSettle();

      expect(marker, findsOneWidget, reason: '定位后目标卡必须被构建出来');
      final gridRect = tester.getRect(find.byType(GridView));
      final markerRect = tester.getRect(marker);
      expect(
        gridRect.contains(markerRect.center),
        isTrue,
        reason: '目标卡应滚入可视区（网格几何偏移不能漂移）',
      );
    });
  });

  group('首载门禁（批38b P2-1）', () {
    testWidgets('加载中禁用布局切换/列数/管理/更多', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            readerThemeProvider.overrideWith(_NeverLoadingThemeNotifier.new),
          ],
          child: const MaterialApp(home: ReaderThemeScreen()),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      final columnMenu = tester.widget<PopupMenuButton<int>>(
        find.byType(PopupMenuButton<int>),
      );
      expect(columnMenu.enabled, isFalse, reason: '加载中列数菜单应禁用');
      final moreMenu = tester.widget<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );
      expect(moreMenu.enabled, isFalse, reason: '加载中更多菜单应禁用');
      final manageButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.checklist_rounded),
      );
      expect(manageButton.onPressed, isNull, reason: '加载中管理入口应禁用');
      final toggleButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.view_list_rounded),
      );
      expect(toggleButton.onPressed, isNull, reason: '加载中布局切换应禁用');
    });
  });
}
