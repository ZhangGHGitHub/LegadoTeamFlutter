//! FFI 桥接层 — 旧式 C ABI 导出函数（向后兼容）
//!
//! 所有对外暴露的 FFI 函数均使用 `catch_unwind` 包装，防止 panic 跨越 FFI 边界。
//! 数据通过 JSON 字符串（`*mut c_char`）在 Rust 与 Dart 之间传递。
//!
//! 新的 flutter_rust_bridge 桥接定义位于 `ffi` 模块（`ffi.rs`）。

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::catch_unwind;

use serde::Serialize;

use legado_core::error::LegadoError;

// ─── FFI 响应结构 ────────────────────────────────────────────

/// FFI 统一响应结构（JSON 序列化后通过 `*mut c_char` 传递）
#[derive(Debug, Serialize)]
pub struct FfiResponse<T: Serialize> {
    pub code: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl<T: Serialize> FfiResponse<T> {
    pub fn success(data: T) -> Self {
        Self {
            code: 0,
            data: Some(data),
            error: None,
        }
    }

    pub fn failure(code: i32, error: impl Into<String>) -> Self {
        Self {
            code,
            data: None,
            error: Some(error.into()),
        }
    }

    pub fn into_raw(self) -> *mut c_char {
        let json = match serde_json::to_string(&self) {
            Ok(j) => j,
            Err(e) => format!(r#"{{"code":-1,"error":"serialize failed: {}"}}"#, e),
        };
        match CString::new(json) {
            Ok(cs) => cs.into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    }
}

// ─── 内部辅助 ────────────────────────────────────────────────

fn to_ffi_response<T: Serialize>(
    result: Result<Result<T, LegadoError>, Box<dyn std::any::Any + Send>>,
) -> *mut c_char {
    match result {
        Ok(Ok(data)) => FfiResponse::success(data).into_raw(),
        Ok(Err(e)) => FfiResponse::<()>::failure(e.to_error_code(), e.to_string()).into_raw(),
        Err(_) => FfiResponse::<()>::failure(-1, "Unexpected panic in FFI boundary").into_raw(),
    }
}

unsafe fn c_char_to_str<'a>(ptr: *const c_char) -> Result<&'a str, LegadoError> {
    if ptr.is_null() {
        return Err(LegadoError::Ffi("Null pointer passed".into()));
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map_err(|e| LegadoError::Ffi(format!("Invalid UTF-8: {}", e)))
}

fn to_c_char(s: &str) -> *mut c_char {
    match CString::new(s) {
        Ok(cs) => cs.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

// ─── 基础 FFI 函数 ──────────────────────────────────────────

/// 初始化 Legado FFI 运行时
#[no_mangle]
pub extern "C" fn ffi_init() -> i32 {
    catch_unwind(|| {
        let _ = crate::runtime::get_runtime();
        0i32
    })
    .unwrap_or(-1)
}

/// 获取版本号
#[no_mangle]
pub extern "C" fn ffi_version() -> *mut c_char {
    catch_unwind(|| to_c_char(env!("CARGO_PKG_VERSION"))).unwrap_or(std::ptr::null_mut())
}

/// 释放 FFI 分配的字符串
#[no_mangle]
pub unsafe extern "C" fn ffi_free_string(ptr: *mut c_char) {
    let _ = catch_unwind(|| {
        if !ptr.is_null() {
            drop(CString::from_raw(ptr));
        }
    });
}

// ─── 数据库 FFI 函数 ────────────────────────────────────────

/// 打开数据库
#[no_mangle]
pub unsafe extern "C" fn ffi_db_open(path: *const c_char) -> i32 {
    match catch_unwind(|| {
        let path_str = c_char_to_str(path).map_err(|e| e.to_error_code())?;
        let db = legado_db::init_database(path_str).map_err(|e| e.to_error_code())?;
        crate::db_state::init_database(db);
        Ok::<i32, i32>(0)
    }) {
        Ok(Ok(code)) => code,
        Ok(Err(code)) => code,
        Err(_) => -1,
    }
}

// ─── 书架管理 FFI 函数 ──────────────────────────────────────

/// 获取书架上所有书籍
#[no_mangle]
pub extern "C" fn ffi_bookshelf_list() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::bookshelf::list_books))
}

/// 添加书籍到书架
#[no_mangle]
pub unsafe extern "C" fn ffi_bookshelf_add(book_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(book_json)?;
        crate::api::bookshelf::add_book(json)
    }))
}

/// 更新书籍信息
#[no_mangle]
pub unsafe extern "C" fn ffi_bookshelf_update(book_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(book_json)?;
        crate::api::bookshelf::update_book(json)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 按 bookUrl 删除书籍
#[no_mangle]
pub unsafe extern "C" fn ffi_bookshelf_delete(book_url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::bookshelf::delete_book(url)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 按 bookUrl 获取书籍详情
#[no_mangle]
pub unsafe extern "C" fn ffi_bookshelf_get(book_url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::bookshelf::get_book(url)?
            .ok_or_else(|| LegadoError::Database("书籍不存在".into()))
    }))
}

/// 更新阅读进度
#[no_mangle]
pub unsafe extern "C" fn ffi_reader_update_progress(
    book_url: *const c_char,
    chapter_index: i32,
    chapter_pos: i32,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::bookshelf::update_reading_progress(url, chapter_index, chapter_pos)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

// ─── 书源管理 FFI 函数 ──────────────────────────────────────

/// 获取所有书源列表
#[no_mangle]
pub extern "C" fn ffi_source_list() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::source::list_sources))
}

/// 获取所有启用的书源
#[no_mangle]
pub extern "C" fn ffi_source_list_enabled() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::source::list_enabled_sources))
}

/// 添加书源
#[no_mangle]
pub unsafe extern "C" fn ffi_source_add(source_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(source_json)?;
        crate::api::source::add_source(json)
    }))
}

/// 更新书源
#[no_mangle]
pub unsafe extern "C" fn ffi_source_update(source_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(source_json)?;
        crate::api::source::update_source(json)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 删除书源
#[no_mangle]
pub unsafe extern "C" fn ffi_source_delete(source_url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(source_url)?;
        crate::api::source::delete_source(url)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 启用书源
#[no_mangle]
pub unsafe extern "C" fn ffi_source_enable(source_url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(source_url)?;
        crate::api::source::enable_source(url)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 禁用书源
#[no_mangle]
pub unsafe extern "C" fn ffi_source_disable(source_url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(source_url)?;
        crate::api::source::disable_source(url)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 批量导入书源（JSON 数组），返回成功导入的数量
#[no_mangle]
pub unsafe extern "C" fn ffi_source_import(json_array: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(json_array)?;
        crate::api::source::import_sources(json)
    }))
}

/// 导出所有书源为 JSON 数组
#[no_mangle]
pub extern "C" fn ffi_source_export() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::source::export_sources))
}

// ─── 搜索 FFI 函数 ──────────────────────────────────────────

/// 搜索书籍
#[no_mangle]
pub unsafe extern "C" fn ffi_search_books(
    keyword: *const c_char,
    source_urls_json: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let kw = c_char_to_str(keyword)?;
        let urls = c_char_to_str(source_urls_json)?;
        crate::api::search::search_books(kw, urls)
    }))
}

/// 多源并行搜索
#[no_mangle]
pub unsafe extern "C" fn ffi_search_multi(
    query: *const c_char,
    source_urls_json: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let q = c_char_to_str(query)?;
        let urls = c_char_to_str(source_urls_json)?;
        crate::api::search::multi_source_search(q, urls)
    }))
}

/// 取消正在进行的搜索
#[no_mangle]
pub extern "C" fn ffi_search_cancel() {
    let _ = catch_unwind(|| {
        crate::api::search::cancel_search();
    });
}

// ─── 阅读 FFI 函数 ──────────────────────────────────────────

/// 获取书籍的章节列表
#[no_mangle]
pub unsafe extern "C" fn ffi_reader_get_chapters(book_url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::reader::get_chapters(url)
    }))
}

/// 获取章节正文内容
#[no_mangle]
pub unsafe extern "C" fn ffi_reader_get_content(
    book_url: *const c_char,
    chapter_index: i32,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::reader::get_chapter_content(url, chapter_index)
    }))
}

/// 从网络刷新书籍目录
#[no_mangle]
pub unsafe extern "C" fn ffi_reader_refresh_toc(
    book_url: *const c_char,
    source_url: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let book = c_char_to_str(book_url)?;
        let source = c_char_to_str(source_url)?;
        crate::api::reader::refresh_toc(book, source)
    }))
}

/// 获取章节正文内容（在线抓取，带 DB 缓存）
#[no_mangle]
pub unsafe extern "C" fn ffi_reader_fetch_content(
    book_url: *const c_char,
    chapter_url: *const c_char,
    source_url: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let book = c_char_to_str(book_url)?;
        let chapter = c_char_to_str(chapter_url)?;
        let source = c_char_to_str(source_url)?;
        crate::api::reader::fetch_chapter_content(book, chapter, source)
    }))
}

// ─── 书籍导入 FFI 函数 ──────────────────────────────────────

/// 检测书籍文件格式
#[no_mangle]
pub unsafe extern "C" fn ffi_import_detect_format(file_path: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let path = c_char_to_str(file_path)?;
        crate::api::book_import::detect_format(path)
    }))
}

/// 解析书籍元数据
#[no_mangle]
pub unsafe extern "C" fn ffi_import_parse_metadata(file_path: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let path = c_char_to_str(file_path)?;
        crate::api::book_import::parse_metadata(path)
    }))
}

/// 导入本地书籍到书架
#[no_mangle]
pub unsafe extern "C" fn ffi_import_local_book(file_path: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let path = c_char_to_str(file_path)?;
        crate::api::book_import::import_local_book(path)
    }))
}

// ─── RSS FFI 函数 ───────────────────────────────────────────

/// 获取所有 RSS 源列表
#[no_mangle]
pub extern "C" fn ffi_rss_list_sources() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::rss::list_rss_sources))
}

/// 添加 RSS 源
#[no_mangle]
pub unsafe extern "C" fn ffi_rss_add_source(source_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(source_json)?;
        crate::api::rss::add_rss_source(json)
    }))
}

/// 删除 RSS 源
#[no_mangle]
pub unsafe extern "C" fn ffi_rss_delete_source(source_url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(source_url)?;
        crate::api::rss::delete_rss_source(url)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 获取 RSS 源的文章列表
#[no_mangle]
pub unsafe extern "C" fn ffi_rss_fetch_articles(source_url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(source_url)?;
        crate::api::rss::fetch_rss_articles(url)
    }))
}

// ─── RSS 收藏 FFI 函数 ─────────────────────────────────────

/// 获取所有 RSS 收藏
#[no_mangle]
pub extern "C" fn ffi_rss_star_list() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::rss_star_api::get_rss_stars))
}

/// 添加 RSS 收藏
#[no_mangle]
pub unsafe extern "C" fn ffi_rss_star_add(
    source_url: *const c_char,
    title: *const c_char,
    link: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(source_url)?;
        let t = c_char_to_str(title)?;
        let l = c_char_to_str(link)?;
        crate::api::rss_star_api::add_rss_star(url, t, l)
    }))
}

/// 取消 RSS 收藏
#[no_mangle]
pub unsafe extern "C" fn ffi_rss_star_delete(link: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let l = c_char_to_str(link)?;
        crate::api::rss_star_api::delete_rss_star(l)
    }))
}

/// 判断是否已收藏
#[no_mangle]
pub unsafe extern "C" fn ffi_rss_star_is_starred(link: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let l = c_char_to_str(link)?;
        crate::api::rss_star_api::is_rss_starred(l)
    }))
}

// ─── 搜索历史 FFI 函数 ─────────────────────────────────────

/// 获取最近搜索历史
#[no_mangle]
pub extern "C" fn ffi_search_history_list(limit: i32) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::search_history_api::get_search_history(limit)
    }))
}

/// 添加搜索关键词
#[no_mangle]
pub unsafe extern "C" fn ffi_search_history_add(
    keyword: *const c_char,
    book_name: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let kw = c_char_to_str(keyword)?;
        let bn = c_char_to_str(book_name)?;
        crate::api::search_history_api::add_search_keyword(kw, bn)
    }))
}

/// 删除搜索关键词
#[no_mangle]
pub unsafe extern "C" fn ffi_search_history_delete(keyword: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let kw = c_char_to_str(keyword)?;
        crate::api::search_history_api::delete_search_keyword(kw)
    }))
}

/// 清空搜索历史
#[no_mangle]
pub extern "C" fn ffi_search_history_clear() -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::search_history_api::clear_search_history()
    }))
}

// ─── HTTP FFI 函数 ──────────────────────────────────────────

/// HTTP GET 请求
#[no_mangle]
pub unsafe extern "C" fn ffi_http_get(url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url_str = c_char_to_str(url)?;
        let response = crate::runtime::block_on(async {
            let client = legado_net::LegadoClient::new(legado_net::LegadoClientConfig::default())
                .map_err(|e| LegadoError::Network(format!("创建客户端失败: {e}")))?;
            client.get(url_str, None).await
        })?;
        Ok::<_, LegadoError>(response)
    }))
}

/// HTTP POST 请求
#[no_mangle]
pub unsafe extern "C" fn ffi_http_post(url: *const c_char, body: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url_str = c_char_to_str(url)?;
        let body_str = c_char_to_str(body)?;
        let response = crate::runtime::block_on(async {
            let client = legado_net::LegadoClient::new(legado_net::LegadoClientConfig::default())
                .map_err(|e| LegadoError::Network(format!("创建客户端失败: {e}")))?;
            client.post(url_str, body_str, None).await
        })?;
        Ok::<_, LegadoError>(response)
    }))
}

// ─── 规则解析 FFI 函数 ──────────────────────────────────────

/// 规则解析
#[no_mangle]
pub unsafe extern "C" fn ffi_parse_rule(
    content: *const c_char,
    rule: *const c_char,
    rule_type: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let content_str = c_char_to_str(content)?;
        let rule_str = c_char_to_str(rule)?;
        let _rule_type_str = c_char_to_str(rule_type)?;
        let analyzer = legado_parser::AnalyzeRule::new(content_str.to_string(), String::new());
        let results = analyzer.get_strings(rule_str)?;
        Ok::<_, LegadoError>(serde_json::json!({
            "results": results,
            "count": results.len(),
        }))
    }))
}

// ─── JS 引擎 FFI 函数 ───────────────────────────────────────

/// 执行 JS 脚本（启用 quickjs feature 时使用真实引擎）
#[cfg(feature = "quickjs")]
#[no_mangle]
pub unsafe extern "C" fn ffi_js_eval(script: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let script_str = c_char_to_str(script)?;
        use legado_js::engine::QuickJsEngine;
        use legado_js::JsEngine;
        use legado_js::SandboxConfig;
        let engine = QuickJsEngine::new(SandboxConfig::permissive())?;
        let result_str = engine.eval(script_str)?;
        Ok::<_, LegadoError>(serde_json::json!({ "result": result_str }))
    }))
}

/// 执行 JS 脚本（未启用 quickjs 时返回错误）
#[cfg(not(feature = "quickjs"))]
#[no_mangle]
pub unsafe extern "C" fn ffi_js_eval(script: *const c_char) -> *mut c_char {
    let _ = script;
    FfiResponse::<()>::failure(-1, "QuickJS engine not enabled").into_raw()
}

// ─── 换源 FFI 函数 ──────────────────────────────────────────────

/// 搜索可替换的书源
#[no_mangle]
pub unsafe extern "C" fn ffi_source_switch_search(
    book_name: *const c_char,
    author: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let name = c_char_to_str(book_name)?;
        let author_str = c_char_to_str(author)?;
        crate::api::source_switch::search_alternative_sources(name, author_str)
    }))
}

/// 切换到新书源
#[no_mangle]
pub unsafe extern "C" fn ffi_source_switch_apply(
    book_url: *const c_char,
    new_source_url: *const c_char,
    new_book_url: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        let src = c_char_to_str(new_source_url)?;
        let dst = c_char_to_str(new_book_url)?;
        crate::api::source_switch::switch_book_source(url, src, dst)
    }))
}

// ─── 书签管理 FFI 函数 ──────────────────────────────────────

/// 获取书籍的所有书签
#[no_mangle]
pub unsafe extern "C" fn ffi_bookmark_get_all(book_name: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let name = c_char_to_str(book_name)?;
        crate::api::bookmark_api::get_bookmarks(name)
    }))
}

/// 添加书签
#[no_mangle]
pub unsafe extern "C" fn ffi_bookmark_add(
    book_name: *const c_char,
    book_author: *const c_char,
    chapter_index: i32,
    chapter_pos: i32,
    chapter_name: *const c_char,
    book_text: *const c_char,
    content: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let name = c_char_to_str(book_name)?;
        let author = c_char_to_str(book_author)?;
        let ch_name = c_char_to_str(chapter_name)?;
        let text = c_char_to_str(book_text)?;
        let note = c_char_to_str(content)?;
        crate::api::bookmark_api::add_bookmark(
            name,
            author,
            chapter_index,
            chapter_pos,
            ch_name,
            text,
            note,
        )
    }))
}

/// 删除书签
#[no_mangle]
pub extern "C" fn ffi_bookmark_delete(bookmark_id: i64) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::bookmark_api::delete_bookmark(bookmark_id)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 搜索书签
#[no_mangle]
pub unsafe extern "C" fn ffi_bookmark_search(keyword: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let kw = c_char_to_str(keyword)?;
        crate::api::bookmark_api::search_bookmarks(kw)
    }))
}

/// 获取所有书签
#[no_mangle]
pub extern "C" fn ffi_bookmark_list() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::bookmark_api::get_all_bookmarks))
}

// ─── 替换规则管理 FFI 函数 ────────────────────────────────────

/// 获取所有替换规则
#[no_mangle]
pub extern "C" fn ffi_replace_rule_list() -> *mut c_char {
    to_ffi_response(catch_unwind(
        crate::api::replace_rule_api::get_replace_rules,
    ))
}

/// 添加替换规则
#[no_mangle]
pub unsafe extern "C" fn ffi_replace_rule_add(
    name: *const c_char,
    pattern: *const c_char,
    replacement: *const c_char,
    is_regex: bool,
    scope: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let n = c_char_to_str(name)?;
        let p = c_char_to_str(pattern)?;
        let r = c_char_to_str(replacement)?;
        let s = c_char_to_str(scope)?;
        crate::api::replace_rule_api::add_replace_rule(n, p, r, is_regex, s)
    }))
}

/// 更新替换规则
#[no_mangle]
pub unsafe extern "C" fn ffi_replace_rule_update(
    rule_id: i64,
    name: *const c_char,
    pattern: *const c_char,
    replacement: *const c_char,
    is_regex: bool,
    is_enabled: bool,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let n = c_char_to_str(name)?;
        let p = c_char_to_str(pattern)?;
        let r = c_char_to_str(replacement)?;
        crate::api::replace_rule_api::update_replace_rule(rule_id, n, p, r, is_regex, is_enabled)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 删除替换规则
#[no_mangle]
pub extern "C" fn ffi_replace_rule_delete(rule_id: i64) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::replace_rule_api::delete_replace_rule(rule_id)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 获取启用的替换规则
#[no_mangle]
pub extern "C" fn ffi_replace_rule_enabled() -> *mut c_char {
    to_ffi_response(catch_unwind(
        crate::api::replace_rule_api::get_enabled_rules,
    ))
}

/// 启用/禁用替换规则
#[no_mangle]
pub extern "C" fn ffi_replace_rule_set_enabled(rule_id: i64, enabled: bool) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::replace_rule_api::set_rule_enabled(rule_id, enabled)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

// ─── 阅读记录 FFI 函数 ─────────────────────────────────────

/// 获取所有阅读记录
#[no_mangle]
pub extern "C" fn ffi_read_record_list() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::read_record_api::get_read_records))
}

/// 添加/更新阅读记录
#[no_mangle]
pub unsafe extern "C" fn ffi_read_record_upsert(
    book_name: *const c_char,
    read_time: i64,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let name = c_char_to_str(book_name)?;
        crate::api::read_record_api::upsert_read_record(name, read_time)
    }))
}

/// 删除阅读记录
#[no_mangle]
pub unsafe extern "C" fn ffi_read_record_delete(book_name: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let name = c_char_to_str(book_name)?;
        crate::api::read_record_api::delete_read_record(name)
    }))
}

/// 清空所有阅读记录
#[no_mangle]
pub extern "C" fn ffi_read_record_clear() -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::read_record_api::clear_read_records()
    }))
}

// ─── 书籍分组 FFI 函数 ─────────────────────────────────────

/// 获取所有书籍分组
#[no_mangle]
pub extern "C" fn ffi_book_group_list() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::book_group_api::get_book_groups))
}

/// 添加书籍分组
#[no_mangle]
pub unsafe extern "C" fn ffi_book_group_add(
    group_name: *const c_char,
    cover: *const c_char,
    order: i32,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let name = c_char_to_str(group_name)?;
        let cov = c_char_to_str(cover)?;
        crate::api::book_group_api::add_book_group(name, cov, order)
    }))
}

/// 更新书籍分组
#[no_mangle]
pub unsafe extern "C" fn ffi_book_group_update(
    id: i64,
    group_name: *const c_char,
    cover: *const c_char,
    order: i32,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let name = c_char_to_str(group_name)?;
        let cov = c_char_to_str(cover)?;
        crate::api::book_group_api::update_book_group(id, name, cov, order)
    }))
}

/// 删除书籍分组
#[no_mangle]
pub extern "C" fn ffi_book_group_delete(id: i64) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::book_group_api::delete_book_group(id)
    }))
}

/// 设置分组显示状态
#[no_mangle]
pub extern "C" fn ffi_book_group_set_show(id: i64, show: bool) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::book_group_api::set_book_group_show(id, show)
    }))
}

// ─── 阅读统计 FFI 函数 ─────────────────────────────────────

/// 获取今日阅读统计
#[no_mangle]
pub extern "C" fn ffi_stats_today() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::reading_stats_api::get_today_stats))
}

/// 获取最近 N 天每日统计
#[no_mangle]
pub extern "C" fn ffi_stats_daily(days: i32) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::reading_stats_api::get_daily_stats(days)
    }))
}

/// 获取按书籍分组的统计
#[no_mangle]
pub extern "C" fn ffi_stats_by_book() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::reading_stats_api::get_book_stats))
}

/// 获取阅读热力图数据
#[no_mangle]
pub extern "C" fn ffi_stats_heatmap(days: i32) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::reading_stats_api::get_reading_heatmap(days)
    }))
}

// ─── 缓存管理 FFI 函数 ─────────────────────────────────────

/// 获取缓存总大小
#[no_mangle]
pub extern "C" fn ffi_cache_get_size() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::cache_api::get_cache_size))
}

/// 清空所有缓存
#[no_mangle]
pub extern "C" fn ffi_cache_clear() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::cache_api::clear_cache))
}

/// 获取章节缓存内容
#[no_mangle]
pub unsafe extern "C" fn ffi_cache_get_chapter(
    book_url: *const c_char,
    chapter_index: i32,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::cache_api::get_chapter_cache(url, chapter_index)
    }))
}

// ─── 配置管理 FFI 函数 ─────────────────────────────────────

/// 获取配置项
#[no_mangle]
pub unsafe extern "C" fn ffi_config_get(key: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let k = c_char_to_str(key)?;
        crate::api::config_api::get_config(k)
    }))
}

/// 设置配置项
#[no_mangle]
pub unsafe extern "C" fn ffi_config_set(key: *const c_char, value: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let k = c_char_to_str(key)?;
        let v = c_char_to_str(value)?;
        crate::api::config_api::set_config(k, v)
    }))
}

/// 获取所有配置
#[no_mangle]
pub extern "C" fn ffi_config_get_all() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::config_api::get_all_config))
}

// ─── HTTP TTS 朗读源 FFI 函数 ───────────────────────────────────

/// 获取所有 HTTP TTS 源
#[no_mangle]
pub extern "C" fn ffi_http_tts_list() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::http_tts_api::get_http_tts_list))
}

/// 添加 HTTP TTS 源
#[no_mangle]
pub unsafe extern "C" fn ffi_http_tts_add(name: *const c_char, url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let n = c_char_to_str(name)?;
        let u = c_char_to_str(url)?;
        crate::api::http_tts_api::add_http_tts(n, u)
    }))
}

/// 更新 HTTP TTS 源
#[no_mangle]
pub unsafe extern "C" fn ffi_http_tts_update(
    id: i64,
    name: *const c_char,
    url: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let n = c_char_to_str(name)?;
        let u = c_char_to_str(url)?;
        crate::api::http_tts_api::update_http_tts(id, n, u)
    }))
}

/// 删除 HTTP TTS 源
#[no_mangle]
pub extern "C" fn ffi_http_tts_delete(id: i64) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::http_tts_api::delete_http_tts(id)
    }))
}

/// 设置 HTTP TTS 源启用/禁用
#[no_mangle]
pub extern "C" fn ffi_http_tts_set_enabled(id: i64, enabled: bool) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::http_tts_api::set_http_tts_enabled(id, enabled)
    }))
}

// ─── 音频播放进度 FFI 函数 ───────────────────────────────────

/// 获取音频播放进度
#[no_mangle]
pub unsafe extern "C" fn ffi_audio_get_progress(
    book_url: *const c_char,
    chapter_index: i32,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::audio_api::get_audio_progress(url, chapter_index)
    }))
}

/// 保存音频播放进度
#[no_mangle]
pub unsafe extern "C" fn ffi_audio_save_progress(
    book_url: *const c_char,
    chapter_index: i32,
    position: i64,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::audio_api::save_audio_progress(url, chapter_index, position)
    }))
}

// ─── 备份/恢复 FFI 函数 ─────────────────────────────────────

/// 创建备份
#[no_mangle]
pub unsafe extern "C" fn ffi_backup_create(path: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let p = c_char_to_str(path)?;
        crate::api::backup_api::backup_create(p)
    }))
}

/// 从备份恢复
#[no_mangle]
pub unsafe extern "C" fn ffi_backup_restore(path: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let p = c_char_to_str(path)?;
        crate::api::backup_api::backup_restore(p)
    }))
}

/// 列出备份文件
#[no_mangle]
pub unsafe extern "C" fn ffi_backup_list(dir: *const c_char) -> *mut c_char {
    match catch_unwind(|| {
        let d = c_char_to_str(dir).unwrap_or("");
        crate::api::backup_api::backup_list(d)
    }) {
        Ok(result) => to_c_char(&result),
        Err(_) => to_c_char("[]"),
    }
}

// ─── 服务器管理 FFI 函数 ───────────────────────────────────

/// 启动服务器
#[no_mangle]
pub extern "C" fn ffi_server_start(port: u16) -> *mut c_char {
    to_ffi_response(catch_unwind(|| crate::api::server_api::server_start(port)))
}

/// 停止服务器
#[no_mangle]
pub extern "C" fn ffi_server_stop() -> *mut c_char {
    match catch_unwind(crate::api::server_api::server_stop) {
        Ok(result) => to_c_char(&result),
        Err(_) => to_c_char("Server stop failed"),
    }
}

/// 获取服务器状态
#[no_mangle]
pub extern "C" fn ffi_server_status() -> *mut c_char {
    match catch_unwind(crate::api::server_api::server_status) {
        Ok(result) => to_c_char(&result),
        Err(_) => to_c_char(r#"{"running":false,"port":0}"#),
    }
}

// ─── 向后兼容的旧函数名 ────────────────────────────────────

#[no_mangle]
pub extern "C" fn legado_init() -> i32 {
    ffi_init()
}

#[no_mangle]
pub extern "C" fn legado_version() -> *mut c_char {
    ffi_version()
}

#[no_mangle]
pub unsafe extern "C" fn legado_free_string(ptr: *mut c_char) {
    ffi_free_string(ptr);
}

#[no_mangle]
pub unsafe extern "C" fn legado_db_open(path: *const c_char) -> i32 {
    ffi_db_open(path)
}

#[no_mangle]
pub unsafe extern "C" fn legado_http_get(url: *const c_char) -> *mut c_char {
    ffi_http_get(url)
}

#[no_mangle]
pub unsafe extern "C" fn legado_parse_rule(
    content: *const c_char,
    rule: *const c_char,
    rule_type: *const c_char,
) -> *mut c_char {
    ffi_parse_rule(content, rule, rule_type)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ffi_response_success() {
        let resp = FfiResponse::success("hello".to_string());
        assert_eq!(resp.code, 0);
        assert_eq!(resp.data, Some("hello".to_string()));
        assert!(resp.error.is_none());
    }

    #[test]
    fn test_ffi_response_failure() {
        let resp = FfiResponse::<()>::failure(1001, "parse error");
        assert_eq!(resp.code, 1001);
        assert!(resp.data.is_none());
        assert_eq!(resp.error, Some("parse error".to_string()));
    }

    #[test]
    fn test_ffi_response_success_serialize() {
        let resp = FfiResponse::success(vec![1, 2, 3]);
        let json = serde_json::to_value(&resp).unwrap();
        assert_eq!(json["code"], 0);
        assert_eq!(json["data"], serde_json::json!([1, 2, 3]));
        assert!(json.get("error").is_none());
    }

    #[test]
    fn test_ffi_response_failure_serialize() {
        let resp = FfiResponse::<()>::failure(500, "internal error");
        let json = serde_json::to_value(&resp).unwrap();
        assert_eq!(json["code"], 500);
        assert_eq!(json["error"], "internal error");
        assert!(json.get("data").is_none());
    }
}
