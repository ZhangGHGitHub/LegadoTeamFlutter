//! legado-book 构建脚本
//!
//! 在 Windows 平台上为 unrar_sys 补充链接 advapi32 库
//! （unrar 内部使用了 Windows 注册表和加密 API）

fn main() {
    // 注意：build.rs 中的 #[cfg] 检查的是宿主平台，交叉编译时必须用 CARGO_CFG_TARGET_OS
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "windows" {
        // unrar_sys 在 Windows 上需要 advapi32（RegOpenKeyExW, CryptAcquireContextW 等）
        println!("cargo:rustc-link-lib=advapi32");
    }
}
