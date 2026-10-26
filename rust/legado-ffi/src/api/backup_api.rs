//! 备份/恢复 API
//!
//! 提供数据库备份创建、恢复和备份文件列表功能。
//! 备份格式为单文件 JSON（BackupData）：
//! - version=1（历史格式）：books/bookmarks/replaceRules/bookSources/rssSources/readRecords
//!   六类；其中 rssSources 为 `SELECT *` 直出（布尔列为 0/1 整数形态）。
//! - version=2（本批，对齐原版 `Backup.kt:279-330` 的表覆盖面）：新增
//!   bookGroups/rssStars/highlights/highlightRules/searchHistory/ruleSubs/
//!   txtTocRules/httpTTS/dictRules/keyboardAssists 十类；rssSources 改由
//!   `RssSourceRepository` 模型序列化（布尔为真 bool、None 字段省略）。
//!
//! 兼容语义（防复发规定 9：备份格式版本化）：恢复器按字段驱动解析，
//! 全部列表字段 `#[serde(default)]`——旧备份（无 version 或 version<2）
//! 缺失的新表字段按空数组处理，仍可正常恢复；恢复时对 v1 整数布尔做归一整形。

use std::fs;
use std::path::Path;

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use legado_core::models::{Book, BookSource, Bookmark, RssSource};
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::Repository;
use legado_db::{
    BookGroup, BookGroupRepository, BookRepository, BookSourceRepository, BookmarkRepository,
    DictRule, DictRuleRepository, HighlightRepository, HighlightRuleRepository, HttpTts,
    HttpTtsRepository, KeyboardAssist, KeyboardAssistRepository, ReadRecord, ReadRecordRepository,
    ReplaceRuleRepository, RssSourceRepository, RssStarRecord, RssStarRepository, RuleSubRecord,
    RuleSubRepository, SearchKeywordRepository, TxtTocRuleRecord, TxtTocRuleRepository,
};

use crate::db_state::with_database;

/// 当前备份格式版本（写入侧；恢复侧按字段兼容，不按版本分叉）
pub const BACKUP_VERSION: i32 = 2;

/// 备份数据结构
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupData {
    /// 备份版本（v1=初版六类；v2=扩表批十类，见模块注释的版本语义）
    #[serde(default = "default_version")]
    pub version: i32,
    /// 备份时间戳（毫秒）
    #[serde(default, rename = "backupTime")]
    pub backup_time: i64,
    /// 书籍列表
    #[serde(default)]
    pub books: Vec<serde_json::Value>,
    /// 书签列表
    #[serde(default)]
    pub bookmarks: Vec<serde_json::Value>,
    /// 替换规则列表
    #[serde(default, rename = "replaceRules")]
    pub replace_rules: Vec<serde_json::Value>,
    /// 书源列表
    #[serde(default, rename = "bookSources")]
    pub book_sources: Vec<serde_json::Value>,
    /// RSS 源列表（v2 起为 RssSource 模型序列化；v1 为 SELECT * 直出）
    #[serde(default, rename = "rssSources")]
    pub rss_sources: Vec<serde_json::Value>,
    /// 阅读记录列表
    #[serde(default, rename = "readRecords")]
    pub read_records: Vec<serde_json::Value>,
    /// 书籍分组列表（v2 新增，对齐原版 bookGroup.json）
    #[serde(default, rename = "bookGroups")]
    pub book_groups: Vec<serde_json::Value>,
    /// RSS 收藏列表（v2 新增，对齐原版 rssStar.json）
    #[serde(default, rename = "rssStars")]
    pub rss_stars: Vec<serde_json::Value>,
    /// 高亮记录列表（v2 新增，对齐原版 highlight.json）
    #[serde(default, rename = "highlights")]
    pub highlights: Vec<serde_json::Value>,
    /// 高亮规则列表（v2 新增，对齐原版 highlightRule.json）
    #[serde(default, rename = "highlightRules")]
    pub highlight_rules: Vec<serde_json::Value>,
    /// 搜索历史列表（v2 新增，对齐原版 searchHistory.json / SearchKeyword 实体）
    #[serde(default, rename = "searchHistory")]
    pub search_history: Vec<serde_json::Value>,
    /// 规则订阅列表（v2 新增，对齐原版 sourceSub.json）
    #[serde(default, rename = "ruleSubs")]
    pub rule_subs: Vec<serde_json::Value>,
    /// TXT 目录规则列表（v2 新增，对齐原版 txtTocRule.json）
    #[serde(default, rename = "txtTocRules")]
    pub txt_toc_rules: Vec<serde_json::Value>,
    /// 在线朗读引擎列表（v2 新增，对齐原版 httpTTS.json）
    #[serde(default, rename = "httpTTS")]
    pub http_tts: Vec<serde_json::Value>,
    /// 词典规则列表（v2 新增，对齐原版 dictRule.json）
    #[serde(default, rename = "dictRules")]
    pub dict_rules: Vec<serde_json::Value>,
    /// 键盘辅助规则列表（v2 新增，对齐原版 keyboardAssists.json）
    #[serde(default, rename = "keyboardAssists")]
    pub keyboard_assists: Vec<serde_json::Value>,
}

fn default_version() -> i32 {
    // 旧备份（无 version 字段）按 v1 解析
    1
}

/// 恢复统计
///
/// 说明：字段集合为 v1 既有六类计数，保持 FFI 返回 JSON 形状不变
/// （v2 扩表恢复不新增计数，失败明细走 warn 日志，规避对外结构变更）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RestoreStats {
    pub books: usize,
    pub bookmarks: usize,
    pub replace_rules: usize,
    pub book_sources: usize,
    pub rss_sources: usize,
    pub read_records: usize,
}

/// 创建备份到指定路径
///
/// 收集 BackupData 全部 16 类数据（v2 覆盖面，对齐原版 `Backup.kt:279-330`
/// 中所有表已在库的类别），统一经各 repository 读取后模型序列化，
/// 写入 JSON 文件，返回备份文件路径。
pub fn backup_create(path: &str) -> LegadoResult<String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let backup_data = with_database(|db| {
        let conn = db.connection();

        // 收集书籍
        let book_repo = BookRepository::new(conn);
        let books: Vec<serde_json::Value> = book_repo
            .find_all()?
            .into_iter()
            .filter_map(|b| serde_json::to_value(&b).ok())
            .collect();

        // 收集书签
        let bookmark_repo = BookmarkRepository::new(conn);
        let bookmarks: Vec<serde_json::Value> = bookmark_repo
            .find_all()?
            .into_iter()
            .filter_map(|b| serde_json::to_value(&b).ok())
            .collect();

        // 收集替换规则
        let rule_repo = ReplaceRuleRepository::new(conn);
        let replace_rules: Vec<serde_json::Value> = rule_repo
            .find_all()?
            .into_iter()
            .filter_map(|r| serde_json::to_value(&r).ok())
            .collect();

        // 收集书源
        let source_repo = BookSourceRepository::new(conn);
        let book_sources: Vec<serde_json::Value> = source_repo
            .find_all()?
            .into_iter()
            .filter_map(|s| serde_json::to_value(&s).ok())
            .collect();

        // 收集 RSS 源（v2：走 repository 全列模型，布尔为真 bool）
        let rss_sources: Vec<serde_json::Value> = RssSourceRepository::new(conn)
            .find_all()
            .map_err(|e| LegadoError::Database(format!("收集 RSS 源失败: {e}")))?
            .into_iter()
            .filter_map(|s| serde_json::to_value(&s).ok())
            .collect();

        // 收集阅读记录
        let record_repo = ReadRecordRepository::new(conn);
        let read_records: Vec<serde_json::Value> = record_repo
            .find_all()?
            .into_iter()
            .filter_map(|r| serde_json::to_value(&r).ok())
            .collect();

        // ─── v2 扩表收集（表已在库，repository 全列读取）──────────────

        // 书籍分组
        let book_groups: Vec<serde_json::Value> = BookGroupRepository::new(conn)
            .find_all()?
            .iter()
            .filter_map(|g| serde_json::to_value(to_core_book_group(g)).ok())
            .collect();

        // RSS 收藏
        let rss_stars: Vec<serde_json::Value> = RssStarRepository::new(conn)
            .find_all()?
            .iter()
            .filter_map(|s| serde_json::to_value(to_core_rss_star(s)).ok())
            .collect();

        // 高亮记录
        let highlights: Vec<serde_json::Value> = HighlightRepository::new(conn)
            .find_all()?
            .into_iter()
            .filter_map(|h| serde_json::to_value(&h).ok())
            .collect();

        // 高亮规则（P2-11：uuid/applyToBody 随 HighlightRule serde 全字段往返，
        // 旧备份 JSON 缺 uuid/applyToBody 时 serde 默认值兜底——uuid 随机生成、
        // applyToBody=true 对齐原版实体默认）
        let highlight_rules: Vec<serde_json::Value> = HighlightRuleRepository::new(conn)
            .find_all()?
            .into_iter()
            .filter_map(|r| serde_json::to_value(&r).ok())
            .collect();

        // 搜索历史
        let search_history: Vec<serde_json::Value> = SearchKeywordRepository::new(conn)
            .find_all()?
            .into_iter()
            .filter_map(|k| serde_json::to_value(&k).ok())
            .collect();

        // 规则订阅
        let rule_subs: Vec<serde_json::Value> = RuleSubRepository::new(conn)
            .find_all()?
            .into_iter()
            .filter_map(|s| serde_json::to_value(&s).ok())
            .collect();

        // TXT 目录规则
        let txt_toc_rules: Vec<serde_json::Value> = TxtTocRuleRepository::new(conn)
            .find_all()?
            .iter()
            .filter_map(|r| serde_json::to_value(to_core_txt_toc_rule(r)).ok())
            .collect();

        // 在线朗读引擎（全 14 列）
        let http_tts: Vec<serde_json::Value> = HttpTtsRepository::new(conn)
            .find_all()?
            .into_iter()
            .filter_map(|t| serde_json::to_value(&t).ok())
            .collect();

        // 词典规则
        let dict_rules: Vec<serde_json::Value> = DictRuleRepository::new(conn)
            .find_all()?
            .iter()
            .filter_map(|r| serde_json::to_value(to_core_dict_rule(r)).ok())
            .collect();

        // 键盘辅助规则
        let keyboard_assists: Vec<serde_json::Value> = KeyboardAssistRepository::new(conn)
            .find_all()?
            .into_iter()
            .filter_map(|k| serde_json::to_value(&k).ok())
            .collect();

        Ok(BackupData {
            version: BACKUP_VERSION,
            backup_time: now,
            books,
            bookmarks,
            replace_rules,
            book_sources,
            rss_sources,
            read_records,
            book_groups,
            rss_stars,
            highlights,
            highlight_rules,
            search_history,
            rule_subs,
            txt_toc_rules,
            http_tts,
            dict_rules,
            keyboard_assists,
        })
    })?;

    // 确保目录存在
    if let Some(parent) = Path::new(path).parent() {
        fs::create_dir_all(parent).map_err(|e| {
            LegadoError::Io(std::io::Error::other(format!("创建备份目录失败: {e}")))
        })?;
    }

    // 写入文件
    let json = serde_json::to_string_pretty(&backup_data)
        .map_err(|e| LegadoError::Internal(format!("备份序列化失败: {e}")))?;
    fs::write(path, &json)
        .map_err(|e| LegadoError::Io(std::io::Error::other(format!("写入备份文件失败: {e}"))))?;

    Ok(path.to_string())
}

/// 从备份文件恢复
///
/// 读取 JSON 文件，逐条恢复各表数据，返回恢复统计。
///
/// [P1-A 加固（2026-10-26 审查批2）] 恢复体整体包进单事务
/// （[`legado_db::connection::in_transaction`]）：此前恢复体在
/// `with_database` 内逐条 autocommit，崩溃/断电会留下「前 k-1 条已恢复、
/// 其余未恢复」的部分恢复态。事务语义与批 1 审查口径一致：
/// - **条目级错误照常提交**：解析失败 / UNIQUE 撞名等条目错误仍在恢复体
///   内 warn 跳过（见 [`restore_backup_in_tx`] 各 match 分支，不上抛），
///   闭包返回 `Ok` → 事务照常 COMMIT，跳过条目不影响其余条目落库；
/// - **仅未捕获 `Err` 触发整体回滚**：恢复体经 `?` 上抛的错误（如未来
///   新增表写入漏捕获、SQLite 级故障）使事务在 drop 中 ROLLBACK，库内
///   零残留（不会出现部分恢复态）；
/// - 复用 legado-db 共享事务边界实现（与批量导入 `insert_batch` 同一
///   入口，单实现原则）；池化 `&Connection` 为不可变借用，经
///   `unchecked_transaction()` 开启事务（rusqlite 0.31 `transaction()`
///   需 `&mut Connection`，缘由见 legado-db connection.rs 文档）。
pub fn backup_restore(path: &str) -> LegadoResult<String> {
    let content = fs::read_to_string(path)
        .map_err(|e| LegadoError::Io(std::io::Error::other(format!("读取备份文件失败: {e}"))))?;

    let backup: BackupData = serde_json::from_str(&content)
        .map_err(|e| LegadoError::Internal(format!("备份文件解析失败: {e}")))?;

    let stats = with_database(|db| {
        let conn = db.connection();
        legado_db::connection::in_transaction(conn, "备份恢复", |conn| {
            restore_backup_in_tx(conn, &backup)
        })
    })?;

    let result = serde_json::to_string(&stats)
        .map_err(|e| LegadoError::Internal(format!("统计序列化失败: {e}")))?;
    Ok(result)
}

/// 恢复体：各表逐条恢复（单事务闭包内容，条目级错误 warn 跳过继续）
///
/// 从 [`backup_restore`] 拆出以匹配 `in_transaction` 闭包签名，并供测试
/// 直接构造「恢复中未捕获错误 → 整体回滚」场景（外部备份数据无法构造
/// 逃逸条目捕获网的 Err——全部条目级错误均在下方 match 分支内被 warn
/// 吞掉，回滚路径只能以闭包内直接上抛 `Err` 的方式验证）。
fn restore_backup_in_tx(conn: &Connection, backup: &BackupData) -> LegadoResult<RestoreStats> {
    let mut stats = RestoreStats {
        books: 0,
        bookmarks: 0,
        replace_rules: 0,
        book_sources: 0,
        rss_sources: 0,
        read_records: 0,
    };

    // 恢复书籍
    // 评审 W3：失败不再静默吞错——UNIQUE 撞名等写入失败记 warn 日志，
    // 便于排查「恢复数量少于备份数量」类问题（RestoreStats 仅含成功计数，
    // 失败不入统计以免变更 FFI 返回结构）
    let book_repo = BookRepository::new(conn);
    for value in &backup.books {
        if let Ok(book) = serde_json::from_value::<Book>(value.clone()) {
            match book_repo.insert(&book) {
                Ok(()) => stats.books += 1,
                Err(e) => log::warn!("恢复书籍失败（已跳过）: {} - {e}", book.book_url),
            }
        }
    }

    // 恢复书签
    let bookmark_repo = BookmarkRepository::new(conn);
    for value in &backup.bookmarks {
        if let Ok(bm) = serde_json::from_value::<Bookmark>(value.clone()) {
            match bookmark_repo.insert(&bm) {
                Ok(_) => stats.bookmarks += 1,
                Err(e) => log::warn!("恢复书签失败（已跳过）: {} - {e}", bm.book_name),
            }
        }
    }

    // 恢复替换规则
    let rule_repo = ReplaceRuleRepository::new(conn);
    for value in &backup.replace_rules {
        if let Ok(rule) = serde_json::from_value::<legado_core::models::ReplaceRule>(value.clone())
        {
            match rule_repo.insert(&rule) {
                Ok(_) => stats.replace_rules += 1,
                Err(e) => log::warn!("恢复替换规则失败（已跳过）: {} - {e}", rule.name),
            }
        }
    }

    // 恢复书源
    let source_repo = BookSourceRepository::new(conn);
    for value in &backup.book_sources {
        if let Ok(source) = serde_json::from_value::<BookSource>(value.clone()) {
            match source_repo.insert(&source) {
                Ok(()) => stats.book_sources += 1,
                Err(e) => {
                    log::warn!("恢复书源失败（已跳过）: {} - {e}", source.book_source_url)
                }
            }
        }
    }

    // 恢复 RSS 源（v2：走 RssSourceRepository 全 44 列写入，替代旧 7 列旁路；
    // v1 备份的整数布尔先经 normalize_v1_rss_entry 归一后再解析）
    let rss_repo = RssSourceRepository::new(conn);
    for value in &backup.rss_sources {
        let normalized = normalize_v1_rss_entry(value);
        let parsed: Result<RssSource, _> = serde_json::from_value(normalized);
        match parsed {
            Ok(source) => {
                if source.source_url.trim().is_empty() {
                    log::warn!("恢复 RSS 源失败（已跳过）: sourceUrl 为空，形态不符");
                    continue;
                }
                match rss_repo.insert(&source) {
                    Ok(_) => stats.rss_sources += 1,
                    Err(e) => {
                        log::warn!("恢复 RSS 源失败（已跳过）: {} - {e}", source.source_url)
                    }
                }
            }
            Err(e) => log::warn!("恢复 RSS 源解析失败（已跳过）: {e}"),
        }
    }

    // 恢复阅读记录（v2：全字段 + 原版 Restore.kt「同键较新者胜 + 作者合并」语义；
    // 旧实现仅 upsert(book_name, read_time) 且 JSON 键不匹配，等于丢数据）
    let record_repo = ReadRecordRepository::new(conn);
    for value in &backup.read_records {
        match serde_json::from_value::<ReadRecord>(value.clone()) {
            Ok(record) => match record_repo.upsert_restore(&record) {
                Ok(()) => stats.read_records += 1,
                Err(e) => {
                    log::warn!("恢复阅读记录失败（已跳过）: {} - {e}", record.book_name)
                }
            },
            Err(e) => log::warn!("恢复阅读记录解析失败（已跳过）: {e}"),
        }
    }

    // ─── v2 扩表恢复（逐表走各自 repository，单实现原则）────────────

    // 书籍分组（对齐原版 bookGroupDao.insert 的 REPLACE 语义）
    let group_repo = BookGroupRepository::new(conn);
    for value in &backup.book_groups {
        match serde_json::from_value::<legado_core::models::BookGroup>(value.clone()) {
            Ok(group) => match group_repo.upsert(&from_core_book_group(group)) {
                Ok(()) => {}
                Err(e) => log::warn!("恢复书籍分组失败（已跳过）: {e}"),
            },
            Err(e) => log::warn!("恢复书籍分组解析失败（已跳过）: {e}"),
        }
    }

    // RSS 收藏（对齐原版 rssStarDao.insert 的 REPLACE 语义）
    let star_repo = RssStarRepository::new(conn);
    for value in &backup.rss_stars {
        match serde_json::from_value::<legado_core::models::RssStar>(value.clone()) {
            Ok(star) => match star_repo.add_star(&from_core_rss_star(star)) {
                Ok(()) => {}
                Err(e) => log::warn!("恢复 RSS 收藏失败（已跳过）: {e}"),
            },
            Err(e) => log::warn!("恢复 RSS 收藏解析失败（已跳过）: {e}"),
        }
    }

    // 高亮记录（主键 time，INSERT OR REPLACE）
    let highlight_repo = HighlightRepository::new(conn);
    for value in &backup.highlights {
        match serde_json::from_value::<legado_core::models::BookHighlight>(value.clone()) {
            Ok(highlight) => match highlight_repo.insert(&highlight) {
                Ok(()) => {}
                Err(e) => log::warn!("恢复高亮记录失败（已跳过）: {e}"),
            },
            Err(e) => log::warn!("恢复高亮记录解析失败（已跳过）: {e}"),
        }
    }

    // 高亮规则（主键 id 显式 REPLACE；P2-11 补列后 uuid/applyToBody 随模型
    // serde 全字段往返，旧备份缺字段时 serde 默认值兜底，不破坏可恢复性）
    let highlight_rule_repo = HighlightRuleRepository::new(conn);
    for value in &backup.highlight_rules {
        match serde_json::from_value::<legado_core::models::HighlightRule>(value.clone()) {
            Ok(rule) => match highlight_rule_repo.insert(&rule) {
                Ok(_) => {}
                Err(e) => log::warn!("恢复高亮规则失败（已跳过）: {e}"),
            },
            Err(e) => log::warn!("恢复高亮规则解析失败（已跳过）: {e}"),
        }
    }

    // 搜索历史（原样保留 usage/lastUseTime，不走 find 的 usage+1 语义）
    let keyword_repo = SearchKeywordRepository::new(conn);
    for value in &backup.search_history {
        match serde_json::from_value::<legado_core::models::SearchKeyword>(value.clone()) {
            Ok(keyword) => match keyword_repo.upsert_record(&keyword) {
                Ok(()) => {}
                Err(e) => log::warn!("恢复搜索历史失败（已跳过）: {e}"),
            },
            Err(e) => log::warn!("恢复搜索历史解析失败（已跳过）: {e}"),
        }
    }

    // 规则订阅（保留备份行 id，整行 REPLACE）
    let rule_sub_repo = RuleSubRepository::new(conn);
    for value in &backup.rule_subs {
        match serde_json::from_value::<RuleSubRecord>(value.clone()) {
            Ok(sub) => match rule_sub_repo.upsert(&sub) {
                Ok(()) => {}
                Err(e) => log::warn!("恢复规则订阅失败（已跳过）: {e}"),
            },
            Err(e) => log::warn!("恢复规则订阅解析失败（已跳过）: {e}"),
        }
    }

    // TXT 目录规则（全列 upsert，保留 id/enable/example）
    let txt_toc_repo = TxtTocRuleRepository::new(conn);
    for value in &backup.txt_toc_rules {
        match serde_json::from_value::<legado_core::models::TxtTocRule>(value.clone()) {
            Ok(rule) => match txt_toc_repo.upsert(&from_core_txt_toc_rule(rule)) {
                Ok(()) => {}
                Err(e) => log::warn!("恢复 TXT 目录规则失败（已跳过）: {e}"),
            },
            Err(e) => log::warn!("恢复 TXT 目录规则解析失败（已跳过）: {e}"),
        }
    }

    // 在线朗读引擎（全 14 列，保留 header/loginUrl 等扩展列）
    let tts_repo = HttpTtsRepository::new(conn);
    for value in &backup.http_tts {
        match serde_json::from_value::<HttpTts>(value.clone()) {
            Ok(tts) => match tts_repo.upsert(&tts) {
                Ok(_) => {}
                Err(e) => log::warn!("恢复朗读引擎失败（已跳过）: {e}"),
            },
            Err(e) => log::warn!("恢复朗读引擎解析失败（已跳过）: {e}"),
        }
    }

    // 词典规则（按 name UNIQUE 列 REPLACE 保留原 id，对齐原版 DictRuleDao 语义）
    let dict_repo = DictRuleRepository::new(conn);
    for value in &backup.dict_rules {
        match serde_json::from_value::<legado_core::models::DictRule>(value.clone()) {
            Ok(rule) => match dict_repo.upsert_by_name(&from_core_dict_rule(rule)) {
                Ok(_) => {}
                Err(e) => log::warn!("恢复词典规则失败（已跳过）: {e}"),
            },
            Err(e) => log::warn!("恢复词典规则解析失败（已跳过）: {e}"),
        }
    }

    // 键盘辅助规则（主键 (type, key)，INSERT OR REPLACE）
    let assist_repo = KeyboardAssistRepository::new(conn);
    for value in &backup.keyboard_assists {
        match serde_json::from_value::<KeyboardAssist>(value.clone()) {
            Ok(assist) => match assist_repo.insert_record(&assist) {
                Ok(()) => {}
                Err(e) => log::warn!("恢复键盘辅助规则失败（已跳过）: {e}"),
            },
            Err(e) => log::warn!("恢复键盘辅助规则解析失败（已跳过）: {e}"),
        }
    }

    Ok(stats)
}

/// 列出备份文件
///
/// 列出目录中的 .json 备份文件，返回 JSON 数组。
pub fn backup_list(dir: &str) -> String {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return "[]".to_string(),
    };

    let files: Vec<serde_json::Value> = entries
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path()
                .extension()
                .map(|ext| ext == "json")
                .unwrap_or(false)
        })
        .filter_map(|e| {
            let path = e.path();
            let metadata = e.metadata().ok()?;
            let name = path.file_name()?.to_str()?.to_string();
            let size = metadata.len();
            let modified = metadata
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            Some(serde_json::json!({
                "name": name,
                "path": path.to_str().unwrap_or_default(),
                "size": size,
                "modified": modified,
            }))
        })
        .collect();

    serde_json::to_string(&files).unwrap_or_else(|_| "[]".to_string())
}

/// 导入旧版（阅读 2.x）备份目录
///
/// 对齐 `ImportOldData.importUri`：扫描 `myBookShelf.json` / `myBookSource.json` /
/// `myBookReplaceRule.json`，字段映射后写入 DB。缺文件不致命，记入 messages。
pub fn import_old_data(dir: &str) -> LegadoResult<String> {
    let dir_path = Path::new(dir);
    if !dir_path.is_dir() {
        return Err(LegadoError::Io(std::io::Error::other(format!(
            "目录不存在或不可用: {dir}"
        ))));
    }

    let mut messages: Vec<String> = Vec::new();
    let mut books_n = 0usize;
    let mut sources_n = 0usize;
    let mut rules_n = 0usize;

    // 书架
    let shelf_path = dir_path.join("myBookShelf.json");
    if shelf_path.is_file() {
        match fs::read_to_string(&shelf_path) {
            Ok(json) => match with_database(|db| {
                let conn = db.connection();
                let book_repo = BookRepository::new(conn);
                let existing: std::collections::HashSet<String> = book_repo
                    .find_all()?
                    .into_iter()
                    .map(|b| b.book_url)
                    .collect();
                let books = legado_core::import_old::from_old_books(&json, &existing);
                let mut n = 0usize;
                for book in &books {
                    match book_repo.insert(book) {
                        Ok(()) => n += 1,
                        Err(e) => log::warn!("导入旧版书籍失败（已跳过）: {} - {e}", book.book_url),
                    }
                }
                Ok(n)
            }) {
                Ok(n) => {
                    books_n = n;
                    messages.push(format!("成功导入书架{n}"));
                }
                Err(e) => messages.push(format!("导入书架失败: {e}")),
            },
            Err(e) => messages.push(format!("导入书架失败: {e}")),
        }
    } else {
        messages.push("未找到 myBookShelf.json".to_string());
    }

    // 书源
    let source_path = dir_path.join("myBookSource.json");
    if source_path.is_file() {
        match fs::read_to_string(&source_path) {
            Ok(json) => match with_database(|db| {
                let conn = db.connection();
                let source_repo = BookSourceRepository::new(conn);
                let sources = legado_core::import_old::from_old_book_sources(&json);
                let mut n = 0usize;
                for source in &sources {
                    match source_repo.insert(source) {
                        Ok(()) => n += 1,
                        Err(e) => log::warn!(
                            "导入旧版书源失败（已跳过）: {} - {e}",
                            source.book_source_url
                        ),
                    }
                }
                Ok(n)
            }) {
                Ok(n) => {
                    sources_n = n;
                    messages.push(format!("成功导入书源{n}"));
                }
                Err(e) => messages.push(format!("导入源失败: {e}")),
            },
            Err(e) => messages.push(format!("导入源失败: {e}")),
        }
    } else {
        messages.push("未找到 myBookSource.json".to_string());
    }

    // 替换规则
    let rule_path = dir_path.join("myBookReplaceRule.json");
    if rule_path.is_file() {
        match fs::read_to_string(&rule_path) {
            Ok(json) => match with_database(|db| {
                let conn = db.connection();
                let rule_repo = ReplaceRuleRepository::new(conn);
                let rules = legado_core::import_old::from_old_replace_rules(&json);
                let mut n = 0usize;
                for rule in &rules {
                    match rule_repo.insert(rule) {
                        Ok(_) => n += 1,
                        Err(e) => log::warn!("导入旧版替换规则失败（已跳过）: {} - {e}", rule.name),
                    }
                }
                Ok(n)
            }) {
                Ok(n) => {
                    rules_n = n;
                    messages.push(format!("成功导入替换规则{n}"));
                }
                Err(e) => messages.push(format!("导入替换规则失败: {e}")),
            },
            Err(e) => messages.push(format!("导入替换规则失败: {e}")),
        }
    } else {
        messages.push("未找到替换规则".to_string());
    }

    let result = serde_json::json!({
        "books": books_n,
        "bookSources": sources_n,
        "replaceRules": rules_n,
        "messages": messages,
    });
    serde_json::to_string(&result)
        .map_err(|e| LegadoError::Internal(format!("统计序列化失败: {e}")))
}

/// v1 备份 RSS 条目布尔列整形（0/1 整数 → bool）
///
/// v1 备份对 rssSources 采用 `SELECT *` 直出（布尔列落为整数 0/1、
/// 空值列落为 null），与 serde 模型的 bool/Option<bool> 形态不符——
/// 旧恢复链因此整条解析失败（叠加 7 列旁路写入，即审查报告 P1-6）。
/// v2 起备份改走 repository 模型序列化；本函数仅用于兼容旧备份恢复。
fn normalize_v1_rss_entry(value: &serde_json::Value) -> serde_json::Value {
    /// RssSource 模型中 bool / Option<bool> 字段对应的 JSON 键
    const BOOL_KEYS: [&str; 8] = [
        "enabled",
        "singleUrl",
        "enableJs",
        "loadWithBaseUrl",
        "showWebLog",
        "preload",
        "cacheFirst",
        "enabledCookieJar",
    ];
    match value {
        serde_json::Value::Object(map) => {
            let mut map = map.clone();
            for key in BOOL_KEYS {
                if let Some(n) = map.get(key).and_then(|v| v.as_i64()) {
                    map.insert(key.to_string(), serde_json::Value::Bool(n != 0));
                }
            }
            serde_json::Value::Object(map)
        }
        other => other.clone(),
    }
}

/// 仓库分组 → 原版模型分组（serde 键对齐原版 bookGroup.json）
fn to_core_book_group(g: &BookGroup) -> legado_core::models::BookGroup {
    legado_core::models::BookGroup {
        group_id: g.group_id,
        group_name: g.group_name.clone(),
        cover: g.cover.clone(),
        order: g.order,
        enable_refresh: g.enable_refresh,
        show: g.show,
        book_sort: g.book_sort,
        only_update_read: g.only_update_read,
    }
}

/// 原版模型分组 → 仓库分组（恢复路径）
fn from_core_book_group(g: legado_core::models::BookGroup) -> BookGroup {
    BookGroup {
        group_id: g.group_id,
        group_name: g.group_name,
        cover: g.cover,
        order: g.order,
        enable_refresh: g.enable_refresh,
        show: g.show,
        book_sort: g.book_sort,
        only_update_read: g.only_update_read,
    }
}

/// 仓库 RSS 收藏 → 原版模型收藏（serde 键对齐原版 rssStar.json）
///
/// link 为 NOT NULL 列：仓库侧空值读为 None，备份时按空串落 JSON。
fn to_core_rss_star(s: &RssStarRecord) -> legado_core::models::RssStar {
    legado_core::models::RssStar {
        origin: s.origin.clone(),
        sort: s.sort.clone(),
        title: s.title.clone(),
        star_time: s.star_time,
        link: s.link.clone().unwrap_or_default(),
        pub_date: s.pub_date.clone(),
        description: s.description.clone(),
        content: s.content.clone(),
        image: s.image.clone(),
        group: s.group.clone(),
        variable: s.variable.clone(),
        star_type: s.star_type,
        dur_pos: s.dur_pos,
    }
}

/// 原版模型收藏 → 仓库 RSS 收藏（恢复路径；空 link 交由 add_star 生成兼容键）
fn from_core_rss_star(s: legado_core::models::RssStar) -> RssStarRecord {
    RssStarRecord {
        origin: s.origin,
        sort: s.sort,
        title: s.title,
        star_time: s.star_time,
        link: if s.link.is_empty() {
            None
        } else {
            Some(s.link)
        },
        pub_date: s.pub_date,
        description: s.description,
        content: s.content,
        image: s.image,
        variable: s.variable,
        group: s.group,
        star_type: s.star_type,
        dur_pos: s.dur_pos,
    }
}

/// 仓库 TXT 目录规则 → 原版模型规则（serde 键对齐原版 txtTocRule.json）
fn to_core_txt_toc_rule(r: &TxtTocRuleRecord) -> legado_core::models::TxtTocRule {
    legado_core::models::TxtTocRule {
        id: r.id,
        name: r.name.clone(),
        rule: r.rule.clone(),
        replacement: r.replacement.clone(),
        example: r.example.clone(),
        serial_number: r.serial_number,
        enable: r.enable,
    }
}

/// 原版模型规则 → 仓库 TXT 目录规则（恢复路径）
fn from_core_txt_toc_rule(r: legado_core::models::TxtTocRule) -> TxtTocRuleRecord {
    TxtTocRuleRecord {
        id: r.id,
        name: r.name,
        rule: r.rule,
        replacement: r.replacement,
        serial_number: r.serial_number,
        enable: r.enable,
        example: r.example,
    }
}

/// 仓库词典规则 → 原版模型规则（serde 键对齐原版 dictRule.json；id 不随备份——
/// name 为 UNIQUE 业务键，恢复经 upsert_by_name 保留库内 id）
fn to_core_dict_rule(r: &DictRule) -> legado_core::models::DictRule {
    legado_core::models::DictRule {
        name: r.name.clone(),
        url_rule: r.url_rule.clone(),
        show_rule: r.show_rule.clone(),
        enabled: r.is_enabled,
        sort_number: r.sort_order,
    }
}

/// 原版模型规则 → 仓库词典规则（恢复路径；id=0 交由 upsert_by_name 处理）
fn from_core_dict_rule(r: legado_core::models::DictRule) -> DictRule {
    DictRule {
        id: 0,
        name: r.name,
        url_rule: r.url_rule,
        show_rule: r.show_rule,
        is_enabled: r.enabled,
        sort_order: r.sort_number,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造全空 BackupData（测试用；按需填入待恢复列表）
    fn empty_backup() -> BackupData {
        BackupData {
            version: BACKUP_VERSION,
            backup_time: 0,
            books: vec![],
            bookmarks: vec![],
            replace_rules: vec![],
            book_sources: vec![],
            rss_sources: vec![],
            read_records: vec![],
            book_groups: vec![],
            rss_stars: vec![],
            highlights: vec![],
            highlight_rules: vec![],
            search_history: vec![],
            rule_subs: vec![],
            txt_toc_rules: vec![],
            http_tts: vec![],
            dict_rules: vec![],
            keyboard_assists: vec![],
        }
    }

    /// 清空备份覆盖的全部表（共享测试库；调用方须持 ensure_test_db 串行锁）
    fn clear_backup_tables() {
        with_database(|db| {
            let conn = db.connection();
            for table in [
                "books",
                "bookmarks",
                "replace_rules",
                "book_sources",
                "rssSources",
                "readRecord",
                "book_groups",
                "rssStars",
                "highlights",
                "highlightRules",
                "search_keywords",
                "ruleSubs",
                "txtTocRules",
                "httpTTS",
                "dictRules",
                "keyboardAssists",
            ] {
                conn.execute(&format!("DELETE FROM {table}"), [])
                    .map_err(|e| LegadoError::Database(format!("清空 {table} 失败: {e}")))?;
            }
            Ok(())
        })
        .unwrap();
    }

    /// 构造全字段 RSS 源种子（覆盖规则/登录/请求头等 v1 曾丢失的关键列）
    fn make_full_rss_source() -> RssSource {
        RssSource {
            source_url: "https://rss.example.com/roundtrip".to_string(),
            source_name: "往返源".to_string(),
            source_icon: "https://rss.example.com/icon.png".to_string(),
            source_group: Some("分组A".to_string()),
            source_comment: Some("源注释".to_string()),
            enabled: false,
            sort_url: Some("{\"新闻\":\"https://news.example\"}".to_string()),
            custom_order: 9,
            last_update_time: 1700000000000,
            header: Some("{\"User-Agent\":\"RoundTripUA\"}".to_string()),
            enable_js: true,
            load_with_base_url: true,
            variable_comment: Some("变量说明".to_string()),
            login_url: Some("https://rss.example.com/login".to_string()),
            login_ui: Some("[{\"name\":\"user\"}]".to_string()),
            login_check_js: Some("return true;".to_string()),
            cover_decode_js: Some("coverDecode()".to_string()),
            concurrent_rate: Some("3".to_string()),
            rule_articles: Some("class.item".to_string()),
            rule_next_page: Some("text.下一页@href".to_string()),
            rule_title: Some("h1@text".to_string()),
            rule_pub_date: Some(".date@text".to_string()),
            rule_description: Some(".desc@text".to_string()),
            rule_image: Some("img@src".to_string()),
            rule_link: Some("a@href".to_string()),
            rule_content: Some(".content@textNodes".to_string()),
            // P1-2：原版 RssSource.nextContentUrl（正文下一页规则）必须随备份往返
            next_content_url: Some(".nextPage@href".to_string()),
            style: Some("body{margin:0}".to_string()),
            article_style: 2,
            single_url: true,
            js_lib: Some("jsLib()".to_string()),
            enabled_cookie_jar: Some(true),
            content_whitelist: Some("ok.example".to_string()),
            content_blacklist: Some("ad.example".to_string()),
            should_override_url_loading: Some("return false;".to_string()),
            inject_js: Some("inject()".to_string()),
            preload_js: Some("preload()".to_string()),
            start_html: Some("<html>start</html>".to_string()),
            start_style: Some("a{color:red}".to_string()),
            start_js: Some("start()".to_string()),
            show_web_log: true,
            rss_type: 1,
            preload: true,
            cache_first: true,
            search_url: Some("search?q={{key}}".to_string()),
        }
    }

    /// [P1-6 往返回归] RSS 源备份→清库→恢复→全列 diff
    ///
    /// 根因：v1 恢复走 7 列 INSERT 旁路（且布尔列整型形态解析必败），
    /// 恢复即抹掉 ruleArticles/searchUrl/loginUrl/header 等全部规则数据。
    #[test]
    fn test_rss_source_backup_restore_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_roundtrip_rss");
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("rss_roundtrip.json");
        let path_str = backup_path.to_str().unwrap();

        // 种子：全字段 RSS 源
        let seed = make_full_rss_source();
        with_database(|db| {
            RssSourceRepository::new(db.connection())
                .insert(&seed)
                .map_err(LegadoError::Database)
        })
        .unwrap();

        // 备份 → 清库 → 恢复
        assert!(backup_create(path_str).is_ok());
        with_database(|db| {
            db.connection()
                .execute("DELETE FROM rssSources", [])
                .map_err(|e| LegadoError::Database(format!("清库失败: {e}")))?;
            Ok(())
        })
        .unwrap();
        let stats_json = backup_restore(path_str).unwrap();
        let stats: RestoreStats = serde_json::from_str(&stats_json).unwrap();
        assert_eq!(stats.rss_sources, 1, "应恢复恰好 1 条 RSS 源");

        // 逐列 diff：恢复后模型与种子全字段一致
        let restored = with_database(|db| {
            RssSourceRepository::new(db.connection())
                .find_by_url("https://rss.example.com/roundtrip")
                .map_err(LegadoError::Database)
        })
        .unwrap()
        .expect("恢复后该源应存在");
        assert_eq!(
            serde_json::to_value(&restored).unwrap(),
            serde_json::to_value(&seed).unwrap(),
            "RSS 源往返后逐列应完全一致"
        );
        // 关键列具名断言（失败信息可读性）
        assert_eq!(restored.rule_articles.as_deref(), Some("class.item"));
        assert_eq!(
            restored.next_content_url.as_deref(),
            Some(".nextPage@href"),
            "nextContentUrl 应随备份往返保留（原版 RssSource 正文下一页规则）"
        );
        assert_eq!(restored.search_url.as_deref(), Some("search?q={{key}}"));
        assert_eq!(
            restored.login_url.as_deref(),
            Some("https://rss.example.com/login")
        );
        assert_eq!(
            restored.header.as_deref(),
            Some("{\"User-Agent\":\"RoundTripUA\"}")
        );

        let _ = fs::remove_dir_all(&dir);
    }

    /// [P1-7 回归] ReadRecord 恢复：双设备 fixture，较新者胜 + deviceId 归属 + author/lastRead 落库
    #[test]
    fn test_read_record_restore_merge_two_devices() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_roundtrip_readrecord");
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("readrecord_merge.json");
        let path_str = backup_path.to_str().unwrap();

        // 预置本机库内记录（较新：readTime=200）
        with_database(|db| {
            ReadRecordRepository::new(db.connection()).upsert_full("", "书X", "作者乙", 200, 20)
        })
        .unwrap();

        // 备份包含：非本机 device-A 记录（直接插入）+ 本机较旧记录（仅合并作者）
        let mut backup = empty_backup();
        backup.read_records = vec![
            serde_json::json!({
                "deviceId": "device-A", "bookName": "书X",
                "author": "作者甲", "readTime": 500, "lastRead": 50
            }),
            serde_json::json!({
                "deviceId": "", "bookName": "书X",
                "author": "作者丙", "readTime": 100, "lastRead": 5
            }),
            // 本机传入较新：整行覆盖（含空作者时保留库内作者）
            serde_json::json!({
                "deviceId": "", "bookName": "书Y",
                "author": "", "readTime": 999, "lastRead": 99
            }),
        ];
        let json = serde_json::to_string(&backup).unwrap();
        fs::write(path_str, json).unwrap();

        // 预置书Y本机旧记录（readTime=50，作者丁）
        with_database(|db| {
            ReadRecordRepository::new(db.connection()).upsert_full("", "书Y", "作者丁", 50, 5)
        })
        .unwrap();

        let stats_json = backup_restore(path_str).unwrap();
        let stats: RestoreStats = serde_json::from_str(&stats_json).unwrap();
        assert_eq!(stats.read_records, 3);

        with_database(|db| {
            let repo = ReadRecordRepository::new(db.connection());

            // 非本机记录：deviceId 归属正确，author/lastRead 原样落库
            let all = repo.find_all().unwrap();
            let foreign = all.iter().find(|r| r.device_id == "device-A").unwrap();
            assert_eq!(foreign.book_name, "书X");
            assert_eq!(foreign.read_time, 500);
            assert_eq!(foreign.last_read, 50);
            assert_eq!(foreign.author, "作者甲");

            // 本机较旧记录：readTime/lastRead 保留库内值，作者合并为集合
            let local_x = all
                .iter()
                .find(|r| r.device_id.is_empty() && r.book_name == "书X")
                .unwrap();
            assert_eq!(
                local_x.read_time, 200,
                "本机库内较新 readTime 不得被旧备份覆盖"
            );
            assert_eq!(local_x.last_read, 20);
            let authors: Vec<String> = serde_json::from_str(
                local_x
                    .author
                    .strip_prefix("\u{1E}authors:")
                    .unwrap_or(&local_x.author),
            )
            .unwrap_or_default();
            assert!(
                authors.contains(&"作者乙".to_string()),
                "库内作者应保留: {}",
                local_x.author
            );
            assert!(
                authors.contains(&"作者丙".to_string()),
                "备份作者应合并: {}",
                local_x.author
            );

            // 本机传入较新：整行覆盖，空作者不抹掉库内作者
            let local_y = all
                .iter()
                .find(|r| r.device_id.is_empty() && r.book_name == "书Y")
                .unwrap();
            assert_eq!(local_y.read_time, 999);
            assert_eq!(local_y.last_read, 99);
            assert_eq!(local_y.author, "作者丁");

            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// [P1-9 第一步回归] 10 张在库新表：逐表备份→清库→恢复→逐字段 diff
    #[test]
    fn test_new_tables_backup_restore_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_roundtrip_newtables");
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("new_tables_roundtrip.json");
        let path_str = backup_path.to_str().unwrap();

        // ── 种子（各表全字段） ──────────────────────────────────
        let seed_group = BookGroup {
            group_id: 7,
            group_name: "往返分组".to_string(),
            cover: Some("cover.png".to_string()),
            order: 4,
            enable_refresh: false,
            show: false,
            book_sort: 2,
            only_update_read: true,
        };
        let seed_star = legado_core::models::RssStar {
            origin: "https://rss.example.com".to_string(),
            sort: "default".to_string(),
            title: "收藏文章".to_string(),
            star_time: 1700001111222,
            link: "https://rss.example.com/article/1".to_string(),
            pub_date: Some("2026-01-01".to_string()),
            description: Some("摘要".to_string()),
            content: None,
            image: Some("https://img.example/1.png".to_string()),
            group: "技术".to_string(),
            variable: Some("v".to_string()),
            star_type: 1,
            dur_pos: 7,
        };
        let seed_highlight = legado_core::models::BookHighlight {
            time: 111,
            bookUrl: "bk://1".to_string(),
            chapterUrl: "ch://0".to_string(),
            bookName: "高亮书".to_string(),
            bookAuthor: "作者A".to_string(),
            chapterIndex: 3,
            chapterPos: 12,
            chapterPosEnd: 34,
            layoutTitleLength: 5,
            chapterName: "第四章".to_string(),
            bookText: "被高亮文本".to_string(),
            style: "{\"bg\":1}".to_string(),
            note: "笔记".to_string(),
        };
        let seed_rule = legado_core::models::HighlightRule {
            id: 5,
            name: "往返规则".to_string(),
            pattern: "关键[词]".to_string(),
            isRegex: true,
            scope: Some("高亮书".to_string()),
            isEnabled: false,
            style: "{}".to_string(),
            sortOrder: -2,
            timeoutMillisecond: 1500,
            applyToTitle: true,
            // [P2-11] uuid/applyToBody 全字段往返（uuid 唯一、applyToBody 仅正文）
            uuid: "44444444-4444-4444-8444-444444444444".to_string(),
            applyToBody: false,
        };
        let seed_keyword = legado_core::models::SearchKeyword {
            word: "往返关键词".to_string(),
            usage: 3,
            last_use_time: 1700002222333,
        };
        let seed_sub = RuleSubRecord {
            id: 21,
            url: "https://sub.example/rt.json".to_string(),
            name: "往返订阅".to_string(),
            sub_type: "replaceRule".to_string(),
            last_update: 1700003333444,
            version: "2.1".to_string(),
            is_enabled: false,
            created_at: 1700000000000,
            custom_order: 5,
            auto_update: true,
            update_interval: 30,
            silent_update: true,
            js: Some("js()".to_string()),
            show_rule: Some("$.list".to_string()),
            source_url: Some("https://src.example/rt.json".to_string()),
        };
        let seed_toc_rule = TxtTocRuleRecord {
            id: 13,
            name: "往返目录规则".to_string(),
            rule: r"^第\s*\d+\s*章".to_string(),
            replacement: "[章]".to_string(),
            serial_number: -1,
            enable: false,
            example: Some("第1章".to_string()),
        };
        let seed_tts = HttpTts {
            id: 3,
            name: "往返引擎".to_string(),
            url: "https://tts.example/?t={{speakText}}".to_string(),
            content_type: "audio/mpeg".to_string(),
            is_enabled: false,
            created_at: 1700004444555,
            pause_duration: 250,
            concurrent_rate: Some("1".to_string()),
            login_url: Some("https://tts.example/login".to_string()),
            login_ui: Some("[{\"name\":\"k\"}]".to_string()),
            header: Some("{\"X-Test\":\"1\"}".to_string()),
            js_lib: Some("ttsLib()".to_string()),
            enabled_cookie_jar: Some(true),
            login_check_js: Some("return 0;".to_string()),
        };
        let seed_dict = legado_core::models::DictRule {
            name: "往返词典".to_string(),
            url_rule: "https://dict.example/{{key}}".to_string(),
            show_rule: "tag.body@all".to_string(),
            enabled: false,
            sort_number: 9,
        };
        let seed_assist = KeyboardAssist {
            assist_type: 1,
            key: "rt_key".to_string(),
            value: "往返值".to_string(),
            serial_no: 6,
        };

        with_database(|db| {
            let conn = db.connection();
            BookGroupRepository::new(conn).upsert(&seed_group).unwrap();
            RssStarRepository::new(conn)
                .add_star(&from_core_rss_star(seed_star.clone()))
                .unwrap();
            HighlightRepository::new(conn)
                .insert(&seed_highlight)
                .unwrap();
            HighlightRuleRepository::new(conn)
                .insert(&seed_rule)
                .unwrap();
            SearchKeywordRepository::new(conn)
                .upsert_record(&seed_keyword)
                .unwrap();
            RuleSubRepository::new(conn).upsert(&seed_sub).unwrap();
            TxtTocRuleRepository::new(conn)
                .upsert(&seed_toc_rule)
                .unwrap();
            HttpTtsRepository::new(conn).upsert(&seed_tts).unwrap();
            DictRuleRepository::new(conn)
                .upsert_by_name(&from_core_dict_rule(seed_dict.clone()))
                .unwrap();
            KeyboardAssistRepository::new(conn)
                .insert_record(&seed_assist)
                .unwrap();
            Ok(())
        })
        .unwrap();

        // 备份 → 清库 → 恢复
        assert!(backup_create(path_str).is_ok());
        clear_backup_tables();
        backup_restore(path_str).unwrap();

        // ── 逐字段 diff ────────────────────────────────────────
        with_database(|db| {
            let conn = db.connection();

            // 1. book_groups
            let group = BookGroupRepository::new(conn)
                .find_by_id(7)
                .unwrap()
                .unwrap();
            assert_eq!(
                serde_json::to_value(&group).unwrap(),
                serde_json::to_value(&seed_group).unwrap(),
                "book_groups 往返逐列不一致"
            );

            // 2. rssStars
            let stars = RssStarRepository::new(conn).find_all().unwrap();
            assert_eq!(stars.len(), 1, "rssStars 应恰好恢复 1 条");
            assert_eq!(
                serde_json::to_value(to_core_rss_star(&stars[0])).unwrap(),
                serde_json::to_value(&seed_star).unwrap(),
                "rssStars 往返逐列不一致"
            );

            // 3. highlights
            let highlight = HighlightRepository::new(conn)
                .find_by_time(111)
                .unwrap()
                .unwrap();
            assert_eq!(
                serde_json::to_value(&highlight).unwrap(),
                serde_json::to_value(&seed_highlight).unwrap(),
                "highlights 往返逐列不一致"
            );

            // 4. highlightRules
            let rule = HighlightRuleRepository::new(conn)
                .find_by_id(5)
                .unwrap()
                .unwrap();
            assert_eq!(
                serde_json::to_value(&rule).unwrap(),
                serde_json::to_value(&seed_rule).unwrap(),
                "highlightRules 往返逐列不一致"
            );
            // [P2-11] uuid/applyToBody 两列显式断言
            assert_eq!(
                rule.uuid, "44444444-4444-4444-8444-444444444444",
                "uuid 应随备份往返保留"
            );
            assert!(!rule.applyToBody, "applyToBody 应随备份往返保留");

            // 5. search_keywords（usage/lastUseTime 原样保留）
            let keywords = SearchKeywordRepository::new(conn).find_all().unwrap();
            assert_eq!(keywords.len(), 1);
            assert_eq!(
                serde_json::to_value(&keywords[0]).unwrap(),
                serde_json::to_value(&seed_keyword).unwrap(),
                "search_keywords 往返逐列不一致"
            );

            // 6. ruleSubs（行 id 保留）
            let sub = RuleSubRepository::new(conn)
                .find_by_url("https://sub.example/rt.json")
                .unwrap()
                .unwrap();
            assert_eq!(sub.id, 21, "恢复应保留备份行 id");
            assert_eq!(
                serde_json::to_value(&sub).unwrap(),
                serde_json::to_value(&seed_sub).unwrap(),
                "ruleSubs 往返逐列不一致"
            );

            // 7. txtTocRules（id/enable/example/replacement 全列）
            let toc_rules = TxtTocRuleRepository::new(conn).find_all().unwrap();
            assert_eq!(toc_rules.len(), 1);
            assert_eq!(
                serde_json::to_value(&toc_rules[0]).unwrap(),
                serde_json::to_value(&seed_toc_rule).unwrap(),
                "txtTocRules 往返逐列不一致"
            );

            // 8. httpTTS（全 14 列）
            let tts = HttpTtsRepository::new(conn).find_by_id(3).unwrap().unwrap();
            assert_eq!(
                serde_json::to_value(&tts).unwrap(),
                serde_json::to_value(&seed_tts).unwrap(),
                "httpTTS 往返逐列不一致"
            );

            // 9. dictRules（按 name REPLACE，库内 id 保留）
            let dict = DictRuleRepository::new(conn)
                .find_by_name("往返词典")
                .unwrap()
                .unwrap();
            assert_eq!(
                serde_json::to_value(to_core_dict_rule(&dict)).unwrap(),
                serde_json::to_value(&seed_dict).unwrap(),
                "dictRules 往返逐列不一致"
            );

            // 10. keyboardAssists
            let assist = KeyboardAssistRepository::new(conn)
                .find_by_pk(1, "rt_key")
                .unwrap()
                .unwrap();
            assert_eq!(
                serde_json::to_value(&assist).unwrap(),
                serde_json::to_value(&seed_assist).unwrap(),
                "keyboardAssists 往返逐列不一致"
            );

            Ok(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// 版本兼容：v1 旧备份（无新表字段 + readRecord 旧 snake 键 + RSS 整数布尔）仍可解析恢复
    #[test]
    fn test_v1_backup_still_restorable() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_v1_compat");
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("v1_backup.json");
        let path_str = backup_path.to_str().unwrap();

        // v1 形态：readRecord 走仓库结构体旧 snake 键；rssSources 为 SELECT * 直出
        //（布尔列 0/1 整数）；完全不含 v2 新表字段、version 亦缺省
        let v1_json = r#"{
            "backupTime": 123456,
            "books": [],
            "bookmarks": [],
            "replaceRules": [],
            "bookSources": [],
            "rssSources": [
                {"sourceUrl": "https://v1.example/rss", "sourceName": "v1源",
                 "sourceIcon": "https://v1.example/i.png", "sourceGroup": "v1分组",
                 "enabled": 1, "customOrder": 4, "type": 2}
            ],
            "readRecords": [
                {"deviceId": "", "book_name": "旧书记录", "author": "旧作者",
                 "read_time": 321, "lastRead": 9}
            ]
        }"#;
        fs::write(path_str, v1_json).unwrap();

        let stats_json = backup_restore(path_str).unwrap();
        let stats: RestoreStats = serde_json::from_str(&stats_json).unwrap();
        assert_eq!(stats.rss_sources, 1, "v1 RSS 整数布尔应经归一后恢复");
        assert_eq!(stats.read_records, 1, "v1 readRecord 旧键应经 alias 恢复");

        with_database(|db| {
            let conn = db.connection();
            // RSS：布尔归一 + 非布尔列落库
            let rss = RssSourceRepository::new(conn)
                .find_by_url("https://v1.example/rss")
                .unwrap()
                .unwrap();
            assert!(rss.enabled, "v1 整数布尔 1 应归一为 true");
            assert_eq!(rss.custom_order, 4);
            assert_eq!(rss.rss_type, 2);

            // readRecord：旧 snake 键 alias 解析，全字段落库
            let record = ReadRecordRepository::new(conn)
                .find_all()
                .unwrap()
                .into_iter()
                .next()
                .unwrap();
            assert_eq!(record.book_name, "旧书记录");
            assert_eq!(record.author, "旧作者");
            assert_eq!(record.read_time, 321);
            assert_eq!(record.last_read, 9);
            Ok(())
        })
        .unwrap();

        // 完全缺 version 的备份也可解析（serde default 兜底）
        let no_version_path = dir.join("no_version.json");
        fs::write(&no_version_path, r#"{"backupTime": 1}"#).unwrap();
        assert!(backup_restore(no_version_path.to_str().unwrap()).is_ok());

        let _ = fs::remove_dir_all(&dir);
    }

    /// [P1-A 回归] 恢复体单事务——条目级错误 warn 跳过照常提交
    ///
    /// 语义锚点：条目错误在恢复体闭包内被捕获（warn 跳过），闭包返回 Ok，
    /// 事务必须照常 COMMIT——合法条目不受同批垃圾条目牵连。
    #[test]
    fn test_restore_entry_level_warn_still_commits() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        // 一条合法书源 + 一条解析必败条目（字符串形态，非对象 →
        // serde_json::from_value::<BookSource> 失败走 warn 跳过分支）
        let mut backup = empty_backup();
        backup.book_sources = vec![
            serde_json::json!({
                "bookSourceUrl": "https://tx.example/source-a",
                "bookSourceName": "事务源A",
            }),
            serde_json::json!("不是对象的垃圾条目"),
        ];

        with_database(|db| {
            let conn = db.connection();
            let stats = legado_db::connection::in_transaction(conn, "测试恢复", |conn| {
                restore_backup_in_tx(conn, &backup)
            })
            .unwrap();
            assert_eq!(
                stats.book_sources, 1,
                "仅合法条目计入统计，垃圾条目 warn 跳过"
            );
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        // 事务已提交：合法条目在库
        with_database(|db| {
            let restored = BookSourceRepository::new(db.connection())
                .find_by_url("https://tx.example/source-a")
                .unwrap();
            assert!(
                restored.is_some(),
                "warn 跳过路径应照常提交，合法条目应落库"
            );
            Ok(())
        })
        .unwrap();
    }

    /// [P1-A 回归] 恢复体未捕获 Err → 整体回滚零残留
    ///
    /// 说明：全部条目级错误均在恢复体 match 分支内被 warn 吞掉，外部备份
    /// 数据无法构造逃逸捕获网的 Err（见 restore_backup_in_tx 文档）；故以
    /// 拆出的可测函数 + 闭包内直接上抛 Err 模拟「恢复中未捕获错误」
    /// （如未来新增表写入漏捕获、SQLite 级故障），验证事务包裹的回滚语义。
    #[test]
    fn test_restore_uncaught_error_rolls_back_all() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let mut backup = empty_backup();
        backup.book_sources = vec![serde_json::json!({
            "bookSourceUrl": "https://rb.example/source-b",
            "bookSourceName": "回滚源B",
        })];
        backup.books = vec![serde_json::json!({
            "bookUrl": "https://rb.example/book-b",
            "name": "回滚书B",
        })];

        with_database(|db| {
            let conn = db.connection();
            let err = legado_db::connection::in_transaction(
                conn,
                "回滚测试",
                |conn| -> LegadoResult<RestoreStats> {
                    // 先经恢复体正常写入一批（若无事务包裹，此处已 autocommit 落库）
                    let stats = restore_backup_in_tx(conn, &backup).unwrap();
                    assert_eq!(stats.book_sources, 1);
                    assert_eq!(stats.books, 1);
                    // 模拟恢复体后续未捕获错误（条目捕获网之外的 Err）
                    Err(LegadoError::Internal("模拟恢复中未捕获错误".into()))
                },
            )
            .unwrap_err();
            assert!(
                err.to_string().contains("模拟恢复中未捕获错误"),
                "应上抛模拟错误: {err}"
            );

            // 整体回滚：恢复体写入的全部条目零残留
            let source = BookSourceRepository::new(conn)
                .find_by_url("https://rb.example/source-b")
                .unwrap();
            assert!(source.is_none(), "回滚后书源不得残留");
            let book = BookRepository::new(conn)
                .find_by_url("https://rb.example/book-b")
                .unwrap();
            assert!(book.is_none(), "回滚后书籍不得残留");
            Ok::<(), LegadoError>(())
        })
        .unwrap();
    }

    #[test]
    fn test_backup_create_and_restore() {
        let _db_guard = crate::db_state::ensure_test_db();

        let dir = std::env::temp_dir().join("legado_backup_test");
        let _ = fs::create_dir_all(&dir);
        let backup_path = dir.join("test_backup.json");
        let path_str = backup_path.to_str().unwrap();

        // 创建备份
        let result = backup_create(path_str);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), path_str);

        // 验证文件存在
        assert!(backup_path.exists());

        // 验证 JSON 格式与版本
        let content = fs::read_to_string(&backup_path).unwrap();
        let data: BackupData = serde_json::from_str(&content).unwrap();
        assert_eq!(data.version, BACKUP_VERSION, "新备份应携带当前格式版本 v2");
        assert!(data.backup_time > 0);

        // 恢复备份
        let restore_result = backup_restore(path_str);
        assert!(restore_result.is_ok());

        // 清理
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_backup_list() {
        let dir = std::env::temp_dir().join("legado_backup_list_test");
        let _ = fs::create_dir_all(&dir);

        // 创建测试文件
        let file1 = dir.join("backup1.json");
        let file2 = dir.join("backup2.json");
        let file3 = dir.join("not_backup.txt");
        fs::write(&file1, "{}").unwrap();
        fs::write(&file2, "{}").unwrap();
        fs::write(&file3, "text").unwrap();

        let result = backup_list(dir.to_str().unwrap());
        let list: Vec<serde_json::Value> = serde_json::from_str(&result).unwrap();
        assert_eq!(list.len(), 2);

        // 清理
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_backup_list_nonexistent_dir() {
        let result = backup_list("/nonexistent/path/that/does/not/exist");
        assert_eq!(result, "[]");
    }
}
