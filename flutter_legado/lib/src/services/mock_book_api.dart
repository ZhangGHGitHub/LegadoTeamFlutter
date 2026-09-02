import 'dart:convert';

import '../models/models.dart';
import 'book_api.dart';

part 'mock_book_api_store.part.dart';
part 'mock_book_api_sources.part.dart';
part 'mock_book_api_search_rss.part.dart';
part 'mock_book_api_reader_data.part.dart';
part 'mock_book_api_discovery_cache.part.dart';
part 'mock_book_api_media_format.part.dart';
part 'mock_book_api_sync_tools.part.dart';
part 'mock_book_api_content_ext.part.dart';

// ↑ 分域 part 文件（体检 §三.16 超长文件拆分）：MockBookApi 按域拆为 mixin 组合，
// 各 mixin 方法原样搬移、合集实现 BookApi，零行为变更。

/// Mock 书籍 API 实现
///
/// 纯 Dart 实现，无需 Rust DLL，供 UI 轨开发使用。
/// 所有数据存储在内存中，会话内可读写。
/// 用法：`flutter run -d windows --dart-define=USE_MOCK=true`
///
/// ─── Mock 数据来源说明（REFACTORING_PLAN §6.4）───
///
/// 书源（BookSource）样本取自原 Android 端内置默认数据：
///   app/src/main/assets/defaultData/bookSources.json
///   （消消乐听书源，bookSourceType=1 音频源，含完整 ruleSearch/ruleExplore/ruleToc）
///
/// RSS 源（RssSource）样本取自原 Android 端内置默认数据：
///   app/src/main/assets/defaultData/rssSources.json
///   （使用说明 / 小说拾遗 / Meow云 / 烏雲净化，均为 legado 官方内置源）
///
/// HTTP TTS 引擎样本取自原 Android 端内置默认数据：
///   app/src/main/assets/defaultData/httpTTS.json
///   （百度 TTS / 阿里云语音，含真实 url 模板与 contentType）
///
/// 书架书籍（Book）为调试用占位数据，字段结构严格对齐
///   flutter_legado/lib/src/models/book.dart 与 docs/API_CONTRACT.md §2.2，
///   书名/作者沿用经典网文以便 UI 截图对比；
///   TODO(§6.4): 后续应从原 Android 端真实书架导出 JSON 替换。
class MockBookApi
    with MockBookApiStore,
        MockBookApiSources,
        MockBookApiSearchRss,
        MockBookApiReaderData,
        MockBookApiDiscoveryCache,
        MockBookApiMediaFormat,
        MockBookApiSyncTools,
        MockBookApiContentExt
    implements BookApi {
  MockBookApi() {
    _initMockData();
  }

  // ========== 初始化/版本 ==========

  @override
  Future<void> initialize() async {
    // Mock 模式无需初始化
  }

  @override
  Future<String> getVersion() async => 'mock-1.0.0';
}
