import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart' show ReaderBackground;
import '../routes.dart';
import '../services/settings_service.dart';

/// 其他设置页面
///
/// 对标 Android 原版「其他设置」（OtherConfigFragment）中 Flutter 已实现的部分：
/// - 语言切换
/// - 默认阅读设置（字号 / 行距 / 背景色）
/// - 网络设置（代理 / 请求超时 / QUIC·HTTP3）
/// - 缓存管理入口
///
/// 拆分自原单体 SettingsScreen，作为设置枢纽「其他设置」入口的目标页。
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
  bool _quicEnabled = false; // QUIC/HTTP3 开关（实验性，默认关闭）

  @override
  void initState() {
    super.initState();
    _loadLocale();
    _loadReadSettings();
    _loadNetworkSettings();
  }

  Future<void> _loadLocale() async {
    _localeValue = await _settingsService.getLocale();
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
    // 加载 QUIC 开关状态（经 BookApi 查询 Rust 侧全局配置）
    try {
      _quicEnabled = await ref.read(bookApiProvider).netIsQuicEnabled();
    } catch (_) {
      _quicEnabled = false; // FFI 不可用时默认关闭
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('其他设置')),
      body: ListView(
        children: [
          // ===== 语言 =====
          _buildSectionHeader(context, AppStrings.language),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(AppStrings.language),
            subtitle: Text(_localeLabel),
            onTap: () => _showLocalePicker(context),
          ),
          const Divider(),

          // ===== 默认阅读设置 =====
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
          SwitchListTile(
            secondary: const Icon(Icons.speed),
            title: const Text('QUIC/HTTP3'),
            subtitle: const Text('启用 HTTP/3 传输（实验性）'),
            value: _quicEnabled,
            onChanged: (value) async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await ref.read(bookApiProvider).netSetQuicEnabled(value);
                setState(() => _quicEnabled = value);
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text('QUIC 设置失败: $e')),
                );
              }
            },
          ),
          const Divider(),

          // ===== 缓存 =====
          _buildSectionHeader(context, '缓存'),
          ListTile(
            leading: const Icon(Icons.cleaning_services),
            title: const Text('缓存管理'),
            subtitle: const Text('缓存统计、自动过期策略与清理'),
            onTap: () => Navigator.pushNamed(context, AppRoutes.cacheSettings),
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
}
