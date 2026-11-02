// [设置批2b-1b-2a | 2026-11-02] 图片选择器（Android SAF / 其余 file_picker）
//
// 设备根因：file_picker 的 Android MediaStore 路径在选中「已删除文件」的陈旧
// 缩略图时会触发原生 FATAL。容器图/导航图标统一改走 SAF
// `ACTION_OPEN_DOCUMENT`：
// - `Saf().pickFile(mimeTypes: ['image/*'])`，取消返回 null；
// - `withFileDescriptor(uri, 'r', ...)` 直接读字节，不解析 MediaStore 路径、
//   不触发 file_picker 原生压缩；
// - Android 分支**不再调用 file_picker**（SAF 异常时提示重试，不降级到
//   MediaStore 路径）；
// - iOS/桌面保留 file_picker（allowCompression:false）。
// 读取后的字节交由 ThemeBackgroundImageStore.storeBytes /
// NavIconStore.importBytes 统一校验/原子写。
// — 全栈工程师 + UI，2026-11-02
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:saf/saf.dart';

import 'theme_background_image_store.dart';

/// 选中图片的字节内容与显示名（SAF/file_picker 统一口径）
///
/// 容器背景图与导航图标共用；调用方通过 [ContainerImagePicker.pick] 的
/// `maxBytes`/`dialogTitle` 区分场景。
class ContainerImagePick {
  final Uint8List bytes;
  final String name;

  const ContainerImagePick({required this.bytes, required this.name});
}

/// 选择器不可用/读取失败（取消返回 null，不抛）
///
/// UI 捕获后 toast 中文提示；Android SAF 异常走此路径，**不**降级到
/// file_picker 的 MediaStore 路径。
class ContainerImagePickException implements Exception {
  final String message;

  const ContainerImagePickException(this.message);

  @override
  String toString() => message;
}

/// SAF 选择/读取抽象：生产走 saf 插件，测试注入桩。
abstract class ContainerSafGateway {
  Future<SafDocumentFile?> pickImage({
    List<String> mimeTypes = const <String>['image/*'],
  });

  Future<Uint8List> readBytes(String uri);
}

/// 默认 SAF 实现：系统文件选择器 + fd 读取（不经过 MediaStore 路径解析）
class PlatformContainerSafGateway implements ContainerSafGateway {
  final Saf _saf;

  PlatformContainerSafGateway([Saf? saf]) : _saf = saf ?? Saf();

  @override
  Future<SafDocumentFile?> pickImage({
    List<String> mimeTypes = const <String>['image/*'],
  }) => _saf.pickFile(mimeTypes: mimeTypes);

  @override
  Future<Uint8List> readBytes(String uri) =>
      _saf.withFileDescriptor(uri, 'r', (fd) => File(fd.path).readAsBytes());
}

/// 容器背景图选择入口（平台分支集中于此，UI 只消费字节）
class ContainerImagePicker {
  ContainerImagePicker._();

  /// 平台判定 seam（测试覆盖 Android / iOS/桌面分支）
  @visibleForTesting
  static bool Function() isAndroid = () => Platform.isAndroid;

  /// SAF 网关 seam（测试覆盖成功/取消/异常/陈旧 URI）
  @visibleForTesting
  static ContainerSafGateway safGateway = PlatformContainerSafGateway();

  /// 测试隔离：恢复真实平台判定与 SAF 网关
  @visibleForTesting
  static void resetForTest() {
    isAndroid = () => Platform.isAndroid;
    safGateway = PlatformContainerSafGateway();
  }

  /// 选择一张图片；用户取消返回 null，失败抛 [ContainerImagePickException]。
  ///
  /// [maxBytes]：读入内存前的尺寸上限（默认容器图 32MB；导航图标传
  /// `NavIconStore.maxBytes`）。Android 先按 SAF 元数据拦截，iOS/桌面按
  /// `PlatformFile.size` 与最终字节双重校验。
  /// [dialogTitle]：iOS/桌面 file_picker 标题；Android SAF 由系统选择器决定。
  static Future<ContainerImagePick?> pick({
    int maxBytes = ThemeBackgroundImageStore.maxBytes,
    String dialogTitle = '选择容器背景图片',
  }) async {
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    if (isAndroid()) return _pickAndroid(maxBytes: maxBytes);
    return _pickFilePicker(maxBytes: maxBytes, dialogTitle: dialogTitle);
  }

  /// Android：SAF pickFile + fd 读字节。异常只提示，不触碰 file_picker。
  static Future<ContainerImagePick?> _pickAndroid({
    required int maxBytes,
  }) async {
    try {
      final doc = await safGateway.pickImage(
        mimeTypes: const <String>['image/*'],
      );
      if (doc == null) {
        debugPrint('[ContainerImagePicker] 平台=Android SAF 用户取消');
        return null;
      }
      // 先按 provider 元数据拦截超大图，避免把超限内容整体读入 Dart 堆；
      // 实际字节仍由 storeBytes/importBytes 再校验一次（元数据可能为 0/不准）。
      if (doc.length > maxBytes) {
        debugPrint(
          '[ContainerImagePicker] Android SAF 文件过大: ${doc.length} bytes',
        );
        throw ContainerImagePickException(_tooLargeMessage(maxBytes));
      }
      final bytes = await safGateway.readBytes(doc.uri);
      debugPrint(
        '[ContainerImagePicker] 平台=Android SAF 读取 ${doc.name} '
        '(${bytes.length} bytes)',
      );
      return ContainerImagePick(bytes: bytes, name: doc.name);
    } on ContainerImagePickException {
      rethrow;
    } catch (e) {
      // [批2b-1b-2a] 刻意不降级 file_picker：Android MediaStore 陈旧缩略图
      // 路径会触发原生 FATAL；SAF 不可用时直接提示重试。
      debugPrint('[ContainerImagePicker] 平台=Android SAF 失败: $e');
      throw const ContainerImagePickException('无法打开系统图片选择器，请重试');
    }
  }

  /// iOS/桌面：保留 file_picker；allowCompression:false 防原生压缩异常。
  static Future<ContainerImagePick?> _pickFilePicker({
    required int maxBytes,
    required String dialogTitle,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        dialogTitle: dialogTitle,
        allowCompression: false,
        withData: false,
      );
      if (result == null || result.files.isEmpty) {
        debugPrint('[ContainerImagePicker] 平台=iOS/桌面 file_picker 用户取消');
        return null;
      }
      final file = result.files.single;
      // 先按平台元数据拦截，避免超大文件整体读入内存
      if (file.size > maxBytes) {
        debugPrint(
          '[ContainerImagePicker] 平台=iOS/桌面 file_picker 文件过大: '
          '${file.size} bytes',
        );
        throw ContainerImagePickException(_tooLargeMessage(maxBytes));
      }
      final bytes =
          file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) {
        debugPrint('[ContainerImagePicker] 平台=iOS/桌面 file_picker 无路径/字节');
        throw const ContainerImagePickException('无法读取所选图片');
      }
      if (bytes.length > maxBytes) {
        throw ContainerImagePickException(_tooLargeMessage(maxBytes));
      }
      return ContainerImagePick(bytes: bytes, name: file.name);
    } on ContainerImagePickException {
      rethrow;
    } catch (e) {
      debugPrint('[ContainerImagePicker] 平台=iOS/桌面 file_picker 失败: $e');
      throw const ContainerImagePickException('选择图片失败，请重试');
    }
  }

  static String _tooLargeMessage(int maxBytes) =>
      '图片过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）';
}
