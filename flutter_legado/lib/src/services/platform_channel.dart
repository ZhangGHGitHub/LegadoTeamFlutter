import 'package:flutter/services.dart';

/// Platform Channel 基础架构
///
/// 定义与原生 Android/iOS 通信的 MethodChannel 常量和方法。
/// 通道名称与 Kotlin 端 MainActivity 中注册的名称保持一致。
class PlatformChannel {
  PlatformChannel._();

  // ─── 通道常量 ─────────────────────────────────────────────────

  /// WebView 通道：用于执行需要 WebView 的 JS（反爬虫验证等）
  static const MethodChannel webview = MethodChannel('legado/webview');

  /// TTS 通道：文本转语音
  static const MethodChannel tts = MethodChannel('legado/tts');

  /// 文件选择器通道：导入本地书籍文件
  static const MethodChannel filePicker = MethodChannel('legado/file_picker');

  /// 通知通道：前台服务、下载进度、阅读通知
  static const MethodChannel notification =
      MethodChannel('legado/notification');

  /// 事件通道：用于接收原生层的流式事件
  static const EventChannel eventChannel =
      EventChannel('io.legado.app/events');

  // ─── WebView 方法 ─────────────────────────────────────────────

  /// 加载 URL 并可选执行 JavaScript，返回 JS 执行结果
  static Future<String?> loadUrlWithJs(String url, [String? js]) async {
    return await webview.invokeMethod<String>('loadUrl', {
      'url': url,
      'javaScript': js,
    });
  }

  /// Android BackstageWebView：cacheFirst→LOAD_CACHE_ELSE_NETWORK；
  /// isRule 时注入 java/source/cache JavascriptInterface。
  static Future<String?> backstageEval(Map<String, dynamic> args) async {
    final raw = await webview.invokeMethod<dynamic>('backstageEval', args);
    return raw?.toString();
  }

  /// 在当前 WebView 上执行 JavaScript
  static Future<String?> evaluateJs(String js) async {
    return await webview.invokeMethod<String>('evaluateJs', {
      'javaScript': js,
    });
  }

  /// 关闭并销毁 WebView
  static Future<void> closeWebView() async {
    await webview.invokeMethod('close');
  }

  // ─── TTS 方法 ─────────────────────────────────────────────────

  /// 初始化 TTS 引擎
  static Future<bool> initTts() async {
    final result = await tts.invokeMethod<bool>('init');
    return result ?? false;
  }

  /// 朗读文本
  static Future<void> speak(String text) async {
    await tts.invokeMethod('speak', {'text': text});
  }

  /// 停止朗读
  static Future<void> stopSpeak() async {
    await tts.invokeMethod('stop');
  }

  /// 设置朗读语言（BCP 47 语言标签，如 "zh-CN"）
  static Future<void> setLanguage(String language) async {
    await tts.invokeMethod('setLanguage', {'language': language});
  }

  /// 设置朗读语速（默认 1.0）
  static Future<void> setSpeed(double speed) async {
    await tts.invokeMethod('setSpeed', {'speed': speed});
  }

  /// 设置朗读音调（默认 1.0）
  static Future<void> setPitch(double pitch) async {
    await tts.invokeMethod('setPitch', {'pitch': pitch});
  }

  /// 查询是否正在朗读
  static Future<bool> isSpeaking() async {
    final result = await tts.invokeMethod<bool>('isSpeaking');
    return result ?? false;
  }

  // ─── 文件选择器方法 ───────────────────────────────────────────

  /// 选择文件，返回文件 URI 字符串
  /// [mimeTypes] 可选 MIME 类型过滤列表
  static Future<String?> pickFile({List<String>? mimeTypes}) async {
    return await filePicker.invokeMethod<String>('pickFile', {
      'mimeTypes': mimeTypes ??
          ['application/epub+zip', 'text/plain', 'application/pdf'],
    });
  }

  /// 选择目录，返回目录 URI 字符串（SAF DocumentTree）
  static Future<String?> pickDirectory() async {
    return await filePicker.invokeMethod<String>('pickDirectory');
  }

  // ─── 通知方法 ─────────────────────────────────────────────────

  /// 显示下载进度通知
  static Future<void> showDownloadProgress({
    required String bookName,
    required int progress,
    required int total,
  }) async {
    await notification.invokeMethod('showDownloadProgress', {
      'bookName': bookName,
      'progress': progress,
      'total': total,
    });
  }

  /// 显示阅读状态通知
  static Future<void> showReadingNotification({
    required String bookName,
    String? chapterName,
  }) async {
    await notification.invokeMethod('showReadingNotification', {
      'bookName': bookName,
      'chapterName': chapterName ?? '',
    });
  }

  /// 取消指定通知，传 null 取消全部
  static Future<void> cancelNotification([int? id]) async {
    await notification.invokeMethod('cancelNotification', {'id': id});
  }

  /// 启动前台服务通知
  static Future<void> startForegroundService({
    String title = '阅读服务',
    String content = '正在后台运行',
  }) async {
    await notification.invokeMethod('startForegroundService', {
      'title': title,
      'content': content,
    });
  }

  /// 停止前台服务通知
  static Future<void> stopForegroundService() async {
    await notification.invokeMethod('stopForegroundService');
  }
}
