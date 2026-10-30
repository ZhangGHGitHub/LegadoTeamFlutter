import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart'
    show Brightness, ThemeMode, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../bridge/ffi.dart';
import '../../constants/pref_keys.dart';
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

  // [C1b-hunt | 2026-09-24] openBook 代际号：每次 openBook 自增并捕获；
  // 任一异步结果返回时若已有更新的 openBook 发起（并发开书 A 慢 / B 快），
  // 丢弃旧结果（不写目录/正文/索引、不写 error、不清 isLoading）——防 A
  // 的迟到结果覆盖已打开的 B（C1b 缺陷）。与 _loadSeq 粒度不同、可共存：
  // _openSeq 守「整次 openBook」（书级，并发开书），_loadSeq 守「单次正文
  // 加载」（章级，连点翻页）；openBook 内部触发的 _loadChapterContent 仍
  // 各自受 _loadSeq 守卫，两守卫互不替代。
  int _openSeq = 0;

  // [C5-hunt | 2026-09-24] 刷新正文重入守卫：refreshChapterContent 在途
  // 期间再次调用（UI 双入口：菜单面板 _refreshContentFlow / 顶栏刷新钮）
  // 直接返回原因、不重复清缓存与联网抓取（对齐换源流程
  // ChangeSourceNotifier.isApplying / _applying 的防重入形态，C5 缺陷：
  // N 次点击 = N 次整书清缓存 + N 次强制抓取）
  bool _refreshing = false;

  /// 刷新正文是否进行中（UI 入口据此提前返回，避免堆叠 SnackBar）
  bool get isRefreshing => _refreshing;

  // [SB-HUNT | 2026-09-25] 换源流程重入锁（provider/notifier 级，顶栏与
  // 菜单面板两入口共用——真机缺陷：两入口各自开换源页并各挂一条 10min
  // 「正在更换书源…」条，第二条/残留条）。两阶段使用：
  //   ① 导航阶段：UI 辅助（runChangeSourceFlow）tryBegin 后推换源页，
  //      pop 返回后 endChangeSourceFlow 释放——同步交接给重载阶段，
  //      中间无用户输入窗口；
  //   ② 重载阶段：reloadAfterSourceChange 内部再置位并 try/finally
  //      复位，作为兜底（其他调用方直接调 reload 时同样被挡住）。
  // 在途期间第二次触发被 UI 层静默忽略（进行中条即轻提示）。
  bool _changeSourceFlowActive = false;

  /// 换源流程是否进行中（导航或重载任一阶段）
  bool get isChangeSourceFlowActive => _changeSourceFlowActive;

  /// 尝试进入换源流程：已在途返回 false（调用方据此提前返回）
  bool tryBeginChangeSourceFlow() {
    if (_changeSourceFlowActive) return false;
    _changeSourceFlowActive = true;
    return true;
  }

  /// 结束换源流程（导航阶段结束；重载阶段由 finally 独立复位）
  void endChangeSourceFlow() {
    _changeSourceFlowActive = false;
  }

  /// 是否使用用户自定义背景（prefs `reader_bg_use_custom`）
  ///
  /// 背景 chip 的「自定义」选中态必须看这个显式标志，而不是「背景色不在
  /// 预设色表里」：深色主题的默认阅读背景是纯黑 0xFF000000（不在预设内），
  /// 用颜色反推会把它误标成自定义背景（批38b 审查 P3-2）。
  bool get useCustomBackground => _useCustomBackground;

  bool _useCustomBackground = false;

  @override
  ReaderState build() {
    // 延迟到 build() 返回后执行（state 初始化完成后才能访问）
    Future.microtask(_loadSettings);
    // [M1 深色态默认修复] 主题切换时重新解析阅读背景默认（仅影响
    // 「从未显式设置」路径，尊重用户显式选择；toggleDayNight 经
    // setThemeMode 同路）。监听挂在阅读器 Notifier 上：仅阅读器实际
    // 被使用（provider 已构建）时才随主题重解析，设置页切主题不会
    // 强制构建阅读器状态。
    ref.listen(themeNotifierProvider, (previous, next) {
      if (previous?.themeMode != next.themeMode) {
        // 传入监听值（next.themeMode）而非重读持久化：setThemeMode
        // 先更新内存状态（触发本监听）后异步落盘，此刻读 prefs 是旧值
        unawaited(reapplyBackgroundForCurrentTheme(themeMode: next.themeMode));
      }
    });
    return const ReaderState();
  }

  /// 字号下限（批33 裁决：采用参考版口径 5–50，步进 1，默认 20）
  ///
  /// [批33b | 字号越界收口] 数值单一来源改为
  /// [SettingsService.minFontSize]：读取/写入的 clamp 都在设置服务完成，
  /// 此处仅作为 UI 侧（滑条 min/divisions）的语义别名。
  static const double minFontSize = SettingsService.minFontSize;

  /// 字号上限（同参考版口径，见 [minFontSize]）
  static const double maxFontSize = SettingsService.maxFontSize;

  /// 从 SharedPreferences 加载持久化的阅读设置
  Future<void> _loadSettings() async {
    final storedFontSize = await _settings.getFontSize();
    // [批33 | 字号范围裁决 5–50] 读取同样归一：历史版本上限 32 不会越界，
    // 但早期手工写入/第三方备份可能 >50，超出即收敛到边界并回写，
    // 避免每次启动重复归一（与 updateFontSize 共用同一范围常量）— 全栈工程师
    final fontSize = storedFontSize.clamp(minFontSize, maxFontSize);
    if (fontSize != storedFontSize) {
      unawaited(_settings.setFontSize(fontSize));
    }
    final lineHeight = await _settings.getLineHeight();
    // [M1 深色态默认修复] 可空读取：null = 从未设置（与显式选 0 区分）
    final bgIndex = await _settings.getBgColorIndexOrNull();
    final modeName = await _settings.getFlipModeName();
    final legacyIndex = await _settings.getFlipMode();

    // [UI-fix v2.0.4 | 2026-08-08] 恢复自定义背景色（界面 Sheet 长按
    // 背景圆圈自定义配色，对标原版 ReadBookConfig 自定义背景）— Qoder
    final prefs = await SharedPreferences.getInstance();
    // [批38b | P3-2] 自定义背景选中态以显式标志为准（见 useCustomBackground）
    _useCustomBackground = prefs.getBool('reader_bg_use_custom') ?? false;
    Color? customBgColor;
    if (_useCustomBackground) {
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
    final hasExplicitIndex =
        storedIndex != null &&
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
      platform = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    } catch (_) {
      platform = Brightness.light;
    }
    return themeBrightnessFor(effectiveMode, platform);
  }

  /// 打开书籍：加载目录并定位到上次阅读章节
  ///
  /// [C1a-hunt | 2026-09-24] 换书（bookUrl 变化）时同步清空上一本书的
  /// 残留状态（目录/正文/章索引/章内位置/分页器/全局页数）——对齐原版
  /// ReadBook.resetData(book) → clearTextChapter() 并重置 chapterSize。
  /// 修复前打开 B 书目录抓取失败时，A 书目录/正文仍留在 State，
  /// reader_page_view 的「error 非空 && 正文为空」全屏错误页门槛失效，
  /// A 书正文冒充 B 书渲染且无任何错误提示（C1a 缺陷）。同书重开
  /// （ErrorView 重试 / 自动换源重载 openBook(currentBook)）不清空，
  /// 保留既有状态（F1b 重试不丢章节）。
  ///
  /// [C1b-hunt | 2026-09-24] 代际守卫（_openSeq）：每次调用自增并捕获，
  /// 任一 await 之后若已被更新的 openBook 取代（并发开书 A 慢 / B 快）
  /// 则丢弃旧结果（不写目录/正文/索引、不写 error、不清 isLoading）——
  /// 防 A 的迟到结果覆盖已打开的 B（C1b 缺陷）。
  Future<void> openBook(Book book) async {
    final openSeq = ++_openSeq;
    // [C1a-hunt | 2026-09-24] 换书判定：与当前书 bookUrl 不同才清旧书残留
    final isBookChange =
        state.currentBook == null || state.currentBook!.bookUrl != book.bookUrl;
    state = state.copyWith(
      currentBook: book,
      isLoading: true,
      error: null,
      showControls: false,
    );
    if (isBookChange) {
      // [C1a-hunt | 2026-09-24] 换书即清旧书残留（对齐原版
      // resetData → clearTextChapter）：换书失败时错误页门槛（error 非空
      // && 正文为空）可生效，目录/正文不再残留上一本书
      state = state.copyWith(
        chapters: const <BookChapter>[],
        chapterContent: '',
        currentChapterIndex: 0,
        currentChapterPos: 0,
      );
      _paginator.clear();
      // 全局页数随清空归零（totalPages=0 → globalPageIndex 钳制到 0）
      _syncGlobalPageInfo();
    }
    await _beginReadRecordSession(book);

    try {
      final api = ref.read(bookApiProvider);
      var chapters = await api.getChapters(book.bookUrl);
      if (openSeq != _openSeq) return; // [C1b-hunt] 已被更新的 openBook 取代，丢弃旧结果
      // 对齐原版：本地无目录的网络书籍（如刚从搜索结果加入书架，
      // 尚未拉取过目录），自动经书源规则从网络获取目录
      if (chapters.isEmpty && book.origin.isNotEmpty) {
        chapters = await api.refreshToc(book.bookUrl, book.origin);
        if (openSeq != _openSeq) return; // [C1b-hunt]
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
      // [C1b-hunt] 被取代的 openBook 的错误不得覆盖新状态（collection-if
      // 保持 HEAD 基线缩进列，避免 diff 引入纯空白行）
      if (openSeq == _openSeq) state = state.copyWith(error: _mapError(e));
    } finally {
      if (openSeq == _openSeq) state = state.copyWith(isLoading: false);
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
  ///
  /// [批33 | 字号范围裁决] 采用参考版口径 5–50（步进 1，默认 20）；
  /// 旧范围 12–32 作废（原版 ReadBookConfig 允许 5sp 起的小字号）。
  void updateFontSize(double size) {
    final clamped = size.clamp(minFontSize, maxFontSize);
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
      // [批38b | P3-2] 内存标志同步清零（背景 chip 选中态立刻跟随）
      _useCustomBackground = false;
      unawaited(
        SharedPreferences.getInstance().then(
          (p) => p.setBool('reader_bg_use_custom', false),
        ),
      );
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
    _useCustomBackground = true;
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
    final globalStart = _paginator.globalIndexForChapterStart(
      state.currentChapterIndex,
    );
    final globalIndex = globalStart >= 0
        ? globalStart + state.currentChapterPos
        : state.globalPageIndex;
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

  /// 设置编码后重载目录与当前章正文（批37b P1-1，对齐 `ReadBook.setCharset`）
  ///
  /// Rust `setBookCharset` 对本地 TXT 已清空章节表（目录 `start/end` 是
  /// 解码后文本的字节偏移，跨编码不可复用）。这里重新拉取目录、按索引
  /// 尽量保持位置，再重载当前章正文。
  ///
  /// 成功返回 null；失败返回原因（UI 据此展示失败，**不得提示成功**）。
  Future<String?> reloadAfterCharsetChange(Book book) async =>
      (await _reloadLocalTocAndContent(book, failureHint: '编码或文件不可读'))
          .error;

  /// 设置 TXT 目录规则后重载目录与当前章正文（批43，对齐 `MenuTocRegex`）
  ///
  /// Rust `setBookTocRule` 已清空本地 TXT 章节表并写入 `books.tocUrl`；
  /// 与换编码同理：重新拉取目录（按新规则解析）、尽量保持当前章索引，
  /// 再重载正文。
  ///
  /// 返回 [TocRuleReloadResult]：[TocRuleReloadResult.error] 非 null 表示
  /// 目录/正文重载失败；[TocRuleReloadResult.usedCustomRule] 来自 Rust
  /// `ChapterListResponse.used_custom_rule`——false 表示规则未命中/不可用，
  /// 已回退默认规则（批43b P2-1，UI 据此提示，不假报「已应用」）。
  Future<TocRuleReloadResult> reloadAfterTocRuleChange(Book book) =>
      _reloadLocalTocAndContent(book, failureHint: '目录规则未命中或文件不可读');

  /// 本地书目录/正文重载共用实现（编码 / 目录规则变更）
  Future<TocRuleReloadResult> _reloadLocalTocAndContent(
    Book book, {
    required String failureHint,
  }) async {
    final openSeq = _openSeq;
    state = state.copyWith(currentBook: book, isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final meta = await api.getChaptersWithMeta(book.bookUrl);
      final chapters = meta.chapters;
      // 开书代际已变化（并发切换到别的书）→ 丢弃旧结果
      if (openSeq != _openSeq) {
        return (error: null, usedCustomRule: meta.usedCustomRule);
      }
      if (chapters.isEmpty) {
        state = state.copyWith(error: '目录加载失败（$failureHint）');
        return (error: state.error, usedCustomRule: meta.usedCustomRule);
      }
      final index = state.currentChapterIndex
          .clamp(0, chapters.length - 1)
          .toInt();
      state = state.copyWith(
        chapters: chapters,
        currentChapterIndex: index,
        currentChapterPos: 0,
      );
      await _loadChapterContent();
      // [批43b P1-2] 重载成功后以库内真源刷新 currentBook：
      // `setBookTocRule` 返回的 Book 在重解析前派生字段（totalChapterNum/
      // latestChapterTitle）已重置为 0/NULL，若停留在 State 里，后续整书
      // 回写会把刚回填的 N 打回 0。getBook 失败不覆盖当前快照（不影响阅读）。
      if (openSeq == _openSeq) {
        try {
          final fresh = await api.getBook(book.bookUrl);
          if (fresh != null && openSeq == _openSeq) {
            state = state.copyWith(currentBook: fresh);
          }
        } catch (_) {
          // 刷新 Book 快照失败不阻断阅读；Rust 整书写侧已保护派生字段
        }
      }
      return (error: state.error, usedCustomRule: meta.usedCustomRule);
    } catch (e) {
      final message = _mapError(e);
      state = state.copyWith(error: message);
      return (error: message, usedCustomRule: false);
    } finally {
      if (openSeq == _openSeq) {
        state = state.copyWith(isLoading: false);
      }
    }
  }

  // [UI-fix v2.0.2 | 2026-08-06] 同步已持久化的书对象到 State
  // （readConfig 变更经 BookApi.updateBook 落库后回写 UI 状态） — Qoder
  void updateCurrentBook(Book book) {
    state = state.copyWith(currentBook: book);
  }

  // [P2-9 | 2026-09-24] 强制刷新当前章正文（绕过缓存，重新联网抓取）
  // [STAGE3-C2B | 2026-09-28] 对齐上游原版 refreshContentDur（用户已裁决）：
  // delContent + loadContent = 先失效当前章缓存 → 再联网重抓。
  // 现已具备章级失效 FFI（clearChapterCache ≡ 上游 BookHelp.delContent，
  // 仅删当前章缓存行、不触碰章级开关键），C2 期自创的「先抓取、成功后才
  // 失效」与「成功后 clearBookCache 整书清缓存」一并移除——缓存优先 ×
  // fetch-first 的组合正是「已缓存章刷新不生效且误清整书离线缓存」的
  // 根因（STAGE3-C2B 裁决前形态）。
  //
  // 新语义（对齐上游）：
  // - 刷新必发网络请求（失效当前章缓存后，缓存优先不再拦截）；
  // - 成功：新内容持久化并更新 State（fetch 自动回写缓存行，无需再
  //   整书清缓存）；
  // - 失败（异常/空正文）：当前章缓存行已在「先失效」步骤删除（失败
  //   保留旧缓存的持久层语义按用户裁决对齐上游后不再保留），UI 保留
  //   旧正文并显示失败原因，同书他章缓存原样保留（无整书清理）。
  // [C5-hunt | 2026-09-24] 重入守卫（_refreshing）：在途期间重复调用
  // 直接返回原因，N 次点击不再触发 N 次失效 + N 次强制抓取
  // （对齐换源流程 isApplying/_applying 的防重入形态）。
  //
  // 成功返回 null；失败返回错误原因（保留旧正文，不清空 chapterContent）。
  // 本地书（origin 为空 / loc_book / webDav:: / 存量 dav:）与
  // 无书籍/目录/非法索引时直接返回说明性原因，不触碰 state 数据（对齐
  // 原版：本地书不显示换源/刷新菜单，此守卫兜底面板侧入口）。
  Future<String?> refreshChapterContent() async {
    final book = state.currentBook;
    if (book == null || state.chapters.isEmpty) return '没有书籍或目录';
    if (book.origin.isEmpty || BookType.isLocalOrigin(book.origin)) {
      return '本地书不支持刷新正文';
    }
    final idx = state.currentChapterIndex;
    if (idx < 0 || idx >= state.chapters.length) return '无效章节索引';
    if (_refreshing) return '正文刷新进行中'; // [C5-hunt] 重入守卫
    _refreshing = true;
    final chapter = state.chapters[idx];
    final api = ref.read(bookApiProvider);
    state = state.copyWith(isLoading: true, error: null);
    try {
      // [STAGE3-C2B] 1) 先失效当前章缓存（≡ 上游 delContent：只删本章
      // 行，同书他章缓存不受影响）
      await api.clearChapterCache(book.bookUrl, idx);
      // 2) 联网抓取（缓存已失效，缓存优先不再拦截，必取站点新内容）
      final content = await api.fetchChapterContent(
        book.bookUrl,
        chapter.url,
        book.origin,
      );
      if (content.trim().isEmpty) {
        // 空正文视为抓取失败：保留旧正文（当前章缓存行已失效，
        // 他章不受影响，无整书清理）
        state = state.copyWith(isLoading: false, error: '正文抓取为空');
        return '正文抓取为空';
      }
      // 3) 成功：持久化新内容（fetch 已自动回写当前章缓存行）
      state = state.copyWith(chapterContent: content, isLoading: false);
      return null;
    } catch (e) {
      // [STAGE3-C2B] 失败保留旧正文并显示原因；仅当前章缓存行丢失
      // （对齐上游，不做整书清理）
      final msg = _mapError(e);
      state = state.copyWith(isLoading: false, error: msg);
      return msg;
    } finally {
      _refreshing = false; // [C5-hunt]
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
    // [SB-HUNT | 2026-09-25] 重入兜底：重载阶段在途（或导航阶段
    // 进行中）时直接返回，不重复 getBook/重载目录/清缓存
    if (_changeSourceFlowActive) return '更换书源进行中';
    _changeSourceFlowActive = true;
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
      // 5) 强制刷新命中章正文（同 Fix A 路径；[STAGE3-C2B] 先失效当前
      //    章缓存行再抓取，bookUrl 不变时仍保证取到新源正文）
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
    } finally {
      // [SB-HUNT | 2026-09-25] 重载阶段锁必复位（含异常/取消路径）
      _changeSourceFlowActive = false;
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
  ///
  /// [批27b P1-1 | 2026-10-28] 基数只取该书的「主记录」，**不得把同名书
  /// 所有作者行的 readTime 求和**：Rust 写路径
  /// （`read_record_api.rs::upsert_read_record`）只取一行（author='' 优先，
  /// 其次 lastRead 最大）作 old_read_time，并把新时长写回该行；若基数含
  /// 其他作者行，第二会话起每会话都会把别人的时长重复叠加进主记录，热力图
  /// 与阅读记录页随之膨胀。选取口径见 [_primaryReadRecord]。
  Future<void> _beginReadRecordSession(Book book) async {
    _readStartMs = DateTime.now().millisecondsSinceEpoch;
    _baseReadTimeMs = 0;
    try {
      final enable = await _settings.getEnableReadRecord();
      if (!enable) return;
      final records = await ref.read(bookApiProvider).getReadRecords();
      _baseReadTimeMs = _primaryReadRecord(records, book.name)?.readTime ?? 0;
    } catch (_) {
      // 忽略：阅读记录失败不阻断打开书籍
    }
  }

  /// 选取该书的「主记录」——与 Rust `ReadRecordRepository::primary_record`
  /// 的排序口径**完全一致**：
  ///
  /// `author == ''` 优先（旧式本机记录）→ `lastRead` 最大 → `readTime` 最大。
  ///
  /// 写路径（`putReadRecord`）不传作者，Rust 侧按同一口径选主记录回写；
  /// 两侧口径任何不一致都会导致时长错记/重复累加（批27b P1-1）。
  static ReadRecord? _primaryReadRecord(
    List<ReadRecord> records,
    String bookName,
  ) {
    ReadRecord? primary;
    for (final r in records) {
      if (r.bookName != bookName) continue;
      if (primary == null || _preferPrimary(r, primary)) {
        primary = r;
      }
    }
    return primary;
  }

  /// [candidate] 是否应优先于 [current] 作为主记录（同 Rust ORDER BY 语义）
  static bool _preferPrimary(ReadRecord candidate, ReadRecord current) {
    final candidateBlank = candidate.author.isEmpty;
    final currentBlank = current.author.isEmpty;
    if (candidateBlank != currentBlank) return candidateBlank;
    if (candidate.lastRead != current.lastRead) {
      return candidate.lastRead > current.lastRead;
    }
    return candidate.readTime > current.readTime;
  }

  /// 累计并写入阅读时长（对标 ReadBook.upReadTime）
  ///
  /// [批35] 书籍级开关：`book.disableReadRecord` 为真时**本地短路**（连 FFI
  /// 都不发）；写路径同时传 `bookUrl`，由 Rust 侧再查一次 DB 兜住「详情页
  /// 切换后阅读器仍持旧 Book 副本」的并发窗口（API_CONTRACT §2.12 注②）。
  /// 本轨仅文本阅读器写 readRecord（朗读/听书不写，RSS 记录是独立体系）。
  ///
  /// [批35b P3-1] 关闭期间不得补记：
  /// - 本地短路（全局/书级关闭）时推进 `_readStartMs`，重开后只从重开时刻
  ///   起算，不把关闭期间算进下一次增量；
  /// - Rust 侧跳过（陈旧副本窗口）时 `putReadRecord` 返回 `false`，把本轮已
  ///   累加的 `delta` 从 `_baseReadTimeMs` 回滚，避免下次写入补记关闭时长。
  Future<void> _upReadTime(Book book) async {
    try {
      final enable = await _settings.getEnableReadRecord();
      if (!enable || book.disableReadRecord) {
        // 关闭期间不计时：推进起点，使重开后首轮 delta 从重开时刻起算
        _readStartMs = DateTime.now().millisecondsSinceEpoch;
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_readStartMs <= 0) {
        _readStartMs = now;
        return;
      }
      final delta = now - _readStartMs;
      if (delta <= 0) return;
      _baseReadTimeMs += delta;
      _readStartMs = now;
      final written = await ref
          .read(bookApiProvider)
          .putReadRecord(
            ReadRecord(
              bookName: book.name,
              readTime: _baseReadTimeMs,
              lastRead: now,
            ),
            bookUrl: book.bookUrl,
          );
      if (!written) {
        // Rust 按库内开关跳过：回滚本轮累加（已推进的起点保留）
        final rolledBack = _baseReadTimeMs - delta;
        _baseReadTimeMs = rolledBack < 0 ? 0 : rolledBack;
      }
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
      // [批9a 项8] 翻章成功钩子：按 preDownloadNum 向前轻量预取
      //（对齐参考版 ReadBook.preDownload 的触发时机与窗口语义）
      _preDownloadNextChapters(book, index);
      return true;
    } catch (e) {
      if (seq != _loadSeq) return false; // 被取代加载的错误同样不得覆盖新状态
      state = state.copyWith(error: _mapError(e), chapterContent: '');
      return true;
    }
  }

  // ===== [批9a 项8] 预下载（轻量预取）=====

  /// 预取批次号（每次触发递增，用于记录表收敛）
  int _preDownloadSeq = 0;

  /// 已预取章节记录（章索引 → 批次号）：同一阅读会话内同章只预取一次
  ///（Rust 侧缓存命中零开销，重复调用纯浪费；重开书/重进阅读器
  /// Notifier 重建时自然重置）
  final Map<int, int> _preDownloadedBatch = {};

  /// 翻章成功后按 `preDownloadNum` 预取后续 N 章正文（参考版
  /// `ReadBook.kt:1929 preDownload` 语义的轻量对齐）
  ///
  /// - 窗口 `[index+1, min(index+N, total-1)]`（参考版向后预取窗口；
  ///   参考版另有独立 preDownloadNumPrev 向前窗口，我方偏好仅一枚，
  ///   按 UI 副题「预先下载 N 章正文」实现向后窗口）；
  /// - 本地书不预取（参考版 `book?.isLocal == true` 直接 return；本地
  ///   章节是文件随机读取，无「下载」语义）；
  /// - 0 = 关闭（参考版 `forward <= 0 && backward <= 0` return）；
  /// - fire-and-forget：失败静默（catchError 吞掉，Rust 链路写库失败也
  ///   仅告警不传播）；命中既有缓存时 Rust 直接返回，零网络开销；
  /// - 不阻塞当前章加载（unawaited，在 await 链外）；
  /// - 不重复：同章在更新批次内已发起过则跳过（批次号随翻章递增，
  ///   防同章反复网络抓取；重开书/重进阅读器自然重置）。
  void _preDownloadNextChapters(Book book, int index) {
    // 开销考虑：进页读一次偏好而非每章读；失败按关闭处理（安全侧）
    unawaited(() async {
      int n;
      try {
        n = await _settings.getIntPref(PrefKeys.preDownloadNum,
            defaultValue: 10);
      } catch (_) {
        return;
      }
      if (n <= 0) return; // 0 = 关闭（对齐参考版语义）
      final chapters = state.chapters;
      final total = chapters.length;
      if (total == 0) return;
      final batch = ++_preDownloadSeq;
      final maxIndex = (index + n < total - 1) ? index + n : total - 1;
      final api = ref.read(bookApiProvider);
      if (BookType.isLocalBook(book)) return; // 本地书不预取
      for (var i = index + 1; i <= maxIndex; i++) {
        if (_preDownloadedBatch.containsKey(i)) {
          continue; // 同章已由此前批次预取过（Rust 缓存幂等，无需重抓）
        }
        _preDownloadedBatch[i] = batch;
        // 静默失败：预取不影响阅读（Rust 内部写库失败也仅告警）
        unawaited(
          api.getChapterContentFull(book.bookUrl, i).catchError((_) => ''),
        );
      }
      // 收敛记录表：仅保留近期批次章索引，防长时间阅读无限增长
      if (_preDownloadedBatch.length > maxIndex - index + 64) {
        _preDownloadedBatch
            .removeWhere((chapter, b) => b < batch - 8);
      }
    }());
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
final readerNotifierProvider = NotifierProvider<ReaderNotifier, ReaderState>(
  ReaderNotifier.new,
);
