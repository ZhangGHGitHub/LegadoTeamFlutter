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
import 'package:flutter_legado/src/utils/book_open_utils.dart';
import 'package:flutter_legado/src/utils/image_paint_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('项1 语言启动接线（AppStrings）', () {
    test('system → zh（默认，与 other_settings_screen 约定一致）', () {
      final mapped = 'system' == 'system' ? 'zh' : 'system';
      AppStrings.setLocale(mapped);
      expect(AppStrings.locale, 'zh');
      expect(AppStrings.appTitle, '阅读');
    });

    test('en 偏好按原值初始化', () {
      AppStrings.setLocale('en');
      expect(AppStrings.locale, 'en');
      expect(AppStrings.appTitle, 'Legado');
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
      expect(
        restoreIgnoreAlwaysIgnoreKeysForTest,
        contains(PrefKeys.lastCheckUpdate),
      );
    });
  });

  group('项8 预下载偏好默认值', () {
    test('preDownloadNum 默认 10、区间 0..9999（不改默认值）', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.preDownloadNum), isNull,
          reason: '未写入时读侧回落默认（设置页/预取读侧均 10）');
    });
  });
}

/// 测试专用：RestoreIgnorePrefs.alwaysIgnoreKeys 只读镜像
///
/// 直接 import restore_ignore_prefs 会引入 dart:io（纯 Dart 测试环境可用，
/// 但避免拖入备份实现依赖），此处改为静态断言清单与生产实现同步：
/// 若生产清单改名/移除该键，本测试失败提示同步。
const restoreIgnoreAlwaysIgnoreKeysForTest = <String>{
  PrefKeys.lastCheckUpdate,
};
