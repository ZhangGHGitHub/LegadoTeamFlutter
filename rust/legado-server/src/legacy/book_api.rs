//! 原版 `BookController` 端点实现（书架/目录/正文/进度/封面图片/阅读配置）
//!
//! 数据层复用 `db_state` 全局单池（[`AppState.db`]，S28 红线：不新建连接池）
//! 与既有 `legado-db` repositories；抓取链复用 `handlers::web_book::build_engine`
//! （与 `/api/*`、FFI 主链路同一 `RealBookSourceFetcher` 注入面）。

use std::collections::HashMap;
use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;
use serde_json::Value;

use legado_core::cache_book::CachedChapter;
use legado_core::content_processor::{
    ContentProcessor, ProcessorConfig, ReplaceRuleEntry, ScopeContext,
};
use legado_core::models::book_type;
use legado_core::models::{Book, BookChapter};
use legado_core::web_book::{WebBookEngine, WebChapter};
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::repository::book_repository::BookRepository;
use legado_db::repository::cache_book_repository::CacheBookRepository;
use legado_db::repository::cache_repository::CacheRepository;
use legado_db::repository::replace_rule_repository::ReplaceRuleRepository;
use legado_db::repository::Repository;
use legado_db::BookSourceRepository;
use legado_net::{LegadoClient, LegadoClientConfig};

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

/// 对齐 Kotlin `Book.isLocal`（BookExtensions.kt:49-55）
fn is_local_book(book: &Book) -> bool {
    if book.book_type == 0 {
        return book.origin == book_type::LOCAL_TAG
            || book.origin.starts_with(book_type::WEB_DAV_TAG);
    }
    book.book_type & book_type::LOCAL > 0
}

fn is_local_path(path: &str) -> bool {
    let lower = path.to_lowercase();
    LOCAL_BOOK_EXTS.iter().any(|ext| lower.ends_with(ext))
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
        // 原版：`getChapterListAwait(...).getOrThrow()` 空列表不抛错 → setData(空)
        return Ok(Vec::new());
    }

    let chapters: Vec<BookChapter> = web_chapters
        .iter()
        .map(|wc| BookChapter {
            url: wc.url.clone(),
            title: wc.title.clone(),
            is_volume: wc.is_volume,
            base_url: book_url.to_string(),
            book_url: book_url.to_string(),
            index: wc.index,
            is_vip: wc.is_vip,
            is_pay: false,
            resource_url: None,
            tag: None,
            word_count: wc.word_count.clone(),
            start: None,
            end: None,
            start_fragment_id: None,
            end_fragment_id: None,
            variable: wc.variable.clone(),
            img_url: None,
        })
        .collect();

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
async fn refresh_local_toc(state: &Arc<AppState>, book: &Book) -> Result<Vec<BookChapter>, String> {
    let chapter_infos =
        legado_book::LocalBook::get_chapters(&book.book_url).map_err(|e| e.to_string())?;
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
        return Ok(purify_content(state, &book, &chapter.title, &cached.content).await);
    }

    // 2) 本地书：文件解析（对齐 BookHelp.getContent 的本地书分支）
    if is_local_book(&book) || is_local_path(book_url) {
        let content = legado_book::LocalBook::get_chapter_content(
            &book.book_url,
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
        return Ok(purify_content(state, &book, &chapter.title, &content).await);
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

    Ok(purify_content(state, &book, &chapter.title, &content).await)
}

/// 正文净化（替换规则 + 去重复标题；`includeTitle=false`）
///
/// 对齐原版 `ContentProcessor.getContent(book, chapter, content, includeTitle=false)`：
/// 只做正文净化，不重排/不缩进/不去空行（避免改变排版）；简繁转换取默认
/// 关闭（Rust 侧未桥接 `chineseConverterType` 配置，登记差异）。规则作用域
///（scope/excludeScope/scopeContent）交由 `ContentProcessor` 内建过滤，
/// 语义对齐 Kotlin DAO 的 LIKE 判定。
async fn purify_content(
    state: &Arc<AppState>,
    book: &Book,
    chapter_title: &str,
    raw_content: &str,
) -> String {
    let rules = {
        let db = state.db.lock().await;
        ReplaceRuleRepository::new(db.connection()).get_enabled_rules()
    };
    let rules = match rules {
        Ok(rules) => rules,
        Err(_) => return raw_content.to_string(),
    };
    let entries = ReplaceRuleEntry::from_replace_rules(&rules);
    let config = ProcessorConfig {
        remove_duplicate_title: true,
        re_segment: false,
        chinese_convert: None,
        apply_replace_rules: true,
        indent_spaces: 0,
        trim_empty_lines: false,
    };
    ContentProcessor::new(config)
        .with_scope_context(ScopeContext::new(book.name.clone(), book.origin.clone()))
        .process(raw_content, chapter_title, &entries)
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
/// 本实现为字节级代理：网络 URL 经 [`LegadoClient`] 直取、本地文件直读，
/// 原样回传字节 + 嗅探 Content-Type。
///
/// 登记差异：不做 84x112 裁切/重编码 PNG，也不回退内置默认封面（原版
/// `BookCover.defaultDrawable` 为 App 资源，Rust 侧无对应物）；失败回
/// `ReturnData` 错误信封（原版此时回默认封面 PNG）。
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

    let target = resolve_image_url(&book_url, &path);
    match target {
        None => to_response(
            &ReturnData::error("图片地址不是有效的 http(s) 链接"),
            "/image",
            origin.as_deref(),
        ),
        Some(target) => match fetch_image_bytes(&state, &target).await {
            Ok((bytes, mime)) => bytes_response(bytes, &mime, "/image", origin.as_deref()),
            Err(msg) => to_response(&ReturnData::error(msg), "/image", origin.as_deref()),
        },
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
async fn fetch_image_bytes(
    _state: &Arc<AppState>,
    path: &str,
) -> Result<(Vec<u8>, String), String> {
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
        let bytes = tokio::fs::read(path)
            .await
            .map_err(|e| format!("读取本地图片失败: {e}"))?;
        let mime = guess_image_mime(&bytes, path);
        Ok((bytes, mime))
    }
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
}
