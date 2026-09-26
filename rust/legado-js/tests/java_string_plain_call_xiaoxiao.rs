//! 小小阅读×3 书源 jsLib（`JavaString` 无 new 普通调用）e2e 回归测试
//!
//! 根因（双基准裁决定案，`.tmp/crosscheck_20260927/verdict.md` = 引擎缺口）：
//! 小小阅读源把 `bookSourceComment` 当 jsLib，bookList 首行
//! `eval(String(source.bookSourceComment))`，jsLib 内 `with (javaImport)`
//! 作用域（`new JavaImporter(Packages.java.util, Packages.java.lang,
//! Packages.java.io)` 合并包成员）中标识符 `String` 被 Packages 模拟层
//! `java.lang.String`（`JavaString`，`rust/legado-js/src/host_api/
//! quickjs_impl.rs` `inject_packages_shim`）遮蔽。`k = String(Arrays
//! .copyOfRange(data, 0, 16))` 为**无 new** 普通调用时，`JavaString` 走
//! bytes 分支返回 JSString **对象**（new 语义遗留——七猫正文修复依赖），
//! 随后宿主侧 `java.digestHex(k, 'sha-256')`（`encoding.rs`
//! `digest_hex(data: &str, …)`）经 rquickjs 严格转换拒收对象 →
//! `Error converting from js 'object' into type 'string'`，整条 bookList
//! 规则崩溃（参考版 io.legato.kazusa 同关键词实搜 wendulou 出 100 本、
//! 我方 0 结果，故判引擎缺口）。
//!
//! 上游语义（Rhino LiveConnect）：无 new 调用类构造器 = 实例化，其字符串
//! coercion 即内容本身，宿主侧最终拿到的是**原始字符串**。修复：`JavaString`
//! 以 `new.target` 判别调用形态——无 new 普通调用返回原始字符串，`new`
//! 调用保持现状返回 JSString 对象（七猫正文 `[object Object]` 修复依赖，
//! 不得破坏）。
//!
//! 覆盖三契约：
//! 1. 新契约：`Packages.java.lang.String('abc')`（无 new）返回
//!    `typeof === 'string'` 且值 'abc'；bytes 形态（1/2/4 参）无 new 调用
//!    同样返回原始串；
//! 2. 小小阅读形态端到端：`with` 作用域内 `k = String(Arrays
//!    .copyOfRange(u8, 0, 16)); java.digestHex(k, 'sha-256')` 全链路
//!    返回合法小写 hex 串（64 位，且与 Rust 侧 sha256 同 16 字节载荷逐字一致）；
//! 3. 七猫既有语义守护：`new Packages.java.lang.String(bytes, 'UTF-8')`
//!    仍为对象且 `String(...)` 取回明文、`.getBytes` 可用（lib 测试
//!    `test_packages_java_string_new_bytes_returns_plaintext` 同构断言全绿）。

#![cfg(feature = "quickjs")]

use hex::encode as hex_encode;
use legado_js::engine::JsEngine;
use legado_js::host_api::current_source;
use legado_js::sandbox::SandboxConfig;
use legado_js::QuickJsEngine;
use sha2::Digest;
use sha2::Sha256;

/// 与生产 `QuickJsExecutor` fresh 路径同源的引擎配置
fn production_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("生产同源引擎创建失败")
}

/// 契约 1（新契约）：`Packages.java.lang.String(...)` 无 new 普通调用一律
/// 返回原始字符串（非 JSString 对象）。字符串 / bytes 1 参 / bytes 2 参 /
/// bytes 4 参（offset+length）四形态全覆盖。
#[test]
fn java_string_plain_call_returns_primitive() {
    let engine = production_engine();
    let script = r#"
(function () {
  var str = Packages.java.lang.String('abc');
  var b1 = Packages.java.lang.String(new Uint8Array([72,101,108,108,111]));
  var b2 = Packages.java.lang.String(new Uint8Array([72,101,108,108,111]), 'UTF-8');
  var b4 = Packages.java.lang.String(new Uint8Array([0,72,101,108,108,111,0]), 1, 5, 'UTF-8');
  return JSON.stringify({
    strType: typeof str, strVal: str,
    b1Type: typeof b1, b1Val: b1,
    b2Type: typeof b2, b2Val: b2,
    b4Type: typeof b4, b4Val: b4
  });
})()
"#;
    current_source::with_current_source_tag("e2e.java_string.xiaoxiao.primitive", || {
        let out: String = JsEngine::eval(&engine, script).expect("无 new 普通调用用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["strType"], "string",
            "String('abc') 无 new 应返回原始字符串，实际: {out}"
        );
        assert_eq!(v["strVal"], "abc", "值应为 'abc'; 实际: {out}");
        assert_eq!(
            v["b1Type"], "string",
            "bytes 1 参无 new 应返回原始字符串，实际: {out}"
        );
        assert_eq!(v["b1Val"], "Hello", "bytes 解码应还原 'Hello'; 实际: {out}");
        assert_eq!(
            v["b2Type"], "string",
            "bytes 2 参无 new 应返回原始字符串，实际: {out}"
        );
        assert_eq!(
            v["b2Val"], "Hello",
            "bytes+charset 解码应还原 'Hello'; 实际: {out}"
        );
        assert_eq!(
            v["b4Type"], "string",
            "bytes 4 参（offset+length）无 new 应返回原始字符串，实际: {out}"
        );
        assert_eq!(
            v["b4Val"], "Hello",
            "4 参重载应取 [offset, offset+length) 子数组解码，实际: {out}"
        );
    });
}

/// 契约 2（小小阅读形态端到端）：`new JavaImporter(java.util, java.lang,
/// java.io)` 合并包 → `with (javaImport)` 作用域内 `k = String(Arrays
/// .copyOfRange(u8, 0, 16))` 返回原始字符串 → 宿主 `java.digestHex(k,
/// 'sha-256')` 全链路返回合法小写 hex 串，且与 Rust 侧 `sha256` 同载荷
/// 逐字一致（防 shim 输出非真实摘要值的假绿）。
#[test]
fn xiaoxiao_with_scope_string_plain_call_digest_hex() {
    let engine = production_engine();
    // 16 字节载荷（0x01..=0x10，均为合法 UTF-8 控制字符，各占 1 字节）
    const PAYLOAD: [u8; 16] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
    let mut hasher = Sha256::new();
    hasher.update(PAYLOAD);
    let expected_hex = hex_encode(hasher.finalize());

    let script = r#"
(function () {
  var u8 = new Uint8Array([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]);
  var javaImport = new JavaImporter(Packages.java.util, Packages.java.lang, Packages.java.io);
  var k;
  with (javaImport) {
    k = String(Arrays.copyOfRange(u8, 0, 16));
  }
  var digest = java.digestHex(k, 'sha-256');
  return JSON.stringify({
    kType: typeof k,
    kLen: (typeof k === 'string' ? k.length : -1),
    digest: digest,
    digestType: typeof digest
  });
})()
"#;
    current_source::with_current_source_tag("e2e.java_string.xiaoxiao.digest_hex", || {
        let out: String = JsEngine::eval(&engine, script).expect("小小阅读全链路脚本执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["kType"], "string",
            "with 作用域内 String(bytes) 无 new 应返回原始字符串（非 JSString 对象），实际: {out}"
        );
        assert_eq!(
            v["kLen"], 16,
            "bytes[0..16) 经 UTF-8 解码应为 16 字符，实际: {out}"
        );
        let digest = v["digest"]
            .as_str()
            .expect("digestHex 输出应为字符串: {out}");
        assert_eq!(digest.len(), 64, "SHA-256 hex 应为 64 位，实际: {out}");
        assert!(
            digest
                .chars()
                .all(|c| c.is_ascii_digit() || matches!(c, 'a'..='f')),
            "hex 应全为小写十六进制（0-9a-f），实际: {out}"
        );
        assert_eq!(
            digest, expected_hex,
            "全链路 digestHex 结果应与 Rust 侧 sha256(同 16 字节载荷) 逐字一致，实际: {out}"
        );
    });
}

/// 契约 3（七猫既有语义守护）：`new Packages.java.lang.String(bytes,
/// 'UTF-8')` 仍返回 JSString **对象**（`new` 路径不变）——`String(obj)`
/// 经 toString 取回明文、`.getBytes(charset)` 返回字节数组可用；防止
/// `new.target` 判别误伤 new 调用路径。
#[test]
fn qimao_new_string_bytes_still_object_guard() {
    let engine = production_engine();
    let script = r#"
(function () {
  var o = new Packages.java.lang.String(new Uint8Array([72,101,108,108,111]), 'UTF-8');
  var o4 = new Packages.java.lang.String(new Uint8Array([0,72,101,108,108,111,0]), 1, 5, 'UTF-8');
  return JSON.stringify({
    oType: typeof o,
    isObj: (typeof o === 'object' && o !== null),
    strVal: String(o),
    getBytesLen: o.getBytes('UTF-8').length,
    o4StrVal: String(o4),
    valueOfVal: o.valueOf()
  });
})()
"#;
    current_source::with_current_source_tag("e2e.java_string.qimao.new_guard", || {
        let out: String = JsEngine::eval(&engine, script).expect("七猫 new 语义守护用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["oType"], "object",
            "new String(bytes, charset) 仍应返回 JSString 对象，实际: {out}"
        );
        assert_eq!(v["isObj"], true, "new 返回值应为非空对象; 实际: {out}");
        assert_eq!(
            v["strVal"], "Hello",
            "String(对象) 经 toString 应取回明文，实际: {out}"
        );
        assert_eq!(
            v["getBytesLen"], 5,
            ".getBytes('UTF-8') 应返回 5 字节，实际: {out}"
        );
        assert_eq!(
            v["o4StrVal"], "Hello",
            "new 4 参重载取子数组解码应还原明文，实际: {out}"
        );
        assert_eq!(
            v["valueOfVal"], "Hello",
            ".valueOf() 应取回明文，实际: {out}"
        );
    });
}
