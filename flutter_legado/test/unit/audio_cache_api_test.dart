// B1 音频章节文件缓存数据链定向测试（契约 §2.47）
//
// 覆盖 Dart 侧可验证面：
// 1. BookApi 签名面（编译期形状 + Mock 走接口调用）
// 2. MockBookApi 空态语义（无写入面 → 查询 false / 列举空 / 清理 0，幂等）
// 3. RustApi FFI 未初始化（库不可用）时四方法全降级、不抛异常
//
// 键规则向量 / 命中三条件（.complete + size>0 + key 匹配）/ 五段式正则解析 /
// 清理幂等与书级隔离由 Rust 单测覆盖（键计算在 Rust 侧，见
// rust/legado-ffi/src/api/audio_cache_api.rs#[cfg(test)]）。
//
// [B1 | 2026-10-04] 新增（契约 §2.47 audio_cache FFI）。

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/rust_api.dart';

void main() {
  // MockBookApi 构造经 _initMockData 惰性读取样例资产（rootBundle）
  TestWidgetsFlutterBinding.ensureInitialized();

  const bookUrl = 'mock://book/audio-1';
  const chapterUrl = 'https://example.com/audio/ch1.mp3';
  const chapterTitle = '第一章';

  group('MockBookApi 音频缓存空态（无写入面，契约 §2.47）', () {
    late MockBookApi api;
    setUp(() => api = MockBookApi());

    test('audioCacheQuery 恒 false（按未缓存降级），空 chapterUrl 也不抛', () async {
      expect(
        await api.audioCacheQuery(
          bookUrl: bookUrl,
          chapterIndex: 0,
          chapterUrl: chapterUrl,
          chapterTitle: chapterTitle,
        ),
        isFalse,
      );
      // 原版 ifBlank 语义：chapterUrl 为空退回标题；Mock 无缓存仍恒 false
      expect(
        await api.audioCacheQuery(
          bookUrl: bookUrl,
          chapterIndex: 0,
          chapterUrl: '',
          chapterTitle: chapterTitle,
        ),
        isFalse,
      );
    });

    test('audioCacheList 恒空数组（无已缓存章节）', () async {
      expect(await api.audioCacheList(bookUrl: bookUrl), isEmpty);
    });

    test('清理幂等：单章/整书首调与重复调用均返回 0', () async {
      expect(
        await api.audioCacheClearChapter(
          bookUrl: bookUrl,
          chapterIndex: 0,
          chapterUrl: chapterUrl,
          chapterTitle: chapterTitle,
        ),
        0,
      );
      expect(
        await api.audioCacheClearChapter(
          bookUrl: bookUrl,
          chapterIndex: 0,
          chapterUrl: chapterUrl,
          chapterTitle: chapterTitle,
        ),
        0,
      );
      expect(await api.audioCacheClearBook(bookUrl: bookUrl), 0);
      expect(await api.audioCacheClearBook(bookUrl: bookUrl), 0);
    });
  });

  group('BookApi 接口面（编译期签名形状 + 走接口调用）', () {
    test('Mock 实现可经 BookApi 接口调用四方法且类型正确', () async {
      final BookApi api = MockBookApi();
      final bool hit = await api.audioCacheQuery(
        bookUrl: bookUrl,
        chapterIndex: 0,
        chapterUrl: chapterUrl,
        chapterTitle: chapterTitle,
      );
      final List<int> indexes = await api.audioCacheList(bookUrl: bookUrl);
      final int clearedChapter = await api.audioCacheClearChapter(
        bookUrl: bookUrl,
        chapterIndex: 0,
        chapterUrl: chapterUrl,
        chapterTitle: chapterTitle,
      );
      final int clearedBook = await api.audioCacheClearBook(bookUrl: bookUrl);
      expect(hit, isFalse);
      expect(indexes, isEmpty);
      expect(clearedChapter, 0);
      expect(clearedBook, 0);
    });
  });

  group('RustApi FFI 不可用降级（契约 §2.47 失败不抛异常）', () {
    late RustApi api;
    setUp(() => api = RustApi());

    test('未初始化时四方法全部降级为 false/空/0，不抛 FFI 异常', () async {
      expect(
        await api.audioCacheQuery(
          bookUrl: bookUrl,
          chapterIndex: 0,
          chapterUrl: chapterUrl,
          chapterTitle: chapterTitle,
        ),
        isFalse,
      );
      expect(await api.audioCacheList(bookUrl: bookUrl), isEmpty);
      expect(
        await api.audioCacheClearChapter(
          bookUrl: bookUrl,
          chapterIndex: 0,
          chapterUrl: chapterUrl,
          chapterTitle: chapterTitle,
        ),
        0,
      );
      expect(await api.audioCacheClearBook(bookUrl: bookUrl), 0);
    });
  });
}
