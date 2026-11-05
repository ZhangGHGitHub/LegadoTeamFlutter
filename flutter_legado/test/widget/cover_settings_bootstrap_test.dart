// 冷启动封面设置预热回归（设置批6b-1 审查 P1-1）
//
// LegadoApp.initState 通过 ref.read(coverSettingsProvider) 预热封面设置；
// 本用例锁定「根节点 initState 读取 provider → listenable 在首屏前拿到
// 持久化值」这一契约（不 pump 完整 LegadoApp：其 Bookshelf/FFI/平台通道
// 依赖无法在纯 widget 测试环境装配）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/cover_settings.dart';
import 'package:flutter_legado/src/providers/cover_settings/cover_settings_notifier.dart';

/// 模拟 App 根 State：initState 只 read、不 watch（与 app.dart 同法）
class _RootBootstrapProbe extends ConsumerStatefulWidget {
  const _RootBootstrapProbe();

  @override
  ConsumerState<_RootBootstrapProbe> createState() =>
      _RootBootstrapProbeState();
}

class _RootBootstrapProbeState extends ConsumerState<_RootBootstrapProbe> {
  @override
  void initState() {
    super.initState();
    ref.read(coverSettingsProvider);
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

void main() {
  setUp(() {
    coverSettingsListenable.value = CoverSettings.defaults;
  });

  testWidgets('prefs → 根节点 initState → listenable 已加载（首屏前生效）', (tester) async {
    SharedPreferences.setMockInitialValues({
      CoverSettings.keyShowShadow: true,
      CoverSettings.keyShowStroke: false,
      CoverSettings.keyLoadOnlyOnWifi: true,
    });

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _RootBootstrapProbe())),
    );
    // 等异步 SharedPreferences 读取完成（根节点未 watch，不触发重建）
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_RootBootstrapProbe)),
    );
    await container.read(coverSettingsProvider.notifier).waitForLoad();
    await tester.pump();

    expect(coverSettingsListenable.value.showShadow, isTrue);
    expect(coverSettingsListenable.value.showStroke, isFalse);
    expect(coverSettingsListenable.value.loadOnlyOnWifi, isTrue);
  });
}
