/// 书签标记 Notifier（契约 §2.52，批7b-2a）
///
/// 职责：
/// - 调 BookApi 读写 `book_marks`，维护内存列表与修订号；
/// - `save` 语义对齐参考版 `SaveMarkingUseCase`：按「书名 + 作者 + 章」查已有，
///   锚点 `chapterPosition` + 归一化文本相同则原地更新（保留 id/createdAt，
///   enabled 置 true，updatedAt 由 Rust 重写），否则新建（id 传空由 Rust 生成 UUID v4）；
/// - 归一化/哈希口径见 `models/book_marking_style.dart`。
///
/// 失败向上抛出（BridgeError 等），由 UI 决定 SnackBar 文案。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../services/book_api.dart';
import '../providers.dart';

/// 书签标记列表 Notifier
class BookMarkingNotifier extends Notifier<List<BookMarking>> {
  @override
  List<BookMarking> build() => const <BookMarking>[];

  /// 按书名 + 作者加载全部章节/源的标记
  Future<void> loadByBook(String bookName, String bookAuthor) async {
    final api = ref.read(bookApiProvider);
    final list = await api.getBookMarkingsByBook(bookName, bookAuthor);
    state = List.unmodifiable(list);
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
      marking = existing.copyWith(
        bookUrl: bookUrl,
        anchorJson: anchor.encode(),
        styleJson: style.encode(),
        note: note,
        chapterName: chapterName.isEmpty
            ? existing.chapterName
            : chapterName,
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
    _upsertState(saved);
    return saved;
  }

  /// 启停标记（不存在为 no-op，由 Rust 保证）
  Future<void> setEnabled(String id, bool enabled) async {
    final api = ref.read(bookApiProvider);
    await api.setBookMarkingEnabled(id, enabled);
    final index = state.indexWhere((m) => m.id == id);
    if (index >= 0) {
      final list = [...state];
      list[index] = list[index].copyWith(
        enabled: enabled,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      state = List.unmodifiable(list);
      _bumpRevision();
    }
  }

  /// 删除标记（不存在为 no-op，由 Rust 保证）
  Future<void> delete(String id) async {
    final api = ref.read(bookApiProvider);
    await api.deleteBookMarking(id);
    state = List.unmodifiable(state.where((m) => m.id != id).toList());
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

  void _upsertState(BookMarking saved) {
    final list = [...state];
    final index = list.indexWhere((m) => m.id == saved.id);
    if (index >= 0) {
      list[index] = saved;
    } else {
      list.add(saved);
    }
    state = List.unmodifiable(list);
    _bumpRevision();
  }

  void _bumpRevision() {
    ref.read(bookMarkingsRevisionProvider.notifier).state++;
  }
}

/// 书签标记 Notifier 全局 Provider
final bookMarkingNotifierProvider =
    NotifierProvider<BookMarkingNotifier, List<BookMarking>>(
      BookMarkingNotifier.new,
    );
