// 阅读器目录/规则重载的元信息（批43b）
//
// 与 `BookChapter` 列表一起承载「本次目录是否真正应用了显式 TXT 目录规则」：
// Rust `ChapterListResponse.used_custom_rule` 在规则未命中/不可用时为 false
// （已回退内置默认），UI 据此区分「已应用」与「未命中已回退」——
// 修复批43「未命中回退却提示已应用」的假成功反馈。
library;

import 'book_chapter.dart';

/// 章节列表 + 本次解析的目录规则使用情况
///
/// [usedCustomRule] 仅在**本地 TXT 重新解析**时有意义：
/// - true：`books.tocUrl` 的显式规则命中并用于分章；
/// - false：未配置规则（默认规则）或规则不可用/未命中而回退内置默认；
/// - 目录缓存命中、在线书与其它本地格式恒为 false（未执行解析）。
typedef ChapterListMeta = ({List<BookChapter> chapters, bool usedCustomRule});

/// TXT 目录规则应用后的重载结果
///
/// [error] 非 null 表示目录或正文重载失败（UI **不得**提示成功）；
/// [usedCustomRule] 语义同 [ChapterListMeta]，用于「规则未命中，已回退默认」
/// 提示。恢复默认规则时该值为 false 属于预期，调用方按「恢复默认」提示。
typedef TocRuleReloadResult = ({String? error, bool usedCustomRule});
