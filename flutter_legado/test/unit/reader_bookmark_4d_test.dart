// [批4d] 滑动书签/角标配置与角标图存储单元测试
//
// 覆盖：
// 1. ReaderAdvancedConfig 三字段默认值/往返/夹逼/copy；
// 2. 备份与「忽略阅读配置」白名单；
// 3. BookmarkBadgeImageStore 相对标识、去重、校验、缺失回落与路径穿越。
//
// 编写：全栈工程师（批4d） ｜ 2026-11-04
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/bookmark_badge_image_store.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderAdvancedConfig 批4d 三字段', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('默认值对齐参考（false/空/10dp）', () async {
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.swipeToAddBookmark, isFalse);
      expect(cfg.bookmarkBadgeImage, '');
      expect(cfg.bookmarkBadgeSize, 10);
    });

    test('save → load 往返一致', () async {
      final cfg = await ReaderAdvancedConfig.load()
        ..swipeToAddBookmark = true
        ..bookmarkBadgeImage = 'bookmark_badges/${'a'.padRight(32, 'a')}.png'
        ..bookmarkBadgeSize = 28;
      await cfg.save();

      final reloaded = await ReaderAdvancedConfig.load();
      expect(reloaded.swipeToAddBookmark, isTrue);
      expect(reloaded.bookmarkBadgeImage, 'bookmark_badges/${'a'.padRight(32, 'a')}.png');
      expect(reloaded.bookmarkBadgeSize, 28);

      // 键名逐字对齐参考 PreferKey
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrefKeys.swipeToAddBookmark), isTrue);
      expect(
        prefs.getString(PrefKeys.bookmarkBadgeImage),
        'bookmark_badges/${'a'.padRight(32, 'a')}.png',
      );
      expect(prefs.getInt(PrefKeys.bookmarkBadgeSize), 28);
    });

    test('读取/写入均夹逼 0..50', () async {
      SharedPreferences.setMockInitialValues({PrefKeys.bookmarkBadgeSize: 99});
      final loaded = await ReaderAdvancedConfig.load();
      expect(loaded.bookmarkBadgeSize, 50, reason: 'load 夹逼上界');

      loaded.bookmarkBadgeSize = 99;
      await loaded.save();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.bookmarkBadgeSize), 50, reason: 'save 夹逼上界');

      SharedPreferences.setMockInitialValues({PrefKeys.bookmarkBadgeSize: -5});
      final low = await ReaderAdvancedConfig.load();
      expect(low.bookmarkBadgeSize, 0, reason: '负数夹逼为 0（隐藏角标）');
    });

    test('copy() 携带三字段且与原实例隔离', () {
      final cfg = ReaderAdvancedConfig()
        ..swipeToAddBookmark = true
        ..bookmarkBadgeImage = 'bookmark_badges/${'b'.padRight(32, 'b')}.jpg'
        ..bookmarkBadgeSize = 20;
      final copied = cfg.copy()..bookmarkBadgeSize = 5;
      expect(copied.swipeToAddBookmark, isTrue);
      expect(copied.bookmarkBadgeImage, 'bookmark_badges/${'b'.padRight(32, 'b')}.jpg');
      expect(copied.bookmarkBadgeSize, 5);
      expect(cfg.bookmarkBadgeSize, 20, reason: '副本修改不影响原实例');
    });
  });

  group('备份与忽略阅读配置', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        PrefKeys.swipeToAddBookmark: true,
        PrefKeys.bookmarkBadgeImage: 'bookmark_badges/${'c'.padRight(32, 'c')}.png',
        PrefKeys.bookmarkBadgeSize: 12,
        'unrelatedKey': 'x',
      });
    });

    test('三键在 readPrefKeys 白名单', () {
      for (final key in const [
        PrefKeys.swipeToAddBookmark,
        PrefKeys.bookmarkBadgeImage,
        PrefKeys.bookmarkBadgeSize,
      ]) {
        expect(
          RestoreIgnorePrefs.readPrefKeys.contains(key),
          isTrue,
          reason: '键 $key 必须随「忽略阅读配置」被过滤',
        );
      }
    });

    test('默认随备份写入；勾选 readConfig 后过滤', () async {
      final all = await RestoreIgnorePrefs.collectForBackup(const {});
      expect(all[PrefKeys.swipeToAddBookmark], isTrue);
      expect(
        all[PrefKeys.bookmarkBadgeImage],
        'bookmark_badges/${'c'.padRight(32, 'c')}.png',
      );
      expect(all[PrefKeys.bookmarkBadgeSize], 12);

      final ignored = await RestoreIgnorePrefs.collectForBackup(const {
        'readConfig': true,
      });
      expect(ignored.containsKey(PrefKeys.swipeToAddBookmark), isFalse);
      expect(ignored.containsKey(PrefKeys.bookmarkBadgeImage), isFalse);
      expect(ignored.containsKey(PrefKeys.bookmarkBadgeSize), isFalse);
      expect(ignored['unrelatedKey'], 'x', reason: '非阅读键不受影响');
    });
  });

  group('BookmarkBadgeImageStore', () {
    late Directory tempDir;
    late Future<Directory> Function() originalSupportDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('badge_store_');
      originalSupportDir = BookmarkBadgeImageStore.supportDir;
      BookmarkBadgeImageStore.supportDir = () async => tempDir;
      BookmarkBadgeImageStore.resetWarmCache();
    });

    tearDown(() async {
      BookmarkBadgeImageStore.supportDir = originalSupportDir;
      BookmarkBadgeImageStore.resetWarmCache();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    Uint8List bytes(List<int> seed) => Uint8List.fromList(seed);

    test('storeBytes 落盘并返回自有相对标识；resolveSync 可解析', () async {
      final id = await BookmarkBadgeImageStore.storeBytes(
        bytes([1, 2, 3, 4]),
        originalName: 'badge.PNG',
      );
      expect(
        RegExp(
          r'^bookmark_badges/[0-9a-f]{32}\.png$',
        ).hasMatch(id),
        isTrue,
        reason: '扩展名小写归一，标识只含相对路径',
      );
      expect(
        File('${tempDir.path}${Platform.pathSeparator}$id').existsSync(),
        isTrue,
      );
      expect(BookmarkBadgeImageStore.resolveSync(id), isNotNull);
    });

    test('相同内容+扩展名去重；未知扩展回落 jpg', () async {
      final a = await BookmarkBadgeImageStore.storeBytes(
        bytes([9, 9, 9]),
        originalName: 'a.webp',
      );
      final b = await BookmarkBadgeImageStore.storeBytes(
        bytes([9, 9, 9]),
        originalName: 'b.webp',
      );
      expect(a, b, reason: '同字节同扩展名命中同一文件，不重复写盘');

      final unknown = await BookmarkBadgeImageStore.storeBytes(
        bytes([7]),
        originalName: 'noext',
      );
      expect(unknown.endsWith('.jpg'), isTrue);
    });

    test('空/超限字节拒绝', () async {
      expect(
        () => BookmarkBadgeImageStore.storeBytes(
          Uint8List(0),
          originalName: 'a.png',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => BookmarkBadgeImageStore.storeBytes(
          Uint8List(BookmarkBadgeImageStore.maxBytes + 1),
          originalName: 'a.png',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('缺失文件/非自有标识/路径穿越 → null（调用方回落默认角标）', () async {
      await BookmarkBadgeImageStore.ensureWarm();
      final missing = 'bookmark_badges/${'d'.padRight(32, 'd')}.png';
      expect(BookmarkBadgeImageStore.resolveSync(missing), isNull);

      expect(
        BookmarkBadgeImageStore.resolveSync('bookmark_badges/../evil.png'),
        isNull,
        reason: '备份中的路径穿越不得解析',
      );
      expect(
        BookmarkBadgeImageStore.resolveSync(
          '${tempDir.path}/bookmark_badges/${'e'.padRight(32, 'e')}.png',
        ),
        isNull,
        reason: '只接受相对标识',
      );
      expect(BookmarkBadgeImageStore.resolveSync(''), isNull);
      expect(BookmarkBadgeImageStore.resolveSync(null), isNull);
    });

    test('ensureWarm 后 resolveSync 使用当前 Support 目录', () async {
      final id = await BookmarkBadgeImageStore.storeBytes(
        bytes([5, 5]),
        originalName: 'x.png',
      );
      BookmarkBadgeImageStore.resetWarmCache();
      expect(BookmarkBadgeImageStore.resolveSync(id), isNull, reason: '未预热');
      await BookmarkBadgeImageStore.ensureWarm();
      expect(BookmarkBadgeImageStore.resolveSync(id), isNotNull);
    });
  });
}
