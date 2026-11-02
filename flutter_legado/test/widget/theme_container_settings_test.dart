// [设置批2b-1a | 2026-11-01] 外观页「容器设置」分组交互测试 — 全栈工程师
//
// 覆盖：三组新行渲染与默认值、容器不透明度/背景图虚化行内滑块落盘、
// 容器背景图（日/夜）行副标题（文件名/缺失回落）、清除图片按钮与键移除;
// [设备回修] 选图参数 allowCompression=false/withData=false（避免原生压缩
// 对非图片 NPE 崩溃）。
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';
import 'package:flutter_legado/src/widgets/setting_slider_row.dart';

/// 记录 pickFiles 参数的桩（返回 null = 用户取消，不进入存储链路）
class _RecordingFilePicker extends FilePicker {
  int pickCalls = 0;
  FileType? type;
  bool? allowCompression;
  bool? withData;
  String? dialogTitle;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    pickCalls++;
    this.dialogTitle = dialogTitle;
    this.type = type;
    this.allowCompression = allowCompression;
    this.withData = withData;
    return null;
  }
}

/// 注入 FilePicker 平台桩并登记恢复
void _useFakeFilePicker(FilePicker fake) {
  FilePicker? original;
  var initialized = false;
  try {
    original = FilePicker.platform;
    initialized = true;
  } catch (_) {
    // 宿主未初始化（测试 registrant 无本平台分支）
  }
  FilePicker.platform = fake;
  addTearDown(
    () => FilePicker.platform = initialized ? original! : FilePickerIO(),
  );
}

void main() {
  late ProviderContainer container;
  late Directory temp;
  late Future<Directory> Function() originalSupportDir;

  setUp(() async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    uiSettingsListenable.value = const UiSettingsState();
    // 容器背景图存储基目录固定到临时目录：widget fake-async 下避免
    // path_provider 通道调用，同时保证「缺失文件」路径可同步判定
    temp = await Directory.systemTemp.createTemp('legado_theme_cfg_');
    originalSupportDir = ThemeBackgroundImageStore.supportDir;
    ThemeBackgroundImageStore.supportDir = () async => temp;
    ThemeBackgroundImageStore.warmWith(temp);
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  tearDown(() async {
    uiSettingsListenable.value = const UiSettingsState();
    ThemeBackgroundImageStore.supportDir = originalSupportDir;
    ThemeBackgroundImageStore.resetWarmCache();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Widget wrap() {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ThemeConfigScreen()),
    );
  }

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.dragUntilVisible(
      target,
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
  }

  Finder sliderRow(String title) => find.ancestor(
        of: find.text(title),
        matching: find.byType(SettingSliderRow),
      );

  Finder sliderOf(String title) => find.descendant(
        of: sliderRow(title),
        matching: find.byType(Slider),
      );

  testWidgets('容器设置组渲染新行与默认值（总开关默认关、图片行隐藏）',
      (tester) async {
    await pumpPage(tester);
    await scrollTo(tester, find.text('容器设置'));

    expect(find.text('容器背景图'), findsOneWidget);
    expect(find.text('大容器背景图透明度'), findsOneWidget);
    expect(find.text('容器不透明度'), findsOneWidget);
    expect(find.text('背景图虚化（日间）'), findsOneWidget);
    expect(find.text('背景图虚化（夜间）'), findsOneWidget);
    // 参考版总开关默认 false → 图片行条件隐藏
    expect(find.text('容器背景图片（日间）'), findsNothing);
    expect(find.text('容器背景图片（夜间）'), findsNothing);

    final rows = tester
        .widgetList<SettingSliderRow>(find.byType(SettingSliderRow))
        .toList();
    final byTitle = {for (final r in rows) r.title: r};
    expect(byTitle['大容器背景图透明度']!.value, 100);
    expect(byTitle['容器不透明度']!.value, 100);
    expect(byTitle['背景图虚化（日间）']!.value, 0);
    expect(byTitle['背景图虚化（夜间）']!.value, 0);
  });

  testWidgets('总开关：开启显示图片行；关闭隐藏但保留已选路径', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.largeContainerBackgroundImageLight:
          'theme_backgrounds/large_light/keep.png',
    });
    await container.read(uiSettingsProvider.notifier).reload();
    await pumpPage(tester);
    await scrollTo(tester, find.text('容器背景图'));

    Finder switchOf(String title) => find.descendant(
          of: find.ancestor(
            of: find.text(title),
            matching: find.byType(SettingSwitchRow),
          ),
          matching: find.byType(Switch),
        );
    expect(tester.widget<Switch>(switchOf('容器背景图')).value, isFalse);
    expect(find.text('容器背景图片（日间）'), findsNothing);

    // 开启 → 图片行出现（路径虽缺失也显示文件名+回落提示）
    await tester.tap(find.text('容器背景图'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.enableContainerBackgroundImage), isTrue);
    expect(find.text('容器背景图片（日间）'), findsOneWidget);
    expect(find.text('容器背景图片（夜间）'), findsOneWidget);

    // 关闭 → 行隐藏，但 prefs 路径仍在（再次开启可恢复）
    await tester.tap(find.text('容器背景图'));
    await tester.pumpAndSettle();
    expect(prefs.getBool(PrefKeys.enableContainerBackgroundImage), isFalse);
    expect(find.text('容器背景图片（日间）'), findsNothing);
    expect(
      prefs.getString(PrefKeys.largeContainerBackgroundImageLight),
      'theme_backgrounds/large_light/keep.png',
    );
  });

  testWidgets('容器不透明度滑块：点按轨道 0% 落盘 containerOpacity=0', (tester) async {
    await pumpPage(tester);
    await scrollTo(tester, find.text('容器不透明度'));

    final slider = sliderOf('容器不透明度');
    final rect = tester.getRect(slider);
    // Slider 轨道两端各留 thumb 半径；点最左端取 0
    await tester.tapAt(Offset(rect.left + 2, rect.center.dy));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PrefKeys.containerOpacity), 0);
    expect(container.read(uiSettingsProvider).containerOpacity, 0);
    expect(uiSettingsListenable.value.containerOpacity, 0);
  });

  testWidgets('大容器背景图透明度滑块：点按轨道 0% 落盘 appColumnBackgroundOpacity=0',
      (tester) async {
    await pumpPage(tester);
    await scrollTo(tester, find.text('大容器背景图透明度'));

    final slider = sliderOf('大容器背景图透明度');
    final rect = tester.getRect(slider);
    await tester.tapAt(Offset(rect.left + 2, rect.center.dy));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PrefKeys.appColumnBackgroundOpacity), 0);
    expect(container.read(uiSettingsProvider).appColumnBackgroundOpacity, 0);
    expect(uiSettingsListenable.value.appColumnBackgroundOpacity, 0);
  });

  testWidgets('覆盖范围文案：不把独立阅读设置页列为不覆盖', (tester) async {
    await pumpPage(tester);
    await scrollTo(tester, find.text('覆盖卡片圆角'));
    expect(
      find.text('覆盖使用默认卡片样式的卡片；'
          '字典/首页/阅读器内面板等自定义形状卡片不覆盖'),
      findsOneWidget,
    );

    await scrollTo(tester, find.text('覆盖卡片边框'));
    expect(
      find.text('覆盖使用默认卡片样式的卡片边框（0 色跟随主题描边）；'
          '字典/首页/阅读器内面板等自定义形状卡片不覆盖'),
      findsOneWidget,
    );
    // 独立阅读设置页使用 IosGroup，实际会被覆盖；仅阅读器内面板不覆盖
    expect(find.textContaining('阅读设置'), findsNothing);
  });

  testWidgets('背景图虚化日/夜滑块独立落盘（>50% 与 <50%）', (tester) async {
    await pumpPage(tester);
    await scrollTo(tester, find.text('背景图虚化（日间）'));

    final dayRect = tester.getRect(sliderOf('背景图虚化（日间）'));
    await tester.tapAt(Offset(dayRect.left + dayRect.width * 0.8, dayRect.center.dy));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.text('背景图虚化（夜间）'));
    final nightRect = tester.getRect(sliderOf('背景图虚化（夜间）'));
    await tester.tapAt(
      Offset(nightRect.left + nightRect.width * 0.2, nightRect.center.dy),
    );
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final day = prefs.getInt(PrefKeys.bgImageBlurring);
    final night = prefs.getInt(PrefKeys.bgImageNBlurring);
    expect(day, isNotNull);
    expect(night, isNotNull);
    expect(day!, greaterThan(50));
    expect(night!, lessThan(50));
    expect(container.read(uiSettingsProvider).bgImageBlurring, day);
    expect(container.read(uiSettingsProvider).bgImageDarkBlurring, night);
  });

  testWidgets('容器背景图行显示文件名；点击行弹选择/清除', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.enableContainerBackgroundImage: true,
      PrefKeys.largeContainerBackgroundImageLight:
          'theme_backgrounds/large_light/day.png',
      PrefKeys.largeContainerBackgroundImageDark:
          'theme_backgrounds/large_dark/night.png',
    });
    await container.read(uiSettingsProvider.notifier).reload();
    await pumpPage(tester);
    await scrollTo(tester, find.text('容器背景图片（日间）'));

    expect(find.text('day.png（文件缺失，已回落）'), findsOneWidget);
    expect(find.text('night.png（文件缺失，已回落）'), findsOneWidget);

    await tester.tap(find.text('容器背景图片（日间）'));
    await tester.pumpAndSettle();
    expect(find.text('选择图片'), findsOneWidget);
    expect(find.text('清除图片'), findsOneWidget);

    await tester.tap(find.text('清除图片'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.containsKey(PrefKeys.largeContainerBackgroundImageLight),
      isFalse,
    );
    expect(find.text('未设置'), findsWidgets);
    expect(
      container.read(uiSettingsProvider).largeContainerBackgroundImageLight,
      isEmpty,
    );
  });

  testWidgets('相对标识按 / 切分显示文件名（Windows/未预热场景）', (tester) async {
    ThemeBackgroundImageStore.resetWarmCache();
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.enableContainerBackgroundImage: true,
      PrefKeys.largeContainerBackgroundImageLight:
          'theme_backgrounds/large_light/sub/day.png',
    });
    await container.read(uiSettingsProvider.notifier).reload();
    await pumpPage(tester);
    await scrollTo(tester, find.text('容器背景图片（日间）'));

    expect(find.text('day.png（文件缺失，已回落）'), findsOneWidget);
  });

  testWidgets('选图参数：allowCompression=false、withData=false（防原生 NPE）',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.enableContainerBackgroundImage: true,
    });
    await container.read(uiSettingsProvider.notifier).reload();
    final picker = _RecordingFilePicker();
    _useFakeFilePicker(picker);
    await pumpPage(tester);
    await scrollTo(tester, find.text('容器背景图片（日间）'));

    await tester.tap(find.text('容器背景图片（日间）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await tester.pumpAndSettle();

    expect(picker.pickCalls, 1);
    expect(picker.type, FileType.image);
    expect(picker.allowCompression, isFalse,
        reason: '必须关闭 file_picker 原生压缩（非图片会 Bitmap.compress NPE）');
    expect(picker.withData, isFalse, reason: '不需要把整图读进内存');
    expect(picker.dialogTitle, '选择容器背景图片');
  });

  testWidgets('未设置时图片行弹窗不显示清除项', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.enableContainerBackgroundImage: true,
    });
    await container.read(uiSettingsProvider.notifier).reload();
    await pumpPage(tester);
    await scrollTo(tester, find.text('容器背景图片（夜间）'));

    await tester.tap(find.text('容器背景图片（夜间）'));
    await tester.pumpAndSettle();
    expect(find.text('选择图片'), findsOneWidget);
    expect(find.text('清除图片'), findsNothing);
  });
}
