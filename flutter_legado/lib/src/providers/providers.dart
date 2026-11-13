import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/pref_keys.dart';
import '../services/book_api.dart';
import '../services/mock_book_api.dart';
import '../services/rust_api.dart';
import '../services/settings_service.dart';
import '../services/web_service_address_resolver.dart';

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

/// 全局「默认启用替换净化」开关（批7a 闭环）
///
/// 与书级 `ReadConfig.useReplaceRule` 配合决定阅读链是否应用替换规则，
/// 对齐 Rust `reader.rs::get_replace_enable_default`：配置缺省/非法 → true，
/// 显式 `"false"`/`"0"` → false。SharedPreferences 为 UI 真源，Rust caches
/// `config:replaceEnableDefault` 由设置页与启动同步写入。
///
/// USE_MOCK 模式无 Rust DB，直接返回 true（与 MockBookApi 行为一致）。
final replaceEnableDefaultProvider = FutureProvider<bool>((ref) async {
  const useMock = bool.fromEnvironment('USE_MOCK', defaultValue: false);
  if (useMock) return true;
  return ref.read(settingsProvider).getBoolPref(
        PrefKeys.replaceEnableDefault,
        defaultValue: true,
      );
});

/// 高亮规则修订号（批34）
///
/// 规则列表加载/保存/删除成功后自增；阅读页 watch 该值并在变化后失效
/// 正文匹配缓存（缓存键含修订号），保证编辑规则后重新匹配。
/// 外部导入/备份恢复不经规则页的路径不会自增——切换章节或重开书后生效
/// （登记为 MVP 限制）。
final highlightRulesRevisionProvider = StateProvider<int>((ref) => 0);

/// 书签标记修订号（批7b-2a）
///
/// 标记保存/启停/删除成功后自增；7b-2b 正文渲染 watch 该值失效锚点命中缓存。
/// 本批先建立，TOC 笔记列表直接 watch `bookMarkingNotifierProvider` 状态。
final bookMarkingsRevisionProvider = StateProvider<int>((ref) => 0);

/// 手动高亮修订号（highlights 表正文渲染）
///
/// 阅读器「保存高亮」成功后自增；阅读页 watch 该值并重新拉取当前章
/// `highlightListByChapter`，使用户保存后立即在正文看到高亮（此前该表
/// 零渲染调用方，保存成功但正文无任何变化）。外部导入/备份恢复不走该
/// 信号，切换章节或重开书后生效（与高亮规则修订号同口径）。
final bookHighlightsRevisionProvider = StateProvider<int>((ref) => 0);

/// Web 服务可访问地址解析 Provider（M1 我的页）
///
/// 默认真实网卡枚举（[LanWebServiceAddressResolver]，局域网 IPv4 优先、
/// 失败回落回环）；widget 测试注入固定 IP 实现，避免 FakeAsync 下
/// `NetworkInterface.list` 不完成导致地址/开关状态悬挂。
final webServiceAddressResolverProvider = Provider<WebServiceAddressResolver>(
  (ref) => const LanWebServiceAddressResolver(),
);
