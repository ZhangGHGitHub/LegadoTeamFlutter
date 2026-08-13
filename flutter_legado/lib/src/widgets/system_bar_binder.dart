import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/theme/system_bar_notifier.dart';
import '../providers/theme/theme_colors_notifier.dart';
import '../providers/theme/theme_notifier.dart';
import '../services/system_bar_service.dart';

/// 监听主题与系统栏偏好，全局同步 SystemChrome / Android Window
class SystemBarBinder extends ConsumerStatefulWidget {
  final Widget child;

  const SystemBarBinder({super.key, required this.child});

  @override
  ConsumerState<SystemBarBinder> createState() => _SystemBarBinderState();
}

class _SystemBarBinderState extends ConsumerState<SystemBarBinder>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _apply());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    _apply();
  }

  void _apply() {
    if (!mounted) return;
    final systemBar = ref.read(systemBarProvider);
    if (!systemBar.loaded) return;

    final theme = Theme.of(context);
    final appBarColor =
        theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface;
    final navBarColor = theme.navigationBarTheme.backgroundColor ??
        theme.colorScheme.surface;

    SystemBarService.apply(
      transparentStatusBar: systemBar.transparentStatusBar,
      immNavigationBar: systemBar.immNavigationBar,
      appBarColor: appBarColor,
      navigationBarColor: navBarColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SystemBarState>(systemBarProvider, (_, _) => _apply());
    ref.listen(themeColorsProvider, (_, _) => _apply());
    ref.listen(themeNotifierProvider, (_, _) => _apply());
    return widget.child;
  }
}
