//! 视频播放状态机
//!
//! 移植自 Kotlin `VideoPlay.kt` / `VideoPlayService.kt` 的核心逻辑，实现：
//! - 卷（Volume）/ 剧集（Episode）目录组织（对齐 `VideoPlay.upEpisodes`）
//! - 剧集切换与边界判断（对齐 `VideoPlay.upDurIndex`）
//! - 播放状态机（Idle → Loading → Playing ⇄ Paused → Completed / Error）
//! - 播放进度管理（对齐 `VideoPlay.saveRead` / `durChapterPos`）
//! - 弹幕来源解析（对齐 `BookChapter.getDanmaku`）
//! - MPD 清单内容检测（对齐 `VideoPlay.startPlay` 中 `content.startsWith("<")`）
//!
//! # 平台边界说明
//!
//! Kotlin 侧的 `VideoPlayService.kt` 为纯 Android 表现层（悬浮窗、MediaSession、
//! 通知栏、触摸手势），无法迁移到 Rust 无头运行时；本模块仅承载与平台无关的
//! 状态与规则逻辑。真实播放器（ExoPlayer/GSYVideoPlayer）的渲染、视频解码、
//! 流媒体缓冲仍由 Flutter / 平台侧负责。

use crate::models::BookChapter;

/// 视频播放状态
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayState {
    /// 空闲（未加载任何资源）
    Idle,
    /// 正在加载视频源（解析规则 / 请求正文）
    Loading,
    /// 正在播放
    Playing,
    /// 已暂停
    Paused,
    /// 播放完成
    Completed,
    /// 出错（附错误信息见 `VideoPlayerState.last_error`）
    Error,
}

impl PlayState {
    /// 是否处于可播放状态（播放中或暂停）
    pub fn is_active(&self) -> bool {
        matches!(self, PlayState::Playing | PlayState::Paused)
    }
}

/// 弹幕数据来源
///
/// 对齐 Kotlin `BookChapter.getDanmaku()`：
/// `variableMap["danmaku"] ?: getDanmakuFile(bookUrl, url)`
#[derive(Debug, Clone, PartialEq)]
pub enum DanmakuSource {
    /// 无弹幕
    None,
    /// 内联弹幕字符串（JSON / XML 文本，来自章节变量 `danmaku`）
    Inline(String),
    /// 弹幕文件路径（来自 `RuleBigDataHelp.getDanmakuFile`）
    File(String),
}

impl DanmakuSource {
    /// 是否存在弹幕
    pub fn is_present(&self) -> bool {
        !matches!(self, DanmakuSource::None)
    }
}

/// 视频播放进度
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VideoProgress {
    /// 当前卷索引（对齐 `durVolumeIndex`）
    pub volume_index: i32,
    /// 当前剧集在卷内索引（对齐 `chapterInVolumeIndex`）
    pub episode_index: i32,
    /// 本集播放位置（毫秒，对齐 `durChapterPos`）
    pub position_ms: i64,
}

/// 视频播放状态机
///
/// 管理卷/剧集目录、播放状态、进度与弹幕。
/// 对齐 Kotlin `VideoPlay` 单例的核心字段与方法。
#[derive(Debug, Clone)]
pub struct VideoPlayerState {
    /// 完整目录（含卷与章节，对齐 `toc`）
    toc: Vec<BookChapter>,
    /// 卷列表（`is_volume == true` 的章节，对齐 `volumes`）
    volumes: Vec<BookChapter>,
    /// 当前卷内的剧集列表（对齐 `episodes`）
    episodes: Vec<BookChapter>,

    /// 当前卷索引（对齐 `durVolumeIndex`）
    dur_volume_index: i32,
    /// 当前剧集在卷内索引（对齐 `chapterInVolumeIndex`）
    chapter_in_volume_index: i32,
    /// 本集播放位置（毫秒，对齐 `durChapterPos`）
    dur_chapter_pos: i64,

    /// 播放状态
    play_state: PlayState,
    /// 最近一次错误信息
    last_error: Option<String>,

    /// 当前解析出的视频播放链接（对齐 `videoUrl`）
    video_url: Option<String>,
    /// 当前视频标题（对齐 `videoTitle`）
    video_title: Option<String>,
    /// 是否单链接模式（对齐 `singleUrl`，非书籍/RSS 的直链播放）
    single_url: bool,

    /// 是否自动播放（对齐 `autoPlay`）
    auto_play: bool,
    /// 弹幕显示开关（对齐 `danmakuShow`）
    danmaku_show: bool,
    /// 当前弹幕来源
    danmaku: DanmakuSource,
}

impl VideoPlayerState {
    /// 创建空的视频播放状态机
    pub fn new() -> Self {
        Self {
            toc: Vec::new(),
            volumes: Vec::new(),
            episodes: Vec::new(),
            dur_volume_index: 0,
            chapter_in_volume_index: 0,
            dur_chapter_pos: 0,
            play_state: PlayState::Idle,
            last_error: None,
            video_url: None,
            video_title: None,
            single_url: false,
            auto_play: true,
            danmaku_show: true,
            danmaku: DanmakuSource::None,
        }
    }

    // ===== 目录组织 =====

    /// 从完整目录初始化卷列表并刷新剧集
    ///
    /// 对齐 Kotlin `VideoPlay.initSource` 中的卷提取 + `upEpisodes`。
    pub fn init_toc(&mut self, toc: Vec<BookChapter>) {
        self.volumes = toc.iter().filter(|c| c.is_volume).cloned().collect();
        self.toc = toc;
        self.up_episodes();
    }

    /// 刷新当前卷内的剧集列表
    ///
    /// 对齐 Kotlin `VideoPlay.upEpisodes`：
    /// - 无卷：剧集 = 整个目录
    /// - 有卷：剧集 = 当前卷之后到下一卷之前的章节
    pub fn up_episodes(&mut self) {
        if self.volumes.is_empty() {
            // 没有卷目录，整个目录即为剧集列表
            self.episodes = self.toc.clone();
            return;
        }
        // 约束卷索引范围
        if self.dur_volume_index < 0 || self.dur_volume_index as usize >= self.volumes.len() {
            self.dur_volume_index = 0;
        }
        let start_int = self
            .volumes
            .get(self.dur_volume_index as usize)
            .map(|v| v.index)
            .unwrap_or(0);
        let end_int = self
            .volumes
            .get(self.dur_volume_index as usize + 1)
            .map(|v| v.index)
            .unwrap_or(self.toc.len() as i32);
        // 剧集为 (start_int + 1) .. end_int 区间（跳过卷标题本身）
        let start = (start_int + 1).max(0) as usize;
        let end = (end_int as usize).min(self.toc.len());
        self.episodes = if start < end {
            self.toc[start..end].to_vec()
        } else {
            Vec::new()
        };
    }

    // ===== 剧集切换 =====

    /// 按偏移切换剧集
    ///
    /// 对齐 Kotlin `VideoPlay.upDurIndex(offset, player)`：
    /// - 越界返回 false（已到开头 / 已播放完）
    /// - 成功则更新索引、清零进度并刷新当前剧集
    pub fn up_dur_index(&mut self, offset: i32) -> bool {
        if self.episodes.is_empty() {
            return false;
        }
        let index = self.chapter_in_volume_index + offset;
        if index < 0 {
            // 已到开头
            return false;
        }
        if index as usize >= self.episodes.len() {
            // 已播放完
            return false;
        }
        self.chapter_in_volume_index = index;
        self.dur_chapter_pos = 0;
        self.refresh_current_episode();
        true
    }

    /// 切换到下一集（播放完成时调用）
    ///
    /// 返回是否成功切换。对齐 `VideoPlayService.onAutoComplete` 中的
    /// `VideoPlay.upDurIndex(1, playerView)`。
    pub fn next_episode(&mut self) -> bool {
        self.up_dur_index(1)
    }

    /// 切换到上一集
    pub fn prev_episode(&mut self) -> bool {
        self.up_dur_index(-1)
    }

    /// 刷新当前剧集的播放链接与标题
    ///
    /// 从 `episodes[chapter_in_volume_index]` 读取 url / title。
    /// 对齐 Kotlin `VideoPlay.startPlay` 中确定 `chapter` 的逻辑。
    fn refresh_current_episode(&mut self) {
        // 先提取所需数据，避免借用冲突
        let episode = self
            .episodes
            .get(self.chapter_in_volume_index as usize)
            .map(|ep| (ep.url.clone(), ep.title.clone()));
        match episode {
            Some((url, title)) => {
                // 卷章节链接以标题开头表示未获取到真实链接（对齐 VideoPlay.startPlay）
                if !title.is_empty() && url.starts_with(&title) {
                    self.video_url = None;
                } else {
                    self.video_url = Some(url);
                }
                self.video_title = Some(title);
            }
            None => {
                self.video_url = None;
            }
        }
    }

    // ===== 播放状态迁移 =====

    /// 标记开始加载视频源
    pub fn start_loading(&mut self) {
        self.play_state = PlayState::Loading;
        self.last_error = None;
    }

    /// 标记视频源解析完成、开始播放
    ///
    /// 对齐 `VideoPlay.startPlay` 中 `player.setUp(...)` + `startPlayLogic()`。
    pub fn start_play(&mut self, video_url: String) {
        self.video_url = Some(video_url);
        self.play_state = if self.auto_play {
            PlayState::Playing
        } else {
            PlayState::Paused
        };
        self.last_error = None;
    }

    /// 暂停播放（对齐 `VideoPlay.onPause`）
    pub fn pause(&mut self) {
        if self.play_state == PlayState::Playing {
            self.play_state = PlayState::Paused;
        }
    }

    /// 恢复播放（对齐 `VideoPlay.onResume`）
    pub fn resume(&mut self) {
        if self.play_state == PlayState::Paused {
            self.play_state = PlayState::Playing;
        }
    }

    /// 标记播放完成（对齐 `GSYSampleCallBack.onAutoComplete`）
    pub fn complete(&mut self) {
        self.play_state = PlayState::Completed;
    }

    /// 标记出错
    pub fn fail(&mut self, msg: String) {
        self.last_error = Some(msg);
        self.play_state = PlayState::Error;
    }

    /// 释放并重置所有状态（对齐 `VideoPlay.releaseAllVideos`）
    pub fn release(&mut self) {
        self.play_state = PlayState::Idle;
        self.video_url = None;
        self.video_title = None;
        self.single_url = false;
        self.dur_chapter_pos = 0;
        self.chapter_in_volume_index = 0;
        self.dur_volume_index = 0;
        self.danmaku = DanmakuSource::None;
        self.last_error = None;
    }

    // ===== 进度管理 =====

    /// 更新本集播放位置（毫秒）
    ///
    /// 对齐 `VideoPlay.saveRead(durPos)` 中的 `durChapterPos = durPos`。
    pub fn update_progress(&mut self, position_ms: i64) {
        self.dur_chapter_pos = position_ms.max(0);
    }

    /// 获取当前播放进度快照
    pub fn progress(&self) -> VideoProgress {
        VideoProgress {
            volume_index: self.dur_volume_index,
            episode_index: self.chapter_in_volume_index,
            position_ms: self.dur_chapter_pos,
        }
    }

    /// 恢复播放进度（跳转）
    pub fn restore_progress(&mut self, progress: VideoProgress) {
        self.dur_volume_index = progress.volume_index;
        self.chapter_in_volume_index = progress.episode_index;
        self.dur_chapter_pos = progress.position_ms;
        self.up_episodes();
        self.refresh_current_episode();
    }

    // ===== 弹幕 =====

    /// 从章节变量与文件路径解析弹幕来源
    ///
    /// 对齐 Kotlin `BookChapter.getDanmaku()`：
    /// `variableMap["danmaku"] ?: getDanmakuFile(bookUrl, url)`
    ///
    /// - `inline_danmaku`: 章节变量中的 `danmaku` 值（可能为 JSON/XML 字符串）
    /// - `danmaku_file_path`: `RuleBigDataHelp.getDanmakuFile` 返回的文件路径（可能不存在）
    pub fn resolve_danmaku(
        &mut self,
        inline_danmaku: Option<String>,
        danmaku_file_path: Option<String>,
    ) {
        self.danmaku = if let Some(inline) = inline_danmaku.filter(|s| !s.is_empty()) {
            DanmakuSource::Inline(inline)
        } else if let Some(path) = danmaku_file_path.filter(|s| !s.is_empty()) {
            DanmakuSource::File(path)
        } else {
            DanmakuSource::None
        };
    }

    /// 清空弹幕（对齐 `VideoPlay.startPlay` 开头的 `danmakuStr = null`）
    pub fn clear_danmaku(&mut self) {
        self.danmaku = DanmakuSource::None;
    }

    // ===== 视频源解析辅助 =====

    /// 检测正文内容是否为 MPD 清单文本
    ///
    /// 对齐 Kotlin `VideoPlay.startPlay`：
    /// `content.startsWith("<")` 时当作 MPD 文本写入临时文件。
    pub fn is_mpd_content(content: &str) -> bool {
        content.trim_start().starts_with('<')
    }

    /// 规范化视频正文内容
    ///
    /// 对齐 Kotlin `VideoPlay.startPlay` 中对 `content` 的处理：
    /// - 空内容 → 返回 `None`（对应 `ContentEmptyException("正文为空")`）
    /// - 以 `<` 开头 → 视为 MPD 清单，返回 `Mpd` 变体
    /// - 否则 → 视为直接 URL，返回 `Url` 变体
    pub fn normalize_content(content: &str) -> Option<VideoContent> {
        let trimmed = content.trim();
        if trimmed.is_empty() {
            return None;
        }
        if Self::is_mpd_content(trimmed) {
            Some(VideoContent::Mpd(trimmed.to_string()))
        } else {
            Some(VideoContent::Url(trimmed.to_string()))
        }
    }

    // ===== Getters / Setters =====

    /// 当前剧集（可能为空）
    pub fn current_episode(&self) -> Option<&BookChapter> {
        self.episodes.get(self.chapter_in_volume_index as usize)
    }

    /// 当前卷（可能为空）
    pub fn current_volume(&self) -> Option<&BookChapter> {
        self.volumes.get(self.dur_volume_index as usize)
    }

    /// 当前卷内剧集列表
    pub fn episodes(&self) -> &[BookChapter] {
        &self.episodes
    }

    /// 卷列表
    pub fn volumes(&self) -> &[BookChapter] {
        &self.volumes
    }

    /// 剧集总数（当前卷内）
    pub fn episode_count(&self) -> usize {
        self.episodes.len()
    }

    /// 是否有下一集
    pub fn has_next_episode(&self) -> bool {
        (self.chapter_in_volume_index as usize + 1) < self.episodes.len()
    }

    /// 是否有上一集
    pub fn has_prev_episode(&self) -> bool {
        self.chapter_in_volume_index > 0
    }

    pub fn play_state(&self) -> PlayState {
        self.play_state
    }

    pub fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }

    pub fn video_url(&self) -> Option<&str> {
        self.video_url.as_deref()
    }

    pub fn video_title(&self) -> Option<&str> {
        self.video_title.as_deref()
    }

    pub fn dur_chapter_pos(&self) -> i64 {
        self.dur_chapter_pos
    }

    pub fn dur_volume_index(&self) -> i32 {
        self.dur_volume_index
    }

    pub fn chapter_in_volume_index(&self) -> i32 {
        self.chapter_in_volume_index
    }

    pub fn danmaku(&self) -> &DanmakuSource {
        &self.danmaku
    }

    pub fn auto_play(&self) -> bool {
        self.auto_play
    }

    pub fn set_auto_play(&mut self, value: bool) {
        self.auto_play = value;
    }

    pub fn danmaku_show(&self) -> bool {
        self.danmaku_show
    }

    pub fn set_danmaku_show(&mut self, value: bool) {
        self.danmaku_show = value;
    }

    pub fn single_url(&self) -> bool {
        self.single_url
    }

    pub fn set_single_url(&mut self, value: bool) {
        self.single_url = value;
    }

    /// 设置当前卷索引并刷新剧集（对齐切换线路/季数）
    pub fn set_volume_index(&mut self, index: i32) {
        self.dur_volume_index = index;
        self.chapter_in_volume_index = 0;
        self.up_episodes();
        self.refresh_current_episode();
    }
}

impl Default for VideoPlayerState {
    fn default() -> Self {
        Self::new()
    }
}

/// 视频正文内容类型
///
/// 对齐 Kotlin `VideoPlay.startPlay` 中对正文的分支处理。
#[derive(Debug, Clone, PartialEq)]
pub enum VideoContent {
    /// 直接视频 URL
    Url(String),
    /// MPD/DASH 清单文本（需写入临时文件后以 file:// 播放）
    Mpd(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构建一个章节
    fn ch(index: i32, title: &str, url: &str, is_volume: bool) -> BookChapter {
        BookChapter {
            index,
            title: title.to_string(),
            url: url.to_string(),
            is_volume,
            ..BookChapter::default()
        }
    }

    /// 构建含两卷的目录：
    /// 卷0(idx0) -> 第1集(idx1), 第2集(idx2)
    /// 卷1(idx3) -> 第3集(idx4)
    fn make_toc() -> Vec<BookChapter> {
        vec![
            ch(0, "第一季", "第一季", true),
            ch(1, "第1集", "http://v.com/1.m3u8", false),
            ch(2, "第2集", "http://v.com/2.m3u8", false),
            ch(3, "第二季", "第二季", true),
            ch(4, "第3集", "http://v.com/3.m3u8", false),
        ]
    }

    #[test]
    fn test_new_state_defaults() {
        let state = VideoPlayerState::new();
        assert_eq!(state.play_state(), PlayState::Idle);
        assert!(state.video_url().is_none());
        assert!(state.current_episode().is_none());
        assert_eq!(state.episode_count(), 0);
        assert!(state.auto_play());
    }

    #[test]
    fn test_init_toc_with_volumes() {
        let mut state = VideoPlayerState::new();
        state.init_toc(make_toc());
        assert_eq!(state.volumes().len(), 2);
        // 第一卷内应有 2 集
        assert_eq!(state.episode_count(), 2);
        assert_eq!(state.current_episode().unwrap().title, "第1集");
    }

    #[test]
    fn test_init_toc_without_volumes() {
        let mut state = VideoPlayerState::new();
        let toc = vec![
            ch(0, "第1集", "http://v.com/1.m3u8", false),
            ch(1, "第2集", "http://v.com/2.m3u8", false),
        ];
        state.init_toc(toc);
        assert_eq!(state.volumes().len(), 0);
        // 无卷时整个目录即剧集
        assert_eq!(state.episode_count(), 2);
    }

    #[test]
    fn test_switch_volume() {
        let mut state = VideoPlayerState::new();
        state.init_toc(make_toc());
        state.set_volume_index(1);
        assert_eq!(state.episode_count(), 1);
        assert_eq!(state.current_episode().unwrap().title, "第3集");
    }

    #[test]
    fn test_up_dur_index_next_prev() {
        let mut state = VideoPlayerState::new();
        state.init_toc(make_toc());
        assert_eq!(state.chapter_in_volume_index(), 0);

        assert!(state.up_dur_index(1));
        assert_eq!(state.chapter_in_volume_index(), 1);
        assert_eq!(state.current_episode().unwrap().title, "第2集");

        // 越界（第一卷只有 2 集）
        assert!(!state.up_dur_index(1));

        assert!(state.up_dur_index(-1));
        assert_eq!(state.chapter_in_volume_index(), 0);

        // 已到开头
        assert!(!state.up_dur_index(-1));
    }

    #[test]
    fn test_next_prev_episode_helpers() {
        let mut state = VideoPlayerState::new();
        state.init_toc(make_toc());
        assert!(state.has_next_episode());
        assert!(!state.has_prev_episode());

        assert!(state.next_episode());
        assert!(state.has_prev_episode());
        assert!(!state.has_next_episode());
    }

    #[test]
    fn test_play_state_transitions() {
        let mut state = VideoPlayerState::new();
        state.start_loading();
        assert_eq!(state.play_state(), PlayState::Loading);

        state.start_play("http://v.com/1.m3u8".to_string());
        assert_eq!(state.play_state(), PlayState::Playing);
        assert_eq!(state.video_url(), Some("http://v.com/1.m3u8"));

        state.pause();
        assert_eq!(state.play_state(), PlayState::Paused);

        state.resume();
        assert_eq!(state.play_state(), PlayState::Playing);

        state.complete();
        assert_eq!(state.play_state(), PlayState::Completed);
    }

    #[test]
    fn test_auto_play_false_starts_paused() {
        let mut state = VideoPlayerState::new();
        state.set_auto_play(false);
        state.start_play("http://v.com/x.mp4".to_string());
        assert_eq!(state.play_state(), PlayState::Paused);
    }

    #[test]
    fn test_fail_sets_error() {
        let mut state = VideoPlayerState::new();
        state.fail("网络超时".to_string());
        assert_eq!(state.play_state(), PlayState::Error);
        assert_eq!(state.last_error(), Some("网络超时"));
    }

    #[test]
    fn test_release_resets_state() {
        let mut state = VideoPlayerState::new();
        state.init_toc(make_toc());
        state.start_play("http://v.com/1.m3u8".to_string());
        state.update_progress(12345);
        state.release();
        assert_eq!(state.play_state(), PlayState::Idle);
        assert!(state.video_url().is_none());
        assert_eq!(state.dur_chapter_pos(), 0);
    }

    #[test]
    fn test_progress_save_and_restore() {
        let mut state = VideoPlayerState::new();
        state.init_toc(make_toc());
        state.up_dur_index(1);
        state.update_progress(60000);

        let progress = state.progress();
        assert_eq!(progress.episode_index, 1);
        assert_eq!(progress.position_ms, 60000);

        let mut state2 = VideoPlayerState::new();
        state2.init_toc(make_toc());
        state2.restore_progress(progress);
        assert_eq!(state2.chapter_in_volume_index(), 1);
        assert_eq!(state2.dur_chapter_pos(), 60000);
        assert_eq!(state2.current_episode().unwrap().title, "第2集");
    }

    #[test]
    fn test_update_progress_clamps_negative() {
        let mut state = VideoPlayerState::new();
        state.update_progress(-100);
        assert_eq!(state.dur_chapter_pos(), 0);
    }

    #[test]
    fn test_resolve_danmaku_inline_priority() {
        let mut state = VideoPlayerState::new();
        state.resolve_danmaku(
            Some("{\"danmaku\":[]}".to_string()),
            Some("/cache/dm.txt".to_string()),
        );
        // 内联优先
        assert_eq!(
            state.danmaku(),
            &DanmakuSource::Inline("{\"danmaku\":[]}".to_string())
        );
    }

    #[test]
    fn test_resolve_danmaku_file_fallback() {
        let mut state = VideoPlayerState::new();
        state.resolve_danmaku(None, Some("/cache/dm.txt".to_string()));
        assert_eq!(
            state.danmaku(),
            &DanmakuSource::File("/cache/dm.txt".to_string())
        );
    }

    #[test]
    fn test_resolve_danmaku_none() {
        let mut state = VideoPlayerState::new();
        state.resolve_danmaku(Some(String::new()), None);
        assert_eq!(state.danmaku(), &DanmakuSource::None);
        assert!(!state.danmaku().is_present());
    }

    #[test]
    fn test_clear_danmaku() {
        let mut state = VideoPlayerState::new();
        state.resolve_danmaku(Some("data".to_string()), None);
        state.clear_danmaku();
        assert_eq!(state.danmaku(), &DanmakuSource::None);
    }

    #[test]
    fn test_is_mpd_content() {
        assert!(VideoPlayerState::is_mpd_content(
            "<?xml version=\"1.0\"?><MPD></MPD>"
        ));
        assert!(VideoPlayerState::is_mpd_content("  <MPD></MPD>"));
        assert!(!VideoPlayerState::is_mpd_content("http://v.com/x.m3u8"));
    }

    #[test]
    fn test_normalize_content_empty() {
        assert_eq!(VideoPlayerState::normalize_content("   "), None);
    }

    #[test]
    fn test_normalize_content_url() {
        assert_eq!(
            VideoPlayerState::normalize_content("http://v.com/x.mp4"),
            Some(VideoContent::Url("http://v.com/x.mp4".to_string()))
        );
    }

    #[test]
    fn test_normalize_content_mpd() {
        let mpd = "<MPD></MPD>";
        assert_eq!(
            VideoPlayerState::normalize_content(mpd),
            Some(VideoContent::Mpd(mpd.to_string()))
        );
    }

    #[test]
    fn test_volume_url_starting_with_title_is_invalid() {
        // 卷章节链接以标题开头表示未获取到真实链接
        let mut state = VideoPlayerState::new();
        let toc = vec![ch(0, "线路A", "线路A", true)];
        state.init_toc(toc);
        // 无剧集，current_episode 为空
        assert!(state.current_episode().is_none());
    }

    #[test]
    fn test_play_state_is_active() {
        assert!(PlayState::Playing.is_active());
        assert!(PlayState::Paused.is_active());
        assert!(!PlayState::Idle.is_active());
        assert!(!PlayState::Completed.is_active());
        assert!(!PlayState::Error.is_active());
    }
}
