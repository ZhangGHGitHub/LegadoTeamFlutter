// [UI-fix v2.0.5 | 2026-08-08] 其他设置页对齐原版 pref_config_other.xml +
// OtherConfigFragment（33 项）：语言 + 主界面分组（自动刷新/仅更新已读/
// 默认进入阅读/显示发现/显示订阅/默认首页）+ 其他分组（本地密码/UserAgent/
// Web 服务唤醒锁/默认书籍保存位置/源编辑最大行数/抗锯齿/图片缓存/图片保留/
// 预下载/替换净化默认/媒体按钮 ×3/自动清除过期/加书架提示/变种更新/漫画界面/
// Web 端口/缓存管理/线程数/文本菜单/记录日志 ×3）。
// 显示发现/显示订阅/默认首页经 MainPrefsNotifier 接通首页底栏；
// Web 端口经 BookApi.setServerPort 接通；记录日志经 CrashLogService 接通；
// Android 专属项持久化并以灰字"仅 Android 生效"标注；
// customHosts/mcpPort 已于 Task #74 接线（契约 §2.20.3/§2.22.5，
// 回读经 BookApi.getConfig 读 Rust 持久化 config:customHosts/config:mcpPort）；
// videoSetting / jsSourceApiToken / clearWebViewData：2026-08-12 已接线；
// uploadRule（直链上传规则）/ Cronet：缺引擎支撑，诚实不展示空壳；
// [Task #40 | 2026-08-09] checkSource 配置入口已接线（§5.13-2，
// 「校验书源配置」对话框经 CheckSourceNotifier 持久化并入 configJson）；
// [Task #52 | 2026-08-10] 压缩数据库已接线（§5.13-9，经 BookApi.shrinkDatabase
// 接通 cacheShrinkDatabase FFI，契约 §2.16.6） — Qoder
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../bridge/ffi.dart';
import '../l10n/app_strings.dart';
import '../providers/main_prefs_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart' show ReaderBackground;
import '../providers/source_check/check_source_notifier.dart';
import '../routes.dart';
import '../services/crash_log_service.dart';
import '../services/settings_service.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/video_settings_dialog.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 其他设置页面（对齐原版 OtherConfigFragment）
///
/// 分组与排序对齐原版 pref_config_other.xml category 结构，
/// 并保留 Flutter 端既有的默认阅读设置/网络设置分组（避免功能回归）。
class OtherSettingsScreen extends ConsumerStatefulWidget {
  const OtherSettingsScreen({super.key});

  @override
  ConsumerState<OtherSettingsScreen> createState() =>
      _OtherSettingsScreenState();
}

class _OtherSettingsScreenState extends ConsumerState<OtherSettingsScreen> {
  final SettingsService _settingsService = SettingsService();
  String _localeValue = 'system'; // system / zh / en

  // 默认阅读设置当前值
  double _fontSize = 18.0;
  double _lineHeight = 1.6;
  int _bgColorIndex = 0;

  // 网络设置当前值
  String _proxyType = 'none'; // none / http / socks5
  String _proxyHost = '';
  int _proxyPort = 0;
  int _timeoutSeconds = 30;

  // ===== 主界面分组（对齐原版 auto_refresh 等键）=====
  bool _autoRefresh = false;
  bool _onlyUpdateRead = false;
  bool _defaultToRead = false;

  // ===== 其他分组 =====
  String _localPassword = '';
  String _userAgent = '';
  bool _webServiceWakeLock = false;
  String _defaultBookTreeUri = '';
  int _sourceEditMaxLine = 99;
  bool _antiAlias = false;
  int _bitmapCacheSize = 50;
  int _imageRetainNum = 100;
  int _preDownloadNum = 10;
  bool _replaceEnableDefault = true;
  bool _mediaButtonOnExit = true;
  bool _readAloudByMediaButton = false;
  bool _ignoreAudioFocus = false;
  bool _autoClearExpired = true;
  bool _showAddToShelfAlert = true;
  bool _autoUpdateVariant = true;
  bool _showMangaUi = true;
  String _jsSourceApiToken = '';
  int _webPort = 1122;
  int _threadCount = 16;
  bool _processText = true;
  bool _recordLog = false;
  bool _recordHttpLog = false;
  bool _recordHeapDump = false;

  /// 自定义 hosts 当前配置 JSON（Rust 持久化 config:customHosts 回读；
  /// 空串=未配置；Task #74 §5.13-1）
  String _customHostsJson = '';

  /// 独立 MCP 服务端口（Rust 持久化 config:mcpPort 回读；
  /// ≤0=停止/未配置，默认 1236 对齐原版；Task #74 §5.13-6）
  int _mcpPort = 0;

  /// 校验书源配置（经 CheckSourceNotifier 持久化，字段对齐契约 §2.3
  /// CheckerConfig；Task #40 §5.13-2）
  Map<String, dynamic> _checkSourceConfig = {};

  /// Android 专属项统一灰字标注（与阅读设置面板刘海项先例一致）
  static const _androidOnly = '仅 Android 生效';

  @override
  void initState() {
    super.initState();
    _loadLocale();
    _loadReadSettings();
    _loadNetworkSettings();
    _loadOtherSettings();
  }

  Future<void> _loadLocale() async {
    _localeValue = await _settingsService.getLocale();
    // 约定：'system' 不调用 setLocale，生效 AppStrings 默认值 'zh'（系统=中文，
    // 与 _showLocalePicker 选“系统”时回退 'zh' 的行为保持一致）
    if (_localeValue != 'system') {
      AppStrings.setLocale(_localeValue);
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadReadSettings() async {
    _fontSize = await _settingsService.getFontSize();
    _lineHeight = await _settingsService.getLineHeight();
    _bgColorIndex = await _settingsService.getBgColorIndex();
    if (mounted) setState(() {});
  }

  Future<void> _loadNetworkSettings() async {
    _proxyType = await _settingsService.getProxyType();
    _proxyHost = await _settingsService.getProxyHost();
    _proxyPort = await _settingsService.getProxyPort();
    _timeoutSeconds = await _settingsService.getRequestTimeout();
    if (mounted) setState(() {});
  }

  /// 加载原版对齐新增项（键名对齐 PreferKey）
  Future<void> _loadOtherSettings() async {
    final s = _settingsService;
    _autoRefresh =
        await s.getBoolPref(PrefKeys.autoRefreshBook, defaultValue: false);
    _onlyUpdateRead =
        await s.getBoolPref(PrefKeys.onlyUpdateRead, defaultValue: false);
    _defaultToRead =
        await s.getBoolPref(PrefKeys.defaultToRead, defaultValue: false);
    _localPassword = await s.getStringPref(PrefKeys.localPassword);
    _userAgent = await s.getStringPref(PrefKeys.userAgent);
    _webServiceWakeLock =
        await s.getBoolPref(PrefKeys.webServiceWakeLock, defaultValue: false);
    _defaultBookTreeUri = await s.getStringPref(PrefKeys.defaultBookTreeUri);
    _sourceEditMaxLine =
        await s.getIntPref(PrefKeys.sourceEditMaxLine, defaultValue: 99);
    _antiAlias = await s.getBoolPref(PrefKeys.antiAlias, defaultValue: false);
    _bitmapCacheSize =
        await s.getIntPref(PrefKeys.bitmapCacheSize, defaultValue: 50);
    _imageRetainNum =
        await s.getIntPref(PrefKeys.imageRetainNum, defaultValue: 100);
    _preDownloadNum =
        await s.getIntPref(PrefKeys.preDownloadNum, defaultValue: 10);
    _replaceEnableDefault =
        await s.getBoolPref(PrefKeys.replaceEnableDefault, defaultValue: true);
    _mediaButtonOnExit =
        await s.getBoolPref(PrefKeys.mediaButtonOnExit, defaultValue: true);
    _readAloudByMediaButton = await s.getBoolPref(
      PrefKeys.readAloudByMediaButton,
      defaultValue: false,
    );
    _ignoreAudioFocus =
        await s.getBoolPref(PrefKeys.ignoreAudioFocus, defaultValue: false);
    _autoClearExpired =
        await s.getBoolPref(PrefKeys.autoClearExpired, defaultValue: true);
    _showAddToShelfAlert =
        await s.getBoolPref(PrefKeys.showAddToShelfAlert, defaultValue: true);
    _autoUpdateVariant =
        await s.getBoolPref(PrefKeys.autoUpdateVariant, defaultValue: true);
    _showMangaUi =
        await s.getBoolPref(PrefKeys.showMangaUi, defaultValue: true);
    _webPort = await s.getIntPref(PrefKeys.webPort, defaultValue: 1122);
    _threadCount = await s.getIntPref(PrefKeys.threadCount, defaultValue: 16);
    _processText =
        await s.getBoolPref(PrefKeys.processText, defaultValue: true);
    // 日志开关经 CrashLogService（已接通日志记录行为）
    _recordLog = await CrashLogService.instance.getRecordLog();
    _recordHttpLog = await CrashLogService.instance.getRecordHttpLog();
    _recordHeapDump = await CrashLogService.instance.getRecordHeapDump();
    // [Task #40 | 2026-08-09] §5.13-2：校验书源配置（含默认值回落） — Qoder
    _checkSourceConfig =
        await ref.read(checkSourceNotifierProvider.notifier).loadCheckConfig();
    // [Task #74 | 2026-08-10] §5.13-1/§5.13-6：customHosts/mcpPort 回读——
    // Rust 侧持久化于 caches 表 config:customHosts / config:mcpPort，
    // 经既有 BookApi.getConfig 回读（最小改动，无需 SP 镜像） — Qoder
    try {
      final api = ref.read(bookApiProvider);
      _customHostsJson = await api.getConfig('customHosts') ?? '';
      _mcpPort = int.tryParse(await api.getConfig('mcpPort') ?? '') ?? 0;
      _jsSourceApiToken = await api.getConfig('jsSourceApiToken') ?? '';
    } catch (e) {
      debugPrint('OtherSettingsScreen 回读 customHosts/mcpPort 异常: $e');
    }
    if (mounted) setState(() {});
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final mainPrefs = ref.watch(mainPrefsProvider);
    final mainPrefsNotifier = ref.read(mainPrefsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('其他设置')),
      body: IosGroupedBody(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            // ===== 语言（对齐原版 language ListPreference）=====
            IosSectionHeader(AppStrings.language),
            IosGroup(children: [
              IosListTile(
                icon: Icons.language,
                iconBackground: Colors.blue,
                title: AppStrings.language,
                value: _localeLabel,
                showDisclosure: true,
                onTap: () => _showLocalePicker(context),
              ),
            ]),

            // ===== 主界面（对齐原版「主界面」分组）=====
            const IosSectionHeader('主界面'),
            IosGroup(children: [
              SwitchListTile(
                title: const Text('自动刷新'),
                subtitle: const Text('打开软件时自动更新书籍'),
                value: _autoRefresh,
                onChanged: (v) {
                  setState(() => _autoRefresh = v);
                  _settingsService.setBoolPref(PrefKeys.autoRefreshBook, v);
                },
              ),
              // 对齐原版可见性依赖：仅自动刷新开启时显示
              if (_autoRefresh)
                SwitchListTile(
                  title: const Text('仅更新已读书籍'),
                  subtitle: const Text('自动刷新时跳过未读过的书籍'),
                  value: _onlyUpdateRead,
                  onChanged: (v) {
                    setState(() => _onlyUpdateRead = v);
                    _settingsService.setBoolPref(PrefKeys.onlyUpdateRead, v);
                  },
                ),
              SwitchListTile(
                title: const Text('默认进入阅读界面'),
                subtitle: const Text('打开书架书籍时直接进入上次阅读'),
                value: _defaultToRead,
                onChanged: (v) {
                  setState(() => _defaultToRead = v);
                  _settingsService.setBoolPref(PrefKeys.defaultToRead, v);
                },
              ),
              SwitchListTile(
                title: const Text('显示发现'),
                subtitle: const Text('在主界面底栏显示发现页'),
                value: mainPrefs.showDiscovery,
                onChanged: (v) => mainPrefsNotifier.setShowDiscovery(v),
              ),
              SwitchListTile(
                title: const Text('显示订阅'),
                subtitle: const Text('在主界面底栏显示订阅页'),
                value: mainPrefs.showRss,
                onChanged: (v) => mainPrefsNotifier.setShowRss(v),
              ),
              IosListTile(
                icon: Icons.home_outlined,
                iconBackground: Colors.teal,
                title: '默认首页',
                value: _homePageLabel(mainPrefs.defaultHomePage),
                showDisclosure: true,
                onTap: () => _showHomePagePicker(mainPrefs, mainPrefsNotifier),
              ),
            ]),

            // ===== 默认阅读设置（Flutter 既有分组，保留避免回归）=====
            IosSectionHeader(AppStrings.readingSettings),
            IosGroup(children: [
              IosListTile(
                icon: Icons.text_fields,
                iconBackground: Colors.orange,
                title: AppStrings.defaultFontSize,
                value: _fontSize.toStringAsFixed(0),
                showDisclosure: true,
                onTap: () => _showDefaultReadSettings(context),
              ),
              IosListTile(
                icon: Icons.format_line_spacing,
                iconBackground: Colors.orange,
                title: AppStrings.defaultLineHeight,
                value: '${_lineHeight.toStringAsFixed(1)}x',
                showDisclosure: true,
                onTap: () => _showDefaultReadSettings(context),
              ),
              IosListTile(
                icon: Icons.palette,
                iconBackground: Colors.orange,
                title: AppStrings.defaultBgColor,
                value: _bgColorLabel,
                showDisclosure: true,
                onTap: () => _showDefaultReadSettings(context),
              ),
            ]),

            // ===== 网络设置（Flutter 既有分组，保留避免回归）=====
            IosSectionHeader(AppStrings.networkSettings),
            IosGroup(children: [
              IosListTile(
                icon: Icons.wifi,
                iconBackground: Colors.green,
                title: AppStrings.proxySettings,
                value: _proxyLabel,
                showDisclosure: true,
                onTap: () => _showProxySettings(context),
              ),
              IosListTile(
                icon: Icons.timer,
                iconBackground: Colors.green,
                title: AppStrings.requestTimeout,
                value: '$_timeoutSeconds ${AppStrings.secondsUnit}',
                showDisclosure: true,
                onTap: () => _showTimeoutSettings(context),
              ),
            ]),

            // ===== 其他（对齐原版「其他」分组，顺序与 XML 一致）=====
            const IosSectionHeader('其他'),
            IosGroup(children: [
              IosListTile(
                icon: Icons.password,
                iconBackground: Colors.red,
                title: '本地密码',
                subtitle: '用于 Web 服务访问鉴权',
                value: _localPassword.isEmpty ? '未设置' : '已设置',
                showDisclosure: true,
                onTap: _showLocalPasswordDialog,
              ),
              IosListTile(
                icon: Icons.public,
                iconBackground: Colors.blueGrey,
                title: '浏览器标识（UserAgent）',
                subtitle: _userAgent.isEmpty ? '默认' : _userAgent,
                showDisclosure: true,
                onTap: _showUserAgentDialog,
              ),
              SwitchListTile(
                title: const Text('Web 服务唤醒锁'),
                subtitle: const Text(_androidOnly),
                value: _webServiceWakeLock,
                onChanged: (v) {
                  setState(() => _webServiceWakeLock = v);
                  _settingsService.setBoolPref(PrefKeys.webServiceWakeLock, v);
                },
              ),
              IosListTile(
                icon: Icons.folder_outlined,
                iconBackground: Colors.amber,
                title: '默认书籍保存位置',
                subtitle: _defaultBookTreeUri.isEmpty ? '未设置' : _defaultBookTreeUri,
                showDisclosure: true,
                onTap: _showBookTreeUriDialog,
              ),
              IosListTile(
                icon: Icons.format_list_numbered,
                iconBackground: Colors.brown,
                title: '源编辑框最大行数',
                value: '$_sourceEditMaxLine',
                showDisclosure: true,
                onTap: () => _editIntPref(
                  title: '源编辑框最大行数',
                  key: PrefKeys.sourceEditMaxLine,
                  current: _sourceEditMaxLine,
                  min: 10,
                  max: 99999,
                  apply: (v) => setState(() => _sourceEditMaxLine = v),
                ),
              ),
              SwitchListTile(
                title: const Text('图片抗锯齿'),
                subtitle: const Text('提高图片渲染质量，可能降低性能'),
                value: _antiAlias,
                onChanged: (v) {
                  setState(() => _antiAlias = v);
                  _settingsService.setBoolPref(PrefKeys.antiAlias, v);
                },
              ),
              IosListTile(
                icon: Icons.memory,
                iconBackground: Colors.deepPurple,
                title: '图片解码缓存',
                value: '$_bitmapCacheSize MB',
                showDisclosure: true,
                onTap: () => _editIntPref(
                  title: '图片解码缓存（MB）',
                  key: PrefKeys.bitmapCacheSize,
                  current: _bitmapCacheSize,
                  min: 1,
                  max: 1024,
                  apply: (v) => setState(() => _bitmapCacheSize = v),
                ),
              ),
              IosListTile(
                icon: Icons.photo_library_outlined,
                iconBackground: Colors.deepPurple,
                title: '图片文件保留数量',
                value: '$_imageRetainNum',
                showDisclosure: true,
                onTap: () => _editIntPref(
                  title: '图片文件保留数量',
                  key: PrefKeys.imageRetainNum,
                  current: _imageRetainNum,
                  min: 0,
                  max: 999,
                  apply: (v) => setState(() => _imageRetainNum = v),
                ),
              ),
              IosListTile(
                icon: Icons.download_outlined,
                iconBackground: Colors.indigo,
                title: '预下载章节数量',
                value: '$_preDownloadNum',
                showDisclosure: true,
                onTap: () => _editIntPref(
                  title: '预下载章节数量',
                  key: PrefKeys.preDownloadNum,
                  current: _preDownloadNum,
                  min: 0,
                  max: 9999,
                  apply: (v) => setState(() => _preDownloadNum = v),
                ),
              ),
              SwitchListTile(
                title: const Text('替换净化默认启用'),
                subtitle: const Text('新加入书架的书籍默认开启替换净化'),
                value: _replaceEnableDefault,
                onChanged: (v) {
                  setState(() => _replaceEnableDefault = v);
                  _settingsService.setBoolPref(
                      PrefKeys.replaceEnableDefault, v);
                },
              ),
              SwitchListTile(
                title: const Text('退出应用时停止朗读'),
                subtitle: const Text(_androidOnly),
                value: _mediaButtonOnExit,
                onChanged: (v) {
                  setState(() => _mediaButtonOnExit = v);
                  _settingsService.setBoolPref(PrefKeys.mediaButtonOnExit, v);
                },
              ),
              SwitchListTile(
                title: const Text('媒体按钮触发朗读'),
                subtitle: const Text(_androidOnly),
                value: _readAloudByMediaButton,
                onChanged: (v) {
                  setState(() => _readAloudByMediaButton = v);
                  _settingsService.setBoolPref(
                      PrefKeys.readAloudByMediaButton, v);
                },
              ),
              SwitchListTile(
                title: const Text('朗读时忽略音频焦点'),
                subtitle: const Text(_androidOnly),
                value: _ignoreAudioFocus,
                onChanged: (v) {
                  setState(() => _ignoreAudioFocus = v);
                  _settingsService.setBoolPref(PrefKeys.ignoreAudioFocus, v);
                },
              ),
              SwitchListTile(
                title: const Text('自动清除过期数据'),
                subtitle: const Text('清除一天前的搜索数据'),
                value: _autoClearExpired,
                onChanged: (v) {
                  setState(() => _autoClearExpired = v);
                  _settingsService.setBoolPref(PrefKeys.autoClearExpired, v);
                },
              ),
              SwitchListTile(
                title: const Text('显示添加书架提示'),
                subtitle: const Text('浏览书籍详情离开时提示加入书架'),
                value: _showAddToShelfAlert,
                onChanged: (v) {
                  setState(() => _showAddToShelfAlert = v);
                  _settingsService.setBoolPref(
                      PrefKeys.showAddToShelfAlert, v);
                },
              ),
              SwitchListTile(
                title: const Text('自动更新到最佳变种版本'),
                subtitle: const Text(_androidOnly),
                value: _autoUpdateVariant,
                onChanged: (v) {
                  setState(() => _autoUpdateVariant = v);
                  _settingsService.setBoolPref(PrefKeys.autoUpdateVariant, v);
                },
              ),
              SwitchListTile(
                title: const Text('显示漫画界面'),
                subtitle: const Text('以漫画模式打开图片流书籍'),
                value: _showMangaUi,
                onChanged: (v) {
                  setState(() => _showMangaUi = v);
                  _settingsService.setBoolPref(PrefKeys.showMangaUi, v);
                },
              ),
              IosListTile(
                icon: Icons.videocam_outlined,
                iconBackground: Colors.redAccent,
                title: '视频设置',
                subtitle: '自动播放、全屏与长按倍速',
                showDisclosure: true,
                onTap: () => showVideoSettingsDialog(context),
              ),
              IosListTile(
                icon: Icons.vpn_key_outlined,
                iconBackground: Colors.brown,
                title: 'JS 书源 API Token',
                subtitle: _jsSourceApiToken.isEmpty ? '未设置' : '已设置',
                showDisclosure: true,
                onTap: _editJsSourceApiToken,
              ),
              IosListTile(
                icon: Icons.web_asset_off,
                iconBackground: Colors.blueGrey,
                title: '清除 WebView 数据',
                subtitle: '清除 Cookie（站点登录态等）',
                showDisclosure: true,
                onTap: _clearWebViewData,
              ),
              IosListTile(
                icon: Icons.settings_ethernet,
                iconBackground: Colors.cyan,
                title: 'Web 服务端口',
                subtitle: '修改后重启 Web 服务生效',
                value: '$_webPort',
                showDisclosure: true,
                onTap: _showWebPortDialog,
              ),
              // [Task #74 | 2026-08-10] §5.13-6：MCP 服务端口（契约 §2.22.5，
              // 对齐原版 AppConfig.mcpPort 默认 1236、区间 1024..65530；
              // 0/留空=停止独立服务） — Qoder
              IosListTile(
                icon: Icons.smart_toy_outlined,
                iconBackground: Colors.indigo,
                title: 'MCP 服务端口',
                subtitle: _mcpPort > 0
                    ? '独立 MCP 服务监听中（1024~65530）'
                    : '独立 MCP 服务已停止（输入 0 停止）',
                value: _mcpPort > 0 ? '$_mcpPort' : '停止',
                showDisclosure: true,
                onTap: _showMcpPortDialog,
              ),
              // [Task #74 | 2026-08-10] §5.13-1：自定义 hosts（契约 §2.20.3，
              // 对齐原版 OtherConfigFragment.showCustomHostsDialog：
              // 合法 JSON 对象才保存、空=清除、非法提示不保存） — Qoder
              IosListTile(
                icon: Icons.dns_outlined,
                iconBackground: Colors.teal,
                title: '自定义 hosts',
                subtitle: _customHostsSummary,
                showDisclosure: true,
                onTap: _showCustomHostsDialog,
              ),
              IosListTile(
                icon: Icons.cleaning_services,
                iconBackground: Colors.grey,
                title: '缓存管理',
                subtitle: '缓存统计、自动过期策略与清理',
                showDisclosure: true,
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.cacheSettings),
              ),
              // [Task #52 | 2026-08-10] §5.13-9：压缩数据库（对齐原版
              // pref_config_other.xml shrink_database → OtherConfigFragment
              // shrinkDatabase：确认对话框 + VACUUM 后 Toast 提示） — Qoder
              IosListTile(
                icon: Icons.compress,
                iconBackground: Colors.grey,
                title: '压缩数据库',
                subtitle: '减小数据库文件的大小',
                showDisclosure: true,
                onTap: _shrinkDatabase,
              ),
              IosListTile(
                icon: Icons.sync,
                iconBackground: Colors.lightBlue,
                title: '线程数量',
                subtitle: '更新书籍、缓存书籍时的并发数量',
                value: '$_threadCount',
                showDisclosure: true,
                onTap: () => _editIntPref(
                  title: '线程数量',
                  key: PrefKeys.threadCount,
                  current: _threadCount,
                  min: 1,
                  max: 999,
                  apply: (v) => setState(() => _threadCount = v),
                ),
              ),
              // [Task #40 | 2026-08-09] §5.13-2：校验书源配置入口
              //（对齐原版 pref_config_other.xml check_source → CheckSourceConfig 对话框） — Qoder
              IosListTile(
                icon: Icons.verified_user_outlined,
                iconBackground: Colors.blue,
                title: '校验书源配置',
                subtitle: _checkSourceConfigSummary,
                showDisclosure: true,
                onTap: _showCheckSourceConfigDialog,
              ),
              SwitchListTile(
                title: const Text('文本操作菜单显示应用'),
                subtitle: const Text(_androidOnly),
                value: _processText,
                onChanged: (v) {
                  setState(() => _processText = v);
                  _settingsService.setBoolPref(PrefKeys.processText, v);
                },
              ),
              SwitchListTile(
                title: const Text('记录日志'),
                subtitle: const Text('记录应用运行日志用于问题诊断'),
                value: _recordLog,
                onChanged: (v) {
                  setState(() => _recordLog = v);
                  CrashLogService.instance.setRecordLog(v);
                },
              ),
              SwitchListTile(
                title: const Text('记录 HTTP 请求日志'),
                value: _recordHttpLog,
                onChanged: (v) {
                  setState(() => _recordHttpLog = v);
                  CrashLogService.instance.setRecordHttpLog(v);
                },
              ),
              SwitchListTile(
                title: const Text('记录内存堆转储'),
                subtitle: const Text('崩溃时保存内存快照用于诊断'),
                value: _recordHeapDump,
                onChanged: (v) {
                  setState(() => _recordHeapDump = v);
                  CrashLogService.instance.setRecordHeapDump(v);
                },
              ),
            ]),
          ],
        ),
      ),
    );
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

  String get _bgColorLabel {
    if (_bgColorIndex >= 0 && _bgColorIndex < ReaderBackground.labels.length) {
      return ReaderBackground.labels[_bgColorIndex];
    }
    return AppStrings.whiteColor;
  }

  String get _proxyLabel {
    switch (_proxyType) {
      case 'http':
        return _proxyHost.isEmpty ? 'HTTP' : 'HTTP · $_proxyHost:$_proxyPort';
      case 'socks5':
        return _proxyHost.isEmpty
            ? 'SOCKS5'
            : 'SOCKS5 · $_proxyHost:$_proxyPort';
      default:
        return AppStrings.noProxy;
    }
  }

  /// 默认首页值 → 展示文案（对齐原版 default_home_page 数组）
  String _homePageLabel(String value) {
    switch (value) {
      case 'explore':
        return '发现';
      case 'rss':
        return '订阅';
      case 'my':
        return '我的';
      default:
        return '书架';
    }
  }

  /// 默认首页选择（对齐原版 defaultHomePage ListPreference）
  Future<void> _showHomePagePicker(
    MainPrefsState prefs,
    MainPrefsNotifier notifier,
  ) async {
    const options = [
      ('bookshelf', '书架'),
      ('explore', '发现'),
      ('rss', '订阅'),
      ('my', '我的'),
    ];
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('默认首页'),
        children: [
          // 用 RadioGroup 统一管理选中值（避免 groupValue/onChanged 废弃 API）
          RadioGroup<String>(
            groupValue: prefs.defaultHomePage,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (value, label) in options)
                  RadioListTile<String>(
                    title: Text(label),
                    value: value,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    // [UI-fix v2.0.5 | 2026-08-08] 异步对话框返回后统一补 mounted 防护，
    // 避免页面已销毁时继续 setState/持久化 — Qoder
    if (selected == null || !mounted) return;
    await notifier.setDefaultHomePage(selected);
  }

  /// 本地密码编辑（对齐原版 localPassword EditTextPreference）
  Future<void> _showLocalPasswordDialog() async {
    final value = await _showTextInputDialog(
      title: '本地密码',
      hint: '用于 Web 服务访问鉴权，留空清除',
      current: _localPassword,
      obscure: true,
    );
    // 异步对话框返回后先检查 mounted，再 setState/持久化
    if (value == null || !mounted) return;
    setState(() => _localPassword = value);
    if (value.isEmpty) {
      await _settingsService.removePref(PrefKeys.localPassword);
    } else {
      await _settingsService.setStringPref(PrefKeys.localPassword, value);
    }
  }

  /// UserAgent 编辑（对齐原版 userAgent 对话框，留空恢复默认）
  Future<void> _showUserAgentDialog() async {
    final value = await _showTextInputDialog(
      title: '浏览器标识（UserAgent）',
      hint: '留空使用默认 UserAgent',
      current: _userAgent,
      maxLines: 3,
    );
    // 异步对话框返回后先检查 mounted，再 setState/持久化
    if (value == null || !mounted) return;
    setState(() => _userAgent = value);
    if (value.isEmpty) {
      await _settingsService.removePref(PrefKeys.userAgent);
    } else {
      await _settingsService.setStringPref(PrefKeys.userAgent, value);
    }
  }

  /// 默认书籍保存位置（对齐原版 defaultBookTreeUri 目录选择）
  Future<void> _showBookTreeUriDialog() async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('默认书籍保存位置'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'select'),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('选择文件夹'),
            ),
          ),
          if (_defaultBookTreeUri.isNotEmpty)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'clear'),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('清除'),
              ),
            ),
        ],
      ),
    );
    // 异步对话框/文件选择器返回后先检查 mounted，再 setState/持久化
    if (!mounted) return;
    if (action == 'select') {
      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择默认书籍保存位置',
      );
      if (dir == null || !mounted) return;
      setState(() => _defaultBookTreeUri = dir);
      await _settingsService.setStringPref(PrefKeys.defaultBookTreeUri, dir);
    } else if (action == 'clear') {
      setState(() => _defaultBookTreeUri = '');
      await _settingsService.removePref(PrefKeys.defaultBookTreeUri);
    }
  }

  /// Web 服务端口设置（对齐原版 webPort 1024~60000；
  /// 经 BookApi.setServerPort 写入引擎配置，重启 Web 服务后生效）
  Future<void> _showWebPortDialog() async {
    final value = await _showNumberInputDialog(
      title: 'Web 服务端口',
      current: _webPort,
      min: 1024,
      max: 60000,
    );
    // 异步对话框返回后先检查 mounted，再 setState/持久化与引擎同步
    if (value == null || value == _webPort || !mounted) return;
    setState(() => _webPort = value);
    await _settingsService.setIntPref(PrefKeys.webPort, value);
    // 行为接通：同步到 Rust 引擎配置（对齐原版 webPort 变更重启 WebService）
    try {
      await ref.read(bookApiProvider).setServerPort(value);
      _toast('端口已保存，重启 Web 服务后生效');
    } catch (e) {
      debugPrint('OtherSettingsScreen 设置 Web 端口异常: $e');
      _toast('端口已保存（引擎同步失败，重启应用后生效）');
    }
  }

  /// 可读错误消息（BridgeError 取 message，其余 toString）
  /// [Task #74 | 2026-08-10] — Qoder
  String _errMsg(Object e) => e is BridgeError ? e.message : e.toString();

  /// 自定义 hosts 配置摘要（副标题：已配置 N 条/未配置；
  /// Task #74 §5.13-1） — Qoder
  String get _customHostsSummary {
    final trimmed = _customHostsJson.trim();
    if (trimmed.isEmpty) return '未配置（域名 → IP 映射）';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return '已配置 ${decoded.length} 条';
    } catch (_) {
      // 解析失败仍显示已配置（保存路径已校验，此处仅兑底）
    }
    return '已配置';
  }

  /// MCP 服务端口设置（契约 §2.22.5，对齐原版 AppConfig.mcpPort：
  /// 默认 1236、区间 1024..65530；0/留空=停止独立服务；
  /// 端口占用等失败 Toast 可读错误）
  /// [Task #74 | 2026-08-10] — Qoder
  Future<void> _showMcpPortDialog() async {
    final value = await showDialog<int>(
      context: context,
      builder: (_) => _McpPortDialog(currentPort: _mcpPort),
    );
    // Task #76 Min1：去掉同端口短路（Rust 侧幂等重启语义），
    // 保证服务异常后可用同端口重启
    if (value == null || !mounted) return;
    try {
      await ref.read(bookApiProvider).setMcpPort(value);
      if (!mounted) return;
      setState(() => _mcpPort = value);
      _toast(value > 0
          ? 'MCP 端口已保存：$value（独立服务已重启）'
          : '独立 MCP 服务已停止');
    } catch (e) {
      debugPrint('OtherSettingsScreen 设置 MCP 端口异常: $e');
      if (mounted) _toast('MCP 端口设置失败: ${_errMsg(e)}');
    }
  }

  /// 自定义 hosts 编辑对话框（对齐原版 OtherConfigFragment
  /// .showCustomHostsDialog：预填当前配置，合法 JSON 对象才保存、
  /// 空=清除、非法 JSON 提示不保存；契约 §2.20.3）
  /// [Task #74 | 2026-08-10] — Qoder
  Future<void> _showCustomHostsDialog() async {
    final input = await showDialog<String>(
      context: context,
      builder: (_) => _CustomHostsDialog(initialText: _customHostsJson),
    );
    if (input == null || !mounted) return;
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      // 空内容=清除映射恢复系统 DNS（契约 §2.20.3）
      try {
        await ref.read(bookApiProvider).setCustomHosts('');
        if (!mounted) return;
        setState(() => _customHostsJson = '');
        _toast('自定义 hosts 已清除');
      } catch (e) {
        debugPrint('OtherSettingsScreen 清除 customHosts 异常: $e');
        if (mounted) _toast('自定义 hosts 清除失败: ${_errMsg(e)}');
      }
      return;
    }
    // 合法 JSON 对象才保存；非法 JSON 提示不保存（对齐原版）
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      _toast('非法 JSON，未保存');
      return;
    }
    if (decoded is! Map) {
      _toast('须为 JSON 对象（域名 → IP），未保存');
      return;
    }
    try {
      await ref.read(bookApiProvider).setCustomHosts(trimmed);
      if (!mounted) return;
      setState(() => _customHostsJson = trimmed);
      _toast('自定义 hosts 已保存（${decoded.length} 条）');
    } catch (e) {
      debugPrint('OtherSettingsScreen 保存 customHosts 异常: $e');
      if (mounted) _toast('自定义 hosts 保存失败: ${_errMsg(e)}');
    }
  }

  /// 压缩数据库（对齐原版 OtherConfigFragment.shrinkDatabase：
  /// 确认对话框 → VACUUM → Toast 提示）
  /// [Task #52 | 2026-08-10] §5.13-9，契约 §2.16.6 — Qoder
  Future<void> _shrinkDatabase() async {
    // 原版确认对话框（alert(sure, shrink_database)）
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认'),
        content: const Text('压缩数据库？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.confirm),
          ),
        ],
      ),
    );
    // 异步对话框返回后先检查 mounted，再执行压缩
    if (confirmed != true || !mounted) return;
    _toast('正在压缩数据库…');
    try {
      final freed = await ref.read(bookApiProvider).shrinkDatabase();
      if (!mounted) return;
      if (freed <= 0) {
        // 契约约定：失败/未初始化降级返回 0
        _toast('无需压缩或压缩失败');
      } else {
        _toast('压缩完成，释放 ${_formatBytes(freed)}');
      }
    } catch (e) {
      debugPrint('OtherSettingsScreen 压缩数据库异常: $e');
      if (mounted) _toast('压缩失败: $e');
    }
  }

  /// 字节数格式化（KB/MB 展示，对齐任务要求的释放空间提示格式）
  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  /// 校验书源配置摘要（对齐原版 CheckSource.summary：超时 + 已启用校验项）
  /// [Task #40 | 2026-08-09] §5.13-2 — Qoder
  String get _checkSourceConfigSummary {
    if (_checkSourceConfig.isEmpty) return '';
    final ms = (_checkSourceConfig['step_timeout_ms'] as num?)?.toInt() ??
        CheckSourceNotifier.defaultStepTimeoutMs;
    final items = <String>[
      if (_checkSourceConfig['check_search'] == true) '搜索',
      if (_checkSourceConfig['check_toc'] == true) '目录',
      if (_checkSourceConfig['check_content'] == true) '正文',
    ];
    final itemText = items.isEmpty ? '未设置校验步骤' : '校验${items.join('、')}';
    return '超时 ${ms ~/ 1000}秒 · $itemText';
  }

  /// 校验书源配置对话框（对齐原版 CheckSourceConfig：搜索关键词、校验超时、
  /// 各校验步骤开关；字段映射到既有 checkSource configJson 契约 §2.3）
  ///
  /// 级联约束对齐原版：校验搜索 → 目录 → 正文 逐级依赖，
  /// 关闭上级步骤时同步关闭下级。
  /// [Task #40 | 2026-08-09] §5.13-2 — Qoder
  /// [Task #54 | 2026-08-10] 缺陷②修复：对话框提取为自持 StatefulWidget
  /// （_CheckSourceConfigDialog），controller 在 State 内创建/dispose 中释放，
  /// 确认回传值而非 controller，消除退场动画期间 dispose 引发的框架断言红屏 — Qoder
  Future<void> _showCheckSourceConfigDialog() async {
    final result = await showDialog<_CheckSourceConfigResult>(
      context: context,
      builder: (_) => _CheckSourceConfigDialog(
        initialKeyword: (_checkSourceConfig['keyword'] ?? '').toString(),
        initialSeconds:
            ((_checkSourceConfig['step_timeout_ms'] as num?)?.toInt() ??
                    CheckSourceNotifier.defaultStepTimeoutMs) ~/
                1000,
        initialCheckSearch: _checkSourceConfig['check_search'] == true,
        initialCheckToc: _checkSourceConfig['check_toc'] == true,
        initialCheckContent: _checkSourceConfig['check_content'] == true,
        initialDetectCaptcha: _checkSourceConfig['detect_captcha'] == true,
        initialDetectRedirect: _checkSourceConfig['detect_redirect'] == true,
      ),
    );
    // 异步对话框返回后先检查 mounted，再 setState/持久化
    if (result == null || !mounted) return;
    // 字段映射到契约 §2.3 CheckerConfig（step_timeout_ms 以毫秒传递）
    final config = <String, dynamic>{
      'keyword': result.keyword,
      'step_timeout_ms': result.seconds * 1000,
      'check_search': result.checkSearch,
      'check_toc': result.checkToc,
      'check_content': result.checkContent,
      'detect_captcha': result.detectCaptcha,
      'detect_redirect': result.detectRedirect,
    };
    await ref
        .read(checkSourceNotifierProvider.notifier)
        .saveCheckConfig(config);
    if (!mounted) return;
    setState(() => _checkSourceConfig = config);
    _toast('配置已保存，下次校验时生效');
  }

  /// 通用整数偏好编辑（输入校验 + 持久化 + 回写状态）
  Future<void> _editIntPref({
    required String title,
    required String key,
    required int current,
    required int min,
    required int max,
    required ValueChanged<int> apply,
  }) async {
    final value = await _showNumberInputDialog(
      title: title,
      current: current,
      min: min,
      max: max,
    );
    // 异步对话框返回后先检查 mounted，apply 内部会调用 setState
    if (value == null || !mounted) return;
    apply(value);
    await _settingsService.setIntPref(key, value);
  }

  /// 通用数字输入对话框（返回 null 表示取消）
  Future<int?> _showNumberInputDialog({
    required String title,
    required int current,
    required int min,
    required int max,
  }) async {
    final controller = TextEditingController(text: '$current');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: '$min ~ $max'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text.trim());
              if (parsed == null || parsed < min || parsed > max) {
                _toast('请输入 $min ~ $max 之间的数字');
                return;
              }
              Navigator.pop(ctx, parsed);
            },
            child: Text(AppStrings.confirm),
          ),
        ],
      ),
    );
  }

  /// 通用文本输入对话框（返回 null 表示取消，返回空串表示清除）
  Future<String?> _showTextInputDialog({
    required String title,
    required String hint,
    required String current,
    bool obscure = false,
    int maxLines = 1,
  }) async {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: obscure,
          maxLines: obscure ? 1 : maxLines,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(AppStrings.confirm),
          ),
        ],
      ),
    );
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
      // 进入 .then 回调后第一时间检查 mounted，再 setState/持久化
      if (selectedLocale == null || !mounted) return;
      setState(() => _localeValue = selectedLocale);
      await _settingsService.setLocale(selectedLocale);
      // [UI-fix v2.0.5 | 2026-08-08] 项目约定：“跟随系统”=中文。
      // AppStrings 无系统语言解析能力，其 _locale 默认值即 'zh'（冷启动时
      // _loadLocale 对 'system' 不调用 setLocale，最终生效的就是默认 'zh'），
      // 故此处选“系统”时立即回退 'zh'，与重启后效果保持一致 — Qoder
      if (selectedLocale == 'system') {
        AppStrings.setLocale('zh');
      } else {
        AppStrings.setLocale(selectedLocale);
      }
      if (mounted) setState(() {});
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

  /// 默认阅读设置：字体大小、行距、背景色
  void _showDefaultReadSettings(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    var fontSize = _fontSize;
    var lineHeight = _lineHeight;
    var bgIndex = _bgColorIndex;

    showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(AppStrings.readingSettingsTitle),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 字体大小
                  Text(
                    '${AppStrings.fontSizeLabel}: ${fontSize.toStringAsFixed(0)}',
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                  Slider(
                    value: fontSize,
                    min: 12,
                    max: 32,
                    divisions: 20,
                    label: fontSize.round().toString(),
                    onChanged: (v) => setDialogState(() => fontSize = v),
                  ),
                  const SizedBox(height: 8),
                  // 行距
                  Text(AppStrings.lineHeightLabel,
                      style: Theme.of(ctx).textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final value in const [1.2, 1.6, 2.0, 2.5])
                        ChoiceChip(
                          label: Text('${value}x'),
                          selected: lineHeight == value,
                          onSelected: (_) =>
                              setDialogState(() => lineHeight = value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 背景色（与阅读器预设保持一致）
                  Text(AppStrings.bgColor,
                      style: Theme.of(ctx).textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    children:
                        List.generate(ReaderBackground.presets.length, (i) {
                      final color = ReaderBackground.presets[i];
                      final isSelected = bgIndex == i;
                      return GestureDetector(
                        onTap: () => setDialogState(() => bgIndex = i),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isSelected
                                      ? Theme.of(ctx).colorScheme.primary
                                      : Theme.of(ctx).colorScheme.outlineVariant,
                                  width: isSelected ? 3 : 1,
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              ReaderBackground.labels[i],
                              style: Theme.of(ctx).textTheme.labelSmall,
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.save),
            ),
          ],
        ),
      ),
    ).then((saved) async {
      // 进入 .then 回调后第一时间检查 mounted，再 setState/持久化
      if (saved != true || !mounted) return;
      setState(() {
        _fontSize = fontSize;
        _lineHeight = lineHeight;
        _bgColorIndex = bgIndex;
      });
      await _settingsService.setFontSize(fontSize);
      await _settingsService.setLineHeight(lineHeight);
      await _settingsService.setBgColorIndex(bgIndex);
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.configSaved)),
      );
    });
  }

  /// 代理设置：类型（无/HTTP/SOCKS5）+ 地址 + 端口
  void _showProxySettings(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    var proxyType = _proxyType;
    final hostController = TextEditingController(text: _proxyHost);
    final portController = TextEditingController(
      text: _proxyPort > 0 ? '$_proxyPort' : '',
    );

    showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(AppStrings.proxySettings),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'none', label: Text('无')),
                      ButtonSegment(value: 'http', label: Text('HTTP')),
                      ButtonSegment(value: 'socks5', label: Text('SOCKS5')),
                    ],
                    selected: {proxyType},
                    onSelectionChanged: (selected) =>
                        setDialogState(() => proxyType = selected.first),
                  ),
                  if (proxyType != 'none') ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: hostController,
                      decoration: const InputDecoration(
                        labelText: '代理地址',
                        hintText: '127.0.0.1',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.dns),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: portController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口',
                        hintText: '7890',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.numbers),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.save),
            ),
          ],
        ),
      ),
    ).then((saved) async {
      final host = hostController.text.trim();
      final port = int.tryParse(portController.text.trim()) ?? 0;
      hostController.dispose();
      portController.dispose();
      // 进入 .then 回调后（控件释放完毕）检查 mounted，再 setState/持久化
      if (saved != true || !mounted) return;

      if (proxyType != 'none' && (host.isEmpty || port <= 0 || port > 65535)) {
        messenger.showSnackBar(
          const SnackBar(content: Text('请填写有效的代理地址和端口')),
        );
        return;
      }

      final effectiveHost = proxyType == 'none' ? '' : host;
      final effectivePort = proxyType == 'none' ? 0 : port;
      setState(() {
        _proxyType = proxyType;
        _proxyHost = effectiveHost;
        _proxyPort = effectivePort;
      });
      await _settingsService.setProxyType(proxyType);
      await _settingsService.setProxyHost(effectiveHost);
      await _settingsService.setProxyPort(effectivePort);
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.configSaved)),
      );
    });
  }

  /// 请求超时设置：5–60 秒滑块
  void _showTimeoutSettings(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    var seconds = _timeoutSeconds.clamp(5, 60).toDouble();

    showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(AppStrings.requestTimeout),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${seconds.round()} ${AppStrings.secondsUnit}',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              Slider(
                value: seconds,
                min: 5,
                max: 60,
                divisions: 55,
                label: '${seconds.round()}',
                onChanged: (v) => setDialogState(() => seconds = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.save),
            ),
          ],
        ),
      ),
    ).then((saved) async {
      // 进入 .then 回调后第一时间检查 mounted，再 setState/持久化
      if (saved != true || !mounted) return;
      setState(() => _timeoutSeconds = seconds.round());
      await _settingsService.setRequestTimeout(seconds.round());
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.configSaved)),
      );
    });
  }
}

/// 校验书源配置对话框确认结果（回传值而非 controller）
/// [Task #54 | 2026-08-10] — Qoder
class _CheckSourceConfigResult {
  final String keyword;
  final int seconds;
  final bool checkSearch;
  final bool checkToc;
  final bool checkContent;
  final bool detectCaptcha;
  final bool detectRedirect;

  const _CheckSourceConfigResult({
    required this.keyword,
    required this.seconds,
    required this.checkSearch,
    required this.checkToc,
    required this.checkContent,
    required this.detectCaptcha,
    required this.detectRedirect,
  });
}

/// 校验书源配置对话框（自持 StatefulWidget，照 _TextPromptDialog 模式）：
/// controller 在 State 内创建、dispose 中随子树卸载统一释放，
/// 避免 Navigator.pop 后立即 dispose 在退场动画期间触发
/// framework.dart _dependents.isEmpty 断言红屏。
/// [Task #54 | 2026-08-10] — Qoder
class _CheckSourceConfigDialog extends StatefulWidget {
  final String initialKeyword;
  final int initialSeconds;
  final bool initialCheckSearch;
  final bool initialCheckToc;
  final bool initialCheckContent;
  final bool initialDetectCaptcha;
  final bool initialDetectRedirect;

  const _CheckSourceConfigDialog({
    required this.initialKeyword,
    required this.initialSeconds,
    required this.initialCheckSearch,
    required this.initialCheckToc,
    required this.initialCheckContent,
    required this.initialDetectCaptcha,
    required this.initialDetectRedirect,
  });

  @override
  State<_CheckSourceConfigDialog> createState() =>
      _CheckSourceConfigDialogState();
}

class _CheckSourceConfigDialogState extends State<_CheckSourceConfigDialog> {
  late final TextEditingController _keywordController =
      TextEditingController(text: widget.initialKeyword);
  late final TextEditingController _timeoutController =
      TextEditingController(text: '${widget.initialSeconds}');
  late bool _checkSearch = widget.initialCheckSearch;
  late bool _checkToc = widget.initialCheckToc;
  late bool _checkContent = widget.initialCheckContent;
  late bool _detectCaptcha = widget.initialDetectCaptcha;
  late bool _detectRedirect = widget.initialDetectRedirect;

  /// 超时输入校验错误回显（非空且 > 0 秒，对齐原版 CheckSourceConfig.tvOk）
  String? _timeoutError;

  @override
  void dispose() {
    _keywordController.dispose();
    _timeoutController.dispose();
    super.dispose();
  }

  void _onConfirm() {
    final text = _timeoutController.text.trim();
    final seconds = int.tryParse(text);
    if (text.isEmpty) {
      setState(() => _timeoutError = '超时时间不能为空');
      return;
    }
    if (seconds == null || seconds <= 0) {
      setState(() => _timeoutError = '超时时间必须大于 0 秒');
      return;
    }
    Navigator.pop(
      context,
      _CheckSourceConfigResult(
        keyword: _keywordController.text.trim(),
        seconds: seconds,
        checkSearch: _checkSearch,
        checkToc: _checkToc,
        checkContent: _checkContent,
        detectCaptcha: _detectCaptcha,
        detectRedirect: _detectRedirect,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('校验书源配置'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _keywordController,
                decoration: const InputDecoration(
                  labelText: '搜索关键词',
                  hintText: '默认：我的',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _timeoutController,
                keyboardType: TextInputType.number,
                onChanged: (_) {
                  if (_timeoutError != null) {
                    setState(() => _timeoutError = null);
                  }
                },
                decoration: InputDecoration(
                  labelText: '校验超时（秒）',
                  hintText: '单个校验步骤的超时时间',
                  border: const OutlineInputBorder(),
                  errorText: _timeoutError,
                ),
              ),
              const SizedBox(height: 8),
              // 校验步骤级联（对齐原版 checkSearch→checkInfo→checkCategory
              // →checkContent 依赖链，映射到 Rust 侧三步开关）
              SwitchListTile(
                title: const Text('校验搜索'),
                subtitle: const Text('搜索关键词并校验结果'),
                value: _checkSearch,
                onChanged: (v) => setState(() {
                  _checkSearch = v;
                  if (!v) {
                    _checkToc = false;
                    _checkContent = false;
                  }
                }),
              ),
              SwitchListTile(
                title: const Text('校验目录'),
                subtitle: const Text('依赖校验搜索结果'),
                value: _checkToc,
                // 上级步骤关闭时下级不可切换（对齐原版 isEnabled 联动）
                onChanged: !_checkSearch
                    ? null
                    : (v) => setState(() {
                          _checkToc = v;
                          if (!v) _checkContent = false;
                        }),
              ),
              SwitchListTile(
                title: const Text('校验正文'),
                subtitle: const Text('依赖校验目录结果'),
                value: _checkContent,
                onChanged: (!_checkSearch || !_checkToc)
                    ? null
                    : (v) => setState(() => _checkContent = v),
              ),
              SwitchListTile(
                title: const Text('验证码拦截检测'),
                subtitle: const Text('识别疑似验证码页面并标记'),
                value: _detectCaptcha,
                onChanged: (v) => setState(() => _detectCaptcha = v),
              ),
              SwitchListTile(
                title: const Text('重定向检测'),
                subtitle: const Text('识别登录/拦截重定向并标记'),
                value: _detectRedirect,
                onChanged: (v) => setState(() => _detectRedirect = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: _onConfirm,
          child: Text(AppStrings.confirm),
        ),
      ],
    );
  }
}

/// MCP 端口输入对话框（自持 StatefulWidget，照 _TextPromptDialog 范式）：
/// controller 在 State 内创建、dispose 中随子树卸载统一释放，
/// 确定先取值再 pop 回传，规避退场动画期间 dispose 引发的框架断言红屏。
/// 留空/0=停止独立服务；>0 校验区间 1024..65530，越界内联报错不 pop。
/// [Task #74 | 2026-08-10] — Qoder
class _McpPortDialog extends StatefulWidget {
  final int currentPort;

  const _McpPortDialog({required this.currentPort});

  @override
  State<_McpPortDialog> createState() => _McpPortDialogState();
}

class _McpPortDialogState extends State<_McpPortDialog> {
  /// 未配置时预填默认端口 1236（Task #76 Med3：落实契约 §2.22.5
  /// 缺省语义，对齐原版 AppConfig.mcpPort 默认值）
  static const int _defaultMcpPort = 1236;

  late final TextEditingController _controller = TextEditingController(
    text: widget.currentPort > 0 ? '${widget.currentPort}' : '$_defaultMcpPort',
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      Navigator.pop(context, 0); // 留空=停止独立服务
      return;
    }
    final parsed = int.tryParse(text);
    if (parsed == null || parsed < 0) {
      setState(() => _error = '请输入非负数字（0 表示停止）');
      return;
    }
    if (parsed > 0 && (parsed < 1024 || parsed > 65530)) {
      setState(() => _error = '端口区间 1024~65530，0 表示停止');
      return;
    }
    Navigator.pop(context, parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('MCP 服务端口'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '独立 MCP 服务端口（对齐原版默认 1236）；'
            '留空或 0 停止独立服务，Web 端 /mcp/* 不受影响。',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: '1024 ~ 65530，0 停止',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: _confirm,
          child: Text(AppStrings.confirm),
        ),
      ],
    );
  }
}

/// 自定义 hosts JSON 编辑对话框（自持 StatefulWidget，照 _TextPromptDialog
/// 范式）：多行编辑 + 预填当前配置，确定回传原始文本，调用方做 JSON 对象
/// 校验（对齐原版 保存/清除/非法不保存 语义）。
/// [Task #74 | 2026-08-10] — Qoder
class _CustomHostsDialog extends StatefulWidget {
  final String initialText;

  const _CustomHostsDialog({required this.initialText});

  @override
  State<_CustomHostsDialog> createState() => _CustomHostsDialogState();
}

class _CustomHostsDialogState extends State<_CustomHostsDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义 hosts'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'JSON 对象格式：{"域名": "IP"} 或 {"域名": ["IP1","IP2"]}；'
            '保存后即时生效，空内容清除并恢复系统 DNS。',
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: TextField(
              controller: _controller,
              autofocus: true,
              minLines: 5,
              maxLines: 12,
              decoration: const InputDecoration(
                hintText: '{"example.com": "1.2.3.4"}',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(AppStrings.confirm),
        ),
      ],
    );
  }
}
