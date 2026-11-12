//! 书源管理 API
//!
//! 提供书源的增删改查、启用/禁用、批量导入/导出操作。

use legado_core::models::BookSource;
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::Repository;
use legado_db::BookSourceRepository;

use crate::db_state::with_database;

/// 获取所有书源
pub fn list_sources() -> LegadoResult<Vec<BookSource>> {
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_all()
    })
}

/// 书源列表项（书源 + 书架书籍数，批31）
///
/// 仅用于 FFI `source_list`（书源管理页）：`#[serde(flatten)]` 保持既有
/// 书源对象形状不变，追加 `bookshelfCount` 加法式字段；`source_export`
/// （导出/备份）继续走 [`list_sources`]，不携带该字段。
#[derive(Debug, Clone, serde::Serialize)]
pub struct BookSourceListItem {
    #[serde(flatten)]
    pub source: BookSource,
    /// 该书源（按 origin 精确匹配）在书架中的书籍数；无书或非书架书 → 0
    #[serde(rename = "bookshelfCount")]
    pub bookshelf_count: i64,
}

/// 获取所有书源并附带书架书籍数（契约 §2.3：`getBookSources` 返回项
/// 加法式字段 `bookshelfCount`）
///
/// 计数口径见
/// [`legado_db::BookRepository::count_bookshelf_books_by_origin`]：单次
/// `GROUP BY origin` 批量查询（非逐源查询），过滤 notShelf 临时书与
/// 本地/WebDAV 书，对齐原版 `BookDao.flowBookshelfSourceOrigins`。
pub fn list_sources_with_bookshelf_counts() -> LegadoResult<Vec<BookSourceListItem>> {
    with_database(|db| {
        let conn = db.connection();
        let counts: std::collections::HashMap<String, i64> = legado_db::BookRepository::new(conn)
            .count_bookshelf_books_by_origin()?
            .into_iter()
            .collect();
        let sources = BookSourceRepository::new(conn).find_all()?;
        Ok(sources
            .into_iter()
            .map(|source| BookSourceListItem {
                bookshelf_count: counts.get(&source.book_source_url).copied().unwrap_or(0),
                source,
            })
            .collect())
    })
}

/// 添加书源（JSON 序列化传入）
pub fn add_source(source_json: &str) -> LegadoResult<BookSource> {
    let source: BookSource = serde_json::from_str(source_json)
        .map_err(|e| LegadoError::Ffi(format!("BookSource JSON 解析失败: {e}")))?;
    let saved = with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.insert_with_check_state(&source)?;
        Ok(source)
    })?;
    // 写库成功后才刷新限速注册表（写库失败经 `?` 提前返回，不触发刷新）；
    // 空值（这里的 `None`/空串）经 refresh 走清除路径，合法值原位刷新
    crate::api::source_rate_limit::refresh_source_rate_limit(
        &saved.book_source_url,
        saved.concurrent_rate.as_deref().unwrap_or(""),
    );
    // [批21-A] 图片动作引擎按书源 URL 缓存：书源新增/覆盖后立即失效，
    // 避免旧 jsLib 引擎继续驻留（缓存另有 jsLib 签名校验兜底）
    legado_js::replace_rule_js::invalidate_image_action_engine(&saved.book_source_url);
    Ok(saved)
}

/// 更新书源
pub fn update_source(source_json: &str) -> LegadoResult<()> {
    let source: BookSource = serde_json::from_str(source_json)
        .map_err(|e| LegadoError::Ffi(format!("BookSource JSON 解析失败: {e}")))?;
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.update_with_check_state(&source)
    })?;
    // 写库成功后才刷新限速注册表（失败经 `?` 提前返回，不触发刷新）；
    // 保存显式 null/空串 → 清除路径（移除该 key 的 limiter），合法值原位刷新
    crate::api::source_rate_limit::refresh_source_rate_limit(
        &source.book_source_url,
        source.concurrent_rate.as_deref().unwrap_or(""),
    );
    // [批21-A] 书源更新后失效图片动作引擎缓存（jsLib/规则变更即时生效）
    legado_js::replace_rule_js::invalidate_image_action_engine(&source.book_source_url);
    Ok(())
}

/// 按 URL 删除书源
pub fn delete_source(source_url: &str) -> LegadoResult<()> {
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.delete(source_url)
    })?;
    // [批21-A] 删除后回收该书的图片动作引擎
    legado_js::replace_rule_js::invalidate_image_action_engine(source_url);
    Ok(())
}

/// 启用书源
pub fn enable_source(source_url: &str) -> LegadoResult<()> {
    set_source_enabled(source_url, true)
}

/// 禁用书源
pub fn disable_source(source_url: &str) -> LegadoResult<()> {
    set_source_enabled(source_url, false)
}

/// 设置书源启用状态
fn set_source_enabled(source_url: &str, enabled: bool) -> LegadoResult<()> {
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        let mut source = repo
            .find_by_url(source_url)?
            .ok_or_else(|| LegadoError::Database("书源不存在".into()))?;
        source.enabled = enabled;
        repo.update_with_check_state(&source)
    })
}

/// 批量导入书源（JSON 数组）
///
/// [P1-1 | 2026-10-01] 整批原子写入：改走 [`BookSourceRepository::insert_batch`]
/// （单事务：任一条失败整批回滚），与 server 侧 `RoomImporter::import_book_sources`
/// 共享 legado-db `in_transaction` 事务边界，不再各自维护一套部分成功语义。
/// 仅整批提交成功后逐个刷新本次实际导入书源（用解析出的书源列表，而非返回值
/// 计数）；任一步失败经 `?` 提前返回，整批均不落库、不刷新。
///
/// 说明：此处不复用 `RoomImporter`（其按 Room 导出格式把规则字段当字符串写入、
/// 且列集不含 `variable`），以免 FFI 线格式（规则为 JSON 对象）的规则与
/// `variable` 被静默丢弃；事务边界与批量写实现仍通过 legado-db 共享。
pub fn import_sources(json_array: &str) -> LegadoResult<i32> {
    let sources: Vec<BookSource> = serde_json::from_str(json_array)
        .map_err(|e| LegadoError::Ffi(format!("书源 JSON 数组解析失败: {e}")))?;
    let count = sources.len() as i32;
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.insert_batch_with_check_state(&sources)
    })?;
    // 整批写库成功后逐个刷新本次导入书源（用实际解析出的书源列表，而非返回值计数）；
    // 任一条目写库失败经 `?` 提前返回，整批均不刷新
    for source in &sources {
        crate::api::source_rate_limit::refresh_source_rate_limit(
            &source.book_source_url,
            source.concurrent_rate.as_deref().unwrap_or(""),
        );
        // [批21-A] 导入覆盖同 URL 书源时失效其图片动作引擎
        legado_js::replace_rule_js::invalidate_image_action_engine(&source.book_source_url);
    }
    Ok(count)
}

/// 导出所有书源为 JSON 数组
pub fn export_sources() -> LegadoResult<Vec<BookSource>> {
    list_sources()
}

/// 获取所有启用的书源
pub fn list_enabled_sources() -> LegadoResult<Vec<BookSource>> {
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_enabled()
    })
}

/// 设置书源自定义变量（契约 §2.3 setSourceVariable，台账 §5.11-3，Task #63）
///
/// 对齐原版 `source.setVariable`：单列 UPDATE 语义仅更新 `variable` 单列，
/// 规避 `updateBookSource` 全行更新风险；空串表示清除该变量。
/// 错误码：书源不存在 → Internal；写入失败 → Db。
pub fn set_source_variable(source_url: &str, variable: &str) -> LegadoResult<()> {
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        let hit = repo.update_variable(source_url, variable)?;
        if !hit {
            return Err(LegadoError::Internal(format!("书源不存在: {source_url}")));
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 辅助：初始化内存数据库并设置全局状态（返回串行锁守卫，测试必须绑定到变量）
    fn setup_test_db() -> std::sync::MutexGuard<'static, ()> {
        crate::db_state::ensure_test_db()
    }

    /// 契约 §2.3：设置后可经查询接口自然带出；空串清除；书源不存在报 Internal
    #[test]
    fn test_set_source_variable() {
        let _db_guard = setup_test_db();
        let url = "https://task63-source-var.example.com";
        add_source(&format!(
            "{{\"bookSourceUrl\":\"{url}\",\"bookSourceName\":\"变量测试源\"}}"
        ))
        .unwrap();

        // 设置变量 → getBookSources 查询自然带出
        set_source_variable(url, "user=abc").unwrap();
        let sources = list_sources().unwrap();
        let found = sources.iter().find(|s| s.book_source_url == url).unwrap();
        assert_eq!(found.variable, "user=abc");

        // 空串 = 清除
        set_source_variable(url, "").unwrap();
        let sources = list_sources().unwrap();
        let found = sources.iter().find(|s| s.book_source_url == url).unwrap();
        assert_eq!(found.variable, "");

        // 书源不存在 → Internal 错误
        let err = set_source_variable("https://task63-not-exist.example.com", "x").unwrap_err();
        assert!(
            matches!(err, LegadoError::Internal(_)),
            "书源不存在应报 Internal"
        );

        // 清理测试书源
        delete_source(url).unwrap();
    }

    // ─── concurrentRate 保存路径刷新（宿主接线） ─────────────────────────────

    /// 构造书源（concurrentRate 可空）
    fn test_source(url: &str, rate: Option<&str>) -> BookSource {
        BookSource {
            book_source_url: url.to_string(),
            book_source_name: "限速刷新测试源".to_string(),
            concurrent_rate: rate.map(str::to_string),
            ..BookSource::default()
        }
    }

    /// 刷新生效判据：limiter 以旧率 1/10000 建立且窗口已用 1 次，保存入口把
    /// 配置刷新为 3/10000 后，携带旧快照的下一次 acquire 必须立即放行；
    /// 未刷新则沿用 1/10000 等满 10s 窗口 → 300ms 超时失败
    async fn assert_stale_acquire_passes(
        registry: &crate::api::source_rate_limit::RateLimiterRegistry,
        stale: &BookSource,
    ) {
        let passed = tokio::time::timeout(
            std::time::Duration::from_millis(300),
            registry.acquire(stale),
        )
        .await;
        assert!(
            passed.is_ok(),
            "保存入口写库成功后必须刷新 ffi registry（旧快照应受新配置约束）"
        );
    }

    /// add 写库成功刷新既有 limiter：同 URL 删除后按新率重新添加
    /// （删除只清 DB 不清 registry，re-add 时刷新可观测）
    #[test]
    fn test_add_source_refreshes_rate_limiter() {
        let _db_guard = setup_test_db();
        let url = "https://ffi-ratelimit-add.example";
        let registry = crate::api::source_rate_limit::registry();

        let v1 = test_source(url, Some("1/10000"));
        add_source(&serde_json::to_string(&v1).unwrap()).unwrap();
        crate::runtime::block_on(registry.acquire(&v1)); // 1/10000 窗口已用 1 次
        delete_source(url).unwrap();

        let v2 = test_source(url, Some("3/10000"));
        add_source(&serde_json::to_string(&v2).unwrap()).unwrap();
        crate::runtime::block_on(assert_stale_acquire_passes(&registry, &v1));

        delete_source(url).unwrap();
    }

    /// update 写库成功刷新既有 limiter：编辑 concurrentRate 后旧快照立即受新率约束
    #[test]
    fn test_update_source_refreshes_rate_limiter() {
        let _db_guard = setup_test_db();
        let url = "https://ffi-ratelimit-update.example";
        let registry = crate::api::source_rate_limit::registry();

        let v1 = test_source(url, Some("1/10000"));
        add_source(&serde_json::to_string(&v1).unwrap()).unwrap();
        crate::runtime::block_on(registry.acquire(&v1)); // 1/10000 窗口已用 1 次

        let v2 = test_source(url, Some("3/10000"));
        update_source(&serde_json::to_string(&v2).unwrap()).unwrap();
        crate::runtime::block_on(assert_stale_acquire_passes(&registry, &v1));

        delete_source(url).unwrap();
    }

    /// update 清除 concurrentRate（缺省 None 或空串）：registry 移除该 key 的
    /// limiter，旧快照下一次 acquire 立即放行（不再受已用满的旧窗口约束）
    #[test]
    fn test_update_source_clears_rate_limiter_when_rate_removed() {
        let _db_guard = setup_test_db();
        let url = "https://ffi-ratelimit-clear.example";
        let registry = crate::api::source_rate_limit::registry();

        let v1 = test_source(url, Some("1/10000"));
        add_source(&serde_json::to_string(&v1).unwrap()).unwrap();
        crate::runtime::block_on(registry.acquire(&v1)); // 旧率窗口已用 1 次

        // 保存时 concurrentRate 缺省（None）→ DB 清空 + registry 移除
        let cleared = test_source(url, None);
        update_source(&serde_json::to_string(&cleared).unwrap()).unwrap();
        let found = list_sources()
            .unwrap()
            .into_iter()
            .find(|s| s.book_source_url == url)
            .expect("书源仍存在");
        assert!(
            found.concurrent_rate.is_none(),
            "缺省保存应清空 DB 内 concurrentRate"
        );
        crate::runtime::block_on(assert_stale_acquire_passes(&registry, &v1));

        // 空串同样走清除路径（registry 移除既有 limiter）
        let v2 = test_source(url, Some("2/10000"));
        update_source(&serde_json::to_string(&v2).unwrap()).unwrap();
        crate::runtime::block_on(registry.acquire(&v2)); // 新窗口已用 1 次
        let empty = test_source(url, Some(""));
        update_source(&serde_json::to_string(&empty).unwrap()).unwrap();
        crate::runtime::block_on(assert_stale_acquire_passes(&registry, &v2));

        delete_source(url).unwrap();
    }

    /// import 批量写库成功后按实际书源列表逐个刷新（先有 in-flight limiter 的
    /// URL 被导入新率时，旧快照立即受新率约束）
    #[test]
    fn test_import_sources_refreshes_rate_limiter() {
        let _db_guard = setup_test_db();
        let url = "https://ffi-ratelimit-import.example";
        let registry = crate::api::source_rate_limit::registry();

        let stale = test_source(url, Some("1/10000"));
        crate::runtime::block_on(registry.acquire(&stale)); // URL 尚未入库，先有 in-flight limiter（窗口已用 1 次）

        let imported = serde_json::to_string(&vec![test_source(url, Some("3/10000"))]).unwrap();
        assert_eq!(import_sources(&imported).unwrap(), 1);
        crate::runtime::block_on(assert_stale_acquire_passes(&registry, &stale));

        delete_source(url).unwrap();
    }

    /// [P1-1] 批量导入出口整批原子：第 1 条合法、第 2 条非法（数值不是
    /// 书源对象）→ 整批失败且数据库零新增（不残留第 1 条）；合法批次仍全部写入
    #[test]
    fn test_import_sources_batch_is_atomic() {
        let _db_guard = setup_test_db();
        let url_ok = "https://ffi-batch-atomic-ok.example";
        let url_ok2 = "https://ffi-batch-atomic-ok2.example";

        // 第 2 条非法 → 整批失败，第 1 条不得落库
        let bad_batch =
            format!(r#"[{{"bookSourceUrl":"{url_ok}","bookSourceName":"批量合法源"}},42]"#);
        assert!(import_sources(&bad_batch).is_err());
        let after_fail = list_sources().unwrap();
        assert!(
            after_fail.iter().all(|s| s.book_source_url != url_ok),
            "整批失败时第 1 条不得残留（无部分成功态）"
        );

        // 合法批次仍整批提交
        let good_batch = format!(
            r#"[{{"bookSourceUrl":"{url_ok}","bookSourceName":"批量合法源"}},
               {{"bookSourceUrl":"{url_ok2}","bookSourceName":"批量合法源二"}}]"#
        );
        assert_eq!(import_sources(&good_batch).unwrap(), 2);
        let after_ok = list_sources().unwrap();
        assert_eq!(
            after_ok
                .iter()
                .filter(|s| s.book_source_url == url_ok || s.book_source_url == url_ok2)
                .count(),
            2,
            "成功批次应整批落库"
        );

        delete_source(url_ok).unwrap();
        delete_source(url_ok2).unwrap();
    }

    /// 批28b（P2-1 红→绿）：`ruleContent.maxBatchSize` 为数字字符串时
    /// 整批导入仍成功（Gson 宽松口径），且值按 20 落库
    ///
    /// 修复前 `Option<i32>` 严格解析报错 → `import_sources` 整数组解析失败，
    /// 批28 之前该键被忽略、源可导入，属新增失败模式。
    #[test]
    fn test_import_sources_lenient_max_batch_size_string() {
        let _db_guard = setup_test_db();
        let url = "https://ffi-lenient-maxbatch.example";

        let batch = format!(
            r#"[{{"bookSourceUrl":"{url}","bookSourceName":"宽松批量源",
                 "ruleContent":{{"contentBatch":"batch@js:result","maxBatchSize":"20"}}}}]"#
        );
        assert_eq!(
            import_sources(&batch).unwrap(),
            1,
            "maxBatchSize 字符串数字不得击穿整批导入"
        );

        let sources = list_sources().unwrap();
        let source = sources
            .into_iter()
            .find(|s| s.book_source_url == url)
            .expect("宽松书源应落库");
        let rule = source.rule_content.expect("正文规则应落库");
        assert_eq!(rule.content_batch.as_deref(), Some("batch@js:result"));
        assert_eq!(
            rule.max_batch_size,
            Some(20),
            "\"20\" 应按 Gson 口径落为 20"
        );

        delete_source(url).unwrap();
    }

    /// [批31] `getBookSources` 返回项加法式 `bookshelfCount`：
    /// - 多源分别计数、零本源为 0；
    /// - notShelf 临时书不计；
    /// - 序列化 JSON 含 `bookshelfCount` 且其余书源字段形状不变；
    /// - `list_sources`（导出/备份路径）返回模型本身，不携带计数字段。
    #[test]
    fn test_source_list_includes_bookshelf_counts() {
        use legado_core::models::Book;
        use legado_db::repository::Repository;
        use legado_db::BookRepository;

        let _db_guard = setup_test_db();
        let url_a = "https://ffi-bookshelf-count-a.example";
        let url_b = "https://ffi-bookshelf-count-b.example";
        let url_zero = "https://ffi-bookshelf-count-zero.example";
        for (url, name) in [(url_a, "计数源A"), (url_b, "计数源B"), (url_zero, "零本源")] {
            add_source(&format!(
                "{{\"bookSourceUrl\":\"{url}\",\"bookSourceName\":\"{name}\"}}"
            ))
            .unwrap();
        }

        let book = |url: &str, origin: &str, ty: i32| Book {
            book_url: url.to_string(),
            origin: origin.to_string(),
            // name/author 唯一索引：逐书给唯一值，避免 INSERT OR REPLACE
            // 把同名同作者的前一条移走（测试种子互相覆盖）
            name: url.to_string(),
            author: "计数作者".to_string(),
            book_type: ty,
            ..Book::default()
        };
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            repo.insert(&book("https://book.example/a1", url_a, 8))
                .unwrap();
            repo.insert(&book("https://book.example/a2", url_a, 8))
                .unwrap();
            repo.insert(&book("https://book.example/b1", url_b, 8))
                .unwrap();
            // 搜索页临时书（notShelf=1024）不计入
            repo.insert(&book("https://book.example/temp", url_a, 8 | 1024))
                .unwrap();
            Ok(())
        })
        .unwrap();

        let items = list_sources_with_bookshelf_counts().unwrap();
        let count_of = |url: &str| {
            items
                .iter()
                .find(|i| i.source.book_source_url == url)
                .map(|i| i.bookshelf_count)
                .unwrap_or(-1)
        };
        assert_eq!(count_of(url_a), 2);
        assert_eq!(count_of(url_b), 1);
        assert_eq!(count_of(url_zero), 0, "零本书源应输出 0 而非缺键");

        // JSON 形状：`bookshelfCount` 与既有源字段平铺（不嵌套）
        let item = items
            .iter()
            .find(|i| i.source.book_source_url == url_a)
            .unwrap();
        let json = serde_json::to_value(item).unwrap();
        assert_eq!(json["bookshelfCount"], 2);
        assert_eq!(json["bookSourceUrl"], url_a);
        assert_eq!(json["bookSourceName"], "计数源A");

        // 导出/备份路径（list_sources）仍返回书源模型本身（无计数字段）
        let exported = list_sources().unwrap();
        let exported_item = exported
            .iter()
            .find(|s| s.book_source_url == url_a)
            .expect("导出路径应包含书源");
        // [批31b P3-4] 导出/备份 JSON 形状断言：派生 bookshelfCount 不得外泄
        //（否则源导出文件/zip 备份会携带计算字段，重新导入后被持久化污染）
        let exported_json = serde_json::to_value(exported_item).unwrap();
        assert!(
            exported_json.get("bookshelfCount").is_none(),
            "导出/备份 JSON 不得携带派生 bookshelfCount（实际 {exported_json}）"
        );
        assert_eq!(exported_json["bookSourceUrl"], url_a);
        assert_eq!(exported_json["bookSourceName"], "计数源A");

        for url in [url_a, url_b, url_zero] {
            delete_source(url).unwrap();
        }
    }
}
