//! RSA 非对称加密 / 签名 JS 桥接
//!
//! 对应 Kotlin `JsEncodeUtils.kt` 的 `createAsymmetricCrypto(transformation)` 与
//! `createSign(algorithm)`，即 `io.legado.app.help.crypto.AsymmetricCrypto`
//! 与 `Sign`（底层为 hutool）。
//!
//! JS 用法（对齐 Android 原版）：
//! ```js
//! const rsa = java.createAsymmetricCrypto("RSA/ECB/PKCS1Padding");
//! rsa.setPublicKey(pubKeyB64);
//! const cipher = rsa.encryptBase64("hello");   // 默认公钥加密
//! const plain  = rsa.decryptStr(cipher, false); // false = 使用私钥解密
//!
//! const sign = java.createSign("SHA256withRSA");
//! sign.setPrivateKey(privKeyB64).setPublicKey(pubKeyB64);
//! const sigHex = sign.signHex("data");
//! sign.verify("data", sigHex);                 // -> true
//! ```
//!
//! 密钥格式：支持 PEM（PKCS#1 / PKCS#8 / X.509 SPKI）与 Base64 DER，
//! 与 hutool `KeyUtil.generatePublicKey/generatePrivateKey` 的接受范围对齐。

use std::cell::RefCell;
use std::rc::Rc;

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use rsa::pkcs1v15::{Signature as RsaSignature, SigningKey, VerifyingKey};
use rsa::traits::PublicKeyParts;
use rsa::{Oaep, Pkcs1v15Encrypt, RsaPrivateKey, RsaPublicKey};
use sha2::Digest;
use signature::hazmat::{PrehashSigner, PrehashVerifier};
use signature::SignatureEncoding;

// ---------------------------------------------------------------------------
// 填充模式解析（对齐 Java transformation）
// ---------------------------------------------------------------------------

/// RSA 填充模式
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RsaPadding {
    /// RSA/ECB/PKCS1Padding（Java 默认，块大小 k-11）
    Pkcs1v15,
    /// RSA/ECB/OAEPWithSHA-1AndMGF1Padding（块大小 k-42）
    OaepSha1,
    /// RSA/ECB/OAEPWithSHA-256AndMGF1Padding（块大小 k-66）
    OaepSha256,
}

/// 解析 RSA transformation，如 "RSA"、"RSA/ECB/PKCS1Padding"、
/// "RSA/ECB/OAEPWithSHA-256AndMGF1Padding"。
///
/// 中间段（ECB/None）对 RSA 无意义，直接忽略（Java 同样如此）。
pub fn parse_rsa_transformation(transformation: &str) -> Result<RsaPadding, String> {
    let parts: Vec<&str> = transformation.split('/').map(|s| s.trim()).collect();
    let algo = parts.first().copied().unwrap_or("");
    if !algo.eq_ignore_ascii_case("RSA") {
        return Err(format!(
            "Unsupported asymmetric algorithm: {} (only RSA supported)",
            algo
        ));
    }
    let padding_part = parts
        .get(2)
        .map(|s| s.to_ascii_uppercase())
        .unwrap_or_default();
    if padding_part.is_empty() || padding_part == "PKCS1PADDING" {
        return Ok(RsaPadding::Pkcs1v15);
    }
    if padding_part.starts_with("OAEP") {
        if padding_part.contains("SHA-256") || padding_part.contains("SHA256") {
            return Ok(RsaPadding::OaepSha256);
        }
        if padding_part.contains("SHA-384")
            || padding_part.contains("SHA384")
            || padding_part.contains("SHA-512")
            || padding_part.contains("SHA512")
        {
            return Err(format!(
                "Unsupported OAEP hash in transformation: {}",
                padding_part
            ));
        }
        // OAEPWithSHA-1AndMGF1Padding 及裸 OAEP 默认 SHA-1
        return Ok(RsaPadding::OaepSha1);
    }
    Err(format!("Unsupported RSA padding: {}", padding_part))
}

// ---------------------------------------------------------------------------
// 密钥解析（PEM / Base64 DER）
// ---------------------------------------------------------------------------

/// 宽松的 Base64 解码：去除空白并自动补齐填充
fn b64_decode_lenient(s: &str) -> Result<Vec<u8>, String> {
    let cleaned: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    if cleaned.is_empty() {
        return Err("Empty key data".to_string());
    }
    let pad = (4 - cleaned.len() % 4) % 4;
    let padded = format!("{}{}", cleaned, "=".repeat(pad));
    B64.decode(&padded).map_err(|e| format!("Invalid Base64 key data: {}", e))
}

/// 解析 RSA 公钥：支持 PEM（X.509 SPKI / PKCS#1）与 Base64 DER
pub fn parse_public_key(key: &str) -> Result<RsaPublicKey, String> {
    use rsa::pkcs1::DecodeRsaPublicKey;
    use rsa::pkcs8::DecodePublicKey;

    let trimmed = key.trim();
    if trimmed.contains("-----BEGIN") {
        if trimmed.contains("BEGIN PUBLIC KEY") {
            return RsaPublicKey::from_public_key_pem(trimmed)
                .map_err(|e| format!("Failed to parse PEM public key: {}", e));
        }
        if trimmed.contains("BEGIN RSA PUBLIC KEY") {
            return RsaPublicKey::from_pkcs1_pem(trimmed)
                .map_err(|e| format!("Failed to parse PKCS#1 PEM public key: {}", e));
        }
        return Err("Unrecognized PEM public key format".to_string());
    }
    let der = b64_decode_lenient(trimmed)?;
    if let Ok(pk) = RsaPublicKey::from_public_key_der(&der) {
        return Ok(pk);
    }
    RsaPublicKey::from_pkcs1_der(&der).map_err(|e| {
        format!(
            "Cannot parse public key (X.509/PKCS#1 DER or PEM required): {}",
            e
        )
    })
}

/// 解析 RSA 私钥：支持 PEM（PKCS#8 / PKCS#1）与 Base64 DER
pub fn parse_private_key(key: &str) -> Result<RsaPrivateKey, String> {
    use rsa::pkcs1::DecodeRsaPrivateKey;
    use rsa::pkcs8::DecodePrivateKey;

    let trimmed = key.trim();
    if trimmed.contains("-----BEGIN") {
        if trimmed.contains("BEGIN RSA PRIVATE KEY") {
            return RsaPrivateKey::from_pkcs1_pem(trimmed)
                .map_err(|e| format!("Failed to parse PKCS#1 PEM private key: {}", e));
        }
        if trimmed.contains("BEGIN ENCRYPTED PRIVATE KEY") {
            return Err("Encrypted private key is not supported".to_string());
        }
        if trimmed.contains("BEGIN PRIVATE KEY") {
            return RsaPrivateKey::from_pkcs8_pem(trimmed)
                .map_err(|e| format!("Failed to parse PKCS#8 PEM private key: {}", e));
        }
        return Err("Unrecognized PEM private key format".to_string());
    }
    let der = b64_decode_lenient(trimmed)?;
    if let Ok(k) = RsaPrivateKey::from_pkcs8_der(&der) {
        return Ok(k);
    }
    RsaPrivateKey::from_pkcs1_der(&der).map_err(|e| {
        format!(
            "Cannot parse private key (PKCS#8/PKCS#1 DER or PEM required): {}",
            e
        )
    })
}

// ---------------------------------------------------------------------------
// 分段加解密（对齐 hutool 的分块行为）
// ---------------------------------------------------------------------------

/// 公钥分段加密（长数据自动分块，对齐 hutool AsymmetricCrypto.encrypt）
pub fn rsa_encrypt_segmented(
    pub_key: &RsaPublicKey,
    padding: RsaPadding,
    data: &[u8],
) -> Result<Vec<u8>, String> {
    let k = pub_key.size();
    let max_block = max_encrypt_block(k, padding)?;
    let mut rng = rand_core::OsRng;
    let mut out = Vec::with_capacity((data.len() / max_block + 1) * k);
    for chunk in data.chunks(max_block) {
        let enc = match padding {
            RsaPadding::Pkcs1v15 => pub_key.encrypt(&mut rng, Pkcs1v15Encrypt, chunk),
            RsaPadding::OaepSha1 => pub_key.encrypt(&mut rng, Oaep::new::<sha1::Sha1>(), chunk),
            RsaPadding::OaepSha256 => {
                pub_key.encrypt(&mut rng, Oaep::new::<sha2::Sha256>(), chunk)
            }
        }
        .map_err(|e| format!("RSA encrypt failed: {}", e))?;
        out.extend_from_slice(&enc);
    }
    Ok(out)
}

/// 私钥分段解密（密文按模长分块，对齐 hutool AsymmetricCrypto.decrypt）
pub fn rsa_decrypt_segmented(
    priv_key: &RsaPrivateKey,
    padding: RsaPadding,
    data: &[u8],
) -> Result<Vec<u8>, String> {
    let k = priv_key.size();
    if k == 0 || !data.len().is_multiple_of(k) {
        return Err(format!(
            "Ciphertext length {} is not a multiple of RSA key size {}",
            data.len(),
            k
        ));
    }
    let mut out = Vec::new();
    for block in data.chunks(k) {
        let dec = match padding {
            RsaPadding::Pkcs1v15 => priv_key.decrypt(Pkcs1v15Encrypt, block),
            RsaPadding::OaepSha1 => priv_key.decrypt(Oaep::new::<sha1::Sha1>(), block),
            RsaPadding::OaepSha256 => priv_key.decrypt(Oaep::new::<sha2::Sha256>(), block),
        }
        .map_err(|e| format!("RSA decrypt failed: {}", e))?;
        out.extend_from_slice(&dec);
    }
    Ok(out)
}

/// 私钥分段加密（PKCS#1 v1.5 type 1，对齐 Java Cipher 私钥加密行为）。
///
/// OAEP 填充不支持私钥加密（与 Java 一致，直接报错）。
pub fn rsa_private_encrypt_segmented(
    priv_key: &RsaPrivateKey,
    padding: RsaPadding,
    data: &[u8],
) -> Result<Vec<u8>, String> {
    if padding != RsaPadding::Pkcs1v15 {
        return Err("Private key encryption only supports PKCS1Padding".to_string());
    }
    let k = priv_key.size();
    let max_block = k
        .checked_sub(11)
        .ok_or_else(|| "RSA key too small".to_string())?;
    let mut out = Vec::with_capacity((data.len() / max_block + 1) * k);
    for chunk in data.chunks(max_block) {
        let em = build_pkcs1_type1_block(k, chunk)?;
        let m = rsa::BigUint::from_bytes_be(&em);
        let c = rsa::hazmat::rsa_decrypt(None::<&mut rand_core::OsRng>, priv_key, &m)
            .map_err(|e| format!("RSA private encrypt failed: {}", e))?;
        let mut bytes = c.to_bytes_be();
        // 模运算可能丢失前导零，需补齐到模长
        if bytes.len() < k {
            let mut padded = vec![0u8; k - bytes.len()];
            padded.append(&mut bytes);
            bytes = padded;
        }
        out.extend_from_slice(&bytes);
    }
    Ok(out)
}

/// 公钥分段解密（对应私钥加密的密文，type 1 填充）
pub fn rsa_public_decrypt_segmented(
    pub_key: &RsaPublicKey,
    padding: RsaPadding,
    data: &[u8],
) -> Result<Vec<u8>, String> {
    if padding != RsaPadding::Pkcs1v15 {
        return Err("Public key decryption only supports PKCS1Padding".to_string());
    }
    let k = pub_key.size();
    if k == 0 || !data.len().is_multiple_of(k) {
        return Err(format!(
            "Ciphertext length {} is not a multiple of RSA key size {}",
            data.len(),
            k
        ));
    }
    let mut out = Vec::new();
    for block in data.chunks(k) {
        let c = rsa::BigUint::from_bytes_be(block);
        let m = rsa::hazmat::rsa_encrypt(pub_key, &c)
            .map_err(|e| format!("RSA public decrypt failed: {}", e))?;
        let mut em = m.to_bytes_be();
        if em.len() < k {
            let mut padded = vec![0u8; k - em.len()];
            padded.append(&mut em);
            em = padded;
        }
        out.extend_from_slice(&strip_pkcs1_type1_block(&em)?);
    }
    Ok(out)
}

/// 构造 PKCS#1 v1.5 type 1 块：0x00 0x01 [0xFF...] 0x00 [data]
fn build_pkcs1_type1_block(k: usize, data: &[u8]) -> Result<Vec<u8>, String> {
    if data.len() + 11 > k {
        return Err("Data too long for RSA key".to_string());
    }
    let mut em = vec![0u8; k];
    em[1] = 0x01;
    em[2..k - data.len() - 1].fill(0xFF);
    em[k - data.len() - 1] = 0x00;
    em[k - data.len()..].copy_from_slice(data);
    Ok(em)
}

/// 剥离 PKCS#1 v1.5 type 1 填充，返回原始数据
fn strip_pkcs1_type1_block(em: &[u8]) -> Result<Vec<u8>, String> {
    if em.len() < 11 || em[0] != 0x00 || em[1] != 0x01 {
        return Err("Bad PKCS#1 type 1 padding".to_string());
    }
    for (i, b) in em[2..].iter().enumerate() {
        if *b == 0x00 {
            return Ok(em[i + 3..].to_vec());
        }
        if *b != 0xFF {
            return Err("Bad PKCS#1 type 1 padding".to_string());
        }
    }
    Err("Bad PKCS#1 type 1 padding".to_string())
}

/// 加密分块上限（对齐 hutool：PKCS1 = k-11，OAEP-SHA1 = k-42，OAEP-SHA256 = k-66）
fn max_encrypt_block(k: usize, padding: RsaPadding) -> Result<usize, String> {
    let overhead = match padding {
        RsaPadding::Pkcs1v15 => 11,
        RsaPadding::OaepSha1 => 42,
        RsaPadding::OaepSha256 => 66,
    };
    k.checked_sub(overhead)
        .filter(|b| *b > 0)
        .ok_or_else(|| "RSA key too small for selected padding".to_string())
}

// ---------------------------------------------------------------------------
// 签名 / 验签（对齐 hutool Sign）
// ---------------------------------------------------------------------------

/// 签名摘要算法
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignAlgo {
    Md5,
    Sha1,
    Sha224,
    Sha256,
    Sha384,
    Sha512,
}

/// 解析签名算法，如 "SHA256withRSA"、"SHA1withRSA"、"MD5withRSA"（大小写不敏感）
pub fn parse_sign_algorithm(algorithm: &str) -> Result<SignAlgo, String> {
    let up = algorithm.trim().to_ascii_uppercase();
    let head = up.strip_suffix("WITHRSA").unwrap_or(&up);
    match head {
        "MD5" => Ok(SignAlgo::Md5),
        "SHA1" | "SHA-1" => Ok(SignAlgo::Sha1),
        "SHA224" | "SHA-224" => Ok(SignAlgo::Sha224),
        "SHA256" | "SHA-256" => Ok(SignAlgo::Sha256),
        "SHA384" | "SHA-384" => Ok(SignAlgo::Sha384),
        "SHA512" | "SHA-512" => Ok(SignAlgo::Sha512),
        _ => Err(format!(
            "Unsupported sign algorithm: {} (supported: MD5/SHA1/SHA224/SHA256/SHA384/SHA512 with RSA)",
            algorithm
        )),
    }
}

/// PKCS#1 v1.5 签名（SHAxxxwithRSA）
pub fn rsa_sign(algo: SignAlgo, key: &RsaPrivateKey, data: &[u8]) -> Result<Vec<u8>, String> {
    macro_rules! do_sign {
        ($d:ty) => {{
            let digest = <$d as Digest>::digest(data);
            let sk = SigningKey::<$d>::new(key.clone());
            let sig: RsaSignature = sk
                .sign_prehash(digest.as_slice())
                .map_err(|e| format!("RSA sign failed: {}", e))?;
            sig.to_bytes().to_vec()
        }};
    }
    Ok(match algo {
        SignAlgo::Md5 => do_sign!(md5::Md5),
        SignAlgo::Sha1 => do_sign!(sha1::Sha1),
        SignAlgo::Sha224 => do_sign!(sha2::Sha224),
        SignAlgo::Sha256 => do_sign!(sha2::Sha256),
        SignAlgo::Sha384 => do_sign!(sha2::Sha384),
        SignAlgo::Sha512 => do_sign!(sha2::Sha512),
    })
}

/// PKCS#1 v1.5 验签
pub fn rsa_verify(algo: SignAlgo, key: &RsaPublicKey, data: &[u8], sig: &[u8]) -> bool {
    macro_rules! do_verify {
        ($d:ty) => {{
            let digest = <$d as Digest>::digest(data);
            let Ok(signature) = RsaSignature::try_from(sig) else {
                return false;
            };
            VerifyingKey::<$d>::new(key.clone())
                .verify_prehash(digest.as_slice(), &signature)
                .is_ok()
        }};
    }
    match algo {
        SignAlgo::Md5 => do_verify!(md5::Md5),
        SignAlgo::Sha1 => do_verify!(sha1::Sha1),
        SignAlgo::Sha224 => do_verify!(sha2::Sha224),
        SignAlgo::Sha256 => do_verify!(sha2::Sha256),
        SignAlgo::Sha384 => do_verify!(sha2::Sha384),
        SignAlgo::Sha512 => do_verify!(sha2::Sha512),
    }
}

/// 密文字符串解码：优先 Base64，回退 Hex（对齐 hutool SecureUtil.decode）
fn decode_cipher_text(s: &str) -> Result<Vec<u8>, String> {
    let trimmed = s.trim();
    if let Ok(bytes) = b64_decode_lenient(trimmed) {
        return Ok(bytes);
    }
    hex::decode(trimmed).map_err(|e| format!("Ciphertext is neither valid Base64 nor Hex: {}", e))
}

// ---------------------------------------------------------------------------
// JS 对象状态与构造
// ---------------------------------------------------------------------------

/// 将错误信息包装为 JS 异常
fn js_err(msg: impl Into<String>) -> rquickjs::Error {
    rquickjs::Error::FromJs {
        from: "String",
        to: "RsaResult",
        message: Some(msg.into()),
    }
}

/// 将 JS 值转为字节：String -> UTF-8 字节；Uint8Array -> 原始字节
fn value_to_bytes<'js>(v: &rquickjs::Value<'js>) -> rquickjs::Result<Vec<u8>> {
    if let Some(s) = v.as_string() {
        return Ok(s.to_string()?.into_bytes());
    }
    if let Ok(arr) = rquickjs::TypedArray::<u8>::from_value(v.clone()) {
        if let Some(bytes) = arr.as_bytes() {
            return Ok(bytes.to_vec());
        }
    }
    Err(js_err("Cannot convert JS value to bytes (expected String or Uint8Array)"))
}

/// 将 JS 值转为密文字节：String -> Base64/Hex 解码；Uint8Array -> 原始字节
fn value_to_cipher_bytes<'js>(v: &rquickjs::Value<'js>) -> rquickjs::Result<Vec<u8>> {
    if let Some(s) = v.as_string() {
        return decode_cipher_text(&s.to_string()?).map_err(js_err);
    }
    if let Ok(arr) = rquickjs::TypedArray::<u8>::from_value(v.clone()) {
        if let Some(bytes) = arr.as_bytes() {
            return Ok(bytes.to_vec());
        }
    }
    Err(js_err("Cannot convert JS value to ciphertext bytes (expected String or Uint8Array)"))
}

/// 字符串密文解密：依次按 Base64、Hex 解码尝试解密，返回首个成功结果
/// （避免 hex 密文被误判为 Base64，对齐书源 encryptHex/decryptStr 混用场景）
fn decrypt_from_text(
    st: &RefCell<AsymState>,
    use_public: bool,
    s: &str,
) -> Result<Vec<u8>, String> {
    let mut last_err = "Ciphertext is neither valid Base64 nor Hex".to_string();
    let candidates = [
        b64_decode_lenient(s),
        hex::decode(s.trim()).map_err(|e| e.to_string()),
    ];
    for bytes in candidates.into_iter().flatten() {
        match st.borrow_mut().decrypt(use_public, &bytes) {
            Ok(pt) => return Ok(pt),
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

/// createAsymmetricCrypto 对象状态（对齐 Kotlin AsymmetricCrypto）
struct AsymState {
    padding: RsaPadding,
    public: Option<RsaPublicKey>,
    private: Option<RsaPrivateKey>,
}

impl AsymState {
    fn new(padding: RsaPadding) -> Self {
        Self {
            padding,
            public: None,
            private: None,
        }
    }

    /// 对齐 hutool：未提供任何密钥时生成随机 1024 位密钥对
    fn ensure_random_keys(&mut self) -> Result<(), String> {
        if self.public.is_none() && self.private.is_none() {
            let priv_key = RsaPrivateKey::new(&mut rand_core::OsRng, 1024)
                .map_err(|e| format!("Failed to generate random RSA key pair: {}", e))?;
            self.public = Some(RsaPublicKey::from(&priv_key));
            self.private = Some(priv_key);
        }
        Ok(())
    }

    fn public_key(&mut self) -> Result<RsaPublicKey, String> {
        self.ensure_random_keys()?;
        self.public
            .clone()
            .ok_or_else(|| "Missing RSA public key, call setPublicKey first".to_string())
    }

    fn private_key(&mut self) -> Result<RsaPrivateKey, String> {
        self.ensure_random_keys()?;
        self.private
            .clone()
            .ok_or_else(|| "Missing RSA private key, call setPrivateKey first".to_string())
    }

    /// 加解密方向分发（usePublicKey 对齐 Kotlin getKeyType）
    fn encrypt(&mut self, use_public: bool, data: &[u8]) -> Result<Vec<u8>, String> {
        if use_public {
            let key = self.public_key()?;
            rsa_encrypt_segmented(&key, self.padding, data)
        } else {
            let key = self.private_key()?;
            rsa_private_encrypt_segmented(&key, self.padding, data)
        }
    }

    fn decrypt(&mut self, use_public: bool, data: &[u8]) -> Result<Vec<u8>, String> {
        if use_public {
            let key = self.public_key()?;
            rsa_public_decrypt_segmented(&key, self.padding, data)
        } else {
            let key = self.private_key()?;
            rsa_decrypt_segmented(&key, self.padding, data)
        }
    }
}

/// 构造 createAsymmetricCrypto 返回的 JS 对象
///
/// 方法集合对齐 Kotlin `AsymmetricCrypto`：
/// setPublicKey / setPrivateKey / encrypt / encryptHex / encryptBase64 /
/// decrypt / decryptStr，均带可选 `usePublicKey`（默认 true，对齐 Kotlin 默认值）。
pub fn build_asymmetric_crypto_object<'js>(
    ctx: rquickjs::Ctx<'js>,
    transformation: &str,
) -> rquickjs::Result<rquickjs::Object<'js>> {
    let padding = parse_rsa_transformation(transformation).map_err(js_err)?;
    let state = Rc::new(RefCell::new(AsymState::new(padding)));
    let obj = rquickjs::Object::new(ctx.clone())?;

    // setPublicKey(key) -> this（链式调用；通过 This 参数返回，避免闭包捕获对象自身造成 GC 循环引用）
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |this: rquickjs::function::This<rquickjs::Object<'js>>, key: String| -> rquickjs::Result<rquickjs::Object<'js>> {
                let pk = parse_public_key(&key).map_err(js_err)?;
                st.borrow_mut().public = Some(pk);
                Ok(this.0)
            },
        )?;
        obj.set("setPublicKey", f)?;
    }

    // setPrivateKey(key) -> this（链式调用）
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |this: rquickjs::function::This<rquickjs::Object<'js>>, key: String| -> rquickjs::Result<rquickjs::Object<'js>> {
                let k = parse_private_key(&key).map_err(js_err)?;
                st.borrow_mut().private = Some(k);
                Ok(this.0)
            },
        )?;
        obj.set("setPrivateKey", f)?;
    }

    // encrypt(data, usePublicKey?) -> Uint8Array（对齐 Kotlin encrypt: ByteArray）
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |ctx: rquickjs::Ctx<'js>,
                  data: rquickjs::Value<'js>,
                  use_public: rquickjs::function::Opt<bool>|
                  -> rquickjs::Result<rquickjs::TypedArray<'js, u8>> {
                let bytes = value_to_bytes(&data)?;
                let ct = st
                    .borrow_mut()
                    .encrypt(use_public.0.unwrap_or(true), &bytes)
                    .map_err(js_err)?;
                rquickjs::TypedArray::new(ctx.clone(), ct)
            },
        )?;
        obj.set("encrypt", f)?;
    }

    // encryptHex(data, usePublicKey?) -> String
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |data: rquickjs::Value<'js>,
                  use_public: rquickjs::function::Opt<bool>|
                  -> rquickjs::Result<String> {
                let bytes = value_to_bytes(&data)?;
                let ct = st
                    .borrow_mut()
                    .encrypt(use_public.0.unwrap_or(true), &bytes)
                    .map_err(js_err)?;
                Ok(hex::encode(ct))
            },
        )?;
        obj.set("encryptHex", f)?;
    }

    // encryptBase64(data, usePublicKey?) -> String
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |data: rquickjs::Value<'js>,
                  use_public: rquickjs::function::Opt<bool>|
                  -> rquickjs::Result<String> {
                let bytes = value_to_bytes(&data)?;
                let ct = st
                    .borrow_mut()
                    .encrypt(use_public.0.unwrap_or(true), &bytes)
                    .map_err(js_err)?;
                Ok(B64.encode(ct))
            },
        )?;
        obj.set("encryptBase64", f)?;
    }

    // decrypt(data, usePublicKey?) -> Uint8Array（String 输入按 Base64/Hex 双解码尝试）
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |ctx: rquickjs::Ctx<'js>,
                  data: rquickjs::Value<'js>,
                  use_public: rquickjs::function::Opt<bool>|
                  -> rquickjs::Result<rquickjs::TypedArray<'js, u8>> {
                let use_pub = use_public.0.unwrap_or(true);
                let pt = if let Some(s) = data.as_string() {
                    decrypt_from_text(&st, use_pub, &s.to_string()?).map_err(js_err)?
                } else {
                    let bytes = value_to_cipher_bytes(&data)?;
                    st.borrow_mut().decrypt(use_pub, &bytes).map_err(js_err)?
                };
                rquickjs::TypedArray::new(ctx.clone(), pt)
            },
        )?;
        obj.set("decrypt", f)?;
    }

    // decryptStr(data, usePublicKey?) -> String
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |data: rquickjs::Value<'js>,
                  use_public: rquickjs::function::Opt<bool>|
                  -> rquickjs::Result<String> {
                let use_pub = use_public.0.unwrap_or(true);
                let pt = if let Some(s) = data.as_string() {
                    decrypt_from_text(&st, use_pub, &s.to_string()?).map_err(js_err)?
                } else {
                    let bytes = value_to_cipher_bytes(&data)?;
                    st.borrow_mut().decrypt(use_pub, &bytes).map_err(js_err)?
                };
                Ok(String::from_utf8_lossy(&pt).into_owned())
            },
        )?;
        obj.set("decryptStr", f)?;
    }

    Ok(obj)
}

/// createSign 对象状态（对齐 Kotlin Sign / hutool Sign）
struct SignState {
    algo: SignAlgo,
    public: Option<RsaPublicKey>,
    private: Option<RsaPrivateKey>,
}

impl SignState {
    fn new(algo: SignAlgo) -> Self {
        Self {
            algo,
            public: None,
            private: None,
        }
    }

    /// 对齐 hutool：未提供密钥时生成随机 1024 位密钥对
    fn ensure_random_keys(&mut self) -> Result<(), String> {
        if self.public.is_none() && self.private.is_none() {
            let priv_key = RsaPrivateKey::new(&mut rand_core::OsRng, 1024)
                .map_err(|e| format!("Failed to generate random RSA key pair: {}", e))?;
            self.public = Some(RsaPublicKey::from(&priv_key));
            self.private = Some(priv_key);
        }
        Ok(())
    }

    fn sign(&mut self, data: &[u8]) -> Result<Vec<u8>, String> {
        self.ensure_random_keys()?;
        let key = self
            .private
            .clone()
            .ok_or_else(|| "Missing private key for sign, call setPrivateKey first".to_string())?;
        rsa_sign(self.algo, &key, data)
    }

    fn verify(&mut self, data: &[u8], sig: &[u8]) -> Result<bool, String> {
        self.ensure_random_keys()?;
        let key = self
            .public
            .clone()
            .ok_or_else(|| "Missing public key for verify, call setPublicKey first".to_string())?;
        Ok(rsa_verify(self.algo, &key, data, sig))
    }
}

/// 构造 createSign 返回的 JS 对象
///
/// 方法集合对齐 Kotlin `Sign`（hutool）：
/// setPrivateKey / setPublicKey / sign / signHex / signBase64 / verify。
pub fn build_sign_object<'js>(
    ctx: rquickjs::Ctx<'js>,
    algorithm: &str,
) -> rquickjs::Result<rquickjs::Object<'js>> {
    let algo = parse_sign_algorithm(algorithm).map_err(js_err)?;
    let state = Rc::new(RefCell::new(SignState::new(algo)));
    let obj = rquickjs::Object::new(ctx.clone())?;

    // setPrivateKey(key) -> this（通过 This 参数返回，避免 GC 循环引用）
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |this: rquickjs::function::This<rquickjs::Object<'js>>, key: String| -> rquickjs::Result<rquickjs::Object<'js>> {
                let k = parse_private_key(&key).map_err(js_err)?;
                st.borrow_mut().private = Some(k);
                Ok(this.0)
            },
        )?;
        obj.set("setPrivateKey", f)?;
    }

    // setPublicKey(key) -> this
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |this: rquickjs::function::This<rquickjs::Object<'js>>, key: String| -> rquickjs::Result<rquickjs::Object<'js>> {
                let pk = parse_public_key(&key).map_err(js_err)?;
                st.borrow_mut().public = Some(pk);
                Ok(this.0)
            },
        )?;
        obj.set("setPublicKey", f)?;
    }

    // sign(data) -> Uint8Array（对齐 hutool Sign.sign: byte[]）
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |ctx: rquickjs::Ctx<'js>,
                  data: rquickjs::Value<'js>|
                  -> rquickjs::Result<rquickjs::TypedArray<'js, u8>> {
                let bytes = value_to_bytes(&data)?;
                let sig = st.borrow_mut().sign(&bytes).map_err(js_err)?;
                rquickjs::TypedArray::new(ctx.clone(), sig)
            },
        )?;
        obj.set("sign", f)?;
    }

    // signHex(data) -> String（对齐 hutool Sign.signHex，WebJsExtensions 使用）
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |data: rquickjs::Value<'js>| -> rquickjs::Result<String> {
                let bytes = value_to_bytes(&data)?;
                let sig = st.borrow_mut().sign(&bytes).map_err(js_err)?;
                Ok(hex::encode(sig))
            },
        )?;
        obj.set("signHex", f)?;
    }

    // signBase64(data) -> String
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |data: rquickjs::Value<'js>| -> rquickjs::Result<String> {
                let bytes = value_to_bytes(&data)?;
                let sig = st.borrow_mut().sign(&bytes).map_err(js_err)?;
                Ok(B64.encode(sig))
            },
        )?;
        obj.set("signBase64", f)?;
    }

    // verify(data, sign) -> boolean（sign 接受 Base64/Hex 字符串或 Uint8Array；
    // 字符串输入依次按 Base64、Hex 解码尝试验签，避免 hex 签名被误判为 Base64）
    {
        let st = state.clone();
        let f = rquickjs::Function::new(
            ctx.clone(),
            move |data: rquickjs::Value<'js>,
                  sig: rquickjs::Value<'js>|
                  -> rquickjs::Result<bool> {
                let bytes = value_to_bytes(&data)?;
                let mut st = st.borrow_mut();
                if let Some(s) = sig.as_string() {
                    let s = s.to_string()?;
                    if let Ok(b64) = b64_decode_lenient(&s) {
                        if st.verify(&bytes, &b64).map_err(js_err)? {
                            return Ok(true);
                        }
                    }
                    if let Ok(hx) = hex::decode(s.trim()) {
                        if st.verify(&bytes, &hx).map_err(js_err)? {
                            return Ok(true);
                        }
                    }
                    return Ok(false);
                }
                let sig_bytes = value_to_cipher_bytes(&sig)?;
                st.verify(&bytes, &sig_bytes).map_err(js_err)
            },
        )?;
        obj.set("verify", f)?;
    }

    Ok(obj)
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

/// 仅供测试：生成随机 1024 位密钥对，返回 (公钥 Base64 SPKI DER, 私钥 Base64 PKCS#8 DER)
#[cfg(test)]
pub fn generate_test_keypair_b64() -> (String, String) {
    use rsa::pkcs8::{EncodePrivateKey, EncodePublicKey};

    let priv_key = RsaPrivateKey::new(&mut rand_core::OsRng, 1024).expect("generate keypair");
    let pub_key = RsaPublicKey::from(&priv_key);
    let pub_der = pub_key.to_public_key_der().expect("encode public key");
    let priv_der = priv_key.to_pkcs8_der().expect("encode private key");
    (B64.encode(pub_der.as_bytes()), B64.encode(priv_der.as_bytes()))
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn test_keypair() -> (RsaPublicKey, RsaPrivateKey) {
        let priv_key = RsaPrivateKey::new(&mut rand_core::OsRng, 1024).unwrap();
        let pub_key = RsaPublicKey::from(&priv_key);
        (pub_key, priv_key)
    }

    // ---- transformation 解析 ----

    #[test]
    fn test_parse_rsa_transformation() {
        assert_eq!(parse_rsa_transformation("RSA").unwrap(), RsaPadding::Pkcs1v15);
        assert_eq!(
            parse_rsa_transformation("RSA/ECB/PKCS1Padding").unwrap(),
            RsaPadding::Pkcs1v15
        );
        assert_eq!(
            parse_rsa_transformation("RSA/None/PKCS1Padding").unwrap(),
            RsaPadding::Pkcs1v15
        );
        assert_eq!(
            parse_rsa_transformation("RSA/ECB/OAEPWithSHA-1AndMGF1Padding").unwrap(),
            RsaPadding::OaepSha1
        );
        assert_eq!(
            parse_rsa_transformation("RSA/ECB/OAEPWITHSHA256ANDMGF1PADDING").unwrap(),
            RsaPadding::OaepSha256
        );
        assert!(parse_rsa_transformation("RSA/ECB/NoPadding").is_err());
        assert!(parse_rsa_transformation("ECB").is_err());
    }

    // ---- 加解密往返 ----

    #[test]
    fn test_rsa_pkcs1_roundtrip() {
        let (pub_key, priv_key) = test_keypair();
        let data = b"Hello, Legado RSA!";
        let ct = rsa_encrypt_segmented(&pub_key, RsaPadding::Pkcs1v15, data).unwrap();
        let pt = rsa_decrypt_segmented(&priv_key, RsaPadding::Pkcs1v15, &ct).unwrap();
        assert_eq!(pt, data);
    }

    #[test]
    fn test_rsa_pkcs1_segmented_long_data() {
        // 300 字节超过 1024 位密钥单块上限（117），必须分段
        let (pub_key, priv_key) = test_keypair();
        let data: Vec<u8> = (0..300u32).map(|i| (i % 256) as u8).collect();
        let ct = rsa_encrypt_segmented(&pub_key, RsaPadding::Pkcs1v15, &data).unwrap();
        // 1024 位密钥：300/117 = 3 块，密文长 3*128
        assert_eq!(ct.len(), 3 * 128);
        let pt = rsa_decrypt_segmented(&priv_key, RsaPadding::Pkcs1v15, &ct).unwrap();
        assert_eq!(pt, data);
    }

    #[test]
    fn test_rsa_oaep_sha256_roundtrip() {
        let (pub_key, priv_key) = test_keypair();
        let data = b"OAEP roundtrip test";
        let ct = rsa_encrypt_segmented(&pub_key, RsaPadding::OaepSha256, data).unwrap();
        let pt = rsa_decrypt_segmented(&priv_key, RsaPadding::OaepSha256, &ct).unwrap();
        assert_eq!(pt, data);
    }

    #[test]
    fn test_rsa_private_encrypt_public_decrypt() {
        // 私钥加密 / 公钥解密（Java Cipher 反向用法）
        let (pub_key, priv_key) = test_keypair();
        let data = b"private key encrypt direction";
        let ct = rsa_private_encrypt_segmented(&priv_key, RsaPadding::Pkcs1v15, data).unwrap();
        let pt = rsa_public_decrypt_segmented(&pub_key, RsaPadding::Pkcs1v15, &ct).unwrap();
        assert_eq!(pt, data);
    }

    #[test]
    fn test_rsa_wrong_key_decrypt_fails() {
        let (pub_key, _) = test_keypair();
        let (_, other_priv) = test_keypair();
        let ct = rsa_encrypt_segmented(&pub_key, RsaPadding::Pkcs1v15, b"secret").unwrap();
        assert!(rsa_decrypt_segmented(&other_priv, RsaPadding::Pkcs1v15, &ct).is_err());
    }

    #[test]
    fn test_rsa_decrypt_bad_length_fails() {
        let (_, priv_key) = test_keypair();
        assert!(rsa_decrypt_segmented(&priv_key, RsaPadding::Pkcs1v15, &[1, 2, 3]).is_err());
    }

    // ---- 密钥解析 ----

    #[test]
    fn test_parse_keys_from_base64_der() {
        let (pub_b64, priv_b64) = generate_test_keypair_b64();
        let pub_key = parse_public_key(&pub_b64).unwrap();
        let priv_key = parse_private_key(&priv_b64).unwrap();
        // 解析出的密钥可用于加解密往返
        let ct = rsa_encrypt_segmented(&pub_key, RsaPadding::Pkcs1v15, b"der keys").unwrap();
        let pt = rsa_decrypt_segmented(&priv_key, RsaPadding::Pkcs1v15, &ct).unwrap();
        assert_eq!(pt, b"der keys");
    }

    #[test]
    fn test_parse_private_key_from_pem() {
        use rsa::pkcs8::{EncodePrivateKey, LineEnding};
        let (_, priv_key) = test_keypair();
        let pem = priv_key.to_pkcs8_pem(LineEnding::LF).unwrap();
        let parsed = parse_private_key(&pem).unwrap();
        assert_eq!(parsed.size(), priv_key.size());
    }

    #[test]
    fn test_parse_invalid_key_fails() {
        assert!(parse_public_key("not a key at all!!!").is_err());
        assert!(parse_private_key(
            "-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----"
        )
        .is_err());
    }

    // ---- 签名验签 ----

    #[test]
    fn test_parse_sign_algorithm() {
        assert_eq!(parse_sign_algorithm("SHA256withRSA").unwrap(), SignAlgo::Sha256);
        assert_eq!(parse_sign_algorithm("sha1withrsa").unwrap(), SignAlgo::Sha1);
        assert_eq!(parse_sign_algorithm("MD5withRSA").unwrap(), SignAlgo::Md5);
        assert!(parse_sign_algorithm("SHA3withRSA").is_err());
    }

    #[test]
    fn test_rsa_sign_verify_roundtrip() {
        let (pub_key, priv_key) = test_keypair();
        let data = b"data to be signed";
        for algo in [
            SignAlgo::Md5,
            SignAlgo::Sha1,
            SignAlgo::Sha224,
            SignAlgo::Sha256,
            SignAlgo::Sha384,
            SignAlgo::Sha512,
        ] {
            let sig = rsa_sign(algo, &priv_key, data).unwrap();
            assert!(rsa_verify(algo, &pub_key, data, &sig), "algo: {:?}", algo);
            // 篡改数据应验签失败
            assert!(!rsa_verify(algo, &pub_key, b"tampered", &sig));
        }
    }

    #[test]
    fn test_rsa_verify_wrong_key_fails() {
        let (_, priv_key) = test_keypair();
        let (other_pub, _) = test_keypair();
        let sig = rsa_sign(SignAlgo::Sha256, &priv_key, b"data").unwrap();
        assert!(!rsa_verify(SignAlgo::Sha256, &other_pub, b"data", &sig));
    }

    // ---- 状态对象（随机密钥生成路径）----

    #[test]
    fn test_asym_state_random_keys_roundtrip() {
        // 对齐 hutool：未设置密钥时生成随机密钥对，加解密应自洽
        let mut st = AsymState::new(RsaPadding::Pkcs1v15);
        let ct = st.encrypt(true, b"random pair test").unwrap();
        let pt = st.decrypt(false, &ct).unwrap();
        assert_eq!(pt, b"random pair test");
    }

    #[test]
    fn test_decode_cipher_text_base64_and_hex() {
        // 对齐 hutool SecureUtil.decode：优先 Base64，非法时回退 Hex
        assert_eq!(decode_cipher_text("aGVsbG8=").unwrap(), b"hello");
        assert!(decode_cipher_text("###").is_err());
    }
}
