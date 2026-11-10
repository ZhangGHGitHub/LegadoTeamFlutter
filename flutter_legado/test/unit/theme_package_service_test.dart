// [批14 | 2026-11-10] App 主题包 zip 导出/导入单测 — 全栈工程师
//
// 覆盖：12 色槽（含 0）往返、paletteId/isNight/名称、背景图字节往返、
// 仅 light / 仅 dark / 都无、清单版本/缺 config/缺 manifest/0 字节/
// 非法路径/超大条目/总量超限/未知资源忽略、重名递增与文件名净化。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/theme/theme_colors_notifier.dart';
import 'package:flutter_legado/src/services/theme_package_service.dart';

Uint8List _pngBytes({int width = 1, int height = 1}) =>
    Uint8List.fromList(img.encodePng(img.Image(width: width, height: height)));

Uint8List _zip(List<ArchiveFile> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.addFile(entry);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

ArchiveFile _textEntry(String name, String content) =>
    ArchiveFile.bytes(name, utf8.encode(content));

String _manifest({
  int version = 1,
  String name = '测试主题',
  bool isNight = false,
  int? paletteId,
  Map<String, int> colors = const {},
  Map<String, String> background = const {},
}) => jsonEncode(<String, dynamic>{
  'formatVersion': version,
  'name': name,
  'appVersion': '2.0.482',
  'config': <String, dynamic>{
    'isNight': isNight,
    'paletteId': paletteId,
    'colors': colors,
  },
  'assets': <String, dynamic>{'background': background},
});

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('legado_theme_package_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> writeFile(String name, List<int> bytes) async {
    final file = File('${temp.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<File> writeZip(String name, List<int> bytes) => writeFile(name, bytes);

  const colors = ThemeColorsState(
    primary: 0xFF112233,
    accent: 0,
    background: 0xFF445566,
    bottomBackground: 0,
    primaryNight: 0xFF778899,
    accentNight: 0,
    backgroundNight: 0xFFAABBCC,
    bottomBackgroundNight: 0,
    primaryTextColor: 0xFF010203,
    secondaryTextColor: 0,
    primaryTextColorNight: 0xFF040506,
    secondaryTextColorNight: 0,
  );

  test('export→import 往返：12 槽含 0、paletteId、isNight、名称、背景图字节一致', () async {
    final light = await writeFile('light.png', _pngBytes(width: 1, height: 1));
    final dark = await writeFile('dark.png', _pngBytes(width: 2, height: 2));
    final target = '${temp.path}${Platform.pathSeparator}package.zip';

    await ThemePackageService.exportThemePackage(
      name: '夜色 主题',
      colors: colors,
      paletteId: 7,
      isNight: true,
      backgroundLight: light,
      backgroundDark: dark,
      targetPath: target,
    );

    // zip 结构：清单 + 日/夜背景图（存在才写）
    final archive = ZipDecoder().decodeBytes(await File(target).readAsBytes());
    expect(
      archive.map((entry) => entry.name).toSet(),
      equals(<String>{
        'manifest.json',
        'assets/background/light.png',
        'assets/background/dark.png',
      }),
    );

    final data = await ThemePackageService.importThemePackage(File(target));
    expect(data.name, '夜色 主题');
    expect(data.isNight, isTrue);
    expect(data.paletteId, 7);
    // 单测环境无 PackageInfo 插件，appVersion 允许为空但不能缺字段
    expect(data.appVersion, isA<String>());
    expect(
      data.colors,
      equals(<String, int>{
        PrefKeys.cPrimary: 0xFF112233,
        PrefKeys.cAccent: 0,
        PrefKeys.cBackground: 0xFF445566,
        PrefKeys.cBBackground: 0,
        PrefKeys.cPrimaryText: 0xFF010203,
        PrefKeys.cSecondaryText: 0,
        PrefKeys.cNPrimary: 0xFF778899,
        PrefKeys.cNAccent: 0,
        PrefKeys.cNBackground: 0xFFAABBCC,
        PrefKeys.cNBBackground: 0,
        PrefKeys.cNPrimaryText: 0xFF040506,
        PrefKeys.cNSecondaryText: 0,
      }),
    );
    expect(data.backgroundLight, equals(await light.readAsBytes()));
    expect(data.backgroundDark, equals(await dark.readAsBytes()));
    expect(data.backgroundLightName, 'assets/background/light.png');
    expect(data.backgroundDarkName, 'assets/background/dark.png');
  });

  test('背景图仅 light：dark 字节为 null', () async {
    final light = await writeFile('only_light.png', _pngBytes());
    final target = '${temp.path}${Platform.pathSeparator}light.zip';

    await ThemePackageService.exportThemePackage(
      name: '仅日间',
      colors: colors,
      targetPath: target,
      backgroundLight: light,
    );

    final data = await ThemePackageService.importThemePackage(File(target));
    expect(data.backgroundLight, equals(await light.readAsBytes()));
    expect(data.backgroundDark, isNull);
    expect(data.backgroundDarkName, isNull);
  });

  test('背景图仅 dark：light 字节为 null', () async {
    final dark = await writeFile('only_dark.png', _pngBytes());
    final target = '${temp.path}${Platform.pathSeparator}dark.zip';

    await ThemePackageService.exportThemePackage(
      name: '仅夜间',
      colors: colors,
      isNight: true,
      targetPath: target,
      backgroundDark: dark,
    );

    final data = await ThemePackageService.importThemePackage(File(target));
    expect(data.backgroundLight, isNull);
    expect(data.backgroundLightName, isNull);
    expect(data.backgroundDark, equals(await dark.readAsBytes()));
  });

  test('背景图都无：assets.background 为空且导入为 null', () async {
    final target = '${temp.path}${Platform.pathSeparator}none.zip';

    await ThemePackageService.exportThemePackage(
      name: '无背景',
      colors: colors,
      targetPath: target,
    );

    final data = await ThemePackageService.importThemePackage(File(target));
    expect(data.backgroundLight, isNull);
    expect(data.backgroundDark, isNull);
    final archive = ZipDecoder().decodeBytes(await File(target).readAsBytes());
    expect(
      archive.map((entry) => entry.name),
      equals(<String>['manifest.json']),
    );
  });

  test('formatVersion=2 → 不支持的主题包版本: 2', () async {
    final zip = await writeZip(
      'v2.zip',
      _zip([
        _textEntry(
          'manifest.json',
          _manifest(version: 2, colors: {PrefKeys.cPrimary: 1}),
        ),
      ]),
    );

    await expectLater(
      ThemePackageService.importThemePackage(zip),
      throwsA(
        isA<ThemePackageException>().having(
          (e) => e.message,
          'message',
          '不支持的主题包版本: 2',
        ),
      ),
    );
  });

  test('缺 config → 主题包清单不完整', () async {
    final zip = await writeZip(
      'no_config.zip',
      _zip([
        _textEntry(
          'manifest.json',
          jsonEncode({'formatVersion': 1, 'name': '无配置'}),
        ),
      ]),
    );

    await expectLater(
      ThemePackageService.importThemePackage(zip),
      throwsA(
        isA<ThemePackageException>().having(
          (e) => e.message,
          'message',
          '主题包清单不完整',
        ),
      ),
    );
  });

  test('缺 manifest → 主题包清单不完整', () async {
    final zip = await writeZip(
      'no_manifest.zip',
      _zip([_textEntry('assets/background/light.png', 'x')]),
    );

    await expectLater(
      ThemePackageService.importThemePackage(zip),
      throwsA(
        isA<ThemePackageException>().having(
          (e) => e.message,
          'message',
          '主题包清单不完整',
        ),
      ),
    );
  });

  test('0 字节 zip → 主题包文件为空', () async {
    final zip = await writeZip('empty.zip', const <int>[]);

    await expectLater(
      ThemePackageService.importThemePackage(zip),
      throwsA(
        isA<ThemePackageException>().having(
          (e) => e.message,
          'message',
          contains('为空'),
        ),
      ),
    );
  });

  test('非法 zip → 无法读取主题包', () async {
    final zip = await writeZip('bad.zip', utf8.encode('not a zip file'));

    await expectLater(
      ThemePackageService.importThemePackage(zip),
      throwsA(
        isA<ThemePackageException>().having(
          (e) => e.message,
          'message',
          contains('无法读取主题包'),
        ),
      ),
    );
  });

  test('条目名含 ../ → 非法路径', () async {
    final zip = await writeZip(
      'traversal.zip',
      _zip([
        _textEntry('manifest.json', _manifest(colors: {PrefKeys.cPrimary: 1})),
        _textEntry('../evil.png', 'x'),
      ]),
    );

    await expectLater(
      ThemePackageService.importThemePackage(zip),
      throwsA(
        isA<ThemePackageException>().having(
          (e) => e.message,
          'message',
          contains('非法路径'),
        ),
      ),
    );
  });

  test('条目名含反斜杠 → 非法路径', () async {
    final zip = await writeZip(
      'backslash.zip',
      _zip([
        _textEntry('manifest.json', _manifest(colors: {PrefKeys.cPrimary: 1})),
        _textEntry(r'assets\background\light.png', 'x'),
      ]),
    );

    await expectLater(
      ThemePackageService.importThemePackage(zip),
      throwsA(
        isA<ThemePackageException>().having(
          (e) => e.message,
          'message',
          contains('非法路径'),
        ),
      ),
    );
  });

  test('伪造小 size + 实际超 32MB → 流式解压中止并报条目过大', () async {
    // 中央目录声明 1 字节，实际写入 32MB+1（全 0，压缩后很小）：
    // 头部预检无法识别，必须由解压时的限长输出流中止。
    final oversized = Uint8List(ThemePackageService.maxEntryBytes + 1);
    final zip = await writeZip(
      'too_big_entry.zip',
      _zip([
        _textEntry('manifest.json', _manifest(colors: {PrefKeys.cPrimary: 1})),
        ArchiveFile('assets/background/big.png', 1, oversized),
      ]),
    );

    await expectLater(
      ThemePackageService.importThemePackage(zip),
      throwsA(
        isA<ThemePackageException>().having(
          (e) => e.message,
          'message',
          allOf(contains('条目过大'), contains('32MB')),
        ),
      ),
    );
  });

  test('伪造小 size + 实际总量超 512MB → 流式累计中止', () async {
    // 17 条各声明 1 字节、实际各 32MB（单条不超限），累计 544MB；
    // 头部预检通过，解压侧按实际写出字节累计到 512MB 即中止。
    final chunk = Uint8List(ThemePackageService.maxEntryBytes);
    final entries = <ArchiveFile>[
      _textEntry('manifest.json', _manifest(colors: {PrefKeys.cPrimary: 1})),
      for (var i = 0; i < 17; i++)
        ArchiveFile('assets/background/big$i.png', 1, chunk),
    ];

    await expectLater(
      ThemePackageService.importThemePackage(
        await writeZip('total.zip', _zip(entries)),
      ),
      throwsA(
        isA<ThemePackageException>().having(
          (e) => e.message,
          'message',
          contains('内容过大'),
        ),
      ),
    );
  });

  test('条目数超 4096 → EOCD 预检直接拒绝', () async {
    final entries = <ArchiveFile>[
      _textEntry('manifest.json', _manifest(colors: {PrefKeys.cPrimary: 1})),
      for (var i = 0; i < ThemePackageService.maxEntries; i++)
        ArchiveFile.bytes('empty/$i.txt', const <int>[]),
    ];
    final zip = await writeZip('too_many.zip', _zip(entries));

    await expectLater(
      ThemePackageService.importThemePackage(zip),
      throwsA(
        isA<ThemePackageException>().having(
          (e) => e.message,
          'message',
          contains('条目过多'),
        ),
      ),
    );
  });

  test('符号链接条目 → 明确拒绝（不解压链接目标）', () async {
    final link = ArchiveFile.bytes(
      'assets/background/light.png',
      utf8.encode('/etc/passwd'),
    )..mode = 0xa1ff; // 0xA000 | 0777：unix 符号链接
    final zip = await writeZip(
      'symlink.zip',
      _zip([
        _textEntry('manifest.json', _manifest(colors: {PrefKeys.cPrimary: 1})),
        link,
      ]),
    );

    await expectLater(
      ThemePackageService.importThemePackage(zip),
      throwsA(
        isA<ThemePackageException>().having(
          (e) => e.message,
          'message',
          contains('符号链接'),
        ),
      ),
    );
  });

  test('NUL 与绝对路径条目名 → 非法路径', () async {
    for (final badName in <String>['bad\u0000name.png', '/absolute.png']) {
      final zip = await writeZip(
        'bad_name_${badName.hashCode}.zip',
        _zip([
          _textEntry(
            'manifest.json',
            _manifest(colors: {PrefKeys.cPrimary: 1}),
          ),
          _textEntry(badName, 'x'),
        ]),
      );
      await expectLater(
        ThemePackageService.importThemePackage(zip),
        throwsA(
          isA<ThemePackageException>().having(
            (e) => e.message,
            'message',
            contains('非法路径'),
          ),
        ),
      );
    }
  });

  test('未知资源（字体/封面等）忽略，不影响导入', () async {
    final zip = await writeZip(
      'unknown_assets.zip',
      _zip([
        _textEntry(
          'manifest.json',
          _manifest(
            name: '含未知资源',
            paletteId: 3,
            colors: {'primary': 0xFF010101},
          ),
        ),
        _textEntry('assets/fonts/custom.ttf', 'font'),
        _textEntry('assets/cover/album.png', 'cover'),
        _textEntry('notes/readme.txt', 'ignored'),
      ]),
    );

    final data = await ThemePackageService.importThemePackage(zip);
    expect(data.name, '含未知资源');
    expect(data.paletteId, 3);
    expect(data.appVersion, '2.0.482');
    expect(data.colors[PrefKeys.cPrimary], 0xFF010101);
    expect(data.backgroundLight, isNull);
    expect(data.backgroundDark, isNull);
  });

  test('重名递增：X → X 2 → X 3；空名回落 theme', () {
    expect(ThemePackageService.uniqueThemeName('森林', []), '森林');
    expect(ThemePackageService.uniqueThemeName('森林', ['森林']), '森林 2');
    expect(ThemePackageService.uniqueThemeName('森林', ['森林', '森林 2']), '森林 3');
    expect(ThemePackageService.uniqueThemeName('   ', []), 'theme');
    expect(ThemePackageService.uniqueThemeName('   ', ['theme']), 'theme 2');
  });

  test('导出文件名净化：删除 /\\:*?"<>| 与首尾空格，空名回落 theme', () {
    expect(
      ThemePackageService.exportFileName(name: ' 我的/主题:*?"<>| ', millis: 42),
      'legado_theme_我的主题_42.zip',
    );
    expect(
      ThemePackageService.exportFileName(name: '   ', millis: 7),
      'legado_theme_theme_7.zip',
    );
    expect(
      ThemePackageService.exportFileName(name: r'a\b', millis: 1),
      'legado_theme_ab_1.zip',
    );
  });

  test('导出空主题名 → 清单名称回落 theme', () async {
    final target = '${temp.path}${Platform.pathSeparator}empty_name.zip';
    await ThemePackageService.exportThemePackage(
      name: '   ',
      colors: colors,
      targetPath: target,
    );
    final data = await ThemePackageService.importThemePackage(File(target));
    expect(data.name, 'theme');
  });
}
