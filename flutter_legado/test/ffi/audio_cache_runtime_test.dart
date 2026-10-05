/// B1/B2 音频章节文件缓存 Dart↔Rust 真实数据链运行时验证（契约 §2.47/§2.48）
///
/// 加载 rust/target/debug/legado_ffi.dll（解析策略对齐
/// ffi_stream_sink_runtime_test.dart），注入临时缓存根，按原版五段式命名
/// 手工构造缓存文件，经真实 FRB wire 验证：
///
/// - audioCacheQuery：命中三条件（key 匹配 + `.complete` 存在 + size>0）
/// - audioCacheList：已缓存章节下标升序
/// - audioCacheClearChapter / ClearBook：实际删除数（**仅数据文件，不计
///   `.complete` 标记**，契约 §2.47 口径修正）与幂等
/// - set_audio_cache_dir 注入目录生效
/// - chapterUrl 空白时退回 chapterTitle（原版 ifBlank 语义）
/// - B2 写入面 FFI 可达：audioCacheCancel 无在途 false；audioCacheDownload
///   失败上抛不降级（本运行时测试未注入 DB 书源上下文，走错误路径）
///
/// 键向量为硬编码固定输入（md5Encode16 逐字节口径已在 Rust 单测
/// rust/legado-ffi/src/api/audio_cache_api.rs 钉死）：
/// - bookUrl = "hello" → 书目录 book_bc4b2a76b9719d91
/// - chapterUrl = "hello" → key bc4b2a76b9719d91
/// - chapterTitle = "中文"（key 9fcdcb3a067903d8，用于 ifBlank 回退验证）
///
/// 写入面全链路（本地回环服务器 + DB 夹具）由 Rust 单测覆盖（不联网）。
/// 前置条件：先在 rust/ 下构建 DLL（cargo build -p legado-ffi --features quickjs）。
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_legado/src/bridge/ffi/ffi.dart' as bridge;
import 'package:flutter_legado/src/bridge/frb_generated.dart';
import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

/// 从 rust/target/debug 解析真实 DLL 路径（对齐 rust_api.dart 的搜索策略）
String _resolveDll() {
  const libName = 'legado_ffi.dll';
  final sep = Platform.pathSeparator;
  final candidates = <String>[
    // flutter test 的 Directory.current 即 flutter_legado/
    '${Directory.current.parent.path}${sep}rust${sep}target${sep}debug$sep$libName',
    '${Directory.current.path}$sep..${sep}rust${sep}target${sep}debug$sep$libName',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  throw StateError('未找到 legado_ffi.dll，请先在 rust/ 下构建');
}

/// 固定键向量（见文件头）
const String _kBookUrl = 'hello';
const String _kBookDirName = 'book_bc4b2a76b9719d91';
const String _kChapterUrl = 'hello';
const String _kKey16 = 'bc4b2a76b9719d91';
const String _kTitleKey16 = '9fcdcb3a067903d8';

void main() {
  // 该测试依赖 Windows 构建的 DLL 产物（rust/target/debug），
  // CI（ubuntu/macOS）无产物：注册阶段整体跳过（对齐
  // ffi_stream_sink_runtime_test.dart / cache_download_failed_chapters_
  // runtime_test.dart 的既有守卫——本文件 B1 批新增时漏抄，致 CI 红）
  if (!Platform.isWindows) {
    test("跳过音频缓存 FFI 运行时测试：需要 Windows DLL 产物（仅本机验证）", () {});
    return;
  }

  late Directory root;
  late RustApi api;

  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(_resolveDll()));
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('legado-audio-cache-rt-');
    await bridge.setAudioCacheDir(dir: root.path);
    api = RustApi();
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Directory bookDir() =>
      Directory('${root.path}${Platform.pathSeparator}$_kBookDirName');

  /// 写入一条五段式缓存文件（可选 `.complete` 标记）
  Future<void> writeCacheFile(String name, {required bool marker}) async {
    final dir = bookDir();
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final sep = Platform.pathSeparator;
    await File('${dir.path}$sep$name').writeAsBytes(List<int>.filled(8, 7));
    if (marker) {
      await File('${dir.path}$sep$name.complete').writeAsString('1\nx\nx');
    }
  }

  String dataName(int index, String key, String ext) =>
      '${index.toString().padLeft(5, '0')}_${key}_某章节_bc964d2a0c9c9bf9_9f8e7d6c.$ext';

  test('查询命中三条件：无文件/无标记/空文件均未命中，齐备才命中', () async {
    const index = 1;
    final name = dataName(index, _kKey16, 'mp3');

    // 目录不存在 → false
    expect(
      await api.audioCacheQuery(
        bookUrl: _kBookUrl,
        chapterIndex: index,
        chapterUrl: _kChapterUrl,
        chapterTitle: '第一章',
      ),
      isFalse,
    );

    // 无 `.complete` 标记 → false
    await writeCacheFile(name, marker: false);
    expect(
      await api.audioCacheQuery(
        bookUrl: _kBookUrl,
        chapterIndex: index,
        chapterUrl: _kChapterUrl,
        chapterTitle: '第一章',
      ),
      isFalse,
    );

    // 有标记但 size=0 → false
    final sep = Platform.pathSeparator;
    await File('${bookDir().path}$sep$name').writeAsBytes(const <int>[]);
    await File('${bookDir().path}$sep$name.complete').writeAsString('1\nx\nx');
    expect(
      await api.audioCacheQuery(
        bookUrl: _kBookUrl,
        chapterIndex: index,
        chapterUrl: _kChapterUrl,
        chapterTitle: '第一章',
      ),
      isFalse,
    );

    // 有标记且 size>0 → true；列举命中 [1]
    await File('${bookDir().path}$sep$name').writeAsBytes(List<int>.filled(8, 7));
    expect(
      await api.audioCacheQuery(
        bookUrl: _kBookUrl,
        chapterIndex: index,
        chapterUrl: _kChapterUrl,
        chapterTitle: '第一章',
      ),
      isTrue,
    );
    expect(await api.audioCacheList(bookUrl: _kBookUrl), <int>[1]);
    expect(
      await api.audioCacheList(bookUrl: 'other-book'),
      isEmpty,
      reason: '书级目录按 md5_16(bookUrl) 隔离，不得跨书命中',
    );
  });

  test('chapterUrl 空白时退回 chapterTitle（原版 ifBlank 语义）', () async {
    await writeCacheFile(dataName(7, _kTitleKey16, 'audio'), marker: true);
    expect(
      await api.audioCacheQuery(
        bookUrl: _kBookUrl,
        chapterIndex: 7,
        chapterUrl: '   ',
        chapterTitle: '中文',
      ),
      isTrue,
      reason: '空白 chapterUrl 应按标题计算键并命中',
    );
    expect(
      await api.audioCacheQuery(
        bookUrl: _kBookUrl,
        chapterIndex: 7,
        chapterUrl: '中文',
        chapterTitle: '无关标题',
      ),
      isTrue,
      reason: '非空 chapterUrl 优先于标题，且键相等',
    );
  });

  test('清理单章：返回删除数（仅数据文件，不计 .complete）、幂等、不触碰其他章节', () async {
    final target = dataName(1, _kKey16, 'mp3');
    final otherKey = _kTitleKey16;
    final other = dataName(2, otherKey, 'mp3');
    await writeCacheFile(target, marker: true);
    await writeCacheFile(other, marker: true);

    final deleted = await api.audioCacheClearChapter(
      bookUrl: _kBookUrl,
      chapterIndex: 1,
      chapterUrl: _kChapterUrl,
      chapterTitle: '第一章',
    );
    expect(deleted, 1,
        reason: '仅统计数据文件（契约 §2.47 口径修正；.complete 照删不计）');
    expect(
      await api.audioCacheQuery(
        bookUrl: _kBookUrl,
        chapterIndex: 1,
        chapterUrl: _kChapterUrl,
        chapterTitle: '第一章',
      ),
      isFalse,
    );
    expect(
      await api.audioCacheQuery(
        bookUrl: _kBookUrl,
        chapterIndex: 2,
        chapterUrl: '   ',
        chapterTitle: '中文',
      ),
      isTrue,
      reason: '其他章节缓存不得被清理',
    );

    // 幂等：再次清理返回 0
    expect(
      await api.audioCacheClearChapter(
        bookUrl: _kBookUrl,
        chapterIndex: 1,
        chapterUrl: _kChapterUrl,
        chapterTitle: '第一章',
      ),
      0,
    );
  });

  test('清理整书：全删（含标记）并移除目录，幂等', () async {
    await writeCacheFile(dataName(1, _kKey16, 'mp3'), marker: true);
    await writeCacheFile(dataName(3, _kTitleKey16, 'm4a'), marker: true);
    expect(await api.audioCacheClearBook(bookUrl: _kBookUrl), 2,
        reason: '仅统计数据文件（.complete 照删不计，契约 §2.47 口径修正）');
    expect(bookDir().existsSync(), isFalse, reason: '书目录应一并移除');
    expect(await api.audioCacheList(bookUrl: _kBookUrl), isEmpty);
    expect(await api.audioCacheClearBook(bookUrl: _kBookUrl), 0, reason: '幂等');
  });

  test('B2 写入面 FFI 可达：取消无在途返回 false（同步语义）', () async {
    expect(await api.audioCacheCancel(), isFalse,
        reason: '运行时测试无在途下载，置位应返回 false');
  });

  test('B2 写入面失败上抛不降级（无 DB 书籍上下文 → 异常）', () async {
    // 本运行时测试未 db_open 注入书籍/书源夹具：写入面必须上抛
    // （契约 §2.48 有意区别于 §2.47 读面降级）
    await expectLater(
      api.audioCacheDownload(
        bookUrl: 'no-such-book',
        chapterIndex: 0,
        chapterUrl: 'hello',
        chapterTitle: '第一章',
        playUrl: 'https://cdn.example/a.mp3',
      ),
      throwsA(anything),
    );
  });
}
