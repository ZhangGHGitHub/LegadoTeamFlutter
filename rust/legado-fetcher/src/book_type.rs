//! BookType 位标志与书源类型换算（自 `legado-ffi/src/api/search.rs` 平移，
//! 对齐原版 `io.legado.app.constant.BookType`）

/// 4 视频
pub const VIDEO: i32 = 0b100;
/// 8 文本
pub const TEXT: i32 = 0b1000;
/// 32 音频
pub const AUDIO: i32 = 0b100000;
/// 64 图片（漫画）
pub const IMAGE: i32 = 0b1000000;
/// 128 只提供下载服务的网站
pub const WEB_FILE: i32 = 0b1000_0000;

/// 书源类型 → BookType（对齐原版 `BookSource.getBookType()`：
/// file→text|webFile、image→image、audio→audio、video→video、其余→text）
pub fn book_type_of_source(source_type: i32) -> i32 {
    use legado_core::models::book_source_type as st;
    match source_type {
        st::FILE => TEXT | WEB_FILE,
        st::IMAGE => IMAGE,
        st::AUDIO => AUDIO,
        st::VIDEO => VIDEO,
        _ => TEXT,
    }
}
