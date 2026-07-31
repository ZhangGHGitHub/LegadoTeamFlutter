import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/audio_provider.dart';

/// 预设定时时长（分钟）
const List<int> _kPresetMinutes = [5, 10, 15, 30];

/// 听书播放页面
class AudioScreen extends StatefulWidget {
  /// 书籍对象（路由参数规范化：优先使用 Book 对象）
  final Book? book;

  /// 书籍 URL（向后兼容）
  final String bookUrl;

  /// 书名（向后兼容）
  final String bookName;

  const AudioScreen({
    super.key,
    this.book,
    this.bookUrl = '',
    this.bookName = '',
  });

  /// 获取有效的 bookUrl
  String get effectiveBookUrl => book?.bookUrl ?? bookUrl;

  /// 获取有效的书名
  String get effectiveBookName => book?.name ?? bookName;

  @override
  State<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends State<AudioScreen> {
  bool _showSettings = false;

  // ===== 定时停止相关状态 =====

  /// 定时器实例
  Timer? _stopTimer;

  /// 剩余秒数，为 0 表示未启用定时
  int _remainingSeconds = 0;

  /// 自定义时长输入控制器
  final TextEditingController _customMinutesController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<AudioProvider>();
      // 初始化媒体会话（后台播放 + 媒体按钮 + 焦点管理）
      provider.initMediaSession(bookName: widget.effectiveBookName);
      if (!provider.hasChapters) {
        provider.loadChapters(widget.effectiveBookUrl);
      }
    });
  }

  @override
  void dispose() {
    // 页面销毁时清理定时器和媒体会话
    _stopTimer?.cancel();
    _customMinutesController.dispose();
    // 释放媒体会话资源（后台播放/焦点）
    context.read<AudioProvider>().releaseMediaSession();
    super.dispose();
  }

  // ===== 定时停止逻辑 =====

  /// 是否正在倒计时
  bool get _isTimerActive => _remainingSeconds > 0;

  /// 启动定时停止
  void _startTimer(int minutes) {
    // 取消已有定时器
    _stopTimer?.cancel();

    final totalSeconds = minutes * 60;
    setState(() => _remainingSeconds = totalSeconds);

    // 每秒更新倒计时
    _stopTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _remainingSeconds--;
        if (_remainingSeconds <= 0) {
          // 倒计时结束，暂停播放
          timer.cancel();
          _remainingSeconds = 0;
          if (mounted) {
            context.read<AudioProvider>().pause();
          }
        }
      });
    });
  }

  /// 取消定时停止
  void _cancelTimer() {
    _stopTimer?.cancel();
    _stopTimer = null;
    setState(() => _remainingSeconds = 0);
  }

  /// 格式化倒计时文本 mm:ss
  String _formatCountdown(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// 显示定时选择底部弹窗
  void _showTimerPicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  '定时停止',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              // 预设时间选项
              ..._kPresetMinutes.map(
                (minutes) => ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text('$minutes 分钟'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _startTimer(minutes);
                  },
                ),
              ),
              // 自定义时长
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Row(
                  children: [
                    const Text('自定义'),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 60,
                      child: TextField(
                        controller: _customMinutesController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          hintText: '分钟',
                          isDense: true,
                          border: UnderlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('分钟'),
                  ],
                ),
                onTap: () {
                  final value =
                      int.tryParse(_customMinutesController.text) ?? 0;
                  if (value > 0 && value <= 180) {
                    Navigator.pop(sheetContext);
                    _startTimer(value);
                  }
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.effectiveBookName.isNotEmpty ? widget.effectiveBookName : '听书'),
        actions: [
          // 定时停止按钮
          _buildTimerButton(),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => setState(() => _showSettings = !_showSettings),
          ),
        ],
      ),
      body: Consumer<AudioProvider>(
        builder: (context, provider, _) {
          if (provider.isLoading && !provider.hasChapters) {
            return const Center(child: CircularProgressIndicator());
          }
          if (provider.state == PlayerState.error && !provider.hasChapters) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 64, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 16),
                  Text(provider.errorMessage ?? '加载失败'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => provider.loadChapters(widget.effectiveBookUrl),
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }

          return Column(
            children: [
              // 当前章节信息
              _buildNowPlayingCard(provider),
              // 进度条
              _buildProgressBar(provider),
              // 播放控制
              _buildControls(provider),
              // 倒计时显示（定时激活时）
              if (_isTimerActive) _buildCountdownBar(),
              const Divider(),
              // 设置面板（可展开）
              if (_showSettings) _buildSettingsPanel(provider),
              // 章节列表
              Expanded(child: _buildChapterList(provider)),
              // 后台播放提示
              _buildBackgroundNotice(),
            ],
          );
        },
      ),
    );
  }

  /// 定时停止按钮（AppBar 中）
  Widget _buildTimerButton() {
    return IconButton(
      icon: Icon(
        _isTimerActive ? Icons.timer : Icons.timer_outlined,
        color: _isTimerActive ? Theme.of(context).colorScheme.error : null,
      ),
      tooltip: _isTimerActive ? '取消定时' : '定时停止',
      onPressed: () {
        if (_isTimerActive) {
          _cancelTimer();
        } else {
          _showTimerPicker();
        }
      },
    );
  }

  /// 倒计时显示条（控制区域下方，红色文字突出）
  Widget _buildCountdownBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.timer, size: 18, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 6),
          Text(
            '定时停止 ${_formatCountdown(_remainingSeconds)}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: _cancelTimer,
            child: Icon(Icons.close, size: 18, color: Theme.of(context).colorScheme.error),
          ),
        ],
      ),
    );
  }

  Widget _buildNowPlayingCard(AudioProvider provider) {
    final chapter = provider.currentChapter;
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Icon(
            provider.isPlaying ? Icons.graphic_eq : Icons.headphones,
            size: 48,
            color: Theme.of(context).primaryColor,
          ),
          const SizedBox(height: 8),
          Text(
            chapter?.title ?? '未选择章节',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            '${provider.currentIndex + 1} / ${provider.totalChapters}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(AudioProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          LinearProgressIndicator(
            value: provider.progress,
            minHeight: 4,
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '第 ${provider.currentIndex + 1} 章',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                '共 ${provider.totalChapters} 章',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControls(AudioProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 播放模式
          IconButton(
            icon: Icon(_modeIcon(provider.mode)),
            tooltip: _modeLabel(provider.mode),
            onPressed: () => _cycleMode(provider),
          ),
          const SizedBox(width: 16),
          // 上一章
          IconButton(
            icon: const Icon(Icons.skip_previous),
            iconSize: 36,
            onPressed: provider.hasPrevious ? provider.previous : null,
          ),
          const SizedBox(width: 16),
          // 播放/暂停
          _buildPlayPauseButton(provider),
          const SizedBox(width: 16),
          // 下一章
          IconButton(
            icon: const Icon(Icons.skip_next),
            iconSize: 36,
            onPressed: provider.hasNext ? provider.next : null,
          ),
        ],
      ),
    );
  }

  Widget _buildPlayPauseButton(AudioProvider provider) {
    return SizedBox(
      width: 64,
      height: 64,
      child: FloatingActionButton(
        onPressed: () {
          if (provider.isPlaying) {
            provider.pause();
          } else {
            provider.play();
          }
        },
        child: provider.isLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(
                provider.isPlaying ? Icons.pause : Icons.play_arrow,
                size: 32,
              ),
      ),
    );
  }

  Widget _buildSettingsPanel(AudioProvider provider) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('TTS 设置', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          // 语速
          Row(
            children: [
              const SizedBox(width: 60, child: Text('语速')),
              Expanded(
                child: Slider(
                  value: provider.config.speed,
                  min: 0.5,
                  max: 3.0,
                  divisions: 25,
                  label: '${provider.config.speed.toStringAsFixed(1)}x',
                  onChanged: (v) => provider.updateConfig(speed: v),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text('${provider.config.speed.toStringAsFixed(1)}x'),
              ),
            ],
          ),
          // 音调
          Row(
            children: [
              const SizedBox(width: 60, child: Text('音调')),
              Expanded(
                child: Slider(
                  value: provider.config.pitch,
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  label: provider.config.pitch.toStringAsFixed(1),
                  onChanged: (v) => provider.updateConfig(pitch: v),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(provider.config.pitch.toStringAsFixed(1)),
              ),
            ],
          ),
          // 音量
          Row(
            children: [
              const SizedBox(width: 60, child: Text('音量')),
              Expanded(
                child: Slider(
                  value: provider.config.volume,
                  min: 0.0,
                  max: 1.0,
                  divisions: 10,
                  label: '${(provider.config.volume * 100).toInt()}%',
                  onChanged: (v) => provider.updateConfig(volume: v),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text('${(provider.config.volume * 100).toInt()}%'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChapterList(AudioProvider provider) {
    if (provider.chapters.isEmpty) {
      return const Center(child: Text('暂无章节'));
    }
    return ListView.builder(
      itemCount: provider.chapters.length,
      itemBuilder: (context, index) {
        final chapter = provider.chapters[index];
        final isCurrent = index == provider.currentIndex;
        return ListTile(
          leading: isCurrent
              ? Icon(Icons.play_circle, color: Theme.of(context).primaryColor)
              : Text('${index + 1}'),
          title: Text(
            chapter.title,
            style: TextStyle(
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent ? Theme.of(context).primaryColor : null,
            ),
          ),
          selected: isCurrent,
          onTap: () => provider.jumpTo(index),
        );
      },
    );
  }

  Widget _buildBackgroundNotice() {
    final provider = context.watch<AudioProvider>();
    final mediaReady = provider.isMediaSessionReady;
    return Container(
      padding: const EdgeInsets.all(8),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            mediaReady ? Icons.headphones : Icons.info_outline,
            size: 16,
            color: mediaReady ? Theme.of(context).primaryColor : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            mediaReady
                ? '后台播放已启用，支持媒体按钮控制'
                : '支持后台播放，切换应用后音频将继续播放',
            style: TextStyle(
              fontSize: 12,
              color: mediaReady ? Theme.of(context).primaryColor : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  IconData _modeIcon(AudioPlayMode mode) {
    switch (mode) {
      case AudioPlayMode.sequential:
        return Icons.arrow_forward;
      case AudioPlayMode.singleLoop:
        return Icons.repeat_one;
      case AudioPlayMode.shuffle:
        return Icons.shuffle;
    }
  }

  String _modeLabel(AudioPlayMode mode) {
    switch (mode) {
      case AudioPlayMode.sequential:
        return '顺序播放';
      case AudioPlayMode.singleLoop:
        return '单曲循环';
      case AudioPlayMode.shuffle:
        return '随机播放';
    }
  }

  void _cycleMode(AudioProvider provider) {
    final nextIndex = (provider.mode.index + 1) % AudioPlayMode.values.length;
    provider.setMode(AudioPlayMode.values[nextIndex]);
  }
}
