import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 隐私闸门加载占位：纯色背景 + 低透明度锁图标（无动画、无业务内容）。
///
/// 启动闸门与阅读器闸门共用：策略/私密标记未就绪时给出「正在准备」的
/// 视觉信号，避免首帧白屏被用户误判为闪退（P3-9）。
class PrivacySplashPlaceholder extends StatelessWidget {
  const PrivacySplashPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: Icon(
          Symbols.lock_rounded,
          size: 48,
          color: scheme.primary.withValues(alpha: 0.25),
        ),
      ),
    );
  }
}
