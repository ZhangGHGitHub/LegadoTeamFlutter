//! 备份/恢复 API
//!
//! 提供数据库备份创建、恢复和备份文件列表功能。
//! 备份格式为单文件 JSON（BackupData）：
//! - version=1（历史格式）：books/bookmarks/replaceRules/bookSources/rssSources/readRecords
//!   六类；其中 rssSources 为 `SELECT *` 直出（布尔列为 0/1 整数形态）。
//! - version=2（扩表批，对齐原版 `Backup.kt:279-330` 的表覆盖面）：新增
//!   bookGroups/rssStars/highlights/highlightRules/searchHistory/ruleSubs/
//!   txtTocRules/httpTTS/dictRules/keyboardAssists 十类；rssSources 改由
//!   `RssSourceRepository` 模型序列化（布尔为真 bool、None 字段省略）。
//! - version=3（批8，用户裁决②）：新增 `servers`（原版 `servers.json`
//!   实体数组形态），承载 WebDAV 同步/远程书库服务器配置。
//!
//! 兼容语义（防复发规定 9：备份格式版本化）：恢复器按字段驱动解析，
//! 全部列表字段 `#[serde(default)]`——旧备份（无 version 或 version<2）
//! 缺失的新表字段按空数组处理，仍可正常恢复；恢复时对 v1 整数布尔做归一整形。
//! `servers` 缺失（v1/v2 备份）时**不触碰库内 servers**，对齐原版
//! `Restore.kt:379-390` 仅在 `servers.json` 存在时 insert 的语义；存在时按
//! 备份中的原主键（含 `id = 0`）REPLACE 写入，不做毫秒重分配。
//!
//! # 原版 zip 备份恢复（批9，用户裁决⑥）
//!
//! 入口按**文件魔数**分流：`PK\x03\x04` / `PK\x05\x06` 走 zip 分支，其余按自有
//! 单文件 JSON 解析（[`BackupData`]）。zip 分支只做「读包 + 逐文件转 [`BackupData`]」，
//! 落库仍走同一个 [`restore_backup_in_tx`]（单实现原则，不复制第二套写库逻辑）。
//!
//! 原版 `Backup.kt` 写出的文件清单（`selectedBackupFileNames` + 固定写出项）：
//! - 书架/分组：`bookshelf.json`、`bookGroup.json`
//! - 标注：`bookmark.json`、`highlight.json`（`writeEmpty=true`）、`highlightRule.json`
//! - 源：`bookSource.json`、`rssSources.json`、`rssStar.json`、`sourceSub.json`
//! - 规则：`replaceRule.json`、`txtTocRule.json`、`httpTTS.json`、`keyboardAssists.json`、
//!   `dictRule.json`、`autoTask.json`、`servers.json`
//! - 历史：`readRecord.json`、`searchHistory.json`
//! - 设置：`readConfig.json`、`shareReadConfig.json`、`themeConfig.json`、`coverRule.json`、
//!   `directLinkUploadRule.json`、`config.xml`、`videoConfig.xml`
//! - 可选加密：`cookies.json`、`runtimeSourceCache.json`
//! - 媒体：`covers/`（可含子目录）、`bg/`
//!
//! 加密口径（`BackupAES` + hutool 5.8 `new AES(key)`）：
//! - 密钥 = `MD5(password)` 小写十六进制串的**前 16 个 ASCII 字符**（不做 hex 解码）；
//! - 算法 = **AES-128-ECB / PKCS5Padding**（hutool `AES(byte[])` 默认 ECB）；
//! - `servers.json` **总是**先尝试加密（失败才退回明文）、恢复侧以「是否 JSON 数组」
//!   判别明文；`cookies.json` / `runtimeSourceCache.json` 仅在设置备份密码时写出，
//!   因此**文件存在即说明备份设过密码**——我方无密码输入面，直接给出明确错误文案
//!   （对齐原版 `Restore.kt` 在 cookies 存在且密码为空时上抛的语义）；
//! - `config.xml` 内的 `webDavPassword` 同密钥加密（本实现跳过整个偏好快照，见下）。
//!
//! 未映射项（本批登记，不静默）：`readConfig.json` / `shareReadConfig.json` /
//! `themeConfig.json` / `coverRule.json` / `directLinkUploadRule.json` /
//! `config.xml` / `videoConfig.xml` 与媒体目录 `covers/`、`bg/` 只记 warn 日志后跳过——
//! 我方没有等价的阅读主题配置面或封面/背景落盘目录（封面按 URL 直取、不落本地
//! `covers/`），恢复媒体会写到无人消费的目录并引入路径安全面；书内指向
//! `.../covers/xxx` 的绝对封面路径按原版 remap 失败语义置空（回落到书源封面 URL）。
//!
//! # 批9 审查回修登记（P2，仅登记，本批不实现）
//!
//! 以下缺口已由批次9 审查确认，登记于此避免静默，待后续批次立项：
//! - **P2-3** 原版旧格式 `bookSource.json`（早期 Room 实体的 `ruleSearch` 等
//!   扁平旧键）回退适配缺失：仅支持当前实体形态，旧源会因规则键不匹配而丢规则；
//! - **P2-4** `bookshelf.json` 的 `persistedCoverUrl`（原版落盘封面缓存路径）不恢复：
//!   我方封面按 URL 直取，无本地封面缓存语义；
//! - **P2-7** 旧高亮 `style` 的 legacy 样式串（原版 `HighlightStyle` 旧编码）缺失
//!   兼容：仅按新 JSON 样式解析；
//! - **P2-8** 明文 `cookies.json` / `runtimeSourceCache.json` 跳过：我方无 Cookie
//!   与书源运行变量持久化面，仅记 warn（不加密码面）；
//! - **P2-10** 部分恢复对用户不可见：条目级跳过只写日志，FFI `RestoreStats`
//!   无 warnings 字段。后续立项在统计结构增加 `warnings`（需同步 FFI 契约）。

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::Path;

use base64::Engine as _;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use legado_core::crypto::AesCrypto;
use legado_core::models::{Book, BookSource, Bookmark, RssSource};
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::Repository;
use legado_db::{
    AutoTaskRepository, BookGroup, BookGroupRepository, BookRepository, BookSourceRepository,
    BookmarkRepository, DictRule, DictRuleRepository, HighlightRepository, HighlightRuleRepository,
    HttpTts, HttpTtsRepository, KeyboardAssist, KeyboardAssistRepository, ReadRecord,
    ReadRecordRepository, ReplaceRuleRepository, RssSourceRepository, RssStarRecord,
    RssStarRepository, RuleSubRecord, RuleSubRepository, SearchKeywordRepository, ServerRepository,
    TxtTocRuleRecord, TxtTocRuleRepository,
};

use crate::db_state::with_database;

/// 当前备份格式版本（写入侧；恢复侧按字段兼容，不按版本分叉）
pub const BACKUP_VERSION: i32 = 3;

/// 备份数据结构
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupData {
    /// 备份版本（v1=初版六类；v2=扩表批十类；v3=servers 表，见模块注释的版本语义）
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
    /// 服务器配置列表（v3 新增，对齐原版 servers.json 实体数组）
    ///
    /// 元素形态为 `legado_core::models::Server`（`id`/`name`/`type`/`config`/
    /// `sortNumber`）。旧备份缺该键时解析为空数组——恢复器据空数组跳过，
    /// 不清库内既有 servers（对齐原版 Restore 缺 servers.json 不处理）。
    #[serde(default)]
    pub servers: Vec<serde_json::Value>,
    /// 自动任务列表（批9 新增，对齐原版 `autoTask.json`）
    ///
    /// 仅用于「恢复原版 zip 备份」：我方 `backup_create` 尚未收集该表，
    /// 序列化时按 `skip_serializing_if` 省略，故自有 JSON 备份形状不变
    /// （BackupData 版本仍为 v3）。收到该键时按主键 `id` REPLACE 写入。
    #[serde(default, skip_serializing_if = "Vec::is_empty", rename = "autoTasks")]
    pub auto_tasks: Vec<serde_json::Value>,
}

impl BackupData {
    /// 构造空备份（全部列表为空；供 zip 适配与测试使用）
    pub fn empty() -> Self {
        Self {
            version: BACKUP_VERSION,
            backup_time: 0,
            books: Vec::new(),
            bookmarks: Vec::new(),
            replace_rules: Vec::new(),
            book_sources: Vec::new(),
            rss_sources: Vec::new(),
            read_records: Vec::new(),
            book_groups: Vec::new(),
            rss_stars: Vec::new(),
            highlights: Vec::new(),
            highlight_rules: Vec::new(),
            search_history: Vec::new(),
            rule_subs: Vec::new(),
            txt_toc_rules: Vec::new(),
            http_tts: Vec::new(),
            dict_rules: Vec::new(),
            keyboard_assists: Vec::new(),
            servers: Vec::new(),
            auto_tasks: Vec::new(),
        }
    }
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
/// 收集 BackupData 全部 17 类数据（v3 覆盖面，对齐原版 `Backup.kt:279-330`
/// 中所有表已在库的类别 + `servers.json`），统一经各 repository 读取后模型序列化，
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

        // 服务器配置（v3：servers 表全量，形态对齐原版 servers.json）
        let servers: Vec<serde_json::Value> = ServerRepository::new(conn)
            .find_all()?
            .into_iter()
            .filter_map(|s| serde_json::to_value(&s).ok())
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
            servers,
            auto_tasks: Vec::new(),
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
    // [批9 回修 P1] 先按元数据限制输入包大小，避免把超大文件整体读入内存
    // （JSON 与 zip 两个入口共用；metadata 失败按读取失败报错）
    let metadata = fs::metadata(path)
        .map_err(|e| LegadoError::Io(std::io::Error::other(format!("读取备份文件失败: {e}"))))?;
    if metadata.len() > MAX_BACKUP_ARCHIVE_BYTES {
        return Err(LegadoError::Io(std::io::Error::other(format!(
            "备份文件过大（{} 字节，上限 {MAX_BACKUP_ARCHIVE_BYTES} 字节），已拒绝恢复: {path}",
            metadata.len()
        ))));
    }
    let bytes = fs::read(path)
        .map_err(|e| LegadoError::Io(std::io::Error::other(format!("读取备份文件失败: {e}"))))?;

    // 批9：按魔数分流——原版 zip 多文件备份 vs 自有单文件 JSON
    if is_zip_backup(&bytes) {
        return restore_from_zip(&bytes);
    }

    // [批9 回修 P1] 既非 zip 魔数、又不以 JSON 对象开头的文件（如带 stub 的
    // 自解压 zip、任意二进制）给出统一可读文案，而不是 UTF-8/serde 的原始报错。
    // 在 UTF-8 转换前按字节判定（二进制包可能整段不是合法 UTF-8）。
    let first_non_space = bytes
        .strip_prefix(&[0xEF, 0xBB, 0xBF]) // UTF-8 BOM
        .unwrap_or(&bytes)
        .iter()
        .find(|b| !b.is_ascii_whitespace());
    if !matches!(first_non_space, Some(b'{')) {
        return Err(LegadoError::Internal(
            "不支持的备份格式：文件既不是原版 zip 备份，也不是本应用的 JSON 备份".to_string(),
        ));
    }

    let content = String::from_utf8(bytes)
        .map_err(|e| LegadoError::Io(std::io::Error::other(format!("读取备份文件失败: {e}"))))?;
    let trimmed = content.trim_start_matches('\u{feff}').trim_start();

    let value: serde_json::Value = serde_json::from_str(trimmed)
        .map_err(|e| LegadoError::Internal(format!("备份文件解析失败: {e}")))?;

    // [批9 回修 P2-6] 「先清空再插入」只在该键存在时生效：v1 旧备份没有
    // highlightRules/keyboardAssists 键，恢复时不得清空库内既有规则
    let replace_policy = ReplaceTablePolicy {
        highlight_rules: value.get("highlightRules").is_some(),
        keyboard_assists: value.get("keyboardAssists").is_some(),
    };

    let backup: BackupData = serde_json::from_value(value)
        .map_err(|e| LegadoError::Internal(format!("备份文件解析失败: {e}")))?;

    restore_backup_data(&backup, replace_policy)
}

/// 恢复「先清空再插入」策略（对齐原版 Restore.kt 的全量替换语义）
///
/// 原版只在该 JSON 文件**存在且解析成功**时执行 `replaceAll` /
/// `deleteAll + insert`（`Restore.kt:310-313`、`359-361`）；文件缺失或损坏时
/// 不动库内旧行。因此不能以「备份列表是否为空」判断——空列表的语义是清空，
/// 键缺失的语义是不触碰，两者必须区分，故由输入适配层显式携带策略。
/// 自有 JSON 按原始 JSON 键是否存在判定，zip 按文件是否存在且解析成功判定。
#[derive(Debug, Clone, Copy, Default)]
struct ReplaceTablePolicy {
    /// 备份显式包含有效的高亮规则集合：恢复时先清空 highlightRules
    highlight_rules: bool,
    /// 备份显式包含有效的键盘辅助集合：恢复时先清空 keyboardAssists
    keyboard_assists: bool,
}

/// 解析结果落库（JSON 与 zip 两条入口共用，单实现原则）
///
/// 事务边界与错误语义见 [`backup_restore`] 文档：条目级错误 warn 跳过并照常
/// 提交，未捕获 `Err` 整体回滚。
fn restore_backup_data(
    backup: &BackupData,
    replace_policy: ReplaceTablePolicy,
) -> LegadoResult<String> {
    let stats = with_database(|db| {
        let conn = db.connection();
        legado_db::connection::in_transaction(conn, "备份恢复", |conn| {
            restore_backup_in_tx(conn, backup, replace_policy)
        })
    })?;

    let result = serde_json::to_string(&stats)
        .map_err(|e| LegadoError::Internal(format!("统计序列化失败: {e}")))?;
    Ok(result)
}

// ─── 原版 zip 备份恢复（批9）──────────────────────────────────────────

/// zip 本地文件头魔数（`PK\x03\x04`）
const ZIP_ENTRY_MAGIC: [u8; 4] = *b"PK\x03\x04";
/// 空 zip（仅中央目录结束记录 `PK\x05\x06`）——同样按 zip 分流
const ZIP_EMPTY_MAGIC: [u8; 4] = *b"PK\x05\x06";
/// 单个数据条目解压上限（256 MiB）：原版无上限，本实现为解压炸弹加固
///
/// [批9 回修 P1] 该上限必须约束**实际解压字节数**：zip 头里的
/// `uncompressed_size` 可由构造者任意伪造（zip 2.4 解压按 `compressed_size`
/// 限流、不校验声明值），仅凭 `entry.size()` 判定会被「声明小/实际大」绕过。
const MAX_BACKUP_ENTRY_BYTES: u64 = 256 * 1024 * 1024;
/// 单个备份文件（解压前）大小上限（512 MiB）：JSON 与 zip 入口共用
const MAX_BACKUP_ARCHIVE_BYTES: u64 = 512 * 1024 * 1024;
/// 单次恢复跨条目累计解压上限（512 MiB）：多个「刚好合规」条目叠加也不能
/// 无限占用内存/CPU，超预算直接中止整次恢复并给出明确错误
const MAX_BACKUP_TOTAL_BYTES: u64 = 512 * 1024 * 1024;

/// 原版 `Backup.kt` 写出的、本实现会读取的数据文件（其余条目不解压）
const ZIP_DATA_FILES: [&str; 20] = [
    "bookshelf.json",
    "bookmark.json",
    "highlight.json",
    "highlightRule.json",
    "bookGroup.json",
    "bookSource.json",
    "rssSources.json",
    "rssStar.json",
    "replaceRule.json",
    "readRecord.json",
    "searchHistory.json",
    "sourceSub.json",
    "txtTocRule.json",
    "httpTTS.json",
    "keyboardAssists.json",
    "dictRule.json",
    "autoTask.json",
    "servers.json",
    "cookies.json",
    "runtimeSourceCache.json",
];

/// 原版 zip 内存在、但本实现无对应落库面的文件（只报告不落库，登记见模块注释）
const ZIP_UNMAPPED_FILES: [&str; 7] = [
    "readConfig.json",
    "shareReadConfig.json",
    "themeConfig.json",
    "coverRule.json",
    "directLinkUploadRule.json",
    "config.xml",
    "videoConfig.xml",
];

/// 原版 zip 备份读取结果
///
/// 只解压 [`ZIP_DATA_FILES`] 命中条目的内容；`entry_names` 保留全部文件条目名，
/// 用于报告媒体目录与未映射文件（**不解压、不落盘**，因此不存在路径逃逸面）。
struct ZipBackupArchive {
    /// 数据文件内容（键为 zip 内相对路径，如 `bookshelf.json`）
    files: HashMap<String, Vec<u8>>,
    /// 全部文件条目名
    entry_names: Vec<String>,
}

/// 是否原版 zip 备份（按魔数判定，见模块注释）
fn is_zip_backup(bytes: &[u8]) -> bool {
    bytes.starts_with(&ZIP_ENTRY_MAGIC) || bytes.starts_with(&ZIP_EMPTY_MAGIC)
}

/// 读取 zip 备份：校验条目路径、只解压已知数据文件
///
/// [批9 回修 P1] 解压按**实际字节数**限量（[`read_zip_entry_limited`]）：
/// zip 头的 `uncompressed_size` 不可信，声明值只用于提前日志；跨条目累计
/// 解压量超过 [`MAX_BACKUP_TOTAL_BYTES`] 时中止整次恢复（明确报错）。
fn read_zip_backup(bytes: &[u8]) -> LegadoResult<ZipBackupArchive> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes))
        .map_err(|e| LegadoError::Internal(format!("备份 zip 解析失败: {e}")))?;
    let mut files: HashMap<String, Vec<u8>> = HashMap::new();
    let mut entry_names: Vec<String> = Vec::new();
    let mut total_decoded: u64 = 0;

    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|e| LegadoError::Internal(format!("读取备份 zip 条目失败: {e}")))?;
        if entry.is_dir() {
            continue;
        }
        // 部分第三方打包工具会给条目加 `./` 前缀；去掉后再做安全校验
        //（`./` 不属于 `..` 逃逸，且去前缀后仍须通过 [`is_safe_zip_entry_name`]）
        let name = entry.name().trim_start_matches("./").to_string();
        if !is_safe_zip_entry_name(&name) {
            log::warn!("跳过路径不安全的备份 zip 条目: {name}");
            continue;
        }
        entry_names.push(name.clone());
        if !ZIP_DATA_FILES.contains(&name.as_str()) {
            continue;
        }
        let declared_size = entry.size();
        match read_zip_entry_limited(
            &name,
            declared_size,
            &mut entry,
            MAX_BACKUP_ENTRY_BYTES,
            &mut total_decoded,
            MAX_BACKUP_TOTAL_BYTES,
        )? {
            Some(buf) => {
                files.insert(name, buf);
            }
            None => continue,
        }
    }

    Ok(ZipBackupArchive { files, entry_names })
}

/// 限量读取单个 zip 条目（解压炸弹防护的唯一读取入口）
///
/// - `declared_size` 仅用于提前日志（zip 头可伪造），**不作为判定依据**；
/// - 实际读取经 `take(limit + 1)` 截断：读满 `limit + 1` 字节即说明超限，
///   返回 `Ok(None)` 表示跳过该条目（不落库、不继续占用内存）；
/// - 已读取字节累计进 `total_decoded`，超过 `total_limit` 返回明确错误中止
///   整次恢复（多条目叠加同样受限）。
///
/// 截断读取不会读到 deflate 流末尾，因此不会触发 zip crate 的 CRC 校验——
/// 这正是「伪造声明值」的绕行路径：CRC 正确与否不影响本函数的判定。
fn read_zip_entry_limited<R: Read>(
    name: &str,
    declared_size: u64,
    reader: R,
    limit: u64,
    total_decoded: &mut u64,
    total_limit: u64,
) -> LegadoResult<Option<Vec<u8>>> {
    if declared_size > limit {
        log::warn!(
            "备份条目声明大小超过上限（仍按实际解压量校验）: {name} 声明 {declared_size} 字节（上限 {limit}）"
        );
    }
    // 预分配只参考声明值且封顶 1 MiB，避免伪造的巨大声明值直接触发巨额分配
    let mut buf = Vec::with_capacity(declared_size.min(1024 * 1024) as usize);
    let mut limited = reader.take(limit.saturating_add(1));
    limited
        .read_to_end(&mut buf)
        .map_err(|e| LegadoError::Internal(format!("读取备份 zip 条目 {name} 失败: {e}")))?;

    *total_decoded = total_decoded.saturating_add(buf.len() as u64);
    if *total_decoded > total_limit {
        return Err(LegadoError::Internal(format!(
            "备份解压总量超过上限（已解压超过 {total_limit} 字节），已中止恢复；\
             备份包可能异常或为解压炸弹"
        )));
    }
    if buf.len() as u64 > limit {
        log::warn!(
            "备份条目实际解压大小超过上限（已跳过）: {name} 实际超过 {limit} 字节（声明 {declared_size} 字节）"
        );
        return Ok(None);
    }
    Ok(Some(buf))
}

/// zip 条目路径安全校验（不接受绝对路径、盘符、反斜杠与 `.`/`..` 段）
///
/// 本实现不从 zip 解包到磁盘，此处为纵深防御：路径不合法的条目连内容都不读。
fn is_safe_zip_entry_name(name: &str) -> bool {
    if name.is_empty() || name.contains('\\') || name.contains('\0') {
        return false;
    }
    if name.starts_with('/') {
        return false;
    }
    if name.get(1..3).is_some_and(|s| s.starts_with(":/")) {
        return false;
    }
    !name
        .split('/')
        .any(|segment| segment == "." || segment == "..")
}

/// zip 恢复入口：读包 → 加密前置校验 → 报告未映射项 → 转 [`BackupData`] → 同一恢复体落库
fn restore_from_zip(bytes: &[u8]) -> LegadoResult<String> {
    let archive = read_zip_backup(bytes)?;
    ensure_zip_encryption_supported(&archive)?;
    // 返回值仅供回归测试断言告警，恢复流程无需消费
    let _ = report_unmapped_zip_entries(&archive);
    let (backup, replace_policy) = backup_data_from_zip(&archive);
    restore_backup_data(&backup, replace_policy)
}

/// 加密内容前置校验（对齐原版「无备份密码即拒绝恢复登录信息」语义）
///
/// `cookies.json` / `runtimeSourceCache.json` 只在原版设置备份密码时写出
/// （`Backup.kt` 在密码为空且启用这两类内容时直接抛错），因此：
/// - 文件存在且内容不是明文 JSON 数组 → 备份设过密码，我方无密码输入面，
///   返回明确错误（不静默跳过）；此时**不启动事务**，库内零残留；
/// - 明文 JSON 数组 → 历史/第三方产出的明文包，登记后跳过该类（不静默）。
fn ensure_zip_encryption_supported(archive: &ZipBackupArchive) -> LegadoResult<()> {
    for (name, label) in [
        ("cookies.json", "登录信息"),
        ("runtimeSourceCache.json", "书源运行变量"),
    ] {
        let Some(bytes) = archive.files.get(name) else {
            continue;
        };
        let Some(text) = decode_zip_text(name, bytes) else {
            continue;
        };
        if text.starts_with('[') {
            log::warn!("备份包含 {name}（{label}），当前版本不恢复该表（已跳过）");
            continue;
        }
        return Err(LegadoError::Internal(format!(
            "该备份包含原版加密的{label}文件 {name}，说明备份时设置过备份密码；\
             当前版本不支持输入备份密码，无法恢复。请在原版 App 的备份设置中清除备份密码后重新备份。"
        )));
    }
    Ok(())
}

/// 报告未映射内容（媒体目录与配置快照）：只记日志，不落盘
///
/// 返回是否发出了「未找到原版数据文件」告警（仅供回归测试断言，调用方无需消费）。
/// [批9 回修 P2-13] 判定只看「是否有可读数据文件」：全部条目被路径校验拒绝
/// 时 `entry_names` 同样为空，原条件（`files.is_empty() && !entry_names.is_empty()`）
/// 会漏报，用户会误以为「恢复成功但数据为空」。
fn report_unmapped_zip_entries(archive: &ZipBackupArchive) -> bool {
    let mut no_data_warned = false;
    if archive.files.is_empty() {
        no_data_warned = true;
        log::warn!(
            "备份 zip 内未找到原版数据文件（条目缺失、被拒绝或嵌套在子目录），本次恢复不写入任何表"
        );
    }
    let mut reported_media: Vec<&str> = Vec::new();
    for name in &archive.entry_names {
        if let Some(prefix) = ["covers/", "bg/"]
            .iter()
            .find(|prefix| name.starts_with(**prefix))
        {
            let dir = prefix.trim_end_matches('/');
            if !reported_media.contains(&dir) {
                reported_media.push(dir);
                log::warn!("备份包含媒体目录 {dir}/，当前版本不恢复图片文件（已跳过）");
            }
            continue;
        }
        if ZIP_UNMAPPED_FILES.contains(&name.as_str()) {
            log::warn!("备份包含 {name}，当前版本无对应配置面（已跳过）");
        }
    }
    no_data_warned
}

/// 原版 zip 文件 → [`BackupData`]（只做输入适配，游标语义对齐原版 `Restore.kt` 顺序）
///
/// 同时返回 [`ReplaceTablePolicy`]：高亮规则/键盘辅助两表在原版恢复里是
/// 「文件存在且解析成功 → 全量替换」，zip 适配层必须把该事实显式带出。
fn backup_data_from_zip(archive: &ZipBackupArchive) -> (BackupData, ReplaceTablePolicy) {
    let mut data = BackupData::empty();
    data.books = zip_json_array(archive, "bookshelf.json")
        .unwrap_or_default()
        .into_iter()
        .map(normalize_zip_book)
        .collect();
    data.book_groups = zip_json_array(archive, "bookGroup.json")
        .unwrap_or_default()
        .into_iter()
        .map(normalize_zip_book_group)
        .collect();
    data.bookmarks = zip_json_array(archive, "bookmark.json").unwrap_or_default();
    data.highlights = zip_json_array(archive, "highlight.json").unwrap_or_default();
    let mut replace_policy = ReplaceTablePolicy::default();
    if let Some(rules) = zip_json_array(archive, "highlightRule.json") {
        replace_policy.highlight_rules = true;
        data.highlight_rules = rules.into_iter().map(normalize_zip_sort_order).collect();
    }
    data.book_sources = zip_json_array(archive, "bookSource.json").unwrap_or_default();
    data.rss_sources = zip_json_array(archive, "rssSources.json").unwrap_or_default();
    data.rss_stars = zip_json_array(archive, "rssStar.json").unwrap_or_default();
    data.replace_rules = zip_json_array(archive, "replaceRule.json")
        .unwrap_or_default()
        .into_iter()
        .map(normalize_zip_sort_order)
        .collect();
    // [批9 回修 P2-5] readRecord 的 deviceId 归一为空串（单设备模型）
    data.read_records = zip_json_array(archive, "readRecord.json")
        .unwrap_or_default()
        .into_iter()
        .map(normalize_zip_read_record)
        .collect();
    data.search_history = zip_json_array(archive, "searchHistory.json").unwrap_or_default();
    data.rule_subs = zip_json_array(archive, "sourceSub.json")
        .unwrap_or_default()
        .into_iter()
        .map(normalize_zip_rule_sub)
        .collect();
    data.txt_toc_rules = zip_json_array(archive, "txtTocRule.json").unwrap_or_default();
    data.http_tts = zip_json_array(archive, "httpTTS.json")
        .unwrap_or_default()
        .into_iter()
        .map(normalize_zip_http_tts)
        .collect();
    data.dict_rules = zip_json_array(archive, "dictRule.json").unwrap_or_default();
    if let Some(assists) = zip_json_array(archive, "keyboardAssists.json") {
        replace_policy.keyboard_assists = true;
        data.keyboard_assists = assists;
    }
    data.auto_tasks = zip_json_array(archive, "autoTask.json").unwrap_or_default();
    data.servers = zip_servers(archive);
    (data, replace_policy)
}

/// 读取并解析一个数据文件为 JSON 数组
///
/// 口径对齐原版 `Restore.fileToListT`：文件不存在 → debug 跳过（`None`）；
/// 解析失败 → warn 跳过**该类**（`None`，不影响其余类别与事务提交）。
/// 返回 `Option` 是为了让调用方区分「键缺失/损坏」与「合法空数组」——
/// 前者不得触发全量替换表的清空（见 [`ReplaceTablePolicy`]）。
fn zip_json_array(archive: &ZipBackupArchive, name: &str) -> Option<Vec<serde_json::Value>> {
    let Some(bytes) = archive.files.get(name) else {
        log::debug!("原版备份不含 {name}，按原版语义跳过该类");
        return None;
    };
    let text = decode_zip_text(name, bytes)?;
    match serde_json::from_str::<Vec<serde_json::Value>>(text) {
        Ok(list) => Some(list),
        Err(e) => {
            log::warn!("{name} 解析失败（已跳过该类）: {e}");
            None
        }
    }
}

/// 解出 zip 条目文本（UTF-8，容忍 BOM）；非 UTF-8 时 warn 并返回 `None`
fn decode_zip_text<'a>(name: &str, bytes: &'a [u8]) -> Option<&'a str> {
    match std::str::from_utf8(bytes) {
        Ok(text) => Some(text.trim_start_matches('\u{feff}').trim()),
        Err(e) => {
            log::warn!("{name} 不是 UTF-8 文本（已跳过该类）: {e}");
            None
        }
    }
}

/// 书内封面路径归一：原版绝对 `<...>/covers/<file>` 路径在未恢复媒体时置空
///
/// 对齐原版 `Restore.remapRestoredCoverPath`：目标封面文件不存在时返回 null。
/// 我方媒体目录不落盘（模块注释），故这类路径必然悬空，置空后书架回落到
/// 书源 `coverUrl`。
fn normalize_zip_book(mut value: serde_json::Value) -> serde_json::Value {
    if let serde_json::Value::Object(map) = &mut value {
        let stale_cover = matches!(
            map.get("customCoverUrl"),
            Some(serde_json::Value::String(path)) if is_absolute_cover_path(path)
        );
        if stale_cover {
            map.insert("customCoverUrl".to_string(), serde_json::Value::Null);
        }
    }
    value
}

/// 分组封面路径归一（同 [`normalize_zip_book`]，键为 `cover`）
fn normalize_zip_book_group(mut value: serde_json::Value) -> serde_json::Value {
    if let serde_json::Value::Object(map) = &mut value {
        let stale_cover = matches!(
            map.get("cover"),
            Some(serde_json::Value::String(path)) if is_absolute_cover_path(path)
        );
        if stale_cover {
            map.insert("cover".to_string(), serde_json::Value::Null);
        }
    }
    value
}

/// 阅读记录归一：原版 zip 的 `deviceId`（原设备 androidId）归一为空串
///
/// 原版 `Restore.kt:363-376` 用 `readRecord.deviceId != androidId` 判定「他机记录」
/// 并直接插入——其前提是备份来自另一台设备；本机恢复时 deviceId 恒等于本机
/// androidId，走「同键较新者胜」。我方为单设备模型（Rust 侧 deviceId 固定空串），
/// 若不归一：原设备 ID 会被当作他机记录直接插入，与本机既有同书名记录并存两行，
/// Flutter 阅读记录页按 bookName 合并时把 readTime 相加，阅读时长翻倍。
/// 归一一律置空串后，恢复走 [`ReadRecordRepository::upsert_restore`] 的
/// 「本机较新者胜 + 作者合并」路径，对齐原版「同设备比较」意图。
fn normalize_zip_read_record(mut value: serde_json::Value) -> serde_json::Value {
    if let serde_json::Value::Object(map) = &mut value {
        // 兼容理论上的 snake_case 旧键，避免归一后同义键并存
        map.remove("device_id");
        map.insert(
            "deviceId".to_string(),
            serde_json::Value::String(String::new()),
        );
    }
    value
}

/// 是否为原版绝对封面路径（`/.../covers/<file>` 或 `C:/.../covers/<file>`）
fn is_absolute_cover_path(path: &str) -> bool {
    let normalized = path.replace('\\', "/");
    let absolute =
        normalized.starts_with('/') || normalized.get(1..3).is_some_and(|s| s.starts_with(":/"));
    if !absolute {
        return false;
    }
    normalized
        .rsplit_once('/')
        .map(|(parent, _)| parent.rsplit('/').next() == Some("covers"))
        .unwrap_or(false)
}

/// 规则订阅条目归一：原版 `RuleSub` 键 → 我方 [`RuleSubRecord`] 键
///
/// 原版实体（`RuleSub.kt`）：`id`/`name`/`url`/`type`（Int：0 书源、1 订阅源、
/// 3 替换规则）/`customOrder`/`autoUpdate`/`update`（毫秒）/`updateInterval`/
/// `silentUpdate`/`js`/`showRule`/`sourceUrl`；**无** `version`/`isEnabled`/
/// `createdAt` 列，故按 Room 默认值补齐（version 空串、启用、createdAt 取 update）。
fn normalize_zip_rule_sub(mut value: serde_json::Value) -> serde_json::Value {
    if let serde_json::Value::Object(map) = &mut value {
        let sub_type = match map.get("type") {
            Some(serde_json::Value::Number(n)) => {
                Some(zip_rule_sub_type(n.as_i64().unwrap_or(0)).to_string())
            }
            Some(serde_json::Value::String(s)) => Some(s.clone()),
            _ => None,
        };
        if let Some(sub_type) = sub_type {
            map.insert("sub_type".to_string(), serde_json::Value::String(sub_type));
        }
        if !map.contains_key("last_update") {
            let update_ms = map
                .get("update")
                .and_then(serde_json::Value::as_i64)
                .unwrap_or(0);
            map.insert(
                "last_update".to_string(),
                serde_json::Value::from(update_ms),
            );
            map.insert("created_at".to_string(), serde_json::Value::from(update_ms));
        }
        map.entry("version".to_string())
            .or_insert_with(|| serde_json::Value::String(String::new()));
        map.entry("is_enabled".to_string())
            .or_insert(serde_json::Value::Bool(true));
        map.entry("created_at".to_string())
            .or_insert(serde_json::Value::from(0));
    }
    value
}

/// Room `ruleSubs.type` 整数 → 我方 `sub_type` 字符串（与 legado-db 映射一致）
fn zip_rule_sub_type(value: i64) -> &'static str {
    match value {
        1 => "rssSource",
        3 => "replaceRule",
        _ => "bookSource",
    }
}

/// 排序键归一：原版实体属性名为 `order`（Room 列名才是 `sortOrder`），我方模型用 `sortOrder`
///
/// 直接影响 `replaceRule.json` / `highlightRule.json`：不改键则排序列全部落到默认值，
/// 恢复后规则顺序与原版不一致（`ReplaceRule.kt:63-65`、`HighlightRule.kt:39-40`）。
fn normalize_zip_sort_order(mut value: serde_json::Value) -> serde_json::Value {
    if let serde_json::Value::Object(map) = &mut value {
        // 移除原版 `order` 键后再落 `sortOrder`：模型已为 `sortOrder` 加 alias="order"
        // （Web 写端点兼容），两键并存会触发 serde duplicate field 错误。
        if let Some(order) = map.remove("order") {
            map.entry("sortOrder").or_insert(order);
        }
    }
    value
}

/// 在线朗读引擎条目归一：原版 `HttpTTS` 无启用列（引擎始终可用）
///
/// 我方 `httpTTS` 表为超集（`isEnabled`），缺键时 serde 默认 false 会把
/// 引擎全部恢复成停用；这里按原版「无该列即可用」补 `isEnabled = true`。
fn normalize_zip_http_tts(mut value: serde_json::Value) -> serde_json::Value {
    if let serde_json::Value::Object(map) = &mut value {
        map.entry("isEnabled".to_string())
            .or_insert(serde_json::Value::Bool(true));
    }
    value
}

/// 解析 `servers.json`：明文数组优先，否则按原版空密码密钥解密
///
/// 原版 `Backup.kt:304-311` 总是先尝试 `aes.encryptBase64`（失败才落明文），
/// 恢复侧 `Restore.kt:379-390` 用 `isJsonArray()` 判别明文。无法用空密码
/// 解密 ⇒ 备份设过密码 ⇒ warn 跳过（对齐原版 `runCatching` 记日志后继续，
/// 不中断其余表的恢复）。
fn zip_servers(archive: &ZipBackupArchive) -> Vec<serde_json::Value> {
    let Some(bytes) = archive.files.get("servers.json") else {
        return Vec::new();
    };
    let Some(text) = decode_zip_text("servers.json", bytes) else {
        return Vec::new();
    };
    if text.starts_with('[') {
        return match serde_json::from_str::<Vec<serde_json::Value>>(text) {
            Ok(list) => list,
            Err(e) => {
                log::warn!("servers.json 解析失败（已跳过）: {e}");
                Vec::new()
            }
        };
    }
    match decrypt_backup_payload(text) {
        Ok(plain) => match serde_json::from_str::<Vec<serde_json::Value>>(plain.trim()) {
            Ok(list) => list,
            Err(e) => {
                log::warn!("servers.json 解密后解析失败（已跳过）: {e}");
                Vec::new()
            }
        },
        Err(e) => {
            log::warn!(
                "servers.json 无法用空密码解密（原版备份设置过备份密码）；\
                 当前版本不支持输入备份密码，服务器配置未恢复（已跳过）: {e}"
            );
            Vec::new()
        }
    }
}

/// 原版 `BackupAES` 密钥派生：`MD5(password)` 小写十六进制串的前 16 个 ASCII 字节
///
/// 注意**不是** hex 解码：Kotlin 侧为 `MD5Utils.md5Encode(password).encodeToByteArray(0, 16)`，
/// 取的是十六进制字符串前 16 个字符的 UTF-8 字节。
fn backup_aes_key(password: &str) -> [u8; 16] {
    let digest = format!("{:x}", md5::compute(password.as_bytes()));
    let mut key = [0u8; 16];
    key.copy_from_slice(&digest.as_bytes()[..16]);
    key
}

/// 解密原版备份密文（Base64 + AES-128-ECB/PKCS5Padding）
///
/// 我方无备份密码输入面，固定按空密码派生密钥：未设密码的原版备份可正常
/// 解密；设过密码的备份解密失败，由调用方给出明确文案（不静默）。
fn decrypt_backup_payload(text: &str) -> LegadoResult<String> {
    let key = backup_aes_key("");
    let ciphertext = base64::engine::general_purpose::STANDARD
        .decode(text.trim())
        .map_err(|e| LegadoError::Internal(format!("备份密文 base64 解码失败: {e}")))?;
    let plain = AesCrypto::decrypt_ecb(&key, &ciphertext)?;
    String::from_utf8(plain)
        .map_err(|e| LegadoError::Internal(format!("备份密文解密结果不是 UTF-8: {e}")))
}

/// 恢复体：各表逐条恢复（单事务闭包内容，条目级错误 warn 跳过继续）
///
/// 从 [`backup_restore`] 拆出以匹配 `in_transaction` 闭包签名，并供测试
/// 直接构造「恢复中未捕获错误 → 整体回滚」场景（外部备份数据无法构造
/// 逃逸条目捕获网的 Err——全部条目级错误均在下方 match 分支内被 warn
/// 吞掉，回滚路径只能以闭包内直接上抛 `Err` 的方式验证）。
fn restore_backup_in_tx(
    conn: &Connection,
    backup: &BackupData,
    replace_policy: ReplaceTablePolicy,
) -> LegadoResult<RestoreStats> {
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
    //
    // [批7c P2-6] 进度覆盖失败同样不计入成功数：书行虽已插入/更新，但
    // 备份中的阅读进度未落库，该条目不算完整恢复；成功计数只统计
    // 「书行 + 4 个进度列」全部写成的条目。
    let book_repo = BookRepository::new(conn);
    for value in &backup.books {
        if let Ok(book) = serde_json::from_value::<Book>(value.clone()) {
            match book_repo.insert(&book) {
                Ok(()) => {
                    // [批7b] 对齐原版 Restore.kt:286-288 的 `bookDao.update(book)`
                    // 全列覆盖语义：insert 对已存在行走 update，而 update 按 [B-3]
                    // 结构性排除 4 个进度列（防陈旧快照回滚），故恢复路径在此
                    // 显式补写备份中的进度。新书插入时 insert_replace 已全列写入，
                    // 本次覆盖为幂等操作。
                    //
                    // 旧备份条目缺进度字段时 serde 默认 0/None——与原版 Gson
                    // 反序列化缺省值一致（Book 实体 durChapterIndex/Pos=0、
                    // durChapterTitle=null），随后原版 @Update 同样全列覆盖，
                    // 因此按原版语义清为默认值，不做「缺字段跳过」特判。
                    match book_repo.overwrite_progress_for_restore(
                        &book.book_url,
                        book.dur_chapter_index,
                        book.dur_chapter_pos,
                        book.dur_chapter_title.as_deref(),
                        book.dur_chapter_time,
                    ) {
                        Ok(()) => stats.books += 1,
                        Err(e) => log::warn!(
                            "恢复书籍进度失败（本条目不计入成功统计）: {} - {e}",
                            book.book_url
                        ),
                    }
                }
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

    // 高亮规则（P2-6 对齐原版 `Restore.kt:310-313` 的 `highlightRuleDao.replaceAll`：
    // 「以备份集合为准」——文件/键存在且解析成功时先清空再插入，否则备份外的
    // 库内旧行会残留。缺失/损坏时不触碰库内旧行（对齐原版 fileToListT 返回 null）。
    // P2-11 补列后 uuid/applyToBody 随模型 serde 全字段往返，旧备份缺字段时
    // serde 默认值兜底，不破坏可恢复性）
    let highlight_rule_repo = HighlightRuleRepository::new(conn);
    if replace_policy.highlight_rules {
        if let Err(e) = highlight_rule_repo.delete_all() {
            log::warn!("恢复高亮规则前清空失败（继续逐条写入，可能残留旧行）: {e}");
        }
    }
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

    // 键盘辅助规则（P2-6 对齐原版 `Restore.kt:359-361`
    // `keyboardAssistsDao.deleteAll()` + insert：以备份集合为准）。
    // 仓库无 delete_all，恢复语义明确要求先清空，故直接执行同表 DELETE。
    let assist_repo = KeyboardAssistRepository::new(conn);
    if replace_policy.keyboard_assists {
        if let Err(e) = conn.execute("DELETE FROM keyboardAssists", []) {
            log::warn!("恢复键盘辅助规则前清空失败（继续逐条写入，可能残留旧行）: {e}");
        }
    }
    for value in &backup.keyboard_assists {
        match serde_json::from_value::<KeyboardAssist>(value.clone()) {
            Ok(assist) => match assist_repo.insert_record(&assist) {
                Ok(()) => {}
                Err(e) => log::warn!("恢复键盘辅助规则失败（已跳过）: {e}"),
            },
            Err(e) => log::warn!("恢复键盘辅助规则解析失败（已跳过）: {e}"),
        }
    }

    // 服务器配置（v3：按 id REPLACE，对齐原版 Restore.kt:379-390 的
    // `serverDao.insert(*it.toTypedArray())`；列表为空 = 备份无该键或空表，
    // 直接跳过，**不清库内 servers**）。恢复走
    // `restore_upsert_preserving_id` 保留原主键（含 id = 0），不做毫秒重分配——
    // 否则同一备份重复恢复会不断产生新行（防复发规定 5：往返逐字段一致）
    let server_repo = ServerRepository::new(conn);
    for value in &backup.servers {
        match serde_json::from_value::<legado_core::models::Server>(value.clone()) {
            Ok(server) => match server_repo.restore_upsert_preserving_id(&server) {
                Ok(_) => {}
                Err(e) => log::warn!("恢复服务器配置失败（已跳过）: {} - {e}", server.name),
            },
            Err(e) => log::warn!("恢复服务器配置解析失败（已跳过）: {e}"),
        }
    }

    // 自动任务（批9：原版 autoTask.json；自有 JSON 备份暂无该段，空列表直接跳过）。
    // 主键为字符串 id（原版 UUID）：缺失/空的条目无法定位行，warn 跳过而非写入
    // 空主键行（空主键行会与后续同 id 条目互相覆盖）。
    let auto_task_repo = AutoTaskRepository::new(conn);
    for value in &backup.auto_tasks {
        match serde_json::from_value::<legado_core::models::AutoTaskRule>(value.clone()) {
            Ok(rule) => {
                if rule.id.trim().is_empty() {
                    log::warn!("恢复自动任务失败（已跳过）: 缺少 id 主键");
                    continue;
                }
                match auto_task_repo.insert(&rule) {
                    Ok(_) => {}
                    Err(e) => log::warn!("恢复自动任务失败（已跳过）: {} - {e}", rule.name),
                }
            }
            Err(e) => log::warn!("恢复自动任务解析失败（已跳过）: {e}"),
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
        BackupData::empty()
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
                "servers",
                "auto_task_rules",
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

    /// [批7b 回归] 恢复覆盖已有书进度（对齐原版 Restore.kt:286-288 全列语义）
    ///
    /// 场景：备份时书内进度 0/0，之后本地读到 3/15；恢复备份后库内进度
    /// 必须回到备份值（旧实现经 insert→update，而 update 按 [B-3]
    /// 结构性排除进度列，导致只有新书生效）。
    #[test]
    fn test_restore_overwrites_existing_book_progress() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_restore_progress");
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("progress_override.json");
        let path_str = backup_path.to_str().unwrap();

        let book_url = "https://progress.example/book/1";
        // 种书：备份时进度为默认 0/0/None/0
        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: book_url.to_string(),
                name: "进度书".to_string(),
                author: "作者甲".to_string(),
                ..Book::default()
            })
        })
        .unwrap();
        backup_create(path_str).unwrap();

        // 备份后本地继续阅读：库内进度推进到 3/15
        with_database(|db| {
            BookRepository::new(db.connection()).update_progress(
                book_url,
                3,
                15,
                Some("第三章"),
                1_700_000_000_000,
            )
        })
        .unwrap();

        let stats_json = backup_restore(path_str).unwrap();
        let stats: RestoreStats = serde_json::from_str(&stats_json).unwrap();
        assert_eq!(stats.books, 1, "已有书应计入恢复统计");

        let restored =
            with_database(|db| BookRepository::new(db.connection()).find_by_url(book_url))
                .unwrap()
                .expect("恢复后书籍应存在");
        assert_eq!(
            restored.dur_chapter_index, 0,
            "恢复应显式覆盖已有书章节索引（对齐原版全列更新）"
        );
        assert_eq!(restored.dur_chapter_pos, 0, "恢复应覆盖章节内位置");
        assert_eq!(restored.dur_chapter_title, None, "恢复应覆盖章节标题");
        assert_eq!(restored.dur_chapter_time, 0, "恢复应覆盖阅读时间");

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批7c 补向] 备份中的非零进度覆盖本地进度（与上一用例相反方向）
    ///
    /// 上一用例只验证「备份 0/0 → 本地 3/15」，无法排除恢复链把进度恒清 0
    /// 的假通过。本用例备份 5/25/第五章/时间戳、本地先读到 3/15，恢复后
    /// 必须取备份值（对齐原版 Restore.kt 全列覆盖）。
    #[test]
    fn test_restore_overwrites_local_progress_with_backup_values() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_restore_nonzero_progress");
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("nonzero_progress.json");
        let path_str = backup_path.to_str().unwrap();

        let book_url = "https://progress.example/book/2";
        let backup_time = 1_711_111_111_111_i64;
        // 本地先有进度 3/15
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "非零进度书".to_string(),
                author: "作者丙".to_string(),
                ..Book::default()
            })?;
            repo.update_progress(book_url, 3, 15, Some("第三章"), 1_700_000_000_000)
        })
        .unwrap();

        // 备份内进度 5/25/第五章/时间戳
        let mut backup = empty_backup();
        backup.books = vec![serde_json::to_value(Book {
            book_url: book_url.to_string(),
            name: "非零进度书".to_string(),
            author: "作者丙".to_string(),
            dur_chapter_index: 5,
            dur_chapter_pos: 25,
            dur_chapter_title: Some("第五章".to_string()),
            dur_chapter_time: backup_time,
            ..Book::default()
        })
        .unwrap()];
        fs::write(path_str, serde_json::to_string(&backup).unwrap()).unwrap();

        let stats_json = backup_restore(path_str).unwrap();
        let stats: RestoreStats = serde_json::from_str(&stats_json).unwrap();
        assert_eq!(stats.books, 1, "已有书应计入恢复统计");

        let restored =
            with_database(|db| BookRepository::new(db.connection()).find_by_url(book_url))
                .unwrap()
                .expect("恢复后书籍应存在");
        assert_eq!(
            restored.dur_chapter_index, 5,
            "恢复应写入备份中的章节索引（非零方向）"
        );
        assert_eq!(restored.dur_chapter_pos, 25, "恢复应写入备份中的章节内位置");
        assert_eq!(
            restored.dur_chapter_title.as_deref(),
            Some("第五章"),
            "恢复应写入备份中的章节标题"
        );
        assert_eq!(
            restored.dur_chapter_time, backup_time,
            "恢复应写入备份中的阅读时间戳"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批7b 语义锚点] 旧备份条目缺进度字段 → 按原版全列语义覆盖为默认值
    ///
    /// 原版判定（Book.kt:94-109 + Restore.kt:286-288）：Gson 反序列化缺字段
    /// 取实体默认值（durChapterIndex/Pos=0、durChapterTitle=null），随后
    /// `bookDao.update(book)`（Room @Update）全列覆盖——即原版会清掉库内
    /// 进度。重构版 serde 缺省同为 0/None，恢复链显式覆盖后行为一致；
    /// 不做「缺字段跳过」特判（用户 2026-10-26 裁决：对齐原版）。
    #[test]
    fn test_restore_legacy_book_without_progress_fields_clears_like_original() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_legacy_progress");
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("legacy_no_progress.json");
        let path_str = backup_path.to_str().unwrap();

        let book_url = "https://legacy.example/book/1";
        // 库内已有书且带进度 3/15
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "旧备份书".to_string(),
                author: "作者乙".to_string(),
                ..Book::default()
            })?;
            repo.update_progress(book_url, 3, 15, Some("第三章"), 1_700_000_000_000)
        })
        .unwrap();

        // 旧备份：books 条目完全不含进度字段（模拟旧版本备份格式）
        let mut backup = empty_backup();
        backup.books = vec![serde_json::json!({
            "bookUrl": book_url,
            "name": "旧备份书",
            "author": "作者乙",
        })];
        fs::write(path_str, serde_json::to_string(&backup).unwrap()).unwrap();

        let stats_json = backup_restore(path_str).unwrap();
        let stats: RestoreStats = serde_json::from_str(&stats_json).unwrap();
        assert_eq!(stats.books, 1);

        let restored =
            with_database(|db| BookRepository::new(db.connection()).find_by_url(book_url))
                .unwrap()
                .expect("恢复后书籍应存在");
        assert_eq!(
            restored.dur_chapter_index, 0,
            "原版缺字段取默认 0 并全列覆盖，恢复后应为 0"
        );
        assert_eq!(restored.dur_chapter_pos, 0);
        assert_eq!(restored.dur_chapter_title, None);
        assert_eq!(restored.dur_chapter_time, 0);

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
                restore_backup_in_tx(conn, &backup, ReplaceTablePolicy::default())
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
                    let stats =
                        restore_backup_in_tx(conn, &backup, ReplaceTablePolicy::default()).unwrap();
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
        assert_eq!(data.version, BACKUP_VERSION, "新备份应携带当前格式版本 v3");
        assert!(data.backup_time > 0);
        assert!(
            content.contains("\"servers\""),
            "v3 备份应包含 servers 字段：{content}"
        );
        assert!(
            !content.contains("\"autoTasks\""),
            "自有 JSON 备份形状不得因批9 autoTasks 字段变化（空列表应省略）：{content}"
        );

        // 恢复备份
        let restore_result = backup_restore(path_str);
        assert!(restore_result.is_ok());

        // 清理
        let _ = fs::remove_dir_all(&dir);
    }

    /// [批8] servers 备份→清库→恢复→逐字段 diff
    ///
    /// 对齐原版 `Backup.kt:304-311`（servers.json = serverDao.all）与
    /// `Restore.kt:379-390`（按 id REPLACE insert）。
    #[test]
    fn test_servers_backup_restore_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_roundtrip_servers");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("servers_roundtrip.json");
        let path_str = backup_path.to_str().unwrap();

        // 种子：默认 WebDAV（负数主键）+ 用户自建服务器
        let default_server = legado_core::models::Server {
            id: legado_db::DEFAULT_WEBDAV_SERVER_ID,
            name: legado_db::DEFAULT_WEBDAV_SERVER_NAME.to_string(),
            server_type: legado_core::models::ServerType::WebDav,
            config: Some(
                r#"{"url":"https://dav.example.com/","username":"u","password":"p"}"#.to_string(),
            ),
            sort_number: 1,
        };
        let custom_server = legado_core::models::Server {
            id: 1700000000123,
            name: "网盘B".to_string(),
            server_type: legado_core::models::ServerType::WebDav,
            config: Some(
                r#"{"url":"https://dav2.example.com/","username":"u2","password":"p2"}"#
                    .to_string(),
            ),
            sort_number: 2,
        };
        with_database(|db| {
            let repo = ServerRepository::new(db.connection());
            repo.upsert(&default_server)?;
            repo.upsert(&custom_server)?;
            Ok(())
        })
        .unwrap();

        // 备份 → 清库 → 恢复
        assert!(backup_create(path_str).is_ok());
        with_database(|db| {
            db.connection()
                .execute("DELETE FROM servers", [])
                .map_err(|e| LegadoError::Database(format!("清空 servers 失败: {e}")))?;
            Ok(())
        })
        .unwrap();
        assert!(backup_restore(path_str).is_ok());

        let restored =
            with_database(|db| ServerRepository::new(db.connection()).find_all()).unwrap();
        assert_eq!(restored.len(), 2, "应恢复 2 条服务器配置");
        assert_eq!(
            serde_json::to_value(&restored[0]).unwrap(),
            serde_json::to_value(&default_server).unwrap(),
            "默认 WebDAV 服务器全字段应往返一致（含负数主键）"
        );
        assert_eq!(
            serde_json::to_value(&restored[1]).unwrap(),
            serde_json::to_value(&custom_server).unwrap(),
            "自建服务器全字段应往返一致"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批8] 旧 v1/v2 备份无 servers 键：恢复不崩、且不清库内既有 servers
    ///
    /// 对齐原版 `Restore.kt:379-390`：仅当 `servers.json` 文件存在才 insert；
    /// 缺失即不处理（不 delete-all）。
    #[test]
    fn test_legacy_backup_without_servers_keeps_existing_rows() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        // 库内已有服务器配置（恢复旧备份不得清除）
        with_database(|db| {
            ServerRepository::new(db.connection()).upsert(&legado_core::models::Server {
                id: legado_db::DEFAULT_WEBDAV_SERVER_ID,
                name: "保留".to_string(),
                server_type: legado_core::models::ServerType::WebDav,
                config: Some(r#"{"url":"https://keep.example.com/"}"#.to_string()),
                sort_number: 0,
            })?;
            Ok(())
        })
        .unwrap();

        let dir = std::env::temp_dir().join("legado_backup_legacy_no_servers");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("legacy_v2.json");
        // 真实旧 v2 备份形态：无 servers 键
        fs::write(
            &backup_path,
            r#"{"version":2,"backupTime":1700000000000,"books":[],"bookSources":[]}"#,
        )
        .unwrap();

        // 解析应为空 servers（serde default）
        let content = fs::read_to_string(&backup_path).unwrap();
        let parsed: BackupData = serde_json::from_str(&content).unwrap();
        assert!(parsed.servers.is_empty());

        // 恢复不崩，库内行保留
        assert!(backup_restore(backup_path.to_str().unwrap()).is_ok());
        let restored =
            with_database(|db| ServerRepository::new(db.connection()).find_all()).unwrap();
        assert_eq!(restored.len(), 1, "旧备份缺 servers 键不得清空库内配置");
        assert_eq!(restored[0].name, "保留");

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批8 回修 P2-2] v3 备份中 `id = 0` 的服务器行恢复后原样保留
    ///
    /// 恢复路径不得走 `ServerRepository::upsert` 的「id = 0 → 当前毫秒」
    /// 新建语义：否则同一备份重复恢复会不断产生新行。
    #[test]
    fn test_servers_restore_preserves_zero_id() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_servers_zero_id");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("servers_zero_id.json");
        fs::write(
            &backup_path,
            r#"{"version":3,"backupTime":0,"servers":[{"id":0,"name":"零号","type":"WEBDAV","config":"{\"url\":\"https://zero.example.com/\"}","sortNumber":4}]}"#,
        )
        .unwrap();
        let path_str = backup_path.to_str().unwrap();

        assert!(backup_restore(path_str).is_ok());
        let restored =
            with_database(|db| ServerRepository::new(db.connection()).find_all()).unwrap();
        assert_eq!(restored.len(), 1);
        assert_eq!(restored[0].id, 0, "恢复应原样保留 id=0，不重分配毫秒主键");
        assert_eq!(restored[0].sort_number, 4);

        // 重复恢复同一备份：REPLACE 原行，不产生第二条
        assert!(backup_restore(path_str).is_ok());
        let restored =
            with_database(|db| ServerRepository::new(db.connection()).find_all()).unwrap();
        assert_eq!(restored.len(), 1, "重复恢复不得新增服务器行");
        assert_eq!(restored[0].id, 0);

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

    // ─── 批9：原版 zip 备份恢复 ─────────────────────────────────────────

    /// 在临时目录写一个原版形态备份 zip（条目名 → 原始字节），返回 (目录, 路径)
    fn write_upstream_backup_zip(
        dir_name: &str,
        entries: &[(&str, &[u8])],
    ) -> (std::path::PathBuf, String) {
        use std::io::Write as _;

        let dir = std::env::temp_dir().join(dir_name);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let zip_path = dir.join("backup2026-10-26.zip");
        {
            let file = fs::File::create(&zip_path).unwrap();
            let mut writer = zip::ZipWriter::new(file);
            let options = zip::write::SimpleFileOptions::default();
            for (name, data) in entries {
                writer.start_file(*name, options).unwrap();
                writer.write_all(data).unwrap();
            }
            writer.finish().unwrap();
        }
        let path = zip_path.to_str().unwrap().to_string();
        (dir, path)
    }

    /// 原版「空密码」密钥加密的 servers.json（openssl AES-128-ECB/PKCS7 独立生成）
    ///
    /// 密钥 = MD5("") 小写 hex 前 16 个 ASCII 字符 `d41d8cd98f00b204`；
    /// 明文 = `[{"id":1700000000002,"name":"网盘B","type":"WEBDAV",
    /// "config":"{\"url\":\"https://dav.example.com/\"}","sortNumber":3}]`。
    /// 用外部工具生成可避免「我方加密 + 我方解密」自洽的假绿。
    const UPSTREAM_EMPTY_PW_SERVERS: &str = "xSIcudYLSog9xFjHp/CQFf0Jhx2/XL8tX/EMThjpDxVc0TnFhOkmarznE9mTpoM4T6O6IY2F5pe/854MstinyYXIYRJ3Z6OelaJOPtVthBUprXzkzcYhGTwfbgDoimWRiaVvuxJolIscFijSJm+Q7IFXilXDqKGnsvqXroY/4Sk=";

    /// 原版「密码 secret」密钥加密的 servers.json（openssl AES-128-ECB/PKCS7 独立生成）
    ///
    /// 密钥 = MD5("secret") 小写 hex 前 16 个 ASCII 字符 `5ebe2294ecd0e0f0`。
    const UPSTREAM_SECRET_PW_SERVERS: &str = "2vU9PxdlMNdJf1ZFkNTKycmGR0xILunMY6nIlKNqGxbBimVUkWjSd0juf6gc/wO5/Gf0BuDDaTzIqpLG1FWHe0kv2jIAZZiIrlG/2gyyyV8Rpnrdkw6KxU0pWcUDah9/dm+xTmldxLQNMeYqaCjXmbCAm8HhRvwnfLB34pV/Hpw=";

    /// [批9 回归] 原版 zip 全类别落库：17 类数据文件 + 加密 servers + 媒体/配置跳过
    #[test]
    fn test_restore_upstream_zip_roundtrip_all_tables() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        // 原版 GSON 形态（属性名 camelCase、null 省略、无我方扩展键）
        let bookshelf = r#"[
            {"bookUrl":"https://zip.example/book/1","name":"zip书一","author":"作者甲",
             "kind":"玄幻","origin":"https://zip.example/source","originName":"zip源",
             "type":0,"group":7,"durChapterIndex":4,"durChapterPos":12,
             "durChapterTitle":"第五章","durChapterTime":1700000000123,
             "customCoverUrl":"/storage/emulated/0/Android/data/io.legado.app.release/files/covers/book1.jpg"},
            {"bookUrl":"https://zip.example/book/2","name":"zip书二","author":"作者乙",
             "origin":"https://zip.example/source","originName":"zip源","type":0,
             "customCoverUrl":"https://cdn.example/cover2.jpg"}
        ]"#;
        let book_group = r#"[
            {"groupId":7,"groupName":"zip分组",
             "cover":"/storage/emulated/0/Android/data/io.legado.app.release/files/covers/g.png",
             "order":3,"enableRefresh":false,"show":false,"bookSort":2,"onlyUpdateRead":true}
        ]"#;
        let bookmark = r#"[{"id":11,"time":1700000001000,"bookName":"zip书一","bookAuthor":"作者甲",
            "chapterIndex":2,"chapterPos":9,"chapterName":"第三章","bookText":"书签文本","content":"内容"}]"#;
        let highlight = r#"[{"time":1700000002000,"bookUrl":"https://zip.example/book/1",
            "chapterUrl":"ch://1","bookName":"zip书一","bookAuthor":"作者甲","chapterIndex":1,
            "chapterPos":2,"chapterPosEnd":8,"layoutTitleLength":3,"chapterName":"第二章",
            "bookText":"高亮文本","style":"{\"fill\":1}","note":"笔记"}]"#;
        let highlight_rule = r#"[{"id":77,"uuid":"77777777-7777-4777-8777-777777777777",
            "name":"zip高亮规则","pattern":"关键[词]","isRegex":true,"isEnabled":true,
            "style":"{}","order":2,"timeoutMillisecond":3000,"applyToTitle":false,"applyToBody":true}]"#;
        let book_source = r#"[{"bookSourceUrl":"https://zip.example/source","bookSourceName":"zip源",
            "bookSourceGroup":"组","bookSourceType":0,"enabled":true,"enabledExplore":true,
            "customOrder":1,"weight":0,"respondTime":180000,
            "searchUrl":"/search?q={{key}}",
            "ruleSearch":{"bookList":"class.b","name":"a@text","bookUrl":"a@href"}}]"#;
        let rss_sources = r#"[{"sourceUrl":"https://zip.example/rss","sourceName":"zip RSS",
            "sourceIcon":"https://zip.example/icon.png","enabled":true,"type":1,
            "ruleArticles":"class.item","ruleLink":"a@href","ruleTitle":"h1@text"}]"#;
        let rss_star = r#"[{"origin":"https://zip.example/rss","sort":"default","title":"zip收藏",
            "starTime":1700000003000,"link":"https://zip.example/rss/a1","group":"",
            "type":1,"durPos":4}]"#;
        let replace_rule = r#"[{"id":21,"name":"zip替换规则","pattern":"a","replacement":"b",
            "scopeTitle":false,"scopeSource":false,"scopeContent":true,"isEnabled":true,
            "isRegex":true,"timeoutMillisecond":3000,"order":5,"previewText":"样例"}]"#;
        let read_record = r#"[{"deviceId":"original-device","bookName":"zip书一","author":"作者甲",
            "readTime":1700000004000,"lastRead":8}]"#;
        let search_history = r#"[{"word":"zip关键词","usage":2,"lastUseTime":1700000005000}]"#;
        let source_sub = r#"[{"id":31,"name":"zip订阅","url":"https://zip.example/sub.json",
            "type":0,"customOrder":2,"autoUpdate":true,"update":1700000006000,
            "updateInterval":30,"silentUpdate":false}]"#;
        let txt_toc_rule = r#"[{"id":41,"name":"zip目录规则","rule":"^第","replacement":"",
            "serialNumber":-1,"enable":true,"example":"第一章"}]"#;
        let http_tts = r#"[{"id":51,"name":"zip引擎","url":"https://tts.example/?t={{speakText}}",
            "contentType":"audio/mpeg","pauseDuration":300,"concurrentRate":"1",
            "enabledCookieJar":false,"lastUpdateTime":1700000007000}]"#;
        let dict_rule = r#"[{"name":"zip词典","urlRule":"https://dict.example/{{key}}",
            "showRule":"tag.body@all","enabled":true,"sortNumber":2}]"#;
        let keyboard_assists = r#"[{"type":1,"key":"zipk","value":"zipv","serialNo":3}]"#;
        let auto_task = r#"[{"id":"zip-task-1","name":"zip任务","enable":true,
            "cron":"0 8 * * *","script":"test()","customOrder":1,"lastRunAt":0}]"#;

        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_upstream_zip",
            &[
                ("bookshelf.json", bookshelf.as_bytes()),
                ("bookGroup.json", book_group.as_bytes()),
                ("bookmark.json", bookmark.as_bytes()),
                ("highlight.json", highlight.as_bytes()),
                ("highlightRule.json", highlight_rule.as_bytes()),
                ("bookSource.json", book_source.as_bytes()),
                ("rssSources.json", rss_sources.as_bytes()),
                ("rssStar.json", rss_star.as_bytes()),
                ("replaceRule.json", replace_rule.as_bytes()),
                ("readRecord.json", read_record.as_bytes()),
                ("searchHistory.json", search_history.as_bytes()),
                ("sourceSub.json", source_sub.as_bytes()),
                ("txtTocRule.json", txt_toc_rule.as_bytes()),
                ("httpTTS.json", http_tts.as_bytes()),
                ("dictRule.json", dict_rule.as_bytes()),
                ("keyboardAssists.json", keyboard_assists.as_bytes()),
                ("autoTask.json", auto_task.as_bytes()),
                ("servers.json", UPSTREAM_EMPTY_PW_SERVERS.as_bytes()),
                // 媒体与配置快照：存在但不落盘（登记跳过），验证不中断恢复
                ("covers/book1.jpg", b"\xFF\xD8\xFF-fake-jpeg"),
                ("bg/wall.jpg", b"fake-bg"),
                ("readConfig.json", b"[]"),
                ("themeConfig.json", b"[]"),
                ("config.xml", b"<map />"),
            ],
        );

        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.books, 2);
        assert_eq!(stats.bookmarks, 1);
        assert_eq!(stats.replace_rules, 1);
        assert_eq!(stats.book_sources, 1);
        assert_eq!(stats.rss_sources, 1);
        assert_eq!(stats.read_records, 1);

        with_database(|db| {
            let conn = db.connection();

            // 书架：进度原样、绝对封面路径置空、网络封面保留
            let book1 = BookRepository::new(conn)
                .find_by_url("https://zip.example/book/1")?
                .expect("zip 备份书一应落库");
            assert_eq!(book1.dur_chapter_index, 4);
            assert_eq!(book1.dur_chapter_pos, 12);
            assert_eq!(book1.dur_chapter_title.as_deref(), Some("第五章"));
            assert_eq!(book1.dur_chapter_time, 1700000000123);
            assert_eq!(
                book1.custom_cover_url, None,
                "原版绝对 covers 路径在未恢复媒体时应置空（对齐 remap 失败语义）"
            );
            let book2 = BookRepository::new(conn)
                .find_by_url("https://zip.example/book/2")?
                .expect("zip 备份书二应落库");
            assert_eq!(
                book2.custom_cover_url.as_deref(),
                Some("https://cdn.example/cover2.jpg"),
                "网络封面 URL 不得被清空"
            );

            // 分组：封面同样置空，其余列原样
            let group = BookGroupRepository::new(conn)
                .find_by_id(7)?
                .expect("分组应落库");
            assert_eq!(group.group_name, "zip分组");
            assert_eq!(group.cover, None);
            assert!(!group.enable_refresh);
            assert_eq!(group.book_sort, 2);
            assert!(group.only_update_read);

            // 书签
            let bookmarks = BookmarkRepository::new(conn).find_all()?;
            assert_eq!(bookmarks.len(), 1);
            assert_eq!(bookmarks[0].book_name, "zip书一");
            assert_eq!(bookmarks[0].chapter_index, 2);
            assert_eq!(bookmarks[0].book_text, "书签文本");

            // 高亮
            let highlight = HighlightRepository::new(conn)
                .find_by_time(1700000002000)?
                .expect("高亮应落库");
            assert_eq!(highlight.bookName, "zip书一");
            assert_eq!(highlight.style, "{\"fill\":1}");
            assert_eq!(highlight.note, "笔记");

            // 高亮规则：order → sortOrder 归一
            let rule = HighlightRuleRepository::new(conn)
                .find_by_id(77)?
                .expect("高亮规则应落库");
            assert_eq!(rule.name, "zip高亮规则");
            assert_eq!(rule.sortOrder, 2, "原版 order 键应归一到 sortOrder");
            assert_eq!(
                rule.uuid, "77777777-7777-4777-8777-777777777777",
                "uuid 应随 zip 备份保留"
            );

            // 书源
            let source = BookSourceRepository::new(conn)
                .find_by_url("https://zip.example/source")?
                .expect("书源应落库");
            assert_eq!(source.book_source_name, "zip源");
            assert!(source.rule_search.is_some(), "搜索规则应随备份落库");

            // RSS 源 / 收藏
            let rss = RssSourceRepository::new(conn)
                .find_by_url("https://zip.example/rss")
                .map_err(LegadoError::Database)?
                .expect("RSS 源应落库");
            assert_eq!(rss.rule_articles.as_deref(), Some("class.item"));
            let stars = RssStarRepository::new(conn).find_all()?;
            assert_eq!(stars.len(), 1);
            assert_eq!(stars[0].title, "zip收藏");
            assert_eq!(stars[0].star_type, 1);
            assert_eq!(stars[0].dur_pos, 4);

            // 替换规则：order → sortOrder 归一
            let rules = ReplaceRuleRepository::new(conn).find_all()?;
            assert_eq!(rules.len(), 1);
            assert_eq!(rules[0].name, "zip替换规则");
            assert_eq!(rules[0].order, 5, "原版 order 键应归一到 sortOrder");

            // 阅读记录（P2-5：原版设备 ID 归一为单设备空串，走「本机较新者胜」）
            let records = ReadRecordRepository::new(conn).find_all()?;
            assert_eq!(records.len(), 1);
            assert_eq!(
                records[0].device_id, "",
                "zip 备份的 deviceId 应归一为空串（单设备模型）"
            );
            assert_eq!(records[0].read_time, 1700000004000);
            assert_eq!(records[0].last_read, 8);

            // 搜索历史（usage/lastUseTime 原样）
            let keywords = SearchKeywordRepository::new(conn).find_all()?;
            assert_eq!(keywords.len(), 1);
            assert_eq!(keywords[0].word, "zip关键词");
            assert_eq!(keywords[0].usage, 2);
            assert_eq!(keywords[0].last_use_time, 1700000005000);

            // 规则订阅：type(int)/update 归一，无 version/isEnabled/createdAt 时补默认
            let sub = RuleSubRepository::new(conn)
                .find_by_url("https://zip.example/sub.json")?
                .expect("规则订阅应落库");
            assert_eq!(sub.name, "zip订阅");
            assert_eq!(sub.sub_type, "bookSource");
            assert_eq!(sub.custom_order, 2);
            assert!(sub.auto_update);
            assert_eq!(sub.last_update, 1700000006000);
            assert_eq!(sub.created_at, 1700000006000);
            assert_eq!(sub.version, "");
            assert!(sub.is_enabled);

            // TXT 目录规则
            let toc_rules = TxtTocRuleRepository::new(conn).find_all()?;
            assert_eq!(toc_rules.len(), 1);
            assert_eq!(toc_rules[0].id, 41);
            assert_eq!(toc_rules[0].serial_number, -1);
            assert!(toc_rules[0].enable);

            // 朗读引擎：原版无 isEnabled 列 → 归一为启用
            let tts = HttpTtsRepository::new(conn)
                .find_by_id(51)?
                .expect("朗读引擎应落库");
            assert_eq!(tts.name, "zip引擎");
            assert!(tts.is_enabled, "原版 HttpTTS 无启用列，恢复后应可用");
            assert_eq!(tts.created_at, 1700000007000);

            // 词典规则
            let dict = DictRuleRepository::new(conn)
                .find_by_name("zip词典")?
                .expect("词典规则应落库");
            assert_eq!(dict.sort_order, 2);
            assert!(dict.is_enabled);

            // 键盘辅助
            let assist = KeyboardAssistRepository::new(conn)
                .find_by_pk(1, "zipk")?
                .expect("键盘辅助应落库");
            assert_eq!(assist.value, "zipv");
            assert_eq!(assist.serial_no, 3);

            // 自动任务（批9 新增映射）
            let tasks = AutoTaskRepository::new(conn).find_all()?;
            assert_eq!(tasks.len(), 1);
            assert_eq!(tasks[0].id, "zip-task-1");
            assert_eq!(tasks[0].name, "zip任务");
            assert_eq!(tasks[0].cron.as_deref(), Some("0 8 * * *"));
            assert_eq!(tasks[0].script, "test()");

            // 服务器：原版空密码密文应解密并按主键写入
            let servers = ServerRepository::new(conn).find_all()?;
            assert_eq!(servers.len(), 1, "加密 servers.json 应解密恢复");
            assert_eq!(servers[0].id, 1700000000002);
            assert_eq!(servers[0].name, "网盘B");
            assert_eq!(servers[0].sort_number, 3);
            assert!(
                servers[0]
                    .config
                    .as_deref()
                    .unwrap_or_default()
                    .contains("dav.example.com"),
                "服务器配置应随解密还原"
            );

            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 兼容] zip 内缺某文件 → 跳过该类，其余照常恢复（对齐原版 fileToListT 缺文件语义）
    #[test]
    fn test_restore_upstream_zip_missing_files_skip_class() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let bookshelf =
            r#"[{"bookUrl":"https://zip.example/only","name":"仅书架","author":"作者"}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_missing_files",
            &[("./bookshelf.json", bookshelf.as_bytes())],
        );

        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.books, 1);
        assert_eq!(stats.bookmarks, 0);
        assert_eq!(stats.replace_rules, 0);
        assert_eq!(stats.book_sources, 0);
        assert_eq!(stats.rss_sources, 0);
        assert_eq!(stats.read_records, 0);

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 兼容] 损坏条目类文件 → 该类 warn 跳过，合法条目照常提交
    #[test]
    fn test_restore_upstream_zip_broken_entry_skips_only_that_class() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let bookshelf =
            r#"[{"bookUrl":"https://zip.example/broken-peer","name":"同伴书","author":"作者"}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_broken_entry",
            &[
                ("bookshelf.json", bookshelf.as_bytes()),
                ("bookSource.json", b"{not-a-json-array"),
            ],
        );

        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.books, 1, "损坏的 bookSource.json 不得影响书架恢复");
        assert_eq!(stats.book_sources, 0);

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 负例] 魔数像 zip 但内容损坏 → 整体报错（对齐原版解压失败即中止）
    #[test]
    fn test_restore_broken_zip_errors() {
        let dir = std::env::temp_dir().join("legado_restore_zip_broken");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("broken.zip");
        fs::write(&path, b"PK\x03\x04this-is-not-a-real-zip").unwrap();

        let err = backup_restore(path.to_str().unwrap()).unwrap_err();
        assert!(
            err.to_string().contains("zip 解析失败"),
            "应给出 zip 解析失败文案: {err}"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 负例] 空 zip（仅 EOCD）→ 合法但零恢复（对齐原版：无文件即无动作）
    #[test]
    fn test_restore_empty_zip_returns_zero_stats() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let (dir, path) = write_upstream_backup_zip("legado_restore_zip_empty", &[]);
        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.books, 0);
        assert_eq!(stats.book_sources, 0);

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 加密] 含加密 cookies.json（原版设过备份密码）→ 明确错误文案且零落库
    ///
    /// 对齐原版 `Restore.kt:227-236`：cookies.json 存在且无密码时上抛
    /// 「需设置备份密码」；我方无密码输入面，故返回可读错误而不是静默跳过。
    ///
    /// [批9 回修 P2-12] 预置哨兵行：断言拒绝恢复时库内既有数据**未被触碰**，
    /// 证明「零落库」而不是「恰好表为空」。
    #[test]
    fn test_restore_zip_password_protected_cookies_errors_without_writes() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        // 哨兵：库内既有书 + 书源（拒绝恢复后必须原样保留）
        with_database(|db| {
            let conn = db.connection();
            BookRepository::new(conn).insert(&Book {
                book_url: "https://zip.example/sentinel".to_string(),
                name: "哨兵书".to_string(),
                author: "哨兵作者".to_string(),
                ..Book::default()
            })?;
            BookSourceRepository::new(conn).insert(&BookSource {
                book_source_url: "https://zip.example/sentinel-source".to_string(),
                book_source_name: "哨兵源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .unwrap();

        let bookshelf =
            r#"[{"bookUrl":"https://zip.example/locked","name":"加密书","author":"作者"}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_encrypted",
            &[
                ("bookshelf.json", bookshelf.as_bytes()),
                // cookies.json 只有设过备份密码才写出，内容必为密文
                ("cookies.json", UPSTREAM_SECRET_PW_SERVERS.as_bytes()),
            ],
        );

        let err = backup_restore(&path).unwrap_err();
        let message = err.to_string();
        assert!(message.contains("备份密码"), "应提示备份密码: {message}");
        assert!(
            message.contains("cookies.json"),
            "应指出加密文件: {message}"
        );

        // 前置校验失败不得产生部分恢复态，也不得触碰库内既有数据
        with_database(|db| {
            let conn = db.connection();
            let books = BookRepository::new(conn).find_all()?;
            assert_eq!(books.len(), 1, "哨兵书应原样保留：{books:?}");
            assert_eq!(books[0].book_url, "https://zip.example/sentinel");
            let sources = BookSourceRepository::new(conn).find_all()?;
            assert_eq!(sources.len(), 1, "哨兵源应原样保留：{sources:?}");
            assert_eq!(
                sources[0].book_source_url,
                "https://zip.example/sentinel-source"
            );
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 回修 P2-12] runtimeSourceCache.json 明文/密文两分支
    ///
    /// - 密文（设过备份密码）→ 明确错误文案，且库内哨兵行未被触碰；
    /// - 明文数组（历史/第三方产出）→ warn 跳过该类，其余表照常恢复。
    #[test]
    fn test_restore_zip_runtime_source_cache_branches() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let bookshelf =
            r#"[{"bookUrl":"https://zip.example/runtime","name":"运行变量书","author":"作者"}]"#;

        // ── 密文分支 ───────────────────────────────────────────
        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: "https://zip.example/runtime-sentinel".to_string(),
                name: "运行变量哨兵".to_string(),
                author: "哨兵".to_string(),
                ..Book::default()
            })?;
            Ok(())
        })
        .unwrap();
        let (dir_enc, path_enc) = write_upstream_backup_zip(
            "legado_restore_zip_runtime_encrypted",
            &[
                ("bookshelf.json", bookshelf.as_bytes()),
                (
                    "runtimeSourceCache.json",
                    UPSTREAM_SECRET_PW_SERVERS.as_bytes(),
                ),
            ],
        );
        let err = backup_restore(&path_enc).unwrap_err();
        let message = err.to_string();
        assert!(message.contains("备份密码"), "应提示备份密码: {message}");
        assert!(
            message.contains("runtimeSourceCache.json"),
            "应指出加密文件: {message}"
        );
        with_database(|db| {
            let books = BookRepository::new(db.connection()).find_all()?;
            assert_eq!(books.len(), 1, "拒绝恢复时哨兵行不得被触碰: {books:?}");
            assert_eq!(
                books[0].book_url, "https://zip.example/runtime-sentinel",
                "哨兵行内容不得变化"
            );
            Ok::<(), LegadoError>(())
        })
        .unwrap();
        let _ = fs::remove_dir_all(&dir_enc);

        // ── 明文分支 ───────────────────────────────────────────
        clear_backup_tables();
        let (dir_plain, path_plain) = write_upstream_backup_zip(
            "legado_restore_zip_runtime_plaintext",
            &[
                ("bookshelf.json", bookshelf.as_bytes()),
                ("runtimeSourceCache.json", b"[]"),
            ],
        );
        let stats: RestoreStats =
            serde_json::from_str(&backup_restore(&path_plain).unwrap()).unwrap();
        assert_eq!(
            stats.books, 1,
            "明文 runtimeSourceCache 只跳过该类，不得影响书架"
        );
        with_database(|db| {
            let books = BookRepository::new(db.connection()).find_all()?;
            assert_eq!(books.len(), 1);
            assert_eq!(books[0].book_url, "https://zip.example/runtime");
            Ok::<(), LegadoError>(())
        })
        .unwrap();
        let _ = fs::remove_dir_all(&dir_plain);
    }

    /// [批9 加密] 密文用真实密码加密 → servers 跳过，其余表照常恢复（对齐原版 runCatching）
    #[test]
    fn test_restore_zip_secret_password_servers_skipped() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let bookshelf =
            r#"[{"bookUrl":"https://zip.example/with-secret","name":"密码书","author":"作者"}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_secret_pw",
            &[
                ("bookshelf.json", bookshelf.as_bytes()),
                ("servers.json", UPSTREAM_SECRET_PW_SERVERS.as_bytes()),
            ],
        );

        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.books, 1, "服务器配置解密失败不得影响其余表");

        let servers =
            with_database(|db| ServerRepository::new(db.connection()).find_all()).unwrap();
        assert!(
            servers.is_empty(),
            "空密码解不开的 servers.json 应跳过，不得写入垃圾行"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 兼容] 历史版本 servers.json 为明文数组 → 按明文解析（原版 isJsonArray 分支）
    #[test]
    fn test_restore_zip_plaintext_servers_supported() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let plain_servers = r#"[{"id":9,"name":"明文服务器","type":"WEBDAV",
            "config":"{\"url\":\"https://plain.example/\",\"username\":\"u\",\"password\":\"p\"}",
            "sortNumber":1}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_plain_servers",
            &[("servers.json", plain_servers.as_bytes())],
        );

        assert!(backup_restore(&path).is_ok());
        let servers =
            with_database(|db| ServerRepository::new(db.connection()).find_all()).unwrap();
        assert_eq!(servers.len(), 1);
        assert_eq!(servers[0].id, 9);
        assert_eq!(servers[0].name, "明文服务器");

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 回修 P2-5] 本机既有记录 + zip 备份记录 → 恢复后单行且较新者胜
    ///
    /// 原版 zip 的 deviceId 是原设备 androidId；若按「他机记录」直插，会与本机
    /// 同书名记录并存两行，Flutter 阅读记录页按 bookName 合并会把 readTime 相加
    /// （阅读时长翻倍）。归一为空串后必须只剩一行，且库内较新值不被覆盖。
    #[test]
    fn test_restore_upstream_zip_read_record_single_row_newest_wins() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        // 本机既有记录（较新：readTime 1700000009000）
        with_database(|db| {
            ReadRecordRepository::new(db.connection()).upsert_full(
                "",
                "zip书一",
                "作者乙",
                1_700_000_009_000,
                90,
            )
        })
        .unwrap();

        // 原版 zip 备份记录（较旧：readTime 1700000004000，deviceId 为原设备）
        let read_record = r#"[{"deviceId":"original-device","bookName":"zip书一",
            "author":"作者甲","readTime":1700000004000,"lastRead":8}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_read_record",
            &[("readRecord.json", read_record.as_bytes())],
        );

        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.read_records, 1);

        with_database(|db| {
            let rows = ReadRecordRepository::new(db.connection()).find_all()?;
            assert_eq!(
                rows.len(),
                1,
                "不得因 deviceId 差异产生两行（两行会被 Flutter 合并导致时长翻倍）: {rows:?}"
            );
            assert_eq!(rows[0].device_id, "", "zip 记录 deviceId 应归一为空串");
            assert_eq!(
                rows[0].read_time, 1_700_000_009_000,
                "本机较新 readTime 不得被较旧备份覆盖"
            );
            assert_eq!(rows[0].last_read, 90, "lastRead 保留库内较新值");
            let authors = legado_db::repository::read_record_repository::decode_read_record_authors(
                &rows[0].author,
            );
            assert!(
                authors.contains(&"作者乙".to_string()),
                "库内作者应保留: {}",
                rows[0].author
            );
            assert!(
                authors.contains(&"作者甲".to_string()),
                "备份作者应合并: {}",
                rows[0].author
            );
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 回修 P2-6] 高亮规则/键盘辅助：恢复语义为「以备份集合为准」
    ///
    /// 对齐原版 `Restore.kt:310-313`（highlightRuleDao.replaceAll）与
    /// `:359-361`（keyboardAssists deleteAll + insert）：库内备份外的旧行必须
    /// 被清掉；备份缺失这两类文件时不触碰库内旧行（对齐原版 fileToListT null）。
    #[test]
    fn test_restore_zip_replaces_highlight_rules_and_keyboard_assists() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let make_rule = |id: i64, name: &str| legado_core::models::HighlightRule {
            id,
            name: name.to_string(),
            pattern: "p".to_string(),
            isRegex: false,
            scope: None,
            isEnabled: true,
            style: "{}".to_string(),
            sortOrder: 0,
            timeoutMillisecond: 1000,
            applyToTitle: false,
            uuid: format!("0000000{id}-0000-4000-8000-000000000000"),
            applyToBody: true,
        };
        let make_assist = |key: &str| KeyboardAssist {
            assist_type: 1,
            key: key.to_string(),
            value: "v".to_string(),
            serial_no: 0,
        };

        // 库内旧行：2 条高亮规则 + 2 条键盘辅助
        with_database(|db| {
            let conn = db.connection();
            HighlightRuleRepository::new(conn).insert(&make_rule(1, "旧规则一"))?;
            HighlightRuleRepository::new(conn).insert(&make_rule(2, "旧规则二"))?;
            KeyboardAssistRepository::new(conn).insert_record(&make_assist("old_key_1"))?;
            KeyboardAssistRepository::new(conn).insert_record(&make_assist("old_key_2"))?;
            Ok(())
        })
        .unwrap();

        // 备份只含 1 条规则 + 1 条辅助（不同键）
        let highlight_rule = r#"[{"id":77,"uuid":"77777777-7777-4777-8777-777777777777",
            "name":"备份规则","pattern":"p","isRegex":false,"isEnabled":true,
            "style":"{}","order":0,"timeoutMillisecond":1000,
            "applyToTitle":false,"applyToBody":true}]"#;
        let keyboard_assists = r#"[{"type":1,"key":"new_key","value":"v","serialNo":0}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_replace_tables",
            &[
                ("highlightRule.json", highlight_rule.as_bytes()),
                ("keyboardAssists.json", keyboard_assists.as_bytes()),
            ],
        );

        assert!(backup_restore(&path).is_ok());

        with_database(|db| {
            let conn = db.connection();
            let rules = HighlightRuleRepository::new(conn).find_all()?;
            assert_eq!(rules.len(), 1, "备份外旧规则应被清空: {rules:?}");
            assert_eq!(rules[0].id, 77);
            assert_eq!(rules[0].name, "备份规则");

            let assists = KeyboardAssistRepository::new(conn).find_all()?;
            assert_eq!(assists.len(), 1, "备份外旧辅助规则应被清空: {assists:?}");
            assert_eq!(assists[0].key, "new_key");
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        // 备份缺这两类文件 → 不触碰库内旧行（重新播种后恢复一个无关 zip）
        with_database(|db| {
            let conn = db.connection();
            HighlightRuleRepository::new(conn).insert(&make_rule(8, "保留规则"))?;
            KeyboardAssistRepository::new(conn).insert_record(&make_assist("keep_key"))?;
            Ok(())
        })
        .unwrap();
        let bookshelf =
            r#"[{"bookUrl":"https://zip.example/rules-keep","name":"规则保留书","author":"作者"}]"#;
        let (dir2, path2) = write_upstream_backup_zip(
            "legado_restore_zip_rules_absent",
            &[("bookshelf.json", bookshelf.as_bytes())],
        );
        assert!(backup_restore(&path2).is_ok());
        with_database(|db| {
            let conn = db.connection();
            let rules = HighlightRuleRepository::new(conn).find_all()?;
            assert_eq!(
                rules.len(),
                2,
                "备份缺 highlightRule.json 时不得清空库内规则"
            );
            let assists = KeyboardAssistRepository::new(conn).find_all()?;
            assert_eq!(
                assists.len(),
                2,
                "备份缺 keyboardAssists.json 时不得清空库内辅助规则"
            );
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&dir2);
    }

    /// [批9 回修 P2-12] sourceSub.type=1/3 分支：rssSource / replaceRule 映射
    #[test]
    fn test_restore_zip_source_sub_type_mapping() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let source_sub = r#"[
            {"id":1,"name":"书源订阅","url":"https://sub.example/book.json","type":0,
             "customOrder":1,"autoUpdate":true,"update":1700000001000,
             "updateInterval":30,"silentUpdate":false},
            {"id":2,"name":"RSS订阅","url":"https://sub.example/rss.json","type":1,
             "customOrder":2,"autoUpdate":true,"update":1700000002000,
             "updateInterval":30,"silentUpdate":false},
            {"id":3,"name":"替换订阅","url":"https://sub.example/replace.json","type":3,
             "customOrder":3,"autoUpdate":true,"update":1700000003000,
             "updateInterval":30,"silentUpdate":false}
        ]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_sub_types",
            &[("sourceSub.json", source_sub.as_bytes())],
        );

        assert!(backup_restore(&path).is_ok());

        with_database(|db| {
            let repo = RuleSubRepository::new(db.connection());
            let book = repo
                .find_by_url("https://sub.example/book.json")?
                .expect("type=0 应落库");
            let rss = repo
                .find_by_url("https://sub.example/rss.json")?
                .expect("type=1 应落库");
            let replace = repo
                .find_by_url("https://sub.example/replace.json")?
                .expect("type=3 应落库");
            assert_eq!(book.sub_type, "bookSource");
            assert_eq!(rss.sub_type, "rssSource", "原版 type=1 应映射订阅源");
            assert_eq!(
                replace.sub_type, "replaceRule",
                "原版 type=3 应映射替换规则"
            );
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 回修 P2-12/P2-13] 真实 `../bookshelf.json` 条目被拒、零恢复且发出告警
    #[test]
    fn test_restore_zip_rejects_parent_dir_entry_and_warns() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let bookshelf =
            r#"[{"bookUrl":"https://zip.example/escape","name":"逃逸书","author":"作者"}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_parent_dir",
            &[("../bookshelf.json", bookshelf.as_bytes())],
        );

        // 路径校验拒绝该条目：文件内容不解压，entry_names 也为空
        let bytes = fs::read(&path).unwrap();
        let archive = read_zip_backup(&bytes).unwrap();
        assert!(archive.files.is_empty(), "不安全路径条目不得解压");
        assert!(archive.entry_names.is_empty(), "不安全路径条目不得记入清单");
        // P2-13：全部条目被拒（entry_names 为空）时同样必须发出「未找到数据文件」告警
        assert!(
            report_unmapped_zip_entries(&archive),
            "全部条目被拒时应报告「未找到原版数据文件」"
        );

        // 端到端：恢复不报错但零落库
        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.books, 0, "被拒条目不得恢复");
        with_database(|db| {
            assert!(
                BookRepository::new(db.connection()).find_all()?.is_empty(),
                "零恢复：库内不得出现逃逸条目写入的书"
            );
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// 把 zip 条目的「未压缩大小」声明改写为 `fake_size`（本地头 + 中央目录）
    ///
    /// 仅用于构造「声明小 / 实际大」的解压炸弹回归样本：压缩数据与 CRC 保持
    /// 原样，只有声明值被伪造（zip 2.4 解压按 compressed_size 限流，不校验声明值）。
    fn forge_zip_uncompressed_size(bytes: &mut [u8], fake_size: u32) {
        assert_eq!(&bytes[..4], b"PK\x03\x04", "本地文件头魔数不符");
        // 本地头：signature(4)+version(2)+flags(2)+method(2)+time(2)+date(2)+crc(4)
        //        +compressedSize(4) = 22 偏移处为 uncompressedSize
        bytes[22..26].copy_from_slice(&fake_size.to_le_bytes());
        // 中央目录头：signature(4)+versionMade(2)+versionNeeded(2)+flags(2)
        //            +method(2)+time(2)+date(2)+crc(4)+compressedSize(4) = 24 偏移
        let cd = bytes
            .windows(4)
            .position(|w| w == b"PK\x01\x02")
            .expect("zip 中央目录缺失");
        bytes[cd + 24..cd + 28].copy_from_slice(&fake_size.to_le_bytes());
    }

    /// [批9 回修 P1] 伪造 uncompressed_size 的超量条目必须按实际读取量跳过
    ///
    /// 用 zip 2.4 构造真实条目（数据与 CRC 完好），仅把声明未压缩大小改为 32
    /// 字节；实际内容 8192 字节。旧实现只看 `entry.size()` 会放行并
    /// `read_to_end` 无限解压；修复后限量读取按实际字节数判定为超限并跳过。
    /// 为避免测试真的生成 256 MiB 数据，直接以较小的 `limit` 调用同一防护函数。
    #[test]
    fn test_zip_forged_uncompressed_size_entry_skipped() {
        use std::io::Write as _;

        let dir = std::env::temp_dir().join("legado_restore_zip_forged_size");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let zip_path = dir.join("forged.zip");

        // 合法书架 JSON + 尾部空白填充到 8192 字节（decode_zip_text 会 trim）
        let mut payload =
            r#"[{"bookUrl":"https://zip.example/forged","name":"伪造书","author":"作者"}]"#
                .as_bytes()
                .to_vec();
        payload.resize(8192, b' ');
        {
            let file = fs::File::create(&zip_path).unwrap();
            let mut writer = zip::ZipWriter::new(file);
            writer
                .start_file("bookshelf.json", zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(&payload).unwrap();
            writer.finish().unwrap();
        }
        let mut bytes = fs::read(&zip_path).unwrap();
        forge_zip_uncompressed_size(&mut bytes, 32);

        // 声明值已伪造：entry.size() 返回 32（旧实现的放行条件）
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(&bytes[..])).unwrap();
        let mut entry = archive.by_index(0).unwrap();
        assert_eq!(entry.size(), 32, "伪造的声明大小应生效");

        // 限量读取（测试上限 1024）→ 实际 8192 字节超限，必须跳过
        let mut total_decoded = 0u64;
        let result = read_zip_entry_limited(
            "bookshelf.json",
            entry.size(),
            &mut entry,
            1024,
            &mut total_decoded,
            MAX_BACKUP_TOTAL_BYTES,
        )
        .unwrap();
        assert!(
            result.is_none(),
            "声明小/实际大的条目必须按实际解压量判定为超限并跳过"
        );
        assert!(
            total_decoded > 1024,
            "已读取字节应计入累计预算: {total_decoded}"
        );

        // 证明条目数据与 CRC 本身完好：不限量读取可读满 8192 字节
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(&bytes[..])).unwrap();
        let mut entry = archive.by_index(0).unwrap();
        let mut full = Vec::new();
        entry.read_to_end(&mut full).unwrap();
        assert_eq!(full.len(), 8192, "条目数据本身完好，跳过原因只能是超限");
        assert!(full.starts_with(b"["));

        // 累计预算超限：读取量入账后超过预算 → 明确错误中止
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(&bytes[..])).unwrap();
        let mut entry = archive.by_index(0).unwrap();
        let mut total_decoded = 0u64;
        let err = read_zip_entry_limited(
            "bookshelf.json",
            32,
            &mut entry,
            1024,
            &mut total_decoded,
            128,
        )
        .unwrap_err();
        assert!(
            err.to_string().contains("解压总量超过上限"),
            "跨条目累计超预算应给出明确错误: {err}"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 回修 P1] 输入包超过大小上限 → 读取前拒绝（JSON/zip 入口共用）
    #[test]
    fn test_restore_rejects_oversized_backup_file() {
        let dir = std::env::temp_dir().join("legado_restore_oversized");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("oversized.json");
        // 用 set_len 造稀疏大文件，避免真的写 512 MiB 数据
        let file = fs::File::create(&path).unwrap();
        file.set_len(MAX_BACKUP_ARCHIVE_BYTES + 1).unwrap();
        drop(file);

        let err = backup_restore(path.to_str().unwrap()).unwrap_err();
        assert!(
            err.to_string().contains("备份文件过大"),
            "超过包大小上限应明确拒绝: {err}"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 回修 P1] 既非 zip 魔数也非 JSON 对象（如带 stub 的自解压包）→ 统一文案
    #[test]
    fn test_restore_rejects_unsupported_format() {
        let dir = std::env::temp_dir().join("legado_restore_unsupported_format");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("sfx.zip");
        // 自解压包常见形态：MZ stub 开头，PK 头后移
        fs::write(&path, b"MZ\x90\x00stub-bytes-then-PK\x03\x04").unwrap();

        let err = backup_restore(path.to_str().unwrap()).unwrap_err();
        assert!(
            err.to_string().contains("不支持的备份格式"),
            "非 zip 非 JSON 应给出兜底文案: {err}"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批9 安全] 绝对路径/`..` 条目被拒绝读取，不影响正常条目
    #[test]
    fn test_zip_entry_path_guard() {
        assert!(is_safe_zip_entry_name("bookshelf.json"));
        assert!(is_safe_zip_entry_name("covers/sub/a.jpg"));
        assert!(!is_safe_zip_entry_name("../bookshelf.json"));
        assert!(!is_safe_zip_entry_name("covers/../../evil.json"));
        assert!(!is_safe_zip_entry_name("/etc/passwd"));
        assert!(!is_safe_zip_entry_name("C:/Windows/evil.json"));
        assert!(!is_safe_zip_entry_name("covers\\evil.json"));
        assert!(!is_safe_zip_entry_name(""));
    }

    /// [批9 密钥派生锚点] 原版 BackupAES 密钥 = MD5 小写 hex 前 16 个 ASCII 字节
    #[test]
    fn test_backup_aes_key_matches_upstream() {
        assert_eq!(&backup_aes_key("")[..], b"d41d8cd98f00b204");
        assert_eq!(&backup_aes_key("secret")[..], b"5ebe2294ecd0e0f0");

        // 外部工具（openssl AES-128-ECB/PKCS7）生成的密文必须能被我方解密
        let plain = decrypt_backup_payload(UPSTREAM_EMPTY_PW_SERVERS).unwrap();
        assert!(
            plain.contains("\"name\":\"网盘B\""),
            "空密码密文应可解密: {plain}"
        );
        assert!(
            decrypt_backup_payload(UPSTREAM_SECRET_PW_SERVERS).is_err(),
            "设过密码的密文不得被空密码密钥误解出"
        );
    }
}
