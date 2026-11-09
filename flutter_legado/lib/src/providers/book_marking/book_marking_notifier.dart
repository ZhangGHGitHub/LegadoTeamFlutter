/// 书签标记 Notifier（契约 §2.52，批7b-2a；批7b-2b 审查修正）
///
/// 职责：
/// - 调 BookApi 读写 `book_marks`，维护内存列表、当前书标识与加载状态；
/// - `save` 语义对齐参考版 `SaveMarkingUseCase`：按「书名 + 作者 + 章」查已有，
///   锚点 `chapterPosition` + 归一化文本相同则原地更新（保留 id/createdAt/
///   bookUrl，enabled 置 true，updatedAt 由 Rust 重写），否则新建
///   （id 传空由 Rust 生成 UUID v4）；
/// - `findExisting` 供划词入口复用：同段再次打开时直接进入编辑模式；
/// - 归一化/哈希口径见 `models/book_marking_style.dart`。
///
/// 失败向上抛出（BridgeError 等），同时把错误写入状态供 TOC 错误页判定；
/// 状态带「当前书」标识，切书/加载失败时不会残留上一本书的标记。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/book_api.dart';
import '../providers.dart';

/// 书签标记列表状态（含所属书与加载结果）
class BookMarkingListState {
  const BookMarkingListState({
    this.items = const <BookMarking>[],
    this.bookName = '',
    this.bookAuthor = '',
    this.loading = false,
    this.loaded = false,
    this.error,
  });

  /// 当前列表（仅当 [bookName]/[bookAuthor] 指向当前书时有意义）
  final List<BookMarking> items;

  /// 列表所属书名/作者（跨源关联键）
  final String bookName;
  final String bookAuthor;

  /// 是否正在加载
  final bool loading;

  /// 本次加载是否成功
  final bool loaded;

  /// 本次加载错误（成功为 null）
  final String? error;

  /// 列表是否属于指定书
  bool isFor(String name, String author) =>
      bookName == name && bookAuthor == author;

  BookMarkingListState copyWith({
    List<BookMarking>? items,
    String? bookName,
    String? bookAuthor,
    bool? loading,
    bool? loaded,
    Object? error = _unset,
  }) {
    return BookMarkingListState(
      items: items ?? this.items,
      bookName: bookName ?? this.bookName,
      bookAuthor: bookAuthor ?? this.bookAuthor,
      loading: loading ?? this.loading,
      loaded: loaded ?? this.loaded,
      error: identical(error, _unset) ? this.error : error as String?,
    );
  }

  static const _unset = Object();
}

/// 书签标记列表 Notifier
class BookMarkingNotifier extends Notifier<BookMarkingListState> {
  /// 加载代际号：A→B 并发时旧结果不覆盖新书
  int _loadSeq = 0;

  @override
  BookMarkingListState build() => const BookMarkingListState();

  /// 按书名 + 作者加载全部章节/源的标记
  ///
  /// 开始即清空旧列表并带上目标书标识（防切书残留）；失败同样清空并记录
  /// error，随后向上抛出供调用方提示。
  Future<void> loadByBook(String bookName, String bookAuthor) async {
    final seq = ++_loadSeq;
    state = BookMarkingListState(
      bookName: bookName,
      bookAuthor: bookAuthor,
      loading: true,
    );
    try {
      final list = await ref
          .read(bookApiProvider)
          .getBookMarkingsByBook(bookName, bookAuthor);
      if (seq != _loadSeq) return;
      state = BookMarkingListState(
        items: List.unmodifiable(list),
        bookName: bookName,
        bookAuthor: bookAuthor,
        loaded: true,
      );
    } catch (e) {
      if (seq != _loadSeq) return;
      state = BookMarkingListState(
        bookName: bookName,
        bookAuthor: bookAuthor,
        error: _mapError(e),
      );
      rethrow;
    }
  }

  /// 按源地址加载（chapterIndex 非空时含该章 + chapterIndex IS NULL）
  Future<List<BookMarking>> listForChapter(
    String bookUrl,
    int? chapterIndex,
  ) async {
    final api = ref.read(bookApiProvider);
    return api.getBookMarkingsForChapter(bookUrl, chapterIndex);
  }

  /// 保存标记：同锚点原地更新，否则新建
  ///
  /// 返回落库后的对象（含 Rust 生成的 id / createdAt / updatedAt）。
  Future<BookMarking> save({
    required String bookName,
    required String bookAuthor,
    required String bookUrl,
    required int chapterIndex,
    required String chapterName,
    required int chapterPosition,
    required String selectedText,
    required BookMarkingStyle style,
    String note = '',
    String contextBefore = '',
    String contextAfter = '',
  }) async {
    final normalized = normalizeMarkingText(selectedText);
    if (normalized.isEmpty) {
      throw const FormatException('选中文本为空，无法保存笔记');
    }
    final anchor = buildBookMarkingAnchor(
      chapterIndex: chapterIndex,
      chapterPosition: chapterPosition,
      selectedText: normalized,
      contextBefore: contextBefore,
      contextAfter: contextAfter,
    );
    final api = ref.read(bookApiProvider);
    final existing = await _findExisting(
      api: api,
      bookName: bookName,
      bookAuthor: bookAuthor,
      chapterIndex: chapterIndex,
      anchor: anchor,
    );

    final BookMarking marking;
    if (existing != null) {
      // [P2-5] 保留既有行 bookUrl（契约：换源不改写既有行 bookUrl）
      marking = existing.copyWith(
        anchorJson: anchor.encode(),
        styleJson: style.encode(),
        note: note,
        chapterName: chapterName.isEmpty ? existing.chapterName : chapterName,
        enabled: true,
      );
    } else {
      marking = BookMarking(
        bookUrl: bookUrl,
        bookName: bookName,
        bookAuthor: bookAuthor,
        chapterIndex: chapterIndex,
        anchorJson: anchor.encode(),
        styleJson: style.encode(),
        note: note,
        chapterName: chapterName,
        enabled: true,
      );
    }

    final saved = await api.saveBookMarking(marking);
    _upsertState(saved, bookName, bookAuthor);
    return saved;
  }

  /// 按锚点查已有标记（同章 + chapterPosition + 归一化文本）
  ///
  /// 划词入口在打开 Sheet 前调用：同段再次打开直接进入编辑模式，预填
  /// 样式/备注，避免新建模式的空备注覆盖旧备注。
  Future<BookMarking?> findExisting({
    required String bookName,
    required String bookAuthor,
    required int chapterIndex,
    required int chapterPosition,
    required String selectedText,
  }) async {
    final normalized = normalizeMarkingText(selectedText);
    if (normalized.isEmpty) return null;
    final anchor = buildBookMarkingAnchor(
      chapterIndex: chapterIndex,
      chapterPosition: chapterPosition,
      selectedText: normalized,
    );
    return _findExisting(
      api: ref.read(bookApiProvider),
      bookName: bookName,
      bookAuthor: bookAuthor,
      chapterIndex: chapterIndex,
      anchor: anchor,
    );
  }

  /// 启停标记（不存在为 no-op，由 Rust 保证）
  Future<void> setEnabled(String id, bool enabled) async {
    final api = ref.read(bookApiProvider);
    await api.setBookMarkingEnabled(id, enabled);
    final index = state.items.indexWhere((m) => m.id == id);
    if (index >= 0) {
      final list = [...state.items];
      list[index] = list[index].copyWith(
        enabled: enabled,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      state = state.copyWith(items: List.unmodifiable(list), error: null);
    }
    _bumpRevision();
  }

  /// 删除标记（不存在为 no-op，由 Rust 保证）
  Future<void> delete(String id) async {
    final api = ref.read(bookApiProvider);
    await api.deleteBookMarking(id);
    state = state.copyWith(
      items: List.unmodifiable(state.items.where((m) => m.id != id).toList()),
      error: null,
    );
    _bumpRevision();
  }

  /// 按锚点查已有标记（同章 + chapterPosition + 归一化文本）
  Future<BookMarking?> _findExisting({
    required BookApi api,
    required String bookName,
    required String bookAuthor,
    required int chapterIndex,
    required BookMarkingAnchor anchor,
  }) async {
    final list = await api.getBookMarkingsByBook(bookName, bookAuthor);
    for (final marking in list) {
      if (marking.chapterIndex != chapterIndex) continue;
      final candidate = BookMarkingAnchor.tryParse(marking.anchorJson);
      if (candidate == null) continue;
      if (candidate.chapterPosition == anchor.chapterPosition &&
          candidate.selectedText == anchor.selectedText) {
        return marking;
      }
    }
    return null;
  }

  void _upsertState(BookMarking saved, String bookName, String bookAuthor) {
    if (state.bookName.isEmpty && state.bookAuthor.isEmpty) {
      // 尚未绑定任何书（阅读器内首次保存）：认领当前书并放入本条
      state = state.copyWith(
        bookName: bookName,
        bookAuthor: bookAuthor,
        items: List.unmodifiable([saved]),
        error: null,
      );
    } else if (state.isFor(bookName, bookAuthor)) {
      final list = [...state.items];
      final index = list.indexWhere((m) => m.id == saved.id);
      if (index >= 0) {
        list[index] = saved;
      } else {
        list.add(saved);
      }
      state = state.copyWith(items: List.unmodifiable(list), error: null);
    }
    _bumpRevision();
  }

  void _bumpRevision() {
    ref.read(bookMarkingsRevisionProvider.notifier).state++;
  }

  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 书签标记 Notifier 全局 Provider
final bookMarkingNotifierProvider =
    NotifierProvider<BookMarkingNotifier, BookMarkingListState>(
      BookMarkingNotifier.new,
    );
