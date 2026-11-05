// 封面设置模型 / Notifier 单元测试（设置批6b-1）
//
// 覆盖：默认值（对齐参考版 CoverSettings.kt）、键名对齐 PrefKeys、
// 旧备份负 int 颜色归一、类型容错、toPrefMap 往返、Notifier 持久化 /
// reload、限制比例与 UiSettings 同步、备份收集与「忽略封面配置」过滤。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/cover_settings.dart';
import 'package:flutter_legado/src/providers/cover_settings/cover_settings_notifier.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    coverSettingsListenable.value = CoverSettings.defaults;
    uiSettingsListenable.value = const UiSettingsState();
  });

  group('CoverSettings 默认值', () {
    test('字段默认值与参考版 CoverSettings.kt 一致', () {
      const s = CoverSettings.defaults;
      expect(s.loadOnlyOnWifi, isFalse);
      expect(s.useDefaultCover, isFalse);
      expect(s.defaultAlbumId, isNull);
      expect(s.showShadow, isFalse);
      expect(s.showStroke, isTrue);
      expect(s.useDefaultColor, isTrue);
      expect(s.restrictCoverRatio, isTrue);
      expect(s.infoOrientation, '0');
      expect(s.exploreFilterState, 0);
      expect(s.textColor, 0xFF000000);
      expect(s.shadowColor, 0xFF000000);
      expect(s.showName, isTrue);
      expect(s.showAuthor, isTrue);
      expect(s.textColorDark, 0xFFFFFFFF);
      expect(s.shadowColorDark, 0xFFFFFFFF);
      expect(s.showNameDark, isTrue);
      expect(s.showAuthorDark, isTrue);
    });

    test('持久化键名逐字对齐 PrefKeys / 参考版 PreferKey', () {
      expect(CoverSettings.keyLoadOnlyOnWifi, PrefKeys.loadCoverOnlyWifi);
      expect(CoverSettings.keyUseDefaultCover, PrefKeys.useDefaultCover);
      expect(CoverSettings.keyDefaultAlbumId, PrefKeys.coverDefaultAlbumId);
      expect(CoverSettings.keyShowShadow, PrefKeys.coverShowShadow);
      expect(CoverSettings.keyShowStroke, PrefKeys.coverShowStroke);
      expect(CoverSettings.keyUseDefaultColor, PrefKeys.coverDefaultColor);
      expect(CoverSettings.keyRestrictCoverRatio, PrefKeys.coverRestrictRatio);
      expect(CoverSettings.keyInfoOrientation, PrefKeys.coverInfoOrientation);
      expect(CoverSettings.keyExploreFilterState, PrefKeys.exploreFilterState);
      expect(CoverSettings.keyTextColor, PrefKeys.coverTextColor);
      expect(CoverSettings.keyShadowColor, PrefKeys.coverShadowColor);
      expect(CoverSettings.keyShowName, PrefKeys.coverShowName);
      expect(CoverSettings.keyShowAuthor, PrefKeys.coverShowAuthor);
      expect(CoverSettings.keyTextColorDark, PrefKeys.coverTextColorN);
      expect(CoverSettings.keyShadowColorDark, PrefKeys.coverShadowColorN);
      expect(CoverSettings.keyShowNameDark, PrefKeys.coverShowNameN);
      expect(CoverSettings.keyShowAuthorDark, PrefKeys.coverShowAuthorN);
    });

    test('prefKeys 覆盖 17 个持久化键', () {
      expect(CoverSettings.prefKeys.length, 17);
      expect(
        CoverSettings.prefKeys,
        containsAll(CoverSettings.defaults.toPrefMap().keys),
      );
    });
  });

  group('fromPrefMap / toPrefMap', () {
    test('缺失键回落默认值；空图集 ID 归一为 null', () {
      final s = CoverSettings.fromPrefMap({
        CoverSettings.keyDefaultAlbumId: '',
      });
      expect(s, CoverSettings.defaults);
    });

    test('兼容参考版 Kotlin 负 int 颜色（32 位截断归一）', () {
      final s = CoverSettings.fromPrefMap({
        CoverSettings.keyTextColor: -16777216,
        CoverSettings.keyShadowColor: -16777216,
        CoverSettings.keyTextColorDark: -1,
        CoverSettings.keyShadowColorDark: -1,
      });
      expect(s.textColor, 0xFF000000);
      expect(s.shadowColor, 0xFF000000);
      expect(s.textColorDark, 0xFFFFFFFF);
      expect(s.shadowColorDark, 0xFFFFFFFF);
    });

    test('类型容错：bool/int/string 与非法方向回落', () {
      final s = CoverSettings.fromPrefMap({
        CoverSettings.keyShowStroke: 0,
        CoverSettings.keyShowShadow: 'true',
        CoverSettings.keyShowName: 1,
        CoverSettings.keyShowAuthor: 'false',
        CoverSettings.keyInfoOrientation: '9',
        CoverSettings.keyExploreFilterState: 99,
      });
      expect(s.showStroke, isFalse);
      expect(s.showShadow, isTrue);
      expect(s.showName, isTrue);
      expect(s.showAuthor, isFalse);
      expect(s.infoOrientation, '0');
      expect(s.exploreFilterState, 3);
    });

    test('toPrefMap 往返一致', () {
      final source = CoverSettings.defaults.copyWith(
        loadOnlyOnWifi: true,
        defaultAlbumId: 'album-1',
        showShadow: true,
        textColor: 0xFF112233,
        infoOrientation: '1',
        showAuthorDark: false,
      );
      final roundtrip = CoverSettings.fromPrefMap(source.toPrefMap());
      expect(roundtrip, source);
    });
  });

  group('渲染辅助语义', () {
    test('默认字体色取主题 secondary；自定义取日/夜独立色', () {
      const s = CoverSettings.defaults;
      expect(
        s.textColorFor(isNight: false, defaultColor: 0xFF123456),
        0xFF123456,
      );
      expect(
        s.textColorFor(isNight: true, defaultColor: 0xFF123456),
        0xFF123456,
      );
      final custom = s.copyWith(
        useDefaultColor: false,
        textColor: 0xFF000001,
        textColorDark: 0xFF000002,
      );
      expect(
        custom.textColorFor(isNight: false, defaultColor: 0xFF123456),
        0xFF000001,
      );
      expect(
        custom.textColorFor(isNight: true, defaultColor: 0xFF123456),
        0xFF000002,
      );
    });

    test('作者随书名：书名关闭时作者不绘制', () {
      final s = CoverSettings.defaults.copyWith(showName: false);
      expect(s.showNameFor(isNight: false), isFalse);
      expect(s.showAuthorFor(isNight: false), isFalse);
      final dark = CoverSettings.defaults.copyWith(showNameDark: false);
      expect(dark.showNameFor(isNight: true), isFalse);
      expect(dark.showAuthorFor(isNight: true), isFalse);
    });

    test('拉丁字母占比 > 30% 强制横排', () {
      expect(CoverSettings.isLatinBasedText('Harry Potter'), isTrue);
      expect(CoverSettings.isLatinBasedText('Code'), isTrue);
      expect(CoverSettings.isLatinBasedText('凡人修仙传'), isFalse);
      // 2 个拉丁 + 8 个中文 → 2/10 = 20% < 30%
      expect(CoverSettings.isLatinBasedText('Ab凡人修仙传测试测'), isFalse);
      expect(CoverSettings.isLatinBasedText(''), isFalse);
      expect(CoverSettings.isLatinBasedText(null), isFalse);
    });

    test('信息方向配置横排时优先于文本判定', () {
      final s = CoverSettings.defaults.copyWith(
        infoOrientation: CoverSettings.infoOrientationLandscape,
      );
      expect(s.horizontalFor('凡人修仙传'), isTrue);
      expect(s.horizontalFor(null), isTrue);
    });
  });

  group('CoverSettingsNotifier', () {
    test('从偏好加载并写入内存镜像', () async {
      SharedPreferences.setMockInitialValues({
        CoverSettings.keyLoadOnlyOnWifi: true,
        CoverSettings.keyShowStroke: false,
        CoverSettings.keyTextColor: 0xFF010203,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(coverSettingsProvider.notifier);
      await notifier.waitForLoad();

      final s = container.read(coverSettingsProvider);
      expect(s.loadOnlyOnWifi, isTrue);
      expect(s.showStroke, isFalse);
      expect(s.textColor, 0xFF010203);
      expect(coverSettingsListenable.value, s);
    });

    test('update 持久化变化键；reload 读回备份恢复后的值', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(coverSettingsProvider.notifier);
      await notifier.waitForLoad();

      await notifier.update(
        (s) => s.copyWith(showShadow: true, textColor: 0xFF00FF00),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(CoverSettings.keyShowShadow), isTrue);
      expect(prefs.getInt(CoverSettings.keyTextColor), 0xFF00FF00);

      // 模拟备份恢复直接改写偏好
      await prefs.setBool(CoverSettings.keyShowShadow, false);
      await prefs.setInt(CoverSettings.keyTextColor, 0xFF0000FF);
      await notifier.reload();
      final s = container.read(coverSettingsProvider);
      expect(s.showShadow, isFalse);
      expect(s.textColor, 0xFF0000FF);
    });

    test('限制比例变更同步 UiSettings 状态与偏好（复用既有键）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(coverSettingsProvider.notifier);
      await notifier.waitForLoad();

      await notifier.update((s) => s.copyWith(restrictCoverRatio: false));
      expect(container.read(uiSettingsProvider).restrictCoverRatio, isFalse);
      expect(uiSettingsListenable.value.restrictCoverRatio, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(CoverSettings.keyRestrictCoverRatio), isFalse);

      // 加载时也镜像到全局监听通道（无 ProviderScope 组件可用）
      uiSettingsListenable.value = const UiSettingsState();
      await prefs.setBool(CoverSettings.keyRestrictCoverRatio, true);
      await notifier.reload();
      expect(uiSettingsListenable.value.restrictCoverRatio, isTrue);
    });
  });

  group('备份与恢复过滤', () {
    test('封面设置全部键默认纳入备份', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(CoverSettings.keyShowShadow, true);
      await prefs.setString(CoverSettings.keyInfoOrientation, '1');

      final all = await RestoreIgnorePrefs.collectForBackup({});
      expect(all[CoverSettings.keyShowShadow], isTrue);
      expect(all[CoverSettings.keyInfoOrientation], '1');
    });

    test('勾选「忽略封面配置」后不写入备份', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(CoverSettings.keyShowShadow, true);
      await prefs.setBool(CoverSettings.keyUseDefaultColor, false);

      final filtered = await RestoreIgnorePrefs.collectForBackup({
        'coverConfig': true,
      });
      for (final key in CoverSettings.prefKeys) {
        expect(filtered.containsKey(key), isFalse, reason: key);
      }
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(CoverSettings.keyShowShadow, {
          'coverConfig': true,
        }),
        isFalse,
      );
    });
  });
}
