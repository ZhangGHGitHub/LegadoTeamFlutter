//! 下载任务模型
//!
//! 包含离线章节下载相关的结构体和枚举。

use serde::{Deserialize, Serialize};

/// 下载任务状态
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub enum DownloadStatus {
    /// 待处理 - 等待进入下载队列
    #[default]
    Pending,
    /// 下载中 - 正在进行网络请求
    Downloading,
    /// 已完成 - 成功下载到本地存储
    Completed,
    /// 失败 - 下载出错，包含错误信息
    Failed(String),
    /// 已暂停 - 用户手动暂停
    Paused,
}

/// 下载任务
///
/// 用于管理书籍章节的离线下载，支持优先级、重试机制、进度追踪等功能。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadTask {
    /// 任务唯一标识 (bookUrl_chapterIndex)
    pub id: String,
    /// 书籍 URL
    pub book_url: String,
    /// 章节 URL
    pub chapter_url: String,
    /// 章节标题
    pub chapter_title: String,
    /// 章节索引 (从 0 开始)
    pub chapter_index: i32,
    /// 下载状态
    pub status: DownloadStatus,
    /// 进度 (0.0 - 1.0)，其中 0.0 表示未开始，1.0 表示完成
    pub progress: f64,
    /// 优先级 (越小越优先)，默认情况下新任务优先级较高（值较小）
    pub priority: i32,
    /// 创建时间 (毫秒时间戳)
    pub created_at: i64,
    /// 完成时间 (可选，仅当状态为 Completed 时设置)
    pub completed_at: Option<i64>,
    /// 错误信息 (可选，仅当状态为 Failed 时设置)
    pub error: Option<String>,
    // 重试元数据
    /// 连续失败次数，用于指数退避算法
    pub fail_count: u32,
    /// 上次重试时间 (毫秒时间戳)
    pub last_retry_at: Option<i64>,
    /// 下次允许重试的时间 (毫秒时间戳)，用于实现延迟重试
    pub next_retry_at: Option<i64>,
    // 断点续传元数据
    /// 已下载的字节数，用于断点续传
    pub downloaded_bytes: i64,
    /// 最大重试次数 (默认 3)，超过后标记为永久失败
    pub max_retry_count: u32,
}

impl DownloadTask {
    /// 创建新的下载任务
    ///
    /// # 参数
    /// - `id`: 任务 ID
    /// - `book_url`: 书籍 URL
    /// - `chapter_url`: 章节 URL
    /// - `chapter_title`: 章节标题
    /// - `chapter_index`: 章节索引
    /// - `priority`: 优先级 (默认为 0，越小越优先)
    ///
    /// # 示例
    /// ```
    /// use legado_core::models::DownloadTask;
    /// let task = DownloadTask::new(
    ///     "book1_0",
    ///     "http://example.com/book",
    ///     "http://example.com/ch1",
    ///     "第一章",
    ///     0,
    ///     10,
    /// );
    /// ```
    pub fn new(
        id: &str,
        book_url: &str,
        chapter_url: &str,
        chapter_title: &str,
        chapter_index: i32,
        priority: i32,
    ) -> Self {
        Self {
            id: id.to_string(),
            book_url: book_url.to_string(),
            chapter_url: chapter_url.to_string(),
            chapter_title: chapter_title.to_string(),
            chapter_index,
            status: DownloadStatus::default(),
            progress: 0.0,
            priority,
            created_at: Self::now_millis(),
            completed_at: None,
            error: None,
            fail_count: 0,
            last_retry_at: None,
            next_retry_at: None,
            downloaded_bytes: 0,
            max_retry_count: 3,
        }
    }

    /// 获取当前毫秒时间戳
    fn now_millis() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64
    }

    /// 检查是否可以重试
    ///
    /// 如果满足以下条件则返回 true:
    /// - 状态为 Failed
    /// - 失败次数未超过最大重试次数
    /// - next_retry_at 为空或已过时
    pub fn can_retry(&self) -> bool {
        matches!(self.status, DownloadStatus::Failed(_))
            && self.fail_count < self.max_retry_count
            && self
                .next_retry_at
                .map(|t| t <= Self::now_millis())
                .unwrap_or(true)
    }

    /// 检查是否已超过最大重试次数（永久失败）
    pub fn is_permanently_failed(&self) -> bool {
        matches!(self.status, DownloadStatus::Failed(_))
            && self.fail_count >= self.max_retry_count
    }

    /// 更新已下载字节数（断点续传）
    pub fn update_downloaded_bytes(&mut self, bytes: i64) {
        self.downloaded_bytes = bytes;
    }

    /// 构建 HTTP Range 请求头值（断点续传）
    ///
    /// 如果已有部分下载，返回 `bytes={downloaded_bytes}-` 格式；
    /// 否则返回 None 表示从头下载。
    pub fn range_header(&self) -> Option<String> {
        if self.downloaded_bytes > 0 {
            Some(format!("bytes={}-", self.downloaded_bytes))
        } else {
            None
        }
    }

    /// 设置重试时间（使用指数退避算法）
    ///
    /// # 参数
    /// - `fail_count`: 当前失败次数
    /// - `max_delay_ms`: 最大延迟 (毫秒), 默认 60 秒
    ///
    /// # 示例
    /// fail_count: 1 -> 2 秒
    /// fail_count: 2 -> 4 秒
    /// fail_count: 3 -> 8 秒
    /// ...
    /// fail_count: 7 -> 60 秒 (达到最大值)
    pub fn set_retry_delay(&mut self, fail_count: u32, max_delay_ms: i64) {
        let base_ms: i64 = 1000; // 1 秒起始
        let delay = base_ms.saturating_mul(2i64.saturating_pow(fail_count));
        let actual_delay = delay.min(max_delay_ms);
        
        self.last_retry_at = Some(Self::now_millis());
        self.next_retry_at = Some(self.last_retry_at.unwrap() + actual_delay);
    }

    /// 降级任务优先级
    ///
    /// 当连续失败多次后调用此方法降低任务优先级。
    pub fn degrade_priority(&mut self) {
        self.priority = 1000; // 设置为低优先级
    }
}
