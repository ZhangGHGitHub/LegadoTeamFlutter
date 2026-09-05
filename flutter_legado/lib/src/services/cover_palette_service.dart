import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:palette_generator/palette_generator.dart';

/// [UI_SYNC_REFACTOR B4] 封面取色服务（对齐参考仓 rememberImageSeedColor）
///
/// 参考链路：Coil 请求 128px → 缩至 ≤64px → QuantizerCelebi(64) → Score，
/// fallback 0xFF4285F4。Flutter 侧 palette_generator 内建 quantize+score
///（dominantColor），128px 采样 + maximumColorCount 64 等效。
class CoverPaletteService {
  CoverPaletteService._();

  /// 提取封面 seed 主色；失败返回 null（调用方回退默认配色）
  static Future<Color?> extractSeed(String coverUrl) async {
    ImageProvider? provider;
    final url = coverUrl.trim();
    if (url.isEmpty) return null;
    if (url.startsWith('http://') || url.startsWith('https://')) {
      provider = NetworkImage(url);
    } else {
      // 本地文件路径（import_local_book 落库约定）
      final file = File(url);
      if (file.existsSync()) provider = FileImage(file);
    }
    if (provider == null) return null;
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        provider,
        size: const Size(128, 128),
        maximumColorCount: 64,
      );
      return palette.dominantColor?.color;
    } catch (_) {
      return null;
    }
  }
}
