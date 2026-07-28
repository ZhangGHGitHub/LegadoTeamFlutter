import 'package:flutter/material.dart';

import 'src/routes.dart';

/// Legado App 入口 Widget
class LegadoApp extends StatelessWidget {
  /// 初始路由（首次启动时为欢迎页）
  final String initialRoute;

  const LegadoApp({super.key, this.initialRoute = AppRoutes.home});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Legado',
      debugShowCheckedModeBanner: false,
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: ThemeMode.system,
      initialRoute: initialRoute,
      routes: AppRoutes.routes,
    );
  }

  ThemeData _buildLightTheme() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF455A64),
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 1,
        indicatorColor: colorScheme.secondaryContainer,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF455A64),
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 1,
        indicatorColor: colorScheme.secondaryContainer,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
    );
  }
}
