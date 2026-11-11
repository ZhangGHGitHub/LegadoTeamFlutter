// [应用字体入口 | 2026-11-11] AppFontStore 单测 — 全栈工程师
//
// 覆盖：合法 TTF 导入落盘 + 偏好写入、10MB 上限、扩展名白名单、文件头/
// 表目录校验、相对标识解析、清除删除文件与偏好、不存在/损坏返回 null、
// 替换字体删除旧自有文件、字体文件不被主题背景图孤儿清理误删、以及
// 「应用字体不触碰阅读正文字体」的分离约束。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/services/app_font_store.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';

/// 构造一个结构合法的最小 sfnt（1 个 head 表，表数据 4 字节）
Uint8List validSfnt({int tag = 0x00010000}) {
  final bytes = Uint8List(32);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, tag);
  data.setUint16(4, 1); // numTables
  data.setUint16(6, 16); // searchRange
  data.setUint16(8, 0); // entrySelector
  data.setUint16(10, 0); // rangeShift
  data.setUint32(12, 0x68656164); // 'head'
  data.setUint32(16, 0); // checksum
  data.setUint32(20, 28); // table offset
  data.setUint32(24, 4); // table length
  data.setUint32(28, 0); // table data
  return bytes;
}

/// 构造一个结构合法的最小 TTC（1 个成员字体）
Uint8List validTtc() {
  final sfnt = validSfnt();
  final bytes = Uint8List(16 + sfnt.length);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0x74746366); // 'ttcf'
  data.setUint32(4, 0x00010000); // version
  data.setUint32(8, 1); // numFonts
  data.setUint32(12, 16); // 第一个成员字体的绝对偏移
  bytes.setRange(16, 16 + sfnt.length, sfnt);
  // TTC 成员的表偏移是文件内绝对偏移：修正为 16 + 28
  data.setUint32(16 + 20, 44);
  return bytes;
}

void main() {
  late Directory temp;
  late Future<Directory> Function() originalSupportDir;
  late Future<AppFontPick?> Function() originalPicker;
  late Future<void> Function(String, Future<ByteData>) originalLoader;
  late Future<Directory> Function() originalThemeSupportDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('legado_app_font_');
    originalSupportDir = AppFontStore.supportDir;
    originalPicker = AppFontStore.picker;
    originalLoader = AppFontStore.engineLoader;
    originalThemeSupportDir = ThemeBackgroundImageStore.supportDir;
    AppFontStore.supportDir = () async => temp;
    AppFontStore.warmWith(temp);
    AppFontStore.engineLoader = (family, bytes) async {};
    ThemeBackgroundImageStore.supportDir = () async => temp;
    ThemeBackgroundImageStore.warmWith(temp);
  });

  tearDown(() async {
    AppFontStore.supportDir = originalSupportDir;
    AppFontStore.resetWarmCache();
    AppFontStore.picker = originalPicker;
    AppFontStore.engineLoader = originalLoader;
    ThemeBackgroundImageStore.supportDir = originalThemeSupportDir;
    ThemeBackgroundImageStore.resetWarmCache();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  File fontFile(String id) => File(
    '${temp.path}${Platform.pathSeparator}${id.replaceAll('/', Platform.pathSeparator)}',
  );

  test('导入合法 TTF：文件落盘、偏好写入相对标识、可解析为绝对路径', () async {
    final bytes = validSfnt();
    final id = await AppFontStore.importBytes(bytes, originalName: '我的字体.ttf');

    expect(id, 'app_font/我的字体.ttf');
    final file = fontFile(id);
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync(), bytes);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.appFontPath), id);

    // 相对标识 → 当前 Support 目录运行时拼接
    expect(AppFontStore.resolveSync(id), file.absolute.path);
    expect(AppFontStore.isUsableSync(id), isTrue);
    expect(AppFontStore.displayNameOf(id), '我的字体.ttf');
    expect(await AppFontStore.loadablePath(id), file.absolute.path);
  });

  test('导入合法 TTC：ttcf 魔数 + 成员表目录校验通过', () async {
    final id = await AppFontStore.importBytes(
      validTtc(),
      originalName: 'collection.ttc',
    );
    expect(AppFontStore.isUsableSync(id), isTrue);
  });

  test('超过 10MB 拒绝并提示，不写偏好', () async {
    final huge = Uint8List(AppFontStore.maxBytes + 1);
    await expectLater(
      AppFontStore.importBytes(huge, originalName: 'big.ttf'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('过大'),
        ),
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.appFontPath), isNull);
  });

  test('非 ttf/otf/ttc 扩展名拒绝', () async {
    await expectLater(
      AppFontStore.importBytes(validSfnt(), originalName: 'font.woff'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('不支持的字体格式'),
        ),
      ),
    );
  });

  test('扩展名合法但文件头/表目录损坏拒绝', () async {
    // 魔数非法
    await expectLater(
      AppFontStore.importBytes(
        Uint8List.fromList(List<int>.filled(64, 0x41)),
        originalName: 'bad.ttf',
      ),
      throwsA(isA<FormatException>()),
    );
    // 魔数合法但表目录越界（截断）
    final truncated = validSfnt().sublist(0, 20);
    await expectLater(
      AppFontStore.importBytes(
        Uint8List.fromList(truncated),
        originalName: 'truncated.otf',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('损坏'),
        ),
      ),
    );
  });

  test('替换字体：删除旧自有文件，仅保留新文件与偏好', () async {
    final first = await AppFontStore.importBytes(
      validSfnt(),
      originalName: 'first.ttf',
    );
    final firstFile = fontFile(first);
    expect(firstFile.existsSync(), isTrue);

    final second = await AppFontStore.importBytes(
      validSfnt(),
      originalName: 'second.otf',
    );
    final prefs = await SharedPreferences.getInstance();

    expect(second, 'app_font/second.otf');
    expect(prefs.getString(PrefKeys.appFontPath), second);
    expect(firstFile.existsSync(), isFalse);
    expect(fontFile(second).existsSync(), isTrue);
  });

  test('清除：删除文件并移除偏好', () async {
    final id = await AppFontStore.importBytes(
      validSfnt(),
      originalName: 'clear-me.ttf',
    );
    final file = fontFile(id);
    expect(file.existsSync(), isTrue);

    await AppFontStore.clear();

    expect(file.existsSync(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.appFontPath), isNull);
  });

  test('读取不存在 → null；损坏文件 → null 且加载回退提示', () async {
    const missing = 'app_font/not-exist.ttf';
    expect(AppFontStore.isUsableSync(missing), isFalse);
    expect(await AppFontStore.loadablePath(missing), isNull);
    final missingResult = await AppFontStore.load(missing);
    expect(missingResult.isSuccess, isFalse);
    expect(missingResult.errorMessage, contains('缺失'));

    // 魔数合法但截断：isUsableSync=false，加载提示损坏
    final dir = Directory('${temp.path}${Platform.pathSeparator}app_font');
    await dir.create(recursive: true);
    final corrupt = File('${dir.path}${Platform.pathSeparator}corrupt.ttf');
    corrupt.writeAsBytesSync(validSfnt().sublist(0, 20));
    const corruptId = 'app_font/corrupt.ttf';
    expect(AppFontStore.isUsableSync(corruptId), isFalse);
    expect(await AppFontStore.loadablePath(corruptId), isNull);
    final corruptResult = await AppFontStore.load(corruptId);
    expect(corruptResult.isSuccess, isFalse);
    expect(corruptResult.errorMessage, isNotNull);
  });

  test('加载成功返回字体族名；加载异常/超时回退默认字体', () async {
    final id = await AppFontStore.importBytes(
      validSfnt(),
      originalName: 'load.ttf',
    );
    String? seenFamily;
    AppFontStore.engineLoader = (family, bytes) async {
      seenFamily = family;
      expect((await bytes).lengthInBytes, greaterThan(0));
    };
    final ok = await AppFontStore.load(id);
    expect(ok.isSuccess, isTrue);
    expect(ok.family, AppFontStore.familyForBytes(validSfnt()));
    expect(seenFamily, ok.family);

    AppFontStore.engineLoader = (family, bytes) async {
      throw Exception('引擎拒绝');
    };
    final failed = await AppFontStore.load(id);
    expect(failed.isSuccess, isFalse);
    expect(failed.errorMessage, contains('加载失败'));

    AppFontStore.engineLoader = (family, bytes) => Completer<void>().future;
    final timedOut = await AppFontStore.load(
      id,
      timeout: const Duration(milliseconds: 20),
    );
    expect(timedOut.isSuccess, isFalse);
    expect(timedOut.errorMessage, contains('超时'));
  });

  test('应用字体不触碰阅读正文字体偏好', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_font_family': 'Custom_ReaderFont',
      'reader_custom_fonts': <String>['Custom_ReaderFont|fonts/reader.ttf'],
    });
    final id = await AppFontStore.importBytes(
      validSfnt(),
      originalName: 'app.ttf',
    );
    await AppFontStore.load(id);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.appFontPath), id);
    expect(prefs.getString('reader_font_family'), 'Custom_ReaderFont');
    expect(prefs.getStringList('reader_custom_fonts'), <String>[
      'Custom_ReaderFont|fonts/reader.ttf',
    ]);
  });

  test('字体族按内容哈希：同名不同内容 → 不同族名（切换立即生效）', () {
    final a = validSfnt();
    final b = validSfnt();
    b[31] = 1; // 表数据末字节变化，结构仍合法
    final familyA = AppFontStore.familyForBytes(a);
    final familyB = AppFontStore.familyForBytes(b);

    expect(familyA, startsWith('AppCustomFont_'));
    expect(familyA, isNot(familyB));
  });

  test('字体文件不在主题背景图孤儿清理范围内（不会被误删）', () async {
    final id = await AppFontStore.importBytes(
      validSfnt(),
      originalName: 'keep-me.ttf',
    );
    final file = fontFile(id);
    expect(file.existsSync(), isTrue);

    final removed = ThemeBackgroundImageStore.cleanupOrphansSync(
      keep: const <String>[],
    );

    expect(removed, 0);
    expect(file.existsSync(), isTrue);
  });
}
