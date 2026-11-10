//! 原版 `BookController` 端点实现（书架/目录/正文/进度/封面图片/阅读配置）
//!
//! 数据层复用 `db_state` 全局单池（[`AppState.db`]，S28 红线：不新建连接池）
//! 与既有 `legado-db` repositories；抓取链复用 `handlers::web_book::build_engine`
//! （与 `/api/*`、FFI 主链路同一 `RealBookSourceFetcher` 注入面）。
//!
//! Web 页对齐批审查（2026-10-07）收口项：
//! - P1-2：`/cover`、`/image` 本地路径读取白名单（目录 + 扩展名 + 魔数），
//!   见 `read_local_image`；
//! - P1-3：净化替换规则按 `Book.getUseReplaceRule()` 门控（epub/图片书默认
//!   关闭），见 `use_replace_rule`。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use axum::body::Bytes;
use axum::extract::multipart::{Field, Multipart, MultipartRejection};
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use regex::Regex;
use serde::Deserialize;
use serde_json::Value;

use legado_book::{BookFormat, LocalBook};
use legado_core::cache_book::CachedChapter;
use legado_core::content_processor::{
    ContentProcessor, ProcessorConfig, ReplaceJsExecutor, ReplaceRuleEntry, ScopeContext,
};
use legado_core::models::book_type;
use legado_core::models::{Book, BookChapter, ReplaceRule};
use legado_core::web_book::{WebBookEngine, WebChapter};
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::repository::book_repository::BookRepository;
use legado_db::repository::cache_book_repository::CacheBookRepository;
use legado_db::repository::cache_repository::CacheRepository;
use legado_db::repository::replace_rule_repository::ReplaceRuleRepository;
use legado_db::repository::Repository;
use legado_db::BookSourceRepository;
// [批17] `@js:` 执行器与绑定构造复用 legado-js（与 App 端共用同一实现）
use legado_js::replace_rule_js::{
    ReplaceJsBindings, ReplaceJsBook, ReplaceJsChapter, ReplaceRuleJsExecutor,
};
use legado_net::{LegadoClient, LegadoClientConfig};
use tokio::io::AsyncWriteExt;

use super::book_json::{LegacyBook, LegacyBookChapter};
use super::{bytes_response, origin_of, to_response, ReturnData};
use crate::handlers::web_book::{build_engine, RealBookSourceFetcher};
use crate::state::AppState;

/// 原版 `CacheManager` 的 Web 阅读配置键（BookController.kt:335-351）
const WEB_READ_CONFIG_KEY: &str = "webReadConfig";

/// 本地书扩展名白名单（对齐 `legado_book::LocalBook` 可解析格式）
const LOCAL_BOOK_EXTS: &[&str] = &[
    ".epub", ".txt", ".text", ".mobi", ".azw", ".azw3", ".pdf", ".cbz",
];

/// 本地书保存子目录名（对齐 FFI `server_api.rs::LOCAL_BOOK_SUB_DIR` 与
/// Dart `LocalBookStore.subDir`；`bookUrl` 相对可迁移标识的首段）
const LOCAL_BOOK_SUB_DIR: &str = "books";

/// 本地图片扩展名白名单（P1-2 安全加固；对齐 `guess_image_mime` 的常见图片集）
const LOCAL_IMAGE_EXTS: &[&str] = &["png", "jpg", "jpeg", "gif", "webp"];

/// 对齐 Kotlin `Book.isLocal`（BookExtensions.kt:50-56）
///
/// WebDAV 判定经 [`book_type::is_web_dav_origin`] 双前缀识别：
/// 原版/参考版 `webDav::` 与本仓库批18b 前的存量 `dav:` 均视为本地书。
///
/// [批22c] 位判定改用 [`book_type::is_local_type`]：原版 zip 备份恢复不做
/// 类型归一（原版本地书 `type = text|local = 264`，压缩包内书籍 776），
/// 仅认 Rust 域 0x1000 会把它们当在线书（Web 服务按 origin 找书源取正文）。
fn is_local_book(book: &Book) -> bool {
    if book.book_type == 0 {
        return book.origin == book_type::LOCAL_TAG || book_type::is_web_dav_origin(&book.origin);
    }
    book_type::is_local_type(book.book_type)
}

/// 对齐 Kotlin `Book.isEpub`（BookExtensions.kt:61-62：本地书 + 文件名 .epub）
fn is_epub_book(book: &Book) -> bool {
    is_local_book(book) && book.origin_name.to_lowercase().ends_with(".epub")
}

/// 对齐 Kotlin `Book.isImage`（BookExtensions.kt:47-48：`type and BookType.image > 0`）
fn is_image_book(book: &Book) -> bool {
    book.book_type & book_type::IMAGE_BIT > 0
}

/// 原版 `Book.getUseReplaceRule()`（Book.kt:226-236）
///
/// - `readConfig.useReplaceRule` 非空 → 取该值（含 false）；
/// - 否则图片类书源 / epub 本地书默认**关闭**净化；
/// - 其余回退 `AppConfig.replaceEnableDefault`（AppConfig.kt:680，默认 true；
///   Rust Web 服务无 Android 偏好读取桥，固定取其默认值——登记差异）。
fn use_replace_rule(book: &Book) -> bool {
    if let Some(value) = book
        .read_config
        .as_ref()
        .and_then(|config| config.use_replace_rule)
    {
        return value;
    }
    if is_image_book(book) || is_epub_book(book) {
        return false;
    }
    REPLACE_ENABLE_DEFAULT
}

/// `AppConfig.replaceEnableDefault` 的 Kotlin 默认值（AppConfig.kt:680 第二参 true）
const REPLACE_ENABLE_DEFAULT: bool = true;

fn is_local_path(path: &str) -> bool {
    let lower = path.to_lowercase();
    LOCAL_BOOK_EXTS.iter().any(|ext| lower.ends_with(ext))
}

/// 保存根是否为「本地书标准保存根」（末段目录名 = `books`）
///
/// FFI 注入的 `local_book_root` 恒由 DB 路径父目录推导为 `{Documents}/books`
/// （`legado-ffi/src/api/server_api.rs::local_book_root`），与 Dart
/// `LocalBookStore`、FFI `db_state::resolve_local_book_path` 的 `books/*`
/// 相对标识同源。满足该形态时上传书 `bookUrl` 才能安全写相对身份。
fn is_local_book_sub_dir(root: &Path) -> bool {
    root.file_name()
        .and_then(|name| name.to_str())
        .map(|name| name == LOCAL_BOOK_SUB_DIR)
        .unwrap_or(false)
}

/// 上传落盘后的 `bookUrl` 身份（C1 可迁移口径）
///
/// - 保存根为标准 `books` 目录（由 DB 父目录推导）→ 相对可迁移标识
///   `books/<fileName>`，与 FFI `book_import::import_local_book` 写入身份一致，
///   iOS 容器 UUID 变化后仍可按 DB 父目录重建；
/// - 自定义根（测试/非标准宿主）→ 绝对路径，保持既有语义。
fn uploaded_book_identity(root: &Path, target: &Path, file_name: &str) -> String {
    if is_local_book_sub_dir(root) {
        format!("{LOCAL_BOOK_SUB_DIR}/{file_name}")
    } else {
        target.to_string_lossy().into_owned()
    }
}

/// 相对可迁移标识（`books/<file>`）→ 当前注入保存根下的真实路径
///
/// 与 FFI `db_state::resolve_local_book_path` 同语义（以 DB 父目录为基），
/// 但 server 进程无 DB 路径访问权，故以宿主注入的本地书保存根为基——二者
/// 同源（保存根 = DB 父目录/books）。Web URL / 绝对路径原样返回；未注入
/// 保存根或首段不匹配时原样返回（由调用方按文件不存在优雅降级）。
fn resolve_local_book_file(state: &AppState, book_url: &str) -> String {
    if book_url.contains("://") {
        return book_url.to_string();
    }
    let path = Path::new(book_url);
    if path.is_absolute() {
        return book_url.to_string();
    }
    let Some(root) = state.injected_paths.local_book_root.as_ref() else {
        return book_url.to_string();
    };
    let mut components = path.components();
    let first = match components.next() {
        Some(std::path::Component::Normal(segment)) => segment,
        _ => return book_url.to_string(),
    };
    let Some(root_name) = root.file_name() else {
        return book_url.to_string();
    };
    if root_name != first {
        return book_url.to_string();
    }
    let rest: std::path::PathBuf = components.collect();
    if rest.as_os_str().is_empty() {
        root.to_string_lossy().into_owned()
    } else {
        root.join(rest).to_string_lossy().into_owned()
    }
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// GET /getBookshelf
// ---------------------------------------------------------------------------

/// GET `/getBookshelf` — 书架全部书籍（BookController.kt:65-83）
///
/// 取数对齐 Kotlin `appDb.bookDao.all`（`SELECT * FROM books`，不过滤
/// notShelf 临时书）；空书架 → errorMsg「还没有添加小说」。
///
/// 排序：`AppConfig.bookshelfSort` 默认 0 → `durChapterTime` 降序。Rust 侧
/// 暂无 Android 偏好（SharedPreferences）读取桥，固定默认分支（登记差异：
/// 排序模式 1/2/3 与书籍分组排序不生效）。
pub async fn get_bookshelf(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let origin = origin_of(&headers);
    let data = {
        let db = state.db.lock().await;
        let repo = BookRepository::new(db.connection());
        match repo.find_all() {
            Err(e) => Err(e.to_string()),
            Ok(books) if books.is_empty() => Err("还没有添加小说".to_string()),
            Ok(mut books) => {
                books.sort_by_key(|b| std::cmp::Reverse(b.dur_chapter_time));
                let projection: Vec<LegacyBook> = books.iter().map(LegacyBook::from).collect();
                serde_json::to_value(projection).map_err(|e| e.to_string())
            }
        }
    };
    let rd = match data {
        Ok(value) => ReturnData::success(value),
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, "/getBookshelf", origin.as_deref())
}

// ---------------------------------------------------------------------------
// GET /getChapterList
// ---------------------------------------------------------------------------

/// GET `/getChapterList?url=` — 目录（BookController.kt:182-193）
///
/// 直读 DB；空目录时回退 `refreshToc`（本地书解析 / 网络抓取，见
/// [`refresh_toc`]）。
///
/// 登记差异：原版目录抓取前会执行 `preUpdateJs` 钩子并桥接 DB 变量表
///（`WebBook.getChapterListAwait(runPerJs=true)`），本实现走
/// `update_one_toc` 同款引擎入口，不含 preUpdateJs 与 `{{key}}` 变量桥。
pub async fn get_chapter_list(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let book_url = params.get("url").cloned().unwrap_or_default();
    if book_url.is_empty() {
        return to_response(
            &ReturnData::error("参数url不能为空，请指定书籍地址"),
            "/getChapterList",
            origin.as_deref(),
        );
    }

    let direct = {
        let db = state.db.lock().await;
        BookChapterRepository::new(db.connection()).find_by_book_url(&book_url)
    };
    let chapters = match direct {
        Ok(list) if !list.is_empty() => Ok(list),
        Ok(_) => refresh_toc(&state, &book_url).await,
        Err(e) => Err(e.to_string()),
    };

    let rd = match chapters {
        Ok(list) => {
            let projection: Vec<LegacyBookChapter> =
                list.iter().map(LegacyBookChapter::from).collect();
            match serde_json::to_value(projection) {
                Ok(value) => ReturnData::success(value),
                Err(e) => ReturnData::error(e.to_string()),
            }
        }
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, "/getChapterList", origin.as_deref())
}

/// GET `/refreshToc?url=` — 独立目录刷新入口（`BookController.refreshToc`，
/// BookController.kt:145-177；HttpServer.kt GET 路由表 `/refreshToc`）
///
/// 与 [`get_chapter_list`] 的空目录回退**共用同一刷新实现** [`refresh_toc`]
/// （单实现原则，不复制刷新语义）：本地书解析 / 网络书「tocUrl 为空先抓详情」+
/// 目录抓取 + 删旧插新 + 目录派生字段更新，返回刷新后的章节目录。
///
/// 错误文案逐条对齐原版：
/// - url 缺失或空串 → 「参数url不能为空，请指定书籍地址」；
/// - 书不存在 → 「未在数据库找到对应书籍，请先添加」；
/// - 网络书缺源 → 「未找到对应书源,请换源」；
/// - 抓取/落库异常 → 错误串（原版取 `e.localizedMessage`，其兜底文案
///   「refresh toc error」仅在该值为 null 时出现；Rust 错误必有 message，登记）。
///
/// 令牌：原版 `PROTECTED_SOURCE_WRITE_ROUTES` / `PROTECTED_HTTP_LOG_READ_ROUTES`
/// 均不含 `/refreshToc`，故本端点不校验令牌（与原版一致）。
pub async fn refresh_toc_endpoint(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let book_url = params.get("url").cloned().unwrap_or_default();
    let rd = refresh_toc_return_data(&state, &book_url).await;
    to_response(&rd, "/refreshToc", origin.as_deref())
}

/// `/refreshToc` 的 ReturnData 组装（提取为纯函数便于单测）
async fn refresh_toc_return_data(state: &Arc<AppState>, book_url: &str) -> ReturnData {
    if book_url.is_empty() {
        return ReturnData::error("参数url不能为空，请指定书籍地址");
    }
    match refresh_toc(state, book_url).await {
        Ok(list) => {
            let projection: Vec<LegacyBookChapter> =
                list.iter().map(LegacyBookChapter::from).collect();
            match serde_json::to_value(projection) {
                Ok(value) => ReturnData::success(value),
                Err(e) => ReturnData::error(e.to_string()),
            }
        }
        Err(msg) => ReturnData::error(msg),
    }
}

/// 原版 `refreshToc`（BookController.kt:145-177）语义的目录重抓
///
/// - 书籍不存在 → 「未在数据库找到对应书籍，请先添加」
/// - 本地书 → `legado_book::LocalBook` 解析（对齐 `LocalBook.getChapterList`）
/// - 网络书 → 书源缺失「未找到对应书源,请换源」；tocUrl 为空先抓详情补全；
///   目录抓取成功后删旧插新 + 更新目录派生字段（对齐 `delByBook/insert` +
///   `book.update()`）
async fn refresh_toc(state: &Arc<AppState>, book_url: &str) -> Result<Vec<BookChapter>, String> {
    let book = {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .find_by_url(book_url)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "未在数据库找到对应书籍，请先添加".to_string())?
    };

    if is_local_book(&book) || is_local_path(book_url) {
        return refresh_local_toc(state, &book).await;
    }

    let source = {
        let db = state.db.lock().await;
        BookSourceRepository::new(db.connection())
            .find_by_url(&book.origin)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "未找到对应书源,请换源".to_string())?
    };
    let engine = build_engine(state).map_err(|e| e.to_string())?;

    let mut book = book;
    // 原版：tocUrl 为空时先 getBookInfoAwait 补全详情（BookController.kt:163-167）
    if book.toc_url.trim().is_empty() {
        let detail_url = book.book_page_fetch_url().to_string();
        if let Ok(info) = engine.get_book_info(&source, &detail_url).await {
            if !info.toc_url.trim().is_empty() {
                book.toc_url = info.toc_url;
            }
        }
    }
    let fetch_url = toc_fetch_url(&book, book_url);
    let web_chapters = engine
        .get_chapters(&source, &fetch_url)
        .await
        .map_err(|e| e.to_string())?;

    if web_chapters.is_empty() {
        // 原版空列表不抛错，但随后仍执行 `delByBook` + `insert(*toc)` + update()
        // → 旧目录被清空并返回空列表。独立 `/refreshToc` 入口会暴露该语义，
        // 故此处走同一持久化链（删旧 + 更新派生字段为 0），而不是保留旧目录。
        persist_chapters(state, book_url, &[], Some(fetch_url))
            .await
            .map_err(|e| e.to_string())?;
        return Ok(Vec::new());
    }

    // P1-1/P2-1：目录转换统一走 core 单一实现（与 refresh_toc / 换源同语义）
    let chapters = legado_core::web_book::web_chapters_to_book_chapters(&web_chapters, book_url);

    persist_chapters(state, book_url, &chapters, Some(fetch_url))
        .await
        .map_err(|e| e.to_string())?;
    Ok(chapters)
}

/// 目录抓取取址回退链（对齐 `update_one_toc`：tocUrl → 书籍页取址点 → 入参）
fn toc_fetch_url(book: &Book, book_url: &str) -> String {
    let toc = book.toc_url.trim();
    if !toc.is_empty() {
        return toc.to_string();
    }
    let fetch = book.book_page_fetch_url();
    if fetch.trim().is_empty() {
        book_url.to_string()
    } else {
        fetch.to_string()
    }
}

/// 本地书目录解析 + 落库（对齐 `LocalBook.getChapterList` + del/insert/update）
///
/// `bookUrl` 可能为相对可迁移标识（`books/x.epub`，Web 上传/iOS 导入）：
/// 文件解析前经 [`resolve_local_book_file`] 还原真实路径，章节行的
/// `book_url`/`base_url` 仍存原始标识（主键一致）。
async fn refresh_local_toc(state: &Arc<AppState>, book: &Book) -> Result<Vec<BookChapter>, String> {
    let real_path = resolve_local_book_file(state, &book.book_url);
    let chapter_infos =
        legado_book::LocalBook::get_chapters(&real_path).map_err(|e| e.to_string())?;
    let chapters: Vec<BookChapter> = chapter_infos
        .iter()
        .map(|ci| BookChapter {
            url: ci.url.clone(),
            title: ci.title.clone(),
            is_volume: ci.is_volume,
            base_url: book.book_url.clone(),
            book_url: book.book_url.clone(),
            index: ci.index,
            is_vip: false,
            is_pay: false,
            resource_url: None,
            tag: None,
            word_count: None,
            start: ci.start,
            end: ci.end,
            start_fragment_id: None,
            end_fragment_id: None,
            variable: None,
            img_url: None,
        })
        .collect();
    if chapters.is_empty() {
        return Ok(chapters);
    }
    persist_chapters(state, &book.book_url, &chapters, None)
        .await
        .map_err(|e| e.to_string())?;
    Ok(chapters)
}

/// 删旧插新 + 更新目录派生字段（事务内；对齐 refresh_toc/换源事务模式）
///
/// `new_toc_url` 非空时同时持久化（网络抓取成功后的有效目录地址）。
async fn persist_chapters(
    state: &Arc<AppState>,
    book_url: &str,
    chapters: &[BookChapter],
    new_toc_url: Option<String>,
) -> legado_core::LegadoResult<()> {
    let db = state.db.lock().await;
    let conn = db.connection();
    let tx = conn
        .unchecked_transaction()
        .map_err(|e| legado_core::LegadoError::Database(format!("开启事务失败: {e}")))?;
    let chapter_repo = BookChapterRepository::new(conn);
    chapter_repo.delete_by_book_url(book_url)?;
    chapter_repo.insert_batch_no_tx(chapters)?;
    let latest_title = chapters.last().map(|c| c.title.clone());
    BookRepository::new(conn).update_toc_derived_fields(
        book_url,
        chapters.len() as i32,
        latest_title.as_deref(),
        Some(now_millis()),
    )?;
    if let Some(toc_url) = new_toc_url {
        BookRepository::new(conn).update_toc_url(book_url, &toc_url)?;
    }
    tx.commit()
        .map_err(|e| legado_core::LegadoError::Database(format!("提交事务失败: {e}")))?;
    Ok(())
}

// ---------------------------------------------------------------------------
// GET /getBookContent
// ---------------------------------------------------------------------------

/// GET `/getBookContent?url=&index=` — 正文（BookController.kt:198-246）
///
/// 缓存优先（`cached_chapters`，对齐 `BookHelp.getContent`）→ 本地书文件解析
/// → 网络抓取（书源规则）；三条路径返回前均经净化（`includeTitle=false`）。
///
/// 登记差异：
/// 1. 原版章节缺失时最多轮询等待 30s（并发目录抓取场景，BookController.kt:209-218），
///    本实现直读，不做等待；
/// 2. 网络抓取失败原版回 `e.stackTraceStr`（完整堆栈），本实现回错误摘要。
pub async fn get_book_content(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let book_url = params.get("url").cloned().unwrap_or_default();
    let index = params.get("index").and_then(|s| s.parse::<i32>().ok());

    let result = if book_url.is_empty() {
        Err("参数url不能为空，请指定书籍地址".to_string())
    } else if index.is_none() {
        Err("参数index不能为空, 请指定目录序号".to_string())
    } else {
        get_book_content_inner(&state, &book_url, index.unwrap()).await
    };

    let rd = match result {
        Ok(content) => ReturnData::success(Value::String(content)),
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, "/getBookContent", origin.as_deref())
}

async fn get_book_content_inner(
    state: &Arc<AppState>,
    book_url: &str,
    index: i32,
) -> Result<String, String> {
    let (book, chapter) = {
        let db = state.db.lock().await;
        let book = BookRepository::new(db.connection())
            .find_by_url(book_url)
            .map_err(|e| e.to_string())?;
        let chapter = BookChapterRepository::new(db.connection())
            .find_by_book_url_and_index(book_url, index)
            .map_err(|e| e.to_string())?;
        (book, chapter)
    };
    let (Some(book), Some(chapter)) = (book, chapter) else {
        return Err("未找到".to_string());
    };

    // 1) DB 缓存优先（原版 BookHelp.getContent 读本地缓存文件）
    let cached = {
        let db = state.db.lock().await;
        CacheBookRepository::new(db.connection())
            .get_by_book_and_chapter_url(book_url, &chapter.url)
            .map_err(|e| e.to_string())?
    };
    if let Some(cached) = cached.filter(|c| !c.content.trim().is_empty()) {
        return Ok(purify_content(state, &book, &chapter, &cached.content).await);
    }

    // 2) 本地书：文件解析（对齐 BookHelp.getContent 的本地书分支）
    if is_local_book(&book) || is_local_path(book_url) {
        // 相对可迁移标识 → 当前保存根真实路径（绝对路径原样）
        let real_path = resolve_local_book_file(state, &book.book_url);
        let content = legado_book::LocalBook::get_chapter_content(
            &real_path,
            &legado_book::ChapterInfo {
                url: chapter.url.clone(),
                title: chapter.title.clone(),
                index: chapter.index,
                is_volume: chapter.is_volume,
                start: chapter.start,
                end: chapter.end,
            },
        )
        .map_err(|e| e.to_string())?;
        return Ok(purify_content(state, &book, &chapter, &content).await);
    }

    // 3) 网络抓取（对齐 WebBook.getContentAwait）
    let source = {
        let db = state.db.lock().await;
        BookSourceRepository::new(db.connection())
            .find_by_url(&book.origin)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "未找到书源".to_string())?
    };
    let engine: WebBookEngine<RealBookSourceFetcher> =
        build_engine(state).map_err(|e| e.to_string())?;
    let web_chapter = WebChapter::new(chapter.index, chapter.title.clone(), chapter.url.clone());
    let content = engine
        .get_content(&source, &web_chapter)
        .await
        .map_err(|e| e.to_string())?;

    // 获取成功即写缓存（存原始正文；与 ffi fetch_chapter_content 同款时机）
    {
        let db = state.db.lock().await;
        let repo = CacheBookRepository::new(db.connection());
        let record = CachedChapter {
            id: 0,
            book_url: book_url.to_string(),
            chapter_index: chapter.index,
            chapter_title: chapter.title.clone(),
            chapter_url: chapter.url.clone(),
            content: content.clone(),
            cached_at: now_millis(),
            size_bytes: content.len() as i64,
        };
        if let Err(e) = repo.insert(&record) {
            tracing::warn!("写章节缓存失败（忽略，不影响正文返回）: {e}");
        }
    }

    Ok(purify_content(state, &book, &chapter, &content).await)
}

/// 正文净化（替换规则 + 去重复标题；`includeTitle=false`）
///
/// 对齐原版 `ContentProcessor.getContent(book, chapter, content, includeTitle=false)`：
/// 只做正文净化，不重排/不缩进/不去空行（避免改变排版）；简繁转换取默认
/// 关闭（Rust 侧未桥接 `chineseConverterType` 配置，登记差异）。规则作用域
///（scope/excludeScope/scopeContent）交由 `ContentProcessor` 内建过滤，
/// 语义对齐 Kotlin DAO 的 LIKE 判定。
///
/// 替换规则按 `Book.getUseReplaceRule()` 门控（对齐 `ContentProcessor.kt:116`
/// 的 `useReplace && book.getUseReplaceRule()`）：epub 本地书 / 图片书默认不
/// 应用规则；去重复标题不受该门控（原版第一分支恒执行）。
///
/// [批17] `@js:` 规则与 App 端执行口径一致：注入 legado-js 的共享执行器，
/// 章节/书籍绑定取自本节已查出的章节行与书籍行（见
/// [`build_replace_js_bindings`]）；JS 抛错/超时由 `ContentProcessor`
/// 规则级保护保留原文，无 quickjs 时执行器返回 Err 同样保留原文、不 panic。
///
/// [批17 回修 P2] 规则执行（Java 方言正则编译、`@js:` QuickJS、逐规则
/// `recv_timeout` 等待）是 CPU 密集阻塞操作，`/getBookContent` 又无鉴权：
/// 先异步读规则，再把纯计算经 `spawn_blocking` 移交 blocking 线程池，
/// 避免并发请求占满 tokio worker（与 `testReplaceRule` 的 P1-3 同款）。
async fn purify_content(
    state: &Arc<AppState>,
    book: &Book,
    chapter: &BookChapter,
    raw_content: &str,
) -> String {
    let replace_enabled = use_replace_rule(book);
    let rules = {
        let db = state.db.lock().await;
        ReplaceRuleRepository::new(db.connection()).get_enabled_rules()
    };
    let rules = match rules {
        Ok(rules) => rules,
        Err(_) => return raw_content.to_string(),
    };
    let book = book.clone();
    let chapter = chapter.clone();
    let raw = raw_content.to_string();
    match tokio::task::spawn_blocking(move || {
        purify_content_blocking(&book, &chapter, &raw, &rules, replace_enabled)
    })
    .await
    {
        Ok(output) => output,
        Err(error) => {
            tracing::warn!("正文净化阻塞任务失败（返回原文）: {error}");
            raw_content.to_string()
        }
    }
}

/// 正文净化同步核心（仅在 blocking 线程池执行，禁止在 async 上下文直调）
fn purify_content_blocking(
    book: &Book,
    chapter: &BookChapter,
    raw_content: &str,
    rules: &[ReplaceRule],
    replace_enabled: bool,
) -> String {
    let entries = ReplaceRuleEntry::from_replace_rules(rules);
    let config = ProcessorConfig {
        remove_duplicate_title: true,
        re_segment: false,
        chinese_convert: None,
        apply_replace_rules: replace_enabled,
        indent_spaces: 0,
        trim_empty_lines: false,
    };
    // [批17] 与 App 端正文净化同款注入条件：规则生效且确有 `@js:` 正文规则
    // 才构造执行器；非 quickjs 构建执行器 eval 返回 Err，管线按既有口径
    // 保留原文（后续规则不受影响）
    let js_executor: Option<Arc<dyn ReplaceJsExecutor>> =
        if replace_enabled && entries.iter().any(ReplaceRuleEntry::needs_js_execution) {
            Some(Arc::new(ReplaceRuleJsExecutor::new(
                build_replace_js_bindings(book, chapter),
            )))
        } else {
            None
        };
    ContentProcessor::new(config)
        .with_scope_context(ScopeContext::new(book.name.clone(), book.origin.clone()))
        .process_with_js(raw_content, &chapter.title, &entries, js_executor)
}

/// 构建 Web 正文净化 `@js:` 的章节/书籍绑定（对齐 App 端口径）
///
/// 数据全部来自 [`purify_content`] 调用方已查出的行，不额外查库：
/// - 章节：`title`/`index`/`url` 取章节行，`bookUrl` 取解析后的书籍地址；
/// - 书籍：`name`/`author` 取书籍行，`bookUrl` 优先书籍主键、为空时回退
///   章节行的 `bookUrl`（与 App 端 `book ?: chapter.bookUrl` 兜底语义一致）。
///
/// 不变式：`get_book_content_inner` 在章节行缺失时已提前返回「未找到」，
/// 故本函数恒持有真实章节行，不构造 `Option` 防御分支；「章节不在目录」
/// 的 `known_chapter=false` 口径只属于 App 端回退路径（Web 不存在该入口）。
fn build_replace_js_bindings(book: &Book, chapter: &BookChapter) -> ReplaceJsBindings {
    let book_url = if book.book_url.is_empty() {
        chapter.book_url.clone()
    } else {
        book.book_url.clone()
    };
    ReplaceJsBindings::new(
        ReplaceJsChapter {
            title: chapter.title.clone(),
            index: chapter.index,
            url: chapter.url.clone(),
            book_url: book_url.clone(),
        },
        ReplaceJsBook {
            name: book.name.clone(),
            author: book.author.clone(),
            book_url,
        },
    )
}

// ---------------------------------------------------------------------------
// POST /saveBookProgress
// ---------------------------------------------------------------------------

/// 原版 `BookProgress`（BookProgress.kt）反序列化载体
#[derive(Debug, Default, Deserialize)]
struct BookProgressBody {
    #[serde(default)]
    name: String,
    #[serde(default)]
    author: String,
    #[serde(default, rename = "durChapterIndex")]
    dur_chapter_index: i32,
    #[serde(default, rename = "durChapterPos")]
    dur_chapter_pos: i32,
    #[serde(default, rename = "durChapterTime")]
    dur_chapter_time: i64,
    #[serde(default, rename = "durChapterTitle")]
    dur_chapter_title: Option<String>,
}

/// POST `/saveBookProgress` — 保存阅读进度（BookController.kt:276-301）
///
/// 原版按 name+author 定位书籍并更新 4 个进度字段（`durVolumeIndex` 等目录
/// 定位列不在 BookProgress 内，不更新）。请求体按原始字节解析 JSON，容忍
/// `navigator.sendBeacon` 的 `text/plain` Content-Type（报告 §六 #5）。
///
/// 登记差异：原版附带 `AppWebDav.uploadBookProgress` 云端上传，本实现未做
/// （WebDav 配置与上传链在 B3/后续批次）。
pub async fn save_book_progress(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let parsed: Option<BookProgressBody> = serde_json::from_slice(&body)
        .ok()
        .filter(|p: &BookProgressBody| !p.name.is_empty() && !p.author.is_empty());

    let result: Result<Value, String> = match parsed {
        None => Err("格式不对".to_string()),
        Some(progress) => {
            let db = state.db.lock().await;
            let repo = BookRepository::new(db.connection());
            match repo.find_by_name_author(&progress.name, &progress.author) {
                Err(e) => Err(e.to_string()),
                Ok(None) => Err("格式不对".to_string()),
                Ok(Some(book)) => repo
                    .update_progress(
                        &book.book_url,
                        progress.dur_chapter_index,
                        progress.dur_chapter_pos,
                        progress.dur_chapter_title.as_deref(),
                        progress.dur_chapter_time,
                    )
                    .map(|_| Value::String(String::new()))
                    .map_err(|e| e.to_string()),
            }
        }
    };

    let rd = match result {
        Ok(data) => ReturnData::success(data),
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, "/saveBookProgress", origin.as_deref())
}

// ---------------------------------------------------------------------------
// GET /getReadConfig + POST /saveReadConfig
// ---------------------------------------------------------------------------

/// GET `/getReadConfig` — Web 阅读配置（BookController.kt:346-351）
pub async fn get_read_config(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let origin = origin_of(&headers);
    let value = {
        let db = state.db.lock().await;
        CacheRepository::new(db.connection()).get(WEB_READ_CONFIG_KEY)
    };
    let rd = match value {
        Ok(Some(config)) => ReturnData::success(Value::String(config)),
        Ok(None) => ReturnData::error("没有配置"),
        Err(e) => ReturnData::error(e.to_string()),
    };
    to_response(&rd, "/getReadConfig", origin.as_deref())
}

/// POST `/saveReadConfig` — 保存 Web 阅读配置（BookController.kt:335-341）
///
/// 原版把请求体原样字符串写入 `CacheManager`（`caches` 表，键 `webReadConfig`，
/// 无 TTL）；空体等价「无配置」→ 删除键（原版 `postData == null` 分支）。
pub async fn save_read_config(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let payload = String::from_utf8_lossy(&body).to_string();
    let result = {
        let db = state.db.lock().await;
        let repo = CacheRepository::new(db.connection());
        if payload.trim().is_empty() {
            repo.delete(WEB_READ_CONFIG_KEY)
                .map(|_| Value::String(String::new()))
        } else {
            repo.put(WEB_READ_CONFIG_KEY, &payload, 0)
                .map(|_| Value::String(String::new()))
        }
    };
    let rd = match result {
        Ok(data) => ReturnData::success(data),
        Err(e) => ReturnData::error(e.to_string()),
    };
    to_response(&rd, "/saveReadConfig", origin.as_deref())
}

// ---------------------------------------------------------------------------
// GET /cover + GET /image
// ---------------------------------------------------------------------------

/// GET `/cover?path=` — 封面（BookController.kt:88-113）
///
/// 原版经 Glide 预置 84x112 centerCrop 后以 PNG 回传，失败回退默认封面。
/// 本实现为字节级代理：网络 URL 经 [`LegadoClient`] 直取、本地文件经
/// [`read_local_image`] 白名单读取（P1-2），原样回传字节 + 嗅探 Content-Type。
///
/// 登记差异：
/// - 不做 84x112 裁切/重编码 PNG，也不回退内置默认封面（原版
///   `BookCover.defaultDrawable` 为 App 资源，Rust 侧无对应物）；失败回
///   `ReturnData` 错误信封（原版此时回默认封面 PNG）；
/// - 本地 `path` 白名单（P1-2）：仅书库登记的本地书目录内 / 书籍登记的本地
///   封面文件可读，且扩展名与魔数双校验（原版依赖 Android 沙箱，Rust 侧
///   绑 `0.0.0.0` 必须自行收口）。
pub async fn get_cover(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let path = params.get("path").cloned().unwrap_or_default();
    if path.is_empty() {
        return to_response(
            &ReturnData::error("getCover error"),
            "/cover",
            origin.as_deref(),
        );
    }
    match fetch_image_bytes(&state, &path).await {
        Ok((bytes, mime)) => bytes_response(bytes, &mime, "/cover", origin.as_deref()),
        Err(msg) => to_response(&ReturnData::error(msg), "/cover", origin.as_deref()),
    }
}

/// GET `/image?path=&url=&width=` — 正文图片代理（BookController.kt:118-140）
///
/// 校验顺序与错误文案与原版一致（bookUrl 为空 → 图片链接为空 → bookUrl 不对）。
/// 本实现按直链抓取（相对地址以书籍地址为基准解析）；`width` 仅解析不缩放。
/// 解析结果落在本地路径时与 `/cover` 同走 [`read_local_image`] 白名单。
///
/// 地址解析失败（本地书 `bookUrl` 为文件路径、`bookUrl` 为无法解析的垃圾串等）
/// 时不再直接报错，而是把原始 `path` 交给 [`fetch_image_bytes`]：http(s) 走网络
/// 代理，其余一律走 [`read_local_image`] 的 P1-2 三重门（扩展名 + 目录/文件
/// 白名单 + 魔数）。安全性由白名单保证，而非由「必须先解析成 URL」保证；
/// 白名单外的本地路径（含垃圾串场景）仍会被拒绝。
/// 注：Linux 上 `Url::parse("/abs/path/book.txt")` 必然失败（无 scheme），
/// 此入口是本地书图片代理的唯一通路。
///
/// 登记差异：原版经书源「正文图片」规则（`ImageProvider.getImage`）解析并
/// 重编码 PNG，本实现为 HTTP 代理（回上游字节与 Content-Type）。
pub async fn get_image(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let book_url = params.get("url").cloned().unwrap_or_default();
    let path = params.get("path").cloned().unwrap_or_default();

    if book_url.trim().is_empty() {
        return to_response(
            &ReturnData::error("bookUrl为空"),
            "/image",
            origin.as_deref(),
        );
    }
    if path.is_empty() {
        return to_response(
            &ReturnData::error("图片链接为空"),
            "/image",
            origin.as_deref(),
        );
    }
    let book_exists = {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .find_by_url(&book_url)
            .ok()
            .flatten()
            .is_some()
    };
    if !book_exists {
        return to_response(
            &ReturnData::error("bookUrl不对"),
            "/image",
            origin.as_deref(),
        );
    }

    // 解析失败（本地书路径、相对标识、垃圾 bookUrl 等）→ 原样交给
    // fetch_image_bytes：http(s) 走网络代理，其余走 P1-2 白名单三重门。
    // 白名单拒绝即安全（原实现此处直接报错，Linux 上本地书路径永远走不通）。
    let target = resolve_image_url(&book_url, &path).unwrap_or_else(|| path.clone());
    match fetch_image_bytes(&state, &target).await {
        Ok((bytes, mime)) => bytes_response(bytes, &mime, "/image", origin.as_deref()),
        Err(msg) => to_response(&ReturnData::error(msg), "/image", origin.as_deref()),
    }
}

/// 图片地址解析：绝对 http(s) 直用；相对地址以书籍地址为基准拼接
fn resolve_image_url(book_url: &str, path: &str) -> Option<String> {
    if path.starts_with("http://") || path.starts_with("https://") {
        return Some(path.to_string());
    }
    let base = reqwest::Url::parse(book_url).ok()?;
    base.join(path).ok().map(|u| u.to_string())
}

/// 图片字节抓取（网络直链或本地文件）→ (字节, Content-Type)
///
/// 本地分支经 [`read_local_image`] 白名单收口（P1-2）：只有书库登记的本地书
/// 目录内、或书籍登记的本地封面文件才能被读出，且扩展名 + 魔数双重校验。
async fn fetch_image_bytes(state: &Arc<AppState>, path: &str) -> Result<(Vec<u8>, String), String> {
    if path.starts_with("http://") || path.starts_with("https://") {
        let client = LegadoClient::new(LegadoClientConfig::default()).map_err(|e| e.to_string())?;
        let resp = client
            .get_raw(path, None)
            .await
            .map_err(|e| e.to_string())?;
        if !resp.is_success() {
            return Err(format!("图片请求失败: HTTP {}", resp.status));
        }
        let mime = resp
            .header("content-type")
            .cloned()
            .filter(|m| !m.trim().is_empty())
            .unwrap_or_else(|| guess_image_mime(&resp.body, path));
        Ok((resp.body, mime))
    } else {
        read_local_image(state, path).await
    }
}

// ---------------------------------------------------------------------------
// P1-2：本地图片读取白名单
//
// 背景：原版 `/cover`、`/image` 的本地路径经 Glide / ImageProvider 读取，运行在
// Android 沙箱内（应用私有目录 + MediaStore 可读范围）；Rust 侧 Web 服务绑
// `0.0.0.0`（`legado-ffi/src/api/server_api.rs`），进程权限直读等于把本机文件
// 暴露给局域网。故非 http(s) 的 `path` 必须命中「目录白名单 + 扩展名白名单 +
// 魔数校验」三重门（原审查 S-1）。
// ---------------------------------------------------------------------------

/// 本地图片扩展名判定（去 query/fragment 后取末段后缀，忽略大小写）
fn has_local_image_ext(path: &str) -> bool {
    let clean = path.split(['?', '#']).next().unwrap_or(path);
    let ext = clean.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    LOCAL_IMAGE_EXTS.contains(&ext.as_str())
}

/// 受支持图片的魔数校验（与 [`LOCAL_IMAGE_EXTS`] 同集：PNG/JPEG/GIF/WEBP）
fn has_image_magic(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0x89, b'P', b'N', b'G'])
        || bytes.starts_with(&[0xFF, 0xD8, 0xFF])
        || bytes.starts_with(b"GIF8")
        || (bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP")
}

/// 绝对本地路径 → canonical（`None` = URL / 相对标识 / 不存在）
///
/// 相对路径（iOS 可迁移标识 `books/x.epub`）不纳入白名单：相对基准是本进程
/// 工作目录，不可信也不稳定，无法据此做前缀判定。
fn canonical_local_path(raw: &str) -> Option<PathBuf> {
    let raw = raw.trim();
    if raw.is_empty() || raw.contains("://") {
        return None;
    }
    let path = Path::new(raw);
    if !path.is_absolute() {
        return None;
    }
    std::fs::canonicalize(path).ok()
}

/// 采集允许本地读取的路径白名单（全部来自 `books` 表真实登记值 + 宿主注入根）
///
/// - 本地书（对齐 `Book.isLocal`）正文文件所在**目录**：目录前缀放行
///   （本地书目录内的图片属书库内容，含 manga 分目录形态）；
/// - `coverUrl` / `customCoverUrl` 指向的本地**文件**：精确放行（用户自选封面）；
/// - 宿主注入的**图片缓存根**（`AppState.injected_paths.image_cache_root`，
///   FFI `image_cache_api` 的磁盘缓存目录，结构 `{root}/{书目录}/images/`）：
///   目录前缀放行——原版 `/cover`、`/image` 的本地路径运行在 Android 沙箱内，
///   `BookHelp` 图片缓存对渲染层天然可读；Rust 侧以白名单等价该沙箱语义
///   （B3，ACTIVE_PLAN「FFI 图片缓存根注入白名单」登记项落地）。
///
/// 原始登记（2026-10 Web 页对齐批）：图片缓存根属 `legado-ffi` crate，依赖
/// 方向 `legado-ffi → legado-server`，server 不可反向引用，需由 FFI 在构造
/// 服务时注入目录——本批落地为 [`crate::state::InjectedPaths`] 构造期注入，
/// FFI 接线（`server_start` 改调 `serve_web_with_injected_paths`）登记为
/// 未接线（见 server.rs 注释），未注入时本白名单与既有行为完全一致。
///
/// 性能：每次本地读取查一次 `books` 单表（仅对本地封面做 canonicalize），
/// 书架页并发取封面时可接受；若后续成为热点可加短 TTL 缓存。
async fn local_read_allowlist(state: &Arc<AppState>) -> Vec<PathBuf> {
    let books = {
        let db = state.db.lock().await;
        match BookRepository::new(db.connection()).find_all() {
            Ok(books) => books,
            Err(_) => return Vec::new(),
        }
    };
    let mut roots: Vec<PathBuf> = Vec::new();
    for book in &books {
        if is_local_book(book) {
            // 相对可迁移标识先还原到当前保存根，再做白名单前缀判定
            let real_path = resolve_local_book_file(state, &book.book_url);
            if let Some(real) = canonical_local_path(&real_path) {
                let dir = if real.is_dir() {
                    Some(real)
                } else {
                    real.parent().map(Path::to_path_buf)
                };
                if let Some(dir) = dir {
                    roots.push(dir);
                }
            }
        }
        for cover in [book.cover_url.as_deref(), book.custom_cover_url.as_deref()]
            .into_iter()
            .flatten()
        {
            if let Some(file) = canonical_local_path(cover) {
                roots.push(file);
            }
        }
    }
    // 宿主注入的图片缓存根：canonicalize 对齐（根目录可能尚不存在——FFI 侧
    // 首次写缓存时才建目录——失败则按注入原值参与前缀比对）
    if let Some(root) = &state.injected_paths.image_cache_root {
        let canonical = std::fs::canonicalize(root).unwrap_or_else(|_| root.clone());
        roots.push(canonical);
    }
    roots
}

/// 本地图片读取（P1-2 白名单：扩展名 → 目录/文件 → 魔数）
async fn read_local_image(state: &Arc<AppState>, path: &str) -> Result<(Vec<u8>, String), String> {
    if !has_local_image_ext(path) {
        return Err("本地图片格式不允许（仅支持 png/jpg/jpeg/gif/webp）".to_string());
    }
    let canonical = tokio::fs::canonicalize(path)
        .await
        .map_err(|e| format!("读取本地图片失败: {e}"))?;
    let allowlist = local_read_allowlist(state).await;
    let allowed = allowlist
        .iter()
        .any(|root| canonical == *root || canonical.starts_with(root));
    if !allowed {
        return Err("本地路径不在书库允许的图片目录内".to_string());
    }
    let bytes = tokio::fs::read(&canonical)
        .await
        .map_err(|e| format!("读取本地图片失败: {e}"))?;
    if !has_image_magic(&bytes) {
        return Err("本地文件不是受支持的图片格式".to_string());
    }
    let mime = guess_image_mime(&bytes, path);
    Ok((bytes, mime))
}

/// 图片 MIME：魔数优先，其次扩展名，最后 `application/octet-stream`
fn guess_image_mime(bytes: &[u8], path: &str) -> String {
    let head = &bytes[..bytes.len().min(256)];
    let magic = if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        Some("image/png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF8") {
        Some("image/gif")
    } else if bytes.len() > 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else if bytes.starts_with(b"BM") {
        Some("image/bmp")
    } else if head.windows(4).any(|w| w == b"<svg".as_slice()) {
        Some("image/svg+xml")
    } else {
        None
    };
    if let Some(mime) = magic {
        return mime.to_string();
    }
    let ext = path
        .split(['?', '#'])
        .next()
        .unwrap_or(path)
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        _ => "application/octet-stream",
    }
    .to_string()
}

// ---------------------------------------------------------------------------
// B3 写端点：POST /saveBook、/deleteBook、/addLocalBook
//
// 原版依据（HttpServer.kt:88-94 分派 → BookController.kt:251-330）：
// - 三端点**不在** PROTECTED_SOURCE_WRITE_ROUTES（HttpServer.kt:246-258）令牌
//   保护清单内，也无 saveJsSource 式专项校验 → 原版不要求 `x-legado-token`，
//   本实现同样不做令牌校验（vue 客户端拦截器集合亦不含三者，见
//   `assets/web/vue/assets/index-*.js` 的 token 集合）；
// - 请求体经 NanoHTTPD `parseBody` 后以 `files["postData"]` 原文传入
//   （非 multipart 的 JSON body 原样可取），与 /saveBookProgress 同构，
//   故按原始字节解析、不校验 Content-Type。
// ---------------------------------------------------------------------------

/// `/addLocalBook` 上传大小上限（500MB）
///
/// 原版服务端无大小限制（BookController.addLocalBook 直接落盘）；vue 传书页
/// 客户端限制 `fileLimitSize = 500 * 1024 * 1024`
/// （`assets/web/uploadBook/js/common.js:9`）。按我方封堵口径对齐客户端限制
/// 从严设为服务端上限（登记差异：原版服务端不限）。pub 供路由注册处计算
/// body 上限（legacy/mod.rs）。
pub const UPLOAD_MAX_BYTES: u64 = 500 * 1024 * 1024;

/// `/addLocalBook` 扩展名白名单 = 既有 [`LOCAL_BOOK_EXTS`] + `.umd`
///
/// 原版服务端无扩展名白名单（客户端 JS 白名单 `fileTypes =
/// "txt|epub|umd|pdf|mobi|azw3|azw"`，common.js:6）；本实现按 `legado_book`
/// 解析器支持集（`LocalBook::detect_format`：epub/txt(.text)/mobi(.azw/.azw3)/
/// pdf/umd/cbz）从严收口（登记差异：原版服务端不限、由解析链自然拒绝）。
const UPLOAD_BOOK_EXTS: &[&str] = &[
    ".epub", ".txt", ".text", ".mobi", ".azw", ".azw3", ".pdf", ".cbz", ".umd",
];

/// 上传文件名安全校验（逐条对齐原版 `requireSafeUploadedBookFileName`，
/// BookController.kt:39-48）：空白 / `.` / `..` / 含 `/` 或 `\` / Windows 盘符
/// 前缀 `^[A-Za-z]:` / ISO 控制字符 → 不安全。
fn require_safe_uploaded_book_file_name(file_name: &str) -> bool {
    if file_name.is_empty() || file_name.trim().is_empty() {
        return false;
    }
    if file_name == "." || file_name == ".." {
        return false;
    }
    if file_name.contains('/') || file_name.contains('\\') {
        return false;
    }
    if windows_drive_prefix().is_match(file_name) {
        return false;
    }
    if file_name.chars().any(|c| c.is_control()) {
        return false;
    }
    true
}

/// Windows 盘符前缀（BookController.kt:37 `^[A-Za-z]:`）
fn windows_drive_prefix() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new("^[A-Za-z]:").expect("盘符正则编译失败"))
}

/// 上传扩展名白名单判定（忽略大小写，取文件名末段后缀）
fn is_allowed_upload_ext(file_name: &str) -> bool {
    let lower = file_name.to_lowercase();
    UPLOAD_BOOK_EXTS.iter().any(|ext| lower.ends_with(ext))
}

/// 文件名解析书名/作者（对齐原版 `LocalBook.analyzeNameAuthor`，
/// LocalBook.kt:450-488）
///
/// 登记差异：原版先执行用户自定义文件名规则脚本
/// （`AppConfig.bookImportFileName`，JS 引擎），Rust Web 服务无该配置桥，
/// 固定跳过该分支（与书架排序默认分支同款登记口径）。
fn analyze_name_author(file_name: &str) -> (String, String) {
    // `substringBeforeLast(".")`：无点号时取全名
    let temp = match file_name.rsplit_once('.') {
        Some((stem, _)) if !stem.is_empty() => stem.to_string(),
        _ => file_name.to_string(),
    };
    for pattern in name_author_patterns() {
        if let Some(caps) = pattern.captures(&temp) {
            let name = caps
                .get(2)
                .map(|m| m.as_str().to_string())
                .unwrap_or_default();
            let group1 = caps.get(1).map(|m| m.as_str()).unwrap_or("");
            let group3 = caps.get(3).map(|m| m.as_str()).unwrap_or("");
            let author = format_book_author(&format!("{group1}{group3}"));
            return (name, author);
        }
    }
    let name = format_book_name(&temp);
    let author = format_book_author(&temp.replace(&name, ""));
    // 原版 `takeIf { it.length != tempFileName.length } ?: ""`：净化后长度
    // 未变（即规则未剥出作者痕迹）→ 作者置空
    let author = if author.chars().count() == temp.chars().count() {
        String::new()
    } else {
        author
    };
    (name, author)
}

/// 原版 `nameAuthorPatterns`（LocalBook.kt:114-119）
fn name_author_patterns() -> &'static [Regex] {
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        [
            "(.*?)《([^《》]+)》.*?作者：(.*)",
            "(.*?)《([^《》]+)》(.*)",
            "(^)(.+) 作者：(.+)$",
            "(^)(.+) by (.+)$",
        ]
        .iter()
        .map(|p| Regex::new(p).expect("文件名解析正则编译失败"))
        .collect()
    })
}

/// `BookHelp.formatBookName`（BookHelp.kt:629-633；`AppPattern.nameRegex`，
/// AppPattern.kt:32）
fn format_book_name(name: &str) -> String {
    name_regex()
        .replace_all(name, "")
        .trim_matches(|c: char| c <= ' ')
        .to_string()
}

/// `BookHelp.formatBookAuthor`（BookHelp.kt:638-642；`AppPattern.authorRegex`，
/// AppPattern.kt:33）
fn format_book_author(author: &str) -> String {
    author_regex()
        .replace_all(author, "")
        .trim_matches(|c: char| c <= ' ')
        .to_string()
}

fn name_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s+作\s*者.*|\s+\S+\s+著").expect("书名净化正则编译失败"))
}

fn author_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^\s*作\s*者[:：\s]+|\s+著").expect("作者净化正则编译失败"))
}

/// 原版 `appDb.bookDao.minOrder`（BookDao.kt:199-200，`select min("order")
/// from books`；空表 NULL → Room 映射 0）
///
/// 复用既有 `BookRepository::find_all`（单实现原则：不为单端点下沉新
/// repository 方法），空书架回 0。
fn min_order(repo: &BookRepository<'_>) -> i32 {
    repo.find_all()
        .map(|books| books.iter().map(|b| b.order).min().unwrap_or(0))
        .unwrap_or(0)
}

/// 文件修改时间 → 毫秒时间戳（对齐 `FileDoc.lastModified` 作为
/// `latestChapterTime`；失败回 0）
fn file_mtime_millis(path: &Path) -> i64 {
    path.metadata()
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Windows `\\?\` verbatim 前缀剥除
///
/// Rust `std::fs::canonicalize` 在 Windows 返回 verbatim 路径
///（`\\?\C:\...` / `\\?\UNC\server\share`）；原版入库的 bookUrl 是
/// `File.canonicalFile` 的用户可见形态（无 verbatim 前缀），且后续本地
/// 解析链（`LocalBook::get_chapters` 等）按 bookUrl 找文件需与宿主可见
/// 路径一致。非 verbatim 路径原样返回。
fn normalize_verbatim(path: PathBuf) -> PathBuf {
    let s = path.to_string_lossy();
    if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
        return PathBuf::from(format!(r"\\{rest}"));
    }
    if let Some(rest) = s.strip_prefix(r"\\?\") {
        return PathBuf::from(rest.to_string());
    }
    path
}

// ---------------------------------------------------------------------------
// POST /saveBook
// ---------------------------------------------------------------------------

/// POST `/saveBook` — 保存书籍（BookController.kt:251-259）
///
/// 原版语义：`GSON.fromJsonObject<Book>(postData)` 解析失败（null/坏 JSON/
/// 形态不符）→ errorMsg「格式不对」；成功则 `book.save()`（Book.kt:467-473，
/// `has(bookUrl) → update else insert` 的 upsert）→ `setData("")`。
///
/// 我方复用 [`BookRepository::insert`]（既有 upsert 实现：按 bookUrl 判存在
/// → 原地全列 UPDATE / 冲突迁移 / 直插，语义同 Kotlin `Book.save()`）。
///
/// 登记差异：
/// 1. 原版附带 `AppWebDav.uploadBookProgress(book)` 云端上传，未做（与
///    `/saveBookProgress` 批登记口径一致）；
/// 2. 更新分支走我方 `update` 的 [B-3] 结构性语义：进度四列
///    （durChapterIndex/Pos/Title/Time）不被请求快照回滚（原版 Room `@Update`
///    全列覆盖——web 端载荷为打开书架时的陈旧快照，覆盖会丢 App 侧新进度）；
/// 3. Gson 对未知字段宽容忽略（vue 搜索书载荷含 `respondTime` 等非 Book 键），
///    serde 默认同样忽略未知字段；类型不符显式报「格式不对」（防复发第 4 条）。
pub async fn save_book(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    // 先保留原始 JSON：`Book` 的 isPrivate 缺键时 serde 默认 false，而本端点
    // 是整行 upsert（isPrivate 属全列 UPDATE），直接落库会把库内私密标记清掉。
    // 故缺键时必须回读库内旧值保留（Web 只改书名/作者不得解除私密）。
    let raw: Option<Value> = serde_json::from_slice(&body).ok();
    let parsed: Option<Book> = raw
        .as_ref()
        .and_then(|value| serde_json::from_value(value.clone()).ok());
    let result: Result<Value, String> = match parsed {
        None => Err("格式不对".to_string()),
        Some(book) => {
            let has_is_private = raw
                .as_ref()
                .and_then(Value::as_object)
                .map(|obj| obj.contains_key("isPrivate"))
                .unwrap_or(false);
            let mut book = book;
            let db = state.db.lock().await;
            let repo = BookRepository::new(db.connection());
            if !has_is_private {
                match repo.find_by_url(&book.book_url) {
                    Ok(Some(existing)) => book.is_private = existing.is_private,
                    Ok(None) => {}
                    Err(e) => {
                        let rd = ReturnData::error(format!("读取书籍失败：{e}"));
                        return to_response(&rd, "/saveBook", origin.as_deref());
                    }
                }
            }
            repo.insert(&book)
                .map(|_| Value::String(String::new()))
                .map_err(|e| e.to_string())
        }
    };
    let rd = match result {
        Ok(data) => ReturnData::success(data),
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, "/saveBook", origin.as_deref())
}

// ---------------------------------------------------------------------------
// POST /deleteBook
// ---------------------------------------------------------------------------

/// POST `/deleteBook` — 删除书籍（BookController.kt:264-271）
///
/// 原版语义：解析 Book 失败 → 「格式不对」；成功则 `book.delete()`
/// （Book.kt:475-480）= 仅 `appDb.bookDao.delete(this)` 按主键删行（书不存在
/// 时删 0 行亦成功；原版书籍文件/封面缓存清理属 App UI 链
/// `LocalBook.deleteBook`，Web 端点不做）。我方复用
/// [`BookRepository::delete_by_url`]；章节经外键
/// `ON DELETE CASCADE`（schema.rs 与原版 Room `BookChapter.ForeignKey`
/// 级联一致）随行删除。
///
/// 登记差异：`ReadBook.book = null` 为原版 App 进程内存态，Web 服务无对应物。
pub async fn delete_book(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let parsed: Option<Book> = serde_json::from_slice(&body).ok();
    let result: Result<Value, String> = match parsed {
        None => Err("格式不对".to_string()),
        Some(book) => {
            let db = state.db.lock().await;
            BookRepository::new(db.connection())
                .delete_by_url(&book.book_url)
                .map(|_| Value::String(String::new()))
                .map_err(|e| e.to_string())
        }
    };
    let rd = match result {
        Ok(data) => ReturnData::success(data),
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, "/deleteBook", origin.as_deref())
}

// ---------------------------------------------------------------------------
// POST /addLocalBook
// ---------------------------------------------------------------------------

/// multipart 收集结果
struct UploadFields {
    /// 文本字段 `fileName`（vue `fd.append("fileName", file.name)`，
    /// html5_fun.js:138；同名多次出现取首个，对齐原版
    /// `parameters[...]?.firstOrNull()` 语义）
    file_name: Option<String>,
    /// 文件字段 `fileData` 流式落盘的临时文件路径（html5_fun.js:139）
    file_data: Option<PathBuf>,
    /// `fileData` 流式读取/落盘错误（超限、IO 失败；超限为封堵口径，登记）
    error: Option<String>,
}

/// 遍历 multipart 字段：fileName 文本收内存（2KB 上限防滥用，登记从严）、
/// fileData 流式写临时文件（不整包进内存）、其余字段丢弃。
///
/// 原版 NanoHTTPD 把 multipart 文本字段并入 `session.parameters`、文件部件存
/// 临时文件后把「字段名 → 临时文件路径」放进 `files`（BookController.kt:311/318
/// 的取值来源）；字段流式处理与原版临时文件形态一致。
async fn read_upload_fields(multipart: &mut Multipart) -> UploadFields {
    let mut result = UploadFields {
        file_name: None,
        file_data: None,
        error: None,
    };
    while let Ok(Some(field)) = multipart.next_field().await {
        // 先拷出字段名（借用与后续 move 分离）
        let name = field.name().map(|s| s.to_string());
        match name.as_deref() {
            Some("fileName") if result.file_name.is_none() => {
                match read_text_field(field, 2048).await {
                    Ok(text) => result.file_name = Some(text),
                    Err(e) => {
                        result.error = Some(format!("保存书籍错误\n{e}"));
                        return result;
                    }
                }
            }
            Some("fileData") if result.file_data.is_none() => {
                match stream_field_to_temp(field).await {
                    Ok(path) => result.file_data = Some(path),
                    Err(e) => {
                        result.error = Some(e);
                        return result;
                    }
                }
            }
            _ => {
                // 其余字段（含重复出现的 fileName/fileData）排空后丢弃
                let mut field = field;
                while let Ok(Some(_)) = field.chunk().await {}
            }
        }
    }
    result
}

/// 读 multipart 文本字段（超 `max_bytes` 视为滥用拒绝）
async fn read_text_field(mut field: Field<'_>, max_bytes: usize) -> Result<String, String> {
    let mut buf: Vec<u8> = Vec::new();
    while let Some(chunk) = field
        .chunk()
        .await
        .map_err(|e| format!("读取 fileName 失败: {e}"))?
    {
        if buf.len() + chunk.len() > max_bytes {
            return Err("fileName 超过长度上限".to_string());
        }
        buf.extend_from_slice(&chunk);
    }
    String::from_utf8(buf).map_err(|_| "fileName 不是有效的 UTF-8".to_string())
}

/// 上传临时文件进程内序号（与 pid/nanos 共同保证并发唯一：并发请求/并行
/// 测试同时上传时，仅靠时间戳在时钟粒度内可能同名互踩——一处清理会删掉
/// 另一处尚未读取的临时文件）
static UPLOAD_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// 流式写 multipart 文件字段到临时文件
///（`temp_dir/legado-web-upload-{pid}-{seq}-{nanos}`）
///
/// 逐 chunk 写盘并累计大小，超过 [`UPLOAD_MAX_BYTES`] 立即中止删除（登记：
/// 原版服务端无上限，按 vue 客户端 fileLimitSize 从严）。
async fn stream_field_to_temp(mut field: Field<'_>) -> Result<PathBuf, String> {
    let seq = UPLOAD_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let temp_path = std::env::temp_dir().join(format!(
        "legado-web-upload-{}-{seq}-{nanos}",
        std::process::id()
    ));
    let mut file = tokio::fs::File::create(&temp_path).await.map_err(|e| {
        let _ = std::fs::remove_file(&temp_path);
        format!("保存书籍错误\n创建临时文件失败: {e}")
    })?;
    let mut size: u64 = 0;
    loop {
        let chunk = match field.chunk().await {
            Ok(Some(chunk)) => chunk,
            Ok(None) => break,
            Err(e) => {
                drop(file);
                let _ = std::fs::remove_file(&temp_path);
                return Err(format!("保存书籍错误\n读取上传内容失败: {e}"));
            }
        };
        size += chunk.len() as u64;
        if size > UPLOAD_MAX_BYTES {
            drop(file);
            let _ = std::fs::remove_file(&temp_path);
            return Err(format!(
                "保存书籍错误\n上传文件超过大小上限（{}MB）",
                UPLOAD_MAX_BYTES / 1024 / 1024
            ));
        }
        if let Err(e) = file.write_all(&chunk).await {
            drop(file);
            let _ = std::fs::remove_file(&temp_path);
            return Err(format!("保存书籍错误\n写临时文件失败: {e}"));
        }
    }
    // tokio::fs::File 的写入先进内存缓冲（`flush` 前不保证达 OS）；导入链
    // 随后以 `std::fs` 同步读该临时文件，必须先 flush 排空缓冲，否则并发
    // 场景下 metadata/read 可能读到 0 字节（集成测试实测竞态）
    if let Err(e) = file.flush().await {
        drop(file);
        let _ = std::fs::remove_file(&temp_path);
        return Err(format!("保存书籍错误\n刷写临时文件失败: {e}"));
    }
    drop(file);
    Ok(temp_path)
}

/// POST `/addLocalBook` — 接收上传的本地书文件并导入书架
/// （HttpServer.kt:91-94 → BookController.kt:306-330）
///
/// 请求形态（vue 传书页 `assets/web/uploadBook/js/html5_fun.js:137-139`）：
/// `POST /addLocalBook`，multipart/form-data，文本字段 `fileName`（原始文件
/// 名）+ 文件字段 `fileData`（文件字节）。
///
/// 原版链路逐段对照：
/// 1. `parameters["fileName"]` 缺失 → 「fileName 不能为空」（:311-312）；
/// 2. `requireSafeUploadedBookFileName` 失败 → 「fileName 格式不正确」
///    （:313-317；守卫逐条对齐 :39-48）；
/// 3. `files["fileData"]` 缺失 → 「fileData 不能为空」（:318-319）；
/// 4. `LocalBook.saveBookFile(File(fileData).inputStream(), fileName)` 落盘到
///    书籍保存位置 + `LocalBook.importFile(uri)` 导入（:320-322）；
/// 5. SecurityException → 「需重新设置书籍保存位置!」，其余异常 →
///    「保存书籍错误\n{原因}」（:323-328）；成功 → `setData(true)`。
///
/// 落盘语义对齐 `LocalBook.saveBookFile` 文件分支（LocalBook.kt:555-570）：
/// 根目录 `mkdirs` + `resolveLocalBookOutputFile` 的 canonical 包含检查
/// （「书籍文件只能保存到指定路径」，LocalBook.kt:89-96）+ 同名覆盖写
/// （`FileOutputStream` 截断语义）；文件名为空文件时对齐
/// `EmptyFileException`（LocalBook.kt:287）。
///
/// 导入语义对齐 `LocalBook.importFile`（LocalBook.kt:283-320）：
/// - `bookUrl` = 落盘文件的**身份标识**：标准 `books` 保存根（由 DB 父目录
///   推导，C1/O2）下为相对可迁移标识 `books/<fileName>`（与 FFI
///   `import_local_book`、Dart `LocalBookStore` 同源；文件仍落绝对路径），
///   非标准根回退绝对路径；已有同 `bookUrl` 书籍 → 更新链：**行保持
///   不变**，仅删目录（`delByBook`）+ 清书籍缓存（`deleteBook(book,false)` 的
///   `BookHelp.clearCache` 对应我方 `cached_chapters` 行）；原版更新分支同样
///   不回写 books 行（upBookInfo 只改内存对象）；
/// - 新书：`analyzeNameAuthor` 解析名/作者 → `upBookInfo` 对齐（epub/umd/pdf/
///   mobi 走元数据解析覆盖 name/author/intro；txt 不解析——原版 `when` 分支
///   不含 txt；cbz 为我方扩展格式，同走解析）→ 书类型 `text|local`
///   （LocalBook.kt:295；cbz 附加 IMAGE_BIT 对齐 FFI 导入口径）→
///   `insertIgnore` 冲突（同 name+author）→ 「书架中已存在同名同作者书籍：
///   {name} / {author}」（values-zh strings.xml:519）→ `order = minOrder - 1`
///   （LocalBook.kt:301）。
///
/// 安全封堵（原版无限制处按我方口径从严并登记）：
/// - 扩展名白名单 [`UPLOAD_BOOK_EXTS`]（原版服务端无，客户端 JS 有）；
/// - 大小上限 [`UPLOAD_MAX_BYTES`]（原版服务端无，客户端 500MB）；
/// - `fileName` 禁路径分隔符/盘符/控制字符（原版 `requireSafeUploadedBookFileName`
///   逐条对齐）+ 落盘 canonical 包含检查（原版 `resolveLocalBookOutputFile`
///   对齐）→ 路径不可逃逸。
///
/// 登记差异：
/// 1. 保存根来自宿主注入（`AppState.injected_paths.local_book_root`，对应
///    原版 `AppConfig.defaultBookTreeUri`）；未注入时按原版「未设置书籍保存
///    位置」报「保存书籍错误\n没有设置书籍保存位置!」（NoBooksDirException，
///    values-zh strings.xml:1399）；
/// 2. 落盘 IO 失败（目录创建/写目标文件）统一映射原版 SecurityException 分支
///    文案「需重新设置书籍保存位置!」（原版文件分支把 FileNotFoundException
///    包装为 SecurityException，LocalBook.kt:565-568）；
/// 3. multipart 本体损坏/非 multipart 请求按「无部件」处理，落 fileName 缺失
///    分支（原版 NanoHTTPD 对任意 body 宽容 parseBody 后
///    `files["fileData"] == null` 走同一文案）；
/// 4. `withParserCacheInvalidated`（epub/mobi/pdf/umd 解析缓存清理）无对应物
///    ——我方 `LocalBook` 每次全量解析，无持久解析缓存。
pub async fn add_local_book(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
    multipart: Result<Multipart, MultipartRejection>,
) -> Response {
    let origin = origin_of(&headers);
    // multipart 解析失败（非 multipart 请求/本体损坏）按「无上传部件」处理，
    // 落 fileName 缺失分支（对齐原版 NanoHTTPD 宽容 parseBody 后
    // `files["fileData"] == null` 的路径；差异登记见本函数文档注释）
    let mut upload = match multipart {
        Ok(mut mp) => read_upload_fields(&mut mp).await,
        Err(_) => UploadFields {
            file_name: None,
            file_data: None,
            error: None,
        },
    };
    // 临时文件清理路径（异步块会 take 走 file_data，先克隆备清理）
    let temp_for_cleanup = upload.file_data.clone();

    let result: Result<Value, String> = async {
        // 1) fileName：multipart 文本字段优先，回退 query 参数
        //    （原版 session.parameters 同时覆盖 query 与表单字段）
        let raw_file_name = upload
            .file_name
            .take()
            .or_else(|| params.get("fileName").cloned())
            .ok_or_else(|| "fileName 不能为空".to_string())?;
        // 2) 文件名安全校验（原版 requireSafeUploadedBookFileName）
        if !require_safe_uploaded_book_file_name(&raw_file_name) {
            return Err("fileName 格式不正确".to_string());
        }
        // 3) fileData 必须存在（原版 :318-319）
        let temp_path = upload
            .file_data
            .take()
            .ok_or_else(|| "fileData 不能为空".to_string())?;
        // 4) 流式读取/落盘期间的硬错误（超限等）在字段校验之后上报
        if let Some(err) = upload.error.take() {
            return Err(err);
        }
        // 5) 扩展名白名单（封堵口径，登记）
        if !is_allowed_upload_ext(&raw_file_name) {
            let exts = UPLOAD_BOOK_EXTS.join(" / ");
            return Err(format!(
                "保存书籍错误\n不支持的书籍文件扩展名（允许：{exts}）"
            ));
        }
        // 6) 保存根：宿主注入；未注入对齐原版「未设置书籍保存位置」
        let root = state
            .injected_paths
            .local_book_root
            .clone()
            .ok_or_else(|| "保存书籍错误\n没有设置书籍保存位置!".to_string())?;
        import_uploaded_book(&state, &root, &raw_file_name, &temp_path).await
    }
    .await;

    // 临时文件清理（导入为 copy 到目标；成败均清）
    if let Some(temp) = temp_for_cleanup {
        let _ = tokio::fs::remove_file(&temp).await;
    }

    let rd = match result {
        Ok(data) => ReturnData::success(data),
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, "/addLocalBook", origin.as_deref())
}

/// 落盘 + 导入链（`LocalBook.saveBookFile` + `importFile` 对齐，见
/// [`add_local_book`] 文档注释）
async fn import_uploaded_book(
    state: &Arc<AppState>,
    root: &Path,
    file_name: &str,
    temp_path: &Path,
) -> Result<Value, String> {
    // —— 落盘（原版文件分支：mkdirs + canonical 包含检查 + 同名覆盖写）——
    std::fs::create_dir_all(root).map_err(|_| "需重新设置书籍保存位置!".to_string())?;
    let root_canonical =
        std::fs::canonicalize(root).map_err(|_| "需重新设置书籍保存位置!".to_string())?;
    let target_raw = root_canonical.join(file_name);
    if !target_raw.starts_with(&root_canonical) {
        // 对齐 resolveLocalBookOutputFile 的 SecurityException
        //（fileName 校验已禁分隔符，此为纵深防御）
        return Err("需重新设置书籍保存位置!".to_string());
    }
    // Windows canonicalize 产出 `\\?\` verbatim 前缀，直接入库会使 bookUrl
    // 与宿主可见路径不一致（后续 getChapterList/正文读取按 bookUrl 找文件
    // 也须可读）——剥除之，对齐原版 `File.canonicalFile` 的路径形态
    //（原版 resolveLocalBookOutputFile 即返回 canonicalFile，LocalBook.kt:89-96）
    let target = normalize_verbatim(target_raw);
    // 空文件检查（EmptyFileException「Unexpected empty File」；元数据读取
    // 失败另报，不与空文件混同）
    let temp_len = std::fs::metadata(temp_path)
        .map_err(|e| format!("保存书籍错误\n读取上传内容失败: {e}"))?
        .len();
    if temp_len == 0 {
        return Err("保存书籍错误\nUnexpected empty File".to_string());
    }
    std::fs::copy(temp_path, &target).map_err(|_| "需重新设置书籍保存位置!".to_string())?;
    // bookUrl 身份：标准 books 保存根下写相对可迁移标识（C1），
    // 文件仍落 target 绝对路径位置；读侧经 resolve_local_book_file 还原。
    let book_url = uploaded_book_identity(root, &target, file_name);
    let latest_chapter_time = file_mtime_millis(&target);

    // —— 导入（importFile 语义）——
    let db = state.db.lock().await;
    let repo = BookRepository::new(db.connection());
    // 兼容存量：旧版本上传书以容器绝对路径为主键；同一文件重传时仍按旧行
    // 走更新链（不新增重复行、不改写旧行主键），读侧对绝对路径原样兼容。
    let absolute_url = target.to_string_lossy().into_owned();
    let existing_url = if repo
        .find_by_url(&book_url)
        .map_err(|e| e.to_string())?
        .is_some()
    {
        Some(book_url.clone())
    } else if book_url != absolute_url
        && repo
            .find_by_url(&absolute_url)
            .map_err(|e| e.to_string())?
            .is_some()
    {
        Some(absolute_url)
    } else {
        None
    };
    if let Some(existing_url) = existing_url {
        // 更新链：行保持不变（原版更新分支不回写 books 行），删目录 + 清
        // 章节内容缓存（BookHelp.clearCache 对应物）
        BookChapterRepository::new(db.connection())
            .delete_by_book_url(&existing_url)
            .map_err(|e| e.to_string())?;
        CacheBookRepository::new(db.connection())
            .delete_by_book(&existing_url)
            .map_err(|e| e.to_string())?;
        return Ok(Value::Bool(true));
    }

    // 新书：analyzeNameAuthor → upBookInfo 对齐
    let (mut name, mut author) = analyze_name_author(file_name);
    let mut intro: Option<String> = None;
    // 格式检测/元数据解析用真实文件路径（bookUrl 可能是相对标识）
    let format = LocalBook::detect_format(&target.to_string_lossy()).ok();
    let book_type_value = match &format {
        // 我方扩展：cbz 漫画包附加 IMAGE_BIT（对齐 FFI 导入口径）
        Some(BookFormat::Cbz) => book_type::LOCAL | book_type::IMAGE_BIT,
        // 原版 `BookType.text or BookType.local`（LocalBook.kt:295）
        _ => book_type::TEXT | book_type::LOCAL,
    };
    // upBookInfo：原版 when 分支仅 epub/umd/pdf/mobi 走元数据解析；txt 不解析
    //（cbz 为我方扩展，同走解析）。名称/作者仅在解析出非空值时覆盖，
    // 简介非空才写入。
    if matches!(
        format,
        Some(
            BookFormat::Epub
                | BookFormat::Mobi
                | BookFormat::Pdf
                | BookFormat::Umd
                | BookFormat::Cbz
        )
    ) {
        if let Ok(meta) = LocalBook::parse(&target.to_string_lossy()) {
            if !meta.title.trim().is_empty() {
                name = meta.title;
            }
            if !meta.author.trim().is_empty() {
                author = meta.author;
            }
            if !meta.description.trim().is_empty() {
                intro = Some(meta.description);
            }
        }
    }
    // insertIgnore 冲突对齐：同 name+author 唯一冲突 → 显式报错
    if repo
        .find_by_name_author(&name, &author)
        .map_err(|e| e.to_string())?
        .is_some()
    {
        return Err(format!("书架中已存在同名同作者书籍：{name} / {author}"));
    }
    let order = min_order(&repo).saturating_sub(1);
    let book = Book {
        book_url,
        name,
        author,
        origin_name: file_name.to_string(),
        origin: book_type::LOCAL_TAG.to_string(),
        book_type: book_type_value,
        intro,
        latest_chapter_time,
        order,
        ..Book::default()
    };
    repo.insert(&book).map_err(|e| e.to_string())?;
    Ok(Value::Bool(true))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_toc_fetch_url_fallback_chain() {
        let book = Book {
            book_url: "https://a.example/book".to_string(),
            toc_url: "https://a.example/toc".to_string(),
            origin_book_url: "https://a.example/detail".to_string(),
            ..Book::default()
        };
        assert_eq!(toc_fetch_url(&book, "x"), "https://a.example/toc");

        // 空 tocUrl → 书籍页取址点（originBookUrl）
        let book = Book {
            toc_url: String::new(),
            ..book
        };
        assert_eq!(toc_fetch_url(&book, "x"), "https://a.example/detail");

        // originBookUrl 为空 → book_page_fetch_url 回退 bookUrl（非空即用它）
        let book = Book {
            origin_book_url: String::new(),
            ..book
        };
        assert_eq!(toc_fetch_url(&book, "fallback"), "https://a.example/book");

        // bookUrl 也为空（极端存量行）→ 回退入参
        let book = Book {
            book_url: String::new(),
            ..book
        };
        assert_eq!(toc_fetch_url(&book, "fallback"), "fallback");
    }

    #[test]
    fn test_is_local_book() {
        let mut book = Book {
            origin: "loc_book".to_string(),
            ..Book::default()
        };
        assert!(is_local_book(&book));

        // 原版 WebDav 标记为 `webDav::`（BookType.kt:76），可带
        // `,{"serverID":N}` 属性后缀
        book = Book {
            origin: "webDav::https://x/book.epub, {\"serverID\":12}".to_string(),
            ..Book::default()
        };
        assert!(is_local_book(&book));

        // 存量旧值 `dav:` 仍按 WebDAV 本地书读取兼容（批18b 双前缀）
        book = Book {
            origin: "dav:https://x/book.epub".to_string(),
            ..Book::default()
        };
        assert!(is_local_book(&book));

        book = Book {
            origin: "dav:/x".to_string(),
            ..Book::default()
        };
        assert!(is_local_book(&book));

        book = Book {
            origin: "https://src".to_string(),
            book_type: book_type::LOCAL,
            ..Book::default()
        };
        assert!(is_local_book(&book));

        book = Book {
            origin: "https://src".to_string(),
            book_type: book_type::TEXT,
            ..Book::default()
        };
        assert!(!is_local_book(&book));

        // —— 批22c：原版 Kotlin 位域（0x100）双标准 ——
        // 原版本地书 `type = text(8)|local(256) = 264`（LocalBook.kt:295），
        // origin 为本仓库与参考版共用的 `loc_book`；zip 备份原样落库。
        book = Book {
            origin: "loc_book".to_string(),
            book_type: 264,
            ..Book::default()
        };
        assert!(is_local_book(&book), "原版本地书 264 应判本地");

        // 原版压缩包内书籍 `type = text|local|archive = 776`（LocalBook.kt:396）
        book = Book {
            origin: "loc_book".to_string(),
            book_type: 776,
            ..Book::default()
        };
        assert!(is_local_book(&book), "原版压缩包内书籍 776 应判本地");

        // 原版在线文字书 `type = text(8)` + http(s) origin → 非本地
        // （不能仅按 origin 反推，也不能把 Kotlin text 位误当本地位）
        for origin in ["http://src", "https://src"] {
            book = Book {
                origin: origin.to_string(),
                book_type: 8,
                ..Book::default()
            };
            assert!(
                !is_local_book(&book),
                "在线书 type=8 origin={origin} 不应判本地"
            );
        }

        // type 非 0 但 origin 为 `loc_book`（异常存量：本地 origin 无本地位）
        // 仍按 Kotlin 语义判非本地（type != 0 只看位，不看 origin）
        book = Book {
            origin: "loc_book".to_string(),
            book_type: 8,
            ..Book::default()
        };
        assert!(!is_local_book(&book));

        // 两个本地位并存（跨域数据混写）也不漏判
        book = Book {
            origin: "https://src".to_string(),
            book_type: book_type::LOCAL | book_type::KOTLIN_LOCAL_BIT,
            ..Book::default()
        };
        assert!(is_local_book(&book));
    }

    /// P1-3：`Book.getUseReplaceRule()`（Book.kt:226-236）对齐
    #[test]
    fn test_use_replace_rule_gating() {
        // 未设置：普通在线文字书 → 回退 AppConfig.replaceEnableDefault(true)
        let text = Book {
            origin: "https://src".to_string(),
            book_type: book_type::TEXT,
            ..Book::default()
        };
        assert!(use_replace_rule(&text));

        // epub 本地书 → 默认关闭
        let epub = Book {
            origin: "loc_book".to_string(),
            origin_name: "book.epub".to_string(),
            book_type: book_type::LOCAL,
            ..Book::default()
        };
        assert!(is_epub_book(&epub));
        assert!(!use_replace_rule(&epub));

        // 本地图片书（IMAGE_BIT 位域）→ 默认关闭
        let image = Book {
            origin: "loc_book".to_string(),
            book_type: book_type::LOCAL | book_type::IMAGE_BIT,
            ..Book::default()
        };
        assert!(is_image_book(&image));
        assert!(!use_replace_rule(&image));

        // 在线图片书源（type 数值域 IMAGE=2 不属位域 64）→ 不误判
        let online_image = Book {
            origin: "https://src".to_string(),
            book_type: book_type::IMAGE,
            ..Book::default()
        };
        assert!(!is_image_book(&online_image));
        assert!(use_replace_rule(&online_image));

        // readConfig.useReplaceRule 非空 → 取该值（含对 epub 显式开启）
        let epub_on = Book {
            read_config: Some(legado_core::models::ReadConfig {
                use_replace_rule: Some(true),
                ..Default::default()
            }),
            ..epub.clone()
        };
        assert!(use_replace_rule(&epub_on));

        let text_off = Book {
            read_config: Some(legado_core::models::ReadConfig {
                use_replace_rule: Some(false),
                ..Default::default()
            }),
            ..text
        };
        assert!(!use_replace_rule(&text_off));
    }

    /// P1-2：本地图片扩展名白名单
    #[test]
    fn test_has_local_image_ext() {
        assert!(has_local_image_ext("D:/x/cover.PNG"));
        assert!(has_local_image_ext("/a/b.jpg?raw=1"));
        assert!(has_local_image_ext("/a/b.webp#frag"));
        assert!(!has_local_image_ext("/etc/passwd"));
        assert!(!has_local_image_ext("/a/b.txt"));
        assert!(!has_local_image_ext("/a/b.png.txt"));
    }

    /// P1-2：图片魔数校验（防扩展名伪造）
    #[test]
    fn test_has_image_magic() {
        assert!(has_image_magic(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A]));
        assert!(has_image_magic(&[0xFF, 0xD8, 0xFF, 0xE0]));
        assert!(has_image_magic(b"GIF89a"));
        let mut webp = b"RIFF".to_vec();
        webp.extend_from_slice(&[0, 0, 0, 0]);
        webp.extend_from_slice(b"WEBP");
        assert!(has_image_magic(&webp));
        assert!(!has_image_magic(b"plain text"));
        assert!(!has_image_magic(
            b"<svg xmlns=\"http://www.w3.org/2000/svg\">"
        ));
    }

    /// P1-2：URL / 相对标识不进入白名单（不可信基准）
    #[test]
    fn test_canonical_local_path_scope() {
        assert!(canonical_local_path("https://x/a.png").is_none());
        assert!(canonical_local_path("books/a.epub").is_none());
        assert!(canonical_local_path("").is_none());
        // 存在的绝对路径可解析（canonical 化）
        let path = std::env::temp_dir();
        assert!(canonical_local_path(&path.to_string_lossy()).is_some());
        // 不存在的绝对路径 → None
        assert!(canonical_local_path("Z:/definitely/not/exist/x.png").is_none());
    }

    #[test]
    fn test_resolve_image_url() {
        assert_eq!(
            resolve_image_url("https://a.example/book/1", "https://img.example/x.png").unwrap(),
            "https://img.example/x.png"
        );
        assert_eq!(
            resolve_image_url("https://a.example/book/1", "/img/x.png").unwrap(),
            "https://a.example/img/x.png"
        );
        assert_eq!(
            resolve_image_url("https://a.example/book/1", "//img.example/x.png").unwrap(),
            "https://img.example/x.png"
        );
        assert!(resolve_image_url("not-a-url", "/x.png").is_none());
    }

    #[test]
    fn test_guess_image_mime() {
        assert_eq!(
            guess_image_mime(&[0x89, b'P', b'N', b'G'], "x.bin"),
            "image/png"
        );
        assert_eq!(guess_image_mime(b"xxxx", "a.jpg"), "image/jpeg");
        assert_eq!(
            guess_image_mime(b"xxxx", "a.bin"),
            "application/octet-stream"
        );
    }

    #[test]
    fn test_book_progress_body_defaults() {
        let body: BookProgressBody = serde_json::from_str(r#"{"name":"a","author":"b"}"#).unwrap();
        assert_eq!(body.name, "a");
        assert_eq!(body.dur_chapter_index, 0);
        assert!(body.dur_chapter_title.is_none());
    }

    /// B3：上传文件名安全校验逐条对齐原版 `requireSafeUploadedBookFileName`
    ///（BookController.kt:39-48）
    #[test]
    fn test_require_safe_uploaded_book_file_name() {
        assert!(require_safe_uploaded_book_file_name("正常书名.txt"));
        assert!(require_safe_uploaded_book_file_name(
            "斗破苍穹《新版》.epub"
        ));
        // 空白 / `.` / `..`
        assert!(!require_safe_uploaded_book_file_name(""));
        assert!(!require_safe_uploaded_book_file_name("   "));
        assert!(!require_safe_uploaded_book_file_name("."));
        assert!(!require_safe_uploaded_book_file_name(".."));
        // 路径分隔符
        assert!(!require_safe_uploaded_book_file_name("a/b.txt"));
        assert!(!require_safe_uploaded_book_file_name(r"a\b.txt"));
        assert!(!require_safe_uploaded_book_file_name("../evil.txt"));
        // Windows 盘符前缀
        assert!(!require_safe_uploaded_book_file_name("C:evil.txt"));
        assert!(!require_safe_uploaded_book_file_name("d:x.txt"));
        // ISO 控制字符
        assert!(!require_safe_uploaded_book_file_name("a\u{0001}b.txt"));
        assert!(!require_safe_uploaded_book_file_name("a\u{007f}b.txt"));
    }

    /// B3：上传扩展名白名单（解析器支持集；忽略大小写）
    #[test]
    fn test_is_allowed_upload_ext() {
        for name in [
            "a.txt", "b.TXT", "c.epub", "d.text", "e.mobi", "f.azw", "g.azw3", "h.pdf", "i.umd",
            "j.cbz",
        ] {
            assert!(is_allowed_upload_ext(name), "{name} 应在白名单");
        }
        for name in ["a.exe", "b.bat", "c.zip", "d.docx", "e.txt.exe", "noext"] {
            assert!(!is_allowed_upload_ext(name), "{name} 不应在白名单");
        }
    }

    /// B3：文件名解析书名/作者（对齐 `LocalBook.analyzeNameAuthor` 的 4 组
    /// 正则与兜底；JS 规则分支无配置桥，登记跳过）
    #[test]
    fn test_analyze_name_author() {
        // 《书名》作者：xxx（模式 1；作者 = formatBookAuthor(group1+group3)，
        // 原版把前缀与作者拼接后再净化——逐字对齐）
        assert_eq!(
            analyze_name_author("斗破苍穹《完整版》作者：天蚕土豆.txt"),
            ("完整版".to_string(), "斗破苍穹天蚕土豆".to_string())
        );
        // 「作者《书名》其他」（模式 2 常见形态：前缀即作者）
        assert_eq!(
            analyze_name_author("天蚕土豆《斗破苍穹》.txt"),
            ("斗破苍穹".to_string(), "天蚕土豆".to_string())
        );
        // 《书名》其他（模式 2）
        assert_eq!(
            analyze_name_author("《三体》刘慈欣.epub"),
            ("三体".to_string(), "刘慈欣".to_string())
        );
        // "书名 作者：xxx"（模式 3，要求书名前空格）
        assert_eq!(
            analyze_name_author("遮天 作者：辰东.txt"),
            ("遮天".to_string(), "辰东".to_string())
        );
        // "书名 by xxx"（模式 4）
        assert_eq!(
            analyze_name_author("Foundation by Asimov.txt"),
            ("Foundation".to_string(), "Asimov".to_string())
        );
        // 无模式命中：书名取净化后文件名、作者为空
        assert_eq!(
            analyze_name_author("三体.txt"),
            ("三体".to_string(), String::new())
        );
        // 无扩展名
        assert_eq!(
            analyze_name_author("凡人修仙传"),
            ("凡人修仙传".to_string(), String::new())
        );
    }

    /// B3：`formatBookName`/`formatBookAuthor`（AppPattern.kt:32-33 对齐）
    #[test]
    fn test_format_book_name_author() {
        assert_eq!(format_book_name("三体"), "三体");
        // nameRegex `\s+\S+\s+著`：剥「空格 词 空格 著」段
        assert_eq!(format_book_name("某某 李四 著"), "某某");
        assert_eq!(format_book_author("作者：张三"), "张三");
        assert_eq!(format_book_author("张三 著"), "张三");
    }

    /// B3：minOrder 空表回 0（Room NULL→0 对齐）、有书取最小值
    #[test]
    fn test_min_order() {
        let db = legado_db::init_in_memory_database().unwrap();
        let repo = BookRepository::new(db.connection());
        assert_eq!(min_order(&repo), 0);
        let mut book = Book {
            book_url: "u1".to_string(),
            name: "n1".to_string(),
            ..Book::default()
        };
        book.order = 5;
        repo.insert(&book).unwrap();
        assert_eq!(min_order(&repo), 5);
    }

    // ─── P1-3：addLocalBook 相对身份（C1 可迁移口径） ─────────────────────

    /// 测试用 AppState（内存库 + 可选本地书保存根）
    fn make_state(local_book_root: Option<PathBuf>) -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: tokio::sync::Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
            injected_paths: crate::state::InjectedPaths {
                image_cache_root: None,
                local_book_root,
            },
            legacy_review: Default::default(),
            source_check: Default::default(),
        })
    }

    /// 身份函数：标准 books 根 → 相对标识；自定义根 → 绝对路径回退
    #[test]
    fn test_uploaded_book_identity() {
        let books_root = Path::new("D:/docs/books");
        assert_eq!(
            uploaded_book_identity(books_root, Path::new("D:/docs/books/a.txt"), "a.txt"),
            "books/a.txt"
        );
        let custom_root = Path::new("D:/tmp/upload");
        assert_eq!(
            uploaded_book_identity(custom_root, Path::new("D:/tmp/upload/a.txt"), "a.txt"),
            "D:/tmp/upload/a.txt"
        );
    }

    /// 解析器：books/<file> → 注入根拼接；绝对路径/URL 原样
    #[test]
    fn test_resolve_local_book_file() {
        let base =
            std::env::temp_dir().join(format!("legado_resolve_books_{}", std::process::id()));
        let root = base.join("books");
        let state = make_state(Some(root.clone()));

        let resolved = resolve_local_book_file(&state, "books/a.epub");
        assert_eq!(Path::new(&resolved), root.join("a.epub"));

        // 非 books 首段 / Web URL / 绝对路径 → 原样
        assert_eq!(
            resolve_local_book_file(&state, "other/a.epub"),
            "other/a.epub"
        );
        assert_eq!(
            resolve_local_book_file(&state, "https://x/a.epub"),
            "https://x/a.epub"
        );
        let abs = root.join("a.epub");
        assert_eq!(
            resolve_local_book_file(&state, &abs.to_string_lossy()),
            abs.to_string_lossy()
        );
    }

    /// 上传导入落库相对身份 + 目录/正文读链可解析（addLocalBook 核心回归）
    #[tokio::test]
    async fn test_import_uploaded_book_relative_identity_and_reader_chain() {
        let base = std::env::temp_dir().join(format!(
            "legado_upload_identity_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let books = base.join("books");
        std::fs::create_dir_all(&books).unwrap();
        let temp = base.join("upload.tmp");
        std::fs::write(&temp, "第一章\n正文一\n\n第二章\n正文二\n").unwrap();
        let state = make_state(Some(books.clone()));

        import_uploaded_book(&state, &books, "测试书.txt", &temp)
            .await
            .unwrap();

        // 1) books 表身份为相对可迁移标识（非容器绝对路径）
        let book_url = {
            let db = state.db.lock().await;
            let books_rows = BookRepository::new(db.connection()).find_all().unwrap();
            assert_eq!(books_rows.len(), 1);
            assert_eq!(
                books_rows[0].book_url, "books/测试书.txt",
                "bookUrl 应存相对可迁移标识（iOS 容器 UUID 变化后仍可解析）"
            );
            books_rows[0].book_url.clone()
        };
        // 2) 文件仍落在注入保存根的绝对位置
        assert!(books.join("测试书.txt").is_file(), "上传文件应落绝对保存根");

        // 3) 读链：目录 + 正文均经 resolve_local_book_file 还原真实路径
        let chapters = refresh_toc(&state, &book_url).await.unwrap();
        assert!(!chapters.is_empty(), "相对标识应能解析出目录");
        let content = get_book_content_inner(&state, &book_url, 0).await.unwrap();
        assert!(
            content.contains("正文一"),
            "相对标识应能读到正文：{content}"
        );

        let _ = std::fs::remove_dir_all(&base);
    }

    /// 存量兼容：旧版本以绝对路径落库的同名文件重传 → 走旧行更新链，
    /// 不新增重复行、不改写旧主键（读侧绝对路径原样兼容）
    #[tokio::test]
    async fn test_import_uploaded_book_legacy_absolute_row_reupload_updates() {
        let base = std::env::temp_dir().join(format!(
            "legado_upload_legacy_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let books = base.join("books");
        std::fs::create_dir_all(&books).unwrap();
        let temp = base.join("upload.tmp");
        std::fs::write(&temp, "第一章\n旧书正文\n").unwrap();
        let state = make_state(Some(books.clone()));

        let absolute_url = books.join("旧书.txt").to_string_lossy().into_owned();
        {
            let db = state.db.lock().await;
            BookRepository::new(db.connection())
                .insert(&Book {
                    book_url: absolute_url.clone(),
                    name: "旧书".to_string(),
                    origin: book_type::LOCAL_TAG.to_string(),
                    book_type: book_type::TEXT | book_type::LOCAL,
                    ..Book::default()
                })
                .unwrap();
        }

        import_uploaded_book(&state, &books, "旧书.txt", &temp)
            .await
            .unwrap();

        let db = state.db.lock().await;
        let rows = BookRepository::new(db.connection()).find_all().unwrap();
        assert_eq!(rows.len(), 1, "重传不应产生重复书行");
        assert_eq!(rows[0].book_url, absolute_url, "旧行主键保持不变");
    }

    // ─── B10：GET /refreshToc 独立入口 ────────────────────────────────────

    /// 缺参：错误文案对齐原版 `refreshToc`（BookController.kt:148-151）
    #[tokio::test]
    async fn test_refresh_toc_endpoint_missing_url() {
        let state = make_state(None);
        let rd = refresh_toc_return_data(&state, "").await;
        assert!(!rd.is_success);
        assert_eq!(rd.error_msg, "参数url不能为空，请指定书籍地址");
        assert!(rd.data.is_null());
    }

    /// 书不存在：错误文案对齐原版（:152-153）
    #[tokio::test]
    async fn test_refresh_toc_endpoint_book_not_found() {
        let state = make_state(None);
        let rd = refresh_toc_return_data(&state, "https://x.example/book/1").await;
        assert!(!rd.is_success);
        assert_eq!(rd.error_msg, "未在数据库找到对应书籍，请先添加");
    }

    /// 网络书缺源：错误文案对齐原版（:161-162）
    #[tokio::test]
    async fn test_refresh_toc_endpoint_source_missing() {
        let state = make_state(None);
        let book_url = "https://x.example/book/1";
        {
            let db = state.db.lock().await;
            BookRepository::new(db.connection())
                .insert(&Book {
                    book_url: book_url.to_string(),
                    name: "无源书".to_string(),
                    origin: "https://x.example/src".to_string(),
                    toc_url: "https://x.example/toc".to_string(),
                    book_type: book_type::TEXT,
                    ..Book::default()
                })
                .unwrap();
        }
        let rd = refresh_toc_return_data(&state, book_url).await;
        assert!(!rd.is_success);
        assert_eq!(rd.error_msg, "未找到对应书源,请换源");
    }

    /// 正例（本地书）：刷新解析目录并落库，返回目录数组
    #[tokio::test]
    async fn test_refresh_toc_endpoint_local_book_success() {
        let base = std::env::temp_dir().join(format!(
            "legado_refresh_toc_local_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let books = base.join("books");
        std::fs::create_dir_all(&books).unwrap();
        std::fs::write(
            books.join("刷新书.txt"),
            "第一章 开端\n正文一\n\n第二章 终章\n正文二\n",
        )
        .unwrap();
        let state = make_state(Some(books.clone()));
        let book_url = "books/刷新书.txt";
        {
            let db = state.db.lock().await;
            BookRepository::new(db.connection())
                .insert(&Book {
                    book_url: book_url.to_string(),
                    name: "刷新书".to_string(),
                    origin: book_type::LOCAL_TAG.to_string(),
                    book_type: book_type::TEXT | book_type::LOCAL,
                    ..Book::default()
                })
                .unwrap();
        }

        let rd = refresh_toc_return_data(&state, book_url).await;
        assert!(rd.is_success, "本地书刷新应成功: {}", rd.error_msg);
        let chapters = rd.data.as_array().expect("data 应为章节数组");
        assert_eq!(chapters.len(), 2, "应解析出两章: {chapters:?}");

        let persisted = {
            let db = state.db.lock().await;
            BookChapterRepository::new(db.connection())
                .find_by_book_url(book_url)
                .unwrap()
        };
        assert_eq!(persisted.len(), 2, "刷新后目录应落库");
        assert!(!persisted[0].title.is_empty(), "章节标题不应为空");

        let _ = std::fs::remove_dir_all(&base);
    }

    /// 正例（网络书 + 回环目录页）：详情→目录抓取→删旧插新，返回目录数组
    #[tokio::test]
    async fn test_refresh_toc_endpoint_network_success() {
        use axum::response::Html;
        use axum::routing::get;
        use legado_core::models::BookSource;

        async fn toc_page() -> Html<&'static str> {
            Html(
                r#"<html><body>
                <div class="ch"><a href="/c/1">第一章</a></div>
                <div class="ch"><a href="/c/2">第二章</a></div>
                </body></html>"#,
            )
        }

        let mock = axum::Router::new().route("/toc", get(toc_page));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let _ = axum::serve(listener, mock).await;
        });

        let state = make_state(None);
        let source_url = format!("http://{addr}/src");
        let book_url = format!("http://{addr}/book/1");
        {
            let db = state.db.lock().await;
            let source: BookSource = serde_json::from_value(serde_json::json!({
                "bookSourceUrl": source_url,
                "bookSourceName": "回环刷新源",
                "ruleToc": {
                    "chapterList": "class.ch",
                    "chapterName": "tag.a@text",
                    "chapterUrl": "tag.a@href"
                }
            }))
            .unwrap();
            BookSourceRepository::new(db.connection())
                .insert(&source)
                .unwrap();
            BookRepository::new(db.connection())
                .insert(&Book {
                    book_url: book_url.clone(),
                    name: "回环书".to_string(),
                    origin: source_url,
                    toc_url: format!("http://{addr}/toc"),
                    book_type: book_type::TEXT,
                    ..Book::default()
                })
                .unwrap();
        }

        let rd = refresh_toc_return_data(&state, &book_url).await;
        assert!(rd.is_success, "网络书刷新应成功: {}", rd.error_msg);
        let chapters = rd.data.as_array().expect("data 应为章节数组");
        assert_eq!(chapters.len(), 2, "应抓取到两章: {chapters:?}");

        let (persisted, total_chapters) = {
            let db = state.db.lock().await;
            let chapters = BookChapterRepository::new(db.connection())
                .find_by_book_url(&book_url)
                .unwrap();
            let book = BookRepository::new(db.connection())
                .find_by_url(&book_url)
                .unwrap()
                .expect("书籍行仍在");
            (chapters, book.total_chapter_num)
        };
        assert_eq!(persisted.len(), 2, "刷新后目录应落库");
        assert_eq!(total_chapters, 2, "目录派生字段应同步（book.update 等价）");
    }

    /// 路由注册：GET /refreshToc 经完整 router 可达且返回原版信封
    #[tokio::test]
    async fn test_refresh_toc_route_registered() {
        use axum::body::Body;
        use axum::http::{Method, StatusCode};
        use tower::ServiceExt;

        let base = std::env::temp_dir().join(format!(
            "legado_refresh_toc_route_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let books = base.join("books");
        std::fs::create_dir_all(&books).unwrap();
        std::fs::write(books.join("路由书.txt"), "第一章\n正文\n").unwrap();
        let state = make_state(Some(books.clone()));
        {
            let db = state.db.lock().await;
            BookRepository::new(db.connection())
                .insert(&Book {
                    book_url: "books/路由书.txt".to_string(),
                    name: "路由书".to_string(),
                    origin: book_type::LOCAL_TAG.to_string(),
                    book_type: book_type::TEXT | book_type::LOCAL,
                    ..Book::default()
                })
                .unwrap();
        }

        let app = crate::routes::create_router(state);
        let resp = app
            .oneshot(
                axum::http::Request::builder()
                    .method(Method::GET)
                    .uri("/refreshToc?url=books/%E8%B7%AF%E7%94%B1%E4%B9%A6.txt")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("oneshot 调用成功");
        assert_eq!(resp.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let body: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(body["isSuccess"], Value::Bool(true), "响应: {body}");
        assert_eq!(body["data"].as_array().map(Vec::len), Some(1));
        assert!(
            body["errorMsg"].as_str().unwrap_or_default().is_empty(),
            "成功时 errorMsg 应为空"
        );

        let _ = std::fs::remove_dir_all(&base);
    }

    /// [批17] Web `@js:` 绑定：章节字段全部取真实章节行；书籍主键为空时
    /// `bookUrl` 回退章节行的 `bookUrl`，不得凭空编造章节值。
    #[test]
    fn test_build_replace_js_bindings_uses_real_rows_only() {
        let book = Book {
            book_url: String::new(),
            name: "绑定书".to_string(),
            author: "绑定作者".to_string(),
            ..Book::default()
        };
        let chapter = BookChapter {
            book_url: "https://b17.example.com/book/1".to_string(),
            title: "第一章".to_string(),
            index: 1,
            url: "https://b17.example.com/ch/1".to_string(),
            ..BookChapter::default()
        };
        // 书籍主键为空 → bookUrl 回退章节行的 bookUrl
        let bindings = build_replace_js_bindings(&book, &chapter);
        assert_eq!(bindings.chapter.title, "第一章");
        assert_eq!(bindings.chapter.index, 1);
        assert_eq!(bindings.chapter.url, "https://b17.example.com/ch/1");
        assert_eq!(bindings.chapter.book_url, "https://b17.example.com/book/1");
        assert_eq!(bindings.book.name, "绑定书");
        assert_eq!(bindings.book.author, "绑定作者");
        assert_eq!(bindings.book.book_url, "https://b17.example.com/book/1");

        // 书籍主键非空 → 使用书籍主键（与 App 端 book.bookUrl 优先一致）
        let book = Book {
            book_url: "https://b17.example.com/book/primary".to_string(),
            ..book
        };
        let bindings = build_replace_js_bindings(&book, &chapter);
        assert_eq!(
            bindings.chapter.book_url,
            "https://b17.example.com/book/primary"
        );
        assert_eq!(
            bindings.book.book_url,
            "https://b17.example.com/book/primary"
        );
    }
}
