import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/book_api.dart' show DeleteBooksResult;
import '../../services/privacy_content_service.dart';
import '../../services/settings_service.dart';
import '../../services/webdav_book_upload_service.dart';
import '../privacy/privacy_content_notifier.dart';
import '../providers.dart';
import 'bookshelf_state.dart';

export 'bookshelf_state.dart';

/// 书架 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §3.2 铁律）：
/// - 调用 BookApi → 接收纯数据 → 更新 immutable State
/// - 管理 UI 状态（loading/error/data 三态）
/// - 管理展示层变换（网格/列表切换、分组模式）
/// - 禁止包含业务计算（排序/过滤/规则解析由 Rust 完成）
///
/// [批9c] 私密标记（单本 / 分组）由 [privacyContentProvider] 统一加载，
/// 本 Notifier 只把快照同步进状态供派生过滤与计数使用。
class BookshelfNotifier extends Notifier<BookshelfState> {
  final SettingsService _settings = SettingsService();

  @override
  BookshelfState build() {
    // 私密标记刷新（批量设私密 / 分组开关）后同步到书架派生过滤
    ref.listen<PrivacyContentSnapshot>(privacyContentProvider, (_, next) {
      _applyPrivacySnapshot(next);
    });
    // 延迟到 build() 返回后执行（state 初始化完成后才能访问）
    Future.microtask(() {
      _loadSettings();
      _loadBooks();
      _loadGroups();
    });
    return const BookshelfState();
  }

  /// 私密标记快照 → 书架状态（保持不可变替换）
  void _applyPrivacySnapshot(PrivacyContentSnapshot snapshot) {
    state = state.copyWith(
      privateBookUrls: snapshot.privateBookUrls,
      privateGroupIds: snapshot.privateGroupIds,
      privacyLoaded: snapshot.loaded,
    );
  }

  /// 加载持久化的书架偏好设置（标签内容三键）
  // [红线清理 2.0.260 | 台账 1-3] 统计行/最近阅读行移除后，偏好仅剩布局
  // [批35] 标签内容三键：键名对齐参考版标签内容对话框
  // [设置批6a-1] 布局/显示标签总开关等迁至 BookshelfSettingsNotifier；
  // 本通知器只保留不属于参考版 BookshelfSettings 的我方标签内容扩展。
  Future<void> _loadSettings() async {
    final results = await Future.wait<Object>([
      _settings.getBookshelfShowCustomTags(),
      _settings.getBookshelfShowSourceTags(),
      _settings.getBookshelfShowWordCount(),
    ]);
    state = state.copyWith(
      showCustomTags: results[0] as bool,
      showSourceTags: results[1] as bool,
      showWordCount: results[2] as bool,
    );
  }

  /// 调用 Rust API 获取书籍列表
  ///
  /// Notifier 不做任何数据处理，Rust 负责排序/过滤
  ///
  /// [批9c] 先等私密标记就绪再发布书籍：避免首帧把私密书按公开卡片渲染
  /// 一次再切锁定（闪露）。标记加载失败按空快照继续（fail-open）。
  Future<void> _loadBooks() async {
    state = state.copyWith(isLoading: true, error: null);
    PrivacyContentSnapshot privacy = PrivacyContentSnapshot.empty;
    try {
      privacy = await ref.read(privacyContentProvider.notifier).ensureLoaded();
    } catch (e) {
      debugPrint('[书架] 私密标记加载失败（按无标记继续）：$e');
    }
    try {
      final api = ref.read(bookApiProvider);
      final books = await api.getBooks();
      state = state.copyWith(
        books: books,
        isLoading: false,
        privateBookUrls: privacy.privateBookUrls,
        privateGroupIds: privacy.privateGroupIds,
        privacyLoaded: privacy.loaded,
      );
      // [P4-2b V4] 书籍就绪后重推视频聚合分组（对齐原版 IdVideo 动态显隐）
      _applyVideoGroup();
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 刷新书架
  ///
  /// [批9c] 先刷新私密标记，保证批量设私密/分组开关后列表与计数立即一致。
  Future<void> refresh() async {
    await ref.read(privacyContentProvider.notifier).refresh();
    await Future.wait([_loadBooks(), _loadGroups()]);
  }

  /// [队列⑫ P3 | 2026-09-22] 从阅读器/详情页返回书架后的单本定向刷新
  ///
  /// 书架页常驻（_KeepAlivePage），开书返回时无刷新钩子——内存态 Book 进度
  /// 滞留（刚读完的书仍显示旧进度/无进度行）。本方法仅重新拉取**受影响
  /// 的那本书**的最新进度写回内存（getBook 单本读取），不做全量
  /// 列表/分组重拉、不触发 isLoading 骨架、不改渲染逻辑。
  ///
  /// 若该书已不在数据源（如阅读期间从详情页移除出书架），回退全量
  /// [refresh] 保持列表一致。
  Future<void> refreshBook(String bookUrl) async {
    try {
      final api = ref.read(bookApiProvider);
      final book = await api.getBook(bookUrl);
      if (book == null) {
        await refresh();
        return;
      }
      state = state.copyWith(
        books: [
          for (final b in state.books)
            if (b.bookUrl == bookUrl) book else b,
        ],
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 加载书籍分组（对标原版 BookshelfFragment1.initBookGroupData）
  Future<void> _loadGroups() async {
    try {
      final api = ref.read(bookApiProvider);
      final groups = await api.getBookGroups();
      final visible = groups.where((g) => g.show).toList()
        ..sort((a, b) => a.order.compareTo(b.order));
      // 对标原版 upGroup：始终保证「全部」组存在并置顶；
      // 无自定义分组时仅单一「全部」组（此时 UI 不显示 TabBar）
      // 合成组 order=-10 对齐原版种子（AppDatabase.kt:206-208），确保早于
      // 视频组（order=-5，AppDatabase.kt:241-244）与自定义组（order≥0）
      final allGroup = const BookGroup(
        groupId: BookGroupId.all,
        groupName: '全部',
        order: -10,
      );
      final hasAll = visible.any((g) => g.groupId == BookGroupId.all);
      final list = hasAll ? visible : [allGroup, ...visible];
      final lastIndex = await _settings.getBookshelfTabPosition();
      state = state.copyWith(
        groups: list,
        selectedGroupIndex: lastIndex.clamp(0, list.length - 1),
      );
      // [P4-2b V4] 分组就绪后重推视频聚合分组（books 可能已先于 groups 加载）
      _applyVideoGroup();
    } catch (e) {
      // 分组加载失败不阻断书架展示
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// [P4-2b V4] 重推视频聚合分组（对齐原版 IdVideo 动态显隐语义）
  ///
  /// 原版依据：
  /// - `BookGroup.kt:39` `IdVideo = -6`；`AppDatabase.kt:241-244` 种子「视频」组
  ///   （order=-5, show=1）
  /// - `BookGroupDao.kt:36` show 查询：视频组仅当存在视频书时出现在分组列表
  ///   （`groupId = -6 and exists (select 1 from books where type & video > 0)`）
  ///
  /// 我方 `book_groups` 表无视频组行（Rust 侧无种子，DB 中 -6 行仅可能来自
  /// 未来种子迁移），故在数据层合成：有视频书（`bookType & BookType.video`）
  /// 且 groups 尚无 -6 组 → 补「视频」组；无视频书但存在 -6 组 → 移除（空组
  /// 不展示，对齐原版）。幂等：状态与条件一致时不写 state。
  ///
  /// 组内书籍过滤由 `currentGroupBooks` 既有 [BookGroupId.video] 分支承担
  /// （bookshelf_state.dart，`type & video != 0`，对齐原版 isVideo 判定）。
  void _applyVideoGroup() {
    final groups = state.groups;
    final hasVideoBook = state.books.any(
      (b) => (b.bookType & BookType.video) != 0,
    );
    final hasVideoGroup = groups.any((g) => g.groupId == BookGroupId.video);
    if (hasVideoBook == hasVideoGroup) return;

    // 组列表变化后按 groupId 保持当前选中 Tab 不动（防插入/移除导致索引
    // 错位跳组）；当前组已不在新列表时回退「全部」组
    final previousGroupId = state.selectedGroup?.groupId ?? BookGroupId.all;
    final List<BookGroup> next;
    if (hasVideoBook) {
      // 合成组对齐原版种子：order=-5、show=1（AppDatabase.kt:241-244）
      next = [
        ...groups,
        const BookGroup(groupId: BookGroupId.video, groupName: '视频', order: -5),
      ]..sort((a, b) => a.order.compareTo(b.order));
    } else {
      // 当前体系 DB 无 -6 行，列表中 -6 组必为合成组（见方法注释）
      next = groups.where((g) => g.groupId != BookGroupId.video).toList();
    }
    var index = next.indexWhere((g) => g.groupId == previousGroupId);
    if (index < 0) {
      index = next.indexWhere((g) => g.groupId == BookGroupId.all);
      if (index < 0) index = 0;
    }
    state = state.copyWith(groups: next, selectedGroupIndex: index);
  }

  /// 切换分组 Tab（对标原版 onTabSelected → AppConfig.saveTabPosition）
  Future<void> selectGroup(int index) async {
    if (index < 0 || index >= state.groups.length) return;
    state = state.copyWith(selectedGroupIndex: index);
    await _settings.setBookshelfTabPosition(index);
  }

  /// 添加书籍到书架
  ///
  /// [F1-hunt F3 | 2026-09-24] 返回值携带结果：true = 写库成功且 UI 列表
  /// 已同步；false = 写库失败（error 已写入 state.error）。修复前异常被
  /// 吞掉后正常返回，调用方无法区分成功/失败，详情页无条件提示「已加入
  /// 书架」（假成功；书架非空时 state.error 又不渲染 → 完全静默）
  Future<bool> addBook(Book book) async {
    try {
      final api = ref.read(bookApiProvider);
      await api.addBook(book);
      state = state.copyWith(books: [...state.books, book]);
      // [P4-2b V4] 新加入的视频书触发视频聚合分组出现
      _applyVideoGroup();
      return true;
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      return false;
    }
  }

  /// 导入本地书籍到书架（EPUB/TXT/MOBI/PDF/UMD）
  ///
  /// 成功后将返回的书籍加入列表；
  /// 失败时异常向上抛出，由 UI 层负责提示。
  ///
  /// [批40] 导入成功后按「导入后自动上传本地书」开关异步补传 WebDAV
  /// （对齐原版 `LocalBook.autoUploadToWebDav`）：不 await、不阻断导入，
  /// 失败仅日志（服务内部兜底）。
  Future<Book> importLocalBook(String filePath) async {
    final api = ref.read(bookApiProvider);
    final book = await api.importLocalBook(filePath);
    state = state.copyWith(
      books: [...state.books.where((b) => b.bookUrl != book.bookUrl), book],
    );
    unawaited(_autoUploadImportedBook(book));
    return book;
  }

  /// 导入后自动上传书籍文件到 WebDAV（批40）
  ///
  /// 开关/配置判定与失败兜底都在 [WebDavBookUploadService] 内；此处仅
  /// 注入当前 BookApi，异常一律吞掉（不得影响导入结果）。
  Future<void> _autoUploadImportedBook(Book book) async {
    try {
      await WebDavBookUploadService(
        api: ref.read(bookApiProvider),
        settings: _settings,
      ).autoUploadAfterImport(book);
    } catch (e) {
      // 服务内部已捕获；此处为最后一道防线（如 ref 已销毁）
      debugPrint('[BookshelfNotifier] 导入后自动上传异常: $e');
    }
  }

  /// 删除书籍：调用 Rust API 后同步本地 UI 状态
  ///
  /// 注意：where 过滤是「UI 状态同步」而非「业务逻辑」
  /// [F1-hunt F3 | 2026-09-24] 同 addBook：返回写库结果，失败时 UI 列表
  /// 不变、error 置位，调用方据此提示失败（不再无条件「已移出书架」）
  Future<bool> removeBook(String bookUrl) async {
    try {
      final api = ref.read(bookApiProvider);
      await api.deleteBook(bookUrl);
      state = state.copyWith(
        books: state.books.where((b) => b.bookUrl != bookUrl).toList(),
      );
      // [P4-2b V4] 删尽视频书后视频聚合分组消失（对齐原版 show 查询动态隐藏）
      _applyVideoGroup();
      return true;
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      return false;
    }
  }

  /// 批量设置书籍私密标记（选择模式顶栏锁图标）
  ///
  /// 返回 Rust 实际更新行数；成功后刷新私密标记与书籍列表（`isPrivate`
  /// 字段、公开书架过滤、分组计数同步），失败异常向上抛由 UI 提示。
  Future<int> setBooksPrivate(List<String> bookUrls, bool isPrivate) async {
    if (bookUrls.isEmpty) return 0;
    final api = ref.read(bookApiProvider);
    final updated = await api.setBooksPrivate(bookUrls, isPrivate);
    await ref.read(privacyContentProvider.notifier).refresh();
    await _loadBooks();
    return updated;
  }

  // ===== 展示层状态切换（不涉及数据内容变更） =====

  /// [批35] 标签内容三项（对齐参考版 `BookshelfTagContentDialog` 确认语义：
  /// 一次性写回三项并持久化）
  Future<void> setTagContent({
    required bool showCustomTags,
    required bool showSourceTags,
    required bool showWordCount,
  }) async {
    state = state.copyWith(
      showCustomTags: showCustomTags,
      showSourceTags: showSourceTags,
      showWordCount: showWordCount,
    );
    await Future.wait([
      _settings.setBookshelfShowCustomTags(showCustomTags),
      _settings.setBookshelfShowSourceTags(showSourceTags),
      _settings.setBookshelfShowWordCount(showWordCount),
    ]);
  }

  /// 设置分组模式
  // [UI_SYNC_REFACTOR T3] 批量选择（对齐参考 SelectionBottomBar 态）
  void toggleBatchMode() {
    state = state.copyWith(isBatchMode: !state.isBatchMode, selectedUrls: {});
  }

  void toggleSelect(String bookUrl) {
    final urls = {...state.selectedUrls};
    urls.contains(bookUrl) ? urls.remove(bookUrl) : urls.add(bookUrl);
    state = state.copyWith(selectedUrls: urls);
  }

  void selectAll() {
    state = state.copyWith(
      selectedUrls: {for (final b in state.currentGroupBooks) b.bookUrl},
    );
  }

  void invertSelection() {
    final all = {for (final b in state.currentGroupBooks) b.bookUrl};
    state = state.copyWith(selectedUrls: all.difference(state.selectedUrls));
  }

  void clearSelection() {
    state = state.copyWith(selectedUrls: {});
  }

  /// 批量删除已勾选书籍（选择模式顶栏「删除」动作）
  ///
  /// [UI-fix 2.0.258] 原逐本 `deleteBook` 方案收敛为单次批量调用。
  /// [批35] 改走 `BookApi.deleteBooks(urls, deleteOriginal)`：`deleteOriginal`
  /// 为真时由 Rust 仅对本地/WebDAV 书删除原文件；文件失败不阻断记录删除。
  /// [批35b P3-5] 返回 [DeleteBooksResult]：成功提示用 Rust 给出的实际删除
  /// 数/已不存在数，而不是选中数（并发删除/重复请求不虚增）。
  ///
  /// 成功后先同步 UI 列表再重拉数据源保证与 Rust 一致，最后清空选中并退出
  /// 选择模式（对标原版批量操作完成即退出选择态）；记录删除失败置
  /// `state.error` 后向上抛出，由调用方提示（不静默假装成功）。
  Future<DeleteBooksResult> deleteSelectedBooks({
    bool deleteOriginal = false,
  }) async {
    final urls = state.selectedUrls.toList();
    if (urls.isEmpty) {
      return const DeleteBooksResult(deleted: 0, missing: 0);
    }
    try {
      final api = ref.read(bookApiProvider);
      final result = await api.deleteBooks(
        urls,
        deleteOriginal: deleteOriginal,
      );
      state = state.copyWith(
        books: state.books.where((b) => !urls.contains(b.bookUrl)).toList(),
        isBatchMode: false,
        selectedUrls: {},
      );
      await _loadBooks();
      return result;
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      rethrow;
    }
  }

  void setGroupMode(GroupMode mode) {
    state = state.copyWith(groupMode: mode);
  }

  /// 清除错误状态
  void clearError() {
    state = state.copyWith(error: null);
  }

  /// 保存拖拽后的手动排序（仅「手动排序」模式可触发）
  ///
  /// [设置批6a-1] 对齐参考版 `saveBookOrder`：升序按视觉顺序写
  /// `order = index`，降序写 `order = n - index`（刷新后仍保持同一
  /// 视觉顺序）。入参为**当前排序后的可见列表**，避免用原始
  /// `state.books` 顺序覆盖用户拖动结果。
  Future<void> saveBookOrder(
    List<Book> reordered, {
    bool descending = false,
  }) async {
    if (reordered.isEmpty) return;
    final total = reordered.length;
    final byUrl = <String, Book>{
      for (var i = 0; i < reordered.length; i++)
        reordered[i].bookUrl: reordered[i].copyWith(
          order: descending ? total - i : i,
        ),
    };
    state = state.copyWith(
      books: [for (final book in state.books) byUrl[book.bookUrl] ?? book],
    );
    try {
      await ref.read(bookApiProvider).reorderBooks([
        for (final entry in byUrl.entries)
          {'bookUrl': entry.key, 'order': entry.value.order},
      ]);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      await _loadBooks();
    }
  }

  // ===== 内部工具 =====

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 书架 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(bookshelfNotifierProvider);
/// ref.read(bookshelfNotifierProvider.notifier).refresh();
/// ```
final bookshelfNotifierProvider =
    NotifierProvider<BookshelfNotifier, BookshelfState>(BookshelfNotifier.new);
