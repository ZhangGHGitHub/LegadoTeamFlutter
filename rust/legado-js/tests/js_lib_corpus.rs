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

/// favcomic jsLib：`java.io.InputStream` 符号已解析为可用函数（队列末项
/// `java.io` 最小面 shim 上线后）
///
/// 取证（2026-09-22，生产同源 QuickJS 引擎本地探针实测，非猜测）：
/// - 语料 favcomic（索引 703）混淆体对 `Packages.java.io.InputStream` 做 Java 式
///   类型探测（`.prototype`/`instanceof`），是 decode 路径（`ruleContent.imageDecode`
///   + `coverDecodeJs` → `decode(result)`，真实 content/cover 可达）的 Java 解密分支
///     脚手架。`InputStream` 的**真实数据路径**是 `java.createSymmetricCrypto`
///     （CryptoJS AES）+ `java.strToBytes`，`InputStream` 只搬运字节。
/// - 队列末项 `java.io` 最小面补上抽象基类 `InputStream`（纯字节缓冲读流，无真实
///   JVM 对象/文件 IO/反射）后：`Packages.java.io.InputStream` 由「未知类哨兵
///   （读取登记 + new/read 抛可读文案）」变为**已实现函数**——`new`/`read`/
///   `instanceof`/`.prototype.read` 全部可用，脚本越过该探测点进入 Java 解密
///   分支（探针 `K Packages.java.io.InputStream`）。
/// - **顶层签名诚实声明（审查修）**：IIFE 的字节码 try/catch 吞掉 `decode` 的
///   运行时结果（测试用伪 7 字节输入非有效 AES 密文 → `decode` 返回 `null`）并
///   执行回退子程序，顶层**完成**返回字面 `undefined`——但此顶层返回值在 shim
///   上线前后**同值、不具区分力**（审查实测：删除 `Packages.java.io.InputStream`
///   的哨兵态同样完成加载并返回 `undefined`——字节码吞掉异常后回退路径不产生
///   返回值）。真实区分点是：① `java.io.InputStream` 解析为可用函数（isFn /
///   `.prototype.read` / instanceof / read 探测全过）；② 能力台账**不再登记**
///   `java.io.InputStream` 前缀键（前缀匹配负断言）；③ 真正未实现的
///   `java.io.PrintStream` 仍走「可读文案 + 台账登记」路径（能力清单提示保留在
///   真正使用点，保护不放松）。
/// - **输出对比局限（诚实声明）**：本测试无法给出 favcomic 真实解密输出与参考
///   实现的可复现对比——缺少真实 favcomic 密文与 AES 密钥/口令（探针 `jcalls` 显示
///   `createSymmetricCrypto(s:20, s:51, u8:7)`：20 字符 key、51 字符 secret，值不外露）。
///   可复现的是上述 ①②③ 区分点，而非解密产物。
#[test]
fn favcomic_jslib_loads_with_resolved_input_stream() {
    use legado_js::host_api::capability_ledger as ledger;

    let engine = production_engine();
    let lib = load_fixture("favcomic_ximan_comic.js");

    // 台账为进程级全局；与同二进制内其他触碰台账的测试串行。
    let _ledger_lock = ledger::LEDGER_TEST_LOCK.lock().unwrap();
    ledger::reset_unknown_java_symbols();

    current_source::with_current_source_tag("e2e.favcomic", || {
        assert!(
            engine.check_syntax(&lib).is_ok(),
            "favcomic jsLib 语法应合法（混淆 IIFE 无语法错误）"
        );

        // 顶层完成加载返回字面 undefined（字节码回退）。注意（审查修）：此顶层
        // 值在 shim 上线前后同值（哨兵态同样完成加载），**不具区分力**——仅作
        // 加载完成性观测；真实区分点是下方的 ① 解析探测 + ②③ 台账断言。
        let observed = match JsEngine::eval(&engine, &lib) {
            Ok(v) => v,
            Err(e) => e.to_string(),
        };
        assert!(
            observed.trim() == "undefined",
            "favcomic jsLib 应完成加载并返回 undefined（字节码回退）；观测: {observed}"
        );

        // 区分点①（队列末项 java.io 最小面）：`java.io.InputStream` 已解析为
        // 函数（非能力受限哨兵）——`.prototype.read` 可直接访问（favcomic
        // 混淆体的 Java 式类型探测点），new/read/instanceof 均可用。
        let resolved: String = JsEngine::eval(
            &engine,
            r#"
            var Ctor = Packages.java.io.InputStream;
            var s = new Ctor(new Uint8Array([9, 8, 7]));
            JSON.stringify({
                isFn: typeof Ctor === 'function',
                protoRead: typeof Ctor.prototype.read === 'function',
                instance: s instanceof Ctor,
                readOk: s.read() === 9
            });
            "#,
        )
        .expect("InputStream 解析探测失败");
        assert!(
            resolved.contains("\"isFn\":true")
                && resolved.contains("\"protoRead\":true")
                && resolved.contains("\"instance\":true")
                && resolved.contains("\"readOk\":true"),
            "java.io.InputStream 应解析为可用函数（非哨兵）：{resolved}"
        );

        // 区分点②（能力清单断言）：已实现的 `java.io.InputStream` 面（类级
        // 探测 + 实例已实现成员）不登记台账。前缀匹配（审查修）：实例/类级未
        // 覆盖成员登记键形如 `java.io.InputStream.<成员>`，精确等值会漏掉后缀键；
        // 未实现的 PrintStream 命中仍须「可读文案 + 台账登记」双到位（保护不放松）。
        assert!(
            !ledger::unknown_java_symbols()
                .iter()
                .any(|(sym, _)| sym.starts_with("java.io.InputStream")),
            "已实现的 java.io.InputStream 面不应登记进能力台账"
        );
        let msg: String = JsEngine::eval(
            &engine,
            r#"
            var m = '';
            try { new Packages.java.io.PrintStream(); } catch (e) { m = String(e); }
            m;
            "#,
        )
        .expect("PrintStream 能力清单探测失败");
        assert!(
            msg.contains("Java 脚本能力") && msg.contains("java.io.PrintStream"),
            "未实现符号应抛可读文案并点名缺失符号：{msg}"
        );
        assert!(
            ledger::unknown_java_symbols()
                .iter()
                .any(|(sym, _)| sym == "java.io.PrintStream"),
            "未实现符号 java.io.PrintStream 应登记进能力台账"
        );
    });

    ledger::reset_unknown_java_symbols();
}
