// [R42 阶段 2A | 2026-11-23] 书籍编辑页「角色」入口守卫（契约 §2.56）
//
// 参考版位置：`BookInfoEditScreen.kt:223` `BookKnowledgeEditCard` 的「人物」
// 按钮 → 人物列表页。我方 2A 把「列表 + 新增 + 编辑 + 删除」收敛进
// `CharacterManageDialog`，入口挂在书籍编辑页。
//
// 门控：仅在线书展示——详情页角色区块对本地书短路（与相关书同口径），
// 本地书建档后无处可见，故入口同样隐藏，避免「录了看不到」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/edit_book_info_screen.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';
import 'package:flutter_legado/src/widgets/character_manage_dialog.dart';

import '../mocks/mocks.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap(Book book) => ProviderScope(
    overrides: [bookApiProvider.overrideWithValue(MockRustApi())],
    child: MaterialApp(
      theme: AppTheme.palette(
        brightness: Brightness.light,
        palette: Md3Palettes.wh,
      ),
      home: EditBookInfoScreen(book: book),
    ),
  );

  const onlineBook = Book(
    bookUrl: 'https://src.com/book/current',
    origin: 'https://src.com',
    originName: '测试书源',
    name: '当前书',
    author: '当前作者',
    tocUrl: 'https://src.com/toc/current',
  );

  testWidgets('在线书：编辑页有「角色」入口，点击打开角色管理对话框', (tester) async {
    tester.view.physicalSize = const Size(1080, 2260);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(onlineBook));
    await tester.pumpAndSettle();

    expect(find.text('角色'), findsOneWidget);
    expect(find.text('手动建档，详情页展示角色卡'), findsOneWidget);

    await tester.tap(find.text('角色'));
    await tester.pumpAndSettle();

    expect(find.byType(CharacterManageDialog), findsOneWidget);
    expect(find.text('角色管理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地书：编辑页不显示「角色」入口（与详情页短路同口径）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2260);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    const localBook = Book(
      bookUrl: '/local/novel.txt',
      origin: BookType.localTag,
      name: '本地书',
      author: '本地作者',
      bookType: BookType.text,
    );
    await tester.pumpWidget(wrap(localBook));
    await tester.pumpAndSettle();

    expect(find.text('角色'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
