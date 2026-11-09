# 批9d「生物识别快捷解锁」设备验收报告

- 日期：2026-11-10
- 验收角色：主代理
- 代码基线：`955611f53b`（含审查 P1/P2 回修）
- 应用版本：2.0.478+479
- APK SHA-256：`f8fa4959b93554dff34fac230594d2bd93da1b033b0197d02ea6387f7a1d9954`
- 证据：`docs/materials_1109k/`（7 个文件）

## 一、环境

| 项 | 值 |
|---|---|
| 模拟器 | MuMu「Test测试」`192.168.100.62:5555`，Android 15 |
| 分辨率/密度 | 1080x1920 / 480dpi |
| 版本 | 2.0.478（versionCode 479） |
| Rust | 本批新增生物识别 4 FFI；arm64-v8a / x86_64 `.so` 已重建（`privacy_biometric_*` 符号存在），armv7 维持既有降级旧档 |
| 生物硬件 | **无**：`pm list features` 无 fingerprint/face，`dumpsys biometric` Sensors 为空 |
| 测试密码 | `Test1234`（测试后 `pm clear`） |

## 二、总体结论

- 本机可验收项 5 项：**PASS 5**；真实生物识别成功/取消/锁定/指纹变更链路 **BLOCKED（设备无硬件）**，由 Dart 104 例相关单测/Widget 与 Rust/通道测试覆盖。
- FATAL/ANR/E.flutter/overflow/E AndroidRuntime 均为 **0**（`logcat_9d.txt`）。
- 设备终态：`pm clear` 空书架、默认设置、无密码。

## 三、逐项结果

### A. 无硬件降级

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| A1 无密码时生物行 | PASS | `tmp_qa9d_03.png` | 「生物快捷解锁」副标题「请先设置隐私密码」，开关禁用 |
| A2 设密后即时刷新 | PASS | `tmp_qa9d_04.png` | 设置密码成功后（未重启）副标题变为「设备不支持指纹或面容识别」，开关保持关闭并禁用；P1 修复生效 |
| A3 禁用开关不可开启 | PASS（测试） | `privacy_settings_screen_test.dart` | Widget 断言不可用/无密码时 `onChanged` 为空；设备上点击无状态变化（无硬件分支） |

### B. 密码路径回归

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| B1 启动锁仍密码可用 | PASS | `tmp_qa9d_05.png` | 开启「启动应用时验证」后冷启动显示密码锁页；无生物硬件时不出现「使用生物识别」按钮 |
| B2 解锁进入应用 | PASS | `tmp_qa9d_06.png` | 正确密码解锁进入应用（页面为阅读记录，证明已放行） |

### C. 稳定性与终态

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| C1 崩溃/ANR/overflow | PASS | `logcat_9d.txt` | 五类计数均为 0 |
| C2 设备清理 | PASS | `tmp_qa9d_07.png` | `pm clear` 后空书架、默认设置、可启动 |

## 四、审查与回修

- 首轮审查 `needs changes`（无 P0；P1×1「首次设密后生物入口整会话不可用」、P2×2「平台不可用时无法关闭已开启项」「enable/unlock 无超时导致 busy 卡死」、P3×5）→ `02034b8237` / `5717d33fb5` / `955611f53b`。
- 二次复审 **pass**：P1/P2 均闭环，新增 12 用例；剩余 P3 登记（refresh 竞态回弹、resumed 复位与在途认证重叠、Future.timeout 不取消原生认证、`_reload` 读失败闪关、settings 关闭用例未断言 deleteKey）。
- 契约：`docs/API_CONTRACT.md` §2.53 12 方法，附录 338 / BookApi 336 / 表 B 172 / 等价 188，程序化契约测试 10 例通过。

## 五、BLOCKED / 未覆盖

1. **真实生物认证链路**：本机无指纹/面容硬件，`enable` 认证与封装、`unlock` 解密、取消、系统锁定、指纹变更 `key_invalidated` 均未设备实测；由 Rust 13 例隐私测试、Dart 通道 Fake/Notifier 104 例相关用例覆盖。
2. **Android 原生通道运行时**：Kotlin 编译通过（`:app:compileDebugKotlin`），设备仅走 `unsupported/no_hardware` 降级分支；`BiometricPrompt` 实机行为未验证。
3. **iOS**：Windows 无法编译 Swift/Xcode 工程改动，仅静态审查；`LAContext` + Keychain 链路需 macOS 编译与真机/模拟器 Face ID 验证。
4. **超时/取消 UI**：45s 超时与 resumed 复位由 Widget 测试覆盖，设备无硬件无法触发原生弹窗。

## 六、设备终态

- 应用 2.0.478+479 已安装，`pm clear` 后空书架、默认设置、无隐私密码，可启动。

## 七、门禁（代码基线）

- Rust：`cargo fmt --all -- --check` 通过；默认与 quickjs 两档 `clippy --all-targets -D warnings` 通过；`cargo test --workspace` EXIT 0（72 目标）；quickjs `legado-ffi` 781 通过/42 ignored（lib）且 28 目标 ok；`legado-js` 678 通过/2 ignored。
- Flutter：analyze 0；test **5321 通过 + 1 skipped**；本批 format 0 changed。
- 契约：§2.53 12 方法，338/336/172/188；DB schema 119 未变。

---

编写：ZCode 主代理 ｜ 2026-11-10
