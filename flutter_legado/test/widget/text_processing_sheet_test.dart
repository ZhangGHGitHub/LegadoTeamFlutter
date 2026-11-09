/// 文字处理 Sheet 测试（批7c-1）
///
/// 覆盖：加载/搜索/四筛选/总开关/行内开关/排序写回/删除/管理入口/
/// 内容处理空态/360dp 无溢出。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/reader/text_processing_sheet.dart';

const _book = Book(
  bookUrl: 'https://book.com/tp',
  name: '测试书',
  author: '作者A',
  origin: 'https://source.example.com',
  readConfig: ReadConfig(useReplaceRule: true),
);

class _FakeReaderNotifier extends ReaderNotifier {
  _FakeReaderNotifier(this.initial);

  final ReaderState initial;
  int reloads = 0;

  @override
  ReaderState build() => initial;

  @override
  Future<void> reloadChapterContent() async {
    reloads++;
  }
}

void main() {
  late MockBookApi api;
  late _FakeReaderNotifier reader;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockBookApi();
    reader = _FakeReaderNotifier(
      const ReaderState(
        currentBook: _book,
        chapters: [
          BookChapter(
            url: 'u0',
            title: '第一章',
            index: 0,
            bookUrl: 'https://book.com/tp',
          ),
        ],
        currentChapterIndex: 0,
        chapterContent: '正文',
      ),
    );
  });

  Future<ReplaceRule> addRule({
    required String name,
    required String pattern,
    String replacement = '',
    String? group,
    String? scope,
    bool scopeContent = true,
    bool isEnabled = true,
  }) {
    return api.addReplaceRule(
      ReplaceRule(
        name: name,
        pattern: pattern,
        replacement: replacement,
        group: group,
        scope: scope,
        scopeContent: scopeContent,
        isEnabled: isEnabled,
        isRegex: false,
      ),
    );
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bookApiProvider.overrideWithValue(api),
          readerNotifierProvider.overrideWith(() => reader),
          replaceEnableDefaultProvider.overrideWith((ref) async => true),
        ],
        child: MaterialApp(
          routes: {
            AppRoutes.replaceRules: (_) =>
                const Scaffold(body: Center(child: Text('规则管理页'))),
          },
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                key: const ValueKey('open-text-processing'),
                onPressed: () => TextProcessingSheet.show(context, ref),
                child: const Text('打开文字处理'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-text-processing')));
    await tester.pumpAndSettle();
  }

  Future<Map<String, ReplaceRule>> rulesById() async {
    final list = await api.getReplaceRules();
    return {for (final rule in list) rule.pattern: rule};
  }

  testWidgets('加载规则并默认筛选「生效」；搜索 name/pattern/group', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await addRule(name: '广告净化', pattern: '广告', scope: '测试书');
    await addRule(
      name: '停用规则',
      pattern: '停用',
      scopeContent: true,
      isEnabled: false,
    );
    await addRule(name: '全局规则', pattern: '全局', scope: null);
    await addRule(name: '外书规则', pattern: '外书', scope: '别的书');
    await addRule(
      name: '标题规则',
      pattern: '标题',
      scopeContent: false,
      scope: '测试书',
    );
    await addRule(name: '分组规则', pattern: '组词', group: '测试组', scope: '测试书');
    await openSheet(tester);

    // 默认「生效」：广告/全局/组词（停用、外书、scopeContent=false 排除）
    expect(
      find.byKey(const ValueKey('text-processing-rule-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('text-processing-rule-3')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('text-processing-rule-6')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('text-processing-rule-2')), findsNothing);
    expect(find.byKey(const ValueKey('text-processing-rule-4')), findsNothing);
    expect(find.byKey(const ValueKey('text-processing-rule-5')), findsNothing);

    // 全部 / 已启用 / 已停用
    await tester.tap(find.byKey(const ValueKey('text-processing-filter-all')));
    await tester.pump();
    for (var id = 1; id <= 6; id++) {
      expect(find.byKey(ValueKey('text-processing-rule-$id')), findsOneWidget);
    }

    await tester.tap(
      find.byKey(const ValueKey('text-processing-filter-enabled')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('text-processing-rule-2')), findsNothing);
    expect(
      find.byKey(const ValueKey('text-processing-rule-5')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('text-processing-filter-disabled')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('text-processing-rule-2')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('text-processing-rule-1')), findsNothing);

    // 搜索 group/pattern（先回全部）
    await tester.tap(find.byKey(const ValueKey('text-processing-filter-all')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('text-processing-search')),
      '测试组',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('text-processing-rule-6')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('text-processing-rule-1')), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('text-processing-search')),
      '广告',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('text-processing-rule-1')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('text-processing-rule-6')), findsNothing);
  });

  testWidgets('总开关切换写配置并重载正文', (tester) async {
    await addRule(name: '规则', pattern: '词', scope: '测试书');
    await openSheet(tester);
    final switchFinder = find.byKey(
      const ValueKey('text-processing-master-switch'),
    );
    expect(
      tester.widget<SwitchListTile>(switchFinder).value,
      isTrue,
      reason: 'readConfig.useReplaceRule=true',
    );
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
    expect(reader.reloads, 1);
  });

  testWidgets('行内开关调用 setReplaceRuleEnabled 并重载', (tester) async {
    final rule = await addRule(name: '规则', pattern: '词', scope: '测试书');
    await openSheet(tester);
    await tester.tap(find.byKey(ValueKey('text-processing-switch-${rule.id}')));
    await tester.pumpAndSettle();
    final stored = (await rulesById())['词']!;
    expect(stored.isEnabled, isFalse);
    expect(reader.reloads, 1);
  });

  testWidgets('拖动排序写回 order 并重载', (tester) async {
    await addRule(name: 'A', pattern: 'a', scope: '测试书');
    await addRule(name: 'B', pattern: 'b', scope: '测试书');
    await addRule(name: 'C', pattern: 'c', scope: '测试书');
    await openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('text-processing-filter-all')));
    await tester.pump();

    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    list.onReorderItem!(0, 2);
    await tester.pumpAndSettle();

    final stored = await rulesById();
    expect(stored['b']!.order, 0);
    expect(stored['c']!.order, 1);
    expect(stored['a']!.order, 2);
    expect(reader.reloads, 1);
  });

  testWidgets('删除规则：确认后移除并重载', (tester) async {
    final rule = await addRule(name: '待删', pattern: '删', scope: '测试书');
    await openSheet(tester);
    await tester.tap(find.byKey(ValueKey('text-processing-menu-${rule.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除替换规则？'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('text-processing-delete-confirm')),
    );
    await tester.pumpAndSettle();

    expect((await rulesById()).containsKey('删'), isFalse);
    expect(
      find.byKey(ValueKey('text-processing-rule-${rule.id}')),
      findsNothing,
    );
    expect(reader.reloads, 1);
  });

  testWidgets('管理入口打开整页替换规则管理', (tester) async {
    await openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('text-processing-manage')));
    await tester.pumpAndSettle();
    expect(find.text('规则管理页'), findsOneWidget);
  });

  testWidgets('内容处理空态', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('内容处理'));
    await tester.pumpAndSettle();
    expect(find.text('暂无 AI 处理记录'), findsOneWidget);
    expect(find.text('AI 内容处理暂未支持'), findsOneWidget);
  });

  testWidgets('360dp 不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await addRule(
      name: '很长很长的规则名称用于检查溢出',
      pattern: '非常长的正则或文本模式',
      scope: '测试书',
    );
    await openSheet(tester);
    expect(tester.takeException(), isNull);
  });
}
