//! QuickJS 函数注册辅助
//!
//! 提供双挂载功能：将同一个函数同时注册到 `java` 命名空间对象和裸全局，
//! 确保 `java.md5Encode("hello")` 和 `md5Encode("hello")` 都能工作。

#![cfg(feature = "quickjs")]

use legado_core::LegadoError;

/// 将一个已创建的函数同时挂载到 java 命名空间对象和裸全局
///
/// 这确保 `java.md5Encode("hello")` 和 `md5Encode("hello")` 都能工作，
/// 保持与现有书源脚本的兼容性。
///
/// # 参数
/// - `java`: java 命名空间对象
/// - `globals`: QuickJS 全局对象
/// - `name`: 函数名
/// - `func`: 已创建的 rquickjs Function 对象
pub fn mount_dual<'js>(
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
    name: &str,
    func: rquickjs::Function<'js>,
) -> Result<(), LegadoError> {
    globals
        .set(name, func.clone())
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    java.set(name, func)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    Ok(())
}
