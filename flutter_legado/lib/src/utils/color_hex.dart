// [设置批2b-1b-1-b | 2026-11-01] 颜色 HEX 解析/格式化 — 全栈工程师
//
// 参考版 `ColorPickerSheet` 支持任意 HEX 输入；本工具供卡片边框/分隔线
// 颜色对话框复用。0 仍由调用方表示「默认」（不在此处编码）。
//
// 口径：
// - 接受 `#RRGGBB` / `#AARRGGBB`，`#` 可省略，大小写不敏感，首尾空白忽略；
// - 6 位按不透明补 `FF` 前缀，8 位按 ARGB 原样；
// - 其他长度/非法字符返回 null。
// - 格式化不补前导 0（对齐参考版 `Integer.toHexString(color).uppercase()`）。

/// 解析 HEX 颜色；非法返回 null
int? parseArgbHexColor(String input) {
  var text = input.trim();
  if (text.startsWith('#')) text = text.substring(1);
  if (text.length != 6 && text.length != 8) return null;
  final value = int.tryParse(text, radix: 16);
  if (value == null) return null;
  if (text.length == 6) return 0xFF000000 | value;
  return value;
}

/// ARGB → `#AARRGGBB`（不补前导 0；参考版 `Integer.toHexString` 大写形态）
String argbToHex(int argb) => '#${argb.toRadixString(16).toUpperCase()}';
