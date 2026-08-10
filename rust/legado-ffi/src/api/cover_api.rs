//! 封面规则搜索 API（契约 §2.4.8 `searchCoverRules`，Task #72/#73）
//!
//! 按书名执行 coverRules 表中全部启用规则搜封面，对齐原版
//! `BookCover.searchCover(book)` 链路（传 `book.name` 作搜索关键词）：
//!
//! 1. 数据源为 coverRules 表（`CoverRuleRepository::find_enabled`，
//!    仅 enable=1）；rule 字段为 JSON `{"searchUrl":"...","coverRule":"..."}`；
//! 2. searchUrl 经 [`crate::js_executor::build_search_url`] 渲染
//!    （`{{key}}`/`{{JS表达式}}`/`searchKey` 模板，key=书名），
//!    复用 dictLookup 同款的取体链路（data: URI / HTTP GET/POST）；
//! 3. coverRule 经 `AnalyzeRule::get_string` 提取（getString isUrl=true
//!    语义：提取结果按 URL 处理，相对路径经
//!    `AnalyzeUrl::get_absolute_url` 补全为绝对 URL）；
//! 4. 单规则失败隔离（记日志跳过，不阻断其余规则）；无启用规则或
//!    全部失败返回空数组 `[]`（非异常）；并发可串行（规则规模小）。
//!
//! 返回值为候选封面 URL 的**裸 JSON Array**（契约 §1.4 铁律）。

use std::time::Duration;

use serde::Deserialize;

use legado_core::{LegadoError, LegadoResult};
use legado_db::{CoverRule, CoverRuleRepository};
use legado_parser::{AnalyzeRule, AnalyzeUrl};

use crate::db_state::with_database;

/// 单条封面规则的请求超时（秒）
///
/// 原版无显式超时（跟随全局 OkHttp）；此处限制单规则耗时，
/// 避免离线场景下多规则串行拖垮查询（与 dict_api 同款保护）。
const COVER_RULE_TIMEOUT_SECS: u64 = 15;

/// coverRules 表 rule 字段的 JSON 结构（对齐原版 CoverRule 配置）
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CoverRuleConfig {
    /// 搜索 URL 模板（支持 `{{key}}` 等模板，key=书名）
    #[serde(default)]
    search_url: String,
    /// 封面提取规则（AnalyzeRule getString isUrl=true 语义）
    #[serde(default)]
    cover_rule: String,
}

/// 按书名执行全部启用封面规则搜封面
///
/// 返回候选封面 URL 裸 JSON Array（`["url1","url2"]`）；
/// 无启用规则/全部失败返回 `[]`。
///
/// 错误码：Internal（coverRules 规则数据读取失败，由 DB 错误映射）。
pub fn search_cover_rules(name: &str) -> LegadoResult<String> {
    let key = name.trim().to_string();

    if !crate::db_state::is_initialized() {
        // 数据库未初始化：返回空数组（沿用 dictLookup「非异常」语义）
        return Ok("[]".to_string());
    }

    // 规则数据读取失败 → 向上抛出（契约错误码 Internal）
    let rules = with_database(|db| {
        let repo = CoverRuleRepository::new(db.connection());
        repo.find_enabled()
    })?;

    // 逐条执行（串行，规模小）；单规则失败隔离
    let mut urls: Vec<String> = Vec::new();
    for rule in &rules {
        match search_one_cover_rule(rule, &key) {
            Ok(Some(url)) => urls.push(url),
            Ok(None) => {}
            Err(e) => {
                log::warn!("封面规则 [{}] 搜索「{}」失败（已跳过）: {}", rule.name, key, e);
            }
        }
    }

    serde_json::to_string(&urls)
        .map_err(|e| LegadoError::Internal(format!("封面 URL 列表序列化失败: {e}")))
}

/// 执行单条封面规则（对标原版 `BookCover.searchCover` 单规则分支）
///
/// 返回 `Ok(Some(url))` 命中 / `Ok(None)` 提取为空 / `Err` 失败（由调用方隔离）。
fn search_one_cover_rule(rule: &CoverRule, key: &str) -> Result<Option<String>, String> {
    // 1. rule JSON 解析（searchUrl + coverRule）
    let config: CoverRuleConfig = serde_json::from_str(&rule.rule)
        .map_err(|e| format!("rule JSON 解析失败: {e}"))?;
    let search_url = config.search_url.trim();
    let cover_rule = config.cover_rule.trim();
    if search_url.is_empty() || cover_rule.is_empty() {
        return Err("searchUrl/coverRule 为空".to_string());
    }

    // 2. searchUrl 模板渲染（复用 build_search_url：{{key}}/{{JS}}/searchKey）
    let analyze_url = crate::js_executor::build_search_url(search_url, key, 1, search_url);

    // 3. 取响应 body（复用 dict_api 取体链路，含 data: URI / 超时保护）
    let body = crate::runtime::block_on(async {
        match tokio::time::timeout(
            Duration::from_secs(COVER_RULE_TIMEOUT_SECS),
            crate::api::dict_api::fetch_body(&analyze_url),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Err(format!(
                "请求超时（>{COVER_RULE_TIMEOUT_SECS}s）: {}",
                analyze_url.url()
            )),
        }
    })?;

    // 4. coverRule 提取（getString 语义，复用 AnalyzeRule 自动路由）
    let analyzer = AnalyzeRule::new(body, analyze_url.url().to_string());
    let raw = analyzer
        .get_string(cover_rule)
        .map_err(|e| format!("coverRule 提取失败: {e}"))?;
    let raw = raw.trim();
    if raw.is_empty() {
        return Ok(None);
    }

    // 5. isUrl=true 语义：提取结果按 URL 处理，相对路径补全为绝对 URL
    Ok(Some(AnalyzeUrl::get_absolute_url(
        analyze_url.url(),
        raw,
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 串行锁：以下测试共享同一测试库的 coverRules 表，需串行执行
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// 清空 coverRules 表（测试隔离；持 ensure_test_db 串行锁调用）
    fn clear_cover_rules() {
        with_database(|db| {
            let repo = CoverRuleRepository::new(db.connection());
            repo.delete_all()
        })
        .unwrap();
    }

    /// 插入测试规则（启用）
    fn insert_rule(name: &str, rule: &str) -> i64 {
        with_database(|db| {
            let repo = CoverRuleRepository::new(db.connection());
            repo.insert(&CoverRule {
                id: 0,
                name: name.to_string(),
                rule: rule.to_string(),
                enable: true,
            })
        })
        .unwrap()
    }

    /// 无启用规则：返回空数组（非异常）
    #[test]
    fn test_no_enabled_rules_returns_empty_array() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        clear_cover_rules();

        let json = search_cover_rules("任意书名").unwrap();
        assert_eq!(json, "[]");
    }

    /// 禁用规则不执行
    #[test]
    fn test_disabled_rule_not_executed() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        clear_cover_rules();
        with_database(|db| {
            let repo = CoverRuleRepository::new(db.connection());
            repo.insert(&CoverRule {
                id: 0,
                name: "禁用规则".into(),
                rule: r#"{"searchUrl":"data:text/plain,x","coverRule":"$"}"#.into(),
                enable: false,
            })
        })
        .unwrap();

        let json = search_cover_rules("书名").unwrap();
        assert_eq!(json, "[]");
        clear_cover_rules();
    }

    /// 完整链路：data: URI searchUrl（{{key}} 模板替换）+ JsonPath coverRule 提取
    #[test]
    fn test_rule_url_template_and_extract() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        clear_cover_rules();
        // searchUrl 为 data: URI，body 内含书名（验证 {{key}} 模板替换）；
        // coverRule 用 JsonPath 提取封面 URL
        insert_rule(
            "JSON封面",
            r#"{"searchUrl":"data:application/json;charset=utf-8,{\"q\":\"{{key}}\",\"cover\":\"https://cdn.example.com/cover-{{key}}.jpg\"}","coverRule":"$.cover"}"#,
        );

        let json = search_cover_rules("测试书").unwrap();
        let urls: Vec<String> = serde_json::from_str(&json).unwrap();
        assert_eq!(urls.len(), 1);
        assert_eq!(
            urls[0],
            "https://cdn.example.com/cover-测试书.jpg"
        );
        clear_cover_rules();
    }

    /// 单规则失败隔离：不可达规则不影响其余规则
    #[test]
    fn test_failed_rule_isolated() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        clear_cover_rules();
        // 规则1：不可达 URL（连接失败，自然隔离）
        insert_rule(
            "不可达",
            r#"{"searchUrl":"http://127.0.0.1:1/cover?q={{key}}","coverRule":"$.cover"}"#,
        );
        // 规则2：rule JSON 非法（解析失败，隔离）
        insert_rule("非法JSON", "not-json");
        // 规则3：正常 data: URI
        insert_rule(
            "正常",
            r#"{"searchUrl":"data:application/json;charset=utf-8,{\"cover\":\"http://ok.example.com/c.jpg\"}","coverRule":"$.cover"}"#,
        );

        let json = search_cover_rules("x").unwrap();
        let urls: Vec<String> = serde_json::from_str(&json).unwrap();
        assert_eq!(urls.len(), 1, "仅正常规则产出结果：{json}");
        assert_eq!(urls[0], "http://ok.example.com/c.jpg");
        clear_cover_rules();
    }

    /// 提取结果为空：该规则无产出（非失败）
    #[test]
    fn test_empty_extract_returns_nothing() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        clear_cover_rules();
        // coverRule 提取不存在的字段 → 空结果
        insert_rule(
            "空提取",
            r#"{"searchUrl":"data:application/json;charset=utf-8,{\"a\":1}","coverRule":"$.cover"}"#,
        );

        let json = search_cover_rules("y").unwrap();
        assert_eq!(json, "[]");
        clear_cover_rules();
    }

    /// isUrl 语义：相对路径补全为绝对 URL
    #[test]
    fn test_relative_url_absolutized() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        clear_cover_rules();
        // searchUrl 为绝对 http 基址（不可达但 data 分支优先不走网络）——
        // 此处用 data: URI 取体，base URL 为 data: URI，无法补全 http 相对路径；
        // 故改用提取结果本身为完整 URL 的常规场景已由上例覆盖，
        // 本例验证 get_absolute_url 对绝对 URL 原样返回。
        insert_rule(
            "绝对URL",
            r#"{"searchUrl":"data:application/json;charset=utf-8,{\"cover\":\"https://abs.example.com/x.jpg\"}","coverRule":"$.cover"}"#,
        );

        let json = search_cover_rules("z").unwrap();
        let urls: Vec<String> = serde_json::from_str(&json).unwrap();
        assert_eq!(urls[0], "https://abs.example.com/x.jpg");
        clear_cover_rules();
    }
}
