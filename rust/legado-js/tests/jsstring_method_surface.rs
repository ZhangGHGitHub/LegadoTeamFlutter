//! JSString 对象 Java String 方法面 e2e 回归测试（2026-09-26 小小阅读×3
//! jsLib 第二层根因：Rhino `javaPrimitiveWrap` 默认 true——Kotlin
//! `digestHex(...): String` 返回值在 Rhino 里被 WrapFactory 包为
//! NativeJavaObject，带 Java String 方法面；`.length()` / `.substring()` /
//! `.getBytes()` 可调。我方宿主绑定 `digestHex`/`md5Encode` 此前返回 JS
//! 原始串 → 验收实测 `not a function (at decode (<input>:68:20))`。
//!
//! 双基准裁定依据：`.tmp/crosscheck_20260927/verdict.md`（引擎缺口）；
//! jsLib 实证链（`.tmp/crosscheck_20260927/ref_xiaoxiao_source_def.txt`
//! 全量 jsLib 逐一核对，方法面最小充分集 = length/substring/charAt/
//! indexOf/equals/isEmpty/getBytes + toString/valueOf/toJSON 三条
//! coercion 路径）：
//! - L68 `length = k.length()`（`k = java.digestHex(k, 'sha-256')` 结果）
//! - L72 `k.substring(i, i3)`（`Integer.parseInt` 取 2 位 hex）
//! - L83 `bytes = i.getBytes()` / L84 `bytes2 = v.getBytes()`
//!   （`i = String(...)` 无 new 普通调用 / `v = java.md5Encode(i)` 结果）
//!
//! 修复方案（`rust/legado-js/src/host_api/quickjs_impl.rs`，仅 JS 层，
//! Rust 侧 `digest_hex`/`md5_encode` 不动）：
//! 1. `JSString` 构造器补 Java String 方法面（含双形态 `length`：
//!    可调用函数 + 自带 valueOf/toString，调用形与数值强转形均可用）；
//! 2. `JavaString`（`Packages.java.lang.String` 模拟）两种调用形态一律
//!    返回 JSString 对象；
//! 3. shim 尾部以 JS 包装替换 `java.digestHex` / `java.md5Encode` /
//!    `java.md5Encode16` 绑定：入参先 `String()` 强转、返回值统一
//!    `JSString` 包装（裸全局镜像保持原始串语义，engine.rs 既有断言钉住）。
//!
//! 本文件覆盖：
//! 1. 方法面逐一断言（`new Packages.java.lang.String('hello world')`）；
//! 2. `java.digestHex` 返回 JSString 对象（length() 可调用 = 64、
//!    String() 取回内容、substring、拼接/JSON.stringify coercion、
//!    与 Rust 侧 sha256 逐字一致）；
//! 3. `java.md5Encode` / `java.md5Encode16` 返回 JSString 对象
//!    （getBytes 字节面、substring(8,24) 对齐 md5Encode16 截取语义、
//!    与 Rust 侧 md5 逐字一致）;
//! 4. 小小阅读 jsLib `decode` 全链复刻：Rust 侧按 jsLib 密钥/IV 推导
//!    规则构造 AES-CBC/PKCS5Padding 密文载荷（首 16 字节盐 → sha256
//!    取密钥；尾 16 字节 → md5 十六进制串 ASCII 字节异或取 IV），
//!    JS 侧 verbatim 运行 jsLib decode 全链（base64DecodeToByteArray →
//!    copyOfRange → String(bytes) → digestHex → substring/parseInt →
//!    md5Encode → getBytes → SecretKeySpec/IvParameterSpec →
//!    Cipher.doFinal），断言明文逐字还原。

#![cfg(feature = "quickjs")]

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use hex::encode as hex_encode;
use legado_js::engine::JsEngine;
use legado_js::host_api::current_source;
use legado_js::sandbox::SandboxConfig;
use legado_js::QuickJsEngine;
use md5::Md5;
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

/// 契约 1：JSString 对象 Java String 方法面逐一断言。
/// `new Packages.java.lang.String('hello world')` 返回的 JSString 对象
/// 须支持 jsLib 语料全量核对出的最小充分集：
/// `length()`（调用形）/ 数值强转形（valueOf）/ 字符串强转形
/// （toString）/ `substring` / `charAt` / `indexOf` / `equals`
/// （null → false，对齐 Java 语义）/ `isEmpty` / `getBytes` /
/// `String()` / `valueOf` / `JSON.stringify`（toJSON）/ 拼接 coercion。
#[test]
fn jsstring_method_surface() {
    let engine = production_engine();
    let script = r#"
(function () {
  var o = new Packages.java.lang.String('hello world');
  var e = new Packages.java.lang.String('');
  return JSON.stringify({
    lenCall: o.length(),
    lenNum: o.length * 2,
    lenStr: '[' + o.length + ']',
    sub5: o.substring(0, 5),
    subRest: o.substring(6),
    subTwo: o.substring(2, 4),
    char0: o.charAt(0),
    idxWorld: o.indexOf('world'),
    idxMiss: o.indexOf('zzz'),
    eqSelf: o.equals('hello world'),
    eqOther: o.equals('bye'),
    eqNull: o.equals(null),
    eqUndef: o.equals(undefined),
    eqNum: o.equals(42),
    isEmpty: o.isEmpty(),
    emptyIsEmpty: e.isEmpty(),
    emptyLen: e.length(),
    str: String(o),
    valOf: o.valueOf(),
    concat: 'x' + o,
    json: JSON.stringify(o),
    bytesLen: o.getBytes('UTF-8').length
  });
})()
"#;
    current_source::with_current_source_tag("e2e.jsstring.method_surface", || {
        let out: String = JsEngine::eval(&engine, script).expect("方法面用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(v["lenCall"], 11, "length() 调用形应返回 11; 实际: {out}");
        assert_eq!(
            v["lenNum"], 22,
            "数值上下文（length * 2）应经 valueOf 强转; 实际: {out}"
        );
        assert_eq!(
            v["lenStr"], "[11]",
            "字符串上下文应经 toString 强转; 实际: {out}"
        );
        assert_eq!(v["sub5"], "hello", "substring(0,5); 实际: {out}");
        assert_eq!(
            v["subRest"], "world",
            "substring(6) 省略 end 应到串尾; 实际: {out}"
        );
        assert_eq!(v["subTwo"], "ll", "substring(2,4); 实际: {out}");
        assert_eq!(v["char0"], "h", "charAt(0); 实际: {out}");
        assert_eq!(v["idxWorld"], 6, "indexOf('world') === 6; 实际: {out}");
        assert_eq!(v["idxMiss"], -1, "未命中 indexOf 应 -1; 实际: {out}");
        assert_eq!(v["eqSelf"], true, "equals 同内容应 true; 实际: {out}");
        assert_eq!(v["eqOther"], false, "equals 异内容应 false; 实际: {out}");
        assert_eq!(
            v["eqNull"], false,
            "Java String.equals(null) === false（非 JS 强转语义）; 实际: {out}"
        );
        assert_eq!(
            v["eqUndef"], false,
            "equals(undefined) 应 false; 实际: {out}"
        );
        assert_eq!(
            v["eqNum"], false,
            "equals(42) 经 String 强转比较应 false; 实际: {out}"
        );
        assert_eq!(v["isEmpty"], false, "非空 isEmpty 应 false; 实际: {out}");
        assert_eq!(v["emptyIsEmpty"], true, "空串 isEmpty 应 true; 实际: {out}");
        assert_eq!(v["emptyLen"], 0, "空串 length() 应 0; 实际: {out}");
        assert_eq!(
            v["str"], "hello world",
            "String(对象) 应取回内容; 实际: {out}"
        );
        assert_eq!(v["valOf"], "hello world", "valueOf 应取回内容; 实际: {out}");
        assert_eq!(
            v["concat"], "xhello world",
            "拼接 coercion 应得内容; 实际: {out}"
        );
        assert_eq!(
            v["json"], "\"hello world\"",
            "JSON.stringify 经 toJSON 应得带引号 JSON 串; 实际: {out}"
        );
        assert_eq!(
            v["bytesLen"], 11,
            "getBytes('UTF-8') 应 11 字节; 实际: {out}"
        );
    });
}

/// 契约 2：`java.digestHex(data, 'sha-256')` 返回 JSString **对象**
/// （Rhino NativeJavaObject 对齐）——`length()` 可调用 = 64（jsLib L68
/// 形态）、`String()` 取回摘要且与 Rust 侧 sha256 逐字一致（防假绿）、
/// `substring` 可调用、URL 模板拼接 / `JSON.stringify` 两条 coercion
/// 路径均取回内容。
#[test]
fn java_digest_hex_returns_jsstring_object() {
    let engine = production_engine();
    let expected_hex = hex_encode(Sha256::digest(b"hello"));
    let script = r#"
(function () {
  var d = java.digestHex('hello', 'sha-256');
  return JSON.stringify({
    dType: typeof d,
    len: d.length(),
    val: String(d),
    sub8: d.substring(0, 8),
    url: 'https://x.com/t?k=' + d,
    json: JSON.stringify(d),
    isEmpty: d.isEmpty()
  });
})()
"#;
    current_source::with_current_source_tag("e2e.jsstring.digest_hex", || {
        let out: String = JsEngine::eval(&engine, script).expect("digestHex 用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["dType"], "object",
            "java.digestHex 应返回 JSString 对象（Java String 方法面），实际: {out}"
        );
        assert_eq!(
            v["len"], 64,
            "digest.length() 应为 64（SHA-256 hex 位长）; 实际: {out}"
        );
        assert_eq!(
            v["val"], expected_hex,
            "String(digest) 应与 Rust 侧 sha256('hello') 逐字一致; 实际: {out}"
        );
        assert_eq!(
            v["sub8"],
            &expected_hex[..8],
            "digest.substring(0,8) 应取前 8 位; 实际: {out}"
        );
        assert_eq!(
            v["url"],
            format!("https://x.com/t?k={expected_hex}"),
            "URL 模板拼接（toString/valueOf coercion）应取回内容; 实际: {out}"
        );
        assert_eq!(
            v["json"],
            format!("\"{expected_hex}\""),
            "JSON.stringify 经 toJSON 应得带引号 JSON 串; 实际: {out}"
        );
        assert_eq!(
            v["isEmpty"], false,
            "摘要非空 isEmpty 应 false; 实际: {out}"
        );
    });
}

/// 契约 3：`java.md5Encode` / `java.md5Encode16` 返回 JSString **对象**
/// ——`getBytes()` 字节面可调用（jsLib L84 `bytes2 = v.getBytes()` 形态，
/// 取十六进制串 ASCII 字节）、`substring(8, 24)` 对齐 md5Encode16 截取
/// 语义、内容与 Rust 侧 md5 逐字一致。
#[test]
fn java_md5_encode_returns_jsstring_object() {
    let engine = production_engine();
    let md5_hex = hex_encode(Md5::digest(b"hello"));
    let script = r#"
(function () {
  var m = java.md5Encode('hello');
  var m16 = java.md5Encode16('hello');
  return JSON.stringify({
    mType: typeof m,
    mLen: m.length(),
    mVal: String(m),
    mBytesLen: m.getBytes('UTF-8').length,
    mMid: m.substring(8, 24),
    m16Type: typeof m16,
    m16Val: String(m16)
  });
})()
"#;
    current_source::with_current_source_tag("e2e.jsstring.md5_encode", || {
        let out: String = JsEngine::eval(&engine, script).expect("md5Encode 用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["mType"], "object",
            "java.md5Encode 应返回 JSString 对象; 实际: {out}"
        );
        assert_eq!(v["mLen"], 32, "md5.length() 应为 32; 实际: {out}");
        assert_eq!(
            v["mVal"], md5_hex,
            "String(md5) 应与 Rust 侧 md5('hello') 逐字一致; 实际: {out}"
        );
        assert_eq!(
            v["mBytesLen"], 32,
            "getBytes('UTF-8') 应 32 字节（hex 串 ASCII）; 实际: {out}"
        );
        assert_eq!(
            v["mMid"], "bc4b2a76b9719d91",
            "substring(8,24) 应对齐 md5Encode16 截取语义; 实际: {out}"
        );
        assert_eq!(
            v["m16Type"], "object",
            "java.md5Encode16 应返回 JSString 对象; 实际: {out}"
        );
        assert_eq!(
            v["m16Val"], "bc4b2a76b9719d91",
            "String(md5Encode16) 应为 16 位中段; 实际: {out}"
        );
    });
}

/// 契约 4（小小阅读 jsLib `decode` 全链复刻）：
///
/// Rust 侧按 jsLib 密钥/IV 推导规则构造密文载荷：
/// - 首 16 字节盐 `FIRST16`：`k = String(盐)`（ASCII 无损）→
///   `java.digestHex(k, 'sha-256')` → 32 字节 AES 密钥
///   = `sha256(FIRST16)`（ASCII ⇒ 字节即字符串 UTF-8）
/// - 尾 16 字节 `LAST16`：`i = String(尾)` → `v = java.md5Encode(i)`
///   （十六进制串）→ jsLib IV 推导 `ivs[j] = (bytes2[j] ^ bytes[j]) ^ (-1)`
///   即 `iv[j] = 255 - (md5hex_ascii[j] ^ LAST16[j])`（mod 256 无符号化）
/// - 载荷 = `base64(FIRST16 || AES-CBC/PKCS5Padding 密文 || LAST16)`
///
/// JS 侧 verbatim 运行 jsLib decode 全链（含 `JavaImporter` +
/// `with` 作用域污染、无 new `String(bytes)` 普通调用、`k.length()` /
/// `k.substring` / `i.getBytes()` / `v.getBytes()` 全部 Java String
/// 方法面形态），断言明文逐字还原——即验收标准「decode 全程跑通」。
#[test]
fn xiaoxiao_decode_chain_full_replica() {
    let engine = production_engine();

    // —— Rust 侧按 jsLib 规则构造密文载荷 ——
    const FIRST16: [u8; 16] = *b"ABCDEFGHIJKLMNOP";
    const LAST16: [u8; 16] = *b"QRSTUVWXYZqstuvw";
    let plaintext = r#"{"name":"重生高考前","url":"https://example.com/book/1","author":"作者"}"#;

    // 密钥：sha256(首 16 字节 ASCII 串)（jsLib：String(盐) → digestHex sha-256）
    let key: [u8; 32] = Sha256::digest(FIRST16).into();

    // IV：jsLib `i = String(尾 16 字节)` → `v = java.md5Encode(i)`（十六进制
    // 串）→ `bytes2 = v.getBytes()`（hex 串 ASCII 字节）与 `bytes =
    // i.getBytes()`（尾 16 字节 ASCII）逐位 `^ (-1)` 取按位补码
    let i_str = String::from_utf8(LAST16.to_vec()).expect("LAST16 为 ASCII");
    let md5_hex = hex_encode(Md5::digest(i_str.as_bytes()));
    assert_eq!(md5_hex.len(), 32, "md5 十六进制串应为 32 位");
    let iv: [u8; 16] = std::array::from_fn(|j| 255u8 - (md5_hex.as_bytes()[j] ^ LAST16[j]));

    // 密文：AES-CBC/PKCS5Padding（与 Cipher.doFinal 解密侧 symmetric_decrypt 对偶）
    let cipher = legado_core::crypto::symmetric_encrypt(
        "AES/CBC/PKCS5Padding",
        &key,
        Some(&iv),
        plaintext.as_bytes(),
    )
    .expect("AES-CBC 加密应成功");
    let mut payload = Vec::new();
    payload.extend_from_slice(&FIRST16);
    payload.extend_from_slice(&cipher);
    payload.extend_from_slice(&LAST16);
    let b64 = STANDARD.encode(&payload);

    // —— JS 侧 verbatim 运行 jsLib decode 全链（jsLib 原文结构）——
    let script = format!(
        r#"
(function () {{
  var javaImport = new JavaImporter();
  javaImport.importPackage(
    Packages.java.lang,
    Packages.javax.crypto.spec,
    Packages.javax.crypto,
    Packages.java.util,
    Packages.java.io
  );
  var decode;
  with (javaImport) {{
    decode = function decode(str) {{
      data = java.base64DecodeToByteArray(str);
      datas = Arrays.copyOfRange(data, 16, data.length - 16);
      k = String(Arrays.copyOfRange(data, 0, 16));
      k = java.digestHex(k, 'sha-256');
      ks = [];
      length = k.length();
      if (length % 2 == 1) {{ length++; k = '0' + k; }}
      i = 0; i2 = 0;
      while (i < length) {{
        i3 = i + 2;
        ks[i2] = intToByte(Integer.parseInt(k.substring(i, i3), 16));
        i2++;
        i = i3;
      }}
      i = String(Arrays.copyOfRange(data, data.length - 16, data.length));
      v = java.md5Encode(i);
      bytes = i.getBytes();
      bytes2 = v.getBytes();
      ivs = [];
      for (i = 0; i < 16; i++) {{ ivs[i] = (bytes2[i] ^ bytes[i]) ^ (-1); }}
      key = SecretKeySpec(ks, 'AES');
      iv = IvParameterSpec(ivs);
      var chipher = Cipher.getInstance('AES/CBC/PKCS5Padding');
      chipher.init(2, key, iv);
      return String(chipher.doFinal(datas));
    }};
  }}
  function intToByte(i) {{
    var b = i & 0xFF;
    var c = 0;
    if (b >= 128) {{ c = b % 128; c = -1 * (128 - c); }} else {{ c = b; }}
    return c;
  }}
  return decode("{b64}");
}})()
"#
    );

    current_source::with_current_source_tag("e2e.jsstring.decode_chain", || {
        let out: String = JsEngine::eval(&engine, &script).expect("jsLib decode 全链复刻执行失败");
        // eval 结果字符串化路径：JSString 对象 → JSON.stringify(toJSON) →
        // 带引号 JSON 串，serde 解一层即得明文
        let recovered: String =
            serde_json::from_str(&out).expect("decode 返回值应能经 JSON 反序列化取回明文: {out}");
        assert_eq!(
            recovered, plaintext,
            "decode 全链（base64 → copyOfRange → String(bytes) → digestHex → \
             parseInt/substring → md5Encode → getBytes → SecretKeySpec/IvParameterSpec \
             → Cipher.doFinal）应逐字还原明文"
        );
    });
}
