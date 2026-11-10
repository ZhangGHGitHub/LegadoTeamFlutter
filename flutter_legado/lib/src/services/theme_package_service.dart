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
// 安全口径：EOCD 预检条目数；逐条限长流式解压（单条 ≤ 32MB、总量 ≤ 512MB，
// 超限立即中止，不等待整条解压完成）；拒绝含 `..`、绝对路径、反斜杠、NUL
// 的条目名与符号链接条目；拒绝 0 字节 zip。所有失败以
// [ThemePackageException] 抛出中文原因，调用方直接展示。
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
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

/// 解压预算（跨条目累计实际写出字节）
class _EntryBudget {
  int used = 0;
}

/// 限长输出流：写入时立即校验单条/总量，超限抛中文异常中止解压
class _BoundedOutputStream extends OutputStream {
  _BoundedOutputStream({
    required this.entryName,
    required this.maxEntryBytes,
    required this.maxTotalBytes,
    required this.retain,
  }) : super(byteOrder: ByteOrder.littleEndian);

  final String entryName;
  final int maxEntryBytes;
  final int maxTotalBytes;
  final bool retain;
  final BytesBuilder _bytes = BytesBuilder(copy: true);
  int _length = 0;

  @override
  int get length => _length;

  @override
  void clear() {
    _length = 0;
    _bytes.clear();
  }

  @override
  void flush() {}

  void _reserve(int count) {
    final next = _length + count;
    if (next > maxEntryBytes) {
      throw ThemePackageException('主题包条目过大：$entryName（上限 32MB）');
    }
    if (next > maxTotalBytes) {
      throw const ThemePackageException('主题包内容过大（上限 512MB）');
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    if (retain) _bytes.addByte(value);
    _length++;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = min(length ?? bytes.length, bytes.length);
    if (count <= 0) return;
    _reserve(count);
    if (retain) {
      _bytes.add(
        bytes is Uint8List
            ? Uint8List.sublistView(bytes, 0, count)
            : bytes.sublist(0, count),
      );
    }
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      // archive 4.0.9 的 InputStream.length 语义是「剩余可读字节」
      //（InputMemoryStream: buffer.length - position；
      //  InputFileStream: fileRemaining），不能再减 position。
      final remaining = stream.length;
      if (remaining <= 0) break;
      final take = min(remaining, 8192);
      writeBytes(stream.readBytes(take).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) {
    if (!retain) return Uint8List(0);
    final all = _bytes.toBytes();
    final stop = end ?? all.length;
    if (start < 0 || start >= stop || stop > all.length) return Uint8List(0);
    return Uint8List.sublistView(all, start, stop);
  }

  @override
  Uint8List getBytes() => retain ? _bytes.toBytes() : Uint8List(0);
}

/// App 主题包 zip 编解码
abstract final class ThemePackageService {
  ThemePackageService._();

  /// 当前支持的清单版本
  static const int formatVersion = 1;

  /// zip 条目数上限
  static const int maxEntries = 4096;

  /// 单条解压后大小上限（32MB；与 ThemeBackgroundImageStore.maxBytes 一致）
  static const int maxEntryBytes = 32 * 1024 * 1024;

  /// 解压总量上限（512MB）
  static const int maxTotalBytes = 512 * 1024 * 1024;

  /// 中央目录大小上限（4MB）：主题包只有清单+两张图，远小于该值；
  /// 防止伪造 entries=0 + 巨型中央目录先构造百万 Header 对象。
  static const int maxCentralDirectoryBytes = 4 * 1024 * 1024;

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

  /// 解析主题包（EOCD 预检 + 限长流式解压 + 清单校验）
  ///
  /// 所有底层异常（archive 解析、文件 IO、解压）统一转换为
  /// [ThemePackageException] 中文提示，不把英文异常抛给界面。
  static Future<ThemePackageData> importThemePackage(File zip) async {
    try {
      return await _importThemePackage(zip);
    } on ThemePackageException {
      rethrow;
    } on FileSystemException catch (e) {
      throw ThemePackageException('无法读取主题包：${e.message}');
    } catch (_) {
      throw const ThemePackageException('无法读取主题包（文件格式不正确）');
    }
  }

  static Future<ThemePackageData> _importThemePackage(File zip) async {
    final fileLength = await zip.length();
    if (fileLength <= 0) {
      throw const ThemePackageException('主题包文件为空');
    }
    if (fileLength > maxTotalBytes) {
      throw const ThemePackageException('主题包文件过大（上限 512MB）');
    }
    // 解压前先读 EOCD：条目数与中央目录大小可伪造，但先挡住明显超限包，
    // 避免为 5000+ 条目/超大目录做完整解析。
    await _validateEocd(zip, fileLength);

    final input = InputFileStream(zip.path);
    try {
      final directory = ZipDirectory();
      directory.read(input);
      if (directory.filePosition < 0) {
        throw const ThemePackageException('无法读取主题包（文件格式不正确）');
      }
      // zip64 可能把 EOCD 的 0xFFFF/0xFFFFFFFF 覆盖为真实值，解析后再复检
      if (directory.numberOfThisDisk != 0 ||
          directory.diskWithTheStartOfTheCentralDirectory != 0) {
        throw const ThemePackageException('不支持分卷主题包');
      }
      if (directory.centralDirectorySize > maxCentralDirectoryBytes) {
        throw const ThemePackageException('主题包清单过大（上限 4MB）');
      }
      if (directory.totalCentralDirectoryEntries > maxEntries ||
          directory.fileHeaders.length > maxEntries) {
        throw const ThemePackageException('主题包条目过多（上限 4096）');
      }

      final headers = <String, ZipFileHeader>{};
      var declaredTotal = 0;
      for (final header in directory.fileHeaders) {
        final entryName = header.filename;
        if (!_isSafeEntryName(entryName)) {
          throw ThemePackageException('主题包包含非法路径：$entryName');
        }
        final fileType = (header.externalFileAttributes >> 16) & 0xf000;
        if (fileType == 0xa000) {
          throw ThemePackageException('主题包包含符号链接条目：$entryName');
        }
        if ((header.generalPurposeBitFlag & 0x1) != 0) {
          throw ThemePackageException('主题包包含加密条目：$entryName');
        }
        if (entryName.endsWith('/') || fileType == 0x4000) continue;

        // 中央目录声明大小只用于提前拒绝；真正解压仍按实际写出字节限长。
        if (header.uncompressedSize > maxEntryBytes) {
          throw ThemePackageException('主题包条目过大：$entryName（上限 32MB）');
        }
        declaredTotal += header.uncompressedSize;
        if (declaredTotal > maxTotalBytes) {
          throw const ThemePackageException('主题包内容过大（上限 512MB）');
        }
        final file = header.file;
        if (file == null) {
          throw ThemePackageException('无法读取主题包（$entryName 头部损坏）');
        }
        if (header.compressionMethod != 0 &&
            header.compressionMethod != 8 &&
            header.compressionMethod != 12) {
          throw ThemePackageException('主题包压缩方式不支持：$entryName');
        }
        headers[entryName] = header;
      }

      final manifestHeader = headers['manifest.json'];
      if (manifestHeader == null) {
        throw const ThemePackageException('主题包清单不完整');
      }
      final budget = _EntryBudget();
      final manifest = _decodeManifest(
        _extractEntry(manifestHeader, budget, retain: true),
      );

      final version = _asNullableInt(manifest['formatVersion']);
      if (version != formatVersion) {
        throw ThemePackageException('不支持的主题包版本: ${version ?? '未知'}');
      }
      final config = manifest['config'];
      if (config is! Map<String, dynamic>) {
        throw const ThemePackageException('主题包清单不完整');
      }
      final colorsRaw = config['colors'];
      if (colorsRaw is! Map<String, dynamic>) {
        throw const ThemePackageException('主题包清单不完整');
      }

      final lightPath = _resolveBackgroundPath(manifest, headers.keys, 'light');
      final darkPath = _resolveBackgroundPath(manifest, headers.keys, 'dark');
      Uint8List? lightBytes;
      Uint8List? darkBytes;
      for (final header in directory.fileHeaders) {
        final entryName = header.filename;
        final fileType = (header.externalFileAttributes >> 16) & 0xf000;
        if (entryName == 'manifest.json' ||
            entryName.endsWith('/') ||
            fileType == 0x4000) {
          continue;
        }
        final retain = entryName == lightPath || entryName == darkPath;
        // 未知资源也解压计数（总量限制覆盖整个包），但不保留字节。
        final bytes = _extractEntry(header, budget, retain: retain);
        if (retain) {
          if (entryName == lightPath) lightBytes = bytes;
          if (entryName == darkPath) darkBytes = bytes;
        }
      }

      return ThemePackageData(
        name: _normalizeName(manifest['name']),
        isNight: config['isNight'] == true,
        paletteId: _asNullableInt(config['paletteId']),
        colors: _decodeColors(colorsRaw),
        backgroundLight: lightBytes == null || lightBytes.isEmpty
            ? null
            : lightBytes,
        backgroundDark: darkBytes == null || darkBytes.isEmpty
            ? null
            : darkBytes,
        backgroundLightName: lightBytes == null || lightBytes.isEmpty
            ? null
            : lightPath,
        backgroundDarkName: darkBytes == null || darkBytes.isEmpty
            ? null
            : darkPath,
        appVersion: manifest['appVersion'] is String
            ? manifest['appVersion'] as String
            : '',
      );
    } finally {
      input.closeSync();
    }
  }

  /// EOCD 预检：拒绝 0 字节/非 zip/分卷/条目超限/中央目录越界
  static Future<void> _validateEocd(File zip, int fileLength) async {
    final raf = await zip.open();
    try {
      final tailLength = min(fileLength, 22 + 0xffff);
      await raf.setPosition(fileLength - tailLength);
      final tail = await raf.read(tailLength);
      if (tail.length < 22) {
        throw const ThemePackageException('无法读取主题包（文件格式不正确）');
      }
      var index = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 &&
            tail[i + 1] == 0x4b &&
            tail[i + 2] == 0x05 &&
            tail[i + 3] == 0x06) {
          index = i;
          break;
        }
      }
      if (index < 0) {
        throw const ThemePackageException('无法读取主题包（文件格式不正确）');
      }
      int u16(int offset) =>
          tail[index + offset] | (tail[index + offset + 1] << 8);
      int u32(int offset) =>
          tail[index + offset] |
          (tail[index + offset + 1] << 8) |
          (tail[index + offset + 2] << 16) |
          (tail[index + offset + 3] << 24);

      if (u16(4) != 0 || u16(6) != 0) {
        throw const ThemePackageException('不支持分卷主题包');
      }
      final entries = u16(10);
      final centralDirectorySize = u32(12);
      final centralDirectoryOffset = u32(16);
      if (entries != 0xffff && entries > maxEntries) {
        throw const ThemePackageException('主题包条目过多（上限 4096）');
      }
      if (centralDirectorySize != 0xffffffff) {
        if (centralDirectorySize > maxCentralDirectoryBytes) {
          throw const ThemePackageException('主题包清单过大（上限 4MB）');
        }
        if (centralDirectorySize > maxTotalBytes) {
          throw const ThemePackageException('主题包内容过大（上限 512MB）');
        }
        if (centralDirectoryOffset != 0xffffffff &&
            centralDirectoryOffset + centralDirectorySize > fileLength) {
          throw const ThemePackageException('无法读取主题包（文件格式不正确）');
        }
      }
    } finally {
      await raf.close();
    }
  }

  static Map<String, dynamic> _decodeManifest(Uint8List bytes) {
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      throw const ThemePackageException('主题包清单不完整');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ThemePackageException('主题包清单不完整');
    }
    return decoded;
  }

  /// 限长流式解压单条；[retain] 为 false 时只计数不保留字节
  static Uint8List _extractEntry(
    ZipFileHeader header,
    _EntryBudget budget, {
    required bool retain,
  }) {
    final file = header.file;
    if (file == null) {
      throw ThemePackageException('无法读取主题包（${header.filename} 头部损坏）');
    }
    final sink = _BoundedOutputStream(
      entryName: header.filename,
      maxEntryBytes: maxEntryBytes,
      maxTotalBytes: maxTotalBytes - budget.used,
      retain: retain,
    );
    try {
      file.decompress(sink);
    } on ThemePackageException {
      rethrow;
    } catch (_) {
      throw ThemePackageException('无法读取主题包（${header.filename} 解压失败）');
    }
    budget.used += sink.length;
    return sink.getBytes();
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
      throw const ThemePackageException('背景图片过大（上限 32MB）');
    }
    final bytes = await file.readAsBytes();
    return ('$entryPrefix.${_imageExtension(file.path)}', bytes);
  }

  /// 清单引用的背景图条目名；引用非法抛错，引用缺失时尝试按固定路径发现
  static String? _resolveBackgroundPath(
    Map<String, dynamic> manifest,
    Iterable<String> entryNames,
    String side,
  ) {
    final assets = manifest['assets'];
    Map<String, dynamic>? background;
    if (assets is Map<String, dynamic>) {
      final raw = assets['background'];
      if (raw is Map<String, dynamic>) background = raw;
    }
    final available = entryNames.toSet();
    final referenced = background?[side];
    String? path;
    if (referenced is String && referenced.trim().isNotEmpty) {
      path = referenced.trim();
      if (!_isSafeEntryName(path) || !path.startsWith('assets/background/')) {
        throw ThemePackageException('主题包包含非法路径：$path');
      }
      return available.contains(path) ? path : null;
    }
    // 清单未声明时按固定命名发现（兼容手工打包/精简清单）
    final prefix = 'assets/background/$side.';
    final candidates =
        available.where((name) => name.startsWith(prefix)).toList()..sort();
    return candidates.isEmpty ? null : candidates.first;
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
