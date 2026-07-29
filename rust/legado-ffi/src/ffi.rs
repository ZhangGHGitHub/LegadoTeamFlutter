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

    // ─── RSS 收藏 ────────────────────────────────────────

    /// 获取所有 RSS 收藏（JSON 数组）
    pub fn rss_star_list() -> Result<String, BridgeError> {
        let stars = crate::api::rss_star_api::get_rss_stars()?;
        to_json(&stars)
    }

    /// 添加 RSS 收藏，返回收藏时间戳
    pub fn rss_star_add(
        source_url: String,
        title: String,
        link: String,
    ) -> Result<i64, BridgeError> {
        let ts = crate::api::rss_star_api::add_rss_star(&source_url, &title, &link)?;
        Ok(ts)
    }

    /// 取消 RSS 收藏（按 link 删除）
    pub fn rss_star_delete(link: String) -> Result<bool, BridgeError> {
        let ok = crate::api::rss_star_api::delete_rss_star(&link)?;
        Ok(ok)
    }

    /// 判断是否已收藏
    pub fn rss_star_is_starred(link: String) -> Result<bool, BridgeError> {
        let starred = crate::api::rss_star_api::is_rss_starred(&link)?;
        Ok(starred)
    }

    // ─── 搜索历史 ────────────────────────────────────────

    /// 获取最近搜索历史（JSON 数组）
    pub fn search_history_list(limit: i32) -> Result<String, BridgeError> {
        let history = crate::api::search_history_api::get_search_history(limit)?;
        to_json(&history)
    }

    /// 添加搜索关键词，返回时间戳
    pub fn search_history_add(keyword: String, book_name: String) -> Result<i64, BridgeError> {
        let ts = crate::api::search_history_api::add_search_keyword(&keyword, &book_name)?;
        Ok(ts)
    }

    /// 删除搜索关键词
    pub fn search_history_delete(keyword: String) -> Result<bool, BridgeError> {
        let ok = crate::api::search_history_api::delete_search_keyword(&keyword)?;
        Ok(ok)
    }

    /// 清空搜索历史
    pub fn search_history_clear() -> Result<bool, BridgeError> {
        let ok = crate::api::search_history_api::clear_search_history()?;
        Ok(ok)
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

    /// 执行 JS 脚本，返回结果字符串（启用 quickjs feature 时使用真实引擎）
    #[cfg(feature = "quickjs")]
    pub fn js_eval(script: String) -> Result<String, BridgeError> {
        use legado_js::engine::QuickJsEngine;
        use legado_js::JsEngine;
        use legado_js::SandboxConfig;
        let engine = QuickJsEngine::new(SandboxConfig::permissive()).map_err(|e| BridgeError {
            message: e.to_string(),
        })?;
        let result = engine.eval(&script)?;
        Ok(result)
    }

    /// 执行 JS 脚本（未启用 quickjs 时返回错误）
    #[cfg(not(feature = "quickjs"))]
    pub fn js_eval(script: String) -> Result<String, BridgeError> {
        let _ = &script;
        Err(BridgeError {
            message: "QuickJS engine not enabled".to_string(),
        })
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

    // ─── 阅读记录 ─────────────────────────────────────

    /// 获取所有阅读记录（JSON 数组）
    pub fn read_record_list() -> Result<String, BridgeError> {
        let records = crate::api::read_record_api::get_read_records()?;
        to_json(&records)
    }

    /// 添加/更新阅读记录，返回阅读时长
    pub fn read_record_upsert(book_name: String, read_time: i64) -> Result<i64, BridgeError> {
        let rt = crate::api::read_record_api::upsert_read_record(&book_name, read_time)?;
        Ok(rt)
    }

    /// 删除阅读记录
    pub fn read_record_delete(book_name: String) -> Result<bool, BridgeError> {
        let ok = crate::api::read_record_api::delete_read_record(&book_name)?;
        Ok(ok)
    }

    /// 清空所有阅读记录
    pub fn read_record_clear() -> Result<bool, BridgeError> {
        let ok = crate::api::read_record_api::clear_read_records()?;
        Ok(ok)
    }

    // ─── 书籍分组 ─────────────────────────────────────

    /// 获取所有书籍分组（JSON 数组）
    pub fn book_group_list() -> Result<String, BridgeError> {
        let groups = crate::api::book_group_api::get_book_groups()?;
        to_json(&groups)
    }

    /// 添加书籍分组，返回新分组 ID
    pub fn book_group_add(
        group_name: String,
        cover: String,
        order: i32,
    ) -> Result<i64, BridgeError> {
        let id = crate::api::book_group_api::add_book_group(&group_name, &cover, order)?;
        Ok(id)
    }

    /// 更新书籍分组
    pub fn book_group_update(
        id: i64,
        group_name: String,
        cover: String,
        order: i32,
    ) -> Result<bool, BridgeError> {
        let ok = crate::api::book_group_api::update_book_group(id, &group_name, &cover, order)?;
        Ok(ok)
    }

    /// 删除书籍分组
    pub fn book_group_delete(id: i64) -> Result<bool, BridgeError> {
        let ok = crate::api::book_group_api::delete_book_group(id)?;
        Ok(ok)
    }

    /// 设置分组显示状态
    pub fn book_group_set_show(id: i64, show: bool) -> Result<bool, BridgeError> {
        let ok = crate::api::book_group_api::set_book_group_show(id, show)?;
        Ok(ok)
    }

    // ─── 阅读统计 ─────────────────────────────────────

    /// 获取今日阅读统计（JSON）
    pub fn stats_today() -> Result<String, BridgeError> {
        let stats = crate::api::reading_stats_api::get_today_stats()?;
        to_json(&stats)
    }

    /// 获取最近 N 天每日统计（JSON 数组）
    pub fn stats_daily(days: i32) -> Result<String, BridgeError> {
        let stats = crate::api::reading_stats_api::get_daily_stats(days)?;
        to_json(&stats)
    }

    /// 获取按书籍分组的统计（JSON 数组）
    pub fn stats_by_book() -> Result<String, BridgeError> {
        let stats = crate::api::reading_stats_api::get_book_stats()?;
        to_json(&stats)
    }

    /// 获取阅读热力图数据（JSON 数组）
    pub fn stats_heatmap(days: i32) -> Result<String, BridgeError> {
        let data = crate::api::reading_stats_api::get_reading_heatmap(days)?;
        to_json(&data)
    }

    // ─── 缓存管理 ─────────────────────────────────────

    /// 获取缓存总大小（字节）
    pub fn cache_get_size() -> Result<i64, BridgeError> {
        let size = crate::api::cache_api::get_cache_size()?;
        Ok(size)
    }

    /// 清空所有缓存
    pub fn cache_clear() -> Result<bool, BridgeError> {
        let ok = crate::api::cache_api::clear_cache()?;
        Ok(ok)
    }

    /// 获取章节缓存内容
    pub fn cache_get_chapter(book_url: String, chapter_index: i32) -> Result<String, BridgeError> {
        let content = crate::api::cache_api::get_chapter_cache(&book_url, chapter_index)?;
        Ok(content)
    }

    // ─── 配置管理 ─────────────────────────────────────

    /// 获取配置项
    pub fn config_get(key: String) -> Result<String, BridgeError> {
        let value = crate::api::config_api::get_config(&key)?;
        Ok(value)
    }

    /// 设置配置项
    pub fn config_set(key: String, value: String) -> Result<bool, BridgeError> {
        let ok = crate::api::config_api::set_config(&key, &value)?;
        Ok(ok)
    }

    /// 获取所有配置（JSON 对象）
    pub fn config_get_all() -> Result<String, BridgeError> {
        let config = crate::api::config_api::get_all_config()?;
        to_json(&config)
    }

    // ─── HTTP TTS 朗读源 ───────────────────────────────────

    /// 获取所有 HTTP TTS 源（JSON 数组）
    pub fn http_tts_list() -> Result<String, BridgeError> {
        let list = crate::api::http_tts_api::get_http_tts_list()?;
        to_json(&list)
    }

    /// 添加 HTTP TTS 源，返回新 ID
    pub fn http_tts_add(name: String, url: String) -> Result<i64, BridgeError> {
        let id = crate::api::http_tts_api::add_http_tts(&name, &url)?;
        Ok(id)
    }

    /// 更新 HTTP TTS 源
    pub fn http_tts_update(id: i64, name: String, url: String) -> Result<bool, BridgeError> {
        let ok = crate::api::http_tts_api::update_http_tts(id, &name, &url)?;
        Ok(ok)
    }

    /// 删除 HTTP TTS 源
    pub fn http_tts_delete(id: i64) -> Result<bool, BridgeError> {
        let ok = crate::api::http_tts_api::delete_http_tts(id)?;
        Ok(ok)
    }

    /// 设置 HTTP TTS 源启用/禁用
    pub fn http_tts_set_enabled(id: i64, enabled: bool) -> Result<bool, BridgeError> {
        let ok = crate::api::http_tts_api::set_http_tts_enabled(id, enabled)?;
        Ok(ok)
    }

    // ─── 音频播放进度 ───────────────────────────────────

    /// 获取音频播放进度（毫秒）
    pub fn audio_get_progress(book_url: String, chapter_index: i32) -> Result<i64, BridgeError> {
        let pos = crate::api::audio_api::get_audio_progress(&book_url, chapter_index)?;
        Ok(pos)
    }

    /// 保存音频播放进度
    pub fn audio_save_progress(
        book_url: String,
        chapter_index: i32,
        position: i64,
    ) -> Result<bool, BridgeError> {
        let ok = crate::api::audio_api::save_audio_progress(&book_url, chapter_index, position)?;
        Ok(ok)
    }

    // ─── 备份/恢复 ───────────────────────────────────────

    /// 创建备份到指定路径，返回备份文件路径
    pub fn backup_create(path: String) -> Result<String, BridgeError> {
        let result = crate::api::backup_api::backup_create(&path)?;
        Ok(result)
    }

    /// 从备份文件恢复，返回恢复统计（JSON）
    pub fn backup_restore(path: String) -> Result<String, BridgeError> {
        let result = crate::api::backup_api::backup_restore(&path)?;
        Ok(result)
    }

    /// 列出备份文件（JSON 数组）
    pub fn backup_list(dir: String) -> String {
        crate::api::backup_api::backup_list(&dir)
    }

    // ─── 服务器管理 ─────────────────────────────────────

    /// 启动 legado-server，返回状态消息
    pub fn server_start(port: u16) -> Result<String, BridgeError> {
        let msg = crate::api::server_api::server_start(port)?;
        Ok(msg)
    }

    /// 停止服务器
    pub fn server_stop() -> String {
        crate::api::server_api::server_stop()
    }

    /// 获取服务器状态（JSON）
    pub fn server_status() -> String {
        crate::api::server_api::server_status()
    }

    // ─── 用户管理 ─────────────────────────────────────

    /// 获取所有用户（JSON 数组）
    pub fn user_get_all() -> Result<String, BridgeError> {
        let json = crate::api::user_api::get_users()?;
        Ok(json)
    }

    /// 保存用户，返回用户 ID
    pub fn user_save(
        username: String,
        password: String,
        source_url: String,
    ) -> Result<i64, BridgeError> {
        let id = crate::api::user_api::save_user(&username, &password, &source_url)?;
        Ok(id)
    }

    /// 删除用户
    pub fn user_delete(username: String) -> Result<bool, BridgeError> {
        let ok = crate::api::user_api::delete_user(&username)?;
        Ok(ok)
    }

    /// 用户登录
    pub fn user_login(username: String, password: String) -> Result<bool, BridgeError> {
        let ok = crate::api::user_api::login(&username, &password)?;
        Ok(ok)
    }

    /// 用户登出
    pub fn user_logout(username: String) -> Result<bool, BridgeError> {
        let ok = crate::api::user_api::logout(&username)?;
        Ok(ok)
    }

    /// 检查登录状态
    pub fn user_check_login(username: String) -> Result<bool, BridgeError> {
        let ok = crate::api::user_api::check_login_status(&username)?;
        Ok(ok)
    }

    // ─── WebDAV 云同步 ─────────────────────────────────────

    /// 列出 WebDAV 远程目录（JSON 数组）
    pub fn webdav_list_dir(config_json: String, path: String) -> Result<String, BridgeError> {
        Ok(crate::api::webdav_api::webdav_list_dir(
            &config_json, &path,
        )?)
    }

    /// 上传文件到 WebDAV
    pub fn webdav_upload(
        config_json: String,
        path: String,
        data: String,
    ) -> Result<(), BridgeError> {
        crate::api::webdav_api::webdav_upload(&config_json, &path, &data)?;
        Ok(())
    }

    /// 从 WebDAV 下载文件
    pub fn webdav_download(config_json: String, path: String) -> Result<String, BridgeError> {
        Ok(crate::api::webdav_api::webdav_download(
            &config_json, &path,
        )?)
    }

    /// 删除 WebDAV 远程文件
    pub fn webdav_delete(config_json: String, path: String) -> Result<(), BridgeError> {
        crate::api::webdav_api::webdav_delete(&config_json, &path)?;
        Ok(())
    }

    /// WebDAV 全量同步（返回 JSON: {"books": "...", "sources": "..."}）
    pub fn webdav_full_sync(
        config_json: String,
        local_books: String,
        local_sources: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::webdav_api::webdav_full_sync(
            &config_json,
            &local_books,
            &local_sources,
        )?)
    }

    // ─── 下载管理器 ─────────────────────────────────────

    /// 添加下载任务，返回任务 ID
    pub fn download_add_task(
        book_url: String,
        chapter_url: String,
        chapter_title: String,
        chapter_index: i32,
        priority: i32,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::download_api::download_add_task(
            &book_url,
            &chapter_url,
            &chapter_title,
            chapter_index,
            priority,
        )?)
    }

    /// 获取下载统计信息（JSON）
    pub fn download_get_stats() -> Result<String, BridgeError> {
        Ok(crate::api::download_api::download_get_stats()?)
    }

    /// 获取指定书籍的下载任务（JSON 数组）
    pub fn download_list_by_book(book_url: String) -> Result<String, BridgeError> {
        Ok(crate::api::download_api::download_list_by_book(&book_url)?)
    }

    /// 暂停所有下载
    pub fn download_pause_all() -> Result<(), BridgeError> {
        crate::api::download_api::download_pause_all()?;
        Ok(())
    }

    /// 恢复所有下载
    pub fn download_resume_all() -> Result<(), BridgeError> {
        crate::api::download_api::download_resume_all()?;
        Ok(())
    }

    /// 移除下载任务
    pub fn download_remove_task(task_id: String) -> Result<(), BridgeError> {
        crate::api::download_api::download_remove_task(&task_id)?;
        Ok(())
    }

    /// 更新下载进度
    pub fn download_update_progress(task_id: String, progress: f64) -> Result<(), BridgeError> {
        crate::api::download_api::download_update_progress(&task_id, progress)?;
        Ok(())
    }

    // ─── 段评/章评 ─────────────────────────────────────

    /// 获取指定章节的所有评论（JSON 数组）
    pub fn review_get_by_chapter(
        book_url: String,
        chapter_index: i32,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::review_api::review_get_by_chapter(
            &book_url,
            chapter_index,
        )?)
    }

    /// 添加评论，返回评论 ID
    pub fn review_add(
        book_url: String,
        chapter_index: i32,
        paragraph_index: i32,
        content: String,
        author: String,
    ) -> Result<i64, BridgeError> {
        Ok(crate::api::review_api::review_add(
            &book_url,
            chapter_index,
            paragraph_index,
            &content,
            &author,
        )?)
    }

    /// 删除评论
    pub fn review_delete(id: i64) -> Result<bool, BridgeError> {
        Ok(crate::api::review_api::review_delete(id)?)
    }

    /// 点赞评论
    pub fn review_like(id: i64) -> Result<(), BridgeError> {
        crate::api::review_api::review_like(id)?;
        Ok(())
    }
}
