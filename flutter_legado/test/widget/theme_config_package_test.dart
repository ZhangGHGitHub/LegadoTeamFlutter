// [批14 | 2026-11-10] 主题管理页：单条主题包导出 / 导入 widget 测试 — 全栈工程师
//
// 覆盖：列表行导出图标与导出 zip 文件名/清单、旧主题不打包当前全局壁纸、
// 导入按钮、非法 zip 中文提示、重名递增且不自动应用、带背景导入+应用、
// paletteId/完整 12 槽应用、列表解析失败时跳过孤儿清理、
// 320dp/360dp + 1.3 倍字体不截断与 40dp 可点区。
//
// 说明：widget 测试运行在 FakeAsync 下，真实文件 IO 必须经
// `tester.runAsync` 驱动；App 版本读取器替换为固定值，避免平台插件。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// path_provider 平台接口为传递依赖，测试直引以覆写 instance 保持 hermetic
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/theme/theme_colors_notifier.dart';
import 'package:flutter_legado/src/providers/theme/theme_notifier.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';
import 'package:flutter_legado/src/services/export_file_service.dart';
import 'package:flutter_legado/src/services/file_save_channel.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';
import 'package:flutter_legado/src/services/theme_package_service.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';

/// 1x1 透明 PNG（真实可解码，供导入背景图落盘校验）
final Uint8List _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
  '/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;
}

class _FakeExportFileService extends ExportFileService {
  Uint8List? savedBytes;
  String? savedFileName;

  @override
  Future<SaveFileResult?> saveExistingFile({
    required String sourcePath,
    required String fileName,
    bool useTree = true,
    bool chooseTree = false,
  }) async {
    savedBytes = await File(sourcePath).readAsBytes();
    savedFileName = fileName;
    return SaveFileResult(location: sourcePath, fileName: fileName);
  }
}

Uint8List _themePackageZip({
  String name = '森林',
  bool isNight = false,
  int? paletteId = 3,
  Map<String, int> colors = const {'primary': 0xFF336699},
  Uint8List? lightBackground,
  Uint8List? darkBackground,
}) {
  final background = <String, dynamic>{
    if (lightBackground != null) 'light': 'assets/background/light.png',
    if (darkBackground != null) 'dark': 'assets/background/dark.png',
  };
  final manifest = <String, dynamic>{
    'formatVersion': 1,
    'name': name,
    'appVersion': '2.0.482',
    'config': <String, dynamic>{
      'isNight': isNight,
      'paletteId': paletteId,
      'colors': colors,
    },
    'assets': <String, dynamic>{'background': background},
  };
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))),
    );
  if (lightBackground != null) {
    archive.addFile(
      ArchiveFile.bytes('assets/background/light.png', lightBackground),
    );
  }
  if (darkBackground != null) {
    archive.addFile(
      ArchiveFile.bytes('assets/background/dark.png', darkBackground),
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const Map<String, int> _allManifestColors = <String, int>{
  'primary': 0xFF010101,
  'accent': 0xFF020202,
  'background': 0xFF030303,
  'bottomBackground': 0xFF040404,
  'primaryText': 0xFF050505,
  'secondaryText': 0xFF060606,
  'primaryNight': 0xFF070707,
  'accentNight': 0xFF080808,
  'backgroundNight': 0xFF090909,
  'bottomBackgroundNight': 0xFF0A0A0A,
  'primaryTextNight': 0xFF0B0B0B,
  'secondaryTextNight': 0xFF0C0C0C,
};

void main() {
  late ProviderContainer container;
  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;
  late Future<String> Function() originalAppVersionLoader;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    addTearDown(container.dispose);
    tempDir = await Directory.systemTemp.createTemp('theme_package_ui_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    originalAppVersionLoader = ThemePackageService.appVersionLoader;
    ThemePackageService.appVersionLoader = () async => '2.0.482';
    ThemeBackgroundImageStore.resetWarmCache();
    addTearDown(() async {
      ThemePackageService.appVersionLoader = originalAppVersionLoader;
      PathProviderPlatform.instance = originalPathProvider;
      ThemeBackgroundImageStore.resetWarmCache();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
  });

  Widget wrap({
    ExportFileService? exportFileService,
    Future<String?> Function()? picker,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ThemeConfigScreen(
          exportFileService: exportFileService ?? const ExportFileService(),
          themePackageFilePicker: picker,
        ),
      ),
    );
  }

  Future<void> openThemeManage(WidgetTester tester) async {
    await tester.dragUntilVisible(
      find.text('主题管理'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题管理'));
    await tester.pumpAndSettle();
  }

  /// FakeAsync 下用真实事件循环落盘
  Future<File> writeFile(
    WidgetTester tester,
    String name,
    List<int> bytes,
  ) async {
    late File file;
    await tester.runAsync(() async {
      file = File('${tempDir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes, flush: true);
    });
    return file;
  }

  /// FakeAsync 下让 App 内的真实文件 IO/异步落库跑完
  ///
  /// 触发动作本身也必须在 `runAsync` 内执行：onPressed 里创建的 IO Future
  /// 会继承当前 Zone，若在 FakeAsync 中创建，其完成回调不会被真实事件循环
  /// 驱动（表现为一直停在 `readAsBytes`）。
  Future<void> runAppIo(
    WidgetTester tester,
    Future<void> Function() action,
  ) async {
    await tester.runAsync(() async {
      await action();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
  }

  /// 连续 toast（导入 + 应用）会让 SnackBar 隐藏动画跨到测试结束，
  /// 先排空动画/定时器，避免 ScaffoldMessenger 已销毁后回调断言。
  Future<void> drainSnackBars(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('主题管理列表出现导出图标，点击导出主题包 zip（文件名/清单）', (tester) async {
    SharedPreferences.setMockInitialValues({
      'themeConfigList': jsonEncode([
        {
          'name': '日间主题',
          'isNight': false,
          'primary': 0xFF010203,
          'accent': 0xFF040506,
          'background': 0xFF070809,
          'bottomBackground': 0,
          'primaryText': 0,
          'secondaryText': 0,
        },
      ]),
    });
    final fake = _FakeExportFileService();
    await tester.pumpWidget(wrap(exportFileService: fake));
    await tester.pumpAndSettle();
    await openThemeManage(tester);

    final exportButton = find.byKey(const ValueKey('theme-config-export-0'));
    expect(exportButton, findsOneWidget);

    await runAppIo(tester, () => tester.tap(exportButton));

    expect(
      fake.savedFileName,
      matches(RegExp(r'^legado_theme_日间主题_\d+\.zip$')),
    );
    final bytes = fake.savedBytes;
    expect(bytes, isNotNull);
    final archive = ZipDecoder().decodeBytes(bytes!);
    final manifestEntry = archive.findFile('manifest.json');
    expect(manifestEntry, isNotNull);
    final manifest =
        jsonDecode(utf8.decode(manifestEntry!.content)) as Map<String, dynamic>;
    expect(manifest['formatVersion'], 1);
    expect(manifest['name'], '日间主题');
    expect(manifest['appVersion'], '2.0.482');
    final config = manifest['config'] as Map<String, dynamic>;
    expect(config['isNight'], isFalse);
    final colors = config['colors'] as Map<String, dynamic>;
    expect(colors['primary'], 0xFF010203);
    expect(colors['accent'], 0xFF040506);
    expect(colors['background'], 0xFF070809);
    expect(colors['bottomBackground'], 0);
    expect(find.textContaining('已保存'), findsOneWidget);
  });

  testWidgets('旧主题无显式背景字段：导出不打包当前全局壁纸', (tester) async {
    final dayWallpaper = await writeFile(
      tester,
      'day_wallpaper.png',
      _pngBytes,
    );
    final nightWallpaper = await writeFile(
      tester,
      'night_wallpaper.png',
      _pngBytes,
    );
    SharedPreferences.setMockInitialValues({
      PrefKeys.bgImage: dayWallpaper.path,
      PrefKeys.bgImageN: nightWallpaper.path,
      'themeConfigList': jsonEncode([
        {'name': '旧主题', 'isNight': false, 'primary': 0xFF010101},
      ]),
    });
    final fake = _FakeExportFileService();
    await tester.pumpWidget(wrap(exportFileService: fake));
    await tester.pumpAndSettle();
    await openThemeManage(tester);

    await runAppIo(
      tester,
      () => tester.tap(find.byKey(const ValueKey('theme-config-export-0'))),
    );

    final archive = ZipDecoder().decodeBytes(fake.savedBytes!);
    expect(
      archive.map((entry) => entry.name),
      equals(<String>['manifest.json']),
      reason: '旧主题无背景字段时不得把用户当前壁纸打进包',
    );
  });

  testWidgets('主题管理页存在导入主题包按钮；非法 zip 给出中文提示且不写入', (tester) async {
    final badZip = await writeFile(
      tester,
      'bad.zip',
      utf8.encode('this is not a zip'),
    );
    await tester.pumpWidget(wrap(picker: () async => badZip.path));
    await tester.pumpAndSettle();
    await openThemeManage(tester);

    final importButton = find.byKey(const ValueKey('theme-package-import'));
    expect(importButton, findsOneWidget);
    expect(find.text('导入主题包'), findsOneWidget);

    await runAppIo(tester, () => tester.tap(importButton));

    expect(find.textContaining('导入失败：无法读取主题包'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('themeConfigList'), isNull);
    expect(find.byKey(const ValueKey('theme-config-item-0')), findsNothing);
  });

  testWidgets('导入主题包：重名加「 2」、写入列表但不自动应用', (tester) async {
    SharedPreferences.setMockInitialValues({
      'themeConfigList': jsonEncode([
        {
          'name': '森林',
          'isNight': false,
          'primary': 0xFF000001,
          'accent': 0,
          'background': 0,
          'bottomBackground': 0,
        },
      ]),
    });
    final zip = await writeFile(tester, 'theme.zip', _themePackageZip());
    await tester.pumpWidget(wrap(picker: () async => zip.path));
    await tester.pumpAndSettle();
    await openThemeManage(tester);

    // 导入前当前主题未被修改
    expect(container.read(themeColorsProvider).primary, isNull);
    expect(container.read(themeNotifierProvider).paletteId, 'def');

    await runAppIo(
      tester,
      () => tester.tap(find.byKey(const ValueKey('theme-package-import'))),
    );

    expect(find.text('已导入主题包 森林 2'), findsOneWidget);
    expect(find.text('森林 2'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    final stored = (jsonDecode(prefs.getString('themeConfigList')!) as List)
        .cast<Map<String, dynamic>>();
    expect(stored.length, 2);
    expect(stored[1]['name'], '森林 2');
    expect(stored[1]['isNight'], isFalse);
    expect(stored[1]['primary'], 0xFF336699);
    expect(stored[1]['paletteId'], 3);
    expect(
      (stored[1]['colors'] as Map<String, dynamic>)[PrefKeys.cPrimary],
      0xFF336699,
    );
    // 导入时两侧都写：无背景的一侧明确为空串
    expect(stored[1]['bgImage'], '');
    expect(stored[1]['bgImageNight'], '');

    // 不自动应用：颜色与调色板保持导入前状态
    expect(container.read(themeColorsProvider).primary, isNull);
    expect(container.read(themeNotifierProvider).paletteId, 'def');
    expect(prefs.getInt(PrefKeys.cPrimary), isNull);
  });

  testWidgets('导入仅白天背景 → 再导出不带夜间壁纸，应用后夜间被清空', (tester) async {
    final nightWallpaper = await writeFile(
      tester,
      'current_night.png',
      _pngBytes,
    );
    SharedPreferences.setMockInitialValues({
      PrefKeys.bgImageN: nightWallpaper.path,
    });
    final zip = await writeFile(
      tester,
      'light_bg.zip',
      _themePackageZip(name: '带白天背景', lightBackground: _pngBytes),
    );
    final fake = _FakeExportFileService();
    await tester.pumpWidget(
      wrap(exportFileService: fake, picker: () async => zip.path),
    );
    await tester.pumpAndSettle();
    await openThemeManage(tester);

    await runAppIo(
      tester,
      () => tester.tap(find.byKey(const ValueKey('theme-package-import'))),
    );
    final prefs = await SharedPreferences.getInstance();
    final stored = (jsonDecode(prefs.getString('themeConfigList')!) as List)
        .cast<Map<String, dynamic>>();
    expect(stored[0]['bgImage'], isNotEmpty);
    expect(stored[0]['bgImageNight'], '');

    // 再导出同一条目：只应带白天背景，不能回落当前全局夜间壁纸
    await runAppIo(
      tester,
      () => tester.tap(find.byKey(const ValueKey('theme-config-export-0'))),
    );
    final archive = ZipDecoder().decodeBytes(fake.savedBytes!);
    final names = archive.map((entry) => entry.name).toSet();
    expect(names, contains('assets/background/light.png'));
    expect(
      names,
      isNot(contains('assets/background/dark.png')),
      reason: '条目的夜间背景为空串，不得回落到当前全局壁纸',
    );

    // 先让导入/导出 toast 完整消失，避免应用时 hide 动画与下一次 show 交错
    await drainSnackBars(tester);
    await runAppIo(
      tester,
      () => tester.tap(find.byKey(const ValueKey('theme-config-item-0'))),
    );

    final dayPath = prefs.getString(PrefKeys.bgImage);
    expect(dayPath, isNotNull);
    expect(dayPath, startsWith(tempDir.path));
    expect(File(dayPath!).existsSync(), isTrue);
    expect(
      prefs.getString(PrefKeys.bgImageN),
      isNull,
      reason: '主题包未含夜间背景时应用主题必须清除旧壁纸',
    );
    await drainSnackBars(tester);
  });

  testWidgets('应用无背景主题包：清除日/夜旧壁纸', (tester) async {
    final dayWallpaper = await writeFile(tester, 'old_day.png', _pngBytes);
    final nightWallpaper = await writeFile(tester, 'old_night.png', _pngBytes);
    SharedPreferences.setMockInitialValues({
      PrefKeys.bgImage: dayWallpaper.path,
      PrefKeys.bgImageN: nightWallpaper.path,
    });
    final zip = await writeFile(
      tester,
      'no_bg.zip',
      _themePackageZip(name: '无背景主题'),
    );
    await tester.pumpWidget(wrap(picker: () async => zip.path));
    await tester.pumpAndSettle();
    await openThemeManage(tester);

    await runAppIo(
      tester,
      () => tester.tap(find.byKey(const ValueKey('theme-package-import'))),
    );
    await drainSnackBars(tester);
    await runAppIo(
      tester,
      () => tester.tap(find.byKey(const ValueKey('theme-config-item-0'))),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.bgImage), isNull);
    expect(prefs.getString(PrefKeys.bgImageN), isNull);
    expect(container.read(themeColorsProvider).bgImage, '');
    expect(container.read(themeColorsProvider).bgImageNight, '');
    await drainSnackBars(tester);
  });

  testWidgets('应用主题包：paletteId 生效且完整 12 槽全部写入', (tester) async {
    final zip = await writeFile(
      tester,
      'full_colors.zip',
      _themePackageZip(name: '全色主题', paletteId: 2, colors: _allManifestColors),
    );
    await tester.pumpWidget(wrap(picker: () async => zip.path));
    await tester.pumpAndSettle();
    await openThemeManage(tester);

    await runAppIo(
      tester,
      () => tester.tap(find.byKey(const ValueKey('theme-package-import'))),
    );
    await drainSnackBars(tester);
    await runAppIo(
      tester,
      () => tester.tap(find.byKey(const ValueKey('theme-config-item-0'))),
    );

    expect(
      container.read(themeNotifierProvider).paletteId,
      Md3Palettes.all[2].id,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PrefKeys.cPrimary), 0xFF010101);
    expect(prefs.getInt(PrefKeys.cAccent), 0xFF020202);
    expect(prefs.getInt(PrefKeys.cBackground), 0xFF030303);
    expect(prefs.getInt(PrefKeys.cBBackground), 0xFF040404);
    expect(prefs.getInt(PrefKeys.cPrimaryText), 0xFF050505);
    expect(prefs.getInt(PrefKeys.cSecondaryText), 0xFF060606);
    expect(prefs.getInt(PrefKeys.cNPrimary), 0xFF070707);
    expect(prefs.getInt(PrefKeys.cNAccent), 0xFF080808);
    expect(prefs.getInt(PrefKeys.cNBackground), 0xFF090909);
    expect(prefs.getInt(PrefKeys.cNBBackground), 0xFF0A0A0A);
    expect(prefs.getInt(PrefKeys.cNPrimaryText), 0xFF0B0B0B);
    expect(prefs.getInt(PrefKeys.cNSecondaryText), 0xFF0C0C0C);

    final state = container.read(themeColorsProvider);
    expect(state.primaryNight, 0xFF070707);
    expect(state.secondaryTextColorNight, 0xFF0C0C0C);
    await drainSnackBars(tester);
  });

  testWidgets('paletteId 无效时应用主题保持当前调色板', (tester) async {
    final zip = await writeFile(
      tester,
      'bad_palette.zip',
      _themePackageZip(paletteId: 999),
    );
    await tester.pumpWidget(wrap(picker: () async => zip.path));
    await tester.pumpAndSettle();
    await openThemeManage(tester);

    await runAppIo(
      tester,
      () => tester.tap(find.byKey(const ValueKey('theme-package-import'))),
    );
    await drainSnackBars(tester);
    await runAppIo(
      tester,
      () => tester.tap(find.byKey(const ValueKey('theme-config-item-0'))),
    );

    expect(container.read(themeNotifierProvider).paletteId, 'def');
    await drainSnackBars(tester);
  });

  testWidgets('主题列表解析失败：跳过孤儿清理，不删除主题包背景图', (tester) async {
    // 预热基目录，确保本用例真的走到 cleanupOrphansSync
    ThemeBackgroundImageStore.warmWith(tempDir);
    late File themeBackground;
    await tester.runAsync(() async {
      final dir = Directory(
        '${tempDir.path}${Platform.pathSeparator}'
        '${ThemeBackgroundImageStore.subDir}${Platform.pathSeparator}'
        '${ThemeBackgroundImageStore.themeLightSlot}',
      )..createSync(recursive: true);
      themeBackground = File(
        '${dir.path}${Platform.pathSeparator}'
        '${List<String>.filled(32, 'a').join()}.png',
      )..writeAsBytesSync(_pngBytes);
    });
    SharedPreferences.setMockInitialValues({
      'themeConfigList': 'not a valid json list',
      // 非空容器图引用让 cleanup 的 keep 条件成立
      PrefKeys.largeContainerBackgroundImageLight:
          'theme_backgrounds/large_light/missing.png',
    });

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(themeBackground.existsSync(), isTrue, reason: '列表解析失败时不得按空列表执行孤儿清理');
  });

  testWidgets('360dp + 1.3 倍字体：主题管理行按钮与标题不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({
      'themeConfigList': jsonEncode([
        {
          'name': '测试夜间主题名称',
          'isNight': true,
          'primary': 1,
          'accent': 2,
          'background': 3,
          'bottomBackground': 4,
        },
      ]),
    });

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await openThemeManage(tester);

    expect(find.byKey(const ValueKey('theme-config-export-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-config-rename-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-config-delete-0')), findsOneWidget);
    expect(find.text('导入主题包'), findsOneWidget);
    expect(find.text('测试夜间主题名称'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '360dp + 1.3 字不得溢出');
  });

  testWidgets('320dp + 1.3 倍字体：标题不截断且按钮可点区 ≥ 40dp', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({
      'themeConfigList': jsonEncode([
        {
          'name': '测试夜间主题名称',
          'isNight': true,
          'primary': 1,
          'accent': 2,
          'background': 3,
          'bottomBackground': 4,
        },
      ]),
    });

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await openThemeManage(tester);

    final title = find.descendant(
      of: find.byKey(const ValueKey('theme-config-item-0')),
      matching: find.text('测试夜间主题名称'),
    );
    expect(title, findsOneWidget);
    expect(
      tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
      isFalse,
      reason: '320dp + 1.3 字允许两行但不能省略截断',
    );
    for (final key in <String>[
      'theme-config-export-0',
      'theme-config-rename-0',
      'theme-config-delete-0',
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.width, greaterThanOrEqualTo(40), reason: '$key 可点区宽度');
      expect(size.height, greaterThanOrEqualTo(40), reason: '$key 可点区高度');
    }
    expect(tester.takeException(), isNull);
  });
}
