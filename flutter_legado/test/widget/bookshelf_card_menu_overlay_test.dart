import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';

import '../mocks/mocks.dart';

/// [P2-31] 书架「更多选项」菜单浮层形态 回归测试
///
/// 背景：修复前「更多」菜单为**全屏不透明**路由（_CardMenuRoute opaque=true，
/// 整页 Material 白底），打开后左侧书架被完全遮住（用户报障：菜单左侧整片
/// 纯白、书架不可见）。参考版（legado-with-MD3 RoundDropdownMenu 非 Miuix
/// 分支）为**浮层**：书架保持可见 + 半透明 scrim 压暗 + 右侧圆角阴影浮卡。
///
/// 修复：_CardMenuRoute opaque=false + 半透明 scrim（_kMenuScrimColor，
/// alpha≈0.25）+ 右侧圆角浮卡；11 项功能行为零改动。
///
/// 本用例断言「打开菜单后书架内容仍可见」：
/// · scrim 压暗层存在（键值 'bookshelf_menu_scrim'，与生产代码同名字面量，
///   不导出命名常量 → 修复前本测试亦可编译，干净红→绿）；
/// · scrim 为半透明（后方书架透出可见，而非修复前的全屏不透明白底）；
/// · 书架书籍条目仍在树中可见；右侧浮卡菜单项可见；
/// · 点按 scrim 关闭菜单。
void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  /// 与 bookshelf_screen.dart 中 scrim 键值保持一致（同名字面量，
  /// 不 import 生产符号 → 修复前亦可编译）
  const ValueKey<String> scrimKey = ValueKey<String>('bookshelf_menu_scrim');

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
  });

  /// 书架含一本「未读之书」
  const bookUnread = Book(
    name: '未读之书',
    bookUrl: 'book://shelf-menu',
    totalChapterNum: 100,
  );

  /// pump 书架页（桩路由占位），返回其 ProviderScope 容器
  Future<ProviderContainer> pumpShelf(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: const BookshelfScreen(),
          routes: {
            AppRoutes.bookInfo: (_) => const _StubPage(label: 'STUB_DETAIL'),
            AppRoutes.reader: (_) => const _StubPage(label: 'STUB_READER'),
            AppRoutes.remoteBooks: (_) => const _StubPage(label: 'STUB_REMOTE'),
          },
        ),
      ),
    );
    final context = tester.element(find.byType(BookshelfScreen));
    return ProviderScope.containerOf(context);
  }

  testWidgets(
      '[P2-31] 打开「更多」菜单：书架保持可见 + scrim 压暗 + 右侧浮卡',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    when(() => mockApi.getBooks()).thenAnswer((_) async => [bookUnread]);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);

    container = await pumpShelf(tester);
    addTearDown(container.dispose);
    // Notifier build() 的 _loadSettings/_loadBooks/_loadGroups 落定
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('未读之书'), findsOneWidget,
        reason: '书架书籍条目应已加载');

    // 打开顶栏「⋮ 更多」菜单
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // [P2-31] 浮层形态的 scrim（压暗层）必须存在。
    // 修复前：全屏不透明白底、无 scrim → 该断言失败（红）。
    final scrim = find.byKey(scrimKey);
    expect(
      scrim,
      findsOneWidget,
      reason:
          '[P2-31] 菜单须有半透明 scrim（浮层形态）；修复前为全屏不透明覆盖、无 scrim',
    );
    final scrimColor = tester.widget<ColoredBox>(scrim).color;
    expect(
      scrimColor.a,
      lessThan(0.99),
      reason: 'scrim 须半透明，后方书架内容仍透出可见（修复前为不透明白底）',
    );

    // 书架内容仍可见（未被菜单遮住）
    expect(
      find.text('未读之书'),
      findsOneWidget,
      reason: '[P2-31] 打开菜单后，后方书架书籍仍应可见',
    );

    // 右侧浮卡菜单项可见
    expect(find.text('远程书籍'), findsOneWidget,
        reason: '菜单浮卡首项「远程书籍」应可见');

    // 点按 scrim 关闭菜单
    await tester.tap(scrim);
    await tester.pumpAndSettle();
    expect(
      find.byKey(scrimKey),
      findsNothing,
      reason: '[P2-31] 点按 scrim 应关闭菜单浮层',
    );
  });
}

/// 桩页：占位（更多菜单 action 目标路由 / 详情页 / 阅读器），
/// 避免 push 到真实页面。
class _StubPage extends StatelessWidget {
  final String label;
  const _StubPage({required this.label});

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Text(label));
  }
}
