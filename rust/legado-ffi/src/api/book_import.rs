//! 书籍导入 API
//!
//! 提供本地书籍格式检测、元数据解析与导入书架的能力。

use serde::{Deserialize, Serialize};

use legado_book::{BookFormat, BookMetadata, LocalBook};
use legado_core::models::Book;
use legado_core::LegadoResult;
use legado_db::repository::Repository;
use legado_db::BookRepository;

use crate::db_state::{resolve_local_book_path, with_database};

/// 书籍格式检测结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DetectFormatResult {
    /// 检测到的格式
    pub format: String,
    /// 文件路径
    pub path: String,
}

/// 导入结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportResult {
    /// 是否成功
    pub success: bool,
    /// 导入的书籍信息（成功时）
    pub book: Option<Book>,
    /// 错误信息（失败时）
    pub error: Option<String>,
}

/// 检测书籍文件格式
pub fn detect_format(file_path: &str) -> LegadoResult<DetectFormatResult> {
    let format = LocalBook::detect_format(file_path)?;
    Ok(DetectFormatResult {
        format: format.as_str().to_string(),
        path: file_path.to_string(),
    })
}

/// 解析书籍元数据
pub fn parse_metadata(file_path: &str) -> LegadoResult<BookMetadata> {
    LocalBook::parse(file_path)
}

/// 导入本地书籍到书架
///
/// 1. 检测格式
/// 2. 解析元数据
/// 3. 构造 Book 实体
/// 4. 插入数据库
///
/// [iOS 视角F C1] `file_path` 可以是「可迁移标识」（相对 Documents 的路径，
/// 如 `books/x.epub`）而非绝对路径：解析/检测时用 [`resolve_local_book_path`]
/// 还原为当前容器的真实路径，而 **`book_url` 原样存 `file_path`**（即标识），
/// 使本地书在重签名/重装（容器 UUID 变化）后仍可按相对标识重建读取。
/// 绝对路径（存量/非 iOS）经 resolver 原样透传，行为不变。
pub fn import_local_book(file_path: &str) -> LegadoResult<ImportResult> {
    // 还原为真实文件路径（相对标识 → 当前 Documents 拼接；绝对/Web 原样）
    let real_path = resolve_local_book_path(file_path);

    // 检测格式（用于验证文件是否为支持的格式）
    let format = LocalBook::detect_format(&real_path)?;

    // 解析元数据
    let metadata = match LocalBook::parse(&real_path) {
        Ok(m) => m,
        Err(e) => {
            return Ok(ImportResult {
                success: false,
                book: None,
                error: Some(format!("元数据解析失败: {e}")),
            });
        }
    };

    // 构造 Book 实体
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let mut book = Book::default();
    book.book_url = file_path.to_string();
    book.name = metadata.title;
    book.author = metadata.author;
    book.intro = Some(metadata.description);
    book.origin = legado_core::models::book::book_type::LOCAL_TAG.to_string();
    book.origin_name = std::path::Path::new(file_path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    // 书类型：本地书基础位 LOCAL；[cbz 批 B | 2026-10-03] `.cbz` 漫画包
    // 额外带 IMAGE_BIT(64) 媒体位（位域组合，对齐 Kotlin `BookType` 位语义；
    // 与 BookSourceType 数值域的 `book_type::IMAGE=2` 不同域，勿混用）。
    // 其余本地格式（txt/epub/mobi/azw/azw3/pdf/umd）保持 LOCAL 无媒体位。
    book.book_type = if format == BookFormat::Cbz {
        legado_core::models::book::book_type::LOCAL
            | legado_core::models::book::book_type::IMAGE_BIT
    } else {
        legado_core::models::book::book_type::LOCAL
    };
    book.last_check_time = now;

    // 插入数据库
    let result = with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.insert(&book)
    });

    match result {
        Ok(()) => Ok(ImportResult {
            success: true,
            book: Some(book),
            error: None,
        }),
        Err(e) => Ok(ImportResult {
            success: false,
            book: None,
            error: Some(format!("导入数据库失败: {e}")),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::book::book_type;

    /// 在临时目录中程序化造一个 CBZ，返回文件路径
    fn make_cbz(dir_name: &str, file_name: &str, entries: &[(&str, &[u8])]) -> String {
        use std::io::Write as _;
        let dir = std::env::temp_dir().join(dir_name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let cbz_path = dir.join(file_name);
        let file = std::fs::File::create(&cbz_path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        for (name, data) in entries {
            writer.start_file(*name, options).unwrap();
            writer.write_all(data).unwrap();
        }
        writer.finish().unwrap();
        cbz_path.to_string_lossy().into_owned()
    }

    /// a) `.cbz` 导入：bookType = LOCAL(0x1000) | IMAGE_BIT(64)，origin 语义不变
    #[test]
    fn import_cbz_sets_local_image_bit() {
        let _db_guard = crate::db_state::ensure_test_db();
        let path = make_cbz(
            "legado_test_import_cbz",
            "本地漫画.cbz",
            &[("01.jpg", b"one"), ("02 续.png", b"two")],
        );

        let res = import_local_book(&path).unwrap();
        assert!(res.success, "导入失败: {:?}", res.error);
        let book = res.book.expect("成功时应有 book");
        assert_eq!(
            book.book_type,
            book_type::LOCAL | book_type::IMAGE_BIT,
            "cbz 应为 LOCAL|IMAGE_BIT"
        );
        assert_eq!(book.book_type, 0x1040);
        assert_ne!(
            book.book_type,
            book_type::IMAGE,
            "位域不得混用数值域 IMAGE=2"
        );
        assert_eq!(book.origin, book_type::LOCAL_TAG, "origin 仍为 loc_book");
        assert_eq!(book.book_url, path, "book_url 应存传入路径");
        assert_eq!(book.name, "本地漫画");

        // 收尾清理共享内存库
        with_database(|db| BookRepository::new(db.connection()).delete_by_url(&path)).unwrap();
        let _ = std::fs::remove_dir_all(std::env::temp_dir().join("legado_test_import_cbz"));
    }

    /// 回归：非 cbz 本地格式（txt）保持 LOCAL 无媒体位
    #[test]
    fn import_txt_keeps_local_without_image_bit() {
        let _db_guard = crate::db_state::ensure_test_db();
        let dir = std::env::temp_dir().join("legado_test_import_txt_regress");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let txt = dir.join("普通小说.txt");
        std::fs::write(&txt, "第一章 开始\n正文内容。\n").unwrap();
        let path = txt.to_string_lossy().into_owned();

        let res = import_local_book(&path).unwrap();
        assert!(res.success, "导入失败: {:?}", res.error);
        let book = res.book.expect("成功时应有 book");
        assert_eq!(book.book_type, book_type::LOCAL, "txt 应保持 LOCAL");
        assert_eq!(book.book_type & book_type::IMAGE_BIT, 0, "不应带图片位");

        with_database(|db| BookRepository::new(db.connection()).delete_by_url(&path)).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
