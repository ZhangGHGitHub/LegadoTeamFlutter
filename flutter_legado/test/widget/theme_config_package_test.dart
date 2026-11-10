// [批14 | 2026-11-10] 主题管理页：单条主题包导出 / 导入 widget 测试 — 全栈工程师
//
// 覆盖：列表行导出图标与导出 zip 文件名/清单、导入按钮、非法 zip 中文提示、
// 导入后重名递增且不自动应用当前主题、360dp + 1.3 倍字体不溢出。
//
// 说明：widget 测试运行在 FakeAsync 下，真实文件 IO 必须经
// `tester.runAsync` 驱动；App 版本读取器替换为固定值，避免平台插件。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
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
}) {
  final manifest = <String, dynamic>{
    'formatVersion': 1,
    'name': name,
    'appVersion': '2.0.482',
    'config': <String, dynamic>{
      'isNight': isNight,
      'paletteId': paletteId,
      'colors': colors,
    },
    'assets': <String, dynamic>{'background': <String, dynamic>{}},
  };
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

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
  Future<File> writeZip(
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

  testWidgets('主题管理页存在导入主题包按钮；非法 zip 给出中文提示且不写入', (tester) async {
    final badZip = await writeZip(
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
    final zip = await writeZip(tester, 'theme.zip', _themePackageZip());
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

    // 不自动应用：颜色与调色板保持导入前状态
    expect(container.read(themeColorsProvider).primary, isNull);
    expect(container.read(themeNotifierProvider).paletteId, 'def');
    expect(prefs.getInt(PrefKeys.cPrimary), isNull);
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
}
