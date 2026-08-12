import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';
import 'bottom_bar_skin_format.dart';

/// ??????????
class BottomBarSkinIcons {
  const BottomBarSkinIcons({this.normal, this.selected});

  final String? normal;
  final String? selected;
}

/// ???????? / ???
class BottomBarSkinPrefill {
  const BottomBarSkinPrefill({this.selected, this.normal});

  final File? selected;
  final File? normal;
}

/// ??????????????
class BottomBarSkinSlotAssign {
  const BottomBarSkinSlotAssign({required this.selected, this.normal});

  final File selected;
  final File? normal;
}

/// ??????????? BottomBarSkinManager?
///
/// ??????? zip ? ?? session ? Assign ????????? zip ?????
class BottomBarSkinService {
  BottomBarSkinService._();
  static final instance = BottomBarSkinService._();

  static const _maxArchiveBytes = 16 * 1024 * 1024;
  static const _maxEntryBytes = 8 * 1024 * 1024;
  static const _maxTotalBytes = 32 * 1024 * 1024;
  static const _maxEntries = 64;
  static const _sessionDirName = '.staging';
  static const _sessionMaxAgeMs = 24 * 60 * 60 * 1000;

  Directory? _root;
  final _random = Random();

  Future<Directory> _rootDir() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}bottomBarSkins');
    if (!await dir.exists()) await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  Future<Directory> _sessionRoot() async {
    final root = await _rootDir();
    final dir = Directory(
      '${root.path}${Platform.pathSeparator}$_sessionDirName',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<List<String>> list() async {
    final root = await _rootDir();
    final names = <String>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final basename = entity.path.split(Platform.pathSeparator).last;
      if (basename.startsWith('.')) continue;
      if (BottomBarSkinFormat.isValidSkinName(basename)) {
        names.add(basename);
      }
    }
    names.sort();
    return names;
  }

  Future<String> getActive() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(PrefKeys.bottomBarSkin) ?? '';
    if (name.isEmpty) return '';
    if (!await hasSkin(name)) return '';
    return name;
  }

  Future<void> setActive(String name) async {
    final prefs = await SharedPreferences.getInstance();
    if (name.isEmpty) {
      await prefs.setString(PrefKeys.bottomBarSkin, '');
      return;
    }
    if (!await hasSkin(name)) return;
    await prefs.setString(PrefKeys.bottomBarSkin, name);
  }

  Future<bool> hasSkin(String name) async {
    if (!BottomBarSkinFormat.isValidSkinName(name)) return false;
    final dir = Directory(
      '${(await _rootDir()).path}${Platform.pathSeparator}$name',
    );
    return dir.existsSync();
  }

  Future<bool> delete(String name) async {
    if (!await hasSkin(name)) return false;
    final active = await getActive();
    final dir = Directory(
      '${(await _rootDir()).path}${Platform.pathSeparator}$name',
    );
    try {
      await dir.delete(recursive: true);
      if (active == name) await setActive('');
      return true;
    } catch (e) {
      debugPrint('BottomBarSkinService.delete exception: $e');
      return false;
    }
  }

  /// ?? zip ???????? sessionId??? extractImages?
  Future<String> extractZipToSession(File zipFile) async {
    final bytes = await zipFile.readAsBytes();
    if (bytes.length > _maxArchiveBytes) {
      throw StateError('archive too large');
    }
    final session = await _createSessionDir();
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final used = <String>{};
      var entryCount = 0;
      var totalBytes = 0;
      var wrote = 0;

      for (final entry in archive) {
        entryCount++;
        if (entryCount > _maxEntries) throw StateError('too many zip entries');
        if (entry.isDirectory) continue;
        final imageName = BottomBarSkinFormat.sanitizeImageName(entry.name);
        if (imageName == null) continue;
        final data = entry.content;
        if (data.length > _maxEntryBytes) throw StateError('zip entry too large');
        totalBytes += data.length;
        if (totalBytes > _maxTotalBytes) throw StateError('zip content too large');
        final unique = BottomBarSkinFormat.uniqueImageName(imageName, used);
        await File('${session.path}${Platform.pathSeparator}$unique')
            .writeAsBytes(data, flush: true);
        wrote++;
      }
      if (wrote == 0) throw StateError('no images in zip');
      return session.path.split(Platform.pathSeparator).last;
    } catch (e) {
      await _safeDelete(session);
      rethrow;
    }
  }

  /// ??????????????
  Future<String> stageExisting(String skinName) async {
    if (!await hasSkin(skinName)) throw StateError('skin not found');
    final source = Directory(
      '${(await _rootDir()).path}${Platform.pathSeparator}$skinName',
    );
    final session = await _createSessionDir();
    try {
      var totalBytes = 0;
      await for (final entity in source.list()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!BottomBarSkinFormat.isImageName(name)) continue;
        final len = await entity.length();
        if (len <= 0 || len > _maxEntryBytes) {
          throw StateError('invalid image');
        }
        totalBytes += len;
        if (totalBytes > _maxTotalBytes) throw StateError('skin too large');
        await entity.copy(
          '${session.path}${Platform.pathSeparator}$name',
        );
      }
      final imgs =
          await stagingImages(session.path.split(Platform.pathSeparator).last);
      if (imgs.isEmpty) throw StateError('no images');
      return session.path.split(Platform.pathSeparator).last;
    } catch (e) {
      await _safeDelete(session);
      rethrow;
    }
  }

  Future<List<File>> stagingImages(String sessionId) async {
    final session = await _resolveSessionDir(sessionId);
    if (session == null) return const [];
    final files = <File>[];
    await for (final entity in session.list()) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!BottomBarSkinFormat.isImageName(name)) continue;
      final len = await entity.length();
      if (len <= 0 || len > _maxEntryBytes) continue;
      files.add(entity);
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<void> discardSession(String sessionId) async {
    final session = await _resolveSessionDir(sessionId);
    if (session != null) await _safeDelete(session);
  }

  /// ????????????? buildPrefill?
  static Map<String, BottomBarSkinPrefill> buildPrefill(List<File> images) {
    final selected = <String, File>{};
    final normal = <String, File>{};
    for (final file in images) {
      final name = file.path.split(Platform.pathSeparator).last;
      final parsed = BottomBarSkinFormat.parseEntryName(name);
      if (parsed == null) continue;
      if (parsed.selected) {
        selected.putIfAbsent(parsed.slot, () => file);
      } else {
        normal.putIfAbsent(parsed.slot, () => file);
      }
    }
    final keys = {...selected.keys, ...normal.keys};
    return {
      for (final slot in keys)
        slot: BottomBarSkinPrefill(
          selected: selected[slot],
          normal: normal[slot],
        ),
    };
  }

  /// ???????????? saveSkin?
  Future<String> saveFromAssign({
    required String desiredName,
    required Map<String, BottomBarSkinSlotAssign> assigns,
    required String sessionId,
    String? editName,
  }) async {
    if (assigns.isEmpty) throw StateError('no assignment');
    if (!assigns.keys.every(BottomBarSkinFormat.mappedSlots.contains)) {
      throw StateError('invalid slot');
    }
    final session = await _resolveSessionDir(sessionId);
    if (session == null) throw StateError('staging session not found');

    final currentNames = await list();
    final sanitized = BottomBarSkinFormat.sanitize(desiredName);
    if (editName != null && !await hasSkin(editName)) {
      throw StateError('skin not found');
    }
    final finalName = editName == null
        ? BottomBarSkinFormat.uniqueName(sanitized, currentNames)
        : (sanitized == editName
            ? editName
            : BottomBarSkinFormat.uniqueName(
                sanitized,
                currentNames.where((n) => n != editName),
              ));

    final root = await _rootDir();
    final target = Directory('${root.path}${Platform.pathSeparator}$finalName');
    final temp = Directory(
      '${root.path}${Platform.pathSeparator}.save-${_newId()}',
    );
    await temp.create(recursive: true);
    try {
      for (final e in assigns.entries) {
        final slot = e.key;
        final assign = e.value;
        await _requireSessionFile(session, assign.selected);
        final selExt = _extOf(assign.selected);
        await assign.selected.copy(
          '${temp.path}${Platform.pathSeparator}${slot}_selected.$selExt',
        );
        if (assign.normal != null) {
          await _requireSessionFile(session, assign.normal!);
          final nExt = _extOf(assign.normal!);
          await assign.normal!.copy(
            '${temp.path}${Platform.pathSeparator}${slot}_normal.$nExt',
          );
        }
      }

      if (editName != null && editName != finalName) {
        if (await target.exists()) throw StateError('skin already exists');
        await temp.rename(target.path);
        final wasActive = (await getActive()) == editName;
        final old = Directory('${root.path}${Platform.pathSeparator}$editName');
        await old.delete(recursive: true);
        if (wasActive) await setActive(finalName);
      } else if (editName != null && editName == finalName) {
        if (await target.exists()) {
          await target.delete(recursive: true);
        }
        await temp.rename(target.path);
        await setActive(finalName);
      } else {
        if (await target.exists()) {
          await target.delete(recursive: true);
        }
        await temp.rename(target.path);
        await setActive(finalName);
      }

      await discardSession(sessionId);
      return finalName;
    } catch (e) {
      if (await temp.exists()) await _safeDelete(temp);
      rethrow;
    }
  }

  /// ?????????? zip ??????? / ? UI ???
  Future<String> importZip(File zipFile, {String? preferredName}) async {
    final sessionId = await extractZipToSession(zipFile);
    try {
      final images = await stagingImages(sessionId);
      final prefill = buildPrefill(images);
      final assigns = <String, BottomBarSkinSlotAssign>{};
      for (final e in prefill.entries) {
        final sel = e.value.selected;
        if (sel != null) {
          assigns[e.key] = BottomBarSkinSlotAssign(
            selected: sel,
            normal: e.value.normal,
          );
        }
      }
      if (assigns.isEmpty) {
        throw StateError(
          'no slot images (need bookshelf/home/notes/settings _selected/_normal)',
        );
      }
      final baseName = preferredName?.isNotEmpty == true
          ? preferredName!
          : zipFile.uri.pathSegments.last.replaceAll(
              RegExp(r'\.zip$', caseSensitive: false),
              '',
            );
      return await saveFromAssign(
        desiredName: baseName,
        assigns: assigns,
        sessionId: sessionId,
      );
    } catch (e) {
      await discardSession(sessionId);
      rethrow;
    }
  }

  /// 导出图集为 zip 字节（对齐 BottomBarSkinManager.buildZipBytes）
  Future<List<int>> buildZipBytes(String skinName) async {
    if (!await hasSkin(skinName)) throw StateError('skin not found');
    final files = await _canonicalSkinFiles(skinName);
    if (files.isEmpty) throw StateError('empty skin');
    var total = 0;
    for (final f in files) {
      final len = await f.length();
      if (len <= 0 || len > _maxEntryBytes) {
        throw StateError('invalid image size');
      }
      total += len;
      if (total > _maxTotalBytes) throw StateError('skin too large');
    }
    final archive = Archive();
    for (final f in files) {
      final name = f.path.split(Platform.pathSeparator).last;
      final data = await f.readAsBytes();
      archive.addFile(ArchiveFile(name, data.length, data));
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded.length > _maxArchiveBytes) {
      throw StateError('skin zip too large');
    }
    return encoded;
  }

  /// 写入缓存供分享（对齐 BottomBarSkinManager.cacheShareZip）
  Future<File> cacheShareZip(String skinName) async {
    final bytes = await buildZipBytes(skinName);
    final cache = await getTemporaryDirectory();
    final root = Directory(
      '${cache.path}${Platform.pathSeparator}bottomBarSkinShare',
    );
    if (!await root.exists()) await root.create(recursive: true);
    await _cleanupStaleShareDirs(root);
    final dir = Directory('${root.path}${Platform.pathSeparator}${_newId()}');
    await dir.create(recursive: true);
    try {
      final file = File(
        '${dir.path}${Platform.pathSeparator}bottom-bar-skin.zip',
      );
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (e) {
      await _safeDelete(dir);
      rethrow;
    }
  }

  /// 槽位图标路径（selected/normal）
  Future<BottomBarSkinIcons> iconsForSlot(String skinName, String slot) async {
    if (!BottomBarSkinFormat.mappedSlots.contains(slot)) {
      return const BottomBarSkinIcons();
    }
    if (!await hasSkin(skinName)) return const BottomBarSkinIcons();
    final dir =
        '${(await _rootDir()).path}${Platform.pathSeparator}$skinName';
    String? selected;
    String? normal;
    for (final ext in BottomBarSkinFormat.imageExts) {
      final s = File('$dir${Platform.pathSeparator}${slot}_selected.$ext');
      final n = File('$dir${Platform.pathSeparator}${slot}_normal.$ext');
      if (selected == null && await s.exists()) selected = s.path;
      if (normal == null && await n.exists()) normal = n.path;
    }
    return BottomBarSkinIcons(normal: normal, selected: selected);
  }

  /// 槽位规范文件（任意允许扩展名；原版导出仅 .png）
  Future<List<File>> _canonicalSkinFiles(String skinName) async {
    final dir = Directory(
      '${(await _rootDir()).path}${Platform.pathSeparator}$skinName',
    );
    final out = <File>[];
    for (final slot in BottomBarSkinFormat.mappedSlots) {
      for (final kind in ['selected', 'normal']) {
        for (final ext in BottomBarSkinFormat.imageExts) {
          final f = File(
            '${dir.path}${Platform.pathSeparator}${slot}_$kind.$ext',
          );
          if (await f.exists()) {
            out.add(f);
            break;
          }
        }
      }
    }
    return out;
  }

  Future<void> _cleanupStaleShareDirs(Directory root) async {
    final cutoff = DateTime.now().millisecondsSinceEpoch - _sessionMaxAgeMs;
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final stat = await entity.stat();
      if (stat.modified.millisecondsSinceEpoch < cutoff) {
        await _safeDelete(entity);
      }
    }
  }

  /// Tab ? ?????
  static String slotForTab(String tab) {
    switch (tab) {
      case 'bookshelf':
        return 'bookshelf';
      case 'explore':
        return 'home';
      case 'rss':
        return 'notes';
      case 'my':
        return 'settings';
      default:
        return tab;
    }
  }

  Future<Directory> _createSessionDir() async {
    await _cleanupStaleSessions();
    final root = await _sessionRoot();
    final dir = Directory('${root.path}${Platform.pathSeparator}${_newId()}');
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _cleanupStaleSessions() async {
    final root = await _sessionRoot();
    final cutoff = DateTime.now().millisecondsSinceEpoch - _sessionMaxAgeMs;
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final stat = await entity.stat();
      if (stat.modified.millisecondsSinceEpoch < cutoff) {
        await _safeDelete(entity);
      }
    }
  }

  Future<Directory?> _resolveSessionDir(String sessionId) async {
    if (!_isSafeSessionId(sessionId)) return null;
    final root = await _sessionRoot();
    final dir = Directory('${root.path}${Platform.pathSeparator}$sessionId');
    if (!await dir.exists()) return null;
    return dir;
  }

  Future<File> _requireSessionFile(Directory session, File file) async {
    if (!await file.exists()) throw StateError('image missing');
    final sessionPath =
        (await session.resolveSymbolicLinks()).toLowerCase();
    final filePath = (await file.resolveSymbolicLinks()).toLowerCase();
    final sep = Platform.pathSeparator;
    final ok = filePath == sessionPath ||
        filePath.startsWith('$sessionPath$sep');
    if (!ok) throw StateError('image outside staging session');
    return file;
  }

  Future<void> _safeDelete(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) {
        await entity.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('BottomBarSkinService._safeDelete: $e');
    }
  }

  String _extOf(File file) {
    final name = file.path.split(Platform.pathSeparator).last.toLowerCase();
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return 'png';
    final ext = name.substring(dot + 1);
    return BottomBarSkinFormat.imageExts.contains(ext) ? ext : 'png';
  }

  String _newId() {
    final a = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final b = _random.nextInt(0x7fffffff).toRadixString(16);
    return '$a$b';
  }

  bool _isSafeSessionId(String id) {
    if (id.isEmpty || id.length > 64) return false;
    return RegExp(r'^[a-fA-F0-9]+$').hasMatch(id);
  }
}
