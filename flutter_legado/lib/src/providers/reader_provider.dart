import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/rust_api.dart';
import '../services/settings_service.dart';

/// 翻页模式
enum PageTurnMode {
  scroll, // 上下滚动
  slide, // 左右滑动
  simulate, // 仿真翻页
}

/// 阅读背景预设
class ReaderBackground {
  static const white = Color(0xFFFFFFFF);
  static const green = Color(0xFFCCEBCC);
  static const brown = Color(0xFFD4A574);
  static const dark = Color(0xFF1A1A1A);
  static const eyeProtect = Color(0xFFE8E0C8);

  static const List<Color> presets = [white, green, brown, eyeProtect, dark];
  static const List<String> labels = ['白色', '绿色', '棕色', '护眼', '夜间'];
}

/// 阅读器状态管理
class ReaderProvider extends ChangeNotifier {
  final RustApi _api;
  final SettingsService _settings = SettingsService();

  ReaderProvider(this._api);

  // ===== 阅读状态 =====
  Book? _currentBook;
  List<BookChapter> _chapters = [];
  int _currentChapterIndex = 0;
  int _currentChapterPos = 0;
  String _chapterContent = '';
  bool _loading = false;
  String? _error;
  bool _showControls = false;

  // ===== 阅读设置 =====
  double _fontSize = 18.0;
  double _lineHeight = 1.6;
  Color _backgroundColor = ReaderBackground.white;
  PageTurnMode _pageTurnMode = PageTurnMode.scroll;

  // ===== Getters =====

  Book? get currentBook => _currentBook;
  List<BookChapter> get chapters => _chapters;
  int get currentChapterIndex => _currentChapterIndex;
  int get currentChapterPos => _currentChapterPos;
  String get chapterContent => _chapterContent;
  bool get loading => _loading;
  String? get error => _error;
  bool get showControls => _showControls;

  double get fontSize => _fontSize;
  double get lineHeight => _lineHeight;
  Color get backgroundColor => _backgroundColor;
  PageTurnMode get pageTurnMode => _pageTurnMode;

  bool get hasPreviousChapter => _currentChapterIndex > 0;
  bool get hasNextChapter => _currentChapterIndex < _chapters.length - 1;

  BookChapter? get currentChapter {
    if (_chapters.isEmpty) return null;
    if (_currentChapterIndex >= _chapters.length) return null;
    return _chapters[_currentChapterIndex];
  }

  double get readingProgress {
    if (_chapters.isEmpty) return 0;
    return (_currentChapterIndex + 1) / _chapters.length;
  }

  // ===== 操作 =====

  /// 从 SharedPreferences 加载持久化的阅读设置
  Future<void> loadSettings() async {
    _fontSize = await _settings.getFontSize();
    _lineHeight = await _settings.getLineHeight();
    final bgIndex = await _settings.getBgColorIndex();
    if (bgIndex >= 0 && bgIndex < ReaderBackground.presets.length) {
      _backgroundColor = ReaderBackground.presets[bgIndex];
    }
    final flipIndex = await _settings.getFlipMode();
    if (flipIndex >= 0 && flipIndex < PageTurnMode.values.length) {
      _pageTurnMode = PageTurnMode.values[flipIndex];
    }
    notifyListeners();
  }

  Future<void> openBook(Book book) async {
    _currentBook = book;
    _loading = true;
    _error = null;
    _showControls = false;
    notifyListeners();

    try {
      _chapters = await _api.getChapters(book.bookUrl);
      _currentChapterIndex = book.durChapterIndex;
      if (_currentChapterIndex >= _chapters.length && _chapters.isNotEmpty) {
        _currentChapterIndex = 0;
      }
      await _loadChapterContent();
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> nextChapter() async {
    if (!hasNextChapter) return;
    await _saveProgress();
    _currentChapterIndex++;
    _currentChapterPos = 0;
    _loading = true;
    notifyListeners();
    await _loadChapterContent();
    _loading = false;
    notifyListeners();
    await _saveProgress();
  }

  Future<void> prevChapter() async {
    if (!hasPreviousChapter) return;
    await _saveProgress();
    _currentChapterIndex--;
    _currentChapterPos = 0;
    _loading = true;
    notifyListeners();
    await _loadChapterContent();
    _loading = false;
    notifyListeners();
    await _saveProgress();
  }

  Future<void> goToChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    await _saveProgress();
    _currentChapterIndex = index;
    _currentChapterPos = 0;
    _loading = true;
    _showControls = false;
    notifyListeners();
    await _loadChapterContent();
    _loading = false;
    notifyListeners();
    await _saveProgress();
  }

  void toggleControls() {
    _showControls = !_showControls;
    notifyListeners();
  }

  void hideControls() {
    if (_showControls) {
      _showControls = false;
      notifyListeners();
    }
  }

  void updateFontSize(double size) {
    _fontSize = size.clamp(12.0, 32.0);
    _settings.setFontSize(_fontSize);
    notifyListeners();
  }

  void updateLineHeight(double height) {
    _lineHeight = height.clamp(1.0, 2.5);
    _settings.setLineHeight(_lineHeight);
    notifyListeners();
  }

  void updateBackgroundColor(Color color) {
    _backgroundColor = color;
    final index = ReaderBackground.presets.indexOf(color);
    if (index >= 0) {
      _settings.setBgColorIndex(index);
    }
    notifyListeners();
  }

  void updatePageTurnMode(PageTurnMode mode) {
    _pageTurnMode = mode;
    _settings.setFlipMode(mode.index);
    notifyListeners();
  }

  /// 更新当前阅读位置（由 UI 层滚动/翻页时调用）
  void updatePosition(int position) {
    _currentChapterPos = position;
  }

  /// 保存当前阅读进度到后端
  Future<void> saveProgress() async {
    await _saveProgress();
  }

  @override
  void dispose() {
    // 退出前保存进度（fire-and-forget，dispose 不能 await）
    _saveProgress();
    super.dispose();
  }

  Future<void> _saveProgress() async {
    if (_currentBook == null) return;
    try {
      await _api.updateReadingProgress(
        bookUrl: _currentBook!.bookUrl,
        chapterIndex: _currentChapterIndex,
        chapterPos: _currentChapterPos,
      );
    } catch (_) {
      // 保存失败不阻断阅读流程
    }
  }

  Future<void> _loadChapterContent() async {
    if (_currentBook == null || _chapters.isEmpty) return;
    try {
      final content = await _api.getChapterContent(
        _currentBook!.bookUrl,
        _currentChapterIndex,
      );

      // 检查是否是 JSON 元数据（在线书籍）
      if (content.startsWith('{') && content.contains('chapter_url')) {
        try {
          final meta = jsonDecode(content) as Map<String, dynamic>;
          final chapterUrl = meta['chapter_url'] as String? ?? '';
          final sourceUrl = _currentBook!.origin; // 书源 URL
          if (chapterUrl.isNotEmpty && sourceUrl.isNotEmpty) {
            // 在线书籍：通过 FFI 获取真实正文
            _chapterContent = await _api.fetchChapterContent(
              _currentBook!.bookUrl,
              chapterUrl,
              sourceUrl,
            );
          } else {
            _chapterContent = content;
          }
        } catch (_) {
          _chapterContent = content; // fallback
        }
      } else {
        _chapterContent = content; // 本地书籍直接使用
      }
    } catch (e) {
      _error = e.toString();
      _chapterContent = '';
    }
  }
}
