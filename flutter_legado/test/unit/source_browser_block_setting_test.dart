// 「拦截书源打开浏览器」偏好备份往返测试（批39）
//
// 参考版键名 blockSourceBrowser；本仓随 Flutter JSON 备份 appPrefs 往返。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('经 UiSettingsNotifier 写入偏好并同步全局镜像', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(uiSettingsProvider);
    await pumpEventQueue();
    expect(container.read(uiSettingsProvider).blockSourceBrowser, isFalse);

    await container.read(uiSettingsProvider.notifier).setBlockSourceBrowser(true);
    expect(container.read(uiSettingsProvider).blockSourceBrowser, isTrue);
    expect(uiSettingsListenable.value.blockSourceBrowser, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.blockSourceBrowser), isTrue);

    // 新容器重新加载（模拟重启）
    final reloaded = ProviderContainer();
    addTearDown(reloaded.dispose);
    reloaded.read(uiSettingsProvider);
    await pumpEventQueue();
    expect(reloaded.read(uiSettingsProvider).blockSourceBrowser, isTrue);

    addTearDown(() => uiSettingsListenable.value = const UiSettingsState());
  });

  test('默认关闭，写入后进入备份 appPrefs', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.blockSourceBrowser), isNull);

    await prefs.setBool(PrefKeys.blockSourceBrowser, true);
    final backup = await RestoreIgnorePrefs.collectForBackup({});
    expect(backup[PrefKeys.blockSourceBrowser], isTrue);

    // 不受其他忽略项影响（与封面/阅读/主题忽略无关）
    for (final ignore in [
      {'readConfig': true},
      {'themeConfig': true},
      {'coverConfig': true},
      {'bookshelfLayout': true},
    ]) {
      final filtered = await RestoreIgnorePrefs.collectForBackup(
        Map<String, bool>.from(ignore),
      );
      expect(filtered[PrefKeys.blockSourceBrowser], isTrue);
    }
  });
}
