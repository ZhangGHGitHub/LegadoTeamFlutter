import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart'
    show Brightness, ThemeMode, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/rust_api.dart';
import '../../services/settings_service.dart';
import '../../widgets/paragraph_layout_engine.dart';
import '../providers.dart';
import '../theme/theme_notifier.dart';
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

  /// 本次打开阅读器时累计起点（对标 ReadBook.readStartTime，毫秒）
  int _readStartMs = 0;

  /// 进入阅读器前已累计的阅读时长（毫秒，对标 ReadBook.readRecord.readTime）
  int _baseReadTimeMs = 0;

  // [F1-hunt F2 | 2026-09-24] 章节正文加载代际号：_loadChapterContent
  // 每次调用自增并捕获；异步结果返回时代际号已变化（快速连点翻页已
  // 发起更新的加载）则丢弃旧结果——防旧章正文覆盖新章（F2 缺陷）。
  // 不设「在途即跳过」硬重入守卫：连点两次仍应逐次推进章节，
  // 只是被取代的加载结果不得写回状态。
  int _loadSeq = 0;

  @override
  ReaderState build() {
    // 延迟到 build() 返回后执行（state 初始化完成后才能访问）
    Future.microtask(_loadSettings);
    // [M1 深色态默认修复] 主题切换时重新解析阅读背景默认（仅影响
    // 「从未显式设置」路径，尊重用户显式选择；toggleDayNight 经
    // setThemeMode 同路）。监听挂在阅读器 Notifier 上：仅阅读器实际
    // 被使用（provider 已构建）时才随主题重解析，设置页切主题不会
    // 强制构建阅读器状态。
    ref.listen(
      themeNotifierProvider,
      (previous, next) {
        if (previous?.themeMode != next.themeMode) {
          // 传入监听值（next.themeMode）而非重读持久化：setThemeMode
          // 先更新内存状态（触发本监听）后异步落盘，此刻读 prefs 是旧值
          unawaited(reapplyBackgroundForCurrentTheme(
            themeMode: next.themeMode,
          ));
        }
      },
    );
    return const ReaderState();
  }

  /// 从 SharedPreferences 加载持久化的阅读设置
  Future<void> _loadSettings() async {
    final fontSize = await _settings.getFontSize();
    final lineHeight = await _settings.getLineHeight();
    // [M1 深色态默认修复] 可空读取：null = 从未设置（与显式选 0 区分）
    final bgIndex = await _settings.getBgColorIndexOrNull();
    final modeName = await _settings.getFlipModeName();
    final legacyIndex = await _settings.getFlipMode();

    // [UI-fix v2.0.4 | 2026-08-08] 恢复自定义背景色（界面 Sheet 长按
    // 背景圆圈自定义配色，对标原版 ReadBookConfig 自定义背景）— Qoder
    final prefs = await SharedPreferences.getInstance();
    Color? customBgColor;
    if (prefs.getBool('reader_bg_use_custom') ?? false) {
      final custom = prefs.getInt('reader_custom_bg_color');
      if (custom != null) customBgColor = Color(custom);
    }

    // [M1 深色态默认修复] 背景默认解析：显式自定义 > 显式预设索引 > 主题默认
    // （深色 → 夜间预设；亮色 → 白色原默认不变；用户显式选择一律保留）
    final backgroundColor = resolveReaderBackground(
      themeBrightness: await _effectiveThemeBrightness(),
      storedBgIndex: bgIndex,
      customBgColor: customBgColor,
    );

    state = state.copyWith(
      fontSize: fontSize,
      lineHeight: lineHeight,
      backgroundColor: backgroundColor,
      pageTurnMode: PageTurnMode.fromStorage(modeName, legacyIndex),
    );
  }

  /// [M1 深色态默认修复] 主题切换后重新解析阅读背景
  ///
  /// 仅影响「从未显式设置」路径：用户已显式选择自定义背景或有效预设索引时
  /// 直接返回（尊重用户选择，不随主题变化）；仅在从未显式设置时按当前
  /// 主题重新解析默认（深色 → 夜间预设，亮色 → 白色）。
  ///
  /// [themeMode]：切换后的新主题模式（build() 内 ref.listen 回调传入，
  /// 避免此刻重读尚未落盘的持久化旧值）；省略时从 [SettingsService] 读取。
  /// 由 build() 内 ref.listen(themeNotifierProvider) 在主题切换时调用
  /// （toggleDayNight 经 setThemeMode 同路）。
  Future<void> reapplyBackgroundForCurrentTheme({ThemeMode? themeMode}) async {
    late SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('ReaderNotifier.reapplyBackgroundForCurrentTheme 异常: $e');
      return;
    }
    if (prefs.getBool('reader_bg_use_custom') ?? false) return;
    final storedIndex = await _settings.getBgColorIndexOrNull();
    final hasExplicitIndex = storedIndex != null &&
        storedIndex >= 0 &&
        storedIndex < ReaderBackground.presets.length;
    if (hasExplicitIndex) return;
    final resolved = resolveReaderBackground(
      themeBrightness: await _effectiveThemeBrightness(mode: themeMode),
      storedBgIndex: null,
      customBgColor: null,
    );
    if (resolved != state.backgroundColor) {
      state = state.copyWith(backgroundColor: resolved);
    }
  }

  /// [M1 深色态默认修复] 解析当前主题的有效亮度
  ///
  /// light/dark 取显式主题模式；system 取平台亮度。无 WidgetsBinding
  /// （如纯单测环境 `WidgetsBinding.instance` 抛 FlutterError）时回退
  /// 亮色，保证解析始终有值。
  /// [mode]：已知的新主题模式（主题切换监听路径直接传入）；
  /// 省略时读持久化值（加载路径）。
  Future<Brightness> _effectiveThemeBrightness({ThemeMode? mode}) async {
    final effectiveMode = mode ?? await _settings.getThemeMode();
    Brightness platform;
    try {
      platform =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
    } catch (_) {
      platform = Brightness.light;
    }
    return themeBrightnessFor(effectiveMode, platform);
  }

  /// 打开书籍：加载目录并定位到上次阅读章节
  Future<void> openBook(Book book) async {
    state = state.copyWith(
      currentBook: book,
      isLoading: true,
      error: null,
      showControls: false,
    );
    await _beginReadRecordSession(book);

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
    _syncCurrentBookProgress();
    // [F1-hunt F2 | 2026-09-24] 被更新的加载取代时（快速连点翻页）
    // 加载返回 false：不清 isLoading、不保存进度（防旧章进度覆盖新章）
    final applied = await _loadChapterContent();
    if (!applied) return;
    state = state.copyWith(isLoading: false);
    await _saveProgress();
  }

  /// 进入上一章（[UI_SYNC_REFACTOR T3 修] 跳到上一章最后一页：
  /// currentChapterPos=-1 为哨兵值，ReaderPageView 分页完成后跳末页）
  ///
  /// [F1-hunt F6 | 2026-09-24] -1 哨兵只存在于 state.currentChapterPos
  /// 供视图消费：进度回写（_syncCurrentBookProgress）与持久化
  /// （_saveProgress）前统一归一为 0，-1 不进入 currentBook / DB。
  Future<void> prevChapter() async {
    if (!state.hasPreviousChapter) return;
    await _saveProgress();
    state = state.copyWith(
      currentChapterIndex: state.currentChapterIndex - 1,
      currentChapterPos: -1,
      isLoading: true,
    );
    _syncCurrentBookProgress();
    final applied = await _loadChapterContent();
    if (!applied) return;
    state = state.copyWith(isLoading: false);
    await _saveProgress();
  }

  /// [UI_SYNC_REFACTOR T3 修] 消费 -1 哨兵后重置（防后续重分页再次跳末页）
  ///
  /// [F1-hunt F1 | 2026-09-24] 同步回写进度（prevChapter 回写时哨兵已
  /// 归一为 0，此处通常命中无变化快路径，不产生额外 notify）
  void resetChapterPos() {
    state = state.copyWith(currentChapterPos: 0);
    _syncCurrentBookProgress();
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
    _syncCurrentBookProgress();
    final applied = await _loadChapterContent();
    if (!applied) return;
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
    _syncCurrentBookProgress();
    final applied = await _loadChapterContent();
    if (!applied) return;
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
    _pushReadBookConfig();
  }

  /// 更新行高
  // [UI-fix v2.0.4 | 2026-08-08] 上限 2.5 → 3.0（界面 Sheet 行距连续
  // 滑条 1.0-3.0，对标原版 dsbLineSize 范围）— Qoder
  void updateLineHeight(double height) {
    final clamped = height.clamp(1.0, 3.0);
    state = state.copyWith(lineHeight: clamped);
    _settings.setLineHeight(clamped);
    _pushReadBookConfig();
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
      _pushReadBookConfig();
    }
  }

  /// 补推阅读配置注入（R 批 R4）：设置变更后同步 Rust 侧 JS 可见快照；
  /// 仅 RustApi 支持，Mock 下为空操作；失败静默（尽力而为）。
  void _pushReadBookConfig() {
    try {
      final api = ref.read(bookApiProvider);
      if (api is RustApi) unawaited(api.refreshReadBookConfig());
    } catch (_) {}
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
    // [F1-hunt F1 | 2026-09-24] 章内位置变化同样回写 currentBook，
    // 下游消费者（设置保存全行 updateBook 等）读到的进度保持鲜活
    _syncCurrentBookProgress();
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
      _syncCurrentBookProgress();
      final applied = await _loadChapterContent();
      if (!applied) return;
      state = state.copyWith(isLoading: false);
      await _saveProgress();
    } else {
      // 同章内翻页
      state = state.copyWith(
        currentChapterPos: targetPage,
        globalPageIndex: globalIndex,
      );
      _syncCurrentBookProgress();
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
  // [F1-hunt F4 | 2026-09-24] 成功加载会清 error（_loadChapterContent
  // 内代际守卫 + 清错），被取代的加载静默返回，不影响设置变更流程
  Future<void> reloadChapterContent() async {
    await _loadChapterContent();
  }

  // [UI-fix v2.0.2 | 2026-08-06] 同步已持久化的书对象到 State
  // （readConfig 变更经 BookApi.updateBook 落库后回写 UI 状态） — Qoder
  void updateCurrentBook(Book book) {
    state = state.copyWith(currentBook: book);
  }

  // [P2-9 | 2026-09-24] 强制刷新当前章正文（绕过缓存，重新联网抓取）
  //
  // 对标原版 refreshContentDur（delContent + loadContent）语义：
  // 失效缓存 → 联网重抓 → 回写缓存并更新 State。
  // 受「不新增 FFI / 不改契约」约束，无法新增单章级删缓存 API，
  // 故以 clearBookCache（书级，≈ 原版 clearCache/refreshContentAll）作为
  // 缓存失效原语——作用域比原版 delContent（章级）更宽，属已知偏差（报告说明）。
  //
  // 成功返回 null；失败返回错误原因（保留旧正文，不清空 chapterContent）。
  // 本地书（origin 为空 / loc_book / dav:）与无书籍/目录/非法索引时
  // 直接返回说明性原因，不触碰 state 数据（对齐原版：本地书不显示
  // 换源/刷新菜单，此守卫兜底面板侧入口）。
  Future<String?> refreshChapterContent() async {
    final book = state.currentBook;
    if (book == null || state.chapters.isEmpty) return '没有书籍或目录';
    if (book.origin.isEmpty ||
        book.origin == BookType.localTag ||
        book.origin.startsWith(BookType.webDavTag)) {
      return '本地书不支持刷新正文';
    }
    final idx = state.currentChapterIndex;
    if (idx < 0 || idx >= state.chapters.length) return '无效章节索引';
    final chapter = state.chapters[idx];
    final api = ref.read(bookApiProvider);
    state = state.copyWith(isLoading: true, error: null);
    try {
      // 1) 失效缓存（不经此步，fetch 会命中旧缓存——根因 A）
      await api.clearBookCache(book.bookUrl);
      // 2) 联网重抓并回写缓存（fetch 内部命中缓存才返回缓存）
      final content = await api.fetchChapterContent(
        book.bookUrl,
        chapter.url,
        book.origin,
      );
      if (content.trim().isEmpty) {
        // 空正文视为抓取失败：保留旧正文，不清空
        state = state.copyWith(isLoading: false, error: '正文抓取为空');
        return '正文抓取为空';
      }
      state = state.copyWith(chapterContent: content, isLoading: false);
      return null;
    } catch (e) {
      // 失败保留旧正文（_loadChapterContent 会清空，刷新路径不得如此）
      final msg = _mapError(e);
      state = state.copyWith(isLoading: false, error: msg);
      return msg;
    }
  }

  // [P2-9 | 2026-09-24] 换书源后重载（换源路由 await 返回、确认发生切换后调用）
  //
  // 顺序（与 openBook 的目录加载/定位语义对齐，勿误重置阅读进度）：
  // 1) getBook 重读书籍记录（Rust 换源事务已更新 origin/originName/
  //    tocUrl/originBookUrl 并清该书缓存）→ updateCurrentBook 同步对象；
  // 2) 重载目录：getChapters 优先本地库，空则 refreshToc 联网取（对齐 openBook）；
  // 3) 章节定位：旧章标题 精确 → 宽松（互含）→ 原索引（范围内）→ 0
  //    （对齐单章换源浮层 _matchChapterIndex 逻辑）；
  // 4) 位置保留：仅当命中章节与旧章同题时保留 currentChapterPos，
  //    否则归 0；随后持久化进度；
  // 5) 强制刷新命中章正文（同 refreshChapterContent 路径）。
  //
  // bookUrl 稳定性：Rust 换源事务保持 bookUrl 为稳定主键不变
  // （P2-8：originBookUrl 写入新源详情页地址）。即使 bookUrl 前后相同，
  // 缓存键（bookUrl+chapterUrl）可能未变，仍必须走强制路径清缓存，
  // 保证旧正文不残留（换源事务已清缓存，此处为防御性双保险）。
  //
  // 成功返回 null；失败返回错误原因（已完成的步骤不回滚：目录已更新则
  // 保留，旧正文保留，error 置位供 UI 反馈）。
  Future<String?> reloadAfterSourceChange(String bookUrl) async {
    final book = state.currentBook;
    if (book == null) return '没有书籍';
    final oldIndex = state.currentChapterIndex;
    final oldChapter =
        (state.chapters.isNotEmpty &&
            oldIndex >= 0 &&
            oldIndex < state.chapters.length)
        ? state.chapters[oldIndex]
        : null;
    final oldTitle = (oldChapter?.title ?? book.durChapterTitle ?? '').trim();
    final oldPos = state.currentChapterPos;

    final api = ref.read(bookApiProvider);
    state = state.copyWith(isLoading: true, error: null);
    try {
      // 1) 重读书籍记录（换源事务后的新记录）
      final newBook = await api.getBook(bookUrl);
      if (newBook == null) {
        throw StateError('读取书籍记录失败');
      }
      // 2) 同步书籍对象（bookUrl 稳定，源相关字段为新值）
      state = state.copyWith(currentBook: newBook);
      // 3) 重载目录（对齐 openBook：本地库优先，空则联网）
      var chapters = await api.getChapters(bookUrl);
      if (chapters.isEmpty && newBook.origin.isNotEmpty) {
        chapters = await api.refreshToc(bookUrl, newBook.origin);
      }
      if (chapters.isEmpty) {
        throw StateError('目录加载失败（新源无目录）');
      }
      // 4) 章节定位 + 位置保留
      final target = _matchChapterAfterTocReload(chapters, oldTitle, oldIndex);
      final sameChapter =
          oldChapter != null &&
          chapters[target].title.trim() == oldChapter.title.trim();
      state = state.copyWith(
        chapters: chapters,
        currentChapterIndex: target,
        currentChapterPos: sameChapter ? oldPos : 0,
      );
      // [F1-hunt F1 | 2026-09-24] 换源重载完成章节定位后回写进度，
      // 保证后续 _saveProgress 持久化的是新目录下的命中章/保留位
      _syncCurrentBookProgress();
      // 5) 强制刷新命中章正文（同 Fix A 路径；bookUrl 不变时靠清缓存
      //    保证取到新源正文）
      final err = await refreshChapterContent();
      if (err != null) {
        // 正文抓取失败：目录已是新源，保留旧正文，错误显式返回
        state = state.copyWith(isLoading: false, error: err);
        return '正文刷新失败：$err';
      }
      // 持久化换源后的新进度（新章节索引/位置）
      await _saveProgress();
      state = state.copyWith(isLoading: false);
      return null;
    } catch (e) {
      final msg = _mapError(e);
      state = state.copyWith(isLoading: false, error: msg);
      return msg;
    }
  }

  /// 换源重载目录后的章节定位（对齐 change_chapter_source_sheet 的
  /// _matchChapterIndex：精确标题 → 宽松互含 → 原索引（范围内）→ 0）
  int _matchChapterAfterTocReload(
    List<BookChapter> toc,
    String oldTitle,
    int oldIndex,
  ) {
    if (toc.isEmpty) return 0;
    final title = oldTitle.trim();
    if (title.isNotEmpty) {
      final exact = toc.indexWhere((c) => c.title.trim() == title);
      if (exact >= 0) return exact;
      final soft = toc.indexWhere(
        (c) =>
            c.title.isNotEmpty &&
            (c.title.contains(title) || title.contains(c.title)),
      );
      if (soft >= 0) return soft;
    }
    if (oldIndex >= 0 && oldIndex < toc.length) return oldIndex;
    return 0;
  }

  // ===== 内部工具 =====

  Future<void> _saveProgress() async {
    final book = state.currentBook;
    if (book == null) return;
    try {
      final api = ref.read(bookApiProvider);
      // [F1-hunt F6 | 2026-09-24] 哨兵归一：prevChapter 的 -1（跳末页
      // 哨兵）只存在于 state.currentChapterPos 供视图消费，落库前归 0，
      // -1 不得持久化（修复前 -1 随 updateReadingProgress 写入
      // durChapterPos，下次 openBook 按非法位置定位）
      final pos = state.currentChapterPos < 0 ? 0 : state.currentChapterPos;
      await api.updateReadingProgress(
        bookUrl: book.bookUrl,
        chapterIndex: state.currentChapterIndex,
        chapterPos: pos,
      );
      await _upReadTime(book);
    } catch (_) {
      // 保存失败不阻断阅读流程
    }
  }

  /// [F1-hunt F1 | 2026-09-24] 把当前阅读进度回写到 state.currentBook
  ///
  /// 修复前 currentBook 的 durChapterIndex/durChapterPos/durChapterTitle
  /// 永远停留在 openBook 时的快照，四个下游消费者均从 currentBook 读取
  /// 陈旧进度：ErrorView 重试（openBook(currentBook)）、设置保存
  /// （updateBook(currentBook.copyWith(...))）、自动换源重载
  /// （openBook(updated)）、目录高亮/定位。此处在每处章节/位置迁移点
  /// 把活进度回写 currentBook（仅三个进度字段，其余字段原样保留），
  /// 全行 updateBook 以此活快照写入，顺带中和 P2-8 陈旧快照覆写风险。
  ///
  /// openBook 不是回写点：以调用方传入的 book 为权威快照（既有测试
  /// 断言 openBook 不改写 currentBook）。
  ///
  /// [F1-hunt F6 | 2026-09-24] 哨兵归一：currentChapterPos < 0（-1 =
  /// 「跳上一章末页」哨兵）回写前归 0，-1 只存在于 state.currentChapterPos
  /// 供视图消费，不进入 currentBook / DB。
  void _syncCurrentBookProgress() {
    final book = state.currentBook;
    if (book == null) return;
    final pos = state.currentChapterPos < 0 ? 0 : state.currentChapterPos;
    final title = state.currentChapter?.title ?? book.durChapterTitle;
    if (book.durChapterIndex == state.currentChapterIndex &&
        book.durChapterPos == pos &&
        book.durChapterTitle == title) {
      return; // 无变化不重建（免无谓 notify / 重分页）
    }
    state = state.copyWith(
      currentBook: book.copyWith(
        durChapterIndex: state.currentChapterIndex,
        durChapterPos: pos,
        durChapterTitle: title,
      ),
    );
  }

  /// 进入阅读会话：加载已有时长并重置计时起点（对标 ReadBook.resetData）
  Future<void> _beginReadRecordSession(Book book) async {
    _readStartMs = DateTime.now().millisecondsSinceEpoch;
    _baseReadTimeMs = 0;
    try {
      final enable = await _settings.getEnableReadRecord();
      if (!enable) return;
      final records = await ref.read(bookApiProvider).getReadRecords();
      for (final r in records) {
        if (r.bookName == book.name) {
          _baseReadTimeMs += r.readTime;
        }
      }
    } catch (_) {
      // 忽略：阅读记录失败不阻断打开书籍
    }
  }

  /// 累计并写入阅读时长（对标 ReadBook.upReadTime）
  Future<void> _upReadTime(Book book) async {
    try {
      final enable = await _settings.getEnableReadRecord();
      if (!enable) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_readStartMs <= 0) {
        _readStartMs = now;
        return;
      }
      final delta = now - _readStartMs;
      if (delta <= 0) return;
      _baseReadTimeMs += delta;
      _readStartMs = now;
      await ref.read(bookApiProvider).putReadRecord(
            ReadRecord(
              bookName: book.name,
              readTime: _baseReadTimeMs,
              lastRead: now,
            ),
          );
    } catch (_) {
      // 写记录失败不阻断阅读
    }
  }

  /// 加载当前章节正文
  ///
  /// 统一调用 getChapterContentFull：本地书籍直接解析返回，在线书籍自动
  /// 从网络抓取并返回净化后的正文，始终返回纯正文字符串（无 JSON 元数据）。
  ///
  /// [F1-hunt F2 | 2026-09-24] 代际守卫（_loadSeq）：快速连点翻页时
  /// 多个加载并发在途，旧加载的结果返回时若已有更新的加载发起，则丢弃
  /// 旧结果（不覆盖新章正文、不写 error），返回 false，由调用方跳过
  /// 「清 isLoading / 保存进度」收尾——防旧章内容覆盖新章（F2 缺陷）。
  /// [F1-hunt F4 | 2026-09-24] 成功加载清 error（粘性错误随下一次成功
  /// 加载解除；失败置 error 并清空正文，视图层仅在正文为空时全屏降级，
  /// 见 ReaderPageView ErrorView 分支）。
  Future<bool> _loadChapterContent() async {
    final book = state.currentBook;
    if (book == null || state.chapters.isEmpty) return true;
    final seq = ++_loadSeq;
    // await 前捕获目标章：连点翻页后旧加载仍按自己捕获的索引取内容，
    // 完成后因代际过期被丢弃，不会误取/误写新章
    final index = state.currentChapterIndex;
    try {
      final api = ref.read(bookApiProvider);
      final content = await api.getChapterContentFull(book.bookUrl, index);
      if (seq != _loadSeq) return false; // 已被更新的加载取代，丢弃旧结果
      state = state.copyWith(chapterContent: content, error: null);
      return true;
    } catch (e) {
      if (seq != _loadSeq) return false; // 被取代加载的错误同样不得覆盖新状态
      state = state.copyWith(error: _mapError(e), chapterContent: '');
      return true;
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
