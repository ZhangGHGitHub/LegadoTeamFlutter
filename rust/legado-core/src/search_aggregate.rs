//! 跨源聚合单一真源（队列⑩a P1-1 项2，2026-09-22）
//!
//! 把搜索两层去重中的**跨源聚合**（同名同作者跨源合并 + origins 累加）从
//! Dart 侧下沉到 Rust，作为跨端夹具校验的基准实现。
//!
//! **对齐范围（严格限定）**：与 Dart 现行**纯函数** `applyPrecisionSearch`
//! （`flutter_legado/lib/src/providers/search/search_state.dart` L144-207）
//! 逐条对齐（不得自作主张改语义）。**不覆盖** `SearchNotifier` 增量桶路径
//! （`search_notifier.dart` L307-310）：该路径入桶前多一层
//! `_seenKeys.add('${name}|${author}|${origin}')` 预去重（`_seenKeys` 声明于
//! L64），本模块与纯函数均无此步——具体表现：同名同作者同 origin、kind
//! 分别落不同桶的输入（如「都市情缘+乙」带 kind 与不带 kind 两条），
//! 纯函数/本模块产出 2 条，增量路径仅 1 条；差异登记与待裁决见
//! `docs/REFACTORING_ACTIVE_PLAN.md` P2-20，故本模块不得与增量路径称
//! 「完全一致」：
//!
//! 1. **归一化**：name/author 经本地 `normalize_book_name` /
//!    `normalize_book_author` 清洗——**正则文本**与 Dart
//!    `AppPattern.nameRegex` / `authorRegex` 对齐，但正则引擎不同（Dart
//!    侧为 ECMAScript 语义；`regex` crate 为 Unicode 语义：`\s` 含
//!    U+0085 不含 U+FEFF、`.` 仅排除 LF、`trim` 按 Unicode White_Space，
//!    三者与 Dart 实测字符集均不等价），故聚合路径不复用 `book_help.rs`
//!    （其服务 Rust 解析路径），改为本地 **ECMAScript 等价实现**：探针
//!    实测显式字符类（`JS_WS_CLASS` 等，实测输出
//!    `rust/_p03_norm_probe/probe_output.txt`）+ `js_trim`（Dart
//!    `String.trim()` 实测字符集 B）。**仅当输入来自 Rust 解析路径**时
//!    「解析期已清洗，聚合再清洗幂等 no-op」成立；对**外部/夹具 JSON
//!    输入，以本模块 ECMAScript 等价实现为准**（两套实现结果可能不同）。
//! 2. **聚合键**：`"{name}\u{0}{author}"`（清洗后值，Dart mapKey 同规则；
//!    键不含 bookUrl/origin——同名同作者即同书，单源内不同 bookUrl 亦合并，
//!    origins 集合按 origin 去重不重复计数）。
//! 3. **分桶**（按清洗后 name/author/kind 判定，四桶各自独立 map——同一键
//!    可因 kind 差异落在不同桶；桶序）：
//!    `equal`（name==key | author==key）→ `tags`（kind contains key）→
//!    `contains`（name|author contains key）→ `other`（仅 `keep_other` 时保留）。
//! 4. **归并**（Dart `withAddedOrigin`，`Set<String>` 保序去重语义，探针
//!    实测 `rust/_p03_norm_probe/probe_output.txt`「Set 语义」节）：
//!    - 入桶首条：条目 origins = 该条 `effectiveOrigins` 的**保序去重**
//!      副本（字段重复收敛，`{"o","o"}` 计 1；**不滤空串**——`[""]` →
//!      `[""]` 计数 1，空串是合法集合成员）；
//!    - 后续归并：并集追加（已有项在前、新成员按该条 `effectiveOrigins`
//!      序、**不滤空串**），仅 `other.origin` 非空且未出现时追加；
//!      `hasReadRecord` OR；其余元数据（bookUrl/origin/originName/
//!      coverUrl/…）保留**首条到达**项。
//! 5. **排序**：桶内 originsCount 降序（effectiveOrigins 空按 1 计），
//!    平局按**首次到达索引**升序（对齐 Dart `sortedBucket` 的索引平局裁决，
//!    不依赖 sort 稳定性）。
//! 6. **输出**：equal → tags → contains → (keep_other) other 桶序拼接；
//!    空关键词直接原样返回（Dart `if (key.isEmpty) return results;`）。
//!
//! **effectiveOrigins 规则**（Dart `SearchResult.effectiveOrigins` 对齐）：
//! 书自带 `origins` 字段非空 → 用它；否则 `origin` 非空 → 单元素 `{origin}`；
//! 全空 → 空集合（originsCount 下限 1）。
//!
//! 单源按 bookUrl 去重**不在本模块**——解析期 `dedup_search_results_keep_first`
//! 已完成（S0-E 对齐 BookList.kt:142-144，bookUrl 单键 keep-first）；本模块
//! 只处理跨源（name+author）合并。

use crate::models::misc::SearchBook;
use regex::Regex;
use std::collections::HashMap;
use std::sync::OnceLock;

// ─── ECMAScript 等价归一化（缺陷 1：探针实测显式字符类，禁止凭记忆猜）───
//
// Dart（ECMAScript）语义与 `regex` crate（Unicode 语义）在三个字符集上
// 不等价，全部经 Dart 探针逐码点实测（0x00-0x10FFFF 全范围扫描，输出
// `rust/_p03_norm_probe/probe_output.txt`；探针脚本 `probe_norm.dart` 同目录）：
// - 集合 A = `RegExp(r'\s')` 命中码点（25 个：含 **U+FEFF**，不含
//   U+0085/U+180E/U+200B；`regex` crate 的 `\s`（Unicode White_Space）含
//   U+0085 而**不含** U+FEFF → 不等价，不得复用）；
// - 集合 B = `String.trim()` 两端剥除码点（26 个 = A ∪ {U+0085}；U+0085
//   NEL 被 Dart trim 剥除却不被 `\s` 命中——A/B 差集实测为 {0x0085}，
//   两组分别建模，不做近似）；
// - 集合 C = `.` **不**匹配码点（4 个：U+000A/U+000D/U+2028/U+2029；
//   `regex` crate 的 `.` 仅排除 LF → 不等价，须显式负类替换）。

/// 集合 A：ECMAScript `\s` 的显式字符类（Dart 探针实测 25 成员，
/// `probe_output.txt`「setA_full」；U+FEFF 在 ECMAScript WhiteSpace 内，
/// 实测 0xFEFF A 列 = Y）。
const JS_WS_CLASS: &str =
    "[\u{9}\u{A}\u{B}\u{C}\u{D} \u{A0}\u{1680}\u{2000}-\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}]";

/// `\S` 等价：集合 A 的补（Rust 负类 `[^…]` 匹配任何不在集合内的码点，
/// 与 ECMAScript `\S` 逐码点等价）。
const JS_NON_WS_CLASS: &str =
    "[^\u{9}\u{A}\u{B}\u{C}\u{D} \u{A0}\u{1680}\u{2000}-\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}]";

/// `.` 等价：实测排除集 C 的负类（U+000A/U+000D/U+2028/U+2029，
/// `probe_output.txt`「setC_full」；Rust `.` 仅排除 LF，须显式负类）。
const JS_ANY_CLASS: &str = "[^\u{A}\u{D}\u{2028}\u{2029}]";

/// 集合 B：Dart `String.trim()` 两端剥除的 26 个码点（实测「setB_full」
/// = 集合 A ∪ {U+0085}；Rust `str::trim()` 按 Unicode White_Space 剥除
/// ——含 U+0085 但**不含** U+FEFF，与实测集 B 不等价，不得复用）。
const JS_TRIM_CODEPOINTS: &[u32] = &[
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004,
    0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
];

/// Dart `String.trim()` 等价：仅两端剥实测集合 B 码点（Rust `str::trim()`
/// 语义不等价，见 `JS_TRIM_CODEPOINTS` 注释）。
fn js_trim(s: &str) -> &str {
    s.trim_matches(|c: char| JS_TRIM_CODEPOINTS.contains(&(c as u32)))
}

/// 书名清洗（聚合路径专用）：**正则文本**对齐 Dart `AppPattern.nameRegex`
/// （`\s+作\s*者.*|\s+\S+\s+著`），`\s`/`\S`/`.` 全部替换为上方实测
/// 显式字符类（ECMAScript 等价）；`book_help.rs` 的 `regex` 引擎版本
/// 仅服务 Rust 解析路径，聚合路径不使用。
fn normalize_book_name(name: &str) -> String {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(&format!(
            "{ws}+作{ws}*者{any}*|{ws}+{non}+{ws}+著",
            ws = JS_WS_CLASS,
            any = JS_ANY_CLASS,
            non = JS_NON_WS_CLASS,
        ))
        .expect("ECMAScript 等价 nameRegex 编译失败")
    });
    js_trim(&re.replace_all(name, "")).to_string()
}

/// 作者清洗（聚合路径专用）：**正则文本**对齐 Dart `AppPattern.authorRegex`
/// （`^\s*作\s*者[:：\s]+|\s+著`），字符类替换规则同 `normalize_book_name`。
fn normalize_book_author(author: &str) -> String {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(&format!(
            "^{ws}*作{ws}*者[:：{ws}]+|{ws}+著",
            ws = JS_WS_CLASS,
        ))
        .expect("ECMAScript 等价 authorRegex 编译失败")
    });
    js_trim(&re.replace_all(author, "")).to_string()
}

/// 书的有效 origins（Dart `SearchResult.effectiveOrigins` 对齐）：
/// `origins` 字段非空 → 用它（保留首次出现序）；否则 `origin` 非空 → 单元素；
/// 全空 → 空。
pub fn effective_origins(book: &SearchBook) -> Vec<String> {
    if !book.origins.is_empty() {
        return book.origins.clone();
    }
    if book.origin.is_empty() {
        Vec::new()
    } else {
        vec![book.origin.clone()]
    }
}

/// origins 计数（Dart `originsCount` 对齐）：空集合按 1 计（对齐原版
/// `bv_originCount` 下限），否则取长度。
pub fn origins_count(origins: &[String]) -> i32 {
    if origins.is_empty() {
        1
    } else {
        origins.len() as i32
    }
}

/// 聚合条目：首条到达元数据 + 累加 origins（首次出现序）+ 阅读记录 OR
#[derive(Debug, Clone)]
struct Entry {
    /// 首条到达书籍（name/author 已替换为清洗值；origins 输出时覆写为累加值）
    book: SearchBook,
    /// 累加 origins 集合（首次出现序）
    origins: Vec<String>,
    /// 各到达项 `has_read_record` OR
    has_read_record: bool,
}

/// 单一桶：键 → 条目索引 + 条目插入序（= 该键首次到达序）
#[derive(Debug, Default)]
struct Bucket {
    slots: HashMap<String, usize>,
    entries: Vec<Entry>,
}

impl Bucket {
    /// 归并一条书（Dart `mergeInto` 对齐，`Set<String>` 保序去重语义按
    /// 探针实测实现，`rust/_p03_norm_probe/probe_output.txt`「Set 语义」节）：
    /// - 首条到达：条目 origins 初始化为该条 `effectiveOrigins` 的
    ///   **保序去重**副本（Dart `{...effectiveOrigins}` Set 副本：重复收敛
    ///   如 `["o","o"]` → `["o"]` 计 1；**不滤空串**——`[""]` → `[""]`
    ///   计数 1，空串是合法集合成员），`has_read_record` 取该条；
    /// - 已有条目：`withAddedOrigin`——先并集追加该条 `effectiveOrigins`
    ///   各成员（已有在前、新成员按该条序、**不滤空串**），再仅在
    ///   `other.origin` **非空**且未出现时追加 origin（Dart L59 判空）；
    ///   `has_read_record` OR，元数据保持首条。
    fn merge(&mut self, key: String, item: &SearchBook, norm_name: &str, norm_author: &str) {
        let eff = effective_origins(item);
        if let Some(&idx) = self.slots.get(&key) {
            let e = &mut self.entries[idx];
            // `{...selfOrigins, ...other.effectiveOrigins}`：并集保序，
            // 空串成员照常保留（探针实测 `{'""'}.length == 1`）。
            for o in &eff {
                if !e.origins.contains(o) {
                    e.origins.push(o.clone());
                }
            }
            // `if (other.book.origin.isNotEmpty) next.add(other.book.origin)`
            if !item.origin.is_empty() && !e.origins.contains(&item.origin) {
                e.origins.push(item.origin.clone());
            }
            e.has_read_record |= item.has_read_record;
        } else {
            let idx = self.entries.len();
            let mut book = item.clone();
            book.name = norm_name.to_string();
            book.author = norm_author.to_string();
            // Dart：入桶首条 copyWith(origins: {...effectiveOrigins})——
            // Set 副本保序去重（探针实测 `['o','o'].toSet().length == 1`），
            // 不滤空串（`[""]` → 条目 origins `[""]`，origins_count 计 1）。
            let mut deduped: Vec<String> = Vec::with_capacity(eff.len());
            for o in &eff {
                if !deduped.contains(o) {
                    deduped.push(o.clone());
                }
            }
            self.entries.push(Entry {
                book,
                origins: deduped,
                has_read_record: item.has_read_record,
            });
            self.slots.insert(key, idx);
        }
    }

    /// 物化（Dart `sortedBucket` 对齐）：originsCount 降序 + 首次到达索引升序平局
    fn render(&self) -> Vec<SearchBook> {
        let mut order: Vec<usize> = (0..self.entries.len()).collect();
        order.sort_by(|&a, &b| {
            let ca = origins_count(&self.entries[a].origins);
            let cb = origins_count(&self.entries[b].origins);
            // b - a 降序；平局按首次到达索引升序（显式裁决，不依赖稳定性）
            cb.cmp(&ca).then_with(|| a.cmp(&b))
        });
        order
            .into_iter()
            .map(|i| {
                let e = &self.entries[i];
                let mut book = e.book.clone();
                book.origins = e.origins.clone();
                book.has_read_record = e.has_read_record;
                book
            })
            .collect()
    }
}

/// 跨源聚合（单一真源入口，Dart `applyPrecisionSearch(results, key,
/// {keepOther})` 逐条对齐的纯函数）：
///
/// - `key` 空 → 原样返回（不聚合、不分桶，Dart 同规则）；
/// - 归一化 → 分桶 → 归并 → 桶内排序 → 桶序拼接输出；
/// - 输出项 `name`/`author` 为清洗值，`origins` 为跨源累加集合（首次出现序），
///   `hasReadRecord` 为各到达项 OR，其余字段保留首条到达元数据。
pub fn aggregate_search_books(
    books: &[SearchBook],
    key: &str,
    keep_other: bool,
) -> Vec<SearchBook> {
    if key.is_empty() {
        return books.to_vec();
    }

    let mut equal = Bucket::default();
    let mut tags = Bucket::default();
    let mut contains = Bucket::default();
    let mut other = Bucket::default();

    for item in books {
        let name = normalize_book_name(&item.name);
        let author = normalize_book_author(&item.author);
        // 聚合键（Dart `'$name\u0000$author'`，清洗后值）
        let map_key = format!("{name}\u{0}{author}");
        let kind = item.kind.as_deref().unwrap_or("");
        // 桶判定用清洗后 name/author（Dart L172-183 同规则）；
        // keep_other=false 时 other 项直接丢弃（Dart L181 else-if 落空）
        if name == key || author == key {
            equal.merge(map_key, item, &name, &author);
        } else if kind.contains(key) {
            tags.merge(map_key, item, &name, &author);
        } else if name.contains(key) || author.contains(key) {
            contains.merge(map_key, item, &name, &author);
        } else if keep_other {
            other.merge(map_key, item, &name, &author);
        }
    }

    let mut out: Vec<SearchBook> = Vec::new();
    // 桶序：equal → tags → contains → (keep_other) other
    out.extend(equal.render());
    out.extend(tags.render());
    out.extend(contains.render());
    if keep_other {
        out.extend(other.render());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::misc::SearchBook;

    /// 构造测试书（字段缺省零值，仅填必要项）
    fn mk(name: &str, author: &str, origin: &str) -> SearchBook {
        SearchBook {
            book_url: format!("{origin}/book/{name}"),
            origin: origin.to_string(),
            origin_name: format!("源{origin}"),
            name: name.to_string(),
            author: author.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn cross_source_same_book_merges_with_origins_accumulated() {
        // 三源同名同作者 → 一条，origins 累加（首次出现序 a→b→c）
        let books = [
            mk("一人之下", "米二", "https://a.com"),
            mk("一人之下", "米二", "https://b.com"),
            mk("一人之下", "米二", "https://c.com"),
            mk("一人之下番外", "米二", "https://d.com"),
        ];
        let out = aggregate_search_books(&books, "一人之下", true);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].name, "一人之下");
        assert_eq!(
            out[0].origins,
            vec![
                "https://a.com".to_string(),
                "https://b.com".to_string(),
                "https://c.com".to_string()
            ]
        );
        assert_eq!(origins_count(&out[0].origins), 3);
        // 多源条（count=3）排在单源 contains 条（count=1）之前（桶内降序）
        assert_eq!(out[1].name, "一人之下番外");
        assert_eq!(origins_count(&out[1].origins), 1);
        // 首条元数据保留
        assert_eq!(out[0].book_url, "https://a.com/book/一人之下");
    }

    #[test]
    fn same_source_same_book_no_double_count() {
        // 同源（origin 相同）同名同作者、不同 bookUrl → 合并一条，
        // origins 集合按 origin 去重（不重复计数，count 下限 1）
        let books = [
            mk("斗破苍穹", "天蚕土豆", "https://a.com"),
            SearchBook {
                book_url: "https://a.com/book/other-id".to_string(),
                ..mk("斗破苍穹", "天蚕土豆", "https://a.com")
            },
        ];
        let out = aggregate_search_books(&books, "斗破苍穹", true);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].origins, vec!["https://a.com".to_string()]);
        assert_eq!(origins_count(&out[0].origins), 1);
    }

    #[test]
    fn normalization_regex_text_aligned_ecmascript_equivalent() {
        // 正则文本与 Dart formatBookName/formatBookAuthor 对齐，引擎语义
        // 为 ECMAScript 等价（显式字符类 + js_trim，非 `regex` crate 的
        // Unicode 默认语义）。作者「作者：」前缀 / 书名「 作者xxx」后缀
        // 归一化后跨源合并
        let books = [
            mk("斗破苍穹", "天蚕土豆", "https://a.com"),
            mk("斗破苍穹", "作者：天蚕土豆", "https://b.com"),
            mk("斗破苍穹", "作者: 天蚕土豆", "https://c.com"),
            mk("斗破苍穹 作者天蚕土豆", "天蚕土豆", "https://d.com"),
        ];
        let out = aggregate_search_books(&books, "斗破苍穹", true);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].name, "斗破苍穹", "书名清洗后展示值");
        assert_eq!(out[0].author, "天蚕土豆", "作者清洗后展示值");
        assert_eq!(origins_count(&out[0].origins), 4);
        // 「忘语 著」书名后缀清洗（nameRegex `\s+\S+\s+著`）
        let books2 = [
            mk("凡人修仙传 忘语 著", "忘语", "https://a.com"),
            mk("凡人修仙传", "忘语 著", "https://b.com"),
        ];
        let out2 = aggregate_search_books(&books2, "凡人修仙传", true);
        assert_eq!(out2.len(), 1);
        assert_eq!(out2[0].name, "凡人修仙传");
        assert_eq!(out2[0].author, "忘语");
    }

    #[test]
    fn unicode_boundaries_match_dart_probe() {
        // 与夹具 case `unicode_boundaries` 同输入/同期望（expected 由 Dart
        // 现行 `applyPrecisionSearch` 实测产出，`rust/_p03_norm_probe/
        // probe_output.txt`「case unicode_boundaries」节）：
        // - U+FEFF：`\s` 命中（A 实测含 FEFF）且 trim 剥除（B 含 FEFF）
        //   → 尾随/「作」前均被清洗，并入「斗破苍穹」桶；
        // - U+0085：`\s` 不命中（A 不含 0x85）但 trim 剥除（B = A ∪ {0x85}）
        //   → 前导剥除并入；「作」前 0x85 不触发 `\s+`，整段保留为独立条；
        // - \r / U+2029：`.` 排除集 C = {0A,0D,2028,2029} → `.*` 在此截断，
        //   残留尾段保留为独立条。
        let books: Vec<SearchBook> = [
            (
                "https://s1.example/book/u1",
                "https://s1.example",
                "斗破苍穹",
            ),
            (
                "https://s2.example/book/u2",
                "https://s2.example",
                "斗破苍穹\u{FEFF}",
            ),
            (
                "https://s3.example/book/u3",
                "https://s3.example",
                "斗破苍穹\u{85}作者天蚕土豆",
            ),
            (
                "https://s4.example/book/u4",
                "https://s4.example",
                "\u{85}斗破苍穹",
            ),
            (
                "https://s5.example/book/u5",
                "https://s5.example",
                "斗破苍穹 作者\r天蚕土豆",
            ),
            (
                "https://s6.example/book/u6",
                "https://s6.example",
                "斗破苍穹\u{FEFF}作者天蚕土豆",
            ),
            (
                "https://s7.example/book/u7",
                "https://s7.example",
                "斗破苍穹\u{2028}",
            ),
            (
                "https://s8.example/book/u8",
                "https://s8.example",
                "斗破苍穹 作者\u{2029}天蚕土豆",
            ),
        ]
        .into_iter()
        .map(|(url, origin, name)| {
            let mut b = SearchBook::default();
            b.book_url = url.to_string();
            b.origin = origin.to_string();
            b.name = name.to_string();
            b.author = "甲".to_string();
            b
        })
        .collect();
        let out = aggregate_search_books(&books, "斗破苍穹", true);
        assert_eq!(
            out.iter().map(|b| b.name.clone()).collect::<Vec<_>>(),
            vec![
                "斗破苍穹".to_string(),
                "斗破苍穹\u{85}作者天蚕土豆".to_string(),
                "斗破苍穹\r天蚕土豆".to_string(),
                "斗破苍穹\u{2029}天蚕土豆".to_string(),
            ],
            "合并条（u1/u2/u4/u6/u7 并入）+ 三条独立 contains 条（探针实测期望）"
        );
        assert_eq!(
            out[0].origins,
            vec![
                "https://s1.example".to_string(),
                "https://s2.example".to_string(),
                "https://s4.example".to_string(),
                "https://s6.example".to_string(),
                "https://s7.example".to_string(),
            ],
            "origins 首次出现序（探针实测期望）"
        );
        assert_eq!(out[1].origins, vec!["https://s3.example".to_string()]);
        assert_eq!(out[2].origins, vec!["https://s5.example".to_string()]);
        assert_eq!(out[3].origins, vec!["https://s8.example".to_string()]);
    }

    #[test]
    fn duplicate_and_empty_origins_follow_dart_set_semantics() {
        // Dart 探针实测（`rust/_p03_norm_probe/probe_output.txt`「Set 语义」
        // 节 + 「case origins_edge_semantics」）：
        // - `{"o","o"}.length == 1`（Set 保序去重）；
        // - `{'""'}.length == 1`（空串是合法成员，不滤除）；
        // - 首条 = eff 保序去重副本（不滤空串）；
        // - 合并 = 并集追加不滤空串，仅 `other.origin` 非空时追加。
        // 重复 origins 字段（`["o","o"]`）→ 计数 1
        let a = SearchBook {
            origins: vec![
                "https://o1.example".to_string(),
                "https://o1.example".to_string(),
            ],
            ..mk("重生", "甲", "https://o1.example")
        };
        let out = aggregate_search_books(&[a], "重生", true);
        assert_eq!(
            out[0].origins,
            vec!["https://o1.example".to_string()],
            "重复 origins 字段按 Set 去重（探针实测 {{\"o\",\"o\"}} 计 1）"
        );
        assert_eq!(origins_count(&out[0].origins), 1);

        // origins 字段 `[""]` + origin 空 → 条目 origins `[""]`，计数 1（空串保留）
        let b = SearchBook {
            origins: vec![String::new()],
            origin: String::new(),
            book_url: "https://o2.example/book/g2".to_string(),
            ..mk("重生", "乙", "")
        };
        let out2 = aggregate_search_books(&[b], "重生", true);
        assert_eq!(
            out2[0].origins,
            vec![String::new()],
            "空串是合法集合成员，不得滤除（探针实测 {{'\"'}} 计 1）"
        );
        assert_eq!(origins_count(&out2[0].origins), 1);

        // 合并：self `[""]` + other eff `["https://o6.example"]`（origin 同值）
        // → `["", "https://o6.example"]`（并集不滤空串，探针实测 merge 输出
        // `[|o6]`）
        let c1 = SearchBook {
            origins: vec![String::new()],
            ..mk("重生", "戊", "https://o5.example")
        };
        let c2 = SearchBook {
            origins: vec!["https://o6.example".to_string()],
            ..mk("重生", "戊", "https://o6.example")
        };
        let out3 = aggregate_search_books(&[c1, c2], "重生", true);
        assert_eq!(
            out3[0].origins,
            vec![String::new(), "https://o6.example".to_string()],
            "合并不滤空串成员（探针实测 merge self=[\"\"] other=[o6] → [|o6]）"
        );
        assert_eq!(origins_count(&out3[0].origins), 2);

        // origin 为 "" 且 eff 为空 → 合并不追加任何成员（origin 判空跳过）
        let d1 = mk("重生", "丁", "");
        let d2 = SearchBook {
            book_url: "https://o4.example/book/g6".to_string(),
            origin: "https://o4.example".to_string(),
            ..mk("重生", "丁", "")
        };
        let out4 = aggregate_search_books(&[d1, d2], "重生", true);
        assert_eq!(
            out4[0].origins,
            vec!["https://o4.example".to_string()],
            "首条 eff 空 → 条目 origins 空；合并仅追加 other.origin（探针实测）"
        );
        assert_eq!(origins_count(&out4[0].origins), 1);
    }

    #[test]
    fn bucket_order_and_within_bucket_sort() {
        // 桶序 equal→tags→contains→other；桶内 originsCount 降序 + 到达序平局
        let books = [
            mk("重生之路", "甲", "https://1.com"), // contains（到达 0）
            mk("都市情缘", "乙", "https://2.com"), // tags（kind 命中）
            mk("重生", "丙", "https://3.com"),     // equal
            mk("重生", "丁", "https://4.com"),     // equal，与丙平局 count=1 → 到达序在前者先
            mk("噪声书", "路人", "https://5.com"), // other
        ];
        let mut tagged = books[1].clone();
        tagged.kind = Some("重生,都市".to_string());
        let books = vec![
            books[0].clone(),
            tagged,
            books[2].clone(),
            books[3].clone(),
            books[4].clone(),
        ];
        let out = aggregate_search_books(&books, "重生", true);
        assert_eq!(
            out.iter().map(|b| b.name.as_str()).collect::<Vec<_>>(),
            vec!["重生", "重生", "都市情缘", "重生之路", "噪声书"],
            "equal(丙,丁 平局按到达序) → tags → contains → other"
        );
        assert_eq!(out[0].author, "丙");
        assert_eq!(out[1].author, "丁");
    }

    #[test]
    fn multi_source_count_desc_within_bucket() {
        // 同桶多源条按 originsCount 降序（乙 3 源 > 甲 1 源）
        let books = [
            mk("一人之下", "甲", "https://1.com"),
            mk("一人之下", "乙", "https://2a.com"),
            mk("一人之下", "乙", "https://2b.com"),
            mk("一人之下", "乙", "https://2c.com"),
        ];
        let out = aggregate_search_books(&books, "一人之下", true);
        assert_eq!(out[0].author, "乙");
        assert_eq!(origins_count(&out[0].origins), 3);
        assert_eq!(out[1].author, "甲");
        assert_eq!(origins_count(&out[1].origins), 1);
    }

    #[test]
    fn keep_other_false_drops_other_bucket() {
        let books = [
            mk("重生", "甲", "https://a.com"),
            mk("斗破苍穹", "天蚕土豆", "https://b.com"),
        ];
        let mut with_kind = books[1].clone();
        with_kind.kind = Some("玄幻".to_string());
        let books = vec![books[0].clone(), with_kind];
        let out = aggregate_search_books(&books, "重生", false);
        assert_eq!(out.len(), 1, "keep_other=false 丢弃 other 桶");
        assert_eq!(out[0].name, "重生");
        // keep_other=true 时 other 保留且排末尾
        let out2 = aggregate_search_books(&books, "重生", true);
        assert_eq!(out2.len(), 2);
        assert_eq!(out2[1].name, "斗破苍穹");
    }

    #[test]
    fn same_key_lands_in_different_buckets_by_kind() {
        // 四桶各自独立 map：同名同作者键可因 kind 差异落不同桶
        // （Dart L151-154 四个独立 map 同规则）
        let books = [
            mk("书A", "张三", "https://a.com"), // kind 命中 → tags
            mk("书A", "张三", "https://b.com"), // 无 kind、name contains → contains
        ];
        let mut tagged = books[0].clone();
        tagged.kind = Some("重生".to_string());
        let books = vec![tagged, books[1].clone()];
        let out = aggregate_search_books(&books, "重生", true);
        assert_eq!(out.len(), 2, "同一 (name,author) 键分落两桶各一条");
        assert_eq!(out[0].book_url, "https://a.com/book/书A", "tags 桶在前");
        assert_eq!(out[1].book_url, "https://b.com/book/书A");
    }

    #[test]
    fn empty_input_and_empty_key() {
        // 空输入 → 空输出
        let out = aggregate_search_books(&[], "x", true);
        assert!(out.is_empty());
        // 空关键词 → 原样返回（不聚合、不分桶）
        let books = [
            mk("斗破苍穹", "天蚕土豆", "https://a.com"),
            mk("斗破苍穹", "天蚕土豆", "https://b.com"),
        ];
        let out2 = aggregate_search_books(&books, "", true);
        assert_eq!(out2.len(), 2, "空 key 不聚合（Dart L149 同规则）");
    }

    #[test]
    fn has_read_record_or_across_sources() {
        let mut b1 = mk("重生", "甲", "https://a.com");
        b1.has_read_record = true;
        let b2 = mk("重生", "甲", "https://b.com"); // false
        let out = aggregate_search_books(&[b1, b2], "重生", true);
        assert_eq!(out.len(), 1);
        assert!(out[0].has_read_record, "任一来源有阅读记录即保留");
        // 元数据保留首条（hasReadRecord=false 首条 + true 后条 → OR 为 true）
        let b3 = mk("重生", "甲", "https://b.com");
        let b4 = SearchBook {
            book_url: "https://a.com/book/重生".to_string(),
            has_read_record: true,
            ..mk("重生", "甲", "https://a.com")
        };
        let out2 = aggregate_search_books(&[b3, b4], "重生", true);
        assert!(out2[0].has_read_record);
        assert_eq!(
            out2[0].book_url, "https://b.com/book/重生",
            "首条元数据保留"
        );
    }

    #[test]
    fn pre_filled_origins_field_consumed() {
        // 输入书已带 origins 字段（聚合入口产出再聚合 / 未来填充场景）→
        // effectiveOrigins 优先用字段值（Dart SearchResult.origins 非空同规则）
        let a = SearchBook {
            origins: vec!["https://x.com".to_string(), "https://y.com".to_string()],
            ..mk("重生", "甲", "https://a.com")
        };
        let b = mk("重生", "甲", "https://b.com");
        let out = aggregate_search_books(&[a, b], "重生", true);
        assert_eq!(out.len(), 1);
        assert_eq!(
            out[0].origins,
            vec![
                "https://x.com".to_string(),
                "https://y.com".to_string(),
                "https://b.com".to_string()
            ],
            "字段序在前，新 origin 追加在后（首次出现序）"
        );
    }

    #[test]
    fn stable_tie_by_first_arrival_index() {
        // 同 originsCount 跨到达按首次到达序（对齐 Dart sortedBucket 索引平局）
        let books = [
            mk("测试甲", "甲作者", "https://1.com"),
            mk("测试乙", "乙作者", "https://2.com"),
            mk("测试丙", "丙作者", "https://3.com"),
        ];
        let out = aggregate_search_books(&books, "测试", true);
        assert_eq!(
            out.iter().map(|b| b.name.as_str()).collect::<Vec<_>>(),
            vec!["测试甲", "测试乙", "测试丙"],
            "三者 count 均 1 → 首次到达序，不得乱序"
        );
    }

    #[test]
    fn serde_origins_additive_default_and_skip_empty() {
        // 加法式：旧 JSON 无 origins 字段 → 反序列化缺省空数组
        let de: SearchBook = serde_json::from_str(r#"{"name":"x","origin":"o"}"#).unwrap();
        assert!(de.origins.is_empty());
        // 空 origins 序列化省略（批次 JSON 形态零变化）
        let json = serde_json::to_string(&de).unwrap();
        assert!(!json.contains("origins"), "空 origins 不得进入序列化输出");
        // 非空 origins 随 JSON 往返
        let mut s = de.clone();
        s.origins = vec!["o1".to_string()];
        let json2 = serde_json::to_string(&s).unwrap();
        assert!(json2.contains(r#""origins":["o1"]"#));
        let de2: SearchBook = serde_json::from_str(&json2).unwrap();
        assert_eq!(de2.origins, vec!["o1".to_string()]);
    }
}
