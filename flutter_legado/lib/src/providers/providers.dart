import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/book_api.dart';
import '../services/mock_book_api.dart';
import '../services/rust_api.dart';
import '../services/settings_service.dart';

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

/// SettingsService 全局 Provider（F3-18：统一注入，禁止 UI 直接 new）
final settingsProvider = Provider<SettingsService>((ref) => SettingsService());

/// 高亮规则修订号（批34）
///
/// 规则列表加载/保存/删除成功后自增；阅读页 watch 该值并在变化后失效
/// 正文匹配缓存（缓存键含修订号），保证编辑规则后重新匹配。
/// 外部导入/备份恢复不经规则页的路径不会自增——切换章节或重开书后生效
/// （登记为 MVP 限制）。
final highlightRulesRevisionProvider = StateProvider<int>((ref) => 0);
