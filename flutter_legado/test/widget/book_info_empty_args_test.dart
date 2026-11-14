// P3-6 回归：详情页空参数（无 bookUrl 且无 Book）不得永久 Loading
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/skeleton.dart';

void main() {
  testWidgets('空 bookUrl 且无 Book：终止骨架并显示缺少书籍参数', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = MockBookApi();
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BookInfoScreen(bookUrl: '')),
      ),
    );
    // 不用 pumpAndSettle：空态修复前骨架 shimmer 会一直动画
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('缺少书籍参数'), findsOneWidget);
    expect(find.byType(ListSkeletonItem), findsNothing,
        reason: '不得停留在首屏骨架/Loading');
  });
}
