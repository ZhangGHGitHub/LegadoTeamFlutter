import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';
import '../routes.dart';
import '../services/settings_service.dart';

/// 欢迎页
///
/// 首次启动展示：应用 logo + 功能介绍轮播（3 页）+ "开始使用" 跳转主页。
/// 通过 SharedPreferences 的 [kWelcomeShownKey] 标记是否已展示过。
class WelcomeScreen extends StatefulWidget {
  /// 首次启动标记 key（main.dart 中读取以决定 initialRoute）
  static const kWelcomeShownKey = 'welcome_shown';

  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _pageController = PageController();
  int _currentPage = 0;

  // [UI-fix v2.0.5 | 2026-08-08] 接通主题设置页「欢迎页样式」偏好：
  // welcomeShowIcon 控制 Logo 图标显隐、welcomeShowText 控制文字显隐，
  // 键名对齐原版 PreferKey（pref_config_welcome.xml，默认均为开） — Qoder
  bool _showIcon = true;
  bool _showText = true;

  @override
  void initState() {
    super.initState();
    _loadWelcomeStyle();
  }

  /// 读取欢迎页样式偏好（主题设置页「欢迎页样式」对话框写入）
  Future<void> _loadWelcomeStyle() async {
    final settings = SettingsService();
    _showIcon =
        await settings.getBoolPref(PrefKeys.welcomeShowIcon, defaultValue: true);
    _showText =
        await settings.getBoolPref(PrefKeys.welcomeShowText, defaultValue: true);
    if (mounted) setState(() {});
  }

  static const _introPages = [
    _IntroPage(
      icon: Icons.explore_outlined,
      title: '海量书源',
      description: '支持自定义书源规则，\n全网小说一键搜索、换源阅读。',
    ),
    _IntroPage(
      icon: Icons.menu_book_outlined,
      title: '沉浸阅读',
      description: '多种阅读背景与字体，\n翻页动画、亮度调节，阅读更舒适。',
    ),
    _IntroPage(
      icon: Icons.cloud_sync_outlined,
      title: '多端同步',
      description: '书架、进度、替换规则云端备份，\n随时随地无缝续读。',
    ),
  ];

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(WelcomeScreen.kWelcomeShownKey, true);
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(AppRoutes.home);
  }

  void _onPageChanged(int page) => setState(() => _currentPage = page);

  void _next() {
    if (_currentPage < _introPages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _finish();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLast = _currentPage == _introPages.length - 1;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 跳过按钮
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: _finish,
                child: const Text('跳过'),
              ),
            ),
            // Logo + 名称（显隐受「欢迎页样式」偏好控制）
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: Column(
                children: [
                  // [UI-fix v2.0.5 | 2026-08-08] welcomeShowIcon 控制 Logo 显隐 — Qoder
                  if (_showIcon) ...[
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(
                        Icons.auto_stories,
                        size: 40,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // [UI-fix v2.0.5 | 2026-08-08] welcomeShowText 控制文字显隐 — Qoder
                  if (_showText) ...[
                    Text(
                      'Legado',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '开源阅读 · Rust 引擎驱动',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 功能介绍轮播
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: _onPageChanged,
                itemCount: _introPages.length,
                itemBuilder: (context, index) {
                  final page = _introPages[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          page.icon,
                          size: 96,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          page.title,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          page.description,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            // 指示点
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_introPages.length, (index) {
                final active = index == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 20 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            const SizedBox(height: 24),
            // 开始使用按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 0, 40, 32),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _next,
                  child: Text(isLast ? '开始使用' : '下一页'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IntroPage {
  final IconData icon;
  final String title;
  final String description;

  const _IntroPage({
    required this.icon,
    required this.title,
    required this.description,
  });
}
