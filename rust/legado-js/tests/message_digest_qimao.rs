//! `java.security.MessageDigest` 能力端到端测试（quickjs 档）
//!
//! 夹具：`tests/fixtures/js_lib/qimao_api_searchurl.js`（🏷七猫小说·API
//! `https://api-bc.wtzw.com` 的 jsLib 原文，来源/提取时间见夹具头部注释）。
//!
//! 引擎搭建与生产 `QuickJsExecutor`（`rust/legado-ffi/src/js_executor.rs`
//! `execute_js` fresh 路径）同源：`SandboxConfig::default().with_allow_script_run(true)`
//! + 64MB 内存上限 + `with_current_source_tag` + jsLib 先行 + RESPONSE/JSOUP 双桥重注入。
//!
//! 期望值出处（2026-09-25 Python `hashlib.md5` 独立重算，非猜测）：
//! - `qmMd5('abc')` = RFC 1321 标准向量 `900150983cd24fb0d6963f7d28e17f72`；
//! - `qmSearch('测试', 1)` 的 `sign` 参数 = `413e3060d1e64a477f1ce7c82d6c13f4`
//!   （`qmSign` 对排序键值拼接 + `QM_KEY` 后取 MD5）。
//!
//! 红→绿（本批次）：改造前该 jsLib 求值在 `QM_HEADERS` IIFE 处抛「此书源需要
//! Java 脚本能力（Packages.java.security.MessageDigest），当前不支持」；
//! 接入 MessageDigest shim 后加载成功且摘要可复现。

#![cfg(feature = "quickjs")]

use legado_js::engine::JsEngine;
use legado_js::host_api::capability_ledger as ledger;
use legado_js::host_api::current_source;
use legado_js::host_api::quickjs_impl::{JSOUP_BRIDGE_JS, RESPONSE_BRIDGE_JS};
use legado_js::sandbox::SandboxConfig;
use legado_js::QuickJsEngine;

/// 与生产 `QuickJsExecutor` fresh 路径同源的引擎配置
fn production_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("生产同源引擎创建失败")
}

fn load_fixture(name: &str) -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/js_lib")
        .join(name);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("jsLib 夹具读取失败: {}: {e}", path.display()))
}

/// 七猫 API jsLib：`java.security.MessageDigest` 已接入后加载成功，
/// 关键摘要函数输出与 Python 独立重算一致（标准向量对照）
#[test]
fn qimao_api_jslib_message_digest_roundtrip() {
    let engine = production_engine();
    let lib = load_fixture("qimao_api_searchurl.js");

    current_source::with_current_source_tag("e2e.qimao-api", || {
        // 生产顺序：jsLib 先行，随后双桥重注入。
        // jsLib 顶层 QM_HEADERS IIFE 在加载期即触发 qmSign → qmMd5 → MessageDigest，
        // 故「加载成功」本身就是 MessageDigest 能力已到位的证据。
        JsEngine::eval(&engine, &lib).expect("七猫 API jsLib 加载失败（能力缺失?）");
        let _ = JsEngine::eval(&engine, RESPONSE_BRIDGE_JS);
        let _ = JsEngine::eval(&engine, JSOUP_BRIDGE_JS);

        // 纯函数确定性摘要（RFC 1321 向量：MD5("abc")）
        let md5abc: String = JsEngine::eval(&engine, "qmMd5('abc')").expect("qmMd5 求值失败");
        assert_eq!(
            md5abc, "900150983cd24fb0d6963f7d28e17f72",
            "MD5(\"abc\") 应命中 RFC 1321 标准向量；观测: {md5abc}"
        );

        // searchUrl 表达式 `qmSearch(key, page)` 的确定性签名
        //（与 Python `hashlib.md5` 重算一致；仅断言确定性摘要 + 基础 URL 前缀，
        //  避免 encodeURIComponent 与 quote 的差异干扰）
        let url: String =
            JsEngine::eval(&engine, "qmSearch('测试', 1)").expect("qmSearch 求值失败");
        assert!(
            url.starts_with("https://api-bc.wtzw.com/search/v1/words?"),
            "qmSearch 应返回七猫 API 搜索 URL；观测: {url}"
        );
        assert!(
            url.contains("sign=413e3060d1e64a477f1ce7c82d6c13f4"),
            "qmSearch 的 sign 参数应为 Python 重算值 413e3060...；观测: {url}"
        );
    });
}

/// 未知算法：抛可读能力文案 + 登记能力台账（不得静默）。
/// 以 `BOGUS_ALGO` 触发 `getInstance` 的未知算法分支，断言错误文案与台账登记。
#[test]
fn message_digest_unknown_algorithm_is_reported_and_ledgered() {
    let engine = production_engine();
    let lib = load_fixture("qimao_api_searchurl.js");

    // 台账为进程级全局；与同二进制内其他触碰台账的测试串行。
    let _ledger_lock = ledger::LEDGER_TEST_LOCK.lock().unwrap();
    ledger::reset_unknown_java_symbols();

    current_source::with_current_source_tag("e2e.qimao-api.unknown-algo", || {
        JsEngine::eval(&engine, &lib).expect("七猫 API jsLib 加载失败（能力缺失?）");

        let msg: String = JsEngine::eval(
            &engine,
            r#"
            var m = '';
            try { Packages.java.security.MessageDigest.getInstance('BOGUS_ALGO'); }
            catch (e) { m = String(e); }
            m;
            "#,
        )
        .expect("未知算法探测求值失败");
        assert!(
            msg.contains("Java 脚本能力") && msg.contains("BOGUS_ALGO"),
            "未知算法应抛可读能力文案并点名算法；观测: {msg}"
        );
        // 台账登记键：`java.security.MessageDigest.getInstance("BOGUS_ALGO")`
        assert!(
            ledger::unknown_java_symbols()
                .iter()
                .any(|(sym, _)| sym
                    .contains("java.security.MessageDigest.getInstance(\"BOGUS_ALGO\")")),
            "未知算法应登记进能力台账（unknown_java_symbols 快照）"
        );
    });

    ledger::reset_unknown_java_symbols();
}
