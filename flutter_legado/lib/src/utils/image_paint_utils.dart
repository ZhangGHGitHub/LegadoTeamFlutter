import 'dart:ui';

import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';

/// 图片绘制偏好镜像（批9a：antiAlias / bitmapCacheSize 的运行时快照）
///
/// 背景：抗锯齿与图片绘制缓存是**全局**偏好，消费点分散在阅读翻页
/// painter（CustomPainter.paint 无 BuildContext）与漫画绘制处。painter
/// 内直读 SharedPreferences（异步）不可行，故在启动时（main.dart）与
/// 偏好变更时（other_settings_screen）同步刷新本镜像，绘制侧零开销读取。
///
/// 语义对齐：
/// - [antiAlias]：原版 `AppConfig.useAntiAlias`（ContentTextView.kt:106 消费
///   于正文文字绘制）；Flutter `TextPainter` 不暴露抗锯齿开关（恒开启），
///   本项目只能作用于**图片绘制**（UI 副题「绘制图片时抗锯齿」本就吻合，
///   属平台差异登记，非缺陷）。默认 false 对齐原版/参考版。
/// - [bitmapCacheSize]：原版 `AppConfig.bitmapCacheSize`（ImageProvider.kt
///   1..1024 MB 校验，默认 50MB）；Flutter 侧对应 `PaintingBinding
///   .instance.imageCache.maximumSizeBytes`，越界回落 50。
///
/// 平台差异登记：原版该项作用于文字绘制 Paint.isAntiAlias；本镜像仅驱动
/// 图片绘制的 FilterQuality / Paint.isAntiAlias，文字渲染不受影响。
class ImagePaintPrefs {
  ImagePaintPrefs._();

  /// 图片绘制缓存上限默认值 MB（对齐原版 ImageProvider.kt:44 回落值）
  static const int defaultBitmapCacheSizeMb = 50;

  /// 图片绘制缓存上限合法区间 MB（对齐原版 1..1024）
  static const int minBitmapCacheSizeMb = 1;
  static const int maxBitmapCacheSizeMb = 1024;

  /// 抗锯齿开关镜像（false=绘制图片时关闭抗锯齿/降低采样质量，默认关）
  static bool antiAlias = false;

  /// 图片绘制缓存上限（MB，已钳制到 1..1024，越界回落 50）
  static int bitmapCacheSizeMb = defaultBitmapCacheSizeMb;

  /// 启动/偏好变更时刷新镜像（读 SharedPreferences，失败保持当前值）
  ///
  /// main.dart 启动序列与 other_settings_screen 的开关回调各调用一次。
  static Future<void> refresh() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      antiAlias = prefs.getBool(PrefKeys.antiAlias) ?? false;
      final size = prefs.getInt(PrefKeys.bitmapCacheSize) ??
          defaultBitmapCacheSizeMb;
      bitmapCacheSizeMb =
          (size >= minBitmapCacheSizeMb && size <= maxBitmapCacheSizeMb)
              ? size
              : defaultBitmapCacheSizeMb;
    } catch (_) {
      // prefs 读取失败保持当前镜像值（默认 false/50MB），不阻断启动
    }
  }

  /// 抗锯齿开启时的图片采样质量（FilterQuality）
  ///
  /// - antiAlias=true → [FilterQuality.high]（高采样，边缘平滑）；
  /// - antiAlias=false → [FilterQuality.medium]（默认档，与接线前视觉一致，
  ///   原版关闭抗锯齿以换取滚动性能）。
  static FilterQuality get imageFilterQuality =>
      antiAlias ? FilterQuality.high : FilterQuality.medium;

  /// 按偏好构造图片绘制 Paint（isAntiAlias + filterQuality 一并落位）
  static Paint imagePaint() => Paint()
    ..isAntiAlias = antiAlias
    ..filterQuality = imageFilterQuality;

  /// 把图片绘制缓存上限应用到 Flutter 全局解码缓存（批9a 项3）
  ///
  /// `PaintingBinding.instance.imageCache.maximumSizeBytes` 是 Flutter 图片
  /// 解码结果的字节上限，与原版 ImageProvider 的 Bitmap LruCache 语义最接近；
  /// 越界值已在 [refresh] 钳制回落 50。须在 WidgetsFlutterBinding 初始化后
  /// 调用（main.dart 启动序列满足）。
  static void applyImageCacheLimit() {
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        bitmapCacheSizeMb * 1024 * 1024;
  }
}
