//! 统一安全正则编译入口（全工作区唯一实现）
//!
//! 背景：病态/深嵌套 pattern 会触发 regex-syntax 解析阶段的深递归，
//! 在 tokio spawn_blocking 池（worker 默认约 2MB 栈）上造成栈溢出 SIGSEGV。
//! **Android 上任何线程的栈溢出都会杀死整个进程**，因此线程隔离
//! （8MB 栈子线程编译）并不是正确性保障——它只用于缩短调用线程阻塞、
//! 作为最后一道兜底。真正保证不崩溃的是三件套：
//!
//! 1. **1KB pattern 长度上限**（[`MAX_REGEX_PATTERN_LEN`]）：超限直接拒绝；
//! 2. **嵌套深度防御**：`regex_syntax::ParserBuilder::nest_limit(32)` 预解析，
//!    病态嵌套在进入真正编译前即被拦截（nest_limit 限定了递归深度，
//!    预解析本身在小栈线程上也安全）；
//! 3. **失败负缓存**：病态/非法 pattern 的失败结果永久缓存，
//!    避免反复触发编译（对齐原版 Kotlin `AnalyzeRule.regexCache` 的全局缓存语义）。
//!
//! 所有"用户/书源可控 pattern"的动态编译必须走 [`compile_regex_safe`]
//! （或 fancy 方言的 [`compile_fancy_regex_safe`]），禁止裸 `Regex::new`。

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};

use regex::Regex;

/// pattern 长度防御上限（字节）：超限直接拒绝编译，降级由调用方处理
pub const MAX_REGEX_PATTERN_LEN: usize = 1024;

/// 嵌套深度防御上限：regex-syntax AST 嵌套超过该深度即判定为病态 pattern。
/// 正常书源规则嵌套远低于此值；32 层足以拦截递归炸栈类构造，同时
/// 保证预解析自身递归深度有界（小栈线程上亦安全）。
const MAX_REGEX_NEST_LIMIT: u32 = 32;

/// 安全编译线程的栈大小：8MB（tokio worker 默认仅约 2MB）
const SAFE_COMPILE_STACK_SIZE: usize = 8 << 20;

/// 编译缓存容量上限（防内存膨胀；超限时整体清空重建）
const REGEX_CACHE_CAPACITY: usize = 1024;

/// 编译结果缓存：pattern → Ok(Arc<Regex>)/Err(失败描述)。
/// 失败结果同样缓存（负缓存），避免病态/非法 pattern 反复触发编译。
/// 对齐原版 Kotlin `AnalyzeRule.regexCache` 的全局正则缓存设计。
static REGEX_CACHE: LazyLock<Mutex<HashMap<String, Result<Arc<Regex>, String>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 截取 pattern 前 64 字符用于诊断日志（避免超长 pattern 刷爆日志）
fn pattern_head(pattern: &str) -> String {
    pattern.chars().take(64).collect()
}

/// 在指定栈大小的独立线程上执行编译闭包。
///
/// **重要**：Android 上任何线程（含子线程）栈溢出都会杀死整个进程，
/// 因此线程隔离**不是**正确性保障，仅用于：
/// - 缩短调用线程（可能是 tokio worker 小栈）被编译占用的阻塞；
/// - 作为长度上限 + nest_limit 之后的最后兜底（join 失败时安全返回 None）。
///
/// 正确性依赖：1KB 长度上限 + nest_limit 嵌套防御 + 失败负缓存。
pub fn compile_on_stack<T, F>(stack_size: usize, f: F) -> Option<T>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    std::thread::Builder::new()
        .name("legado-regex-compile".to_string())
        .stack_size(stack_size)
        .spawn(f)
        .ok()?
        .join()
        .ok()
}

/// 在指定栈大小的独立线程上执行 `Regex::new`（兼容旧签名）。
pub fn compile_regex_on_stack(pattern: &str, stack_size: usize) -> Option<Regex> {
    let owned = pattern.to_string();
    compile_on_stack(stack_size, move || Regex::new(&owned))?.ok()
}

/// 安全编译用户提供的正则 pattern —— 全工作区动态正则编译的统一入口。
///
/// 防御三件套（见模块文档）：
/// - pattern 超过 [`MAX_REGEX_PATTERN_LEN`]（1KB）：直接返回 None；
/// - `regex_syntax` nest_limit(32) 预解析：病态嵌套提前拒绝；
/// - 编译结果（含失败）以 pattern 字符串为键缓存，容量上限防内存膨胀。
///
/// 返回 `Some(Arc<Regex>)` 表示编译成功；`None` 表示应降级
/// （跳过该正则 / 回退字面量替换 / 返回空结果，由调用方按原版语义处理）。
pub fn compile_regex_safe(pattern: &str) -> Option<Arc<Regex>> {
    if pattern.len() > MAX_REGEX_PATTERN_LEN {
        eprintln!(
            "[regex_safe] 拒绝超长 pattern（{}B > {}B 上限），前64字符: {}",
            pattern.len(),
            MAX_REGEX_PATTERN_LEN,
            pattern_head(pattern)
        );
        return None;
    }
    let mut cache = REGEX_CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(entry) = cache.get(pattern) {
        return entry.clone().ok();
    }
    // 嵌套深度防御：nest_limit 限定解析递归深度，病态嵌套在此被拦截，
    // 通过预解析的 pattern 后续编译递归深度同样有界。
    let mut builder = regex_syntax::ParserBuilder::new();
    builder.nest_limit(MAX_REGEX_NEST_LIMIT);
    if let Err(e) = builder.build().parse(pattern) {
        let msg = format!("regex parse rejected: {e}");
        eprintln!(
            "[regex_safe] 正则编译失败（{}），前64字符: {}",
            if msg.contains("nest") {
                "嵌套过深"
            } else {
                "语法非法"
            },
            pattern_head(pattern)
        );
        let entry = Err(msg);
        if cache.len() >= REGEX_CACHE_CAPACITY {
            cache.clear();
        }
        cache.insert(pattern.to_string(), entry);
        return None;
    }
    // 8MB 栈独立线程编译：兜底防御（见 compile_on_stack 文档）
    let compiled = compile_regex_on_stack(pattern, SAFE_COMPILE_STACK_SIZE)
        .map(Arc::new)
        .ok_or_else(|| "regex compile failed (invalid or stack overflow)".to_string());
    if compiled.is_err() {
        eprintln!(
            "[regex_safe] 正则编译失败（编译阶段），前64字符: {}",
            pattern_head(pattern)
        );
    }
    let result = compiled.clone().ok();
    if cache.len() >= REGEX_CACHE_CAPACITY {
        cache.clear();
    }
    cache.insert(pattern.to_string(), compiled);
    result
}

/// 安全编译 fancy-regex 方言 pattern（lookbehind/lookahead/backreference/原子组）。
///
/// 与 [`compile_regex_safe`] 相同的防御，但**不走 regex 缓存**：
/// fancy 方言含 regex-syntax 不认识的语法（lookaround/backreference），
/// 无法做 nest_limit 预解析；1KB 长度上限已天然限定嵌套深度上界，
/// 编译同样放在 8MB 栈独立线程兜底。失败返回 None，调用方降级。
pub fn compile_fancy_regex_safe(pattern: &str) -> Option<fancy_regex::Regex> {
    if pattern.len() > MAX_REGEX_PATTERN_LEN {
        eprintln!(
            "[regex_safe] 拒绝超长 fancy pattern（{}B > {}B 上限），前64字符: {}",
            pattern.len(),
            MAX_REGEX_PATTERN_LEN,
            pattern_head(pattern)
        );
        return None;
    }
    let owned = pattern.to_string();
    let compiled = compile_on_stack(SAFE_COMPILE_STACK_SIZE, move || fancy_regex::Regex::new(&owned));
    match compiled {
        Some(Ok(re)) => Some(re),
        Some(Err(e)) => {
            eprintln!(
                "[regex_safe] fancy 正则编译失败（{}），前64字符: {}",
                e,
                pattern_head(pattern)
            );
            None
        }
        None => {
            eprintln!(
                "[regex_safe] fancy 正则编译异常（线程退出），前64字符: {}",
                pattern_head(pattern)
            );
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compile_regex_safe_basic() {
        // 常规 pattern 行为不变
        let re = compile_regex_safe(r"\d+").expect("常规 pattern 应编译成功");
        assert_eq!(re.find("abc123").unwrap().as_str(), "123");
        // 非法 pattern 返回 None（不 panic）
        assert!(compile_regex_safe(r"(unclosed").is_none());
    }

    #[test]
    fn test_compile_regex_safe_pattern_len_limit() {
        // 超过 1KB 上限的 pattern 直接拒绝（降级，不崩溃）
        let long_pattern = "a|".repeat(600);
        assert!(long_pattern.len() > MAX_REGEX_PATTERN_LEN);
        assert!(compile_regex_safe(&long_pattern).is_none());
    }

    #[test]
    fn test_compile_regex_safe_caches_result() {
        let a = compile_regex_safe(r"cached-\w+").expect("编译成功");
        let b = compile_regex_safe(r"cached-\w+").expect("缓存命中");
        assert!(Arc::ptr_eq(&a, &b), "相同 pattern 应命中同一缓存实例");
    }

    /// 构造深嵌套病态 pattern（超 regex-syntax 递归上限，且超 1KB 长度防御上限）
    fn pathological_pattern() -> String {
        let mut p = String::from("a");
        for _ in 0..40_000 {
            p = format!("(?:{})?", p);
        }
        p
    }

    #[test]
    fn test_compile_regex_safe_rejects_pathological_pattern() {
        // 病态 pattern 超过 1KB 上限：直接降级返回 None，绝不进入编译（不崩溃）
        let pattern = pathological_pattern();
        assert!(pattern.len() > MAX_REGEX_PATTERN_LEN);
        assert!(compile_regex_safe(&pattern).is_none());
    }

    #[test]
    fn test_compile_regex_safe_deep_nesting_within_limit() {
        // 深嵌套但长度在限内：nest_limit 预解析或 regex-syntax 递归上限拦截，
        // 安全路径应与直连编译同果（Err → None，不 panic、不崩溃）
        let mut p = String::from("a");
        while p.len() + 5 <= MAX_REGEX_PATTERN_LEN {
            p = format!("(?:{})?", p);
        }
        assert!(p.len() <= MAX_REGEX_PATTERN_LEN);
        let direct = Regex::new(&p);
        let safe = compile_regex_safe(&p);
        assert_eq!(
            safe.is_some(),
            direct.is_ok(),
            "安全编译与直连编译应同果（深嵌套病态 pattern 应编译失败降级）"
        );
        assert!(
            direct.is_err(),
            "前置条件：深嵌套 pattern 应超出 regex-syntax 递归上限或 nest_limit"
        );
    }

    /// 深嵌套字符类病态 pattern（`[a-[b-[c-...]]]`），每层 +6 字节
    fn nested_char_class_pattern(depth: usize) -> String {
        let mut p = String::from("z");
        for _ in 0..depth {
            p = format!("[a-[{}]]", p);
        }
        p
    }

    #[test]
    fn test_compile_regex_safe_nested_char_class_pathological() {
        // 200 层嵌套字符类（约 1.2KB）：超 1KB 上限，长度防御直接拒绝，绝不崩溃
        let p200 = nested_char_class_pattern(200);
        assert!(p200.len() > MAX_REGEX_PATTERN_LEN);
        assert!(compile_regex_safe(&p200).is_none());
        // 170 层嵌套字符类（1021B ≤ 1KB）：不走长度拦截，
        // 由 nest_limit 嵌套防御或语法校验拦截，同样安全降级不崩溃
        let p170 = nested_char_class_pattern(170);
        assert!(p170.len() <= MAX_REGEX_PATTERN_LEN);
        assert!(
            compile_regex_safe(&p170).is_none(),
            "1KB 内 170 层嵌套字符类应被 nest_limit/语法校验拦截降级"
        );
    }

    #[test]
    fn test_compile_regex_safe_negative_cache_hit() {
        // 病态/非法 pattern 负缓存：二次调用直接命中缓存返回 None
        assert!(compile_regex_safe(r"(unclosed-neg").is_none());
        assert!(compile_regex_safe(r"(unclosed-neg").is_none());
        let cache = REGEX_CACHE.lock().unwrap();
        assert!(
            matches!(cache.get(r"(unclosed-neg"), Some(Err(_))),
            "非法 pattern 应存在负缓存"
        );
    }

    #[test]
    fn test_compile_fancy_regex_safe_basic_and_limit() {
        // fancy 方言常规 pattern（lookbehind）编译成功
        let re = compile_fancy_regex_safe(r"(?<=\$)\d+").expect("lookbehind 应编译成功");
        let m = re.find("price $42").unwrap().unwrap();
        assert_eq!(m.as_str(), "42");
        // 超 1KB 上限直接拒绝
        let long = "a|".repeat(600);
        assert!(compile_fancy_regex_safe(&long).is_none());
        // 非法 pattern 降级 None（不 panic）
        assert!(compile_fancy_regex_safe(r"(unclosed").is_none());
    }

    #[test]
    fn test_compile_regex_safe_on_small_stack_caller() {
        // 模拟 tokio worker 小栈调用方：在 512KB 栈线程上调用 compile_regex_safe，
        // 编译在其内部 8MB 栈子线程执行，调用方无论结果如何均不崩溃。
        let handle = std::thread::Builder::new()
            .stack_size(512 << 10)
            .spawn(|| {
                let ok = compile_regex_safe(r"\d{4}-\d{2}-\d{2}").expect("常规 pattern 应编译成功");
                assert!(ok.is_match("2026-08-10"));
                let bad = compile_regex_safe(r"(?P<dup>a)(?P<dup>b)");
                assert!(bad.is_none(), "非法 pattern 应降级为 None");
                // 病态嵌套在小栈线程上同样安全（nest_limit 预解析递归有界）
                let mut p = String::from("a");
                while p.len() + 5 <= MAX_REGEX_PATTERN_LEN {
                    p = format!("(?:{})?", p);
                }
                assert!(compile_regex_safe(&p).is_none());
            })
            .expect("spawn 失败");
        handle.join().expect("小栈线程上调用 compile_regex_safe 不应崩溃");
    }
}
