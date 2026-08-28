import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../routes.dart';
import '../services/auto_task_scheduler.dart';
import '../providers/providers.dart';
import '../providers/theme/theme_notifier.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';

/// 我的页面（枢纽菜单）
///
/// 对标 Android 原版「我的」页（`fragment_my_config.xml` + `pref_main.xml`）：
/// - 顶部：书源管理 / 定时任务 / 运行定时任务 / TXT 目录规则 / 替换净化 /
///   字典规则 / 主题模式 / Web 服务 / MCP 服务
/// - 「设置」分组：备份与恢复 / 主题设置 / 其他设置
/// - 「其他」分组：书签 / 阅读记录 / 文件管理 / 关于 / 退出
///
/// 视觉：apple-ui-designer — iOS 分组 inset 列表、系统感图标色块、克制分隔。
///
/// — UI 子代理 + UI ｜ 2026-08-13
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // 服务开关（对标 pref_main SwitchPreference）
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
      if (_autoTaskService) {
        AutoTaskScheduler.instance.refresh();
      }
    } catch (_) {
      // 首启无配置时静默失败，保持默认关
    }
  }

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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Web 服务切换失败: $e')));
    } finally {
      if (mounted) setState(() => _webServiceBusy = false);
    }
  }

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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('MCP 服务切换失败: $e')));
    } finally {
      if (mounted) setState(() => _mcpServiceBusy = false);
    }
  }

  Future<void> _toggleAutoTaskService(bool v) async {
    setState(() => _autoTaskService = v);
    try {
      await ref
          .read(bookApiProvider)
          .setConfig('autoTaskService', v ? 'true' : 'false');
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
    // [MD3 LargeTitle] 主 Tab 根页可折叠大标题（UI_MD3_PLAN.md Batch 1）
    return Scaffold(
      body: LegadoLargeTitleScroll(
        title: Text(AppStrings.my),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: '帮助',
            onPressed: _showHelp,
          ),
        ],
        body: IosGroupedBody(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              // ===== 顶部管理入口（对标 pref_main 顶层项，文案对齐 values-zh）=====
              IosGroup(
                separatorIndent: 62,
                children: [
                  IosListTile(
                    icon: Icons.library_books,
                    title: '书源管理',
                    subtitle: '新建、导入、编辑或管理书源',
                    showDisclosure: true,
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.sources),
                  ),
                  IosListTile(
                    icon: Icons.schedule,
                    title: '定时任务',
                    subtitle: '管理按计划执行的 JavaScript 任务',
                    showDisclosure: true,
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.autoTasks),
                  ),
                  SwitchListTile(
                    secondary: Icon(
                      Icons.autorenew,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: const Text('运行定时任务'),
                    subtitle: const Text('重启后保留计划；Android 可能延后实际执行时间'),
                    value: _autoTaskService,
                    onChanged: _toggleAutoTaskService,
                  ),
                  IosListTile(
                    icon: Icons.toc,
                    title: 'TXT 目录规则',
                    subtitle: '配置 TXT 目录规则',
                    showDisclosure: true,
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.txtTocRules),
                  ),
                  IosListTile(
                    icon: Icons.find_replace,
                    title: '替换净化',
                    subtitle: '配置替换净化规则',
                    showDisclosure: true,
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.replaceRules),
                  ),
                  IosListTile(
                    icon: Icons.translate,
                    title: '字典规则',
                    subtitle: '配置字典规则',
                    showDisclosure: true,
                    onTap: () => Navigator.pushNamed(context, AppRoutes.dict),
                  ),
                  IosListTile(
                    icon: Icons.brightness_6,
                    title: '主题模式',
                    subtitle: '选择主题模式',
                    value: _themeModeLabel(themeMode),
                    showDisclosure: true,
                    onTap: () => _showThemePicker(context),
                  ),
                  SwitchListTile(
                    secondary: _webServiceBusy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            Icons.language,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                    title: const Text('Web 服务'),
                    subtitle: Text(
                      _webService && _webServiceStatus.isNotEmpty
                          ? _webServiceStatus
                          : '用浏览器写源或看书',
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
                        : Icon(
                            Icons.cable,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                    title: const Text('MCP 服务'),
                    subtitle: Text(
                      _mcpService && _mcpPort > 0
                          ? '端口 $_mcpPort（带令牌保护的书源开发工具）'
                          : '带令牌保护的书源开发工具',
                    ),
                    value: _mcpService,
                    onChanged: _mcpServiceBusy ? null : _toggleMcpService,
                  ),
                ],
              ),

              // ===== 设置分组 =====
              const IosSectionHeader('设置'),
              IosGroup(
                separatorIndent: 62,
                children: [
                  IosListTile(
                    icon: Icons.backup,
                    title: '备份与恢复',
                    subtitle: 'WebDav 设置/导入旧版本数据',
                    showDisclosure: true,
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.webdavSettings),
                  ),
                  IosListTile(
                    icon: Icons.palette_outlined,
                    title: '主题设置',
                    subtitle: '与界面/颜色相关的一些设置',
                    showDisclosure: true,
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.themeConfig),
                  ),
                  IosListTile(
                    icon: Icons.tune,
                    title: '其他设置',
                    subtitle: '与功能相关的一些设置',
                    showDisclosure: true,
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.otherSettings),
                  ),
                ],
              ),

              // ===== 其他分组 =====
              const IosSectionHeader('其他'),
              IosGroup(
                separatorIndent: 62,
                children: [
                  IosListTile(
                    icon: Icons.bookmark,
                    title: '书签',
                    subtitle: '所有书签',
                    showDisclosure: true,
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.bookmarks),
                  ),
                  IosListTile(
                    icon: Icons.history,
                    title: '阅读记录',
                    subtitle: '阅读时间记录',
                    showDisclosure: true,
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.readRecord),
                  ),
                  IosListTile(
                    icon: Icons.folder_outlined,
                    title: '文件管理',
                    subtitle: '管理私有文件夹的文件',
                    showDisclosure: true,
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.fileManage),
                  ),
                  IosListTile(
                    icon: Icons.info_outline,
                    title: '关于',
                    showDisclosure: true,
                    onTap: () => Navigator.pushNamed(context, AppRoutes.about),
                  ),
                  IosListTile(
                    icon: Icons.exit_to_app,
                    title: '退出',
                    onTap: _confirmExit,
                  ),
                ],
              ),
            ],
          ),
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

  /// 帮助（对标 main_my.xml → showHelp("appHelp")）
  void _showHelp() {
    showHelp(context, HelpAssets.appHelp);
  }

  void _showThemePicker(BuildContext context) {
    final themeNotifier = ref.read(themeNotifierProvider.notifier);
    final currentMode = ref.read(themeNotifierProvider).themeMode;
    showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    AppStrings.selectTheme,
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
              ),
              ...ThemeMode.values.map((mode) {
                final selected = mode == currentMode;
                return ListTile(
                  leading: Icon(
                    selected ? Icons.check_circle : Icons.circle_outlined,
                    color: selected ? Theme.of(ctx).colorScheme.primary : null,
                  ),
                  title: Text(_getThemeLabel(mode)),
                  onTap: () => Navigator.pop(ctx, mode),
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
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
}
