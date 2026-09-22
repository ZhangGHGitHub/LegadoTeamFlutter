//! 能力受限台账（队列④：能力受限提示 + 未知类告警）
//!
//! 两份进程内登记表（`Mutex<BTreeMap>`），供诊断与"下一批补什么"决策查询：
//!
//! 1. **未知 Java 符号**：Rhino `Packages` / `Java.type` / `importClass` 模拟层遇到
//!    能力清单未覆盖的类/成员时登记符号全名（如 `java.lang.Foo`、`Java.type(x.y.Z)`），
//!    并抛出带明确文案的错误（文案见 `quickjs_impl` 的 `inject_packages_shim`）。
//!    决策依据：`docs/RHINO_INTEROP_ANALYSIS_20260920.md` §8 —— 916 源语料中
//!    `importClass(`/`Java.type(` 零命中，Java 面集中在命名类，故只覆盖用到的类，
//!    未知类调用必须告警而非静默。
//! 2. **jsLib 加载失败**：书源 jsLib 求值失败（含归一化兜底后仍失败）时按来源标签
//!    登记计数与最后一次错误摘要，供搜索批次错误通道上屏与离线诊断。
//!
//! 查询 API 为纯函数式只读快照；`reset_*` 仅供单元测试隔离进程级状态。
//!
//! P3 硬化：登记前截断（符号名/错误串 ≤120 字符）、表容量上限（256 键，
//! 满则丢弃新键）；所有 `Mutex::lock()` 用 `unwrap_or_else(|e| e.into_inner())`
//! 恢复语义——台账是进程级诊断设施，锁中毒不应让登记/查询整体雪崩。

use std::collections::BTreeMap;
use std::sync::Mutex;

/// 未知 Java 符号登记表：符号全名 → 累计命中次数
static UNKNOWN_SYMBOLS: Mutex<BTreeMap<String, u64>> = Mutex::new(BTreeMap::new());

/// jsLib 加载失败登记表：来源标签（engine-cache key / executor tag）→ (计数, 最后错误摘要)
static JSLIB_FAILURES: Mutex<BTreeMap<String, (u64, String)>> = Mutex::new(BTreeMap::new());

/// P3 硬化：符号名/错误串登记前截断上限（按字符，非字节）——
/// 防止病态书源用超长符号/错误串灌大表。
const MAX_ENTRY_LEN: usize = 120;

/// P3 硬化：单张登记表容量上限——满时丢弃新键（既有键仍可更新计数/错误摘要），
/// 防止病态书源用海量垃圾符号把表灌到内存膨胀。
const MAX_LEDGER_ENTRIES: usize = 256;

/// 截断辅助：保留前 120 个字符（`char` 边界安全，不截半多字节字符）。
fn truncate_to_cap(s: &str) -> String {
    s.chars().take(MAX_ENTRY_LEN).collect()
}

/// 登记一个未知 Java 符号（首次登记时输出开发日志）。
///
/// 空串/全空白直接忽略。线程安全；调用方无需预 trim（内部处理）。
/// P3 硬化：符号名截断至 120 字符；表满（256 键）时丢弃新键，既有键照常累计。
pub fn record_unknown_java_symbol(symbol: &str) {
    let sym = symbol.trim();
    if sym.is_empty() {
        return;
    }
    let mut guard = UNKNOWN_SYMBOLS.lock().unwrap_or_else(|e| e.into_inner());
    let sym = truncate_to_cap(sym);
    match guard.get_mut(&sym) {
        Some(count) => *count += 1,
        None => {
            if guard.len() >= MAX_LEDGER_ENTRIES {
                return; // 表满：丢弃新键，既有登记不受影响
            }
            eprintln!("[legado-js] 能力受限登记: 未知 Java 符号 {sym}（需补充 Java 类支持）");
            guard.insert(sym, 1);
        }
    }
}

/// 当前已登记的未知 Java 符号快照（按符号升序），每项为 (符号, 累计次数)。
pub fn unknown_java_symbols() -> Vec<(String, u64)> {
    let guard = UNKNOWN_SYMBOLS.lock().unwrap_or_else(|e| e.into_inner());
    guard.iter().map(|(k, v)| (k.clone(), *v)).collect()
}

/// 未知 Java 符号累计命中总次数（所有符号求和）。
pub fn unknown_java_symbol_count() -> u64 {
    let guard = UNKNOWN_SYMBOLS.lock().unwrap_or_else(|e| e.into_inner());
    guard.values().sum()
}

/// 清空未知 Java 符号登记表（仅测试用）。
pub fn reset_unknown_java_symbols() {
    let mut guard = UNKNOWN_SYMBOLS.lock().unwrap_or_else(|e| e.into_inner());
    guard.clear();
}

/// 登记一次 jsLib 加载失败：计数 +1 并刷新最后错误摘要。
///
/// `source_tag` 为来源标识（engine-cache key，如 `executor:www.example.com`，
/// 或引擎缓存 key `https://...`）；`error` 为错误摘要。
/// P3 硬化：来源标签与错误摘要均截断至 120 字符；表满（256 键）时丢弃
/// 新键，既有键照常累计/刷新。
pub fn record_jslib_load_failure(source_tag: &str, error: &str) {
    let tag = source_tag.trim();
    if tag.is_empty() {
        return;
    }
    let tag = truncate_to_cap(tag);
    let summary = truncate_to_cap(error.trim());
    let mut guard = JSLIB_FAILURES.lock().unwrap_or_else(|e| e.into_inner());
    match guard.get_mut(&tag) {
        Some((count, last_err)) => {
            *count += 1;
            *last_err = summary;
        }
        None => {
            if guard.len() >= MAX_LEDGER_ENTRIES {
                return; // 表满：丢弃新键，既有登记不受影响
            }
            guard.insert(tag, (1, summary));
        }
    }
}

/// 查询某来源最近一次 jsLib 加载失败的错误摘要；从未失败返回 `None`。
pub fn last_jslib_error(source_tag: &str) -> Option<String> {
    let guard = JSLIB_FAILURES.lock().unwrap_or_else(|e| e.into_inner());
    guard
        .get(&truncate_to_cap(source_tag.trim()))
        .map(|(_, err)| err.clone())
}

/// 当前所有 jsLib 加载失败快照（按来源升序），每项为 (来源, 计数, 最后错误摘要)。
pub fn jslib_load_failures() -> Vec<(String, u64, String)> {
    let guard = JSLIB_FAILURES.lock().unwrap_or_else(|e| e.into_inner());
    guard
        .iter()
        .map(|(k, (c, e))| (k.clone(), *c, e.clone()))
        .collect()
}

/// 清空 jsLib 加载失败登记表（仅测试用）。
pub fn reset_jslib_load_failures() {
    let mut guard = JSLIB_FAILURES.lock().unwrap_or_else(|e| e.into_inner());
    guard.clear();
}

/// 测试串行锁：台账是进程级全局状态，同一测试二进制内多个触碰台账的测试
///（本模块 + `quickjs_impl` 的 trap 测试 + `legado-ffi` 的 `validate_js_lib` 测试）
/// 必须在此串行，避免并行互踩。无条件导出（非 `#[cfg(test)]`），
/// 依赖 crate（legado-ffi）的单元测试同样可见。
pub static LEDGER_TEST_LOCK: Mutex<()> = Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_unknown_symbol_counting_and_snapshot() {
        let _lock = LEDGER_TEST_LOCK.lock().unwrap();
        reset_unknown_java_symbols();
        assert!(unknown_java_symbols().is_empty());
        assert_eq!(unknown_java_symbol_count(), 0);

        record_unknown_java_symbol("java.lang.Foo");
        record_unknown_java_symbol("java.lang.Foo");
        record_unknown_java_symbol("  Java.type(a.b.C)  "); // 内部 trim
        record_unknown_java_symbol(""); // 忽略空
        record_unknown_java_symbol("   "); // 忽略全空白

        let snap = unknown_java_symbols();
        assert_eq!(snap.len(), 2, "两个不同符号各登记一次");
        // BTreeMap 升序：'J'(74) < 'j'(106)
        assert_eq!(snap[0], ("Java.type(a.b.C)".to_string(), 1));
        assert_eq!(snap[1], ("java.lang.Foo".to_string(), 2));
        assert_eq!(unknown_java_symbol_count(), 3);
        reset_unknown_java_symbols();
    }

    #[test]
    fn test_jslib_failure_count_and_last_error() {
        let _lock = LEDGER_TEST_LOCK.lock().unwrap();
        reset_jslib_load_failures();
        assert!(jslib_load_failures().is_empty());
        assert_eq!(last_jslib_error("src-a"), None);

        record_jslib_load_failure("src-a", "decode is not defined");
        record_jslib_load_failure("src-a", "ReferenceError: x is not defined");
        record_jslib_load_failure("src-b", "SyntaxError: at line 2");

        assert_eq!(
            last_jslib_error("src-a").as_deref(),
            Some("ReferenceError: x is not defined")
        );
        assert_eq!(
            last_jslib_error("src-b").as_deref(),
            Some("SyntaxError: at line 2")
        );
        assert_eq!(
            last_jslib_error("src-a ").as_deref(),
            Some("ReferenceError: x is not defined")
        );

        let snap = jslib_load_failures();
        assert_eq!(snap.len(), 2);
        assert_eq!(
            snap[0],
            (
                "src-a".to_string(),
                2,
                "ReferenceError: x is not defined".to_string()
            )
        );
        assert_eq!(
            snap[1],
            ("src-b".to_string(), 1, "SyntaxError: at line 2".to_string())
        );

        record_jslib_load_failure("", "ignored"); // 空 tag 忽略
        record_jslib_load_failure("   ", "ignored");
        assert_eq!(jslib_load_failures().len(), 2);
        reset_jslib_load_failures();
    }

    /// P3 硬化：未知符号登记截断 + 容量上限
    #[test]
    fn test_unknown_symbol_truncation_and_capacity() {
        let _lock = LEDGER_TEST_LOCK.lock().unwrap();
        reset_unknown_java_symbols();

        // 超长符号截断至 120 字符登记
        let long = "a".repeat(500);
        record_unknown_java_symbol(&long);
        let snap = unknown_java_symbols();
        assert_eq!(snap.len(), 1);
        assert_eq!(snap[0].0.len(), MAX_ENTRY_LEN, "符号名应截断至 120 字符");
        assert_eq!(snap[0].0, "a".repeat(MAX_ENTRY_LEN));

        // 灌满至容量上限（1 + 255 = 256 键）
        for i in 0..(MAX_LEDGER_ENTRIES - 1) {
            record_unknown_java_symbol(&format!("capfill{:02}", i));
        }
        assert_eq!(unknown_java_symbols().len(), MAX_LEDGER_ENTRIES);

        // 表满：新键丢弃
        record_unknown_java_symbol("brand-new-key-should-be-dropped");
        assert_eq!(
            unknown_java_symbols().len(),
            MAX_LEDGER_ENTRIES,
            "表满时应丢弃新键"
        );

        // 表满：既有键仍可累计
        record_unknown_java_symbol(&long);
        let snap = unknown_java_symbols();
        let hit = snap
            .iter()
            .find(|item| item.0.len() == MAX_ENTRY_LEN)
            .unwrap();
        assert_eq!(hit.1, 2, "既有键累计不受容量上限影响");
        reset_unknown_java_symbols();
    }

    /// P3 硬化：jsLib 失败登记截断（来源标签 + 错误摘要）
    #[test]
    fn test_jslib_failure_truncation() {
        let _lock = LEDGER_TEST_LOCK.lock().unwrap();
        reset_jslib_load_failures();

        // 超长错误摘要截断至 120 字符
        let long_err = "e".repeat(300);
        record_jslib_load_failure("src-cap", &long_err);
        let snap = jslib_load_failures();
        assert_eq!(snap.len(), 1);
        assert_eq!(snap[0].0, "src-cap");
        assert_eq!(snap[0].2.len(), MAX_ENTRY_LEN, "错误摘要应截断至 120 字符");

        // 超长来源标签截断至 120 字符（查询端同口径截断才能命中）
        let long_tag = "t".repeat(400);
        record_jslib_load_failure(&long_tag, "x");
        let snap = jslib_load_failures();
        assert_eq!(snap.len(), 2);
        assert_eq!(snap[1].0.len(), MAX_ENTRY_LEN, "来源标签应截断至 120 字符");
        assert_eq!(
            last_jslib_error(&long_tag).as_deref(),
            Some("x"),
            "长标签查询经同口径截断应命中"
        );
        reset_jslib_load_failures();
    }
}
