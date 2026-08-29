//! 全局设备 ID（Android ID）注入
//!
//! 对齐 Kotlin AppConst.androidId（Settings.Secure.ANDROID_ID）：书山聚合等
//! 源登录时登记该设备、正文请求需携带匹配的 X-Device-Id 才返回明文。
//! Flutter 侧经 FFI 读取真实设备 ID 后调用 set_device_id 注入（进程级）。

use std::sync::{OnceLock, RwLock};

fn device_id_store() -> &'static RwLock<Option<String>> {
    static STORE: OnceLock<RwLock<Option<String>>> = OnceLock::new();
    STORE.get_or_init(|| RwLock::new(None))
}

/// 注入真实设备 ID（Flutter 启动时经 FFI 调用）
pub fn set_device_id(id: &str) {
    let id = id.trim().to_string();
    if !id.is_empty() && id != "null" {
        *device_id_store().write().unwrap_or_else(|p| p.into_inner()) = Some(id);
    }
}

/// 读取设备 ID（无注入时返回空）
pub fn device_id() -> Option<String> {
    device_id_store()
        .read()
        .unwrap_or_else(|p| p.into_inner())
        .clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_set_and_get_device_id() {
        set_device_id("70f79699ca032aeb");
        assert_eq!(device_id().as_deref(), Some("70f79699ca032aeb"));
    }

    #[test]
    fn test_ignores_empty_device_id() {
        set_device_id("");
        set_device_id("null");
        // 空值不覆盖既有注入；首次无注入时保持 None
        assert!(device_id().as_deref() != Some(""));
    }
}
