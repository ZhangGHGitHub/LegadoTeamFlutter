// [设置批2b-2b] 多栏布局设置持久化与备份归组
//
// 语义：键 multiPaneMode 默认 auto；随 appPrefs 备份/恢复，不进入
// themePrefKeys（参考版 BackupConfig.themePrefKeys 未收录）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/utils/multi_pane_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('默认 auto（未写入偏好时不落盘）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(uiSettingsProvider);
    await pumpEventQueue();

    expect(
      container.read(uiSettingsProvider).multiPaneMode,
      MultiPaneMode.auto,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(PrefKeys.multiPaneMode), isFalse);
  });

  test('切换后写入偏好，重启加载保持', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(uiSettingsProvider.notifier)
        .setMultiPaneMode(MultiPaneMode.always);

    expect(
      container.read(uiSettingsProvider).multiPaneMode,
      MultiPaneMode.always,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.multiPaneMode), 'always');

    // 新容器从偏好重新加载（模拟重启）
    final reloaded = ProviderContainer();
    addTearDown(reloaded.dispose);
    reloaded.read(uiSettingsProvider);
    await pumpEventQueue();
    expect(
      reloaded.read(uiSettingsProvider).multiPaneMode,
      MultiPaneMode.always,
    );
  });

  test('未知持久化值回落 auto', () async {
    SharedPreferences.setMockInitialValues({PrefKeys.multiPaneMode: '__bad__'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(uiSettingsProvider);
    await pumpEventQueue();

    expect(
      container.read(uiSettingsProvider).multiPaneMode,
      MultiPaneMode.auto,
    );
  });

  test('随 appPrefs 备份，且不受「忽略主题配置」过滤', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(PrefKeys.multiPaneMode, 'landscape');

    expect(
      RestoreIgnorePrefs.themePrefKeys.contains(PrefKeys.multiPaneMode),
      isFalse,
    );

    final all = await RestoreIgnorePrefs.collectForBackup({});
    expect(all[PrefKeys.multiPaneMode], 'landscape');

    final filtered = await RestoreIgnorePrefs.collectForBackup({
      'themeConfig': true,
    });
    expect(filtered[PrefKeys.multiPaneMode], 'landscape');
  });
}
