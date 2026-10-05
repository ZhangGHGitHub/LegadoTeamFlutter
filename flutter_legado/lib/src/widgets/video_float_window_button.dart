import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// [V-B3] 视频悬浮窗入口按钮
///
/// 对齐原版 `menu/video_play.xml` 的 `menu_float_window`（视频播放页顶栏
/// 「悬浮窗」always 动作，tooltip = R.string.float_window「悬浮窗」；
/// 原版点击 → VideoPlayerActivity.startFloatingWindow :729-738）。
/// 解析出播放地址前（onPressed == null）禁用。
class VideoFloatWindowButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const VideoFloatWindowButton({super.key, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Symbols.picture_in_picture_rounded),
      tooltip: '悬浮窗',
      onPressed: onPressed,
    );
  }
}
