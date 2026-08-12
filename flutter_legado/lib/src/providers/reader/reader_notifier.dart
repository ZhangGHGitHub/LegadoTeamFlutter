import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/settings_service.dart';
import '../../widgets/paragraph_layout_engine.dart';
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

  /// 跨章节连续分页器（维护全局页索引 ↔ 章节/页映射）
  final CrossChapterPaginator _paginator = CrossChapterPaginator();

  /// 获取分页器（供 UI 层查询全局页信息）
  CrossChapterPaginator get paginator => _paginator;

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

    // [UI-fix v2.0.4 | 2026-08-08] 恢复自定义背景色（界面 Sheet 长按
    // 背景圆圈自定义配色，对标原版 ReadBookConfig 自定义背景）— Qoder
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('reader_bg_use_custom') ?? false) {
      final custom = prefs.getInt('reader_custom_bg_color');
      if (custom != null) backgroundColor = Color(custom);
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
      var chapters = await api.getChapters(book.bookUrl);
      // 对齐原版：本地无目录的网络书籍（如刚从搜索结果加入书架，
      // 尚未拉取过目录），自动经书源规则从网络获取目录
      if (chapters.isEmpty && book.origin.isNotEmpty) {
        chapters = await api.refreshToc(book.bookUrl, book.origin);
      }
      var chapterIndex = book.durChapterIndex;
      var chapterPos = book.durChapterPos;
      if (chapterIndex >= chapters.length && chapters.isNotEmpty) {
        chapterIndex = 0;
        chapterPos = 0;
      }
      state = state.copyWith(
        chapters: chapters,
        currentChapterIndex: chapterIndex,
        currentChapterPos: chapterPos,
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

  /// 应用 WebDAV 云端进度（对齐原版 ReadBook.setProgress）
  Future<void> applyBookProgress({
    required int chapterIndex,
    required int chapterPos,
  }) async {
    if (chapterIndex < 0 || chapterIndex >= state.chapters.length) return;
    await _saveProgress();
    state = state.copyWith(
      currentChapterIndex: chapterIndex,
      currentChapterPos: chapterPos.clamp(0, 1 << 30),
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
  // [UI-fix v2.0.4 | 2026-08-08] 上限 2.5 → 3.0（界面 Sheet 行距连续
  // 滑条 1.0-3.0，对标原版 dsbLineSize 范围）— Qoder
  void updateLineHeight(double height) {
    final clamped = height.clamp(1.0, 3.0);
    state = state.copyWith(lineHeight: clamped);
    _settings.setLineHeight(clamped);
  }

  /// 更新背景色（预设）
  void updateBackgroundColor(dynamic color) {
    state = state.copyWith(backgroundColor: color);
    final index = ReaderBackground.presets.indexOf(color);
    if (index >= 0) {
      _settings.setBgColorIndex(index);
      // [UI-fix v2.0.4 | 2026-08-08] 选中预设时清除自定义背景标志，
      // 下次启动按预设恢复 — Qoder
      unawaited(SharedPreferences.getInstance()
          .then((p) => p.setBool('reader_bg_use_custom', false)));
    }
  }

  // [UI-fix v2.0.4 | 2026-08-08] 自定义背景色（界面 Sheet 长按背景圆圈
  // 自定义配色）：即时应用并持久化，启动时经 _loadSettings 恢复 — Qoder
  Future<void> updateCustomBackgroundColor(Color color) async {
    state = state.copyWith(backgroundColor: color);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('reader_custom_bg_color', color.toARGB32());
    await prefs.setBool('reader_bg_use_custom', true);
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
    // [UI-fix v2.0.3 | 2026-08-06] 翻页/滑动后同步全局页索引，
    // 保证点击翻页与滑动手势翻页时全局页码指示器实时更新（此前仅
    // updateChapterPageCount 才刷新，导致章内翻页指示器停滞） — Qoder
    _syncGlobalPageInfo();
  }

  // ===== 跨章节连续分页导航 =====

  /// 更新章节分页信息（由 UI 层分页完成后调用）
  ///
  /// 当某章分页完成时，UI 层调用此方法注册该章的页数，
  /// 分页器据此维护全局页索引映射。
  void updateChapterPageCount(int chapterIndex, int pageCount) {
    _paginator.addChapter(chapterIndex, pageCount);
    _syncGlobalPageInfo();
  }

  /// 同步全局页信息到 State
  void _syncGlobalPageInfo() {
    final total = _paginator.totalPages();
    final globalStart = _paginator.globalIndexForChapterStart(state.currentChapterIndex);
    final globalIndex = globalStart >= 0 ? globalStart + state.currentChapterPos : state.globalPageIndex;
    state = state.copyWith(
      totalPages: total,
      globalPageIndex: globalIndex.clamp(0, total > 0 ? total - 1 : 0),
    );
  }

  /// 跳转到全局页索引
  ///
  /// 自动解析对应的章节和章内页，如果章节变化则加载新章节内容。
  Future<void> goToGlobalPage(int globalIndex) async {
    if (!_paginator.isValidGlobalIndex(globalIndex)) return;

    final resolved = _paginator.resolve(globalIndex);
    if (resolved == null) return;

    final targetChapter = resolved.chapterIndex;
    final targetPage = resolved.pageIndex;

    if (targetChapter != state.currentChapterIndex) {
      // 章节变化：加载新章节
      await _saveProgress();
      state = state.copyWith(
        currentChapterIndex: targetChapter,
        currentChapterPos: targetPage,
        globalPageIndex: globalIndex,
        isLoading: true,
      );
      await _loadChapterContent();
      state = state.copyWith(isLoading: false);
      await _saveProgress();
    } else {
      // 同章内翻页
      state = state.copyWith(
        currentChapterPos: targetPage,
        globalPageIndex: globalIndex,
      );
    }
  }

  /// 下一页（跨章节无缝）
  Future<void> nextGlobalPage() async {
    final next = state.globalPageIndex + 1;
    if (_paginator.isValidGlobalIndex(next)) {
      await goToGlobalPage(next);
    }
  }

  /// 上一页（跨章节无缝）
  Future<void> prevGlobalPage() async {
    final prev = state.globalPageIndex - 1;
    if (prev >= 0 && _paginator.isValidGlobalIndex(prev)) {
      await goToGlobalPage(prev);
    }
  }

  /// 保存当前阅读进度到后端
  Future<void> saveProgress() => _saveProgress();

  // [UI-fix v2.0.2 | 2026-08-06] 重新加载当前章正文（替换规则开关/重新分段/
  // 图片样式/繁简转换等书籍配置变更后由 UI 层调用，对标原版
  // ReadBook.loadContent(false)） — Qoder
  Future<void> reloadChapterContent() => _loadChapterContent();

  // [UI-fix v2.0.2 | 2026-08-06] 同步已持久化的书对象到 State
  // （readConfig 变更经 BookApi.updateBook 落库后回写 UI 状态） — Qoder
  void updateCurrentBook(Book book) {
    state = state.copyWith(currentBook: book);
  }

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
  /// 统一调用 getChapterContentFull：本地书籍直接解析返回，在线书籍自动
  /// 从网络抓取并返回净化后的正文，始终返回纯正文字符串（无 JSON 元数据）。
  Future<void> _loadChapterContent() async {
    final book = state.currentBook;
    if (book == null || state.chapters.isEmpty) return;
    try {
      final api = ref.read(bookApiProvider);
      final content = await api.getChapterContentFull(
        book.bookUrl,
        state.currentChapterIndex,
      );
      state = state.copyWith(chapterContent: content);
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
