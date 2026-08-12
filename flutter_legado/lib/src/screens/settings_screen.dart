import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';

import '../l10n/app_strings.dart';
import '../models/book.dart';
import '../routes.dart';
import '../services/auto_task_scheduler.dart';
import '../services/book_api.dart';
import '../services/crash_log_service.dart';
import '../services/settings_service.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/providers.dart';
import '../providers/theme/theme_notifier.dart';
import '../theme/app_colors.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/restore_ignore_dialog.dart';

/// 我的页面（枢纽菜单）
///
/// 对标 Android 原版「我的」页（`fragment_my_config.xml` + `pref_main.xml`）：以菜单入口形式聚合各管理功能与子设置页。
/// - 顶部：书源管理 / 定时任务 / 定时任务服务 / TXT 目录规则 / 替换净化 / 词典规则 / 主题模式 / Web 服务 / MCP 服务
/// - 「设置」分组：备份恢复 / 主题设置 / 其他设置
/// - 「其他」分组：书签 / 阅读记录 / 文件管理 / 关于 / 退出
///
/// 子设置页拆分至独立页面：
/// - 主题设置 → [AppRoutes.themeConfig]
/// - 其他设置（语言/阅读默认/网络/缓存）→ [AppRoutes.otherSettings]
/// - 备份恢复 → 底部弹窗（备份/恢复/WebDAV 同步），WebDAV 详情 → [AppRoutes.webdavSettings]
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _backupLoading = false;
  bool _restoreLoading = false;
  bool _importOldLoading = false;
  // 服务开关（对标 pref_main SwitchPreference）
  // [UI-fix v2.0.2 | 2026-08-06] Web 服务开关接通 Rust server_start/server_stop，
  // 状态持久化于 config 键 webService — Qoder
  // [UI-fix v2.0.3 | 2026-08-08] 定时服务开关联动应用内调度器（Task #146） — Qoder
  bool _autoTaskService = false;
  bool _webService = false;
  bool _mcpService = false;
  bool _webServiceBusy = false;
  bool _mcpServiceBusy = false;
  String _webServiceStatus = '';
  int _mcpPort = 0;

  @override
  void initState() {
    super.initState();
    _initServiceStates();
  }

  /// 恢复服务开关持久化状态（config 键 webService / autoTaskService / mcpPort）
  Future<void> _initServiceStates() async {
    final api = ref.read(bookApiProvider);
    try {
      final web = await api.getConfig('webService');
      final autoTask = await api.getConfig('autoTaskService');
      final mcpPortRaw = await api.getConfig('mcpPort');
      final mcpPort = int.tryParse(mcpPortRaw ?? '') ?? 0;
      if (!mounted) return;
      setState(() {
        _webService = web == 'true';
        _autoTaskService = autoTask == 'true';
        _mcpPort = mcpPort;
        _mcpService = mcpPort > 0;
      });
      if (_webService) {
        final status = await api.getServerStatus();
        if (!mounted) return;
        setState(() => _webServiceStatus = status);
      }
      // [UI-fix v2.0.3 | 2026-08-08] 持久化开关加载恢复：开启时重算调度
      //（对齐原版启动时按 PreferKey.autoTaskService 决定 refresh/cancelAll） — Qoder
      if (_autoTaskService) {
        AutoTaskScheduler.instance.refresh();
      }
    } catch (_) {
      // 首启无配置时静默失败，保持默认关
    }
  }

  /// Web 服务开关（对标原版 WebServiceActivity：启动/停止 legado-server）
  ///
  /// 经 [BookApi.startServer]/[BookApi.stopServer] 委托 Rust 真实启停，
  /// 开关状态持久化于 config 键 `webService`。
  Future<void> _toggleWebService(bool v) async {
    if (_webServiceBusy) return;
    setState(() => _webServiceBusy = true);
    final api = ref.read(bookApiProvider);
    try {
      if (v) {
        await api.startServer();
        final status = await api.getServerStatus();
        await api.setConfig('webService', 'true');
        if (!mounted) return;
        setState(() {
          _webService = true;
          _webServiceStatus = status;
        });
      } else {
        await api.stopServer();
        await api.setConfig('webService', 'false');
        if (!mounted) return;
        setState(() {
          _webService = false;
          _webServiceStatus = '';
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Web 服务切换失败: $e')),
      );
    } finally {
      if (mounted) setState(() => _webServiceBusy = false);
    }
  }

  /// MCP 独立服务开关（契约 §2.22.5 `setMcpPort`）
  ///
  /// 开启：端口默认 1236（对齐原版 AppConfig.mcpPort）；关闭：port=0 停服。
  /// 细调端口见「其他设置」→ MCP 服务端口。
  Future<void> _toggleMcpService(bool v) async {
    if (_mcpServiceBusy) return;
    setState(() => _mcpServiceBusy = true);
    final api = ref.read(bookApiProvider);
    try {
      if (v) {
        final port = _mcpPort > 0 ? _mcpPort : 1236;
        await api.setMcpPort(port);
        if (!mounted) return;
        setState(() {
          _mcpService = true;
          _mcpPort = port;
        });
      } else {
        await api.setMcpPort(0);
        if (!mounted) return;
        setState(() {
          _mcpService = false;
          _mcpPort = 0;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('MCP 服务切换失败: $e')),
      );
    } finally {
      if (mounted) setState(() => _mcpServiceBusy = false);
    }
  }

  /// 定时任务服务开关（对标原版 AutoTaskService SwitchPreference）
  ///
  /// [UI-fix v2.0.3 | 2026-08-08] 应用内调度器联动（Task #146）：开启 →
  /// 启动调度；关闭 → 取消 Timer（对齐原版 MyFragment 开关分支
  /// refresh/cancelAll）。真后台调度需 WorkManager，不在应用内范围。 — Qoder
  Future<void> _toggleAutoTaskService(bool v) async {
    setState(() => _autoTaskService = v);
    try {
      await ref.read(bookApiProvider).setConfig(
        'autoTaskService',
        v ? 'true' : 'false',
      );
    } catch (_) {
      // 持久化失败不阻断 UI 切换
    }
    if (v) {
      AutoTaskScheduler.instance.refresh();
    } else {
      AutoTaskScheduler.instance.cancelAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeNotifierProvider).themeMode;
    return Scaffold(
      appBar: AppBar(
        title: Text(AppStrings.my),
        actions: [
          // 对标原版 main_my.xml：顶栏帮助入口（ic_help → HelpActivity）
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: '帮助',
            onPressed: _showHelp,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          // ===== 顶部管理入口（对标 pref_main 顶层项）=====
          IosGroup(
            separatorIndent: 62,
            children: [
              IosListTile(
                icon: Icons.library_books,
                iconBackground: AppColors.iosBlueLight,
                title: AppStrings.sourceManagement,
                subtitle: '书源管理、启用、禁用与排序',
                showDisclosure: true,
                onTap: () => Navigator.pushNamed(context, AppRoutes.sources),
              ),
              IosListTile(
                icon: Icons.schedule,
                iconBackground: AppColors.iosOrangeLight,
                title: '定时任务',
                subtitle: '管理自动刷新和备份任务',
                showDisclosure: true,
                onTap: () => Navigator.pushNamed(context, AppRoutes.autoTasks),
              ),
              // [UI-fix v2.0.3 | 2026-08-08] 定时服务应用内调度器已接通（Task #146）；
              // 真后台（进程被杀后仍调度）需 WorkManager，保留诚实标注 — Qoder
              // 真后台需 WorkManager/前台服务；本轮保持应用内调度 + 诚实标注
              SwitchListTile(
                secondary: const Icon(Icons.autorenew),
                title: const Text('定时任务服务'),
                subtitle: const Text(
                  '仅前台应用内调度；退出或杀进程后不执行（真后台未移植）',
                ),
                value: _autoTaskService,
                onChanged: _toggleAutoTaskService,
              ),
              IosListTile(
                icon: Icons.toc,
                iconBackground: AppColors.iosTealLight,
                title: 'TXT 目录规则',
                subtitle: '配置 TXT 书籍目录解析规则',
                showDisclosure: true,
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.txtTocRules),
              ),
              IosListTile(
                icon: Icons.find_replace,
                iconBackground: AppColors.iosRedLight,
                title: '替换净化',
                subtitle: '管理阅读内容替换规则',
                showDisclosure: true,
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.replaceRules),
              ),
              IosListTile(
                icon: Icons.translate,
                iconBackground: AppColors.iosIndigoLight,
                title: '词典规则',
                subtitle: '配置词典查询规则',
                showDisclosure: true,
                onTap: () => Navigator.pushNamed(context, AppRoutes.dict),
              ),
              IosListTile(
                icon: Icons.brightness_6,
                iconBackground: AppColors.iosPurpleLight,
                title: AppStrings.themeMode,
                value: _themeModeLabel(themeMode),
                showDisclosure: true,
                onTap: () => _showThemePicker(context),
              ),
              // [UI-fix v2.0.2 | 2026-08-06] Web 服务开关接通 Rust server_start/server_stop — Qoder
              SwitchListTile(
                secondary: _webServiceBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.language),
                title: const Text('Web 服务'),
                subtitle: Text(
                  _webService && _webServiceStatus.isNotEmpty
                      ? 'Web 书架服务：$_webServiceStatus'
                      : 'Web 书架服务',
                ),
                value: _webService,
                onChanged: _webServiceBusy ? null : _toggleWebService,
              ),
              SwitchListTile(
                secondary: _mcpServiceBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cable),
                title: const Text('MCP 服务'),
                subtitle: Text(
                  _mcpService && _mcpPort > 0
                      ? '独立 MCP 端口 $_mcpPort（细调见其他设置）'
                      : '独立 MCP 工具服务（默认端口 1236）',
                ),
                value: _mcpService,
                onChanged: _mcpServiceBusy ? null : _toggleMcpService,
              ),
            ],
          ),

          // ===== 设置分组（对标 pref_main「设置」PreferenceCategory）=====
          const IosSectionHeader('设置'),
          IosGroup(
            separatorIndent: 62,
            children: [
              IosListTile(
                icon: Icons.backup,
                iconBackground: AppColors.iosGreenLight,
                title: '备份恢复',
                subtitle: '备份/恢复数据与 WebDAV 同步',
                trailing: (_backupLoading || _restoreLoading || _importOldLoading)
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                showDisclosure: !(_backupLoading ||
                    _restoreLoading ||
                    _importOldLoading),
                onTap: (_backupLoading || _restoreLoading || _importOldLoading)
                    ? null
                    : () => _showBackupSheet(context),
              ),
              IosListTile(
                icon: Icons.palette_outlined,
                iconBackground: AppColors.iosPinkLight,
                title: '主题设置',
                subtitle: '主题模式、字体、行距、背景色',
                showDisclosure: true,
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.themeConfig),
              ),
              IosListTile(
                icon: Icons.tune,
                iconBackground: AppColors.iosBrownLight,
                title: '其他设置',
                subtitle: '语言、阅读默认、网络、缓存',
                showDisclosure: true,
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.otherSettings),
              ),
            ],
          ),

          // ===== 其他分组（对标 pref_main「其他」PreferenceCategory）=====
          IosSectionHeader(AppStrings.otherSettings),
          IosGroup(
            separatorIndent: 62,
            children: [
              IosListTile(
                icon: Icons.bookmark,
                iconBackground: AppColors.iosOrangeLight,
                title: '书签',
                subtitle: '查看和管理所有书签',
                showDisclosure: true,
                onTap: () => Navigator.pushNamed(context, AppRoutes.bookmarks),
              ),
              IosListTile(
                icon: Icons.history,
                iconBackground: AppColors.iosTealLight,
                title: '阅读记录',
                subtitle: '查看阅读时长书单',
                showDisclosure: true,
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.readRecord),
              ),
              IosListTile(
                icon: Icons.folder_outlined,
                iconBackground: AppColors.iosBrownLight,
                title: '文件管理',
                subtitle: '浏览与管理应用文件',
                showDisclosure: true,
                // 对标原版 FileManageActivity 入口
                onTap: () => Navigator.pushNamed(context, AppRoutes.fileManage),
              ),
              IosListTile(
                icon: Icons.info,
                iconBackground: AppColors.iosBlueLight,
                title: AppStrings.aboutSettings,
                showDisclosure: true,
                onTap: () => Navigator.pushNamed(context, AppRoutes.about),
              ),
              IosListTile(
                icon: Icons.exit_to_app,
                iconBackground: AppColors.iosRedLight,
                title: '退出',
                onTap: _confirmExit,
              ),
              IosListTile(
                icon: Icons.bug_report,
                iconBackground: AppColors.iosYellowLight,
                // [审计修复 §3.3] 黑色图标为亮黄背景的固定对比搭配
                //（iconBackground 亮暗模式均为亮黄，iOS 惯例黄底黑字），保留 — Qoder
                iconColor: AppColors.black,
                title: '导出日志',
                subtitle: '分享应用日志文件用于问题诊断',
                onTap: _exportLogs,
              ),
            ],
          ),
        ],
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

  /// 帮助对话框（对标原版 HelpActivity 入口）
  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('帮助'),
        content: const SingleChildScrollView(
          child: Text(
            '欢迎使用 Legado 阅读。\n\n'
            '· 书架：顶栏菜单可添加本地书籍、切换书架布局与管理分组；'
            '长按书籍可编辑、分享或删除。\n'
            '· 发现：展开书源查看发现分类，长按书源可编辑或删除。\n'
            '· 订阅：顶栏可进入历史、收藏与订阅设置，长按订阅源可删除。\n'
            '· 备份：「备份恢复」支持本地备份/恢复与 WebDAV 同步。\n\n'
            '详细文档请访问 Legado 官方帮助页面。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 主题模式选择（对标 pref_main themeMode NameListPreference）
  ///
  /// 选中后经 [ThemeNotifier.setThemeMode] 全局实时生效并持久化。
  void _showThemePicker(BuildContext context) {
    final themeNotifier = ref.read(themeNotifierProvider.notifier);
    final currentMode = ref.read(themeNotifierProvider).themeMode;
    showDialog<ThemeMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppStrings.selectTheme),
        children: ThemeMode.values.map((mode) {
          final isSelected = mode == currentMode;
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
        themeNotifier.setThemeMode(selectedMode);
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
              ListTile(
                leading: const Icon(Icons.filter_list_outlined),
                title: const Text('恢复忽略项'),
                subtitle: const Text('恢复时跳过勾选项（当前仅本地书籍生效）'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showRestoreIgnore(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('导入旧版数据'),
                subtitle: const Text('选择含 myBookShelf 等文件的阅读 2.x 备份目录'),
                onTap: () {
                  Navigator.pop(ctx);
                  _doImportOldData(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 恢复忽略项（对齐 BackupConfigFragment.backupIgnore）
  Future<void> _showRestoreIgnore(BuildContext context) async {
    final settings = SettingsService();
    final initial = await settings.getRestoreIgnoreConfig();
    if (!context.mounted) return;
    final result = await showDialog<Map<String, bool>>(
      context: context,
      builder: (ctx) => RestoreIgnoreDialog(initial: initial),
    );
    if (result == null) return;
    await settings.saveRestoreIgnoreConfig(result);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存恢复忽略项')),
      );
    }
  }

  /// 本地备份（对标原版 BackupConfigFragment.backup）
  ///
  /// 读取备份路径（[CrashLogService.getBackupPath]，对应原版 AppConfig.backupPath），
  /// 无则选择目录并持久化；经 [BookApi.backup] 真实落盘，提示备份文件路径。
  Future<void> _doBackup(BuildContext context) async {
    setState(() => _backupLoading = true);
    try {
      final api = ref.read(bookApiProvider);
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
  /// 选择备份文件后经 [BookApi.restore] 全量恢复；若勾选忽略本地书，
  /// 先按 [SettingsService] 配置过滤备份 JSON 中的本地书再恢复。
  Future<void> _doRestore(BuildContext context) async {
    setState(() => _restoreLoading = true);
    final api = ref.read(bookApiProvider);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'zip'],
      );
      final backupPath = result?.files.single.path;
      if (backupPath == null) return; // 用户取消选择

      var pathToRestore = backupPath;
      final ignore = await SettingsService().getRestoreIgnoreConfig();
      if (ignore['localBook'] == true &&
          backupPath.toLowerCase().endsWith('.json')) {
        pathToRestore = await _backupPathSkippingLocalBooks(backupPath);
      }

      await api.restore(pathToRestore);
      if (context.mounted) {
        ref.read(bookshelfNotifierProvider.notifier).refresh();
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

  /// 导入旧版数据（对齐 BackupConfigFragment.restoreOld / ImportOldData.importUri）
  ///
  /// 选择目录后调用 [BookApi.importOldData]，展示 messages 汇总反馈。
  Future<void> _doImportOldData(BuildContext context) async {
    setState(() => _importOldLoading = true);
    try {
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
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入旧版数据失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _importOldLoading = false);
    }
  }

  /// 生成去掉本地书的临时备份 JSON（对齐 Restore 中 ignoreLocalBook）
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

  /// 退出应用（对标 pref_main exit）
  Future<void> _confirmExit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出'),
        content: const Text('确定退出阅读吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.confirm),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await SystemNavigator.pop();
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
