// [批14 | 2026-11-10] App 主题包 zip 导出/导入 — 全栈工程师
//
// 主题包内容（已裁决）：配色 12 色槽 + 主题名 + 背景图（日/夜各一张）。
// 字体、导航图标、封面相册不入包；导入时忽略包内未知资源。
//
// zip 结构：
//   manifest.json
//   assets/background/light.<ext>   （存在才写）
//   assets/background/dark.<ext>    （存在才写）
//
// manifest（formatVersion=1）：
// ```json
// {
//   "formatVersion": 1,
//   "name": "主题名",
//   "appVersion": "2.0.482",
//   "config": {
//     "isNight": false,
//     "paletteId": null,
//     "colors": {
//       "primary": 0, "accent": 0, "background": 0, "bottomBackground": 0,
//       "primaryText": 0, "secondaryText": 0,
//       "primaryNight": 0, "accentNight": 0, "backgroundNight": 0,
//       "bottomBackgroundNight": 0, "primaryTextNight": 0,
//       "secondaryTextNight": 0
//     }
//   },
//   "assets": {"background": {"light": "assets/background/light.png"}}
// }
// ```
// 颜色值 0 = 未设置（与批13 口径一致）。
//
// 安全口径：条目数 ≤ 4096、单条 ≤ 64MB、总量 ≤ 512MB；拒绝含 `..`、
// 绝对路径、反斜杠或 NUL 的条目名；拒绝 0 字节 zip。所有失败以
// [ThemePackageException] 抛出中文原因，调用方直接展示。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:package_info_plus/package_info_plus.dart';

import '../constants/pref_keys.dart';
import '../providers/theme/theme_colors_notifier.dart';
import 'theme_config_json.dart';

/// 主题包解析/生成失败（message 为可直接展示的中文原因）
class ThemePackageException implements Exception {
  const ThemePackageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 解析后的主题包数据
class ThemePackageData {
  const ThemePackageData({
    required this.name,
    required this.isNight,
    required this.paletteId,
    required this.colors,
    this.backgroundLight,
    this.backgroundDark,
    this.backgroundLightName,
    this.backgroundDarkName,
    this.appVersion = '',
  });

  /// 主题名（清单缺失/为空时回落 `theme`）
  final String name;

  /// 主题归属（true = 夜间主题）
  final bool isNight;

  /// 清单内的调色板编号（不透明整数；我方保存主题无此概念时为 null）
  final int? paletteId;

  /// 12 色槽，键为 [PrefKeys] 颜色键；0 = 未设置
  final Map<String, int> colors;

  /// 日间背景图字节（无则为 null）
  final Uint8List? backgroundLight;

  /// 夜间背景图字节（无则为 null）
  final Uint8List? backgroundDark;

  /// 日间背景图在包内的条目名（推断扩展名用）
  final String? backgroundLightName;

  /// 夜间背景图在包内的条目名（推断扩展名用）
  final String? backgroundDarkName;

  /// 生成该包的 App 版本（排障用）
  final String appVersion;
}

/// App 主题包 zip 编解码
abstract final class ThemePackageService {
  ThemePackageService._();

  /// 当前支持的清单版本
  static const int formatVersion = 1;

  /// zip 条目数上限
  static const int maxEntries = 4096;

  /// 单条解压后大小上限（64MB）
  static const int maxEntryBytes = 64 * 1024 * 1024;

  /// 解压总量上限（512MB）
  static const int maxTotalBytes = 512 * 1024 * 1024;

  /// 清单颜色键 → 我方偏好键（顺序即导出顺序）
  static const List<(String, String)> _colorKeys = [
    (PrefKeys.cPrimary, 'primary'),
    (PrefKeys.cAccent, 'accent'),
    (PrefKeys.cBackground, 'background'),
    (PrefKeys.cBBackground, 'bottomBackground'),
    (PrefKeys.cPrimaryText, 'primaryText'),
    (PrefKeys.cSecondaryText, 'secondaryText'),
    (PrefKeys.cNPrimary, 'primaryNight'),
    (PrefKeys.cNAccent, 'accentNight'),
    (PrefKeys.cNBackground, 'backgroundNight'),
    (PrefKeys.cNBBackground, 'bottomBackgroundNight'),
    (PrefKeys.cNPrimaryText, 'primaryTextNight'),
    (PrefKeys.cNSecondaryText, 'secondaryTextNight'),
  ];

  /// 导出主题包到 [targetPath]（目录不存在时自动创建）
  ///
  /// [backgroundLight]/[backgroundDark] 为已存在的图片文件（可为 null）；
  /// 文件不存在/为空时视为无图，不中断导出。
  static Future<void> exportThemePackage({
    required String name,
    required ThemeColorsState colors,
    int? paletteId,
    bool isNight = false,
    File? backgroundLight,
    File? backgroundDark,
    required String targetPath,
  }) async {
    final light = await _readBackground(
      backgroundLight,
      'assets/background/light',
    );
    final dark = await _readBackground(
      backgroundDark,
      'assets/background/dark',
    );

    final manifest = <String, dynamic>{
      'formatVersion': formatVersion,
      'name': _normalizeName(name),
      'appVersion': await appVersionLoader(),
      'config': <String, dynamic>{
        'isNight': isNight,
        'paletteId': paletteId,
        'colors': <String, int>{
          for (final (prefKey, manifestKey) in _colorKeys)
            manifestKey: _colorValue(colors, prefKey),
        },
      },
      'assets': <String, dynamic>{
        'background': <String, dynamic>{
          if (light != null) 'light': light.$1,
          if (dark != null) 'dark': dark.$1,
        },
      },
    };

    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes(
          'manifest.json',
          utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
        ),
      );
    if (light != null) {
      archive.addFile(ArchiveFile.bytes(light.$1, light.$2));
    }
    if (dark != null) {
      archive.addFile(ArchiveFile.bytes(dark.$1, dark.$2));
    }

    final encoded = ZipEncoder().encode(archive);
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    await target.writeAsBytes(encoded, flush: true);
  }

  /// 解析主题包（安全校验 + 清单校验）
  static Future<ThemePackageData> importThemePackage(File zip) async {
    final fileLength = await zip.length();
    if (fileLength <= 0) {
      throw const ThemePackageException('主题包文件为空');
    }
    if (fileLength > maxTotalBytes) {
      throw const ThemePackageException('主题包文件过大（上限 512MB）');
    }
    final bytes = await zip.readAsBytes();
    if (bytes.isEmpty) {
      throw const ThemePackageException('主题包文件为空');
    }
    // archive 的 ZipDecoder 对非 zip 输入会返回空归档（不抛错），先按本地
    // 文件头判定，避免把任意文件报成「清单不完整」。
    if (!_looksLikeZip(bytes)) {
      throw const ThemePackageException('无法读取主题包（文件格式不正确）');
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const ThemePackageException('无法读取主题包（文件格式不正确）');
    }

    final files = <String, Uint8List>{};
    var count = 0;
    var declaredTotal = 0;
    var actualTotal = 0;
    for (final entry in archive) {
      count++;
      if (count > maxEntries) {
        throw const ThemePackageException('主题包条目过多（上限 4096）');
      }
      final entryName = entry.name;
      if (!_isSafeEntryName(entryName)) {
        throw ThemePackageException('主题包包含非法路径：$entryName');
      }
      if (entry.isDirectory) continue;

      // 先看中央目录声明的大小，避免为超大条目解压后再判断
      if (entry.size > maxEntryBytes) {
        throw ThemePackageException('主题包条目过大：$entryName');
      }
      declaredTotal += entry.size;
      if (declaredTotal > maxTotalBytes) {
        throw const ThemePackageException('主题包内容过大（上限 512MB）');
      }

      final data = entry.content;
      if (data.length > maxEntryBytes) {
        throw ThemePackageException('主题包条目过大：$entryName');
      }
      actualTotal += data.length;
      if (actualTotal > maxTotalBytes) {
        throw const ThemePackageException('主题包内容过大（上限 512MB）');
      }
      files[entryName] = data;
    }

    final manifestBytes = files['manifest.json'];
    if (manifestBytes == null) {
      throw const ThemePackageException('主题包清单不完整');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifestBytes, allowMalformed: true));
    } catch (_) {
      throw const ThemePackageException('主题包清单不完整');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ThemePackageException('主题包清单不完整');
    }

    final version = _asNullableInt(decoded['formatVersion']);
    if (version != formatVersion) {
      throw ThemePackageException('不支持的主题包版本: ${version ?? '未知'}');
    }

    final config = decoded['config'];
    if (config is! Map<String, dynamic>) {
      throw const ThemePackageException('主题包清单不完整');
    }
    final colorsRaw = config['colors'];
    if (colorsRaw is! Map<String, dynamic>) {
      throw const ThemePackageException('主题包清单不完整');
    }

    final lightPath = _resolveBackgroundPath(decoded, files, 'light');
    final darkPath = _resolveBackgroundPath(decoded, files, 'dark');
    final lightBytes = lightPath == null ? null : files[lightPath];
    final darkBytes = darkPath == null ? null : files[darkPath];

    return ThemePackageData(
      name: _normalizeName(decoded['name']),
      isNight: config['isNight'] == true,
      paletteId: _asNullableInt(config['paletteId']),
      colors: _decodeColors(colorsRaw),
      backgroundLight: lightBytes == null || lightBytes.isEmpty
          ? null
          : lightBytes,
      backgroundDark: darkBytes == null || darkBytes.isEmpty ? null : darkBytes,
      backgroundLightName: lightBytes == null || lightBytes.isEmpty
          ? null
          : lightPath,
      backgroundDarkName: darkBytes == null || darkBytes.isEmpty
          ? null
          : darkPath,
      appVersion: decoded['appVersion'] is String
          ? decoded['appVersion'] as String
          : '',
    );
  }

  /// 重名递增：`X` → `X 2` → `X 3`（参考 uniqueSavedThemeName 口径）
  static String uniqueThemeName(String desired, Iterable<String> existing) {
    final base = _normalizeName(desired);
    final used = existing.toSet();
    if (!used.contains(base)) return base;
    var index = 2;
    while (used.contains('$base $index')) {
      index++;
    }
    return '$base $index';
  }

  /// 导出文件名：`legado_theme_<净化名>_<millis>.zip`
  ///
  /// 净化 = 删除 `/\:*?"<>|` 并去首尾空格；空名回落 `theme`。
  static String exportFileName({required String name, required int millis}) =>
      'legado_theme_${sanitizeName(name)}_$millis.zip';

  /// 文件名净化（仅用于文件名，不改清单内的主题名）
  static String sanitizeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    return cleaned.isEmpty ? 'theme' : cleaned;
  }

  /// 清单主题名规范化：去首尾空白，空名回落 `theme`
  static String _normalizeName(dynamic raw) {
    final name = raw is String ? raw.trim() : '';
    return name.isEmpty ? 'theme' : name;
  }

  /// 按偏好键取颜色值（null → 0 = 未设置）
  static int _colorValue(ThemeColorsState colors, String key) => switch (key) {
    PrefKeys.cPrimary => colors.primary ?? 0,
    PrefKeys.cAccent => colors.accent ?? 0,
    PrefKeys.cBackground => colors.background ?? 0,
    PrefKeys.cBBackground => colors.bottomBackground ?? 0,
    PrefKeys.cNPrimary => colors.primaryNight ?? 0,
    PrefKeys.cNAccent => colors.accentNight ?? 0,
    PrefKeys.cNBackground => colors.backgroundNight ?? 0,
    PrefKeys.cNBBackground => colors.bottomBackgroundNight ?? 0,
    PrefKeys.cPrimaryText => colors.primaryTextColor,
    PrefKeys.cSecondaryText => colors.secondaryTextColor,
    PrefKeys.cNPrimaryText => colors.primaryTextColorNight,
    PrefKeys.cNSecondaryText => colors.secondaryTextColorNight,
    _ => 0,
  };

  /// 清单 colors → 我方 12 槽（缺字段/非数值按 0）
  static Map<String, int> _decodeColors(Map<String, dynamic> source) => {
    for (final (prefKey, manifestKey) in _colorKeys)
      prefKey: ThemeConfigJson.asInt(source[manifestKey]) ?? 0,
  };

  /// 读取背景图并返回（条目名, 字节）；不存在/空文件返回 null
  static Future<(String, Uint8List)?> _readBackground(
    File? file,
    String entryPrefix,
  ) async {
    if (file == null) return null;
    final bool exists;
    try {
      exists = await file.exists();
    } on FileSystemException {
      return null;
    }
    if (!exists) return null;
    final length = await file.length();
    if (length <= 0) return null;
    if (length > maxEntryBytes) {
      throw const ThemePackageException('背景图片过大（上限 64MB）');
    }
    final bytes = await file.readAsBytes();
    return ('$entryPrefix.${_imageExtension(file.path)}', bytes);
  }

  /// 清单引用的背景图条目名；引用非法抛错，引用缺失时尝试按固定路径发现
  static String? _resolveBackgroundPath(
    Map<String, dynamic> manifest,
    Map<String, Uint8List> files,
    String side,
  ) {
    final assets = manifest['assets'];
    Map<String, dynamic>? background;
    if (assets is Map<String, dynamic>) {
      final raw = assets['background'];
      if (raw is Map<String, dynamic>) background = raw;
    }
    final referenced = background?[side];
    String? path;
    if (referenced is String && referenced.trim().isNotEmpty) {
      path = referenced.trim();
      if (!_isSafeEntryName(path) || !path.startsWith('assets/background/')) {
        throw ThemePackageException('主题包包含非法路径：$path');
      }
      return files.containsKey(path) ? path : null;
    }
    // 清单未声明时按固定命名发现（兼容手工打包/精简清单）
    final prefix = 'assets/background/$side.';
    final candidates =
        files.keys.where((name) => name.startsWith(prefix)).toList()..sort();
    return candidates.isEmpty ? null : candidates.first;
  }

  /// zip 本地文件头（普通/空归档/分段）；其他内容一律按格式错误拒绝
  static bool _looksLikeZip(Uint8List bytes) {
    if (bytes.length < 4) return false;
    if (bytes[0] != 0x50 || bytes[1] != 0x4B) return false;
    return (bytes[2] == 0x03 && bytes[3] == 0x04) ||
        (bytes[2] == 0x05 && bytes[3] == 0x06) ||
        (bytes[2] == 0x07 && bytes[3] == 0x08);
  }

  /// 条目名安全校验：禁止绝对路径、反斜杠、NUL 与 `..` 段
  static bool _isSafeEntryName(String name) {
    if (name.isEmpty) return false;
    if (name.contains('\\') || name.contains('\u0000')) return false;
    if (name.startsWith('/')) return false;
    if (RegExp(r'^[A-Za-z]:').hasMatch(name)) return false;
    return !name.split('/').contains('..');
  }

  /// 背景图扩展名（小写、无点；未知/无扩展名回落 jpg）
  static String _imageExtension(String path) {
    final normalized = path.replaceAll('\\', '/');
    final name = normalized.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return 'jpg';
    final ext = name.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]+$').hasMatch(ext) ? ext : 'jpg';
  }

  /// 数值容错：非数值返回 null
  static int? _asNullableInt(dynamic value) =>
      value is int ? value : (value is num ? value.toInt() : null);

  /// 当前 App 版本（读取失败不影响导出）
  /// 当前 App 版本读取器（测试可替换，避免依赖平台插件）
  @visibleForTesting
  static Future<String> Function() appVersionLoader = _loadAppVersion;

  /// 当前 App 版本（读取失败/超时返回空串，不影响导出）
  static Future<String> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 2),
      );
      return info.version;
    } catch (_) {
      return '';
    }
  }
}
