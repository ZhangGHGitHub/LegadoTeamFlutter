// 封面设置模型（设置批6b-1）
//
// 字段名 / 默认值逐字对齐参考版 `CoverSettings.kt`（`legado-with-MD3`），
// 持久化键名对齐参考版 `PreferKey.kt` 的真实字符串值（非常量名）。
// 本期 18 个设置项中「封面规则」无持久化字段（走既有 Rust 封面规则
// 接口），其余 17 项全部在本模型内；「网络书籍角标」只保存
// `exploreFilterState`（默认 0），过滤逻辑另立项，本批不在 UI 生效。
//
// 相册（`defaultAlbumId`）本期只保留字段与键 `defaultCover`（参考版同名
// 键），设置页显示「应用内置封面」并置灰；相册管理与日/夜图集选择在
// 设置批 6b-2 接入。为避免与参考版 `defaultCoverDark` 语义错位，本期
// 不写入该键（登记见交付说明）。
//
// 颜色在 Dart 内统一使用 32 位无符号 ARGB（0xAARRGGBB），读取旧备份时
// 兼容参考版 Kotlin 写入的负 int（按 32 位截断归一）。
//
// 编写：全栈工程师（设置批6b-1） ｜ 2026-11-06
import 'dart:math' as math;

/// 封面设置（不可变）
class CoverSettings {
  // ===== 持久化键（逐字对齐参考版 PreferKey 的真实字符串值）=====
  static const keyLoadOnlyOnWifi = 'loadCoverOnlyWifi';
  static const keyUseDefaultCover = 'useDefaultCover';

  /// 默认封面图集 ID（参考版同名键 `defaultCover`；6b-2 相册接入）
  static const keyDefaultAlbumId = 'defaultCover';

  /// 默认夜间封面图集 ID（参考版同名键 `defaultCoverDark`；6b-2 相册接入）
  static const keyDefaultAlbumIdDark = 'defaultCoverDark';
  static const keyShowShadow = 'coverShowShadow';
  static const keyShowStroke = 'coverShowStroke';
  static const keyUseDefaultColor = 'coverDefaultColor';

  /// 限制封面比例（批39 已接入，键名与 `PrefKeys.coverRestrictRatio` 一致）
  static const keyRestrictCoverRatio = 'coverRestrictRatio';
  static const keyInfoOrientation = 'coverInfoOrientation';

  /// 网络书籍角标过滤（参考版 `explore_filter_state`；本批只持久化）
  static const keyExploreFilterState = 'explore_filter_state';
  static const keyTextColor = 'coverTextColor';
  static const keyShadowColor = 'coverShadowColor';
  static const keyShowName = 'coverShowName';
  static const keyShowAuthor = 'coverShowAuthor';
  static const keyTextColorDark = 'coverTextColorN';
  static const keyShadowColorDark = 'coverShadowColorN';
  static const keyShowNameDark = 'coverShowNameN';
  static const keyShowAuthorDark = 'coverShowAuthorN';

  /// 属于「忽略封面配置」恢复项的全部键（RestoreIgnorePrefs 过滤用）
  static const prefKeys = <String>{
    keyLoadOnlyOnWifi,
    keyUseDefaultCover,
    keyDefaultAlbumId,
    keyDefaultAlbumIdDark,
    keyShowShadow,
    keyShowStroke,
    keyUseDefaultColor,
    keyRestrictCoverRatio,
    keyInfoOrientation,
    keyExploreFilterState,
    keyTextColor,
    keyShadowColor,
    keyShowName,
    keyShowAuthor,
    keyTextColorDark,
    keyShadowColorDark,
    keyShowNameDark,
    keyShowAuthorDark,
  };

  /// 信息方向可选值：0 竖排（默认）/ 1 横排
  static const infoOrientationPortrait = '0';
  static const infoOrientationLandscape = '1';

  /// 仅 WiFi 下加载网络封面（默认 false）
  final bool loadOnlyOnWifi;

  /// 总是使用默认封面（忽略网络封面，默认 false）
  final bool useDefaultCover;

  /// 默认封面图集 ID（null = 应用内置封面；6b-2 相册）
  final String? defaultAlbumId;

  /// 默认夜间封面图集 ID（null = 与日间一致/应用内置封面；6b-2）
  final String? defaultAlbumIdDark;

  /// 封面外阴影 + 字体阴影（默认 false）
  final bool showShadow;

  /// 字体描边（白色 STROKE，默认 true）
  final bool showStroke;

  /// 使用默认字体颜色（主题 secondary，默认 true）
  final bool useDefaultColor;

  /// 限制封面比例（默认 true）
  final bool restrictCoverRatio;

  /// 封面信息方向：'0' 竖排 / '1' 横排
  final String infoOrientation;

  /// 网络书籍角标过滤状态：0 全部显示（本批不渲染过滤）
  final int exploreFilterState;

  /// 日间正文色（默认黑）
  final int textColor;

  /// 日间阴影色（默认黑）
  final int shadowColor;

  /// 日间显示书名（默认 true）
  final bool showName;

  /// 日间显示作者（默认 true；书名关闭时不绘制）
  final bool showAuthor;

  /// 夜间正文色（默认白）
  final int textColorDark;

  /// 夜间阴影色（默认白）
  final int shadowColorDark;

  /// 夜间显示书名（默认 true）
  final bool showNameDark;

  /// 夜间显示作者（默认 true；书名关闭时不绘制）
  final bool showAuthorDark;

  const CoverSettings({
    this.loadOnlyOnWifi = false,
    this.useDefaultCover = false,
    this.defaultAlbumId,
    this.defaultAlbumIdDark,
    this.showShadow = false,
    this.showStroke = true,
    this.useDefaultColor = true,
    this.restrictCoverRatio = true,
    this.infoOrientation = infoOrientationPortrait,
    this.exploreFilterState = 0,
    this.textColor = 0xFF000000,
    this.shadowColor = 0xFF000000,
    this.showName = true,
    this.showAuthor = true,
    this.textColorDark = 0xFFFFFFFF,
    this.shadowColorDark = 0xFFFFFFFF,
    this.showNameDark = true,
    this.showAuthorDark = true,
  });

  /// 参考版默认值（字段顺序/取值同 `CoverSettings.kt`）
  static const defaults = CoverSettings();

  /// copyWith 的「未传参」哨兵：图集 ID 需要支持显式清空（null）
  static const _unset = Object();

  CoverSettings copyWith({
    bool? loadOnlyOnWifi,
    bool? useDefaultCover,
    Object? defaultAlbumId = _unset,
    Object? defaultAlbumIdDark = _unset,
    bool? showShadow,
    bool? showStroke,
    bool? useDefaultColor,
    bool? restrictCoverRatio,
    String? infoOrientation,
    int? exploreFilterState,
    int? textColor,
    int? shadowColor,
    bool? showName,
    bool? showAuthor,
    int? textColorDark,
    int? shadowColorDark,
    bool? showNameDark,
    bool? showAuthorDark,
  }) {
    return CoverSettings(
      loadOnlyOnWifi: loadOnlyOnWifi ?? this.loadOnlyOnWifi,
      useDefaultCover: useDefaultCover ?? this.useDefaultCover,
      defaultAlbumId: identical(defaultAlbumId, _unset)
          ? this.defaultAlbumId
          : defaultAlbumId as String?,
      defaultAlbumIdDark: identical(defaultAlbumIdDark, _unset)
          ? this.defaultAlbumIdDark
          : defaultAlbumIdDark as String?,
      showShadow: showShadow ?? this.showShadow,
      showStroke: showStroke ?? this.showStroke,
      useDefaultColor: useDefaultColor ?? this.useDefaultColor,
      restrictCoverRatio: restrictCoverRatio ?? this.restrictCoverRatio,
      infoOrientation: infoOrientation ?? this.infoOrientation,
      exploreFilterState: exploreFilterState ?? this.exploreFilterState,
      textColor: textColor ?? this.textColor,
      shadowColor: shadowColor ?? this.shadowColor,
      showName: showName ?? this.showName,
      showAuthor: showAuthor ?? this.showAuthor,
      textColorDark: textColorDark ?? this.textColorDark,
      shadowColorDark: shadowColorDark ?? this.shadowColorDark,
      showNameDark: showNameDark ?? this.showNameDark,
      showAuthorDark: showAuthorDark ?? this.showAuthorDark,
    );
  }

  /// 读取持久化映射（缺失键用默认值；兼容参考版负 int 颜色）
  factory CoverSettings.fromPrefMap(Map<String, Object?> map) {
    const d = defaults;

    bool readBool(String key, bool fallback) {
      final value = map[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        switch (value.trim().toLowerCase()) {
          case 'true':
          case '1':
            return true;
          case 'false':
          case '0':
            return false;
        }
      }
      return fallback;
    }

    int readInt(String key, int fallback) {
      final value = map[key];
      if (value is int) return value & 0xFFFFFFFF;
      if (value is num) return value.round() & 0xFFFFFFFF;
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) return parsed & 0xFFFFFFFF;
      }
      return fallback;
    }

    String? readOptionalString(String key) {
      final value = map[key];
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    String readOrientation(String key, String fallback) {
      final value = map[key];
      if (value is String && (value == '0' || value == '1')) return value;
      if (value is num) return value == 1 ? '1' : '0';
      return fallback;
    }

    return CoverSettings(
      loadOnlyOnWifi: readBool(keyLoadOnlyOnWifi, d.loadOnlyOnWifi),
      useDefaultCover: readBool(keyUseDefaultCover, d.useDefaultCover),
      defaultAlbumId: readOptionalString(keyDefaultAlbumId),
      defaultAlbumIdDark: readOptionalString(keyDefaultAlbumIdDark),
      showShadow: readBool(keyShowShadow, d.showShadow),
      showStroke: readBool(keyShowStroke, d.showStroke),
      useDefaultColor: readBool(keyUseDefaultColor, d.useDefaultColor),
      restrictCoverRatio: readBool(keyRestrictCoverRatio, d.restrictCoverRatio),
      infoOrientation: readOrientation(keyInfoOrientation, d.infoOrientation),
      exploreFilterState: readInt(keyExploreFilterState, d.exploreFilterState),
      textColor: readInt(keyTextColor, d.textColor),
      shadowColor: readInt(keyShadowColor, d.shadowColor),
      showName: readBool(keyShowName, d.showName),
      showAuthor: readBool(keyShowAuthor, d.showAuthor),
      textColorDark: readInt(keyTextColorDark, d.textColorDark),
      shadowColorDark: readInt(keyShadowColorDark, d.shadowColorDark),
      showNameDark: readBool(keyShowNameDark, d.showNameDark),
      showAuthorDark: readBool(keyShowAuthorDark, d.showAuthorDark),
    ).normalized();
  }

  /// 持久化映射（键名逐字对齐参考版 PreferKey 真实值）
  Map<String, Object?> toPrefMap() => {
    keyLoadOnlyOnWifi: loadOnlyOnWifi,
    keyUseDefaultCover: useDefaultCover,
    keyDefaultAlbumId: defaultAlbumId ?? '',
    keyDefaultAlbumIdDark: defaultAlbumIdDark ?? '',
    keyShowShadow: showShadow,
    keyShowStroke: showStroke,
    keyUseDefaultColor: useDefaultColor,
    keyRestrictCoverRatio: restrictCoverRatio,
    keyInfoOrientation: infoOrientation,
    keyExploreFilterState: exploreFilterState,
    keyTextColor: textColor,
    keyShadowColor: shadowColor,
    keyShowName: showName,
    keyShowAuthor: showAuthor,
    keyTextColorDark: textColorDark,
    keyShadowColorDark: shadowColorDark,
    keyShowNameDark: showNameDark,
    keyShowAuthorDark: showAuthorDark,
  };

  /// 越界值收敛（备份/手改/旧版本写入同一入口）
  CoverSettings normalized() {
    int argb(int value) => value & 0xFFFFFFFF;
    return copyWith(
      defaultAlbumId: (defaultAlbumId == null || defaultAlbumId!.trim().isEmpty)
          ? null
          : defaultAlbumId!.trim(),
      defaultAlbumIdDark:
          (defaultAlbumIdDark == null || defaultAlbumIdDark!.trim().isEmpty)
          ? null
          : defaultAlbumIdDark!.trim(),
      infoOrientation: infoOrientation == infoOrientationLandscape ? '1' : '0',
      exploreFilterState: math.min(math.max(exploreFilterState, 0), 3),
      textColor: argb(textColor),
      shadowColor: argb(shadowColor),
      textColorDark: argb(textColorDark),
      shadowColorDark: argb(shadowColorDark),
    );
  }

  /// 日间/夜间是否显示书名
  bool showNameFor({required bool isNight}) =>
      isNight ? showNameDark : showName;

  /// 日间/夜间是否显示作者（书名关闭时作者随之不绘制）
  bool showAuthorFor({required bool isNight}) {
    if (!showNameFor(isNight: isNight)) return false;
    return isNight ? showAuthorDark : showAuthor;
  }

  /// 正文色：使用默认色时取主题 secondary，否则取日/夜自定义色
  int textColorFor({required bool isNight, required int defaultColor}) {
    if (useDefaultColor) return defaultColor;
    return isNight ? textColorDark : textColor;
  }

  /// 阴影色（日/夜）
  int shadowColorFor({required bool isNight}) =>
      isNight ? shadowColorDark : shadowColor;

  /// 是否配置为横排
  bool get horizontalBySetting => infoOrientation == infoOrientationLandscape;

  /// 实际是否横排：配置横排或书名以拉丁字母为主（>30% 拉丁字母）
  bool horizontalFor(String? name) =>
      horizontalBySetting || isLatinBasedText(name);

  /// 书名是否以拉丁字母为主（参考版阈值：拉丁字母占比 > 30%）
  static bool isLatinBasedText(String? text) {
    if (text == null || text.trim().isEmpty) return false;
    var latin = 0;
    for (final rune in text.runes) {
      if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
        latin++;
      }
    }
    return latin / text.length > 0.3;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CoverSettings &&
        other.loadOnlyOnWifi == loadOnlyOnWifi &&
        other.useDefaultCover == useDefaultCover &&
        other.defaultAlbumId == defaultAlbumId &&
        other.defaultAlbumIdDark == defaultAlbumIdDark &&
        other.showShadow == showShadow &&
        other.showStroke == showStroke &&
        other.useDefaultColor == useDefaultColor &&
        other.restrictCoverRatio == restrictCoverRatio &&
        other.infoOrientation == infoOrientation &&
        other.exploreFilterState == exploreFilterState &&
        other.textColor == textColor &&
        other.shadowColor == shadowColor &&
        other.showName == showName &&
        other.showAuthor == showAuthor &&
        other.textColorDark == textColorDark &&
        other.shadowColorDark == shadowColorDark &&
        other.showNameDark == showNameDark &&
        other.showAuthorDark == showAuthorDark;
  }

  @override
  int get hashCode => Object.hash(
    loadOnlyOnWifi,
    useDefaultCover,
    defaultAlbumId,
    defaultAlbumIdDark,
    showShadow,
    showStroke,
    useDefaultColor,
    restrictCoverRatio,
    infoOrientation,
    exploreFilterState,
    textColor,
    shadowColor,
    showName,
    showAuthor,
    textColorDark,
    shadowColorDark,
    showNameDark,
    showAuthorDark,
  );
}
