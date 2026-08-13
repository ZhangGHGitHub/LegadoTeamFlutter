import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';

import '../constants/pref_keys.dart';
import '../services/settings_service.dart';
import '../widgets/ios_widgets.dart';

/// 欢迎页样式配置（对齐原版 WelcomeConfigFragment + pref_config_welcome.xml）
///
/// 分组：显示时长 / 自定义欢迎 / 白天 / 夜间。视觉用 iOS 分组列表（apple-ui-designer）。
class WelcomeConfigScreen extends StatefulWidget {
  const WelcomeConfigScreen({super.key});

  @override
  State<WelcomeConfigScreen> createState() => _WelcomeConfigScreenState();
}

class _WelcomeConfigScreenState extends State<WelcomeConfigScreen> {
  final _settings = SettingsService();
  bool _loading = true;

  int _showTime = 500;
  bool _customWelcome = false;
  String _imageDay = '';
  String _imageNight = '';
  bool _showText = true;
  bool _showIcon = true;
  bool _showTextDark = true;
  bool _showIconDark = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = _settings;
    final showTime =
        await s.getIntPref(PrefKeys.welcomeShowTime, defaultValue: 500);
    final custom =
        await s.getBoolPref(PrefKeys.customWelcome, defaultValue: false);
    final imageDay = await s.getStringPref(PrefKeys.welcomeImage);
    final imageNight = await s.getStringPref(PrefKeys.welcomeImageDark);
    final showText =
        await s.getBoolPref(PrefKeys.welcomeShowText, defaultValue: true);
    final showIcon =
        await s.getBoolPref(PrefKeys.welcomeShowIcon, defaultValue: true);
    final showTextDark =
        await s.getBoolPref(PrefKeys.welcomeShowTextDark, defaultValue: true);
    final showIconDark =
        await s.getBoolPref(PrefKeys.welcomeShowIconDark, defaultValue: true);
    if (!mounted) return;
    setState(() {
      _showTime = showTime.clamp(0, 800);
      _customWelcome = custom;
      _imageDay = imageDay;
      _imageNight = imageNight;
      _showText = showText;
      _showIcon = showIcon;
      _showTextDark = showTextDark;
      _showIconDark = showIconDark;
      _loading = false;
    });
  }

  Future<void> _pickImage({required bool dark}) async {
    final current = dark ? _imageNight : _imageDay;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('选择图片'),
              onTap: () => Navigator.pop(ctx, 'select'),
            ),
            if (current.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除'),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'select') {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        dialogTitle: '选择欢迎页背景',
      );
      final path = result?.files.single.path;
      if (path == null || !mounted) return;
      setState(() {
        if (dark) {
          _imageNight = path;
        } else {
          _imageDay = path;
        }
      });
      await _settings.setStringPref(
        dark ? PrefKeys.welcomeImageDark : PrefKeys.welcomeImage,
        path,
      );
    } else if (action == 'delete') {
      setState(() {
        if (dark) {
          _imageNight = '';
        } else {
          _imageDay = '';
        }
      });
      await _settings.setStringPref(
        dark ? PrefKeys.welcomeImageDark : PrefKeys.welcomeImage,
        '',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: LegadoAppBar(title: const Text('欢迎页样式')),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : IosGroupedBody(
              child: ListView(
                children: [
                  const IosSectionHeader('显示时长'),
                  IosGroup(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '启动闪屏停留 $_showTime 毫秒',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                          Text(
                            '$_showTime',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                    Slider(
                      value: _showTime.toDouble(),
                      min: 0,
                      max: 800,
                      divisions: 80,
                      label: '$_showTime',
                      onChanged: (v) {
                        setState(() => _showTime = v.round());
                      },
                      onChangeEnd: (v) {
                        final ms = v.round().clamp(0, 800);
                        setState(() => _showTime = ms);
                        _settings.setIntPref(PrefKeys.welcomeShowTime, ms);
                      },
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        '设为 0 则跳过闪屏直接进入主页',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ),
                  ]),
                  const IosSectionHeader('自定义'),
                  IosGroup(children: [
                    SwitchListTile.adaptive(
                      title: const Text('自定义欢迎页'),
                      subtitle: const Text('启用后可设置日/夜背景图'),
                      value: _customWelcome,
                      onChanged: (v) {
                        setState(() => _customWelcome = v);
                        _settings.setBoolPref(PrefKeys.customWelcome, v);
                      },
                    ),
                  ]),
                  const IosSectionHeader('白天'),
                  IosGroup(children: [
                    IosListTile(
                      icon: Icons.wallpaper_outlined,
                      iconBackground: Colors.teal,
                      title: '背景图片',
                      subtitle: _imageDay.isEmpty ? '选择图片' : _imageDay,
                      showDisclosure: true,
                      onTap: () => _pickImage(dark: false),
                    ),
                    SwitchListTile.adaptive(
                      title: const Text('显示文字'),
                      subtitle: const Text('阅读 / 享受美好时光 / 品读万千故事'),
                      value: _showText,
                      onChanged: (v) {
                        setState(() => _showText = v);
                        _settings.setBoolPref(PrefKeys.welcomeShowText, v);
                      },
                    ),
                    SwitchListTile.adaptive(
                      title: const Text('显示图标'),
                      subtitle: const Text('默认书本图标'),
                      value: _showIcon,
                      onChanged: (v) {
                        setState(() => _showIcon = v);
                        _settings.setBoolPref(PrefKeys.welcomeShowIcon, v);
                      },
                    ),
                  ]),
                  const IosSectionHeader('夜间'),
                  IosGroup(children: [
                    IosListTile(
                      icon: Icons.wallpaper_outlined,
                      iconBackground: Colors.indigo,
                      title: '背景图片',
                      subtitle: _imageNight.isEmpty ? '选择图片' : _imageNight,
                      showDisclosure: true,
                      onTap: () => _pickImage(dark: true),
                    ),
                    SwitchListTile.adaptive(
                      title: const Text('显示文字'),
                      subtitle: const Text('阅读 / 享受美好时光 / 品读万千故事'),
                      value: _showTextDark,
                      onChanged: (v) {
                        setState(() => _showTextDark = v);
                        _settings.setBoolPref(PrefKeys.welcomeShowTextDark, v);
                      },
                    ),
                    SwitchListTile.adaptive(
                      title: const Text('显示图标'),
                      subtitle: const Text('默认书本图标'),
                      value: _showIconDark,
                      onChanged: (v) {
                        setState(() => _showIconDark = v);
                        _settings.setBoolPref(PrefKeys.welcomeShowIconDark, v);
                      },
                    ),
                  ]),
                  const IosSectionFooter(
                    '闪屏结构对齐原版 WelcomeActivity；背景图仅在开启「自定义欢迎页」时生效。',
                  ),
                ],
              ),
            ),
    );
  }
}
