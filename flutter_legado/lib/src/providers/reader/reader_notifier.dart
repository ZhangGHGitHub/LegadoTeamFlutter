import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/settings_service.dart';
import '../providers.dart';
import 'reader_state.dart';

export 'reader_state.dart';

/// 阅读器 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §3.2 铁律）：
/// - 调用 BookApi 加载章节、保存进度 → 更新 immutable State
/// - 管理 UI 状态（loading/error/data 三态、工具栏显隐）
/// - 管理阅读设置（字号/行距/背景/翻页模式）并持久化
/// - 禁止包含业务计算（文本解析/净化/替换由 Rust 完成）
class ReaderNotifier extends Notifier<ReaderState> {
  final SettingsService _settings = SettingsService();

  @override
  ReaderState build() {
    // 延迟到 build() 返回后执行（state 初始化完成后才能访问）
    Future.microtask(_loadSettings);
    return const ReaderState();
  }

  /// 从 SharedPreferences 加载持久化的阅读设置
  Future<void> _loadSettings() async {
    final fontSize = await _settings.getFontSize();
    final lineHeight = await _settings.getLineHeight();
    final bgIndex = await _settings.getBgColorIndex();
    final modeName = await _settings.getFlipModeName();
    final legacyIndex = await _settings.getFlipMode();

    var backgroundColor = state.backgroundColor;
    if (bgIndex >= 0 && bgIndex < ReaderBackground.presets.length) {
      backgroundColor = ReaderBackground.presets[bgIndex];
    }

    state = state.copyWith(
      fontSize: fontSize,
      lineHeight: lineHeight,
      backgroundColor: backgroundColor,
      pageTurnMode: PageTurnMode.fromStorage(modeName, legacyIndex),
    );
  }

  /// 打开书籍：加载目录并定位到上次阅读章节
  Future<void> openBook(Book book) async {
    state = state.copyWith(
      currentBook: book,
      isLoading: true,
      error: null,
      showControls: false,
    );

    try {
      final api = ref.read(bookApiProvider);
      final chapters = await api.getChapters(book.bookUrl);
      var chapterIndex = book.durChapterIndex;
      if (chapterIndex >= chapters.length && chapters.isNotEmpty) {
        chapterIndex = 0;
      }
      state = state.copyWith(
        chapters: chapters,
        currentChapterIndex: chapterIndex,
      );
      await _loadChapterContent();
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  /// 进入下一章
  Future<void> nextChapter() async {
    if (!state.hasNextChapter) return;
    await _saveProgress();
    state = state.copyWith(
      currentChapterIndex: state.currentChapterIndex + 1,
      currentChapterPos: 0,
      isLoading: true,
    );
    await _loadChapterContent();
    state = state.copyWith(isLoading: false);
    await _saveProgress();
  }

  /// 进入上一章
  Future<void> prevChapter() async {
    if (!state.hasPreviousChapter) return;
    await _saveProgress();
    state = state.copyWith(
      currentChapterIndex: state.currentChapterIndex - 1,
      currentChapterPos: 0,
      isLoading: true,
    );
    await _loadChapterContent();
    state = state.copyWith(isLoading: false);
    await _saveProgress();
  }

  /// 跳转到指定章节
  Future<void> goToChapter(int index) async {
    if (index < 0 || index >= state.chapters.length) return;
    await _saveProgress();
    state = state.copyWith(
      currentChapterIndex: index,
      currentChapterPos: 0,
      isLoading: true,
      showControls: false,
    );
    await _loadChapterContent();
    state = state.copyWith(isLoading: false);
    await _saveProgress();
  }

  // ===== 工具栏交互 =====

  /// 切换工具栏显隐
  void toggleControls() {
    state = state.copyWith(showControls: !state.showControls);
  }

  /// 隐藏工具栏
  void hideControls() {
    if (state.showControls) {
      state = state.copyWith(showControls: false);
    }
  }

  // ===== 阅读设置（更新并持久化） =====

  /// 更新字体大小
  void updateFontSize(double size) {
    final clamped = size.clamp(12.0, 32.0);
    state = state.copyWith(fontSize: clamped);
    _settings.setFontSize(clamped);
  }

  /// 更新行高
  void updateLineHeight(double height) {
    final clamped = height.clamp(1.0, 2.5);
    state = state.copyWith(lineHeight: clamped);
    _settings.setLineHeight(clamped);
  }

  /// 更新背景色
  void updateBackgroundColor(dynamic color) {
    state = state.copyWith(backgroundColor: color);
    final index = ReaderBackground.presets.indexOf(color);
    if (index >= 0) {
      _settings.setBgColorIndex(index);
    }
  }

  /// 更新翻页模式
  void updatePageTurnMode(PageTurnMode mode) {
    state = state.copyWith(pageTurnMode: mode);
    // 同时写入 name（新版）和 index（旧版兼容）
    _settings.setFlipModeName(mode.name);
    _settings.setFlipMode(mode.index);
  }

  /// 更新当前阅读位置（由 UI 层滚动/翻页时调用）
  void updatePosition(int position) {
    state = state.copyWith(currentChapterPos: position);
  }

  /// 保存当前阅读进度到后端
  Future<void> saveProgress() => _saveProgress();

  // ===== 内部工具 =====

  Future<void> _saveProgress() async {
    final book = state.currentBook;
    if (book == null) return;
    try {
      final api = ref.read(bookApiProvider);
      await api.updateReadingProgress(
        bookUrl: book.bookUrl,
        chapterIndex: state.currentChapterIndex,
        chapterPos: state.currentChapterPos,
      );
    } catch (_) {
      // 保存失败不阻断阅读流程
    }
  }

  /// 加载当前章节正文
  ///
  /// 在线书籍：getChapterContent 返回 JSON 元数据，需二次调用
  /// fetchChapterContent 通过 FFI 获取真实正文；本地书籍直接使用。
  Future<void> _loadChapterContent() async {
    final book = state.currentBook;
    if (book == null || state.chapters.isEmpty) return;
    try {
      final api = ref.read(bookApiProvider);
      final content = await api.getChapterContent(
        book.bookUrl,
        state.currentChapterIndex,
      );

      // 检查是否是 JSON 元数据（在线书籍）
      if (content.startsWith('{') && content.contains('chapter_url')) {
        try {
          final meta = jsonDecode(content) as Map<String, dynamic>;
          final chapterUrl = meta['chapter_url'] as String? ?? '';
          final sourceUrl = book.origin; // 书源 URL
          if (chapterUrl.isNotEmpty && sourceUrl.isNotEmpty) {
            // 在线书籍：通过 FFI 获取真实正文
            final real = await api.fetchChapterContent(
              book.bookUrl,
              chapterUrl,
              sourceUrl,
            );
            state = state.copyWith(chapterContent: real);
          } else {
            state = state.copyWith(chapterContent: content);
          }
        } catch (_) {
          state = state.copyWith(chapterContent: content); // fallback
        }
      } else {
        state = state.copyWith(chapterContent: content); // 本地书籍直接使用
      }
    } catch (e) {
      state = state.copyWith(error: _mapError(e), chapterContent: '');
    }
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 阅读器 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(readerNotifierProvider);
/// ref.read(readerNotifierProvider.notifier).openBook(book);
/// ```
final readerNotifierProvider =
    NotifierProvider<ReaderNotifier, ReaderState>(
  ReaderNotifier.new,
);
