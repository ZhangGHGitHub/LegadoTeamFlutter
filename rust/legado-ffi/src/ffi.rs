//! flutter_rust_bridge 桥接定义模块
//!
//! 所有 `pub fn` 会被 frb codegen 自动生成为 Dart bindings。
//! 函数内部调用 `crate::api::*` 的业务逻辑。
//!
//! **注意**: 所有复杂类型（Book, BookSource 等）均通过 JSON String 传递，
//! 避免 frb codegen 为外部 crate 的类型生成绑定。
//!
//! 运行代码生成:
//!   cd flutter_legado && flutter_rust_bridge_codegen generate

use legado_core::error::LegadoError;

// ─── BridgeError ──────────────────────────────────────────────

/// frb 桥接错误类型
///
/// 所有桥接函数统一返回 `Result<T, BridgeError>`。
/// frb 会自动将其映射为 Dart 异常。
#[derive(Debug, Clone)]
pub struct BridgeError {
    /// 错误描述信息
    pub message: String,
}

impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for BridgeError {}

impl From<LegadoError> for BridgeError {
    fn from(e: LegadoError) -> Self {
        Self {
            message: e.to_string(),
        }
    }
}

impl From<serde_json::Error> for BridgeError {
    fn from(e: serde_json::Error) -> Self {
        Self {
            message: format!("JSON error: {e}"),
        }
    }
}

/// 将值序列化为 JSON 字符串，错误统一包装为 BridgeError
fn to_json<T: serde::Serialize>(value: &T) -> Result<String, BridgeError> {
    serde_json::to_string(value).map_err(|e| BridgeError {
        message: format!("JSON serialize error: {e}"),
    })
}

// ─── frb bridge module ────────────────────────────────────────

/// flutter_rust_bridge 桥接定义
///
/// 所有 `pub fn` 会被 frb codegen 自动生成为 Dart 方法。
/// 复杂类型通过 JSON String 传递，避免 frb 为外部类型生成绑定。
#[flutter_rust_bridge::frb]
pub mod ffi {
    use super::to_json;
    use super::BridgeError;
    use legado_core::error::LegadoError;

    // ─── 基础 ─────────────────────────────────────────────────

    /// 初始化 Legado 运行时（首次调用时创建 tokio runtime）
    pub fn init() -> Result<(), BridgeError> {
        let _ = crate::runtime::get_runtime();
        Ok(())
    }

    /// 获取版本号
    pub fn version() -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }

    // ─── 数据库 ───────────────────────────────────────────────

    /// 打开数据库并初始化全局连接
    pub fn db_open(path: String) -> Result<(), BridgeError> {
        let db = legado_db::init_database(&path)?;
        crate::db_state::init_database(db);
        Ok(())
    }

    // ─── 书架管理 ─────────────────────────────────────────────

    /// 获取书架上所有书籍（JSON 数组）
    pub fn bookshelf_list() -> Result<String, BridgeError> {
        let books = crate::api::bookshelf::list_books()?;
        to_json(&books)
    }

    /// 添加书籍到书架（传入 JSON 字符串），返回书籍信息（JSON）
    pub fn bookshelf_add(book_json: String) -> Result<String, BridgeError> {
        let book = crate::api::bookshelf::add_book(&book_json)?;
        to_json(&book)
    }

    /// 更新书籍信息（传入 JSON 字符串）
    pub fn bookshelf_update(book_json: String) -> Result<(), BridgeError> {
        crate::api::bookshelf::update_book(&book_json)?;
        Ok(())
    }

    /// 按 bookUrl 删除书籍
    pub fn bookshelf_delete(book_url: String) -> Result<(), BridgeError> {
        crate::api::bookshelf::delete_book(&book_url)?;
        Ok(())
    }

    /// 按 bookUrl 获取书籍详情（JSON，可能为 null）
    pub fn bookshelf_get(book_url: String) -> Result<String, BridgeError> {
        let book = crate::api::bookshelf::get_book(&book_url)?;
        to_json(&book)
    }

    /// 更新阅读进度
    pub fn reader_update_progress(
        book_url: String,
        chapter_index: i32,
        chapter_pos: i32,
    ) -> Result<(), BridgeError> {
        crate::api::bookshelf::update_reading_progress(&book_url, chapter_index, chapter_pos)?;
        Ok(())
    }

    // ─── 书源管理 ─────────────────────────────────────────────

    /// 获取所有书源列表（JSON 数组）
    pub fn source_list() -> Result<String, BridgeError> {
        let sources = crate::api::source::list_sources()?;
        to_json(&sources)
    }

    /// 获取所有启用的书源（JSON 数组）
    pub fn source_list_enabled() -> Result<String, BridgeError> {
        let sources = crate::api::source::list_enabled_sources()?;
        to_json(&sources)
    }

    /// 添加书源（传入 JSON 字符串），返回书源信息（JSON）
    pub fn source_add(source_json: String) -> Result<String, BridgeError> {
        let source = crate::api::source::add_source(&source_json)?;
        to_json(&source)
    }

    /// 更新书源（传入 JSON 字符串）
    pub fn source_update(source_json: String) -> Result<(), BridgeError> {
        crate::api::source::update_source(&source_json)?;
        Ok(())
    }

    /// 按 URL 删除书源
    pub fn source_delete(source_url: String) -> Result<(), BridgeError> {
        crate::api::source::delete_source(&source_url)?;
        Ok(())
    }

    /// 启用书源
    pub fn source_enable(source_url: String) -> Result<(), BridgeError> {
        crate::api::source::enable_source(&source_url)?;
        Ok(())
    }

    /// 禁用书源
    pub fn source_disable(source_url: String) -> Result<(), BridgeError> {
        crate::api::source::disable_source(&source_url)?;
        Ok(())
    }

    /// 批量导入书源（JSON 数组），返回成功导入的数量
    pub fn source_import(json_array: String) -> Result<i32, BridgeError> {
        Ok(crate::api::source::import_sources(&json_array)?)
    }

    /// 导出所有书源为 JSON 数组
    pub fn source_export() -> Result<String, BridgeError> {
        let sources = crate::api::source::export_sources()?;
        to_json(&sources)
    }

    // ─── 搜索 ─────────────────────────────────────────────────

    /// 搜索书籍（返回 JSON 数组）
    ///
    /// `keyword` — 搜索关键词
    /// `source_urls_json` — 可选 JSON 数组，指定搜索的书源 URL 列表；为空则搜索所有启用的书源
    pub fn search_books(keyword: String, source_urls_json: String) -> Result<String, BridgeError> {
        let results = crate::api::search::search_books(&keyword, &source_urls_json)?;
        to_json(&results)
    }

    /// 多源并行搜索（返回 JSON 数组）
    ///
    /// `query` — 搜索关键词
    /// `source_urls_json` — 可选 JSON 数组，指定搜索的书源 URL 列表；为空则搜索所有启用的书源
    pub fn search_multi(query: String, source_urls_json: String) -> Result<String, BridgeError> {
        let json_str = crate::api::search::multi_source_search(&query, &source_urls_json)?;
        Ok(json_str)
    }

    /// 取消正在进行的搜索
    pub fn search_cancel() {
        crate::api::search::cancel_search();
    }

    // ─── 阅读 ─────────────────────────────────────────────────

    /// 获取书籍的章节列表（JSON）
    pub fn reader_get_chapters(book_url: String) -> Result<String, BridgeError> {
        let resp = crate::api::reader::get_chapters(&book_url)?;
        to_json(&resp)
    }

    /// 获取章节正文内容
    ///
    /// 本地书籍直接返回正文文本；在线书籍返回 JSON（含 chapter_url 等信息，需 Dart 侧进一步获取）
    pub fn reader_get_content(book_url: String, chapter_index: i32) -> Result<String, BridgeError> {
        Ok(crate::api::reader::get_chapter_content(
            &book_url,
            chapter_index,
        )?)
    }

    /// 从网络刷新书籍目录（返回 JSON 章节列表）
    ///
    /// `book_url` — 书籍详情页 URL
    /// `source_url` — 书源 URL
    pub fn reader_refresh_toc(book_url: String, source_url: String) -> Result<String, BridgeError> {
        let resp = crate::api::reader::refresh_toc(&book_url, &source_url)?;
        to_json(&resp)
    }

    /// 获取章节正文内容（在线抓取，带 DB 缓存，返回真实正文文本）
    ///
    /// `book_url` — 书籍 URL
    /// `chapter_url` — 章节 URL
    /// `source_url` — 书源 URL
    pub fn reader_fetch_content(
        book_url: String,
        chapter_url: String,
        source_url: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::reader::fetch_chapter_content(
            &book_url,
            &chapter_url,
            &source_url,
        )?)
    }

    // ─── 书籍导入 ─────────────────────────────────────────────

    /// 检测书籍文件格式（JSON）
    pub fn import_detect_format(file_path: String) -> Result<String, BridgeError> {
        let result = crate::api::book_import::detect_format(&file_path)?;
        to_json(&result)
    }

    /// 解析书籍元数据（返回 JSON 字符串）
    pub fn import_parse_metadata(file_path: String) -> Result<String, BridgeError> {
        let metadata = crate::api::book_import::parse_metadata(&file_path)?;
        Ok(serde_json::to_string(&metadata)?)
    }

    /// 导入本地书籍到书架（JSON）
    pub fn import_local_book(file_path: String) -> Result<String, BridgeError> {
        let result = crate::api::book_import::import_local_book(&file_path)?;
        to_json(&result)
    }

    // ─── RSS ──────────────────────────────────────────────────

    /// 获取所有 RSS 源列表（JSON 数组）
    pub fn rss_list_sources() -> Result<String, BridgeError> {
        let sources = crate::api::rss::list_rss_sources()?;
        to_json(&sources)
    }

    /// 添加 RSS 源（传入 JSON 字符串），返回源信息（JSON）
    pub fn rss_add_source(source_json: String) -> Result<String, BridgeError> {
        let source = crate::api::rss::add_rss_source(&source_json)?;
        to_json(&source)
    }

    /// 删除 RSS 源
    pub fn rss_delete_source(source_url: String) -> Result<(), BridgeError> {
        crate::api::rss::delete_rss_source(&source_url)?;
        Ok(())
    }

    /// 获取 RSS 源的文章列表（JSON 数组）
    pub fn rss_fetch_articles(source_url: String) -> Result<String, BridgeError> {
        let articles = crate::api::rss::fetch_rss_articles(&source_url)?;
        to_json(&articles)
    }

    // ─── 换源 ───────────────────────────────────────────────

    /// 搜索可替换的书源（返回 JSON 格式的匹配结果列表）
    ///
    /// `book_name` — 当前书籍名称
    /// `author` — 当前作者
    pub fn source_switch_search(book_name: String, author: String) -> Result<String, BridgeError> {
        let resp = crate::api::source_switch::search_alternative_sources(&book_name, &author)?;
        to_json(&resp)
    }

    /// 切换到新书源（返回更新后的书籍 JSON）
    ///
    /// `book_url` — 当前书籍的 bookUrl
    /// `new_source_url` — 新书源的 URL
    /// `new_book_url` — 新书源中该书籍的详情页 URL
    pub fn source_switch_apply(
        book_url: String,
        new_source_url: String,
        new_book_url: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::source_switch::switch_book_source(
            &book_url,
            &new_source_url,
            &new_book_url,
        )?)
    }

    // ─── HTTP 工具 ────────────────────────────────────────────

    /// HTTP GET 请求，返回 JSON 格式的响应
    pub fn http_get(url: String) -> Result<String, BridgeError> {
        let response = crate::runtime::block_on(async {
            let client = legado_net::LegadoClient::new(legado_net::LegadoClientConfig::default())
                .map_err(|e| LegadoError::Network(format!("创建客户端失败: {e}")))?;
            client.get(&url, None).await
        })?;
        Ok(serde_json::to_string(&serde_json::json!({
            "status": response.status,
            "body": response.body,
            "url": response.url,
        }))?)
    }

    /// HTTP POST 请求，返回 JSON 格式的响应
    pub fn http_post(url: String, body: String) -> Result<String, BridgeError> {
        let response = crate::runtime::block_on(async {
            let client = legado_net::LegadoClient::new(legado_net::LegadoClientConfig::default())
                .map_err(|e| LegadoError::Network(format!("创建客户端失败: {e}")))?;
            client.post(&url, &body, None).await
        })?;
        Ok(serde_json::to_string(&serde_json::json!({
            "status": response.status,
            "body": response.body,
            "url": response.url,
        }))?)
    }

    // ─── WebBook 书源规则驱动链路 ────────────────────────────────────────────

    /// 搜索书籍（书源规则驱动，返回 JSON 数组）
    ///
    /// `source_json` — BookSource JSON 字符串
    /// `query` — 搜索关键词
    /// `page` — 页码（从 1 开始）
    pub fn webbook_search(
        source_json: String,
        query: String,
        page: i32,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::web_book::webbook_search(
            &source_json,
            &query,
            page,
        )?)
    }

    /// 获取书籍详情（返回 WebBookInfo JSON）
    ///
    /// `source_json` — BookSource JSON 字符串
    /// `book_url` — 书籍详情页 URL
    pub fn webbook_info(source_json: String, book_url: String) -> Result<String, BridgeError> {
        Ok(crate::api::web_book::webbook_info(&source_json, &book_url)?)
    }

    /// 获取章节列表（返回 JSON 数组）
    ///
    /// `source_json` — BookSource JSON 字符串
    /// `book_url` — 书籍详情页 URL
    pub fn webbook_chapters(source_json: String, book_url: String) -> Result<String, BridgeError> {
        Ok(crate::api::web_book::webbook_chapters(
            &source_json,
            &book_url,
        )?)
    }

    /// 获取章节正文内容
    ///
    /// `source_json` — BookSource JSON 字符串
    /// `chapter_json` — WebChapter JSON 字符串
    pub fn webbook_content(
        source_json: String,
        chapter_json: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::web_book::webbook_content(
            &source_json,
            &chapter_json,
        )?)
    }

    // ─── 规则解析 ─────────────────────────────────────────────

    /// 使用规则解析内容，返回 JSON 格式的结果
    pub fn parse_rule(
        content: String,
        rule: String,
        rule_type: String,
    ) -> Result<String, BridgeError> {
        let _ = &rule_type; // 暂未使用
        let analyzer = legado_parser::AnalyzeRule::new(content, String::new());
        let results = analyzer.get_strings(&rule)?;
        Ok(serde_json::to_string(&serde_json::json!({
            "results": results,
            "count": results.len(),
        }))?)
    }

    // ─── JS 引擎 ──────────────────────────────────────────────

    /// 执行 JS 脚本，返回结果字符串
    pub fn js_eval(script: String) -> Result<String, BridgeError> {
        let engine = legado_js::StubJsEngine::new();
        use legado_js::JsEngine;
        let result_str = engine.eval(&script)?;
        Ok(result_str)
    }

    // ─── 书签管理 ─────────────────────────────────────────────

    /// 获取书籍的所有书签（JSON 数组）
    pub fn bookmark_get_all(book_name: String) -> Result<String, BridgeError> {
        let bookmarks = crate::api::bookmark_api::get_bookmarks(&book_name)?;
        to_json(&bookmarks)
    }

    /// 添加书签，返回书签 id
    pub fn bookmark_add(
        book_name: String,
        book_author: String,
        chapter_index: i32,
        chapter_pos: i32,
        chapter_name: String,
        book_text: String,
        content: String,
    ) -> Result<i64, BridgeError> {
        let id = crate::api::bookmark_api::add_bookmark(
            &book_name,
            &book_author,
            chapter_index,
            chapter_pos,
            &chapter_name,
            &book_text,
            &content,
        )?;
        Ok(id)
    }

    /// 删除书签
    pub fn bookmark_delete(bookmark_id: i64) -> Result<(), BridgeError> {
        crate::api::bookmark_api::delete_bookmark(bookmark_id)?;
        Ok(())
    }

    /// 搜索书签（JSON 数组）
    pub fn bookmark_search(keyword: String) -> Result<String, BridgeError> {
        let bookmarks = crate::api::bookmark_api::search_bookmarks(&keyword)?;
        to_json(&bookmarks)
    }

    /// 获取所有书签（JSON 数组）
    pub fn bookmark_list() -> Result<String, BridgeError> {
        let bookmarks = crate::api::bookmark_api::get_all_bookmarks()?;
        to_json(&bookmarks)
    }

    // ─── 替换规则管理 ─────────────────────────────────────────

    /// 获取所有替换规则（JSON 数组）
    pub fn replace_rule_list() -> Result<String, BridgeError> {
        let rules = crate::api::replace_rule_api::get_replace_rules()?;
        to_json(&rules)
    }

    /// 添加替换规则，返回规则 id
    pub fn replace_rule_add(
        name: String,
        pattern: String,
        replacement: String,
        is_regex: bool,
        scope: String,
    ) -> Result<i64, BridgeError> {
        let id = crate::api::replace_rule_api::add_replace_rule(
            &name,
            &pattern,
            &replacement,
            is_regex,
            &scope,
        )?;
        Ok(id)
    }

    /// 更新替换规则
    pub fn replace_rule_update(
        rule_id: i64,
        name: String,
        pattern: String,
        replacement: String,
        is_regex: bool,
        is_enabled: bool,
    ) -> Result<(), BridgeError> {
        crate::api::replace_rule_api::update_replace_rule(
            rule_id,
            &name,
            &pattern,
            &replacement,
            is_regex,
            is_enabled,
        )?;
        Ok(())
    }

    /// 删除替换规则
    pub fn replace_rule_delete(rule_id: i64) -> Result<(), BridgeError> {
        crate::api::replace_rule_api::delete_replace_rule(rule_id)?;
        Ok(())
    }

    /// 获取启用的替换规则（JSON 数组，用于阅读时应用）
    pub fn replace_rule_enabled() -> Result<String, BridgeError> {
        let rules = crate::api::replace_rule_api::get_enabled_rules()?;
        to_json(&rules)
    }

    /// 启用/禁用替换规则
    pub fn replace_rule_set_enabled(rule_id: i64, enabled: bool) -> Result<(), BridgeError> {
        crate::api::replace_rule_api::set_rule_enabled(rule_id, enabled)?;
        Ok(())
    }
}
