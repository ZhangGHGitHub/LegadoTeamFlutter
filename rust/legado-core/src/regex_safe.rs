//! 统一安全正则编译入口（全工作区唯一实现）
//!
//! 背景：病态/深嵌套 pattern 会触发 regex-syntax 解析管线的深递归，
//! 在 tokio worker（默认约 2MB 栈）上造成栈溢出 SIGSEGV。
//! **Android 上任何线程的栈溢出都会杀死整个进程**。
//!
//! ## 防御体系（第三轮调查结论落地）
//!
//! 1. **1KB pattern 长度上限**（[`MAX_REGEX_PATTERN_LEN`]）：超限直接拒绝；
//! 2. **非递归结构预检**（根治核心，[`max_nesting_depth`]）：O(n) 单遍扫描
//!    统计 `(` 与 `[` 的最大嵌套深度，超过 [`MAX_REGEX_NEST_DEPTH`]（32）直接
//!    拒绝并负缓存。这是 nest_limit 语义的**真正等价物**——regex-syntax 0.8 的
//!    `ParserBuilder::nest_limit` 是 AST 解析完成后的后验检查，病态 pattern 的
//!    解析/drop 递归先于检查发生，且预解析运行在调用方线程（2MB 栈）本身就是
//!    裸奔点；本预检为纯迭代扫描，在任何栈大小的线程上零栈风险。
//! 3. **失败负缓存 + LRU 淘汰**：病态/非法 pattern 的失败结果持久缓存；
//!    缓存容量 2048 的 LRU 淘汰（不再整体 clear()，避免 152 源场景反复失效
//!    放大编译风暴）；对齐原版 Kotlin `AnalyzeRule.regexCache` 全局缓存语义。
//! 4. **8MB 栈隔离线程编译**：仅作兜底（缩短调用线程阻塞），不是正确性保障。
//!
//! 配套防线（见各 runtime 构建点）：FFI/server/JS 三处 tokio Runtime 的
//! worker 线程栈统一扩到 8MB，对齐原版 JVM 线程栈水位。
//!
//! 所有"用户/书源可控 pattern"的动态编译必须走 [`compile_regex_safe`]
//! （或 fancy 方言的 [`compile_fancy_regex_safe`]），禁止裸 `Regex::new`。

use std::num::NonZeroUsize;
use std::sync::{Arc, LazyLock, Mutex};

use lru::LruCache;
use regex::Regex;

/// pattern 长度防御上限（字节）：超限直接拒绝编译，降级由调用方处理
pub const MAX_REGEX_PATTERN_LEN: usize = 1024;

/// 嵌套深度防御上限：`(` 与 `[` 的最大嵌套深度超过该值即判定为病态 pattern。
/// 32 层足以拦截递归炸栈类构造（1KB 内最多约 500 层嵌套 ≈ debug 构建下
/// Ast::drop 单帧 2.6KB × 500 ≈ 1.3MB+，足以击穿 2MB worker 栈），
/// 正常书源规则嵌套远低于此值。
const MAX_REGEX_NEST_DEPTH: usize = 32;

/// 安全编译线程的栈大小：8MB（tokio worker 默认仅约 2MB）
const SAFE_COMPILE_STACK_SIZE: usize = 8 << 20;

/// 编译缓存容量上限：LRU 淘汰（超限逐出最久未用条目，**不再整体清空**）
const REGEX_CACHE_CAPACITY: usize = 2048;

/// 编译结果 LRU 缓存：pattern → Ok(Arc<Regex>)/Err(失败描述)。
/// 失败结果同样缓存（负缓存），避免病态/非法 pattern 反复触发编译。
/// 对齐原版 Kotlin `AnalyzeRule.regexCache` 的全局正则缓存设计。
static REGEX_CACHE: LazyLock<Mutex<LruCache<String, Result<Arc<Regex>, String>>>> =
    LazyLock::new(|| {
        Mutex::new(LruCache::new(
            NonZeroUsize::new(REGEX_CACHE_CAPACITY).expect("容量常量非法"),
        ))
    });

// ─── 诊断日志（Android 路由到 logcat） ─────────────────────

#[cfg(target_os = "android")]
const ANDROID_LOG_INFO: std::ffi::c_int = 4;

#[cfg(target_os = "android")]
#[link(name = "log")]
extern "C" {
    fn __android_log_write(
        prio: std::ffi::c_int,
        tag: *const std::ffi::c_char,
        text: *const std::ffi::c_char,
    ) -> std::ffi::c_int;
}

/// 诊断日志统一助手：Android 上 eprintln 不路由到 logcat，
/// 故 Android 目标改用 liblog 的 `__android_log_write`（tag=legado-regex）；
/// 非 Android 平台保留 eprintln。
fn regex_safe_log(msg: &str) {
    let line = format!("[regex_safe] {}", msg);
    #[cfg(target_os = "android")]
    {
        use std::ffi::CString;
        if let (Ok(tag), Ok(text)) = (CString::new("legado-regex"), CString::new(line)) {
            unsafe {
                __android_log_write(ANDROID_LOG_INFO, tag.as_ptr(), text.as_ptr());
            }
        }
    }
    #[cfg(not(target_os = "android"))]
    {
        eprintln!("{}", line);
    }
}

/// 当前线程名（诊断用）
fn current_thread_name() -> String {
    std::thread::current()
        .name()
        .unwrap_or("<unnamed>")
        .to_string()
}

/// 截取 pattern 前 64 字符用于诊断日志（避免超长 pattern 刷爆日志）
fn pattern_head(pattern: &str) -> String {
    pattern.chars().take(64).collect()
}

// ─── 非递归结构预检（根治核心） ─────────────────────────────

/// 非递归 O(n) 单遍扫描：统计 pattern 中 `(` 与 `[` 的最大嵌套深度。
///
/// 与 regex-syntax 的 nest_limit 语义等价但**零栈风险**（纯迭代，无递归）：
/// - `\` 转义的下一字符按字面量处理（`\(`/`\[` 不计嵌套）；
/// - 字符类内部的 `(` 是字面量，不计分组嵌套；
/// - 字符类内部的 `[`（嵌套字符类，如 `[a-[b]]`）同样计入深度——
///   递归炸栈类病态构造（如 `[a-[b-[c-...]]]`）恰恰依赖类内嵌套，
///   简易扫描无法区分类内字面量 `[`，一律计深，误差方向只会偏保守；
/// - `]` 关闭一层嵌套（类内或分组），`saturating_sub` 防负数。
pub fn max_nesting_depth(pattern: &str) -> usize {
    let mut depth: usize = 0;
    let mut max_depth: usize = 0;
    let mut in_class = false;
    let mut escaped = false;
    for c in pattern.chars() {
        if escaped {
            escaped = false;
            continue;
        }
        match c {
            '\\' => escaped = true,
            '[' => {
                in_class = true;
                depth += 1;
                max_depth = max_depth.max(depth);
            }
            ']' if depth > 0 => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    in_class = false;
                }
            }
            '(' if !in_class => {
                depth += 1;
                max_depth = max_depth.max(depth);
            }
            ')' if !in_class => {
                depth = depth.saturating_sub(1);
            }
            _ => {}
        }
    }
    max_depth
}

// ─── 隔离线程编译（兜底） ──────────────────────────────────

/// 在指定栈大小的独立线程上执行编译闭包。
///
/// **重要**：Android 上任何线程（含子线程）栈溢出都会杀死整个进程，
/// 因此线程隔离**不是**正确性保障，仅用于：
/// - 缩短调用线程（可能是 tokio worker）被编译占用的阻塞；
/// - 作为长度上限 + 非递归结构预检之后的最后兜底（join 失败时安全返回 None）。
///
/// 正确性依赖：1KB 长度上限 + 非递归嵌套预检 + 失败负缓存。
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

// ─── 统一安全编译入口 ──────────────────────────────────────

/// 安全编译用户提供的正则 pattern —— 全工作区动态正则编译的统一入口。
///
/// 防御链（见模块文档）：
/// - pattern 超过 [`MAX_REGEX_PATTERN_LEN`]（1KB）：直接拒绝并负缓存；
/// - 非递归结构预检：`(`/`[` 最大嵌套深度 > 32 直接拒绝并负缓存
///   （纯迭代扫描，调用方线程零栈风险）；
/// - 8MB 栈独立线程编译（兜底）；
/// - 结果（含失败）进入 LRU 缓存（容量 2048，逐出最久未用，不整体清空）。
///
/// 返回 `Some(Arc<Regex>)` 表示编译成功；`None` 表示应降级
/// （跳过该正则 / 回退字面量替换 / 返回空结果，由调用方按原版语义处理）。
pub fn compile_regex_safe(pattern: &str) -> Option<Arc<Regex>> {
    let mut cache = REGEX_CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(entry) = cache.get(pattern) {
        return entry.clone().ok();
    }
    // 首次编译该 pattern：输出诊断日志（pattern 前 64 字符 + 线程名）
    regex_safe_log(&format!(
        "首次编译 pattern（线程 {}），前64字符: {}",
        current_thread_name(),
        pattern_head(pattern)
    ));
    let entry = compile_pattern_checked(pattern);
    let result = entry.clone().ok();
    cache.put(pattern.to_string(), entry);
    result
}

/// 长度/嵌套预检 + 隔离线程编译，返回缓存条目（成功或失败原因）
fn compile_pattern_checked(pattern: &str) -> Result<Arc<Regex>, String> {
    if pattern.len() > MAX_REGEX_PATTERN_LEN {
        let msg = format!(
            "pattern too long: {}B > {}B limit",
            pattern.len(),
            MAX_REGEX_PATTERN_LEN
        );
        regex_safe_log(&format!(
            "拒绝超长 pattern（{}），前64字符: {}",
            msg,
            pattern_head(pattern)
        ));
        return Err(msg);
    }
    // 非递归结构预检：nest_limit 语义的真正等价物（零栈风险）
    let depth = max_nesting_depth(pattern);
    if depth > MAX_REGEX_NEST_DEPTH {
        let msg = format!("nesting too deep: depth {} > {} limit", depth, MAX_REGEX_NEST_DEPTH);
        regex_safe_log(&format!(
            "拒绝病态嵌套 pattern（{}），前64字符: {}",
            msg,
            pattern_head(pattern)
        ));
        return Err(msg);
    }
    // 8MB 栈独立线程编译：兜底防御（见 compile_on_stack 文档）
    match compile_regex_on_stack(pattern, SAFE_COMPILE_STACK_SIZE) {
        Some(re) => Ok(Arc::new(re)),
        None => {
            let msg = "regex compile failed (invalid syntax or compile thread aborted)".to_string();
            regex_safe_log(&format!(
                "正则编译失败（编译阶段），前64字符: {}",
                pattern_head(pattern)
            ));
            Err(msg)
        }
    }
}

/// 安全编译 fancy-regex 方言 pattern（lookbehind/lookahead/backreference/原子组）。
///
/// 与 [`compile_regex_safe`] 相同的预检防御（1KB 上限 + 非递归嵌套预检），
/// 但**不走 regex 缓存**：fancy 方言含 regex-syntax 不认识的语法
/// （lookaround/backreference），缓存键空间不同，按需编译。
/// 编译同样放在 8MB 栈独立线程兜底。失败返回 None，调用方降级。
pub fn compile_fancy_regex_safe(pattern: &str) -> Option<fancy_regex::Regex> {
    if pattern.len() > MAX_REGEX_PATTERN_LEN {
        regex_safe_log(&format!(
            "拒绝超长 fancy pattern（{}B > {}B 上限），前64字符: {}",
            pattern.len(),
            MAX_REGEX_PATTERN_LEN,
            pattern_head(pattern)
        ));
        return None;
    }
    // 同一非递归结构预检：病态嵌套在调用方线程即被拦截（零栈风险）
    let depth = max_nesting_depth(pattern);
    if depth > MAX_REGEX_NEST_DEPTH {
        regex_safe_log(&format!(
            "拒绝病态嵌套 fancy pattern（depth {} > {}），前64字符: {}",
            depth,
            MAX_REGEX_NEST_DEPTH,
            pattern_head(pattern)
        ));
        return None;
    }
    let owned = pattern.to_string();
    let compiled = compile_on_stack(SAFE_COMPILE_STACK_SIZE, move || fancy_regex::Regex::new(&owned));
    match compiled {
        Some(Ok(re)) => Some(re),
        Some(Err(e)) => {
            regex_safe_log(&format!(
                "fancy 正则编译失败（{}），前64字符: {}",
                e,
                pattern_head(pattern)
            ));
            None
        }
        None => {
            regex_safe_log(&format!(
                "fancy 正则编译异常（线程退出），前64字符: {}",
                pattern_head(pattern)
            ));
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

    // ─── 非递归结构预检 ────────────────────────────────────

    #[test]
    fn test_max_nesting_depth_escape_and_class_literals() {
        // 转义与字符类内字面量不计嵌套
        assert_eq!(max_nesting_depth(r"\(\(\("), 0, "转义括号不计嵌套");
        assert_eq!(max_nesting_depth(r"[(\[]"), 1, "字符类内 ( 与转义 \\[ 为字面量，仅 [ 计 1 层");
        assert_eq!(max_nesting_depth(r"(a)(b)(c)"), 1, "平级分组深度为 1");
        assert_eq!(max_nesting_depth(r"((a))"), 2);
        assert_eq!(max_nesting_depth(r"(a[b(c)]d)"), 2, "( 内嵌 [ 深度叠加");
        assert_eq!(max_nesting_depth(r"[a-[b]]"), 2, "嵌套字符类的类内 [ 计入深度（保守偏严）");
        assert_eq!(max_nesting_depth(""), 0);
    }

    /// 构造深嵌套病态 pattern（超 1KB 长度防御上限）
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

    /// 深嵌套字符类病态 pattern（`[a-[b-[c-...]]]`），每层 +6 字节。
    /// 预检将类内 `[` 一并计深（保守偏严），depth=100 即达 601 层计深，
    /// 远超 32 上限，1KB 内即可稳定触发预检拒绝。
    fn nested_char_class_pattern(depth: usize) -> String {
        let mut p = String::from("z");
        for _ in 0..depth {
            p = format!("[a-[{}]]", p);
        }
        p
    }

    #[test]
    fn test_compile_regex_safe_nested_char_class_pathological() {
        // 200 层嵌套字符类（约 1.2KB）：超 1KB 上限，长度防御直接拒绝
        let p200 = nested_char_class_pattern(200);
        assert!(p200.len() > MAX_REGEX_PATTERN_LEN);
        assert!(compile_regex_safe(&p200).is_none());
        // 100 层嵌套字符类（601B ≤ 1KB）：不走长度拦截，
        // 由非递归结构预检（计深 601 > 32）拦截，安全降级不崩溃
        let p100 = nested_char_class_pattern(100);
        assert!(p100.len() <= MAX_REGEX_PATTERN_LEN);
        assert!(max_nesting_depth(&p100) > MAX_REGEX_NEST_DEPTH);
        assert!(
            compile_regex_safe(&p100).is_none(),
            "1KB 内 100 层嵌套字符类应被非递归预检拦截降级"
        );
    }

    #[test]
    fn test_compile_regex_safe_deep_group_nesting_within_1kb() {
        // 1KB 内约 500 层 `(` 嵌套（500×( + a + 500×) = 1001B）：
        // 非递归预检在调用方线程直接拒绝，绝不进入 regex-syntax 递归管线
        let p = format!("{}a{}", "(".repeat(500), ")".repeat(500));
        assert!(p.len() <= MAX_REGEX_PATTERN_LEN);
        assert_eq!(max_nesting_depth(&p), 500);
        assert!(compile_regex_safe(&p).is_none(), "500 层分组嵌套应被预检拒绝");
        assert!(
            compile_fancy_regex_safe(&p).is_none(),
            "fancy 路径同样应被预检拒绝"
        );
    }

    #[test]
    fn test_precheck_rejects_on_2mb_stack_thread() {
        // 任务⑤指定场景：在 2MB 栈线程（模拟 tokio worker）上编译
        // 1KB 内约 200 层嵌套字符类（p200 走长度拦截、p100 走预检拦截）
        // 与 500 层 `(` 嵌套 pattern：预检为纯迭代扫描，
        // 调用方线程零栈风险，拒绝且不崩溃。
        let handle = std::thread::Builder::new()
            .name("sim-tokio-worker-2mb".to_string())
            .stack_size(2 << 20)
            .spawn(|| {
                let p_class_200 = nested_char_class_pattern(200);
                assert!(p_class_200.len() > MAX_REGEX_PATTERN_LEN);
                assert!(compile_regex_safe(&p_class_200).is_none());
                let p_class_100 = nested_char_class_pattern(100);
                assert!(p_class_100.len() <= MAX_REGEX_PATTERN_LEN);
                assert!(compile_regex_safe(&p_class_100).is_none());
                let p_group = format!("{}a{}", "(".repeat(500), ")".repeat(500));
                assert!(compile_regex_safe(&p_group).is_none());
                // 常规 pattern 在 2MB 栈调用方上行为不变
                let ok = compile_regex_safe(r"\d+").expect("常规 pattern 应编译成功");
                assert_eq!(ok.find("x42y").unwrap().as_str(), "42");
            })
            .expect("spawn 失败");
        handle.join().expect("2MB 栈线程上调用 compile_regex_safe 不应崩溃");
    }

    #[test]
    fn test_compile_regex_safe_deep_nesting_within_limit() {
        // 深嵌套但长度在限内：安全路径由非递归预检拒绝（None），
        // 与直连编译同果（regex-syntax 递归上限 → Err），不 panic、不崩溃
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
            "前置条件：深嵌套 pattern 应超出 regex-syntax 递归上限"
        );
    }

    // ─── 缓存：负缓存命中 + LRU 淘汰 ───────────────────────

    #[test]
    fn test_compile_regex_safe_negative_cache_hit() {
        // 病态/非法 pattern 负缓存：二次调用直接命中缓存返回 None
        assert!(compile_regex_safe(r"(unclosed-neg").is_none());
        assert!(compile_regex_safe(r"(unclosed-neg").is_none());
        let mut cache = REGEX_CACHE.lock().unwrap();
        assert!(
            matches!(cache.get(r"(unclosed-neg"), Some(Err(_))),
            "非法 pattern 应存在负缓存"
        );
    }

    #[test]
    fn test_cache_lru_eviction_not_clear_all() {
        // LRU 淘汰正确性：超容量时逐出最久未用条目，而非整体 clear()
        {
            let mut cache = REGEX_CACHE.lock().unwrap();
            for i in 0..(REGEX_CACHE_CAPACITY + 64) {
                cache.put(format!("__lru_probe_{i}__"), Ok(Arc::new(
                    Regex::new(r"a").unwrap(),
                )));
            }
            assert!(
                cache.len() <= REGEX_CACHE_CAPACITY,
                "缓存容量应受 LRU 上限约束（实际 {}）",
                cache.len()
            );
            assert!(
                cache.peek("__lru_probe_0__").is_none(),
                "最早插入的条目应被 LRU 逐出"
            );
            assert!(
                cache
                    .peek(&format!("__lru_probe_{}__", REGEX_CACHE_CAPACITY + 63))
                    .is_some(),
                "最近插入的条目应保留"
            );
        }
        // 清理探针条目，避免污染其他测试的缓存命中判定
        let mut cache = REGEX_CACHE.lock().unwrap();
        cache.clear();
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
        // 非递归预检零栈风险 + 编译在内部 8MB 栈子线程执行，调用方不崩溃。
        let handle = std::thread::Builder::new()
            .stack_size(512 << 10)
            .spawn(|| {
                let ok = compile_regex_safe(r"\d{4}-\d{2}-\d{2}").expect("常规 pattern 应编译成功");
                assert!(ok.is_match("2026-08-10"));
                let bad = compile_regex_safe(r"(?P<dup>a)(?P<dup>b)");
                assert!(bad.is_none(), "非法 pattern 应降级为 None");
                // 病态嵌套在小栈线程上同样安全（预检为纯迭代扫描）
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
