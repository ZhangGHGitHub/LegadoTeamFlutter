import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

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
/// 书架书籍（Book）消费合成脱敏样例资产
///   assets/mock_data/bookshelf_sample.json（USE_MOCK 数据源）：
///   结构严格对齐 flutter_legado/lib/src/models/book.dart 与
///   docs/API_CONTRACT.md §2.2（键名/类型与原版书架导出一致），
///   内容已全部替换为虚构数据（书名/作者/URL 均为示例值，http(s) 主机名
///   仅 example.com，不指向任何真实站点）；
///   来源与脱敏口径见 assets/mock_data/README.md。
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
    // Mock 模式无需初始化；确保书架样例资产已加载
    // （MockBookApi 构造器保持同步，资产读取为异步，经守卫惰性完成）
    await _ensureBooksLoaded();
  }

  @override
  Future<String> getVersion() async => 'mock-1.0.0';
}
