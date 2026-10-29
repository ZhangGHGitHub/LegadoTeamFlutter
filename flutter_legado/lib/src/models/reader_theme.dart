// 阅读主题模型（批38｜参考版阅读主题列表管理）
//
// 参考依据：
// - `legado-with-MD3/.../help/config/ReadBookConfig.kt` 的 `Config`（一份样式
//   快照：字号/行距/边距/背景/文字色/字重/斜体等）；
// - `.../assets/defaultData/readConfig.json` 的内置预设（微信读书 + 预设1..4
//   为参考版钉死的 5 份预设，预设5 是参考版可变的自建位，本批不内置）；
// - `.../ui/book/read/sheet/ThemeListContent.kt` 的列表/网格、多选、列数、
//   定位当前、回顶/回底交互。
//
// 本模型只描述**主题快照**（不可变值对象），不持有任何 Flutter Widget /
// SharedPreferences 状态；持久化见 `services/reader_theme_service.dart`。
//
// 背景图说明：参考版 Config 支持 `bgType=2` 背景图，我方阅读页当前没有
// 背景图能力（仅有背景色），故 `bgImage` 字段仅做导入/导出透传占位，
// 应用主题时忽略（本批登记为未做项）。
//
// 编写：全栈工程师（批38） ｜ 2026-10-29
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

/// 阅读主题 JSON 结构版本（导入时只做提示，不强制拒绝高版本）
const int kReaderThemeSchemaVersion = 1;

/// 颜色编码为 `#AARRGGBB`（对齐参考版 Config 的 `#ffc0edc6` 形态）
String encodeReaderThemeColor(int argb) =>
    '#${argb.toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// 解析颜色：接受 `#AARRGGBB` / `#RRGGBB` / ARGB int
///
/// - 6 位 hex 视为不透明（补 `FF` 前缀）
/// - 非法输入抛 [FormatException]（导入侧据此拒绝整份主题）
int decodeReaderThemeColor(Object? raw) {
  switch (raw) {
    case final int value:
      return value;
    case final String text:
      final hex = text.trim().replaceFirst('#', '');
      if (hex.length == 6) {
        final rgb = int.tryParse(hex, radix: 16);
        if (rgb != null) return 0xFF000000 | rgb;
      } else if (hex.length == 8) {
        final argb = int.tryParse(hex, radix: 16);
        if (argb != null) return argb;
      }
      throw FormatException('无法解析颜色：$text');
    default:
      throw FormatException('颜色字段类型非法：${raw.runtimeType}');
  }
}

/// 阅读样式快照（一份主题）
///
/// 字段与阅读页实际生效的配置一一对应：
/// - [fontSize]/[lineHeight] → `ReaderState`
/// - [backgroundColor] → `ReaderState.backgroundColor`（应用时按是否命中
///   预设色选择「预设索引」或「自定义背景」两条既有持久化链路）
/// - [textColor] → `ReaderAdvancedConfig.customTextColor`（0=跟随背景自动）
/// - [fontFamily] → prefs `reader_font_family`；[titleFont] → `titleFont`
/// - 其余排版字段 → `ReaderAdvancedConfig`（边距/字距/缩进/段距/字重/斜体）
@immutable
class ReaderThemeStyle {
  const ReaderThemeStyle({
    this.fontSize = 20.0,
    this.lineHeight = 1.7,
    this.backgroundColor = 0xFFFFFFFF,
    this.textColor = 0,
    this.fontFamily = '',
    this.titleFont = '',
    this.letterSpacing = 0.1,
    this.paragraphIndent = 2,
    this.paragraphSpacing = 2.0,
    this.marginTop = 24.0,
    this.marginBottom = 24.0,
    this.marginLeft = 20.0,
    this.marginRight = 20.0,
    this.textBold = 0,
    this.italic = false,
    this.bgImage = '',
  });

  /// 正文字号（对齐阅读页范围 5..50，默认 20）
  final double fontSize;

  /// 行高倍数（1.0..3.0，默认 1.7）
  final double lineHeight;

  /// 背景色 ARGB（0xAARRGGBB）
  final int backgroundColor;

  /// 文字色 ARGB；0 = 跟随背景自动（`customTextColor` 语义）
  final int textColor;

  /// 正文字体 family（prefs `reader_font_family`，空=系统默认）
  final String fontFamily;

  /// 标题字体（prefs `titleFont`，空=跟随正文）
  final String titleFont;

  /// 字距（em，-0.5..1.0）
  final double letterSpacing;

  /// 首行缩进（字符数 0..3）
  final int paragraphIndent;

  /// 段落间距（pt，0..48）
  final double paragraphSpacing;

  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;

  /// 字重（0 中 / 1 粗 / 2 细）
  final int textBold;

  /// 正文斜体（参考版行内字体面板开关）
  final bool italic;

  /// 背景图路径（预留：我方阅读页暂无背景图能力，仅导入/导出透传）
  final String bgImage;

  /// 归一化到阅读页可接受的取值区间（导入/历史脏数据统一收敛）
  ReaderThemeStyle normalized() {
    return ReaderThemeStyle(
      fontSize: fontSize.clamp(5.0, 50.0),
      lineHeight: lineHeight.clamp(1.0, 3.0),
      backgroundColor: backgroundColor,
      textColor: textColor,
      fontFamily: fontFamily.trim(),
      titleFont: titleFont.trim(),
      letterSpacing: letterSpacing.clamp(-0.5, 1.0),
      paragraphIndent: paragraphIndent.clamp(0, 3),
      paragraphSpacing: paragraphSpacing.clamp(0.0, 48.0),
      marginTop: marginTop.clamp(0.0, 400.0),
      marginBottom: marginBottom.clamp(0.0, 400.0),
      marginLeft: marginLeft.clamp(0.0, 100.0),
      marginRight: marginRight.clamp(0.0, 100.0),
      textBold: textBold.clamp(0, 2),
      italic: italic,
      bgImage: bgImage.trim(),
    );
  }

  ReaderThemeStyle copyWith({
    double? fontSize,
    double? lineHeight,
    int? backgroundColor,
    int? textColor,
    String? fontFamily,
    String? titleFont,
    double? letterSpacing,
    int? paragraphIndent,
    double? paragraphSpacing,
    double? marginTop,
    double? marginBottom,
    double? marginLeft,
    double? marginRight,
    int? textBold,
    bool? italic,
    String? bgImage,
  }) {
    return ReaderThemeStyle(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textColor: textColor ?? this.textColor,
      fontFamily: fontFamily ?? this.fontFamily,
      titleFont: titleFont ?? this.titleFont,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      paragraphIndent: paragraphIndent ?? this.paragraphIndent,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      marginTop: marginTop ?? this.marginTop,
      marginBottom: marginBottom ?? this.marginBottom,
      marginLeft: marginLeft ?? this.marginLeft,
      marginRight: marginRight ?? this.marginRight,
      textBold: textBold ?? this.textBold,
      italic: italic ?? this.italic,
      bgImage: bgImage ?? this.bgImage,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'backgroundColor': encodeReaderThemeColor(backgroundColor),
    // 0 = 自动，导出为 null（比 "0" 更不易被误读成黑色）
    'textColor': textColor == 0 ? null : encodeReaderThemeColor(textColor),
    'fontFamily': fontFamily,
    'titleFont': titleFont,
    'letterSpacing': letterSpacing,
    'paragraphIndent': paragraphIndent,
    'paragraphSpacing': paragraphSpacing,
    'marginTop': marginTop,
    'marginBottom': marginBottom,
    'marginLeft': marginLeft,
    'marginRight': marginRight,
    'textBold': textBold,
    'italic': italic,
    'bgImage': bgImage,
  };

  /// 解析样式；缺省字段取默认值，类型非法抛 [FormatException]
  factory ReaderThemeStyle.fromJson(Map<String, dynamic> json) {
    double readDouble(String key, double fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is num) return value.toDouble();
      throw FormatException('$key 应为数字');
    }

    int readInt(String key, int fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is int) return value;
      if (value is num) return value.round();
      throw FormatException('$key 应为整数');
    }

    bool readBool(String key, bool fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is bool) return value;
      throw FormatException('$key 应为布尔值');
    }

    String readString(String key, String fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is String) return value;
      throw FormatException('$key 应为字符串');
    }

    final rawTextColor = json['textColor'];
    return ReaderThemeStyle(
      fontSize: readDouble('fontSize', 20.0),
      lineHeight: readDouble('lineHeight', 1.7),
      backgroundColor: decodeReaderThemeColor(
        json['backgroundColor'] ?? '#FFFFFFFF',
      ),
      textColor: rawTextColor == null
          ? 0
          : decodeReaderThemeColor(rawTextColor),
      fontFamily: readString('fontFamily', ''),
      titleFont: readString('titleFont', ''),
      letterSpacing: readDouble('letterSpacing', 0.1),
      paragraphIndent: readInt('paragraphIndent', 2),
      paragraphSpacing: readDouble('paragraphSpacing', 2.0),
      marginTop: readDouble('marginTop', 24.0),
      marginBottom: readDouble('marginBottom', 24.0),
      marginLeft: readDouble('marginLeft', 20.0),
      marginRight: readDouble('marginRight', 20.0),
      textBold: readInt('textBold', 0),
      italic: readBool('italic', false),
      bgImage: readString('bgImage', ''),
    ).normalized();
  }

  @override
  bool operator ==(Object other) {
    return other is ReaderThemeStyle &&
        other.fontSize == fontSize &&
        other.lineHeight == lineHeight &&
        other.backgroundColor == backgroundColor &&
        other.textColor == textColor &&
        other.fontFamily == fontFamily &&
        other.titleFont == titleFont &&
        other.letterSpacing == letterSpacing &&
        other.paragraphIndent == paragraphIndent &&
        other.paragraphSpacing == paragraphSpacing &&
        other.marginTop == marginTop &&
        other.marginBottom == marginBottom &&
        other.marginLeft == marginLeft &&
        other.marginRight == marginRight &&
        other.textBold == textBold &&
        other.italic == italic &&
        other.bgImage == bgImage;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    fontSize,
    lineHeight,
    backgroundColor,
    textColor,
    fontFamily,
    titleFont,
    letterSpacing,
    paragraphIndent,
    paragraphSpacing,
    marginTop,
    marginBottom,
    marginLeft,
    marginRight,
    textBold,
    italic,
    bgImage,
  ]);
}

/// 主题样式应用辅助
extension ReaderThemeStyleApply on ReaderThemeStyle {
  /// 背景色在给定预设色表中的下标（-1 = 不在预设内，按自定义背景处理）
  ///
  /// 应用主题时据此选择既有持久化链路：命中预设走 `reader_bg_color_index`，
  /// 未命中走 `reader_custom_bg_color` + `reader_bg_use_custom`。这样背景
  /// chip 的选中态（预设色或自定义）与主题实际背景始终一致。
  int presetBackgroundIndex(Iterable<int> presetArgb) {
    var index = 0;
    for (final color in presetArgb) {
      if (color == backgroundColor) return index;
      index++;
    }
    return -1;
  }
}

/// 命名阅读主题
///
/// [builtIn] 的内置主题恒排在最前、不可重命名/删除/排序（对齐参考版
/// `READ_STYLE_PRESET_COUNT` 的前 5 份钉死语义）。
@immutable
class ReaderTheme {
  const ReaderTheme({
    required this.id,
    required this.name,
    required this.style,
    this.builtIn = false,
  });

  /// 主题身份（内置为稳定 id；自建/导入为运行时生成 id）
  ///
  /// 名称允许重复，身份一律按 id 判定（对齐参考版 `buildThemeKeys` 的
  /// `theme:<id>` key 空间）。
  final String id;
  final String name;
  final ReaderThemeStyle style;
  final bool builtIn;

  ReaderTheme copyWith({String? name, ReaderThemeStyle? style}) {
    return ReaderTheme(
      id: id,
      name: name ?? this.name,
      style: style ?? this.style,
      builtIn: builtIn,
    );
  }

  /// 单份导出 JSON（含名称/样式/背景；`type` 仅作识别提示，导入不强制）
  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': 'legado.readerTheme',
    'schema': kReaderThemeSchemaVersion,
    'id': id,
    'name': name,
    'style': style.toJson(),
  };

  /// 解析单份主题；`id` 仅作参考，导入侧一律重新分配
  factory ReaderTheme.fromJson(Map<String, dynamic> json) {
    final rawName = json['name'];
    if (rawName is! String || rawName.trim().isEmpty) {
      throw const FormatException('主题名称缺失或为空');
    }
    final rawStyle = json['style'];
    if (rawStyle is! Map) {
      throw const FormatException('缺少 style 样式对象');
    }
    return ReaderTheme(
      id: json['id'] is String ? json['id'] as String : '',
      name: rawName.trim(),
      style: ReaderThemeStyle.fromJson(Map<String, dynamic>.from(rawStyle)),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ReaderTheme &&
        other.id == id &&
        other.name == name &&
        other.builtIn == builtIn &&
        other.style == style;
  }

  @override
  int get hashCode => Object.hash(id, name, builtIn, style);
}

/// 主题 JSON 编解码（导入/导出/持久化共用）
class ReaderThemeCodec {
  ReaderThemeCodec._();

  /// 编码单份主题（缩进 2 便于用户手工编辑/分享阅读）
  static String encode(ReaderTheme theme) =>
      const JsonEncoder.withIndent('  ').convert(theme.toJson());

  /// 解码单份或数组形态的导入内容
  ///
  /// 支持：
  /// - 单对象 `{ "name": ..., "style": {...} }`
  /// - 数组 `[ {...}, {...} ]`（批量导入，逐份校验）
  ///
  /// 任一形态非法即抛 [FormatException]（调用方提示导入失败原因）。
  static List<ReaderTheme> decodeAll(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('不是有效的 JSON：${e.message}');
    }
    switch (decoded) {
      case final List<dynamic> list:
        if (list.isEmpty) throw const FormatException('主题列表为空');
        return <ReaderTheme>[
          for (final item in list)
            if (item is Map)
              ReaderTheme.fromJson(Map<String, dynamic>.from(item))
            else
              throw const FormatException('主题列表中存在非对象条目'),
        ];
      case final Map<String, dynamic> map:
        return <ReaderTheme>[ReaderTheme.fromJson(map)];
      default:
        throw const FormatException('JSON 顶层应为对象或数组');
    }
  }

  /// 解码本地持久化的自建主题列表（宽松：坏条目跳过，不阻断启动）
  static List<ReaderTheme> decodeStoredList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <ReaderTheme>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <ReaderTheme>[];
      final result = <ReaderTheme>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          final theme = ReaderTheme.fromJson(Map<String, dynamic>.from(item));
          // 持久化列表只允许自建主题（内置由代码提供，写进来也不采信）；
          // 缺 id（手工编辑/旧格式）时补一个，避免整条被丢弃
          final id = theme.id.isEmpty
              ? 'theme-restored-${DateTime.now().microsecondsSinceEpoch}-'
                    '${result.length}'
              : theme.id;
          result.add(
            ReaderTheme(
              id: id,
              name: theme.name,
              style: theme.style,
              builtIn: false,
            ),
          );
        } on FormatException {
          continue;
        }
      }
      return result;
    } on FormatException {
      return const <ReaderTheme>[];
    }
  }

  /// 编码自建主题列表（持久化用）
  static String encodeStoredList(List<ReaderTheme> themes) =>
      jsonEncode(<Map<String, dynamic>>[
        for (final theme in themes)
          if (!theme.builtIn) theme.toJson(),
      ]);
}

/// 名称冲突自动加后缀：`名字` → `名字 (2)` → `名字 (3)`…
///
/// 参考版导入走「同名替换」，本批按手头任务口径改为「导入为新主题」，
/// 因此必须避免重名（名称是用户唯一可辨识的标识）。
String uniqueReaderThemeName(String base, Iterable<String> existingNames) {
  final trimmed = base.trim();
  final normalized = trimmed.isEmpty ? '阅读主题' : trimmed;
  final names = existingNames.toSet();
  if (!names.contains(normalized)) return normalized;
  var index = 2;
  while (names.contains('$normalized ($index)')) {
    index++;
  }
  return '$normalized ($index)';
}

/// 内置主题（对齐参考版 `readConfig.json` 的 5 份预设色）
///
/// 取值说明：
/// - 微信读书：背景 `#ffc0edc6`、文字 `#ff0b0b0b`、字号 24、
///   参考版 `lineSpacingExtra=10`（≈1.42 倍行距）、边距 5/4/22/22
/// - 预设1..4：背景 `#FFFFFF / #DDC090 / #C2D8AA / #DBB8E2`，
///   文字 `#000000 / #3E3422 / #596C44 / #68516C`
/// - 未内置参考版第 6 份「预设5（#ABCEE0）」：参考版仅前 5 份钉死，
///   预设5 属可变的自建位，本批按「自建主题可删」语义留给用户导入/新建
const List<ReaderTheme> kBuiltInReaderThemes = <ReaderTheme>[
  ReaderTheme(
    id: 'builtin-wechat-read',
    name: '微信读书',
    builtIn: true,
    style: ReaderThemeStyle(
      fontSize: 24.0,
      lineHeight: 1.42,
      backgroundColor: 0xFFC0EDC6,
      textColor: 0xFF0B0B0B,
      letterSpacing: 0.0,
      paragraphIndent: 2,
      marginTop: 5.0,
      marginBottom: 4.0,
      marginLeft: 22.0,
      marginRight: 22.0,
    ),
  ),
  ReaderTheme(
    id: 'builtin-preset-1',
    name: '预设1',
    builtIn: true,
    style: ReaderThemeStyle(backgroundColor: 0xFFFFFFFF, textColor: 0xFF000000),
  ),
  ReaderTheme(
    id: 'builtin-preset-2',
    name: '预设2',
    builtIn: true,
    style: ReaderThemeStyle(backgroundColor: 0xFFDDC090, textColor: 0xFF3E3422),
  ),
  ReaderTheme(
    id: 'builtin-preset-3',
    name: '预设3',
    builtIn: true,
    style: ReaderThemeStyle(backgroundColor: 0xFFC2D8AA, textColor: 0xFF596C44),
  ),
  ReaderTheme(
    id: 'builtin-preset-4',
    name: '预设4',
    builtIn: true,
    style: ReaderThemeStyle(backgroundColor: 0xFFDBB8E2, textColor: 0xFF68516C),
  ),
];

/// 内置主题 id 集合（不可删/不可排序判定）
final Set<String> kBuiltInReaderThemeIds = <String>{
  for (final theme in kBuiltInReaderThemes) theme.id,
};
