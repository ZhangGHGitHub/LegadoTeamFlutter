// [设置批2b-1a | 2026-11-01] 全局主题背景图层（含日/夜虚化）— 全栈工程师
//
// 语义基准（参考版 legado-with-MD3）：
// - 背景图虚化键 `backgroundImageBlurring` / `backgroundImageNightBlurring`
//   （PreferKey.kt:282-283），默认 0，范围 0..100（ThemeSettings.kt:54-55；
//   设置面板 Slider 0..100 见 BackgroundImageManageSheet.kt:121-147）。
// - 虚化作用于**全局背景图本身**：参考版 `AppBackground.kt:36-48` 用
//   `AsyncImage(...).blur(blur.dp)`，内容层不受影响；`AppScaffold.kt:243-266`
//   同口径。故本方把 ImageFiltered 只包背景 Image，不包 app 内容。
//
// 结构说明（修既有登记风险）：
// - 背景层始终返回同一形状 `Stack[Positioned.fill(bg), child]`：有无图只切换
//   第 0 个 slot 的内容，app 子树恒定位于第 1 个 slot。此前「无图→有图」
//   在 `child` 与 `DecoratedBox(child)` 之间切换 Element 类型，会重建其下
//   SystemBarBinder / WebViewBridgeListener / VerificationCodeListener 子树
//   （见原 app.dart 登记注释）；本批一并消除。
// - 图片层套 IgnorePointer：不拦截点击/手势；blur>0 时套 RepaintBoundary，
//   让模糊结果可被引擎缓存为绘制层（低端机减少逐帧模糊开销）。
// - 解码用 ResizeImage 限到窗口×DPR（P2.2），避免 12MP 全量解码。
// - 护眼模式在本层之外（app.dart 中 EyeProtectionLayer 包在最外层），
//   因此壁纸与内容被同一暖色矩阵统一处理，顺序与参考版一致。
// - 设备项（登记）：sigma 最大 100 的全屏虚化、壁纸按窗口×DPR 解码后的
//   RSS/帧率需真机粗测（widget 测试无法覆盖 GPU 成本）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// 判断背景图路径是否可用（文件存在且非空）
///
/// Web 端无本地文件语义 → false；异常（权限/路径失效）→ false，调用方
/// 按「无背景图」回落（保持原主题底色/壁纸缺省行为）。
bool isThemeBackgroundFileUsable(String path) {
  if (kIsWeb || path.isEmpty) return false;
  try {
    final file = File(path);
    return file.existsSync() && file.lengthSync() > 0;
  } catch (_) {
    return false;
  }
}

/// 主题背景图解码 provider（全局壁纸/容器图共用）
///
/// [P2.2 回修] 用 ResizeImage 把解码尺寸限制到「窗口宽高 × DPR」并保持比例
/// （`ResizeImagePolicy.fit`，不放大），避免 12MP 照片全量解码造成 40-50MB
/// 峰值内存。窗口尺寸不可得（极少见的独立 widget 场景）时退回 FileImage。
ImageProvider<Object> themeBackgroundImageProvider(
  String path,
  BuildContext context,
) {
  final media = MediaQuery.maybeSizeOf(context);
  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
  if (media == null) return FileImage(File(path));
  // 上限 8192 防止极端桌面 DPR 组合产生过大 target（8K 级别）
  final targetWidth = (media.width * dpr).round().clamp(1, 8192);
  final targetHeight = (media.height * dpr).round().clamp(1, 8192);
  return ResizeImage(
    FileImage(File(path)),
    width: targetWidth,
    height: targetHeight,
    policy: ResizeImagePolicy.fit,
    allowUpscaling: false,
  );
}

/// 全局主题背景图层
///
/// [path] 为当前亮/暗模式对应的背景图绝对路径（空=无图）；
/// [blurRadius] 为 0..100 的虚化半径（0=不虚化，不产生 ImageFiltered 开销）。
class ThemeBackgroundLayer extends StatelessWidget {
  final String path;
  final int blurRadius;
  final Widget child;

  const ThemeBackgroundLayer({
    super.key,
    required this.path,
    required this.child,
    this.blurRadius = 0,
  });

  @override
  Widget build(BuildContext context) {
    final usable = isThemeBackgroundFileUsable(path);
    // 恒定结构：child 永远在第 1 slot，避免切换背景图时重建应用子树
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: usable
              ? _BackgroundImage(path: path, blurRadius: blurRadius)
              : const SizedBox.shrink(),
        ),
        child,
      ],
    );
  }
}

/// 只绘制背景图（不包内容），虚化仅作用于此层
class _BackgroundImage extends StatelessWidget {
  final String path;
  final int blurRadius;

  const _BackgroundImage({required this.path, required this.blurRadius});

  @override
  Widget build(BuildContext context) {
    final image = Image(
      image: themeBackgroundImageProvider(path, context),
      fit: BoxFit.cover,
      alignment: Alignment.center,
      gaplessPlayback: true,
      // 图片在构建后失效（被清理/权限变化）→ 静默回落，不抛错
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
    if (blurRadius <= 0) {
      return IgnorePointer(child: image);
    }
    final radius = blurRadius.toDouble();
    return IgnorePointer(
      child: RepaintBoundary(
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: radius,
            sigmaY: radius,
            // clamp：避免模糊后边缘透出下层/透明带
            tileMode: TileMode.clamp,
          ),
          child: image,
        ),
      ),
    );
  }
}
