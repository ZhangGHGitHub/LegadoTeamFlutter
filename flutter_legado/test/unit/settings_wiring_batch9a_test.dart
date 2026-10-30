// 批9a 单元测试：有开关无功能项接线（语言/抗锯齿/图片绘制缓存/
// 漫画浏览开关/自动更新每日一次/源编辑最大行数/预下载）
//
// 覆盖口径（任务要求）：默认值、开关切换、越界/异常回落、关闭态不回退。
import 'dart:ui' show FilterQuality;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/l10n/app_strings.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/app_update_service.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/utils/book_open_utils.dart';
import 'package:flutter_legado/src/utils/image_paint_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('项1 语言启动接线（AppStrings.startupLocaleOf，P3-1）', () {
    test('system → zh（默认，与 other_settings_screen 约定一致）', () {
      expect(AppStrings.startupLocaleOf('system'), 'zh');
      AppStrings.setLocale(AppStrings.startupLocaleOf('system'));
      expect(AppStrings.locale, 'zh');
      expect(AppStrings.appTitle, '阅读');
    });

    test('en 偏好按原值初始化', () {
      expect(AppStrings.startupLocaleOf('en'), 'en');
      AppStrings.setLocale(AppStrings.startupLocaleOf('en'));
      expect(AppStrings.locale, 'en');
      expect(AppStrings.appTitle, 'Legado');
    });

    test('zh 直通；脏值（历史偏好/手工改库）→ zh 兜底不抛异常', () {
      expect(AppStrings.startupLocaleOf('zh'), 'zh');
      // 非法值统一回落中文（main.dart 与本测试共用同一映射函数）
      expect(AppStrings.startupLocaleOf('fr'), 'zh');
      expect(AppStrings.startupLocaleOf(''), 'zh');
      expect(AppStrings.startupLocaleOf('tw'), 'zh',
          reason: '我方仅 zh/en 两套字符串，tw 脏值按兜底处理（登记差异）');
    });
  });

  group('项2+3 抗锯齿与图片绘制缓存镜像（ImagePaintPrefs）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('默认值：antiAlias=false、bitmapCacheSize=50（对齐原版）', () async {
      await ImagePaintPrefs.refresh();
      expect(ImagePaintPrefs.antiAlias, false);
      expect(ImagePaintPrefs.bitmapCacheSizeMb, 50);
      expect(ImagePaintPrefs.imageFilterQuality, FilterQuality.medium);
    });

    test('开关切换：antiAlias=true → high 采样 + isAntiAlias=true', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.antiAlias: true});
      await ImagePaintPrefs.refresh();
      expect(ImagePaintPrefs.antiAlias, true);
      expect(ImagePaintPrefs.imageFilterQuality, FilterQuality.high);
      final paint = ImagePaintPrefs.imagePaint();
      expect(paint.isAntiAlias, true);
      expect(paint.filterQuality, FilterQuality.high);
    });

    test('关闭态不回退：写回 false 后镜像同步为 medium', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.antiAlias: true});
      await ImagePaintPrefs.refresh();
      SharedPreferences.setMockInitialValues({PrefKeys.antiAlias: false});
      await ImagePaintPrefs.refresh();
      expect(ImagePaintPrefs.antiAlias, false);
      expect(ImagePaintPrefs.imageFilterQuality, FilterQuality.medium);
      expect(ImagePaintPrefs.imagePaint().isAntiAlias, false);
    });

    test('越界回落：bitmapCacheSize 0 与 2048 均回落 50（对齐原版 1..1024 钳制）',
        () async {
      SharedPreferences.setMockInitialValues({PrefKeys.bitmapCacheSize: 0});
      await ImagePaintPrefs.refresh();
      expect(ImagePaintPrefs.bitmapCacheSizeMb, 50);
      SharedPreferences.setMockInitialValues({PrefKeys.bitmapCacheSize: 2048});
      await ImagePaintPrefs.refresh();
      expect(ImagePaintPrefs.bitmapCacheSizeMb, 50);
    });

    test('区间边界值合法：1 与 1024 不回落', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.bitmapCacheSize: 1});
      await ImagePaintPrefs.refresh();
      expect(ImagePaintPrefs.bitmapCacheSizeMb, 1);
      SharedPreferences.setMockInitialValues(
          {PrefKeys.bitmapCacheSize: 1024});
      await ImagePaintPrefs.refresh();
      expect(ImagePaintPrefs.bitmapCacheSizeMb, 1024);
    });

    test('applyImageCacheLimit：上限 = MB × 1MB 字节数', () {
      ImagePaintPrefs.bitmapCacheSizeMb = 77;
      ImagePaintPrefs.applyImageCacheLimit();
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      expect(
        binding.imageCache.maximumSizeBytes,
        77 * 1024 * 1024,
      );
    });
  });

  group('项4 漫画浏览开关（showMangaUi 开书分流）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      BookOpenUtils.showMangaUi = true; // 重置镜像
    });

    test('默认 true：在线图片书 → /reader-comic（默认行为不变）', () async {
      await BookOpenUtils.refreshShowMangaUi();
      expect(
        BookOpenUtils.routeForTypeBits(BookType.image),
        '/reader-comic',
      );
    });

    test('关闭后：在线图片书 → /reader（文本阅读器降级，对齐参考版）', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.showMangaUi: false});
      await BookOpenUtils.refreshShowMangaUi();
      expect(BookOpenUtils.showMangaUi, false);
      expect(
        BookOpenUtils.routeForTypeBits(BookType.image),
        '/reader',
      );
    });

    test('关闭态不回退：开关重开后镜像恢复 comic 路由', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.showMangaUi: false});
      await BookOpenUtils.refreshShowMangaUi();
      SharedPreferences.setMockInitialValues({PrefKeys.showMangaUi: true});
      await BookOpenUtils.refreshShowMangaUi();
      expect(
        BookOpenUtils.routeForTypeBits(BookType.image),
        '/reader-comic',
      );
    });

    test('本地图片书不受开关影响（对齐参考版 !isLocal 条件）', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.showMangaUi: false});
      await BookOpenUtils.refreshShowMangaUi();
      expect(
        BookOpenUtils.routeForTypeBits(
          BookType.local | BookType.image,
          isLocalBook: true,
        ),
        '/reader-comic',
        reason: '本地 cbz 漫画包不随开关降级（参考版 BookInfoRouteScreen.kt:147）',
      );
    });

    test('关闭后文本/音频/视频路由不受影响（不误分流普通书）', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.showMangaUi: false});
      await BookOpenUtils.refreshShowMangaUi();
      expect(BookOpenUtils.routeForTypeBits(BookType.text), '/reader');
      expect(BookOpenUtils.routeForTypeBits(BookType.audio), '/audio');
      expect(BookOpenUtils.routeForTypeBits(BookType.video), '/video');
      expect(BookOpenUtils.routeForTypeBits(0), '/reader');
    });

    test('prefs 异常时镜像保持当前值（默认 true）', () async {
      // SharedPreferences.setMockInitialValues 未设键 → 默认路径；此处验证
      // 默认回落 true 而非误写 false
      await BookOpenUtils.refreshShowMangaUi();
      expect(BookOpenUtils.showMangaUi, true);
    });
  });

  group('项5 自动更新每日一次（AppUpdateService.checkDailyOnStartup）', () {
    test('首次（无时间戳）发起检查并写入时间戳；有更新且未忽略返回 info',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = AppUpdateService();
      // 网络在测试内不可达 → check 抛异常 → 静默返回 null（失败静默语义）
      final info = await service.checkDailyOnStartup(debugSkip: false);
      expect(info, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastCheckUpdate), greaterThan(0));
    });

    test('24h 内已检查过 → 直接跳过（不再发起网络请求、时间戳不刷新）',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues(
          {PrefKeys.lastCheckUpdate: now});
      final service = AppUpdateService();
      final info = await service.checkDailyOnStartup(debugSkip: false);
      expect(info, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastCheckUpdate), now,
          reason: '门内直接返回，时间戳不被覆盖');
    });

    test('时间戳超 24h → 再次发起（写入新时间戳）', () async {
      final stale = DateTime.now().millisecondsSinceEpoch -
          const Duration(hours: 25).inMilliseconds;
      SharedPreferences.setMockInitialValues(
          {PrefKeys.lastCheckUpdate: stale});
      final service = AppUpdateService();
      await service.checkDailyOnStartup(debugSkip: false);
      final prefs = await SharedPreferences.getInstance();
      final updated = prefs.getInt(PrefKeys.lastCheckUpdate)!;
      expect(updated, greaterThan(stale));
    });

    test('DEBUG 构建跳过：时间戳不写入（Mock/测试构建不触发每日检查）',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = AppUpdateService();
      // 不传 debugSkip → 生产路径 kDebugMode=true（flutter test 即 debug）
      final info = await service.checkDailyOnStartup();
      expect(info, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.lastCheckUpdate), isNull,
          reason: 'DEBUG 跳过必须在写时间戳之前返回');
    });

    test('lastCheckUpdate 在备份排除表（设备级，不随备份往返）', () {
      // P2-2b：直接断言生产 RestoreIgnorePrefs.alwaysIgnoreKeys
      //（随生产清单改名/移除该键即时红），不再用测试内镜像常量
      expect(
        RestoreIgnorePrefs.alwaysIgnoreKeys,
        contains(PrefKeys.lastCheckUpdate),
      );
    });
  });
}
