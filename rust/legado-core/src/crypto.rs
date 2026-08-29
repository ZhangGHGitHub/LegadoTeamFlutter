//! 加密/解密工具模块
//!
//! 书源规则中常用的对称加密算法支持。
//! 参考 Kotlin 侧 `SymmetricCryptoAndroid.kt` 与 CryptoJS 集成。
//!
//! 支持算法：
//! - AES（CBC / ECB 模式，PKCS7 或 NoPadding，128/192/256 位密钥）
//! - DES（CBC 模式，PKCS7 填充）
//! - RC4（流密码，加解密同操作）

use crate::{LegadoError, LegadoResult};

/// AES 块大小（字节）
const AES_BLOCK_SIZE: usize = 16;
/// DES 块大小（字节）
const DES_BLOCK_SIZE: usize = 8;

// ---------------------------------------------------------------------------
// AES
// ---------------------------------------------------------------------------

/// AES 对称加密工具
///
/// 自动根据密钥长度（16/24/32 字节）选择 AES-128/192/256。
pub struct AesCrypto;

impl AesCrypto {
    /// AES-CBC 解密（PKCS7 填充）
    pub fn decrypt_cbc(key: &[u8], iv: &[u8], data: &[u8]) -> LegadoResult<Vec<u8>> {
        use aes::{Aes128, Aes192, Aes256};
        use cbc::cipher::block_padding::Pkcs7;
        use cbc::cipher::{BlockDecryptMut, KeyIvInit};

        type Dec128 = cbc::Decryptor<Aes128>;
        type Dec192 = cbc::Decryptor<Aes192>;
        type Dec256 = cbc::Decryptor<Aes256>;

        let mut buf = data.to_vec();
        let pt = match key.len() {
            16 => Dec128::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<Pkcs7>(&mut buf)
                .map_err(crypto_op_err)?,
            24 => Dec192::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<Pkcs7>(&mut buf)
                .map_err(crypto_op_err)?,
            32 => Dec256::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<Pkcs7>(&mut buf)
                .map_err(crypto_op_err)?,
            n => return Err(bad_key_len("AES", n, &[16, 24, 32])),
        };
        Ok(pt.to_vec())
    }

    /// AES-CBC 加密（PKCS7 填充）
    pub fn encrypt_cbc(key: &[u8], iv: &[u8], data: &[u8]) -> LegadoResult<Vec<u8>> {
        use aes::{Aes128, Aes192, Aes256};
        use cbc::cipher::block_padding::Pkcs7;
        use cbc::cipher::{BlockEncryptMut, KeyIvInit};

        type Enc128 = cbc::Encryptor<Aes128>;
        type Enc192 = cbc::Encryptor<Aes192>;
        type Enc256 = cbc::Encryptor<Aes256>;

        let mut buf = make_padded_buf(AES_BLOCK_SIZE, data);
        let ct = match key.len() {
            16 => Enc128::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<Pkcs7>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            24 => Enc192::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<Pkcs7>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            32 => Enc256::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<Pkcs7>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            n => return Err(bad_key_len("AES", n, &[16, 24, 32])),
        };
        Ok(ct.to_vec())
    }

    /// AES-CBC 解密（NoPadding；密文长度须为 16 的倍数）
    ///
    /// 对齐 Android 漫画站 `AES/CBC/NoPadding` imageDecode（如 51漫画）。
    /// — Reasonix + Rust
    pub fn decrypt_cbc_nopadding(key: &[u8], iv: &[u8], data: &[u8]) -> LegadoResult<Vec<u8>> {
        use aes::{Aes128, Aes192, Aes256};
        use cbc::cipher::block_padding::NoPadding;
        use cbc::cipher::{BlockDecryptMut, KeyIvInit};

        type Dec128 = cbc::Decryptor<Aes128>;
        type Dec192 = cbc::Decryptor<Aes192>;
        type Dec256 = cbc::Decryptor<Aes256>;

        if !data.len().is_multiple_of(AES_BLOCK_SIZE) {
            return Err(LegadoError::Parser(format!(
                "AES/CBC/NoPadding ciphertext length must be multiple of {}, got {}",
                AES_BLOCK_SIZE,
                data.len()
            )));
        }
        let mut buf = data.to_vec();
        let pt = match key.len() {
            16 => Dec128::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<NoPadding>(&mut buf)
                .map_err(crypto_op_err)?,
            24 => Dec192::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<NoPadding>(&mut buf)
                .map_err(crypto_op_err)?,
            32 => Dec256::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<NoPadding>(&mut buf)
                .map_err(crypto_op_err)?,
            n => return Err(bad_key_len("AES", n, &[16, 24, 32])),
        };
        Ok(pt.to_vec())
    }

    /// AES-CBC 加密（NoPadding；明文长度须为 16 的倍数）
    pub fn encrypt_cbc_nopadding(key: &[u8], iv: &[u8], data: &[u8]) -> LegadoResult<Vec<u8>> {
        use aes::{Aes128, Aes192, Aes256};
        use cbc::cipher::block_padding::NoPadding;
        use cbc::cipher::{BlockEncryptMut, KeyIvInit};

        type Enc128 = cbc::Encryptor<Aes128>;
        type Enc192 = cbc::Encryptor<Aes192>;
        type Enc256 = cbc::Encryptor<Aes256>;

        if !data.len().is_multiple_of(AES_BLOCK_SIZE) {
            return Err(LegadoError::Parser(format!(
                "AES/CBC/NoPadding plaintext length must be multiple of {}, got {}",
                AES_BLOCK_SIZE,
                data.len()
            )));
        }
        let mut buf = data.to_vec();
        let ct = match key.len() {
            16 => Enc128::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<NoPadding>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            24 => Enc192::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<NoPadding>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            32 => Enc256::new_from_slices(key, iv)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<NoPadding>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            n => return Err(bad_key_len("AES", n, &[16, 24, 32])),
        };
        Ok(ct.to_vec())
    }

    /// AES-ECB 解密（NoPadding；密文长度须为 16 的倍数）
    pub fn decrypt_ecb_nopadding(key: &[u8], data: &[u8]) -> LegadoResult<Vec<u8>> {
        use aes::{Aes128, Aes192, Aes256};
        use cbc::cipher::block_padding::NoPadding;
        use cbc::cipher::{BlockDecryptMut, KeyInit};

        type EcbDec128 = ecb::Decryptor<Aes128>;
        type EcbDec192 = ecb::Decryptor<Aes192>;
        type EcbDec256 = ecb::Decryptor<Aes256>;

        if !data.len().is_multiple_of(AES_BLOCK_SIZE) {
            return Err(LegadoError::Parser(format!(
                "AES/ECB/NoPadding ciphertext length must be multiple of {}, got {}",
                AES_BLOCK_SIZE,
                data.len()
            )));
        }
        let mut buf = data.to_vec();
        let pt = match key.len() {
            16 => EcbDec128::new_from_slice(key)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<NoPadding>(&mut buf)
                .map_err(crypto_op_err)?,
            24 => EcbDec192::new_from_slice(key)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<NoPadding>(&mut buf)
                .map_err(crypto_op_err)?,
            32 => EcbDec256::new_from_slice(key)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<NoPadding>(&mut buf)
                .map_err(crypto_op_err)?,
            n => return Err(bad_key_len("AES", n, &[16, 24, 32])),
        };
        Ok(pt.to_vec())
    }

    /// AES-ECB 加密（NoPadding；明文长度须为 16 的倍数）
    pub fn encrypt_ecb_nopadding(key: &[u8], data: &[u8]) -> LegadoResult<Vec<u8>> {
        use aes::{Aes128, Aes192, Aes256};
        use cbc::cipher::block_padding::NoPadding;
        use cbc::cipher::{BlockEncryptMut, KeyInit};

        type EcbEnc128 = ecb::Encryptor<Aes128>;
        type EcbEnc192 = ecb::Encryptor<Aes192>;
        type EcbEnc256 = ecb::Encryptor<Aes256>;

        if !data.len().is_multiple_of(AES_BLOCK_SIZE) {
            return Err(LegadoError::Parser(format!(
                "AES/ECB/NoPadding plaintext length must be multiple of {}, got {}",
                AES_BLOCK_SIZE,
                data.len()
            )));
        }
        let mut buf = data.to_vec();
        let ct = match key.len() {
            16 => EcbEnc128::new_from_slice(key)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<NoPadding>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            24 => EcbEnc192::new_from_slice(key)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<NoPadding>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            32 => EcbEnc256::new_from_slice(key)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<NoPadding>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            n => return Err(bad_key_len("AES", n, &[16, 24, 32])),
        };
        Ok(ct.to_vec())
    }

    /// AES-ECB 解密（PKCS7 填充）
    pub fn decrypt_ecb(key: &[u8], data: &[u8]) -> LegadoResult<Vec<u8>> {
        use aes::{Aes128, Aes192, Aes256};
        use cbc::cipher::block_padding::Pkcs7;
        use cbc::cipher::{BlockDecryptMut, KeyInit};

        type EcbDec128 = ecb::Decryptor<Aes128>;
        type EcbDec192 = ecb::Decryptor<Aes192>;
        type EcbDec256 = ecb::Decryptor<Aes256>;

        let mut buf = data.to_vec();
        let pt = match key.len() {
            16 => EcbDec128::new_from_slice(key)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<Pkcs7>(&mut buf)
                .map_err(crypto_op_err)?,
            24 => EcbDec192::new_from_slice(key)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<Pkcs7>(&mut buf)
                .map_err(crypto_op_err)?,
            32 => EcbDec256::new_from_slice(key)
                .map_err(crypto_init_err)?
                .decrypt_padded_mut::<Pkcs7>(&mut buf)
                .map_err(crypto_op_err)?,
            n => return Err(bad_key_len("AES", n, &[16, 24, 32])),
        };
        Ok(pt.to_vec())
    }

    /// AES-ECB 加密（PKCS7 填充）
    pub fn encrypt_ecb(key: &[u8], data: &[u8]) -> LegadoResult<Vec<u8>> {
        use aes::{Aes128, Aes192, Aes256};
        use cbc::cipher::block_padding::Pkcs7;
        use cbc::cipher::{BlockEncryptMut, KeyInit};

        type EcbEnc128 = ecb::Encryptor<Aes128>;
        type EcbEnc192 = ecb::Encryptor<Aes192>;
        type EcbEnc256 = ecb::Encryptor<Aes256>;

        let mut buf = make_padded_buf(AES_BLOCK_SIZE, data);
        let ct = match key.len() {
            16 => EcbEnc128::new_from_slice(key)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<Pkcs7>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            24 => EcbEnc192::new_from_slice(key)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<Pkcs7>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            32 => EcbEnc256::new_from_slice(key)
                .map_err(crypto_init_err)?
                .encrypt_padded_mut::<Pkcs7>(&mut buf, data.len())
                .map_err(crypto_op_err)?,
            n => return Err(bad_key_len("AES", n, &[16, 24, 32])),
        };
        Ok(ct.to_vec())
    }
}

// ---------------------------------------------------------------------------
// DES
// ---------------------------------------------------------------------------

/// DES 对称加密工具（CBC 模式，PKCS7 填充）
pub struct DesCrypto;

impl DesCrypto {
    /// DES-CBC 解密
    pub fn decrypt_cbc(key: &[u8], iv: &[u8], data: &[u8]) -> LegadoResult<Vec<u8>> {
        use cbc::cipher::block_padding::Pkcs7;
        use cbc::cipher::{BlockDecryptMut, KeyIvInit};
        use des::Des;

        if key.len() != 8 {
            return Err(bad_key_len("DES", key.len(), &[8]));
        }
        type Dec = cbc::Decryptor<Des>;
        let mut buf = data.to_vec();
        let pt = Dec::new_from_slices(key, iv)
            .map_err(crypto_init_err)?
            .decrypt_padded_mut::<Pkcs7>(&mut buf)
            .map_err(crypto_op_err)?;
        Ok(pt.to_vec())
    }

    /// DES-CBC 加密
    pub fn encrypt_cbc(key: &[u8], iv: &[u8], data: &[u8]) -> LegadoResult<Vec<u8>> {
        use cbc::cipher::block_padding::Pkcs7;
        use cbc::cipher::{BlockEncryptMut, KeyIvInit};
        use des::Des;

        if key.len() != 8 {
            return Err(bad_key_len("DES", key.len(), &[8]));
        }
        type Enc = cbc::Encryptor<Des>;
        let mut buf = make_padded_buf(DES_BLOCK_SIZE, data);
        let ct = Enc::new_from_slices(key, iv)
            .map_err(crypto_init_err)?
            .encrypt_padded_mut::<Pkcs7>(&mut buf, data.len())
            .map_err(crypto_op_err)?;
        Ok(ct.to_vec())
    }
}

// ---------------------------------------------------------------------------
// RC4
// ---------------------------------------------------------------------------

/// RC4 流密码（加密与解密为同一操作）
pub struct Rc4Crypto;

impl Rc4Crypto {
    /// RC4 处理（XOR 流密码，加解密相同）
    pub fn process(key: &[u8], data: &[u8]) -> Vec<u8> {
        assert!(!key.is_empty(), "RC4 key must not be empty");

        // Key-Scheduling Algorithm (KSA)
        let mut s: Vec<u8> = (0..=255u8).collect();
        let mut j: u8 = 0;
        for i in 0..256usize {
            j = j.wrapping_add(s[i]).wrapping_add(key[i % key.len()]);
            s.swap(i, j as usize);
        }

        // Pseudo-Random Generation Algorithm (PRGA)
        let mut i: u8 = 0;
        let mut j: u8 = 0;
        data.iter()
            .map(|&byte| {
                i = i.wrapping_add(1);
                j = j.wrapping_add(s[i as usize]);
                s.swap(i as usize, j as usize);
                let k = s[(s[i as usize].wrapping_add(s[j as usize])) as usize];
                byte ^ k
            })
            .collect()
    }
}

// ---------------------------------------------------------------------------
// 便捷函数
// ---------------------------------------------------------------------------

/// Base64 + AES-CBC 组合解密（书源常见模式）
///
/// 将 `ciphertext_b64` 进行 Base64 解码后，使用 AES-CBC（PKCS7）解密，
/// 返回 UTF-8 明文字符串。
pub fn aes_decrypt_base64(key: &str, iv: &str, ciphertext_b64: &str) -> LegadoResult<String> {
    use base64::Engine;
    let ciphertext = base64::engine::general_purpose::STANDARD
        .decode(ciphertext_b64)
        .map_err(|e| LegadoError::Parser(format!("Base64 decode error: {}", e)))?;
    let plaintext = AesCrypto::decrypt_cbc(key.as_bytes(), iv.as_bytes(), &ciphertext)?;
    String::from_utf8(plaintext)
        .map_err(|e| LegadoError::Parser(format!("UTF-8 decode error: {}", e)))
}

/// AES-CBC 加密后 Base64 编码（书源常见模式）
pub fn aes_encrypt_base64(key: &str, iv: &str, plaintext: &str) -> LegadoResult<String> {
    use base64::Engine;
    let ciphertext = AesCrypto::encrypt_cbc(key.as_bytes(), iv.as_bytes(), plaintext.as_bytes())?;
    Ok(base64::engine::general_purpose::STANDARD.encode(&ciphertext))
}

/// DES-CBC 加密后 Base64 编码
pub fn des_encrypt_base64(key: &str, iv: &str, plaintext: &str) -> LegadoResult<String> {
    use base64::Engine;
    let ciphertext = DesCrypto::encrypt_cbc(key.as_bytes(), iv.as_bytes(), plaintext.as_bytes())?;
    Ok(base64::engine::general_purpose::STANDARD.encode(&ciphertext))
}

/// Base64 + DES-CBC 组合解密
pub fn des_decrypt_base64(key: &str, iv: &str, ciphertext_b64: &str) -> LegadoResult<String> {
    use base64::Engine;
    let ciphertext = base64::engine::general_purpose::STANDARD
        .decode(ciphertext_b64)
        .map_err(|e| LegadoError::Parser(format!("Base64 decode error: {}", e)))?;
    let plaintext = DesCrypto::decrypt_cbc(key.as_bytes(), iv.as_bytes(), &ciphertext)?;
    String::from_utf8(plaintext)
        .map_err(|e| LegadoError::Parser(format!("UTF-8 decode error: {}", e)))
}

/// RC4 加密后 Base64 编码
pub fn rc4_encrypt_base64(key: &str, plaintext: &str) -> LegadoResult<String> {
    use base64::Engine;
    let ciphertext = Rc4Crypto::process(key.as_bytes(), plaintext.as_bytes());
    Ok(base64::engine::general_purpose::STANDARD.encode(&ciphertext))
}

/// Base64 + RC4 组合解密
pub fn rc4_decrypt_base64(key: &str, ciphertext_b64: &str) -> LegadoResult<String> {
    use base64::Engine;
    let ciphertext = base64::engine::general_purpose::STANDARD
        .decode(ciphertext_b64)
        .map_err(|e| LegadoError::Parser(format!("Base64 decode error: {}", e)))?;
    let plaintext = Rc4Crypto::process(key.as_bytes(), &ciphertext);
    String::from_utf8(plaintext)
        .map_err(|e| LegadoError::Parser(format!("UTF-8 decode error: {}", e)))
}

// ---------------------------------------------------------------------------
// 内部辅助
// ---------------------------------------------------------------------------

/// 构造用于加密的缓冲区（足够容纳 PKCS7 填充后的数据）
fn make_padded_buf(block_size: usize, data: &[u8]) -> Vec<u8> {
    let padded_len = ((data.len() / block_size) + 1) * block_size;
    let mut buf = vec![0u8; padded_len];
    buf[..data.len()].copy_from_slice(data);
    buf
}

fn crypto_init_err(e: impl std::fmt::Display) -> LegadoError {
    LegadoError::Parser(format!("Crypto init error: {}", e))
}

fn crypto_op_err(e: impl std::fmt::Display) -> LegadoError {
    LegadoError::Parser(format!("Crypto operation error: {}", e))
}

fn bad_key_len(algo: &str, got: usize, expected: &[usize]) -> LegadoError {
    LegadoError::Parser(format!(
        "{} key length must be {:?} bytes, got {}",
        algo, expected, got
    ))
}

// ---------------------------------------------------------------------------
// Transformation 解析
// ---------------------------------------------------------------------------

/// 解析 transformation 字符串，如 "AES/CBC/PKCS5Padding"
///
/// 返回 (algorithm, mode, padding) 三元组，algorithm 和 mode 为大写。
/// 对于无模式/填充的算法（如 "RC4"），允许单段格式，返回 ("RC4", "NONE", "NONE")。
pub fn parse_transformation(s: &str) -> Result<(String, String, String), String> {
    let parts: Vec<&str> = s.split('/').collect();
    match parts.len() {
        3 => Ok((
            parts[0].to_uppercase(),
            parts[1].to_uppercase(),
            parts[2].to_string(),
        )),
        1 => {
            // 单段格式，如 "RC4"、"AES"
            let algo = parts[0].to_uppercase();
            Ok((algo, "NONE".to_string(), "NONE".to_string()))
        }
        _ => Err(format!(
            "Invalid transformation: {}. Expected format: Algorithm/Mode/Padding or Algorithm",
            s
        )),
    }
}

/// 是否为 NoPadding（大小写不敏感）
fn is_no_padding(padding: &str) -> bool {
    padding.eq_ignore_ascii_case("NoPadding") || padding.eq_ignore_ascii_case("NONE")
}

/// 按 Java transformation 对称解密原始字节（对齐 hutool SymmetricCrypto.decrypt）
///
/// — Reasonix + Rust
pub fn symmetric_decrypt(
    transformation: &str,
    key: &[u8],
    iv: Option<&[u8]>,
    data: &[u8],
) -> LegadoResult<Vec<u8>> {
    let (algo, mode, padding) =
        parse_transformation(transformation).map_err(LegadoError::Parser)?;
    match algo.as_str() {
        "AES" => {
            let nopad = is_no_padding(&padding);
            match mode.as_str() {
                "CBC" => {
                    let iv =
                        iv.ok_or_else(|| LegadoError::Parser("AES/CBC requires IV".to_string()))?;
                    if nopad {
                        AesCrypto::decrypt_cbc_nopadding(key, iv, data)
                    } else {
                        AesCrypto::decrypt_cbc(key, iv, data)
                    }
                }
                "ECB" => {
                    if nopad {
                        AesCrypto::decrypt_ecb_nopadding(key, data)
                    } else {
                        AesCrypto::decrypt_ecb(key, data)
                    }
                }
                other => Err(LegadoError::Parser(format!(
                    "Unsupported AES mode: {other}"
                ))),
            }
        }
        "DES" => {
            let iv = iv.unwrap_or(b"\0\0\0\0\0\0\0\0");
            DesCrypto::decrypt_cbc(key, iv, data)
        }
        "RC4" => Ok(Rc4Crypto::process(key, data)),
        other => Err(LegadoError::Parser(format!(
            "Unsupported algorithm: {other}"
        ))),
    }
}

/// 按 Java transformation 对称加密原始字节（对齐 hutool SymmetricCrypto.encrypt）
///
/// — Reasonix + Rust
pub fn symmetric_encrypt(
    transformation: &str,
    key: &[u8],
    iv: Option<&[u8]>,
    data: &[u8],
) -> LegadoResult<Vec<u8>> {
    let (algo, mode, padding) =
        parse_transformation(transformation).map_err(LegadoError::Parser)?;
    match algo.as_str() {
        "AES" => {
            let nopad = is_no_padding(&padding);
            match mode.as_str() {
                "CBC" => {
                    let iv =
                        iv.ok_or_else(|| LegadoError::Parser("AES/CBC requires IV".to_string()))?;
                    if nopad {
                        AesCrypto::encrypt_cbc_nopadding(key, iv, data)
                    } else {
                        AesCrypto::encrypt_cbc(key, iv, data)
                    }
                }
                "ECB" => {
                    if nopad {
                        AesCrypto::encrypt_ecb_nopadding(key, data)
                    } else {
                        AesCrypto::encrypt_ecb(key, data)
                    }
                }
                other => Err(LegadoError::Parser(format!(
                    "Unsupported AES mode: {other}"
                ))),
            }
        }
        "DES" => {
            let iv = iv.unwrap_or(b"\0\0\0\0\0\0\0\0");
            DesCrypto::encrypt_cbc(key, iv, data)
        }
        "RC4" => Ok(Rc4Crypto::process(key, data)),
        other => Err(LegadoError::Parser(format!(
            "Unsupported algorithm: {other}"
        ))),
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // ---- AES-CBC ----

    #[test]
    fn test_aes_cbc_128_roundtrip() {
        let key = b"0123456789abcdef"; // 16 bytes = AES-128
        let iv = b"fedcba9876543210";
        let plaintext = b"Hello, Legado AES-CBC!";

        let ct = AesCrypto::encrypt_cbc(key, iv, plaintext).expect("encrypt");
        let pt = AesCrypto::decrypt_cbc(key, iv, &ct).expect("decrypt");
        assert_eq!(&pt, plaintext);
    }

    #[test]
    fn test_aes_cbc_256_roundtrip() {
        let key = b"0123456789abcdef0123456789abcdef"; // 32 bytes = AES-256
        let iv = b"fedcba9876543210";
        let plaintext = b"AES-256 CBC test data";

        let ct = AesCrypto::encrypt_cbc(key, iv, plaintext).expect("encrypt");
        let pt = AesCrypto::decrypt_cbc(key, iv, &ct).expect("decrypt");
        assert_eq!(&pt, plaintext);
    }

    #[test]
    fn test_aes_cbc_known_vector() {
        // NIST AES-128-CBC test vector (no padding - raw block)
        let key = hex_to_bytes("2b7e151628aed2a6abf7158809cf4f3c");
        let iv = hex_to_bytes("000102030405060708090a0b0c0d0e0f");
        let plaintext = hex_to_bytes("6bc1bee22e409f96e93d7e117393172a");

        let ct = AesCrypto::encrypt_cbc(&key, &iv, &plaintext).expect("encrypt");
        // 16-byte input + PKCS7 -> 32-byte output; first 16 bytes are the known CT
        let expected_ct_prefix = hex_to_bytes("7649abac8119b246cee98e9b12e9197d");
        assert_eq!(&ct[..16], &expected_ct_prefix[..]);
    }

    #[test]
    fn test_aes_cbc_bad_key_len() {
        let key = b"short";
        let iv = b"0123456789abcdef";
        let result = AesCrypto::encrypt_cbc(key, iv, b"data");
        assert!(result.is_err());
    }

    // ---- AES-ECB ----

    #[test]
    fn test_aes_ecb_128_roundtrip() {
        let key = b"0123456789abcdef";
        let plaintext = b"AES ECB roundtrip test data!";

        let ct = AesCrypto::encrypt_ecb(key, plaintext).expect("encrypt");
        let pt = AesCrypto::decrypt_ecb(key, &ct).expect("decrypt");
        assert_eq!(&pt, plaintext);
    }

    #[test]
    fn test_aes_ecb_known_vector() {
        // NIST AES-128-ECB single block
        let key = hex_to_bytes("2b7e151628aed2a6abf7158809cf4f3c");
        let plaintext = hex_to_bytes("6bc1bee22e409f96e93d7e117393172a");
        let expected_ct = hex_to_bytes("3ad77bb40d7a3660a89ecaf32466ef97");

        let ct = AesCrypto::encrypt_ecb(&key, &plaintext).expect("encrypt");
        assert_eq!(&ct[..16], &expected_ct[..]);
    }

    #[test]
    fn test_aes_ecb_nopadding_roundtrip() {
        let key = b"0123456789abcdef"; // AES-128
        let plaintext = b"legado ecb test!"; // 恰好 16 字节
        let ct = AesCrypto::encrypt_ecb_nopadding(key, plaintext).expect("encrypt");
        assert_eq!(ct.len(), 16);
        let pt = AesCrypto::decrypt_ecb_nopadding(key, &ct).expect("decrypt");
        assert_eq!(&pt, plaintext);
        // 经 symmetric_decrypt 分派路径
        let via = symmetric_decrypt("AES/ECB/NoPadding", key, None, &ct).expect("dispatch");
        assert_eq!(via, plaintext);
    }

    // ---- DES ----

    #[test]
    fn test_des_cbc_roundtrip() {
        let key = b"deskey01"; // 8 bytes
        let iv = b"initvec0";
        let plaintext = b"DES CBC test data for Legado";

        let ct = DesCrypto::encrypt_cbc(key, iv, plaintext).expect("encrypt");
        let pt = DesCrypto::decrypt_cbc(key, iv, &ct).expect("decrypt");
        assert_eq!(&pt, plaintext);
    }

    #[test]
    fn test_des_cbc_bad_key_len() {
        let key = b"short";
        let iv = b"initvec0";
        let result = DesCrypto::encrypt_cbc(key, iv, b"data");
        assert!(result.is_err());
    }

    // ---- RC4 ----

    #[test]
    fn test_rc4_symmetric() {
        let key = b"rc4secretkey";
        let plaintext = b"RC4 is a stream cipher";

        let ct = Rc4Crypto::process(key, plaintext);
        let pt = Rc4Crypto::process(key, &ct);
        assert_eq!(&pt, plaintext);
    }

    #[test]
    fn test_rc4_known_vector() {
        // RC4 test vector: Key = "Key", Plaintext = "Plaintext"
        // Expected ciphertext (hex): bbf316e8d940af0ad3
        let key = b"Key";
        let plaintext = b"Plaintext";
        let expected = hex_to_bytes("bbf316e8d940af0ad3");

        let ct = Rc4Crypto::process(key, plaintext);
        assert_eq!(ct, expected);
    }

    #[test]
    fn test_rc4_different_keys_produce_different_output() {
        let data = b"same data";
        let ct1 = Rc4Crypto::process(b"key1", data);
        let ct2 = Rc4Crypto::process(b"key2", data);
        assert_ne!(ct1, ct2);
    }

    // ---- Base64 + AES 组合 ----

    #[test]
    fn test_aes_base64_roundtrip() {
        let key = "0123456789abcdef"; // 16 bytes
        let iv = "fedcba9876543210";
        let plaintext = "Base64 + AES 组合测试";

        let encoded = aes_encrypt_base64(key, iv, plaintext).expect("encrypt");
        let decoded = aes_decrypt_base64(key, iv, &encoded).expect("decrypt");
        assert_eq!(decoded, plaintext);
    }

    #[test]
    fn test_aes_decrypt_base64_bad_input() {
        let result = aes_decrypt_base64("0123456789abcdef", "fedcba9876543210", "!!!invalid_b64");
        assert!(result.is_err());
    }

    // ---- parse_transformation ----

    #[test]
    fn test_parse_transformation_full() {
        let (algo, mode, padding) = parse_transformation("AES/CBC/PKCS5Padding").unwrap();
        assert_eq!(algo, "AES");
        assert_eq!(mode, "CBC");
        assert_eq!(padding, "PKCS5Padding");
    }

    #[test]
    fn test_parse_transformation_lowercase() {
        let (algo, mode, _padding) = parse_transformation("aes/ecb/NoPadding").unwrap();
        assert_eq!(algo, "AES");
        assert_eq!(mode, "ECB");
    }

    #[test]
    fn test_parse_transformation_des() {
        let (algo, mode, padding) = parse_transformation("DES/CBC/PKCS5Padding").unwrap();
        assert_eq!(algo, "DES");
        assert_eq!(mode, "CBC");
        assert_eq!(padding, "PKCS5Padding");
    }

    #[test]
    fn test_parse_transformation_single_segment() {
        let (algo, mode, padding) = parse_transformation("RC4").unwrap();
        assert_eq!(algo, "RC4");
        assert_eq!(mode, "NONE");
        assert_eq!(padding, "NONE");
    }

    #[test]
    fn test_parse_transformation_invalid_two_parts() {
        let result = parse_transformation("AES/CBC");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Invalid transformation"));
    }

    #[test]
    fn test_parse_transformation_invalid_four_parts() {
        let result = parse_transformation("AES/CBC/PKCS5/Extra");
        assert!(result.is_err());
    }

    /// AES/CBC/NoPadding 往返（对齐 51漫画 imageDecode）
    #[test]
    fn test_aes_cbc_nopadding_roundtrip() {
        let key = b"0123456789abcdef";
        let iv = b"fedcba9876543210";
        // 恰好 32 字节（两块）
        let plaintext = b"0123456789abcdef0123456789abcdef";
        let ct = AesCrypto::encrypt_cbc_nopadding(key, iv, plaintext).expect("encrypt");
        assert_eq!(ct.len(), 32);
        let pt = AesCrypto::decrypt_cbc_nopadding(key, iv, &ct).expect("decrypt");
        assert_eq!(&pt, plaintext);

        let via = symmetric_decrypt("AES/CBC/NoPadding", key, Some(iv), &ct).expect("dispatch");
        assert_eq!(&via, plaintext);
    }

    // ---- 辅助 ----

    fn hex_to_bytes(hex: &str) -> Vec<u8> {
        (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("hex"))
            .collect()
    }
}
