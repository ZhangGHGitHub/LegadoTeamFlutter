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
    use crate::frb_generated::StreamSink;

    // ─── 基础 ─────────────────────────────────────────────────

    /// 初始化 Legado 运行时（首次调用时创建 tokio runtime）
    pub fn init() -> Result<(), BridgeError> {
        let _ = crate::runtime::get_runtime();
        Ok(())
    }

    /// 注入真实设备 ID（Android Settings.Secure.ANDROID_ID）
    ///
    /// 书山聚合等源登录时登记该设备，正文请求需携带匹配的 X-Device-Id
    /// 才返回明文；Flutter 侧启动时读取系统 ANDROID_ID 后调用。
    pub fn set_device_id(device_id: String) {
        legado_js::host_api::device_id::set_device_id(&device_id);
    }

    /// 获取版本号
    pub fn version() -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }

    // ─── 数据库 ───────────────────────────────────────────────

    /// 打开数据库并初始化全局连接
    pub fn db_open(path: String) -> Result<(), BridgeError> {
        // 已初始化时跳过冗余的 Database::open（含迁移检查 + 池构建）
        if crate::db_state::is_initialized() {
            eprintln!("[legado-ffi] 数据库已初始化，忽略重复 db_open 调用");
            return Ok(());
        }
        // 记录 DB 文件路径（Task #76：独立 MCP 服务等二次连接池
        // 场景复用同一文件，避免硬编码相对路径）
        crate::db_state::record_db_path(&path);
        let db = legado_db::init_database(&path)?;
        crate::db_state::init_database(db)?;
        // 启动时恢复配置（契约 §2.20.3 / §2.22.5，Task #73）：
        // 读回 customHosts 映射与独立 MCP 端口，尽力而为（失败仅记日志）
        crate::api::net_api::restore_custom_hosts();
        crate::api::server_api::restore_mcp_port();
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

    /// 批量导入书籍（JSON 数组），返回成功导入的数量
    pub fn bookshelf_import(json_array: String) -> Result<i32, BridgeError> {
        Ok(crate::api::bookshelf::import_books(&json_array)?)
    }

    /// 批量持久化书架排序（JSON 数组：[{"bookUrl":"...", "order":1}, ...]）
    pub fn bookshelf_reorder_orders(orders_json: String) -> Result<(), BridgeError> {
        crate::api::bookshelf::reorder_books(&orders_json)?;
        Ok(())
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

    /// 设置书源自定义变量（契约 §2.3 setSourceVariable，台账 §5.11-3，Task #63）
    ///
    /// 对齐原版 `source.setVariable`：单列 UPDATE 语义仅更新 `variable` 单列，
    /// 规避 updateBookSource 全行更新风险；`variable` 为空串表示清除。
    /// 错误码：书源不存在 → Internal；写入失败 → Db。
    /// 书源查询接口（source_list 等）自然带出 variable 字段。
    pub fn set_source_variable(source_url: String, variable: String) -> Result<(), BridgeError> {
        crate::api::source::set_source_variable(&source_url, &variable)?;
        Ok(())
    }

    /// 清除指定 URL 所属二级域名的 Cookie（契约 §2.3 clearCookie，2026-08-12 P1-2）
    ///
    /// 对齐原版 `CookieStore.removeCookie`：持久层 + 共享 HTTP 内存 CookieStore +
    /// JS 宿主 cookie 表。url 为空 → Internal。
    pub fn clear_cookie(url: String) -> Result<(), BridgeError> {
        crate::api::net_api::clear_cookie(&url)?;
        Ok(())
    }

    // ─── cURL ↔ AnalyzeUrl（P1-14，对齐 CurlAnalyzeUrlConverter） ─

    /// 判断文本是否形似 cURL 命令（对齐 Kotlin `CurlAnalyzeUrlConverter.looksLikeCurl`）
    pub fn looks_like_curl(text: String) -> Result<bool, BridgeError> {
        Ok(legado_parser::looks_like_curl(&text))
    }

    /// cURL 命令 → AnalyzeUrl 模板字符串（对齐 `curlToAnalyzeUrl`）
    ///
    /// 失败时 BridgeError.message 含 `[CURL_*]` 前缀，便于 UI 映射提示。
    pub fn curl_to_analyze_url(text: String) -> Result<String, BridgeError> {
        Ok(legado_parser::curl_to_analyze_url(&text)?)
    }

    /// AnalyzeUrl 模板字符串 → cURL 命令（对齐 `analyzeUrlToCurl`）
    pub fn analyze_url_to_curl(text: String) -> Result<String, BridgeError> {
        Ok(legado_parser::analyze_url_to_curl(&text)?)
    }

    // ─── 书源校验（Task #87，加法式新增） ─────────────────────

    /// 校验单个书源（搜索→详情→目录→正文四步 + 验证码/重定向检测）
    ///
    /// 返回 CheckResult JSON：`source_url` / `search_ok` / `toc_ok` /
    /// `content_ok` / `search_error` / `toc_error` / `content_error` /
    /// `total_time_ms` / `captcha` / `redirect`。
    ///
    /// `source_json` — BookSource JSON（字段名对齐 Android 原版 camelCase）
    /// `config_json` — 可选校验配置 JSON（keyword/step_timeout_ms/check_search/
    /// check_toc/check_content/detect_captcha/detect_redirect），空串用默认配置
    pub fn source_check(source_json: String, config_json: String) -> Result<String, BridgeError> {
        let result = crate::api::source_check_api::check_source(&source_json, &config_json)?;
        to_json(&result)
    }

    /// 批量校验书源（串行逐个回推进度，Stream<String>）
    ///
    /// 每完成一个书源即推送一条进度 JSON：`index` / `total` / `is_last` /
    /// `source_name` / `result`（CheckResult）。流在所有书源完成、
    /// 取消或 sink 关闭后自然结束。
    ///
    /// `source_urls_json` — 待校验书源 URL 的 JSON 数组；为空则校验全部书源
    /// `config_json` — 可选校验配置 JSON，空串用默认配置
    /// `sink` — flutter_rust_bridge 流式接收器，Dart 侧表现为 `Stream<String>`
    pub async fn source_check_stream(
        source_urls_json: String,
        config_json: String,
        sink: StreamSink<String>,
    ) -> Result<(), BridgeError> {
        crate::api::source_check_api::run_check_sources_stream(
            source_urls_json,
            config_json,
            |item| sink.add(item).map_err(|e| e.to_string()),
        )
        .await;
        Ok(())
    }

    /// 取消正在进行的批量书源校验
    pub fn source_check_cancel() -> Result<(), BridgeError> {
        crate::api::source_check_api::cancel_check_sources();
        Ok(())
    }

    // ─── 书源调试流（对齐 Debug.Callback，加法式新增） ─────────

    /// 流式调试书源（Stream&lt;String&gt;）
    ///
    /// 对齐 Kotlin `Debug.startDebug` + `Debug.Callback.printLog(state, msg)`。
    /// 每条推送 JSON：`{"state":int,"msg":String}`；`state=-1` 失败、`1000` 完成。
    /// 关键字分流：绝对 URL→详情；`::`→发现；`++`→目录；`--`→正文；否则搜索。
    ///
    /// `source_url` — 已入库书源 URL；`key` — 调试关键字
    pub async fn debug_book_source_stream(
        source_url: String,
        key: String,
        sink: StreamSink<String>,
    ) -> Result<(), BridgeError> {
        crate::api::source_debug_api::run_debug_book_source_stream(source_url, key, move |item| {
            sink.add(item).map_err(|e| e.to_string())
        })
        .await;
        Ok(())
    }

    /// 取消正在进行的书源调试
    pub fn debug_book_source_cancel() -> Result<(), BridgeError> {
        crate::api::source_debug_api::cancel_debug_book_source();
        Ok(())
    }

    // ─── 验证码交互通道（Task #90，加法式新增） ───────────────

    /// 订阅验证码请求事件流（长期存活，Stream<String>）
    ///
    /// 书源 JS 经 `getVerificationCode` 钩子挂起等待时，每个请求推送
    /// 一条事件 JSON：`key` / `source_url` / `source_name` / `image_url` /
    /// `title` / `use_browser`（桌面端恒 false，浏览器模式已降级） /
    /// `created_at_ms`。订阅时先回放当前进行中的请求。
    /// UI 拿到事件后弹验证码对话框，用户输入经 [`verification_submit`]
    /// 回传；关闭对话框调 [`verification_cancel`]。流在 sink 关闭后结束。
    ///
    /// `sink` — flutter_rust_bridge 流式接收器，Dart 侧表现为 `Stream<String>`
    pub async fn verification_request_stream(
        sink: StreamSink<String>,
    ) -> Result<(), BridgeError> {
        crate::api::verification_api::run_verification_request_stream(|event| {
            sink.add(event).map_err(|e| e.to_string())
        })
        .await;
        Ok(())
    }

    /// 提交验证码结果，唤醒 JS 等待方（对齐 Kotlin `setResult`）
    ///
    /// `key` — 请求事件中的 resultKey；`code` — 用户输入的验证码。
    /// 返回是否命中进行中的请求。
    pub fn verification_submit(key: String, code: String) -> Result<bool, BridgeError> {
        Ok(crate::api::verification_api::submit_verification_result(&key, &code))
    }

    /// 取消验证码请求（对齐 Kotlin `checkResult`：UI 关闭对话框未提交）
    ///
    /// 以空结果唤醒等待方（等待侧报「验证结果为空」，对齐 Kotlin 语义）。
    pub fn verification_cancel(key: String) -> Result<bool, BridgeError> {
        Ok(crate::api::verification_api::cancel_verification_request(&key))
    }

    /// 当前进行中的验证码请求列表（JSON 数组，供拉取式消费/调试）
    pub fn verification_pending() -> Result<String, BridgeError> {
        Ok(crate::api::verification_api::pending_requests_json())
    }

    // ─── BackstageWebView DOM 执行通道（SOURCE_DIFF P1，加法式新增） ─

    /// 订阅 WebView DOM 执行请求事件流（长期存活，Stream\<String\>）
    ///
    /// 书源 `@webjs` / 正文 webJs / `java.webView*` 在 Flutter 已订阅时
    /// 经此通道挂起等待真实 WebView 执行。事件 JSON 字段（snake_case）：
    /// `key` / `action` / `html` / `url` / `js` / `source_regex` /
    /// `override_url_regex` / `cache_first` / `delay_time` / `is_rule` /
    /// `result` / `created_at_ms`。订阅时先回放进行中请求。
    /// UI 执行后经 [`webview_submit`] 回传；超时/取消调 [`webview_cancel`]。
    pub async fn webview_request_stream(
        sink: StreamSink<String>,
    ) -> Result<(), BridgeError> {
        crate::api::webview_api::run_webview_request_stream(|event| {
            sink.add(event).map_err(|e| e.to_string())
        })
        .await;
        Ok(())
    }

    /// 提交 WebView 执行结果，唤醒 Rust 等待方
    pub fn webview_submit(key: String, result: String) -> Result<bool, BridgeError> {
        Ok(crate::api::webview_api::submit_webview_result(&key, &result))
    }

    /// 取消 WebView 请求（以空结果唤醒）
    pub fn webview_cancel(key: String) -> Result<bool, BridgeError> {
        Ok(crate::api::webview_api::cancel_webview_request(&key))
    }

    /// 当前进行中的 WebView 请求列表（JSON 数组）
    pub fn webview_pending() -> Result<String, BridgeError> {
        Ok(crate::api::webview_api::pending_requests_json())
    }

    // ─── 登录 UI V2 动态状态协议（#402/#488，加法式新增） ─────────

    /// 判定书源登录 UI 是否为 V2 动态状态协议
    ///
    /// `source_json` — BookSource JSON
    pub fn source_is_login_ui_v2(source_json: String) -> Result<bool, BridgeError> {
        Ok(crate::api::source_login_v2_api::is_login_ui_v2(
            &source_json,
        )?)
    }

    /// 执行 loginUi v2 脚本，返回动态 UI 描述 JSON（`{"rows":[...]}`）
    ///
    /// `source_json` — BookSource JSON；`state_json` — 当前状态 JSON（首次渲染传 `"{}"`）
    pub fn source_login_ui_v2(
        source_json: String,
        state_json: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::source_login_v2_api::eval_login_ui_v2(
            &source_json,
            &state_json,
        )?)
    }

    /// 执行 loginAction v2 动作，返回命令 JSON（state/error/login/close）
    ///
    /// `source_json` — BookSource JSON
    /// `user_input_json` — `{"action":"...","stateJson":"...","formJson":{...}}`
    pub fn source_login_action_v2(
        source_json: String,
        user_input_json: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::source_login_v2_api::eval_login_action_v2(
            &source_json,
            &user_input_json,
        )?)
    }

    /// 执行书源 V1 登录动作（对齐原版 `BaseSource.login()`）
    ///
    /// 书山聚合等 V1 源：loginUrl 为 JS 脚本（定义 login()），loginUi 为表单
    /// JSON；本函数在书源完整上下文（sanitize jsLib + setup + header 规则）
    /// 执行 `loginJs + login.apply({source,cookie,java})`，登录成功后
    /// `source.putLoginHeader(api_key)` 写入的 loginHeader 自动同步落库，
    /// 后续 java.ajax 正文请求携带 X-Api-Key 返回明文。
    ///
    /// `source_json` — BookSource JSON；`action` — 按钮动作（默认 `login`）
    pub fn source_login_v1(
        source_json: String,
        action: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::source_login_v1_api::eval_login_v1(
            &source_json,
            &action,
        )?)
    }

    /// 保存书源登录用户信息（对齐原版 `BaseSource.putLoginInfo` →
    /// CacheManager `userInfo_<key>`；V2 login 命令与手动登录共用）
    ///
    /// `source_url` — 书源 URL；`info_json` — 用户信息 JSON（原样存储）
    pub fn source_put_login_info(source_url: String, info_json: String) -> Result<(), BridgeError> {
        crate::api::source_login_cache::put_login_info(&source_url, &info_json)?;
        Ok(())
    }

    /// 保存书源登录头（对齐原版 `BaseSource.putLoginHeader` →
    /// CacheManager `loginHeader_<key>`，请求路径自动合并）
    ///
    /// `source_url` — 书源 URL；`header_json` — header map JSON（如 `{"Cookie":"..."}`）
    pub fn source_put_login_header(
        source_url: String,
        header_json: String,
    ) -> Result<(), BridgeError> {
        crate::api::source_login_cache::put_login_header(&source_url, &header_json)?;
        Ok(())
    }

    /// 读取书源登录用户信息（`userInfo_<key>`），无则返回空字符串
    pub fn source_get_login_info(source_url: String) -> Result<String, BridgeError> {
        Ok(crate::api::source_login_cache::get_login_info(&source_url).unwrap_or_default())
    }

    /// 读取书源登录头（`loginHeader_<key>`），无则返回空字符串
    pub fn source_get_login_header(source_url: String) -> Result<String, BridgeError> {
        Ok(crate::api::source_login_cache::get_login_header(&source_url).unwrap_or_default())
    }

    // ─── 搜索 ─────────────────────────────────────────────────

    /// 搜索书籍（返回 JSON 数组）
    ///
    /// `keyword` — 搜索关键词
    /// `source_urls_json` — 可选 JSON 数组，指定搜索的书源 URL 列表；为空则搜索所有启用的书源
    ///
    /// 序列化契约：返回原版 `SearchBook` camelCase 结构（name/originName/bookUrl/…），
    /// 与 Dart 侧 `SearchBook.fromJson` 字段一一对应。
    /// 另附加阅读记录标识字段 `hasReadRecord` / `readRecordAuthor`（#424，
    /// 加法式扩展，Dart 侧 jsonDecode 兼容）。
    pub fn search_books(keyword: String, source_urls_json: String) -> Result<String, BridgeError> {
        let results = crate::api::search::search_books(&keyword, &source_urls_json)?;
        let books: Vec<legado_core::models::SearchBook> = results
            .into_iter()
            .map(crate::api::search::result_to_search_book)
            .collect();
        to_json(&books)
    }

    /// 精确搜索（对齐原版 `WebBook.preciseSearchAwait`）
    ///
    /// 返回首个 name+author 完全匹配的 SearchBook JSON；未命中抛 BridgeError。
    /// `source_urls_json` 语义同 `searchBooks`（空=全部启用源）。
    pub fn precise_search(
        name: String,
        author: String,
        source_urls_json: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::search::precise_search(
            &name,
            &author,
            &source_urls_json,
        )?)
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

    /// 搜索书籍封面候选列表（返回 JSON 数组）
    ///
    /// 复用多书源搜索能力：以书名为关键词搜索所有启用的书源，
    /// 从搜索结果中提取封面 URL 作为候选（去重、过滤空值）。
    /// 每项字段：`url` / `width` / `height`（未知尺寸填 0）。
    ///
    /// `book_name` — 书籍名称（搜索关键词）
    pub fn search_cover(book_name: String) -> Result<String, BridgeError> {
        let candidates = crate::api::search::search_cover(&book_name)?;
        to_json(&candidates)
    }

    /// 多源渐进式（流式）搜索
    ///
    /// 与 [`search_multi`] 不同：每完成一个书源即通过 `StreamSink` 推送一个结果批次
    /// （JSON 字符串），UI 侧可逐源渲染，无需等待最慢书源。流在所有书源完成后自然结束。
    ///
    /// `query` — 搜索关键词
    /// `source_urls_json` — 可选 JSON 数组，指定搜索的书源 URL 列表；为空则搜索所有启用的书源
    /// `sink` — flutter_rust_bridge 流式接收器，Dart 侧表现为 `Stream<String>`
    pub async fn search_multi_stream(
        query: String,
        source_urls_json: String,
        sink: StreamSink<String>,
    ) -> Result<(), BridgeError> {
        crate::api::search::run_multi_stream(query, source_urls_json, |batch| {
            sink.add(batch).map_err(|e| e.to_string())
        })
        .await;
        Ok(())
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

    /// 获取章节正文内容（不应用替换规则，用于内容搜索）
    ///
    /// 取正文流程与 [`reader_get_content`] 相同，但净化时关闭替换规则，
    /// 与 Android 书内搜索默认行为（replaceEnabled=false）对齐。
    pub fn reader_get_content_raw(
        book_url: String,
        chapter_index: i32,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::reader::get_chapter_content_raw(
            &book_url,
            chapter_index,
        )?)
    }

    /// 一次调用获取章节正文（合并 reader_get_content + reader_fetch_content）
    ///
    /// 本地书籍直接解析返回；在线书籍自动从网络抓取并返回净化后的正文。
    /// 始终返回纯正文字符串，不返回 JSON 元数据。
    pub fn reader_get_content_full(
        book_url: String,
        chapter_index: i32,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::reader::get_chapter_content_full(
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

    /// 设置阅读器繁简转换类型并持久化（0=不转换 / 1=繁转简 t2s / 2=简转繁 s2t）
    ///
    /// 语义对齐 Kotlin `AppConfig.chineseConverterType`；非法取值归一为 0。
    /// 设置后，正文净化与章节标题显示均按新类型转换。
    pub fn reader_set_chinese_convert(convert_type: i32) -> Result<(), BridgeError> {
        crate::api::reader::set_chinese_convert_type(convert_type);
        Ok(())
    }

    /// 获取当前繁简转换类型（0=不转换 / 1=繁转简 t2s / 2=简转繁 s2t）
    pub fn reader_get_chinese_convert() -> Result<i32, BridgeError> {
        Ok(crate::api::reader::get_chinese_convert_type())
    }

    /// 章级「删除重复标题」开关（Task #51，API_CONTRACT §2.9.10）
    ///
    /// enable=true 恢复全局默认（去除重复标题）；enable=false 该章 opt-out
    /// （保留原始标题）。状态持久化于 DB，重启后保持。
    /// 错误码：书籍不存在 → Internal；章节不存在 → Db。
    pub fn reader_toggle_same_title_removed(
        book_url: String,
        chapter_index: i32,
        enable: bool,
    ) -> Result<(), BridgeError> {
        crate::api::reader::toggle_same_title_removed(&book_url, chapter_index, enable)?;
        Ok(())
    }

    /// 权威查询章级「删除重复标题」开关（caches KV）
    ///
    /// true=去除重复标题（全局默认）；false=该章 opt-out。
    pub fn reader_get_same_title_removed(
        book_url: String,
        chapter_index: i32,
    ) -> Result<bool, BridgeError> {
        Ok(crate::api::reader::get_same_title_removed(
            &book_url,
            chapter_index,
        ))
    }

    /// 试算当前正文是否含可移除的重复标题（对齐原版「未找到可移除的重复标题」）
    pub fn reader_can_remove_same_title(
        chapter_title: String,
        raw_content: String,
    ) -> Result<bool, BridgeError> {
        Ok(crate::api::reader::can_remove_same_title(
            &chapter_title,
            &raw_content,
        ))
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

    // ─── 本地 TXT 全文搜索（Task #98 缺口#4，加法式新增） ─────

    /// 搜索本地 TXT 文件内容（纯文本模式）
    ///
    /// 对齐 C ABI `ffi_txt_search`。返回 JSON 序列化的 `Vec<TxtSearchResult>`，
    /// 每项含 `chapter_index` / `chapter_title` / `char_offset` / `matched_text` /
    /// `context` / `context_match_start` / `context_match_end`。
    pub fn txt_search(
        path: String,
        query: String,
        case_sensitive: bool,
        max_results: i32,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::txt_search_api::txt_search(
            &path,
            &query,
            case_sensitive,
            max_results,
        )?)
    }

    /// 使用正则搜索本地 TXT 文件内容
    ///
    /// 对齐 C ABI `ffi_txt_search_regex`。返回格式同 `txt_search`。
    pub fn txt_search_regex(
        path: String,
        pattern: String,
        case_sensitive: bool,
        max_results: i32,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::txt_search_api::txt_search_regex(
            &path,
            &pattern,
            case_sensitive,
            max_results,
        )?)
    }

    /// 在本地 TXT 文件指定章节内搜索
    ///
    /// 对齐 C ABI `ffi_txt_search_in_chapter`。返回格式同 `txt_search`。
    pub fn txt_search_in_chapter(
        path: String,
        query: String,
        chapter_index: i32,
        case_sensitive: bool,
        max_results: i32,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::txt_search_api::txt_search_in_chapter(
            &path,
            &query,
            chapter_index,
            case_sensitive,
            max_results,
        )?)
    }

    /// 统计本地 TXT 文件内关键词匹配总数（不返回完整结果，供 UI 显示计数）
    ///
    /// 对齐 C ABI `ffi_txt_search_count`。
    pub fn txt_search_count(path: String, query: String, case_sensitive: bool) -> Result<i32, BridgeError> {
        Ok(crate::api::txt_search_api::txt_search_count(
            &path,
            &query,
            case_sensitive,
        )?)
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

    /// 原子更新 RSS 源（按 sourceUrl 主键单条 UPDATE，不删后重插），返回源信息（JSON）
    ///
    /// 缺口④ rssUpdateSource 原子更新（Task #108，加法式）：
    /// 对齐 C ABI `ffi_rss_update_source`。
    pub fn rss_update_source(source_json: String) -> Result<String, BridgeError> {
        let source = crate::api::rss::update_rss_source(&source_json)?;
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

    /// 清空指定 RSS 源的本地文章缓存（对齐 clearArticles）
    pub fn rss_clear_articles(source_url: String) -> Result<(), BridgeError> {
        crate::api::rss::clear_rss_articles(&source_url)?;
        Ok(())
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

    // ─── RSS 已读记录 ────────────────────────────────

    /// 标记 RSS 文章为已读
    pub fn rss_mark_read(
        origin: String,
        title: String,
        link: Option<String>,
    ) -> Result<(), BridgeError> {
        crate::api::rss_read_record_api::mark_read(&origin, &title, link.as_deref())?;
        Ok(())
    }

    /// 判断 RSS 文章是否已读（按 link）
    pub fn rss_is_read(link: String) -> Result<bool, BridgeError> {
        let read = crate::api::rss_read_record_api::is_read(&link)?;
        Ok(read)
    }

    /// 判断 RSS 文章是否已读（按 origin + title）
    pub fn rss_is_read_by_title(origin: String, title: String) -> Result<bool, BridgeError> {
        let read = crate::api::rss_read_record_api::is_read_by_title(&origin, &title)?;
        Ok(read)
    }

    /// 清空所有 RSS 已读记录
    pub fn rss_clear_read_records() -> Result<(), BridgeError> {
        crate::api::rss_read_record_api::clear_all()?;
        Ok(())
    }

    /// 获取 RSS 已读记录总数
    pub fn rss_read_record_count() -> Result<i64, BridgeError> {
        let count = crate::api::rss_read_record_api::count()?;
        Ok(count)
    }

    /// 获取 RSS 已读记录列表（JSON 数组，按 readTime 降序）
    pub fn rss_list_read_records(limit: Option<i32>) -> Result<String, BridgeError> {
        let records = crate::api::rss_read_record_api::list_records(limit)?;
        to_json(&records)
    }

    /// 按 RSS 源 origin 获取已读记录（JSON 数组，对齐原版 getRecordsByOrigin）
    pub fn rss_list_read_records_by_origin(
        origin: String,
        limit: Option<i32>,
    ) -> Result<String, BridgeError> {
        let records =
            crate::api::rss_read_record_api::list_records_by_origin(&origin, limit)?;
        to_json(&records)
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

    /// 按前缀搜索历史关键词（JSON 数组）
    pub fn search_history_by_prefix(prefix: String, limit: i32) -> Result<String, BridgeError> {
        let results = crate::api::search_history_api::search_history_by_prefix(&prefix, limit)?;
        to_json(&results)
    }

    // ─── 词典 ───────────────────────────────────────────────

    /// 词典查询（本地内置词典，JSON 对象）
    ///
    /// 返回结构化释义 DictEntry：`word`（归一化单词）/ `phonetic`（音标）/
    /// `definitions`（释义列表）。未收录词返回空 `definitions`（非异常）。
    pub fn dict_lookup(word: String) -> Result<String, BridgeError> {
        let entry = crate::api::dict_api::dict_lookup(&word)?;
        to_json(&entry)
    }

    // ─── 换源 ───────────────────────────────────────────────

    /// 搜索可替换的书源（返回 JSON 格式的匹配结果列表）
    ///
    /// `book_name` — 当前书籍名称
    /// `author` — 当前作者
    /// `source_urls_json` — 可选 JSON 数组，指定搜索的书源 URL 列表；
    /// 空串/空数组=搜全部启用源（留项#12/Task #131，加法式新增）
    pub fn source_switch_search(
        book_name: String,
        author: String,
        source_urls_json: String,
        options_json: String,
    ) -> Result<String, BridgeError> {
        let resp = crate::api::source_switch::search_alternative_sources(
            &book_name,
            &author,
            &source_urls_json,
            &options_json,
        )?;
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
            let client = crate::http_state::shared_client()?;
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
            let client = crate::http_state::shared_client()?;
            client.post(&url, &body, None).await
        })?;
        Ok(serde_json::to_string(&serde_json::json!({
            "status": response.status,
            "body": response.body,
            "url": response.url,
        }))?)
    }

    /// HTTP GET 二进制响应（返回 JSON：status/bodyBase64/url）
    pub fn http_get_bytes(url: String, headers_json: String) -> Result<String, BridgeError> {
        Ok(crate::api::net_api::http_get_bytes(&url, &headers_json)?)
    }

    /// 图片下载 + imageDecode 解码（返回 JSON：{ base64, len }）
    ///
    /// 对齐原版 ImageUtils.decodeImageStream：漫画/图片站图片 bytes 经
    /// 书源 imageDecode JS（配合 jsLib）解密后才可显示；无 imageDecode
    /// 规则时返回原始图片 base64。`source_json` 为书源 JSON（单对象）。
    /// 防盗链 header 取书源 header + 兜底 Referer。— Reasonix
    pub fn fetch_image_with_decode(
        url: String,
        source_json: String,
    ) -> Result<String, BridgeError> {
        let result = crate::api::image_api::fetch_image_with_decode(&url, &source_json)?;
        Ok(result)
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
    pub fn webbook_chapters(
        source_json: String,
        book_url: String,
        toc_url: String,
        book_name: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::web_book::webbook_chapters(
            &source_json,
            &book_url,
            &toc_url,
            &book_name,
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

    // ─── 发现页 ───────────────────────────────────────────────

    /// 解析 exploreUrl 为分类列表（返回 JSON 数组）
    ///
    /// `explore_url` — 书源的 exploreUrl 字段
    pub fn explore_parse_url(
        explore_url: String,
        source_json: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::explore_api::explore_parse_url(
            &explore_url,
            &source_json,
        )?)
    }

    /// 抓取发现分类的书籍列表（返回 WebSearchResult JSON 数组）
    ///
    /// `source_json` — BookSource JSON 字符串
    /// `url` — 分类 URL
    /// `page` — 页码（从 1 开始）
    pub fn explore_fetch_books(
        source_json: String,
        url: String,
        page: i32,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::explore_api::explore_fetch_books(
            &source_json,
            &url,
            page,
        )?)
    }

    /// 写入发现 infoMap 键值（toggle/select 控件）
    pub fn explore_info_map_put(
        source_url: String,
        key: String,
        value: String,
    ) -> Result<(), BridgeError> {
        crate::api::explore_api::explore_info_map_put(&source_url, &key, &value)?;
        Ok(())
    }

    /// 初始化发现 infoMap 默认值
    pub fn explore_info_map_ensure_default(
        source_url: String,
        key: String,
        default_value: String,
    ) -> Result<(), BridgeError> {
        crate::api::explore_api::explore_info_map_ensure_default(
            &source_url,
            &key,
            &default_value,
        )?;
        Ok(())
    }

    /// 读取发现 infoMap 快照（JSON 对象字符串；供 UI 回显 toggle/select/text
    /// 已存值，对齐原版 InfoMap 持久化语义）— 发现页修复 B①
    pub fn explore_info_map_snapshot(source_url: String) -> Result<String, BridgeError> {
        let map = crate::api::explore_info_map::snapshot(&source_url)?;
        Ok(serde_json::to_string(&map).map_err(BridgeError::from)?)
    }

    /// 执行发现页控件 action JS（返回 ExploreEvalActionResult JSON）
    pub fn explore_eval_action(
        source_json: String,
        action_js: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::explore_api::explore_eval_action(
            &source_json,
            &action_js,
        )?)
    }

    /// 执行发现页 viewName 动态标题 JS
    pub fn explore_eval_ui_js(
        source_json: String,
        js_str: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::explore_api::explore_eval_ui_js(
            &source_json,
            &js_str,
        )?)
    }

    // ─── 规则解析 ─────────────────────────────────────────────

    /// 使用规则解析内容，返回 JSON 格式的结果
    pub fn parse_rule(
        content: String,
        rule: String,
        rule_type: String,
    ) -> Result<String, BridgeError> {
        let effective_rule = if rule.starts_with('@') || rule.starts_with('<') {
            rule
        } else if !rule_type.trim().is_empty() {
            format!("@{}:{}", rule_type.trim(), rule)
        } else {
            rule
        };
        let analyzer = legado_parser::AnalyzeRule::new(content, String::new());
        let results = analyzer.get_strings(&effective_rule)?;
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
        let engine = QuickJsEngine::new(SandboxConfig::default()).map_err(|e| BridgeError {
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

    /// 按书名+作者获取某本书的所有书签（裸 JSON 数组，契约 §2.7
    /// getBookmarksByBook，台账 §5.14-2，Task #63 加法式新增）
    ///
    /// 对齐原版 `bookmarkDao.getByBook(name, author)`，规避同名书混入；
    /// 既有 bookmark_get_all（仅按书名）签名保持不变。
    pub fn get_bookmarks_by_book(
        book_name: String,
        book_author: String,
    ) -> Result<String, BridgeError> {
        let bookmarks = crate::api::bookmark_api::get_bookmarks_by_book(&book_name, &book_author)?;
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

    /// 清除指定书籍的章节缓存，返回删除行数
    pub fn cache_clear_book(book_url: String) -> Result<i32, BridgeError> {
        Ok(crate::api::cache_api::clear_book_cache(&book_url)?)
    }

    /// 获取章节缓存内容
    pub fn cache_get_chapter(book_url: String, chapter_index: i32) -> Result<String, BridgeError> {
        let content = crate::api::cache_api::get_chapter_cache(&book_url, chapter_index)?;
        Ok(content)
    }

    /// 列出某本书已缓存章节的 chapter_url 集合（Task #22，目录页云图标）
    ///
    /// 返回 JSON 字符串数组（`["url1","url2",...]`），供 Flutter 目录页解析为
    /// 已缓存 chapter_url 集合，据此为每章渲染「已缓存实心 / 未缓存空心云」图标。
    pub fn cache_list_cached_chapter_urls(book_url: String) -> Result<String, BridgeError> {
        let urls = crate::api::cache_api::list_cached_chapter_urls(&book_url)?;
        to_json(&urls)
    }

    /// 获取缓存书籍数量
    pub fn cache_get_book_count() -> Result<i32, BridgeError> {
        let count = crate::api::cache_api::get_cache_book_count()?;
        Ok(count)
    }

    /// 获取缓存章节数量
    pub fn cache_get_chapter_count() -> Result<i32, BridgeError> {
        let count = crate::api::cache_api::get_cache_chapter_count()?;
        Ok(count)
    }

    /// 清除指定时间之前的缓存
    pub fn cache_clear_before(before_timestamp_ms: i64) -> Result<bool, BridgeError> {
        crate::api::cache_api::clear_cache_before(before_timestamp_ms)?;
        Ok(true)
    }

    /// 执行 SQLite VACUUM 压缩数据库，返回释放的字节数（Task #51，API_CONTRACT §2.16.6）
    ///
    /// 失败（数据库锁/文件损坏）或数据库未初始化时降级返回 0，不抛异常。
    pub fn cache_shrink_database() -> Result<i64, BridgeError> {
        Ok(crate::api::cache_api::shrink_database())
    }

    /// 写入/覆盖单章缓存（Task #136 R5，API_CONTRACT §2.43.1）
    ///
    /// `title` / `chapter_url` 为空串时从 DB 章节表回填；
    /// 复用 CacheBookRepository.insert（INSERT OR REPLACE）。
    pub fn save_chapter_content(
        book_url: String,
        chapter_index: i32,
        title: String,
        content: String,
        chapter_url: String,
    ) -> Result<bool, BridgeError> {
        let ok = crate::api::cache_api::save_chapter_content(
            &book_url,
            chapter_index,
            &title,
            &content,
            &chapter_url,
        )?;
        Ok(ok)
    }

    // ─── 批量缓存下载（Task #136 R7，API_CONTRACT §2.43.3）─────

    /// 创建批量缓存下载任务，返回任务 ID（字符串）
    ///
    /// `start_chapter` / `end_chapter` 含端点；负值按 0、超出按末章截断。
    /// 对标 Kotlin CacheActivity：复用正文抓取链路 + 任务表/取消令牌。
    /// 同一本书已有进行中任务时复用返回既有 ID（契约 §2.43.3）。
    pub fn cache_download_start(
        book_url: String,
        start_chapter: i32,
        end_chapter: i32,
    ) -> Result<String, BridgeError> {
        let task_id =
            crate::api::cache_download_api::cache_download_start(
                &book_url,
                start_chapter,
                end_chapter,
            )?;
        Ok(task_id.to_string())
    }

    /// 查询批量下载任务进度（JSON：taskId/bookUrl/status/total/completed/failed；
    /// 未知任务 status=notFound）
    pub fn cache_download_progress(task_id: i64) -> Result<String, BridgeError> {
        let task = crate::api::cache_download_api::cache_download_progress(task_id as u64)?;
        to_json(&task)
    }

    /// 取消批量下载任务（对照书源校验流取消机制）；未知任务返回 false
    pub fn cache_download_cancel(task_id: i64) -> Result<bool, BridgeError> {
        let ok = crate::api::cache_download_api::cache_download_cancel(task_id as u64)?;
        Ok(ok)
    }

    /// 列出所有批量下载任务（JSON 数组，按任务 ID 升序）
    pub fn cache_download_list() -> Result<String, BridgeError> {
        let tasks = crate::api::cache_download_api::cache_download_list()?;
        to_json(&tasks)
    }

    // ─── 章节购买动作（Task #136 R6，API_CONTRACT §2.43.2）─────

    /// 执行章节购买动作（对照 Kotlin ReadBookActivity.payAction）
    ///
    /// 返回 JSON：`{"kind": "url"/"success"/"none", "value": "<JS 返回原文>"}`；
    /// kind=url 时 UI 打开支付页，kind=success 时已清当前章正文缓存。
    /// 需 quickjs 构建（非 quickjs 返回错误）。
    pub fn chapter_pay_action(book_url: String, chapter_index: i32) -> Result<String, BridgeError> {
        let result =
            crate::api::pay_action_api::chapter_pay_action(&book_url, chapter_index)?;
        to_json(&result)
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

    // ─── TTS 真实合成管线（Task #113 缺口②，API_CONTRACT §2.42）─────

    /// TTS 真实合成：url 模板替换（speakText/speakSpeed）→ HTTP 拉取音频 → 本地缓存
    ///
    /// 返回合成结果 JSON（camelCase）：
    /// `{"audioPath": "...", "fromCache": false, "contentType": "audio/mpeg"}`
    /// 缓存命中时不发起网络请求。
    pub fn tts_speak(text: String, engine_url: String, speed: f64) -> Result<String, BridgeError> {
        let dto = crate::api::tts_speak_api::tts_speak(&text, &engine_url, speed)?;
        to_json(&dto)
    }

    /// 设置 TTS 音频缓存目录（全局生效）
    pub fn tts_set_cache_dir(path: String) -> Result<bool, BridgeError> {
        let ok = crate::api::tts_speak_api::set_tts_cache_dir(&path)?;
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

    /// 音频章节取址（契约 §2.26 getAudioChapterMedia）
    ///
    /// 对齐原版 `AudioPlay` → `WebBook.getContent`：返回可播 `mediaUrl` 等元数据 JSON。
    pub fn audio_get_chapter_media(
        book_url: String,
        chapter_index: i32,
    ) -> Result<String, BridgeError> {
        let dto = crate::api::audio_api::get_audio_chapter_media(&book_url, chapter_index)?;
        to_json(&dto)
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

    /// 导入旧版（阅读 2.x）备份目录，返回统计 JSON
    pub fn import_old_data(dir: String) -> Result<String, BridgeError> {
        let result = crate::api::backup_api::import_old_data(&dir)?;
        Ok(result)
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

    /// 设置独立 MCP 服务端口（契约 §2.22.5，Task #72/#73）
    ///
    /// - port>0：启动/重启独立 MCP 服务监听该端口（合法区间 1024..65530，
    ///   越界或占用报 Internal）；port≤0：停止独立服务；
    /// - Web 端口的 /mcp/* 挂载不受影响（兼容并存）；端口持久化并启动时恢复。
    pub fn set_mcp_port(port: i32) -> Result<(), BridgeError> {
        crate::api::server_api::set_mcp_port(port)?;
        Ok(())
    }

    /// 设置自定义 hosts 映射（契约 §2.20.3，Task #72/#73）
    ///
    /// hostsJson 为 JSON 对象 `域名 → 单 IP 字符串或 IP 数组`（对齐原版
    /// AppConfig.hostMap）；空串/空对象 = 清除映射恢复系统 DNS。
    /// 应用后网络层 DNS 即时生效，并持久化到 `config:customHosts`。
    pub fn set_custom_hosts(hosts_json: String) -> Result<(), BridgeError> {
        crate::api::net_api::set_custom_hosts(&hosts_json)?;
        Ok(())
    }

    /// 按书名执行启用封面规则搜封面（契约 §2.4.8，Task #72/#73）
    ///
    /// 返回候选封面 URL 裸 JSON Array（§1.4 铁律）；无启用规则或
    /// 全部失败返回 `[]`（非异常）。
    pub fn search_cover_rules(name: String) -> Result<String, BridgeError> {
        let json = crate::api::cover_api::search_cover_rules(&name)?;
        Ok(json)
    }

    /// 读取封面规则配置（契约 §2.4 F4，对齐 BookCover.getCoverRule）
    pub fn get_cover_rule() -> Result<String, BridgeError> {
        let json = crate::api::cover_api::get_cover_rule()?;
        Ok(json)
    }

    /// 保存封面规则配置（契约 §2.4 F4，对齐 BookCover.saveCoverRule）
    pub fn save_cover_rule(rule_json: String) -> Result<bool, BridgeError> {
        let ok = crate::api::cover_api::save_cover_rule(&rule_json)?;
        Ok(ok)
    }

    /// 删除封面规则配置（契约 §2.4 F4，对齐 BookCover.delCoverRule）
    pub fn delete_cover_rule() -> Result<bool, BridgeError> {
        let ok = crate::api::cover_api::delete_cover_rule()?;
        Ok(ok)
    }

    // ─── WebDAV 云同步 ─────────────────────────────────────

    /// 列出 WebDAV 远程目录（JSON 数组）
    pub fn webdav_list_dir(config_json: String, path: String) -> Result<String, BridgeError> {
        Ok(crate::api::webdav_api::webdav_list_dir(
            &config_json,
            &path,
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

    /// 从本地文件路径读取并上传到 WebDAV（Task #51，API_CONTRACT §2.28.6）
    ///
    /// 大文件场景（如书籍上传至远程），区别于 webdav_upload 的 String data 直传。
    /// 错误码：文件不存在/读取失败 → Io；上传失败 → Net；配置解析失败 → Internal。
    pub fn webdav_upload_file(
        config_json: String,
        path: String,
        local_file_path: String,
    ) -> Result<(), BridgeError> {
        crate::api::webdav_api::webdav_upload_file(&config_json, &path, &local_file_path)?;
        Ok(())
    }

    /// 从 WebDAV 下载文件
    pub fn webdav_download(config_json: String, path: String) -> Result<String, BridgeError> {
        Ok(crate::api::webdav_api::webdav_download(
            &config_json,
            &path,
        )?)
    }

    /// 从 WebDAV 下载二进制到本地文件（API_CONTRACT §2.28，2026-08-12 P1-5）
    ///
    /// 错误码：配置解析失败 → Internal；下载失败 → Net；写盘失败 → Io。
    pub fn webdav_download_file(
        config_json: String,
        path: String,
        local_file_path: String,
    ) -> Result<(), BridgeError> {
        crate::api::webdav_api::webdav_download_file(&config_json, &path, &local_file_path)?;
        Ok(())
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

    // ─── 段评（书源 ruleReview，对齐原版）────────────────

    /// 段评摘要（P2-9，对标 loadReviewSummary + parseSummary）
    ///
    /// 返回 JSON `{"counts":{"1":5},"keys":{"1":"paraData"}}`。
    /// `request_json` 支持 chapterUrl；可选 book/chapter。
    pub fn review_get_summary(
        source_json: String,
        request_json: String,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::review_api::review_get_summary(
            &source_json,
            &request_json,
        )?)
    }

    /// 段评详情分页（P2-9，对标 ReviewDetailDialog + parseDetailPage）
    ///
    /// 返回 JSON `{"items":[...],"nextPageUrl":String?,"hasReplyUrl":bool}`。
    /// `request_json` 支持 paraIndex/paraData/chapterUrl/detailUrl。
    pub fn review_get_detail(
        source_json: String,
        request_json: String,
        page: i32,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::review_api::review_get_detail(
            &source_json,
            &request_json,
            page,
        )?)
    }

    /// 按需加载段评回复（上游 #519）
    ///
    /// 返回 JSON 对象字符串 `{"items": [回复列表], "nextPageUrl": String?}`。
    /// `request_json` 支持字段：reviewId/paraIndex/paraData/chapterUrl/replyUrl。
    pub fn review_get_replies(
        source_json: String,
        request_json: String,
        page: i32,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::review_api::review_get_replies(
            &source_json,
            &request_json,
            page,
        )?)
    }

    // ─── 书籍导出 ─────────────────────────────────────

    /// 导出书籍（返回 ExportResult JSON）
    ///
    /// # 参数
    /// - `book_url`: 书籍 URL
    /// - `format`: 导出格式（txt/epub/html/pdf）
    /// - `include_toc`: 是否包含目录
    pub fn book_export(
        book_url: String,
        format: String,
        include_toc: bool,
    ) -> Result<String, BridgeError> {
        let result = crate::api::book_export::export_book(&book_url, &format, include_toc)?;
        to_json(&result)
    }

    /// 获取导出预览信息（返回 ExportResult JSON）
    pub fn book_export_info(book_url: String, format: String) -> Result<String, BridgeError> {
        let result = crate::api::book_export::export_info(&book_url, &format)?;
        to_json(&result)
    }

    /// 带选项导出书籍（Task #136 R8，API_CONTRACT §2.43.4）
    ///
    /// `options_json` 透传：encoding（仅 TXT）/ startChapter / endChapter（-1=不限）/
    /// fileNameTemplate（{name}/{author} 占位符）；空串 = 全缺省（行为等同 book_export）。
    pub fn book_export_with_options(
        book_url: String,
        format: String,
        include_toc: bool,
        options_json: String,
    ) -> Result<String, BridgeError> {
        let result = crate::api::book_export::export_book_with_options(
            &book_url,
            &format,
            include_toc,
            &options_json,
        )?;
        to_json(&result)
    }

    // ─── 压缩包导入与编码检测 ─────────────────────────

    /// 导入 ZIP 压缩包中的书籍文件（返回 ArchiveImportResult JSON）
    pub fn archive_import_zip(zip_path: String, output_dir: String) -> Result<String, BridgeError> {
        let result = crate::api::archive_import_api::import_zip_file(&zip_path, &output_dir);
        to_json(&result)
    }

    /// 导入 RAR 压缩包中的书籍文件（支持加密，返回 ArchiveImportResult JSON）
    pub fn archive_import_rar(
        rar_path: String,
        output_dir: String,
        password: Option<String>,
    ) -> Result<String, BridgeError> {
        let result =
            crate::api::archive_import_api::import_rar_file(&rar_path, &output_dir, password);
        to_json(&result)
    }

    /// 列出 ZIP 压缩包中的书籍文件名（不解压，返回 JSON 数组）
    pub fn archive_list_zip_files(zip_path: String) -> Result<String, BridgeError> {
        let files = crate::api::archive_import_api::list_zip_book_files(&zip_path)?;
        to_json(&files)
    }

    /// 列出 RAR 压缩包中的书籍文件名（不解压，返回 JSON 数组）
    pub fn archive_list_rar_files(
        rar_path: String,
        password: Option<String>,
    ) -> Result<String, BridgeError> {
        let files = crate::api::archive_import_api::list_rar_book_files(&rar_path, password)?;
        to_json(&files)
    }

    /// 检测 TXT 文件编码（返回 EncodingResult JSON）
    pub fn archive_detect_encoding(file_path: String) -> Result<String, BridgeError> {
        let result = crate::api::archive_import_api::detect_txt_encoding(&file_path)?;
        to_json(&result)
    }

    /// 转换 TXT 文件编码（返回 ConvertResult JSON）
    pub fn archive_convert_encoding(
        file_path: String,
        from_encoding: String,
        to_encoding: String,
    ) -> Result<String, BridgeError> {
        let result = crate::api::archive_import_api::convert_txt_encoding(
            &file_path,
            &from_encoding,
            &to_encoding,
        );
        to_json(&result)
    }

    /// 判断文件是否为压缩包格式
    pub fn archive_is_archive(file_path: String) -> bool {
        crate::api::archive_import_api::is_archive_file(&file_path)
    }

    // ─── 自动任务 ─────────────────────────────────────

    /// 构建书籍更新定时任务（返回 AutoTaskRule JSON）
    pub fn auto_task_build_book_update(
        book_url: String,
        book_name: String,
        book_author: String,
        name: String,
    ) -> Result<String, BridgeError> {
        let task = crate::api::auto_task_api::build_book_update_task(
            &book_url,
            &book_name,
            &book_author,
            &name,
        );
        to_json(&task)
    }

    /// 批量更新 cron 表达式（rules_json 为 AutoTaskRule 数组，ids_json 为 ID 数组，返回更新后的规则数组 JSON）
    pub fn auto_task_update_cron_batch(
        rules_json: String,
        ids_json: String,
        cron: String,
    ) -> Result<String, BridgeError> {
        let rules = crate::api::auto_task_api::update_cron_batch(&rules_json, &ids_json, &cron)?;
        to_json(&rules)
    }

    /// 准备导入任务（合并本地运行时状态，返回合并后的任务数组 JSON）
    pub fn auto_task_prepare_imported(
        local_tasks_json: String,
        imported_json: String,
    ) -> Result<String, BridgeError> {
        let merged =
            crate::api::auto_task_api::prepare_imported_tasks(&local_tasks_json, &imported_json)?;
        to_json(&merged)
    }

    /// 执行任务协议（protocol_json 为 TaskProtocol，返回 TaskResult JSON）
    pub fn auto_task_execute(protocol_json: String) -> Result<String, BridgeError> {
        let result = crate::api::auto_task_api::execute_task(&protocol_json, None)?;
        to_json(&result)
    }

    /// 带 ID 执行任务协议（返回 TaskResult JSON）
    pub fn auto_task_execute_with_id(
        protocol_json: String,
        task_id: String,
    ) -> Result<String, BridgeError> {
        let result = crate::api::auto_task_api::execute_task(&protocol_json, Some(&task_id))?;
        to_json(&result)
    }

    /// 规范化脚本（去除 @js: 前缀或 <js></js> 包裹）
    pub fn auto_task_normalize_script(script: String) -> String {
        crate::api::auto_task_api::normalize_script(&script)
    }

    /// 判断书籍是否允许刷新目录
    pub fn auto_task_can_refresh_toc(can_update: bool, respect_can_update: bool) -> bool {
        crate::api::auto_task_api::can_refresh_book_toc(can_update, respect_can_update)
    }

    /// 查找书籍更新任务（tasks_json 为 AutoTaskRule 数组，返回匹配任务 JSON 或 null）
    pub fn auto_task_find_book_update(
        tasks_json: String,
        book_url: String,
        book_name: String,
        book_author: String,
    ) -> Result<String, BridgeError> {
        let found = crate::api::auto_task_api::find_book_update_task(
            &tasks_json,
            &book_url,
            &book_name,
            &book_author,
        )?;
        to_json(&found)
    }

    /// 解析 cron 表达式计算下次执行时间（Unix 毫秒，无法解析返回 -1）
    pub fn auto_task_next_due_at(cron: String, from_ms: i64) -> i64 {
        crate::api::auto_task_api::next_due_at(&cron, from_ms)
    }

    // ─── 自动任务数据库 CRUD ───────────────────────

    /// 列出所有自动任务规则（按 customOrder 排序，返回 AutoTaskRule 数组 JSON）
    pub fn auto_task_list_rules() -> Result<String, BridgeError> {
        let rules = crate::api::auto_task_api::list_rules_db()?;
        to_json(&rules)
    }

    /// 创建自动任务规则（rule_json 为 AutoTaskRule JSON，返回任务 ID）
    pub fn auto_task_create_rule(rule_json: String) -> Result<String, BridgeError> {
        let rule: legado_core::models::AutoTaskRule = serde_json::from_str(&rule_json)?;
        let id = crate::api::auto_task_api::create_rule_db(&rule)?;
        Ok(id)
    }

    /// 更新自动任务规则（rule_json 为 AutoTaskRule JSON）
    pub fn auto_task_update_rule(rule_json: String) -> Result<(), BridgeError> {
        let rule: legado_core::models::AutoTaskRule = serde_json::from_str(&rule_json)?;
        crate::api::auto_task_api::update_rule_db(&rule)?;
        Ok(())
    }

    /// 删除自动任务规则（按 ID 删除）
    pub fn auto_task_delete_rule(id: String) -> Result<(), BridgeError> {
        crate::api::auto_task_api::delete_rule_db(&id)?;
        Ok(())
    }

    /// 根据 ID 查询自动任务规则（返回 AutoTaskRule JSON 或 null）
    pub fn auto_task_find_rule_by_id(id: String) -> Result<String, BridgeError> {
        let rule = crate::api::auto_task_api::find_rule_by_id_db(&id)?;
        to_json(&rule)
    }

    // ─── 高亮体系（Task #69，加法式新增）────────────────

    /// 新增/更新高亮记录（BookHighlight JSON，time=0 时自动分配），返回 time
    pub fn highlight_add(highlight_json: String) -> Result<i64, BridgeError> {
        Ok(crate::api::highlight_api::highlight_add(&highlight_json)?)
    }

    /// 按主键 time 删除高亮记录，返回是否实际删除
    pub fn highlight_delete(time: i64) -> Result<bool, BridgeError> {
        Ok(crate::api::highlight_api::highlight_delete(time)?)
    }

    /// 按书籍删除全部高亮记录，返回删除数量
    pub fn highlight_delete_by_book(book_url: String) -> Result<i64, BridgeError> {
        Ok(crate::api::highlight_api::highlight_delete_by_book(
            &book_url,
        )?)
    }

    /// 按书籍获取高亮列表（BookHighlight 数组 JSON）
    pub fn highlight_list_by_book(book_url: String) -> Result<String, BridgeError> {
        let list = crate::api::highlight_api::highlight_list_by_book(&book_url)?;
        to_json(&list)
    }

    /// 按书籍 + 章节索引获取高亮列表（BookHighlight 数组 JSON）
    pub fn highlight_list_by_chapter(
        book_url: String,
        chapter_index: i32,
    ) -> Result<String, BridgeError> {
        let list = crate::api::highlight_api::highlight_list_by_chapter(&book_url, chapter_index)?;
        to_json(&list)
    }

    /// 全局关键词搜索高亮（BookHighlight 数组 JSON）
    pub fn highlight_search(keyword: String) -> Result<String, BridgeError> {
        let list = crate::api::highlight_api::highlight_search(&keyword)?;
        to_json(&list)
    }

    /// 获取所有高亮记录（BookHighlight 数组 JSON）
    pub fn highlight_list_all() -> Result<String, BridgeError> {
        let list = crate::api::highlight_api::highlight_list_all()?;
        to_json(&list)
    }

    /// 获取所有高亮规则（HighlightRule 数组 JSON，按 sortOrder 升序）
    pub fn highlight_rule_list() -> Result<String, BridgeError> {
        let rules = crate::api::highlight_api::highlight_rule_list()?;
        to_json(&rules)
    }

    /// 保存高亮规则（HighlightRule JSON，id=0 时自增新增），返回规则 ID
    pub fn highlight_rule_save(rule_json: String) -> Result<i64, BridgeError> {
        Ok(crate::api::highlight_api::highlight_rule_save(&rule_json)?)
    }

    /// 按 ID 删除高亮规则，返回是否实际删除
    pub fn highlight_rule_delete(id: i64) -> Result<bool, BridgeError> {
        Ok(crate::api::highlight_api::highlight_rule_delete(id)?)
    }

    /// 按书籍查找启用的高亮规则（HighlightRule 数组 JSON）
    pub fn highlight_rule_find_enabled(
        book_name: String,
        origin: String,
    ) -> Result<String, BridgeError> {
        let rules = crate::api::highlight_api::highlight_rule_find_enabled(&book_name, &origin)?;
        to_json(&rules)
    }

    // ─── 听书播放（播放模式/书籍解析）───────────────────

    /// 将播放模式写入 readConfig JSON（返回更新后的 JSON）
    pub fn audio_with_play_mode(read_config: Option<String>, play_mode: i32) -> String {
        crate::api::audio_api::with_audio_play_mode(read_config.as_deref(), play_mode)
    }

    /// 解析听书书籍（返回 Book JSON 或 null）
    ///
    /// 请求 URL 为空时返回缓存书籍；缓存匹配时直接返回；否则按 URL 查库。
    pub fn audio_resolve_play_book(
        requested_book_url: Option<String>,
        cached_book_json: Option<String>,
    ) -> Result<String, BridgeError> {
        let book = crate::api::audio_api::resolve_audio_play_book(
            requested_book_url.as_deref(),
            cached_book_json.as_deref(),
        )?;
        to_json(&book)
    }

    /// 书源 callBackBtn（对齐 SourceCallBack.callBackBtn + 中途 UI 队列）
    ///
    /// 返回 JSON：`{invoked, jsTrue, raw, actions:[...]}`。
    /// `actions` 供 Flutter PlatformBridge 回放（refreshBookInfo / openBrowser 等）。
    pub fn source_call_back_btn(
        event: String,
        book_url: String,
        chapter_index: Option<i32>,
        result: Option<String>,
        book_type: i32,
    ) -> Result<String, BridgeError> {
        let dto = crate::api::source_callback_api::source_call_back_btn(
            &event,
            &book_url,
            chapter_index,
            result.as_deref(),
            book_type,
        )?;
        to_json(&dto)
    }

    // ─── JS 单文件书源配置（JsSourceConfig 对齐）────────────────

    /// 提取 JS 单文件书源配置（返回 BookSource JSON）
    ///
    /// `content` — 完整 JS 书源脚本文本；需 quickjs 构建，否则返回错误
    pub fn js_source_extract(content: String) -> Result<String, BridgeError> {
        Ok(crate::api::js_source_config_api::js_source_extract(
            &content,
        )?)
    }

    /// JS 语法检查（#479，返回 SyntaxCheckResult JSON：valid/message/line）
    ///
    /// `content` — 待检查的 JS 脚本文本；quickjs 构建下只编译不执行，
    /// 非 quickjs 构建降级为括号平衡基础检查
    pub fn js_source_syntax_check(content: String) -> Result<String, BridgeError> {
        Ok(crate::api::js_source_config_api::js_source_syntax_check(
            &content,
        )?)
    }

    /// 写回顶层配置对象的 lastUpdateTime（#208/#515，返回替换后脚本文本）
    ///
    /// `content` — JS 书源脚本文本；`stamp` — 新时间戳（毫秒）。
    /// 找不到可替换位置时返回空字符串
    pub fn js_source_stamp_last_update_time(
        content: String,
        stamp: i64,
    ) -> Result<String, BridgeError> {
        Ok(crate::api::js_source_config_api::js_source_stamp_last_update_time(&content, stamp)?)
    }

    // ─── 应用日志（Task #79，对齐 Kotlin AppLog + 上游 #543 导出）──────

    /// 写入一条应用日志（级别：message / crash / http，大小写不敏感）
    ///
    /// 供 UI/Flutter 侧记录应用消息；空消息忽略（对齐 Kotlin `put` 的 null 短路）
    pub fn app_log_push(level: String, message: String) -> Result<(), BridgeError> {
        Ok(crate::api::log_api::push_log(&level, &message)?)
    }

    /// 获取指定级别的日志列表（JSON 数组，最新在前）
    ///
    /// 每项字段：`timestamp`（毫秒）/ `level` / `message`
    pub fn app_log_list(level: String) -> Result<String, BridgeError> {
        let logs = crate::api::log_api::list_logs(&level)?;
        to_json(&logs)
    }

    /// 清空指定级别的日志
    pub fn app_log_clear(level: String) -> Result<(), BridgeError> {
        Ok(crate::api::log_api::clear_logs(&level)?)
    }

    /// 清空全部级别日志（对齐 #543 清空确认后的 AppLog.clear + HttpLogStore.clear）
    pub fn app_log_clear_all() -> Result<(), BridgeError> {
        Ok(crate::api::log_api::clear_all_logs()?)
    }

    /// 导出全部日志为格式化文本（时间升序，64_000 字符截断，对齐 #543）
    pub fn app_log_export() -> Result<String, BridgeError> {
        Ok(crate::api::log_api::export_logs()?)
    }

    // ─── 规则订阅（Task #89，对齐 Kotlin RuleSub/RuleSubActivity）──────

    /// 获取规则订阅列表（RuleSub 数组 JSON，按 customOrder 排序）
    pub fn rule_sub_list() -> Result<String, BridgeError> {
        let subs = crate::api::rule_sub_api::list_subs_db()?;
        to_json(&subs)
    }

    /// 保存规则订阅（RuleSub JSON，id>0 且存在则更新，否则新增）
    pub fn rule_sub_save(sub_json: String) -> Result<bool, BridgeError> {
        let record: legado_db::RuleSubRecord = serde_json::from_str(&sub_json)?;
        Ok(crate::api::rule_sub_api::save_sub_db(&record)?)
    }

    /// 删除规则订阅，返回是否实际删除
    pub fn rule_sub_delete(id: i64) -> Result<bool, BridgeError> {
        Ok(crate::api::rule_sub_api::delete_sub_db(id)?)
    }

    /// 切换规则订阅启用状态，返回记录是否存在
    pub fn rule_sub_set_enabled(id: i64, enabled: bool) -> Result<bool, BridgeError> {
        Ok(crate::api::rule_sub_api::set_sub_enabled_db(id, enabled)?)
    }

    /// 批量更新规则订阅排序（拖拽排序，ids_json 为新顺序 ID 数组）
    pub fn rule_sub_update_order(ids_json: String) -> Result<bool, BridgeError> {
        let ids: Vec<i64> = serde_json::from_str(&ids_json)?;
        Ok(crate::api::rule_sub_api::update_sub_order_db(&ids)?)
    }

    /// 检查规则订阅更新（委托 should_update/fetch_subscription，返回检查结果 JSON）
    ///
    /// 返回字段：id/url/name/dueForUpdate/hasUpdate/remoteVersion/error
    pub fn rule_sub_check_update(id: i64) -> Result<String, BridgeError> {
        let result = crate::api::rule_sub_api::check_sub_update_db(id)?;
        to_json(&result)
    }

    /// 应用规则订阅更新（委托 fetch/merge_subscription，返回应用结果 JSON）
    ///
    /// 返回字段：id/url/success/itemsAdded/itemsUpdated/itemsRemoved/totalItems/error
    pub fn rule_sub_apply_update(id: i64) -> Result<String, BridgeError> {
        let result = crate::api::rule_sub_api::apply_sub_update_db(id)?;
        to_json(&result)
    }
}
