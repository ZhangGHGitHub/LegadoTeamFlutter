// 崩溃日志分类回归测试（MuMu 冒烟 2026-09-20 误报修复）
//
// 缺陷：debug 模式下的非致命布局告警（RenderFlex 右溢 12px，
// "A RenderFlex overflowed by 12 pixels on the right."）经
// main.dart 的 FlutterError.onError → CrashLogService.logError 被写入
// crash_log.txt 并置崩溃标记 crash_last_crash → 下次冷启动
// getLastCrashLog 非空 → LegadoApp.scheduleCrashLogDialog 弹出
// 「上次运行发生崩溃」（日志无堆栈段、无「查看详情」按钮）。
// 确定性验证：确定 → force-stop → 冷启动 → 无弹窗、应用正常。
//
// 修复：logError 先经 [CrashLogService.isSoftWarning] 识别已知软性告警，
// 软性告警只写普通日志（内存日志 + app_log.txt 打「[布局告警]」标记），
// 不写崩溃记录、不置崩溃标记 → 下次启动不弹窗；
// 真崩溃（如 StateError/未捕获异常）行为保持不变。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/crash_log_service.dart';

void main() {
  late Directory tempDir;
  late File crashFile;
  late FlutterExceptionHandler? previousOnError;

  // 与生产 main.dart L27-29 完全一致的处理器（复刻点）
  void installProductionHandler() {
    previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      CrashLogService.instance.logError(details.exception, details.stack);
    };
  }

  void restoreProductionHandler() {
    FlutterError.onError = previousOnError;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('crash_class_test');
    crashFile = File('${tempDir.path}/crash_log.txt');
    // 测试环境无平台通道，经接缝注入临时崩溃日志文件
    CrashLogService.instance.setCrashLogFileForTest(crashFile);
  });

  tearDown(() async {
    restoreProductionHandler();
    CrashLogService.instance.clearLogs();
    await tempDir.delete(recursive: true);
  });

  /// 冲刷 SharedPreferences mock 上已注册的 .then 回调（FIFO 微任务序），
  /// 保证 logError 内部的 setBool 崩溃标记已完成。
  Future<void> flushPrefs() async {
    await SharedPreferences.getInstance();
  }

  test('RenderFlex 溢出经全局处理器：不产生崩溃记录、不置崩溃标记', () async {
    installProductionHandler();
    // 复刻框架 debug 模式报告 RenderFlex 溢出的路径：
    // FlutterError.reportError(FlutterErrorDetails(...))
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: FlutterError(
          'A RenderFlex overflowed by 12 pixels on the right.\n'
              'The relevant error-causing widget was:\n'
              '  Row Row',
        ),
        stack: StackTrace.current,
      ),
    );
    restoreProductionHandler();
    await flushPrefs();

    // 1) 软性布局告警不写 crash_log.txt
    expect(crashFile.existsSync(), isFalse,
        reason: '软性布局告警不应写入 crash_log.txt');
    // 2) 不置崩溃标记 → 下次启动 getLastCrashLog 为 null，不弹窗
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('crash_last_crash'), isNot(true),
        reason: '软性布局告警不应置崩溃标记（否则会误弹崩溃弹窗）');
    expect(await CrashLogService.instance.getLastCrashLog(), isNull,
        reason: '软性告警后下次启动不应取到崩溃日志');
    // 3) 已单独标记写入普通日志（可观测，不静默丢失）
    expect(
      CrashLogService.instance.logs.any((e) {
        if (!e.message.startsWith('[布局告警]')) return false;
        final error = e.error;
        return error is FlutterError &&
            error.message.contains('A RenderFlex overflowed by');
      }),
      isTrue,
      reason: '软性告警应打 [布局告警] 标记写入普通日志',
    );
  });

  test('真异常经全局处理器：崩溃记录与崩溃标记按原语义保留', () async {
    installProductionHandler();
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('boom'),
        stack: StackTrace.current,
      ),
    );
    restoreProductionHandler();
    await flushPrefs();

    // 1) 真崩溃仍写 crash_log.txt（格式不变）
    expect(crashFile.existsSync(), isTrue, reason: '真崩溃必须写崩溃日志文件');
    final content = crashFile.readAsStringSync();
    expect(content, contains('===== 崩溃日志 ====='));
    // StateError.toString() → "Bad state: boom"
    expect(content, contains('错误: Bad state: boom'));
    expect(content, contains('----- 堆栈信息 -----'));
    expect(content, contains('===== 日志结束 ====='));
    // 2) 崩溃标记已置位（下次启动 getLastCrashLog 非空 → 正常弹窗语义）
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('crash_last_crash'), isTrue,
        reason: '真崩溃必须置崩溃标记');
    expect(CrashLogService.instance.lastCrash, isTrue);
    expect(
      (await CrashLogService.instance.getLastCrashLog()),
      contains('错误: Bad state: boom'),
      reason: '下次启动应能取到该崩溃日志（弹窗链路不变）',
    );
  });

  test('isSoftWarning：RenderFlex 溢出判为软性告警，其他异常判为崩溃', () {
    // FlutterError（框架诊断，message 携带溢出文本）
    expect(
      CrashLogService.isSoftWarning(
        FlutterError('A RenderFlex overflowed by 12 pixels on the right.'),
      ),
      isTrue,
    );
    // 非 FlutterError 但 toString 携带溢出特征（防御性分支）
    expect(
      CrashLogService.isSoftWarning(
        Exception('A RenderFlex overflowed by 3 pixels on the bottom.'),
      ),
      isTrue,
    );
    // 普通异常 / 其他框架错误 → 真崩溃
    expect(CrashLogService.isSoftWarning(StateError('boom')), isFalse);
    expect(
      CrashLogService.isSoftWarning(FlutterError('Null check operator used')),
      isFalse,
    );
  });
}
