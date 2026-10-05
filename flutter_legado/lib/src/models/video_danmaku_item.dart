/// 视频弹幕项（V-B2，契约 §2.50）
///
/// 由 Rust `parseVideoDanmaku` 解析 B 站弹幕 XML 得到（Dart 侧仅 JSON 解码，
/// 不含 XML 语义逻辑）。字段语义对齐原版 `BiliDanmukuParser.kt`：
/// - [timeMs]：出现时间（毫秒，`p0.toFloat() * 1000` 截断）；
/// - [type]：弹幕类型（1 右→左 / 4 底 / 5 顶 / 6 左→右 / 7 高级），
///   2/3/8 及范围外类型已由 Rust 侧静默丢弃；
/// - [textSizeRaw]：字号原值（未乘 density——平台换算归渲染层）；
/// - [color]：有符号 ARGB（对齐 Kotlin `Int` 口径，如白色 = -1）；
/// - [text]：文本（type7 为 JSON 属性原文，V-B2 不渲染，登记边界）。
class VideoDanmakuItem {
  const VideoDanmakuItem({
    required this.timeMs,
    required this.type,
    required this.textSizeRaw,
    required this.color,
    required this.text,
  });

  /// JSON 解码（契约 §2.50 返回数组的元素；字段缺失/类型异常时抛错，
  /// 由调用方降级——数据来自 Rust 纯函数，形状有契约保证）
  factory VideoDanmakuItem.fromJson(Map<String, dynamic> json) {
    return VideoDanmakuItem(
      timeMs: (json['timeMs'] as num).toInt(),
      type: (json['type'] as num).toInt(),
      textSizeRaw: (json['textSizeRaw'] as num).toDouble(),
      color: (json['color'] as num).toInt(),
      text: json['text'] as String,
    );
  }

  /// 出现时间（毫秒）
  final int timeMs;

  /// 弹幕类型（1/4/5/6/7）
  final int type;

  /// 字号原值（density 换算在渲染层）
  final double textSizeRaw;

  /// 有符号 ARGB 颜色（Kotlin Int 口径）
  final int color;

  /// 文本内容
  final String text;
}
