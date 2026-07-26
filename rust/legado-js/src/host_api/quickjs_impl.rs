//! QuickJS 宿主 API 注册实现
//!
//! 在 `quickjs` feature 启用时，将 Legado 提供的宿主函数
//! 注册到 rquickjs 的全局上下文中，供 JS 脚本直接调用。
//!
//! 当前实现：
//! - 编解码 API：md5Encode, md5Encode16, base64Encode, base64Decode,
//!   hexEncode, hexDecode, sha256, encodeURI, hmacMd5, hmacSha256
//! - 字符串工具：urlencode, urldecode, trimStart, trimEnd,
//!   substringBefore, substringAfter, replaceFirst, replaceAll
//! - JSON 工具：jsonPath, jsonGetString, toJson
//! - 正则工具：regExp, regExpReplace, regExpFindAll
//! - 时间工具：formatTime, currentTimeMillis, parseTime, timeFormatUTC
//! - 文件工具：readFile, writeFile, fileExists, deleteFile
//! - 变量存储：getVariable, setVariable, removeVariable, clearVariables
//! - 工具类：randomUUID, log

#![cfg(feature = "quickjs")]

use legado_core::LegadoError;

use crate::host_api::{
    chinese_utils, cookie_store, crypto_api, encoding, file_utils, html_format, json_utils,
    network, regex_utils, register::mount_dual, string_utils, time_utils, variable_store,
};
use rquickjs::function::Opt;

/// 将所有宿主 API 注册到 QuickJS 全局上下文
///
/// 每个函数同时挂载到 `java` 命名空间对象和裸全局，
/// 确保 `java.md5Encode("hello")` 和 `md5Encode("hello")` 都能工作。
pub fn register_all_apis<'js>(ctx: &rquickjs::Ctx<'js>) -> Result<(), LegadoError> {
    let globals = ctx.globals();

    // 创建 java 命名空间对象
    let java =
        rquickjs::Object::new(ctx.clone()).map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    register_encoding_apis(ctx, &java, &globals)?;
    register_string_apis(ctx, &java, &globals)?;
    register_json_apis(ctx, &java, &globals)?;
    register_regex_apis(ctx, &java, &globals)?;
    register_time_apis(ctx, &java, &globals)?;
    register_file_apis(ctx, &java, &globals)?;
    register_variable_apis(ctx, &java, &globals)?;
    register_utility_apis(ctx, &java, &globals)?;
    register_network_apis(ctx, &java, &globals)?;
    register_cookie_apis(ctx, &java, &globals)?;
    register_crypto_apis(ctx, &java, &globals)?;
    register_html_apis(ctx, &java, &globals)?;
    register_chinese_apis(ctx, &java, &globals)?;

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
/// 对应 Kotlin 端 `JsExtensions` 中的 ajax/connect/get/post/head 等方法。
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
}
