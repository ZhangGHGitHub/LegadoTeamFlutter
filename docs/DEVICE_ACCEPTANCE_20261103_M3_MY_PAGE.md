# 批 M3「我的」页设备验收报告（footer 入组 · 容器背景/边框包裹 · 字典深链）

> 范围：版本 **2.0.440+441**（HEAD `1a8155799a`）「我的」页 M3 边缘与一致性：
> `IosGroup(footer:)` 新增分组脚注能力；Web 服务运行中「复制地址 / 在浏览器中打开」
> 由组外回移分组容器内；`legado://dict` / `legado://dict_rule` 外部深链路由映射
>（冷启动等闪屏、热路径去重、pop 后可重开）；import 深链语义回归。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`），Android 15 / SDK 35 / x86_64，
> 1080×1920 / 480 dpi（**360×640 dp**）。
> 参考文档：`docs/MY_PAGE_ALIGNMENT_PLAN_20261103.md` §六 M3 记录、
> `docs/DEVICE_ACCEPTANCE_20261103_M2_MY_PAGE.md`（格式与基线）。
>
> **结论：7 组验收场景全部 PASS（M3 范围内 P1=0、P2=0；P3 均为既有项/排版观察）。**
> 目标行为逐项实测成立：运行中动作行位于分组容器内（不套行卡、无分隔线/2dp 行距、
> 12dp 上内边距、右对齐 16dp），开启容器背景图 + 自定义边框/圆角时**同一图片层、
> 同一圆角裁剪、同一 1dp 边框**完整包裹动作行（像素取证）；点按动作按钮不切换开关、
> 不停服；停止后动作行收起；字体 1.3/1.6 无溢出。
> 冷启动 `legado://dict` → 字典查询、`legado://dict_rule` → 字典规则管理，
> `legado:///dict`、`legado://dict?x=1`、`legado://dict/`、`yuedu://dict` 全部落字典查询页；
> 热路径前台/后台投递正确导航，同 URI 存续期内不重复 push（返回一次回到原页），
> pop 后可再次打开；`legado://import/...` 与未知 host `legado://foo` 仍为关联导入语义，
> 未被误判为字典；返回栈与底栏状态保持；FATAL=0、ANR=0、overflow=0、E/flutter=0。
> 既有项（非本批引入，已登记）：冷启动 import 深链不弹确认框、字典页首次系统返回被
> 输入焦点吞掉、导入面板同会话复用旧错误、Web 开关与副题冷启动不一致、删除书籍后
> 书架不即时刷新。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ x86_64 |
| 分辨率 / 密度 | 1080×1920 / 480 dpi（3x，即 **360×640 dp**） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 设备 root | `adb shell id` = `uid=0(root)`（可读取 `shared_prefs` 取证） |
| 应用包名 / Activity | `io.legado.flutter_legado` / `io.legado.flutter.MainActivity`（singleTop） |
| 验收版本 | versionName **2.0.440** / versionCode **441**（安装后与清理后各复核） |
| 源码基线 | `master` HEAD **`1a8155799a1e271d43b8216f6ab5a31d6eaceb93`**（`chore: M3 我的页收尾（2.0.440+441 双日志与计划登记）`） |
| 同机其他 legado 应用 | `com.legado.app.release`（原版）、`io.legato.kazusa` 3.26.19（参考版） |
| 验收时间 | 2026-11-03 12:01 ~ 12:32（宿主时间） |
| 证据目录 | `tmp_debug/device_acceptance_20261103_m3/`（logcat/data/scripts/shots，不入库） |
| 截图 | `docs/materials_1106/`（62 张：`m3_00`~`m3_59`） |

### 1.1 构建产物（本批仅 Dart/UI，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（本批无 Rust/FFI 变更） |
| x86_64 `.so` | `liblegado_ffi.so` **51,883,696 B**，mtime **2026-10-31 23:45**，sha256 **`7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e`**（`data/so_info.txt`） |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 35.2s`，**200,271,504 B（191.0 MB）**；sha256 **`7b9315a1e7c12416bd9b2443a491d38b79d51a97adc718a63fb20c820eae37f8`**（`logcat/build_release.log`、`data/apk_sha256.txt`） |
| 安装 | `adb install -r` **Success: streamed 200271504 bytes**（`logcat/install.log`）；设备侧 `base.apk` sha256 与构建产物**一致**（`data/apk_sha256_installed.txt`） |
| 通知权限 | `POST_NOTIFICATIONS: granted=true`（沿用 M1/M2 授权，未再弹窗） |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `flutter analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（11.8s，`logcat/analyze.log`） |
| 本批定向测试 | `flutter test test/widget/ios_group_footer_test.dart test/widget/deep_link_route_dispatch_test.dart test/unit/legado_deep_link_test.dart test/widget/my_page_m1_test.dart test/widget/settings_test.dart` | **82/82 passed**，EXIT=0（`logcat/targeted_tests.log`） |
| 全量 Flutter 测试 | `flutter test` | **3971 passed + 1 skipped**，EXIT=0（1:34，`logcat/full_tests.log`） |
| Release 构建 / 安装 | `flutter build apk --release` + `adb install -r` | EXIT=0 / Success（见 §1.1） |

> 门禁、构建、安装串行执行，避免 `flutter test` 与 `flutter build` 并发触发
> `GeneratedPluginRegistrant.java` 竞态；设备操作在门禁完成后进行。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | footer 入组：运行中动作行位于分组容器底部；不套行卡/不分隔线/12dp 上距/右对齐 16dp；容器背景图 + 自定义边框/圆角完整包裹；停止收起；点按不切换开关；字体 1.3/1.6 无溢出 | **PASS**（排版观察 P3-O2） | `m3_02`、`m3_03`、`m3_04`、`m3_08`、`m3_09`、`m3_10`、`m3_11`、`m3_53`；`data/02_web_running.xml`、`04_web_stopped.xml`、`22_my_combo_running.xml`、`24_font16.xml`、`25_font13.xml` |
| 2 | 冷启动深链：`legado://dict` → 字典查询；`legado://dict_rule` → 字典规则管理；`legado:///dict`、`?x=1`、末尾斜杠、`yuedu://` → 字典查询；等闪屏退出后落页 | **PASS** | `m3_12`、`m3_13`、`m3_14_*`（4 张）、`m3_56`、`m3_57`；`data/44_cold_dict.xml`、`45_cold_dict_rule.xml`、`variant_1.xml`~`variant_4.xml` |
| 3 | 热路径深链：前台/后台投递正确导航；同 URI 存续期内不重复 push（返回一次回原页）；pop 后可再打开 | **PASS** | `m3_15`、`m3_16`、`m3_17`、`m3_19`、`m3_20`、`m3_58`；`data/47_hot_dict.xml`、`48_hot_dup.xml`、`61_push.xml`、`62_after_ui_back.xml`、`63_pop_reopen.xml`、`64_bg_delivery.xml` |
| 4 | import 回归：`legado://import/bookSource?src=...` 打开关联导入确认框；未知 host `legado://foo` 仍导入语义、不误判字典 | **PASS**（hot；冷启动既有缺口见 §五） | `m3_21`、`m3_28`、`m3_30`；`data/65_import_booksource.xml`、`72_hot_import.xml`、`74_unknown_clean.xml` |
| 5 | 返回栈：深链进字典 → 返回原页面（我的/首页/书架）；底栏状态不丢失 | **PASS**（系统返回首按被输入焦点吞掉，UI 返回正常，既有） | `m3_18`、`m3_31`、`m3_58`；`data/54_back_ui.xml`、`77_back_home.xml` |
| 6 | 回归：Web 服务复制/打开/地址刷新、AI 占位、服务与工具、首页导航、阅读；FATAL/ANR/overflow=0 | **PASS** | `m3_32`~`m3_50`；`data/79_home_search.xml`、`95_pasted.xml`、`96_browser.xml`、`100_after_restore.xml`、`102_ai_chat.xml`、`108_auto_task_page.xml`、`109_mcp.xml`、`118_reader.xml`、`119_reader_next.xml`；`logcat/session_main.log`、`session_final.log`、`crash_final.log` |
| 7 | 清理：停服务、恢复外观/主题/字体、空书架、保留版本 | **PASS** | `m3_53`、`m3_54`、`m3_55`；`data/prefs_final.xml`、`version_final.txt` |

## 三、逐场景证据

### 3.1 场景 1：footer 入组（PASS）

**步骤**：安装后冷启动 → 底栏「我的」→ 截图/语义树（停止态）→ 点「Web 服务」行 → 运行态截图/语义树 →
点「复制地址」→ 语义树复核开关 → 点「Web 服务」停止 → 收尾截图；随后走真实设置路径
（设置→外观→容器设置）开启容器背景图（SAF 选图）+「覆盖卡片圆角」16dp +「覆盖卡片边框」1dp，
复测运行态；再切字体 1.6 / 1.3 复测；最后全部恢复。

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| 运行中动作行位置 | 分组容器内、最后一行下方 | 开关行 `[48,552][1032,768]`；动作行 `复制地址 [159,804][490,948]`、`在浏览器中打开 [526,804][984,948]`；**行底到按钮顶 36 px = 12dp**（`footerPadding` 上内边距），按钮右缘 984 = 容器右缘 1032 − **16dp**；下一分组标题「规则」由停止态 768 下移到 **984**，即容器高度包含 footer（`data/02_web_running.xml`、`04_web_stopped.xml`） |
| 不套行卡 | 动作行无 surfaceContainerLow 卡片面 | 默认主题下按钮区像素 `(245,245,245)`＝页面背景，行卡区 `(240,240,240)`；开启容器背景图后按钮区透出图片（见下）→ 无行卡 |
| 不参与分隔线 / 2dp 行距 | 行与 footer 之间无 Divider、无 2dp SizedBox | 行底 768 → 按钮顶 804 之间无分隔线节点，间距即 12dp 内边距；按钮底 948 → 容器底 984 为 12dp 内边距（`m3_02`） |
| 右对齐 / 大字体换行 | 右对齐、1.3/1.6 换行不溢出 | 1.0：两按钮同排右对齐（右缘 984）；1.3：按钮上下两排，`[620,858][984,1002]`、`[450,1014][984,1158]`；1.6：`[592,984][984,1128]`、`[386,1140][984,1284]`；`overflowed by`=**0**（`m3_11`、`m3_10`；`logcat/session_main.log`） |
| 点按不切换开关 | 复制/打开不影响开关与服务 | 点「复制地址」后 `Web 服务 chk=true`、地址不变、动作行仍在（`m3_03`、`data/03_after_copy.xml`）；点「在浏览器中打开」并返回后 `chk=true`、地址不变、动作行仍在，宿主 `curl` **HTTP 200**（`data/99_after_browser_back.xml`；浏览器页 `m3_40`） |
| 停止后收起 | 地址/动作行消失、容器高度回落 | 停止后副题回「用浏览器写源或看书」，动作节点消失，「规则」标题回 **768**；宿主 `curl` **HTTP 000**、无 `WebServerForegroundService`（`m3_04`、`m3_53`） |
| 容器背景图 + 边框/圆角包裹 | 动作行被同一容器图片层/圆角裁剪/边框包裹 | 开启后（`m3_08`）：按钮区像素为图片色（`(250,200,40)` 黄、`(30,120,220)` 蓝、左缘 `(220,30,30)` 红），页面背景为 `(245,245,245)`；容器底缘 y≈982 处为 **1dp 边框色 `(216,196,190)`**，随后才是页面背景；底部圆角内图片按 16dp 圆角收边（x=1000 处图片止于 978）→ **同一图片层 + 同一圆角裁剪 + 同一边框**完整包裹动作行（`data/22_my_combo_running.xml`） |
| 容器背景图来源 | 真实用户路径 | 外观→容器设置→「容器背景图」开→「容器背景图片（日间）」→ SAF 选择 `/sdcard/Download/qa_m3_bg.png` → 落盘 `files/theme_backgrounds/large_light/e6165b495e7f300ff105a9717370fcf5.png`（`m3_07`、`data/12_saf.xml`、`14_after_pick.xml`） |
| 恢复 | 关闭三项并移除图片 | `data/prefs_final.xml`：`enableContainerBackgroundImage=false`、`overrideBaseCardCornerRadius=false`、`overrideBaseCardBorder=false`、`baseCardBorderWidth=1`；`files/theme_backgrounds/` 已删除 |

- **说明**：默认主题下分组本身无整卡底色（与参考版 `SplicedColumnGroup` 一致，行卡才是
  surfaceContainerLow），因此 footer 区在默认主题显示页面背景色属预期；「同容器」由
  容器背景图/圆角/边框组合与布局高度共同证明。
- **既有排版观察 P3-O2**：1.6 字体下地址仍按字符断行（`http://` / `192.168.100.62:112` / `2`），
  无溢出；该现象 M2 已登记 P3-3，本批 footer 换行本身正常。
- **未覆盖**：`containerOpacity < 100` 的视觉叠加本轮未在设备复核（由
  `ios_group_footer_test` 覆盖「footer 不乘 containerOpacity」）；深色主题未复测（M2 已覆盖行卡/动作行）。

### 3.2 场景 2：冷启动深链（PASS）

**方法**：`am force-stop` → `am start -n io.legado.flutter_legado/io.legado.flutter.MainActivity -a android.intent.action.VIEW -d "<URI>"` →
等待 12s → 语义树/截图。**说明**：同机安装原版与参考版，三者都声明 `legado` scheme，
`am start -d` 会弹系统解析器（`data/43_cold_dict.xml` 首次尝试可见「使用阅读打开/仅此一次/始终」）。
为消除歧义，统一用显式组件投递（action/data 不变，应用侧分流路径一致）。

| URI | 预期 | 实际 / 证据 |
|---|---|---|
| `legado://dict` | 字典查询页 | 顶栏「字典查询」+ 查询输入 +「输入单词开始查询」；无导入框（`m3_12`、`m3_57`、`data/44_cold_dict.xml`） |
| `legado://dict_rule` | 字典规则管理页 | 顶栏「字典规则管理」+ 海词中文/英文/有道/哔哩/百度汉语列表（`m3_13`、`data/45_cold_dict_rule.xml`） |
| `legado:///dict` | 字典查询页 | 同 `legado://dict`（`m3_14_variant_legado____dict.png`，`data/variant_1.xml`） |
| `legado://dict?x=1` | 字典查询页（query 忽略） | 同上（`m3_14_variant_legado___dict_x_1.png`，`data/variant_2.xml`） |
| `legado://dict/` | 字典查询页（末尾斜杠） | 同上（`m3_14_variant_legado___dict_.png`，`data/variant_3.xml`） |
| `yuedu://dict` | 字典查询页 | 同上（`m3_14_variant_yuedu___dict.png`，`data/variant_4.xml`） |
| 等闪屏退出后落页 | 闪屏期间不抢栈，退出后落字典页 | 冷启动 +1s 帧（`m3_56`）可见「字典查询」已压在淡出的书架/闪屏之上；+4s 帧（`m3_57`）为稳定的字典查询页 |

- **结论**：PASS。六个 URI 全部落目标页，无关联导入弹窗、无空白/栈错乱。

### 3.3 场景 3：热路径深链（PASS）

| 子项 | 步骤 | 预期 | 实际 / 证据 |
|---|---|---|---|
| 前台投递 | 我的页 → `am start … -d legado://dict`（Activity 在前台，系统提示 intent delivered to running instance） | 导航到字典查询 | 字典查询页（`m3_15`、`data/47_hot_dict.xml`） |
| 同 URI 去重 | 字典页存续期内再次投递同一 URI → 点左上角 UI 返回一次 | 不叠栈；返回回到原页面 | 一次返回直达「书架」（push 来源页），未再出现字典页（`m3_58`；受控序列 dump `61_push.xml`→`62_after_ui_back.xml` 亦显示回到「我的」） |
| pop 后可重开 | 返回原页后再次投递同一 URI | 重新打开字典页 | 字典查询页再次出现（`m3_19`、`data/63_pop_reopen.xml`） |
| 后台投递 | Home 键 → 投递 `legado://dict_rule` | 回到前台并落字典规则管理 | `topResumedActivity` 为本应用；页面「字典规则管理」（`m3_20`、`data/64_bg_delivery.xml`） |

- **说明（既有行为）**：字典查询页的输入框 `autofocus: true`，页面刚进入时**首次系统返回键会被
  输入焦点消费**，需再按一次或点顶栏返回。该现象在「我的→字典规则→字典查询」普通入口同样复现
  （`data/58_dict_from_entry.xml` → `59_back_from_entry.xml`），**与深链无关、非本批引入**（见 §五 P3-O1）。

### 3.4 场景 4：import 回归（PASS，hot；冷启动缺口见 §五）

| 子项 | 步骤 | 预期 | 实际 / 证据 |
|---|---|---|---|
| 书源导入深链 | 前台投递 `legado://import/bookSource?src=https%3A%2F%2Fexample.com%2Fqa_m3_bs3.json` | 打开关联导入确认框 | 弹出「关联导入」面板，显示 `HTTP 请求失败：状态码 404`（example.com 无该文件，属预期），可重置/重试（`m3_28`、`data/72_hot_import.xml`） |
| 未知 host | 干净进程启动后前台投递 `legado://foo` | 仍为导入语义、不判字典 | 空白「关联导入」面板：扫码导入 / 从文件 / 从剪贴板 / 加载 + 自动识别说明；未进入字典页（`m3_30`、`data/74_unknown_clean.xml`） |
| 不误判 | 上述两 URI | 不 push 字典/字典规则 | 两次均无字典页面节点 |

- **既有观察 P3-O3**：同会话内先做一次失败导入、再投递另一个 import URI 时，面板会复用上一次的
  错误态（`legado://foo` 也显示旧的 `HTTP 404`，`m3_29`、`data/73_hot_unknown.xml`）；新进程首投
  `legado://foo` 为空白导入页（`m3_30`）。属关联导入面板既有状态复用行为，非 M3 改动。
- **既有缺口（P2-既有）**：进程未启动时直接投递 `legado://import/...` 或 `legado://foo`，
  2s/10s 两帧均未出现导入确认框，最终落书架（`m3_26`、`m3_27`）；hot 路径正常。
  M3 diff 未触及导入分流；推测为闪屏 `pushReplacementNamed(home)` 替换弹窗的既有竞态
  （M3 只为路由深链新增了 `isSplashVisible` 等待）。**未在 M2 基线复测**（M2 APK 未保留），
  按既有缺陷登记，建议单独立项修复并补冷启动用例。

### 3.5 场景 5：返回栈（PASS）

| 起点 | 步骤 | 实际 / 证据 |
|---|---|---|
| 我的 | 我的页 → 投递 `legado://dict` → 点顶栏返回 | 回到「我的」页，底栏「我的」保持选中（`m3_18`、`data/54_back_ui.xml`） |
| 首页 | 首页 → 投递 `legado://dict` → 点顶栏返回 | 回「首页」，底栏「首页」胶囊高亮保持（`m3_31`、`data/77_back_home.xml`） |
| 书架 | 书架（冷启动根页）→ 投递 `legado://dict` → 点顶栏返回 | 回「书架」（`m3_58`） |
| 字典规则 | 我的 → 字典规则管理 → 系统返回一次 | 回「我的」，底栏不变（`data/56_back_rule.xml`） |

- **结论**：深链 push 不破坏底栏选中态与返回栈；返回一次即回原页面。

### 3.6 场景 6：回归（PASS）

| 检查点 | 实测 | 证据 |
|---|---|---|
| 复制地址 | Toast「已复制访问地址」；在应用内搜索框粘贴得到 **`http://192.168.100.62:1122`**；开关不变 | `m3_35`、`m3_36`~`m3_39`；`data/89b_copy_toast.xml`、`95_pasted.xml` |
| 浏览器打开 | 打开 Chrome（`topResumedActivity=com.android.chromium/...ChromeTabbedActivity`），显示 Legado web 导航（书架/书源/传书/订阅源） | `m3_40`；`data/96_browser.xml` |
| 浏览器返回 | 回应用后开关仍开、地址不变、动作行仍在；宿主 `curl` **HTTP 200** | `data/99_after_browser_back.xml` |
| 地址刷新（断网） | `MuMuManager sh -v 1 -c "svc wifi disable"` → Home → 回前台：副题 **`http://127.0.0.1:1122（本机）`**，动作行仍在 | `m3_41`（离线帧经 MuMuManager `screencap` 取出） |
| 地址刷新（恢复） | `svc wifi enable` → Home/回前台：副题回 **`http://192.168.100.62:1122`**；`curl` **200** | `m3_42`、`data/100_after_restore.xml`、`data/curl_web.txt`（200/200/200/000） |
| AI 聊天占位 | 入口「AI 聊天 / 暂未支持，待 Rust 能力接入」→ 页面「AI 聊天暂未支持 / 待 Rust 能力接入后开放」，无输入框，可返回 | `m3_43`、`data/102_ai_chat.xml` |
| 服务与工具 | 「定时任务」页可达（空态「暂无定时任务」）；「运行定时任务」开关可开/关并复核为关；MCP 前置提示 SnackBar（token 未配置），开关保持关、不崩溃 | `m3_45`、`m3_46`、`m3_47`；`data/104_autotask_off.xml`、`108_auto_task_page.xml`、`109_mcp.xml` |
| 首页/发现/订阅导航 | 底栏四页均可进入：「发现」空态提示、「订阅」规则页、「首页」统计卡 | `data/122_discover.xml`、`123_rss.xml`、`124_home.xml` |
| 阅读 | 导入本地 TXT（SAF）→ 书架出现「qa_m3_book」→ 打开阅读页渲染正文 → 点右侧翻页（1/1 50%→100%，章节「第一章」→「第二章」）→ 返回 | `m3_48`、`m3_49`、`m3_50`；`data/117_after_import.xml`、`118_reader.xml`、`119_reader_next.xml` |
| 稳定性 | 两个日志窗口合计 **22,918 行**：`FATAL EXCEPTION`=**0**、`ANR in io.legado`=**0**、`RenderFlex overflowed`=**0**、`E/flutter`=**0**；crash buffer 508 行中 `io.legado` **0** 条（仅 `uiautomator` 进程自身退出段错误，属取证工具） | `logcat/session_main.log`、`session_final.log`、`crash_final.log` |

- **说明**：断网期间 adb 走 wlan0 一并断开，改用 `MuMuManager.exe sh -v 1 -c`
  执行 `svc wifi`/`input keyevent`/`am start`/`screencap`；恢复网络后 `adb pull`
  取证，截图校验为 1080×1920 PNG，IP 与断网前一致（`192.168.100.62/24`）。
- **既有缺陷（非本批，未修复）**：
  1. **Web 服务配置镜像**（M1 登记 P3）：冷启动后开关显示「开」但副题为 `stopped`、服务未起
     （`data/139_my_state.xml`，随后点按变为关）；本批未改动该状态机。
  2. **书架删除刷新**（M1 登记 P3）：管理态删除书籍后返回书架仍显示旧行（`m3_51`），
     冷启动后为空书架（`m3_52`）。

### 3.7 场景 7：清理（PASS）

| 步骤 | 结果 | 证据 |
|---|---|---|
| 停 Web 服务 | 开关关、副题回默认、动作行消失、`curl` **000**、无 `WebServerForegroundService` | `m3_53`、`data/140_web_stopped.xml`；`dumpsys activity services` 计数 0 |
| 恢复主题模式 | `app_theme_mode=system`，界面浅色 | `data/prefs_final.xml`、`m3_55` |
| 恢复外观 | 容器背景图/圆角/边框均关；`baseCardBorderWidth=1`；`theme_backgrounds/` 已删；`largeContainerBackgroundImage*` 键已移除 | `data/prefs_final.xml` |
| 字体 | `settings get system font_scale` = **1.0** | adb 实测 |
| 书架 | 空书架（测试书已删除，重启后空态） | `m3_52`、`m3_54` |
| 测试文件 | `/sdcard/Download/qa_m3_bg.png`、`/sdcard/Download/qa_m3_book.txt`、`/sdcard/qa_m3_offline.png`、`/sdcard/qa_ui.xml` 已删除；`ls` 无匹配 | adb `ls` |
| 版本保留 | **2.0.440 / 441** | `data/version_final.txt` |

## 四、与 M2 结论对照

| 维度 | M2（2.0.439+440） | M3（2.0.440+441） | 判定 |
|---|---|---|---|
| 动作行容器归属 | 分组外贴邻（4dp） | **分组内 footer**（容器内、12dp 内边距、右对齐 16dp） | 已闭环（M2 P3-2） |
| 容器背景图/圆角/边框 | 动作行在组外，不被包裹 | 同一图片层/圆角/边框完整包裹（像素取证） | 已闭环 |
| 动作行与行卡/分隔线 | 组外独立按钮区 | 不套行卡、不插分隔线/2dp 行距 | 符合 M3 计划 |
| 停止态 | 动作行收起 | 收起且容器高度回落（规则标题 984→768） | 一致 |
| 复制/打开不切换开关 | 是 | 是（默认与容器组合下均复核） | 一致 |
| 外部 `legado://dict*` | M1 登记「非既有深链契约」（P2） | **冷/热路径均为应用内路由**，含变体；import/未知 host 语义不变 | 已实现（M1 遗留口径已落地） |
| 大字体 | 1.3/1.6 无溢出，地址断词（P3-3） | 无溢出；footer 两排右对齐；地址断词仍在（P3-O2） | 保持 |
| 门禁 | analyze 0；3953+1 | analyze 0；**3971+1**（+18） | 一致增量 |

## 五、问题清单与分级

| 级别 | 编号 | 描述 | 复现步骤 / 证据 | 归属 |
|---|---|---|---|---|
| P1 | — | 无 | — | — |
| P2 | — | **M3 范围内无 P2** | — | — |
| P2 | P2-E1 | **冷启动 import 深链不弹关联导入确认框**（既有，非本批引入）：进程未启动时投递 `legado://import/...` 或 `legado://foo`，最终落书架 | `am force-stop` → `am start -a VIEW -d "legado://import/bookSource?src=…"` → 2s/10s 均无面板（`m3_26`、`m3_27`）；hot 路径正常（`m3_28`、`m3_30`） | 既有（M3 diff 未触及导入分流；推测闪屏替换竞态）；建议单独立项 + 补冷启动用例；未在 M2 基线复测 |
| P3 | P3-O1 | **字典查询页首次系统返回键被输入焦点吞掉**（既有）：`autofocus` 输入框导致首按不 pop；点顶栏返回正常 | 深链进字典后 `input keyevent 4` 一次仍停留字典页，UI 返回一次即回；「我的→字典规则→字典查询」同样复现（`data/58`/`59`） | 既有页面行为，非 M3 |
| P3 | P3-O2 | **1.6 字体下地址按字符断行**（M2 P3-3 延续）：`http://` / `…112` / `2`；无溢出、可操作 | `font_scale 1.6` → `m3_10` | 排版优化，建议评估单行省略/可选中 |
| P3 | P3-O3 | **同会话导入面板复用旧错误态**（既有）：失败导入后再投递其它 import URI，仍显示旧 `HTTP 404`；新进程首投为空面板 | `m3_29` vs `m3_30` | 既有关联导入面板行为 |
| P3 | P3-O4 | **Web 服务开关与副题冷启动不一致**（M1 登记 P3）：冷启动后开关显示开、副题 `stopped`、服务未启动；点按后变为关 | `data/139_my_state.xml`（12:29） | 既有状态机，M2 已登记未复测 |
| P3 | P3-O5 | **删除书籍后书架不即时刷新**（M1 登记 P3）：管理态删除→书架仍显示旧行；重启后空 | `m3_51`（删除后仍在） vs `m3_52`（重启后空） | 既有列表刷新问题 |
| 观察 | O-1 | `legado://` 解析器弹窗：同机三款 legado 应用均声明该 scheme，`am start -d` 需选应用；本轮统一用显式组件投递（不影响应用侧分流） | `data/43_cold_dict.xml` | 环境说明 |
| 观察 | O-2 | crash buffer 中 `uiautomator` 退出时 SIGSEGV（取证工具自身），`io.legado` 记录 0 条 | `logcat/crash_final.log` | 工具/环境 |
| 未覆盖 | U-1 | `containerOpacity < 100` 时 footer 视觉叠加未在设备复核 | 仅 widget 测试覆盖「footer 不乘 containerOpacity」 | 建议后续深色/半透明专项 |
| 未覆盖 | U-2 | 深色主题下 footer 入组未复测（M2 已覆盖深色行卡/动作行） | — | 非本批阻塞 |

## 六、结论与建议

- **功能结论**：M3 验收目标达成（7/7 场景 PASS）。动作行已无损移入分组容器：默认主题下
  与行卡同容器、12dp 上内边距、右对齐 16dp、无行卡/分隔线/2dp 行距；开启容器背景图 +
  自定义 16dp 圆角 + 1dp 边框时，footer 与开关行共享同一图片层/裁剪/边框；点按动作按钮
  不切换开关、不停服，停止后动作行收起；字体 1.3/1.6 无溢出。
- **深链结论**：`legado://dict`/`dict_rule`（含 `yuedu://`、三斜杠、query、末尾斜杠）
  冷启动与热路径均正确落页；冷启动等闪屏退出（+1s 帧可见字典页压在淡出闪屏上）；
  同 URI 存续期去重（返回一次回原页）、pop 后可重开、后台投递均成立；
  `legado://import/...` 与未知 host 仍为关联导入语义，未被误判为字典。
- **回归结论**：复制（剪贴板实测 URL）/浏览器打开/断网 `127.0.0.1（本机）`/恢复局域网地址、
  AI 占位、服务与工具、首页/发现/订阅、本地书阅读均正常；FATAL=0、ANR=0、overflow=0、
  E/flutter=0（22,918 行），crash buffer 无本应用记录。
- **门禁结论**：`flutter analyze` 0；定向 82/82；全量 3971 passed + 1 skipped；release
  构建 EXIT=0；安装成功且设备侧 sha256 与产物一致；版本 2.0.440+441。
- **建议（按优先级）**：
  1. **P2-E1**：补「冷启动 import 深链」的在位等待（复用 `isSplashVisible` 逐帧等待，与
     路由深链同法），并新增 widget/集成用例；在此之前在计划中保留登记。
  2. **P3-O1**：评估字典页首按返回：进入页时不要无条件 `autofocus`，或在 `PopScope` 中
     先 `unfocus` 再 pop，避免深链/普通入口都要按两次返回。
  3. **P3-O3**：关联导入面板每次打开重置错误态（新 key 或清空 state），避免旧错误误导。
  4. **P3-O4/P3-O5**：沿用 M1 登记项，按独立批次修复（Web 状态镜像、书架删除刷新）。
  5. **U-1**：后续专项补 `containerOpacity` 半透明与深色主题下 footer 的视觉回归。
- **证据路径**：
  - 报告：`docs/DEVICE_ACCEPTANCE_20261103_M3_MY_PAGE.md`
  - 截图（62 张）：`docs/materials_1106/`（`m3_00`~`m3_59`）
  - 日志/数据/脚本：`tmp_debug/device_acceptance_20261103_m3/`
    - `logcat/analyze.log`、`targeted_tests.log`、`full_tests.log`、
      `build_release.log`、`install.log`、`session_main.log`、`session_final.log`、`crash_final.log`
    - `data/version_installed.txt`、`version_final.txt`、`apk_sha256.txt`、
      `apk_sha256_installed.txt`、`so_info.txt`、`curl_web.txt`、`prefs_final.xml`
    - `data/01_my_top.xml` ~ `145_dedupe_back.xml`（逐步骤语义树）
    - `scripts/ui.py`（本轮 UI dump/点击/截图辅助脚本）

编写：ZCode QA 子代理 ｜ 2026-11-03
