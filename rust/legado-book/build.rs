//! legado-book 构建脚本
//!
//! 在 Windows 平台上为 unrar_sys 补充链接 advapi32 库
//! （unrar 内部使用了 Windows 注册表和加密 API）

fn main() {
    // unrar_sys 在 Windows 上需要 advapi32（RegOpenKeyExW, CryptAcquireContextW 等）
    #[cfg(target_os = "windows")]
    println!("cargo:rustc-link-lib=advapi32");
}
