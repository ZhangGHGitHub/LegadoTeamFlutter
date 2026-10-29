// 「限制封面比例」设置持久化与备份往返测试（批39）
//
// 覆盖：默认开启、切换后写 SharedPreferences、重新加载生效、
// 备份 appPrefs 收集与「忽略封面配置」过滤。
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

  test('默认开启（对齐参考版 restrictCoverRatio=true）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(uiSettingsProvider);
    await pumpEventQueue();

    expect(container.read(uiSettingsProvider).restrictCoverRatio, isTrue);
  });

  test('关闭后写入偏好并可被重新加载', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(uiSettingsProvider.notifier).setRestrictCoverRatio(false);
    expect(container.read(uiSettingsProvider).restrictCoverRatio, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.coverRestrictRatio), isFalse);

    // 新容器从偏好重新加载（模拟重启）：先触发 build 再等异步 _load 完成
    final reloaded = ProviderContainer();
    addTearDown(reloaded.dispose);
    reloaded.read(uiSettingsProvider);
    await pumpEventQueue();
    expect(reloaded.read(uiSettingsProvider).restrictCoverRatio, isFalse);

    // 再开启同样持久化
    await reloaded.read(uiSettingsProvider.notifier).setRestrictCoverRatio(true);
    expect(prefs.getBool(PrefKeys.coverRestrictRatio), isTrue);
  });

  test('纳入备份 appPrefs，并受「忽略封面配置」约束', () async {
    await SharedPreferences.getInstance()
        .then((prefs) => prefs.setBool(PrefKeys.coverRestrictRatio, false));

    // 默认备份包含该键
    final all = await RestoreIgnorePrefs.collectForBackup({});
    expect(all[PrefKeys.coverRestrictRatio], isFalse);

    // 勾选「忽略封面配置」→ 不写入备份
    final filtered = await RestoreIgnorePrefs.collectForBackup(
      {'coverConfig': true},
    );
    expect(filtered.containsKey(PrefKeys.coverRestrictRatio), isFalse);

    // 键级判定同口径
    expect(
      RestoreIgnorePrefs.keyIsNotIgnore(PrefKeys.coverRestrictRatio, {}),
      isTrue,
    );
    expect(
      RestoreIgnorePrefs.keyIsNotIgnore(
        PrefKeys.coverRestrictRatio,
        {'coverConfig': true},
      ),
      isFalse,
    );
  });
}
