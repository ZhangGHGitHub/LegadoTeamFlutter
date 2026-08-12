//! FFI 桥接层 — 旧式 C ABI 导出函数（向后兼容）
//!
//! **DEPRECATED（Task #136 R12）**：本模块整体标记为废弃，处于
//! 「保留 + 计划性废弃」状态：
//!
//! - **冻结新增**：新功能一律在 frb 主链路（`ffi.rs`）暴露，
//!   本模块不再新增任何 `#[no_mangle]` 导出；
//! - **不改行为**：既有导出保持现有签名与语义不变（存量调用方兼容），
//!   待 Flutter 侧全部切换到 frb 绑定后随版本计划移除；
//! - 存量盘点：无 Rust 内部调用点，仅历史 Dart C ABI 绑定引用。
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
        crate::db_state::init_database(db).map_err(|e| e.to_error_code())?;
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

/// 批量导入书籍（JSON 数组），返回成功导入的数量
#[no_mangle]
pub unsafe extern "C" fn ffi_bookshelf_import(json_array: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(json_array)?;
        crate::api::bookshelf::import_books(json)
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

// ─── 书源校验 FFI 函数（Task #87，加法式新增） ──────────────────────────

/// 校验单个书源（搜索→详情→目录→正文四步 + 验证码/重定向检测）
///
/// `config_json` 传空串使用默认配置；返回 CheckResult JSON。
#[no_mangle]
pub unsafe extern "C" fn ffi_source_check(
    source_json: *const c_char,
    config_json: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let source = c_char_to_str(source_json)?;
        let config = c_char_to_str(config_json)?;
        crate::api::source_check_api::check_source(source, config)
    }))
}

/// 批量校验进度回调（C ABI）
///
/// 每完成一个书源即被调用一次：
/// - `progress_json` — 该书源进度（`CheckProgress`）的 JSON 字符串（NUL 结尾，仅回调期间有效）
/// - `user_data` — 调用方透传的上下文指针
pub type FfiSourceCheckCallback =
    unsafe extern "C" fn(progress_json: *const c_char, user_data: *mut std::ffi::c_void);

/// 批量校验书源（C ABI，回调模式，串行逐个回推）
///
/// 同步阻塞直到所有书源完成/取消；每完成一个书源即通过 `callback`
/// 推送一条进度 JSON。与 frb `source_check_stream`（Stream）互补，
/// 供原生 C 消费者逐源渲染。
///
/// # Safety
/// `callback` 可能从后台工作线程调用，调用方须保证其线程安全；`user_data` 原样透传。
#[no_mangle]
pub unsafe extern "C" fn ffi_source_check_stream(
    source_urls_json: *const c_char,
    config_json: *const c_char,
    callback: FfiSourceCheckCallback,
    user_data: *mut std::ffi::c_void,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let urls = c_char_to_str(source_urls_json)?.to_string();
        let config = c_char_to_str(config_json)?.to_string();

        crate::runtime::block_on(crate::api::source_check_api::run_check_sources_stream(
            urls,
            config,
            |item| {
                if let Ok(cs) = CString::new(item) {
                    unsafe { callback(cs.as_ptr(), user_data) };
                }
                Ok::<(), String>(())
            },
        ));

        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 取消正在进行的批量书源校验
#[no_mangle]
pub extern "C" fn ffi_source_check_cancel() {
    let _ = catch_unwind(|| {
        crate::api::source_check_api::cancel_check_sources();
    });
}

// ─── 验证码交互通道 FFI 函数（Task #90，加法式新增） ─────────────────────

/// 提交验证码结果，唤醒 JS 等待方（对齐 Kotlin `setResult`）
///
/// 返回 `{"code":0,"data":true/false}`（是否命中进行中的请求）。
#[no_mangle]
pub unsafe extern "C" fn ffi_verification_submit(
    key: *const c_char,
    code: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let key = c_char_to_str(key)?;
        let code = c_char_to_str(code)?;
        Ok::<_, LegadoError>(crate::api::verification_api::submit_verification_result(
            key, code,
        ))
    }))
}

/// 取消验证码请求（对齐 Kotlin `checkResult`：UI 关闭对话框未提交）
///
/// 返回 `{"code":0,"data":true/false}`（是否命中进行中的请求）。
#[no_mangle]
pub unsafe extern "C" fn ffi_verification_cancel(key: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let key = c_char_to_str(key)?;
        Ok::<_, LegadoError>(crate::api::verification_api::cancel_verification_request(key))
    }))
}

/// 当前进行中的验证码请求列表（JSON 数组，供 C ABI 消费者拉取）
#[no_mangle]
pub extern "C" fn ffi_verification_pending() -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        Ok::<_, LegadoError>(crate::api::verification_api::pending_requests_json())
    }))
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

/// 搜索书籍封面候选列表
///
/// 复用多书源搜索能力，从搜索结果中提取封面 URL 作为候选（去重、过滤空值）。
/// 返回 JSON 数组字符串，每项字段：`url` / `width` / `height`。
#[no_mangle]
pub unsafe extern "C" fn ffi_search_cover(book_name: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let name = c_char_to_str(book_name)?;
        crate::api::search::search_cover(name)
    }))
}

/// 渐进式搜索批次回调（C ABI）
///
/// 每完成一个书源即被调用一次：
/// - `batch_json` — 该书源批次（`SearchSourceBatch`）的 JSON 字符串（NUL 结尾，仅回调期间有效）
/// - `user_data` — 调用方透传的上下文指针
pub type FfiSearchBatchCallback =
    unsafe extern "C" fn(batch_json: *const c_char, user_data: *mut std::ffi::c_void);

/// 多源渐进式（流式）搜索（C ABI，回调模式）
///
/// 同步阻塞直到所有书源完成；每完成一个书源即通过 `callback` 推送一个批次 JSON。
/// 与 `ffi_search_multi`（一次性返回）互补，供原生 C 消费者逐源渲染。
///
/// # Safety
/// `callback` 可能从后台工作线程调用，调用方须保证其线程安全；`user_data` 原样透传。
#[no_mangle]
pub unsafe extern "C" fn ffi_search_multi_stream(
    query: *const c_char,
    source_urls_json: *const c_char,
    callback: FfiSearchBatchCallback,
    user_data: *mut std::ffi::c_void,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let q = c_char_to_str(query)?.to_string();
        let urls = c_char_to_str(source_urls_json)?.to_string();

        crate::runtime::block_on(crate::api::search::run_multi_stream(q, urls, |batch| {
            if let Ok(cs) = CString::new(batch) {
                unsafe { callback(cs.as_ptr(), user_data) };
            }
            Ok::<(), String>(())
        }));

        Ok::<_, LegadoError>("ok".to_string())
    }))
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

/// 一次调用获取章节正文（合并 get_content + fetch_content）
#[no_mangle]
pub unsafe extern "C" fn ffi_reader_get_content_full(
    book_url: *const c_char,
    chapter_index: i32,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::reader::get_chapter_content_full(url, chapter_index)
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

/// 原子更新 RSS 源（按 sourceUrl 主键单条 UPDATE）
///
/// 缺口④ rssUpdateSource 原子更新（Task #108，加法式）
#[no_mangle]
pub unsafe extern "C" fn ffi_rss_update_source(source_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(source_json)?;
        crate::api::rss::update_rss_source(json)
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

// ─── RSS 已读记录 FFI 函数 ─────────────────────────────

/// 标记 RSS 文章为已读
#[no_mangle]
pub unsafe extern "C" fn ffi_rss_mark_read(
    origin: *const c_char,
    title: *const c_char,
    link: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let o = c_char_to_str(origin)?;
        let t = c_char_to_str(title)?;
        let l = if link.is_null() {
            None
        } else {
            Some(c_char_to_str(link)?)
        };
        crate::api::rss_read_record_api::mark_read(o, t, l)
    }))
}

/// 判断 RSS 文章是否已读（按 link）
#[no_mangle]
pub unsafe extern "C" fn ffi_rss_is_read(link: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let l = c_char_to_str(link)?;
        crate::api::rss_read_record_api::is_read(l)
    }))
}

/// 判断 RSS 文章是否已读（按 origin + title）
#[no_mangle]
pub unsafe extern "C" fn ffi_rss_is_read_by_title(
    origin: *const c_char,
    title: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let o = c_char_to_str(origin)?;
        let t = c_char_to_str(title)?;
        crate::api::rss_read_record_api::is_read_by_title(o, t)
    }))
}

/// 清空所有 RSS 已读记录
#[no_mangle]
pub extern "C" fn ffi_rss_clear_read_records() -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::rss_read_record_api::clear_all()
    }))
}

/// 获取 RSS 已读记录总数
#[no_mangle]
pub extern "C" fn ffi_rss_read_record_count() -> *mut c_char {
    to_ffi_response(catch_unwind(|| crate::api::rss_read_record_api::count()))
}

/// 获取 RSS 已读记录列表
#[no_mangle]
pub extern "C" fn ffi_rss_list_read_records(limit: i32) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let lim = if limit <= 0 { None } else { Some(limit) };
        crate::api::rss_read_record_api::list_records(lim)
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

/// 按前缀搜索历史关键词
#[no_mangle]
pub unsafe extern "C" fn ffi_search_history_by_prefix(
    prefix: *const c_char,
    limit: i32,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let p = c_char_to_str(prefix)?;
        crate::api::search_history_api::search_history_by_prefix(p, limit)
    }))
}

/// 词典查询（本地内置词典）
///
/// 返回结构化释义 DictEntry（JSON 对象）：`word` / `phonetic` / `definitions`。
/// 未收录词返回空 `definitions`（非异常）。
#[no_mangle]
pub unsafe extern "C" fn ffi_dict_lookup(word: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let w = c_char_to_str(word)?;
        crate::api::dict_api::dict_lookup(w)
    }))
}

// ─── HTTP FFI 函数 ──────────────────────────────────────────

/// HTTP GET 请求
#[no_mangle]
pub unsafe extern "C" fn ffi_http_get(url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url_str = c_char_to_str(url)?;
        let response = crate::runtime::block_on(async {
            let client = crate::http_state::shared_client();
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
            let client = crate::http_state::shared_client();
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
        let engine = QuickJsEngine::new(SandboxConfig::default())?;
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
///
/// `source_urls_json` — 可选 JSON 数组，指定搜索的书源 URL 列表；
/// 空串/空数组=搜全部启用源（留项#12/Task #131，加法式新增）
#[no_mangle]
pub unsafe extern "C" fn ffi_source_switch_search(
    book_name: *const c_char,
    author: *const c_char,
    source_urls_json: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let name = c_char_to_str(book_name)?;
        let author_str = c_char_to_str(author)?;
        let urls = c_char_to_str(source_urls_json)?;
        crate::api::source_switch::search_alternative_sources(name, author_str, urls)
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

/// TTS 真实合成（Task #113 缺口②）：模板替换 → HTTP 拉取音频 → 本地缓存
///
/// 返回 JSON：`{"audioPath": "...", "fromCache": bool, "contentType": "..."}`
#[no_mangle]
pub unsafe extern "C" fn ffi_tts_speak(
    text: *const c_char,
    engine_url: *const c_char,
    speed: f64,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let t = c_char_to_str(text)?;
        let u = c_char_to_str(engine_url)?;
        crate::api::tts_speak_api::tts_speak(t, u, speed)
    }))
}

/// 设置 TTS 音频缓存目录
#[no_mangle]
pub unsafe extern "C" fn ffi_tts_set_cache_dir(path: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let p = c_char_to_str(path)?;
        crate::api::tts_speak_api::set_tts_cache_dir(p)
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

/// 音频章节取址（契约 §2.26）：WebBook.getContent → 可播 mediaUrl JSON
#[no_mangle]
pub unsafe extern "C" fn ffi_audio_get_chapter_media(
    book_url: *const c_char,
    chapter_index: i32,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::audio_api::get_audio_chapter_media(url, chapter_index)
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

// ─── 用户管理 ────────────────────────────────────────

/// 获取所有用户
#[no_mangle]
pub extern "C" fn ffi_user_get_all() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::user_api::get_users))
}

/// 保存用户
#[no_mangle]
pub unsafe extern "C" fn ffi_user_save(
    username: *const c_char,
    password: *const c_char,
    source_url: *const c_char,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let u = c_char_to_str(username)?;
        let p = c_char_to_str(password)?;
        let s = c_char_to_str(source_url)?;
        crate::api::user_api::save_user(u, p, s)
    });
    to_ffi_response(result)
}

/// 删除用户
#[no_mangle]
pub unsafe extern "C" fn ffi_user_delete(username: *const c_char) -> *mut c_char {
    let result = catch_unwind(|| {
        let u = c_char_to_str(username)?;
        crate::api::user_api::delete_user(u)
    });
    to_ffi_response(result)
}

/// 用户登录
#[no_mangle]
pub unsafe extern "C" fn ffi_user_login(
    username: *const c_char,
    password: *const c_char,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let u = c_char_to_str(username)?;
        let p = c_char_to_str(password)?;
        crate::api::user_api::login(u, p)
    });
    to_ffi_response(result)
}

/// 用户登出
#[no_mangle]
pub unsafe extern "C" fn ffi_user_logout(username: *const c_char) -> *mut c_char {
    let result = catch_unwind(|| {
        let u = c_char_to_str(username)?;
        crate::api::user_api::logout(u)
    });
    to_ffi_response(result)
}

/// 检查登录状态
#[no_mangle]
pub unsafe extern "C" fn ffi_user_check_login(username: *const c_char) -> *mut c_char {
    let result = catch_unwind(|| {
        let u = c_char_to_str(username)?;
        crate::api::user_api::check_login_status(u)
    });
    to_ffi_response(result)
}

// ─── 登录 UI V2 动态状态协议（#402/#488，加法式新增） ────

/// 判定书源登录 UI 是否为 V2 动态状态协议
#[no_mangle]
pub unsafe extern "C" fn ffi_source_is_login_ui_v2(source_json: *const c_char) -> *mut c_char {
    let result = catch_unwind(|| {
        let s = c_char_to_str(source_json)?;
        crate::api::source_login_v2_api::is_login_ui_v2(s)
    });
    to_ffi_response(result)
}

/// 执行 loginUi v2 脚本，返回动态 UI 描述 JSON
#[no_mangle]
pub unsafe extern "C" fn ffi_source_login_ui_v2(
    source_json: *const c_char,
    state_json: *const c_char,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let s = c_char_to_str(source_json)?;
        let st = c_char_to_str(state_json)?;
        crate::api::source_login_v2_api::eval_login_ui_v2(s, st)
    });
    to_ffi_response(result)
}

/// 执行 loginAction v2 动作，返回命令 JSON
#[no_mangle]
pub unsafe extern "C" fn ffi_source_login_action_v2(
    source_json: *const c_char,
    user_input_json: *const c_char,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let s = c_char_to_str(source_json)?;
        let u = c_char_to_str(user_input_json)?;
        crate::api::source_login_v2_api::eval_login_action_v2(s, u)
    });
    to_ffi_response(result)
}

// ─── 向后兼容的旧函数名 ────────────────────────────────────

// ─── TXT 搜索 API ──────────────────────────────────────────

/// TXT 全文搜索
#[no_mangle]
pub unsafe extern "C" fn ffi_txt_search(
    path: *const c_char,
    query: *const c_char,
    case_sensitive: bool,
    max_results: i32,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let p = c_char_to_str(path)?;
        let q = c_char_to_str(query)?;
        crate::api::txt_search_api::txt_search(p, q, case_sensitive, max_results)
    });
    to_ffi_response(result)
}

/// TXT 正则搜索
#[no_mangle]
pub unsafe extern "C" fn ffi_txt_search_regex(
    path: *const c_char,
    pattern: *const c_char,
    case_sensitive: bool,
    max_results: i32,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let p = c_char_to_str(path)?;
        let pat = c_char_to_str(pattern)?;
        crate::api::txt_search_api::txt_search_regex(p, pat, case_sensitive, max_results)
    });
    to_ffi_response(result)
}

/// TXT 章节内搜索
#[no_mangle]
pub unsafe extern "C" fn ffi_txt_search_in_chapter(
    path: *const c_char,
    query: *const c_char,
    chapter_index: i32,
    case_sensitive: bool,
    max_results: i32,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let p = c_char_to_str(path)?;
        let q = c_char_to_str(query)?;
        crate::api::txt_search_api::txt_search_in_chapter(
            p,
            q,
            chapter_index,
            case_sensitive,
            max_results,
        )
    });
    to_ffi_response(result)
}

/// TXT 搜索匹配计数
#[no_mangle]
pub unsafe extern "C" fn ffi_txt_search_count(
    path: *const c_char,
    query: *const c_char,
    case_sensitive: bool,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let p = c_char_to_str(path)?;
        let q = c_char_to_str(query)?;
        crate::api::txt_search_api::txt_search_count(p, q, case_sensitive)
    });
    to_ffi_response(result)
}

// ─── WebDAV 云同步 API ──────────────────────────────────────

/// WebDAV 列出远程目录
#[no_mangle]
pub unsafe extern "C" fn ffi_webdav_list_dir(
    config_json: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let c = c_char_to_str(config_json)?;
        let p = c_char_to_str(path)?;
        crate::api::webdav_api::webdav_list_dir(c, p)
    });
    to_ffi_response(result)
}

/// WebDAV 上传文件
#[no_mangle]
pub unsafe extern "C" fn ffi_webdav_upload(
    config_json: *const c_char,
    path: *const c_char,
    data: *const c_char,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let c = c_char_to_str(config_json)?;
        let p = c_char_to_str(path)?;
        let d = c_char_to_str(data)?;
        crate::api::webdav_api::webdav_upload(c, p, d)
    });
    to_ffi_response(result)
}

/// WebDAV 下载文件
#[no_mangle]
pub unsafe extern "C" fn ffi_webdav_download(
    config_json: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let c = c_char_to_str(config_json)?;
        let p = c_char_to_str(path)?;
        crate::api::webdav_api::webdav_download(c, p)
    });
    to_ffi_response(result)
}

/// WebDAV 删除远程文件
#[no_mangle]
pub unsafe extern "C" fn ffi_webdav_delete(
    config_json: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let c = c_char_to_str(config_json)?;
        let p = c_char_to_str(path)?;
        crate::api::webdav_api::webdav_delete(c, p)
    });
    to_ffi_response(result)
}

/// WebDAV 全量同步
#[no_mangle]
pub unsafe extern "C" fn ffi_webdav_full_sync(
    config_json: *const c_char,
    local_books: *const c_char,
    local_sources: *const c_char,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let c = c_char_to_str(config_json)?;
        let b = c_char_to_str(local_books)?;
        let s = c_char_to_str(local_sources)?;
        crate::api::webdav_api::webdav_full_sync(c, b, s)
    });
    to_ffi_response(result)
}

// ─── 下载管理器 API ──────────────────────────────────────────

/// 添加下载任务
#[no_mangle]
pub unsafe extern "C" fn ffi_download_add_task(
    book_url: *const c_char,
    chapter_url: *const c_char,
    chapter_title: *const c_char,
    chapter_index: i32,
    priority: i32,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let b = c_char_to_str(book_url)?;
        let c = c_char_to_str(chapter_url)?;
        let t = c_char_to_str(chapter_title)?;
        crate::api::download_api::download_add_task(b, c, t, chapter_index, priority)
    });
    to_ffi_response(result)
}

/// 获取下载统计信息
#[no_mangle]
pub extern "C" fn ffi_download_get_stats() -> *mut c_char {
    let result = catch_unwind(crate::api::download_api::download_get_stats);
    to_ffi_response(result)
}

/// 获取指定书籍的下载任务
#[no_mangle]
pub unsafe extern "C" fn ffi_download_list_by_book(book_url: *const c_char) -> *mut c_char {
    let result = catch_unwind(|| {
        let b = c_char_to_str(book_url)?;
        crate::api::download_api::download_list_by_book(b)
    });
    to_ffi_response(result)
}

/// 暂停所有下载
#[no_mangle]
pub extern "C" fn ffi_download_pause_all() -> *mut c_char {
    let result = catch_unwind(crate::api::download_api::download_pause_all);
    to_ffi_response(result)
}

/// 恢复所有下载
#[no_mangle]
pub extern "C" fn ffi_download_resume_all() -> *mut c_char {
    let result = catch_unwind(crate::api::download_api::download_resume_all);
    to_ffi_response(result)
}

/// 移除下载任务
#[no_mangle]
pub unsafe extern "C" fn ffi_download_remove_task(task_id: *const c_char) -> *mut c_char {
    let result = catch_unwind(|| {
        let t = c_char_to_str(task_id)?;
        crate::api::download_api::download_remove_task(t)
    });
    to_ffi_response(result)
}

/// 更新下载进度
#[no_mangle]
pub unsafe extern "C" fn ffi_download_update_progress(
    task_id: *const c_char,
    progress: f64,
) -> *mut c_char {
    let result = catch_unwind(|| {
        let t = c_char_to_str(task_id)?;
        crate::api::download_api::download_update_progress(t, progress)
    });
    to_ffi_response(result)
}

// ─── 压缩包导入与编码检测 FFI 函数 ──────────────────────

/// 导入 ZIP 压缩包中的书籍文件
#[no_mangle]
pub unsafe extern "C" fn ffi_archive_import_zip(
    zip_path: *const c_char,
    output_dir: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let zip = c_char_to_str(zip_path)?;
        let out = c_char_to_str(output_dir)?;
        Ok::<_, LegadoError>(crate::api::archive_import_api::import_zip_file(zip, out))
    }))
}

/// 导入 RAR 压缩包中的书籍文件（password 为空指针时表示无密码）
#[no_mangle]
pub unsafe extern "C" fn ffi_archive_import_rar(
    rar_path: *const c_char,
    output_dir: *const c_char,
    password: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let rar = c_char_to_str(rar_path)?;
        let out = c_char_to_str(output_dir)?;
        let pwd = if password.is_null() {
            None
        } else {
            Some(c_char_to_str(password)?.to_string())
        };
        Ok::<_, LegadoError>(crate::api::archive_import_api::import_rar_file(
            rar, out, pwd,
        ))
    }))
}

/// 列出 ZIP 压缩包中的书籍文件名（不解压）
#[no_mangle]
pub unsafe extern "C" fn ffi_archive_list_zip_files(zip_path: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let zip = c_char_to_str(zip_path)?;
        crate::api::archive_import_api::list_zip_book_files(zip)
    }))
}

/// 列出 RAR 压缩包中的书籍文件名（不解压，password 为空指针时表示无密码）
#[no_mangle]
pub unsafe extern "C" fn ffi_archive_list_rar_files(
    rar_path: *const c_char,
    password: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let rar = c_char_to_str(rar_path)?;
        let pwd = if password.is_null() {
            None
        } else {
            Some(c_char_to_str(password)?.to_string())
        };
        crate::api::archive_import_api::list_rar_book_files(rar, pwd)
    }))
}

/// 检测 TXT 文件编码
#[no_mangle]
pub unsafe extern "C" fn ffi_archive_detect_encoding(file_path: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let path = c_char_to_str(file_path)?;
        crate::api::archive_import_api::detect_txt_encoding(path)
    }))
}

/// 转换 TXT 文件编码
#[no_mangle]
pub unsafe extern "C" fn ffi_archive_convert_encoding(
    file_path: *const c_char,
    from_encoding: *const c_char,
    to_encoding: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let path = c_char_to_str(file_path)?;
        let from = c_char_to_str(from_encoding)?;
        let to = c_char_to_str(to_encoding)?;
        Ok::<_, LegadoError>(crate::api::archive_import_api::convert_txt_encoding(
            path, from, to,
        ))
    }))
}

/// 判断文件是否为压缩包格式
#[no_mangle]
pub unsafe extern "C" fn ffi_archive_is_archive(file_path: *const c_char) -> bool {
    catch_unwind(|| {
        let path = c_char_to_str(file_path).unwrap_or("");
        crate::api::archive_import_api::is_archive_file(path)
    })
    .unwrap_or(false)
}

// ─── 自动任务 FFI 函数 ───────────────────────────────

/// 构建书籍更新定时任务
#[no_mangle]
pub unsafe extern "C" fn ffi_auto_task_build_book_update(
    book_url: *const c_char,
    book_name: *const c_char,
    book_author: *const c_char,
    name: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        let bn = c_char_to_str(book_name)?;
        let ba = c_char_to_str(book_author)?;
        let n = c_char_to_str(name)?;
        Ok::<_, LegadoError>(crate::api::auto_task_api::build_book_update_task(
            url, bn, ba, n,
        ))
    }))
}

/// 批量更新 cron 表达式
#[no_mangle]
pub unsafe extern "C" fn ffi_auto_task_update_cron_batch(
    rules_json: *const c_char,
    ids_json: *const c_char,
    cron: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let rules = c_char_to_str(rules_json)?;
        let ids = c_char_to_str(ids_json)?;
        let c = c_char_to_str(cron)?;
        crate::api::auto_task_api::update_cron_batch(rules, ids, c)
    }))
}

/// 准备导入任务（合并本地运行时状态）
#[no_mangle]
pub unsafe extern "C" fn ffi_auto_task_prepare_imported(
    local_tasks_json: *const c_char,
    imported_json: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let local = c_char_to_str(local_tasks_json)?;
        let imported = c_char_to_str(imported_json)?;
        crate::api::auto_task_api::prepare_imported_tasks(local, imported)
    }))
}

/// 执行任务协议（task_id 为空指针时不带 ID）
#[no_mangle]
pub unsafe extern "C" fn ffi_auto_task_execute(
    protocol_json: *const c_char,
    task_id: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let protocol = c_char_to_str(protocol_json)?;
        let id = if task_id.is_null() {
            None
        } else {
            Some(c_char_to_str(task_id)?)
        };
        crate::api::auto_task_api::execute_task(protocol, id)
    }))
}

/// 规范化脚本
#[no_mangle]
pub unsafe extern "C" fn ffi_auto_task_normalize_script(script: *const c_char) -> *mut c_char {
    match catch_unwind(|| {
        let s = c_char_to_str(script).unwrap_or("");
        crate::api::auto_task_api::normalize_script(s)
    }) {
        Ok(result) => to_c_char(&result),
        Err(_) => to_c_char(""),
    }
}

/// 判断书籍是否允许刷新目录
#[no_mangle]
pub extern "C" fn ffi_auto_task_can_refresh_toc(
    can_update: bool,
    respect_can_update: bool,
) -> bool {
    catch_unwind(|| crate::api::auto_task_api::can_refresh_book_toc(can_update, respect_can_update))
        .unwrap_or(false)
}

/// 查找书籍更新任务
#[no_mangle]
pub unsafe extern "C" fn ffi_auto_task_find_book_update(
    tasks_json: *const c_char,
    book_url: *const c_char,
    book_name: *const c_char,
    book_author: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let tasks = c_char_to_str(tasks_json)?;
        let url = c_char_to_str(book_url)?;
        let bn = c_char_to_str(book_name)?;
        let ba = c_char_to_str(book_author)?;
        crate::api::auto_task_api::find_book_update_task(tasks, url, bn, ba)
    }))
}

/// 解析 cron 表达式计算下次执行时间（无法解析返回 -1）
#[no_mangle]
pub unsafe extern "C" fn ffi_auto_task_next_due_at(cron: *const c_char, from_ms: i64) -> i64 {
    catch_unwind(|| {
        let c = c_char_to_str(cron).unwrap_or("");
        crate::api::auto_task_api::next_due_at(c, from_ms)
    })
    .unwrap_or(-1)
}

// ─── 自动任务数据库 CRUD FFI 函数 ─────────────────────

/// 列出所有自动任务规则（返回 AutoTaskRule 数组 JSON）
#[no_mangle]
pub extern "C" fn ffi_auto_task_list_rules() -> *mut c_char {
    to_ffi_response(catch_unwind(|| crate::api::auto_task_api::list_rules_db()))
}

/// 创建自动任务规则（rule_json 为 AutoTaskRule JSON，返回任务 ID）
#[no_mangle]
pub unsafe extern "C" fn ffi_auto_task_create_rule(rule_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(rule_json)?;
        let rule: legado_core::models::AutoTaskRule =
            serde_json::from_str(json).map_err(|e| LegadoError::Parser(e.to_string()))?;
        crate::api::auto_task_api::create_rule_db(&rule)
    }))
}

/// 更新自动任务规则（rule_json 为 AutoTaskRule JSON）
#[no_mangle]
pub unsafe extern "C" fn ffi_auto_task_update_rule(rule_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(rule_json)?;
        let rule: legado_core::models::AutoTaskRule =
            serde_json::from_str(json).map_err(|e| LegadoError::Parser(e.to_string()))?;
        crate::api::auto_task_api::update_rule_db(&rule)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 删除自动任务规则（按 ID 删除）
#[no_mangle]
pub unsafe extern "C" fn ffi_auto_task_delete_rule(id: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let task_id = c_char_to_str(id)?;
        crate::api::auto_task_api::delete_rule_db(task_id)?;
        Ok::<_, LegadoError>("ok".to_string())
    }))
}

/// 根据 ID 查询自动任务规则（返回 AutoTaskRule JSON 或 null）
#[no_mangle]
pub unsafe extern "C" fn ffi_auto_task_find_rule_by_id(id: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let task_id = c_char_to_str(id)?;
        crate::api::auto_task_api::find_rule_by_id_db(task_id)
    }))
}

// ─── 规则订阅 FFI 函数（Task #89）─────────────────────

/// 获取规则订阅列表（返回 RuleSub 数组 JSON，按 customOrder 排序）
#[no_mangle]
pub extern "C" fn ffi_rule_sub_list() -> *mut c_char {
    to_ffi_response(catch_unwind(|| crate::api::rule_sub_api::list_subs_db()))
}

/// 保存规则订阅（sub_json 为 RuleSub JSON，返回是否成功）
#[no_mangle]
pub unsafe extern "C" fn ffi_rule_sub_save(sub_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(sub_json)?;
        let record: legado_db::RuleSubRecord =
            serde_json::from_str(json).map_err(|e| LegadoError::Parser(e.to_string()))?;
        crate::api::rule_sub_api::save_sub_db(&record)
    }))
}

/// 删除规则订阅（返回是否实际删除）
#[no_mangle]
pub extern "C" fn ffi_rule_sub_delete(id: i64) -> *mut c_char {
    to_ffi_response(catch_unwind(|| crate::api::rule_sub_api::delete_sub_db(id)))
}

/// 切换规则订阅启用状态（返回记录是否存在）
#[no_mangle]
pub extern "C" fn ffi_rule_sub_set_enabled(id: i64, enabled: bool) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::rule_sub_api::set_sub_enabled_db(id, enabled)
    }))
}

/// 批量更新规则订阅排序（ids_json 为新顺序 ID 数组 JSON）
#[no_mangle]
pub unsafe extern "C" fn ffi_rule_sub_update_order(ids_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(ids_json)?;
        let ids: Vec<i64> =
            serde_json::from_str(json).map_err(|e| LegadoError::Parser(e.to_string()))?;
        crate::api::rule_sub_api::update_sub_order_db(&ids)
    }))
}

/// 检查规则订阅更新（返回检查结果 JSON）
#[no_mangle]
pub extern "C" fn ffi_rule_sub_check_update(id: i64) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::rule_sub_api::check_sub_update_db(id)
    }))
}

/// 应用规则订阅更新（返回应用结果 JSON）
#[no_mangle]
pub extern "C" fn ffi_rule_sub_apply_update(id: i64) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::rule_sub_api::apply_sub_update_db(id)
    }))
}

// ─── 听书播放（播放模式/书籍解析）FFI 函数 ───────────────

/// 将播放模式写入 readConfig JSON（read_config 为空指针时视为空）
#[no_mangle]
pub unsafe extern "C" fn ffi_audio_with_play_mode(
    read_config: *const c_char,
    play_mode: i32,
) -> *mut c_char {
    match catch_unwind(|| {
        let config = if read_config.is_null() {
            None
        } else {
            Some(c_char_to_str(read_config).unwrap_or(""))
        };
        crate::api::audio_api::with_audio_play_mode(config, play_mode)
    }) {
        Ok(result) => to_c_char(&result),
        Err(_) => to_c_char("{}"),
    }
}

/// 解析听书书籍（返回 Book JSON 或 null）
#[no_mangle]
pub unsafe extern "C" fn ffi_audio_resolve_play_book(
    requested_book_url: *const c_char,
    cached_book_json: *const c_char,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let requested = if requested_book_url.is_null() {
            None
        } else {
            Some(c_char_to_str(requested_book_url)?)
        };
        let cached = if cached_book_json.is_null() {
            None
        } else {
            Some(c_char_to_str(cached_book_json)?)
        };
        crate::api::audio_api::resolve_audio_play_book(requested, cached)
    }))
}

#[no_mangle]
pub extern "C" fn legado_init() -> i32 {
    ffi_init()
}

// ─── 高亮体系 FFI 函数 ────────────────────────────

/// 新增/更新高亮记录（BookHighlight JSON，time=0 时自动分配），返回 time
#[no_mangle]
pub unsafe extern "C" fn ffi_highlight_add(highlight_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(highlight_json)?;
        crate::api::highlight_api::highlight_add(json)
    }))
}

/// 按主键 time 删除高亮记录
#[no_mangle]
pub extern "C" fn ffi_highlight_delete(time: i64) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::highlight_api::highlight_delete(time)
    }))
}

/// 按书籍删除全部高亮记录，返回删除数量
#[no_mangle]
pub unsafe extern "C" fn ffi_highlight_delete_by_book(book_url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::highlight_api::highlight_delete_by_book(url)
    }))
}

/// 按书籍获取高亮列表（BookHighlight 数组 JSON）
#[no_mangle]
pub unsafe extern "C" fn ffi_highlight_list_by_book(book_url: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::highlight_api::highlight_list_by_book(url)
    }))
}

/// 按书籍 + 章节索引获取高亮列表
#[no_mangle]
pub unsafe extern "C" fn ffi_highlight_list_by_chapter(
    book_url: *const c_char,
    chapter_index: i32,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let url = c_char_to_str(book_url)?;
        crate::api::highlight_api::highlight_list_by_chapter(url, chapter_index)
    }))
}

/// 全局关键词搜索高亮
#[no_mangle]
pub unsafe extern "C" fn ffi_highlight_search(keyword: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let key = c_char_to_str(keyword)?;
        crate::api::highlight_api::highlight_search(key)
    }))
}

/// 获取所有高亮规则（HighlightRule 数组 JSON，按 sortOrder 升序）
#[no_mangle]
pub extern "C" fn ffi_highlight_rule_list() -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::highlight_api::highlight_rule_list()
    }))
}

/// 保存高亮规则（HighlightRule JSON，id=0 时自增新增），返回规则 ID
#[no_mangle]
pub unsafe extern "C" fn ffi_highlight_rule_save(rule_json: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let json = c_char_to_str(rule_json)?;
        crate::api::highlight_api::highlight_rule_save(json)
    }))
}

/// 按 ID 删除高亮规则
#[no_mangle]
pub extern "C" fn ffi_highlight_rule_delete(id: i64) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        crate::api::highlight_api::highlight_rule_delete(id)
    }))
}

// ─── JS 单文件书源配置 FFI 函数 ──────────────────────────────

/// 提取 JS 单文件书源配置（返回 BookSource JSON）
#[no_mangle]
pub unsafe extern "C" fn ffi_js_source_extract(content: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let text = c_char_to_str(content)?;
        crate::api::js_source_config_api::js_source_extract(text)
    }))
}

/// JS 语法检查（返回 SyntaxCheckResult JSON）
#[no_mangle]
pub unsafe extern "C" fn ffi_js_source_syntax_check(content: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let text = c_char_to_str(content)?;
        crate::api::js_source_config_api::js_source_syntax_check(text)
    }))
}

/// 写回顶层配置对象的 lastUpdateTime（返回替换后脚本文本，无匹配时空字符串）
#[no_mangle]
pub unsafe extern "C" fn ffi_js_source_stamp_last_update_time(
    content: *const c_char,
    stamp: i64,
) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let text = c_char_to_str(content)?;
        crate::api::js_source_config_api::js_source_stamp_last_update_time(text, stamp)
    }))
}

// ─── 应用日志 FFI 函数（Task #79）────────────────────

/// 写入一条应用日志（级别：message / crash / http）
#[no_mangle]
pub unsafe extern "C" fn ffi_app_log_push(level: *const c_char, message: *const c_char) -> i32 {
    match catch_unwind(|| {
        let level = c_char_to_str(level).map_err(|e| e.to_error_code())?;
        let message = c_char_to_str(message).map_err(|e| e.to_error_code())?;
        crate::api::log_api::push_log(level, message).map_err(|e| e.to_error_code())
    }) {
        Ok(Ok(())) => 0,
        Ok(Err(code)) => code,
        Err(_) => -1,
    }
}

/// 获取指定级别的日志列表（JSON 数组，最新在前）
#[no_mangle]
pub unsafe extern "C" fn ffi_app_log_list(level: *const c_char) -> *mut c_char {
    to_ffi_response(catch_unwind(|| {
        let level = c_char_to_str(level)?;
        crate::api::log_api::list_logs(level)
    }))
}

/// 清空指定级别的日志
#[no_mangle]
pub unsafe extern "C" fn ffi_app_log_clear(level: *const c_char) -> i32 {
    match catch_unwind(|| {
        let level = c_char_to_str(level).map_err(|e| e.to_error_code())?;
        crate::api::log_api::clear_logs(level).map_err(|e| e.to_error_code())
    }) {
        Ok(Ok(())) => 0,
        Ok(Err(code)) => code,
        Err(_) => -1,
    }
}

/// 清空全部级别日志
#[no_mangle]
pub extern "C" fn ffi_app_log_clear_all() -> i32 {
    match catch_unwind(|| crate::api::log_api::clear_all_logs().map_err(|e| e.to_error_code())) {
        Ok(Ok(())) => 0,
        Ok(Err(code)) => code,
        Err(_) => -1,
    }
}

/// 导出全部日志为格式化文本（时间升序，64_000 字符截断）
#[no_mangle]
pub extern "C" fn ffi_app_log_export() -> *mut c_char {
    to_ffi_response(catch_unwind(crate::api::log_api::export_logs))
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
