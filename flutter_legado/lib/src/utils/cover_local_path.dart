// 封面本地路径识别（设置批6b-1 设备回归 P2-1）
//
// `Book.customCoverUrl` 可能来自：
// - 网络地址（http/https）→ CachedNetworkImage；
// - 本地换封面写入的绝对路径（Android /data/...、Windows C:\...、POSIX /...）；
// - `file://` URI（SAF/分享等外部来源）；
// - 历史/其他来源的相对路径。
//
// 统一在此判定：网络/data URI 返回 null；file URI 转本地路径；其余按本地
// 路径原样返回（存在性由调用方 File.existsSync 判断，缺失回落默认封面）。
//
// 编写：全栈工程师（设置批6b-1 设备回归） ｜ 2026-11-06
import 'dart:io';

/// 解析本地封面文件路径；网络地址 / data URI / 空值返回 null
String? localCoverFilePath(String? url) {
  final text = url?.trim();
  if (text == null || text.isEmpty) return null;
  final lower = text.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('data:')) {
    return null;
  }
  if (lower.startsWith('file://')) {
    try {
      return Uri.parse(text).toFilePath(windows: Platform.isWindows);
    } catch (_) {
      return null;
    }
  }
  return text;
}

/// 是否为本地封面路径（不保证文件存在）
bool isLocalCoverUrl(String? url) => localCoverFilePath(url) != null;
