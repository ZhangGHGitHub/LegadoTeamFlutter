//! 通用类型定义

use serde::{Deserialize, Serialize};

/// 通用分页信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageInfo {
    pub page: usize,
    pub page_size: usize,
    pub total: usize,
}

/// FFI 字符串指针包装（用于跨语言传递）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FfiString(pub String);

impl From<String> for FfiString {
    fn from(s: String) -> Self {
        Self(s)
    }
}

impl From<FfiString> for String {
    fn from(ffi: FfiString) -> Self {
        ffi.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_page_info_serde() {
        let pi = PageInfo {
            page: 1,
            page_size: 20,
            total: 100,
        };
        let json = serde_json::to_string(&pi).unwrap();
        let de: PageInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(de.page, 1);
        assert_eq!(de.page_size, 20);
        assert_eq!(de.total, 100);
    }

    #[test]
    fn test_ffi_string_conversions() {
        let s = "hello".to_string();
        let ffi: FfiString = s.clone().into();
        assert_eq!(ffi.0, "hello");
        let back: String = ffi.into();
        assert_eq!(back, "hello");
    }
}
