import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:saf/saf.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/audio/audio_notifier.dart';
import '../providers/providers.dart';
import '../utils/audio_skip_policy.dart';
import '../routes.dart';
import 'source_edit_screen.dart';
import 'source_login_screen.dart';

/// 预设定时时长（分钟）
const List<int> _kPresetMinutes = [5, 10, 15, 30];

/// 听书播放页面
class AudioScreen extends ConsumerStatefulWidget {
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
  ConsumerState<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends ConsumerState<AudioScreen> {
  bool _showSettings = false;
  bool _wakeLock = false;

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
      final notifier = ref.read(audioNotifierProvider.notifier);
      // 音频书 → 流媒体；否则保持 TTS（阅读器朗读入口会强制 TTS）
      notifier.setAudioBookMode(_canCopyPlayUrl);
      notifier.bindBook(widget.book);
      notifier.initMediaSession(bookName: widget.effectiveBookName);
      unawaited(notifier.isWakeLockEnabled().then((v) {
        if (mounted) setState(() => _wakeLock = v);
      }));
      if (!ref.read(audioNotifierProvider).hasChapters) {
        notifier.loadChapters(widget.effectiveBookUrl);
      }
    });
  }

  @override
  void dispose() {
    // 页面销毁时清理定时器和媒体会话
    _stopTimer?.cancel();
    _customMinutesController.dispose();
    // 释放媒体会话资源（后台播放/焦点）
    // [UI-fix v2.0.11 | 2026-08-10] 防御卸载时序边界：element 已 dispose
    // 时（快速连续导航/测试环境树卸载）ref.read 会抛
    // 「Cannot use ref after the widget was disposed」，跳过释放 — Reasonix
    try {
      ref.read(audioNotifierProvider.notifier).releaseMediaSession();
    } catch (_) {}
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
            ref.read(audioNotifierProvider.notifier).pause();
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
    // 监听听书状态（替代原 Consumer<AudioProvider>）
    final provider = ref.watch(audioNotifierProvider);
    final notifier = ref.watch(audioNotifierProvider.notifier);
    return ListenableBuilder(
      listenable: notifier,
      builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(widget.effectiveBookName.isNotEmpty ? widget.effectiveBookName : '听书'),
        actions: [
          // 定时停止按钮
          _buildTimerButton(),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => setState(() => _showSettings = !_showSettings),
          ),
          // [UI-fix v2.0.2 | 2026-08-06] 听书溢出菜单（对标原版 audio_play.xml：
          // 换源/登录/复制播放地址/缓存目录选择/缓存范围/清当前章缓存/
          // 听书溢出菜单可用项：换源/登录/复制地址/编辑书源/日志。
          // P0-2：片头/wakelock/缓存目录(SAF)/缓存范围已诚实接通。
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: _handleOverflowMenu,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'changeSource', child: Text('换源')),
              if (_origin.isNotEmpty)
                const PopupMenuItem(value: 'login', child: Text('登录')),
              if (_canCopyPlayUrl)
                const PopupMenuItem(
                  value: 'copyAudioUrl',
                  child: Text('复制播放地址'),
                ),
              if (_canCopyPlayUrl)
                const PopupMenuItem(value: 'cacheFolder', child: Text('缓存目录')),
              if (_canCopyPlayUrl)
                const PopupMenuItem(value: 'cacheRange', child: Text('缓存范围')),
              if (_canCopyPlayUrl)
                CheckedPopupMenuItem(
                  value: 'wakeLock',
                  checked: _wakeLock,
                  child: const Text('唤醒锁定'),
                ),
              if (_canCopyPlayUrl)
                const PopupMenuItem(value: 'skipCredits', child: Text('跳过片头片尾')),
              if (_origin.isNotEmpty)
                const PopupMenuItem(value: 'editSource', child: Text('编辑书源')),
              const PopupMenuItem(value: 'log', child: Text('日志')),
            ],
          ),
        ],
      ),
      body: _buildBody(provider),
    ),
    );
  }

  /// 听书主体（根据状态展示 loading/error/内容三态）
  Widget _buildBody(AudioState provider) {
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
              onPressed: () => ref
                  .read(audioNotifierProvider.notifier)
                  .loadChapters(widget.effectiveBookUrl),
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
        // 设置面板：音频书仅保留语速；TTS 保留完整引擎配置
        if (_showSettings) _buildSettingsPanel(provider),
        // 章节列表
        Expanded(child: _buildChapterList(provider)),
        // 后台播放提示
        _buildBackgroundNotice(),
      ],
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

  Widget _buildNowPlayingCard(AudioState provider) {
    final chapter = provider.currentChapter;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Column(
        children: [
          Icon(
            provider.isPlaying ? Icons.graphic_eq_rounded : Icons.headphones_rounded,
            size: 44,
            color: scheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            chapter?.title ?? '未选择章节',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            provider.isStreamMode ? '音频书' : '朗读',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            '${provider.currentIndex + 1} / ${provider.totalChapters}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          if (provider.isStreamMode &&
              (provider.lyric?.trim().isNotEmpty ?? false)) ...[
            const SizedBox(height: 10),
            Text(
              provider.lyric!.trim(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.secondary,
                  ),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProgressBar(AudioState provider) {
    final isStream = provider.isStreamMode;
    final dur = provider.durationMs;
    final pos = provider.positionMs;
    final streamValue =
        (isStream && dur > 0) ? (pos / dur).clamp(0.0, 1.0) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: streamValue ?? provider.progress,
              minHeight: 3,
              backgroundColor: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isStream && dur > 0
                    ? _formatMs(pos)
                    : '第 ${provider.currentIndex + 1} 章',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              Text(
                isStream && dur > 0
                    ? _formatMs(dur)
                    : '共 ${provider.totalChapters} 章',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatMs(int ms) {
    final totalSec = (ms / 1000).floor();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildControls(AudioState provider) {
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
            onPressed: provider.hasPrevious
                ? ref.read(audioNotifierProvider.notifier).previous
                : null,
          ),
          const SizedBox(width: 16),
          // 播放/暂停
          _buildPlayPauseButton(provider),
          const SizedBox(width: 16),
          // 下一章
          IconButton(
            icon: const Icon(Icons.skip_next),
            iconSize: 36,
            onPressed: provider.hasNext
                ? ref.read(audioNotifierProvider.notifier).next
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildPlayPauseButton(AudioState provider) {
    return SizedBox(
      width: 64,
      height: 64,
      child: FloatingActionButton(
        onPressed: () {
          final n = ref.read(audioNotifierProvider.notifier);
          if (provider.isPlaying) {
            n.pause();
          } else {
            unawaited(n.resumeOrPlay());
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

  Widget _buildSettingsPanel(AudioState provider) {
    final isStream = provider.isStreamMode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isStream ? '播放设置' : '朗读设置',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
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
                  onChanged: (v) => ref
                      .read(audioNotifierProvider.notifier)
                      .updateConfig(speed: v),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text('${provider.config.speed.toStringAsFixed(1)}x'),
              ),
            ],
          ),
          if (!isStream) ...[
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
                    onChanged: (v) => ref
                        .read(audioNotifierProvider.notifier)
                        .updateConfig(pitch: v),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(provider.config.pitch.toStringAsFixed(1)),
                ),
              ],
            ),
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
                    onChanged: (v) => ref
                        .read(audioNotifierProvider.notifier)
                        .updateConfig(volume: v),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text('${(provider.config.volume * 100).toInt()}%'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tune, size: 20),
              title: const Text('朗读引擎'),
              subtitle: const Text('管理 HTTP TTS 朗读引擎'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.pushNamed(context, AppRoutes.readAloudConfig),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChapterList(AudioState provider) {
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
          onTap: () => ref.read(audioNotifierProvider.notifier).jumpTo(index),
        );
      },
    );
  }

  Widget _buildBackgroundNotice() {
    final provider = ref.watch(audioNotifierProvider);
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

  void _cycleMode(AudioState provider) {
    final nextIndex = (provider.mode.index + 1) % AudioPlayMode.values.length;
    ref
        .read(audioNotifierProvider.notifier)
        .setMode(AudioPlayMode.values[nextIndex]);
  }

  // ===== 溢出菜单（对标 audio_play.xml；仅已接通项）— GapAudit P0-2 =====

  /// 溢出菜单分发
  Future<void> _handleOverflowMenu(String value) async {
    switch (value) {
      case 'changeSource':
        _openChangeSource();
      case 'login':
        await _openLogin();
      case 'copyAudioUrl':
        await _copyAudioUrl();
      case 'cacheFolder':
        await _pickAudioCacheFolder();
      case 'cacheRange':
        await _showAudioCacheRange();
      case 'wakeLock':
        final next = !_wakeLock;
        await ref.read(audioNotifierProvider.notifier).setWakeLockEnabled(next);
        if (mounted) setState(() => _wakeLock = next);
      case 'skipCredits':
        await _showSkipCreditsSheet();
      case 'editSource':
        _openEditSource();
      case 'log':
        if (mounted) Navigator.pushNamed(context, AppRoutes.appLog);
    }
  }

  /// 当前书源 URL（Book.origin）
  String get _origin => widget.book?.origin ?? '';

  /// 是否可复制真实播放地址（音频书位标记；TTS 朗读无流媒体地址则不展示）
  bool get _canCopyPlayUrl {
    final book = widget.book;
    if (book == null) return false;
    return (book.bookType & BookType.audio) == BookType.audio;
  }

  /// 换源（对标原版从听书页打开 ChangeBookSourceDialog）
  void _openChangeSource() {
    final book = widget.book;
    if (book != null) {
      Navigator.pushNamed(context, AppRoutes.changeSource, arguments: book);
      return;
    }
    Navigator.pushNamed(context, AppRoutes.changeSource, arguments: {
      'bookUrl': widget.effectiveBookUrl,
      'bookName': widget.effectiveBookName,
      'currentSourceUrl': _origin,
    });
  }

  /// 登录（按 book.origin 定位书源后打开登录页）
  Future<void> _openLogin() async {
    if (_origin.isEmpty) {
      _snack('本书无关联书源，无法登录');
      return;
    }
    BookSource? source;
    try {
      final sources = await ref.read(bookApiProvider).getBookSources();
      source =
          sources.where((s) => s.bookSourceUrl == _origin).firstOrNull;
    } catch (_) {}
    if (!mounted) return;
    if (source == null) {
      _snack('未找到当前书源');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SourceLoginScreen(
          sourceUrl: source!.bookSourceUrl,
          sourceName: source.bookSourceName,
          loginUrl: source.loginUrl,
        ),
      ),
    );
  }

  /// 复制播放地址（对标 menu_copy_audio_url；优先 mediaUrl）
  Future<void> _copyAudioUrl() async {
    final bookUrl = widget.effectiveBookUrl;
    if (bookUrl.isEmpty) {
      _snack('无法获取播放地址');
      return;
    }
    try {
      final api = ref.read(bookApiProvider);
      final audio = ref.read(audioNotifierProvider);
      // 优先当前已解析的播放地址，避免重复取址
      var url = audio.mediaUrl.trim();
      if (url.isEmpty) {
        final media =
            await api.getAudioChapterMedia(bookUrl, audio.currentIndex);
        url = (media['mediaUrl'] as String?)?.trim() ?? '';
        if (url.isEmpty) {
          final resource = (media['resourceUrl'] as String?)?.trim() ?? '';
          final chapterUrl = (media['url'] as String?)?.trim() ?? '';
          url = resource.isNotEmpty ? resource : chapterUrl;
        }
      }
      if (url.isEmpty) {
        _snack('当前章节无播放地址');
        return;
      }
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) _snack('播放地址已复制');
    } catch (e) {
      if (mounted) _snack('复制失败：$e');
    }
  }

  /// 编辑书源（对标原版 menu_edit_source）
  void _openEditSource() {
    if (_origin.isEmpty) {
      _snack('本书无关联书源');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SourceEditScreen(sourceUrl: _origin),
      ),
    );
  }


  Future<void> _pickAudioCacheFolder() async {
    try {
      // 优先 SAF v2（持久化写权限）；失败再降级 MethodChannel
      String? uri;
      try {
        final dir = await Saf().pickDirectory(writePermission: true);
        uri = dir?.uri;
      } catch (_) {
        const channel = MethodChannel('legado/file_picker');
        uri = await channel.invokeMethod<String>('pickDirectory');
      }
      if (uri == null || uri.isEmpty) return;
      await ref.read(bookApiProvider).setConfig(kAudioCacheTreeUriKey, uri);
      if (mounted) _snack('已选择缓存目录');
    } catch (e) {
      if (mounted) _snack('选择目录失败: $e');
    }
  }

  Future<void> _showAudioCacheRange() async {
    final audio = ref.read(audioNotifierProvider);
    final total = audio.chapters.length;
    if (total <= 0) {
      _snack('暂无章节');
      return;
    }
    final from = audio.currentIndex + 1;
    final toCtrl = TextEditingController(text: '$total');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 8,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('缓存范围', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('从第 $from 章缓存到：'),
              TextField(
                controller: toCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: '结束章节序号'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('开始缓存'),
              ),
            ],
          ),
        );
      },
    );
    if (ok != true || !mounted) return;
    final to = int.tryParse(toCtrl.text.trim()) ?? total;
    final end = to.clamp(from, total);
    _snack('开始缓存第 $from-$end 章…');
    unawaited(_cacheAudioRange(from - 1, end - 1));
  }

  Future<void> _cacheAudioRange(int fromIndex, int toIndex) async {
    final api = ref.read(bookApiProvider);
    final bookUrl = widget.effectiveBookUrl;
    // F1：优先写入用户自选 SAF DocumentFile tree；无 tree 时回退应用 audio_cache
    final treeUri = (await api.getConfig(kAudioCacheTreeUriKey))?.trim() ?? '';
    final useSaf = treeUri.isNotEmpty && Platform.isAndroid;
    Directory? fallbackDir;
    if (!useSaf) {
      final base = await getApplicationSupportDirectory();
      fallbackDir =
          Directory('${base.path}${Platform.pathSeparator}audio_cache');
      if (!fallbackDir.existsSync()) {
        fallbackDir.createSync(recursive: true);
      }
    }
    final saf = useSaf ? Saf() : null;
    var okCount = 0;
    for (var i = fromIndex; i <= toIndex; i++) {
      try {
        final media = await api.getAudioChapterMedia(bookUrl, i);
        final url = (media['mediaUrl'] as String?)?.trim() ?? '';
        if (url.isEmpty || !url.startsWith('http')) continue;
        final resp = await http.get(Uri.parse(url));
        if (resp.statusCode < 200 || resp.statusCode >= 300) continue;
        final name = '${bookUrl.hashCode}_$i.audio';
        if (saf != null) {
          await saf.writeFileBytes(
            treeUri,
            name,
            'application/octet-stream',
            Uint8List.fromList(resp.bodyBytes),
            overwrite: true,
          );
        } else {
          final file = File(
            '${fallbackDir!.path}${Platform.pathSeparator}$name',
          );
          await file.writeAsBytes(resp.bodyBytes, flush: true);
        }
        okCount++;
      } catch (_) {}
    }
    if (mounted) {
      final where = useSaf ? '所选缓存目录' : '应用本地目录';
      _snack(okCount > 0 ? '已缓存 $okCount 章到$where' : '未缓存到可用章节');
    }
  }

  Future<void> _showSkipCreditsSheet() async {
    final api = ref.read(bookApiProvider);
    final book = widget.book;
    var globalOpen =
        int.tryParse(await api.getConfig(kAudioSkipOpenCreditsKey) ?? '0') ?? 0;
    var globalClose =
        int.tryParse(await api.getConfig(kAudioSkipCloseCreditsKey) ?? '0') ?? 0;
    var useGlobal = (book?.readConfig?.openCredits ?? 0) == 0 &&
        (book?.readConfig?.closeCredits ?? 0) == 0;
    var open = useGlobal ? globalOpen : (book?.readConfig?.openCredits ?? 0);
    var close = useGlobal ? globalClose : (book?.readConfig?.closeCredits ?? 0);

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 8,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('跳过片头片尾',
                      style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('全局')),
                      ButtonSegment(value: false, label: Text('本书')),
                    ],
                    selected: {useGlobal},
                    onSelectionChanged: (s) {
                      setSheet(() {
                        useGlobal = s.first;
                        if (useGlobal) {
                          open = globalOpen;
                          close = globalClose;
                        } else {
                          open = book?.readConfig?.openCredits ?? globalOpen;
                          close = book?.readConfig?.closeCredits ?? globalClose;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Text('片头 $open 秒'),
                  Slider(
                    value: open.toDouble().clamp(0, 120),
                    max: 120,
                    divisions: 120,
                    label: '$open',
                    onChanged: (v) => setSheet(() => open = v.round()),
                  ),
                  Text('片尾 $close 秒'),
                  Slider(
                    value: close.toDouble().clamp(0, 120),
                    max: 120,
                    divisions: 120,
                    label: '$close',
                    onChanged: (v) => setSheet(() => close = v.round()),
                  ),
                  FilledButton(
                    onPressed: () async {
                      if (useGlobal) {
                        await api.setConfig(
                            kAudioSkipOpenCreditsKey, '$open');
                        await api.setConfig(
                            kAudioSkipCloseCreditsKey, '$close');
                        if (book != null) {
                          final cfg = book.readConfig ?? const ReadConfig();
                          await api.updateBook(book.copyWith(
                            readConfig: cfg.copyWith(
                              openCredits: 0,
                              closeCredits: 0,
                            ),
                          ));
                        }
                      } else if (book != null) {
                        final cfg = book.readConfig ?? const ReadConfig();
                        await api.updateBook(book.copyWith(
                          readConfig: cfg.copyWith(
                            openCredits: open,
                            closeCredits: close,
                          ),
                        ));
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        ref
                            .read(audioNotifierProvider.notifier)
                            .bindBook(book);
                        _snack('已保存片头片尾设置');
                      }
                    },
                    child: const Text('保存'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
  /// 统一 snackbar 提示
  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
