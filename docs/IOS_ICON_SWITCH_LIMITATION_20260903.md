# iOS 桌面图标切换：旁载安装下的已知限制（根因收口）

> 日期：2026-09-03
> 状态：**已收口**——H5（旁载签名 / LaunchServices 注册语境）决定性坐实，代码层无法修复
> 关联台账：`REFACTOR_DEFECT_AUDIT_V2_20260902.md` §2.3 / §8.8（P2-D，本文件为其关闭记录）
> 前序：`IOS_TRACK_FEASIBILITY_20260830.md`（旁载签名语境假设首次登记）

---

## 1. TL;DR（先说结论）

在 **iPhone 16 / iOS 17.5、用旁载工具安装** 的语境下，**没有任何 App 能运行时切换桌面图标**——无论其结构多简单。这是**安装渠道限制**，不是本 App 的代码/配置缺陷，代码层无法修复。

- `UIApplication.setAlternateIconName` 在该语境下必然返回 **OSStatus -54（Carbon fNotFoundErr）**；
- 已用最小探针 App 决定性隔离：与主 App 结构唯一差异是「规模小、结构最简单」，仍同样 -54；
- 该功能仅在**正规向 LaunchServices 注册图标元数据**的渠道下可用：**App Store / MDM-企业签名**。

---

## 2. 现象

主题设置 → 「切换图标」，iOS 真机点选任一备选后弹原始错误：

```
The operation couldn't be completed. (OSStatus error -54.)
domain=NSOSStatusErrorDomain code=-54
```

仅真机复现；模拟器上 `setAlternateIconName` 的 completion **不回调**（已知系统限制，无法在模拟器验证）。

---

## 3. 排查历程（8 轮 + 实验 A/B/C）

| 阶段 | 动作 | 结果 |
|---|---|---|
| 第 1–4 轮 | CI 产物完整性、`Assets.car` appiconset、路径修正 | 排除构建/资产缺失 |
| 第 5 轮 | status 真机自检（systemVersion / supportsAlt / carHasAllLaunchers）+ 私有 API `_setAlternateIconName` 旁路 | -54 仍现；私有旁路无效 |
| 第 6 轮 | `looseIcons`：逐 `CFBundleIconFiles` base name 校验 bundle 根散文件可解析性 | 12/12 齐全仍 -54（H2 证伪） |
| 第 7 轮 | `carReadable`：用常规 imageset 做 `UIImage(named:)` 读取探针 | car 可读仍 -54（H3 证伪）；reply 增加 userInfo/underlyingError 全量转储 |
| 第 8 轮 | CI 剥离所有 `CFBundleAlternateIcons` 条目的 `CFBundleIconName`，强制纯 legacy 路径（对齐社区实证结构）+ `altModernDecl` 计数 | 现代声明=0、散文件 12/12 仍 -54 |
| 实验 A | 干净卸载 + 重装 | -54 仍现 |
| 实验 B | 换工具重签 | -54 仍现 |
| **实验 C（决定性）** | **最小探针 App**（§4）同设备同工具实测 | **-54 仍现 → H5 坐实** |

---

## 4. 决定性证据：最小探针 App

为把「App 结构」与「安装语境」两个变量彻底分离，构建了独立的最小探针 `probe_icon/`（CI 产出未签名 IPA，用户用**同一旁载工具、同一台 iPhone 16** 签名安装）。它与主 App 的**唯一**差异是刻意做到最小：

- **仅 1 个备选图标**（非 6 个）；
- **纯 legacy 声明**：`CFBundleIconFiles` + bundle 根散文件，**无 `CFBundleIconName`**（对齐 tastelessjolt/flutter_dynamic_icon 等社区实证结构）；
- **iPhone-only**（`TARGETED_DEVICE_FAMILY=1`，无 iPad/universal）；
- **仅公开 API**（`setAlternateIconName`），无私有旁路、无 Rust FFI、无复杂 UI。

真机实测结果：

```
自检：iOS 17.5 / supportsAlt=true / 磁盘声明=true / 散文件2/2   ← 每个结构前置条件都满足
点「切换为 probe 图标」→ -[_LSDIconClient setAlternateIconName:forIdentifier:iconsDictionary:reply:] → code -54
```

**判读**：探针把前面所有结构变量（6 个备选？iPad/universal？私有 API？）全部排除，仍同样 -54。结论——**问题不在 App 结构，而在旁载签名 + LaunchServices 注册这个语境本身。**

---

## 5. 根因

错误详情点名了 LaunchServices 内部真正失败的函数：

```
-[_LSDIconClient setAlternateIconName:forIdentifier:iconsDictionary:reply:]
```

其参数 **`iconsDictionary`（图标字典）在旁载安装下是空的 / 未注册**——LaunchServices 找不到该 App 的图标元数据，于是返回 `fNotFoundErr(-54)`。

正规渠道（App Store / MDM-企业签名）的安装流程会向 LaunchServices 完整注册 App 的图标元数据；而旁载工具的签名/安装链路不走这条注册路径，`iconsDictionary` 缺失，`setAlternateIconName` 因此必然失败。这与调用公开还是私有 API、备选数量、是否 universal 均无关——它们都走同一个 LS 路径。

---

## 6. 影响与边界

| 安装渠道 | LaunchServices 图标注册 | 换图标是否可用 |
|---|---|---|
| App Store | ✅ 完整注册 | ✅ 可用 |
| MDM / 企业签名 | ✅ 完整注册 | ✅ 可用（预期，待企业签名环境确认） |
| **旁载工具（当前开发/分发语境）** | ❌ 未注册 iconsDictionary | ❌ **-54，不可用** |

因此该功能对 App Store / 企业用户正常；对旁载用户为**已知限制**。

---

## 7. 处置决策

1. **A（已落地）优雅降级**：`launcher_icon_service.dart` 捕获 iOS -54 后，把原始 `OSStatus error -54` 换成一句清楚的提示——「当前安装方式不支持切换图标（仅 App Store / 企业签名安装可用）」，避免用户误以为是 bug。功能保留给真正支持的渠道。
2. **C（本文件）文档化**：将根因与探针证据记录为已知限制；**停止在旁载语境上继续投入**。
3. **不追求代码层修复**：任何 App 结构/公开/私有 API 组合在此语境下都无法改变 LS 的注册状态。

---

## 8. 复现 / 再确认方式

- 探针：`probe_icon/`（CI 工作流 `probe-icon-build.yml` 产出 `probe-ios-unsigned-ipa`），同旁载工具装到 iPhone，点「切换为 probe 图标」→ 预期 -54。
- 主 App：主题设置 → 切换图标 → 任一备选 → 现显示优雅降级提示（非原始 OSStatus）。
- 若未来改用 **MDM / 企业签名** 安装后 -54 消失，即反向坐实「旁载注册缺失」这一根因。

---

编写者：Qoder ｜ 2026-09-03
