// [V-B4] 视频长按倍速手势区
//
// 原版依据（app/src/main/java/io/legado/app/help/gsyVideo/VideoPlayer.kt）：
// - :108-115 onLongPress：仅 CURRENT_STATE_PLAYING 生效 → 临时提速
//   （longPressSpeed/10.0f）+ tip「X倍速播放中」+ isLongPressSpeed=true；
// - :124-133 touchSurfaceUp：本次长按已生效才恢复原倍速 + 隐藏 tip +
//   resolveDanmakuStart(当前位置)；
// - 非长按的点击/双击仍交回宿主（onTap/onDoubleTap），互不干扰。
import 'package:flutter/material.dart';

/// 长按倍速手势包装：宿主提供提速/恢复回调与「播放中」开关。
///
/// 语义要点：
/// - [enabled]（播放中）为 false 时长按不生效（对齐 `mCurrentState ==
///   CURRENT_STATE_PLAYING` 判定）；
/// - 只有本次长按真正触发过 [onSpeedUp] 才会回调 [onRestore]（未长按的
///   轻触松手不误恢复）；
/// - 长按取消/抬手（onLongPressUp/End/Cancel）都会恢复，避免倍速卡在临时值。
class VideoLongPressSpeedArea extends StatefulWidget {
  const VideoLongPressSpeedArea({
    super.key,
    required this.enabled,
    required this.onSpeedUp,
    required this.onRestore,
    this.onTap,
    this.onDoubleTap,
    required this.child,
  });

  /// 播放中才允许长按提速（对齐原版 CURRENT_STATE_PLAYING 判定）
  final bool enabled;

  /// 长按触发：临时提速并显示 tip
  final VoidCallback onSpeedUp;

  /// 松手/取消：恢复会话倍速（仅本次长按触发后回调）
  final VoidCallback onRestore;

  /// 单击（宿主用于切换控制栏显隐）
  final VoidCallback? onTap;

  /// 双击（宿主用于播放/暂停）
  final VoidCallback? onDoubleTap;

  final Widget child;

  @override
  State<VideoLongPressSpeedArea> createState() =>
      _VideoLongPressSpeedAreaState();
}

class _VideoLongPressSpeedAreaState extends State<VideoLongPressSpeedArea> {
  /// 本次手势是否已触发长按提速（松手时据此决定是否恢复）
  bool _active = false;

  void _handleLongPress() {
    if (!widget.enabled || _active) return;
    _active = true;
    widget.onSpeedUp();
  }

  void _handleRelease() {
    if (!_active) return;
    _active = false;
    widget.onRestore();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      onLongPress: widget.enabled ? _handleLongPress : null,
      onLongPressUp: _handleRelease,
      onLongPressEnd: (_) => _handleRelease(),
      onLongPressCancel: _handleRelease,
      child: widget.child,
    );
  }
}
