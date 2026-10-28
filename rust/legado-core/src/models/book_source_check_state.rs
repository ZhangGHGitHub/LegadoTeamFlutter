//! 书源检验状态实体（对齐原版 `BookSourceCheckState.kt`）
//!
//! 原版定义（upstream `app/src/main/java/io/legado/app/data/entities/
//! BookSourceCheckState.kt`）：
//!
//! ```kotlin
//! @Entity(
//!     tableName = "book_source_check_states",
//!     foreignKeys = [ForeignKey(
//!         entity = BookSource::class,
//!         parentColumns = ["bookSourceUrl"],
//!         childColumns = ["bookSourceUrl"],
//!         onDelete = ForeignKey.CASCADE,
//!     )],
//! )
//! data class BookSourceCheckState(
//!     @PrimaryKey val bookSourceUrl: String,
//!     val revision: String = UUID.randomUUID().toString(),
//!     val sourceRevision: String = UUID.randomUUID().toString(),
//!     val status: String = NEEDS_CHECK,
//!     val checkedAt: Long = 0,
//!     val detail: String = "",
//! )
//! ```
//!
//! 语义（设备本地元数据，不进入书源导入/导出 JSON）：
//! - `revision`：一次检验任务的令牌。`startBookSourceCheck` 开始时重置为新值，
//!   检验结果写回以 `(bookSourceUrl, revision, status='NEEDS_CHECK')` 为条件，
//!   实现「旧任务结果不覆盖新任务」的 CAS；
//! - `sourceRevision`：书源规则内容版本。书源保存且 `checkContent()` 变化时
//!   重新生成，检验开始时不改；网页端用它与本地内容快照比对，判断状态是否
//!   仍然适用于当前源内容；
//! - `status`：`NEEDS_CHECK` / `PASSED` / `FAILED` / `UNCHECKABLE`；
//! - `checkedAt`：检验完成时间（毫秒时间戳；`NEEDS_CHECK` 时为 0）；
//! - `detail`：失败详情（原版：失效分组 + 结果消息 + `// Error: {本次异常}`，
//!   以 `" | "` 连接；第三段来自本次失败异常——上游 `doCheckSource` 先
//!   `removeErrorComment()` 剥离历史、失败时 `addErrorComment(本次)` 前置，
//!   故与库内历史注释无关；`PASSED` 恒为空串、`UNCHECKABLE` 无第三段）。

use serde::{Deserialize, Serialize};

/// 检验状态取值（对齐原版 `BookSourceCheckState` companion object 常量）
pub mod check_status {
    /// 需要检验（新建源 / 规则变更后 / 检验进行中）
    pub const NEEDS_CHECK: &str = "NEEDS_CHECK";
    /// 检验成功
    pub const PASSED: &str = "PASSED";
    /// 检验失败
    pub const FAILED: &str = "FAILED";
    /// 无法校验（原版：启用「源地址可访问性」检查时源地址不是 http 链接）
    pub const UNCHECKABLE: &str = "UNCHECKABLE";
}

/// 书源检验状态
///
/// 字段名与序列化键逐字对齐原版 Room 实体（Gson 输出键名），供网页端
/// `getBookSourceCheckStates` / `getBookSourcesForManagement` 直接消费。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BookSourceCheckState {
    /// 书源地址（主键，外键 `book_sources.bookSourceUrl`，删除级联）
    #[serde(rename = "bookSourceUrl")]
    pub book_source_url: String,
    /// 检验任务令牌（每次开始检验重置）
    #[serde(default)]
    pub revision: String,
    /// 书源规则内容版本（内容变更时重置）
    #[serde(rename = "sourceRevision", default)]
    pub source_revision: String,
    /// 检验状态（`check_status::*`）
    #[serde(default = "default_status")]
    pub status: String,
    /// 检验完成时间（毫秒；未检验为 0）
    #[serde(rename = "checkedAt", default)]
    pub checked_at: i64,
    /// 失败详情（成功恒为空串）
    #[serde(default)]
    pub detail: String,
}

fn default_status() -> String {
    check_status::NEEDS_CHECK.to_string()
}

impl Default for BookSourceCheckState {
    fn default() -> Self {
        Self {
            book_source_url: String::new(),
            revision: String::new(),
            source_revision: String::new(),
            status: check_status::NEEDS_CHECK.to_string(),
            checked_at: 0,
            detail: String::new(),
        }
    }
}

impl BookSourceCheckState {
    /// 新建状态（对齐 Kotlin 构造器默认值：两个 revision 均为随机 UUID）
    ///
    /// 用于：书源新建 / 规则内容变更 / 检验开始前的排队重置。
    pub fn new(book_source_url: impl Into<String>) -> Self {
        Self {
            book_source_url: book_source_url.into(),
            revision: uuid::Uuid::new_v4().to_string(),
            source_revision: uuid::Uuid::new_v4().to_string(),
            status: check_status::NEEDS_CHECK.to_string(),
            checked_at: 0,
            detail: String::new(),
        }
    }

    /// 缺行时的 coalesce 默认值（对齐原版 `book_sources_part` 视图
    /// `coalesce(c.status, 'NEEDS_CHECK')` 等表达式：空 revision）
    pub fn missing(book_source_url: impl Into<String>) -> Self {
        Self {
            book_source_url: book_source_url.into(),
            ..Self::default()
        }
    }

    /// 开始检验时的排队重置：新 `revision`、保留 `sourceRevision`、
    /// 状态回到 `NEEDS_CHECK`、清空时间与详情
    ///
    /// 对齐原版 `BookSourceDao.beginCheck`：
    /// `BookSourceCheckState(selected.bookSourceUrl, sourceRevision = current.sourceRevision)`。
    pub fn begin_check(&self) -> Self {
        Self {
            book_source_url: self.book_source_url.clone(),
            revision: uuid::Uuid::new_v4().to_string(),
            source_revision: self.source_revision.clone(),
            status: check_status::NEEDS_CHECK.to_string(),
            checked_at: 0,
            detail: String::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_generates_distinct_revisions() {
        let a = BookSourceCheckState::new("https://a.example.com");
        let b = BookSourceCheckState::new("https://a.example.com");
        assert_eq!(a.status, check_status::NEEDS_CHECK);
        assert_eq!(a.checked_at, 0);
        assert!(a.detail.is_empty());
        assert_ne!(a.revision, a.source_revision);
        assert_ne!(a.revision, b.revision);
        assert_ne!(a.source_revision, b.source_revision);
    }

    #[test]
    fn test_begin_check_keeps_source_revision() {
        let mut state = BookSourceCheckState::new("https://a.example.com");
        state.status = check_status::PASSED.to_string();
        state.checked_at = 123;
        state.detail = "旧详情".to_string();
        let queued = state.begin_check();
        assert_eq!(queued.source_revision, state.source_revision);
        assert_ne!(queued.revision, state.revision);
        assert_eq!(queued.status, check_status::NEEDS_CHECK);
        assert_eq!(queued.checked_at, 0);
        assert!(queued.detail.is_empty());
    }

    #[test]
    fn test_json_shape_matches_kotlin_entity() {
        let state = BookSourceCheckState {
            book_source_url: "https://a.example.com".to_string(),
            revision: "r1".to_string(),
            source_revision: "s1".to_string(),
            status: "PASSED".to_string(),
            checked_at: 42,
            detail: "d".to_string(),
        };
        let value = serde_json::to_value(&state).unwrap();
        let mut keys: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(|k| k.as_str())
            .collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            vec![
                "bookSourceUrl",
                "checkedAt",
                "detail",
                "revision",
                "sourceRevision",
                "status"
            ]
        );
        assert_eq!(value["bookSourceUrl"], "https://a.example.com");
        assert_eq!(value["sourceRevision"], "s1");
        assert_eq!(value["checkedAt"], 42);
    }

    #[test]
    fn test_missing_defaults() {
        let state = BookSourceCheckState::missing("u");
        assert_eq!(state.status, check_status::NEEDS_CHECK);
        assert_eq!(state.revision, "");
        assert_eq!(state.source_revision, "");
    }
}
