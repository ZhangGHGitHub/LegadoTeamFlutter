// 批9a 项7：源编辑框最大行数（sourceEditMaxLine）接线测试
//
// 语义钉住（对齐原版 BookSourceEditAdapter.editEntityMaxLine）：
// - 默认 99：代码/JS 大文本字段（loginUi/jsLib/c_content 等）maxLines=99；
// - 偏好生效：写 10 后大文本字段 maxLines=10；
// - 短字段不套用：源 URL/源名称等 maxLines=1 字段保持 1；
// - 越界回落：偏好 < 10（下限）回落 99；
// - 不降级：偏好 < 字段原定义时取原定义（较大者）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/source_edit_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Future<void> pumpEdit(WidgetTester tester) async {
    // 加高可视区域：扁平单列长表单，目标字段须构建完成才能被 find 定位
    // （与 source_edit_test 同口径）
    await tester.binding.setSurfaceSize(const Size(800, 12000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: SourceEditScreen(),
        ),
      ),
    );
    // initState 异步读偏好（microtask）后 setState
    await tester.pump();
    await tester.pump();
  }

  /// 读取指定 key 字段的 maxLines
  ///
  /// TextFormField 不透出 maxLines getter，取其 KeyedSubtree 内层
  /// TextField（TextFormField builder 直接透传 maxLines）。
  int maxLinesOf(WidgetTester tester, String key) {
    final field = tester.widget<TextField>(
      find
          .descendant(
            of: find.byKey(ValueKey<String>('sf_$key')),
            matching: find.byType(TextField),
          )
          .first,
    );
    return field.maxLines ?? 1;
  }

  testWidgets('默认 99：代码/JS 大文本字段展开到 99 行', (tester) async {
    await pumpEdit(tester);
    expect(maxLinesOf(tester, 'loginUi'), 99);
    expect(maxLinesOf(tester, 'jsLib'), 99);
    expect(maxLinesOf(tester, 'c_content'), 99);
  });

  testWidgets('偏好 10 生效：大文本字段 maxLines=10', (tester) async {
    SharedPreferences.setMockInitialValues(
      const {'sourceEditMaxLine': 10},
    );
    await pumpEdit(tester);
    expect(maxLinesOf(tester, 'loginUi'), 10);
    expect(maxLinesOf(tester, 'jsLib'), 10);
  });

  testWidgets('短字段不套用：URL/名称保持 maxLines=1', (tester) async {
    SharedPreferences.setMockInitialValues(
      const {'sourceEditMaxLine': 10},
    );
    await pumpEdit(tester);
    expect(maxLinesOf(tester, 'bookSourceUrl'), 1);
    expect(maxLinesOf(tester, 'bookSourceName'), 1);
    expect(maxLinesOf(tester, 'bookSourceGroup'), 1);
  });

  testWidgets('越界回落：偏好 < 10 回落默认 99', (tester) async {
    SharedPreferences.setMockInitialValues(
      const {'sourceEditMaxLine': 3},
    );
    await pumpEdit(tester);
    expect(maxLinesOf(tester, 'loginUi'), 99);
  });

  testWidgets('不降级：偏好 2（回落 99 后）与原定义取较大者——原 maxLines=4 字段为 99，'
      '原 maxLines=1 短字段仍 1', (tester) async {
    SharedPreferences.setMockInitialValues(
      const {'sourceEditMaxLine': 2},
    );
    await pumpEdit(tester);
    // 2 < 10 下限 → 回落 99
    expect(maxLinesOf(tester, 'loginCheckJs'), 99);
    expect(maxLinesOf(tester, 's_checkKeyWord'), 99);
    // 短字段不受影响
    expect(maxLinesOf(tester, 'searchUrl'), 1);
  });
}
