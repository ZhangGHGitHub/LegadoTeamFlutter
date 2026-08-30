import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';

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

  /// Cookie 通道：WebView 登录页读取系统 CookieManager
  static const MethodChannel cookie = MethodChannel('legado/cookie');

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

  // ─── Cookie 方法 ──────────────────────────────────────────────

  /// 读取指定 url 的 Cookie 串（无则空串）。
  ///
  /// 对齐原版 WebViewLoginFragment 的 CookieManager.getCookie 链路；
  /// 非 Android 平台/通道未注册时降级返回空串（调用方须容错）。
  static Future<String> getCookie(String url) async {
    try {
      return await cookie.invokeMethod<String>('getCookie', {'url': url}) ?? '';
    } catch (_) {
      return '';
    }
  }

  // ─── TTS 方法 ─────────────────────────────────────────────────

  // [iOS 轨 P2] iOS 走 flutter_tts（AVSpeechSynthesizer）；Android 保持
  // Kotlin TtsBridge 通道不回归；桌面平台维持原行为（调用方容错）。
  static final FlutterTts _iosTts = () {
    final tts = FlutterTts();
    // speak 不等待朗读完成（对齐 Android 通道的异步语义）
    tts.awaitSpeakCompletion(false);
    tts.setCompletionHandler(() => _iosSpeaking = false);
    tts.setCancelHandler(() => _iosSpeaking = false);
    tts.setErrorHandler((_) => _iosSpeaking = false);
    return tts;
  }();
  static bool _iosSpeaking = false;
  static bool _iosTtsLangSet = false;

  /// 初始化 TTS 引擎
  static Future<bool> initTts() async {
    if (Platform.isIOS) {
      try {
        await _iosTts.setLanguage('zh-CN');
        _iosTtsLangSet = true;
        return true;
      } catch (_) {
        return false;
      }
    }
    final result = await tts.invokeMethod<bool>('init');
    return result ?? false;
  }

  /// 朗读文本
  static Future<void> speak(String text) async {
    if (Platform.isIOS) {
      if (!_iosTtsLangSet) await initTts();
      _iosSpeaking = true;
      await _iosTts.speak(text);
      return;
    }
    await tts.invokeMethod('speak', {'text': text});
  }

  /// 停止朗读
  static Future<void> stopSpeak() async {
    if (Platform.isIOS) {
      _iosSpeaking = false;
      await _iosTts.stop();
      return;
    }
    await tts.invokeMethod('stop');
  }

  /// 设置朗读语言（BCP 47 语言标签，如 "zh-CN"）
  static Future<void> setLanguage(String language) async {
    if (Platform.isIOS) {
      await _iosTts.setLanguage(language);
      _iosTtsLangSet = true;
      return;
    }
    await tts.invokeMethod('setLanguage', {'language': language});
  }

  /// 设置朗读语速（默认 1.0）
  ///
  /// 刻度差异：Android setSpeechRate 1.0 为常速（约 0.5-2.0），
  /// iOS AVSpeechUtterance.rate 0-1 且 0.5 为常速——iOS 侧按 speed/2 折算。
  static Future<void> setSpeed(double speed) async {
    if (Platform.isIOS) {
      final rate = (speed / 2.0).clamp(0.0, 1.0);
      await _iosTts.setSpeechRate(rate);
      return;
    }
    await tts.invokeMethod('setSpeed', {'speed': speed});
  }

  /// 设置朗读音调（默认 1.0；两平台 1.0 均为常速，直接透传）
  static Future<void> setPitch(double pitch) async {
    if (Platform.isIOS) {
      await _iosTts.setPitch(pitch.clamp(0.5, 2.0));
      return;
    }
    await tts.invokeMethod('setPitch', {'pitch': pitch});
  }

  /// 查询是否正在朗读
  static Future<bool> isSpeaking() async {
    if (Platform.isIOS) return _iosSpeaking;
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

  // [iOS 轨 P2] iOS 走 flutter_local_notifications（UNUserNotificationCenter）；
  // Android 保持 NotificationService 通道。固定 id：1=下载 2=阅读状态。
  static final FlutterLocalNotificationsPlugin _iosNotifications =
      FlutterLocalNotificationsPlugin();
  static bool _iosNotifInitialized = false;

  static Future<void> _ensureIosNotifications() async {
    if (_iosNotifInitialized) return;
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _iosNotifications.initialize(
      const InitializationSettings(iOS: darwin),
    );
    await _iosNotifications
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: false, sound: false);
    _iosNotifInitialized = true;
  }

  static Future<void> _iosShow(int id, String title, String body) async {
    await _ensureIosNotifications();
    const details = NotificationDetails(
      iOS: DarwinNotificationDetails(presentAlert: true, presentSound: false),
    );
    await _iosNotifications.show(id, title, body, details);
  }

  /// 显示下载进度通知
  static Future<void> showDownloadProgress({
    required String bookName,
    required int progress,
    required int total,
  }) async {
    if (Platform.isIOS) {
      await _iosShow(1, '正在下载：$bookName', '$progress / $total');
      return;
    }
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
    if (Platform.isIOS) {
      await _iosShow(2, bookName, chapterName ?? '');
      return;
    }
    await notification.invokeMethod('showReadingNotification', {
      'bookName': bookName,
      'chapterName': chapterName ?? '',
    });
  }

  /// 取消指定通知，传 null 取消全部
  static Future<void> cancelNotification([int? id]) async {
    if (Platform.isIOS) {
      await _ensureIosNotifications();
      if (id == null) {
        await _iosNotifications.cancelAll();
      } else {
        await _iosNotifications.cancel(id);
      }
      return;
    }
    await notification.invokeMethod('cancelNotification', {'id': id});
  }

  /// 启动前台服务通知（iOS 无前台服务概念，空实现）
  static Future<void> startForegroundService({
    String title = '阅读服务',
    String content = '正在后台运行',
  }) async {
    if (Platform.isIOS) return;
    await notification.invokeMethod('startForegroundService', {
      'title': title,
      'content': content,
    });
  }

  /// 停止前台服务通知（iOS 无前台服务概念，空实现）
  static Future<void> stopForegroundService() async {
    if (Platform.isIOS) return;
    await notification.invokeMethod('stopForegroundService');
  }
}
