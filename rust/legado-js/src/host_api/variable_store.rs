//! 变量存储 API
//!
//! 提供全局变量存取功能，对应 Kotlin 端 `JsExtensions` 中
//! AnalyzeRule 变量表的功能：
//! - getVariable(key) — 获取变量
//! - setVariable(key, value) — 设置变量
//! - removeVariable(key) — 删除变量
//! - clearVariables() — 清空所有变量
//!
//! # 持久化（B6/A4）
//!
//! 对齐上游 `CacheManager`（`caches` 表，`deadline=0` 永久）：书源运行时
//! 变量五族（`v_` / `userInfo_` / `loginHeader_` / `sourceVariable_` /
//! `infoMap_`）经 [`VariableSink`] 写穿到 DB，进程启动时由
//! [`backfill_from_sink`] 回填内存。其余键（`lgflow::` 会话层、
//! `bookVar::` / `bookType::` 进程级绑定层、裸会话键）**不落库**——它们
//! 的语义就是进程内/流程内，落库会改变语义（且备份格式的运行时缓存段
//! 只覆盖上述五族，见 `legado-ffi` 备份实现）。
//!
//! # 读路径：内存 → DB → 回填内存（P1-3，批10 审查）
//!
//! 五族持久键的读（[`get_flow_variable`] / [`get_persisted_variable`]）在内存
//! miss 时**回查持久层**并回填内存——对齐上游 `CacheManager.get` 的三级读。
//! 由此「清内存」天然等价于「下次读重载」：备份恢复写完 `caches` 行后调
//! [`clear_source_variables`]，此后 `source.get()` / `source.getLoginHeader()`
//! **无需重启**即可读到恢复值；删源链路先删 DB 行再清内存，回查恒 miss
//! 不会复活。
//!
//! `legado-js` 自身不依赖 DB：下沉由宿主（FFI / server）在 DB 初始化点
//! 注册一次（first-wins），未注册时纯内存，行为与改造前一致。

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex, OnceLock};

/// 全局变量存储（线程安全单例）
///
/// 对应 Kotlin 端 AnalyzeRule 变量映射。
/// 使用 `Arc<Mutex<HashMap>>` 保证线程安全。
static GLOBAL_VARIABLES: LazyLock<Arc<Mutex<HashMap<String, String>>>> =
    LazyLock::new(|| Arc::new(Mutex::new(HashMap::new())));

/// 需持久化的书源运行时变量键前缀（对齐上游 `CacheDao.deleteSourceVariables`
/// 的五族与备份格式 `runtimeSourceCache` 段）
pub const PERSISTED_KEY_PREFIXES: [&str; 5] = [
    "v_",
    "userInfo_",
    "loginHeader_",
    "sourceVariable_",
    "infoMap_",
];

/// 判断键是否属于需持久化的五族（前缀 + 非空后缀）
pub fn is_persisted_key(key: &str) -> bool {
    PERSISTED_KEY_PREFIXES
        .iter()
        .any(|prefix| key.starts_with(prefix) && key.len() > prefix.len())
}

/// 变量持久化下沉（由宿主注入；`legado-js` 自身不依赖任何 DB）
///
/// 对齐上游 `CacheManager.put/get/delete` 落 `caches` 表（`deadline = 0`
/// 永久）的语义：JS 侧 `source.put` / `source.setVariable` /
/// `putLoginHeader` / `putLoginInfo` / `infoMap_*` 写入经此下沉落库，
/// 进程启动时由 [`backfill_from_sink`] 回填内存，重启不丢。
///
/// 下沉调用发生在 JS 执行线程、且**在变量表锁释放之后**（不持锁跨 DB
/// I/O）：实现必须 `Send + Sync` 且快速；失败仅记日志、绝不向 JS 传播
/// （内存写入本身已成功，持久化失败不影响本进程读侧——对齐上游
/// 「持久化宽容失败」方向）。
pub trait VariableSink: Send + Sync {
    /// upsert 单个键值（`deadline = 0` 永久）
    fn upsert(&self, key: &str, value: &str);
    /// 删除单个键（幂等）
    fn remove(&self, key: &str);
    /// 加载全部持久化行（键 → 值），供启动回填
    fn load_all(&self) -> Vec<(String, String)>;
    /// 读取单个键（过期行返回 `None`）
    ///
    /// 供持久键**懒加载**（[`get_flow_variable`] 内存 miss 时回查）：对齐上游
    /// `CacheManager.get` 的「内存 → DB → 回填内存」三级读，使「清内存」天然
    /// 等价于「下次读从 DB 重载」——备份恢复/删源清内存后无需重启即可读到
    /// 权威值（P1-3）。失败返回 `None`（读侧宽容，不向 JS 传播）。
    fn get(&self, key: &str) -> Option<String>;
}

/// 全局持久化下沉（first-wins：宿主在 DB 初始化点注册一次，重复调用被忽略）
static VARIABLE_SINK: OnceLock<Arc<dyn VariableSink>> = OnceLock::new();

/// 注册变量持久化下沉（first-wins，后续调用被忽略）
///
/// 返回 `true` = 实际注册成功；`false` = 已存在下沉（忽略）。
/// **默认未注册 → 纯内存**（测试 / 无 DB 环境不受影响）。
pub fn set_variable_sink(sink: Arc<dyn VariableSink>) -> bool {
    VARIABLE_SINK.set(sink).is_ok()
}

/// 是否有已注册的持久化下沉（测试/诊断用）
pub fn has_variable_sink() -> bool {
    VARIABLE_SINK.get().is_some()
}

/// 写穿（内存写已完成后调用，不持变量表锁）
fn sink_upsert(key: &str, value: &str) {
    if !is_persisted_key(key) {
        return;
    }
    if let Some(sink) = VARIABLE_SINK.get() {
        sink.upsert(key, value);
    }
}

/// 删穿（内存删已完成后调用，不持变量表锁）
fn sink_remove(key: &str) {
    if !is_persisted_key(key) {
        return;
    }
    if let Some(sink) = VARIABLE_SINK.get() {
        sink.remove(key);
    }
}

/// 持久层单键读（不持变量表锁）
fn sink_get(key: &str) -> Option<String> {
    if !is_persisted_key(key) {
        return None;
    }
    VARIABLE_SINK.get().and_then(|sink| sink.get(key))
}

/// 持久键读：内存 → 持久层 → 回填内存（对齐上游 `CacheManager.get`）
///
/// P1-3 方案 2：持久五族键的读路径在内存 miss 时**回查持久层**并回填内存。
/// 这使「清内存」天然等价于「下次读从 DB 重载」：
/// - 备份恢复写入 `caches` 行后 `clear_source_variables()` 清内存 →
///   下一次 `source.get()` / `getLoginHeader()` **无需重启**即可读到恢复值；
/// - `clear_variables()`（整表清）同理；
/// - 删源链路先删 DB 行再清内存 → 回查恒 miss，不会复活。
///
/// 锁序：先取变量表锁读内存并释放，再在**不持锁**状态下做 DB I/O，最后
/// 重新取锁回填（与 [`set_variable`] 的「不持变量表锁跨库」约定一致）。
pub fn get_persisted_variable(key: &str) -> Option<String> {
    if let Ok(Some(v)) = get_variable(key) {
        return Some(v);
    }
    let loaded = sink_get(key)?;
    if let Ok(mut store) = GLOBAL_VARIABLES.lock() {
        store.insert(key.to_string(), loaded.clone());
    }
    Some(loaded)
}

/// 仅写内存（不写穿持久层）
///
/// 供宿主把「已从 DB 读到的值」回填进内存而不触发重复落库（`source_login_cache`
/// 的 DB 兜底读路径、备份恢复的显式重载等）。调用方须保证传入值即持久层权威值。
pub fn prime_memory(key: &str, value: &str) -> Result<(), String> {
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    store.insert(key.to_string(), value.to_string());
    Ok(())
}

/// 仅删内存（不触碰持久层）
///
/// 与 [`remove_variable`] 的区别：本函数不删 DB 行。供宿主在「DB 行已由自身
/// 删除」的路径上清内存（避免重复 DELETE），或模拟「清内存但保留持久行」。
pub fn remove_memory_only(key: &str) -> Result<Option<String>, String> {
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    Ok(store.remove(key))
}

/// 将持久化行回填进内存存储（宿主注册后调用一次，即进程启动点）
///
/// **内存优先、miss 回落**：同名键以既有内存值胜出（内存态可能更新，
/// 例如「模拟重启」前内存写入而 DB 行较旧）；DB 独有的键补齐。幂等：
/// 重复调用不改变既有内存值。未注册下沉时 no-op。
pub fn backfill_from_sink() {
    let Some(sink) = VARIABLE_SINK.get() else {
        return;
    };
    let rows = sink.load_all();
    if rows.is_empty() {
        return;
    }
    let mut store = match GLOBAL_VARIABLES.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    for (key, value) in rows {
        // 只回填五族键：下沉实现若误存了会话/绑定键，不得污染内存语义
        if !is_persisted_key(&key) {
            continue;
        }
        store.entry(key).or_insert(value);
    }
}

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

/// 设置变量值（五族键写穿持久层）
///
/// 对应 Kotlin: `setVariable(key, value)`
pub fn set_variable(key: &str, value: &str) -> Result<(), String> {
    {
        let mut store = GLOBAL_VARIABLES
            .lock()
            .map_err(|e| format!("Lock error: {}", e))?;
        store.insert(key.to_string(), value.to_string());
    }
    // 锁已释放再做 DB I/O（不持变量表锁跨库）
    sink_upsert(key, value);
    Ok(())
}

/// 删除变量（五族键同步删持久层）
///
/// P2-2（批10 审查）：删除**无条件下沉**，不以「内存是否命中」为门控。
/// 此前 `if removed.is_some() { sink_remove(key) }`：一旦内存被清（备份恢复
/// 路径的 `clear_source_variables`、整表 `clear_variables`），
/// `source.removeLoginHeader()` 只清内存不删 DB 行 → 下次启动
/// `backfill_from_sink` 把「已登出的登录头」复活。下沉侧 `remove` 本就是
/// 幂等 `DELETE`，无条件调用零额外语义成本。
pub fn remove_variable(key: &str) -> Result<Option<String>, String> {
    let removed = {
        let mut store = GLOBAL_VARIABLES
            .lock()
            .map_err(|e| format!("Lock error: {}", e))?;
        store.remove(key)
    };
    sink_remove(key);
    Ok(removed)
}

/// 清空所有变量（**仅内存**）
///
/// 与改造前语义一致：不触碰持久层。持久行的删除只由
/// [`remove_variable`]（显式删键）与宿主侧按源清理
/// （`CacheRepository::delete_source_variables`）发起——若此处连 DB 一起清，
/// 备份恢复链路（先写运行时缓存行、再调清理让引擎从 DB 重载）会把刚恢复的
/// 变量删掉。
pub fn clear_variables() -> Result<(), String> {
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    store.clear();
    Ok(())
}

/// 清除全部「源运行时缓存」族键（P1-2，批10 审查）
///
/// 逐条对齐原版 `AppCacheManager.clearSourceVariables`
/// （`app/src/main/java/io/legado/app/help/CacheManager.kt:35-46`）：删除内存
/// 表中所有以 `v_` / `userInfo_` / `loginHeader_` / `sourceVariable_` /
/// `infoMap_` 开头的键。**范围是整族而非单源**（原版即如此：DB 侧按源删
/// `v_{key}_%` 等 5 族后，再整体清一次内存快照）。
///
/// 调用方：源删除 / JS 源换 URL 保存成功后由
/// `legado-server/src/legacy/source_write_api.rs` 调用（与 DB
/// `CacheRepository::delete_source_variables` 配套）。
///
/// 键空间隔离：`lgflow::`、`bookVar::`、`bookType::`、`bookReverseToc::`
/// 等本轨新增前缀不在 5 族内，不受影响。
///
/// **只清内存**（与上游一致）：DB 行由调用方的 `delete_source_variables`
/// 负责；备份恢复链路也调用本函数「让引擎从 DB 重载」，此处删行会把刚恢复
/// 的运行时缓存抹掉。
///
/// P1-3：配合持久键读路径的**内存 miss 回查**，本函数的语义就是「丢弃内存
/// 快照，下一次读从 DB 重载」——恢复链路无需再等进程重启。删源链路因先删
/// DB 行，清后回查恒 miss，不会复活已删数据。
pub fn clear_source_variables() -> Result<(), String> {
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    store.retain(|key, _| !is_persisted_key(key));
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

/// [P2-15 剩项①] 清除指定 bookUrl 的 `bookType::` / `bookReverseToc::`
/// 裸键 overlay（流程会话级：scope 切换/结束时旧书的 type/reverseToc
/// 覆盖值失效，回落书源 `bookSourceType` 换算初值）。
///
/// **保留** `bookVar::{bookUrl}::` 键——P2-15 ① 语义（「下一次绑定
/// 构造时可见」）要求 bookVar 跨流程/跨书在进程内存活；type/reverseToc
/// 是**会话级覆盖**（对齐上游每阶段 `removeAllBookType` 重置语义），
/// 进程级黏性会让旧书 type 覆盖跨书残留到进程重启。
fn clear_book_type_overlays(book_url: &str) -> Result<(), String> {
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    store.remove(&book_type_key(book_url));
    store.remove(&book_reverse_toc_key(book_url));
    Ok(())
}

/// 设置当前流程作用域（`begin_book_flow` 的底层实现）
///
/// - scope 与当前相同 → 无操作（同一本书 info → toc → content 链不清空，
///   保住同书会话变量快路径）；
/// - scope 变化 → 只清**旧** scope 前缀（上一本书的会话键），再写入新
///   scope。裸键持久数据（`v_*`/`sourceVariable_*`/`loginHeader_*`/
///   `userInfo_*`/`cache.*`）不受影响（P1-1）。
///
/// [P2-15 剩项①] scope 变化/流程结束（[`clear_flow_scope`]）时另清旧
/// scope 的 `bookType::`/`bookReverseToc::` 会话级 overlay（保留
/// `bookVar::`，见 [`clear_book_type_overlays`]）。
pub fn set_flow_scope(scope: &str) -> Result<(), String> {
    let mut cur = FLOW_SCOPE
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    if cur.as_deref() != Some(scope) {
        if let Some(old) = cur.take() {
            clear_flow_prefix(&old)?;
            clear_book_type_overlays(&old)?;
        }
        *cur = Some(scope.to_string());
    }
    Ok(())
}

/// 清除当前 scope 前缀并把 scope 复位为 None（测试收尾/流程生命周期结束）
///
/// [P2-15 剩项①] 同时清当前 scope 的 `bookType::`/`bookReverseToc::`
/// 会话级 overlay（流程结束 = 会话级 type/reverseToc 覆盖失效）。
pub fn clear_flow_scope() -> Result<(), String> {
    let old = FLOW_SCOPE
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?
        .take();
    if let Some(old) = old {
        clear_flow_prefix(&old)?;
        clear_book_type_overlays(&old)?;
    }
    Ok(())
}

/// 读取当前流程作用域（None = 未进入书籍流程）
pub fn current_flow_scope() -> Option<String> {
    FLOW_SCOPE.lock().ok().and_then(|g| g.clone())
}

/// 写会话变量（`java.put` / `java.__lgStorePut` 桥 / `source.put` 等共用入口）
///
/// 分派规则（B6/A4）：
/// - **持久前缀键**（五族：`v_` / `userInfo_` / `loginHeader_` /
///   `sourceVariable_` / `infoMap_`）→ 写**裸键持久层**（并经
///   [`VariableSink`] 落 `caches` 表，重启不丢）。书源 setup 脚本的
///   `source.put` / `source.setVariable` / `putLoginHeader` 等都走这条。
/// - 其他键 + scope 已设置 → 写 `lgflow::{scope}{key}`（按流程隔离）；
/// - 其他键 + 无 scope（未走书籍流程入口的直用引擎/残留入口）→ 写裸键，
///   行为与 P2-9 ③ 引入前一致。
pub fn put_flow_variable(key: &str, value: &str) -> Result<(), String> {
    if is_persisted_key(key) {
        return set_variable(key, value);
    }
    let k = match current_flow_scope() {
        Some(scope) => flow_key(&scope, key),
        None => key.to_string(),
    };
    set_variable(&k, value)
}

/// 读会话变量（`java.get` / `__lgStoreGet` 桥 / `source.get` / 解析器 `@get` 兜底读者）
///
/// 读取优先级：
/// 0. **持久前缀键**（五族）→ 读裸键持久层（唯一权威来源，不查流程层；
///    跨书/跨源按 `v_{sourceUrl}_` 等前缀天然隔离）。**内存 miss 时回查
///    持久层并回填内存**（P1-3 方案 2：清内存 = 下次读重载）。
/// 1. scope 已设置 → `lgflow::{scope}{key}`（本流程会话层）；
/// 2. 未命中 → 裸键 `{key}`（历史裸键：`cache.*` 等，上游 CacheManager
///    语义，跨书存活——P1-1 的持久键修复同一机制）；
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
    if is_persisted_key(key) {
        // P1-3 方案 2：内存 miss 时回查持久层并回填内存（「清内存」=
        // 「下次读重载」）。未注册下沉时 `get_persisted_variable` 等价纯内存读。
        return get_persisted_variable(key);
    }
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

    /// P1-2：`clear_source_variables` 只清 5 族源运行时键，其他键（含本轨
    /// flow/bookVar 前缀与无关裸键）保留。
    #[test]
    fn test_clear_source_variables_clears_five_families_only() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let url = "https://mem.family.example.com/source";
        for key in [
            format!("v_{url}_token"),
            format!("userInfo_{url}"),
            format!("loginHeader_{url}"),
            format!("sourceVariable_{url}"),
            format!("infoMap_{url}"),
        ] {
            set_variable(&key, "v").unwrap();
        }
        for key in [
            "unrelated_bare_key",
            "bookVar::https://mem.example.com/b/1::k",
            "bookType::https://mem.example.com/b/1",
        ] {
            set_variable(key, "keep").unwrap();
        }
        set_flow_scope("mem-clear-scope").unwrap();
        put_flow_variable("sess", "keep").unwrap();

        clear_source_variables().unwrap();

        for key in [
            format!("v_{url}_token"),
            format!("userInfo_{url}"),
            format!("loginHeader_{url}"),
            format!("sourceVariable_{url}"),
            format!("infoMap_{url}"),
        ] {
            assert_eq!(get_variable(&key).unwrap(), None, "{key} 应被清除");
        }
        assert_eq!(
            get_variable("unrelated_bare_key").unwrap(),
            Some("keep".into())
        );
        assert_eq!(
            get_variable("bookVar::https://mem.example.com/b/1::k").unwrap(),
            Some("keep".into()),
            "bookVar 前缀不在 5 族内"
        );
        assert_eq!(
            get_variable("bookType::https://mem.example.com/b/1").unwrap(),
            Some("keep".into())
        );
        assert_eq!(get_flow_variable("sess"), Some("keep".into()));
        clear_flow_scope().unwrap();
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

    // ── P2-15 剩项①：overlay 生命周期收窄（type/reverseToc 会话级） ─────

    /// [P2-15 剩项①] 换书（scope 切换）清旧书 `bookType::`/`bookReverseToc::`
    /// 会话级 overlay，`bookVar::` 保留（P2-15 ①「下一次绑定构造时可见」
    /// 的跨书/跨流程存活语义不回归）。
    #[test]
    fn test_p215_scope_switch_clears_type_overlays_keeps_bookvar() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let book_a = "https://p215-overlay.example.com/b/a";
        let book_b = "https://p215-overlay.example.com/b/b";
        set_flow_scope(book_a).unwrap();
        // A 的会话级 overlay + bookVar（宿主桥同形写入）
        set_variable(&book_type_key(book_a), "64").unwrap();
        set_variable(&book_reverse_toc_key(book_a), "true").unwrap();
        set_variable(&book_var_key(book_a, "seq"), "a-seq").unwrap();
        // 换书 A → B：A 的 type/reverseToc overlay 被清，bookVar 保留
        set_flow_scope(book_b).unwrap();
        assert_eq!(
            get_variable(&book_type_key(book_a)).unwrap(),
            None,
            "换书后旧书 type overlay 应失效"
        );
        assert_eq!(
            get_variable(&book_reverse_toc_key(book_a)).unwrap(),
            None,
            "换书后旧书 reverseToc overlay 应失效"
        );
        assert_eq!(
            get_variable(&book_var_key(book_a, "seq")).unwrap(),
            Some("a-seq".into()),
            "bookVar 跨书存活（P2-15 ① 不回归）"
        );
        clear_flow_scope().unwrap();
    }

    /// [P2-15 剩项①] 同 scope 重复 set = 无操作：同书 info → toc →
    /// content 链的 type overlay 不清（快路径不回归）。
    #[test]
    fn test_p215_same_scope_keeps_type_overlay() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let book_url = "https://p215-overlay.example.com/b/same";
        set_flow_scope(book_url).unwrap();
        set_variable(&book_type_key(book_url), "32").unwrap();
        set_flow_scope(book_url).unwrap();
        assert_eq!(
            get_variable(&book_type_key(book_url)).unwrap(),
            Some("32".into()),
            "同书同 scope 重设不清 type overlay"
        );
        clear_flow_scope().unwrap();
    }

    /// [P2-15 剩项①] `clear_flow_scope`（流程结束）同样清当前书的
    /// type/reverseToc overlay（会话级覆盖随会话失效）；bookVar 属
    /// 进程级持久层，不受流程结束影响。
    #[test]
    fn test_p215_clear_flow_scope_clears_type_overlays() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let book_url = "https://p215-overlay.example.com/b/end";
        set_flow_scope(book_url).unwrap();
        set_variable(&book_type_key(book_url), "8").unwrap();
        set_variable(&book_reverse_toc_key(book_url), "true").unwrap();
        set_variable(&book_var_key(book_url, "v"), "bv").unwrap();
        clear_flow_scope().unwrap();
        assert_eq!(get_variable(&book_type_key(book_url)).unwrap(), None);
        assert_eq!(get_variable(&book_reverse_toc_key(book_url)).unwrap(), None);
        assert_eq!(
            get_variable(&book_var_key(book_url, "v")).unwrap(),
            Some("bv".into()),
            "流程结束不清 bookVar 持久层"
        );
    }

    // ── B6/A4：持久化下沉 + 裸 put/get 作用域 ─────────────────────────

    /// 五族键判定（前缀 + 非空后缀）
    #[test]
    fn test_is_persisted_key_families() {
        for key in [
            "v_https://x.com_k",
            "userInfo_https://x.com",
            "loginHeader_https://x.com",
            "sourceVariable_https://x.com",
            "infoMap_https://x.com",
        ] {
            assert!(is_persisted_key(key), "{key} 应属持久五族");
        }
        for key in [
            "v_",
            "userInfo_",
            "lgflow:scope\u{1}k",
            "bookVar::https://x.com/b::k",
            "bookType::https://x.com/b",
            "bare_key",
        ] {
            assert!(!is_persisted_key(key), "{key} 不应属持久五族");
        }
    }

    /// B6：`source.put` 类持久键写穿下沉；清内存后回填仍可读（模拟重启）
    #[test]
    fn test_variable_sink_roundtrip_survives_memory_clear() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let sink = shared_sink();

        let key = "v_https://sink.example.com/source_token";
        put_flow_variable(key, "tok").expect("写持久键");
        assert_eq!(sink.get(key).as_deref(), Some("tok"), "应写穿持久层");

        // 模拟重启：只清内存，持久行仍在
        clear_variables().expect("清内存");
        assert_eq!(get_variable(key).unwrap(), None, "内存已清");
        backfill_from_sink();
        assert_eq!(
            get_flow_variable(key),
            Some("tok".into()),
            "重启回填后持久键应可读"
        );

        remove_variable(key).expect("删持久键");
        assert_eq!(sink.get(key), None, "删键应同步删持久行");
        sink.clear();
    }

    /// B6：跨源同名键不串（`v_源A_k` 与 `v_源B_k` 各自独立落库）
    #[test]
    fn test_variable_sink_cross_source_isolation() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let sink = shared_sink();
        let a = "v_https://a.example.com_src_k";
        let b = "v_https://b.example.com_src_k";
        put_flow_variable(a, "from-a").expect("写源 A");
        put_flow_variable(b, "from-b").expect("写源 B");
        assert_eq!(sink.get(a).as_deref(), Some("from-a"));
        assert_eq!(sink.get(b).as_deref(), Some("from-b"));

        clear_variables().expect("清内存");
        backfill_from_sink();
        assert_eq!(get_flow_variable(a), Some("from-a".into()));
        assert_eq!(get_flow_variable(b), Some("from-b".into()));
        sink.clear();
    }

    /// A4：裸 `java.put`（无持久前缀）走 flow scope，不写持久层
    #[test]
    fn test_bare_put_uses_flow_scope_and_skips_sink() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let sink = shared_sink();
        set_flow_scope("book-a").expect("设 scope");
        put_flow_variable("mode", "audio").expect("写会话变量");
        // 会话层可见
        assert_eq!(get_flow_variable("mode"), Some("audio".into()));
        // 裸键未被写入（不污染 @get 持久兜底层）
        assert_eq!(get_variable("mode").unwrap(), None);
        // 未落库（非五族）
        assert!(sink.rows.lock().unwrap().is_empty(), "裸会话键不应落库");

        // 换 scope：会话键不可见（跨书不串）
        set_flow_scope("book-b").expect("换 scope");
        assert_eq!(get_flow_variable("mode"), None);
        clear_flow_scope().expect("清 scope");
        sink.clear();
    }

    /// A4：持久前缀键在 scope 内也直读持久层（不被流程层遮蔽）
    #[test]
    fn test_persisted_key_reads_persistent_layer_even_in_scope() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        set_flow_scope("book-scope").expect("设 scope");
        set_variable("sourceVariable_https://x.com", "sv").expect("写持久键");
        // 流程层同名键不应遮蔽持久层（持久键写路径也落裸键）
        assert_eq!(
            get_flow_variable("sourceVariable_https://x.com"),
            Some("sv".into())
        );
        clear_flow_scope().expect("清 scope");
    }

    /// P1-3 方案 2：持久键内存 miss 时**懒加载**回查下沉并回填内存
    ///
    /// 场景等价于备份恢复：DB 行已改成新值 → `clear_source_variables()` 清内存
    /// → 不调用 `backfill_from_sink()`，下一次读也必须拿到 DB 新值（不重启）。
    #[test]
    fn test_persisted_key_lazy_reloads_from_sink_after_memory_clear() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let sink = shared_sink();
        let key = "loginHeader_https://lazy-reload.example.com";
        put_flow_variable(key, "old-header").expect("写旧值");
        assert_eq!(sink.get(key).as_deref(), Some("old-header"));

        // 恢复：DB 行换新值，内存被清（不跑 backfill）
        sink.upsert(key, "new-header");
        clear_source_variables().expect("清内存五族");
        assert_eq!(get_variable(key).unwrap(), None, "内存应已清空");

        // 懒加载：读路径回查下沉
        assert_eq!(
            get_flow_variable(key),
            Some("new-header".into()),
            "内存 miss 时应回查持久层（恢复后免重启生效）"
        );
        // 回查后已回填内存（下一次读不再打 DB）
        assert_eq!(
            get_variable(key).unwrap(),
            Some("new-header".into()),
            "懒加载命中后应回填内存"
        );

        remove_variable(key).expect("清理");
        assert_eq!(sink.get(key), None);
        sink.clear();
    }

    /// P2-2：内存无该键时 `remove_variable` 仍必须删下沉行（否则重启复活）
    #[test]
    fn test_remove_variable_deletes_sink_row_when_memory_miss() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let sink = shared_sink();
        let key = "loginHeader_https://p22-remove.example.com";
        // 只有持久行（内存已被 clear_variables 清掉）
        sink.upsert(key, "stale");
        clear_variables().expect("清内存");
        assert_eq!(get_variable(key).unwrap(), None);

        remove_variable(key).expect("删键");
        assert_eq!(sink.get(key), None, "内存 miss 时也必须删持久行");

        // 重启回填不得复活
        backfill_from_sink();
        assert_eq!(get_flow_variable(key), None, "已删键不得被回填复活");
        sink.clear();
    }

    /// 测试用内存型下沉（模拟 `caches` 表五族行）
    #[derive(Default)]
    struct MemorySink {
        rows: Mutex<HashMap<String, String>>,
    }

    /// 进程内共享下沉（first-wins 注册一次，全部 sink 类测试共用同一实例）
    ///
    /// 直接 `set_variable_sink(Arc::new(...))` 时若本二进制已有他测试先注册，
    /// 后续注册被忽略 → 测试若「未注册就 return」会**假绿**（断言根本没跑）。
    /// 统一取共享实例可保证断言始终生效；各测试在末尾 `clear()` 清理，
    /// 且全部经 [`lock_variables`] 串行。
    fn shared_sink() -> Arc<MemorySink> {
        static SINK: OnceLock<Arc<MemorySink>> = OnceLock::new();
        SINK.get_or_init(|| {
            let sink = Arc::new(MemorySink::default());
            let _ = set_variable_sink(sink.clone());
            sink
        })
        .clone()
    }

    impl MemorySink {
        fn get(&self, key: &str) -> Option<String> {
            self.rows.lock().unwrap().get(key).cloned()
        }
        fn clear(&self) {
            self.rows.lock().unwrap().clear();
        }
    }

    impl VariableSink for MemorySink {
        fn upsert(&self, key: &str, value: &str) {
            self.rows
                .lock()
                .unwrap()
                .insert(key.to_string(), value.to_string());
        }
        fn remove(&self, key: &str) {
            self.rows.lock().unwrap().remove(key);
        }
        fn load_all(&self) -> Vec<(String, String)> {
            self.rows
                .lock()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect()
        }
        fn get(&self, key: &str) -> Option<String> {
            // 显式走固有方法（同名 trait 方法在作用域内，避免解析歧义）
            MemorySink::get(self, key)
        }
    }
}
