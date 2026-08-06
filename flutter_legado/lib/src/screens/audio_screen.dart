import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/audio/audio_notifier.dart';
import '../providers/providers.dart';
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
      // 初始化媒体会话（后台播放 + 媒体按钮 + 焦点管理）
      notifier.initMediaSession(bookName: widget.effectiveBookName);
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
    ref.read(audioNotifierProvider.notifier).releaseMediaSession();
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
          // [UI-fix v2.0.2 | 2026-08-06] 听书溢出菜单（对标原版 audio_play.xml：
          // 换源/登录/复制播放地址/缓存目录选择/缓存范围/清当前章缓存/
          // 编辑书源/wakelock开关/跳过片头/日志） — Qoder
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: _handleOverflowMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'changeSource', child: Text('换源')),
              PopupMenuItem(value: 'login', child: Text('登录')),
              PopupMenuItem(value: 'copyAudioUrl', child: Text('复制播放地址')),
              PopupMenuItem(value: 'cacheFolder', child: Text('缓存目录选择')),
              PopupMenuItem(value: 'cacheRange', child: Text('缓存范围')),
              PopupMenuItem(
                value: 'clearChapterCache',
                child: Text('清当前章缓存'),
              ),
              PopupMenuItem(value: 'editSource', child: Text('编辑书源')),
              PopupMenuItem(value: 'wakeLock', child: Text('wakelock 开关')),
              PopupMenuItem(value: 'skipCredits', child: Text('跳过片头')),
              PopupMenuItem(value: 'log', child: Text('日志')),
            ],
          ),
        ],
      ),
      body: _buildBody(provider),
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
        // 设置面板（可展开）
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

  Widget _buildProgressBar(AudioState provider) {
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
          if (provider.isPlaying) {
            ref.read(audioNotifierProvider.notifier).pause();
          } else {
            ref.read(audioNotifierProvider.notifier).play();
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
          // [UI-fix v2.0.1 | 2026-08-06] 朗读设置区入口接 ReadAloudConfigScreen
          // （对标原版 ReadAloudDialog 朗读引擎入口 pref_aloud；此前该页为孤儿页） — Qoder
          const SizedBox(height: 4),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.tune, size: 20),
            title: const Text('朗读引擎'),
            subtitle: const Text('管理 HTTP TTS 朗读引擎'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, AppRoutes.readAloudConfig),
          ),
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

  // ===== [UI-fix v2.0.2 | 2026-08-06] 溢出菜单（对标 audio_play.xml）— Qoder =====

  /// 溢出菜单分发
  Future<void> _handleOverflowMenu(String value) async {
    switch (value) {
      case 'changeSource':
        // 对标 menu_change_source → ChangeBookSourceDialog
        _openChangeSource();
      case 'login':
        // 对标 menu_login → SourceLoginActivity
        await _openLogin();
      case 'copyAudioUrl':
        // 对标 menu_copy_audio_url
        await _copyAudioUrl();
      case 'cacheFolder':
        // 对标 menu_audio_cache_folder
        await _pickCacheFolder();
      case 'cacheRange':
        // 对标 menu_audio_cache_range
        await _showCacheRangeDialog();
      case 'clearChapterCache':
        // 对标 menu_clear_current_audio_cache
        await _clearChapterCache();
      case 'editSource':
        // 对标 menu_edit_source → SourceEditActivity
        _openEditSource();
      case 'wakeLock':
        // 对标 menu_wake_lock
        await _toggleWakeLock();
      case 'skipCredits':
        // 对标 menu_skip_credits
        await _showSkipCreditsDialog();
      case 'log':
        // [UI-fix v2.0.2 | 2026-08-06] 听书日志入口接通 AppLogScreen
        //（对标原版 menu_log → LogActivity） — Qoder
        if (mounted) Navigator.pushNamed(context, AppRoutes.appLog);
    }
  }

  /// 当前书源 URL（Book.origin）
  String get _origin => widget.book?.origin ?? '';

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

  /// 复制播放地址
  ///
  /// TODO(UI-fix v2.0.2): 当前听书为 TTS 朗读，尚无真实播放地址，
  /// 待 audioSpeak 音频管线（任务 #113）落地后接通。— Qoder
  Future<void> _copyAudioUrl() async {
    _snack('当前为 TTS 朗读，暂无播放地址可复制');
  }

  /// 缓存目录选择（目录选择后持久化于 config 键 audioCacheFolder）
  ///
  /// TODO(UI-fix v2.0.2): 音频缓存体系未移植，目录仅持久化待后端接入。— Qoder
  Future<void> _pickCacheFolder() async {
    final api = ref.read(bookApiProvider);
    String? current;
    try {
      current = await api.getConfig('audioCacheFolder');
    } catch (_) {}
    if (!mounted) return;
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择音频缓存目录',
      initialDirectory: (current ?? '').isEmpty ? null : current,
    );
    if (picked == null || !mounted) return;
    try {
      await api.setConfig('audioCacheFolder', picked);
      if (mounted) _snack('缓存目录已设置：$picked');
    } catch (e) {
      if (mounted) _snack('设置缓存目录失败：$e');
    }
  }

  /// 缓存范围（输入待缓存章节数，持久化于 config 键 audioCacheCount）
  ///
  /// TODO(UI-fix v2.0.2): 音频缓存体系未移植，仅持久化配置待后端接入。— Qoder
  Future<void> _showCacheRangeDialog() async {
    final api = ref.read(bookApiProvider);
    String? current;
    try {
      current = await api.getConfig('audioCacheCount');
    } catch (_) {}
    if (!mounted) return;
    final ctrl = TextEditingController(text: current ?? '10');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('缓存范围'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '缓存章节数',
            hintText: '输入待缓存的章节数量',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    if (int.tryParse(result) == null) {
      _snack('请输入有效的章节数');
      return;
    }
    try {
      await api.setConfig('audioCacheCount', result);
      if (mounted) _snack('缓存范围已设置：$result 章');
    } catch (e) {
      if (mounted) _snack('设置缓存范围失败：$e');
    }
  }

  /// 清当前章缓存
  ///
  /// TODO(UI-fix v2.0.2): 音频缓存体系未移植，暂无可清理的本地缓存。— Qoder
  Future<void> _clearChapterCache() async {
    _snack('当前无本地音频缓存可清理');
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

  /// wakelock 开关（持久化于 config 键 audioWakeLock）
  ///
  /// TODO(UI-fix v2.0.2): 未引入 wakelock 依赖（不改 pubspec），
  /// 当前仅持久化开关，待依赖接入后生效。— Qoder
  Future<void> _toggleWakeLock() async {
    final api = ref.read(bookApiProvider);
    String? current;
    try {
      current = await api.getConfig('audioWakeLock');
    } catch (_) {}
    final next = current != 'true';
    try {
      await api.setConfig('audioWakeLock', next ? 'true' : 'false');
    } catch (_) {}
    if (mounted) _snack(next ? 'wakelock 已开启' : 'wakelock 已关闭');
  }

  /// 跳过片头（输入跳过秒数，持久化于 config 键 audioSkipCredits）
  ///
  /// TODO(UI-fix v2.0.2): 音频管线未支持自动跳片头，仅持久化配置。— Qoder
  Future<void> _showSkipCreditsDialog() async {
    final api = ref.read(bookApiProvider);
    String? current;
    try {
      current = await api.getConfig('audioSkipCredits');
    } catch (_) {}
    if (!mounted) return;
    final ctrl = TextEditingController(text: current ?? '0');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳过片头'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '跳过秒数',
            hintText: '每章开头自动跳过的秒数，0 为不跳过',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final seconds = int.tryParse(result);
    if (seconds == null || seconds < 0) {
      _snack('请输入有效的秒数');
      return;
    }
    try {
      await api.setConfig('audioSkipCredits', seconds.toString());
      if (mounted) {
        _snack(seconds == 0 ? '已关闭跳过片头' : '已设置跳过片头 $seconds 秒');
      }
    } catch (e) {
      if (mounted) _snack('设置跳过片头失败：$e');
    }
  }

  /// 统一 snackbar 提示
  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
