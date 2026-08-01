import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_strings.dart';
import '../routes.dart';
import '../services/book_api.dart';
import '../services/crash_log_service.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/theme_provider.dart';

/// 设置页面（枢纽菜单）
///
/// 对标 Android 原版「我的」页（`pref_main.xml`）：以菜单入口形式聚合各管理功能与子设置页。
/// - 顶部：书源管理 / 定时任务 / TXT 目录规则 / 替换净化 / 词典规则 / 主题模式
/// - 「设置」分组：备份恢复 / 主题设置 / 其他设置
/// - 「其他」分组：书签 / 阅读统计 / 关于
///
/// 子设置页拆分至独立页面：
/// - 主题设置 → [AppRoutes.themeConfig]
/// - 其他设置（语言/阅读默认/网络/缓存）→ [AppRoutes.otherSettings]
/// - 备份恢复 → 底部弹窗（备份/恢复/WebDAV 同步），WebDAV 详情 → [AppRoutes.webdavSettings]
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _backupLoading = false;
  bool _restoreLoading = false;

  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<ThemeProvider>().themeMode;
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.settings)),
      body: ListView(
        children: [
          // ===== 顶部管理入口（对标 pref_main 顶层项）=====
          ListTile(
            leading: const Icon(Icons.library_books),
            title: Text(AppStrings.sourceManagement),
            subtitle: const Text('书源管理、启用、禁用与排序'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.sources),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('定时任务'),
            subtitle: const Text('管理自动刷新和备份任务'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.autoTasks),
          ),
          ListTile(
            leading: const Icon(Icons.toc),
            title: const Text('TXT 目录规则'),
            subtitle: const Text('配置 TXT 书籍目录解析规则'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.txtTocRules),
          ),
          ListTile(
            leading: const Icon(Icons.find_replace),
            title: const Text('替换净化'),
            subtitle: const Text('管理阅读内容替换规则'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.replaceRules),
          ),
          ListTile(
            leading: const Icon(Icons.translate),
            title: const Text('词典规则'),
            subtitle: const Text('配置词典查询规则'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.dict),
          ),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: Text(AppStrings.themeMode),
            subtitle: Text(_themeModeLabel(themeMode)),
            onTap: () => _showThemePicker(context),
          ),
          const Divider(),

          // ===== 设置分组（对标 pref_main「设置」PreferenceCategory）=====
          _buildSectionHeader(context, '设置'),
          ListTile(
            leading: const Icon(Icons.backup),
            title: const Text('备份恢复'),
            subtitle: const Text('备份/恢复数据与 WebDAV 同步'),
            trailing: (_backupLoading || _restoreLoading)
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: (_backupLoading || _restoreLoading)
                ? null
                : () => _showBackupSheet(context),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('主题设置'),
            subtitle: const Text('主题模式、字体、行距、背景色'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.themeConfig),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('其他设置'),
            subtitle: const Text('语言、阅读默认、网络、缓存'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.otherSettings),
          ),
          const Divider(),

          // ===== 其他分组（对标 pref_main「其他」PreferenceCategory）=====
          _buildSectionHeader(context, AppStrings.otherSettings),
          ListTile(
            leading: const Icon(Icons.bookmark),
            title: const Text('书签'),
            subtitle: const Text('查看和管理所有书签'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.bookmarks),
          ),
          ListTile(
            leading: const Icon(Icons.bar_chart),
            title: const Text('阅读统计'),
            subtitle: const Text('查看阅读时长与书籍分布'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.readingStats),
          ),
          ListTile(
            leading: const Icon(Icons.info),
            title: Text(AppStrings.aboutSettings),
            onTap: () => Navigator.pushNamed(context, AppRoutes.about),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report),
            title: const Text('导出日志'),
            subtitle: const Text('分享应用日志文件用于问题诊断'),
            onTap: _exportLogs,
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

  String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return AppStrings.themeLight;
      case ThemeMode.dark:
        return AppStrings.themeDark;
      default:
        return AppStrings.themeSystem;
    }
  }

  /// 主题模式选择（对标 pref_main themeMode NameListPreference）
  ///
  /// 选中后经 [ThemeProvider.setThemeMode] 全局实时生效并持久化。
  void _showThemePicker(BuildContext context) {
    final themeProvider = context.read<ThemeProvider>();
    showDialog<ThemeMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppStrings.selectTheme),
        children: ThemeMode.values.map((mode) {
          final isSelected = mode == themeProvider.themeMode;
          return ListTile(
            leading: Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? Theme.of(ctx).colorScheme.primary : null,
            ),
            title: Text(_getThemeLabel(mode)),
            onTap: () => Navigator.pop(ctx, mode),
          );
        }).toList(),
      ),
    ).then((selectedMode) {
      if (selectedMode != null) {
        themeProvider.setThemeMode(selectedMode);
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

  /// 备份恢复底部弹窗（对标原版 BackupConfigFragment 入口聚合）
  void _showBackupSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.backup),
                title: Text(AppStrings.backupData),
                subtitle: Text(AppStrings.backupDataDesc),
                onTap: () {
                  Navigator.pop(ctx);
                  _doBackup(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.restore),
                title: Text(AppStrings.restoreData),
                subtitle: const Text('从本地备份文件恢复全部数据'),
                onTap: () {
                  Navigator.pop(ctx);
                  _doRestore(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_sync),
                title: const Text('WebDAV 同步'),
                subtitle: const Text('连接测试、同步进度与自动同步配置'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.pushNamed(context, AppRoutes.webdavSettings);
                },
              ),
              const Divider(),
              // 延后项：Rust 契约暂不支持，占位禁用（后续版本支持）
              ListTile(
                leading: const Icon(Icons.filter_alt_off),
                title: const Text('恢复忽略项'),
                subtitle: const Text('后续版本支持'),
                enabled: false,
              ),
              ListTile(
                leading: const Icon(Icons.archive),
                title: const Text('导入旧版数据'),
                subtitle: const Text('后续版本支持'),
                enabled: false,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 本地备份（对标原版 BackupConfigFragment.backup）
  ///
  /// 读取备份路径（[CrashLogService.getBackupPath]，对应原版 AppConfig.backupPath），
  /// 无则选择目录并持久化；经 [BookApi.backup] 真实落盘，提示备份文件路径。
  Future<void> _doBackup(BuildContext context) async {
    setState(() => _backupLoading = true);
    try {
      final api = context.read<BookApi>();
      final crashLog = CrashLogService.instance;
      var dirPath = await crashLog.getBackupPath();
      if (dirPath == null || dirPath.isEmpty) {
        final picked = await FilePicker.platform.getDirectoryPath();
        if (picked == null) return; // 用户取消选择
        dirPath = picked;
        await crashLog.setBackupPath(dirPath);
      }
      final filePath = await api.backup(dirPath);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppStrings.backupSuccess}：$filePath')),
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

  /// 本地恢复（对标原版 BackupConfigFragment.restoreFromLocal）
  ///
  /// 选择备份文件后经 [BookApi.restore] 全量恢复（书源/RSS 源/书籍/替换规则/HTTP TTS），
  /// 并刷新书架。
  Future<void> _doRestore(BuildContext context) async {
    setState(() => _restoreLoading = true);
    final api = context.read<BookApi>();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'zip'],
      );
      final backupPath = result?.files.single.path;
      if (backupPath == null) return; // 用户取消选择

      await api.restore(backupPath);
      if (context.mounted) {
        context.read<BookshelfProvider>().loadBooks();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(AppStrings.restoreSuccess)));
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

  /// 导出应用日志（对标原版 BackupConfigFragment menu_log）
  ///
  /// 经 [CrashLogService.exportLogsToFile] 聚合日志为临时文件，调用系统分享。
  Future<void> _exportLogs() async {
    try {
      final path = await CrashLogService.instance.exportLogsToFile();
      if (!mounted) return;
      if (path == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂无可导出的日志')));
        return;
      }
      await Share.shareXFiles([XFile(path)], subject: 'Legado 应用日志');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出日志失败: $e')));
      }
    }
  }
}
