//! [B-13 回归测试 | 2026-09-28] 本地书懒加载建目录须同步 books 行派生字段
//!
//! 历史登记（Active 计划·第三阶段）：「B-13（换目录/重建目录路径的
//! latestChapterTitle 同步）」。2026-09-24 已修 refresh_toc 与
//! commit_source_switch 两条通道（`BookRepository::update_toc_derived_fields`
//! 同步 totalChapterNum / latestChapterTitle / latestChapterTime；分别见
//! reader.rs 与 source_switch.rs）。本测试核验**第三条重建 chapters 而漏
//! 同步派生字段**的路径，原为 STAGE3-VERIFY 红复现（exit 101，books 行
//! 派生字段 0/None），B-13b 修复后收编为正式回归测试（GREEN 基线）。
//!
//! 全库章节表写点排查结论（grep delete_by_book_url / insert_batch 非测试代码）：
//! 1. reader.rs        refresh_toc 重建         → 已同步（update_toc_derived_fields）
//! 2. source_switch.rs 换源提交重建              → 已同步（全行 update 前内存同步）
//! 3. reader.rs        本地书懒加载首次建目录    → 【B-13b 修复对象】原无派生字段写入
//!
//! 本地书懒加载虽然不是「换目录」，但属于「books 无派生字段依据时重建
//! chapters 表」的第三条路径：get_chapters 懒加载入库后 books 行的
//! totalChapterNum / latestChapterTitle 保持初始默认（0 / None），与 chapters
//! 表（3 章）不一致 —— 书架「共 N 章 / 最新章节」等派生展示失真。
//!
//! 修复（reader.rs get_chapters 本地书懒加载分支，B-13b）：insert_batch 后
//! 于同一 with_database 内调用 `BookRepository::update_toc_derived_fields`
//! （totalChapterNum = 新章数；latestChapterTitle = 末章标题；
//! latestChapterTime 仅章数增长时写入，对齐 refresh_toc 增长条件分支；
//! books 行不存在时 no-op）。不触碰 refresh_toc / commit_source_switch
//! 两条既有通道。
//!
//! 判别力保留：修复前主断言 RED（books.total_chapter_num=0 /
//! latest_chapter_title=None，exit 101）；修复后 GREEN（=3 / Some(末章)）。

use std::sync::{Mutex, MutexGuard, Once};

use legado_ffi::legado_db::BookRepository;

static TEST_LOCK: Mutex<()> = Mutex::new(());
static ENV_INIT: Once = Once::new();

fn lock_test() -> MutexGuard<'static, ()> {
    TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

fn setup_env() {
    let db = legado_ffi::legado_db::init_in_memory_database().expect("内存数据库初始化");
    legado_ffi::db_state::init_database(db).expect("全局连接池初始化");
}

#[test]
fn local_book_lazy_toc_load_syncs_derived_fields() {
    let _lock = lock_test();
    ENV_INIT.call_once(setup_env);

    // 构造本地 TXT（3 章），形态与 cache_download_api 夹具一致
    let dir = std::env::temp_dir().join("legado_p3verify_b13");
    std::fs::create_dir_all(&dir).expect("创建临时目录");
    let txt_path = dir.join("p3verify_b13.txt");
    std::fs::write(
        &txt_path,
        "第一章 开始\n\n这是第一章的正文内容。\n\n第二章 继续\n\n这是第二章的正文内容。\n\n第三章 结束\n\n这是第三章的正文内容。\n",
    )
    .expect("写入 TXT");
    let book_url = txt_path.to_string_lossy().to_string();

    let book_json = serde_json::json!({
        "bookUrl": book_url,
        "name": "B-13 本地书同步复现",
        "author": "",
        "origin": "loc_book"
    })
    .to_string();
    legado_ffi::api::bookshelf::add_book(&book_json).expect("本地书入库");

    // 首次取章节 → 触发懒加载解析并 insert_batch 入 chapters 表
    let list = legado_ffi::api::reader::get_chapters(&book_url).expect("本地书章节懒加载");
    assert_eq!(list.total, 3, "TXT 应解析出 3 章（夹具自检）");
    let last_title = list
        .chapters
        .last()
        .map(|c| c.title.clone())
        .expect("应有末章");

    // 懒加载后读 books 行派生字段
    let book = legado_ffi::db_state::with_database(|db| {
        BookRepository::new(db.connection()).find_by_url(&book_url)
    })
    .expect("books 查询")
    .expect("书籍行应存在");

    eprintln!(
        "[p3verify-b13] chapters.total={} books.total_chapter_num={:?} books.latest_chapter_title={:?}",
        list.total, book.total_chapter_num, book.latest_chapter_title
    );

    // 断言（缺陷形态为 RED）：重建 chapters 后派生字段应同步
    // （对齐 refresh_toc / 换源两条通道的既有语义）
    assert_eq!(
        book.total_chapter_num, list.total,
        "B-13 第三路径复现：本地书懒加载建目录后 books.totalChapterNum 未同步（chapters 表 {0} 章）",
        list.total
    );
    assert_eq!(
        book.latest_chapter_title.as_deref(),
        Some(last_title.as_str()),
        "B-13 第三路径复现：本地书懒加载建目录后 books.latestChapterTitle 未同步"
    );

    // 清理
    let _ = std::fs::remove_file(&txt_path);
}
