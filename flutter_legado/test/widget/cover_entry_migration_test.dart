// 封面设置入口迁移测试（设置批6b-1）
//
// 覆盖：设置主页一级「封面设置」入口 → 独立页；外观页旧「封面设置」行
// 已移除（滚动到原相邻行「底栏图集」附近仍不可见）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/cover_settings_screen.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('设置主页提供「封面设置」一级入口并导航到独立页', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          initialRoute: AppRoutes.settingsHome,
          routes: AppRoutes.routes,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SettingsHomeScreen), findsOneWidget);
    expect(find.text('封面设置'), findsOneWidget);

    await tester.tap(find.text('封面设置'));
    await tester.pumpAndSettle();

    expect(find.byType(CoverSettingsScreen), findsOneWidget);
    expect(find.text('仅 WiFi'), findsOneWidget);
    expect(find.text('显示字体描边'), findsOneWidget);
  });

  testWidgets('外观页旧「封面设置」行已移除', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ThemeConfigScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // 滚动到原相邻行「底栏图集」：若旧行仍在，应在其上方一同构建
    await tester.scrollUntilVisible(
      find.text('底栏图集'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('底栏图集'), findsOneWidget);
    expect(find.text('封面设置'), findsNothing);
    expect(find.text('通用封面规则及默认封面样式'), findsNothing);
  });
}
