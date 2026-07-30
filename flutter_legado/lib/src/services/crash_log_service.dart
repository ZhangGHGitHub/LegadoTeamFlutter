import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 崩溃日志服务
///
/// 参考 Android 原版 [CrashHandler] 的设计思路，
/// 负责捕获异常信息并持久化到本地文件，便于后续诊断。
class CrashLogService {
  CrashLogService._();

  /// 单例实例
  static final CrashLogService instance = CrashLogService._();

  /// 崩溃日志文件
  File? _crashLogFile;

  /// 普通日志文件
  File? _messageLogFile;

  /// 上次是否发生崩溃（内存标记，应用重启后重置）
  bool _lastCrash = false;

  /// 上次运行是否发生了崩溃
  bool get lastCrash => _lastCrash;

  // ===== 初始化 =====

  /// 初始化日志文件路径
  ///
  /// 使用 [getApplicationDocumentsDirectory] 下的 `crash_log.txt` 作为崩溃日志，
  /// `app_log.txt` 作为普通消息日志。
  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _crashLogFile = File('${dir.path}/crash_log.txt');
    _messageLogFile = File('${dir.path}/app_log.txt');
  }

  // ===== 崩溃日志 =====

  /// 记录错误信息（覆盖写入，仅保留最近一次崩溃）
  ///
  /// [error] 异常对象
  /// [stack] 堆栈信息（可选）
  void logError(Object error, StackTrace? stack) {
    final file = _crashLogFile;
    if (file == null) return;

    final buffer = StringBuffer()
      ..writeln('===== 崩溃日志 =====')
      ..writeln('时间: ${_formatTime(DateTime.now())}')
      ..writeln('错误: $error');

    if (stack != null) {
      buffer
        ..writeln('----- 堆栈信息 -----')
        ..writeln(stack.toString());
    }

    buffer.writeln('===== 日志结束 =====');

    try {
      file.writeAsStringSync(buffer.toString());
      _lastCrash = true;
    } catch (_) {
      // 写入失败时静默忽略，避免二次异常
    }
  }

  /// 读取上次崩溃日志内容
  ///
  /// 返回日志文本，若无日志文件则返回 null
  Future<String?> getLastCrashLog() async {
    final file = _crashLogFile;
    if (file == null) return null;

    try {
      if (await file.exists()) {
        final content = await file.readAsString();
        return content.isEmpty ? null : content;
      }
    } catch (_) {
      // 读取失败时返回 null
    }
    return null;
  }

  /// 删除崩溃日志文件
  Future<void> clearCrashLog() async {
    final file = _crashLogFile;
    if (file == null) return;

    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 删除失败时静默忽略
    }
  }

  // ===== 普通消息日志 =====

  /// 写入普通日志消息（追加模式）
  ///
  /// [message] 日志内容
  void logMessage(String message) {
    final file = _messageLogFile;
    if (file == null) return;

    final line = '[${_formatTime(DateTime.now())}] $message\n';

    try {
      file.writeAsStringSync(line, mode: FileMode.append);
    } catch (_) {
      // 写入失败时静默忽略
    }
  }

  // ===== 内部工具 =====

  /// 格式化时间戳
  String _formatTime(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final M = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$y-$M-$d $h:$m:$s';
  }
}
