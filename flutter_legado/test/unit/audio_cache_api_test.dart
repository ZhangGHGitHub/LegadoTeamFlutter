// B1/B2 音频章节文件缓存数据链定向测试（契约 §2.47 读面 + §2.48 写入面）
//
// 覆盖 Dart 侧可验证面：
// 1. BookApi 签名面（编译期形状 + Mock 走接口调用，含 §2.48 两方法）
// 2. MockBookApi 内存态语义（空态查询 false / 列举空 / 清理 0，幂等；
//    download 后查询 true / 列举含下标 / 重复 download 为 already_cached）
// 3. RustApi FFI 未初始化（库不可用）时读面四方法降级不抛异常；
//    写入面两方法**上抛不降级**（契约 §2.48 有意区别）
//
// 键规则向量 / 命中三条件（.complete + size>0 + key 匹配）/ 五段式正则解析 /
// 清理幂等与书级隔离 / 下载安装八步（本地回环服务器 + DB 夹具，不联网）由
// Rust 单测覆盖（键计算与写入在 Rust 侧，见
// rust/legado-ffi/src/api/audio_cache_api.rs#[cfg(test)]）。
//
// [B1 | 2026-10-04] 新增（契约 §2.47 audio_cache FFI）。
// [B2 | 2026-10-03] 扩展（契约 §2.48 写入面两方法）。

import 'dart:convert';

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
  const playUrl = 'https://cdn.example.com/audio/ch1.mp3';

  group('MockBookApi 音频缓存（内存态，契约 §2.47/§2.48）', () {
    late MockBookApi api;
    setUp(() => api = MockBookApi());

    test('空态：audioCacheQuery 恒 false，空 chapterUrl 也不抛', () async {
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

    test('空态：audioCacheList 空数组；清理幂等返回 0', () async {
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
      expect(await api.audioCacheClearBook(bookUrl: bookUrl), 0);
    });

    test('download 幂等：installed → already_cached；读面随写入态一致', () async {
      final first = await api.audioCacheDownload(
        bookUrl: bookUrl,
        chapterIndex: 0,
        chapterUrl: chapterUrl,
        chapterTitle: chapterTitle,
        playUrl: playUrl,
      );
      expect(jsonDecode(first)['status'], 'installed');
      expect(jsonDecode(first)['extension'], 'mp3');
      expect(
        await api.audioCacheQuery(
          bookUrl: bookUrl,
          chapterIndex: 0,
          chapterUrl: chapterUrl,
          chapterTitle: chapterTitle,
        ),
        isTrue,
      );
      expect(await api.audioCacheList(bookUrl: bookUrl), <int>[0]);

      final second = await api.audioCacheDownload(
        bookUrl: bookUrl,
        chapterIndex: 0,
        chapterUrl: chapterUrl,
        chapterTitle: chapterTitle,
        playUrl: playUrl,
      );
      expect(jsonDecode(second)['status'], 'already_cached');

      // 清理 → 返回数据文件数 1，再清 0；读面回落 false/空
      expect(
        await api.audioCacheClearChapter(
          bookUrl: bookUrl,
          chapterIndex: 0,
          chapterUrl: chapterUrl,
          chapterTitle: chapterTitle,
        ),
        1,
      );
      expect(await api.audioCacheQuery(
        bookUrl: bookUrl,
        chapterIndex: 0,
        chapterUrl: chapterUrl,
        chapterTitle: chapterTitle,
      ), isFalse);
      expect(await api.audioCacheCancel(), isFalse, reason: 'mock 无在途下载');
    });
  });

  group('BookApi 接口面（编译期签名形状 + 走接口调用）', () {
    test('Mock 实现可经 BookApi 接口调用全部方法且类型正确', () async {
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
      final String downloadResult = await api.audioCacheDownload(
        bookUrl: bookUrl,
        chapterIndex: 0,
        chapterUrl: chapterUrl,
        chapterTitle: chapterTitle,
        playUrl: playUrl,
      );
      final bool cancelled = await api.audioCacheCancel();
      expect(hit, isFalse);
      expect(indexes, isEmpty);
      expect(clearedChapter, 0);
      expect(clearedBook, 0);
      expect(jsonDecode(downloadResult)['status'], 'installed');
      expect(cancelled, isFalse);
    });
  });

  group('RustApi FFI 不可用（读面降级 / 写入面上抛，契约 §2.47/§2.48）', () {
    late RustApi api;
    setUp(() => api = RustApi());

    test('读面四方法降级为 false/空/0，不抛 FFI 异常', () async {
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

    test('写入面两方法上抛不降级（有意区别于读面）', () async {
      await expectLater(
        Future<String>.sync(() => api.audioCacheDownload(
              bookUrl: bookUrl,
              chapterIndex: 0,
              chapterUrl: chapterUrl,
              chapterTitle: chapterTitle,
              playUrl: playUrl,
            )),
        throwsA(anything),
      );
      await expectLater(
        Future<bool>.sync(() => api.audioCacheCancel()),
        throwsA(anything),
      );
    });
  });
}
