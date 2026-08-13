//! 书籍导出 API
//!
//! 提供书籍导出为 TXT/EPUB/HTML/PDF 的能力。

use serde::{Deserialize, Serialize};

use legado_book::export::{
    extract_image_sources, BookExporter, ExportChapter, ExportConfig, ExportData, ExportFormat,
    ImageFetcher,
};
use legado_core::LegadoResult;
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::repository::book_repository::BookRepository;
use legado_db::repository::cache_book_repository::CacheBookRepository;
use legado_parser::AnalyzeUrl;

use crate::api::reader::{
    apply_content_processing_chapter, chapter_to_local_info, is_local_book,
};
use crate::db_state::with_database;

/// 导出结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportResult {
    /// 是否成功
    pub success: bool,
    /// 导出文件内容（base64 编码）
    pub data_base64: Option<String>,
    /// 文件名
    pub file_name: Option<String>,
    /// MIME 类型
    pub mime_type: Option<String>,
    /// 错误信息（失败时）
    pub error: Option<String>,
}

/// 导出选项 DTO（Task #136 R8，API_CONTRACT §2.43.4，所有字段可选）
///
/// 对照 Kotlin `ExportBookService`（编码）/ `getExportFileName`（文件名模板）。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportOptions {
    /// 输出编码（仅 TXT 生效）：UTF-8（缺省）/ GB2312 / GBK / GB18030 / UTF-16 / UTF-16LE / ASCII
    pub encoding: Option<String>,
    /// 起始章节 index（闭区间；缺省/-1 = 不限）
    pub start_chapter: Option<i32>,
    /// 结束章节 index（闭区间；缺省/-1 = 不限）
    pub end_chapter: Option<i32>,
    /// 文件名模板：`{name}` / `{author}` 占位符（对照 Kotlin getExportFileName
    /// 缺省 `"$name 作者：$author"`；此处缺省保持现行为 `{书名}.{扩展名}`）
    pub file_name_template: Option<String>,
}

/// 导出书籍（既有签名与行为不变；等价于全缺省选项的 [`export_book_with_options`]）
///
/// # 参数
/// - `book_url`: 书籍 URL
/// - `format`: 导出格式（txt/epub/html/pdf）
/// - `include_toc`: 是否包含目录
///
/// # 返回
/// 导出结果，包含 base64 编码的文件内容
pub fn export_book(book_url: &str, format: &str, include_toc: bool) -> LegadoResult<ExportResult> {
    export_book_inner(book_url, format, include_toc, &ExportOptions::default())
}

/// 带选项导出书籍（Task #136 R8，API_CONTRACT §2.43.4）
///
/// `options_json` 为空串/`"{}"` 时全缺省（行为等同 [`export_book`]）。
/// 字段见 [`ExportOptions`]；非法 JSON 返回错误结果（不 panic）。
pub fn export_book_with_options(
    book_url: &str,
    format: &str,
    include_toc: bool,
    options_json: &str,
) -> LegadoResult<ExportResult> {
    let options = if options_json.trim().is_empty() {
        ExportOptions::default()
    } else {
        match serde_json::from_str::<ExportOptions>(options_json) {
            Ok(o) => o,
            Err(e) => {
                return Ok(ExportResult {
                    success: false,
                    data_base64: None,
                    file_name: None,
                    mime_type: None,
                    error: Some(format!("导出选项 JSON 解析失败: {e}")),
                });
            }
        }
    };
    export_book_inner(book_url, format, include_toc, &options)
}

/// 导出内层实现（选项全部缺省时行为与旧版一致）
fn export_book_inner(
    book_url: &str,
    format: &str,
    include_toc: bool,
    options: &ExportOptions,
) -> LegadoResult<ExportResult> {
    // 解析导出格式
    let export_format = match ExportFormat::from_str(format) {
        Some(f) => f,
        None => {
            return Ok(ExportResult {
                success: false,
                data_base64: None,
                file_name: None,
                mime_type: None,
                error: Some(format!("不支持的导出格式: {format}，支持 txt/epub/html/pdf")),
            });
        }
    };

    // 从数据库获取书籍与章节元数据
    let book_data = with_database(|db| {
        let book_repo = BookRepository::new(db.connection());
        let book = book_repo.find_by_url(book_url)?;
        let book = match book {
            Some(b) => b,
            None => return Ok(None),
        };
        let chapter_repo = BookChapterRepository::new(db.connection());
        let chapters = chapter_repo.find_by_book_url(book_url)?;
        Ok(Some((book, chapters)))
    })?;

    let (book, chapters) = match book_data {
        Some(v) => v,
        None => {
            return Ok(ExportResult {
                success: false,
                data_base64: None,
                file_name: None,
                mime_type: None,
                error: Some(format!("书籍不存在: {book_url}")),
            });
        }
    };

    // 在线书：预加载缓存正文（本地书不走缓存，逐章走解析器）
    let cached = if is_local_book(book_url) {
        Vec::new()
    } else {
        with_database(|db| {
            let cache_repo = CacheBookRepository::new(db.connection());
            Ok(cache_repo.get_by_book(book_url).unwrap_or_default())
        })?
    };

    // 章节范围筛选（R8：startChapter/endChapter 闭区间，缺省/-1 = 不限）
    let range_ok = |index: i32| {
        let start_ok = match options.start_chapter {
            Some(s) if s >= 0 => index >= s,
            _ => true,
        };
        let end_ok = match options.end_chapter {
            Some(e) if e >= 0 => index <= e,
            _ => true,
        };
        start_ok && end_ok
    };

    // 逐章取正文（与阅读器 get_chapter_content 同源）并应用净化，与 Android 导出经 ContentProcessor 一致
    let local = is_local_book(book_url);
    let export_chapters: Vec<ExportChapter> = chapters
        .iter()
        .filter(|ch| range_ok(ch.index))
        .map(|ch| {
            let raw_content = if local {
                // 本地书：走解析器读取文件正文（修复仅读缓存导致本地书导出全空的回归）
                legado_book::LocalBook::get_chapter_content(
                    book_url,
                    &chapter_to_local_info(ch),
                )
                .unwrap_or_default()
            } else {
                // 在线书：从缓存取原始正文
                cached
                    .iter()
                    .find(|c| c.chapter_index == ch.index)
                    .map(|c| c.content.clone())
                    .unwrap_or_default()
            };
            // 导出内容与阅读器显示对齐：应用替换规则 + 内容净化
            // （含章级「删除重复标题」开关，Task #51）
            let content = apply_content_processing_chapter(book_url, &raw_content, &ch.title, ch.index);
            // 图片书 PDF 导出（对齐上游 #483）：从正文提取 img 标签，
            // 并相对章节 URL 绝对化（对齐 Kotlin NetworkUtils.getAbsoluteURL）
            let images = if matches!(export_format, ExportFormat::Pdf) {
                extract_image_sources(&content)
                    .into_iter()
                    .map(|src| AnalyzeUrl::get_absolute_url(&ch.url, &src))
                    .collect()
            } else {
                Vec::new()
            };
            ExportChapter {
                index: ch.index,
                title: ch.title.clone(),
                content,
                images,
            }
        })
        .collect();

    let export_data = ExportData {
        title: book.name.clone(),
        author: book.author.clone(),
        intro: book.intro.clone(),
        chapters: export_chapters,
    };

    let config = ExportConfig {
        format: export_format,
        include_toc,
        chapter_separator: String::new(),
        // R8：编码透传（仅 TXT 生效，缺省 UTF-8 行为不变）
        encoding: options
            .encoding
            .clone()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "UTF-8".to_string()),
    };

    // 图片书 PDF 导出：注入网络图片获取器（复用共享 HTTP 客户端，与阅读器下载链路同源）
    let fetcher: Option<Box<ImageFetcher>> = if matches!(export_format, ExportFormat::Pdf) {
        Some(Box::new(|src: &str| {
            crate::runtime::block_on(async {
                crate::http_state::shared_client()
                    .map_err(|e| e.to_string())?
                    .get_bytes(src, None)
                    .await
                    .map_err(|e| e.to_string())
            })
        }))
    } else {
        None
    };

    // 执行导出
    Ok(match BookExporter::export_with(&export_data, &config, fetcher.as_deref()) {
        Ok(bytes) => {
            use base64::Engine;
            let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
            // R8：文件名模板（{name}/{author} 占位符），缺省 = 现行为 `{书名}.{扩展名}`
            let file_name = match options.file_name_template.as_deref().filter(|s| !s.trim().is_empty()) {
                Some(template) => {
                    let base = template
                        .replace("{name}", &book.name)
                        .replace("{author}", &book.author);
                    format!("{}.{}", base, export_format.extension())
                }
                None => format!("{}.{}", book.name, export_format.extension()),
            };
            ExportResult {
                success: true,
                data_base64: Some(b64),
                file_name: Some(file_name),
                mime_type: Some(export_format.mime_type().to_string()),
                error: None,
            }
        }
        Err(e) => ExportResult {
            success: false,
            data_base64: None,
            file_name: None,
            mime_type: None,
            error: Some(format!("导出失败: {e}")),
        },
    })
}

/// 获取导出预览信息
pub fn export_info(book_url: &str, format: &str) -> LegadoResult<ExportResult> {
    let export_format = match ExportFormat::from_str(format) {
        Some(f) => f,
        None => {
            return Ok(ExportResult {
                success: false,
                data_base64: None,
                file_name: None,
                mime_type: None,
                error: Some(format!("不支持的导出格式: {format}")),
            });
        }
    };

    with_database(|db| {
        let book_repo = BookRepository::new(db.connection());
        let book = book_repo.find_by_url(book_url)?;

        match book {
            Some(b) => {
                let chapter_repo = BookChapterRepository::new(db.connection());
                let chapters = chapter_repo.find_by_book_url(book_url)?;
                let file_name = format!("{}.{}", b.name, export_format.extension());
                Ok(ExportResult {
                    success: true,
                    data_base64: None,
                    file_name: Some(file_name),
                    mime_type: Some(export_format.mime_type().to_string()),
                    error: Some(format!("章节数: {}", chapters.len())),
                })
            }
            None => Ok(ExportResult {
                success: false,
                data_base64: None,
                file_name: None,
                mime_type: None,
                error: Some(format!("书籍不存在: {book_url}")),
            }),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::{Book, ReplaceRule};
    use legado_db::repository::Repository;
    use legado_db::{BookRepository, ReplaceRuleRepository};
    use std::io::Write;

    /// 创建临时 TXT 书籍文件（含两个章节）并返回路径
    fn create_temp_txt(suffix_tag: &str) -> String {
        let dir = std::env::temp_dir();
        let path = dir.join(format!(
            "legado_export_test_{suffix_tag}_{}.txt",
            std::process::id()
        ));
        let content =
            "第一章 测试章节一\n这是第一章的正文广告文字。\n第二章 测试章节二\n这是第二章的正文。\n";
        let mut file = std::fs::File::create(&path).unwrap();
        file.write_all(content.as_bytes()).unwrap();
        path.to_string_lossy().to_string()
    }

    /// 在 DB 中注册书籍并解析章节入库（返回串行锁守卫，测试必须绑定到变量）
    fn register_book_and_chapters(book_url: &str, book_name: &str) -> std::sync::MutexGuard<'static, ()> {
        let db_guard = crate::db_state::ensure_test_db();
        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            if book_repo.find_by_url(book_url)?.is_none() {
                book_repo.insert(&Book {
                    book_url: book_url.to_string(),
                    name: book_name.to_string(),
                    ..Book::default()
                })?;
            }
            Ok(())
        })
        .unwrap();
        // 解析章节并入库（与 get_chapters 懒加载逻辑一致）
        let chapters = crate::api::reader::get_chapters(book_url).unwrap();
        assert!(chapters.total >= 2, "临时 TXT 应至少解析出 2 章");
        db_guard
    }

    /// 解码导出结果的 base64 为 UTF-8 文本
    fn decode_export(result: &ExportResult) -> String {
        use base64::Engine;
        assert!(result.success, "导出应成功: {:?}", result.error);
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(result.data_base64.as_ref().unwrap())
            .unwrap();
        String::from_utf8(bytes).unwrap()
    }

    /// 测试本地书导出正文非空（修复仅读缓存导致全空的回归）
    #[test]
    fn test_export_local_book_non_empty_content() {
        let path = create_temp_txt("nonempty");
        let _db_guard = register_book_and_chapters(&path, "导出测试书A");

        let result = export_book(&path, "txt", false).unwrap();
        let text = decode_export(&result);
        assert!(text.contains("第一章"), "导出应包含章节标题");
        assert!(
            text.contains("这是第一章的正文"),
            "本地书导出正文不应为空"
        );
        assert!(text.contains("这是第二章的正文"));

        let _ = std::fs::remove_file(&path);
    }

    /// 测试导出应用替换规则净化（与阅读器/Android 对齐）
    #[test]
    fn test_export_local_book_applies_replace_rules() {
        let path = create_temp_txt("purify");
        let _db_guard = register_book_and_chapters(&path, "导出测试书B");

        // 插入唯一命名的全局启用规则
        let rule_id = with_database(|db| {
            let repo = ReplaceRuleRepository::new(db.connection());
            repo.insert(&ReplaceRule {
                name: "export_测试规则_unique".to_string(),
                pattern: "广告文字".to_string(),
                replacement: String::new(),
                is_regex: false,
                is_enabled: true,
                ..ReplaceRule::default()
            })
        })
        .unwrap();

        let result = export_book(&path, "txt", false).unwrap();
        let text = decode_export(&result);
        assert!(
            !text.contains("广告文字"),
            "导出应已净化（替换规则生效）"
        );
        assert!(text.contains("这是第一章的正文。"), "净化后正文应保留");

        // 清理本测试插入的规则
        with_database(|db| {
            let repo = ReplaceRuleRepository::new(db.connection());
            repo.delete(rule_id)?;
            Ok(())
        })
        .unwrap();
        let _ = std::fs::remove_file(&path);
    }

    /// 集成测试：PDF 格式全链路导出
    ///
    /// 环境有中文字体时应成功且输出有效 PDF（%PDF 文件头）；
    /// 无字体时应优雅降级为带明确错误信息的结果（不 panic）。
    #[test]
    fn test_export_local_book_pdf() {
        let path = create_temp_txt("pdf");
        let _db_guard = register_book_and_chapters(&path, "导出测试书PDF");

        let result = export_book(&path, "pdf", false).unwrap();
        if result.success {
            use base64::Engine;
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(result.data_base64.as_ref().unwrap())
                .unwrap();
            assert!(bytes.len() > 4, "PDF 输出不应为空");
            assert_eq!(&bytes[0..4], b"%PDF", "导出文件应为有效 PDF");
            assert_eq!(
                result.mime_type.as_deref(),
                Some("application/pdf"),
                "MIME 类型应为 application/pdf"
            );
            assert!(
                result.file_name.as_ref().unwrap().ends_with(".pdf"),
                "文件名应以 .pdf 结尾"
            );
        } else {
            // 无 CJK 字体环境：错误信息应明确提示字体问题
            let err = result.error.unwrap_or_default();
            assert!(
                err.contains("字体"),
                "导出失败应提示字体问题: {err}"
            );
        }

        let _ = std::fs::remove_file(&path);
    }

    /// Task #136 R8：GBK 编码导出（对照 Kotlin AppConfig.exportCharset）
    #[test]
    fn test_export_with_gbk_encoding() {
        let path = create_temp_txt("gbk");
        let _db_guard = register_book_and_chapters(&path, "导出测试书GBK");

        let result = export_book_with_options(&path, "txt", false, r#"{"encoding":"GBK"}"#).unwrap();
        assert!(result.success, "GBK 导出应成功: {:?}", result.error);

        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(result.data_base64.as_ref().unwrap())
            .unwrap();
        // GBK 输出非合法 UTF-8（中文首字节 ≥ 0x81）
        assert!(std::str::from_utf8(&bytes).is_err(), "GBK 输出不应为 UTF-8");
        // 首字符「导」的 GBK 编码为 0xB5 0xBC
        assert_eq!(&bytes[0..2], &[0xB5, 0xBC], "首字符应按 GBK 编码");

        let _ = std::fs::remove_file(&path);
    }

    /// Task #136 R8：章节范围筛选（startChapter/endChapter 闭区间）
    #[test]
    fn test_export_with_chapter_range() {
        let path = create_temp_txt("range");
        let _db_guard = register_book_and_chapters(&path, "导出测试书范围");

        // 仅导出第 2 章（index=1）
        let result =
            export_book_with_options(&path, "txt", false, r#"{"startChapter":1,"endChapter":1}"#)
                .unwrap();
        let text = decode_export(&result);
        assert!(text.contains("第二章"), "应包含范围内章节");
        assert!(!text.contains("这是第一章的正文"), "不应包含范围外章节");

        // -1 = 不限（全量）
        let result =
            export_book_with_options(&path, "txt", false, r#"{"startChapter":-1,"endChapter":-1}"#)
                .unwrap();
        let text = decode_export(&result);
        assert!(text.contains("这是第一章的正文") && text.contains("这是第二章的正文"));

        let _ = std::fs::remove_file(&path);
    }

    /// Task #136 R8：文件名模板（{name}/{author} 占位符）与缺省兼容
    #[test]
    fn test_export_with_file_name_template() {
        let path = create_temp_txt("filename");
        let _db_guard = register_book_and_chapters(&path, "导出测试书模板");

        let result = export_book_with_options(
            &path,
            "txt",
            false,
            r#"{"fileNameTemplate":"{name} 作者：{author}"}"#,
        )
        .unwrap();
        assert!(result.success);
        // 测试书 author 为空 → 模板展开为 「导出测试书模板 作者：.txt」
        assert_eq!(
            result.file_name.as_deref(),
            Some("导出测试书模板 作者：.txt")
        );

        // 缺省（空 optionsJson）行为不变：`{书名}.txt`
        let result = export_book_with_options(&path, "txt", false, "").unwrap();
        assert_eq!(result.file_name.as_deref(), Some("导出测试书模板.txt"));

        // 非法 JSON：返回错误结果不 panic
        let result = export_book_with_options(&path, "txt", false, "{bad").unwrap();
        assert!(!result.success);
        assert!(result.error.unwrap().contains("导出选项 JSON 解析失败"));

        let _ = std::fs::remove_file(&path);
    }
}
