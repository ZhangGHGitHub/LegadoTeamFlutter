// 正文图片点击方式（clickImgWay）纯逻辑 — 全栈工程师 + UI
//
// 对齐原版：
// - `PreferKey.kt:242` clickImgWay / `pref_config_read.xml:228-235`
//   （五档 values 0..4，entries：默认行为/预览图片/兼容旧版/关闭点击/双击生效）
// - `ContentTextView.kt:398-444` 的分流语义：
//   "1" 预览 → PhotoDialog
//   "2" 兼容 → 在线文本书：click 非空执行 click action，否则 oldClickImg
//         （读复合 URL 的 click/js）；非在线文本不消费
//   "3" 关闭 → handled=false（点击穿透给页面）
//   "4" 双击 → 双击才执行 click action，单击消费
//   其他（含 "0"）→ click 非空执行 click action，否则不消费
//
// 本仓库现状（参见实现说明）：
// - Rust `HtmlFormatter.format_keep_img` 保留 `<img src="URL,{json}">` 复合
//   URL 的 JSON 后缀，故 `click`/`action`/`js`/`headers` 信息在正文中可用；
// - 但尚无「带书源 jsLib + book/chapter/result 绑定」的图片 action 执行
//   FFI（`BookApi.evalJs` 是裸沙箱），`kClickImgActionSupported` 恒为
//   false → 命中 action 时回退为预览，并把「图片 click action 执行能力」
//   作为阻塞项登记。
//
// 参考版默认档位为 "2"（兼容旧版）；原版 pref 的 defaultValue 为 "0"，
// 按任务口径统一取 "2"。

import 'dart:convert';

/// 正文图片点击方式默认档（参考版 `ReadSettings` 口径 "2"=兼容旧版）
const String kDefaultClickImgWay = '2';

/// 当前构建是否具备执行图片 `click`/`js` action 的能力。
///
/// 参考版经书源 `evalJS` 注入 `book`/`chapter`/`result`/`java` 后执行；
/// 本仓库尚无等价 FFI（`BookApi.evalJs` 为无绑定裸沙箱），故恒 false。
const bool kClickImgActionSupported = false;

/// 五档下拉选项（值与顺序对齐原版 `click_image_way_value` /
/// `click_image_way_title`）
const Map<String, String> kClickImgWayOptions = <String, String>{
  '0': '默认行为',
  '1': '预览图片',
  '2': '兼容旧版',
  '3': '关闭点击',
  '4': '双击生效',
};

/// 档位钳制：合法值 "0".."4" 原样保留，缺省/非法回落参考版默认 "2"
String clampClickImgWay(String? raw) =>
    kClickImgWayOptions.containsKey(raw) ? raw! : kDefaultClickImgWay;

/// 档位显示文案（非法值按钳制后的默认档显示）
String clickImgWayLabel(String? way) => kClickImgWayOptions[clampClickImgWay(way)]!;

/// 复合图片 URL 参数分隔符，对齐原版 `AnalyzeUrl.paramPattern`
/// `\s*,\s*(?=\{)`（URL 与 JSON 属性之间允许空白）
final RegExp _clickImgParamSeparator = RegExp(r'\s*,\s*(?=\{)');

/// 正文图片 URL 及其复合参数（书源解析产物）
///
/// 示例：`https://cdn/a.webp,{"click":"act()","js":"...","headers":{...}}`
/// → [url] 为可直连地址，[click]/[js] 为动作脚本，[headers] 为防盗链头。
class ClickImgUrlOptions {
  /// 纯 URL（已剥离 `,{json}` 后缀，可直接交给 CachedNetworkImage/预览器）
  final String url;

  /// 点击动作：原版读复合 JSON 的 `click`；参考版 `image.action` 亦兼容
  final String? click;

  /// 兼容旧版动作脚本（原版 `oldClickImg` 在 click 为空时读取）
  final String? js;

  /// 请求头（复合 JSON 的 `headers`，供预览器复用）
  final Map<String, String> headers;

  const ClickImgUrlOptions({
    required this.url,
    this.click,
    this.js,
    this.headers = const <String, String>{},
  });

  bool get hasClick => click != null;
  bool get hasJs => js != null;

  /// 是否带任何可执行动作（click/action 或 js）
  bool get hasAction => hasClick || hasJs;

  @override
  String toString() =>
      'ClickImgUrlOptions(url: $url, click: $click, js: $js, headers: $headers)';
}

/// 解析正文图片 URL 的复合参数（对齐原版 `AnalyzeUrl` + `ImageColumn`
/// 的 `paramPattern` 口径）。
///
/// 无 `,{json}` 后缀、JSON 非法、或字段为空串时 fail-closed：保留纯 URL，
/// 动作/请求头按缺省处理（不抛错，避免坏数据中断阅读）。
ClickImgUrlOptions parseClickImgUrlOptions(String src) {
  final raw = src.trim();
  if (raw.isEmpty) return const ClickImgUrlOptions(url: '');

  final separator = _clickImgParamSeparator.firstMatch(raw);
  if (separator == null) return ClickImgUrlOptions(url: raw);

  final url = raw.substring(0, separator.start).trim();
  final jsonPart = raw.substring(separator.end);
  String? click;
  String? js;
  var headers = const <String, String>{};
  try {
    final decoded = jsonDecode(jsonPart);
    if (decoded is Map<String, dynamic>) {
      click = _nonBlank(decoded['click']) ?? _nonBlank(decoded['action']);
      js = _nonBlank(decoded['js']);
      final rawHeaders = decoded['headers'];
      if (rawHeaders is Map) {
        headers = <String, String>{
          for (final entry in rawHeaders.entries)
            if (entry.value != null) '${entry.key}': '${entry.value}',
        };
      }
    }
  } catch (_) {
    // 复合后缀不是合法 JSON：按纯 URL 处理（与 stripCompositeImageUrl 一致）
  }
  return ClickImgUrlOptions(
    url: url.isEmpty ? raw : url,
    click: click,
    js: js,
    headers: headers,
  );
}

String? _nonBlank(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 单次点击的处置结果
enum ClickImgTapEffect {
  /// 不消费：点击穿透给页面点击（原版 handled=false，阅读页据此翻页/呼菜单）
  passThrough,

  /// 消费但不动作（双击档的第一次点击）
  consume,

  /// 打开图片预览（对齐原版 PhotoDialog）
  preview,

  /// 执行书源 click/js action（当前构建不可用，见 [kClickImgActionSupported]）
  runAction,
}

/// 五档图片点击决策（纯函数）— 全栈工程师 + UI
///
/// - [way]：clickImgWay 原始值（内部按 [clampClickImgWay] 钳制）
/// - [onlineText]：是否在线文本书（对齐原版 `Book.isOnLineTxt`：非本地且
///   文本类型；见 `reader_image_dominant_body.dart` 的调用点）
/// - [hasClick]：[ClickImgUrlOptions.hasClick]（click/action 非空）
/// - [hasJs]：[ClickImgUrlOptions.hasJs]
/// - [doubleTap]：是否处于双击窗口内的第二次点击（仅 "4" 档消费）
/// - [actionAvailable]：是否具备 action 执行能力（默认 [kClickImgActionSupported]）
///
/// 语义矩阵：
/// | 档位 | 单击 | 双击 |
/// |---|---|---|
/// | "1" | 预览 | 预览 |
/// | "2" | 在线文本且 click/js 非空 → action；否则穿透 | 同单击 |
/// | "3" | 穿透 | 穿透 |
/// | "4" | 消费（不动作） | click 非空 → action；否则预览 |
/// | 其他("0"/非法) | click 非空 → action；否则穿透 | 同单击 |
///
/// action 不可执行时统一回退 [ClickImgTapEffect.preview]（任务口径：
/// 「若 Rust 无 action，回退预览并登记」；本仓库有 action 数据但无执行能力，
/// 同样回退预览并登记）。
ClickImgTapEffect resolveClickImgTap({
  required String way,
  required bool onlineText,
  required bool hasClick,
  required bool hasJs,
  required bool doubleTap,
  bool actionAvailable = kClickImgActionSupported,
}) {
  ClickImgTapEffect actionOrPreview() => actionAvailable
      ? ClickImgTapEffect.runAction
      : ClickImgTapEffect.preview;

  switch (clampClickImgWay(way)) {
    case '1':
      return ClickImgTapEffect.preview;
    case '2':
      if (!onlineText) return ClickImgTapEffect.passThrough;
      if (!hasClick && !hasJs) return ClickImgTapEffect.passThrough;
      return actionOrPreview();
    case '3':
      return ClickImgTapEffect.passThrough;
    case '4':
      if (!doubleTap) return ClickImgTapEffect.consume;
      // 参考版双击档仅在 click 非空时执行；任务口径补充「无 action 回退
      // 预览」（本仓库 action 执行恒不可用，故实际落 preview）
      return hasClick ? actionOrPreview() : ClickImgTapEffect.preview;
    default:
      // "0" 默认行为：仅 click 非空时执行（原版 else 分支不读 js）
      return hasClick ? actionOrPreview() : ClickImgTapEffect.passThrough;
  }
}
