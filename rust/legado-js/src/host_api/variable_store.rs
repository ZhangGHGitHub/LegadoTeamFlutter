//! 变量存储 API
//!
//! 提供全局变量存取功能，对应 Kotlin 端 `JsExtensions` 中
//! AnalyzeRule 变量表的功能：
//! - getVariable(key) — 获取变量
//! - setVariable(key, value) — 设置变量
//! - removeVariable(key) — 删除变量
//! - clearVariables() — 清空所有变量

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};

/// 全局变量存储（线程安全单例）
///
/// 对应 Kotlin 端 AnalyzeRule 变量映射。
/// 使用 `Arc<Mutex<HashMap>>` 保证线程安全。
static GLOBAL_VARIABLES: LazyLock<Arc<Mutex<HashMap<String, String>>>> =
    LazyLock::new(|| Arc::new(Mutex::new(HashMap::new())));

/// 获取全局变量映射的句柄（用于注入到 QuickJS 上下文）
pub fn get_variable_store() -> Arc<Mutex<HashMap<String, String>>> {
    Arc::clone(&GLOBAL_VARIABLES)
}

/// 获取变量值
///
/// 对应 Kotlin: `getVariable(key)`
pub fn get_variable(key: &str) -> Result<Option<String>, String> {
    let store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    Ok(store.get(key).cloned())
}

/// 设置变量值
///
/// 对应 Kotlin: `setVariable(key, value)`
pub fn set_variable(key: &str, value: &str) -> Result<(), String> {
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    store.insert(key.to_string(), value.to_string());
    Ok(())
}

/// 删除变量
pub fn remove_variable(key: &str) -> Result<Option<String>, String> {
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    Ok(store.remove(key))
}

/// 清空所有变量
pub fn clear_variables() -> Result<(), String> {
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    store.clear();
    Ok(())
}

/// 获取所有变量名
pub fn list_variable_keys() -> Result<Vec<String>, String> {
    let store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    Ok(store.keys().cloned().collect())
}

// ============================================================
// P2-9 ③ 书籍流程会话变量作用域（flow scope）
// ============================================================
//
/// 流程作用域键格式：`lgflow::{scope}{key}`（SOH 分隔符）。
///
/// 与既有键空间不碰撞：持久键为裸键（`cache.put`/`source.put` 经
/// `v_{sourceUrl}_{k}` / `sourceVariable_*` / `loginHeader_*` /
/// `userInfo_*` 约定）或带下划线前缀，`lgflow:` 前缀 + SOH 分隔符
/// 保证唯一归本层。
const FLOW_KEY_PREFIX: &str = "lgflow:";
const FLOW_KEY_SEP: char = '\u{1}';

/// 当前书籍流程作用域（进程级单槽）。
///
/// P1-1/P1-2 修复：`begin_book_flow` 由「整表 `clear_variables()`」改为
/// 「切换 scope、只清旧 scope 前缀」——持久键（书源 `source.put`/
/// `source.setVariable`/登录缓存/`cache.*`，上游对应持久 CacheManager）
/// 是裸键、永不命中 `lgflow::{scope}` 前缀 → 换书不再误清；会话变量
/// （解析器 JS 前导 `java.put`/`java.get` 经 `__lgStorePut`/`__lgStoreGet`
/// 桥写入）按 flow 命名空间隔离 → 跨书源/跨书 `@get` 兜底不再互串。
static FLOW_SCOPE: LazyLock<Mutex<Option<String>>> = LazyLock::new(|| Mutex::new(None));

fn flow_key(scope: &str, key: &str) -> String {
    format!("{FLOW_KEY_PREFIX}{scope}{FLOW_KEY_SEP}{key}")
}

fn flow_key_prefix(scope: &str) -> String {
    format!("{FLOW_KEY_PREFIX}{scope}{FLOW_KEY_SEP}")
}

/// 清除指定 scope 前缀下的全部会话键（外科手术式，不触碰裸键/其他前缀）
fn clear_flow_prefix(scope: &str) -> Result<(), String> {
    let prefix = flow_key_prefix(scope);
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    store.retain(|k, _| !k.starts_with(&prefix));
    Ok(())
}

/// 设置当前流程作用域（`begin_book_flow` 的底层实现）
///
/// - scope 与当前相同 → 无操作（同一本书 info → toc → content 链不清空，
///   保住同书会话变量快路径）；
/// - scope 变化 → 只清**旧** scope 前缀（上一本书的会话键），再写入新
///   scope。裸键持久数据（`v_*`/`sourceVariable_*`/`loginHeader_*`/
///   `userInfo_*`/`cache.*`）不受影响（P1-1）。
pub fn set_flow_scope(scope: &str) -> Result<(), String> {
    let mut cur = FLOW_SCOPE
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    if cur.as_deref() != Some(scope) {
        if let Some(old) = cur.take() {
            clear_flow_prefix(&old)?;
        }
        *cur = Some(scope.to_string());
    }
    Ok(())
}

/// 清除当前 scope 前缀并把 scope 复位为 None（测试收尾/流程生命周期结束）
pub fn clear_flow_scope() -> Result<(), String> {
    let old = FLOW_SCOPE
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?
        .take();
    if let Some(old) = old {
        clear_flow_prefix(&old)?;
    }
    Ok(())
}

/// 读取当前流程作用域（None = 未进入书籍流程）
pub fn current_flow_scope() -> Option<String> {
    FLOW_SCOPE.lock().ok().and_then(|g| g.clone())
}

/// 写会话变量（`java.__lgStorePut` 桥）
///
/// - scope 已设置 → 写 `lgflow::{scope}{key}`（按流程隔离）；
/// - 无 scope（未走书籍流程入口的直用引擎/残留入口）→ 写裸键，行为与
///   P2-9 ③ 引入前一致。
pub fn put_flow_variable(key: &str, value: &str) -> Result<(), String> {
    let k = match current_flow_scope() {
        Some(scope) => flow_key(&scope, key),
        None => key.to_string(),
    };
    set_variable(&k, value)
}

/// 读会话变量（`java.__lgStoreGet` 桥 / 解析器 `@get` 全局兜底读者）
///
/// 读取优先级（**既有链路逐层不变**，bookVar 兜底仅追加于链尾）：
/// 1. scope 已设置 → `lgflow::{scope}{key}`（本流程会话层）；
/// 2. 未命中 → 裸键 `{key}`（持久层：`cache.*`/源上下文裸 `java.put`
///    等，上游 CacheManager 语义，跨书存活——P1-1 的持久键修复同一机制）；
/// 3. 【P2-15】仍未命中且 scope 已设置 → `bookVar::{scope}::{key}`
///    （book 绑定写路径层，见下）；
/// 4. 无 scope → 仅读裸键（与 P2-9 ③ 引入前一致，bookVar 兜底不生效）。
///
/// 第 3 步（P2-15 打通 `java.get`/`@get` ← `bookVar`）：`book.putVariable`
/// 等写入落在 `bookVar::{bookUrl}::{key}` 裸键（进程级、跨书存活）。上游
/// `AnalyzeRule.get()` 链是 `chapter → book → ruleData → source`——book
/// 变量本就对同书 `java.get` 可见；此前本函数只有会话层与裸键两层，
/// `bookVar` 层对 `java.get`/`@get` 完全不可见（就去看网语料：正文规则
/// `book.putVariable("序",…)` 后 `java.get("序")` 恒空，闭环断裂）。
/// 兜底键取**当前 flow scope**（书籍流程各入口经 `begin_book_flow` 写入，
/// 详情/目录/正文链上 scope 即该书 bookUrl）→ 天然按本书 bookUrl 命名
/// 空间隔离：只读本流程那本书的 bookVar，不允许跨书串读；search/explore
/// 入口的 scope（`search:{url}`/`explore:{url}`）下从未有过
/// `bookVar::search:{url}::` 键写入，兜底恒未命中（行为不变）；无 scope
/// 场景不挂兜底（保持 P2-9 ③ 引入前行为）。
///
/// 锁失败/未命中一律返回 None（读者闭包不向 FFI 传播错误）。
pub fn get_flow_variable(key: &str) -> Option<String> {
    match current_flow_scope() {
        Some(scope) => {
            if let Some(v) = get_variable(&flow_key(&scope, key)).ok().flatten() {
                return Some(v);
            }
            if let Some(v) = get_variable(key).ok().flatten() {
                return Some(v);
            }
            // P2-15：bookVar 兜底（链尾，键 = 当前 scope 的本书 bookVar 键）
            get_variable(&book_var_key(&scope, key)).ok().flatten()
        }
        None => get_variable(key).ok().flatten(),
    }
}

// ============================================================
// P2-11 ① book 绑定写路径命名空间（裸键持久层键构造器）
// ============================================================
//
/// book 绑定写路径存储键构造器（**裸键**——持久层，P1-1 语义：永不命中
/// flow scope 前缀、换书/换流程不清空）。
///
/// 写入方：QuickJS 宿主桥 `java.__lgBookVarSet/__lgBookVarDel/__lgBookSetType/
/// __lgBookSetReverseToc`（quickjs_impl.rs `register_book_binding_bridges`，
/// 由 `book` 绑定 IIFE 的 putVariable/setType/setReverseToc 及直接赋值
/// `book.type = N` 触发）。
///
/// 读取方：FFI `book` 绑定构造（legado-ffi web_book.rs `iife_book_expr`）按
/// bookUrl 前缀枚举合并回绑定字面量（variable 覆盖层 / type / reverseToc
/// 初值）。两侧共用本组构造器，键格式不漂移。
///
/// 生命周期：**进程级**（应用重启即失——降级项，未直接落 DB `books.variable`；
/// 详情解析期 FFI 会把覆盖层并入 `WebBookInfo.variable` 走既有 DB 合并路径，
/// 见 web_book.rs `parse_book_info_from_body` 注释）。
///
/// 可见性（P2-15 修正，此前「后续规则/请求均可见」表述不准确）：
/// - **`book` 绑定构造期**（FFI `iife_book_expr` 经
///   `web_book::book_write_overlays` 读回合并）：同 bookUrl 的详情→目录→
///   正文链、第二次详情、换源刷新，各阶段**新构造**的绑定初值含此前写入；
///   但**同一次构造的绑定字面量是构造期快照**——同阶段后续规则的新
///   IIFE 实例只看到构造时点的值，其他规则在构造后对 store 的写入不会
///   反向改写已有字面量（P2-15 由 IIFE `getVariable` 的 `__lgBookVarGet`
///   store 兜底补齐同阶段跨规则读路径，见 web_book.rs IIFE 注释）；
/// - **`java.get`/`@get`**（P2-15）：经 [`get_flow_variable`] 链尾 bookVar
///   兜底，同书同流程（flow scope = 该书 bookUrl 的详情/目录/正文链）内
///   `book.putVariable` 写入对后续 `java.get`/`@get` 可见；
/// - 跨书以 bookUrl 命名空间隔离，不串读。
pub fn book_var_key(book_url: &str, key: &str) -> String {
    format!("bookVar::{book_url}::{key}")
}

/// `bookVar::{bookUrl}::` 前缀（绑定构造期枚举覆盖层用）
pub fn book_var_key_prefix(book_url: &str) -> String {
    format!("bookVar::{book_url}::")
}

/// `bookType::{bookUrl}`（book.setType / book.type = N；值为 BookType 位标志
/// 字符串，如 "8"/"32"/"64"，对齐上游 io.legado.app.constant.BookType）
pub fn book_type_key(book_url: &str) -> String {
    format!("bookType::{book_url}")
}

/// `bookReverseToc::{bookUrl}`（book.setReverseToc；"true"/"false"）
pub fn book_reverse_toc_key(book_url: &str) -> String {
    format!("bookReverseToc::{book_url}")
}

// ============================================================
// 测试基础设施（快照守卫 + 互斥锁）
// ============================================================
/// 全局态快照-恢复守卫（仅测试用，照抄 config_api.rs StoreGuard 模式）
///
/// 构造时快照 `GLOBAL_VARIABLES` 全量 `HashMap` 与 `FLOW_SCOPE`，`Drop` 时
/// 整体恢复原内容——panic 路径同样经 `Drop` 恢复。用于消除 cargo 默认多线程
/// 并行跑测时，`test_clear_variables` 的 `clear_variables()`（清空整表）与
/// 其他 set/get 类测试对进程级全局 `GLOBAL_VARIABLES` 的交叉污染：写入类
/// 测试结束（含 panic）后自动恢复原值，不向后续/并行测试泄漏清空或残留
/// 状态（含 flow scope，防 `set_flow_scope` 残留到并行测试）。
#[cfg(test)]
pub(crate) struct StoreGuard {
    previous: HashMap<String, String>,
    previous_scope: Option<String>,
}

#[cfg(test)]
impl StoreGuard {
    pub(crate) fn new() -> Self {
        let scope = FLOW_SCOPE.lock().unwrap_or_else(|p| p.into_inner()).clone();
        let store = GLOBAL_VARIABLES.lock().unwrap_or_else(|p| p.into_inner());
        Self {
            previous: store.clone(),
            previous_scope: scope,
        }
    }
}

#[cfg(test)]
impl Drop for StoreGuard {
    fn drop(&mut self) {
        let mut store = GLOBAL_VARIABLES.lock().unwrap_or_else(|p| p.into_inner());
        *store = self.previous.clone();
        let mut scope = FLOW_SCOPE.lock().unwrap_or_else(|p| p.into_inner());
        *scope = self.previous_scope.clone();
    }
}

/// 测试间互斥锁：串行化**所有**触碰全局变量表/flow scope 的测试（本模块
/// 自身测试 + `quickjs_impl` 的 P2-9 ③ 桥测试等），其余测试仍照常并行。
/// 避免 `clear_variables()`（整表清空）/`clear_flow_scope`（前缀清空）与
/// 写入/读取类测试真正并发交错（如某测试 set 后、get 前被 clear 插入，
/// 导致读到 None）。
///
/// P2-2 统一锁：本锁是变量表测试串行化的**唯一**锁——此前 `quickjs_impl`
/// 自带 `P29_LOCK` 与本锁互不互斥，`StoreGuard::drop` 的整体恢复会抹掉
/// 并行 P29 测试刚写入的键（间歇性失败）。现 `quickjs_impl` 测试改经
/// [`lock_variables`] 取本锁，`P29_LOCK` 已删除。
#[cfg(test)]
static VARIABLES_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 获取测试互斥锁（panic 时经 Drop 自动释放，不会永久卡死后续测试）
#[cfg(test)]
pub(crate) fn lock_variables() -> std::sync::MutexGuard<'static, ()> {
    VARIABLES_TEST_LOCK
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}

// ============================================================
// 单元测试
// ============================================================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_set_and_get_variable() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        set_variable("var_set_get", "bar").unwrap();
        assert_eq!(
            get_variable("var_set_get").unwrap(),
            Some("bar".to_string())
        );
    }

    #[test]
    fn test_get_nonexistent_variable() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        assert_eq!(get_variable("var_never_exists_xyz").unwrap(), None);
    }

    #[test]
    fn test_overwrite_variable() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let key = "var_overwrite";
        set_variable(key, "v1").unwrap();
        set_variable(key, "v2").unwrap();
        assert_eq!(get_variable(key).unwrap(), Some("v2".to_string()));
    }

    #[test]
    fn test_remove_variable() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let key = "var_remove_target";
        set_variable(key, "value").unwrap();
        let removed = remove_variable(key).unwrap();
        assert_eq!(removed, Some("value".to_string()));
        assert_eq!(get_variable(key).unwrap(), None);
    }

    #[test]
    fn test_clear_variables() {
        let _lock = lock_variables();
        // 守卫快照整表，测试结束（含 panic）恢复，避免 clear 泄漏给并行测试
        let _guard = StoreGuard::new();
        let key_a = "var_clear_a";
        let key_b = "var_clear_b";
        set_variable(key_a, "1").unwrap();
        set_variable(key_b, "2").unwrap();
        clear_variables().unwrap();
        assert_eq!(get_variable(key_a).unwrap(), None);
        assert_eq!(get_variable(key_b).unwrap(), None);
    }

    #[test]
    fn test_list_variable_keys() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        set_variable("var_list_x", "1").unwrap();
        set_variable("var_list_y", "2").unwrap();
        let keys = list_variable_keys().unwrap();
        assert!(keys.contains(&"var_list_x".to_string()));
        assert!(keys.contains(&"var_list_y".to_string()));
    }

    #[test]
    fn test_get_variable_store_handle() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let store = get_variable_store();
        let mut guard = store.lock().unwrap();
        guard.insert("var_handle_test".to_string(), "ok".to_string());
        drop(guard);
        assert_eq!(
            get_variable("var_handle_test").unwrap(),
            Some("ok".to_string())
        );
    }

    // ── P2-9 ③ flow scope（P1-1/P1-2）────────────────────────────────

    /// P1-1 验收语义：换书（scope 切换）只清旧 scope 前缀，持久裸键
    /// （`v_{sourceUrl}_k`/`sourceVariable_*` 等）存活；会话键被清。
    #[test]
    fn test_flow_scope_switch_keeps_persistent_bare_keys() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        // 持久层：源搜索期 source.put / source.setVariable 写入的裸键
        set_variable("v_x_k", "tok").unwrap();
        set_variable("sourceVariable_x", "s").unwrap();
        // 书 A 流程会话键（__lgStorePut 经 scope 写入）
        set_flow_scope("book_a").unwrap();
        put_flow_variable("url", "aUrl").unwrap();
        assert_eq!(get_flow_variable("url"), Some("aUrl".into()));

        // 换书（B）：旧 scope 前缀清、scope 切到 B
        set_flow_scope("book_b").unwrap();
        // P1-1 验收断言：持久裸键两键仍存
        assert_eq!(get_variable("v_x_k").unwrap(), Some("tok".into()));
        assert_eq!(get_variable("sourceVariable_x").unwrap(), Some("s".into()));
        // 会话键：A 的 url 不可见（已清），裸回退亦无 → 空
        assert_eq!(get_flow_variable("url"), None);
        // 新 scope 写入可读
        put_flow_variable("页", "1").unwrap();
        assert_eq!(get_flow_variable("页"), Some("1".into()));
        // 收尾：清 scope（guard 也会兜底恢复）
        clear_flow_scope().unwrap();
        assert_eq!(current_flow_scope(), None);
    }

    /// 同 scope 重复 set = 无操作（同书 info→toc→content 链不清空）
    #[test]
    fn test_flow_scope_same_key_is_noop() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        set_flow_scope("book_x").unwrap();
        put_flow_variable("k", "v").unwrap();
        set_flow_scope("book_x").unwrap();
        assert_eq!(get_flow_variable("k"), Some("v".into()));
        clear_flow_scope().unwrap();
    }

    /// scope 已设置时读取优先级：scoped 命中即返回；未命中回退裸键
    #[test]
    fn test_flow_get_prefers_scoped_then_bare() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        set_variable("bare_only", "bare-v").unwrap();
        set_flow_scope("s1").unwrap();
        assert_eq!(get_flow_variable("bare_only"), Some("bare-v".into()));
        put_flow_variable("dup", "scoped-v").unwrap();
        set_variable("dup", "bare-v2").unwrap();
        assert_eq!(get_flow_variable("dup"), Some("scoped-v".into()));
        clear_flow_scope().unwrap();
    }

    /// 无 scope（未走书籍流程入口）：put/get 走裸键（P2-9 ③ 前行为）
    #[test]
    fn test_flow_put_get_without_scope_is_bare() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        assert_eq!(current_flow_scope(), None);
        put_flow_variable("ns_k", "ns_v").unwrap();
        assert_eq!(get_variable("ns_k").unwrap(), Some("ns_v".into()));
        assert_eq!(get_flow_variable("ns_k"), Some("ns_v".into()));
    }

    /// clear_flow_scope：清当前前缀并复位 None（会话键消失，裸键保留）
    #[test]
    fn test_clear_flow_scope() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        set_variable("persist_k", "persist-v").unwrap();
        set_flow_scope("s2").unwrap();
        put_flow_variable("sess_k", "sess-v").unwrap();
        clear_flow_scope().unwrap();
        assert_eq!(current_flow_scope(), None);
        assert_eq!(get_variable("sess_k").unwrap(), None); // scoped 键已清（裸键本就不存在）
        assert_eq!(get_variable("persist_k").unwrap(), Some("persist-v".into()));
        // 再清一次（已 None）= 无操作不报错
        clear_flow_scope().unwrap();
    }

    /// P2-11 ①：book 写路径键格式固化（宿主桥写入方 / FFI 合并读取方共用）
    #[test]
    fn test_book_write_path_key_format() {
        let book_url = "https://example.com/b/1";
        assert_eq!(
            book_var_key(book_url, "k"),
            "bookVar::https://example.com/b/1::k"
        );
        assert_eq!(
            book_var_key_prefix(book_url),
            "bookVar::https://example.com/b/1::"
        );
        assert_eq!(book_type_key(book_url), "bookType::https://example.com/b/1");
        assert_eq!(
            book_reverse_toc_key(book_url),
            "bookReverseToc::https://example.com/b/1"
        );
        // 裸键：不命中 flow scope 前缀，换书清 scope 时不受影响（P1-1）
        assert!(!book_var_key(book_url, "k").starts_with(FLOW_KEY_PREFIX));
    }

    // ── P2-15：get_flow_variable 的 bookVar 链尾兜底 ─────────────────────

    /// 优先级链固化：会话层（scoped）> 裸键 > bookVar（仅 scope 已设置时
    /// 挂兜底）；逐层撤掉上层后兜底才可达，三层皆空 → None。
    #[test]
    fn test_p215_flow_get_bookvar_fallback_is_last_resort() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let book_url = "https://p215-priority.example.com/b/priority";
        set_flow_scope(book_url).unwrap();
        let k = "k";
        // 三层同键、不同值（会话层经 put_flow_variable 写 scoped 键）
        set_variable(&book_var_key(book_url, k), "bookvar-v").unwrap();
        set_variable(k, "bare-v").unwrap();
        put_flow_variable(k, "session-v").unwrap();
        // 1) 会话层优先（既有行为不回归）
        assert_eq!(get_flow_variable(k), Some("session-v".into()));
        // 2) 撤会话层 → 裸键优先
        let _ = remove_variable(&flow_key(book_url, k));
        assert_eq!(get_flow_variable(k), Some("bare-v".into()));
        // 3) 撤裸键 → bookVar 兜底可达（P2-15 新行为）
        let _ = remove_variable(k);
        assert_eq!(get_flow_variable(k), Some("bookvar-v".into()));
        // 4) 三层皆空 → None
        let _ = remove_variable(&book_var_key(book_url, k));
        assert_eq!(get_flow_variable(k), None);
        clear_flow_scope().unwrap();
    }

    /// 跨书隔离：bookVar 兜底键 = 当前 scope（本书 bookUrl）→ A 书的
    /// bookVar 在 B 书流程内不可见；bookVar 键属裸键持久层，换书切
    /// scope 不清空（A 切回后仍可读回 A 的值）。
    #[test]
    fn test_p215_bookvar_fallback_cross_book_isolation() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let book_a = "https://p215-xbook.example.com/b/a";
        let book_b = "https://p215-xbook.example.com/b/b";
        // 两本书各自写入同名 key（各自 bookVar 键，裸键层）
        set_variable(&book_var_key(book_a, "seq"), "a-seq").unwrap();
        set_variable(&book_var_key(book_b, "seq"), "b-seq").unwrap();
        // A 书流程内：只读 A 的 bookVar
        set_flow_scope(book_a).unwrap();
        assert_eq!(get_flow_variable("seq"), Some("a-seq".into()));
        // 换书 B：A 的 bookVar 不可见（scope 切走，兜底键变为 B 的键）
        set_flow_scope(book_b).unwrap();
        assert_eq!(get_flow_variable("seq"), Some("b-seq".into()));
        // bookVar 键持久：切回 A 仍能读回 A 的值（跨书不串读、不互清）
        set_flow_scope(book_a).unwrap();
        assert_eq!(get_flow_variable("seq"), Some("a-seq".into()));
        for key in [book_var_key(book_a, "seq"), book_var_key(book_b, "seq")] {
            let _ = remove_variable(&key);
        }
        clear_flow_scope().unwrap();
    }

    /// 无 scope（未走书籍流程入口）：不挂 bookVar 兜底——仅 bookVar 键
    /// 存在的 key 读不到（保持 P2-9 ③ 引入前行为，防止无流程上下文的
    /// 直用引擎意外命中他书 bookVar 残留键）。
    #[test]
    fn test_p215_bookvar_fallback_absent_without_scope() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        assert_eq!(current_flow_scope(), None, "前置：无 scope");
        set_variable(
            &book_var_key("https://p215-noscope.example.com/b/x", "k"),
            "bv",
        )
        .unwrap();
        assert_eq!(get_flow_variable("k"), None, "无 scope 不挂 bookVar 兜底");
        // 对照：scope 设为该 bookUrl 后兜底生效
        set_flow_scope("https://p215-noscope.example.com/b/x").unwrap();
        assert_eq!(get_flow_variable("k"), Some("bv".into()));
        let _ = remove_variable(&book_var_key("https://p215-noscope.example.com/b/x", "k"));
        clear_flow_scope().unwrap();
    }
}
