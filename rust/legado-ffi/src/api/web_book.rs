//! WebBook FFI API
//!
//! 为 Flutter/Dart 提供书源驱动的搜索、目录、内容获取能力。
//! 所有复杂类型通过 JSON String 传递，避免 frb 为外部类型生成绑定。
//!
//! 使用 `RealBookSourceFetcher`（LegadoClient + AnalyzeUrl + AnalyzeRule）
//! 实现完整的搜索→详情→目录→正文链路。

use std::collections::HashMap;

use legado_core::models::BookSource;
use legado_core::models::{Book, BookChapter};
use legado_core::web_book::{
    BookSourceFetcher, WebBookEngine, WebBookInfo, WebChapter, WebSearchResult,
};
use legado_core::{LegadoError, LegadoResult};
use legado_js::js_source::js_source_book::JsSourceBookOrchestrator;
use legado_js::JsSourceConfig;
use legado_net::LegadoClient;
use legado_parser::{AnalyzeUrl, RequestMethod};

use crate::runtime;

// ─── Real Fetcher（真实网络请求 + 规则解析） ────────────────────────────────────

/// 真实书源数据抓取器
///
/// 基于 legado-net HTTP 客户端 + legado-parser 规则解析引擎，
/// 实现完整的搜索→详情→目录→正文链路（对标 Kotlin WebBook 对象）。
pub struct RealBookSourceFetcher {
    client: LegadoClient,
}

impl RealBookSourceFetcher {
    pub fn new() -> Self {
        // 复用进程共享的 HTTP 客户端单例（共享连接池与 CookieStore，clone 廉价）
        let client = crate::http_state::shared_client();
        Self { client }
    }

    /// 解析书源 header 字段为请求头
    fn parse_source_headers(source: &BookSource) -> Option<HashMap<String, String>> {
        source
            .header
            .as_ref()
            .and_then(|h| serde_json::from_str::<HashMap<String, String>>(h).ok())
    }

    /// 根据 AnalyzeUrl 解析结果发起 HTTP 请求，返回响应体文本
    async fn fetch_url(
        &self,
        analyze_url: &AnalyzeUrl,
        source_headers: Option<&HashMap<String, String>>,
    ) -> LegadoResult<String> {
        let url = analyze_url.url();
        if url.is_empty() {
            return Err(LegadoError::Internal("AnalyzeUrl 解析后 URL 为空".into()));
        }

        // 合并请求头：书源全局 header + AnalyzeUrl 解析出的 header
        let mut headers = source_headers.cloned().unwrap_or_default();
        headers.extend(analyze_url.headers().clone());
        let headers_opt = if headers.is_empty() {
            None
        } else {
            Some(headers)
        };

        let response = match analyze_url.method() {
            RequestMethod::Post => {
                let body = analyze_url.body().unwrap_or("");
                self.client.post(url, body, headers_opt).await?
            }
            _ => self.client.get(url, headers_opt).await?,
        };

        if !response.is_success() {
            return Err(LegadoError::Network(format!(
                "HTTP {} for {}",
                response.status, url
            )));
        }

        Ok(response.body)
    }

    /// 直接 GET 一个 URL（用于章节内容等简单场景）
    async fn fetch_simple(
        &self,
        url: &str,
        source_headers: Option<&HashMap<String, String>>,
    ) -> LegadoResult<String> {
        let headers_opt = source_headers.cloned();
        let response = self.client.get(url, headers_opt).await?;
        if !response.is_success() {
            return Err(LegadoError::Network(format!(
                "HTTP {} for {}",
                response.status, url
            )));
        }
        Ok(response.body)
    }

    /// 执行 loginCheckJs 登录检测（规则路径增强）
    ///
    /// 参考 Kotlin WebBook.kt 四链路中的 loginCheckJs 双路径模式：
    /// - 成功路径：HTTP 响应正常时 evalJS(loginCheckJs)
    /// - 无配置时静默跳过，不影响现有逻辑
    fn execute_login_check(
        source: &BookSource,
        response_body: &str,
        response_url: &str,
        response_code: u16,
    ) -> LegadoResult<()> {
        let login_check_js = match &source.login_check_js {
            Some(js) if !js.trim().is_empty() => js,
            _ => return Ok(()), // 无 loginCheckJs 配置，跳过
        };

        // 对齐原版语义：loginCheckJs 仅为登录态检查（常依赖 java.*/cookie.*
        // 等 Android 运行时对象），执行失败不应阻断详情/目录/正文获取，降级放行
        if let Err(e) = crate::js_executor::execute_login_check_js(
            login_check_js,
            response_body,
            response_url,
            response_code,
            &source.book_source_url,
        ) {
            eprintln!(
                "[web_book] loginCheckJs 执行失败（已忽略）: {}",
                e
            );
        }
        Ok(())
    }

    /// 从详情页响应体解析书籍详情（可复用辅助方法）
    ///
    /// 同时服务于：
    /// - 详情路径 `get_book_info`
    /// - 搜索详情页直连 / 空列表回退（B1.1）
    ///
    /// 对标 Kotlin `BookInfo.analyzeBookInfo`：
    /// - **canReName 双条件门控**：仅当规则 `canReName` 非空且入参 `can_re_name` 为 true 时，
    ///   才允许以解析结果覆盖已有书名/作者（`mCanReName = canReName && !infoRule.canReName.isNullOrBlank()`）；
    ///   否则仅在原值为空时填充。
    /// - **coverUrl 绝对化**：基于 `redirect_url` 转绝对 URL。
    /// - **tocUrl**：绝对化，空时回退 `book_url`。
    /// - **kind / wordCount** 字段提取。
    fn parse_book_info_from_body(
        source: &BookSource,
        body: String,
        book_url: &str,
        redirect_url: &str,
        can_re_name: bool,
        existing_name: &str,
        existing_author: &str,
    ) -> WebBookInfo {
        let info_rule = source.rule_book_info.as_ref();
        let analyzer = crate::js_executor::construct_analyzer(
            body,
            book_url.to_string(),
            &source.book_source_url,
        );

        // B2.1 canReName 双条件门控
        let rule_can_re_name = info_rule
            .and_then(|r| r.can_re_name.as_deref())
            .is_some_and(|v| !v.trim().is_empty());
        let m_can_re_name = can_re_name && rule_can_re_name;

        // 书名：对标 Kotlin `if (it.isNotEmpty() && (mCanReName || book.name.isEmpty()))`
        let parsed_name = info_rule
            .and_then(|r| r.name.as_deref())
            .map(|rule| analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();
        let name = if !parsed_name.is_empty() && (m_can_re_name || existing_name.is_empty()) {
            parsed_name
        } else {
            existing_name.to_string()
        };

        // 作者：与书名同门控
        let parsed_author = info_rule
            .and_then(|r| r.author.as_deref())
            .map(|rule| analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();
        let author = if !parsed_author.is_empty() && (m_can_re_name || existing_author.is_empty()) {
            parsed_author
        } else {
            existing_author.to_string()
        };

        // 分类：kind 原始字符串 + 拆分后的 categories
        let kind_raw = info_rule
            .and_then(|r| r.kind.as_deref())
            .map(|rule| analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();
        let (kind, categories) = if kind_raw.is_empty() {
            (None, Vec::new())
        } else {
            let cats = kind_raw
                .split([',', '，', ' '])
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            (Some(kind_raw), cats)
        };

        // B2 字数
        let word_count = info_rule
            .and_then(|r| r.word_count.as_deref())
            .and_then(|rule| optional_field(&analyzer, rule));

        let intro = info_rule
            .and_then(|r| r.intro.as_deref())
            .and_then(|rule| optional_field(&analyzer, rule));

        // 封面：基于 redirect_url 绝对化（对标 Kotlin NetworkUtils.getAbsoluteURL(redirectUrl, it)）
        let cover_url = info_rule
            .and_then(|r| r.cover_url.as_deref())
            .map(|rule| {
                let v = analyzer.get_string(rule).unwrap_or_default();
                if v.is_empty() {
                    None
                } else {
                    Some(AnalyzeUrl::get_absolute_url(redirect_url, &v))
                }
            })
            .unwrap_or(None);

        let last_chapter = info_rule
            .and_then(|r| r.last_chapter.as_deref())
            .and_then(|rule| optional_field(&analyzer, rule));

        // 目录页 URL：绝对化 + 空时回退 book_url（对标 Kotlin `if (book.tocUrl.isEmpty()) book.tocUrl = baseUrl`）
        let raw_toc = info_rule
            .and_then(|r| r.toc_url.as_deref())
            .map(|rule| analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();
        let toc_url = if raw_toc.is_empty() {
            book_url.to_string()
        } else {
            AnalyzeUrl::get_absolute_url(book_url, &raw_toc)
        };

        WebBookInfo {
            name,
            author,
            cover_url,
            intro,
            categories,
            last_chapter,
            book_url: book_url.to_string(),
            toc_url,
            word_count,
            kind,
        }
    }
}

impl Default for RealBookSourceFetcher {
    fn default() -> Self {
        Self::new()
    }
}

impl BookSourceFetcher for RealBookSourceFetcher {
    async fn search(
        &self,
        source: &BookSource,
        query: &str,
        page: i32,
    ) -> LegadoResult<Vec<WebSearchResult>> {
        let search_url = source.search_url.as_deref().unwrap_or("");
        if search_url.is_empty() {
            return Err(LegadoError::Internal("书源未配置 searchUrl".into()));
        }

        let source_headers = Self::parse_source_headers(source);

        // 1. 解析搜索 URL 模板
        let analyze_url = AnalyzeUrl::new(
            search_url,
            Some(query),
            Some(page.max(1) as u32),
            &source.book_source_url,
            source_headers.clone(),
        );

        // 2. 发起 HTTP 请求
        let body = self
            .fetch_url(&analyze_url, source_headers.as_ref())
            .await?;

        // 2.5 loginCheckJs 登录检测（规则路径增强）
        Self::execute_login_check(source, &body, analyze_url.url(), 200)?;

        let base_url = analyze_url.url().to_string();
        let search_rule = source.rule_search.as_ref();

        // 3. bookUrlPattern 详情页直连（B1.1，对标 Kotlin BookList `baseUrl.matches(bookUrlPattern)`）
        //    若搜索结果页 URL 命中详情页正则，说明返回体本身就是详情页，按单条详情解析。
        let has_pattern = source
            .book_url_pattern
            .as_deref()
            .is_some_and(|p| !p.trim().is_empty());
        if has_pattern
            && matches_book_url_pattern(source.book_url_pattern.as_deref().unwrap_or(""), &base_url)
        {
            let info = Self::parse_book_info_from_body(
                source,
                body,
                &base_url,
                &base_url,
                true,
                "",
                "",
            );
            return Ok(if info.name.is_empty() {
                vec![]
            } else {
                vec![info_to_search_result(info, &source.book_source_url)]
            });
        }

        // 4. 使用搜索规则解析列表
        let book_list_rule = search_rule
            .and_then(|r| r.book_list.as_deref())
            .unwrap_or("");

        let analyzer = crate::js_executor::construct_analyzer(
            body.clone(),
            base_url.clone(),
            &source.book_source_url,
        );

        let elements = if book_list_rule.is_empty() {
            vec![analyzer.content().to_string()]
        } else {
            analyzer.get_elements(book_list_rule).unwrap_or_default()
        };

        // 4.5 列表为空且未配置 bookUrlPattern 时，回退按详情页解析（对标 Kotlin BookList “列表为空,按详情页解析”）
        if elements.is_empty() && !has_pattern {
            let info = Self::parse_book_info_from_body(
                source,
                body,
                &base_url,
                &base_url,
                true,
                "",
                "",
            );
            return Ok(if info.name.is_empty() {
                vec![]
            } else {
                vec![info_to_search_result(info, &source.book_source_url)]
            });
        }

        // 5. 逐项提取字段（规则提到循环外，避免重复解析）
        let name_rule = search_rule.and_then(|r| r.name.as_deref()).unwrap_or("");
        let author_rule = search_rule.and_then(|r| r.author.as_deref()).unwrap_or("");
        let book_url_rule = search_rule
            .and_then(|r| r.book_url.as_deref())
            .unwrap_or("");
        let cover_url_rule = search_rule
            .and_then(|r| r.cover_url.as_deref())
            .unwrap_or("");
        let intro_rule = search_rule.and_then(|r| r.intro.as_deref()).unwrap_or("");
        let last_chapter_rule = search_rule
            .and_then(|r| r.last_chapter.as_deref())
            .unwrap_or("");
        let kind_rule = search_rule.and_then(|r| r.kind.as_deref()).unwrap_or("");
        let word_count_rule = search_rule
            .and_then(|r| r.word_count.as_deref())
            .unwrap_or("");

        let mut results = Vec::new();
        for elem in elements.iter().take(50) {
            let elem_analyzer = crate::js_executor::construct_analyzer(
                elem.clone(),
                base_url.clone(),
                &source.book_source_url,
            );

            let name = elem_analyzer.get_string(name_rule).unwrap_or_default();
            if name.is_empty() {
                continue;
            }

            let author = elem_analyzer.get_string(author_rule).unwrap_or_default();

            // B1.4 bookUrl 绝对化（对标 Kotlin getString(ruleBookUrl, isUrl=true)），空时回退 baseUrl
            let raw_book_url = elem_analyzer.get_string(book_url_rule).unwrap_or_default();
            let book_url = if raw_book_url.is_empty() {
                base_url.clone()
            } else {
                AnalyzeUrl::get_absolute_url(&base_url, &raw_book_url)
            };

            // B1.4 coverUrl 绝对化（对标 Kotlin NetworkUtils.getAbsoluteURL(baseUrl, it)）
            let cover_url = {
                let v = elem_analyzer.get_string(cover_url_rule).unwrap_or_default();
                if v.is_empty() {
                    None
                } else {
                    Some(AnalyzeUrl::get_absolute_url(&base_url, &v))
                }
            };
            let intro = optional_field(&elem_analyzer, intro_rule);
            let latest_chapter = optional_field(&elem_analyzer, last_chapter_rule);
            // B1.2 kind / wordCount 输出字段
            let kind = optional_field(&elem_analyzer, kind_rule);
            let word_count = optional_field(&elem_analyzer, word_count_rule);

            results.push(WebSearchResult {
                name,
                author,
                book_url,
                cover_url,
                intro,
                latest_chapter,
                source_url: source.book_source_url.clone(),
                kind,
                word_count,
            });
        }

        // B1.3 LinkedHashSet 去重：按 bookUrl 去重，保留首次出现顺序
        Ok(dedupe_by_book_url(results))
    }

    async fn get_book_info(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<WebBookInfo> {
        let source_headers = Self::parse_source_headers(source);

        // 1. 请求书籍详情页
        //    注：B2.2 infoHtml 缓存复用需要上游传入带 info_html 的 Book 对象，
        //    当前无状态 FFI 签名（book_url）无法携带，故此处始终发 HTTP（见报告说明）。
        let body = self.fetch_simple(book_url, source_headers.as_ref()).await?;

        // 1.5 loginCheckJs 登录检测
        Self::execute_login_check(source, &body, book_url, 200)?;

        // 2. 使用 bookInfo 规则解析（无状态上下文无已有书名，canReName=true、existing 为空）
        Ok(Self::parse_book_info_from_body(
            source, body, book_url, book_url, true, "", "",
        ))
    }

    async fn get_chapters(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<Vec<WebChapter>> {
        let source_headers = Self::parse_source_headers(source);

        // 1. 先获取详情页以确定 toc_url
        let info_body = self.fetch_simple(book_url, source_headers.as_ref()).await?;

        // 1.5 loginCheckJs 登录检测
        Self::execute_login_check(source, &info_body, book_url, 200)?;

        let info_rule = source.rule_book_info.as_ref();
        let info_analyzer = crate::js_executor::construct_analyzer(
            info_body.clone(),
            book_url.to_string(),
            &source.book_source_url,
        );

        let raw_toc = info_rule
            .and_then(|r| r.toc_url.as_deref())
            .map(|rule| info_analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();
        let toc_url = if raw_toc.is_empty() {
            book_url.to_string()
        } else {
            AnalyzeUrl::get_absolute_url(book_url, &raw_toc)
        };

        // 2. B3.1 tocHtml 缓存复用：当 tocUrl == bookUrl 时复用详情页响应体，避免重复请求
        //    （对标 Kotlin BookInfo `if (book.tocUrl == baseUrl) book.tocHtml = body` + BookChapterList 缓存复用）
        let toc_body = if toc_url == book_url {
            info_body
        } else {
            self.fetch_simple(&toc_url, source_headers.as_ref()).await?
        };

        // 3. B3.4 反转标记：chapterList 规则以 "-" 前缀表示倒序，"+" 前缀仅为标记（对标 Kotlin BookChapterList）
        let toc_rule = source.rule_toc.as_ref();
        let raw_list_rule = toc_rule
            .and_then(|r| r.chapter_list.as_deref())
            .unwrap_or("");
        let mut reverse = false;
        let mut chapter_list_rule = raw_list_rule;
        if let Some(stripped) = chapter_list_rule.strip_prefix('-') {
            reverse = true;
            chapter_list_rule = stripped;
        }
        if let Some(stripped) = chapter_list_rule.strip_prefix('+') {
            chapter_list_rule = stripped;
        }

        let analyzer =
            crate::js_executor::construct_analyzer(toc_body, toc_url.clone(), &source.book_source_url);

        let elements = if chapter_list_rule.is_empty() {
            vec![analyzer.content().to_string()]
        } else {
            analyzer.get_elements(chapter_list_rule).unwrap_or_default()
        };

        // 规则提到循环外
        let name_rule = toc_rule
            .and_then(|r| r.chapter_name.as_deref())
            .unwrap_or("");
        let url_rule = toc_rule
            .and_then(|r| r.chapter_url.as_deref())
            .unwrap_or("");
        let vip_rule = toc_rule.and_then(|r| r.is_vip.as_deref()).unwrap_or("");
        let volume_rule = toc_rule.and_then(|r| r.is_volume.as_deref()).unwrap_or("");

        let mut chapters = Vec::new();
        for (index, elem) in elements.iter().enumerate() {
            let elem_analyzer = crate::js_executor::construct_analyzer(
                elem.clone(),
                toc_url.clone(),
                &source.book_source_url,
            );

            let title = elem_analyzer.get_string(name_rule).unwrap_or_default();
            if title.is_empty() {
                continue;
            }

            let is_vip = if vip_rule.is_empty() {
                false
            } else {
                let v = elem_analyzer.get_string(vip_rule).unwrap_or_default();
                v == "true" || v == "1"
            };

            // B3.2 isVolume 标记（卷章）
            let is_volume = if volume_rule.is_empty() {
                false
            } else {
                let v = elem_analyzer.get_string(volume_rule).unwrap_or_default();
                v == "true" || v == "1"
            };

            // B3.3 空 URL 回退 + 绝对化（对标 Kotlin BookChapterList）
            //    - 卷章 url 空：用 `title + index` 替代（合成唯一标识，不绝对化）
            //    - 普通章 url 空：回退 baseUrl（目录页 url）
            //    - 非空 url：基于 toc_url 绝对化
            let raw_url = elem_analyzer.get_string(url_rule).unwrap_or_default();
            let url = if raw_url.is_empty() {
                if is_volume {
                    format!("{}{}", title, index)
                } else {
                    toc_url.clone()
                }
            } else {
                AnalyzeUrl::get_absolute_url(&toc_url, &raw_url)
            };

            chapters.push(WebChapter {
                index: index as i32,
                title,
                url,
                is_vip,
                is_volume,
            });
        }

        // B3.4 去重 + 反转管线（对标 Kotlin BookChapterList 双反转去重逻辑，去重键为 url）
        let chapters = if reverse {
            // "-" 前缀：先去重（保留首次），再反转
            let mut deduped = dedupe_first_by_url(chapters);
            deduped.reverse();
            deduped
        } else {
            // 默认：等价于 Kotlin reverse→去重→reverse，即去重保留最后一次出现、保持原顺序
            dedupe_last_by_url(chapters)
        };

        Ok(chapters)
    }

    async fn get_content(&self, source: &BookSource, chapter: &WebChapter) -> LegadoResult<String> {
        let source_headers = Self::parse_source_headers(source);

        // 1. 请求章节页面
        let body = self
            .fetch_simple(&chapter.url, source_headers.as_ref())
            .await?;

        // 1.5 loginCheckJs 登录检测
        Self::execute_login_check(source, &body, &chapter.url, 200)?;

        // 2. 使用正文规则解析
        let content_rule = source.rule_content.as_ref();
        let content_rule_str = content_rule
            .and_then(|r| r.content.as_deref())
            .unwrap_or("");

        let analyzer = crate::js_executor::construct_analyzer(
            body,
            chapter.url.clone(),
            &source.book_source_url,
        );

        let raw_content = if content_rule_str.is_empty() {
            analyzer.content().to_string()
        } else {
            analyzer.get_string(content_rule_str).unwrap_or_default()
        };

        // 3. 正文净化管线（对标 Kotlin BookContent.analyzeContent）
        // 音频/视频书源获取的是链接，不需要 HTML 格式化
        let is_media = source.book_source_type == legado_core::models::book_source::book_source_type::AUDIO
            || source.book_source_type == legado_core::models::book_source::book_source_type::VIDEO;

        let content = if is_media {
            raw_content
        } else {
            // 3.1 HtmlFormatter.formatKeepImg（保留 img 标签 + URL 绝对化）
            let cleaned = legado_core::html_formatter::format_keep_img(&raw_content, &chapter.url);
            // 3.2 unescapeHtml4（实体反转义）
            legado_core::html_formatter::unescape_html4(&cleaned)
        };

        // 4. 空内容检查（卷章豁免）
        if !chapter.is_volume && content.trim().is_empty() {
            return Err(LegadoError::ContentEmpty(format!(
                "章节 {} 正文为空",
                chapter.title
            )));
        }

        Ok(content)
    }
}

/// 构建 WebBookEngine（使用真实 HTTP + 规则解析实现）
pub fn build_engine() -> WebBookEngine<RealBookSourceFetcher> {
    WebBookEngine::new(RealBookSourceFetcher::new())
}

// ─── 规则路径增强辅助函数（B1-B3） ─────────────────────────────

/// 提取可选字段：规则为空或解析结果为空时返回 None
fn optional_field(analyzer: &legado_parser::AnalyzeRule, rule: &str) -> Option<String> {
    if rule.is_empty() {
        return None;
    }
    let v = analyzer.get_string(rule).unwrap_or_default();
    if v.is_empty() {
        None
    } else {
        Some(v)
    }
}

/// 判断 URL 是否命中 bookUrlPattern 正则（对标 Kotlin `baseUrl.matches(it.toRegex())`）
///
/// 正则非法时静默返回 false，不影响主流程。
fn matches_book_url_pattern(pattern: &str, url: &str) -> bool {
    regex::Regex::new(pattern)
        .map(|re| re.is_match(url))
        .unwrap_or(false)
}

/// 将 WebBookInfo 转为 WebSearchResult（详情页直连搜索项，对标 Kotlin `Book.toSearchBook()`）
fn info_to_search_result(info: WebBookInfo, source_url: &str) -> WebSearchResult {
    WebSearchResult {
        name: info.name,
        author: info.author,
        book_url: info.book_url,
        cover_url: info.cover_url,
        intro: info.intro,
        latest_chapter: info.last_chapter,
        source_url: source_url.to_string(),
        kind: info.kind,
        word_count: info.word_count,
    }
}

/// 搜索结果按 bookUrl 去重，保留首次出现顺序（对标 Kotlin `LinkedHashSet(bookList)`）
fn dedupe_by_book_url(results: Vec<WebSearchResult>) -> Vec<WebSearchResult> {
    let mut seen = std::collections::HashSet::new();
    results
        .into_iter()
        .filter(|r| seen.insert(r.book_url.clone()))
        .collect()
}

/// 章节去重（保留首次出现），去重键为 url
///
/// 对标 Kotlin `BookChapter.equals/hashCode`（基于 url）+ `LinkedHashSet(chapterList)`。
fn dedupe_first_by_url(chapters: Vec<WebChapter>) -> Vec<WebChapter> {
    let mut seen = std::collections::HashSet::new();
    chapters
        .into_iter()
        .filter(|c| seen.insert(c.url.clone()))
        .collect()
}

/// 章节去重（保留最后一次出现、保持原顺序）
///
/// 等价于 Kotlin 默认路径的 reverse→去重（保留首次）→reverse 双反转逻辑。
fn dedupe_last_by_url(chapters: Vec<WebChapter>) -> Vec<WebChapter> {
    let mut reversed = chapters;
    reversed.reverse();
    let mut deduped = dedupe_first_by_url(reversed);
    deduped.reverse();
    deduped
}

// ─── JS 书源分派辅助 ──────────────────────────────────────────────────────────

/// 将 JS 编排器搜索结果（serde_json::Value）转换为 WebSearchResult 列表
pub(crate) fn convert_js_search_results(
    values: Vec<serde_json::Value>,
    source_url: &str,
) -> Vec<WebSearchResult> {
    values
        .into_iter()
        .filter_map(|v| {
            let name = v.get("name")?.as_str()?.to_string();
            let book_url = v.get("bookUrl")?.as_str()?.to_string();
            if name.is_empty() || book_url.is_empty() {
                return None;
            }
            let author = v
                .get("author")
                .and_then(|a| a.as_str())
                .unwrap_or_default()
                .to_string();
            let cover_url = v
                .get("coverUrl")
                .and_then(|c| c.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            let intro = v
                .get("intro")
                .and_then(|i| i.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            let latest_chapter = v
                .get("latestChapter")
                .or_else(|| v.get("lastChapter"))
                .and_then(|l| l.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            let kind = v
                .get("kind")
                .and_then(|k| k.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            let word_count = v
                .get("wordCount")
                .and_then(|w| w.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            Some(WebSearchResult {
                name,
                author,
                book_url,
                cover_url,
                intro,
                latest_chapter,
                source_url: source_url.to_string(),
                kind,
                word_count,
            })
        })
        .collect()
}

/// 将 JS 编排器章节列表（serde_json::Value）转换为 WebChapter 列表
fn convert_js_chapters(values: Vec<serde_json::Value>) -> Vec<WebChapter> {
    values
        .into_iter()
        .enumerate()
        .map(|(i, v)| {
            let index = v
                .get("index")
                .and_then(|idx| idx.as_i64())
                .unwrap_or(i as i64) as i32;
            let title = v
                .get("title")
                .and_then(|t| t.as_str())
                .unwrap_or_default()
                .to_string();
            let url = v
                .get("url")
                .and_then(|u| u.as_str())
                .unwrap_or_default()
                .to_string();
            let is_vip = v
                .get("isVip")
                .and_then(|vip| vip.as_bool())
                .unwrap_or(false);
            WebChapter {
                index,
                title,
                url,
                is_vip,
                is_volume: false,
            }
        })
        .collect()
}

/// 构建 JS 书源编排器
///
/// 从 BookSource 的 mainJs 字段创建 JsSourceEngine 并包装为编排器。
/// quickjs 启用时使用真实 QuickJS 引擎，否则使用占位引擎。
/// mainJs 为空时返回 None（非 JS 源）。
pub(crate) fn build_js_orchestrator(source: &BookSource) -> LegadoResult<Option<JsSourceBookOrchestrator>> {
    let main_js = match source.main_js.as_deref() {
        Some(js) if !js.trim().is_empty() => js.to_string(),
        _ => return Ok(None),
    };

    let mut config = JsSourceConfig::new(source.book_source_url.clone(), main_js);
    if let Some(lib) = &source.js_lib {
        config = config.with_js_lib(lib.clone());
    }

    #[cfg(feature = "quickjs")]
    let engine = legado_js::JsSourceEngine::new_quickjs(config)?;
    #[cfg(not(feature = "quickjs"))]
    let engine = legado_js::JsSourceEngine::new_stub(config);

    Ok(Some(JsSourceBookOrchestrator::new(engine)))
}

// ─── 公开 API 函数 ─────────────────────────────────────────────────────────────

/// 搜索书籍
///
/// `source_json` — BookSource JSON 字符串
/// `query` — 搜索关键词
/// `page` — 页码（从 1 开始）
///
/// 返回 `WebSearchResult` JSON 数组字符串
pub fn webbook_search(source_json: &str, query: &str, page: i32) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;

    // JS 书源分派：spawn_blocking 避免嵌套 runtime 死锁（R1）
    if let Some(mut orchestrator) = build_js_orchestrator(&source)? {
        let source_clone = source.clone();
        let key = query.to_string();
        let values = runtime::block_on(async {
            tokio::task::spawn_blocking(move || {
                orchestrator.search(&source_clone, &key, page)
            })
            .await
            .map_err(|e| LegadoError::Internal(format!("JS 搜索任务异常: {e}")))?
        })?;
        let results = convert_js_search_results(values, &source.book_source_url);
        return serde_json::to_string(&results).map_err(LegadoError::Serialization);
    }

    // 规则书源路径（现有逻辑不变）
    let engine = build_engine();
    let results: Vec<WebSearchResult> =
        runtime::block_on(async { engine.search(&source, query, page).await })?;
    serde_json::to_string(&results).map_err(LegadoError::Serialization)
}

/// 获取书籍详情
///
/// `source_json` — BookSource JSON 字符串
/// `book_url` — 书籍详情页 URL
///
/// 返回 `WebBookInfo` JSON 字符串
pub fn webbook_info(source_json: &str, book_url: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;

    // JS 书源分派
    if let Some(mut orchestrator) = build_js_orchestrator(&source)? {
        let source_clone = source.clone();
        let url = book_url.to_string();
        let js_info = runtime::block_on(async {
            tokio::task::spawn_blocking(move || {
                let book = Book {
                    book_url: url.clone(),
                    origin: source_clone.book_source_url.clone(),
                    ..Book::default()
                };
                orchestrator.get_book_info(&source_clone, &book, true)
            })
            .await
            .map_err(|e| LegadoError::Internal(format!("JS 详情任务异常: {e}")))?
        })?;
        // 将 MarshalledBookInfo 转换为 WebBookInfo
        let categories = js_info
            .kind
            .as_deref()
            .map(|k| {
                k.split([',', '，', ' '])
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let info = WebBookInfo {
            name: js_info.name,
            author: js_info.author.unwrap_or_default(),
            cover_url: js_info.cover_url,
            intro: js_info.intro,
            categories,
            last_chapter: js_info.latest_chapter_title,
            book_url: book_url.to_string(),
            toc_url: js_info.toc_url.unwrap_or_else(|| book_url.to_string()),
            word_count: js_info.word_count,
            kind: js_info.kind,
        };
        return serde_json::to_string(&info).map_err(LegadoError::Serialization);
    }

    // 规则书源路径
    let engine = build_engine();
    let info: WebBookInfo =
        runtime::block_on(async { engine.get_book_info(&source, book_url).await })?;
    serde_json::to_string(&info).map_err(LegadoError::Serialization)
}

/// 获取章节列表
///
/// `source_json` — BookSource JSON 字符串
/// `book_url` — 书籍详情页 URL
///
/// 返回 `WebChapter` JSON 数组字符串
pub fn webbook_chapters(source_json: &str, book_url: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;

    // JS 书源分派
    if let Some(mut orchestrator) = build_js_orchestrator(&source)? {
        let source_clone = source.clone();
        let url = book_url.to_string();
        let values = runtime::block_on(async {
            tokio::task::spawn_blocking(move || {
                let book = Book {
                    book_url: url.clone(),
                    toc_url: url,
                    origin: source_clone.book_source_url.clone(),
                    ..Book::default()
                };
                orchestrator.get_chapter_list(&source_clone, &book)
            })
            .await
            .map_err(|e| LegadoError::Internal(format!("JS 目录任务异常: {e}")))?
        })?;
        let chapters = convert_js_chapters(values);
        return serde_json::to_string(&chapters).map_err(LegadoError::Serialization);
    }

    // 规则书源路径
    let engine = build_engine();
    let chapters: Vec<WebChapter> =
        runtime::block_on(async { engine.get_chapters(&source, book_url).await })?;
    serde_json::to_string(&chapters).map_err(LegadoError::Serialization)
}

/// 获取章节内容
///
/// `source_json` — BookSource JSON 字符串
/// `chapter_json` — WebChapter JSON 字符串
///
/// 返回章节正文文本
pub fn webbook_content(source_json: &str, chapter_json: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    let chapter: WebChapter = serde_json::from_str(chapter_json)?;

    // JS 书源分派
    if let Some(mut orchestrator) = build_js_orchestrator(&source)? {
        let source_clone = source.clone();
        let web_ch = chapter.clone();
        return runtime::block_on(async {
            tokio::task::spawn_blocking(move || {
                let book_chapter = BookChapter {
                    url: web_ch.url,
                    title: web_ch.title,
                    index: web_ch.index,
                    is_vip: web_ch.is_vip,
                    ..BookChapter::default()
                };
                let book = Book {
                    origin: source_clone.book_source_url.clone(),
                    ..Book::default()
                };
                orchestrator.get_content(&source_clone, &book_chapter, &book, None)
            })
            .await
            .map_err(|e| LegadoError::Internal(format!("JS 正文任务异常: {e}")))?
        });
    }

    // 规则书源路径
    let engine = build_engine();
    runtime::block_on(async { engine.get_content(&source, &chapter).await })
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::rule::ContentRule;

    fn make_source_json() -> String {
        serde_json::to_string(&BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: Some("https://example.com/search?q={key}".to_string()),
            rule_content: Some(ContentRule {
                content: Some("css(.content).html".to_string()),
                ..ContentRule::default()
            }),
            ..BookSource::default()
        })
        .unwrap()
    }

    #[test]
    fn test_webbook_search_invalid_source_json() {
        let err = webbook_search("not valid json", "关键词", 1).unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_info_invalid_source_json() {
        let err = webbook_info("invalid", "https://example.com/book/1").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_chapters_invalid_source_json() {
        let err = webbook_chapters("bad json", "https://example.com/book/1").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_content_invalid_chapter_json() {
        let err = webbook_content(&make_source_json(), "not json").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_build_engine_creates_real_fetcher() {
        // 验证 build_engine 能正常构建（不 panic）
        let _engine = build_engine();
    }

    #[test]
    fn test_real_fetcher_default() {
        // 验证 Default trait 实现
        let _fetcher = RealBookSourceFetcher::default();
    }

    #[test]
    fn test_webbook_search_empty_query_returns_error() {
        // 空关键词应返回解析错误（engine 层校验）
        let err = webbook_search(&make_source_json(), "", 1).unwrap_err();
        assert!(err.to_string().contains("搜索关键词不能为空"));
    }

    #[test]
    fn test_webbook_content_empty_chapter_url_returns_error() {
        let chapter_json = serde_json::to_string(&WebChapter::new(0, "第一章", "")).unwrap();
        let err = webbook_content(&make_source_json(), &chapter_json).unwrap_err();
        assert!(err.to_string().contains("章节URL不能为空"));
    }

    // ─── B1-B3 规则路径增强测试 ───────────────────────────────

    /// 构造带 bookInfo 规则的书源（canReName 可选）
    fn make_info_source(can_re_name: Option<&str>) -> BookSource {
        use legado_core::models::rule::BookInfoRule;
        BookSource {
            book_source_url: "https://example.com".to_string(),
            rule_book_info: Some(BookInfoRule {
                name: Some(".name".to_string()),
                author: Some(".author".to_string()),
                kind: Some(".kind".to_string()),
                word_count: Some(".wc".to_string()),
                cover_url: Some(".cover".to_string()),
                can_re_name: can_re_name.map(|s| s.to_string()),
                ..BookInfoRule::default()
            }),
            ..BookSource::default()
        }
    }

    const INFO_HTML: &str = "<html><body>\
<div class='name'>解析书名</div>\
<div class='author'>解析作者</div>\
<div class='kind'>科幻,悬疑</div>\
<div class='wc'>200万字</div>\
<div class='cover'>/covers/1.jpg</div>\
</body></html>";

    #[test]
    fn test_matches_book_url_pattern() {
        assert!(matches_book_url_pattern(
            r"https://example\.com/book/\d+",
            "https://example.com/book/123"
        ));
        assert!(!matches_book_url_pattern(
            r"https://example\.com/book/\d+",
            "https://example.com/search?q=x"
        ));
        // 非法正则静默返回 false
        assert!(!matches_book_url_pattern("[invalid", "https://example.com"));
    }

    #[test]
    fn test_dedupe_by_book_url_keeps_first() {
        let results = vec![
            WebSearchResult::new("书A", "作者A", "url1", "src"),
            WebSearchResult::new("书A重复", "作者A", "url1", "src"),
            WebSearchResult::new("书B", "作者B", "url2", "src"),
        ];
        let deduped = dedupe_by_book_url(results);
        assert_eq!(deduped.len(), 2);
        assert_eq!(deduped[0].name, "书A"); // 保留首次出现
        assert_eq!(deduped[1].book_url, "url2");
    }

    #[test]
    fn test_dedupe_first_by_url() {
        let chapters = vec![
            WebChapter::new(0, "章1", "u1"),
            WebChapter::new(1, "章1重复", "u1"),
            WebChapter::new(2, "章2", "u2"),
        ];
        let deduped = dedupe_first_by_url(chapters);
        assert_eq!(deduped.len(), 2);
        assert_eq!(deduped[0].title, "章1");
    }

    #[test]
    fn test_dedupe_last_by_url_keeps_last_preserves_order() {
        let chapters = vec![
            WebChapter::new(0, "章1", "u1"),
            WebChapter::new(1, "章2", "u2"),
            WebChapter::new(2, "章1重复", "u1"),
        ];
        let deduped = dedupe_last_by_url(chapters);
        assert_eq!(deduped.len(), 2);
        // 保留最后一次出现，且保持原相对顺序 → [章2, 章1重复]
        assert_eq!(deduped[0].title, "章2");
        assert_eq!(deduped[1].title, "章1重复");
    }

    #[test]
    fn test_info_to_search_result() {
        let mut info = WebBookInfo::new("三体", "刘慈欣", "url1", "toc1");
        info.kind = Some("科幻".to_string());
        info.word_count = Some("200k".to_string());
        let r = info_to_search_result(info, "https://src");
        assert_eq!(r.name, "三体");
        assert_eq!(r.kind.as_deref(), Some("科幻"));
        assert_eq!(r.word_count.as_deref(), Some("200k"));
        assert_eq!(r.source_url, "https://src");
    }

    #[test]
    fn test_parse_book_info_can_rename_gating() {
        // 规则 canReName 为空 + 已有书名非空 → 不覆盖（保留已有）
        let source = make_info_source(None);
        let info = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            INFO_HTML.to_string(),
            "https://example.com/book/1",
            "https://example.com/book/1",
            true,
            "已有书名",
            "已有作者",
        );
        assert_eq!(info.name, "已有书名");
        assert_eq!(info.author, "已有作者");

        // 规则 canReName 非空 + can_re_name=true + 已有非空 → 覆盖
        let source2 = make_info_source(Some("true"));
        let info2 = RealBookSourceFetcher::parse_book_info_from_body(
            &source2,
            INFO_HTML.to_string(),
            "https://example.com/book/1",
            "https://example.com/book/1",
            true,
            "已有书名",
            "已有作者",
        );
        assert_eq!(info2.name, "解析书名");
        assert_eq!(info2.author, "解析作者");

        // 已有书名为空 → 无论 canReName 均填充
        let info3 = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            INFO_HTML.to_string(),
            "https://example.com/book/1",
            "https://example.com/book/1",
            true,
            "",
            "",
        );
        assert_eq!(info3.name, "解析书名");
    }

    #[test]
    fn test_parse_book_info_fields_and_absolutize() {
        let source = make_info_source(None);
        let info = RealBookSourceFetcher::parse_book_info_from_body(
            &source,
            INFO_HTML.to_string(),
            "https://example.com/book/1",
            "https://example.com/book/1",
            true,
            "",
            "",
        );
        // kind 原始字符串 + 拆分 categories
        assert_eq!(info.kind.as_deref(), Some("科幻,悬疑"));
        assert_eq!(info.categories, vec!["科幻".to_string(), "悬疑".to_string()]);
        // wordCount
        assert_eq!(info.word_count.as_deref(), Some("200万字"));
        // coverUrl 绝对化
        assert_eq!(
            info.cover_url.as_deref(),
            Some("https://example.com/covers/1.jpg")
        );
        // tocUrl 规则为空时回退 book_url
        assert_eq!(info.toc_url, "https://example.com/book/1");
    }
}
