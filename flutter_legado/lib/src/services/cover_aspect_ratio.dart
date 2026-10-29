// 封面原图宽高比缓存与自适应高度换算（批39）
//
// 对齐参考版：
// - `CoverSettings.kt:10-15` `restrictCoverRatio` 默认开（封面固定 5:7），
//   关闭后按原图宽高比自适应；
// - `SearchBookItem.kt:53-92` / `BookInfoScreen.kt:1169-1185`：
//   `cachedCoverAspectRatio(url)` 缓存已解析比例，列表回收重建时直接落在
//   最终高度，不先回弹 5:7 再等图加载。
//
// 本仓无 Coil 的 `onImageAspectRatio` 回调，比例由 `BookCover` 在图片加载
// 完成时（网络图经 ImageStream 尺寸 / 解码字节经 ImageDescriptor 头部）
// 上报并写入本缓存；网格行高经 `coverAspectRatioRevisionProvider` 重算。
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 封面比例修订号（新比例入缓存时自增）
///
/// 书架/发现页监听该值后重算网格行高（「限制封面比例」关闭时行高随原图
/// 比例调整）；用全局 ValueNotifier 而非 Riverpod，避免 BookCover 在无
/// ProviderScope 的测试/局部宿主中依赖容器。
final ValueNotifier<int> coverAspectRatioRevision = ValueNotifier<int>(0);

/// 封面比例常量与缓存
class CoverAspectRatio {
  CoverAspectRatio._();

  /// 固定比例 5:7（宽/高），对齐参考版 `DEFAULT_*_COVER_ASPECT_RATIO`
  static const double restricted = 5 / 7;

  /// 合法比例下限（宽/高）：更窄的图（高度超过宽度 2.5 倍）按此收敛，
  /// 避免列表行被极端竖图撑破
  static const double minRatio = 0.4;

  /// 合法比例上限（宽/高）：横版封面按此收敛
  static const double maxRatio = 1.5;

  /// 缓存条目上限（LRU）：长列表/多次浏览会持续写入不同封面 URL，
  /// 无上限会让进程内 Map 无限增长（每项仅一个 double，但键串不受控）
  static const int maxEntries = 600;

  /// 已解析比例缓存（coverUrl → 宽/高；含内存，进程级）
  ///
  /// Dart 的 `Map` 保持插入序，这里复用为 LRU：命中时把键移到末尾，
  /// 写入超限时淘汰表头（最久未使用）键。
  static final Map<String, double> _cache = <String, double>{};

  /// 取已解析比例（命中时刷新 LRU 位置）
  static double? cached(String? url) {
    final key = url?.trim() ?? '';
    if (key.isEmpty) return null;
    final hit = _cache.remove(key);
    if (hit == null) return null;
    _cache[key] = hit;
    return hit;
  }

  /// 记录比例；非法（非有限/非正）返回 false，命中已知同值也返回 false
  ///
  /// 返回值用于调用方决定是否递增 `coverAspectRatioRevision`
  /// （仅新值需要重算网格行高）。需要区分「是否首个已知比例」时用
  /// [rememberDetailed]。
  static bool remember(String? url, double? ratio) =>
      rememberDetailed(url, ratio).changed;

  /// 记录比例并返回写入效果
  ///
  /// [firstKnown] 为 true 表示本次写入前缓存**没有任何已知比例**——此时
  /// 各网格的「代表比例」会从回退值 5:7 切换为该值，即使「限制封面比例」
  /// 开启（网格行高固定、本不需要逐张通知）也应通知一次重算。
  static ({bool changed, bool firstKnown}) rememberDetailed(
    String? url,
    double? ratio,
  ) {
    final key = url?.trim() ?? '';
    if (key.isEmpty || !isValid(ratio)) {
      return (changed: false, firstKnown: false);
    }
    final value = ratio!.clamp(minRatio, maxRatio).toDouble();
    final firstKnown = _cache.isEmpty;
    if (_cache[key] == value) {
      // 命中同值也刷新 LRU 位置（视为最近使用）
      _cache.remove(key);
      _cache[key] = value;
      return (changed: false, firstKnown: false);
    }
    _cache.remove(key);
    _cache[key] = value;
    while (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return (changed: true, firstKnown: firstKnown);
  }

  /// 比例是否合法（有限、正数）
  static bool isValid(double? ratio) =>
      ratio != null && ratio.isFinite && ratio > 0;

  /// 取封面比例（未知回退固定 5:7）
  static double ratioFor(String? url) => cached(url) ?? restricted;

  /// 按固定宽度与原图比例换算显示高度，并夹在 [minHeight, maxHeight]
  static double heightFor({
    required double width,
    required double ratio,
    required double minHeight,
    required double maxHeight,
  }) {
    final safeRatio = isValid(ratio) ? ratio.clamp(minRatio, maxRatio) : restricted;
    final raw = width / safeRatio;
    final lower = minHeight > 0 ? minHeight : raw;
    final upper = maxHeight >= lower ? maxHeight : lower;
    return raw.clamp(lower, upper).toDouble();
  }

  /// 网格代表比例：取已知比例中的第一个（同图不同比例时整格统一，保持
  /// 行高稳定）；全部未知回退固定 5:7。
  static double representativeRatio(Iterable<String?> urls) {
    for (final url in urls) {
      final ratio = cached(url);
      if (ratio != null) return ratio;
    }
    return restricted;
  }

  /// 清空缓存（测试隔离用）
  static void clear() => _cache.clear();
}

/// 是否应递增 [coverAspectRatioRevision]（驱动网格/列表重算行高）
///
/// [批39 审查回修] 「限制封面比例」开启（默认）时网格行高固定 5:7，逐张
/// 封面都递增修订号会让整屏（书架/发现网格）无谓重建；因此：
/// - `restrict=false`：布局随比例变化，任何新值都要通知；
/// - `restrict=true`：仅「首个已知比例」需要通知一次（网格代表比例从回退
///   5:7 切换为该值，此后行高仍固定，不再通知）。
bool shouldNotifyCoverRatioRevision({
  required bool changed,
  required bool restrict,
  required bool firstKnown,
}) =>
    changed && (!restrict || firstKnown);

/// 从图片字节解析宽高比（仅读文件头，不做完整解码）
///
/// 失败（非图片/格式不支持/引擎异常）返回 null，调用方回退固定比例。
Future<double?> decodeImageAspectRatio(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.height <= 0) return null;
    return descriptor.width / descriptor.height;
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}
