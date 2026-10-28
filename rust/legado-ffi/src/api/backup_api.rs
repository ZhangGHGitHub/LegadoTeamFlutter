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
//! - version=4（批16f）：新增 `directLinkUploadRule`（字符串，值为短键
//!   `directLinkUploadRule`（落库 `config:` 前缀，即 `config:directLinkUploadRule`）
//!   的原始 JSON 文本；形态为 4 字段 camelCase 对象
//!   `uploadUrl`/`downloadUrlRule`/`summary`/`compress`，对齐原版
//!   `DirectLinkUpload.ruleFileName = "directLinkUploadRule.json"`），承载直链上传规则。
//! - version=5（批27）：新增 `bookMemos`（书备忘数组，元素
//!   `{bookUrl, content, updatedAt}`，对齐原版 `bookMemo.json`，**空表也写空数组**）；
//!   `readRecords` 元素扩为 13 字段（v113 readRecord：作者主键 + 章节快照/显示元数据）。
//!
//! 兼容语义（防复发规定 9：备份格式版本化）：恢复器按字段驱动解析，
//! 全部列表字段 `#[serde(default)]`——旧备份（无 version 或 version<2）
//! 缺失的新表字段按空数组处理，仍可正常恢复；恢复时对 v1 整数布尔做归一整形。
//! `servers` 缺失（v1/v2 备份）时**不触碰库内 servers**，对齐原版
//! `Restore.kt:379-390` 仅在 `servers.json` 存在时 insert 的语义；存在时按
//! 备份中的原主键（含 `id = 0`）REPLACE 写入，不做毫秒重分配。
//! `directLinkUploadRule` 缺失（v1~v3 备份）时**不触碰**库内既有直链配置
//! （对齐原版 `Restore.kt:404-408` 仅在该文件存在时 `ACache.put` 的语义）；
//! 空/空白值同样跳过并保留旧配置（**本地加固**：上游会把空文本 `ACache.put`
//! 进去，等价清空并回落内置默认规则）；值必须是合法 JSON 对象，解析失败
//! 只 warn 跳过，不让整次恢复失败。
//!
//! # 原版 zip 备份恢复（批9，用户裁决⑥）
//!
//! 入口按**文件魔数**分流：`PK\x03\x04` / `PK\x05\x06` 走 zip 分支，其余按自有
//! 单文件 JSON 解析（[`BackupData`]）。zip 分支只做「读包 + 逐文件转 [`BackupData`]」，
//! 落库仍走同一个 [`restore_backup_in_tx`]（单实现原则，不复制第二套写库逻辑）。
//!
//! 原版 `Backup.kt` 写出的文件清单（`selectedBackupFileNames` + 固定写出项）：
//! - 书架/分组：`bookshelf.json`、`bookGroup.json`、`bookMemo.json`
//! - 标注：`bookmark.json`、`highlight.json`（`writeEmpty=true`）、`highlightRule.json`
//! - 源：`bookSource.json`、`rssSources.json`、`rssStar.json`、`sourceSub.json`
//! - 规则：`replaceRule.json`、`txtTocRule.json`、`httpTTS.json`、`keyboardAssists.json`、
//!   `dictRule.json`、`autoTask.json`、`servers.json`、`directLinkUploadRule.json`
//!   （明文 JSON 对象，**未经 `BackupAES` 加密**，证据见 `Backup.kt` 的
//!   `DirectLinkUpload.getConfig()?.let { ... writeText(GSON.toJson(it)) }`；
//!   我方映射到短键 `directLinkUploadRule`（落库 `config:` 前缀），为第三方加密产物保留
//!   空密码解密回退）
//! - 历史：`readRecord.json`、`searchHistory.json`
//! - 设置：`readConfig.json`、`shareReadConfig.json`、`themeConfig.json`、`coverRule.json`、
//!   `config.xml`、`videoConfig.xml`
//! - 可选加密：`cookies.json`、`runtimeSourceCache.json`
//! - 媒体：`covers/`（可含子目录）、`bg/`、`readRecordCovers/`（阅读记录封面缓存）
//! - 封面字体：`coverFont.ttf`（原版设置页自定义封面字体，随设置项备份）
//!
//! 加密口径（`BackupAES` + hutool 5.8 `new AES(key)`）：
//! - 密钥 = `MD5(password)` 小写十六进制串的**前 16 个 ASCII 字符**（不做 hex 解码）；
//! - 算法 = **AES-128-ECB / PKCS5Padding**（hutool `AES(byte[])` 默认 ECB）；
//! - `servers.json` **总是**先尝试加密（失败才退回明文）、恢复侧以「是否 JSON 数组」
//!   判别明文；`cookies.json` / `runtimeSourceCache.json` 仅在设置备份密码时写出，
//!   因此**文件存在即说明备份设过密码**——需用户输入备份密码
//!   （对齐原版 `Restore.kt` 在 cookies 存在且密码为空时上抛的语义）。
//!   **注**：「我方无密码输入面、直接报错零落库」是批9 当时的口径，
//!   **已被批17a 取代**（探测 [`backup_inspect`] + 密码框 + `password` 参数）；
//! - `config.xml` 内的 `webDavPassword` 同密钥加密（本实现跳过整个偏好快照，见下）。
//!
//! 未映射项（本批登记，不静默）：`readConfig.json` / `shareReadConfig.json` /
//! `themeConfig.json` / `coverRule.json` / `config.xml` / `videoConfig.xml` /
//! `coverFont.ttf` 与媒体目录 `covers/`、`bg/`、`readRecordCovers/` 只记 warn
//! 日志后跳过——我方没有等价的阅读主题配置面或封面/背景/阅读记录封面落盘目录
//! （封面按 URL 直取、不落本地 `covers/`），恢复媒体会写到无人消费的目录并引入
//! 路径安全面；书内指向 `.../covers/xxx` 的绝对封面路径按原版 remap 失败语义
//! 置空（回落到书源封面 URL）。**批27 起** `bookMemo.json` 已从「未映射」移入
//! 数据映射（[`ZIP_DATA_FILES`]），`readRecord.json` 解析全部 13 字段。
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
//!   与书源运行变量持久化面，仅记 warn（不加密码面）。→ **批17a 已解决**：
//!   两个文件（明文/密文）均恢复，见模块注释「批17a」段。
//! - **P2-10** 部分恢复对用户不可见：条目级跳过只写日志，FFI `RestoreStats`
//!   无 warnings 字段。后续立项在统计结构增加 `warnings`（需同步 FFI 契约）。
//!
//! # 批17a：备份密码恢复与探测（2026-10-26，用户裁决「探测 + 密码框」）
//!
//! 原版 `BackupAES`（`BackupAES.kt:6-8`）密钥派生：`MD5(password)` 小写十六进制串的
//! **前 16 个 ASCII 字符**（**不做 hex 解码**；空密码固定密钥 `d41d8cd98f00b204`；
//! 密码不 trim），算法 AES-128-ECB/PKCS5Padding，Base64 standard。加密文件集合：
//! `servers.json`（恒加密，空密码也用固定密钥，失败才回退明文）、`cookies.json` /
//! `runtimeSourceCache.json`（设置备份密码时写出）、`config.xml` 的 `webDavPassword`
//! （本实现仍跳过整份偏好快照）。其余数据文件与 `directLinkUploadRule.json` 明文。
//!
//! 恢复前置校验（**事务前**，保证失败零落库）：
//! - 未提供密码 + `cookies.json`/`runtimeSourceCache.json` 为密文 →
//!   [`BACKUP_PASSWORD_REQUIRED_PREFIX`]；
//! - 提供密码 + 三个候选全部解密失败 → [`BACKUP_PASSWORD_INVALID_PREFIX`]；
//! - 部分成功 → 密码正确；`servers.json` 解析失败只 warn（对齐原版 `runCatching`），
//!   `cookies.json`/`runtimeSourceCache.json` 解析失败 →
//!   [`BACKUP_ENCRYPTED_CONTENT_CORRUPT_PREFIX`]。
//!
//! 内容恢复：cookies 按原版 `CookieStore.restoreCookie` 语义（`url` 含 `|` 原样
//! upsert，否则按 `get_sub_domain` 归一后与库内同名键合并）；runtime 仅接受五前缀
//! （`v_`/`userInfo_`/`loginHeader_`/`sourceVariable_`/`infoMap_`），按精确 deadline
//! 落库、过期跳过，写完后清内存运行时变量让引擎重载。
//!
//! 批17c（审查回修 P2-1）：Cookie 改为**主事务提交后**落库，并在
//! `COOKIE_PERSIST_RW_LOCK` 内把合并结果覆盖写回 FFI 共享内存 store 与
//! `legado-js` 内存 store，随后重建共享客户端——否则进程内存仍是旧值
//! （客户端合并预载「内存值胜」），备份 Cookie 要重启才生效。
//! 该锁同时关闭「读到旧行 → 覆盖落库」的丢更新窗口（P3-5）。
//!
//! 探测（[`backup_inspect`]）只解压三个候选条目判定是否需要密码，不写任何表。
//! 空/纯空白条目按「内容损坏」处理（不弹永远失败的密码框，P3-3）。
//! **本批不做备份创建侧加密**（`backup_create` 仍写明文 JSON，另行立项）。

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
    AutoTaskRepository, BookGroup, BookGroupRepository, BookMemo, BookMemoRepository,
    BookRepository, BookSourceRepository, BookmarkRepository, CacheRepository, CookieRepository,
    DictRule, DictRuleRepository, HighlightRepository, HighlightRuleRepository, HttpTts,
    HttpTtsRepository, KeyboardAssist, KeyboardAssistRepository, ReadRecord, ReadRecordRepository,
    ReplaceRuleRepository, RssSourceRepository, RssStarRecord, RssStarRepository, RuleSubRecord,
    RuleSubRepository, SearchKeywordRepository, ServerRepository, TxtTocRuleRecord,
    TxtTocRuleRepository,
};

use crate::api::config_api::CONFIG_PREFIX;
use crate::db_state::with_database;

/// 当前备份格式版本（写入侧；恢复侧按字段兼容，不按版本分叉）
///
/// v4（批16f）：新增 `directLinkUploadRule`（直链上传规则配置）。
/// v5（批27）：新增 `bookMemos`（书备忘）；`readRecords` 元素扩为 13 字段。
pub const BACKUP_VERSION: i32 = 5;

/// 备份数据结构
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupData {
    /// 备份版本（v1=初版六类；v2=扩表批十类；v3=servers 表；v4=直链上传规则；
    /// v5=书备忘 + readRecord 13 字段，见模块注释的版本语义）
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
    /// 阅读记录列表（v113 起元素为 13 字段：作者主键 + 章节快照/显示元数据）
    #[serde(default, rename = "readRecords")]
    pub read_records: Vec<serde_json::Value>,
    /// 书备忘列表（v5 新增，对齐原版 bookMemo.json）
    ///
    /// 元素形态为 [`legado_db::BookMemo`]（`bookUrl`/`content`/`updatedAt`）。
    /// 写入侧**空表也写空数组**（对齐原版 `writeEmpty = true`）；旧备份缺该键时
    /// serde 默认空数组，恢复器据此**不触碰**库内既有备忘。
    #[serde(default, rename = "bookMemos")]
    pub book_memos: Vec<serde_json::Value>,
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
    /// 序列化时按 `skip_serializing_if` 省略，故自有 JSON 备份形状不受影响
    /// （当前版本为 v5；该键仍只在恢复原版 zip 时出现）。收到该键时按主键
    /// `id` REPLACE 写入。
    #[serde(default, skip_serializing_if = "Vec::is_empty", rename = "autoTasks")]
    pub auto_tasks: Vec<serde_json::Value>,
    /// 直链上传规则（v4 新增，对齐原版 `directLinkUploadRule.json`）
    ///
    /// 值为 caches 配置键 `config:directLinkUploadRule` 的原始 JSON 文本（4 字段
    /// camelCase 对象 `uploadUrl`/`downloadUrlRule`/`summary`/`compress`）。
    /// 配置不存在或为空串时 `None`，序列化时省略该键（保持旧备份形状）；
    /// 恢复时 `None` 或空值**不清库内既有配置**（本地加固，见模块注释）。
    ///
    /// 反序列化宽容（P2-2）：字符串按原文接收，对象/数组转紧凑文本后交
    /// [`normalize_direct_link_upload_rule`] 判定，null/数字/布尔视为无效值。
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "directLinkUploadRule",
        deserialize_with = "deserialize_direct_link_upload_rule"
    )]
    pub direct_link_upload_rule: Option<String>,
    /// Cookie 列表（批17a，**仅**由原版 zip 适配层填充）
    ///
    /// 原版 `cookies.json` 元素形态 `{url, cookie}`。`serde(skip)`：我方单文件
    /// JSON 备份既不含也不恢复该表（本批只打通原版 zip 路径），备份文件形状
    /// 与恢复口径不变。
    #[serde(skip)]
    pub cookies: Vec<CookieBackupEntry>,
    /// 书源运行变量缓存（批17a，**仅**由原版 zip 适配层填充）
    ///
    /// 原版 `runtimeSourceCache.json` 元素形态 `{key, value, deadline}`。
    /// 同 [`Self::cookies`]，`serde(skip)` 不参与自有 JSON 备份。
    #[serde(skip)]
    pub runtime_source_caches: Vec<RuntimeCacheBackupEntry>,
}

/// 原版 `cookies.json` 的单条记录
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CookieBackupEntry {
    /// Cookie 作用域键（原版 `Cookie.url`；非域名时可能含 `|`）
    pub url: String,
    /// Cookie 值（`k=v; k2=v2` 形态）
    pub cookie: String,
}

/// 原版 `runtimeSourceCache.json` 的单条记录
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeCacheBackupEntry {
    /// 缓存键（必须是五类运行时前缀之一）
    pub key: String,
    /// 缓存值（原版允许 null，我方 DB 列 NOT NULL，落库时空值归一为空串）
    pub value: Option<String>,
    /// 过期时间戳（毫秒），0 表示永不过期
    pub deadline: i64,
}

/// 宽容反序列化 `directLinkUploadRule`（字段级容错，批16f 回修 P2-2）
///
/// 该键的规范形态是 JSON 字符串（配置原文），但第三方工具可能直接把上游
/// `directLinkUploadRule.json` 的对象内联进备份 JSON。若用 `Option<String>`
/// 直接反序列化，这类备份会在开事务前整包解析失败——与契约「数组/null/
/// 语法错误只 warn 跳过」矛盾。故按字段级容错：
/// - 字符串 → 原样 `Some`（内容合法性仍由 [`normalize_direct_link_upload_rule`] 校验）；
/// - 对象/数组 → 紧凑 JSON 文本 `Some`（数组随后被判定非对象并 warn 跳过）；
/// - null / 数字 / 布尔 → `None`（不触碰库内配置）；
/// - 字段缺失 → `#[serde(default)]` 给 `None`。
fn deserialize_direct_link_upload_rule<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(
        match Option::<serde_json::Value>::deserialize(deserializer)? {
            Some(serde_json::Value::String(text)) => Some(text),
            Some(value @ (serde_json::Value::Object(_) | serde_json::Value::Array(_))) => {
                Some(value.to_string())
            }
            _ => None,
        },
    )
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
            book_memos: Vec::new(),
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
            direct_link_upload_rule: None,
            cookies: Vec::new(),
            runtime_source_caches: Vec::new(),
        }
    }
}

fn default_version() -> i32 {
    // 旧备份（无 version 字段）按 v1 解析
    1
}

/// 直链上传规则的短配置键（对齐 Dart `DirectLinkUploadRuleService.configKey`）
///
/// 原版该规则存放在 `ACache.get(cacheDir=false)` 的 `directLinkUploadRule.json`；
/// 我方落在 caches 表的 `config:` 前缀键，值同样是单个 JSON 对象文本。
const DIRECT_LINK_UPLOAD_RULE_CONFIG_KEY: &str = "directLinkUploadRule";

/// 直链上传规则在 caches 表的完整键（`config:directLinkUploadRule`）
fn direct_link_upload_rule_cache_key() -> String {
    format!("{CONFIG_PREFIX}{DIRECT_LINK_UPLOAD_RULE_CONFIG_KEY}")
}

/// 校验并归一待落库的直链上传规则文本
///
/// 口径对齐原版 `DirectLinkUpload.getConfig()`：只有 GSON 能解析成**对象**才算
/// 有效规则（数组/null/标量都不是 Rule）。空白文本与非法 JSON 返回 `None`，
/// 调用方只记 warn 并跳过——恢复其余数据不受影响。
///
/// 返回去除 BOM 与首尾空白后的原文（不重排字段、不丢弃未知键如原版
/// `expiryDate`），保证「备份 → 恢复 → 再备份」逐字节稳定。BOM 处理与 zip
/// 路径的 [`decode_zip_text`] 一致（P3-2：两条入口口径对称）。
///
/// 日志只记类型与字节长度（P2-1）：`uploadUrl` 的 options 可能含鉴权信息，
/// 完整值不得落日志，大数组也不得造成日志洪泛。
fn normalize_direct_link_upload_rule(raw: &str) -> Option<&str> {
    let text = raw.trim_start_matches('\u{feff}').trim();
    if text.is_empty() {
        log::warn!("直链上传规则为空（已跳过，库内既有配置保持不变）");
        return None;
    }
    match serde_json::from_str::<serde_json::Value>(text) {
        Ok(serde_json::Value::Object(_)) => Some(text),
        Ok(other) => {
            log::warn!(
                "直链上传规则不是 JSON 对象（类型 {}，长度 {} 字节，已跳过）",
                json_value_kind(&other),
                text.len()
            );
            None
        }
        Err(e) => {
            log::warn!("直链上传规则 JSON 解析失败（已跳过）: {e}");
            None
        }
    }
}

/// JSON 值的类型名（日志用，避免把可能含敏感串的完整值打进日志）
fn json_value_kind(value: &serde_json::Value) -> &'static str {
    match value {
        serde_json::Value::Object(_) => "object",
        serde_json::Value::Array(_) => "array",
        serde_json::Value::String(_) => "string",
        serde_json::Value::Number(_) => "number",
        serde_json::Value::Bool(_) => "bool",
        serde_json::Value::Null => "null",
    }
}

/// 解析结果的类型名（`Ok` → 值类型名；`Err` → 「非法 JSON」）
///
/// 供需要「先判定类型、再按类型出日志」的调用方复用：对象判定与日志
/// 共享同一次解析结果，避免对同一文本重复解析（P3 收口）。
fn json_parse_kind(parsed: &Result<serde_json::Value, serde_json::Error>) -> &'static str {
    match parsed {
        Ok(value) => json_value_kind(value),
        Err(_) => "非法 JSON",
    }
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
/// 收集 BackupData 全部 19 类数据（v5 覆盖面，对齐原版 `Backup.kt:279-330`
/// 中所有表已在库的类别，以及 `servers.json`/`directLinkUploadRule.json`/
/// `bookMemo.json`），统一经各 repository/配置仓储读取后模型序列化，写入
/// JSON 文件，返回备份文件路径。
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

        // 收集阅读记录（v113：13 字段全列，含作者主键/章节快照/显示元数据）
        let record_repo = ReadRecordRepository::new(conn);
        let read_records: Vec<serde_json::Value> = record_repo
            .find_all()?
            .into_iter()
            .filter_map(|r| serde_json::to_value(&r).ok())
            .collect();

        // 收集书备忘（v5：仅书架内书籍，对齐原版 `bookMemoDao.all()` 的 inner join）；
        // 空表也写出空数组（对齐原版 `writeEmpty = true`）
        let book_memos: Vec<serde_json::Value> = BookMemoRepository::new(conn)
            .list_for_bookshelf()?
            .into_iter()
            .filter_map(|m| serde_json::to_value(&m).ok())
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

        // 直链上传规则（v4：短键 `directLinkUploadRule`（落库 `config:` 前缀）
        // 的原始 JSON 文本）。
        // 不存在/空串 → None（序列化时省略该键，备份形状保持旧版兼容）
        let direct_link_upload_rule = CacheRepository::new(conn)
            .get(&direct_link_upload_rule_cache_key())?
            .filter(|raw| !raw.trim().is_empty());

        Ok(BackupData {
            version: BACKUP_VERSION,
            backup_time: now,
            books,
            bookmarks,
            replace_rules,
            book_sources,
            rss_sources,
            read_records,
            book_memos,
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
            direct_link_upload_rule,
            // 批17a：cookies / 运行时变量只走原版 zip 恢复，自有 JSON 备份不收集
            cookies: Vec::new(),
            runtime_source_caches: Vec::new(),
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

/// 从备份文件恢复（无密码旧入口）
///
/// 兼容包装：等价于 [`backup_restore_with_password`] 传 `None`
/// （空密码密钥），旧调用方行为不变。
pub fn backup_restore(path: &str) -> LegadoResult<String> {
    backup_restore_with_password(path, None)
}

/// 从备份文件恢复（批17a：支持原版 zip 备份密码）
///
/// `password` 仅对**原版 zip 备份**生效；`None`/空串等价空密码。我方单文件
/// JSON 备份忽略该参数（其恢复语义不含加密内容）。密码错误/缺失时在**事务前**
/// 返回带前缀的错误码（见模块注释「批17a」），库内零残留。
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
pub fn backup_restore_with_password(path: &str, password: Option<&str>) -> LegadoResult<String> {
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
        return restore_from_zip(&bytes, password);
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

/// 备份探测（批17a，契约 §2.11 `backupInspect`）
///
/// **只读**：zip 仅解压 [`ZIP_ENCRYPTED_FILES`] 三个候选条目（复用路径安全
/// 校验与解压限额，不全量解压），不写任何表；我方单文件 JSON 备份直接判定
/// `format=json`（其内容不加密）。
///
/// 返回 JSON：`{"format":"zip"|"json","passwordRequired":bool,
/// "passwordProtectedFiles":[string]}`。判定细则见 [`inspect_encrypted_candidate`]。
pub fn backup_inspect(path: &str) -> LegadoResult<String> {
    let metadata = fs::metadata(path)
        .map_err(|e| LegadoError::Io(std::io::Error::other(format!("读取备份文件失败: {e}"))))?;
    if metadata.len() > MAX_BACKUP_ARCHIVE_BYTES {
        return Err(LegadoError::Io(std::io::Error::other(format!(
            "备份文件过大（{} 字节，上限 {MAX_BACKUP_ARCHIVE_BYTES} 字节），已拒绝探测: {path}",
            metadata.len()
        ))));
    }
    let bytes = fs::read(path)
        .map_err(|e| LegadoError::Io(std::io::Error::other(format!("读取备份文件失败: {e}"))))?;

    if is_zip_backup(&bytes) {
        let archive = read_zip_selected(&bytes, &ZIP_ENCRYPTED_FILES)?;
        let mut protected: Vec<&str> = Vec::new();
        for name in ZIP_ENCRYPTED_FILES {
            let Some(entry) = archive.files.get(name) else {
                continue;
            };
            match inspect_encrypted_candidate(name, entry) {
                InspectVerdict::Protected => protected.push(name),
                InspectVerdict::Corrupt => {
                    log::warn!("探测到 {name} 内容损坏（不是明文数组、空密码也解不开）");
                }
                InspectVerdict::Plain => {}
            }
        }
        let result = serde_json::json!({
            "format": "zip",
            "passwordRequired": !protected.is_empty(),
            "passwordProtectedFiles": protected,
        });
        return serde_json::to_string(&result)
            .map_err(|e| LegadoError::Internal(format!("备份探测结果序列化失败: {e}")));
    }

    // 非 zip：与恢复入口同一「首字符 { 才是本应用 JSON 备份」口径
    let first_non_space = bytes
        .strip_prefix(&[0xEF, 0xBB, 0xBF])
        .unwrap_or(&bytes)
        .iter()
        .find(|b| !b.is_ascii_whitespace());
    if !matches!(first_non_space, Some(b'{')) {
        return Err(LegadoError::Internal(
            "不支持的备份格式：文件既不是原版 zip 备份，也不是本应用的 JSON 备份".to_string(),
        ));
    }
    Ok(r#"{"format":"json","passwordRequired":false,"passwordProtectedFiles":[]}"#.to_string())
}

/// 探测单个可能加密的 zip 条目是否需要密码
///
/// 判定（对齐用户裁决）：
/// - 空 / 纯空白（P3-3）：内容损坏（`Corrupt`）——空内容不可能被任何密码
///   解开，若判 `Protected` 会让 UI 弹一个永远失败的密码框；
/// - 明文 JSON **数组** → 无需密码（`Plain`）；
/// - 以 `{`/`[` 开头但解析不成数组 → 内容损坏，**不**要求密码（`Corrupt`）；
/// - 其余（密文形态）用空密码试解 + JSON 数组解析，失败 → 需密码（`Protected`）。
///
/// 注意：`servers.json` 可能用空密码密钥加密（原版恒加密，空密码也用固定
/// 密钥），空密码能解开时同样归入 `Plain`（恢复无需用户输入密码）。
fn inspect_encrypted_candidate(name: &str, bytes: &[u8]) -> InspectVerdict {
    let Ok(text) = std::str::from_utf8(bytes) else {
        log::warn!("{name} 不是 UTF-8 文本");
        return InspectVerdict::Corrupt;
    };
    let text = text.trim_start_matches('\u{feff}').trim();
    if text.is_empty() {
        log::warn!("{name} 内容为空（视为损坏，不要求密码）");
        return InspectVerdict::Corrupt;
    }
    if text.starts_with('[') {
        return match serde_json::from_str::<Vec<serde_json::Value>>(text) {
            Ok(_) => InspectVerdict::Plain,
            Err(_) => InspectVerdict::Corrupt,
        };
    }
    if text.starts_with('{') {
        return InspectVerdict::Corrupt;
    }
    match BackupCipher::new(None).decrypt_text(text) {
        Ok(plain) => match serde_json::from_str::<Vec<serde_json::Value>>(plain.trim()) {
            Ok(_) => InspectVerdict::Plain,
            Err(_) => InspectVerdict::Corrupt,
        },
        Err(_) => InspectVerdict::Protected,
    }
}

/// 探测判定结果
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InspectVerdict {
    /// 明文或以空密码可解密（无需用户输入密码）
    Plain,
    /// 内容损坏（不要求密码；恢复时按类别跳过或报错）
    Corrupt,
    /// 需要备份密码
    Protected,
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
const ZIP_DATA_FILES: [&str; 22] = [
    "bookshelf.json",
    "bookmark.json",
    "highlight.json",
    "highlightRule.json",
    "bookGroup.json",
    // 书备忘（批27：从「无落库面」移入数据映射；原版 `writeEmpty = true`）
    "bookMemo.json",
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
    // 直链上传规则（批16f 映射：明文 JSON 对象 → 短键 directLinkUploadRule，
    // 落库 config: 前缀）
    "directLinkUploadRule.json",
    "cookies.json",
    "runtimeSourceCache.json",
];

/// 原版 zip 内可能加密的三个候选文件（批17a：探测与恢复前置校验共用）
const ZIP_ENCRYPTED_FILES: [&str; 3] = ["servers.json", "cookies.json", "runtimeSourceCache.json"];

/// 原版 zip 内存在、但本实现无对应落库面的文件（只报告不落库，登记见模块注释）
const ZIP_UNMAPPED_FILES: [&str; 7] = [
    "readConfig.json",
    "shareReadConfig.json",
    "themeConfig.json",
    "coverRule.json",
    "config.xml",
    "videoConfig.xml",
    // 封面字体（批27：原版设置页自定义封面字体，我方无封面渲染配置面）
    "coverFont.ttf",
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
    read_zip_selected(bytes, &ZIP_DATA_FILES)
}

/// 读取 zip 备份中**指定**条目（路径安全校验与解压限额与恢复入口一致）
///
/// 批17a：探测入口只传 [`ZIP_ENCRYPTED_FILES`]，避免为了判断「是否要密码」
/// 把整个备份的全部数据文件解压一遍。
fn read_zip_selected(bytes: &[u8], wanted: &[&str]) -> LegadoResult<ZipBackupArchive> {
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
        if !wanted.contains(&name.as_str()) {
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
///
/// 批17a：`password` 仅用于解密 `servers.json`/`cookies.json`/
/// `runtimeSourceCache.json`；前置校验（[`precheck_zip_encrypted`]）在开事务**之前**
/// 完成，密码缺失/错误/加密内容损坏时库内零残留。
fn restore_from_zip(bytes: &[u8], password: Option<&str>) -> LegadoResult<String> {
    let archive = read_zip_backup(bytes)?;
    let cipher = BackupCipher::new(password);
    let credentials = precheck_zip_encrypted(&archive, &cipher)?;
    // 返回值仅供回归测试断言告警，恢复流程无需消费
    let _ = report_unmapped_zip_entries(&archive);
    let (backup, replace_policy) = backup_data_from_zip(&archive, &cipher, credentials);
    let runtime_restored = !backup.runtime_source_caches.is_empty();
    let stats = restore_backup_data(&backup, replace_policy)?;
    // 批17c P2-1：Cookie 在**主事务提交后**落库并同步进程内存
    //（内存同步必须看到已提交行；且须在 `COOKIE_PERSIST_RW_LOCK` 保护域内
    // 完成「读-合并-写」，与 jar/JS 合并写串行）
    apply_restored_cookies(&backup.cookies);
    // 对齐原版 `Restore.kt:393-397`：写入运行时缓存后 `AppCacheManager.clearSourceVariables()`
    // 让引擎内存变量从 DB 重载（否则进程内旧变量继续生效到重启）
    if runtime_restored {
        if let Err(e) = legado_js::host_api::variable_store::clear_source_variables() {
            log::warn!("恢复书源运行变量后清理内存变量失败（重启后生效）: {e}");
        }
    }
    Ok(stats)
}

/// 恢复受影响 Cookie 的键集（库内域键 → JS 内存键列表）
///
/// 返回 `Vec<(库内域键, JS 内存键列表)>`：
/// - **库内域键**：`|` 原始作用域键原样，其余按 `get_sub_domain` 归一到 ETLD+1
///   （与 [`restored_cookie_domain_key`] 同口径）；同一域键只出现一次；
/// - **JS 内存键**：`legado-js` 的键归一在默认档是「trim 原串」、quickjs 档
///   才是 ETLD+1——两侧键空间不同，必须各按各的口径写（quickjs 档两者相等；
///   默认档 DB 域键与 JS 原始串键不同名）。
///
/// **P3-3（批17d）**：同一库内域键下的**多个 URL 必须逐个收集** JS 键。默认档
/// 键空间是原始 URL 串，同域不同 URL 会得到不同键；旧实现按库内域键去重时
/// 只记首个键，其余 URL 的内存条目保持旧值（重启前读侧仍命中旧串）。quickjs
/// 档两者归一后相等，多 URL 自然收敛为同一键（去重后只写一次）。
fn affected_cookie_domains(entries: &[CookieBackupEntry]) -> Vec<(String, Vec<String>)> {
    let mut affected: Vec<(String, Vec<String>)> = Vec::new();
    for entry in entries {
        let Some(key) = restored_cookie_domain_key(entry) else {
            continue;
        };
        let js_key = legado_js::host_api::cookie_store::normalized_cookie_key(&entry.url);
        match affected.iter_mut().find(|(domain, _)| *domain == key) {
            Some((_, js_keys)) => {
                if !js_keys.contains(&js_key) {
                    js_keys.push(js_key);
                }
            }
            None => affected.push((key, vec![js_key])),
        }
    }
    affected
}

/// 恢复 Cookie 到库 + 同步进程内存 + 重建客户端（批17c P2-1，提交后执行）
///
/// 语义（逐条对齐原版 `Restore.kt:391-399` / `CookieStore.restoreCookie`）：
/// - `url` 含 `|`：原版直接 `cookieDao.insert(cookie)`（原样主键 upsert，
///   不做域名归一、不合并）；
/// - 其余：按 `get_sub_domain` 归一，与库内既有 Cookie **同名键合并**
///   （备份新值胜）后 upsert；url/cookie 为空直接跳过（原版
///   `TextUtils.isEmpty` 早退）。
///
/// **为什么在事务外**：① 事务内已持连接池连接，再取
/// `COOKIE_PERSIST_RW_LOCK`（C）与 jar/JS 写方的 C→P 锁序相反；② 内存
/// 同步必须读**已提交**行。Cookie 写入本身逐条 autocommit，条目级失败只
/// warn（与恢复其他表的条目级容错口径一致）。
///
/// **进程内存同步（P2-1 红态修复）**：只写 DB 时进程内存 CookieStore 仍是
/// 恢复前的旧值，客户端重建的合并预载又是「内存值胜」→ 备份值要重启才生效。
/// 故在 C 锁内：写库 → 读回每个受影响域的最终合并行 → 覆盖式写回 FFI 共享
/// store 与 `legado-js` 内存 store（同一 C 保护域成对更新，关闭「读到旧行 →
/// 覆盖内存/落库」的丢更新窗口，P3-5）。最后重建共享客户端使其重新预载
///（内存已是新值，合并预载不会回退）。
///
/// **并发捕获窗口（批17d P2 红态修复，锁序 D→C→P→S/G）**：jar 写回路径
/// （`legado-net::client::save_cookies_from_response`）是「持 D → 写内存并
/// 捕获整域串（释放 S）→ 持 D 取 C 落库」。旧实现恢复侧只取 C：jar 在
/// 「已捕获、未落库」时等 C，恢复读库看不到刚捕获的新值 → 合并结果覆盖
/// 内存后 jar 再以旧视图「incoming 胜」落库，**把刚恢复的备份值回滚**，且
/// 内存与 DB 分叉、jar 新键在内存丢失（红态用例
/// `test_restore_cookies_concurrent_jar_write_no_rollback`）。
///
/// 修复：恢复侧按 [`affected_cookie_domains`] 的键集（库内域键 ∪ 全部 JS
/// 内存键）**排序去重后先取 D**（默认档再取
/// [`legado_js::host_api::cookie_store::lock_local_domain_writes`]——默认档 JS
/// 写侧用本地注册表），再在 D 内取 C，形成 D→C→P→S/G 与 JS 写侧
/// （D→C）、jar 写侧（D→C）同序，无 ABBA；jar/JS 的「捕获 + 落库」与恢复的
/// 「读-合并-写-回读-覆盖内存」整体互斥。释放 D/C 后再
/// [`crate::http_state::reset_shared_client`]，避免持按域锁跨客户端重建。
///
/// 同域**同键**冲突（恢复与 jar 都写同名键）按「后写胜」：二者被 D 串行后，
/// 先完成者写入、后完成者在最新行上合并——jar 先行则备份值胜（恢复在后），
/// 恢复先行则 jar 的 Set-Cookie 胜（真实后到的会话值不得被历史备份覆盖）。
fn apply_restored_cookies(entries: &[CookieBackupEntry]) {
    if entries.is_empty() {
        return;
    }
    let affected = affected_cookie_domains(entries);
    if affected.is_empty() {
        return;
    }

    // D（最外层，按域写通道）：键集 = 库内域键 ∪ 全部 JS 内存键。
    // 排序去重保证每个键只取一次（Mutex 不可重入）且固定顺序（无环）。
    let mut domain_keys: Vec<String> = Vec::with_capacity(affected.len() * 2);
    for (domain, js_keys) in &affected {
        domain_keys.push(domain.clone());
        domain_keys.extend(js_keys.iter().cloned());
    }
    domain_keys.sort();
    domain_keys.dedup();
    let d_guards: Vec<_> = domain_keys
        .iter()
        .map(|key| legado_net::cookie_store::domain_write_lock(key))
        .collect();
    // 默认档：JS 写侧用本地注册表（quickjs 档 JS 侧复用 net 注册表，上方
    // net D 已覆盖，该函数不存在于此档）
    #[cfg(not(feature = "quickjs"))]
    let local_guards = legado_js::host_api::cookie_store::lock_local_domain_writes(&domain_keys);

    let (rows, _js_rows) = crate::http_state::with_cookie_persist_lock(|| {
        let affected_for_read = affected.clone();
        let result = with_database(move |db| {
            let repo = CookieRepository::new(db.connection());
            for entry in entries {
                let Some(key) = restored_cookie_domain_key(entry) else {
                    continue;
                };
                if entry.url.contains('|') {
                    if let Err(e) = repo.upsert(&key, &entry.cookie) {
                        log::warn!("恢复 Cookie 失败（已跳过）: {key} - {e}");
                    }
                    continue;
                }
                let existing = match repo.get_by_tag(&key) {
                    Ok(value) => value.unwrap_or_default(),
                    Err(e) => {
                        log::warn!("读取本机 Cookie 失败（按备份值直接写入）: {key} - {e}");
                        String::new()
                    }
                };
                let merged = merge_cookie_values(&existing, &entry.cookie);
                if let Err(e) = repo.upsert(&key, &merged) {
                    log::warn!("恢复 Cookie 失败（已跳过）: {key} - {e}");
                }
            }
            // 合并完成后读回最终行（同一 C 保护域内，无并发写方插入）
            let mut rows: Vec<(String, String)> = Vec::with_capacity(affected_for_read.len());
            let mut js_rows: Vec<(String, String)> = Vec::new();
            for (key, js_keys) in &affected_for_read {
                match repo.get_by_tag(key) {
                    Ok(Some(value)) => {
                        rows.push((key.clone(), value.clone()));
                        // 同一域下的每个 JS 键都覆盖成同一份最终合并串（P3-3）
                        for js_key in js_keys {
                            js_rows.push((js_key.clone(), value.clone()));
                        }
                    }
                    Ok(None) => {}
                    Err(e) => log::warn!("读取恢复后 Cookie 失败（跳过内存同步）: {key} - {e}"),
                }
            }
            Ok((rows, js_rows))
        });
        match result {
            Ok(pair) => {
                // 内存覆盖写与 DB 写同处 C 保护域：两边看到同一份合并结果
                crate::http_state::overwrite_shared_cookie_rows(&pair.0);
                legado_js::host_api::cookie_store::overwrite_cookies(&pair.1);
                pair
            }
            Err(e) => {
                log::warn!("恢复 Cookie 写入失败（本次未生效）: {e}");
                (Vec::new(), Vec::new())
            }
        }
    });

    // 先释放按域写通道 / 合并写串行锁，再做客户端重建（不持按域锁跨
    // 客户端槽位写锁）
    drop(d_guards);
    #[cfg(not(feature = "quickjs"))]
    drop(local_guards);

    if rows.is_empty() {
        return;
    }
    // 重建客户端：FFI 主客户端与 JS 桥四池共用共享 store（已写入新值），
    // rebuild 的合并预载以内存为准，不会把旧 DB 视图盖回来
    crate::http_state::reset_shared_client();
    #[cfg(feature = "quickjs")]
    legado_js::host_api::network::reset_shared_client_pools();
}

/// 备份 Cookie 条目的落库键（`url` 含 `|` 原样，否则 ETLD+1 归一）
///
/// 返回 `None` 表示该条目按原版 `TextUtils.isEmpty` 早退语义跳过
/// （`url` 空白；非 `|` 形态且 `cookie` 为空）。
fn restored_cookie_domain_key(entry: &CookieBackupEntry) -> Option<String> {
    if entry.url.trim().is_empty() {
        return None;
    }
    if entry.url.contains('|') {
        return Some(entry.url.clone());
    }
    if entry.cookie.is_empty() {
        return None;
    }
    Some(crate::api::net_api::get_sub_domain(&entry.url))
}

/// 加密内容前置校验结果（批17a）
///
/// 各 `Option` 语义：`None` = 文件缺失或解析失败（已 warn 跳过）；
/// `Some(空列表)` = 文件存在且解析成功但内容为空。
#[derive(Debug, Default)]
struct ZipCredentials {
    /// `servers.json` 明文实体数组（明文或解密成功）
    servers: Option<Vec<serde_json::Value>>,
    /// `cookies.json` 解析结果
    cookies: Option<Vec<CookieBackupEntry>>,
    /// `runtimeSourceCache.json` 解析结果
    runtime: Option<Vec<RuntimeCacheBackupEntry>>,
}

/// 加密内容前置校验（批17a，事务前执行，失败即零落库）
///
/// 对 [`ZIP_ENCRYPTED_FILES`] 三个候选逐个判定：
/// - 明文 JSON 数组 → 直接解析（`servers` 解析失败只 warn，对齐原版 `runCatching`）；
/// - 以 `{`/`[` 开头但解析不成数组 → 损坏；`servers` 只 warn，cookies/runtime
///   返回 [`BACKUP_ENCRYPTED_CONTENT_CORRUPT_PREFIX`]；
/// - 密文 → `cookies`/`runtime` 在未提供密码时返回
///   [`BACKUP_PASSWORD_REQUIRED_PREFIX`]；提供密码时解密，全部解密失败返回
///   [`BACKUP_PASSWORD_INVALID_PREFIX`]（部分成功视为密码正确，失败条目 warn 跳过）。
///
/// 加密文件只按**密文**判定：以 `[` 开头的文本一律按明文数组处理（原版历史/
/// 第三方产物形态），不会尝试解密，避免把合法明文误判为密文。
fn precheck_zip_encrypted(
    archive: &ZipBackupArchive,
    cipher: &BackupCipher,
) -> LegadoResult<ZipCredentials> {
    let password_provided = cipher.password_provided();
    let mut credentials = ZipCredentials::default();
    let mut decrypt_attempted = 0usize;
    let mut decrypt_succeeded = 0usize;

    for name in ZIP_ENCRYPTED_FILES {
        let Some(bytes) = archive.files.get(name) else {
            continue;
        };
        let text = match decode_zip_text(name, bytes) {
            Some(text) if !text.is_empty() => text,
            other => {
                let reason = if other.is_some() {
                    "内容为空"
                } else {
                    "不是 UTF-8 文本"
                };
                if name == "servers.json" {
                    log::warn!("{name} {reason}（已跳过服务器配置）");
                    continue;
                }
                return Err(encrypted_content_corrupt_error(name, reason));
            }
        };

        // 明文数组（原版历史/第三方产物）：直接解析，不尝试解密
        if text.starts_with('[') {
            match name {
                "servers.json" => match serde_json::from_str::<Vec<serde_json::Value>>(text) {
                    Ok(list) => credentials.servers = Some(list),
                    Err(e) => log::warn!("servers.json 解析失败（已跳过）: {e}"),
                },
                "cookies.json" => credentials.cookies = Some(parse_cookie_backup(name, text)?),
                _ => credentials.runtime = Some(parse_runtime_cache_backup(name, text)?),
            }
            continue;
        }

        // 以 `{` 开头（或 `[` 开头但上面解析失败的路径不会到这里）说明不是
        // 「可解密的 Base64 密文」，按损坏处理
        if text.starts_with('{') {
            if name == "servers.json" {
                log::warn!("servers.json 是 JSON 对象而非数组（已跳过服务器配置）");
                continue;
            }
            return Err(encrypted_content_corrupt_error(
                name,
                "内容是 JSON 对象而不是数组",
            ));
        }

        // 密文：cookies/runtime 未提供密码 ⇒ 明确要求密码（原版同语义）
        if !password_provided {
            if name == "servers.json" {
                // servers 允许空密码密钥；用空密码尝试一次，失败只 warn 跳过
                decrypt_attempted += 1;
                match cipher.decrypt_text(text) {
                    Ok(plain) => {
                        decrypt_succeeded += 1;
                        match serde_json::from_str::<Vec<serde_json::Value>>(plain.trim()) {
                            Ok(list) => credentials.servers = Some(list),
                            Err(e) => log::warn!("servers.json 解密后解析失败（已跳过）: {e}"),
                        }
                    }
                    Err(e) => {
                        log::warn!(
                            "servers.json 无法用空密码解密（原版备份设置过备份密码）；\
                             服务器配置未恢复（已跳过）: {e}"
                        );
                    }
                }
                continue;
            }
            return Err(backup_password_required_error(name));
        }

        decrypt_attempted += 1;
        let plain = match cipher.decrypt_text(text) {
            Ok(plain) => {
                decrypt_succeeded += 1;
                plain
            }
            Err(e) => {
                log::warn!("{name} 用提供的备份密码解密失败（已跳过）: {e}");
                continue;
            }
        };
        match name {
            "servers.json" => match serde_json::from_str::<Vec<serde_json::Value>>(plain.trim()) {
                Ok(list) => credentials.servers = Some(list),
                Err(e) => {
                    log::warn!("servers.json 解密成功但解析失败（密码正确，服务器配置已跳过）: {e}")
                }
            },
            "cookies.json" => credentials.cookies = Some(parse_cookie_backup(name, plain.trim())?),
            _ => credentials.runtime = Some(parse_runtime_cache_backup(name, plain.trim())?),
        }
    }

    // 提供密码时：有加密候选但一个都没解开 ⇒ 密码错误（零落库）
    if password_provided && decrypt_attempted > 0 && decrypt_succeeded == 0 {
        return Err(backup_password_invalid_error());
    }
    Ok(credentials)
}

/// 错误码前缀（Dart 按消息前缀识别；后端统一以 `LegadoError::Internal` 返回文本）
pub const BACKUP_PASSWORD_REQUIRED_PREFIX: &str = "BACKUP_PASSWORD_REQUIRED";
/// 备份密码错误
pub const BACKUP_PASSWORD_INVALID_PREFIX: &str = "BACKUP_PASSWORD_INVALID";
/// 加密内容解密成功但结构损坏
pub const BACKUP_ENCRYPTED_CONTENT_CORRUPT_PREFIX: &str = "BACKUP_ENCRYPTED_CONTENT_CORRUPT";

fn backup_password_required_error(name: &str) -> LegadoError {
    let label = match name {
        "cookies.json" => "登录信息",
        "runtimeSourceCache.json" => "书源运行变量",
        _ => "加密内容",
    };
    LegadoError::Internal(format!(
        "{BACKUP_PASSWORD_REQUIRED_PREFIX}: 该备份包含原版加密的{label}（{name}），\
         说明备份时设置过备份密码；请输入备份密码后重试"
    ))
}

fn backup_password_invalid_error() -> LegadoError {
    LegadoError::Internal(format!(
        "{BACKUP_PASSWORD_INVALID_PREFIX}: 备份密码错误——无法用该密码解开备份中的加密内容，\
         请确认密码后重试"
    ))
}

fn encrypted_content_corrupt_error(name: &str, reason: &str) -> LegadoError {
    LegadoError::Internal(format!(
        "{BACKUP_ENCRYPTED_CONTENT_CORRUPT_PREFIX}: 备份中的 {name} 内容损坏（{reason}），\
         无法恢复该部分数据"
    ))
}

/// 解析原版 `cookies.json`（`[{url, cookie}]`）
///
/// 文件级结构非法 → [`BACKUP_ENCRYPTED_CONTENT_CORRUPT_PREFIX`]（事务前中止）；
/// 条目级非法（非对象/url 非字符串或空白/cookie 非字符串）只 warn 跳过——
/// 原版整份抛错，本实现按「单条坏数据不阻断整次恢复」口径收窄，已登记。
fn parse_cookie_backup(name: &str, text: &str) -> LegadoResult<Vec<CookieBackupEntry>> {
    let values: Vec<serde_json::Value> = serde_json::from_str(text)
        .map_err(|e| encrypted_content_corrupt_error(name, &format!("不是 JSON 数组: {e}")))?;
    let mut entries = Vec::with_capacity(values.len());
    for value in values {
        let Some(map) = value.as_object() else {
            log::warn!("{name} 条目不是 JSON 对象（已跳过）");
            continue;
        };
        let url = map.get("url").and_then(|v| v.as_str()).unwrap_or("");
        let cookie = map.get("cookie").and_then(|v| v.as_str());
        if url.trim().is_empty() || cookie.is_none() {
            log::warn!("{name} 条目缺少有效 url/cookie（已跳过）");
            continue;
        }
        entries.push(CookieBackupEntry {
            url: url.to_string(),
            cookie: cookie.unwrap_or_default().to_string(),
        });
    }
    Ok(entries)
}

/// 解析原版 `runtimeSourceCache.json`（`[{key, value, deadline}]`）
///
/// 键必须是五类运行时前缀（对齐原版 `Restore.isRuntimeSourceCacheKey`）；`
/// value` 允许 null（DB 列 NOT NULL，恢复时归一为空串）；`deadline` 必须是
/// 非负整数。文件级结构非法 → 损坏错误；条目级非法只 warn 跳过。同键出现
/// 多次时后者胜出（对齐原版 `latestByKey[key] = ...`）。
fn parse_runtime_cache_backup(
    name: &str,
    text: &str,
) -> LegadoResult<Vec<RuntimeCacheBackupEntry>> {
    let values: Vec<serde_json::Value> = serde_json::from_str(text)
        .map_err(|e| encrypted_content_corrupt_error(name, &format!("不是 JSON 数组: {e}")))?;
    let mut entries: Vec<RuntimeCacheBackupEntry> = Vec::with_capacity(values.len());
    let mut index_by_key: HashMap<String, usize> = HashMap::new();
    for value in values {
        let Some(map) = value.as_object() else {
            log::warn!("{name} 条目不是 JSON 对象（已跳过）");
            continue;
        };
        let key = map.get("key").and_then(|v| v.as_str()).unwrap_or("");
        if !is_runtime_source_cache_key(key) {
            log::warn!("{name} 条目键不在五类运行时前缀内（已跳过）: {key}");
            continue;
        }
        let value = match map.get("value") {
            None => {
                log::warn!("{name} 条目缺少 value（已跳过）: {key}");
                continue;
            }
            Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::String(text)) => Some(text.clone()),
            Some(_) => {
                log::warn!("{name} 条目 value 不是字符串/null（已跳过）: {key}");
                continue;
            }
        };
        let Some(deadline) = map.get("deadline").and_then(|v| v.as_i64()) else {
            log::warn!("{name} 条目 deadline 不是整数（已跳过）: {key}");
            continue;
        };
        if deadline < 0 {
            log::warn!("{name} 条目 deadline 为负（已跳过）: {key}");
            continue;
        }
        let entry = RuntimeCacheBackupEntry {
            key: key.to_string(),
            value,
            deadline,
        };
        match index_by_key.get(key) {
            Some(&index) => entries[index] = entry,
            None => {
                index_by_key.insert(key.to_string(), entries.len());
                entries.push(entry);
            }
        }
    }
    Ok(entries)
}

/// 五类书源运行时缓存前缀（对齐原版 `Restore.kt:94-106`）
fn is_runtime_source_cache_key(key: &str) -> bool {
    [
        "v_",
        "userInfo_",
        "loginHeader_",
        "sourceVariable_",
        "infoMap_",
    ]
    .iter()
    .any(|prefix| key.starts_with(prefix) && key.len() > prefix.len())
}

/// 合并两段 Cookie 字符串（原版 `CookieStore.mergeCookieValues` 语义）
///
/// 逐行对齐原版 `app/src/main/java/io/legado/app/help/http/CookieStore.kt:118-136`
/// （`mergeCookieValues` + `cookieToMap` + `mapToCookie`）：
/// - `existing` 为空 → **原样返回** `incoming`（不归一、不重排）；
/// - 同名键**位置保留、值覆盖**（Kotlin `LinkedHashMap.putAll` 语义）→
///   输出保持**首次出现顺序**（旧实现按键名排序是本地偏离，P3-2 已对齐）；
/// - 键值各 `trim` 一次后**空白值丢弃**（上游 `value.isNotBlank()`），但字面量
///   `"null"` 保留（上游特意豁免：`value.trim() == "null"` 视为有效值）；
/// - 段内无 `=` → 跳过（上游 `pairs.size <= 1`）。
///
/// **本地加固**：键为空的段丢弃（上游会把空键放进 map，`mapToCookie` 产出
/// `=value` 畸形段）。其余口径与上游一致，不再有排序偏离。
fn merge_cookie_values(existing: &str, incoming: &str) -> String {
    if existing.is_empty() {
        return incoming.to_string();
    }
    let mut pairs: Vec<(String, String)> = Vec::new();
    for pair in existing.split(';').chain(incoming.split(';')) {
        let pair = pair.trim();
        let Some((key, value)) = pair.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty() {
            continue; // 本地加固：空键丢弃（上游会产出 `=value` 畸形段）
        }
        let value = value.trim();
        if value.is_empty() {
            // 上游 isNotBlank 判定：空白值不是合法 cookie 值（"null" 非空白，保留）
            continue;
        }
        match pairs
            .iter_mut()
            .find(|(existing_key, _)| existing_key == key)
        {
            Some(slot) => slot.1 = value.to_string(),
            None => pairs.push((key.to_string(), value.to_string())),
        }
    }
    pairs
        .iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("; ")
}

/// 当前时间戳（毫秒）
fn current_time_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
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
        if let Some(prefix) = ["covers/", "bg/", "readRecordCovers/"]
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
fn backup_data_from_zip(
    archive: &ZipBackupArchive,
    cipher: &BackupCipher,
    credentials: ZipCredentials,
) -> (BackupData, ReplaceTablePolicy) {
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
    // 书备忘（批27，对齐原版 bookMemo.json；恢复时按 restoredBookUrls 过滤）
    data.book_memos = zip_json_array(archive, "bookMemo.json").unwrap_or_default();
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
    data.servers = credentials.servers.unwrap_or_default();
    data.cookies = credentials.cookies.unwrap_or_default();
    data.runtime_source_caches = credentials.runtime.unwrap_or_default();
    data.direct_link_upload_rule = zip_direct_link_upload_rule(archive, cipher);
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
/// androidId，走「同键（deviceId, bookName, author）较新者胜」。我方为单设备模型
/// （Rust 侧 deviceId 固定空串），若不归一：原设备 ID 会被当作他机记录直接插入，
/// 与本机同书同作者记录并存两行（同书同作者会被重复计时）。
/// 归一一律置空串后，恢复走 [`ReadRecordRepository::upsert_restore`] 的
/// 「同键较新者胜」路径（v113 起同名不同作者本就分行，不再合并作者），
/// 对齐原版「同设备比较」意图。
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

/// 解析 `directLinkUploadRule.json`：原版以**明文** GSON 对象写出，直接取用
///
/// 证据（Android 原版与参考版一致）：`Backup.kt` 中该文件为
/// `DirectLinkUpload.getConfig()?.let { ...writeText(GSON.toJson(it)) }`，
/// **不经过** `BackupAES`（同文件内 `servers.json` / `cookies.json` 才调用 `aes`）。
/// 为兼容第三方工具或历史加密产物，明文不是 JSON 对象时按**当前备份密码**
/// （批17a：无密码时为原版空密码密钥）尝试解密一次（复用 [`BackupCipher`]
/// 同一条解密流水线，不另写实现）。
///
/// 文件缺失 / 空文件 / 明文非对象 / 解密失败 / 仍非 JSON 对象 → `None`（warn 跳过，
/// 不清库内既有配置，对齐原版 `runCatching` 记日志后继续）。
fn zip_direct_link_upload_rule(
    archive: &ZipBackupArchive,
    cipher: &BackupCipher,
) -> Option<String> {
    const NAME: &str = "directLinkUploadRule.json";
    let bytes = archive.files.get(NAME)?;
    let text = decode_zip_text(NAME, bytes)?;
    if text.is_empty() {
        log::warn!("{NAME} 为空文件（已跳过，库内既有直链规则保持不变）");
        return None;
    }
    // P3 收口：对象判定与「非对象类型」日志共用同一次解析结果，
    // 避免同一文本被 serde_json 解析两遍
    let parsed = serde_json::from_str::<serde_json::Value>(text);
    if matches!(&parsed, Ok(serde_json::Value::Object(_))) {
        return Some(text.to_string());
    }
    // 明文但不是 JSON 对象：先做低成本 base64 形态检查（P3-6）——非 base64 形态
    // 直接判定「明文非对象」，避免把大段明文送去完整解码 + AES 解密产生无谓分配
    if !looks_like_base64(text) {
        log::warn!(
            "{NAME} 是明文但不是 JSON 对象（类型 {}，长度 {} 字节，已跳过，\
             库内既有直链规则保持不变）",
            json_parse_kind(&parsed),
            text.len()
        );
        return None;
    }
    // base64 形态：按当前备份密码尝试解密（第三方加密产物）
    match cipher.decrypt_text(text) {
        Ok(plain) => {
            let plain = plain.trim();
            let parsed = serde_json::from_str::<serde_json::Value>(plain);
            match parsed {
                Ok(serde_json::Value::Object(_)) => Some(plain.to_string()),
                other => {
                    log::warn!(
                        "{NAME} 解密成功但不是 JSON 对象（类型 {}，已跳过，\
                         库内既有直链规则保持不变）",
                        json_parse_kind(&other)
                    );
                    None
                }
            }
        }
        Err(e) => {
            log::warn!("{NAME} 按备份密码解密失败（已跳过，库内既有直链规则保持不变）: {e}");
            None
        }
    }
}

/// 文本是否具备 Base64 形态（仅字符集与长度检查，**不做解码**）
///
/// 用于解密前的低成本分流：原版该文件本为明文，只有第三方加密产物才需要走
/// 解密；非 base64 形态的输入直接判定「明文非对象」，避免大输入触发完整解码
/// 与 AES 解密的分配。
///
/// **仅用于日志分流，不作为可解密性判据**：字符集与长度合规的文本仍可能
/// 解码/解密失败，最终结果一律由 [`BackupCipher::decrypt_text`] 的返回值为准。
fn looks_like_base64(text: &str) -> bool {
    let bytes = text.as_bytes();
    if bytes.is_empty() || !bytes.len().is_multiple_of(4) {
        return false;
    }
    bytes
        .iter()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'='))
}

/// 原版 `BackupAES` 密钥派生：`MD5(password)` 小写十六进制串的前 16 个 ASCII 字节
///
/// 注意**不是** hex 解码：Kotlin 侧为 `MD5Utils.md5Encode(password).encodeToByteArray(0, 16)`，
/// 取的是十六进制字符串前 16 个字符的 UTF-8 字节。密码**不 trim**（原版
/// `password.orEmpty()` 原样参与 MD5）。
fn backup_aes_key(password: &str) -> [u8; 16] {
    let digest = format!("{:x}", md5::compute(password.as_bytes()));
    let mut key = [0u8; 16];
    key.copy_from_slice(&digest.as_bytes()[..16]);
    key
}

/// 原版备份加解密器（批17a）
///
/// 算法固定：密钥 = [`backup_aes_key`]，AES-128-ECB/PKCS5Padding，Base64 standard。
/// `None`/空串 → 空密码密钥（`d41d8cd98f00b204`）。
struct BackupCipher {
    key: [u8; 16],
    /// 是否由调用方显式提供了非空密码（决定「缺密码」判定与错误码）
    password_provided: bool,
}

impl BackupCipher {
    /// 按可选密码构造；`None`/空串等价空密码
    fn new(password: Option<&str>) -> Self {
        let password = password.unwrap_or("");
        Self {
            key: backup_aes_key(password),
            password_provided: !password.is_empty(),
        }
    }

    /// 调用方是否提供了非空密码
    fn password_provided(&self) -> bool {
        self.password_provided
    }

    /// 解密原版备份密文（Base64 → AES-128-ECB/PKCS5 → UTF-8）
    fn decrypt_text(&self, text: &str) -> LegadoResult<String> {
        let ciphertext = base64::engine::general_purpose::STANDARD
            .decode(text.trim())
            .map_err(|e| LegadoError::Internal(format!("备份密文 base64 解码失败: {e}")))?;
        let plain = AesCrypto::decrypt_ecb(&self.key, &ciphertext)?;
        String::from_utf8(plain)
            .map_err(|e| LegadoError::Internal(format!("备份密文解密结果不是 UTF-8: {e}")))
    }
}

/// 按空密码密钥解密（仅供单测锚定历史空密码向量）
#[cfg(test)]
fn decrypt_backup_payload(text: &str) -> LegadoResult<String> {
    BackupCipher::new(None).decrypt_text(text)
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
    //
    // [批27] `restoredBookUrls`：本次备份 `books` 段中成功解析的书籍 URL 集合，
    // 书备忘恢复按该集合过滤（对齐原版 `Restore.kt:304-306`）。
    let book_repo = BookRepository::new(conn);
    let mut restored_book_urls: std::collections::HashSet<String> =
        std::collections::HashSet::new();
    for value in &backup.books {
        if let Ok(book) = serde_json::from_value::<Book>(value.clone()) {
            restored_book_urls.insert(book.book_url.clone());
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

    // 恢复书备忘（v5，对齐原版 `Restore.kt:304-306`）：
    // 仅写「bookUrl ∈ restoredBookUrls + 库内存在该书 + updatedAt 更新者胜」的条目；
    // 备份缺该键/空数组时不触碰库内既有备忘。
    let memo_repo = BookMemoRepository::new(conn);
    for value in &backup.book_memos {
        match serde_json::from_value::<BookMemo>(value.clone()) {
            Ok(memo) => {
                if !restored_book_urls.contains(&memo.book_url) {
                    continue;
                }
                match memo_repo.restore_one(&memo) {
                    Ok(_) => {}
                    Err(e) => log::warn!("恢复书备忘失败（已跳过）: {} - {e}", memo.book_url),
                }
            }
            Err(e) => log::warn!("恢复书备忘解析失败（已跳过）: {e}"),
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
            match source_repo.insert_with_check_state(&source) {
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

    // 恢复阅读记录（v113：13 字段全列 + 原版 `mergeRestoredReadRecord` 语义：
    // 物理主键 (deviceId, bookName, author) 相同才合并，较新者胜；同名不同作者分行）
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
            Ok(mut rule) => {
                // 批28b（P3-3）：恢复前规整对齐原版 `normalizeForRestore`
                // （group trim→null、非法 uuid 重生成、超时回退默认）。
                // 恢复语义允许重建 uuid（原版导入/恢复同口径）；编辑保存路径
                // 只做 group 规整，不触碰 uuid，见 `highlight_rule_save`。
                rule.normalize_for_restore();
                match highlight_rule_repo.insert(&rule) {
                    Ok(_) => {}
                    Err(e) => log::warn!("恢复高亮规则失败（已跳过）: {e}"),
                }
            }
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

    // Cookie（批17a 恢复语义，批17c P2-1 移出事务）
    //
    // 恢复写入必须在**事务提交后**进行，且与进程内存同步同处
    // `COOKIE_PERSIST_RW_LOCK` 保护域（见 [`apply_restored_cookies`]）：
    // 事务内取该锁是「先持连接池（P）再取 C」，与 jar/JS 写方的 C→P
    // 锁序相反（ABBA）；且内存同步必须看到已提交的行。

    // 书源运行变量缓存（批17a：对齐原版 `Restore.kt:393-397`）
    //
    // REPLACE 语义：只覆盖同名键，库内其他源/本地独有运行时条目保持不动；
    // 已过期条目（deadline>0 且 <= now）不写入（原版备份侧
    // `getRuntimeSourceCaches(now)` 已过滤，此处防第三方包携带过期项）。
    if !backup.runtime_source_caches.is_empty() {
        let cache_repo = CacheRepository::new(conn);
        let now = current_time_millis();
        for entry in &backup.runtime_source_caches {
            if entry.deadline > 0 && entry.deadline <= now {
                continue;
            }
            if let Err(e) = cache_repo.put_with_deadline(
                &entry.key,
                entry.value.as_deref().unwrap_or(""),
                entry.deadline,
                now,
            ) {
                log::warn!("恢复书源运行变量失败（已跳过）: {} - {e}", entry.key);
            }
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

    // 直链上传规则（v4：写回 caches 配置键）。
    //
    // 语义对齐原版 `Restore.kt:404-408`：仅当备份含该键（原版 zip 内该文件存在）
    // 时写入 `ACache.put`；`None`（旧 v1~v3 备份）不触碰库内既有配置。
    // 值须为合法 JSON 对象（Dart `DirectLinkUploadRuleService` 按对象解析），
    // 空白/非法 JSON 只 warn 跳过，不中断整次恢复（原版 runCatching 语义）。
    if let Some(rule) = backup.direct_link_upload_rule.as_deref() {
        if let Some(rule) = normalize_direct_link_upload_rule(rule) {
            if let Err(e) = CacheRepository::new(conn).put(
                &direct_link_upload_rule_cache_key(),
                rule,
                0, // ttl=0 永不过期（与 config_api::set_config 一致）
            ) {
                log::warn!("恢复直链上传规则失败（已跳过）: {e}");
            }
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
                    match source_repo.insert_with_check_state(source) {
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
    const BOOL_KEYS: [&str; 9] = [
        "enabled",
        "singleUrl",
        "enableJs",
        "loadWithBaseUrl",
        "showWebLog",
        "preload",
        "cacheFirst",
        "enabledCookieJar",
        // 批28b（P3-5）：v1 备份 SELECT * 同样会把该列落为 0/1
        "enableReadRecord",
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
                "cookies",
                "book_memos",
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
            // 批28：v114 新列（原版 RssSource.enableReadRecord），随备份往返
            enable_read_record: false,
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
        assert!(
            !restored.enable_read_record,
            "enableReadRecord 应随备份往返保留（批28，原版 RSS 阅读历史开关）"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    /// 批30b P3-6：备份恢复书源后重建检验状态（NEEDS_CHECK），不沿用旧结果
    ///
    /// 恢复走 `insert_with_check_state`（对齐原版 BookSourceDao.insert）；
    /// 状态是设备本地元数据、不进备份文件，恢复后必须回到待检验。
    #[test]
    fn test_book_source_restore_rebuilds_check_state() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_state_restore");
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("state.json");
        let path_str = backup_path.to_str().unwrap();
        let url = "https://restore-state.example.com";

        with_database(|db| {
            let conn = db.connection();
            BookSourceRepository::new(conn).insert_with_check_state(&BookSource {
                book_source_url: url.to_string(),
                book_source_name: "恢复源".to_string(),
                ..BookSource::default()
            })?;
            let mut state = legado_core::models::BookSourceCheckState::new(url);
            state.status = "FAILED".to_string();
            state.detail = "旧失败详情".to_string();
            state.checked_at = 7;
            legado_db::BookSourceCheckStateRepository::new(conn).save(&state)?;
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        assert!(backup_create(path_str).is_ok());
        with_database(|db| {
            db.connection()
                .execute("DELETE FROM book_sources", [])
                .map_err(|e| LegadoError::Database(format!("清库失败: {e}")))?;
            Ok(())
        })
        .unwrap();
        let stats: RestoreStats = serde_json::from_str(&backup_restore(path_str).unwrap()).unwrap();
        assert_eq!(stats.book_sources, 1, "应恢复恰好 1 条书源");

        with_database(|db| {
            let restored = legado_db::BookSourceCheckStateRepository::new(db.connection())
                .find_by_url(url)?
                .expect("恢复后应重建状态行");
            assert_eq!(restored.status, "NEEDS_CHECK", "恢复即待检验");
            assert_eq!(restored.checked_at, 0);
            assert!(restored.detail.is_empty(), "不得沿用备份前的失败详情");
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批27] ReadRecord 恢复 v113 语义：物理键 `(deviceId,bookName,author)`
    ///
    /// 覆盖：非本机记录直插、同名不同作者分行、同键本机较新者胜（时长不回滚）、
    /// 同键传入较新时章节快照落库，且全程不再产生旧合并作者串。
    #[test]
    fn test_read_record_restore_v113_semantics() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_roundtrip_readrecord_v113");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("readrecord_merge_v113.json");
        let path_str = backup_path.to_str().unwrap();

        // 预置本机库内记录（书X/作者乙 较新：readTime=200）
        with_database(|db| {
            let repo = ReadRecordRepository::new(db.connection());
            repo.upsert_full("", "书X", "作者乙", 200, 20)?;
            repo.upsert_full("", "书Y", "作者丁", 50, 5)
        })
        .unwrap();

        let mut backup = empty_backup();
        backup.read_records = vec![
            // 非本机 device-A 记录（直接插入）
            serde_json::json!({
                "deviceId": "device-A", "bookName": "书X",
                "author": "作者甲", "readTime": 500, "lastRead": 50
            }),
            // 同名不同作者：新行（不合并进 作者乙）
            serde_json::json!({
                "deviceId": "", "bookName": "书X",
                "author": "作者丙", "readTime": 100, "lastRead": 5
            }),
            // 同键本机较旧记录：readTime/lastRead 保留库内值
            serde_json::json!({
                "deviceId": "", "bookName": "书X",
                "author": "作者乙", "readTime": 100, "lastRead": 5
            }),
            // 同键本机传入较新：覆盖时长并落章节快照
            serde_json::json!({
                "deviceId": "", "bookName": "书Y", "author": "作者丁",
                "readTime": 999, "lastRead": 99,
                "lastChapterTitle": "备份章节", "lastChapterIndex": 3,
                "lastChapterPos": 30, "coverUrl": "https://cover.example/new.jpg"
            }),
        ];
        let json = serde_json::to_string(&backup).unwrap();
        fs::write(path_str, json).unwrap();

        let stats_json = backup_restore(path_str).unwrap();
        let stats: RestoreStats = serde_json::from_str(&stats_json).unwrap();
        assert_eq!(stats.read_records, 4);

        with_database(|db| {
            let repo = ReadRecordRepository::new(db.connection());
            let all = repo.find_all().unwrap();
            assert_eq!(all.len(), 4, "同名不同作者应分行（不合并为一行）: {all:?}");

            // 非本机记录：deviceId 归属正确
            let foreign = all.iter().find(|r| r.device_id == "device-A").unwrap();
            assert_eq!(foreign.book_name, "书X");
            assert_eq!(foreign.author, "作者甲");
            assert_eq!(foreign.read_time, 500);
            assert_eq!(foreign.last_read, 50);

            // 同键本机较新：时长/最后阅读不被旧备份覆盖
            let local_x = all
                .iter()
                .find(|r| r.device_id.is_empty() && r.book_name == "书X" && r.author == "作者乙")
                .unwrap();
            assert_eq!(local_x.read_time, 200, "本机较新 readTime 不得被旧备份覆盖");
            assert_eq!(local_x.last_read, 20);

            // 同名不同作者：独立行
            let other_x = all
                .iter()
                .find(|r| r.book_name == "书X" && r.author == "作者丙")
                .unwrap();
            assert_eq!(other_x.read_time, 100);

            // 同键传入较新：时长覆盖 + 章节快照落库
            let local_y = all
                .iter()
                .find(|r| r.device_id.is_empty() && r.book_name == "书Y")
                .unwrap();
            assert_eq!(local_y.author, "作者丁");
            assert_eq!(local_y.read_time, 999);
            assert_eq!(local_y.last_read, 99);
            assert_eq!(local_y.last_chapter_title.as_deref(), Some("备份章节"));
            assert_eq!(local_y.last_chapter_index, 3);
            assert_eq!(local_y.last_chapter_pos, 30);
            assert_eq!(
                local_y.cover_url.as_deref(),
                Some("https://cover.example/new.jpg")
            );

            // 不再产生旧合并作者串
            assert!(
                all.iter().all(|r| !r.author.starts_with("\u{1E}authors:")),
                "写入侧不得再合并作者: {all:?}"
            );

            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批27] 备份 v5：书备忘随备份往返，且只导出书架内书籍的备忘
    #[test]
    fn test_book_memo_backup_restore_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_roundtrip_book_memo");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("book_memo.json");
        let path_str = backup_path.to_str().unwrap();

        let on_shelf = "https://memo.example/on-shelf";
        let off_shelf = "https://memo.example/off-shelf";
        with_database(|db| {
            let conn = db.connection();
            BookRepository::new(conn).insert(&Book {
                book_url: on_shelf.to_string(),
                name: "备忘书".to_string(),
                author: "作者甲".to_string(),
                ..Book::default()
            })?;
            let memo_repo = BookMemoRepository::new(conn);
            memo_repo.upsert(&BookMemo {
                book_url: on_shelf.to_string(),
                content: "书架内备忘".to_string(),
                updated_at: 1_700_000_000_000,
            })?;
            memo_repo.upsert(&BookMemo {
                book_url: off_shelf.to_string(),
                content: "离架备忘".to_string(),
                updated_at: 1_700_000_000_100,
            })
        })
        .unwrap();

        backup_create(path_str).unwrap();
        let raw: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(path_str).unwrap()).unwrap();
        let memos = raw["bookMemos"].as_array().unwrap();
        assert_eq!(memos.len(), 1, "只导出书架内书籍的备忘: {memos:?}");
        assert_eq!(memos[0]["bookUrl"], on_shelf);
        assert_eq!(memos[0]["content"], "书架内备忘");
        assert_eq!(memos[0]["updatedAt"], 1_700_000_000_000_i64);

        // 清库后恢复
        with_database(|db| {
            db.connection()
                .execute("DELETE FROM book_memos", [])
                .map_err(|e| LegadoError::Database(format!("清空书备忘失败: {e}")))?;
            db.connection()
                .execute("DELETE FROM books", [])
                .map_err(|e| LegadoError::Database(format!("清空书籍失败: {e}")))?;
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        backup_restore(path_str).unwrap();
        with_database(|db| {
            let repo = BookMemoRepository::new(db.connection());
            let memo = repo.get(on_shelf)?.expect("书架内备忘应恢复");
            assert_eq!(memo.content, "书架内备忘");
            assert_eq!(memo.updated_at, 1_700_000_000_000);
            assert!(repo.get(off_shelf)?.is_none(), "离架备忘不随备份恢复");
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批27] 旧格式（v1~v4，无 bookMemos 键）恢复不得清空库内既有备忘
    #[test]
    fn test_legacy_backup_without_book_memos_keeps_existing() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_v4_no_book_memo");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("v4_backup.json");
        let path_str = backup_path.to_str().unwrap();

        let book_url = "https://memo.example/legacy";
        with_database(|db| {
            let conn = db.connection();
            BookRepository::new(conn).insert(&Book {
                book_url: book_url.to_string(),
                name: "旧备份书".to_string(),
                ..Book::default()
            })?;
            BookMemoRepository::new(conn).upsert(&BookMemo {
                book_url: book_url.to_string(),
                content: "库内既有备忘".to_string(),
                updated_at: 500,
            })
        })
        .unwrap();

        // v4 形态：无 bookMemos 键
        fs::write(path_str, r#"{"version":4,"backupTime":1,"books":[]}"#).unwrap();
        backup_restore(path_str).unwrap();

        with_database(|db| {
            let memo = BookMemoRepository::new(db.connection())
                .get(book_url)?
                .expect("旧备份缺 bookMemos 时不得清空库内备忘");
            assert_eq!(memo.content, "库内既有备忘");
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批27] 原版 zip：bookMemo.json 按 restoredBookUrls 过滤 + 更新者胜
    #[test]
    fn test_restore_upstream_zip_book_memo_filtered_and_newest_wins() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let book_url = "https://zip.example/memo-book";
        with_database(|db| {
            let conn = db.connection();
            BookRepository::new(conn).insert(&Book {
                book_url: book_url.to_string(),
                name: "zip备忘书".to_string(),
                ..Book::default()
            })?;
            BookMemoRepository::new(conn).upsert(&BookMemo {
                book_url: book_url.to_string(),
                content: "库内旧备忘".to_string(),
                updated_at: 50,
            })
        })
        .unwrap();

        let bookshelf = format!(
            r#"[{{"bookUrl":"{book_url}","name":"zip备忘书","author":"作者甲",
                 "origin":"loc_book","originName":"本地","type":0,
                 "latestChapterTime":0,"lastCheckTime":0,"lastCheckCount":0,
                 "totalChapterNum":0,"durChapterIndex":0,"durChapterPos":0,
                 "canUpdate":true,"order":0,"originOrder":0}}]"#
        );
        let book_memo = r#"[
            {"bookUrl":"https://zip.example/memo-book","content":"备份新备忘","updatedAt":100},
            {"bookUrl":"https://zip.example/missing-book","content":"离架备忘","updatedAt":999}
        ]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_book_memo",
            &[
                ("bookshelf.json", bookshelf.as_bytes()),
                ("bookMemo.json", book_memo.as_bytes()),
            ],
        );

        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.books, 1);

        with_database(|db| {
            let repo = BookMemoRepository::new(db.connection());
            let memo = repo.get(book_url)?.expect("书架内备忘应恢复");
            assert_eq!(memo.content, "备份新备忘", "新备份应覆盖库内旧备忘");
            assert_eq!(memo.updated_at, 100);
            assert!(
                repo.get("https://zip.example/missing-book")?.is_none(),
                "不在 restoredBookUrls 的备忘应被过滤"
            );
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批27] 自有备份 readRecords 元素含全部 13 字段且往返逐字段一致
    #[test]
    fn test_read_record_backup_13_fields_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_read_record_13_fields");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("read_record_13.json");
        let path_str = backup_path.to_str().unwrap();

        let seeded = ReadRecord {
            device_id: String::new(),
            book_name: "十三字段书".to_string(),
            author: "作者癸".to_string(),
            read_time: 123_456,
            last_read: 1_700_000_000_123,
            last_chapter_title: Some("第十二章".to_string()),
            last_chapter_index: 11,
            last_chapter_pos: 1_234,
            cover_url: Some("https://cover.example/13.jpg".to_string()),
            resolved_author: Some("还原作者".to_string()),
            display_book_name: "显示书名".to_string(),
            display_author: "显示作者".to_string(),
            metadata_edited_at: 1_700_000_000_456,
        };
        with_database(|db| ReadRecordRepository::new(db.connection()).write_row(&seeded)).unwrap();

        backup_create(path_str).unwrap();
        let raw: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(path_str).unwrap()).unwrap();
        let records = raw["readRecords"].as_array().unwrap();
        let record = records
            .iter()
            .find(|r| r["bookName"] == "十三字段书")
            .expect("备份应包含种子阅读记录");
        for key in [
            "deviceId",
            "bookName",
            "author",
            "readTime",
            "lastRead",
            "lastChapterTitle",
            "lastChapterIndex",
            "lastChapterPos",
            "coverUrl",
            "resolvedAuthor",
            "displayBookName",
            "displayAuthor",
            "metadataEditedAt",
        ] {
            assert!(
                record.get(key).is_some(),
                "readRecord 备份应含 {key} 键: {record}"
            );
        }

        with_database(|db| {
            db.connection()
                .execute("DELETE FROM readRecord", [])
                .map_err(|e| LegadoError::Database(format!("清空阅读记录失败: {e}")))?;
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        backup_restore(path_str).unwrap();
        with_database(|db| {
            let row = ReadRecordRepository::new(db.connection())
                .get_by_pk("", "十三字段书", "作者癸")?
                .expect("恢复后阅读记录应存在");
            assert_eq!(row.read_time, seeded.read_time);
            assert_eq!(row.last_read, seeded.last_read);
            assert_eq!(row.last_chapter_title, seeded.last_chapter_title);
            assert_eq!(row.last_chapter_index, seeded.last_chapter_index);
            assert_eq!(row.last_chapter_pos, seeded.last_chapter_pos);
            assert_eq!(row.cover_url, seeded.cover_url);
            assert_eq!(row.resolved_author, seeded.resolved_author);
            assert_eq!(row.display_book_name, seeded.display_book_name);
            assert_eq!(row.display_author, seeded.display_author);
            assert_eq!(row.metadata_edited_at, seeded.metadata_edited_at);
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
            // [批28] group 全字段往返（v114 新列，原版 HighlightRule.group）
            group: Some("备份分组".to_string()),
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
            // [批28] group（v114 新列）显式断言
            assert_eq!(
                rule.group.as_deref(),
                Some("备份分组"),
                "group 应随备份往返保留（原版 HighlightRule.group）"
            );

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
        // 直链配置预置为空：回滚断言要求「写入 → 回滚 → 零残留」
        set_direct_link_rule_config(None);

        let mut backup = empty_backup();
        backup.book_sources = vec![serde_json::json!({
            "bookSourceUrl": "https://rb.example/source-b",
            "bookSourceName": "回滚源B",
        })];
        backup.books = vec![serde_json::json!({
            "bookUrl": "https://rb.example/book-b",
            "name": "回滚书B",
        })];
        // 配置键同属恢复事务写入面：回滚后必须一并撤销
        backup.direct_link_upload_rule = Some(DIRECT_LINK_RULE_SEED.to_string());

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
            let rule = CacheRepository::new(conn)
                .get(&direct_link_upload_rule_cache_key())
                .unwrap();
            assert!(rule.is_none(), "回滚后直链配置不得残留");
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
        assert_eq!(
            data.version, BACKUP_VERSION,
            "新备份应携带当前格式版本（BACKUP_VERSION）"
        );
        assert!(data.backup_time > 0);
        assert!(
            content.contains("\"servers\""),
            "v4 备份应包含 servers 字段：{content}"
        );
        assert!(
            content.contains("\"bookMemos\""),
            "v5 备份应包含 bookMemos 字段（空表也写空数组）：{content}"
        );
        let raw: serde_json::Value = serde_json::from_str(&content).unwrap();
        assert_eq!(
            raw.get("bookMemos").and_then(|v| v.as_array()),
            Some(&Vec::new()),
            "空表应写出空数组而非省略键"
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

    // ─── 批16f：直链上传规则备份/恢复 ───────────────────────────────────

    /// 直链规则种子（4 字段 camelCase，与 Dart `DirectLinkUploadRule.toJson` 同形；
    /// uploadUrl 含原版 `url,{options}` 逗号选项形态）
    const DIRECT_LINK_RULE_SEED: &str = r#"{"uploadUrl":"https://upload.example/api,{\"method\":\"POST\",\"body\":{\"file\":\"fileRequest\"}}","downloadUrlRule":"$.data.url","summary":"往返规则","compress":true}"#;

    /// 读取 caches 中的直链规则配置（None 表示未配置）
    fn read_direct_link_rule_config() -> Option<String> {
        with_database(|db| {
            CacheRepository::new(db.connection()).get(&direct_link_upload_rule_cache_key())
        })
        .unwrap()
    }

    /// 写入（Some）或删除（None）直链规则配置（**不走事务**，供测试预置/清库）
    fn set_direct_link_rule_config(value: Option<&str>) {
        with_database(|db| {
            let repo = CacheRepository::new(db.connection());
            match value {
                Some(v) => repo.put(&direct_link_upload_rule_cache_key(), v, 0)?,
                None => repo.delete(&direct_link_upload_rule_cache_key())?,
            }
            Ok::<(), LegadoError>(())
        })
        .unwrap();
    }

    /// 写一个临时备份 JSON 文件并返回 (目录, 路径)
    fn write_json_backup_file(
        dir_name: &str,
        file_name: &str,
        content: &str,
    ) -> (std::path::PathBuf, String) {
        let dir = std::env::temp_dir().join(dir_name);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join(file_name);
        fs::write(&path, content).unwrap();
        let path_str = path.to_str().unwrap().to_string();
        (dir, path_str)
    }

    /// [批16f] 自有 JSON 备份往返：配置 → backup_create 含 v4 字段 → 清库 → restore 恢复
    #[test]
    fn test_direct_link_upload_rule_backup_restore_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(Some(DIRECT_LINK_RULE_SEED));

        let dir = std::env::temp_dir().join("legado_backup_roundtrip_direct_link");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("direct_link_roundtrip.json");
        let path_str = backup_path.to_str().unwrap();

        assert_eq!(backup_create(path_str).unwrap(), path_str);

        // 备份 JSON 携带当前版本键，且值与配置文本逐字节一致
        let content = fs::read_to_string(&backup_path).unwrap();
        let parsed: BackupData = serde_json::from_str(&content).unwrap();
        // 版本契约钉死一次字面量（P2-4）：常量若是误改，此处必须红
        // 批27：备份格式版本 4→5（新增 bookMemos）
        assert_eq!(parsed.version, 5, "v5 契约版本");
        assert_eq!(
            parsed.direct_link_upload_rule.as_deref(),
            Some(DIRECT_LINK_RULE_SEED),
            "备份应原样携带直链规则配置文本"
        );
        assert!(
            content.contains("\"directLinkUploadRule\""),
            "v4 备份应包含 directLinkUploadRule 字段：{content}"
        );

        // 清库 → 恢复 → 配置逐字节恢复
        set_direct_link_rule_config(None);
        assert!(read_direct_link_rule_config().is_none());

        assert!(backup_restore(path_str).is_ok());
        assert_eq!(
            read_direct_link_rule_config().as_deref(),
            Some(DIRECT_LINK_RULE_SEED),
            "恢复后配置应与备份文本一致"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批16f] 配置缺失/空串时不写该键（备份形状保持旧版兼容）
    #[test]
    fn test_backup_without_direct_link_rule_omits_key() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let dir = std::env::temp_dir().join("legado_backup_direct_link_absent");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let backup_path = dir.join("direct_link_absent.json");
        let path_str = backup_path.to_str().unwrap();

        // 未配置 → 省略键
        set_direct_link_rule_config(None);
        assert!(backup_create(path_str).is_ok());
        let content = fs::read_to_string(&backup_path).unwrap();
        assert!(
            !content.contains("\"directLinkUploadRule\""),
            "未配置直链规则时不得写出该键：{content}"
        );

        // 空白值同样视为未配置 → 省略键
        set_direct_link_rule_config(Some("   "));
        assert!(backup_create(path_str).is_ok());
        let content = fs::read_to_string(&backup_path).unwrap();
        assert!(
            !content.contains("\"directLinkUploadRule\""),
            "空白直链规则不得写出该键：{content}"
        );
        let parsed: BackupData = serde_json::from_str(&content).unwrap();
        assert!(parsed.direct_link_upload_rule.is_none());

        set_direct_link_rule_config(None);
        let _ = fs::remove_dir_all(&dir);
    }

    /// [批16f] 旧 v3 备份无该键：恢复不触碰库内既有直链配置
    ///
    /// 对齐原版 `Restore.kt:404-408`：仅当备份内 `directLinkUploadRule.json`
    /// 存在时才 `ACache.put`；缺失即不处理（不 delete）。
    #[test]
    fn test_legacy_backup_without_direct_link_rule_keeps_existing_config() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(Some(DIRECT_LINK_RULE_SEED));

        let (dir, path) = write_json_backup_file(
            "legado_backup_legacy_no_direct_link",
            "legacy_v3.json",
            r#"{"version":3,"backupTime":1700000000000,"books":[],"bookSources":[]}"#,
        );

        // 解析应为 None（serde default）
        let content = fs::read_to_string(&path).unwrap();
        let parsed: BackupData = serde_json::from_str(&content).unwrap();
        assert!(
            parsed.direct_link_upload_rule.is_none(),
            "旧 v3 备份缺该键应解析为 None"
        );

        assert!(backup_restore(&path).is_ok());
        assert_eq!(
            read_direct_link_rule_config().as_deref(),
            Some(DIRECT_LINK_RULE_SEED),
            "旧备份缺该键不得清空库内既有直链配置"
        );

        set_direct_link_rule_config(None);
        let _ = fs::remove_dir_all(&dir);
    }

    /// [批16f] 非法 JSON 值：warn 跳过且恢复整体成功（其余表照常落库）
    #[test]
    fn test_restore_invalid_direct_link_rule_skips_and_keeps_existing() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(Some(DIRECT_LINK_RULE_SEED));

        let book = Book {
            book_url: "https://direct-link.example/book".to_string(),
            name: "直链书".to_string(),
            author: "作者".to_string(),
            ..Book::default()
        };
        for (file_name, invalid) in [
            ("broken_syntax.json", "not-a-json"),
            ("json_array.json", "[1,2,3]"),
            ("json_null.json", "null"),
        ] {
            let backup_json = serde_json::json!({
                "version": BACKUP_VERSION,
                "books": [serde_json::to_value(&book).unwrap()],
                "directLinkUploadRule": invalid,
            });
            let (dir, path) = write_json_backup_file(
                "legado_backup_direct_link_invalid",
                file_name,
                &backup_json.to_string(),
            );

            let stats: RestoreStats =
                serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
            assert_eq!(
                stats.books, 1,
                "非法直链规则不得影响其余表恢复（{file_name}）"
            );
            assert_eq!(
                read_direct_link_rule_config().as_deref(),
                Some(DIRECT_LINK_RULE_SEED),
                "非法直链规则应跳过并保留库内既有配置（{file_name}）"
            );

            let _ = fs::remove_dir_all(&dir);
        }

        set_direct_link_rule_config(None);
    }

    /// [批16f 回修 P2-2] 字段本身是 JSON 数组：宽容解析后由 normalize 判非对象跳过
    ///
    /// `Option<String>` 直接反序列化会把整份备份判为解析失败（开事务前上抛），
    /// 与契约「数组/null/语法错误只 warn 跳过」矛盾；宽容反序列化后应整体恢复成功，
    /// 其余表照常落库，库内既有直链配置保留。
    #[test]
    fn test_restore_direct_link_rule_field_as_json_array_skips() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(Some(DIRECT_LINK_RULE_SEED));

        let book = Book {
            book_url: "https://direct-link.example/array-book".to_string(),
            name: "数组字段书".to_string(),
            author: "作者".to_string(),
            ..Book::default()
        };
        let backup_json = serde_json::json!({
            "version": BACKUP_VERSION,
            "books": [serde_json::to_value(&book).unwrap()],
            // 字段类型是 JSON 数组（不是字符串）——旧实现整包解析失败
            "directLinkUploadRule": [1, 2, 3],
        });
        let (dir, path) = write_json_backup_file(
            "legado_backup_direct_link_field_array",
            "field_array.json",
            &backup_json.to_string(),
        );

        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap())
            .expect("字段为数组时整份备份仍应恢复成功");
        assert_eq!(stats.books, 1, "其余表应照常恢复");
        assert_eq!(
            read_direct_link_rule_config().as_deref(),
            Some(DIRECT_LINK_RULE_SEED),
            "数组值应被判定为非对象并跳过，库内既有配置保留"
        );

        set_direct_link_rule_config(None);
        let _ = fs::remove_dir_all(&dir);
    }

    /// [批16f 回修 P2-2] 字段本身是 JSON 对象：恢复为该对象的紧凑文本
    ///
    /// 上游 `directLinkUploadRule.json` 是单对象形态；若第三方工具把它内联进
    /// 备份 JSON（字段类型为对象而非字符串），应按对象文本恢复而不是整包失败。
    #[test]
    fn test_restore_direct_link_rule_field_as_json_object_restores() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(None);

        let backup_json = serde_json::json!({
            "version": BACKUP_VERSION,
            "directLinkUploadRule": {"uploadUrl": "x"},
        });
        let (dir, path) = write_json_backup_file(
            "legado_backup_direct_link_field_object",
            "field_object.json",
            &backup_json.to_string(),
        );

        assert!(
            backup_restore(&path).is_ok(),
            "字段为对象时整份备份应恢复成功"
        );
        assert_eq!(
            read_direct_link_rule_config().as_deref(),
            Some(r#"{"uploadUrl":"x"}"#),
            "对象值应按紧凑 JSON 文本写入配置键"
        );

        set_direct_link_rule_config(None);
        let _ = fs::remove_dir_all(&dir);
    }

    /// [批16f 回修 P3-4] `{}` 是合法 JSON 对象：按对象写入（不额外清空语义）
    ///
    /// 语义非法（字段全空）由 Dart `getEffectiveRule` 回落内置默认规则，Rust 侧
    /// 只做「是否对象」判定，不擅自改写或删除用户配置。
    #[test]
    fn test_restore_empty_json_object_direct_link_rule_written() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(None);

        let backup_json = serde_json::json!({
            "version": BACKUP_VERSION,
            "directLinkUploadRule": "{}",
        });
        let (dir, path) = write_json_backup_file(
            "legado_backup_direct_link_empty_object",
            "empty_object.json",
            &backup_json.to_string(),
        );

        assert!(backup_restore(&path).is_ok());
        assert_eq!(
            read_direct_link_rule_config().as_deref(),
            Some("{}"),
            "空对象是合法 JSON 对象，应按原文写入"
        );

        set_direct_link_rule_config(None);
        let _ = fs::remove_dir_all(&dir);
    }

    /// [批16f 回修 P3-2] 带 UTF-8 BOM 的值：与 zip 路径 `decode_zip_text` 同口径剥离
    #[test]
    fn test_restore_direct_link_rule_with_bom_prefix() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(None);

        let rule = r#"{"uploadUrl":"https://bom.example/api","summary":"BOM"}"#;
        let backup_json = serde_json::json!({
            "version": BACKUP_VERSION,
            // 字符串以 BOM 开头（等价于原版文件中带 BOM 的文本）
            "directLinkUploadRule": format!("\u{feff}{rule}"),
        });
        let (dir, path) = write_json_backup_file(
            "legado_backup_direct_link_bom",
            "bom.json",
            &backup_json.to_string(),
        );

        assert!(backup_restore(&path).is_ok());
        assert_eq!(
            read_direct_link_rule_config().as_deref(),
            Some(rule),
            "BOM 应被剥离后写入配置（与 decode_zip_text 对称）"
        );

        set_direct_link_rule_config(None);
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

    /// [批9 回归] 原版 zip 全类别落库：18 类数据文件 + 加密 servers + 媒体/配置跳过
    /// （`cookies.json`/`runtimeSourceCache.json` 有独立分支用例，
    /// `directLinkUploadRule.json` 有批16f 专项用例）
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
            "style":"{}","order":2,"timeoutMillisecond":3000,"applyToTitle":false,"applyToBody":true,
            "group":"zip分组"}]"#;
        let book_source = r#"[{"bookSourceUrl":"https://zip.example/source","bookSourceName":"zip源",
            "bookSourceGroup":"组","bookSourceType":0,"enabled":true,"enabledExplore":true,
            "customOrder":1,"weight":0,"respondTime":180000,
            "searchUrl":"/search?q={{key}}",
            "ruleSearch":{"bookList":"class.b","name":"a@text","bookUrl":"a@href"},
            "ruleContent":{"content":".content@text","contentBatch":"batch@js:result",
                "maxBatchSize":20}}]"#;
        let rss_sources = r#"[{"sourceUrl":"https://zip.example/rss","sourceName":"zip RSS",
            "sourceIcon":"https://zip.example/icon.png","enabled":true,"type":1,
            "enableReadRecord":false,
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
            // 批28：原版 highlightRules.group 应随 zip 恢复保留
            assert_eq!(
                rule.group.as_deref(),
                Some("zip分组"),
                "group 应随原版 zip 备份保留（批28）"
            );

            // 书源
            let source = BookSourceRepository::new(conn)
                .find_by_url("https://zip.example/source")?
                .expect("书源应落库");
            assert_eq!(source.book_source_name, "zip源");
            assert!(source.rule_search.is_some(), "搜索规则应随备份落库");
            // 批28b（P2-3）：原版 zip bookSource.json 的批量正文规则原样透传
            let content_rule = source.rule_content.expect("正文规则应随备份落库");
            assert_eq!(content_rule.content.as_deref(), Some(".content@text"));
            assert_eq!(
                content_rule.content_batch.as_deref(),
                Some("batch@js:result"),
                "contentBatch 应随原版 zip 备份透传（批28b）"
            );
            assert_eq!(
                content_rule.max_batch_size,
                Some(20),
                "maxBatchSize 应随原版 zip 备份透传（批28b）"
            );

            // RSS 源 / 收藏
            let rss = RssSourceRepository::new(conn)
                .find_by_url("https://zip.example/rss")
                .map_err(LegadoError::Database)?
                .expect("RSS 源应落库");
            assert_eq!(rss.rule_articles.as_deref(), Some("class.item"));
            // 批28：原版 rssSources.enableReadRecord 应随 zip 恢复保留
            assert!(
                !rss.enable_read_record,
                "enableReadRecord 应随原版 zip 备份保留（批28）"
            );
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
    /// 「需设置备份密码」；本实现返回可读错误（`BACKUP_PASSWORD_REQUIRED`），
    /// **注**：批9 的「我方无密码输入面」口径已被批17a 取代（现由探测 +
    /// 密码框 + `password` 参数处理）；本用例固化「未提供密码时零落库」的
    /// 前置校验语义。
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
        assert!(
            message.contains(BACKUP_PASSWORD_REQUIRED_PREFIX),
            "应返回 BACKUP_PASSWORD_REQUIRED 错误码: {message}"
        );
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

    /// [批9 回修 P2-12 / 批17a] runtimeSourceCache.json 明文/密文两分支
    ///
    /// - 密文（设过备份密码）且未提供密码 → `BACKUP_PASSWORD_REQUIRED`，
    ///   且库内哨兵行未被触碰；
    /// - 明文数组（历史/第三方产出）→ 无需密码，按内容恢复（空数组不写行），
    ///   其余表照常恢复。
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
        assert!(
            message.contains(BACKUP_PASSWORD_REQUIRED_PREFIX),
            "应返回 BACKUP_PASSWORD_REQUIRED 错误码: {message}"
        );
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
            "明文 runtimeSourceCache（空数组）无需密码，且不得影响书架"
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

    /// [批16f] 原版 zip 映射：`directLinkUploadRule.json` → caches 配置键
    ///
    /// 原版 `Backup.kt` 以 `GSON.toJson` **明文**写出（未走 `BackupAES`），
    /// `Restore.kt:404-408` 解出后 `ACache.put`；我方映射到
    /// `config:directLinkUploadRule`（Dart `DirectLinkUploadRuleService.configKey`）。
    /// 第二段覆盖第三方/历史加密产物的空密码解密回退（同一解密流水线）。
    #[test]
    fn test_restore_zip_maps_direct_link_upload_rule_to_config() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(None);

        // 明文（真实原版形态）
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_direct_link_plain",
            &[(
                "directLinkUploadRule.json",
                DIRECT_LINK_RULE_SEED.as_bytes(),
            )],
        );
        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.books, 0);
        assert_eq!(
            read_direct_link_rule_config().as_deref(),
            Some(DIRECT_LINK_RULE_SEED),
            "zip 内明文直链规则应映射到 config 键"
        );
        let _ = fs::remove_dir_all(&dir);

        // 加密回退（Base64 + AES-128-ECB/PKCS7，空密码派生密钥）
        let ciphertext =
            AesCrypto::encrypt_ecb(&backup_aes_key(""), DIRECT_LINK_RULE_SEED.as_bytes()).unwrap();
        let encrypted = base64::engine::general_purpose::STANDARD.encode(ciphertext);
        set_direct_link_rule_config(None);
        let (dir_enc, path_enc) = write_upstream_backup_zip(
            "legado_restore_zip_direct_link_encrypted",
            &[("directLinkUploadRule.json", encrypted.as_bytes())],
        );
        assert!(backup_restore(&path_enc).is_ok());
        assert_eq!(
            read_direct_link_rule_config().as_deref(),
            Some(DIRECT_LINK_RULE_SEED),
            "加密直链规则应按空密码密钥解出并写入 config"
        );
        let _ = fs::remove_dir_all(&dir_enc);

        set_direct_link_rule_config(None);
    }

    /// [批16f P3 收口] zip 内 `directLinkUploadRule.json` 为明文数组 `[1,2]`：
    /// warn 跳过且保留库内既有配置
    ///
    /// 数组不是规则对象；且 `[1,2]` 不具备 Base64 形态（含 `[`/`,`），
    /// 直接走「明文非对象」分支，不进入解密流水线。
    #[test]
    fn test_restore_zip_plain_array_direct_link_rule_skipped() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(Some(DIRECT_LINK_RULE_SEED));

        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_direct_link_plain_array",
            &[("directLinkUploadRule.json", b"[1,2]".as_slice())],
        );
        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.books, 0, "负例不得中断整次恢复");
        assert_eq!(
            read_direct_link_rule_config().as_deref(),
            Some(DIRECT_LINK_RULE_SEED),
            "明文数组不是规则对象，应跳过且保留库内既有配置"
        );

        set_direct_link_rule_config(None);
        let _ = fs::remove_dir_all(&dir);
    }

    /// [批16f P3 收口] zip 内为合法 AES 密文、但明文是数组 `[1,2]`：
    /// 解密成功仍判非对象，warn 跳过且保留库内既有配置
    #[test]
    fn test_restore_zip_encrypted_array_direct_link_rule_skipped() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(Some(DIRECT_LINK_RULE_SEED));

        // 复用现有测试加密辅助：空密码派生密钥 + AES-128-ECB/PKCS7 + Base64
        let ciphertext = AesCrypto::encrypt_ecb(&backup_aes_key(""), b"[1,2]").unwrap();
        let encrypted = base64::engine::general_purpose::STANDARD.encode(ciphertext);
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_direct_link_encrypted_array",
            &[("directLinkUploadRule.json", encrypted.as_bytes())],
        );
        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.books, 0, "负例不得中断整次恢复");
        assert_eq!(
            read_direct_link_rule_config().as_deref(),
            Some(DIRECT_LINK_RULE_SEED),
            "解密成功但明文为数组时应跳过且保留库内既有配置"
        );

        set_direct_link_rule_config(None);
        let _ = fs::remove_dir_all(&dir);
    }

    /// [批16f P3 收口] 字段为内联对象（多键且含 `expiryDate`）：键不丢、不剥除
    ///
    /// 内联对象经宽容反序列化转为紧凑文本落库；`serde_json` 未启用
    /// `preserve_order`，允许紧凑化与键重排，但键集合与值必须完整保留
    /// （含原版未建模的 `expiryDate`）。
    #[test]
    fn test_restore_direct_link_rule_inline_object_keeps_all_keys() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(None);

        let inline = serde_json::json!({
            "uploadUrl": "https://upload.example/api",
            "downloadUrlRule": "$.data.url",
            "summary": "多键内联",
            "compress": false,
            "expiryDate": 1_700_000_000_000i64,
        });
        let backup_json = serde_json::json!({
            "version": BACKUP_VERSION,
            "directLinkUploadRule": inline.clone(),
        });
        let (dir, path) = write_json_backup_file(
            "legado_backup_direct_link_inline_object",
            "inline_multikey.json",
            &backup_json.to_string(),
        );

        assert!(backup_restore(&path).is_ok());
        let stored = read_direct_link_rule_config().expect("内联对象应写入配置");
        let stored_json: serde_json::Value = serde_json::from_str(&stored).unwrap();
        assert_eq!(
            stored_json, inline,
            "内联对象键值应完整保留（允许紧凑化与键重排）: {stored}"
        );
        assert!(
            stored_json
                .as_object()
                .is_some_and(|map| map.contains_key("expiryDate")),
            "原版 expiryDate 不得被剥除: {stored}"
        );

        set_direct_link_rule_config(None);
        let _ = fs::remove_dir_all(&dir);
    }

    /// [批16f] 空文件/空白内容/空串/null：跳过且不清库内既有直链配置
    #[test]
    fn test_restore_empty_direct_link_rule_skipped() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(Some(DIRECT_LINK_RULE_SEED));

        // zip：空文件与纯空白内容
        for (dir_name, bytes) in [
            ("legado_restore_zip_direct_link_empty_file", b"".as_slice()),
            (
                "legado_restore_zip_direct_link_blank",
                b"  \n\t ".as_slice(),
            ),
        ] {
            let (dir, path) =
                write_upstream_backup_zip(dir_name, &[("directLinkUploadRule.json", bytes)]);
            let stats: RestoreStats =
                serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
            assert_eq!(stats.books, 0, "{dir_name} 应整体恢复成功");
            assert_eq!(
                read_direct_link_rule_config().as_deref(),
                Some(DIRECT_LINK_RULE_SEED),
                "{dir_name} 空内容不得清空库内既有配置"
            );
            let _ = fs::remove_dir_all(&dir);
        }

        // 自有 JSON：空串与 null 同样跳过
        for (file_name, value) in [
            ("empty_string.json", serde_json::json!("")),
            ("null_value.json", serde_json::Value::Null),
        ] {
            let backup_json = serde_json::json!({
                "version": BACKUP_VERSION,
                "directLinkUploadRule": value,
            });
            let (dir, path) = write_json_backup_file(
                "legado_backup_direct_link_empty",
                file_name,
                &backup_json.to_string(),
            );
            assert!(backup_restore(&path).is_ok(), "{file_name} 应整体恢复成功");
            assert_eq!(
                read_direct_link_rule_config().as_deref(),
                Some(DIRECT_LINK_RULE_SEED),
                "{file_name} 空值不得清空库内既有配置"
            );
            let _ = fs::remove_dir_all(&dir);
        }

        set_direct_link_rule_config(None);
    }

    /// [批16f 回修 P3-4] zip 缺 `directLinkUploadRule.json`：不清库内既有配置
    ///
    /// 对齐原版 `Restore.kt:404-408` 的 `takeIf { it.exists() }` 语义。
    #[test]
    fn test_restore_zip_without_direct_link_rule_keeps_existing_config() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        set_direct_link_rule_config(Some(DIRECT_LINK_RULE_SEED));

        let bookshelf =
            r#"[{"bookUrl":"https://zip.example/no-rule","name":"无规则书","author":"作者"}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_direct_link_absent",
            &[("bookshelf.json", bookshelf.as_bytes())],
        );

        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.books, 1, "其余表应照常恢复");
        assert_eq!(
            read_direct_link_rule_config().as_deref(),
            Some(DIRECT_LINK_RULE_SEED),
            "备份缺该文件时不得清空库内既有直链配置"
        );

        set_direct_link_rule_config(None);
        let _ = fs::remove_dir_all(&dir);
    }

    /// [批27] 本机既有记录 + zip 备份同键记录 → 单行且较新者胜
    ///
    /// 原版 zip 的 deviceId 是原设备 androidId；归一为空串后与库内本机记录同键
    /// （同书同作者）合并，库内较新的 readTime/lastRead 不被旧备份覆盖。
    #[test]
    fn test_restore_upstream_zip_read_record_same_author_newest_wins() {
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

        // 原版 zip 备份记录（同作者较旧：readTime 1700000004000，deviceId 为原设备）
        let read_record = r#"[{"deviceId":"original-device","bookName":"zip书一",
            "author":"作者乙","readTime":1700000004000,"lastRead":8}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_read_record_same_author",
            &[("readRecord.json", read_record.as_bytes())],
        );

        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.read_records, 1);

        with_database(|db| {
            let rows = ReadRecordRepository::new(db.connection()).find_all()?;
            assert_eq!(rows.len(), 1, "同书同作者应合并为一行: {rows:?}");
            assert_eq!(rows[0].device_id, "", "zip 记录 deviceId 应归一为空串");
            assert_eq!(rows[0].author, "作者乙");
            assert_eq!(
                rows[0].read_time, 1_700_000_009_000,
                "本机较新 readTime 不得被较旧备份覆盖"
            );
            assert_eq!(rows[0].last_read, 90, "lastRead 保留库内较新值");
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// [批27] 本机既有记录 + zip 备份同名不同作者 → 两行独立（不合并时长）
    ///
    /// v113 主键含 author：备份作者与库内作者不同即不同记录。Dart 阅读记录页
    /// 按显示书名+显示作者分组，两行各自计时长，不会叠加。
    #[test]
    fn test_restore_upstream_zip_read_record_different_author_separate_rows() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        with_database(|db| {
            ReadRecordRepository::new(db.connection()).upsert_full(
                "",
                "zip书二",
                "作者乙",
                1_700_000_009_000,
                90,
            )
        })
        .unwrap();

        let read_record = r#"[{"deviceId":"original-device","bookName":"zip书二",
            "author":"作者甲","readTime":1700000004000,"lastRead":8,
            "lastChapterTitle":"备份章节","lastChapterIndex":6,"lastChapterPos":60}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_read_record_diff_author",
            &[("readRecord.json", read_record.as_bytes())],
        );

        let stats: RestoreStats = serde_json::from_str(&backup_restore(&path).unwrap()).unwrap();
        assert_eq!(stats.read_records, 1);

        with_database(|db| {
            let rows = ReadRecordRepository::new(db.connection()).find_all()?;
            assert_eq!(rows.len(), 2, "同名不同作者应分行: {rows:?}");
            let local = rows.iter().find(|r| r.author == "作者乙").unwrap();
            assert_eq!(local.read_time, 1_700_000_009_000);
            let restored = rows.iter().find(|r| r.author == "作者甲").unwrap();
            assert_eq!(restored.device_id, "", "zip 记录 deviceId 应归一为空串");
            assert_eq!(restored.read_time, 1_700_000_004_000);
            assert_eq!(restored.last_read, 8);
            // 13 字段中的章节快照随 zip 备份落库
            assert_eq!(restored.last_chapter_title.as_deref(), Some("备份章节"));
            assert_eq!(restored.last_chapter_index, 6);
            assert_eq!(restored.last_chapter_pos, 60);
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
            group: None,
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

    /// [批16f 回修 P2-1/P3-6] 日志辅助与解密前分流：类型名 + base64 形态判定
    #[test]
    fn test_json_value_kind_and_base64_shape() {
        assert_eq!(json_value_kind(&serde_json::json!({})), "object");
        assert_eq!(json_value_kind(&serde_json::json!([])), "array");
        assert_eq!(json_value_kind(&serde_json::json!("x")), "string");
        assert_eq!(json_value_kind(&serde_json::json!(1)), "number");
        assert_eq!(json_value_kind(&serde_json::json!(true)), "bool");
        assert_eq!(json_value_kind(&serde_json::Value::Null), "null");
        assert_eq!(
            json_parse_kind(&serde_json::from_str::<serde_json::Value>("[1,2,3]")),
            "array"
        );
        assert_eq!(
            json_parse_kind(&serde_json::from_str::<serde_json::Value>("not-json")),
            "非法 JSON"
        );

        // base64 形态：长度 4 的倍数 + 仅 base64 字符集
        assert!(looks_like_base64("QUJDRA=="));
        assert!(looks_like_base64("d41d8cd98f00b204"));
        assert!(!looks_like_base64("{\"uploadUrl\":\"x\"}"));
        assert!(!looks_like_base64("not base64"));
        assert!(!looks_like_base64("abc"), "长度非 4 倍数不算 base64");
        assert!(!looks_like_base64(""));
    }

    /// [批9 密钥派生锚点 / 批17a 扩展] 原版 BackupAES 密钥 = MD5 小写 hex 前 16 个 ASCII 字节
    ///
    /// 向量为外部计算值（`printf <password> | md5sum`）；密码**不 trim**。
    #[test]
    fn test_backup_aes_key_matches_upstream() {
        assert_eq!(&backup_aes_key("")[..], b"d41d8cd98f00b204");
        assert_eq!(&backup_aes_key("secret")[..], b"5ebe2294ecd0e0f0");
        // 中文密码按 UTF-8 字节参与 MD5
        assert_eq!(&backup_aes_key("密码")[..], b"a8105204604a0b11");
        // 纯空格密码不 trim（与空密码不同）
        assert_eq!(&backup_aes_key("   ")[..], b"628631f07321b22d");
        assert_ne!(backup_aes_key("   "), backup_aes_key(""));

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
        assert!(
            BackupCipher::new(Some("secret"))
                .decrypt_text(UPSTREAM_SECRET_PW_COOKIES)
                .unwrap()
                .contains("sid=abc"),
            "secret 密码 cookies 密文应可解密"
        );
    }

    // ─── 批17a：备份密码恢复与探测 ─────────────────────────────────────

    /// 原版「密码 secret」加密的 cookies.json（openssl AES-128-ECB/PKCS7 独立生成）
    ///
    /// 明文 = `[{"url":"https://cookie.secret.example.com","cookie":"sid=abc; theme=dark"},
    /// {"url":"source|https://x.example.com","cookie":"k=v"}]`
    const UPSTREAM_SECRET_PW_COOKIES: &str = "yPHSkviZ0JUUjpmG012f4n0EFgMDh4DRWY0fQ3/h6/Vma0a0/65eUmymixI24vw46cBYFmK8WjAysl+3TdxQljKB+x/3h4lxshMVgj66b7/A858Lx+WMP2OkMVHs9nqVPWQCWI5dFhkQFvZ/9KlgJEUMyM/sq17eNtvMeAlOeKD+fz1Ohx0RZQ5BmR2Zbh1c";

    /// 原版「密码 secret」加密的 runtimeSourceCache.json（openssl 独立生成）
    ///
    /// 明文 = `[{"key":"v_https://runtime.secret.example.com/source_token","value":"tok","deadline":0},
    /// {"key":"userInfo_https://runtime.secret.example.com/source","value":null,
    /// "deadline":4102444800000}]`（deadline 2100 年，避免过期）
    const UPSTREAM_SECRET_PW_RUNTIME: &str = "7YHyIJhec6WNdiIqwc5mBDqaE6y1hz1o0eM7gmV+gzjkKEkps6i0epI8oTaXd/KEeLH7HN/kXeD1Hfy9/yteXbaLCDDd/Ngmu2Z0wy81ruAKo7NAgkT1e9MuKs0fYfYNs2SeMxiBR1IjbUyQVNt6dxWnHlhrVarqJHO1iDaKjghiFD3J5cyaNG3ilBk7SW9TDd90fcpzB899JTf4H6zZ+a8xb2Tk7mnwt1SNrdsUo+1xCbU3WgMxFuFJqee6bXc2";

    /// 原版「密码（中文）」加密的 servers.json（openssl 独立生成）
    ///
    /// 明文 = `[{"id":7,"name":"中文密码服务器","type":"WEBDAV",
    /// "config":"{\"url\":\"https://zh.example.com/\"}","sortNumber":1}]`
    const UPSTREAM_ZH_PW_SERVERS: &str = "HOkliXdfdVc98XaUufz1tteNmHM2YZcirP6Ot/xqz/JmCDTVq2SLNNaMm1eubgDL/oS/lnheWAAHMITgsdSg8F6JA0CPgJ0eawvP7SOnKyBI8Ao2Aihq1nEiCp0mK2OA7+qetUUb0TWu2rkdsOtM9npGVSoVPEjNmBtp8Z/ngvE=";

    /// 原版「密码 三个空格」加密的 servers.json（openssl 独立生成）
    ///
    /// 明文 = `[{"id":8,"name":"空格密码服务器","type":"WEBDAV",
    /// "config":"{\"url\":\"https://sp.example.com/\"}","sortNumber":2}]`
    const UPSTREAM_SPACE_PW_SERVERS: &str = "2sPsIEraNWxegqPN2B9d8kE9swcjKJqclhmG1QYBgsdF4q4T1Uj0E8G/uN8EcJ2kodAg+gJL+nR1t1+KEofNmsDq/wDdv2iAQ/ubUzyXhr4EEZcJ1hyCmSjSv2sOQFpGUj249Mycj8G8XmzRRo+pt3Y2HTVToZn1XiqOZVHvaiY=";

    /// secret 密钥加密的「不是数组」内容（明文 `{"not":"array"}`，openssl 生成）
    const UPSTREAM_SECRET_PW_CORRUPT: &str = "n3SSLeZ151zzmXMyJIF6ow==";

    /// 清空 cookies 与全部 caches（批17a 用例隔离用）
    fn clear_cookie_and_cache_tables() {
        with_database(|db| {
            let conn = db.connection();
            conn.execute("DELETE FROM cookies", [])
                .map_err(|e| LegadoError::Database(format!("清空 cookies 失败: {e}")))?;
            conn.execute("DELETE FROM caches", [])
                .map_err(|e| LegadoError::Database(format!("清空 caches 失败: {e}")))?;
            Ok::<(), LegadoError>(())
        })
        .unwrap();
    }

    /// cookie 串按键集合比较辅助（HashMap / jar 内部序不保证，比对按键集合）
    fn sorted_cookie_parts(s: &str) -> Vec<String> {
        let mut parts: Vec<String> = s
            .split(';')
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty())
            .collect();
        parts.sort();
        parts
    }

    /// Cookie 合并逐条对齐原版 `CookieStore.mergeCookieValues`（P3-2）
    ///
    /// 覆盖：空旧值原样返回；**插入序保留**（旧实现按键排序的本地偏离已删除）；
    /// 同名键位置保留值覆盖；空白值丢弃；字面量 `"null"` 保留；无 `=` 段跳过；
    /// **本地加固**：空键丢弃（上游会产出 `=value`）。
    #[test]
    fn test_merge_cookie_values_aligned_with_upstream() {
        // 空旧值：原样返回（上游 `if (oldCookie.isEmpty()) return cookie`）
        assert_eq!(merge_cookie_values("", "b=2; a=1"), "b=2; a=1");
        // 插入序保留（非字典序）
        assert_eq!(merge_cookie_values("b=2; a=1", ""), "b=2; a=1");
        // 同名键位置保留、值覆盖；异名键尾随
        assert_eq!(merge_cookie_values("a=1; b=2", "b=3; c=4"), "a=1; b=3; c=4");
        assert_eq!(
            merge_cookie_values("sid=old; keep=1", "sid=abc; theme=dark"),
            "sid=abc; keep=1; theme=dark"
        );
        // 空白值丢弃，旧值保留（上游 isNotBlank 判定）
        assert_eq!(merge_cookie_values("a=1", "a="), "a=1");
        assert_eq!(merge_cookie_values("a=1", "b=  "), "a=1");
        // 字面量 "null" 是有效值（上游特意豁免）
        assert_eq!(merge_cookie_values("", "a=null"), "a=null");
        assert_eq!(merge_cookie_values("a=1", "a=null"), "a=null");
        // 无 `=` 段跳过；空键丢弃（本地加固）
        assert_eq!(merge_cookie_values("a=1", "flag; =v"), "a=1");
        assert_eq!(merge_cookie_values("a=1", "a=2; junk"), "a=2");
    }

    /// inspect：本应用 JSON 备份无需密码
    #[test]
    fn test_backup_inspect_json_backup() {
        let (dir, path) = write_json_backup_file(
            "legado_inspect_json",
            "own.json",
            r#"{"version":4,"books":[]}"#,
        );
        let result: serde_json::Value =
            serde_json::from_str(&backup_inspect(&path).unwrap()).unwrap();
        assert_eq!(result["format"], "json");
        assert_eq!(result["passwordRequired"], false);
        assert_eq!(result["passwordProtectedFiles"], serde_json::json!([]));
        let _ = fs::remove_dir_all(&dir);
    }

    /// inspect：不支持的文件格式 → 明确错误
    #[test]
    fn test_backup_inspect_rejects_unsupported_format() {
        let dir = std::env::temp_dir().join("legado_inspect_unsupported");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("notes.txt");
        fs::write(&path, "hello").unwrap();
        let err = backup_inspect(path.to_str().unwrap()).unwrap_err();
        assert!(
            err.to_string().contains("不支持的备份格式"),
            "应返回统一可读错误: {err}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    /// inspect：zip 各形态（空密码可解 / 需要密码 / 明文 / 损坏）
    #[test]
    fn test_backup_inspect_zip_variants() {
        let _db_guard = crate::db_state::ensure_test_db();

        // ① 空密码加密的 servers.json（原版未设密码形态）→ 无需密码
        let (dir1, path1) = write_upstream_backup_zip(
            "legado_inspect_empty_pw",
            &[("servers.json", UPSTREAM_EMPTY_PW_SERVERS.as_bytes())],
        );
        let r1: serde_json::Value = serde_json::from_str(&backup_inspect(&path1).unwrap()).unwrap();
        assert_eq!(r1["format"], "zip");
        assert_eq!(r1["passwordRequired"], false, "空密码可解: {r1}");
        assert_eq!(r1["passwordProtectedFiles"], serde_json::json!([]));
        let _ = fs::remove_dir_all(&dir1);

        // ② secret 密码的 servers.json → 需要密码
        let (dir2, path2) = write_upstream_backup_zip(
            "legado_inspect_secret_servers",
            &[("servers.json", UPSTREAM_SECRET_PW_SERVERS.as_bytes())],
        );
        let r2: serde_json::Value = serde_json::from_str(&backup_inspect(&path2).unwrap()).unwrap();
        assert_eq!(r2["passwordRequired"], true, "{r2}");
        assert_eq!(
            r2["passwordProtectedFiles"],
            serde_json::json!(["servers.json"])
        );
        let _ = fs::remove_dir_all(&dir2);

        // ③ secret 密码的 cookies + runtime → 两个文件都列出（固定顺序）
        let (dir3, path3) = write_upstream_backup_zip(
            "legado_inspect_secret_cookies_runtime",
            &[
                ("cookies.json", UPSTREAM_SECRET_PW_COOKIES.as_bytes()),
                (
                    "runtimeSourceCache.json",
                    UPSTREAM_SECRET_PW_RUNTIME.as_bytes(),
                ),
            ],
        );
        let r3: serde_json::Value = serde_json::from_str(&backup_inspect(&path3).unwrap()).unwrap();
        assert_eq!(r3["passwordRequired"], true, "{r3}");
        assert_eq!(
            r3["passwordProtectedFiles"],
            serde_json::json!(["cookies.json", "runtimeSourceCache.json"])
        );
        let _ = fs::remove_dir_all(&dir3);

        // ④ 全明文数组 → 无需密码
        let (dir4, path4) = write_upstream_backup_zip(
            "legado_inspect_plaintext",
            &[
                ("servers.json", b"[]"),
                ("cookies.json", b"[]"),
                ("runtimeSourceCache.json", b"[]"),
            ],
        );
        let r4: serde_json::Value = serde_json::from_str(&backup_inspect(&path4).unwrap()).unwrap();
        assert_eq!(r4["passwordRequired"], false, "{r4}");
        let _ = fs::remove_dir_all(&dir4);

        // ⑤ 以 { 开头的对象 / 非法数组 → 损坏，不要求密码
        let (dir5, path5) = write_upstream_backup_zip(
            "legado_inspect_corrupt",
            &[
                ("servers.json", br#"{"not":"array"}"#),
                ("cookies.json", b"[1,"),
            ],
        );
        let r5: serde_json::Value = serde_json::from_str(&backup_inspect(&path5).unwrap()).unwrap();
        assert_eq!(r5["passwordRequired"], false, "损坏内容不应要求密码: {r5}");
        assert_eq!(r5["passwordProtectedFiles"], serde_json::json!([]));
        let _ = fs::remove_dir_all(&dir5);

        // ⑥ P3-3：空 / 纯空白条目 → 损坏（不要求密码）。空内容不可能被任何
        // 密码解开，判 Protected 会让 UI 弹一个永远失败的密码框
        let (dir6, path6) = write_upstream_backup_zip(
            "legado_inspect_blank_entries",
            &[
                ("cookies.json", b""),
                ("runtimeSourceCache.json", b"   \n\t"),
            ],
        );
        let r6: serde_json::Value = serde_json::from_str(&backup_inspect(&path6).unwrap()).unwrap();
        assert_eq!(r6["passwordRequired"], false, "空条目不应要求密码: {r6}");
        assert_eq!(r6["passwordProtectedFiles"], serde_json::json!([]));
        // 恢复侧空文件仍报 CORRUPT（口径保持）：不落库、不弹密码框
        let err = backup_restore_with_password(&path6, None).unwrap_err();
        assert!(
            err.to_string()
                .contains(BACKUP_ENCRYPTED_CONTENT_CORRUPT_PREFIX),
            "空 cookies.json 恢复必须是 CORRUPT 错误: {err}"
        );
        let _ = fs::remove_dir_all(&dir6);
    }

    /// 正确密码：servers + cookies + runtime 全部恢复（含域名合并与精确 deadline）
    #[test]
    fn test_restore_zip_with_password_restores_servers_cookies_runtime() {
        // 全局锁序不变式：先 store 锁、后池锁、再 DB 守卫（恢复后重建共享客户端，
        // 与池触碰测试互斥——见 test_support 模块文档）
        let _gs = crate::test_support::lock_global_store();
        let _p = crate::test_support::lock_pool_tests();
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        clear_cookie_and_cache_tables();

        // 预置同域 Cookie：sid 应被备份值覆盖，keep 保留
        let url = "https://cookie.secret.example.com";
        let domain = crate::api::net_api::get_sub_domain(url);
        with_database(|db| {
            CookieRepository::new(db.connection()).upsert(&domain, "sid=old; keep=1")
        })
        .unwrap();

        let bookshelf =
            r#"[{"bookUrl":"https://zip.example/pw-book","name":"密码包书","author":"作者"}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_with_password",
            &[
                ("bookshelf.json", bookshelf.as_bytes()),
                ("servers.json", UPSTREAM_SECRET_PW_SERVERS.as_bytes()),
                ("cookies.json", UPSTREAM_SECRET_PW_COOKIES.as_bytes()),
                (
                    "runtimeSourceCache.json",
                    UPSTREAM_SECRET_PW_RUNTIME.as_bytes(),
                ),
            ],
        );

        let stats: RestoreStats =
            serde_json::from_str(&backup_restore_with_password(&path, Some("secret")).unwrap())
                .unwrap();
        assert_eq!(stats.books, 1, "其余表照常恢复");

        let servers =
            with_database(|db| ServerRepository::new(db.connection()).find_all()).unwrap();
        assert_eq!(servers.len(), 1, "servers.json 应解密恢复");
        assert_eq!(servers[0].id, 1);
        assert_eq!(servers[0].name, "加密服务器");

        with_database(|db| {
            let repo = CookieRepository::new(db.connection());
            // 域名行：同域合并，sid 新值胜，keep 保留（插入序，P3-2 对齐上游）
            assert_eq!(
                repo.get_by_tag(&domain).unwrap().as_deref(),
                Some("sid=abc; keep=1; theme=dark")
            );
            // `|` 主键行原样 upsert
            assert_eq!(
                repo.get_by_tag("source|https://x.example.com")
                    .unwrap()
                    .as_deref(),
                Some("k=v")
            );
            assert_eq!(repo.count().unwrap(), 2, "合并不得新增域名行");
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        with_database(|db| {
            let conn = db.connection();
            let (value, deadline): (String, i64) = conn
                .query_row(
                    "SELECT value, deadline FROM caches WHERE key = ?1",
                    rusqlite::params!["v_https://runtime.secret.example.com/source_token"],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .unwrap();
            assert_eq!(value, "tok");
            assert_eq!(deadline, 0);
            let (value, deadline): (String, i64) = conn
                .query_row(
                    "SELECT value, deadline FROM caches WHERE key = ?1",
                    rusqlite::params!["userInfo_https://runtime.secret.example.com/source"],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .unwrap();
            assert_eq!(value, "", "null 值落库归一为空串");
            assert_eq!(deadline, 4102444800000, "deadline 必须精确落库");
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// P2-1（批17c）：恢复的 Cookie 必须在**当前进程立即生效**
    ///
    /// 红态：恢复只写 DB，进程内存 CookieStore 仍是旧值；客户端重建时的
    /// 合并预载是「内存值胜」→ 备份值要等重启才生效。恢复后
    /// [`crate::http_state::shared_cookie_store`] 与 `legado-js` 内存 store
    /// 都必须已是备份新值（备份新值胜、库内独有键保留）。
    #[test]
    fn test_restore_zip_cookies_take_effect_in_process_memory() {
        // 全局锁序不变式：先 store 锁、后池锁、再 DB 守卫（见 test_support 文档）
        let _gs = crate::test_support::lock_global_store();
        let _p = crate::test_support::lock_pool_tests();
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        clear_cookie_and_cache_tables();

        const URL: &str = "https://mem-restore-fix.test/";
        let domain = crate::api::net_api::get_sub_domain(URL);

        // 恢复前进程态：DB + 内存都是旧值（模拟「已登录，进程运行中恢复」）
        with_database(|db| {
            CookieRepository::new(db.connection()).upsert(&domain, "sid=old; keep=1")
        })
        .unwrap();
        {
            let mut store = crate::http_state::shared_cookie_store()
                .write()
                .unwrap_or_else(|p| p.into_inner());
            store.remove_domain(&domain);
            store.set_cookies_from_string(&domain, "sid=old; keep=1");
        }
        legado_js::host_api::cookie_store::set_cookie(URL, "sid", "old");

        let cookies = format!(r#"[{{"url":"{URL}","cookie":"sid=new; theme=dark"}}]"#);
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_mem_cookies",
            &[("cookies.json", cookies.as_bytes())],
        );
        backup_restore_with_password(&path, None).expect("明文 cookies 恢复必须成功");
        let _ = fs::remove_dir_all(&dir);

        // FFI 共享内存 store：备份值必须立即可见（无需重启）
        {
            let store = crate::http_state::shared_cookie_store()
                .read()
                .unwrap_or_else(|p| p.into_inner());
            assert_eq!(
                store.get_key(&domain, "sid").as_deref(),
                Some("new"),
                "恢复后共享内存 Cookie 必须立即是新值（P2-1 红态：仍是 old）"
            );
            assert_eq!(
                store.get_key(&domain, "keep").as_deref(),
                Some("1"),
                "同名键合并：库内异名键必须保留"
            );
            assert_eq!(
                store.get_key(&domain, "theme").as_deref(),
                Some("dark"),
                "备份新增键必须在内存可见"
            );
        }

        // legado-js 侧内存 store（java.ajax 读侧）：同样必须立即生效
        let js_cookie = legado_js::host_api::cookie_store::get_cookie(URL);
        assert!(
            js_cookie.contains("sid=new") && !js_cookie.contains("sid=old"),
            "JS 内存 store 必须同步为备份新值: {js_cookie}"
        );

        // 收尾：两侧齐清（避免污染其他 cookie 用例）
        crate::api::net_api::clear_cookie(URL).expect("清理 Cookie 必须成功");
        legado_js::host_api::cookie_store::clear_cookies(URL);
        clear_cookie_and_cache_tables();
    }

    /// 批17d P2：Cookie 恢复与 jar「捕获 → 落库」的并发交错不得回滚备份值
    ///
    /// 复现口径对齐真实 jar 写回路径（`legado-net::client::save_cookies_from_response`
    /// 的锁序 D → 写内存并捕获整域串（释放 S）→ 持 D 取 C 落库）：jar 线程在
    /// 持 D 完成捕获后短暂停住（模拟被调度走），主线程在此窗口内发起恢复。
    ///
    /// **红态（修复前，恢复侧只持 C）**：恢复读库看不到 jar 刚捕获、尚未落库
    /// 的新值 → 合并结果覆盖内存；jar 随后以旧视图「incoming 胜」落库 →
    /// 备份值被回滚为 `sid=old`、内存与 DB 分叉、`jar=m1` 在内存丢失。
    ///
    /// **绿态（恢复侧先取 D 再取 C，D→C→P→S/G）**：恢复与 jar 的「捕获 +
    /// 落库」整体互斥，二者严格串行 → 最终 DB / FFI 内存 / JS 内存三者一致；
    /// 备份值不被回滚（jar 先行时恢复在后，同名键按「后写胜」= 备份值胜），
    /// jar 的异名新键 `jar=m1` 保留。
    #[test]
    fn test_restore_cookies_concurrent_jar_write_no_rollback() {
        // 全局锁序不变式：先 store 锁、后池锁、再 DB 守卫（见 test_support 文档）
        let _gs = crate::test_support::lock_global_store();
        let _p = crate::test_support::lock_pool_tests();
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        clear_cookie_and_cache_tables();

        use legado_net::CookiePersistence;
        use std::sync::{Arc, Condvar, Mutex};
        use std::time::Duration;

        const URL: &str = "https://race-restore.test/";
        let domain = crate::api::net_api::get_sub_domain(URL);

        // 恢复前：DB / FFI 内存 / JS 内存都是 "sid=old; keep=1"（模拟已登录进程）
        with_database(|db| {
            CookieRepository::new(db.connection()).upsert(&domain, "sid=old; keep=1")
        })
        .unwrap();
        {
            let mut store = crate::http_state::shared_cookie_store()
                .write()
                .unwrap_or_else(|p| p.into_inner());
            store.remove_domain(&domain);
            store.set_cookies_from_string(&domain, "sid=old; keep=1");
        }
        legado_js::host_api::cookie_store::set_cookie(URL, "sid", "old");
        legado_js::host_api::cookie_store::set_cookie(URL, "keep", "1");

        // 备份值：sid/theme（sid 与库内同名 → 备份胜；theme 为新增键）
        let cookies = format!(r#"[{{"url":"{URL}","cookie":"sid=new; theme=dark"}}]"#);
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_race_cookies",
            &[("cookies.json", cookies.as_bytes())],
        );

        let captured = Arc::new((Mutex::new(false), Condvar::new()));
        let jar_captured = Arc::clone(&captured);
        let domain_for_jar = domain.clone();
        let jar = std::thread::spawn(move || {
            // ① D：真实 jar 路径的最外层（与恢复的按域写通道互斥）
            let _d = legado_net::cookie_store::domain_write_lock(&domain_for_jar);
            // ② 写内存（Set-Cookie 生效）
            {
                let mut store = crate::http_state::shared_cookie_store()
                    .write()
                    .unwrap_or_else(|p| p.into_inner());
                store.set_cookies_from_string(&domain_for_jar, "jar=m1");
            }
            // ③ 捕获整域串（jar 锁已释放，D 仍持有）
            let view = crate::http_state::shared_cookie_store()
                .read()
                .unwrap_or_else(|p| p.into_inner())
                .domain_cookie_string(&domain_for_jar);
            // ④ 捕获完成、尚未落库：通知主线程在此窗口发起恢复
            {
                let (lock, cv) = &*jar_captured;
                *lock.lock().unwrap_or_else(|p| p.into_inner()) = true;
                cv.notify_all();
            }
            // 模拟「捕获后被调度走」的窗口（红态下恢复即在此进入 C）
            std::thread::sleep(Duration::from_millis(200));
            // ⑤ C+P 落库（真实 jar 在 D 内取 C；incoming 胜）
            crate::http_state::DbCookiePersistence.save(&domain_for_jar, &view);
        });

        // 等 jar 完成捕获（未落库）后再发起恢复
        {
            let (lock, cv) = &*captured;
            let mut ready = lock.lock().unwrap_or_else(|p| p.into_inner());
            while !*ready {
                let (guard, timeout) = cv
                    .wait_timeout(ready, Duration::from_secs(5))
                    .unwrap_or_else(|p| p.into_inner());
                assert!(!timeout.timed_out(), "jar 线程未在超时前完成捕获");
                ready = guard;
            }
        }

        backup_restore_with_password(&path, None).expect("恢复必须成功");
        jar.join().expect("jar 线程不得 panic");
        let _ = fs::remove_dir_all(&dir);

        // 最终态：DB 行 = 两侧内存（三条断言共同证明「串行化后无分叉」）
        let db_row = with_database(|db| CookieRepository::new(db.connection()).get_by_tag(&domain))
            .unwrap()
            .expect("合并后域名行必须存在");
        let parts = sorted_cookie_parts(&db_row);
        assert!(
            parts.contains(&"sid=new".to_string()),
            "备份值不得被 jar 旧视图回滚（红态：sid=old）: {db_row}"
        );
        assert!(
            parts.contains(&"jar=m1".to_string()),
            "jar 新键不得丢失: {db_row}"
        );
        assert!(
            parts.contains(&"keep=1".to_string()),
            "库内异名键必须保留: {db_row}"
        );
        assert!(
            parts.contains(&"theme=dark".to_string()),
            "备份新键必须落库: {db_row}"
        );
        let memory = crate::http_state::shared_cookie_store()
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .domain_cookie_string(&domain);
        assert_eq!(
            sorted_cookie_parts(&memory),
            parts,
            "FFI 内存必须与 DB 一致（红态：内存无 jar=m1）: {memory}"
        );
        let js_cookie = legado_js::host_api::cookie_store::get_cookie(URL);
        assert_eq!(
            sorted_cookie_parts(&js_cookie),
            parts,
            "JS 内存必须与 DB 一致（红态：内存无 jar=m1）: {js_cookie}"
        );

        // 收尾：两侧齐清（避免污染其他 cookie 用例）
        crate::api::net_api::clear_cookie(URL).expect("清理 Cookie 必须成功");
        legado_js::host_api::cookie_store::clear_cookies(URL);
        clear_cookie_and_cache_tables();
    }

    /// 批17d P3-3：默认（无 quickjs）档同域多 URL 必须逐个覆盖 JS 内存键
    ///
    /// 默认档 JS 键空间是「trim 原始 URL 串」，同域不同 URL = 不同键。旧实现
    /// 按库内域键去重时只记首个 URL 的 JS 键 → 第二个 URL 的内存条目保持旧值
    /// （重启前经 `java.getCookie(第二个URL)` 仍读到旧串）。修复后按域收集
    /// 全部 JS 键并逐键覆盖同一份最终合并串。
    ///
    /// quickjs 档两个 URL 归一为同一 ETLD+1 键（本用例同样通过）。
    #[test]
    fn test_restore_cookies_covers_every_js_key_of_same_domain() {
        // 全局锁序不变式：先 store 锁、后池锁、再 DB 守卫（见 test_support 文档）
        let _gs = crate::test_support::lock_global_store();
        let _p = crate::test_support::lock_pool_tests();
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        clear_cookie_and_cache_tables();

        const URL_A: &str = "https://multi-url.test/a";
        const URL_B: &str = "https://multi-url.test/b";
        let domain = crate::api::net_api::get_sub_domain(URL_A);

        // 两个 URL 的 JS 内存条目都是旧值（默认档两键不同名）
        legado_js::host_api::cookie_store::set_cookie(URL_A, "sid", "old");
        legado_js::host_api::cookie_store::set_cookie(URL_B, "sid", "old");

        let cookies = format!(
            r#"[{{"url":"{URL_A}","cookie":"sid=new"}},{{"url":"{URL_B}","cookie":"sid=new"}}]"#
        );
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_multi_url_cookies",
            &[("cookies.json", cookies.as_bytes())],
        );
        backup_restore_with_password(&path, None).expect("恢复必须成功");
        let _ = fs::remove_dir_all(&dir);

        let db_row = with_database(|db| CookieRepository::new(db.connection()).get_by_tag(&domain))
            .unwrap()
            .expect("域名行必须存在");
        assert_eq!(sorted_cookie_parts(&db_row), vec!["sid=new".to_string()]);
        for url in [URL_A, URL_B] {
            let js_cookie = legado_js::host_api::cookie_store::get_cookie(url);
            assert_eq!(
                sorted_cookie_parts(&js_cookie),
                vec!["sid=new".to_string()],
                "{url} 的 JS 内存键必须同步为新值（红态：仍为 sid=old）: {js_cookie}"
            );
        }

        // 收尾
        crate::api::net_api::clear_cookie(URL_A).expect("清理 Cookie 必须成功");
        legado_js::host_api::cookie_store::clear_cookies(URL_A);
        legado_js::host_api::cookie_store::clear_cookies(URL_B);
        clear_cookie_and_cache_tables();
    }

    /// 错误密码：零落库（哨兵行保留）且返回 BACKUP_PASSWORD_INVALID
    #[test]
    fn test_restore_zip_wrong_password_zero_writes() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        clear_cookie_and_cache_tables();

        with_database(|db| {
            let conn = db.connection();
            BookRepository::new(conn).insert(&Book {
                book_url: "https://zip.example/sentinel-pw".to_string(),
                name: "哨兵书".to_string(),
                author: "哨兵".to_string(),
                ..Book::default()
            })?;
            CookieRepository::new(conn).upsert("keep.example.com", "keep=1")?;
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let bookshelf =
            r#"[{"bookUrl":"https://zip.example/wrong-pw","name":"错密码书","author":"作者"}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_wrong_password",
            &[
                ("bookshelf.json", bookshelf.as_bytes()),
                ("servers.json", UPSTREAM_SECRET_PW_SERVERS.as_bytes()),
                ("cookies.json", UPSTREAM_SECRET_PW_COOKIES.as_bytes()),
            ],
        );

        let err = backup_restore_with_password(&path, Some("wrong")).unwrap_err();
        assert!(
            err.to_string().contains(BACKUP_PASSWORD_INVALID_PREFIX),
            "应返回 BACKUP_PASSWORD_INVALID: {err}"
        );

        with_database(|db| {
            let conn = db.connection();
            let books = BookRepository::new(conn).find_all()?;
            assert_eq!(books.len(), 1, "哨兵书应保留（零落库）: {books:?}");
            assert_eq!(books[0].book_url, "https://zip.example/sentinel-pw");
            let cookies = CookieRepository::new(conn).find_all()?;
            assert_eq!(cookies.len(), 1, "Cookie 不得写入: {cookies:?}");
            assert_eq!(cookies[0].0, "keep.example.com");
            let servers = ServerRepository::new(conn).find_all()?;
            assert!(servers.is_empty(), "servers 不得写入");
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }

    /// 仅 servers 加密 + 错密码 → BACKUP_PASSWORD_INVALID（零落库）
    #[test]
    fn test_restore_zip_servers_only_wrong_password_invalid() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        let bookshelf =
            r#"[{"bookUrl":"https://zip.example/only-servers","name":"仅服务器","author":"作者"}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_servers_only_wrong_pw",
            &[
                ("bookshelf.json", bookshelf.as_bytes()),
                ("servers.json", UPSTREAM_SECRET_PW_SERVERS.as_bytes()),
            ],
        );

        let err = backup_restore_with_password(&path, Some("wrong")).unwrap_err();
        assert!(
            err.to_string().contains(BACKUP_PASSWORD_INVALID_PREFIX),
            "唯一加密候选解不开即密码错误: {err}"
        );
        let books = with_database(|db| BookRepository::new(db.connection()).find_all()).unwrap();
        assert!(books.is_empty(), "不得发生部分恢复: {books:?}");

        let _ = fs::remove_dir_all(&dir);
    }

    /// 混合包：servers 密文 + cookies 明文 → 提供密码后两者都恢复
    #[test]
    fn test_restore_zip_mixed_encrypted_servers_and_plain_cookies() {
        // 同上：Cookie 恢复会重建共享客户端，需持池锁串行
        let _gs = crate::test_support::lock_global_store();
        let _p = crate::test_support::lock_pool_tests();
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        clear_cookie_and_cache_tables();

        let plain_cookies = r#"[{"url":"https://plain-cookie.example.com","cookie":"a=1; b=2"}]"#;
        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_mixed",
            &[
                ("servers.json", UPSTREAM_SECRET_PW_SERVERS.as_bytes()),
                ("cookies.json", plain_cookies.as_bytes()),
            ],
        );

        let stats: RestoreStats =
            serde_json::from_str(&backup_restore_with_password(&path, Some("secret")).unwrap())
                .unwrap();
        assert_eq!(stats.books, 0);
        let servers =
            with_database(|db| ServerRepository::new(db.connection()).find_all()).unwrap();
        assert_eq!(servers.len(), 1, "密文 servers 应恢复");
        let domain = crate::api::net_api::get_sub_domain("https://plain-cookie.example.com");
        let cookie =
            with_database(|db| CookieRepository::new(db.connection()).get_by_tag(&domain)).unwrap();
        assert_eq!(cookie.as_deref(), Some("a=1; b=2"), "明文 cookies 应恢复");

        let _ = fs::remove_dir_all(&dir);
    }

    /// 中文密码 / 纯空格密码（不 trim）恢复 servers
    #[test]
    fn test_restore_zip_chinese_and_space_passwords() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();

        // 中文密码
        let (dir_zh, path_zh) = write_upstream_backup_zip(
            "legado_restore_zip_zh_password",
            &[("servers.json", UPSTREAM_ZH_PW_SERVERS.as_bytes())],
        );
        assert!(backup_restore_with_password(&path_zh, Some("密码")).is_ok());
        let servers =
            with_database(|db| ServerRepository::new(db.connection()).find_all()).unwrap();
        assert_eq!(servers.len(), 1);
        assert_eq!(servers[0].name, "中文密码服务器");
        let _ = fs::remove_dir_all(&dir_zh);

        // 纯空格密码（三个空格）；两个空格是错误密码（证明不 trim）
        clear_backup_tables();
        let (dir_sp, path_sp) = write_upstream_backup_zip(
            "legado_restore_zip_space_password",
            &[("servers.json", UPSTREAM_SPACE_PW_SERVERS.as_bytes())],
        );
        let err = backup_restore_with_password(&path_sp, Some("  ")).unwrap_err();
        assert!(
            err.to_string().contains(BACKUP_PASSWORD_INVALID_PREFIX),
            "密码不得 trim（两空格应判错）: {err}"
        );
        assert!(backup_restore_with_password(&path_sp, Some("   ")).is_ok());
        let servers =
            with_database(|db| ServerRepository::new(db.connection()).find_all()).unwrap();
        assert_eq!(servers.len(), 1);
        assert_eq!(servers[0].name, "空格密码服务器");
        let _ = fs::remove_dir_all(&dir_sp);
    }

    /// 加密 cookies 解密成功但内容不是数组 → BACKUP_ENCRYPTED_CONTENT_CORRUPT（零落库）
    #[test]
    fn test_restore_zip_corrupt_encrypted_cookies() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_backup_tables();
        clear_cookie_and_cache_tables();

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: "https://zip.example/corrupt-sentinel".to_string(),
                name: "损坏哨兵".to_string(),
                author: "哨兵".to_string(),
                ..Book::default()
            })
        })
        .unwrap();

        let (dir, path) = write_upstream_backup_zip(
            "legado_restore_zip_corrupt_cookies",
            &[
                ("cookies.json", UPSTREAM_SECRET_PW_CORRUPT.as_bytes()),
                ("servers.json", UPSTREAM_SECRET_PW_SERVERS.as_bytes()),
            ],
        );

        let err = backup_restore_with_password(&path, Some("secret")).unwrap_err();
        assert!(
            err.to_string()
                .contains(BACKUP_ENCRYPTED_CONTENT_CORRUPT_PREFIX),
            "应返回 BACKUP_ENCRYPTED_CONTENT_CORRUPT: {err}"
        );
        assert!(err.to_string().contains("cookies.json"), "{err}");

        with_database(|db| {
            let conn = db.connection();
            let books = BookRepository::new(conn).find_all()?;
            assert_eq!(books.len(), 1, "哨兵行应保留（零落库）");
            let servers = ServerRepository::new(conn).find_all()?;
            assert!(servers.is_empty(), "损坏校验必须先于任何落库");
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let _ = fs::remove_dir_all(&dir);
    }
}
