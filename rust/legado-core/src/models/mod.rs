//! 数据模型模块

pub mod book;
pub mod book_chapter;
pub mod book_source;
pub mod misc;
pub mod rss_source;
pub mod rule;

pub use book::book_type;
pub use book::{Book, ReadConfig};
pub use book_chapter::BookChapter;
pub use book_source::book_source_type;
pub use book_source::BookSource;
pub use rss_source::RssSource;

pub use rule::{
    BookInfoRule, BookListRule, ContentRule, ExploreKind, ExploreRule, FlexChildStyle, ReviewRule,
    RowUi, SearchRule, TocRule,
};

pub use misc::{
    AutoTaskRule, BookCacheInfo, BookChapterReview, BookGroup, BookProgress, BookSourcePart,
    Bookmark, Cache, Cookie, DictRule, HttpTts, KeyboardAssist, ReadRecord, ReadRecordShow,
    ReplaceBook, ReplaceRule, RssArticle, RssReadRecord, RssStar, RuleSub, SearchBook,
    SearchKeyword, Server, ServerType, TxtTocRule, WebDavConfig,
};
