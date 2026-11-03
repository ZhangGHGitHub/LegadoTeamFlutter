import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_strings.dart';
import '../routes.dart';
import '../constants/pref_keys.dart';
import '../utils/error_message.dart';
import '../services/auto_task_scheduler.dart';
import '../services/web_keep_alive_service.dart';
import '../services/web_service_address_resolver.dart';
import '../services/web_service_foreground_service.dart';
import '../services/web_service_wake_lock_service.dart';
import '../providers/providers.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';

/// 我的页面（枢纽菜单）
///
/// [M1 我的页信息架构 | full-stack-engineer + UI | 2026-11-03]
/// 按 `docs/MY_PAGE_ALIGNMENT_PLAN_20261103.md` 与用户裁决对齐参考版
/// （`legado-with-MD3/.../ui/main/my/MyScreen.kt`），同时保留 Android 原版
/// （`pref_main.xml`）独有能力：
/// - 顶部无标题分组：Web 服务块（开关 + 运行地址 + 复制地址/在浏览器中打开）
/// - 「规则」组：书源管理 / 替换净化 / TXT 目录规则 / 字典规则 / 高亮标签规则
///   （原「规则管理」与「字典规则」合并为单入口，默认进管理页）
/// - 「服务与工具」组：定时任务 / 运行定时任务 / MCP 服务（原版能力保留区）
/// - 「其他」组：AI 聊天（占位）/ 设置 / 书签 / 阅读记录 / 缓存管理 /
///   文件管理 / 关于 / 退出
///
/// 主题模式快捷入口按参考版移除，统一从「设置 → 外观」进入。
///
/// 视觉：apple-ui-designer — iOS 分组 inset 列表、系统感图标色块、克制分隔。
/// [M2 我的页 | 2026-11-03] 对齐参考版 `MyScreen.kt` / `WebServiceSettingBlock`：
/// Web 服务改为无标题 `IosGroup` 内的 `SettingSwitchRow`（不再是 48dp 图标槽
/// 大卡），运行中操作行置于组外紧邻下方；规则/其他组图标按参考版
/// `Source/FindReplace/Rule/LibraryBooks/Sell/…/ExitToApp` 对齐。
///
/// — UI 子代理 + UI ｜ 2026-08-13
/// 修订：全栈工程师 + UI ｜ 2026-11-03（M1 信息架构 / M2 视觉对齐）
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  // 服务开关（对标 pref_main SwitchPreference）
  bool _autoTaskService = false;
  bool _webService = false;
  bool _mcpService = false;
  bool _webServiceBusy = false;
  bool _mcpServiceBusy = false;

  /// iOS 后台保活不可用（start 失败回退「仅前台可用」时，卡片副题提示）
  bool _webKeepAliveUnavailable = false;

  /// Android 通知权限未授予（批9b-6c 审查回修 P2）：
  /// FGS 仍运行、LAN 访问不受影响，仅前台通知不可见，卡片副题提示。
  bool _webNotificationDegraded = false;
  String _webServiceStatus = '';

  /// 运行中可访问地址（`http://<局域网IPv4>:<port>`；失败回落回环）。
  /// 由 [webServiceAddressResolverProvider] 解析，经 [_refreshWebAddress] 更新。
  String _webServiceAddress = '';
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
    // 批9b-6c 审查回修 P3：回到前台重新对账——系统可能在后台停止 FGS，
    // 而 Dart 镜像仍为运行中（需强制查询原生 isRunning）。
    WidgetsBinding.instance.addObserver(this);
    _initServiceStates();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 开关切换进行中跳过：避免与启动/停止流程并发改写 FGS 状态
    if (state == AppLifecycleState.resumed && !_webServiceBusy) {
      _reconcileWebForegroundOnResume();
    }
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
      // 批9b-6 边界回修：无论 webService 配置镜像真假都查询运行态——
      // 新引擎 Dart 状态归零、配置写失败等边界下原生锁仍可能持有；
      // 以实际 status 为准做唤醒锁对账（stopped → 释放一切遗留锁）。
      try {
        final status = await api.getServerStatus();
        if (!mounted) return;
        if (_webService) setState(() => _webServiceStatus = status);
        await _reconcileWebWakeLock(status);
        await _reconcileWebForeground(status);
        // [M1] 服务对账完成后再解析展示地址（UI 操作不阻断保活/前台服务）
        if (_webService && _isServerRunning(status)) {
          await _refreshWebAddress(status);
        }
      } catch (e) {
        // 状态查询失败（FFI 未初始化等）：保持现状，不下发唤醒锁/前台服务命令
        debugPrint('Web 服务状态查询失败（跳过唤醒锁/前台服务对账）：$e');
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

  /// 服务状态串是否为「运行中」
  ///
  /// RustApi.getServerStatus 统一返回 `running on port X` / `stopped`
  ///（见 rust_api_media_format.part.dart）。
  bool _isServerRunning(String status) =>
      status.trim().toLowerCase().startsWith('running');

  /// 解析并写入 Web 服务可访问地址（M1）
  ///
  /// 端口优先取状态串 `running on port X`（Rust 实际绑定端口），解析失败
  /// （异常状态串/旧实现）回落用户配置端口 [_readWebPort]。
  Future<void> _refreshWebAddress(String status) async {
    final address = await _resolveAddressForStatus(status);
    if (!mounted) return;
    setState(() => _webServiceAddress = address);
  }

  /// 按运行状态串解析地址；解析失败只记日志并返回空串——复制/打开按钮
  /// 随地址为空隐藏，不影响开关与唤醒锁/前台服务对账。
  Future<String> _resolveAddressForStatus(String status) async {
    try {
      final parsedPort = LanWebServiceAddressResolver.parsePort(status);
      final port = parsedPort ?? await _readWebPort();
      return await ref.read(webServiceAddressResolverProvider).resolve(port);
    } catch (e) {
      debugPrint('Web 服务访问地址解析失败（忽略）：$e');
      return '';
    }
  }

  /// 运行中地址展示文案
  ///
  /// [M1 复核 P3] 回落回环地址时标注「（本机）」：该地址只能在本机浏览器
  /// 访问，避免用户误以为局域网其他设备可用。复制/打开仍使用原始地址。
  String get _webServiceAddressLabel {
    final host = Uri.tryParse(_webServiceAddress)?.host ?? '';
    return host == LanWebServiceAddressResolver.loopbackHost
        ? '$_webServiceAddress（本机）'
        : _webServiceAddress;
  }

  /// 批9b-6 审查回修：按运行态对账进程级 Web 服务唤醒锁
  ///
  /// 原生锁为进程级持有，Activity/引擎重建后 Dart 状态归零但锁可能仍在：
  /// - 服务运行 + 偏好开 → 重新确认持有（原生 acquire 幂等）
  /// - 服务运行 + 偏好关 → 释放
  /// - 服务未运行 → 释放一切遗留锁
  Future<void> _reconcileWebWakeLock(String status) async {
    final keepAwake = await ref
        .read(settingsProvider)
        .getBoolPref(PrefKeys.webServiceWakeLock, defaultValue: false);
    if (_isServerRunning(status)) {
      await WebServiceWakeLockService.instance.onServiceStarted(
        keepAwake: keepAwake,
      );
    } else {
      await WebServiceWakeLockService.instance.onServiceStopped();
    }
  }

  /// 批9b-6c：按运行态对账 Android Web 服务前台服务（幂等）
  ///
  /// 9b-6 设备验收确认唤醒锁无法改变 `APP_BACKGROUND` 网络策略，需前台服务
  /// 把进程提升为可见前台（原版 `WebService` 同构，见
  /// [WebServiceForegroundService] 文档）。初始化/回前台对账：
  /// - 服务运行 → 确保前台服务也运行（先查原生 `isRunning`，已运行不重复拉起）
  ///   并刷新通知权限降级提示
  /// - 服务未运行 → 停掉可能遗留的前台服务（引擎重建 / 配置写失败边界）
  ///
  /// [forceQuery] 供 App 回到前台时强制查询原生状态（系统可能已停止 FGS，
  /// 而 Dart 镜像仍是 true，审查回修 P3）。
  ///
  /// 与唤醒锁完全解耦：不读 `webServiceWakeLock` 偏好，前台服务恒随 Web 服务
  /// 启停（唤醒锁仍由 [_reconcileWebWakeLock] 按原开关控制）。
  Future<void> _reconcileWebForeground(
    String status, {
    bool forceQuery = false,
  }) async {
    final foreground = WebServiceForegroundService.instance;
    if (_isServerRunning(status)) {
      await foreground.ensureStarted(forceQuery: forceQuery);
      final granted = await foreground.hasNotificationPermission();
      if (!mounted) return;
      setState(() => _webNotificationDegraded = !granted);
    } else {
      await foreground.stop();
      if (!mounted) return;
      setState(() => _webNotificationDegraded = false);
    }
  }

  /// App 回到前台时重新对账（审查回修 P3）
  ///
  /// 只查询 Rust server 运行态后交给 [_reconcileWebForeground]；查询失败
  /// （FFI 未初始化等）静默跳过，不影响用户操作。
  ///
  /// [M1 复核 P1-1 | 2026-11-03] 同时对账 UI 镜像：运行中刷新状态串并重新
  /// 解析地址（网卡/IP 可能在后台切换，如 Wi-Fi 漫游/热点变化），停止则清空
  /// 状态与地址，避免卡片长期展示已失效地址与复制/打开按钮。
  Future<void> _reconcileWebForegroundOnResume() async {
    try {
      final status = await ref.read(bookApiProvider).getServerStatus();
      if (!mounted) return;
      await _reconcileWebForeground(status, forceQuery: true);
      if (!mounted) return;
      if (_isServerRunning(status)) {
        setState(() => _webServiceStatus = status);
        await _refreshWebAddress(status);
      } else {
        setState(() {
          _webServiceStatus = '';
          _webServiceAddress = '';
        });
      }
    } catch (e) {
      debugPrint('回前台对账 Web 前台服务失败（忽略）：$e');
    }
  }

  /// 批9b-6c 审查回修 P2：启动后校验失败的回滚（best-effort，逐项容错）
  ///
  /// 顺序：撤前台服务 → 释放唤醒锁 → 停 Rust server。停 server 失败只记
  /// 日志——回滚本身已在错误路径，不能让二次失败覆盖对用户的原始提示。
  Future<void> _rollbackWebStart(Future<void> Function() stopServer) async {
    await WebServiceForegroundService.instance.stop();
    await WebServiceWakeLockService.instance.onServiceStopped();
    try {
      await stopServer();
    } catch (e) {
      debugPrint('Web 服务启动回滚停服失败（忽略）：$e');
    }
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
  /// [Android Web 服务前台服务 | 批9b-6c] Android 等价物是真实前台服务
  /// [WebServiceForegroundService]（原版 `WebService` 同构）：startServer
  /// 成功即 start、stopServer 成功即 stop、启动后状态异常回滚即 stop；
  /// **与唤醒锁偏好解耦**（唤醒锁只影响 CPU/Wi-Fi 休眠，无法改变息屏后的
  /// `APP_BACKGROUND` 网络策略，见 9b-6 验收报告）。
  ///
  /// [Android Web 服务唤醒锁 | 批9b-6] 对齐原版
  /// `WebService.kt:76,77-82,83-89,105-106,140-141,160-161`：偏好
  /// `webServiceWakeLock`（默认 false）开且服务运行 → 同时持
  /// `PARTIAL_WAKE_LOCK` 与 `WifiLock`（`WIFI_MODE_FULL_HIGH_PERF`，
  /// tag `legado:WebService`，acquire 无超时），服务停止 / 开关关 → release。
  /// 参考版 `legado-with-MD3/.../service/WebService.kt:68,69-74,75-81,92-93,133-134,145-146`
  /// 电源语义一致。Android 经 [WebServiceWakeLockService] 接线（运行中切换由
  /// 其他设置页即时下发；原生锁为进程级，Activity/引擎重建不释放，设置页
  /// 初始化按实际 running 状态重新对账）；iOS 由 [WebKeepAliveService]
  ///（静音音轨）负责；桌面不适用。
  ///
  /// 生命周期差异（如实登记）：原版唤醒锁与前台服务同属 `WebService`；
  /// 本仓库 Rust server 在 Flutter 进程内，前台服务只做进程提权、不承载
  /// server，因此「前台服务随 Web 服务启停」、唤醒锁仍按偏好独立控制。
  Future<void> _toggleWebService(bool v) async {
    if (_webServiceBusy) return;
    setState(() => _webServiceBusy = true);
    final api = ref.read(bookApiProvider);
    try {
      if (v) {
        // 启动端口取用户配置（PrefKeys.webPort），越界按 1122 兜底
        final port = await _readWebPort();
        // 批9b-6：启动前读唤醒锁偏好；运行中切换由其他设置页负责
        final keepAwake = await ref
            .read(settingsProvider)
            .getBoolPref(PrefKeys.webServiceWakeLock, defaultValue: false);
        // 批9b-6c 审查回修 P2：先取通知权限（可能弹框）再启动 server/FGS。
        // 若放在 startServer 之后，权限框 pending 期间 server 已运行却没有
        // FGS/唤醒锁，锁屏后 LAN 会短暂不可达；先拿结果再启动，拒绝也继续。
        final notificationGranted = await WebServiceForegroundService.instance
            .ensureNotificationPermission();
        await api.startServer(port: port);
        // 批9b-6c：服务启动成功即起前台服务（与唤醒锁偏好解耦；非 Android no-op）。
        // 失败仅静默记日志，由原生按「仅前台可用」降级，不阻断开关。
        await WebServiceForegroundService.instance.start();
        // 服务已启动：Android 按偏好持唤醒锁（非 Android 内部不触平台通道）
        await WebServiceWakeLockService.instance.onServiceStarted(
          keepAwake: keepAwake,
        );
        final String status;
        try {
          status = await api.getServerStatus();
        } catch (e) {
          // 批9b-6 边界回修：启动后状态查询失败 → 回滚释放唤醒锁并提示，
          // 不留在「已 acquire 但状态未知」
          // 批9b-6c 审查回修：回滚同时停前台服务并 best-effort 停 server，
          // 不留下「server 在跑、开关却是关」的孤儿态
          await _rollbackWebStart(api.stopServer);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Web 服务启动失败: 无法确认服务状态（${errorMessage(e)}）',
              ),
            ),
          );
          return;
        }
        if (!_isServerRunning(status)) {
          // 批9b-6 审查回修：启动「假成功」（状态仍 stopped）时回滚唤醒锁，
          // 不把开关置为开，也不接保活/写 webService=true
          // 批9b-6c 审查回修：同时停前台服务并 best-effort 停 server
          await _rollbackWebStart(api.stopServer);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Web 服务启动失败: 服务状态异常（$status）')),
          );
          return;
        }
        // 服务成功即接保活（iOS 专用；其它平台 no-op）
        final keepAlive = await WebKeepAliveService.instance.start();
        await api.setConfig('webService', 'true');
        if (!mounted) return;
        // [M1 复核 P1-3 | 2026-11-03] 先落定开关/状态（并结束 busy spinner），
        // 地址解析改为异步刷新：网卡枚举慢或永不完成时，开关已开启、
        // 无 spinner，仅操作按钮晚到，不把「启动成功」表现成卡住/未开启。
        setState(() {
          _webService = true;
          _webServiceStatus = status;
          _webServiceAddress = '';
          _webKeepAliveUnavailable = keepAlive == WebKeepAliveStatus.failed;
          _webNotificationDegraded = !notificationGranted;
        });
        unawaited(_refreshWebAddress(status));
        if (!notificationGranted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('通知权限未授予：Web 服务前台通知不可见（局域网访问不受影响）')),
          );
        }
      } else {
        try {
          await api.stopServer();
        } catch (e) {
          // 批9b-6 审查回修：停服报错先用状态确认——已停则继续释放锁，
          // 仍运行才按失败上抛（避免「实际已停」被误报为切换失败）
          var stillRunning = true;
          try {
            stillRunning = _isServerRunning(await api.getServerStatus());
          } catch (_) {
            // 状态查询也失败：按仍运行处理，保留现场
          }
          if (stillRunning) rethrow;
          debugPrint('Web 服务停止报错但状态已停（忽略）：$e');
        }
        // 服务已停：先无条件释放唤醒锁（偏好仍开也不再持锁）
        await WebServiceWakeLockService.instance.onServiceStopped();
        // 批9b-6c：停前台服务（幂等；进程内 server 已不在，前台通知必须撤）
        await WebServiceForegroundService.instance.stop();
        // 服务停止必须同步停保活（否则静音音轨会让进程继续存活）
        await WebKeepAliveService.instance.stop();
        await api.setConfig('webService', 'false');
        if (!mounted) return;
        setState(() {
          _webService = false;
          _webServiceStatus = '';
          _webServiceAddress = '';
          _webKeepAliveUnavailable = false;
          _webNotificationDegraded = false;
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

  /// 复制 Web 服务访问地址（M1）
  ///
  /// 纯 UI 操作（对齐参考版 `PrefClickEvent.CopyUrl`），不触碰服务状态；
  /// 剪贴板失败给出 SnackBar 提示。
  Future<void> _copyWebServiceAddress() async {
    final address = _webServiceAddress;
    if (address.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: address));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制访问地址')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('复制地址失败: ${errorMessage(e)}')));
    }
  }

  /// 系统浏览器打开 Web 服务地址（M1）
  ///
  /// 对齐参考版 `PrefClickEvent.OpenUrl(webServiceAddress)`：外部浏览器打开；
  /// 无实现/失败时 SnackBar 提示，不静默。
  Future<void> _openWebServiceAddress() async {
    final address = _webServiceAddress;
    if (address.isEmpty) return;
    final uri = Uri.tryParse(address);
    var opened = false;
    try {
      opened =
          uri != null &&
          await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('打开 Web 服务地址失败：$e');
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开浏览器')));
    }
  }

  /// [M2 我的页 | 2026-11-03] Web 服务块（参考版 `WebServiceSettingBlock`）
  ///
  /// 参考版形态（`legado-with-MD3/.../ui/main/my/MyScreen.kt`）：
  /// 无标题 `SplicedColumnGroup` 内一个 `SwitchSettingItem`
  /// （Web 图标 + 标题「Web 服务」+ 状态/地址副题 + 开关）；运行中在其下方
  /// 展开「复制地址」「在浏览器中打开」两个 `SmallPlainButton`（右对齐），
  /// 不是独立大卡。本实现据此替换此前 48dp 图标槽大卡：
  /// - 开关行 = `IosGroup` + `SettingSwitchRow`（裸 24dp 图标、行内开关、
  ///   整行可点、busy 时禁用并显示轻量 spinner——与「MCP 服务」行同法）；
  /// - 开启态不再有整卡描边/Ink 底色/整卡 MergeSemantics/InkWell。
  ///
  /// 运行中操作行的落位（登记）：参考版把按钮 Row 放在分组 Column 内（非卡片）；
  /// 本仓库 `IosGroup` 会给每个 child 强制套 surfaceContainerLow 行卡
  /// （ios_widgets.dart），无法表达「组内无卡片行」，故按任务约定放在
  /// `IosGroup` 组外紧邻下方：右对齐、与开关行视觉贴邻，且不属于开关行
  /// 手势/语义区域，点击不会误触开关。
  ///
  /// [M1 我的页 | 2026-11-03] 运行中副题显示可访问地址（参考版
  /// `MyUiState.webServiceAddress`）；保活/通知降级提示保留。
  Widget _buildWebServiceBlock(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = _webService;
    // [M1] 运行中优先展示可访问地址；地址解析中/失败回落状态串
    final baseSubtitle = enabled
        ? (_webServiceAddress.isNotEmpty
              ? _webServiceAddressLabel
              : (_webServiceStatus.isNotEmpty
                    ? _webServiceStatus
                    : '用浏览器写源或看书'))
        : '用浏览器写源或看书';
    // [2026-10-07 保活批 | 方案 A 兜底] 保活启动失败 → 回退「仅前台可用」，
    // 仅副题提示（对齐需求：不阻断服务、UI 主形态不变）。
    // [批9b-6c 审查回修] Android 通知权限未授予 → FGS 与 LAN 访问不受影响，
    // 仅前台通知不可见，同样只加副题提示。
    final subtitle = enabled && _webKeepAliveUnavailable
        ? '$baseSubtitle · 后台保活不可用，请保持 App 打开'
        : enabled && _webNotificationDegraded
        ? '$baseSubtitle · 通知权限未授予，前台通知不可见'
        : baseSubtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosGroup(
          margin: const EdgeInsets.only(top: 8),
          children: [
            SettingSwitchRow(
              // busy：行禁用（onChanged = null）+ 轻量 spinner 取代图标，
              // 与「MCP 服务」行同法；开关本身保留可见但灰置。
              leading: _webServiceBusy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      Symbols.language_rounded,
                      size: 24,
                      color: cs.onSurfaceVariant,
                    ),
              title: 'Web 服务',
              subtitle: subtitle,
              value: _webService,
              onChanged: _webServiceBusy ? null : _toggleWebService,
            ),
          ],
        ),
        // [M2] 运行中操作（对齐参考版 WebServiceSettingBlock 的展开按钮）：
        // 在 IosGroup 组外紧邻下方（落位原因见方法注释），右对齐 Wrap 防
        // 小屏溢出；不属于开关行手势/语义区域，点按不会切换开关。
        if (enabled && _webServiceAddress.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    key: const ValueKey('web-service-copy-address'),
                    onPressed: _copyWebServiceAddress,
                    icon: const Icon(Symbols.content_copy_rounded, size: 18),
                    label: const Text('复制地址'),
                  ),
                  TextButton.icon(
                    key: const ValueKey('web-service-open-browser'),
                    onPressed: _openWebServiceAddress,
                    icon: const Icon(Symbols.open_in_browser_rounded, size: 18),
                    label: const Text('在浏览器中打开'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
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
              // ===== 顶部 Web 服务块 =====
              // [M2 我的页 | 2026-11-03] 对齐参考版无标题 SplicedColumnGroup：
              // 开关行（SwitchSettingItem 形态）+ 运行中复制/浏览器打开。
              _buildWebServiceBlock(context),

              // ===== 规则分组（M1：收敛为 5 个规则入口）=====
              const IosSectionHeader('规则'),
              IosGroup(
                separatorIndent: 62,
                children: [
                  IosListTile(
                    // [M2] 图标对齐参考版 ClickableSettingItem：Source
                    icon: Symbols.source_rounded,
                    title: '书源管理',
                    subtitle: '新建、导入、编辑或管理书源',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.sources),
                  ),
                  IosListTile(
                    icon: Symbols.find_replace_rounded,
                    title: '替换净化',
                    subtitle: '配置替换净化规则',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.replaceRules),
                  ),
                  IosListTile(
                    // [M2] 图标对齐参考版：Rule
                    icon: Symbols.rule_rounded,
                    title: 'TXT 目录规则',
                    subtitle: '配置 TXT 目录规则',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.txtTocRules),
                  ),
                  // [M1 字典规则合并 | 2026-11-03 用户裁决] 原「字典规则」
                  // （查询页）+「规则管理」（管理页）两个入口合并为单入口：
                  // 默认进管理页（对齐原版 DictRuleActivity / 参考版
                  // PrefClickEvent.OpenDictRule）；查询页 AppRoutes.dict 保留
                  // 注册与深链，从管理页顶栏「字典查询」进入（见
                  // dict_rule_screen.dart）。
                  IosListTile(
                    // [M2] 图标对齐参考版：LibraryBooks
                    icon: Symbols.library_books_rounded,
                    title: '字典规则',
                    subtitle: '管理字典规则，查询词典释义',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.dictRule),
                  ),
                  IosListTile(
                    // [M2] 图标对齐参考版：Sell
                    icon: Symbols.sell_rounded,
                    title: '高亮标签规则',
                    subtitle: '自动高亮标注规则',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.highlightRules),
                  ),
                ],
              ),

              // ===== 服务与工具分组 =====
              // [M1 用户裁决] 原版 pref_main 独有能力保留区：定时任务 /
              // 运行定时任务 / MCP 服务（主题模式不在此，统一从设置→外观）。
              const IosSectionHeader('服务与工具'),
              IosGroup(
                separatorIndent: 62,
                children: [
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

              // ===== 其他分组 =====
              const IosSectionHeader('其他'),
              IosGroup(
                separatorIndent: 62,
                children: [
                  // [M1 我的页 | 2026-11-03 用户裁决] AI 聊天先占位：
                  // 入口 + 明确「暂未支持」页面壳，不接任何 LLM。
                  IosListTile(
                    icon: Symbols.auto_awesome_rounded,
                    title: 'AI 聊天',
                    subtitle: '暂未支持，待 Rust 能力接入',
                    onTap: () => Navigator.pushNamed(context, AppRoutes.aiChat),
                  ),
                  // [UI_SYNC_REFACTOR S6 | 2026-09-08] 设置主页集中化：我的页
                  // 原备份与恢复/主题设置/其他设置三 tile 收敛为单一「设置」
                  // 入口（对齐参考版我的页「设置」项；各页经设置主页分组到达）
                  // — Qoder
                  // [M1 我的页 | 2026-11-03] 移除独立「设置」分组，入口并入
                  // 「其他」组（对齐参考版顺序：AI 聊天 → 设置 → 书签 …）
                  IosListTile(
                    icon: Symbols.settings_rounded,
                    title: '设置',
                    subtitle: '外观 / 高级 / 阅读界面 / 备份 / 缓存',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.settingsHome),
                  ),
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
                    // [M2] 图标对齐参考版：AutoMirrored ExitToApp
                    icon: Symbols.exit_to_app_rounded,
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

  /// 帮助（对标 main_my.xml → showHelp("appHelp")）
  void _showHelp() {
    showHelp(context, HelpAssets.appHelp);
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
