/// FRB StreamSink 生成链路真实 DLL 运行时验证（P1-1）
///
/// 绕过 Mock 层直接加载 rust/target/debug/legado_ffi.dll，验证
/// flutter_rust_bridge 2.11.1 生成的 5 个 StreamSink 流 API 在真实
/// wire 链路上的订阅、事件接收、正常结束与取消路径：
///
/// - crateFfiFfiSourceCheckStream / crateFfiFfiSourceCheckCancel
/// - crateFfiFfiDebugBookSourceStream / crateFfiFfiDebugBookSourceCancel
/// - crateFfiFfiVerificationRequestStream（+ pending/submit/cancel 配套）
/// - crateFfiFfiWebviewRequestStream（+ pending/submit/cancel 配套）
/// - crateFfiFfiSearchMultiStream
///
/// 同时作为 UnimplementedError 分支不可达性的运行时证据：所有流均由
/// Dart 侧创建 sink 后经 sse_encode_StreamSink_String_Sse 单向传入
/// Rust（frb_generated.dart L3394/L6969/L7342/L8218/L8760），解码方向
/// （dco_decode/sse_decode_StreamSink_String_Sse）在全部链路中无调用点；
/// 若该分支可达，下列测试将全部抛出 UnimplementedError。
///
/// 前置条件：先在 rust/ 下构建 DLL（cargo build -p legado-ffi --features quickjs）。
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_legado/src/bridge/ffi/ffi.dart' as bridge;
import 'package:flutter_legado/src/bridge/frb_generated.dart';
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

class _CollectResult {
  const _CollectResult(this.events, this.completed, this.error);

  final List<String> events;

  /// 是否以 onDone 正常结束（true=正常结束，false=onError）
  final bool completed;
  final Object? error;
}

/// 订阅流并收集事件直至结束；[afterSubscribe] 在订阅后立即执行
/// （用于并发触发取消等配套调用）
Future<_CollectResult> _collect(
  Stream<String> stream, {
  Future<void> Function()? afterSubscribe,
  Duration timeout = const Duration(seconds: 45),
}) async {
  final events = <String>[];
  final settled = Completer<_CollectResult>();
  late final StreamSubscription<String> sub;
  sub = stream.listen(
    events.add,
    onDone: () {
      if (!settled.isCompleted) {
        settled.complete(_CollectResult(events, true, null));
      }
    },
    onError: (Object e) {
      if (!settled.isCompleted) {
        settled.complete(_CollectResult(events, false, e));
      }
    },
  );
  if (afterSubscribe != null) {
    await afterSubscribe();
  }
  final _CollectResult result;
  try {
    result = await settled.future.timeout(timeout);
  } on TimeoutException {
    await sub.cancel();
    rethrow;
  }
  await sub.cancel();
  return result;
}

void main() {
  setUpAll(() async {
    // 显式加载真实 DLL（非 frb 默认加载逻辑，非 Mock）
    final lib = ExternalLibrary.open(_resolveDll());
    await RustLib.init(externalLibrary: lib);
    await bridge.init();
    // 隔离数据库：书源表为空且仅含本测试注入的数据，保证断言确定性
    final sep = Platform.pathSeparator;
    final dbDir = Directory('.dart_tool${sep}ffi_stream_test');
    dbDir.createSync(recursive: true);
    final dbFile = File('${dbDir.path}${sep}p1_1_streams.db');
    if (dbFile.existsSync()) {
      dbFile.deleteSync();
    }
    await bridge.dbOpen(path: dbFile.path);
  });

  group('FRB StreamSink 真实 DLL 运行时验证（P1-1）', () {
    test('前置：DLL 加载成功且 version() 经真实 wire 返回', () async {
      final version = await bridge.version();
      expect(version, isNotEmpty);
    });

    test('sourceCheckStream：订阅→进度事件→正常结束', () async {
      // 不存在的 URL 以 None 占位并推送失败进度（无网络依赖，确定性）
      final r = await _collect(bridge.sourceCheckStream(
        sourceUrlsJson: jsonEncode(['test://stream-check-nonexistent']),
        configJson: '',
      ));
      expect(r.error, isNull, reason: '流不应产生 onError');
      expect(r.completed, isTrue, reason: '流应自然结束');
      expect(r.events, hasLength(1));
      final progress = jsonDecode(r.events.single) as Map<String, dynamic>;
      expect(progress['total'], 1);
      expect(progress['is_last'], true);
      final result = progress['result'] as Map<String, dynamic>;
      expect(result['search_error'], contains('书源不存在'));
    });

    test('sourceCheckCancel：取消路径（wire 调用+干净结束+新一轮重置）', () async {
      final urls =
          jsonEncode(List.generate(200, (i) => 'test://cancel-check-$i'));
      // 第一轮：订阅后立即取消。取消检查点位于源间（Rust 侧单测覆盖 break
      // 语义）；此处验证取消调用经真实 wire 成功返回且流生命周期不受破坏。
      final cancelled = await _collect(
        bridge.sourceCheckStream(sourceUrlsJson: urls, configJson: ''),
        afterSubscribe: () => bridge.sourceCheckCancel(),
      );
      expect(cancelled.completed, isTrue);
      expect(cancelled.error, isNull);
      expect(cancelled.events.length, lessThanOrEqualTo(200));
      // 第二轮：不取消 → 全部事件完整到达。证明取消标志在新一轮开始时被
      // 重置（source_check_api.rs L155），取消不残留污染后续会话。
      final rerun = await _collect(
        bridge.sourceCheckStream(sourceUrlsJson: urls, configJson: ''),
      );
      expect(rerun.completed, isTrue);
      expect(rerun.error, isNull);
      expect(rerun.events, hasLength(200));
      final last = jsonDecode(rerun.events.last) as Map<String, dynamic>;
      expect(last['is_last'], true);
    });

    test('debugBookSourceStream：订阅→失败事件(state=-1)→正常结束', () async {
      final r = await _collect(bridge.debugBookSourceStream(
        sourceUrl: 'test://stream-debug-nonexistent',
        key: '搜索词',
      ));
      expect(r.error, isNull);
      expect(r.completed, isTrue);
      expect(r.events, isNotEmpty);
      final first = jsonDecode(r.events.first) as Map<String, dynamic>;
      expect(first['state'], -1);
      expect(first['msg'], contains('未找到书源'));
    });

    test('debugBookSourceCancel：取消路径（会话失效+后续会话不受影响）', () async {
      const url = 'test://stream-debug-cancel';
      // 第一轮：发起后立即取消（SESSION_ID 自增使旧会话失效），流干净结束
      final cancelled = await _collect(
        bridge.debugBookSourceStream(sourceUrl: url, key: 'k'),
        afterSubscribe: () => bridge.debugBookSourceCancel(),
      );
      expect(cancelled.completed, isTrue);
      expect(cancelled.error, isNull);
      // 第二轮：取消后再跑仍正常产出事件，会话机制未被破坏
      final rerun = await _collect(
        bridge.debugBookSourceStream(sourceUrl: url, key: 'k'),
      );
      expect(rerun.completed, isTrue);
      expect(rerun.error, isNull);
      expect(rerun.events, isNotEmpty);
      final first = jsonDecode(rerun.events.first) as Map<String, dynamic>;
      expect(first['state'], -1);
    });

    test('verificationRequestStream：长期存活+pending/submit/cancel 配套', () async {
      var ended = false;
      Object? streamError;
      final sub = bridge.verificationRequestStream().listen(
        (_) {},
        onDone: () => ended = true,
        onError: (Object e) {
          ended = true;
          streamError = e;
        },
      );
      // 等待超过 Rust 侧轮询周期（STREAM_POLL_INTERVAL=1s）×2，
      // 证明接收循环存活且未误结束（无请求时不推事件属预期行为）
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(streamError, isNull, reason: '长期存活流不应出错');
      expect(ended, isFalse, reason: '长期存活流不应在订阅后立即结束');
      // 配套 API 经真实 wire 工作
      final pending = await bridge.verificationPending();
      expect(jsonDecode(pending), isEmpty);
      expect(
        await bridge.verificationSubmit(key: 'no-such-key', code: '1234'),
        false,
      );
      expect(await bridge.verificationCancel(key: 'no-such-key'), false);
      // 长期存活流空闲时底层 async* 生成器停在端口等待点，取消 Future
      // 永不完成（FRB RustStreamSink 语义，非本项目缺陷），故不等待取消
      unawaited(sub.cancel());
    });

    test('webviewRequestStream：长期存活+pending/submit/cancel 配套', () async {
      var ended = false;
      Object? streamError;
      final sub = bridge.webviewRequestStream().listen(
        (_) {},
        onDone: () => ended = true,
        onError: (Object e) {
          ended = true;
          streamError = e;
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(streamError, isNull);
      expect(ended, isFalse);
      final pending = await bridge.webviewPending();
      expect(jsonDecode(pending), isEmpty);
      expect(
        await bridge.webviewSubmit(key: 'no-such-key', result: '{}'),
        false,
      );
      expect(await bridge.webviewCancel(key: 'no-such-key'), false);
      // 同上：长期存活流取消 Future 不完成，不等待（见 verification 用例说明）
      unawaited(sub.cancel());
    });

    test('searchMultiStream：订阅→逐源批次事件→正常结束', () async {
      // 注入指向本机拒绝端口的假源（连接秒拒，无外网依赖）
      const fakeUrl = 'test://stream-fake-source';
      final imported = await bridge.sourceImport(
        jsonArray: jsonEncode([
          {
            'bookSourceUrl': fakeUrl,
            'bookSourceName': 'P1-1 流式验证假源',
            'bookSourceType': 0,
            'searchUrl': 'http://127.0.0.1:9/search?q={{key}}',
            'ruleSearch': {'bookList': '.x'},
          },
        ]),
      );
      expect(imported, greaterThanOrEqualTo(1));
      final r = await _collect(bridge.searchMultiStream(
        query: '测试关键词',
        sourceUrlsJson: jsonEncode([fakeUrl]),
      ));
      expect(r.error, isNull);
      expect(r.completed, isTrue);
      expect(r.events, hasLength(1), reason: '单个书源应恰好回推一个批次');
      final batch = jsonDecode(r.events.single) as Map<String, dynamic>;
      expect(batch['source_url'], fakeUrl);
      expect(batch['is_last'], true);
      expect(batch['finished_count'], 1);
      expect((batch['books'] as List), isEmpty, reason: '拒绝端口应无结果');
      expect(batch['error'], isNotNull, reason: '连接失败应以 error 字段回推批次');
    });
  });
}