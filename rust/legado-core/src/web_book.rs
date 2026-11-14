//! WebBook — 书源规则驱动的完整书籍获取协调器
//!
//! 提供搜索、详情、目录、内容四大能力，对标 Kotlin 侧 WebBook 对象。
//! 当前阶段使用 `BookSourceFetcher` trait + 注入模式，便于 Mock 测试；
//! 真实实现待 AnalyUrl + LegadoClient 完善后对接。

use serde::{Deserialize, Serialize};

use crate::error::{LegadoError, LegadoResult};
use crate::models::book_source::BookSource;

// ─── 数据结构 ─────────────────────────────────────────────────────────────────

/// 搜索结果项
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WebSearchResult {
    /// 书名
    pub name: String,
    /// 作者
    pub author: String,
    /// 详情页 URL
    pub book_url: String,
    /// 封面 URL
    pub cover_url: Option<String>,
    /// 简介
    pub intro: Option<String>,
    /// 最新章节标题
    pub latest_chapter: Option<String>,
    /// 来源书源 URL
    pub source_url: String,
    /// 分类（kind 原始字符串，对标 Kotlin SearchBook.kind）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// 字数（对标 Kotlin SearchBook.wordCount）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub word_count: Option<String>,
    /// 书籍类型位标记（对标 Kotlin SearchBook.type / BookType；
    /// 0=文本，漫画/听书/视频源据此分流阅读器）— 发现页修复 A8
    #[serde(default, skip_serializing_if = "is_zero", rename = "type")]
    pub book_type: i32,
}

fn is_zero(v: &i32) -> bool {
    *v == 0
}

/// 章节信息
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WebChapter {
    /// 章节序号（从 0 开始）
    pub index: i32,
    /// 章节标题
    pub title: String,
    /// 章节 URL
    pub url: String,
    /// 是否 VIP 章节
    ///
    /// `#[serde(default)]`（缺陷修复 2026-11-15）：外部构造路径（书源调试
    /// `--`/`++`、REST 正文入口等）不一定提供该字段；缺失时按 false 处理，
    /// 与相邻 `is_volume`/`is_pay` 口径一致。此前无 default → 调试正文路径
    /// 反序列化即失败（`missing field 'is_vip'`），整条调试链不可用。
    #[serde(default)]
    pub is_vip: bool,
    /// 是否卷章（卷章不检查空内容）
    #[serde(default)]
    pub is_volume: bool,
    /// 是否付费章节（P1-1/P2-1：ruleToc.isPay 解析结果，对齐 BookChapter.isPay）
    #[serde(default)]
    pub is_pay: bool,
    /// 章节附加信息（对齐 BookChapter.tag）：卷章 = updateTime 规则 info 原文；
    /// 普通章 = info 剥离 wordCount 命中串后的余量（原版 `info.replaceFirst(match.value,"")`）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    /// 规则变量 JSON（对齐 BookChapter.variable；@put 写入）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
    /// 章节字数（对齐 BookChapter.wordCount；规则源由 updateTime 规则 info 经
    /// AppPattern.wordCountRegex 等价正则提取，N5；JS 源读 wordCount 键）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub word_count: Option<String>,
}

/// 书籍详情
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WebBookInfo {
    /// 书名
    pub name: String,
    /// 作者
    pub author: String,
    /// 封面 URL
    pub cover_url: Option<String>,
    /// 简介
    pub intro: Option<String>,
    /// 分类标签
    pub categories: Vec<String>,
    /// 最新章节标题
    pub last_chapter: Option<String>,
    /// 详情页 URL
    pub book_url: String,
    /// 目录页 URL（可能与详情页相同）
    pub toc_url: String,
    /// 字数（对标 Kotlin Book.wordCount）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub word_count: Option<String>,
    /// 分类（kind 原始字符串，对标 Kotlin Book.kind）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// 规则变量 JSON（换源 T3，2026-09-03）：bookInfo 规则求值期间的
    /// `@put`/JS `putVariable` 级联导出（对齐 AnalyzeRule.putVariable →
    /// Book.putVariable；原版无专用 variable 规则字段，与目录解析同一机制）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
    /// 书籍类型位标记（对标 Kotlin Book.type / BookType 位标志；P2-15 ②
    /// `type` 回流，2026-09-18）：JS `book.type=N` 写路径覆盖值优先（`bookType::{bookUrl}`
    /// overlay），缺失回落书源 `bookSourceType` 换算（TEXT=8 / AUDIO=32 /
    /// IMAGE=64 / VIDEO=4）。Dart 侧 `mergeWebInfo` 据此合并 `Book.bookType`
    /// 并经既有 updateBook 链路落库 `books.book_type`，开读路由
    /// （reader / reader-comic / audio / video）随值切换。
    #[serde(default, skip_serializing_if = "is_zero", rename = "type")]
    pub book_type: i32,
    /// 文件类书源（type=3）下载地址列表（P1-3，对标 Kotlin Book.downloadUrls：
    /// `getStringList(infoRule.downloadUrls, isUrl = true)` = 相对转绝对 + 去重；
    /// JSON 传输为数组，落库时序列化 JSON 字符串写 books.downloadUrls）
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "downloadUrls"
    )]
    pub download_urls: Option<Vec<String>>,
}

// ─── Fetcher trait ────────────────────────────────────────────────────────────

/// HTTP 响应结构，由 fetcher 返回
#[derive(Debug, Clone)]
pub struct FetchResponse {
    /// 最终 URL（可能经过重定向）
    pub url: String,
    /// 响应体文本
    pub body: String,
}

/// 书源数据抓取 trait
///
/// 将网络请求与规则解析抽象为统一接口，便于：
/// - 注入 Mock 实现用于单元测试
/// - 后续替换为真实的 AnalyUrl + LegadoClient 实现
#[allow(async_fn_in_trait)]
pub trait BookSourceFetcher: Send + Sync {
    /// 搜索书籍
    ///
    /// - `source`: 书源配置
    /// - `query`: 搜索关键词
    /// - `page`: 页码（从 1 开始）
    async fn search(
        &self,
        source: &BookSource,
        query: &str,
        page: i32,
    ) -> LegadoResult<Vec<WebSearchResult>>;

    /// 获取书籍详情
    ///
    /// - `source`: 书源配置
    /// - `book_url`: 书籍详情页 URL
    async fn get_book_info(&self, source: &BookSource, book_url: &str)
        -> LegadoResult<WebBookInfo>;

    /// 带既有书籍上下文的详情获取（换源 T2，2026-09-03）
    ///
    /// - `can_re_name`: 是否允许重命名（原版 changeSource 的 getBookInfoAwait
    ///   传 false → 保留既有书名/作者，仅其余字段更新）
    /// - `existing_name` / `existing_author`: 既有书名/作者（重命名门控基准）
    ///
    /// 默认实现退化为无上下文 [`BookSourceFetcher::get_book_info`]（Mock 等
    /// 实现无需感知）；真实实现覆盖以保留 canReName 门控语义。
    async fn get_book_info_with_existing(
        &self,
        source: &BookSource,
        book_url: &str,
        can_re_name: bool,
        existing_name: &str,
        existing_author: &str,
    ) -> LegadoResult<WebBookInfo> {
        let _ = (can_re_name, existing_name, existing_author);
        self.get_book_info(source, book_url).await
    }

    /// 带变量表的详情获取（换源变量链 R1，2026-09-06）
    ///
    /// 原版 `WebBook.getBookInfoAwait` 的详情请求 AnalyzeUrl 以 `ruleData = book`
    /// 构建（WebBook.kt:225-231），bookUrl 中的 `{{key}}` 模板与 `,{json}` 请求
    /// 选项用 book.variable（换源时=候选搜索期变量）展开。此前换源详情请求
    /// 变量表恒空，变量依赖源会请求到错误地址（目录/正文错书的链路根因之一）。
    ///
    /// 默认实现忽略变量表退化为 [`Self::get_book_info_with_existing`]（Mock 等
    /// 实现无需感知）；真实实现覆盖以传入变量。
    async fn get_book_info_with_existing_and_vars(
        &self,
        source: &BookSource,
        book_url: &str,
        can_re_name: bool,
        existing_name: &str,
        existing_author: &str,
        variables: &std::collections::HashMap<String, String>,
    ) -> LegadoResult<WebBookInfo> {
        let _ = variables;
        self.get_book_info_with_existing(
            source,
            book_url,
            can_re_name,
            existing_name,
            existing_author,
        )
        .await
    }

    /// 获取章节列表
    ///
    /// - `source`: 书源配置
    /// - `book_url`: 书籍详情页 URL（用于构造目录请求）
    async fn get_chapters(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<Vec<WebChapter>>;

    /// 带变量表的目录获取（换源变量链 R1，2026-09-06；语义修订 2026-09-17）
    ///
    /// `toc_url` 是**已解析的真实目录页 URL**（如换源 2a 详情解析出的
    /// toc_url；目录在详情页时可传详情 URL）：实现应直接抓取该目录页并对
    /// 响应体跑 ruleToc，**不得**把它当 book_url 走「抓详情 → init → tocUrl
    /// 规则重推目录地址」的详情路径——目录体上 init 求值空 → tocUrl 重推出
    /// 空值地址（如松鹤 `all-chapter?bookId=`）→ 服务端 422 → 0 章（换源
    /// 第二断点，2026-09-17 实测确证）。
    ///
    /// 原版 `WebBook.getChapterListAwait` 的目录请求 AnalyzeUrl 同样以
    /// `ruleData = book` 构建（WebBook.kt:312-318），目录地址中 `{{key}}`
    /// 模板与 `,{json}` 请求选项用 book.variable（候选 ⊕ 详情导出合并值）
    /// 展开。默认实现忽略变量表、以该 URL 直接请求目录退化为
    /// [`Self::get_chapters`]（Mock 等实现无需感知）；真实实现覆盖以传入变量。
    async fn get_chapters_with_vars(
        &self,
        source: &BookSource,
        toc_url: &str,
        variables: &std::collections::HashMap<String, String>,
    ) -> LegadoResult<Vec<WebChapter>> {
        let _ = variables;
        self.get_chapters(source, toc_url).await
    }

    /// 带变量表 + 书名提示的目录获取（换源回归 P2-2，2026-09-17）
    ///
    /// `book_name_hint` 为详情步已解析出的书名。原版 `BookChapterList.kt:196`
    /// 以 `AnalyzeRule(book, bookSource)` 构建解析器，`book` 完整可用，
    /// `@js:[{title: book.name, url: …}]` 类 `ruleToc.chapterList` 规则可读
    /// `book.name`。「已知目录页」直抓路径不抓详情页，无 hint 时 `book`
    /// 绑定名位为空 → 此类规则标题退化。
    ///
    /// 默认实现忽略 hint 退化为 [`Self::get_chapters_with_vars`]（Mock 等
    /// 实现无需感知，既有签名不变）；真实实现覆盖以注入 hint。
    async fn get_chapters_with_vars_and_name_hint(
        &self,
        source: &BookSource,
        toc_url: &str,
        variables: &std::collections::HashMap<String, String>,
        book_name_hint: Option<&str>,
    ) -> LegadoResult<Vec<WebChapter>> {
        let _ = book_name_hint;
        self.get_chapters_with_vars(source, toc_url, variables)
            .await
    }

    /// 带变量表 + 已知目录页 + 书名提示的目录获取（详情再进入/U7 刷新变量链 P2-12，2026-09-18）
    ///
    /// 与 [`Self::get_chapters_with_vars`] 不同：第一个 URL 参数是**书籍详情页
    /// 取址点**（bookUrl，其 `{{key}}` 模板与 `,{json}` 请求选项经变量表展开；
    /// 已知目录页可为相对路径，相对详情页绝对化），并携带已知目录页与书名
    /// 提示。原版 `WebBook.getChapterListAwait` 的目录请求 AnalyzeUrl 以
    /// `ruleData = book` 构建，目录/详情地址模板用 book.variable 展开——
    /// 详情再进入（U7 回书架再进详情）与 U7 目录刷新须把 DB 持久化的
    /// `books.variable` 传入，否则换源变量链（`{{svid}}`/`{{tok}}` 等）展开
    /// 为空 → 请求到错误地址（服务端 400）。
    ///
    /// 默认实现退化为 [`Self::get_chapters_with_vars_and_name_hint`]（Mock 等
    /// 实现无需感知，既有的变量表/门控委托链不变）；真实实现覆盖以实现
    /// 「已知目录页直抓 / 详情推导目录」完整逻辑。
    async fn get_chapters_with_hints_and_vars(
        &self,
        source: &BookSource,
        book_url: &str,
        known_toc_url: Option<&str>,
        book_name_hint: Option<&str>,
        variables: &std::collections::HashMap<String, String>,
    ) -> LegadoResult<Vec<WebChapter>> {
        let _ = known_toc_url;
        self.get_chapters_with_vars_and_name_hint(source, book_url, variables, book_name_hint)
            .await
    }

    /// 带 book 主键身份的目录获取（目录抓取链 bookUrl 脏值修正，2026-10-05）
    ///
    /// 与 [`Self::get_chapters_with_hints_and_vars`] 的唯一差异：`book_url` 仍是
    /// **本次请求取址点**（详情页 URL，或刷新目录链上调用方解析出的 tocUrl /
    /// 书籍页取址点），另增 `book_key` 为书籍**稳定主键**。
    ///
    /// 对齐原版 `WebBook.getChapterListAwait(bookSource, book)` 的二元语义：
    /// `book.bookUrl` 恒为主键（`AnalyzeRule` 的 `book` 绑定、章节映射登记、
    /// `books.variable` 反查均用它），`book.tocUrl` 才是抓取地址；刷新目录链上
    /// 两者不同（DB `books.tocUrl` 是取址点，主键仍是 `books.bookUrl`）。
    /// 真实实现须以 `book_key` 作 meta 缓存键、`book` 绑定 bookUrl、DB 变量
    /// 反查与章节反查登记键，**禁止**把取址点回填为 bookUrl——否则刷新链会把
    /// tocUrl 写成“书籍取址点”经章节反查泄漏到正文阶段的 `book` 绑定与媒体
    /// 副内容 sink（弹幕/歌词落库键）。
    ///
    /// 默认实现忽略 `book_key`，退化为
    /// [`Self::get_chapters_with_hints_and_vars`]（Mock/测试实现无需感知）。
    async fn get_chapters_with_book_key_and_vars(
        &self,
        source: &BookSource,
        book_url: &str,
        book_key: &str,
        known_toc_url: Option<&str>,
        book_name_hint: Option<&str>,
        variables: &std::collections::HashMap<String, String>,
    ) -> LegadoResult<Vec<WebChapter>> {
        let _ = book_key;
        self.get_chapters_with_hints_and_vars(
            source,
            book_url,
            known_toc_url,
            book_name_hint,
            variables,
        )
        .await
    }

    /// 获取章节正文内容
    ///
    /// - `source`: 书源配置
    /// - `chapter`: 目标章节（含 URL 等信息）
    async fn get_content(&self, source: &BookSource, chapter: &WebChapter) -> LegadoResult<String>;

    /// 获取章节正文 + `ruleContent.title` 标题链产物（P1-2）
    ///
    /// 默认实现退化为 [`Self::get_content`]（Mock 等实现无需感知，签名不变，
    /// title/img_url 恒 None）；真实实现覆盖以携带标题覆盖值与段评图，
    /// 实现 `AppPattern.imgRegex` 解构（imgUrl=group2、标题=group1 余量）。
    async fn get_content_with_meta(
        &self,
        source: &BookSource,
        chapter: &WebChapter,
    ) -> LegadoResult<ChapterContentWithMeta> {
        let content = self.get_content(source, chapter).await?;
        Ok(ChapterContentWithMeta {
            content,
            title_override: None,
            img_url: None,
        })
    }
}

/// 章节正文抓取产物（P1-2：正文 + `ruleContent.title` 标题链解构产物）
///
/// 对标 Kotlin `BookContent.analyzeContent` 的标题链副作用：`contentRule.title`
/// 非空时解析标题，`AppPattern.imgRegex` 命中后 `imgUrl = group2`、标题 = group1
/// 余量（group1 空则保留原章节标题）。产物经 [`BookSourceFetcher::get_content_with_meta`]
/// 回传，由调用方（ffi reader 链）写入 DB 章节（`chapters.title` / `chapters.imgUrl`）。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChapterContentWithMeta {
    /// 净化前的章节正文文本
    pub content: String,
    /// title 规则解析出的标题覆盖值（无 title 规则 / 解析为空 → None，不覆盖）
    pub title_override: Option<String>,
    /// 标题内解构出的段评图 URL（`AppPattern.imgRegex` group2，未命中 → None）
    pub img_url: Option<String>,
}

/// WebChapter → DB 章节实体（BookChapter）的**唯一**目录转换函数（P1-1/P2-1）
///
/// refresh_toc（ffi）/ 换源（ffi source_switch）/ server legacy 目录刷新三条
/// 路径一律经本函数，字段语义仅此一份（防复发规定 1：同一数据的写库/转换
/// 语义只允许一个实现）：
/// - is_volume / is_vip / is_pay / tag / word_count / variable 全量透传，
///   禁止任何 `false`/`None` 兜底硬编码（防复发规定 3）
/// - base_url / book_url 落稳定主键 book_url（目录转换的既有语义）
pub fn web_chapters_to_book_chapters(
    web_chapters: &[WebChapter],
    book_url: &str,
) -> Vec<crate::models::BookChapter> {
    web_chapters
        .iter()
        .map(|wc| crate::models::BookChapter {
            url: wc.url.clone(),
            title: wc.title.clone(),
            is_volume: wc.is_volume,
            base_url: book_url.to_string(),
            book_url: book_url.to_string(),
            index: wc.index,
            is_vip: wc.is_vip,
            // P2-1：ruleToc.isPay 解析结果透传（对标原版 BookChapter.isPay）
            is_pay: wc.is_pay,
            resource_url: None,
            // P1-1：章节附加信息透传（卷章 = updateTime 原文；普通章 =
            // 字数命中串剥离后的余量，语义见 fetcher parse_toc_chapter）
            tag: wc.tag.clone(),
            // N5：字数透传（WebChapter.word_count 来自 updateTime 规则/JS 源）
            word_count: wc.word_count.clone(),
            start: None,
            end: None,
            start_fragment_id: None,
            end_fragment_id: None,
            variable: wc.variable.clone(),
            // 章节标题内段评图（P1-2）：仅正文标题链写入，目录阶段恒空
            img_url: None,
        })
        .collect()
}

// ─── Mock Fetcher ─────────────────────────────────────────────────────────────

/// 用于单元测试的 Mock Fetcher
///
/// 通过 `VecDeque` 存储预设响应，每次调用按序消费。
/// 测试代码可预先通过 `push_*` 方法注入返回值。
#[cfg(test)]
#[derive(Default)]
pub struct MockBookSourceFetcher {
    search_results: std::sync::Mutex<Vec<LegadoResult<Vec<WebSearchResult>>>>,
    info_results: std::sync::Mutex<Vec<LegadoResult<WebBookInfo>>>,
    chapter_results: std::sync::Mutex<Vec<LegadoResult<Vec<WebChapter>>>>,
    content_results: std::sync::Mutex<Vec<LegadoResult<String>>>,
}

#[cfg(test)]
impl MockBookSourceFetcher {
    pub fn new() -> Self {
        Self::default()
    }

    /// 注入搜索响应
    pub fn push_search(&self, result: LegadoResult<Vec<WebSearchResult>>) {
        self.search_results
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(result);
    }

    /// 注入书籍详情响应
    pub fn push_info(&self, result: LegadoResult<WebBookInfo>) {
        self.info_results
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(result);
    }

    /// 注入章节列表响应
    pub fn push_chapters(&self, result: LegadoResult<Vec<WebChapter>>) {
        self.chapter_results
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(result);
    }

    /// 注入章节内容响应
    pub fn push_content(&self, result: LegadoResult<String>) {
        self.content_results
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(result);
    }
}

#[cfg(test)]
impl BookSourceFetcher for MockBookSourceFetcher {
    async fn search(
        &self,
        _source: &BookSource,
        _query: &str,
        _page: i32,
    ) -> LegadoResult<Vec<WebSearchResult>> {
        let mut queue = self
            .search_results
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if queue.is_empty() {
            Err(LegadoError::Internal(
                "MockBookSourceFetcher: no search result queued".into(),
            ))
        } else {
            queue.remove(0)
        }
    }

    async fn get_book_info(
        &self,
        _source: &BookSource,
        _book_url: &str,
    ) -> LegadoResult<WebBookInfo> {
        let mut queue = self.info_results.lock().unwrap_or_else(|e| e.into_inner());
        if queue.is_empty() {
            Err(LegadoError::Internal(
                "MockBookSourceFetcher: no info result queued".into(),
            ))
        } else {
            queue.remove(0)
        }
    }

    async fn get_chapters(
        &self,
        _source: &BookSource,
        _book_url: &str,
    ) -> LegadoResult<Vec<WebChapter>> {
        let mut queue = self
            .chapter_results
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if queue.is_empty() {
            Err(LegadoError::Internal(
                "MockBookSourceFetcher: no chapter result queued".into(),
            ))
        } else {
            queue.remove(0)
        }
    }

    async fn get_content(
        &self,
        _source: &BookSource,
        _chapter: &WebChapter,
    ) -> LegadoResult<String> {
        let mut queue = self
            .content_results
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if queue.is_empty() {
            Err(LegadoError::Internal(
                "MockBookSourceFetcher: no content result queued".into(),
            ))
        } else {
            queue.remove(0)
        }
    }
}

// ─── WebBookEngine ─────────────────────────────────────────────────────────────

/// WebBook 协调器
///
/// 封装完整的书源驱动书籍获取链路：搜索 → 详情 → 目录 → 内容。
/// 内部通过注入的 `BookSourceFetcher` 执行实际的网络请求与规则解析。
pub struct WebBookEngine<F: BookSourceFetcher> {
    fetcher: F,
}

impl<F: BookSourceFetcher> WebBookEngine<F> {
    /// 使用指定的 fetcher 构建 engine
    pub fn new(fetcher: F) -> Self {
        Self { fetcher }
    }

    /// 搜索书籍
    ///
    /// 流程（对标 Kotlin WebBook.searchBookAwait）：
    /// 1. 校验 searchUrl 不为空
    /// 2. 委托 fetcher 发起请求并解析结果
    /// 3. 返回 `WebSearchResult` 列表
    pub async fn search(
        &self,
        source: &BookSource,
        query: &str,
        page: i32,
    ) -> LegadoResult<Vec<WebSearchResult>> {
        // 校验搜索 URL（JS 书源的 searchUrl 通常为空，豁免校验）
        if !source.is_js_source()
            && source
                .search_url
                .as_ref()
                .is_none_or(|u| u.trim().is_empty())
        {
            return Err(LegadoError::Parser("搜索url不能为空".into()));
        }
        // 校验关键词
        if query.is_empty() {
            return Err(LegadoError::Parser("搜索关键词不能为空".into()));
        }
        let page = if page < 1 { 1 } else { page };
        self.fetcher.search(source, query, page).await
    }

    /// 获取书籍详情
    ///
    /// 流程（对标 Kotlin WebBook.getBookInfoAwait）：
    /// 1. 委托 fetcher 请求书籍详情页
    /// 2. 用 ruleBookInfo 规则解析
    pub async fn get_book_info(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<WebBookInfo> {
        if book_url.is_empty() {
            // [v2.0.10] 可读文案（原裸「bookUrl不能为空」无上下文）— Reasonix
            return Err(LegadoError::Parser(
                "书籍详情页地址为空，无法获取详情（该书源搜索/发现规则未解析出详情链接）".into(),
            ));
        }
        self.fetcher.get_book_info(source, book_url).await
    }

    /// 带既有书籍上下文的详情获取（换源 T2，2026-09-03）
    ///
    /// 委托 fetcher 的 [`BookSourceFetcher::get_book_info_with_existing`]，
    /// 保留既有书名/作者与 canReName 门控语义（对齐原版 changeSource getToc）。
    pub async fn get_book_info_with_existing(
        &self,
        source: &BookSource,
        book_url: &str,
        can_re_name: bool,
        existing_name: &str,
        existing_author: &str,
    ) -> LegadoResult<WebBookInfo> {
        if book_url.is_empty() {
            return Err(LegadoError::Parser(
                "书籍详情页地址为空，无法获取详情（该书源搜索/发现规则未解析出详情链接）".into(),
            ));
        }
        self.fetcher
            .get_book_info_with_existing(
                source,
                book_url,
                can_re_name,
                existing_name,
                existing_author,
            )
            .await
    }

    /// 获取章节列表
    ///
    /// 流程（对标 Kotlin WebBook.getChapterListAwait）：
    /// 1. 委托 fetcher 请求目录页
    /// 2. 用 ruleToc 规则解析章节列表
    pub async fn get_chapters(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<Vec<WebChapter>> {
        if book_url.is_empty() {
            // [v2.0.10] 可读文案（原裸「bookUrl不能为空」无上下文）— Reasonix
            return Err(LegadoError::Parser(
                "书籍详情页地址为空，无法获取目录（该书源搜索/发现规则未解析出详情链接）".into(),
            ));
        }
        let mut chapters = self.fetcher.get_chapters(source, book_url).await?;
        // 确保章节序号正确（从 0 开始递增）
        for (i, ch) in chapters.iter_mut().enumerate() {
            ch.index = i as i32;
        }
        Ok(chapters)
    }

    /// 带变量表 + 已知目录页 + 书名提示的目录获取（详情再进入/U7 刷新变量链 P2-12，2026-09-18）
    ///
    /// 委托 fetcher 的 [`BookSourceFetcher::get_chapters_with_hints_and_vars`]，
    /// 章节序号语义与 [`Self::get_chapters`] 一致（从 0 重编号）。变量表为
    /// DB `books.variable`（用户持久化值）经 `chapter_url_variables` 展开的
    /// HashMap，使详情/目录地址的 `{{key}}` 模板与 `,{json}` 请求选项被填充
    /// （与换源后变量链一致；DB 值 > 书源 `@put` 默认导出——用户显式设置
    /// 优先，P1-1 同源理由）。
    pub async fn get_chapters_with_hints_and_vars(
        &self,
        source: &BookSource,
        book_url: &str,
        known_toc_url: Option<&str>,
        book_name_hint: Option<&str>,
        variables: &std::collections::HashMap<String, String>,
    ) -> LegadoResult<Vec<WebChapter>> {
        if book_url.is_empty() {
            return Err(LegadoError::Parser(
                "书籍详情页地址为空，无法获取目录（该书源搜索/发现规则未解析出详情链接）".into(),
            ));
        }
        let mut chapters = self
            .fetcher
            .get_chapters_with_hints_and_vars(
                source,
                book_url,
                known_toc_url,
                book_name_hint,
                variables,
            )
            .await?;
        for (i, ch) in chapters.iter_mut().enumerate() {
            ch.index = i as i32;
        }
        Ok(chapters)
    }

    /// 带 book 主键身份的目录获取（目录抓取链 bookUrl 脏值修正）
    ///
    /// 委托 fetcher 的 [`BookSourceFetcher::get_chapters_with_book_key_and_vars`]，
    /// 章节序号语义与 [`Self::get_chapters`] 一致（从 0 重编号）。`book_url` 为
    /// 本次请求取址点、`book_key` 为书籍稳定主键（见 trait 方法文档）。
    pub async fn get_chapters_with_book_key_and_vars(
        &self,
        source: &BookSource,
        book_url: &str,
        book_key: &str,
        known_toc_url: Option<&str>,
        book_name_hint: Option<&str>,
        variables: &std::collections::HashMap<String, String>,
    ) -> LegadoResult<Vec<WebChapter>> {
        if book_url.is_empty() {
            return Err(LegadoError::Parser(
                "书籍详情页地址为空，无法获取目录（该书源搜索/发现规则未解析出详情链接）".into(),
            ));
        }
        let mut chapters = self
            .fetcher
            .get_chapters_with_book_key_and_vars(
                source,
                book_url,
                book_key,
                known_toc_url,
                book_name_hint,
                variables,
            )
            .await?;
        for (i, ch) in chapters.iter_mut().enumerate() {
            ch.index = i as i32;
        }
        Ok(chapters)
    }

    /// 获取章节内容
    ///
    /// 流程（对标 Kotlin WebBook.getContentAwait）：
    /// 1. 非 JS 源且 ruleContent 为空 → **直接返回章节 URL**（原版：
    ///    「正文规则为空,使用章节链接」；音频书常用直链章 URL）
    /// 2. 否则委托 fetcher 请求章节页并提取正文
    pub async fn get_content(
        &self,
        source: &BookSource,
        chapter: &WebChapter,
    ) -> LegadoResult<String> {
        if chapter.url.is_empty() {
            return Err(LegadoError::Parser("章节URL不能为空".into()));
        }
        // 校验正文规则（JS 书源由脚本直接返回内容，豁免规则校验）
        if !source.is_js_source() {
            let has_content_rule = source
                .rule_content
                .as_ref()
                .is_some_and(|r| r.content.as_ref().is_some_and(|c| !c.is_empty()));
            if !has_content_rule {
                // 对齐 Kotlin：正文规则为空时回退章节链接（听书/直链源关键路径）
                return Ok(chapter.url.clone());
            }
        }
        self.fetcher.get_content(source, chapter).await
    }

    /// 获取章节正文 + `ruleContent.title` 标题链产物（P1-2，透传 fetcher）
    ///
    /// 引擎侧仅转发：URL/规则校验与直链回退语义与 [`Self::get_content`]
    /// 完全一致（同一入口守卫），产物由调用方决定落库。
    pub async fn get_content_with_meta(
        &self,
        source: &BookSource,
        chapter: &WebChapter,
    ) -> LegadoResult<ChapterContentWithMeta> {
        if chapter.url.is_empty() {
            return Err(LegadoError::Parser("章节URL不能为空".into()));
        }
        // 校验正文规则（JS 书源由脚本直接返回内容，豁免规则校验）
        if !source.is_js_source() {
            let has_content_rule = source
                .rule_content
                .as_ref()
                .is_some_and(|r| r.content.as_ref().is_some_and(|c| !c.is_empty()));
            if !has_content_rule {
                // 对齐 Kotlin：正文规则为空时回退章节链接（听书/直链源关键路径）；
                // 直链回退不携带标题链产物（原版标题链仅在规则链内生效）
                return Ok(ChapterContentWithMeta {
                    content: chapter.url.clone(),
                    title_override: None,
                    img_url: None,
                });
            }
        }
        self.fetcher.get_content_with_meta(source, chapter).await
    }
}

// ─── 辅助构造函数 ──────────────────────────────────────────────────────────────

impl WebSearchResult {
    pub fn new(
        name: impl Into<String>,
        author: impl Into<String>,
        book_url: impl Into<String>,
        source_url: impl Into<String>,
    ) -> Self {
        Self {
            name: name.into(),
            author: author.into(),
            book_url: book_url.into(),
            cover_url: None,
            intro: None,
            latest_chapter: None,
            source_url: source_url.into(),
            kind: None,
            word_count: None,
            book_type: 0,
        }
    }
}

impl WebChapter {
    pub fn new(index: i32, title: impl Into<String>, url: impl Into<String>) -> Self {
        Self {
            index,
            title: title.into(),
            url: url.into(),
            is_vip: false,
            is_volume: false,
            is_pay: false,
            tag: None,
            variable: None,
            word_count: None,
        }
    }
}

impl WebBookInfo {
    pub fn new(
        name: impl Into<String>,
        author: impl Into<String>,
        book_url: impl Into<String>,
        toc_url: impl Into<String>,
    ) -> Self {
        Self {
            name: name.into(),
            author: author.into(),
            cover_url: None,
            intro: None,
            categories: Vec::new(),
            last_chapter: None,
            book_url: book_url.into(),
            toc_url: toc_url.into(),
            word_count: None,
            kind: None,
            variable: None,
            book_type: 0,
            download_urls: None,
        }
    }
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造用于测试的 BookSource（含 searchUrl 和 ruleContent）
    fn make_test_source() -> BookSource {
        use crate::models::rule::{ContentRule, SearchRule};
        BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: Some("https://example.com/search?q={key}".to_string()),
            rule_search: Some(SearchRule::default()),
            rule_content: Some(ContentRule {
                content: Some("css(.content).html".to_string()),
                ..ContentRule::default()
            }),
            ..BookSource::default()
        }
    }

    /// 构造无 searchUrl 的书源
    fn make_no_search_source() -> BookSource {
        BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "无搜索源".to_string(),
            search_url: None,
            ..BookSource::default()
        }
    }

    // ─── search 测试 ──────────────────────────────────────────────────────────

    #[tokio::test]
    async fn test_search_returns_results() {
        let mock = MockBookSourceFetcher::new();
        mock.push_search(Ok(vec![
            WebSearchResult::new(
                "三体",
                "刘慈欣",
                "https://example.com/book/1",
                "https://example.com",
            ),
            WebSearchResult::new(
                "黑暗森林",
                "刘慈欣",
                "https://example.com/book/2",
                "https://example.com",
            ),
        ]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let results = engine.search(&source, "三体", 1).await.unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].name, "三体");
        assert_eq!(results[1].name, "黑暗森林");
    }

    #[tokio::test]
    async fn test_search_empty_query_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let err = engine.search(&source, "", 1).await.unwrap_err();
        assert!(err.to_string().contains("搜索关键词不能为空"));
    }

    #[tokio::test]
    async fn test_search_no_search_url_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = make_no_search_source();

        let err = engine.search(&source, "关键词", 1).await.unwrap_err();
        assert!(err.to_string().contains("搜索url不能为空"));
    }

    #[tokio::test]
    async fn test_search_page_zero_normalized_to_one() {
        let mock = MockBookSourceFetcher::new();
        // 注入一个结果，page 参数由 fetcher 接收，这里只验证不崩溃
        mock.push_search(Ok(vec![WebSearchResult::new(
            "书A", "作者A", "url1", "src1",
        )]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let results = engine.search(&source, "书A", 0).await.unwrap();
        assert_eq!(results.len(), 1);
    }

    #[tokio::test]
    async fn test_search_empty_search_url_string_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            search_url: Some("".to_string()),
            ..BookSource::default()
        };

        let err = engine.search(&source, "关键词", 1).await.unwrap_err();
        assert!(err.to_string().contains("搜索url不能为空"));
    }

    // ─── get_book_info 测试 ────────────────────────────────────────────────────

    #[tokio::test]
    async fn test_get_book_info_success() {
        let mock = MockBookSourceFetcher::new();
        mock.push_info(Ok(WebBookInfo::new(
            "三体",
            "刘慈欣",
            "https://example.com/book/1",
            "https://example.com/book/1",
        )));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let info = engine
            .get_book_info(&source, "https://example.com/book/1")
            .await
            .unwrap();
        assert_eq!(info.name, "三体");
        assert_eq!(info.author, "刘慈欣");
    }

    #[tokio::test]
    async fn test_get_book_info_empty_url_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let err = engine.get_book_info(&source, "").await.unwrap_err();
        assert!(err.to_string().contains("详情页地址为空"));
    }

    #[tokio::test]
    async fn test_get_book_info_with_categories() {
        let mock = MockBookSourceFetcher::new();
        let mut info = WebBookInfo::new("凡人修仙传", "忘语", "url1", "url1");
        info.categories = vec!["仙侠".to_string(), "修真".to_string()];
        info.intro = Some("一个普通山村少年的修仙之路".to_string());
        mock.push_info(Ok(info));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let result = engine.get_book_info(&source, "url1").await.unwrap();
        assert_eq!(result.categories.len(), 2);
        assert!(result.intro.as_ref().unwrap().contains("修仙"));
    }

    #[tokio::test]
    async fn test_get_book_info_network_error_propagated() {
        let mock = MockBookSourceFetcher::new();
        mock.push_info(Err(LegadoError::Network("connection refused".into())));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let err = engine.get_book_info(&source, "url1").await.unwrap_err();
        assert!(matches!(err, LegadoError::Network(_)));
    }

    #[tokio::test]
    async fn test_get_book_info_serde_roundtrip() {
        let mut info = WebBookInfo {
            name: "斗破苍穹".to_string(),
            author: "天蚕土豆".to_string(),
            cover_url: Some("https://example.com/cover.jpg".to_string()),
            intro: Some("这里是简介".to_string()),
            categories: vec!["玄幻".to_string()],
            last_chapter: Some("第100章".to_string()),
            book_url: "https://example.com/book/10".to_string(),
            toc_url: "https://example.com/book/10/toc".to_string(),
            word_count: None,
            kind: None,
            variable: None,
            // P2-15 ②：type 回流（非零 → JSON 携带 `type` 键）
            book_type: 64,
            download_urls: None,
        };
        let json = serde_json::to_string(&info).unwrap();
        assert!(json.contains(r#""type":64"#), "非零 type 应序列化进 JSON");
        let de: WebBookInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(de, info);
        // 零值省略（Dart 侧 mergeWebInfo 以「缺键 = 保留现值」语义依赖此行为）
        info.book_type = 0;
        let json0 = serde_json::to_string(&info).unwrap();
        assert!(!json0.contains(r#""type""#), "零值 type 应省略不序列化");
        let de0: WebBookInfo = serde_json::from_str(&json0).unwrap();
        assert_eq!(de0.book_type, 0);
    }

    // ─── get_chapters 测试 ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn test_get_chapters_success() {
        let mock = MockBookSourceFetcher::new();
        mock.push_chapters(Ok(vec![
            WebChapter::new(0, "第一章", "https://example.com/ch/1"),
            WebChapter::new(1, "第二章", "https://example.com/ch/2"),
            WebChapter::new(2, "第三章", "https://example.com/ch/3"),
        ]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let chapters = engine
            .get_chapters(&source, "https://example.com/book/1")
            .await
            .unwrap();
        assert_eq!(chapters.len(), 3);
        assert_eq!(chapters[0].index, 0);
        assert_eq!(chapters[2].index, 2);
        assert_eq!(chapters[1].title, "第二章");
    }

    #[tokio::test]
    async fn test_get_chapters_empty_url_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let err = engine.get_chapters(&source, "").await.unwrap_err();
        assert!(err.to_string().contains("详情页地址为空"));
    }

    #[tokio::test]
    async fn test_get_chapters_reindex() {
        // 即使 fetcher 返回乱序 index，engine 应重新编号
        let mock = MockBookSourceFetcher::new();
        mock.push_chapters(Ok(vec![
            WebChapter::new(99, "第一章", "url1"),
            WebChapter::new(100, "第二章", "url2"),
        ]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let chapters = engine.get_chapters(&source, "book_url").await.unwrap();
        assert_eq!(chapters[0].index, 0);
        assert_eq!(chapters[1].index, 1);
    }

    #[tokio::test]
    async fn test_get_chapters_empty_list() {
        let mock = MockBookSourceFetcher::new();
        mock.push_chapters(Ok(vec![]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let chapters = engine.get_chapters(&source, "book_url").await.unwrap();
        assert!(chapters.is_empty());
    }

    #[tokio::test]
    async fn test_get_chapters_vip_flag_preserved() {
        let mock = MockBookSourceFetcher::new();
        let mut ch = WebChapter::new(0, "VIP章节", "url_vip");
        ch.is_vip = true;
        mock.push_chapters(Ok(vec![ch]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let chapters = engine.get_chapters(&source, "book_url").await.unwrap();
        assert!(chapters[0].is_vip);
    }

    // ─── get_content 测试 ──────────────────────────────────────────────────────

    #[tokio::test]
    async fn test_get_content_success() {
        let mock = MockBookSourceFetcher::new();
        mock.push_content(Ok("这是正文内容，测试用。".to_string()));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();
        let chapter = WebChapter::new(0, "第一章", "https://example.com/ch/1");

        let content = engine.get_content(&source, &chapter).await.unwrap();
        assert!(content.contains("正文内容"));
    }

    #[tokio::test]
    async fn test_get_content_no_content_rule_falls_back_to_chapter_url() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        // source 无 ruleContent → 对齐 Kotlin 回退章节 URL
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            rule_content: None,
            ..BookSource::default()
        };
        let chapter = WebChapter::new(0, "第一章", "https://cdn.example.com/a.mp3");

        let content = engine.get_content(&source, &chapter).await.unwrap();
        assert_eq!(content, "https://cdn.example.com/a.mp3");
    }

    #[tokio::test]
    async fn test_get_content_empty_chapter_url_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();
        let chapter = WebChapter::new(0, "第一章", "");

        let err = engine.get_content(&source, &chapter).await.unwrap_err();
        assert!(err.to_string().contains("章节URL不能为空"));
    }

    #[tokio::test]
    async fn test_get_content_empty_content_rule_string_falls_back_to_chapter_url() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            rule_content: Some(crate::models::rule::ContentRule {
                content: Some("".to_string()), // 空字符串
                ..crate::models::rule::ContentRule::default()
            }),
            ..BookSource::default()
        };
        let chapter = WebChapter::new(0, "第一章", "https://cdn.example.com/ch1.m4a");

        let content = engine.get_content(&source, &chapter).await.unwrap();
        assert_eq!(content, "https://cdn.example.com/ch1.m4a");
    }

    #[tokio::test]
    async fn test_get_content_network_error_propagated() {
        let mock = MockBookSourceFetcher::new();
        mock.push_content(Err(LegadoError::Network("timeout".into())));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();
        let chapter = WebChapter::new(0, "第一章", "url1");

        let err = engine.get_content(&source, &chapter).await.unwrap_err();
        assert!(matches!(err, LegadoError::Network(_)));
    }

    // ─── 数据结构序列化测试 ────────────────────────────────────────────────────

    #[test]
    fn test_web_search_result_serde() {
        let r = WebSearchResult::new("书名", "作者", "url1", "src1");
        let json = serde_json::to_string(&r).unwrap();
        let de: WebSearchResult = serde_json::from_str(&json).unwrap();
        assert_eq!(de.name, "书名");
        assert_eq!(de.author, "作者");
    }

    #[test]
    fn test_web_chapter_serde() {
        let ch = WebChapter::new(5, "第五章", "url5");
        let json = serde_json::to_string(&ch).unwrap();
        let de: WebChapter = serde_json::from_str(&json).unwrap();
        assert_eq!(de.index, 5);
        assert_eq!(de.title, "第五章");
        assert!(!de.is_vip);
    }
    /// P1-1/P2-1（防复发规定 3）：WebChapter → BookChapter 全字段透传断言
    ///（源字段全非默认 → 目标逐字段相等；base_url/book_url 落稳定主键）
    #[test]
    fn test_web_chapters_to_book_chapters_full_field_passthrough() {
        let web = WebChapter {
            index: 3,
            title: "第二卷".to_string(),
            url: "https://src.test/v/2".to_string(),
            is_vip: true,
            is_volume: true,
            is_pay: true,
            tag: Some("2024-01-01".to_string()),
            variable: Some(r#"{"k":"v"}"#.to_string()),
            word_count: Some("1000字".to_string()),
        };
        let bcs = web_chapters_to_book_chapters(std::slice::from_ref(&web), "https://src.test");
        assert_eq!(bcs.len(), 1);
        let bc = &bcs[0];
        assert_eq!(bc.url, web.url);
        assert_eq!(bc.title, web.title);
        assert_eq!(bc.index, web.index);
        assert_eq!(bc.is_vip, web.is_vip);
        assert_eq!(bc.is_volume, web.is_volume, "卷章标记透传（禁 false 兜底）");
        assert_eq!(bc.is_pay, web.is_pay, "付费标记透传（禁 false 兜底）");
        assert_eq!(bc.tag, web.tag, "章节附加信息透传（禁 None 兜底）");
        assert_eq!(bc.variable, web.variable);
        assert_eq!(bc.word_count, web.word_count);
        assert_eq!(bc.base_url, "https://src.test");
        assert_eq!(bc.book_url, "https://src.test");
    }

    /// P1-1/P2-1：WebChapter 旧 JSON（无 isPay/tag 键）反序列化兼容——
    /// serde default 缺省，老调用方（Dart 侧拼装 JSON 等）不破
    #[test]
    fn test_web_chapter_legacy_json_without_new_fields() {
        let json = r#"{"index":0,"title":"t","url":"u","is_vip":false,"is_volume":false}"#;
        let ch: WebChapter = serde_json::from_str(json).unwrap();
        assert!(!ch.is_pay);
        assert!(ch.tag.is_none());
    }

    /// [缺陷回归 2026-11-15] 调试正文路径最小章节 JSON（仅 title/url/index）
    ///
    /// `source_debug_api::content_debug` 构造章节对象时只提供 `title`/`url`/
    /// `index`；`is_vip` 无 `#[serde(default)]` 时整条调试正文链
    /// （`--<chapterUrl>` 与 `++<tocUrl>` 首章）在
    /// `webbook_content` 反序列化即失败：`missing field 'is_vip'`。
    /// 修复要求：缺失时缺省为 false（不得把普通章节误判为 VIP 章节）。
    #[test]
    fn test_web_chapter_minimal_debug_json_defaults_is_vip_false() {
        let json = r#"{"title":"调试","url":"https://example.com/ch/1.html","index":0}"#;
        let ch: WebChapter =
            serde_json::from_str(json).expect("正文调试路径最小章节 JSON 必须可反序列化");
        assert_eq!(ch.index, 0);
        assert_eq!(ch.title, "调试");
        assert_eq!(ch.url, "https://example.com/ch/1.html");
        assert!(!ch.is_vip, "is_vip 缺省必须为 false（不得误判 VIP 章节）");
        assert!(!ch.is_volume);
        assert!(!ch.is_pay);
        assert!(ch.tag.is_none() && ch.variable.is_none() && ch.word_count.is_none());
    }

    /// [缺陷回归 2026-11-15] 显式 `is_vip: true` 仍须保留（default 只补缺省，
    /// 不得把真实 VIP 标记压成 false）
    #[test]
    fn test_web_chapter_explicit_is_vip_true_preserved() {
        let json =
            r#"{"title":"VIP章","url":"https://example.com/ch/2.html","index":1,"is_vip":true}"#;
        let ch: WebChapter = serde_json::from_str(json).unwrap();
        assert!(ch.is_vip, "显式 is_vip=true 必须保留");
    }

    /// 引擎 get_content_with_meta：默认直链回退（正文规则为空 → 返回章节
    /// URL）不携带标题链产物；Mock 默认实现只回正文（title/img_url 恒 None）
    #[tokio::test]
    async fn test_engine_get_content_with_meta_fallback_and_mock() {
        let fetcher = MockBookSourceFetcher::default();
        fetcher.push_content(Ok("正文".to_string()));
        let engine = WebBookEngine::new(fetcher);

        let mut source = make_test_source();
        // 正文规则为空 → 回退章节 URL（听书/直链源关键路径），meta 恒 None
        source.rule_content = Some(crate::models::rule::ContentRule::default());
        let ch = WebChapter::new(0, "第一章", "https://src.test/c/1");
        let meta = engine.get_content_with_meta(&source, &ch).await.unwrap();
        assert_eq!(meta.content, "https://src.test/c/1");
        assert!(meta.title_override.is_none() && meta.img_url.is_none());

        // Mock fetcher 默认路径：正文透传，标题链产物恒 None
        let fetcher2 = MockBookSourceFetcher::default();
        fetcher2.push_content(Ok("正文".to_string()));
        let engine2 = WebBookEngine::new(fetcher2);
        let mut source2 = make_test_source();
        source2.rule_content = Some(crate::models::rule::ContentRule {
            content: Some("class.content@text".to_string()),
            ..crate::models::rule::ContentRule::default()
        });
        let meta2 = engine2.get_content_with_meta(&source2, &ch).await.unwrap();
        assert_eq!(meta2.content, "正文");
        assert!(meta2.title_override.is_none() && meta2.img_url.is_none());
    }
}
