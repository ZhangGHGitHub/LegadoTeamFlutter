// [C3 B1 | 台账 1-3] 分组 tab 左对齐回归（对齐参考 03b：tab 行左起）
//
// 2.0.260 实机截图（ours_2.0.260/03_bookshelf.png）中单组「全部」tab
// 水平居中（墨迹 x≈499..580@1080，屏中 540），参考 03b 多组 tab 自
// x≈59 左起。本套件锁死两态：
// ① 无用户分组（空态回落）：tab 行唯一 tab「全部」左对齐（首 tab 左缘
//    贴近 0，非居中）；
// ② 多组：首 tab（通知器恒置顶的默认「全部」组）左对齐，后续 tab 顺排
//    不拉伸居中。
//
// 注意：分组 tab 列表 = 通知器「默认全部组置顶 + 用户组」（bookshelf
// notifier 68 行），用户组不含「全部」时首 tab 恒为「全部」——断言对象
// 以实际渲染的首 tab 为准。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  Future<void> pumpBookshelf(
    WidgetTester tester,
    MockRustApi mockApi,
    List<BookGroup> groups,
  ) async {
    SharedPreferences.setMockInitialValues({'bookshelf_layout': true});
    when(() => mockApi.getBooks()).thenAnswer(
      (_) async => const [
        Book(bookUrl: 'u1', name: '书一'),
        Book(bookUrl: 'u2', name: '书二'),
      ],
    );
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => groups);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: BookshelfScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('单组（空态回落）：唯一 tab 左对齐（首 tab 左缘 ≈ 0）',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 无用户分组：tab 行仅回落的「全部」一项
    await pumpBookshelf(tester, MockRustApi(), const []);

    final tabRect = tester.getRect(find.text('全部'));
    // 左对齐：左缘贴近 0（TabBar padding=0，labelPadding=0，
    // 容忍 24 内像素误差）；若为居中，360dp 屏上「全部」(~28dp 宽)
    // 左缘应 ≈ 166dp，本断言将其判负。
    expect(
      tabRect.left,
      lessThan(24),
      reason: '单组 tab 应左对齐（参考 03b tab 行左起），实际 left=${tabRect.left}',
    );
  });

  testWidgets('多组：首 tab 左对齐且各 tab 顺排', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 用户组不含「全部」：实际 tab 行 = [全部(默认置顶), 未读, 小说, 网络未分组]
    await pumpBookshelf(
      tester,
      MockRustApi(),
      const [
        BookGroup(groupId: 1, groupName: '未读', show: true),
        BookGroup(groupId: 2, groupName: '小说', show: true),
        BookGroup(groupId: 4, groupName: '网络未分组', show: true),
      ],
    );

    // 首 tab（默认「全部」组）左起：参考 03b 量测 x≈59px@3x≈20dp 内，
    // 我方 TabBar padding=0 钉在 0，取 24 容差
    final first = tester.getRect(find.text('全部'));
    expect(
      first.left,
      lessThan(24),
      reason: '多组首 tab 应左起（参考 03b 量测 x≈59px@3x≈20dp 内），实际 left=${first.left}',
    );
    // 顺排：「未读」紧随首 tab 右侧、「小说」再其后
    final second = tester.getRect(find.text('未读'));
    expect(second.left, greaterThan(first.right - 8));
    final third = tester.getRect(find.text('小说'));
    expect(third.left, greaterThan(second.right - 8));
  });
}
