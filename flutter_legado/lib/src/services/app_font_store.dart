// [应用字体入口 | 2026-11-11] 应用界面自定义字体存储/校验/加载 — 全栈工程师
//
// 语义基准（参考版 legado-with-MD3 外观页「字体设置」）：
// - 选择一个字体文件后，整个 App 的界面文字使用该字体（日/夜共用）；
// - 阅读正文的字体是另一套（`reader_font_family` / `FontScreen`），两者
//   必须保持独立，本文件不读写任何 `reader_*` 偏好；
// - 字体文件复制到应用 Support 目录（`app_font/<文件名>`），偏好键
//   [PrefKeys.appFontPath] 存**相对 Support 目录的可迁移标识**，不存绝对
//   路径（iOS 容器 UUID 在重签名/重装后会变化，与
//   `ThemeBackgroundImageStore` 同口径）；
// - 仅接受 ttf / otf / ttc，单文件 ≤10MB；扩展名与文件头魔数/表目录
//   双校验，损坏文件在导入时即拒绝；
// - 加载经 [FontLoader] 注册字体族，失败/超时由调用方回退默认字体，
//   不阻塞启动、不崩溃；
// - 字体文件不纳入备份（`RestoreIgnorePrefs.alwaysIgnoreKeys` 排除偏好），
//   也不在主题背景图/导航图标的孤儿清理扫描范围内，只有用户「清除字体」
//   或成功替换字体时删除自有文件。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';

/// 用户选中的字体文件（字节 + 原始文件名）
class AppFontPick {
  final Uint8List bytes;
  final String name;

  const AppFontPick({required this.bytes, required this.name});
}

/// 字体选择器不可用/读取失败（用户取消返回 null，不抛）
class AppFontPickException implements Exception {
  final String message;

  const AppFontPickException(this.message);

  @override
  String toString() => message;
}

/// 运行时加载结果：成功返回注册的字体族名，失败返回中文提示
class AppFontLoadResult {
  final String? family;
  final String? errorMessage;

  const AppFontLoadResult.success(String this.family) : errorMessage = null;

  const AppFontLoadResult.failure(String this.errorMessage) : family = null;

  bool get isSuccess => family != null;
}

/// 应用字体文件存储/校验/加载
class AppFontStore {
  AppFontStore._();

  /// 相对应用 Support 目录的根子目录
  static const String subDir = 'app_font';

  /// 单文件大小上限（10MB；超限直接拒绝，避免异常大字体拖垮加载）
  static const int maxBytes = 10 * 1024 * 1024;

  /// 允许的字体扩展名（小写、无点）
  static const Set<String> allowedExtensions = <String>{'ttf', 'otf', 'ttc'};

  /// 注册到 Flutter 引擎的字体族名前缀。
  ///
  /// 后缀取**字体内容** md5 前 8 位：换字体（即使沿用同一文件名）后族名
  /// 随之变化，保证新字体立即生效（同一族名重复注册时引擎可能沿用先前
  /// 的字形，无法刷新）；同一文件重启后族名稳定。
  static const String familyPrefix = 'AppCustomFont';

  /// 默认加载超时：超时回退默认字体，不阻塞启动
  static const Duration defaultLoadTimeout = Duration(seconds: 5);

  /// 测试 seam：应用 Support 目录获取（默认 path_provider）
  @visibleForTesting
  static Future<Directory> Function() supportDir =
      getApplicationSupportDirectory;

  /// 测试 seam：字体选择（默认系统 file_picker；返回 null = 用户取消）
  @visibleForTesting
  static Future<AppFontPick?> Function() picker = _pickWithFilePicker;

  /// 测试 seam：字体引擎加载（默认 FontLoader；测试可注入成功/失败/超时）
  @visibleForTesting
  static Future<void> Function(String family, Future<ByteData> bytes)
  engineLoader = _loadWithFontLoader;

  /// 测试 seam：读取字体字节（widget 测试的 FakeAsync 下真实 IO 不推进，
  /// 可注入同步实现；生产保持异步，避免 10MB 文件阻塞 UI 线程）
  @visibleForTesting
  static Future<Uint8List> Function(File file) readBytes = (file) =>
      file.readAsBytes();

  /// 缓存的 Support 绝对路径（供同步 [resolveSync] 使用）
  static String? _supportPath;

  // ===== 文件头常量（大端）=====

  /// TrueType 轮廓（0x00010000）
  static const int _sfntTrueType = 0x00010000;

  /// Apple TrueType（'true'）
  static const int _sfntTrueTypeApple = 0x74727565;

  /// OpenType CFF（'OTTO'）
  static const int _sfntOpenTypeCff = 0x4F54544F;

  /// PostScript Type 1（'typ1'）
  static const int _sfntType1 = 0x74797031;

  /// TrueType Collection（'ttcf'）
  static const int _ttcTag = 0x74746366;

  /// 预热 [resolveSync] 的基目录缓存
  static void warmWith(Directory dir) {
    _supportPath = dir.absolute.path;
  }

  /// 基目录缓存是否已就绪
  static bool get isWarm => _supportPath != null;

  /// 测试隔离：清除基目录缓存（生产不调用）
  @visibleForTesting
  static void resetWarmCache() {
    _supportPath = null;
  }

  /// 确保基目录缓存可用；失败不抛出（解析侧优雅降级）。
  static Future<void> ensureWarm() async {
    if (_supportPath != null) return;
    try {
      warmWith(await supportDir());
    } catch (_) {
      // 基目录不可得：按「未设置/不可用」回落，不阻断任何页面
    }
  }

  /// 从系统文件选择器选择字体；用户取消返回 null，失败抛
  /// [AppFontPickException]（中文提示）。校验失败抛 [FormatException]。
  static Future<AppFontPick?> pick() async {
    if (kIsWeb) {
      throw const AppFontPickException('当前平台不支持自定义应用字体');
    }
    try {
      return await picker();
    } on FormatException {
      rethrow;
    } on AppFontPickException {
      rethrow;
    } catch (e) {
      throw const AppFontPickException('无法打开系统文件选择器，请重试');
    }
  }

  /// 导入字节流：校验 → 落盘 → 写偏好 → 删除旧自有文件，返回相对标识。
  ///
  /// 失败抛 [FormatException]（空/超限/格式/损坏），不留下正式文件。
  static Future<String> importBytes(
    Uint8List bytes, {
    required String originalName,
  }) async {
    if (kIsWeb) throw UnsupportedError('当前平台不支持自定义应用字体');
    if (bytes.isEmpty) throw const FormatException('字体文件为空');
    if (bytes.length > maxBytes) {
      throw FormatException('字体文件过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）');
    }
    final ext = _extensionOf(originalName);
    if (ext == null) {
      throw const FormatException('不支持的字体格式（仅支持 TTF / OTF / TTC）');
    }
    _validateFontBytes(bytes);

    final support = await supportDir();
    final supportPath = support.absolute.path;
    _supportPath = supportPath;
    final sep = Platform.pathSeparator;
    final dirPath = '$supportPath$sep$subDir';
    await Directory(dirPath).create(recursive: true);

    final fileName = _sanitizeFileName(originalName, ext);
    final target = File('$dirPath$sep$fileName');
    final tmp = File(
      '$dirPath$sep.$fileName.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      // Windows 的 rename 不能覆盖已存在文件：先删旧同名文件（仅自有目录内）
      if (target.existsSync()) await target.delete();
      await tmp.rename(target.path);
    } catch (e) {
      await _safeDelete(tmp);
      rethrow;
    }

    final id = '$subDir/$fileName';
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(PrefKeys.appFontPath);
    try {
      await prefs.setString(PrefKeys.appFontPath, id);
    } catch (e) {
      // 偏好写入失败：本次落盘无引用，删除避免孤儿文件
      await _safeDelete(target);
      rethrow;
    }
    if (previous != null && previous.isNotEmpty && previous != id) {
      await deleteOwned(previous);
    }
    return id;
  }

  /// 导入本地文件路径（桌面/iOS file_picker 返回 path 时使用）
  static Future<String> importFile(String sourcePath) async {
    final file = File(sourcePath);
    final bytes = await file.readAsBytes();
    return importBytes(bytes, originalName: _baseName(sourcePath));
  }

  /// 读取当前偏好中的相对标识（空/未设置返回 null）
  static Future<String?> readStoredIdentifier() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(PrefKeys.appFontPath)?.trim();
      return (stored == null || stored.isEmpty) ? null : stored;
    } catch (_) {
      return null;
    }
  }

  /// 同步：把偏好值解析为真实文件路径（相对标识拼当前 Support 目录；
  /// 绝对路径原样透传，兼容旧备份/参考版存量值）。
  static String resolveSync(String stored) {
    if (stored.isEmpty) return '';
    if (stored.startsWith('/')) return stored;
    if (File(stored).isAbsolute) return stored;
    final root = _supportPath;
    if (root == null) return stored;
    return '$root${Platform.pathSeparator}'
        '${stored.replaceAll('/', Platform.pathSeparator)}';
  }

  /// 同步：偏好值对应的字体当前是否可用（存在、非空、≤上限、文件头有效）
  static bool isUsableSync(String stored) {
    if (stored.isEmpty) return false;
    final resolved = resolveSync(stored);
    if (resolved.isEmpty) return false;
    if (_hasParentSegment(resolved)) return false;
    try {
      final file = File(resolved);
      if (!file.existsSync()) return false;
      final length = file.lengthSync();
      if (length <= 0 || length > maxBytes) return false;
      return _hasValidHeaderSync(file, length);
    } catch (_) {
      return false;
    }
  }

  /// 异步：返回可加载的字体绝对路径；不存在或损坏返回 null。
  static Future<String?> loadablePath(String stored) async {
    if (!isUsableSync(stored)) return null;
    final path = resolveSync(stored);
    try {
      _validateFontBytes(await File(path).readAsBytes());
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 偏好值对应的显示文件名（不做可用性判断）
  static String displayNameOf(String stored) => _baseName(stored);

  /// 删除自有字体文件并清除偏好；文件不存在/删除失败静默（偏好仍清除）
  static Future<void> clear({String? stored}) async {
    String? target = stored;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      target ??= prefs.getString(PrefKeys.appFontPath);
    } catch (_) {
      // prefs 不可用：仍尝试删除传入的文件（如有）
    }
    if (target != null && target.isNotEmpty) {
      await deleteOwned(target);
    }
    try {
      await prefs?.remove(PrefKeys.appFontPath);
    } catch (_) {
      // 偏好清除失败不影响文件已删除；下次启动 isUsableSync=false
    }
  }

  /// 删除自有字体文件；只处理 Support 目录内 `app_font/` 下的路径，
  /// 外部/参考版路径不动（防误删用户其它文件）。
  static Future<bool> deleteOwned(String stored) async {
    if (stored.isEmpty || kIsWeb) return false;
    await ensureWarm();
    final root = _supportPath;
    if (root == null) return false;
    final resolved = resolveSync(stored);
    if (resolved.isEmpty) return false;
    if (_hasParentSegment(resolved)) return false;
    final owned = resolved.startsWith(
      '$root${Platform.pathSeparator}$subDir${Platform.pathSeparator}',
    );
    if (!owned) return false;
    try {
      final file = File(resolved);
      if (!file.existsSync()) return false;
      // 同步删除：删除是即时操作，且避免 widget 测试 FakeAsync 下
      // 真实异步 IO 不推进导致「清除字体」悬挂
      file.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 字体族名（`AppCustomFont_<字体内容 md5 前8位>`）
  static String familyForBytes(Uint8List bytes) {
    final digest = md5.convert(bytes).toString();
    return '${familyPrefix}_${digest.substring(0, 8)}';
  }

  /// 读取偏好中的字体并注册到引擎。
  ///
  /// 成功返回字体族名；失败返回中文提示。总耗时受 [timeout] 约束，
  /// 超时/异常不抛出（调用方回退默认字体）。
  static Future<AppFontLoadResult> load(
    String stored, {
    Duration timeout = defaultLoadTimeout,
  }) async {
    if (stored.isEmpty) {
      return const AppFontLoadResult.failure('未设置应用字体');
    }
    await ensureWarm();
    final path = resolveSync(stored);
    if (path.isEmpty) {
      return const AppFontLoadResult.failure('自定义字体文件缺失，已回退默认字体');
    }
    final file = File(path);
    if (!file.existsSync()) {
      return const AppFontLoadResult.failure('自定义字体文件缺失，已回退默认字体');
    }
    Uint8List bytes;
    try {
      bytes = await readBytes(file);
      _validateFontBytes(bytes);
    } on FormatException catch (e) {
      return AppFontLoadResult.failure(_withFallbackHint(e.message));
    } catch (_) {
      return const AppFontLoadResult.failure('自定义字体读取失败，已回退默认字体');
    }
    final family = familyForBytes(bytes);
    try {
      final data = Future<ByteData>.value(ByteData.sublistView(bytes));
      await engineLoader(family, data).timeout(timeout);
      return AppFontLoadResult.success(family);
    } on TimeoutException {
      return const AppFontLoadResult.failure('自定义字体加载超时，已回退默认字体');
    } on FormatException catch (e) {
      return AppFontLoadResult.failure(_withFallbackHint(e.message));
    } catch (_) {
      return const AppFontLoadResult.failure('自定义字体加载失败，已回退默认字体');
    }
  }

  // ===== 内部实现 =====

  static Future<AppFontPick?> _pickWithFilePicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions.toList(growable: false),
      dialogTitle: '选择字体文件',
      allowCompression: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.single;
    if (picked.size > maxBytes) {
      throw FormatException('字体文件过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）');
    }
    final bytes =
        picked.bytes ??
        (picked.path != null ? await File(picked.path!).readAsBytes() : null);
    if (bytes == null) {
      throw const FormatException('无法读取所选字体文件');
    }
    return AppFontPick(bytes: bytes, name: picked.name);
  }

  static Future<void> _loadWithFontLoader(
    String family,
    Future<ByteData> bytes,
  ) {
    final loader = FontLoader(family)..addFont(bytes);
    return loader.load();
  }

  /// 加载失败提示统一带「已回退默认字体」，避免只报格式错误让用户
  /// 误以为界面仍在使用自定义字体。
  static String _withFallbackHint(String message) =>
      message.contains('默认字体') ? message : '$message，已回退默认字体';

  /// 扩展名白名单校验；不在白名单返回 null
  static String? _extensionOf(String path) {
    final name = _baseName(path);
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    final ext = name.substring(dot + 1).toLowerCase();
    return allowedExtensions.contains(ext) ? ext : null;
  }

  /// 文件名校验/归一：去掉路径与控制字符，保留 Unicode 文件名；
  /// 确保以白名单扩展名结尾，长度上限 100 字符（避免路径过长）。
  static String _sanitizeFileName(String originalName, String ext) {
    var name = _baseName(
      originalName,
    ).replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_').trim();
    name = name.replaceFirst(RegExp(r'^\.+'), '');
    if (name.isEmpty) name = 'app_font';
    if (!name.toLowerCase().endsWith('.$ext')) {
      final dot = name.lastIndexOf('.');
      if (dot > 0) name = name.substring(0, dot);
      name = '$name.$ext';
    }
    if (name.length > 100) {
      final suffix = '.$ext';
      name = '${name.substring(0, 100 - suffix.length)}$suffix';
    }
    return name;
  }

  /// 校验字体文件：扩展名已在上层校验，这里按文件头 + 表目录判断。
  static void _validateFontBytes(Uint8List bytes) {
    if (bytes.isEmpty) throw const FormatException('字体文件为空');
    if (bytes.length < 12) {
      throw const FormatException('字体文件内容无效或已损坏');
    }
    final tag = _u32(bytes, 0);
    if (tag == _ttcTag) {
      final numFonts = _u32(bytes, 8);
      if (numFonts <= 0 || numFonts > 1024) {
        throw const FormatException('字体集合（TTC）内容无效或已损坏');
      }
      if (bytes.length < 12 + 4 * numFonts) {
        throw const FormatException('字体文件内容无效或已损坏');
      }
      for (var i = 0; i < numFonts; i++) {
        final offset = _u32(bytes, 12 + 4 * i);
        if (!_validateSfntAt(bytes, offset)) {
          throw const FormatException('字体文件内容无效或已损坏');
        }
      }
      return;
    }
    if (!_isKnownSfntTag(tag)) {
      throw const FormatException('不是有效的 TTF / OTF / TTC 字体文件');
    }
    if (!_validateSfntAt(bytes, 0)) {
      throw const FormatException('字体文件内容无效或已损坏');
    }
  }

  static bool _isKnownSfntTag(int tag) =>
      tag == _sfntTrueType ||
      tag == _sfntTrueTypeApple ||
      tag == _sfntOpenTypeCff ||
      tag == _sfntType1;

  /// 校验单个 sfnt 字体的表目录（TTC 成员 offset 为文件内绝对偏移）
  static bool _validateSfntAt(Uint8List bytes, int offset) {
    if (offset < 0 || offset + 12 > bytes.length) return false;
    final numTables = _u16(bytes, offset + 4);
    if (numTables <= 0 || numTables > 4096) return false;
    final dirEnd = offset + 12 + numTables * 16;
    if (dirEnd > bytes.length) return false;
    for (var i = 0; i < numTables; i++) {
      final record = offset + 12 + i * 16;
      final tableOffset = _u32(bytes, record + 8);
      final tableLength = _u32(bytes, record + 12);
      if (tableOffset > bytes.length) return false;
      if (tableLength > bytes.length - tableOffset) return false;
    }
    return true;
  }

  /// 同步轻量校验文件头/表目录长度（不读取整文件）
  static bool _hasValidHeaderSync(File file, int length) {
    RandomAccessFile? raf;
    try {
      raf = file.openSync();
      final headLength = length < 12 ? length : 12;
      final head = raf.readSync(headLength);
      if (head.length < 12) return false;
      final tag = _u32(head, 0);
      if (tag == _ttcTag) {
        final numFonts = _u32(head, 8);
        if (numFonts <= 0 || numFonts > 1024) return false;
        return length >= 12 + 4 * numFonts;
      }
      if (!_isKnownSfntTag(tag)) return false;
      final numTables = _u16(head, 4);
      if (numTables <= 0 || numTables > 4096) return false;
      return length >= 12 + numTables * 16;
    } catch (_) {
      return false;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {
        // 忽略关闭异常
      }
    }
  }

  static int _u16(Uint8List bytes, int offset) =>
      (bytes[offset] << 8) | bytes[offset + 1];

  static int _u32(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  static bool _hasParentSegment(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.split('/').contains('..');
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清理失败不影响主流程
    }
  }
}
