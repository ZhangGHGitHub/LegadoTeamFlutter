import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';
import 'bottom_bar_skin_format.dart';

/// 底栏皮肤路径解析结果
class BottomBarSkinIcons {
  const BottomBarSkinIcons({this.normal, this.selected});

  final String? normal;
  final String? selected;
}

/// 底栏皮肤本地管理（对齐 BottomBarSkinManager 最小可用子集）
///
/// MVP：导入已命名槽位图片的 zip（`bookshelf_selected.png` 等）→ 列表/启用/删除。
/// 不含原版 AssignActivity 交互式槽位分配。
class BottomBarSkinService {
  BottomBarSkinService._();
  static final instance = BottomBarSkinService._();

  static const _maxArchiveBytes = 16 * 1024 * 1024;
  static const _maxEntryBytes = 8 * 1024 * 1024;
  static const _maxTotalBytes = 32 * 1024 * 1024;
  static const _maxEntries = 64;

  Directory? _root;

  Future<Directory> _rootDir() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}bottomBarSkins');
    if (!await dir.exists()) await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  Future<List<String>> list() async {
    final root = await _rootDir();
    final names = <String>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final basename = entity.path.split(Platform.pathSeparator).last;
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
      debugPrint('BottomBarSkinService.delete 异常: $e');
      return false;
    }
  }

  /// 导入 zip：仅接受已按槽位命名的图片（对齐智能预填 parseEntryName）
  Future<String> importZip(File zipFile, {String? preferredName}) async {
    final bytes = await zipFile.readAsBytes();
    if (bytes.length > _maxArchiveBytes) {
      throw StateError('压缩包过大');
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    final mapped = <String, List<int>>{}; // filename -> bytes
    var entryCount = 0;
    var totalBytes = 0;

    for (final entry in archive) {
      entryCount++;
      if (entryCount > _maxEntries) throw StateError('压缩包条目过多');
      if (entry.isDirectory) continue;
      final imageName = BottomBarSkinFormat.sanitizeImageName(entry.name);
      if (imageName == null) continue;
      final parsed = BottomBarSkinFormat.parseEntryName(imageName);
      if (parsed == null) continue;
      final data = entry.content;
      if (data.length > _maxEntryBytes) throw StateError('单文件过大');
      totalBytes += data.length;
      if (totalBytes > _maxTotalBytes) throw StateError('压缩包内容过大');
      final ext = imageName.split('.').last.toLowerCase();
      final outName =
          '${parsed.slot}_${parsed.selected ? 'selected' : 'normal'}.$ext';
      mapped[outName] = data;
    }

    if (mapped.isEmpty) {
      throw StateError('未找到有效槽位图片（需 bookshelf/home/notes/settings 的 _selected/_normal）');
    }
    final hasSelected =
        mapped.keys.any((k) => k.contains('_selected.'));
    if (!hasSelected) {
      throw StateError('至少需要一张 *_selected 图片');
    }

    final existing = await list();
    final baseName = preferredName?.isNotEmpty == true
        ? preferredName!
        : zipFile.uri.pathSegments.last.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
    final skinName = BottomBarSkinFormat.uniqueName(baseName, existing);
    final skinDir = Directory(
      '${(await _rootDir()).path}${Platform.pathSeparator}$skinName',
    );
    await skinDir.create(recursive: true);
    for (final e in mapped.entries) {
      await File('${skinDir.path}${Platform.pathSeparator}${e.key}')
          .writeAsBytes(e.value, flush: true);
    }
    return skinName;
  }

  /// 读取某槽位图标路径（selected/normal）
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
    // 导入统一写成 .png，但也兼容其它后缀
    return BottomBarSkinIcons(normal: normal, selected: selected);
  }

  /// Tab → 原版槽位名
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
}
