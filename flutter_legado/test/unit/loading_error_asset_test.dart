import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// [STAGE-UI-P43UNIFY1 B1] 图片加载失败占位素材存在性与 pubspec 声明断言
///
/// 取证（docs/LOADING_ASSETS_UNIFY_SURVEY_20260930.md §2.4/§3.3）：
/// - `image_loading_error.png` 为原版/参考版共有素材（原版
///   `app/src/main/res/drawable/image_loading_error.png` 6933B，md5
///   1238cf6b80dc1ff61fa823a232ffb71a；参考版同名同字节）；
/// - 参考版图片加载失败形态 = 直接显示该素材图（ImageProvider.kt:39
///   阅读错误 bitmap、PhotoDialog.kt:61 / VerificationCodeDialog.kt:91
///   Coil `.error()`），我方对应位置此前用 `Icons.broken_image` 图标
///   代替，B1 批拷入本素材并替换引用。
void main() {
  // flutter test 工作目录 = 包根（flutter_legado/）
  final root = Directory.current;

  test('assets/images/image_loading_error.png 存在且字节数与原版一致（6933B）',
      () {
    final file = File('${root.path}${Platform.pathSeparator}assets'
        '${Platform.pathSeparator}images'
        '${Platform.pathSeparator}image_loading_error.png');
    expect(file.existsSync(), isTrue, reason: '素材文件应已拷入 assets/images/');
    // 原版/参考版均 6933B（调研报告 §3.3 字节级对齐口径）
    expect(file.lengthSync(), 6933,
        reason: '素材须与原版 res/drawable/image_loading_error.png 字节一致');
  });

  test('pubspec flutter.assets 已声明 assets/images/ 目录（覆盖该素材）', () {
    final pubspec = File('${root.path}${Platform.pathSeparator}pubspec.yaml');
    expect(pubspec.existsSync(), isTrue);
    final text = pubspec.readAsStringSync();
    // assets 声明区（flutter: 段）存在 - assets/images/ 行（目录级声明，
    // 覆盖该目录下所有素材；调研报告 §3.1 实测声明位于 pubspec L73）
    final inFlutterAssets =
        text.contains('assets/images/') && text.contains('  assets:');
    expect(inFlutterAssets, isTrue,
        reason: 'pubspec 须以 flutter.assets 目录声明覆盖 assets/images/');
  });
}
