//! 跨端夹具校验（队列⑩a P1-1 项2，2026-09-22）
//!
//! 验证「Rust 跨源聚合结果 == Dart 现行 `applyPrecisionSearch` 期望」：
//! 本测试与 Dart 侧 `flutter_legado/test/unit/search_aggregate_fixture_test.dart`
//! 读同一夹具 `tests/fixtures/search_aggregate/cross_source_merge.json`，
//! 各自跑本端聚合实现并与夹具 `expected` 逐条比对：
//! - `name`/`author`/`origin`/`originName`/`bookUrl`/`kind`/`hasReadRecord`
//!   按索引顺序敏感比对（`kind` 缺失/`null` 视同 None）；
//! - `origins` 按序比对（首次出现序为契约：Dart `Set<String>` 为
//!   LinkedHashSet 保序、Rust 实现同保序去重，两端测试约定一致）；
//! - 不依赖真网络（纯 JSON 输入，聚合为无状态纯函数）。
//!
//! 覆盖语义：跨源同名同作者合并 + origins 累加（首次出现序）、作者「作者：」
//! 前缀 / 书名「 作者」后缀归一化后合并、同源重复（不同 bookUrl）origin 去重
//! 不重复计数、桶序 equal→tags→contains→other、桶内 originsCount 降序 +
//! 首次到达序平局、预填 `origins` 字段（加法式字段）优先于 `origin` 消费、
//! `hasReadRecord` 跨源 OR、`keep_other=false`（精准搜索）丢弃 other 桶、
//! 空 key 原样透传（book 不清洗）、Unicode 边界（U+FEFF / U+0085 / CR /
//! U+2028 / U+2029，正则文本对齐 + ECMAScript 等价归一化）、重复与空串
//! origins 的 Set 语义（保序去重留首 / 并集不滤空串 / 空串是合法成员）。

use serde_json::Value;

const FIXTURE_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/fixtures/search_aggregate/cross_source_merge.json"
);

/// 可选字符串字段（缺失 / `null` → None）
fn opt_str(v: &Value, field: &str) -> Option<String> {
    match v.get(field) {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(o) => panic!("字段 {field} 期望字符串，实际 {o}"),
    }
}

fn origins_of(v: &Value) -> Vec<String> {
    v.get("origins")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default()
}

/// 单条投影比对（顺序敏感字段 + origins 按序比对）
fn assert_projection(actual: &Value, expected: &Value, case_id: &str, idx: usize) {
    for field in ["name", "author", "origin", "originName", "bookUrl"] {
        let a = actual.get(field).and_then(Value::as_str).unwrap_or("");
        let e = expected.get(field).and_then(Value::as_str).unwrap_or("");
        assert_eq!(a, e, "[{case_id}] 第{idx}条 {field}");
    }
    assert_eq!(
        opt_str(actual, "kind").as_deref(),
        opt_str(expected, "kind").as_deref(),
        "[{case_id}] 第{idx}条 kind（缺失/null 视同 None）"
    );
    assert_eq!(
        actual
            .get("hasReadRecord")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        expected
            .get("hasReadRecord")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        "[{case_id}] 第{idx}条 hasReadRecord"
    );
    let a_origins = origins_of(actual);
    let e_origins = origins_of(expected);
    assert_eq!(
        a_origins, e_origins,
        "[{case_id}] 第{idx}条 origins（按序比对，首次出现序为契约）"
    );
}

#[test]
fn cross_source_merge_fixture_matches_dart_apply_precision_search() {
    let raw = std::fs::read_to_string(FIXTURE_PATH).expect("读取夹具 JSON");
    let fixture: Value = serde_json::from_str(&raw).expect("夹具 JSON 解析失败");

    for case in fixture
        .get("cases")
        .and_then(Value::as_array)
        .expect("夹具须含 cases 数组")
        .iter()
    {
        let case_id = case.get("id").and_then(Value::as_str).unwrap();
        let key = case.get("key").and_then(Value::as_str).unwrap();
        let keep_other = case.get("keep_other").and_then(Value::as_bool).unwrap();

        // books 原样作为 CoreSearchBook 数组 JSON 喂给聚合入口（同 SearchSourceBatch.books[] 形态）
        let books_json = case.get("books").expect("夹具须含 books 数组").to_string();
        let out_json =
            legado_ffi::api::search::aggregate_search_books_json(&books_json, key, keep_other)
                .unwrap_or_else(|e| panic!("[{case_id}] aggregate_search_books_json 失败: {e}"));

        let actual: Vec<Value> = serde_json::from_str(&out_json).expect("聚合输出 JSON 解析失败");
        let expected = case
            .get("expected")
            .and_then(Value::as_array)
            .expect("夹具须含 expected 数组");

        assert_eq!(
            actual.len(),
            expected.len(),
            "[{case_id}] 输出条数（Rust 聚合 vs 夹具期望）"
        );
        for (i, (a, e)) in actual.iter().zip(expected.iter()).enumerate() {
            assert_projection(a, e, case_id, i);
        }
    }
}

#[test]
fn fixture_input_books_deserialize_as_core_search_book() {
    // 加法式字段消费面：books 中预填的 origins 数组（Rust 单一真源输出再聚合
    // 场景）与缺省（旧批次 JSON 无 origins 字段）均须可反序列化
    let raw = std::fs::read_to_string(FIXTURE_PATH).expect("读取夹具 JSON");
    let fixture: Value = serde_json::from_str(&raw).unwrap();
    let books = fixture
        .get("cases")
        .and_then(Value::as_array)
        .unwrap()
        .iter()
        .next()
        .unwrap()
        .get("books")
        .unwrap();
    let parsed: Vec<legado_ffi::legado_core::models::misc::SearchBook> =
        serde_json::from_value(books.clone()).expect("books 应可解析为 CoreSearchBook 数组");
    assert!(!parsed.is_empty());
    // 预填 origins 的条目（加法式字段）反序列化保留；无该字段的条目缺省空数组
    let pre_filled = parsed
        .iter()
        .find(|b| b.name == "重生" && b.author == "庚")
        .expect("夹具须含预填 origins 条目");
    assert_eq!(pre_filled.origins.len(), 2, "预填 origins 字段须被消费");
    let plain = parsed
        .iter()
        .find(|b| b.name == "斗破苍穹")
        .expect("夹具须含未预填 origins 条目");
    assert!(
        plain.origins.is_empty(),
        "旧 JSON 无 origins 字段须缺省空数组"
    );
}
