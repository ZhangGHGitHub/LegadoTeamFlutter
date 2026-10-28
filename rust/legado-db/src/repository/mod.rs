//! 数据访问层（Repository 模式）

pub mod auto_task_repository;
pub mod book_chapter_repository;
pub mod book_group_repository;
pub mod book_memo_repository;
pub mod book_repository;
pub mod book_source_check_state_repository;
pub mod book_source_repository;
pub mod bookmark_repository;
pub mod cache_book_repository;
pub mod cache_repository;
pub mod cookie_repository;
pub mod cover_rule_repository;
pub mod dict_rule_repository;
pub mod download_task_repository;
pub mod highlight_repository;
pub mod highlight_rule_repository;
pub mod http_tts_repository;
pub mod keyboard_assist_repository;
pub mod read_record_repository;
pub mod replace_rule_repository;
pub mod review_repository;
pub mod rss_article_repository;
pub mod rss_read_record_repository;
pub mod rss_source_repository;
pub mod rss_star_repository;
pub mod rule_sub_repository;
pub mod search_book_repository;
pub mod search_keyword_repository;
pub mod server_repository;
pub mod txt_toc_rule_repository;

use legado_core::LegadoResult;

/// 通用 Repository trait
pub trait Repository<T> {
    fn find_all(&self) -> LegadoResult<Vec<T>>;
    fn insert(&self, item: &T) -> LegadoResult<()>;
    fn update(&self, item: &T) -> LegadoResult<()>;
    fn delete(&self, id: &str) -> LegadoResult<()>;
}

/// 收集查询行；单行映射失败时记日志并跳过（批30b P3-7）
///
/// 背景：原 `filter_map(|r| r.ok())` 静默吞掉行解析错误（列漂移/坏 JSON 等），
/// 表现为「书源凭空消失」且无任何线索。保持「单行坏不拖垮整表」的可用性取向
/// （对齐 Room 逐行映射语义），但把失败行数与前几条错误写到 stderr（本 crate
/// 无 tracing 依赖，沿用迁移自愈的 eprintln 约定）；超过 3 条只汇总条数，
/// 避免坏库刷屏。
pub(crate) fn collect_rows_logged<T>(
    rows: impl Iterator<Item = rusqlite::Result<T>>,
    context: &str,
) -> Vec<T> {
    let mut out = Vec::new();
    let mut failed = 0usize;
    for row in rows {
        match row {
            Ok(item) => out.push(item),
            Err(e) => {
                failed += 1;
                if failed <= 3 {
                    eprintln!("[legado-db] {context}行解析失败（已跳过）: {e}");
                }
            }
        }
    }
    if failed > 3 {
        eprintln!(
            "[legado-db] {context}另有 {} 行解析失败（已跳过）",
            failed - 3
        );
    }
    out
}

#[cfg(test)]
mod tests {
    use super::collect_rows_logged;

    #[test]
    fn test_collect_rows_logged_skips_bad_rows() {
        let rows: Vec<rusqlite::Result<i32>> =
            vec![Ok(1), Err(rusqlite::Error::InvalidQuery), Ok(3)];
        assert_eq!(
            collect_rows_logged(rows.into_iter(), "测试查询"),
            vec![1, 3],
            "坏行跳过、好行保留"
        );
    }
}
