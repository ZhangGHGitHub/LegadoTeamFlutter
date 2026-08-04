//! 音频片头/片尾跳过策略
//!
//! 同步上游 #462/#492 修复：
//! - `AudioSkipPolicy.kt`：跳过窗口计算（`resolveAudioSkipWindow`）；
//! - `Book.kt`：书级 openCredits/closeCredits 与全局设置的切换
//!   （useGlobalAudioSkip，对齐 #492 全局默认）；
//! - `PreferKey.kt`：全局设置键 `audioSkipOpenCredits` / `audioSkipCloseCredits`。
//!
//! 全局默认值由调用方从设置存储（config/PreferKey 等价表）读取后传入，
//! 本模块为纯逻辑实现，不依赖具体存储。

use crate::models::book::ReadConfig;

/// 跳过生效所需的最短剩余可听时长（毫秒），对齐上游 `MIN_AUDIO_SKIP_REMAINING_MS`
///
/// 音频总时长 ≤ 片头 + 片尾 + 该值时不启用跳过，避免短音频被整体跳空。
pub const MIN_AUDIO_SKIP_REMAINING_MS: i64 = 5_000;

/// 全局片头跳过时长设置键（对齐上游 `PreferKey.audioSkipOpenCredits`）
pub const AUDIO_SKIP_OPEN_CREDITS_KEY: &str = "audioSkipOpenCredits";

/// 全局片尾跳过时长设置键（对齐上游 `PreferKey.audioSkipCloseCredits`）
pub const AUDIO_SKIP_CLOSE_CREDITS_KEY: &str = "audioSkipCloseCredits";

/// 音频跳过窗口（对齐上游 `AudioSkipWindow`）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioSkipWindow {
    /// 片头结束位置（毫秒）：播放起始位置落在该点之前时跳到该点
    pub intro_end_ms: i64,
    /// 片尾起始位置（毫秒）：播放位置到达该点时视为本章结束
    pub outro_start_ms: i64,
}

/// 根据音频时长与片头/片尾秒数计算跳过窗口
///
/// 对齐上游 `resolveAudioSkipWindow`：
/// - 时长未知（≤ 0）时不跳过；
/// - 时长不足以容纳"片头 + 片尾 + 最短剩余时长"时不跳过。
pub fn resolve_audio_skip_window(
    duration_ms: i64,
    intro_seconds: i32,
    outro_seconds: i32,
) -> Option<AudioSkipWindow> {
    if duration_ms <= 0 {
        return None;
    }
    let intro_ms = intro_seconds.max(0) as i64 * 1_000;
    let outro_ms = outro_seconds.max(0) as i64 * 1_000;
    if duration_ms <= intro_ms + outro_ms + MIN_AUDIO_SKIP_REMAINING_MS {
        return None;
    }
    Some(AudioSkipWindow {
        intro_end_ms: intro_ms,
        outro_start_ms: duration_ms - outro_ms,
    })
}

/// 解析书级生效的片头跳过秒数（对齐上游 `Book.getOpenCredits()`）
///
/// `use_global_audio_skip = true` 时取全局值，否则取书级自定义值。
/// readConfig 为空时对齐上游 `Book.config` 回退分支（默认使用全局）。
pub fn resolve_open_credits(read_config: Option<&ReadConfig>, global_open_credits: i32) -> i32 {
    match read_config {
        Some(config) if !config.use_global_audio_skip => config.open_credits,
        _ => global_open_credits,
    }
}

/// 解析书级生效的片尾跳过秒数（对齐上游 `Book.getCloseCredits()`）
pub fn resolve_close_credits(read_config: Option<&ReadConfig>, global_close_credits: i32) -> i32 {
    match read_config {
        Some(config) if !config.use_global_audio_skip => config.close_credits,
        _ => global_close_credits,
    }
}

/// 从全局模式切换到书级自定义模式（对齐上游 `Book.switchToBookAudioSkip()`）
///
/// 首次切换到书级时，把当前全局值拷贝为书级初始值，
/// 保证用户"改为书级"瞬间的生效值不变。
pub fn switch_to_book_audio_skip(
    config: &mut ReadConfig,
    global_open_credits: i32,
    global_close_credits: i32,
) {
    if !config.use_global_audio_skip {
        return;
    }
    config.open_credits = global_open_credits;
    config.close_credits = global_close_credits;
    config.use_global_audio_skip = false;
}

/// 设置书级片头跳过秒数（对齐上游 `Book.setOpenCredits()`）
///
/// 设置书级值即代表切换到书级模式，负值归零。
pub fn set_open_credits(
    config: &mut ReadConfig,
    open_credits: i32,
    global_open_credits: i32,
    global_close_credits: i32,
) {
    switch_to_book_audio_skip(config, global_open_credits, global_close_credits);
    config.open_credits = open_credits.max(0);
}

/// 设置书级片尾跳过秒数（对齐上游 `Book.setCloseCredits()`）
pub fn set_close_credits(
    config: &mut ReadConfig,
    close_credits: i32,
    global_open_credits: i32,
    global_close_credits: i32,
) {
    switch_to_book_audio_skip(config, global_open_credits, global_close_credits);
    config.close_credits = close_credits.max(0);
}

/// 设置是否使用全局跳过配置（对齐上游 `Book.setAudioSkipUsingGlobal()`）
///
/// 切换到书级模式时先以全局值初始化书级值。
pub fn set_audio_skip_using_global(
    config: &mut ReadConfig,
    use_global: bool,
    global_open_credits: i32,
    global_close_credits: i32,
) {
    if use_global {
        config.use_global_audio_skip = true;
    } else {
        switch_to_book_audio_skip(config, global_open_credits, global_close_credits);
    }
}

/// 是否使用全局跳过配置（对齐上游 `Book.isAudioSkipUsingGlobal()`）
///
/// readConfig 为空时对齐上游默认回退（useGlobalAudioSkip = true）。
pub fn is_audio_skip_using_global(read_config: Option<&ReadConfig>) -> bool {
    read_config.map_or(true, |c| c.use_global_audio_skip)
}

/// 计算片头跳过后的起播位置（对齐上游 `applyIntroSkipIfNeeded`）
///
/// 仅在从头开始播放（position ≤ 0）且存在片头窗口时返回片头结束位置，
/// 调用方应 seek 到该位置；否则返回 None 表示无需跳过。
pub fn intro_seek_position(current_position_ms: i64, window: &AudioSkipWindow) -> Option<i64> {
    if current_position_ms > 0 {
        return None;
    }
    if window.intro_end_ms <= 0 {
        return None;
    }
    Some(window.intro_end_ms)
}

/// 判断当前位置是否应视为片尾跳过（对齐上游 `tryAutoSkipOutro`）
///
/// 播放位置进入片尾窗口（剩余时长 ≤ 片尾时长）时返回 true，
/// 调用方应将本章视为播放完成并切换下一章。
pub fn should_skip_outro(current_position_ms: i64, window: &AudioSkipWindow) -> bool {
    current_position_ms >= window.outro_start_ms
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── resolve_audio_skip_window 边界测试 ─────────────────

    #[test]
    fn test_window_basic() {
        // 600 秒音频，片头 10 秒，片尾 20 秒
        let w = resolve_audio_skip_window(600_000, 10, 20).unwrap();
        assert_eq!(w.intro_end_ms, 10_000);
        assert_eq!(w.outro_start_ms, 580_000);
    }

    #[test]
    fn test_window_zero_credits() {
        let w = resolve_audio_skip_window(600_000, 0, 0).unwrap();
        assert_eq!(w.intro_end_ms, 0);
        assert_eq!(w.outro_start_ms, 600_000);
    }

    #[test]
    fn test_window_negative_credits_clamped() {
        let w = resolve_audio_skip_window(600_000, -5, -3).unwrap();
        assert_eq!(w.intro_end_ms, 0);
        assert_eq!(w.outro_start_ms, 600_000);
    }

    #[test]
    fn test_window_invalid_duration() {
        assert!(resolve_audio_skip_window(0, 10, 10).is_none());
        assert!(resolve_audio_skip_window(-1, 10, 10).is_none());
    }

    #[test]
    fn test_window_too_short_audio() {
        // 时长 ≤ 片头 + 片尾 + 5 秒最小剩余 → 不跳过
        assert!(resolve_audio_skip_window(35_000, 10, 20).is_none());
        // 刚好超过阈值 → 生效
        assert!(resolve_audio_skip_window(35_001, 10, 20).is_some());
    }

    // ─── 全局 vs 书级切换测试（#492） ──────────────────────

    fn global_mode_config() -> ReadConfig {
        ReadConfig {
            use_global_audio_skip: true,
            ..ReadConfig::default()
        }
    }

    fn book_mode_config(open: i32, close: i32) -> ReadConfig {
        ReadConfig {
            open_credits: open,
            close_credits: close,
            use_global_audio_skip: false,
            ..ReadConfig::default()
        }
    }

    #[test]
    fn test_resolve_credits_global_mode() {
        let cfg = global_mode_config();
        assert_eq!(resolve_open_credits(Some(&cfg), 15), 15);
        assert_eq!(resolve_close_credits(Some(&cfg), 25), 25);
    }

    #[test]
    fn test_resolve_credits_book_mode() {
        let cfg = book_mode_config(5, 8);
        assert_eq!(resolve_open_credits(Some(&cfg), 15), 5);
        assert_eq!(resolve_close_credits(Some(&cfg), 25), 8);
    }

    #[test]
    fn test_resolve_credits_no_config_uses_global() {
        // readConfig 为空时对齐上游回退分支（默认全局）
        assert_eq!(resolve_open_credits(None, 15), 15);
        assert_eq!(resolve_close_credits(None, 25), 25);
        assert!(is_audio_skip_using_global(None));
    }

    #[test]
    fn test_switch_to_book_audio_skip_copies_globals() {
        let mut cfg = global_mode_config();
        switch_to_book_audio_skip(&mut cfg, 15, 25);
        assert!(!cfg.use_global_audio_skip);
        // 切换瞬间书级值 = 全局值，生效值不变
        assert_eq!(cfg.open_credits, 15);
        assert_eq!(cfg.close_credits, 25);
        assert_eq!(resolve_open_credits(Some(&cfg), 15), 15);
    }

    #[test]
    fn test_switch_to_book_only_once() {
        let mut cfg = book_mode_config(5, 8);
        // 已是书级模式时不再用全局值覆盖
        switch_to_book_audio_skip(&mut cfg, 15, 25);
        assert_eq!(cfg.open_credits, 5);
        assert_eq!(cfg.close_credits, 8);
    }

    #[test]
    fn test_set_open_credits_switches_to_book_mode() {
        let mut cfg = global_mode_config();
        set_open_credits(&mut cfg, 30, 15, 25);
        assert!(!cfg.use_global_audio_skip);
        assert_eq!(cfg.open_credits, 30);
        // 片尾保留切换时拷贝的全局值
        assert_eq!(cfg.close_credits, 25);
    }

    #[test]
    fn test_set_close_credits_clamps_negative() {
        let mut cfg = global_mode_config();
        set_close_credits(&mut cfg, -3, 15, 25);
        assert_eq!(cfg.close_credits, 0);
    }

    #[test]
    fn test_set_audio_skip_using_global_roundtrip() {
        let mut cfg = global_mode_config();
        // 切到书级
        set_audio_skip_using_global(&mut cfg, false, 15, 25);
        assert!(!is_audio_skip_using_global(Some(&cfg)));
        assert_eq!(cfg.open_credits, 15);
        // 切回全局
        set_audio_skip_using_global(&mut cfg, true, 15, 25);
        assert!(is_audio_skip_using_global(Some(&cfg)));
        assert_eq!(resolve_open_credits(Some(&cfg), 99), 99);
    }

    // ─── 播放进度跳过应用测试 ────────────────────────────

    #[test]
    fn test_intro_seek_from_start() {
        let w = resolve_audio_skip_window(600_000, 10, 20).unwrap();
        assert_eq!(intro_seek_position(0, &w), Some(10_000));
    }

    #[test]
    fn test_intro_seek_not_from_start() {
        let w = resolve_audio_skip_window(600_000, 10, 20).unwrap();
        // 恢复播放（position > 0）不跳片头
        assert_eq!(intro_seek_position(5_000, &w), None);
    }

    #[test]
    fn test_intro_seek_no_intro() {
        let w = resolve_audio_skip_window(600_000, 0, 20).unwrap();
        assert_eq!(intro_seek_position(0, &w), None);
    }

    #[test]
    fn test_should_skip_outro_boundary() {
        let w = resolve_audio_skip_window(600_000, 10, 20).unwrap();
        // 片尾窗口起点之前不跳
        assert!(!should_skip_outro(579_999, &w));
        // 到达片尾窗口即视为本章结束
        assert!(should_skip_outro(580_000, &w));
        assert!(should_skip_outro(600_000, &w));
    }
}
