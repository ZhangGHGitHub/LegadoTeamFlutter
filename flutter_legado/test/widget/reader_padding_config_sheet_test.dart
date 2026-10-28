// 页面边距面板测试（批33：上下联动 + 滑块/步进器形态）
//
// 对齐基准：原版 `PaddingConfigDialog`（`paddingTopBottomLinked` 仅正文 Tab
// 可见；开启后以上边距为准镜像下边距；`applyEdit` 双向镜像）与参考版
// 「滑块 + 数值 + 加减」行形态。
//
// 覆盖：
// - 正文 Tab 显示「上下边距联动」，页眉/页脚 Tab 不显示；
// - 开启后上/下镜像（打开即下=上，单步调整双向同步）；
// - 左右联动仍生效（不因新开关回退）；
// - 范围不回退：上/下 0-400，左/右 0-100；
// - paddingTopBottomLinked 随 ReaderAdvancedConfig 持久化/恢复。
//
// 编写：全栈工程师（批33） ｜ 2026-10-29
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/widgets/reader/reader_padding_config_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<List<ReaderAdvancedConfig>> pumpSheet(
    WidgetTester tester,
    ReaderAdvancedConfig config,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final changes = <ReaderAdvancedConfig>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ReaderPaddingConfigSheet(
              config: config,
              onChanged: changes.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return changes;
  }

  /// 四行 ± 按钮顺序固定为 上/下/左/右（构建顺序即 _padRow 调用顺序）
  Finder stepButton(int index, {bool increase = true}) =>
      find.byTooltip(increase ? '增加' : '减少').at(index);

  testWidgets('上下联动开关仅正文 Tab 可见', (tester) async {
    await pumpSheet(tester, ReaderAdvancedConfig());

    expect(find.text('上下边距联动'), findsOneWidget);

    await tester.tap(find.text('页眉'));
    await tester.pumpAndSettle();
    expect(find.text('上下边距联动'), findsNothing);

    await tester.tap(find.text('页脚'));
    await tester.pumpAndSettle();
    expect(find.text('上下边距联动'), findsNothing);

    await tester.tap(find.text('正文'));
    await tester.pumpAndSettle();
    expect(find.text('上下边距联动'), findsOneWidget);
  });

  testWidgets('开启上下联动：先以下边距对齐上边距，之后双向镜像', (tester) async {
    final changes = await pumpSheet(
      tester,
      ReaderAdvancedConfig(pageMarginTop: 10, pageMarginBottom: 30),
    );

    await tester.tap(find.text('上下边距联动'));
    await tester.pumpAndSettle();

    // 打开即以上边距为准镜像下边距（对齐原版 finalApply(TOP, ...)）
    expect(changes.last.paddingTopBottomLinked, isTrue);
    expect(changes.last.pageMarginTop, 10);
    expect(changes.last.pageMarginBottom, 10);

    // 上 +1 → 下同步
    await tester.tap(stepButton(0));
    await tester.pumpAndSettle();
    expect(changes.last.pageMarginTop, 11);
    expect(changes.last.pageMarginBottom, 11);

    // 下 -1 → 上同步（双向镜像）
    await tester.tap(stepButton(1, increase: false));
    await tester.pumpAndSettle();
    expect(changes.last.pageMarginTop, 10);
    expect(changes.last.pageMarginBottom, 10);
  });

  testWidgets('左右联动仍生效（左右镜像）', (tester) async {
    // 初始左右不等 → 联动默认关闭；点开关后开启再验证镜像
    final changes = await pumpSheet(
      tester,
      ReaderAdvancedConfig(pageMarginLeft: 20, pageMarginRight: 25),
    );

    await tester.tap(find.text('左右边距联动'));
    await tester.pumpAndSettle();

    // 左 +1 → 右同步
    await tester.tap(stepButton(2));
    await tester.pumpAndSettle();
    expect(changes.last.pageMarginLeft, 21);
    expect(changes.last.pageMarginRight, 21);

    // 右 -1 → 左同步
    await tester.tap(stepButton(3, increase: false));
    await tester.pumpAndSettle();
    expect(changes.last.pageMarginLeft, 20);
    expect(changes.last.pageMarginRight, 20);
  });

  testWidgets('范围不回退：上下 0-400、左右 0-100', (tester) async {
    final changes = await pumpSheet(
      tester,
      ReaderAdvancedConfig(
        pageMarginTop: 400,
        pageMarginBottom: 0,
        pageMarginLeft: 100,
        pageMarginRight: 0,
      ),
    );

    // 上已在 400，继续加不越界
    await tester.tap(stepButton(0));
    await tester.pumpAndSettle();
    expect(changes.last.pageMarginTop, 400);

    // 下已在 0，继续减不越界
    await tester.tap(stepButton(1, increase: false));
    await tester.pumpAndSettle();
    expect(changes.last.pageMarginBottom, 0);

    // 左已在 100，继续加不越界
    await tester.tap(stepButton(2));
    await tester.pumpAndSettle();
    expect(changes.last.pageMarginLeft, 100);

    // 右已在 0，继续减不越界
    await tester.tap(stepButton(3, increase: false));
    await tester.pumpAndSettle();
    expect(changes.last.pageMarginRight, 0);
  });

  test('paddingTopBottomLinked 随配置持久化并恢复', () async {
    final cfg = ReaderAdvancedConfig(
      paddingTopBottomLinked: true,
      pageMarginTop: 12,
      pageMarginBottom: 12,
    );
    await cfg.save();

    final loaded = await ReaderAdvancedConfig.load();
    expect(loaded.paddingTopBottomLinked, isTrue);
    expect(loaded.pageMarginTop, 12);
    expect(loaded.pageMarginBottom, 12);

    // 关闭后同样往返
    final off = loaded.copy()..paddingTopBottomLinked = false;
    await off.save();
    final reloaded = await ReaderAdvancedConfig.load();
    expect(reloaded.paddingTopBottomLinked, isFalse);
  });
}
