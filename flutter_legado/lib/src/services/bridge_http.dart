import 'dart:convert';
import 'dart:typed_data';

import 'book_api.dart';

/// Rust Bridge HTTP 响应（文本 GET，F3-14 裸 http 收敛）
class BridgeHttpResponse {
  const BridgeHttpResponse({
    required this.statusCode,
    required this.body,
    this.url = '',
  });

  final int statusCode;
  final String body;
  final String url;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// 经 [`BookApi.httpGet`] 发起 GET（共享 UA/Cookie/超时/限流）
Future<BridgeHttpResponse> bridgeHttpGet(
  BookApi api,
  String url, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final raw = await api.httpGet(url).timeout(timeout);
  final map = jsonDecode(raw) as Map<String, dynamic>;
  return BridgeHttpResponse(
    statusCode: map['status'] as int? ?? 0,
    body: map['body'] as String? ?? '',
    url: map['url'] as String? ?? url,
  );
}

/// 经 [`BookApi.httpGetBytes`] 发起二进制 GET
Future<({int statusCode, Uint8List bytes, String url})> bridgeHttpGetBytes(
  BookApi api,
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final headersJson =
      headers == null || headers.isEmpty ? '' : jsonEncode(headers);
  final raw = await api
      .httpGetBytes(url, headersJson: headersJson)
      .timeout(timeout);
  final map = jsonDecode(raw) as Map<String, dynamic>;
  final b64 = map['bodyBase64'] as String? ?? '';
  return (
    statusCode: map['status'] as int? ?? 0,
    bytes: base64Decode(b64),
    url: map['url'] as String? ?? url,
  );
}
