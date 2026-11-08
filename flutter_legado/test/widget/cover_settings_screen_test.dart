// 封面设置独立页 widget 测试（设置批6b-1）
//
// 覆盖：18 项全量渲染（参考版 CoverConfigScreen 分组）、默认值、
// 作者随书名禁用、仅 WiFi/描边/阴影/限制比例写偏好、信息方向下拉、
// 取色复用 ContainerColorDialog、默认封面入口（内置/相册）、网络角标灰置。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/cover_settings.dart';
import 'package:flutter_legado/src/providers/cover_settings/cover_settings_notifier.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/cover_album_manage_screen.dart';
import 'package:flutter_legado/src/screens/cover_settings_screen.dart';
import 'package:flutter_legado/src/services/cover_album_store.dart';
import 'package:flutter_legado/src/widgets/container_color_dialog.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    coverSettingsListenable.value = CoverSettings.defaults;
    uiSettingsListenable.value = const UiSettingsState();
  });

  /// 高视口一次渲染全部 18 行（避免 ListView 懒构建影响计数断言）
  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: CoverSettingsScreen())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('18 项全量渲染且分组标题存在', (tester) async {
    await pumpScreen(tester);

    // 10 个 SettingSwitchRow 内部各含 1 个 IosListTile + 8 个直接行 = 18
    expect(find.byType(IosListTile), findsNWidgets(18));
    expect(find.byType(SettingSwitchRow), findsNWidgets(10));

    // 参考版分组：白天 / 夜间 / 网络书籍角标
    expect(find.text('白天'), findsOneWidget);
    expect(find.text('夜间'), findsOneWidget);
    expect(find.text('网络书籍角标'), findsOneWidget);

    // 关键行键（入口/开关/取色/方向/角标）
    for (final key in const [
      'coverOnlyWifiSwitch',
      'coverRuleRow',
      'coverUseDefaultSwitch',
      'coverDefaultAlbumRow',
      'coverShadowSwitch',
      'coverStrokeSwitch',
      'coverDefaultColorSwitch',
      'coverRestrictRatioSwitch',
      'coverInfoOrientationDropdown',
      'coverNetworkBadgeRow',
      'coverTextColorRow',
      'coverShadowColorRow',
      'coverShowNameSwitch',
      'coverShowAuthorSwitch',
      'coverTextColorDarkRow',
      'coverShadowColorDarkRow',
      'coverShowNameDarkSwitch',
      'coverShowAuthorDarkSwitch',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
  });

  testWidgets('默认值：描边/默认色/限制比例/书名作者开，阴影/仅 WiFi 关', (tester) async {
    await pumpScreen(tester);

    SettingSwitchRow row(String key) =>
        tester.widget<SettingSwitchRow>(find.byKey(ValueKey(key)));

    expect(row('coverOnlyWifiSwitch').value, isFalse);
    expect(row('coverUseDefaultSwitch').value, isFalse);
    expect(row('coverShadowSwitch').value, isFalse);
    expect(row('coverStrokeSwitch').value, isTrue);
    expect(row('coverDefaultColorSwitch').value, isTrue);
    expect(row('coverRestrictRatioSwitch').value, isTrue);
    expect(row('coverShowNameSwitch').value, isTrue);
    expect(row('coverShowAuthorSwitch').value, isTrue);
    expect(row('coverShowAuthorSwitch').onChanged, isNotNull);
    expect(row('coverShowNameDarkSwitch').value, isTrue);
    expect(row('coverShowAuthorDarkSwitch').onChanged, isNotNull);

    // 相册（6b-2）已启用；无相册时副标题「应用内置封面」
    final album = tester.widget<IosListTile>(
      find.byKey(const ValueKey('coverDefaultAlbumRow')),
    );
    expect(album.enabled, isTrue);
    expect(album.onTap, isNotNull);
    expect(album.subtitle, '应用内置封面');
    // 网络角标（另立项）仍灰置
    final badge = tester.widget<IosListTile>(
      find.byKey(const ValueKey('coverNetworkBadgeRow')),
    );
    expect(badge.enabled, isFalse);
    expect(badge.value, '全部显示');
    expect(find.text('另立项，暂不生效'), findsOneWidget);
  });

  testWidgets('书名关闭时作者开关禁用；恢复书名后重新可用', (tester) async {
    await pumpScreen(tester);

    SettingSwitchRow authorRow() => tester.widget<SettingSwitchRow>(
      find.byKey(const ValueKey('coverShowAuthorSwitch')),
    );
    expect(authorRow().onChanged, isNotNull);

    await tester.tap(find.byKey(const ValueKey('coverShowNameSwitch')));
    await tester.pumpAndSettle();
    expect(authorRow().onChanged, isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(CoverSettings.keyShowName), isFalse);

    await tester.tap(find.byKey(const ValueKey('coverShowNameSwitch')));
    await tester.pumpAndSettle();
    expect(authorRow().onChanged, isNotNull);
  });

  testWidgets('夜间作者开关随夜间书名禁用', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('coverShowNameDarkSwitch')));
    await tester.pumpAndSettle();

    final authorDark = tester.widget<SettingSwitchRow>(
      find.byKey(const ValueKey('coverShowAuthorDarkSwitch')),
    );
    expect(authorDark.onChanged, isNull);
    // 白天作者不受夜间开关影响
    final authorDay = tester.widget<SettingSwitchRow>(
      find.byKey(const ValueKey('coverShowAuthorSwitch')),
    );
    expect(authorDay.onChanged, isNotNull);
  });

  testWidgets('仅 WiFi / 描边 / 阴影 / 限制比例写偏好', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('coverOnlyWifiSwitch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coverStrokeSwitch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coverShadowSwitch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coverRestrictRatioSwitch')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(CoverSettings.keyLoadOnlyOnWifi), isTrue);
    expect(prefs.getBool(CoverSettings.keyShowStroke), isFalse);
    expect(prefs.getBool(CoverSettings.keyShowShadow), isTrue);
    // 限制比例复用既有键，并同步 UiSettings
    expect(prefs.getBool(CoverSettings.keyRestrictCoverRatio), isFalse);
    expect(uiSettingsListenable.value.restrictCoverRatio, isFalse);
  });

  testWidgets('信息方向下拉切换为横向并持久化', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('横向').last);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(CoverSettings.keyInfoOrientation), '1');
    expect(find.text('横向'), findsOneWidget);
  });

  testWidgets('取色复用 ContainerColorDialog 并写入偏好', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('coverTextColorRow')));
    await tester.pumpAndSettle();
    expect(find.byType(ContainerColorDialog), findsOneWidget);
    expect(find.text('正文颜色（白天）'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '#FF112233');
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(CoverSettings.keyTextColor), 0xFF112233);
  });

  testWidgets('取色对话框「恢复默认」回落参考版默认色（非透明）', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('coverTextColorDarkRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();

    // 初值即默认白色：ContainerColorDialog 返回 0 时回落 0xFFFFFFFF，
    // 内存态保持非透明（不得写入 0 = 透明文字）
    expect(coverSettingsListenable.value.textColorDark, 0xFFFFFFFF);
  });

  testWidgets('默认封面行显示相册副标题，选择 Sheet 可切回内置封面', (tester) async {
    final temp = Directory.systemTemp.createTempSync('legado_cover_settings_');
    CoverAlbumStore.resetForTest();
    CoverAlbumStore.supportDirOverride = () async => temp;
    await CoverAlbumStore.instance.ensureLoaded();
    final albumId = await CoverAlbumStore.instance.createAlbum('日间相册');
    addTearDown(() async {
      CoverAlbumStore.resetForTest();
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    SharedPreferences.setMockInitialValues(<String, Object>{
      CoverSettings.keyDefaultAlbumId: albumId,
    });

    await pumpScreen(tester);
    expect(find.text('日间相册 · 日间 0 · 夜间 0'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('coverDefaultAlbumRow')));
    await tester.pumpAndSettle();
    expect(find.text('选择封面相册'), findsOneWidget);
    expect(find.byKey(ValueKey('coverAlbumOption_$albumId')), findsOneWidget);
    expect(
      find.byKey(ValueKey('coverAlbumOptionCheck_$albumId')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('coverAlbumBuiltinOption')));
    await tester.pumpAndSettle();
    expect(find.text('选择封面相册'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(CoverSettings.keyDefaultAlbumId), '');
  });

  testWidgets('默认封面 → 管理相册入口进入封面相册管理页', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          routes: AppRoutes.routes,
          initialRoute: AppRoutes.coverSettings,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('coverDefaultAlbumRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coverAlbumManageAction')));
    await tester.pumpAndSettle();
    expect(find.byType(CoverAlbumManageScreen), findsOneWidget);
  });
}
