//! 真实语料 jsLib 夹具端到端测试（quickjs 档）
//!
//! 夹具来源（`.tmp/corpus/` 原始件不入库，归属注释见夹具头部）：
//! - `qimao_four_in_one_local.js`：七猫四合一本地版（合集 1283 索引 170，588700B）
//! - `favcomic_ximan_comic.js`：喜漫漫画（合集 1283 索引 703，16184B）
//!
//! 引擎搭建与生产 `QuickJsExecutor`（`rust/legado-ffi/src/js_executor.rs`
//! `execute_js` fresh 路径）**同源**：`SandboxConfig::default().with_allow_script_run(true)`
//! + 64MB 内存上限 + `with_current_source_tag` + jsLib 先行 + RESPONSE/JSOUP 双桥重注入。
//!
//! 期望值出处（2026-09-22 双路探明，非猜测）：
//! 1. 生产同源 QuickJS 引擎本地探针实测；
//! 2. Python 独立重算（`hashlib.md5` + `base64` + 夹具内 `qmMapChars` 算法
//!    + `QM_B64`/`QM_PARAM_MAP`/`QM_SECRET` 常量）逐项一致。

#![cfg(feature = "quickjs")]

use legado_js::engine::JsEngine;
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

/// 七猫 jsLib：加载成功，关键纯函数存在且输出可复现
#[test]
fn qimao_jslib_loads_and_pure_functions_are_stable() {
    let engine = production_engine();
    let lib = load_fixture("qimao_four_in_one_local.js");

    current_source::with_current_source_tag("e2e.qimao", || {
        // 生产顺序：jsLib 先行，随后双桥重注入
        JsEngine::eval(&engine, &lib).expect("七猫 jsLib 加载失败");
        let _ = JsEngine::eval(&engine, RESPONSE_BRIDGE_JS);
        let _ = JsEngine::eval(&engine, JSOUP_BRIDGE_JS);

        // 关键函数全部存在于全局（eval global=true，顶层函数声明落 globalThis）
        let fns_exist = r#"
['qmMd5','qmSign','qmUrlSign','qmBase64Encode','qmHexDecodeAscii',
 'qmParamEncode','qmCacheOf','qmBookVariable','qmJavaOf','qmDataUrl']
 .every(function (n) { return typeof globalThis[n] === 'function'; })
"#;
        let ok: String = JsEngine::eval(&engine, fns_exist).expect("函数存在性探测失败");
        assert_eq!(ok, "true", "七猫 jsLib 关键函数应全部存在");

        // 纯函数输出（探针 + Python 双路探明的可复现值）
        let probe = r#"
[
  'md5:' + qmMd5('legado'),
  'sign:' + qmSign('abc'),
  'urlsign:' + qmUrlSign({b:'2',a:'1'}),
  'b64:' + qmBase64Encode(null, 'hello'),
  'hex:' + qmHexDecodeAscii('68656c6c6f'),
  'paramenc:' + qmParamEncode('abc'),
  'hutool_md5_abc:' + JSON.stringify(Packages.cn.hutool.crypto.digest.DigestUtil.md5Hex('abc'))
].join('\n')
"#;
        let out: String = JsEngine::eval(&engine, probe).expect("七猫纯函数求值失败");
        let expected = "\
md5:bbd6a62a8a291b19a802e4ad64547fff
sign:16d266282165e5a533b1b4b899066d2d
urlsign:12eba91ac1503ad62ff49096b82fa411
b64:aGVsbG8=
hex:hello
paramenc:4qGT
hutool_md5_abc:\"900150983cd24fb0d6963f7d28e17f72\"";
        assert_eq!(
            out, expected,
            "七猫纯函数输出应与探针一致（md5 值同时经 hutool 桥与 Python 交叉验证）"
        );
    });
}

/// favcomic jsLib：加载**必失败**（缺失 Java 脚本能力，已文档化的降级路径）
///
/// 诚实断言可复现失败签名，而非虚构的「加载成功」：
/// - 语法合法（混淆 IIFE 无语法错误）→ `check_syntax` 通过，属**运行时**失败
///   （生产路径据此跳过 Rhino 宽容归一化，直接降级 + 台账登记）；
/// - 失败信息指向缺失的 Java 脚本能力：批次④能力受限 shim 上线后文案为
///   「此书源需要 Java 脚本能力（Packages.java.io.InputStream），当前不支持」，
///   此前原始签名为 `decode is not defined`——两种文案均为同一根因
///   （脚本运行期引用 QuickJS 环境不存在的 Java 能力），故断言取并集。
#[test]
fn favcomic_jslib_load_fails_with_reproducible_signature() {
    let engine = production_engine();
    let lib = load_fixture("favcomic_ximan_comic.js");

    current_source::with_current_source_tag("e2e.favcomic", || {
        assert!(
            engine.check_syntax(&lib).is_ok(),
            "favcomic jsLib 语法应合法（失败发生在运行期，非语法期）"
        );
        let err = JsEngine::eval(&engine, &lib)
            .expect_err("favcomic jsLib 加载必失败（缺失 Java 脚本能力）");
        let msg = err.to_string();
        assert!(
            msg.contains("Java 脚本能力") || msg.contains("decode"),
            "失败签名应指向缺失的 Java 脚本能力（两种批次文案均有效）: {msg}"
        );
    });
}
