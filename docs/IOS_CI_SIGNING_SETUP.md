# iOS CI 签名脚手架配置与真机安装指南

> 编写者：Legado 项目维护组 ｜ 2026-09-27
> 关联任务：P2-26（iOS CI 签名改造，脚手架阶段）｜ 关联工作流：`.github/workflows/ios-build.yml`
> 状态：**暂缓（待外部测试能力，2026-09-27 验证口径）**——当前缺少本地 Mac、Apple 设备与可授权测试者，恢复真机测试时再按 §二 准备素材（**当前不要求申请 Apple Developer Program**）；文中标「待用户素材」的部分到恢复时才需演练。

## 一、目标与非目标

**目标**：

- CI 能按需产出**开发签名 / Ad-hoc 签名 ipa**，供真机侧载安装验收。
- 签名材料缺失时 CI **保持全绿**，自动回落既有的未签名产物链路（`legado-ios-unsigned-ipa` artifact）。

**非目标（P2-26 裁决口径，2026-09-27 已入档）**：

- 不做 TestFlight / App Store 上架路径（不配置 App Store Connect、不做公证/notarization、不加 hardened runtime）。
- iOS 真机验收当前**暂缓（待外部测试能力）**：缺少本地 Mac、Apple 设备与可授权测试者，不安排 Agent 自行真机验收；本轮交付的「脚手架 + 文档」为**未来恢复真机测试的预留入口**，恢复时无需重做。当前验证以 Android MuMu 为唯一真机验收平台（详见 Active 计划 §一「验证口径」）。

## 二、素材清单（待用户素材）

| 素材 | 说明 | 状态 |
| --- | --- | --- |
| Apple Developer Program 账号 | $99/年（付费团队；免费个人团队仅限 7 天有效期开发描述文件，不支持 Ad-hoc） | 待用户素材 |
| 签名证书（P12 导出） | 建议类型：**Apple Development**（development 导出方式）或 **Apple Distribution**（ad-hoc 导出方式，推荐 Ad-hoc 分发用此） | 待用户素材 |
| 证书密码 | 导出 P12 时自设的密码（写入 GitHub secret，不落库） | 待用户素材 |
| App ID | 实际 bundle id 为 **`io.legado.flutterLegado`**（`flutter_legado/ios/Runner.xcodeproj/project.pbxproj`）。建议在 developer.apple.com 注册 **explicit（显式）App ID** `io.legado.flutterLegado`；wildcard（`io.legado.*`）仅在计划更换 bundle id 时考虑——Ad-hoc/开发签名下 explicit 更稳妥，匹配检查最明确 | 待用户素材 |
| 描述文件（.mobileprovision） | **Ad-hoc** 描述文件：创建时须勾选目标真机 **UDID**（付费账号上限 100 台），有效期**最长 12 个月**；Development 描述文件同理需登记设备 | 待用户素材 |

**有效期对比**：

| 账号类型 | 描述文件类型 | 有效期 | 设备数 | 备注 |
| --- | --- | --- | --- | --- |
| 免费个人团队（$0） | Development | **7 天** | 3 台 | 不支持 Ad-hoc，不适合验收分发 |
| 付费团队（$99/年） | Development / Ad-hoc | **最长 12 个月** | 100 台 | 推荐 Ad-hoc 用于真机验收 |

## 三、GitHub Secrets 配置表

在仓库 **Settings → Secrets and variables → Actions** 配置以下 4 个 secret（变量名与 `ios-build.yml` job 级 `env` 映射一致）：

| Secret 名 | 内容 | 获取/转换方法 |
| --- | --- | --- |
| `IOS_P12_BASE64` | 签名证书 P12 文件的 base64 | 本地导出 P12 后（macOS）：`base64 -i LegadoAdhoc.p12`；（Linux）：`base64 -w 0 LegadoAdhoc.p12`；（Windows PowerShell）：`[Convert]::ToBase64String([IO.File]::ReadAllBytes("LegadoAdhoc.p12"))`。输出可多行，直接粘贴进 secret |
| `IOS_P12_PASSWORD` | P12 导出时设置的密码 | 自设；仅存于 GitHub secret，**不要把密码写进仓库任何文件** |
| `IOS_PROFILE_BASE64` | 描述文件 .mobileprovision 的 base64 | 同上，文件换成描述文件：macOS `base64 -i LegadoAdhoc.mobileprovision`；Linux `base64 -w 0`；PowerShell 同式 |
| `IOS_EXPORT_METHOD` | 导出方式：`ad-hoc`（配 Apple Distribution 证书）或 `development`（配 Apple Development 证书） | 默认缺省为 `ad-hoc` |

> **安全红线：不要把真实证书 / 描述文件 / 密码提交进仓库**（含 `.github/`、`docs/`、任何示例代码）。base64 只是编码不是加密，secret 内容等同于证书本身。本地演练 base64 转换命令即可，不需要真实证书。

**素材获取路径（developer.apple.com）**：

1. **证书**：Certificates, Identifiers & Profiles → Certificates → 「+」选择 Apple Development / Apple Distribution 生成 .cer → 下载后双击导入 Keychain Access → 选中对应身份（iPhone Distribution: xxx / Apple Development: xxx）→ 右键 Export… 导出 .p12 并设密码。
2. **App ID**：Identifiers → App IDs → 「+」→ Bundle ID 填 `io.legado.flutterLegado`。
3. **描述文件**：Profiles → 「+」→ Ad Hoc（或 Development）→ 勾选上一步 App ID → Ad-hoc 需勾选目标真机 UDID（设备 UDID 获取：Xcode → Window → Devices and Simulators → 连机后选中设备查看 Identifier）→ Generate 下载 .mobileprovision。

## 四、CI 两态行为说明

`ios-build.yml` 的签名步骤以 `if: env.IOS_P12_BASE64 != ''` 门控，两态均能跑通、CI 均保持全绿：

### 态 A：无签名 secrets（当前默认态）

- 跳过 `Prepare signing materials` / `Sign modified Runner.app` / `Package signed IPA` / `Upload signed IPA` 四个步骤。
- 走既有未签名链路：`flutter build ios --release --no-codesign` → 图标注入/plist 剥离（-54 修复）→ `app-unsigned.ipa` → artifact **`legado-ios-unsigned-ipa`**。
- 额外输出一行 warning：`未配置签名 secrets（IOS_P12_BASE64 为空），产出未签名 ipa（P2-26 脚手架模式）`。
- 未签名 ipa 仅可作构建产物取证，**不能直接装真机**。

### 态 B：配置签名 secrets 后

1. **Prepare signing materials**：base64 解码 P12/描述文件 → 创建临时 keychain（随机密码，挂进 user keychain 搜索链）→ 导入 P12 → 描述文件安装至 `~/Library/MobileDevice/Provisioning Profiles/`（按 profile UUID 命名）→ 从 profile 本身提取 `application-identifier` 生成签名 entitlements（自洽，无需单独维护 TEAM_ID secret）→ 预埋 `embedded.mobileprovision`。
2. **Sign modified Runner.app**：先签嵌套代码对象（`Frameworks/*.framework`），再带 entitlements 重签顶层 bundle，`codesign -v --strict` 验证。注意：此处对**最终修改版 Runner.app**（图标注入/plist 剥离完成后）直接 codesign 重签，而非 `flutter build ipa`——后者会重新 archive 丢弃上述 in-place 修复（-54 回归修复）。
3. **Package / Upload signed IPA**：复用 Payload 打包 `app-signed.ipa` → artifact **`legado-ios-signed-ipa`**（retention 14 天）。
   - 注：既有 `Package unsigned IPA` 步骤无条件执行，故态 B 下 `legado-ios-unsigned-ipa` 内容也已是签名 app（产物名沿用既有链路）；**下载签名包请用 `legado-ios-signed-ipa`**。
4. 无 secrets 路径不引用任何签名产物（`if-no-files-found: error` 仅作用于条件满足的上传步），两态互不干扰。

## 五、真机安装与信任流程

以 Ad-hoc 签名 ipa 为例（development 签名流程相同，信任对象换成开发者证书）：

1. **下载**：GitHub Actions 运行页 → 对应 run → Artifacts → 下载 `legado-ios-signed-ipa`。
2. **安装**（三选一）：
   - **macOS + Finder/Xcode Organizer**：iPhone 连 Mac，双击 `.ipa` 打开 Xcode Organizer，选择设备安装。
   - **Apple Configurator 2**（Windows/macOS）：Devices 窗口连接真机 → 拖入 `.ipa` 安装。
   - **第三方侧载工具**（Sideloadly / AltStore 等）：打开下载的 ipa 重新签名侧载（会换成 7 天个人签名，仅限个人体验）。
3. **首次启动信任**（系统拦截「未受信任的企业级开发者应用」）：
   - **设置 → 通用 → VPN 与设备管理**（iOS 15 及以下为「描述文件与设备管理」）→ 点按对应开发者证书 → **信任** → 输入锁屏密码确认。
   - 回到主屏重新启动 App。
4. **过期处理**：Ad-hoc 描述文件到期（最长 12 个月）或证书到期后，已安装 App 无法启动——重新生成 P12/描述文件、更新 secret、重跑 CI 安装新 ipa 即可（旧包无需卸载，直接覆盖安装）。

## 六、排障

| 症状 | 根因 | 处置 |
| --- | --- | --- |
| CI 报 `P12 中无有效 codesigning 身份` | P12 密码错 / 证书类型与 `IOS_EXPORT_METHOD` 不匹配（ad-hoc 需 Apple Distribution、development 需 Apple Development）/ 证书链中间证书（Apple WWDR）缺失 | 核对 `IOS_P12_PASSWORD`；核对证书类型与导出方式一致；在 Mac 上先把 Apple WWDR 中间证书导入 Keychain 再导出 P12 |
| codesign 报 `profile doesn't match` / 真机装不上 | **描述文件与 bundle id 不匹配**（profile 的 `application-identifier` 不含 `io.legado.flutterLegado`） | 本地核对：`security cms -D -i xx.mobileprovision \| plutil -p \| grep application-identifier`；portal 上按第二节流程重建匹配 App ID 的描述文件，更新 `IOS_PROFILE_BASE64` |
| 真机报 `provisioning profile does not match device` / 无法安装 | **设备未登记**（Ad-hoc 描述文件未含该机 UDID） | 获取设备 UDID（Xcode → Window → Devices and Simulators）→ portal 描述文件中添加 UDID → 重新 Generate → 更新 `IOS_PROFILE_BASE64`（付费账号上限 100 台 UDID） |
| 装上的 App 无法启动 / 提示过期 | **证书或描述文件过期** | 重新生成证书（P12）与描述文件（最长 12 个月），更新 `IOS_P12_BASE64` / `IOS_P12_PASSWORD` / `IOS_PROFILE_BASE64`，重跑 CI |
| 真机启动报签名无效（Code Signature Invalid） | 打包链路被改动导致重签不彻底（嵌套 framework 未先签） | 确认 CI 签名步顺序（frameworks → 顶层 bundle）；勿在签名后再次改动 Runner.app 内容 |

## 七、与脚手架代码的对应关系

| 本文小节 | `ios-build.yml` 对应步骤 |
| --- | --- |
| §四 态 B | `Prepare signing materials (keychain + mobileprovision)` / `Sign modified Runner.app (ad-hoc/development)` / `Package signed IPA` / `Upload signed IPA`（均 `if: env.IOS_P12_BASE64 != ''`） |
| §四 态 A | 既有 `Build iOS (device, no codesign)` → `Package unsigned IPA` → `Upload unsigned IPA` + `Note unsigned fallback (no signing secrets)`（`if: env.IOS_P12_BASE64 == ''` 输出 warning） |
| §三 secrets 映射 | job 级 `env`（`IOS_P12_BASE64` / `IOS_P12_PASSWORD` / `IOS_PROFILE_BASE64` / `IOS_EXPORT_METHOD`） |
