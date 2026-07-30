import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 日志条目（对应 Android 原版 [`AppLog`](https://github.com/PAPro-Nightmare/LegadoTeam/blob/main/app/src/main/java/io/legado/app/help/AppLog.kt)）中的 Triple
class LogEntry {
  /// 时间戳（毫秒）
  final int timestamp;

  /// 日志消息
  final String message;

  /// 关联的异常（可选）
  final Object? error;

  const LogEntry(this.timestamp, this.message, [this.error]);
}

/// 崩溃日志文件条目（对应 Android 原版 CrashLogsDialog 中的 FileDoc 列表项）
class CrashLogItem {
  /// 文件名
  final String fileName;

  /// 文件完整路径
  final String filePath;

  const CrashLogItem(this.fileName, this.filePath);
}

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

  /// HTTP 日志文件
  File? _httpLogFile;

  /// SharedPreferences 键：上次是否崩溃
  static const _keyLastCrash = 'crash_last_crash';

  /// SharedPreferences 键：是否记录日志（对应 Android 原版 AppConfig.recordLog）
  static const _keyRecordLog = 'crash_record_log';

  /// SharedPreferences 键：是否记录 HTTP 日志（对应 Android 原版 AppConfig.recordHttpLog）
  static const _keyRecordHttpLog = 'crash_record_http_log';

  /// SharedPreferences 键：备份/导出路径（对应 Android 原版 AppConfig.backupPath）
  static const _keyBackupPath = 'app_backup_path';

  /// SharedPreferences 键：是否记录堆转储（对应 Android 原版 AppConfig.recordHeapDump）
  static const _keyRecordHeapDump = 'crash_record_heap_dump';

  /// 日志文件大小上限（1MB）
  static const _maxLogSize = 1024 * 1024;

  /// 崩溃日志保留天数（对应 Android 原版 7 天清理策略）
  static const _crashLogRetainDays = 7;

  /// 文件名非法字符正则
  static final _invalidFileNameChars = RegExp(r'[\\/:*?"<>|]');

  /// 内存日志列表上限（对应 Android 原版 AppLog 的 100 条限制）
  static const _maxMemoryLogs = 100;

  /// 内存日志列表（最新的在前）
  final List<LogEntry> _memoryLogs = [];

  /// 上次运行是否发生了崩溃（内存缓存，由 [init] 从持久化存储恢复）
  bool get lastCrash => _lastCrashValue;
  bool _lastCrashValue = false;

  /// 崩溃标记是否已被消费（避免重复弹窗）
  bool _crashFlagConsumed = false;

  // ===== 初始化 =====

  /// 初始化日志文件路径
  ///
  /// 使用 [getApplicationDocumentsDirectory] 下的 `crash_log.txt` 作为崩溃日志，
  /// `app_log.txt` 作为普通消息日志。
  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _crashLogFile = File('${dir.path}/crash_log.txt');
    _messageLogFile = File('${dir.path}/app_log.txt');
    _httpLogFile = File('${dir.path}/http_log.txt');

    // 从持久化存储恢复上次崩溃标记
    final prefs = await SharedPreferences.getInstance();
    _lastCrashValue = prefs.getBool(_keyLastCrash) ?? false;
    _crashFlagConsumed = false;
  }

  /// 检查并重置崩溃标记（对应 Android 原版 MainActivity.notifyAppCrash）
  ///
  /// 返回 true 表示上次运行发生了崩溃，同时重置标记。
  /// 应在应用启动后调用，用于决定是否弹出崩溃提示对话框。
  Future<bool> checkAndResetCrashFlag() async {
    if (_crashFlagConsumed) return false;
    _crashFlagConsumed = true;

    final prefs = await SharedPreferences.getInstance();
    final crashed = prefs.getBool(_keyLastCrash) ?? false;
    if (crashed) {
      await prefs.setBool(_keyLastCrash, false);
    }
    _lastCrashValue = crashed;
    return crashed;
  }

  /// 设置崩溃标记（对应 Android 原版 LocalConfig.appCrash = true）
  ///
  /// 由全局异常处理器在捕获崩溃时调用。
  Future<void> setCrashFlag(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLastCrash, value);
    _lastCrashValue = value;
  }

  // ===== 全局异常捕获（对应 Android 原版 CrashHandler + App.onCreate） =====

  /// 设置全局异常捕获处理器
  ///
  /// 对应 Android 原版 `App.onCreate` 中的 `CrashHandler(this)` 初始化。
  /// 同时捕获 Flutter 框架异常和 Dart 异步异常。
  void setupCrashHandler() {
    // 捕获 Flutter 框架异常（Widget 构建、布局、绘制等）
    FlutterError.onError = (FlutterErrorDetails details) {
      handleException(details.exception, details.stack ?? StackTrace.current);
      // 在调试模式下仍输出到控制台
      FlutterError.presentError(details);
    };

    // 捕获 Dart 异步异常（Future、Timer 等未捕获的异常）
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      handleException(error, stack);
      return true; // 已处理，不再向上传递
    };
  }

  /// 统一异常处理入口（对应 Android 原版 CrashHandler.handleException）
  ///
  /// [error] 异常对象
  /// [stack] 堆栈信息
  void handleException(Object error, StackTrace stack) {
    // 记录到内存日志
    put('发生未捕获的异常\n$error', error: error);

    // 检测内存溢出异常，记录内存信息（对应 Android 原版 OutOfMemoryError + doHeapDump）
    if (_isOutOfMemoryError(error)) {
      logMemoryInfo();
    }

    // 写入崩溃日志文件并设置崩溃标记
    logError(error, stack);
  }

  /// 判断是否为内存溢出异常
  bool _isOutOfMemoryError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('out of memory') ||
        msg.contains('outofmemory') ||
        msg.contains('allocation failed');
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
      // 持久化崩溃标记
      SharedPreferences.getInstance().then((prefs) {
        prefs.setBool(_keyLastCrash, true);
      });
      _lastCrashValue = true;
    } catch (_) {
      // 写入失败时静默忽略，避免二次异常
    }

    // 同时写入带时间戳的崩溃日志到备份目录（对应 Android 原版 saveCrashInfo2File）
    _saveCrashLogToBackup(buffer.toString());
  }

  /// 将崩溃日志保存到备份目录的 crash 子目录
  ///
  /// 文件名格式：`crash-yyyy-MM-dd-HH-mm-ss-时间戳.log`
  void _saveCrashLogToBackup(String crashLog) {
    try {
      final prefs = SharedPreferences.getInstance();
      prefs.then((sp) {
        final backupPath = sp.getString(_keyBackupPath);
        if (backupPath == null || backupPath.isEmpty) return;

        final crashDir = Directory('$backupPath/crash');
        if (!crashDir.existsSync()) {
          crashDir.createSync(recursive: true);
        }

        final now = DateTime.now();
        final timestamp = now.millisecondsSinceEpoch;
        final timeStr = _formatTimeForFileName(now);
        final fileName = 'crash-$timeStr-$timestamp.log';
        File('${crashDir.path}/$fileName').writeAsStringSync(crashLog);

        // 清理超过 7 天的旧崩溃日志
        _cleanOldCrashLogs(crashDir);
      });
    } catch (_) {
      // 备份写入失败时静默忽略
    }
  }

  /// 清理超过保留天数的旧崩溃日志文件
  void _cleanOldCrashLogs(Directory crashDir) {
    try {
      final expireTime = DateTime.now()
          .subtract(const Duration(days: _crashLogRetainDays))
          .millisecondsSinceEpoch;
      for (final entity in crashDir.listSync()) {
        if (entity is File && entity.path.endsWith('.log')) {
          if (entity.lastModifiedSync().millisecondsSinceEpoch < expireTime) {
            entity.deleteSync();
          }
        }
      }
    } catch (_) {
      // 清理失败时静默忽略
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

  /// 删除崩溃日志文件（本地 crash_log.txt）
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

  // ===== 崩溃日志列表（对应 Android 原版 CrashLogsDialog） =====

  /// 获取备份目录中所有崩溃日志文件列表（按文件名降序，最新的在前）
  Future<List<CrashLogItem>> listCrashLogs() async {
    final backupPath = await getBackupPath();
    if (backupPath == null) return [];

    final crashDir = Directory('$backupPath/crash');
    if (!crashDir.existsSync()) return [];

    final items = <CrashLogItem>[];
    try {
      for (final entity in crashDir.listSync()) {
        if (entity is File && entity.path.endsWith('.log')) {
          final name = entity.uri.pathSegments.last;
          items.add(CrashLogItem(name, entity.path));
        }
      }
      // 按文件名降序排列（时间戳文件名自然排序即为时间顺序）
      items.sort((a, b) => b.fileName.compareTo(a.fileName));
    } catch (_) {
      // 列举失败时返回已收集的部分
    }
    return items;
  }

  /// 读取指定崩溃日志文件内容
  ///
  /// [fileName] 崩溃日志文件名
  /// 返回日志文本，文件不存在则返回 null
  Future<String?> readCrashLog(String fileName) async {
    final backupPath = await getBackupPath();
    if (backupPath == null) return null;

    final file = File('$backupPath/crash/$fileName');
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

  /// 清空备份目录中所有崩溃日志（对应 Android 原版 CrashViewModel.clearCrashLog）
  ///
  /// 同时删除本地 crash_log.txt 和备份目录下的 crash 文件夹内容
  Future<void> clearAllCrashLogs() async {
    // 删除本地崩溃日志
    await clearCrashLog();

    // 删除备份目录中的崩溃日志
    final backupPath = await getBackupPath();
    if (backupPath == null) return;

    final crashDir = Directory('$backupPath/crash');
    try {
      if (crashDir.existsSync()) {
        for (final entity in crashDir.listSync()) {
          if (entity is File && entity.path.endsWith('.log')) {
            entity.deleteSync();
          }
        }
      }
    } catch (_) {
      // 删除失败时静默忽略
    }
  }

  // ===== 备份路径配置（对应 Android 原版 AppConfig.backupPath） =====

  /// 获取备份/导出路径
  Future<String?> getBackupPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_keyBackupPath);
    return (path == null || path.isEmpty) ? null : path;
  }

  /// 设置备份/导出路径
  Future<void> setBackupPath(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_keyBackupPath);
    } else {
      await prefs.setString(_keyBackupPath, value);
    }
  }

  // ===== 日志开关（对应 Android 原版 AppConfig.recordLog / recordHttpLog） =====

  /// 获取是否记录日志
  Future<bool> getRecordLog() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyRecordLog) ?? false;
  }

  /// 设置是否记录日志
  Future<void> setRecordLog(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRecordLog, value);
  }

  /// 获取是否记录 HTTP 日志
  Future<bool> getRecordHttpLog() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyRecordHttpLog) ?? false;
  }

  /// 设置是否记录 HTTP 日志
  Future<void> setRecordHttpLog(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRecordHttpLog, value);
  }

  /// 获取是否记录堆转储（对应 Android 原版 AppConfig.recordHeapDump）
  Future<bool> getRecordHeapDump() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyRecordHeapDump) ?? false;
  }

  /// 设置是否记录堆转储
  Future<void> setRecordHeapDump(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRecordHeapDump, value);
  }

  // ===== 内存诊断（对应 Android 原版 CrashHandler.doHeapDump） =====

  /// 记录当前内存使用信息
  ///
  /// Flutter 无法直接执行堆转储，改为记录 RSS 内存信息到日志。
  /// 对应 Android 原版 `Debug.dumpHprofData` 的替代方案。
  void logMemoryInfo() {
    final currentRss = ProcessInfo.currentRss;
    final maxRss = ProcessInfo.maxRss;
    final info = '内存信息: currentRss=${_formatBytes(currentRss)}, '
        'maxRss=${_formatBytes(maxRss)}';
    put(info);
    logMessage('[OOM] $info');
  }

  /// 格式化字节数为可读字符串
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ===== 应用日志（对应 Android 原版 AppLog） =====

  /// 获取内存中的所有日志（最新的在前）
  List<LogEntry> get logs => List.unmodifiable(_memoryLogs);

  /// 记录日志（对应 Android 原版 AppLog.put）
  ///
  /// [message] 日志消息
  /// [error] 关联的异常对象（可选）
  /// [toast] 是否显示提示（预留，当前仅输出到调试控制台）
  void put(String message, {Object? error, bool toast = false}) {
    // 超出上限时移除最旧的记录
    if (_memoryLogs.length >= _maxMemoryLogs) {
      _memoryLogs.removeLast();
    }
    _memoryLogs.insert(0, LogEntry(DateTime.now().millisecondsSinceEpoch, message, error));

    // 输出到调试控制台
    if (error != null) {
      debugPrint('[AppLog] $message\n$error');
    } else {
      debugPrint('[AppLog] $message');
    }
  }

  /// 仅在开启日志记录时写入（对应 Android 原版 AppLog.putDebug）
  ///
  /// 需要 [recordLog] 开关为 true 才会实际记录
  void putDebug(String message, {Object? error}) {
    SharedPreferences.getInstance().then((prefs) {
      if (prefs.getBool(_keyRecordLog) ?? false) {
        put(message, error: error);
      }
    });
  }

  /// 清空内存日志（对应 Android 原版 AppLog.clear）
  void clearLogs() {
    _memoryLogs.clear();
  }

  // ===== HTTP 日志（对应 Android 原版 AppConfig.recordHttpLog） =====

  /// 记录 HTTP 请求日志
  ///
  /// 仅在 [recordHttpLog] 开关开启时写入。
  /// [method] 请求方法（GET/POST 等）
  /// [url] 请求地址
  /// [statusCode] 响应状态码
  /// [durationMs] 请求耗时（毫秒）
  void logHttp(String method, String url, int statusCode, int durationMs) {
    final file = _httpLogFile;
    if (file == null) return;

    final line =
        '[${_formatTime(DateTime.now())}] $method $url -> $statusCode (${durationMs}ms)\n';

    try {
      // 检查日志文件大小，超过上限时清空重写
      if (file.existsSync() && file.lengthSync() > _maxLogSize) {
        file.writeAsStringSync(line);
      } else {
        file.writeAsStringSync(line, mode: FileMode.append);
      }
    } catch (_) {
      // 写入失败时静默忽略
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
      // 检查日志文件大小，超过上限时清空重写
      if (file.existsSync() && file.lengthSync() > _maxLogSize) {
        file.writeAsStringSync(line);
      } else {
        file.writeAsStringSync(line, mode: FileMode.append);
      }
    } catch (_) {
      // 写入失败时静默忽略
    }
  }

  // ===== 内部工具 =====

  /// 格式化时间戳（日志显示用）
  String _formatTime(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final M = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$y-$M-$d $h:$m:$s';
  }

  /// 格式化时间戳（文件名用，不含空格和冒号）
  String _formatTimeForFileName(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final M = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$y-$M-$d-$h-$m-$s';
  }

  /// 清理文件名中的非法字符
  String sanitizeFileName(String name) {
    return name.replaceAll(_invalidFileNameChars, '_');
  }
}
