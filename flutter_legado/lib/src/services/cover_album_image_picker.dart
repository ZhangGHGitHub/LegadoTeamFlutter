// 封面相册多选图片导入（设置批6b-2）
//
// 复用 2b-1b-2a 的 SAF 口径：Android 走 `ACTION_OPEN_DOCUMENT` 多选
// （`Saf.pickFiles`）+ fd 读字节，不解析 MediaStore 路径（陈旧缩略图会
// 触发原生 FATAL）；iOS/桌面走 file_picker 多选，allowCompression:false。
//
// [审查回修 P2-2] 选择阶段只拿元数据（URI/路径/大小），字节按
// [CoverAlbumImagePick.readBytes] 逐张惰性读取；UI 逐张导入后立即释放，
// 不再把 20×10MB 一次性读入内存。批量门槛：单张 ≤32MB（超限跳过并报
// 可读原因）、总张数 ≤20、总大小 ≤64MB（超出拒绝整批）。
//
// 测试 seam：`pickOverride` 注入选择结果（不会真正读取字节），
// `resetForTest` 恢复真实平台实现。
//
// 编写：全栈工程师（设置批6b-2） ｜ 2026-11-09
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:saf/saf.dart';

import 'cover_album_store.dart';

/// 单张选中图片：只持元数据，[readBytes] 按需读取一次
class CoverAlbumImagePick {
  final String name;
  final int size;
  final Future<Uint8List> Function() _read;

  CoverAlbumImagePick({
    required this.name,
    required this.size,
    required Future<Uint8List> Function() read,
  }) : _read = read;

  /// 已在内存中的字节（测试/旧调用方）
  factory CoverAlbumImagePick.fromBytes({
    required String name,
    required Uint8List bytes,
  }) {
    return CoverAlbumImagePick(
      name: name,
      size: bytes.length,
      read: () async => bytes,
    );
  }

  Future<Uint8List> readBytes() => _read();
}

/// 选择阶段被跳过的图片（单张超限/不可读）
class CoverAlbumImagePickFailure {
  final String name;
  final String message;

  const CoverAlbumImagePickFailure({required this.name, required this.message});
}

/// 多选结果：可读句柄 + 选择阶段失败项
class CoverAlbumImagePickBatch {
  final List<CoverAlbumImagePick> picks;
  final List<CoverAlbumImagePickFailure> failures;

  const CoverAlbumImagePickBatch({
    this.picks = const <CoverAlbumImagePick>[],
    this.failures = const <CoverAlbumImagePickFailure>[],
  });
}

/// 选择/读取失败（取消返回空批次，不抛）
class CoverAlbumImagePickerException implements Exception {
  final String message;

  const CoverAlbumImagePickerException(this.message);

  @override
  String toString() => message;
}

/// 多选图片入口（平台分支集中于此，UI 只消费惰性句柄）
class CoverAlbumImagePicker {
  CoverAlbumImagePicker._();

  /// 单批张数上限（与 Store 一致）
  static const int maxCount = CoverAlbumStore.maxBatchCount;

  /// 单批总字节上限（与 Store 一致）
  static const int maxTotalBytes = CoverAlbumStore.maxBatchBytes;

  /// 测试 seam：返回 null 走真实平台实现
  @visibleForTesting
  static Future<CoverAlbumImagePickBatch> Function(int maxBytes)? pickOverride;

  @visibleForTesting
  static void resetForTest() {
    pickOverride = null;
  }

  /// 选择多张图片；用户取消返回空批次
  ///
  /// 单张超限记入 [CoverAlbumImagePickBatch.failures]（不中止整批）；
  /// 张数/总大小超过门槛抛 [CoverAlbumImagePickerException]。
  static Future<CoverAlbumImagePickBatch> pickImages({
    int maxBytes = CoverAlbumStore.maxBytes,
  }) async {
    if (kIsWeb) {
      throw const CoverAlbumImagePickerException('Web 端不支持封面相册');
    }
    final override = pickOverride;
    final batch = override != null
        ? await override(maxBytes)
        : Platform.isAndroid
        ? await _pickAndroid()
        : await _pickDesktop();
    return _applyLimits(batch, maxBytes);
  }

  static CoverAlbumImagePickBatch _applyLimits(
    CoverAlbumImagePickBatch batch,
    int maxBytes,
  ) {
    if (batch.picks.length > maxCount) {
      throw CoverAlbumImagePickerException('单次最多导入 $maxCount 张图片');
    }
    var total = 0;
    final picks = <CoverAlbumImagePick>[];
    final failures = <CoverAlbumImagePickFailure>[...batch.failures];
    for (final pick in batch.picks) {
      if (pick.size > maxBytes) {
        failures.add(
          CoverAlbumImagePickFailure(
            name: pick.name,
            message: '图片过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）',
          ),
        );
        continue;
      }
      total += pick.size;
      if (total > maxTotalBytes) {
        throw CoverAlbumImagePickerException(
          '本次选择图片总大小超过 ${maxTotalBytes ~/ (1024 * 1024)}MB',
        );
      }
      picks.add(pick);
    }
    return CoverAlbumImagePickBatch(picks: picks, failures: failures);
  }

  static Future<CoverAlbumImagePickBatch> _pickAndroid() async {
    try {
      final saf = Saf();
      final docs = await saf.pickFiles(mimeTypes: const <String>['image/*']);
      if (docs.isEmpty) return const CoverAlbumImagePickBatch();
      return CoverAlbumImagePickBatch(
        picks: [
          for (final doc in docs)
            CoverAlbumImagePick(
              name: doc.name,
              size: doc.length,
              read: () => saf.withFileDescriptor(
                doc.uri,
                'r',
                (fd) => File(fd.path).readAsBytes(),
              ),
            ),
        ],
      );
    } on CoverAlbumImagePickerException {
      rethrow;
    } catch (e) {
      debugPrint('[CoverAlbumImagePicker] Android SAF 失败: $e');
      throw const CoverAlbumImagePickerException('无法打开系统图片选择器，请重试');
    }
  }

  static Future<CoverAlbumImagePickBatch> _pickDesktop() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
        allowCompression: false,
        withData: false,
      );
      if (result == null || result.files.isEmpty) {
        return const CoverAlbumImagePickBatch();
      }
      return CoverAlbumImagePickBatch(
        picks: [
          for (final file in result.files)
            CoverAlbumImagePick(
              name: file.name,
              size: file.size,
              read: () async {
                final bytes = file.bytes;
                if (bytes != null) return bytes;
                final path = file.path;
                if (path == null) {
                  throw CoverAlbumImagePickerException('无法读取所选图片：${file.name}');
                }
                return File(path).readAsBytes();
              },
            ),
        ],
      );
    } on CoverAlbumImagePickerException {
      rethrow;
    } catch (e) {
      debugPrint('[CoverAlbumImagePicker] file_picker 失败: $e');
      throw const CoverAlbumImagePickerException('选择图片失败，请重试');
    }
  }
}
