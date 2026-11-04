// 自定义翻页键 keyCode 串解析/归一化（批4b）
//
// 参考 `PageKeySheet.kt:62-110`：逗号追加 keyCode；排除 BACK(4)/
// DEL(67)。本工具统一收敛非法/重复值，读写两侧共用。
//
// 编写：全栈工程师（批4b） ｜ 2026-11-04
library;

abstract final class PageKeyCodes {
  /// 系统返回键 / 删除键：不参与自定义翻页
  static const Set<int> excluded = <int>{4, 67};

  /// 解析逗号（或空白）分隔的 keyCode 串：忽略非法/<=0/排除值，去重保序
  static List<int> parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <int>[];
    final out = <int>[];
    for (final token in raw.split(RegExp(r'[,\s]+'))) {
      if (token.isEmpty) continue;
      final code = int.tryParse(token);
      if (code == null || code <= 0 || excluded.contains(code)) continue;
      if (!out.contains(code)) out.add(code);
    }
    return out;
  }

  /// 归一化为参考逗号串
  static String normalize(String? raw) => encode(parse(raw));

  /// 编码
  static String encode(Iterable<int> codes) => codes.join(',');

  /// 追加一个 keyCode（去重保序；BACK/DEL 忽略）
  static String append(String? raw, int keyCode) {
    final codes = List<int>.of(parse(raw));
    if (keyCode > 0 && !excluded.contains(keyCode) && !codes.contains(keyCode)) {
      codes.add(keyCode);
    }
    return encode(codes);
  }

  /// 删除一个 keyCode
  static String remove(String? raw, int keyCode) {
    final codes = List<int>.of(parse(raw))..remove(keyCode);
    return encode(codes);
  }
}
