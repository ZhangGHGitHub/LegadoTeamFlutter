import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 视频播放设置（对标原版 `ui/video/config/SettingsDialog` + `VideoPlay` prefs）
class VideoPlaySettings {
  static const _ns = 'videoPlay';
  static const autoPlayKey = '$_ns.autoPlay';
  static const startFullKey = '$_ns.startFull';
  static const longPressSpeedKey = '$_ns.longPressSpeed';
  static const fullBottomProgressKey = '$_ns.fullBottomProgressBar';

  bool autoPlay;
  bool startFull;
  /// 原版存 5–60 整数，实际倍速 = value / 10
  int longPressSpeed;
  bool fullBottomProgressBar;

  VideoPlaySettings({
    this.autoPlay = true,
    this.startFull = false,
    this.longPressSpeed = 30,
    this.fullBottomProgressBar = true,
  });

  double get pressSpeedFactor => longPressSpeed / 10.0;

  static Future<VideoPlaySettings> load() async {
    final p = await SharedPreferences.getInstance();
    return VideoPlaySettings(
      autoPlay: p.getBool(autoPlayKey) ?? true,
      startFull: p.getBool(startFullKey) ?? false,
      longPressSpeed: p.getInt(longPressSpeedKey) ?? 30,
      fullBottomProgressBar: p.getBool(fullBottomProgressKey) ?? true,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(autoPlayKey, autoPlay);
    await p.setBool(startFullKey, startFull);
    await p.setInt(longPressSpeedKey, longPressSpeed);
    await p.setBool(fullBottomProgressKey, fullBottomProgressBar);
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
          ? const SizedBox(
              height: 96,
              child: Center(child: CircularProgressIndicator()),
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
