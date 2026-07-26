import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/audio_provider.dart';

/// 听书播放页面
class AudioScreen extends StatefulWidget {
  final String bookUrl;
  final String bookName;

  const AudioScreen({
    super.key,
    required this.bookUrl,
    this.bookName = '',
  });

  @override
  State<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends State<AudioScreen> {
  bool _showSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<AudioProvider>();
      if (!provider.hasChapters) {
        provider.loadChapters(widget.bookUrl);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.bookName.isNotEmpty ? widget.bookName : '听书'),
        actions: [
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
                  const Icon(Icons.error_outline, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  Text(provider.errorMessage ?? '加载失败'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => provider.loadChapters(widget.bookUrl),
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
    return Container(
      padding: const EdgeInsets.all(8),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.info_outline, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Text(
            '支持后台播放，切换应用后音频将继续播放',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
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
