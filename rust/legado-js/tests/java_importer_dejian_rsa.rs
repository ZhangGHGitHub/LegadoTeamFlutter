//! 得间免费小说 jsLib（JavaImporter + java.security RSA 签名面）e2e 回归测试
//!
//! 根因（取证定稿）：得间 jsLib 用 Rhino `JavaImporter` 语法做 RSA 签名——
//! `new JavaImporter()` 零参构造后 `importPackage(Packages.java.lang,
//! Packages.java.security, Packages.java.security.spec, Packages.java.util)`，
//! 再在 `with (javaImport)` 作用域内走
//! `PKCS8EncodedKeySpec(Base64.getDecoder().decode(privateKey))` →
//! `KeyFactory.getInstance("RSA").generatePrivate(spec)` →
//! `Signature.getInstance("SHA1WithRSA")` `initSign/update/sign` →
//! `Base64.getEncoder().encodeToString`。本引擎的 Packages 模拟层
//! （`rust/legado-js/src/host_api/quickjs_impl.rs` `inject_packages_shim`）此前
//! 无 `JavaImporter` 全局、`java.security` 仅有 `MessageDigest`、
//! `java.util` 无 `Base64`、`java.security.spec` 整包缺失——`new
//! JavaImporter()` 直接 `not a function`，jsLib 加载即失败，得间搜索/发现
//! 规则整条不可用。
//!
//! 本批次修复面（全在 Packages 模拟层，加密计算零重实现）：
//! - `JavaImporter` 全局构造器：零参不抛错；`new JavaImporter(pkg1, …)` 与
//!   `importPackage(...)` 变参均把各包**直接类成员**（自身可枚举属性）合并
//!   进 importer（同名先注册者胜）；`with (javaImport)` 即对合并集做作用域
//!   解析。**不预挂载** Packages.java 各面——得间 jsLib 构造后立即
//!   importPackage（Rhino 语义：合并前类名不可解析），预挂载会使其形同虚设；
//! - `java.security.spec.PKCS8EncodedKeySpec(bytes)`：语料中不带 `new` 直接
//!   调用，普通函数返回 `{ encode() }`（取回 PKCS#8 DER 字节，toU8 拷贝）；
//! - `java.security.KeyFactory`：`getInstance` 仅接受 "RSA"（非 RSA →
//!   登记符号 + 可读文案）；`generatePrivate(spec)` 取 `spec.encode()` 转
//!   Base64 字符串（`parse_private_key` 可解析的 PKCS#8 DER）；
//! - `java.security.Signature`：`getInstance` 提前经宿主 `java.createSign`
//!   做算法预校验（未知算法即抛可读错误）；`initSign` 存密钥、`update`
//!   累积、`sign()` 一次性委托 `createSign`（asymmetric_crypto PKCS#1 v1.5
//!   确定性签名）输出 Uint8Array；
//! - `java.util.Base64`：`getDecoder().decode(str)` 委托宿主
//!   `java.base64DecodeToByteArray`（空白输入 → null，归一为空字节序列不
//!   中断脚本）；`getEncoder().encodeToString(bytes)` 委托宿主
//!   `java.base64EncodeBytes`（与 android.util.Base64 面同一宿主函数）。
//!
//! 密钥：本文件硬编码的 1024 位测试密钥对为 2026-09-26 经本仓库
//! `asymmetric_crypto::generate_test_keypair_b64()` 自生成（PKCS#8 私有
//! / SPKI 公钥，Base64 DER）；**刻意不复用取证文件中得间源的私钥**——
//! 回归测试不得固化任何真实源密钥。

#![cfg(feature = "quickjs")]

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;

use legado_js::engine::{JsEngine, JsValue};
use legado_js::host_api::asymmetric_crypto::{parse_public_key, rsa_verify, SignAlgo};
use legado_js::host_api::current_source;
use legado_js::sandbox::SandboxConfig;
use legado_js::QuickJsEngine;

/// 固定测试私钥（PKCS#8 DER，Base64）——自生成，非真实源密钥
const TEST_PRIV_B64: &str = "MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAKq54k9Yuq+XhYi6aG0AReMvTfzenktZF94Xh+7C9TuutMbz/1NzsbpvHyD7MbMdY8/W9h8HC3yWLiCwr3z7A8sf80VyFF+xk+fNKdkqGfVEzl+TXSEBzJt2egOqCz2sw5JMZMdl1NJrjgjvHyw9VALDcKNTNHxAS3WC4dZgsvWvAgMBAAECgYAqBupMCBakxRMNLn4oXwnVPD7hgdfLypnShU5kG0ANOhusYkI3Q+K7d0FdeBiq9BAvCMa7qptMRxgB2hzJEm3DOuMXcYRjeNcCDFaAtqC+mLNmxEUNy1QTsjQZtFbVI8+daFaX/L2BugegVGnYIiQy2dSazpoMBlFODrnk/1LBIQJBAMLvJtSx+qRLY0HlsEhOISgJEwgzaUlIiuex2jss4Dhkg1y1jRNoV5NBVwBh5CHT1SryMfp8/LnaqLmO8eNCqV8CQQDgNVphV5a3JMTJ114Bns6ljcDUijXl1lMShaTtcJ0bbz2Glw44H1p/SjKzmKIw2pg6lEyDb58g7VvKCeNH0wWxAkEAp3QdXVVOxFfmejM/jb1gCi5RZRgU99kTShmkKHVSX98oYTmsaOGXaW4VuMRe3xhD5FKN0GoSB+3oRw6eh+U57QJAdJZp1Bp2ze95wTeTs6X/8QjAUAU6t7R2aDhEpg+cMqrqxHUCON7c8ToFGWzyUhMpe7SoAOTnS3kB9RKlNDEgUQJABkD6nzg1Wca9GyhmjtEsd+jgz0Gjcdkf7QON6A8VR/U7g0ox+Hg0OIQ67BPk0XAs+ANks1CsT+lWwv3CAkq1TA==";

/// 固定测试公钥（SPKI DER，Base64）——与 TEST_PRIV_B64 同对
const TEST_PUB_B64: &str = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCqueJPWLqvl4WIumhtAEXjL0383p5LWRfeF4fuwvU7rrTG8/9Tc7G6bx8g+zGzHWPP1vYfBwt8li4gsK98+wPLH/NFchRfsZPnzSnZKhn1RM5fk10hAcybdnoDqgs9rMOSTGTHZdTSa44I7x8sPVQCw3CjUzR8QEt1guHWYLL1rwIDAQAB";

/// 签名载荷（ASCII，UTF-8 字节即其本身）
const PAYLOAD: &str = "timestamp=1700000000&usr=12345";

/// 与生产 `QuickJsExecutor` fresh 路径同源的引擎配置
fn production_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("生产同源引擎创建失败")
}

/// 绿态：零参 `JavaImporter` + `importPackage` 四包合并 + `with` 作用域内
/// PKCS8EncodedKeySpec → KeyFactory → Signature → Base64 全流（得间 jsLib
/// `sign(p)` 同款结构，仅私钥换成自生成测试密钥）：
/// - 签名输出为合法 Base64（1024 位密钥 → 128 字节签名 → 172 字符）；
/// - PKCS#1 v1.5 确定性：同载荷两次签名逐字节一致；
/// - Rust 侧 `parse_public_key` + `rsa_verify(SHA1WithRSA)` 复核通过，
///   篡改数据验签必失败（防 shim 输出非真实签名值的假绿）。
#[test]
fn java_importer_with_scope_rsa_sign_full_flow() {
    let engine = production_engine();
    let script = r#"
(function () {
  var javaImport = new JavaImporter();
  javaImport.importPackage(
    Packages.java.lang,
    Packages.java.security,
    Packages.java.security.spec,
    Packages.java.util
  );
  function sign(p) {
    with (javaImport) {
      var priPKCS8 = PKCS8EncodedKeySpec(Base64.getDecoder().decode(privKey));
      var keyf = KeyFactory.getInstance("RSA");
      var priKey = keyf.generatePrivate(priPKCS8);
      var signature = Signature.getInstance("SHA1WithRSA");
      signature.initSign(priKey);
      signature.update(new String(p).getBytes("UTF-8"));
      return Base64.getEncoder().encodeToString(signature.sign());
    }
  }
  var s1 = sign(payload);
  var s2 = sign(payload);
  return JSON.stringify({ s1: s1, s2: s2, same: (s1 === s2), len: s1.length });
})()
"#;
    current_source::with_current_source_tag("e2e.java_importer.dejian.full_flow", || {
        let out: String = JsEngine::eval_with_bindings(
            &engine,
            script,
            &[
                ("privKey", JsValue::String(TEST_PRIV_B64.to_string())),
                ("payload", JsValue::String(PAYLOAD.to_string())),
            ],
        )
        .expect("得间全流脚本执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        let s1 = v["s1"].as_str().expect("s1 应为字符串: {out}");
        assert_eq!(
            v["same"], true,
            "PKCS#1 v1.5 签名应确定性（同载荷两次一致）; 观测: {out}"
        );
        let sig_bytes = STANDARD
            .decode(s1)
            .expect("sign() 输出应为合法 Base64: {s1}");
        assert_eq!(
            sig_bytes.len(),
            128,
            "1024 位密钥签名应为 128 字节; 观测: {out}"
        );
        assert_eq!(s1.len(), 172, "128 字节 Base64 应为 172 字符; 观测: {out}");
        // Rust 侧复核：公钥验签通过 + 篡改数据必失败
        let pub_key = parse_public_key(TEST_PUB_B64).expect("测试公钥解析应成功");
        assert!(
            rsa_verify(SignAlgo::Sha1, &pub_key, PAYLOAD.as_bytes(), &sig_bytes),
            "Rust 侧 rsa_verify(SHA1WithRSA) 应通过: {out}"
        );
        assert!(
            !rsa_verify(SignAlgo::Sha1, &pub_key, b"tampered", &sig_bytes),
            "篡改数据验签必须失败（防假绿）"
        );
    });
}

/// 绿态：`new JavaImporter()` 零参不抛错；`new JavaImporter(pkg1, …)` 构造
/// 参数即合并；`importPackage(...)` 可链式追加包；合并后可解析类名（String /
/// Base64 / KeyFactory / Signature 均命中）。
#[test]
fn java_importer_zero_arg_and_ctor_args_forms() {
    let engine = production_engine();
    let script = r#"
(function () {
  var a = new JavaImporter();
  var b = new JavaImporter(Packages.java.lang, Packages.java.util);
  b.importPackage(Packages.java.security);
  return JSON.stringify({
    aType: typeof a,
    aHasImportPackage: (typeof a.importPackage === 'function'),
    bStringIsFn: (typeof b.String === 'function'),
    bBase64IsObj: (typeof b.Base64 === 'object' && typeof b.Base64.getDecoder === 'function'),
    bKeyFactory: (typeof b.KeyFactory === 'object' && typeof b.KeyFactory.getInstance === 'function'),
    bSignature: (typeof b.Signature === 'object' && typeof b.Signature.getInstance === 'function')
  });
})()
"#;
    current_source::with_current_source_tag("e2e.java_importer.dejian.forms", || {
        let out: String = JsEngine::eval(&engine, script).expect("JavaImporter 形态用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["aType"], "object",
            "零参 new JavaImporter() 不得抛错; 观测: {out}"
        );
        assert_eq!(
            v["aHasImportPackage"], true,
            "importer 应自带 importPackage 变参方法; 观测: {out}"
        );
        assert_eq!(
            v["bStringIsFn"], true,
            "构造参数合并后 java.lang.String 应可解析; 观测: {out}"
        );
        assert_eq!(
            v["bBase64IsObj"], true,
            "java.util.Base64 面应可解析; 观测: {out}"
        );
        assert_eq!(
            v["bKeyFactory"], true,
            "importPackage 链式追加后 java.security.KeyFactory 应可解析; 观测: {out}"
        );
        assert_eq!(
            v["bSignature"], true,
            "importPackage 链式追加后 java.security.Signature 应可解析; 观测: {out}"
        );
    });
}

/// 绿态：`java.util.Base64` getDecoder/getEncoder 面——decode('aGVsbG8=')
/// 还原 'hello' 字节、encodeToString 往返一致、空白输入归一为空字节序列
/// （宿主 null 语义不中断脚本）。
#[test]
fn java_util_base64_decoder_encoder_face() {
    let engine = production_engine();
    let script = r#"
(function () {
  var b64 = Packages.java.util.Base64;
  var bytes = b64.getDecoder().decode('aGVsbG8=');
  var round = b64.getEncoder().encodeToString(bytes);
  var empty = b64.getDecoder().decode('');
  var hello = new Uint8Array([104, 101, 108, 108, 111]);
  var ok = (bytes.length === hello.length);
  if (ok) {
    for (var i = 0; i < hello.length; i++) {
      if (bytes[i] !== hello[i]) { ok = false; break; }
    }
  }
  return JSON.stringify({
    round: round,
    bytesLen: bytes.length,
    bytesOk: ok,
    emptyLen: empty.length,
    emptyIsU8: (empty instanceof Uint8Array)
  });
})()
"#;
    current_source::with_current_source_tag("e2e.java_importer.dejian.base64", || {
        let out: String = JsEngine::eval(&engine, script).expect("java.util.Base64 用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["bytesLen"], 5,
            "decode('aGVsbG8=') 应为 5 字节; 观测: {out}"
        );
        assert_eq!(v["bytesOk"], true, "字节应还原 'hello'; 观测: {out}");
        assert_eq!(
            v["round"], "aGVsbG8=",
            "encodeToString 往返应一致; 观测: {out}"
        );
        assert_eq!(v["emptyLen"], 0, "空白输入应归一为空字节序列; 观测: {out}");
        assert_eq!(
            v["emptyIsU8"], true,
            "空输入返回值仍是 Uint8Array 实例; 观测: {out}"
        );
    });
}

/// 绿态（错误路径可读性）：非 RSA 算法 `KeyFactory.getInstance` → 登记 +
/// 可读文案；未 `initSign` 直接 `sign()` → 提示先 initSign；`generatePrivate`
/// 收到无 `encode()` 的 spec → 提示参数形态。三条均为可捕获 JS 异常（书源
/// try/catch 可降级），文案含定位信息。
#[test]
fn key_factory_and_signature_error_paths() {
    let engine = production_engine();
    let script = r#"
(function () {
  var r = { badAlgo: false, noKey: false, badSpec: false };
  try {
    Packages.java.security.KeyFactory.getInstance('EC');
  } catch (e) { r.badAlgo = String(e).indexOf('当前不支持') >= 0; }
  try {
    Packages.java.security.Signature.getInstance('SHA1WithRSA').sign();
  } catch (e) { r.noKey = String(e).indexOf('initSign') >= 0; }
  try {
    Packages.java.security.KeyFactory.getInstance('RSA').generatePrivate({ encode: null });
  } catch (e) { r.badSpec = String(e).indexOf('encode()') >= 0; }
  return JSON.stringify(r);
})()
"#;
    current_source::with_current_source_tag("e2e.java_importer.dejian.errors", || {
        let out: String = JsEngine::eval(&engine, script).expect("错误路径用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["badAlgo"], true,
            "非 RSA 算法应登记符号并抛可读文案; 观测: {out}"
        );
        assert_eq!(
            v["noKey"], true,
            "未 initSign 的 sign() 应提示先 initSign; 观测: {out}"
        );
        assert_eq!(
            v["badSpec"], true,
            "非法 spec 应提示须带 encode() 方法; 观测: {out}"
        );
    });
}
