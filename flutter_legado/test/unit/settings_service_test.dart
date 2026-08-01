import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = SettingsService();
  });

  group('SettingsService 字体大小', () {
    test('默认字体大小为 18.0', () async {
      expect(await service.getFontSize(), equals(18.0));
    });

    test('设置并读取字体大小', () async {
      await service.setFontSize(24.0);
      expect(await service.getFontSize(), equals(24.0));
    });

    test('多次设置取最后值', () async {
      await service.setFontSize(20.0);
      await service.setFontSize(28.0);
      expect(await service.getFontSize(), equals(28.0));
    });
  });

  group('SettingsService 行距', () {
    test('默认行距为 1.6', () async {
      expect(await service.getLineHeight(), equals(1.6));
    });

    test('设置并读取行距', () async {
      await service.setLineHeight(2.0);
      expect(await service.getLineHeight(), equals(2.0));
    });
  });

  group('SettingsService 背景色索引', () {
    test('默认背景色索引为 0', () async {
      expect(await service.getBgColorIndex(), equals(0));
    });

    test('设置并读取背景色索引', () async {
      await service.setBgColorIndex(3);
      expect(await service.getBgColorIndex(), equals(3));
    });
  });

  group('SettingsService 翻页模式（双通道）', () {
    test('getFlipMode 默认返回 -1（无旧版存储）', () async {
      expect(await service.getFlipMode(), equals(-1));
    });

    test('setFlipMode/getFlipMode 读写一致', () async {
      await service.setFlipMode(2);
      expect(await service.getFlipMode(), equals(2));
    });

    test('getFlipModeName 默认返回 null', () async {
      expect(await service.getFlipModeName(), isNull);
    });

    test('setFlipModeName/getFlipModeName 读写一致', () async {
      await service.setFlipModeName('cover');
      expect(await service.getFlipModeName(), equals('cover'));
    });

    test('setFlipModeName 支持所有枚举名', () async {
      final names = ['scroll', 'slide', 'simulate', 'none', 'cover'];
      for (final name in names) {
        await service.setFlipModeName(name);
        expect(await service.getFlipModeName(), equals(name));
      }
    });

    test('双通道同时写入互不干扰', () async {
      await service.setFlipMode(3);
      await service.setFlipModeName('cover');
      expect(await service.getFlipMode(), equals(3));
      expect(await service.getFlipModeName(), equals('cover'));
    });
  });

  group('SettingsService 亮度', () {
    test('默认亮度为 -1.0（跟随系统）', () async {
      expect(await service.getBrightness(), equals(-1.0));
    });

    test('设置并读取亮度', () async {
      await service.setBrightness(0.8);
      expect(await service.getBrightness(), equals(0.8));
    });
  });

  group('SettingsService 主题模式', () {
    test('默认主题模式为 system', () async {
      expect(await service.getThemeMode(), equals(ThemeMode.system));
    });

    test('设置为 light 模式', () async {
      await service.setThemeMode(ThemeMode.light);
      expect(await service.getThemeMode(), equals(ThemeMode.light));
    });

    test('设置为 dark 模式', () async {
      await service.setThemeMode(ThemeMode.dark);
      expect(await service.getThemeMode(), equals(ThemeMode.dark));
    });

    test('设置为 system 模式', () async {
      await service.setThemeMode(ThemeMode.dark);
      await service.setThemeMode(ThemeMode.system);
      expect(await service.getThemeMode(), equals(ThemeMode.system));
    });
  });

  group('SettingsService 全局字体缩放', () {
    test('默认字体缩放为 0（跟随系统）', () async {
      expect(await service.getFontScale(), equals(0));
    });

    test('设置并读取字体缩放', () async {
      await service.setFontScale(12);
      expect(await service.getFontScale(), equals(12));
    });

    test('重置为 0（跟随系统）', () async {
      await service.setFontScale(14);
      await service.setFontScale(0);
      expect(await service.getFontScale(), equals(0));
    });
  });

  group('SettingsService 书架偏好', () {
    test('默认显示最近阅读', () async {
      expect(await service.getShowBookshelfRecentReading(), isTrue);
    });

    test('设置隐藏最近阅读', () async {
      await service.setShowBookshelfRecentReading(false);
      expect(await service.getShowBookshelfRecentReading(), isFalse);
    });

    test('默认显示统计', () async {
      expect(await service.getShowBookshelfStats(), isTrue);
    });

    test('设置隐藏统计', () async {
      await service.setShowBookshelfStats(false);
      expect(await service.getShowBookshelfStats(), isFalse);
    });
  });

  group('SettingsService 语言设置', () {
    test('默认语言为 system', () async {
      expect(await service.getLocale(), equals('system'));
    });

    test('设置并读取语言', () async {
      await service.setLocale('zh_CN');
      expect(await service.getLocale(), equals('zh_CN'));
    });
  });

  group('SettingsService 网络设置', () {
    test('代理默认为 none', () async {
      expect(await service.getProxyType(), 'none');
      expect(await service.getProxyHost(), '');
      expect(await service.getProxyPort(), 0);
    });

    test('代理配置读写一致', () async {
      await service.setProxyType('http');
      await service.setProxyHost('127.0.0.1');
      await service.setProxyPort(7890);
      expect(await service.getProxyType(), 'http');
      expect(await service.getProxyHost(), '127.0.0.1');
      expect(await service.getProxyPort(), 7890);
    });

    test('SOCKS5 代理读写一致', () async {
      await service.setProxyType('socks5');
      await service.setProxyHost('192.168.1.10');
      await service.setProxyPort(1080);
      expect(await service.getProxyType(), 'socks5');
      expect(await service.getProxyHost(), '192.168.1.10');
      expect(await service.getProxyPort(), 1080);
    });

    test('请求超时默认 30 秒且读写一致', () async {
      expect(await service.getRequestTimeout(), 30);
      await service.setRequestTimeout(15);
      expect(await service.getRequestTimeout(), 15);
    });
  });

  group('SettingsService WebDAV 云同步配置', () {
    test('默认 WebDAV URL 为空', () async {
      expect(await service.getWebDavUrl(), equals(''));
    });

    test('设置并读取 WebDAV URL', () async {
      await service.setWebDavUrl('https://dav.example.com');
      expect(await service.getWebDavUrl(), equals('https://dav.example.com'));
    });

    test('默认用户名为空', () async {
      expect(await service.getWebDavUsername(), equals(''));
    });

    test('设置并读取用户名', () async {
      await service.setWebDavUsername('user@test.com');
      expect(await service.getWebDavUsername(), equals('user@test.com'));
    });

    test('默认密码为空', () async {
      expect(await service.getWebDavPassword(), equals(''));
    });

    test('设置并读取密码', () async {
      await service.setWebDavPassword('secret123');
      expect(await service.getWebDavPassword(), equals('secret123'));
    });

    test('默认远程目录为 /legado/', () async {
      expect(await service.getWebDavRemoteDir(), equals('/legado/'));
    });

    test('设置并读取远程目录', () async {
      await service.setWebDavRemoteDir('/backup/legado/');
      expect(await service.getWebDavRemoteDir(), equals('/backup/legado/'));
    });

    test('默认自动同步关闭', () async {
      expect(await service.getAutoSync(), isFalse);
    });

    test('开启自动同步', () async {
      await service.setAutoSync(true);
      expect(await service.getAutoSync(), isTrue);
    });

    test('默认无最后同步时间', () async {
      expect(await service.getLastSyncTime(), isNull);
    });

    test('设置并读取最后同步时间', () async {
      final now = DateTime.now();
      await service.setLastSyncTime(now);
      final result = await service.getLastSyncTime();
      expect(result, isNotNull);
      // 毫秒精度比较
      expect(result!.millisecondsSinceEpoch, equals(now.millisecondsSinceEpoch));
    });
  });
}
