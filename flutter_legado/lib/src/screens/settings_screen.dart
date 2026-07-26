import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../routes.dart';
import '../services/backup_service.dart';
import '../services/rust_api.dart';
import '../services/settings_service.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/sync_provider.dart';

/// 设置页面
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsService _settingsService = SettingsService();
  ThemeMode _themeMode = ThemeMode.system;
  String _localeValue = 'system'; // system, zh, en
  bool _backupLoading = false;
  bool _restoreLoading = false;

  // WebDAV 配置控制器
  final _webDavUrlController = TextEditingController();
  final _webDavUserController = TextEditingController();
  final _webDavPassController = TextEditingController();
  final _webDavDirController = TextEditingController(text: '/legado/');

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
    _loadLocale();
    _initSyncConfig();
  }

  @override
  void dispose() {
    _webDavUrlController.dispose();
    _webDavUserController.dispose();
    _webDavPassController.dispose();
    _webDavDirController.dispose();
    super.dispose();
  }

  Future<void> _initSyncConfig() async {
    final syncProvider = context.read<SyncProvider>();
    await syncProvider.loadConfig();
    if (mounted) {
      _webDavUrlController.text = syncProvider.webDavUrl;
      _webDavUserController.text = syncProvider.webDavUsername;
      _webDavPassController.text = syncProvider.webDavPassword;
      _webDavDirController.text = syncProvider.remoteDir;
    }
  }

  Future<void> _loadThemeMode() async {
    _themeMode = await _settingsService.getThemeMode();
    if (mounted) setState(() {});
  }

  Future<void> _loadLocale() async {
    _localeValue = await _settingsService.getLocale();
    if (_localeValue == 'system') {
      // 保持默认 zh
    } else {
      AppStrings.setLocale(_localeValue);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.settings)),
      body: ListView(
        children: [
          // ===== 外观设置 =====
          _buildSectionHeader(context, AppStrings.appearanceSettings),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: Text(AppStrings.themeMode),
            subtitle: Text(_themeModeLabel),
            onTap: () => _showThemePicker(context),
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(AppStrings.language),
            subtitle: Text(_localeLabel),
            onTap: () => _showLocalePicker(context),
          ),
          const Divider(),

          // ===== 阅读设置 =====
          _buildSectionHeader(context, AppStrings.readingSettings),
          ListTile(
            leading: const Icon(Icons.text_fields),
            title: Text(AppStrings.defaultFontSize),
            subtitle: const Text('18'),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.format_line_spacing),
            title: Text(AppStrings.defaultLineHeight),
            subtitle: const Text('1.6x'),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.palette),
            title: Text(AppStrings.defaultBgColor),
            subtitle: Text(AppStrings.whiteColor),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.bar_chart),
            title: const Text('阅读统计'),
            subtitle: const Text('查看阅读时长与书籍分布'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.readingStats),
          ),
          const Divider(),

          // ===== 网络设置 =====
          _buildSectionHeader(context, AppStrings.networkSettings),
          ListTile(
            leading: const Icon(Icons.wifi),
            title: Text(AppStrings.proxySettings),
            subtitle: Text(AppStrings.noProxy),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.timer),
            title: Text(AppStrings.requestTimeout),
            subtitle: Text(AppStrings.seconds30),
            onTap: () {},
          ),
          const Divider(),

          // ===== 数据管理 =====
          _buildSectionHeader(context, AppStrings.dataManagement),
          ListTile(
            leading: const Icon(Icons.backup),
            title: Text(AppStrings.backupData),
            subtitle: Text(AppStrings.backupDataDesc),
            trailing: _backupLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _backupLoading ? null : () => _doBackup(context),
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: Text(AppStrings.restoreData),
            subtitle: Text(AppStrings.restoreDataDesc),
            trailing: _restoreLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _restoreLoading ? null : () => _doRestore(context),
          ),
          ListTile(
            leading: Icon(Icons.cleaning_services,
                color: Theme.of(context).colorScheme.error),
            title: Text(AppStrings.clearCache,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            subtitle: Text(AppStrings.clearCacheDesc),
            onTap: () => _clearCache(context),
          ),
          const Divider(),

          // ===== 云同步 =====
          _buildSectionHeader(context, AppStrings.cloudSync),
          _buildWebDavConfigSection(context),
          _buildSyncActionsSection(context),
          const Divider(),

          // ===== 其他 =====
          _buildSectionHeader(context, AppStrings.otherSettings),
          ListTile(
            leading: const Icon(Icons.library_books),
            title: Text(AppStrings.sourceManagement),
            onTap: () => Navigator.pushNamed(context, AppRoutes.sources),
          ),
          ListTile(
            leading: const Icon(Icons.bookmark),
            title: const Text('书签管理'),
            subtitle: const Text('查看和管理所有书签'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.bookmarks),
          ),
          ListTile(
            leading: const Icon(Icons.find_replace),
            title: const Text('替换规则'),
            subtitle: const Text('管理阅读内容替换规则'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.replaceRules),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('定时任务'),
            subtitle: const Text('管理自动刷新和备份任务'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.autoTasks),
          ),
          const Divider(),

          // ===== 关于 =====
          _buildSectionHeader(context, AppStrings.aboutSettings),
          ListTile(
            leading: const Icon(Icons.info),
            title: Text(AppStrings.version),
            subtitle: const Text('1.0.0'),
          ),
          ListTile(
            leading: const Icon(Icons.description),
            title: Text(AppStrings.license),
            subtitle: const Text('GPL-3.0'),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(AppStrings.projectUrl),
            subtitle: const Text('github.com/gedoor/legado'),
            onTap: () {},
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  String get _themeModeLabel {
    switch (_themeMode) {
      case ThemeMode.light:
        return AppStrings.themeLight;
      case ThemeMode.dark:
        return AppStrings.themeDark;
      default:
        return AppStrings.themeSystem;
    }
  }

  String get _localeLabel {
    switch (_localeValue) {
      case 'zh':
        return AppStrings.langChinese;
      case 'en':
        return AppStrings.langEnglish;
      default:
        return AppStrings.langSystem;
    }
  }

  void _showThemePicker(BuildContext context) {
    showDialog<ThemeMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppStrings.selectTheme),
        children: ThemeMode.values.map((mode) {
          final isSelected = mode == _themeMode;
          return ListTile(
            leading: Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? Theme.of(ctx).colorScheme.primary : null,
            ),
            title: Text(_getThemeLabel(mode)),
            onTap: () {
              Navigator.pop(ctx, mode);
            },
          );
        }).toList(),
      ),
    ).then((selectedMode) async {
      if (selectedMode != null) {
        setState(() => _themeMode = selectedMode);
        await _settingsService.setThemeMode(selectedMode);
      }
    });
  }

  String _getThemeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return AppStrings.themeSystem;
      case ThemeMode.light:
        return AppStrings.themeLight;
      case ThemeMode.dark:
        return AppStrings.themeDark;
    }
  }

  void _showLocalePicker(BuildContext context) {
    showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppStrings.language),
        children: [
          _buildLocaleOption(ctx, 'system', AppStrings.langSystem),
          _buildLocaleOption(ctx, 'zh', AppStrings.langChinese),
          _buildLocaleOption(ctx, 'en', AppStrings.langEnglish),
        ],
      ),
    ).then((selectedLocale) async {
      if (selectedLocale != null) {
        setState(() => _localeValue = selectedLocale);
        await _settingsService.setLocale(selectedLocale);
        if (selectedLocale == 'system') {
          AppStrings.setLocale('zh');
        } else {
          AppStrings.setLocale(selectedLocale);
        }
        // Force rebuild of current screen
        if (mounted) setState(() {});
      }
    });
  }

  Widget _buildLocaleOption(BuildContext ctx, String value, String label) {
    final isSelected = value == _localeValue;
    return ListTile(
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: isSelected ? Theme.of(ctx).colorScheme.primary : null,
      ),
      title: Text(label),
      onTap: () => Navigator.pop(ctx, value),
    );
  }

  Future<void> _doBackup(BuildContext context) async {
    setState(() => _backupLoading = true);
    try {
      final api = context.read<RustApi>();
      final backup = BackupService(api);
      final data = await backup.fullBackup();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.backupSuccess}, data length: ${data.length}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.backupFailed}: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _backupLoading = false);
    }
  }

  Future<void> _doRestore(BuildContext context) async {
    setState(() => _restoreLoading = true);
    final api = context.read<RustApi>();
    try {
      final controller = TextEditingController();
      final json = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(AppStrings.restoreData),
          content: TextField(
            controller: controller,
            maxLines: 5,
            decoration: InputDecoration(
              hintText: AppStrings.pasteBackupJson,
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(AppStrings.restore),
            ),
          ],
        ),
      );

      if (json == null || json.isEmpty) return;

      final backup = BackupService(api);
      final count = await backup.restoreSourcesFromBackup(json);
      if (context.mounted) {
        context.read<BookshelfProvider>().loadBooks();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.restoreSuccess}, $count sources')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.restoreFailed}: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _restoreLoading = false);
    }
  }

  void _clearCache(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppStrings.clearCache),
        content: Text(AppStrings.confirmClearCache),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppStrings.cacheCleared)),
              );
            },
            child: Text(AppStrings.confirm),
          ),
        ],
      ),
    );
  }

  // ===== 云同步 UI 构建 =====

  Widget _buildWebDavConfigSection(BuildContext context) {
    return Consumer<SyncProvider>(
      builder: (context, syncProvider, _) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                controller: _webDavUrlController,
                decoration: InputDecoration(
                  labelText: AppStrings.webdavServerUrl,
                  hintText: 'https://dav.example.com/',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.cloud),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                controller: _webDavUserController,
                decoration: InputDecoration(
                  labelText: AppStrings.username,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.person),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                controller: _webDavPassController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: AppStrings.password,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                controller: _webDavDirController,
                decoration: InputDecoration(
                  labelText: AppStrings.remoteDir,
                  hintText: '/legado/',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.folder),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                onPressed: () async {
                  await syncProvider.saveConfig(
                    _webDavUrlController.text,
                    _webDavUserController.text,
                    _webDavPassController.text,
                    _webDavDirController.text,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(AppStrings.configSaved)),
                    );
                  }
                },
                icon: const Icon(Icons.save),
                label: Text(AppStrings.saveConfig),
              ),
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  Widget _buildSyncActionsSection(BuildContext context) {
    return Consumer<SyncProvider>(
      builder: (context, syncProvider, _) {
        final isSyncing = syncProvider.status == SyncStatus.syncing;
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.sync),
              title: Text(AppStrings.syncNow),
              subtitle: Text('${AppStrings.lastSync}: ${syncProvider.lastSyncTimeLabel}'),
              trailing: isSyncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onTap: isSyncing ? null : () => _showSyncOptions(context),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.autorenew),
              title: Text(AppStrings.autoSync),
              subtitle: Text(AppStrings.autoSyncDesc),
              value: syncProvider.autoSync,
              onChanged: syncProvider.toggleAutoSync,
            ),
            if (syncProvider.status == SyncStatus.success)
              ListTile(
                leading: Icon(Icons.check_circle,
                    color: Theme.of(context).colorScheme.primary),
                title: Text(AppStrings.syncSuccess),
              ),
            if (syncProvider.status == SyncStatus.error &&
                syncProvider.error != null)
              ListTile(
                leading: Icon(Icons.error,
                    color: Theme.of(context).colorScheme.error),
                title: Text(
                  syncProvider.error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        );
      },
    );
  }

  void _showSyncOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.cloud_upload),
              title: Text(AppStrings.uploadBookshelf),
              subtitle: Text(AppStrings.uploadBookshelfDesc),
              onTap: () {
                Navigator.pop(ctx);
                context.read<SyncProvider>().syncUpload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud_download),
              title: Text(AppStrings.downloadBookshelf),
              subtitle: Text(AppStrings.downloadBookshelfDesc),
              onTap: () {
                Navigator.pop(ctx);
                context.read<SyncProvider>().syncDownload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.merge),
              title: Text(AppStrings.mergeSync),
              subtitle: Text(AppStrings.mergeSyncDesc),
              onTap: () {
                Navigator.pop(ctx);
                context.read<SyncProvider>().syncMerge();
              },
            ),
          ],
        ),
      ),
    );
  }
}
