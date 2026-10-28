// 正文搜索选项持久化单测（批33）
//
// 裁决口径：
// - 默认范围由「本书 + 网络」改为「仅本书（已缓存）」（对齐原版/参考版
//   「只搜已缓存」）；
// - 三档范围 + 替换/正则开关持久化到 SharedPreferences，重进/重启保持；
// - 非法遗留值回退默认，不把脏值写回。
//
// 编写：全栈工程师（批33） ｜ 2026-10-29
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/search_content_options.dart';
import 'package:flutter_legado/src/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('默认：范围仅本书（已缓存），替换/正则关闭', () async {
    final options = SearchContentOptions();
    await options.load();

    expect(options.scope, SettingsService.searchScopeCached);
    expect(options.scope, 'current_and_cached');
    expect(options.useReplace, isFalse);
    expect(options.useRegex, isFalse);
  });

  test('三档范围 + 替换/正则持久化，重进保持', () async {
    final options = SearchContentOptions()
      ..scope = SettingsService.searchScopeNetwork
      ..useReplace = true
      ..useRegex = true;
    await options.save();

    // 模拟关闭页面重进 / 重启应用：新实例从持久化恢复
    final reloaded = SearchContentOptions();
    await reloaded.load();
    expect(reloaded.scope, SettingsService.searchScopeNetwork);
    expect(reloaded.useReplace, isTrue);
    expect(reloaded.useRegex, isTrue);

    reloaded.scope = SettingsService.searchScopeCurrent;
    await reloaded.save();
    final again = SearchContentOptions();
    await again.load();
    expect(again.scope, SettingsService.searchScopeCurrent);
  });

  test('非法遗留范围回退默认（仅本书已缓存）', () async {
    SharedPreferences.setMockInitialValues({
      'search_content_scope': 'bogus_scope',
    });
    final options = SearchContentOptions();
    await options.load();
    expect(options.scope, SettingsService.searchScopeCached);
  });

  test('写入非法范围被忽略，持久化值不变', () async {
    SharedPreferences.setMockInitialValues({
      'search_content_scope': 'current',
    });
    final settings = SettingsService();
    await settings.setSearchContentScope('not_a_scope');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('search_content_scope'), 'current');
  });
}
