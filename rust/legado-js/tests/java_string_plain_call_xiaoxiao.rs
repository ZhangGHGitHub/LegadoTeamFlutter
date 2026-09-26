//! 小小阅读×3 书源 jsLib（`JavaString` 无 new 普通调用）e2e 回归测试
//!
//! 根因（双基准裁决定案，`.tmp/crosscheck_20260927/verdict.md` = 引擎缺口，
//! 2026-09-26 第二层再定案）：小小阅读源把 `bookSourceComment` 当 jsLib，
//! bookList 首行 `eval(String(source.bookSourceComment))`，jsLib 内
//! `with (javaImport)` 作用域（`new JavaImporter(...)` 合并 Packages 包
//! 成员）中标识符 `String` 被 Packages 模拟层 `java.lang.String`
//! （`JavaString`，`rust/legado-js/src/host_api/quickjs_impl.rs`
//! `inject_packages_shim`）遮蔽。`k = String(Arrays.copyOfRange(data, 0,
//! 16))` 为**无 new** 普通调用——Rhino LiveConnect 语义下无 new 调用类
//! 构造器 = 实例化（返回 NativeJavaObject）。jsLib 实证链：
//! - L66 `k = String(bytes)` 后 L67 `java.digestHex(k, 'sha-256')`：
//!   第一层修复（普通调用返原始串）消除了 L66:26 的 rquickjs 严格转换拒收
//!   （"Error converting from js 'object' into type 'string'"）；
//! - 但 L83 `bytes = i.getBytes()`（`i = String(bytes...)` 普通调用结果）
//!   与 L68 `length = k.length()`（`k = java.digestHex(...)` 结果）证明
//!   **Java String 必须是带方法面的对象**——第一层设计被验收实测证伪
//!   （`not a function (at decode (<input>:68:20))`），本层回归对象返回：
//!   `JavaString` 两种调用形态一律返回 JSString 对象（补 Java String
//!   方法面），`java.digestHex` / `java.md5Encode` 的 JS 层包装先 String()
//!   强转入参、返回值统一 JSString 包装（宿主绑定本体不动）。
//!
//! 覆盖三契约：
//! 1. 新契约：`Packages.java.lang.String(...)`（无 new）四形态（字符串 /
//!    bytes 1 参 / bytes 2 参 / bytes 4 参 offset+length）一律返回
//!    JSString **对象**（`typeof === 'object'`），`String(...)` /
//!    valueOf 取回明文、`.getBytes()` 可调用；
//! 2. 小小阅读形态端到端：`with` 作用域内 `k = String(Arrays
//!    .copyOfRange(u8, 0, 16))` 为对象 → `java.digestHex(k, 'sha-256')`
//!    返回 JSString 对象（`k.length()` 可调用 = 64 位小写 hex，
//!    且与 Rust 侧 sha256 同 16 字节载荷逐字一致）；
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

/// 契约 1（第二层新契约）：`Packages.java.lang.String(...)` 无 new 普通
/// 调用一律返回 JSString **对象**（非原始串）。字符串 / bytes 1 参 /
/// bytes 2 参 / bytes 4 参（offset+length）四形态全覆盖；对象经
/// String()/valueOf 取回明文、`.getBytes()` 可调用（jsLib L83
/// `i.getBytes()` 实证需求）。
#[test]
fn java_string_plain_call_returns_jsstring_object() {
    let engine = production_engine();
    let script = r#"
(function () {
  var str = Packages.java.lang.String('abc');
  var b1 = Packages.java.lang.String(new Uint8Array([72,101,108,108,111]));
  var b2 = Packages.java.lang.String(new Uint8Array([72,101,108,108,111]), 'UTF-8');
  var b4 = Packages.java.lang.String(new Uint8Array([0,72,101,108,108,111,0]), 1, 5, 'UTF-8');
  return JSON.stringify({
    strType: typeof str, strVal: String(str), strValOf: str.valueOf(),
    b1Type: typeof b1, b1Val: String(b1),
    b2Type: typeof b2, b2Val: String(b2),
    b4Type: typeof b4, b4Val: String(b4),
    strGetBytesLen: str.getBytes('UTF-8').length
  });
})()
"#;
    current_source::with_current_source_tag("e2e.java_string.xiaoxiao.jsstring", || {
        let out: String = JsEngine::eval(&engine, script).expect("无 new 普通调用用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["strType"], "object",
            "String('abc') 无 new 应返回 JSString 对象（Rhino 实例化语义），实际: {out}"
        );
        assert_eq!(
            v["strVal"], "abc",
            "String(对象) 强转应取回 'abc'; 实际: {out}"
        );
        assert_eq!(v["strValOf"], "abc", "valueOf 应取回 'abc'; 实际: {out}");
        assert_eq!(
            v["b1Type"], "object",
            "bytes 1 参无 new 应返回 JSString 对象，实际: {out}"
        );
        assert_eq!(v["b1Val"], "Hello", "bytes 解码应还原 'Hello'; 实际: {out}");
        assert_eq!(
            v["b2Type"], "object",
            "bytes 2 参无 new 应返回 JSString 对象，实际: {out}"
        );
        assert_eq!(
            v["b2Val"], "Hello",
            "bytes+charset 解码应还原 'Hello'; 实际: {out}"
        );
        assert_eq!(
            v["b4Type"], "object",
            "bytes 4 参（offset+length）无 new 应返回 JSString 对象，实际: {out}"
        );
        assert_eq!(
            v["b4Val"], "Hello",
            "4 参重载应取 [offset, offset+length) 子数组解码，实际: {out}"
        );
        assert_eq!(
            v["strGetBytesLen"], 3,
            ".getBytes('UTF-8') 应可调用并返回 3 字节（jsLib L83 i.getBytes() 形态），实际: {out}"
        );
    });
}

/// 契约 2（小小阅读形态端到端）：`new JavaImporter(java.util, java.lang,
/// java.io)` 合并包 → `with (javaImport)` 作用域内 `k = String(Arrays
/// .copyOfRange(u8, 0, 16))` 返回 JSString 对象 → 宿主 `java.digestHex(k,
/// 'sha-256')` 返回 JSString 对象：`k.length()` 可调用（jsLib L68 形态），
/// 摘要为 64 位小写 hex 且与 Rust 侧 `sha256` 同载荷逐字一致
/// （防 shim 输出非真实摘要值的假绿）。
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
    kLen: k.length(),
    digestType: typeof digest,
    digestLen: digest.length(),
    digest: String(digest)
  });
})()
"#;
    current_source::with_current_source_tag("e2e.java_string.xiaoxiao.digest_hex", || {
        let out: String = JsEngine::eval(&engine, script).expect("小小阅读全链路脚本执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["kType"], "object",
            "with 作用域内 String(bytes) 无 new 应返回 JSString 对象（Rhino 实例化语义），实际: {out}"
        );
        assert_eq!(
            v["kLen"], 16,
            "k.length() 应可调用且 bytes[0..16) 经 UTF-8 解码为 16 字符，实际: {out}"
        );
        assert_eq!(
            v["digestType"], "object",
            "java.digestHex 应返回 JSString 对象（Java String 方法面），实际: {out}"
        );
        assert_eq!(
            v["digestLen"], 64,
            "digest.length() 应为 64（SHA-256 hex 位长），实际: {out}"
        );
        let digest = v["digest"]
            .as_str()
            .expect("String(digest) 强转应得摘要字符串: {out}");
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
/// 形态统一改动误伤 new 调用路径。
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
