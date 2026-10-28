//! 高亮体系 FFI API
//!
//! 暴露正文高亮（highlights 表）与高亮规则（highlightRules 表）的 CRUD 能力，
//! 通过 JSON 序列化传参，遵循项目「复杂类型 FFI 用 JSON」决策。
//!
//! 对应 Android 原版 `BookHighlightDao` / `HighlightRuleDao`。

use std::collections::HashMap;
use std::time::{Duration, Instant};

use legado_core::models::{BookHighlight, HighlightRule};
use legado_core::{LegadoError, LegadoResult};
use legado_db::{HighlightRepository, HighlightRuleRepository};
use serde::Serialize;

use crate::db_state::with_database;

/// 单次高亮匹配允许的最大文本字节数（1 MiB，防 ReDoS/内存放大）
pub const MAX_MATCH_TEXT_BYTES: usize = 1024 * 1024;

/// 单次高亮匹配整体截止时间（5s）
pub const MATCH_TIMEOUT: Duration = Duration::from_secs(5);

/// 默认最大命中数（对齐原版 `HighlightRuleMatcher.DEFAULT_MAX_MATCHES`）
pub const DEFAULT_MAX_MATCHES: usize = 10_000;

/// 单条规则超时上限（毫秒，防单规则长超时）
const RULE_TIMEOUT_MAX_MILLIS: i64 = 5_000;

// ─── 高亮记录 CRUD ────────────────────────────────────────────

/// 新增/更新高亮记录（INSERT OR REPLACE，主键为 time）
///
/// `highlight_json` 为 BookHighlight JSON。
/// time 为 0 时自动分配当前 Unix 毫秒时间戳。返回保存后的 time。
pub fn highlight_add(highlight_json: &str) -> LegadoResult<i64> {
    let mut highlight: BookHighlight = serde_json::from_str(highlight_json)
        .map_err(|e| LegadoError::Parser(format!("解析高亮 JSON 失败: {e}")))?;
    let auto_time = highlight.time == 0;
    if auto_time {
        highlight.time = current_time_millis();
    }
    with_database(|db| {
        let repo = HighlightRepository::new(db.connection());
        // 自动分配 time 时若与已有记录撞主键（同一毫秒多次新增），向后顺延
        if auto_time {
            while repo.find_by_time(highlight.time)?.is_some() {
                highlight.time += 1;
            }
        }
        repo.insert(&highlight)?;
        Ok(highlight.time)
    })
}

/// 按主键 time 删除高亮记录，返回是否实际删除
pub fn highlight_delete(time: i64) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = HighlightRepository::new(db.connection());
        repo.delete(time)
    })
}

/// 按书籍删除全部高亮记录，返回删除数量
pub fn highlight_delete_by_book(book_url: &str) -> LegadoResult<i64> {
    with_database(|db| {
        let repo = HighlightRepository::new(db.connection());
        repo.delete_by_book(book_url)
    })
}

/// 按书籍获取高亮列表（按 chapterIndex/chapterPos/time 排序）
pub fn highlight_list_by_book(book_url: &str) -> LegadoResult<Vec<BookHighlight>> {
    with_database(|db| {
        let repo = HighlightRepository::new(db.connection());
        repo.get_by_book(book_url)
    })
}

/// 按书籍 + 章节索引获取高亮列表
pub fn highlight_list_by_chapter(
    book_url: &str,
    chapter_index: i32,
) -> LegadoResult<Vec<BookHighlight>> {
    with_database(|db| {
        let repo = HighlightRepository::new(db.connection());
        repo.get_by_chapter(book_url, chapter_index)
    })
}

/// 全局关键词搜索高亮（匹配 chapterName/bookText/note）
pub fn highlight_search(keyword: &str) -> LegadoResult<Vec<BookHighlight>> {
    with_database(|db| {
        let repo = HighlightRepository::new(db.connection());
        repo.search(keyword)
    })
}

/// 获取所有高亮记录（按书名/作者/章节/位置排序）
pub fn highlight_list_all() -> LegadoResult<Vec<BookHighlight>> {
    with_database(|db| {
        let repo = HighlightRepository::new(db.connection());
        repo.find_all()
    })
}

// ─── 高亮规则 CRUD ────────────────────────────────────────────

/// 获取所有高亮规则（按 sortOrder 升序）
pub fn highlight_rule_list() -> LegadoResult<Vec<HighlightRule>> {
    with_database(|db| {
        let repo = HighlightRuleRepository::new(db.connection());
        repo.find_all()
    })
}

/// 保存高亮规则（新增或按 ID 覆盖），返回规则 ID
///
/// `rule_json` 为 HighlightRule JSON；id 为 0 时使用自增主键新增。
///
/// 批28b（P3-3）：保存前只规整 `group`（trim→null），与导入/恢复口径一致；
/// **不**调用完整 `normalize_for_restore`——编辑保存不得重新生成 uuid
/// （规则身份需稳定），缺失 uuid 仍由 serde 默认值兜底。
pub fn highlight_rule_save(rule_json: &str) -> LegadoResult<i64> {
    let mut rule: HighlightRule = serde_json::from_str(rule_json)
        .map_err(|e| LegadoError::Parser(format!("解析高亮规则 JSON 失败: {e}")))?;
    rule.normalize_group();
    with_database(|db| {
        let repo = HighlightRuleRepository::new(db.connection());
        repo.insert(&rule)
    })
}

/// 按 ID 删除高亮规则，返回是否实际删除
pub fn highlight_rule_delete(id: i64) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = HighlightRuleRepository::new(db.connection());
        repo.delete(id)
    })
}

/// 按书籍查找启用的高亮规则（scope 匹配书名或书源名，空 scope 全局生效）
pub fn highlight_rule_find_enabled(
    book_name: &str,
    origin: &str,
) -> LegadoResult<Vec<HighlightRule>> {
    with_database(|db| {
        let repo = HighlightRuleRepository::new(db.connection());
        repo.find_enabled_by_book(book_name, origin)
    })
}

/// 当前 Unix 毫秒时间戳
fn current_time_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ─── 高亮规则正文匹配（批34） ────────────────────────────────

/// 单条高亮命中（FFI JSON 输出，字段名即契约字段名）
#[derive(Debug, Clone, PartialEq, Serialize)]
#[allow(non_snake_case)] // FFI JSON 字段名为 camelCase
pub struct HighlightRuleMatch {
    /// 命中规则 ID
    pub ruleId: i64,
    /// 命中起点（UTF-16 code unit，闭区间端点）
    pub start: i64,
    /// 命中终点（UTF-16 code unit，开区间端点）
    pub end: i64,
    /// 规则排序值（sortOrder，越大优先级越高）
    pub order: i32,
    /// 规则 style JSON 原文（未知键原样保留，Dart 侧解析）
    pub styleJson: String,
}

/// 候选命中（内部使用，字节偏移）
struct Candidate {
    start: usize,
    end: usize,
    rule_index: usize,
    /// 收集序号（同优先级时先命中者胜）
    seq: usize,
}

/// 已接受的互不重叠区间（按 start 升序）
struct Accepted {
    start: usize,
    end: usize,
    rule_index: usize,
}

/// 按启用高亮规则匹配正文
///
/// 语义见 `docs/API_CONTRACT.md` §2.36 批34 注：
/// - 只取启用且 scope 匹配的规则，再按 `apply_to_title` 选侧过滤；
/// - 字面量非重叠查找；正则走 Java 方言适配 + 安全编译，失败 warn 跳过；
/// - 重叠按 `sortOrder` 大者覆盖（同 order 先命中者胜），输出 `(order, start)` 升序；
/// - 返回 UTF-16 code unit 半开区间，`styleJson` 原样透传。
pub fn highlight_rule_match(
    text: &str,
    book_name: &str,
    origin: &str,
    apply_to_title: bool,
    max_matches: Option<i32>,
) -> LegadoResult<Vec<HighlightRuleMatch>> {
    if text.len() > MAX_MATCH_TEXT_BYTES {
        return Err(LegadoError::Parser(format!(
            "正文超过高亮匹配上限（{} 字节 > {} 字节）",
            text.len(),
            MAX_MATCH_TEXT_BYTES
        )));
    }
    let limit = match max_matches {
        Some(n) => n.max(0) as usize,
        None => DEFAULT_MAX_MATCHES,
    };
    if text.is_empty() || limit == 0 {
        return Ok(Vec::new());
    }

    let mut rules = with_database(|db| {
        let repo = HighlightRuleRepository::new(db.connection());
        repo.find_enabled_by_book(book_name, origin)
    })?;
    // 同 sortOrder 时按 id 稳定排序，保证「同 order 先命中者胜」可复现
    rules.sort_by_key(|r| (r.sortOrder, r.id));
    rules.retain(|r| {
        !r.pattern.is_empty()
            && if apply_to_title {
                r.applyToTitle
            } else {
                r.applyToBody
            }
    });
    if rules.is_empty() {
        return Ok(Vec::new());
    }

    let overall_deadline = Instant::now() + MATCH_TIMEOUT;
    let mut candidates: Vec<Candidate> = Vec::new();
    let mut seq = 0usize;
    let mut timed_out = false;
    // 按优先级从高到低收集（order 降序、同 order 规则 id 升序）：
    // maxMatches 截断候选时优先保住高优先级命中，避免低优先级先占满配额
    let mut collection_order: Vec<usize> = (0..rules.len()).collect();
    collection_order.sort_by(|&a, &b| rules[b].sortOrder.cmp(&rules[a].sortOrder).then(a.cmp(&b)));
    for rule_index in collection_order {
        if candidates.len() >= limit {
            break;
        }
        let rule = &rules[rule_index];
        // 单规则超时取规则自身 timeoutMillisecond（夹取 1..=5s），并受整体截止约束
        let rule_timeout =
            Duration::from_millis(rule.timeoutMillisecond.clamp(1, RULE_TIMEOUT_MAX_MILLIS) as u64);
        let rule_deadline = overall_deadline.min(Instant::now() + rule_timeout);
        let completed = if rule.isRegex {
            collect_regex_matches(
                text,
                rule,
                rule_index,
                rule_deadline,
                limit,
                &mut candidates,
                &mut seq,
            )
        } else {
            collect_literal_matches(
                text,
                &rule.pattern,
                rule_index,
                rule_deadline,
                limit,
                &mut candidates,
                &mut seq,
            )
        };
        if !completed {
            timed_out = true;
            break;
        }
    }
    if timed_out {
        log::warn!(
            "[highlight] 规则匹配超时（整体 {}s / 单规则上限 {}ms），返回已收集 {} 条候选",
            MATCH_TIMEOUT.as_secs(),
            RULE_TIMEOUT_MAX_MILLIS,
            candidates.len()
        );
    }
    if candidates.is_empty() {
        return Ok(Vec::new());
    }

    Ok(resolve_candidates(text, candidates, &rules))
}

/// 字面量非重叠查找；返回是否在截止时间内完成
fn collect_literal_matches(
    text: &str,
    pattern: &str,
    rule_index: usize,
    deadline: Instant,
    limit: usize,
    out: &mut Vec<Candidate>,
    seq: &mut usize,
) -> bool {
    if pattern.is_empty() {
        return true;
    }
    for (start, matched) in text.match_indices(pattern) {
        if out.len() >= limit {
            return true;
        }
        if Instant::now() > deadline {
            return false;
        }
        out.push(Candidate {
            start,
            end: start + matched.len(),
            rule_index,
            seq: *seq,
        });
        *seq += 1;
    }
    true
}

/// 正则查找（非重叠）；返回是否在截止时间内完成
///
/// 双引擎：`regex` crate 编译成功走快速路径；Java 方言（lookbehind/
/// backreference/原子组）回退 `fancy-regex`。两路均经 `legado-core::regex_safe`
/// 统一安全入口（1KB pattern 上限 + 嵌套深度预检 + 隔离线程编译）。
fn collect_regex_matches(
    text: &str,
    rule: &HighlightRule,
    rule_index: usize,
    deadline: Instant,
    limit: usize,
    out: &mut Vec<Candidate>,
    seq: &mut usize,
) -> bool {
    let adapted = legado_core::content_processor::adapt_java_regex(&rule.pattern);
    if let Some(re) = legado_core::compile_regex_safe(&adapted) {
        return collect_with_finder(
            text,
            |pos| Ok(re.find_at(text, pos).map(|m| (m.start(), m.end()))),
            rule_index,
            deadline,
            limit,
            out,
            seq,
        )
        .unwrap_or(true);
    }
    if let Some(re) = legado_core::compile_fancy_regex_safe(&adapted) {
        let result = collect_with_finder(
            text,
            |pos| match re.find_from_pos(text, pos) {
                Ok(found) => Ok(found.map(|m| (m.start(), m.end()))),
                Err(e) => Err(e.to_string()),
            },
            rule_index,
            deadline,
            limit,
            out,
            seq,
        );
        if let Err(e) = &result {
            log::warn!(
                "[highlight] 正则运行失败（规则 {}），跳过该规则: {e}",
                rule.id
            );
        }
        return result.unwrap_or(true);
    }
    log::warn!(
        "[highlight] 无效正则（regex/fancy-regex 均编译失败），跳过该规则，前64字符: {}",
        rule.pattern.chars().take(64).collect::<String>()
    );
    true
}

/// 通用正则遍历：`find` 返回下一个匹配的字节半开区间
///
/// 返回 `Ok(completed)` 表示是否在截止时间内完成；`Err` 为运行时错误，
/// 由调用方 warn 并跳过该规则。
fn collect_with_finder<F>(
    text: &str,
    mut find: F,
    rule_index: usize,
    deadline: Instant,
    limit: usize,
    out: &mut Vec<Candidate>,
    seq: &mut usize,
) -> Result<bool, String>
where
    F: FnMut(usize) -> Result<Option<(usize, usize)>, String>,
{
    let mut pos = 0usize;
    while pos <= text.len() {
        if out.len() >= limit {
            return Ok(true);
        }
        if Instant::now() > deadline {
            return Ok(false);
        }
        let Some((start, end)) = find(pos)? else {
            return Ok(true);
        };
        if end > start {
            out.push(Candidate {
                start,
                end,
                rule_index,
                seq: *seq,
            });
            *seq += 1;
            pos = end;
        } else {
            // 零宽匹配：从匹配起点前进一个字符，防死循环
            let advance = text[start..]
                .chars()
                .next()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
            if advance == 0 {
                return Ok(true);
            }
            pos = start + advance;
        }
    }
    Ok(true)
}

/// 重叠区间解析：高 order 覆盖低 order，同 order 先命中者胜，其余截断/跳过
fn resolve_candidates(
    text: &str,
    mut candidates: Vec<Candidate>,
    rules: &[HighlightRule],
) -> Vec<HighlightRuleMatch> {
    // 高优先级先占位；同优先级按收集序号（规则 sortOrder/id 升序 + 规则内命中顺序）
    candidates.sort_by(|a, b| {
        rules[b.rule_index]
            .sortOrder
            .cmp(&rules[a.rule_index].sortOrder)
            .then(a.seq.cmp(&b.seq))
    });

    let mut accepted: Vec<Accepted> = Vec::new();
    for cand in candidates {
        let mut pieces = vec![(cand.start, cand.end)];
        // accepted 按 start 升序且互不重叠；从第一个可能重叠处开始裁剪
        let first = accepted.partition_point(|a| a.end <= cand.start);
        for acc in accepted[first..].iter() {
            if acc.start >= cand.end {
                break;
            }
            let mut next = Vec::with_capacity(pieces.len() + 1);
            for (s, e) in pieces {
                if acc.end <= s || acc.start >= e {
                    next.push((s, e));
                } else {
                    if s < acc.start {
                        next.push((s, acc.start));
                    }
                    if acc.end < e {
                        next.push((acc.end, e));
                    }
                }
            }
            pieces = next;
            if pieces.is_empty() {
                break;
            }
        }
        for (s, e) in pieces {
            let pos = accepted.partition_point(|a| a.start < s);
            accepted.insert(
                pos,
                Accepted {
                    start: s,
                    end: e,
                    rule_index: cand.rule_index,
                },
            );
        }
    }

    // 输出按 (order 升序, start 升序) 稳定排序
    accepted.sort_by(|a, b| {
        rules[a.rule_index]
            .sortOrder
            .cmp(&rules[b.rule_index].sortOrder)
            .then(a.start.cmp(&b.start))
    });

    let offsets = utf16_offset_table(text, &accepted);
    accepted
        .into_iter()
        .map(|a| HighlightRuleMatch {
            ruleId: rules[a.rule_index].id,
            start: offsets[&a.start],
            end: offsets[&a.end],
            order: rules[a.rule_index].sortOrder,
            styleJson: rules[a.rule_index].style.clone(),
        })
        .collect()
}

/// 把已接受区间的字节端点换算为 UTF-16 code unit 偏移
///
/// 单遍扫描：所有端点排序后按字符顺序累加 `len_utf16`，复杂度 O(n + m)。
fn utf16_offset_table(text: &str, accepted: &[Accepted]) -> HashMap<usize, i64> {
    let mut positions: Vec<usize> = accepted.iter().flat_map(|a| [a.start, a.end]).collect();
    positions.sort_unstable();
    positions.dedup();

    let mut table = HashMap::with_capacity(positions.len());
    let mut last = 0usize;
    let mut utf16 = 0i64;
    for pos in positions {
        utf16 += text[last..pos]
            .chars()
            .map(|c| c.len_utf16() as i64)
            .sum::<i64>();
        last = pos;
        table.insert(pos, utf16);
    }
    table
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_highlight_crud_flow() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 新增
        let json = r#"{
            "time": 0,
            "bookUrl": "bk://highlight_test",
            "chapterUrl": "ch://1",
            "bookName": "高亮测试书",
            "bookAuthor": "测试作者",
            "chapterIndex": 2,
            "chapterPos": 10,
            "chapterPosEnd": 25,
            "chapterName": "第三章",
            "bookText": "这是一段高亮文本",
            "style": "{}",
            "note": "测试笔记"
        }"#;
        let time = highlight_add(json).unwrap();
        assert!(time > 0);

        // 按书籍查询
        let by_book = highlight_list_by_book("bk://highlight_test").unwrap();
        assert_eq!(by_book.len(), 1);
        assert_eq!(by_book[0].bookText, "这是一段高亮文本");

        // 按章节查询
        let by_chapter = highlight_list_by_chapter("bk://highlight_test", 2).unwrap();
        assert_eq!(by_chapter.len(), 1);

        // 关键词搜索
        let results = highlight_search("高亮文本").unwrap();
        assert!(results.iter().any(|h| h.bookUrl == "bk://highlight_test"));

        // 删除
        assert!(highlight_delete(time).unwrap());
        let by_book = highlight_list_by_book("bk://highlight_test").unwrap();
        assert_eq!(by_book.len(), 0);
    }

    #[test]
    fn test_highlight_delete_by_book() {
        let _db_guard = crate::db_state::ensure_test_db();

        for i in 0..2 {
            let json = format!(
                r#"{{"time": 0, "bookUrl": "bk://del_test", "chapterIndex": {i},
                     "bookName": "删除测试", "bookText": "t{i}"}}"#
            );
            highlight_add(&json).unwrap();
        }
        assert_eq!(highlight_list_by_book("bk://del_test").unwrap().len(), 2);
        let deleted = highlight_delete_by_book("bk://del_test").unwrap();
        assert_eq!(deleted, 2);
    }

    #[test]
    fn test_highlight_rule_crud_flow() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 新增规则（id=0 自增）
        let json = r#"{
            "name": "FFI测试规则",
            "pattern": "关键词",
            "isRegex": false,
            "isEnabled": true,
            "style": "{}",
            "sortOrder": 100,
            "timeoutMillisecond": 3000,
            "applyToTitle": false
        }"#;
        let id = highlight_rule_save(json).unwrap();
        assert!(id > 0);

        // 列表包含新规则
        let rules = highlight_rule_list().unwrap();
        assert!(rules.iter().any(|r| r.id == id && r.name == "FFI测试规则"));

        // 按书籍查找启用规则
        let enabled = highlight_rule_find_enabled("", "").unwrap();
        assert!(enabled.iter().any(|r| r.id == id));

        // 覆盖保存（同 ID 更新）
        let update_json = format!(
            r#"{{"id": {id}, "name": "FFI测试规则-更新", "pattern": "新关键词",
                 "isRegex": true, "isEnabled": true, "style": "{{}}",
                 "sortOrder": 100, "timeoutMillisecond": 3000}}"#
        );
        let saved_id = highlight_rule_save(&update_json).unwrap();
        assert_eq!(saved_id, id);
        let rules = highlight_rule_list().unwrap();
        let updated = rules.iter().find(|r| r.id == id).unwrap();
        assert_eq!(updated.name, "FFI测试规则-更新");
        assert!(updated.isRegex);

        // 删除
        assert!(highlight_rule_delete(id).unwrap());
        assert!(!highlight_rule_delete(id).unwrap());
    }

    /// [P2-11] uuid/applyToBody 随 JSON 通道全字段往返（旧调用方不传两字段时
    /// serde 默认值兜底：uuid 随机、applyToBody=true，对齐原版实体默认）
    #[test]
    fn test_highlight_rule_uuid_and_apply_to_body_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 带 uuid/applyToBody 的字面量保存 → 读回一致
        let json = r#"{
            "uuid": "44444444-4444-4444-8444-444444444444",
            "name": "双开关规则",
            "pattern": "关键词",
            "isRegex": false,
            "isEnabled": true,
            "style": "{}",
            "sortOrder": 1,
            "timeoutMillisecond": 3000,
            "applyToTitle": true,
            "applyToBody": false
        }"#;
        let id = highlight_rule_save(json).unwrap();
        let rules = highlight_rule_list().unwrap();
        let rule = rules.iter().find(|r| r.id == id).unwrap();
        assert_eq!(rule.uuid, "44444444-4444-4444-8444-444444444444");
        assert!(rule.applyToTitle);
        assert!(!rule.applyToBody, "applyToBody=false 应经 JSON 往返保留");
        assert!(highlight_rule_delete(id).unwrap());

        // 旧形态 JSON（缺 uuid/applyToBody）不报错且默认值对齐原版实体
        let legacy_id =
            highlight_rule_save(r#"{"name": "旧形态规则", "pattern": "p", "style": "{}"}"#)
                .unwrap();
        let rules = highlight_rule_list().unwrap();
        let legacy = rules.iter().find(|r| r.id == legacy_id).unwrap();
        assert!(!legacy.uuid.is_empty(), "缺 uuid 时应生成随机 uuid");
        assert!(
            legacy.applyToBody,
            "缺 applyToBody 时应默认 true（原版实体默认）"
        );
        assert!(
            !legacy.applyToTitle,
            "缺 applyToTitle 时应默认 false（原版实体默认）"
        );
    }

    #[test]
    fn test_highlight_add_invalid_json() {
        let _db_guard = crate::db_state::ensure_test_db();
        assert!(highlight_add("{invalid json").is_err());
        assert!(highlight_rule_save("{invalid json").is_err());
    }

    /// 批28b（P3-3）：`highlight_rule_save` 只规整 group（trim→null），
    /// 不得像恢复路径那样重新生成 uuid（规则身份需稳定）
    #[test]
    fn test_highlight_rule_save_normalizes_group_only() {
        let _db_guard = crate::db_state::ensure_test_db();

        let uuid = "55555555-5555-4555-8555-555555555555";
        let json = format!(
            r#"{{"uuid":"{uuid}","name":"分组规则","pattern":"p",
                 "style":"{{}}","group":"  分组A  "}}"#
        );
        let id = highlight_rule_save(&json).unwrap();
        let rules = highlight_rule_list().unwrap();
        let rule = rules.iter().find(|r| r.id == id).unwrap();
        assert_eq!(rule.group.as_deref(), Some("分组A"), "group 应去首尾空白");
        assert_eq!(rule.uuid, uuid, "编辑保存不得重新生成 uuid");
        assert!(highlight_rule_delete(id).unwrap());

        // 空白分组 → None（对齐原版 normalizeForRestore 的 takeIf 语义）
        let blank_json = format!(
            r#"{{"uuid":"{uuid}","name":"空白分组规则","pattern":"p",
                 "style":"{{}}","group":"   "}}"#
        );
        let blank_id = highlight_rule_save(&blank_json).unwrap();
        let rules = highlight_rule_list().unwrap();
        let blank = rules.iter().find(|r| r.id == blank_id).unwrap();
        assert_eq!(blank.group, None, "空白 group 应规整为 None");
        assert_eq!(blank.uuid, uuid);
        assert!(highlight_rule_delete(blank_id).unwrap());
    }

    // ─── 批34：高亮规则正文匹配 ────────────────────────────────

    /// 匹配测试专用书名（作为规则 scope，隔离其他用例可能残留的全局规则）
    const MATCH_TEST_BOOK: &str = "批34高亮匹配测试书";

    /// 保存一条规则并返回 id（scope 固定 MATCH_TEST_BOOK）
    fn save_match_rule(
        name: &str,
        pattern: &str,
        is_regex: bool,
        sort_order: i32,
        apply_to_title: bool,
        apply_to_body: bool,
    ) -> i64 {
        let json = serde_json::json!({
            "name": name,
            "pattern": pattern,
            "isRegex": is_regex,
            "scope": MATCH_TEST_BOOK,
            "isEnabled": true,
            "style": r#"{"fill":-2130706186}"#,
            "sortOrder": sort_order,
            "timeoutMillisecond": 3000,
            "applyToTitle": apply_to_title,
            "applyToBody": apply_to_body,
        });
        highlight_rule_save(&json.to_string()).unwrap()
    }

    /// 仅保留本用例规则产生的命中（防其他用例残留全局规则干扰）
    fn own_matches(text: &str, apply_to_title: bool, ids: &[i64]) -> Vec<HighlightRuleMatch> {
        highlight_rule_match(text, MATCH_TEST_BOOK, "", apply_to_title, None)
            .unwrap()
            .into_iter()
            .filter(|m| ids.contains(&m.ruleId))
            .collect()
    }

    #[test]
    fn test_highlight_rule_match_literal_utf16_and_style_json() {
        let _db_guard = crate::db_state::ensure_test_db();
        let id = save_match_rule("字面量", "关键词", false, 10, false, true);

        // 😀 为非 BMP 字符（UTF-16 占 2 个 code unit），起点应为 2 而非字节偏移 4
        let matches = own_matches("😀关键词", false, &[id]);
        assert_eq!(matches.len(), 1);
        let m = &matches[0];
        assert_eq!((m.start, m.end), (2, 5));
        assert_eq!(m.end - m.start, 3);
        assert_eq!(m.order, 10);
        assert_eq!(m.styleJson, r#"{"fill":-2130706186}"#);

        // 同一规则多命中：非重叠顺序查找
        let matches = own_matches("重复关键词与关键词，结尾关键词。", false, &[id]);
        let spans: Vec<(i64, i64)> = matches.iter().map(|m| (m.start, m.end)).collect();
        assert_eq!(spans, vec![(2, 5), (6, 9), (12, 15)]);

        // 字面量大小写敏感（与 Java Pattern 默认口径一致）
        assert!(own_matches("ABC", false, &[id]).is_empty());

        assert!(highlight_rule_delete(id).unwrap());
    }

    #[test]
    fn test_highlight_rule_match_regex_java_dialect_and_invalid_skip() {
        let _db_guard = crate::db_state::ensure_test_db();
        // Java \uXXXX 转义经 adapt_java_regex 适配为 \x{XXXX}
        let good = save_match_rule("正则", r"\u5173.词", true, 20, false, true);
        // 无效正则：应 warn 跳过且不影响其他规则
        let bad = save_match_rule("坏正则", "(", true, 30, false, true);

        let matches = own_matches("甲关键词乙", false, &[good, bad]);
        let spans: Vec<(i64, i64)> = matches.iter().map(|m| (m.start, m.end)).collect();
        assert_eq!(spans, vec![(1, 4)]);
        assert!(matches.iter().all(|m| m.ruleId != bad));

        assert!(highlight_rule_delete(good).unwrap());
        assert!(highlight_rule_delete(bad).unwrap());
    }

    #[test]
    fn test_highlight_rule_match_overlap_priority_truncates_lower_order() {
        let _db_guard = crate::db_state::ensure_test_db();
        let low = save_match_rule("低优先级", "abcdef", false, 1, false, true);
        let high = save_match_rule("高优先级", "cde", false, 5, false, true);

        let matches = own_matches("xxabcdefyy", false, &[low, high]);
        let spans: Vec<(i64, i64, i64)> =
            matches.iter().map(|m| (m.ruleId, m.start, m.end)).collect();
        // 低优先级被高优先级截断为前后两段；输出按 (order 升序, start 升序)
        assert_eq!(
            spans,
            vec![(low, 2, 4), (low, 7, 8), (high, 4, 7)],
            "重叠必须由高 order 覆盖，低 order 截断"
        );

        assert!(highlight_rule_delete(low).unwrap());
        assert!(highlight_rule_delete(high).unwrap());
    }

    #[test]
    fn test_highlight_rule_match_apply_to_title_filter() {
        let _db_guard = crate::db_state::ensure_test_db();
        let title_only = save_match_rule("仅标题", "标题词", false, 5, true, false);

        // applyToTitle=false（正文侧）不采纳 applyToBody=false 的规则
        assert!(own_matches("标题词", false, &[title_only]).is_empty());
        // applyToTitle=true（标题侧）采纳
        assert_eq!(own_matches("标题词", true, &[title_only]).len(), 1);

        assert!(highlight_rule_delete(title_only).unwrap());
    }

    #[test]
    fn test_highlight_rule_match_empty_and_limits() {
        let _db_guard = crate::db_state::ensure_test_db();
        let id = save_match_rule("限额", "关键词", false, 10, false, true);

        // maxMatches=0 → 空数组（不查询、不报错）
        assert!(
            highlight_rule_match("关键词", MATCH_TEST_BOOK, "", false, Some(0))
                .unwrap()
                .is_empty()
        );
        // 空正文 → 空数组
        assert!(highlight_rule_match("", MATCH_TEST_BOOK, "", false, None)
            .unwrap()
            .is_empty());
        // 其他书的 scope 不采纳本规则
        let other = highlight_rule_match("关键词", "另一本书", "", false, None).unwrap();
        assert!(other.iter().all(|m| m.ruleId != id));

        assert!(highlight_rule_delete(id).unwrap());
    }

    #[test]
    fn test_highlight_rule_match_size_cap() {
        // 超出 1 MiB 上限：报错且不进入匹配（无需 DB）
        let big = "a".repeat(MAX_MATCH_TEXT_BYTES + 1);
        assert!(highlight_rule_match(&big, MATCH_TEST_BOOK, "", false, None).is_err());
    }

    #[test]
    fn test_highlight_rule_match_deadline_check() {
        // 截止时间已过：字面量收集立即返回未完成（模拟超时路径，小文本）
        let expired = Instant::now()
            .checked_sub(Duration::from_secs(1))
            .expect("系统时钟应支持回退 1s");
        let mut out = Vec::new();
        let mut seq = 0usize;
        let completed = collect_literal_matches("abcabc", "a", 0, expired, 10, &mut out, &mut seq);
        assert!(!completed, "截止时间已过应报告未完成");
        assert!(out.is_empty(), "截止时间已过不应再收集命中");
    }
}
