/// 单元测试 Mock 定义
///
/// 使用 mocktail 生成 RustApi / AudioService / http.Client 的 mock 实例，
/// 供 Providers / Services 层测试使用。
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_legado/src/services/audio_service.dart';
import 'package:flutter_legado/src/models/models.dart';

/// RustApi 的 mock 实现
class MockRustApi extends Mock implements RustApi {}

/// AudioService 的 mock 实现
class MockAudioService extends Mock implements AudioService {}

/// http.Client 的 mock 实现
class MockHttpClient extends Mock implements http.Client {}

/// http.Response 的 mock 实现
class MockHttpResponse extends Mock implements http.Response {}

/// Book 的 Fake 实现（用于 registerFallbackValue）
class FakeBook extends Fake implements Book {}

/// RssSource 的 Fake 实现
class FakeRssSource extends Fake implements RssSource {}

/// BookSource 的 Fake 实现
class FakeBookSource extends Fake implements BookSource {}

/// Bookmark 的 Fake 实现
class FakeBookmark extends Fake implements Bookmark {}

/// ReplaceRule 的 Fake 实现
class FakeReplaceRule extends Fake implements ReplaceRule {}

/// Uri 的 Fake 实现
class FakeUri extends Fake implements Uri {}

/// 注册所有 fallback 值（在 setUpAll 中调用）
void registerFallbacks() {
  registerFallbackValue(FakeBook());
  registerFallbackValue(FakeRssSource());
  registerFallbackValue(FakeBookSource());
  registerFallbackValue(FakeBookmark());
  registerFallbackValue(FakeReplaceRule());
  registerFallbackValue(FakeUri());
}
