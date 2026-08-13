import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../providers/reader/reader_notifier.dart';
import '../../screens/reader_config_panel.dart';
import 'reader_page_chrome.dart';

/// 隐藏控制栏时顶部的状态提示栏（电量/时间/进度/章节名）
///
/// 对齐安卓原版阅读器顶部状态提示（ReadTipConfig 控制显隐）
class ReaderStatusStrip extends ConsumerWidget {
  final ReaderAdvancedConfig config;

  /// 正文延伸至状态栏（readBodyToLh）
  final bool readBodyToLh;

  const ReaderStatusStrip({
    super.key,
    required this.config,
    this.readBodyToLh = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerNotifierProvider);

    if (!config.showBattery &&
        !config.showTime &&
        !config.showProgress &&
        !config.showChapterName) {
      return const SizedBox.shrink();
    }

    final isDark = state.isDarkBackground;
    final color = isDark ? const Color(0xFFBBBBBB) : const Color(0xFF888888);
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final progress = '${(state.readingProgress * 100).toStringAsFixed(1)}%';

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        minimum: EdgeInsets.only(
          top: config.hideStatusBar
              ? 0
              : readerOverlayStatusBarInset(
                  context,
                  readBodyToLh: readBodyToLh,
                ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: DefaultTextStyle(
            style: TextStyle(fontSize: 11, color: color),
            child: Row(
              children: [
                if (config.showBattery) ...[
                  Icon(Icons.battery_std, size: 12, color: color),
                  const SizedBox(width: 4),
                ],
                if (config.showTime) ...[
                  Text(time),
                  const SizedBox(width: 10),
                ],
                const Spacer(),
                if (config.showChapterName)
                  Flexible(
                    child: Text(
                      state.currentChapter?.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (config.showProgress) ...[
                  const SizedBox(width: 10),
                  Text(progress),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
