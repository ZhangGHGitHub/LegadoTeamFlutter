import 'package:flutter/services.dart';

/// 系统另存平台通道抽象（D1）
///
/// 背景：`file_picker 8.3.7` 在 Android 的 `onActivityResult` 内直接对
/// SAF 返回的 Downloads provider URI 调 `openOutputStream` 写字节，仅捕获
/// `IOException`；MuMu Android 15 上抛出的 `SecurityException` 穿透
/// `Activity.onActivityResult` → 主线程 FATAL（进程被强杀，残留 0 字节文件）。
///
/// 该异常发生在平台 Activity 回调里，Dart 侧无法捕获，因此 Android 改为走
/// 自建 `legado/file_save` 通道（Kotlin `SaveFileBridge`）：选位置由
/// `ACTION_CREATE_DOCUMENT` 完成，写字节由原生后台线程执行并**捕获全部
/// 异常**回传（失败时删除已创建的空文档）。
///
/// 本抽象供 [ExportFileService] 注入测试假实现；生产实现为
/// [MethodChannelFileSaveChannel]。
abstract class FileSaveChannel {
  const FileSaveChannel();

  /// 打开系统另存对话框并写入 [bytes]。
  ///
  /// 返回实际保存的 URI 字符串（Android 为 content:// URI）；用户取消返回
  /// null；写入失败抛 [FileSaveException]（原生端已捕获异常并清理空文档）。
  Future<String?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
  });
}

/// `legado/file_save` MethodChannel 实现（Kotlin `SaveFileBridge`）
class MethodChannelFileSaveChannel extends FileSaveChannel {
  const MethodChannelFileSaveChannel();

  static const MethodChannel _channel = MethodChannel('legado/file_save');

  @override
  Future<String?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
  }) async {
    try {
      return await _channel.invokeMethod<String>('saveFile', <String, Object?>{
        'fileName': fileName,
        'bytes': bytes,
        if (mimeType != null && mimeType.isNotEmpty) 'mimeType': mimeType,
      });
    } on MissingPluginException {
      // 通道未注册（非本应用 Android 壳/测试宿主）：给出可读原因，
      // 不回退 file_picker（会重新引入崩溃链路）
      throw const FileSaveException(
        code: 'SAVE_CHANNEL_MISSING',
        message: '系统保存通道不可用，请更新应用版本后重试',
      );
    } on PlatformException catch (e) {
      throw FileSaveException(
        code: e.code,
        message: (e.message ?? '').trim().isEmpty ? '保存失败' : e.message!,
      );
    }
  }
}

/// 系统另存失败（原生端已捕获原始异常并清理残留文档）
///
/// `toString()` 直接返回中文原因，便于 UI 经 `errorMessage()` 展示；
/// [code] 保留原生错误码（SAVE_FAILED / EMPTY_BYTES / ...）供排障。
class FileSaveException implements Exception {
  const FileSaveException({required this.code, required this.message});

  /// 原生错误码
  final String code;

  /// 面向用户的中文原因
  final String message;

  @override
  String toString() => message;
}
