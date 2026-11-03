//! 批9b-3 端到端：`retain_comic_images`（契约 §2.46）
//!
//! 覆盖：临时内存库 + 临时图片缓存目录 → FFI 面 `ffi::retain_comic_images`
//! → 实际落盘文件增删。
//!
//! 断言矩阵：
//! 1. 窗口内保留 / 窗口外删除（返回实际删除数）；
//! 2. 窗口内任一章节缺 `cached_chapters` 正文 → 整次跳过（文件全保留）；
//! 3. 非图片书 → 不清理；
//! 4. `retain=0` → 不清理；
//! 5. 相对 `<img src>` 按章节 URL 绝对化后与读写路径同名（保留）；
//! 6. 目录不存在 → 返回 0（幂等）。
//!
//! 进程级环境变量 `LEGADO_IMAGE_CACHE_DIR` 与全局 DB 均为共享状态，
//! 测试串行执行并在收尾清理。

use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, Once};

use legado_ffi::legado_core::cache_book::CachedChapter;
use legado_ffi::legado_core::models::{book_type, Book, BookChapter};
use legado_ffi::legado_db::repository::Repository;
use legado_ffi::legado_db::{BookChapterRepository, BookRepository, CacheBookRepository};

static LOCK: Mutex<()> = Mutex::new(());
static INIT: Once = Once::new();

fn setup() -> MutexGuard<'static, ()> {
    let guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    INIT.call_once(|| {
        let db = legado_ffi::legado_db::init_in_memory_database().expect("内存数据库初始化");
        legado_ffi::db_state::init_database(db).expect("全局连接池初始化");
    });
    guard
}

fn unique_root(tag: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "legado-retain-comic-{}-{}",
        std::process::id(),
        tag
    ))
}

fn with_cache_root<T>(tag: &str, f: impl FnOnce(&PathBuf) -> T) -> T {
    let root = unique_root(tag);
    let _ = fs::remove_dir_all(&root);
    std::env::set_var(
        legado_ffi::api::image_cache_api::CACHE_DIR_ENV,
        root.to_string_lossy().into_owned(),
    );
    let out = f(&root);
    std::env::remove_var(legado_ffi::api::image_cache_api::CACHE_DIR_ENV);
    let _ = fs::remove_dir_all(&root);
    out
}

fn insert_book(book_url: &str, book_type_value: i32) {
    legado_ffi::db_state::with_database(|db| {
        BookRepository::new(db.connection()).insert(&Book {
            book_url: book_url.to_string(),
            origin: "https://e2e-source.example.com".to_string(),
            book_type: book_type_value,
            ..Book::default()
        })
    })
    .expect("插入书籍");
}

fn insert_chapter(book_url: &str, index: i32) -> String {
    let url = format!("https://e2e-source.example.com/{book_url}/ch/{index}");
    legado_ffi::db_state::with_database(|db| {
        BookChapterRepository::new(db.connection()).insert(&BookChapter {
            url: url.clone(),
            title: format!("第{}章", index + 1),
            book_url: book_url.to_string(),
            index,
            ..BookChapter::default()
        })
    })
    .expect("插入章节");
    url
}

fn insert_cached(book_url: &str, index: i32, chapter_url: &str, content: &str) {
    legado_ffi::db_state::with_database(|db| {
        CacheBookRepository::new(db.connection()).insert(&CachedChapter {
            id: 0,
            book_url: book_url.to_string(),
            chapter_index: index,
            chapter_title: format!("第{}章", index + 1),
            chapter_url: chapter_url.to_string(),
            content: content.to_string(),
            cached_at: 0,
            size_bytes: content.len() as i64,
        })
    })
    .expect("插入章节缓存");
}

fn save(url: &str, book_url: &str) {
    assert!(
        legado_ffi::api::image_cache_api::save_image_cache(book_url, url, url.as_bytes()),
        "图片缓存写入应成功: {url}"
    );
}

fn has(book_url: &str, url: &str) -> bool {
    legado_ffi::api::image_cache_api::get_image_cache(book_url, url).is_some()
}

fn call(book_url: &str, dur: i32, retain: i32, pre: i32) -> i32 {
    legado_ffi::ffi::ffi::retain_comic_images(book_url.to_string(), dur, retain, pre)
        .expect("retain_comic_images 不应抛错（降级返回 0）")
}

#[test]
fn e2e_window_keep_and_delete() {
    let _guard = setup();
    with_cache_root("keep-delete", |_root| {
        let book = "https://e2e-retain/keep-delete";
        // Book.bookType 位域图片位 = 64（`IMAGE_BIT`；注意勿用
        // `book_type::IMAGE`=2——那是 BookSourceType 数值域，见契约命名域警告）
        insert_book(book, book_type::IMAGE_BIT);
        let mut urls = Vec::new();
        for i in 0..4 {
            let chapter_url = insert_chapter(book, i);
            let img = format!("https://cdn.example.com/{i}.jpg");
            insert_cached(
                book,
                i,
                &chapter_url,
                &format!("<p><img src=\"{img}\"></p>"),
            );
            save(&img, book);
            urls.push(img);
        }

        // dur=2, retain=1, pre=1 → 窗口 [1,3]，章 0 图片应被删除
        assert_eq!(call(book, 2, 1, 1), 1, "窗口外仅 1 张应删除");
        assert!(!has(book, &urls[0]), "窗口外图片必须删除");
        for (i, url) in urls.iter().enumerate().skip(1) {
            assert!(has(book, url), "窗口内图片必须保留（章 {i}）");
        }
    });
}

#[test]
fn e2e_missing_window_content_skips_cleanup() {
    let _guard = setup();
    with_cache_root("missing-content", |_root| {
        let book = "https://e2e-retain/missing-content";
        insert_book(book, book_type::IMAGE_BIT);
        let mut urls = Vec::new();
        for i in 0..3 {
            let chapter_url = insert_chapter(book, i);
            let img = format!("https://cdn.example.com/missing-{i}.jpg");
            // 章 2 故意不写 cached_chapters（没有正文）
            if i < 2 {
                insert_cached(book, i, &chapter_url, &format!("<img src=\"{img}\">"));
            }
            save(&img, book);
            urls.push(img);
        }

        assert_eq!(
            call(book, 1, 1, 1),
            0,
            "窗口 [0,2] 含缺正文章节时必须整次跳过"
        );
        for url in &urls {
            assert!(has(book, url), "跳过清理时所有图片必须保留: {url}");
        }
    });
}

#[test]
fn e2e_non_image_book_not_cleaned() {
    let _guard = setup();
    with_cache_root("non-image", |_root| {
        let book = "https://e2e-retain/non-image";
        insert_book(book, 8); // BookType.text
        let chapter_url = insert_chapter(book, 0);
        let img = "https://cdn.example.com/textbook.jpg";
        insert_cached(book, 0, &chapter_url, &format!("<img src=\"{img}\">"));
        save(img, book);

        assert_eq!(call(book, 0, 5, 5), 0, "非图片书不得清理");
        assert!(has(book, img), "非图片书图片必须保留");
    });
}

#[test]
fn e2e_retain_zero_not_cleaned() {
    let _guard = setup();
    with_cache_root("retain-zero", |_root| {
        let book = "https://e2e-retain/retain-zero";
        insert_book(book, book_type::IMAGE_BIT);
        let chapter_url = insert_chapter(book, 0);
        let img = "https://cdn.example.com/zero.jpg";
        insert_cached(book, 0, &chapter_url, &format!("<img src=\"{img}\">"));
        save(img, book);

        assert_eq!(call(book, 0, 0, 10), 0, "retain=0 不得清理任何图片");
        assert!(has(book, img), "retain=0 时图片必须保留");
    });
}

#[test]
fn e2e_relative_img_url_absolutized() {
    let _guard = setup();
    with_cache_root("relative", |_root| {
        let book = "https://e2e-retain/relative";
        insert_book(book, book_type::IMAGE_BIT);
        let chapter_url = insert_chapter(book, 0);
        // 正文为相对地址；阅读器以绝对化后的地址作为缓存键
        insert_cached(book, 0, &chapter_url, "<p><img src=\"/img/a.webp\"></p>");
        let absolute = "https://e2e-source.example.com/img/a.webp";
        save(absolute, book);
        let outside = "https://cdn.example.com/outside.jpg";
        save(outside, book);

        assert_eq!(call(book, 0, 1, 0), 1, "仅窗口外图片应删除");
        assert!(
            has(book, absolute),
            "相对 src 绝对化后必须命中保留集合（与读写路径同源）"
        );
        assert!(!has(book, outside), "窗口外图片应删除");
    });
}

#[test]
fn e2e_missing_cache_dir_returns_zero() {
    let _guard = setup();
    with_cache_root("missing-dir", |_root| {
        let book = "https://e2e-retain/missing-dir";
        insert_book(book, book_type::IMAGE_BIT);
        let chapter_url = insert_chapter(book, 0);
        insert_cached(
            book,
            0,
            &chapter_url,
            "<img src=\"https://cdn.example.com/none.jpg\">",
        );
        // 不写任何图片文件（目录不存在）
        assert_eq!(call(book, 0, 1, 0), 0, "目录不存在时幂等返回 0");
    });
}
