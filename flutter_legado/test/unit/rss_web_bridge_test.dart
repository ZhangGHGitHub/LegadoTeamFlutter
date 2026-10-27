// RSS WebView preloadJs 宿主桥单元测试（批21b）
//
// 覆盖：`__prepare` 解析、协议编码、hello/nonce 握手、方法白名单转发、
// 30s（测试用短超时）失败回填、`__store` 写穿、动作分发、Cookie 辅助、
// 组合脚本注入顺序，以及**同步面纯函数/同步网络报错**的真实 JS 执行
// （Node 可用时执行 `kRssBridgeSyncShimBody`，不可用时降级为结构断言）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/services/rss_web_bridge.dart';
import 'package:flutter_legado/src/services/rss_web_config.dart';

import '../mocks/mocks.dart';

/// 组合一次 `__prepare` 成功信封
String _prepareEnvelope({
  String script = '(() => {\n  // 桥头\n',
  Object? snapshot = const <String, dynamic>{
    'sourceUrl': 'https://s.test/feed',
    'sourceName': '测试源',
    'userAgent': 'UA-Prepare',
    'loginHeader': '{"Cookie":"sid=1"}',
    'vars': <String, String>{'k': 'v'},
  },
  bool bridgeAvailable = true,
}) =>
    jsonEncode(<String, dynamic>{
      'ok': true,
      'value': <String, dynamic>{
        'script': script,
        'snapshot': snapshot,
        'bridgeAvailable': bridgeAvailable,
      },
      'error': null,
    });

/// 组合一次宿主调用成功信封
String _okEnvelope(Object? value) => jsonEncode(<String, dynamic>{
      'ok': true,
      'value': value,
      'error': null,
    });

String _errorEnvelope(String error) => jsonEncode(<String, dynamic>{
      'ok': false,
      'value': null,
      'error': error,
    });

/// 页面消息
String _pageMessage({
  required String method,
  String id = 'rss_1',
  String args = '[]',
  String? nonce,
}) =>
    jsonEncode(<String, dynamic>{
      'nonce': nonce,
      'id': id,
      'method': method,
      'args': args,
    });

void main() {
  late MockRustApi api;
  late List<String> runLog;
  late List<RssWebBridgeAction> actions;

  RssWebBridge newBridge({
    Duration timeout = const Duration(seconds: 30),
    Duration handshakeTimeout = const Duration(seconds: 10),
    Duration? watchdog,
    List<String>? log,
    RssWebBridgeJsRunner? runner,
    Duration Function()? elapsed,
  }) {
    final bridge = RssWebBridge(
      sourceUrl: 'https://s.test/feed',
      api: api,
      runJavaScript: runner ?? (js) async => (log ?? runLog).add(js),
      requestTimeout: timeout,
      handshakeTimeout: handshakeTimeout,
      handshakeWatchdog: watchdog ?? const Duration(seconds: 4),
      onAction: actions.add,
      onLog: (message) => (log ?? runLog).add('LOG:$message'),
      random: Random(7),
      elapsedNow: elapsed,
    );
    addTearDown(bridge.dispose);
    return bridge;
  }

  /// 模拟页面回发 nonceAck（最新令牌）
  Future<void> ack(RssWebBridge bridge, String nonce) => bridge.handleMessage(
        _pageMessage(
          method: 'nonceAck',
          id: '',
          args: '${bridge.handshakeToken}',
          nonce: nonce,
        ),
      );

  /// 完成握手（hello → 回填 → 页面 ACK，返回 nonce）
  Future<String> handshake(RssWebBridge bridge) async {
    await bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
    final nonce = bridge.nonce;
    expect(nonce, isNotNull, reason: 'hello 后必须生成 nonce');
    await ack(bridge, nonce!);
    expect(bridge.isHandshaken, isTrue, reason: '页面 ACK 后必须置位握手');
    return nonce;
  }

  setUpAll(registerFallbacks);

  setUp(() {
    api = MockRustApi();
    runLog = <String>[];
    actions = <RssWebBridgeAction>[];
  });

  group('__prepare 解析', () {
    test('成功：透传 channelName/callbackName/ua 并解析 script/snapshot', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _prepareEnvelope());

      final bridge = newBridge();
      final result = await bridge.prepare(userAgent: 'UA-X');

      expect(result, isNotNull);
      expect(result!.script, contains('// 桥头'));
      expect(result.sourceUrl, 'https://s.test/feed');
      expect(result.sourceName, '测试源');
      expect(result.userAgent, 'UA-Prepare');
      expect(result.loginHeader, '{"Cookie":"sid=1"}');
      expect(result.vars, {'k': 'v'});

      final captured = verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          '__prepare',
          captureAny(),
        ),
      ).captured.single as String;
      final params = (jsonDecode(captured) as List).single as Map;
      expect(params['channelName'], bridge.channelName);
      expect(params['callbackName'], bridge.callbackName);
      expect(params['ua'], 'UA-X');
      expect(bridge.channelName, startsWith('__rs_'));
      expect(bridge.nativeChannelName, startsWith('__rn_'));
      expect(bridge.callbackName, startsWith('__rc_'));
      expect(bridge.nonceCallbackName, startsWith('__rk_'));
      expect(
        <String>{
          bridge.channelName,
          bridge.nativeChannelName,
          bridge.callbackName,
          bridge.nonceCallbackName,
        }.length,
        4,
        reason: '通道/桥对象/回填回调/nonce 回调必须各自独立随机，互不可推',
      );
      expect(bridge.nativeChannelName, isNot(bridge.channelName),
          reason: '平台通道名与页面桥对象名必须分离，避免覆写平台注入对象');
    });

    test('失败信封 / 非法 JSON → null（降级无宿主绑定）', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _errorEnvelope('当前构建未启用 quickjs'));
      expect(await newBridge().prepare(), isNull);

      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => 'not-json');
      expect(await newBridge().prepare(), isNull);

      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenThrow(Exception('boom'));
      expect(await newBridge().prepare(), isNull);
    });
  });

  group('协议编码', () {
    test('回填结果脚本携带回调名/id/ok/payload 字面量', () {
      final script = rssBridgeReplyScript(
        callbackName: 'cb',
        id: 'id 1',
        ok: false,
        payload: '错误"信息',
      );
      expect(script, contains('window["cb"]("id 1", false, '));
      expect(script, contains(r'错误\"信息'));
    });

    test('U+2028/U+2029 转义避免旧引擎断句', () {
      final literal = rssJsLiteral('a\u2028b\u2029c');
      expect(literal, contains(r'\u2028'));
      expect(literal, contains(r'\u2029'));
    });

    test('nonce 回填脚本：独立回调名 + 代数令牌 + 交付后立即删除', () {
      final script = rssBridgeNonceScript(
        nonceCallbackName: 'nonceCb',
        nonce: 'n1',
        generation: 7,
      );
      expect(script, contains('window["nonceCb"]("n1", 7)'));
      expect(script, contains('delete window["nonceCb"]'));
    });

    test('hello 重发脚本经回填回调上的非枚举入口', () {
      final script = rssBridgeHelloScript(callbackName: 'cb');
      expect(script, contains('window["cb"]'));
      expect(script, contains('__lgHello'));
    });

    test('信封解析：actions 仅保留对象项', () {
      final envelope = RssWebBridgeEnvelope.parse(jsonEncode({
        'ok': true,
        'value': 1,
        'error': null,
        'actions': [
          {'action': 'toast', 'text': 'x'},
          'bad',
        ],
      }));
      expect(envelope.ok, isTrue);
      expect(envelope.value, 1);
      expect(envelope.actions, hasLength(1));
      expect(envelope.actions.single['action'], 'toast');
    });
  });

  group('hello/nonce 握手', () {
    test('首个 hello 接受并回填 nonce；后续消息必须携带 nonce', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _okEnvelope('v'));
      final bridge = newBridge();
      final nonce = await handshake(bridge);

      expect(bridge.isHandshaken, isTrue);
      expect(
        runLog.any(
          (js) =>
              js.contains(bridge.nonceCallbackName) &&
              js.contains(nonce) &&
              js.contains('${bridge.handshakeToken}'),
        ),
        isTrue,
        reason: '必须经 runJavaScript 回填 nonce（独立回调名 + 代数令牌）',
      );

      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        args: '["https://a"]',
        nonce: nonce,
      ));
      await Future<void>.delayed(Duration.zero);
      verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          'getAwait',
          '["https://a"]',
        ),
      ).called(1);
    });

    test('页面导航后重置握手：新 hello 接受、旧 nonce 拒绝', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _okEnvelope('v'));
      final bridge = newBridge();
      final firstNonce = await handshake(bridge);

      bridge.beginNavigation();
      expect(bridge.isHandshaken, isFalse);
      expect(bridge.nonce, isNull);

      final secondNonce = await handshake(bridge);
      expect(secondNonce, isNot(firstNonce),
          reason: '新文档必须换发 nonce');

      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        args: '["https://old"]',
        nonce: firstNonce,
      ));
      await Future<void>.delayed(Duration.zero);
      verifyNever(
        () => api.rssWebViewHostCall(any(), 'getAwait', any()),
      );
    });

    test('重复 hello 拒绝（nonce 不变）', () async {
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
      expect(bridge.nonce, nonce);
      expect(
        runLog.any((js) => js.contains('重复 hello')),
        isTrue,
        reason: '重复 hello 必须回失败并留日志',
      );
    });

    test('错误 nonce / 握手前消息一律拒绝且不发起 RPC', () async {
      final bridge = newBridge();
      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        args: '["https://a"]',
        nonce: null,
      ));
      verifyNever(
        () => api.rssWebViewHostCall(any(), any(), any()),
      );

      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        args: '["https://a"]',
        nonce: '${nonce}x',
      ));
      verifyNever(
        () => api.rssWebViewHostCall(
          any(),
          'getAwait',
          any(),
        ),
      );
      expect(
        runLog.any((js) => js.contains('nonce 校验失败')),
        isTrue,
      );
    });

    test('nonce 回填 runJavaScript 失败：状态回滚，可重试 hello', () async {
      var fail = true;
      final bridge = newBridge(runner: (js) async {
        if (fail) {
          fail = false;
          throw Exception('runJavaScript boom');
        }
        runLog.add(js);
      });
      await bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
      expect(bridge.isHandshaken, isFalse, reason: '回填失败不得置位握手');
      expect(bridge.nonce, isNull, reason: '回填失败必须回滚 nonce');

      // 第二次 hello 必须被接受（失败可恢复）
      await bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
      expect(bridge.isHandshaken, isFalse,
          reason: '回填成功但 ACK 未到，握手不得置位');
      await ack(bridge, bridge.nonce!);
      expect(bridge.isHandshaken, isTrue);
      expect(bridge.nonce, isNotNull);
    });

    test('ACK 缺失：状态不置位，看门狗重试后新 hello 可完成（虚拟时钟）', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 1, 1));
        final bridge = newBridge(
          watchdog: const Duration(seconds: 4),
          // 批21f P2-2：注入单调时钟（fakeAsync 虚拟时间）
          elapsed: () => clock.now().difference(DateTime(2026, 1, 1)),
        );
        bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
        async.flushMicrotasks();
        expect(bridge.isHandshaken, isFalse, reason: 'ACK 缺失不得置位握手');
        expect(bridge.nonce, isNotNull);

        // 看门狗超时（回填已结束、ACK 未到）→ 重发 hello
        async.elapse(const Duration(seconds: 5));
        expect(
          runLog.any((js) => js.contains('__lgHello')),
          isTrue,
          reason: 'ACK 缺失时看门狗必须重发 hello',
        );
        expect(bridge.watchdogRetries, 1);

        // 页面再次 hello → 新 nonce → ACK 后置位，计时器取消
        bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
        async.flushMicrotasks();
        ack(bridge, bridge.nonce!);
        async.flushMicrotasks();
        expect(bridge.isHandshaken, isTrue);
        expect(bridge.isWatchdogActive, isFalse);
        final helloCount = runLog.where((js) => js.contains('__lgHello')).length;
        async.elapse(const Duration(seconds: 20));
        expect(
          runLog.where((js) => js.contains('__lgHello')).length,
          helloCount,
          reason: 'ACK 成功后看门狗计时器必须取消，不得继续重发',
        );
      });
    });

    test('回填慢于看门狗：顺延受总时长上限约束，新 hello 仍被接受（虚拟时钟）', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 1, 1));
        final holders = <Completer<void>>[];
        final bridge = newBridge(
          watchdog: const Duration(seconds: 4),
          handshakeTimeout: const Duration(seconds: 10),
          // 批21f P2-2：注入单调时钟（fakeAsync 虚拟时间）
          elapsed: () => clock.now().difference(DateTime(2026, 1, 1)),
          runner: (js) async {
            final completer = Completer<void>();
            holders.add(completer);
            await completer.future;
            runLog.add(js);
          },
        );
        bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
        async.flushMicrotasks();
        final firstNonce = bridge.nonce;
        expect(holders, hasLength(1));
        expect(bridge.isHandshaken, isFalse);

        // 回填在途未超总时长：只顺延，不得重置代数/nonce
        async.elapse(const Duration(seconds: 8));
        expect(
          runLog.any((js) => js.contains('看门狗顺延')),
          isTrue,
          reason: '回填在途时看门狗必须顺延',
        );
        expect(bridge.nonce, firstNonce, reason: '顺延不得清空在途 nonce');
        expect(bridge.watchdogRetries, 0, reason: '顺延不消耗重试次数');

        // 新 hello 仍被接受（覆盖在途握手），并以新 nonce/ACK 置位
        bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
        async.flushMicrotasks();
        expect(holders.length, greaterThanOrEqualTo(2));
        final secondNonce = bridge.nonce!;
        expect(secondNonce, isNot(firstNonce));
        holders.last.complete();
        async.flushMicrotasks();
        ack(bridge, secondNonce);
        async.flushMicrotasks();
        expect(bridge.isHandshaken, isTrue);

        // 旧回填晚到：不得覆盖新状态
        holders.first.complete();
        async.flushMicrotasks();
        expect(bridge.nonce, secondNonce);
        expect(bridge.isHandshaken, isTrue);
      });
    });

    test('回填在途超过 handshakeTimeout：按失败处理并进入重试（虚拟时钟）', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 1, 1));
        final blocker = Completer<void>();
        final bridge = newBridge(
          watchdog: const Duration(milliseconds: 10),
          handshakeTimeout: const Duration(milliseconds: 25),
          // 批21f P2-2：注入单调时钟（fakeAsync 虚拟时间）
          elapsed: () => clock.now().difference(DateTime(2026, 1, 1)),
          runner: (js) async {
            if (js.contains('__rk_')) {
              await blocker.future;
            }
            runLog.add(js);
          },
        );
        bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
        async.flushMicrotasks();
        expect(bridge.nonce, isNotNull);

        // 10ms 顺延、20ms 顺延、30ms 超过 25ms 总时长 → 按失败重试
        async.elapse(const Duration(milliseconds: 40));
        expect(
          runLog.any((js) => js.contains('超过总时长上限')),
          isTrue,
          reason: '在途顺延必须受总时长上限约束',
        );
        expect(bridge.watchdogRetries, greaterThanOrEqualTo(1));
        blocker.complete();
        async.flushMicrotasks();
      });
    });

    test('注入时钟回拨：在途时长按 0 处理，不提前判超时（批21f P2-2）', () {
      fakeAsync((async) {
        var elapsed = const Duration(seconds: 10);
        final blocker = Completer<void>();
        final bridge = newBridge(
          watchdog: const Duration(seconds: 4),
          handshakeTimeout: const Duration(seconds: 30),
          elapsed: () => elapsed,
          runner: (js) async {
            if (js.contains('__rk_')) {
              await blocker.future;
            }
            runLog.add(js);
          },
        );
        bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
        async.flushMicrotasks();
        final nonce = bridge.nonce;
        expect(nonce, isNotNull);

        // 单调时钟回拨 5s：差值 -5s 必须钳制为 0（顺延而非判超时重试）
        elapsed = const Duration(seconds: 5);
        async.elapse(const Duration(seconds: 4));
        expect(
          runLog.any((js) => js.contains('看门狗顺延')),
          isTrue,
          reason: '负差值必须按 0 处理',
        );
        expect(bridge.watchdogRetries, 0, reason: '回拨不得消耗重试次数');
        expect(bridge.nonce, nonce, reason: '回拨不得重置在途 nonce');

        blocker.complete();
        async.flushMicrotasks();
      });
    });

    test('无 preloadJs（未注入桥）：不臂看门狗，4s 后也不重发 hello（虚拟时钟）', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 1, 1));
        final bridge = newBridge(
          watchdog: const Duration(seconds: 4),
          // 批21f P2-2：注入单调时钟（fakeAsync 虚拟时间）
          elapsed: () => clock.now().difference(DateTime(2026, 1, 1)),
        );
        bridge.beginNavigation(bridgeInjected: false);
        expect(bridge.isWatchdogActive, isFalse);
        async.elapse(const Duration(seconds: 20));
        expect(
          runLog.any((js) => js.contains('__lgHello')),
          isFalse,
          reason: '未注入桥的源不得空转重发 hello',
        );
        expect(bridge.watchdogRetries, 0);
      });
    });

    test('看门狗重试上限 3 次后停止并留明确日志（虚拟时钟）', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 1, 1));
        final bridge = newBridge(
          watchdog: const Duration(seconds: 4),
          // 批21f P2-2：注入单调时钟（fakeAsync 虚拟时间）
          elapsed: () => clock.now().difference(DateTime(2026, 1, 1)),
        );
        bridge.beginNavigation();
        async.elapse(const Duration(seconds: 30));
        expect(bridge.watchdogRetries, kRssWebBridgeMaxWatchdogRetries);
        expect(
          runLog.where((js) => js.contains('__lgHello')).length,
          kRssWebBridgeMaxWatchdogRetries,
          reason: '每轮看门狗只重发一次 hello，达到上限后停止',
        );
        expect(
          runLog.any((js) => js.contains('停止重试')),
          isTrue,
          reason: '停止重试必须留明确日志',
        );
        expect(bridge.isWatchdogActive, isFalse);
      });
    });

    test('陈旧 ACK / 旧代数丢弃：只有当前 nonce + 当前令牌才置位（P3-4）', () async {
      final bridge = newBridge();
      final nonceA = await handshake(bridge);
      final tokenA = bridge.handshakeToken;

      bridge.beginNavigation();
      await bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
      final nonceB = bridge.nonce!;
      final tokenB = bridge.handshakeToken;
      expect(nonceB, isNot(nonceA));
      expect(tokenB, greaterThan(tokenA));

      // 旧 nonce + 旧令牌
      await bridge.handleMessage(_pageMessage(
        method: 'nonceAck',
        id: '',
        args: '$tokenA',
        nonce: nonceA,
      ));
      expect(bridge.isHandshaken, isFalse, reason: '旧文档 ACK 必须丢弃');

      // 当前 nonce + 旧令牌
      await bridge.handleMessage(_pageMessage(
        method: 'nonceAck',
        id: '',
        args: '$tokenA',
        nonce: nonceB,
      ));
      expect(bridge.isHandshaken, isFalse, reason: '旧代数 ACK 必须丢弃');

      // 当前 nonce + 当前令牌
      await ack(bridge, nonceB);
      expect(bridge.isHandshaken, isTrue);
    });

    test('导航交错：旧回填晚到被丢弃，新文档 nonceB 生效', () async {
      final holders = <Completer<void>>[];
      final bridge = newBridge(runner: (js) async {
        // 只阻塞 nonce 回填，其余（如失败回填）立即完成
        if (!js.contains('__rk_')) {
          runLog.add(js);
          return;
        }
        final completer = Completer<void>();
        holders.add(completer);
        await completer.future;
        runLog.add(js);
      });
      final oldHello = bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
      await Future<void>.delayed(Duration.zero);
      final nonceA = bridge.nonce!;

      bridge.beginNavigation();
      expect(bridge.isHandshaken, isFalse);
      expect(bridge.nonce, isNull);

      final newHello = bridge.handleMessage(_pageMessage(method: 'hello', id: ''));
      await Future<void>.delayed(Duration.zero);
      final nonceB = bridge.nonce!;
      expect(nonceB, isNot(nonceA), reason: '新文档必须换发 nonceB');
      holders.last.complete();
      await newHello;
      await ack(bridge, nonceB);
      expect(bridge.isHandshaken, isTrue);

      // 旧文档回填晚到：不得覆盖 nonceB，也不得回退握手状态
      holders.first.complete();
      await oldHello;
      expect(bridge.nonce, nonceB);
      expect(bridge.isHandshaken, isTrue);

      // 旧 nonce 的消息仍被拒绝
      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        args: '["https://old"]',
        nonce: nonceA,
      ));
      await Future<void>.delayed(Duration.zero);
      verifyNever(
        () => api.rssWebViewHostCall(any(), 'getAwait', any()),
      );
    });

    test('导航看门狗总时长上限：30s 无 hello 后停止（虚拟时钟）', () {
      fakeAsync((async) {
        final clock = async.getClock(DateTime(2026, 1, 1));
        final bridge = newBridge(
          watchdog: const Duration(seconds: 4),
          // 批21f P2-2：注入单调时钟（fakeAsync 虚拟时间）
          elapsed: () => clock.now().difference(DateTime(2026, 1, 1)),
        );
        bridge.beginNavigation();
        async.elapse(const Duration(seconds: 30));
        expect(bridge.isHandshaken, isFalse);
        expect(bridge.watchdogRetries, kRssWebBridgeMaxWatchdogRetries);
        expect(bridge.isWatchdogActive, isFalse);
      });
    });
  });

  group('白名单转发', () {
    test('白名单方法 → RPC → 回调 ok=true + value', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _okEnvelope('结果'));
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: 'ajaxAwait',
        id: 'id-9',
        args: '["https://a", "9000"]',
        nonce: nonce,
      ));
      await Future<void>.delayed(Duration.zero);

      verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          'ajaxAwait',
          '["https://a", "9000"]',
        ),
      ).called(1);
      final reply = runLog.lastWhere((js) => js.contains('window["${bridge.callbackName}"]'));
      expect(reply, contains('"id-9"'));
      expect(reply, contains('true'));
      expect(reply, contains('结果'));
    });

    test('失败信封 → 回调 ok=false + error', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _errorEnvelope('网络错误'));
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        id: 'id-10',
        args: '["https://a"]',
        nonce: nonce,
      ));
      await Future<void>.delayed(Duration.zero);

      final reply = runLog.lastWhere((js) => js.contains('window["${bridge.callbackName}"]'));
      expect(reply, contains('"id-10"'));
      expect(reply, contains('false'));
      expect(reply, contains('网络错误'));
    });

    test('downloadFileAwait 在白名单内（由 Rust 返回明确不支持）', () {
      expect(kRssWebBridgeHostMethods, contains('downloadFileAwait'));
      expect(kRssWebBridgeHostMethods, contains('getStringAwait'));
    });

    test('未知方法 → 回调失败，且不发起 RPC', () async {
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: 'eval',
        id: 'id-x',
        nonce: nonce,
      ));
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => api.rssWebViewHostCall(any(), any(), any()));
      final reply = runLog.lastWhere((js) => js.contains('window["${bridge.callbackName}"]'));
      expect(reply, contains('未知宿主方法'));
    });

    test('超时（短超时）→ 回调 ok=false 超时文本，晚到结果忽略', () async {
      final completer = Completer<String>();
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) => completer.future);
      final bridge = newBridge(timeout: const Duration(milliseconds: 30));
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: 'getAwait',
        id: 'id-slow',
        args: '["https://slow"]',
        nonce: nonce,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final reply = runLog.lastWhere((js) => js.contains('window["${bridge.callbackName}"]'));
      expect(reply, contains('"id-slow"'));
      expect(reply, contains('false'));
      expect(reply, contains('超时'));

      // 晚到结果不再回填
      final count = runLog.length;
      completer.complete(_okEnvelope('late'));
      await Future<void>.delayed(Duration.zero);
      expect(runLog.length, count, reason: '超时后晚到结果必须忽略');
    });

    test('__store 写穿：sourcePut/cachePut 等原样转发且不回填', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _okEnvelope(null));
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      final before = runLog.length;

      await bridge.handleMessage(_pageMessage(
        method: '__store',
        id: 'store_1',
        args: '{"op":"sourcePut","key":"token","value":"a-1"}',
        nonce: nonce,
      ));
      await bridge.handleMessage(_pageMessage(
        method: '__store',
        id: 'store_2',
        args: '{"op":"cachePut","key":"c","value":"v"}',
        nonce: nonce,
      ));
      // __store 串行保序：等待链上两次调用完成
      await Future<void>.delayed(const Duration(milliseconds: 5));

      verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          '__store',
          '[{"op":"sourcePut","key":"token","value":"a-1"}]',
        ),
      ).called(1);
      verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          '__store',
          '[{"op":"cachePut","key":"c","value":"v"}]',
        ),
      ).called(1);
      expect(
        runLog.length,
        before,
        reason: '__store 为写穿 fire-and-forget，不回填页面',
      );
    });

    test('__store toast 动作回传 Dart', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any())).thenAnswer(
        (_) async => jsonEncode({
          'ok': true,
          'value': null,
          'error': null,
          'actions': [
            {'action': 'toast', 'text': '保存成功', 'long': true},
          ],
        }),
      );
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: '__store',
        id: 'store_3',
        args: '{"op":"toast","value":"保存成功"}',
        nonce: nonce,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(actions, hasLength(1));
      expect(actions.single.name, 'toast');
      expect(actions.single.message, '保存成功');
      expect(actions.single.isLong, isTrue);
    });

    test('__action 动作分发（java.open）', () async {
      final bridge = newBridge();
      final nonce = await handshake(bridge);
      await bridge.handleMessage(_pageMessage(
        method: '__action',
        id: 'act_1',
        args: '{"action":"open","name":"sort","url":"u","title":"t","origin":null}',
        nonce: nonce,
      ));
      expect(actions, hasLength(1));
      expect(actions.single.name, 'open');
      expect(actions.single.openName, 'sort');
      expect(actions.single.url, 'u');
    });
  });

  group('组合脚本', () {
    test('顺序：console 钩子 → 通道适配 → Rust 桥头 → 同步面 → preloadJs → 闭合', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _prepareEnvelope(script: 'RUST_HEAD_MARKER\n'));
      final bridge = newBridge();
      await bridge.prepare(userAgent: 'UA-1');
      final composed = bridge.composeInjection(
        'PRELOAD_JS_MARKER',
        includeConsoleHook: true,
      );

      final consoleIndex = composed.indexOf('__rssConsoleHooked');
      final bootstrapIndex = composed.indexOf('__lgNative');
      final rustIndex = composed.indexOf('RUST_HEAD_MARKER');
      final shimIndex = composed.indexOf('var __lgB64Chars');
      final preloadIndex = composed.indexOf('PRELOAD_JS_MARKER');
      expect(consoleIndex, greaterThanOrEqualTo(0));
      expect(bootstrapIndex, greaterThan(consoleIndex));
      expect(rustIndex, greaterThan(bootstrapIndex));
      expect(shimIndex, greaterThan(rustIndex));
      expect(preloadIndex, greaterThan(shimIndex));
      expect(composed.trimRight(), endsWith('})();'));
    });

    test('未尝试 prepare 时返回裸 preloadJs（1:1 旧行为）', () {
      final bridge = newBridge();
      expect(bridge.composeInjection('PRELOAD'), 'PRELOAD');
    });

    test('prepare 失败：注入引导式降级桩（不裸跑 preloadJs）', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _errorEnvelope('当前构建未启用 quickjs'));
      final bridge = newBridge();
      expect(await bridge.prepare(), isNull);
      expect(bridge.isDegraded, isTrue);

      final composed = bridge.composeInjection('PRELOAD_MARKER');
      expect(composed, contains('PRELOAD_MARKER'));
      expect(composed, contains('宿主桥不可用（prepare 失败或桥不可用）'));
      expect(composed, contains('base64Encode'), reason: '同步面纯函数仍应可用');
      expect(composed, isNot(contains('window.java')));
      expect(composed.trimRight(), endsWith('})();'));
    });

    test('bridgeAvailable:false（非 quickjs/空桥头）：同样走降级桩', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any())).thenAnswer(
        (_) async => _prepareEnvelope(script: '', bridgeAvailable: false),
      );
      final bridge = newBridge();
      final prepared = await bridge.prepare();
      expect(prepared, isNotNull);
      expect(prepared!.bridgeAvailable, isFalse);
      expect(bridge.isDegraded, isFalse, reason: 'prepare 本身成功，不算失败');

      final composed = bridge.composeInjection('PRELOAD_MARKER');
      expect(composed, contains('PRELOAD_MARKER'));
      expect(composed, contains('宿主桥不可用（prepare 失败或桥不可用）'),
          reason: '桥不可用时不得裸跑 preloadJs');
      expect(composed, isNot(contains('__lgNative')));
      expect(composed, contains('base64Encode'));
    });

    test('mock 返回 script:""：不得回退为裸 preloadJs', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any())).thenAnswer(
        (_) async => jsonEncode(<String, dynamic>{
          'ok': true,
          'value': <String, dynamic>{
            'script': '',
            'snapshot': <String, dynamic>{},
          },
          'error': null,
        }),
      );
      final bridge = newBridge();
      final prepared = await bridge.prepare();
      expect(prepared, isNotNull);
      expect(prepared!.bridgeAvailable, isFalse,
          reason: '缺省 bridgeAvailable 时按空 script 判不可用');

      final composed = bridge.composeInjection('PRELOAD_MARKER');
      expect(composed, contains('宿主桥不可用（prepare 失败或桥不可用）'));
    });

    test('bootstrap：删除平台通道全局、独立 nonce 回调、桥对象/回调不可枚举、队列上限 20', () {
      final script = rssBridgeBootstrapScript(
        nativeChannelName: '__lgNativeTest',
        bridgeObjectName: '__lgBridgeTest',
        callbackName: '__lgCbTest',
        nonceCallbackName: '__lgNonceTest',
        bootstrapMarkerName: '__lgBootTest',
      );
      for (final needle in [
        'delete window["__lgNativeTest"]',
        'Object.defineProperty(window, "__lgBridgeTest"',
        'Object.defineProperty(window, "__lgNonceTest"',
        'Object.defineProperty(window, "__lgBootTest"',
        'configurable: true',
        'enumerable: false',
        'var __lgMaxQueue = 20',
        '队列已满',
        '宿主桥握手超时',
        '__lgHello',
        'delete window["__lgBridgeTest"]',
        "nonceAck",
        '__lgRegisterNonceCallback',
      ]) {
        expect(script, contains(needle), reason: 'bootstrap 缺少 $needle');
      }
      // 不得把桥对象直接挂到可枚举全局；不得保留 postMessage 直通原生通道
      expect(script, isNot(contains('window["__lgBridgeTest"] = {')));
      expect(script, isNot(contains('postMessage: function (message)')));

      if (!_nodeAvailable()) {
        // 纯 Dart 向量：结构断言已在上方完成（Node 缺失时不静默 skip）
        return;
      }
      final outputs = _runBootstrapInNode(script, rerunBootstrap: script);
      expect(outputs['nativeDeleted'], isTrue);
      expect(outputs['bridgeEnumerable'], isFalse);
      expect(outputs['nonceEnumerable'], isFalse);
      expect(outputs['helloFirst'], isTrue);
      expect(outputs['flushedQueued'], 20);
      expect(outputs['overflowErrors'], 5);
      expect(outputs['nonceAckSent'], isTrue);
      expect(outputs['bridgeDeletedAfterTick'], isTrue);
      expect(outputs['helloHook'], isTrue);
      expect(outputs['helloCount'], 1,
          reason: '同文档二次注入必须被幂等标记拦截（不得重发 hello）');
      expect(outputs['markerConfigurable'], isTrue,
          reason: '批21h P1-2：窗口标记必须可删除（转移后即删除）');
      expect(outputs['markerDeletedAfterTick'], isTrue,
          reason: '窗口标记必须在首个 tick 后删除（window 上不留宿主命名）');
      expect(outputs['guardOnCallback'], isTrue,
          reason: '幂等守卫必须转移到回填回调（非 window 全局）');
      expect(outputs['helloCountAfterRerun'], 1,
          reason: 'tick 后重复注入必须由回调守卫拦截，不得重发 hello');

      final afterTick = _runBootstrapInNode(script, rerunAfterTick: true);
      expect(afterTick['markerDeletedAfterTick'], isTrue);
      expect(afterTick['guardOnCallback'], isTrue);
      expect(afterTick['helloCountAfterRerun'], 1,
          reason: '窗口标记删除后，tick 后重复注入必须由回调守卫拦截');
    });

    test('HTML 内联转义 </script（大小写不敏感）', () {
      expect(
        rssEscapeScriptBody('var a = "</script>"; var b = "</SCRIPT>";'),
        'var a = "<\\/script>"; var b = "<\\/script>";',
      );
      expect(rssEscapeScriptBody('var a = 1;'), 'var a = 1;');
    });
  });

  group('shouldOverrideUrlLoading 快照桩', () {
    test('java.get/put/getKey/getTag/getVariable 同步可用', () {
      final script = rssBridgeOverrideScript(<String, dynamic>{
        'sourceUrl': 'https://s.override/feed',
        'sourceName': '快照源',
        'sourceVariable': 'sv',
        'userAgent': 'UA-O',
        'vars': <String, String>{'token': 't1'},
      });
      for (final needle in [
        'window.__rssJava',
        'getKey',
        'getTag',
        'getVariable',
        'putVariable',
        'https://s.override/feed',
        '快照源',
      ]) {
        expect(script, contains(needle));
      }
      // 写入仅本地快照：不出现任何通道/存储调用
      expect(script, isNot(contains('postMessage')));
      expect(script, isNot(contains('__store')));
    });
  });

  group('释放', () {
    test('dispose：页面侧删除回填回调/幂等标记/nonce 回调（批21h P1-2）', () {
      final bridge = newBridge();
      bridge.dispose();
      final release = runLog.where((js) => js.contains('delete window[')).toList();
      expect(release, hasLength(1), reason: '释放必须下发一次删除脚本');
      expect(release.single, contains('delete window["${bridge.callbackName}"]'));
      expect(
        release.single,
        contains('delete window["${bridge.bootstrapMarkerName}"]'),
      );
      expect(
        release.single,
        contains('delete window["${bridge.nonceCallbackName}"]'),
      );
    });
  });

  group('Cookie 辅助', () {
    test('loginHeader 取 Cookie（大小写不敏感）', () {
      expect(
        rssBridgeCookieFromLoginHeader('{"cookie":"a=1; b=2"}'),
        'a=1; b=2',
      );
      expect(
        rssBridgeCookieFromLoginHeader('{"Cookie":"  c=3  "}'),
        'c=3',
      );
      expect(rssBridgeCookieFromLoginHeader('{"X":"1"}'), isNull);
      expect(rssBridgeCookieFromLoginHeader('not-json'), isNull);
      expect(rssBridgeCookieFromLoginHeader(null), isNull);
    });

    test('__cookieSet 透传 url/cookie', () async {
      when(() => api.rssWebViewHostCall(any(), any(), any()))
          .thenAnswer((_) async => _okEnvelope(null));
      final bridge = newBridge();
      await bridge.pushCookies(
        url: 'https://s.test/a',
        cookie: 'sid=1; t=2',
      );
      verify(
        () => api.rssWebViewHostCall(
          'https://s.test/feed',
          '__cookieSet',
          '[{"url":"https://s.test/a","cookie":"sid=1; t=2"}]',
        ),
      ).called(1);
    });
  });

  group('同步面（JS 真实执行）', () {
    final nodeAvailable = _nodeAvailable();

    test(
      '纯函数向量 + 同步网络报错（Node 实执行/纯 Dart 回退）',
      () async {
        if (!nodeAvailable) {
          // Node 缺失时不静默 skip：退化为纯 Dart 结构向量
          for (final fn in [
            '__lgBase64Encode',
            '__lgBase64Decode',
            '__lgMd5Hex',
            '__lgHexEncode',
            '__lgHexDecode',
            '__lgEncodeUri',
            '__lgSyncUnsupported',
          ]) {
            expect(kRssBridgeSyncShimBody, contains(fn), reason: '缺少 $fn');
          }
          expect(
            kRssBridgeSyncShimBody,
            contains('同步网络在当前平台不可用'),
          );
          return;
        }
        final outputs = _runSyncShimInNode();
        final java = outputs['java'] as Map<String, dynamic>;
        final network = outputs['network'] as Map<String, dynamic>;
        final logActions = outputs['logActions'] as List<dynamic>;

        // base64（UTF-8）
        expect(java['base64EncodeHello'], 'aGVsbG8=');
        expect(java['base64EncodeCjk'], '6YeN55Sf');
        expect(java['base64DecodeCjk'], '重生');
        // md5
        expect(java['md5Empty'], 'd41d8cd98f00b204e9800998ecf8427e');
        expect(java['md5Hello'], '5d41402abc4b2a76b9719d911017c592');
        expect(java['md5Hex16'], 'bc4b2a76b9719d91');
        // hex
        expect(java['hexEncodeCjk'], 'e9878de7949f');
        expect(java['hexDecodeCjk'], '重生');
        // Java URLEncoder 语义（空格 -> +，保留 -._*，~ 编码）
        expect(java['encodeUriCjk'], '%E9%87%8D%E7%94%9F');
        expect(java['encodeUriReserved'], 'a+b%26c%7E*');
        // UA / 单参 get 回落
        expect(java['userAgent'], 'UA-Sync');
        expect(java['sourceGet'], 'V:token');
        // 同步网络全部明确抛错并 log
        for (final name in [
          'ajax',
          'connect',
          'post',
          'head',
          'webView',
          'webViewGetSource',
          'get',
        ]) {
          expect(
            network[name],
            contains('同步网络在当前平台不可用'),
            reason: 'java.$name 必须抛平台不可用错误',
          );
        }
        expect(logActions, isNotEmpty);
        expect(
          logActions.any(
            (item) =>
                item is Map &&
                item['action'] == 'log' &&
                item['message'].toString().contains('java.ajax'),
          ),
          isTrue,
        );
      },
    );

    test(
      '动作通道：java.log/toast/open/... 各发出一条动作（Node 实执行 + Dart 分发）',
      () async {
        // 批21h P1-1 回归守卫：同步面**不得**再声明同名两参
        // `function __lgEmitAction`（会遮蔽桥头单参实现 → 自递归 → 动作丢失）
        expect(
          kRssBridgeSyncShimBody,
          isNot(contains('function __lgEmitAction')),
          reason: '同步面不得声明与桥头同名的 __lgEmitAction',
        );
        expect(kRssBridgeSyncShimBody, contains('function __lgActionEmit'));
        expect(
          kRssBridgeSyncShimBody,
          isNot(contains("__lgEmitAction('")),
          reason: '同步面不得以两参形式调用桥头的 __lgEmitAction',
        );

        if (!nodeAvailable) {
          // Node 缺失时保留结构断言（不静默 skip）
          return;
        }
        final outputs = _runSyncShimInNode();
        final logActions = outputs['logActions'] as List<dynamic>;
        final payloads = logActions.whereType<Map>().toList();

        Map<String, dynamic> single(String action, {String? message}) {
          final matches = payloads.where((item) {
            if (item['action'] != action) return false;
            if (message != null && item['message'] != message) return false;
            return true;
          }).toList();
          expect(
            matches,
            hasLength(1),
            reason: '$action/${message ?? ''} 必须恰好发送一次（实际 ${matches.length}）',
          );
          return Map<String, dynamic>.from(matches.single);
        }

        expect(single('log', message: 'L1')['message'], 'L1');
        expect(single('toast', message: 'T1')['long'], isFalse);
        expect(single('toast', message: 'LT1')['long'], isTrue);
        final open = single('open');
        expect(open['name'], 'sort');
        expect(open['url'], 'https://u');
        expect(open['title'], 'title');
        expect(open['origin'], 'origin');
        expect(single('searchBook')['key'], 'K1');
        expect(single('addBook')['url'], 'https://b');
        expect(single('showPhoto')['src'], 'https://p');
        expect(single('openUrl')['url'], 'https://o');

        // 组件级：把 Node 实际产出的动作载荷按 `__action` 协议喂给 Dart，
        // 断言 onAction 回调收到同名动作（模拟页面 → 通道 → 桥分发）
        final bridge = newBridge();
        final nonce = await handshake(bridge);
        var index = 0;
        for (final payload in payloads) {
          await bridge.handleMessage(_pageMessage(
            method: '__action',
            id: 'act_${index++}',
            args: jsonEncode(payload),
            nonce: nonce,
          ));
        }
        expect(actions, hasLength(payloads.length));
        expect(
          actions.map((action) => action.name).toList(),
          payloads.map((item) => item['action'].toString()).toList(),
        );
        expect(actions.first.name, 'log');
        expect(actions.first.message, contains('java.ajax'));
      },
    );

    test('同步面脚本不使用通道/RPC（纯函数摊平）', () {
      final script = rssBridgeSyncShimScript(
        bridgeObjectName: '__rsBridge_x',
        userAgent: 'UA',
      );
      for (final name in [
        'base64Encode',
        'base64Decode',
        'md5Encode',
        'md5Encode16',
        'hexEncodeToString',
        'hexDecodeToString',
        'encodeURI',
        'getWebViewUA',
        'open',
        'searchBook',
        'addBook',
        'showPhoto',
        'openUrl',
      ]) {
        expect(script, contains(name), reason: '同步面缺少 $name');
      }
      // 纯函数绑定段不发起 RPC（动作段才使用通道）
      final pureSection = kRssBridgeSyncShimBody.substring(
        0,
        kRssBridgeSyncShimBody.indexOf('// ── 动作摊平'),
      );
      expect(pureSection, isNot(contains('.request(')));
      expect(pureSection, isNot(contains('postMessage')));
    });
  });
}

// ─── Node 执行辅助（仅开发/CI 环境有 node 时启用） ───────────────────────────

bool _nodeAvailable() {
  try {
    final result = Process.runSync('node', ['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 在 Node 中执行 bootstrap（模拟页面全局 + 平台通道），返回结构化断言值
///
/// 覆盖批21c P0-1/P0-3：平台通道全局删除、桥对象/回调不可枚举、队列上限、
/// 非枚举 hello 重发入口、定时清理；批21e P3-1：同文档二次注入幂等。
Map<String, dynamic> _runBootstrapInNode(
  String bootstrap, {
  String? rerunBootstrap,
  bool rerunAfterTick = false,
}) {
  final harness = r'''
var window = {};
var posted = [];
var replies = [];
window['__lgNativeTest'] = {
  postMessage: function (m) { posted.push(JSON.parse(m)); }
};
window['__lgCbTest'] = function (id, ok, payload) {
  replies.push({ id: id, ok: ok, payload: payload });
};
''' +
      bootstrap +
      r'''
var nativeDeleted = typeof window['__lgNativeTest'] === 'undefined';
''' +
      (rerunBootstrap == null
          ? ''
          : r'''
// 模拟平台在同一文档重新注入通道对象后，bootstrap 被二次执行
window['__lgNativeTest'] = {
  postMessage: function (m) { posted.push(JSON.parse(m)); }
};
''' +
              rerunBootstrap) +
      r'''
var bridgeDesc = Object.getOwnPropertyDescriptor(window, '__lgBridgeTest');
var nonceDesc = Object.getOwnPropertyDescriptor(window, '__lgNonceTest');
var markerDesc = Object.getOwnPropertyDescriptor(window, '__lgBootTest');
var helloCount = posted.filter(function (m) { return m.method === 'hello'; }).length;
for (var i = 0; i < 25; i++) {
  window['__lgBridgeTest'].request('q' + i, '[]', 'q' + i);
}
var overflowErrors = replies.length;
window['__lgNonceTest']('n1', 1);
var helloFirst = posted.length > 0 && posted[0].method === 'hello';
var flushedQueued = posted.filter(function (m) {
  return m.method !== 'hello' && m.method !== 'nonceAck';
}).length;
var nonceAckSent = posted.some(function (m) { return m.method === 'nonceAck'; });
setTimeout(function () {
  // 批21h P1-2：窗口标记必须在首个 tick 后删除（getOwnPropertyNames 不可见），
  // 幂等守卫转移到回填回调上的非枚举属性。
  var markerDeletedAfterTick = typeof window['__lgBootTest'] === 'undefined';
  var guardOnCallback = !!(window['__lgCbTest'] &&
    window['__lgCbTest'].__lgBridgeInstalled === 1);
  var helloCountAfterRerun = helloCount;
''' +
      (rerunAfterTick
          ? r'''
  // tick 之后再次注入（窗口标记已删）：必须由回调上的守卫拦截，不得重发 hello
  window['__lgNativeTest'] = {
    postMessage: function (m) { posted.push(JSON.parse(m)); }
  };
''' +
              bootstrap +
              r'''
  helloCountAfterRerun = posted.filter(function (m) { return m.method === 'hello'; }).length;
'''
          : '') +
      r'''
  process.stdout.write(JSON.stringify({
    nativeDeleted: nativeDeleted,
    bridgeEnumerable: bridgeDesc ? bridgeDesc.enumerable : null,
    nonceEnumerable: nonceDesc ? nonceDesc.enumerable : null,
    markerConfigurable: markerDesc ? markerDesc.configurable : null,
    markerDeletedAfterTick: markerDeletedAfterTick,
    guardOnCallback: guardOnCallback,
    helloCount: helloCount,
    helloCountAfterRerun: helloCountAfterRerun,
    helloFirst: helloFirst,
    flushedQueued: flushedQueued,
    overflowErrors: overflowErrors,
    nonceAckSent: nonceAckSent,
    bridgeDeletedAfterTick: typeof window['__lgBridgeTest'] === 'undefined',
    helloHook: typeof window['__lgCbTest'].__lgHello === 'function'
  }));
  process.exit(0);
}, 10);
''';

  final dir = Directory.systemTemp.createTempSync('rss_bridge_bootstrap_');
  try {
    final file = File('${dir.path}${Platform.pathSeparator}bootstrap.js')
      ..writeAsStringSync(harness);
    final result = Process.runSync(
      'node',
      [file.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    expect(
      result.exitCode,
      0,
      reason: 'Node 执行 bootstrap 失败：${result.stderr}',
    );
    final decoded = jsonDecode(result.stdout as String);
    expect(decoded, isA<Map>());
    return Map<String, dynamic>.from(decoded as Map);
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响用例
    }
  }
}

/// 在 Node 中执行 `kRssBridgeSyncShimBody`，返回结构化结果
///
/// 批21h P1-1：外层用**单参** `__lgEmitAction(payload)`（与 Rust 桥头/降级桩
/// 同签名）复刻桥的外层包装器 `__lgAction`；修复前同步面内的同名两参函数
/// 声明会提升并遮蔽它，导致 `__lgAction` 自递归、`RangeError` 被吞、动作
/// 永远发不出去（`actions` 为空）。
Map<String, dynamic> _runSyncShimInNode() {
  final harness = r'''
var __lgActions = [];
var __lgJava = {
  get: function (key) { return 'V:' + String(key); }
};
// 与 Rust 桥头 `function __lgEmitAction(payload)` 同签名（单参）
function __lgEmitAction(payload) { __lgActions.push(payload); }
// 与 rssBridgeSyncShimScript 的外层包装器同形
var __lgAction = function (payload) {
  try {
    if (typeof __lgEmitAction === 'function') {
      __lgEmitAction(payload || {});
    }
  } catch (e) {}
};
var __lgUserAgent = 'UA-Sync';
''' +
      kRssBridgeSyncShimBody +
      r'''
var network = {};
var calls = [
  ['ajax', function () { return __lgJava.ajax('https://x'); }],
  ['connect', function () { return __lgJava.connect('https://x'); }],
  ['post', function () { return __lgJava.post('https://x', 'b'); }],
  ['head', function () { return __lgJava.head('https://x'); }],
  ['webView', function () { return __lgJava.webView('h'); }],
  ['webViewGetSource', function () { return __lgJava.webViewGetSource('h'); }],
  ['get', function () { return __lgJava.get('https://x', '{}'); }]
];
for (var i = 0; i < calls.length; i++) {
  try {
    calls[i][1]();
    network[calls[i][0]] = 'no-throw';
  } catch (e) {
    network[calls[i][0]] = String(e && e.message ? e.message : e);
  }
}
// 批21h P1-1：动作面每次调用必须产出一条动作消息（不得互相遮蔽/递归）
var actionCalls = [
  ['log', function () { return __lgJava.log('L1'); }],
  ['toast', function () { return __lgJava.toast('T1'); }],
  ['longToast', function () { return __lgJava.longToast('LT1'); }],
  ['open', function () { return __lgJava.open('sort', 'https://u', 'title', 'origin'); }],
  ['searchBook', function () { return __lgJava.searchBook('K1', 'S1'); }],
  ['addBook', function () { return __lgJava.addBook('https://b'); }],
  ['showPhoto', function () { return __lgJava.showPhoto('https://p'); }],
  ['openUrl', function () { return __lgJava.openUrl('https://o'); }]
];
var actionReturns = {};
for (var j = 0; j < actionCalls.length; j++) {
  actionReturns[actionCalls[j][0]] = actionCalls[j][1]();
}
process.stdout.write(JSON.stringify({
  java: {
    base64EncodeHello: __lgJava.base64Encode('hello'),
    base64EncodeCjk: __lgJava.base64Encode('重生'),
    base64DecodeCjk: __lgJava.base64Decode('6YeN55Sf'),
    md5Empty: __lgJava.md5Encode(''),
    md5Hello: __lgJava.md5Encode('hello'),
    md5Hex16: __lgJava.md5Encode16('hello'),
    hexEncodeCjk: __lgJava.hexEncodeToString('重生'),
    hexDecodeCjk: __lgJava.hexDecodeToString('e9878de7949f'),
    encodeUriCjk: __lgJava.encodeURI('重生'),
    encodeUriReserved: __lgJava.encodeURI('a b&c~*'),
    userAgent: __lgJava.getWebViewUA(),
    sourceGet: __lgJava.get('token')
  },
  network: network,
  actionReturns: actionReturns,
  logActions: __lgActions
}));
''';

  final dir = Directory.systemTemp.createTempSync('rss_bridge_js_');
  try {
    final file = File('${dir.path}${Platform.pathSeparator}sync_shim.js')
      ..writeAsStringSync(harness);
    // Node 在中文 Windows 下默认系统编码为 GBK；显式按 UTF-8 解码，
    // 避免 CJK 向量被误判（CI 为 UTF-8 环境，同样安全）
    final result = Process.runSync(
      'node',
      [file.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    expect(
      result.exitCode,
      0,
      reason: 'Node 执行同步面失败：${result.stderr}',
    );
    final decoded = jsonDecode(result.stdout as String);
    expect(decoded, isA<Map>());
    return Map<String, dynamic>.from(decoded as Map);
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响用例
    }
  }
}
