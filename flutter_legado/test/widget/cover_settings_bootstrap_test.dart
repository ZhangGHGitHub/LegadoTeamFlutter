// 冷启动封面设置预热回归（设置批6b-1 审查 R-P2-2）
//
// LegadoApp 实际以 CoverSettingsBootstrap 包裹应用树；本用例直接 pump 该
// Widget（不是测试内复制的一份假 initState），锁定「根节点 initState 读取
// provider → listenable 在首屏前拿到持久化值」契约。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/cover_settings.dart';
import 'package:flutter_legado/src/providers/cover_settings/cover_settings_notifier.dart';
import 'package:flutter_legado/src/widgets/cover_settings_bootstrap.dart';

void main() {
  setUp(() {
    coverSettingsListenable.value = CoverSettings.defaults;
  });

  testWidgets('prefs → CoverSettingsBootstrap.initState → listenable 已加载', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      CoverSettings.keyShowShadow: true,
      CoverSettings.keyShowStroke: false,
      CoverSettings.keyLoadOnlyOnWifi: true,
    });

    await tester.pumpWidget(
      ProviderScope(
        child: CoverSettingsBootstrap(
          child: MaterialApp(home: SizedBox.shrink()),
        ),
      ),
    );
    // 等异步 SharedPreferences 读取完成（根节点未 watch，不触发重建）
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CoverSettingsBootstrap)),
    );
    await container.read(coverSettingsProvider.notifier).waitForLoad();
    await tester.pump();

    expect(coverSettingsListenable.value.showShadow, isTrue);
    expect(coverSettingsListenable.value.showStroke, isFalse);
    expect(coverSettingsListenable.value.loadOnlyOnWifi, isTrue);
  });
}
