//! QuickJS 宿主 API 注册实现
//!
//! 在 `quickjs` feature 启用时，将 Legado 提供的宿主函数
//! 注册到 rquickjs 的全局上下文中，供 JS 脚本直接调用。
//!
//! 当前实现：
//! - 编解码 API：md5Encode, md5Encode16, base64Encode, base64Decode,
//!   base64DecodeToByteArray, hexEncode, hexDecode, sha256, encodeURI,
//!   hmacMd5, hmacSha256
//! - 字符串工具：urlencode, urldecode, trimStart, trimEnd,
//!   substringBefore, substringAfter, replaceFirst, replaceAll
//! - JSON 工具：jsonPath, jsonGetString, toJson
//! - 正则工具：regExp, regExpReplace, regExpFindAll
//! - 时间工具：formatTime, timeFormat, currentTimeMillis, parseTime, timeFormatUTC
//! - 文件工具：readFile, writeFile, fileExists, deleteFile, getTxtInFolder
//! - 变量存储：getVariable, setVariable, removeVariable, clearVariables
//! - 网络 API：httpGet, httpPost, httpHead, ajax, ajaxAll, connect, head, post
//! - 平台桥接：webView, webViewGetSource, webViewGetOverrideUrl, startBrowser,
//!   showBrowser, openUrl, getVerificationCode
//! - 压缩解压：unzipFile, getZipStringContent, un7zFile, unrarFile, get7zStringContent, getRarStringContent
//! - 字体 API：queryTTF, queryBase64TTF, replaceFont
//! - 工具类：randomUUID, log, toast, longToast, toURL

#![cfg(feature = "quickjs")]

use legado_core::LegadoError;

use crate::host_api::{
    archive_utils, asymmetric_crypto, chinese_utils, concurrency_api, config_api, cookie_store,
    crypto_api, encoding, file_utils, font_api, html_format, json_utils, misc_api, network,
    platform, regex_utils, register::mount_dual, string_utils, time_utils, variable_store,
};
use crate::sandbox::SandboxConfig;
use rquickjs::function::Opt;

/// 将所有宿主 API 注册到 QuickJS 全局上下文
///
/// 每个函数同时挂载到 `java` 命名空间对象和裸全局，
/// 确保 `java.md5Encode("hello")` 和 `md5Encode("hello")` 都能工作。
///
/// 根据 `SandboxConfig.allow_file_access` 决定是否注册文件 API；
/// network 与 cookie API 始终注册（经 legado-net 受控通道，保持书源对等）。
pub fn register_all_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    config: &SandboxConfig,
) -> Result<(), LegadoError> {
    let globals = ctx.globals();

    // 创建 java 命名空间对象
    let java =
        rquickjs::Object::new(ctx.clone()).map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    register_encoding_apis(ctx, &java, &globals)?;
    register_string_apis(ctx, &java, &globals)?;
    register_json_apis(ctx, &java, &globals)?;
    register_regex_apis(ctx, &java, &globals)?;
    register_time_apis(ctx, &java, &globals)?;
    // 文件 API 仅在 allow_file_access = true 时注册（安全门控）
    if config.allow_file_access {
        register_file_apis(ctx, &java, &globals)?;
    }
    register_variable_apis(ctx, &java, &globals)?;
    register_utility_apis(ctx, &java, &globals)?;
    register_network_apis(ctx, &java, &globals)?;
    register_cookie_apis(ctx, &java, &globals)?;
    register_crypto_apis(ctx, &java, &globals)?;
    register_html_apis(ctx, &java, &globals)?;
    register_chinese_apis(ctx, &java, &globals)?;
    register_config_apis(ctx, &java, &globals)?;
    register_concurrency_apis(ctx, &java, &globals)?;
    register_misc_apis(ctx, &java, &globals)?;
    register_archive_apis(ctx, &java, &globals)?;
    register_font_apis(ctx, &java, &globals)?;

    // 将 java 命名空间对象注册到全局
    globals
        .set("java", java)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    Ok(())
}

/// 注册编解码类 API
///
/// 对应 Kotlin 端 `JsEncodeUtils` + `JsExtensions` 中的编解码方法。
fn register_encoding_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // md5Encode(str) -> String（32 位）
    mount_dual(
        java,
        globals,
        "md5Encode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::md5_encode(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // md5Encode16(str) -> String（16 位）
    mount_dual(
        java,
        globals,
        "md5Encode16",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::md5_encode_16(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // base64Encode(str) -> String
    mount_dual(
        java,
        globals,
        "base64Encode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::base64_encode(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // base64Decode(str) -> String
    mount_dual(
        java,
        globals,
        "base64Decode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::base64_decode(&s).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // base64DecodeToByteArray(str, flags?) -> Uint8Array（字节数组）
    // 对应 Kotlin: base64DecodeToByteArray(str?, flags=0): ByteArray?
    // 空白输入返回 null（对齐 Kotlin 的 null 返回）；flags 兼容 Android URL_SAFE(8)
    mount_dual(
        java,
        globals,
        "base64DecodeToByteArray",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>, s: String, flags: Opt<i32>| -> rquickjs::Result<
                rquickjs::Value<'js>,
            > {
                use rquickjs::IntoJs;
                if s.trim().is_empty() {
                    // 对齐 Kotlin：isNullOrBlank -> null
                    return Ok(rquickjs::Value::new_null(ctx.clone()));
                }
                let bytes =
                    encoding::base64_decode_bytes_with_flags(&s, flags.0.unwrap_or(0))
                        .map_err(|e| rquickjs::Error::FromJs {
                            from: "String",
                            to: "Uint8Array",
                            message: Some(e),
                        })?;
                let arr: rquickjs::TypedArray<u8> = rquickjs::TypedArray::new(ctx.clone(), bytes)?;
                arr.into_js(&ctx)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hexEncode(str) -> String
    mount_dual(
        java,
        globals,
        "hexEncode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::hex_encode(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hexDecode(str) -> String
    mount_dual(
        java,
        globals,
        "hexDecode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::hex_decode(&s).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // sha256(str) -> String
    mount_dual(
        java,
        globals,
        "sha256",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String { encoding::sha256(&s) })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // encodeURI(str) -> String
    mount_dual(
        java,
        globals,
        "encodeURI",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::encode_uri(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // encodeURIComponent(str) -> String（JS 标准语义：保留 -_.!~*'()）
    // [UI-fix 2026-08-10 | Reasonix] 对齐原版 Rhino 内建：yckceo 书源
    // （思兔 sto66 等）searchUrl 模板 {{encodeURIComponent(key)}} 依赖此函数，
    // 缺失致表达式求值失败 → URL 残缺 → 搜索无结果
    mount_dual(
        java,
        globals,
        "encodeURIComponent",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::encode_uri_component(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hmacMd5(data, key) -> String
    mount_dual(
        java,
        globals,
        "hmacMd5",
        rquickjs::Function::new(ctx.clone(), |data: String, key: String| -> String {
            encoding::hmac_md5(&data, &key).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hmacSha256(data, key) -> String
    mount_dual(
        java,
        globals,
        "hmacSha256",
        rquickjs::Function::new(ctx.clone(), |data: String, key: String| -> String {
            encoding::hmac_sha256(&data, &key).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // digestHex(data, algorithm) -> String
    mount_dual(
        java,
        globals,
        "digestHex",
        rquickjs::Function::new(ctx.clone(), |data: String, algorithm: String| -> String {
            encoding::digest_hex(&data, &algorithm).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // digestBase64Str(data, algorithm) -> String
    mount_dual(
        java,
        globals,
        "digestBase64Str",
        rquickjs::Function::new(ctx.clone(), |data: String, algorithm: String| -> String {
            encoding::digest_base64_str(&data, &algorithm)
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hmacHex(data, algorithm, key) -> String
    mount_dual(
        java,
        globals,
        "hmacHex",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, algorithm: String, key: String| -> String {
                encoding::hmac_hex(&data, &algorithm, &key)
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hmacBase64(data, algorithm, key) -> String
    mount_dual(
        java,
        globals,
        "hmacBase64",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, algorithm: String, key: String| -> String {
                encoding::hmac_base64(&data, &algorithm, &key)
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // strToBytes(str, charset?) -> String (JSON array)
    mount_dual(
        java,
        globals,
        "strToBytes",
        rquickjs::Function::new(ctx.clone(), |s: String, charset: Opt<String>| -> String {
            encoding::str_to_bytes(&s, charset.0.as_deref())
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // bytesToStr(bytesJson, charset?) -> String
    mount_dual(
        java,
        globals,
        "bytesToStr",
        rquickjs::Function::new(
            ctx.clone(),
            |bytes_json: String, charset: Opt<String>| -> String {
                encoding::bytes_to_str(&bytes_json, charset.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册字符串工具 API
fn register_string_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "urlencode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            string_utils::urlencode(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "urldecode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            string_utils::urldecode(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "trimStart",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            string_utils::trim_start(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "trimEnd",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            string_utils::trim_end(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "substringBefore",
        rquickjs::Function::new(ctx.clone(), |s: String, d: String| -> String {
            string_utils::substring_before(&s, &d).to_string()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "substringAfter",
        rquickjs::Function::new(ctx.clone(), |s: String, d: String| -> String {
            string_utils::substring_after(&s, &d).to_string()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "replaceFirst",
        rquickjs::Function::new(
            ctx.clone(),
            |s: String, old: String, new: String| -> String {
                string_utils::replace_first(&s, &old, &new)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "replaceAll",
        rquickjs::Function::new(
            ctx.clone(),
            |s: String, old: String, new: String| -> String {
                string_utils::replace_all(&s, &old, &new)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // toNumChapter(s) -> String
    mount_dual(
        java,
        globals,
        "toNumChapter",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            string_utils::to_num_chapter(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册 JSON 工具 API
fn register_json_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "jsonPath",
        rquickjs::Function::new(ctx.clone(), |json: String, path: String| -> String {
            match json_utils::json_path(&json, &path) {
                Ok(results) => results.join("\n"),
                Err(e) => format!("[ERROR] {}", e),
            }
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "jsonGetString",
        rquickjs::Function::new(ctx.clone(), |json: String, key: String| -> String {
            json_utils::json_get_string(&json, &key).unwrap_or_default()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "toJson",
        rquickjs::Function::new(ctx.clone(), |json: String| -> String {
            json_utils::to_json(&json).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册正则工具 API
fn register_regex_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "regExp",
        rquickjs::Function::new(
            ctx.clone(),
            |text: String, pattern: String, group: i32| -> String {
                regex_utils::reg_exp(&text, &pattern, group as usize).unwrap_or_default()
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "regExpReplace",
        rquickjs::Function::new(
            ctx.clone(),
            |text: String, pattern: String, replacement: String| -> String {
                regex_utils::reg_exp_replace(&text, &pattern, &replacement)
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "regExpFindAll",
        rquickjs::Function::new(ctx.clone(), |text: String, pattern: String| -> String {
            regex_utils::reg_exp_find_all(&text, &pattern)
                .map(|v| v.join("\n"))
                .unwrap_or_default()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册时间工具 API
fn register_time_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "formatTime",
        rquickjs::Function::new(ctx.clone(), |ts: i64, format: String| -> String {
            let fmt = if format.is_empty() {
                None
            } else {
                Some(format.as_str())
            };
            time_utils::format_time(ts, fmt).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // timeFormat(ts) -> String
    // 对应 Kotlin: timeFormat(time: Long)，格式为 AppConst.dateFormat "yyyy/MM/dd HH:mm"。
    // 保留上方 formatTime(ts, format) 注册名，兼容已按该名调用的现有书源。
    mount_dual(
        java,
        globals,
        "timeFormat",
        rquickjs::Function::new(ctx.clone(), |ts: i64| -> String {
            time_utils::format_time(ts, Some("%Y/%m/%d %H:%M"))
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "timeFormatUTC",
        rquickjs::Function::new(
            ctx.clone(),
            |ts: i64, format: String, offset_secs: i32| -> String {
                let fmt = if format.is_empty() {
                    None
                } else {
                    Some(format.as_str())
                };
                time_utils::format_time_utc(ts, fmt, offset_secs)
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "currentTimeMillis",
        rquickjs::Function::new(ctx.clone(), || -> i64 { time_utils::current_time_millis() })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "parseTime",
        rquickjs::Function::new(ctx.clone(), |time_str: String, format: String| -> i64 {
            let fmt = if format.is_empty() {
                None
            } else {
                Some(format.as_str())
            };
            time_utils::parse_time(&time_str, fmt).unwrap_or(-1)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册文件工具 API
fn register_file_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "readFile",
        rquickjs::Function::new(ctx.clone(), |path: String| -> String {
            file_utils::read_file(&path).unwrap_or_default()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "writeFile",
        rquickjs::Function::new(ctx.clone(), |path: String, content: String| -> bool {
            file_utils::write_file(&path, &content).is_ok()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "fileExists",
        rquickjs::Function::new(ctx.clone(), |path: String| -> bool {
            file_utils::file_exists(&path).unwrap_or(false)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "deleteFile",
        rquickjs::Function::new(ctx.clone(), |path: String| -> bool {
            file_utils::delete_file(&path).unwrap_or(false)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // readTxtFile(path, charset?) -> String
    mount_dual(
        java,
        globals,
        "readTxtFile",
        rquickjs::Function::new(
            ctx.clone(),
            |path: String, charset: Opt<String>| -> String {
                file_utils::read_txt_file(&path, charset.0.as_deref()).unwrap_or_default()
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // downloadFile(url, fileName?) -> String
    mount_dual(
        java,
        globals,
        "downloadFile",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, file_name: Opt<String>| -> String {
                file_utils::download_file(&url, file_name.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // cacheFile(url) -> String
    mount_dual(
        java,
        globals,
        "cacheFile",
        rquickjs::Function::new(ctx.clone(), |url: String| -> String {
            file_utils::cache_file(&url).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // importScript(url) -> String
    mount_dual(
        java,
        globals,
        "importScript",
        rquickjs::Function::new(ctx.clone(), |url: String| -> String {
            file_utils::import_script(&url).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getTxtInFolder(folderPath) -> String
    mount_dual(
        java,
        globals,
        "getTxtInFolder",
        rquickjs::Function::new(ctx.clone(), |folder_path: String| -> String {
            file_utils::get_txt_in_folder(&folder_path).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册变量存取 API
fn register_variable_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "getVariable",
        rquickjs::Function::new(ctx.clone(), |key: String| -> String {
            variable_store::get_variable(&key)
                .ok()
                .flatten()
                .unwrap_or_default()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "setVariable",
        rquickjs::Function::new(ctx.clone(), |key: String, value: String| -> bool {
            variable_store::set_variable(&key, &value).is_ok()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "removeVariable",
        rquickjs::Function::new(ctx.clone(), |key: String| -> bool {
            variable_store::remove_variable(&key)
                .ok()
                .flatten()
                .is_some()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "clearVariables",
        rquickjs::Function::new(ctx.clone(), || -> bool {
            variable_store::clear_variables().is_ok()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册工具类 API
fn register_utility_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // randomUUID() -> String
    mount_dual(
        java,
        globals,
        "randomUUID",
        rquickjs::Function::new(ctx.clone(), || -> String {
            uuid::Uuid::new_v4().to_string()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // log(msg) -> msg（打印并返回）
    mount_dual(
        java,
        globals,
        "log",
        rquickjs::Function::new(ctx.clone(), |msg: String| -> String {
            eprintln!("[legado-js] {}", msg);
            msg
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册网络类 API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 ajax/ajaxAll/connect/get/post/head 等方法。
fn register_network_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // httpGet(url, headers?) -> String
    mount_dual(
        java,
        globals,
        "httpGet",
        rquickjs::Function::new(ctx.clone(), |url: String, headers: Opt<String>| -> String {
            network::http_get(&url, headers.0.as_deref())
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // httpPost(url, body, headers?) -> String
    mount_dual(
        java,
        globals,
        "httpPost",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, body: String, headers: Opt<String>| -> String {
                network::http_post(&url, &body, headers.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // httpHead(url) -> String（响应头 JSON）
    mount_dual(
        java,
        globals,
        "httpHead",
        rquickjs::Function::new(ctx.clone(), |url: String| -> String {
            network::http_head(&url).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // ajax(options_json) -> String（HttpResponse JSON）
    mount_dual(
        java,
        globals,
        "ajax",
        rquickjs::Function::new(ctx.clone(), |options: String| -> String {
            network::ajax(&options).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // ajaxAll(urls_json) -> String（JSON 数组，并发请求多个 URL）
    // 对应 Kotlin: ajaxAll(urlList: Array<String>): Array<StrResponse>
    mount_dual(
        java,
        globals,
        "ajaxAll",
        rquickjs::Function::new(ctx.clone(), |urls: String| -> String {
            network::ajax_all(&urls).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // connect(url, method?, headers?, body?, timeoutMs?) -> String（完整响应 JSON）
    // 对应 Kotlin: connect(urlStr, header, callTimeout): StrResponse
    // 增强：支持指定 HTTP 方法（GET/POST/HEAD/PUT/DELETE）
    mount_dual(
        java,
        globals,
        "connect",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String,
             method: Opt<String>,
             headers: Opt<String>,
             body: Opt<String>,
             timeout_ms: Opt<i64>| -> String {
                network::connect_full(
                    &url,
                    method.0.as_deref(),
                    headers.0.as_deref(),
                    body.0.as_deref(),
                    timeout_ms.0.map(|t| t as u64),
                )
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // head(url, headers?) -> String（完整响应 JSON）
    // 对应 Kotlin: head(urlStr, headers): Connection.Response
    mount_dual(
        java,
        globals,
        "head",
        rquickjs::Function::new(ctx.clone(), |url: String, headers: Opt<String>| -> String {
            network::head_full(&url, headers.0.as_deref())
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // post(url, body, headers?) -> String（完整响应 JSON）
    // 对应 Kotlin: post(urlStr, body, headers): Connection.Response
    mount_dual(
        java,
        globals,
        "post",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, body: String, headers: Opt<String>| -> String {
                network::post_full(&url, &body, headers.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册 Cookie API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 getCookie/setCookie/clearCookies 方法。
fn register_cookie_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // getCookie(tag, key?) -> String
    mount_dual(
        java,
        globals,
        "getCookie",
        rquickjs::Function::new(ctx.clone(), |tag: String, key: Opt<String>| -> String {
            match key.0 {
                Some(k) => cookie_store::get_cookie_by_key(&tag, &k),
                None => cookie_store::get_cookie(&tag),
            }
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // setCookie(tag, cookieStr) -> bool
    // cookieStr 格式: "key=value" 或 "key=value; key2=value2"
    mount_dual(
        java,
        globals,
        "setCookie",
        rquickjs::Function::new(ctx.clone(), |tag: String, cookie_str: String| -> bool {
            for pair in cookie_str.split(';') {
                let pair = pair.trim();
                if let Some(eq_pos) = pair.find('=') {
                    let key = pair[..eq_pos].trim();
                    let value = pair[eq_pos + 1..].trim();
                    if !key.is_empty() {
                        cookie_store::set_cookie(&tag, key, value);
                    }
                }
            }
            true
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // clearCookies(tag) -> bool
    mount_dual(
        java,
        globals,
        "clearCookies",
        rquickjs::Function::new(ctx.clone(), |tag: String| -> bool {
            cookie_store::clear_cookies(&tag);
            true
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册加密 API
///
/// 对应 Kotlin 端 `JsEncodeUtils` + `JsExtensions` 中的 AES/DES/RC4 加解密方法。
fn register_crypto_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // aesEncrypt(data, key, iv?) -> String
    mount_dual(
        java,
        globals,
        "aesEncrypt",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, key: String, iv: Opt<String>| -> String {
                crypto_api::aes_encrypt(&data, &key, iv.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // aesDecrypt(data, key, iv?) -> String
    mount_dual(
        java,
        globals,
        "aesDecrypt",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, key: String, iv: Opt<String>| -> String {
                crypto_api::aes_decrypt(&data, &key, iv.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // desEncrypt(data, key, iv?) -> String
    mount_dual(
        java,
        globals,
        "desEncrypt",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, key: String, iv: Opt<String>| -> String {
                crypto_api::des_encrypt(&data, &key, iv.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // desDecrypt(data, key, iv?) -> String
    mount_dual(
        java,
        globals,
        "desDecrypt",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, key: String, iv: Opt<String>| -> String {
                crypto_api::des_decrypt(&data, &key, iv.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // rc4Encrypt(data, key) -> String
    mount_dual(
        java,
        globals,
        "rc4Encrypt",
        rquickjs::Function::new(ctx.clone(), |data: String, key: String| -> String {
            crypto_api::rc4_encrypt(&data, &key).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // rc4Decrypt(data, key) -> String
    mount_dual(
        java,
        globals,
        "rc4Decrypt",
        rquickjs::Function::new(ctx.clone(), |data: String, key: String| -> String {
            crypto_api::rc4_decrypt(&data, &key).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // createSymmetricCrypto(transformation, key, iv?) -> String
    mount_dual(
        java,
        globals,
        "createSymmetricCrypto",
        rquickjs::Function::new(
            ctx.clone(),
            |transformation: String, key: String, iv: Opt<String>| -> String {
                crypto_api::create_symmetric_crypto(&transformation, &key, iv.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // createAsymmetricCrypto(transformation) -> RSA 对象
    // 对应 Kotlin JsEncodeUtils.createAsymmetricCrypto（AsymmetricCrypto）
    // 返回对象含 setPublicKey/setPrivateKey/encrypt/encryptHex/encryptBase64/decrypt/decryptStr
    mount_dual(
        java,
        globals,
        "createAsymmetricCrypto",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             transformation: String|
             -> rquickjs::Result<rquickjs::Object<'js>> {
                asymmetric_crypto::build_asymmetric_crypto_object(ctx, &transformation)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // createSign(algorithm) -> 签名对象
    // 对应 Kotlin JsEncodeUtils.createSign（Sign / hutool Sign）
    // 返回对象含 setPublicKey/setPrivateKey/sign/signHex/signBase64/verify
    mount_dual(
        java,
        globals,
        "createSign",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             algorithm: String|
             -> rquickjs::Result<rquickjs::Object<'js>> {
                asymmetric_crypto::build_sign_object(ctx, &algorithm)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册 HTML 格式化 API
///
/// 对应 Kotlin 端 `HtmlFormatter` 中的格式化方法。
fn register_html_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // htmlFormat(html) -> String
    mount_dual(
        java,
        globals,
        "htmlFormat",
        rquickjs::Function::new(ctx.clone(), |html: String| -> String {
            html_format::html_format(&html)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // htmlFormatWithTags(html, keepTags?) -> String
    mount_dual(
        java,
        globals,
        "htmlFormatWithTags",
        rquickjs::Function::new(
            ctx.clone(),
            |html: String, keep_tags: Opt<String>| -> String {
                html_format::html_format_with_tags(&html, keep_tags.0.as_deref())
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册中文工具 API
///
/// 对应 Kotlin 端 `ChineseUtils` 中的繁简转换方法。
fn register_chinese_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // t2s(text) -> String
    mount_dual(
        java,
        globals,
        "t2s",
        rquickjs::Function::new(ctx.clone(), |text: String| -> String {
            chinese_utils::t2s(&text)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // s2t(text) -> String
    mount_dual(
        java,
        globals,
        "s2t",
        rquickjs::Function::new(ctx.clone(), |text: String| -> String {
            chinese_utils::s2t(&text)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册配置读取 API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 getReadBookConfig / getThemeConfig / getThemeMode /
/// getWebViewUA / androidId 等方法。
fn register_config_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // getReadBookConfig() -> String
    mount_dual(
        java,
        globals,
        "getReadBookConfig",
        rquickjs::Function::new(ctx.clone(), || -> String {
            config_api::get_read_book_config()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getThemeConfig() -> String
    mount_dual(
        java,
        globals,
        "getThemeConfig",
        rquickjs::Function::new(ctx.clone(), || -> String { config_api::get_theme_config() })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getThemeMode() -> String
    mount_dual(
        java,
        globals,
        "getThemeMode",
        rquickjs::Function::new(ctx.clone(), || -> String { config_api::get_theme_mode() })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getWebViewUA() -> String
    mount_dual(
        java,
        globals,
        "getWebViewUA",
        rquickjs::Function::new(ctx.clone(), || -> String { config_api::get_web_view_ua() })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // androidId() -> String
    mount_dual(
        java,
        globals,
        "androidId",
        rquickjs::Function::new(ctx.clone(), || -> String { config_api::get_android_id() })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册并发控制 API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 singleFlight / lock / tick 方法。
fn register_concurrency_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // singleFlight(key, waitMs, fJs) -> String
    mount_dual(
        java,
        globals,
        "singleFlight",
        rquickjs::Function::new(
            ctx.clone(),
            |key: String, wait_ms: i64, f_js: String| -> String {
                concurrency_api::single_flight(key, wait_ms, f_js)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // lock(key, waitMs) -> Boolean
    mount_dual(
        java,
        globals,
        "lock",
        rquickjs::Function::new(ctx.clone(), |key: String, wait_ms: i64| -> bool {
            concurrency_api::lock(key, wait_ms)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // tick(key) -> Int
    mount_dual(
        java,
        globals,
        "tick",
        rquickjs::Function::new(ctx.clone(), |key: String| -> i64 {
            concurrency_api::tick(key)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册杂项 API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 getSource / getTag /
/// ajaxTestAll / toUrl / toast / logType 等方法，
/// 以及需要平台能力的桥接 API（webView / startBrowser / openUrl 等）。
fn register_misc_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // getSource(sourceUrl) -> String
    mount_dual(
        java,
        globals,
        "getSource",
        rquickjs::Function::new(ctx.clone(), |source_url: String| -> String {
            misc_api::get_source(&source_url)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getTag(tagName) -> String
    mount_dual(
        java,
        globals,
        "getTag",
        rquickjs::Function::new(ctx.clone(), |tag_name: String| -> String {
            misc_api::get_tag(&tag_name)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // ajaxTestAll(urls) -> String
    mount_dual(
        java,
        globals,
        "ajaxTestAll",
        rquickjs::Function::new(ctx.clone(), |urls: String| -> String {
            misc_api::ajax_test_all(&urls)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // toUrl(path, query) -> String
    mount_dual(
        java,
        globals,
        "toUrl",
        rquickjs::Function::new(ctx.clone(), |path: String, query: Opt<String>| -> String {
            misc_api::to_url(&path, query.0.as_deref().unwrap_or(""))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // toast(msg) -> String
    mount_dual(
        java,
        globals,
        "toast",
        rquickjs::Function::new(ctx.clone(), |msg: String| -> String {
            misc_api::toast(&msg)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // longToast(msg) -> String
    // 对应 Kotlin: longToast(msg)（长停留 toast）；
    // 与现有 toast 处理保持一致：stderr 日志输出 + 原样返回
    mount_dual(
        java,
        globals,
        "longToast",
        rquickjs::Function::new(ctx.clone(), |msg: String| -> String {
            misc_api::long_toast(&msg)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // toURL(urlStr, baseUrl?) -> Object（JsURL）
    // 对应 Kotlin: toURL(urlStr, baseUrl?) -> JsURL（host/origin/pathname/searchParams）
    mount_dual(
        java,
        globals,
        "toURL",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             url_str: String,
             base_url: Opt<String>|
             -> rquickjs::Result<rquickjs::Object<'js>> {
                let parts = misc_api::parse_js_url(&url_str, base_url.0.as_deref().unwrap_or(""))
                    .map_err(|e| rquickjs::Error::FromJs {
                        from: "String",
                        to: "Object<JsURL>",
                        message: Some(e),
                    })?;
                let obj = rquickjs::Object::new(ctx.clone())?;
                obj.set("host", parts.host)?;
                obj.set("origin", parts.origin)?;
                obj.set("pathname", parts.pathname)?;
                match parts.search_params {
                    Some(params) => {
                        let map = rquickjs::Object::new(ctx.clone())?;
                        for (k, v) in params {
                            map.set(k, v)?;
                        }
                        obj.set("searchParams", map)?;
                    }
                    None => {
                        // 对齐 Kotlin JsURL：无 query 时 searchParams 为 null
                        obj.set("searchParams", rquickjs::Null)?;
                    }
                }
                Ok(obj)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // logType(value) -> String
    mount_dual(
        java,
        globals,
        "logType",
        rquickjs::Function::new(ctx.clone(), |value: String| -> String {
            misc_api::log_type(&value)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // openVideoPlayer(url, title?, isFloat?) -> String
    // 对齐 Kotlin JsExtensions.openVideoPlayer：返回结构化桥接载荷，
    // 由 Flutter / 平台侧拦截并拉起内置视频播放器。
    mount_dual(
        java,
        globals,
        "openVideoPlayer",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, title: Opt<String>, is_float: Opt<bool>| -> String {
                platform::open_video_player(
                    &url,
                    title.0.as_deref().unwrap_or(""),
                    is_float.0.unwrap_or(false),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // webView(html?, url?, js?) -> String（桥接载荷）
    // 对应 Kotlin: webView(html, url, js): String?
    // Rust 无头运行时返回结构化桥接载荷，由 Flutter 侧使用真实 WebView 处理
    mount_dual(
        java,
        globals,
        "webView",
        rquickjs::Function::new(
            ctx.clone(),
            |html: Opt<String>, url: Opt<String>, js: Opt<String>| -> String {
                platform::web_view(
                    html.0.as_deref().unwrap_or(""),
                    url.0.as_deref().unwrap_or(""),
                    js.0.as_deref().unwrap_or(""),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // webViewGetSource(html?, url?, js?, sourceRegex?) -> String（桥接载荷）
    // 对应 Kotlin: webViewGetSource(html, url, js, sourceRegex): String?
    mount_dual(
        java,
        globals,
        "webViewGetSource",
        rquickjs::Function::new(
            ctx.clone(),
            |html: Opt<String>,
             url: Opt<String>,
             js: Opt<String>,
             source_regex: Opt<String>|
             -> String {
                platform::web_view_get_source(
                    html.0.as_deref().unwrap_or(""),
                    url.0.as_deref().unwrap_or(""),
                    js.0.as_deref().unwrap_or(""),
                    source_regex.0.as_deref().unwrap_or(""),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // webViewGetOverrideUrl(html?, url?, js?, overrideUrlRegex, cacheFirst?, delayTime?)
    // -> String（桥接载荷）
    // 对应 Kotlin: webViewGetOverrideUrl(html, url, js, overrideUrlRegex, cacheFirst, delayTime)
    // Rust 无头运行时返回桥接载荷，由 Flutter 侧用真实 WebView 拦截跳转 URL
    mount_dual(
        java,
        globals,
        "webViewGetOverrideUrl",
        rquickjs::Function::new(
            ctx.clone(),
            |html: Opt<String>,
             url: Opt<String>,
             js: Opt<String>,
             override_url_regex: String,
             cache_first: Opt<bool>,
             delay_time: Opt<i64>|
             -> String {
                platform::web_view_get_override_url(
                    html.0.as_deref().unwrap_or(""),
                    url.0.as_deref().unwrap_or(""),
                    js.0.as_deref().unwrap_or(""),
                    &override_url_regex,
                    cache_first.0.unwrap_or(false),
                    delay_time.0.unwrap_or(0),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // showBrowser(url, html?, preloadJs?, config?) -> String（桥接载荷）
    // 对应 Kotlin: showBrowser(url, html, preloadJs, config)（应用内 WebView 对话框）；
    // Rust 无头运行时返回 {"action":"openBrowser",...}，由 Flutter 侧拦截并打开浏览器
    mount_dual(
        java,
        globals,
        "showBrowser",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String,
             html: Opt<String>,
             preload_js: Opt<String>,
             config: Opt<String>|
             -> String {
                platform::show_browser(
                    &url,
                    html.0.as_deref().unwrap_or(""),
                    preload_js.0.as_deref().unwrap_or(""),
                    config.0.as_deref().unwrap_or(""),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // startBrowser(url, title?, html?) -> String（桥接载荷）
    // 对应 Kotlin: startBrowser(url, title, html?)
    mount_dual(
        java,
        globals,
        "startBrowser",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, title: Opt<String>, html: Opt<String>| -> String {
                platform::start_browser(
                    &url,
                    title.0.as_deref().unwrap_or(""),
                    html.0.as_deref().unwrap_or(""),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // openUrl(url, mimeType?) -> String（桥接载荷）
    // 对应 Kotlin: openUrl(url, mimeType?)
    mount_dual(
        java,
        globals,
        "openUrl",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, mime_type: Opt<String>| -> String {
                platform::open_url(&url, mime_type.0.as_deref().unwrap_or(""))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getVerificationCode(imageUrl) -> String（验证码交互通道，阻塞等待用户输入）
    // 对应 Kotlin: getVerificationCode(imageUrl): String
    mount_dual(
        java,
        globals,
        "getVerificationCode",
        rquickjs::Function::new(ctx.clone(), |image_url: String| -> String {
            platform::get_verification_code(&image_url)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // startBrowserAwait(url, title, refetchAfterSuccess?, html?) -> String
    // 对应 Kotlin: startBrowserAwait 三个重载（useBrowser=true）；
    // 桌面端无内置浏览器，一律降级为图片验证码流程（Task #90）
    mount_dual(
        java,
        globals,
        "startBrowserAwait",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String,
             title: Opt<String>,
             _refetch_after_success: Opt<bool>,
             _html: Opt<String>|
             -> String {
                platform::start_browser_await(&url, title.0.as_deref().unwrap_or(""))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册压缩解压 API
///
/// 对应 Kotlin 端 `JsExtensions` / `ArchiveUtils` 中的
/// unzipFile / getZipStringContent / un7zFile / unrarFile /
/// get7zStringContent / getRarStringContent 方法。
fn register_archive_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // unzipFile(zipPath) -> String（解压目标目录）
    // 对应 Kotlin: unzipFile(zipPath) -> unArchiveFile(zipPath)（自动检测压缩格式）；
    // 空路径返回空串（对齐 Kotlin）
    mount_dual(
        java,
        globals,
        "unzipFile",
        rquickjs::Function::new(ctx.clone(), |zip_path: String| -> String {
            if zip_path.is_empty() {
                return String::new();
            }
            archive_utils::un_archive_file(&zip_path, None)
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getZipStringContent(url, path, charsetName?) -> String
    // 对应 Kotlin: getZipStringContent(url, path[, charsetName])；
    // url 可为本地 ZIP 路径 / 网络 URL / 十六进制字符串；失败返回空串（对齐 Kotlin）
    mount_dual(
        java,
        globals,
        "getZipStringContent",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, entry: String, charset: Opt<String>| -> String {
                get_zip_string_content_js(&url, &entry, charset.0.as_deref())
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // un7zFile(7zPath, outputPath?) -> String（解压目标目录）
    // 使用 sevenz-rust2 纯 Rust 实现解压 7z 格式
    mount_dual(
        java,
        globals,
        "un7zFile",
        rquickjs::Function::new(
            ctx.clone(),
            |seven_z_path: String, output_path: Opt<String>| -> String {
                archive_utils::un7z_file(&seven_z_path, output_path.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // unrarFile(rarPath, outputPath?) -> String
    // 纯 Rust RAR4/RAR5 解压（rar crate），失败返回 [ERROR] 前缀错误信息
    mount_dual(
        java,
        globals,
        "unrarFile",
        rquickjs::Function::new(
            ctx.clone(),
            |rar_path: String, output_path: Opt<String>| -> String {
                archive_utils::unrar_file(&rar_path, output_path.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // get7zStringContent(url, path, charsetName?) -> String
    // 对应 Kotlin: get7zStringContent(url, path[, charsetName])；
    // url 可为本地 7z 路径 / 网络 URL / 十六进制字符串；失败返回空串（对齐 Kotlin）
    mount_dual(
        java,
        globals,
        "get7zStringContent",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, entry: String, charset: Opt<String>| -> String {
                get_7z_string_content_js(&url, &entry, charset.0.as_deref())
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getRarStringContent(url, path, charsetName?) -> String
    // 对应 Kotlin: getRarStringContent(url, path[, charsetName])；
    // url 可为本地 RAR 路径 / 网络 URL / 十六进制字符串；失败返回空串（对齐 Kotlin）
    mount_dual(
        java,
        globals,
        "getRarStringContent",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, entry: String, charset: Opt<String>| -> String {
                get_rar_string_content_js(&url, &entry, charset.0.as_deref())
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// getZipStringContent 的 JS 入口实现：解析 ZIP 来源并读取指定条目的字符串内容
///
/// 对应 Kotlin `getZipByteArrayContent` + `getZipStringContent`：
/// - 绝对 URL → 经 legado-net 下载 ZIP 字节
/// - 本地存在的文件路径 → 直接读取
/// - 其余按十六进制字符串解码
/// 失败时记录日志并返回空串（对齐 Kotlin `log("getZipContent 未发现内容")` + `return ""`）
fn get_zip_string_content_js(url: &str, entry: &str, charset: Option<&str>) -> String {
    let bytes = match resolve_zip_bytes(url) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("[getZipStringContent] ZIP 来源解析失败: {e}");
            return String::new();
        }
    };
    match archive_utils::zip_entry_bytes(&bytes, entry) {
        Ok(b) => decode_bytes_with_charset(&b, charset),
        Err(e) => {
            eprintln!("[getZipStringContent] {e}");
            String::new()
        }
    }
}

/// 解析 getZipStringContent 的 ZIP 来源为字节数据
fn resolve_zip_bytes(source: &str) -> Result<Vec<u8>, String> {
    resolve_archive_bytes(source, "ZIP")
}

/// get7zStringContent 的 JS 入口实现：解析 7z 来源并读取指定条目的字符串内容
///
/// 对应 Kotlin `get7zByteArrayContent` + `get7zStringContent`；
/// 失败时记录日志并返回空串（对齐 Kotlin `?: return ""`）
fn get_7z_string_content_js(url: &str, entry: &str, charset: Option<&str>) -> String {
    let bytes = match resolve_archive_bytes(url, "7z") {
        Ok(b) => b,
        Err(e) => {
            eprintln!("[get7zStringContent] 7z 来源解析失败: {e}");
            return String::new();
        }
    };
    match archive_utils::seven_z_entry_bytes(&bytes, entry) {
        Ok(b) => decode_bytes_with_charset(&b, charset),
        Err(e) => {
            eprintln!("[get7zStringContent] {e}");
            String::new()
        }
    }
}

/// getRarStringContent 的 JS 入口实现：解析 RAR 来源并读取指定条目的字符串内容
///
/// 对应 Kotlin `getRarByteArrayContent` + `getRarStringContent`；
/// 失败时记录日志并返回空串（对齐 Kotlin `?: return ""`）
fn get_rar_string_content_js(url: &str, entry: &str, charset: Option<&str>) -> String {
    let bytes = match resolve_archive_bytes(url, "RAR") {
        Ok(b) => b,
        Err(e) => {
            eprintln!("[getRarStringContent] RAR 来源解析失败: {e}");
            return String::new();
        }
    };
    match archive_utils::rar_entry_bytes(&bytes, entry) {
        Ok(b) => decode_bytes_with_charset(&b, charset),
        Err(e) => {
            eprintln!("[getRarStringContent] {e}");
            String::new()
        }
    }
}

/// 解析压缩档案来源为字节数据（ZIP / 7z / RAR 共用）
fn resolve_archive_bytes(source: &str, kind: &str) -> Result<Vec<u8>, String> {
    // 网络 URL：经 legado-net 二进制通道下载（尽力支持；
    // legado-net 响应体当前经 String 中转，纯二进制压缩包可能受影响）
    if source.starts_with("http://") || source.starts_with("https://") {
        use crate::host_api::runtime_bridge::block_on;
        use legado_net::{LegadoClient, LegadoClientConfig};
        return block_on(async {
            let client = LegadoClient::new(LegadoClientConfig::default())
                .map_err(|e| format!("网络客户端初始化失败: {e}"))?;
            client
                .get_bytes(source, None)
                .await
                .map_err(|e| format!("{kind} 下载失败: {e}"))
        });
    }
    // 本地文件路径
    let path = std::path::Path::new(source);
    if path.exists() {
        return std::fs::read(path).map_err(|e| format!("读取本地 {kind} 文件失败: {e}"));
    }
    // 十六进制字符串（对齐 Kotlin HexUtil.decodeHex 分支）
    hex::decode(source).map_err(|e| format!("十六进制 {kind} 数据解析失败: {e}"))
}

/// 按指定字符集解码 ZIP 条目字节
///
/// Kotlin 侧默认用 EncodingDetect 自动探测编码；Rust 侧未指定字符集时
/// 优先按严格 UTF-8 解码，非法则 lossy 回退；指定字符集时用 encoding_rs 解码
fn decode_bytes_with_charset(bytes: &[u8], charset: Option<&str>) -> String {
    match charset {
        Some(cs) if !cs.trim().is_empty() => {
            match encoding_rs::Encoding::for_label(cs.trim().as_bytes()) {
                Some(enc) => {
                    let (decoded, _, _) = enc.decode(bytes);
                    decoded.into_owned()
                }
                None => String::from_utf8_lossy(bytes).into_owned(),
            }
        }
        _ => String::from_utf8(bytes.to_vec())
            .unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned()),
    }
}

/// 注册字体 API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 queryTTF / queryBase64TTF / replaceFont 方法。
fn register_font_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // queryTTF(data, useCache?) -> String（字体句柄 JSON）
    // 对应 Kotlin: queryTTF(data: Any?, useCache: Boolean): QueryTTF?
    mount_dual(
        java,
        globals,
        "queryTTF",
        rquickjs::Function::new(ctx.clone(), |data: String, use_cache: Opt<bool>| -> String {
            font_api::query_ttf(&data, use_cache.0.unwrap_or(true))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // queryBase64TTF(data) -> String（已废弃，等价于 queryTTF）
    // 对应 Kotlin: @Deprecated queryBase64TTF(data): QueryTTF?
    mount_dual(
        java,
        globals,
        "queryBase64TTF",
        rquickjs::Function::new(ctx.clone(), |data: String| -> String {
            font_api::query_base64_ttf(&data)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // replaceFont(text, errorFontData, correctFontData, filter?) -> String
    // 对应 Kotlin: replaceFont(text, errorQueryTTF, correctQueryTTF, filter): String
    mount_dual(
        java,
        globals,
        "replaceFont",
        rquickjs::Function::new(
            ctx.clone(),
            |text: String,
             error_font: String,
             correct_font: String,
             filter: Opt<bool>|
             -> String {
                font_api::replace_font(
                    &text,
                    &error_font,
                    &correct_font,
                    filter.0.unwrap_or(false),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::engine::{JsEngine, QuickJsEngine};
    use crate::sandbox::SandboxConfig;

    fn make_engine() -> QuickJsEngine {
        QuickJsEngine::new(SandboxConfig::permissive()).expect("Failed to create QuickJsEngine")
    }

    #[test]
    fn test_java_namespace_md5() {
        let engine = make_engine();
        let result = engine.eval("java.md5Encode('hello')").unwrap();
        assert_eq!(result, "5d41402abc4b2a76b9719d911017c592");
    }

    #[test]
    fn test_java_namespace_base64() {
        let engine = make_engine();
        let result = engine.eval("java.base64Encode('hello')").unwrap();
        assert_eq!(result, "aGVsbG8=");
    }

    #[test]
    fn test_java_namespace_http_get_exists() {
        let engine = make_engine();
        // 只验证 java.httpGet 存在且是函数，不实际调用
        let result = engine.eval("typeof java.httpGet").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_bare_global_still_works() {
        let engine = make_engine();
        let result = engine.eval("md5Encode('hello')").unwrap();
        assert_eq!(result, "5d41402abc4b2a76b9719d911017c592");
    }

    #[test]
    fn test_java_namespace_sha256() {
        let engine = make_engine();
        let result = engine.eval("java.sha256('hello')").unwrap();
        assert_eq!(
            result,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn test_java_namespace_urlencode() {
        let engine = make_engine();
        let result = engine.eval("java.urlencode('hello world')").unwrap();
        assert!(result.contains("%20") || result.contains("+"));
    }

    #[test]
    fn test_java_and_bare_produce_same_result() {
        let engine = make_engine();
        let java_result = engine.eval("java.md5Encode('test123')").unwrap();
        let bare_result = engine.eval("md5Encode('test123')").unwrap();
        assert_eq!(java_result, bare_result);
    }

    #[test]
    fn test_java_open_video_player_bridge() {
        let engine = make_engine();
        // 书源 JS 调用 java.openVideoPlayer(url, title) 应返回结构化桥接载荷
        let result = engine
            .eval("java.openVideoPlayer('http://v.com/x.mp4', '第1集')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "openVideoPlayer");
        assert_eq!(parsed["url"], "http://v.com/x.mp4");
        assert_eq!(parsed["title"], "第1集");
        assert_eq!(parsed["isFloat"], false);
    }

    #[test]
    fn test_bare_open_video_player_with_float() {
        let engine = make_engine();
        // 裸全局调用 + isFloat 参数
        let result = engine
            .eval("openVideoPlayer('http://v.com/y.m3u8', '标题', true)")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["isFloat"], true);
    }

    // ---- 新增 API 集成测试 ----

    #[test]
    fn test_java_aes_encrypt_decrypt() {
        let engine = make_engine();
        // AES 加密后解密应还原
        let result = engine
            .eval(
                "java.aesDecrypt(java.aesEncrypt('hello', '0123456789abcdef'), '0123456789abcdef')",
            )
            .unwrap();
        assert_eq!(result, "hello");
    }

    #[test]
    fn test_java_aes_encrypt_returns_base64() {
        let engine = make_engine();
        let result = engine
            .eval("java.aesEncrypt('hello', '0123456789abcdef')")
            .unwrap();
        // 应为非空 Base64 字符串
        assert!(!result.is_empty());
        assert!(!result.starts_with("[ERROR]"));
    }

    #[test]
    fn test_java_rc4_roundtrip() {
        let engine = make_engine();
        let result = engine
            .eval("java.rc4Decrypt(java.rc4Encrypt('secret data', 'mykey'), 'mykey')")
            .unwrap();
        assert_eq!(result, "secret data");
    }

    #[test]
    fn test_java_get_cookie() {
        let engine = make_engine();
        // 先 setCookie 再 getCookie
        engine
            .eval("java.setCookie('test_tag', 'session=abc123')")
            .unwrap();
        let result = engine
            .eval("java.getCookie('test_tag', 'session')")
            .unwrap();
        assert_eq!(result, "abc123");
        // 清理
        engine.eval("java.clearCookies('test_tag')").unwrap();
    }

    #[test]
    fn test_java_html_format() {
        let engine = make_engine();
        let result = engine.eval("java.htmlFormat('<p>hello</p>')").unwrap();
        assert_eq!(result, "hello");
    }

    #[test]
    fn test_java_html_format_complex() {
        let engine = make_engine();
        let result = engine
            .eval("java.htmlFormat('<div>正文</div><script>alert(1)</script><div>结尾</div>')")
            .unwrap();
        assert!(result.contains("正文"));
        assert!(result.contains("结尾"));
        assert!(!result.contains("script"));
    }

    #[test]
    fn test_java_t2s() {
        let engine = make_engine();
        let result = engine.eval("java.t2s('國')").unwrap();
        assert_eq!(result, "国");
    }

    #[test]
    fn test_java_s2t() {
        let engine = make_engine();
        let result = engine.eval("java.s2t('国')").unwrap();
        assert_eq!(result, "國");
    }

    #[test]
    fn test_java_to_num_chapter() {
        let engine = make_engine();
        let result = engine.eval("java.toNumChapter('第一百二十三章')").unwrap();
        assert_eq!(result, "第123章");
    }

    #[test]
    fn test_java_digest_hex() {
        let engine = make_engine();
        let result = engine.eval("java.digestHex('hello', 'MD5')").unwrap();
        assert_eq!(result, "5d41402abc4b2a76b9719d911017c592");
    }

    #[test]
    fn test_java_str_to_bytes() {
        let engine = make_engine();
        let result = engine.eval("java.strToBytes('Hello')").unwrap();
        assert_eq!(result, "[72,101,108,108,111]");
    }

    #[test]
    fn test_java_bytes_to_str() {
        let engine = make_engine();
        let result = engine
            .eval("java.bytesToStr('[72,101,108,108,111]')")
            .unwrap();
        assert_eq!(result, "Hello");
    }

    #[test]
    fn test_bare_global_new_apis() {
        let engine = make_engine();
        // 裸全局调用新 API
        let result = engine.eval("t2s('國')").unwrap();
        assert_eq!(result, "国");
        let result = engine.eval("htmlFormat('<b>bold</b>')").unwrap();
        assert_eq!(result, "bold");
        let result = engine.eval("toNumChapter('第一章')").unwrap();
        assert_eq!(result, "第1章");
    }

    // ---- P2-6 新增 API 集成测试 ----

    #[test]
    fn test_java_web_view_bridge() {
        let engine = make_engine();
        let result = engine
            .eval("java.webView('', 'http://test.com', 'document.title')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "webView");
        assert_eq!(parsed["url"], "http://test.com");
        assert_eq!(parsed["js"], "document.title");
    }

    #[test]
    fn test_java_web_view_get_source_bridge() {
        let engine = make_engine();
        let result = engine
            .eval("java.webViewGetSource('', 'http://test.com', '', 'content')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "webViewGetSource");
        assert_eq!(parsed["sourceRegex"], "content");
    }

    #[test]
    fn test_java_start_browser_bridge() {
        let engine = make_engine();
        let result = engine
            .eval("java.startBrowser('http://test.com', '标题')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "startBrowser");
        assert_eq!(parsed["url"], "http://test.com");
        assert_eq!(parsed["title"], "标题");
    }

    #[test]
    fn test_java_open_url_bridge() {
        let engine = make_engine();
        let result = engine.eval("java.openUrl('legado://import')").unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "openUrl");
        assert_eq!(parsed["url"], "legado://import");
    }

    #[test]
    fn test_java_get_verification_code_channel() {
        use std::time::{Duration, Instant};

        let engine = std::sync::Arc::new(make_engine());
        let image_url = "http://img.com/captcha-quickjs-test.png";
        let rx = legado_core::verification_channel::verification_manager().subscribe();

        // JS eval 在后台线程阻塞等待（模拟 JS 工作线程）
        let eng = engine.clone();
        let worker = std::thread::spawn(move || {
            eng.eval("java.getVerificationCode('http://img.com/captcha-quickjs-test.png')")
                .unwrap()
        });

        // UI 侧：定位事件并提交
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut key = None;
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(req) if req.image_url == image_url => {
                    key = Some(req.key);
                    break;
                }
                Ok(_) => continue,
                Err(_) => continue,
            }
        }
        let key = key.expect("应收到验证码请求事件");
        assert!(legado_core::verification_channel::submit_verification_result(&key, "q777"));
        assert_eq!(worker.join().unwrap(), "q777");
    }

    #[test]
    fn test_java_start_browser_await_degraded() {
        use std::time::{Duration, Instant};

        let engine = std::sync::Arc::new(make_engine());
        let url = "http://verify.example.com/quickjs-browser-degrade";
        let rx = legado_core::verification_channel::verification_manager().subscribe();

        let eng = engine.clone();
        let worker = std::thread::spawn(move || {
            eng.eval("java.startBrowserAwait('http://verify.example.com/quickjs-browser-degrade', '验证', true)")
                .unwrap()
        });

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut key = None;
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(req) if req.image_url == url => {
                    assert!(!req.use_browser);
                    key = Some(req.key);
                    break;
                }
                Ok(_) => continue,
                Err(_) => continue,
            }
        }
        let key = key.expect("应收到降级验证请求事件");
        assert!(legado_core::verification_channel::submit_verification_result(&key, "b555"));
        assert_eq!(worker.join().unwrap(), "b555");
    }

    #[test]
    fn test_java_query_ttf() {
        let engine = make_engine();
        let result = engine
            .eval("java.queryTTF('https://example.com/font.ttf')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["type"], "url");
        // 真实实现：字体下载/解析失败时句柄标记 valid=false（降级）
        assert_eq!(parsed["valid"], false);
    }

    #[test]
    fn test_java_query_ttf_empty() {
        let engine = make_engine();
        let result = engine.eval("java.queryTTF('')").unwrap();
        assert_eq!(result, "null");
    }

    #[test]
    fn test_java_query_base64_ttf() {
        let engine = make_engine();
        let result = engine.eval("java.queryBase64TTF('AAECAwQF')").unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        // 真实实现：非法 base64 字体解析失败 → valid=false
        assert_eq!(parsed["valid"], false);
    }

    #[test]
    fn test_java_replace_font_null_handles() {
        let engine = make_engine();
        let result = engine
            .eval("java.replaceFont('hello', 'null', 'null')")
            .unwrap();
        assert_eq!(result, "hello");
    }

    #[test]
    fn test_java_replace_font_stub() {
        let engine = make_engine();
        // 句柄无效（下载失败）时降级原样返回，与 Kotlin null 句柄分支一致
        let result = engine
            .eval(
                "var e = java.queryTTF('https://e.com/f.ttf'); \
                 var c = java.queryTTF('https://c.com/f.ttf'); \
                 java.replaceFont('测试', e, c)",
            )
            .unwrap();
        assert_eq!(result, "测试");
    }

    #[test]
    fn test_java_replace_font_real_cmap() {
        // 端到端：真实 cmap/glyf 解析，经 JS 契约完成防爬字体替换
        use base64::Engine;
        use crate::host_api::font_api::tests::{build_minimal_ttf, Segment};
        let err_font = build_minimal_ttf(
            &[Segment {
                start: 0xE001,
                end: 0xE003,
                id_delta: 0x2000,
            }],
            false,
        );
        let ok_font = build_minimal_ttf(
            &[Segment {
                start: 0x41,
                end: 0x43,
                id_delta: -0x40,
            }],
            false,
        );
        let err_b64 = base64::engine::general_purpose::STANDARD.encode(&err_font);
        let ok_b64 = base64::engine::general_purpose::STANDARD.encode(&ok_font);

        let engine = make_engine();
        let script = format!(
            "var e = java.queryTTF('{}'); \
             var c = java.queryTTF('{}'); \
             java.replaceFont('\\uE001\\uE002\\uE003结尾', e, c)",
            err_b64, ok_b64
        );
        let result = engine.eval(&script).unwrap();
        assert_eq!(result, "ABC结尾");
    }

    #[test]
    fn test_java_ajax_all_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.ajaxAll").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_head_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.head").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_post_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.post").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_connect_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.connect").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_un7z_file_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.un7zFile").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_unrar_file_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.unrarFile").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_unrar_file_missing_file_error() {
        // 真实实现（rar crate）：不存在的文件返回 [ERROR] 前缀错误信息
        let engine = make_engine();
        let result = engine.eval("java.unrarFile('test.rar')").unwrap();
        assert!(result.contains("[ERROR]"));
    }

    #[test]
    fn test_java_get7z_string_content_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.get7zStringContent").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_get_rar_string_content_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.getRarStringContent").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_get7z_string_content_local_file() {
        use std::io::Write;

        // 构造测试 7z 文件
        let dir = std::env::temp_dir().join(format!(
            "legado_js_7z_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let src_dir = dir.join("src");
        std::fs::create_dir_all(&src_dir).unwrap();
        let entry_path = src_dir.join("inner.txt");
        let mut f = std::fs::File::create(&entry_path).unwrap();
        f.write_all("7z 内部文本内容".as_bytes()).unwrap();
        drop(f);
        let seven_z_path = dir.join("test.7z");
        sevenz_rust2::compress_to_path(&src_dir, &seven_z_path).unwrap();

        // JS 侧调用：本地路径 + 条目名
        let path_js = seven_z_path.to_str().unwrap().replace('\\', "\\\\");
        let engine = make_engine();
        let script = format!("java.get7zStringContent('{path_js}', 'inner.txt')");
        let result = engine.eval(&script).unwrap();
        assert_eq!(result, "7z 内部文本内容");

        // 不存在的条目 → 空串（对齐 Kotlin 失败语义）
        let script = format!("java.get7zStringContent('{path_js}', 'no-such.txt')");
        let result = engine.eval(&script).unwrap();
        assert_eq!(result, "");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ============================================================
    // Task #95：unzipFile / getZipStringContent / 零星 API 宿主集成测试
    // ============================================================

    /// 辅助：创建测试 ZIP 文件，返回路径
    fn create_zip_for_js(entries: &[(&str, &[u8])]) -> String {
        use std::io::Write;
        use zip::write::SimpleFileOptions;
        use zip::ZipWriter;

        let dir = std::env::temp_dir().join(format!(
            "legado_js_host_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let zip_path = dir.join("host_test.zip");

        let file = std::fs::File::create(&zip_path).unwrap();
        let mut writer = ZipWriter::new(file);
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        for (name, content) in entries {
            writer.start_file(*name, options).unwrap();
            writer.write_all(content).unwrap();
        }
        writer.finish().unwrap();

        zip_path.to_string_lossy().to_string()
    }

    /// 辅助：把路径转为 JS 字符串字面量（转义 Windows 反斜杠）
    fn js_str(s: &str) -> String {
        format!("'{}'", s.replace('\\', "\\\\"))
    }

    #[test]
    fn test_java_unzip_file_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.unzipFile").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_js_unzip_file_round_trip() {
        // unzip 往返：创建 ZIP → JS 调用 unzipFile → 验证解压产物
        let zip_path = create_zip_for_js(&[
            ("hello.txt", b"unzip round trip"),
            ("sub/data.bin", &[0x01, 0x02]),
        ]);
        let engine = make_engine();
        let code = format!("java.unzipFile({})", js_str(&zip_path));
        let out_dir = engine.eval(&code).unwrap();
        assert!(
            !out_dir.starts_with("[ERROR]"),
            "unzipFile 失败: {}",
            out_dir
        );
        assert!(std::path::Path::new(&out_dir).join("hello.txt").exists());
        assert!(std::path::Path::new(&out_dir).join("sub/data.bin").exists());

        let _ = std::fs::remove_dir_all(&out_dir);
        let _ = std::fs::remove_dir_all(std::path::Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_js_unzip_file_empty_path() {
        // 对齐 Kotlin：空路径返回空串
        let engine = make_engine();
        let result = engine.eval("java.unzipFile('')").unwrap();
        assert_eq!(result, "");
    }

    #[test]
    fn test_js_get_zip_string_content() {
        let content = "ZIP 文本内容";
        let zip_path = create_zip_for_js(&[("content.txt", content.as_bytes())]);
        let engine = make_engine();

        let code = format!("java.getZipStringContent({}, 'content.txt')", js_str(&zip_path));
        let result = engine.eval(&code).unwrap();
        assert_eq!(result, content);

        // 不存在的条目返回空串（对齐 Kotlin return ""）
        let code = format!("java.getZipStringContent({}, 'no.txt')", js_str(&zip_path));
        assert_eq!(engine.eval(&code).unwrap(), "");

        let _ = std::fs::remove_dir_all(std::path::Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_js_get_zip_string_content_hex_source() {
        // 十六进制字符串来源（对齐 Kotlin HexUtil.decodeHex 分支）
        let zip_path = create_zip_for_js(&[("h.txt", b"hex source")]);
        let hex_str = hex::encode(std::fs::read(&zip_path).unwrap());
        let engine = make_engine();

        let code = format!("java.getZipStringContent('{}', 'h.txt')", hex_str);
        assert_eq!(engine.eval(&code).unwrap(), "hex source");

        let _ = std::fs::remove_dir_all(std::path::Path::new(&zip_path).parent().unwrap());
    }

    /// 辅助：创建包含指定文件的测试 7z 压缩包，返回 7z 文件路径
    fn create_7z_for_js(entries: &[(&str, &[u8])]) -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let src_dir = std::env::temp_dir().join(format!("legado_js_7z_src_{:x}", nanos));
        std::fs::create_dir_all(&src_dir).unwrap();
        for (name, content) in entries {
            let file_path = src_dir.join(name);
            if let Some(parent) = file_path.parent() {
                std::fs::create_dir_all(parent).unwrap();
            }
            std::fs::write(&file_path, content).unwrap();
        }

        let seven_z_path = std::env::temp_dir()
            .join(format!("legado_js_7z_arc_{:x}", nanos))
            .join("host_test.7z");
        if let Some(parent) = seven_z_path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        sevenz_rust2::compress_to_path(&src_dir, &seven_z_path).unwrap();
        let _ = std::fs::remove_dir_all(&src_dir);

        seven_z_path.to_string_lossy().to_string()
    }

    #[test]
    fn test_js_get_7z_string_content() {
        // 7z 本地文件来源往返（对齐 getZipStringContent 模式）
        let content = "第七章 7z 文本内容";
        let seven_z_path = create_7z_for_js(&[("chapter.txt", content.as_bytes())]);
        let engine = make_engine();

        let code = format!(
            "java.get7zStringContent({}, 'chapter.txt')",
            js_str(&seven_z_path)
        );
        let result = engine.eval(&code).unwrap();
        assert_eq!(result, content);

        // 不存在的条目返回空串（对齐 Kotlin return ""）
        let code = format!("java.get7zStringContent({}, 'no.txt')", js_str(&seven_z_path));
        assert_eq!(engine.eval(&code).unwrap(), "");

        let _ = std::fs::remove_dir_all(std::path::Path::new(&seven_z_path).parent().unwrap());
    }

    #[test]
    fn test_js_get_rar_string_content_hex_source() {
        // RAR 十六进制来源往返：RAR5 STORE 单文件 fixture（与 archive_utils 测试同源）
        const RAR5_HELLO: &[u8] = &[
            0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00, 0xc5, 0x1a, 0x33, 0x32, 0x03, 0x01,
            0x00, 0x00, 0xe4, 0xf8, 0x02, 0x48, 0x16, 0x02, 0x02, 0x10, 0x04, 0x10, 0x20, 0xec,
            0x68, 0x08, 0x45, 0x00, 0x01, 0x09, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e, 0x74, 0x78,
            0x74, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x52, 0x41, 0x52, 0x20, 0x57, 0x6f, 0x72,
            0x6c, 0x64, 0x21, 0x19, 0xb2, 0x3a, 0x35, 0x03, 0x05, 0x00, 0x00,
        ];
        let hex_str = hex::encode(RAR5_HELLO);
        let engine = make_engine();

        let code = format!("java.getRarStringContent('{}', 'hello.txt')", hex_str);
        assert_eq!(engine.eval(&code).unwrap(), "Hello RAR World!");

        // 不存在的条目返回空串（对齐 Kotlin return ""）
        let code = format!("java.getRarStringContent('{}', 'no.txt')", hex_str);
        assert_eq!(engine.eval(&code).unwrap(), "");
    }

    #[test]
    fn test_js_web_view_get_override_url_payload() {
        let engine = make_engine();
        let result = engine
            .eval("java.webViewGetOverrideUrl('', 'http://t.com', '', 'legado://.*')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "webViewGetOverrideUrl");
        assert_eq!(parsed["url"], "http://t.com");
        assert_eq!(parsed["overrideUrlRegex"], "legado://.*");
        assert_eq!(parsed["cacheFirst"], false);
    }

    #[test]
    fn test_js_show_browser_payload() {
        let engine = make_engine();
        let result = engine
            .eval("java.showBrowser('http://t.com', '<h/>')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "openBrowser");
        assert_eq!(parsed["url"], "http://t.com");
        assert_eq!(parsed["html"], "<h/>");
    }

    #[test]
    fn test_js_long_toast() {
        let engine = make_engine();
        let result = engine.eval("java.longToast('长提示')").unwrap();
        assert_eq!(result, "长提示");
        // 裸全局同样可用
        let result = engine.eval("longToast('bare')").unwrap();
        assert_eq!(result, "bare");
    }

    #[test]
    fn test_js_base64_decode_to_byte_array() {
        let engine = make_engine();
        // 'aGVsbG8=' = "hello"
        let result = engine
            .eval("Array.from(java.base64DecodeToByteArray('aGVsbG8=')).join(',')")
            .unwrap();
        assert_eq!(result, "104,101,108,108,111");
        // 空白输入返回 null（对齐 Kotlin isNullOrBlank -> null）
        let result = engine.eval("java.base64DecodeToByteArray('') === null").unwrap();
        assert_eq!(result, "true");
    }

    #[test]
    fn test_js_time_format() {
        let engine = make_engine();
        let result = engine.eval("java.timeFormat(1704067200000)").unwrap();
        // Kotlin dateFormat = "yyyy/MM/dd HH:mm"
        let re = regex::Regex::new(r"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$").unwrap();
        assert!(re.is_match(&result), "timeFormat 结果不匹配: {}", result);
        // formatTime 兼容名保留（双参形式）
        let result = engine.eval("java.formatTime(1704067200000, '%Y')").unwrap();
        assert_eq!(result, "2024");
    }

    #[test]
    fn test_js_to_url_fields() {
        let engine = make_engine();
        assert_eq!(
            engine
                .eval("java.toURL('https://ex.com:8080/a/b?x=1&y=%E4%B8%AD').host")
                .unwrap(),
            "ex.com"
        );
        assert_eq!(
            engine
                .eval("java.toURL('https://ex.com:8080/a/b').origin")
                .unwrap(),
            "https://ex.com:8080"
        );
        assert_eq!(
            engine.eval("java.toURL('https://ex.com/a/b').pathname").unwrap(),
            "/a/b"
        );
        assert_eq!(
            engine
                .eval("java.toURL('https://ex.com/a?x=1').searchParams.x")
                .unwrap(),
            "1"
        );
        assert_eq!(
            engine
                .eval("java.toURL('https://ex.com/a?y=%E4%B8%AD').searchParams.y")
                .unwrap(),
            "中"
        );
        // 无 query 时 searchParams 为 null（对齐 Kotlin JsURL）
        assert_eq!(
            engine
                .eval("java.toURL('https://ex.com/a').searchParams === null")
                .unwrap(),
            "true"
        );
    }

    #[test]
    fn test_js_to_url_relative_base() {
        let engine = make_engine();
        assert_eq!(
            engine
                .eval("java.toURL('c.html', 'https://ex.com/a/b.html').pathname")
                .unwrap(),
            "/a/c.html"
        );
        assert_eq!(
            engine
                .eval("java.toURL('/c', 'https://ex.com/a/b.html').pathname")
                .unwrap(),
            "/c"
        );
    }

    #[test]
    fn test_bare_web_view_bridge() {
        let engine = make_engine();
        // 裸全局调用 webView
        let result = engine
            .eval("webView('', 'http://bare.com', 'js_code')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "webView");
        assert_eq!(parsed["url"], "http://bare.com");
    }

    #[test]
    fn test_bare_query_ttf() {
        let engine = make_engine();
        let result = engine.eval("queryTTF('/fonts/test.ttf')").unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["type"], "file");
    }
}
