// 字号越界收口单测（批33b）
//
// 背景：字号范围裁决为 5–50 后，仍有两条绕过路径直写 prefs：
// - 主题导入（association_notifier._importTheme）对 fontSize>0 直写；
// - Rust 阅读配置注入（rust_api._injectReadBookConfig）未 clamp。
// 修复：SettingsService.getFontSize/setFontSize 作为唯一读写收口统一
// clamp，导入与注入均收敛到该单点。
//
// 编写：全栈工程师（批33b） ｜ 2026-10-29
import 'package:flutter_legado/src/providers/association/association_notifier.dart';
import 'package:flutter_legado/src/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('SettingsService 字号读写统一 clamp 5–50', () async {
    final settings = SettingsService();

    // 写入越界 → 落库即收敛
    await settings.setFontSize(80);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('reader_font_size'), 50.0);
    expect(await settings.getFontSize(), 50.0);

    // 低于下限同样收敛
    await settings.setFontSize(2);
    expect(prefs.getDouble('reader_font_size'), 5.0);
    expect(await settings.getFontSize(), 5.0);

    // 外部直写越界值（旧版本/第三方备份）→ 读取侧仍收口
    await prefs.setDouble('reader_font_size', 999);
    expect(await settings.getFontSize(), 50.0);
    await prefs.setDouble('reader_font_size', 0.5);
    expect(await settings.getFontSize(), 5.0);

    // 范围内原样保留
    await settings.setFontSize(30);
    expect(await settings.getFontSize(), 30.0);
  });

  test('主题导入 fontSize=80 → 收敛到 50（不再直写越界值）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result = await container
        .read(associationNotifierProvider.notifier)
        .confirmImport(ImportType.theme, [
      {'themeName': '第三方主题', 'fontSize': 80},
    ]);

    expect(result.success, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getDouble('reader_font_size'),
      50.0,
      reason: '导入越界字号必须收敛到上限 50，不得原样入库',
    );
  });

  test('主题导入字号在范围内原样保留；越下限收敛到 5', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(associationNotifierProvider.notifier);
    final prefs = await SharedPreferences.getInstance();

    await notifier.confirmImport(ImportType.theme, [
      {'themeName': '正常主题', 'fontSize': 30},
    ]);
    expect(prefs.getDouble('reader_font_size'), 30.0);

    await notifier.confirmImport(ImportType.theme, [
      {'themeName': '小字号主题', 'fontSize': 1},
    ]);
    expect(prefs.getDouble('reader_font_size'), 5.0);
  });
}
