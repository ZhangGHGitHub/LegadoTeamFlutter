// [应用字体入口 | 2026-11-11] AppFontNotifier + AppTheme 字体接线单测
// — 全栈工程师
//
// 覆盖：启动读取偏好并注册字体族、加载失败/超时回退默认字体且给出提示、
// 清除后立即回退、选择导入成功/校验失败/取消三态，以及 ThemeData 仅在
// family 非空时应用字体族（界面字体即时生效路径）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/theme/app_font_notifier.dart';
import 'package:flutter_legado/src/services/app_font_store.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';

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
  late Directory temp;
  late Future<Directory> Function() originalSupportDir;
  late Future<AppFontPick?> Function() originalPicker;
  late Future<void> Function(String, Future<ByteData>) originalLoader;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('legado_app_font_notifier_');
    originalSupportDir = AppFontStore.supportDir;
    originalPicker = AppFontStore.picker;
    originalLoader = AppFontStore.engineLoader;
    AppFontStore.supportDir = () async => temp;
    AppFontStore.warmWith(temp);
    AppFontStore.engineLoader = (family, bytes) async {};
  });

  tearDown(() async {
    AppFontStore.supportDir = originalSupportDir;
    AppFontStore.resetWarmCache();
    AppFontStore.picker = originalPicker;
    AppFontStore.engineLoader = originalLoader;
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows 文件句柄释放存在短延迟：清理失败不掩盖断言结果
    }
  });

  ProviderContainer newContainer({
    Duration timeout = const Duration(seconds: 5),
  }) {
    final container = ProviderContainer(
      overrides: [
        appFontProvider.overrideWith(
          () => AppFontNotifier(loadTimeout: timeout),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// 写入一个合法字体文件并返回偏好相对标识
  Future<String> seedValidFont({String name = 'seed.ttf'}) async {
    return AppFontStore.importBytes(validSfnt(), originalName: name);
  }

  /// 订阅 provider 并等待首个「已完成加载」状态（stored 非空且 loading=false）
  ///
  /// 不用 `pumpEventQueue`：字体加载含真实文件 IO，机器繁忙时事件队列
  /// 轮询可能先于 IO 完成返回（全量测试并行时曾出现假失败/临时目录占用）。
  Future<AppFontState> waitForLoaded(ProviderContainer container) async {
    final completer = Completer<AppFontState>();
    final subscription = container.listen<AppFontState>(appFontProvider, (
      previous,
      next,
    ) {
      if (!next.loading && next.stored != null && !completer.isCompleted) {
        completer.complete(next);
      }
    }, fireImmediately: true);
    try {
      return await completer.future.timeout(const Duration(seconds: 5));
    } finally {
      subscription.close();
    }
  }

  test('启动读取偏好并成功注册字体族', () async {
    final id = await seedValidFont();
    final container = newContainer();
    final state = await waitForLoaded(container);

    expect(state.isSet, isTrue);
    expect(state.stored, id);
    expect(state.displayName, 'seed.ttf');
    expect(state.isActive, isTrue);
    expect(state.family, AppFontStore.familyForBytes(validSfnt()));
    expect(state.errorMessage, isNull);
    expect(state.loading, isFalse);
  });

  test('字体文件损坏：不崩溃、回退默认字体（family=null）并给出提示', () async {
    final dir = Directory('${temp.path}${Platform.pathSeparator}app_font');
    await dir.create(recursive: true);
    File(
      '${dir.path}${Platform.pathSeparator}bad.ttf',
    ).writeAsBytesSync(Uint8List.fromList(List<int>.filled(12, 0)));
    const id = 'app_font/bad.ttf';
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefKeys.appFontPath: id,
    });

    final container = newContainer();
    final state = await waitForLoaded(container);

    expect(state.isSet, isTrue);
    expect(state.family, isNull);
    expect(state.isActive, isFalse);
    expect(state.errorMessage, isNotNull);
    expect(state.errorMessage, contains('默认字体'));

    // 主题侧 family 为 null → 不应用自定义字体族
    final theme = AppTheme.palette(
      brightness: Brightness.light,
      palette: Md3Palettes.def,
      fontFamily: state.family,
    );
    expect(theme.textTheme.bodyMedium?.fontFamily, isNot('AppCustomFont_bad'));
  });

  test('加载超时：回退默认字体并提示超时', () async {
    final id = await seedValidFont();
    AppFontStore.engineLoader = (family, bytes) => Completer<void>().future;
    final container = newContainer(timeout: const Duration(milliseconds: 10));
    final state = await waitForLoaded(container);

    expect(state.stored, id);
    expect(state.family, isNull);
    expect(state.errorMessage, contains('超时'));
  });

  test('清除后立即回退默认字体（文件删除 + 偏好清除 + family=null）', () async {
    final id = await seedValidFont();
    final container = newContainer();
    expect((await waitForLoaded(container)).isActive, isTrue);

    final file = File(
      '${temp.path}${Platform.pathSeparator}${id.replaceAll('/', Platform.pathSeparator)}',
    );
    expect(file.existsSync(), isTrue);

    await container.read(appFontProvider.notifier).clear();

    final state = container.read(appFontProvider);
    expect(state.isSet, isFalse);
    expect(state.family, isNull);
    expect(file.existsSync(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.appFontPath), isNull);
  });

  test('选择导入成功：落盘 + 偏好 + 立即激活新字体族', () async {
    AppFontStore.picker = () async =>
        AppFontPick(bytes: validSfnt(), name: 'picked.otf');
    final container = newContainer();
    // 先触发启动初始化，避免它与导入竞争（代数保护会丢弃旧结果）
    container.read(appFontProvider);
    await Future<void>.delayed(Duration.zero);

    final outcome = await container
        .read(appFontProvider.notifier)
        .pickAndImport();

    expect(outcome.canceled, isFalse);
    expect(outcome.error, isNull);
    final state = container.read(appFontProvider);
    expect(state.stored, 'app_font/picked.otf');
    expect(state.isActive, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.appFontPath), state.stored);
  });

  test('选择导入校验失败：旧字体保持不变并返回中文提示', () async {
    final id = await seedValidFont(name: 'old.ttf');
    final container = newContainer();
    final before = await waitForLoaded(container);

    AppFontStore.picker = () async =>
        AppFontPick(bytes: validSfnt(), name: 'bad.woff');
    final outcome = await container
        .read(appFontProvider.notifier)
        .pickAndImport();

    expect(outcome.canceled, isFalse);
    expect(outcome.error, contains('不支持的字体格式'));
    final after = container.read(appFontProvider);
    expect(after.stored, id);
    expect(after.stored, before.stored);
    expect(after.isActive, isTrue);
  });

  test('取消选择：不改变状态', () async {
    final id = await seedValidFont();
    final container = newContainer();
    await waitForLoaded(container);

    AppFontStore.picker = () async => null;
    final outcome = await container
        .read(appFontProvider.notifier)
        .pickAndImport();

    expect(outcome.canceled, isTrue);
    expect(container.read(appFontProvider).stored, id);
  });

  test('AppTheme 仅在 fontFamily 非空时应用界面字体（AppBar/正文同族）', () {
    final defaultTheme = AppTheme.palette(
      brightness: Brightness.light,
      palette: Md3Palettes.def,
    );
    expect(
      defaultTheme.textTheme.bodyMedium?.fontFamily,
      isNot('AppCustomFont_x'),
    );

    final customTheme = AppTheme.palette(
      brightness: Brightness.light,
      palette: Md3Palettes.def,
      fontFamily: 'AppCustomFont_x',
    );
    expect(customTheme.textTheme.bodyMedium?.fontFamily, 'AppCustomFont_x');
    expect(customTheme.textTheme.titleMedium?.fontFamily, 'AppCustomFont_x');
    expect(
      customTheme.appBarTheme.titleTextStyle?.fontFamily,
      'AppCustomFont_x',
    );
    expect(
      customTheme.navigationBarTheme.labelTextStyle
          ?.resolve(<WidgetState>{})
          ?.fontFamily,
      'AppCustomFont_x',
    );
  });
}
