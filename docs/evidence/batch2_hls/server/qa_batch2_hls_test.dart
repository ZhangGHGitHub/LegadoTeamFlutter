// 批 2 HLS 音频缓存 —— 真机（MuMu 模拟器）验收驱动
//
// 目的：在**真实 Android 设备**上、经真实 FFI 入口 `audioCacheDownload`
// 走完「解析 playlist → 选档 → 直播门禁 → 分片下载 → 合并 → 安装」全链路，
// 对本地回环 HLS 服务（宿主 18080，经 adb reverse 映射到设备 127.0.0.1:18080）
// 逐条验证 5 项验收标准。
//
// 前置：
//   - 宿主已启动 .qa_scratch/hls_server/hls_server.py（端口 18080）
//   - `adb -s <dev> reverse tcp:18080 tcp:18080`
//
// 夹具：本测试在 setUpAll 内用设备自带 /system/bin/sqlite3 直接向应用私有 DB
// 注入 book / chapters / book_source / loginHeader（应用自身 uid 拥有该 DB）。
// 这样夹具与测试生命周期一致，不受 `flutter test` 安装/卸载重置数据影响。
//
// 运行：
//   flutter test integration_test/qa_batch2_hls_test.dart -d 192.168.100.62:5555
//
// 本文件位于 integration_test/，不被 `flutter test` 默认拾取，不影响单测基线。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter_legado/src/services/rust_api.dart';

const _bookUrl = 'qa://batch2-hls/book';
const _sourceUrl = 'http://127.0.0.1:18080/qa/source';
const _base = 'http://127.0.0.1:18080';
const _xsiteHost = 'http://192.168.100.52:18080';

/// 逐场景打印带前缀的结构化结果，便于事后从测试输出提取证据
void _report(String tag, Map<String, Object?> data) {
  // ignore: avoid_print
  print('QA_BATCH2_HLS $tag ${jsonEncode(data)}');
}

/// 提取 BridgeError 的 message（FRB 异常的 toString 只有类型名）
String _errText(Object e) {
  try {
    final dyn = e as dynamic;
    final msg = dyn.message;
    if (msg is String && msg.isNotEmpty) return msg;
  } catch (_) {
    // 非 BridgeError：走 toString
  }
  return '$e';
}

/// 调本地服务的 probe 端点（设备侧经 adb reverse 到宿主 18080）
Future<List<Map<String, dynamic>>> _probeRequests() async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('$_base/probe/requests'));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return (jsonDecode(body) as List<dynamic>).cast<Map<String, dynamic>>();
  } finally {
    client.close(force: true);
  }
}

Future<void> _probeReset() async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('$_base/probe/reset'));
    final resp = await req.close();
    await resp.drain<void>();
  } finally {
    client.close(force: true);
  }
}

/// 用设备自带 sqlite3 向应用私有 DB 注入夹具（app uid 拥有该文件）
Future<void> _seedDatabase(String dbPath) async {
  final sql = '''
DELETE FROM chapters WHERE bookUrl = '$_bookUrl';
DELETE FROM books WHERE bookUrl = '$_bookUrl';
DELETE FROM book_sources WHERE bookSourceUrl = '$_sourceUrl';
DELETE FROM caches WHERE key LIKE 'loginHeader_$_sourceUrl%';
INSERT INTO book_sources (bookSourceUrl, bookSourceName, bookSourceType, customOrder,
  enabled, enabledExplore, lastUpdateTime, respondTime, weight, header, enabledCookieJar)
VALUES ('$_sourceUrl', 'QA-HLS-源', 1, 0, 1, 0, 0, 0, 0,
  '{"User-Agent":"QA-Batch2-HLS","Referer":"$_base/"}', 0);
INSERT INTO books (bookUrl, tocUrl, origin, originName, name, author, type, originBookUrl)
VALUES ('$_bookUrl', '$_base/qa/toc', '$_sourceUrl', 'QA-HLS-源', 'QA HLS 验收书', 'QA', 1,
  '$_base/qa/toc');
INSERT INTO chapters (url, title, isVolume, baseUrl, bookUrl, "index", isVip, isPay) VALUES
  ('$_base/qa/ch-audio-track', '音频轨档', 0, '', '$_bookUrl', 0, 0, 0),
  ('$_base/qa/ch-nocodes', '无 CODECS 音频档', 0, '', '$_bookUrl', 1, 0, 0),
  ('$_base/qa/ch-live', '直播章', 0, '', '$_bookUrl', 2, 0, 0),
  ('$_base/qa/ch-empty', '空分片章', 0, '', '$_bookUrl', 3, 0, 0),
  ('$_base/qa/ch-ok', '正常章', 0, '', '$_bookUrl', 4, 0, 0),
  ('$_base/qa/ch-auth', '头门控章', 0, '', '$_bookUrl', 5, 0, 0);
INSERT INTO caches (key, value, deadline, created_at)
VALUES ('loginHeader_$_sourceUrl', '{"Authorization":"Bearer QA-SECRET-TOKEN"}', 0, 0);
''';
  final result = await Process.run('/system/bin/sqlite3', [dbPath, sql]);
  if (result.exitCode != 0) {
    throw StateError(
      'sqlite3 注入夹具失败 exit=${result.exitCode} '
      'stdout=${result.stdout} stderr=${result.stderr}',
    );
  }
  final check = await Process.run(
    '/system/bin/sqlite3',
    [dbPath, 'SELECT count(*) FROM chapters WHERE bookUrl="$_bookUrl";'],
  );
  _report('seed', {
    'exit': result.exitCode,
    'chapters': '${check.stdout}'.trim(),
  });
  if ('${check.stdout}'.trim() != '6') {
    throw StateError('夹具注入校验失败: ${check.stdout} ${check.stderr}');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late RustApi api;
  late Directory cacheRoot;

  setUpAll(() async {
    api = RustApi();
    await api.initialize();
    final docs = await getApplicationDocumentsDirectory();
    final dbPath = '${docs.path}/legado.db';
    _report('env', {
      'documentsDir': docs.path,
      'dbPath': dbPath,
      'dbExists': File(dbPath).existsSync(),
    });
    await _seedDatabase(dbPath);

    final cacheDir = await getApplicationCacheDirectory();
    cacheRoot = Directory('${cacheDir.path}/audio_cache');
    _report('env', {
      'audioCacheRoot': cacheRoot.path,
      'exists': cacheRoot.existsSync(),
    });
  });

  List<Map<String, Object?>> listBookFiles() {
    final dirs = cacheRoot
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.split(RegExp(r'[\\/]')).last.startsWith('book_'))
        .toList();
    final out = <Map<String, Object?>>[];
    for (final d in dirs) {
      for (final e in d.listSync()) {
        final stat = e.statSync();
        out.add({
          'dir': d.path.split(RegExp(r'[\\/]')).last,
          'name': e.path.split(RegExp(r'[\\/]')).last,
          'size': stat.size,
          'isDir': stat.type == FileSystemEntityType.directory,
        });
      }
    }
    out.sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return out;
  }

  void clearBookCache() {
    for (final d in cacheRoot.listSync().whereType<Directory>()) {
      if (d.path.split(RegExp(r'[\\/]')).last.startsWith('book_')) {
        d.deleteSync(recursive: true);
      }
    }
  }

  testWidgets('场景1a 纯音频档选择：master 的 EXT-X-MEDIA 音频轨优先（服务端日志判定）',
      (tester) async {
    clearBookCache();
    await _probeReset();
    final result = await api.audioCacheDownload(
      bookUrl: _bookUrl,
      chapterIndex: 0,
      chapterUrl: '$_base/qa/ch-audio-track',
      chapterTitle: '音频轨档',
      playUrl: '$_base/master.m3u8',
    );
    final json = jsonDecode(result) as Map<String, dynamic>;
    _report('case1a', {'result': json});
    expect(json['status'], 'installed');
    expect(json['extension'], 'ts');
    final files = listBookFiles();
    _report('case1a', {'files': files});
    expect(files.where((f) => '${f['name']}'.endsWith('.complete')).length, 1,
        reason: '必须有且仅有一个 .complete 标记');

    final reqs = await _probeRequests();
    final paths = reqs.map((r) => r['path'] as String).toList();
    _report('case1a', {'serverPaths': paths});
    expect(paths, contains('/audio.m3u8'), reason: '应拉取独立音频轨 URI /audio.m3u8');
    expect(paths, isNot(contains('/video.m3u8')),
        reason: '不得拉取视频档 /video.m3u8（音频轨优先）');
  });

  testWidgets('场景1b 纯音频档选择：variant 音频档省略 CODECS 仍应选中（旧实现会误选视频档）',
      (tester) async {
    clearBookCache();
    await _probeReset();
    final result = await api.audioCacheDownload(
      bookUrl: _bookUrl,
      chapterIndex: 1,
      chapterUrl: '$_base/qa/ch-nocodes',
      chapterTitle: '无 CODECS 音频档',
      playUrl: '$_base/master-nocodes.m3u8',
    );
    final json = jsonDecode(result) as Map<String, dynamic>;
    _report('case1b', {'result': json});
    expect(json['status'], 'installed');

    final reqs = await _probeRequests();
    final paths = reqs.map((r) => r['path'] as String).toList();
    _report('case1b', {'serverPaths': paths});
    expect(paths, contains('/audio.m3u8'),
        reason: '省略 CODECS 的音频档应被选中（旧实现会误选带 avc1 的视频档）');
    expect(paths, isNot(contains('/video.m3u8')),
        reason: '不得拉取带 RESOLUTION+avc1 的视频档');
  });

  testWidgets('场景2 直播拒绝：无 EXT-X-ENDLIST → Err 含「直播」且无残留', (tester) async {
    clearBookCache();
    Object? err;
    try {
      await api.audioCacheDownload(
        bookUrl: _bookUrl,
        chapterIndex: 2,
        chapterUrl: '$_base/qa/ch-live',
        chapterTitle: '直播章',
        playUrl: '$_base/live.m3u8',
      );
    } catch (e) {
      err = e;
    }
    final errText = err == null ? '' : _errText(err);
    _report('case2', {'error': errText});
    expect(err, isNotNull, reason: '直播 playlist 必须 Err');
    expect(errText.contains('直播'), isTrue, reason: '错误文案须含「直播」: $errText');
    final files = listBookFiles();
    _report('case2', {'filesAfter': files});
    expect(files.where((f) => '${f['name']}'.endsWith('.complete')), isEmpty,
        reason: '直播拒绝不得留 .complete');
    expect(files.where((f) => '${f['name']}'.endsWith('.part')), isEmpty,
        reason: '直播拒绝不得留 .part 临时文件');
  });

  testWidgets('场景3 空分片拒绝：第 2 段 0 字节 → Err 且无 .complete / 无残留', (tester) async {
    clearBookCache();
    Object? err;
    try {
      await api.audioCacheDownload(
        bookUrl: _bookUrl,
        chapterIndex: 3,
        chapterUrl: '$_base/qa/ch-empty',
        chapterTitle: '空分片章',
        playUrl: '$_base/empty-seg.m3u8',
      );
    } catch (e) {
      err = e;
    }
    final errText = err == null ? '' : _errText(err);
    _report('case3', {'error': errText});
    expect(err, isNotNull, reason: '空分片必须 Err');
    final files = listBookFiles();
    _report('case3', {'filesAfter': files});
    expect(files.where((f) => '${f['name']}'.endsWith('.complete')), isEmpty);
    expect(files.where((f) => '${f['name']}'.endsWith('.part')), isEmpty);
    expect(files.where((f) => '${f['name']}'.endsWith('.ts')), isEmpty,
        reason: '失败不得留下合并产物');
  });

  testWidgets('场景4 正常路径：installed + 单文件 + .complete 存在', (tester) async {
    clearBookCache();
    final result = await api.audioCacheDownload(
      bookUrl: _bookUrl,
      chapterIndex: 4,
      chapterUrl: '$_base/qa/ch-ok',
      chapterTitle: '正常章',
      playUrl: '$_base/master.m3u8',
    );
    final json = jsonDecode(result) as Map<String, dynamic>;
    _report('case4', {'result': json});
    expect(json['status'], 'installed');
    expect(json['extension'], 'ts');

    final files = listBookFiles();
    _report('case4', {'files': files});
    final dataFiles = files
        .where((f) => !'${f['name']}'.endsWith('.complete') && f['isDir'] != true)
        .toList();
    expect(dataFiles.length, 1, reason: '合并产物必须是单文件: $files');
    expect('${dataFiles.first['name']}'.endsWith('.ts'), isTrue);
    expect((dataFiles.first['size'] as int) > 0, isTrue);
    expect(files.where((f) => '${f['name']}'.endsWith('.complete')).length, 1);

    // 幂等
    final again = await api.audioCacheDownload(
      bookUrl: _bookUrl,
      chapterIndex: 4,
      chapterUrl: '$_base/qa/ch-ok',
      chapterTitle: '正常章',
      playUrl: '$_base/master.m3u8',
    );
    final againJson = jsonDecode(again) as Map<String, dynamic>;
    _report('case4', {'second': againJson});
    expect(againJson['status'], 'already_cached');

    // 导出产物供宿主 ffmpeg 验证可播放：
    // 同时写应用私有目录（测试内断言）与 /sdcard（flutter test 结束会卸载
    // 应用并清私有数据，只有外部存储能在测试后 pull 留证）
    final dataFile = File(
        '${cacheRoot.path}/${dataFiles.first['dir']}/${dataFiles.first['name']}');
    final bytes = dataFile.readAsBytesSync();
    final exported =
        File('${(await getApplicationDocumentsDirectory()).path}/qa_case4_merged.ts');
    exported.writeAsBytesSync(bytes);
    const externalPath = '/sdcard/Download/qa_case4_merged.ts';
    try {
      File(externalPath).writeAsBytesSync(bytes);
    } catch (e) {
      _report('case4', {'externalExportError': '$e'});
    }
    _report('case4', {
      'exported': exported.path,
      'exportedSize': exported.lengthSync(),
      'externalPath': externalPath,
      'externalExists': File(externalPath).existsSync(),
    });
  });

  testWidgets('场景5 同站/跨站头门控：同站分片带 Authorization，跨站分片不带', (tester) async {
    clearBookCache();
    await _probeReset();
    Object? err;
    try {
      final result = await api.audioCacheDownload(
        bookUrl: _bookUrl,
        chapterIndex: 5,
        chapterUrl: '$_base/qa/ch-auth',
        chapterTitle: '头门控章',
        playUrl: '$_base/auth/master.m3u8',
      );
      _report('case5', {'result': jsonDecode(result)});
    } catch (e) {
      err = e;
      _report('case5', {'error': _errText(e)});
    }
    _report('case5', {'completed': err == null});

    final reqs = await _probeRequests();
    Map<String, dynamic>? findReq(String path) {
      for (final r in reqs) {
        if (r['path'] == path) return r;
      }
      return null;
    }

    final same = findReq('/auth/seg0.ts');
    final cross = findReq('/xsite/seg1.ts');
    _report('case5', {
      'sameSiteReq': same,
      'crossSiteReq': cross,
      'allPaths': reqs.map((r) => r['path']).toList(),
      'xsiteHost': _xsiteHost,
    });
    expect(same, isNotNull, reason: '同站分片 /auth/seg0.ts 应被请求');
    expect(cross, isNotNull, reason: '跨站分片 /xsite/seg1.ts 应被请求');

    final sameHeaders = (same!['headers'] as Map).cast<String, dynamic>();
    final crossHeaders = (cross!['headers'] as Map).cast<String, dynamic>();
    expect(sameHeaders.keys.map((k) => k.toLowerCase()), contains('authorization'),
        reason: '同站分片必须收到 Authorization: $sameHeaders');
    expect(crossHeaders.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
        reason: '跨站分片不得收到 Authorization（凭据外泄）: $crossHeaders');
    // Referer 是防盗链所需，跨站仍应发送（登记为契约要求）
    expect(crossHeaders.keys.map((k) => k.toLowerCase()), contains('referer'),
        reason: '跨站仍应发送 Referer（防盗链）: $crossHeaders');
  });
}
