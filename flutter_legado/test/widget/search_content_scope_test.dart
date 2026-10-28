// 正文搜索范围/选项持久化与「仅本书」胶囊解绑测试（批33）
//
// 覆盖：
// - 默认范围 = 仅本书（已缓存），⋮ 菜单勾选态对齐；
// - 菜单三档 + 替换/正则选择即写 SharedPreferences，重进（新建 options）
//   后保持；
// - 「仅本书」胶囊不再改搜索范围（只提示「按书搜索历史待后续版本支持」）。
//
// 说明：⋮ 菜单项直接经 `PopupMenuButton.itemBuilder` / `onSelected` 驱动，
// 不走弹出层点击（菜单弹出层在测试窗口内的命中区域不稳定，且本用例要验证
// 的是选项状态与持久化语义，不是菜单动画）。
//
// 编写：全栈工程师（批33） ｜ 2026-10-29
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/search_content_screen.dart';
import 'package:flutter_legado/src/services/search_content_options.dart';
import 'package:flutter_legado/src/services/settings_service.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    when(() => mockApi.getSearchHistory(limit: any(named: 'limit')))
        .thenAnswer((_) async => <SearchKeyword>[
              const SearchKeyword(word: '关键词'),
            ]);
  });

  Future<SearchContentOptions> pumpScreen(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
  }) async {
    if (prefs.isNotEmpty) SharedPreferences.setMockInitialValues(prefs);
    final options = SearchContentOptions();
    await options.load();

    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: SearchContentScreen(
            bookUrl: 'https://src.com/book/1',
            bookName: '测试书',
            options: options,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return options;
  }

  PopupMenuButton<String> optionsButton(WidgetTester tester) =>
      tester.widget<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );

  /// 用页面真实 itemBuilder 评估菜单勾选态（不依赖弹出层命中）
  Map<String, bool> checkedStates(WidgetTester tester) {
    final context = tester.element(find.byType(PopupMenuButton<String>));
    final items = optionsButton(tester)
        .itemBuilder(context)
        .whereType<CheckedPopupMenuItem<String>>();
    return {
      for (final item in items)
        if (item.child is Text) (item.child! as Text).data!: item.checked,
    };
  }

  Future<void> selectOption(WidgetTester tester, String value) async {
    optionsButton(tester).onSelected!(value);
    await tester.pumpAndSettle();
  }

  testWidgets('默认范围仅本书（已缓存），菜单勾选态对齐', (tester) async {
    final options = await pumpScreen(tester);

    expect(options.scope, SettingsService.searchScopeCached);
    final checked = checkedStates(tester);
    expect(checked['仅本书（已缓存）'], isTrue);
    expect(checked['本书 + 网络'], isFalse);
    expect(checked['仅当前章'], isFalse);
  });

  testWidgets('菜单选择持久化：三档范围 + 替换/正则重进保持', (tester) async {
    final options = await pumpScreen(tester);

    await selectOption(tester, 'scope_network');
    await selectOption(tester, 'replace');
    await selectOption(tester, 'regex');

    expect(options.scope, SettingsService.searchScopeNetwork);
    expect(options.useReplace, isTrue);
    expect(options.useRegex, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('search_content_scope'),
      SettingsService.searchScopeNetwork,
    );
    expect(prefs.getBool('search_content_use_replace'), isTrue);
    expect(prefs.getBool('search_content_use_regex'), isTrue);

    // 模拟关闭页面重进：新实例从持久化恢复
    final reloaded = SearchContentOptions();
    await reloaded.load();
    expect(reloaded.scope, SettingsService.searchScopeNetwork);
    expect(reloaded.useReplace, isTrue);
    expect(reloaded.useRegex, isTrue);
  });

  testWidgets('切回仅当前章也持久化', (tester) async {
    final options = await pumpScreen(
      tester,
      prefs: {'search_content_scope': SettingsService.searchScopeNetwork},
    );

    await selectOption(tester, 'scope_current');

    expect(options.scope, SettingsService.searchScopeCurrent);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('search_content_scope'),
      SettingsService.searchScopeCurrent,
    );
    expect(checkedStates(tester)['仅当前章'], isTrue);
  });

  testWidgets('「仅本书」胶囊不再改范围，仅提示后续支持', (tester) async {
    final options = await pumpScreen(
      tester,
      prefs: {'search_content_scope': SettingsService.searchScopeNetwork},
    );

    // 历史非空，胶囊位于历史标题行
    expect(find.text('仅本书'), findsOneWidget);
    await tester.tap(find.text('仅本书'));
    await tester.pump();

    expect(find.text('按书搜索历史待后续版本支持'), findsOneWidget);
    expect(
      options.scope,
      SettingsService.searchScopeNetwork,
      reason: '胶囊只服务搜索历史，不得再改正文搜索范围',
    );
    // 菜单勾选态仍为网络档
    final checked = checkedStates(tester);
    expect(checked['本书 + 网络'], isTrue);
    expect(checked['仅本书（已缓存）'], isFalse);
  });
}
