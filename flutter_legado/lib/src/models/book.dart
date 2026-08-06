import 'package:freezed_annotation/freezed_annotation.dart';

part 'book.freezed.dart';
part 'book.g.dart';

/// 书籍类型常量
class BookType {
  static const int text = 0;
  static const int audio = 1;
  static const int image = 2;
  static const int file = 3;
  static const int video = 4;
  static const int local = 0x1000;
  /// 未入书架的临时书（对齐 Kotlin `BookType.notShelf`；搜索/发现打开在线书阅读时临时落库）
  static const int notShelf = 0x400;
  static const String localTag = 'loc_book';
  static const String webDavTag = 'dav:';
}

/// 阅读配置
@freezed
class ReadConfig with _$ReadConfig {
  const factory ReadConfig({
    @Default(false) @JsonKey(name: 'reverseToc') bool reverseToc,
    @JsonKey(name: 'pageAnim') int? pageAnim,
    @Default(false) @JsonKey(name: 'reSegment') bool reSegment,
    @JsonKey(name: 'imageStyle') String? imageStyle,
    @JsonKey(name: 'useReplaceRule') bool? useReplaceRule,
    @Default(0) @JsonKey(name: 'delTag') int delTag,
    @JsonKey(name: 'ttsEngine') String? ttsEngine,
    @Default(true) @JsonKey(name: 'splitLongChapter') bool splitLongChapter,
    @Default(false) @JsonKey(name: 'readSimulating') bool readSimulating,
    @JsonKey(name: 'startDate') String? startDate,
    @JsonKey(name: 'startChapter') int? startChapter,
    @Default(3) @JsonKey(name: 'dailyChapters') int dailyChapters,
    @Default(0) @JsonKey(name: 'openCredits') int openCredits,
    @Default(0) @JsonKey(name: 'closeCredits') int closeCredits,
    @Default(0) @JsonKey(name: 'playMode') int playMode,
    @Default(1.0) @JsonKey(name: 'playSpeed') double playSpeed,
  }) = _ReadConfig;

  factory ReadConfig.fromJson(Map<String, dynamic> json) =>
      _$ReadConfigFromJson(json);
}

/// 书籍实体
@freezed
class Book with _$Book {
  const factory Book({
    @Default('') @JsonKey(name: 'bookUrl') String bookUrl,
    @Default('') @JsonKey(name: 'tocUrl') String tocUrl,
    @Default('loc_book') String origin,
    @Default('') @JsonKey(name: 'originName') String originName,
    @Default('') String name,
    @Default('') String author,
    String? kind,
    @JsonKey(name: 'customTag') String? customTag,
    @JsonKey(name: 'coverUrl') String? coverUrl,
    @JsonKey(name: 'customCoverUrl') String? customCoverUrl,
    String? intro,
    @JsonKey(name: 'customIntro') String? customIntro,
    String? charset,
    @Default(0) @JsonKey(name: 'type') int bookType,
    @Default(0) int group,
    @JsonKey(name: 'latestChapterTitle') String? latestChapterTitle,
    @Default(0) @JsonKey(name: 'latestChapterTime') int latestChapterTime,
    @Default(0) @JsonKey(name: 'lastCheckTime') int lastCheckTime,
    @Default(0) @JsonKey(name: 'lastCheckCount') int lastCheckCount,
    @Default(0) @JsonKey(name: 'totalChapterNum') int totalChapterNum,
    @JsonKey(name: 'durChapterTitle') String? durChapterTitle,
    @Default(0) @JsonKey(name: 'durChapterIndex') int durChapterIndex,
    @Default(0) @JsonKey(name: 'durVolumeIndex') int durVolumeIndex,
    @Default(0) @JsonKey(name: 'chapterInVolumeIndex') int chapterInVolumeIndex,
    @Default(0) @JsonKey(name: 'durChapterPos') int durChapterPos,
    @Default(0) @JsonKey(name: 'durChapterTime') int durChapterTime,
    @JsonKey(name: 'wordCount') String? wordCount,
    @Default(true) @JsonKey(name: 'canUpdate') bool canUpdate,
    @Default(0) int order,
    @Default(0) @JsonKey(name: 'originOrder') int originOrder,
    String? variable,
    @JsonKey(name: 'readConfig') ReadConfig? readConfig,
    @Default(0) @JsonKey(name: 'syncTime') int syncTime,
  }) = _Book;

  factory Book.fromJson(Map<String, dynamic> json) => _$BookFromJson(json);
}
