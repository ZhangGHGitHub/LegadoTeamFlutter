/// flutter_rust_bridge 生成代码的导出入口
///
/// 重新导出生成的 RustLib 和所有桥接函数。
/// codegen 运行后自动生成，请勿手动编辑。
library;

export 'frb_generated.dart' show RustLib;
export 'ffi/ffi.dart';
export 'api/book_import.dart';
export 'api/reader.dart';
export 'api/rss.dart';
export 'api/search.dart';

// lib.dart 中的 Book/BookChapter 等类型与 models/ 中的同名类冲突，
// 使用时需通过 import prefix 区分
