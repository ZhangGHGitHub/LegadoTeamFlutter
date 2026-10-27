// 平台 WebView 能力判定（批19 审查 P1 收口）
//
// webview_flutter 当前依赖栈仅覆盖 Android / iOS / macOS；Windows / Linux
// 桌面端没有实现。历史上 browser_screen、rss_article_detail_screen、
// platform_bridge_service 各自维护同一份判定，容易漂移（批19 审查 P1：
// singleUrl 分流与详情页判定不一致，Windows 落到「暂无内容」空态）。
// 本文件作为唯一判定来源，三处调用统一走 [isWebViewPlatformSupported]。

import 'dart:io';

/// 测试用平台能力覆盖（null 表示按真实平台判定）
///
/// 仅测试使用：桌面测试宿主不支持真实 WebView，用例通过覆盖该值验证
/// 「支持 WebView」分支（需配合最小 `WebViewPlatform` 假实现）。
bool? _debugWebViewSupportedOverride;

/// 设置测试用平台能力覆盖（null 恢复真实判定）
void debugSetWebViewSupportedOverride(bool? value) {
  _debugWebViewSupportedOverride = value;
}

/// 读取测试用平台能力覆盖（null 表示按真实平台判定）
bool? debugGetWebViewSupportedOverride() => _debugWebViewSupportedOverride;

/// 当前平台是否支持 webview_flutter（Android / iOS / macOS）
bool get isWebViewPlatformSupported {
  final override = _debugWebViewSupportedOverride;
  if (override != null) return override;
  return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
}
