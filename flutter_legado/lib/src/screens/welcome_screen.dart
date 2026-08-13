import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../models/book.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../services/platform_bridge_service.dart';
import '../services/settings_service.dart';
import '../utils/book_open_utils.dart';

/// 启动闪屏（对齐原版 WelcomeActivity + activity_welcome.xml）
///
/// 结构：竖排「阅读」标题 + 副标、书图标、底部文案；按 [PrefKeys.welcomeShowTime]
/// 延时后进入主页（0 则立即进入）。支持自定义欢迎图与日/夜显隐偏好。
/// 非三页功能介绍轮播（审计 D2 / P2-11）。
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  SettingsService get _settings => ref.read(settingsProvider);
  Timer? _timer;
  bool _navigating = false;

  bool _customWelcome = false;
  bool _showIcon = true;
  bool _showText = true;
  bool _showIconDark = true;
  bool _showTextDark = true;
  String? _bgImageDay;
  String? _bgImageNight;

  late final AnimationController _fade =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
  late final Animation<double> _opacity =
      CurvedAnimation(parent: _fade, curve: Curves.easeOut);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final custom =
        await _settings.getBoolPref(PrefKeys.customWelcome, defaultValue: false);
    final showTime = await _settings.getIntPref(
      PrefKeys.welcomeShowTime,
      defaultValue: 500,
    );
    final showIcon = await _settings.getBoolPref(
      PrefKeys.welcomeShowIcon,
      defaultValue: true,
    );
    final showText = await _settings.getBoolPref(
      PrefKeys.welcomeShowText,
      defaultValue: true,
    );
    final showIconDark = await _settings.getBoolPref(
      PrefKeys.welcomeShowIconDark,
      defaultValue: true,
    );
    final showTextDark = await _settings.getBoolPref(
      PrefKeys.welcomeShowTextDark,
      defaultValue: true,
    );
    String? imageDay;
    String? imageNight;
    if (custom) {
      final day = await _settings.getStringPref(PrefKeys.welcomeImage);
      final night = await _settings.getStringPref(PrefKeys.welcomeImageDark);
      if (day.isNotEmpty) imageDay = day;
      if (night.isNotEmpty) imageNight = night;
    }

    if (!mounted) return;
    setState(() {
      _customWelcome = custom;
      _showIcon = showIcon;
      _showText = showText;
      _showIconDark = showIconDark;
      _showTextDark = showTextDark;
      _bgImageDay = imageDay;
      _bgImageNight = imageNight;
    });
    _fade.forward();

    if (showTime <= 0) {
      await _goNext();
      return;
    }
    _timer = Timer(Duration(milliseconds: showTime.clamp(0, 800)), _goNext);
  }

  Future<void> _goNext() async {
    if (_navigating || !mounted) return;
    _navigating = true;
    _timer?.cancel();

    Book? lastRead;
    final defaultToRead = await _settings.getBoolPref(
      PrefKeys.defaultToRead,
      defaultValue: false,
    );
    if (defaultToRead) {
      try {
        final books = await ref.read(bookApiProvider).getBooks();
        if (books.isNotEmpty) {
          lastRead = books.reduce(
            (a, b) => a.durChapterTime >= b.durChapterTime ? a : b,
          );
          if (lastRead.durChapterTime <= 0) lastRead = null;
        }
      } catch (_) {
        lastRead = null;
      }
    }

    if (!mounted) return;
    // 对齐原版：先 MainActivity，再按需 ReadBookActivity
    await Navigator.of(context).pushReplacementNamed(AppRoutes.home);
    if (lastRead != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openLastRead(lastRead!);
      });
    }
  }

  Future<void> _openLastRead(Book book) async {
    final nav = PlatformBridgeService.navigatorKey.currentState;
    final ctx = PlatformBridgeService.navigatorKey.currentContext;
    if (nav == null || ctx == null) return;

    var typeBits = BookOpenUtils.typeBitsOf(book);
    if (BookOpenUtils.isOnlineBook(book)) {
      try {
        final sources = await ref.read(bookApiProvider).getBookSources();
        String norm(String u) => u.trim().replaceAll(RegExp(r'/+$'), '');
        final o = norm(book.origin);
        for (final s in sources) {
          if (norm(s.bookSourceUrl) == o || s.bookSourceUrl == book.origin) {
            typeBits = BookOpenUtils.resolveTypeBits(typeBits, s);
            break;
          }
        }
      } catch (_) {}
    }

    final bookToOpen =
        typeBits != 0 ? book.copyWith(bookType: typeBits) : book;
    final route = BookOpenUtils.routeForTypeBits(typeBits);
    if (BookOpenUtils.needsReaderNotifier(route)) {
      ref.read(readerNotifierProvider.notifier).openBook(bookToOpen);
      await nav.pushNamed(route);
      return;
    }
    await nav.pushNamed(
      route,
      arguments: BookOpenUtils.argumentsForRoute(route, bookToOpen),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary;
    final showIcon = isDark ? _showIconDark : _showIcon;
    final showText = isDark ? _showTextDark : _showText;
    final path = isDark ? _bgImageNight : _bgImageDay;

    DecorationImage? bgImage;
    if (_customWelcome && path != null && File(path).existsSync()) {
      bgImage = DecorationImage(
        image: FileImage(File(path)),
        fit: BoxFit.cover,
      );
    }

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          image: bgImage,
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _opacity,
            child: Stack(
              children: [
                // 标题区（约垂直偏上，对齐原版 bias 0.4）
                Align(
                  alignment: const Alignment(0, -0.35),
                  child: showText
                      ? _WelcomeTitle(accent: accent)
                      : const SizedBox.shrink(),
                ),
                // 书图标
                Align(
                  alignment: const Alignment(0, 0.35),
                  child: showIcon
                      ? Icon(
                          Icons.menu_book_rounded,
                          size: 120,
                          color: accent,
                        )
                      : const SizedBox.shrink(),
                ),
                // 底部文案
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 32),
                    child: showText
                        ? Text(
                            '品读万千故事',
                            style: TextStyle(
                              fontSize: 16,
                              letterSpacing: 1.6,
                              color: accent,
                              fontWeight: FontWeight.w500,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 竖排「阅读」+ 横排副标（结构对齐 activity_welcome.xml；视觉偏系统字重）
class _WelcomeTitle extends StatelessWidget {
  final Color accent;

  const _WelcomeTitle({required this.accent});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 6,
          height: 120,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 竖排「阅读」
            Text(
              '阅\n读',
              style: TextStyle(
                fontSize: 48,
                height: 1.05,
                fontWeight: FontWeight.w600,
                color: accent,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
        const SizedBox(width: 10),
        Padding(
          padding: const EdgeInsets.only(top: 58),
          child: Text(
            '享\n受\n美\n好\n时\n光',
            style: TextStyle(
              fontSize: 15,
              height: 1.25,
              fontWeight: FontWeight.w400,
              color: accent.withValues(alpha: 0.85),
            ),
          ),
        ),
      ],
    );
  }
}
