# re3 草稿：2.0.328 装机冒烟（快速）STAGE5-SMOKE-328

- 任务：STAGE5-SMOKE-328（2026-09-29/30）
- HEAD：7b7bbe6175（版本 2.0.328+329）
- 设备：192.168.100.62:5555（MuMu Test测试）
- 产出前缀：re3_*

## 步骤 1：冒烟
- [x] pwsh emulator_smoke_test.ps1 -Device 192.168.100.62:5555（首次调用因 Git Bash 反斜杠路径被转义成 .scriptsemulator_smoke_test.ps1 报 64，改正斜杠绝对路径重跑成功）
- 退出码：0（汇总 PASSED，7 PASS / 0 FAIL）
- 构建形态：flutter build apk --debug 全量执行（Gradle assembleDebug 14.0s，√ Built build/app/outputs/flutter-apk/app-debug.apk，282.3 MB）；FFI content hash 校验通过（复用现有 .so，arm64/x86_64 指纹一致）
- 版本复核：已装版本与 pubspec 一致 2.0.328（HEAD=7b7bbe6175）
- FATAL：无崩溃日志（FATAL/E/flutter 均无）；进程存活 pid 27515
- 证据：re3_smoke_raw.log

## 步骤 2：漫画屏点验
- [x] 启动应用（冒烟启动 pid 27515；后 force-stop 重进，最终存活无 FATAL）
- [x] 书架打开漫画：书架共 4 本（进度 100/17/50/0）。第 3 本=漫画（国漫·冒险·连载中，共 101 章，已读 51 章=50%），来源=七七漫画；第 4 本=《海贼王》（来源=非凡资源网，1180 章）。点封面直达阅读器（续读）。
- [x] 阅读器出图：全屏 ImageView [0,0][1080,1920] 正常渲染（首图 1.7MB PNG 非空白）；控制栏=返回/漫画设置/50%；漫画设置：阅读模式=从上到下（T2B 单页）、全屏适配、自动翻页 OFF、灰度/电子纸。
- [x] 翻页：T2B 模式上滑翻页，前后 screencap 哈希不同（5eadc061… → b92e9603…）= 页面已切换，翻页生效。
- [x] 退出：点「返回」退回书架，无异常。
- [x] 截图：re3_20_manga_reader_p1.png（首屏）/ re3_22_manga_reader_p1.png（翻页前）/ re3_21_manga_reader_p2.png（翻页后）。
- 来源说明：本机书架 4 书均非 tuku.cc/天脉漫画源（RE2 曾用《咒术回战》=天脉漫画，已不在书架）；换源面板可开（源名在 a11y 树不可读），未做换源以免改数据。漫画屏出图+翻页已在漫画书上验证无回归。

## 关键陷阱记录
- Git Bash 下 `adb shell uiautomator dump /sdcard/window.xml` 被 MSYS 路径转换破坏 → 一直 pull 到旧文件（表象：dump 不随界面变化）。解法：export MSYS_NO_PATHCONV=1 或参数用双斜杠/唯一文件名。
- `pwsh -File .\scripts\...ps1` 在 Git Bash 下反斜杠被转义成 .scriptsemulator_smoke_test.ps1（退出码 64）→ 改正斜杠绝对路径。
- uiautomator dump 进程 Shutdown thread 偶发 SIGSEGV（无害，但可能导致当次不写文件）。
- 书架/搜索框点选「无响应」的表象多为读到旧 dump 所致，非输入失效（原生 input tap/keyevent 实际生效）。

## 结论
- 冒烟 7/7 通过（构建形态=flutter build apk --debug 全量、版本 2.0.328 与 pubspec 一致、FFI hash 通过、无 FATAL）。
- 漫画屏无回归：出图正常 + 翻页正常 + 退出正常。
- 设备 192.168.100.62:5555 可用。
- 未改任何生产代码；未做换源/导入等数据变更。
