import 'dart:convert';

/// 底栏皮肤文件名逻辑（对齐原版 BottomBarSkinFormat，无平台依赖）
class BottomBarSkinFormat {
  BottomBarSkinFormat._();

  static const maxSkinNameLength = 80;
  static const maxSkinNameBytes = 240;
  static const maxImageNameLength = 128;
  static const maxImageNameBytes = 240;

  static final _invalidFileChars = RegExp(r'[\u0000-\u001F\u007F\\/:*?"<>|]');

  /// 底栏 4 槽（bookshelf/发现/订阅/我的）
  static const mappedSlots = ['bookshelf', 'home', 'notes', 'settings'];

  static const imageExts = ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'];

  static bool isImageName(String name) {
    final file = name.split(RegExp(r'[\\/]')).last.toLowerCase();
    final ext = file.contains('.') ? file.split('.').last : '';
    return imageExts.contains(ext);
  }

  /// 解析 `slot_selected.ext` / `slot_normal.ext`
  static ({String slot, bool selected})? parseEntryName(String name) {
    final file = name.split(RegExp(r'[\\/]')).last.toLowerCase();
    final dot = file.lastIndexOf('.');
    if (dot <= 0) return null;
    if (!imageExts.contains(file.substring(dot + 1))) return null;
    final base = file.substring(0, dot);
    late final String slot;
    late final bool selected;
    if (base.endsWith('_selected')) {
      slot = base.substring(0, base.length - '_selected'.length);
      selected = true;
    } else if (base.endsWith('_normal')) {
      slot = base.substring(0, base.length - '_normal'.length);
      selected = false;
    } else {
      return null;
    }
    if (!mappedSlots.contains(slot)) return null;
    return (slot: slot, selected: selected);
  }

  static String uniqueName(String desired, Iterable<String> existing) {
    final existingSet = existing.toSet();
    final base = sanitize(desired);
    if (!existingSet.contains(base)) return base;
    var i = 2;
    while (true) {
      final suffix = ' ($i)';
      final stem = _truncate(
        base,
        maxSkinNameLength - suffix.length,
        maxSkinNameBytes - utf8.encode(suffix).length,
      ).replaceAll(RegExp(r'\s+$'), '');
      final candidate = '$stem$suffix';
      if (!existingSet.contains(candidate)) return candidate;
      i++;
    }
  }

  static String sanitize(String name) {
    var cleaned = name.replaceAll(_invalidFileChars, '_').trim();
    while (cleaned.startsWith('.') || cleaned.endsWith('.')) {
      cleaned = cleaned.replaceAll(RegExp(r'^\.+|\.+$'), '').trim();
    }
    final truncated = _truncate(cleaned, maxSkinNameLength, maxSkinNameBytes)
        .trim()
        .replaceAll(RegExp(r'^\.+|\.+$'), '');
    return truncated.isEmpty ? 'skin' : truncated;
  }

  static bool isValidSkinName(String name) {
    return name.isNotEmpty &&
        name.runes.length <= maxSkinNameLength &&
        utf8.encode(name).length <= maxSkinNameBytes &&
        !name.startsWith('.') &&
        name == sanitize(name);
  }

  static String? sanitizeImageName(String name) {
    final base = name.split(RegExp(r'[\\/]')).last;
    final dot = base.lastIndexOf('.');
    if (dot <= 0) return null;
    final extension = base.substring(dot + 1).toLowerCase();
    if (!imageExts.contains(extension)) return null;
    final suffix = '.$extension';
    var cleaned = base
        .substring(0, dot)
        .replaceAll(_invalidFileChars, '_')
        .trim()
        .replaceAll(RegExp(r'[.\s]+$'), '');
    if (cleaned.isEmpty) cleaned = 'image';
    final stem = _truncate(
      cleaned,
      maxImageNameLength - suffix.length,
      maxImageNameBytes - utf8.encode(suffix).length,
    ).replaceAll(RegExp(r'[.\s]+$'), '');
    if (stem.isEmpty) return null;
    return '$stem$suffix';
  }

  static String _truncate(String value, int maxCodePoints, int maxBytes) {
    final result = StringBuffer();
    var codePoints = 0;
    var bytes = 0;
    for (final rune in value.runes) {
      final ch = String.fromCharCode(rune);
      final charBytes = utf8.encode(ch).length;
      if (codePoints + 1 > maxCodePoints) break;
      if (bytes + charBytes > maxBytes) break;
      result.write(ch);
      codePoints++;
      bytes += charBytes;
    }
    return result.toString();
  }
}
