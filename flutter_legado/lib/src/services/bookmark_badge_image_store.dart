// 书签角标自定义图存储（批4d）
//
// 参考 ReaderBookmarkBadgeRenderer：角标图来自应用内可读资源。为兼容
// 重装/迁移，偏好只保存相对应用 Support 目录的标识
// `bookmark_badges/<md5>.<ext>`（正斜杠），读取时用当前容器目录拼接。
//
// 选图复用 ContainerImagePicker（Android SAF 直接读字节），本类只负责
// 校验/哈希命名/原子落盘与同步解析；文件缺失时调用方回落默认琥珀书签带。
//
// 编写：全栈工程师（批4d） ｜ 2026-11-04
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path_provider/path_provider.dart';

class BookmarkBadgeImageStore {
  BookmarkBadgeImageStore._();

  static const String subDir = 'bookmark_badges';

  /// 角标图体积上限（8MB）：角标最终只显示几十 dp，无需大图
  static const int maxBytes = 8 * 1024 * 1024;

  static const Set<String> _exts = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
  };

  /// 仅接受本类生成的相对标识，阻止备份中的路径穿越
  static final RegExp _ownedPattern = RegExp(
    r'^bookmark_badges/[0-9a-f]{32}\.(?:jpe?g|png|webp|gif|bmp)$',
  );

  /// 测试 seam：应用 Support 目录获取
  @visibleForTesting
  static Future<Directory> Function() supportDir =
      getApplicationSupportDirectory;

  static String? _supportPath;

  /// 预热同步解析所需的 Support 根目录
  static void warmWith(Directory dir) {
    _supportPath = dir.absolute.path;
  }

  @visibleForTesting
  static void resetWarmCache() {
    _supportPath = null;
  }

  /// 启动/首个消费者调用；失败不抛出，角标回落默认样式
  static Future<void> ensureWarm() async {
    if (_supportPath != null) return;
    try {
      warmWith(await supportDir());
    } catch (_) {
      // Support 目录不可得：resolveSync 返回 null，走默认角标
    }
  }

  /// 相对标识 → 当前容器绝对路径；非自有标识/未预热/文件缺失返回 null
  static String? resolveSync(String? identifier) {
    if (identifier == null || !_ownedPattern.hasMatch(identifier)) return null;
    final base = _supportPath;
    if (base == null) return null;
    final fileName = identifier.substring(subDir.length + 1);
    final path =
        '$base${Platform.pathSeparator}$subDir'
        '${Platform.pathSeparator}$fileName';
    return File(path).existsSync() ? path : null;
  }

  /// 字节流落盘，返回相对标识（同图内容命中同一哈希，不重复写盘）
  static Future<String> storeBytes(
    Uint8List bytes, {
    required String originalName,
  }) async {
    if (kIsWeb) throw UnsupportedError('Web 端不支持书签角标图');
    if (bytes.isEmpty) throw const FormatException('图片内容为空');
    if (bytes.length > maxBytes) {
      throw FormatException('图片过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）');
    }
    final support = await supportDir();
    final supportPath = support.absolute.path;
    _supportPath = supportPath;

    final digest = md5.convert(bytes).toString();
    final fileName = '$digest.${_extensionOf(originalName)}';
    final dir = Directory('$supportPath${Platform.pathSeparator}$subDir');
    await dir.create(recursive: true);
    final target = File('${dir.path}${Platform.pathSeparator}$fileName');
    final relative = '$subDir/$fileName';
    if (target.existsSync()) return relative;

    final tmp = File(
      '${dir.path}${Platform.pathSeparator}.$fileName'
      '.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      if (target.existsSync()) {
        await _safeDelete(tmp);
      } else {
        await tmp.rename(target.path);
      }
    } on FileSystemException {
      await _safeDelete(tmp);
      if (!target.existsSync()) rethrow;
    }
    return relative;
  }

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot >= 0 && dot < name.length - 1) {
      final ext = name.substring(dot + 1).toLowerCase();
      if (_exts.contains(ext)) return ext;
    }
    return 'jpg';
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // 清理失败不阻断主流程
    }
  }
}
