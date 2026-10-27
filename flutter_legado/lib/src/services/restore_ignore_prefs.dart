import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';
import 'settings_service.dart';

/// 备份 JSON 中偏好字段名（Flutter 单文件备份扩展，对齐原版 config.xml）
const kBackupAppPrefsKey = 'appPrefs';

/// 恢复忽略项的偏好备份/恢复（对齐 [BackupConfig.keyIsNotIgnore] + Restore 写 prefs）
///
/// 原版 ZIP 含 SharedPreferences `config`；重构版 JSON 仅有业务表时，
/// 由本助手在备份后注入 / 恢复前应用 `appPrefs`，使 ignore 键除 localBook 外亦可生效。
class RestoreIgnorePrefs {
  RestoreIgnorePrefs._();

  /// 始终不备份/不恢复（对齐 BackupConfig.ignorePrefKeys）
  static const alwaysIgnoreKeys = <String>{
    PrefKeys.webServiceWakeLock,
    PrefKeys.defaultBookTreeUri,
    PrefKeys.bitmapCacheSize,
    'defaultCover',
    'defaultCoverDark',
    'backupPath',
    'webDavDeviceName',
    'jsSourceApiToken',
    PrefKeys.launcherIcon,
    'readAloudWakeLock',
    'audioPlayWakeLock',
    // 本地密码（应用锁）：只在签发设备上有效，随备份/恢复携带会泄露明文
    // 口令，故既不写入备份 appPrefs，也不被备份值覆盖本机设置
    PrefKeys.localPassword,
    // [批17c P2-3] WebDAV 同步账号密码：同属设备级秘密（原版该值在
    // config.xml 内以备份密码 AES 加密；我方 JSON 备份不加密），整键排除
    SettingsService.webDavPasswordKey,
    SettingsService.restoreIgnoreStorageKey,
  };

  /// 需要**值净化**（而非整键排除）的偏好键 → 剥除其中敏感字段
  ///
  /// `remote_servers` 仍是 legacy prefs 形态（`RemoteBookNotifier` 在用），
  /// 元素含 `password` 明文：备份时剥掉密码（保留 id/name/url/username，
  /// 便于换机后重新填密码），恢复时**不得用备份值覆盖本机密码**。
  static const _sanitizedKeys = <String>{SettingsService.remoteServersKey};

  /// 阅读界面相关键（对齐 BackupConfig.readPrefKeys + Flutter 阅读偏好）
  static const readPrefKeys = <String>{
    'readStyleSelect',
    'comicStyleSelect',
    'shareLayout',
    'hideStatusBar',
    'hideNavigationBar',
    'autoReadSpeed',
    'clickActionTL',
    'clickActionTC',
    'clickActionTR',
    'clickActionML',
    'clickActionMC',
    'clickActionMR',
    'clickActionBL',
    'clickActionBC',
    'clickActionBR',
    'reader_font_size',
    'reader_line_height',
    'reader_bg_color_index',
    'reader_flip_mode',
    'reader_flip_mode_name',
    'reader_brightness',
    'reader_font_family',
  };

  /// 主题颜色相关键（对齐 BackupConfig.themePrefKeys）
  static const themePrefKeys = <String>{
    PrefKeys.cPrimary,
    PrefKeys.cAccent,
    PrefKeys.cBackground,
    PrefKeys.cBBackground,
    PrefKeys.bgImage,
    PrefKeys.bgImageN,
    PrefKeys.cNPrimary,
    PrefKeys.cNAccent,
    PrefKeys.cNBackground,
    PrefKeys.cNBBackground,
    PrefKeys.transparentNavBar,
    PrefKeys.transparentNavBarNight,
    'themeConfigList',
    'bgImageBlurring',
    'bgImageNBlurring',
  };

  /// 封面规则相关键（对齐 BackupConfig.coverPrefKeys）
  static const coverPrefKeys = <String>{
    PrefKeys.useDefaultCover,
    PrefKeys.loadCoverOnlyWifi,
    PrefKeys.coverShowName,
    PrefKeys.coverShowAuthor,
    'coverShowNameN',
    'coverShowAuthorN',
  };

  /// Flutter 侧主题模式存储键（SettingsService）
  static const themeModeStorageKey = 'app_theme_mode';

  /// Flutter 侧书架布局存储键
  static const bookshelfLayoutStorageKey = 'bookshelf_layout';

  /// 判断偏好键是否应写入备份 / 从备份恢复（对齐 BackupConfig.keyIsNotIgnore）
  static bool keyIsNotIgnore(String key, Map<String, bool> ignore) {
    if (alwaysIgnoreKeys.contains(key)) return false;
    if (ignore['readConfig'] == true && readPrefKeys.contains(key)) {
      return false;
    }
    if (ignore['themeConfig'] == true && themePrefKeys.contains(key)) {
      return false;
    }
    if (ignore['coverConfig'] == true && coverPrefKeys.contains(key)) {
      return false;
    }
    if (ignore['themeMode'] == true &&
        (key == 'themeMode' || key == themeModeStorageKey)) {
      return false;
    }
    if (ignore['bookshelfLayout'] == true &&
        (key == 'bookshelfLayout' || key == bookshelfLayoutStorageKey)) {
      return false;
    }
    if (ignore['showRss'] == true && key == PrefKeys.showRss) return false;
    if (ignore['threadCount'] == true && key == PrefKeys.threadCount) {
      return false;
    }
    return true;
  }

  /// 从当前 SharedPreferences 收集可备份偏好（已按 ignore 过滤 + 敏感值净化）
  static Future<Map<String, dynamic>> collectForBackup(
    Map<String, bool> ignore,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      if (!keyIsNotIgnore(key, ignore)) continue;
      final value = prefs.get(key);
      if (value == null) continue;
      if (_sanitizedKeys.contains(key)) {
        final sanitized = sanitizePrefValue(key, value);
        // 净化失败（形态非法）时整键不写入——宁可丢非敏感字段，也不把
        // 无法识别的内容原样带进明文备份
        if (sanitized != null) out[key] = sanitized;
        continue;
      }
      out[key] = value;
    }
    return out;
  }

  /// 敏感偏好值净化（备份侧）：剥除秘密字段后返回，非法形态返回 null
  ///
  /// 当前仅 `remote_servers`（JSON 数组字符串）：逐元素保留
  /// `id`/`name`/`url`/`username` 与其它非敏感键，**删除 `password` 键**
  ///（键名大小写不敏感，见 [_stripServerSecrets]；仅顶层本应用 schema）。
  /// 非 JSON 数组形态 → null（不写入备份）。
  static String? sanitizePrefValue(String key, Object value) {
    if (key != SettingsService.remoteServersKey) return null;
    final servers = _decodeRemoteServers(value);
    if (servers == null) {
      debugPrint('RestoreIgnorePrefs: $key 形态非法，已从备份中剔除');
      return null;
    }
    return jsonEncode(servers.map(_stripServerSecrets).toList());
  }

  /// 剥除远程书库条目中的秘密字段（`password`），其余键原样保留
  ///
  /// 范围声明：**仅本应用 schema 的顶层 `password`**（`RemoteBook` 服务器条目
  /// 形态 `{id,name,url,username,password}`）。不做递归清洗——嵌套对象里的
  /// 字段不属于本应用约定、无法安全判定敏感面，递归剥除会误改用户自定义
  /// 字段并改变备份结构。
  ///
  /// 键名按**大小写不敏感**匹配：本应用写出的键恒为小写 `password`，但
  /// 手改 / 第三方产物可能出现 `Password`/`PASSWORD`，同样必须剥除（否则
  /// 明文口令随备份落盘，且恢复侧大小写不同会被当成普通字段写回）。
  static Map<String, dynamic> _stripServerSecrets(Map<String, dynamic> server) {
    return <String, dynamic>{
      for (final entry in server.entries)
        if (entry.key.toLowerCase() != 'password') entry.key: entry.value,
    };
  }

  /// 把备份中的远程书库配置合并进本机（恢复侧）
  ///
  /// 语义：备份列表**替换**本机列表（与其它偏好恢复的覆盖语义一致），但
  /// **密码只认本机既有值**——按 `id`（其次 `url`+`username`）匹配本机
  /// 条目取回 password；备份里没有对应本机条目时密码置空（由用户重填）。
  /// 备份侧已净化（无 password 字段），此处仍显式忽略备份中的 password，
  /// 防止旧版备份/第三方备份携带明文口令覆盖本机设置。
  static Future<String?> mergeRemoteServersFromBackup(Object value) async {
    final backupServers = _decodeRemoteServers(value);
    if (backupServers == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final localServers = _decodeRemoteServers(
          prefs.getString(SettingsService.remoteServersKey) ?? '',
        ) ??
        const [];
    final localPasswordsById = <int, String>{};
    final localPasswordsByEndpoint = <String, String>{};
    for (final local in localServers) {
      final password = local['password'];
      if (password is! String || password.isEmpty) continue;
      final id = local['id'];
      if (id is int) localPasswordsById[id] = password;
      localPasswordsByEndpoint[
          _endpointKeyOf(local['url'], local['username'])] = password;
    }
    final merged = backupServers.map((server) {
      final out = _stripServerSecrets(server);
      final id = out['id'];
      final localPassword =
          (id is int ? localPasswordsById[id] : null) ??
              localPasswordsByEndpoint[
                  _endpointKeyOf(out['url'], out['username'])];
      if (localPassword != null && localPassword.isNotEmpty) {
        out['password'] = localPassword;
      }
      return out;
    }).toList();
    return jsonEncode(merged);
  }

  static String _endpointKeyOf(Object? url, Object? username) =>
      '${url ?? ''}\u0000${username ?? ''}';

  /// 解析远程书库服务器 JSON（`[{id,name,url,username,password}]`）
  ///
  /// 宽容形态：JSON 字符串 / List 均可；非数组或元素非对象 → null
  /// （调用方按「不写入备份」处理）。元素内非敏感字段原样保留。
  static List<Map<String, dynamic>>? _decodeRemoteServers(Object? value) {
    Object? decoded = value;
    if (decoded is String) {
      final text = decoded.trim();
      if (text.isEmpty) return const [];
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        return null;
      }
    }
    if (decoded is! List) return null;
    final out = <Map<String, dynamic>>[];
    for (final item in decoded) {
      if (item is! Map) return null;
      out.add(Map<String, dynamic>.from(item));
    }
    return out;
  }

  /// 将备份中的 appPrefs 写入 SharedPreferences（按 ignore 过滤）
  static Future<void> applyFromBackup(
    Map<String, dynamic>? appPrefs,
    Map<String, bool> ignore,
  ) async {
    if (appPrefs == null || appPrefs.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    for (final entry in appPrefs.entries) {
      final key = entry.key;
      if (!keyIsNotIgnore(key, ignore)) continue;
      final value = entry.value;
      try {
        // [批17c P2-3] 远程书库：只恢复非敏感字段，密码保留本机既有值
        //（备份值即使携带 password 也一律忽略）
        if (key == SettingsService.remoteServersKey) {
          final merged = await mergeRemoteServersFromBackup(value);
          if (merged != null) {
            await prefs.setString(key, merged);
          }
          continue;
        }
        if (value is bool) {
          await prefs.setBool(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is String) {
          await prefs.setString(key, value);
        } else if (value is List) {
          await prefs.setStringList(
            key,
            value.map((e) => '$e').toList(),
          );
        } else if (value is num) {
          if (value == value.roundToDouble()) {
            await prefs.setInt(key, value.toInt());
          } else {
            await prefs.setDouble(key, value.toDouble());
          }
        }
      } catch (e) {
        debugPrint('RestoreIgnorePrefs.applyFromBackup($key) 异常: $e');
      }
    }
  }

  /// 向备份 JSON 注入 appPrefs
  static Future<void> injectAppPrefsIntoBackupFile(
    String backupPath,
    Map<String, bool> ignore,
  ) async {
    if (!backupPath.toLowerCase().endsWith('.json')) return;
    try {
      final file = await _readJsonMap(backupPath);
      if (file == null) return;
      file[kBackupAppPrefsKey] = await collectForBackup(ignore);
      await File(backupPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(file),
      );
    } catch (e) {
      debugPrint('RestoreIgnorePrefs.injectAppPrefsIntoBackupFile 异常: $e');
    }
  }

  /// 从备份 JSON 读取并应用 appPrefs（不改动供 Rust restore 的文件）
  static Future<void> applyAppPrefsFromBackupFile(
    String backupPath,
    Map<String, bool> ignore,
  ) async {
    if (!backupPath.toLowerCase().endsWith('.json')) return;
    try {
      final file = await _readJsonMap(backupPath);
      if (file == null) return;
      final raw = file[kBackupAppPrefsKey];
      Map<String, dynamic>? appPrefs;
      if (raw is Map<String, dynamic>) {
        appPrefs = raw;
      } else if (raw is Map) {
        appPrefs = raw.map((k, v) => MapEntry('$k', v));
      }
      await applyFromBackup(appPrefs, ignore);
    } catch (e) {
      debugPrint('RestoreIgnorePrefs.applyAppPrefsFromBackupFile 异常: $e');
    }
  }

  static Future<Map<String, dynamic>?> _readJsonMap(String path) async {
    final raw = await File(path).readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry('$k', v));
    }
    return null;
  }
}
