import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/book_api.dart';
import '../services/mock_book_api.dart';
import '../services/rust_api.dart';

/// BookApi 全局 Provider（Riverpod 注入层）
///
/// 启动时根据 --dart-define=USE_MOCK 决定注入哪个实现：
/// - USE_MOCK=true → MockBookApi（纯 Dart 假数据，UI 轨独立开发用）
/// - 默认 → RustApi（真实 FFI 实现，需 Rust DLL）
///
/// 使用方式：在 Notifier 中通过 `ref.read(bookApiProvider)` 获取实例。
final bookApiProvider = Provider<BookApi>((ref) {
  const useMock = bool.fromEnvironment('USE_MOCK', defaultValue: false);
  return useMock ? MockBookApi() : RustApi();
});
