/// 书源打开浏览器拦截（批39，对齐参考版 `OtherSettings.blockSourceBrowser`）
///
/// 统一的拦截口径与文案，供两处消费：
/// - 书源 JS 桥（`PlatformBridgeService` 的 openUrl/openBrowser/startBrowser）；
/// - RSS 阅读页 WebView 宿主桥（`java.openUrl` 动作，见
///   `rss_article_detail_screen.dart`）。
///
/// [批39 审查回修]
/// - 文案中性化：startBrowser 可能外开、showBrowser 走内置浏览器，统一说
///   「浏览器」而不是「内置浏览器」；
/// - `legado:`/`yuedu:` 关联导入属站内链路（导入确认页），不受拦截，
///   三个入口（openUrl/openBrowser/startBrowser）与 RSS `java.openUrl`
///   一律豁免。
library;

import '../providers/ui_settings/ui_settings_notifier.dart';
import '../utils/legado_deep_link.dart';

/// 拦截提示文案（与参考版 `block_source_browser_error` 语义一致）
const String kSourceBrowserBlockedMessage = '已阻止书源打开浏览器';

/// 当前是否拦截书源打开浏览器
///
/// 同步读取 [uiSettingsListenable]（UiSettingsNotifier 启动加载并镜像），
/// 避免在桥接动作里做异步偏好读取（偏好 IO 失败不得阻塞浏览器动作）。
bool get sourceBrowserBlocked =>
    uiSettingsListenable.value.blockSourceBrowser;

/// 是否为「不受拦截」的站内深链（`legado:`/`yuedu:` 关联导入）
bool isSourceBrowserBlockedExempt(String url) =>
    LegadoDeepLink.isImportScheme(url);
