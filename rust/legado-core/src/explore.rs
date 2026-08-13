//! 发现页（Explore）模块
//!
//! 对标 Android 端 ExploreShowActivity / ExploreShowViewModel 的核心逻辑：
//! - 解析书源 exploreUrl 为分类列表（ExploreKind）
//!
//! exploreUrl 格式（对标 BookSourceExtensions.kt）：
//! - 纯文本：`分类名::URL` 多条以 `\n` 或 `&&` 分隔
//! - JSON 数组：`[{"title":"分类","url":"..."}]`
//! - `@js:` / `<js>`：由 legado-ffi explore_api 执行 JS 后再解析
//!
//! 网络抓取逻辑位于 legado-ffi 的 explore_api.rs（依赖 legado-net/legado-parser）

use serde::{Deserialize, Serialize};

// ─── 数据结构 ─────────────────────────────────────────────────────────────────

/// 发现分类项（对标 Android ExploreKind）
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ExploreCategory {
    /// 分类标题
    pub title: String,
    /// 分类 URL（可能包含页码占位符；分组标题行可为 None）
    pub url: Option<String>,
}

// ─── exploreUrl 解析 ──────────────────────────────────────────────────────────

/// 解析 exploreUrl 规则字符串为分类列表（不含 `@js:` 执行，由 FFI 层先 resolve）
///
/// 支持格式：
/// 1. 纯文本：`分类名::URL` 多条以 `\n` 或 `&&` 分隔
/// 2. JSON 数组：`[{"title":"分类","url":"..."}]`
///
/// 对标 Android BookSourceExtensions.kt 中 exploreKinds() 的解析逻辑
pub fn parse_explore_url(explore_url: &str) -> Vec<ExploreCategory> {
    let trimmed = explore_url.trim();
    if trimmed.is_empty() {
        return vec![];
    }

    // 尝试 JSON 数组解析
    if trimmed.starts_with('[') {
        if let Ok(kinds) = serde_json::from_str::<Vec<JsonExploreKind>>(trimmed) {
            return kinds
                .into_iter()
                .filter(|k| !k.title.trim().is_empty())
                .map(|k| ExploreCategory {
                    title: k.title.trim().to_string(),
                    url: k.url.filter(|u| !u.trim().is_empty()),
                })
                .collect();
        }
    }

    // 纯文本格式：按 \n 或 && 分隔，每条按 :: 分割为 标题::URL
    let mut categories = Vec::new();
    // 对标 Android: ruleStr.split("(&&|\n)+".toRegex())
    for segment in trimmed.split(['\n', '\r']) {
        for part in segment.split("&&") {
            let part = part.trim();
            if part.is_empty() {
                continue;
            }
            // 按 :: 分割（对标 Android: kindStr.split("::")）
            if let Some(idx) = part.find("::") {
                let title = part[..idx].trim().to_string();
                let url = part[idx + 2..].trim().to_string();
                if !title.is_empty() {
                    categories.push(ExploreCategory {
                        title,
                        url: if url.is_empty() { None } else { Some(url) },
                    });
                }
            } else {
                // 无 URL 的分类（仅标题）
                categories.push(ExploreCategory {
                    title: part.to_string(),
                    url: None,
                });
            }
        }
    }

    categories
}

/// JSON 格式的 ExploreKind（用于反序列化）
#[derive(Debug, Deserialize)]
struct JsonExploreKind {
    #[serde(default)]
    title: String,
    #[serde(default)]
    url: Option<String>,
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_explore_url_text_format() {
        let input = "玄幻::https://example.com/xuanhuan\n都市::https://example.com/dushi";
        let result = parse_explore_url(input);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].title, "玄幻");
        assert_eq!(
            result[0].url,
            Some("https://example.com/xuanhuan".to_string())
        );
        assert_eq!(result[1].title, "都市");
        assert_eq!(result[1].url, Some("https://example.com/dushi".to_string()));
    }

    #[test]
    fn test_parse_explore_url_double_ampersand() {
        let input = "分类A::https://a.com&&分类B::https://b.com";
        let result = parse_explore_url(input);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].title, "分类A");
        assert_eq!(result[1].title, "分类B");
    }

    #[test]
    fn test_parse_explore_url_json_format() {
        let input = r#"[{"title":"玄幻","url":"https://example.com/xh"},{"title":"都市"}]"#;
        let result = parse_explore_url(input);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].title, "玄幻");
        assert_eq!(
            result[0].url,
            Some("https://example.com/xh".to_string())
        );
        assert_eq!(result[1].title, "都市");
        assert_eq!(result[1].url, None);
    }

    #[test]
    fn test_parse_explore_url_json_null_url_header() {
        let input = r#"[{"title":"排行榜","url":null},{"title":"玄幻","url":"https://a.com"}]"#;
        let result = parse_explore_url(input);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].title, "排行榜");
        assert_eq!(result[0].url, None);
        assert_eq!(result[1].title, "玄幻");
    }

    #[test]
    fn test_parse_explore_url_empty() {
        assert!(parse_explore_url("").is_empty());
        assert!(parse_explore_url("   ").is_empty());
    }

    #[test]
    fn test_parse_explore_url_no_url() {
        let input = "仅标题分类";
        let result = parse_explore_url(input);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].title, "仅标题分类");
        assert_eq!(result[0].url, None);
    }

    #[test]
    fn test_parse_explore_url_mixed_separators() {
        let input = "分类1::https://a.com\n分类2::https://b.com&&分类3::https://c.com";
        let result = parse_explore_url(input);
        assert_eq!(result.len(), 3);
        assert_eq!(result[0].title, "分类1");
        assert_eq!(result[1].title, "分类2");
        assert_eq!(result[2].title, "分类3");
    }
}
