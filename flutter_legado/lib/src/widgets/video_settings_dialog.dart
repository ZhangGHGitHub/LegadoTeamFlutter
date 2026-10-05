import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_progress_indicator.dart';

/// 视频播放设置（对标原版 `ui/video/config/SettingsDialog` + `VideoPlay` prefs）
class VideoPlaySettings {
  static const _ns = 'videoPlay';
  static const autoPlayKey = '$_ns.autoPlay';
  static const startFullKey = '$_ns.startFull';
  static const longPressSpeedKey = '$_ns.longPressSpeed';
  static const fullBottomProgressKey = '$_ns.fullBottomProgressBar';
  static const defaultFloatWindowKey = '$_ns.defaultFloatWindow';

  bool autoPlay;
  bool startFull;
  /// 原版存 5–60 整数，实际倍速 = value / 10
  int longPressSpeed;
  bool fullBottomProgressBar;

  /// [V-B3] 默认悬浮窗播放（对齐原版 VideoPlay.defaultFloatWindow /
  /// SettingsDialog.kt:26,30 的 cbDefaultFloatWindow；默认 false 同原版）
  bool defaultFloatWindow;

  VideoPlaySettings({
    this.autoPlay = true,
    this.startFull = false,
    this.longPressSpeed = 30,
    this.fullBottomProgressBar = true,
    this.defaultFloatWindow = false,
  });

  double get pressSpeedFactor => longPressSpeed / 10.0;

  static Future<VideoPlaySettings> load() async {
    final p = await SharedPreferences.getInstance();
    return VideoPlaySettings(
      autoPlay: p.getBool(autoPlayKey) ?? true,
      startFull: p.getBool(startFullKey) ?? false,
      longPressSpeed: p.getInt(longPressSpeedKey) ?? 30,
      fullBottomProgressBar: p.getBool(fullBottomProgressKey) ?? true,
      defaultFloatWindow: p.getBool(defaultFloatWindowKey) ?? false,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(autoPlayKey, autoPlay);
    await p.setBool(startFullKey, startFull);
    await p.setInt(longPressSpeedKey, longPressSpeed);
    await p.setBool(fullBottomProgressKey, fullBottomProgressBar);
    await p.setBool(defaultFloatWindowKey, defaultFloatWindow);
  }
}

/// 视频设置 Dialog（对标原版 SettingsDialog）
Future<VideoPlaySettings?> showVideoSettingsDialog(BuildContext context) {
  return showDialog<VideoPlaySettings>(
    context: context,
    builder: (_) => const _VideoSettingsDialog(),
  );
}

class _VideoSettingsDialog extends StatefulWidget {
  const _VideoSettingsDialog();

  @override
  State<_VideoSettingsDialog> createState() => _VideoSettingsDialogState();
}

class _VideoSettingsDialogState extends State<_VideoSettingsDialog> {
  VideoPlaySettings? _settings;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    VideoPlaySettings.load().then((s) {
      if (!mounted) return;
      setState(() {
        _settings = s;
        _loading = false;
      });
    });
  }

  Future<void> _persist() async {
    final s = _settings;
    if (s == null) return;
    await s.save();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = _settings;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('播放设置'),
      content: _loading || s == null
          // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（默认参数视觉等价）
          ? const SizedBox(
              height: 96,
              child: Center(child: AppCircularProgressIndicator()),
            )
          : SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动播放'),
                    value: s.autoPlay,
                    onChanged: (v) {
                      setState(() => s.autoPlay = v);
                      _persist();
                    },
                  ),
                  // [V-B3] 默认悬浮窗播放（对齐原版 dialog_video_settings.xml:
                  // 43-63 cb_default_float_window「默认悬浮窗播放」，默认 false；
                  // 开启后新开播放页解析出目标即转悬浮窗，对齐
                  // VideoPlayerActivity.kt:177-193 的 defaultFloatWindow 转发）
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('默认悬浮窗播放'),
                    value: s.defaultFloatWindow,
                    onChanged: (v) {
                      setState(() => s.defaultFloatWindow = v);
                      _persist();
                    },
                  ),
                  if (s.autoPlay)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('自动全屏'),
                      value: s.startFull,
                      onChanged: (v) {
                        setState(() => s.startFull = v);
                        _persist();
                      },
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('全屏底栏进度条'),
                    value: s.fullBottomProgressBar,
                    onChanged: (v) {
                      setState(() => s.fullBottomProgressBar = v);
                      _persist();
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('长按倍速'),
                    subtitle: Text(
                      '${s.pressSpeedFactor.toStringAsFixed(1)}x',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    onTap: () => _editPressSpeed(s),
                  ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _settings),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Future<void> _editPressSpeed(VideoPlaySettings s) async {
    var value = s.longPressSpeed.clamp(5, 60);
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('长按倍速'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${(value / 10.0).toStringAsFixed(1)}x'),
              Slider(
                min: 5,
                max: 60,
                divisions: 55,
                value: value.toDouble(),
                label: '${(value / 10.0).toStringAsFixed(1)}x',
                onChanged: (v) => setLocal(() => value = v.round()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 30),
              child: const Text('默认'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, value),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => s.longPressSpeed = result);
    await _persist();
  }
}

// ===== [P4-3 波次1b V3] 视频选集 / 倍速选择浮层（对齐原版 gsyVideo 对话框） =====
//
// 原版依据（本仓 app/src/main/java/io/legado/app/help/gsyVideo/）：
// - ChoiceEpisodeDialog.kt：靠右浮层（宽 40% 屏、全高、Gravity.END），
//   背景 #80121212；标题「选集（N）」；列表项 = 章节标题（白 15sp）；
//   打开时 setSelectionFromTop(当前集)；点击 → dismiss 后回调 position。
// - ChoiceSpeedDialog.kt / VideoPlayer.kt:403：靠右浮层（宽 30% 屏、全高），
//   档位 [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0].reversed()（降序），
//   项文案 = 档位 + "X"；点击 → dismiss 后回调档位值。
// - 入口仅存在于全屏控制器 video_layout_controller_full.xml（episode_list /
//   playback_speed / next）；非全屏控制器无此二入口。

/// 选集对话框的剧集项（对齐原版 `SwitchVideoAdapter<BookChapter>`）
class VideoEpisodeItem {
  /// 剧集标题（原版 BookChapter.title）
  final String title;

  /// 绝对章节索引（原版点击回调的 position）
  final int chapterIndex;

  const VideoEpisodeItem({required this.title, required this.chapterIndex});
}

/// 浮层背景（原版 switch_*_video_dialog.xml 背景 #80121212：
/// 50% 透明深色，属视频播放器黑底体系，亮/暗主题下均正确）
const Color kVideoDialogPanelColor = Color(0x80121212);

/// 选项卡底（原版 card_video_background：card_bg_water #69FDFDFD）
const Color kVideoDialogItemColor = Color(0x69FDFDFD);

/// 选项卡边框（原版 card_border_water #39424242，1px）
const Color kVideoDialogItemBorderColor = Color(0x39424242);

/// 当前选中项底色（原版无选中态，仅滚动定位；此侧加亮当前项以便辨识，
/// 沿用 water 卡片色系，比普通项更亮）
const Color kVideoDialogHighlightColor = Color(0x99FDFDFD);

/// 选项文字（原版 switch_video_dialog_item.xml：#FFFFFF 15sp）
const Color kVideoDialogTextColor = Color(0xFFFFFFFF);

/// 选项标题（原版 listCount：#88FFFFFF）
const Color kVideoDialogTitleColor = Color(0x88FFFFFF);

/// 倍速档位（对齐原版 VideoPlayer.kt:403，降序展示）
const List<double> kVideoSpeedChoices = [
  3.0,
  2.5,
  2.0,
  1.5,
  1.25,
  1.0,
  0.75,
  0.5,
];

/// 倍速入口文案（对齐原版 VideoPlayer.kt:409-414：
/// 1.0 → 「倍速」，其余 → 「X.XX X」）
String speedEntryLabel(double speed) =>
    speed == 1.0 ? '倍速' : '${speed}X';

/// 倍速 tip 文案（对齐原版 VideoPlayer.kt:411「X倍播放中」，展示 2 秒；
/// 长按倍速 tip「X倍速播放中」见 VideoPlayer.kt:112，勿混）
String speedTipLabel(double speed) => '$speed倍播放中';

/// 长按倍速 tip 文案（对齐原版 VideoPlayer.kt:112「X倍速播放中」；
/// 按住期间显示，松手 touchSurfaceUp 隐藏）
String longPressSpeedTipLabel(double speed) => '$speed倍速播放中';

/// 选集对话框（对齐原版 ChoiceEpisodeDialog）
///
/// 返回被选中的绝对章节索引；点屏障/系统返回关闭时返回 null。
Future<int?> showVideoEpisodeDialog(
  BuildContext context, {
  required List<VideoEpisodeItem> episodes,
  int? currentChapterIndex,
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => _VideoEpisodePanel(
      episodes: episodes,
      currentChapterIndex: currentChapterIndex,
    ),
  );
}

/// 倍速选择对话框（对齐原版 ChoiceSpeedDialog）
///
/// [currentSpeed] 用于高亮当前档位；返回被选中的倍速值，
/// 点屏障/系统返回关闭时返回 null。
Future<double?> showVideoSpeedDialog(
  BuildContext context, {
  double currentSpeed = 1.0,
}) {
  return showDialog<double>(
    context: context,
    builder: (_) => _VideoSpeedPanel(currentSpeed: currentSpeed),
  );
}

/// 选集浮层（靠右 40% 宽、全高；标题「选集（N）」；列表项=剧集标题）
class _VideoEpisodePanel extends StatefulWidget {
  final List<VideoEpisodeItem> episodes;
  final int? currentChapterIndex;

  const _VideoEpisodePanel({
    required this.episodes,
    required this.currentChapterIndex,
  });

  @override
  State<_VideoEpisodePanel> createState() => _VideoEpisodePanelState();
}

class _VideoEpisodePanelState extends State<_VideoEpisodePanel> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 对齐原版 setSelectionFromTop(initialSelection, 0)：
    // 打开时把当前集滚动到列表顶部
    final current = widget.currentChapterIndex;
    if (current != null && current > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        // 项高 ≈ padding 20 + 行高 ~20，估 56；超出可滚动范围时截断
        final target = 56.0 * current;
        final maxExtent = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(target.clamp(0.0, maxExtent));
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 对齐原版窗口参数：宽 = 0.4 * 屏宽，高 = 全高，Gravity.END 靠右
    final panelWidth = MediaQuery.of(context).size.width * 0.4;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: panelWidth,
        decoration: const BoxDecoration(color: kVideoDialogPanelColor),
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          children: [
            // 原版 listCount：「选集（N）」
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                '选集（${widget.episodes.length}）',
                style: const TextStyle(
                  color: kVideoDialogTitleColor,
                  fontSize: 14,
                ),
              ),
            ),
            Expanded(
              child: ListView.separated(
                controller: _scrollController,
                padding: const EdgeInsetsDirectional.only(start: 8, end: 16),
                itemCount: widget.episodes.length,
                separatorBuilder: (_, _) => const SizedBox(height: 4),
                itemBuilder: (context, i) {
                  final item = widget.episodes[i];
                  final isCurrent =
                      item.chapterIndex == widget.currentChapterIndex;
                  return _VideoDialogItem(
                    label: item.title,
                    highlighted: isCurrent,
                    // 原版：点击 → dismiss 后回调 position（绝对章节索引）
                    onTap: () => Navigator.of(context).pop(item.chapterIndex),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 倍速浮层（靠右 30% 宽、全高；8 档降序；列表垂直居中）
class _VideoSpeedPanel extends StatelessWidget {
  final double currentSpeed;

  const _VideoSpeedPanel({required this.currentSpeed});

  @override
  Widget build(BuildContext context) {
    // 对齐原版窗口参数：宽 = 0.3 * 屏宽，高 = 全高，Gravity.END 靠右
    final panelWidth = MediaQuery.of(context).size.width * 0.3;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: panelWidth,
        decoration: const BoxDecoration(color: kVideoDialogPanelColor),
        padding: const EdgeInsets.symmetric(vertical: 8),
        // 原版：两个 0dp/weight=1 的占位夹 wrap_content ListView → 垂直居中
        child: Center(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, end: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final value in kVideoSpeedChoices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _VideoDialogItem(
                      // 原版项文案：item.toString() + "X"（Kotlin Float 的
                      // toString 与 Dart double 一致：3.0→"3.0"、0.75→"0.75"）
                      label: '${value}X',
                      highlighted: (value - currentSpeed).abs() < 0.001,
                      // 原版：点击 → dismiss 后回调档位值
                      onTap: () => Navigator.of(context).pop(value),
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

/// 浮层选项卡（对齐原版 switch_video_dialog_item：白 15sp、
/// 左右 15 / 上下 10 padding、8dp 圆角卡片）
class _VideoDialogItem extends StatelessWidget {
  final String label;
  final bool highlighted;
  final VoidCallback onTap;

  const _VideoDialogItem({
    required this.label,
    required this.highlighted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            color: highlighted
                ? kVideoDialogHighlightColor
                : kVideoDialogItemColor,
            border: Border.all(
              color: kVideoDialogItemBorderColor,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          child: Text(
            label,
            style: const TextStyle(color: kVideoDialogTextColor, fontSize: 15),
          ),
        ),
      ),
    );
  }
}
