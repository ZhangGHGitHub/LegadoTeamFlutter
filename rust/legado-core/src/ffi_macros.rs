//! FFI 桥接宏，用于简化 Dart FFI 绑定生成

/// 导出 FFI 函数的辅助宏（占位实现）
#[macro_export]
macro_rules! ffi_export {
    ($name:ident, $body:expr) => {
        #[no_mangle]
        pub extern "C" fn $name() {
            $body
        }
    };
}

/// 将 Rust Result 转换为 FFI 友好的返回码
#[macro_export]
macro_rules! ffi_result {
    ($result:expr) => {
        match $result {
            Ok(_) => 0,
            Err(_) => -1,
        }
    };
}
