import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../l10n/app_strings.dart';
import '../models/book.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/main_prefs_notifier.dart';
import '../providers/providers.dart';
import '../providers/sync/sync_notifier.dart';
import '../providers/theme/theme_colors_notifier.dart';
import '../providers/theme/theme_notifier.dart';
import '../routes.dart';
import '../services/crash_log_service.dart';
import '../services/restore_ignore_prefs.dart';
import '../services/settings_service.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import '../widgets/restore_ignore_dialog.dart';

/// 备份与恢复（对齐 BackupConfigFragment + pref_config_backup.xml）
///
/// 结构：
/// 1. WebDav 设置：地址/账号/密码/子目录/设备名/同步进度（含增强）
/// 2. 备份与恢复：备份路径/备份/恢复/恢复忽略/仅保留最新/自动检查
///
/// 顶栏菜单对标 backup_restore.xml：帮助、导入旧版数据、日志。
/// 恢复项长按 → 本地恢复（对标 web_dav_restore.onLongClick）。
///
/// 路由仍为 [AppRoutes.webdavSettings]（历史路径兼容）。
///
/// — UI 子代理 + UI ｜ 2026-08-13
class WebDavSettingsScreen extends ConsumerStatefulWidget {
  const WebDavSettingsScreen({super.key});

  @override
  ConsumerState<WebDavSettingsScreen> createState() =>
      _WebDavSettingsScreenState();
}

class _WebDavSettingsScreenState extends ConsumerState<WebDavSettingsScreen> {
  SettingsService get _settings => ref.read(settingsProvider);

  String _url = '';
  String _user = '';
  String _pass = '';
  String _dir = '/legado/';
  String _device = '';
  String _backupPath = '';
  bool _onlyLatestBackup = true;
  bool _autoCheckNewBackup = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final notifier = ref.read(syncNotifierProvider.notifier);
    await notifier.loadConfig();
    final state = ref.read(syncNotifierProvider);
    final path = await CrashLogService.instance.getBackupPath() ?? '';
    final onlyLatest = await _settings.getBoolPref(
      PrefKeys.onlyLatestBackup,
      defaultValue: true,
    );
    final autoCheck = await _settings.getBoolPref(
      PrefKeys.autoCheckNewBackup,
      defaultValue: true,
    );
    if (!mounted) return;
    setState(() {
      _url = state.webDavUrl;
      _user = state.webDavUsername;
      _pass = state.webDavPassword;
      _dir = state.remoteDir;
      _device = state.deviceName;
      _backupPath = path;
      _onlyLatestBackup = onlyLatest;
      _autoCheckNewBackup = autoCheck;
    });
  }

  Future<void> _saveWebDav() async {
    await ref.read(syncNotifierProvider.notifier).saveConfig(
          _url,
          _user,
          _pass,
          _dir,
          deviceName: _device,
        );
  }

  Future<void> _editTextPref({
    required String title,
    required String initial,
    required ValueChanged<String> onSaved,
    bool obscure = false,
    String? hint,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        // [LAYOUT_PLAN P3] Dialog 容器 surfaceContainer 圆角 28dp（全局标尺，对齐 dialogTheme）
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: obscure,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result == null) return;
    setState(() => onSaved(result));
    await _saveWebDav();
  }

  Future<void> _pickBackupPath() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择备份路径',
    );
    if (picked == null) return;
    await CrashLogService.instance.setBackupPath(picked);
    if (!mounted) return;
    setState(() => _backupPath = picked);
  }

  Future<void> _doLocalBackup() async {
    await _runWithProgress('备份中…', () async {
      final api = ref.read(bookApiProvider);
      var dirPath = _backupPath;
      if (dirPath.isEmpty) {
        final picked = await FilePicker.platform.getDirectoryPath();
        if (picked == null) return;
        dirPath = picked;
        await CrashLogService.instance.setBackupPath(dirPath);
        if (mounted) setState(() => _backupPath = dirPath);
      }
      final filePath = await api.backup(dirPath);
      final ignore = await _settings.getRestoreIgnoreConfig();
      await RestoreIgnorePrefs.injectAppPrefsIntoBackupFile(filePath, ignore);
      // 同步 WebDAV（对齐原版本地与 WebDav 一起备份）
      final sync = ref.read(syncNotifierProvider);
      if (sync.isConfigured) {
        try {
          await ref.read(syncNotifierProvider.notifier).backupToWebDav();
        } catch (_) {
          // WebDAV 失败不阻断本地备份成功提示
        }
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(content: Text('${AppStrings.backupSuccess}：$filePath')),
      );
    });
  }

  /// 默认恢复：优先 WebDAV；失败或未配置则提示（长按走本地）
  Future<void> _doRestore() async {
    final sync = ref.read(syncNotifierProvider);
    if (sync.isConfigured) {
      await _runWithProgress('恢复中…', () async {
        final message =
            await ref.read(syncNotifierProvider.notifier).restoreFromWebDav();
        if (!mounted) return;
        await _reloadPrefsAfterRestore();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message.isEmpty ? '恢复完成' : message)),
        );
      });
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('未配置 WebDAV，请长按「恢复」从本地恢复')),
    );
  }

  Future<void> _doRestoreFromLocal() async {
    await _runWithProgress('恢复中…', () async {
      final api = ref.read(bookApiProvider);
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'zip'],
      );
      final backupPath = result?.files.single.path;
      if (backupPath == null) return;

      var pathToRestore = backupPath;
      final ignore = await _settings.getRestoreIgnoreConfig();
      if (ignore['localBook'] == true &&
          backupPath.toLowerCase().endsWith('.json')) {
        pathToRestore = await _backupPathSkippingLocalBooks(backupPath);
      }

      await RestoreIgnorePrefs.applyAppPrefsFromBackupFile(backupPath, ignore);
      await api.restore(pathToRestore);
      if (!mounted) return;
      await _reloadPrefsAfterRestore();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.restoreSuccess)),
      );
    });
  }

  Future<void> _showRestoreIgnore() async {
    final initial = await _settings.getRestoreIgnoreConfig();
    if (!mounted) return;
    final result = await showDialog<Map<String, bool>>(
      context: context,
      builder: (ctx) => RestoreIgnoreDialog(initial: initial),
    );
    if (result == null) return;
    await _settings.saveRestoreIgnoreConfig(result);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存恢复忽略项')),
    );
  }

  Future<void> _doImportOldData() async {
    await _runWithProgress('导入中…', () async {
      final dirPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择旧版备份目录',
      );
      if (dirPath == null) return;

      final api = ref.read(bookApiProvider);
      final raw = await api.importOldData(dirPath);
      final decoded = jsonDecode(raw);
      String message;
      if (decoded is Map) {
        final msgs = decoded['messages'];
        if (msgs is List && msgs.isNotEmpty) {
          message = msgs.map((e) => '$e').join('\n');
        } else {
          final books = decoded['books'] ?? 0;
          final sources = decoded['bookSources'] ?? 0;
          final rules = decoded['replaceRules'] ?? 0;
          message = '书架 $books · 书源 $sources · 替换规则 $rules';
        }
      } else {
        message = '导入完成';
      }

      ref.read(bookshelfNotifierProvider.notifier).refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    });
  }

  Future<void> _reloadPrefsAfterRestore() async {
    await ref.read(themeNotifierProvider.notifier).load();
    ref.invalidate(themeColorsProvider);
    ref.invalidate(mainPrefsProvider);
    ref.invalidate(bookshelfNotifierProvider);
  }

  Future<String> _backupPathSkippingLocalBooks(String backupPath) async {
    final raw = await File(backupPath).readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return backupPath;
    final books = decoded['books'];
    if (books is! List) return backupPath;

    decoded['books'] = books.where((item) {
      if (item is! Map) return true;
      final origin = item['origin']?.toString() ?? '';
      final type = item['type'];
      final typeInt = type is int ? type : int.tryParse('$type') ?? 0;
      final isLocal = origin == BookType.localTag ||
          origin.startsWith(BookType.webDavTag) ||
          (typeInt & BookType.local) != 0;
      return !isLocal;
    }).toList();

    final dir = Directory.systemTemp;
    final out = File(
      '${dir.path}${Platform.pathSeparator}legado_restore_no_local_${DateTime.now().millisecondsSinceEpoch}.json',
    );
    await out.writeAsString(jsonEncode(decoded));
    return out.path;
  }

  Future<void> _runWithProgress(
    String label,
    Future<void> Function() task,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        // [LAYOUT_PLAN P3] Dialog 容器 surfaceContainer 圆角 28dp（全局标尺，对齐 dialogTheme）
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
    try {
      await task();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        setState(() => _busy = false);
      }
    }
  }

  void _showHelp() {
    showHelp(context, HelpAssets.webDavHelp);
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncNotifierProvider);
    final notifier = ref.read(syncNotifierProvider.notifier);

    return Scaffold(
      appBar: LegadoAppBar(
        title: const Text('备份与恢复'),
        actions: [
          IconButton(
            icon: const Icon(Symbols.help_rounded),
            tooltip: '帮助',
            onPressed: _showHelp,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'import_old':
                  _doImportOldData();
                case 'log':
                  Navigator.pushNamed(context, AppRoutes.appLog);
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'import_old',
                child: Text('导入旧版数据'),
              ),
              PopupMenuItem(
                value: 'log',
                child: Text('日志'),
              ),
            ],
          ),
        ],
      ),
      body: IosGroupedBody(
        // [LAYOUT_PLAN P3] 列表边距 16dp 走 IosGroupedBody（全局标尺）
        child: ListView(
          // [LAYOUT_PLAN P3] 底部 bottom32 保留
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const IosSectionHeader('WebDav 设置'),
            IosGroup(
              flat: true, // [LAYOUT_MOTION_AUDIT L2] 设置拆扁平
              children: [
                IosListTile(
                  title: 'WebDAV 服务器地址',
                  subtitle: _url.isEmpty ? '输入你的服务器地址' : _url,
                  onTap: () => _editTextPref(
                    title: 'WebDAV 服务器地址',
                    initial: _url,
                    hint: 'https://dav.example.com/',
                    onSaved: (v) => _url = v,
                  ),
                ),
                IosListTile(
                  title: 'WebDAV 账号',
                  subtitle: _user.isEmpty ? '输入你的 WebDAV 账号' : _user,
                  onTap: () => _editTextPref(
                    title: 'WebDAV 账号',
                    initial: _user,
                    onSaved: (v) => _user = v,
                  ),
                ),
                IosListTile(
                  title: 'WebDAV 密码',
                  subtitle: _pass.isEmpty ? '输入你的密码' : '*' * _pass.length,
                  onTap: () => _editTextPref(
                    title: 'WebDAV 密码',
                    initial: _pass,
                    obscure: true,
                    onSaved: (v) => _pass = v,
                  ),
                ),
                IosListTile(
                  title: '子目录',
                  subtitle: _dir.isEmpty ? 'legado' : _dir,
                  onTap: () => _editTextPref(
                    title: '子目录',
                    initial: _dir,
                    hint: 'legado',
                    onSaved: (v) => _dir = v,
                  ),
                ),
                IosListTile(
                  title: '设备名称',
                  subtitle: _device.isEmpty ? '用于区分不同设备的备份' : _device,
                  onTap: () => _editTextPref(
                    title: '设备名称',
                    initial: _device,
                    onSaved: (v) => _device = v,
                  ),
                ),
                SwitchListTile(
                  // [LAYOUT_PLAN P3] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  title: const Text('同步书籍进度'),
                  subtitle: const Text('在多设备间同步书籍阅读进度'),
                  value: syncState.syncBookProgress,
                  onChanged: (v) => notifier.setSyncBookProgress(v),
                ),
                SwitchListTile(
                  // [LAYOUT_PLAN P3] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  title: const Text('同步书籍进度增强'),
                  subtitle: const Text('同步更详细的阅读进度信息'),
                  value: syncState.syncBookProgressPlus,
                  onChanged: syncState.syncBookProgress
                      ? (v) => notifier.setSyncBookProgressPlus(v)
                      : null,
                ),
              ],
            ),

            const IosSectionHeader('备份与恢复'),
            IosGroup(
              flat: true, // [LAYOUT_MOTION_AUDIT L2] 设置拆扁平
              children: [
                IosListTile(
                  title: '备份路径',
                  subtitle:
                      _backupPath.isEmpty ? '请选择备份路径' : _backupPath,
                  onTap: _busy ? null : _pickBackupPath,
                ),
                IosListTile(
                  title: '备份',
                  subtitle: '本地和 WebDav 一起备份',
                  onTap: _busy ? null : _doLocalBackup,
                ),
                // 短按 WebDAV 优先；长按本地恢复
                GestureDetector(
                  onLongPress: _busy ? null : _doRestoreFromLocal,
                  child: IosListTile(
                    title: '恢复',
                    subtitle: '优先从 WebDav 恢复，长按从本地恢复',
                    onTap: _busy ? null : _doRestore,
                  ),
                ),
                IosListTile(
                  title: '恢复忽略列表',
                  subtitle: '恢复时忽略一些内容不恢复，方便不同手机配置不同',
                  onTap: _busy ? null : _showRestoreIgnore,
                ),
                SwitchListTile(
                  // [LAYOUT_PLAN P3] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  title: const Text('仅保留最新备份'),
                  subtitle: const Text('本地备份仅保留最新备份文件'),
                  value: _onlyLatestBackup,
                  onChanged: (v) {
                    setState(() => _onlyLatestBackup = v);
                    _settings.setBoolPref(PrefKeys.onlyLatestBackup, v);
                  },
                ),
                SwitchListTile(
                  // [LAYOUT_PLAN P3] 开关行规范：组内行 vertical12/horizontal8，无 Chevron
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  title: const Text('自动检查新备份'),
                  subtitle: const Text(
                    '打开软件时检查是否有新备份，有新备份时提示是否更新',
                  ),
                  value: _autoCheckNewBackup,
                  onChanged: (v) {
                    setState(() => _autoCheckNewBackup = v);
                    _settings.setBoolPref(PrefKeys.autoCheckNewBackup, v);
                  },
                ),
              ],
            ),
            if (syncState.lastSyncTimeLabel.isNotEmpty)
              IosSectionFooter('上次同步：${syncState.lastSyncTimeLabel}'),
          ],
        ),
      ),
    );
  }
}
