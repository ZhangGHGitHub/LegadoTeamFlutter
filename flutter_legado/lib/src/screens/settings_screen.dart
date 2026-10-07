import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../routes.dart';
import '../constants/pref_keys.dart';
import '../utils/error_message.dart';
import '../services/auto_task_scheduler.dart';
import '../services/web_keep_alive_service.dart';
import '../providers/providers.dart';
import '../providers/theme/theme_notifier.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import '../widgets/bottom_sheet_widget.dart';

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

  /// iOS 后台保活不可用（start 失败回退「仅前台可用」时，卡片副题提示）
  bool _webKeepAliveUnavailable = false;
  String _webServiceStatus = '';
  int _mcpPort = 0;

  /// Web 书源访问令牌（config:jsSourceApiToken）是否已配置。
  ///
  /// [2026-10-06 iOS 实测修复] MCP 独立服务的 Rust 启动守卫要求该配置非空
  /// （`mcp_start_internal`，rust/legado-ffi/src/api/server_api.rs），未配置时
  /// 开关必然失败——卡片副题提前给出「需先配置」提示，用户不必先点开关
  /// 撞错误。默认 true（乐观值）：配置读取完成前不误报「未配置」。
  bool _mcpTokenConfigured = true;

  /// 端口越界兜底日志只记一次（防手改 prefs 反复刷日志）
  bool _webPortFallbackLogged = false;

  @override
  void initState() {
    super.initState();
    _initServiceStates();
  }

  /// 恢复服务开关持久化状态（config 键 webService / autoTaskService / mcpPort）
  ///
  /// [iOS 特性 | 2026-10-07 保活批核实] `webService=true` 只是 UI 镜像态
  /// （对齐原版：原版无开机/启动自拉起，见调研报告 §二.4）：App 进程重启后
  /// 进程内 Rust server 并不存在，此处也**不**自动 `startServer`、**不**启动
  /// 后台保活（没有服务可保；保活生命周期严格绑定 startServer 成功）。
  Future<void> _initServiceStates() async {
    final api = ref.read(bookApiProvider);
    try {
      final web = await api.getConfig('webService');
      final autoTask = await api.getConfig('autoTaskService');
      final mcpPortRaw = await api.getConfig('mcpPort');
      final mcpToken = await api.getConfig('jsSourceApiToken');
      final mcpPort = int.tryParse(mcpPortRaw ?? '') ?? 0;
      if (!mounted) return;
      setState(() {
        _webService = web == 'true';
        _autoTaskService = autoTask == 'true';
        _mcpPort = mcpPort;
        _mcpService = mcpPort > 0;
        _mcpTokenConfigured = (mcpToken ?? '').trim().isNotEmpty;
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

  /// 读取「其他设置 → Web 服务端口」配置（PrefKeys.webPort，默认 1122）
  ///
  /// [2026-10-06 缺陷修复] 对齐原版 `WebService.kt:244`
  /// `var port = getPrefInt(PreferKey.webPort, 1122)` → `:215 HttpServer(port)`：
  /// 启动时使用用户配置端口。此前本页调 `api.startServer()` 不传端口，恒用
  /// 默认 1122，使「其他设置」中的端口配置形同虚设。
  ///
  /// 读取写法对齐 other_settings_screen.dart 既有 `getIntPref`（同键同默认值；
  /// getIntPref 内部已对异常回落默认值）。越界兜底：设置页已校验
  /// 1024~60000（other_settings_screen.dart `_showWebPortDialog`），此处仅为
  /// 防手改 prefs 绕过校验导致启动失败，越界回落 1122 并只记一次日志。
  Future<int> _readWebPort() async {
    const defaultPort = 1122;
    final port = await ref
        .read(settingsProvider)
        .getIntPref(PrefKeys.webPort, defaultValue: defaultPort);
    if (port < 1024 || port > 60000) {
      if (!_webPortFallbackLogged) {
        _webPortFallbackLogged = true;
        debugPrint('Web 服务端口配置越界（$port），回落默认 $defaultPort');
      }
      return defaultPort;
    }
    return port;
  }

  /// Web 服务开关（对标原版 pref_main SwitchPreference）
  ///
  /// [iOS Web 服务后台保活 | 2026-10-07 用户批准方案 C+A] iOS 无前台服务，
  /// 平台等价物是 `UIBackgroundModes: audio` + 近静音音频会话（对应原版
  /// WakeLock 的「防睡眠」目的，见 docs/WEB_SERVICE_KEEPALIVE_SURVEY_20261007.md）：
  /// 启动成功后接[WebKeepAliveService.start]，停止成功后接 stop，让 App
  /// 退后台/锁屏时局域网浏览器仍可访问。保活启动失败仅记日志并回退
  /// 「仅前台可用」（卡片副题提示），不阻断服务开关。
  ///
  /// Android 侧本仓库虽有前台服务机制（platform_channel），但 Web 服务当前
  /// 未接入保活：`webServiceWakeLock` 偏好仅持久化未接线，既有前台服务仅用于
  /// 视频/听书播放（VideoPlayService / PlaybackForegroundService），故 Android
  /// 后台存活同样不作保证（如实登记，未夸大；本批按红线不动 Android）。
  Future<void> _toggleWebService(bool v) async {
    if (_webServiceBusy) return;
    setState(() => _webServiceBusy = true);
    final api = ref.read(bookApiProvider);
    try {
      if (v) {
        // 启动端口取用户配置（PrefKeys.webPort），越界按 1122 兜底
        final port = await _readWebPort();
        await api.startServer(port: port);
        final status = await api.getServerStatus();
        // 服务成功即接保活（iOS 专用；其它平台 no-op）
        final keepAlive = await WebKeepAliveService.instance.start();
        await api.setConfig('webService', 'true');
        if (!mounted) return;
        setState(() {
          _webService = true;
          _webServiceStatus = status;
          _webKeepAliveUnavailable = keepAlive == WebKeepAliveStatus.failed;
        });
      } else {
        await api.stopServer();
        // 服务停止必须同步停保活（否则静音音轨会让进程继续存活）
        await WebKeepAliveService.instance.stop();
        await api.setConfig('webService', 'false');
        if (!mounted) return;
        setState(() {
          _webService = false;
          _webServiceStatus = '';
          _webKeepAliveUnavailable = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      // [2026-10-06 iOS 实测修复] 裸插值 $e 对 Rust BridgeError 只会显示
      // "Instance of 'BridgeError'"，改用统一提取器暴露 Rust 侧可读原因
      // （如「数据库未初始化」「端口绑定失败」）。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Web 服务切换失败: ${errorMessage(e)}')),
      );
    } finally {
      if (mounted) setState(() => _webServiceBusy = false);
    }
  }

  /// MCP 卡片副题：运行中显示端口；未运行且未配置访问令牌时给出前置条件
  /// 提示（见 [_mcpTokenConfigured]）——「需先配置什么」直接写在卡片上，
  /// 而不是让用户点开关撞「Instance of BridgeError」后再猜。
  String get _mcpServiceSubtitle {
    if (_mcpService && _mcpPort > 0) {
      return '端口 $_mcpPort（带令牌保护的书源开发工具）';
    }
    if (!_mcpTokenConfigured) {
      return '需先配置「Web 书源访问令牌」（设置 → 高级 → 其他设置）';
    }
    return '带令牌保护的书源开发工具';
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
      // [2026-10-06 iOS 实测修复] 同 Web 开关：BridgeError 取 message，
      // 暴露 Rust 侧真实失败原因（token 未配置 / 端口占用 / 端口越界）。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('MCP 服务切换失败: ${errorMessage(e)}')),
      );
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

  /// [B2-C2 2-10 | 全栈工程师] Web 服务大卡（图标 + 绿 accent）
  ///
  /// 对齐 ref 12 原版「我的」页 Web 服务大卡形态：48dp 圆角图标槽
  /// （language 图标）+ 标题/状态副题 + 右端 Switch（busy 时 spinner）；
  /// 开启态卡片描边与图标槽转绿（iOS 系统绿语义色）。
  Widget _buildWebServiceCard(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // [2026-10-06 登记待修 → 本批已修复] 原「iOS 标记暂不可用」门控（副题
    // 「暂不可用，将在后续版本修复」+ Switch 禁用）已整体移除：根因见
    // docs/IOS_WEB_SERVICE_ROOT_CAUSE_SURVEY_20261006.md（缺陷 A 绑定
    // 127.0.0.1、缺陷 B bind 失败假成功、缺陷 C 缺本地网络用途描述），
    // 三处已随本批修复，iOS 与其他平台恢复统一形态。
    // [A-5 | 2026-09-20 用户裁决] AppColors 整体删除，本卡启用态 accent
    // 改 MD3 scheme 取值。槽位映射（保持"开启态强调"视觉语义）：
    //   AppColors.iosGreenLight / iosGreenDark（iOS 系统绿，按亮暗双取值）
    //     → cs.primary（MD3 主色，随当前 13 套调色板亮/暗各自生效）
    // 对齐参考版 SwitchSettingItem：开关 checked 色即 colorScheme.primary，
    // 同卡内 Switch 与卡描边/图标槽同源，主题切换无残留绿。
    final green = cs.primary;
    final enabled = _webService;
    final baseSubtitle = enabled && _webServiceStatus.isNotEmpty
        ? _webServiceStatus
        : '用浏览器写源或看书';
    // [2026-10-07 保活批 | 方案 A 兜底] 保活启动失败 → 回退「仅前台可用」，
    // 仅副题提示（对齐需求：不阻断服务、UI 主形态不变）。
    final subtitle = enabled && _webKeepAliveUnavailable
        ? '$baseSubtitle · 后台保活不可用，请保持 App 打开'
        : baseSubtitle;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: enabled ? green.withValues(alpha: 0.6) : cs.outlineVariant,
          width: enabled ? 1.5 : 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: enabled
                    ? green.withValues(alpha: 0.15)
                    : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Symbols.language_rounded,
                size: 28,
                color: enabled ? green : cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Web 服务',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _webServiceBusy
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Switch(
                    value: _webService,
                    onChanged: _toggleWebService,
                  ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeNotifierProvider).themeMode;
    // [MD3 LargeTitle] 主 Tab 根页可折叠大标题（UI_MD3_PLAN.md Batch 1）
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      body: LegadoLargeTitleScroll(
        title: Text(AppStrings.my),
        actions: [
          IconButton(
            icon: const Icon(Symbols.help_rounded),
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
                    icon: Symbols.library_books_rounded,
                    title: '书源管理',
                    subtitle: '新建、导入、编辑或管理书源',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.sources),
                  ),
                  IosListTile(
                    icon: Symbols.schedule_rounded,
                    title: '定时任务',
                    subtitle: '管理按计划执行的 JavaScript 任务',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.autoTasks),
                  ),
                  SettingSwitchRow(
                    icon: Symbols.autorenew_rounded,
                    title: '运行定时任务',
                    subtitle: '重启后保留计划；Android 可能延后实际执行时间',
                    value: _autoTaskService,
                    onChanged: _toggleAutoTaskService,
                  ),
                  IosListTile(
                    icon: Symbols.toc_rounded,
                    title: 'TXT 目录规则',
                    subtitle: '配置 TXT 目录规则',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.txtTocRules),
                  ),
                  IosListTile(
                    icon: Symbols.find_replace_rounded,
                    title: '替换净化',
                    subtitle: '配置替换净化规则',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.replaceRules),
                  ),
                  IosListTile(
                    icon: Symbols.translate_rounded,
                    title: '字典规则',
                    subtitle: '配置字典规则',
                    onTap: () => Navigator.pushNamed(context, AppRoutes.dict),
                  ),
                  // [C2 批2 | full-stack-engineer + UI] 字典规则管理页入口
                  // （对齐原版 DictRuleActivity；「字典规则」仍进查询页）
                  IosListTile(
                    icon: Symbols.manage_search_rounded,
                    title: '规则管理',
                    subtitle: '管理字典规则（增删改、启停、排序、导入）',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.dictRule),
                  ),
                  IosListTile(
                    icon: Icons.sell_rounded,
                    title: '高亮标注',
                    subtitle: '自动高亮标注规则',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.highlightRules),
                  ),
                  IosListTile(
                    icon: Symbols.brightness_6_rounded,
                    title: '主题模式',
                    subtitle: '选择主题模式',
                    value: _themeModeLabel(themeMode),
                    onTap: () => _showThemePicker(context),
                  ),
                ],
              ),

              // [B2-C2 2-10 | 全栈工程师] Web 服务卡片化：图标+绿 accent 独立大卡
              //（对齐 ref 12「大卡带图标/绿acc」；_toggleWebService 语义不变）
              _buildWebServiceCard(context),

              IosGroup(
                separatorIndent: 62,
                children: [
                  SettingSwitchRow(
                    leading: _mcpServiceBusy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            Symbols.cable_rounded,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                    title: 'MCP 服务',
                    subtitle: _mcpServiceSubtitle,
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
                  // [UI_SYNC_REFACTOR S6 | 2026-09-08] 设置主页集中化：我的页
                  // 原备份与恢复/主题设置/其他设置三 tile 收敛为单一「设置」
                  // 入口（对齐参考版我的页「设置」项；各页经设置主页分组到达）
                  // — Qoder
                  IosListTile(
                    icon: Symbols.settings_rounded,
                    title: '设置',
                    subtitle: '外观 / 高级 / 阅读界面 / 备份 / 缓存',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.settingsHome),
                  ),
                ],
              ),

              // ===== 其他分组 =====
              const IosSectionHeader('其他'),
              IosGroup(
                separatorIndent: 62,
                children: [
                  IosListTile(
                    icon: Symbols.bookmark_rounded,
                    title: '书签',
                    subtitle: '所有书签',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.bookmarks),
                  ),
                  IosListTile(
                    icon: Symbols.history_rounded,
                    title: '阅读记录',
                    subtitle: '阅读时间记录',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.readRecord),
                  ),
                  // [UI_SYNC_REFACTOR S5 修 | 2026-09-08] 补「缓存管理」入口
                  //（对齐参考版我的页其它组；页面复用既有离线缓存页
                  // OfflineCacheScreen，此前入口仅在书架菜单「离线缓存」）— Qoder
                  IosListTile(
                    icon: Symbols.download_rounded,
                    title: '缓存管理',
                    subtitle: '书籍下载任务与缓存进度',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.offlineCache),
                  ),
                  IosListTile(
                    icon: Symbols.folder_rounded,
                    title: '文件管理',
                    subtitle: '管理私有文件夹的文件',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.fileManage),
                  ),
                  IosListTile(
                    icon: Symbols.info_rounded,
                    title: '关于',
                    onTap: () => Navigator.pushNamed(context, AppRoutes.about),
                  ),
                  IosListTile(
                    icon: Symbols.logout_rounded,
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
    // [统一壳 B2a] 自造壳迁移统一 AppBottomSheet（对齐参考版 AppModalBottomSheet
    // 语义；把手由主题 bottomSheetTheme.showDragHandle 统一提供）
    AppBottomSheet.show<ThemeMode>(
      context: context,
      title: AppStrings.selectTheme,
      children: [
        ...ThemeMode.values.map((mode) {
          final selected = mode == currentMode;
          return ListTile(
            leading: Icon(
              selected ? Symbols.check_circle_rounded : Symbols.radio_button_unchecked_rounded,
              color: selected ? Theme.of(context).colorScheme.primary : null,
            ),
            title: Text(_getThemeLabel(mode)),
            onTap: () => Navigator.pop(context, mode),
          );
        }),
        const SizedBox(height: 8),
      ],
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
