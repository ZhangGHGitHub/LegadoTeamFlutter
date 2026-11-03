# P2-E1「冷启动导入深链」设备验收报告

> 范围：版本 **2.0.445+446**（HEAD `ec0a146d09`）的深链导入等待 UI 修复：
> 干净进程显式组件投递 `legado://import/bookSource?src=…` 与未知 host
> `legado://foo?src=…` 时，闪屏退出后仍出现关联导入确认框（不直接落书架）；
> 热路径立即弹框；取消后同一 URL 可再次投递；FATAL=0。
> 核心实现：`flutter_legado/lib/src/services/deep_link_service.dart`
>（`_handleImportUrlWhenUiReady` / `_scheduleUiReadyRetry` / `_lastHandled`）。
>
> 设备：MuMu 实例 index 1「Test测试」（adb `192.168.100.62:5555`），
> Android 15 / SDK 35 / x86_64；版本 2.0.445+446；APK sha256 `690767f1…`。
>
> **结论：B1/B2/B3 全部 PASS；B 路径本身无 FATAL/ANR/异常。**
> 首次冷启动画面背景出现的「上次运行发生崩溃」为 2b-2c 发现页 P1（报告
> `DEVICE_ACCEPTANCE_20261104_BATCH2B2C.md` P1-O1）的既有崩溃记录，不是本轮
> 深链路径产生；B2/B3 复核时已清除并确认不再出现。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu index 1「Test测试」，`is_android_started=true`） |
| 设备型号 / 系统 / ABI | SM-G9900（伪装）/ Android 15（SDK 35）/ x86_64 |
| 分辨率 / 密度 | 验收期间 `1920×1200` / `240`（1280×800dp）；结束 `wm size reset` / `wm density reset` 回 1080×1920 / 480 |
| 应用包名 / Activity | `io.legado.flutter_legado` / `io.legado.flutter.MainActivity` |
| 验收版本 | versionName **2.0.445** / versionCode **446** |
| APK | 200,697,868 B，sha256 **`690767f10584c978e07bce56cc44f7ff72376784828b8fe5c255113eab80e630`**；`adb install -r` Success；设备 base.apk 同哈希 |
| Rust | `build-android.ps1 -Mode release` EXIT=0；x86_64 `.so` 51,938,080 B / sha256 `5c29e4dd…` / `quickjs=true`（详见 2b-2c 报告 §1.1） |
| 门禁 | `flutter analyze` 0；`flutter test` **4129 passed + 1 skipped**；Rust retain 8/8；详见 2b-2c 报告 §1.2 |
| 导入夹具 | 宿主 mock `http://192.168.100.52:8899/source.json`：`{"bookSourceUrl":"https://qa.p2e1.local","bookSourceName":"QA_P2E1源",…}` |
| 验收时间 | 2026-11-03 22:50 ~ 22:53（宿主） |
| 证据目录 | `tmp_debug/device_acceptance_20261104/`；截图 `docs/materials_1109b/p2e1_*.png` |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 干净进程（`am force-stop` 后）显式组件投递 `legado://import/bookSource?src=<URL>`：闪屏退出后出现关联导入确认框，不直接落书架 | **PASS** | `p2e1_b01_cold_import_dialog.png`、`data/b01_cold_import_dialog.xml`、`logcat/deeplink_cold.log` |
| 2 | 干净进程投递未知 host `legado://foo?src=<URL>`：同样弹确认框 | **PASS** | `p2e1_b05_cold_unknown_host.png`、`data/b05_cold_unknown_host.xml` |
| 3 | 热路径（Activity 存活）立即弹框；取消后同一 URL 再次投递可再弹 | **PASS** | `p2e1_b06_hot_import_dialog.png`、`p2e1_b07_hot_again_after_cancel.png`、`p2e1_b08_hot_cancelled_final.png` |
| 4 | 不构造闪屏异常边界；FATAL=0 | **PASS** | `logcat/session_app.log`：FATAL EXCEPTION=0、ANR=0、E/flutter=0 |

## 三、逐场景证据

### 3.1 B1 冷启动 `legado://import/bookSource`

命令（`logcat/deeplink_cold.log`）：

```
adb -s 192.168.100.62:5555 shell "am force-stop io.legado.flutter_legado"
adb -s 192.168.100.62:5555 shell "am start -W -n io.legado.flutter_legado/io.legado.flutter.MainActivity \
  -a android.intent.action.VIEW -d 'legado://import/bookSource?src=http://192.168.100.52:8899/source.json'"
```

`am start -W` 返回 `Status: ok / LaunchState: COLD / Activity: …MainActivity / TotalTime: 443 / WaitTime: 444`。

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| 闪屏退出后弹框 | 关联导入确认框 | 6s 后截图：居中「导入书源」面板，列出 `QA_P2E1源 / 新增`，勾选 1/1，按钮「取消 / 确认（1）」（`p2e1_b01_cold_import_dialog.png`；语义 `data/b01_cold_import_dialog.xml`） |
| 不直接落书架 | 书架不被导入源污染 | 面板为模态；背景书架可见且无导入完成提示；取消后 DB `book_sources` 中 `QA_P2E1源` 计数 = **0**（`data/b03_import_cancelled.xml` 后查询） |
| 当前 Activity | 停留主界面 | `dumpsys activity activities` 顶层 `io.legado.flutter_legado/.MainActivity`（本报告验收时记录） |
| 背景提示 | 不应有本轮新崩溃 | 首次冷启动背景出现 A 批 P1 的「上次运行发生崩溃（22:45:45 Bad state）」，由 A 场景遗留；B2/B3 前已清除，后续不再出现（见 §3.4） |

> 说明：首次冷启动截图 `b01` 同时可见导入面板与背景崩溃提示；两者独立。导入面板在崩溃提示之上且可交互，说明闪屏替换后弹框逻辑生效。

### 3.2 B2 冷启动未知 host `legado://foo`

```
am force-stop …
am start -W -n …/MainActivity -a android.intent.action.VIEW -d 'legado://foo?src=http://192.168.100.52:8899/source.json'
```

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| 未知 host 仍按导入处理 | 弹导入确认框 | `Status: ok / COLD / TotalTime: 391`；6s 后「导入书源 / QA_P2E1源 新增 / 确认（1）」（`p2e1_b05_cold_unknown_host.png`、`data/b05_cold_unknown_host.xml`） |
| 不误判字典/落书架 | 不跳字典页、不直接导入 | 界面为导入面板；未出现字典页节点；取消后 DB 计数 0 |

### 3.3 B3 热路径与取消后可重投

| 步骤 | 实际 / 证据 |
|---|---|
| Activity 存活时投递 `legado://import/bookSource?src=…` | `am start` 返回 `Warning: Activity not started, intent has been delivered to currently running top-most instance.`；1.2s 内出现导入面板（`p2e1_b06_hot_import_dialog.png`、`data/b06_hot_import_dialog.xml`） |
| 点「取消」 | 面板关闭，回书架（`p2e1_b08_hot_cancelled_final.png`），DB 仍 0 |
| 同一 URL 再次投递 | 面板再次出现（`p2e1_b07_hot_again_after_cancel.png`、`data/b07_hot_again_after_cancel.xml`）；证明 `_lastHandled` 在取消/关闭时清理，去重仅限弹窗存续期 |
| 再次取消 | 面板关闭，无残留 |

### 3.4 稳定性

- `logcat/session_app.log`（全程 22:40~23:14，6454 行）：
  - `FATAL EXCEPTION` = **0**
  - `ANR in io.legado.flutter_legado` = **0**
  - `overflowed by` = **0**
  - `E/flutter` = **0**
- B1/B2/B3 投递期间无新增 Dart 异常；A 批 P1 的 `Bad state: Too many elements` 仍作为独立缺陷记录在 2b-2c 报告，不计入 B 通过条件。
- 未构造「闪屏异常滞留 90 帧后强制展示/放弃」边界（任务明确可不构造）。

## 四、问题与观察清单

| 编号 | 级别 | 描述 | 影响 / 建议 |
|---|---|---|---|
| P2E1-O1 | P3（观察） | 冷启动首次画面背景出现 A 批 P1 的「上次运行发生崩溃」提示，会遮住部分背景但导入面板在其上层可操作 | 修复 A 批 P1 后消失；不影响 B 行为 |
| P2E1-O2 | P3（既有） | 导入面板为旧 UI 形态（「自定义分组/重置/打开」等），与参考版视觉差异未在本批比对 | 2b-2c/9b-3 均未触及；登记待视觉专项 |

**未覆盖 / 声明**：
- 闪屏异常滞留 90 帧后强制展示/放弃分支未构造（任务允许）。
- iOS `app_links` 初始链未验证（本机 Android）。
- 去重仅弹窗存续期；同 URL 在面板存续期间重复投递不叠框，未单独截图（实现与热路径一致）。

## 五、证据与产物索引

| 类别 | 路径 |
|---|---|
| 冷启动命令/输出 | `tmp_debug/device_acceptance_20261104/logcat/deeplink_cold.log` |
| 会话日志 | `tmp_debug/device_acceptance_20261104/logcat/session_app.log` |
| 语义树 | `tmp_debug/device_acceptance_20261104/data/b01_cold_import_dialog.xml`、`b05_cold_unknown_host.xml`、`b06_hot_import_dialog.xml`、`b07_hot_again_after_cancel.xml`、`b08…` |
| 截图 | `docs/materials_1109b/p2e1_*.png`（`b01`~`b08`） |
| 版本/哈希 | `tmp_debug/device_acceptance_20261104/data/version_installed.txt`、`apk_sha256.txt` |

---

编写：QA（设备验收子代理） · 2026-11-03
