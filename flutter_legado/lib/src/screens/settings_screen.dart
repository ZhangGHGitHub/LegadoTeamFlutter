import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_strings.dart';
import '../providers/reader_provider.dart' show ReaderBackground;
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

  // 默认阅读设置当前值
  double _fontSize = 18.0;
  double _lineHeight = 1.6;
  int _bgColorIndex = 0;

  // 网络设置当前值
  String _proxyType = 'none'; // none / http / socks5
  String _proxyHost = '';
  int _proxyPort = 0;
  int _timeoutSeconds = 30;

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
    _loadReadSettings();
    _loadNetworkSettings();
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
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('主题配置'),
            subtitle: const Text('字体、行距、背景色综合设置'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.themeConfig),
          ),
          ListTile(
            leading: const Icon(Icons.font_download_outlined),
            title: const Text('字体管理'),
            subtitle: const Text('系统字体切换与自定义字体导入'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.fonts),
          ),
          const Divider(),

          // ===== 阅读设置 =====
          _buildSectionHeader(context, AppStrings.readingSettings),
          ListTile(
            leading: const Icon(Icons.text_fields),
            title: Text(AppStrings.defaultFontSize),
            subtitle: Text(_fontSize.toStringAsFixed(0)),
            onTap: () => _showDefaultReadSettings(context),
          ),
          ListTile(
            leading: const Icon(Icons.format_line_spacing),
            title: Text(AppStrings.defaultLineHeight),
            subtitle: Text('${_lineHeight.toStringAsFixed(1)}x'),
            onTap: () => _showDefaultReadSettings(context),
          ),
          ListTile(
            leading: const Icon(Icons.palette),
            title: Text(AppStrings.defaultBgColor),
            subtitle: Text(_bgColorLabel),
            onTap: () => _showDefaultReadSettings(context),
          ),
          ListTile(
            leading: const Icon(Icons.bar_chart),
            title: const Text('阅读统计'),
            subtitle: const Text('查看阅读时长与书籍分布'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.readingStats),
          ),
          ListTile(
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('朗读引擎'),
            subtitle: const Text('HTTP TTS 引擎管理'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.readAloudConfig),
          ),
          const Divider(),

          // ===== 网络设置 =====
          _buildSectionHeader(context, AppStrings.networkSettings),
          ListTile(
            leading: const Icon(Icons.wifi),
            title: Text(AppStrings.proxySettings),
            subtitle: Text(_proxyLabel),
            onTap: () => _showProxySettings(context),
          ),
          ListTile(
            leading: const Icon(Icons.timer),
            title: Text(AppStrings.requestTimeout),
            subtitle: Text('$_timeoutSeconds ${AppStrings.secondsUnit}'),
            onTap: () => _showTimeoutSettings(context),
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
            leading: const Icon(Icons.cloud_sync),
            title: const Text('WebDAV 同步'),
            subtitle: const Text('连接测试、同步进度与自动同步配置'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.webdavSettings),
          ),
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
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Legado',
              applicationVersion: '2.0.0',
              applicationLegalese: 'GPL-3.0 License',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(AppStrings.projectUrl),
            subtitle: const Text('github.com/gedoor/legado'),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final uri = Uri.parse('https://github.com/gedoor/legado');
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              } else {
                messenger.showSnackBar(
                  const SnackBar(content: Text('https://github.com/gedoor/legado')),
                );
              }
            },
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
            onPressed: () async {
              Navigator.pop(ctx);
              final messenger = ScaffoldMessenger.of(context);
              try {
                final api = context.read<RustApi>();
                await api.clearCache();
                messenger.showSnackBar(
                  SnackBar(content: Text(AppStrings.cacheCleared)),
                );
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text('清除缓存失败: $e')),
                );
              }
            },
            child: Text(AppStrings.confirm),
          ),
        ],
      ),
    );
  }

  // ===== 默认阅读设置 / 网络设置对话框 =====

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
                                      : Colors.grey.shade300,
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
      if (saved != true) return;
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
      if (saved != true) return;

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
      if (saved != true) return;
      setState(() => _timeoutSeconds = seconds.round());
      await _settingsService.setRequestTimeout(seconds.round());
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.configSaved)),
      );
    });
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
