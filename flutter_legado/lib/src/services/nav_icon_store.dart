// [设置批2b-2a | 2026-11-02] 主导航自定义图标文件存储（对齐参考版
// ThemeConfigRouteScreen.kt:46-77 / ThemeConfigViewModel.selectNavigationIcon）
//
// 参考版口径：
// - 选图走系统图片选择器（GetContent "image/png"）；
// - 图片复制到 `filesDir/nav_icons/`，以**内容摘要**命名（同图重复选择
//   命中同一路径，避免覆盖固定文件名导致缓存到旧图）；
// - 多个槽位可引用同一文件，只有不再被任何槽位引用时才删除；
// - 恢复默认主题配置时整目录删除。
//
// 本实现用 sha1 摘要（crypto 已为直接依赖），文件扩展名保留源扩展名
// （无扩展名时按 .png 处理）；所有文件操作失败均静默降级到内置图标，
// 不阻断导航渲染。
// — 全栈工程师 + UI，2026-11-02
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 导航自定义图标文件存储
class NavIconStore {
  NavIconStore._();

  /// 测试可替换的图标目录（避免依赖 path_provider 平台通道）
  @visibleForTesting
  static Directory? debugDirectoryOverride;

  /// 图标目录：`<应用支持目录>/nav_icons`
  static Future<Directory> directory() async {
    final override = debugDirectoryOverride;
    if (override != null) {
      await override.create(recursive: true);
      return override;
    }
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}nav_icons');
    await dir.create(recursive: true);
    return dir;
  }

  /// 从用户选择的图片导入，返回持久化后的文件路径
  ///
  /// 失败（读不到源文件/写盘异常）返回空字符串，由调用方提示。
  static Future<String> importFromPath(String sourcePath) async {
    if (sourcePath.isEmpty) return '';
    try {
      final source = File(sourcePath);
      if (!await source.exists()) return '';
      final bytes = await source.readAsBytes();
      final digest = sha1.convert(bytes).toString();
      final extension = _safeExtension(sourcePath);
      final dir = await directory();
      final destination = File(
        '${dir.path}${Platform.pathSeparator}$digest$extension',
      );
      if (!await destination.exists()) {
        await destination.writeAsBytes(bytes, flush: true);
      }
      return destination.path;
    } catch (e) {
      debugPrint('NavIconStore.importFromPath 失败: $e');
      return '';
    }
  }

  /// 旧图标不再被任何槽位引用时删除（只删除本服务目录内的文件）
  static Future<void> deleteIfUnused(
    String path, {
    required Iterable<String> keep,
  }) async {
    if (path.isEmpty || keep.contains(path)) return;
    try {
      final dir = await directory();
      final file = File(path);
      if (!_isInside(dir.path, file.path)) return;
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('NavIconStore.deleteIfUnused 失败: $e');
    }
  }

  /// 清空图标目录（恢复默认时调用）
  static Future<void> deleteAll() async {
    try {
      final dir = debugDirectoryOverride ?? await _rawDirectory();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('NavIconStore.deleteAll 失败: $e');
    }
  }

  static Future<Directory> _rawDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}nav_icons');
  }

  /// 保留源文件扩展名（仅字母数字，最长 8 位；否则回退 .png）
  static String _safeExtension(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '.png';
    final ext = name.substring(dot + 1).toLowerCase();
    if (!RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext)) return '.png';
    return '.$ext';
  }

  /// 判断 [filePath] 是否位于 [dirPath] 内（防误删用户文件）
  static bool _isInside(String dirPath, String filePath) {
    final dir = _normalize(dirPath);
    final file = _normalize(filePath);
    // _normalize 统一为 '/'，Windows 下不能用 Platform.pathSeparator 拼接
    return file.startsWith('$dir/');
  }

  static String _normalize(String path) {
    var value = path.replaceAll('\\', '/');
    while (value.endsWith('/') && value.length > 1) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}
