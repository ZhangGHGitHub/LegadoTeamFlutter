//! 对称加密 JS 对象桥（对齐 Android `JsEncodeUtils.createSymmetricCrypto`）
//!
//! 原版返回 hutool `SymmetricCrypto` 实例，书源以链式调用：
//! ```js
//! const cipher = java.createSymmetricCrypto("AES/CBC/NoPadding", key, iv);
//! return cipher.decrypt(result); // Uint8Array → Uint8Array（漫画 imageDecode）
//! java.aesBase64DecodeToString(b64, key, "AES/CBC/PKCS5Padding", iv);
//! ```
//!
//! 重构版此前 `createSymmetricCrypto` 只返回 `"AES/CBC"` 字符串，
//! `.decrypt` 恒失败 → 密文原样进 Image.memory → Invalid image data。
//! — Reasonix + Rust

use std::cell::RefCell;
use std::rc::Rc;

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use rquickjs::function::Opt;
use rquickjs::{Ctx, Function, Object, Result as JsResult, TypedArray, Value};

use legado_core::crypto::{self, parse_transformation};

fn js_err(msg: impl Into<String>) -> rquickjs::Error {
    rquickjs::Error::FromJs {
        from: "String",
        to: "SymmetricCrypto",
        message: Some(msg.into()),
    }
}

/// 宽松 Base64 解码（去空白、补齐 padding）
fn b64_decode_lenient(s: &str) -> Result<Vec<u8>, String> {
    let cleaned: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    if cleaned.is_empty() {
        return Err("Empty Base64 data".to_string());
    }
    let pad = (4 - cleaned.len() % 4) % 4;
    let padded = format!("{}{}", cleaned, "=".repeat(pad));
    B64.decode(&padded)
        .map_err(|e| format!("Invalid Base64 data: {e}"))
}

/// JS 值 → 密钥/IV 字节：String 按 UTF-8；Uint8Array 取原始字节
fn value_to_key_bytes<'js>(v: &Value<'js>) -> JsResult<Vec<u8>> {
    if let Some(s) = v.as_string() {
        return Ok(s.to_string()?.into_bytes());
    }
    if let Ok(arr) = TypedArray::<u8>::from_value(v.clone()) {
        if let Some(bytes) = arr.as_bytes() {
            return Ok(bytes.to_vec());
        }
    }
    Err(js_err(
        "key/iv must be String or Uint8Array (对齐 Android ByteArray/String 重载)",
    ))
}

/// JS 密文 → 字节：Uint8Array 原样；String 按 Base64 解码（对齐 hutool decrypt(String)）
fn value_to_cipher_bytes<'js>(v: &Value<'js>) -> JsResult<Vec<u8>> {
    if let Ok(arr) = TypedArray::<u8>::from_value(v.clone()) {
        if let Some(bytes) = arr.as_bytes() {
            return Ok(bytes.to_vec());
        }
    }
    if let Some(s) = v.as_string() {
        return b64_decode_lenient(&s.to_string()?).map_err(js_err);
    }
    Err(js_err("decrypt input must be String(Base64) or Uint8Array"))
}

/// JS 明文 → 字节：String UTF-8；Uint8Array 原样
fn value_to_plain_bytes<'js>(v: &Value<'js>) -> JsResult<Vec<u8>> {
    if let Some(s) = v.as_string() {
        return Ok(s.to_string()?.into_bytes());
    }
    if let Ok(arr) = TypedArray::<u8>::from_value(v.clone()) {
        if let Some(bytes) = arr.as_bytes() {
            return Ok(bytes.to_vec());
        }
    }
    Err(js_err("encrypt input must be String or Uint8Array"))
}

/// 对称加密状态（对齐 hutool SymmetricCrypto 持有 key/iv/transformation）
struct SymState {
    transformation: String,
    key: Vec<u8>,
    iv: Option<Vec<u8>>,
}

impl SymState {
    fn decrypt(&self, data: &[u8]) -> Result<Vec<u8>, String> {
        crypto::symmetric_decrypt(&self.transformation, &self.key, self.iv.as_deref(), data)
            .map_err(|e| e.to_string())
    }

    fn encrypt(&self, data: &[u8]) -> Result<Vec<u8>, String> {
        crypto::symmetric_encrypt(&self.transformation, &self.key, self.iv.as_deref(), data)
            .map_err(|e| e.to_string())
    }
}

/// 构建 createSymmetricCrypto 返回对象
///
/// 方法对齐 hutool：`decrypt` / `decryptStr` / `encrypt` / `encryptBase64` / `encryptHex` / `setIv`
pub fn build_symmetric_crypto_object<'js>(
    ctx: Ctx<'js>,
    transformation: &str,
    key: &[u8],
    iv: Option<&[u8]>,
) -> JsResult<Object<'js>> {
    // 预先校验 transformation，失败尽早报错（避免书源侧 cipher.decrypt 才炸）
    let (algo, mode, _padding) = parse_transformation(transformation).map_err(js_err)?;
    match algo.as_str() {
        "AES" if mode == "CBC" || mode == "ECB" || mode == "NONE" => {}
        "DES" | "RC4" => {}
        _ => {
            return Err(js_err(format!(
                "Unsupported algorithm: {algo} (supported: AES/DES/RC4)"
            )));
        }
    }

    let state = Rc::new(RefCell::new(SymState {
        transformation: transformation.to_string(),
        key: key.to_vec(),
        iv: iv.map(|v| v.to_vec()),
    }));

    let obj = Object::new(ctx.clone())?;

    // decrypt(data) -> Uint8Array（对齐 hutool decrypt → byte[]）
    {
        let st = Rc::clone(&state);
        let f = Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, data: Value<'js>| -> JsResult<TypedArray<'js, u8>> {
                let bytes = value_to_cipher_bytes(&data)?;
                let pt = st.borrow().decrypt(&bytes).map_err(js_err)?;
                TypedArray::new(ctx, pt)
            },
        )?;
        obj.set("decrypt", f)?;
    }

    // decryptStr(data) -> String
    {
        let st = Rc::clone(&state);
        let f = Function::new(ctx.clone(), move |data: Value<'js>| -> JsResult<String> {
            let bytes = value_to_cipher_bytes(&data)?;
            let pt = st.borrow().decrypt(&bytes).map_err(js_err)?;
            String::from_utf8(pt).map_err(|e| js_err(format!("UTF-8 decode: {e}")))
        })?;
        obj.set("decryptStr", f)?;
    }

    // encrypt(data) -> Uint8Array
    {
        let st = Rc::clone(&state);
        let f = Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, data: Value<'js>| -> JsResult<TypedArray<'js, u8>> {
                let bytes = value_to_plain_bytes(&data)?;
                let ct = st.borrow().encrypt(&bytes).map_err(js_err)?;
                TypedArray::new(ctx, ct)
            },
        )?;
        obj.set("encrypt", f)?;
    }

    // encryptBase64(data) -> String
    {
        let st = Rc::clone(&state);
        let f = Function::new(ctx.clone(), move |data: Value<'js>| -> JsResult<String> {
            let bytes = value_to_plain_bytes(&data)?;
            let ct = st.borrow().encrypt(&bytes).map_err(js_err)?;
            Ok(B64.encode(ct))
        })?;
        obj.set("encryptBase64", f)?;
    }

    // encryptHex(data) -> String
    {
        let st = Rc::clone(&state);
        let f = Function::new(ctx.clone(), move |data: Value<'js>| -> JsResult<String> {
            let bytes = value_to_plain_bytes(&data)?;
            let ct = st.borrow().encrypt(&bytes).map_err(js_err)?;
            Ok(hex::encode(ct))
        })?;
        obj.set("encryptHex", f)?;
    }

    // 注意：不实现 setIv 链式返回 this——在 rquickjs 中闭包捕获 Object 自引用
    // 会导致 Runtime drop 时 gc_obj_list 非空断言崩溃。IV 请在
    // createSymmetricCrypto(transformation, key, iv) 第三参传入（对齐 51 漫画等用法）。

    Ok(obj)
}

/// 从可选 JS 参数解析 key/iv（String | Uint8Array）
pub fn parse_key_iv_args<'js>(
    key: Value<'js>,
    iv: Opt<Value<'js>>,
) -> JsResult<(Vec<u8>, Option<Vec<u8>>)> {
    let key_bytes = value_to_key_bytes(&key)?;
    let iv_bytes = match iv.0 {
        Some(v) if !v.is_null() && !v.is_undefined() => Some(value_to_key_bytes(&v)?),
        _ => None,
    };
    Ok((key_bytes, iv_bytes))
}

/// aesBase64DecodeToString(str, key, transformation, iv) — 对齐 JsEncodeUtils 同名方法
pub fn aes_base64_decode_to_string(
    ciphertext_b64: &str,
    key: &str,
    transformation: &str,
    iv: &str,
) -> Result<String, String> {
    let data = b64_decode_lenient(ciphertext_b64)?;
    let pt = crypto::symmetric_decrypt(transformation, key.as_bytes(), Some(iv.as_bytes()), &data)
        .map_err(|e| e.to_string())?;
    String::from_utf8(pt).map_err(|e| format!("UTF-8 decode: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::crypto::AesCrypto;

    #[test]
    fn test_aes_base64_decode_to_string_pkcs() {
        let key = "0123456789abcdef";
        let iv = "fedcba9876543210";
        let plain = "kaimanhua-aes-payload";
        let ct = AesCrypto::encrypt_cbc(key.as_bytes(), iv.as_bytes(), plain.as_bytes()).unwrap();
        let b64 = B64.encode(&ct);
        let out = aes_base64_decode_to_string(&b64, key, "AES/CBC/PKCS5Padding", iv).unwrap();
        assert_eq!(out, plain);
    }

    #[test]
    fn test_sym_state_nopadding_bytes() {
        let key = b"0123456789abcdef";
        let iv = b"fedcba9876543210";
        let plain = b"0123456789abcdef0123456789abcdef";
        let ct = AesCrypto::encrypt_cbc_nopadding(key, iv, plain).unwrap();
        let st = SymState {
            transformation: "AES/CBC/NoPadding".into(),
            key: key.to_vec(),
            iv: Some(iv.to_vec()),
        };
        let pt = st.decrypt(&ct).unwrap();
        assert_eq!(&pt, plain);
    }
}
