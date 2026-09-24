import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 本地书籍持久化存储（[iOS 视角F C1]）。
///
/// 背景：iOS 的 file_picker Import 模式会把所选文件**移动**到
/// `NSTemporaryDirectory()`（tmp）。tmp 会被系统清理，且 App 重签名 /
/// 重装后容器 UUID 变化 → 以「tmp 绝对路径」作为 `book_url` 主键的本地书
/// 全部失效。
///
/// 本服务把本地书文件**拷贝**到「持久」沙盒目录 `Documents/books/`，并向
/// DB 写入「可迁移标识」= 相对 `Documents` 的路径（形如 `books/<name>`，
/// 正斜杠）。Rust 读侧（`db_state::resolve_local_book_path`）以「当前容器
/// 的 Documents 目录」为基拼接该标识重建真实路径，从而跨重签名 / 重装仍
/// 可读。tmp 永不作为持久引用。
///
/// 兼容：非 iOS 平台 / 存量本地书仍以**绝对路径**作为 `book_url`，读侧
/// resolver 对绝对路径原样透传，行为不变（升级不破坏既有书）。
class LocalBookStore {
  LocalBookStore._();

  /// 本地书持久子目录名（相对应用 `Documents` 目录）。
  static const String subDir = 'books';

  /// 测试 seam：应用 `Documents` 目录获取（默认 path_provider）。
  /// 测试可覆盖为返回临时目录，避免触碰真实沙盒。
  static Future<Directory> Function() documentsDir =
      getApplicationDocumentsDirectory;

  /// 缓存的 `Documents` 绝对路径（首次 [store]/[warmWith] 时填充），
  /// 供同步 [resolveSync] 使用（读取侧标签等无 async 上下文的场景）。
  static String? _docsPath;

  /// 预热 [resolveSync] 的基目录缓存（App 启动时由 rust_api 初始化调用，
  /// 复用其已获取的 `Documents` 目录，避免额外 IO）。
  static void warmWith(Directory docs) {
    _docsPath = docs.absolute.path;
  }

  /// 把 [sourcePath] 拷入 `Documents/books/`，返回「相对 Documents 的
  /// 可迁移标识」（`books/<name>`，正斜杠）。
  ///
  /// - 幂等：若 [sourcePath] 已在 `Documents/books/` 内，直接返回其相对
  ///   标识，不做自拷贝。
  /// - 去重：目标文件名冲突时追加 `_<n>` 后缀，不覆盖既有文件。
  /// - 拷贝失败（源不存在 / IO 错误）抛异常，由调用方决定是否回退。
  static Future<String> store(String sourcePath) async {
    final docs = await documentsDir();
    final docsPath = docs.absolute.path;
    _docsPath = docsPath;

    final sep = Platform.pathSeparator;
    final booksDir = '$docsPath$sep$subDir';
    await Directory(booksDir).create(recursive: true);

    final src = File(sourcePath).absolute.path;
    final prefix = '$booksDir$sep';
    // 幂等：源文件已位于 Documents/books 内 → 直接返回相对标识
    if (src.startsWith(prefix)) {
      return '$subDir/${src.substring(prefix.length).replaceAll(sep, '/')}';
    }

    final name = _baseName(src);
    final baseNoExt = _baseNoExt(name);
    final ext = _ext(name);
    var candidate = name;
    var n = 1;
    while (File('$booksDir$sep$candidate').existsSync()) {
      // 注意：显式字符串拼接，避免 `$baseNoExt_` 被解析成未定义标识符
      candidate = '$baseNoExt' '_$n$ext';
      n++;
    }
    final target = '$booksDir$sep$candidate';
    await File(src).copy(target);
    // 返回相对 Documents 的标识（正斜杠，供 Rust 端拼接）
    return '$subDir/$candidate';
  }

  /// 同步：把 `book_url` 解析为真实文件路径（Dart 读侧消费点用）。
  ///
  /// - Web URL（含 `://`）/ 绝对路径 → 原样返回（兼容在线书与存量/非 iOS）。
  /// - 相对可迁移标识（`books/x.epub`）→ 拼接到当前 `Documents` 目录。
  /// - 基目录未缓存（未初始化 / 未预热）时原样返回，调用方按「文件不存在」
  ///   优雅降级（与既有 try/catch 行为一致，不崩溃）。
  static String resolveSync(String bookUrl) {
    if (bookUrl.contains('://')) return bookUrl;
    if (File(bookUrl).isAbsolute) return bookUrl;
    final docs = _docsPath;
    if (docs == null) return bookUrl;
    return '$docs${Platform.pathSeparator}${bookUrl.replaceAll('/', Platform.pathSeparator)}';
  }

  /// 取路径末段（不引入 package:path，避免新增直接依赖）。
  static String _baseName(String p) {
    final parts = p.split(Platform.pathSeparator);
    return parts.isEmpty ? p : parts.last;
  }

  /// 去扩展名的基名（无扩展名时原样返回）。
  static String _baseNoExt(String name) {
    final i = name.lastIndexOf('.');
    return i <= 0 ? name : name.substring(0, i);
  }

  /// 扩展名（含点；无扩展名时返回空串）。
  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    return i <= 0 ? '' : name.substring(i);
  }
}
