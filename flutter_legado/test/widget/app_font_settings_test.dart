// [应用字体入口 | 2026-11-11] 外观页「字体设置」Widget 测试 — 全栈工程师
//
// 覆盖：字体设置行出现且位于参考顺序（主题管理之后、导出主题之前）；
// 未设置/已设置两种副标题；点击弹窗含「选择字体文件」、已设置时含
// 「清除字体」；清除后行回「未设置」且文件/偏好清理；损坏字体加载失败
// 不崩溃、界面回退默认字体（family=null）并在行副标题提示；
// 360dp + 1.3 倍字体下长文件名不产生布局溢出。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/theme/app_font_notifier.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';
import 'package:flutter_legado/src/services/app_font_store.dart';
import 'package:flutter_legado/src/services/theme_background_image_store.dart';

/// 结构合法的最小 sfnt（1 个 head 表）
Uint8List validSfnt() {
  final bytes = Uint8List(32);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0x00010000);
  data.setUint16(4, 1);
  data.setUint32(12, 0x68656164);
  data.setUint32(20, 28);
  data.setUint32(24, 4);
  return bytes;
}

void main() {
  late ProviderContainer container;
  late Directory temp;
  late Future<Directory> Function() originalSupportDir;
  late Future<AppFontPick?> Function() originalPicker;
  late Future<void> Function(String, Future<ByteData>) originalLoader;
  late Future<Directory> Function() originalThemeSupportDir;
  late Future<Uint8List> Function(File file) originalReadBytes;

  setUp(() async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    uiSettingsListenable.value = const UiSettingsState();
    temp = await Directory.systemTemp.createTemp('legado_app_font_widget_');
    originalSupportDir = AppFontStore.supportDir;
    originalPicker = AppFontStore.picker;
    originalLoader = AppFontStore.engineLoader;
    originalThemeSupportDir = ThemeBackgroundImageStore.supportDir;
    originalReadBytes = AppFontStore.readBytes;
    AppFontStore.supportDir = () async => temp;
    AppFontStore.warmWith(temp);
    AppFontStore.engineLoader = (family, bytes) async {};
    // widget 测试 FakeAsync 下真实异步 IO 不推进：同步读，避免加载挂起
    AppFontStore.readBytes = (file) async => file.readAsBytesSync();
    ThemeBackgroundImageStore.supportDir = () async => temp;
    ThemeBackgroundImageStore.warmWith(temp);
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  tearDown(() async {
    uiSettingsListenable.value = const UiSettingsState();
    AppFontStore.supportDir = originalSupportDir;
    AppFontStore.resetWarmCache();
    AppFontStore.picker = originalPicker;
    AppFontStore.engineLoader = originalLoader;
    AppFontStore.readBytes = originalReadBytes;
    ThemeBackgroundImageStore.supportDir = originalThemeSupportDir;
    ThemeBackgroundImageStore.resetWarmCache();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Widget wrap() {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ThemeConfigScreen()),
    );
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(800, 2600),
    double devicePixelRatio = 1.0,
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = devicePixelRatio;
    if (textScale != 1.0) {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap());
    // 页面加载是纯异步偏好读取：两次 pump 足够；不用 pumpAndSettle，
    // 避免加载态 spinner 在异常路径下造成无限帧等待。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// widget FakeAsync 下用同步文件 IO + 预置偏好（不调用异步导入链路）
  ///
  /// 使用与新导入链路一致的内容哈希前缀文件名，验证 UI 显示会剥离前缀。
  String seedFont({String name = '我的字体.ttf'}) {
    final dir = Directory('${temp.path}${Platform.pathSeparator}app_font')
      ..createSync(recursive: true);
    final storedName = '${'0' * 32}_$name';
    File(
      '${dir.path}${Platform.pathSeparator}$storedName',
    ).writeAsBytesSync(validSfnt());
    final id = 'app_font/$storedName';
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.appFontPath: id,
    });
    return id;
  }

  File fontFile(String id) => File(
    '${temp.path}${Platform.pathSeparator}'
    '${id.replaceAll('/', Platform.pathSeparator)}',
  );

  testWidgets('字体设置行位于主题管理之后、导出主题之前，默认显示未设置', (tester) async {
    await pumpPage(tester);

    expect(find.text('字体设置'), findsOneWidget);
    expect(find.text('未设置（跟随系统默认字体）'), findsOneWidget);

    final fontSettingY = tester.getTopLeft(find.text('字体设置')).dy;
    expect(fontSettingY, greaterThan(tester.getTopLeft(find.text('主题管理')).dy));
    expect(fontSettingY, lessThan(tester.getTopLeft(find.text('导出主题')).dy));
  });

  testWidgets('已设置状态显示字体文件名', (tester) async {
    final id = seedFont();
    await pumpPage(tester);

    expect(AppFontStore.displayNameOf(id), '我的字体.ttf');
    expect(find.text('已设置：我的字体.ttf'), findsOneWidget);
    expect(container.read(appFontProvider).isActive, isTrue);
  });

  testWidgets('点击弹出选择/清除选项；清除后回默认并删除文件', (tester) async {
    final id = seedFont();
    final file = fontFile(id);
    await pumpPage(tester);

    await tester.tap(find.text('字体设置'));
    await tester.pumpAndSettle();
    expect(find.text('选择字体文件'), findsOneWidget);
    expect(find.text('清除字体'), findsOneWidget);

    await tester.tap(find.text('清除字体'));
    await tester.pumpAndSettle();

    expect(find.text('未设置（跟随系统默认字体）'), findsOneWidget);
    expect(container.read(appFontProvider).isSet, isFalse);
    expect(container.read(appFontProvider).family, isNull);
    expect(file.existsSync(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.appFontPath), isNull);
  });

  testWidgets('未设置时弹窗不显示清除字体', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('字体设置'));
    await tester.pumpAndSettle();

    expect(find.text('选择字体文件'), findsOneWidget);
    expect(find.text('清除字体'), findsNothing);
  });

  testWidgets('损坏字体：加载失败不崩溃，界面回退默认字体并在行内提示', (tester) async {
    final dir = Directory('${temp.path}${Platform.pathSeparator}app_font');
    dir.createSync(recursive: true);
    File(
      '${dir.path}${Platform.pathSeparator}broken.ttf',
    ).writeAsBytesSync(Uint8List.fromList(List<int>.filled(12, 0)));
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.appFontPath: 'app_font/broken.ttf',
    });
    await pumpPage(tester);

    expect(tester.takeException(), isNull);
    final state = container.read(appFontProvider);
    expect(state.isSet, isTrue);
    expect(state.family, isNull);
    expect(state.errorMessage, isNotNull);
    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.textContaining('已回退默认字体'), findsOneWidget);
  });

  testWidgets('360dp + 1.3 倍字体：超长字体文件名不溢出', (tester) async {
    final longName = '${'超长字体文件名' * 8}.ttf';
    seedFont(name: longName);
    await pumpPage(
      tester,
      size: const Size(1080, 1920),
      devicePixelRatio: 3.0,
      textScale: 1.3,
    );

    await tester.dragUntilVisible(
      find.text('字体设置'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('字体设置'), findsOneWidget);

    // 具体几何断言（不仅靠 takeException）：行/副标题都不得超出 360dp
    final tileRect = tester.getRect(
      find.ancestor(of: find.text('字体设置'), matching: find.byType(ListTile)),
    );
    expect(tileRect.right, lessThanOrEqualTo(360.5));
    final subtitle = tester.renderObject<RenderParagraph>(
      find.textContaining('已设置：'),
    );
    expect(subtitle.size.width, lessThanOrEqualTo(tileRect.width));
    expect(subtitle.size.height, lessThan(200));
  });
}
